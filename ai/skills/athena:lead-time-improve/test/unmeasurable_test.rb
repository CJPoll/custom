# frozen_string_literal: true

# Deterministic suite for the unmeasurable-phase escalation (DND-1806):
# lib/unmeasurable.rb (domain), lib/unmeasurable_store.rb (the state file) and
# lib/unmeasurable_manager.rb (the manager, against fake Notion and alert
# ports). Run by test/self-test.sh, which harness-gate discovers.
#
# TDD order: the domain first, then the store against a temp dir, then the
# manager with fakes. Functional only (DND-1222): no sleeps, no timing, no
# load, no network. Ticket ids are synthetic.

require "json"
require "tmpdir"
require_relative "../lib/unmeasurable"
require_relative "../lib/unmeasurable_store"
require_relative "../lib/unmeasurable_manager"

U = LeadTimeUnmeasurable

$failures = []
$checks = 0

def check(desc)
  $checks += 1
  $failures << desc unless yield
rescue StandardError => e
  $failures << "#{desc} (raised #{e.class}: #{e.message})"
end

def raises?(klass)
  yield
  false
rescue klass
  true
end

# A summary as lead-time-phases --summary --json prints it, cut to the keys
# this tool reads. counts: phase -> [n, n_na].
def summary(repo: "custom", biggest: "queue", counts: {})
  base = { "implement" => [14, 6], "verify" => [9, 11], "queue" => [5, 15], "integrate" => [15, 5], "merge" => [13, 7] }
  phases = base.merge(counts).to_h { |p, (n, na)| [p, { "n" => n, "n_na" => na, "sum_s" => 100 }] }
  { "repo" => repo, "biggest" => (biggest ? { "phase" => biggest } : nil), "phases" => phases }
end

# ── domain: measures ────────────────────────────────────────────────────────
m = U.measures(summary, "custom")
check("measures: the biggest phase is read from the summary") { m[:biggest] == "queue" }
check("measures: n_na > n is unmeasured (the choice rule)") { m[:phases]["queue"] == :unmeasured && m[:phases]["verify"] == :unmeasured }
check("measures: n_na <= n with n > 0 is measured") { m[:phases]["implement"] == :measured && m[:phases]["integrate"] == :measured }
check("measures: no rows at all is empty, neither measured nor unmeasured") { U.measures(summary(counts: { "merge" => [0, 0] }), "custom")[:phases]["merge"] == :empty }
check("measures: a summary for another repo is refused, never counted for this one") { raises?(U::Invalid) { U.measures(summary(repo: "gen_saas"), "custom") } }
check("measures: a summary with no repo is refused") { raises?(U::Invalid) { U.measures(summary.tap { |s| s.delete("repo") }, "custom") } }
check("measures: a summary missing a phase is refused, never read as measured") do
  s = summary
  s["phases"].delete("queue")
  raises?(U::Invalid) { U.measures(s, "custom") }
end
check("measures: a phase whose n is not an integer is refused") do
  s = summary
  s["phases"]["queue"]["n"] = "5"
  raises?(U::Invalid) { U.measures(s, "custom") }
end
dm = U.measures(summary(counts: { "verify" => [0, 20] }), "custom")
check("measures: a phase with no measured row and some n/a rows is dark") { dm[:dark] == ["verify"] }
check("counts?: a dark phase counts though it is not the biggest") { U.counts?(dm, "verify") && U.counts?(dm, "queue") && !U.counts?(dm, "implement") }
check("measures: a tail biggest is no phase to count") { U.measures(summary(biggest: "tail"), "custom")[:biggest].nil? }
check("measures: a null biggest is no phase to count") { U.measures(summary(biggest: nil), "custom")[:biggest].nil? }
check("measures: a biggest that names no known phase is refused") { raises?(U::Invalid) { U.measures(summary(biggest: "lunch"), "custom") } }

