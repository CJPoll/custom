# frozen_string_literal: true

# Domain suite for `judgment-feedback scan-tickets` (DND-1469, DND-1470):
# ai/lib/judgment_feedback_scan.rb, pure. The ticket's test 3 cases are
# marked [ticket 3]. Run by self-test.sh beside this file. Synthetic ids and
# text only (this repo is public).

require "json"
require_relative "../../lib/judgment_feedback_scan"

S = JudgmentFeedbackScan
$failures = []
$checks = 0

def check(desc)
  $checks += 1
  ok = begin
    yield
  rescue StandardError => e
    $failures << desc
    puts "FAIL #{desc} (raised #{e.class}: #{e.message})"
    return
  end
  $failures << desc unless ok
  puts "#{ok ? 'ok  ' : 'FAIL'} #{desc}"
end

CALL_K = "11111111-1111-4111-8111-111111111111"
CALL_S = "22222222-2222-4222-8222-222222222222"
CALL_X = "33333333-3333-4333-8333-333333333333"
CALLS = { "kind" => CALL_K, "severity" => CALL_S, "security" => CALL_X }.freeze

def prop(value, source: "jev", judged: value, accepted: source == "jev", mode: "on", reason: nil)
  { "value" => value, "source" => source, "judged" => judged, "confidence" => judged && 0.9,
    "accepted" => accepted, "mode" => mode, "reason" => reason }
end

def doc(kind: prop("Bug"), severity: prop("MEDIUM"), security: prop("none"), calls: CALLS)
  d = { "kind" => kind, "severity" => severity, "security" => security, "model" => "jev-1.13.0",
        "versions" => { "kind" => "ticket-kind-v1", "severity" => "ticket-severity-v1", "security" => "ticket-security-v1" } }
  d["calls"] = calls unless calls == :absent
  d
end

def line(doc) = "Jev classification: #{JSON.generate(doc)}"

def ticket(kind: "Bug", severity: "MEDIUM", security: "none", lines: [line(doc)], body_read: true)
  { "ref" => "DND-9001", "kind" => kind, "severity" => severity, "security" => security,
    "body_read" => body_read, "blocks_text" => ["Synthetic body."] + lines }
end

def verdicts(t) = S.ticket_verdict(t)[:properties].to_h

puts "== labels"
check("a judged kind's label is its option key (lower case)") { S.label("kind", "Hardening") == "hardening" }
check("Feature has no kind label (authored, never judged)") { S.label("kind", "Feature").nil? }
check("a severity's label is its level index, lowest first") { %w[LOW MEDIUM HIGH CRITICAL].map { |v| S.label("severity", v) } == %w[0 1 2 3] }
check("an unset severity has no label") { S.label("severity", nil).nil? }
check("security maps introduced and pre-existing to security, none to none") do
  [S.label("security", "introduced"), S.label("security", "pre-existing"), S.label("security", "none")] == %w[security security none]
end

puts "== property verdicts"
check("jev-sourced Kind Bug, current Hardening: one record, correction kind=hardening [ticket 3]") do
  verdicts(ticket(kind: "Hardening"))["kind"] == ["edited", CALL_K, { "kind" => "hardening" }]
end
check("the other two properties, unchanged, are counted unchanged") do
  v = verdicts(ticket(kind: "Hardening"))
  v["severity"] == ["unchanged"] && v["security"] == ["unchanged"]
end
check("filer-sourced and differing: counted filer_sourced, no record [ticket 3]") do
  t = ticket(kind: "Hardening", lines: [line(doc(kind: prop("Bug", source: "filer", judged: nil, reason: "mode_off")))])
  verdicts(t)["kind"] == ["filer_sourced"]
end
check("policy-sourced and differing: counted policy_sourced, no record") do
  t = ticket(security: "none", lines: [line(doc(security: prop("pre-existing", source: "policy", judged: nil, reason: "vulnerability_floor")))])
  verdicts(t)["security"] == ["policy_sourced"]
end
check("no calls key (a line filed before DND-1469): counted unlinked, never matched by title [ticket 3]") do
  verdicts(ticket(kind: "Hardening", lines: [line(doc(calls: :absent))]))["kind"] == ["unlinked"]
end
check("an unedited property on an unlinked line is unchanged, not unlinked (nothing to report)") do
  verdicts(ticket(lines: [line(doc(calls: :absent))]))["kind"] == ["unchanged"]
end
check("a null call for the edited property: counted no_call") do
  verdicts(ticket(kind: "Hardening", lines: [line(doc(calls: CALLS.merge("kind" => nil)))]))["kind"] == ["no_call"]
