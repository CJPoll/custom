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

check("test_additions: a *.self-test.sh counts (FirstParty.test_file_any_layout?, the one rule)") do
  X.test_additions([[1, 0, "scripts/lib/thing.self-test.sh"]]) == ["scripts/lib/thing.self-test.sh"]
end

check("test_additions: a test path with only deletions does not count (reverting it adds them back)") do
  X.test_additions([[0, 4, "ai/x/test/foo.sh"]]) == []
end

check("test_additions: a binary test file (no line counts) counts: unknown is held") do
  X.test_additions([[nil, nil, "ai/x/test/fixture.bin"]]) == ["ai/x/test/fixture.bin"]
end

# DND-1630: a product repo's tests live in its own layout. Every common one is
# a test; a plain source file is not; a name that only contains the letters is not.
TEST_LAYOUTS = %w[
  spec/models/user_spec.rb __tests__/button.js app/__tests__/button.js tests/test_api.py src/tests/api.rs
  src/user_test.go lib/user_spec.rb web/button.test.ts web/button.spec.tsx
  src/main/FooTest.java src/main/FooSpec.kt test_api.py e2e/login.ts conftest.py src/HTTPTest.java
].freeze
PLAIN_SOURCE = %w[
  src/latest.rb lib/contest.go app/attestation.ts src/protest/main.rs lib/inspector.rb apps/x/lib/deploy.ex
].freeze

check("test_additions: spec/, __tests__/, tests/, *_test.*, *_spec.*, *.test.*, *.spec.* and CamelCase Test/Spec files are tests") do
  X.test_additions(TEST_LAYOUTS.map { |p| [2, 0, p] }) == TEST_LAYOUTS.sort
end

check("test_additions: a plain source change is not a test, even where a name holds the letters") do
  X.test_additions(PLAIN_SOURCE.map { |p| [2, 0, p] }) == []
end

check("deletes_tests_fields: a commit adding spec/, __tests__/ and *.test.ts names all three") do
  f = X.deletes_tests_fields(Source.ok([[1, 0, "spec/a_spec.rb"], [1, 0, "web/__tests__/b.js"], [1, 0, "web/c.test.ts"], [4, 1, "lib/d.rb"]]))
  f == { "revert_deletes_tests" => %w[spec/a_spec.rb web/__tests__/b.js web/c.test.ts] }
end

check("deletes_tests_fields: an answer lists the paths, [] when there are none") do
  X.deletes_tests_fields(Source.ok([[2, 0, "a/test/t.sh"]])) == { "revert_deletes_tests" => ["a/test/t.sh"] } &&
    X.deletes_tests_fields(Source.ok([[2, 0, "a/bin/t"]])) == { "revert_deletes_tests" => [] }
end

check("deletes_tests_fields: could not look stores _na with the reason, never []") do
  f = X.deletes_tests_fields(Source.could_not_look("git show failed"))
  f == { "revert_deletes_tests_na" => "git show failed" }
end

# DND-1634: a test-like layout with no test word is named as unclassified,
# never read as "no tests"; a test and a plain source file are not.
UNCLASSIFIED = %w[
  features/x.feature features/step_definitions/login_steps.rb src/__mocks__/api.js testing/helpers.go
  fixtures/user.json app/__snapshots__/button.js.snap cypress/integration/login.js docs/login.feature
].freeze

check("unclassified_additions: features/, __mocks__/, testing/, fixtures/, *.feature and *.snap are named") do
  X.unclassified_additions(UNCLASSIFIED.map { |p| [2, 0, p] }) == UNCLASSIFIED.sort
end

check("unclassified_additions: a plain source change is not named") do
  X.unclassified_additions(PLAIN_SOURCE.map { |p| [2, 0, p] }) == []
end

check("unclassified_additions: a test is classified (a test), so not named") do
  X.unclassified_additions((TEST_LAYOUTS + %w[spec/fixtures/user.json test/features/x.rb]).map { |p| [2, 0, p] }) == []
end

check("unclassified_additions: a word only in the file name is source (lib/fixtures.rb), deletions only are not named") do
  X.unclassified_additions([[2, 0, "lib/fixtures.rb"], [0, 3, "features/x.feature"]]) == []
end

check("layout_fields: a commit adding features/x.feature names it as unclassified, holding nothing") do
  f = X.layout_fields(Source.ok([[3, 0, "features/x.feature"], [4, 1, "lib/d.rb"]]))
  f == { "revert_deletes_tests" => [], "revert_unclassified" => ["features/x.feature"] } &&
    X.hold("revert", f).nil?
end

check("layout_fields: a plain source change names nothing") do
  X.layout_fields(Source.ok([[4, 1, "lib/d.rb"]])) == { "revert_deletes_tests" => [], "revert_unclassified" => [] }
end

check("layout_fields: could not look stores both _na fields, never []") do
  X.layout_fields(Source.could_not_look("git show failed")) ==
    { "revert_deletes_tests_na" => "git show failed", "revert_unclassified_na" => "git show failed" }
end

check("unclassified_text: names the paths; nil for none; n/a for unknown or a missing field") do
  s = X.unclassified_text({ "revert_unclassified" => ["features/x.feature", "fixtures/u.json"] })
  s.include?("unclassified additions in features/x.feature, fixtures/u.json") &&
    s.include?("a revert is not held on them") &&
    X.unclassified_text({ "revert_unclassified" => [] }).nil? &&
    X.unclassified_text({ "revert_unclassified_na" => "no repo" }) == "unclassified additions n/a (no repo)" &&
    X.unclassified_text({}).include?("n/a (the record carries no revert_unclassified list)")
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
    s.include?("Fix: land a partial revert that keeps every test addition and its fixture fix") &&
    s.include?("), or run experiment decline --repo custom --id custom:verify:abc --constraint safety-checks --reason-file <F>")
end

check("hold_text: the partial-revert Fix keeps git's full-SHA revert line, so judge can record reverted") do
  s = X.hold_text("custom", "i", LANDING, { "tests" => ["a/test/t.sh"] }, nil)
  s.include?("git revert --no-commit #{LANDING}") && s.include?("\"This reverts commit #{LANDING}.\"") &&
    X.revert_refs("This reverts commit #{LANDING}.") == [LANDING]
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

# ── cross-repo experiments (DND-1528) ───────────────────────────────────────

CUSTOM_SHA = "c" * 40
LIVE = "2026-10-01T12:30:00Z"

def xexp(**over)
  exp.merge("id" => "gen_saas:verify:#{CUSTOM_SHA[0, 12]}", "repo" => "gen_saas", "commit" => CUSTOM_SHA,
            "change_repo" => "custom", "live_at" => LIVE).merge(over.transform_keys(&:to_s))
end

check("cross_repo?: a change_repo other than the repo") { X.cross_repo?(xexp) }
check("cross_repo?: no change_repo (every record before DND-1528) is same-repo") { !X.cross_repo?(exp) }
check("cross_repo?: change_repo equal to the repo is same-repo") { !X.cross_repo?(xexp("change_repo" => "gen_saas")) }

