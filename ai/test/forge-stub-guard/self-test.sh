#!/usr/bin/env bash
# self-test for ai/lib/forge-stub-guard.sh (DND-1647) — discovered and run by
# harness-gate.
#
# The defect it pins: a suite that stubs gh/glab on PATH fell through to the
# REAL CLI when a stub was missing or not executable, and the suite passed.
# Every case here puts a recording fake "real" gh/glab LATER on PATH, standing
# in for the installed CLI, so no case can reach the live forge even if the
# guard is broken. A record in that fake's log is the defect.
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
LIB="$here/../../lib/forge-stub-guard.sh"
if [ ! -f "${LIB}" ]; then
  echo "forge-stub-guard self-test: FAIL — ${LIB} is missing" >&2
  echo "Fix: restore ai/lib/forge-stub-guard.sh" >&2
  exit 1
fi

PASS=0; FAIL=0
ok()  { printf '  ok    %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  FAIL  %s\n        %s\n' "$1" "$2"; FAIL=$((FAIL+1)); }

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

# The stand-in for the installed CLI: records argv, never touches a network.
REAL="${TMP}/real"; mkdir -p "${REAL}"
for t in gh glab; do
  printf '#!/bin/sh\nprintf "%%s %%s\\n" "${0##*/}" "$*" >> "%s/calls.log"\necho REAL-REACHED\nexit 0\n' "${REAL}" > "${REAL}/${t}"
  chmod +x "${REAL}/${t}"
done
BASE_PATH="${REAL}:/usr/bin:/bin"
reset_real() { : > "${REAL}/calls.log"; }
real_calls() { cat "${REAL}/calls.log"; }

# case <n> : a fresh dir for one case.
casedir() { mkdir -p "${TMP}/$1"; printf '%s' "${TMP}/$1"; }

# --- G1. fsg_arm builds the guard and puts it first on PATH.
D="$(casedir g1)"
OUT="$( (PATH="${BASE_PATH}"; . "${LIB}"; fsg_arm "${D}/guard"
  printf '%s|%s|' "${FSG_DIR}" "${PATH%%:*}"
  [ -x "${D}/guard/gh" ] && [ -x "${D}/guard/glab" ] && [ -f "${D}/guard/fallthrough.log" ] \
    && [ ! -s "${D}/guard/fallthrough.log" ] && printf 'built') 2>&1)"
[ "${OUT}" = "${D}/guard|${D}/guard|built" ] \
  && ok "G1. fsg_arm makes executable gh/glab guards, an empty log, sets FSG_DIR, and leads PATH" \
  || bad "G1. fsg_arm builds the guard" "out=${OUT}"

# run_case <dir> <stub-setup> <cmd...>: arm, prepend <dir>/stubs, run cmd.
# Prints "<rc>" on line 1 of ${dir}/rc; stderr to ${dir}/err; stdout to ${dir}/out.
run_case() {
  local d="$1" setup="$2"; shift 2
  mkdir -p "${d}/stubs"
  eval "${setup}"
  (PATH="${BASE_PATH}"; . "${LIB}"; fsg_arm "${d}/guard"; PATH="${d}/stubs:${PATH}"
   "$@" >"${d}/out" 2>"${d}/err"; echo "$?" >"${d}/rc"
   fsg_verify 2>"${d}/verr"; echo "$?" >"${d}/vrc")
}

# --- G2. THE REGRESSION: a non-executable gh stub never reaches the real gh.
reset_real; D="$(casedir g2)"
run_case "${D}" 'printf "#!/bin/sh\necho STUB\n" > "${d}/stubs/gh"' gh pr view 7
if [ "$(cat "${D}/rc")" = 97 ] && [ -z "$(real_calls)" ] && grep -q 'not executable' "${D}/err" \
   && grep -q 'Fix:' "${D}/err" && [ "$(cat "${D}/guard/fallthrough.log")" = "$(printf 'gh\tpr view 7')" ]; then
  ok "G2. a non-executable gh stub: exit 97 with a Fix:, logged, the real gh NOT run"
else bad "G2. non-executable gh stub fails loudly" "rc=$(cat "${D}/rc") real=$(real_calls) err=$(head -c 300 "${D}/err")"; fi

# --- G3. A missing glab stub never reaches the real glab.
reset_real; D="$(casedir g3)"
run_case "${D}" ':' glab mr view 5
if [ "$(cat "${D}/rc")" = 97 ] && [ -z "$(real_calls)" ] && grep -q 'Fix:' "${D}/err" \
   && [ "$(cat "${D}/guard/fallthrough.log")" = "$(printf 'glab\tmr view 5')" ]; then
  ok "G3. a missing glab stub: exit 97 with a Fix:, logged, the real glab NOT run"
else bad "G3. missing glab stub fails loudly" "rc=$(cat "${D}/rc") real=$(real_calls) err=$(head -c 300 "${D}/err")"; fi

# --- G4. fsg_verify fails a suite that swallowed the guard's exit.
if [ "$(cat "${D}/vrc")" = 1 ] && grep -q 'past its stub 1 time' "${D}/verr" \
   && grep -q 'glab	mr view 5' "${D}/verr" && grep -q 'Fix:' "${D}/verr"; then
  ok "G4. fsg_verify after a fall-through: returns 1, names the call, carries a Fix:"
else bad "G4. fsg_verify reports the fall-through" "vrc=$(cat "${D}/vrc") verr=$(head -c 300 "${D}/verr")"; fi

