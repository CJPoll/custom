# frozen_string_literal: true

# Domain suite for ticket-reclassify (DND-1056): lib/reclassify.rb, pure.
# QA Plan rows are marked [qa eligibility N] / [qa changes N]. Run by
# self-test.sh beside this file. Synthetic ids only.

require "json"
require_relative "helper"
require_relative "../../lib/reclassify"

R = Reclassify

section "eligibility/2"

check("a closed ticket is skipped [qa eligibility 1]") { R.eligibility(ticket(status: "Done"), nil) == [:skip, :closed] }
check("Cancelled and Won't Fix are closed too") do
  R.eligibility(ticket(status: "Cancelled"), nil) == [:skip, :closed] && R.eligibility(ticket(status: "Won't Fix"), nil) == [:skip, :closed]
end
check("In Progress and Todo are open") { R.eligibility(ticket(status: "In Progress"), nil) == :eligible }
check("a Feature is skipped [qa eligibility 2]") { R.eligibility(ticket(kind: "Feature", severity: nil), nil) == [:skip, :feature] }
check("a hand edit after classification locks it [qa eligibility 3]") do
  t = ticket(severity: "HIGH", lines: [line(VALUES, "on")])
  R.eligibility(t, NOW_ON) == [:skip, :locked]
end
check("a matching line does not lock [qa eligibility 4]") do
  R.eligibility(ticket(lines: [line(VALUES, "shadow")]), NOW_ON) == :eligible
end
check("only the LAST line counts for the lock") do
  t = ticket(severity: "HIGH", lines: [line(VALUES, "on"), line(VALUES.merge("severity" => "HIGH"), "shadow")])
  R.eligibility(t, NOW_ON) == :eligible
end
check("an empty property is skipped, not guessed [qa eligibility 5]") { R.eligibility(ticket(severity: nil), nil) == [:skip, :unset_properties] }
check("an empty-string property is unset too") { R.eligibility(ticket(security: ""), nil) == [:skip, :unset_properties] }
check("a value outside the tracker's set is its own skip, never sent") { R.eligibility(ticket(kind: "Chore"), nil) == [:skip, :unknown_value] }
check("a ticket with no project is skipped, never guessed") { R.eligibility(ticket(project: nil), nil) == [:skip, :no_project] }
check("a blank title is skipped (the server refuses it)") { R.eligibility(ticket(title: "   "), nil) == [:skip, :blank_title] }
check("a body that could not be read is skipped, never read as no line") { R.eligibility(ticket(body_read: false), nil) == [:skip, :body_unread] }
check("a line from this version in mode on is already classified [qa eligibility 6]") do
  R.eligibility(ticket(lines: [line(VALUES, "on")]), NOW_ON) == [:skip, :already_classified]
end
check("a mode-off or shadow line is NOT already classified [qa eligibility 7]") do
  R.eligibility(ticket(lines: [line(VALUES, "off")]), NOW_ON) == :eligible &&
    R.eligibility(ticket(lines: [line(VALUES, "shadow")]), NOW_ON) == :eligible &&
    R.eligibility(ticket(lines: [line(VALUES, "off")]), nil) == :eligible
end
check("a line whose modes equal the modes now is already classified (re-judging changes nothing)") do
  now_off = NOW_ON.merge("modes" => { "kind" => "off", "severity" => "off", "security" => "off" })
  R.eligibility(ticket(lines: [line(VALUES, "off")]), now_off) == [:skip, :already_classified]
end
check("an older version is re-judged [qa eligibility 8]") do
  R.eligibility(ticket(lines: [line(VALUES, "on", versions: VERSIONS.merge("kind" => "ticket-kind-v0"))]), NOW_ON) == :eligible
end
check("an older model is re-judged") do
  R.eligibility(ticket(lines: [line(VALUES, "on", model: "jev-1.12.0")]), NOW_ON) == :eligible
end
check("a broken line is its own skip, never absent [qa eligibility 9]") do
  R.eligibility(ticket(lines: [line(VALUES, "on")[0, 60]]), NOW_ON) == [:skip, :unparseable_provenance]
end
check("a line missing a value or a mode is unparseable") do
  doc = JSON.parse(line(VALUES, "on").delete_prefix(R::PREFIX))
  doc["kind"].delete("value")
  no_mode = JSON.parse(line(VALUES, "on").delete_prefix(R::PREFIX))
  no_mode["security"]["mode"] = "sometimes"
  R.eligibility(ticket(lines: [R::PREFIX + JSON.generate(doc)]), NOW_ON) == [:skip, :unparseable_provenance] &&
    R.eligibility(ticket(lines: [R::PREFIX + JSON.generate(no_mode)]), NOW_ON) == [:skip, :unparseable_provenance]
end
check("no line and versions_now unknown is eligible [qa eligibility 10]") { R.eligibility(ticket(lines: ["A W4-era body."]), nil) == :eligible }
check("the reasons are checked in order: closed before unset") { R.eligibility(ticket(status: "Done", severity: nil), nil) == [:skip, :closed] }

section "changes/2"

check("lists only differing properties [qa changes 1]") do
  R.changes(VALUES, VALUES.merge("severity" => "LOW")) == [{ "prop" => "Severity", "from" => "MEDIUM", "to" => "LOW" }]
end
check("equal values give no change [qa changes 2]") { R.changes(VALUES, VALUES) == [] }
check("changes come in Kind, Severity, Security order") do
  R.changes(VALUES, { "kind" => "Vulnerability", "severity" => "HIGH", "security" => "pre-existing" }).map { |c| c["prop"] } == %w[Kind Severity Security]
end

section "reading an answer"

