#!/usr/bin/env bash
# repro-real-suites.sh -- DND-818's deterministic reproduction against the REAL
# mock-bearing suites. Not a self-test (harness-gate discovers only
# **/self-test.sh): it runs two whole suites, so it costs about 80s. Run it by
# hand to re-prove the incident class:
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
# Survivors are found by a marker this script puts in each suite's
# environment (every process the suite starts inherits it), never by the
# suite's own bookkeeping. Each is printed, then killed BY PID.
# VERDICT: PASS means no process outlived either SIGTERMed suite.
set -uo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
REPO="$(cd -- "${HERE}/../../.." && pwd -P)"
REAL_RUBY="$(command -v ruby)" || { echo "VERDICT: FAIL -- no ruby on PATH"; echo "  Fix: put ruby on PATH."; exit 1; }
WORK="$(mktemp -d)"
FAIL=0
TRACK=()

# pids_with_env <VAR=value> -- own-uid pids whose environ holds exactly it.
pids_with_env() {
  local want="$1" d e
  for d in /proc/[0-9]*; do
    [ -O "${d}" ] || continue
    {
      while IFS= read -r -d '' e; do
        if [ "${e}" = "${want}" ]; then printf '%s\n' "${d#/proc/}"; break; fi
      done <"${d}/environ"
    } 2>/dev/null
  done
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
          kill -STOP "${p}"
          ( for _ in $(seq 1 300); do [ -s "${MOCK_READY}" ] && break; sleep 0.1; done
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
export REAL_RUBY
# scripts/athena-inbox-client-run.sh resets PATH to a fixed list headed by
# ${HOME}/.local/bin, so R2 also runs with HOME pointing at a scratch home
# whose .local/bin holds the same shim.
mkdir -p "${WORK}/home/.local/bin"
cp "${WORK}/bin/ruby" "${WORK}/home/.local/bin/ruby"

run_case() { # run_case <id> <label> <suite-rel-path> <suite-pattern> [HOME]
  local id="$1" label="$2" suite="$3" pat="$4" home="${5:-${HOME}}" mark="DND818_REPRO_MARK=${1}-$$" pid
  printf '%s  %s\n' "${id^^}" "${label}"
  env "${mark}" HOME="${home}" PATH="${WORK}/bin:${PATH}" REPRO_CASE="${id}" REPRO_SUITE_PAT="${pat}" \
      REPRO_SEEN="${WORK}/${id}.seen" REPRO_FIRED="${WORK}/${id}.fired" \
      bash "${REPO}/${suite}" >"${WORK}/${id}.out" 2>&1 &
  pid=$!; TRACK+=("${pid}")
  timeout 400 tail --pid="${pid}" -f /dev/null
  if [ ! -s "${WORK}/${id}.fired" ]; then
    printf '  FAIL  %s setup: the trigger never fired (suite exited %s)\n' "${id}" "$(tail -n 2 "${WORK}/${id}.out" | tr '\n' ' ')"
    FAIL=$((FAIL+1))
    report_survivors "${id}" "${mark}"
    return
  fi
  report_survivors "${id} (target client pid $(cat "${WORK}/${id}.fired"))" "${mark}"
}

run_case r1 "inbox-client-capture: SIGTERM as C-10's fake suite starts its mock" \
  scripts/test/inbox-client-capture/self-test.sh inbox-client-capture/self-test.sh
run_case r2 "athena-inbox-client: SIGTERM as 45c relaunches a TERM-ignoring client" \
  scripts/test/athena-inbox-client/self-test.sh athena-inbox-client/self-test.sh "${WORK}/home"

printf '\n'
if [ "${FAIL}" -eq 0 ]; then echo "VERDICT: PASS"; exit 0; fi
echo "VERDICT: FAIL (${FAIL})"
echo "  Fix: a suite must reap every process it started on every exit path, whether or not it learned the pid (scripts/test/lib/suite-reaper.bash)."
exit 1