# --- G5. An executable stub runs; nothing is logged; fsg_verify passes.
reset_real; D="$(casedir g5)"
run_case "${D}" 'printf "#!/bin/sh\necho STUB-GH\n" > "${d}/stubs/gh"; chmod +x "${d}/stubs/gh"' gh pr view 7
if [ "$(cat "${D}/rc")" = 0 ] && [ "$(cat "${D}/out")" = STUB-GH ] && [ -z "$(real_calls)" ] \
   && [ ! -s "${D}/guard/fallthrough.log" ] && [ "$(cat "${D}/vrc")" = 0 ] && [ ! -s "${D}/verr" ]; then
  ok "G5. an executable stub answers; the guard stays silent; fsg_verify returns 0"
else bad "G5. a healthy stub passes" "rc=$(cat "${D}/rc") out=$(cat "${D}/out") vrc=$(cat "${D}/vrc")"; fi

# --- G6. A lost guard log is "could not measure", never clean.
D="$(casedir g6)"
OUT="$( (PATH="${BASE_PATH}"; . "${LIB}"; fsg_arm "${D}/guard"; rm -f "${D}/guard/fallthrough.log"
  fsg_verify; echo "rc=$?") 2>&1)"
[[ "${OUT}" == *"could not measure"* && "${OUT}" == *"Fix:"* && "${OUT}" == *"rc=1" ]] \
  && ok "G6. a deleted guard log: fsg_verify returns 1, 'could not measure', with a Fix:" \
  || bad "G6. lost log is not clean" "out=${OUT}"

# --- G7. fsg_verify with no fsg_arm at all is "could not measure" too.
OUT="$( (unset FSG_DIR; . "${LIB}"; fsg_verify; echo "rc=$?") 2>&1)"
[[ "${OUT}" == *"could not measure"* && "${OUT}" == *"rc=1" ]] \
  && ok "G7. fsg_verify without fsg_arm returns 1, never a clean pass" \
  || bad "G7. unarmed verify is not clean" "out=${OUT}"

# --- G8. fsg_require_stubs fails the suite at setup on a bad stub.
D="$(casedir g8)"; mkdir -p "${D}/s"
printf '#!/bin/sh\n' > "${D}/s/gh"; printf '#!/bin/sh\n' > "${D}/s/glab"; chmod +x "${D}/s/glab"
OUT="$( (. "${LIB}"; fsg_require_stubs "${D}/s" glab gh; echo "after") 2>&1)"; RC=$?
[ "${RC}" = 1 ] && [[ "${OUT}" == *"${D}/s/gh is not executable"* && "${OUT}" == *"Fix:"* && "${OUT}" != *after* ]] \
  && ok "G8a. fsg_require_stubs on a non-executable stub: exit 1 with a Fix:, nothing after runs" \
  || bad "G8a. non-executable stub refused" "rc=${RC} out=${OUT}"
OUT="$( (. "${LIB}"; fsg_require_stubs "${D}/s" glab gh-athena; echo "after") 2>&1)"; RC=$?
[ "${RC}" = 1 ] && [[ "${OUT}" == *"${D}/s/gh-athena does not exist"* && "${OUT}" == *"Fix:"* ]] \
  && ok "G8b. fsg_require_stubs on a missing stub: exit 1 with a Fix:" \
  || bad "G8b. missing stub refused" "rc=${RC} out=${OUT}"
OUT="$( (. "${LIB}"; fsg_require_stubs "${D}/s" glab; echo "after") 2>&1)"; RC=$?
[ "${RC}" = 0 ] && [ "${OUT}" = after ] \
  && ok "G8c. fsg_require_stubs on an executable stub: silent, returns" \
  || bad "G8c. healthy stub accepted" "rc=${RC} out=${OUT}"

# --- G9. Named tools: fsg_arm guards exactly the names it is given.
D="$(casedir g9)"
OUT="$( (PATH="${BASE_PATH}"; . "${LIB}"; fsg_arm "${D}/guard" gh-athena
  [ -x "${D}/guard/gh-athena" ] && [ ! -e "${D}/guard/gh" ] && printf 'named') 2>&1)"
[ "${OUT}" = named ] && ok "G9. fsg_arm <dir> gh-athena guards that name only" \
  || bad "G9. named guard" "out=${OUT}"

# --- G10. A guard directory that cannot be made fails loudly.
D="$(casedir g10)"; : > "${D}/file"
OUT="$( (. "${LIB}"; fsg_arm "${D}/file/guard"; echo "after") 2>&1)"; RC=$?
[ "${RC}" = 1 ] && [[ "${OUT}" == *"could not create"* && "${OUT}" == *"Fix:"* && "${OUT}" != *after* ]] \
  && ok "G10. an unwritable guard directory: exit 1 with a Fix:" \
  || bad "G10. unwritable guard dir refused" "rc=${RC} out=${OUT}"

printf '\nforge-stub-guard self-test: %d passed, %d failed\n' "${PASS}" "${FAIL}"
if [ "${FAIL}" -ne 0 ]; then
  echo "Fix: ai/lib/forge-stub-guard.sh must put a guard behind every gh/glab stub that logs and exits 97 without running the real CLI, fsg_verify must return 1 on any logged call or a lost log, and fsg_require_stubs must exit 1 on a missing or non-executable stub." >&2
  exit 1
fi
exit 0
