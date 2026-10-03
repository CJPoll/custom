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

# A fixture computed outside a check: a raise is a named failure (and {} for
# the checks that read it), so one missing method cannot hide the rest.
def fixture
  yield
rescue StandardError => e
  $failures << "fixture raised #{e.class}: #{e.message.lines.first&.chomp}"
  {}
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

# DND-1838: a re-dispatch from a park restarts the stamp, and its
# ticket.dispatched says so. A gate run before it is from before the park.
restarted = [ev("ticket.dispatched", "2026-10-01T01:00:00.000Z", attrs: { "tracker" => "dnd", "restart" => true })] +
            early
ph4b = fixture { L::Phases.compute(anchors(l, S.ok(restarted))) }
check("P4b DND-1838 after a restart, a gate before it is not the first gate: implement is measured") do
  ph4b.dig("implement", "s") == 3600 && !ph4b["implement"].key?("invalid")
end
check("P4b the phases still sum to landing - dispatch") do
  ph4b.values.sum { |c| c["s"].to_i } == (l["landed_at"] - l["start"]).to_i
end
not_restart = [ev("ticket.dispatched", "2026-10-01T01:00:00.000Z", attrs: { "tracker" => "dnd", "restart" => false })] +
              early
check("P4c a dispatch event that is not a restart leaves a gate before the stamp invalid") do
  fixture { L::Phases.compute(anchors(l, S.ok(not_restart))) }.dig("implement", "invalid") == true
end
only_before = [ev("ticket.dispatched", "2026-10-01T01:00:00.000Z", attrs: { "tracker" => "dnd", "restart" => true }),
               ev("harness_gate.run", "2026-10-01T00:30:00Z", duration_s: 10.0)]
ph4d = fixture { L::Phases.compute(anchors(l, S.ok(only_before))) }
check("P4d every gate before the restart: implement is n/a naming the restart, never invalid or 0") do
  ph4d.dig("implement", "s").nil? && !ph4d["implement"].key?("invalid") &&
    ph4d.dig("implement", "na_reason").to_s.include?("since its restart at 2026-10-01T01:00:00Z")
end

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

# DND-1511: a miss names the key its lookup used. A ticketed merge row looks
# gate runs up by unit (for_gated), so its reason names the unit, not the sha.
no_integ_m = FULL.reject { |e| e["event"] == "integration_gate.run" }
ph_mm = L::Phases.compute(anchors(merged, S.ok(no_integ_m)))
check("R3b ticketed merge, no gate run: the reason names the unit") do
  ph_mm["integrate"]["na_reason"].include?("no integration_gate.run on DND-9001") &&
    !ph_mm["integrate"]["na_reason"].include?("no integration_gate.run on #{OTHER[0, 8]}")
end
unt_m = landing(ticket: nil, start: nil, commit: OTHER).merge("landed_via" => "merge", "gated_head" => HEAD)
ph_um = L::Phases.compute(anchors(unt_m, S.ok(no_integ_m.map { |e| e.merge("unit" => "some-branch") })))
check("R3c unticketed merge, no gate run: the reason names the gated head") do
  ph_um["integrate"]["na_reason"].include?("no integration_gate.run on head #{HEAD[0, 8]}")
end
c_m = L::Counters.compute(landing: merged, events: S.ok([]), timings: S.could_not_look("no timings file"))
check("R3d ticketed merge, no gate check: the telemetry reason names the unit") do
  c_m["top_checks_na"].include?("no harness_gate.check on DND-9001")
end

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

# DND-1759: a merge landing with no gated head names the missing head in every
# head-keyed reason, never the forge's landed commit (OTHER), which no lookup used.
LANDED8 = OTHER[0, 8]
nh_tick = landing(commit: OTHER).merge("landed_via" => "merge", "gated_head" => nil, "gated_head_na" => "no head")
ph_nht = L::Phases.compute(anchors(nh_tick, S.ok([])))
{ "unticketed" => ph_un, "ticketed" => ph_nht }.each do |label, ph|
  rs = %w[queue integrate merge].map { |c| ph[c]["na_reason"].to_s }
  check("N1 #{label}: no head-keyed reason names the landed commit") { rs.none? { |r| r.include?(LANDED8) } }
  # A ticketed run lookup is keyed by the unit, so only its receipt/verdict reasons are head-keyed.
  head_keyed = label == "ticketed" ? [rs[0], rs[2]] : rs
  check("N1 #{label}: each head-keyed reason says no gated head is known") do
    head_keyed.all? { |r| r.include?("no gated head known") }
  end
end
nh_check = L::Counters.check_fields(nh_tick, S.ok([]), S.empty("none"))
check("N2 check_fields names no landed commit when no head is known") do
  !nh_check["top_checks_na"].include?(LANDED8) && nh_check["top_checks_na"].include?("no gated head known")
end
nh_critic = L::Anchors.critic_miss(unt_nohead, S.ok([]), NO_VERDICTS)
check("N3 critic_miss names no landed commit when no head is known") do
  !nh_critic.include?(LANDED8) && nh_critic.include?("no gated head known")
end
check("N4 a head known still names the head in a miss") do
  L::Anchors.critic_miss(landing, S.ok([]), NO_VERDICTS).include?(HEAD[0, 8])
end

LOCAL_ORIGIN = L::Origin.local("fixture")
base_sq = L::Ledger.improve_row(repo: "custom", landing: sq, anchors: anchors(sq, S.ok(FULL)), counters: {},
                                telemetry_status: :ok, ingested_at: t("2026-10-01T06:00:00Z"), origin: LOCAL_ORIGIN)
check("G7 a ledger row records the gated head") { base_sq["gated_head"] == HEAD && !base_sq.key?("gated_head_na") }
base_un = L::Ledger.improve_row(repo: "custom", landing: unread, anchors: anchors(unread, S.ok(FULL)), counters: {},
                                telemetry_status: :ok, ingested_at: t("2026-10-01T06:00:00Z"), origin: LOCAL_ORIGIN)
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

# ── tail as a biggest-contributor candidate (DND-1532) ─────────────────────
# A gen_saas-shaped window (post-merge CI: tail is landing -> Post-Merge
# Deploy) and a custom-shaped one (no CI: tail 0). Synthetic values only.

check("T0 a landing keeps lead-time's end kind as tail_end") do
  L::Landing.from_row(pr_row.merge("end_kind" => "deploy"), ticket: "DND-9001")[0]["tail_end"] == "deploy"
end
check("T0 a row with no end kind has tail_end nil, never a guess") { lnd["tail_end"].nil? }
check("T0 the ledger row carries tail_end") do
  dl, = L::Landing.from_row(pr_row.merge("end_kind" => "pipeline"), ticket: "DND-9001")
  L::Ledger.watch_row(repo: "gen_saas", landing: dl, ingested_at: t("2026-10-01T06:00:00Z"))["tail_end"] == "pipeline"
end

custom_rows = [row(1, verify: 40), row(2, verify: nil), row(3, verify: 10), row(4, verify: 30), row(5, verify: 20)]
cst = L::Stats.summarize(custom_rows)
check("T1 custom-shaped (tail 0): biggest is unchanged") { cst["biggest"].values_at("phase", "sum_s") == ["implement", 150] }
check("T1 custom-shaped: the lever is harness") { cst["biggest"]["lever"] == "harness" }
check("T1 custom-shaped: tail is not a candidate, with a reason") do
  cst["biggest"]["tail_candidate"] == false && cst["biggest"]["tail_reason"].to_s.include?("no measured nonzero tail")
end
check("T1 custom-shaped: the tail total is unchanged (five measured zeros)") do
  cst["totals"]["tail"].values_at("n", "n_na", "sum_s") == [5, 0, 0]
end
legacy_custom = custom_rows.map { |r| r.merge("tail_end" => nil) }
check("T1 custom-shaped rows with no tail_end are still measured zeros") do
  L::Stats.summarize(legacy_custom)["totals"]["tail"].values_at("n", "n_na") == [5, 0]
end

gs_rows = (1..5).map { |i| row(i).merge("repo" => "gen_saas", "tail_s" => 3600, "tail_end" => "deploy") }
gst = L::Stats.summarize(gs_rows)
check("T2 gen_saas-shaped with a dominant tail: biggest is tail") { gst["biggest"]["phase"] == "tail" }
check("T2 the tail's sum is the measured tails") { gst["biggest"]["sum_s"] == 18_000 }
check("T2 a tail biggest has lever product") { gst["biggest"]["lever"] == "product" }
check("T2 tail is a candidate") { gst["biggest"]["tail_candidate"] == true && !gst["biggest"].key?("tail_reason") }

