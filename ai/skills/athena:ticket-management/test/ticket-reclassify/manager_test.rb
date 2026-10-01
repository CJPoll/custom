# frozen_string_literal: true

# Manager suite for ticket-reclassify (DND-1056): plan and proof with a fake
# tracker, a fake classification server and a fake clock. QA Plan rows are
# marked [qa plan N] / [qa proof N]. Synthetic ids only; no network.

require "json"
require "stringio"
require "tmpdir"
require_relative "helper"

require_relative "fakes"

def run_plan(notion, server, out_path, clock: FakeClock.new, limit: nil, resume_from: nil)
  io = StringIO.new
  code = Manager.plan({ out: out_path, limit: limit, resume_from: resume_from }, io,
                      { notion: notion, server: server, clock: clock, interval: Reclassify::CALL_INTERVAL_S })
  [code, io.string, JSON.parse(File.read(out_path))]
end

def run_proof(notion, plan_path)
  io = StringIO.new
  code = Manager.proof({ against: plan_path }, io, { notion: notion })
  [code, io.string]
end

TMP = Dir.mktmpdir("reclassify-test-")
at_exit { FileUtils.rm_rf(TMP) }

section "plan"

check("sends current values as the filer and the ref [qa plan 1]") do
  server = FakeServer.new { |b| [filer_of(b), "off"] }
  run_plan(FakeNotion.new([ticket(number: 7, severity: "HIGH")]), server, "#{TMP}/p1.json")
  b = server.bodies.first
  b["filer"] == { "kind" => "Bug", "severity" => "HIGH", "security" => "none" } && b["ticket"]["ref"] == "DND-7" &&
    b["ticket"]["project"] == "harness" && b["ticket"]["title"] == "Synthetic ticket title"
end

check("the sent body carries no provenance line") do
  server = FakeServer.new { |b| [filer_of(b), "off"] }
  run_plan(FakeNotion.new([ticket(lines: ["Body text.", line(VALUES, "off")])]), server, "#{TMP}/p1b.json")
  server.bodies.first["ticket"]["body"] == "Body text."
end

check("the plan holds the server's decision verbatim [qa plan 2]") do
  server = FakeServer.new { |b| [filer_of(b).merge("severity" => "LOW"), "on"] }
  _, _, doc = run_plan(FakeNotion.new([ticket]), server, "#{TMP}/p2.json")
  e = doc["entries"].first
  e["decided"] == VALUES.merge("severity" => "LOW") && e["provenance_line"] == line(VALUES.merge("severity" => "LOW"), "on") &&
    e["changes"] == [{ "prop" => "Severity", "from" => "MEDIUM", "to" => "LOW" }] && doc["counts"]["changes"] == { "Severity MEDIUM->LOW" => 1 }
end

check("unchanged entries still carry the provenance line [qa plan 3]") do
  server = FakeServer.new { |b| [filer_of(b), "on"] }
  _, _, doc = run_plan(FakeNotion.new([ticket]), server, "#{TMP}/p3.json")
  e = doc["entries"].first
  doc["counts"]["unchanged"] == 1 && e["changes"] == [] && e["provenance_line"] == line(VALUES, "on")
end

check("every mode off: no entries, every answered ticket inert, reported with counts (A-1056-1)") do
  server = FakeServer.new { |b| [filer_of(b), "off"] }
  code, out, doc = run_plan(FakeNotion.new([ticket(number: 1), ticket(number: 2)]), server, "#{TMP}/p3b.json")
  code.zero? && doc["entries"].empty? && doc["counts"]["inert"] == 2 && doc["inert_refs"] == %w[DND-1 DND-2] &&
    out.include?("writes to apply: 0 (0 property writes, 0 provenance lines); every answered ticket is inert") &&
    out.include?("server now: model jev-1.13.0") && out.include?("modes kind off, severity off, security off")
end

