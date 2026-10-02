#!/usr/bin/env bash
# Deterministic suite for ai/lib/proc-stat.sh (DND-1625): the ONE rule for
# reading /proc/<pid>/stat in shell -- read the whole file, take the fields
# after the LAST ") ". Discovered by ai/bin/harness-gate (a committed
# self-test.sh under a test/ directory).
#
# Every input is a FIXTURE stat file. No process with an odd name is started
# and nothing generates load (DND-1222). The fixture's comm holds a newline and
# ") ", the two things a line-oriented or first-") " parse misreads.
#
# Run: bash ai/lib/test/proc-stat/self-test.sh
set -uo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
REPO="$(cd -- "${HERE}/../../../.." && pwd -P)"
LIB="${REPO}/ai/lib/proc-stat.sh"

PASS=0; FAIL=0
ok()  { printf '  ok    %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  FAIL  %s\n        %s\n' "$1" "$2"; FAIL=$((FAIL+1)); }

T="$(mktemp -d "${TMPDIR:-/tmp}/dnd-1625-proc-stat.XXXXXX")" || { echo "cannot mktemp. Fix: make \$TMPDIR writable." >&2; exit 2; }
trap 'rm -rf -- "${T}"' EXIT

echo "proc-stat self-test"

# The fixture. Its comm is "x) Z 7 9<newline>) T" (12 bytes, under the
# kernel's 15-byte TASK_COMM_LEN). After the LAST ") " the fields are:
#   1 state S, 2 ppid 1, 3 pgrp 4242, 4 session 4242, ..., 20 starttime 555.
# A first-") " parse reads state Z; a line-by-line parse reads "Z 7 9" from
# line one and the real fields from line two.
FIX="${T}/odd.stat"
printf '4242 (x) Z 7 9\n) T) S 1 4242 4242 0 -1 4194560 0 0 0 0 0 0 0 0 20 0 1 0 555 1000 10\n' >"${FIX}"
PLAIN="${T}/plain.stat"
printf '77 (sleep) R 1 77 77 0 -1 4194560 0 0 0 0 0 0 0 0 20 0 1 0 999 1000 10\n' >"${PLAIN}"
NOCLOSE="${T}/noclose.stat"
printf '88 (broken S 1 88 88\n' >"${NOCLOSE}"
EMPTY="${T}/empty.stat"
: >"${EMPTY}"
MISSING="${T}/missing.stat"

if [ -r "${LIB}" ]; then
# shellcheck source=ai/lib/proc-stat.sh
. "${LIB}"

# --- proc_stat_rest -----------------------------------------------------------
proc_stat_rest "${FIX}"; rc=$?
[ "${rc}" -eq 0 ] && [ "${PROC_STAT_REST%% *}" = "S" ] \
  && ok "PS-1 an odd comm (newline and \") \") parses after the LAST \") \"" \
  || bad "PS-1 an odd comm parses after the LAST \") \"" "rc=${rc} rest='${PROC_STAT_REST:-}'"
case "${PROC_STAT_REST}" in *$'\n'*) bad "PS-1b the rest holds no newline" "rest='${PROC_STAT_REST}'" ;; *) ok "PS-1b the rest holds no newline" ;; esac

proc_stat_rest "${MISSING}"; rc=$?
[ "${rc}" -eq 1 ] && [ -z "${PROC_STAT_REST}" ] && ok "PS-2 a missing stat is 1 (could not read), with an empty rest" \
  || bad "PS-2 a missing stat is 1" "rc=${rc} rest='${PROC_STAT_REST}'"
proc_stat_rest "${EMPTY}"; rc=$?
[ "${rc}" -eq 1 ] && ok "PS-3 an empty stat is 1 (could not read), never fields" || bad "PS-3 an empty stat is 1" "rc=${rc}"
proc_stat_rest "${NOCLOSE}"; rc=$?
[ "${rc}" -eq 2 ] && [ -z "${PROC_STAT_REST}" ] && ok "PS-4 a stat with no \") \" is 2 (malformed), never guessed" \
  || bad "PS-4 a stat with no \") \" is 2" "rc=${rc} rest='${PROC_STAT_REST}'"

# --- proc_stat_field: the shapes the sites read --------------------------------
# integration-gate adopts a pre-started critic only when field 3 (pgrp) of
# /proc/<pgid>/stat is the pgid itself.
out="$(proc_stat_field "${FIX}" 3)"; rc=$?
[ "${rc}" -eq 0 ] && [ "${out}" = "4242" ] \
  && ok "PS-5 integration-gate's read: field 3 (pgrp) of the odd stat is 4242" \
  || bad "PS-5 integration-gate's read: field 3 (pgrp)" "rc=${rc} out='${out}'"
# inbox-client-capture's proc_start_epoch reads field 20 (starttime).
out="$(proc_stat_field "${FIX}" 20)"; rc=$?
[ "${rc}" -eq 0 ] && [ "${out}" = "555" ] \
  && ok "PS-6 inbox-client-capture's read: field 20 (starttime) of the odd stat is 555" \
  || bad "PS-6 inbox-client-capture's read: field 20 (starttime)" "rc=${rc} out='${out}'"
out="$(proc_stat_field "${FIX}" 1)"; rc=$?
[ "${rc}" -eq 0 ] && [ "${out}" = "S" ] && ok "PS-7 field 1 (state) of the odd stat is S, not the comm's Z" \
  || bad "PS-7 field 1 (state)" "rc=${rc} out='${out}'"
