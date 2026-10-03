#!/usr/bin/env bash
# self-test for lead time across a Park (DND-1838) -- discovered by harness-gate
# (every committed self-test.sh runs). mark-in-progress writes the dispatch
# stamp and ai/bin/lead-time reads it back, through one fake Notion; no network.
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"

if ! /usr/bin/ruby "$here/park_test.rb"; then
  echo "lead-time park self-test: FAIL" >&2
  echo "Fix: see the failing checks above (ai/docs/lead-time-tracking.md -> Decisions)." >&2
  exit 1
fi
echo "lead-time park self-test: PASS"
