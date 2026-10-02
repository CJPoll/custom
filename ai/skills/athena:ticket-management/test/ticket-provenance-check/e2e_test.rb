# frozen_string_literal: true

# End-to-end suite for scripts/ticket-provenance-check (DND-1354): the script
# against ../fake-triage-server.py standing in for Notion's reads. Never
# prod. Functional only (DND-1222): it blocks on the fake's port file being
# written and on each exit, never on a timer. Synthetic ids and text only.

require "json"
require "open3"
require "tmpdir"
require "fileutils"

HERE = __dir__
BIN = File.expand_path("../../scripts/ticket-provenance-check", HERE)
FAKE = File.expand_path("../fake-triage-server.py", HERE)
DS = "219349da-87fb-8063-8f36-000b362fbd60"
PAGE = "a0000000-0000-4000-8000-000000001354"

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

DIR = Dir.mktmpdir("provenance-check-e2e-")
SPEC = File.join(DIR, "spec")
FileUtils.mkdir_p(SPEC)
NOTION_TOKEN = "provenance-notion-token-#{Process.pid}"
File.write("#{DIR}/notion-token", "#{NOTION_TOKEN}\n")
File.write("#{DIR}/athena-token", "unused-athena-#{Process.pid}\n")
File.write("#{DIR}/claude.json", JSON.generate({ "mcpServers" => { "notion-personal" => { "env" => { "NOTION_ATHENA_TOKEN_FILE" => "#{DIR}/notion-token" } } } }))
LOG = File.join(DIR, "server.log")
File.write(LOG, "")

# The fake writes its port to the port file once it listens; block on the
# file's content with a bounded read of the fake's own pipe-free signal.
port_file = File.join(DIR, "port")
FAKE_PID = Process.spawn("python3", FAKE, port_file, LOG, SPEC, "#{DIR}/athena-token", "#{DIR}/notion-token", err: File::NULL)
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

ENVV = { "FLEET_CLAUDE_JSON" => "#{DIR}/claude.json", "TICKET_PROVENANCE_CHECK_NOTION_API" => "http://127.0.0.1:#{port}",
         "TICKET_PROVENANCE_CHECK_PACE_S" => "0" }.freeze

def spec(name, doc) = File.write(File.join(SPEC, name), JSON.generate(doc))

def row(number) = { "id" => PAGE, "properties" => { "ID" => { "unique_id" => { "prefix" => "DND", "number" => number } } } }

def block(text) = { "type" => "paragraph", "paragraph" => { "rich_text" => [{ "plain_text" => text }] } }

def tracker(rows, texts)
  spec("query-#{DS}.json", { "status" => 200, "body" => { "results" => rows, "has_more" => false } })
  spec("blocks-#{PAGE}.json", { "status" => 200, "body" => { "results" => texts.map { |t| block(t) }, "has_more" => false } })
end

def run(*args)
  out, err, status = Open3.capture3(ENVV, BIN, *args)
  [status.exitstatus, out, err]
end

def requests = File.readlines(LOG).map { |l| JSON.parse(l) }

CL = 'Jev classification: {"kind":{"reason":"mode_off","value":"Bug","mode":"off","accepted":false,"source":"filer","confidence":null,"judged":null},' \
     '"severity":{"reason":"mode_off","value":"LOW","mode":"off","accepted":false,"source":"filer","confidence":null,"judged":null},' \
     '"security":{"reason":"mode_off","value":"none","mode":"off","accepted":false,"source":"filer","confidence":null,"judged":null},' \
     '"versions":{"kind":"ticket-kind-v1","severity":"ticket-severity-v1","security":"ticket-security-v1"},"model":"jev-1.13.0"}'
LINES = File.join(DIR, "lines.txt")
File.write(LINES, "#{CL}\n")

puts "== verbatim"
tracker([row(1354)], ["Synthetic body.", CL])
rc, out, err = run("--ref", "DND-1354", "--lines-file", LINES)
check("a verbatim line exits 0 and says so [ticket 1354]", "rc #{rc} out #{out} err #{err}") do
  rc.zero? && out.include?("verbatim: DND-1354's last Jev classification: line is the one ticket-classify printed")
