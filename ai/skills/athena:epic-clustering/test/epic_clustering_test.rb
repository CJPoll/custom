# frozen_string_literal: true

# Deterministic suite for athena:epic-clustering (DND-982): the pure rules
# (lib/epic_clustering.rb), the Notion read adapter behind a fake transport
# (lib/epic_clustering_notion.rb), and scripts/epic-clustering end to end on
# --from-json fixtures. No network, no git, no model, no Slack.
# Run by test/self-test.sh, which harness-gate discovers.

require "json"
require "open3"
require "tmpdir"
require_relative "../lib/epic_clustering"
require_relative "../lib/epic_clustering_notion"
require_relative "../lib/epic_clustering_view"

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

EC = EpicClustering
ECV = EpicClusteringView
HERE = __dir__
BIN = File.expand_path("../scripts/epic-clustering", HERE)
FIX = File.join(HERE, "fixtures")

# t("DND-5", kind: "Bug", ...) -> a Ticket with defaults; edges are ticket ids
# here and are turned into page ids ("page-DND-5") the way the adapter stores them.
def t(id, status: "Todo", kind: "Bug", severity: "LOW", security: "none", path: "Off", area: "Harness",
      epics: ["E1"], deps: [], blocks: [], created: nil, title: nil, body: nil)
  n = id.split("-").last.to_i
  EC::Ticket.new(id: id, page_id: "page-#{id}", title: title || "title #{id}", status: status, kind: kind,
                 severity: kind == "Feature" ? nil : severity, security: security, path: path, area: area,
                 epic_ids: epics, depends_on: deps.map { |d| "page-#{d}" }, blocks: blocks.map { |d| "page-#{d}" },
                 created: created || format("2026-09-%02dT00:00:00Z", (n % 28) + 1), body: body)
end

def epic(id, name = "Epic #{id}", project: "Proj", status: "In Progress")
  EC::Epic.new(page_id: id, name: name, status: status, project: project)
end

# ------------------------------------------------------------ never-movable

check("never-movable: Feature, Critical, Blocking, Promoted and a tier-1 vulnerability are the core") do
  ts = [t("DND-1", kind: "Feature", path: "Off"), t("DND-2", path: "Critical"), t("DND-3", path: "Blocking"),
        t("DND-4", path: "Promoted"), t("DND-5", kind: "Vulnerability", severity: "HIGH"),
        t("DND-6", kind: "Vulnerability", severity: "MEDIUM"), t("DND-7", kind: "Docs")]
  EC.never_movable(ts) == %w[DND-1 DND-2 DND-3 DND-4 DND-5]
end

check("never-movable: a Depends On or Blocks edge to a core ticket pins the ticket (one hop, either direction)") do
  ts = [t("DND-1", kind: "Feature"), t("DND-2", deps: ["DND-1"]), t("DND-3", blocks: ["DND-1"]),
        t("DND-4", deps: ["DND-2"]), t("DND-5")]
  EC.never_movable(ts) == %w[DND-1 DND-2 DND-3]
end

check("never-movable: a closed Feature still counts (status changes never shift the proof)") do
  EC.never_movable([t("DND-1", kind: "Feature", status: "Done"), t("DND-2", deps: ["DND-1"])]) == %w[DND-1 DND-2]
end

check("never-movable: an edge to a ticket outside the epic does not pin (the core is the epic's own)") do
  EC.never_movable([t("DND-2", deps: ["DND-99"])]).empty?
end

check("movable: open, not never-movable, not started (In Progress / In Merge Queue stay with their admiral)") do
  ts = [t("DND-1", kind: "Feature"), t("DND-2"), t("DND-3", status: "In Progress"),
        t("DND-4", status: "In Merge Queue"), t("DND-5", status: "Done"), t("DND-6", status: "Parked")]
  EC.movable(ts).map(&:id) == %w[DND-2 DND-6]
end

# ------------------------------------------------------------ proof

