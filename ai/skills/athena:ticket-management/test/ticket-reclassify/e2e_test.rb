# frozen_string_literal: true

# End-to-end suite for ticket-reclassify (DND-1056): the script as a process
# against one loopback fake (fake-server.py) standing in for Notion's reads
# and the classification endpoint. Never prod: every URL is 127.0.0.1, and
# both tokens, the MCP registry and the inbox client config are temp fixtures.

require "json"
require "open3"
require "tmpdir"
require_relative "fakes"

BIN = SCRIPT
FAKE = File.expand_path("fake-server.py", __dir__)
DIR = Dir.mktmpdir("reclassify-e2e-")
NOTION_TOKEN = "reclassify-notion-token-#{Process.pid}-#{rand(1 << 30)}"
ATHENA_TOKEN = "reclassify-athena-token-#{Process.pid}-#{rand(1 << 30)}"

$server_pid = nil
at_exit do
  if $server_pid
    Process.kill("TERM", $server_pid)
    Process.wait($server_pid)
  end
  FileUtils.rm_rf(DIR)
end

def block(text) = { "type" => "paragraph", "paragraph" => { "rich_text" => [{ "plain_text" => text }] } }

# The fixture: DND-1 open and answered with a change, DND-2 closed, DND-3 open
# with a body of two block pages whose LAST page holds a matching line in
# mode on at the server's version now (already classified once known).
tickets = [ticket(number: 1, lines: ["Body one."]), ticket(number: 2, status: "Done"),
           ticket(number: 3, lines: ["Body three."])]
notion = FakeNotion.new(tickets)
decided1 = VALUES.merge("severity" => "LOW")
fixture = {
  "notion_token" => NOTION_TOKEN, "athena_token" => ATHENA_TOKEN,
  "data_sources" => { Effects::PROJECTS_DATA_SOURCE => notion.project_rows, Effects::TICKETS_DATA_SOURCE => tickets.map { |t| notion.row(t) } },
  "blocks" => { page_id(1) => [[block("Body one.")]], page_id(2) => [[block("Closed.")]],
                page_id(3) => [[block("Body three.")], [block(line(VALUES, "on"))]] },
  "pages" => {
    page_id(1) => { "properties" => { "Kind" => { "select" => { "name" => "Bug" } }, "Severity" => { "select" => { "name" => "LOW" } },
                                      "Security" => { "select" => { "name" => "none" } } } }
  },
  "answers" => { "DND-1" => answer(decided1, "on"), "DND-3" => answer(VALUES, "on") }
}
File.write("#{DIR}/fixture.json", JSON.generate(fixture))
File.write("#{DIR}/notion-token", "#{NOTION_TOKEN}\n")
File.write("#{DIR}/inbox.json", JSON.generate({ "token" => ATHENA_TOKEN }))
log = "#{DIR}/requests.log"
port_file = "#{DIR}/port"
$server_pid = Process.spawn("python3", FAKE, port_file, log, "#{DIR}/fixture.json", out: File::NULL, err: File::NULL)
# Wait for the fake to bind: a bounded poll on the port file it writes.
200.times do
  break if File.exist?(port_file)

  sleep 0.05
end
abort "e2e: the fake server never wrote its port. Fix: check python3 and #{FAKE}" unless File.exist?(port_file)
port = File.read(port_file).strip
File.write("#{DIR}/claude.json", JSON.generate({ "mcpServers" => {
                                                   "athena" => { "type" => "http", "url" => "http://127.0.0.1:#{port}/mcp" },
                                                   "notion-personal" => { "env" => { "NOTION_ATHENA_TOKEN_FILE" => "#{DIR}/notion-token" } }
                                                 } }))
ENV_VARS = {
  "FLEET_CLAUDE_JSON" => "#{DIR}/claude.json", "ATHENA_INBOX_CLIENT_CONFIG" => "#{DIR}/inbox.json",
  "TICKET_RECLASSIFY_NOTION_API" => "http://127.0.0.1:#{port}", "TICKET_RECLASSIFY_PACE_S" => "0",
  "TICKET_RECLASSIFY_CALL_INTERVAL_S" => "0"
}.freeze

def run(*args)
  out, err, status = Open3.capture3(ENV_VARS, BIN, *args, chdir: DIR)
  [status.exitstatus, out, err]
end

section "argv"

check("--help prints usage on stdout, exit 0, and runs nothing") do
  File.delete(log) if File.exist?(log)
  code, out, err = run("--help")
  code.zero? && out.start_with?("Usage: ticket-reclassify plan") && err.empty? && !File.exist?(log)
