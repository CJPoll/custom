# frozen_string_literal: true

# Deterministic suite for the next-mission selector (DND-985): the pure tier
# logic (ai/lib/next_mission.rb), the Notion read adapter behind a fake
# transport (ai/lib/next_mission_notion.rb), and the CLI end to end through
# --from-json fixtures (ai/bin/next-mission). No network, no git, no model.
# Run by ai/lib/test/next-mission/self-test.sh, which harness-gate discovers.

require "json"
require "open3"
require "tmpdir"
require_relative "../../next_mission"
require_relative "../../next_mission_notion"

$failures = []
$checks = 0

def check(desc)
  $checks += 1
  $failures << desc unless yield
rescue StandardError => e
  $failures << "#{desc} (raised #{e.class}: #{e.message})"
end

def raises?(klass, pattern = nil)
  yield
  false
rescue klass => e
  pattern.nil? || e.message.match?(pattern)
end

NM = NextMission

# t("DND-5", kind: "Bug", ...) -> a Ticket with sensible defaults.
def t(id, status: "Todo", kind: nil, severity: nil, path: "Off", area: "Product",
      deps: [], created: nil)
  n = id.split("-").last.to_i
  NM::Ticket.new(id: id, page_id: "page-#{id}", title: "title #{id}", status: status,
                 kind: kind, severity: severity, path: path, area: area,
                 depends_on: deps, created: created || format("2026-09-%02dT00:00:00Z", (n % 28) + 1))
end

def pick(tickets, external: [], **kw)
  NM.select(scope: tickets, external: external, **kw)
end

# ---------------------------------------------------------------- domain: tiers

check("tier 0: Path=Promoted wins over everything, even a CRITICAL vulnerability") do
  r = pick([t("DND-9", kind: "Vulnerability", severity: "CRITICAL", path: "Off"),
            t("DND-20", kind: "Docs", severity: "LOW", path: "Promoted")])
  r.pick.id == "DND-20" && r.tier == 0 && r.rule.start_with?("tier 0: owner-promoted")
end

check("tier 0: two promoted tickets are ordered by ID (the owner's order is not recorded)") do
  r = pick([t("DND-30", path: "Promoted", kind: "Bug"), t("DND-12", path: "Promoted", kind: "Docs")])
  r.pick.id == "DND-12"
end

check("tier 1: exploitable vulnerability (HIGH) beats a blocking bug and the critical path") do
  r = pick([t("DND-1", kind: "Feature", path: "Critical"),
            t("DND-2", kind: "Bug", severity: "CRITICAL", path: "Blocking"),
            t("DND-3", kind: "Vulnerability", severity: "HIGH", path: "Off")])
  r.pick.id == "DND-3" && r.tier == 1 && r.rule == "tier 1: exploitable vulnerability (HIGH)"
end

check("tier 1: CRITICAL vulnerability sorts before HIGH, whatever the age") do
  r = pick([t("DND-3", kind: "Vulnerability", severity: "HIGH"),
            t("DND-8", kind: "Vulnerability", severity: "CRITICAL")])
  r.pick.id == "DND-8" && r.rule == "tier 1: exploitable vulnerability (CRITICAL)"
end

check("tier 1 excludes a MEDIUM vulnerability; it is tier 4") do
  r = pick([t("DND-3", kind: "Vulnerability", severity: "MEDIUM")])
  r.pick.id == "DND-3" && r.tier == 4
end

check("tier 2: bug blocking functional requirements beats the critical path") do
  r = pick([t("DND-1", kind: "Feature", path: "Critical"),
            t("DND-7", kind: "Bug", severity: "MEDIUM", path: "Blocking")])
  r.pick.id == "DND-7" && r.tier == 2 &&
    r.rule == "tier 2: bug blocking functional requirements (Path=Blocking, MEDIUM)"
end

check("tier 3: position is the topological order of the UNFINISHED critical path, ties by ID") do
  # Unfinished Critical: DND-6 (started), DND-2 (depends on DND-6), DND-9.
  # Kahn, lowest ID first: 6, then 2 (freed by 6), then 9. DND-9 is the only
  # ready one, at #3 of 3.
  tickets = [t("DND-6", kind: "Feature", path: "Critical", status: "In Progress"),
             t("DND-2", kind: "Feature", path: "Critical", deps: ["DND-6"]),
             t("DND-9", kind: "Feature", path: "Critical")]
  r = pick(tickets)
  r.pick.id == "DND-9" && r.tier == 3 &&
    r.rule == "tier 3: critical path, dependency order #3 of 3 unfinished"
end

check("tier 3: a finished dependency's ID never moves the order") do
  # Same shape twice; only the Done dependency's ID differs (1 vs 8). With
  # terminal tickets counted, DND-8 would have pushed DND-2 behind DND-6.
  a = pick([t("DND-2", kind: "Feature", path: "Critical", deps: ["DND-1"]),
            t("DND-1", kind: "Feature", path: "Critical", status: "Done"),
            t("DND-6", kind: "Feature", path: "Critical")])
  b = pick([t("DND-2", kind: "Feature", path: "Critical", deps: ["DND-8"]),
            t("DND-8", kind: "Feature", path: "Critical", status: "Done"),
            t("DND-6", kind: "Feature", path: "Critical")])
  a.pick.id == "DND-2" && b.pick.id == "DND-2" &&
    b.rule == "tier 3: critical path, dependency order #1 of 2 unfinished"
end

check("tier 4: Severity first, then Kind order, then age") do
  r = pick([t("DND-1", kind: "Feature", path: "Critical", status: "Done"),
            t("DND-10", kind: "Docs", severity: "HIGH", created: "2026-09-02T00:00:00Z"),
            t("DND-11", kind: "Bug", severity: "HIGH", created: "2026-09-03T00:00:00Z"),
            t("DND-12", kind: "Bug", severity: "HIGH", created: "2026-09-01T00:00:00Z"),
            t("DND-13", kind: "Vulnerability", severity: "MEDIUM")])
  r.pick.id == "DND-12" && r.tier == 4 && r.rule.start_with?("tier 4: other improvements (HIGH, Bug")
