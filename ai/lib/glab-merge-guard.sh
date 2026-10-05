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
#   * `mr merge` / `mr accept` (--squash, --rebase, …) is REFUSED unless
#     `--sha <sha>` is given, <sha> IS the MR's head, and the head pipeline
#     passed on it (see glmg_check_head).
#   * …and unless auto-merge is OFF by name, `--auto-merge=false` (DND-1941).
#     glab sets auto-merge by DEFAULT (glab 1.92.1 --help: "--auto-merge Set
#     auto-merge. (true)"), and auto-merge is a DEFERRED merge: GitLab
#     completes it later, when its own checks pass (approvals, threads, a new
#     pipeline), onto whatever the target branch is then. No receipt or
#     red-tip judgment can be read at that moment, so it is refused, as gh-athena
#     refuses `--auto` in a gated repo (DND-969); every project merged here is
#     gated (DND-1845, below). `--when-pipeline-succeeds` (hidden, deprecated)
#     is refused in any spelling. Before DND-1941 this said "--auto-merge does
#     not relax this: with a passed pipeline there is nothing left to wait
#     for"; but a merge GitLab cannot complete at once (an unmet approval rule,
#     an open thread) can wait, scheduled, and complete later with nothing
#     here re-read.
#   * MERGE-TRAIN BOARDING — `glab-athena api -X POST
#     projects/<p>/merge_trains/merge_requests/<iid> -f sha=<sha>` — is the
#     guarded path the athena:merge-boarding flow already uses; it now needs the
#     `sha` field, and the same head check. The train then re-tests the
#     integrated result before the car merges. GET/HEAD (read a car) and DELETE
#     (take a car off the train) pass. Any other method on a car is refused,
#     and so is an `auto_merge` / `when_pipeline_succeeds` field (DND-1941: it
#     boards the car later, when the checks pass, which is a deferred merge).
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
#   * API writes that CREATE OR MOVE A REF, or change a branch's protection, are
#     REFUSED outright (DND-1941, the GitLab side of DND-741): REST writes to
#     repository/branches and repository/tags (a plain DELETE of one ref
#     passes), POST repository/commits and its cherry_pick / revert,
#     repository/files, repository/submodules, repository/changelog,
#     protected_branches, protected_tags, remote_mirrors, mirror/pull and
#     merge_requests/<iid>/rebase; and the GraphQL mutations in
#     GLMG_REF_MUTATIONS. See glmg_ref_route for the scope decision.
#
# AND the target tip is not RED (DND-1941, the GitLab side of DND-1902): its
# own pipelines and its content are judged by gmg_line_check, the code
# gh-athena runs, with glmg_tip_health in place of the GitHub runs read. See
# "stop the line" below.
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
#   * A ref move outside `api`: `glab mr rebase` (the CLI form of the refused
#     rebase route; it moves only the MR's source branch, as a feature-branch
#     push does, as gh-athena leaves `gh pr update-branch`), and a
#     `glab-athena git push` to `main`, which ai/lib/forge-git-passthrough.sh
#     judges instead (a default branch with another name is not judged there). A PUT projects/<p> that
#     re-points default_branch or changes merge settings (it moves no ref).
#     Other forge settings: approval rules, push rules, and branchRule*
#     mutations other than create/update/delete. External commit statuses
#     (POST projects/<p>/statuses/<sha>), as on GitHub. Before DND-1941 this
#     listed the REST and GraphQL ref writes now refused.
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
# glab versions: the flag tables and the routing measurements are glab 1.112's
# (2026-09-26); the auto-merge default was read from glab 1.92.1's --help on
# 2026-10-03 (this machine), and the DND-742 suite's M4 case already named
# auto-merge as 1.112's default.
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

# The stop-the-line judges (DND-1902: gmg_line_check, gmg_content_health and
# their marks) are gh-merge-guard.sh's, shared so the two forges cannot drift
# (DND-1941). Loading it defines functions and constants only; nothing in it
# runs, and its GitHub-only reads (gmg_tip_health) are never called here:
# glmg_tip_health judges the GitLab tip in their place.
GMG_TOOL=glab-athena
# shellcheck source=gh-merge-guard.sh
. "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/gh-merge-guard.sh" || {
  echo "glab-athena: REFUSING: cannot load ai/lib/gh-merge-guard.sh (the shared stop-the-line judges), so no merge can be judged." >&2
  echo "  Fix: run glab-athena from a full ~/dev/custom checkout (ai/bin and ai/lib side by side)." >&2
  exit 3
}

