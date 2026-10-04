# shellcheck shell=bash
#
# glab-merge-guard.sh — the merge guard behind `glab-athena` (DND-742). Sourced,
# never run. The GitLab counterpart of ai/lib/gh-merge-guard.sh (DND-609,
# DND-728).
#
# The defect: glab-athena ran every command as-is. `glab-athena mr merge` with no
# --sha, or with the head pipeline still running or failed, went straight to
# GitLab, and so did a `glab-athena api` merge (REST PUT …/merge, a merge-train
# POST, GraphQL mergeRequestAccept). On a project whose settings gate merges on
# CI, GitLab stops some of that; on one that does not, nothing did. And no
# setting pins the head a merge was checked on.
#
# Measured 2026-09-26 (read-only, as athena-amby), the work GitLab project:
# only_allow_merge_if_pipeline_succeeds=true, merge_trains_enabled=true,
# merge_trains_skip_train_allowed=false, allow_merge_on_skipped_pipeline=false.
# So on walt_ui GitLab itself refuses a merge whose pipeline has not passed, and
# a train car merges only on a green train pipeline. This guard is the floor
# that fires on EVERY project, and the one thing no project setting does: it
# pins the reviewed head.
#
# THE ONE RULE, for every merge path this lets through: the call pins the MR's
# exact head SHA, and the MR's head pipeline on that head PASSED.
#   * `mr merge` / `mr accept` (any flags: --auto-merge, --when-pipeline-succeeds,
#     --squash, --rebase, …) is REFUSED unless `--sha <sha>` is given, <sha> IS
#     the MR's head, and the head pipeline passed on it (see glmg_check_head).
#     --auto-merge does not relax this: with a passed pipeline there is nothing
#     left to wait for, so it merges (or joins the train) at once.
#   * MERGE-TRAIN BOARDING — `glab-athena api -X POST
#     projects/<p>/merge_trains/merge_requests/<iid> -f sha=<sha>` — is the
#     guarded path the athena:merge-boarding flow already uses; it now needs the
#     `sha` field, and the same head check. The train then re-tests the
#     integrated result before the car merges. GET/HEAD (read a car) and DELETE
#     (take a car off the train) pass. Any other method on a car is refused.
#   * REST PUT projects/<p>/merge_requests/<iid>/merge (any non-GET method, or a
#     method override) is REFUSED outright: `mr merge --sha` is its guarded form.
#   * GraphQL mergeRequestAccept is REFUSED outright, wherever the query comes
#     from. It is the only mutation in GitLab's schema that merges or schedules
#     a merge (introspected 2026-09-26: its strategies are MERGE_TRAIN,
#     ADD_TO_MERGE_TRAIN_WHEN_CHECKS_PASS, MERGE_WHEN_CHECKS_PASS).
#     mergeTrainsDeleteCar removes a car and passes.
#   * `glab mcp serve` is REFUSED: it runs an MCP server whose tools include
#     merging an MR, with no guard in the way.
#   * `--auto-merge` on any command but `mr merge` (e.g. `mr create
#     --auto-merge`) is REFUSED: it schedules a merge with no pin.
#
# AND integration-gate passed that head (DND-1845, glmg_receipt_gate). Both
# paths it lets through (`mr merge`/`mr accept --sha`, train boarding) read
# integration-gate's sealed receipt for exactly the MR's head, never a
# merged-results or train commit, recorded against the target branch's tip or
# an ancestor of it (DND-1463). The reader is ai/lib/integration-receipt.sh's
# ir_read_receipt, the one gh-athena and locked-merge use. Before this, an MR
# integration-gate held at exit 4 (no receipt) could be merged or boarded
# here; the owner-approval hold failed open on GitLab. Unlike gh-merge-guard,
# the check does not ask whether the project's main DECLARES a gate: the
# GitLab project this guards declares none at its root, its gate runs take a
# caller-supplied --gate, and a declaration-keyed check would never fire. So
# every project merged through glab-athena needs a receipt. The receipt lives
# in the git common dir, so the merge runs from a checkout of the MR's project
# (matched on the MR's web_url against `git remote -v`); anywhere else is
# COULD NOT LOOK and refused. An owner-approved exit 4 writes a pass receipt
# that records the approval, so it passes. A head re-pushed after a gate needs
# its own receipt; the refusal names the earlier gated head when the MR's
# diff versions show one. Non-merge writes (labels, notes, approvals, job
# plays) read nothing and need no receipt.
#
# How "the head pipeline passed on the head" is decided (glmg_check_head). The
# MR's head_pipeline must have status `success`, and be tied to the head one of
# two ways:
#   * its sha IS the head (a branch or detached MR pipeline); or
#   * its ref is refs/merge-requests/<iid>/merge (a merged-results pipeline) and
#     its commit has exactly two parents, the second being the head. Measured on
#     work-repo MRs (ids not recorded here): the open MR's head pipeline is this kind, its sha is
#     the merge commit, and parent_ids = [target, head].
# A merge-train pipeline (refs/merge-requests/<iid>/train) is not tied: its
# second parent is a squash commit, not the head. It is refused, with a Fix to
# run a fresh MR pipeline. Anything else is refused too.
#
# Everything the guard cannot establish — an MR it cannot read, a pipeline it
# cannot tie, an argv it cannot parse the way glab does, a GraphQL body it
# cannot read, its own scratch file failing — is REFUSED, never passed.
#
# Aliases: glab-athena runs glab with a fresh, empty config dir on every call
# (ai/lib/forge-cli-isolation.sh), so the only aliases glab knows are its two
# defaults, `ci` and `co`, and neither merges. An alias set through the wrapper
# dies with its call. So, unlike gh-merge-guard, there is no alias expansion.
# Cobra accepts flags before the subcommand (`glab --repo g/r mr merge 5`,
# measured), so the command is read from the positional words, not argv[0].
# But cobra finds those words with its own walk, not any command's flag table:
# `glab mr -ym merge 4242` routes to merge (measured, glab 1.112) and then
# merges the current branch's MR with -m 4242 as the message. So before the
# command path, only -R/--repo is allowed when any word could be a merge (see
# glmg_prepath_flag). glab also dispatches `glab -R g/r api …` to api
# (measured), so `api` must be the first word; anything before it is refused.
# `mr merge --help` gets no short-circuit: pflag lets a later `--help=false`
# turn help off again.
#
# `--auto-merge` anywhere outside `mr merge` is refused: `glab mr create
# --auto-merge` (glab 1.112) sets the new MR to merge when its checks pass, on a
# head nobody pinned. A full `--help` walk of glab 1.112's command tree (three
# levels) found no other subcommand flag that merges or schedules a merge;
# `mr update` has none. `mr create --recover` reloads options from a file in
# glab's config dir, which glab-athena makes fresh and empty on every call.
#
# Residual (NOT checked; each still runs):
#   * API writes that move a ref without merging: REST POST
#     …/repository/commits, …/repository/branches, PUT/POST …/repository/files,
#     GraphQL commitCreate / createBranch (the GitLab side of DND-741), and a
#     `glab-athena git push` to the default branch. On walt_ui the default
#     branch's protection is GitLab's own gate for those.
#   * A pipeline that has not been CREATED yet for the head: head_pipeline is
#     then an older one, whose sha is not the head, so it is refused. A head
#     pipeline that passed while a later, still-running pipeline exists for the
#     same head is not seen.
#   * A merge mutation or route GitLab adds after 2026-09-26.
#   * The receipt check's own residuals are integration-receipt.sh's: the
#     sealer is an oracle to any same-uid process (OPEN, DND-1808 (a)). And a
#     receipt on an older base passes, so the head plus the target's newer
#     commits was never gated (DND-1463, accepted by the owner); the merge
#     train re-tests that integrated result before the car merges.
#
# Test seam: GLAB_ATHENA_MERGE_DRY_RUN=1 (read by ai/bin/glab-athena) runs this
# guard (reads only) and prints the command instead of running glab.
#
# Usage: `glmg_guard "$@"` after glab-athena's isolation exports. It returns 0
# when the command may run, and exits 3 with a REFUSING line and a Fix: line
# otherwise. Its reads run `glab` as the caller has set it up, and `git` in
# the current directory for the receipt check.