check("proof hit: equal before/after sets hold, and a zero set is printed as 0, not omitted") do
  before = EC.proof_snapshot([[epic("E1", "Fleet"), [t("DND-1", kind: "Feature"), t("DND-2")]],
                              [epic("E2", "Empty core"), [t("DND-3")]]])
  after = EC.proof_snapshot([[epic("E1", "Fleet"), [t("DND-1", kind: "Feature")]],
                             [epic("E2", "Empty core"), [t("DND-3"), t("DND-2", epics: ["E2"])]]])
  r = EC.compare_proof(before, after)
  lines = ECV.proof_lines(after)
  r.ok? && r.mismatches.empty? && lines.any? { |l| l.include?("Empty core") && l.include?("0 (none)") } &&
    lines.any? { |l| l.include?("Fleet") && l.include?("1: DND-1") }
end

check("proof mismatch: a never-movable ticket that left its epic fails, naming the missing id") do
  before = EC.proof_snapshot([[epic("E1", "Fleet"), [t("DND-1", kind: "Feature"), t("DND-2", path: "Critical")]]])
  after = EC.proof_snapshot([[epic("E1", "Fleet"), [t("DND-1", kind: "Feature")]]])
  r = EC.compare_proof(before, after)
  !r.ok? && r.mismatches.size == 1 && r.mismatches.first[:missing] == ["DND-2"] &&
    r.mismatches.first[:before_count] == 2 && r.mismatches.first[:still_there] == 1
end

check("proof: a ticket moved into the epic that holds its dependency joins that set; reported, not failed") do
  # DND-5 depends on E2's Feature DND-2, so it is movable out of E1 and pinned once in E2.
  before = EC.proof_snapshot([[epic("E1"), [t("DND-1", kind: "Feature"), t("DND-5", deps: ["DND-2"])]],
                              [epic("E2"), [t("DND-2", kind: "Feature", epics: ["E2"])]]])
  after = EC.proof_snapshot([[epic("E1"), [t("DND-1", kind: "Feature")]],
                             [epic("E2"), [t("DND-2", kind: "Feature", epics: ["E2"]), t("DND-5", deps: ["DND-2"], epics: ["E2"])]]])
  r = EC.compare_proof(before, after)
  before["E1"]["ids"] == ["DND-1"] && r.ok? && r.joined == { "E2" => ["DND-5"] }
end

check("proof mismatch: a ticket pinned by an edge that leaves its epic fails like a core ticket") do
  before = EC.proof_snapshot([[epic("E1"), [t("DND-1", kind: "Feature"), t("DND-5", deps: ["DND-1"])]]])
  after = EC.proof_snapshot([[epic("E1"), [t("DND-1", kind: "Feature")]]])
  r = EC.compare_proof(before, after)
  !r.ok? && r.mismatches.first[:missing] == ["DND-5"] && r.mismatches.first[:still_there] == 1
end

check("lane: every movable Area=Harness, Path=Off ticket outside a 'Harness lane: ' epic is lane-bound, singletons too") do
  pairs = [[epic("E1", "Fleet"), [t("DND-1", kind: "Feature"), t("DND-2"), t("DND-3", area: "Product"),
                                  t("DND-4", path: "Blocking")]],
           [epic("E9", "Harness lane: evals"), [t("DND-7", epics: ["E9"])]]]
  EC.lane_bound(pairs) == ["DND-2"]
end

check("proof miss: an epic in the before snapshot that the after read did not return is a mismatch, never a pass") do
  before = EC.proof_snapshot([[epic("E1"), [t("DND-1", kind: "Feature")]], [epic("E2"), []]])
  after = EC.proof_snapshot([[epic("E1"), [t("DND-1", kind: "Feature")]]])
  r = EC.compare_proof(before, after)
  !r.ok? && r.mismatches.any? { |m| m[:epic] == "E2" && m[:reason].include?("not read") }
end

check("proof miss: an empty before snapshot is refused (nothing was proven)") do
  raises?(EC::DataError, /no epics/) { EC.compare_proof(EC.proof_snapshot([]), EC.proof_snapshot([])) }
end

# ------------------------------------------------------------ trigger

check("trigger: trips when open Path=Off exceeds open on-path; closed tickets are not counted") do
  ts = [t("DND-1", path: "Critical", kind: "Feature"), t("DND-2"), t("DND-3"),
        t("DND-4", status: "Done"), t("DND-5", status: "Done", path: "Critical")]
  tr = EC.trigger(ts)
  tr[:open_off] == 2 && tr[:open_on_path] == 1 && tr[:trips]
