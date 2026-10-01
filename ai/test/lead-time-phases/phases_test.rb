# frozen_string_literal: true

# Deterministic suite for ai/lib/lead_time_phases.rb (domain) and
# ai/lib/lead_time_phases_io.rb (side effects), DND-1477. Run by
# `ai/bin/lead-time-phases --self-test` and ai/test/lead-time-phases/self-test.sh,
# which harness-gate discovers.
#
# TDD order: the domain first, then the IO readers and stores against temp
# dirs. Functional only (DND-1222): no sleeps, no timing, no load. Every time
# is a fixed fixture value. Ids are synthetic (DND-9001, ZQ-12).

require "json"
require "tmpdir"
require "fileutils"
require "time"
require_relative "../../lib/lead_time_phases"

L = LeadTimePhases
S = L::Source

$failures = []
$checks = 0

def check(desc)
  $checks += 1
  $failures << desc unless yield
rescue StandardError => e
  $failures << "#{desc} (raised #{e.class}: #{e.message})"
end

def t(iso) = Time.iso8601(iso).utc

HEAD = "a" * 40
OTHER = "b" * 40

def ev(name, at, unit: "DND-9001", head: HEAD, duration_s: nil, attrs: {})
  { "v" => 1, "event" => name, "at" => at, "duration_s" => duration_s, "unit" => unit,
    "head" => head, "attrs" => attrs }
end

def landing(ticket: "DND-9001", start: "2026-10-01T01:00:00Z", landed: "2026-10-01T05:00:00Z", commit: HEAD)
  { "ticket" => ticket, "landed_commit" => commit, "gated_head" => commit, "gated_head_na" => nil,
    "landed_at" => t(landed), "landed_via" => "push",
    "pr" => nil, "start" => start && t(start), "start_na" => start ? nil : "no stamp",
    "lead_s" => nil, "code_s" => nil, "tail_s" => nil, "lead_na_reason" => nil }
end

# A full, ordered set of events for DND-9001 on HEAD.
FULL = [
  ev("harness_gate.run", "2026-10-01T02:00:00.400Z", duration_s: 100.0, attrs: { "ok" => false, "run_id" => "r1" }),
  ev("harness_gate.run", "2026-10-01T02:30:00Z", duration_s: 120.5, attrs: { "ok" => true, "run_id" => "r2" }),
  ev("harness_gate.run", "2026-10-01T03:00:00Z", duration_s: 90.0, attrs: { "ok" => true, "run_id" => "r3" }),
  ev("critic.round", "2026-10-01T03:05:00Z", duration_s: 60.0, attrs: { "verdict" => "block" }),
  ev("critic.round", "2026-10-01T03:20:00Z", duration_s: 45.0, attrs: { "verdict" => "pass" }),
  ev("integration_gate.run", "2026-10-01T04:00:00Z", duration_s: 300.0, attrs: { "exit_code" => 0 }),
  ev("test_slot.wait", "2026-10-01T02:29:00Z", duration_s: 41.5),
  ev("merge.lock_wait", "2026-10-01T04:50:00Z", duration_s: 2.0),
].freeze

NO_RECEIPT = S.empty("no receipt")
NO_VERDICTS = S.empty("no verdicts")

def anchors(l, events, receipt: NO_RECEIPT, verdicts: NO_VERDICTS)
  L::Anchors.from(landing: l, events: events, receipt: receipt, verdicts: verdicts)
end

# ── Phases.compute ─────────────────────────────────────────────────────────

l = landing
ph = L::Phases.compute(anchors(l, S.ok(FULL)))
check("P1 all anchors ordered: five measured phases") { L::PHASES.all? { |p| ph[p]["s"].is_a?(Integer) } }
check("P1 the phases sum to landing - dispatch exactly") do
  ph.values.sum { |c| c["s"] } == (l["landed_at"] - l["start"]).to_i
end
check("P1 implement = dispatch -> first gate (floored)") { ph["implement"]["s"] == 3600 }
check("P1 verify ends at the PASS round's end") { ph["verify"]["s"] == (t("2026-10-01T03:20:45Z") - t("2026-10-01T02:00:00Z")).to_i }
check("P1 integrate is the run's duration") { ph["integrate"]["s"] == 300 }
check("P1 merge = integration end -> landing") { ph["merge"]["s"] == (t("2026-10-01T05:00:00Z") - t("2026-10-01T04:05:00Z")).to_i }