check("every mode off: a paraphrased line is re-judged and its verbatim line planned (healed) [ticket 1354]") do
  server = FakeServer.new { |b| [filer_of(b), "off"] }
  prose = "Jev classification: Kind Bug, Severity MEDIUM, Security none (filer: mode_off)."
  code, out, doc = run_plan(FakeNotion.new([ticket(number: 1), ticket(number: 2, lines: ["Body.", prose])]), server, "#{TMP}/p3h.json")
  e = doc["entries"].first
  code.zero? && doc["entries"].size == 1 && e["ref"] == "DND-2" && e["changes"] == [] && e["provenance_line"] == line(VALUES, "off") &&
    doc["counts"]["unchanged"] == 1 && doc["counts"]["inert"] == 1 && doc["healed_refs"] == { "prose_values" => ["DND-2"] } &&
    out.include?("healed paraphrases: 1 (prose_values: DND-2)") && out.include?("writes to apply: 1 tickets")
end

check("a lossy paraphrase is skipped and named by its reason, never asked [ticket 1354]") do
  server = FakeServer.new { |b| [filer_of(b), "off"] }
  lossy = "Jev classification: security none (jev 1.00, mode on, accepted); kind and severity from the filer (mode_off)."
  code, out, doc = run_plan(FakeNotion.new([ticket(number: 3, lines: [lossy])]), server, "#{TMP}/p3l.json")
  code.zero? && server.bodies.empty? && doc["counts"]["skipped"]["unparseable_provenance"] == 1 &&
    doc["unparseable_reasons"] == { "lossy_paraphrase" => ["DND-3"] } && out.include?("    lossy_paraphrase: 1 (DND-3)")
end

check("a policy change with every mode off is still planned (the Vulnerability floor)") do
  server = FakeServer.new { |b| [filer_of(b).merge("security" => "pre-existing"), "off"] }
  _, _, doc = run_plan(FakeNotion.new([ticket(kind: "Vulnerability")]), server, "#{TMP}/p3c.json")
  doc["counts"]["planned"] == 1 && doc["counts"]["changes"] == { "Security none->pre-existing" => 1 }
end

check("a budget stop writes a cursor and exits 3 [qa plan 4]") do
  server = FakeServer.new do |b|
    b["ticket"]["ref"] == "DND-5" ? [filer_of(b), "on", "budget_exhausted"] : [filer_of(b).merge("severity" => "LOW"), "on"]
  end
  code, out, doc = run_plan(FakeNotion.new((1..6).map { |n| ticket(number: n) }), server, "#{TMP}/p4.json")
  code == 3 && doc["entries"].size == 4 && doc["cursor"] == "DND-5" && doc["complete"] == false &&
    doc["stopped_because"] == "the server answered budget_exhausted" && doc["counts"]["not_reached"] == 2 &&
    out.include?("Fix: resume later with --resume-from the cursor (--resume-from DND-5, into a new --out)")
end

check("--resume-from starts at the cursor") do
  server = FakeServer.new { |b| [filer_of(b), "on"] }
  _, out, doc = run_plan(FakeNotion.new((1..6).map { |n| ticket(number: n) }), server, "#{TMP}/p4b.json", resume_from: "DND-5")
  doc["counts"]["considered"] == 2 && doc["entries"].map { |e| e["ref"] } == %w[DND-5 DND-6] && out.include?("(resumed from DND-5)")
end

check("an unreachable server stops with a cursor, never skipped") do
  server = Object.new
  def server.post(_body) = { unreachable: "curl exit 7 reaching the Athena server" }
  code, out, doc = run_plan(FakeNotion.new([ticket(number: 3)]), server, "#{TMP}/p4c.json")
  code == 3 && doc["cursor"] == "DND-3" && out.include?("COULD NOT REACH SERVER")
end

check("--limit asks at most N tickets, then stops with a cursor (partial, exit 0)") do
  server = FakeServer.new { |b| [filer_of(b), "on"] }
  code, out, doc = run_plan(FakeNotion.new((1..4).map { |n| ticket(number: n) }), server, "#{TMP}/p4d.json", limit: 2)
  code.zero? && server.bodies.size == 2 && doc["cursor"] == "DND-3" && out.include?("PARTIAL (cursor DND-3, not reached 2)")
end

