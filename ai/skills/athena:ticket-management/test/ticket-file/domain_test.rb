# frozen_string_literal: true

# Domain suite for filing a ticket with its Jev lines written by the tool,
# never by hand (DND-1669): ../../lib/ticket_filing.rb, pure. Run by
# self-test.sh beside this file. Synthetic ids and text only (this repo is
# public). Fail-first cases carry [regression].

require "json"
require_relative "../../lib/ticket_filing"

TF = TicketFiling
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

def refusal(**kw)
  TF.plan(**DEFAULTS.merge(kw))
  nil
rescue TF::Refused => e
  e
end

CALLS = { "kind" => "00000000-0000-4000-8000-000000000001", "severity" => "00000000-0000-4000-8000-000000000002",
          "security" => "00000000-0000-4000-8000-000000000003" }.freeze
def prop(value, judged) = { "reason" => "no_threshold", "value" => value, "mode" => "on", "accepted" => true, "source" => "jev", "confidence" => 0.9, "judged" => judged }
CL = "Jev classification: " + JSON.generate({ "kind" => prop("Bug", "Bug"), "severity" => prop("LOW", "LOW"), "security" => prop("none", "none"),
                                              "versions" => { "kind" => "ticket-kind-v1", "severity" => "ticket-severity-v2", "security" => "ticket-security-v1" },
                                              "model" => "jev-1.13.0", "calls" => CALLS })
PATHL = 'Jev path: {"path":{"value":"Off","source":"filer","mode":"on"},"call":"00000000-0000-4000-8000-000000000004"}'
TRIAGE = <<~T
  3 candidates considered (DND, project harness)
  call: 00000000-0000-4000-8000-000000000005
  Jev advisory (not a decision): question set finding-triage-v1, model jev-1.13.0, mode on
    questions: cand_0 DND-11, cand_1 DND-12, cand_2 DND-13
    DND-12 (cand_1): related (confidence 0.70) -- a synthetic title
    severity suggestion: LOW (confidence 0.60; a suggestion, not calibrated)
T
PROPS = { "Kind" => { "select" => { "name" => "Bug" } }, "Severity" => { "select" => { "name" => "LOW" } },
          "Security" => { "select" => { "name" => "none" } }, "Path" => { "select" => { "name" => "Off" } },
          "Area" => { "select" => { "name" => "Harness" } } }.freeze
DEFAULTS = { title: "A synthetic finding", body: "Impact: a synthetic impact.\n\nCause: a synthetic cause.\n",
             lines_text: "#{CL}\n#{PATHL}\n", triage_text: TRIAGE, properties: PROPS, allow_no_lines: false }.freeze

def texts(plan) = plan[:blocks].map { |b| TF.block_text(b) }

puts "== plan: what is written"
plan = TF.plan(**DEFAULTS)
check("the body's lines are paragraphs, blank lines dropped, in order") { texts(plan)[0, 2] == ["Impact: a synthetic impact.", "Cause: a synthetic cause."] }
check("the advisory follows under its heading, one paragraph per printed line, byte for byte") do
  i = texts(plan).index("Jev advisory (not a decision)")
  plan[:blocks][i]["type"] == "heading_3" && texts(plan)[i + 1, 6] == TRIAGE.split("\n")
end
check("the Jev lines are the LAST paragraphs, each its own block, byte for byte (readers read the last line)") do
  texts(plan).last(2) == [CL, PATHL] && plan[:blocks].last(2).all? { |b| b["type"] == "paragraph" }
end
check("the title goes into Name; the filer's properties pass through unchanged") do
  plan[:properties]["Name"] == { "title" => [{ "type" => "text", "text" => { "content" => "A synthetic finding" } }] } &&
    PROPS.all? { |k, v| plan[:properties][k] == v }