no_gate = FULL.reject { |e| e["event"].start_with?("harness_gate") }
receipt = S.ok([{ "recorded_at" => "2026-10-01T04:10:00Z" }])
ph2 = L::Phases.compute(anchors(l, S.ok(no_gate.reject { |e| e["event"] == "integration_gate.run" }), receipt: receipt))
check("P2 no gate events: implement is null") { ph2["implement"]["s"].nil? }
check("P2 no gate events: verify is null") { ph2["verify"]["s"].nil? }
check("P2 the reason names the unit and both gate events") { ph2["implement"]["na_reason"] == "no harness_gate.run or gate.run for DND-9001" }
check("P2 merge is still measured from the receipt") { ph2["merge"]["s"] == 50 * 60 }
check("P2 integrate is n/a: the receipt gives the end only") { ph2["integrate"]["s"].nil? && ph2["integrate"]["na_reason"].include?("the receipt gives the end only") }

no_integ = FULL.reject { |e| e["event"] == "integration_gate.run" }
ph3 = L::Phases.compute(anchors(l, S.ok(no_integ)))
check("P3 no receipt, no run: queue/integrate/merge are null") { %w[queue integrate merge].all? { |p| ph3[p]["s"].nil? } }
check("P3 each carries a reason") { %w[queue integrate merge].all? { |p| ph3[p]["na_reason"].to_s.include?("no integration_gate.run on #{HEAD[0, 8]}") } }
check("P3 the receipt miss is named") { ph3["merge"]["na_reason"].include?("no integration receipt for") }

early = [ev("harness_gate.run", "2026-10-01T00:30:00Z", duration_s: 10.0)] + FULL
ph4 = L::Phases.compute(anchors(l, S.ok(early)))
check("P4 a gate before the dispatch stamp: implement is invalid") { ph4["implement"]["invalid"] == true && ph4["implement"]["s"].nil? }
check("P4 never negative") { ph4.values.none? { |c| c["s"].is_a?(Integer) && c["s"].negative? } }
check("P4 the invalid reason names both anchors") { ph4["implement"]["na_reason"].start_with?("invalid: gate_first") }

json = JSON.parse(JSON.generate(ph2))
check("P5 a null phase serializes as JSON null plus na_reason, never 0") do
  json["implement"]["s"].nil? && json["implement"].key?("s") && !json["implement"]["na_reason"].to_s.empty?
end

# The miss tests: a store that could not be read never reads as "no events".
ph6 = L::Phases.compute(anchors(l, S.could_not_look("no telemetry store at /x")))
check("P6 no telemetry store: implement reads could not look") { ph6["implement"]["na_reason"] == "telemetry: could not look (no telemetry store at /x)" }
check("P6 could-not-look and found-nothing read differently") { ph6["implement"]["na_reason"] != ph2["implement"]["na_reason"] }

unt = landing(ticket: nil, start: nil)
ph7 = L::Phases.compute(anchors(unt, S.ok(FULL.map { |e| e.merge("unit" => "some-branch") })))
check("P7 unticketed: implement and verify n/a") { ph7["implement"]["s"].nil? && ph7["verify"]["s"].nil? }
check("P7 unticketed: integrate and merge measured by head") { ph7["integrate"]["s"] == 300 && ph7["merge"]["s"].is_a?(Integer) }

# A --with-critic PASS that ran inside the integration run is not a queue anchor.
inside = FULL.reject { |e| e["event"] == "critic.round" } +
         [ev("critic.round", "2026-10-01T04:01:00Z", duration_s: 30.0, attrs: { "verdict" => "pass" })]
ph8 = L::Phases.compute(anchors(l, S.ok(inside)))
check("P8 a PASS only inside integration-gate: verify and queue n/a, named") do
  ph8["queue"]["s"].nil? && ph8["queue"]["na_reason"].include?("--with-critic")
end
verdict = S.ok([{ "verdict" => "pass", "at" => "2026-10-01T03:40:00Z" }])
ph9 = L::Phases.compute(anchors(l, S.ok(inside), verdicts: verdict))
check("P9 a verdict receipt on the head is a PASS candidate") { ph9["queue"]["s"] == 20 * 60 }

after = FULL + [ev("harness_gate.run", "2026-10-01T06:00:00Z", duration_s: 5.0)]
ph10 = L::Phases.compute(anchors(l, S.ok(after)))
check("P10 events after the landing are ignored") { ph10 == ph }