GLMG_TOOL=glab-athena
GLMG_ESCALATE='Never merge or move a branch around this (a bare `glab mr merge`, a `glab api` merge or ref write, or the owner'"'"'s login); if the pipeline cannot pass, escalate to your admiral with the MR number and this output.'
GLMG_IG="~/dev/custom/ai/bin/integration-gate"
GLMG_BOARD="read the MR's head and its head pipeline (\`glab mr view <iid> -F json\`: .sha and .head_pipeline.status must be success), then board it on the merge train — \`~/dev/custom/ai/bin/$GLMG_TOOL api -X POST \"projects/:id/merge_trains/merge_requests/<iid>\" -f sha=<head sha>\` — or, on a project with no merge train, \`~/dev/custom/ai/bin/$GLMG_TOOL mr merge <iid> --sha <head sha> --auto-merge=false --yes\`, running either from a checkout of the MR's project"
GLMG_SAFE_PATH="gate the MR's head with \`$GLMG_IG\` (athena:merge-boarding -> Landing onto a moving main), then $GLMG_BOARD"
GLMG_HOST=""
# Set by glmg_mr_merge for an `mr merge` / `mr accept` it lets through, and
# read by ai/lib/glab-landing.sh after glab ran (DND-1939). Empty otherwise.
GLMG_LAND_IID="" GLMG_LAND_PID="" GLMG_LAND_HEAD="" GLMG_LAND_TOP="" GLMG_LAND_BEFORE=""
GLMG_MERGE_MUTATIONS="mergeRequestAccept"
# GitLab's GraphQL mutations that create or move a ref, or change a branch's
# protection (DND-1941; the mutation list of gitlab.com's schema, read
# 2026-10-03). branchDelete moves nothing onto a ref and passes, as a REST
# branch DELETE does.
GLMG_REF_MUTATIONS="commitCreate|createBranch|tagCreate|branchRuleCreate|branchRuleUpdate|branchRuleDelete|scanExecutionPolicyCommit|securityFindingCreateMergeRequest"
GLMG_REF_FIX="commit locally and move a branch only with \`~/dev/custom/ai/bin/$GLMG_TOOL git push origin <feature-branch>\` (athena:gitlab -> Pushing as Athena); land on the default branch only through an MR: $GLMG_SAFE_PATH. A branch-protection or mirror change is a forge-settings change: name it to your admiral, never make it through the API"
# The deferred-merge refusal's Fix (DND-1941).
GLMG_DEFER_FIX="merge at once with auto-merge OFF, spelled \`--auto-merge=false\` (glab sets auto-merge by default): \`~/dev/custom/ai/bin/$GLMG_TOOL mr merge <iid> --sha <head sha> --auto-merge=false --yes\` once the head pipeline passed and integration-gate passed that head; or board the merge train with only -f sha=<head sha>. Full path: $GLMG_SAFE_PATH"

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
#
# It also reads auto-merge the way pflag does (DND-1941): GLMG_AUTO is 1 unless
# the LAST --auto-merge spelling set it false (`--auto-merge=false`, `=0`, `=f`,
# …; glab's default is true, and a bare `--auto-merge` sets it true again).
# A bool flag takes no separate value: in `--auto-merge false`, `false` is a
# positional word. GLMG_AUTO_BAD names an `--auto-merge=<v>` whose value pflag
# would reject; GLMG_WPS names any --when-pipeline-succeeds spelling (glab's
# hidden, deprecated auto-merge flag).
glmg_parse_cli() {
  local a v i c rest n="$#"
  GLMG_POS=() GLMG_REPO="" GLMG_SHA="" GLMG_SHA_N=0 GLMG_UNKNOWN="" GLMG_POS0_AT=""
  GLMG_AUTO=1 GLMG_AUTO_BAD="" GLMG_WPS=""
  while [ $# -gt 0 ]; do
    a="$1"; shift
    case "$a" in
      --)
        [ $# -gt 0 ] && [ -z "$GLMG_POS0_AT" ] && GLMG_POS0_AT=$((n - $#))
        GLMG_POS+=("$@"); break ;;
      --*=*)
        if [[ "$GLMG_MR_VALUED" == *" ${a%%=*} "* ]]; then glmg_cli_opt "${a%%=*}" "${a#*=}"
        elif [[ "$GLMG_MR_BOOL" == *" ${a%%=*} "* ]]; then glmg_cli_bool "${a%%=*}" "${a#*=}" "$a"
        else [ -n "$GLMG_UNKNOWN" ] || GLMG_UNKNOWN="${a%%=*}"; fi ;;
      --*)
        if [[ "$GLMG_MR_VALUED" == *" $a "* ]]; then
          v="${1:-}"; [ $# -gt 0 ] && shift
          glmg_cli_opt "$a" "$v"
        elif [[ "$GLMG_MR_BOOL" == *" $a "* ]]; then glmg_cli_bool "$a" true "$a"
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

# glmg_cli_bool <flag> <value> <word as given> : one boolean of the mr-merge
# table. pflag's ParseBool reads 1/t/T/TRUE/true/True and 0/f/F/FALSE/false/
# False (gmg_false_word); anything else is an error in glab.
glmg_cli_bool() {
  case "$1" in
    --auto-merge)
      if gmg_false_word "$2"; then GLMG_AUTO=0
      else
        case "$2" in 1|t|T|true|TRUE|True) GLMG_AUTO=1 ;; *) GLMG_AUTO=1; GLMG_AUTO_BAD="$3" ;; esac
      fi ;;
    --when-pipeline-succeeds) GLMG_WPS="$3" ;;
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
  # The target tip this merge was judged on: a landing's `before` (DND-1939).
  GLMG_LAND_BEFORE="$tip"
  if [ "$IR_BASE_MOVED" = 1 ]; then
    printf '%s: RECEIPT %s base %s recorded %s; BASE MOVED: %s is an ancestor of the tip %s, so the head with the newer %s commits was never gated (DND-1463)\n' \
      "$GLMG_TOOL" "$IR_RECEIPT" "$IR_BASE" "$IR_RECORDED_AT" "$IR_BASE" "$tip" "$branch" >&2
  else
    printf '%s: RECEIPT %s base %s recorded %s\n' "$GLMG_TOOL" "$IR_RECEIPT" "$tip" "$IR_RECORDED_AT" >&2
  fi
  # What the stop-the-line check (glmg_tip_gate, DND-1941) judges: the same
  # tip, read once, with the MR's project, target and head.
  GLMG_TIP="$tip" GLMG_BRANCH="$branch" GLMG_PROJ_PATH="$proj" GLMG_PID="$pid" GLMG_HEAD="$head"
  return 0
}

