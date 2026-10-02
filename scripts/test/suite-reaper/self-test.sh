#!/usr/bin/env bash
# self-test.sh -- scripts/test/lib/suite-reaper.bash (DND-818).
#
# Every case runs a throwaway fixture suite and then asks the kernel, not the
# fixture, what survived: survivors are found by a marker this test puts in the
# fixture's environment. Each survivor is killed BY PID here, so a failing case
# never leaks.
#
#   S1  premise: the old pid-list cleanup leaks a process started just before
#       a trapped signal (the fork-window race, made deterministic with
#       `kill -TERM $$` between the `&` and the `PIDS+=`).
#   S2  the same fixture with the reaper: nothing survives.
#   S3  a grandchild that ignores SIGTERM and was orphaned to PID 1 before the
#       suite exited is reaped.
#   S4  a forked subshell that never execs is reaped (why begin re-execs).
#   S5  a nested suite SIGKILLed with a leak inside: the OUTER reaper gets it.
#   S6  a concurrent sibling suite's processes are never touched.
#   S7  suite_reap_tagged without suite_reaper_begin fails loudly with a Fix:,
#       never reads as "nothing to reap".
#   S8  a normal exit reaps an unrecorded process and names it on stderr.
#   S9  wiring: every self-test that starts mock-athena-inbox-client.rb sources
#       the reaper, calls suite_reaper_begin, and calls suite_reap_tagged.
#   S10 the real suites, SIGTERMed mid-run at the two measured windows, leave
#       nothing behind (scripts/test/suite-reaper/repro-real-suites.sh).
#   S11 when a repro case cannot run, the repro says why truthfully: a suite
#       still running when the wait runs out is not called "exited", and one
#       that did exit early is named with its status. Both quote the suite's
#       own FAIL lines, and nothing the suite started is left alive.
#   S12 a tagged process caught mid-exec is found by every scan (DND-1016).
#   S13 an orphaned process that is mid-exec when the suite reaps does not
#       survive the reap (the R1 orphan, end to end).
#   S14 a scan that cannot run fails the reap loudly with a Fix:, never
#       "none left".
#   S15 scripts/lib/proc-env-scan.awk on a fixture /proc: settled bounds find
#       the tag; 0 0 that never settles and a short read are UNKNOWN (exit 4);
#       equal bounds are an empty environment once the exec has finished
#       (start_code set) and UNKNOWN while it has not (DND-1626); the
#       needle's own entry read torn ('=' a NUL, bash mid-import) is UNKNOWN,
#       another variable torn is not (DND-1202).
#   S16 a non-dumpable process (0 0 forever) is skipped at once, not waited out.
#   S17 R2's target client boots under the scratch HOME even when the `ruby`
#       first on PATH is an asdf-style shim that works only under the real
#       HOME, and a target client that never boots FAILs R2 instead of
#       passing it vacuously (DND-1203).
#   S18 a process ANYWHERE on the machine whose name holds a newline (any
#       user's; proc-state's own P-6 makes one) does not blind the scan or the
#       reap: on a fixture /proc, and end to end with a live one (DND-1616).
#
# Case isolation: each run_fixture case gets its own marker, and the next
# run_fixture kills whatever the previous case left, by pid, before it starts,
# so one case's leftover can never count against the next.
set -uo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
REPO="$(cd -- "${HERE}/../../.." && pwd -P)"
LIB="${REPO}/scripts/test/lib/suite-reaper.bash"
TMP="$(mktemp -d)"
PASS=0; FAIL=0
ok()  { printf '  ok    %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  FAIL  %s\n        %s\n' "$1" "$2"; FAIL=$((FAIL+1)); }

