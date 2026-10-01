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
#   PR 15:  c0 -> p15 "DND-15: edit k" (lands as l15 after m15 edits an
#                                  adjacent line: same change, other context)
def build_fixture(root)
  origin = File.join(root, "origin.git")
  work = File.join(root, "work")
  FileUtils.mkdir_p(origin)
  sh_git(origin, "init", "-q", "--bare")
  sh_git(root, "clone", "-q", origin, work)
  o = {}
  File.write(File.join(work, "k.txt"), "k1\nk2\nk3\n")
  sh_git(work, "add", "k.txt")
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
  o[:p15] = pr.call(15) { commit_file(work, "k.txt", "k1\nk2\nk3-pr\n", "DND-15: edit k", "2026-09-28T06:00:00Z") }

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
  # PR 15's shape is custom PR #83 (DND-1491): main edits a line inside PR
  # 15's diff context, then PR 15's change lands on top. Its added and removed
  # lines are PR 15's; its context is not, so its patch-id differs.
  o[:m15] = commit_file(work, "k.txt", "k1-main\nk2\nk3\n", "unrelated k", "2026-09-29T10:30:00Z")
  o[:l15] = commit_file(work, "k.txt", "k1-main\nk2\nk3-pr\n", "DND-15: edit k", "2026-09-29T10:40:00Z")
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
    { "timestamp" => "2026-09-29T10:45:30Z", "activity_type" => "push", "ref" => "refs/heads/main",
      "before" => o[:p11b], "after" => o[:l15] },
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

# A Notion transport over fixture pages: DND number -> the page's
# "In Progress at" property (a Hash, or :absent for a page without it).
class FakeNotion
  attr_reader :calls

  def initialize(pages, fail_with = nil)
    @pages = pages
    @fail = fail_with
    @calls = []
  end

  def call(method, path, body = nil)
    @calls << [method, path, body]
    raise NextMissionNotion::ReadError, @fail if @fail

    n = body.dig("filter", "unique_id", "equals")
    prop = @pages[n]
    return { "results" => [] } if prop.nil?

    props = { "ID" => { "type" => "unique_id", "unique_id" => { "prefix" => "DND", "number" => n } } }
    props[NotionStart::PROPERTY] = prop unless prop == :absent
    { "results" => [{ "id" => "page-#{n}", "properties" => props }] }
  end
end

