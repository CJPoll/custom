#!/usr/bin/env bash
# self-test for ai/lib/dispatch_trackers.rb (DND-1341) -- discovered by
# harness-gate. Fixture overlay roots only; no network, no real overlay read.
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"

if ! /usr/bin/ruby "$here/dispatch_trackers_test.rb"; then
  echo "dispatch-trackers self-test: FAIL" >&2
  echo "Fix: see the failing checks above; a ticket ref must route to its tracker, and a missing or malformed work-tracker overlay key must be refused by name with Fix:." >&2
  exit 1
fi
echo "dispatch-trackers self-test: PASS"
