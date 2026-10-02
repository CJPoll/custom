# frozen_string_literal: true

# End-to-end suite for scripts/ticket-file (DND-1669): the script against
# fake-notion-filing-server.py, a stateful stand-in for Notion. Never prod.
# Functional only (DND-1222): it blocks on the fake's port file and on each
# exit, never on a timer. Synthetic ids and text only.

require "json"
require "open3"
require "tmpdir"
require "fileutils"

HERE = __dir__
BIN = File.expand_path("../../scripts/ticket-file", HERE)
FAKE = File.join(HERE, "fake-notion-filing-server.py")
DS = "219349da-87fb-8063-8f36-000b362fbd60"
PAGE = "b0000000-0000-4000-8000-000000001669"

$failures = []
$checks = 0

def check(desc, detail = nil)
  $checks += 1
  ok = begin
    yield
  rescue StandardError => e
    puts "FAIL #{desc} (raised #{e.class}: #{e.message})"
    $failures << desc
    return
  end
  $failures << desc unless ok
  puts "#{ok ? 'ok  ' : 'FAIL'} #{desc}"
  puts "     #{detail}" if !ok && detail
end

DIR = Dir.mktmpdir("ticket-file-e2e-")
SPEC = File.join(DIR, "spec")
FileUtils.mkdir_p(SPEC)
TOKEN = "ticket-file-notion-token-#{Process.pid}"
File.write("#{DIR}/notion-token", "#{TOKEN}\n")
File.write("#{DIR}/claude.json", JSON.generate({ "mcpServers" => { "notion-personal" => { "env" => { "NOTION_ATHENA_TOKEN_FILE" => "#{DIR}/notion-token" } } } }))
LOG = File.join(DIR, "server.log")
File.write(LOG, "")

port_file = File.join(DIR, "port")
FAKE_PID = Process.spawn("python3", FAKE, port_file, LOG, SPEC, "#{DIR}/notion-token", err: File::NULL)
at_exit do
  Process.kill("TERM", FAKE_PID)
  Process.wait(FAKE_PID)
rescue StandardError
  nil
ensure
  FileUtils.rm_rf(DIR)
end
port = nil
200.times do
  port = File.read(port_file).strip if File.exist?(port_file)
  break if port && !port.empty?

  IO.select(nil, nil, nil, 0.05)
end
abort "e2e: the fake wrote no port. Fix: run #{FAKE} by hand and read its error" unless port&.match?(/\A\d+\z/)

ENVV = { "FLEET_CLAUDE_JSON" => "#{DIR}/claude.json", "TICKET_FILE_NOTION_API" => "http://127.0.0.1:#{port}", "TICKET_FILE_PACE_S" => "0" }.freeze

def run(*args)
  out, err, status = Open3.capture3(ENVV, BIN, *args)
  [status.exitstatus, out, err]
end

def requests = File.readlines(LOG).map { |l| JSON.parse(l) }

def reset!
  File.write(LOG, "")
  Dir.children(SPEC).each { |f| File.delete(File.join(SPEC, f)) }
end

def spec(name, doc) = File.write(File.join(SPEC, name), JSON.generate(doc))

def file(name, text)
  path = File.join(DIR, name)
  File.write(path, text)
  path
end

CALLS = { "kind" => "00000000-0000-4000-8000-000000000001", "severity" => "00000000-0000-4000-8000-000000000002",
          "security" => "00000000-0000-4000-8000-000000000003" }.freeze
def prop(value) = { "reason" => "no_threshold", "value" => value, "mode" => "on", "accepted" => true, "source" => "jev", "confidence" => 0.9, "judged" => value }
CL = "Jev classification: " + JSON.generate({ "kind" => prop("Bug"), "severity" => prop("LOW"), "security" => prop("none"),
                                              "versions" => { "kind" => "ticket-kind-v1", "severity" => "ticket-severity-v2", "security" => "ticket-security-v1" },
                                              "model" => "jev-1.13.0", "calls" => CALLS })
PATHL = 'Jev path: {"path":{"value":"Off","source":"filer","mode":"on"},"call":"00000000-0000-4000-8000-000000000004"}'
TRIAGE = <<~T
  3 candidates considered (DND, project harness)
  call: 00000000-0000-4000-8000-000000000005
  Jev advisory (not a decision): question set finding-triage-v1, model jev-1.13.0, mode on
    questions: cand_0 DND-11, cand_1 DND-12, cand_2 DND-13
    severity suggestion: LOW (confidence 0.60; a suggestion, not calibrated)
T
PROPS = { "Kind" => { "select" => { "name" => "Bug" } }, "Severity" => { "select" => { "name" => "LOW" } },
          "Security" => { "select" => { "name" => "none" } }, "Path" => { "select" => { "name" => "Off" } },
          "Area" => { "select" => { "name" => "Harness" } }, "Control" => { "select" => { "name" => "none" } } }.freeze

