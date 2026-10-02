# shellcheck shell=bash
#
# proc-stat.sh -- the ONE shell rule for reading /proc/<pid>/stat (DND-1625).
# Sourced, never run.
#
# A process name (comm) may hold a newline or ") ", so a stat file is read
# WHOLE and its fields are taken after the LAST ") ". A line-by-line read
# (sed, a single `read -r`, awk per line) or a first-") " match misreads such a
# process: DND-1616 found the machine-wide scanner blinded by one. This is the
# rule ai/lib/reap_tags.rb, ai/lib/proc_state.rb (ProcState.stat_fields) and
# scripts/test/lib/proc-state.bash already follow; the shell callers share it
# here instead of each spelling it again.
#
# Callers: integration-gate (the pre-started critic's pgrp) and inbox-client-
# capture (a client's start time). test-slot's read_ppid follows the same rule
# inline, because test-slot also runs with no ai/lib beside it.
#
# Neither function forks: both read with the `read` builtin, so they can be
# called in the main shell (test-slot reads /proc/self/stat and needs /proc/self
# to be itself, not a subshell).
#
# Exit codes, kept distinct so a failed read never looks like a value:
#   0  read; the result is set/printed
#   1  could not read: no such file, unreadable, or empty (a gone process)
#   2  malformed: no ") " after the comm, a field index that is not a positive
#      integer, or a field past the end. Never guessed at.

# proc_stat_rest <stat-path> : sets PROC_STAT_REST to the stat fields after the
# LAST ") " (field 1 is the state), on one line. Empty unless it returns 0.
proc_stat_rest() {
  local s=""
  PROC_STAT_REST=""
  { IFS= read -r -d '' s <"$1"; } 2>/dev/null
  [ -n "${s}" ] || return 1
  case "${s}" in *") "*) ;; *) return 2 ;; esac
  s="${s##*) }"
  s="${s%$'\n'}"
  [ -n "${s}" ] || return 2
  case "${s}" in *$'\n'*) return 2 ;; esac
  PROC_STAT_REST="${s}"
  return 0
}

# proc_stat_field <stat-path> <n> : prints field <n> after the comm (1 = state,
# 2 = ppid, 3 = pgrp, 20 = starttime; the kernel's field number minus 2).
proc_stat_field() {
  local n="${2:-}" rc f
  case "${n}" in ''|0*|*[!0-9]*) return 2 ;; esac
  proc_stat_rest "$1"; rc=$?
  [ "${rc}" -eq 0 ] || return "${rc}"
  read -r -a f <<<"${PROC_STAT_REST}"
  [ "${#f[@]}" -ge "${n}" ] || return 2
  printf '%s\n' "${f[n-1]}"
}
