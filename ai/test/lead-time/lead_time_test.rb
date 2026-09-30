# frozen_string_literal: true

# Deterministic suite for ai/bin/lead-time's landing rules (DND-1317).
#
# The forge is stubbed: every `gh` call is answered from fixtures by
# overriding GitHubForge#run_json on the instance. git is REAL, against a
# throwaway repository whose `origin` is a local bare repo, so the patch-id
# and ancestry logic runs on real commits. No network, no model.
# Run by ai/test/lead-time/self-test.sh, which harness-gate discovers.

require "json"
require "open3"
require "tmpdir"
require "fileutils"
require "stringio"

load File.expand_path("../../bin/lead-time", __dir__)

$failures = []
$checks = 0

def check(desc)
  $checks += 1
  $failures << desc unless yield
rescue StandardError => e
  $failures << "#{desc} (raised #{e.class}: #{e.message})"
end

# ---------------------------------------------------------------------------
# Fixture repository
# ---------------------------------------------------------------------------

GIT_ENV = {
  "GIT_CONFIG_NOSYSTEM" => "1",
  "GIT_AUTHOR_NAME" => "Fixture", "GIT_AUTHOR_EMAIL" => "fixture@example.invalid",
  "GIT_COMMITTER_NAME" => "Fixture", "GIT_COMMITTER_EMAIL" => "fixture@example.invalid",
}.freeze

def sh_git(dir, *args, date: "2026-09-29T00:00:00Z")
  env = GIT_ENV.merge("GIT_AUTHOR_DATE" => date, "GIT_COMMITTER_DATE" => date)
  out, err, st = Open3.capture3(env, "git", "-C", dir, "-c", "commit.gpgsign=false",
                                "-c", "init.defaultBranch=main", *args)
  raise "fixture git #{args.join(' ')} failed: #{err}" unless st.success?

  out.strip
end

def commit_file(dir, path, body, subject, date)
  File.write(File.join(dir, path), body)
  sh_git(dir, "add", path)
  sh_git(dir, "commit", "-q", "-m", subject, date: date)
  sh_git(dir, "rev-parse", "HEAD")
end

# Builds one repo holding every scenario. Returns a Hash of named oids.
#   main:   c0 -> c1 -> p7' (PR 7 rebased) -> s10 (PR 10 squashed) -> y9
#   PR 7:   c0 -> p7              (landed by a rebase: same patch, new sha)
#   PR 8:   c0 -> p8              (never landed)
#   PR 9:   c0 -> x9 "DND-9: fix" (main carries y9, same subject, other patch)
#   PR 10:  c0 -> q1 -> q2        (landed squashed into one commit s10)
#   PR 11:  c0 -> p11             (partly landed: see p11b)
def build_fixture(root)
  origin = File.join(root, "origin.git")
  work = File.join(root, "work")
  FileUtils.mkdir_p(origin)
  sh_git(origin, "init", "-q", "--bare")
  sh_git(root, "clone", "-q", origin, work)
  o = {}
  o[:c0] = commit_file(work, "a.txt", "a\n", "init", "2026-09-28T00:00:00Z")
  sh_git(work, "push", "-q", "origin", "HEAD:refs/heads/main")

  pr = lambda do |n, &blk|
    sh_git(work, "checkout", "-q", "-B", "pr#{n}", o[:c0])
    head = blk.call
    sh_git(work, "push", "-q", "origin", "HEAD:refs/pull/#{n}/head")
    head
  end
  o[:p7] = pr.call(7) { commit_file(work, "b.txt", "seven\n", "DND-7: add b", "2026-09-28T01:00:00Z") }
  o[:p8] = pr.call(8) { commit_file(work, "c.txt", "eight\n", "DND-8: add c", "2026-09-28T02:00:00Z") }
  o[:x9] = pr.call(9) { commit_file(work, "d.txt", "nine-pr\n", "DND-9: fix", "2026-09-28T03:00:00Z") }
  o[:q2] = pr.call(10) do
    commit_file(work, "e.txt", "ten-1\n", "DND-10: part one", "2026-09-28T04:00:00Z")
    commit_file(work, "f.txt", "ten-2\n", "DND-10: part two", "2026-09-28T04:10:00Z")
  end
  o[:p11] = pr.call(11) do
    commit_file(work, "g.txt", "eleven-1\n", "DND-11: part one", "2026-09-28T05:00:00Z")
    commit_file(work, "h.txt", "eleven-2\n", "DND-11: part two", "2026-09-28T05:10:00Z")
  end

  sh_git(work, "checkout", "-q", "-B", "main", o[:c0])
  o[:c1] = commit_file(work, "z.txt", "z\n", "unrelated", "2026-09-29T06:00:00Z")
  # PR 7 lands rebased: same patch, new sha, new committer date.
  o[:p7_landed] = commit_file(work, "b.txt", "seven\n", "DND-7: add b", "2026-09-29T07:00:00Z")
  # PR 10 lands squashed: both files in one commit.
  File.write(File.join(work, "e.txt"), "ten-1\n")
  File.write(File.join(work, "f.txt"), "ten-2\n")
  sh_git(work, "add", "e.txt", "f.txt")
  sh_git(work, "commit", "-q", "-m", "DND-10: squashed", date: "2026-09-29T08:00:00Z")
  o[:s10] = sh_git(work, "rev-parse", "HEAD")
  # A commit titled like PR 9's, with a different change (a conflict-resolved
  # or hand-edited landing): not provably PR 9's change, not provably absent.
  o[:y9] = commit_file(work, "d.txt", "nine-main\n", "DND-9: fix", "2026-09-29T09:00:00Z")
  # Only the first of PR 11's two commits reaches main.
  o[:p11b] = commit_file(work, "g.txt", "eleven-1\n", "DND-11: part one", "2026-09-29T10:00:00Z")
  sh_git(work, "push", "-q", "origin", "HEAD:refs/heads/main")
  sh_git(work, "push", "-q", "origin", "#{o[:c0]}:refs/heads/start")
  o[:origin] = origin
  o
