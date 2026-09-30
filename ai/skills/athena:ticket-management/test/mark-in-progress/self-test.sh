#!/usr/bin/env bash
# self-test for scripts/mark-in-progress (DND-1318) -- discovered by harness-gate
# (every committed self-test.sh runs). A fake Notion transport stands in for
# the network; no token is read.
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
bin="$here/../../scripts/mark-in-progress"

if [ ! -x "$bin" ]; then
  echo "mark-in-progress self-test: FAIL -- $bin missing or not executable" >&2
  echo "Fix: chmod +x ai/skills/athena:ticket-management/scripts/mark-in-progress" >&2
  exit 1
fi

fail=0
if ! /usr/bin/ruby "$here/mark_in_progress_test.rb"; then
  fail=1
fi

out="$("$bin" --help)"; code=$?
if [ "$code" -ne 0 ] || ! grep -q 'Usage:' <<<"$out"; then
  echo "  FAIL  --help answers on stdout with exit 0 (code=$code)"
  fail=1
fi

if [ "$fail" -ne 0 ]; then
  echo "mark-in-progress self-test: FAIL" >&2
  echo "Fix: see the failing checks above; the script must stamp 'In Progress at' once, with the status, and refuse every miss with Fix:." >&2
  exit 1
fi
echo "mark-in-progress self-test: PASS"
