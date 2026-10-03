# frozen_string_literal: true

# Deterministic suite for lead time across a park (DND-1838): the dispatch
# stamp mark-in-progress writes, read back by ai/bin/lead-time's NotionStart,
# through ONE stateful fake Notion that applies each PATCH to the page. So the
# lead measured here is the lead the two real tools produce together.
#
# Cases (ai/docs/lead-time-tracking.md -> Decisions -> A park restarts the start):
#   - a ticket Parked then re-dispatched measures, and the parked span is not
#     in its lead;
#   - a ticket never Parked is unchanged;
#   - a re-dispatch with no stamp and no park says so with a Fix:, never a zero.
#
# No network, no token, no overlay read. Ticket refs are synthetic (DND-93xx).
# Run by ./self-test.sh, which harness-gate discovers.

require "stringio"
require "tmpdir"
require "fileutils"
require "time"

TELEMETRY_ROOT = Dir.mktmpdir("park-telemetry")
at_exit { FileUtils.rm_rf(TELEMETRY_ROOT) }
ENV["ATHENA_TELEMETRY_DIR"] = File.join(TELEMETRY_ROOT, "store")

load File.expand_path("../../bin/lead-time", __dir__)
load File.expand_path("../../skills/athena:ticket-management/scripts/mark-in-progress", __dir__)

$failures = []
$checks = 0

def check(desc)
  $checks += 1
  $failures << desc unless yield
rescue StandardError => e
  $failures << "#{desc} (raised #{e.class}: #{e.message})"
end

# One DND Tickets page whose properties change as the tools PATCH it.
class StatefulNotion
  attr_reader :page

  def initialize(status)
    @page = { "id" => "p-park", "properties" => {
      "Status" => { "type" => "status", "status" => { "name" => status } },
      "In Progress at" => { "type" => "date", "date" => nil },
    } }
  end

  def status=(name)
    @page["properties"]["Status"]["status"] = { "name" => name }
  end

  def stamp
    @page["properties"].dig("In Progress at", "date", "start")
  end

  def call(method, _path, body = nil)
    case method
    when :post then { "results" => [@page] }
    when :patch
      body["properties"].each do |k, v|
        @page["properties"][k] = @page["properties"][k].merge(v)
      end
      @page
    end
  end
end

def dispatch(notion, ref, at)
  out = StringIO.new
  err = StringIO.new
  code = MarkInProgress.run(["--ref", ref], transport_for: ->(_t) { notion }, now: Time.iso8601(at),
                                            work: -> { raise "a DND ticket must not read the overlay" },
                                            out: out, err: err)
  [code, out.string, err.string]
end

# The row lead-time gives a landing of `ref` at `landed`, with no CI.
def lead_row(notion, ref, landed)
  starts = NotionStart.new(notion)
  start_at, why = starts.lookup(ref)
  LeadTime.compute(start_at: start_at, start_source: starts.source(ref), start_unmeasured: why,
                   deploy_at: nil, pipeline_at: nil, merged_at: landed)
end

T0 = "2026-09-28T01:00:00Z" # first dispatch
T1 = "2026-09-28T03:00:00Z" # parked (the admiral's move; no tool stamps it)
T2 = "2026-09-30T04:00:00Z" # re-dispatched from Parked
T3 = "2026-09-30T05:00:00Z" # landed

# --- Parked, then re-dispatched: it measures, and the parked span is excluded.
parked = StatefulNotion.new("Todo")
dispatch(parked, "DND-9301", T0)
parked.status = "Parked"
code, _o, err = dispatch(parked, "DND-9301", T2)
row = lead_row(parked, "DND-9301", T3)
check("a re-dispatch from Parked exits 0 with nothing on stderr") { code == 0 && err.empty? }
check("a ticket Parked then re-dispatched measures") { row[:lead_seconds] && row[:unmeasured_reason].nil? }
check("its lead starts at the re-dispatch, so the parked span #{T1}..#{T2} is not in it") do
  row[:start] == T2 && row[:lead_seconds] == Time.iso8601(T3) - Time.iso8601(T2)
end
check("its lead is shorter than the span from the first dispatch") do
  row[:lead_seconds] < Time.iso8601(T3) - Time.iso8601(T1)
end

# --- an unstamped ticket re-dispatched from Parked (DND-1095's shape) measures.
unstamped = StatefulNotion.new("Parked")
dispatch(unstamped, "DND-9302", T2)
row = lead_row(unstamped, "DND-9302", T3)
check("an unstamped ticket re-dispatched from Parked measures from the re-dispatch") do
  row[:start] == T2 && row[:lead_seconds] == 3600
end

# --- never Parked: unchanged.
plain = StatefulNotion.new("Todo")
dispatch(plain, "DND-9303", T0)
plain.status = "Attention Given"
dispatch(plain, "DND-9303", T2) # a re-dispatch that was not a park keeps the first stamp
row = lead_row(plain, "DND-9303", T3)
check("a ticket never Parked keeps its first dispatch as the start") do
  row[:start] == T0 && row[:lead_seconds] == Time.iso8601(T3) - Time.iso8601(T0)
end

# --- a re-dispatch with no record and no park: never a silent zero.
norecord = StatefulNotion.new("Attention Given")
code, _o, err = dispatch(norecord, "DND-9304", T2)
row = lead_row(norecord, "DND-9304", T3)
check("mark-in-progress says it did not stamp, with Fix:") do
  code == 0 && norecord.stamp.nil? && err.include?("not stamped") && err.include?("Fix:")
end
check("lead-time reads it could-not-measure, never a lead of zero") do
  row[:lead_seconds].nil? && row[:unmeasured_reason].to_s.include?("has no 'In Progress at' date")
end
check("lead-time's reason names the fix") do
  row[:unmeasured_reason].to_s.include?("Fix:") && row[:unmeasured_reason].to_s.include?("mark-in-progress")
end

if $failures.empty?
  puts "park_test: PASS (#{$checks} checks)"
  exit 0
end
warn "park_test: FAIL (#{$failures.size} of #{$checks})"
$failures.each { |f| warn "  - #{f}" }
warn "Fix: a re-dispatch from Parked must restamp the dispatch date (mark-in-progress), and lead-time must " \
     "read that stamp, so a park is measurable and its span is never lead time (ai/docs/lead-time-tracking.md)."
exit 1
