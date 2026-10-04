# frozen_string_literal: true

# check.rb -- the rule checker behind ai/test/gitlab-ci/self-test.sh (DND-1946).
# Usage: ruby check.rb <.gitlab-ci.yml>. Prints each violated rule; exit 1 if any.

require "yaml"

path = ARGV.fetch(0) { abort "usage: check.rb FILE\n  Fix: pass the .gitlab-ci.yml path." }
unless File.file?(path)
  warn "gitlab-ci check: #{path} is missing\n  Fix: restore .gitlab-ci.yml at the repo root."
  exit 1
end

doc = YAML.safe_load_file(path, aliases: true)
errors = []
unless doc.is_a?(Hash)
  warn "gitlab-ci check: #{path} is not a YAML mapping\n  Fix: write a valid .gitlab-ci.yml."
  exit 1
end

RESERVED = %w[workflow default stages variables include image services before_script after_script cache].freeze
jobs = doc.reject { |k, v| RESERVED.include?(k) || k.start_with?(".") || !v.is_a?(Hash) }

# Fork guard: first workflow rule, `when: never`, comparing source and project path.
rules = doc.dig("workflow", "rules")
first = rules.is_a?(Array) ? rules.first : nil
guard = first.is_a?(Hash) ? first["if"].to_s : ""
unless guard.include?("CI_MERGE_REQUEST_SOURCE_PROJECT_PATH") && guard.include?("!= $CI_PROJECT_PATH") && first["when"] == "never"
  errors << "fork guard: workflow:rules must open with an `if` comparing $CI_MERGE_REQUEST_SOURCE_PROJECT_PATH to $CI_PROJECT_PATH, `when: never`"
end
ifs = Array(rules).map { |r| r.is_a?(Hash) ? r["if"].to_s : "" }
errors << "workflow: no merge_request_event rule" unless ifs.any? { |i| i.include?("merge_request_event") }
dup = Array(rules).find { |r| r.is_a?(Hash) && r["if"].to_s.include?("CI_OPEN_MERGE_REQUESTS") }
errors << "workflow: no rule using $CI_OPEN_MERGE_REQUESTS with `when: never` (CI_OPEN_MERGE_REQUESTS; duplicate branch+MR pipelines)" unless dup && dup["when"] == "never"
errors << "workflow: no branch pipeline rule ($CI_COMMIT_BRANCH)" unless ifs.any? { |i| i.strip == "$CI_COMMIT_BRANCH" }

errors << "no jobs found" if jobs.empty?
jobs.each do |name, job|
  tags = job["tags"]
  errors << "#{name}: tags must be exactly [ci] (the role tag; no untagged job, no per-host tag), got #{tags.inspect}" unless tags == ["ci"]
  errors << "#{name}: id_tokens is not allowed (no credentials on the ci runner)" if job.key?("id_tokens")
  errors << "#{name}: secrets is not allowed (no credentials on the ci runner)" if job.key?("secrets")
  errors << "#{name}: interruptible must be true" unless job["interruptible"] == true
end

# Variables, anywhere, may not name a credential.
all_vars = [doc["variables"]] + jobs.values.map { |j| j["variables"] }
all_vars.compact.each do |vars|
  vars.each_key do |k|
    errors << "variable #{k}: credential-looking names are not allowed (no secrets in this file)" if k.to_s =~ /TOKEN|SECRET|PASSWORD|KEY|CREDENTIAL/i
  end
end

gate = jobs["harness-gate"]
if gate.nil?
  errors << "harness-gate: job is missing"
else
  scripts = Array(gate["script"]).flatten.map(&:to_s)
  errors << "harness-gate: script must run `ai/bin/harness-gate` as a command" unless scripts.any? { |s| s.strip == "ai/bin/harness-gate" || s.strip.end_with?(" ai/bin/harness-gate") }
  errors << "harness-gate: variables must set GIT_DEPTH \"0\" (landed bars read origin/main)" unless gate.dig("variables", "GIT_DEPTH").to_s == "0"
  errors << "harness-gate: script must fetch origin/main explicitly" unless scripts.any? { |s| s.include?("git fetch") && s.include?("origin/main") }
  img = gate["image"].to_s
  errors << "harness-gate: image must be an exact tag pinned by @sha256 digest, got #{img.inspect}" unless img =~ /\A[^:@\s]+:\d+\.\d+\.\d+[^@\s]*@sha256:[0-9a-f]{64}\z/
end

if errors.empty?
  puts "gitlab-ci check: OK (#{jobs.size} job(s))"
else
  errors.each { |e| warn "gitlab-ci check: FAIL -- #{e}" }
  warn "  Fix: restore the rule in .gitlab-ci.yml (see ai/test/gitlab-ci/self-test.sh)."
  exit 1
end
