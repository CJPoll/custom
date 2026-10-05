# frozen_string_literal: true

# The judge on captured CLI traffic (DND-2025). Each scenario under fixtures/
# is what real gh 2.96.0 or glab 1.92.1 sent to a local fake upstream
# (capture/capture --help). Every earlier argv-scan leak is a scenario, and
# each must be REFUSED when a pattern matches its planted synthetic value and
# the target is public, and FORWARDED when no pattern matches (clean text).
# The bytes are the CLI's own, so these cases judge what is actually sent:
# no flag table, env fallback, URL grammar or placeholder decides it.

require "json"
require_relative "helper"
require_relative "../../forge_wire/verdict"

PLANTED_PATTERNS = OutboundScan.parse_patterns("synthetic-work\tSYNTH-WORK-[0-9]{4}\n", "planted")
CLEAN_PATTERNS = OutboundScan.parse_patterns("other-work\tNEVER-SENT-[0-9]{4}\n", "clean")
TABLE = ForgeWire::Operations.load_default

# What the proxy's upstream reads would say for the synthetic repositories.
VISIBILITY = {
  "github:repo:synth-owner/pub" => "public", "github:repo:synth-owner/priv" => "private",
  "github:node:R_kgDOSynthPub" => "public", "github:node:R_kgDOSynthPriv" => "private",
  "github:node:PR_kwDOSynthPub1" => "public", "github:node:PR_kwDOSynthPriv1" => "private",
  "github:node:I_kwDOSynthPub3" => "public", "github:node:LA_kwDOSynthLabel" => "public",
  "gitlab:project:synth-group/pub" => "public", "gitlab:project:synth-group/priv" => "private",
  "gitlab:project_id:101" => "public", "gitlab:project_id:102" => "private",
}.freeze

def forge_of(name)
  name.start_with?("gh-") ? :github : :gitlab
end

# -> [[file, Verdict], ...] for a scenario under the given patterns.
def run(name, patterns)
  fixture(name).map do |file, req|
    v = ForgeWire::Judge.judge(req, forge: forge_of(name), table: TABLE, scan: ForgeWire::Scan.measured(patterns),
                                    visibility: VISIBILITY)
    [file, v]
  end
end

# The first refusal decides what the CLI sees (it stops there); else :forward.
def outcome(verdicts)
  refused = verdicts.find { |_, v| !v.forward? }
  refused ? refused[1].state : :forward
end

def hit_fields(verdicts)
  verdicts.flat_map { |_, v| v.hits.map { |h| h.location.field } }
end

# scenario => [outcome with the planted pattern, outcome with a clean one]
EXPECT = {
  "gh-api-read" => %i[forward forward],
  "gh-dnd-1976-flag-swallow" => %i[hits forward],
  "gh-dnd-2006-gh-repo-fallback" => %i[hits forward],
  "gh-dnd-2007-api-write" => %i[hits forward],
  "gh-dnd-2007-placeholder" => %i[hits forward],
  "gh-dnd-2019-pr-create-fill" => %i[hits forward],
  "gh-dnd-2019-issue-develop" => %i[ref_without_grant ref_without_grant],
  "gh-pr-comment-private" => %i[forward forward],
  "gh-pr-merge" => %i[ref_without_grant ref_without_grant],
  "gh-pr-merge-auto" => %i[ref_without_grant ref_without_grant],
  "gh-pr-close" => %i[forward forward],
  "gh-pr-reopen" => %i[forward forward],
  "gh-pr-edit-base" => %i[forward forward],
  "gh-run-rerun" => %i[forward forward],
  "gh-repo-create" => %i[forward forward],
  "glab-api-read" => %i[forward forward],
  "glab-dnd-2009-upper-scheme" => %i[hits forward],
  "glab-dnd-2009-placeholder" => %i[hits forward],
  "glab-dnd-2012-schemeless-url" => %i[hits forward],
  "glab-dnd-2014-related-issue" => %i[hits forward],
  "glab-dnd-2017-hidden-flag" => %i[hits forward],
  "glab-dnd-2018-head-project" => %i[ref_without_grant ref_without_grant],
  "glab-mr-create" => %i[hits forward],
  "glab-mr-note-private" => %i[forward forward],
  "glab-mr-merge" => %i[ref_without_grant ref_without_grant],
}.freeze

check("every captured scenario has an expectation, and every expectation a capture") do
  fixture_names.sort == EXPECT.keys.sort
end