# ── domain: advance (the count across runs) ─────────────────────────────────
e0 = U.blank_entry
e1, ev1 = U.advance(e0, run: "r1", measure: :unmeasured, counts: true)
check("advance: an unmeasured biggest phase counts one run") { e1["runs"] == 1 && ev1 == :counted && e1["last_run"] == "r1" }
e1b, = U.advance(e1, run: "r1", measure: :unmeasured, counts: true)
check("advance: the same run observed twice counts once (idempotent per run)") { e1b["runs"] == 1 }
e2, = U.advance(e1, run: "r2", measure: :unmeasured, counts: true)
check("advance: a second run counts two") { e2["runs"] == 2 }
eh, evh = U.advance(e2, run: "r3", measure: :unmeasured, counts: false)
check("advance: unmeasured but not the biggest holds the count, never resets it") { eh["runs"] == 2 && evh.nil? }
ee, eve = U.advance(e2, run: "r3", measure: :empty, counts: true)
check("advance: a window with no rows holds the count") { ee["runs"] == 2 && eve.nil? }
with_ep = e2.merge("runs" => 4, "ticket" => "DND-9001", "episode" => { "since" => "r3", "alerted" => "x.md" })
em, evm = U.advance(with_ep, run: "r5", measure: :measured, counts: true)
check("advance: a measured phase ends the episode and resets the count") { em["runs"].zero? && em["episode"].nil? && evm == :measurable }
check("advance: ... and keeps the hand-off ticket") { em["ticket"] == "DND-9001" }
_, evq = U.advance(U.blank_entry, run: "r1", measure: :measured, counts: true)
check("advance: a measured phase with nothing to reset is no event") { evq.nil? }
check("advance: never mutates its input") { e1["runs"] == 1 && with_ep["runs"] == 4 }

# ── domain: tickets ─────────────────────────────────────────────────────────
check("ticket ref: DND-N is accepted") { U.ticket_ref("DND-1501") == "DND-1501" }
check("ticket ref: another tracker's prefix is refused") { raises?(U::Invalid) { U.ticket_ref("XYZ-12") } }
check("ticket ref: a malformed ref is refused") { raises?(U::Invalid) { U.ticket_ref("DND-") } && raises?(U::Invalid) { U.ticket_ref("dnd 12") } }
check("ticket state: Done is landed") { U.ticket_state("Done") == :landed }
check("ticket state: Ready for Release is landed") { U.ticket_state("Ready for Release") == :landed }
check("ticket state: Cancelled and Won't Fix are closed, not landed") { U.ticket_state("Cancelled") == :closed && U.ticket_state("Won't Fix") == :closed }
check("ticket state: In Progress, Todo, Backlog, Parked are open") { %w[In\ Progress Todo Backlog Parked].all? { |s| U.ticket_state(s) == :open } }
check("ticket state: no status is refused, never read as open") { raises?(U::Invalid) { U.ticket_state(nil) } && raises?(U::Invalid) { U.ticket_state("") } }

# ── domain: escalation steps ────────────────────────────────────────────────
check("steps: a fresh episode promotes, then notes, then alerts") { U.steps(nil, "Off") == %i[promote note alert] }
check("steps: an already Promoted ticket is noted and alerted, not patched") { U.steps(nil, "Promoted") == %i[note alert] }
check("steps: an episode done in an earlier run does nothing") do
  U.steps({ "noted" => true, "promoted" => "yes", "alerted" => "a.md" }, "Promoted").empty?
end
check("steps: an episode whose alert failed retries only the alert") do
  U.steps({ "noted" => true, "promoted" => "yes", "alerted" => nil }, "Promoted") == %i[alert]
end
check("steps: an episode whose promotion failed retries it") do
  U.steps({ "noted" => true, "promoted" => nil, "alerted" => "a.md" }, "Off") == %i[promote]
end
check("steps: a ticket someone set back from Promoted after this episode promoted it is not re-patched") do
  U.steps({ "noted" => true, "promoted" => "yes", "alerted" => "a.md" }, "Off").empty?
end