end

check("tier 4: Kind order Vulnerability>Bug>Feature>Hardening>Test>Refactor>Ops>Docs, unset last") do
  kinds = %w[Docs Ops Refactor Test Hardening Feature Bug Vulnerability]
  order = kinds.each_with_index.map { |k, i| t("DND-#{100 + i}", kind: k, severity: "LOW", created: "2026-09-01T00:00:00Z") }
  order << t("DND-200", kind: nil, severity: "LOW", created: "2026-09-01T00:00:00Z")
  NM.tier4_order(order).map(&:kind) == (kinds.reverse + [nil])
end

check("tier 4: an unset Severity sorts after LOW") do
  r = pick([t("DND-50", kind: "Feature", severity: nil), t("DND-51", kind: "Feature", severity: "LOW")])
  r.pick.id == "DND-51"
end

# ----------------------------------------------------- domain: functional-first

check("functional-first: tier-4 non-Feature is held while a Feature is unfinished (even if started)") do
  r = pick([t("DND-1", kind: "Feature", path: "Critical", status: "In Progress"),
            t("DND-40", kind: "Bug", severity: "HIGH")])
  r.pick.nil? && r.emptied_by == :functional_first &&
    r.reason.include?("DND-1") && r.held_back == ["DND-40"]
end

check("functional-first: a tier-4 Feature is not held; it is picked over a held Bug") do
  r = pick([t("DND-1", kind: "Feature", path: "Critical", status: "In Progress"),
            t("DND-40", kind: "Bug", severity: "HIGH"),
            t("DND-41", kind: "Feature", path: "Off")])
  r.pick.id == "DND-41" && r.held_back == ["DND-40"]
end

check("functional-first: a Path=Critical non-Feature unfinished also holds tier 4") do
  r = pick([t("DND-1", kind: "Ops", path: "Critical", status: "In Progress"),
            t("DND-40", kind: "Docs", severity: "LOW")])
  r.pick.nil? && r.emptied_by == :functional_first
end

check("functional-first: lifted once every Feature/Critical ticket is Done, Cancelled or Won't Fix") do
  r = pick([t("DND-1", kind: "Feature", path: "Critical", status: "Done"),
            t("DND-2", kind: "Feature", status: "Cancelled"),
            t("DND-3", kind: "Feature", status: "Won't Fix"),
            t("DND-40", kind: "Bug", severity: "HIGH")])
  r.pick.id == "DND-40" && r.held_back.empty?
end

check("functional-first: a non-Bug Path=Blocking ticket is a blocker and is not held") do
  r = pick([t("DND-1", kind: "Feature", path: "Critical", status: "In Progress"),
            t("DND-40", kind: "Hardening", path: "Blocking", severity: "LOW")])
  r.pick.id == "DND-40" && r.tier == 4 && r.rule.include?("blocker")
end

check("functional-first: tiers 1-2 are never held") do
  r = pick([t("DND-1", kind: "Feature", path: "Critical", status: "In Progress"),
            t("DND-40", kind: "Vulnerability", severity: "HIGH")])
  r.pick.id == "DND-40"
end

# ------------------------------------------------------------- domain: filters

check("filter: terminal tickets (Done, Cancelled, Won't Fix) are never picked") do
  r = pick([t("DND-1", status: "Done", kind: "Bug"), t("DND-2", status: "Cancelled", kind: "Bug"),
            t("DND-3", status: "Won't Fix", kind: "Bug")])
  r.pick.nil? && r.emptied_by == :not_terminal
end

check("filter: a Flake is excluded (own lane)") do
  r = pick([t("DND-1", kind: "Flake", severity: "HIGH")])
  r.pick.nil? && r.emptied_by == :not_flake
end

check("filter: In Progress counts as started") do
  r = pick([t("DND-1", kind: "Bug", status: "In Progress")])
  r.pick.nil? && r.emptied_by == :not_started
end

check("filter: --started ids (state log) count as started even when Notion says Todo") do
  r = pick([t("DND-1", kind: "Bug"), t("DND-2", kind: "Bug")], started: ["DND-1"])
  r.pick.id == "DND-2"
end

check("filter: Needs Attention waits on the owner; Attention Given is eligible") do
  a = pick([t("DND-1", kind: "Bug", status: "Needs Attention")])
  b = pick([t("DND-1", kind: "Bug", status: "Attention Given")])
  a.pick.nil? && a.emptied_by == :not_waiting_on_owner && b.pick&.id == "DND-1"
end

check("filter: blocked by an unfinished dependency; unblocked by Done/Cancelled/Won't Fix") do
  blocked = pick([t("DND-1", kind: "Bug", deps: ["DND-2"]), t("DND-2", kind: "Bug", status: "In Progress")])
  freed = pick([t("DND-1", kind: "Bug", deps: %w[DND-2 DND-3 DND-4])],
               external: [t("DND-2", status: "Done"), t("DND-3", status: "Cancelled"),
                          t("DND-4", status: "Won't Fix")])
  blocked.pick.nil? && blocked.emptied_by == :unblocked && freed.pick&.id == "DND-1"
end

check("filter: a dependency OUTSIDE the scope still blocks (read from external)") do
  r = pick([t("DND-1", kind: "Bug", deps: ["DND-99"])], external: [t("DND-99", status: "Todo")])
  r.pick.nil? && r.emptied_by == :unblocked
end

check("filter: a dependency whose status was never read is an ERROR, never 'unblocked'") do
  raises?(NM::DataError, /DND-99/) { pick([t("DND-1", kind: "Bug", deps: ["DND-99"])]) }
end

check("filter: --harness-lane keeps only Area=Harness and Path=Off") do
  r = pick([t("DND-1", kind: "Bug", area: "Harness", path: "Blocking"),
            t("DND-2", kind: "Bug", area: "Product", path: "Off"),
            t("DND-3", kind: "Docs", area: "Harness", path: "Off")], harness_lane: true)
  r.pick.id == "DND-3"