FP = [["f3" + "0" * 38, t("2026-10-01T14:00:00Z")], ["f2" + "0" * 38, t("2026-10-01T12:30:00Z")],
      ["f1" + "0" * 38, t("2026-10-01T10:00:00Z")]].freeze
check("landing_point: a commit on main's first-parent line landed as itself, at its own time") do
  X.landing_point(FP, [], FP[1][0]) == FP[1]
end
check("landing_point: a merged side commit landed with the OLDEST first-parent commit that contains it") do
  X.landing_point(FP, [FP[0][0], FP[1][0], "a" * 40], "b" * 40) == FP[1]
end
check("landing_point: a commit no first-parent commit contains has no landing (nil, never a guess)") do
  X.landing_point(FP, ["a" * 40], "b" * 40).nil?
end

ledger = before_rows([600] * 10) + [row(0, verify: 550, sha: LANDING)] + after_rows([500] * 10)
check("split: same-repo splits at its own ledgered landing, excluding it") do
  s = X.split(exp, ledger)
  s[:boundary] == t(RECORDED) && s[:exclude] == [LANDING]
end
check("split: same-repo with no ledgered landing yet is nil (unlanded)") { X.split(exp, ledger - [ledger[10]]).nil? }
check("split: cross-repo splits at live_at, with no own landing to exclude") do
  s = X.split(xexp, ledger)
  s[:boundary] == t(LIVE) && s[:exclude] == []
end
check("split: cross-repo ignores a measured-repo landing that happens to carry the commit's SHA") do
  X.split(xexp("commit" => LANDING), ledger)[:exclude] == []
end
check("sides at a cross-repo live_at: the landing at +0h is BEFORE a live_at of +0h30m, so it joins the before-set") do
  s = X.split(xexp, ledger)
  sd = X.sides(ledger, metric: X::Metric.parse("phase", phase: "verify"), exclude: s[:exclude], boundary: s[:boundary])
  sd[:before].last["landed_commit"] == LANDING && sd[:after].size == 10 && sd[:before].size == 10
end

check("record_error: a cross-repo record folds") { X.record_error(xexp).nil? }
check("record_error: a change_repo that is not a plain name is malformed") do
  X.record_error(xexp("change_repo" => "../x")).to_s.include?("change_repo")
end
check("record_error: a cross-repo record without an RFC 3339 live_at is malformed, never split at nil") do
  X.record_error(xexp("live_at" => "yesterday")).to_s.include?("live_at") && X.record_error(xexp("live_at" => nil)).to_s.include?("live_at")
end
check("record_error: a same-repo record needs no live_at (unchanged)") { X.record_error(exp).nil? }

check("cross_text: a cross-repo experiment names change_repo, commit and live_at") do
  X.cross_text(xexp) == "change_repo=custom commit=#{CUSTOM_SHA[0, 12]} live_at=#{LIVE}"
end
check("cross_text: a committer-time live_at says so, so it never reads as the push time") do
  X.cross_text(xexp("live_at_source" => "committer")).end_with?("live_at=#{LIVE} (committer time: no change-repo ledger row carried it when recorded)")
end
check("record_error: an unknown live_at_source is malformed") do
  X.record_error(xexp("live_at_source" => "guess")).to_s.include?("live_at_source")
end
check("record_error: ledger and committer are the known live_at sources") do
  X.record_error(xexp("live_at_source" => "ledger")).nil? && X.record_error(xexp("live_at_source" => "committer")).nil?
end

crow = lambda do |at, sha, repo: "custom"|
  { "repo" => repo, "landed_commit" => sha, "landed_at" => at }
end
cands = X.ledger_live_candidates(
  [crow.call("2026-10-01T13:00:00Z", "b" * 40), crow.call("2026-10-01T09:00:00Z", "a" * 40),
   crow.call("2026-10-01T12:45:00Z", "d" * 40), crow.call("2026-10-01T12:45:00Z", "d" * 40),
   crow.call("2026-10-01T12:50:00Z", nil), crow.call("2026-10-01T11:40:00Z", "e" * 40)],
  committed_at: t("2026-10-01T12:30:00Z")
)
check("ledger_live_candidates: the change repo's landings from (committer time - skew) on, oldest first, one per landed commit") do
  cands.map { |r| r["landed_commit"][0] } == %w[e d b]
end
check("ledger_live_candidates: a landing more than the skew before the commit was made is never a candidate") do
  cands.none? { |r| r["landed_commit"] == "a" * 40 }
end
check("ledger_live_candidates: a row with no landed commit is never a candidate") { cands.none? { |r| r["landed_commit"].nil? } }
check("ledger_live_candidates: ordered by time, not by the timestamp's text (a non-Z offset)") do
  mixed = X.ledger_live_candidates([crow.call("2026-10-01T13:00:00Z", "b" * 40), crow.call("2026-10-01T06:50:00-06:00", "d" * 40)],
                                   committed_at: t("2026-10-01T12:30:00Z"))
  mixed.map { |r| r["landed_commit"][0] } == %w[d b]
end
check("cross_text: a same-repo experiment prints nothing new") { X.cross_text(exp).nil? }

check("hold_text: a cross-repo revert names the change repo it lands in") do
  s = X.hold_text("gen_saas", "gen_saas:verify:c", CUSTOM_SHA, { "tests" => ["a/test/t.sh"] }, nil, change_repo: "custom")
  s.include?("in custom: git revert --no-commit #{CUSTOM_SHA}") && s.include?("experiment decline --repo gen_saas")
end
check("hold_text: same-repo text is unchanged when no change_repo is given") do
  X.hold_text("custom", "i", LANDING, { "tests" => ["a/test/t.sh"] }, nil) ==
    X.hold_text("custom", "i", LANDING, { "tests" => ["a/test/t.sh"] }, nil, change_repo: nil)
end

# ── the experiment trailer and confounds (DND-1529) ─────────────────────────

TR = LeadTimeTrailer
OTHER_SHA = "f" * 40
THIRD_SHA = "d" * 40

check("trailer: line builds the documented format") do
  TR.line("custom", "verify", "phase") == "Lead-time-experiment: custom verify phase"
end
check("trailer: a check:<label> metric keeps its spaces (the rest of the line)") do
  t, = TR.parse("custom integrate check:self-test: fixture/control/wait")
  t.metric == "check:self-test: fixture/control/wait" && t.phase == "integrate"
end
check("trailer: line refuses parts that would not parse back (an empty phase)") do
  TR.line("custom", "", "phase")
  false
rescue TR::Error => e
  e.message.include?("no phase") && e.fix.include?(TR::FORMAT)
end
check("trailer: scan finds every trailer line, case-insensitive key, and reports malformed ones") do
  s = TR.scan("subject\n\nbody\n\nlead-time-experiment: custom verify phase\nLead-time-experiment: gen_saas queue lead\n" \
              "Lead-time-experiment: custom VERIFY phase\nCo-Authored-By: x\n")
  s[:trailers].map(&:to_s) == ["custom verify phase", "gen_saas queue lead"] &&
    s[:malformed].size == 1 && s[:malformed][0][1].include?("not a phase name")
end
check("trailer: a message with none scans to nothing") { TR.scan("fix: a thing\n")[:trailers].empty? }