fixture_names.each do |name|
  check("#{name}: every request parses whole and has meta.json") do
    fixture(name).all? { |_, r| r.is_a?(ForgeWire::Request) } && File.file?(File.join(FIXTURE_DIR, name, "meta.json"))
  end
  next unless EXPECT.key?(name)

  planted, clean = EXPECT[name]
  check("#{name}: with the planted pattern -> #{planted}") { outcome(run(name, PLANTED_PATTERNS)) == planted }
  check("#{name}: with a pattern that matches nothing -> #{clean}") { outcome(run(name, CLEAN_PATTERNS)) == clean }
  check("#{name}: no refusal prints the planted value") do
    run(name, PLANTED_PATTERNS).none? { |_, v| v.lines.join("\n").include?("SYNTH-WORK-4242") }
  end
end

# Every write the CLIs made is an operation the table names: the table is
# built from these captures, and a capture it does not cover is a gap.
check("every captured write is in the operation table (no unknown_operation)") do
  fixture_names.all? { |n| run(n, CLEAN_PATTERNS).none? { |_, v| v.state == :unknown_operation } }
end

# --- each leak, where it is caught ---------------------------------------------
def fields_for(name)
  hit_fields(run(name, PLANTED_PATTERNS))
end

check("DND-1976: the body that followed `-l -t` is the PR body on the wire") do
  fields_for("gh-dnd-1976-flag-swallow") == ["body.variables.input.body"]
end
check("DND-2006: GH_REPO's PR is the wire target (its node, not the checkout)") do
  v = run("gh-dnd-2006-gh-repo-fallback", PLANTED_PATTERNS).last[1]
  v.targets.map(&:key) == ["github:node:PR_kwDOSynthPub1"] && v.state == :hits
end
check("DND-2007: an api write's field is caught") { fields_for("gh-dnd-2007-api-write") == ["body.title"] }
check("DND-2007: the {branch} placeholder is caught filled") { fields_for("gh-dnd-2007-placeholder") == ["body.title"] }
check("DND-2009: HTTPS:// reaches gitlab.com and is judged there") { fields_for("glab-dnd-2009-upper-scheme") == ["body.title"] }
check("DND-2009: :branch is caught filled") { fields_for("glab-dnd-2009-placeholder") == ["body.title"] }
check("DND-2012: the note goes to the public project the URL names") do
  v = run("glab-dnd-2012-schemeless-url", PLANTED_PATTERNS).last[1]
  v.targets.map(&:key) == ["gitlab:project:synth-group/pub"] && v.state == :hits
end
check("DND-2014: the issue title glab copied is caught in the MR title") do
  fields_for("glab-dnd-2014-related-issue") == ["body.title"]
end
check("DND-2017: the hidden flag's file is caught as the release description") do
  fields_for("glab-dnd-2017-hidden-flag") == ["body.description"]
end
check("DND-2018: the branch create on the head project is a refused ref operation") do
  vs = run("glab-dnd-2018-head-project", CLEAN_PATTERNS)
  branch = vs.find { |_, v| v.operations.any? { |o| o.route.end_with?("/repository/branches") } }
  branch && branch[1].state == :ref_without_grant
end
check("DND-2018: the MR on the head project is judged against both projects") do
  vs = run("glab-dnd-2018-head-project", PLANTED_PATTERNS)
  mr = vs.last[1]
  mr.targets.map(&:key) == ["gitlab:project:synth-group/pub", "gitlab:project_id:102"] && mr.state == :hits
end
check("DND-2019: --fill's commit text is caught in the PR body") do
  fields_for("gh-dnd-2019-pr-create-fill") == ["body.variables.input.body"]
end
check("DND-2019: issue develop's branch create is a refused ref operation") do
  run("gh-dnd-2019-issue-develop", CLEAN_PATTERNS).any? { |_, v| v.state == :ref_without_grant && v.operations.map(&:route) == ["createLinkedBranch"] }
end
check("a private target forwards the planted text unscanned (GitHub)") do
  run("gh-pr-comment-private", PLANTED_PATTERNS).last[1].state == :private
end
check("a private target forwards the planted text unscanned (GitLab)") do
  run("glab-mr-note-private", PLANTED_PATTERNS).last[1].state == :private
end
check("the merge a guard would grant is refused here: grants are build step 5") do
  %w[gh-pr-merge glab-mr-merge].all? { |n| run(n, CLEAN_PATTERNS).last[1].state == :ref_without_grant }
end

finish("forge-wire fixtures")