# Review round (code-reviewer + adr-reviewer), DND-1477.
second = landing(start: "2026-10-01T01:00:00Z", landed: "2026-10-01T09:00:00Z", commit: OTHER)
late = [ev("harness_gate.run", "2026-10-01T07:00:00Z", head: OTHER, duration_s: 50.0, attrs: { "ok" => true })]
bounded = L::Landing.with_bounds([second], [{ "ticket" => "DND-9001", "landed_at" => "2026-10-01T05:00:00Z" }])
check("R1 a second landing of a ticket is bounded by the first") { bounded[0]["after"] == t("2026-10-01T05:00:00Z") }
c_two = L::Counters.compute(landing: bounded[0], events: S.ok(FULL + late), timings: S.empty("none"))
check("R1 the second landing never re-counts the first landing's gate runs") { c_two["counters"]["gate_runs"] == 1 }
a_two = anchors(bounded[0], S.ok(FULL + late))
check("R1 its first gate is its own") { a_two["gate_first"].at == t("2026-10-01T07:00:00Z") }
check("R1 an unticketed landing gets no bound") { L::Landing.with_bounds([unt], [])[0]["after"].nil? }
both = L::Landing.with_bounds([landing, second], [])
check("R1 bounds also come from the same batch") { both[1]["after"] == t("2026-10-01T05:00:00Z") && both[0]["after"].nil? }

dirty = FULL.reject { |e| e["event"] == "critic.round" } +
        [ev("critic.round", "2026-10-01T03:20:00Z", duration_s: 45.0, attrs: { "verdict" => "pass", "dirty" => true })]
check("R2 a dirty PASS is never a verify anchor") { anchors(l, S.ok(dirty))["critic_pass"].at.nil? }
dirty_receipt = S.ok([{ "verdict" => "pass", "at" => "2026-10-01T03:40:00Z", "dirty" => true }])
check("R2 a dirty verdict receipt is never one either") { anchors(l, S.ok(dirty), verdicts: dirty_receipt)["critic_pass"].at.nil? }

merged = landing(commit: OTHER).merge("landed_via" => "merge", "gated_head" => nil, "gated_head_na" => "no head")
ph_m = L::Phases.compute(anchors(merged, S.ok(FULL)))
check("R3 a merge landing joins integration by unit, not the squash sha") { ph_m["integrate"]["s"] == 300 }

nodur = FULL.map { |e| e["event"] == "test_slot.wait" ? e.merge("duration_s" => nil) : e }
c_nd = L::Counters.compute(landing: l, events: S.ok(nodur), timings: S.empty("none"))
check("R4 a wait with no duration is null with a reason, never 0") do
  c_nd["counters"]["slot_wait_s"].nil? && c_nd["counters_na"]["slot_wait_s"].include?("no duration_s")
end

inv = [1, 2].map do |i|
  { "ticket" => "DND-#{i}", "landed_commit" => "c#{i}" * 8,
    "phases" => { "implement" => { "s" => nil, "invalid" => true,
                                   "na_reason" => "invalid: gate_first (2026-10-0#{i}T00:00:00Z) is before dispatch (2026-10-0#{i}T01:00:00Z)" } } }
end
check("R5 invalid reasons group across rows") { L::Stats.summarize(inv)["phases"]["implement"]["na_reasons"].first["count"] == 2 }

rec_only = S.ok([{ "recorded_at" => "2026-10-01T04:10:00Z" }])
inside_rec = FULL.reject { |e| %w[critic.round integration_gate.run].include?(e["event"]) } +
             [ev("critic.round", "2026-10-01T04:20:00Z", duration_s: 30.0, attrs: { "verdict" => "pass" })]
check("R6 with only the receipt end known, a PASS after it is not chosen") do
  anchors(l, S.ok(inside_rec), receipt: rec_only)["critic_pass"].at.nil?
end

faulty = landing(ticket: nil, start: nil).merge("ticket_na" => "the ticket-ref parser did not load")
check("R7 a ticket that could not be read never reads as unticketed") do
  anchors(faulty, S.ok([]))["gate_first"].reason == "ticket: could not look (the ticket-ref parser did not load)"
end

mixed = S.ok([ev("harness_gate.run", "2026-10-01T02:00:00Z").merge("repo" => "custom"),
              ev("harness_gate.run", "2026-10-01T01:30:00Z").merge("repo" => "gen_saas")])
check("R8 events are scoped to the repo they were written in") { L.scope_events(mixed, "custom").items.size == 1 }
stopped = FULL + [ev("harness_gate.run", "2026-10-01T03:10:00Z", duration_s: 5.0, attrs: { "ok" => false, "interrupted" => true })]
check("R10 an interrupted gate run is counted but never red") do
  c = L::Counters.compute(landing: l, events: S.ok(stopped), timings: S.empty("none"))["counters"]
  c["gate_runs"] == 4 && c["gate_red"] == 1