small_tail = (1..5).map { |i| row(i).merge("tail_s" => 10, "tail_end" => "deploy") }
check("T3 a measured tail smaller than a phase: the phase wins, lever harness") do
  b = L::Stats.summarize(small_tail)["biggest"]
  b["phase"] == "verify" && b["sum_s"] == 500 && b["lever"] == "harness" && b["tail_candidate"] == true
end
tie_tail = [row(1).merge("phases" => L::PHASES.to_h { |p| [p, { "s" => p == "verify" ? 50 : 1 }] },
                         "tail_s" => 50, "tail_end" => "deploy")]
check("T3 a tie between a phase and tail goes to the phase") { L::Stats.summarize(tie_tail)["biggest"]["phase"] == "verify" }

na_tail = custom_rows.map { |r| r.merge("tail_s" => nil, "lead_na_reason" => "start: no stamp") }
nst = L::Stats.summarize(na_tail)
check("T4 an all-n/a tail is not a candidate, with its reason") do
  nst["biggest"]["phase"] == "implement" && nst["biggest"]["tail_candidate"] == false &&
    nst["biggest"]["tail_reason"].to_s.include?("not measured")
end
check("T4 an n/a tail is n/a in the totals, never 0") { nst["totals"]["tail"].values_at("n", "n_na", "sum_s") == [0, 5, nil] }

no_deploy = gs_rows.first(4) + [row(5).merge("tail_s" => 0, "tail_end" => "merge")]
ndt = L::Stats.summarize(no_deploy)["totals"]["tail"]
check("T5 in a post-merge-CI window, a landing with no CI run found is n/a, never 0") do
  ndt["n"] == 4 && ndt["n_na"] == 1 && ndt["median"] == 3600
end
check("T5 its reason says no post-merge run was found") { ndt["na_reasons"].first["reason"].include?("found no successful post-merge CI run") }
pre = gs_rows.first(4) + [row(5).merge("tail_s" => 0)]
pret = L::Stats.summarize(pre)["totals"]["tail"]
check("T5 a 0 tail ingested before tail_end, in a post-merge-CI window, is n/a with why") do
  pret["n_na"] == 1 && pret["na_reasons"].first["reason"].include?("no end kind")
end
zero_deploy = gs_rows.first(4) + [row(5).merge("tail_s" => 0, "tail_end" => "deploy")]
check("T5 a 0 tail whose deploy run was found is a measured 0") { L::Stats.summarize(zero_deploy)["totals"]["tail"]["n"] == 5 }

only_tail = [row(1).merge("phases" => L::PHASES.to_h { |p| [p, { "s" => nil, "na_reason" => "x" }] },
                          "tail_s" => 600, "tail_end" => "deploy")]
check("T6 no phase measured but a tail: biggest is tail, lever product") do
  b = L::Stats.summarize(only_tail)["biggest"]
  b["phase"] == "tail" && b["lever"] == "product" && b["sum_s"] == 600
end
check("T6 nothing measured at all: no biggest, no lever, a reason") do
  b = L::Stats.summarize([row(1).merge("phases" => {}, "tail_s" => nil)])["biggest"]
  b["phase"].nil? && !b.key?("lever") && b["reason"]
end

# ── tail reads the repo's declared post-merge CI (DND-1614) ────────────────
# idle_workflow (DND-1540) declares it: a workflow file is CI, "none" is no
# CI, absent falls back to the window inference above. Synthetic repo names.
WF = "post-merge.yml"
all_merge = (1..5).map { |i| row(i).merge("repo" => "prod", "tail_s" => 0, "tail_end" => "merge") }
dcl = L::Stats.summarize(all_merge, idle_workflow: WF, repo: "prod")
dclt = dcl["totals"]["tail"]
check("D1 declared CI, every tail 0 with a merge end: every tail cell is n/a") do
  dclt.values_at("n", "n_na", "sum_s") == [0, 5, nil]
end
check("D1 its reason names the declaration") do
  r = dclt["na_reasons"].first
  r["count"] == 5 && r["reason"].include?("prod declares post-merge CI (idle_workflow #{WF})") &&
    r["reason"].include?("end kind merge")
end
check("D1 tail is not a candidate, and tail_reason says it was not measured") do
  dcl["biggest"]["tail_candidate"] == false && dcl["biggest"]["tail_reason"].include?("not measured") &&
    dcl["biggest"]["tail_reason"].include?("idle_workflow #{WF}")
end
check("D1 --json carries tail_ci declared true") { dcl["tail_ci"] == { "source" => "declared", "value" => true } }
check("D1 the biggest pick is a phase (verify), never the unmeasured tail") do
  dcl["biggest"].values_at("phase", "lever") == ["verify", "harness"]
end

no_end = all_merge.first(4) + [row(5).merge("repo" => "prod", "tail_s" => 0)]
check("D2 declared CI, a 0 tail with no tail_end: n/a with the declared reason") do
  reasons = L::Stats.summarize(no_end, idle_workflow: WF, repo: "prod")["totals"]["tail"]["na_reasons"]
  reasons.all? { |x| x["reason"].include?("declares post-merge CI") } &&
    reasons.any? { |x| x["reason"].include?("ingested before DND-1532") }
end

check("D3 declared CI, a mixed window: the same cells as the inference") do
  decl = L::Stats.summarize(no_deploy, idle_workflow: WF, repo: "prod")["totals"]["tail"]
  inf = L::Stats.summarize(no_deploy)["totals"]["tail"]
  decl.values_at("n", "n_na", "median", "p90", "sum_s") == inf.values_at("n", "n_na", "median", "p90", "sum_s")
end
check("D3 declared CI, a 0 tail whose deploy run was found is a measured 0") do
  L::Stats.summarize(zero_deploy, idle_workflow: WF, repo: "prod")["totals"]["tail"]["n"] == 5
end

none = L::Stats.summarize(custom_rows, idle_workflow: "none", repo: "custom")
check("D4 declared none, all zeros: measured zeros") { none["totals"]["tail"].values_at("n", "n_na", "sum_s") == [5, 0, 0] }
check("D4 tail_reason names the declaration, not 'as in custom'") do
  why = none["biggest"]["tail_reason"]
  none["biggest"]["tail_candidate"] == false && why.include?("custom declares no post-merge CI (idle_workflow none)") &&
    !why.include?("as in custom")
end
check("D4 no mismatch warning") { none["tail_ci"] == { "source" => "declared", "value" => false } }
check("D4 declared none, a merge-end 0 stays measured (never n/a)") do
  L::Stats.summarize(all_merge, idle_workflow: "none", repo: "prod")["totals"]["tail"].values_at("n", "n_na") == [5, 0]
end

one_run = custom_rows.first(4) + [row(5).merge("tail_s" => 600, "tail_end" => "deploy")]
mis = L::Stats.summarize(one_run, idle_workflow: "none", repo: "custom")
check("D5 declared none with a nonzero tail: it stays measured") do
  mis["totals"]["tail"].values_at("n", "n_na", "sum_s") == [5, 0, 600]
end
check("D5 the mismatch counts the landings with a post-merge run") do
  mis["tail_ci"] == { "source" => "declared", "value" => false, "mismatch" => 1 }
end

# ── lead reads the same post-merge fact as tail (DND-1615) ─────────────────
# A lead with no post-merge run ends at the landing, a lead with one ends at
# the deploy. In a window with post-merge CI the no-run lead is n/a, never a
# shorter lead. gs_rows: lead_s 1000 * i, a deploy end each; no_deploy swaps
# the fifth for a merge end (lead_s 5000).
def totals_of(rs, **kw) = L::Stats.summarize(rs, **kw).fetch("totals")

lead_mixed = totals_of(no_deploy).fetch("lead")
check("LC1 inferred CI: a lead with no post-merge run is n/a, not a shorter lead") do
  lead_mixed.values_at("n", "n_na", "sum_s") == [4, 1, 10_000]
end
check("LC1 its reason is tail's, saying no post-merge run was found") do
  lead_mixed["na_reasons"].first["reason"].include?("found no successful post-merge CI run")
end
check("LC1 the lead and tail n/a counts agree, so the two share a definition") do
  lt = totals_of(no_deploy)
  lt["lead"]["n_na"] == lt["tail"]["n_na"]
end
check("LC2 declared CI: the same lead cells, the reason names the declaration") do
  d = totals_of(no_deploy, idle_workflow: WF, repo: "prod").fetch("lead")
  d.values_at("n", "n_na", "sum_s") == [4, 1, 10_000] && d["na_reasons"].first["reason"].include?("declares post-merge CI")
end
check("LC2 a row ingested before DND-1532, in a CI window: lead is n/a with why") do
  d = totals_of(pre).fetch("lead")
  d["n_na"] == 1 && d["na_reasons"].first["reason"].include?("no end kind")