end

check("trigger: equal counts do not trip") do
  tr = EC.trigger([t("DND-1", path: "Blocking"), t("DND-2")])
  !tr[:trips] && tr[:open_off] == 1 && tr[:open_on_path] == 1
end

# ------------------------------------------------------------ C3 duplicate candidates

check("C3 pair: same Area, near-identical titles -> one candidate, the older ticket kept") do
  a = t("DND-40", title: "critic-review verdict receipt lost on rebase of the head", created: "2026-09-10T00:00:00Z")
  b = t("DND-71", title: "critic-review verdict receipt lost after rebase of head", created: "2026-09-20T00:00:00Z")
  c = t("DND-72", title: "slack digest renders badly on mobile", created: "2026-09-21T00:00:00Z")
  pairs = EC.duplicate_candidates([b, c, a])
  pairs.size == 1 && pairs.first[:keep] == "DND-40" && pairs.first[:duplicate] == "DND-71" && pairs.first[:score] >= 0.5
end

check("C3: titles sharing fewer than 3 tokens never pair, however high the ratio") do
  EC.duplicate_candidates([t("DND-2", title: "ticket two"), t("DND-3", title: "ticket three")]).empty?
end

check("C3: similar titles in different Areas are not paired") do
  a = t("DND-40", title: "critic-review verdict receipt lost on rebase", area: "Harness")
  b = t("DND-41", title: "critic-review verdict receipt lost on rebase", area: "Product")
  EC.duplicate_candidates([a, b]).empty?
end

# ------------------------------------------------------------ hygiene

check("status hygiene: In Progress with no live captain is flagged; In Merge Queue is exempt") do
  ts = [t("DND-1", status: "In Progress"), t("DND-2", status: "In Progress"), t("DND-3", status: "In Merge Queue")]
  h = EC.status_hygiene(ts, started: ["DND-2"])
  h[:checked] == 2 && h[:stale].map { |x| x[:id] } == ["DND-1"]
end

check("status hygiene: no --started list means the check is skipped and says so (never an empty list)") do
  h = EC.status_hygiene([t("DND-1", status: "In Progress")], started: nil)
  h[:stale].nil? && h[:skipped].include?("--started")
end

check("ticket hygiene: a thin body is flagged for each missing question; Features are exempt") do
  thin = t("DND-1", kind: "Bug", body: "Something is off with the gate.")
  good = t("DND-2", kind: "Bug", body: "## Problem\nThe gate reads a stale receipt and passes a head it never judged, " \
                                        "so an unreviewed change can merge.\n## Repro\n```\nai/bin/critic-review --head x\n```\n" \
                                        "## Affected code\n`ai/bin/critic-review:120`\n")
  feat = t("DND-3", kind: "Feature", body: "")
  h = EC.ticket_hygiene([thin, good, feat])
  h[:scanned] == 2 && h[:flagged].size == 1 && h[:flagged].first[:id] == "DND-1" &&
    h[:flagged].first[:missing] == ["problem", "repro/exploit path", "affected code"]
end

check("ticket hygiene: a repro is owed only by Bug/Vulnerability/Flake or Security set, not by a Refactor") do
  h = EC.ticket_hygiene([t("DND-1", kind: "Refactor", body: "Tidy it."),
                         t("DND-2", kind: "Hardening", security: "pre-existing", body: "Tidy it.")])
  h[:flagged].map { |x| [x[:id], x[:missing]] } ==
    [["DND-1", ["problem", "affected code"]], ["DND-2", ["problem", "repro/exploit path", "affected code"]]]
end

check("ticket hygiene: an unread body (nil) is counted as unread, never as a pass") do
  h = EC.ticket_hygiene([t("DND-1", kind: "Bug", body: nil)])
  h[:unread_reasons] = { "HTTP 429" => 1 }
  line = ECV.hygiene_lines(h).first
  h[:scanned].zero? && h[:unread] == ["DND-1"] && h[:flagged].empty? &&
    line.include?("1 UNREAD (not judged): DND-1") && line.include?("1x HTTP 429")
end

# ------------------------------------------------------------ digest