BODY = file("body.txt", "Impact: a synthetic impact.\n\nCause: a synthetic cause.\n")
LINES = file("lines.txt", "#{CL}\n#{PATHL}\n")
TRIAGE_F = file("triage.txt", TRIAGE)
PROPS_F = file("props.json", JSON.generate(PROPS))
ARGS = ["--title", "A synthetic finding", "--body-file", BODY, "--properties-file", PROPS_F, "--lines-file", LINES, "--triage-file", TRIAGE_F].freeze

def stored_texts
  r = requests.find { |x| x["method"] == "POST" && x["path"] == "/v1/pages" }
  r ? r["body"]["children"].map { |b| b[b["type"]]["rich_text"].map { |t| t["text"]["content"] }.join } : []
end

puts "== a verbatim filing"
reset!
rc, out, err = run(*ARGS)
check("[regression] a filing exits 0 only after the page read back is what was written", "rc #{rc} out #{out} err #{err}") do
  rc.zero? && out.include?("filed: DND-1669 https://example.invalid/p/") &&
    out.include?("verified: DND-1669's page is what was written (2 Jev lines, advisory call 00000000-0000-4000-8000-000000000005)")
end
check("it created the page in DND Tickets with the title and the filer's properties") do
  r = requests.find { |x| x["method"] == "POST" && x["path"] == "/v1/pages" }
  r && r["body"]["parent"] == { "type" => "data_source_id", "data_source_id" => DS } &&
    r["body"]["properties"]["Name"]["title"][0]["text"]["content"] == "A synthetic finding" &&
    PROPS.all? { |k, v| r["body"]["properties"][k] == v }
end
check("each Jev line went in as its own paragraph, byte for byte, last") { stored_texts.last(2) == [CL, PATHL] }
check("the advisory went in under its heading, line for line") { stored_texts.include?("Jev advisory (not a decision)") && stored_texts.include?("call: 00000000-0000-4000-8000-000000000005") }
check("every request carried the token in its header, and no token reached argv or the environment") do
  r = requests
  r.size >= 2 && r.none? { |x| x["unexpected"] } && r.all? { |x| x["auth_ok"] } && r.all? { |x| x["argv_leak"].empty? && x["environ_leak"].empty? }
end

puts "== the inputs a hand filing got wrong (nothing written)"
reset!
para = file("para-body.txt", "Impact: x.\nJev classification: Kind Bug, Severity LOW, Security none (jev 0.9).\n")
rc, out, err = run("--title", "T", "--body-file", para, "--properties-file", PROPS_F, "--lines-file", LINES)
check("[regression] a body holding a paraphrased classification line is refused, exit 2, with Fix:, nothing sent", "rc #{rc} out #{out} err #{err}") do
  rc == 2 && err.include?("REFUSED, nothing written: body line 2 starts with \"Jev classification: \"") && err.include?("Fix:") && requests.empty?
end
para_lines = file("para-lines.txt", "Jev classification: Kind Bug, Severity LOW, Security none (filer: mode_off).\n")
rc, _out, err = run("--title", "T", "--body-file", BODY, "--properties-file", PROPS_F, "--lines-file", para_lines)
check("[regression] a hand-edited lines file is refused, exit 2, nothing sent", "rc #{rc} err #{err}") do
  rc == 2 && err.include?("reads as recovered_prose_values") && requests.empty?
end
no_area = file("no-area.json", JSON.generate(PROPS.reject { |k, _| k == "Area" }))
rc, _out, err = run("--title", "T", "--body-file", BODY, "--properties-file", no_area, "--lines-file", LINES)
check("a missing property is refused, exit 2") { rc == 2 && err.include?("has no Area") && requests.empty? }
rc, _out, err = run("--title", "T", "--body-file", BODY, "--properties-file", PROPS_F)
check("--lines-file is required") { rc == 2 && err.include?("--lines-file is required") }
empty = file("empty-lines.txt", "")
rc, _out, err = run("--title", "T", "--body-file", BODY, "--properties-file", PROPS_F, "--lines-file", empty)
check("an empty lines file without --no-jev-lines is refused") { rc == 2 && err.include?("--no-jev-lines") && requests.empty? }
rc, out, = run("--title", "T", "--body-file", BODY, "--properties-file", PROPS_F, "--lines-file", empty, "--no-jev-lines")
check("--no-jev-lines with the empty file classify left files the ticket and verifies it", "rc #{rc} out #{out}") do
  rc.zero? && out.include?("(0 Jev lines, advisory none)")
end

puts "== Notion stored something else, or failed"
reset!
spec("mangle.json", { "from" => '"severity":{"reason"', "to" => '"severity": {"reason"' })
rc, out, err = run(*ARGS)
check("[regression] a page whose classification line reads back changed exits 4 naming DND-N and the line, on stderr", "rc #{rc} out #{out} err #{err}") do
  rc == 4 && err.include?("ticket-file: FILED, NOT VERBATIM: DND-1669:") && err.include?("Jev classification: line is not the one ticket-classify printed") &&
    err.include?("Fix: do not file it again; run ticket-provenance-check --ref DND-1669 --lines-file #{LINES}") && out.include?("filed: DND-1669")