end
check("source jev but this call was not accepted (a floor from the kind call): not_accepted") do
  floor = prop("pre-existing", judged: "none", accepted: false, reason: nil)
  verdicts(ticket(security: "none", lines: [line(doc(security: floor))]))["security"] == ["not_accepted"]
end
check("an edit to a value with no label (Feature) is no_label, never a guessed label") do
  verdicts(ticket(kind: "Feature"))["kind"] == ["no_label"]
end
check("an edit that keeps Jev's label (pre-existing to introduced) is same_label") do
  sec = prop("pre-existing", judged: "security")
  verdicts(ticket(security: "introduced", lines: [line(doc(security: sec))]))["security"] == ["same_label"]
end
check("a Jev security on a floor that Jev accepted 'none' for, edited back to none: same_label") do
  floor = prop("pre-existing", judged: "none")
  verdicts(ticket(security: "none", lines: [line(doc(security: floor))]))["security"] == ["same_label"]
end
check("severity edited away: the correction is the level index") do
  verdicts(ticket(severity: "HIGH"))["severity"] == ["edited", CALL_S, { "severity" => "2" }]
end
check("security edited from Jev's none to pre-existing: correction security=security") do
  verdicts(ticket(security: "pre-existing"))["security"] == ["edited", CALL_X, { "security" => "security" }]
end
check("a no_threshold reason (DND-1450) on a jev decision is read like any jev decision") do
  t = ticket(kind: "Docs", lines: [line(doc(kind: prop("Bug", reason: "no_threshold")))])
  verdicts(t)["kind"] == ["edited", CALL_K, { "kind" => "docs" }]
end

puts "== ticket verdicts"
check("an unread body is provenance_unread, never no_provenance [ticket 3]") do
  S.ticket_verdict(ticket(body_read: false, lines: [])) == { reason: "provenance_unread", properties: [] }
end
check("no line is no_provenance") { S.ticket_verdict(ticket(lines: []))[:reason] == "no_provenance" }
check("a broken last line is unparseable, even with a good earlier one") do
  S.ticket_verdict(ticket(lines: [line(doc), line(doc)[0, 50]]))[:reason] == "unparseable"
end
check("a garbled calls key is unparseable") do
  S.ticket_verdict(ticket(lines: [line(doc(calls: { "kind" => "DND-1" }))]))[:reason] == "unparseable"
end
check("a property with no value key is unparseable (the scan compares values)") do
  d = doc
  d["kind"].delete("value")
  S.ticket_verdict(ticket(lines: [line(d)]))[:reason] == "unparseable"
end
check("the LAST line decides: a re-classification line supersedes the first") do
  older = doc(kind: prop("Docs"))
  verdicts(ticket(kind: "Bug", lines: [line(older), line(doc)]))["kind"] == ["unchanged"]
end

puts "== tally"
check("every ticket counts once and every property of a read line once; refs name the actionable reasons") do
  rows = [["DND-1", S.ticket_verdict(ticket(kind: "Hardening"))],
          ["DND-2", S.ticket_verdict(ticket(lines: []))],
          ["DND-3", S.ticket_verdict(ticket(body_read: false, lines: []))],
          ["DND-4", S.ticket_verdict(ticket(kind: "Docs", lines: [line(doc(calls: :absent))]))]]
  t = S.tally(rows)
  t[:tickets] == { "provenance_unread" => 1, "no_provenance" => 1, "unparseable" => 0, "lines" => 2 } &&
    t[:properties].values.sum == 6 && t[:properties]["edited"] == 1 && t[:properties]["unlinked"] == 1 &&
    t[:refs]["unlinked"] == ["DND-4"] && t[:refs]["provenance_unread"] == ["DND-3"] &&
    t[:edits] == [["DND-1", "kind", CALL_K, { "kind" => "hardening" }]]
end

puts "== since, cursor and the recorded file"
check("--since takes a time with a zone") { S.parse_since("2026-10-01T07:00:00Z") == Time.utc(2026, 10, 1, 7) }
check("--since refuses a bare date or a zoneless time (never guesses a zone)") do
  %w[2026-10-01 2026-10-01T07:00:00 yesterday].all? do |v|
    S.parse_since(v)
    false
  rescue S::UsageError
    true
  end
end
check("next_since is a minute before the minute the scan started in") do
  S.iso(S.next_since(Time.utc(2026, 10, 1, 7, 30, 45))) == "2026-10-01T07:29:00Z"
end
check("the Notion filter is last_edited_time on or after since") do
  S.filter(Time.utc(2026, 10, 1, 7)) == { "timestamp" => "last_edited_time", "last_edited_time" => { "on_or_after" => "2026-10-01T07:00:00Z" } }