# ---- stop the line: the target tip's own pipelines and content (DND-1941) ---
# The GitLab side of DND-1902. Every merge this guard lets through (mr merge,
# train boarding) also judges the target branch's tip, after the receipt:
#   * RUNS (glmg_tip_health): the tip's pipelines on the target branch,
#     `projects/<id>/pipelines?sha=<tip>&ref=<target>`. The latest pipeline of
#     each source (push, a child pipeline, a schedule, …) is judged, the way
#     gh-merge-guard judges the latest run of each check: failed, canceled or
#     canceling is RED; created, waiting_for_resource, preparing, pending,
#     running, scheduled or manual is PENDING (not red, so the merge proceeds
#     and names it); success or skipped is not red. An older red pipeline is
#     superseded only when its source's latest pipeline SUCCEEDED. So a new
#     pipeline of ANOTHER source (a "Run pipeline" click is source `web`, a
#     schedule may run other jobs) never clears a red push pipeline; retrying
#     the red pipeline does, since its status becomes its retried jobs'. A
#     status the judge does not know is COULD NOT LOOK.
#   * A tip with NO pipeline is COULD NOT LOOK, never green. This is stricter
#     than GitHub, where a repo with no CI (custom's shape) reports no run and
#     passes. So a project merged through this guard must run a pipeline on its
#     target branch (gen_saas's post-merge deploy does). A project whose target
#     branch runs none (custom, which lands by a fast-forward `glab-athena git
#     push`, not by an MR merge) cannot merge here: every such merge is refused
#     COULD NOT LOOK, closed, by design.
#   * CONTENT: gmg_content_health, the same code and the same declaration
#     (ai/config/main-content-checks.json) as on GitHub, looked up by the MR's
#     full project path in each product's paths, so
#     gitlab.com/athena-ai-harness/gen_saas reads the gen_saas entry. A path
#     no entry lists whose project name is a declared product's (the pre-move
#     gitlab.com/cjpoll/gen_saas) is COULD NOT LOOK, never "no check"
#     (DND-2034).
#   * The red-main fix and the composition are gmg_line_check's: a head that
#     contains the tip (from the local object store, else the forge's merge
#     base) and removes every duplicate passes; any other MR is refused. What
#     cannot be read is COULD NOT LOOK and refused.
# Residuals (named, not closed): those of DND-1902 (a merge onto a PENDING tip
# that turns red; containing a red tip is the only fix evidence read for a red
# pipeline); a red pipeline beyond the first page of 100 is COULD NOT LOOK; a
# pipeline on the tip that GitLab lists under another ref (a tag) is not read.

