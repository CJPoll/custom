#!/usr/bin/env bash
# Self-test for the fork MR pipeline refusal (DND-1942), in both places it
# runs: ai/bin/glab-athena and the agent PATH glab wrapper (ai/agent-bin/glab,
# through ai/lib/agent-forge-cli.sh).
#
# The defect this pins: both wrappers ran any call that creates, runs, retries
# or plays a pipeline, whatever MR it belonged to. A fork MR's pipeline run in
# the parent project runs the FORK's code, and the fork's own .gitlab-ci.yml,
# on the parent's runners. The Athena bot is a Developer+ member of the parent
# and acts on untrusted input, so `glab-athena api -X POST
# projects/:id/merge_requests/<iid>/pipelines` on a fork MR was one call away.
# The wrappers now read the MR's source_project_id and target_project_id and
# refuse when they differ, or when either cannot be read (COULD NOT LOOK).
# Design and residuals: the header of ai/lib/glab-fork-pipeline-guard.sh.
# Old-vs-new evidence: SABOTAGE_RECORDS.md next to this file.
#
# NO NETWORK, EVER. `glab` is a stub on PATH. It answers the guard's reads (an
# MR, a job, a pipeline, a schedule, an MR list by source branch) from fixture
# files and records every OTHER call as an exec. Every refusal asserts that
# nothing was exec'd; every allowed call asserts exactly one exec.
#
# Gated: ai/bin/harness-gate runs every tracked **/self-test.sh.
#
# Fail-first seam: AGENT_FORGE_ROOT_UNDER_TEST=<dir> runs the wrappers from
# <dir>/ai instead of this checkout's.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO="$(cd "${HERE}/../../.." && pwd -P)"
ROOT="${AGENT_FORGE_ROOT_UNDER_TEST:-${REPO}}"
WRAPPER="${ROOT}/ai/bin/glab-athena"
WBIN="${ROOT}/ai/agent-bin"

TMP="$(mktemp -d)" || { echo "FAIL: mktemp"; exit 1; }
trap 'rm -rf "${TMP}"' EXIT INT TERM
PASS=0; FAIL=0
ok()  { printf '  ok    %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  FAIL  %s\n        %s\n' "$1" "$2"; FAIL=$((FAIL+1)); }

# ---- hermetic environment ---------------------------------------------------
unset GLAB_ATHENA_MERGE_DRY_RUN GLAB_ATHENA_GIT_DRY_RUN ATHENA_AGENT_GLAB_SEEN ATHENA_AGENT_BIN \
  GITLAB_TOKEN GLAB_CONFIG_DIR GITLAB_HOST GITLAB_URI GITLAB_API_HOST
for v in $(env | sed -n 's/^\(GIT_CONFIG_\(KEY\|VALUE\)_[0-9]*\)=.*/\1/p'); do unset "$v"; done
unset GIT_CONFIG_COUNT GIT_CONFIG_PARAMETERS GIT_DIR GIT_WORK_TREE
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL="${TMP}/gitconfig"
printf '[init]\n\tdefaultBranch = main\n' > "${GIT_CONFIG_GLOBAL}"
FAKE_TOKEN="glpat-SELFTESTFAKETOKEN0000"
printf '%s\n' "${FAKE_TOKEN}" > "${TMP}/token"; chmod 600 "${TMP}/token"
export GITLAB_ATHENA_TOKEN_FILE="${TMP}/token"
export ATHENA_TELEMETRY_DIR="${TMP}/telemetry" ATHENA_SECRETS_ROOT="${TMP}/secrets"

# The base PATH drops every directory that holds an agent wrapper, so the only
# wrapper on PATH is the one a case puts there.
BASEPATH=
IFS=: read -r -a _dirs <<< "${PATH}"
for d in "${_dirs[@]}"; do
  if [ -f "${d}/glab" ] && grep -q '(agent wrapper)' "${d}/glab" 2>/dev/null; then continue; fi
  BASEPATH="${BASEPATH:+${BASEPATH}:}${d}"
done

FX="${TMP}/fx"; mkdir -p "${FX}" "${TMP}/bin"
export STUB_FX="${FX}" STUB_READS="${TMP}/reads.log" STUB_EXECS="${TMP}/execs.log"

