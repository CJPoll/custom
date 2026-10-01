# frozen_string_literal: true

# Deterministic suite for lib/experiment.rb (domain) and lib/experiment_store.rb
# (the experiments.jsonl store), DND-1478. Run by test/self-test.sh, which
# harness-gate discovers.
#
# TDD order: the domain first (judge, comparable/sides, admit?, fold), then the
# store against a temp dir. Functional only (DND-1222): no sleeps, no timing,
# no load, no git, no network. `now` is always injected. Ids are synthetic.

require "json"
require "tmpdir"
require "time"
require_relative "../lib/experiment"
require_relative "../lib/experiment_store"

X = LeadTimeExperiment

$failures = []
$checks = 0

def check(desc)
  $checks += 1
  $failures << desc unless yield
rescue StandardError => e
  $failures << "#{desc} (raised #{e.class}: #{e.message})"
end

def t(iso) = Time.iso8601(iso).utc

RECORDED = "2026-10-01T12:00:00Z"
LANDING = "e" * 40

# A ledger row landed `hours` after (positive) or before (negative) RECORDED.
def row(hours, verify: nil, implement: nil, sha: nil, ticket: nil, critic: [1, 0], gate: [1, 0])
  at = (t(RECORDED) + (hours * 3600)).utc.iso8601
  { "repo" => "custom", "landed_at" => at, "landed_commit" => sha || format("%040x", (hours * 100).to_i.abs + (hours.negative? ? 1 : 2) * 10**9),
    "ticket" => ticket, "start" => nil,
    "phases" => { "verify" => { "s" => verify, "na_reason" => verify ? nil : "no critic PASS" },
                  "implement" => { "s" => implement, "na_reason" => implement ? nil : "no gate" } },
    "counters" => { "critic_rounds" => critic[0], "critic_blocks" => critic[1],
                    "gate_runs" => gate[0], "gate_red" => gate[1] } }
end

def exp(kind: "change", metric: "phase", phase: "verify", recorded_at: RECORDED)
  { "id" => "custom:#{phase}:#{LANDING[0, 12]}", "repo" => "custom", "phase" => phase, "metric" => metric,
    "kind" => kind, "commit" => LANDING, "recorded_at" => recorded_at }
end

def guards(block: 0.2, red: 0.1, reverts: 0)
  { "critic_block_rate" => { "value" => block }, "gate_red_rate" => { "value" => red }, "reverts" => { "value" => reverts } }
end

NOW = t("2026-10-03T12:00:00Z") # day 2
LATE = t("2026-10-09T12:00:00Z") # day 8

def before_rows(values) = values.each_with_index.map { |v, i| row(-(i + 1), verify: v) }
def after_rows(values) = values.each_with_index.map { |v, i| row(i + 1, verify: v) }

# ── judge ───────────────────────────────────────────────────────────────────

ten600 = before_rows([600] * 10)

check("judge 1: an after-set of 9 (K=10) is pending, never keep") do
  v = X.judge(exp, before: ten600, after: after_rows([100] * 9), guards_before: guards, guards_after: guards, now: NOW)
  v["status"] == "pending" && v["reason"].include?("after-set n=9 of K=10") && v["after"]["n"] == 9
end

check("judge 2: median 600 -> 500 (-16.7%), p90 not up, guards equal: keep") do
  v = X.judge(exp, before: ten600, after: after_rows([500] * 10), guards_before: guards, guards_after: guards, now: NOW)
  v["status"] == "keep" && v["before"]["median"] == 600 && v["after"]["median"] == 500 && v["change_pct"] == -16.7
end

check("judge 3: median 650 after 600: revert") do
  v = X.judge(exp, before: ten600, after: after_rows([650] * 10), guards_before: guards, guards_after: guards, now: NOW)
  v["status"] == "revert" && v["reason"].include?("median rose")
end

check("judge 4: median -20% but the critic BLOCK rate rose 0.2 -> 0.4: revert (guard)") do
  v = X.judge(exp, before: ten600, after: after_rows([480] * 10), guards_before: guards(block: 0.2),
                   guards_after: guards(block: 0.4), now: NOW)
  v["status"] == "revert" && v["reason"].include?("critic_block_rate") && v["reason"].include?("0.2 -> 0.4")
end

check("judge 4b: a worse gate red rate or more reverts also reverts") do
  red = X.judge(exp, before: ten600, after: after_rows([480] * 10), guards_before: guards(red: 0.1),
                     guards_after: guards(red: 0.3), now: NOW)
  rev = X.judge(exp, before: ten600, after: after_rows([480] * 10), guards_before: guards(reverts: 0),
                     guards_after: guards(reverts: 1), now: NOW)
  red["status"] == "revert" && rev["status"] == "revert" && rev["reason"].include?("reverts")
