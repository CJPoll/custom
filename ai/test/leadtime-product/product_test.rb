# frozen_string_literal: true

# Deterministic suite for ai/lib/leadtime_product.rb (DOMAIN, DND-1540): the
# product-repo lane's rules. Run by `ai/bin/leadtime-product --self-test` and
# ai/test/leadtime-product/self-test.sh, which harness-gate discovers.
#
# Every input is a value. No file, process or clock access. Functional only
# (DND-1222). Names, paths and SHAs are synthetic.

require "json"
require_relative "../../lib/leadtime_product"

P = LeadTimeProduct

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
rescue P::Error => e
  e
end

H1 = "a" * 40
H2 = "b" * 40
M1 = "c" * 40
AT = "2026-10-01T12:30:00Z"

def opened(repo: "prod", pr: 7, head: H1, phase: "verify", branch: "leadtime/prod-verify-20261001T123000Z")
  P.event("opened", at: AT, repo: repo, pr: pr, url: "https://example.invalid/o/#{repo}/pull/#{pr}",
                    phase: phase, branch: branch, head: head, run_id: "run-x")
end

# ── names ────────────────────────────────────────────────────────────────────

check("N1 branch name is leadtime/<repo>-<phase>-<utc>") do
  P.branch_name("prod", "verify", "20261001T123000Z") == "leadtime/prod-verify-20261001T123000Z"
end
check("N2 a phase with a slash, space or capital is refused") do
  %w[ver/ify Verify ver\ ify -verify].all? { |ph| raised { P.branch_name("prod", ph, "20261001T123000Z") } }
end
check("N2 an empty phase is refused with a Fix") do
  e = raised { P.branch_name("prod", "", "20261001T123000Z") }
  e && !e.fix.to_s.empty?
end
check("N3 a repo name with a slash is refused") { raised { P.branch_name("a/b", "verify", "20261001T123000Z") } }
check("N4 a malformed utc stamp is refused") { raised { P.branch_name("prod", "verify", "today") } }

# ── manifest ─────────────────────────────────────────────────────────────────

def manifest_doc(repos: nil, run_id: "run-20261001T123000Z-42", state: "/s/lead-time")
  repos ||= [{ "name" => "prod", "path" => "/src/prod", "common" => "/src/prod/.git",
               "lanes_dir" => "/src/prod/.git/leadtime-lanes",
               "lane" => "/src/prod/.git/leadtime-lanes/#{run_id}",
               "lock" => "/src/prod/.git/leadtime-lanes/#{run_id}.lock" }]
  JSON.generate("run_id" => run_id, "state_dir" => state, "repos" => repos)
end

check("M1 a valid manifest parses, repos by name") do
  m = P.parse_manifest(manifest_doc)
  m.run_id == "run-20261001T123000Z-42" && m.repo("prod").lane.end_with?("/run-20261001T123000Z-42")
end
check("M2 an empty repo list is valid (no product repo)") { P.parse_manifest(manifest_doc(repos: [])).repos.empty? }
check("M3 unparseable JSON is an error, never an empty manifest") { raised { P.parse_manifest("{") } }
check("M4 a relative path is refused") do
  r = JSON.parse(manifest_doc)["repos"]
  r[0]["lane"] = "rel/lane"
  raised { P.parse_manifest(manifest_doc(repos: r)) }
end
check("M5 a lane outside its lanes_dir is refused") do
  r = JSON.parse(manifest_doc)["repos"]
  r[0]["lane"] = "/elsewhere/run-20261001T123000Z-42"
  raised { P.parse_manifest(manifest_doc(repos: r)) }
end
check("M6 a repo the manifest does not name is an error naming it and the names it has") do
  e = raised { P.parse_manifest(manifest_doc).repo("other") }
  e && e.message.include?("other") && e.message.include?("prod")
