#!/usr/bin/env bash
# resume-manager.sh -- MANAGER of the drain/resume hand-off (DND-443). Every
# change of a run's owner goes through here, under the run's state-log lock
# (resume-effects.sh), judged by resume-domain.sh. Framework (bin/fleet-resume)
# calls only this file and the domain files.
#
# Exit statuses (shared with bin/fleet-resume):
#   0 ok   1 local problem (no state log, unreadable, lock timeout)
#   4 a marker candidate is malformed, so the run cannot be judged
#
# Source order: domain.sh, resume-domain.sh, resume-effects.sh, then this file.

# fleet_resume_step <state.md> <session_id> <run_id> <drained|claim|status>
# Runs UNDER the lock. Reads the markers, decides, and appends at most one.
# Status: 0 done; 10 claim found nothing to claim; 4 malformed; 1 unreadable.
fleet_resume_step() {
  local f="$1" sid="$2" run="$3" mode="$4" lines last now
  lines="$(fleet_marker_candidates "${f}")" || { printf 'cannot read %s\n' "${f}"; return 1; }
  last="$(fleet_marker_last "${sid}" "${run}" "${lines}")" || { printf '%s: %s\n' "${f}" "${last}"; return 4; }
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  case "${mode}" in
    status) printf '%s\n' "${last}" ;;
    drained)
      if [ "${last}" = "DRAINED" ]; then
        printf 'already DRAINED\n'
      else
        fleet_append_marker "${f}" "$(fleet_marker_line DRAINED "${sid}" "${run}" "${now}")" || { printf 'cannot append to %s\n' "${f}"; return 1; }
        printf 'DRAINED\n'
      fi ;;
    claim)
      [ "${last}" = "DRAINED" ] || return 10
      fleet_append_marker "${f}" "$(fleet_marker_line RESUMED "${sid}" "${run}" "${now}")" || { printf 'cannot append to %s\n' "${f}"; return 1; }
      printf 'CLAIMED\n' ;;
  esac
  return 0
}

# fleet_resume_one <root> <session_id> <run_id> <drained|status>
# The single-run subcommands. The state log must exist.
fleet_resume_one() {
  local root="$1" sid="$2" run="$3" mode="$4" f out rc=0
  f="${root}/${run}/state.md"
  if [ ! -f "${f}" ]; then
    printf 'fleet-resume: %s: no state log at %s. Fix: pass the run-id of a run whose admiral wrote a state log (the coordination directory name).\n' "${mode}" "${f}" >&2
    return 1
  fi
  out="$(fleet_locked "${f}" fleet_resume_step "${f}" "${sid}" "${run}" "${mode}")" || rc=$?
  case "${rc}" in
    0)  printf 'fleet-resume: %s run=%s session=%s: %s\n' "${mode}" "${run}" "${sid}" "${out}" ;;
    4)  printf 'fleet-resume: %s refused: %s. Fix: markers are written only by ai/bin/fleet-resume; repair or remove the hand-edited line, then retry. A run that cannot be judged is never resumed or marked.\n' "${mode}" "${out}" >&2 ;;
    70) printf 'fleet-resume: %s: could not lock %s within 10 s. Fix: another fleet-resume holds it; retry.\n' "${mode}" "${f}.resume.lock" >&2; rc=1 ;;
    *)  printf 'fleet-resume: %s failed: %s. Fix: check the state log is readable and writable.\n' "${mode}" "${out}" >&2; rc=1 ;;
  esac
  return "${rc}"
}

# fleet_resume_claim <root> <session_id>
# Claims EVERY run of this session whose last marker is DRAINED, each under its
# own lock, and prints `CLAIMED run=<run-id>` per claim, then one summary line
# naming how many state logs were considered. A malformed state log is named
# on stderr and skipped (never claimed); the exit is then 4.
fleet_resume_claim() {
  local root="$1" sid="$2" f run out rc worst=0 n=0 claimed=0 bad=0
  if [ ! -d "${root}" ]; then
    printf 'fleet-resume: claim: the coordination root %s does not exist. Fix: pass --root, or run from the harness checkout; a missing root is never read as "nothing drained".\n' "${root}" >&2
    return 1
  fi
  while IFS= read -r f; do
    [ -n "${f}" ] || continue
    n=$((n + 1))
    run="$(basename -- "$(dirname -- "${f}")")"
    fleet_valid_id "${run}" || continue
    rc=0
    out="$(fleet_locked "${f}" fleet_resume_step "${f}" "${sid}" "${run}" claim)" || rc=$?
    case "${rc}" in
      0)  printf 'CLAIMED run=%s state=%s\n' "${run}" "${f}"; claimed=$((claimed + 1)) ;;
      10) ;;
      4)  printf 'fleet-resume: claim skipped %s: %s. Fix: markers are written only by ai/bin/fleet-resume; repair the line, then claim again.\n' "${run}" "${out}" >&2; bad=$((bad + 1)); worst=4 ;;
      *)  printf 'fleet-resume: claim could not judge %s (status %s): %s. Fix: check the state log and its lock; claim again.\n' "${run}" "${rc}" "${out}" >&2; bad=$((bad + 1)); [ "${worst}" -eq 0 ] && worst=1 ;;
    esac
  done < <(fleet_state_logs "${root}")
  printf 'fleet-resume: claim for session %s: considered %s state log(s) under %s; claimed %s; could not judge %s\n' "${sid}" "${n}" "${root}" "${claimed}" "${bad}"
  return "${worst}"
}