end
check("a record key is the call and its sorted correction") { S.record_key(CALL_K, { "kind" => "docs" }) == "#{CALL_K} kind=docs" }
check("an upper-case call id matches its own recorded entry after the file round trip (never re-sent)") do
  upper = "ABCDEF01-1111-4111-8111-11111111ABCD"
  key = S.record_key(upper, { "kind" => "docs" })
  key != "#{upper} kind=docs" && S.recorded_keys("#{key}\n").include?(key)
end
check("the recorded file reads its keys, blank lines allowed") do
  S.recorded_keys("#{CALL_K} kind=docs\n\n#{CALL_S} severity=2\n") == Set["#{CALL_K} kind=docs", "#{CALL_S} severity=2"]
end
check("a corrupt recorded-file line is usage, never silently ignored") do
  S.recorded_keys("not a key\n")
  false
rescue S::UsageError => e
  e.message.include?("line 1")
end

# ── ticket_blocking (DND-1470) ─────────────────────────────────────────────
# A finding's LAST `Jev path:` line against its current Path and Blocks edge.
# The ticket's test 3 cases are marked [ticket 3].

CALL_P = "44444444-4444-4444-8444-444444444444"
REFS = %w[DND-101 DND-102 DND-103].freeze

def pline(value: "Blocking", blocks: "DND-101", source: "jev", reason: nil, mode: "on", refs: REFS, call: CALL_P)
  d = { "path" => { "value" => value, "blocks" => blocks, "source" => source, "reason" => reason, "mode" => mode, "confidence" => source == "jev" ? 0.95 : nil },
        "would" => nil, "candidates" => refs == :absent ? 3 : refs.size, "model" => "jev-1.13.0", "version" => "ticket-blocking-v1" }
  d["candidate_refs"] = refs unless refs == :absent
  d["call"] = call unless call == :absent
  "Jev path: #{JSON.generate(d)}"
end

def finding(path: "Blocking", lines: [pline], body_read: true)
  { "ref" => "DND-9002", "kind" => "Bug", "severity" => "MEDIUM", "security" => "none", "path" => path,
    "body_read" => body_read, "blocks_text" => ["Synthetic finding."] + lines }
end

def bv(t, edges = []) = S.blocking_verdict(t, edges)

puts "== ticket_blocking verdicts"
check("jev Blocking -> current Off: does_not_block for the judged-blocks candidate [ticket 3]") do
  bv(finding(path: "Off")) == ["edited", CALL_P, { "cand_0" => "does_not_block" }]
end
check("Blocks edge moved to an earlier candidate: two corrections, one record [ticket 3]") do
  bv(finding(lines: [pline(blocks: "DND-103")]), ["DND-101"]) == ["edited", CALL_P, { "cand_0" => "blocks", "cand_2" => "does_not_block" }]
end
check("Blocks edge moved to a later candidate: does_not_block only (Jev may have accepted blocks there too)") do
  bv(finding, ["DND-103"]) == ["edited", CALL_P, { "cand_0" => "does_not_block" }]
end
check("Path changed to Promoted: authored_override, no record [ticket 3]") do
  bv(finding(path: "Promoted")) == ["authored_override"]
end
check("Path changed to Critical: authored_override, no record") do
  bv(finding(path: "Critical")) == ["authored_override"]
end
check("no call key (a line filed before DND-1470): unlinked [ticket 3]") do
  bv(finding(path: "Off", lines: [pline(refs: :absent, call: :absent)])) == ["unlinked"]
end
check("a null call: no_call") do
  bv(finding(path: "Off", lines: [pline(call: nil)])) == ["no_call"]
end
check("jev Blocking, still Blocking onto the same candidate: unchanged") do
  bv(finding, ["DND-101"]) == ["unchanged"]
end
check("an unlinked line that was not changed is unchanged, not unlinked (nothing to report)") do
  bv(finding(lines: [pline(refs: :absent, call: :absent)]), ["DND-101"]) == ["unchanged"]
end
check("jev Blocking, an extra edge onto an earlier candidate: blocks for it only") do
  bv(finding(lines: [pline(blocks: "DND-102")]), %w[DND-101 DND-102]) == ["edited", CALL_P, { "cand_0" => "blocks" }]
end
check("jev Blocking, an extra edge onto a later candidate: not_contradicted, no record") do
  bv(finding, %w[DND-101 DND-102]) == ["not_contradicted"]
end
check("Blocking with no edge is blocking_no_edge (both ways), never unchanged or a correction") do
  bv(finding, []) == ["blocking_no_edge"] && bv(finding(lines: [pline(value: "Off", blocks: nil)]), []) == ["blocking_no_edge"]
end
check("a duplicate edge onto Jev's candidate is unchanged") do
  bv(finding, %w[DND-101 DND-101]) == ["unchanged"]
