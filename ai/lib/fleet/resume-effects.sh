#!/usr/bin/env bash
# resume-effects.sh -- SIDE EFFECTS of the drain/resume hand-off (DND-443): the
# coordination directory, the state logs' marker lines, and the per-state-log
# lock that makes "read the last marker, then append one" a single step.
#
# Source order: domain.sh, resume-domain.sh, then this file.

# fleet_coordination_root <harness-dir>
# <main checkout>/ai-artifacts/coordination, resolved through the git common
# dir so a worktree resolves to the MAIN checkout's runs (where every admiral
# writes its state log). Status 2 when git cannot say.
fleet_coordination_root() {
  local common
  common="$(git -C "$1" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || return 2
  common="$(realpath -q -- "${common}")" || return 2
  case "${common}" in /*/.git) ;; *) return 2 ;; esac
  printf '%s/ai-artifacts/coordination\n' "${common%/.git}"
}

# fleet_state_logs <root> -- every <root>/<run-id>/state.md, sorted.
fleet_state_logs() {
  find "$1" -mindepth 2 -maxdepth 2 -type f -name state.md 2>/dev/null | LC_ALL=C sort
}

# fleet_marker_candidates <state.md>
# Every line that looks like a marker, in file order. Status 0 with none; 2
# when the file cannot be read (never read as "no markers").
fleet_marker_candidates() {
  local rc=0 out
  out="$(grep -E -- "${FLEET_MARKER_CANDIDATE_RE}" "$1" 2>/dev/null)" || rc=$?
  [ "${rc}" -le 1 ] || return 2
  printf '%s' "${out}"
}

# fleet_append_marker <state.md> <line>
# Appends the line on its own line (a newline first when the file does not end
# with one, so the marker never glues onto a narrative line).
fleet_append_marker() {
  local f="$1"
  if [ -s "${f}" ] && [ -n "$(tail -c 1 -- "${f}")" ]; then
    printf '\n' >> "${f}" || return 1
  fi
  printf '%s\n' "$2" >> "${f}"
}

# fleet_locked <state.md> <command...>
# Runs the command (a shell function is fine) holding an exclusive flock on
# <state.md>.resume.lock, so two resumers cannot both read "last = DRAINED"
# before either appends. Status 70 when the lock cannot be taken in 10 s.
fleet_locked() {
  local f="$1"
  shift
  (
    exec 7>>"${f}.resume.lock" || exit 70
    flock -w 10 7 || exit 70
    "$@"
  )
}
