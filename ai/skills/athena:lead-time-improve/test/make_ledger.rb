# frozen_string_literal: true

# make_ledger.rb -- writes the fixture ledger self-test.sh judges (DND-1478).
#
#   ruby make_ledger.rb OUT LANDING_SHA
#
# Ten landings before LANDING_SHA (verify 600 s, implement n/a: before its
# emitter), the landing itself, then ten after (verify 500 s, implement
# measured). Every landing carries one critic round and one gate run, none
# red, so the guards are measured and equal on both sides. Synthetic ids
# only (DND-9xxx).

require "json"
require "time"

out, landing = ARGV
base = Time.iso8601("2026-09-20T00:00:00Z")

def row(at, sha, verify, implement)
  { "schema" => 1, "repo" => "custom", "mode" => "improve", "ticket" => "DND-9#{sha[0, 3]}",
    "landed_commit" => sha, "landed_at" => at.utc.iso8601, "landed_via" => "push", "start" => nil,
    "lead_s" => nil, "code_s" => nil, "tail_s" => 0,
    "phases" => {
      "implement" => { "s" => implement, "na_reason" => implement ? nil : "no harness_gate.run for DND-9000" },
      "verify" => { "s" => verify, "na_reason" => verify ? nil : "no critic PASS" },
      "queue" => { "s" => nil, "na_reason" => "no critic PASS" },
      "integrate" => { "s" => nil, "na_reason" => "no integration_gate.run" },
      "merge" => { "s" => nil, "na_reason" => "no integration_gate.run" },
    },
    "counters" => { "gate_runs" => 1, "gate_red" => 0, "critic_rounds" => 1, "critic_blocks" => 0 } }
end

rows = (1..10).map { |i| row(base + (i * 3600), format("%040x", 0xa000 + i), 600, nil) }
rows << row(base + (11 * 3600), landing, 550, nil)
rows += (12..21).map { |i| row(base + (i * 3600), format("%040x", 0xb000 + i), 500, 300) }
File.write(out, rows.map { |r| "#{JSON.generate(r)}\n" }.join)