body = U.alert_body(repo: "custom", phase: "queue", ticket: "DND-9001", runs: 3, run: "run-x", promoted: "yes", record: "/s/runs/x")
check("alert body: names the repo, the phase, the ticket and the run count") do
  ["custom", "queue", "DND-9001", "3 counted runs"].all? { |w| body.include?(w) }
end
check("alert body: carries Fix:") { body.include?("Fix:") }
note = U.ticket_note(repo: "custom", phase: "queue", runs: 3, run: "run-x", promoted: "yes")
failed_note = U.ticket_note(repo: "custom", phase: "queue", runs: 3, run: "run-x", promoted: nil)
check("ticket note: never claims a promotion that failed") { failed_note.include?("promotion failed") && !failed_note.include?("Promoted to Path") }
check("ticket note: names the phase, repo, count, run and DND-1806") { ["queue", "custom", "3", "run-x", "DND-1806"].all? { |w| note.include?(w) } }

# ── the write client's allowlist for the promotion (ai/lib/notion_write.rb) ─
require_relative "../../../lib/notion_write"
PG = "c0000000-0000-4000-8000-000000009001"
ok_body = { "properties" => { "Path" => { "select" => { "name" => "Promoted" } } } }
check("NotionWrite: a page PATCH setting Path = Promoted is admitted") { NotionWrite.write?("PATCH", "/v1/pages/#{PG}", ok_body) }
[
  ["another Path value", { "properties" => { "Path" => { "select" => { "name" => "Off" } } } }],
  ["another property", { "properties" => { "Status" => { "select" => { "name" => "Promoted" } } } }],
  ["two properties", { "properties" => { "Path" => { "select" => { "name" => "Promoted" } }, "Severity" => { "select" => { "name" => "LOW" } } } }],
  ["an archive", { "archived" => true }],
  ["properties plus an archive", ok_body.merge("archived" => true)],
  ["a non-select type", { "properties" => { "Path" => { "status" => { "name" => "Promoted" } } } }],
  ["no body", nil]
].each do |what, body|
  check("NotionWrite: a page PATCH with #{what} is refused before it is sent") { !NotionWrite.write?("PATCH", "/v1/pages/#{PG}", body) }
end
check("NotionWrite: set_select of a value SELECTS does not list raises Refused, nothing sent") do
  raises?(NotionWrite::Refused) { NotionWrite.set_select("http://127.0.0.1:9", "t", PG, "Path", "Off") }
end
check("NotionWrite: the two earlier writes are still admitted") do
  NotionWrite.write?("POST", "/v1/pages", {}) && NotionWrite.write?("PATCH", "/v1/blocks/#{PG}/children", {})
end

# ── store ───────────────────────────────────────────────────────────────────
Dir.mktmpdir("unmeasurable-store-") do |dir|
  path = File.join(dir, "unmeasurable.json")
  store = LeadTimeUnmeasurableStore.new(path)
  check("store: no file is the initial state, zero entries") { store.load.empty? }
  store.save({ "custom/queue" => U.blank_entry.merge("runs" => 2) })
  check("store: a saved entry reads back") { LeadTimeUnmeasurableStore.new(path).load["custom/queue"]["runs"] == 2 }
  check("store: the file is 0600") { (File.stat(path).mode & 0o777) == 0o600 }
  File.write(path, "{not json")
  check("store: a corrupt file is could-not-look, never an empty state") { raises?(LeadTimeUnmeasurableStore::Unreadable) { store.load } }
  File.write(path, JSON.generate({ "version" => 99, "entries" => {} }))
  check("store: an unknown version is could-not-look") { raises?(LeadTimeUnmeasurableStore::Unreadable) { store.load } }
  [{ "runs" => nil }, { "runs" => "2" }, { "ticket" => "XYZ-1" }, { "ticket_landed" => nil }, { "episode" => [] }].each do |bad|
    File.write(path, JSON.generate({ "version" => 1, "entries" => { "custom/queue" => U.blank_entry.merge(bad) } }))
    check("store: an entry with #{bad.keys.first}=#{bad.values.first.inspect} is could-not-look, never a crash") do
      raises?(LeadTimeUnmeasurableStore::Unreadable) { store.load }
    end
  end
  File.delete(path)
  locked = store.transaction { |entries, save| entries["custom/merge"] = U.blank_entry.merge("runs" => 1); save.call; :done }
  check("store: a transaction returns its block's value and saves through save") { locked == :done && store.load["custom/merge"]["runs"] == 1 }
  check("store: a transaction leaves its lock file beside the state") { File.exist?("#{path}.lock") }
