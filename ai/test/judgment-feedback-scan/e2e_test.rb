# frozen_string_literal: true

# End-to-end suite for `judgment-feedback scan-tickets` (DND-1469, DND-1470): the bin as
# a process against one loopback fake (fake-scan-server.py) standing in for
# Notion's reads and the Athena feedback POST. Never prod: every URL is
# 127.0.0.1, and both tokens, the MCP registry and the inbox client config are
# temp fixtures. Functional only (DND-1222): the suite blocks on the fake's
# port line and on each command's exit, never on a sleep. Synthetic ids only.

require "fileutils"
require "json"
require "open3"
require "tmpdir"

ROOT = File.expand_path("../../..", __dir__)
BIN = File.join(ROOT, "ai/bin/judgment-feedback")
FAKE = File.expand_path("fake-scan-server.py", __dir__)
DIR = Dir.mktmpdir("jf-scan-e2e-")
NOTION_TOKEN = "scan-notion-token-#{Process.pid}-#{rand(1 << 30)}"
ATHENA_TOKEN = "scan-athena-token-#{Process.pid}-#{rand(1 << 30)}"
SINCE = "2026-10-01T00:00:00Z"

$failures = []
$checks = 0
$fakes = []

at_exit do
  $fakes.each do |io, pid|
    Process.kill("TERM", pid)
    Process.wait(pid)
    io.close
  rescue SystemCallError, IOError
    nil
  end
  FileUtils.rm_rf(DIR)
end

def check(desc, detail = nil)
  $checks += 1
  ok = begin
    yield
  rescue StandardError => e
    detail = "raised #{e.class}: #{e.message}"
    false
  end
  $failures << desc unless ok
  puts "#{ok ? 'ok  ' : 'FAIL'} #{desc}"
  puts "     #{detail}" if !ok && detail
end

def call(n) = format("%08d-1111-4111-8111-111111111111", n)
def page(n) = format("a0000000-0000-4000-8000-%012d", n)

def prop(value, source: "jev", judged: value, reason: nil)
  { "value" => value, "source" => source, "judged" => source == "jev" ? judged : nil, "confidence" => source == "jev" ? 0.9 : nil,
    "accepted" => source == "jev", "mode" => "on", "reason" => reason }
end

def line(kind: prop("Bug"), severity: prop("MEDIUM"), security: prop("none"), calls: nil)
  doc = { "kind" => kind, "severity" => severity, "security" => security, "model" => "jev-1.13.0",
          "versions" => { "kind" => "ticket-kind-v1", "severity" => "ticket-severity-v1", "security" => "ticket-security-v1" } }
  doc["calls"] = calls if calls
  "Jev classification: #{JSON.generate(doc)}"
end

def calls(n) = { "kind" => call(n * 10 + 1), "severity" => call(n * 10 + 2), "security" => call(n * 10 + 3) }

def block(text) = { "type" => "paragraph", "paragraph" => { "rich_text" => [{ "plain_text" => text }] } }

def row(n, kind:, severity:, security:, path: "Off", blocks: [])
  sel = ->(v) { { "select" => v && { "name" => v } } }
  { "id" => page(n), "created_time" => "2026-10-01T01:00:00.000Z", "last_edited_time" => "2026-10-01T02:00:00.000Z",
    "properties" => { "ID" => { "unique_id" => { "prefix" => "DND", "number" => n } },
                      "Name" => { "title" => [{ "plain_text" => "Synthetic ticket #{n}" }] },
                      "Status" => { "status" => { "name" => "Todo" } }, "Area" => { "select" => { "name" => "Harness" } },
                      "Kind" => sel.call(kind), "Severity" => sel.call(severity), "Security" => sel.call(security),
                      "Path" => sel.call(path), "Blocks" => { "relation" => blocks.map { |id| { "id" => id } }, "has_more" => false },
                      "Epic" => { "relation" => [] }, "Depends On" => { "relation" => [] } } }
end