# GLMG_TIP_SHAPE: OK, EMPTY or ERR<TAB><why>, for the pipelines answer.
GLMG_TIP_SHAPE='
  if type != "array" then "ERR\tthe answer is not a list of pipelines: \(tojson | .[0:200])"
  elif length == 0 then "EMPTY"
  elif length >= 100 then "ERR\tthe tip lists \(length) pipelines on one page of 100, so more may exist, and unread pipelines are not green"
  elif (map((.id | type) == "number" and (.status | type) == "string") | all | not) then "ERR\ta listed pipeline has no numeric id or no status: \(tojson | .[0:200])"
  elif (map(.sha == $tip and .ref == $ref) | all | not) then
    "ERR\tthe answer lists pipelines that are not on \($ref) at \($tip): \([.[] | select(.sha != $tip or .ref != $ref) | "\(.id) on \(.ref // "?") at \(.sha // "?")"] | join(", "))"
  else "OK" end'

# GLMG_TIP_JUDGE: one line per finding, like gh-merge-guard's GMG_TIP_JUDGE:
# RED, PEND, OLD (a superseded red pipeline) or ODD (a status it does not know).
GLMG_TIP_JUDGE='
  def red: .status | IN("failed", "canceled", "canceling");
  def pending: .status | IN("created", "waiting_for_resource", "preparing", "pending", "running", "scheduled", "manual");
  def known: red or pending or (.status | IN("success", "skipped"));
  def lbl: "pipeline \(.id) (\(.source // "no source")): \(.status)\(if (.web_url // "") == "" then "" else " \(.web_url)" end)";
  def judge($why):
    if (known | not) then "ODD\t\(lbl)"
    elif red then "RED\t\(lbl)\($why)"
    elif pending then "PEND\t\(lbl)"
    else empty end;
  def skey: if (.source | type) == "string" and .source != "" then "source:\(.source)" else "alone:\(.id)" end;
  group_by(skey)[] | sort_by(.id) | .[-1] as $cur | .[:-1] as $old | ($cur.status == "success") as $supersedes
  | ($cur | judge(", the latest \(.source // "no-source") pipeline")),
    ($old[] | if (known | not) then "ODD\t\(lbl)"
              elif (red | not) then empty
              elif $supersedes then "OLD\t\(lbl)"
              else "RED\t\(lbl): the newer pipeline \($cur.id) is \($cur.status), not success, so it does not supersede this one" end)'

# glmg_tip_health <owner> <repo> <tip> <head|""> <gitdir> <target> : the runs
# judge gmg_line_check calls (its contract is there). Never exits. Reads the
# project by GLMG_PID on GLMG_HOST, both set by glmg_receipt_gate.
glmg_tip_health() {
  local tip="$3" head="$4" gitdir="$5" base="$6" enc pipes err rc why shape judged line red="" pend="" odd="" mb
  local -a req=(api)
  GMG_TIP_STATE="LOOK" GMG_TIP_RUNS="" GMG_TIP_OLD="" GMG_TIP_WHY=""
  if ! [[ "$tip" =~ ^[0-9a-f]{40}$ ]]; then GMG_TIP_WHY="the target tip '$tip' is not a full SHA"; return 2; fi
  if ! [[ "${GLMG_PID:-}" =~ ^[0-9]+$ ]]; then GMG_TIP_WHY="the MR's project id '${GLMG_PID:-}' is not a number, so the tip's pipelines cannot be read"; return 2; fi
  if [ -z "$base" ] || ! enc="$(jq -rn --arg b "$base" '$b | @uri' 2>/dev/null)" || [ -z "$enc" ]; then
    GMG_TIP_WHY="the target branch '$base' could not be URL-encoded, so the tip's pipelines cannot be read"; return 2
  fi
  [ -n "$GLMG_HOST" ] && req+=(--hostname "$GLMG_HOST")
  req+=("projects/$GLMG_PID/pipelines?sha=$tip&ref=$enc&per_page=100")
  if ! err="$(mktemp)"; then GMG_TIP_WHY="mktemp failed, so the tip's pipelines could not be read"; return 2; fi
  if pipes="$(glab "${req[@]}" 2>"$err")"; then rc=0; else rc=$?; fi
  why="$(tr '\n' ' ' <"$err")"; rm -f "$err"
  if [ "$rc" != 0 ]; then
    GMG_TIP_WHY="the pipelines on $tip could not be read (\`glab ${req[*]}\` exit $rc: ${why:-no stderr})"; return 2
  fi
  if ! shape="$(jq -r --arg tip "$tip" --arg ref "$base" "$GLMG_TIP_SHAPE" <<<"$pipes" 2>/dev/null)"; then
    shape="ERR"$'\t'"the answer is not the expected JSON: $(head -c 200 <<<"$pipes" | tr '\n' ' ')"
  fi
  case "$shape" in
    OK) ;;
    EMPTY) GMG_TIP_WHY="no pipeline has run on the $base tip $tip (\`glab ${req[*]}\` listed none), so nothing shows it green; a tip with no pipeline is never read as green"; return 2 ;;
    *) GMG_TIP_WHY="the pipelines on $tip could not be read: ${shape#ERR$'\t'}"; return 2 ;;
  esac
  if ! judged="$(jq -r "$GLMG_TIP_JUDGE" <<<"$pipes" 2>&1)"; then
    GMG_TIP_WHY="the tip judge in ai/lib/glab-merge-guard.sh failed (jq: $(tr '\n' ' ' <<<"$judged")); a defect in the guard, not in the MR"; return 2
  fi
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    case "$line" in
      RED$'\t'*) red+="    ${line#*$'\t'}"$'\n' ;;
      PEND$'\t'*) pend+="    ${line#*$'\t'}"$'\n' ;;
      OLD$'\t'*) GMG_TIP_OLD+="    ${line#*$'\t'}"$'\n' ;;
      *) odd+="    ${line#*$'\t'}"$'\n' ;;
    esac
  done <<<"$judged"
  if [ -n "$odd" ]; then
    GMG_TIP_WHY="the tip lists pipelines whose status the judge does not know:
${odd%$'\n'}"; return 2
  fi
  if [ -z "$red" ]; then
    GMG_TIP_RUNS="${pend%$'\n'}"
    if [ -n "$pend" ]; then GMG_TIP_STATE="PENDING"; else GMG_TIP_STATE="CLEAN"; fi
    return 0
  fi
  GMG_TIP_RUNS="${red%$'\n'}"
  GMG_TIP_STATE="RED"
  [ -n "$head" ] || return 1
  # Does the head contain the red tip? The local graph answers when both
  # commits are here (0 yes, 1 no); anything else asks the forge.
  if git -C "$gitdir" merge-base --is-ancestor "$tip" "$head" 2>/dev/null; then rc=0; else rc=$?; fi
  case "$rc" in
    0) GMG_TIP_STATE="FIX"; return 0 ;;
    1) return 1 ;;
  esac
  # DND-2061: from here on containment only names a red-main fix in the note.
  # A head that does not contain the red tip, or one whose containment cannot
  # be read, is RED (return 1), which gmg_line_check does not refuse.
  if ! [[ "$head" =~ ^[0-9a-f]{40}$ ]]; then
    GMG_TIP_WHY="may not contain it: it is not a full SHA, so whether it does could not be read"; return 1
  fi
  req=(api)
  [ -n "$GLMG_HOST" ] && req+=(--hostname "$GLMG_HOST")
  req+=("projects/$GLMG_PID/repository/merge_base?refs%5B%5D=$tip&refs%5B%5D=$head")
  if ! err="$(mktemp)"; then
    GMG_TIP_WHY="may not contain it: mktemp failed, so whether it does could not be read"; return 1
  fi
  if mb="$(glab "${req[@]}" 2>"$err")"; then rc=0; else rc=$?; fi
  why="$(tr '\n' ' ' <"$err")"; rm -f "$err"
  mb="$(jq -r '.id // empty' <<<"$mb" 2>/dev/null)" || mb=""
  if [ "$rc" != 0 ] || ! [[ "$mb" =~ ^[0-9a-f]{40}$ ]]; then
    GMG_TIP_WHY="may not contain it: whether it does could not be read (\`glab ${req[*]}\` exit $rc: ${why:-no usable merge base})"
    return 1
  fi
  if [ "$mb" = "$tip" ]; then GMG_TIP_STATE="FIX"; return 0; fi
  return 1
}

