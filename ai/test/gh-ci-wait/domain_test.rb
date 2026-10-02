# frozen_string_literal: true

# Deterministic suite for ai/lib/gh_ci_wait.rb (DOMAIN, DND-1708/DND-1706):
# reading one `gh api -i` response, judging CI state from it, and deciding how
# long to wait before the next read. Run by ai/test/gh-ci-wait/self-test.sh,
# which harness-gate discovers.
#
# Every input is a value (response text, a Time). No process, file or clock
# access. Functional only (DND-1222). Repos, shas and ids are synthetic.

require "json"
require_relative "../../lib/gh_ci_wait"

W = GhCiWait
NOW = Time.utc(2026, 10, 2, 8, 0, 0)
SHA = "a" * 40
OTHER = "b" * 40

$failures = []
$checks = 0

def check(desc)
  $checks += 1
  $failures << desc unless yield
rescue StandardError => e
  $failures << "#{desc} (raised #{e.class}: #{e.message})"
end

def raised
  yield
  nil
rescue W::Usage => e
  e
end

# A `gh api -i` stdout: status line, headers, blank line, body.
def http(status, headers = {}, body = "{}")
  reason = { 200 => "OK", 403 => "Forbidden", 404 => "Not Found", 401 => "Unauthorized",
             422 => "Unprocessable Entity", 429 => "Too Many Requests", 502 => "Bad Gateway" }[status]
  lines = ["HTTP/2.0 #{status} #{reason}"] + headers.map { |k, v| "#{k}: #{v}" }
  lines.join("\r\n") + "\r\n\r\n" + body
end

def run_row(id:, name:, sha:, status:, conclusion: nil, created: "2026-10-02T07:00:00Z", path: nil)
  { "id" => id, "name" => name, "head_sha" => sha, "status" => status, "conclusion" => conclusion,
    "created_at" => created, "path" => path || ".github/workflows/#{name.downcase.tr(' ', '-')}.yml" }
end

def check_row(name, status, conclusion = nil)
  { "name" => name, "status" => status, "conclusion" => conclusion }
end

def checks_body(rows, total: nil)
  JSON.generate("total_count" => total || rows.size, "check_runs" => rows)
end

# ---- P: parse one response ------------------------------------------------
check("P1 a 200 with a JSON body is ok, body parsed") do
  r = W.parse(stdout: http(200, {}, '{"x":1}'), stderr: "", now: NOW)
  r.kind == :ok && r.body == { "x" => 1 } && r.status == 200
end
check("P2 a 200 whose body is not JSON is an error, never ok or empty") do
  r = W.parse(stdout: http(200, {}, "<html>"), stderr: "", now: NOW)
  r.kind == :error && r.detail.include?("not JSON")
end
check("P3 primary limit: 403 with remaining 0 is rate_limited until the reset header") do
  reset = NOW + 1800
  r = W.parse(stdout: http(403, { "X-Ratelimit-Remaining" => "0", "X-Ratelimit-Reset" => reset.to_i.to_s,
                                  "X-Ratelimit-Resource" => "core" },
                          '{"message":"API rate limit exceeded for user ID 1."}'),
              stderr: "gh: API rate limit exceeded for user ID 1. (HTTP 403)", now: NOW)
  r.kind == :rate_limited && r.reset_at == reset && r.resource == "core" && r.secondary == false
end
check("P4 secondary limit: a Retry-After header sets the wait, and it is named secondary") do
  r = W.parse(stdout: http(403, { "Retry-After" => "120" },
                          '{"message":"You have exceeded a secondary rate limit."}'),
              stderr: "", now: NOW)
  r.kind == :rate_limited && r.reset_at == NOW + 120 && r.secondary == true
end
check("P5 secondary limit with no header waits the documented minute") do
  r = W.parse(stdout: http(429, {}, '{"message":"You have exceeded a secondary rate limit"}'), stderr: "", now: NOW)
  r.kind == :rate_limited && r.reset_at == NOW + 60 && r.secondary == true
