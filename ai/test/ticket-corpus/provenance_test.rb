# frozen_string_literal: true

# Domain suite for reading a ticket's `Jev classification:` line (DND-1354):
# TicketCorpus.read_line / provenance / line_class, pure. Filers pasted
# paraphrases instead of the line; the readers recover the known shapes that
# lose nothing, and count every other line by reason (never read as absent).
# Run by self-test.sh beside this file. Synthetic ids and text only (this
# repo is public). The fail-first cases are marked [ticket].

require "json"
require_relative "../../lib/ticket_corpus"

TC = TicketCorpus
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

P = "Jev classification: "

def prop(value, source: "filer", accepted: false, judged: nil, mode: "off", reason: "mode_off")
  { "reason" => reason, "value" => value, "mode" => mode, "accepted" => accepted, "source" => source,
    "confidence" => nil, "judged" => judged }
end

VERBATIM = P + JSON.generate("kind" => prop("Bug"), "severity" => prop("MEDIUM"), "security" => prop("none"),
                             "versions" => { "kind" => "ticket-kind-v1", "severity" => "ticket-severity-v1", "security" => "ticket-security-v1" },
                             "model" => "jev-1.13.0")

def ticket(*lines) = { "ref" => "DND-9001", "blocks_text" => ["Synthetic body."] + lines }

def values(doc) = %w[kind severity security].map { |k| doc[k]["value"] }

puts "== verbatim"
check("a verbatim line reads ok and is not marked recovered") do
  state, doc = TC.read_line(VERBATIM)
  state == :ok && !doc.key?("recovered") && TC.line_class([state, doc]) == "verbatim"
end
check("provenance still returns [:none] with no line") { TC.provenance(ticket) == [:none] && TC.line_class([:none]) == "none" }

puts "== recovered paraphrases [ticket]"
abbreviated = P + JSON.generate("kind" => { "reason" => "mode_off", "value" => "Test", "source" => "filer" },
                                "severity" => { "reason" => "mode_off", "value" => "LOW", "source" => "filer" },
                                "security" => { "reason" => "mode_off", "value" => "none", "source" => "filer" },
                                "model" => "jev-1.13.0")
check("an abbreviated all-filer JSON line (no accepted, judged or versions) is recovered [ticket]") do
  state, doc = TC.read_line(abbreviated)
  state == :ok && doc["recovered"] == "abbreviated_json" && values(doc) == %w[Test LOW none] &&
    %w[kind severity security].all? { |k| doc[k]["accepted"] == false && doc[k]["judged"].nil? && doc[k]["source"] == "filer" } &&
    TC.valid_provenance?(doc) && TC.line_class([state, doc]) == "recovered_abbreviated_json"
end
check("prose 'Kind X, Severity Y, Security Z (filer: mode_off)' is recovered as filer values [ticket]") do
  state, doc = TC.read_line("#{P}Kind Bug, Severity MEDIUM, Security none (filer: mode_off).")
  state == :ok && doc["recovered"] == "prose_values" && values(doc) == %w[Bug MEDIUM none] && TC.valid_provenance?(doc)
end
check("prose naming versions and the model (jev-1.13.0) is still all filer [ticket]") do
  state, doc = TC.read_line("#{P}Kind Bug, Severity LOW, Security none (filer: mode_off; ticket-kind-v1/ticket-severity-v1/ticket-security-v1, jev-1.13.0).")
  state == :ok && values(doc) == %w[Bug LOW none]
end
check("prose 'filer values A / B / C' with mode_off is recovered [ticket]") do
  state, doc = TC.read_line("#{P}ticket-classify exit 0, mode_off; filer values Ops / LOW / none.")
  state == :ok && doc["recovered"] == "prose_values" && values(doc) == %w[Ops LOW none]
end
check("a recovered line carries no calls (it cannot name Jev's call)") do
  _, doc = TC.read_line("#{P}Kind Bug, Severity LOW, Security pre-existing (filer: mode_off).")
  TC.calls(doc).nil? && doc["security"]["value"] == "pre-existing"
end

puts "== unparseable, by reason [ticket]"
check("prose that names an accepted jev judgment is lossy_paraphrase: its call and values are gone [ticket]") do
  TC.read_line("#{P}security none (jev 1.00, mode on, accepted); kind and severity from the filer (mode_off); Path Off (filer: shadow), Blocks none.") ==
    [:unparseable, "lossy_paraphrase"]
