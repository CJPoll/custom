#!/usr/bin/env bash
# repro-real-suites.sh -- DND-818's deterministic reproduction against the REAL
# mock-bearing suites. scripts/test/suite-reaper/self-test.sh runs it as case
# S10, so every harness-gate run runs it (about 75s: most of both suites, up to
# the chosen spawn). It also runs standalone:
#
#   scripts/test/suite-reaper/repro-real-suites.sh
#
# The measured incident: a harness-gate run was SIGTERMed (test-slot exit 143
# at 20:46:58Z) and left a ruby client born in that same second, ppid 1. Its
# suite was SIGTERMed after starting it but before recording its pid, so the
# suite's pid-list cleanup never knew it existed.
#
# The timing is made deterministic with a `ruby` shim first on PATH. The
# suites start every client as a bare `ruby ...` (directly, or through a stub
# that execs `ruby`), so the shim runs as the new client's own process. When it
# is the client a case targets, it SIGTERMs the suite and only then execs the
# real ruby. The client therefore always exists before the suite can have read
# its ready file, which is the window the incident needed luck to hit.
#
# R1  inbox-client-capture: the TERM lands as C-10's fake-suite.sh starts its
#     mock. The suite never records the fake suite or its mock.
# R2  athena-inbox-client: the TERM lands as case 45c's supervisor RELAUNCHES
#     a client that ignores SIGTERM (the second MOCK_IGNORE_TERM=1 start). The
#     supervisor's reaper sends it SIGTERM, which it ignores, and the suite
#     never learned its pid.
#
# Environment (all optional):
#   REPRO_CASES    which cases to run, space-separated (default "r1 r2").
#   REPRO_WAIT_S   hard cap on the wait for each suite (default 1200).
#   REPRO_STALL_S  a suite that prints nothing for this long is stuck (default 240).
#   REPRO_READY_S  a hang cap on R2's wait for its target client (default 120).
#                  The wait ends on an event: the client's ready file names it,
#                  or the client exited first (R2 FAILs: nothing was tested).
#                  Only a client still booting at the cap is a no-verdict FAIL.
# A case that cannot run is a FAIL that says which of two things happened:
# the suite was still RUNNING when the wait ran out (a slow or stuck suite,
# killed here, no leak verdict), or it EXITED early (named with its status).
# Either way the suite's own FAIL lines are quoted. Before this (2026-09-28) a
# loaded gate's still-running suite was reported as "the trigger never fired
# (suite exited ...)" and its live children as processes that "outlived" it.
#
# Survivors are found by a marker this script puts in each suite's
# environment (every process the suite starts inherits it), never by the
# suite's own bookkeeping. Each is printed, then killed BY PID.
# VERDICT: PASS means no process outlived either SIGTERMed suite.
set -uo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
REPO="$(cd -- "${HERE}/../../.." && pwd -P)"
command -v ruby >/dev/null 2>&1 || { echo "VERDICT: FAIL -- no ruby on PATH"; echo "  Fix: put ruby on PATH."; exit 1; }
[[ "${REPRO_READY_S:-120}" =~ ^[1-9][0-9]*$ ]] || { echo "VERDICT: FAIL -- REPRO_READY_S='${REPRO_READY_S}' is not a whole number of seconds"; echo "  Fix: set REPRO_READY_S to a positive integer, or unset it (default 120)."; exit 2; }
WORK="$(mktemp -d)"
FAIL=0
NORUN=0   # cases whose suite was still running when the wait ran out
TRACK=()

# pids_with_env <VAR=value> -- own-uid pids whose environ holds exactly it,
# read through the reaper's scan (DND-1016): a plain environ read misses a
# survivor caught mid-exec and gives a false PASS. It runs inside $(...),
# where an exit is lost, so a scan that cannot run prints the token
# SCAN-FAILED in place of a pid: the caller reads "something outlived the
# suite" and the case FAILs, never "no survivors".
. "${REPO}/scripts/test/lib/suite-reaper.bash"
pids_with_env() {
  suite_env_pids exact "$1" && return 0
  echo "repro: the process scan could not run, so survivors cannot be counted." >&2
  echo "  Fix: repair the scan's reason above (scripts/lib/proc-env-scan.awk)." >&2
  echo "SCAN-FAILED"
}