end
check("R9 an empty window's reverts are null with a reason") { L::Guards.compute([], reverts: nil)["reverts"]["value"].nil? }

# ── Counters.compute ───────────────────────────────────────────────────────

c = L::Counters.compute(landing: l, events: S.ok(FULL), timings: S.empty("none"))
check("C1 three gate runs") { c["counters"]["gate_runs"] == 3 }
check("C1 the summed gate wall") { c["counters"]["gate_wall_s"] == 310.5 }
check("C1 one red gate run") { c["counters"]["gate_red"] == 1 }
check("C1 two critic rounds, one BLOCK") { c["counters"]["critic_rounds"] == 2 && c["counters"]["critic_blocks"] == 1 }
check("C1 critic wall") { c["counters"]["critic_wall_s"] == 105.0 }
check("C1 slot wait and lock wait") { c["counters"]["slot_wait_s"] == 41.5 && c["counters"]["lock_wait_s"] == 2.0 }

checks = (1..7).map { |i| ev("harness_gate.check", "2026-10-01T03:00:0#{i}Z", duration_s: i * 1.0, attrs: { "run_id" => "r3", "label" => "c#{i}" }) } +
         [ev("harness_gate.check", "2026-10-01T02:00:00Z", duration_s: 99.0, attrs: { "run_id" => "r1", "label" => "old" })]
c2 = L::Counters.compute(landing: l, events: S.ok(checks), timings: S.ok([{ "label" => "t", "wall_s" => 500.0, "at" => "x" }]))
check("C2 top 5 from the head's last gate run, telemetry first") do
  c2["top_checks"].map { |x| x["label"] } == %w[c7 c6 c5 c4 c3] && c2["top_checks_source"].start_with?("telemetry")
end
timings = S.ok([{ "label" => "x", "wall_s" => 3.0, "at" => "2026-10-01T01:00:00Z" },
                { "label" => "x", "wall_s" => 9.0, "at" => "2026-10-01T02:00:00Z" },
                { "label" => "y", "wall_s" => 5.0, "at" => "2026-10-01T02:00:00Z" }])
c3 = L::Counters.compute(landing: l, events: S.ok([]), timings: timings)
check("C2 empty telemetry: from the timings rows of the newest run") do
  c3["top_checks"] == [{ "label" => "x", "wall_s" => 9.0 }, { "label" => "y", "wall_s" => 5.0 }] &&
    c3["top_checks_source"] == "harness-gate timings.jsonl"
end
c4 = L::Counters.compute(landing: l, events: S.ok([]), timings: S.could_not_look("no timings file"))
check("C2 both empty: null with a reason naming both sources") do
  c4["top_checks"].nil? && c4["top_checks_na"].include?("no harness_gate.check") && c4["top_checks_na"].include?("timings: could not look")
end
# check_walls (DND-1548): every check of the head's last gate run, by label.
# top_checks is read from it, so the two can never disagree.
check("C4 check_walls holds every label of the head's last gate run (telemetry)") do
  c2["check_walls"] == (1..7).to_h { |i| ["c#{i}", i * 1.0] } && !c2.key?("check_walls_na")
end
check("C4 top_checks equals top(check_walls) on the same fixture") do
  c2["top_checks"] == L::Counters.top(c2["check_walls"]) && c3["top_checks"] == L::Counters.top(c3["check_walls"])
end
check("C4 check_walls from the timings rows of the newest run") { c3["check_walls"] == { "x" => 9.0, "y" => 5.0 } }
check("C4 timings: only the head's LAST gate run counts; a label from an older run is absent, never stale") do
  runs = S.ok([{ "label" => "x", "wall_s" => 3.0, "at" => "2026-10-01T01:00:00Z", "tree" => "/w" },
               { "label" => "z", "wall_s" => 7.0, "at" => "2026-10-01T01:00:00Z", "tree" => "/w" },
               { "label" => "x", "wall_s" => 9.0, "at" => "2026-10-01T02:00:00Z", "tree" => "/w" }])
  got = L::Counters.compute(landing: l, events: S.ok([]), timings: runs)
  got["check_walls"] == { "x" => 9.0 } && got["top_checks"] == [{ "label" => "x", "wall_s" => 9.0 }]