check("record: the matching trailer passes") do
  X.trailer_error("x\n\nLead-time-experiment: custom verify phase\n", sha: LANDING, repo: "custom", phase: "verify", metric: "phase").nil?
end
check("record: no trailer is refused, the Fix naming the line and its format") do
  what, fix = X.trailer_error("x\n", sha: LANDING, repo: "custom", phase: "verify", metric: "phase")
  what.include?("carries no Lead-time-experiment trailer") &&
    fix.include?("`Lead-time-experiment: custom verify phase`") && fix.include?(TR::FORMAT)
end
check("record: a trailer for another phase or metric is refused, naming what it carries") do
  what, = X.trailer_error("Lead-time-experiment: custom queue phase\n", sha: LANDING, repo: "custom", phase: "verify", metric: "phase")
  what.include?("name custom queue phase, not custom verify phase")
end
check("record: a malformed trailer line is named in the refusal") do
  what, = X.trailer_error("Lead-time-experiment: custom\n", sha: LANDING, repo: "custom", phase: "verify", metric: "phase")
  what.include?("malformed") && what.include?("no phase after custom")
end

# commits for confounders: [sha, Time, message], RECORDED-relative hours
def tc(sha, hours, msg) = [sha, t(RECORDED) + (hours * 3600), msg]
FROM = t(RECORDED) - (10 * 3600)
TO = t(RECORDED) + (10 * 3600)

check("window: the before-set's first landing to the after-set's last") do
  s = { before: before_rows([600] * 10).reverse, after: after_rows([500] * 10) } # landing order, as sides gives
  X.window(s, t(RECORDED)) == [t(RECORDED) - (10 * 3600), t(RECORDED) + (10 * 3600)]
end
check("window: no before-set and no after landing yet: the boundary on that side") do
  X.window({ before: nil, after: [] }, t(RECORDED)) == [t(RECORDED), t(RECORDED)]
end

check("confounders: regression: another experiment's trailer on the same phase inside the window is named") do
  c = X.confounders(exp, [tc(OTHER_SHA, 3, "y\n\nLead-time-experiment: gen_saas verify phase\n")], from: FROM, to: TO)
  c[:confounders].size == 1 && c[:confounders][0]["commit"] == OTHER_SHA && c[:confounders][0]["repo"] == "gen_saas" &&
    c[:confounders][0]["phase"] == "verify"
end
check("confounders: a trailer on another phase has no effect") do
  X.confounders(exp, [tc(OTHER_SHA, 3, "Lead-time-experiment: custom queue phase\n")], from: FROM, to: TO)[:confounders].empty?
end
check("confounders: outside the window has no effect (either side)") do
  m = "Lead-time-experiment: custom verify phase\n"
  X.confounders(exp, [tc(OTHER_SHA, -11, m), tc(THIRD_SHA, 11, m)], from: FROM, to: TO)[:confounders].empty?
end
check("confounders: the window's edges are inside") do
  m = "Lead-time-experiment: custom verify phase\n"
  X.confounders(exp, [tc(OTHER_SHA, -10, m), tc(THIRD_SHA, 10, m)], from: FROM, to: TO)[:confounders].size == 2
end
check("confounders: the experiment's own commit and a revert of it do not count") do
  m = "Lead-time-experiment: custom verify phase\n"
  own_revert = "Revert x\n\nThis reverts commit #{LANDING}.\n\n#{m}"
  X.confounders(exp, [tc(LANDING, 0, m), tc(OTHER_SHA, 2, own_revert)], from: FROM, to: TO)[:confounders].empty?
end
check("confounders: an instrumentation trailer (na_share) on the phase confounds no change, as it blocks none") do
  X.confounders(exp, [tc(OTHER_SHA, 2, "Lead-time-experiment: custom verify na_share\n")], from: FROM, to: TO)[:confounders].empty?
end
check("confounders: an instrumentation experiment is never confounded by a trailer, as it is never blocked") do
  X.confounders(exp(kind: "instrumentation", metric: "na_share"), [tc(OTHER_SHA, 2, "Lead-time-experiment: custom verify phase\n")],
                from: FROM, to: TO)[:confounders].empty?
end
check("confounders: a change trailer with another metric on the phase still confounds") do
  X.confounders(exp, [tc(OTHER_SHA, 2, "Lead-time-experiment: custom verify check:x y\n")], from: FROM, to: TO)[:confounders].size == 1
end
check("confounders: phase alone matches across measured repos (one harness serves every repo)") do
  gs = exp.merge("repo" => "gen_saas", "id" => "gen_saas:verify:x")
  X.confounders(gs, [tc(OTHER_SHA, 2, "Lead-time-experiment: custom verify phase\n")], from: FROM, to: TO)[:confounders].size == 1
end
check("confounders: a settled predecessor's change inside the before-set confounds too (the window reaches back)") do
  X.confounders(exp, [tc(OTHER_SHA, -5, "Revert y\n\nThis reverts commit #{THIRD_SHA}.\n\nLead-time-experiment: custom verify phase\n")],
                from: FROM, to: TO)[:confounders].size == 1
end
check("confounders: a commit with no trailer has no effect") do
  X.confounders(exp, [tc(OTHER_SHA, 2, "a plain commit\n")], from: FROM, to: TO)[:confounders].empty?
end
check("confounders: a malformed trailer is not a confounder, and is returned to be named") do
  c = X.confounders(exp, [tc(OTHER_SHA, 2, "Lead-time-experiment: custom\n")], from: FROM, to: TO)
  c[:confounders].empty? && c[:malformed] == [[OTHER_SHA, "custom", "no phase after custom"]]
end

KEEP_V = { "status" => "keep", "reason" => "median 600s -> 500s", "before" => { "n" => 10 }, "after" => { "n" => 10 }, "guards" => {} }.freeze
CONF = [{ "commit" => OTHER_SHA, "at" => "2026-10-01T15:00:00Z", "repo" => "gen_saas", "phase" => "verify", "metric" => "phase" }].freeze

check("confound: no confounder leaves the verdict alone") { X.confound(KEEP_V, [], phase: "verify") == KEEP_V }
check("confound: a keep becomes confounded, naming the other commit and what it would have read") do
  v = X.confound(KEEP_V, CONF, phase: "verify")
  v["status"] == "confounded" && v["confounders"] == CONF && v["reason"].include?(OTHER_SHA[0, 12]) &&
    v["reason"].include?("gen_saas verify phase") && v["reason"].include?("unconfounded it read keep") && v["before"] == KEEP_V["before"]
end
check("confound: a revert never stays a revert") do
  X.confound(KEEP_V.merge("status" => "revert"), CONF, phase: "verify")["status"] == "confounded"
end
check("confounded: terminal, not blocking, judged, and never declinable") do
  X.terminal?("confounded") && !X::BLOCKING.include?("confounded") && X::JUDGED.include?("confounded") &&
    X.admit?([exp.merge("status" => "confounded")], phase: "verify", kind: "change") &&
    X.decline_error(exp.merge("status" => "confounded", "id" => "i")).first.include?("not an owed revert")