report_survivors() { # report_survivors <label> <marker>
  local label="$1" marker="$2" s p
  s="$(pids_with_env "${marker}")"
  if [ -n "${s}" ]; then
    printf '  FAIL  %s: processes outlived the SIGTERMed suite:\n' "${label}"
    for p in ${s}; do
      printf '        pid=%s ppid=%s cmd=%s\n' "${p}" "$(awk '{print $4}' "/proc/${p}/stat" 2>/dev/null)" \
        "$(tr '\0' ' ' <"/proc/${p}/cmdline" 2>/dev/null)"
    done
    FAIL=$((FAIL+1))
    for p in ${s}; do kill -9 "${p}" 2>/dev/null; done
  else
    printf '  ok    %s: nothing outlived the SIGTERMed suite\n' "${label}"
  fi
}

cleanup() {
  local p
  for p in ${TRACK[@]+"${TRACK[@]}"}; do kill -9 "${p}" 2>/dev/null; done
  rm -rf -- "${WORK}"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# The shim. REPRO_CASE picks the trigger; REPRO_SUITE_PAT names the suite
# process to SIGTERM (found by walking this process's ancestors); REPRO_FIRED
# makes the trigger fire once.
mkdir -p "${WORK}/bin"
cat >"${WORK}/bin/ruby" <<'SHIM'
#!/usr/bin/env bash
fire=0
case "${REPRO_CASE:-}" in
  r1) case "$(tr '\0' ' ' </proc/$PPID/cmdline 2>/dev/null)" in *fake-suite.sh*) fire=1 ;; esac ;;
  r2) if [ "${MOCK_IGNORE_TERM:-0}" = 1 ] && [[ " $* " == *mock-athena-inbox-client.rb* ]]; then
        if [ -e "${REPRO_SEEN}" ]; then fire=1; else : >"${REPRO_SEEN}"; fi
      fi ;;
esac
if [ "${fire}" = 1 ] && [ ! -e "${REPRO_FIRED}" ]; then
  : >"${REPRO_FIRED}"
  p=$PPID
  while [ -n "${p}" ] && [ "${p}" -gt 1 ]; do
    case "$(tr '\0' ' ' </proc/${p}/cmdline 2>/dev/null)" in
      *"${REPRO_SUITE_PAT}"*)
        if [ "${REPRO_CASE}" = r2 ]; then
          # Freeze the suite so it cannot read the ready file, let the client
          # finish booting (its TERM-ignoring trap installed, ready written),
          # then deliver the SIGTERM and thaw it. Only then can the cleanup's
          # own SIGTERM meet a client that ignores it, as in the incident.
          # The wait ends on an EVENT, never on the clock (DND-1203): the
          # ready file naming THIS pid (the exec keeps it) proves the client
          # booted (.ready); the client dead before that means the case tests
          # nothing (.dead). REPRO_READY_S is only a hang cap; a client still
          # alive and not ready when it runs out is recorded as .slow, a
          # no-verdict run, never as "tested nothing".
          kill -STOP "${p}"
          me=$$; st0="$(cat "/proc/${me}/stat")"; st0="${st0##*) }"
          st0="$(set -- ${st0}; printf '%s' "${20}")"   # starttime: survives exec, not pid reuse
          ( out=slow
            for _ in $(seq 1 $(( ${REPRO_READY_S:-120} * 10 ))); do
              [ "$(cat "${MOCK_READY}" 2>/dev/null)" = "${me}" ] && { out=ready; break; }
              s="$(cat "/proc/${me}/stat" 2>/dev/null)"; s="${s##*) }"
              set -- ${s}
              { [ -z "${s}" ] || [ "$1" = Z ] || [ "$1" = X ] || [ "${20}" != "${st0}" ]; } && { out=dead; break; }
              sleep 0.1
            done
            : >"${REPRO_FIRED}.${out}"
            kill -TERM "${p}"; kill -CONT "${p}" ) >/dev/null 2>&1 &
        else
          kill -TERM "${p}"
        fi
        printf '%s\n' "$$" >"${REPRO_FIRED}"; break ;;
    esac
    p="$(awk '{print $4}' /proc/${p}/stat 2>/dev/null)"
  done
fi
exec "${REAL_RUBY}" "$@"
SHIM
chmod +x "${WORK}/bin/ruby"
# scripts/athena-inbox-client-run.sh resets PATH to a fixed list headed by
# ${HOME}/.local/bin, so R2 also runs with HOME pointing at a scratch home
# whose .local/bin holds the same shim.
mkdir -p "${WORK}/home/.local/bin"
cp "${WORK}/bin/ruby" "${WORK}/home/.local/bin/ruby"

