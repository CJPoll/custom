# frozen_string_literal: true

# ai/lib/notion_retry.rb -- the ONE retry policy for a Notion read (DND-1649).
#
# Two clients read Notion: NextMissionNotion::HttpTransport (Net::HTTP, behind
# lead-time, next-mission and epic-clustering) and NotionRead (curl, behind
# triage-corpus, ticket-classify --epic, ticket-reclassify, judgment-feedback
# scan-tickets and ticket-provenance-check). DND-1519 gave the first this
# policy; NotionRead kept retrying a 429 only, on the wall clock, so a burst of
# 500 "Cross-cell memcached access is not allowed" (2026-10-01) failed its
# callers on the first try. Both now run each request through this class, so
# the policy has one home.
#
# The policy. A 429 or a 5xx is transient; anything else is not, and is never
# retried. A call is tried up to ATTEMPTS times. Before each retry it waits the
# Retry-After Notion sent (seconds, capped at RETRY_AFTER_CAP), else the next
# BACKOFF step. It stops early rather than let its waits pass WAIT_BUDGET.
#
# A sustained outage must not multiply that budget by every call a run makes.
# After a call exhausts its retries, later calls through the same policy
# object are tried once each, until one succeeds. One policy object per run:
# a caller builds one (HttpTransport) or uses NotionRead.default_retrier.
#
# The policy decides; it does not raise. The caller turns a failed Result into
# its own error, so a failure is always reported, never read as empty.
#
# The wait is injected: `wait:` is called with the seconds to wait. Its
# default is a real sleep. A test injects a recorder, so no test waits on the
# wall clock (DND-1222). Nothing else (no env var, no global) shortens it.
#
# Deliberately gem-free (stdlib only).
class NotionRetry
  ATTEMPTS = 6
  BACKOFF = [1.0, 2.0, 4.0, 8.0, 16.0].freeze
  RETRY_AFTER_CAP = 30.0
  WAIT_BUDGET = 60.0

  # reply: what the request block returned last. status: its HTTP status (0
  # when nothing answered). attempts: how many times it was asked.
  # retryable: the final status was transient. degraded: the call was tried
  # once because an earlier call exhausted its retries.
  Result = Struct.new(:reply, :status, :attempts, :retryable, :degraded, keyword_init: true) do
    def ok?
      status.between?(200, 299)
    end
  end

  def self.retryable?(status)
    status == 429 || status >= 500
  end

  # Seconds to wait before retry number `attempt` (1-based). retry_after is
  # the raw header value or nil. A positive number of seconds (a fraction is
  # kept) is honoured up to the cap; an absent, zero, negative or HTTP-date
  # value falls back to the backoff step.
  def self.wait_for(retry_after, attempt)
    given = retry_after.to_s.strip
    seconds = given.match?(/\A\d+(\.\d+)?\z/) ? given.to_f : 0.0
    return [seconds, RETRY_AFTER_CAP].min if seconds.positive?

    BACKOFF.fetch(attempt - 1, BACKOFF.last)
  end

  def initialize(wait: ->(seconds) { sleep(seconds) })
    @wait = wait
    @degraded = false
  end

  # run { |attempt| [status, retry_after, reply] } -> Result. The block makes
  # one request and returns its status, its raw Retry-After (or nil) and the
  # reply to hand back.
  def run
    degraded = @degraded
    attempts = degraded ? 1 : ATTEMPTS
    waited = 0.0
    attempt = 0
    loop do
      attempt += 1
      status, retry_after, reply = yield(attempt)
      retryable = self.class.retryable?(status)
      if status.between?(200, 299)
        @degraded = false
        return Result.new(reply: reply, status: status, attempts: attempt, retryable: false, degraded: degraded)
      end

      pause = self.class.wait_for(retry_after, attempt)
      if retryable && attempt < attempts && waited + pause <= WAIT_BUDGET
        waited += pause
        @wait.call(pause)
        next
      end
      @degraded = true if retryable
      return Result.new(reply: reply, status: status, attempts: attempt, retryable: retryable, degraded: degraded)
    end
  end
end
