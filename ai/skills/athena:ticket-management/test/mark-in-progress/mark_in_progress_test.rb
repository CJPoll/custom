# frozen_string_literal: true

# Deterministic suite for scripts/mark-in-progress (DND-1318; the work
# tracker, DND-1341): the pure plan, and the manager behind a fake Notion
# transport and a fake work-tracker resolution. No network, no token, no
# overlay read; work values are synthetic.
# Run by ./self-test.sh, which harness-gate discovers.

require "stringio"
load File.expand_path("../../scripts/mark-in-progress", __dir__)

$failures = []
$checks = 0

def check(desc)
  $checks += 1
  $failures << desc unless yield
rescue StandardError => e
  $failures << "#{desc} (raised #{e.class}: #{e.message})"
end

class FakeNotion
  attr_reader :calls

  def initialize(page, fail_with = nil)
    @page = page
    @fail = fail_with
    @calls = []
  end

  def call(method, path, body = nil)
    @calls << [method, path, body]
    raise NextMissionNotion::ReadError, @fail if @fail
    return { "results" => @page ? [@page] : [] } if method == :post

    @page
  end

  def patches
    @calls.select { |m, _p, _b| m == :patch }
  end
end

def page(stamp, with_property: true, status: "Todo")
  props = { "Status" => { "status" => { "name" => status } } }
  props["In Progress at"] = { "type" => "date", "date" => stamp && { "start" => stamp } } if with_property
  { "id" => "p1318", "properties" => props }
end

NOW = Time.utc(2026, 9, 30, 5, 32, 0)

# The work tracker as the private overlay would give it: synthetic values only.
WORK = DispatchTrackers.work_from(
  data_source: "0000aaaa-1111-2222-3333-444455556666", prefix: "ZQ", property: "Synthetic stamp",
  first_dispatch_from: '["Todo","Backlog","Shaping"]',
)
ABSENT = DispatchTrackers::Resolution.new(
  tracker: nil, fault: false,
  reason: "private-overlay: ABSENT: key=notion.work.tickets_data_source probed=/nowhere. Fix: overlay unavailable here",
)
$used_trackers = []

def run(argv, notion, work: WORK)
  out = StringIO.new
  err = StringIO.new
  asked = false
  code = MarkInProgress.run(argv, transport_for: ->(t) { $used_trackers << t; notion }, now: NOW,
                                  work: -> { asked = true; work }, out: out, err: err)
  $work_asked = asked
  [code, out.string, err.string]
end

# --- stamps the first move to In Progress, with the status, in one write.
fresh = FakeNotion.new(page(nil))
code, out, = run(["--ref", "DND-1318"], fresh)
check("an unstamped ticket exits 0") { code == 0 }
check("one PATCH sets the status and the stamp together") do
  fresh.patches.size == 1 &&
    fresh.patches.first[2]["properties"] == {
      "Status" => { "status" => { "name" => "In Progress" } },
      "In Progress at" => { "date" => { "start" => "2026-09-30T05:32:00Z" } },
    }
end
check("it writes to the ticket's page") { fresh.patches.first[1] == "/v1/pages/p1318" }
check("it says it stamped") { out.include?("stamped") && out.include?("2026-09-30T05:32:00Z") }
check("it queries DND Tickets by the ticket number") do
  m, path, body = fresh.calls.first
  m == :post && path == "/v1/data_sources/#{NextMissionNotion::TICKETS_DATA_SOURCE}/query" &&
    body.dig("filter", "property") == "ID" && body.dig("filter", "unique_id", "equals") == 1318
end

# --- an unstamped ticket resumed from Parked is NOT stamped now: its first
#     dispatch was earlier and unknown here.
resumed = FakeNotion.new(page(nil, status: "Parked"))
code, out, err = run(["--ref", "DND-1318"], resumed)
check("a resume from Parked moves the status and does not stamp") do
  code == 0 && resumed.patches.first[2]["properties"].keys == ["Status"]
end
check("and says why, with the backfill fix") { out.include?("not stamped") && err.include?("--backfill") }

# --- a re-dispatch keeps the FIRST stamp.
again = FakeNotion.new(page("2026-09-30T02:41:00.000Z"))
code, out, = run(["--ref", "DND-1318"], again)
check("a stamped ticket still exits 0") { code == 0 }
check("a re-dispatch writes the status only, keeping the first stamp") do
  again.patches.first[2]["properties"].keys == ["Status"]
end
check("it says it kept the stamp") { out.include?("kept") && out.include?("2026-09-30T02:41:00.000Z") }