end
check("P6 a rate-limit 403 seen only on stderr (no headers) is still rate_limited, never an error") do
  r = W.parse(stdout: "", stderr: "HTTP 403: API rate limit exceeded for user ID 1. (https://api.github.com/x)", now: NOW)
  r.kind == :rate_limited && r.reset_at == NOW + 60 && r.resource == "unknown"
end
check("P7 a 403 that is not a rate limit is auth, not rate_limited") do
  r = W.parse(stdout: http(403, { "X-Ratelimit-Remaining" => "4000" }, '{"message":"Resource not accessible by integration"}'),
              stderr: "", now: NOW)
  r.kind == :auth && r.detail.include?("not accessible")
end
check("P8 a 401 is auth") { W.parse(stdout: http(401, {}, '{"message":"Bad credentials"}'), stderr: "", now: NOW).kind == :auth }
check("P9 a 404 is not_found") { W.parse(stdout: http(404, {}, '{"message":"Not Found"}'), stderr: "", now: NOW).kind == :not_found }
check("P10 a 422 (sha unknown to the repo) is not_found") do
  W.parse(stdout: http(422, {}, '{"message":"No commit found for SHA"}'), stderr: "", now: NOW).kind == :not_found
end
check("P11 a 5xx is a transient error") { W.parse(stdout: http(502, {}, "{}"), stderr: "", now: NOW).kind == :error }
check("P12 no HTTP status line (network down) is an error naming stderr") do
  r = W.parse(stdout: "", stderr: "error connecting to api.github.com\n", now: NOW)
  r.kind == :error && r.detail.include?("error connecting")
end
check("P13 a reset already in the past still waits at least one second, never a negative sleep") do
  r = W.parse(stdout: http(403, { "X-Ratelimit-Remaining" => "0", "X-Ratelimit-Reset" => (NOW - 5).to_i.to_s }, "{}"),
              stderr: "", now: NOW)
  r.kind == :rate_limited && r.reset_at == NOW + 1
end
check("P14 header names are matched case-insensitively") do
  r = W.parse(stdout: http(429, { "x-ratelimit-remaining" => "0", "x-ratelimit-reset" => (NOW + 30).to_i.to_s }, "{}"),
              stderr: "", now: NOW)
  r.kind == :rate_limited && r.reset_at == NOW + 30
end

check("P16 a bare 429 (no headers, no message) is still rate_limited, never a generic error") do
  r = W.parse(stdout: http(429, {}, "{}"), stderr: "", now: NOW)
  r.kind == :rate_limited && r.reset_at == NOW + 60
end
check("P17 an HTTP/1.1 status line parses") do
  r = W.parse(stdout: http(200, {}, '{"x":2}').sub("HTTP/2.0", "HTTP/1.1"), stderr: "", now: NOW)
  r.kind == :ok && r.body == { "x" => 2 }
end
check("P18 gh-athena failing to reach the API is a transient error, not auth") do
  r = W.parse(stdout: "", stderr: "gh-athena: could not reach the GitHub API to list installations.\n", now: NOW)
  r.kind == :error
end
check("P19 a 403 saying rate limit with remaining non-zero waits the fallback, never the window reset") do
  r = W.parse(stdout: http(403, { "X-Ratelimit-Remaining" => "4000", "X-Ratelimit-Reset" => (NOW + 3000).to_i.to_s },
                          '{"message":"API rate limit exceeded for user ID 1."}'), stderr: "", now: NOW)
  r.kind == :rate_limited && r.reset_at == NOW + 60
end
check("P15 gh-athena refusing before any request (no App config) is auth, not a retryable error") do
  r = W.parse(stdout: "", stderr: "gh-athena: missing App ID at /x. Fix: echo <app-id> > /x\n", now: NOW)
  r.kind == :auth && r.detail.include?("missing App ID")
end

# ---- C: check-runs on one sha ---------------------------------------------
def cs(rows, min: 1, total: nil)
  W.checks_state(JSON.parse(checks_body(rows, total: total)), min_checks: min)
end
check("C1 zero check-runs is pending (none seen yet), never success") do
  s = cs([])
  s.state == :pending && s.total.zero? && s.summary.include?("no check-runs")