# REAL_RUBY is the interpreter itself, never the first `ruby` on PATH
# (DND-1203). In an agent session that is the asdf shim, and an asdf shim
# finds no ruby under R2's scratch HOME (exit 126): every client R2's suite
# started died at once, the suite waited out each one's ready bound (~835s a
# gate), and the TERM-ignoring client R2 exists to test never ran. RbConfig.ruby
# is resolved here, under the real HOME, and must then run under the scratch one.
REAL_RUBY="$(ruby -e 'print RbConfig.ruby' 2>/dev/null)"
if [ -z "${REAL_RUBY}" ] || [ ! -x "${REAL_RUBY}" ]; then
  echo "VERDICT: FAIL -- could not resolve the ruby interpreter: \`ruby -e 'print RbConfig.ruby'\` gave '${REAL_RUBY}' (the first ruby on PATH is $(command -v ruby))"
  echo "  Fix: make the first ruby on PATH run under this HOME (an asdf shim needs a version set for this directory)."
  exit 1
fi
if ! HOME="${WORK}/home" "${REAL_RUBY}" -e 0 >/dev/null 2>&1; then
  echo "VERDICT: FAIL -- the ruby interpreter '${REAL_RUBY}' (RbConfig.ruby of the first ruby on PATH) does not run with HOME=${WORK}/home"
  echo "  Fix: the shim must exec a ruby that needs nothing from HOME; check \`ruby -e 'print RbConfig.ruby'\` names an executable interpreter."
  exit 1
fi
export REAL_RUBY

# wait_suite <pid> <outfile> -- block until the suite exits (status 0), or
# until it stalls or hits the cap (status 1, WAIT_WHY says which). The bound
# follows progress, not a wall clock alone: a suite that keeps printing is
# working, however loaded the machine, and a suite that prints nothing for
# REPRO_STALL_S is stuck. REPRO_WAIT_S caps the whole wait either way.
WAIT_WHY=""
wait_suite() {
  local pid="$1" out="$2" cap="${REPRO_WAIT_S:-1200}" stall="${REPRO_STALL_S:-240}" start now size last=-1 changed
  start="$(date +%s)"; changed="${start}"
  while kill -0 "${pid}" 2>/dev/null; do   # our own child: its pid is not reused before we wait
    now="$(date +%s)"
    size="$(stat -c %s "${out}" 2>/dev/null || echo 0)"
    if [ "${size}" != "${last}" ]; then last="${size}"; changed="${now}"; fi
    if [ $((now - start)) -ge "${cap}" ]; then WAIT_WHY="the ${cap}s cap ran out"; return 1; fi
    if [ $((now - changed)) -ge "${stall}" ]; then WAIT_WHY="it printed nothing for ${stall}s, at $((now - start))s"; return 1; fi
    timeout 5 tail --pid="${pid}" -f /dev/null
  done
  return 0
}

# suite_own_fails <outfile> -- the suite's own FAIL lines (each with its detail
# line), else its last lines: why the case could not run starts there.
suite_own_fails() {
  local f
  f="$(grep -A1 '^  FAIL' "$1" 2>/dev/null | grep -v '^--$' | head -n 12)"
  if [ -n "${f}" ]; then
    printf '        the suite'"'"'s own FAIL lines so far:\n'; printf '%s\n' "${f}" | sed 's/^/        | /'
  else
    printf '        the suite'"'"'s last lines:\n'; tail -n 3 "$1" 2>/dev/null | sed 's/^/        | /'
  fi
}

# kill_mark <marker> -- kill every process carrying the marker, by pid, until
# none is left (bounded; a process mid-fork is caught on the next pass).
kill_mark() {
  local pass p s
  for pass in 1 2 3 4 5; do
    s="$(pids_with_env "$1")"
    [ -z "${s}" ] && return 0
    for p in ${s}; do
      [ "${pass}" = 1 ] && printf '        killed pid=%s cmd=%s\n' "${p}" "$(tr '\0' ' ' <"/proc/${p}/cmdline" 2>/dev/null)"
      kill -9 "${p}" 2>/dev/null
    done
    timeout 1 tail --pid="${p}" -f /dev/null 2>/dev/null
  done
}