check("pacing stays under the local limit [qa plan 5]") do
  clock = FakeClock.new
  times = []
  server = FakeServer.new do |b|
    times << clock.now
    clock.advance(0.2) # the call itself takes time
    [filer_of(b), "on"]
  end
  run_plan(FakeNotion.new((1..30).map { |n| ticket(number: n) }), server, "#{TMP}/p5.json", clock: clock)
  times.size == 30 && times.all? { |t0| times.count { |t| t >= t0 && t < t0 + 60 } <= 20 }
end

check("counts account for every ticket [qa plan 6]") do
  tickets = [
    ticket(number: 1, status: "Done"), ticket(number: 2, kind: "Feature", severity: nil), ticket(number: 3, severity: nil),
    ticket(number: 4, severity: "HIGH", lines: [line(VALUES, "on")]), ticket(number: 5, lines: [line(VALUES, "on")[0, 40]]),
    ticket(number: 6, project: nil), ticket(number: 7, kind: "Chore"), ticket(number: 8),
    ticket(number: 9), ticket(number: 10), ticket(number: 11), ticket(number: 12)
  ]
  notion = FakeNotion.new(tickets)
  notion.unreadable << page_id(8)
  server = FakeServer.new { |b| [filer_of(b).merge("severity" => b["ticket"]["ref"] == "DND-9" ? "LOW" : "MEDIUM"), "on"] }
  code, out, doc = run_plan(notion, server, "#{TMP}/p6.json")
  c = doc["counts"]
  sum = c["skipped"].values.sum + c["planned"] + c["unchanged"] + c["inert"] + c["not_reached"]
  # DND-8's unread body makes the plan INCOMPLETE: exit 3.
  code == 3 && c["considered"] == 12 && sum == 12 && c["planned"] == 1 && c["unchanged"] == 3 && c["inert"].zero? &&
    c["skipped"].values_at("closed", "feature", "unset_properties", "locked", "unparseable_provenance", "no_project", "unknown_value", "body_unread") == [1] * 8 &&
    doc["skipped_refs"]["locked"] == ["DND-4"] && out.include?("sum check: considered 12 = skipped 8 + planned 1 + unchanged 3 + inert 0 + not reached 0")
end

check("an already-classified ticket makes no call once the server's version is known [R1056-7]") do
  server = FakeServer.new { |b| [filer_of(b), "on"] }
  _, _, doc = run_plan(FakeNotion.new([ticket(number: 1), ticket(number: 2, lines: [line(VALUES, "on")])]), server, "#{TMP}/p6b.json")
  server.bodies.size == 1 && doc["skipped_refs"]["already_classified"] == ["DND-2"]
end

check("the first answer re-checks its own ticket: an already-classified first ticket is counted so, not re-written") do
  server = FakeServer.new { |b| [filer_of(b), "on"] }
  _, _, doc = run_plan(FakeNotion.new([ticket(number: 1, lines: [line(VALUES, "on")])]), server, "#{TMP}/p6c.json")
  doc["entries"].empty? && doc["skipped_refs"]["already_classified"] == ["DND-1"]
end

check("a server whose modes change mid-run stops the plan") do
  server = FakeServer.new { |b| [filer_of(b), b["ticket"]["ref"] == "DND-1" ? "off" : "on"] }
  code, _, doc = run_plan(FakeNotion.new([ticket(number: 1), ticket(number: 2)]), server, "#{TMP}/p6d.json")
  code == 3 && doc["cursor"] == "DND-2" && doc["stopped_because"].include?("changed during the run")
end

check("the plan file is 0600 and holds no body text [qa plan 7]") do
  server = FakeServer.new { |b| [filer_of(b).merge("severity" => "LOW"), "on"] }
  run_plan(FakeNotion.new([ticket(lines: ["SECRET-BODY-MARKER text"])]), server, "#{TMP}/p7.json")
  File.stat("#{TMP}/p7.json").mode & 0o777 == 0o600 && !File.read("#{TMP}/p7.json").include?("SECRET-BODY-MARKER")
end

check("a closed ticket's body is never read (skips decidable from the row cost no read)") do
  notion = FakeNotion.new([ticket(number: 1, status: "Done")])
  run_plan(notion, FakeServer.new { |b| [filer_of(b), "on"] }, "#{TMP}/p7b.json")
  notion.calls.none? { |c| c.first == :children }