end
reset!
spec("mangle.json", { "from" => "call: 00000000-0000-4000-8000-000000000005", "to" => "call: unavailable" })
rc, _out, err = run(*ARGS)
check("[review] an advisory that lost its call id exits 4 and its Fix: re-appends the advisory, not provenance-check", "rc #{rc} err #{err}") do
  rc == 4 && err.include?("advisory does not read as finding-triage's output") && err.include?("each line of #{TRIAGE_F}") &&
    !err.include?("ticket-provenance-check")
end
reset!
spec("create.json", { "status" => 400, "body" => { "message" => "validation failed" } })
rc, out, err = run(*ARGS)
check("a create Notion refuses (4xx) is NOT FILED, exit 3, with Fix:") { rc == 3 && err.include?("NOT FILED") && err.include?("Fix:") && out.empty? }
reset!
spec("create.json", { "status" => 502, "body" => {} })
rc, _out, err = run(*ARGS)
check("a create that failed after it was sent (5xx) is MAY BE FILED and is never retried", "rc #{rc} err #{err}") do
  rc == 3 && err.include?("MAY BE FILED") && requests.count { |x| x["path"] == "/v1/pages" } == 1
end
reset!
spec("read.json", { "status" => 400, "body" => {} })
rc, out, err = run(*ARGS)
check("a failed read-back is FILED, UNVERIFIED naming DND-N, exit 3", "rc #{rc} out #{out} err #{err}") do
  rc == 3 && out.include?("filed: DND-1669") && err.include?("FILED, UNVERIFIED: DND-1669") && err.include?("ticket-provenance-check --ref DND-1669")
end

puts "== a long body (more than one create's worth of blocks)"
reset!
wide = "w#{"\u{1F600}" * 2500}w" # 5002 UTF-16 units: over the 2000 per item a fake enforces
long = file("long-body.txt", ((1..150).map { |i| "Line #{i} of a synthetic body." } + [wide]).join("\n"))
rc, out, = run("--title", "Long", "--body-file", long, "--properties-file", PROPS_F, "--lines-file", LINES)
check("blocks past the first 100 are appended in order, the Jev lines still last, and it verifies", "rc #{rc} out #{out}") do
  appends = requests.select { |x| x["method"] == "PATCH" }
  rc.zero? && appends.size == 1 && appends[0]["body"]["children"].last(2).map { |b| b["paragraph"]["rich_text"].map { |t| t["text"]["content"] }.join } == [CL, PATHL]
end

puts "== partial writes"
reset!
spec("append.json", { "status" => 502, "body" => {} })
rc, out, err = run("--title", "Long", "--body-file", long, "--properties-file", PROPS_F, "--lines-file", LINES)
check("[critic] a failed append is FILED, INCOMPLETE naming DND-N, never MAY BE FILED, with one create only", "rc #{rc} out #{out} err #{err}") do
  rc == 3 && err.include?("FILED, INCOMPLETE: DND-1669") && err.include?("Fix: do not file it again") && !err.include?("MAY BE FILED") &&
    requests.count { |x| x["method"] == "POST" && x["path"] == "/v1/pages" } == 1 && requests.count { |x| x["method"] == "PATCH" } == 1
end
reset!
spec("create.json", { "status" => 200, "body" => { "object" => "page" } })
rc, _out, err = run(*ARGS)
check("[critic] a create answered with no page id is MAY BE FILED, exit 3, and nothing more is sent", "rc #{rc} err #{err}") do
  rc == 3 && err.include?("MAY BE FILED: Notion answered the create with no page id") && requests.size == 1
end
require_relative "../../../../lib/notion_write"
before = requests.size
refused = begin
  NotionWrite.write("http://127.0.0.1:#{port}", TOKEN, "GET", "/v1/pages", nil)
  nil
rescue NotionWrite::Refused => e
  e
end
check("[critic] the write client refuses any other request before sending it (NotionWrite::Refused, the class ticket-file reads as NOT FILED)") do
  refused && refused.message.include?("only creates pages and appends blocks") && requests.size == before
end

puts "== dry run and help"
reset!
rc, out, = run(*ARGS, "--dry-run")
check("--dry-run checks every input, prints the plan and sends nothing") { rc.zero? && out.include?("DRY RUN: would file") && requests.empty? }
rc, out, = run("--help")
check("--help prints the usage on stdout, exit 0, no request") { rc.zero? && out.include?("Usage: ticket-file") && requests.empty? }

puts
puts "ticket-file e2e: #{$checks - $failures.size} passed, #{$failures.size} failed"
exit($failures.empty? ? 0 : 1)
