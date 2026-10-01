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

# ── check:<label> (DND-1548): one check's wall on each landing's gated head ──

WAIT = "self-test: ai/lib/fleet/test/control/wait"
# Parsed per case, so an unfixed parser fails each case rather than the file.
def check_metric = X::Metric.parse("check:#{WAIT}", phase: "integrate")

# A row with check_walls (or none: walls nil leaves the key out).
def crow(hours, walls, verify: 600, na: nil)
  r = row(hours, verify: verify)
  r["check_walls"] = walls unless walls.nil?
  r["check_walls_na"] = na if na
  r
end

check("Metric.parse: check:<label> parses for any non-empty label, colons and spaces included") do
  m = X::Metric.parse("check:self-test: x", phase: "integrate")
  m.check? && m.check_label == "self-test: x" && m.name == "check:self-test: x"
end

check("Metric.parse: check: alone raises, and so does a label with a newline") do
  raises = lambda do |name|
    X::Metric.parse(name, phase: "integrate")
    false
  rescue X::UsageError => e
    e.message.include?("check:")
  end
  raises.call("check:") && raises.call("check:a\nb")
end

check("Metric: a check metric reads its label's wall from check_walls") do
  check_metric.value(crow(1, { WAIT => 120.3, "other" => 9.0 })) == 120.3
end

check("Metric: key absent, check_walls_na set and label missing are three distinct n/a reasons, never 0") do
  absent = crow(1, nil)
  na = crow(1, nil, na: "no harness_gate.check on aaaaaaaa; no timings rows for aaaaaaaa")
  missing = crow(1, { "other" => 9.0 }).merge("gated_head" => "c" * 40)
  vals = [absent, na, missing].map { |r| check_metric.value(r) }
  reasons = [absent, na, missing].map { |r| check_metric.na_reason(r) }
  vals.all?(&:nil?) && reasons.uniq.size == 3 &&
    reasons[0].include?("row predates check_walls") &&
    reasons[1].include?("no harness_gate.check on aaaaaaaa") &&
    reasons[2].include?("check #{WAIT} did not run on cccccccc")
end

check("Metric: a measured row has no n/a reason") { check_metric.na_reason(crow(1, { WAIT => 5.0 })).nil? }

check("judge: the check falls 120 -> 5 s while the phase rises: keep (the regression case)") do
  # The experiment's own phase (verify) is the one that rises, as Judge#context reads it.
  e = exp(metric: "check:#{WAIT}", phase: "verify")
  rows = (1..10).map { |i| crow(-i, { WAIT => 120.0 }, verify: 600) } + (1..10).map { |i| crow(i, { WAIT => 5.0 }, verify: 900) }
  s = X.sides(rows, metric: X::Metric.parse(e["metric"], phase: e["phase"]), exclude: [], boundary: t(RECORDED))
  v = X.judge(e, before: s[:before], after: s[:after], guards_before: guards, guards_after: guards, now: NOW)
  ctx = X.phase_context(s[:before], s[:after], phase: e["phase"])
  v["status"] == "keep" && v["before"]["median"] == 120.0 && v["after"]["median"] == 5.0 &&
    ctx["before"]["median"] == 600 && ctx["after"]["median"] == 900
end

check("judge: the check rises: revert") do
  e = exp(metric: "check:#{WAIT}", phase: "integrate")
  v = X.judge(e, before: (1..10).map { |i| crow(-i, { WAIT => 5.0 }) }, after: (1..10).map { |i| crow(i, { WAIT => 6.0 }) },
                 guards_before: guards, guards_after: guards, now: NOW)
  v["status"] == "revert" && v["reason"].include?("median rose")
end

check("judge: the check falls but a guard is worse: revert") do
  e = exp(metric: "check:#{WAIT}", phase: "integrate")
  v = X.judge(e, before: (1..10).map { |i| crow(-i, { WAIT => 120.0 }) }, after: (1..10).map { |i| crow(i, { WAIT => 5.0 }) },
                 guards_before: guards(red: 0.1), guards_after: guards(red: 0.3), now: NOW)
  v["status"] == "revert" && v["reason"].include?("gate_red_rate")
end

check("sides: rows without check_walls give no before-set, so judge says pending (never a gain)") do
  e = exp(metric: "check:#{WAIT}", phase: "integrate")
  rows = (1..10).map { |i| crow(-i, nil) } + (1..10).map { |i| crow(i, { WAIT => 5.0 }) }
  s = X.sides(rows, metric: check_metric, exclude: [], boundary: t(RECORDED))
  v = X.judge(e, before: s[:before], after: s[:after], guards_before: nil, guards_after: guards, now: NOW)
  s[:before].nil? && s[:before_na].include?("row predates check_walls") && v["status"] == "pending"