end

# A checkout that knows only the first commit: the PR heads and the landed
# main are not in it, so the tool has to fetch them, as in a real checkout.
def fresh_clone(o, root, name)
  dir = File.join(root, name)
  sh_git(root, "clone", "-q", "--no-local", "--single-branch", "--branch", "start", o[:origin], dir)
  dir
end

# Pushes to refs/heads/main as GitHub's activity API reports them, newest
# first, one page per inner array (gh api --paginate --slurp).
def activity(o)
  [[
    { "timestamp" => "2026-09-29T10:00:30Z", "activity_type" => "push", "ref" => "refs/heads/main",
      "before" => o[:y9], "after" => o[:p11b] },
    { "timestamp" => "2026-09-29T09:00:30Z", "activity_type" => "push", "ref" => "refs/heads/main",
      "before" => o[:s10], "after" => o[:y9] },
    { "timestamp" => "2026-09-29T08:18:58Z", "activity_type" => "push", "ref" => "refs/heads/main",
      "before" => o[:p7_landed], "after" => o[:s10] },
  ], [
    { "timestamp" => "2026-09-29T07:05:00Z", "activity_type" => "push", "ref" => "refs/heads/main",
      "before" => o[:c1], "after" => o[:p7_landed] },
    { "timestamp" => "2026-09-29T06:00:30Z", "activity_type" => "push", "ref" => "refs/heads/main",
      "before" => o[:c0], "after" => o[:c1] },
  ]]
end

def pr_view(o, n, state:, merged_at: nil, closed_at: "2026-09-29T11:00:00Z", head:, commits:)
  { "number" => n, "title" => "DND-#{n}: t", "headRefName" => "dnd-#{n}-b", "state" => state,
    "mergedAt" => merged_at, "closedAt" => closed_at, "createdAt" => "2026-09-28T00:30:00Z",
    "baseRefName" => "main", "headRefOid" => o[head],
    "mergeCommit" => merged_at ? { "oid" => o[:c1] } : nil,
    "commits" => commits.map { |t| { "authoredDate" => t, "committedDate" => t } } }
end

# A GitHubForge over the fixture whose gh answers come from `views`.
def forge_over(o, views, calls = [], list: [], dir: o[:work])
  f = GitHubForge.new(dir)
  act = activity(o)
  f.define_singleton_method(:run_json) do |cmd, _dir|
    calls << cmd
    next [] if cmd[1] == "run"
    next list if cmd[1] == "pr" && cmd[2] == "list"
    next act if cmd[1] == "api" && cmd.any? { |c| c.include?("/activity") }
    next views.fetch(cmd[3].to_i) if cmd[1] == "pr" && cmd[2] == "view"

    raise "unexpected gh call: #{cmd.inspect}"
  end
  f
end

def capture_row(row)
  old = $stdout
  $stdout = StringIO.new
  print_row(row)
  $stdout.string
ensure
  $stdout = old
end