end
check("confounded: a status row folds in") do
  rows = [exp.merge("type" => "record"), { "type" => "status", "id" => exp["id"], "status" => "confounded" }]
  f = X.fold_all(rows)
  f[:bad_status].empty? && f[:experiments][0]["status"] == "confounded"
end
check("hold_text: the partial revert keeps the trailer line when given") do
  X.hold_text("custom", "i", LANDING, { "tests" => ["a/test/t.sh"] }, nil, trailer: "Lead-time-experiment: custom verify phase")
   .include?("and the trailer line `Lead-time-experiment: custom verify phase`")
end

# ── tail (DND-1613): a product change judged on landing -> post-merge run ────

def tail_metric = X::Metric.parse("phase", phase: "tail")

# A ledger row with a tail: tail_s seconds, lead-time's end kind tail_end
# (deploy | pipeline: a post-merge run concluded; merge: none was found).
# :absent leaves tail_end out (a row ingested before DND-1532).
def trow(hours, tail_s, tail_end = "deploy", origin: nil)
  r = row(hours, verify: 600).merge("tail_s" => tail_s)
  r["tail_end"] = tail_end unless tail_end == :absent
  r["origin"] = origin if origin
  r
end

def texp(**kw) = exp(phase: "tail", **kw)

check("tail: Metric.parse takes --phase tail with --metric phase") do
  m = tail_metric
  m.phase == "tail" && m.name == "phase" && m.tail?
end

check("tail: every other metric on tail raises, naming tail and phase") do
  %w[lead code na_share counter:gate_runs check:x].all? do |n|
    X::Metric.parse(n, phase: "tail")
    false
  rescue X::UsageError => e
    e.message.include?("tail") && e.message.include?("--metric phase")
  end
end

check("tail: an unknown phase still raises, and the message lists tail") do
  X::Metric.parse("phase", phase: "deploy")
  false
rescue X::UsageError => e
  e.message.include?("deploy") && e.message.include?("tail")
end

check("tail: a row whose post-merge run concluded (deploy or pipeline) is measured") do
  tail_metric.value(trow(1, 2400, "deploy")) == 2400 && tail_metric.value(trow(1, 900, "pipeline")) == 900 &&
    tail_metric.na_reason(trow(1, 2400, "deploy")).nil?
end

check("tail: a 0 tail with no post-merge run (end kind merge) is n/a with its reason, never 0") do
  r = trow(1, 0, "merge")
  tail_metric.value(r).nil? && tail_metric.na_reason(r).include?("no post-merge run") &&
    tail_metric.na_reason(r).include?("merge")
end

check("tail: a row ingested before DND-1532 (no tail_end) is n/a, never a measured 0") do
  r = trow(1, 0, :absent)
  tail_metric.value(r).nil? && tail_metric.na_reason(r).include?("DND-1532")
end

check("tail: a nonzero tail on a row with no tail_end is measured (only a deploy or pipeline end gives one), as the summary reads it") do
  r = trow(1, 2400, :absent)
  tail_metric.value(r) == 2400 && tail_metric.na_reason(r).nil? &&
    LeadTimePhases::Stats.tail_cell(r, true) == [2400, nil]
end

# lead-time gives these kinds no tail (nil); the nonzero tail here is a
# defensive input: the end kind alone keeps them out.
check("tail: closed, open and unmeasured end kinds are n/a, each naming its kind") do
  %w[closed open unmeasured].all? do |k|
    r = trow(1, 50, k)
    tail_metric.value(r).nil? && tail_metric.na_reason(r).include?(k)
  end
end

check("tail: a null tail_s is n/a with the ledger's own reason") do
  r = trow(1, nil, "deploy").merge("lead_na_reason" => "no merge time")
  tail_metric.value(r).nil? && tail_metric.na_reason(r).include?("no merge time")
end

check("tail: a phase metric on another phase is unchanged (reads phases.<p>.s)") do
  X::Metric.parse("phase", phase: "verify").value(trow(1, 2400)) == 600
end

# A fixture repo with post-merge CI: before, ten measured tails of 3600 s
# with three landings that had no post-merge run between them; after, ten
# measured tails of 2400 s with two such landings and one pre-DND-1532 row.
TAIL_BEFORE = (1..13).map { |i| [4, 8, 11].include?(i) ? trow(-i, 0, "merge") : trow(-i, 3600) }
TAIL_AFTER = (1..13).map { |i| i == 3 ? trow(i, 0, :absent) : ([6, 9].include?(i) ? trow(i, 0, "merge") : trow(i, 2400)) }
TAIL_ROWS = TAIL_BEFORE + TAIL_AFTER

check("tail sides: the split counts measured tails only; a no-run landing is never a 0 in either side") do
  s = X.sides(TAIL_ROWS, metric: tail_metric, exclude: [LANDING], boundary: t(RECORDED))
  s[:before].size == 10 && s[:after].size == 10 &&
    s[:before].all? { |r| r["tail_s"] == 3600 } && s[:after].all? { |r| r["tail_s"] == 2400 }
end

check("tail excluded: the landings inside the window without a measured tail are tallied by reason") do
  s = X.sides(TAIL_ROWS, metric: tail_metric, exclude: [LANDING], boundary: t(RECORDED))
  from, to = X.window(s, t(RECORDED))
  ex = X.excluded(TAIL_ROWS, metric: tail_metric, exclude: [LANDING], from: from, to: to)
  ex.sum { |e| e["count"] } == 6 &&
    ex.find { |e| e["reason"].include?("no post-merge run") }["count"] == 5 &&
    ex.find { |e| e["reason"].include?("DND-1532") }["count"] == 1
end

check("excluded: na_share excludes nothing (its n/a IS the measurement)") do
  m = X::Metric.parse(X::NA_SHARE, phase: "verify")
  X.excluded([row(1), row(2)], metric: m, exclude: [], from: t(RECORDED), to: TO).empty?
end

check("excluded: a phase metric names its null rows' reasons, landing order irrelevant") do
  m = X::Metric.parse("phase", phase: "verify")
  ex = X.excluded([row(2), row(1, verify: 5), row(3)], metric: m, exclude: [], from: t(RECORDED), to: TO)
  ex == [{ "reason" => "no critic PASS", "count" => 2 }]
end

check("excluded: a batch landing a side kept is never also excluded (one landing, one place)") do
  m = X::Metric.parse("phase", phase: "verify")
  sha = "f" * 40
  rows = [row(1, sha: sha, ticket: "DND-1"), row(1, verify: 600, sha: sha, ticket: "DND-2")]
  X.comparable(rows, metric: m, exclude: []).map { |r| r["ticket"] } == ["DND-2"] &&
    X.excluded(rows, metric: m, exclude: [], from: t(RECORDED), to: TO).empty?
end

check("excluded: reasons are tallied with the unit and SHAs made generic, as the summary does") do
  m = X::Metric.parse("phase", phase: "verify")
  rows = [1, 2, 3].map do |h|
    r = row(h, ticket: "DND-#{h}")
    r["phases"]["verify"]["na_reason"] = "worked on another machine (no local events for DND-#{h})"
    r
  end
  X.excluded(rows, metric: m, exclude: [], from: t(RECORDED), to: TO) ==
    [{ "reason" => "worked on another machine (no local events for <unit>)", "count" => 3 }]
