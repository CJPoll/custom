# frozen_string_literal: true

# make_tail_ledger.rb -- writes a fixture ledger for a repo with post-merge
# CI, for the tail experiments self-test.sh judges (DND-1613).
#
#   ruby make_tail_ledger.rb OUT REPO LANDING_SHA AFTER_TAIL_S BASE_TIME [no-runs]
#
# Landings are hourly from BASE_TIME. Before: +1h..+13h, a measured tail of
# 3600 s (tail_end deploy) except +4h, +8h and +11h, where lead-time found no
# post-merge run (tail 0, end kind merge). The landing itself at +14h. After:
# +15h..+27h, a measured tail of AFTER_TAIL_S except +18h and +21h (no run,
# end kind merge) and +16h (tail 0 with no end kind: ingested before
# DND-1532). Every other landing is foreign (DND-1531): worked on another
# machine, its phases null, its tail still read from the forge. Every landing
# carries one critic round and one gate run, none red, so the guards are
# measured and equal on both sides. Synthetic ids only (DND-9xxx).
#
# With `no-runs`, no landing has a post-merge run (all end kind merge): a
# repo where tail cannot be judged.

require "json"
require "time"

out, repo, landing, after_tail, base_time, mode = ARGV
after_tail = Integer(after_tail)
base = Time.iso8601(base_time)
no_runs = mode == "no-runs"

def row(repo, at, sha, tail_s, tail_end, foreign)
  r = { "schema" => 1, "repo" => repo, "mode" => "improve", "ticket" => "DND-9#{sha[-3, 3]}",
        "landed_commit" => sha, "gated_head" => sha, "landed_at" => at.utc.iso8601, "landed_via" => "merge",
        "start" => nil, "lead_s" => 7200 + tail_s, "code_s" => 7200, "tail_s" => tail_s,
        "phases" => { "verify" => { "s" => foreign ? nil : 600, "na_reason" => foreign ? "worked on another machine" : nil } },
        "counters" => { "gate_runs" => 1, "gate_red" => 0, "critic_rounds" => 1, "critic_blocks" => 0 },
        "origin" => foreign ? "foreign" : "local" }
  r["tail_end"] = tail_end unless tail_end == :absent
  r
end

rows = (1..13).map do |i|
  run = !no_runs && ![4, 8, 11].include?(i)
  row(repo, base + (i * 3600), format("%040x", 0xc000 + i), run ? 3600 : 0, run ? "deploy" : "merge", i.even?)
end
rows << row(repo, base + (14 * 3600), landing, no_runs ? 0 : 3600, no_runs ? "merge" : "deploy", false)
rows += (15..27).map do |i|
  if i == 16
    row(repo, base + (i * 3600), format("%040x", 0xd000 + i), 0, :absent, false)
  else
    run = !no_runs && ![18, 21].include?(i)
    row(repo, base + (i * 3600), format("%040x", 0xd000 + i), run ? after_tail : 0, run ? "pipeline" : "merge", i.even?)
  end
end
File.write(out, rows.map { |r| "#{JSON.generate(r)}\n" }.join)