def at_prop(iso)
  { "type" => "date", "date" => iso && { "start" => iso, "end" => nil, "time_zone" => nil } }
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
    15 => pr_view(o, 15, state: "CLOSED", head: :p15, commits: ["2026-09-28T06:00:00Z"]),
    # MERGED, but the forge named no merge commit.
    16 => pr_view(o, 16, state: "MERGED", merged_at: "2026-09-29T06:30:00Z",
                         closed_at: "2026-09-29T06:30:00Z", head: :p8, commits: ["2026-09-28T02:00:00Z"])
            .merge("mergeCommit" => nil),
  }

  # The start is the ticket's In Progress date (DND-1318); these landing cases
  # stamp each ticket at its first commit, so the leads below are unchanged.
  starts = NotionStart.new(FakeNotion.new(views.to_h do |n, v|
    [n, at_prop(v["commits"].map { |c| c["authoredDate"] }.min)]
  end))
  ProbeFailures.reset!
  forge = forge_over(o, views)

  # --- the DND-1317 regression: CLOSED on GitHub, but its change is on main.
  r7 = analyze(forge, 7, starts)
  check("a CLOSED PR landed by a rebase reads as landed, not open (DND-1317)") { r7[:end_kind] == :merge }
  check("its landing time is the push that put the change on main") { r7[:merged] == "2026-09-29T07:05:00Z" }
  check("its lead runs from its start to that push") { r7[:lead_seconds] == (30 * 3600) + (5 * 60) }
  check("the row names how it landed") { r7[:landed_via] == "push" }
  check("the row names the landed commit") { r7[:landed_commit] == o[:p7_landed] }

  r10 = analyze(forge, 10, starts)
  check("a CLOSED PR landed squashed reads as landed") { r10[:end_kind] == :merge }
  check("a squashed landing is timed by the push that carried it") { r10[:merged] == "2026-09-29T08:18:58Z" }

  r14 = analyze(forge, 14, starts)
  check("a CLOSED PR whose own head is on main reads as landed") { r14[:end_kind] == :merge }
  check("its head is the landed commit, timed by the push that carried it") do
    r14[:landed_commit] == o[:c1] && r14[:merged] == "2026-09-29T06:00:30Z"
  end

  # --- CLOSED and not on main: distinct from open, never a lead.
  r8 = analyze(forge, 8, starts)
  check("a CLOSED PR whose change is not on main reads as closed, not open") { r8[:end_kind] == :closed }
  check("a closed-unlanded PR has no lead") { r8[:lead_seconds].nil? }

  # --- cannot decide: says so, never open and never closed.
  r9 = analyze(forge, 9, starts)
  check("a same-subject, different-patch commit on main is could-not-measure") { r9[:end_kind] == :unmeasured }
  check("the could-not-measure row says why") { r9[:unmeasured_reason].to_s.include?("DND-9: fix") }
  r11 = analyze(forge, 11, starts)
  check("a partly-landed PR is could-not-measure") { r11[:end_kind] == :unmeasured }
  check("the partial landing names the count") { r11[:unmeasured_reason].to_s.include?("1 of 2") }

  # --- the states that already worked still do.
  r12 = analyze(forge, 12, starts)
  check("an OPEN PR still reads as open") { r12[:end_kind] == :open }
  r13 = analyze(forge, 13, starts)
  check("a MERGED PR still ends at mergedAt") { r13[:merged] == "2026-09-29T06:30:00Z" && r13[:end_kind] == :merge }
  check("a MERGED PR names the forge merge") { r13[:landed_via] == "merge" }

  # --- DND-1491: custom PR #83's shape. Main edited a line inside the PR's
  #     diff context before the PR's change landed, so the landed commit's
  #     patch-id differs only by context. It is that PR's landing.
  r15 = analyze(forge, 15, starts)
  check("REGRESSION (DND-1491): a same-subject landing whose patch differs only in context is landed") do
    r15[:end_kind] == :merge && r15[:landed_via] == "push" && r15[:landed_commit] == o[:l15]
  end
  check("it is timed by the push that carried the landed commit") { r15[:merged] == "2026-09-29T10:45:30Z" }
  check("and names no could-not-measure reason for its commit") do
    r15.key?(:landing_commit_unmeasured) && r15[:landing_commit_unmeasured].nil?
  end
  check("a same-subject commit with a DIFFERENT change still reads could-not-measure") do
    r9[:end_kind] == :unmeasured && r9[:landed_commit].nil?
  end
  check("its reason names the base commit it clashed with") { r9[:unmeasured_reason].to_s.include?(o[:y9][0, 12]) }

  # --- DND-1491, the class: every row has a landed commit, or says why not.
  check("REGRESSION (DND-1491): a could-not-measure row names why it has no landed commit") do
    r9[:landing_commit_unmeasured].to_s.include?("could not be decided") &&
      r9[:landing_commit_unmeasured].to_s.include?("DND-9: fix")
  end
  check("a closed-unlanded row names why it has no landed commit") do
    r8[:landing_commit_unmeasured] == "it closed without landing on the base branch"
  end
  check("an open row names why it has no landed commit") do
    r12[:landing_commit_unmeasured] == "it is open: it has not landed"
  end
  check("a landed row carries its commit and no reason") do
    [r7, r10, r13, r14].all? do |r|
      (r[:landed_commit] || r[:merge_commit]) && r.key?(:landing_commit_unmeasured) && r[:landing_commit_unmeasured].nil?
    end
  end
  r16 = analyze(forge, 16, starts)
  check("a MERGED PR the forge gave no merge commit for names why, never an empty key") do
    r16[:merge_commit].nil? && r16[:landing_commit_unmeasured] == "the forge gave no merge commit (mergeCommit)"
  end
  check("every analysed row has a landed commit XOR a reason for its absence") do
    [r7, r8, r9, r10, r11, r12, r13, r14, r15, r16].all? do |r|
      no_commit = (r[:landed_commit] || r[:merge_commit]).nil?
      r.key?(:landing_commit_unmeasured) && no_commit != r[:landing_commit_unmeasured].nil?
    end
  end
  check("no probe failed on a readable fixture") { !ProbeFailures.any? }

  # --- a landing probe that cannot run is a probe failure, never "open".
  ProbeFailures.reset!
  cut_off = fresh_clone(o, root, "cut-off")
  sh_git(cut_off, "remote", "set-url", "origin", File.join(root, "no-such-origin.git"))
  rb = analyze(forge_over(o, views, dir: cut_off), 7, starts)
  check("a landing probe whose fetch fails is recorded as a failed probe") { ProbeFailures.any? }
  check("and the row does not read as open") { rb.nil? || rb[:end_kind] != :open }
  check("and the row says it could not measure") { rb.nil? || rb[:end_kind] == :unmeasured }
  ProbeFailures.reset!
  broken_log = forge_over(o, views, dir: o[:work])
  broken_log.define_singleton_method(:base_pushes) { |_b| ProbeFailures.record("gh api activity", "HTTP 502") }
  rl = analyze(broken_log, 7, starts)
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
  ctx = lambda do |pr_pid0, main_subject|
    LeadTime.classify_landing(pr_only: [{ pid: "pr", pid0: pr_pid0, subject: "DND-1: x" }], combined_pid: "pr",
                              main: [{ sha: "m1", pid: "other", pid0: "z0", subject: main_subject }])
  end
  check("a context-only difference under the same subject is landed (DND-1491)") do
    ctx.call("z0", "DND-1: x") == { status: :landed, sha: "m1" }
  end
  check("the same change under ANOTHER subject is could-not-measure, never closed") do
    c = ctx.call("z0", "DND-2: y")
    c[:status] == :unknown && c[:reason].include?("m1")
  end
  check("a same-subject commit whose change differs is still could-not-measure") do
    ctx.call("q0", "DND-1: x")[:status] == :unknown
  end
  check("a commit with no zero-context patch-id never matches on it") do
    LeadTime.classify_landing(pr_only: [{ pid: "pr", pid0: nil, subject: "DND-1: x" }], combined_pid: "pr",
                              main: [{ sha: "m1", pid: "other", pid0: nil, subject: "DND-1: x" }])[:status] == :unknown
  end
  two = lambda do |main|
    LeadTime.classify_landing(pr_only: [{ pid: "a", pid0: "a0", subject: "DND-1: one" },
                                        { pid: "b", pid0: "b0", subject: "DND-1: two" }],
                              combined_pid: "ab", main: main)
  end
  check("a mixed rebase lands: one commit by patch-id, one with only its context changed") do
    two.call([{ sha: "mb", pid: "other", pid0: "b0", subject: "DND-1: two" },
              { sha: "ma", pid: "a", pid0: "a0", subject: "DND-1: one" }]) == { status: :landed, sha: "mb" }
  end
  check("only one commit on main, by either tier, is a partial landing, never closed") do
    c = two.call([{ sha: "mb", pid: "other", pid0: "b0", subject: "DND-1: two" }])
    c[:status] == :unknown && c[:reason].include?("1 of 2")
  end
  check("one base commit never carries two request commits") do
    two.call([{ sha: "mx", pid: "a", pid0: "a0", subject: "DND-1: one" }])[:status] == :unknown
  end
  check("a subject two base commits share never pairs by zero-context patch-id, and the reason says so") do
    c = LeadTime.classify_landing(pr_only: [{ pid: "pr", pid0: "z0", subject: "fix typo" }], combined_pid: "pr",
                                  main: [{ sha: "m1", pid: "o1", pid0: "z0", subject: "fix typo" },
                                         { sha: "m2", pid: "o2", pid0: "y0", subject: "fix typo" }])
    c[:status] == :unknown && c[:reason].include?("2 base commits share that subject") &&
      !c[:reason].include?("another subject")
  end
  check("the another-subject reason is kept for a truly different subject") do
    ctx.call("z0", "DND-2: y")[:reason].include?("under another subject")
  end
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

  # --- presentation: could-not-measure and closed are named on the row.
  out = capture_row(r9)
  check("a could-not-measure row prints 'could not measure'") { out.include?("could not measure") }
  check("a closed row prints via=closed") { capture_row(r8).include?("via=closed") }
  # --- DND-1490: a PR row carries its own head (the gated head), apart from
  #     the commit the forge or the push landed.
  check("a MERGED PR row carries the PR head beside the forge's merge commit") do
    r13[:head_commit] == o[:p8] && r13[:merge_commit] == o[:c1] && r13[:head_commit_unmeasured].nil?
  end
  check("a push-landed PR row carries its PR head too") { r7[:head_commit] == o[:p7] && r7[:landed_commit] == o[:p7_landed] }
  check("a landed-by-push row prints its landing") do
    capture_row(r7).include?("landed by push #{o[:p7_landed][0, 8]}") && !capture_row(r13).include?("landed by push")
  end
end

# ---------------------------------------------------------------------------
# DND-1318: the START is the ticket's move to In Progress (captain dispatch),
# read from the DND Tickets "In Progress at" date. Owner decision, Cody,
# 2026-09-30 ~04:05Z: lead time = captain dispatch -> landed on main.
# ---------------------------------------------------------------------------

# PR #129's shape (DND-1203): the captain was dispatched 02:41Z, squashed its
# work into one commit authored 03:06:00Z, and the PR merged 03:27:17Z. The old
# start (the earliest commit) read lead=21m 19s; the dispatch start reads 46m 17s.
pr129 = { "number" => 129, "title" => "DND-1203: suite-reaper repro execs the real ruby",
          "headRefName" => "dnd-1203-suite-reaper-worktree-time", "state" => "MERGED",
          "mergedAt" => "2026-09-30T03:27:17Z", "closedAt" => "2026-09-30T03:27:17Z",
          "baseRefName" => "main", "headRefOid" => "h129", "mergeCommit" => { "oid" => "m129" },
          "commits" => [{ "authoredDate" => "2026-09-30T03:05:58Z", "committedDate" => "2026-09-30T03:05:58Z" }] }
