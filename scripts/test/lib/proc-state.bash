# proc-state.bash -- is a process (or process group) still RUNNING, and wait
# for it to stop. For test suites; sourced, never run. (DND-1550)
#
# Why. `kill -0 <pid>` answers "does a process table entry exist", not "is it
# running". It succeeds on a ZOMBIE, and a SIGKILLed orphan is a zombie until
# its new parent (PID 1, or a subreaper) reaps it. A suite that asserted
# `! kill -0 $pid` right after a tool killed an orphan raced init's reap:
# inbox-client-capture C-10 failed that way on 2026-10-01 at load 23. And a
# SIGKILL is delivered asynchronously, so the target may not even be a zombie
# yet when the killer returns. "It is gone" is therefore an EVENT to wait on
# (bounded, to cap a hang), judged on the kernel's own state letter.
#
# Running means: /proc/<pid>/stat exists, its state is not Z (zombie) or X/x
# (dead), and, when a start time is given, it is the same process (a pid can be
# reused once the zombie is reaped).
#
# A malformed pid or bound is an ERROR (status 2, with a Fix:), never "gone":
# an empty or mistyped pid matches nothing, and a predicate that read that as
# "the process is gone" would pass a suite whose fixture is broken. "Could not
# look" (status 3: no /proc, or a stat that exists but is unreadable, empty or
# short) is never "gone" either.
#
# Status, every function:
#   proc_starttime <pid>                  prints the start time (clock ticks);
#                                         0 found, 1 no such process, 2 malformed,
#                                         3 could not read
#   proc_running <pid> [<start>]          0 running, 1 not running, 2 malformed,
#                                         3 could not read
#   proc_wait_gone <pid> <tenths> [<start>]
#                                         0 gone, 1 still running at the bound,
#                                         2 malformed, 3 could not read
#   proc_group_running <pgid>             0 a member is running, 1 none, 2 malformed,
#                                         3 /proc cannot be read at all
#   proc_group_wait_gone <pgid> <tenths>  0 gone, 1 a member still running, 2 malformed,
#                                         3 /proc cannot be read at all
# A bound is at least 1 tenth of a second; for an instant answer call
# proc_running (or proc_group_running).

_proc_state_bad() { # <what> <value>
  echo "proc-state: $1 '$2' is not a positive integer." >&2
  echo "  Fix: pass the pid (or pgid, or bound in tenths of a second) the caller actually recorded; an empty or mistyped value must never read as 'gone'." >&2
  return 2
}

_proc_state_blind() { # <what>
  echo "proc-state: $1 could not be read, so whether the process is running is unknown (never read as gone)." >&2
  echo "  Fix: run the suite on Linux with /proc mounted, as the user that owns the process." >&2
  return 3
}

_proc_state_posint() { case "$1" in ''|0*|*[!0-9]*) return 1 ;; esac; return 0; }

# _proc_state_fields <pid> -- sets _PS_F (the stat fields after "(comm) ",
# so _PS_F[0] is the state, [2] the pgrp, [19] the start time). 1 when the
# process does not exist; 3 when it cannot be looked at (no /proc at all, or
# /proc/<pid> exists but its stat is unreadable, empty or short). The whole
# file is read (-d ''): a process name may hold a newline or ") ", so the
# fields are taken after the LAST ") ".
_proc_state_fields() {
  local s=""
  _PS_F=()
  [ -r /proc/self/stat ] || return 3
  { IFS= read -r -d '' s <"/proc/$1/stat"; } 2>/dev/null
  if [ -z "${s}" ]; then
    [ -e "/proc/$1" ] && return 3
    return 1
  fi
  s="${s%$'\n'}"
  s="${s##*) }"
  read -r -a _PS_F <<<"${s}"
  [ "${#_PS_F[@]}" -ge 20 ] || return 3
  return 0
}

proc_starttime() {
  _proc_state_posint "${1:-}" || { _proc_state_bad pid "${1:-}"; return 2; }
  _proc_state_fields "$1"
  case $? in 0) ;; 1) return 1 ;; *) _proc_state_blind "/proc/$1/stat"; return 3 ;; esac
  printf '%s\n' "${_PS_F[19]}"
}

proc_running() {
  local pid="${1:-}" start="${2:-}" rc
  _proc_state_posint "${pid}" || { _proc_state_bad pid "${pid}"; return 2; }
  if [ -n "${start}" ]; then _proc_state_posint "${start}" || { _proc_state_bad "start time" "${start}"; return 2; }; fi
  _proc_state_fields "${pid}"; rc=$?
  if [ "${rc}" -eq 3 ]; then _proc_state_blind "/proc/${pid}/stat"; return 3; fi
  [ "${rc}" -eq 0 ] || return 1
  case "${_PS_F[0]}" in Z|X|x) return 1 ;; esac
  [ -z "${start}" ] || [ "${_PS_F[19]}" = "${start}" ] || return 1
  return 0
}

proc_wait_gone() {
  local pid="${1:-}" max="${2:-}" start="${3:-}" i=0 rc
  _proc_state_posint "${max}" || { _proc_state_bad bound "${max}"; return 2; }
  while :; do
    proc_running "${pid}" ${start:+"${start}"}; rc=$?
    case "${rc}" in 0) ;; 1) return 0 ;; *) return "${rc}" ;; esac
    [ "${i}" -ge "${max}" ] && return 1
    sleep 0.1; i=$((i+1))
  done
}

proc_group_running() {
  local pgid="${1:-}" f p
  _proc_state_posint "${pgid}" || { _proc_state_bad pgid "${pgid}"; return 2; }
  [ -r /proc/self/stat ] || { _proc_state_blind /proc; return 3; }
  for f in /proc/[0-9]*/stat; do
    p="${f#/proc/}"; p="${p%/stat}"
    # Gone between the glob and the read (1), or unreadable (3): /proc/<pid>/stat
    # is world-readable, so 3 is never a member of a group this suite made.
    _proc_state_fields "${p}" || continue
    [ "${_PS_F[2]}" = "${pgid}" ] || continue
    case "${_PS_F[0]}" in Z|X|x) ;; *) return 0 ;; esac
  done
  return 1
}

proc_group_wait_gone() {
  local pgid="${1:-}" max="${2:-}" i=0 rc
  _proc_state_posint "${max}" || { _proc_state_bad bound "${max}"; return 2; }
  while :; do
    proc_group_running "${pgid}"; rc=$?
    case "${rc}" in 0) ;; 1) return 0 ;; *) return "${rc}" ;; esac
    [ "${i}" -ge "${max}" ] && return 1
    sleep 0.1; i=$((i+1))
  done
}
