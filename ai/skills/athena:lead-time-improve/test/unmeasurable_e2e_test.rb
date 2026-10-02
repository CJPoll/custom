# frozen_string_literal: true

# End-to-end suite for scripts/unmeasurable (DND-1806): the real script, its
# real Notion port against fake-notion-tickets-server.py, and its real alert
# port (ai/lib/harness-alert-send.sh) against a fake send-mail that records
# what it was asked to send. Never prod: no live Notion write, no live alert.
#
# The fixture is the state the ticket names: a phase that stays the biggest
# and unmeasurable while its hand-off ticket is open. The 3rd run promotes the
# ticket and alerts once; the 4th does neither; landing the ticket ends the
# episode (~/dev/custom/CLAUDE.md -> A claimed mechanism must be able to fire).
#
# Functional only (DND-1222): it blocks on the fake's port file and on each
# exit, never on a timer. Synthetic ids only.

require "json"
require "open3"
require "tmpdir"
require "fileutils"

HERE = __dir__
BIN = File.expand_path("../scripts/unmeasurable", HERE)
FAKE = File.join(HERE, "fake-notion-tickets-server.py")
PAGE = "c0000000-0000-4000-8000-000000009001"

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

DIR = Dir.mktmpdir("unmeasurable-e2e-")
TOKEN = "unmeasurable-notion-token-#{Process.pid}"
File.write("#{DIR}/notion-token", "#{TOKEN}\n")
File.write("#{DIR}/claude.json", JSON.generate({ "mcpServers" => { "notion-personal" => { "env" => { "NOTION_ATHENA_TOKEN_FILE" => "#{DIR}/notion-token" } } } }))
TICKETS = File.join(DIR, "tickets.json")
LOG = File.join(DIR, "server.log")
File.write(LOG, "")
SENT = File.join(DIR, "sent")
FileUtils.mkdir_p(SENT)