end

check("judge 5: median -5%, p90 equal, before day 7: pending") do
  v = X.judge(exp, before: ten600, after: after_rows([570] * 10), guards_before: guards, guards_after: guards, now: NOW)
  v["status"] == "pending" && v["reason"].include?("under the 10% bar")
end

check("judge 5: median -5%, p90 equal, K reached and day 7 past: inconclusive") do
  v = X.judge(exp, before: ten600, after: after_rows([570] * 10), guards_before: guards, guards_after: guards, now: LATE)
  v["status"] == "inconclusive" && v["reason"].include?("under the 10% bar")
end

check("judge 5b: median -20% but the p90 rose: not a keep (pending)") do
  # nearest-rank p90 of 10 is the 9th value: 600 before, 900 after
  before = before_rows([600] * 10)
  after = after_rows([480] * 8 + [900] * 2)
  v = X.judge(exp, before: before, after: after, guards_before: guards, guards_after: guards, now: NOW)
  v["status"] == "pending" && v["reason"].include?("p90 rose")
end

check("judge 5f: a zero baseline median is never a keep (0 -> 0 is no reduction)") do
  e = exp(metric: "counter:gate_red")
  zero = ->(hs) { hs.map { |h| row(h, verify: 1).tap { |r| r["counters"]["gate_red"] = 0 } } }
  v = X.judge(e, before: zero.((1..10).map { |i| -i }), after: zero.((1..10).to_a), guards_before: guards,
                 guards_after: guards, now: NOW)
  v["status"] == "pending" && v["reason"].include?("baseline median is 0s")
end

check("judge 5g: a before-set short of K says it can never grow") do
  v = X.judge(exp, before: before_rows([600] * 4), after: after_rows([500] * 10), guards_before: guards,
                   guards_after: guards, now: NOW)
  v["status"] == "pending" && v["reason"].include?("can never grow")
end

check("judge 5c: the median falls 10% exactly: keep (the bar is at least 10%)") do
  v = X.judge(exp, before: ten600, after: after_rows([540] * 10), guards_before: guards, guards_after: guards, now: NOW)
  v["status"] == "keep"
end

check("judge 5d: a guard unmeasured on either side blocks a keep, and says which") do
  gb = guards
  ga = guards.merge("critic_block_rate" => { "value" => nil, "reason" => "no critic rounds measured in the window" })
  v = X.judge(exp, before: ten600, after: after_rows([400] * 10), guards_before: gb, guards_after: ga, now: NOW)
  v["status"] == "pending" && v["reason"].include?("critic_block_rate unmeasured")
end

check("judge 5e: a short after-set past day 7 is inconclusive, not pending forever") do
  v = X.judge(exp, before: ten600, after: after_rows([100] * 3), guards_before: guards, guards_after: guards, now: LATE)
  v["status"] == "inconclusive" && v["reason"].include?("after-set n=3 of K=10")
end

check("judge 6: instrumentation keeps when its phase's n/a share falls 0.8 -> 0.1; duration not compared") do
  before = before_rows([nil] * 8 + [9000, 9000])
  after = after_rows([100] * 9 + [nil])
  e = exp(kind: "instrumentation", metric: "na_share")
  v = X.judge(e, before: before, after: after, guards_before: guards, guards_after: guards, now: NOW)
  v["status"] == "keep" && v["before"]["na_share"] == 0.8 && v["after"]["na_share"] == 0.1 &&
    !v["before"].key?("median")
end

check("judge 6b: instrumentation whose n/a share did not fall is pending, never revert") do
  before = before_rows([nil] * 5 + [100] * 5)
  after = after_rows([nil] * 5 + [100] * 5)
  e = exp(kind: "instrumentation", metric: "na_share")
  v = X.judge(e, before: before, after: after, guards_before: guards, guards_after: guards, now: NOW)
  v["status"] == "pending" && v["reason"].include?("n/a share did not fall")
end

check("judge: a before-set of nil (n/a) is pending with reason no before-set") do
  v = X.judge(exp, before: nil, after: after_rows([100] * 10), guards_before: guards, guards_after: guards, now: NOW)
  v["status"] == "pending" && v["reason"].include?("no before-set") && v["before"].nil?
end