end
Dir.mktmpdir("unmeasurable-store-") do |dir|
  sub = File.join(dir, "noread")
  Dir.mkdir(sub)
  File.write(File.join(sub, "unmeasurable.json"), JSON.generate({ "version" => 1, "entries" => {} }))
  File.chmod(0o000, sub)
  unless File.readable?(sub) # root reads anyway; the case needs a non-root user
    check("store: a state file it may not reach is could-not-look, never an empty state (File.exist? would say false)") do
      raises?(LeadTimeUnmeasurableStore::Unreadable) { LeadTimeUnmeasurableStore.new(File.join(sub, "unmeasurable.json")).load }
    end
  end
  File.chmod(0o700, sub)
end

# ── manager, against fake ports ─────────────────────────────────────────────
class FakeNotion
  attr_reader :calls
  attr_accessor :status, :path, :fail_read, :fail_promote, :fail_note

  def initialize(status: "In Progress", path: "Off")
    @status = status
    @path = path
    @calls = []
  end

  def ticket(ref)
    @calls << [:read, ref]
    raise LeadTimeUnmeasurableManager::PortError, "Notion answered HTTP 503" if fail_read

    { id: "page-#{ref}", status: @status, path: @path }
  end

  def promote(page_id)
    @calls << [:promote, page_id]
    raise LeadTimeUnmeasurableManager::PortError, "Notion answered HTTP 403" if fail_promote

    @path = "Promoted"
  end

  def note(page_id, text)
    @calls << [:note, page_id, text]
    raise LeadTimeUnmeasurableManager::PortError, "no answer" if fail_note
  end

  def writes = @calls.count { |c| c.first != :read }
end

class FakeAlert
  attr_reader :sent
  attr_accessor :fail

  def initialize
    @sent = []
  end

  def send_alert(slug, record, body)
    raise LeadTimeUnmeasurableManager::PortError, "send-mail exited 1" if fail

    @sent << [slug, record, body]
    "20261002T000000Z-#{@sent.size}-#{slug}.md"
  end
end

def manager(dir, notion, alert)
  LeadTimeUnmeasurableManager.new(store: LeadTimeUnmeasurableStore.new(File.join(dir, "unmeasurable.json")),
                                  runs_dir: File.join(dir, "runs"), notion: notion, alert: alert)
end

def outcome(result, phase = "queue") = result[:lines].find { |l| l[:phase] == phase }