MARKS=()
# marked <VAR=value> -- own pids whose environ holds exactly it, read through
# the reaper's own scan (DND-1016): a plain `grep -z` over /proc/*/environ
# misses a process caught mid-exec, so a survivor could read as gone. marked
# runs inside $(...), where an exit is lost, so a scan that cannot run prints
# the token SCAN-FAILED in place of a pid: every caller then reads "something
# survived" and the case FAILs, never "no survivors".
. "${LIB}"
. "${REPO}/scripts/test/lib/proc-state.bash"
marked() {
  suite_env_pids exact "$1" && return 0
  echo "self-test: the process scan could not run, so survivors cannot be counted." >&2
  echo "  Fix: repair the scan's reason above (scripts/lib/proc-env-scan.awk)." >&2
  echo "SCAN-FAILED"
}
# kill_marked <VAR=value> -- kill them all by pid (this test's own safety net).
kill_marked() { local p; for p in $(marked "$1"); do [ "${p}" = "$$" ] || kill -9 "${p}" 2>/dev/null; done; }
survivors() { # survivors <mark> -- pid:cmdline of each live marked process
  local p
  for p in $(marked "$1"); do
    [ "${p}" = "$$" ] && continue
    [ "${p}" = "${BASHPID}" ] && continue
    printf '%s:%s ' "${p}" "$(tr '\0' ' ' <"/proc/${p}/cmdline" 2>/dev/null)"
  done
}
cleanup() {
  local m
  for m in ${MARKS[@]+"${MARKS[@]}"}; do kill_marked "${m}"; done
  rm -rf -- "${TMP}"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# run_fixture <name> <body> -- write a fixture suite and run it to completion
# under a fresh marker; sets MARK and FX_RC, and FX_ERR to its stderr file.
run_fixture() {
  local name="$1" body="$2"
  # Isolation: the previous case's leftovers (a failed case's survivors) are
  # killed by pid here, before this case starts.
  [ -n "${MARK:-}" ] && kill_marked "${MARK}"
  MARK="DND818_ST_MARK=${name}-$$"; MARKS+=("${MARK}")
  printf '#!/usr/bin/env bash\nset -uo pipefail\nLIB=%q\n%s\n' "${LIB}" "${body}" >"${TMP}/${name}.sh"
  FX_ERR="${TMP}/${name}.err"
  env "${MARK}" bash "${TMP}/${name}.sh" >"${TMP}/${name}.out" 2>"${FX_ERR}"
  FX_RC=$?
}

# gone <mark> -- block (bounded) until no marked process remains; a killed
# process can take a moment to leave the table.
gone() { local i; for i in $(seq 1 50); do [ -z "$(survivors "$1")" ] && return 0; sleep 0.1; done; return 1; }

printf 'suite-reaper self-test\n'

# ---------------------------------------------------------------------------
# S1 / S2: the fork-window race. `kill -TERM $$` runs between the `&` and the
# append, exactly where a harness-gate SIGTERM landed on 2026-09-26 20:46:58Z.
OLD_BODY='PIDS=()
cleanup() { local p; for p in ${PIDS[@]+"${PIDS[@]}"}; do kill -9 "$p" 2>/dev/null; done; }
trap cleanup EXIT; trap "exit 143" TERM
sleep 300 & kill -TERM $$; PIDS+=("$!")
sleep 1'
run_fixture s1 "${OLD_BODY}"
S1="$(survivors "${MARK}")"
if [ "${FX_RC}" -eq 143 ] && [ -n "${S1}" ]; then
  ok "S1 premise: a pid-list cleanup leaks a process started just before a trapped SIGTERM (${S1% })"
else
  bad "S1 premise: a pid-list cleanup leaks the fork-window process" "rc=${FX_RC} survivors=${S1:-none}"
fi
kill_marked "${MARK}"

run_fixture s2 '. "${LIB}"; suite_reaper_begin "$@"
PIDS=()
cleanup() { local p; for p in ${PIDS[@]+"${PIDS[@]}"}; do kill -9 "$p" 2>/dev/null; done; suite_reap_tagged; }
trap cleanup EXIT; trap "exit 143" TERM
sleep 300 & kill -TERM $$; PIDS+=("$!")
sleep 1'
if [ "${FX_RC}" -eq 143 ] && gone "${MARK}"; then
  ok "S2 with the reaper, the same fork-window process does not survive"
else
  bad "S2 with the reaper, the fork-window process does not survive" "rc=${FX_RC} survivors=$(survivors "${MARK}") err=$(cat "${FX_ERR}")"
fi

# ---------------------------------------------------------------------------
# S3: the 45c shape. A launcher starts a client that ignores SIGTERM and exits
# first, so the client is reparented before the suite's cleanup runs, and the
# suite never learned its pid.
printf '#!/usr/bin/env bash\n( trap "" TERM; exec sleep 300 ) &\nprintf "%%s\\n" "$!" >"$1"\n' >"${TMP}/s3-launcher.sh"
run_fixture s3 '. "${LIB}"; suite_reaper_begin "$@"
trap suite_reap_tagged EXIT
bash '"${TMP}"'/s3-launcher.sh '"${TMP}"'/s3.pid
c="$(cat '"${TMP}"'/s3.pid)"
kill -TERM "$c"
printf "%s %s\n" "$c" "$(cut -d" " -f4 /proc/$c/stat)" >'"${TMP}"'/s3.child'
C3="$(cat "${TMP}/s3.child" 2>/dev/null)"
if [ -n "${C3}" ] && gone "${MARK}"; then
  ok "S3 an orphaned grandchild that ignores SIGTERM (pid, ppid: ${C3}) is reaped"
else
  bad "S3 an orphaned grandchild that ignores SIGTERM is reaped" "child=${C3:-none} survivors=$(survivors "${MARK}")"
fi

# ---------------------------------------------------------------------------
# S4: a forked subshell that never execs carries the environ its shell was
# EXEC'd with, so the tag must be in the suite's exec environment.
run_fixture s4 '. "${LIB}"; suite_reaper_begin "$@"
trap suite_reap_tagged EXIT
( while :; do sleep 1; done ) &
sleep 0.2'
if gone "${MARK}"; then
  ok "S4 a forked, never-exec'd background subshell is reaped"
else
  bad "S4 a forked, never-exec'd background subshell is reaped" "survivors=$(survivors "${MARK}")"
fi

# ---------------------------------------------------------------------------
# S5: nested. The inner suite leaks, then is SIGKILLed (no trap runs); the
# outer suite's reaper still owns the leak through its own tag in the list.
printf '#!/usr/bin/env bash\n. %q; suite_reaper_begin "$@"\ntrap suite_reap_tagged EXIT\nsleep 300 &\nprintf "%%s\\n" "$!" >"$1"\nkill -9 $$\n' \
  "${LIB}" >"${TMP}/s5-inner.sh"
run_fixture s5 '. "${LIB}"; suite_reaper_begin "$@"
trap suite_reap_tagged EXIT
bash '"${TMP}"'/s5-inner.sh '"${TMP}"'/s5.leak
exit 0'
L5="$(cat "${TMP}/s5.leak" 2>/dev/null)"
if [ -n "${L5}" ] && gone "${MARK}"; then
  ok "S5 a SIGKILLed nested suite's leak (pid ${L5}) is reaped by the outer suite"
else
  bad "S5 a SIGKILLed nested suite's leak is reaped by the outer suite" "leak=${L5:-none} survivors=$(survivors "${MARK}")"
fi

# ---------------------------------------------------------------------------
# S6: a sibling suite (another worktree's gate) is never touched. The sibling
# is a separate tagged suite whose child must still be alive after this run.
SIB_MARK="DND818_ST_MARK=s6sib-$$"; MARKS+=("${SIB_MARK}")
printf '#!/usr/bin/env bash\n. %q; suite_reaper_begin "$@"\ntrap suite_reap_tagged EXIT\ntrap "exit 143" TERM\nsleep 300 &\nprintf "%%s\\n" "$!" >"$1"\nwait\n' \
  "${LIB}" >"${TMP}/s6-sib.sh"
env "${SIB_MARK}" bash "${TMP}/s6-sib.sh" "${TMP}/s6.sib" >/dev/null 2>&1 &
SIB=$!
for i in $(seq 1 50); do [ -s "${TMP}/s6.sib" ] && break; sleep 0.1; done
SC="$(cat "${TMP}/s6.sib" 2>/dev/null)"
run_fixture s6 '. "${LIB}"; suite_reaper_begin "$@"
trap suite_reap_tagged EXIT
sleep 300 &
exit 0'
if [ -n "${SC}" ] && kill -0 "${SC}" 2>/dev/null && gone "${MARK}"; then
  ok "S6 a concurrent sibling suite's child (pid ${SC}) survives this suite's reap"
else
  bad "S6 a concurrent sibling suite's child survives" "sib_child=${SC:-none} alive=$(kill -0 "${SC:-0}" 2>/dev/null && echo y || echo n) own=$(survivors "${MARK}")"
fi
kill -TERM "${SIB}" 2>/dev/null; timeout 10 tail --pid="${SIB}" -f /dev/null 2>/dev/null
if gone "${SIB_MARK}"; then ok "S6 ...and the sibling reaps its own when it ends"; else bad "S6 the sibling reaps its own" "$(survivors "${SIB_MARK}")"; fi

# ---------------------------------------------------------------------------
# S7: called without begin, the reaper has no tag. That is a failed lookup,
# not an empty one.
run_fixture s7 '. "${LIB}"
unset ATHENA_SUITE_REAPER_TAG
suite_reap_tagged; echo "rc=$?"'
if grep -q '^rc=1$' "${TMP}/s7.out" && grep -q 'Fix:' "${FX_ERR}" && grep -q 'without suite_reaper_begin' "${FX_ERR}"; then
  ok "S7 without suite_reaper_begin: status 1 with a Fix:, never a silent 'nothing to reap'"
else
  bad "S7 without suite_reaper_begin: status 1 with a Fix:" "out=$(cat "${TMP}/s7.out") err=$(cat "${FX_ERR}")"
fi

# ---------------------------------------------------------------------------
# S8: a normal, passing exit with an unrecorded process: reaped, and named.
run_fixture s8 '. "${LIB}"; suite_reaper_begin "$@"
trap suite_reap_tagged EXIT
sleep 301 &
exit 0'
if [ "${FX_RC}" -eq 0 ] && gone "${MARK}" && grep -q 'suite-reaper: killing pid [0-9]* .*sleep 301' "${FX_ERR}"; then
  ok "S8 a normal exit reaps an unrecorded process and names it on stderr"
else
  bad "S8 a normal exit reaps an unrecorded process and names it" "rc=${FX_RC} survivors=$(survivors "${MARK}") err=$(cat "${FX_ERR}")"
fi

# ---------------------------------------------------------------------------
# S9: wiring. A suite that starts the mock and does not use the reaper is the
# regression this whole file exists to stop.
S9=""; n=0
while IFS= read -r f; do
  n=$((n+1))
  grep -q 'scripts/test/lib/suite-reaper.bash\|/lib/suite-reaper.bash' "${f}" \
    && grep -q '^suite_reaper_begin "\$@"' "${f}" && grep -q 'suite_reap_tagged' "${f}" || S9="${S9} ${f#"${REPO}"/}"
done < <(grep -rlF --include=self-test.sh 'mock-athena-inbox-client.rb' "${REPO}/scripts" "${REPO}/ai" 2>/dev/null \
           | grep -vxF "${HERE}/self-test.sh")
if [ "${n}" -ge 2 ] && [ -z "${S9}" ]; then
  ok "S9 all ${n} self-tests that start mock-athena-inbox-client.rb source the reaper and call begin + reap"
else
  bad "S9 every mock-bearing self-test uses the reaper" "found ${n}; missing wiring in:${S9:- (none, but fewer than 2 suites found -- the grep lost them)}"
fi

# ---------------------------------------------------------------------------
# S11: the repro must say WHY a case could not run, truthfully. A suite that is
# still running when the wait runs out, and one that exited before the trigger,
# are different findings: the first is a slow (loaded) suite, not a leak; the
# second is a suite that died early. On 2026-09-28 a loaded desktop gate read
# the first as the second ("the trigger never fired (suite exited ...)") and the
# still-running suite's own children as processes that "outlived" it. Run
# against a fake repo so a slow suite costs seconds, not minutes.
s11_repo() { # s11_repo <name> <fake-suite-body> -- a fake checkout holding the repro
  local r="${TMP}/$1"
  mkdir -p "${r}/scripts/test/suite-reaper" "${r}/scripts/test/athena-inbox-client"
  mkdir -p "${r}/scripts/test/lib" "${r}/scripts/lib"
  cp "${HERE}/repro-real-suites.sh" "${r}/scripts/test/suite-reaper/"
  cp "${LIB}" "${r}/scripts/test/lib/"
  cp "${REPO}/scripts/lib/proc-env-scan.awk" "${r}/scripts/lib/"
  printf '#!/usr/bin/env bash\n%s\n' "$2" >"${r}/scripts/test/athena-inbox-client/self-test.sh"
  printf '%s\n' "${r}"
}
S11_FAKE_OUT='echo "  ok    fake case 1"; echo "  FAIL  fake case 43"; echo "        fake detail"'
r="$(s11_repo s11slow "${S11_FAKE_OUT}; sleep 307 & wait")"
MARK="DND818_ST_MARK=s11slow-$$"; MARKS+=("${MARK}")
O="$(env "${MARK}" REPRO_CASES=r2 REPRO_WAIT_S=3 REPRO_STALL_S=3 bash "${r}/scripts/test/suite-reaper/repro-real-suites.sh" 2>&1)"; ORC=$?
if [ "${ORC}" -eq 1 ] && grep -q '^VERDICT: FAIL' <<<"${O}" && grep -q 'still RUNNING' <<<"${O}" \
   && ! grep -q 'suite exited' <<<"${O}" && grep -qF 'FAIL  fake case 43' <<<"${O}"; then
  ok "S11 a suite still running when the wait runs out is reported as still RUNNING (with its own FAILs), never as exited"
else
  bad "S11 a suite still running when the wait runs out is reported as still RUNNING, never as exited" "rc=${ORC} $(printf '%s' "${O}" | tr '\n' '|')"
fi
if gone "${MARK}"; then
  ok "S11 ...and the still-running suite and its children are killed"
else
  bad "S11 the still-running suite and its children are killed" "$(survivors "${MARK}")"; kill_marked "${MARK}"
fi
r="$(s11_repo s11early "${S11_FAKE_OUT}; exit 3")"
O="$(REPRO_CASES=r2 REPRO_WAIT_S=30 REPRO_STALL_S=30 bash "${r}/scripts/test/suite-reaper/repro-real-suites.sh" 2>&1)"; ORC=$?
if [ "${ORC}" -eq 1 ] && grep -q 'EXITED (status 3) before the trigger fired' <<<"${O}" && grep -qF 'FAIL  fake case 43' <<<"${O}"; then
  ok "S11 a suite that exits before the trigger is reported as EXITED with its status and its own FAILs"
else
  bad "S11 a suite that exits before the trigger is reported as EXITED with its status and its own FAILs" "rc=${ORC} $(printf '%s' "${O}" | tr '\n' '|')"
fi

# ---------------------------------------------------------------------------
# S12 / S13 (DND-1016): a process that is IN execve when the reaper looks. From
# the kernel swapping in the new mm until it lays out the new stack,
# /proc/<pid>/environ reads EMPTY (or EACCES), and a read that straddles an
# exec is cut short at a page boundary. A scan that reads either as "not
# tagged" misses a process that IS tagged. The measured orphan was
# `asdf exec ruby .../mock-athena-inbox-client.rb`: the mock starts through a
# chain of four execs (a shim, the asdf shim, asdf, ruby), and R1 SIGTERMs the
# suite exactly as that chain begins, so the suite's reap ran while the mock
# was mid-exec, read nothing, and returned "none left". The spinner below
# re-execs itself forever, so it is always at or near that window: measured
# on the old reaper, 58 of 300 scans (19%) did not list it. The window it
# found last is narrow: equal env_start/env_end, which the kernel shows for an
# instant before it walks the new environment. It missed 1 scan in 100 until
# the scan stopped reading equal bounds as "empty, settled", so S12 runs 200.
printf '#!%s\nexec "${BASH}" "$0"\n' "${BASH}" >"${TMP}/spin.sh"; chmod +x "${TMP}/spin.sh"
run_fixture s12 '. "${LIB}"; suite_reaper_begin "$@"
trap suite_reap_tagged EXIT
'"${TMP}"'/spin.sh & sp=$!
miss=0
for i in $(seq 1 200); do
  case " $(suite_tagged_pids | tr "\n" " ") " in *" ${sp} "*) ;; *) miss=$((miss+1)) ;; esac