gh129 = GitHubForge.new(".")
gh129.define_singleton_method(:run_json) do |cmd, _dir|
  next [] if cmd[1] == "run"

  pr129
end

ProbeFailures.reset!
stamped = NotionStart.new(FakeNotion.new(1203 => at_prop("2026-09-30T02:41:00.000Z")))
r129 = analyze(gh129, 129, stamped)
check("the start is the ticket's move to In Progress, not the squashed commit (DND-1318)") do
  r129[:start] == "2026-09-30T02:41:00Z"
end
check("the lead runs from dispatch to landing: 46m 17s, not 21m 19s") { r129[:lead_seconds] == (46 * 60) + 17 }
check("the row names its measured start") { r129[:start_source] == "DND-1203 In Progress at" }
check("the earliest commit is still reported, as first_commit") { r129[:first_commit] == "2026-09-30T03:05:58Z" }
check("the human row names the start source") { capture_row(r129).include?("start=DND-1203 In Progress at") }

# --- DND-1490: a head the forge did not give, or gave malformed, is a named
#     could-not-measure: head_commit null with a reason, never "".
check("a head that is not a commit sha is refused, with the reason") do
  r129[:head_commit].nil? && r129[:head_commit_unmeasured] == 'the forge\'s head commit (headRefOid) "h129" is not a commit sha'
end
gh_nohead = GitHubForge.new(".")
gh_nohead.define_singleton_method(:run_json) do |cmd, _dir|
  next [] if cmd[1] == "run"

  pr129.merge("headRefOid" => nil)
end
r_nohead = analyze(gh_nohead, 129, stamped)
check("a head the forge did not give is null with a reason") do
  r_nohead[:head_commit].nil? && r_nohead[:head_commit_unmeasured] == "the forge gave no head commit (headRefOid)"
end
check("an empty head reads the same as none, never an empty sha") do
  h, why = LeadTime.head_commit("", "headRefOid")
  h.nil? && why == "the forge gave no head commit (headRefOid)"
end
check("a full sha is the head, with no reason") { LeadTime.head_commit("ab" * 20, "sha") == ["ab" * 20, nil] }
check("a SHA-256 object name is a head too") { LeadTime.head_commit("cd" * 32, "sha") == ["cd" * 32, nil] }
check("an uppercase sha is refused: receipts are keyed lowercase, it would join nothing") do
  LeadTime.head_commit("AB" * 20, "sha")[0].nil?
end

gl = GitLabForge.allocate
gl.instance_variable_set(:@dir, ".")
gl.instance_variable_set(:@proj, "group%2Frepo")
gl_mr = { "iid" => 5, "title" => "DND-1203: t", "source_branch" => "dnd-1203-b", "state" => "merged",
          "merged_at" => "2026-09-30T03:27:17Z", "closed_at" => nil, "sha" => "ef" * 20,
          "merge_commit_sha" => nil, "squash_commit_sha" => "12" * 20 }
gl.define_singleton_method(:api) do |path|
  next gl_mr if path.end_with?("/merge_requests/5")
  next [] if path.include?("/commits") || path.include?("/pipelines")

  raise "unexpected glab call: #{path}"
end
r_gl = analyze(gl, 5, stamped)
check("a GitLab MR row carries the MR head (sha) beside its squash commit") do
  r_gl[:head_commit] == "ef" * 20 && r_gl[:merge_commit] == "12" * 20 && r_gl[:head_commit_unmeasured].nil?
end
check("a merged GitLab MR's commit carries no reason (DND-1491)") do
  r_gl.key?(:landing_commit_unmeasured) && r_gl[:landing_commit_unmeasured].nil?
end
gl_mr["sha"] = nil
check("a GitLab MR with no head says so") do
  analyze(gl, 5, stamped)[:head_commit_unmeasured] == "the forge gave no head commit (sha)"
end
gl_mr["squash_commit_sha"] = nil
check("a merged GitLab MR the forge gave no commit for names why (DND-1491)") do
  r = analyze(gl, 5, stamped)
  r[:merge_commit].nil? &&
    r[:landing_commit_unmeasured] == "the forge gave no merge commit (merge_commit_sha, squash_commit_sha, sha)"
end
gl_mr.merge!("state" => "closed", "merged_at" => nil, "closed_at" => "2026-09-30T03:27:17Z", "sha" => "ef" * 20)
check("a closed-unmerged GitLab MR names why it has no landed commit (DND-1491)") do
  analyze(gl, 5, stamped)[:landing_commit_unmeasured].to_s.include?("landing by push is only detected on GitHub")
end

unstamped = NotionStart.new(FakeNotion.new(1203 => at_prop(nil)))
ru = analyze(gh129, 129, unstamped)
check("a ticket with no In Progress date has no lead (never the commit date)") { ru[:lead_seconds].nil? && ru[:start].nil? }
check("and says it could not measure the start, naming the ticket") do
  ru[:unmeasured_reason].to_s.include?("start") && ru[:unmeasured_reason].to_s.include?("DND-1203")
end
check("the unstamped row prints 'could not measure'") { capture_row(ru).include?("could not measure") }

absent = NotionStart.new(FakeNotion.new(1203 => :absent))
check("a database without the property says so") do
  analyze(gh129, 129, absent)[:unmeasured_reason].to_s.include?("has no 'In Progress at' property")
end
missing = NotionStart.new(FakeNotion.new({}))
check("a ticket that is not in the database says so") do
  analyze(gh129, 129, missing)[:unmeasured_reason].to_s.include?("no DND-1203 in DND Tickets")
end
dateonly = NotionStart.new(FakeNotion.new(1203 => at_prop("2026-09-30")))
check("a date with no time is not a start") do
  analyze(gh129, 129, dateonly)[:unmeasured_reason].to_s.include?("no time")
end
check("no Notion read failed on readable fixtures") { !ProbeFailures.any? }

# --- which ticket a PR is: its branch, else its title; never a guess.
check("the ticket comes from the branch") do
  LeadTime.ticket_ref(branch: "dnd-1203-suite-reaper", title: "x") == ["DND-1203", nil]
end
check("else from the title") { LeadTime.ticket_ref(branch: "shipwright-docs", title: "DND-77: y") == ["DND-77", nil] }
check("a PR naming no ticket has no start, and says so") do
  ref, why = LeadTime.ticket_ref(branch: "harness-gate-jobs", title: "harness-gate: --jobs N")
  ref.nil? && why.to_s.include?("names a ticket")
