#!/usr/bin/env bash
# Self-test for scripts/test/lib/proc-state.bash (DND-1550).
#
# The defect class: a suite SIGKILLs a process (or has a tool do it), then asks
# `kill -0 <pid>` whether it is gone. kill -0 succeeds on a ZOMBIE, and a
# killed orphan is a zombie until its new parent (PID 1 or a subreaper) reaps
# it. So the assertion raced init's reap, and failed under load
# (inbox-client-capture C-10, 2026-10-01 14:27Z). A SIGKILL is also delivered
# asynchronously, so "killed" is an event to wait on, never an instant fact.
#
# Every zombie here is FORCED, not hoped for: a ruby holder spawns the target
# and never waits on it, so once killed the target stays a zombie until this
# suite kills the holder. No load, no repeated runs, no wall-clock verdict: the
# bounded waits only cap a hang.
#
# Run: bash scripts/test/proc-state/self-test.sh
set -uo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SCRIPTS="$(cd -- "${HERE}/../.." && pwd -P)"
# shellcheck source=scripts/test/lib/suite-reaper.bash
. "${SCRIPTS}/test/lib/suite-reaper.bash"
suite_reaper_begin "$@"
# shellcheck source=scripts/test/lib/proc-state.bash
. "${SCRIPTS}/test/lib/proc-state.bash"

PASS=0; FAIL=0
ok()  { printf '  ok    %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  FAIL  %s\n        %s\n' "$1" "$2"; FAIL=$((FAIL+1)); }

RUBY=/usr/bin/ruby
[ -x "${RUBY}" ] || {
  echo "VERDICT: FAIL — ${RUBY} is not executable; the zombie fixture's holder is ruby."
  echo "  Fix: install the harness Ruby at /usr/bin/ruby (DND-931/958; the harness gate itself needs it)."
  exit 1
}