# The fake send-mail: prints the delivered line send-mail prints, and keeps a
# copy of each body, named by its slug, so the suite can count the sends.
FAKE_SEND = File.join(DIR, "send-mail")
File.write(FAKE_SEND, <<~SH)
  #!/usr/bin/env bash
  set -u
  slug="$3"; body=""
  while [ $# -gt 0 ]; do [ "$1" = "--body-file" ] && body="$2"; shift; done
  n="$(find "#{SENT}" -type f | wc -l)"
  name="20261002T000000Z-$n-${slug}.md"
  cp -- "${body}" "#{SENT}/${name}"
  echo "athena:inbox: path: local -- fake"
  echo "athena:inbox: delivered ${name}"
SH
File.chmod(0o755, FAKE_SEND)

def write_tickets(doc) = File.write(TICKETS, JSON.generate(doc))

write_tickets({ "9001" => { "id" => PAGE, "status" => "In Progress", "path" => "Off" } })
port_file = File.join(DIR, "port")
FAKE_PID = Process.spawn("python3", FAKE, port_file, LOG, TICKETS, "#{DIR}/notion-token", err: File::NULL)
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
abort "FAIL the fake Notion never wrote its port\nFix: check python3 runs #{FAKE}" if port.nil? || port.empty?

def summary_file(name, repo: "custom", queue: [5, 15])
  phases = { "implement" => [14, 6], "verify" => [9, 11], "queue" => queue, "integrate" => [15, 5], "merge" => [13, 7] }
  doc = { "repo" => repo, "biggest" => { "phase" => "queue", "sum_s" => 21_572 },
          "phases" => phases.to_h { |p, (n, na)| [p, { "n" => n, "n_na" => na, "sum_s" => 100 }] } }
  path = File.join(DIR, "#{name}.json")
  File.write(path, JSON.generate(doc))
  path
end

def env_for(state, port)
  { "LEAD_TIME_STATE_DIR" => state, "LEADTIME_UNMEASURABLE_NOTION_API" => "http://127.0.0.1:#{port}",
    "FLEET_CLAUDE_JSON" => "#{DIR}/claude.json", "LEADTIME_SEND_MAIL" => FAKE_SEND }
end

def tool(env, *args)
  out, err, st = Open3.capture3(env, "/usr/bin/ruby", BIN, *args)
  [st.exitstatus, out, err]
end

def requests = File.readlines(LOG).map { |l| JSON.parse(l) }
def writes = requests.select { |r| r["method"] == "PATCH" }
def path_patches = writes.count { |r| r["path"].start_with?("/v1/pages/") }
def notes = writes.count { |r| r["path"].start_with?("/v1/blocks/") }
def sends = Dir.children(SENT).sort

STATE = File.join(DIR, "state")
FileUtils.mkdir_p(STATE)
ENVS = env_for(STATE, port)
SUM = summary_file("sum")

code, out, err = tool(ENVS, "--help")
check("--help: exit 0 on stdout, nothing written") { code.zero? && out.include?("unmeasurable observe") && !File.exist?(File.join(STATE, "unmeasurable.json")) }

code, out, = tool(ENVS, "handoff", "--repo", "custom", "--phase", "queue", "--ticket", "DND-9001")
check("handoff: records the hand-off ticket", out) { code.zero? && out.include?("ticket=DND-9001 recorded") }

r1 = tool(ENVS, "observe", "--repo", "custom", "--run", "run-1", "--summary-file", SUM)
r2 = tool(ENVS, "observe", "--repo", "custom", "--run", "run-2", "--summary-file", SUM)
check("runs 1 and 2: COUNTING, exit 0", r2[1]) { r1[0].zero? && r2[0].zero? && r2[1].include?("phase=queue runs=2 ticket=DND-9001 status=\"In Progress\" outcome=COUNTING") }
check("runs 1 and 2: the ticket is read each run, nothing written, nothing sent") { requests.size == 2 && writes.empty? && sends.empty? }

code, out, = tool(ENVS, "observe", "--repo", "custom", "--run", "run-3", "--summary-file", SUM)
check("run 3: ESCALATED, exit 0", out) { code.zero? && out.include?("runs=3 ticket=DND-9001 status=\"In Progress\" outcome=ESCALATED") }
check("run 3: promotes the ticket: one Path PATCH, Path is now Promoted") { path_patches == 1 && JSON.parse(File.read(TICKETS))["9001"]["path"] == "Promoted" }
check("run 3: records the promotion on the ticket: one note") { notes == 1 }
check("run 3: the note names DND-1806 and the run") { writes.find { |r| r["path"].start_with?("/v1/blocks/") }.to_json.then { |j| j.include?("DND-1806") && j.include?("run-3") } }
check("run 3: sends ONE harness-alerts message, slug leadtime-unmeasurable", sends.inspect) { sends.size == 1 && sends[0].end_with?("-leadtime-unmeasurable.md") }
body = sends.empty? ? "" : File.read(File.join(SENT, sends[0]))
check("run 3: the alert names the repo, the phase, the ticket and the run count", body) do
  ["repo: custom", "phase: queue", "ticket: DND-9001", "counted_runs: 3", "Fix:"].all? { |w| body.include?(w) }
end
record = body[/^record: (.*)$/, 1].to_s
check("run 3: the alert's record exists in the state dir's runs/", record) { record.start_with?(File.join(STATE, "runs")) && File.read(record).include?("runs=3") }
check("run 3: its journal line names the promotion", out) { out.include?("journal:") && out.include?("promoted DND-9001 to Path Promoted") }

code, out, = tool(ENVS, "observe", "--repo", "custom", "--run", "run-4", "--summary-file", SUM)
check("run 4: ESCALATED-EARLIER, exit 0", out) { code.zero? && out.include?("runs=4") && out.include?("outcome=ESCALATED-EARLIER") }
check("run 4: neither promotes nor notes nor alerts") { path_patches == 1 && notes == 1 && sends.size == 1 }

write_tickets({ "9001" => { "id" => PAGE, "status" => "Done", "path" => "Promoted" } })
code, out, = tool(ENVS, "observe", "--repo", "custom", "--run", "run-5", "--summary-file", SUM)
check("landing (Status Done): HANDOFF-LANDED, the count resets, exit 0", out) { code.zero? && out.include?("runs=0") && out.include?("outcome=HANDOFF-LANDED") }
check("landing: nothing written or sent") { path_patches == 1 && notes == 1 && sends.size == 1 }
status = JSON.parse(tool(ENVS, "status", "--repo", "custom")[1])
check("status: the episode is over and the ticket is marked landed") { status["custom/queue"]["episode"].nil? && status["custom/queue"]["ticket_landed"] == true }

reqs_before = requests.size
code, out, = tool(ENVS, "observe", "--repo", "custom", "--run", "run-6", "--summary-file", SUM)
check("after landing, still unmeasurable: counts again, no Notion read, nothing sent", out) do
  code.zero? && out.include?("runs=1") && out.include?("outcome=HANDOFF-LANDED") && sends.size == 1 && requests.size == reqs_before
end
code, out, = tool(ENVS, "observe", "--repo", "custom", "--run", "run-7", "--summary-file", summary_file("meas", queue: [15, 5]))
check("then a measurable queue: MEASURABLE, the count reset, exit 0", out) { code.zero? && out.include?("runs=0") && out.include?("outcome=MEASURABLE") }

# A run that cannot read the ticket.
STATE2 = File.join(DIR, "state2")
FileUtils.mkdir_p(STATE2)
E2 = env_for(STATE2, port)
tool(E2, "handoff", "--repo", "custom", "--phase", "queue", "--ticket", "DND-9001")
write_tickets({ "9001" => { "id" => PAGE, "status" => "In Progress", "path" => "Off" }, "fail" => 403 })
code, out, err = tool(E2, "observe", "--repo", "custom", "--run", "run-1", "--summary-file", SUM)
check("Notion refuses the read: COULD-NOT-LOOK, exit 3", out) { code == 3 && out.include?("outcome=COULD-NOT-LOOK") }
check("... never 'already handed off', and the Fix: says so", out + err) { !out.include?("already handed off") && err.include?("Fix:") }

# A promotion Notion refuses.
STATE3 = File.join(DIR, "state3")
FileUtils.mkdir_p(STATE3)
E3 = env_for(STATE3, port)
tool(E3, "handoff", "--repo", "custom", "--phase", "queue", "--ticket", "DND-9001")
write_tickets({ "9001" => { "id" => PAGE, "status" => "In Progress", "path" => "Off" }, "fail_patch" => 403 })
sent_before = sends.size
3.times { |i| tool(E3, "observe", "--repo", "custom", "--run", "p-#{i}", "--summary-file", SUM) }
code, out, = tool(E3, "observe", "--repo", "custom", "--run", "p-3", "--summary-file", SUM)
last = sends.last.to_s
check("Notion refuses the Path PATCH: COULD-NOT-LOOK, exit 3, naming Notion's answer", out) do
  code == 3 && out.include?("outcome=COULD-NOT-LOOK") && out.include?("promote failed") && out.include?("403")
end
check("... Path stays Off, the note says the promotion failed, and ONE alert says it could NOT be promoted") do
  note = writes.reverse.find { |r| r["path"].start_with?("/v1/blocks/") }.to_json
  JSON.parse(File.read(TICKETS))["9001"]["path"] == "Off" && note.include?("promotion failed") &&
    sends.size == sent_before + 1 && File.read(File.join(SENT, last)).include?("could NOT be promoted")
end

# Refusals: the lookup's other side.
code, _, err = tool(E2, "observe", "--repo", "custom", "--run", "run-2", "--summary-file", summary_file("other", repo: "gen_saas"))
check("a summary for another repo: refused, exit 2, nothing counted", err) do
  code == 2 && err.include?("not custom") && JSON.parse(tool(E2, "status")[1])["custom/queue"]["runs"] == 1
end
code, _, err = tool(E2, "handoff", "--repo", "custom", "--phase", "queue", "--ticket", "XYZ-7")
check("a non-DND hand-off ticket: refused, exit 2", err) { code == 2 && err.include?("Fix:") }
code, _, err = tool(E2, "observe", "--repo", "custom", "--run", "run-3")
check("observe with no --summary-file: usage error, exit 2", err) { code == 2 && err.include?("--summary-file") }
File.write(File.join(STATE2, "unmeasurable.json"), "{torn")
code, _, err = tool(E2, "status")
check("a torn state file: could not look, exit 3, never an empty state", err) { code == 3 && err.include?("could not look") }

puts "unmeasurable_e2e_test: #{$checks - $failures.size}/#{$checks} passed"
exit($failures.empty? ? 0 : 1)
