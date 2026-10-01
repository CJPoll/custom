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
  { "ticket" => ticket, "landed_commit" => commit, "landed_at" => t(landed), "landed_via" => "push",
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
check("P2 the reason names the unit") { ph2["implement"]["na_reason"] == "no harness_gate.run for DND-9001" }
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
check("C2 empty telemetry: from timings rows, latest per label") do
  c3["top_checks"] == [{ "label" => "x", "wall_s" => 9.0 }, { "label" => "y", "wall_s" => 5.0 }] &&
    c3["top_checks_source"] == "harness-gate timings.jsonl"
end
c4 = L::Counters.compute(landing: l, events: S.ok([]), timings: S.could_not_look("no timings file"))
check("C2 both empty: null with a reason naming both sources") do
  c4["top_checks"].nil? && c4["top_checks_na"].include?("no harness_gate.check") && c4["top_checks_na"].include?("timings: could not look")
end
check("C3 a counter with no source events is null with a reason, never 0") do
  c4["counters"]["gate_runs"].nil? && c4["counters_na"]["gate_runs"] == "no harness_gate.run for DND-9001"
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

# ── Config.parse ───────────────────────────────────────────────────────────

def cfg(repos, window: 20) = JSON.generate("repos" => repos, "window" => window, "improvement_epic" => "epic-id")

def raises(text)
  L::Config.parse(text, home: "/home/u")
  nil
rescue L::ConfigError => e
  e.message
end

check("K1 an unknown mode raises naming the repo") { raises(cfg([{ "name" => "custom", "path" => "~/dev/custom", "mode" => "fix" }])).to_s.include?('"custom" has unknown mode') }
check("K2 a duplicate name raises") do
  r = { "name" => "custom", "path" => "~/dev/custom", "mode" => "improve" }
  raises(cfg([r, r])).to_s.include?("listed 2 times")
end
check("K4 a missing key raises") { raises(cfg([{ "name" => "custom", "path" => "~/dev/custom" }])).to_s.include?("missing mode") }
check("K4 an unknown key raises") { raises(cfg([{ "name" => "c", "path" => "/p", "mode" => "watch", "x" => 1 }])).to_s.include?("unknown key") }
check("K4 a zero window raises") { raises(cfg([{ "name" => "c", "path" => "/p", "mode" => "watch" }], window: 0)).to_s.include?("window") }
check("K4 a relative path raises") { raises(cfg([{ "name" => "c", "path" => "dev/c", "mode" => "watch" }])).to_s.include?("not absolute") }
seed_path = File.expand_path("../../config/lead-time-repos.json", __dir__)
seed = L::Config.parse(File.read(seed_path), home: "/home/u")
check("K3 the committed seed parses") { seed.repos.map { |r| [r.name, r.mode] } == [%w[custom improve], %w[gen_saas watch], %w[walt_ui watch]] }
check("K3 seed paths expand ~/dev/<name>") { seed.repos.map(&:path) == %w[/home/u/dev/custom /home/u/dev/gen_saas /home/u/dev/walt_ui] }
check("K3 seed window is 20") { seed.window == 20 }
check("K5 find names the configured repos on a miss") do
  L::Config.find(seed, "nope")
  false
rescue L::ConfigError => e
  e.message.include?("custom, gen_saas, walt_ui")
end

# ── Landing.from_row, Ledger ───────────────────────────────────────────────

pr_row = { "pr" => 7, "landed_via" => "merge", "merge_commit" => OTHER, "landed_commit" => nil, "merged" => "2026-10-01T05:00:00Z",
           "start" => nil, "unmeasured_reason" => "start: no stamp" }
lnd, = L::Landing.from_row(pr_row, ticket: "DND-9001")
check("L1 a merge row's landed commit is its merge commit") { lnd["landed_commit"] == OTHER }
check("L1 a missing start carries lead-time's reason") { lnd["start"].nil? && lnd["start_na"] == "start: no stamp" }
_, why = L::Landing.from_row(pr_row.merge("merge_commit" => nil), ticket: nil)
check("L2 no landed commit: refused with a reason") { why.to_s.include?("no landed commit") }
_, why = L::Landing.from_row(pr_row.merge("merged" => nil), ticket: nil)
check("L2 no landing time: refused with a reason") { why.to_s.include?("no landing time") }

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