end

# The harness lane (DND-987, P7): an Area=Harness, Path=Off (or unset), non-Feature
# ticket is the lane's. A feature admiral files it and never starts it, except
# at tier 1 (an exploitable vulnerability is never deferred to another queue).

check("lane: without --harness-lane, a tier-4 Area=Harness Path=Off ticket is the lane's, never picked") do
  r = pick([t("DND-3", kind: "Docs", severity: "LOW", area: "Harness", path: "Off"),
            t("DND-4", kind: "Docs", severity: "LOW", area: "Product", path: "Off")])
  r.pick&.id == "DND-4" && r.funnel.to_h[:not_lane] == 1 && r.left_to_lane == ["DND-3"]
end

check("lane: without --harness-lane, Path unset counts as Off (the lane's)") do
  r = pick([t("DND-3", kind: "Bug", severity: "HIGH", area: "Harness", path: nil)])
  r.pick.nil? && r.emptied_by == :not_lane && r.left_to_lane == ["DND-3"]
end

check("lane: a feature scope holding only lane tickets is emptied by :not_lane, naming them") do
  r = pick([t("DND-8", kind: "Bug", severity: "MEDIUM", area: "Harness"),
            t("DND-5", kind: "Docs", severity: "LOW", area: "Harness")])
  r.pick.nil? && r.emptied_by == :not_lane && r.left_to_lane == %w[DND-5 DND-8] &&
    r.reason.include?("DND-5, DND-8") && r.to_h[:left_to_lane] == %w[DND-5 DND-8]
end

check("lane: without --harness-lane, a tier-1 Harness vulnerability stays with the feature admiral") do
  r = pick([t("DND-3", kind: "Vulnerability", severity: "HIGH", area: "Harness", path: "Off")])
  r.pick&.id == "DND-3" && r.tier == 1 && r.left_to_lane.empty?
end

check("lane: Harness Path=Blocking, Critical and Promoted stay with the feature admiral") do
  %w[Blocking Critical Promoted].all? do |p|
    r = pick([t("DND-3", kind: "Bug", severity: "LOW", area: "Harness", path: p)])
    r.pick&.id == "DND-3" && r.left_to_lane.empty?
  end
end

check("lane: a Harness Kind=Feature with Path=Off is planned work, never the lane's") do
  feat = t("DND-3", kind: "Feature", area: "Harness", path: "Off")
  pick([feat]).pick&.id == "DND-3" && pick([feat], harness_lane: true).emptied_by == :harness_lane
end

check("lane: --harness-lane takes tier 1 before tier 4 in its own queue") do
  r = pick([t("DND-2", kind: "Bug", severity: "CRITICAL", area: "Harness"),
            t("DND-9", kind: "Vulnerability", severity: "HIGH", area: "Harness")], harness_lane: true)
  r.pick.id == "DND-9" && r.tier == 1
end

check("lane: --harness-lane with a lane-only scope is not held (no Critical/Feature in it)") do
  r = pick([t("DND-2", kind: "Docs", severity: "LOW", area: "Harness", path: nil)], harness_lane: true)
  r.pick&.id == "DND-2" && r.held_back.empty?
end

check("lane: --harness-lane over a scope with an unfinished Feature is held (why the lane scope is lane epics only)") do
  r = pick([t("DND-1", kind: "Feature", path: "Critical"),
            t("DND-2", kind: "Docs", severity: "LOW", area: "Harness")], harness_lane: true)
  r.pick.nil? && r.emptied_by == :functional_first && r.held_back == ["DND-2"]
end

check("lane: --harness-lane never reports tickets as left to the lane") do
  pick([t("DND-2", kind: "Docs", severity: "LOW", area: "Harness")], harness_lane: true).left_to_lane.empty?
end

# ---------------------------------------------------- domain: empty / miss cases

check("empty: an empty scope is emptied by :in_scope with count 0") do
  r = pick([])
  r.pick.nil? && r.emptied_by == :in_scope && r.funnel.first == [:in_scope, 0]
end

check("empty: the funnel records considered vs matched at every stage") do
  r = pick([t("DND-1", kind: "Bug", status: "Done"), t("DND-2", kind: "Bug", status: "In Progress"),
            t("DND-3", kind: "Bug")], started: ["DND-3"])
  f = r.funnel.to_h
  f[:in_scope] == 3 && f[:not_terminal] == 2 && f[:not_started] == 0 && r.emptied_by == :not_started
end

check("data: an unknown Status value is an error naming it (schema drift), not a skip") do
  raises?(NM::DataError, /Blocked-ish/) { pick([t("DND-1", status: "Blocked-ish")]) }
end

check("data: an unknown Kind/Severity/Path value is an error") do
  raises?(NM::DataError, /Kind/) { pick([t("DND-1", kind: "Finding")]) } &&
    raises?(NM::DataError, /Severity/) { pick([t("DND-1", severity: "SEVERE")]) } &&
    raises?(NM::DataError, /Path/) { pick([t("DND-1", path: "Maybe")]) }
end

check("data: a malformed ticket id is an error") do
  raises?(NM::DataError, /id/) { pick([t("DND-1").tap { |x| x.id = "nope" }]) }
end

check("data: a duplicate ticket in scope is an error") do
  raises?(NM::DataError, /DND-1/) { pick([t("DND-1"), t("DND-1")]) }
end

check("data: a self-dependency among unfinished tickets is an error naming the cycle, not 'blocked'") do
  raises?(NM::DataError, /cycle.*DND-1 -> DND-1/) { pick([t("DND-1", kind: "Bug", deps: ["DND-1"])]) }
end

check("data: a 2-cycle among unfinished tickets is an error naming both") do
  raises?(NM::DataError, /DND-1 -> DND-2 -> DND-1/) do
    pick([t("DND-1", kind: "Bug", deps: ["DND-2"]), t("DND-2", kind: "Bug", deps: ["DND-1"])])
  end
end

