# frozen_string_literal: true

# make_ledger.rb -- writes the fixture ledger self-test.sh judges (DND-1478).
#
#   ruby make_ledger.rb OUT LANDING_SHA [AFTER_VERIFY_S [BASE_TIME [checks]]]
#
# Ten landings before LANDING_SHA (verify 600 s, implement n/a: before its
# emitter), the landing itself, then ten after (verify AFTER_VERIFY_S,
# default 500 s; implement measured). Landings are hourly from BASE_TIME
# (default 2026-09-20T00:00:00Z): before at +1h..+10h, the landing at +11h,
# after at +12h..+21h. Every landing carries one critic round and one gate run, none
# red, so the guards are measured and equal on both sides. Synthetic ids
# only (DND-9xxx).
#
# With the fifth argument `checks` (DND-1548), every landing also carries
# check_walls: CHECK_WAIT reads 120 s before the landing and 5 s after it,
# while the other two checks hold steady.

require "json"
require "time"

out, landing, after_verify, base_time, checks = ARGV
after_verify = Integer(after_verify || "500")
base = Time.iso8601(base_time || "2026-09-20T00:00:00Z")

CHECK_WAIT = "self-test: fixture/control/wait"
CHECK_OTHERS = { "self-test: fixture/merge-boarding" => 160.0, "blast-radius self-test" => 83.0 }.freeze

def row(at, sha, verify, implement, wait)
  r = { "schema" => 1, "repo" => "custom", "mode" => "improve", "ticket" => "DND-9#{sha[0, 3]}",
        "landed_commit" => sha, "gated_head" => sha, "landed_at" => at.utc.iso8601, "landed_via" => "push",
        "start" => nil, "lead_s" => nil, "code_s" => nil, "tail_s" => 0,
        "phases" => {
          "implement" => { "s" => implement, "na_reason" => implement ? nil : "no harness_gate.run or gate.run for DND-9000" },
          "verify" => { "s" => verify, "na_reason" => verify ? nil : "no critic PASS" },
          "queue" => { "s" => nil, "na_reason" => "no critic PASS" },
          "integrate" => { "s" => nil, "na_reason" => "no integration_gate.run" },
          "merge" => { "s" => nil, "na_reason" => "no integration_gate.run" },
        },
        "counters" => { "gate_runs" => 1, "gate_red" => 0, "critic_rounds" => 1, "critic_blocks" => 0 } }
  r["check_walls"] = CHECK_OTHERS.merge(CHECK_WAIT => wait) if wait
  r
end

walls = checks == "checks"
rows = (1..10).map { |i| row(base + (i * 3600), format("%040x", 0xa000 + i), 600, nil, walls && 120.0) }
rows << row(base + (11 * 3600), landing, 550, nil, walls && 60.0)
rows += (12..21).map { |i| row(base + (i * 3600), format("%040x", 0xb000 + i), after_verify, 300, walls && 5.0) }
File.write(out, rows.map { |r| "#{JSON.generate(r)}\n" }.join)