end
check("a line longer than one rich_text item is split into items that join back byte for byte") do
  long = "x#{'é' * 2500}y"
  b = TF.paragraph(long)
  b["paragraph"]["rich_text"].size > 1 && b["paragraph"]["rich_text"].all? { |t| t["text"]["content"].length <= TF::CHUNK } &&
    b["paragraph"]["rich_text"].map { |t| t["text"]["content"] }.join == long
end
check("with no --triage-file there is no advisory heading") do
  !texts(TF.plan(**DEFAULTS.merge(triage_text: nil))).include?("Jev advisory (not a decision)")
end

puts "== plan: refusals (nothing is written)"
paraphrase = refusal(body: "Impact: x.\nJev classification: Kind Bug, Severity LOW, Security none (jev 0.9).\n")
check("[regression] a body holding a paraphrased Jev classification: line is refused, naming the line") do
  paraphrase && paraphrase.message.include?("body line 2 starts with \"Jev classification: \"") && paraphrase.fix.include?("--lines-file")
end
r = refusal(body: "Impact: x.\n  Jev path: Off (filer)\n")
check("[regression] a body holding a Jev path: line (even indented) is refused") { r && r.message.include?("Jev path: ") }
r = refusal(body: "Impact: x.\nJev advisory (not a decision)\ncall: 00000000-0000-4000-8000-000000000005\n")
check("[regression] a body holding a pasted advisory is refused: the advisory goes in --triage-file") { r && r.fix.include?("--triage-file") }
r = refusal(lines_text: "Jev classification: Kind Bug, Severity LOW, Security none (filer: mode_off).\n")
check("[regression] a lines file whose classification line is a paraphrase is refused (it reads as recovered_prose_values)") do
  r && r.message.include?("recovered_prose_values") && r.fix.include?("ticket-classify --lines-out")
end
r = refusal(lines_text: "#{CL}\nJev path: Off, no blocks\n")
check("a lines file whose Jev path: line is not a JSON object is refused") { r && r.message.include?("Jev path: line is not") }
r = refusal(lines_text: "")
check("an empty lines file is refused: nothing printed is never a pass") { r && r.message.include?("holds no Jev line") && r.fix.include?("--no-jev-lines") }
r = refusal(lines_text: "Kind: Bug\n")
check("a lines file holding a non-Jev line is refused") { r && r.message.include?("not a Jev classification: or Jev path: line") }
check("--no-jev-lines with an empty lines file plans a filing with no Jev line") do
  p = TF.plan(**DEFAULTS.merge(lines_text: "", allow_no_lines: true))
  texts(p).none? { |t| t.start_with?("Jev classification: ", "Jev path: ") }
end
r = refusal(lines_text: "#{CL}\n", allow_no_lines: true)
check("--no-jev-lines with a lines file that has lines is refused (never silently drop them)") { r && r.message.include?("--no-jev-lines") }
r = refusal(properties: PROPS.reject { |k, _| k == "Area" })
check("a missing required property is refused, naming it") { r && r.message.include?("Area") }
r = refusal(properties: PROPS.reject { |k, _| k == "Severity" })
check("Severity is required on a Bug") { r && r.message.include?("Severity") }
check("Severity is not required on a Feature") do
  TF.plan(**DEFAULTS.merge(properties: PROPS.reject { |k, _| k == "Severity" }.merge("Kind" => { "select" => { "name" => "Feature" } })))
end
r = refusal(properties: PROPS.merge("Name" => { "title" => [] }))
check("a Name property is refused: the title comes from --title") { r && r.message.include?("Name") }
r = refusal(properties: [])
check("properties that are not an object are refused") { r && r.message.include?("JSON object") }
r = refusal(title: "two\nlines")
check("a multi-line title is refused") { r && r.message.include?("title") }
r = refusal(title: "  ")
check("a blank title is refused") { r && r.message.include?("title") }
r = refusal(triage_text: "\n")
check("an empty triage file is refused: an unavailable advisory still prints a line") { r && r.message.include?("triage") }