end
check("C2 all completed success/skipped/neutral is success") do
  cs([check_row("a", "completed", "success"), check_row("b", "completed", "skipped"),
      check_row("c", "completed", "neutral")]).state == :success
end
check("C3 one still running is pending") do
  s = cs([check_row("a", "completed", "success"), check_row("b", "in_progress")])
  s.state == :pending && s.pending == 1
end
check("C4 all completed, one failure: failure names it") do
  s = cs([check_row("a", "completed", "success"), check_row("lint", "completed", "failure")])
  s.state == :failure && s.failed == ["lint(failure)"]
end
check("C5 cancelled and timed_out are failures") do
  cs([check_row("a", "completed", "cancelled")]).state == :failure &&
    cs([check_row("a", "completed", "timed_out")]).state == :failure
end
check("C6 a failure while others still run reports pending (wait for the full verdict)") do
  cs([check_row("a", "completed", "failure"), check_row("b", "queued")]).state == :pending
end
check("C7 fewer completed checks than --min-checks is pending") do
  s = cs([check_row("a", "completed", "success")], min: 3)
  s.state == :pending && s.summary.include?("1 of at least 3")
end
check("C8 a body whose total_count exceeds the rows read is refused (a partial page is not the set)") do
  e = (W.checks_state(JSON.parse(checks_body([check_row("a", "completed", "success")], total: 101)), min_checks: 1) rescue $!)
  e.is_a?(W::Unreadable) && e.message.include?("101")
end
check("C9 a body with no check_runs array is unreadable, never empty") do
  e = (W.checks_state({ "message" => "x" }, min_checks: 1) rescue $!)
  e.is_a?(W::Unreadable)
end

# ---- S: a superseded run (DND-1727) -----------------------------------------
# The verified case, gen_saas PR #726 (2026-10-02): a force-push left CI run
# 36998703158 (pull_request) cancelled, and CI run 36998704873 (pull_request,
# same workflow, same head) succeeded. filter=latest returned both suites'
# check-runs, so the waiter read "10 of 20 did not succeed". Ids are the real
# run, suite and workflow ids; the repo and sha are synthetic.
JOBS = ["Lock protocol", "Secret allowlist", "Client", "Build", "Tooling", "Terraform", "Advisories",
        "Format", "Test", "Credo"].freeze
OLD_SUITE = 100_215_347_952
NEW_SUITE = 100_215_352_559
ACTIONS = { "id" => 15_368, "slug" => "github-actions" }.freeze

def suite_row(name, suite, status, conclusion, started, app: ACTIONS)
  { "name" => name, "status" => status, "conclusion" => conclusion, "started_at" => started,
    "check_suite" => { "id" => suite }, "app" => app }
end

def suite_rows(suite, status, conclusion, started)
  JOBS.map { |j| suite_row(j, suite, status, conclusion, started) }
end

def ci_run(id, suite, status, conclusion, created, event: "pull_request", workflow_id: 256_531_677, sha: SHA,
           started: created)
  { "id" => id, "name" => "CI", "path" => ".github/workflows/ci.yml", "head_sha" => sha, "event" => event,
    "status" => status, "conclusion" => conclusion, "created_at" => created, "run_started_at" => started,
    "check_suite_id" => suite, "workflow_id" => workflow_id }
end

def runs_of(*runs) = { "total_count" => runs.size, "workflow_runs" => runs }

OLD_CANCELLED = ci_run(36_998_703_158, OLD_SUITE, "completed", "cancelled", "2026-10-02T11:01:24Z")
NEW_SUCCESS = ci_run(36_998_704_873, NEW_SUITE, "completed", "success", "2026-10-02T11:01:25Z")
NEW_ROWS = suite_rows(NEW_SUITE, "completed", "success", "2026-10-02T11:13:17Z")
OLD_ROWS = suite_rows(OLD_SUITE, "completed", "cancelled", "2026-10-02T11:01:24Z")
TCS = W::Target.new(mode: :checks, repo: "acme/app", sha: SHA, min_checks: 1)
TWS = W::Target.new(mode: :run_workflow, repo: "acme/app", sha: SHA, workflow: "CI")

