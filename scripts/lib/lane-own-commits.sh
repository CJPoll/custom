#!/usr/bin/env bash
# Sourced by scripts/athena-leadtime-run.sh and scripts/athena-shipwright-run.sh
# (DND-1507, DND-1541). Definition-only: no side effects on load.
#
# The question both runners ask after a session: which commits did THIS run
# make? A lane that moved off its base is not evidence of its own work. A sync
# down (athena:shipwright-lane) fast-forwards or rebases the lane onto other
# fleets' commits, so "tip != base" credits the run with them and can
# fast-forward the main checkout on their behalf.
#
# lane_own_commits <lane> <base> <tip>
#   Prints the run's own commits still on the lane, newest first. A commit is the
#   run's own when the lane's HEAD reflog records it being MADE there (a commit,
#   cherry-pick, revert, rebase pick, am, or a merge that made a commit) and it
#   is still in <base>..<tip>. A sync, reset or checkout only moves HEAD, so it
#   never credits a commit.
#   Exit codes, so a failed lookup never reads as "no own commits":
#     0  answered (stdout empty = the run made none)
#     1  no readable HEAD reflog
#     2  the reflog does not start at <base>
#     3  git rev-list <base>..<tip> failed
#
# The sequencer's step label is the stable part of a rebase entry; the action
# before it is the caller's argv ("rebase", "pull -q --rebase https://... main"),
# which may itself hold a colon. A cherry-pick --ff that only moved HEAD
# ("cherry-pick: fast-forward") made nothing (OWN_MOVED_ONLY).
OWN_MADE='^(commit|cherry-pick|revert|am)( \([a-z]+\))?: |^(rebase|pull)( [^(]*)? \((pick|reword|edit|squash|fixup|continue|merge)\): |: Merge made by '
OWN_MOVED_ONLY=': fast-forward$'
lane_own_commits() {
  local lane="$1" base="$2" tip="$3" reflog first made log_path range
  # With no HEAD reflog git silently shows the branch's reflog instead, which
  # records a rebase only as its finish and so would under-credit: require the
  # file itself.
  log_path="$(git -C "${lane}" rev-parse --git-path logs/HEAD 2>/dev/null)" || return 1
  case "${log_path}" in /*) ;; *) log_path="${lane}/${log_path}" ;; esac
  [ -s "${log_path}" ] || return 1
  reflog="$(git -C "${lane}" reflog show --format='%H %gs' HEAD -- 2>/dev/null)" || return 1
  [ -n "${reflog}" ] || return 1
  first="$(printf '%s\n' "${reflog}" | tail -n1 | cut -d' ' -f1)"
  [ "${first}" = "${base}" ] || return 2
  made="$(printf '%s\n' "${reflog}" | while read -r sha gs; do
            if grep -q -E -- "${OWN_MADE}" <<<"${gs}" && ! grep -q -E -- "${OWN_MOVED_ONLY}" <<<"${gs}"; then
              printf '%s\n' "${sha}"
            fi
          done | sort -u)"
  [ -n "${made}" ] || return 0
  # Capture the range first: a failed rev-list must not read as "no own commits".
  range="$(git -C "${lane}" rev-list --topo-order "${base}..${tip}" 2>/dev/null)" || return 3
  [ -n "${range}" ] || return 0
  printf '%s\n' "${range}" | grep -F -x -f <(printf '%s\n' "${made}") || true
}