# The stub glab. A read the case staged answers from <fx>/<key>.out (stdout)
# and <key>.rc (exit code, default 0). An unstaged read, and anything else, is
# an EXEC: logged and answered "stub: ran …".
cat > "${TMP}/bin/glab" <<'STUB'
#!/usr/bin/env bash
[ "${GITLAB_TOKEN:-}" = "glpat-SELFTESTFAKETOKEN0000" ] || { echo "stub: GITLAB_TOKEN not the Athena token" >&2; exit 97; }
answer() {
  local k="$1" rc=0
  [ -f "${STUB_FX}/$k.out" ] || [ -f "${STUB_FX}/$k.rc" ] || return 0
  printf '%s\n' "$all" >> "${STUB_READS}"
  [ -f "${STUB_FX}/$k.rc" ] && rc="$(cat "${STUB_FX}/$k.rc")"
  [ -f "${STUB_FX}/$k.out" ] && cat "${STUB_FX}/$k.out"
  exit "$rc"
}
all="$*"
# DND-1938: the outbound scan reads the project's visibility before a write. Answered
# quietly (not logged as a guard read), as a private project: nothing to scan.
if [[ "$all" =~ ^api\ (--hostname\ [^\ ]+\ )?projects/[^\ /]+$ ]]; then echo '{"visibility":"private"}'; exit 0; fi
H='(--hostname [^ ]+ )?'
if [[ "$all" =~ ^api\ ${H}projects/[^\ /]+/merge_requests/([0-9]+)$ ]]; then answer "mr-${BASH_REMATCH[2]}"; fi
if [[ "$all" =~ ^api\ ${H}projects/[^\ /]+/jobs/([0-9]+)$ ]]; then answer "job-${BASH_REMATCH[2]}"; fi
if [[ "$all" =~ ^api\ ${H}projects/[^\ /]+/pipelines/([0-9]+)$ ]]; then answer "pl-${BASH_REMATCH[2]}"; fi
if [[ "$all" =~ ^api\ ${H}projects/[^\ /]+/pipeline_schedules/([0-9]+)$ ]]; then answer "sc-${BASH_REMATCH[2]}"; fi
if [[ "$all" =~ ^api\ ${H}projects/[^\ /]+/repository/branches/([^\ /]+)$ ]]; then answer "br-${BASH_REMATCH[2]}"; fi
if [[ "$all" =~ ^api\ ${H}projects/[^\ /]+/repository/tags/([^\ /]+)$ ]]; then answer "tag-${BASH_REMATCH[2]}"; fi
if [[ "$all" =~ ^api\ ${H}--paginate\ projects/[^\ /]+/merge_requests\?source_branch= ]]; then answer mrlist; fi
printf '%s\n' "$all" >> "${STUB_EXECS}"
echo "stub: ran $all"
exit 0
STUB
chmod +x "${TMP}/bin/glab"
# DND-1647: a guard stands behind the stub, so a stub that is missing or not
# executable fails the suite instead of reaching the real glab.
. "${REPO}/ai/lib/forge-stub-guard.sh"
fsg_arm "${TMP}/forge-guard"
fsg_require_stubs "${TMP}/bin" glab
GUARDPATH="${PATH%%:*}"
export PATH="${TMP}/bin:${GUARDPATH}:${BASEPATH}"
PLAIN_PATH="${PATH}"

# A checkout the CLI cases run in: branch `feat`, origin on gitlab.com.
CO="${TMP}/example-app"
git init -q -b main "${CO}"
git -C "${CO}" -c user.name=t -c user.email=t@t -c commit.gpgsign=false commit -q --allow-empty -m one
git -C "${CO}" remote add origin git@gitlab.com:example-group/example-app.git
git -C "${CO}" checkout -q -b feat
cd "${CO}" || exit 2