end
check("C4 no source: no check_walls, and check_walls_na carries top_checks_na's reason") do
  !c4.key?("check_walls") && c4["check_walls_na"] == c4["top_checks_na"] && !c4["check_walls_na"].to_s.empty?
end
check("C4 a check with no numeric wall is left out of check_walls, never 0") do
  odd = [ev("harness_gate.check", "2026-10-01T03:00:01Z", duration_s: nil, attrs: { "run_id" => "r3", "label" => "nowall" }),
         ev("harness_gate.check", "2026-10-01T03:00:02Z", duration_s: 4.0, attrs: { "run_id" => "r3", "label" => "w" })]
  L::Counters.compute(landing: l, events: S.ok(odd), timings: S.empty("none"))["check_walls"] == { "w" => 4.0 }
end
check("C3 a counter with no source events is null with a reason, never 0") do
  c4["counters"]["gate_runs"].nil? && c4["counters_na"]["gate_runs"] == "no harness_gate.run or gate.run for DND-9001"
end

# ── gate.run: a declared gate other than harness-gate, run under test-slot
# (DND-1530). It anchors implement/verify and feeds the gate counters exactly
# as harness_gate.run does.
GATE_RUNS = [
  ev("gate.run", "2026-10-01T02:00:00.400Z", duration_s: 100.0, attrs: { "gate" => "bin/prep-commit.sh", "ok" => false, "exit" => 1, "slot_wait_s" => 4.0 }),
  ev("gate.run", "2026-10-01T02:30:00Z", duration_s: 120.5, attrs: { "gate" => "bin/prep-commit.sh", "ok" => true, "exit" => 0, "slot_wait_s" => 0.0 }),
].freeze
product = FULL.reject { |e| e["event"].start_with?("harness_gate") } + GATE_RUNS
ph_g = L::Phases.compute(anchors(l, S.ok(product)))
check("G1 gate.run alone: implement is measured from it") { ph_g["implement"]["s"] == 3600 }
check("G1 gate.run alone: verify is measured from it") { ph_g["verify"]["s"] == (t("2026-10-01T03:20:45Z") - t("2026-10-01T02:00:00Z")).to_i }
check("G1 the anchor names its source event") { anchors(l, S.ok(product))["gate_first"].source == "telemetry gate.run" }
c_g = L::Counters.compute(landing: l, events: S.ok(product), timings: S.empty("none"))["counters"]
check("G2 gate.run feeds gate_runs, gate_wall_s and gate_red") do
  c_g["gate_runs"] == 2 && c_g["gate_wall_s"] == 220.5 && c_g["gate_red"] == 1
end
both_kinds = FULL + [ev("gate.run", "2026-10-01T01:30:00Z", duration_s: 10.0, attrs: { "ok" => true, "exit" => 0 })]
check("G3 the first gate is the earliest of either event") do
  a = anchors(l, S.ok(both_kinds))["gate_first"]
  a.at == t("2026-10-01T01:30:00Z") && a.source == "telemetry gate.run"
end
c_b = L::Counters.compute(landing: l, events: S.ok(both_kinds), timings: S.empty("none"))["counters"]
check("G3 both events count as gate runs") { c_b["gate_runs"] == 4 && c_b["gate_red"] == 1 }
other_unit = [ev("gate.run", "2026-10-01T02:00:00Z", unit: "DND-9002", duration_s: 5.0, attrs: { "ok" => true })]
check("G4 another unit's gate.run never anchors this landing") do
  anchors(l, S.ok(other_unit))["gate_first"].reason == "no harness_gate.run or gate.run for DND-9001"
end
check("G5 the red-rate guard's reason names both events") do
  L::Guards.compute([{ "counters" => {} }], reverts: nil)["gate_red_rate"]["reason"] == "no harness_gate.run or gate.run measured in the window"
end
check("G6 gate.run is read from the store") { L::EVENTS.include?("gate.run") }
stopped_g = product + [ev("gate.run", "2026-10-01T03:10:00Z", duration_s: 5.0, attrs: { "ok" => false, "exit" => 143, "interrupted" => true })]
check("G7 an interrupted gate.run is counted but never red") do
  c = L::Counters.compute(landing: l, events: S.ok(stopped_g), timings: S.empty("none"))["counters"]
  c["gate_runs"] == 3 && c["gate_red"] == 1
end

# ── Stats.summarize, Batch, Window ─────────────────────────────────────────