NOW = "2026-09-28T13:00:00Z"

def digest_fixture(extra = [])
  epics = [epic("E1", "Fleet", project: "Athena"), epic("E2", "Harness rules", project: "Harness")]
  ts = [
    t("DND-1", kind: "Feature", path: "Critical", epics: ["E1"], status: "Needs Attention"),
    t("DND-2", kind: "Bug", severity: "MEDIUM", epics: ["E1"]),
    t("DND-3", kind: "Docs", severity: "LOW", epics: ["E2"], created: "2026-09-25T00:00:00Z"),
    t("DND-4", kind: "Refactor", severity: "LOW", epics: [], area: "Product", created: "2026-09-26T00:00:00Z"),
    t("DND-5", kind: "Vulnerability", severity: "HIGH", security: "pre-existing", epics: ["E2"]),
    t("DND-6", kind: "Flake", severity: "LOW", epics: ["E2"])
  ] + extra
  [epics, ts]
end

check("digest: tier-4 queue by project and Area with Kind x Severity counts; Flake excluded") do
  epics, ts = digest_fixture
  d = EC.build_digest(tickets: ts, epics: epics, now: NOW)
  q = d[:tier4_queue]
  q.map { |g| [g[:project], g[:area], g[:count]] }.sort ==
    [["(no epic)", "Product", 1], ["Athena", "Harness", 1], ["Harness", "Harness", 1]].sort &&
    q.find { |g| g[:project] == "Athena" }[:counts] == { "Bug" => { "MEDIUM" => 1 } }
end

check("digest: next 10 follow next-mission's tier-4 order (Severity, then Kind, then age)") do
  epics, ts = digest_fixture
  d = EC.build_digest(tickets: ts, epics: epics, now: NOW)
  d[:next].map { |x| x[:id] } == %w[DND-2 DND-4 DND-3]
end

check("digest: why tier 4 waits names open tier 1-3 counts, owner-gated holders and functional-first holds") do
  epics, ts = digest_fixture
  d = EC.build_digest(tickets: ts, epics: epics, now: NOW)
  m = d[:moving]
  m[:tier_counts] == { 1 => 1, 2 => 0, 3 => 1 } && m[:owner_gated].map { |x| x[:id] } == ["DND-1"] &&
    m[:held_by_functional_first].map { |x| x[:epic] } == ["Fleet"]
end

check("digest: a Feature off the critical path is never queued as tier 4; it is named as a planning gap") do
  epics, ts = digest_fixture([t("DND-30", kind: "Feature", path: "Off", epics: ["E2"])])
  d = EC.build_digest(tickets: ts, epics: epics, now: NOW)
  d[:next].none? { |x| x[:id] == "DND-30" } && d[:features_off_path] == ["DND-30"] &&
    ECV.digest_text(d).include?("Features with no Path=Critical (not queued here; a planning gap): 1: DND-30")
end

check("digest without won't-fix candidates prints 'None today'") do
  epics, ts = digest_fixture
  d = EC.build_digest(tickets: ts, epics: epics, now: NOW)
  d[:wont_fix].empty? && ECV.digest_text(d).include?("Won't-fix candidates: None today")
end

check("digest with won't-fix candidates lists old LOW tier-4 tickets, one line and reason each, oldest first") do
  old = [t("DND-8", kind: "Docs", severity: "LOW", epics: ["E2"], created: "2026-09-01T00:00:00Z"),
         t("DND-9", kind: "Refactor", severity: "LOW", epics: ["E2"], created: "2026-08-30T00:00:00Z"),
         t("DND-10", kind: "Vulnerability", severity: "LOW", epics: ["E2"], created: "2026-08-01T00:00:00Z"),
         t("DND-11", kind: "Test", severity: "LOW", epics: ["E2"], created: "2026-08-01T00:00:00Z", blocks: ["DND-9"])]
  epics, ts = digest_fixture(old)
  d = EC.build_digest(tickets: ts, epics: epics, now: NOW)
  text = ECV.digest_text(d)
  d[:wont_fix].map { |x| x[:id] } == %w[DND-9 DND-8] && d[:wont_fix].all? { |x| x[:reason].include?("open") } &&
    !text.include?("None today")