def css(rows, wf_runs, min: 1)
  W.checks_state(JSON.parse(checks_body(rows)), min_checks: min, runs_body: wf_runs)
end

check("S1 PR #726: an older cancelled run with a newer success of the same workflow on the sha is success, " \
      "and the cancelled run is named as superseded") do
  s = css(NEW_ROWS + OLD_ROWS, runs_of(NEW_SUCCESS, OLD_CANCELLED))
  s.state == :success && s.summary.include?("superseded") && s.summary.include?("36998703158") &&
    s.summary.include?("Test(cancelled)") && !s.summary.include?("did not succeed")
end
check("S2 a lone cancelled run (no newer run of its workflow) is failure, never success") do
  s = css(OLD_ROWS, runs_of(OLD_CANCELLED))
  s.state == :failure && s.failed.include?("Test(cancelled)")
end
check("S3 a cancelled NEWEST run is failure even when an older run of the workflow succeeded") do
  older_ok = ci_run(1001, OLD_SUITE, "completed", "success", "2026-10-02T11:01:24Z")
  newer_cancel = ci_run(1002, NEW_SUITE, "completed", "cancelled", "2026-10-02T11:01:25Z")
  rows = suite_rows(OLD_SUITE, "completed", "success", "2026-10-02T11:01:24Z") +
         suite_rows(NEW_SUITE, "completed", "cancelled", "2026-10-02T11:13:17Z")
  s = css(rows, runs_of(older_ok, newer_cancel))
  s.state == :failure && s.failed.include?("Test(cancelled)")
end
check("S4 an older cancelled run while the newer run still runs is pending, not failure and not success") do
  newer = ci_run(36_998_704_873, NEW_SUITE, "in_progress", nil, "2026-10-02T11:01:25Z")
  rows = suite_rows(NEW_SUITE, "in_progress", nil, "2026-10-02T11:13:17Z") + OLD_ROWS
  css(rows, runs_of(newer, OLD_CANCELLED)).state == :pending
end
check("S5 an older red run is not superseded by a newer run that is only skipped (it proves nothing)") do
  newer_skipped = ci_run(36_998_704_873, NEW_SUITE, "completed", "skipped", "2026-10-02T11:01:25Z")
  rows = [suite_row("Test", OLD_SUITE, "completed", "failure", "2026-10-02T11:01:24Z"),
          suite_row("Test", NEW_SUITE, "completed", "skipped", "2026-10-02T11:13:17Z")]
  s = css(rows, runs_of(newer_skipped, OLD_CANCELLED))
  s.state == :failure && s.failed.include?("Test(failure)")
end
check("S6 a push run and a pull_request run of one workflow are both current: neither supersedes the other") do
  push = ci_run(1003, OLD_SUITE, "completed", "failure", "2026-10-02T11:01:24Z", event: "push")
  rows = [suite_row("Test", OLD_SUITE, "completed", "failure", "2026-10-02T11:01:24Z"),
          suite_row("Test", NEW_SUITE, "completed", "success", "2026-10-02T11:13:17Z")]
  s = css(rows, runs_of(NEW_SUCCESS, push))
  s.state == :failure && s.failed.include?("Test(failure)")
end
check("S7 two workflows with a same-named job are different checks: neither supersedes the other") do
  other = ci_run(1004, OLD_SUITE, "completed", "failure", "2026-10-02T11:01:24Z", workflow_id: 999)
  rows = [suite_row("Test", OLD_SUITE, "completed", "failure", "2026-10-02T11:01:24Z"),
          suite_row("Test", NEW_SUITE, "completed", "success", "2026-10-02T11:13:17Z")]
  css(rows, runs_of(NEW_SUCCESS, other)).state == :failure
end
check("S8 a suite the runs list does not hold is judged on its own, never superseded") do
  css(NEW_ROWS + OLD_ROWS, runs_of(NEW_SUCCESS)).state == :failure
end
check("S9 a non-Actions app's runs are judged on their own (no workflow run orders them)") do
  app = { "id" => 7, "slug" => "other-ci" }
  rows = [suite_row("lint", 1, "completed", "cancelled", "2026-10-02T11:01:24Z", app: app),
          suite_row("lint", 2, "completed", "success", "2026-10-02T11:13:17Z", app: app)]
  css(rows, runs_of).state == :failure