end
check("M7 a bad run id is refused") { raised { P.parse_manifest(manifest_doc(run_id: "../x")) } }
check("M8 idle_workflow is carried: absent is nil, a file or none as given") do
  base = JSON.parse(manifest_doc)["repos"][0]
  [nil, "post-merge.yml", "none"].all? do |v|
    r = v ? base.merge("idle_workflow" => v) : base
    P.parse_manifest(manifest_doc(repos: [r])).repo("prod").idle_workflow == v
  end
end
check("M9 an idle_workflow with a path in it is refused") do
  r = JSON.parse(manifest_doc)["repos"][0].merge("idle_workflow" => "../x.yml")
  raised { P.parse_manifest(manifest_doc(repos: [r])) }
end

# ── the landing bar: the repo's idle post-merge workflow ─────────────────────

check("I1 a declared workflow file becomes --require-idle-workflow <file>") do
  P.idle_args("post-merge.yml") == ["--require-idle-workflow", "post-merge.yml"]
end
check("I2 none (declared: no post-merge workflow) passes no flag") { P.idle_args("none") == [] }
check("I3 undeclared refuses the landing with a Fix naming idle_workflow") do
  e = raised { P.idle_args(nil) }
  e && e.message.include?("idle_workflow") && e.fix.include?("idle_workflow")
end
check("I4 base deploy: the latest completed run failed holds the line") do
  r = P.base_deploy_hold([{ "status" => "completed", "conclusion" => "failure", "headSha" => H1 }])
  r && r.include?("failure")
end
check("I5 base deploy: success or still running does not hold (locked-merge waits for idle itself)") do
  P.base_deploy_hold([{ "status" => "completed", "conclusion" => "success", "headSha" => H1 }]).nil? &&
    P.base_deploy_hold([{ "status" => "in_progress", "conclusion" => "", "headSha" => H1 }]).nil? &&
    P.base_deploy_hold([]).nil?
end
check("I6 locked-merge's WARN base deploy line is seen") do
  P.merge_warning("x\nWARN base deploy 12 for abc concluded failure; merging anyway: ...\n").to_s.include?("concluded failure") &&
    P.merge_warning("all fine").nil?
end

# ── the store: events and their fold ──────────────────────────────────────────

check("S1 an event serialises with its kind and time") do
  e = opened
  e["event"] == "opened" && e["at"] == AT && e["pr"] == 7
end
check("S2 an unknown event kind is refused") { raised { P.event("frobbed", at: AT, repo: "prod", pr: 7) } }
check("S3 an opened event without a head is refused") do
  raised { P.event("opened", at: AT, repo: "prod", pr: 7, url: "u", phase: "verify", branch: "b", run_id: "r") }
end
check("S4 fold: opened is open") do
  s = P.fold([opened])
  s.size == 1 && s.first.status == "open" && s.first.head == H1 && s.first.phase == "verify"
end
check("S5 fold: a head event moves the head and stays open") do
  s = P.fold([opened, P.event("head", at: AT, repo: "prod", pr: 7, head: H2)]).first
  s.status == "open" && s.head == H2
end
check("S6 fold: merged, then deployed") do
  ev = [opened, P.event("merged", at: AT, repo: "prod", pr: 7, merge_sha: M1),
        P.event("deployed", at: AT, repo: "prod", pr: 7)]
  s = P.fold(ev).first
  s.status == "deployed" && s.merge_sha == M1
end
check("S7 fold keys on (repo, pr): two repos with the same PR number stay apart") do
  P.fold([opened, opened(repo: "other")]).size == 2
end
check("S8 an event for a PR never opened is an error, not a silent new PR") do
  raised { P.fold([P.event("closed", at: AT, repo: "prod", pr: 9, reason: "x")]) }
end
check("S9 parse_line refuses a line that is not a JSON object") do
  raised { P.parse_line("[1]", 3) } && raised { P.parse_line("nope", 4) }
end
check("S10 open_count counts open PRs only") do
  ev = [opened, opened(pr: 8), P.event("closed", at: AT, repo: "prod", pr: 8, reason: "CI red")]
  P.open_count(P.fold(ev)) == 1
end

# ── CI ──────────────────────────────────────────────────────────────────────

