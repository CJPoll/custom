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
#       equal bounds still equal on a re-read are an empty environment.
#   S16 a non-dumpable process (0 0 forever) is skipped at once, not waited out.
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
# reaps. 30 rounds, each asking the kernel afterwards whether it survived.
printf '#!%s\n%q & printf "%%s\\n" "$!" >"$1"\n' "${BASH}" "${TMP}/spin.sh" >"${TMP}/s13-launcher.sh"
run_fixture s13 '. "${LIB}"; suite_reaper_begin "$@"
trap suite_reap_tagged EXIT
left=0
for i in $(seq 1 30); do
  bash '"${TMP}"'/s13-launcher.sh '"${TMP}"'/s13.pid
  c="$(cat '"${TMP}"'/s13.pid)"
  suite_reap_tagged 2>/dev/null
  if kill -0 "$c" 2>/dev/null; then left=$((left+1)); kill -9 "$c"; fi
done
echo "survived=${left}"'
S13="$(cat "${TMP}/s13.out")"
if [ "${S13}" = "survived=0" ] && gone "${MARK}"; then
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
if [ "${S14}" = "rc=1" ] && grep -q 'scan could not run' "${FX_ERR}" && grep -q 'Fix:' "${FX_ERR}" && gone "${MARK}"; then
  ok "S14 a scan that cannot run fails the reap (status 1, with a Fix:), never 'none left'"
else
  bad "S14 a scan that cannot run fails the reap loudly" "${S14:-no output} survivors=$(survivors "${MARK}") err=$(head -c 400 "${FX_ERR}")"
fi

# S15: the scan's verdicts on a fixture /proc (root=), one state each, so the
# rule is pinned without racing a real exec. fake_proc <pid> <env_start>
# <env_end> <environ-bytes> writes a stat line in the kernel's shape (fields
# 50-51 are the env bounds), a status with our uid, and the environ.
SCAN="${REPO}/scripts/lib/proc-env-scan.awk"
fake_proc() {
  local d="${TMP}/fakeproc/$1" i f=""
  mkdir -p "${d}"
  for i in $(seq 4 49); do
    case "${i}" in 22) f="${f} 100" ;; *) f="${f} 0" ;; esac
  done
  printf '%s (fake) S%s %s %s 0\n' "$1" "${f}" "$2" "$3" >"${d}/stat"
  printf 'Name:\tfake\nUid:\t%s\t%s\t%s\t%s\n' "${UID}" "${UID}" "${UID}" "${UID}" >"${d}/status"
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
  ok "S15 equal bounds still equal on a re-read: an empty environment, 'no' with no warning"
else
  bad "S15 equal bounds still equal on a re-read: an empty environment" "rc=${SRC} out=${SO} err=${SE}"
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