end
check("LC3 no CI declared: a landing-ended lead stays measured") do
  totals_of(all_merge, idle_workflow: "none", repo: "prod").fetch("lead").values_at("n", "n_na") == [5, 0]
end
check("LC3 no CI seen in the window (custom-shaped): every lead stays measured") do
  totals_of(custom_rows).fetch("lead").values_at("n", "n_na", "sum_s") == [5, 0, 15_000]
end
check("LC4 a lead that ended at a deploy with a 0 tail is still measured") do
  totals_of(zero_deploy).fetch("lead")["n"] == 5
end
check("LC5 a lead already n/a keeps its own reason, not the tail's") do
  rs = no_deploy.first(4) + [row(5).merge("lead_s" => nil, "tail_s" => nil, "lead_na_reason" => "start: no stamp")]
  totals_of(rs).fetch("lead")["na_reasons"] == [{ "reason" => "start: no stamp", "count" => 1 }]
end
check("LC5 a lead n/a for its start keeps that reason even when the landing also has no run") do
  rs = no_deploy.first(4) + [row(5).merge("lead_s" => nil, "tail_s" => 0, "tail_end" => "merge",
                                           "lead_na_reason" => "start: no stamp")]
  totals_of(rs).fetch("lead")["na_reasons"] == [{ "reason" => "start: no stamp", "count" => 1 }]
end
check("LC6 code stays measured for the no-run landing (it ends at the landing by definition)") do
  totals_of(no_deploy).fetch("code").values_at("n", "n_na") == [5, 0]
end

# The tail numbers and candidacy before DND-1614, pinned: [n, n_na, sum_s, candidate].
{ "custom-shaped" => [custom_rows, [5, 0, 0, false]], "gen_saas-shaped" => [gs_rows, [5, 0, 18_000, true]],
  "one no-run landing" => [no_deploy, [4, 1, 14_400, true]], "one pre-DND-1532 row" => [pre, [4, 1, 14_400, true]],
  "all n/a" => [na_tail, [0, 5, nil, false]] }.each do |name, (rs, want)|
  check("D6 absent, #{name}: the same tail numbers, n/a count and candidacy as before DND-1614") do
    s = L::Stats.summarize(rs)
    s["totals"]["tail"].values_at("n", "n_na", "sum_s") + [s["biggest"]["tail_candidate"]] == want
  end
end
check("D6 an explicit nil declaration is absent (AC 5: any caller with no declaration)") do
  [custom_rows, gs_rows, no_deploy].all? do |rs|
    a = L::Stats.summarize(rs)
    b = L::Stats.summarize(rs, idle_workflow: nil, repo: "custom")
    a["totals"] == b["totals"] && a["biggest"] == b["biggest"] && a["tail_ci"] == b["tail_ci"]
  end
end
check("D6 absent, no nonzero tail: the reason says the fact was inferred") do
  why = cst["biggest"]["tail_reason"]
  why.include?("inferred") && why.include?("idle_workflow")
end
check("D6 absent, inferred CI: the n/a reason says the fact was inferred") do
  ndt["na_reasons"].first["reason"].include?("inferred")
end
check("D6 absent: tail_ci is inferred, with the inferred value") do
  cst["tail_ci"] == { "source" => "inferred", "value" => false } && gst["tail_ci"] == { "source" => "inferred", "value" => true }
end

# The miss: a value that is not a declaration is a fault, never read as absent.
["", "deploy", "../x.yml", " none", 7, true, :none, []].each do |bad|
  check("D7 an unrecognised CI declaration #{bad.inspect} raises, never reads as absent") do
    L::Stats.summarize(custom_rows, idle_workflow: bad, repo: "custom")
    false
  rescue L::DeclarationError => e
    e.message.include?("idle_workflow") && e.message.include?(bad.inspect) && e.fix.to_s.include?("lead-time-repos")
  end
end

check("D8 declared none, every tail n/a: tail_reason still names the declaration") do
  why = L::Stats.summarize(na_tail, idle_workflow: "none", repo: "custom")["biggest"]["tail_reason"]
  why.include?("not measured") && why.include?("custom declares no post-merge CI (idle_workflow none)")
end
check("D8 declared CI, measured zeros at a run end plus n/a ones: the reason counts the n/a") do
  zr = [row(1).merge("tail_s" => 0, "tail_end" => "deploy"), row(2).merge("tail_s" => 0, "tail_end" => "merge")]
  why = L::Stats.summarize(zr, idle_workflow: WF, repo: "prod")["biggest"]["tail_reason"]
  why.include?("each of its 1 measured landing(s)") && why.include?("1 are n/a") && why.include?("idle_workflow #{WF}")
end

# ── origin: a landing worked on another machine is foreign (DND-1531) ──────
# Telemetry is machine-local. Foreign needs positive evidence: a dispatch
# stamp, a readable store already recording dispatches at that instant (its
# first ticket.dispatched, of any unit, at or before it), and no local event
# (of any kind), receipt, verdict or timings for the unit.

O = L::Origin
NONE_HERE = S.empty("no receipt")
# events: a Source; since: the store's first ticket.dispatched (another
# unit's), prepended to an ok Source, or nil for none.
def origin(l, events, since: "2026-09-20T00:00:00Z", evidence: nil)
  if since && !events.could_not_look?
    events = S.ok([ev("ticket.dispatched", since, unit: "DND-9050")] + events.items)
  end
  O.decide(landing: l, unit_events: events, evidence: evidence)
end

o1 = origin(l, S.ok([ev("harness_gate.run", "2026-10-01T02:00:00Z", unit: "DND-9002")]))
check("O1 a stamp, a covering store and zero local events for the unit: foreign") { o1["origin"] == "foreign" }
check("O1 the decision names its evidence") do
  o1["origin_source"].include?("dispatched at 2026-10-01T01:00:00Z") && o1["origin_source"].include?("DND-9001")
end
check("O1 another unit's events are not evidence for this one") { !o1.key?("origin_na") }
check("O1 a store with only another unit's dispatch is still foreign (looked, found nothing)") do
  origin(l, S.ok([]))["origin"] == "foreign"
end

dispatched_only = [ev("ticket.dispatched", "2026-10-01T01:00:00Z", attrs: { "tracker" => "dnd" }).merge("repo" => "other_repo")]
o2 = origin(l, S.ok(dispatched_only))
check("O2 any local event for the unit (ticket.dispatched, any repo) makes it local") { o2["origin"] == "local" }
check("O2 the source counts the events") { o2["origin_source"] == "1 local telemetry event(s) for DND-9001" }
check("O2 a local event after the landing still counts (merge.landed is confirmed after it)") do
  origin(l, S.ok([ev("merge.landed", "2026-10-01T05:00:30Z")]))["origin"] == "local"
end

o3 = origin(l, S.could_not_look("no telemetry store at /x"))
check("O3 MISS: no store is could not look, never foreign") { o3["origin"].nil? && o3["origin_na"] == "telemetry: could not look (no telemetry store at /x)" }

ev_rec = O.local_evidence(l, receipt: S.ok([{ "recorded_at" => "x" }]), verdicts: NO_VERDICTS, timings: S.empty("none"))
check("O4 a local integration receipt is evidence, named with the head") { ev_rec == "integration receipt for #{HEAD[0, 8]} on this machine" }
check("O4 nothing found on any head source: no evidence") do
  O.local_evidence(l, receipt: NONE_HERE, verdicts: S.could_not_look("x"), timings: S.empty("none")).nil?
end
check("O4 local evidence makes a zero-event landing local") { origin(l, S.ok([]), evidence: ev_rec)["origin"] == "local" }
check("O4 local evidence wins over an unreadable store") do
  origin(l, S.could_not_look("x"), evidence: ev_rec)["origin"] == "local"
end

o5 = origin(landing(start: nil), S.ok([]))
check("O5 MISS: no dispatch stamp is undecided, never foreign") { o5["origin"].nil? && o5["origin_na"].include?("no dispatch stamp") }

o6 = origin(l, S.ok([]), since: "2026-10-01T01:00:00Z")
check("O6 a first dispatch event at the dispatch instant covers it") { o6["origin"] == "foreign" }
o6b = origin(l, S.ok([]), since: "2026-10-01T01:00:01Z")
check("O6 MISS: the same day, the dispatch emitter not yet recording: undecided") do
  o6b["origin"].nil? &&
    o6b["origin_na"].include?("first ticket.dispatched is at 2026-10-01T01:00:01Z, after the dispatch at 2026-10-01T01:00:00Z")