done
echo "misses=${miss}"'
S12="$(cat "${TMP}/s12.out")"
if [ "${S12}" = "misses=0" ] && gone "${MARK}"; then
  ok "S12 a tagged process caught mid-exec is still found: 200 of 200 scans list the exec-spinner"
else
  bad "S12 a tagged process caught mid-exec is still found by every scan" "${S12:-no output} (of 200 scans) survivors=$(survivors "${MARK}") err=$(head -c 400 "${FX_ERR}")"
fi

# S13: end to end. The spinner is ORPHANED (its launcher exits first, as R1's
# fake suite is killed first), so only the tag can find it; then the suite
# reaps. 30 rounds, each asking the kernel afterwards whether it survived
# (still running; a dead orphan stays a zombie until PID 1 reaps it).
printf '#!%s\n%q & printf "%%s\\n" "$!" >"$1"\n' "${BASH}" "${TMP}/spin.sh" >"${TMP}/s13-launcher.sh"
run_fixture s13 '. "${LIB}"; . "${LIB%/*}/proc-state.bash"; suite_reaper_begin "$@"
trap suite_reap_tagged EXIT
left=0; blind=0
for i in $(seq 1 30); do
  bash '"${TMP}"'/s13-launcher.sh '"${TMP}"'/s13.pid
  c="$(cat '"${TMP}"'/s13.pid)"
  suite_reap_tagged 2>/dev/null
  # proc_wait_gone, never kill -0 (DND-1550): the reap leaves the orphan a
  # ZOMBIE until PID 1 reaps it, and kill -0 succeeds on a zombie. And never
  # an instant proc_running (DND-1616): a SIGKILLed process that has already
  # dropped its memory (do_exit) reads "not ours" to the next reap pass but
  # is not a zombie yet, so "gone" is an event to wait on. The bound only caps
  # a hang: an orphan the reap missed is still running at it, and counts.
  # rc 2/3 (an unread or malformed pid) is never "reaped".
  proc_wait_gone "$c" 50; prc=$?
  case "${prc}" in 1) left=$((left+1)); kill -9 "$c" ;; 0) ;; *) blind=$((blind+1)) ;; esac