check("judge: no before-set past day 7 is inconclusive") do
  v = X.judge(exp, before: nil, after: after_rows([100] * 10), guards_before: guards, guards_after: guards, now: LATE)
  v["status"] == "inconclusive" && v["reason"].include?("no before-set")
end

check("unlanded: an experiment whose landing is not in the ledger is pending, inconclusive after day 7") do
  a = X.unlanded(exp, now: NOW)
  b = X.unlanded(exp, now: LATE)
  a["status"] == "pending" && a["reason"].include?("not in the ledger") && b["status"] == "inconclusive"
end

# ── comparable / sides ──────────────────────────────────────────────────────

metric = X::Metric.parse("phase", phase: "verify")

check("comparable 1: excludes the experiment's own landing commit and rows whose metric is null") do
  rows = [row(-2, verify: 100), row(-1, verify: nil), row(0, verify: 50, sha: LANDING), row(1, verify: 70)]
  out = X.comparable(rows, metric: metric, exclude: [LANDING])
  out.map { |r| r.dig("phases", "verify", "s") } == [100, 70]
end

check("comparable 1c: watch-mode rows (no phases) never count, even for na_share") do
  m = X::Metric.parse("na_share", phase: "verify")
  rows = [row(-2, verify: nil).merge("mode" => "watch"), row(-1, verify: nil).merge("mode" => "improve"), row(1, verify: 4)]
  X.comparable(rows, metric: m, exclude: []).size == 2
end

check("comparable 1d: batch tickets sharing a landed commit are ONE landing") do
  sha = "d" * 40
  rows = [row(-1, verify: 10, sha: sha, ticket: "DND-9001"), row(-1, verify: 10, sha: sha, ticket: "DND-9002"),
          row(-1, verify: 10, sha: sha, ticket: "DND-9003"), row(-2, verify: 20)]
  X.comparable(rows, metric: metric, exclude: []).size == 2
end

check("comparable 1b: rows come back in landing order whatever the input order") do
  rows = [row(3, verify: 3), row(-3, verify: 1), row(1, verify: 2)]
  X.comparable(rows, metric: metric, exclude: []).map { |r| r.dig("phases", "verify", "s") } == [1, 2, 3]
end

check("comparable 2: a metric first measured after the boundary has no before-set (n/a), and judge says so") do
  rows = before_rows([nil] * 12) + after_rows([100] * 10)
  s = X.sides(rows, metric: metric, exclude: [LANDING], boundary: t(RECORDED))
  v = X.judge(exp, before: s[:before], after: s[:after], guards_before: guards, guards_after: guards, now: NOW)
  s[:before].nil? && s[:before_na].include?("no before-set") && v["status"] == "pending" && v["reason"].include?("no before-set")
end

check("sides: before is the LAST K before the boundary, after the FIRST K after it") do
  rows = before_rows((1..12).to_a) + after_rows((101..112).to_a)
  s = X.sides(rows, metric: metric, exclude: [], boundary: t(RECORDED))
  b = s[:before].map { |r| r.dig("phases", "verify", "s") }.sort
  a = s[:after].map { |r| r.dig("phases", "verify", "s") }.sort
  b == (1..10).to_a && a == (101..110).to_a
end

check("sides: na_share keeps n/a rows (the n/a IS the measurement) but still drops the own landing") do
  m = X::Metric.parse("na_share", phase: "verify")
  rows = [row(-1, verify: nil), row(0, verify: nil, sha: LANDING), row(1, verify: 5)]
  s = X.sides(rows, metric: m, exclude: [LANDING], boundary: t(RECORDED))
  s[:before].size == 1 && s[:after].size == 1
end

check("sides: a row landed exactly at the boundary belongs to neither side") do
  rows = [row(0, verify: 9), row(-1, verify: 1), row(1, verify: 2)]
  s = X.sides(rows, metric: metric, exclude: [], boundary: t(RECORDED))
  s[:before].size == 1 && s[:after].size == 1
end

check("Metric.parse: phase, lead, code, counter:<name>, na_share; anything else raises naming it") do
  ok = %w[phase lead code counter:slot_wait_s na_share].all? { |m| X::Metric.parse(m, phase: "verify") }
  bad = begin
    X::Metric.parse("speed", phase: "verify")
    false
  rescue X::UsageError => e
    e.message.include?("speed")
  end
  ok && bad
end

check("Metric: counter and total values read from their ledger fields") do
  r = row(1, verify: 5).merge("lead_s" => 77)
  r["counters"]["slot_wait_s"] = 12
  X::Metric.parse("lead", phase: "verify").value(r) == 77 &&
    X::Metric.parse("counter:slot_wait_s", phase: "verify").value(r) == 12