run_case() { # run_case <id> <label> <suite-rel-path> <suite-pattern> [HOME]
  local id="$1" label="$2" suite="$3" pat="$4" home="${5:-${HOME}}" mark="DND818_REPRO_MARK=${1}-$$" pid rc
  printf '%s  %s\n' "${id^^}" "${label}"
  env "${mark}" HOME="${home}" PATH="${WORK}/bin:${PATH}" REPRO_CASE="${id}" REPRO_SUITE_PAT="${pat}" \
      REPRO_SEEN="${WORK}/${id}.seen" REPRO_FIRED="${WORK}/${id}.fired" \
      bash "${REPO}/${suite}" >"${WORK}/${id}.out" 2>&1 &
  pid=$!; TRACK+=("${pid}")
  if ! wait_suite "${pid}" "${WORK}/${id}.out"; then
    # Still running is NOT a leak and NOT an early exit: every process of the
    # suite is still a live descendant of a live suite. Say so, and stop it.
    printf '  FAIL  %s: the suite was still RUNNING when the wait ran out (%s); it never exited, so this run gives no leak verdict%s\n' \
      "${id}" "${WAIT_WHY}" "$([ -s "${WORK}/${id}.fired" ] && echo ' (the trigger had fired)')"
    suite_own_fails "${WORK}/${id}.out"
    printf '        Fix: a loaded machine slows the suite; re-run this repro alone (REPRO_CASES=%s). A stall with the same last line each time is a hang in the suite.\n' "${id}"
    FAIL=$((FAIL+1))
    kill_mark "${mark}"; wait "${pid}" 2>/dev/null; NORUN=$((NORUN+1))
    return
  fi
  wait "${pid}"; rc=$?
  if [ ! -s "${WORK}/${id}.fired" ]; then
    printf '  FAIL  %s setup: the suite EXITED (status %s) before the trigger fired\n' "${id}" "${rc}"
    suite_own_fails "${WORK}/${id}.out"
    FAIL=$((FAIL+1))
    report_survivors "${id}" "${mark}"
    return
  fi
  report_survivors "${id} (target client pid $(cat "${WORK}/${id}.fired"))" "${mark}"
  # R2's window needs the TERM-ignoring client ALIVE when the SIGTERM lands.
  # A client that died before its ready file named it leaves nothing to leak,
  # so "nothing outlived" would be a vacuous PASS (DND-1203).
  [ "${id}" = r2 ] || return
  local f="${WORK}/${id}.fired" c
  c="$(cat "${f}")"
  if [ -e "${f}.ready" ]; then
    :
  elif [ -e "${f}.dead" ]; then
    printf '  FAIL  %s: the target client (pid %s) exited before it became ready, so the SIGTERM met no TERM-ignoring client and this case tested nothing\n' "${id}" "${c}"
    suite_own_fails "${WORK}/${id}.out"
    printf '        Fix: the shim execs REAL_RUBY with HOME=%s; make sure that ruby and the mock start there.\n' "${WORK}/home"
    FAIL=$((FAIL+1))
  elif [ -e "${f}.slow" ]; then
    printf '  FAIL  %s: the target client (pid %s) was still alive but not ready when the %ss hang cap ran out; this run gives no verdict\n' "${id}" "${c}" "${REPRO_READY_S:-120}"
    printf '        Fix: re-run this repro alone (REPRO_CASES=%s); a client that never writes its ready file is hung in its boot.\n' "${id}"
    FAIL=$((FAIL+1)); NORUN=$((NORUN+1))
  else
    printf '  FAIL  %s: the trigger fired (target pid %s) but left no ready/dead/slow record, so whether the client booted is unknown\n' "${id}" "${c}"
    printf '        Fix: the shim'"'"'s ready waiter did not finish; read %s and the shim in this script.\n' "${WORK}/${id}.out"
    FAIL=$((FAIL+1))
  fi
}

for c in ${REPRO_CASES:-r1 r2}; do
  case "${c}" in
    r1) run_case r1 "inbox-client-capture: SIGTERM as C-10's fake suite starts its mock" \
          scripts/test/inbox-client-capture/self-test.sh inbox-client-capture/self-test.sh ;;
    r2) run_case r2 "athena-inbox-client: SIGTERM as 45c relaunches a TERM-ignoring client" \
          scripts/test/athena-inbox-client/self-test.sh athena-inbox-client/self-test.sh "${WORK}/home" ;;
    *) echo "VERDICT: FAIL -- unknown case '${c}' in REPRO_CASES"; echo "  Fix: REPRO_CASES takes r1 and/or r2."; exit 2 ;;
  esac
done

printf '\n'
if [ "${FAIL}" -eq 0 ]; then echo "VERDICT: PASS"; exit 0; fi
echo "VERDICT: FAIL (${FAIL})"
[ "${NORUN}" -gt 0 ] && echo "  Fix: ${NORUN} case(s) never reached a verdict (the suite was still running); read each case's own FAIL lines above and re-run it alone before reading this as a leak."
[ "${FAIL}" -gt "${NORUN}" ] && echo "  Fix: a suite must reap every process it started on every exit path, whether or not it learned the pid (scripts/test/lib/suite-reaper.bash)."
exit 1