def row(i, verify: 100, start: "2026-10-0#{i}T00:00:00Z", commit: "c#{i}", ticket: "DND-#{9000 + i}", merge: 10)
  { "repo" => "custom", "ticket" => ticket, "landed_commit" => commit, "start" => start,
    "landed_at" => "2026-10-0#{i}T05:00:00Z", "lead_s" => 1000 * i, "code_s" => 1000 * i, "tail_s" => 0,
    "phases" => { "implement" => { "s" => 10 * i }, "verify" => verify.nil? ? { "s" => nil, "na_reason" => "no critic PASS for DND-#{9000 + i}" } : { "s" => verify },
                  "queue" => { "s" => 5 }, "integrate" => { "s" => 20 }, "merge" => { "s" => merge } } }
end

rows = [row(1, verify: 40), row(2, verify: nil), row(3, verify: 10), row(4, verify: 30), row(5, verify: 20)]
st = L::Stats.summarize(rows)
v = st["phases"]["verify"]
check("S1 n=4, n_na=1") { v["n"] == 4 && v["n_na"] == 1 }
check("S1 median by nearest rank over 4") { v["median"] == 20 }
check("S1 p90 by nearest rank over 4") { v["p90"] == 40 }
check("S1 n/a reasons are grouped with the unit masked") { v["na_reasons"] == [{ "reason" => "no critic PASS for <unit>", "count" => 1 }] }
check("S1 sum") { v["sum_s"] == 100 }

check("S2 biggest contributor by sum") { st["biggest"]["phase"] == "implement" && st["biggest"]["sum_s"] == 150 }
tie = L::Stats.summarize([row(1).merge("phases" => L::PHASES.to_h { |p| [p, { "s" => p == "implement" ? 5 : 10 }] })])
check("S2 a tie goes to the earlier phase") { tie["biggest"]["phase"] == "verify" }
none = L::Stats.summarize([row(1).merge("phases" => L::PHASES.to_h { |p| [p, { "s" => nil, "na_reason" => "x" }] })])
check("S2 no phase measured: no biggest, with a reason") { none["biggest"]["phase"].nil? && none["biggest"]["reason"] }
check("S2 an all-n/a phase has null median, p90 and sum") { none["phases"]["merge"].values_at("median", "p90", "sum_s") == [nil, nil, nil] }

batch = [row(1, commit: "x", ticket: "DND-1"), row(1, commit: "x", ticket: "DND-2"), row(2)]
kept, folded = L::Batch.dedupe(batch)
check("S3 a batch (shared start and landing) is counted once") { kept.size == 2 && folded == 1 }
nostart = [row(1, commit: "x", start: nil, ticket: nil), row(1, commit: "x", start: nil, ticket: "DND-3")]
check("S3 rows with no start are never folded together") { L::Batch.dedupe(nostart)[0].size == 2 }

check("S4 the window keeps the last N by landing time") { L::Window.select(rows.reverse, 2).map { |r| r["ticket"] } == %w[DND-9004 DND-9005] }

g = L::Guards.compute(rows.map { |r| r.merge("counters" => { "critic_rounds" => 2, "critic_blocks" => 1, "gate_runs" => 4, "gate_red" => 0 }) },
                      reverts: S.ok(["Revert x"]))
check("S5 guard rates") { g["critic_block_rate"]["value"] == 0.5 && g["gate_red_rate"]["value"] == 0.0 && g["reverts"]["value"] == 1 }
g2 = L::Guards.compute(rows, reverts: S.could_not_look("git log failed"))
check("S5 no counters: rates n/a with a reason, reverts could not look") do
  g2["critic_block_rate"]["value"].nil? && g2["critic_block_rate"]["reason"] && g2["reverts"]["reason"].include?("could not look")
end

# ── Landing.from_row, Ledger ───────────────────────────────────────────────

pr_row = { "pr" => 7, "landed_via" => "merge", "merge_commit" => OTHER, "landed_commit" => nil, "merged" => "2026-10-01T05:00:00Z",
           "start" => nil, "unmeasured_reason" => "start: no stamp" }
lnd, = L::Landing.from_row(pr_row, ticket: "DND-9001")
check("L1 a merge row's landed commit is its merge commit") { lnd["landed_commit"] == OTHER }
check("L1 a missing start carries lead-time's reason") { lnd["start"].nil? && lnd["start_na"] == "start: no stamp" }
_, why = L::Landing.from_row(pr_row.merge("merge_commit" => nil), ticket: nil)
check("L2 no landed commit: refused with a reason") { why.to_s.include?("no landed commit") }
# DND-1491: the refusal carries lead-time's own reason for the missing commit,
# and a row with neither a commit nor a reason is named as lead-time's fault.
_, why = L::Landing.from_row(pr_row.merge("merge_commit" => nil, "landing_commit_unmeasured" => "it is open: it has not landed"),
                             ticket: nil)