end
check("a branch naming two tickets is not a guess") do
  ref, why = LeadTime.ticket_ref(branch: "dnd-1-and-dnd-2", title: "t")
  ref.nil? && why.to_s.include?("DND-1") && why.to_s.include?("DND-2")
end
check("a word shaped like a ticket beside the real one is not a second ticket") do
  LeadTime.ticket_ref(branch: "dnd-897-contract-resync-404", title: "t") == ["DND-897", nil] &&
    LeadTime.ticket_ref(branch: "dnd-931-harness-ruby-34", title: "t") == ["DND-931", nil]
end
check("a branch naming only a non-DND word falls through to the title") do
  LeadTime.ticket_ref(branch: "shipwright/admiral-500-stage1", title: "DND-77: x") == ["DND-77", nil]
end
check("a lone non-DND ref is named in the reason") do
  ref, why = LeadTime.ticket_ref(branch: "athena/zq-2032-foo", title: "t")
  ref.nil? && why.include?("ZQ-2032")
end
check("a cron lane branch names no ticket") do
  LeadTime.ticket_ref(branch: "shipwright/run-20260930-1234", title: "shipwright: x")[0].nil?
end
check("lead-time holds no parser of its own: it is ai/lib/ticket_ref.rb (DND-1488)") do
  !LeadTime.const_defined?(:TICKET_REF_RE, false) &&
    LeadTime.refs_in("dnd-1-zq-22") == TicketRef.refs_in("dnd-1-zq-22") &&
    LeadTime.ticket_ref(branch: "zq-9-x", title: nil, prefixes: ["ZQ"]) ==
      TicketRef.ticket_ref(branch: "zq-9-x", title: nil, prefixes: ["ZQ"])
end
check("the start query goes to DND Tickets by ID") do
  fake = FakeNotion.new(1203 => at_prop("2026-09-30T02:41:00.000Z"))
  NotionStart.new(fake).lookup("DND-1203")
  m, path, body = fake.calls.first
  m == :post && path == "/v1/data_sources/#{NextMissionNotion::TICKETS_DATA_SOURCE}/query" &&
    body.dig("filter", "property") == "ID"
end
check("a stamp with no UTC offset is not read as local time") do
  _at, why = NotionStart.new(FakeNotion.new(1203 => at_prop("2026-09-30T02:41:00.000"))).lookup("DND-1203")
  why.to_s.include?("no UTC offset")
end
check("a non-date property is not a start") do
  _at, why = NotionStart.new(FakeNotion.new(1203 => { "type" => "rich_text", "rich_text" => [] })).lookup("DND-1203")
  why.to_s.include?("not a date")
end
late = NotionStart.new(FakeNotion.new(1203 => at_prop("2026-09-30T04:00:00.000Z")))
rlate = analyze(gh129, 129, late)
check("a stamp after the landing is could-not-measure, never a negative lead") do
  rlate[:lead_seconds].nil? && rlate[:code_seconds].nil? && rlate[:unmeasured_reason].to_s.include?("after the landing")
end
nondnd = NotionStart.new(FakeNotion.new({}))
check("a ticket outside the DND database is could-not-measure") do
  _at, why = nondnd.lookup("ZQ-12")
  why.to_s.include?("ZQ-12") && nondnd.instance_variable_get(:@transport).calls.empty?
end
pr_none = pr129.merge("headRefName" => "harness-gate-jobs", "title" => "harness-gate: --jobs N")
gh_none = GitHubForge.new(".")
gh_none.define_singleton_method(:run_json) { |cmd, _d| cmd[1] == "run" ? [] : pr_none }
check("a PR with no ticket reads could-not-measure, not a commit-date lead") do
  r = analyze(gh_none, 129, stamped)
  r[:lead_seconds].nil? && r[:unmeasured_reason].to_s.include?("names a ticket")
end

# --- a Notion read that cannot run is a failed probe (SCAN INCOMPLETE).
ProbeFailures.reset!
down = NotionStart.new(FakeNotion.new({}, "HTTP 502 on POST /v1/data_sources/x/query"))
rd = analyze(gh129, 129, down)
check("a Notion failure is a recorded probe failure") { ProbeFailures.any? }
check("and the row has no lead") { rd[:lead_seconds].nil? }
ProbeFailures.reset!
notoken = NotionStart.new(nil, missing_reason: "no notion-personal token at /nowhere")
analyze(gh129, 129, notoken)
check("no Notion token is a recorded probe failure, not an empty answer") do
  ProbeFailures.list.any? { |f| f[:detail].include?("no notion-personal token") }
end
ProbeFailures.reset!
check("one lookup per ticket per run") do
  fake = FakeNotion.new(1203 => at_prop("2026-09-30T02:41:00.000Z"))
  s = NotionStart.new(fake)
  analyze(gh129, 129, s)
  analyze(gh129, 129, s)
  fake.calls.size == 1
end

# ---------------------------------------------------------------------------
# DND-1341: a work-tracker ticket's start, through the private overlay's work
# tracker. Every work value here is synthetic (prefix ZQ, a zero data source).
# ---------------------------------------------------------------------------

PR129 = pr129
WORK_T = DispatchTrackers.work_from(
  data_source: "0000aaaa-1111-2222-3333-444455556666", prefix: "ZQ", property: "Synthetic stamp",
  first_dispatch_from: '["Todo","Backlog"]',
).tracker

# A work-tracker transport: ticket number -> its stamp (ISO or nil).
class FakeWorkNotion
  attr_reader :calls

  def initialize(stamps)
    @stamps = stamps
    @calls = []
  end

  def call(method, path, body = nil)
    @calls << [method, path, body]
    n = body.dig("filter", "unique_id", "equals")
    return { "results" => [] } unless @stamps.key?(n)

    props = { "Synthetic stamp" => at_prop(@stamps[n]) }
    { "results" => [{ "id" => "w-#{n}", "properties" => props }] }
  end
end

def gh_pr(branch, title, base: PR129)
  view = base.merge("headRefName" => branch, "title" => title)
  gh = GitHubForge.new(".")
  gh.define_singleton_method(:run_json) { |cmd, _d| cmd[1] == "run" ? [] : view }
  gh
end

def starts_with(work_result, dnd: NotionStart.new(FakeNotion.new(1203 => at_prop("2026-09-30T02:41:00.000Z"))))
  asked = []
  s = TicketStarts.new(dnd: dnd, work: lambda {
    asked << 1
    work_result
  })
  [s, asked]
end

ProbeFailures.reset!
work_fake = FakeWorkNotion.new(2032 => "2026-09-30T02:00:00.000Z")
ok_res = DispatchTrackers::Resolution.new(tracker: WORK_T, reason: nil, fault: false)
ts, asked = starts_with([NotionStart.new(work_fake, tracker: WORK_T), ok_res])
rw = analyze(gh_pr("athena/ZQ-2032-foo", "feat: x (ZQ-2032)"), 129, ts)
check("a work ticket's start is its work-tracker stamp (DND-1341)") { rw[:start] == "2026-09-30T02:00:00Z" }
check("its lead runs from that dispatch to the landing") do
  rw[:lead_seconds] == Time.iso8601("2026-09-30T03:27:17Z") - Time.iso8601("2026-09-30T02:00:00Z")
