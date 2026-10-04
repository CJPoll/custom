# shellcheck shell=bash
#
# glab-landing.sh -- the merge.landed record for an MR merge glab-athena ran
# (DND-1939). Sourced by ai/bin/glab-athena, never run.
#
# Why: the lead-time ledger times a landing from merge.landed. On GitHub a PR
# merge records it in locked-merge (via=pr) and a push to main in the shared
# git passthrough (via=push). A GitLab MR merge recorded nothing, so after the
# move to GitLab the merge phase would read could-not-measure.
#
# What: after glab ran an `mr merge` / `mr accept` that the merge guard let
# through (glmg_mr_merge sets GLMG_LAND_*; nothing else does), ask
# confirm-merged whether the MR landed. GitLab can answer before the merge is
# real (confirm-merged's header), so the record waits for that, never for
# glab's exit code: up to GLL_TRIES reads, GLL_SLEEP seconds apart, when glab
# exited 0, and one read when it did not (a failed call can still have landed,
# DND-1324). Then the MR is read again by project id, the key the guard
# judged, so a checkout whose remote resolves to another project cannot lend
# its MR's state. Merged there too: one point event at confirmation, run from
# the checkout the guard matched to the MR's project (its repo key):
#   via=mr, mr=<iid>, before=<the target tip the guard judged the receipt on>,
#   after=<merge_commit_sha, else squash_commit_sha, else the head (a
#   fast-forward)>, head=<the MR head>, unit from the MR's source branch.
# That mirrors locked-merge's via=pr event. A merge that is not confirmed, or
# whose landed commit cannot be read, is no event and says so on stderr with
# a Fix: (a miss is never silent).
#
# Fails open: glab's exit code and stdout are what the caller sees; the reads
# are bounded by GLL_TRIES; the emit goes through ai/lib/telemetry-emit.sh with
# the bot token unset.
#
# Residuals, said out loud:
#   * Merge-train boarding (`api -X POST …/merge_trains/merge_requests/<iid>`)
#     records nothing: the car merges after a train pipeline, long after the
#     wrapper exits. The personal namespace (gitlab.com Free) has no trains.
#   * An `mr merge` that joins a train, or a forge slower than the tries, is a
#     miss (said, with the Fix: to record it by hand).
#   * One event per merge glab-athena ran. A caller that wraps glab-athena's
#     merge (locked-merge's GitLab path, DND-1943) gets this event and must
#     not write a second merge.landed for the same merge.

GLL_TRIES=6
GLL_SLEEP=10

# gll_miss <why> : say that no landing was recorded, and how to record it.
gll_miss() {
  printf '%s: no merge.landed recorded for !%s: %s.\n  Fix: once `~/dev/custom/ai/bin/confirm-merged --mr %s --repo %s` exits 0, record it from that checkout: `~/dev/custom/ai/bin/telemetry-emit --event merge.landed --attr via=mr --attr mr=%s --attr after=<the MR'"'"'s landed commit> --head %s`; until then the ledger reads this landing from the forge alone.\n' \
    "${GLMG_TOOL:-glab-athena}" "$GLMG_LAND_IID" "$1" "$GLMG_LAND_IID" "$GLMG_LAND_TOP" "$GLMG_LAND_IID" "${GLMG_LAND_HEAD:-<the MR head>}" >&2
  return 0
}

# gll_record_mr_landing <glab exit code> : the record, after glab ran. Never
# fails, never changes the caller's exit code or stdout.
gll_record_mr_landing() {
  local rc="$1" iid="$GLMG_LAND_IID" top="$GLMG_LAND_TOP" head="$GLMG_LAND_HEAD" before="$GLMG_LAND_BEFORE"
  local cm tries i confirmed=0 json="" state after src at here
  [ -n "$iid" ] && [ -n "$top" ] || return 0
  if ! [[ "$head" =~ ^[0-9a-f]{40}$ ]] || ! [[ "$GLMG_LAND_PID" =~ ^[0-9]+$ ]] || ! [[ "$iid" =~ ^[0-9]+$ ]]; then
    gll_miss "the guard's read of the MR gave no usable head, project id or iid"
    return 0
  fi
  here="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
  cm="$here/../bin/confirm-merged"
  tries="$GLL_TRIES"; [ "$rc" -eq 0 ] || tries=1
  for ((i = 1; i <= tries; i++)); do
    if "$cm" --mr "$iid" --repo "$top" >/dev/null 2>&1 </dev/null; then confirmed=1; break; fi
    if [ "$i" -lt "$tries" ]; then sleep "$GLL_SLEEP"; fi
  done
  if [ "$confirmed" != 1 ]; then
    # A call glab itself failed, and that did not land: glab's own error says
    # why, and there is no landing to miss.
    if [ "$rc" -eq 0 ]; then
      gll_miss "glab exited 0, but confirm-merged did not see it merged in $tries read(s), ${GLL_SLEEP}s apart (a merge-train car, or a slow forge)"
    fi
    return 0
  fi
  local -a read=(api)
  [ -n "${GLMG_HOST:-}" ] && read+=(--hostname "$GLMG_HOST")
  read+=("projects/$GLMG_LAND_PID/merge_requests/$iid")
  json="$(glab "${read[@]}" 2>/dev/null </dev/null)" || json=""
  state="$(jq -r '.state // empty' <<<"$json" 2>/dev/null)" || state=""
  if [ "$state" != merged ]; then
    gll_miss "confirm-merged saw it merged, but the MR read by project id (\`glab ${read[*]}\`) says state '${state:-unreadable}'"
    return 0
  fi
  after="$(jq -r '.merge_commit_sha // .squash_commit_sha // .sha // empty' <<<"$json" 2>/dev/null)" || after=""
  if ! [[ "$after" =~ ^[0-9a-f]{40}$ ]]; then
    gll_miss "the merged MR names no landed commit (merge_commit_sha, squash_commit_sha and sha are all unusable: '${after}')"
    return 0
  fi
  src="$(jq -r '.source_branch // empty' <<<"$json" 2>/dev/null)" || src=""
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