end

check("digest: pass summary prints each part, zero as 'none', and a missing summary as 'not given'") do
  epics, ts = digest_fixture
  given = ECV.digest_text(EC.build_digest(tickets: ts, epics: epics, now: NOW,
                                         pass_summary: { "moved" => [{ "id" => "DND-3", "from" => "Fleet", "to" => "Evals" }],
                                                         "merged" => [], "closed" => [],
                                                         "wont_fix" => [{ "id" => "DND-7", "reason" => "stale LOW" }] }))
  missing = ECV.digest_text(EC.build_digest(tickets: ts, epics: epics, now: NOW))
  given.include?("Moved: DND-3 Fleet -> Evals") && given.include?("Merged (C3): none") &&
    given.include?("Closed as fixed (C4): none") &&
    given.include?("Closed as Won't Fix (veto by its notice): DND-7 (stale LOW)") &&
    missing.include?("Pass summary:\n  not given (no --pass-summary")
end

check("digest blocks: valid Block Kit shape, names the sending session, no buttons, under 50 blocks") do
  epics, ts = digest_fixture
  b = ECV.digest_blocks(EC.build_digest(tickets: ts, epics: epics, now: NOW), session: "harness session -> architect")
  b.is_a?(Array) && b.size <= 50 && b.none? { |x| x["type"] == "actions" } &&
    b.first.dig("text", "text").include?("harness session -&gt; architect") &&
    b.all? { |x| x["type"] != "section" || x.dig("text", "text").length <= 3000 }
end

check("digest: a ticket whose epic was not read is a data error, never a silent '(no epic)'") do
  epics, ts = digest_fixture([t("DND-20", epics: ["E-missing"])])
  raises?(EC::DataError, /E-missing/) { EC.build_digest(tickets: ts, epics: epics, now: NOW) }
end

# ------------------------------------------------------------ won't-fix notice

check("notice: won't-fix reports the close, with background, why, options and a veto; 'Keep closed' is the primary default") do
  r = ECV.wont_fix_notice(ticket: "DND-9", title: "Tidy the README", background: "Open 28 days at LOW.",
                          why: "Closing it shrinks the epic.", session: "harness session")
  btns = r[:blocks].select { |x| x["type"] == "actions" }.flat_map { |x| x["elements"] }
  prim = btns.select { |x| x["style"] == "primary" }
  text = r[:blocks].map { |x| x.dig("text", "text").to_s }.join("\n")
  prim.size == 1 && prim.first.dig("text", "text") == "Keep closed (recommended)" &&
    btns.map { |x| x["value"] } == ["wontfix:keep:DND-9", "wontfix:reopen:DND-9"] &&
    btns.none? { |x| x.dig("text", "text").start_with?("Your call") } &&
    text.include?("Closed DND-9 as Won't Fix") && text.include?("Silence keeps it closed") &&
    %w[Background Why Options Recommendation].all? { |w| text.include?(w) } && r[:text].include?("DND-9")
end

check("notice: a missing background or why is refused, not sent thin; a bad ticket id is refused") do
  raises?(EC::DataError, /background/) do
    ECV.wont_fix_notice(ticket: "DND-9", title: "x", background: " ", why: "y", session: "s")
  end &&
    raises?(EC::DataError, /not an id/) do
      ECV.wont_fix_notice(ticket: "nine", title: "x", background: "b", why: "y", session: "s")
    end
end

# ------------------------------------------------------------ adapter (fake transport)

class FakeTransport
  attr_reader :calls

  def initialize(routes)
    @routes = routes
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
EPIC_ID = "3e8349da-87fb-8179-991c-cef934dafd95"

def sel(name) = { "type" => "select", "select" => name && { "name" => name } }
def rel(ids) = { "id" => "r", "type" => "relation", "relation" => ids.map { |i| { "id" => i } }, "has_more" => false }