Dir.mktmpdir("lead-time-test") do |root|
  o = build_fixture(root)
  o[:work] = fresh_clone(o, root, "checkout")
  views = {
    7 => pr_view(o, 7, state: "CLOSED", head: :p7, commits: ["2026-09-28T01:00:00Z"]),
    8 => pr_view(o, 8, state: "CLOSED", head: :p8, commits: ["2026-09-28T02:00:00Z"]),
    9 => pr_view(o, 9, state: "CLOSED", head: :x9, commits: ["2026-09-28T03:00:00Z"]),
    10 => pr_view(o, 10, state: "CLOSED", head: :q2,
                         commits: ["2026-09-28T04:00:00Z", "2026-09-28T04:10:00Z"]),
    11 => pr_view(o, 11, state: "CLOSED", head: :p11,
                         commits: ["2026-09-28T05:00:00Z", "2026-09-28T05:10:00Z"]),
    12 => pr_view(o, 12, state: "OPEN", closed_at: nil, head: :p8, commits: ["2026-09-28T02:00:00Z"]),
    13 => pr_view(o, 13, state: "MERGED", merged_at: "2026-09-29T06:30:00Z",
                         closed_at: "2026-09-29T06:30:00Z", head: :p8, commits: ["2026-09-28T02:00:00Z"]),
    # Its head itself was fast-forwarded onto main (no rebase).
    14 => pr_view(o, 14, state: "CLOSED", head: :c1, commits: ["2026-09-29T05:00:00Z"]),
  }

  ProbeFailures.reset!
  forge = forge_over(o, views)

  # --- the DND-1317 regression: CLOSED on GitHub, but its change is on main.
  r7 = analyze(forge, 7)
  check("a CLOSED PR landed by a rebase reads as landed, not open (DND-1317)") { r7[:end_kind] == :merge }
  check("its landing time is the push that put the change on main") { r7[:merged] == "2026-09-29T07:05:00Z" }
  check("its lead runs from its start to that push") { r7[:lead_seconds] == (30 * 3600) + (5 * 60) }
  check("the row names how it landed") { r7[:landed_via] == "push" }
  check("the row names the landed commit") { r7[:landed_commit] == o[:p7_landed] }

  r10 = analyze(forge, 10)
  check("a CLOSED PR landed squashed reads as landed") { r10[:end_kind] == :merge }
  check("a squashed landing is timed by the push that carried it") { r10[:merged] == "2026-09-29T08:18:58Z" }

  r14 = analyze(forge, 14)
  check("a CLOSED PR whose own head is on main reads as landed") { r14[:end_kind] == :merge }
  check("its head is the landed commit, timed by the push that carried it") do
    r14[:landed_commit] == o[:c1] && r14[:merged] == "2026-09-29T06:00:30Z"
  end

  # --- CLOSED and not on main: distinct from open, never a lead.
  r8 = analyze(forge, 8)
  check("a CLOSED PR whose change is not on main reads as closed, not open") { r8[:end_kind] == :closed }
  check("a closed-unlanded PR has no lead") { r8[:lead_seconds].nil? }

  # --- cannot decide: says so, never open and never closed.
  r9 = analyze(forge, 9)
  check("a same-subject, different-patch commit on main is could-not-measure") { r9[:end_kind] == :unmeasured }
  check("the could-not-measure row says why") { r9[:unmeasured_reason].to_s.include?("DND-9: fix") }
  r11 = analyze(forge, 11)
  check("a partly-landed PR is could-not-measure") { r11[:end_kind] == :unmeasured }
  check("the partial landing names the count") { r11[:unmeasured_reason].to_s.include?("1 of 2") }

  # --- the states that already worked still do.
  r12 = analyze(forge, 12)
  check("an OPEN PR still reads as open") { r12[:end_kind] == :open }
  r13 = analyze(forge, 13)
  check("a MERGED PR still ends at mergedAt") { r13[:merged] == "2026-09-29T06:30:00Z" && r13[:end_kind] == :merge }
  check("a MERGED PR names the forge merge") { r13[:landed_via] == "merge" }
  check("no probe failed on a readable fixture") { !ProbeFailures.any? }

  # --- a landing probe that cannot run is a probe failure, never "open".
  ProbeFailures.reset!
  cut_off = fresh_clone(o, root, "cut-off")
  sh_git(cut_off, "remote", "set-url", "origin", File.join(root, "no-such-origin.git"))
  rb = analyze(forge_over(o, views, dir: cut_off), 7)
  check("a landing probe whose fetch fails is recorded as a failed probe") { ProbeFailures.any? }
  check("and the row does not read as open") { rb.nil? || rb[:end_kind] != :open }
  check("and the row says it could not measure") { rb.nil? || rb[:end_kind] == :unmeasured }
  ProbeFailures.reset!
  broken_log = forge_over(o, views, dir: o[:work])
  broken_log.define_singleton_method(:base_pushes) { |_b| ProbeFailures.record("gh api activity", "HTTP 502") }
  rl = analyze(broken_log, 7)
  check("an unreadable activity log is a failed probe, not open") { ProbeFailures.any? && rl[:end_kind] == :unmeasured }
  ProbeFailures.reset!

  # --- the window scan sees closed PRs too.
  scan_calls = []
  listed = [{ "number" => 7, "mergedAt" => nil, "closedAt" => "2026-09-29T11:00:00Z", "state" => "CLOSED" },
            { "number" => 13, "mergedAt" => "2026-09-29T06:30:00Z", "closedAt" => "2026-09-29T06:30:00Z",
              "state" => "MERGED" }]
  scanner = forge_over(o, views, scan_calls, list: listed)
  ids = scanner.landing_candidates_since("2026-09-29T00:00:00Z")
  list_cmd = scan_calls.find { |c| c[1] == "pr" && c[2] == "list" }
  check("the window scan lists closed PRs, not only merged ones") do
    list_cmd.include?("closed") && list_cmd.any? { |c| c.start_with?("updated:>=") }
  end
  check("the window scan returns a CLOSED candidate for the landing check") { ids.include?(7) && ids.include?(13) }

  # --- the scan keeps a landing inside the window, drops one before it, and
  #     counts the closed-unlanded rows instead of silently losing them.
  window = -> { select_window([r7, r8, r13], "2026-09-29T07:00:00Z") }
  check("a request closed inside the window is kept") { window.call[0].map { |r| r[:pr] } == [7] }
  check("a closed-unlanded row is counted, not kept") { window.call[1] == 1 }
  # r7 landed by push at 07:05 and closed at 11:00. A scan between the two
  # could not list it; the next scan, from 08:00, must still keep it.
  check("a push landing before the window whose close is inside it is kept") do
    select_window([r7], "2026-09-29T08:00:00Z")[0].map { |r| r[:pr] } == [7]
  end

  # --- --slow keeps could-not-measure rows: they cannot be shown fast.
  slow = slow_filter([r9, { pr: 99, lead_seconds: 60 }, r7], 90)
  check("--slow keeps an outlier and a could-not-measure row, drops a fast one") do
    slow.map { |r| r[:pr] } == [7, 9]
  end

  # --- the landing rules on their own (pure).
  cls = LeadTime.classify_landing(pr_only: [], combined_pid: nil, main: [{ sha: "m", pid: "p", subject: "s" }])
  check("no commit of its own and no diff match is could-not-measure, never closed") { cls[:status] == :unknown }
  pushes = [{ at: "T1", after: "a1" }, { at: "T2", after: "a2" }, { at: "T3", after: "a3" }]
  carries = ->(hits) { ->(_s, after) { hits.fetch(after) } }
  check("the landing is the FIRST push that carries the commit") do
    LeadTime.landing_push("s", pushes, carries.call("a1" => false, "a2" => true, "a3" => true)) == ["T2", nil]
  end
  check("an unreadable push before the carrier makes the time unprovable") do
    at, why = LeadTime.landing_push("s", pushes, carries.call("a1" => nil, "a2" => true, "a3" => true))
    at.nil? && why.include?("T1")
  end
  check("no carrying push is a reason, not a time") do
    at, why = LeadTime.landing_push("s", pushes, carries.call("a1" => false, "a2" => false, "a3" => false))
    at.nil? && why.include?("no push")
  end

  # --- a landed request with no commits has no start, and says so.
  nostart = LeadTime.compute(start_iso_times: [], deploy_at: nil, pipeline_at: nil,
                             merged_at: "2026-09-29T07:05:00Z")
  check("a landed request with no commits names why it has no lead") do
    nostart[:lead_seconds].nil? && nostart[:unmeasured_reason].to_s.include?("no commits")
  end

  # --- presentation: could-not-measure and closed are named on the row.
  out = capture_row(r9)
  check("a could-not-measure row prints 'could not measure'") { out.include?("could not measure") }
  check("a closed row prints via=closed") { capture_row(r8).include?("via=closed") }
  check("a landed-by-push row prints its landing") do
    capture_row(r7).include?("landed by push #{o[:p7_landed][0, 8]}") && !capture_row(r13).include?("landed by push")
  end
end

if $failures.empty?
  puts "lead_time_test: PASS (#{$checks} checks)"
  exit 0
end
warn "lead_time_test: FAIL (#{$failures.size} of #{$checks})"
$failures.each { |f| warn "  - #{f}" }
warn "Fix: make ai/bin/lead-time judge a CLOSED GitHub PR's landing by its change " \
     "(patch-id) on the base branch, timed by the push that carried it; a PR it cannot " \
     "place must read 'could not measure', and a closed-unlanded one 'closed', never 'open'."
exit 1