end
check("the row names the overlay's property as its start source") { rw[:start_source] == "ZQ-2032 Synthetic stamp" }
check("the start query goes to the overlay's work data source") do
  m, path, body = work_fake.calls.first
  m == :post && path == "/v1/data_sources/#{WORK_T.data_source}/query" && body.dig("filter", "unique_id", "equals") == 2032
end
check("a lower-case work branch still names the ticket") do
  r = analyze(gh_pr("agent/zq-2032-move-floor", "t"), 129, ts)
  r[:start_source] == "ZQ-2032 Synthetic stamp"
end
check("a work ticket that is not stamped is could-not-measure, naming the ticket and property") do
  s2, = starts_with([NotionStart.new(FakeWorkNotion.new(7 => nil), tracker: WORK_T), ok_res])
  r = analyze(gh_pr("athena/ZQ-7-x", "t"), 129, s2)
  r[:lead_seconds].nil? && r[:unmeasured_reason].include?("ZQ-7") && r[:unmeasured_reason].include?("Synthetic stamp")
end
check("the overlay is resolved once per run, not per row") { asked.size == 1 }
check("no probe failed on readable fixtures") { !ProbeFailures.any? }

dnd_only, asked_dnd = starts_with(nil)
rd2 = analyze(gh129, 129, dnd_only)
check("a DND-only request never reads the overlay") { asked_dnd.empty? && rd2[:start] == "2026-09-30T02:41:00Z" }
check("nor does a request that names no ticket at all") do
  s3, a3 = starts_with(nil)
  analyze(gh_pr("harness-gate-jobs", "harness-gate: --jobs N"), 129, s3)
  a3.empty?
end
check("a ticket-shaped word that is neither tracker's does not displace the DND ticket") do
  s4, = starts_with([NotionStart.new(work_fake, tracker: WORK_T), ok_res])
  analyze(gh_pr("shipwright/admiral-500-stage1", "DND-1203: x"), 129, s4)[:start] == "2026-09-30T02:41:00Z"
end
check("a branch naming a DND and a work ticket is not a guess") do
  s5, = starts_with([NotionStart.new(work_fake, tracker: WORK_T), ok_res])
  r = analyze(gh_pr("dnd-1203-zq-2032", "t"), 129, s5)
  r[:lead_seconds].nil? && r[:unmeasured_reason].include?("several")
end

ProbeFailures.reset!
absent_res = DispatchTrackers::Resolution.new(
  tracker: nil, fault: false,
  reason: "private-overlay: ABSENT: key=notion.work.tickets_data_source probed=/nowhere. Fix: unavailable here",
)
s6, = starts_with([nil, absent_res])
ra = analyze(gh_pr("athena/ZQ-2032-foo", "t"), 129, s6)
check("with no overlay a work ticket is could-not-measure, carrying the overlay's line") do
  ra[:lead_seconds].nil? && ra[:unmeasured_reason].include?("work tracker is unavailable") &&
    ra[:unmeasured_reason].include?("ABSENT") && ra[:unmeasured_reason].include?("ZQ-2032")
end
check("an absent overlay is this machine's state, not a failed probe") { !ProbeFailures.any? }

ProbeFailures.reset!
fault_res = DispatchTrackers::Resolution.new(
  tracker: nil, fault: true,
  reason: "private-overlay: KEY_NOT_FOUND: key=notion.work.ticket_prefix root=/r. Fix: add it",
)
s7, = starts_with([nil, fault_res])
analyze(gh_pr("athena/ZQ-2032-foo", "t"), 129, s7)
analyze(gh_pr("athena/ZQ-2033-bar", "t"), 129, s7)
check("a present overlay missing a key is a failed probe (SCAN INCOMPLETE), recorded once") do
  ProbeFailures.list.count { |f| f[:cmd] == "private-overlay work tracker" } == 1 &&
    ProbeFailures.list.first[:detail].include?(".work.ticket_prefix")
end

ProbeFailures.reset!
s7b, = starts_with([nil, fault_res])
rn = analyze(gh_pr("fix-utf-8-decoding", "t"), 129, s7b)
check("a noise word with a broken overlay is a failed probe, and the row says why (never a silent no-ticket)") do
  ProbeFailures.list.any? { |f| f[:cmd] == "private-overlay work tracker" } &&
    rn[:unmeasured_reason].include?("work tracker is unavailable")
end

ProbeFailures.reset!
nowork_token = NotionStart.new(nil, tracker: WORK_T, missing_reason: "no Notion token for the work tracker at /x/notion-api-token")
s8, = starts_with([nowork_token, ok_res])
analyze(gh_pr("athena/ZQ-2032-foo", "t"), 129, s8)
check("no work token is a failed probe naming the work tracker") do
  ProbeFailures.list.any? { |f| f[:cmd].include?("the work tracker") && f[:detail].include?("notion-api-token") }
end
ProbeFailures.reset!

# ---------------------------------------------------------------------------
# DND-1009: every landing on the base branch is measured, including a direct
# push with no PR; --meta reports the cursor independent of --slow; a
# date-only --since is a date, and anything else unparseable is refused.
# ---------------------------------------------------------------------------

def sha_of(c) = c * 40

def push_of(at, after, commits, type: "push", before: sha_of("0"))
  { at: at, type: type, before: before, after: after, commits: commits }
end

def cmt(sha, subject, authored = "2026-09-30T00:00:00Z")
  { sha: sha, subject: subject, authored: authored }
end

# --- build_push_rows (pure) -----------------------------------------------
check("REGRESSION: a direct push with no PR gives a landing row for its ticket") do
  rows = LeadTime.build_push_rows(
    pushes: [push_of("2026-09-30T01:00:30Z", sha_of("a"), [cmt(sha_of("a"), "DND-9001: x")])],
    covered: [], prefixes: ["DND"],
  )
  rows.size == 1 && rows[0][:ticket] == "DND-9001" && rows[0][:landed_commit] == sha_of("a") &&
    rows[0][:at] == "2026-09-30T01:00:30Z" && rows[0][:unmeasured].nil?
end
check("a push of three commits naming two tickets gives two rows sharing the landing") do
  commits = [cmt(sha_of("d"), "chore: tidy"), cmt(sha_of("c"), "DND-9002: b"), cmt(sha_of("b"), "DND-9001: a")]
  rows = LeadTime.build_push_rows(pushes: [push_of("2026-09-30T02:10:30Z", sha_of("d"), commits)],
                                  covered: [], prefixes: ["DND"])
  rows.map { |r| r[:ticket] }.sort == %w[DND-9001 DND-9002] &&
    rows.map { |r| [r[:at], r[:landed_commit]] }.uniq == [["2026-09-30T02:10:30Z", sha_of("d")]] &&
    rows.all? { |r| r[:commits] == [sha_of("d"), sha_of("c"), sha_of("b")] }