end

def failure_of
  yield
  nil
rescue Failure => e
  [e.code, e.message]
end

check("a per-call fault in mode on is no entry and no classification; the plan is incomplete (exit 3, Fix:)") do
  server = FakeServer.new { |b| [filer_of(b), "on", b["ticket"]["ref"] == "DND-2" ? "timeout" : nil] }
  code, out, doc = run_plan(FakeNotion.new([ticket(number: 1), ticket(number: 2)]), server, "#{TMP}/f1.json")
  code == 3 && doc["entries"].map { |e| e["ref"] } == ["DND-1"] && doc["skipped_refs"]["unavailable"] == ["DND-2"] &&
    doc["complete"] == false && out.include?("INCOMPLETE: 1 ticket(s) could not be judged (unavailable DND-2)") && out.include?("Fix:")
end

check("an account-wide fault stops the plan at that ticket") do
  server = FakeServer.new { |b| [filer_of(b), "on", "credential_rejected"] }
  code, _, doc = run_plan(FakeNotion.new([ticket(number: 4)]), server, "#{TMP}/f2.json")
  code == 3 && doc["cursor"] == "DND-4" && doc["stopped_because"] == "the server answered credential_rejected"
end

check("a 422 through the manager is refused, listed, and the plan is incomplete") do
  server = Object.new
  def server.post(_body) = { curl_rc: 0, status: 422, body: '{"error":"invalid_request"}' }
  code, out, doc = run_plan(FakeNotion.new([ticket(number: 5)]), server, "#{TMP}/f3.json")
  code == 3 && doc["skipped_refs"]["refused"] == ["DND-5"] && out.include?("INCOMPLETE") && doc["complete"] == false
end

check("an unreadable body makes the plan incomplete, never complete with 0 writes") do
  notion = FakeNotion.new([ticket(number: 6)])
  notion.unreadable << page_id(6)
  code, out, doc = run_plan(notion, FakeServer.new { |b| [filer_of(b), "on"] }, "#{TMP}/f4.json")
  code == 3 && doc["skipped_refs"]["body_unread"] == ["DND-6"] && out.include?("INCOMPLETE") && out.include?("body_unread DND-6")
end

check("a ticket with no Status is skipped as no_status, never read as open") do
  _, _, doc = run_plan(FakeNotion.new([ticket(number: 7, status: nil)]), FakeServer.new { |b| [filer_of(b), "on"] }, "#{TMP}/f5.json")
  doc["skipped_refs"]["no_status"] == ["DND-7"]
end

check("rows with no Status property fail the plan (a renamed property is not an open ticket)") do
  notion = FakeNotion.new([ticket(number: 8)])
  def notion.row(t) = super.tap { |r| r["properties"].delete("Status") }
  code, message = failure_of { run_plan(notion, FakeServer.new { |b| [filer_of(b), "on"] }, "#{TMP}/f6.json") }
  code == 1 && message.include?("no Status status property") && message.include?("Fix:")
end

check("a --resume-from that matches no ticket fails, never an empty complete plan") do
  code, message = failure_of { run_plan(FakeNotion.new([ticket(number: 9)]), FakeServer.new { |b| [filer_of(b), "on"] }, "#{TMP}/f7.json", resume_from: "DND-90") }
  code == 1 && message.include?("--resume-from DND-90 matches no ticket") && !File.exist?("#{TMP}/f7.json")
end

check("an unexpected error stops with a cursor and keeps the answers so far") do
  server = FakeServer.new do |b|
    raise NoMethodError, "boom" if b["ticket"]["ref"] == "DND-2"

    [filer_of(b).merge("severity" => "LOW"), "on"]
  end
  code, out, doc = run_plan(FakeNotion.new([ticket(number: 1), ticket(number: 2)]), server, "#{TMP}/f8.json")
  code == 3 && doc["entries"].map { |e| e["ref"] } == ["DND-1"] && doc["cursor"] == "DND-2" &&
    doc["stopped_because"] == "UNEXPECTED ERROR: NoMethodError" && out.include?("Fix:")
