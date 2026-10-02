#!/usr/bin/env bash
# common.sh -- the preamble the six fleet-control suites share (DND-1007).
# Sourced, never run. Each suite is its own self-test.sh under control/, so
# harness-gate discovers and runs them as six checks side by side:
#   domain/       the pure domain rules and the cache/zone effects (no server)
#   server/       fleet-control check/fetch against the fake server, and usage
#   watch/        admiral-report-watch CONTROL lines
#   wait/         the resume waiter (DND-484) test 1: resuming from the server
#   wait-basis/   the waiter's test 2: a non-server run is never a resume
#   wait-limits/  its tests 3-5 (refusals, usage, budget), trap, own, test 7b
# They were one 124-137 s suite (DND-443), the parallel gate's floor. The
# wait part was then the floor (about 17 s alone, all in the waiter's real
# polls and budgets), so DND-1361 split it three ways (wait-fixture.sh holds
# what they share). `fleet-control --self-test` runs all six.
#
# TDD order (DND-443):
#   1. domain  -- lib/fleet/control-domain.sh: shapes, desired/3 mirror, the
#      local rule, work-hours math (DST, weekend, holiday, boundaries), causes;
#   2. effects -- lib/fleet/control-effects.sh: cache path, atomic write, read;
#   3. end to end -- bin/fleet-control against a FAKE server (loopback only;
#      never prod): every basis, every cause as its own outcome (the MISS is
#      tested, not just the hit), the coordinator's acceptance case, and resume
#      through a stale drain cache.


set -u
# DND-1163: the athena:inbox bins resolve the session's project from
# CLAUDE_PROJECT_DIR, then /proc/$CLAUDE_PID/cwd, before the cwd. Scrubbed so
# the fixtures, not the Claude session running this suite, decide the project.
unset CLAUDE_PROJECT_DIR CLAUDE_PID

CONTROL="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
TESTS="$(cd -- "${CONTROL}/.." && pwd -P)"
LIB="$(cd -- "${TESTS}/.." && pwd -P)"
AI="$(cd -- "${LIB}/../.." && pwd -P)"
BIN="${AI}/bin/fleet-control"
FAKE="${TESTS}/fake-fleet-server.py"

PASS=0
FAIL=0
ok()   { PASS=$((PASS + 1)); printf 'ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL + 1)); printf 'FAIL %s\n' "$1"; [ -n "${2:-}" ] && printf '     %s\n' "$2"; return 0; }
check() { local name="$1"; shift; if "$@"; then ok "${name}"; else bad "${name}"; fi; }
eq()   { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$3], got [$2]"; fi; }
has()  { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "[$3] not in [$2]" ;; esac; }
hasnt() { case "$2" in *"$3"*) bad "$1" "[$3] unexpectedly in [$2]" ;; *) ok "$1" ;; esac; }

for dep in jq curl python3 git flock timeout date; do
  command -v "${dep}" >/dev/null 2>&1 || { echo "fleet-control self-test: FAIL -- ${dep} is not on PATH"; echo "  Fix: install ${dep}; this suite does not skip."; exit 1; }
done
[ -f /usr/share/zoneinfo/America/Denver ] || [ -f "${TZDIR:-/nonexistent}/America/Denver" ] || {
  echo "fleet-control self-test: FAIL -- the tz database has no America/Denver"; echo "  Fix: install tzdata; the work-hours cases need it."; exit 1; }

# shellcheck source=../../domain.sh
. "${LIB}/domain.sh"
# shellcheck source=../../control-domain.sh
. "${LIB}/control-domain.sh"

TMP="$(mktemp -d)" || { echo "FAIL mktemp"; exit 1; }
SERVER_PID=""
HOLDER_PID=""
SPARE_SERVER_PID=""   # a suite's second fake server (DND-1719)
cleanup() {
  [ -n "${SERVER_PID}" ] && kill "${SERVER_PID}" 2>/dev/null
  [ -n "${HOLDER_PID}" ] && kill "${HOLDER_PID}" 2>/dev/null
  [ -n "${SPARE_SERVER_PID}" ] && kill "${SPARE_SERVER_PID}" 2>/dev/null
  rm -rf "${TMP}"
}
trap cleanup EXIT INT TERM

# den <YYYY-MM-DD HH:MM[:SS]> -- epoch of a wall-clock time in America/Denver.
den() { TZ=America/Denver date -d "$1" +%s; }

SID="0cc59a5e-6c65-495e-a216-83c6a0bf2d56"
THU_10=$(den "2026-09-24 10:00")      # Thursday, work hours (the acceptance instant)
P1_SNAP='{"override":null,"effective_domain":"personal","metering":{"enabled":false}}'
METER_SNAP="$(fleet_local_rule_snapshot gen_saas)"   # metering on, personal, 08-18 M-F

# answer <desired> <reason> <until-json> <snapshot-json> [sid]
answer() {
  jq -n -c --arg s "${5:-${SID}}" --arg d "$1" --arg r "$2" --argjson u "$3" --argjson p "$4" \
    '{claude_session_id: $s, desired: $d, reason: $r, until: $u, policy_snapshot: $p}'
}

# Shared by every part (they were set inside the domain section before
# DND-1007 split the suite).
GOOD="$(answer run default null "${P1_SNAP}")"
OV_DRAIN='{"override":{"desired":"drain","expires_at":null},"effective_domain":"blend","metering":{"enabled":false}}'

# finish <part> -- the part's verdict; exits.
finish() {
  echo
  echo "${PASS} passed, ${FAIL} failed"
  if [ "${FAIL}" -ne 0 ]; then
    echo "fleet-control self-test ($1): FAIL"
    echo "  Fix: read the FAIL lines above; each names the rule it checks (athena-events.md -> Unknown control state)."
    exit 1
  fi
  echo "fleet-control self-test ($1): OK"
  exit 0
}