end
o7 = origin(l, S.ok([ev("harness_gate.run", "2026-09-01T00:00:00Z", unit: "DND-9002")]), since: nil)
check("O7 MISS: a store with no ticket.dispatched at all is undecided, never foreign") do
  o7["origin"].nil? && o7["origin_na"].include?("holds no ticket.dispatched")
end
check("O7 the earliest dispatch event is the one that counts") do
  evs = S.ok([ev("ticket.dispatched", "2026-10-03T00:00:00Z", unit: "DND-1"), ev("ticket.dispatched", "2026-09-02T00:00:00Z", unit: "DND-2")])
  O.dispatch_recording_since(evs) == t("2026-09-02T00:00:00Z")
end

o8 = origin(landing(ticket: nil, start: nil), S.ok([]))
check("O8 an unticketed landing is undecided") { o8["origin"].nil? && o8["origin_na"].start_with?("unticketed landing") }
check("O8 a ticket that could not be read is could not look, not unticketed") do
  origin(faulty, S.ok([]))["origin_na"].start_with?("ticket: could not look")
end

fl = L::Ledger.improve_row(repo: "gen_saas", landing: l, anchors: anchors(l, S.ok([])), counters: {},
                           telemetry_status: :ok, ingested_at: t("2026-10-01T06:00:00Z"), origin: o1)
check("O9 a foreign ledger row records its origin and why") { fl["origin"] == "foreign" && fl["origin_source"] == o1["origin_source"] }
check("O9 its five phases are null with the foreign reason") do
  fl["phases"].values.all? { |c| c["s"].nil? && c["na_reason"] == "worked on another machine (no local events for DND-9001)" }
end
check("O9 its forge totals are kept") { fl.key?("lead_s") && fl.key?("tail_s") }
ll = L::Ledger.improve_row(repo: "custom", landing: l, anchors: anchors(l, S.ok(FULL)), counters: {},
                           telemetry_status: :ok, ingested_at: t("2026-10-01T06:00:00Z"), origin: o2)
check("O9 a local row keeps its measured phases") { ll["origin"] == "local" && ll["phases"] == ph }
ul = L::Ledger.improve_row(repo: "custom", landing: l, anchors: anchors(l, S.ok([])), counters: {},
                           telemetry_status: :ok, ingested_at: t("2026-10-01T06:00:00Z"), origin: o3)
check("O9 an undecided row records origin null with its reason, phases as measured") do
  ul.key?("origin") && ul["origin"].nil? && ul["origin_na"] == o3["origin_na"] && !ul["phases"]["implement"]["na_reason"].include?("another machine")
end

# Summary: foreign rows are out of the phase stats and the biggest pick, in
# the totals, counted and named.
def foreign_row(i)
  row(i, verify: nil).merge("origin" => "foreign", "phases" => O.foreign_phases("DND-#{9000 + i}"),
                            "tail_s" => 0)
end
loc = [row(1, verify: 40).merge("origin" => "local"), row(3, verify: 10).merge("origin" => "local")]
mixed_w = loc + [foreign_row(2), foreign_row(4)]
fs = L::Stats.summarize(mixed_w)
check("F1 foreign is counted beside rows") { fs["rows"] == 4 && fs["foreign"] == 2 }
check("F1 foreign landings are named") { fs["origin"]["foreign_units"] == %w[DND-9002 DND-9004] }
check("F1 the phase stats see only local rows (no foreign n/a)") do
  fs["phases"]["verify"].values_at("n", "n_na", "sum_s") == [2, 0, 50] &&
    fs["phases"]["implement"]["na_reasons"].empty?
end
check("F1 the biggest pick is over local rows") { fs["biggest"]["phase"] == "verify" && fs["biggest"]["sum_s"] == 50 }
check("F1 the totals still include foreign rows") do
  fs["totals"]["lead"].values_at("n", "sum_s") == [4, 10_000]
end
check("F1 local and unknown are counted too") { fs["origin"]["local"] == 2 && fs["origin"]["unknown"] == 0 }

tailing = [foreign_row(2), foreign_row(4)].map { |r| r.merge("tail_s" => 9000, "tail_end" => "deploy") }
ft = L::Stats.summarize(loc + tailing)
check("F1 a foreign landing's tail never enters the biggest pick") do
  ft["biggest"].values_at("phase", "sum_s", "lever") == ["verify", 50, "harness"] && ft["biggest"]["tail_candidate"] == false
end
check("F1 but its tail is still in the totals") { ft["totals"]["tail"]["sum_s"] == 18_000 }
check("F1 declared CI (DND-1614): totals keep the foreign tails, the local 0s with no run are n/a, tail no candidate") do
  d = L::Stats.summarize(loc + tailing, idle_workflow: "post-merge.yml", repo: "prod")
  d["totals"]["tail"].values_at("n", "n_na", "sum_s") == [2, 2, 18_000] && d["biggest"]["tail_candidate"] == false
end
check("F2 every landing foreign, with nonzero tails: still no biggest, the foreign reason") do
  b = L::Stats.summarize(tailing)["biggest"]
  b["phase"].nil? && b["reason"].include?("worked on another machine")
end
all_f = L::Stats.summarize([foreign_row(1), foreign_row(2)])
check("F2 every landing foreign: no biggest, and the reason says so") do
  all_f["biggest"]["phase"].nil? && all_f["biggest"]["reason"].include?("worked on another machine") && all_f["foreign"] == 2
end

legacy_w = L::Stats.summarize([row(1).merge("mode" => "improve"), row(2).merge("mode" => "improve")])
check("F3 MISS: rows with no origin judged: foreign is null, never 0") { legacy_w["foreign"].nil? }
check("F3 they count as unknown, with the reason") do
  legacy_w["origin"]["unknown"] == 2 && legacy_w["origin"]["unknown_reasons"].first["reason"].include?("before DND-1531")
end
check("F3 and stay in the phase stats, as before") { legacy_w["phases"]["implement"]["n"] == 2 }
watch_w = L::Stats.summarize([row(1).merge("mode" => "watch")])
check("F4 a watch row is unknown with a watch reason, foreign null") do
  watch_w["foreign"].nil? && watch_w["origin"]["unknown_reasons"].first["reason"].start_with?("watch mode")
end
und = L::Stats.summarize(loc + [row(5).merge("mode" => "improve", "origin" => nil, "origin_na" => "telemetry: could not look (x)")])
check("F5 an undecided row is unknown with its own reason, and foreign counts the judged rows") do
  und["foreign"] == 0 && und["origin"]["unknown"] == 1 &&
    und["origin"]["unknown_reasons"].first["reason"] == "telemetry: could not look (x)"
end

# ── DND-1501: the --with-critic integration flow ───────────────────────────
# The captain's verify step IS `integration-gate --with-critic`, so its critic
# PASS is judged inside the integration run and no PASS stands before it. The
# phases then read: verify = first gate -> final integration start; integrate
# = that run; queue = integration end -> the landing start (the first
# merge.lock_wait, or the start of a timed merge.landed push); merge = landing
# start -> landing. Every anchor is a recorded event; none is invented.

WC_LANDED = "2026-10-01T04:30:05Z"
WC_RUN = { "exit_code" => 0, "outcome" => "ok", "with_critic" => true }.freeze
WC = [
  ev("harness_gate.run", "2026-10-01T02:00:00.400Z", duration_s: 100.0, attrs: { "ok" => true, "run_id" => "g1" }),
  # an earlier integration attempt: the critic BLOCKed (fix round follows)
  ev("integration_gate.run", "2026-10-01T03:00:00Z", duration_s: 200.0,
                             attrs: { "exit_code" => 3, "outcome" => "no_critic_pass", "with_critic" => true }),
  ev("harness_gate.run", "2026-10-01T03:00:05Z", duration_s: 180.0, attrs: { "ok" => true, "run_id" => "g2" }),
  ev("critic.round", "2026-10-01T03:00:06Z", duration_s: 70.0, attrs: { "verdict" => "block" }),
  # the final, green integration run with its PASS inside it
  ev("integration_gate.run", "2026-10-01T04:00:00Z", duration_s: 300.0, attrs: WC_RUN),
  ev("harness_gate.run", "2026-10-01T04:00:02Z", duration_s: 280.0, attrs: { "ok" => true, "run_id" => "g3" }),
  ev("critic.round", "2026-10-01T04:00:03Z", duration_s: 45.0, attrs: { "verdict" => "pass" }),
].freeze
# The landing push, timed (DND-1501): at = the push start, duration_s = its wall.
PUSH = ev("merge.landed", "2026-10-01T04:30:00Z", duration_s: 4.0, attrs: { "via" => "push", "after" => HEAD })