def run(status, conclusion) = { "__typename" => "CheckRun", "status" => status, "conclusion" => conclusion }
def ctx(state) = { "__typename" => "StatusContext", "state" => state }

check("C1 every check completed SUCCESS/NEUTRAL/SKIPPED is green") do
  P.ci_state([run("COMPLETED", "SUCCESS"), run("COMPLETED", "SKIPPED"), run("COMPLETED", "NEUTRAL"), ctx("SUCCESS")]) == :green
end
check("C2 any FAILURE is red, even beside a pending one") do
  P.ci_state([run("IN_PROGRESS", nil), run("COMPLETED", "FAILURE")]) == :red
end
check("C3 CANCELLED, TIMED_OUT and a failed status context are red") do
  P.ci_state([run("COMPLETED", "CANCELLED")]) == :red && P.ci_state([run("COMPLETED", "TIMED_OUT")]) == :red &&
    P.ci_state([ctx("FAILURE")]) == :red && P.ci_state([ctx("ERROR")]) == :red
end
check("C4 a queued run is pending, never green") { P.ci_state([run("QUEUED", nil), run("COMPLETED", "SUCCESS")]) == :pending }
check("C5 no checks at all is :none, never green") { P.ci_state([]) == :none && P.ci_state(nil) == :none }
check("C6 an unknown conclusion is never green") { P.ci_state([run("COMPLETED", "WEIRD")]) == :pending }

# ── decide: what a sweep does with one open PR ───────────────────────────────

def pr_state = P.fold([opened]).first
def view(state: "OPEN", head: H1, ci: :green) = { state: state, head: head, ci: ci }

check("D1 merged outside the run is recorded as merged") { P.decide(pr_state, view(state: "MERGED"), line_stopped: nil).action == :record_merged }
check("D2 closed outside the run is recorded as closed") { P.decide(pr_state, view(state: "CLOSED"), line_stopped: nil).action == :record_closed }
check("D3 a head the run did not push is never landed") do
  d = P.decide(pr_state, view(head: H2), line_stopped: nil)
  d.action == :wait && d.reason.include?(H2[0, 12])
end
check("D4 CI red closes") { P.decide(pr_state, view(ci: :red), line_stopped: nil).action == :close }
check("D5 CI pending waits") { P.decide(pr_state, view(ci: :pending), line_stopped: nil).action == :wait }
check("D6 no CI reported waits and says so") do
  d = P.decide(pr_state, view(ci: :none), line_stopped: nil)
  d.action == :wait && d.reason.include?("no CI")
end
check("D7 green with the line stopped waits, naming why") do
  d = P.decide(pr_state, view, line_stopped: "deploy of #3 failed")
  d.action == :wait && d.reason.include?("deploy of #3 failed")
end
check("D8 green, head ours, line running: land") { P.decide(pr_state, view, line_stopped: nil).action == :land }
check("D9 an unknown forge state is an error, never a land") { raised { P.decide(pr_state, view(state: "DRAFTY"), line_stopped: nil) } }

# ── integration-gate, locked-merge, confirm-merged ───────────────────────────

check("G1 gate 0 on the same head: merge") { P.gate_outcome(0, "", head_before: H1, head_after: H1).action == :merge }
check("G2 gate 0 on a rebased head: push it and wait for CI") { P.gate_outcome(0, "", head_before: H1, head_after: H2).action == :rebased }
check("G3 exit 4 closes, names exit 4 and that it is Cody's") do
  o = P.gate_outcome(4, "", head_before: H1, head_after: H1)
  o.action == :close && o.reason.include?("exit 4") && o.reason.include?("Cody")
end
check("G4 exit 3 with a recorded critic BLOCK closes (the reader's line or the judge's)") do
  P.gate_outcome(3, "critic-review: VERDICT BLOCK for #{H1} — findings: x", head_before: H1, head_after: H1).action == :close &&
    P.gate_outcome(3, "critic-review: BLOCKED — athena-diff-critic found: x", head_before: H1, head_after: H1).action == :close