end
check("an edge onto the finding itself (not a candidate) under a jev Off: no_candidate_named") do
  bv(finding(lines: [pline(value: "Off", blocks: nil)]), ["DND-9002"]) == ["no_candidate_named"]
end
check("a single-pair recorded-file key from DND-1469 still reads back") do
  S.recorded_keys("#{CALL_K} kind=docs\n").include?("#{CALL_K} kind=docs")
end
check("jev Off (Jev removed the claim), now Blocking onto a candidate: blocks for it") do
  bv(finding(lines: [pline(value: "Off", blocks: nil)]), ["DND-102"]) == ["edited", CALL_P, { "cand_1" => "blocks" }]
end
check("jev Off, still Off: unchanged; a stale edge under Off is not a Blocks claim") do
  bv(finding(path: "Off", lines: [pline(value: "Off", blocks: nil)]), ["DND-102"]) == ["unchanged"]
end
check("jev Off, now Blocking onto a ticket that was not a candidate: no_candidate_named") do
  bv(finding(lines: [pline(value: "Off", blocks: nil)]), ["DND-555"]) == ["no_candidate_named"]
end
check("jev Blocking, edge moved to a non-candidate: does_not_block for the judged one only") do
  bv(finding, ["DND-555"]) == ["edited", CALL_P, { "cand_0" => "does_not_block" }]
end
check("filer- and rule-sourced lines are never Jev's: filer_sourced, rule_sourced") do
  bv(finding(path: "Off", lines: [pline(source: "filer", reason: "mode_off")])) == ["filer_sourced"] &&
    bv(finding(path: "Off", lines: [pline(source: "rule", reason: "introduced_security")])) == ["rule_sourced"]
end
check("an unset Path is path_unset, never read as Off") do
  bv(finding(path: nil)) == ["path_unset"]
end
check("Blocking with edges that could not be resolved is edges_unread, never read as no edge") do
  bv(finding, nil) == ["edges_unread"]
end
check("Off needs no edges: an unresolved edge list does not matter") do
  bv(finding(path: "Off"), nil) == ["edited", CALL_P, { "cand_0" => "does_not_block" }]
end
check("no Jev path line: no_path_line; an unread body: provenance_unread") do
  bv(finding(lines: [])) == ["no_path_line"] && bv(finding(body_read: false, lines: [])) == ["provenance_unread"]
end
check("a broken last path line is unparseable, even after a good one") do
  bv(finding(lines: [pline, pline[0, 40]])) == ["unparseable"]
end
check("a garbled call or candidate_refs is unparseable") do
  [pline(call: "DND-1"), pline(refs: ["x"]), pline(refs: %w[DND-101 DND-101 DND-102]), pline.sub(%q("candidates":3), %q("candidates":2)), pline(refs: :absent), pline(call: :absent),
   pline(blocks: "DND-999")].all? { |l| bv(finding(path: "Off", lines: [l])) == ["unparseable"] }
end
check("the LAST path line decides") do
  bv(finding(path: "Off", lines: [pline, pline(value: "Off", blocks: nil)])) == ["unchanged"]
end
check("edges_needed? only for a Jev-sourced line on a ticket now Blocking") do
  S.edges_needed?(finding) && !S.edges_needed?(finding(path: "Off")) &&
    !S.edges_needed?(finding(lines: [pline(source: "filer", reason: "mode_off")])) && !S.edges_needed?(finding(lines: []))
end
check("a blocking correction's record key holds every question, sorted, and reads back") do
  key = S.record_key(CALL_P, { "cand_2" => "blocks", "cand_0" => "does_not_block" })
  key == "#{CALL_P} cand_0=does_not_block,cand_2=blocks" && S.recorded_keys("#{key}\n").include?(key)
end

puts "== ticket_blocking tally"
check("every ticket counts once by reason; actionable reasons are named; edits carry the path property") do
  rows = [["DND-1", bv(finding(path: "Off"))], ["DND-2", bv(finding(lines: []))],
          ["DND-3", bv(finding(path: "Promoted"))], ["DND-4", bv(finding(path: "Off", lines: [pline(refs: :absent, call: :absent)]))]]
  t = S.blocking_tally(rows)
  t[:counts].values.sum == 4 && t[:counts]["edited"] == 1 && t[:counts]["no_path_line"] == 1 &&
    t[:counts]["authored_override"] == 1 && t[:counts]["unlinked"] == 1 && t[:counts].keys == S::BLOCKING_REASONS &&
    t[:refs] == { "unlinked" => ["DND-4"] } && t[:edits] == [["DND-1", "path", CALL_P, { "cand_0" => "does_not_block" }]]
end

puts
puts "judgment-feedback-scan domain: #{$checks - $failures.size} passed, #{$failures.size} failed"
exit($failures.empty? ? 0 : 1)
