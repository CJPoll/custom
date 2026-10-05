#!/usr/bin/env bash
# Deterministic suite for the forge-wire judge, the Domain layer of the
# outbound scan at the wire (DND-2025; design ai/docs/outbound-scan-at-the-wire.md):
# ai/lib/forge_wire/{request,graphql,target,fields,operations,verdict}.rb on
# hand-built requests, and on the requests real gh 2.96.0 and glab 1.92.1 sent
# to a local fake upstream (fixtures/, recorded by capture/capture). No
# network, no CLI, no clock, no load (DND-1222). Discovered by
# ai/bin/harness-gate (a committed self-test.sh under a test/ directory).
#
# Run: bash ai/lib/test/forge-wire/self-test.sh
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

PASS=0; FAIL=0
T="$(mktemp -d "${TMPDIR:-/tmp}/dnd-2025-forge-wire.XXXXXX")" || { echo "cannot mktemp. Fix: make \$TMPDIR writable." >&2; exit 2; }
trap 'rm -rf -- "${T}"' EXIT

echo "forge-wire self-test"
for t in request_test graphql_test fields_test target_test operations_test verdict_test fixtures_test; do
  if LC_ALL=C /usr/bin/ruby "${here}/${t}.rb" >"${T}/${t}" 2>&1; then
    printf '  ok    %s.rb (%s)\n' "${t}" "$(tail -1 "${T}/${t}")"; PASS=$((PASS+1))
  else
    printf '  FAIL  %s.rb\n' "${t}"; sed 's/^/        /' "${T}/${t}"; FAIL=$((FAIL+1))
  fi
done

# The capture tool answers --help without running anything.
if /usr/bin/ruby "${here}/capture/capture" --help >"${T}/help" 2>&1 && grep -q '^capture -- ' "${T}/help"; then
  printf '  ok    capture --help\n'; PASS=$((PASS+1))
else
  printf '  FAIL  capture --help\n'; sed 's/^/        /' "${T}/help"; FAIL=$((FAIL+1))
fi

printf '\n%s passed, %s failed\n' "${PASS}" "${FAIL}"
[ "${FAIL}" -eq 0 ]