end

check("tail judge: 3600 -> 2400 on measured tails, guards equal: keep (as for any phase)") do
  s = X.sides(TAIL_ROWS, metric: tail_metric, exclude: [LANDING], boundary: t(RECORDED))
  v = X.judge(texp, before: s[:before], after: s[:after], guards_before: guards, guards_after: guards, now: NOW)
  v["status"] == "keep" && v["before"]["median"] == 3600 && v["after"]["median"] == 2400 && v["after"]["n"] == 10
end

check("tail judge: a rising tail is a revert, as for any phase") do
  rows = TAIL_BEFORE + (1..10).map { |i| trow(i, 4000) }
  s = X.sides(rows, metric: tail_metric, exclude: [LANDING], boundary: t(RECORDED))
  X.judge(texp, before: s[:before], after: s[:after], guards_before: guards, guards_after: guards, now: NOW)["status"] == "revert"
end

check("tail judge: no measured tail before the landing is no before-set (pending), never a 0 baseline") do
  rows = (1..10).map { |i| trow(-i, 0, "merge") } + (1..10).map { |i| trow(i, 2400) }
  s = X.sides(rows, metric: tail_metric, exclude: [LANDING], boundary: t(RECORDED))
  v = X.judge(texp, before: s[:before], after: s[:after], guards_before: guards, guards_after: guards, now: NOW)
  s[:before].nil? && s[:before_na].include?("no post-merge run") && v["status"] == "pending"
end

check("tail foreign: a landing worked on another machine keeps its measured tail and counts on both sides") do
  rows = (1..10).map { |i| trow(-i, 3600, origin: i.even? ? "foreign" : "local") } +
         (1..10).map { |i| trow(i, 2400, origin: "foreign") }
  s = X.sides(rows, metric: tail_metric, exclude: [LANDING], boundary: t(RECORDED))
  s[:before].size == 10 && s[:after].size == 10
end

# ── foreign rows (DND-1628) ─────────────────────────────────────────────────
# A landing worked on another machine has its five phases null with a reason.
# Phase and n/a-share comparisons leave it out, as lead-time-phases --summary
# does, and name the count.
FOREIGN_FROM = t(RECORDED) - (11 * 3600)
FOREIGN_TO = t(RECORDED) + (11 * 3600)

def frow(hours)
  sha = format("%040x", 7 * 10**9 + (hours * 100).to_i.abs + (hours.negative? ? 1 : 2))
  row(hours, ticket: "DND-F#{hours}", sha: sha).merge("origin" => "foreign")
end

def lrow(hours, verify) = row(hours, verify: verify, ticket: "DND-L#{hours}").merge("origin" => "local")

FOREIGN_LOCAL = (1..10).map { |i| lrow(-i, i < 6 ? nil : 600) } + (1..10).map { |i| lrow(i, i < 3 ? nil : 600) }
FOREIGN_MIXED = FOREIGN_LOCAL + (1..8).map { |i| frow(i + 0.5) } + (1..8).map { |i| frow(-i - 0.5) }

def share_sides(rows)
  m = X::Metric.parse(X::NA_SHARE, phase: "verify")
  [m, X.sides(rows, metric: m, exclude: [LANDING], boundary: t(RECORDED))]
end

check("foreign na_share: sides and stats match the local-only window") do
  m, local = share_sides(FOREIGN_LOCAL)
  _, mixed = share_sides(FOREIGN_MIXED)
  X.stats(mixed[:before], m) == X.stats(local[:before], m) && X.stats(mixed[:after], m) == X.stats(local[:after], m)
end

check("foreign na_share: the verdict matches the local-only window") do
  _, local = share_sides(FOREIGN_LOCAL)
  _, mixed = share_sides(FOREIGN_MIXED)
  ex = exp(metric: X::NA_SHARE, kind: "instrumentation")
  j = ->(s) { X.judge(ex, before: s[:before], after: s[:after], guards_before: guards, guards_after: guards, now: NOW) }
  j.call(mixed) == j.call(local) && j.call(mixed)["status"] == "keep"
end

check("foreign phase: foreign rows are not tallied as n/a reasons; the count is named apart") do
  m = X::Metric.parse("phase", phase: "verify")
  ex = X.excluded(FOREIGN_MIXED, metric: m, exclude: [LANDING], from: FOREIGN_FROM, to: FOREIGN_TO)
  n = X.foreign_excluded(FOREIGN_MIXED, metric: m, exclude: [LANDING], from: FOREIGN_FROM, to: FOREIGN_TO)
  ex.none? { |e| e["reason"].include?("another machine") } && n == 16
end

check("foreign count: na_share names it too, and a window with none reports 0") do
  m = X::Metric.parse(X::NA_SHARE, phase: "verify")
  X.foreign_excluded(FOREIGN_MIXED, metric: m, exclude: [], from: FOREIGN_FROM, to: FOREIGN_TO) == 16 &&
    X.foreign_excluded(FOREIGN_LOCAL, metric: m, exclude: [], from: FOREIGN_FROM, to: FOREIGN_TO).zero?
end

check("foreign count: only phase and na_share leave foreign rows out; lead and tail keep them") do
  lead = X::Metric.parse("lead", phase: "verify")
  X.foreign_excluded(FOREIGN_MIXED, metric: lead, exclude: [], from: FOREIGN_FROM, to: FOREIGN_TO).zero? &&
    X.foreign_excluded(FOREIGN_MIXED, metric: tail_metric, exclude: [], from: FOREIGN_FROM, to: FOREIGN_TO).zero?
end

check("foreign: a row with an undecided origin counts as before") do
  m, s = share_sides((1..10).map { |i| row(-i, verify: nil) } + (1..10).map { |i| row(i, verify: 600) })
  X.stats(s[:before], m)["n"] == 10 &&
    X.foreign_excluded([row(1)], metric: m, exclude: [], from: FOREIGN_FROM, to: FOREIGN_TO).zero?
end

check("foreign text: the count is named beside the excluded reasons") do
  X.foreign_text(16).include?("16") && X.foreign_text(16).include?("another machine") && X.foreign_text(0).nil?
end

check("tail_error: a measured tail on one of the window's landings passes") do
  X.tail_error([trow(-2, 0, "merge"), trow(-1, 3600)], window: 20).nil?
end

check("tail_error: tail_end on rows but no post-merge run concluded on any: unmeasured, tallied by reason") do
  e = X.tail_error([trow(-3, 0, "merge"), trow(-2, 0, "merge"), trow(-1, 0, :absent)], window: 20)
  e[:state] == :unmeasured && e[:n] == 3 && e[:reasons].sum { |r| r["count"] } == 3
end

check("tail_error: no row carries tail_end (all ingested before DND-1532): could not look, never unmeasured") do
  e = X.tail_error([trow(-2, 0, :absent), trow(-1, 0, :absent)], window: 20)
  e[:state] == :could_not_look && e[:n] == 2
end