check("L2 DND-1491 no landed commit names lead-time's reason") do
  why == "no landed commit (PR #7): it is open: it has not landed"
end
_, why = L::Landing.from_row(pr_row.merge("merge_commit" => nil), ticket: nil)
check("L2 DND-1491 no commit and no reason is named as lead-time's contract break") do
  why.to_s.include?("lead-time named no reason")
end
_, why = L::Landing.from_row(pr_row.merge("merged" => nil), ticket: nil)
check("L2 no landing time: refused with a reason") { why.to_s.include?("no landing time") }

# DND-1490: the gated head. A squash landing's commit is the forge's; the
# head integration-gate, the critic and harness-gate saw is the PR's own head.
push_row = { "pr" => nil, "landed_via" => "push", "landed_commit" => HEAD, "merged" => "2026-10-01T05:00:00Z" }
gp, = L::Landing.from_row(push_row, ticket: "DND-9001")
check("G1 a push landing's gated head is its landed commit") { gp["gated_head"] == HEAD && gp["gated_head_na"].nil? }
sq, = L::Landing.from_row(pr_row.merge("head_commit" => HEAD, "head_commit_unmeasured" => nil), ticket: "DND-9001")
check("G2 a squash landing's gated head is the PR head") { sq["gated_head"] == HEAD && sq["gated_head_na"].nil? }
check("G2 its landed commit is still the forge's") { sq["landed_commit"] == OTHER }
unread, = L::Landing.from_row(pr_row.merge("head_commit" => nil, "head_commit_unmeasured" => "the forge gave no head commit (headRefOid)"),
                              ticket: "DND-9001")
check("G3 an unread PR head is null with lead-time's reason, never empty") do
  unread["gated_head"].nil? && unread["gated_head_na"].include?("the forge gave no head commit (headRefOid)")
end
legacy, = L::Landing.from_row(pr_row, ticket: "DND-9001")
check("G4 a row from before head_commit names that, and the rejoin") do
  legacy["gated_head"].nil? && legacy["gated_head_na"].include?("no head_commit") && legacy["gated_head_na"].include?("--rejoin")
end
check("G4 the reason still names the forge's commit") { legacy["gated_head_na"].include?("is the forge's commit") }
bad_head, = L::Landing.from_row(pr_row.merge("head_commit" => "h129"), ticket: "DND-9001")
check("G5 a malformed head is refused, never joined on") { bad_head["gated_head"].nil? && bad_head["gated_head_na"].include?("not a commit sha") }
upper, = L::Landing.from_row(pr_row.merge("head_commit" => "A" * 40), ticket: "DND-9001")
check("G5 an uppercase head is refused (receipts are keyed lowercase)") { upper["gated_head"].nil? }
empty_head, = L::Landing.from_row(pr_row.merge("head_commit" => ""), ticket: "DND-9001")
check("G5 an empty head is refused too") { empty_head["gated_head"].nil? && !empty_head["gated_head_na"].to_s.empty? }

# An unticketed squash landing joins its gate events on the PR head.
unt_sq = landing(ticket: nil, start: nil, commit: OTHER).merge("landed_via" => "merge", "gated_head" => HEAD)
ph_us = L::Phases.compute(anchors(unt_sq, S.ok(FULL.map { |e| e.merge("unit" => "some-branch") })))
check("G6 an unticketed squash landing: integrate measured on the PR head") { ph_us["integrate"]["s"] == 300 }
unt_nohead = unt_sq.merge("gated_head" => nil, "gated_head_na" => "no head")
ph_un = L::Phases.compute(anchors(unt_nohead, S.ok(FULL.map { |e| e.merge("unit" => "some-branch", "head" => nil) })))
check("G6 no gated head never matches an event with no head") { ph_un["integrate"]["s"].nil? }

base_sq = L::Ledger.improve_row(repo: "custom", landing: sq, anchors: anchors(sq, S.ok(FULL)), counters: {},
                                telemetry_status: :ok, ingested_at: t("2026-10-01T06:00:00Z"))
check("G7 a ledger row records the gated head") { base_sq["gated_head"] == HEAD && !base_sq.key?("gated_head_na") }
base_un = L::Ledger.improve_row(repo: "custom", landing: unread, anchors: anchors(unread, S.ok(FULL)), counters: {},
                                telemetry_status: :ok, ingested_at: t("2026-10-01T06:00:00Z"))