done
echo "survived=${left} unread=${blind}"'
S13="$(cat "${TMP}/s13.out")"
if [ "${S13}" = "survived=0 unread=0" ] && gone "${MARK}"; then
  ok "S13 an orphaned exec-spinner never survives suite_reap_tagged (30 of 30 rounds)"
else
  bad "S13 an orphaned exec-spinner never survives suite_reap_tagged" "${S13:-no output} (of 30 rounds) survivors=$(survivors "${MARK}")"
fi

# S14: a scan that cannot run found nothing because it did not look. The reap
# must fail loudly with a Fix:, never return 0 as "none left" while a tagged
# process is alive. The fixture restores the scanner and reaps for real after.
run_fixture s14 '. "${LIB}"; suite_reaper_begin "$@"
sleep 309 &
real="${_SUITE_REAPER_SCAN}"; _SUITE_REAPER_SCAN="/nonexistent/proc-env-scan.awk"
suite_reap_tagged; echo "rc=$?"
_SUITE_REAPER_SCAN="${real}"; suite_reap_tagged 2>/dev/null'
S14="$(cat "${TMP}/s14.out")"
if [ "${S14}" = "rc=1" ] && grep -q 'scan could not look' "${FX_ERR}" && grep -q 'Fix:' "${FX_ERR}" && gone "${MARK}"; then
  ok "S14 a scan that cannot run fails the reap (status 1, with a Fix:), never 'none left'"
