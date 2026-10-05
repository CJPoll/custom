# shellcheck shell=bash
#
# glab-fork-pipeline-guard.sh — never run a fork MR's pipeline in the parent
# project (DND-1942). Sourced, never run. Called from ONE place in each glab
# front: ai/bin/glab-athena (after the merge guard) and the agent PATH glab
# wrapper (ai/lib/agent-forge-cli.sh, before it execs the real glab).
#
# THE DEFECT. By GitLab default a fork MR's pipeline runs in the fork, on the
# fork's runners and without the parent's variables. A Developer+ member of
# the parent can still run it IN THE PARENT (the web UI's "Run pipeline", or
# the API), and then the fork's code and the fork's own .gitlab-ci.yml run on
# the parent's runners. A `workflow: rules:` guard in the parent's CI file does
# not apply: the fork's file is the one that runs. The Athena bot is a
# Developer+ member and acts on untrusted input, so before this a single
# `glab-athena api -X POST projects/:id/merge_requests/<iid>/pipelines` on a
# fork MR ran untrusted code on our runner.
#
# THE RULE. A call that creates, runs, retries or plays a pipeline or job is
# REFUSED, exit 3 with a Fix:, when the pipeline belongs to an MR whose
# source_project_id differs from its target_project_id. Both ids are read from
# the API. An MR, job, pipeline or schedule that cannot be read, or a ref,
# project or endpoint this cannot parse, is refused as COULD NOT LOOK, never
# allowed. The calls judged:
#   glab ci|pipe|pipeline run|create  the ref (-b, else the checkout's
#                                  branch); with --mr, every MR whose source
#                                  branch is that branch (glab's OWNER:BRANCH
#                                  form is read as glab reads it)
#   glab ci … run-trig             the ref (-b, else the checkout's branch)
#   glab ci … retry|trigger <job>  a numeric job id: the job's ref; a job name
#                                  needs -p <pipeline id>: that pipeline's ref
#   glab schedule|sched|skd run <id>         the schedule's ref
#   glab schedule … create|update --ref <r>  the ref
#   glab release create --ref|-r <r>         the ref (a new tag on it runs a
#                                            tag pipeline here); its argv is
#                                            read with the pinned glab flag
#                                            table the outbound scan reads
#                                            (ai/lib/glab-flag-table.sh,
#                                            DND-1976), so `--ref -n` is ref
#                                            `-n`, as pflag reads it
#   glab api, a write (not GET/HEAD, or a method override) to
#     projects/<p>/merge_requests/<iid>/pipelines       the MR
#     projects/<p>/pipeline(s)                          the ref field/query
#     projects/<p>/trigger/pipeline                     the ref field/query
#     projects/<p>/ref/<ref>/trigger/pipeline           the ref in the path
#     projects/<p>/jobs/<id>/retry|play                 the job's ref
#     projects/<p>/pipelines/<id>/retry                 the pipeline's ref
#     projects/<p>/pipeline_schedules[/<id>]            the ref field/query
#     projects/<p>/pipeline_schedules/<id>/play         the schedule's ref
#     projects/<p>/merge_trains/merge_requests/<iid>    the MR (a train car
#                                                       runs a pipeline here)
#     projects/<p>/repository/branches|tags, releases   the ref field/query (a
#                                                       branch or tag made from
#                                                       an MR ref puts the
#                                                       fork's code, CI file
#                                                       included, on a ref that
#                                                       runs pipelines here)
#   glab api graphql carrying a pipeline or job mutation (GLFP_MUTATIONS) is
#     refused outright: the target cannot be read cheaply; use the REST route.
# A ref the CALLER names (-b, --ref, a ref field or query, a trigger path) is
# allowed only when it is one of:
#   * an MR ref: a path segment `merge-requests` then a numeric iid
#     (refs/merge-requests/<iid>/head|merge|train, or without the refs/
#     prefix, which git's ref lookup also resolves); the MR is read in the
#     same project and judged. A `merge-requests` segment with no numeric iid
#     after it is COULD NOT LOOK;
#   * an existing branch or tag of the project, read from the API by its exact
#     name. Only Developer+ members (Cody and the bot) put code on those.
# Anything else is COULD NOT LOOK: a commit sha, `refs/keep-around/<sha>` or
# any other ref can name a fork MR's head, whose commits GitLab keeps in the
# parent. A ref read back from an existing job, pipeline or schedule is
# GitLab's own (a branch, a tag or an MR ref), so only its MR form is judged.
# The ways a fork's code reaches a parent branch or tag that this does not
# see are residuals below.
#
# Route matching is done on the endpoint's raw segments, each %-decoded, with
# the project in exactly one segment (an id, a URL-encoded path, or a glab
# placeholder like :id). A write whose NORMALISED path (fas_path) ends like a
# judged route but whose raw shape is not exactly that route (an encoded slash
# in a route word, a `.`/`..` segment, an unencoded project path) is COULD NOT
# LOOK. A `.json`/`;x` suffix on the last segment is Grape's and is ignored.
#
# HELP (DND-2078). A call that asks for help sends nothing: cobra prints the
# help and runs nothing, and pflag reads every flag first, so a flag left with
# no value fails and runs nothing either. So a judged command whose argv asks
# for help passes UNREAD, before any ref, MR or branch is read. Help is the
# outbound scan's rule, ots_help_asked (ai/lib/outbound-text-scan.sh), over a
# strict ots_pflag_parse with the command's flag table: GLFP_T_* for ci,
# schedule and api, the pinned table for release create. A word that is a
# flag's value (`--ref --help`, `-H --help`), a later `--help=false`, a flag
# the table lacks, or `--help` after `--` is not help, and the call is judged
# as before. ai/bin/cli-flag-table probes `<cmd> --help --<flag>` through
# whatever glab is on PATH, which in an agent session is this guard's front.
#
# RESIDUAL (NOT checked; each still runs):
#   * Cody clicking "Run pipeline" (or retry/play) on a fork MR in the web UI.
#     The rule is never; it is written into athena:gitlab.
#   * Interactive prompts: `glab ci view` (a TUI) and `glab ci status` (a
#     "Retry" choice) retry only from an interactive terminal; agent sessions
#     have none and glab-athena sets GLAB_NO_PROMPT=1.
#   * `mr merge`/`mr accept` of a fork MR on a project with merge trains or
#     auto-merge into a train: that creates a train pipeline in the parent.
#     Train boarding by API is judged; the merge command is the merge guard's.
#   * `mr rebase` of a fork MR: GitLab pushes to the fork's branch, and the
#     pipeline that follows runs in the fork.
#   * A fork's commit put on a parent ref some other way: `glab-athena git
#     push <fork sha>:refs/heads/x` (the git passthrough runs before this),
#     or a REST commit whose start_sha/start_project names fork code
#     (`repository/commits`; DND-1941 refuses API ref writes in glab-athena).
#     The branch or tag pipeline that follows runs here.
#   * `environments/<id>/stop` (or GraphQL environmentStop) plays an
#     environment's on_stop job; it can hold fork code only if a fork MR
#     pipeline already ran here, which this refuses.
#   * `glab mcp serve` exposes ci run/trigger and api as MCP tools; this
#     guard returns for `mcp`, and glab-athena runs nothing because its merge
#     guard refuses `mcp serve` outright. Relaxing that refusal needs this
#     guard taught the MCP tool calls first.
#   * Any client that is not glab (curl with a token), or glab run by absolute
#     path past the agent wrapper; a pipeline/job route GitLab adds after
#     2026-10-03; a GraphQL mutation not named in GLFP_MUTATIONS.
#
# Fails closed (refused, not a bypass): -R in glab's HOST/GROUP/PROJECT form
# reads as a three-level project path, whose read fails; use a URL or
# GROUP/PROJECT. On the glab-athena -> agent wrapper path the check runs twice
# (each front judges its own argv); its reads are GETs and pass straight on.
#
# Usage: set GLFP_TOOL (the name refusals carry) and optionally GLFP_GLAB (the
# glab its reads run, default `glab`), then `glfp_guard "$@"`. It returns 0 when
# the call may run and exits 3 with a REFUSING line and a Fix: line otherwise.
# A refusal names the command's group and verb (or the endpoint path), never
# the rest of argv: an argument can carry a secret (`ci run-trig -t <token>`).
# Works under `set -eu`.