end
check("S10 runs from more than one suite, or a red Actions row, need the runs list; one green suite does not") do
  !W.needs_runs?(TCS, JSON.parse(checks_body(NEW_ROWS))) &&
    W.needs_runs?(TCS, JSON.parse(checks_body(NEW_ROWS + OLD_ROWS))) &&
    W.needs_runs?(TCS, JSON.parse(checks_body(OLD_ROWS))) &&
    !W.needs_runs?(TCS, JSON.parse(checks_body([check_row("lint", "completed", "failure")]))) &&
    !W.needs_runs?(TWS, JSON.parse(checks_body(NEW_ROWS + OLD_ROWS)))
end
check("S16 the cancelled run's rows while the newer run is queued with no check-runs yet: pending, not failure") do
  queued = ci_run(36_998_704_873, NEW_SUITE, "queued", nil, "2026-10-02T11:01:25Z")
  css(OLD_ROWS, runs_of(queued, OLD_CANCELLED)).state == :pending
end
check("S17 a cancelled row whose newer run has not created that job yet: pending, not failure") do
  newer = ci_run(36_998_704_873, NEW_SUITE, "in_progress", nil, "2026-10-02T11:01:25Z")
  rows = [suite_row("Build", NEW_SUITE, "completed", "success", "2026-10-02T11:09:23Z"),
          suite_row("Build", OLD_SUITE, "completed", "cancelled", "2026-10-02T11:01:24Z"),
          suite_row("Test", OLD_SUITE, "completed", "cancelled", "2026-10-02T11:01:24Z")]
  css(rows, runs_of(newer, OLD_CANCELLED)).state == :pending
end
check("S18 a cancelled row whose newer run completed without that job is judged: failure") do
  rows = [suite_row("Build", NEW_SUITE, "completed", "success", "2026-10-02T11:09:23Z"),
          suite_row("Test", OLD_SUITE, "completed", "cancelled", "2026-10-02T11:01:24Z")]
  s = css(rows, runs_of(NEW_SUCCESS, OLD_CANCELLED))
  s.state == :failure && s.failed == ["Test(cancelled)"]
end
check("S19 an older run re-run after the newer one is the current run (its start time moved): its failure counts") do
  rerun = ci_run(36_998_703_158, OLD_SUITE, "completed", "failure", "2026-10-02T11:01:24Z",
                 started: "2026-10-02T12:00:00Z")
  rows = [suite_row("Test", OLD_SUITE, "completed", "failure", "2026-10-02T12:00:05Z"),
          suite_row("Test", NEW_SUITE, "completed", "success", "2026-10-02T11:13:17Z")]
  s = css(rows, runs_of(NEW_SUCCESS, rerun))
  s.state == :failure && s.failed == ["Test(failure)"] && !s.summary.include?("superseded")
end
check("S20 a run with no readable start time orders nothing: its rows are judged on their own") do
  untimed = OLD_CANCELLED.merge("run_started_at" => nil, "created_at" => nil)
  css(NEW_ROWS + OLD_ROWS, runs_of(NEW_SUCCESS, untimed)).state == :failure
end
check("S21 while the newer run runs, an older suite's green rows are judged and only its red rows wait") do
  newer = ci_run(36_998_704_873, NEW_SUITE, "in_progress", nil, "2026-10-02T11:01:25Z")
  rows = [suite_row("Build", NEW_SUITE, "in_progress", nil, "2026-10-02T11:09:23Z"),
          suite_row("Build", OLD_SUITE, "completed", "success", "2026-10-02T11:01:24Z"),
          suite_row("Test", NEW_SUITE, "in_progress", nil, "2026-10-02T11:09:23Z"),
          suite_row("Test", OLD_SUITE, "completed", "cancelled", "2026-10-02T11:01:24Z")]
  sorted = W.supersede(rows, W.runs_by_suite!(runs_of(newer, OLD_CANCELLED)))
  sorted[:awaiting].map { |r| r["name"] } == ["Test"] &&
    sorted[:judged].map { |r| [r["name"], r["status"]] }.sort ==
      [["Build", "completed"], ["Build", "in_progress"], ["Test", "in_progress"]]