else
  bad "S14 a scan that cannot run fails the reap loudly" "${S14:-no output} survivors=$(survivors "${MARK}") err=$(head -c 400 "${FX_ERR}")"
fi
# ...and a PARTIAL scan (status 4: it confirmed some matches, but one pid never
# settled) still kills what it confirmed, then fails. Dropping the matches
# would leave the very orphan DND-1016 is about. The scan is stubbed to report
# the real leak plus an unknown, as the awk does.
run_fixture s14b '. "${LIB}"; suite_reaper_begin "$@"
sleep 310 & leak=$!
suite_tagged_pids() { kill -0 "${leak}" 2>/dev/null && echo "${leak}"; echo "proc-env-scan: pid 1 ... UNKNOWN" >&2; return 4; }
suite_reap_tagged; rc=$?
kill -0 "${leak}" 2>/dev/null && alive=yes || alive=no
echo "rc=${rc} alive=${alive}"'
S14B="$(cat "${TMP}/s14b.out")"
if [ "${S14B}" = "rc=1 alive=no" ] && grep -q 'could not look' "${FX_ERR}" && gone "${MARK}"; then
  ok "S14 a partial scan (status 4) kills the matches it confirmed, then fails the reap"
else
  bad "S14 a partial scan kills the matches it confirmed, then fails" "${S14B:-no output} survivors=$(survivors "${MARK}") err=$(head -c 400 "${FX_ERR}")"
fi

# S15: the scan's verdicts on a fixture /proc (root=), one state each, so the
# rule is pinned without racing a real exec. fake_proc <pid> <env_start>
# <env_end> <environ-bytes> writes a stat line in the kernel's shape (fields
# 50-51 are the env bounds, field 26 is start_code), a status with our uid,
# and the environ. start_code defaults to a text address (the exec has
# finished); 0 is a new mm load_elf_binary has not finished (DND-1626).
SCAN="${REPO}/scripts/lib/proc-env-scan.awk"
fake_proc() { # fake_proc <pid> <env_start> <env_end> <environ> [<comm> [<uid> [<start_code>]]]
  local d="${TMP}/fakeproc/$1" i f="" comm="${5:-fake}" u="${6:-${UID}}" sc="${7:-4194304}"
  mkdir -p "${d}"
  for i in $(seq 4 49); do
    case "${i}" in 22) f="${f} 100" ;; 26) f="${f} ${sc}" ;; *) f="${f} 0" ;; esac
  done
  printf '%s (%s) S%s %s %s 0\n' "$1" "${comm}" "${f}" "$2" "$3" >"${d}/stat"
  printf 'Name:\tfake\nUid:\t%s\t%s\t%s\t%s\n' "${u}" "${u}" "${u}" "${u}" >"${d}/status"
  printf '%b' "$4" >"${d}/environ"
  printf 'fake\0' >"${d}/cmdline"
}
scan_fake() { # scan_fake <pid> -- runs the scan on one fixture pid; sets SO, SE, SRC
  SO="$(gawk -b -f "${SCAN}" -v mode=tag -v needle=t1 -v uid="${UID}" -v since=0 -v settle_s=0.2 \
        -v root="${TMP}/fakeproc" "${TMP}/fakeproc/$1" 2>"${TMP}/scan.err")"; SRC=$?
  SE="$(cat "${TMP}/scan.err")"
}
ENV1='ATHENA_REAP_TAGS=t0,t1\0HOME=/x\0'   # 31 bytes
fake_proc 4201 1000 1031 "${ENV1}"
scan_fake 4201
if [ "${SRC}" -eq 0 ] && [ "${SO}" = 4201 ] && [ -z "${SE}" ]; then
  ok "S15 settled bounds spanning every byte read: the tag is found"
