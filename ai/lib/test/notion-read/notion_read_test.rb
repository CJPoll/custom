# frozen_string_literal: true

# DND-1649: NotionRead (ai/lib/notion_read.rb, the curl-based read-only Notion
# client) retried a 429 only, never a 5xx, and slept on the wall clock. A
# burst of 500 "Cross-cell memcached access is not allowed" (2026-10-01) failed
# triage-corpus, ticket-classify --epic, ticket-reclassify, judgment-feedback
# scan-tickets and ticket-provenance-check on the first try.
#
# NotionRead runs its real curl request against a fake Notion on loopback, so
# the shared retry policy (NotionRetry) is proven over a real socket. The wait
# is injected and recorded: no check waits on the wall clock (DND-1222). The
# fake answers raw UTF-8 JSON, so a locale-dependent read cannot hide (DND-1054).
# Run by ai/lib/test/notion-read/self-test.sh, under LC_ALL=C.

require "json"
require_relative "../../notion_read"
require_relative "../support/fake_notion_server"

$failures = []
$checks = 0

def check(desc)
  $checks += 1
  $failures << desc unless yield
rescue StandardError => e
  $failures << "#{desc} (raised #{e.class}: #{e.message})"
end

TOKEN = "fake-token-0001"
PAGE_ID = "00000000-0000-4000-8000-000000000001"
DATA_SOURCE = "00000000-0000-4000-8000-0000000000d5"
TITLE = "Récupération ✓ — ünïcode"
PAGE = { "object" => "page", "id" => PAGE_ID,
         "properties" => { "Name" => { "type" => "title", "title" => [{ "plain_text" => TITLE }] } } }.freeze
MEMCACHED = "Cross-cell memcached access is not allowed"

def ok(body = PAGE)
  FakeNotionServer::Reply.new(status: 200, body: JSON.generate(body))
end

def err(status, message, headers = nil)
  FakeNotionServer::Reply.new(status: status, body: JSON.generate("object" => "error", "message" => message),
                              headers: headers)
end