def tpage(n, kind: "Bug", path: "Off", status: "Todo", epics: [EPIC_ID], deps: [], blocks: [])
  { "id" => "p#{n}", "created_time" => "2026-09-0#{n}T00:00:00Z",
    "properties" => {
      "ID" => { "type" => "unique_id", "unique_id" => { "prefix" => "DND", "number" => n } },
      "Name" => { "type" => "title", "title" => [{ "plain_text" => "t#{n}" }] },
      "Status" => { "type" => "status", "status" => { "name" => status } },
      "Kind" => sel(kind), "Severity" => sel(kind == "Feature" ? nil : "LOW"), "Security" => sel("none"),
      "Path" => sel(path), "Area" => sel("Harness"),
      "Epic" => rel(epics), "Depends On" => rel(deps), "Blocks" => rel(blocks)
    } }
end

def epage(id, name, status: "In Progress", project: [])
  { "id" => id, "in_trash" => false, "parent" => { "type" => "data_source_id", "data_source_id" => EDS },
    "properties" => { "Name" => { "type" => "title", "title" => [{ "plain_text" => name }] },
                      "Status" => { "type" => "select", "select" => { "name" => status } },
                      "Project" => rel(project) } }
end

check("adapter: epic tickets are read with edges as page ids and every property the rules need") do
  tr = FakeTransport.new(
    [:get, "/v1/pages/#{EPIC_ID}"] => epage(EPIC_ID, "Harness: scope-growth rules"),
    [:post, "/v1/data_sources/#{TDS}/query"] => { "results" => [tpage(1, kind: "Feature", path: "Critical"),
                                                                tpage(2, deps: ["p1"])], "has_more" => false }
  )
  e, ts = EpicClusteringNotion.new(tr).epic_with_tickets(EPIC_ID)
  e.name == "Harness: scope-growth rules" && ts.map(&:id) == %w[DND-1 DND-2] && ts.last.depends_on == ["p1"] &&
    EC.never_movable(ts) == %w[DND-1 DND-2]
end

check("adapter: an epic title that matches no epic is a read error, never an empty epic") do
  tr = FakeTransport.new([:post, "/v1/data_sources/#{EDS}/query"] => { "results" => [], "has_more" => false })
  raises?(NextMissionNotion::ReadError, /no epic titled/) { EpicClusteringNotion.new(tr).epic_with_tickets("Nope") }
end

check("adapter: a ticket page missing the Security property is a read error naming it") do
  bad = tpage(1)
  bad["properties"].delete("Security")
  tr = FakeTransport.new(
    [:get, "/v1/pages/#{EPIC_ID}"] => epage(EPIC_ID, "E"),
    [:post, "/v1/data_sources/#{TDS}/query"] => { "results" => [bad], "has_more" => false }
  )
  raises?(NextMissionNotion::ReadError, /Security/) { EpicClusteringNotion.new(tr).epic_with_tickets(EPIC_ID) }
end

check("adapter: open epics resolve their project names; an epic query HTTP failure raises") do
  tr = FakeTransport.new(
    [:post, "/v1/data_sources/#{EDS}/query"] => { "results" => [epage("e1", "A", project: ["pr1"])], "has_more" => false },
    [:get, "/v1/pages/pr1"] => { "id" => "pr1", "properties" => { "Name" => { "type" => "title", "title" => [{ "plain_text" => "Athena" }] } } }
  )
  eps = EpicClusteringNotion.new(tr).open_epics
  fail_tr = FakeTransport.new([:post, "/v1/data_sources/#{EDS}/query"] => NextMissionNotion::ReadError.new("HTTP 500"))
  eps.map { |x| [x.name, x.project] } == [["A", "Athena"]] &&
    raises?(NextMissionNotion::ReadError, /500/) { EpicClusteringNotion.new(fail_tr).open_epics }
end

check("adapter: the epic query pages through has_more/next_cursor; a has_more with no cursor is an error") do
  tr = FakeTransport.new(
    [:post, "/v1/data_sources/#{EDS}/query", nil] => { "results" => [epage("e1", "A")], "has_more" => true, "next_cursor" => "c2" },
    [:post, "/v1/data_sources/#{EDS}/query", "c2"] => { "results" => [epage("e2", "B")], "has_more" => false }
  )
  bad = FakeTransport.new([:post, "/v1/data_sources/#{EDS}/query"] => { "results" => [], "has_more" => true })
  EpicClusteringNotion.new(tr).all_epics.map(&:name) == %w[A B] &&
    raises?(NextMissionNotion::ReadError, /next_cursor/) { EpicClusteringNotion.new(bad).all_epics }