check("tail_error: only the last `window` landings are read") do
  rows = [trow(-5, 3600)] + (1..3).map { |i| trow(-5 + i, 0, "merge") }
  X.tail_error(rows, window: 3)[:state] == :unmeasured && X.tail_error(rows, window: 4).nil?
end

check("tail_error: an empty ledger is could not look") do
  X.tail_error([], window: 20)[:state] == :could_not_look
end

check("tail blocker: a pending tail change blocks tail only; one-pending-per-phase unchanged") do
  pend = [texp.merge("status" => "pending")]
  !X.admit?(pend, phase: "tail", kind: "change") && X.admit?(pend, phase: "verify", kind: "change") &&
    X.admit?([exp.merge("status" => "pending")], phase: "tail", kind: "change")
end

check("tail trailer: record wants `<R> tail phase`") do
  X.trailer_error("x\n\nLead-time-experiment: gen_saas tail phase\n", sha: LANDING, repo: "gen_saas", phase: "tail", metric: "phase").nil? &&
    X.trailer_error("x\n\nLead-time-experiment: gen_saas verify phase\n", sha: LANDING, repo: "gen_saas", phase: "tail", metric: "phase")
end

check("tail confound: another tail trailer inside the window confounds; a harness phase's does not") do
  c = X.confounders(texp, [tc(OTHER_SHA, 2, "Lead-time-experiment: gen_saas tail phase\n")], from: FROM, to: TO)
  n = X.confounders(texp, [tc(OTHER_SHA, 2, "Lead-time-experiment: gen_saas verify phase\n")], from: FROM, to: TO)
  c[:confounders].size == 1 && n[:confounders].empty?
end

check("revert_route: tail (lever product) reverts by a PR in the measured repo through its own bar") do
  r = X.revert_route(texp.merge("repo" => "gen_saas"), harness: "custom")
  r.include?("PR in gen_saas") && r.include?("its own bar") && r.include?("DND-1540") &&
    X.revert_route(texp.merge("repo" => "gen_saas"), harness: nil).include?("PR in gen_saas")
end

check("revert_route: a same-repo change in a repo other than the harness repo is a product revert too") do
  X.revert_route(exp.merge("repo" => "gen_saas"), harness: "custom").include?("PR in gen_saas")
end

check("revert_route: a harness change has none (custom's own, or cross-repo landed in custom)") do
  X.revert_route(exp, harness: "custom").nil? &&
    X.revert_route(exp.merge("repo" => "gen_saas", "change_repo" => "custom"), harness: "custom").nil? &&
    X.revert_route(exp.merge("repo" => "gen_saas"), harness: nil).nil?
end

check("hold_text: a held tail revert routes its partial revert through the product repo's PR") do
  txt = X.hold_text("gen_saas", "i", LANDING, { "tests" => ["apps/x/test/a_test.exs"] }, nil,
                    trailer: "Lead-time-experiment: gen_saas tail phase",
                    route: X.revert_route(texp.merge("repo" => "gen_saas"), harness: "custom"))
  txt.include?("apps/x/test/a_test.exs") && txt.include?("PR in gen_saas") && txt.include?("Lead-time-experiment: gen_saas tail phase")
end

check("tail_change_repo_error: a tail change must land in the measured repo itself (the product lever)") do
  X.tail_change_repo_error("tail", "gen_saas", "custom").include?("lands in gen_saas itself") &&
    X.tail_change_repo_error("tail", "gen_saas", "gen_saas").nil? &&
    X.tail_change_repo_error("verify", "gen_saas", "custom").nil?
end

check("record_error: a tail record parses; a tail record on another metric is malformed") do
  rec = texp.merge("commit" => LANDING)
  X.record_error(rec).nil? && X.record_error(rec.merge("metric" => "lead")).to_s.include?("tail")
end

# ── settling: a clean baseline before a change lands (DND-1622) ────────────
# The before-set a change recorded at `now` would get, and the confounders
# judge would find in it. now = RECORDED; ten600 lands at -1h..-10h.

SET_NOW = t(RECORDED)
REVERT_MSG = "Revert x\n\nThis reverts commit #{THIRD_SHA}.\n\nLead-time-experiment: custom verify phase\n"

def settle(rows, commits, metric: "phase", phase: "verify")
  X.settling(rows, commits, phase: phase, metric: metric, now: SET_NOW)
end

check("settling 1: a revert commit inside the would-be before-set: SETTLING, named, needed = K - after_count") do
  s = settle(ten600, [tc(OTHER_SHA, -5, REVERT_MSG)])
  s["verdict"] == "SETTLING" && s["confounders"].map { |c| c["commit"] } == [OTHER_SHA] &&
    s["latest"]["commit"] == OTHER_SHA && s["after_latest"] == 4 && s["needed"] == 6 && s["confounded"]
end

check("settling 2: a predecessor change (settled inconclusive) inside the before-set: SETTLING") do
  s = settle(ten600, [tc(OTHER_SHA, -2.5, "y\n\nLead-time-experiment: custom verify phase\n")])
  s["verdict"] == "SETTLING" && s["after_latest"] == 2 && s["needed"] == 8
end

check("settling 3: the latest same-phase trailer older than the before-set's first landing: CLEAN") do
  older = settle(ten600, [tc(OTHER_SHA, -11, REVERT_MSG)])
  # K landings have followed the trailer: the oldest of fifteen is outside the last ten
  fifteen = settle(before_rows([600] * 15), [tc(OTHER_SHA, -12, REVERT_MSG)])
  older["verdict"] == "CLEAN" && older["confounders"].empty? && older["needed"].zero? &&
    fifteen["verdict"] == "CLEAN" && fifteen["before"]["n"] == 10 && !fifteen["confounded"]
end

check("settling 4: a same-phase na_share (instrumentation) trailer inside: CLEAN") do
  settle(ten600, [tc(OTHER_SHA, -3, "Lead-time-experiment: custom verify na_share\n")])["verdict"] == "CLEAN"
end

check("settling 5: another phase's trailer inside: CLEAN") do
  settle(ten600, [tc(OTHER_SHA, -3, "Lead-time-experiment: custom queue phase\n")])["verdict"] == "CLEAN"
end

check("settling 6: the same phase from another measured repo's trailer: SETTLING (one harness serves every repo)") do
  s = settle(ten600, [tc(OTHER_SHA, -3, "Lead-time-experiment: gen_saas verify phase\n")])
  s["verdict"] == "SETTLING" && s["confounders"][0]["repo"] == "gen_saas"
end

check("settling 7: fewer than K comparable landings: SHORT, and a confounder is still named") do
  short = settle(before_rows([600] * 6), [tc(OTHER_SHA, -3, REVERT_MSG)])
  none = settle([], [])
  short["verdict"] == "SHORT" && short["before"]["n"] == 6 && short["short_by"] == 4 &&
    short["confounders"].map { |c| c["commit"] } == [OTHER_SHA] && short["confounded"] &&
    none["verdict"] == "SHORT" && none["before"].nil? && none["before_na"].include?("no before-set") &&
    none["short_by"] == X::K && !none["confounded"]
end