end

section "proof"

def planned_fixture(name)
  notion = FakeNotion.new([ticket(number: 1), ticket(number: 2), ticket(number: 3)])
  server = FakeServer.new { |b| [filer_of(b).merge("severity" => b["ticket"]["ref"] == "DND-3" ? "MEDIUM" : "LOW"), "on"] }
  path = "#{TMP}/#{name}.json"
  _, _, doc = run_plan(notion, server, path)
  [notion, path, doc]
end

check("all applied is exit 0 [qa proof 1]") do
  notion, path, doc = planned_fixture("q1")
  doc["entries"].each { |e| notion.apply(e) }
  code, out = run_proof(notion, path)
  code.zero? && out.include?("3 entries (planned 2, unchanged 1), 3 match, 0 mismatch")
end

check("a missed property write fails, named [qa proof 2]") do
  notion, path, doc = planned_fixture("q2")
  doc["entries"].each { |e| notion.apply(e) }
  notion.pages[page_id(2)]["severity"] = "MEDIUM"
  code, out = run_proof(notion, path)
  code == 4 && out.include?("MISMATCH DND-2: Severity is MEDIUM; the plan decided LOW") && out.include?("Fix: apply the named writes")
end

check("a missing or altered provenance line fails [qa proof 3]") do
  notion, path, doc = planned_fixture("q3")
  doc["entries"].each { |e| notion.apply(e) }
  notion.bodies[page_id(1)] = ["Body text."]
  code, out = run_proof(notion, path)
  code == 4 && out.include?("MISMATCH DND-1: the body has no Jev classification: line")
end

check("an unreadable page is a mismatch, not a pass [qa proof 4]") do
  notion, path, doc = planned_fixture("q4")
  doc["entries"].each { |e| notion.apply(e) }
  notion.unreadable << page_id(3)
  code, out = run_proof(notion, path)
  code == 4 && out.include?("MISMATCH DND-3: could not read")
end

check("a plan with no writes proves 0 entries and says so") do
  notion = FakeNotion.new([ticket(number: 1)])
  run_plan(notion, FakeServer.new { |b| [filer_of(b), "off"] }, "#{TMP}/q5.json")
  code, out = run_proof(notion, "#{TMP}/q5.json")
  code.zero? && out.include?("0 entries (planned 0, unchanged 0), 0 match, 0 mismatch; the plan holds no writes, nothing to prove")
end

check("a second plan after the apply plans nothing (idempotence) [qa procedure 3]") do
  notion, _path, doc = planned_fixture("q6")
  doc["entries"].each { |e| notion.apply(e) }
  notion.tickets.each { |t| t.merge!(notion.pages[t["page_id"]]) }
  server = FakeServer.new { |b| [filer_of(b).merge("severity" => "LOW"), "on"] }
  _, _, again = run_plan(notion, server, "#{TMP}/q6-again.json")
  again["counts"]["planned"].zero? && again["counts"]["unchanged"].zero? && server.bodies.size == 1 &&
    again["counts"]["skipped"]["already_classified"] == 3
end

section "notion_read"

check("a query page that says has_more with no cursor raises, never a cut-off list") do
  original = NotionRead.method(:read)
  NotionRead.define_singleton_method(:read) { |*_args, **_kw| { "results" => [{ "id" => "x" }], "has_more" => true, "next_cursor" => nil } }
  begin
    NotionRead.query_all("http://127.0.0.1:1", "t", Effects::TICKETS_DATA_SOURCE, pace: 0)
    false
  rescue NotionRead::Error => e
    e.message.include?("has_more") && e.message.include?("no usable next_cursor")
  ensure
    NotionRead.define_singleton_method(:read, original)
  end
end

check("the allowlist refuses a write before it is sent") do
  NotionRead.read("http://127.0.0.1:1", "t", "PATCH", "/v1/pages/#{page_id(1)}", pace: 0)
  false
rescue NotionRead::Error => e
  e.message.start_with?("refused a Notion PATCH")
end

finish("ticket-reclassify manager")