# The fixture tracker:
#   DND-1 Kind edited away from Jev's Bug (line on the body's 2nd page): recorded
#   DND-2 Kind differs from a filer-sourced value: filer_sourced
#   DND-3 Kind edited on a line with no calls (filed before DND-1469): unlinked
#   DND-4 no line: no_provenance
#   DND-5 Severity edited away from Jev's MEDIUM; the server refuses the call
#   DND-6 Security edited from Jev's none to pre-existing: recorded
ROWS = [row(1, kind: "Hardening", severity: "MEDIUM", security: "none"),
        row(2, kind: "Docs", severity: "MEDIUM", security: "none"),
        row(3, kind: "Refactor", severity: "MEDIUM", security: "none"),
        row(4, kind: "Bug", severity: "LOW", security: "none"),
        row(5, kind: "Bug", severity: "HIGH", security: "none"),
        row(6, kind: "Bug", severity: "MEDIUM", security: "pre-existing"),
        { "id" => page(99), "properties" => { "ID" => { "unique_id" => { "prefix" => "OTHER", "number" => 1 } } } }].freeze
BLOCKS = {
  page(1) => [[block("Synthetic body one.")], [block(line(calls: calls(1)))]],
  page(2) => [[block(line(kind: prop("Bug", source: "filer", reason: "mode_off"), calls: calls(2)))]],
  page(3) => [[block(line)]],
  page(4) => [[block("A body with no classification line.")]],
  page(5) => [[block(line(calls: calls(5)))]],
  page(6) => [[block(line(calls: calls(6)))]]
}.freeze
REFUSE = { call(52) => { "status" => 404, "body" => { "error" => "not_found", "fix" => "Fix: name a call of yours" } } }.freeze

# fake(name, extra) -> [log path, env] for a fresh fake with its own state.
def fake(name, extra = {})
  dir = File.join(DIR, name)
  FileUtils.mkdir_p(dir)
  fixture = { "notion_token" => NOTION_TOKEN, "athena_token" => ATHENA_TOKEN, "rows" => ROWS, "blocks" => BLOCKS,
              "refuse" => REFUSE }.merge(extra)
  File.write("#{dir}/fixture.json", JSON.generate(fixture))
  log = "#{dir}/requests.log"
  File.write(log, "")
  io = IO.popen(["python3", FAKE, log, "#{dir}/fixture.json"], "r", err: File::NULL)
  port = io.gets.to_s.strip
  abort "e2e: the fake printed no port. Fix: run #{FAKE} by hand and read its error" unless /\A\d+\z/.match?(port)
  $fakes << [io, io.pid]
  File.write("#{dir}/notion-token", "#{NOTION_TOKEN}\n")
  File.write("#{dir}/config.json", JSON.generate({ "token" => ATHENA_TOKEN }), perm: 0o600)
  File.write("#{dir}/claude.json", JSON.generate({ "mcpServers" => {
                                                    "athena" => { "type" => "http", "url" => "http://127.0.0.1:#{port}/mcp" },
                                                    "notion-personal" => { "env" => { "NOTION_ATHENA_TOKEN_FILE" => "#{dir}/notion-token" } }
                                                  } }))
  env = { "FLEET_CLAUDE_JSON" => "#{dir}/claude.json", "ATHENA_INBOX_CLIENT_CONFIG" => "#{dir}/config.json",
          "JUDGMENT_FEEDBACK_NOTION_API" => "http://127.0.0.1:#{port}", "JUDGMENT_FEEDBACK_NOTION_PACE_S" => "0",
          "JUDGMENT_FEEDBACK_MAX_TIME_S" => "10" }
  [log, env]
end

def run(env, *args)
  out, err, status = Open3.capture3(env, "/usr/bin/ruby", BIN, *args)
  [status.exitstatus, out, err]
end

def requests(log) = File.readlines(log).map { |l| JSON.parse(l) }
def posts(log) = requests(log).select { |r| r["path"] == "/api/v1/judgments/feedback" }

puts "== one scan records the edits and counts every other ticket by reason [ticket 4]"
log, env = fake("main")
rc, out, err = run(env, "scan-tickets", "--since", SINCE)
check("exit 0 and complete with a next_since", "rc #{rc}; out: #{out}; err: #{err}") { rc.zero? && out =~ /^complete: next_since \d{4}-\d\d-\d\dT\d\d:\d\d:00Z$/ }
check("tickets counted once each by reason", out) { out.include?("tickets: provenance_unread 0, no_provenance 1, unparseable 0, lines 5") }
check("every property of the 5 lines counted once (15)", out) do
  out.include?("properties: filer_sourced 1, policy_sourced 0, unchanged 10, unlinked 1, no_call 0, not_accepted 0, no_label 0, same_label 0, edited 3")