check("data: a cycle through a terminal ticket is not an error (the edge is satisfied)") do
  r = pick([t("DND-1", kind: "Bug", deps: ["DND-2"]), t("DND-2", kind: "Bug", status: "Done", deps: ["DND-1"])])
  r.pick&.id == "DND-1"
end

check("data: a scope ticket with no created time is an error (age orders tiers 1, 2, 4)") do
  raises?(NM::DataError, /created/) { pick([t("DND-1", kind: "Bug").tap { |x| x.created = nil }]) }
end

check("started: an id not in scope is reported in started_not_in_scope, not silently dropped") do
  r = pick([t("DND-1", kind: "Bug")], started: %w[DND-1 DND-77])
  r.started_not_in_scope == ["DND-77"] && r.to_h[:started_not_in_scope] == ["DND-77"]
end

check("functional-first: a Flake with Path=Critical does not hold tier 4 (Flake is its own lane)") do
  r = pick([t("DND-1", kind: "Flake", path: "Critical"), t("DND-40", kind: "Docs", severity: "LOW")])
  r.pick&.id == "DND-40"
end

# ---------------------------------------------------------------- Parked

check("parked: a Parked ticket is not terminal and not started; it is eligible") do
  r = pick([t("DND-1", kind: "Bug", status: "Parked")])
  r.pick&.id == "DND-1" && r.funnel.to_h[:not_terminal] == 1 && r.funnel.to_h[:not_started] == 1
end

check("parked: a Parked ticket listed in --started is started") do
  r = pick([t("DND-1", kind: "Bug", status: "Parked")], started: ["DND-1"])
  r.pick.nil? && r.emptied_by == :not_started
end

check("parked: resuming Parked beats a fresh ticket in the same tier, ahead of severity and age") do
  r = pick([t("DND-1", kind: "Bug", severity: "HIGH", created: "2026-09-01T00:00:00Z"),
            t("DND-9", kind: "Docs", severity: "LOW", status: "Parked", created: "2026-09-20T00:00:00Z")])
  r.pick.id == "DND-9" && r.tier == 4 && r.rule.end_with?("; resume Parked")
end

check("parked: resume-first applies inside tiers 1-3 too") do
  t1 = pick([t("DND-1", kind: "Vulnerability", severity: "CRITICAL"),
             t("DND-9", kind: "Vulnerability", severity: "HIGH", status: "Parked")])
  t3 = pick([t("DND-1", kind: "Feature", path: "Critical"),
             t("DND-9", kind: "Feature", path: "Critical", status: "Parked")])
  t1.pick.id == "DND-9" && t1.rule == "tier 1: exploitable vulnerability (HIGH); resume Parked" &&
    t3.pick.id == "DND-9" && t3.rule.start_with?("tier 3:") && t3.rule.end_with?("resume Parked")
end

check("parked: a Parked ticket never jumps a tier") do
  r = pick([t("DND-1", kind: "Vulnerability", severity: "HIGH"),
            t("DND-9", kind: "Bug", severity: "HIGH", status: "Parked")])
  r.pick.id == "DND-1" && r.tier == 1 && !r.rule.include?("Parked")
end

check("parked: a Parked Feature still holds tier-4 findings (it is unfinished)") do
  r = pick([t("DND-1", kind: "Feature", path: "Critical", status: "Parked"),
            t("DND-40", kind: "Docs", severity: "LOW")], started: ["DND-1"])
  r.pick.nil? && r.emptied_by == :functional_first
end

check("merge queue: In Merge Queue is a known status, counts as started, and is not terminal") do
  r = pick([t("DND-1", kind: "Bug", status: "In Merge Queue")])
  r.pick.nil? && r.emptied_by == :not_started && r.funnel.to_h[:not_terminal] == 1
end

check("merge queue: a ticket depending on an In Merge Queue ticket is still blocked") do
  r = pick([t("DND-1", kind: "Bug", status: "In Merge Queue"), t("DND-2", kind: "Bug", deps: ["DND-1"])])
  r.pick.nil? && r.emptied_by == :unblocked
end

# ------------------------------------------------------ stale In Progress

check("stale: In Merge Queue is active, so it is never reported stale") do
  r = pick([t("DND-1", kind: "Bug", status: "In Merge Queue"), t("DND-2", kind: "Bug", status: "In Progress")],
           started: [])
  r.stale_in_progress == ["DND-2"]
end

check("stale: an In Progress ticket missing from --started is listed; the pick is unchanged") do
  r = pick([t("DND-1", kind: "Bug", status: "In Progress"), t("DND-2", kind: "Bug", status: "In Progress"),
            t("DND-3", kind: "Bug")], started: ["DND-2"])
  r.stale_in_progress == ["DND-1"] && r.pick.id == "DND-3" && r.funnel.to_h[:not_started] == 1 &&
    r.to_h[:stale_in_progress] == ["DND-1"] && r.to_h[:stale_check].include?("checked 2")
end

check("stale: without --started the check is skipped (nil + a reason), never an empty list") do
  r = pick([t("DND-1", kind: "Bug", status: "In Progress"), t("DND-3", kind: "Bug")])
  r.stale_in_progress.nil? && r.to_h[:stale_in_progress].nil? && r.to_h[:stale_check].start_with?("skipped")
end

check("stale: Parked is never reported stale (the warning covers In Progress only)") do
  r = pick([t("DND-1", kind: "Bug", status: "Parked")], started: [])
  r.stale_in_progress == [] && r.in_progress.zero?
end

check("stale: the check also runs on an empty result") do
  r = pick([t("DND-1", kind: "Bug", status: "In Progress")], started: [])
  r.pick.nil? && r.stale_in_progress == ["DND-1"]
end

check("result: to_h carries pick, tier, rule, funnel, held_back") do
  h = pick([t("DND-3", kind: "Vulnerability", severity: "HIGH")]).to_h
  h[:ticket] == "DND-3" && h[:tier] == 1 && h[:funnel].is_a?(Array) && h.key?(:held_back)
end