# --- a backfill from a recorded dispatch time.
back = FakeNotion.new(page(nil))
code, = run(["--ref", "DND-1203", "--at", "2026-09-30T02:41:00Z"], back)
check("--at stamps the given time") do
  code == 0 && back.patches.first[2].dig("properties", "In Progress at", "date", "start") == "2026-09-30T02:41:00Z"
end
code, _o, err = run(["--ref", "DND-1203", "--at", "2026-09-30"], FakeNotion.new(page(nil)))
check("--at with no time is a usage error with Fix:") { code == 2 && err.include?("Fix:") }
nozone = FakeNotion.new(page(nil))
code, _o, err = run(["--ref", "DND-1203", "--at", "2026-09-30T02:41:00"], nozone)
check("--at with no zone is a usage error, never read as local time") do
  code == 2 && err.include?("zone") && nozone.patches.empty?
end
wrongtype = page(nil)
wrongtype["properties"]["In Progress at"] = { "type" => "rich_text", "rich_text" => [] }
wt = FakeNotion.new(wrongtype)
code, _o, err = run(["--ref", "DND-1318"], wt)
check("a non-date property is refused with Fix:, not written") { code == 3 && err.include?("Fix:") && wt.patches.empty? }

# --- a backfill stamps only: a landed ticket's status is left alone.
bf = FakeNotion.new(page(nil))
code, out, = run(["--ref", "DND-1203", "--backfill", "--at", "2026-09-30T02:41:00Z"], bf)
check("--backfill writes the stamp and not the status") do
  code == 0 && bf.patches.first[2]["properties"].keys == ["In Progress at"] && out.include?("Status unchanged")
end
bf2 = FakeNotion.new(page("2026-09-30T01:00:00.000Z"))
code, = run(["--ref", "DND-1203", "--backfill", "--at", "2026-09-30T02:41:00Z"], bf2)
check("--backfill on a stamped ticket writes nothing") { code == 0 && bf2.patches.empty? }
code, _o, err = run(["--ref", "DND-1203", "--backfill"], FakeNotion.new(page(nil)))
check("--backfill without --at is a usage error") { code == 2 && err.include?("Fix:") }

# --- a dry run writes nothing.
dry = FakeNotion.new(page(nil))
code, out, = run(["--ref", "DND-1318", "--dry-run"], dry)
check("--dry-run writes nothing") { code == 0 && dry.patches.empty? && out.include?("dry run") }

# --- every refusal names its fix, and never writes.
none = FakeNotion.new(nil)
code, _o, err = run(["--ref", "DND-9"], none)
check("a ticket not in DND Tickets exits 3 with Fix:") { code == 3 && err.include?("no DND-9") && err.include?("Fix:") }
check("and writes nothing") { none.patches.empty? }
noprop = FakeNotion.new(page(nil, with_property: false))
code, _o, err = run(["--ref", "DND-1318"], noprop)
check("a database without the property exits 3 with Fix:") { code == 3 && err.include?("Fix:") && noprop.patches.empty? }
down = FakeNotion.new(page(nil), "HTTP 502 on POST /v1/data_sources/x/query")
code, _o, err = run(["--ref", "DND-1318"], down)
check("an unreachable Notion exits 3 with Fix:") { code == 3 && err.include?("Fix:") }
code, _o, err = run(["--ref", "XY-12"], FakeNotion.new(page(nil)))
check("a ticket in no known tracker is a usage error naming both prefixes") do
  code == 2 && err.include?("Fix:") && err.include?("DND") && err.include?("ZQ")
end
$used_trackers.clear
run(["--ref", "DND-1318", "--dry-run"], FakeNotion.new(page(nil)))
check("a DND ticket never reads the overlay") { !$work_asked }
check("a DND ticket uses the DND tracker's transport (notion-personal)") do
  $used_trackers == [DispatchTrackers::DND]
end

# --- DND-1341: a work ticket, through the overlay's work tracker.
def work_page(stamp, status: "Todo", with_property: true)
  props = { "Status" => { "status" => { "name" => status } } }
  props["Synthetic stamp"] = { "type" => "date", "date" => stamp && { "start" => stamp } } if with_property
  { "id" => "pzq12", "properties" => props }
end
$used_trackers.clear
wfresh = FakeNotion.new(work_page(nil))
code, out, = run(["--ref", "ZQ-12"], wfresh)
check("a work ticket exits 0") { code == 0 }
check("it queries the overlay's work data source by the ticket number") do
  m, path, body = wfresh.calls.first
  m == :post && path == "/v1/data_sources/0000aaaa-1111-2222-3333-444455556666/query" &&
    body.dig("filter", "unique_id", "equals") == 12