end
check("records: 2 recorded, 1 refused, named by ticket, property and error", out) do
  out.include?("records: recorded 2, replaced 0, already_recorded 0, refused 1, not_sent 0") && out.include?("  refused: DND-5 severity not_found")
end
check("the unlinked ticket is named", out) { out.include?("  unlinked: DND-3") }
check("a row with no DND id is counted, not dropped", out) { out.include?("7 rows edited (1 without a DND id)") }
check("the ticket_blocking line counts every ticket once: none has a Jev path line here", out) do
  out.include?("ticket_blocking: provenance_unread 0, no_path_line 6, unparseable 0, filer_sourced 0, rule_sourced 0, path_unset 0, " \
               "authored_override 0, edges_unread 0, blocking_no_edge 0, unchanged 0, unlinked 0, no_call 0, no_candidate_named 0, " \
               "not_contradicted 0, edited 0")
end
sent = posts(log)
check("the bodies carry call, correction, field_changed and harness; no identity key", sent.map { |r| r["body"] }.inspect) do
  sent.map { |r| r["body"] } == [
    { "call_id" => call(11), "correction" => { "kind" => "hardening" }, "signal" => "field_changed", "session_label" => "harness" },
    { "call_id" => call(52), "correction" => { "severity" => "2" }, "signal" => "field_changed", "session_label" => "harness" },
    { "call_id" => call(63), "correction" => { "security" => "security" }, "signal" => "field_changed", "session_label" => "harness" }
  ]
end
check("the feedback POSTs carry the machine token; Notion requests the Notion token") do
  requests(log).all? { |r| r["auth"] == (r["path"].start_with?("/api/") ? "athena" : "notion") }
end
check("Notion saw reads only, and the query filtered on last_edited_time since") do
  notion = requests(log).reject { |r| r["path"].start_with?("/api/") }
  q = notion.find { |r| r["path"].end_with?("/query") }
  notion.none? { |r| r["unexpected"] } && notion.all? { |r| %w[GET POST].include?(r["method"]) } &&
    q["body"]["filter"] == { "timestamp" => "last_edited_time", "last_edited_time" => { "on_or_after" => SINCE } }
end
check("the body's LAST block page was read (the line was on it)") { requests(log).any? { |r| r["path"].include?("#{page(1)}/children") && r["path"].include?("start_cursor") } }

rc, out, = run(env, "scan-tickets", "--since", SINCE)
check("a re-run records the same edits as replaced, no new rows [ticket 4]", out) do
  rc.zero? && out.include?("records: recorded 0, replaced 2, already_recorded 0, refused 1, not_sent 0")
end

puts "== the recorded file"
rec = File.join(DIR, "recorded.txt")
rc, out, = run(env, "scan-tickets", "--since", SINCE, "--recorded-file", rec, "--json")
view = JSON.parse(out.lines.last)
check("--json prints one line with the counts and next_since", out) do
  rc.zero? && out.lines.size == 1 && view["complete"] == true && view["records"]["replaced"] == 2 && view["next_since"].is_a?(String) &&
    view["named"] == { "unlinked" => ["DND-3"] } && view["refused"] == ["DND-5 severity not_found"]
end
check("each stored record is appended to the recorded file") do
  File.readlines(rec).map(&:strip).sort == ["#{call(11)} kind=hardening", "#{call(63)} security=security"]
end
before = posts(log).size
rc, out, = run(env, "scan-tickets", "--recorded-file", rec, "--since", SINCE)
check("an edit already recorded is counted, not sent again (flags in any order)", out) do
  rc.zero? && out.include?("records: recorded 0, replaced 0, already_recorded 2, refused 1, not_sent 0") && posts(log).size == before + 1
end

puts "== incomplete scans keep the old --since"
log2, env2 = fake("unread", "fail_blocks" => [page(4)])
rc, out, err = run(env2, "scan-tickets", "--since", SINCE)
check("a body that cannot be read is provenance_unread: named, exit 3, no next_since", "rc #{rc}; out: #{out}; err: #{err}") do
  rc == 3 && out.include?("provenance_unread 1, no_provenance 0") && out.include?("  provenance_unread: DND-4") &&
    !out.include?("next_since") && out.include?("INCOMPLETE (COULD NOT READ NOTION): keep the old --since") && err.include?("Fix:")