# ------------------------------------------------- adapter: Notion (fake HTTP)

def page(id_num, status: "Todo", kind: nil, severity: nil, path: "Off", area: "Harness",
         deps: [], deps_more: false, created: "2026-09-27T21:15:00.000Z")
  sel = ->(v) { { "type" => "select", "select" => v && { "name" => v } } }
  { "object" => "page", "id" => "p#{id_num}", "created_time" => created,
    "properties" => {
      "ID" => { "id" => "idp", "type" => "unique_id", "unique_id" => { "prefix" => "DND", "number" => id_num } },
      "Name" => { "id" => "title", "type" => "title", "title" => [{ "plain_text" => "T#{id_num}" }] },
      "Status" => { "id" => "st", "type" => "status", "status" => { "name" => status } },
      "Kind" => sel.call(kind), "Severity" => sel.call(severity), "Path" => sel.call(path),
      "Area" => sel.call(area),
      "Depends On" => { "id" => "dep", "type" => "relation", "relation" => deps.map { |d| { "id" => d } },
                        "has_more" => deps_more }
    } }
end

# A fake transport: routes [method, path] to canned responses and records calls.
class FakeTransport
  attr_reader :calls

  EPIC_PAGE_PATH = "/v1/pages/3e8349da-87fb-8179-991c-cef934dafd95"

  # Every fake answers the epic-id verification with a live DND epic unless a
  # test overrides that route.
  def initialize(routes)
    epic = { "object" => "page", "id" => "3e8349da-87fb-8179-991c-cef934dafd95", "in_trash" => false,
             "parent" => { "type" => "data_source_id",
                           "data_source_id" => NextMissionNotion::EPICS_DATA_SOURCE } }
    @routes = { [:get, EPIC_PAGE_PATH] => epic }.merge(routes)
    @calls = []
  end

  def call(method, path, body = nil)
    @calls << [method, path, body]
    key = [method, path, body && body["start_cursor"]]
    resp = @routes.fetch(key) { @routes.fetch([method, path]) { raise NextMissionNotion::ReadError, "no route #{key.inspect}" } }
    raise resp if resp.is_a?(Exception)

    resp
  end
end

TDS = NextMissionNotion::TICKETS_DATA_SOURCE
EDS = NextMissionNotion::EPICS_DATA_SOURCE
EPIC = "3e8349da87fb8179991ccef934dafd95"

check("adapter: epic scope paginates the query and parses tickets") do
  tr = FakeTransport.new(
    [:post, "/v1/data_sources/#{TDS}/query", nil] => { "results" => [page(1, kind: "Feature", path: "Critical")],
                                                      "has_more" => true, "next_cursor" => "c2" },
    [:post, "/v1/data_sources/#{TDS}/query", "c2"] => { "results" => [page(2, kind: "Bug", deps: ["p1"])],
                                                       "has_more" => false }
  )
  s = NextMissionNotion.new(tr).load(epic: EPIC)
  query = tr.calls.find { |m, _, _| m == :post }
  s.scope.map(&:id) == %w[DND-1 DND-2] && s.scope.last.depends_on == ["DND-1"] &&
    s.scope.first.kind == "Feature" && s.external.empty? &&
    tr.calls.first[0..1] == [:get, FakeTransport::EPIC_PAGE_PATH] &&
    query[2]["filter"]["relation"]["contains"] == "3e8349da-87fb-8179-991c-cef934dafd95"
end

check("adapter: an epic id whose page is not in DND Epics is an error, never an empty epic") do
  tr = FakeTransport.new([:get, FakeTransport::EPIC_PAGE_PATH] =>
                           { "id" => "x", "parent" => { "type" => "data_source_id", "data_source_id" => TDS } })
  raises?(NextMissionNotion::ReadError, /not a DND epic/) { NextMissionNotion.new(tr).load(epic: EPIC) } &&
    tr.calls.none? { |m, _, _| m == :post }
end

check("adapter: an epic id that Notion cannot find (404) is an error") do
  tr = FakeTransport.new([:get, FakeTransport::EPIC_PAGE_PATH] => NextMissionNotion::ReadError.new("HTTP 404"))
  raises?(NextMissionNotion::ReadError, /404/) { NextMissionNotion.new(tr).load(epic: EPIC) }
end

check("adapter: a trashed out-of-scope dependency is an error naming it") do
  trashed = page(77, status: "Todo").merge("in_trash" => true)
  tr = FakeTransport.new(
    [:post, "/v1/data_sources/#{TDS}/query"] => { "results" => [page(2, deps: ["p77"])], "has_more" => false },
    [:get, "/v1/pages/p77"] => trashed
  )
  raises?(NextMissionNotion::ReadError, /DND-2.*trash/) { NextMissionNotion.new(tr).load(epic: EPIC) }
end

check("adapter: a page with a null unique_id is a ReadError, not a crash") do
  bad = page(1)
  bad["properties"]["ID"]["unique_id"] = nil
  tr = FakeTransport.new([:post, "/v1/data_sources/#{TDS}/query"] => { "results" => [bad], "has_more" => false })
  raises?(NextMissionNotion::ReadError, /malformed/) { NextMissionNotion.new(tr).load(epic: EPIC) }
end

check("adapter: HttpTransport turns a dropped connection (EOFError) into a ReadError") do
  tr = Class.new(NextMissionNotion::HttpTransport) do
    def request(*) = raise(EOFError, "end of file reached")
  end.new("unused-token")
  raises?(NextMissionNotion::ReadError, /EOFError/) { tr.call(:get, "/v1/pages/x") }
end

check("adapter: a dependency outside the scope is fetched by page id into external") do
  tr = FakeTransport.new(
    [:post, "/v1/data_sources/#{TDS}/query"] => { "results" => [page(2, deps: ["p77"])], "has_more" => false },
    [:get, "/v1/pages/p77"] => page(77, status: "Done")
  )
  s = NextMissionNotion.new(tr).load(epic: EPIC)
  s.external.map(&:id) == ["DND-77"] && s.scope.first.depends_on == ["DND-77"]