check("a judged 200 reads as ok with the decided values and the modes now") do
  kind, result = R.read_reply(reply(answer(VALUES, "off")), R.filer(VALUES))
  kind == :ok && R.decided(result) == VALUES && R.now_of(result)["modes"] == { "kind" => "off", "severity" => "off", "security" => "off" }
end
check("a budget or rate reason stops the plan") do
  %w[budget_exhausted rate_limited rate_limited_local].all? do |why|
    R.read_reply(reply(answer(VALUES, "on", reason: why)), R.filer(VALUES)).first == :stop
  end
end
check("an account-wide fault stops the plan (a revoked key never stamps the backlog)") do
  %w[key_missing credential_rejected custody_fault price_unknown invalid_request request_rejected model_mismatch].all? do |why|
    R.read_reply(reply(answer(VALUES, "on", reason: why)), R.filer(VALUES)).first == :stop
  end
end
check("a per-call fault makes this ticket unavailable, never an entry") do
  %w[timeout overloaded http_status transport_error undecodable_body malformed_answer domain_not_permitted].all? do |why|
    R.read_reply(reply(answer(VALUES, "on", reason: why)), R.filer(VALUES)) == [:unavailable, "the server answered #{why}"]
  end
end
check("a state reason is a decision, not a fault") do
  %w[mode_off below_threshold threshold_unset label_disabled].all? { |why| R.read_reply(reply(answer(VALUES, "on", reason: why)), R.filer(VALUES)).first == :ok }
end
check("a line carrying a fault reason is never already classified") do
  R.eligibility(ticket(lines: [line(VALUES, "on", reason: "timeout")]), NOW_ON) == :eligible
end
check("a ticket with no Status is skipped, never read as open") { R.eligibility(ticket(status: nil), nil) == [:skip, :no_status] }
check("an unreachable server stops") { R.read_reply({ unreachable: "curl exit 7" }, R.filer(VALUES)) == [:stop, "COULD NOT REACH SERVER: curl exit 7"] }
check("a 401 stops, naming the owner-issued token") { R.read_reply(reply("{}", status: 401), R.filer(VALUES)).then { |k, why| k == :stop && why.include?("HTTP 401") } }
check("a 5xx stops") { R.read_reply(reply("{}", status: 503), R.filer(VALUES)).first == :stop }
check("a 422 is a refusal of this ticket, not a stop") { R.read_reply(reply('{"error":"invalid_request"}', status: 422), R.filer(VALUES)).first == :refused }
check("a 200 outside the judged shape stops (never guessed)") do
  R.read_reply(reply('{"status":"judged"}'), R.filer(VALUES)).then { |k, why| k == :stop && why.start_with?("UNREADABLE SERVER ANSWER") }
end
check("a 200 whose provenance line lacks versions stops") do
  doc = JSON.parse(answer(VALUES, "off"))
  doc["provenance_line"] = R::PREFIX + "{}"
  R.read_reply(reply(JSON.generate(doc)), R.filer(VALUES)).first == :stop
end

section "outcome and plan entries"

check("a change is planned") { R.outcome([{ "prop" => "Severity" }], NOW_ON["modes"]) == :planned }
check("no change with a mode on is unchanged (gets the provenance line) [R1056-7]") { R.outcome([], NOW_ON["modes"]) == :unchanged }
check("no change and no mode on is inert: nothing to write (A-1056-1)") do
  R.outcome([], { "kind" => "off", "severity" => "shadow", "security" => "off" }) == :inert
end
check("the plan entry holds the server's decision and line verbatim, and no body text") do
  _, result = R.read_reply(reply(answer(VALUES.merge("severity" => "LOW"), "on")), R.filer(VALUES))
  e = R.plan_entry(ticket, result)
  e.keys.sort == %w[changes current decided page_id provenance_line ref] && e["provenance_line"] == result["provenance_line"] &&
    e["decided"]["severity"] == "LOW" && !JSON.generate(e).include?("Body text")
end
check("the sent body drops every provenance line (a label leak) and keeps the rest") do
  R.sent_body(ticket(lines: ["Body text.", line(VALUES, "off"), "More."])) == "Body text.\nMore."
end

section "proof"

check("a page matching the plan has no mismatch") do
  e = { "ref" => "DND-7", "decided" => VALUES, "provenance_line" => line(VALUES, "on") }
  R.proof_mismatches(e, VALUES, ["x", line(VALUES, "on")]) == []
end
check("a missed property write is named") do
  e = { "ref" => "DND-7", "decided" => VALUES.merge("severity" => "LOW"), "provenance_line" => line(VALUES, "on") }
  R.proof_mismatches(e, VALUES, [line(VALUES, "on")]) == ["DND-7: Severity is MEDIUM; the plan decided LOW"]
end
check("a missing provenance line is named") do
  e = { "ref" => "DND-7", "decided" => VALUES, "provenance_line" => line(VALUES, "on") }
  R.proof_mismatches(e, VALUES, ["x"]) == ["DND-7: the body has no Jev classification: line; the plan appends one"]
end
check("an altered last line is named, even when an earlier line matches") do
  e = { "ref" => "DND-7", "decided" => VALUES, "provenance_line" => line(VALUES, "on") }
  R.proof_mismatches(e, VALUES, [line(VALUES, "on"), line(VALUES, "off")]) == ["DND-7: the last Jev classification: line is not the plan's, byte for byte"]
end

section "pacing"

check("the first call waits nothing; the next waits out the interval") do
  R.pace_delay(nil, 100.0, 3.0).zero? && R.pace_delay(100.0, 101.0, 3.0) == 2.0 && R.pace_delay(100.0, 104.0, 3.0).zero?
end

finish("ticket-reclassify domain")