end
check("the records it could send still went") { posts(log2).size == 3 }

_log3, env3 = fake("down", "post_status" => 503)
rc, out, err = run(env3, "scan-tickets", "--since", SINCE)
check("a server that fails stops the sending: exit 3, the rest not_sent, no next_since", "rc #{rc}; out: #{out}; err: #{err}") do
  rc == 3 && out.include?("recorded 0, replaced 0, already_recorded 0, refused 0, not_sent 3") && err.start_with?("SERVER FAILED: HTTP 503") &&
    out.include?("INCOMPLETE (SERVER FAILED)") && !out.include?("next_since")
end

rc, out, err = run(env3, "scan-tickets", "--since", SINCE, "--json")
view = JSON.parse(out.lines.last.to_s)
check("--json on an incomplete scan is still one line: complete false, the reason, no next_since", "rc #{rc}; out: #{out}") do
  rc == 3 && out.lines.size == 1 && view["complete"] == false && view["next_since"].nil? && view["reason"] == "SERVER FAILED" &&
    !view.key?("failure") && err.start_with?("SERVER FAILED")
end

invalid = REFUSE.merge(call(63) => { "status" => 422, "body" => { "error" => "invalid", "field" => "correction", "fix" => "Fix: use a label of the question" } })
_log5, env5 = fake("invalid", "refuse" => invalid)
rc, out, err = run(env5, "scan-tickets", "--since", SINCE)
check("a correction refused as invalid (our labels are wrong) is exit 4 and incomplete; not_found stays a named answer", "rc #{rc}; out: #{out}; err: #{err}") do
  rc == 4 && out.include?("recorded 1, replaced 0, already_recorded 0, refused 2, not_sent 0") && out.include?("  refused: DND-6 security invalid") &&
    out.include?("INCOMPLETE (SERVER REFUSED)") && !out.include?("next_since") && err.include?("as invalid. Fix:")
end

_log6, env6 = fake("append")
rc, out, err = run(env6, "scan-tickets", "--since", SINCE, "--recorded-file", File.join(DIR, "no-such-dir", "recorded.txt"))
check("a record stored but not appended counts once (recorded), and the rest not_sent", "rc #{rc}; out: #{out}; err: #{err}") do
  rc == 3 && out.include?("recorded 1, replaced 0, already_recorded 0, refused 0, not_sent 2") && err.include?("could not append to --recorded-file") &&
    err.include?("Fix:")
end

env4 = env.merge("JUDGMENT_FEEDBACK_NOTION_API" => "http://127.0.0.1:1")
rc, out, err = run(env4, "scan-tickets", "--since", SINCE)
check("Notion unreachable is exit 3 COULD NOT READ NOTION with a Fix:, never an empty scan", "rc #{rc}; out: #{out}; err: #{err}") do
  rc == 3 && err.start_with?("COULD NOT READ NOTION: could not reach Notion") && err.include?("Fix:") && out.empty?
end

puts "== ticket_blocking: a Path or Blocks change away from a jev Jev path line (DND-1470)"
# Candidates, in cand_<i> order: DND-102 (cand_0, page 102, outside the
# scan: its ref is read from its page) and DND-101 (cand_1, page 101, in the
# scan). Jev blocked DND-101 (cand_1) unless a row says otherwise.
#   DND-21 now Off: cand_1=does_not_block
#   DND-22 now Blocking onto DND-102 (earlier): cand_0=blocks, cand_1=does_not_block
#   DND-23 now Promoted: authored_override, no record
#   DND-24 a line with no call, now Off: unlinked
#   DND-25 still Blocking onto DND-101: unchanged
#   DND-26 filer Off, now Blocking onto DND-101: filer_sourced
#   DND-27 Jev blocked DND-102 (cand_0); now also onto DND-101 (later): not_contradicted
#   DND-28 still onto DND-101, plus an edge onto DND-102 (earlier): cand_0=blocks
#   DND-29 Blocking with no edge: blocking_no_edge
#   DND-101 a candidate with no line: no_path_line
REFS2 = %w[DND-102 DND-101].freeze
P_CALL = { 21 => call(210), 22 => call(220), 23 => call(230), 25 => call(250), 27 => call(270), 28 => call(280), 29 => call(290) }.freeze
def pline(n, value: "Blocking", blocks: "DND-101", source: "jev", linked: true)
  d = { "path" => { "value" => value, "blocks" => blocks, "source" => source, "reason" => source == "jev" ? nil : "mode_off", "mode" => "on",
                    "confidence" => source == "jev" ? 0.95 : nil }, "would" => nil, "candidates" => 2, "model" => "jev-1.13.0", "version" => "ticket-blocking-v1" }
  d.merge!("candidate_refs" => REFS2, "call" => P_CALL[n]) if linked
  "Jev path: #{JSON.generate(d)}"
