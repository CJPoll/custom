# shellcheck shell=bash
#
# glab-landing.sh -- the merge.landed record for an MR merge glab-athena ran
# (DND-1939). Sourced by ai/bin/glab-athena, never run.
#
# Why: on GitHub, locked-merge records a PR merge (via=pr) and the shared git
# passthrough records a push to main (via=push). A GitLab MR merge recorded
# nothing. This record is the GitLab counterpart of locked-merge's via=pr
# event: a point event at confirmation. What it feeds in the lead-time phase
# ledger (ai/lib/lead_time_phases.rb): the landing's merge.landed (unit and
# head evidence, so a landing worked here reads "local"). It is NOT a landing
# start: land_start takes a merge.lock_wait or a timed via=push event only,
# and a GitLab MR's merge phase starts from the merge.lock_wait that
# locked-merge's GitLab path writes (DND-1943). The landing time itself comes
# from the forge (ai/bin/lead-time; DND-1952).
#
# What: after glab ran an `mr merge` / `mr accept` that the merge guard let
# through (glmg_mr_merge sets GLMG_LAND_*; nothing else does), ask
# confirm-merged whether the MR landed. GitLab can answer before the merge is
# real (confirm-merged's header), so the record waits for that, never for
# glab's exit code: up to GLL_TRIES reads, GLL_SLEEP seconds apart, when glab
# exited 0, and one read when it did not (a failed call can still have landed,
# DND-1324). Every forge read is capped at GLL_READ_S seconds. Then the MR is
# read again by project id, the key the guard judged, so a checkout whose
# remote resolves to another project cannot lend its MR's state, and the
# project is read for its default branch: merge.landed is a landing on the
# default branch, so an MR into any other branch (a stacked MR into its
# parent) records nothing and says so. A merged MR into the default branch is
# one point event at confirmation, run from the checkout the guard matched to
# the MR's project (its repo key):
#   via=mr, mr=<iid>, before=<the target tip the guard read before the merge>,
#   after=<merge_commit_sha, else squash_commit_sha, else the head only when
#   the project's merge_method is ff; otherwise a miss>, head=<the MR head>,
#   unit from the MR's source branch.
#
# Every outcome but a recorded landing and a clean "not merged" after a
# failed glab call is said on stderr: a miss (not confirmed, could not look,
# no landed commit) with a Fix: to record it by hand, a skip (not the default
# branch) with the branch named. "Not merged" and "could not look"
# (confirm-merged exit 1 vs 3) read differently.
#
# Fails open: glab's exit code and stdout are what the caller sees; the emit
# goes through ai/lib/telemetry-emit.sh with the bot token unset.
#
# Residuals, said out loud:
#   * Merge-train boarding (`api -X POST …/merge_trains/merge_requests/<iid>`)
#     records nothing: the car merges after a train pipeline, long after the
#     wrapper exits. The personal namespace (gitlab.com Free) has no trains.
#   * An `mr merge` that joins a train, or a forge slower than the tries, is a
#     miss (said, with the Fix: to record it by hand).
#   * `before` is the target tip the guard read, not read again at the merge:
#     a branch that moved in between is not seen (for a merge commit, after^1
#     is exact).
#   * One event per merge glab-athena ran. A caller that wraps glab-athena's
#     merge gets this event and must not write a second merge.landed for the
#     same merge. locked-merge's GitLab path (DND-1943) writes only
#     merge.lock_wait (its telemetry section), and its GitLab suite asserts
#     it writes no merge.landed. Nothing here enforces it for other callers.
#   * Cost: the record runs inside the caller's wait, so under locked-merge
#     it runs while the merge lock is held. Worst case, a slow forge adds
#     GLL_TRIES reads of up to GLL_READ_S seconds each plus the sleeps
#     between them, about 4 minutes, before locked-merge's own confirm.

GLL_TRIES=6
GLL_SLEEP=10
GLL_READ_S=30

# gll_read <cmd...> : one forge read, capped at GLL_READ_S, quiet, no stdin.
gll_read() { timeout -k 2 "$GLL_READ_S" "$@" </dev/null; }

# gll_miss <why> [<source branch>] : say that no landing was recorded, and how
# to record it so the hand record matches the automatic one.
gll_miss() {
  local src="${2:-<the MR source branch>}" before=""
  [[ "$GLMG_LAND_BEFORE" =~ ^[0-9a-f]{40}$ ]] && before=" --attr before=$GLMG_LAND_BEFORE"
  printf '%s: no merge.landed recorded for !%s: %s.\n  Fix: once `~/dev/custom/ai/bin/confirm-merged --mr %s --repo %s` exits 0, record it from that checkout: `~/dev/custom/ai/bin/telemetry-emit --event merge.landed --attr via=mr --attr mr=%s --attr after=<the landed commit: merge_commit_sha, else squash_commit_sha, else sha on a fast-forward project>%s --head %s --unit-branch %s`; until then the ledger has no merge.landed for this landing.\n' \
    "${GLMG_TOOL:-glab-athena}" "$GLMG_LAND_IID" "$1" "$GLMG_LAND_IID" "$GLMG_LAND_TOP" "$GLMG_LAND_IID" "$before" \
    "${GLMG_LAND_HEAD:-<the MR head>}" "$src" >&2
  return 0
}

