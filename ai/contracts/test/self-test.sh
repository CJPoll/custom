#!/usr/bin/env bash
# Self-test for the contract's pinned refusal quotes (DND-411).
#
# The defect this pins: ai/contracts/athena-events.md quoted, as the exact
# refusal text, strings no gen_saas code emitted. Prose naming text the code
# does not emit passes every other gate. This suite:
#   1. runs check-quoted-fix.rb on the REAL contract against the fixture (the
#      live pin — red whenever a quote drifts from the pinned text);
#   2. proves the checker can fire: a reworded quote and an unpinned quote must
#      fail (exit 1), including one after a fenced `#` line; a renamed section,
#      a section with no quotes, unbalanced backticks, and an empty fixture must
#      fail as "could not look" (exit 2), never as a match.
# Hermetic: temp copies only; no network, no git.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONTRACTS="$(cd "${HERE}/.." && pwd)"
CHECK="${HERE}/check-quoted-fix.rb"
CONTRACT="${CONTRACTS}/athena-events.md"
FIXTURE="${CONTRACTS}/fixtures/athena-events-quoted-fix.txt"

TMP="$(mktemp -d)"; trap 'rm -rf "${TMP}"' EXIT
PASS=0; FAIL=0
ok()  { printf '  ok    %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  FAIL  %s\n        %s\n' "$1" "$2"; FAIL=$((FAIL+1)); }

# expect <label> <want-exit> <contract> <fixture>
expect() {
  local label="$1" want="$2" contract="$3" fixture="$4"
  local out rc
  out="$(ruby "${CHECK}" --contract "${contract}" --fixture "${fixture}" 2>&1)"
  rc=$?
  if [ "${rc}" -eq "${want}" ]; then
    ok "${label} (exit ${rc})"
  else
    bad "${label}" "want exit ${want}, got ${rc}: ${out}"
  fi
  if [ "${rc}" -ne 0 ] && ! grep -q 'Fix:' <<<"${out}"; then
    bad "${label}: failure output carries Fix:" "${out}"
  fi
}

echo "contract refusal-quote pins (athena-events.md)"

# 1. The live pin.
expect "real contract quotes match the pinned text" 0 "${CONTRACT}" "${FIXTURE}"

# 2. The checker can fire.
cp "${CONTRACT}" "${TMP}/mutated.md"
# Whitespace-insensitive: the quote may wrap across lines in the contract.
ruby -e 'p = ARGV[0]; File.write(p, File.read(p).sub(/whatever\s+its\s+registration\s+says/, "whatever its registration claims"))' "${TMP}/mutated.md"
if cmp -s "${CONTRACT}" "${TMP}/mutated.md"; then
  bad "mutation applied" "the mutation target is gone from the contract; update this test"
else
  expect "a reworded quote is drift" 1 "${TMP}/mutated.md" "${FIXTURE}"
fi

grep -v '^Fix: register' "${FIXTURE}" > "${TMP}/short-fixture.txt"
expect "a quote the fixture does not pin is drift" 1 "${CONTRACT}" "${TMP}/short-fixture.txt"

sed 's/^@section The predicate grammar$/@section No such section heading/' "${FIXTURE}" > "${TMP}/renamed.txt"
if cmp -s "${FIXTURE}" "${TMP}/renamed.txt"; then
  bad "rename applied" "the fixture has no '@section The predicate grammar' line; update this test"
else
  expect "a renamed section cannot be measured" 2 "${CONTRACT}" "${TMP}/renamed.txt"
fi

printf '@section Harness-emit\nFix: anything\n' > "${TMP}/no-quotes.txt"
expect "a section with no quotes cannot be measured" 2 "${CONTRACT}" "${TMP}/no-quotes.txt"

# A fenced `#` line must not end the section early and hide a later quote.
printf '### Alpha\n\n```\n# not a heading\n```\n\nrefused: `Fix: pinned one`\n\n### Beta\n' > "${TMP}/fenced.md"
printf '@section Alpha\nFix: pinned one\n' > "${TMP}/fenced-fixture.txt"
expect "a # line inside a fence is not a heading" 0 "${TMP}/fenced.md" "${TMP}/fenced-fixture.txt"
printf '### Alpha\n\n```\n# not a heading\n```\n\nrefused: `Fix: pinned one`, and `Fix: unpinned`\n' > "${TMP}/fenced-extra.md"
expect "a quote after a fenced # line is still seen" 1 "${TMP}/fenced-extra.md" "${TMP}/fenced-fixture.txt"

printf '### Alpha\n\nrefused: `Fix: pinned one` and a stray ` backtick\n' > "${TMP}/odd.md"
expect "unbalanced backticks cannot be measured" 2 "${TMP}/odd.md" "${TMP}/fenced-fixture.txt"

grep '^#' "${FIXTURE}" > "${TMP}/empty-fixture.txt"
expect "an empty fixture cannot be measured" 2 "${CONTRACT}" "${TMP}/empty-fixture.txt"

printf '%d passed, %d failed\n' "${PASS}" "${FAIL}"
if [ "${FAIL}" -ne 0 ]; then
  echo "Fix: read the FAIL lines above; case 1 red means the contract quote and the fixture drifted (see the fixture header for which side to change)."
  exit 1
fi