end
check("S11 a runs body with no workflow_runs array is unreadable, never no runs") do
  (css(NEW_ROWS + OLD_ROWS, { "message" => "x" }) rescue $!).is_a?(W::Unreadable)
end
check("S12 a runs page short of total_count is unreadable (a newer run may be on page 2)") do
  (css(NEW_ROWS + OLD_ROWS, runs_of(NEW_SUCCESS, OLD_CANCELLED).merge("total_count" => 101)) rescue $!)
    .is_a?(W::Unreadable)
end
check("S13 --min-checks counts the current check-runs, not the superseded ones") do
  css(NEW_ROWS + OLD_ROWS, runs_of(NEW_SUCCESS, OLD_CANCELLED), min: 11).state == :pending
end
check("S14 judge passes the runs body through in checks mode") do
  W.judge(TCS, JSON.parse(checks_body(NEW_ROWS + OLD_ROWS)), runs_of(NEW_SUCCESS, OLD_CANCELLED)).state == :success
end
check("S15 the runs list for a sha is one page of 100 by head_sha") do
  W.runs_path_for(TCS) == "repos/acme/app/actions/runs?head_sha=#{SHA}&per_page=100"
end

# ---- WS: --workflow judges the newest run per event, naming the superseded --
check("WS1 PR #726 by --workflow: the newer success is the verdict and the cancelled run is named superseded") do
  s = W.judge(TWS, runs_of(OLD_CANCELLED, NEW_SUCCESS))
  s.state == :success && s.summary.include?("36998704873") && s.summary.include?("superseded") &&
    s.summary.include?("36998703158")
end
check("WS2 by --workflow, a lone cancelled run is failure") do
  W.judge(TWS, runs_of(OLD_CANCELLED)).state == :failure
end
check("WS3 by --workflow, a cancelled newest run is failure despite an older success") do
  older_ok = ci_run(1001, OLD_SUITE, "completed", "success", "2026-10-02T11:01:24Z")
  newer_cancel = ci_run(1002, NEW_SUITE, "completed", "cancelled", "2026-10-02T11:01:25Z")
  W.judge(TWS, runs_of(older_ok, newer_cancel)).state == :failure
end
check("WS4 by --workflow, a red push run is not hidden by a newer green pull_request run") do
  push = ci_run(1003, OLD_SUITE, "completed", "failure", "2026-10-02T11:01:24Z", event: "push")
  s = W.judge(TWS, runs_of(push, NEW_SUCCESS))
  s.state == :failure && s.summary.include?("1003")
end
check("WS6 by --workflow, a run with no readable time is unreadable, never the oldest") do
  untimed = NEW_SUCCESS.merge("run_started_at" => nil, "created_at" => nil)
  (W.judge(TWS, runs_of(OLD_CANCELLED, untimed)) rescue $!).is_a?(W::Unreadable)
end
check("WS7 by --workflow, an older run re-run last is the current run") do
  rerun = ci_run(36_998_703_158, OLD_SUITE, "completed", "failure", "2026-10-02T11:01:24Z",
                 started: "2026-10-02T12:00:00Z")
  W.judge(TWS, runs_of(rerun, NEW_SUCCESS)).state == :failure
end
check("WS5 by --workflow, a pending newest run is pending even when an older run is cancelled") do
  newer = ci_run(36_998_704_873, NEW_SUITE, "in_progress", nil, "2026-10-02T11:01:25Z")
  W.judge(TWS, runs_of(OLD_CANCELLED, newer)).state == :pending
end

# ---- R: one workflow run ----------------------------------------------------
check("R1 a completed success run on the pinned sha is success") do
  W.run_state(run_row(id: 1, name: "CI", sha: SHA, status: "completed", conclusion: "success"), sha: SHA).state == :success
end
check("R2 a completed failure is failure") do
  s = W.run_state(run_row(id: 1, name: "CI", sha: SHA, status: "completed", conclusion: "failure"), sha: SHA)
  s.state == :failure && s.summary.include?("failure")