end
check("G4b exit 3 without a BLOCK (judge failed open, could not look) retries, never closes") do
  P.gate_outcome(3, "critic-review: FAIL-OPEN model error", head_before: H1, head_after: H1).action == :retry
end
check("G5 exit 1 (gate RED) closes") { P.gate_outcome(1, "", head_before: H1, head_after: H1).action == :close }
check("G6 exit 2 with REBASE CONFLICT closes") do
  P.gate_outcome(2, "integration-gate: REBASE CONFLICT in a.rb", head_before: H1, head_after: H1).action == :close
end
check("G7 any other exit 2 retries (not a verdict on the change)") do
  P.gate_outcome(2, "usage", head_before: H1, head_after: H1).action == :retry
end
check("G8 exit 6 (gate not run) retries") { P.gate_outcome(6, "", head_before: H1, head_after: H1).action == :retry }
check("G9 an unknown exit retries, naming it") do
  o = P.gate_outcome(137, "", head_before: H1, head_after: H1)
  o.action == :retry && o.reason.include?("137")
end

check("L1 locked-merge 0 and 10 merged") { P.merge_outcome(0).action == :merged && P.merge_outcome(10).action == :merged }
check("L2 locked-merge 3, 5, 6, 9 retry later") { [3, 5, 6, 9, 2, 4].all? { |x| P.merge_outcome(x).action == :retry } }
check("L3 locked-merge 7 and 8 stop the line") { [7, 8].all? { |x| P.merge_outcome(x).action == :stop_line } }
check("L4 an unknown locked-merge exit stops the line (never a blind retry)") { P.merge_outcome(99).action == :stop_line }
check("K1 confirm-merged 0 confirms; anything else stops the line") do
  P.confirm_outcome(0).action == :confirmed && P.confirm_outcome(1).action == :stop_line && P.confirm_outcome(3).action == :stop_line
end

# ── deploy ───────────────────────────────────────────────────────────────────

RE = /deploy/i
NOW_T = Time.utc(2026, 10, 1, 12, 30, 0)
def wf(name, status, conclusion, sha = M1, at: "2026-10-01T11:00:00Z")
  { "name" => name, "status" => status, "conclusion" => conclusion, "headSha" => sha, "updatedAt" => at }
end
def ds(runs, merged_at: nil) = P.deploy_state(runs, M1, RE, now: NOW_T, merged_at: merged_at)

check("P1 nothing reported for the merge yet: pending") { ds([]) == :pending }
check("P1b no run at all, long after the merge: none (the repo runs nothing on main)") do
  ds([], merged_at: Time.utc(2026, 10, 1, 11, 0, 0)) == :none
end
check("P1c no run at all, just merged: pending") { ds([], merged_at: Time.utc(2026, 10, 1, 12, 20, 0)) == :pending }
check("P2 a deploy run in progress: pending") { ds([wf("Post-Merge Deploy", "in_progress", "")]) == :pending }
check("P3 the deploy concluded success: success") do
  ds([wf("CI", "completed", "success"), wf("Post-Merge Deploy", "completed", "success")]) == :success
end
check("P4 the deploy concluded failure: failed") { ds([wf("Post-Merge Deploy", "completed", "failure")]) == :failed }
check("P5 a cancelled deploy is never success, and never a failure that owes a revert") do
  ![:success, :failed].include?(ds([wf("Deploy", "completed", "cancelled")]))
end
check("P5b a superseded (cancelled) run then a success of the same workflow: success") do
  ds([wf("Deploy", "completed", "cancelled", at: "2026-10-01T11:00:00Z"),
      wf("Deploy", "completed", "success", at: "2026-10-01T11:10:00Z")]) == :success
end
check("P5c a skipped deploy job is not a failure") { ds([wf("Deploy", "completed", "skipped")]) != :failed }
check("P5d timed_out and startup_failure are failures") do
  ds([wf("Deploy", "completed", "timed_out")]) == :failed && ds([wf("Deploy", "completed", "startup_failure")]) == :failed