TMP="$(mktemp -d)"
PIDS=()
cleanup() {
  local p
  for p in "${PIDS[@]}"; do kill -9 "${p}" 2>/dev/null; done
  for p in "${PIDS[@]}"; do wait "${p}" 2>/dev/null; done
  suite_reap_tagged
  rm -rf -- "${TMP}"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# wait_file <file> [tenths] -- a bounded poll with a real sleep; never a spin.
wait_file() {
  local f="$1" max="${2:-100}" i=0
  while [ "${i}" -lt "${max}" ]; do [ -s "${f}" ] && return 0; sleep 0.1; i=$((i+1)); done
  return 1
}

# stat_state <pid> -- the kernel's one-letter state, read directly (the
# fixture's own premise check; never the helper under test).
stat_state() {
  local s=""
  { IFS= read -r -d '' s <"/proc/$1/stat"; } 2>/dev/null
  [ -n "${s}" ] || return 1
  s="${s##*) }"; printf '%s\n' "${s%% *}"
}

# await_state <pid> <letter> [tenths] -- bounded wait for the kernel to report
# that state (a SIGKILL lands asynchronously).
await_state() {
  local i=0
  while [ "${i}" -lt "${3:-300}" ]; do [ "$(stat_state "$1")" = "$2" ] && return 0; sleep 0.1; i=$((i+1)); done
  return 1
}

# start_holder <name> -- a ruby process that spawns `sleep 600` in a NEW
# process group and never waits on it. Sets HOLDER and TARGET (the sleep's
# pid, which is also its process-group id).
HOLDER=""; TARGET=""
# An optional second argument is the program to spawn instead of `sleep 600`.
start_holder() {
  local ready="${TMP}/$1.ready" prog="${2:-}"
  # [[path, argv0]]: never a single string, which ruby would hand to /bin/sh.
  "${RUBY}" -e 'cmd = ARGV[1].empty? ? ["sleep", "600"] : [[ARGV[1], ARGV[1]]]
                pid = Process.spawn(*cmd, pgroup: true)
                File.write(ARGV[0] + ".tmp", pid.to_s); File.rename(ARGV[0] + ".tmp", ARGV[0])
                sleep' "${ready}" "${prog}" >/dev/null 2>&1 &
  HOLDER=$!; PIDS+=("${HOLDER}")
  TARGET=""
  wait_file "${ready}" 300 || return 1
  TARGET="$(cat "${ready}")"; PIDS+=("${TARGET}")
}

printf 'proc-state self-test\n'

# ---------------------------------------------------------------------------
printf '\nP-1  a live process reads running, and a bounded wait on it says so\n'
start_holder p1 || bad "P-1 fixture" "the holder never reported its child"
if [ -n "${TARGET}" ]; then
  proc_running "${TARGET}"; rc=$?
  [ "${rc}" -eq 0 ] && ok "P-1 a live sleep reads running (rc 0)" || bad "P-1 a live sleep reads running" "rc=${rc}"
  proc_wait_gone "${TARGET}" 3; rc=$?
  [ "${rc}" -eq 1 ] && ok "P-1 waiting for a live process to go returns 1 at the bound" || bad "P-1 waiting on a live process returns 1" "rc=${rc}"
  START="$(proc_starttime "${TARGET}")"; rc=$?
  [ "${rc}" -eq 0 ] && [ -n "${START}" ] && proc_running "${TARGET}" "${START}" \
    && ok "P-1 its own start time keeps it running (rc 0)" || bad "P-1 its own start time keeps it running" "rc=${rc} start=${START:-none}"
fi

# ---------------------------------------------------------------------------
printf '\nP-2  a SIGKILLed process that is still a ZOMBIE reads gone (the C-10 race)\n'
start_holder p2 || bad "P-2 fixture" "the holder never reported its child"
if [ -n "${TARGET}" ]; then
  kill -9 "${TARGET}"
  if await_state "${TARGET}" Z; then
    # The premise: this is exactly the state the old assertion raced. kill -0
    # succeeds on it, so `! kill -0` read a dead process as alive.
    if kill -0 "${TARGET}" 2>/dev/null; then
      ok "P-2 premise: the killed target is a zombie and kill -0 still succeeds on it"
    else
      bad "P-2 premise: kill -0 succeeds on the zombie" "kill -0 failed; the fixture proves nothing"
    fi
    proc_running "${TARGET}"; rc=$?
    [ "${rc}" -eq 1 ] && ok "P-2 a zombie reads not running (rc 1)" || bad "P-2 a zombie reads not running" "rc=${rc} state=$(stat_state "${TARGET}")"
    proc_wait_gone "${TARGET}" 300; rc=$?
    [ "${rc}" -eq 0 ] && ok "P-2 waiting for a zombie to go returns 0 at once" || bad "P-2 waiting for a zombie to go returns 0" "rc=${rc}"
  else
    bad "P-2 fixture: the killed target becomes a zombie" "state=$(stat_state "${TARGET}" || echo gone)"
  fi
fi

# ---------------------------------------------------------------------------
printf '\nP-3  a reaped pid reads gone; a reused pid (other start time) reads gone\n'
sleep 0 & GONE=$!; wait "${GONE}"
proc_running "${GONE}"; rc=$?
[ "${rc}" -eq 1 ] && ok "P-3 a reaped pid reads not running (rc 1)" || bad "P-3 a reaped pid reads not running" "rc=${rc}"
start_holder p3 || bad "P-3 fixture" "the holder never reported its child"
if [ -n "${TARGET}" ]; then
  proc_running "${TARGET}" 1; rc=$?
  [ "${rc}" -eq 1 ] && ok "P-3 a live pid with another start time is another process: not running (rc 1)" \
    || bad "P-3 a reused pid reads not running" "rc=${rc}"
fi

# ---------------------------------------------------------------------------
printf '\nP-4  a malformed pid is an error with a Fix:, never "gone"\n'
for arg in "" "abc" "0" "-5" "12x"; do
  err="$(proc_running "${arg}" 2>&1 >/dev/null)"; rc=$?
  if [ "${rc}" -eq 2 ] && grep -q 'Fix:' <<<"${err}"; then
    ok "P-4 proc_running '${arg}' -> rc 2 with a Fix:"
  else
    bad "P-4 proc_running '${arg}' -> rc 2 with a Fix:" "rc=${rc} err=${err}"
  fi
  err="$(proc_wait_gone "${arg}" 3 2>&1 >/dev/null)"; rc=$?
  [ "${rc}" -eq 2 ] && ok "P-4 proc_wait_gone '${arg}' -> rc 2, not 'gone'" || bad "P-4 proc_wait_gone '${arg}' -> rc 2" "rc=${rc} err=${err}"
done
err="$(proc_wait_gone "$$" "" 2>&1 >/dev/null)"; rc=$?
[ "${rc}" -eq 2 ] && grep -q 'Fix:' <<<"${err}" && ok "P-4 a missing bound -> rc 2 with a Fix:" || bad "P-4 a missing bound -> rc 2" "rc=${rc} err=${err}"
err="$(proc_starttime "nope" 2>&1 >/dev/null)"; rc=$?
[ "${rc}" -eq 2 ] && ok "P-4 proc_starttime 'nope' -> rc 2" || bad "P-4 proc_starttime 'nope' -> rc 2" "rc=${rc} err=${err}"

# ---------------------------------------------------------------------------
printf '\nP-5  a process group whose only members are zombies reads gone\n'
start_holder p5 || bad "P-5 fixture" "the holder never reported its child"
if [ -n "${TARGET}" ]; then
  proc_group_running "${TARGET}"; rc=$?
  [ "${rc}" -eq 0 ] && ok "P-5 a group with a live member reads running (rc 0)" || bad "P-5 a group with a live member reads running" "rc=${rc}"
  kill -9 -- "-${TARGET}"
  if await_state "${TARGET}" Z; then
    if kill -0 -- "-${TARGET}" 2>/dev/null; then
      ok "P-5 premise: kill -0 on the group still succeeds while its member is a zombie"
    else
      bad "P-5 premise: kill -0 on the group succeeds" "kill -0 failed; the fixture proves nothing"
    fi
    proc_group_running "${TARGET}"; rc=$?
    [ "${rc}" -eq 1 ] && ok "P-5 a group of zombies reads not running (rc 1)" || bad "P-5 a group of zombies reads not running" "rc=${rc}"
    proc_group_wait_gone "${TARGET}" 300; rc=$?
    [ "${rc}" -eq 0 ] && ok "P-5 waiting for that group to go returns 0" || bad "P-5 waiting for a group of zombies returns 0" "rc=${rc}"
  else
    bad "P-5 fixture: the killed group member becomes a zombie" "state=$(stat_state "${TARGET}" || echo gone)"
  fi
  err="$(proc_group_running "x" 2>&1 >/dev/null)"; rc=$?
  [ "${rc}" -eq 2 ] && grep -q 'Fix:' <<<"${err}" && ok "P-5 a malformed pgid -> rc 2 with a Fix:" || bad "P-5 a malformed pgid -> rc 2" "rc=${rc} err=${err}"
fi

# ---------------------------------------------------------------------------
printf '\nP-6  a process name holding ") Z (" and a newline is parsed after the LAST ") "\n'
# The kernel names a script's process after the script file, so this name is
# the process name. A first-line or first-") " parse would read state "Z".
WEIRD="${TMP}/x) Z ("$'\n'"y"
printf '#!/bin/bash\nwhile :; do sleep 600; done\n' >"${WEIRD}"; chmod +x "${WEIRD}"
start_holder p6 "${WEIRD}" || bad "P-6 fixture" "the holder never reported its child"
if [ -n "${TARGET}" ]; then
  # Premise: the target has exec'd the script, so its name is the weird one.
  COMM=""; i=0
  while [ "${i}" -lt 300 ]; do
    COMM=""; { IFS= read -r -d '' COMM <"/proc/${TARGET}/comm"; } 2>/dev/null
    [ "${COMM}" = "x) Z ("$'\n'"y"$'\n' ] && break
    sleep 0.1; i=$((i+1))
  done
  [ "${COMM}" = "x) Z ("$'\n'"y"$'\n' ] && ok "P-6 premise: the process name is 'x) Z (<newline>y'" || bad "P-6 premise: the process name" "comm=$(printf '%q' "${COMM}")"
  START="$(proc_starttime "${TARGET}")"; rc=$?
  [ "${rc}" -eq 0 ] && _proc_state_posint "${START}" && ok "P-6 its start time parses (${START})" || bad "P-6 its start time parses" "rc=${rc} start=${START:-none}"
  proc_running "${TARGET}" "${START}"; rc=$?
  [ "${rc}" -eq 0 ] && ok "P-6 it reads running (rc 0), not a zombie" || bad "P-6 it reads running" "rc=${rc}"
  kill -9 -- "-${TARGET}"    # the group: the script and its sleep
  if await_state "${TARGET}" Z; then
    proc_running "${TARGET}"; rc=$?
    [ "${rc}" -eq 1 ] && ok "P-6 killed, it reads not running (rc 1)" || bad "P-6 killed, it reads not running" "rc=${rc}"
  else
    bad "P-6 fixture: the killed target becomes a zombie" "state=$(stat_state "${TARGET}" || echo gone)"
  fi
fi
sleep 0 & GONE=$!; wait "${GONE}"
proc_starttime "${GONE}" >/dev/null 2>&1; rc=$?
[ "${rc}" -eq 1 ] && ok "P-6 proc_starttime of a reaped pid -> rc 1" || bad "P-6 proc_starttime of a reaped pid -> rc 1" "rc=${rc}"

printf '\n'
if [ "${FAIL}" -eq 0 ]; then echo "VERDICT: PASS (${PASS} cases)"; exit 0; fi
echo "VERDICT: FAIL (${FAIL} failed, ${PASS} passed)"
echo "  Fix: read each FAIL above; the claim names the behaviour. Repair scripts/test/lib/proc-state.bash and re-run this suite."
exit 1
