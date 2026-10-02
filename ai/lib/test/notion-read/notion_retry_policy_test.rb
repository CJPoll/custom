# frozen_string_literal: true

# DND-1649: the ONE Notion retry policy (ai/lib/notion_retry.rb), shared by
# NextMissionNotion::HttpTransport and NotionRead. Pure: each "request" is a
# scripted [status, Retry-After] pair, and the wait is a recorder, so nothing
# here touches a socket or the wall clock (DND-1222).
# Run by ai/lib/test/notion-read/self-test.sh.

require_relative "../../notion_retry"

$failures = []
$checks = 0

def check(desc)
  $checks += 1
  $failures << desc unless yield
rescue StandardError => e
  $failures << "#{desc} (raised #{e.class}: #{e.message})"
end

# run(policy, [[status, retry_after], ...]) -> [result, statuses asked]. Once
# the script is spent, its last entry repeats.
def run(policy, script)
  asked = []
  result = policy.run do |attempt|
    status, retry_after = script.fetch(attempt - 1, script.last)
    asked << status
    [status, retry_after, "reply #{attempt}"]
  end
  [result, asked]
end

def fresh
  waits = []
  [NotionRetry.new(wait: ->(s) { waits << s }), waits]
end

# --- what is transient ---------------------------------------------------------
check("429 and every 5xx are retryable") { [429, 500, 502, 503, 504, 599].all? { |s| NotionRetry.retryable?(s) } }
check("a 2xx, any other 4xx, and 0 (no answer) are not") do
  [200, 204, 400, 401, 403, 404, 409, 0].none? { |s| NotionRetry.retryable?(s) }
end

# --- 5xx then success ------------------------------------------------------------
policy, waits = fresh
result, asked = run(policy, [[500, nil], [500, nil], [200, nil]])
check("a 500 burst then a 200 succeeds (#{asked.inspect})") { result.ok? && asked == [500, 500, 200] }
check("and the reply is the successful one") { result.reply == "reply 3" && result.status == 200 && result.attempts == 3 }
check("and it backed off 1 s then 2 s (waits #{waits.inspect})") { waits == [1.0, 2.0] }

# --- Retry-After -----------------------------------------------------------------
policy, waits = fresh
run(policy, [[429, "7"], [200, nil]])
check("Retry-After in seconds is honoured (waits #{waits.inspect})") { waits == [7.0] }
policy, waits = fresh
run(policy, [[429, "0.5"], [200, nil]])
check("a fractional Retry-After is kept (waits #{waits.inspect})") { waits == [0.5] }
policy, waits = fresh
run(policy, [[503, "120"], [200, nil]])
check("an over-long Retry-After is capped at #{NotionRetry::RETRY_AFTER_CAP} (waits #{waits.inspect})") do
  waits == [NotionRetry::RETRY_AFTER_CAP]
end
["Wed, 01 Oct 2026 12:09:00 GMT", "0", "-3", "", nil].each do |given|
  policy, waits = fresh
  run(policy, [[429, given], [200, nil]])
  check("a Retry-After of #{given.inspect} falls back to the backoff (waits #{waits.inspect})") { waits == [1.0] }
end

# --- never retried -----------------------------------------------------------------
[400, 401, 404, 0].each do |status|
  policy, waits = fresh
  result, asked = run(policy, [[status, "5"]])
  check("a #{status} is asked once and returned, not retried") do
    !result.ok? && asked == [status] && waits.empty? && result.attempts == 1 && !result.retryable
  end
end

# --- exhaustion ----------------------------------------------------------------------
policy, waits = fresh
result, asked = run(policy, [[503, nil]])
check("a 5xx that never clears is asked ATTEMPTS (#{NotionRetry::ATTEMPTS}) times (#{asked.size})") do
  asked.size == NotionRetry::ATTEMPTS
end
check("and waits the backoff steps, inside the budget (waits #{waits.inspect})") do
  waits == [1.0, 2.0, 4.0, 8.0, 16.0] && waits.sum <= NotionRetry::WAIT_BUDGET
end
check("and the result names the status, the tries and that it was retryable") do
  !result.ok? && result.status == 503 && result.attempts == NotionRetry::ATTEMPTS && result.retryable && !result.degraded
end

policy, waits = fresh
result, asked = run(policy, [[429, "30"]])
check("Retry-After waits stop before they pass the budget (waits #{waits.inspect}, #{asked.size} asks)") do
  waits == [30.0, 30.0] && asked.size == 3 && result.status == 429
end

# --- a sustained outage costs one budget per run ---------------------------------------
policy, waits = fresh
run(policy, [[503, nil]])
waits.clear
result, asked = run(policy, [[503, nil]])
check("after an exhausted call, the next call is asked once (#{asked.size})") do
  asked.size == 1 && waits.empty? && result.degraded && result.retryable
end
run(policy, [[200, nil]])
waits.clear
result, asked = run(policy, [[500, nil], [200, nil]])
check("a success ends the outage: later calls retry again (waits #{waits.inspect})") do
  result.ok? && asked == [500, 200] && waits == [1.0]
end

policy, waits = fresh
run(policy, [[404, nil]])
result, asked = run(policy, [[500, nil], [200, nil]])
check("a non-retryable failure does not degrade later calls") { result.ok? && asked == [500, 200] && waits == [1.0] }

# --- the real wait is the default, and only an injection replaces it -----------------
check("the default wait is a real sleep (Kernel#sleep), not a no-op") do
  src = File.read(File.expand_path("../../notion_retry.rb", __dir__))
  src.include?("wait: ->(seconds) { sleep(seconds) }") && !src.match?(/ENV\[/)
end

if $failures.empty?
  puts "notion_retry_policy_test: PASS (#{$checks} checks)"
  exit 0
end
warn "notion_retry_policy_test: FAIL (#{$failures.size} of #{$checks})"
$failures.each { |f| warn "  - #{f}" }
warn "Fix: NotionRetry (ai/lib/notion_retry.rb) must retry a 429 or 5xx up to ATTEMPTS times, waiting " \
     "Retry-After (capped) or the backoff step through the injected wait, stop before WAIT_BUDGET, never " \
     "retry another status, and try calls once after an exhausted call until one succeeds (DND-1519, DND-1649)."
exit 1