PARENT=7000001
FORK=8000002
# mr <iid> <source project id|null> [target project id] : stage an MR read.
mr() { printf '{"iid":%s,"source_project_id":%s,"target_project_id":%s}\n' "$1" "$2" "${3:-${PARENT}}" > "${FX}/mr-$1.out"; }
reset_fx() {
  rm -f "${FX}"/*; : > "${STUB_READS}"; : > "${STUB_EXECS}"
  mr 11 "${FORK}"          # a fork MR
  mr 12 "${PARENT}"        # a same-project MR
  # The project's branches and tag, as the API answers them. Any other name
  # (a sha, a keep-around ref) answers 404.
  for b in main feat fix-merge-requests-list; do printf '{"name":"%s"}\n' "$b" > "${FX}/br-$b.out"; done
  printf '{"name":"v0"}\n' > "${FX}/tag-v0.out"
  for k in br-deadbeef br-0123456789abcdef0123456789abcdef01234567 tag-0123456789abcdef0123456789abcdef01234567 br-refs%2Fkeep-around%2F0123456789abcdef0123456789abcdef01234567 tag-refs%2Fkeep-around%2F0123456789abcdef0123456789abcdef01234567 br-v0 tag-main br-nope tag-nope; do
    echo '{"message":"404 Not Found"}' > "${FX}/$k.out"; echo 1 > "${FX}/$k.rc"
  done
}

# run_ga <args...> : glab-athena, the stub glab behind it. Sets OUT, RC.
run_ga() { OUT="$(PATH="${PLAIN_PATH}" "${WRAPPER}" "$@" 2>&1)"; RC=$?; }

# The routed marker glab-athena builds, made by hand: the agent wrapper's own
# check must hold even when the call did not come through glab-athena's guard.
MARK="${TMP}/glab-athena-cfg.ABCDEFGH"; mkdir -p "${MARK}"; chmod 700 "${MARK}"
run_ab() {
  OUT="$(PATH="${WBIN}:${PLAIN_PATH}" GITLAB_TOKEN="${FAKE_TOKEN}" GITLAB_HOST=gitlab.com GLAB_CONFIG_DIR="${MARK}" \
    "${WBIN}/glab" "$@" 2>&1)"; RC=$?
}
# Both on PATH, as in an agent session: glab-athena's glab child is the agent wrapper.
run_both() { OUT="$(PATH="${WBIN}:${PLAIN_PATH}" "${WRAPPER}" "$@" 2>&1)"; RC=$?; }

nexec() { grep -c . "${STUB_EXECS}" 2>/dev/null || true; }

# refused <name> <pattern in output> : exit 3, a Fix: line, the pattern, no exec.
refused() {
  if [ "${RC}" != 3 ]; then bad "$1" "exit ${RC}, want 3; out: ${OUT}"; return; fi
  if ! grep -q 'Fix:' <<<"${OUT}"; then bad "$1" "no Fix: line; out: ${OUT}"; return; fi
  if ! grep -q -- "$2" <<<"${OUT}"; then bad "$1" "output lacks '$2'; out: ${OUT}"; return; fi
  if [ "$(nexec)" != 0 ]; then bad "$1" "something ran: $(cat "${STUB_EXECS}")"; return; fi
  ok "$1"
}
# allowed <name> : exit 0 and exactly one exec, the call itself.
allowed() {
  if [ "${RC}" != 0 ]; then bad "$1" "exit ${RC}, want 0; out: ${OUT}"; return; fi
  if [ "$(nexec)" != 1 ]; then bad "$1" "want exactly one exec, got: $(cat "${STUB_EXECS}")"; return; fi
  ok "$1"
}

FORKMSG='FORK MR'
LOOK='COULD NOT LOOK'

echo "== glab-athena: POST merge_requests/<iid>/pipelines"
reset_fx; run_ga api -X POST "projects/${PARENT}/merge_requests/11/pipelines"
refused "fork MR pipeline create is refused" "${FORKMSG}"
reset_fx; run_ga api -X POST "projects/${PARENT}/merge_requests/12/pipelines"
allowed "same-project MR pipeline create runs"
reset_fx; echo 1 > "${FX}/mr-11.rc"; rm -f "${FX}/mr-11.out"; run_ga api -X POST "projects/${PARENT}/merge_requests/11/pipelines"
refused "an unreadable MR refuses" "${LOOK}: could not read !11"
reset_fx; mr 11 null; run_ga api -X POST "projects/${PARENT}/merge_requests/11/pipelines"
refused "an MR with no source_project_id refuses" "${LOOK}"
reset_fx; printf '{"iid":11,"source_project_id":%s}\n' "${FORK}" > "${FX}/mr-11.out"; run_ga api -X POST "projects/${PARENT}/merge_requests/11/pipelines"
refused "an MR with no target_project_id refuses" "${LOOK}"
reset_fx; run_ga api "projects/${PARENT}/merge_requests/11/pipelines"
allowed "a GET of a fork MR's pipelines is a read and runs"
reset_fx; run_ga api -X POST "/api/v4/projects/:id/merge_requests/11/pipelines.json"
refused "a fork MR pipeline create via /api/v4 and a format suffix is refused" "${FORKMSG}"
reset_fx; run_ga api -X POST "projects/${PARENT}/merge_requests%2F11%2Fpipelines"
refused "an encoded slash in a route word refuses" "${LOOK}"
reset_fx; run_ga api -X POST "projects/${PARENT}/merge_requests/12/../11/pipelines"
refused "a dot segment refuses" "${LOOK}"

echo "== glab-athena: POST pipeline with an MR ref"
reset_fx; run_ga api -X POST "projects/${PARENT}/pipeline" -f ref=refs/merge-requests/11/head
refused "pipeline create on a fork MR's head ref is refused" "${FORKMSG}"
reset_fx; run_ga api "projects/${PARENT}/pipeline" -f ref=refs/merge-requests/11/merge
refused "a field makes it a POST; the merge ref is refused" "${FORKMSG}"
reset_fx; run_ga api -X POST "projects/${PARENT}/pipeline?ref=refs%2Fmerge-requests%2F11%2Fhead"
refused "a ref in the query string is read" "${FORKMSG}"
reset_fx; run_ga api -X POST "projects/${PARENT}/pipeline" -f ref=merge-requests/11/head
refused "an MR ref without refs/ is read" "${FORKMSG}"
reset_fx; run_ga api -X POST "projects/${PARENT}/pipeline" -f ref=refs/merge-requests/12/head
allowed "pipeline create on a same-project MR ref runs"
reset_fx; run_ga api -X POST "projects/${PARENT}/pipeline" -f ref=main
allowed "pipeline create on a branch runs"
[ "$(cat "${STUB_READS}")" = "api projects/${PARENT}/repository/branches/main" ] && ok "a branch ref reads only that branch" || bad "a branch ref reads only that branch" "$(cat "${STUB_READS}")"
reset_fx; echo '{"ref":"refs/merge-requests/12/head"}' > "${TMP}/body.json"; run_ga api -X POST "projects/${PARENT}/pipeline" --input "${TMP}/body.json"
refused "a body from --input refuses" "${LOOK}"
reset_fx; run_ga api -X POST "projects/${PARENT}/pipeline" -f ref=main -f ref=refs/merge-requests/12/head
refused "two refs refuse" "${LOOK}"
reset_fx; run_ga api -X POST "projects/${PARENT}/pipeline" -f ref=refs/merge-requests/x/head
refused "an MR ref with no iid refuses" "${LOOK}"
reset_fx; run_ga api -X POST "projects/${PARENT}/trigger/pipeline" -f token=x -f ref=refs/merge-requests/11/head
refused "a trigger on a fork MR ref is refused" "${FORKMSG}"
reset_fx; run_ga api -X POST "projects/${PARENT}/ref/refs%2Fmerge-requests%2F11%2Fhead/trigger/pipeline" -f token=x
refused "a trigger with the fork MR ref in the path is refused" "${FORKMSG}"

echo "== glab-athena: job retry/play, pipeline retry, schedule play, train boarding"
job() { printf '{"id":%s,"ref":"%s","pipeline":{"id":601,"ref":"%s"}}\n' "$1" "$2" "$2" > "${FX}/job-$1.out"; }
pl()  { printf '{"id":%s,"ref":"%s","source":"%s"}\n' "$1" "$2" "${3:-merge_request_event}" > "${FX}/pl-$1.out"; }
reset_fx; job 501 refs/merge-requests/11/head; run_ga api -X POST "projects/${PARENT}/jobs/501/retry"
refused "retrying a job of a fork MR pipeline is refused" "${FORKMSG}"
reset_fx; job 501 refs/merge-requests/11/head; run_ga api -X POST "projects/${PARENT}/jobs/501/play"
refused "playing a job of a fork MR pipeline is refused" "${FORKMSG}"
reset_fx; job 502 main; run_ga api -X POST "projects/${PARENT}/jobs/502/retry"
allowed "retrying a branch job runs"
reset_fx; echo 1 > "${FX}/job-503.rc"; run_ga api -X POST "projects/${PARENT}/jobs/503/retry"
refused "an unreadable job refuses" "${LOOK}: could not read job 503"
reset_fx; pl 601 refs/merge-requests/11/head; run_ga api -X POST "projects/${PARENT}/pipelines/601/retry"
refused "retrying a fork MR pipeline is refused" "${FORKMSG}"
reset_fx; pl 602 refs/merge-requests/12/head; run_ga api -X POST "projects/${PARENT}/pipelines/602/retry"
allowed "retrying a same-project MR pipeline runs"
reset_fx; pl 603 main merge_request_event; run_ga api -X POST "projects/${PARENT}/pipelines/603/retry"
refused "an MR-event pipeline whose ref names no MR refuses" "${LOOK}"
reset_fx; printf '{"id":701,"ref":"refs/merge-requests/11/head"}\n' > "${FX}/sc-701.out"; run_ga api -X POST "projects/${PARENT}/pipeline_schedules/701/play"
refused "playing a schedule on a fork MR ref is refused" "${FORKMSG}"
reset_fx; run_ga api -X POST "projects/${PARENT}/pipeline_schedules" -f ref=refs/merge-requests/11/head -f cron='0 * * * *' -f description=x
refused "a schedule on a fork MR ref is refused" "${FORKMSG}"
# glab-athena's merge guard (DND-1941) judges train boarding and API ref writes
# first, so these are judged on the agent wrapper alone, where this guard is the check.
reset_fx; run_ab api -X POST "projects/${PARENT}/merge_trains/merge_requests/11" -f sha=0123456789012345678901234567890123456789
refused "boarding a fork MR on the merge train is refused" "${FORKMSG}"
reset_fx; run_ga api graphql -f query='mutation { jobRetry(input: {id: "gid://gitlab/Ci::Build/1"}) { errors } }'
refused "a GraphQL pipeline or job mutation is refused" "GraphQL"

echo "== glab-athena: glab ci"
reset_fx; printf '[{"iid":11,"source_project_id":%s,"target_project_id":%s}]\n' "${FORK}" "${PARENT}" > "${FX}/mrlist.out"; run_ga ci run --mr -b feat
refused "ci run --mr for a branch with a fork MR is refused" "${FORKMSG}"
reset_fx; printf '[{"iid":12,"source_project_id":%s,"target_project_id":%s}]\n' "${PARENT}" "${PARENT}" > "${FX}/mrlist.out"; run_ga ci run --mr -b feat
allowed "ci run --mr for a same-project MR runs"
reset_fx; printf '[{"iid":11,"source_project_id":%s,"target_project_id":%s}]\n' "${FORK}" "${PARENT}" > "${FX}/mrlist.out"; run_ga ci run --mr
refused "ci run --mr reads the current branch" "${FORKMSG}"
grep -q 'source_branch=feat' "${STUB_READS}" && ok "the MR list is read for the current branch" || bad "the MR list is read for the current branch" "$(cat "${STUB_READS}")"
reset_fx; echo 1 > "${FX}/mrlist.rc"; run_ga ci run --mr -b feat
refused "an unreadable MR list refuses" "${LOOK}: the MRs with source branch"
reset_fx; printf '[{"iid":11,"source_project_id":%s,"target_project_id":%s}]\n' "${FORK}" "${PARENT}" > "${FX}/mrlist.out"; run_ga -R example-group/example-app ci run --mr -b feat
refused "-R before the group is honoured" "${FORKMSG}"
grep -q 'projects/example-group%2Fexample-app/merge_requests' "${STUB_READS}" && ok "-R names the project read" || bad "-R names the project read" "$(cat "${STUB_READS}")"
reset_fx; run_ga ci run -b refs/merge-requests/11/head
refused "ci run on a fork MR ref is refused" "${FORKMSG}"
reset_fx; run_ga pipeline run --branch=refs/merge-requests/11/merge
refused "the pipeline alias and --branch= are read" "${FORKMSG}"
reset_fx; run_ga ci run -b main
allowed "ci run on a branch runs"
reset_fx; run_ga ci run-trig -t x -b refs/merge-requests/11/head
refused "ci run-trig on a fork MR ref is refused" "${FORKMSG}"
reset_fx; job 501 refs/merge-requests/11/head; run_ga ci retry 501
refused "ci retry of a fork MR job is refused" "${FORKMSG}"
reset_fx; job 501 refs/merge-requests/11/head; run_ga ci trigger 501
refused "ci trigger of a fork MR job is refused" "${FORKMSG}"
reset_fx; job 502 main; run_ga ci retry 502
allowed "ci retry of a branch job runs"
reset_fx; run_ga ci retry lint
refused "ci retry by job name with no pipeline id refuses" "${LOOK}"
reset_fx; pl 602 refs/merge-requests/12/head; run_ga ci retry lint -p 602
allowed "ci retry by name in a same-project MR pipeline runs"
reset_fx; pl 601 refs/merge-requests/11/head; run_ga pipe trigger lint --pipeline-id 601
refused "ci trigger by name in a fork MR pipeline is refused" "${FORKMSG}"
reset_fx; run_ga ci run --bogus -b main
refused "an unknown ci run flag refuses" "--bogus"
reset_fx; run_ga --bogus ci run -b main
refused "a flag before the command path refuses" "--bogus"
reset_fx; run_ga ci list
allowed "a ci read runs"

echo "== glab-athena: glab schedule"
reset_fx; printf '{"id":701,"ref":"refs/merge-requests/11/head"}\n' > "${FX}/sc-701.out"; run_ga schedule run 701
refused "schedule run on a fork MR ref is refused" "${FORKMSG}"
reset_fx; run_ga schedule create --ref refs/merge-requests/11/head --cron '0 * * * *' --description x
refused "schedule create on a fork MR ref is refused" "${FORKMSG}"
reset_fx; run_ga schedule update 701 --ref=refs/merge-requests/11/head
refused "schedule update to a fork MR ref is refused" "${FORKMSG}"
reset_fx; printf '{"id":702,"ref":"main"}\n' > "${FX}/sc-702.out"; run_ga schedule run 702
allowed "schedule run on a branch runs"

echo "== review round: aliases, glab's OWNER:BRANCH, query separators, refs made from an MR ref"
FORKLIST="$(printf '[{"iid":11,"source_project_id":%s,"target_project_id":%s}]' "${FORK}" "${PARENT}")"
reset_fx; run_ga ci create -b refs/merge-requests/11/head
refused "ci create (glab's alias of ci run) on a fork MR ref is refused" "${FORKMSG}"
reset_fx; echo "${FORKLIST}" > "${FX}/mrlist.out"; run_ga ci create --mr -b feat
refused "ci create --mr for a branch with a fork MR is refused" "${FORKMSG}"
reset_fx; echo "${FORKLIST}" > "${FX}/mrlist.out"; run_ga ci run --mr -b forker:feat
refused "ci run --mr -b OWNER:BRANCH lists MRs by the branch part" "${FORKMSG}"
grep -q 'source_branch=feat&' "${STUB_READS}" && ok "OWNER:BRANCH reads source_branch=BRANCH" || bad "OWNER:BRANCH reads source_branch=BRANCH" "$(cat "${STUB_READS}")"
reset_fx; run_ga api -X POST "projects/${PARENT}/pipeline?x=1;ref=refs/merge-requests/11/head"
refused "a ';' in the query string refuses" "${LOOK}"
reset_fx; run_ab api -X POST "projects/${PARENT}/repository/branches" -f branch=x -f ref=refs/merge-requests/11/head
refused "a branch made from a fork MR ref is refused" "${FORKMSG}"
reset_fx; run_ab api -X POST "projects/${PARENT}/repository/tags" -f tag_name=v1 -f ref=refs/merge-requests/11/head
refused "a tag made from a fork MR ref is refused" "${FORKMSG}"
reset_fx; run_ga api -X POST "projects/${PARENT}/releases" -f tag_name=v1 -f ref=refs/merge-requests/11/head
refused "a release (and its new tag) from a fork MR ref is refused" "${FORKMSG}"
reset_fx; run_ab api -X POST "projects/${PARENT}/repository/branches" -f branch=x -f ref=main
allowed "a branch made from a branch runs"
reset_fx; run_ga release create v1 --ref refs/merge-requests/11/head --notes x
refused "release create --ref on a fork MR ref is refused" "${FORKMSG}"
reset_fx; run_ga release create v1 -r main -N x
allowed "release create -r on a branch runs"
reset_fx; run_ga ci run -b fix-merge-requests-list
allowed "a branch whose name contains merge-requests runs"
grep -q 'merge_requests' "${STUB_READS}" && bad "that branch reads no MR" "$(cat "${STUB_READS}")" || ok "that branch reads no MR"
reset_fx; run_ga ci run -b refs/merge-requests/head
refused "a merge-requests segment with no iid refuses" "${LOOK}"
reset_fx; run_ga schedule update 701 --update-variable K:V
allowed "schedule update with its own variable flags runs"

echo "== critic round: a ref that is not a branch, a tag or an MR ref"
SHA=0123456789abcdef0123456789abcdef01234567
reset_fx; run_ab api -X POST "projects/${PARENT}/repository/branches" -f branch=x -f "ref=${SHA}"
refused "a branch made from a commit sha (a fork MR head GitLab keeps here) refuses" "${LOOK}"
reset_fx; run_ab api -X POST "projects/${PARENT}/repository/tags" -f tag_name=v1 -f "ref=refs/keep-around/${SHA}"
refused "a tag made from a keep-around ref refuses" "${LOOK}"
reset_fx; run_ga release create v1 --ref "${SHA}"
refused "release create --ref <sha> refuses" "${LOOK}"
reset_fx; run_ga ci run -b "${SHA}"
refused "ci run -b <sha> refuses" "${LOOK}"
reset_fx; run_ga api -X POST "projects/${PARENT}/pipeline" -f ref=nope
refused "a ref that is no branch or tag refuses" "not, as read, a branch or a tag"
reset_fx; run_ab api -X POST "projects/${PARENT}/repository/branches" -f branch=x -f ref=v0
allowed "a branch made from a tag runs"
reset_fx; printf '[{"iid":12,"source_project_id":%s,"target_project_id":%s}]\n' "${PARENT}" "${PARENT}" > "${FX}/mrlist.out"; run_ga ci run --mr -b forker:nope
allowed "ci run --mr does not need its branch in this project (it only finds the MR)"

echo "== glab-athena: the merge guard judges first (DND-1941)"
reset_fx; run_ga api -X POST "projects/${PARENT}/repository/branches" -f branch=x -f ref=refs/merge-requests/11/head
refused "a branch made from a fork MR ref is refused by the merge guard first" "moves a branch"

echo "== agent PATH glab (routed marker built by hand)"
reset_fx; run_ab api -X POST "projects/${PARENT}/merge_requests/11/pipelines"
refused "agent glab: fork MR pipeline create is refused" "${FORKMSG}"
reset_fx; run_ab api -X POST "projects/${PARENT}/merge_requests/12/pipelines"
allowed "agent glab: same-project MR pipeline create runs"
reset_fx; echo 1 > "${FX}/mr-11.rc"; rm -f "${FX}/mr-11.out"; run_ab api -X POST "projects/${PARENT}/merge_requests/11/pipelines"
refused "agent glab: an unreadable MR refuses" "${LOOK}: could not read !11"
reset_fx; job 501 refs/merge-requests/11/head; run_ab ci retry 501
refused "agent glab: ci retry of a fork MR job is refused" "${FORKMSG}"
reset_fx; run_ab ci run -b refs/merge-requests/11/head
refused "agent glab: ci run on a fork MR ref is refused" "${FORKMSG}"
reset_fx; run_ab api "projects/${PARENT}/pipelines"
allowed "agent glab: a read runs"

echo "== glab-athena with the agent wrapper behind it"
reset_fx; run_both api -X POST "projects/${PARENT}/merge_requests/12/pipelines"
allowed "same-project MR pipeline create runs once through both"
reset_fx; run_both api -X POST "projects/${PARENT}/merge_requests/11/pipelines"
refused "fork MR pipeline create is refused through both" "${FORKMSG}"

fsg_verify || bad "forge-stub-guard" "a call fell through the stub to the guard (DND-1647)"

echo
printf '%d passed, %d failed\n' "${PASS}" "${FAIL}"
[ "${FAIL}" = 0 ]