# shellcheck source=forge-api-scan.sh
. "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/forge-api-scan.sh" || {
  echo "glab-athena: REFUSING: cannot load ai/lib/forge-api-scan.sh, so no merge can be judged." >&2
  echo "  Fix: run glab-athena from a full ~/dev/custom checkout (ai/bin and ai/lib side by side)." >&2
  exit 3
}

# The integration-gate receipt reader, shared with gh-merge-guard.sh,
# integration-gate and locked-merge so they cannot drift (DND-969, DND-1845).
# shellcheck source=integration-receipt.sh
. "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/integration-receipt.sh" || {
  echo "glab-athena: REFUSING: cannot load ai/lib/integration-receipt.sh, so no merge can be judged." >&2
  echo "  Fix: run glab-athena from a full ~/dev/custom checkout (ai/bin and ai/lib side by side)." >&2
  exit 3
}

GLMG_TOOL=glab-athena
GLMG_ESCALATE='Never merge around this (a bare `glab mr merge`, a `glab api` merge call, or the owner'"'"'s login); if the pipeline cannot pass, escalate to your admiral with the MR number and this output.'
GLMG_IG="~/dev/custom/ai/bin/integration-gate"
GLMG_BOARD="read the MR's head and its head pipeline (\`glab mr view <iid> -F json\`: .sha and .head_pipeline.status must be success), then board it on the merge train — \`~/dev/custom/ai/bin/$GLMG_TOOL api -X POST \"projects/:id/merge_trains/merge_requests/<iid>\" -f sha=<head sha>\` — or, on a project with no merge train, \`~/dev/custom/ai/bin/$GLMG_TOOL mr merge <iid> --sha <head sha> --yes\`, running either from a checkout of the MR's project"
GLMG_SAFE_PATH="gate the MR's head with \`$GLMG_IG\` (athena:merge-boarding -> Landing onto a moving main), then $GLMG_BOARD"
GLMG_HOST=""
GLMG_MERGE_MUTATIONS="mergeRequestAccept"

# `glab api` flags (glab 1.112): the one table in ai/lib/forge-api-scan.sh,
# shared with the outbound scan.
GLMG_API_VALUED="$FAS_GLAB_API_VALUED"
GLMG_API_BOOL="$FAS_GLAB_API_BOOL"
GLMG_API_SVALUED="$FAS_GLAB_API_SVALUED"
GLMG_API_SBOOL="$FAS_GLAB_API_SBOOL"

# `glab mr merge` flags (glab 1.112; --when-pipeline-succeeds is its hidden,
# deprecated boolean). -R/--repo is also accepted before the subcommand.
GLMG_MR_VALUED=" --repo --message --sha --squash-message "
GLMG_MR_BOOL=" --auto-merge --when-pipeline-succeeds --rebase --remove-source-branch --squash --yes --help "
GLMG_MR_SVALUED="Rm"
GLMG_MR_SBOOL="rdsyh"

