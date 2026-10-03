#!/usr/bin/env bash
# Sourced by scripts/athena-leadtime-run.sh, scripts/athena-clustering-run.sh and
# scripts/athena-shipwright-run.sh (DND-1560). Definition-only: no side effects
# on load.
#
# The one list of provider limit, billing and auth wordings the cron runners
# read a session's output for, and the one reader of it. A runner calls a reader
# after a headless session ends. A match on a session that did no work means the
# provider stopped it, so the tick is BLOCKED (exit 69, never counted toward the
# wedge: a usage limit clears on its own).
#
# The list is a CLASSIFIER. Rules that keep its surface narrow (DND-739):
#   * `429` is anchored to the words that make it an HTTP status ("API Error:
#     429", "HTTP 429", "status 429", "code=429"). A bare 429 matched pids,
#     temp paths and SHAs.
#   * Callers pass the session's own output only, never teardown's git chatter
#     appended to the same log.
#   * A caller that matches must also have seen NO evidence of work (no summary,
#     no lane commit). A signature on a session that did work is a failure.
#   * A session that left its receipt is read through athena_block_signature_final
#     (the closing bytes only). Words like "authentication" in the middle of a
#     long log are a tool's output, not the provider's final word, and must not
#     turn a real failure into a self-clearing outage.
ATHENA_BLOCK_PATTERNS='usage limit|session limit|weekly limit|daily limit|rate limit|rate_limit|quota|out of credits|credit balance|insufficient_quota|billing|overloaded|Too Many Requests|(http|status|error|code)[^a-z0-9]{0,3}429\b|authentication|unauthorized|invalid api key'
# How much of the end of a session's output athena_block_signature_final reads.
ATHENA_BLOCK_FINAL_BYTES=2048

# athena_block_signature <log> [bytes] [skip]
#   Prints the first known block signature in <log>, or nothing. With <bytes>,
#   reads only that many bytes after the first <skip> bytes (the shipwright's
#   session slice of a log that teardown also writes). Always exits 0: an
#   unreadable or empty log has no signature. A caller that treats a signature
#   as the only way to a BLOCKED outcome therefore fails safe: an unreadable log
#   stays a counted failure.
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

# athena_block_signature_final <log> [bytes] [skip]
#   As athena_block_signature, but reads only the last ATHENA_BLOCK_FINAL_BYTES
#   bytes of the same range: the provider's closing message, which is where a
#   limit or auth stop prints.
athena_block_signature_final() {
  local log="$1" bytes="${2:-}" skip="${3:-0}"
  [ -r "${log}" ] || return 0
  if [ -n "${bytes}" ]; then
    tail -c "+$(( skip + 1 ))" -- "${log}" 2>/dev/null | head -c "${bytes}" 2>/dev/null \
      | tail -c "${ATHENA_BLOCK_FINAL_BYTES}" 2>/dev/null \
      | grep -m1 -i -E -o "${ATHENA_BLOCK_PATTERNS}" 2>/dev/null || true
  else
    tail -c "${ATHENA_BLOCK_FINAL_BYTES}" -- "${log}" 2>/dev/null \
      | grep -m1 -i -E -o "${ATHENA_BLOCK_PATTERNS}" 2>/dev/null || true
  fi
}