end

check("adapter: a body read that comes back truncated is an error, never a short body") do
  tr = FakeTransport.new([:get, "/v1/pages/p1/markdown"] => { "markdown" => "## Problem", "truncated" => true })
  raises?(NextMissionNotion::ReadError, /truncated/) { EpicClusteringNotion.new(tr).body("p1") }
end

# ------------------------------------------------------------ CLI end to end

def run(*args)
  out, err, st = Open3.capture3(BIN, *args)
  [out, err, st.exitstatus]
end

check("cli: --help prints usage on stdout, exit 0, and nothing else") do
  out, err, code = run("--help")
  code.zero? && out.include?("Usage: epic-clustering") && err.empty?
end

check("cli: an unknown flag is a usage error with Fix:, exit 2") do
  _, err, code = run("read", "--bogus")
  code == 2 && err.include?("Fix:")
end

check("cli: read prints the trigger, the never-movable set and the movable clusters from a fixture") do
  out, _, code = run("read", "--from-json", File.join(FIX, "pass.json"), "--all-open-epics")
  code.zero? && out.include?("never-movable 3: DND-1, DND-2, DND-3") && out.include?("trigger: open Path=Off 4 > on-path 2: TRIPS") &&
    out.include?("Harness / Bug") && out.include?("C3 candidates")
end

check("cli: proof --save then --against the same fixture holds (exit 0)") do
  Dir.mktmpdir do |d|
    snap = File.join(d, "DND-982-proof.json")
    _, _, c1 = run("proof", "--from-json", File.join(FIX, "pass.json"), "--all-open-epics", "--save", snap)
    out, _, c2 = run("proof", "--from-json", File.join(FIX, "pass.json"), "--against", snap)
    c1.zero? && c2.zero? && out.include?("proof holds")
  end
end

check("cli: proof --against a fixture where a Critical ticket moved out fails loudly, exit 4, with Fix:") do
  Dir.mktmpdir do |d|
    snap = File.join(d, "DND-982-proof.json")
    run("proof", "--from-json", File.join(FIX, "pass.json"), "--all-open-epics", "--save", snap)
    out, err, code = run("proof", "--from-json", File.join(FIX, "pass-moved-critical.json"), "--against", snap)
    code == 4 && (out + err).include?("missing: DND-2") && err.include?("Fix:")
  end
end

check("cli: proof --against a missing snapshot is exit 3 (could not measure), never a pass") do
  _, err, code = run("proof", "--from-json", File.join(FIX, "pass.json"), "--against", "/nonexistent/DND-982.json")
  code == 3 && err.include?("Fix:")
end

check("cli: digest from a fixture prints the draft banner, won't-fix candidates and the skipped stale check") do
  out, _, code = run("digest", "--from-json", File.join(FIX, "pass.json"), "--now", NOW)
  code.zero? && out.include?("DRAFT") && out.include?("Won't-fix candidates:") &&
    out.include?("stale In Progress check skipped")
end

check("cli: notice writes Block Kit JSON to --blocks-out and prints the fallback text; request is gone") do
  Dir.mktmpdir do |d|
    f = File.join(d, "DND-982-notice.json")
    out, _, code = run("notice", "--ticket", "DND-9", "--title", "Tidy", "--background",
                       "Open 28 days.", "--why", "Shrinks the epic.", "--blocks-out", f)
    _, gone_err, gone = run("request", "--ticket", "DND-9")
    code.zero? && out.include?("DND-9") && out.include?("top-level session") &&
      JSON.parse(File.read(f)).is_a?(Array) && gone == 2 && gone_err.include?("Fix:")
  end
end

check("cli: a malformed --started id is a usage error (exit 2, Fix:), never a list that flags every ticket stale") do
  _, err, code = run("digest", "--from-json", File.join(FIX, "pass.json"), "--started", "dnd-1,garbage", "--no-bodies")
  code == 2 && err.include?("malformed") && err.include?("Fix:")
end

