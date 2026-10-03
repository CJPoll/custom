#!/usr/bin/env bash
# Sourced by scripts/athena-leadtime-run.sh, scripts/athena-clustering-run.sh and
# scripts/athena-shipwright-run.sh (DND-1560). Definition-only: no side effects
# on load.
#
# The one list of provider limit, billing and auth wordings the cron runners
# read a session's output for, and the one reader of it. A runner calls
# athena_block_signature after a headless session ends. A match on a session
# that did no work means the provider stopped it, so the tick is BLOCKED (exit
# 69, never counted toward the wedge: a usage limit clears on its own).
#
# The list is a CLASSIFIER. Three rules keep its surface narrow (DND-739):
#   * `429` is anchored to the words that make it an HTTP status ("API Error:
#     429", "HTTP 429", "status 429", "code=429"). A bare 429 matched pids,
#     temp paths and SHAs.
#   * Callers pass the session's own output only, never teardown's git chatter
#     appended to the same log.
#   * A caller that matches must also have seen NO evidence of work (no summary,
#     no lane commit). A signature on a session that did work is a failure.
ATHENA_BLOCK_PATTERNS='usage limit|session limit|weekly limit|daily limit|rate limit|rate_limit|quota|out of credits|credit balance|insufficient_quota|billing|overloaded|Too Many Requests|(http|status|error|code)[^a-z0-9]{0,3}429\b|authentication|unauthorized|invalid api key'

# athena_block_signature <log> [bytes] [skip]
#   Prints the first known block signature in <log>, or nothing. With <bytes>,
#   reads only that many bytes after the first <skip> bytes (the shipwright's
#   session slice of a log that teardown also writes). Always exits 0: an
#   unreadable or empty log has no signature, and the caller already holds the
#   session's exit status, which is what separates "no signature" from "could
#   not look" for it.
athena_block_signature() {
  local log="$1" bytes="${2:-}" skip="${3:-0}"
  [ -r "${log}" ] || return 0
  if [ -n "${bytes}" ]; then
    tail -c "+$(( skip + 1 ))" -- "${log}" 2>/dev/null | head -c "${bytes}" 2>/dev/null \
      | grep -m1 -i -E -o "${ATHENA_BLOCK_PATTERNS}" 2>/dev/null || true
  else
    grep -m1 -i -E -o "${ATHENA_BLOCK_PATTERNS}" -- "${log}" 2>/dev/null || true
  fi
}