end

check("adapter: a truncated Depends On relation (has_more) is paged through the property endpoint") do
  tr = FakeTransport.new(
    [:post, "/v1/data_sources/#{TDS}/query"] => { "results" => [page(2, deps: ["p1"], deps_more: true), page(1)],
                                                  "has_more" => false },
    [:get, "/v1/pages/p2/properties/dep"] => { "results" => [{ "relation" => { "id" => "p1" } },
                                                              { "relation" => { "id" => "p3" } }],
                                               "has_more" => false },
    [:get, "/v1/pages/p3"] => page(3, status: "Todo")
  )
  s = NextMissionNotion.new(tr).load(epic: EPIC)
  s.scope.find { |x| x.id == "DND-2" }.depends_on == %w[DND-1 DND-3]
end

check("adapter: --tickets resolves each id by the unique_id filter") do
  tr = FakeTransport.new(
    [:post, "/v1/data_sources/#{TDS}/query"] => { "results" => [page(5)], "has_more" => false }
  )
  s = NextMissionNotion.new(tr).load(tickets: ["DND-5"])
  s.scope.map(&:id) == ["DND-5"] && tr.calls.first[2]["filter"]["or"].first["unique_id"]["equals"] == 5
end

check("adapter: a --tickets id that matches no page is an error, never a smaller scope") do
  tr = FakeTransport.new(
    [:post, "/v1/data_sources/#{TDS}/query"] => { "results" => [page(5)], "has_more" => false }
  )
  raises?(NextMissionNotion::ReadError, /DND-6/) { NextMissionNotion.new(tr).load(tickets: %w[DND-5 DND-6]) }
end

check("adapter: an epic NAME resolves through the Epics data source; zero matches is an error") do
  tr0 = FakeTransport.new([:post, "/v1/data_sources/#{EDS}/query"] => { "results" => [], "has_more" => false })
  miss = raises?(NextMissionNotion::ReadError, /no epic titled "Nope"/) { NextMissionNotion.new(tr0).load(epic: "Nope") }
  tr2 = FakeTransport.new([:post, "/v1/data_sources/#{EDS}/query"] => { "results" => [{ "id" => "a" }, { "id" => "b" }],
                                                                         "has_more" => false })
  amb = raises?(NextMissionNotion::ReadError, /2 epics/) { NextMissionNotion.new(tr2).load(epic: "Dup") }
  miss && amb
end

check("adapter: an HTTP/transport failure propagates as ReadError (never an empty scope)") do
  tr = FakeTransport.new([:post, "/v1/data_sources/#{TDS}/query"] => NextMissionNotion::ReadError.new("HTTP 502"))
  raises?(NextMissionNotion::ReadError, /502/) { NextMissionNotion.new(tr).load(epic: EPIC) }
end

check("adapter: a page missing a required property is a ReadError naming it") do
  bad = page(1)
  bad["properties"].delete("Kind")
  tr = FakeTransport.new([:post, "/v1/data_sources/#{TDS}/query"] => { "results" => [bad], "has_more" => false })
  raises?(NextMissionNotion::ReadError, /Kind/) { NextMissionNotion.new(tr).load(epic: EPIC) }
end

def epic_row(id, title)
  { "object" => "page", "id" => id,
    "properties" => { "Name" => { "id" => "title", "type" => "title", "title" => [{ "plain_text" => title }] } } }
end

LANE = NextMissionNotion::LANE_EPIC_PREFIX

check("adapter: lane_epics queries DND Epics by the title prefix, skips Done/Cancelled, and pages") do
  tr = FakeTransport.new(
    [:post, "/v1/data_sources/#{EDS}/query", nil] => { "results" => [epic_row("e1", "#{LANE}evals")],
                                                      "has_more" => true, "next_cursor" => "k2" },
    [:post, "/v1/data_sources/#{EDS}/query", "k2"] => { "results" => [epic_row("e2", "#{LANE}guards")],
                                                       "has_more" => false }
  )
  kept, dropped = NextMissionNotion.new(tr).lane_epics
  f = tr.calls.first[2]["filter"]["and"]
  kept == [{ id: "e1", title: "#{LANE}evals" }, { id: "e2", title: "#{LANE}guards" }] && dropped.empty? &&
    f.include?({ "property" => "Name", "title" => { "starts_with" => LANE } }) &&
    f.include?({ "property" => "Status", "select" => { "does_not_equal" => "Done" } }) &&
    f.include?({ "property" => "Status", "select" => { "does_not_equal" => "Cancelled" } })
end

check("adapter: lane_epics drops a hit whose title does not start with the exact prefix, and says so") do
  tr = FakeTransport.new([:post, "/v1/data_sources/#{EDS}/query"] =>
                           { "results" => [epic_row("e1", "harness LANE: evals")], "has_more" => false })
  kept, dropped = NextMissionNotion.new(tr).lane_epics
  kept.empty? && dropped == ["harness LANE: evals"]
end

check("adapter: lane_epics with no match is an empty list, not an error (the caller reports it)") do
  tr = FakeTransport.new([:post, "/v1/data_sources/#{EDS}/query"] => { "results" => [], "has_more" => false })
  NextMissionNotion.new(tr).lane_epics == [[], []]
end

check("adapter: a lane_epics HTTP failure is a ReadError, never an empty lane") do
  tr = FakeTransport.new([:post, "/v1/data_sources/#{EDS}/query"] => NextMissionNotion::ReadError.new("HTTP 503"))
  raises?(NextMissionNotion::ReadError, /503/) { NextMissionNotion.new(tr).lane_epics }
end

check("adapter: load(epics:) unions every epic's tickets; a ticket in two epics appears once") do
  q = "/v1/data_sources/#{TDS}/query"
  tr = FakeTransport.new([:post, q] => { "results" => [page(1), page(2)], "has_more" => false })
  s = NextMissionNotion.new(tr).load(epics: %w[e1 e2])
  posts = tr.calls.select { |m, _, _| m == :post }.map { |_, _, b| b["filter"]["relation"]["contains"] }
  s.scope.map(&:id) == %w[DND-1 DND-2] && posts == %w[e1 e2]
