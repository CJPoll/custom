# suite-reaper.bash -- reap EVERY process a self-test started, on every exit
# path, whether or not the suite ever learned its pid. Sourced, never run.
#
# Why (DND-818). The mock-bearing suites reaped by a pid list: `cmd &` then
# `PIDS+=("$!")`, and cleanup killed the list. Two measured gaps:
#   * A signal that lands between the fork and the list append runs the trap
#     first, so cleanup never hears of the new process. A harness-gate run
#     SIGTERMed at 20:46:58Z left a ruby client born in that same second,
#     ppid 1, for 12 hours.
#   * A process the suite starts only indirectly (a supervisor's relaunched
#     client, a fake suite's mock) is learned from a ready file, or not at all.
#     When the reader misses it, and the process ignores the SIGTERM its parent
#     sends, it outlives the suite (scripts/test/suite-reaper/repro-real-suites.sh
#     reproduces both).
# A list the suite has to keep in step with every spawn cannot close either
# gap. So each suite run carries a unique TAG in its environment, every
# descendant inherits it (exec'd or forked), and cleanup kills every process of
# ours that carries the tag -- the tag, not the bookkeeping, is the proof of
# ownership. It survives reparenting, so a grandchild orphaned to PID 1 or to a
# subreaper is still found.
#
# The variable is a comma-separated LIST (ATHENA_REAP_TAGS) so a suite nested
# inside another suite, or inside harness-gate (which tags every check the same
# way), adds its own tag without hiding its processes from the outer reaper.
#
# Usage, at the very top of the suite, before anything is started:
#
#   . "<repo>/scripts/test/lib/suite-reaper.bash"
#   suite_reaper_begin "$@"      # may re-exec the suite once; see below
#
# and as the LAST process-killing step of the suite's cleanup (after its own
# graceful stops, before removing its temp dir):
#
#   suite_reap_tagged
#
# suite_reaper_begin re-execs the suite once with the tag in its environment.
# `export` alone is not enough: a forked subshell that never execs (a
# `( ... ) &` block) reports the environment its shell was EXEC'd with in
# /proc/<pid>/environ, which would not hold a tag exported later.
#
# Limits, stated: a descendant that clears its environment (`env -i`) drops the
# tag, and SIGKILL of the suite itself runs no cleanup at all (harness-gate's
# per-check sweep and ai/bin/check-inbox-mock-orphans are the backstops there).

# suite_reaper_begin "$@" -- tag this suite run; re-exec once so the tag is in
# the suite's own exec environment. Returns only in the re-exec'd suite.
suite_reaper_begin() {
  if [ "${ATHENA_SUITE_REAPER_PID:-}" != "$$" ]; then
    local uuid
    uuid="$(cat /proc/sys/kernel/random/uuid 2>/dev/null)" || uuid=""
    if [ -z "${uuid}" ]; then
      echo "suite-reaper: cannot read /proc/sys/kernel/random/uuid; this suite cannot tag its processes." >&2
      echo "  Fix: run on Linux with /proc mounted; the reaper finds processes through /proc/<pid>/environ." >&2
      exit 2
    fi
    export ATHENA_SUITE_REAPER_PID="$$"
    export ATHENA_SUITE_REAPER_TAG="athena-reap:suite-${uuid}"
    export ATHENA_REAP_TAGS="${ATHENA_REAP_TAGS:+${ATHENA_REAP_TAGS},}${ATHENA_SUITE_REAPER_TAG}"
    exec "${BASH}" "$0" "$@"
  fi
  # A child suite inherits ATHENA_SUITE_REAPER_PID (a different pid), so it
  # takes the branch above and appends a tag of its own.
}

# suite_tagged_pids -- pids of ours, other than this shell, whose environment
# carries this run's tag. One grep over every environ file; unreadable ones
# (other users, processes gone mid-scan) are skipped silently by -s. The scan
# itself runs tagged (the grep and its subshell inherit the tag), so the list
# is taken whole first and each pid is then re-checked ALIVE and STILL tagged:
# the scanners have exited by then and drop out, and nothing else is signalled.
suite_tagged_pids() {
  local scan p
  [ -n "${ATHENA_SUITE_REAPER_TAG:-}" ] || return 1
  scan="$(grep -lsFz -- "${ATHENA_SUITE_REAPER_TAG}" /proc/[0-9]*/environ 2>/dev/null)"
  for p in ${scan}; do
    p="${p#/proc/}"; p="${p%/environ}"
    case "${p}" in ''|*[!0-9]*) continue ;; esac
    [ "${p}" = "$$" ] && continue
    [ "${p}" = "${BASHPID}" ] && continue   # this function's own $(...) subshell
    [ -O "/proc/${p}" ] || continue
    grep -qsFz -- "${ATHENA_SUITE_REAPER_TAG}" "/proc/${p}/environ" || continue
    printf '%s\n' "${p}"
  done
}

# suite_reap_tagged -- SIGKILL every tagged process until none is left
# (bounded: a process mid-fork is caught on the next pass). Each one it had to
# kill is named on stderr, so a leak the suite's own cleanup missed is visible
# rather than silently tidied. Status 0 when none remain, 1 when the bound ran
# out with some still alive (named, with a Fix:).
suite_reap_tagged() {
  local pass p pids left=""
  if [ -z "${ATHENA_SUITE_REAPER_TAG:-}" ]; then
    echo "suite-reaper: suite_reap_tagged called without suite_reaper_begin; nothing was tagged, so nothing can be reaped." >&2
    echo "  Fix: call suite_reaper_begin \"\$@\" at the top of the suite, before it starts any process." >&2
    return 1
  fi
  for pass in 1 2 3 4 5 6 7 8 9 10; do
    pids="$(suite_tagged_pids)"
    [ -z "${pids}" ] && return 0
    for p in ${pids}; do
      [ "${pass}" = 1 ] && printf 'suite-reaper: killing pid %s that outlived this suite'"'"'s own cleanup: %s\n' \
        "${p}" "$(tr '\0' ' ' <"/proc/${p}/cmdline" 2>/dev/null)" >&2
      kill -9 "${p}" 2>/dev/null
    done
    left="${pids}"
    sleep 0.1
  done
  pids="$(suite_tagged_pids)"
  [ -z "${pids}" ] && return 0
  echo "suite-reaper: FAILED -- still alive after 10 kill passes: ${pids//$'\n'/ } (last seen: ${left//$'\n'/ })" >&2
  echo "  Fix: something keeps forking new tagged processes; find which from the pids above and stop it at its source." >&2
  return 1
}