end
def brow(n, path, blocks = []) = row(n, kind: "Bug", severity: "MEDIUM", security: "none", path: path, blocks: blocks)
BROWS = [brow(21, "Off"), brow(22, "Blocking", [page(102)]), brow(23, "Promoted", [page(101)]), brow(24, "Off"),
         brow(25, "Blocking", [page(101)]), brow(26, "Blocking", [page(101)]), brow(27, "Blocking", [page(102), page(101)]),
         brow(28, "Blocking", [page(101), page(102)]), brow(29, "Blocking"),
         row(101, kind: "Feature", severity: nil, security: "none", path: "Critical")].freeze
BBLOCKS = {
  page(21) => [[block(pline(21))]], page(22) => [[block("Body."), block(pline(22))]], page(23) => [[block(pline(23))]],
  page(24) => [[block(pline(24, linked: false))]], page(25) => [[block(pline(25))]],
  page(26) => [[block(pline(26, value: "Off", blocks: nil, source: "filer"))]], page(27) => [[block(pline(27, blocks: "DND-102"))]],
  page(28) => [[block(pline(28))]], page(29) => [[block(pline(29))]], page(101) => [[block("Requirement.")]]
}.freeze
blog, benv = fake("blocking", "rows" => BROWS, "blocks" => BBLOCKS, "pages" => { page(102) => 102 })
rc, out, err = run(benv, "scan-tickets", "--since", SINCE)
check("exit 0, complete, the ticket_blocking counts by reason [ticket 4]", "rc #{rc}; out: #{out}; err: #{err}") do
  rc.zero? && out =~ /^complete: next_since / &&
    out.include?("ticket_blocking: provenance_unread 0, no_path_line 1, unparseable 0, filer_sourced 1, rule_sourced 0, path_unset 0, " \
                 "authored_override 1, edges_unread 0, blocking_no_edge 1, unchanged 1, unlinked 1, no_call 0, no_candidate_named 0, " \
                 "not_contradicted 1, edited 3")
end
check("the unlinked and edgeless findings are named on the ticket_blocking line", out) do
  out.include?("  ticket_blocking unlinked: DND-24") && out.include?("  ticket_blocking blocking_no_edge: DND-29")
end
check("three records, one per call, each with every contradicted candidate", posts(blog).map { |r| r["body"] }.inspect) do
  posts(blog).map { |r| r["body"] } == [
    { "call_id" => call(210), "correction" => { "cand_1" => "does_not_block" }, "signal" => "field_changed", "session_label" => "harness" },
    { "call_id" => call(220), "correction" => { "cand_0" => "blocks", "cand_1" => "does_not_block" }, "signal" => "field_changed", "session_label" => "harness" },
    { "call_id" => call(280), "correction" => { "cand_0" => "blocks" }, "signal" => "field_changed", "session_label" => "harness" }
  ] && out.include?("records: recorded 3, replaced 0, already_recorded 0, refused 0, not_sent 0")
end
check("an edge onto a page outside the scan is read once, however many findings name it") do
  requests(blog).select { |r| r["path"].start_with?("/v1/pages/") }.map { |r| r["path"] } == ["/v1/pages/#{page(102)}"]
