# frozen_string_literal: true

# Deterministic suite for ai/lib/dispatch_trackers.rb and
# ai/lib/dispatch_trackers_overlay.rb (DND-1341): which Notion tracker holds a
# ticket's dispatch stamp, and how the work tracker is read from the private
# overlay. Every overlay here is a fixture root under a temp dir, reached
# through ATHENA_PRIVATE_ROOT or a fake HOME. All ids are synthetic.
# Run by ./self-test.sh, which harness-gate discovers.

require "fileutils"
require "json"
require "tmpdir"
require_relative "../../lib/dispatch_trackers"
require_relative "../../lib/dispatch_trackers_overlay"

$failures = []
$checks = 0

def check(desc)
  $checks += 1
  $failures << desc unless yield
rescue StandardError => e
  $failures << "#{desc} (raised #{e.class}: #{e.message})"
end

FAKE_DS = "0000aaaa-1111-2222-3333-444455556666"
GOOD = {
  "work" => {
    "tickets_data_source" => FAKE_DS,
    "ticket_prefix" => "ZQ",
    "in_progress_property" => "Synthetic stamp",
    "first_dispatch_from" => ["Todo", "Backlog", "Shaping"],
  },
}.freeze

def mk_root(dir, notion)
  FileUtils.mkdir_p(File.join(dir, "overlay"))
  File.chmod(0o700, dir)
  File.write(File.join(dir, "athena-overlay.json"), JSON.generate("kind" => "athena-private-overlay", "schema" => 1))
  File.write(File.join(dir, "overlay", "notion.json"), JSON.generate(notion)) if notion
  dir
end

# --- DOMAIN: the DND tracker is public and fixed.
dnd = DispatchTrackers::DND
check("the DND tracker's prefix is DND") { dnd.prefix == "DND" }
check("the DND tracker stamps 'In Progress at'") { dnd.property == "In Progress at" }
check("the DND tracker queries DND Tickets") { dnd.data_source == NextMissionNotion::TICKETS_DATA_SOURCE }
check("a DND first dispatch is a move from Todo or Backlog") { dnd.first_dispatch_from == %w[Todo Backlog] }
check("the DND tracker reads the notion-personal token") { dnd.token_file.end_with?("notion-personal-token") }

# --- DOMAIN: building the work tracker from overlay values.
vals = {
  data_source: FAKE_DS, prefix: "ZQ", property: "Synthetic stamp",
  first_dispatch_from: '["Todo","Backlog","Shaping"]',
}
r = DispatchTrackers.work_from(vals)
check("well-formed values build the work tracker") { r.tracker && r.reason.nil? }
check("it carries the overlay's prefix, property and data source") do
  r.tracker.prefix == "ZQ" && r.tracker.property == "Synthetic stamp" && r.tracker.data_source == FAKE_DS
end
check("it carries the overlay's first-dispatch statuses") { r.tracker.first_dispatch_from == %w[Todo Backlog Shaping] }
check("the work tracker reads the notion-work token") { r.tracker.token_file.end_with?("notion-api-token") }
check("its label names no work value") { !r.tracker.label.include?("ZQ") && !r.tracker.label.include?(FAKE_DS) }

bad = lambda do |override|
  DispatchTrackers.work_from(vals.merge(override))
end
check("a lower-case prefix is refused as a fault") do
  x = bad.call(prefix: "zq")
  x.tracker.nil? && x.fault && x.reason.include?(DispatchTrackers::WORK_KEYS[:prefix]) && x.reason.include?("Fix:")
end
check("the DND prefix is refused for the work tracker (it would shadow DND)") do
  x = bad.call(prefix: "DND")
  x.tracker.nil? && x.fault && x.reason.include?("DND")
end
check("a data source that is not a Notion id is refused") do
  x = bad.call(data_source: "not-an-id")
  x.tracker.nil? && x.fault && x.reason.include?(DispatchTrackers::WORK_KEYS[:data_source])
end
check("a first-dispatch list that is not a JSON array of names is refused") do
  a = bad.call(first_dispatch_from: '"Todo"')
  b = bad.call(first_dispatch_from: '["Todo", ""]')
  c = bad.call(first_dispatch_from: "{")
  [a, b, c].all? { |x| x.tracker.nil? && x.fault && x.reason.include?(DispatchTrackers::WORK_KEYS[:first_dispatch_from]) }
