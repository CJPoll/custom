# frozen_string_literal: true

# git_env_leak_test -- ai/bin/lead-time answers for the repo it is given even
# when its environment carries GIT_DIR / GIT_WORK_TREE / GIT_INDEX_FILE for
# ANOTHER repo (DND-1923). git reads those before -C, so a leak made every git
# read answer for the wrong repo with exit 0. DND-1602 fixed the same leak in
# the experiment adapters; this pins the lead-time tool and its product I/O.
# No network, no forge: gh is a fake script, git is real against two fixtures.
# Run by ai/test/lead-time/self-test.sh, which harness-gate discovers.

require "json"
require "open3"
require "tmpdir"
require "fileutils"

load File.expand_path("../../bin/lead-time", __dir__)
require_relative "../../lib/leadtime_product_io"

$failures = []
$checks = 0

def check(desc)
  $checks += 1
  $failures << desc unless yield
rescue StandardError => e
  $failures << "#{desc} (raised #{e.class}: #{e.message})"
end

DATE = "2026-09-29T00:00:00Z"
FIXTURE_ENV = {
  "GIT_CONFIG_GLOBAL" => "/dev/null", "GIT_CONFIG_NOSYSTEM" => "1", "GIT_DIR" => nil, "GIT_WORK_TREE" => nil,
  "GIT_INDEX_FILE" => nil, "GIT_AUTHOR_NAME" => "Fixture", "GIT_AUTHOR_EMAIL" => "fixture@example.invalid",
  "GIT_COMMITTER_NAME" => "Fixture", "GIT_COMMITTER_EMAIL" => "fixture@example.invalid",
  "GIT_AUTHOR_DATE" => DATE, "GIT_COMMITTER_DATE" => DATE
}.freeze

def fgit(dir, *args)
  out, err, st = Open3.capture3(FIXTURE_ENV, "git", "-C", dir, "-c", "commit.gpgsign=false", *args)
  raise "fixture git #{args.join(' ')} failed: #{err}" unless st.success?

  out.strip
end

def make_repo(dir, file, url)
  FileUtils.mkdir_p(dir)
  fgit(dir, "init", "-q", "-b", "main")
  fgit(dir, "remote", "add", "origin", url)
  File.write(File.join(dir, file), "one\n")
  fgit(dir, "add", file)
  fgit(dir, "commit", "-q", "-m", "add #{file}")
  fgit(dir, "rev-parse", "HEAD")
end

# Run the block with the given variables set in this process's environment (so
# every child inherits them), then restore.
def with_env(vars)
  saved = vars.keys.to_h { |k| [k, ENV.fetch(k, nil)] }
  vars.each { |k, v| ENV[k] = v }
  yield
ensure
  saved.each { |k, v| ENV[k] = v }
end

Dir.mktmpdir("ltgitenv-") do |tmp|
  a = File.join(tmp, "a")
  b = File.join(tmp, "b")
  sha_a = make_repo(a, "alpha.txt", "https://github.com/example/alpha.git")
  sha_b = make_repo(b, "beta.txt", "https://gitlab.com/example/beta.git")
  leak = { "GIT_DIR" => File.join(b, ".git"), "GIT_WORK_TREE" => b, "GIT_INDEX_FILE" => File.join(b, ".git", "index") }

  # A fake forge CLI that reports the git location variables it inherited.
  fake = File.join(tmp, "fake-forge")
  File.write(fake, "#!/bin/sh\nprintf '{\"git_dir\":\"%s\",\"work_tree\":\"%s\"}' \"${GIT_DIR-unset}\" \"${GIT_WORK_TREE-unset}\"\n")
  File.chmod(0o755, fake)

  forge = GitHubForge.new(a)

  check("baseline: origin_url answers for repo A") { origin_url(a) == "https://github.com/example/alpha.git" }

  with_env(leak) do
    check("a leaked GIT_DIR does not change origin_url's repo") { origin_url(a) == "https://github.com/example/alpha.git" }
    check("a leaked GIT_DIR does not change detect_forge's answer") { detect_forge(a) == :github }
    check("a leaked GIT_DIR does not change git_status's repo (A's commit is known to A)") do
      forge.send(:git_status, "cat-file", "-e", "#{sha_a}^{commit}") == 0
    end
    check("a leaked GIT_DIR does not make B's commit known to A") do
      forge.send(:git_status, "cat-file", "-e", "#{sha_b}^{commit}") != 0
    end
    check("a leaked GIT_DIR does not change git_ok's repo") do
      forge.send(:git_ok, "log", "-1", "--format=%s") == "add alpha.txt\n"
    end
    check("a leaked GIT_DIR does not change have_commits?'s repo") { forge.send(:have_commits?, [sha_a]) == true }
    check("a leaked GIT_DIR does not change pushes_since's date lookup") do
      old = { at: "2026-09-01T00:00:00Z" }
      forge.send(:pushes_since, [old], sha_a).empty?
    end
    check("a leaked GIT_DIR is cleared for the forge CLI run_json spawns") do
      run_json([fake], a) == { "git_dir" => "unset", "work_tree" => "unset" }
    end
    check("a leaked GIT_DIR is cleared for leadtime_product_io's git spawns") do
      out, code = LeadTimeProductIO::Run.call(%w[git rev-parse --show-toplevel], chdir: a)
      code.zero? && File.realpath(out.strip) == File.realpath(a)
    end
  end

  check("one GIT_ENV_UNSET definition: leadtime_product_io reuses LeadTimeConfigIO's") do
    LeadTimeProductIO::GIT_ENV_UNSET.equal?(LeadTimeConfigIO::GIT_ENV_UNSET)
  end
end

if $failures.empty?
  puts "git_env_leak_test: #{$checks} checks passed"
  exit 0
end

warn "git_env_leak_test: FAIL (#{$failures.size} of #{$checks})"
$failures.each { |f| warn "  FAIL #{f}" }
warn "Fix: pass LeadTimeConfigIO::GIT_ENV_UNSET as the first Open3 argument of every git (and forge CLI) spawn in " \
     "ai/bin/lead-time, and make LeadTimeProductIO reuse that one constant (DND-1923)."
exit 1