# glmg_tip_gate <shown> : returns 0 when the target tip does not stop the
# merge; exits 3 otherwise. Called after glmg_receipt_gate, which read the tip.
glmg_tip_gate() {
  local shown="$1" owner repo rc fix enc
  if [[ "${GLMG_PROJ_PATH:-}" != ?*/?* ]]; then
    glmg_refuse "$shown" "${GMG_LOOK_MARK} the MR's project path '${GLMG_PROJ_PATH:-}' has no namespace, so its content declaration cannot be looked up" \
      "make the MR readable (right iid, right -R <group>/<project>), then $GLMG_SAFE_PATH"
  fi
  owner="${GLMG_PROJ_PATH%/*}" repo="${GLMG_PROJ_PATH##*/}"
  enc="$(jq -rn --arg b "$GLMG_BRANCH" '$b | @uri' 2>/dev/null)" || enc="<the URL-encoded target branch>"
  if gmg_line_check "$owner" "$repo" "$GLMG_BRANCH" "$GLMG_TIP" "$GLMG_HEAD" "$GLMG_TOP" glmg_tip_health; then rc=0; else rc=$?; fi
  case "$rc" in
    0) printf '%s: %s\n' "$GLMG_TOOL" "$GMG_LINE_NOTE" >&2; return 0 ;;
    1) fix="land only a red-main fix: a head that contains $GLMG_TIP, removes every duplicate named above, and carries its own INTEGRATION OK receipt (merge origin/$GLMG_BRANCH into it, fix it, push as Athena, re-gate with \`$GLMG_IG\`). Every other MR waits until that fix lands on $GLMG_BRANCH. A red pipeline on the tip is not by itself a refusal (DND-2061). Then $GLMG_BOARD"
       glmg_refuse "$shown" "$GMG_LINE_WHY" "$fix" ;;
    *) glmg_refuse "$shown" "$GMG_LINE_WHY" \
         "make the tip readable (network up, the right -R <group>/<project>, glab-athena's token, \`git fetch origin\` in this checkout). A tip with no pipeline needs one: \`~/dev/custom/ai/bin/$GLMG_TOOL api -X POST \"projects/$GLMG_PID/pipeline?ref=$enc\"\`, then wait for it to finish. An undeclared path of a declared product (DND-2034) is fixed by adding that path to the product's paths in ~/dev/custom/ai/config/main-content-checks.json, landed on custom main. A malformed repo key or an unloadable runs judge is a defect in the guard: escalate it to your admiral with this output. Then $GLMG_BOARD" ;;
  esac
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
  # A deferred merge (DND-1941): auto-merge hands the merge to GitLab, which
  # completes it later, when its own checks pass, onto whatever the target is
  # then. Every project merged here needs a receipt (DND-1845), and no receipt
  # or tip judgment can be read at that later moment (DND-969 on GitHub). glab
  # sets auto-merge by DEFAULT, so it must be turned off by name. Refused before
  # any read.
  if [ -n "$GLMG_AUTO_BAD" ]; then
    glmg_refuse "$shown" "'$GLMG_AUTO_BAD' is not a boolean pflag reads (glab rejects it), so whether this is a deferred merge cannot be told" \
      "$GLMG_DEFER_FIX"
  fi
  if [ -n "$GLMG_WPS" ]; then
    glmg_refuse "$shown" "'$GLMG_WPS' is glab's hidden, deprecated auto-merge flag: a deferred merge, which GitLab completes later, when its checks pass, onto whatever the target branch is then; no integration-gate receipt or red-tip judgment can cover that moment (DND-1941, DND-969)" \
      "drop it; $GLMG_DEFER_FIX"
  fi
  if [ "$GLMG_AUTO" = 1 ]; then
    glmg_refuse "$shown" "this is a deferred merge: auto-merge is on (glab's default, or --auto-merge), so GitLab completes the merge later, when its checks pass, onto whatever the target branch is then. No integration-gate receipt or red-tip judgment can cover that moment (DND-1941, DND-969)" \
      "$GLMG_DEFER_FIX"
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
  glmg_tip_gate "$shown"
  # What a landing record needs once glab has run (DND-1939,
  # ai/lib/glab-landing.sh): set only here, so only an `mr merge` / `mr
  # accept` the guard let through is ever recorded.
  GLMG_LAND_IID="$(jq -r .iid <<<"$mr")" GLMG_LAND_PID="$(jq -r .project_id <<<"$mr")"
  GLMG_LAND_HEAD="$(jq -r .sha <<<"$mr")" GLMG_LAND_TOP="$GLMG_TOP"
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