glmg_refuse() {
  # $1 what was refused, $2 why (may be multi-line), $3 the Fix: text
  printf '%s: REFUSING `%s`: %s\n  Fix: %s. %s\n' "$GLMG_TOOL" "$1" "$2" "$3" "$GLMG_ESCALATE" >&2
  exit 3
}

# glmg_parse_cli <args...> : the positional words of a non-api glab command,
# with the mr-merge flag table. Sets GLMG_POS, GLMG_REPO, GLMG_SHA (and
# GLMG_SHA_N, how many --sha), GLMG_UNKNOWN (the first flag outside the table,
# or "") and GLMG_POS0_AT (the 0-based argv index of the first positional word, or "").
# There is deliberately no --help short-circuit: pflag lets a later
# `--help=false` switch help off again, so a merge carrying --help is judged
# like any other (DND-742 critic finding).
glmg_parse_cli() {
  local a v i c rest n="$#"
  GLMG_POS=() GLMG_REPO="" GLMG_SHA="" GLMG_SHA_N=0 GLMG_UNKNOWN="" GLMG_POS0_AT=""
  while [ $# -gt 0 ]; do
    a="$1"; shift
    case "$a" in
      --)
        [ $# -gt 0 ] && [ -z "$GLMG_POS0_AT" ] && GLMG_POS0_AT=$((n - $#))
        GLMG_POS+=("$@"); break ;;
      --*=*)
        if [[ "$GLMG_MR_VALUED" == *" ${a%%=*} "* ]]; then glmg_cli_opt "${a%%=*}" "${a#*=}"
        elif [[ "$GLMG_MR_BOOL" == *" ${a%%=*} "* ]]; then :
        else [ -n "$GLMG_UNKNOWN" ] || GLMG_UNKNOWN="${a%%=*}"; fi ;;
      --*)
        if [[ "$GLMG_MR_VALUED" == *" $a "* ]]; then
          v="${1:-}"; [ $# -gt 0 ] && shift
          glmg_cli_opt "$a" "$v"
        elif [[ "$GLMG_MR_BOOL" == *" $a "* ]]; then :
        else [ -n "$GLMG_UNKNOWN" ] || GLMG_UNKNOWN="$a"; fi ;;
      -?*)
        rest="${a#-}"; i=0
        while [ "$i" -lt "${#rest}" ]; do
          c="${rest:$i:1}"
          if [[ "$GLMG_MR_SBOOL" == *"$c"* ]]; then :
          elif [[ "$GLMG_MR_SVALUED" == *"$c"* ]]; then
            v="${rest:$((i+1))}"; v="${v#=}"
            if [ -z "$v" ]; then v="${1:-}"; [ $# -gt 0 ] && shift; fi
            [ "$c" = R ] && glmg_cli_opt --repo "$v"
            break
          else [ -n "$GLMG_UNKNOWN" ] || GLMG_UNKNOWN="-$c (in '$a')"; fi
          i=$((i+1))
        done ;;
      *)
        [ -z "$GLMG_POS0_AT" ] && GLMG_POS0_AT=$((n - $# - 1))
        GLMG_POS+=("$a") ;;
    esac
  done
  # An explicit status: glab-athena runs under `set -e`, and a loop whose last
  # test was false would otherwise return 1.
  return 0
}

glmg_cli_opt() {
  case "$1" in
    --repo) GLMG_REPO="$2" ;;
    --sha) GLMG_SHA="$2"; GLMG_SHA_N=$((GLMG_SHA_N+1)) ;;
  esac
}

# glmg_prepath_flag <args...> : sets GLMG_PREPATH_FLAG to the first flag that
# comes before the command path is fixed and is not -R/--repo, or "".
#
# The path is the first positional word, or the first two when the first is
# `mr`. Cobra finds it by its own walk (stripFlags), which is not any command's
# flag table: a two-character `-x` or a `--flag` with no `=` that the level
# does not know as a boolean takes the next word; every other flag word is
# dropped alone; `--` ends the walk. So `mr -ym merge 4242` routes to merge
# (measured, glab 1.112), while the mr-merge table reads `-m` as taking
# `merge`. Before the path, only -R/--repo parse the same both ways (a value
# flag at every level, measured): `-R v`, `--repo v`, `-Rv`, `-R=v`,
# `--repo=v`. Any other flag word there, `--` included, is reported, and
# glmg_guard refuses it when argv could be a merge.
glmg_prepath_flag() {
  local a seen=0 need=1
  GLMG_PREPATH_FLAG=""
  while [ $# -gt 0 ]; do
    a="$1"; shift
    case "$a" in
      -R|--repo) [ $# -gt 0 ] && shift ;;
      -R?*|--repo=*) ;;
      -*) GLMG_PREPATH_FLAG="$a"; return 0 ;;
      *)
        seen=$((seen+1))
        [ "$seen" = 1 ] && [ "$a" = mr ] && need=2
        [ "$seen" -ge "$need" ] && return 0 ;;
    esac
  done
  return 0
}

