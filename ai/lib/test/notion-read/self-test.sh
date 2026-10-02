#!/usr/bin/env bash
# Deterministic suite for the shared Notion retry policy (DND-1649):
# ai/lib/notion_retry.rb on its own, and NotionRead (ai/lib/notion_read.rb)
# running its real curl request against a fake Notion on loopback. The retry
# wait is injected and recorded, so nothing waits on the wall clock and
# nothing generates load (DND-1222). LC_ALL=C pins the read of a raw UTF-8
# body (DND-1054). Discovered by ai/bin/harness-gate (a committed self-test.sh
# under a test/ directory).
#
# Run: bash ai/lib/test/notion-read/self-test.sh
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

PASS=0; FAIL=0
T="$(mktemp -d "${TMPDIR:-/tmp}/dnd-1649-notion-read.XXXXXX")" || { echo "cannot mktemp. Fix: make \$TMPDIR writable." >&2; exit 2; }
trap 'rm -rf -- "${T}"' EXIT

echo "notion-read self-test"
for t in notion_retry_policy_test notion_read_test; do
  if LC_ALL=C /usr/bin/ruby "${here}/${t}.rb" >"${T}/${t}" 2>&1; then
    printf '  ok    %s.rb (%s)\n' "${t}" "$(tail -1 "${T}/${t}")"; PASS=$((PASS+1))
  else
    printf '  FAIL  %s.rb\n' "${t}"; sed 's/^/        /' "${T}/${t}"; FAIL=$((FAIL+1))
  fi
done

printf '\n%s passed, %s failed\n' "${PASS}" "${FAIL}"
[ "${FAIL}" -eq 0 ]