out="$(proc_stat_field "${PLAIN}" 20)"; rc=$?
[ "${rc}" -eq 0 ] && [ "${out}" = "999" ] && ok "PS-8 a plain stat reads the same way" || bad "PS-8 a plain stat" "rc=${rc} out='${out}'"
out="$(proc_stat_field "${FIX}" 99)"; rc=$?
[ "${rc}" -eq 2 ] && [ -z "${out}" ] && ok "PS-9 a field past the end is 2, never an empty value read as 0" \
  || bad "PS-9 a field past the end is 2" "rc=${rc} out='${out}'"
for n in 0 -1 x ''; do
  out="$(proc_stat_field "${FIX}" "${n}" 2>&1)"; rc=$?
  [ "${rc}" -eq 2 ] && ok "PS-10 field index '${n}' is refused (2)" || bad "PS-10 field index '${n}' is refused" "rc=${rc} out='${out}'"
done
out="$(proc_stat_field "${MISSING}" 3)"; rc=$?
[ "${rc}" -eq 1 ] && [ -z "${out}" ] && ok "PS-11 a missing stat is 1 for a field read too" || bad "PS-11 missing stat field read" "rc=${rc}"
out="$(proc_stat_field "${NOCLOSE}" 3)"; rc=$?
[ "${rc}" -eq 2 ] && ok "PS-12 a malformed stat is 2 for a field read" || bad "PS-12 malformed stat field read" "rc=${rc}"
TRUNC="${T}/trunc.stat"
printf '99 (cut) ' >"${TRUNC}"
proc_stat_rest "${TRUNC}"; rc=$?
[ "${rc}" -eq 2 ] && [ -z "${PROC_STAT_REST}" ] && ok "PS-13 a stat with nothing after the last \") \" is 2, never an empty read"   || bad "PS-13 a stat with nothing after the last \") \"" "rc=${rc} rest='${PROC_STAT_REST}'"

else
  bad "PS-0 the shared library exists" "${LIB} is missing, so PS-1..PS-12 did not run"
fi

# --- the sites use the shared rule (DND-1625) ---------------------------------
# Each named site read /proc/<pid>/stat line by line (sed) or took the FIRST
# ") ". The behaviour is proven above; this asserts each site now reads it
# through this library, so the fixture's answer is the site's answer.
IG="${REPO}/ai/skills/athena:merge-boarding/scripts/integration-gate"
CAP="${REPO}/scripts/inbox-client-capture"
TS="${REPO}/ai/bin/test-slot"
site() { # <label> <file> <must-match ERE>
  if grep -qE "$3" "$2"; then ok "$1"; else bad "$1" "no match for /$3/ in $2"; fi
}
nosite() { # <label> <file> <must-not-match ERE>
  local hit; hit="$(grep -nE "$3" "$2")"
  if [ -z "${hit}" ]; then ok "$1"; else bad "$1" "${hit}"; fi
}
site   "SITE-1 integration-gate reads the critic's pgrp with proc_stat_field" "${IG}" 'proc_stat_field "/proc/\$\{p_pgid\}/stat" 3'
nosite "SITE-1b integration-gate has no line-oriented sed over a stat file" "${IG}" "sed [^|]*/proc/[^ ]*/stat"
site   "SITE-2 inbox-client-capture reads starttime with proc_stat_field" "${CAP}" 'proc_stat_field "/proc/\$\{p\}/stat" 20'
nosite "SITE-2b inbox-client-capture has no line-oriented sed over a stat file" "${CAP}" "sed [^|]*/proc/[^ ]*/stat"
# test-slot runs with no ai/lib beside it (its self-test G10), so it spells
# the same rule inline. SITE-3 runs read_ppid ITSELF, lifted out of test-slot,
# on the fixture: the parse that carries the fix is exercised, not matched.
rp="$(sed -n '/^read_ppid() {$/,/^}$/p' "${TS}")"
if [ -z "${rp}" ]; then
  bad "SITE-3 test-slot defines read_ppid" "no 'read_ppid() {' ... '}' block in ${TS}"
else
  CUR_PPID="unset"
  eval "${rp}"
  read_ppid "${FIX}"
  [ "${CUR_PPID}" = "1" ] && ok "SITE-3 test-slot's read_ppid reads ppid 1 from the odd fixture (not the comm's 7)"     || bad "SITE-3 test-slot's read_ppid on the odd fixture" "CUR_PPID='${CUR_PPID}' (want 1)"
  read_ppid "${NOCLOSE}"
  [ -z "${CUR_PPID}" ] && ok "SITE-3c read_ppid on a stat with no \") \" is empty (unreadable), never a guess"     || bad "SITE-3c read_ppid on a malformed stat" "CUR_PPID='${CUR_PPID}'"
  read_ppid
  [ "${CUR_PPID}" = "${PPID}" ] && ok "SITE-3d read_ppid with no argument reads this shell's own parent"     || bad "SITE-3d read_ppid default" "CUR_PPID='${CUR_PPID}' PPID='${PPID}'"
fi
nosite "SITE-3b test-slot has no single-line read of /proc/self/stat" "${TS}" "read -r [a-z_]+ [^<]*</proc/self/stat"

printf '\n%s passed, %s failed\n' "${PASS}" "${FAIL}"
[ "${FAIL}" -eq 0 ]