else
  bad "S15 settled bounds spanning every byte read: the tag is found" "rc=${SRC} out=${SO} err=${SE}"
fi
fake_proc 4202 0 0 "${ENV1}"
scan_fake 4202
if [ "${SRC}" -eq 4 ] && [ -z "${SO}" ] && grep -q 'pid 4202 .*UNKNOWN' <<<"${SE}" && grep -q 'Fix:' <<<"${SE}"; then
  ok "S15 bounds that never leave 0 0 (mid-exec): named UNKNOWN with a Fix:, exit 4, never a quiet 'no'"
else
  bad "S15 bounds that never leave 0 0: named UNKNOWN, exit 4" "rc=${SRC} out=${SO} err=${SE}"
fi
fake_proc 4203 1000 1100 "${ENV1}"
scan_fake 4203
if [ "${SRC}" -eq 4 ] && [ -z "${SO}" ] && grep -q 'pid 4203 .*UNKNOWN' <<<"${SE}"; then
  ok "S15 a read shorter than the bounds (cut at a page mid-exec): UNKNOWN, exit 4, never 'no'"
else
  bad "S15 a read shorter than the bounds: UNKNOWN, exit 4" "rc=${SRC} out=${SO} err=${SE}"
fi
fake_proc 4204 1000 1000 ''
scan_fake 4204
if [ "${SRC}" -eq 0 ] && [ -z "${SO}" ] && [ -z "${SE}" ]; then
  ok "S15 equal bounds with the exec finished (start_code set): an empty environment, 'no' with no warning"
else
  bad "S15 equal bounds with the exec finished: an empty environment" "rc=${SRC} out=${SO} err=${SE}"
fi
# DND-1626: equal bounds with start_code still 0 are an exec inside its
# environment walk (create_elf_tables sets env_end = env_start, walks, then
# sets env_end; load_elf_binary sets start_code only after). However long that
# state lasts (a preempted walk), it is "cannot tell yet", never "no".
fake_proc 4210 1000 1000 '' fake "${UID}" 0
scan_fake 4210
if [ "${SRC}" -eq 4 ] && [ -z "${SO}" ] && grep -q 'pid 4210 .*UNKNOWN' <<<"${SE}"; then
  ok "S15 equal bounds mid-exec (start_code 0) that never settle: UNKNOWN, exit 4, never 'no'"
else
  bad "S15 equal bounds mid-exec (start_code 0): UNKNOWN, exit 4" "rc=${SRC} out=${SO} err=${SE}"
fi
# DND-1202: settled bounds, but the program is rewriting its environment in
# place (bash writes a NUL over each entry's '=' while it imports it), so our
# entry reads split in two. That is "cannot tell yet", never "no".
fake_proc 4205 1000 1031 'HOME=/x\0ATHENA_REAP_TAGS\0t0,t1\0'   # 31 bytes
scan_fake 4205
if [ "${SRC}" -eq 4 ] && [ -z "${SO}" ] && grep -q 'pid 4205 .*UNKNOWN' <<<"${SE}"; then
  ok "S15 our entry read mid-rewrite ('=' read as NUL): UNKNOWN, exit 4, never 'no'"
else
  bad "S15 our entry read mid-rewrite ('=' read as NUL): UNKNOWN, exit 4" "rc=${SRC} out=${SO} err=${SE}"
fi
fake_proc 4206 1000 1028 'HOME\0/x\0ATHENA_REAP_TAGS=t0\0'       # 28 bytes
scan_fake 4206
if [ "${SRC}" -eq 0 ] && [ -z "${SO}" ] && [ -z "${SE}" ]; then
  ok "S15 another variable read mid-rewrite, ours whole and untagged: a plain 'no'"
else
  bad "S15 another variable read mid-rewrite, ours whole and untagged: a plain 'no'" "rc=${SRC} out=${SO} err=${SE}"
fi
fake_proc 4207 1000 1016 'HOME=/x\0DND_X\0v\0'                    # 16 bytes
SO="$(gawk -b -f "${SCAN}" -v mode=exact -v needle=DND_X=v -v uid="${UID}" -v since=0 -v settle_s=0.2 \
      -v root="${TMP}/fakeproc" "${TMP}/fakeproc/4207" 2>"${TMP}/scan.err")"; SRC=$?; SE="$(cat "${TMP}/scan.err")"
if [ "${SRC}" -eq 4 ] && [ -z "${SO}" ] && grep -q 'pid 4207 .*UNKNOWN' <<<"${SE}"; then
  ok "S15 mode exact: the needle's entry read mid-rewrite is UNKNOWN, exit 4, never 'no'"
else
  bad "S15 mode exact: the needle's entry read mid-rewrite is UNKNOWN, exit 4" "rc=${SRC} out=${SO} err=${SE}"
fi