Dir.mktmpdir("unmeasurable-mgr-") do |dir|
  notion = FakeNotion.new
  alert = FakeAlert.new
  mgr = manager(dir, notion, alert)
  mgr.handoff(repo: "custom", phase: "queue", ticket: "DND-9001")

  r1 = mgr.observe(repo: "custom", run: "run-1", summary: summary)
  r2 = mgr.observe(repo: "custom", run: "run-2", summary: summary)
  check("manager: runs 1 and 2 count, read the ticket, and write nothing") do
    outcome(r1)[:outcome] == "COUNTING" && outcome(r2)[:outcome] == "COUNTING" && outcome(r2)[:runs] == 2 && notion.writes.zero? && alert.sent.empty?
  end
  check("manager: a counting run reads the ticket, so its state is never assumed") { notion.calls.count { |c| c.first == :read } == 2 }

  r3 = mgr.observe(repo: "custom", run: "run-3", summary: summary)
  o3 = outcome(r3)
  check("manager: the 3rd run ESCALATES") { o3[:outcome] == "ESCALATED" && o3[:runs] == 3 }
  check("manager: ... notes the ticket once") { notion.calls.count { |c| c.first == :note } == 1 }
  check("manager: ... promotes it once") { notion.calls.count { |c| c.first == :promote } == 1 && notion.path == "Promoted" }
  check("manager: ... sends ONE alert, slug leadtime-unmeasurable") { alert.sent.size == 1 && alert.sent[0][0] == "leadtime-unmeasurable" }
  check("manager: ... whose re: record exists and names the episode") do
    File.read(alert.sent[0][1]).include?("unmeasurable: repo=custom phase=queue ticket=DND-9001 runs=3")
  end
  check("manager: ... and its journal line names the promotion") { o3[:journal].include?("promoted DND-9001 to Path Promoted") }
  check("manager: ... exit 0") { r3[:code].zero? }

  r4 = mgr.observe(repo: "custom", run: "run-4", summary: summary)
  check("manager: the 4th run neither promotes nor alerts") do
    outcome(r4)[:outcome] == "ESCALATED-EARLIER" && notion.calls.count { |c| c.first == :promote } == 1 &&
      notion.calls.count { |c| c.first == :note } == 1 && alert.sent.size == 1
  end
  r4b = mgr.observe(repo: "custom", run: "run-4", summary: summary)
  check("manager: re-observing the same run neither counts nor writes") { outcome(r4b)[:runs] == 4 && alert.sent.size == 1 }

  notion.status = "Done"
  r5 = mgr.observe(repo: "custom", run: "run-5", summary: summary)
  check("manager: landing the ticket ends the episode and resets the count") do
    outcome(r5)[:outcome] == "HANDOFF-LANDED" && outcome(r5)[:runs].zero? && alert.sent.size == 1
  end
  reads_before = notion.calls.count { |c| c.first == :read }
  r6 = mgr.observe(repo: "custom", run: "run-6", summary: summary)
  r7 = mgr.observe(repo: "custom", run: "run-7", summary: summary)
  r8 = mgr.observe(repo: "custom", run: "run-8", summary: summary)
  check("manager: after landing, still-unmeasurable runs count again and never re-escalate the landed ticket") do
    [r6, r7].all? { |r| outcome(r)[:outcome] == "HANDOFF-LANDED" } && outcome(r7)[:runs] == 2 &&
      alert.sent.size == 1 && notion.calls.count { |c| c.first == :promote } == 1
  end
  check("manager: ... and the landed ticket is not re-read") { notion.calls.count { |c| c.first == :read } == reads_before }
  check("manager: ... below the threshold the journal allows measurement maturing") do
    outcome(r7)[:journal].include?("landed") && outcome(r7)[:journal].include?("measurement maturing")
  end
  check("manager: 3 runs after a landing that left it unmeasurable: NO-HANDOFF, so maturing cannot repeat forever") do
    outcome(r8)[:outcome] == "NO-HANDOFF" && outcome(r8)[:runs] == 3 && outcome(r8)[:journal].include?("landed without making it measurable") &&
      outcome(r8)[:journal].include?("no action is not allowed") && alert.sent.size == 1
  end

  mgr.handoff(repo: "custom", phase: "queue", ticket: "DND-9002")
  notion.status = "Todo"
  notion.path = "Off"
  r9 = mgr.observe(repo: "custom", run: "run-9", summary: summary)
  check("manager: a new hand-off ticket opens a new episode at the held count") do
    outcome(r9)[:outcome] == "ESCALATED" && outcome(r9)[:ticket] == "DND-9002" && alert.sent.size == 2
  end
end