wl = landing(landed: WC_LANDED)
wa = anchors(wl, S.ok(WC + [PUSH]))
wp = L::Phases.compute(wa)
check("W1 with-critic: every phase is measured") { L::PHASES.all? { |p| wp[p]["s"].is_a?(Integer) } }
check("W1 the phases sum to landing - dispatch exactly") do
  wp.values.sum { |c| c["s"] } == (wl["landed_at"] - wl["start"]).to_i
end
check("W1 verify = first gate -> the final integration run's start") { wp["verify"]["s"] == 7200 }
check("W1 integrate = the final run's duration") { wp["integrate"]["s"] == 300 }
check("W1 queue = integration end -> the landing push start") { wp["queue"]["s"] == 25 * 60 }
check("W1 merge = the landing push start -> the landing") { wp["merge"]["s"] == 5 }
check("W1 implement is unchanged") { wp["implement"]["s"] == 3600 }
check("W2 the flow is recorded as with_critic") { L::Phases.flow(wa) == "with_critic" }
check("W2 the critic_pass anchor is the PASS inside the run, marked with_critic") do
  wa["critic_pass"].at == t("2026-10-01T04:00:48Z") && wa["critic_pass"].with_critic == true &&
    wa["critic_pass"].to_h_json["with_critic"] == true
end
check("W2 the land_start anchor names its source") do
  wa["land_start"].at == t("2026-10-01T04:30:00Z") && wa["land_start"].source.include?("merge.landed")
end

# The rows ingested before DND-1501: the push was a point event (no
# duration_s), so the landing start is not recorded. queue and merge are n/a
# with that reason, never 0, and never the old mislabel (queue inside merge).
old_push = PUSH.merge("duration_s" => nil)
wo = L::Phases.compute(anchors(wl, S.ok(WC + [old_push])))
check("W3 no landing start recorded: verify and integrate still measured") do
  wo["verify"]["s"] == 7200 && wo["integrate"]["s"] == 300
end
check("W3 queue and merge are n/a with a reason naming the missing landing start, never 0") do
  %w[queue merge].all? { |p| wo[p]["s"].nil? && wo[p]["na_reason"].include?("no landing start") }
end
check("W3 the reason names the missing instrumentation") do
  wo["queue"]["na_reason"].include?("merge.lock_wait") && wo["queue"]["na_reason"].include?("DND-1501")
end

# A locked-merge landing (gen_saas): merge.lock_wait marks the landing start,
# and the earliest one after integration counts (retries stay in merge).
locks = [ev("merge.lock_wait", "2026-10-01T03:30:00Z", duration_s: 1.0, attrs: { "outcome" => "acquired" }),
         ev("merge.lock_wait", "2026-10-01T04:20:00Z", duration_s: 2.0, attrs: { "outcome" => "acquired" }),
         ev("merge.lock_wait", "2026-10-01T04:25:00Z", duration_s: 2.0, attrs: { "outcome" => "acquired" })]
wl2 = L::Phases.compute(anchors(wl, S.ok(WC + locks + [PUSH])))
check("W4 the first merge.lock_wait after integration ends is the landing start") do
  wl2["queue"]["s"] == 15 * 60 && wl2["merge"]["s"] == (t(WC_LANDED) - t("2026-10-01T04:20:00Z")).to_i
end

# A run not marked --with-critic: a PASS inside it is not a with-critic flow.
plain = WC.map { |e| e["event"] == "integration_gate.run" ? e.merge("attrs" => e["attrs"].merge("with_critic" => false)) : e }
pp_ = L::Phases.compute(anchors(wl, S.ok(plain + [PUSH])))
check("W5 a PASS inside a run NOT marked --with-critic: verify and queue n/a, named") do
  %w[verify queue].all? { |p| pp_[p]["s"].nil? && pp_[p]["na_reason"].include?("not marked --with-critic") }
end
# A PASS after the run ended is not inside it.
late_pass = WC.reject { |e| e["event"] == "critic.round" } +
            [ev("critic.round", "2026-10-01T04:10:00Z", duration_s: 20.0, attrs: { "verdict" => "pass" })]
check("W6 a PASS after the integration run ended is not a with-critic PASS") do
  a = anchors(wl, S.ok(late_pass + [PUSH]))
  a["critic_pass"].at.nil? && L::Phases.flow(a) == "standalone"
end
dirty_in = WC.map { |e| e["event"] == "critic.round" ? e.merge("attrs" => e["attrs"].merge("dirty" => true)) : e }
check("W7 a dirty PASS inside the run is never one, so the flow is not with_critic") do
  a = anchors(wl, S.ok(dirty_in + [PUSH]))
  a["critic_pass"].at.nil? && L::Phases.flow(a) == "standalone"
end

# The standalone-PASS flow is unchanged: a PASS stood before integration.
std = anchors(l, S.ok(FULL + [PUSH.merge("at" => "2026-10-01T04:55:00Z")]))
check("W8 standalone PASS: the phases are exactly as before DND-1501") do
  L::Phases.compute(std) == ph && L::Phases.flow(std) == "standalone"
end
check("W8 standalone PASS: the critic_pass anchor carries no with_critic mark") { std["critic_pass"].with_critic.nil? }
# No integration run: n/a as today.
check("W9 no integration run: the flow is standalone, phases as before") do
  a = anchors(l, S.ok(no_integ))
  L::Phases.compute(a) == ph3 && L::Phases.flow(a) == "standalone"
end
a_cnl = anchors(wl, S.could_not_look("store gone"))
ph_cnl = L::Phases.compute(a_cnl)
check("W10 telemetry could not look: every phase n/a, never 0, and the land_start miss says could not look") do
  L::PHASES.all? { |p| ph_cnl[p]["s"].nil? } && a_cnl["land_start"]&.reason == "telemetry: could not look (store gone)"
end

# verify.gate_runs_s: the gate-run wall inside verify (machine time vs fix time).
gs = fixture { L::Counters.verify_gate_runs(landing: wl, events: S.ok(WC + [PUSH]), anchors: wa) }
check("W11 gate_runs_s sums the gate runs inside verify, the final run's excluded") { gs["gate_runs_s"] == 280.0 }
gs_std = fixture { L::Counters.verify_gate_runs(landing: l, events: S.ok(FULL), anchors: anchors(l, S.ok(FULL))) }
check("W11 standalone: runs wholly inside verify are summed whole") do
  # verify 02:00:00 -> 03:20:45: runs 100 + 120.5 + 90 all end inside it.
  gs_std["gate_runs_s"] == 310.5
end
# A run that starts inside verify and ends after it: only its part inside
# verify (03:20:00 -> 03:20:45, 45 s of its 100 s) is summed.
straddle = FULL + [ev("harness_gate.run", "2026-10-01T03:20:00Z", duration_s: 100.0, attrs: { "ok" => true, "run_id" => "r4" })]
gs_clip = fixture do
  L::Counters.verify_gate_runs(landing: l, events: S.ok(straddle), anchors: anchors(l, S.ok(straddle)))
end
check("W11 a run that straddles verify's end is clipped to it") { gs_clip["gate_runs_s"] == 355.5 }
nodur_g = WC.map { |e| e["at"] == "2026-10-01T03:00:05Z" ? e.merge("duration_s" => nil) : e }
gs_nd = fixture { L::Counters.verify_gate_runs(landing: wl, events: S.ok(nodur_g), anchors: anchors(wl, S.ok(nodur_g + [PUSH]))) }
check("W12 a gate run inside verify with no duration: null with a reason, never summed as 0") do
  gs_nd["gate_runs_s"].nil? && gs_nd["gate_runs_na"].include?("no duration_s")
end
gs_na = fixture { L::Counters.verify_gate_runs(landing: wl, events: S.ok([]), anchors: anchors(wl, S.ok([]))) }
check("W12 verify n/a: gate_runs_s is null with verify's reason") do
  gs_na["gate_runs_s"].nil? && gs_na["gate_runs_na"].start_with?("verify n/a:")
end
row_w = fixture do
  L::Ledger.improve_row(repo: "custom", landing: wl, anchors: wa, counters: {}, telemetry_status: :ok,
                        ingested_at: t("2026-10-01T06:00:00Z"), origin: L::Origin.local("x"), verify_gate_runs: gs)
end
check("W13 the ledger row carries the flow and verify.gate_runs_s") do
  row_w["phase_flow"] == "with_critic" && row_w.dig("phases", "verify", "gate_runs_s") == 280.0 &&
    row_w.dig("phases", "queue", "s") == 1500 && row_w.dig("anchors", "land_start", "at") == "2026-10-01T04:30:00Z"
end