end

check("Metric.check_kind: instrumentation must measure na_share, a change must not") do
  X.kind_error("instrumentation", "phase").include?("na_share") &&
    X.kind_error("change", "na_share").include?("instrumentation") &&
    X.kind_error("change", "phase").nil? && X.kind_error("instrumentation", "na_share").nil?
end

# ── admit? ──────────────────────────────────────────────────────────────────

pending = [exp(kind: "change", phase: "verify").merge("status" => "pending")]

check("admit? 1: a second change on verify is refused; a change on merge and instrumentation on verify are admitted") do
  !X.admit?(pending, phase: "verify", kind: "change") &&
    X.admit?(pending, phase: "merge", kind: "change") &&
    X.admit?(pending, phase: "verify", kind: "instrumentation")
end

check("admit?: blocker names the pending experiment") do
  X.blocker(pending, phase: "verify", kind: "change")["id"] == pending[0]["id"]
end

check("admit?: a change judged revert blocks its phase until the revert lands (reverted)") do
  owed = [exp.merge("status" => "revert")]
  done = [exp.merge("status" => "reverted")]
  !X.admit?(owed, phase: "verify", kind: "change") && X.admit?(done, phase: "verify", kind: "change")
end

check("admit?: a pending INSTRUMENTATION experiment never blocks a change") do
  ins = [exp(kind: "instrumentation", metric: "na_share").merge("status" => "pending")]
  X.admit?(ins, phase: "verify", kind: "change")
end

# ── fold / changed? ─────────────────────────────────────────────────────────

rec = exp.merge("type" => "record")
st1 = { "type" => "status", "id" => rec["id"], "status" => "pending", "reason" => "r1", "judged_at" => "x" }
st2 = { "type" => "status", "id" => rec["id"], "status" => "keep", "reason" => "r2", "judged_at" => "y" }

check("fold: a record with no status row is pending") do
  f = X.fold([rec])
  f.size == 1 && f[0]["status"] == "pending" && f[0]["last"].nil?
end

check("fold: the latest status row wins") do
  f = X.fold([rec, st1, st2])
  f[0]["status"] == "keep" && f[0]["last"]["reason"] == "r2"
end

check("fold: a status row for an unknown id is reported, not folded in") do
  orphan = st1.merge("id" => "custom:merge:000000000000")
  r = X.fold_all([rec, orphan])
  r[:experiments].size == 1 && r[:orphans] == ["custom:merge:000000000000"]
end

check("fold: a malformed record is reported with why, never folded in") do
  bad = [rec.merge("id" => "a", "commit" => "abc"), rec.merge("id" => "b", "metric" => "speed"),
         rec.merge("id" => "c", "recorded_at" => "soon"), rec.merge("id" => "d", "kind" => "instrumentation")]
  r = X.fold_all(bad)
  why = r[:malformed].to_h
  r[:experiments].empty? && why["a"].include?("40-hex") && why["b"].include?("speed") &&
    why["c"].include?("RFC 3339") && why["d"].include?("na_share")
end

check("fold: an unknown status value is reported and ignored, so the experiment stays pending") do
  r = X.fold_all([rec, st1.merge("status" => "kept")])
  r[:bad_status] == [[rec["id"], "kept"]] && r[:experiments][0]["status"] == "pending"
end

check("revert_refs: reads git revert's own line, 40 hex only") do
  body = "Revert x\n\nThis reverts commit #{LANDING}.\nThis reverts commit abc."
  X.revert_refs(body) == [LANDING] && X.revert_refs(nil) == []
end

check("changed?: the same verdict again is not a change (judge is idempotent); a new status is") do
  v = { "status" => "pending", "reason" => "r1", "before" => nil, "after" => nil, "guards" => nil }
  !X.changed?(st1.merge(v), v) && X.changed?(st1.merge(v), v.merge("status" => "keep")) && X.changed?(nil, v)
end

check("terminal?: keep, inconclusive, reverted and declined are terminal; pending and an owed revert are not") do
  %w[keep inconclusive reverted declined].all? { |s| X.terminal?(s) } && !X.terminal?("pending") && !X.terminal?("revert")
end

# ── decline (DND-1547) ──────────────────────────────────────────────────────

ok_guards = { "critic_block_rate" => { "before" => 0.154, "after" => 0.083, "state" => "ok" },
              "gate_red_rate" => { "before" => 0.1, "after" => 0.0, "state" => "ok" },
              "reverts" => { "before" => 0, "after" => 0, "state" => "ok" } }