# S18 (DND-1616): a process name may hold a newline (and ") "), and the scan
# reads EVERY pid's stat before it knows whose the process is. Read one line
# at a time, the stat of `x) Z (<newline>y` ends inside the name: 4 fields, so
# the scan died (exit 3) and the reap killed nothing. proc-state's own P-6
# runs such a process, so any gate that ran P-6 beside this suite turned S13
# and S14 red at 1454c234. The fields start after the LAST ") " of the whole
# file. Another user's process (uid 0) must not blind the scan; one of ours
# with that name is still read.
NL_COMM="x) Z ("$'\n'"y"
fake_proc 4208 1000 1031 "${ENV1}" "${NL_COMM}" 0
fake_proc 4209 1000 1031 "${ENV1}" "${NL_COMM}"
SO="$(gawk -b -f "${SCAN}" -v mode=tag -v needle=t1 -v uid="${UID}" -v since=0 -v settle_s=0.2 \
      -v root="${TMP}/fakeproc" "${TMP}/fakeproc/4208" "${TMP}/fakeproc/4209" "${TMP}/fakeproc/4201" 2>"${TMP}/scan.err")"; SRC=$?
SE="$(cat "${TMP}/scan.err")"
if [ "${SRC}" -eq 0 ] && [ "${SO}" = $'4209\n4201' ] && [ -z "${SE}" ]; then
  ok "S18 a process name holding a newline and ') ' does not blind the scan: exit 0, the tagged pids (one of them so named) found"
else
  bad "S18 a process name holding a newline does not blind the scan" "rc=${SRC} out=$(printf '%s' "${SO}" | tr '\n' ' ') err=${SE}"
fi

# S16: a NON-DUMPABLE process of ours (ssh-agent disables tracing) shows 0 0
# bounds forever, like a process mid-exec. It must be skipped at once by who
# owns its /proc files, not waited out: waiting made every scan cost settle_s
# (5s) while any such process was alive, and every gate check runs a scan.
if command -v ssh-agent >/dev/null 2>&1; then
  ND="DND1016_ST_ND=s16-$$"; MARKS+=("${ND}")
  env "${ND}" ssh-agent -D -a "${TMP}/s16.sock" >/dev/null 2>&1 & ndp=$!
  for i in $(seq 1 50); do [ -S "${TMP}/s16.sock" ] && break; sleep 0.1; done
  t0="$(date +%s%N)"; SO="$(suite_env_pids exact "${ND}" 2>"${TMP}/s16.err")"; SRC=$?; t1="$(date +%s%N)"
  ms=$(( (t1 - t0) / 1000000 ))
  kill -9 "${ndp}" 2>/dev/null; wait "${ndp}" 2>/dev/null
  if [ "${SRC}" -eq 0 ] && [ "${ms}" -lt 2000 ] && [ ! -s "${TMP}/s16.err" ]; then
    ok "S16 a non-dumpable process (ssh-agent) is skipped at once (${ms}ms), not waited out"
  else
    bad "S16 a non-dumpable process is skipped at once" "rc=${SRC} ${ms}ms out=${SO} err=$(head -c 300 "${TMP}/s16.err")"
  fi
else
  printf '  n/a   S16 not run: no ssh-agent on PATH, so no non-dumpable process to start\n'
fi

# S17 (DND-1203): R2 runs its suite with HOME pointing at a scratch home. The
# repro's shim used to exec `command -v ruby`, which in an agent session is
# the asdf shim, and an asdf shim finds no ruby under a scratch HOME (exit 126).
# So every ruby client R2's suite started died at once: the suite waited out
# each client's ready bound (R2 ~835s in a worktree gate; in a cron lane,
# whose PATH has no asdf shim, the whole suite-reaper check took ~96s), and
# the TERM-ignoring client the case exists to test never ran, so R2 passed
# without testing anything. Neither sub-case below depends on the clock: the
# repro's wait ends when the client's ready file names it, or when it exits. The fake `ruby` here
# stands in for the asdf shim: it works only under the HOME it was made for.
S17_REAL="$(/usr/bin/ruby -e 'print RbConfig.ruby' 2>/dev/null)"
[ -x "${S17_REAL}" ] || bad "S17 setup: resolve the ruby interpreter" "/usr/bin/ruby -e 'print RbConfig.ruby' gave '${S17_REAL}'"
S17_BIN="${TMP}/s17bin"; mkdir -p "${S17_BIN}"
printf '#!/usr/bin/env bash\n[ "${HOME}" = %q ] || { echo "fake asdf shim: no ruby version set under HOME=${HOME}" >&2; exit 126; }\nexec %q "$@"\n' \
  "${HOME}" "${S17_REAL}" >"${S17_BIN}/ruby"
chmod +x "${S17_BIN}/ruby"
# s17_suite <boot|noboot> -- a fake athena-inbox-client suite that starts the
# mock twice with MOCK_IGNORE_TERM=1, as case 45c does. `boot` mocks install
# their TERM trap and write the ready file; `noboot` mocks exit at once.
s17_suite() {
  printf '%s\n' '. "$(dirname "$0")/../lib/suite-reaper.bash"; suite_reaper_begin "$@"' \
    'trap suite_reap_tagged EXIT; trap "exit 143" TERM' \
    "export MOCK_READY=${TMP}/s17-$1.ready MOCK_IGNORE_TERM=1 S17_MODE=$1 S17_BOOTED=${TMP}/s17-$1.booted" \
    "ruby ${TMP}/s17/mock-athena-inbox-client.rb first" \
    "ruby ${TMP}/s17/mock-athena-inbox-client.rb & wait"
}
mkdir -p "${TMP}/s17"
cat >"${TMP}/s17/mock-athena-inbox-client.rb" <<'RB'
exit 0 if ARGV[0] == "first" || ENV["S17_MODE"] == "noboot"
trap("TERM") {}
File.write(ENV.fetch("S17_BOOTED"), Process.pid.to_s)
File.write(ENV.fetch("MOCK_READY"), Process.pid.to_s)
sleep 300
RB
r="$(s11_repo s17boot "$(s17_suite boot)")"
MARK="DND818_ST_MARK=s17boot-$$"; MARKS+=("${MARK}")
O="$(env "${MARK}" PATH="${S17_BIN}:${PATH}" REPRO_CASES=r2 \
      bash "${r}/scripts/test/suite-reaper/repro-real-suites.sh" 2>&1)"; ORC=$?