Dir.mktmpdir("unmeasurable-mgr-") do |dir|
  notion = FakeNotion.new
  alert = FakeAlert.new
  mgr = manager(dir, notion, alert)
  mgr.handoff(repo: "custom", phase: "queue", ticket: "DND-9001")
  2.times { |i| mgr.observe(repo: "custom", run: "run-#{i}", summary: summary) }
  r = mgr.observe(repo: "custom", run: "run-m", summary: summary(counts: { "queue" => [15, 5] }))
  check("manager: a phase that becomes measurable ends the count (MEASURABLE)") { outcome(r)[:outcome] == "MEASURABLE" && outcome(r)[:runs].zero? }
  r2 = mgr.observe(repo: "custom", run: "run-n", summary: summary)
  check("manager: ... so the next unmeasurable run starts again at 1") { outcome(r2)[:runs] == 1 && alert.sent.empty? }
end

Dir.mktmpdir("unmeasurable-mgr-") do |dir|
  notion = FakeNotion.new
  alert = FakeAlert.new
  mgr = manager(dir, notion, alert)
  r = nil
  3.times { |i| r = mgr.observe(repo: "custom", run: "run-#{i}", summary: summary) }
  check("manager: three runs with no hand-off recorded is NO-HANDOFF, never an escalation of nothing") do
    outcome(r)[:outcome] == "NO-HANDOFF" && notion.calls.empty? && alert.sent.empty?
  end
  check("manager: ... and its journal line says the hand-off is this run's action") { outcome(r)[:journal].include?("hand-off is this run's action") }
end

Dir.mktmpdir("unmeasurable-mgr-") do |dir|
  notion = FakeNotion.new
  alert = FakeAlert.new
  mgr = manager(dir, notion, alert)
  mgr.handoff(repo: "custom", phase: "queue", ticket: "DND-9001")
  notion.fail_read = true
  r = mgr.observe(repo: "custom", run: "run-1", summary: summary)
  check("manager: a ticket read that fails is COULD-NOT-LOOK, exit 3, never 'already handed off'") do
    outcome(r)[:outcome] == "COULD-NOT-LOOK" && r[:code] == 3 && !outcome(r)[:journal].include?("already handed off")
  end
  check("manager: ... and still counts the run") { outcome(r)[:runs] == 1 }
  2.times { |i| mgr.observe(repo: "custom", run: "run-x#{i}", summary: summary) }
  check("manager: an unreadable ticket at the threshold neither promotes nor alerts") { notion.writes.zero? && alert.sent.empty? }
  notion.fail_read = false
  notion.fail_promote = true
  r4 = mgr.observe(repo: "custom", run: "run-4", summary: summary)
  check("manager: a promotion that fails is COULD-NOT-LOOK, exit 3") { outcome(r4)[:outcome] == "COULD-NOT-LOOK" && r4[:code] == 3 }
  check("manager: ... the alert still goes, once, saying the promotion failed") { alert.sent.size == 1 && alert.sent[0][2].include?("could NOT be promoted") }
  notion.fail_promote = false
  r5 = mgr.observe(repo: "custom", run: "run-5", summary: summary)
  check("manager: the next run retries the promotion and does not re-alert") do
    outcome(r5)[:outcome] == "ESCALATED" && notion.path == "Promoted" && alert.sent.size == 1 &&
      notion.calls.count { |c| c.first == :note } == 1
  end
end

Dir.mktmpdir("unmeasurable-mgr-") do |dir|
  notion = FakeNotion.new
  alert = FakeAlert.new
  alert.fail = true
  mgr = manager(dir, notion, alert)
  mgr.handoff(repo: "custom", phase: "queue", ticket: "DND-9001")
  r = nil
  3.times { |i| r = mgr.observe(repo: "custom", run: "run-#{i}", summary: summary) }
  check("manager: an undelivered alert is COULD-NOT-LOOK, exit 3, and the episode stays unalerted") { outcome(r)[:outcome] == "COULD-NOT-LOOK" && r[:code] == 3 }
  alert.fail = false
  r4 = mgr.observe(repo: "custom", run: "run-4", summary: summary)
  check("manager: the next run sends the one alert") { outcome(r4)[:outcome] == "ESCALATED" && alert.sent.size == 1 }
end