# shellcheck source=forge-api-scan.sh
. "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/forge-api-scan.sh" || {
  echo "${GLFP_TOOL:-glab}: REFUSING: cannot load ai/lib/forge-api-scan.sh, so whether this call runs a fork MR's pipeline is unknown." >&2
  echo "  Fix: run it from a full ~/dev/custom checkout (ai/bin, ai/lib and ai/agent-bin side by side)." >&2
  exit 3
}

# The help rule and the pflag parse it reads (DND-2078), the outbound scan's.
# shellcheck source=outbound-text-scan.sh
. "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/outbound-text-scan.sh" || {
  echo "${GLFP_TOOL:-glab}: REFUSING: cannot load ai/lib/outbound-text-scan.sh, so whether this call asks for help is unknown." >&2
  echo "  Fix: run it from a full ~/dev/custom checkout (ai/bin, ai/lib and ai/agent-bin side by side)." >&2
  exit 3
}

# The pinned glab flag table (DND-1976), the one the outbound scan reads. A
# table that is missing or does not define LFT_FLAGS refuses every command it
# would be read for (glfp_table), never a guess at the flags.
GLFP_TABLE_OK=""
# shellcheck source=glab-flag-table.sh
if . "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/glab-flag-table.sh" 2>/dev/null \
  && declare -p LFT_FLAGS >/dev/null 2>&1; then
  GLFP_TABLE_OK=1
fi

GLFP_TOOL="${GLFP_TOOL:-glab-athena}"
GLFP_MUTATIONS="pipelineCreate|pipelineRetry|pipelineSchedulePlay|pipelineScheduleCreate|pipelineScheduleUpdate|jobRetry|jobPlay|mergeRequestCreatePipeline|mergeTrainsAddCar|mergeRequestAccept"
GLFP_NEVER="never run a fork MR's pipeline in the parent project: by GitLab default it runs in the fork, without our runners or variables, and that is where it belongs (athena:gitlab -> Fork MR pipelines). Do not retry it another way (plain glab, curl, the web UI, another ref); if the contribution must be tested here, report it to your admiral with the MR, and leave the decision to Cody"
GLFP_LOOKFIX="make the object readable (right project, right id, network up) and re-run; never run the call another way while this cannot be checked"

# The flags of each command judged here outside the pinned table, in its
# <kind>:<short>:<long> form (v takes a value, b is a switch), read from glab
# 1.92.1's --help. The parse (glfp_cli_parse, fas_parse_api) and the help rule
# (glfp_help) both read these.
GLFP_T_CI_RUN=' v:b:branch v:i:input v:R:repo v::variables v::variables-env v::variables-file v:f:variables-from b::mr b:w:web b:h:help '
GLFP_T_CI_RUNTRIG=' v:b:branch v:i:input v:R:repo v:t:token v::variables b:h:help '
GLFP_T_CI_RETRY=' v:b:branch v:p:pipeline-id v:R:repo b:h:help '
GLFP_T_SCHED_RUN=' v:R:repo b:h:help '
GLFP_T_SCHED_CREATE=' v::ref v::cron v::cronTimeZone v::description v:R:repo v::variable b::active b:h:help '
GLFP_T_SCHED_UPDATE=' v::ref v::cron v::cronTimeZone v::description v:R:repo v::create-variable v::update-variable v::delete-variable b::active b:h:help '
# `glab api` (glab 1.92 and 1.112 agree on these).
GLFP_T_API=' v:X:method v:F:field v:f:raw-field v:H:header v::input v::form v::hostname v::output b:i:include b::paginate b::silent b:h:help '

glfp_refuse() {
  # $1 what was refused, $2 why, $3 the Fix: text
  printf '%s: REFUSING `%s`: %s (DND-1942)\n  Fix: %s.\n' "$GLFP_TOOL" "$1" "$2" "$3" >&2
  exit 3
}