end

check("adapter: a malformed epic key (not 32 hex, not a name) with dashes in wrong places still resolves as a name") do
  tr = FakeTransport.new([:post, "/v1/data_sources/#{EDS}/query"] => { "results" => [], "has_more" => false })
  raises?(NextMissionNotion::ReadError, /no epic titled/) { NextMissionNotion.new(tr).load(epic: "3e8349da-zz") }
end

check("adapter: reads Notion in-process, never via a subprocess (the token stays off argv)") do
  src = File.read(File.expand_path("../../next_mission_notion.rb", __dir__))
  !src.match?(/Open3|\bsystem\(|\bspawn\(|%x|`|curl/)
end

# ----------------------------------------------------------- CLI (integration)

BIN = File.expand_path("../../../bin/next-mission", __dir__)
FIX = File.expand_path("fixtures", __dir__)

def cli(*args)
  out, err, st = Open3.capture3("/usr/bin/ruby", BIN, *args)
  [out, err, st.exitstatus]
end

check("cli: --help prints usage on stdout, exit 0, nothing on stderr") do
  out, err, code = cli("--help")
  code.zero? && out.include?("Usage") && out.include?("--from-json") && err.empty?
end

check("cli: picks from a fixture and prints one id plus the rule") do
  out, _err, code = cli("--from-json", File.join(FIX, "tiers.json"))
  code.zero? && out.lines.size == 1 && out.start_with?("DND-3\ttier 1: exploitable vulnerability (HIGH)")
end

check("cli: --json emits a parseable object with ticket and rule") do
  out, _err, code = cli("--from-json", File.join(FIX, "tiers.json"), "--json")
  h = JSON.parse(out)
  code.zero? && h["ticket"] == "DND-3" && h["tier"] == 1 && h["funnel"].is_a?(Array)
end

check("cli: --started removes a ticket and the next one is picked") do
  out, _err, code = cli("--from-json", File.join(FIX, "tiers.json"), "--started", "DND-3")
  code.zero? && out.start_with?("DND-7\ttier 2")
end

check("cli: functional-first hold empties the set -> exit 1 naming the hold and the unfinished features") do
  out, _err, code = cli("--from-json", File.join(FIX, "held.json"))
  code == 1 && out.include?("functional-first") && out.include?("DND-1") &&
    out.match?(/in scope: 2/) && out.include?("Fix:")
end

check("cli: empty result names the filter that emptied it with counts considered vs matched") do
  out, _err, code = cli("--from-json", File.join(FIX, "blocked.json"))
  code == 1 && out.include?("emptied by: unblocked") && out.match?(/not started: 1/) && out.match?(/unblocked: 0/)
end

check("cli: --harness-lane restricts the fixture") do
  out, _err, code = cli("--from-json", File.join(FIX, "lane.json"), "--harness-lane")
  code.zero? && out.start_with?("DND-41\ttier 4")
end

check("cli: unknown flag -> exit 2 with Fix:") do
  _out, err, code = cli("--scoep", "x")
  code == 2 && err.include?("Fix:")
end

check("cli: no scope and no fixture -> exit 2 with Fix:") do
  _out, err, code = cli
  code == 2 && err.include?("Fix:")
end

check("cli: --from-json together with --scope is refused (exit 2)") do
  _out, err, code = cli("--from-json", File.join(FIX, "tiers.json"), "--scope", "x")
  code == 2 && err.include?("Fix:")
end

check("cli: an unreadable fixture is exit 3 (a read failure), never empty") do
  _out, err, code = cli("--from-json", "/nonexistent/DND-985.json")
  code == 3 && err.include?("Fix:")
end

check("cli: a fixture with a dangling dependency is exit 3 naming it") do
  Dir.mktmpdir("DND-985") do |d|
    f = File.join(d, "dangling.json")
    File.write(f, JSON.dump("tickets" => [{ "id" => "DND-1", "status" => "Todo", "depends_on" => ["DND-99"],
                                            "created" => "2026-09-01T00:00:00Z" }]))
    _out, err, code = cli("--from-json", f)
    code == 3 && err.include?("DND-99") && err.include?("Fix:")
  end
end

def with_fixture(data)
  Dir.mktmpdir("DND-985") do |d|
    f = File.join(d, "fixture.json")
    File.write(f, data.is_a?(String) ? data : JSON.dump(data))
    yield f
  end
end

check("cli: a fixture whose tickets is null is exit 3, never an empty scope") do
  with_fixture("tickets" => nil) do |f|
    out, err, code = cli("--from-json", f)
    code == 3 && err.include?("Fix:") && out.empty?
  end
end

check("cli: an unexpected exception exits 3 with Fix:, never Ruby's default 1") do
  # Validated input cannot reach the catch-all, so preload a file (ruby -r)
  # that makes the selector raise something no specific rescue names.
  Dir.mktmpdir("DND-985") do |d|
    boom = File.join(d, "boom.rb")
    File.write(boom, <<~RUBY)
      require #{File.expand_path('../../next_mission', __dir__).inspect}
      module NextMission
        def self.select(**) = raise(ZeroDivisionError, "boom")
      end
    RUBY
    out, err, st = Open3.capture3("/usr/bin/ruby", "-r", boom, BIN, "--from-json", File.join(FIX, "tiers.json"))
    st.exitstatus == 3 && err.include?("ZeroDivisionError") && err.include?("Fix:") && out.empty?
  end
end

check("data: a created time that is not a string is an error") do
  raises?(NM::DataError, /created/) { pick([t("DND-1", kind: "Bug").tap { |x| x.created = {} }]) }
end

check("cli: --json with no candidate still carries a Fix: line (on stderr) and exit 1") do
  out, err, code = cli("--from-json", File.join(FIX, "held.json"), "--json")
  code == 1 && JSON.parse(out)["emptied_by"] == "functional_first" && err.include?("Fix:")
end

check("cli: a --started id not in scope is reported on stderr, and the pick is unaffected") do
  out, err, code = cli("--from-json", File.join(FIX, "tiers.json"), "--started", "DND-3,DND-777")
  code.zero? && out.start_with?("DND-7\t") && err.include?("DND-777")
end

check("cli: a --tickets id with a non-DND prefix is a usage error (exit 2), before any token read") do
  Dir.mktmpdir("DND-985") do |home|
    _out, err, st = Open3.capture3({ "HOME" => home }, "/usr/bin/ruby", BIN, "--tickets", "PT-5")
    st.exitstatus == 2 && err.include?("DND-NUMBER") && err.include?("Fix:")
  end
end

check("cli: stale In Progress is one stderr line naming its source; stdout stays one line") do
  with_fixture("tickets" => [
    { "id" => "DND-1", "status" => "In Progress", "kind" => "Bug", "created" => "2026-09-01T00:00:00Z" },
    { "id" => "DND-2", "status" => "In Progress", "kind" => "Bug", "created" => "2026-09-01T00:00:00Z" },
    { "id" => "DND-3", "status" => "Todo", "kind" => "Bug", "created" => "2026-09-01T00:00:00Z" }
  ]) do |f|
    out, err, code = cli("--from-json", f, "--started", "DND-2")
    code.zero? && out.lines.size == 1 && out.start_with?("DND-3\t") &&
      err.include?("stale In Progress (no live captain per --started): DND-1")
  end
end

check("cli: without --started the stale check says it was skipped and why") do
  _out, err, code = cli("--from-json", File.join(FIX, "tiers.json"))
  code.zero? && err.include?("stale In Progress check skipped: no --started given")
end

check("cli: --json carries stale_in_progress and stale_check") do
  out, _err, code = cli("--from-json", File.join(FIX, "held.json"), "--json", "--started", "DND-9")
  h = JSON.parse(out)
  code == 1 && h["stale_in_progress"] == ["DND-1"] && h["stale_check"].start_with?("checked 1")
end

check("cli: an unknown Status value (e.g. a new option) is exit 3 naming it, not 'not started'") do
  with_fixture("tickets" => [{ "id" => "DND-1", "status" => "Snoozed", "kind" => "Bug",
                               "created" => "2026-09-01T00:00:00Z" }]) do |f|
    _out, err, code = cli("--from-json", f)
    code == 3 && err.include?("Snoozed") && err.include?("Fix:")
  end
end

check("cli: a malformed --started id is exit 2") do
  _out, err, code = cli("--from-json", File.join(FIX, "tiers.json"), "--started", "985")
  code == 2 && err.include?("Fix:")
end

check("cli: a missing Notion token file is exit 3 with an owner-gated Fix:, before any network") do
  Dir.mktmpdir("DND-985") do |home|
    out, err, st = Open3.capture3({ "HOME" => home }, "/usr/bin/ruby", BIN, "--scope", EPIC)
    st.exitstatus == 3 && err.include?("notion-personal-token") && err.include?("Fix:") && out.empty?
  end
end

check("cli: --harness-lane over lane epics picks the lane ticket and names the lane scope on stderr") do
  out, err, code = cli("--from-json", File.join(FIX, "lane.json"), "--harness-lane")
  code.zero? && out.start_with?("DND-41\ttier 4") &&
    err.include?("harness lane scope: 1 open epic(s)") && err.include?("Harness lane: eval reliability")
end

check("cli: --harness-lane --json carries the lane epics") do
  out, _err, code = cli("--from-json", File.join(FIX, "lane.json"), "--harness-lane", "--json")
  code.zero? && JSON.parse(out)["lane_epics"].map { |e| e["title"] } == ["Harness lane: eval reliability"]
end

check("cli: zero lane epics is exit 1 naming the prefix searched, never a silent empty") do
  Dir.mktmpdir("DND-987") do |d|
    f = File.join(d, "no-lane.json")
    File.write(f, JSON.generate("lane_epics" => [], "tickets" => []))
    out, _err, code = cli("--from-json", f, "--harness-lane")
    code == 1 && out.include?("emptied by: lane_epics") && out.include?(NextMissionNotion::LANE_EPIC_PREFIX.inspect) &&
      out.include?("Fix:")
  end
end

check("cli: a lane_epics fixture without --harness-lane is a usage error") do
  _out, err, code = cli("--from-json", File.join(FIX, "lane.json"))
  code == 2 && err.include?("--harness-lane") && err.include?("Fix:")
end

check("cli: a feature admiral's pick notes the tickets left to the harness lane on stderr") do
  Dir.mktmpdir("DND-987") do |d|
    f = File.join(d, "mixed.json")
    File.write(f, JSON.generate("tickets" => [
      { "id" => "DND-2", "status" => "Todo", "kind" => "Bug", "severity" => "LOW", "path" => "Off",
        "area" => "Product", "created" => "2026-09-02T00:00:00Z" },
      { "id" => "DND-5", "status" => "Todo", "kind" => "Bug", "severity" => "HIGH", "path" => "Off",
        "area" => "Harness", "created" => "2026-09-05T00:00:00Z" }
    ]))
    out, err, code = cli("--from-json", f)
    code.zero? && out.start_with?("DND-2\t") && err.include?("left to the harness lane: DND-5")
  end
end

check("cli: --harness-lane with no scope reads the lane epics from Notion (exit 3 without a token, not 2)") do
  Dir.mktmpdir("DND-987") do |home|
    _out, err, st = Open3.capture3({ "HOME" => home }, "/usr/bin/ruby", BIN, "--harness-lane")
    st.exitstatus == 3 && err.include?("notion-personal-token")
  end
end

if $failures.empty?
  puts "next-mission self-test: #{$checks}/#{$checks} checks passed"
  exit 0
end
warn "next-mission self-test: #{$failures.size}/#{$checks} checks FAILED:"
$failures.each { |f| warn "  - #{f}" }
exit 1
