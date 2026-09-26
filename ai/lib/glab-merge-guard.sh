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
# Measured 2026-09-26 (read-only, as athena-amby), amby_ai/walt_ui:
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
#
# How "the head pipeline passed on the head" is decided (glmg_check_head). The
# MR's head_pipeline must have status `success`, and be tied to the head one of
# two ways:
#   * its sha IS the head (a branch or detached MR pipeline); or
#   * its ref is refs/merge-requests/<iid>/merge (a merged-results pipeline) and
#     its commit has exactly two parents, the second being the head. Measured on
#     walt_ui !1473 / !1478: the open MR's head pipeline is this kind, its sha is
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
#
# Test seam: GLAB_ATHENA_MERGE_DRY_RUN=1 (read by ai/bin/glab-athena) runs this
# guard (reads only) and prints the command instead of running glab.
#
# Usage: `glmg_guard "$@"` after glab-athena's isolation exports. It returns 0
# when the command may run, and exits 3 with a REFUSING line and a Fix: line
# otherwise. Its reads run `glab` as the caller has set it up.

# shellcheck source=forge-api-scan.sh
. "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/forge-api-scan.sh" || {
  echo "glab-athena: REFUSING: cannot load ai/lib/forge-api-scan.sh, so no merge can be judged." >&2
  echo "  Fix: run glab-athena from a full ~/dev/custom checkout (ai/bin and ai/lib side by side)." >&2
  exit 3
}

GLMG_TOOL=glab-athena
GLMG_ESCALATE='Never merge around this (a bare `glab mr merge`, a `glab api` merge call, or the owner'"'"'s login); if the pipeline cannot pass, escalate to your admiral with the MR number and this output.'
GLMG_SAFE_PATH="read the MR's head and its head pipeline (\`glab mr view <iid> -F json\`: .sha and .head_pipeline.status must be success), then board it on the merge train — \`~/dev/custom/ai/bin/$GLMG_TOOL api -X POST \"projects/:id/merge_trains/merge_requests/<iid>\" -f sha=<head sha>\` — or, on a project with no merge train, \`~/dev/custom/ai/bin/$GLMG_TOOL mr merge <iid> --sha <head sha> --yes\`"
GLMG_MERGE_MUTATIONS="mergeRequestAccept"

# `glab api` flags (glab 1.112).
GLMG_API_VALUED=" --method --field --raw-field --header --input --form --hostname --output "
GLMG_API_BOOL=" --include --paginate --silent --help "
GLMG_API_SVALUED="XFfH"
GLMG_API_SBOOL="ih"

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
# GLMG_SHA_N, how many --sha), GLMG_HELP, GLMG_UNKNOWN (the first flag outside
# the table, or "") and GLMG_UNKNOWN_AT (how many positional words preceded it).
glmg_parse_cli() {
  local a v i c rest
  GLMG_POS=() GLMG_REPO="" GLMG_SHA="" GLMG_SHA_N=0 GLMG_HELP=0 GLMG_UNKNOWN="" GLMG_UNKNOWN_AT=""
  while [ $# -gt 0 ]; do
    a="$1"; shift
    case "$a" in
      --) GLMG_POS+=("$@"); break ;;
      --help|-h) GLMG_HELP=1 ;;
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
          if [[ "$GLMG_MR_SBOOL" == *"$c"* ]]; then [ "$c" = h ] && GLMG_HELP=1
          elif [[ "$GLMG_MR_SVALUED" == *"$c"* ]]; then
            v="${rest:$((i+1))}"; v="${v#=}"
            if [ -z "$v" ]; then v="${1:-}"; [ $# -gt 0 ] && shift; fi
            [ "$c" = R ] && glmg_cli_opt --repo "$v"
            break
          else [ -n "$GLMG_UNKNOWN" ] || GLMG_UNKNOWN="-$c (in '$a')"; fi
          i=$((i+1))
        done ;;
      *) GLMG_POS+=("$a") ;;
    esac
    [ -n "$GLMG_UNKNOWN" ] && [ -z "$GLMG_UNKNOWN_AT" ] && GLMG_UNKNOWN_AT="${#GLMG_POS[@]}"
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
  local shown="glab $*" w i=0
  # The command is the first positional word. `api` is parsed with the api flag
  # table: its first positional is the endpoint.
  local -a before=()
  for w in "$@"; do
    case "$w" in
      api) glmg_api_guard "$shown" "${before[@]}" "${@:$((i + 2))}"; return 0 ;;
      -*) before+=("$w") ;;
      *) break ;;
    esac
    i=$((i+1))
  done
  glmg_parse_cli "$@"
  case "${GLMG_POS[0]:-}" in
    mcp)
      glmg_refuse "$shown" "\`glab mcp\` serves GitLab as MCP tools, merging an MR among them, as athena-amby and with no merge guard in the way" \
        "call the glab command you need through the wrapper directly; to merge, $GLMG_SAFE_PATH" ;;
    mr)
      case "${GLMG_POS[1]:-}" in
        merge|accept)
          [ "$GLMG_HELP" = 1 ] && [ -z "$GLMG_UNKNOWN" ] && return 0
          glmg_mr_merge "$shown" "$@" ;;
      esac ;;
  esac
  # A flag outside the table BEFORE the subcommand is fixed (cobra assumes an
  # unknown flag takes a value, so it may swallow the next word) can make glab
  # read the command differently than this parse did. If any word could then
  # be a merge, refuse. A flag after the subcommand cannot change it.
  if [ -n "$GLMG_UNKNOWN" ] && [ "${GLMG_UNKNOWN_AT:-0}" -lt 2 ]; then
    for w in "${GLMG_POS[@]}"; do
      case "$w" in
        merge|accept|api|mcp)
          glmg_refuse "$shown" "'$GLMG_UNKNOWN' comes before the subcommand, is a flag $GLMG_TOOL does not know, and a word after it ('$w') could make this a merge; it cannot tell how glab parses them" \
            "put the command first (\`glab-athena mr merge <iid> …\`, \`glab-athena api <endpoint> …\`) and drop unknown flags; to merge, $GLMG_SAFE_PATH" ;;
      esac
    done
  fi
  return 0
}