end
check("no command is usage, exit 2, with Fix:") do
  code, _, err = run("--out", "#{DIR}/x.json")
  code == 2 && err.include?("pass exactly one command, plan or proof") && err.include?("Fix:")
end
check("plan needs --out") { run("plan").then { |code, _, err| code == 2 && err.include?("plan needs --out FILE. Fix:") } }
check("the command may follow its flags (order never matters)") { run("--against", "#{DIR}/none.json", "proof").then { |code, _, err| code == 1 && err.include?("does not exist. Fix:") } }
check("a flag of the other command is refused") { run("proof", "--against", "#{DIR}/p.json", "--limit", "3").then { |code, _, err| code == 2 && err.include?("proof does not take --limit") } }
check("a malformed cursor is refused") { run("plan", "--out", "#{DIR}/p.json", "--resume-from", "12").then { |code, _, err| code == 2 && err.include?("is not a DND ticket id") } }

section "plan"

code, out, = run("plan", "--out", "#{DIR}/plan.json")
plan = File.exist?("#{DIR}/plan.json") ? JSON.parse(File.read("#{DIR}/plan.json")) : {}
requests = File.exist?(log) ? File.readlines(log, chomp: true) : []

check("plan exits 0 over the fixture") { code.zero? }
check("plan reads to the LAST block page: DND-3's line there makes it already classified") do
  plan.dig("skipped_refs", "already_classified") == ["DND-3"] && requests.any? { |r| r.include?("start_cursor=") }
end
check("plan writes DND-1's decision and counts the closed ticket") do
  plan["entries"].map { |e| e["ref"] } == ["DND-1"] && plan.dig("counts", "skipped", "closed") == 1 && out.include?("changes: Severity MEDIUM->LOW: 1")
end
check("only read requests reach Notion [qa plan 8]") do
  notion_reqs = requests.reject { |r| r.start_with?("POST /api/v1/judgments/ticket_classification ") }
  notion_reqs.all? { |r| %r{\A(POST /v1/data_sources/[0-9a-f-]{36}/query|GET /v1/blocks/[0-9a-f-]{36}/children\?page_size=100(&start_cursor=[0-9a-f-]{36})?|GET /v1/pages/[0-9a-f-]{36}) AUTH_OK\z}.match?(r) } &&
    notion_reqs.size.positive?
end
check("the classification call carries the Athena token, and the closed ticket's body is never read") do
  requests.select { |r| r.start_with?("POST /api/") }.all? { |r| r.end_with?("AUTH_OK") } && requests.none? { |r| r.include?(page_id(2)) }
end
check("neither token reaches the plan file or the output") do
  text = File.read("#{DIR}/plan.json") + out
  !text.include?(NOTION_TOKEN) && !text.include?(ATHENA_TOKEN)
end
check("the plan file is 0600 [qa plan 7]") { File.stat("#{DIR}/plan.json").mode & 0o777 == 0o600 }

section "proof"

check("proof reads the page and its blocks; DND-1 lacks its line (exit 4, named)") do
  code, out, = run("proof", "--against", "#{DIR}/plan.json")
  code == 4 && out.include?("MISMATCH DND-1: the body has no Jev classification: line") && File.readlines(log).any? { |r| r.start_with?("GET /v1/pages/#{page_id(1)} ") }
end
check("proof passes once the fixture page carries the line (exit 0)") do
  fixture["blocks"][page_id(1)] = [[block("Body one."), block(line(decided1, "on"))]]
  File.write("#{DIR}/fixture2.json", JSON.generate(fixture))
  # A second fake over the applied fixture.
  port2 = "#{DIR}/port2"
  pid2 = Process.spawn("python3", FAKE, port2, "#{DIR}/requests2.log", "#{DIR}/fixture2.json", out: File::NULL, err: File::NULL)
  begin
    200.times do
      break if File.exist?(port2)

      sleep 0.05
    end
    env = ENV_VARS.merge("TICKET_RECLASSIFY_NOTION_API" => "http://127.0.0.1:#{File.read(port2).strip}")
    out, _err, status = Open3.capture3(env, BIN, "proof", "--against", "#{DIR}/plan.json", chdir: DIR)
    status.exitstatus.zero? && out.include?("1 entries (planned 1, unchanged 0), 1 match, 0 mismatch")
  ensure
    Process.kill("TERM", pid2)
    Process.wait(pid2)
  end
end

finish("ticket-reclassify e2e")