row_wf = fixture do
  L::Ledger.improve_row(repo: "custom", landing: wl, anchors: wa, counters: {}, telemetry_status: :ok,
                        ingested_at: t("2026-10-01T06:00:00Z"), origin: { "origin" => "foreign", "origin_source" => "x" },
                        verify_gate_runs: gs)
end
check("W13 a foreign row records no phase_flow and no gate split: its phases are the foreign nulls") do
  row_wf.key?("phase_flow") && row_wf["phase_flow"].nil? && !row_wf.dig("phases", "verify").key?("gate_runs_s")
end

# --summary: code time attributed to no phase, and the flows in the window.
un_rows = [row(1).merge("code_s" => 200), # phases 10+100+5+20+10 = 145 -> 55 unattributed
           row(2).merge("code_s" => 500, "phases" => row(2)["phases"].merge("queue" => { "s" => nil, "na_reason" => "x" }),
                        "phase_flow" => "with_critic"), # 20+100+20+10 = 150 -> 350
           row(3).merge("code_s" => nil, "phase_flow" => "standalone")]
un = fixture { L::Stats.summarize(un_rows) }
check("W14 unattributed = code minus the measured phases, summed over rows with code") do
  un["unattributed"]["sum_s"] == 405 && un["unattributed"]["code_s"] == 700 && un["unattributed"]["n"] == 2 &&
    un["unattributed"]["n_na"] == 1
end
check("W14 the flows in the window, a row from before DND-1501 counted as unrecorded") do
  un["flows"] == { "with_critic" => 1, "standalone" => 1, "unrecorded" => 1 }
end
un_f = fixture { L::Stats.summarize([row(1).merge("code_s" => 200, "origin" => "foreign")]) }
check("W14 a foreign row is out of unattributed, as out of the phase stats") do
  un_f["unattributed"]["n"].zero? && un_f["unattributed"]["sum_s"].nil?
end

# ── DND-1809: a clean-rebase push landing joins its gated head ─────────────
# The admiral rebases a gated head onto a moved main and pushes: the landed
# commit is not the head integration-gate, the critic and the receipt are
# keyed on. The gated head is found from recorded data only: the push's
# merge.landed `before` (the pre-push main) and the integration receipt's
# clean-rebase cover (ir_push_covered, read by the IO side into `cover`),
# else the ticket's only gated head. Two candidates, or none, is a named
# miss that says which keys it searched.

RB_LANDED = "e" * 40   # the commit the push landed
RB_GATED = "f" * 40    # the head integration-gate passed, before the rebase
RB_GATED2 = "8" * 40   # a second head of the same change, gated again
RB_BEFORE = "9" * 40   # main before the push
RB_RUNS = WC.map { |e| e.merge("head" => RB_GATED) }.freeze
RB_PUSH = ev("merge.landed", "2026-10-01T04:30:00Z", head: RB_LANDED, duration_s: 4.0,
                                                    attrs: { "via" => "push", "after" => RB_LANDED,
                                                             "before" => RB_BEFORE }).freeze
NO_LANDED_RECEIPT = S.empty("no receipt for eeeeeeee")

def rb_landing(ticket: "DND-9001") = landing(ticket: ticket, landed: WC_LANDED, commit: RB_LANDED)

def rb_cover(kind, heads) = S.ok([{ "cover" => kind, "heads" => heads, "onto" => RB_BEFORE }])

def rb_resolve(l, events, cover, receipt: NO_LANDED_RECEIPT)
  L::PushJoin.resolve(l, events: S.ok(events), cover: cover, landed_receipt: receipt)
end

check("X0 the pre-push main is the before of the push's own merge.landed") do
  L::PushJoin.before_of(rb_landing, S.ok(RB_RUNS + [RB_PUSH])) == RB_BEFORE
end
check("X0 no merge.landed for the landed commit: no pre-push main") do
  L::PushJoin.before_of(rb_landing, S.ok(RB_RUNS)).nil?
end

# X1: the regression. One gated head covers the landing.
x1 = fixture { rb_resolve(rb_landing, RB_RUNS + [RB_PUSH], rb_cover("rebase", [RB_GATED])) }
check("X1 a clean-rebase push landing joins its gated head") { x1["gated_head"] == RB_GATED }
check("X1 and says how it was joined") do
  x1["gated_head_source"].to_s.include?("clean-rebase cover") && x1["gated_head_source"].include?(RB_BEFORE[0, 8])
end
x1a = fixture { anchors(x1, S.ok(RB_RUNS + [RB_PUSH])) }
x1p = fixture { L::Phases.compute(x1a) }
check("X1 its run joins: every phase is measured") { L::PHASES.all? { |p| x1p.dig(p, "s").is_a?(Integer) } }
check("X1 integrate is the gated run's duration") { x1p.dig("integrate", "s") == 300 }
check("X1 the PASS inside the run reads as with_critic, not standalone") { L::Phases.flow(x1a) == "with_critic" }
check("X1 the landing start is the push on the landed commit") do
  x1a["land_start"]&.at == t("2026-10-01T04:30:00Z") && x1p.dig("merge", "s") == 5
end
x1r = fixture do
  L::Ledger.improve_row(repo: "custom", landing: x1, anchors: x1a, counters: {}, telemetry_status: :ok,
                        ingested_at: t("2026-10-02T00:00:00Z"), origin: { "origin" => "local" })
end
check("X1 the row records the gated head and how it was found") do
  x1r["landed_commit"] == RB_LANDED && x1r["gated_head"] == RB_GATED &&
    x1r["gated_head_source"] == x1["gated_head_source"] && !x1r.key?("gated_head_miss")
end

# Unfixed, the landed commit was the only key: integrate is n/a.
x1old = fixture { L::Phases.compute(anchors(rb_landing, S.ok(RB_RUNS + [RB_PUSH]))) }
check("X1 (control) unresolved, the landed commit joins no run") { x1old.dig("integrate", "s").nil? }

# X2: ambiguity is n/a with a reason, never a guess.
x2 = fixture { rb_resolve(rb_landing, RB_RUNS + [RB_PUSH], rb_cover("rebase", [RB_GATED, RB_GATED2])) }
check("X2 two covering heads: no gated head is chosen") { x2["gated_head"] == RB_LANDED && x2["gated_head_source"].nil? }
check("X2 the miss names both candidates") do
  m = x2["gated_head_miss"].to_s
  m.include?("ambiguous") && m.include?(RB_GATED[0, 8]) && m.include?(RB_GATED2[0, 8])
end
x2p = fixture { L::Phases.compute(anchors(x2, S.ok(RB_RUNS + [RB_PUSH]))) }
check("X2 integrate is n/a and its reason carries the ambiguity") do
  x2p.dig("integrate", "s").nil? && x2p.dig("integrate", "na_reason").to_s.include?("ambiguous")
end
two_runs = RB_RUNS + [ev("integration_gate.run", "2026-10-01T04:10:00Z", head: RB_GATED2, duration_s: 10.0,
                         attrs: WC_RUN)]
x2t = fixture { rb_resolve(rb_landing, two_runs, S.empty("no gated head covers it")) }
check("X2 the ticket fallback with two gated heads is ambiguous too") do
  x2t["gated_head"] == RB_LANDED && x2t["gated_head_miss"].to_s.include?("ambiguous") &&
    x2t["gated_head_miss"].include?("DND-9001")
end

# X3: no gated head names the keys it searched.
x3 = fixture { rb_resolve(rb_landing, [RB_PUSH], S.empty("no gated head covers it as a clean rebase")) }
check("X3 nothing found: the landed commit stays the key") { x3["gated_head"] == RB_LANDED && x3["gated_head_source"].nil? }
check("X3 the miss names the landed commit and the pre-push main it searched") do
  m = x3["gated_head_miss"].to_s
  m.include?(RB_LANDED[0, 8]) && m.include?(RB_BEFORE[0, 8])
end
x3t = fixture { rb_resolve(rb_landing, [], S.empty("no landed main is known")) }
check("X3 with no pre-push main, the miss also names the ticket it searched") do
  m = x3t["gated_head_miss"].to_s
  m.include?(RB_LANDED[0, 8]) && m.include?("no single merge.landed") &&
    m.include?("no successful integration_gate.run for DND-9001")
end
check("X3 a red run on the landed commit does not make it the gated head") do
  red = [ev("integration_gate.run", "2026-10-01T04:20:00Z", head: RB_LANDED, duration_s: 9.0,
            attrs: { "exit_code" => 1 })]
  rb_resolve(rb_landing, RB_RUNS + [RB_PUSH] + red, rb_cover("rebase", [RB_GATED]))["gated_head"] == RB_GATED