end
check("R3 an in-progress run is pending") do
  W.run_state(run_row(id: 1, name: "CI", sha: SHA, status: "in_progress"), sha: SHA).state == :pending
end
check("R4 a run for another sha is wrong_head, never success") do
  s = W.run_state(run_row(id: 1, name: "CI", sha: OTHER, status: "completed", conclusion: "success"), sha: SHA)
  s.state == :wrong_head && s.summary.include?(OTHER[0, 12])
end
check("R5 with no pinned sha the run's own state decides") do
  W.run_state(run_row(id: 1, name: "CI", sha: OTHER, status: "completed", conclusion: "success"), sha: nil).state == :success
end
check("R6 a run body with no status is unreadable") do
  (W.run_state({ "id" => 1 }, sha: nil) rescue $!).is_a?(W::Unreadable)
end

# ---- K: pick the workflow's run for a sha -----------------------------------
runs = { "total_count" => 3, "workflow_runs" => [
  run_row(id: 7, name: "Post-Merge Deploy", sha: SHA, status: "completed", conclusion: "success", created: "2026-10-02T07:00:00Z"),
  run_row(id: 9, name: "Post-Merge Deploy", sha: SHA, status: "in_progress", created: "2026-10-02T07:30:00Z"),
  run_row(id: 8, name: "CI", sha: SHA, status: "completed", conclusion: "success", created: "2026-10-02T07:40:00Z"),
] }
check("K1 the newest run with that name on that sha is picked") { W.pick_run(runs, workflow: "Post-Merge Deploy", sha: SHA)["id"] == 9 }
check("K2 a workflow file name matches the run's path") do
  W.pick_run(runs, workflow: "ci.yml", sha: SHA)["id"] == 8
end
check("K3 no run of that workflow yet is nil (pending), never a run of another workflow") do
  W.pick_run(runs, workflow: "Nightly", sha: SHA).nil?
end
check("K4 a run of the workflow on another sha is never picked") do
  W.pick_run(runs, workflow: "CI", sha: OTHER).nil?
end
check("K6 a runs page short of total_count is unreadable (the newest run may be on page 2)") do
  (W.pick_run(runs.merge("total_count" => 250), workflow: "CI", sha: SHA) rescue $!).is_a?(W::Unreadable)
end
check("K5 a body with no workflow_runs array is unreadable") do
  (W.pick_run({}, workflow: "CI", sha: SHA) rescue $!).is_a?(W::Unreadable)
end

# ---- N: how long to wait before the next read ------------------------------
deadline = NOW + 600
ok = W::Read.new(kind: :ok)
err = W::Read.new(kind: :error)
check("N1 after an ok read, sleep the interval") { W.next_wait(read: ok, now: NOW, deadline: deadline, interval: 60, errors_in_row: 0) == [:sleep, 60] }
check("N2 the last sleep is cut to the deadline") do
  W.next_wait(read: ok, now: deadline - 10, deadline: deadline, interval: 60, errors_in_row: 0) == [:sleep, 10]
end
check("N3 at the deadline: stop") { W.next_wait(read: ok, now: deadline, deadline: deadline, interval: 60, errors_in_row: 0) == [:stop] }
check("N4 consecutive errors back off: the interval, then doubled per error, capped at 300 s") do
  W.next_wait(read: err, now: NOW, deadline: NOW + 9999, interval: 60, errors_in_row: 1) == [:sleep, 60] && W.next_wait(read: err, now: NOW, deadline: NOW + 9999, interval: 60, errors_in_row: 2) == [:sleep, 120] &&
    W.next_wait(read: err, now: NOW, deadline: NOW + 9999, interval: 60, errors_in_row: 5) == [:sleep, 300]
end
check("N5 rate limited with the reset inside the bound: sleep until the reset, not before") do
  rl = W::Read.new(kind: :rate_limited, reset_at: NOW + 200)
  W.next_wait(read: rl, now: NOW, deadline: deadline, interval: 60, errors_in_row: 0) == [:sleep, 200]