end
check("a push whose after sha is a listed PR's landed commit adds no row") do
  LeadTime.build_push_rows(pushes: [push_of("2026-09-30T04:00:30Z", sha_of("e"), [cmt(sha_of("e"), "DND-9003: y")])],
                           covered: [sha_of("e")], prefixes: ["DND"]).empty?
end
check("a push carrying a PR's landing plus a direct commit on top keeps the direct commit's ticket") do
  commits = [cmt(sha_of("f"), "DND-9004: tip"), cmt(sha_of("e"), "DND-9003: y"), cmt(sha_of("1"), "DND-9003: x")]
  rows = LeadTime.build_push_rows(pushes: [push_of("2026-09-30T04:00:30Z", sha_of("f"), commits)],
                                  covered: [sha_of("e")], prefixes: ["DND"])
  rows.map { |r| r[:ticket] } == ["DND-9004"] && rows[0][:commits] == [sha_of("f")]
end
check("an activity type it does not read is could-not-measure, never dropped") do
  rows = LeadTime.build_push_rows(pushes: [push_of("2026-09-30T06:30:30Z", sha_of("9"), nil, type: "merge_queue_merge")],
                                  covered: [], prefixes: ["DND"])
  rows.size == 1 && rows[0][:unmeasured].include?("merge_queue_merge")
end
check("a branch creation in the window is read as a push of its after commit") do
  rows = LeadTime.build_push_rows(
    pushes: [push_of("2026-09-30T00:10:00Z", sha_of("a"), [cmt(sha_of("a"), "DND-9001: x")], type: "branch_creation")],
    covered: [], prefixes: ["DND"],
  )
  rows.map { |r| r[:ticket] } == ["DND-9001"]
end
check("a push naming no ticket gives one row whose start says no ticket was named") do
  rows = LeadTime.build_push_rows(pushes: [push_of("2026-09-30T03:00:30Z", sha_of("5"), [cmt(sha_of("5"), "tidy docs")])],
                                  covered: [], prefixes: ["DND"])
  rows.size == 1 && rows[0][:ticket].nil? &&
    rows[0][:start_unmeasured] == "no ticket in the pushed commits' subjects"
end
check("a push naming only another tracker's ticket says which ref it saw") do
  rows = LeadTime.build_push_rows(pushes: [push_of("2026-09-30T03:00:30Z", sha_of("5"), [cmt(sha_of("5"), "ZQ-12: w")])],
                                  covered: [], prefixes: ["DND"])
  rows.size == 1 && rows[0][:ticket].nil? && rows[0][:start_unmeasured].include?("ZQ-12")
end
check("a force push gives a could-not-measure row: force push to base") do
  rows = LeadTime.build_push_rows(pushes: [push_of("2026-09-30T05:00:30Z", sha_of("6"), nil, type: "force_push")],
                                  covered: [], prefixes: ["DND"])
  rows.size == 1 && rows[0][:unmeasured] == "force push to base" && rows[0][:landed_commit] == sha_of("6")
end
check("a push whose commits could not be read is could-not-measure, never no-ticket") do
  rows = LeadTime.build_push_rows(pushes: [push_of("2026-09-30T05:00:30Z", sha_of("7"), nil)],
                                  covered: [], prefixes: ["DND"])
  rows.size == 1 && rows[0][:unmeasured].to_s.include?("could not be read")
end
check("a PR merge no listed PR claims is could-not-measure, never silently dropped") do
  rows = LeadTime.build_push_rows(pushes: [push_of("2026-09-30T06:00:30Z", sha_of("8"), nil, type: "pr_merge")],
                                  covered: [], prefixes: ["DND"])
  rows.size == 1 && rows[0][:unmeasured].to_s.include?("no listed PR")
end
check("a PR merge a listed PR claims adds no row") do
  LeadTime.build_push_rows(pushes: [push_of("2026-09-30T06:00:30Z", sha_of("8"), nil, type: "pr_merge")],
                           covered: [sha_of("8")], prefixes: ["DND"]).empty?
end

# --- scan_meta (pure) -------------------------------------------------------
six = (1..6).map do |h|
  { pr: nil, landed_commit: sha_of(h.to_s), closed_at: "2026-09-30T0#{h}:00:00Z", lead_seconds: 600 }
end
check("STUCK-CURSOR regression: no row over --slow still advances scanned_through to the newest landing") do
  m = LeadTime.scan_meta(rows: six, kept: 0, failures: [])
  m == { scanned_through: "2026-09-30T06:00:00Z", landings: 6, kept: 0, incomplete: false }
end
check("an incomplete scan stops scanned_through before the first failed probe") do
  m = LeadTime.scan_meta(rows: six, kept: 0, failures: [{ cmd: "git log", detail: "x", at: "2026-09-30T04:00:00Z" }])
  m[:incomplete] == true && m[:scanned_through] == "2026-09-30T03:00:00Z"
end
check("a failed probe tied to no landing gives no scanned_through at all") do
  m = LeadTime.scan_meta(rows: six, kept: 0, failures: [{ cmd: "gh pr list", detail: "401", at: nil }])
  m[:incomplete] == true && m[:scanned_through].nil?
end
check("two tickets on one push are one landing") do
  rows = [{ pr: nil, landed_commit: sha_of("d"), closed_at: "2026-09-30T02:10:30Z" },
          { pr: nil, landed_commit: sha_of("d"), closed_at: "2026-09-30T02:10:30Z" }]
  LeadTime.scan_meta(rows: rows, kept: 2, failures: [])[:landings] == 1
end
check("an empty window has no scanned_through, not a fabricated one") do
  LeadTime.scan_meta(rows: [], kept: 0, failures: []) ==
    { scanned_through: nil, landings: 0, kept: 0, incomplete: false }
end

# --- parse_since (pure) -----------------------------------------------------
check("a date-only --since is 00:00:00Z that day") { LeadTime.parse_since("2026-09-30") == ["2026-09-30T00:00:00Z", nil] }
check("an RFC 3339 --since with an offset reads as UTC") do
  LeadTime.parse_since("2026-09-30T22:00:00+02:00") == ["2026-09-30T20:00:00Z", nil]
end
check("an RFC 3339 --since in Z is kept") { LeadTime.parse_since("2026-09-30T22:00:00Z") == ["2026-09-30T22:00:00Z", nil] }
check("'yesterday' is refused, naming the accepted forms") do
  at, why = LeadTime.parse_since("yesterday")
  at.nil? && why.include?("YYYY-MM-DD") && why.include?("RFC 3339")
end
check("a time with no zone is refused, not read as local time") { LeadTime.parse_since("2026-09-30T22:00:00")[0].nil? }
check("an impossible date is refused, not rolled over") { LeadTime.parse_since("2026-02-31")[0].nil? }