# glmg_ref_route <lower-cased normalised path> <method> : true when a WRITE to
# the path creates or moves a ref, or changes a branch's protection (DND-1941,
# the GitLab side of DND-741); echoes what it does. <method> is never GET/HEAD
# here; a plain `DELETE` of one branch or tag moves nothing onto a ref and is
# not a match, but a DELETE with a method override is. Group-level protection
# (groups/<g…>/protected_branches) is a match too. Routes, after
# projects/<p…>/:
#   repository/branches[/…], repository/tags[/…]  (create, protect, unprotect)
#   repository/commits                           (create a commit on a branch)
#   repository/commits/<sha>/cherry_pick|revert
#   repository/files/…, repository/submodules/…, repository/changelog
#   protected_branches[/…], protected_tags[/…], remote_mirrors[/…], mirror/pull
#   merge_requests/<iid>/rebase                   (moves the source branch)
# The project path itself may hold several segments (an encoded %2F decodes to
# `/`), and so may a branch or file name, so every segment after projects/<one
# segment> is tried as the start of a route. A project or group that happens to
# be named like a route word only over-refuses a write, never passes one.
#
# SCOPE (as DND-741 decided for GitHub): EVERY ref write by API, not only one
# aimed at the default branch. Branches move by `glab-athena git push`; the
# target is often not in the call (a commit action list, a file body), and the
# default branch is a read that can fail. A refusal that needs no read has no
# lookup to get wrong.
glmg_ref_route() {
  local method="$2" i n w nx
  local -a s
  IFS=/ read -ra s <<<"$1"
  n="${#s[@]}"
  [ "$n" -ge 3 ] || return 1
  case "${s[0]}" in projects|groups) ;; *) return 1 ;; esac
  s[n-1]="${s[n-1]%%[.;]*}"
  for ((i = 2; i < n; i++)); do
    w="${s[i]}"; nx="${s[i+1]:-}"
    # A group has no repository: only its protection routes apply.
    [ "${s[0]}" = groups ] && [ "$w" != protected_branches ] && continue
    case "$w:$nx" in
      repository:branches|repository:tags)
        # A plain DELETE of one named ref passes; keep scanning the rest.
        if [ "$method" = DELETE ] && [ $((i + 2)) -lt "$n" ]; then continue; fi
        echo "a write to repository/$nx"; return 0 ;;
      repository:commits)
        if [ $((i + 2)) = "$n" ]; then echo "a commit through repository/commits"; return 0; fi
        if [ $((i + 4)) = "$n" ] && [[ "${s[i+3]}" =~ ^(cherry_pick|revert)$ ]]; then
          echo "a ${s[i+3]} onto a branch through repository/commits/<sha>/${s[i+3]}"; return 0
        fi ;;
      repository:files|repository:submodules|repository:changelog)
        echo "a commit through repository/$nx"; return 0 ;;
      mirror:pull)
        echo "a pull-mirror update through mirror/pull"; return 0 ;;
    esac
    case "$w" in
      protected_branches|protected_tags|remote_mirrors)
        echo "a write to $w"; return 0 ;;
      merge_requests)
        if [ $((i + 3)) = "$n" ] && [ "${s[i+2]}" = rebase ]; then
          echo "a rebase of the MR's source branch through merge_requests/<iid>/rebase"; return 0
        fi ;;
    esac
  done
  return 1
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
    # A deferred boarding (DND-1941): these fields add the car only when the
    # checks pass, later, onto whatever the target is then. Any value is
    # refused: the head pipeline has already passed here, so they are never
    # needed. Matched without case, more strictly than GitLab reads them.
    case "${FAS_FKEY[$i],,}" in
      auto_merge|when_pipeline_succeeds|merge_when_pipeline_succeeds)
        glmg_refuse "$shown" "the '${FAS_FKEY[$i]}' field makes this a deferred merge: GitLab adds the car later, when its checks pass, onto whatever the target branch is then, and no integration-gate receipt or red-tip judgment can cover that moment (DND-1941, DND-969)" \
          "drop the field; $GLMG_DEFER_FIX" ;;
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
  glmg_tip_gate "$shown"
}