end
check("X3 the cover's own reason is kept in full") do
  x3["gated_head_search"].to_s.include?("no gated head covers it as a clean rebase")
end
x3p = fixture { L::Phases.compute(anchors(x3, S.ok([RB_PUSH]))) }
check("X3 integrate's n/a names the key and the search") do
  r = x3p.dig("integrate", "na_reason").to_s
  r.include?("no integration_gate.run on #{RB_LANDED[0, 8]}") && r.include?(x3["gated_head_miss"])
end
x3u = fixture { rb_resolve(rb_landing(ticket: nil), [], S.empty("x")) }
check("X3 unticketed, no merge.landed: the miss says both") do
  m = x3u["gated_head_miss"].to_s
  m.include?("unticketed") && m.include?("no single merge.landed")
end
x3c = fixture { rb_resolve(rb_landing, [RB_PUSH], S.could_not_look("jq is not on PATH")) }
check("X3 a cover that could not be read says so, never 'none'") do
  x3c["gated_head_search"].to_s.include?("could not look (jq is not on PATH)")
end

# X4: the other joins.
x4 = fixture { rb_resolve(rb_landing, [RB_PUSH], rb_cover("exact", [RB_LANDED])) }
check("X4 an exact cover: the landed commit IS the gated head") do
  x4["gated_head"] == RB_LANDED && x4["gated_head_source"].to_s.include?("exact")
end
x4r = fixture { rb_resolve(rb_landing, [RB_PUSH], S.empty("x"), receipt: S.ok([{ "head" => RB_LANDED }])) }
check("X4 a receipt for the landed commit joins it, before any fallback") do
  x4r["gated_head"] == RB_LANDED && x4r["gated_head_source"].to_s.include?("receipt")
end
on_landed = [ev("integration_gate.run", "2026-10-01T04:00:00Z", head: RB_LANDED, duration_s: 9.0, attrs: WC_RUN)]
x4n = fixture { rb_resolve(rb_landing, on_landed + RB_RUNS, S.empty("x")) }
check("X4 a run on the landed commit itself joins it, before the ticket fallback") do
  x4n["gated_head"] == RB_LANDED && x4n["gated_head_source"].to_s.include?("integration_gate.run")
end
# No merge.landed: the cover had no pre-push main to judge against.
x4t = fixture { rb_resolve(rb_landing, RB_RUNS, S.empty("no landed main is known")) }
check("X4 the ticket fallback: the ticket's one gated head joins, said to be not tree-checked") do
  x4t["gated_head"] == RB_GATED && x4t["gated_head_source"].to_s.include?("DND-9001") &&
    x4t["gated_head_source"].include?("not tree-checked")
end

# X6: the rule judged (a pre-push main was known) and rejected every receipt
# head. The ticket's head is one it disproved: it never joins.
x6 = fixture { rb_resolve(rb_landing, RB_RUNS + [RB_PUSH], S.empty("1 candidate(s) checked, 1 conflicting")) }
check("X6 a cover the rule judged and found none: the ticket is not tried") do
  x6["gated_head"] == RB_LANDED && x6["gated_head_source"].nil? &&
    x6["gated_head_miss"].to_s.include?("the ticket is not tried") &&
    x6["gated_head_search"].to_s.include?("1 conflicting")
end

# X7: a lookup that could not run never reads as one that found nothing,
# on the join path too.
x7 = fixture { rb_resolve(rb_landing, RB_RUNS + [RB_PUSH], S.could_not_look("jq is not on PATH")) }
check("X7 a cover that could not run: the ticket joins, and its source says the cover was not judged") do
  x7["gated_head"] == RB_GATED && x7["gated_head_source"].to_s.include?("could not be judged (jq is not on PATH)")
end
x7r = fixture do
  rb_resolve(rb_landing, RB_RUNS, S.empty("no landed main is known"),
             receipt: S.could_not_look("eeeeeeee.json is unreadable"))
end
check("X7 an unreadable receipt for the landed commit is named, never 'no receipt'") do
  s = x7r["gated_head_source"].to_s
  s.include?("its receipt could not be read (eeeeeeee.json is unreadable)") && !s.include?("no receipt or")
end
check("X4 a red run's head is no candidate") do
  red = [ev("integration_gate.run", "2026-10-01T03:59:00Z", head: RB_GATED2, duration_s: 1.0,
            attrs: { "exit_code" => 1 })]
  rb_resolve(rb_landing, RB_RUNS + red, S.empty("no cover"))["gated_head"] == RB_GATED
end
check("X4 a run before the ticket's previous landing is no candidate") do
  l = rb_landing.merge("after" => t("2026-10-01T04:01:00Z"))
  rb_resolve(l, RB_RUNS, S.empty("no cover"))["gated_head"] == RB_LANDED
end
sq_l = landing.merge("landed_via" => "merge", "landed_commit" => "1" * 40, "gated_head" => HEAD)
check("X5 a merge landing is left as it was") { rb_resolve(sq_l, RB_RUNS, S.empty("x")) == sq_l }

# ── DND-1819: no gate ran before the final integration run ─────────────────
# Verify is the captain's time between the first gate run and the final
# integration attempt. When the unit's first gate run is the one inside its
# final integration run, no gate ran before that attempt: the window is
# empty, and verify is a measured 0 that starts where it ends (the run's
# start in the with-critic flow, the PASS in the standalone flow). The recorded
# gate_first anchor is kept as it was; the cells say which shape they read.

# A fresh landing: a check block above (X4) reassigns the top-level `l`.
vl = landing

VW = [
  ev("integration_gate.run", "2026-10-01T04:00:00Z", duration_s: 300.0, attrs: WC_RUN),
  ev("harness_gate.run", "2026-10-01T04:00:05Z", duration_s: 280.0, attrs: { "ok" => true, "run_id" => "v1" }),
  ev("critic.round", "2026-10-01T04:00:06Z", duration_s: 45.0, attrs: { "verdict" => "pass" }),
].freeze
va = fixture { anchors(wl, S.ok(VW + [PUSH])) }
vp = fixture { L::Phases.compute(va) }
check("V1 with-critic, first gate inside the final run: the flow is with_critic") { L::Phases.flow(va) == "with_critic" }
check("V1 verify is a measured 0, not invalid") do
  vp.dig("verify", "s") == 0 && !vp["verify"].key?("invalid") && !vp["verify"].key?("na_reason")
end
check("V1 the verify cell names the shape") { vp.dig("verify", "basis").to_s.include?("inside its final integration run") }
check("V1 implement ends at the final run's start") { vp.dig("implement", "s") == 3 * 3600 }
check("V1 the implement cell names the shape") { vp.dig("implement", "basis").to_s.include?("inside its final integration run") }
check("V1 integrate, queue and merge read as in W1") do
  vp.dig("integrate", "s") == 300 && vp.dig("queue", "s") == 25 * 60 && vp.dig("merge", "s") == 5
end
check("V1 the phases sum to landing - dispatch exactly") do
  L::PHASES.all? { |p| vp.dig(p, "s").is_a?(Integer) } &&
    vp.values.sum { |c| c["s"] } == (wl["landed_at"] - wl["start"]).to_i
end
check("V1 the recorded gate_first anchor is the real first gate run") { va["gate_first"].at == t("2026-10-01T04:00:05Z") }
vg = fixture { L::Counters.verify_gate_runs(landing: wl, events: S.ok(VW + [PUSH]), anchors: va) }
check("V1 gate_runs_s is a measured 0.0 (no gate run inside an empty verify)") { vg["gate_runs_s"].eql?(0.0) }
vrow = fixture do
  L::Ledger.improve_row(repo: "custom", landing: wl, anchors: va, counters: {}, telemetry_status: :ok,
                        ingested_at: t("2026-10-01T06:00:00Z"), origin: L::Origin.local("x"), verify_gate_runs: vg)
end
check("V1 the ledger row carries verify 0 with its basis and the gate split") do
  vrow.dig("phases", "verify", "s") == 0 && vrow.dig("phases", "verify", "gate_runs_s") == 0.0 &&
    vrow.dig("phases", "verify", "basis").is_a?(String) && vrow.dig("anchors", "gate_first", "at") == "2026-10-01T04:00:05Z"
end
check("V1 the summary counts verify as measured") do
  v = L::Stats.summarize([vrow])["phases"]["verify"]
  v["n"] == 1 && v["n_na"].zero? && v["sum_s"].zero?
end