# glmg_check_head <shown> <mr json> <pinned sha> <fix> : returns 0 when <pinned
# sha> is the MR's head and the MR's head pipeline passed on that head (see the
# header); exits 3 otherwise. Reads the pipeline's commit when it has to.
glmg_check_head() {
  local shown="$1" mr="$2" pin="$3" fix="$4" head iid pid hp_status hp_sha hp_ref hp_id commit err rc parents
  if ! jq -e '(.sha | type == "string") and (.iid | type == "number") and (.project_id | type == "number")' >/dev/null 2>&1 <<<"$mr"; then
    glmg_refuse "$shown" "the MR as read has no usable sha / iid / project_id ($(head -c 200 <<<"$mr" | tr '\n' ' ')), so no merge gate can be established" "$fix"
  fi
  head="$(jq -r .sha <<<"$mr")"; iid="$(jq -r .iid <<<"$mr")"; pid="$(jq -r .project_id <<<"$mr")"
  if [ -z "$pin" ]; then
    glmg_refuse "$shown" "a merge must pin the exact head it was checked on, and no sha was given (the MR's head is $head)" "$fix"
  fi
  if [ "$pin" != "$head" ]; then
    glmg_refuse "$shown" "the pinned sha $pin is not the MR's head; the head is $head (pass the full 40-char SHA)" "re-check the pipeline on $head, then $GLMG_SAFE_PATH"
  fi
  if ! jq -e '.head_pipeline | type == "object"' >/dev/null 2>&1 <<<"$mr"; then
    glmg_refuse "$shown" "!$iid has no head pipeline, so nothing shows head $head passed" \
      "run a pipeline on the MR (\`~/dev/custom/ai/bin/$GLMG_TOOL api -X POST \"projects/:id/merge_requests/$iid/pipelines\"\`), wait for it to pass, then $GLMG_SAFE_PATH"
  fi
  hp_status="$(jq -r '.head_pipeline.status // ""' <<<"$mr")"
  hp_sha="$(jq -r '.head_pipeline.sha // ""' <<<"$mr")"
  hp_ref="$(jq -r '.head_pipeline.ref // ""' <<<"$mr")"
  hp_id="$(jq -r '.head_pipeline.id // "?"' <<<"$mr")"
  if [ "$hp_status" != success ]; then
    glmg_refuse "$shown" "!$iid's head pipeline $hp_id is '${hp_status:-unknown}', not success" \
      "wait for it to finish (\`glab ci status\`, \`glab mr view $iid -F json\`) and fix it if it failed, then $GLMG_SAFE_PATH"
  fi
  [ "$hp_sha" = "$head" ] && return 0
  if [ "$hp_ref" != "refs/merge-requests/$iid/merge" ] || ! [[ "$hp_sha" =~ ^[0-9a-f]{7,64}$ ]]; then
    glmg_refuse "$shown" "!$iid's head pipeline $hp_id (ref '$hp_ref', sha '$hp_sha') cannot be tied to head $head: it is neither a pipeline on the head nor a merged-results pipeline (refs/merge-requests/$iid/merge)" \
      "run a fresh pipeline on the MR (\`~/dev/custom/ai/bin/$GLMG_TOOL api -X POST \"projects/:id/merge_requests/$iid/pipelines\"\`), wait for it to pass, then $GLMG_SAFE_PATH"
  fi
  # A merged-results pipeline runs on a merge commit; its second parent must be
  # the head.
  err="$(mktemp)"
  if commit="$(glab api "projects/$pid/repository/commits/$hp_sha" 2>"$err")"; then rc=0; else rc=$?; fi
  if [ "$rc" != 0 ] || ! jq -e '.parent_ids | type == "array"' >/dev/null 2>&1 <<<"$commit"; then
    local why; why="$(tr '\n' ' ' <"$err")"; rm -f "$err"
    glmg_refuse "$shown" "could not read the merged-results commit $hp_sha of !$iid's head pipeline (\`glab api projects/$pid/repository/commits/$hp_sha\` exit $rc: ${why:-no usable JSON}), so it cannot be tied to head $head" "$fix"
  fi
  rm -f "$err"
  parents="$(jq -r '.parent_ids | join(" ")' <<<"$commit")"
  if [ "$(jq -r '.parent_ids | length' <<<"$commit")" = 2 ] && [ "$(jq -r '.parent_ids[1]' <<<"$commit")" = "$head" ]; then
    return 0
  fi
  glmg_refuse "$shown" "!$iid's head pipeline $hp_id ran on merge commit $hp_sha, whose parents ($parents) do not end in head $head, so it did not test that head" \
    "run a fresh pipeline on the MR (\`~/dev/custom/ai/bin/$GLMG_TOOL api -X POST \"projects/:id/merge_requests/$iid/pipelines\"\`), wait for it to pass, then $GLMG_SAFE_PATH"
}