# glfp_dec <text> : echoes <text> %-decoded once; returns 1 on a malformed
# escape or a control character.
glfp_dec() {
  local s="$1"
  if [[ "$s" == *%* ]]; then
    [[ "$s" =~ %([^0-9A-Fa-f]|[0-9A-Fa-f][^0-9A-Fa-f]|[0-9A-Fa-f]?$) ]] && return 1
    s="$(printf '%b' "${s//%/\\x}")"
  fi
  [[ "$s" == *[[:cntrl:]]* ]] && return 1
  printf '%s' "$s"
}

# glfp_read <what> <path> [hostname] : sets GLFP_JSON to the API answer for
# <path>, read with GLFP_GLAB; refuses COULD NOT LOOK on a failed read.
glfp_read() {
  local what="$1" path="$2" host="${3:-}" err rc why
  local -a cmd=(api)
  [ -n "$host" ] && cmd+=(--hostname "$host")
  cmd+=("$path")
  err="$(mktemp)" || glfp_refuse "$GLFP_SHOWN" "COULD NOT LOOK: no scratch file for reading $what" "check that \$TMPDIR (or /tmp) is writable, then re-run"
  if GLFP_JSON="$("${GLFP_GLAB:-glab}" "${cmd[@]}" 2>"$err")"; then rc=0; else rc=$?; fi
  why="$(head -c 300 "$err" | tr '\n' ' ')"; rm -f "$err"
  if [ "$rc" != 0 ]; then
    glfp_refuse "$GLFP_SHOWN" "COULD NOT LOOK: could not read $what (\`glab api $path\` exit $rc: ${why:-no output}), so whether it belongs to a fork MR is unknown" "$GLFP_LOOKFIX"
  fi
  return 0
}

# glfp_check_mr <project> <iid> <host> : refuses when MR <iid> of <project> is a
# fork MR or its project ids cannot be read.
glfp_check_mr() {
  local p="$1" iid="$2" host="$3" src tgt
  glfp_read "!$iid" "projects/$p/merge_requests/$iid" "$host"
  if ! jq -e --argjson i "$iid" '.iid == $i' >/dev/null 2>&1 <<<"$GLFP_JSON"; then
    glfp_refuse "$GLFP_SHOWN" "COULD NOT LOOK: the MR read back for !$iid is not !$iid ($(head -c 200 <<<"$GLFP_JSON" | tr '\n' ' ')), so whether it is a fork MR is unknown" "$GLFP_LOOKFIX"
  fi
  if ! jq -e '(.source_project_id | type == "number") and (.target_project_id | type == "number")' >/dev/null 2>&1 <<<"$GLFP_JSON"; then
    glfp_refuse "$GLFP_SHOWN" "COULD NOT LOOK: !$iid as read has no numeric source_project_id and target_project_id ($(head -c 200 <<<"$GLFP_JSON" | tr '\n' ' ')), so whether it is a fork MR is unknown" "$GLFP_LOOKFIX"
  fi
  src="$(jq -r .source_project_id <<<"$GLFP_JSON")"; tgt="$(jq -r .target_project_id <<<"$GLFP_JSON")"
  if [ "$src" != "$tgt" ]; then
    glfp_refuse "$GLFP_SHOWN" "FORK MR: !$iid's source project $src is not its target project $tgt, so its pipeline would run the fork's code and CI file on this project's runners" "$GLFP_NEVER"
  fi
  return 0
}

# glfp_check_ref <project> <ref> <host> [given] : a ref that names an MR is
# judged as that MR. With `given` (a ref the caller named), any other ref must
# be an existing branch or tag of the project; without it (a ref GitLab
# itself recorded on a job, pipeline or schedule), it passes.
glfp_check_ref() {
  local p="$1" ref="$2" host="$3" given="${4:-}"
  if [[ "${ref,,}" =~ (^|/)merge-requests(/|$) ]]; then
    if [[ "${ref,,}" =~ (^|/)merge-requests/([0-9]+)(/|$) ]]; then
      glfp_check_mr "$p" "${BASH_REMATCH[2]}" "$host"
      return 0
    fi
    glfp_refuse "$GLFP_SHOWN" "COULD NOT LOOK: the ref '$ref' has a merge-requests segment but no numeric MR iid after it, so whose code it runs is unknown" "pass a branch, or the MR ref exactly as refs/merge-requests/<iid>/head"
  fi
  [ "$given" = given ] || return 0
  glfp_branch_or_tag "$p" "$ref" "$host"
}

# glfp_branch_or_tag <project> <ref> <host> : returns 0 when <ref> is, by its
# exact name, a branch or a tag of the project as read; refuses otherwise.
glfp_branch_or_tag() {
  local p="$1" ref="$2" host="$3" enc kind out
  local -a cmd
  if [ -z "$ref" ] || ! enc="$(jq -rn --arg r "$ref" '$r | @uri' 2>/dev/null)" || [ -z "$enc" ]; then
    glfp_refuse "$GLFP_SHOWN" "COULD NOT LOOK: the ref '$ref' is empty or could not be URL-encoded (jq failed), so it cannot be read" "pass a branch or tag name; make jq work on PATH (\`jq --version\`)"
  fi
  for kind in branches tags; do
    cmd=(api)
    [ -n "$host" ] && cmd+=(--hostname "$host")
    cmd+=("projects/$p/repository/$kind/$enc")
    if out="$("${GLFP_GLAB:-glab}" "${cmd[@]}" 2>/dev/null)" \
      && jq -e --arg r "$ref" 'type == "object" and .name == $r' >/dev/null 2>&1 <<<"$out"; then
      return 0
    fi
  done
  glfp_refuse "$GLFP_SHOWN" "COULD NOT LOOK: the ref '$ref' is not, as read, a branch or a tag of this project (or the read failed); a commit sha, refs/keep-around/<sha> or another ref can name a fork MR's head, whose commits GitLab keeps here, so whose code it runs is unknown" "pass a branch or tag name of this project (to build from a commit, push a branch with \`glab-athena git push\` first and pass its name), or an MR ref as refs/merge-requests/<iid>/head"
}

# glfp_check_obj <what> <project> <path> <host> : reads a job, pipeline or
# schedule and judges its ref. A pipeline whose source is merge_request_event
# must carry an MR ref.
glfp_check_obj() {
  local what="$1" p="$2" path="$3" host="$4" ref src
  glfp_read "$what" "$path" "$host"
  ref="$(jq -r 'if type == "object" and (.ref | type == "string") then .ref else empty end' <<<"$GLFP_JSON" 2>/dev/null)" || ref=""
  if [ -z "$ref" ]; then
    glfp_refuse "$GLFP_SHOWN" "COULD NOT LOOK: $what as read has no ref ($(head -c 200 <<<"$GLFP_JSON" | tr '\n' ' ')), so whose code it runs is unknown" "$GLFP_LOOKFIX"
  fi
  src="$(jq -r '(.source // .pipeline.source // "") | strings' <<<"$GLFP_JSON" 2>/dev/null)" || src=""
  if [ "$src" = merge_request_event ] && ! [[ "${ref,,}" =~ (^|/)merge-requests/[0-9]+(/|$) ]]; then
    glfp_refuse "$GLFP_SHOWN" "COULD NOT LOOK: $what is a merge_request_event pipeline but its ref '$ref' names no MR" "$GLFP_LOOKFIX"
  fi
  glfp_check_ref "$p" "$ref" "$host"
}

# ---- glab api ----------------------------------------------------------------

# glfp_api_ref <endpoint> : sets GLFP_REF/GLFP_NREF from the ref fields and the
# query string; refuses when a ref cannot be read.
glfp_api_ref() {
  local ep="$1" q kv k v i
  GLFP_REF="" GLFP_NREF=0
  if [ -n "$FAS_INPUT" ]; then
    glfp_refuse "$GLFP_SHOWN" "COULD NOT LOOK: the body comes from --input, which this does not read, so the ref is unknown" "pass the ref as a field (-f ref=<ref>)"
  fi
  for i in "${!FAS_FKEY[@]}"; do
    [ "${FAS_FKEY[$i]}" = ref ] || continue
    case "${FAS_FKIND[$i]}" in
      file|formfile) glfp_refuse "$GLFP_SHOWN" "COULD NOT LOOK: the ref field is read from a file, which this does not read" "pass it inline (-f ref=<ref>)" ;;
    esac
    GLFP_REF="${FAS_FVAL[$i]}"; GLFP_NREF=$((GLFP_NREF+1))
  done
  if [[ "$ep" == *\?* ]]; then
    q="${ep#*\?}"; q="${q%%#*}"
    if [[ "$q" == *\;* ]]; then
      glfp_refuse "$GLFP_SHOWN" "COULD NOT LOOK: the query string holds a ';', which some servers read as a parameter separator, so which ref GitLab reads is unknown" "drop the ';' and pass the ref as a field (-f ref=<ref>)"
    fi
    local -a kvs=()
    IFS='&' read -ra kvs <<<"$q"
    for kv in "${kvs[@]}"; do
      k="${kv%%=*}"; v=""; [[ "$kv" == *=* ]] && v="${kv#*=}"
      if ! k="$(glfp_dec "${k//+/ }")" || ! v="$(glfp_dec "${v//+/ }")"; then
        glfp_refuse "$GLFP_SHOWN" "COULD NOT LOOK: the query string cannot be decoded" "spell the query plainly, or pass the ref as a field (-f ref=<ref>)"
      fi
      if [ "$k" = ref ]; then GLFP_REF="$v"; GLFP_NREF=$((GLFP_NREF+1)); fi
    done
  fi
  if [ "$GLFP_NREF" -gt 1 ]; then
    glfp_refuse "$GLFP_SHOWN" "COULD NOT LOOK: the ref is given $GLFP_NREF times, and which one GitLab uses is not judged" "pass the ref once"
  fi
  return 0
}

# glfp_api <args after the word api...>
glfp_api() {
  local ep path lower last method write=1 sc raw seg d p host
  local -a segs rest
  glfp_help "$GLFP_T_API" "$@" && return 0
  glfp_lists "$GLFP_T_API"
  FAS_API_VALUED="$GLFP_TLV" FAS_API_BOOL="$GLFP_TLB"
  FAS_API_SVALUED="$GLFP_TSV" FAS_API_SBOOL="$GLFP_TSB"
  if ! fas_parse_api "$@"; then
    glfp_refuse "glab api" "'$FAS_UNKNOWN' is not a \`glab api\` flag this knows, so it cannot tell how the call parses or whether it runs a fork MR's pipeline" "drop the flag (glab rejects an unknown flag anyway)"
  fi
  method="$FAS_METHOD"
  if [ -z "$method" ]; then
    if [ "$FAS_NPARAMS" -gt 0 ] || [ -n "$FAS_INPUT" ]; then method=POST; else method=GET; fi
  fi
  case "$method" in GET|HEAD) write=0 ;; esac
  [ "$FAS_OVERRIDE" = 1 ] && write=1
  local k; for k in "${FAS_FKEY[@]}"; do [ "$k" = _method ] && write=1; done
  [ "$write" = 1 ] || return 0
  host="$FAS_HOSTNAME"

  for ep in "${FAS_POS[@]}"; do
    GLFP_SHOWN="glab api $method ${ep%%[?#]*}"
    if ! path="$(fas_path "$ep" api v4)"; then
      glfp_refuse "$GLFP_SHOWN" "COULD NOT LOOK: the endpoint cannot be normalized (a backslash, a control character, or a malformed or nested %-escape), so whether it runs a pipeline is unknown" "spell the endpoint plainly (projects/<id>/…)"
    fi
    lower="${path,,}"
    last="${lower##*/}"; last="${last%%[.;]*}"
    if [ "$last" = graphql ]; then
      if fas_graphql_scan "$GLFP_MUTATIONS"; then sc=0; else sc=$?; fi
      case "$sc" in
        0) glfp_refuse "$GLFP_SHOWN" "this GraphQL call carries '$FAS_FOUND', which creates, runs or retries a pipeline or job, and its MR is not read here" "use the REST route, which is judged (e.g. \`glab-athena api -X POST projects/:id/merge_requests/<iid>/pipelines\`)" ;;
        2) glfp_refuse "$GLFP_SHOWN" "COULD NOT LOOK: whether this GraphQL call runs a pipeline is unknown: $FAS_WHY" "$FAS_HOW" ;;
      esac
      continue
    fi
    lower="${lower%/*}/$last"
    [[ "$lower" == projects/* ]] || continue
    # The normalised path, loosely: does it end like a judged route?
    if ! [[ "$lower" =~ (/merge_requests/[^/]+/pipelines|/pipelines?|/trigger/pipeline|/jobs/[^/]+/(retry|play)|/pipelines/[^/]+/retry|/pipeline_schedules(/[^/]+)?|/pipeline_schedules/[^/]+/play|/merge_trains/merge_requests/[^/]+|/repository/(branches|tags)|/releases)$ ]]; then
      continue
    fi
    # A DELETE (no override) of a schedule or train car runs nothing.
    if [ "$method" = DELETE ] && [ "$FAS_OVERRIDE" = 0 ] && [[ " ${FAS_FKEY[*]} " != *" _method "* ]]; then
      case "$lower" in */pipeline_schedules/*|*/merge_trains/*) continue ;; esac
    fi
    # The raw shape: projects/<p>/<route words>, each segment decoded alone.
    raw="${ep%%[?#]*}"
    [[ "$raw" =~ ^[A-Za-z][A-Za-z0-9+.-]*://[^/]*(.*)$ ]] && raw="${BASH_REMATCH[1]}"
    IFS=/ read -ra segs <<<"$raw"
    rest=()
    for seg in "${segs[@]}"; do [ -n "$seg" ] && rest+=("$seg"); done
    [ "${#rest[@]}" -gt 0 ] && [ "${rest[0],,}" = api ] && rest=("${rest[@]:1}")
    [ "${#rest[@]}" -gt 0 ] && [ "${rest[0],,}" = v4 ] && rest=("${rest[@]:1}")
    local -a dw=()
    local bad=0
    for seg in "${rest[@]}"; do
      if ! d="$(glfp_dec "$seg")"; then bad=1; break; fi
      case "$d" in .|..) bad=1; break ;; esac
      dw+=("${d,,}")
    done
    if [ "$bad" = 0 ] && [ "${#dw[@]}" -ge 3 ]; then
      dw[-1]="${dw[-1]%%[.;]*}"
      p="${rest[1]}"
    else
      bad=1
    fi
    local shape=""
    if [ "$bad" = 0 ] && [ "${dw[0]}" = projects ]; then
      local w="${dw[*]:2}"
      case "$w" in
        "merge_requests "*" pipelines") [ "${#dw[@]}" = 5 ] && [[ "${dw[3]}" =~ ^[0-9]+$ ]] && shape=mrpipe ;;
        pipeline|pipelines) shape=create ;;
        "trigger pipeline") shape=create ;;
        "ref "*" trigger pipeline") [ "${#dw[@]}" = 6 ] && shape=reftrigger ;;
        "jobs "*" retry"|"jobs "*" play") [ "${#dw[@]}" = 5 ] && [[ "${dw[3]}" =~ ^[0-9]+$ ]] && shape=job ;;
        "pipelines "*" retry") [ "${#dw[@]}" = 5 ] && [[ "${dw[3]}" =~ ^[0-9]+$ ]] && shape=pipeline ;;
        pipeline_schedules) shape=create ;;
        "pipeline_schedules "*" play") [ "${#dw[@]}" = 5 ] && [[ "${dw[3]}" =~ ^[0-9]+$ ]] && shape=schedule ;;
        "pipeline_schedules "*) [ "${#dw[@]}" = 4 ] && [[ "${dw[3]}" =~ ^[0-9]+$ ]] && shape=create ;;
        "merge_trains merge_requests "*) [ "${#dw[@]}" = 5 ] && [[ "${dw[4]}" =~ ^[0-9]+$ ]] && shape=train ;;
        "repository branches"|"repository tags"|releases) shape=create ;;
      esac
    fi
    if [ -z "$shape" ]; then
      glfp_refuse "$GLFP_SHOWN" "COULD NOT LOOK: the endpoint reads as a pipeline or job route once normalized ($path), but its raw form is not exactly projects/<project>/<route> (an encoded slash in a route word, a dot segment, or an unencoded project path), so this cannot tell what GitLab routes it to" "spell the endpoint plainly: projects/<id or URL-encoded path>/<route>"
    fi
    case "$shape" in
      mrpipe) glfp_check_mr "$p" "${dw[3]}" "$host" ;;
      train) glfp_check_mr "$p" "${dw[4]}" "$host" ;;
      job) glfp_check_obj "job ${dw[3]}" "$p" "projects/$p/jobs/${dw[3]}" "$host" ;;
      pipeline) glfp_check_obj "pipeline ${dw[3]}" "$p" "projects/$p/pipelines/${dw[3]}" "$host" ;;
      schedule) glfp_check_obj "pipeline schedule ${dw[3]}" "$p" "projects/$p/pipeline_schedules/${dw[3]}" "$host" ;;
      reftrigger)
        glfp_api_ref "$ep"
        if [ "$GLFP_NREF" -gt 0 ]; then
          glfp_refuse "$GLFP_SHOWN" "COULD NOT LOOK: the ref is given in the path and again as a field or query" "pass the ref once"
        fi
        d="$(glfp_dec "${rest[3]}")"
        glfp_check_ref "$p" "$d" "$host" given ;;
      create)
        glfp_api_ref "$ep"
        [ "$GLFP_NREF" = 1 ] && glfp_check_ref "$p" "$GLFP_REF" "$host" given ;;
    esac
  done
  return 0
}

# ---- glab ci / schedule --------------------------------------------------------

# glfp_repo <-R value> : sets GLFP_P (the URL-encoded project, or :id when no
# -R) and GLFP_HOST (from a URL form, or "").
glfp_repo() {
  local r="$1" path
  GLFP_HOST=""
  if [ -z "$r" ]; then GLFP_P=":id"; return 0; fi
  if [[ "$r" =~ ^[A-Za-z][A-Za-z0-9+.-]*://([^@/]*@)?([^/:]+)(:[0-9]+)?/(.+)$ ]]; then
    GLFP_HOST="${BASH_REMATCH[2]}"; path="${BASH_REMATCH[4]}"
  elif [[ "$r" =~ ^[^@/:]+@([^/:]+):(.+)$ ]]; then
    GLFP_HOST="${BASH_REMATCH[1]}"; path="${BASH_REMATCH[2]}"
  else
    path="$r"
  fi
  path="${path%/}"; path="${path%.git}"
  if ! [[ "$path" =~ ^[A-Za-z0-9_.-]+(/[A-Za-z0-9_.-]+)+$ ]]; then
    glfp_refuse "$GLFP_SHOWN" "COULD NOT LOOK: -R '$r' is not a GROUP/PROJECT path or a URL to one, so the project cannot be read" "pass -R <group>/<project>"
  fi
  GLFP_P="${path//\//%2F}"
  return 0
}

# glfp_branch : sets GLFP_BRANCH to the checkout's current branch, or refuses.
glfp_branch() {
  if ! GLFP_BRANCH="$(git symbolic-ref --quiet --short HEAD 2>/dev/null)" || [ -z "$GLFP_BRANCH" ]; then
    glfp_refuse "$GLFP_SHOWN" "COULD NOT LOOK: no -b/--branch was given and the current directory has no checked-out branch, so the ref glab would use is unknown" "pass -b <branch>"
  fi
  return 0
}

# glfp_mr_value <value> : sets GLFP_MR from a --mr=<value>, as glab (a Go bool
# flag, the last occurrence wins) reads it: 1 t T TRUE true True are true; 0 f F
# FALSE false False are false. Any other spelling is refused, so a value this
# does not read as glab does cannot hide an --mr run or fake one.
glfp_mr_value() {
  case "$1" in
    1|t|T|TRUE|true|True) GLFP_MR=1 ;;
    0|f|F|FALSE|false|False) GLFP_MR=0 ;;
    *) glfp_refuse "$GLFP_SHOWN" "COULD NOT LOOK: '--mr=$1' is not a boolean glab reads (1 t T TRUE true True 0 f F FALSE false False), so whether this is an --mr run is unknown" "spell it --mr, --mr=true or --mr=false" ;;
  esac
}

# glfp_cli_parse <valued long flags> <bool long flags> <valued shorts> <bool
# shorts> <args...> : sets GLFP_OPT_<name> for -b/--branch, -p/--pipeline-id,
# -R/--repo, --ref, -t; GLFP_MR (1 on --mr); GLFP_POS; refuses an unknown flag.
glfp_cli_parse() {
  local lv="$1" lb="$2" sv="$3" sb="$4" a v i c rest
  shift 4
  GLFP_BR="" GLFP_BR_N=0 GLFP_PID="" GLFP_REPO="" GLFP_REFOPT="" GLFP_REF_N=0 GLFP_MR=0 GLFP_POS=()
  while [ $# -gt 0 ]; do
    a="$1"; shift
    case "$a" in
      --) GLFP_POS+=("$@"); break ;;
      --*=*)
        if [[ "$lv" == *" ${a%%=*} "* ]]; then glfp_cli_opt "${a%%=*}" "${a#*=}"
        elif [[ "$lb" == *" ${a%%=*} "* ]]; then [ "${a%%=*}" = --mr ] && glfp_mr_value "${a#*=}"
        else glfp_refuse "$GLFP_SHOWN" "'${a%%=*}' is not a flag of this command that this knows (glab 1.92), so it cannot tell how the rest parses" "drop the flag, or put it after a flag it knows"; fi ;;
      --*)
        if [[ "$lv" == *" $a "* ]]; then v="${1:-}"; [ $# -gt 0 ] && shift; glfp_cli_opt "$a" "$v"
        elif [[ "$lb" == *" $a "* ]]; then [ "$a" = --mr ] && GLFP_MR=1
        else glfp_refuse "$GLFP_SHOWN" "'$a' is not a flag of this command that this knows (glab 1.92), so it cannot tell how the rest parses" "drop the flag (glab rejects an unknown flag anyway)"; fi ;;
      -?*)
        rest="${a#-}"; i=0
        while [ "$i" -lt "${#rest}" ]; do
          c="${rest:$i:1}"
          if [[ "$sb" == *"$c"* ]]; then :
          elif [[ "$sv" == *"$c"* ]]; then
            v="${rest:$((i+1))}"; v="${v#=}"
            if [ -z "$v" ]; then v="${1:-}"; [ $# -gt 0 ] && shift; fi
            case "$c" in
              b) glfp_cli_opt --branch "$v" ;;
              p) glfp_cli_opt --pipeline-id "$v" ;;
              R) glfp_cli_opt --repo "$v" ;;
              r) glfp_cli_opt --ref "$v" ;;
            esac
            break
          else glfp_refuse "$GLFP_SHOWN" "'-$c' is not a flag of this command that this knows (glab 1.92), so it cannot tell how the rest parses" "drop the flag (glab rejects an unknown flag anyway)"; fi
          i=$((i+1))
        done ;;
      *) GLFP_POS+=("$a") ;;
    esac
  done
  return 0
}

glfp_cli_opt() {
  case "$1" in
    --branch) GLFP_BR="$2"; GLFP_BR_N=$((GLFP_BR_N+1)) ;;
    --pipeline-id) GLFP_PID="$2" ;;
    --repo) GLFP_REPO="$2" ;;
    --ref) GLFP_REFOPT="$2"; GLFP_REF_N=$((GLFP_REF_N+1)) ;;
  esac
  return 0
}

# glfp_ci <verb> <args...> : `glab ci|pipe|pipeline <verb> …`.
glfp_ci() {
  local verb="$1" mrs n t
  shift
  case "$verb" in
    run|create) verb=run; t="$GLFP_T_CI_RUN" ;;
    run-trig) t="$GLFP_T_CI_RUNTRIG" ;;
    retry|trigger) t="$GLFP_T_CI_RETRY" ;;
    *) return 0 ;;
  esac
  glfp_help "$t" "$@" && return 0
  glfp_lists "$t"
  glfp_cli_parse "$GLFP_TLV" "$GLFP_TLB" "$GLFP_TSV" "$GLFP_TSB" "$@"
  glfp_repo "$GLFP_REPO"
  if [ "$GLFP_BR_N" -gt 1 ]; then
    glfp_refuse "$GLFP_SHOWN" "COULD NOT LOOK: -b/--branch is given $GLFP_BR_N times" "pass -b once"
  fi
  case "$verb" in
    run|run-trig)
      if [ -z "$GLFP_BR" ]; then glfp_branch; GLFP_BR="$GLFP_BRANCH"; fi
      # With --mr the branch only finds the MR, whose pipeline runs on its own
      # ref; without it the branch IS the pipeline's ref.
      if [ "$verb" = run ] && [ "$GLFP_MR" = 1 ]; then
        glfp_check_ref "$GLFP_P" "$GLFP_BR" "$GLFP_HOST"
      else
        glfp_check_ref "$GLFP_P" "$GLFP_BR" "$GLFP_HOST" given
      fi
      if [ "$verb" = run ] && [ "$GLFP_MR" = 1 ]; then
        # glab finds the MR by its source branch: judge every MR that has it.
        # glab reads OWNER:BRANCH and lists MRs by the BRANCH part
        # (mrutils resolveOwnerAndBranch: split on ':', take the second).
        local enc srcb="$GLFP_BR"
        if [[ "$srcb" == *:* ]]; then srcb="${srcb#*:}"; srcb="${srcb%%:*}"; fi
        enc="$(jq -rn --arg b "$srcb" '$b | @uri' 2>/dev/null)" || enc=""
        [ -n "$enc" ] || glfp_refuse "$GLFP_SHOWN" "COULD NOT LOOK: the branch name could not be URL-encoded (jq failed)" "make jq work on PATH (\`jq --version\`)"
        local -a cmd=(api)
        [ -n "$GLFP_HOST" ] && cmd+=(--hostname "$GLFP_HOST")
        cmd+=(--paginate "projects/$GLFP_P/merge_requests?source_branch=$enc&per_page=100")
        local err rc why
        err="$(mktemp)" || glfp_refuse "$GLFP_SHOWN" "COULD NOT LOOK: no scratch file" "check that \$TMPDIR (or /tmp) is writable, then re-run"
        if mrs="$("${GLFP_GLAB:-glab}" "${cmd[@]}" 2>"$err")"; then rc=0; else rc=$?; fi
        why="$(head -c 300 "$err" | tr '\n' ' ')"; rm -f "$err"
        if [ "$rc" != 0 ] || ! mrs="$(jq -cs '[.[] | if type == "array" then .[] else . end]' <<<"$mrs" 2>/dev/null)"; then
          glfp_refuse "$GLFP_SHOWN" "COULD NOT LOOK: the MRs with source branch '$srcb' could not be read (exit $rc: ${why:-not JSON}), so whether --mr picks a fork MR is unknown" "$GLFP_LOOKFIX"
        fi
        if ! jq -e 'all(.[]; type == "object" and (.source_project_id | type == "number") and (.target_project_id | type == "number"))' >/dev/null 2>&1 <<<"$mrs"; then
          glfp_refuse "$GLFP_SHOWN" "COULD NOT LOOK: an MR with source branch '$srcb' has no numeric source_project_id and target_project_id" "$GLFP_LOOKFIX"
        fi
        n="$(jq -r '[.[] | select(.source_project_id != .target_project_id) | "!\(.iid)"] | join(" ")' <<<"$mrs")"
        if [ -n "$n" ]; then
          glfp_refuse "$GLFP_SHOWN" "FORK MR: --mr picks an MR whose source branch is '$srcb', and $n comes from a fork, so its pipeline would run the fork's code and CI file on this project's runners" "$GLFP_NEVER"
        fi
      fi ;;
    retry|trigger)
      if [[ "${GLFP_POS[0]:-}" =~ ^[0-9]+$ ]]; then
        glfp_check_obj "job ${GLFP_POS[0]}" "$GLFP_P" "projects/$GLFP_P/jobs/${GLFP_POS[0]}" "$GLFP_HOST"
      elif [[ "$GLFP_PID" =~ ^[0-9]+$ ]]; then
        glfp_check_obj "pipeline $GLFP_PID" "$GLFP_P" "projects/$GLFP_P/pipelines/$GLFP_PID" "$GLFP_HOST"
      else
        glfp_refuse "$GLFP_SHOWN" "COULD NOT LOOK: with no numeric job id and no -p <pipeline id>, glab picks the job itself, so whose pipeline it belongs to is unknown" "pass the numeric job id (\`glab ci get -F json\` lists them), or -p <pipeline id> with the job name"
      fi ;;
  esac
  return 0
}

# glfp_schedule <verb> <args...> : `glab schedule|sched|skd <verb> …`.
glfp_schedule() {
  local verb="$1" t
  shift
  case "$verb" in
    run) t="$GLFP_T_SCHED_RUN" ;;
    create) t="$GLFP_T_SCHED_CREATE" ;;
    update) t="$GLFP_T_SCHED_UPDATE" ;;
    *) return 0 ;;
  esac
  glfp_help "$t" "$@" && return 0
  glfp_lists "$t"
  glfp_cli_parse "$GLFP_TLV" "$GLFP_TLB" "$GLFP_TSV" "$GLFP_TSB" "$@"
  case "$verb" in
    run)
      glfp_repo "$GLFP_REPO"
      if ! [[ "${GLFP_POS[0]:-}" =~ ^[0-9]+$ ]]; then
        glfp_refuse "$GLFP_SHOWN" "COULD NOT LOOK: no numeric schedule id" "pass the schedule id: \`glab schedule run <id>\`"
      fi
      glfp_check_obj "pipeline schedule ${GLFP_POS[0]}" "$GLFP_P" "projects/$GLFP_P/pipeline_schedules/${GLFP_POS[0]}" "$GLFP_HOST" ;;
    create|update)
      glfp_repo "$GLFP_REPO"
      if [ "$GLFP_REF_N" -gt 1 ]; then glfp_refuse "$GLFP_SHOWN" "COULD NOT LOOK: --ref is given $GLFP_REF_N times" "pass --ref once"; fi
      [ "$GLFP_REF_N" = 1 ] && glfp_check_ref "$GLFP_P" "$GLFP_REFOPT" "$GLFP_HOST" given ;;
  esac
  return 0
}

# glfp_table <command> : sets GLFP_TLV, GLFP_TLB (long valued and switch
# flags, space-delimited) and GLFP_TSV, GLFP_TSB (their short letters) from the
# pinned table's entry for <command>; refuses when the table or the entry is
# missing.
glfp_table() {
  if [ -z "$GLFP_TABLE_OK" ] || [ -z "${LFT_FLAGS[$1]+x}" ]; then
    glfp_refuse "$GLFP_SHOWN" "COULD NOT LOOK: the pinned glab flag table (ai/lib/glab-flag-table.sh) is missing, does not define LFT_FLAGS, or has no \`$1\`, so this argv cannot be read the way glab reads it" "run it from a full ~/dev/custom checkout; if the file is damaged, regenerate it with \`ai/bin/cli-flag-table --cli glab --write\`"
  fi
  glfp_lists "${LFT_FLAGS[$1]}"
}

# glfp_lists <table> : sets GLFP_TLV, GLFP_TLB, GLFP_TSV, GLFP_TSB (see
# glfp_table) from a <kind>:<short>:<long> table.
glfp_lists() {
  local e kind short long
  GLFP_TLV=" " GLFP_TLB=" " GLFP_TSV="" GLFP_TSB=""
  for e in $1; do
    IFS=: read -r kind short long <<<"$e"
    case "$kind" in
      v) GLFP_TLV+="--$long "; GLFP_TSV+="$short" ;;
      b) GLFP_TLB+="--$long "; GLFP_TSB+="$short" ;;
    esac
  done
  return 0
}

# glfp_help <table> <args...> : 0 when the argv asks for help, by the outbound
# scan's rule (ots_help_asked) over a strict pflag parse with <table>. An argv
# the parse cannot read (a flag the table lacks) is not help: it is judged.
glfp_help() {
  local t="$1"
  shift
  ots_pflag_parse strict "$t" 0 "$@" || return 1
  ots_help_asked
}

# glfp_release <args...> : `glab release create <tag> [files] --ref <r>`, its
# flags read from the pinned table.
glfp_release() {
  glfp_table "release create"
  glfp_help "${LFT_FLAGS[release create]}" "$@" && return 0
  glfp_cli_parse "$GLFP_TLV" "$GLFP_TLB" "$GLFP_TSV" "$GLFP_TSB" "$@"
  glfp_repo "$GLFP_REPO"
  if [ "$GLFP_REF_N" -gt 1 ]; then glfp_refuse "$GLFP_SHOWN" "COULD NOT LOOK: --ref is given $GLFP_REF_N times" "pass --ref once"; fi
  [ "$GLFP_REF_N" = 1 ] && glfp_check_ref "$GLFP_P" "$GLFP_REFOPT" "$GLFP_HOST" given
  return 0
}

# glfp_guard <glab args...> : the entry point. Returns 0 or exits 3.
glfp_guard() {
  local a i=0 grp="" verb="" gi=-1 vi=-1 pre="" w
  local -a argv=("$@")
  GLFP_SHOWN="glab"
  # The command path: the first two positional words, skipping -R/--repo and
  # its value. Any other flag before the path can change how glab's command
  # walk routes (see glab-merge-guard.sh, glmg_prepath_flag), so it is refused
  # when the argv could be a pipeline call.
  while [ "$i" -lt "${#argv[@]}" ]; do
    a="${argv[$i]}"
    case "$a" in
      -R|--repo) i=$((i+2)); continue ;;
      -R?*|--repo=*) ;;
      -*) if [ -z "$verb" ] && [ -z "$pre" ]; then pre="$a"; fi ;;
      *)
        if [ -z "$grp" ]; then grp="$a"; gi="$i"
        elif [ -z "$verb" ]; then verb="$a"; vi="$i"; fi ;;
    esac
    # `api` is a one-word path: what follows it is api flags and the endpoint.
    [ -n "$verb" ] || [ "$grp" = api ] && break
    i=$((i+1))
  done
  if [ -n "$pre" ]; then
    for w in "$@"; do
      case "$w" in
        api|ci|pipe|pipeline|schedule|sched|skd|release)
          GLFP_SHOWN="glab ${grp:-…} ${verb:-}"
          glfp_refuse "$GLFP_SHOWN" "'$pre' comes before the command and is not -R/--repo, and glab's command walk can read it differently from this guard, so it cannot tell whether the call runs a fork MR's pipeline" "put the command first and every flag after it (\`glab-athena ci run -b <branch>\`, \`glab-athena api <endpoint> …\`)" ;;
      esac
    done
    return 0
  fi
  GLFP_SHOWN="glab $grp $verb"
  case "$grp" in
    api)
      [ "$gi" = 0 ] || glfp_refuse "glab api" "\`api\` is not the first word, so the api flags cannot be read the way glab reads them" "put \`api\` first: \`glab-athena api <endpoint> [flags]\`"
      glfp_api "${argv[@]:1}" ;;
    ci|pipe|pipeline)
      [ -n "$verb" ] || return 0
      # Flags anywhere but the path words, with -R/--repo kept.
      glfp_ci "$verb" "${argv[@]:0:$gi}" "${argv[@]:$((gi+1)):$((vi-gi-1))}" "${argv[@]:$((vi+1))}" ;;
    release)
      [ "$verb" = create ] || return 0
      glfp_release "${argv[@]:0:$gi}" "${argv[@]:$((gi+1)):$((vi-gi-1))}" "${argv[@]:$((vi+1))}" ;;
    schedule|sched|skd)
      [ -n "$verb" ] || return 0
      glfp_schedule "$verb" "${argv[@]:0:$gi}" "${argv[@]:$((gi+1)):$((vi-gi-1))}" "${argv[@]:$((vi+1))}" ;;
  esac
  return 0
}