# The standalone flow: the PASS stood before the run, and the first gate run
# is inside it, so the PASS is before gate_first.
VS = [
  ev("critic.round", "2026-10-01T03:59:00Z", duration_s: 30.0, attrs: { "verdict" => "pass" }),
  ev("integration_gate.run", "2026-10-01T04:00:00Z", duration_s: 300.0,
                             attrs: { "exit_code" => 0, "outcome" => "ok", "with_critic" => false }),
  ev("harness_gate.run", "2026-10-01T04:00:04Z", duration_s: 280.0, attrs: { "ok" => true, "run_id" => "v2" }),
].freeze
sa = fixture { anchors(vl, S.ok(VS)) }
sp = fixture { L::Phases.compute(sa) }
check("V2 standalone, PASS before a first gate inside the final run: the flow is standalone") { L::Phases.flow(sa) == "standalone" }
check("V2 verify is a measured 0, not invalid") do
  sp.dig("verify", "s") == 0 && !sp["verify"].key?("invalid") && sp.dig("verify", "basis").to_s.include?("inside its final integration run")
end
check("V2 implement ends at the PASS, queue = the PASS -> the run's start") do
  sp.dig("implement", "s") == (t("2026-10-01T03:59:30Z") - t("2026-10-01T01:00:00Z")).to_i && sp.dig("queue", "s") == 30
end
check("V2 the phases sum to landing - dispatch exactly") do
  L::PHASES.all? { |p| sp.dig(p, "s").is_a?(Integer) } &&
    sp.values.sum { |c| c["s"] } == (vl["landed_at"] - vl["start"]).to_i
end
sg = fixture { L::Counters.verify_gate_runs(landing: vl, events: S.ok(VS), anchors: sa) }
check("V2 gate_runs_s is a measured 0.0") { sg["gate_runs_s"] == 0.0 }

# The standalone flow, PASS before a first gate run that is NOT inside the
# final run: the captain gated after the PASS. No PASS follows the first gate,
# so verify has no end: n/a naming the shape, never invalid, never 0.
VS3 = [
  ev("critic.round", "2026-10-01T03:00:00Z", duration_s: 30.0, attrs: { "verdict" => "pass" }),
  ev("harness_gate.run", "2026-10-01T03:30:00Z", duration_s: 100.0, attrs: { "ok" => true, "run_id" => "v3" }),
  ev("integration_gate.run", "2026-10-01T04:00:00Z", duration_s: 300.0,
                             attrs: { "exit_code" => 0, "outcome" => "ok", "with_critic" => false }),
].freeze
s3 = fixture { L::Phases.compute(anchors(vl, S.ok(VS3))) }
check("V3 standalone, PASS before a first gate outside the run: verify is n/a, not invalid") do
  s3.dig("verify", "s").nil? && !s3["verify"].key?("invalid")
end
check("V3 the reason names the shape") do
  r = s3.dig("verify", "na_reason").to_s
  r.include?("critic PASS") && r.include?("before the first gate run") && !r.start_with?("invalid")
end
check("V3 implement and queue read as before") do
  s3.dig("implement", "s") == 9000 && s3.dig("queue", "s") == (t("2026-10-01T04:00:00Z") - t("2026-10-01T03:00:30Z")).to_i
end
s3g = fixture { L::Counters.verify_gate_runs(landing: vl, events: S.ok(VS3), anchors: anchors(vl, S.ok(VS3))) }
check("V3 gate_runs_s carries verify's n/a reason") do
  s3g["gate_runs_s"].nil? && s3g["gate_runs_na"].to_s.include?("before the first gate run")
end

# With-critic, the first gate run after the final run's start, whose end is
# not recorded: whether it is inside cannot be told. n/a naming that, never
# invalid.
VW4 = [ev("integration_gate.run", "2026-10-01T04:00:00Z", attrs: WC_RUN)] + VW[1..]
w4 = fixture { L::Phases.compute(anchors(wl, S.ok(VW4 + [PUSH]))) }
check("V4 first gate after a final run with no recorded end: verify is n/a, not invalid") do
  w4.dig("verify", "s").nil? && !w4["verify"].key?("invalid") && w4.dig("verify", "na_reason").to_s.include?("no recorded end")
end

# Not these shapes: the rows that were measured before stay as they were.
check("V5 a normal with-critic row is unchanged and carries no basis") do
  L::Phases.compute(wa) == wp && wp.values.none? { |c| c.key?("basis") } && wp.dig("verify", "s") == 7200
end
check("V5 a normal standalone row is unchanged and carries no basis") do
  L::Phases.compute(anchors(vl, S.ok(FULL))) == ph && ph.values.none? { |c| c.key?("basis") }
end
check("V5 a gate before the dispatch stamp stays invalid (another shape)") { L::Phases.compute(anchors(vl, S.ok(early)))["implement"]["invalid"] == true }
# A first gate run after the final run ENDED is not inside it: left as it was.
VW6 = [VW[0], VW[2], ev("harness_gate.run", "2026-10-01T04:10:00Z", duration_s: 60.0, attrs: { "ok" => true, "run_id" => "v6" })]
w6 = fixture { L::Phases.compute(anchors(wl, S.ok(VW6 + [PUSH]))) }
check("V6 a first gate run after the final run ended is not this shape: verify stays invalid") do
  w6.dig("verify", "invalid") == true && !w6["verify"].key?("basis")
end

# Review round: the boundaries and the guards.
# A first gate in the run's own second already read verify 0 (with-critic):
# left exactly as it was, no basis.
VW7 = [VW[0], ev("harness_gate.run", "2026-10-01T04:00:00.700Z", duration_s: 280.0, attrs: { "ok" => true }), VW[2]]
w7 = fixture { L::Phases.compute(anchors(wl, S.ok(VW7 + [PUSH]))) }
check("V7 with-critic, first gate in the run's own second: verify 0, no basis (as before)") do
  w7.dig("verify", "s").zero? && w7.values.none? { |c| c.key?("basis") } && w7.dig("implement", "s") == 3 * 3600
end
# Standalone, the same second: the PASS is before it, so it is this shape.
VS8 = [VS[0], VS[1], ev("harness_gate.run", "2026-10-01T04:00:00.700Z", duration_s: 280.0, attrs: { "ok" => true })]
s8 = fixture { L::Phases.compute(anchors(vl, S.ok(VS8))) }
check("V8 standalone, first gate in the run's own second: verify a measured 0 with its basis") do
  s8.dig("verify", "s").zero? && s8.dig("verify", "basis").is_a?(String) && s8.dig("queue", "s") == 30
end
# A first gate run in the run's last second is inside it.
VW9 = [VW[0], ev("harness_gate.run", "2026-10-01T04:05:00Z", duration_s: 1.0, attrs: { "ok" => true }), VW[2]]
w9 = fixture { L::Phases.compute(anchors(wl, S.ok(VW9 + [PUSH]))) }
check("V9 a first gate run at the final run's end second is inside it: verify 0") do
  w9.dig("verify", "s").zero? && w9.dig("verify", "basis").is_a?(String)
end
# Standalone with no PASS and the first gate inside the run: verify is n/a
# with the PASS's own reason (never the derived anchor, never invalid).
VS10 = VS[1..]
s10 = fixture { L::Phases.compute(anchors(vl, S.ok(VS10))) }
check("V10 standalone, no PASS, first gate inside the run: verify n/a with the no-PASS reason") do
  s10.dig("verify", "s").nil? && !s10["verify"].key?("invalid") && s10.dig("verify", "na_reason").include?("no critic PASS")
end
# Standalone, a PASS, and a final run with no recorded end.
VS11 = [VS[0], VS[1].merge("duration_s" => nil), VS[2]]
s11 = fixture { L::Phases.compute(anchors(vl, S.ok(VS11))) }
check("V11 standalone, first gate after a final run with no recorded end: verify n/a naming it") do
  s11.dig("verify", "s").nil? && !s11["verify"].key?("invalid") && s11.dig("verify", "na_reason").include?("no recorded end")
end
# Standalone, PASS before a first gate run that is before the dispatch stamp:
# a re-dispatch shape, left invalid.
late = landing(start: "2026-10-01T03:40:00Z")
VS12 = [ev("critic.round", "2026-10-01T03:00:00Z", duration_s: 30.0, attrs: { "verdict" => "pass" }),
        ev("harness_gate.run", "2026-10-01T03:30:00Z", duration_s: 100.0, attrs: { "ok" => true }), VS[1]]
s12 = fixture { L::Phases.compute(anchors(late, S.ok(VS12))) }
check("V12 standalone, a first gate run before the dispatch stamp stays invalid") do
  s12.dig("verify", "invalid") == true && s12.dig("implement", "invalid") == true
end

if $failures.empty?
  puts "lead-time-phases: #{$checks} checks passed"
  exit 0
end
$failures.each { |f| puts "FAIL #{f}" }
puts "lead-time-phases: #{$failures.size} of #{$checks} checks failed"
exit 1
