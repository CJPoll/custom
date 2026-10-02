#!/usr/bin/env bash
# Functional suite for ai/bin/shipwright-artifacts. Discovered and run by
# harness-gate. Everything lives in a mktemp -d; nothing reads the real state.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOL="$(cd "${HERE}/../.." && pwd)/bin/shipwright-artifacts"

TMP="$(mktemp -d)"; trap 'rm -rf "${TMP}"' EXIT
PASS=0; FAIL=0
ok()  { printf '  ok    %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  FAIL  %s\n        %s\n' "$1" "$2"; FAIL=$((FAIL+1)); }

# run NAME ARGS... -> sets RC, OUT, ERR
run() {
  OUT="$(env -u SHIPWRIGHT_STATE_DIR "${TOOL}" "$@" 2>"${TMP}/err")"; RC=$?
  ERR="$(cat "${TMP}/err")"
}

mkroot() {
  local root="$1"
  mkdir -p "${root}/run-a/reports" "${root}/run-b"
  printf 'a\n' > "${root}/run-a/reports/A-report.md"
  printf 'b\n' > "${root}/run-b/state.md"
  touch -d '2026-10-01T10:00:00.100000001Z' "${root}/run-a/reports/A-report.md"
  touch -d '2026-10-01T10:00:00.100000002Z' "${root}/run-b/state.md"
}

echo "shipwright-artifacts self-test"

# 1. First run: no journal, no cursor -> everything is listed.
S="${TMP}/s1"; R="${TMP}/r1"; mkdir -p "${S}"; mkroot "${R}"
run --state-dir "${S}" --root "${R}"
if [ "${RC}" = 0 ] && grep -q 'A-report.md' <<<"${OUT}" \
   && grep -q 'first run' <<<"${OUT}" \
   && grep -q '2 considered, 2 newer' <<<"${OUT}"; then
  ok "1. first run lists every artifact"
else bad "1. first run lists every artifact" "rc=${RC} out=${OUT} err=${ERR}"; fi

# 2. Damaged state: journal present, cursor absent -> exit 3, nothing listed.
S="${TMP}/s2"; mkdir -p "${S}"; : > "${S}/journal.md"
run --state-dir "${S}" --root "${R}"
if [ "${RC}" = 3 ] && [ -z "${OUT}" ] && grep -q 'DAMAGED STATE' <<<"${ERR}" \
   && grep -q 'Fix:' <<<"${ERR}"; then
  ok "2. journal without cursor is damaged state, exit 3, empty stdout"
else bad "2. journal without cursor is damaged state" "rc=${RC} out=${OUT} err=${ERR}"; fi

# 3. A nanosecond cursor equal to A's mtime selects only the later B.
S="${TMP}/s3"; mkdir -p "${S}"; : > "${S}/journal.md"
printf '2026-10-01T04:00:00.100000001-06:00\n' > "${S}/cursor.txt"
run --state-dir "${S}" --root "${R}"
if [ "${RC}" = 0 ] && ! grep -q 'A-report.md' <<<"${OUT}" \
   && grep -q 'state.md' <<<"${OUT}" \
   && grep -q '2 considered, 1 newer' <<<"${OUT}" \
   && grep -q 'next cursor: 2026-10-01T[0-9:]*\.100000002' <<<"${OUT}"; then
  ok "3. nanosecond cursor: equal mtime excluded, 1 ns later included, next cursor exact"
else bad "3. nanosecond cursor" "rc=${RC} out=${OUT} err=${ERR}"; fi

# 4. Nothing newer is a visible zero: newest overall shown, cursor unchanged.
printf '2026-10-01T11:00:00Z\n' > "${S}/cursor.txt"
run --state-dir "${S}" --root "${R}"
if [ "${RC}" = 0 ] && grep -q '2 considered, 0 newer' <<<"${OUT}" \
   && grep -q 'newest overall .*state.md' <<<"${OUT}" \
   && grep -q 'next cursor: unchanged' <<<"${OUT}"; then
  ok "4. zero newer names the newest file and leaves the cursor"
else bad "4. zero newer" "rc=${RC} out=${OUT} err=${ERR}"; fi

# 5. An epoch cursor parses too.
printf '1790845200.1\n' > "${S}/cursor.txt"
run --state-dir "${S}" --root "${R}"
if [ "${RC}" = 0 ] && grep -q 'considered' <<<"${OUT}"; then
  ok "5. epoch cursor parses"
else bad "5. epoch cursor parses" "rc=${RC} out=${OUT} err=${ERR}"; fi

# 6. An unparseable cursor is could-not-look, never a zero.
printf 'yesterday-ish\n' > "${S}/cursor.txt"
run --state-dir "${S}" --root "${R}"
if [ "${RC}" = 3 ] && [ -z "${OUT}" ] && grep -q 'Fix:' <<<"${ERR}"; then
  ok "6. unparseable cursor exits 3 with a Fix:"
else bad "6. unparseable cursor" "rc=${RC} out=${OUT} err=${ERR}"; fi

# 7. A missing root is could-not-look, never a zero.
printf '2026-10-01T11:00:00Z\n' > "${S}/cursor.txt"
run --state-dir "${S}" --root "${TMP}/no-such-root"
if [ "${RC}" = 3 ] && [ -z "${OUT}" ] && grep -q 'no-such-root' <<<"${ERR}"; then
  ok "7. missing root exits 3 naming it"
else bad "7. missing root" "rc=${RC} out=${OUT} err=${ERR}"; fi

# 8. SHIPWRIGHT_STATE_DIR is used when --state-dir is absent.
OUT="$(SHIPWRIGHT_STATE_DIR="${TMP}/s2" "${TOOL}" --root "${R}" 2>"${TMP}/err")"; RC=$?
ERR="$(cat "${TMP}/err")"
if [ "${RC}" = 3 ] && grep -q 'SHIPWRIGHT_STATE_DIR set' <<<"${ERR}"; then
  ok "8. SHIPWRIGHT_STATE_DIR selects the state dir"
else bad "8. SHIPWRIGHT_STATE_DIR selects the state dir" "rc=${RC} out=${OUT} err=${ERR}"; fi

# 9. An unknown flag is refused, stdout empty.
run --state-dir "${S}" --root "${R}" --cursr x
if [ "${RC}" = 2 ] && [ -z "${OUT}" ] && grep -q -- '--cursr' <<<"${ERR}" \
   && grep -q 'Fix:' <<<"${ERR}"; then
  ok "9. unknown flag refused with exit 2"
else bad "9. unknown flag refused" "rc=${RC} out=${OUT} err=${ERR}"; fi

# 10. --help answers on stdout, exit 0.
run --help
if [ "${RC}" = 0 ] && grep -q '^Usage:' <<<"${OUT}"; then
  ok "10. --help on stdout, exit 0"
else bad "10. --help" "rc=${RC} out=${OUT} err=${ERR}"; fi

echo "shipwright-artifacts self-test: ${PASS} passed, ${FAIL} failed"
[ "${FAIL}" = 0 ]
