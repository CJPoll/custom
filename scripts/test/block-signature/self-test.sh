#!/usr/bin/env bash
# Self-test for scripts/lib/block-signature.sh (DND-1560): the shared reader of
# provider limit wordings. Each case feeds a log and asserts the signature (or
# none) it prints. No network, no model.
#
# Run: bash scripts/test/block-signature/self-test.sh

set -uo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/lib/block-signature.sh
. "${HERE}/../../lib/block-signature.sh"

PASS=0; FAIL=0
ok()  { printf '  ok    %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  FAIL  %s\n        %s\n' "$1" "${2:-}"; FAIL=$((FAIL+1)); }
expect() { # <claim> <expected> <actual>
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$2] got [$3]"; fi
}

T="$(mktemp -d)"
trap 'rm -rf -- "$T"' EXIT

printf '\nathena_block_signature — what a session log says\n'
printf "You've hit your weekly limit\n" >"${T}/weekly"
expect "the weekly limit wording matches" "weekly limit" "$(athena_block_signature "${T}/weekly")"
printf "You've hit your session limit · resets 6:30am\n" >"${T}/session"
expect "the session limit wording matches" "session limit" "$(athena_block_signature "${T}/session")"
printf 'API Error: 429 {"type":"error"}\n' >"${T}/http429"
expect "an HTTP 429 anchored to its words matches" "Error: 429" "$(athena_block_signature "${T}/http429")"
printf 'wrote /tmp/run-4291.log pid 429\n' >"${T}/bare429"
expect "a bare 429 (a pid, a path) does not match" "" "$(athena_block_signature "${T}/bare429")"
printf 'segmentation fault\n' >"${T}/crash"
expect "a crash with no limit wording matches nothing" "" "$(athena_block_signature "${T}/crash")"
: >"${T}/empty"
expect "an empty log matches nothing" "" "$(athena_block_signature "${T}/empty")"
athena_block_signature "${T}/absent" >/dev/null; rc=$?
expect "an absent log exits 0 with nothing (the caller holds the session's exit status)" "0" "${rc}"

printf '\nathena_block_signature <log> <bytes> <skip> — only the session slice\n'
printf 'before: usage limit\nSESSION: fine\nafter: weekly limit\n' >"${T}/slice"
pre="$(printf 'before: usage limit\n' | wc -c | tr -d ' ')"
len="$(printf 'SESSION: fine\n' | wc -c | tr -d ' ')"
expect "wording before the slice and after it is not read" "" "$(athena_block_signature "${T}/slice" "${len}" "${pre}")"
printf 'before: fine\nSESSION: rate limit\nafter: fine\n' >"${T}/slice2"
pre="$(printf 'before: fine\n' | wc -c | tr -d ' ')"
len="$(printf 'SESSION: rate limit\n' | wc -c | tr -d ' ')"
expect "wording inside the slice matches" "rate limit" "$(athena_block_signature "${T}/slice2" "${len}" "${pre}")"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || echo "Fix: read each FAIL line above; it names the claim that broke. Re-run with: bash scripts/test/block-signature/self-test.sh"
[ "$FAIL" -eq 0 ]