median_revert = { "type" => "status", "id" => rec["id"], "status" => "revert", "reason" => "median rose 247s -> 292s",
                  "before" => { "n" => 10, "median" => 247, "p90" => 309 },
                  "after" => { "n" => 10, "median" => 292, "p90" => 345 }, "guards" => ok_guards, "judged_at" => "z" }
declined_row = { "type" => "status", "id" => rec["id"], "status" => "declined", "constraint" => "safety-checks",
                 "reason" => "the revert deletes a test", "declined_at" => "w" }

check("fold: a declined status row folds, and is terminal") do
  r = X.fold_all([rec, median_revert, declined_row])
  r[:bad_status].empty? && r[:experiments][0]["status"] == "declined" && X.terminal?(r[:experiments][0]["status"])
end

check("blocker: a declined change on the phase blocks nothing; a revert still blocks (unchanged)") do
  X.blocker([exp.merge("status" => "declined")], phase: "verify", kind: "change").nil? &&
    X.blocker([exp.merge("status" => "revert")], phase: "verify", kind: "change")&.dig("id") == exp["id"]
end

check("decline_error: a revert verdict with no worse guard is admitted") do
  X.decline_error(X.fold([rec, median_revert])[0]).nil?
end

check("decline_error: pending, keep, inconclusive, reverted and declined are each refused with their own reason") do
  whys = { "pending" => "not judged yet", "keep" => "keep", "inconclusive" => "inconclusive",
           "reverted" => "reverted", "declined" => "already declined" }
  reasons = whys.keys.map { |s| X.decline_error(exp.merge("status" => s))&.first }
  whys.values.zip(reasons).all? { |want, got| got.to_s.include?(want) } && reasons.uniq.size == whys.size
end

check("decline_error: a revert from a worse guard is refused, naming the guard and the Fix") do
  worse = ok_guards.merge("gate_red_rate" => { "before" => 0.0, "after" => 0.2, "state" => "worse" })
  why, fix = X.decline_error(X.fold([rec, median_revert.merge("guards" => worse)])[0])
  why.to_s.include?("gate_red_rate") && fix.to_s.include?("decline does not cover a quality regression") &&
    fix.to_s.include?("a guard worsened (gate_red_rate)")
end

check("decline_error: a revert row whose guards are missing is refused (cannot tell it was median-only)") do
  why, = X.decline_error(X.fold([rec, median_revert.reject { |k, _| k == "guards" }])[0])
  why.to_s.include?("guards")
end

check("decline_row: copies before/after/guards and the revert's reason; status declined") do
  e = X.fold([rec, median_revert])[0]
  r = X.decline_row(e, constraint: "bug-fix", reason: "it reinstates a leak", now: t("2026-10-02T00:00:00Z"))
  r["type"] == "status" && r["status"] == "declined" && r["constraint"] == "bug-fix" &&
    r["reason"] == "it reinstates a leak" && r["declined_at"] == "2026-10-02T00:00:00Z" &&
    r["prior_reason"] == "median rose 247s -> 292s" && r["before"] == median_revert["before"] &&
    r["after"] == median_revert["after"] && r["guards"] == ok_guards
end

check("decline_row: an unknown constraint raises (the CLI refuses it first)") do
  X.decline_row(X.fold([rec, median_revert])[0], constraint: "speed", reason: "x", now: NOW)
  false
rescue X::UsageError => e
  e.message.include?("safety-checks")
end

check("status_row: judge can never write declined; only decline_row does") do
  X.status_row(exp, { "status" => "declined", "reason" => "x" }, NOW)
  false
rescue X::UsageError => e
  e.message.include?("declined")
end

# ── store ───────────────────────────────────────────────────────────────────

Dir.mktmpdir("experiment-store-") do |dir|
  path = File.join(dir, "experiments.jsonl")
  store = LeadTimeExperimentStore.new(path)

  check("store: a missing file reads as absent (exist? false), never as an error") do
    rows, bad = store.read
    !store.exist? && rows.empty? && bad.zero?
  end

  check("store: append then read round-trips, and counts malformed lines") do
    store.append([rec])
    File.write(path, "not json\n", mode: "a")
    store.append([st1])
    rows, bad = store.read
    rows.size == 2 && bad == 1 && rows[1]["status"] == "pending"
  end

  check("store: the file is created 0600") do
    (File.stat(path).mode & 0o777) == 0o600
  end
end

puts "experiment suite: #{$checks - $failures.size}/#{$checks} passed"
$failures.each { |f| puts "FAIL #{f}" }
exit($failures.empty? ? 0 : 1)