end
check("one PATCH sets the status and the overlay's stamp property together") do
  wfresh.patches.size == 1 &&
    wfresh.patches.first[2]["properties"] == {
      "Status" => { "status" => { "name" => "In Progress" } },
      "Synthetic stamp" => { "date" => { "start" => "2026-09-30T05:32:00Z" } },
    }
end
check("it never writes the DND property on a work ticket") do
  !wfresh.patches.first[2]["properties"].key?("In Progress at")
end
check("it names the overlay's property in its output") { out.include?("Synthetic stamp") && out.include?("stamped") }
check("it uses the work tracker's transport (notion-work token)") do
  $used_trackers.map(&:prefix) == ["ZQ"] && $used_trackers.first.token_file.end_with?("notion-api-token")
end
wshape = FakeNotion.new(work_page(nil, status: "Shaping"))
run(["--ref", "ZQ-12"], wshape)
check("a move from an overlay first-dispatch status stamps") do
  wshape.patches.first[2]["properties"].key?("Synthetic stamp")
end
wpark = FakeNotion.new(work_page(nil, status: "Parked"))
_c, _o, err = run(["--ref", "ZQ-12"], wpark)
check("a move from any other status does not stamp, and says so") do
  wpark.patches.first[2]["properties"].keys == ["Status"] && err.include?("--backfill")
end
wkept = FakeNotion.new(work_page("2026-09-29T01:00:00.000Z"))
run(["--ref", "ZQ-12"], wkept)
check("a work re-dispatch keeps its first stamp") { wkept.patches.first[2]["properties"].keys == ["Status"] }
wnoprop = FakeNotion.new(work_page(nil, with_property: false))
code, _o, err = run(["--ref", "ZQ-12"], wnoprop)
check("a work tracker without the stamp property exits 3 naming it, with Fix:") do
  code == 3 && err.include?("Synthetic stamp") && err.include?("the work tracker") && err.include?("Fix:") &&
    wnoprop.patches.empty?
end
wnone = FakeNotion.new(nil)
code, _o, err = run(["--ref", "ZQ-99"], wnone)
check("a work ticket that is not there exits 3") { code == 3 && err.include?("no ZQ-99 in the work tracker") }
untouched = FakeNotion.new(work_page(nil))
code, _o, err = run(["--ref", "ZQ-12"], untouched, work: ABSENT)
check("with no overlay a work ticket is refused with exit 3, carrying the resolver's line") do
  code == 3 && err.include?("ABSENT") && err.include?("Fix:") && untouched.calls.empty?
end
fault = DispatchTrackers::Resolution.new(tracker: nil, fault: true,
                                         reason: "private-overlay: KEY_NOT_FOUND: key=notion.work.ticket_prefix. Fix: add it")
code, _o, err = run(["--ref", "ZQ-12"], FakeNotion.new(work_page(nil)), work: fault)
check("a missing overlay key is refused with exit 3, naming the key") do
  code == 3 && err.include?(".work.ticket_prefix")
end
check("a missing token is exit 3 naming the token file, never a write") do
  o = StringIO.new
  e = StringIO.new
  bad_file = lambda do |t|
    MarkInProgress.transport_for_token_file(t.dup.tap { |x| x.token_file = "/nonexistent/token" })
  end
  c = MarkInProgress.run(["--ref", "ZQ-12"], now: NOW, work: -> { WORK }, out: o, err: e, transport_for: bad_file)
  c == 3 && e.string.include?("/nonexistent/token") && e.string.include?("Fix:")
end
code, _o, err = run([], FakeNotion.new(page(nil)))
check("no --ref is a usage error") { code == 2 && err.include?("Fix:") }
code, _o, err = run(["--ref", "DND-1", "--bogus"], FakeNotion.new(page(nil)))
check("an unknown flag is a usage error") { code == 2 && err.include?("--bogus") }

if $failures.empty?
  puts "mark_in_progress_test: PASS (#{$checks} checks)"
  exit 0
end
warn "mark_in_progress_test: FAIL (#{$failures.size} of #{$checks})"
$failures.each { |f| warn "  - #{f}" }
warn "Fix: make scripts/mark-in-progress set Status and stamp 'In Progress at' in one PATCH, " \
     "only when the stamp is empty, and refuse every miss with exit 2/3 and a Fix: line."
exit 1
