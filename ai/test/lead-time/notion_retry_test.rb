# frozen_string_literal: true

# DND-1519: a transient Notion error must not cost lead-time a whole scan
# window. The real transport (NextMissionNotion::HttpTransport) talks HTTP to a
# fake Notion on loopback, so the retry policy runs over a real socket. The
# retry wait is injected and recorded: no check waits on the wall clock
# (DND-1222). The fake answers raw UTF-8 JSON, never ASCII-escaped, so a
# locale-dependent read cannot hide behind it (DND-1054).
# Run by ai/test/lead-time/self-test.sh.

require "json"

load File.expand_path("../../bin/lead-time", __dir__)

$failures = []
$checks = 0

def check(desc)
  $checks += 1
  $failures << desc unless yield
rescue StandardError => e
  $failures << "#{desc} (raised #{e.class}: #{e.message})"
end

# The fake Notion is shared with NotionRead's suite (DND-1649).
require_relative "../../lib/test/support/fake_notion_server"

TOKEN = "fake-token-0001"
STAMP = "2026-09-30T02:41:00.000Z"
# A title with non-ASCII text, emitted as raw UTF-8 (JSON.generate does not
# escape it).
PAGE = {
  "results" => [{
    "id" => "page-1203",
    "properties" => {
      "Name" => { "type" => "title", "title" => [{ "plain_text" => "Récupération ✓ — ünïcode" }] },
      "ID" => { "type" => "unique_id", "unique_id" => { "prefix" => "DND", "number" => 1203 } },
      NotionStart::PROPERTY => { "type" => "date", "date" => { "start" => STAMP, "end" => nil } }
    }
  }]
}.freeze

def ok(body = PAGE)
  FakeNotionServer::Reply.new(status: 200, body: JSON.generate(body))
end

def err(status, message, headers = nil)
  FakeNotionServer::Reply.new(status: status, body: JSON.generate("object" => "error", "message" => message),
                              headers: headers)
end

MEMCACHED = "Cross-cell memcached access is not allowed"