# ---- the integration-gate receipt (DND-1845) --------------------------------
# glmg_checkout_for <host> <project path> : sets GLMG_TOP and GLMG_COMMON to
# the cwd's checkout when one of its remotes is <host>/<project path>
# (ssh `git@host:path`, `ssh://…@host[:port]/path` or `https://host/path`,
# any case, with or without .git). Returns 1 with GLMG_WHY otherwise. The host
# must be the whole host (`evil-host` is not `host`), and the path the whole
# path. <host> carries no port: a web port and an ssh port differ.
# Residual: a GitLab served under a relative URL root (web_url
# https://host/root/group/project) matches no scp-style remote, so it is
# refused (COULD NOT LOOK), never passed.
glmg_checkout_for() {
  local host="${1,,}" want="${2,,}" u urls found=0 re
  GLMG_TOP="" GLMG_COMMON="" GLMG_WHY=""
  if ! GLMG_TOP="$(git rev-parse --show-toplevel 2>/dev/null)" || [ -z "$GLMG_TOP" ]; then
    GLMG_WHY="the current directory ($(pwd)) is not inside a git checkout"; return 1
  fi
  GLMG_COMMON="$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || GLMG_COMMON=""
  case "$GLMG_COMMON" in
    /*) ;;
    *) GLMG_WHY="the git common dir of ${GLMG_TOP} did not resolve to an absolute path (got '${GLMG_COMMON}'; git >= 2.31 is needed)"; return 1 ;;
  esac
  if ! urls="$(git remote -v 2>/dev/null)"; then
    GLMG_WHY="the remotes of ${GLMG_TOP} could not be listed (\`git remote -v\` failed), so whether it is a checkout of ${host}/${want} is unknown"; return 1
  fi
  urls="$(awk '{print $2}' <<<"$urls" | sort -u)"
  re="^([a-z][a-z0-9+.-]*://)?([^@/]*@)?${host//./\\.}(:[0-9]+)?[:/]${want//./\\.}$"
  while IFS= read -r u; do
    [ -n "$u" ] || continue
    u="${u,,}"; u="${u%/}"; u="${u%.git}"
    [[ "$u" =~ $re ]] && found=1
  done <<<"$urls"
  if [ "$found" != 1 ]; then
    GLMG_WHY="${GLMG_TOP} is not a checkout of ${host}/${want} (its remotes: $(tr '\n' ' ' <<<"${urls:-none}"))"; return 1
  fi
  return 0
}

# glmg_gate_fix <head> : the Fix: text for a head integration-gate has not passed.
glmg_gate_fix() {
  printf 'run `%s` on head %s, in a checkout of the MR'"'"'s project with that head checked out (add `--gate '"'"'<the project'"'"'s gate command>'"'"'` when its main declares no gate: --help says which); it records the receipt only on INTEGRATION OK, and an exit 4 needs the owner'"'"'s --owner-approval first. Then %s' \
    "$GLMG_IG" "$1" "$GLMG_BOARD"
}

# glmg_regated_head <project id> <iid> <head> : sets GLMG_OLD_HEAD to the newest
# EARLIER head of the MR (its diff versions) that has a receipt file in the
# store, or "". The file is not verified here: the refusal says only that it
# exists. Wording only: a failed read leaves it "", and the refusal
# stands either way.
glmg_regated_head() {
  local pid="$1" iid="$2" head="$3" out h
  local -a read=(api)
  GLMG_OLD_HEAD=""
  [ -n "$GLMG_HOST" ] && read+=(--hostname "$GLMG_HOST")
  read+=("projects/$pid/merge_requests/$iid/versions")
  out="$(glab "${read[@]}" 2>/dev/null)" || return 0
  out="$(jq -r 'if type == "array" then .[].head_commit_sha // empty else empty end' <<<"$out" 2>/dev/null)" || return 0
  while IFS= read -r h; do
    [[ "$h" =~ ^[0-9a-f]{40}$ ]] && [ "$h" != "$head" ] || continue
    if [ -e "$(ir_receipt_path "$GLMG_COMMON" "$h")" ]; then GLMG_OLD_HEAD="$h"; return 0; fi
  done <<<"$out"
  return 0
}

# glmg_receipt_gate <shown> <mr json> : returns 0 when integration-gate's sealed
# receipt covers the MR's head against its target branch's tip (or an ancestor
# of it, DND-1463); exits 3 otherwise. Called after glmg_check_head, so the
# pinned sha IS the MR's head: the receipt is read for the head, never for a
# merged-results or train commit.
#
# Every merge is checked, whether or not the project's main DECLARES a gate
# (ir_declared_gate_on). The GitLab project this guards declares none at its
# root, so its integration-gate runs take a caller-supplied --gate and still
# write the same receipt. A check keyed on the declaration would never fire.
# A project gated with any command (a backend suite, a mobile one) is covered
# alike: the receipt says the gate passed, and this does not ask which ran.
glmg_receipt_gate() {
  local shown="$1" mr="$2" head iid pid url host proj branch enc tip json err rc why look fix
  local -a read=(api)
  head="$(jq -r .sha <<<"$mr")"; iid="$(jq -r .iid <<<"$mr")"; pid="$(jq -r .project_id <<<"$mr")"
  url="$(jq -r '.web_url // ""' <<<"$mr" 2>/dev/null)" || url=""
  branch="$(jq -r '.target_branch // ""' <<<"$mr" 2>/dev/null)" || branch=""
  look="COULD NOT LOOK: $GLMG_TOOL cannot read integration-gate's receipt for !$iid's head $head"
  fix="$(glmg_gate_fix "$head")"
  if ! [[ "$url" =~ ^https?://([^/@]+)/(.+)/-/merge_requests/[0-9]+$ ]]; then
    glmg_refuse "$shown" "$look: the MR as read has no usable web_url ('$url'), so its project, and the checkout that holds the receipt, cannot be named" \
      "make the MR readable (right iid, right -R <group>/<project>), then $fix"
  fi
  host="${BASH_REMATCH[1]}"; proj="${BASH_REMATCH[2]}"
  # Every read below goes to the MR's own host. A --hostname that names
  # another host would read the tip on one host and the receipt for another.
  if [ -n "$GLMG_HOST" ] && [ "${GLMG_HOST,,}" != "${host,,}" ]; then
    glmg_refuse "$shown" "$look: --hostname '$GLMG_HOST' is not the MR's host ('$host', from its web_url)" \
      "pass --hostname $host, or drop it; then $fix"
  fi
  GLMG_HOST="$host"
  if [ -z "$branch" ]; then
    glmg_refuse "$shown" "$look: the MR as read has no target_branch, so the tip the receipt must cover cannot be read" \
      "make the MR readable (right iid, right -R <group>/<project>), then $fix"
  fi
  if ! glmg_checkout_for "${host%%:*}" "$proj"; then
    glmg_refuse "$shown" "$look, because $GLMG_WHY. The receipt lives in the git common dir of a checkout of $proj, so it can only be read from one" \
      "cd into a checkout or worktree of $host/$proj (\`git remote -v\` names it), then $fix"
  fi
  if ! enc="$(jq -rn --arg b "$branch" '$b | @uri' 2>/dev/null)" || [ -z "$enc" ]; then
    glmg_refuse "$shown" "$look: the target branch name '$branch' could not be URL-encoded (jq failed)" \
      "make jq work on PATH (\`jq --version\`), then $fix"
  fi
  read+=(--hostname "$GLMG_HOST")
  read+=("projects/$pid/repository/branches/$enc")
  err="$(mktemp)"
  if json="$(glab "${read[@]}" 2>"$err")"; then rc=0; else rc=$?; fi
  why="$(tr '\n' ' ' <"$err")"; rm -f "$err"
  tip="$(jq -r '.commit.id // empty' <<<"$json" 2>/dev/null)" || tip=""
  if [ "$rc" != 0 ] || ! [[ "$tip" =~ ^[0-9a-f]{40}$ ]]; then
    glmg_refuse "$shown" "$look: the tip of its target branch '$branch' could not be read (\`glab ${read[*]}\` exit $rc: ${why:-body '$(head -c 200 <<<"$json" | tr '\n' ' ')'})" \
      "make the target branch readable (right project, network up), then $fix"
  fi
  if ! ir_read_receipt "$GLMG_COMMON" "$head" "$tip"; then
    if [ "$IR_KIND" = "NO RECEIPT" ]; then
      glmg_regated_head "$pid" "$iid" "$head"
      if [ -n "$GLMG_OLD_HEAD" ]; then
        glmg_refuse "$shown" "$IR_KIND: $IR_WHY. an EARLIER head of !$iid, $GLMG_OLD_HEAD, has a receipt file in the store; the MR was re-pushed since (a head pushed after integration-gate --rebase that is not the one it gated, or a later commit), and a receipt covers only the exact head it gated" \
          "re-gate the new head: $fix"
      fi
    fi
    glmg_refuse "$shown" "$IR_KIND: !$iid's head $head (target '$branch' at $tip): $IR_WHY" \
      "${IR_HOW:+$IR_HOW }$fix"
  fi
  if [ "$IR_BASE_MOVED" = 1 ]; then
    printf '%s: RECEIPT %s base %s recorded %s; BASE MOVED: %s is an ancestor of the tip %s, so the head with the newer %s commits was never gated (DND-1463)\n' \
      "$GLMG_TOOL" "$IR_RECEIPT" "$IR_BASE" "$IR_RECORDED_AT" "$IR_BASE" "$tip" "$branch" >&2
  else
    printf '%s: RECEIPT %s base %s recorded %s\n' "$GLMG_TOOL" "$IR_RECEIPT" "$tip" "$IR_RECORDED_AT" >&2
  fi
  return 0
}

# glmg_mr_merge <shown> <args...> : `mr merge` / `mr accept`.
glmg_mr_merge() {
  local shown="$1" mr err rc
  shift
  glmg_parse_cli "$@"
  if [ -n "$GLMG_UNKNOWN" ]; then
    glmg_refuse "$shown" "'$GLMG_UNKNOWN' is not a \`glab mr merge\` flag $GLMG_TOOL knows (glab 1.112), so it cannot tell how the rest of the command parses" \
      "drop the flag (glab rejects an unknown flag anyway); to merge, $GLMG_SAFE_PATH"
  fi
  if [ "$GLMG_SHA_N" -gt 1 ]; then
    glmg_refuse "$shown" "--sha is given $GLMG_SHA_N times; exactly one pin is judged" "pass --sha once; to merge, $GLMG_SAFE_PATH"
  fi
  local -a view=(mr view)
  [ -n "${GLMG_POS[2]:-}" ] && view+=("${GLMG_POS[2]}")
  [ -n "$GLMG_REPO" ] && view+=(-R "$GLMG_REPO")
  err="$(mktemp)"
  if mr="$(glab "${view[@]}" -F json 2>"$err")"; then rc=0; else rc=$?; fi
  if [ "$rc" != 0 ]; then
    local why; why="$(tr '\n' ' ' <"$err")"; rm -f "$err"
    glmg_refuse "$shown" "could not read the MR (\`glab ${view[*]} -F json\` exit $rc: ${why:-no output}), so no merge gate can be established" \
      "make the MR readable (right iid, right -R <group>/<project>), then $GLMG_SAFE_PATH"
  fi
  rm -f "$err"
  glmg_check_head "$shown" "$mr" "$GLMG_SHA" "pass --sha <the MR's head sha>: $GLMG_SAFE_PATH"
  glmg_receipt_gate "$shown" "$mr"
}

# glmg_route <lower-cased normalised path> : classifies a REST path. Sets
# GLMG_KIND (merge | train | none), GLMG_IID and GLMG_PROJ (the project
# segments, joined with %2F, for a read of the same project).
#   merge : projects/<p…>/merge_requests/<iid>/merge
#   train : projects/<p…>/merge_trains/merge_requests/<iid>
# A `.json`/`;x` suffix on the last segment is ignored (Grape's format suffix).
glmg_route() {
  local -a s
  local n last
  GLMG_KIND=none GLMG_IID="" GLMG_PROJ=""
  IFS=/ read -ra s <<<"$1"
  n="${#s[@]}"
  [ "$n" -ge 5 ] && [ "${s[0]}" = projects ] || return 0
  last="${s[-1]%%[.;]*}"
  if [ "$last" = merge ] && [ "${s[-3]}" = merge_requests ]; then
    GLMG_KIND=merge GLMG_IID="${s[-2]}"
    return 0
  fi
  if [ "${s[-3]}" = merge_trains ] && [ "${s[-2]}" = merge_requests ]; then
    GLMG_KIND=train GLMG_IID="$last"
    local IFS=/ p
    p="${s[*]:1:$((n-4))}"
    GLMG_PROJ="${p//\//%2F}"
  fi
  return 0
}

# glmg_train_board <shown> <endpoint as given> : a POST that boards a train car.
glmg_train_board() {
  local shown="$1" ep="$2" i pin="" npin=0 mr err rc
  local -a read=(api)
  if [[ "$ep" == *[?#]* ]]; then
    glmg_refuse "$shown" "the merge-train endpoint carries a query string ('$ep'); $GLMG_TOOL judges the sha pin only from -f/-F fields" \
      "drop the query string and pass parameters as fields; to board, $GLMG_SAFE_PATH"
  fi
  if [ -n "$FAS_INPUT" ] || [ "$FAS_NFORM" -gt 0 ]; then
    glmg_refuse "$shown" "boarding a merge train with --input or --form sends a body $GLMG_TOOL does not read for the sha pin" \
      "pass parameters as -f fields; to board, $GLMG_SAFE_PATH"
  fi
  for i in "${!FAS_FKEY[@]}"; do
    case "${FAS_FKEY[$i]}" in
      sha)
        npin=$((npin+1)); pin="${FAS_FVAL[$i]}"
        if [ "${FAS_FKIND[$i]}" = file ]; then
          glmg_refuse "$shown" "the sha field is read from a file ('${FAS_FVAL[$i]}'), which $GLMG_TOOL does not read" "pass it inline: -f sha=<head sha>; to board, $GLMG_SAFE_PATH"
        fi ;;
      _method)
        glmg_refuse "$shown" "a '_method' field can override the HTTP method" "drop it; to board, $GLMG_SAFE_PATH" ;;
    esac
  done
  if [ "$npin" -gt 1 ]; then
    glmg_refuse "$shown" "the sha field is given $npin times; exactly one pin is judged" "pass -f sha=<head sha> once; to board, $GLMG_SAFE_PATH"
  fi
  if ! [[ "$GLMG_IID" =~ ^[0-9]+$ ]] || [ -z "$GLMG_PROJ" ]; then
    glmg_refuse "$shown" "cannot read an MR iid and project out of the merge-train endpoint ('$ep')" "spell the endpoint plainly; to board, $GLMG_SAFE_PATH"
  fi
  [ -n "$FAS_HOSTNAME" ] && read+=(--hostname "$FAS_HOSTNAME")
  read+=("projects/$GLMG_PROJ/merge_requests/$GLMG_IID")
  err="$(mktemp)"
  if mr="$(glab "${read[@]}" 2>"$err")"; then rc=0; else rc=$?; fi
  if [ "$rc" != 0 ]; then
    local why; why="$(tr '\n' ' ' <"$err")"; rm -f "$err"
    glmg_refuse "$shown" "could not read !$GLMG_IID (\`glab ${read[*]}\` exit $rc: ${why:-no output}), so no merge gate can be established" \
      "make the MR readable (right project, right iid), then $GLMG_SAFE_PATH"
  fi
  rm -f "$err"
  if [ "$(jq -r '.iid // empty' <<<"$mr" 2>/dev/null)" != "$GLMG_IID" ]; then
    glmg_refuse "$shown" "the MR read back for the merge-train endpoint is not !$GLMG_IID" "spell the endpoint plainly; to board, $GLMG_SAFE_PATH"
  fi
  glmg_check_head "$shown" "$mr" "$pin" "pass -f sha=<the MR's head sha>: $GLMG_SAFE_PATH"
  GLMG_HOST="$FAS_HOSTNAME"
  glmg_receipt_gate "$shown" "$mr"
}

# glmg_api_guard <shown> <glab api args (after the word api)...>
glmg_api_guard() {
  local shown="$1" ep path lower last method write sc
  shift
  FAS_API_VALUED="$GLMG_API_VALUED" FAS_API_BOOL="$GLMG_API_BOOL"
  FAS_API_SVALUED="$GLMG_API_SVALUED" FAS_API_SBOOL="$GLMG_API_SBOOL"
  if ! fas_parse_api "$@"; then
    glmg_refuse "$shown" "'$FAS_UNKNOWN' is not a \`glab api\` flag $GLMG_TOOL knows (glab 1.112), so it cannot tell how the rest of the call parses or whether it merges" \
      "drop the flag (glab rejects an unknown flag anyway); to merge, $GLMG_SAFE_PATH"
  fi
  method="$FAS_METHOD"
  if [ -z "$method" ]; then
    if [ "$FAS_NPARAMS" -gt 0 ] || [ -n "$FAS_INPUT" ]; then method=POST; else method=GET; fi
  fi
  # A write is anything but a plain GET/HEAD; a method-override header or a
  # `_method` field turns any method into a possible write.
  write=1
  case "$method" in GET|HEAD) write=0 ;; esac
  [ "$FAS_OVERRIDE" = 1 ] && write=1
  local k; for k in "${FAS_FKEY[@]}"; do [ "$k" = _method ] && write=1; done

  for ep in "${FAS_POS[@]}"; do
    if ! path="$(fas_path "$ep" api v4)"; then
      glmg_refuse "$shown" "the endpoint '$ep' cannot be normalized (a backslash, a control character, or a malformed or nested %-escape), so $GLMG_TOOL cannot tell whether it is a merge route" \
        "spell the endpoint plainly (e.g. projects/:id/merge_requests/<iid>); to merge, $GLMG_SAFE_PATH"
    fi
    lower="${path,,}"
    last="${lower##*/}"; last="${last%%[.;]*}"
    if [ "$last" = graphql ]; then
      if fas_graphql_scan "$GLMG_MERGE_MUTATIONS"; then sc=0; else sc=$?; fi
      case "$sc" in
        0) glmg_refuse "$shown" "this GraphQL call carries the merge mutation '$FAS_FOUND', which merges (or schedules a merge or train car) without the pinned-head, passed-pipeline check (DND-742)" \
             "merge only through a guarded path: $GLMG_SAFE_PATH" ;;
        2) glmg_refuse "$shown" "$GLMG_TOOL cannot tell whether this GraphQL call merges: $FAS_WHY" \
             "$FAS_HOW; to merge, $GLMG_SAFE_PATH" ;;
      esac
      continue
    fi
    glmg_route "$lower"
    case "$GLMG_KIND" in
      merge)
        if [ "$write" = 1 ]; then
          glmg_refuse "$shown" "this is a REST merge ($method $path), which merges without the pinned-head, passed-pipeline check (DND-742)" \
            "merge only through a guarded path: $GLMG_SAFE_PATH"
        fi ;;
      train)
        [ "$write" = 0 ] && continue
        if [ "$method" = DELETE ] && [ "$FAS_OVERRIDE" = 0 ] && [[ " ${FAS_FKEY[*]} " != *" _method "* ]]; then continue; fi
        if [ "$method" != POST ] || [ "$FAS_OVERRIDE" = 1 ]; then
          glmg_refuse "$shown" "$method on a merge-train car (with any method override) is not the boarding call $GLMG_TOOL judges" \
            "board with POST; to board, $GLMG_SAFE_PATH"
        fi
        glmg_train_board "$shown" "$ep" ;;
    esac
  done
  return 0
}