if [ -n "${S17_REAL}" ] && [ "${ORC}" -eq 0 ] && grep -q '^VERDICT: PASS' <<<"${O}" && [ -s "${TMP}/s17-boot.booted" ]; then
  ok "S17 with an asdf-style ruby first on PATH, R2's TERM-ignoring client still boots under the scratch HOME (pid $(cat "${TMP}/s17-boot.booted"))"
else
  bad "S17 with an asdf-style ruby first on PATH, R2's TERM-ignoring client boots under the scratch HOME" \
      "real_ruby=${S17_REAL:-none} rc=${ORC} booted=$(cat "${TMP}/s17-boot.booted" 2>/dev/null || echo none) $(printf '%s' "${O}" | tr '\n' '|')"
fi
gone "${MARK}" || { bad "S17 the fake suite's processes are reaped" "$(survivors "${MARK}")"; kill_marked "${MARK}"; }
r="$(s11_repo s17noboot "$(s17_suite noboot)")"
MARK="DND818_ST_MARK=s17noboot-$$"; MARKS+=("${MARK}")
O="$(env "${MARK}" PATH="${S17_BIN}:${PATH}" REPRO_CASES=r2 \
      bash "${r}/scripts/test/suite-reaper/repro-real-suites.sh" 2>&1)"; ORC=$?
if [ "${ORC}" -eq 1 ] && grep -q '^VERDICT: FAIL' <<<"${O}" && grep -q 'exited before it became ready' <<<"${O}"; then
  ok "S17 a target client that never boots makes R2 FAIL ('exited before it became ready'), never a vacuous PASS"
else
  bad "S17 a target client that never boots makes R2 FAIL, never a vacuous PASS" "rc=${ORC} $(printf '%s' "${O}" | tr '\n' '|')"
fi
gone "${MARK}" || { bad "S17 the no-boot fake suite's processes are reaped" "$(survivors "${MARK}")"; kill_marked "${MARK}"; }

# S18 end to end (DND-1616): with a live process named `x) Z (<newline>y`
# alive (proc-state P-6's shape, untagged by the fixture), the reap still
# kills the fixture's process and returns 0, and leaves the untagged one alone.
# The named process blocks opening a FIFO, so it has no child and its name
# never changes; it is killed by pid here, whatever the scan can see, and it
# carries a marker of its own, so an interrupted run's cleanup reaps it too.
mkdir -p "${TMP}/s18"; mkfifo "${TMP}/s18/fifo"
NLP="${TMP}/s18/${NL_COMM}"
printf '#!/bin/bash\nread -r _ <"$1"\n' >"${NLP}"; chmod +x "${NLP}"
NL_MARK="DND818_ST_MARK=s18named-$$"; MARKS+=("${NL_MARK}")
env "${NL_MARK}" "${NLP}" "${TMP}/s18/fifo" & nlp=$!
NLC=""
for i in $(seq 1 100); do
  { IFS= read -r -d '' NLC <"/proc/${nlp}/comm"; } 2>/dev/null
  [ "${NLC}" = "${NL_COMM}"$'\n' ] && break
  sleep 0.05
done
if [ "${NLC}" = "${NL_COMM}"$'\n' ]; then
  run_fixture s18 '. "${LIB}"; suite_reaper_begin "$@"
sleep 311 &
suite_reap_tagged; echo "rc=$?"'
  S18="$(cat "${TMP}/s18.out")"
  if [ "${S18}" = "rc=0" ] && gone "${MARK}" && proc_running "${nlp}"; then
    ok "S18 with a live newline-named process (pid ${nlp}) on the machine, the reap still kills the fixture's process and returns 0"
  else
    bad "S18 with a live newline-named process on the machine, the reap still works" \
        "${S18:-no output} survivors=$(survivors "${MARK}") named_alive=$(proc_running "${nlp}" && echo y || echo n) err=$(head -c 400 "${FX_ERR}")"
  fi
else
  bad "S18 premise: the live process is named 'x) Z (<newline>y'" "comm=$(printf '%q' "${NLC}")"
fi
kill -9 "${nlp}" 2>/dev/null; wait "${nlp}" 2>/dev/null
kill_marked "${MARK}"

# S10: the real suites, at the two measured windows (the deterministic repro).
R="$("${HERE}/repro-real-suites.sh" 2>&1)"; RRC=$?
if [ "${RRC}" -eq 0 ] && grep -q '^VERDICT: PASS' <<<"${R}"; then
  ok "S10 the real suites, SIGTERMed at both measured windows, leave nothing behind"
else
  bad "S10 the real suites leave nothing behind when SIGTERMed mid-run" "$(printf '%s' "${R}" | tr '\n' '|')"
fi

printf '\n'
if [ "${FAIL}" -eq 0 ]; then echo "VERDICT: PASS (${PASS} cases)"; exit 0; fi
echo "VERDICT: FAIL (${FAIL} failed, ${PASS} passed)"
echo "  Fix: read each FAIL; the claim names the behaviour. Repair scripts/test/lib/suite-reaper.bash (or the suite S9 names) and re-run scripts/test/suite-reaper/self-test.sh."
exit 1