# --- the window scan over a real fixture repo (the manager) ----------------
#   main: a0 -> d1 (push 1) -> d2 d3 d4 (push 2) -> d5 (push 3) -> d6 (PR 31, push 6)
#   plus a force push and an unclaimed PR merge between pushes 3 and 6.
def build_push_fixture(root)
  origin = File.join(root, "push-origin.git")
  work = File.join(root, "push-work")
  FileUtils.mkdir_p(origin)
  sh_git(origin, "init", "-q", "--bare")
  sh_git(root, "clone", "-q", origin, work)
  o = { origin: origin }
  o[:a0] = commit_file(work, "a.txt", "a\n", "init", "2026-09-29T23:00:00Z")
  sh_git(work, "push", "-q", "origin", "HEAD:refs/heads/start")
  o[:d1] = commit_file(work, "b.txt", "1\n", "DND-9001: x", "2026-09-30T01:00:00Z")
  o[:d2] = commit_file(work, "c.txt", "2\n", "DND-9001: part a", "2026-09-30T02:00:00Z")
  o[:d3] = commit_file(work, "d.txt", "3\n", "DND-9002: part b", "2026-09-30T02:05:00Z")
  o[:d4] = commit_file(work, "e.txt", "4\n", "chore: tidy", "2026-09-30T02:10:00Z")
  o[:d5] = commit_file(work, "f.txt", "5\n", "tidy the docs", "2026-09-30T03:00:00Z")
  o[:d6] = commit_file(work, "g.txt", "6\n", "DND-9003: landed through its PR", "2026-09-30T04:00:00Z")
  sh_git(work, "push", "-q", "origin", "HEAD:refs/heads/main")
  sh_git(work, "push", "-q", "origin", "#{o[:d6]}:refs/pull/31/head")
  o[:work] = File.join(root, "push-checkout")
  sh_git(root, "clone", "-q", "--no-local", "--single-branch", "--branch", "start", origin, o[:work])
  o
end

def push_activity(o)
  e = ->(at, type, before, after) { { "timestamp" => at, "activity_type" => type, "ref" => "refs/heads/main",
                                      "before" => before, "after" => after } }
  [[e.call("2026-09-30T04:00:30Z", "push", o[:d5], o[:d6]),
    e.call("2026-09-30T03:40:30Z", "pr_merge", o[:d5], o[:d5]),
    e.call("2026-09-30T03:20:30Z", "force_push", o[:d4], o[:d5]),
    e.call("2026-09-30T03:00:30Z", "push", o[:d4], o[:d5])],
   [e.call("2026-09-30T02:10:30Z", "push", o[:d1], o[:d4]),
    e.call("2026-09-30T01:00:30Z", "push", o[:a0], o[:d1]),
    e.call("2026-09-29T23:00:30Z", "branch_creation", sha_of("0"), o[:a0])]]
end

def push_forge(o, fail_activity: false, pr_ticket: "9003")
  view = { "number" => 31, "title" => "DND-#{pr_ticket}: landed through its PR", "headRefName" => "dnd-#{pr_ticket}-b",
           "state" => "CLOSED", "mergedAt" => nil, "closedAt" => "2026-09-30T04:01:00Z", "baseRefName" => "main",
           "headRefOid" => o[:d6], "mergeCommit" => nil,
           "commits" => [{ "authoredDate" => "2026-09-30T04:00:00Z", "committedDate" => "2026-09-30T04:00:00Z" }] }
  listed = [{ "number" => 31, "mergedAt" => nil, "closedAt" => "2026-09-30T04:01:00Z", "state" => "CLOSED" }]
  act = push_activity(o)
  f = GitHubForge.new(o[:work])
  f.define_singleton_method(:run_json) do |cmd, _dir|
    next [] if cmd[1] == "run"
    next listed if cmd[1] == "pr" && cmd[2] == "list"
    next view if cmd[1] == "pr" && cmd[2] == "view"
    next({ "defaultBranchRef" => { "name" => "main" } }) if cmd[1] == "repo" && cmd[2] == "view"
    if cmd[1] == "api" && cmd.any? { |c| c.include?("/activity") }
      next ProbeFailures.record("gh api activity", "HTTP 502") if fail_activity

      next act
    end
    raise "unexpected gh call: #{cmd.inspect}"
  end
  f
end

def push_starts
  NotionStart.new(FakeNotion.new(9001 => at_prop("2026-09-30T00:30:00.000Z"),
                                 9002 => at_prop("2026-09-30T01:30:00.000Z"),
                                 9003 => at_prop("2026-09-30T03:30:00.000Z")))
end

def run_scan_captured(**kw)
  out = StringIO.new
  err = StringIO.new
  code = nil
  old_out = $stdout
  old_err = $stderr
  $stdout = out
  $stderr = err
  begin
    code = run_scan(**kw)
  rescue StandardError => e
    $failures << "the window scan ran (raised #{e.class}: #{e.message.lines.first.to_s.strip})"
  ensure
    $stdout = old_out
    $stderr = old_err
  end
  [code, out.string, err.string]
end

