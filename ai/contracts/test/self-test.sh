#!/usr/bin/env bash
# Self-test for the contract's pinned `Fix:` quotes (DND-411).
#
# The defect this pins: ai/contracts/athena-events.md quoted, as the exact
# refusal text, a harness-emit Fix: clause that no gen_saas code emitted. Prose
# naming text the code does not emit passes every other gate. This suite:
#   1. runs check-quoted-fix.rb on the REAL contract against the fixture (the
#      live pin — red whenever a quote drifts from the pinned clauses);
#   2. proves the checker can fire: a mutated quote, a dropped quote, a renamed
#      section, and an empty fixture must each fail, and "could not look" (exit 2)
#      must stay distinct from "drifted" (exit 1).
# Hermetic: temp copies only; no network, no git.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONTRACTS="$(cd "${HERE}/.." && pwd)"
CHECK="${HERE}/check-quoted-fix.rb"
CONTRACT="${CONTRACTS}/athena-events.md"
FIXTURE="${CONTRACTS}/fixtures/athena-events-origination-fix.txt"
SECTION="Which event types an ingress kind may originate"

TMP="$(mktemp -d)"; trap 'rm -rf "${TMP}"' EXIT
PASS=0; FAIL=0
ok()  { printf '  ok    %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  FAIL  %s\n        %s\n' "$1" "$2"; FAIL=$((FAIL+1)); }

# expect <label> <want-exit> <contract> <fixture> [section]
expect() {
  local label="$1" want="$2" contract="$3" fixture="$4" section="${5:-${SECTION}}"
  local out rc
  out="$(ruby "${CHECK}" --contract "${contract}" --fixture "${fixture}" --section "${section}" 2>&1)"
  rc=$?
  if [ "${rc}" -eq "${want}" ]; then
    ok "${label} (exit ${rc})"
  else
    bad "${label}" "want exit ${want}, got ${rc}: ${out}"
  fi
  if [ "${rc}" -ne 0 ] && ! printf '%s' "${out}" | grep -q 'Fix:'; then
    bad "${label}: failure output carries Fix:" "${out}"
  fi
}

echo "contract Fix: quote pins (athena-events.md)"

# 1. The live pin.
expect "real contract quotes match the pinned clauses" 0 "${CONTRACT}" "${FIXTURE}"

# 2. The checker can fire.
cp "${CONTRACT}" "${TMP}/mutated.md"
# Whitespace-insensitive: the quote wraps across lines in the contract.
ruby -e 'p = ARGV[0]; File.write(p, File.read(p).sub(/whatever\s+its\s+registration\s+says/, "whatever its registration claims"))' "${TMP}/mutated.md"
if cmp -s "${CONTRACT}" "${TMP}/mutated.md"; then
  bad "mutation applied" "the mutation target is gone from the contract; update this test"
else
  expect "a reworded quote is drift" 1 "${TMP}/mutated.md" "${FIXTURE}"
fi

grep -v '^Fix: register' "${FIXTURE}" > "${TMP}/short-fixture.txt"
expect "a quote the fixture does not pin is drift" 1 "${CONTRACT}" "${TMP}/short-fixture.txt"

expect "a renamed section cannot be measured" 2 "${CONTRACT}" "${FIXTURE}" "No such section heading"

grep '^#' "${FIXTURE}" > "${TMP}/empty-fixture.txt"
expect "an empty fixture cannot be measured" 2 "${CONTRACT}" "${TMP}/empty-fixture.txt"

expect "a section with no Fix: quotes cannot be measured" 2 "${CONTRACT}" "${FIXTURE}" "Harness-emit"

printf '%d passed, %d failed\n' "${PASS}" "${FAIL}"
if [ "${FAIL}" -ne 0 ]; then
  echo "Fix: read the FAIL lines above; case 1 red means the contract quote and the fixture drifted (see the fixture header for which side to change)."
  exit 1
fi