r = refusal(body: "Impact: x.\n### Jev advisory (not a decision)\n")
check("a body opening a line with the advisory heading (markdown marks included) is refused") { r && r.message.include?("body line 2 starts a pasted finding-triage advisory") }
check("prose that only mentions the advisory heading mid-line is not refused") do
  TF.plan(**DEFAULTS.merge(body: "Impact: the Jev advisory (not a decision) block lost its call id.\n"))
end
r = refusal(body: "Impact: x.\ncall: 00000000-0000-4000-8000-000000000005\nJev advisory (not a decision): question set finding-triage-v1, model m, mode on\n")
check("a body holding a call line followed by the advisory header is refused") { r && r.message.include?("body line 2") }

def classes(problems) = problems.map(&:first).uniq.sort

puts "== verify: the read-back"
written = texts(plan)
check("an exact read-back verifies") { TF.verify(written, written, plan[:lines], TRIAGE).empty? }
check("a read-back that differs only in surrounding whitespace verifies") { TF.verify(written, written.map { |t| " #{t} " }, plan[:lines], TRIAGE).empty? }
mangled = written.map { |t| t == CL ? "Jev classification: Kind Bug, Severity LOW, Security none (jev)." : t }
problems = TF.verify(written, mangled, plan[:lines], TRIAGE)
check("[regression] a read-back whose classification line is not the one written fails, naming the line, as :jev") do
  problems.any? { |c, p| c == :jev && p.include?("Jev classification: line is not the one ticket-classify printed") }
end
dropped = written.reject { |t| t == PATHL }
problems = TF.verify(written, dropped, plan[:lines], TRIAGE)
check("a read-back missing the Jev path: line fails as missing") { problems.any? { |c, p| c == :jev && p.include?("no Jev path: line") } }
no_call = written.map { |t| t.start_with?("call: ") ? "call: (see the advisory)" : t }
problems = TF.verify(written, no_call, plan[:lines], TRIAGE)
check("[regression] a read-back whose advisory lost its call id fails as :advisory, and Jev lines still pass") do
  classes(problems) == %i[advisory blocks]
end
problems = TF.verify(written, written + ["an extra block"], plan[:lines], TRIAGE)
check("a read-back with an extra block fails as :blocks") { classes(problems) == [:blocks] && problems[0][1].include?("blocks") }
two = written.each_with_index.map { |t, i| [0, 1].include?(i) ? "#{t} changed" : t }
problems = TF.verify(written, two, plan[:lines], TRIAGE)
check("every differing block is named, not only the first") { problems.any? { |_c, p| p.include?("block(s) 1, 2 ") } }

puts "== repair: the Fix: follows the problem class"
files = { body: "/s/body.txt", lines: "/s/lines.txt", triage: "/s/triage.txt" }
fix = TF.repair(%i[jev blocks], ref: "DND-7", files: files)
check("a Jev problem names ticket-provenance-check with the lines file") do
  fix.start_with?("do not file it again; run ticket-provenance-check --ref DND-7 --lines-file /s/lines.txt")
end
fix = TF.repair(%i[advisory blocks], ref: "DND-7", files: files)
check("[review] an advisory problem names re-appending the advisory, never provenance-check (which cannot see it)") do
  fix.include?("each line of /s/triage.txt") && !fix.include?("ticket-provenance-check")
end
fix = TF.repair(%i[blocks], ref: "DND-7", files: files)
check("a body problem names the body file and the hand correction") { fix.include?("compare DND-7's body with /s/body.txt") && !fix.include?("provenance") }
fix = TF.repair(%i[jev blocks], ref: "DND-7", files: files.merge(lines: nil))
check("[review] under --no-jev-lines the provenance-check step is left out") { !fix.include?("ticket-provenance-check") }
fix = TF.repair(%i[jev], ref: nil, files: files)
check("with no DND id the step never prints an invalid --ref") { !fix.include?("--ref") && fix.include?("/s/lines.txt") }

puts
puts "ticket-file domain: #{$checks - $failures.size} passed, #{$failures.size} failed"
exit($failures.empty? ? 0 : 1)