server = FakeNotionServer.new
begin
  waits = []
  transport = nil
  # A new scan: a new transport and start source, as one lead-time run builds.
  fresh = lambda do
    waits.clear
    ProbeFailures.reset!
    transport = NextMissionNotion::HttpTransport.new(TOKEN, base: server.base, wait: ->(s) { waits << s })
    NotionStart.new(transport)
  end

  # --- the window survives a burst of 5xx (the 2026-10-01 symptom) ----------
  server.script(err(500, MEMCACHED), err(500, MEMCACHED), err(500, MEMCACHED), ok)
  at, why = fresh.call.lookup("DND-1203")
  check("a 500 burst of three then a 200 reads the stamp (got #{at.inspect}, #{why.inspect})") do
    at == "2026-09-30T02:41:00Z" && why.nil?
  end
  check("and records no probe failure, so the scan is not SCAN INCOMPLETE") { !ProbeFailures.any? }
  check("and backs off between tries (waits #{waits.inspect})") { waits == [1.0, 2.0, 4.0] }
  check("and every try carried the token and the Notion version") do
    server.requests.size == 4 && server.requests.all? do |r|
      r[:headers]["authorization"] == "Bearer #{TOKEN}" && r[:headers]["notion-version"] == NextMissionNotion::NOTION_VERSION
    end
  end

  # --- 429 honours Retry-After --------------------------------------------------
  server.script(err(429, "rate limited", "Retry-After" => "7"), ok)
  at, = fresh.call.lookup("DND-1203")
  check("a 429 then a 200 reads the stamp") { at == "2026-09-30T02:41:00Z" }
  check("and waits the Retry-After it was given (waits #{waits.inspect})") { waits == [7.0] }

  server.script(err(429, "rate limited", "Retry-After" => "120"), ok)
  fresh.call.lookup("DND-1203")
  check("an over-long Retry-After is capped (waits #{waits.inspect})") do
    waits == [NotionRetry::RETRY_AFTER_CAP]
  end

  # A Retry-After that is not a number of seconds (an HTTP date) falls back to
  # the backoff step. A 5xx's Retry-After is honoured like a 429's.
  server.script(err(429, "rate limited", "Retry-After" => "Wed, 01 Oct 2026 12:09:00 GMT"), ok)
  fresh.call.lookup("DND-1203")
  check("a date-form Retry-After falls back to the backoff (waits #{waits.inspect})") { waits == [1.0] }

  server.script(err(503, MEMCACHED, "Retry-After" => "5"), ok)
  fresh.call.lookup("DND-1203")
  check("a 5xx's Retry-After is honoured too (waits #{waits.inspect})") { waits == [5.0] }

  # --- a 4xx other than 429 is never retried ----------------------------------
  server.script(err(400, "body failed validation"))
  _at, why = fresh.call.lookup("DND-1203")
  check("a 400 is asked once, never retried (#{server.requests.size} request(s))") do
    server.requests.size == 1 && waits.empty?
  end
  check("and is a failed probe naming the ticket and the status") do
    f = ProbeFailures.list.first
    why.include?("Notion could not be read") && f && f[:cmd].include?("DND-1203") && f[:detail].include?("HTTP 400")
  end

  # --- exhausted retries still end the scan SCAN INCOMPLETE -------------------
  server.script(err(503, MEMCACHED))
  outage = fresh.call
  _at, why = outage.lookup("DND-1203")
  attempts = NotionRetry::ATTEMPTS
  check("a 5xx that never clears is asked ATTEMPTS (#{attempts}) times (#{server.requests.size})") do
    server.requests.size == attempts
  end
  check("within the wait budget (waits #{waits.inspect})") do
    waits.size == attempts - 1 && waits.sum <= NotionRetry::WAIT_BUDGET
  end
  check("and is a failed probe naming the ticket, the status and the tries") do
    f = ProbeFailures.list.first
    why.include?("Notion could not be read") && f && f[:cmd].include?("DND-1203") &&
      f[:detail].include?("HTTP 503") && f[:detail].include?("after #{attempts} attempts") &&
      f[:detail].include?(MEMCACHED)
  end

  # A sustained outage costs one budget per scan, not one per ticket.
  server.script(err(503, MEMCACHED))
  waits.clear
  _at, why = outage.lookup("DND-1204")
  check("after an exhausted call, the next ticket is asked once (#{server.requests.size} request(s))") do
    server.requests.size == 1 && waits.empty?
  end
  check("and its failed probe says it was not retried, naming the ticket") do
    f = ProbeFailures.list.find { |x| x[:cmd].include?("DND-1204") }
    why.include?("Notion could not be read") && f && f[:detail].include?("HTTP 503") &&
      f[:detail].include?("not retried")
  end
  server.script(ok, err(500, MEMCACHED), ok)
  outage.lookup("DND-1205")
  waits.clear
  at, = outage.lookup("DND-1206")
  check("a success ends the outage: later calls retry again (waits #{waits.inspect})") do
    at == "2026-09-30T02:41:00Z" && waits == [1.0]
  end

  # Retry-After waits that would overrun the budget stop early, not late.
  server.script(err(429, "rate limited", "Retry-After" => "30"))
  fresh.call.lookup("DND-1203")
  check("Retry-After waits stop at the wait budget (waits #{waits.inspect})") do
    waits == [30.0, 30.0] && server.requests.size == 3 &&
      ProbeFailures.list.first[:detail].include?("HTTP 429")
  end

  # --- one read per ticket per scan --------------------------------------------
  server.script(ok)
  s = fresh.call
  s.lookup("DND-1203")
  s.lookup("DND-1203")
  check("a ticket's stamp is read once per scan (#{server.requests.size} request(s))") do
    server.requests.size == 1
  end

  # --- the base override is loopback only ------------------------------------
  check("a non-loopback base is refused") do
    NextMissionNotion::HttpTransport.new(TOKEN, base: "http://example.com")
    false
  rescue ArgumentError
    true
  end
  check("an https loopback or a path-bearing base is refused") do
    %w[https://127.0.0.1:1 http://127.0.0.1:1/v1].all? do |b|
      NextMissionNotion::HttpTransport.new(TOKEN, base: b)
      false
    rescue ArgumentError
      true
    end
  end
ensure
  server.close
end

if $failures.empty?
  puts "notion_retry_test: PASS (#{$checks} checks)"
  exit 0
end
warn "notion_retry_test: FAIL (#{$failures.size} of #{$checks})"
$failures.each { |f| warn "  - #{f}" }
warn "Fix: NextMissionNotion::HttpTransport must retry a 429 (honouring Retry-After, capped) and a 5xx " \
     "with bounded backoff inside a total wait budget, never retry another 4xx, and on exhaustion raise a " \
     "ReadError naming the status and the attempts, which NotionStart records as a failed probe naming the " \
     "ticket (DND-1519)."
exit 1