end

check("check_label_error: a label on any of the window's landings passes") do
  rows = [crow(-2, { "a" => 1.0 }), crow(-1, { WAIT => 2.0 })]
  X.check_label_error(rows, WAIT, window: 20).nil?
end

check("check_label_error: a misspelled label is unknown, naming the 5 closest labels, closest first") do
  labels = { WAIT => 1.0, "self-test: ai/lib/fleet/test/control/drain" => 1.0, "blast-radius self-test" => 1.0,
             "a" => 1.0, "b" => 1.0, "c" => 1.0, "zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz" => 1.0 }
  err = X.check_label_error([crow(-1, labels), crow(-2, nil)], "self-test: ai/lib/fleet/test/control/wiat", window: 20)
  err[:state] == :unknown && err[:n] == 1 && err[:closest].size == 5 && err[:closest].first == WAIT &&
    !err[:closest].include?("zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz")
end

check("check_label_error: only the last `window` landings with check_walls are searched") do
  rows = [crow(-3, { WAIT => 1.0 }), crow(-2, { "a" => 1.0 }), crow(-1, { "b" => 1.0 })]
  err = X.check_label_error(rows, WAIT, window: 2)
  err[:state] == :unknown && err[:n] == 2
end

check("check_label_error: batch rows sharing a landed commit are ONE landing of the window") do
  batch = %w[DND-9001 DND-9002].map { |tk| crow(-1, { "b" => 1.0 }).merge("landed_commit" => "d" * 40, "ticket" => tk) }
  rows = [crow(-3, { WAIT => 1.0 }), crow(-2, { "a" => 1.0 })] + batch
  err = X.check_label_error(rows, WAIT, window: 2)
  err[:state] == :unknown && err[:n] == 2 && X.check_label_error(rows, WAIT, window: 3).nil?
end

check("check_label_error: watch-mode rows never count") do
  watch = crow(-1, { WAIT => 1.0 }).merge("mode" => "watch")
  X.check_label_error([watch], WAIT, window: 20)[:state] == :could_not_look
end

check("check_label_error: no landing carries check_walls: could not look, never unknown") do
  err = X.check_label_error([crow(-1, nil), crow(-2, nil, na: "no source")], WAIT, window: 20)
  err[:state] == :could_not_look && err[:n].zero?
end

check("check_label_error: only empty check_walls maps (no numeric wall anywhere): could not look, never an empty closest list") do
  X.check_label_error([crow(-1, {}), crow(-2, {})], WAIT, window: 20)[:state] == :could_not_look
end

check("Metric.parse: a label with any control character raises (a carriage return too)") do
  X::Metric.parse("check:a\rb", phase: "integrate")
  false
rescue X::UsageError => e
  e.message.include?("control character")
end

check("Metric: a label present with no numeric wall says so, not that it did not run") do
  check_metric.na_reason(crow(1, { WAIT => nil }).merge("gated_head" => "c" * 40)) == "check #{WAIT} has no numeric wall on cccccccc"
end

check("sides: an empty before-set names the latest unmeasured improve landing, never a watch row") do
  rows = [crow(-2, nil), crow(-1, { WAIT => 1.0 }).merge("mode" => "watch", "check_walls" => {})] +
         (1..10).map { |i| crow(i, { WAIT => 5.0 }) }
  s = X.sides(rows, metric: check_metric, exclude: [], boundary: t(RECORDED))
  s[:before_na].end_with?("the latest landing before it: row predates check_walls")
end

check("kind_error: a change may take check:<label>; instrumentation may not") do
  X.kind_error("change", "check:#{WAIT}").nil? && X.kind_error("instrumentation", "check:#{WAIT}").include?("na_share") &&
    X.record_error(exp(metric: "check:#{WAIT}", phase: "integrate").merge("recorded_at" => RECORDED)).nil?
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

check("decline_error: a revert with an unmeasured guard is refused, naming it (it may hide a regression)") do
  gap = ok_guards.merge("reverts" => { "before" => 0, "after" => nil, "state" => "unmeasured" })
  why, fix = X.decline_error(X.fold([rec, median_revert.merge("guards" => gap)])[0])
  why.to_s.include?("reverts") && fix.to_s.include?("re-judge once reverts can be measured")
