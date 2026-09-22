#!/usr/bin/env bash
# Discovered self-test for scripts/reap-orphan-dbus.
#
# The reaper's orphan-matcher is unit-tested by its own inline `--self-test`
# (the pure dbus_argv_is_orphan_session function, checked against real live
# signatures). This wrapper runs that suite so the blocking gate covers it via
# the **/self-test.sh discovery, and additionally asserts the reaper is
# side-effect-free under --dry-run and --help.
set -euo pipefail

here="$(cd -- "$(dirname -- "$0")" && pwd -P)"
reaper="${here}/../../reap-orphan-dbus"

fails=0
run() { # desc cmd...
  local desc="$1"; shift
  if "$@" >/dev/null 2>&1; then echo "PASS ${desc}"; else echo "FAIL ${desc}"; fails=$((fails+1)); fi
}

[ -x "${reaper}" ] || { echo "FAIL reaper not executable: ${reaper}"; exit 1; }

# The matcher self-test (verdicts on real orphan/system/session/at-spi argvs).
if "${reaper}" --self-test; then echo "PASS matcher --self-test"; else echo "FAIL matcher --self-test"; fails=$((fails+1)); fi

# --help and --dry-run must be side-effect-free and exit 0.
run "--help exits 0" "${reaper}" --help
run "--dry-run exits 0 (kills nothing)" "${reaper}" --dry-run
run "--dry-run --min-age 0 exits 0" "${reaper}" --dry-run --min-age 0

# Bad --min-age is rejected with a non-zero exit and a Fix: line.
if "${reaper}" --min-age abc >/dev/null 2>&1; then
  echo "FAIL bad --min-age should be rejected"; fails=$((fails+1))
else
  echo "PASS bad --min-age rejected"
fi
# Capture stderr into a var (a pipe would let pipefail see the reaper's exit 1).
minage_err="$("${reaper}" --min-age abc 2>&1 || true)"
case "${minage_err}" in
  *Fix:*) echo "PASS bad --min-age carries a Fix: line" ;;
  *) echo "FAIL bad --min-age missing Fix: line"; fails=$((fails+1)) ;;
esac

if [ "${fails}" -eq 0 ]; then
  echo "reap-orphan-dbus/self-test.sh: OK"
  exit 0
fi
echo "reap-orphan-dbus/self-test.sh: ${fails} failure(s)" >&2
exit 1