end
brec = File.join(DIR, "blocking-recorded.txt")
run(benv, "scan-tickets", "--since", SINCE, "--recorded-file", brec)
rc, out, = run(benv, "scan-tickets", "--since", SINCE, "--recorded-file", brec)
check("a re-run with the recorded file sends none again [ticket 4]", out) do
  rc.zero? && out.include?("records: recorded 0, replaced 0, already_recorded 3, refused 0, not_sent 0") &&
    File.readlines(brec).map(&:strip).sort == ["#{call(210)} cand_1=does_not_block", "#{call(220)} cand_0=blocks,cand_1=does_not_block",
                                               "#{call(280)} cand_0=blocks"]
end

_ulog, uenv = fake("edges-unread", "rows" => BROWS, "blocks" => BBLOCKS, "pages" => { page(102) => 102 }, "fail_pages" => [page(102)])
rc, out, err = run(uenv, "scan-tickets", "--since", SINCE)
check("a Blocks target that cannot be read is edges_unread: named, exit 3, no next_since", "rc #{rc}; out: #{out}; err: #{err}") do
  rc == 3 && out.include?("edges_unread 3") && out.include?("  ticket_blocking edges_unread: DND-22, DND-27, DND-28") && !out.include?("next_since") &&
    err.include?("Blocks edges could not be read") && err.include?("Fix:")
end

truncated = BROWS.map { |r| r["id"] == page(25) ? r.merge("properties" => r["properties"].merge("Blocks" => { "relation" => [{ "id" => page(101) }], "has_more" => true })) : r }
_tlog, tenv = fake("truncated", "rows" => truncated, "blocks" => BBLOCKS, "pages" => { page(102) => 102 })
rc, out, err = run(tenv, "scan-tickets", "--since", SINCE)
check("a truncated Blocks relation is edges_unread, never read as the whole edge list", "rc #{rc}; out: #{out}; err: #{err}") do
  rc == 3 && out.include?("  ticket_blocking edges_unread: DND-25") && !out.include?("next_since")
end

_plog, penv = fake("no-dnd-id", "rows" => BROWS, "blocks" => BBLOCKS, "pages" => { page(102) => nil })
rc, out, err = run(penv, "scan-tickets", "--since", SINCE)
check("a Blocks target with no DND id is read, and is no candidate (never edges_unread)", "rc #{rc}; out: #{out}; err: #{err}") do
  rc.zero? && out.include?("edges_unread 0")
end

no_path = ROWS.map { |r| r.merge("properties" => r["properties"].except("Path")) }
_nlog, nenv = fake("no-path", "rows" => no_path)
rc, out, err = run(nenv, "scan-tickets", "--since", SINCE)
check("rows with no Path select are a schema fault (exit 3, Fix:), never 'Path unset'", "rc #{rc}; out: #{out}; err: #{err}") do
  rc == 3 && err.include?("no select property Path") && err.include?("Fix:")
end

puts "== usage"
rc, out, err = run(env, "scan-tickets")
check("--since is required (exit 2, Fix:, nothing read)") { rc == 2 && err.include?("needs --since") && err.include?("Fix:") && out.empty? }
rc, _out, err = run(env, "scan-tickets", "--since", "2026-10-01")
check("a --since with no time or zone is usage") { rc == 2 && err.include?("ISO 8601 time with a zone") }
File.write(File.join(DIR, "bad-recorded.txt"), "not a key\n")
rc, _out, err = run(env, "scan-tickets", "--since", SINCE, "--recorded-file", File.join(DIR, "bad-recorded.txt"))
check("a corrupt recorded file is usage, never silently ignored") { rc == 2 && err.include?("--recorded-file line 1") }
rc, _out, err = run(env, "scan-tickets", "--since", SINCE, "--owner", "x")
check("there is no identity flag") { rc == 2 && err.include?("--owner") }
rc, _out, err = run(env.merge("JUDGMENT_FEEDBACK_NOTION_API" => "https://api.example.invalid"), "scan-tickets", "--since", SINCE)
check("a Notion override that is not loopback is usage") { rc == 2 && err.include?("JUDGMENT_FEEDBACK_NOTION_API") }
rc, out, = run({}, "--help")
check("--help names scan-tickets, on stdout, exit 0") { rc.zero? && out.include?("scan-tickets --since") }

puts
puts "judgment-feedback-scan e2e: #{$checks - $failures.size} passed, #{$failures.size} failed"
exit($failures.empty? ? 0 : 1)
