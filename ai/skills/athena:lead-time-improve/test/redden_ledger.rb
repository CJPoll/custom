# frozen_string_literal: true

# redden_ledger.rb -- marks every gate run red on the landings after a time
# (DND-1810), so a fixture ledger from make_ledger.rb reads a worse
# gate_red_rate guard on its after-set.
#
#   ruby redden_ledger.rb LEDGER AFTER_TIME
#
# Rewrites LEDGER in place (a fixture in a temp dir). Synthetic data only.

require "json"
require "time"

path, after = ARGV
cut = Time.iso8601(after)
rows = File.readlines(path).map { |l| JSON.parse(l) }
rows.each do |r|
  next unless Time.iso8601(r["landed_at"]) > cut

  r["counters"]["gate_red"] = r["counters"]["gate_runs"]
end
File.write(path, rows.map { |r| "#{JSON.generate(r)}\n" }.join)