server = FakeNotionServer.new
begin
  waits = []
  # A new run: a new retry policy, as each caller process starts with one.
  fresh = lambda do
    waits.clear
    NotionRetry.new(wait: ->(s) { waits << s })
  end
  page = ->(retrier) { NotionRead.page(server.base, TOKEN, PAGE_ID, pace: 0, retrier: retrier) }

  # --- the regression: a 500 then a 200 reads the page ----------------------
  server.script(err(500, MEMCACHED), ok)
  got = page.call(fresh.call)
  check("a 500 then a 200 reads the page (got #{got.inspect[0, 120]})") do
    got["id"] == PAGE_ID && got.dig("properties", "Name", "title", 0, "plain_text") == TITLE
  end
  check("and asked twice (#{server.requests.size} request(s))") { server.requests.size == 2 }
  check("and waited through the injected wait, never the wall clock (waits #{waits.inspect})") { waits == [1.0] }
  check("and every try carried the token and the Notion version") do
    server.requests.all? do |r|
      r[:headers]["authorization"] == "Bearer #{TOKEN}" && r[:headers]["notion-version"] == NotionRead::NOTION_VERSION
    end
  end

  # --- the 2026-10-01 burst, through a paginated query ------------------------
  server.script(err(500, MEMCACHED), err(502, MEMCACHED), err(503, MEMCACHED),
                ok("results" => [{ "id" => "row-1" }], "has_more" => false))
  rows = NotionRead.query_all(server.base, TOKEN, DATA_SOURCE, pace: 0, retrier: fresh.call)
  check("a burst of three 5xx then a 200 returns the rows (got #{rows.inspect})") { rows == [{ "id" => "row-1" }] }
  check("and backed off 1/2/4 s (waits #{waits.inspect})") { waits == [1.0, 2.0, 4.0] }
  check("and re-sent the same query body on every try") do
    bodies = server.requests.map { |r| r[:body] }
    bodies.size == 4 && bodies.uniq.size == 1 && JSON.parse(bodies.first)["page_size"] == 100
  end

  # --- 429 honours Retry-After, as before -------------------------------------
  server.script(err(429, "rate limited", "Retry-After" => "7"), ok)
  got = page.call(fresh.call)
  check("a 429 then a 200 reads the page, waiting the Retry-After (waits #{waits.inspect})") do
    got["id"] == PAGE_ID && waits == [7.0]
  end
  server.script(err(503, MEMCACHED, "Retry-After" => "5"), ok)
  page.call(fresh.call)
  check("a 5xx's Retry-After is honoured too (waits #{waits.inspect})") { waits == [5.0] }

  # --- a 4xx other than 429 is never retried ----------------------------------
  server.script(err(404, "Could not find page"), ok)
  begin
    page.call(fresh.call)
    check("a 404 raises") { false }
  rescue NotionRead::Error => e
    check("a 404 is asked once, never retried (#{server.requests.size} request(s), waits #{waits.inspect})") do
      server.requests.size == 1 && waits.empty?
    end
    check("and raises NotionRead::Error with status 404 and its fix (#{e.message})") do
      e.status == 404 && e.message.include?("HTTP 404") && e.fix.include?("401/403")
    end
  end

  # --- exhausted retries keep today's reported failure, never an empty result -
  outage = fresh.call
  server.script(err(503, MEMCACHED))
  begin
    page.call(outage)
    check("a 5xx that never clears raises") { false }
  rescue NotionRead::Error => e
    attempts = NotionRetry::ATTEMPTS
    check("a 5xx that never clears is asked ATTEMPTS (#{attempts}) times (#{server.requests.size})") do
      server.requests.size == attempts
    end
    check("within the wait budget (waits #{waits.inspect})") do
      waits.size == attempts - 1 && waits.sum <= NotionRetry::WAIT_BUDGET
    end
    check("and raises naming the status and the tries (#{e.message})") do
      e.status == 503 && e.message.include?("HTTP 503") && e.message.include?("after #{attempts} attempts")
    end
  end

  # A sustained outage costs one budget per run, not one per page.
  server.script(err(503, MEMCACHED))
  waits.clear
  begin
    page.call(outage)
    check("the next page in an outage raises") { false }
  rescue NotionRead::Error => e
    check("after an exhausted read, the next is asked once (#{server.requests.size} request(s))") do
      server.requests.size == 1 && waits.empty?
    end
    check("and says it was not retried (#{e.message})") { e.status == 503 && e.message.include?("not retried") }
  end
  server.script(ok, err(500, MEMCACHED), ok)
  page.call(outage)
  waits.clear
  got = page.call(outage)
  check("a success ends the outage: later reads retry again (waits #{waits.inspect})") do
    got["id"] == PAGE_ID && waits == [1.0]
  end

  # --- unchanged guarantees ---------------------------------------------------
  server.script(ok)
  begin
    NotionRead.read(server.base, TOKEN, "PATCH", "/v1/pages/#{PAGE_ID}", {}, pace: 0, retrier: fresh.call)
    check("a write is refused") { false }
  rescue NotionRead::Error => e
    check("a write is refused before it is sent (#{server.requests.size} request(s))") do
      e.message.start_with?("refused a Notion PATCH") && server.requests.empty?
    end
  end

  # Nothing listens on port 1: curl cannot connect. That is not a 5xx, so it
  # is not retried, and it still raises naming curl's exit.
  begin
    NotionRead.page("http://127.0.0.1:1", TOKEN, PAGE_ID, pace: 0, retrier: fresh.call)
    check("an unreachable Notion raises") { false }
  rescue NotionRead::Error => e
    check("an unreachable Notion raises 'could not reach', unretried (#{e.message}, waits #{waits.inspect})") do
      e.message.include?("could not reach Notion") && waits.empty?
    end
  end

  # curl dumps one header block per response; only the final one answers.
  interim = "HTTP/1.1 100 Continue\r\nRetry-After: 9\r\n\r\n"
  final = "HTTP/1.1 503 Service Unavailable\r\nContent-Type: application/json\r\n\r\n"
  check("Retry-After is read from the final header block only") do
    NotionRead.retry_after_from(interim + final).nil? &&
      NotionRead.retry_after_from(interim + final.sub("\r\n\r\n", "\r\nretry-after: 4\r\n\r\n")) == "4" &&
      NotionRead.retry_after_from("HTTP/1.1 429 Too Many\nRetry-After:  2.5\n\n") == "2.5" &&
      NotionRead.retry_after_from("").nil?
  end

  check("a caller that passes no retrier gets the one process-wide policy") do
    NotionRead.default_retrier.is_a?(NotionRetry) && NotionRead.default_retrier.equal?(NotionRead.default_retrier)
  end
ensure
  server.close
end

if $failures.empty?
  puts "notion_read_test: PASS (#{$checks} checks)"
  exit 0
end
warn "notion_read_test: FAIL (#{$failures.size} of #{$checks})"
$failures.each { |f| warn "  - #{f}" }
warn "Fix: NotionRead#read must run each request through the shared NotionRetry policy (ai/lib/notion_retry.rb): " \
     "retry a 429 or 5xx with Retry-After or backoff through the injected wait, never another 4xx, and on " \
     "exhaustion raise NotionRead::Error naming the status and the attempts (DND-1649)."
exit 1