end
check("P5e a failure then a later success of the same workflow (a re-run): success") do
  ds([wf("Deploy", "completed", "failure", at: "2026-10-01T11:00:00Z"),
      wf("Deploy", "completed", "success", at: "2026-10-01T11:10:00Z")]) == :success
end
check("P6 every run completed long ago and none is a deploy: none") { ds([wf("CI", "completed", "success")]) == :none }
check("P6b CI just finished and no deploy yet (it may follow on CI): pending, not none") do
  ds([wf("CI", "completed", "success", at: "2026-10-01T12:20:00Z")]) == :pending
end
check("P6c an unreadable completion time is pending, never none") { ds([wf("CI", "completed", "success", at: "soon")]) == :pending }
check("P7 a non-deploy run still running: pending") { ds([wf("CI", "in_progress", "")]) == :pending }
check("P8 runs for other SHAs are ignored") { ds([wf("Deploy", "completed", "failure", H1)]) == :pending }

# ── retire a lane ────────────────────────────────────────────────────────────

check("R1 tip on origin/main: delete the branch") { P.retire(tip: H1, on_main: true, recorded_head: nil) == :delete }
check("R2 tip pushed on an open improver PR: awaiting landing") { P.retire(tip: H1, on_main: false, recorded_head: H1) == :awaiting }
check("R3 a commit after the push: stranded") { P.retire(tip: H2, on_main: false, recorded_head: H1) == :stranded }
check("R4 never pushed: stranded") { P.retire(tip: H1, on_main: false, recorded_head: nil) == :stranded }

# A lane with no branch ref in R to judge (DND-1640): "never cut" and "cut,
# branch already gone" must not read the same.
LANE = "run-20261001T123000Z-4242"
def no_ref(branch:, worktree:, meta:) = P.no_branch_ref(lane: LANE, branch: branch, worktree: worktree, meta: meta)
check("R5 no worktree and no meta: none, 'no lane cut'") do
  no_ref(branch: nil, worktree: false, meta: false) == [:none, "no lane cut"]
end
check("R6 a cut lane whose branch ref is gone: names the lane and the branch, never 'no lane cut'") do
  v, d = no_ref(branch: "leadtime/prod-verify-x", worktree: true, meta: true)
  v == :gone && d == "lane #{LANE} cut, worktree removed; branch leadtime/prod-verify-x already gone (nothing to keep)"
end
check("R7 meta only (worktree already gone), branch ref gone: says the worktree was already gone") do
  v, d = no_ref(branch: "leadtime/prod-verify-x", worktree: false, meta: true)
  v == :gone && d == "lane #{LANE} cut, worktree already gone; branch leadtime/prod-verify-x already gone (nothing to keep)"
end
check("R8 meta that records no branch, no worktree: cut, no branch recorded, never 'no lane cut'") do
  v, d = no_ref(branch: nil, worktree: false, meta: true)
  v == :gone && d == "lane #{LANE} cut, worktree already gone; its meta records no branch (nothing to keep)"
end

# ── summary and PR body ──────────────────────────────────────────────────────

check("Y1 summary with nothing: product_prs=0 landed=none") { P.summary(0, []) == "product_prs=0 landed=none" }
check("Y2 summary names each landing as R#n") { P.summary(2, %w[prod#7 prod#9]) == "product_prs=2 landed=prod#7,prod#9" }
check("B1 PR body is the evidence with no trailer today (DND-1529 hook)") do
  P.pr_body("evidence here\n\n", nil) == "evidence here\n"
end
check("B2 PR body appends a trailer block when the hook gives one") do
  P.pr_body("evidence", "Lead-time-experiment: x") == "evidence\n\nLead-time-experiment: x\n"
end
check("B3 an empty evidence body is refused") { raised { P.pr_body("  \n", nil) } }

if $failures.empty?
  puts "leadtime_product domain: #{$checks} checks PASS"
  exit 0
else
  $failures.each { |f| puts "FAIL #{f}" }
  puts "leadtime_product domain: #{$failures.size} of #{$checks} FAILED"
  exit 1
end