# gll_record_mr_landing <glab exit code> : the record, after glab ran. Never
# fails, never changes the caller's exit code or stdout.
gll_record_mr_landing() {
  local rc="$1" iid="$GLMG_LAND_IID" top="$GLMG_LAND_TOP" head="$GLMG_LAND_HEAD" before="$GLMG_LAND_BEFORE"
  local cm tries i crc=0 cwhy="" json="" proj="" state after method="" src="" target def at here
  [ -n "$iid" ] && [ -n "$top" ] || return 0
  if ! [[ "$head" =~ ^[0-9a-f]{40}$ ]] || ! [[ "$GLMG_LAND_PID" =~ ^[0-9]+$ ]] || ! [[ "$iid" =~ ^[0-9]+$ ]]; then
    gll_miss "the guard's read of the MR gave no usable head, project id or iid"
    return 0
  fi
  here="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
  cm="$here/../bin/confirm-merged"
  tries="$GLL_TRIES"; [ "$rc" -eq 0 ] || tries=1
  for ((i = 1; i <= tries; i++)); do
    crc=0; cwhy="$(gll_read "$cm" --mr "$iid" --repo "$top" 2>&1 >/dev/null)" || crc=$?
    [ "$crc" -eq 0 ] && break
    if [ "$i" -lt "$tries" ]; then sleep "$GLL_SLEEP"; fi
  done
  cwhy="$(printf '%s' "$cwhy" | head -n 1)"
  if [ "$crc" -ne 0 ]; then
    if [ "$crc" -eq 1 ]; then
      # Not merged. After a failed glab call that is no landing to miss:
      # glab's own error says why.
      [ "$rc" -eq 0 ] && gll_miss "glab exited 0, but confirm-merged did not see it merged in $tries read(s), ${GLL_SLEEP}s apart (a merge-train car, or a slow forge)"
    else
      gll_miss "COULD NOT LOOK: confirm-merged could not tell whether it merged (exit $crc after $tries read(s)${cwhy:+: $cwhy})"
    fi
    return 0
  fi
  local -a read=(api)
  [ -n "${GLMG_HOST:-}" ] && read+=(--hostname "$GLMG_HOST")
  json="$(gll_read glab "${read[@]}" "projects/$GLMG_LAND_PID/merge_requests/$iid" 2>/dev/null)" || json=""
  state="$(jq -r '.state // empty' <<<"$json" 2>/dev/null)" || state=""
  if [ "$state" != merged ]; then
    gll_miss "confirm-merged saw it merged, but the MR read by project id (\`glab ${read[*]} projects/$GLMG_LAND_PID/merge_requests/$iid\`) says state '${state:-unreadable}'"
    return 0
  fi
  src="$(jq -r '.source_branch // empty' <<<"$json" 2>/dev/null)" || src=""
  target="$(jq -r '.target_branch // empty' <<<"$json" 2>/dev/null)" || target=""
  proj="$(gll_read glab "${read[@]}" "projects/$GLMG_LAND_PID" 2>/dev/null)" || proj=""
  def="$(jq -r '.default_branch // empty' <<<"$proj" 2>/dev/null)" || def=""
  if [ -z "$def" ] || [ -z "$target" ]; then
    gll_miss "COULD NOT LOOK: the project's default branch ('${def}') or the MR's target branch ('${target}') could not be read (\`glab ${read[*]} projects/$GLMG_LAND_PID\`), so whether this merge landed on the default branch is unknown" "$src"
    return 0
  fi
  # The landed commit: the merge commit, else the squash commit. The MR head
  # itself landed only on a fast-forward project; on any other merge method a
  # missing commit is a miss, never the head.
  after="$(jq -r '.merge_commit_sha // .squash_commit_sha // empty' <<<"$json" 2>/dev/null)" || after=""
  if [ -z "$after" ]; then
    method="$(jq -r '.merge_method // empty' <<<"$proj" 2>/dev/null)" || method=""
    if [ "$method" = ff ]; then
      after="$(jq -r '.sha // empty' <<<"$json" 2>/dev/null)" || after=""
    else
      gll_miss "the merged MR names no merge_commit_sha or squash_commit_sha, and the project's merge_method '${method:-unreadable}' is not ff, so its head is not the landed commit" "$src"
      return 0
    fi
  fi
  if ! [[ "$after" =~ ^[0-9a-f]{40}$ ]]; then
    gll_miss "the merged MR names no usable landed commit ('${after}')" "$src"
    return 0
  fi
  if [ "$target" != "$def" ]; then
    printf '%s: !%s merged into %s, not the default branch %s: no merge.landed (a landing is a merge into the default branch).\n' \
      "${GLMG_TOOL:-glab-athena}" "$iid" "$target" "$def" >&2
    return 0
  fi
  (
    # The telemetry writer needs no credential.
    unset GITLAB_TOKEN
    . "$here/telemetry-emit.sh" 2>/dev/null || exit 0
    cd "$top" 2>/dev/null || exit 0
    at="$(athena_telemetry_now)"
    local -a opt=( --head "$head" )
    [ -n "$at" ] && opt+=( --at "$at" )
    [[ "$before" =~ ^[0-9a-f]{40}$ ]] && opt+=( --attr "before=$before" )
    [ -n "$src" ] && opt+=( --unit-branch "$src" )
    athena_telemetry_emit --event merge.landed --attr via=mr --attr "mr=$iid" --attr "after=$after" "${opt[@]}"
  ) || true
  return 0
}