end

check("constraint_error: safety-checks and bug-fix pass; anything else names both") do
  X.constraint_error("safety-checks").nil? && X.constraint_error("bug-fix").nil? &&
    X.constraint_error("speed").to_s.include?("safety-checks, bug-fix")
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

# ── revert held (DND-1549) ──────────────────────────────────────────────────

Source = LeadTimePhases::Source

check("test_additions: a test/ path with additions counts; a non-test path does not") do
  X.test_additions([[3, 0, "ai/x/test/foo.sh"], [5, 1, "ai/bin/x"], [1, 0, "ai/x/fix.sh"]]) == ["ai/x/test/foo.sh"]
end

check("test_additions: a *.self-test.sh counts (FirstParty.test_path?, the one rule)") do
  X.test_additions([[1, 0, "scripts/lib/thing.self-test.sh"]]) == ["scripts/lib/thing.self-test.sh"]
end

check("test_additions: a test path with only deletions does not count (reverting it adds them back)") do
  X.test_additions([[0, 4, "ai/x/test/foo.sh"]]) == []
end

check("test_additions: a binary test file (no line counts) counts: unknown is held") do
  X.test_additions([[nil, nil, "ai/x/test/fixture.bin"]]) == ["ai/x/test/fixture.bin"]
end

check("deletes_tests_fields: an answer lists the paths, [] when there are none") do
  X.deletes_tests_fields(Source.ok([[2, 0, "a/test/t.sh"]])) == { "revert_deletes_tests" => ["a/test/t.sh"] } &&
    X.deletes_tests_fields(Source.ok([[2, 0, "a/bin/t"]])) == { "revert_deletes_tests" => [] }
end

check("deletes_tests_fields: could not look stores _na with the reason, never []") do
  f = X.deletes_tests_fields(Source.could_not_look("git show failed"))
  f == { "revert_deletes_tests_na" => "git show failed" }
end

check("hold: revert with revert_deletes_tests non-empty is held, naming the tests") do
  X.hold("revert", { "revert_deletes_tests" => ["a/test/t.sh"] }) == { "tests" => ["a/test/t.sh"] }
end

check("hold: revert with _na is held (fail closed)") do
  X.hold("revert", { "revert_deletes_tests_na" => "no repo" }) == { "could_not_look" => "no repo" }
end

check("hold: revert with [] is not held") do
  X.hold("revert", { "revert_deletes_tests" => [] }).nil?
end

check("hold: revert with neither field is held (could not look), never read as []") do
  X.hold("revert", {})&.key?("could_not_look")
end

check("hold: pending, keep, inconclusive and reverted are never held") do
  tests = { "revert_deletes_tests" => ["a/test/t.sh"] }
  %w[pending keep inconclusive reverted].all? { |s| X.hold(s, tests).nil? }
end

check("hold_text: tests, the Fix and decline when decline would be admitted") do
  s = X.hold_text("custom", "custom:verify:abc", LANDING, { "tests" => ["a/test/t.sh", "b/test/u.sh"] }, nil)
  s.include?("reverting #{LANDING[0, 12]} deletes test additions in a/test/t.sh, b/test/u.sh") &&
    s.include?("the hard constraint rules out a plain git revert") &&
    s.include?("Fix: land a partial revert that keeps every test addition and its fixture fix, or run " \
               "experiment decline --repo custom --id custom:verify:abc --constraint safety-checks --reason-file <F>")
end

check("hold_text: could not look names the reason") do
  s = X.hold_text("custom", "i", LANDING, { "could_not_look" => "no repo" }, nil)
  s.include?("could not look whether reverting #{LANDING[0, 12]} deletes test additions: no repo")
end

check("hold_text: when decline would refuse (a worse guard), it is not offered and says why") do
  s = X.hold_text("custom", "i", LANDING, { "tests" => ["a/test/t.sh"] }, "a guard worsened")
  s.include?("Fix: land a partial revert that keeps every test addition and its fixture fix") &&
    !s.include?("experiment decline") && s.include?("decline does not cover this revert (a guard worsened)")
end

check("hold never changes the verdict: status_row of a held revert stays revert") do
  r = X.status_row(exp, { "status" => "revert", "reason" => "median rose", "held" => { "tests" => ["a/test/t.sh"] } }, NOW)
  r["status"] == "revert" && r["held"] == { "tests" => ["a/test/t.sh"] }
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