Dir.mktmpdir("lead-time-push") do |root|
  po = build_push_fixture(root)
  ProbeFailures.reset!
  meta_path = File.join(root, "meta.json")
  code, out, = run_scan_captured(repo: po[:work], since: "2026-09-30T00:00:00Z", slow_min: nil, as_json: true,
                                 meta_file: meta_path, forge: push_forge(po), starts: push_starts)
  rows = code&.zero? ? JSON.parse(out) : []
  by = ->(sha) { rows.select { |r| r["landed_commit"] == sha && r["pr"].nil? } }

  check("REGRESSION (manager): a direct push with no PR is a landing row (DND-1009)") do
    r = by.call(po[:d1]).first
    r && r["landed_via"] == "push" && r["pr"].nil? && r["merged"] == "2026-09-30T01:00:30Z" &&
      r["ticket"] == "DND-9001" && r["lead_seconds"] == (30 * 60) + 30 && r["commits"] == [po[:d1]]
  end
  check("the scan exits 0 on a readable fixture") { code&.zero? && !ProbeFailures.any? }
  check("a two-ticket push gives two rows, each timed from its own start") do
    rs = by.call(po[:d4]).sort_by { |r| r["ticket"] }
    rs.map { |r| r["ticket"] } == %w[DND-9001 DND-9002] &&
      rs.map { |r| r["lead_seconds"] } == [(100 * 60) + 30, (40 * 60) + 30] &&
      rs.all? { |r| r["commits"] == [po[:d4], po[:d3], po[:d2]] }
  end
  check("an unticketed push reads could-not-measure, naming the missing ticket") do
    r = rows.find { |x| x["landed_commit"] == po[:d5] && x["merged"] == "2026-09-30T03:00:30Z" }
    r && r["lead_seconds"].nil? && r["unmeasured_reason"].include?("no ticket in the pushed commits' subjects")
  end
  check("a force push reads could-not-measure: force push to base") do
    rows.any? { |x| x["unmeasured_reason"] == "force push to base" && x["merged"] == "2026-09-30T03:20:30Z" }
  end
  check("an unclaimed PR merge reads could-not-measure") do
    rows.any? { |x| x["merged"] == "2026-09-30T03:40:30Z" && x["unmeasured_reason"].to_s.include?("no listed PR") }
  end
  check("the PR-landed push is the PR's row only, never counted twice") do
    rows.count { |x| x["landed_commit"] == po[:d6] } == 1 && rows.find { |x| x["pr"] == 31 }
  end
  check("DND-1491: every scanned row has a landed commit XOR a named reason for its absence") do
    !rows.empty? && rows.all? do |r|
      no_commit = (r["landed_commit"] || r["merge_commit"]).nil?
      r.key?("landing_commit_unmeasured") && no_commit != r["landing_commit_unmeasured"].nil?
    end
  end
  check("the meta file names the newest landing, the landing count and kept") do
    m = JSON.parse(File.read(meta_path))
    m == { "scanned_through" => "2026-09-30T04:01:00Z", "landings" => 6, "kept" => 7, "incomplete" => false }
  end
  check("the human table prints a direct push as via=push") do
    ProbeFailures.reset!
    _c, o_tbl, e = run_scan_captured(repo: po[:work], since: "2026-09-30T00:00:00Z", slow_min: nil, as_json: false,
                                     meta_file: nil, forge: push_forge(po), starts: push_starts)
    line = o_tbl.lines.find { |l| l.include?("DND-9001: x") }
    line&.start_with?("push ") && line.include?("via=push") && e.include?("forge=github")
  end

  # --- a push whose range cannot be read is a failed probe tied to that push:
  #     the cursor stops at the landing before it.
  ProbeFailures.reset!
  cut_meta = File.join(root, "cut-meta.json")
  cut = push_forge(po)
  act_cut = push_activity(po).map { |page| page.map(&:dup) }
  act_cut[1][0]["before"] = "dead" * 10
  base_run = cut.method(:run_json)
  cut.define_singleton_method(:run_json) do |cmd, dir|
    cmd[1] == "api" && cmd.any? { |c| c.include?("/activity") } ? act_cut : base_run.call(cmd, dir)
  end
  code_c, = run_scan_captured(repo: po[:work], since: "2026-09-30T00:00:00Z", slow_min: nil, as_json: true,
                              meta_file: cut_meta, forge: cut, starts: push_starts)
  check("an unreadable push range ends SCAN INCOMPLETE, and the cursor stops before that push") do
    m = JSON.parse(File.read(cut_meta))
    code_c == 3 && m["incomplete"] == true && m["scanned_through"] == "2026-09-30T01:00:30Z"
  end

  # --- a Notion failure cached by one landing is tied to every landing it
  #     leaves without a start. PR 31 (closed 04:01) is analysed first and
  #     names DND-9001; the 01:00:30 push names it too and reads the cached
  #     failure. Tied to PR 31 only, the cursor would pass the 01:00:30 push.
  ProbeFailures.reset!
  flaky_meta = File.join(root, "flaky-meta.json")
  down_9001 = Class.new(FakeNotion) do
    def call(method, path, body = nil)
      raise NextMissionNotion::ReadError, "HTTP 502" if body.dig("filter", "unique_id", "equals") == 9001

      super
    end
  end
  stalled = NotionStart.new(down_9001.new(9002 => at_prop("2026-09-30T01:30:00.000Z"),
                                          9003 => at_prop("2026-09-30T03:30:00.000Z")))
  run_scan_captured(repo: po[:work], since: "2026-09-30T00:00:00Z", slow_min: nil, as_json: true,
                    meta_file: flaky_meta, forge: push_forge(po, pr_ticket: "9001"), starts: stalled)
  check("a cached ticket failure stops the cursor before the EARLIEST landing that read it") do
    m = JSON.parse(File.read(flaky_meta))
    m["incomplete"] == true && m["scanned_through"].nil?
  end
  check("the cached failure is recorded for each landing it touched") do
    ProbeFailures.list.count { |f| f[:cmd].include?("DND-9001") } == 3
  end

  ProbeFailures.reset!
  notoken_meta = File.join(root, "notoken-meta.json")
  run_scan_captured(repo: po[:work], since: "2026-09-30T00:00:00Z", slow_min: nil, as_json: true,
                    meta_file: notoken_meta, forge: push_forge(po),
                    starts: NotionStart.new(nil, missing_reason: "no token at /nowhere"))
  check("no Notion token is window-wide: no scanned_through, never a partial cursor") do
    m = JSON.parse(File.read(notoken_meta))
    m["incomplete"] == true && m["scanned_through"].nil? && ProbeFailures.list.all? { |f| f[:at].nil? }
  end

  ProbeFailures.reset!
  slow_meta = File.join(root, "slow-meta.json")
  run_scan_captured(repo: po[:work], since: "2026-09-30T00:00:00Z", slow_min: 90, as_json: true,
                    meta_file: slow_meta, forge: push_forge(po), starts: push_starts)
  check("--slow filters rows but not the meta cursor") do
    m = JSON.parse(File.read(slow_meta))
    m["scanned_through"] == "2026-09-30T04:01:00Z" && m["kept"] < 7
  end

  # --- an activity log that cannot be read is SCAN INCOMPLETE, never empty.
  ProbeFailures.reset!
  bad_meta = File.join(root, "bad-meta.json")
  code_b, out_b, err_b = run_scan_captured(repo: po[:work], since: "2026-09-30T00:00:00Z", slow_min: nil,
                                           as_json: true, meta_file: bad_meta,
                                           forge: push_forge(po, fail_activity: true), starts: push_starts)
  check("an unreadable activity log ends SCAN INCOMPLETE (exit 3), no rows on stdout") do
    code_b == 3 && out_b.empty? && err_b.include?("SCAN INCOMPLETE")
  end
  check("and the meta file says incomplete, with no fabricated row list or cursor") do
    m = JSON.parse(File.read(bad_meta))
    m["incomplete"] == true && m["scanned_through"].nil? && !m.key?("rows")
  end
  ProbeFailures.reset!
end

if $failures.empty?
  puts "lead_time_test: PASS (#{$checks} checks)"
  exit 0
end
warn "lead_time_test: FAIL (#{$failures.size} of #{$checks})"
$failures.each { |f| warn "  - #{f}" }
warn "Fix: make ai/bin/lead-time judge a CLOSED GitHub PR's landing by its change " \
     "(patch-id) on the base branch, timed by the push that carried it; a PR it cannot " \
     "place must read 'could not measure', and a closed-unlanded one 'closed', never 'open'. " \
     "A window scan must also list every direct push to the base branch (one row per ticket its " \
     "commit subjects name, deduped against PR rows), write --meta's scanned_through before --slow, " \
     "and parse --since as YYYY-MM-DD or zoned RFC 3339 (DND-1009). A same-subject base commit " \
     "whose zero-context (-U0) patch-id matches is that commit's landing, and every row carries " \
     "landed_commit or merge_commit, or landing_commit_unmeasured naming why not (DND-1491)."
exit 1