check("G7 an unread gated head is recorded null with its reason") do
  base_un.key?("gated_head") && base_un["gated_head"].nil? && base_un["gated_head_na"].include?("headRefOid")
end

miss = L::Phases.compute(anchors(sq, S.ok([])))
check("G8 a squash landing's head-keyed miss names the PR head, not the forge's commit") do
  miss["merge"]["na_reason"].include?(HEAD[0, 8]) && !miss["merge"]["na_reason"].include?(OTHER[0, 8])
end
check("G8 the gated head is masked when reasons are grouped") do
  L::Stats.generic("no receipt for #{HEAD[0, 8]}", { "landed_commit" => OTHER, "gated_head" => HEAD }) == "no receipt for <sha>"
end

old_sq = { "repo" => "custom", "mode" => "improve", "landed_via" => "merge", "landed_commit" => OTHER, "ticket" => "DND-9001" }
check("J1 an improve merge row with no gated head is rejoinable") { L::Ledger.rejoinable?(old_sq) }
check("J1 one whose head was unread is rejoinable") { L::Ledger.rejoinable?(old_sq.merge("gated_head" => nil)) }
check("J1 one already joined is not") { !L::Ledger.rejoinable?(old_sq.merge("gated_head" => HEAD)) }
check("J1 a push row is not") { !L::Ledger.rejoinable?(old_sq.merge("landed_via" => "push")) }
check("J1 a watch row is not") { !L::Ledger.rejoinable?(old_sq.merge("mode" => "watch")) }
new_sq = old_sq.merge("gated_head" => HEAD, "x" => 1)
nohead_sq = old_sq.merge("ticket" => "DND-9002", "gated_head" => nil, "gated_head_na" => "no head")
plan = L::Ledger.rejoins([new_sq, nohead_sq, new_sq.merge("landed_via" => "push", "ticket" => "DND-9003"),
                          new_sq.merge("mode" => "watch", "ticket" => "DND-9004")])
check("J2 the candidates are this scan's improve merge rows") { plan.keys == [L::Ledger.key(new_sq), L::Ledger.key(nohead_sq)] }
check("J2 a row the scan did not list is not_in_scan") { L::Ledger.rejoin_verdict(old_sq, nil) == :not_in_scan }
check("J2 a fresh row with no head is no_head") { L::Ledger.rejoin_verdict(old_sq, nohead_sq) == :no_head }
check("J2 a fresh row with its head replaces") { L::Ledger.rejoin_verdict(old_sq, new_sq) == :replace }
measured = old_sq.merge("phases" => { "implement" => { "s" => 60 }, "merge" => { "s" => nil } }, "counters" => { "gate_runs" => 2 })
check("J5 a fresh row that lost a measured phase would_lose") do
  L::Ledger.rejoin_verdict(measured, new_sq.merge("phases" => { "implement" => { "s" => nil }, "merge" => { "s" => 9 } },
                                                  "counters" => { "gate_runs" => 2 })) == :would_lose
end
check("J5 a fresh row that lost a counter would_lose") do
  L::Ledger.rejoin_verdict(measured, new_sq.merge("phases" => { "implement" => { "s" => 60 } }, "counters" => { "gate_runs" => nil })) == :would_lose
end
check("J5 a fresh row that keeps every measurement and adds one replaces") do
  L::Ledger.rejoin_verdict(measured, new_sq.merge("phases" => { "implement" => { "s" => 61 }, "merge" => { "s" => 9 } },
                                                  "counters" => { "gate_runs" => 2 })) == :replace
end

r1 = { "repo" => "custom", "landed_commit" => HEAD, "ticket" => "DND-1" }
r2 = r1.merge("ticket" => "DND-2")
check("L3 the ledger key is (repo, landed commit, ticket)") { L::Ledger.fresh([r1, r2, r1], [r1]) == [r2] }
w = L::Ledger.watch_row(repo: "gen_saas", landing: lnd, ingested_at: t("2026-10-01T06:00:00Z"))
check("L4 a watch row's phases are n/a by design") { w["phases"].values.all? { |p| p["s"].nil? && p["na_reason"].include?("watch mode") } }
check("L4 rows carry schema 1") { w["schema"] == 1 }

if $failures.empty?
  puts "lead-time-phases: #{$checks} checks passed"
  exit 0
end
$failures.each { |f| puts "FAIL #{f}" }
puts "lead-time-phases: #{$failures.size} of #{$checks} checks failed"
exit 1