check("cli: digest --started flags an In Progress ticket with no live captain and notes a --started id with no open ticket") do
  out, _, code = run("digest", "--from-json", File.join(FIX, "pass.json"), "--started", "DND-99", "--no-bodies", "--now", NOW)
  code.zero? && out.include?("stale In Progress (no live captain per --started): 1 of 1") && out.include?("DND-7 ticket 7") &&
    out.include?("naming no open ticket (typo?): DND-99") && out.include?("ticket bodies not scanned")
end

check("cli: a malformed snapshot entry is exit 3 naming it, never a crash or a pass") do
  Dir.mktmpdir do |d|
    snap = File.join(d, "DND-982-bad.json")
    File.write(snap, JSON.generate("epics" => { "E1" => { "name" => "Fleet", "count" => 3, "ids" => ["DND-1"] } }))
    _, err, code = run("proof", "--from-json", File.join(FIX, "pass.json"), "--against", snap)
    code == 3 && err.include?("entry \"E1\"") && err.include?("Fix:")
  end
end

check("cli: proof --against a snapshot epic that cannot be read again is exit 4 (a mismatch), never a pass") do
  Dir.mktmpdir do |d|
    snap = File.join(d, "DND-982-gone.json")
    File.write(snap, JSON.generate("epics" => { "E-gone" => { "name" => "Gone", "count" => 1, "ids" => ["DND-1"] } }))
    _, err, code = run("proof", "--from-json", File.join(FIX, "pass.json"), "--against", snap)
    code == 4 && err.include?("could not read epic E-gone again") && err.include?("PROOF MISMATCH Gone")
  end
end

check("cli: proof holds prints the before count and the count still there, computed separately") do
  Dir.mktmpdir do |d|
    snap = File.join(d, "DND-982-proof.json")
    run("proof", "--from-json", File.join(FIX, "pass.json"), "--all-open-epics", "--save", snap)
    out, = run("proof", "--from-json", File.join(FIX, "pass.json"), "--against", snap)
    out.include?("(3 before, 3 still there)")
  end
end

def fixture_with_bodies(dir, &blk)
  data = JSON.parse(File.read(File.join(FIX, "pass.json")))
  data["tickets"].each(&blk)
  path = File.join(dir, "DND-982-bodies.json")
  File.write(path, JSON.generate(data))
  path
end

check("cli: an unreadable body is listed UNREAD with its reason; the digest still drafts") do
  Dir.mktmpdir do |d|
    f = fixture_with_bodies(d) { |t| t["body"] = "__unreadable__" if t["id"] == "DND-3" }
    out, _, code = run("digest", "--from-json", f, "--now", NOW)
    code.zero? && out.include?("1 UNREAD (not judged): DND-3") && out.include?("1x HTTP 429")
  end
end

check("cli: when no body at all can be read the digest is exit 3, not a thin pass") do
  Dir.mktmpdir do |d|
    f = fixture_with_bodies(d) { |t| t["body"] = "__unreadable__" unless t["kind"] == "Feature" }
    _, err, code = run("digest", "--from-json", f, "--now", NOW)
    code == 3 && err.include?("no ticket body could be read") && err.include?("Fix:")
  end
end

check("view: ticket data is escaped for Slack mrkdwn, so a title cannot ping a channel") do
  r = ECV.wont_fix_notice(ticket: "DND-9", title: "<!channel> & co", background: "b <x>",
                          why: "w", session: "s")
  text = r[:blocks].map { |x| x.dig("text", "text").to_s }.join
  text.include?("&lt;!channel&gt; &amp; co") && !text.include?("<!channel>") && text.include?("b &lt;x&gt;")
end

check("view: an overlong digest section is clipped under Slack's limit and says how many lines were cut") do
  long = (1..400).map { |i| "line #{i} of a long section" }.join("\n")
  c = ECV.clip(long)
  c.length <= 3000 && c.match?(/more lines in the run log\z/)
end

if $failures.empty?
  puts "epic-clustering self-test: #{$checks} checks passed"
  exit 0
end
warn "epic-clustering self-test: #{$failures.size} of #{$checks} checks FAILED:"
$failures.each { |f| warn "  - #{f}" }
warn "Fix: make lib/epic_clustering.rb, lib/epic_clustering_notion.rb or scripts/epic-clustering satisfy the failed check(s) above."
exit 1
