#!/usr/bin/env bash
# resume-domain.sh -- DOMAIN: pure. The run-ownership markers of the drain /
# resume hand-off (DND-443; athena:fleet-drain -> *Resume*). Nothing here reads
# a file or the environment.
#
# THE JOINT INVARIANT these markers carry: at most one admiral owns a run at any
# time. Ownership changes hands ONLY by a marker line appended by
# ai/bin/fleet-resume under the run's state-log lock:
#   DRAINED  -- the owning admiral finished its drain and owns nothing (or a
#               claim was released because the resume spawn did not happen);
#   RESUMED  -- the top-level session CLAIMED the run, before it spawns the
#               resuming admiral.
# A run is resumable exactly when the LAST marker for the session is DRAINED.
#
# The line format is pinned here and nowhere else, and it is written only by
# fleet-resume: `<KIND> session=<id> run=<run-id> at=<ISO 8601 UTC>`, alone on
# its line. A line that LOOKS like a marker but is not exactly that is an error,
# never skipped: a skipped marker would be a run silently never resumed, or
# resumed twice.
#
# Source order: domain.sh, then this file.

FLEET_MARKER_RE='^(DRAINED|RESUMED) session=([A-Za-z0-9][A-Za-z0-9._-]{0,127}) run=([A-Za-z0-9][A-Za-z0-9._-]{0,127}) at=([0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z)$'

# Anything mentioning a marker word next to `session=` is a marker candidate.
# The loose pattern is what makes a hand-written or reformatted marker LOUD.
FLEET_MARKER_CANDIDATE_RE='(DRAINED|RESUMED)[^A-Za-z0-9]+session='

# fleet_marker_line <DRAINED|RESUMED> <session_id> <run_id> <iso>
fleet_marker_line() {
  printf '%s session=%s run=%s at=%s\n' "$1" "$2" "$3" "$4"
}

# fleet_marker_last <session_id> <run_id> <candidate-lines>
# Judges one state log's marker candidates (every line matching
# FLEET_MARKER_CANDIDATE_RE, in file order). Prints the LAST marker kind for
# this session -- DRAINED, RESUMED, or none -- and returns 0. Returns 1 and
# prints the first problem when a candidate is not a well-formed marker, or
# names another run (a marker copied from another state log).
fleet_marker_last() {
  local sid="$1" run="$2" lines="$3" line last="none" n=0
  local LC_ALL=C
  while IFS= read -r line; do
    [ -n "${line}" ] || continue
    n=$((n + 1))
    if ! [[ "${line}" =~ ${FLEET_MARKER_RE} ]]; then
      printf 'marker candidate #%s is not exactly `<KIND> session=<id> run=<run-id> at=<ISO>` alone on its line: %s\n' "${n}" "${line@Q}"
      return 1
    fi
    if [ "${BASH_REMATCH[3]}" != "${run}" ]; then
      printf 'marker #%s names run %s, but it is in run %s'"'"'s state log: %s\n' "${n}" "${BASH_REMATCH[3]}" "${run}" "${line@Q}"
      return 1
    fi
    [ "${BASH_REMATCH[2]}" = "${sid}" ] && last="${BASH_REMATCH[1]}"
  done <<<"${lines}"
  printf '%s\n' "${last}"
}