check("settling: the window is [first before-set landing, now], as judge's for a change landing at now") do
  s = settle(ten600, [])
  s["window"] == [(SET_NOW - (10 * 3600)).utc.iso8601, SET_NOW.utc.iso8601]
end

check("settling: two confounders from two repos' logs, newest first (git log order): latest is the newest") do
  # harness repo's log, then the measured repo's, each newest first
  s = settle(ten600, [tc(OTHER_SHA, -2, REVERT_MSG), tc(THIRD_SHA, -8, "Lead-time-experiment: custom verify phase\n"),
                      tc("c" * 40, -5, "Lead-time-experiment: gen_saas verify phase\n")])
  s["verdict"] == "SETTLING" && s["confounders"].map { |c| c["commit"] } == [THIRD_SHA, "c" * 40, OTHER_SHA] &&
    s["latest"]["commit"] == OTHER_SHA && s["after_latest"] == 1 && s["needed"] == 9
end

check("settling: a confounder exactly at the first before-set landing is inside; that landing does not count after it") do
  s = settle(ten600, [tc(OTHER_SHA, -10, REVERT_MSG)])
  s["verdict"] == "SETTLING" && s["after_latest"] == 9 && s["needed"] == 1
end

check("settling_window: the window settling reads its logs from, from the ledger alone") do
  X.settling_window(ten600, phase: "verify", metric: "phase", now: SET_NOW) ==
    [SET_NOW - (10 * 3600), SET_NOW]
end

check("settling: a confounder later than the newest landing needs all K") do
  s = settle(ten600, [tc(OTHER_SHA, -0.5, REVERT_MSG)])
  s["verdict"] == "SETTLING" && s["after_latest"].zero? && s["needed"] == X::K
end

check("settling: an unknown phase or metric is a usage error, as record's parse is") do
  [["phase", "nope"], ["nope", "verify"]].all? do |m, p|
    settle(ten600, [], metric: m, phase: p)
    false
  rescue X::UsageError
    true
  end
end

check("settling: na_share is checked for series breaks only, never for trailers (DND-1810)") do
  # An instrumentation change is exempt from trailers, so a change trailer
  # inside leaves it CLEAN; a declared break on its phase does not.
  trailer = settle(ten600, [tc(OTHER_SHA, -3, REVERT_MSG)], metric: "na_share")
  brk = X.settling(ten600, [], phase: "verify", metric: "na_share", now: SET_NOW,
                               breaks: [{ "ticket" => "DND-9001", "commit" => OTHER_SHA, "phases" => ["verify"],
                                          "what" => "w", "at" => (SET_NOW - (3 * 3600)).utc.iso8601 }])
  trailer["verdict"] == "CLEAN" && trailer["confounders"].empty? && brk["verdict"] == "SETTLING" && brk["confounded"]
end

# What judge says of a change recorded at `now` (landing at now) with no new
# trailers: the same functions judge's manager calls, in the same order.
def judged_at_now(rows, commits, phase: "verify", metric: "phase")
  e = exp(phase: phase, metric: metric, recorded_at: SET_NOW.utc.iso8601).merge("commit" => LANDING)
  landed = rows + [row(0, verify: 600, sha: LANDING)]
  split = X.split(e, landed)
  m = X::Metric.parse(metric, phase: phase)
  s = X.sides(landed, metric: m, exclude: split[:exclude], boundary: split[:boundary])
  v = X.judge(e, before: s[:before], after: s[:after], guards_before: nil, guards_after: nil, now: SET_NOW)
  from, to = X.window(s, split[:boundary])
  X.confound(v, X.confounders(e, commits, from: from, to: to)[:confounders], phase: phase)
end

check("settling 8: agreement: SETTLING <=> judge reads confounded, over every fixture") do
  fixtures = [
    [ten600, [tc(OTHER_SHA, -5, REVERT_MSG)]],
    [ten600, [tc(OTHER_SHA, -2.5, "y\n\nLead-time-experiment: custom verify phase\n")]],
    [ten600, [tc(OTHER_SHA, -11, REVERT_MSG)]],
    [ten600, [tc(OTHER_SHA, -10, REVERT_MSG)]], # the window's first edge is inside
    [ten600, [tc(OTHER_SHA, -3, "Lead-time-experiment: custom verify na_share\n")]],
    [ten600, [tc(OTHER_SHA, -3, "Lead-time-experiment: custom queue phase\n")]],
    [ten600, [tc(OTHER_SHA, -3, "Lead-time-experiment: gen_saas verify phase\n")]],
    [ten600, [tc(OTHER_SHA, -3, "Lead-time-experiment: custom\n")]],
    [ten600, []],
    [before_rows([600] * 15), [tc(OTHER_SHA, -12, REVERT_MSG)]],
    [before_rows([600] * 6), [tc(OTHER_SHA, -3, REVERT_MSG)]],
    [before_rows([600] * 6), []],
  ]
  fixtures.all? do |rows, commits|
    s = settle(rows, commits)
    confounded = judged_at_now(rows, commits)["status"] == "confounded"
    # Where the before-set is full, the verdict itself agrees; on SHORT the
    # `confounded` field carries it (judge never reaches keep/revert there).
    s["confounded"] == confounded && (s["verdict"] == "SHORT" || ((s["verdict"] == "SETTLING") == confounded))
  end
end

check("settling 9: the miss: a malformed trailer is reported as malformed, never a confounder, never dropped") do
  s = settle(ten600, [tc(OTHER_SHA, -3, "Lead-time-experiment: custom\n")])
  s["verdict"] == "CLEAN" && s["confounders"].empty? &&
    s["malformed"] == [{ "commit" => OTHER_SHA, "value" => "custom", "why" => "no phase after custom" }]
end

check("settling: text names each confounder, the latest, and the landings still needed") do
  txt = X.settling_text("custom", settle(ten600, [tc(OTHER_SHA, -5, REVERT_MSG)]))
  txt.start_with?("experiment settling: custom verify phase SETTLING") && txt.include?(OTHER_SHA[0, 12]) &&
    txt.include?("clean after 6 more comparable landings")
end

check("settling: text for CLEAN, SHORT and a malformed trailer") do
  clean = X.settling_text("custom", settle(ten600, []))
  short = X.settling_text("custom", settle(before_rows([600] * 6), []))
  bad = X.settling_text("custom", settle(ten600, [tc(OTHER_SHA, -3, "Lead-time-experiment: custom\n")]))
  short_conf = X.settling_text("custom", settle(before_rows([600] * 6), [tc(OTHER_SHA, -3, REVERT_MSG)]))
  clean.include?("CLEAN") && clean.include?("n=10 of K=10") && short.include?("SHORT") && short.include?("4 more") &&
    !short.include?("clean after") && short_conf.include?("judge would read confounded") &&
    short_conf.include?("clean after 8 more comparable landings") &&
    bad.include?("malformed") && bad.include?("not counted as a confounder")
end

# ── declared series breaks (DND-1810) ───────────────────────────────────────
# A change to how a phase is measured: before and after it the ledger
# measures the phase by different rules. The registry holds them; the
# manager adds each break's landing time ("at").

BRK_SHA = "b" * 40