end
[
  "Kind: Bug (jev), Severity: LOW (filer: mode_off), Security: none (filer: mode_off)",
  "Kind Bug (judged by Jev), Severity LOW, Security none (filer)",
  "Kind Bug (Jev: 0.93), Severity LOW, Security none (filer: mode_off)",
  "Kind Bug (jev 93%), Severity LOW, Security none (filer: mode_off)",
  "Kind Bug (jev .9), Severity LOW, Security none (filer: mode_off)",
  "Kind Bug (filer: shadow), Severity LOW, Security none (filer: mode_off)",
  "Kind Bug, Severity LOW, Security pre-existing (vulnerability_floor); rest filer",
  "Kind Bug, Severity LOW (Jev said MEDIUM), Security none, filer",
  "Kind Bug, Severity LOW, Security pre-existing (rule: introduced_security), filer"
].each do |prose|
  check("a paraphrase naming Jev, a judgment, shadow, a rule or a policy floor is lossy, never the filer's [review]: #{prose[0, 50]}") do
    TC.read_line("#{P}#{prose}") == [:unparseable, "lossy_paraphrase"]
  end
end
check("two different values for one property is unrecognized_prose, never the first one [review]") do
  TC.read_line("#{P}Kind Bug, Severity LOW, Security none (filer: mode_off); later Kind Docs") == [:unparseable, "unrecognized_prose"]
end
check("the same value named twice still recovers") do
  TC.read_line("#{P}Kind Bug, Severity LOW, Security none (filer: mode_off; Kind Bug kept)").first == :ok
end
check("abbreviated JSON in mode shadow or on is malformed_json: a judgment may hide behind it [review]") do
  %w[shadow on].all? do |mode|
    j = P + JSON.generate("kind" => { "value" => "Bug", "source" => "filer", "mode" => mode }, "severity" => { "value" => "LOW", "source" => "filer" },
                          "security" => { "value" => "none", "source" => "filer" })
    TC.read_line(j) == [:unparseable, "malformed_json"]
  end
end
check("abbreviated JSON naming a call id is malformed_json: a call answered [review]") do
  c = { "kind" => "11111111-1111-4111-8111-111111111111", "severity" => nil, "security" => nil }
  j = P + JSON.generate("kind" => { "value" => "Bug", "source" => "filer" }, "severity" => { "value" => "LOW", "source" => "filer" },
                        "security" => { "value" => "none", "source" => "filer" }, "calls" => c)
  TC.read_line(j) == [:unparseable, "malformed_json"]
end
check("a Feature paraphrase (no severity) is never recovered: it stays unparseable") do
  TC.read_line("#{P}Kind Feature, Security none (filer: feature)").first == :unparseable
end
check("prose naming a policy decision is lossy_paraphrase (the source is not the filer's)") do
  TC.read_line("#{P}Kind Vulnerability, Severity HIGH, Security pre-existing (policy: vulnerability_floor).") == [:unparseable, "lossy_paraphrase"]
end
check("prose missing a value is unrecognized_prose") do
  TC.read_line("#{P}Kind Bug, Security none (filer: mode_off).") == [:unparseable, "unrecognized_prose"]
end
check("prose with all values but no filer attribution is unrecognized_prose") do
  TC.read_line("#{P}Kind Bug, Severity LOW, Security none.") == [:unparseable, "unrecognized_prose"]
end
check("a truncated JSON line is malformed_json") { TC.read_line("#{P}{\"kind\":{\"val") == [:unparseable, "malformed_json"] }
check("abbreviated JSON with a jev-sourced property is malformed_json, never recovered as the filer's") do
  jevline = P + JSON.generate("kind" => { "value" => "Bug", "source" => "jev" }, "severity" => { "value" => "LOW", "source" => "filer" },
                              "security" => { "value" => "none", "source" => "filer" })
  TC.read_line(jevline) == [:unparseable, "malformed_json"]
end
check("abbreviated JSON with a value outside the tracker's set is malformed_json") do
  bad = P + JSON.generate("kind" => { "value" => "Bugg", "source" => "filer" }, "severity" => { "value" => "LOW", "source" => "filer" },
                          "security" => { "value" => "none", "source" => "filer" })
  TC.read_line(bad) == [:unparseable, "malformed_json"]
end
check("provenance returns [:unparseable, reason] for the LAST line") do
  TC.provenance(ticket(VERBATIM, "#{P}Kind Bug")) == [:unparseable, "unrecognized_prose"]
end
check("line_class names the unparseable reason") { TC.line_class([:unparseable, "lossy_paraphrase"]) == "unparseable_lossy_paraphrase" }
check("every reason and shape is in the closed lists") do
  TC::UNPARSEABLE_REASONS == %w[malformed_json lossy_paraphrase unrecognized_prose] && TC::RECOVERED_SHAPES == %w[abbreviated_json prose_values]
end

puts
puts "#{$checks - $failures.size}/#{$checks} ticket-corpus provenance checks passed"
exit($failures.empty? ? 0 : 1)