end
check("N7 Retry-After 0 or a passed reset never re-reads sooner than the floor") do
  rl = W::Read.new(kind: :rate_limited, reset_at: NOW + 1)
  W.next_wait(read: rl, now: NOW, deadline: deadline, interval: 60, errors_in_row: 0) == [:sleep, W::MIN_INTERVAL]
end
check("N8 rate limited with less than the floor left: give up, not a short re-read") do
  rl = W::Read.new(kind: :rate_limited, reset_at: NOW + 1)
  W.next_wait(read: rl, now: NOW, deadline: NOW + 10, interval: 60, errors_in_row: 0) == [:give_up]
end
check("N6 rate limited past the bound: give up (COULD-NOT-LOOK), never poll into the limit") do
  rl = W::Read.new(kind: :rate_limited, reset_at: deadline + 1)
  W.next_wait(read: rl, now: NOW, deadline: deadline, interval: 60, errors_in_row: 0) == [:give_up]
end

# ---- V: argument validation (a wrongly computed key is an error) -----------
check("V1 repo must be OWNER/NAME") { raised { W.repo!("gen_saas") }&.message.to_s.include?("OWNER/NAME") }
check("V2 a good repo passes") { W.repo!("Acme-1/app.x") == "Acme-1/app.x" }
check("V3 a short sha is refused: a prefix is not the head") { raised { W.sha!("abc123") }&.message.to_s.include?("40") }
check("V4 an upper-case full sha is normalised") { W.sha!("A" * 40) == "a" * 40 }
check("V5 a run id must be digits") { raised { W.run_id!("12x") } && W.run_id!("123") == "123" }
check("V6 an interval under the floor is refused, naming the floor") do
  e = raised { W.interval!("10") }
  e && e.message.include?(W::MIN_INTERVAL.to_s) && W.interval!("60") == 60
end
check("V7 --max must be a positive integer") { raised { W.max!("0") } && raised { W.max!("x") } && W.max!("570") == 570 }
check("V8 --min-checks must be a positive integer") { raised { W.min_checks!("0") } && W.min_checks!("8") == 8 }
check("V9 every usage error carries a Fix") { raised { W.repo!("") }.fix.to_s.length.positive? }

# ---- T: targets ---------------------------------------------------------------
tc = W::Target.new(mode: :checks, repo: "acme/app", sha: SHA, min_checks: 2)
tr = W::Target.new(mode: :run_id, repo: "acme/app", id: "42", sha: SHA)
tw = W::Target.new(mode: :run_workflow, repo: "acme/app", sha: SHA, workflow: "Post-Merge Deploy")
check("T1 checks read the sha's latest check-runs, one page of 100") do
  W.path_for(tc) == "repos/acme/app/commits/#{SHA}/check-runs?filter=latest&per_page=100"
end
check("T2 a run id reads that run by id (DND-1378: never inferred from a list)") { W.path_for(tr) == "repos/acme/app/actions/runs/42" }
check("T3 a workflow run is found by head_sha") { W.path_for(tw) == "repos/acme/app/actions/runs?head_sha=#{SHA}&per_page=100" }
check("T4 judge passes min_checks through") do
  W.judge(tc, JSON.parse(checks_body([check_row("a", "completed", "success")]))).state == :pending
end
check("T5 judge on a workflow with no run listed is pending, naming the workflow") do
  s = W.judge(tw, { "workflow_runs" => [] })
  s.state == :pending && s.summary.include?("Post-Merge Deploy")
end
check("T6 judge on a workflow is its newest run's state (id 9, in progress)") { W.judge(tw, runs).state == :pending }
check("T7 a mistyped workflow names the workflows that do have runs on the sha") do
  s = W.judge(W::Target.new(mode: :run_workflow, repo: "acme/app", sha: SHA, workflow: "Deploy"), runs)
  s.state == :pending && s.summary.include?("Post-Merge Deploy (post-merge-deploy.yml)") && s.summary.include?("CI (ci.yml)")
end

if $failures.empty?
  puts "gh-ci-wait domain: #{$checks} checks passed"
  exit 0
end
$failures.each { |f| puts "FAIL #{f}" }
puts "gh-ci-wait domain: #{$failures.size} of #{$checks} checks failed"
exit 1