end
check("a first-dispatch list that includes In Progress is refused (every re-dispatch would restamp)") do
  x = bad.call(first_dispatch_from: '["Todo","In Progress"]')
  x.tracker.nil? && x.fault
end
check("a refusal never echoes the offending value") do
  x = bad.call(data_source: "leaky-value-123")
  !x.reason.include?("leaky-value-123")
end

# --- DOMAIN: routing a ticket ref to its tracker.
work_ok = -> { r }
check("a DND ref routes to DND without reading the overlay") do
  called = false
  t, why, = DispatchTrackers.for_ref("DND-12", work: -> { called = true; r })
  t == dnd && why.nil? && !called
end
check("a work-prefix ref routes to the work tracker") do
  t, why, = DispatchTrackers.for_ref("ZQ-12", work: work_ok)
  t == r.tracker && why.nil?
end
check("an unknown prefix is a usage refusal (exit 2) naming both prefixes") do
  t, why, code = DispatchTrackers.for_ref("XY-3", work: work_ok)
  t.nil? && code == 2 && why.include?("DND") && why.include?("ZQ") && why.include?("Fix:")
end
check("a malformed ref is a usage refusal") do
  t, _why, code = DispatchTrackers.for_ref("DND-0x1", work: work_ok)
  t.nil? && code == 2
end
check("a non-DND ref with no work tracker is exit 3 carrying the overlay line") do
  absent = DispatchTrackers::Resolution.new(tracker: nil, reason: "private-overlay: ABSENT: ... Fix: x", fault: false)
  t, why, code = DispatchTrackers.for_ref("ZQ-12", work: -> { absent })
  t.nil? && code == 3 && why.include?("ABSENT") && why.include?("ZQ-12")
end

# --- EFFECTS: reading the work tracker from a fixture overlay.
Dir.mktmpdir("dispatch-trackers") do |tmp|
  root = mk_root(File.join(tmp, "good"), GOOD)
  w = DispatchTrackers::Overlay.work(env: { "ATHENA_PRIVATE_ROOT" => root, "HOME" => tmp })
  check("a complete overlay yields the work tracker") { w.tracker && w.tracker.prefix == "ZQ" }
  check("its statuses come back as an array") { w.tracker.first_dispatch_from == %w[Todo Backlog Shaping] }

  home = File.join(tmp, "home")
  FileUtils.mkdir_p(home)
  a = DispatchTrackers::Overlay.work(env: { "HOME" => home })
  check("an absent overlay is not a fault, and names the probed path with the resolver's Fix") do
    a.tracker.nil? && !a.fault && a.reason.include?("ABSENT") && a.reason.include?(home) && a.reason.include?("Fix:")
  end

  partial = GOOD["work"].reject { |k, _| k == "ticket_prefix" }
  proot = mk_root(File.join(tmp, "partial"), "work" => partial)
  pr = DispatchTrackers::Overlay.work(env: { "ATHENA_PRIVATE_ROOT" => proot, "HOME" => tmp })
  check("a missing key is a fault naming the key (KEY_NOT_FOUND)") do
    pr.tracker.nil? && pr.fault && pr.reason.include?("KEY_NOT_FOUND") && pr.reason.include?(".work.ticket_prefix")
  end

  broken = File.join(tmp, "broken")
  FileUtils.mkdir_p(broken)
  File.chmod(0o700, broken)
  br = DispatchTrackers::Overlay.work(env: { "ATHENA_PRIVATE_ROOT" => broken, "HOME" => tmp })
  check("a malformed overlay is a fault (MALFORMED)") { br.tracker.nil? && br.fault && br.reason.include?("MALFORMED") }

  lower = mk_root(File.join(tmp, "lower"), "work" => GOOD["work"].merge("ticket_prefix" => "zq"))
  lr = DispatchTrackers::Overlay.work(env: { "ATHENA_PRIVATE_ROOT" => lower, "HOME" => tmp })
  check("an overlay value the domain refuses is a fault") { lr.tracker.nil? && lr.fault }
end

if $failures.empty?
  puts "dispatch_trackers_test: PASS (#{$checks} checks)"
  exit 0
end
warn "dispatch_trackers_test: FAIL (#{$failures.size} of #{$checks})"
$failures.each { |f| warn "  - #{f}" }
warn "Fix: make ai/lib/dispatch_trackers.rb route DND refs to DND Tickets and the overlay's work prefix to " \
     "the work tracker, and refuse every missing or malformed overlay value by key, with Fix:, never a guess."
exit 1