end
check("it queried the tracker by the ticket's ID and read only (no write request)") do
  r = requests
  q = r.find { |x| x["path"] == "/v1/data_sources/#{DS}/query" }
  q && q["body"]["filter"] == { "property" => "ID", "unique_id" => { "equals" => 1354 } } &&
    r.none? { |x| x["unexpected"] } && r.all? { |x| x["auth_ok"] } && r.all? { |x| x["argv_leak"].empty? && x["environ_leak"].empty? }
end

puts "== not verbatim [ticket 1354]"
tracker([row(1354)], ["Synthetic body.", "Jev classification: Kind Bug, Severity LOW, Security none (filer: mode_off)."])
rc, out, = run("--lines-file", LINES, "--ref", "DND-1354")
check("a paraphrase exits 4, names how it reads and says what to append (flags in any order)", "rc #{rc} out #{out}") do
  rc == 4 && out.include?("NOT VERBATIM: DND-1354's last Jev classification: line is not the one ticket-classify printed (it reads as recovered_prose_values)") &&
    out.include?("Fix: append ONE paragraph to DND-1354 whose text is exactly line 1 of #{LINES}")
end
tracker([row(1354)], ["Synthetic body.", CL.sub('"LOW"', '"HIGH"')])
rc, out, = run("--ref", "DND-1354", "--lines-file", LINES)
check("a well-formed line from another run is NOT VERBATIM and says so, never 'reads as verbatim'", "rc #{rc} out #{out}") do
  rc == 4 && out.include?("(the body's line is well formed but not this one byte for byte: another run, or a re-serialised copy)") && !out.include?("reads as verbatim")
end
tracker([row(1354)], ["Synthetic body."])
File.write(LINES, "#{CL}\nJev path: {\"path\":{\"decided\":\"Off\"}}\n")
rc, out, = run("--ref", "DND-1354", "--lines-file", LINES)
check("no line is MISSING, per line, exit 4", "rc #{rc} out #{out}") do
  rc == 4 && out.include?("MISSING: DND-1354 has no Jev classification: line.") && out.include?("MISSING: DND-1354 has no Jev path: line.")
end
File.write(LINES, "#{CL}\n")

puts "== usage and unreadable"
tracker([], [])
rc, out, err = run("--ref", "DND-1354", "--lines-file", LINES)
check("an id matching no ticket is usage (2) with Fix:, never 'no line'", "rc #{rc} out #{out} err #{err}") do
  rc == 2 && err.include?("DND-1354 matches no ticket") && err.include?("Fix:") && out.empty?
end
File.write(File.join(DIR, "empty.txt"), "")
rc, _out, err = run("--ref", "DND-1354", "--lines-file", File.join(DIR, "empty.txt"))
check("an empty lines file is usage (2): nothing to check is never a pass") { rc == 2 && err.include?("holds no Jev line") && err.include?("Fix:") }
rc, _out, err = run("--ref", "DND-1354", "--lines-file", File.join(DIR, "nope.txt"))
check("a missing lines file is usage (2)") { rc == 2 && err.include?("does not exist") }
rc, _out, err = run("--ref", "DND1354", "--lines-file", LINES)
check("an id that is not DND-N is usage (2)") { rc == 2 && err.include?("is not a DND ticket id") }
rc, _out, err = run("--lines-file", LINES)
check("--ref is required") { rc == 2 && err.include?("--ref is required") }
# A permanent Notion failure (a 4xx other than 429 is never retried), so no
# real retry wait runs here. The transient path (429/5xx, retried, then the
# same failure) is proven with an injected wait in ai/lib/test/notion-read
# (DND-1649).
spec("query-#{DS}.json", { "status" => 400, "body" => {} })
rc, out, err = run("--ref", "DND-1354", "--lines-file", LINES)
check("a Notion failure is exit 3 with Fix:, nothing compared", "rc #{rc} out #{out} err #{err}") do
  rc == 3 && err.include?("COULD NOT READ NOTION") && err.include?("Fix:") && out.empty?
end
before = requests.size
rc, out, = run("--help")
check("--help prints the usage on stdout, exit 0, no request") { rc.zero? && out.include?("Usage: ticket-provenance-check") && requests.size == before }

puts
puts "ticket-provenance-check e2e: #{$checks - $failures.size} passed, #{$failures.size} failed"
exit($failures.empty? ? 0 : 1)