# glmg_guard <glab args...> : the entry point. Returns 0 or exits 3.
glmg_guard() {
  local shown="glab $*" w
  # First, the words before the command path. Only -R/--repo may sit there when
  # any word could make this a merge: every other flag can make cobra route to
  # a different command than the flag-table parse below reads (see
  # glmg_prepath_flag). Raw argv is scanned for the merge words, because the
  # table parse can itself swallow one (`mr -ym merge`).
  glmg_prepath_flag "$@"
  if [ -n "$GLMG_PREPATH_FLAG" ]; then
    for w in "$@"; do
      case "$w" in
        merge|accept|api|mcp)
          glmg_refuse "$shown" "'$GLMG_PREPATH_FLAG' comes before the subcommand and is not -R/--repo, and a word after it ('$w') could make this a merge; glab's command walk can read that flag differently from $GLMG_TOOL (\`mr -ym merge\` routes to merge), so it cannot tell which command runs" \
            "put the command first and every flag after it (\`glab-athena mr merge <iid> …\`, \`glab-athena api <endpoint> …\`); to merge, $GLMG_SAFE_PATH" ;;
      esac
    done
  fi
  # With the path words clear, the flag table reads the same path glab does.
  glmg_parse_cli "$@"
  case "${GLMG_POS[0]:-}" in
    api)
      # `api` must come first. Anything before it is refused: glab dispatches
      # `glab -R g/r api …` to api (measured, glab 1.112), and the api flag
      # table cannot tell what a flag placed before the word means.
      if [ "$GLMG_POS0_AT" != 0 ]; then
        glmg_refuse "$shown" "\`api\` is not the first word; flags before it ('${*:1:$GLMG_POS0_AT}') are passed to glab api in a way $GLMG_TOOL does not parse, so it cannot tell whether the call merges" \
          "put \`api\` first: \`~/dev/custom/ai/bin/$GLMG_TOOL api <endpoint> [flags]\`; to merge, $GLMG_SAFE_PATH"
      fi
      glmg_api_guard "$shown" "${@:2}"
      return 0 ;;
    mcp)
      glmg_refuse "$shown" "\`glab mcp\` serves GitLab as MCP tools, merging an MR among them, as athena-amby and with no merge guard in the way" \
        "call the glab command you need through the wrapper directly; to merge, $GLMG_SAFE_PATH" ;;
    mr)
      case "${GLMG_POS[1]:-}" in
        merge|accept) glmg_mr_merge "$shown" "$@"; return 0 ;;
      esac ;;
  esac
  # `--auto-merge` outside `mr merge` schedules a merge nobody pinned: glab
  # 1.112's `mr create --auto-merge` sets the new MR to merge when its checks
  # pass. Any word spelling the flag is refused, whatever the subcommand (an
  # over-read of, say, a note whose text is exactly `--auto-merge` is refused
  # too, and says why).
  for w in "$@"; do
    case "$w" in
      --auto-merge|--auto-merge=*)
        glmg_refuse "$shown" "'$w' outside \`mr merge\` sets the MR to merge when its checks pass, on a head nobody pinned or checked (\`glab mr create --auto-merge\`, glab 1.112)" \
          "drop '$w'; create or update the MR without it, and merge through the guarded path once its pipeline passes: $GLMG_SAFE_PATH" ;;
    esac
  done
  return 0
}