Dir.mktmpdir("unmeasurable-mgr-") do |dir|
  notion = FakeNotion.new(status: "Cancelled")
  alert = FakeAlert.new
  mgr = manager(dir, notion, alert)
  mgr.handoff(repo: "custom", phase: "queue", ticket: "DND-9001")
  r = nil
  3.times { |i| r = mgr.observe(repo: "custom", run: "run-#{i}", summary: summary) }
  check("manager: a hand-off closed without landing is HANDOFF-CLOSED: no promotion, a new hand-off is owed") do
    outcome(r)[:outcome] == "HANDOFF-CLOSED" && notion.writes.zero? && outcome(r)[:journal].include?("not handed off")
  end
end

Dir.mktmpdir("unmeasurable-mgr-") do |dir|
  mgr = manager(dir, FakeNotion.new, FakeAlert.new)
  check("manager: handoff refuses a non-DND ticket") { raises?(U::Invalid) { mgr.handoff(repo: "custom", phase: "queue", ticket: "XYZ-1") } }
  check("manager: handoff refuses an unknown phase") { raises?(U::Invalid) { mgr.handoff(repo: "custom", phase: "lunch", ticket: "DND-1") } }
  check("manager: handoff refuses a malformed repo name") { raises?(U::Invalid) { mgr.handoff(repo: "a/b", phase: "queue", ticket: "DND-1") } }
  check("manager: observe refuses a malformed run id") { raises?(U::Invalid) { mgr.observe(repo: "custom", run: "a b", summary: summary) } }
  check("manager: the same hand-off recorded twice is unchanged") do
    mgr.handoff(repo: "custom", phase: "queue", ticket: "DND-1")
    mgr.handoff(repo: "custom", phase: "queue", ticket: "DND-1") == :unchanged
  end
end

Dir.mktmpdir("unmeasurable-mgr-") do |dir|
  notion = FakeNotion.new
  alert = FakeAlert.new
  mgr = manager(dir, notion, alert)
  mgr.handoff(repo: "custom", phase: "verify", ticket: "DND-9003")
  dark = summary(counts: { "verify" => [0, 20] })
  r = nil
  3.times { |i| r = mgr.observe(repo: "custom", run: "run-#{i}", summary: dark) }
  check("manager: a dark phase (no measured row) escalates though queue is the biggest") do
    outcome(r, "verify")[:outcome] == "ESCALATED" && alert.sent.size == 1 && outcome(r, "queue")[:runs] == 3
  end
end

# A step done is saved before the next one runs: a crash after the promotion
# (an error no port rescues) must not repeat it next run.
class CrashingNotion < FakeNotion
  attr_accessor :crash

  def note(page_id, text)
    raise "simulated crash after the promotion" if crash

    super
  end
end
Dir.mktmpdir("unmeasurable-mgr-") do |dir|
  notion = CrashingNotion.new
  alert = FakeAlert.new
  mgr = manager(dir, notion, alert)
  mgr.handoff(repo: "custom", phase: "queue", ticket: "DND-9001")
  2.times { |i| mgr.observe(repo: "custom", run: "run-#{i}", summary: summary) }
  notion.crash = true
  crashed = begin
    mgr.observe(repo: "custom", run: "run-2", summary: summary)
    false
  rescue RuntimeError
    true
  end
  notion.crash = false
  r = mgr.observe(repo: "custom", run: "run-3", summary: summary)
  check("manager: a crash after the promotion keeps it: the next run notes and alerts, and never promotes twice") do
    crashed && outcome(r)[:outcome] == "ESCALATED" && notion.calls.count { |c| c.first == :promote } == 1 &&
      notion.calls.count { |c| c.first == :note } == 1 && alert.sent.size == 1
  end
  check("manager: status refuses a malformed repo name rather than print nothing") { raises?(U::Invalid) { mgr.status(repo: "a/b") } }
end

puts "unmeasurable_test: #{$checks - $failures.size}/#{$checks} passed"
unless $failures.empty?
  $failures.each { |f| puts "FAIL #{f}" }
  exit 1
end