# glmg_api_guard <shown> <glab api args (after the word api)...>
glmg_api_guard() {
  local shown="$1" ep path lower last method write sc what how
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
      if fas_graphql_scan "$GLMG_MERGE_MUTATIONS|$GLMG_REF_MUTATIONS"; then sc=0; else sc=$?; fi
      case "$sc" in
        0)
          # A merge name is reported as a merge; anything else that matched
          # (including a name that could not be re-extracted) as a ref write.
          if [[ "${FAS_FOUND,,}" =~ ^(${GLMG_MERGE_MUTATIONS,,})$ ]]; then
            glmg_refuse "$shown" "this GraphQL call carries the merge mutation '$FAS_FOUND', which merges (or schedules a merge or train car) without the pinned-head, passed-pipeline check (DND-742)" \
              "merge only through a guarded path: $GLMG_SAFE_PATH"
          fi
          glmg_refuse "$shown" "this GraphQL call carries the ref-write mutation '${FAS_FOUND:-?}', which creates or moves a branch or changes its protection (it can put commits on the default branch) with no pinned head and no passed pipeline (DND-1941, the DND-741 analogue)" \
            "$GLMG_REF_FIX" ;;
        2) glmg_refuse "$shown" "$GLMG_TOOL cannot tell whether this GraphQL call merges or moves a branch: $FAS_WHY" \
             "$FAS_HOW; to merge, $GLMG_SAFE_PATH" ;;
      esac
      continue
    fi
    if [ "$write" = 1 ]; then
      # Only a PLAIN DELETE may pass as a ref delete: an override header or
      # a _method field can turn it into any write.
      how="$method"
      if [ "$FAS_OVERRIDE" = 1 ] || [[ " ${FAS_FKEY[*]} " == *" _method "* ]]; then how="$method with a method override"; fi
      if what="$(glmg_ref_route "$lower" "$how")"; then
        glmg_refuse "$shown" "this is $what ($method $path), which creates or moves a branch or changes its protection (it can put commits on the default branch) with no pinned head and no passed pipeline (DND-1941, the DND-741 analogue)" \
          "$GLMG_REF_FIX"
      fi
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