def brk(hours, phases = ["verify"], sha: BRK_SHA, ticket: "DND-9001")
  { "ticket" => ticket, "commit" => sha, "phases" => phases, "what" => "a measurement change",
    "at" => (t(RECORDED) + (hours * 3600)).utc.iso8601 }
end

def registry(*rows) = { "schema" => 1, "breaks" => rows.map { |r| r.except("at") } }

check("series_breaks: a well-formed registry reads its breaks, ticket and commit first") do
  b, why = X.series_breaks(registry(brk(1, %w[verify queue])))
  why.nil? && b.size == 1 && b[0].keys.first(2) == %w[ticket commit] && b[0]["phases"] == %w[verify queue]
end
check("series_breaks: an empty list is read, and is not an error") do
  X.series_breaks(registry) == [[], nil]
end
check("series_breaks: every malformed shape is an error naming it, never an empty list") do
  bad = {
    "not a JSON object" => [],
    "schema" => { "schema" => 2, "breaks" => [] },
    "no breaks list" => { "schema" => 1 },
    "ticket" => registry(brk(1).merge("ticket" => "")),
    "40-hex" => registry(brk(1).merge("commit" => "abc")),
    "unknown phase \"verfy\"" => registry(brk(1, ["verfy"])),
    "phases" => registry(brk(1, [])),
    "what" => registry(brk(1).merge("what" => " ")),
  }
  bad.all? do |needle, data|
    b, why = X.series_breaks(data)
    b.nil? && why.to_s.include?(needle)
  end
end
check("series_breaks: tail is a phase a break may name") do
  X.series_breaks(registry(brk(1, ["tail"])))[1].nil?
end

check("breaks_inside: a break on the phase inside the window, edges included") do
  inside = X.breaks_inside(exp, [brk(-10, sha: "1" * 40), brk(3, sha: "2" * 40), brk(10, sha: "3" * 40)], from: FROM, to: TO)
  inside.map { |b| b["commit"] } == ["1" * 40, "2" * 40, "3" * 40]
end
check("breaks_inside: outside the window, or on another phase, has no effect") do
  X.breaks_inside(exp, [brk(-11), brk(11), brk(2, ["queue"])], from: FROM, to: TO).empty?
end
check("breaks_inside: the experiment's own commit is not a break against itself") do
  X.breaks_inside(exp, [brk(0, sha: LANDING)], from: FROM, to: TO).empty?
end
check("breaks_inside: an instrumentation experiment is NOT exempt (a break changes what n/a means)") do
  X.breaks_inside(exp(kind: "instrumentation", metric: "na_share"), [brk(2)], from: FROM, to: TO).size == 1
end

check("confound: a declared break makes a keep confounded, naming the break and what it read") do
  v = X.confound(KEEP_V, [], phase: "verify", breaks: [brk(2, %w[verify implement])])
  v["status"] == "confounded" && v["breaks"] == [brk(2, %w[verify implement])] && !v.key?("confounders") &&
    v["reason"].include?("a declared series break on verify landed inside the window: DND-9001 #{BRK_SHA[0, 12]} " \
                         "(verify/implement, #{brk(2)['at']})") &&
    v["reason"].include?("unconfounded it read keep")
end
check("confound: a trailer and a break are both named") do
  v = X.confound(KEEP_V, CONF, phase: "verify", breaks: [brk(2)])
  v["confounders"] == CONF && v["breaks"].size == 1 && v["reason"].include?("another experiment's change") &&
    v["reason"].include?("a declared series break")
end
check("confound: neither leaves the verdict alone") { X.confound(KEEP_V, [], phase: "verify", breaks: []) == KEEP_V }

GUARD_REVERT = KEEP_V.merge("status" => "revert", "reason" => "guard worsened: gate_red_rate 0.0 -> 0.2",
                            "guards" => { "gate_red_rate" => { "before" => 0.0, "after" => 0.2, "state" => "worse" } }).freeze
check("confound: a revert a worse guard drove stands against a break, and names it") do
  v = X.confound(GUARD_REVERT, [], phase: "verify", breaks: [brk(2)])
  v["status"] == "revert" && v["breaks"] == [brk(2)] && v["reason"].start_with?("guard worsened") &&
    v["reason"].include?("the revert stands") && v["reason"].include?("DND-9001")
end
check("confound: a median-only revert is confounded by a break") do
  median = KEEP_V.merge("status" => "revert", "reason" => "median rose 500s -> 600s",
                        "guards" => { "gate_red_rate" => { "state" => "ok" } })
  X.confound(median, [], phase: "verify", breaks: [brk(2)])["status"] == "confounded"
end
check("confound: a trailer confounder still confounds a guard revert (DND-1529, unchanged)") do
  X.confound(GUARD_REVERT, CONF, phase: "verify", breaks: [brk(2)])["status"] == "confounded"
end
check("last_verdict: the row's own fields and held are dropped, the verdict kept") do
  e = exp.merge("last" => { "type" => "status", "schema" => 1, "id" => "i", "judged_at" => "x", "status" => "revert",
                            "reason" => "r", "held" => { "tests" => ["t/a_test.rb"] }, "guards" => {} })
  X.last_verdict(e) == { "status" => "revert", "reason" => "r", "guards" => {} } && X.last_verdict(exp) == {}
end
check("breaks_inside: a break with no readable at raises, never reads as no break") do
  X.breaks_inside(exp, [brk(2).merge("at" => nil)], from: FROM, to: TO)
  false
rescue ArgumentError => e
  e.message.include?("DND-9001")
end

check("settling: a break inside the would-be before-set is SETTLING, named, needed = K - after it") do
  s = X.settling(ten600, [], phase: "verify", metric: "phase", now: SET_NOW, breaks: [brk(-5)])
  s["verdict"] == "SETTLING" && s["breaks"].map { |b| b["ticket"] } == ["DND-9001"] && s["confounders"].empty? &&
    s["after_latest"] == 4 && s["needed"] == 6 && s["confounded"] &&
    X.settling_text("custom", s).include?("series break(s) in the window: DND-9001 #{BRK_SHA[0, 12]}")
end
check("settling: a break on another phase, or before the window, is CLEAN") do
  %w[queue].all? do |p|
    X.settling(ten600, [], phase: "verify", metric: "phase", now: SET_NOW, breaks: [brk(-5, [p]), brk(-11)])["verdict"] == "CLEAN"
  end
end
check("settling: the latest of a trailer and a break decides how many more landings are needed") do
  s = X.settling(ten600, [tc(OTHER_SHA, -8, REVERT_MSG)], phase: "verify", metric: "phase", now: SET_NOW, breaks: [brk(-2.5)])
  s["latest"]["commit"] == BRK_SHA && s["after_latest"] == 2 && s["needed"] == 8
end

check("the tracked registry is well formed (ai/config/lead-time-series-breaks.json)") do
  path = File.expand_path("../../../config/lead-time-series-breaks.json", __dir__)
  b, why = X.series_breaks(JSON.parse(File.read(path)))
  why.nil? && b.map { |x| x["ticket"] } == %w[DND-1501 DND-1809 DND-1819]
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
