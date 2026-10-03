#!/usr/bin/env bash
# Self-test for the glab-athena merge guard (DND-742).
#
# The defect this pins: glab-athena ran every command as-is. `glab-athena mr
# merge` with no --sha, or while the head pipeline was running or red, went to
# GitLab, and so did `glab-athena api` merges (REST PUT …/merge, a merge-train
# POST, GraphQL mergeRequestAccept). The wrapper now requires, on every merge
# path it lets through, a pin of the MR's exact head SHA and a head pipeline
# that PASSED on that head; the REST merge route, mergeRequestAccept and `mcp
# serve` are refused outright. Since DND-1845 both merge paths also need
# integration-gate's sealed receipt for the head (the R cases), read from a
# fixture checkout of the MR's project. Design and measurements: the header of
# ai/lib/glab-merge-guard.sh. Old-vs-new evidence and mutation results:
# SABOTAGE_RECORDS.md next to this file.
#
# NO NETWORK, EVER. `glab` is a stub on PATH. It answers the guard's five reads
# (`mr view … -F json`, `api projects/<p>/merge_requests/<iid>`, `api
# projects/<p>/repository/commits/<sha>`, `api projects/<p>/repository/branches/
# <branch>`, `api projects/<p>/merge_requests/<iid>/versions`) from fixture
# files, and records every
# OTHER call as an exec in a separate log. Every refusal case asserts that log
# is empty, i.e. nothing that could merge reached glab.
#
# Gated: ai/bin/harness-gate runs every tracked **/self-test.sh.
#
# Run against another copy of the wrapper (old-vs-new evidence) with
#   GLAB_ATHENA_UNDER_TEST=/path/to/glab-athena bash ai/test/glab-athena-merge-guard/self-test.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AI_DIR="$(cd "${HERE}/../.." && pwd)"
WRAPPER="${GLAB_ATHENA_UNDER_TEST:-${AI_DIR}/bin/glab-athena}"

TMP="$(mktemp -d)"; trap 'rm -rf "${TMP}"' EXIT
PASS=0; FAIL=0
ok()  { printf '  ok    %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  FAIL  %s\n        %s\n' "$1" "$2"; FAIL=$((FAIL+1)); }

# ---- hermetic environment ---------------------------------------------------
FAKE_TOKEN="glpat-SELFTESTFAKETOKEN0000"
printf '%s\n' "${FAKE_TOKEN}" > "${TMP}/token"; chmod 600 "${TMP}/token"
export GITLAB_ATHENA_TOKEN_FILE="${TMP}/token"
unset GLAB_ATHENA_MERGE_DRY_RUN GLAB_ATHENA_GIT_DRY_RUN

FX="${TMP}/fx"; mkdir -p "${FX}" "${TMP}/bin"
export STUB_FX="${FX}" STUB_READS="${TMP}/reads.log" STUB_EXECS="${TMP}/execs.log"

# The stub glab. A read the case staged answers from <fx>/<kind>.out (stdout),
# .err (stderr) and .rc (exit code, default 0). Anything else is an EXEC:
# logged to STUB_EXECS and answered "stub: ran …".
cat > "${TMP}/bin/glab" <<'STUB'
#!/usr/bin/env bash
[ "${GITLAB_TOKEN:-}" = "glpat-SELFTESTFAKETOKEN0000" ] || { echo "stub: GITLAB_TOKEN not the Athena token" >&2; exit 97; }
answer() {
  local k="$1" rc=0
  # No fixture: not one of this case's reads (a user's own GET of the same
  # shape). It falls through to an exec, so a guard read the case forgot to
  # stage shows up as an exec and fails the case loudly.
  [ -f "${STUB_FX}/$k.out" ] || [ -f "${STUB_FX}/$k.rc" ] || return 0
  printf '%s\n' "$*" >> "${STUB_READS}"
  [ -f "${STUB_FX}/$k.rc" ] && rc="$(cat "${STUB_FX}/$k.rc")"
  [ -f "${STUB_FX}/$k.err" ] && cat "${STUB_FX}/$k.err" >&2
  [ -f "${STUB_FX}/$k.out" ] && cat "${STUB_FX}/$k.out"
  exit "$rc"
}
all="$*"
case "$all" in
  "mr view "*"-F json"|"mr view -F json") answer mrview "$all" ;;
esac
if [[ "$all" =~ ^api\ (--hostname\ [^\ ]+\ )?projects/[^\ ]+/merge_requests/[0-9]+$ ]]; then answer mrapi "$all"; fi
if [[ "$all" =~ ^api\ projects/[0-9]+/repository/commits/[0-9a-f]+$ ]]; then answer commit "$all"; fi
if [[ "$all" =~ ^api\ (--hostname\ [^\ ]+\ )?projects/[0-9]+/repository/branches/[^\ ]+$ ]]; then answer branch "$all"; fi
if [[ "$all" =~ ^api\ (--hostname\ [^\ ]+\ )?projects/[0-9]+/merge_requests/[0-9]+/versions$ ]]; then answer versions "$all"; fi
printf '%s\n' "$all" >> "${STUB_EXECS}"
echo "stub: ran $all"
exit 0
STUB
chmod +x "${TMP}/bin/glab"
# DND-1647: a guard stands behind every gh/glab stub on PATH, so a stub
# that is missing or not executable fails the suite instead of reaching the
# real CLI (ai/lib/forge-stub-guard.sh).
. "${HERE}/../../lib/forge-stub-guard.sh"
fsg_arm "${TMP}/forge-guard"
fsg_require_stubs "${TMP}/bin" glab
export PATH="${TMP}/bin:${PATH}"

# Shapes measured on example-group/example-app !4242 (2026-09-26): the open MR's head
# pipeline is a merged-results pipeline on refs/merge-requests/4242/merge, whose
# commit's parents are [target, head].
HEAD_SHA="4cc5665184c838efca81646c61b461e72e6ea145"
MERGE_SHA="e8feb98c3218bbc35a684bcd047ada5d94e0f176"
TARGET_SHA="fb181a4274258faf3b2a7ba8e6b438e0c490a6e9"
OTHER_SHA="0e134e88662690fe8edde401fa79bf44aa688eec"

# ---- the local checkout the receipt check reads (DND-1845) ------------------
# Every merge glab-athena lets through now also needs integration-gate's sealed
# receipt for the MR's exact head, read from the git common dir of the checkout
# the wrapper runs in. The fixture is a checkout of the MR's project (origin is
# never contacted) that DECLARES NO GATE: a GitLab project gated with a
# caller-supplied `--gate` is still gated. Commits:
#   OLD_TIP  main's parent        TIP_FX  main's tip (the target branch tip)
#   SIDE_FX  a sibling of TIP_FX, not an ancestor of it
# Receipts are sealed under a private key in the suite's temp dir (DND-1814).
export ATHENA_SECRETS_ROOT="${TMP}/secrets"
REPO_FX="${TMP}/example-app"
git init -q -b main "${REPO_FX}"
rfx() { git -C "${REPO_FX}" -c user.name=t -c user.email=t@t -c commit.gpgsign=false "$@"; }
rfx remote add origin git@gitlab.com:example-group/example-app.git
echo one > "${REPO_FX}/README"; rfx add README; rfx commit -q -m one
OLD_TIP="$(rfx rev-parse HEAD)"
echo two >> "${REPO_FX}/README"; rfx commit -q -am two
TIP_FX="$(rfx rev-parse HEAD)"
rfx checkout -q -b side "${OLD_TIP}"; echo side >> "${REPO_FX}/README"; rfx commit -q -am side
SIDE_FX="$(rfx rev-parse HEAD)"
rfx checkout -q main
COMMON_FX="$(git -C "${REPO_FX}" rev-parse --path-format=absolute --git-common-dir)"
STORE_FX="${COMMON_FX}/integration-receipts"
cd "${REPO_FX}" || exit 2

reset_fx() { rm -f "${FX}"/* "${STUB_READS}" "${STUB_EXECS}"; rm -rf "${STORE_FX}"; : > "${STUB_READS}"; : > "${STUB_EXECS}"; }

# mr_json <status> [pipeline sha] [pipeline ref] [head] [iid] -> an MR object.
mr_json() {
  printf '{"iid":%s,"project_id":7000001,"sha":"%s","target_branch":"main","web_url":"https://gitlab.com/example-group/example-app/-/merge_requests/%s","head_pipeline":{"id":9000000001,"sha":"%s","ref":"%s","status":"%s"}}\n' \
    "${5:-4242}" "${4:-${HEAD_SHA}}" "${5:-4242}" "${2:-${MERGE_SHA}}" "${3:-refs/merge-requests/4242/merge}" "$1"
}
# branch_is <sha> : the forge reports <sha> as the tip of the MR's target branch.
branch_is() { printf '{"name":"main","commit":{"id":"%s"}}\n' "$1" > "${FX}/branch.out"; }
# plant <head> <base> [verdict] [jq edit] : a receipt as integration-gate
# writes it, sealed. The optional jq edit adjusts fields before the seal.
plant() {
  mkdir -p "${STORE_FX}"
  jq -n --arg h "$1" --arg b "$2" --arg v "${3:-pass}" \
    '{schema:"integration-receipt/1", verdict:$v, head:$h, target_ref:"origin/main", base:$b,
      gate:"cd backend && bin/prep-commit.sh", gate_source:"caller-supplied; no gate declared on origin/main",
      owner_approval:null, recorded_at:"2026-10-03T00:00:00Z"}' | jq "${4:-.}" > "${STORE_FX}/$1.json"
  "${AI_DIR}/bin/receipt-seal" seal --kind integration "${STORE_FX}/$1.json"
}
# green_fx : every read answers "passed merged-results pipeline on the head",
# and integration-gate passed that head against the target tip.
green_fx() {
  mr_json success > "${FX}/mrview.out"
  mr_json success > "${FX}/mrapi.out"
  printf '{"id":"%s","parent_ids":["%s","%s"]}\n' "${MERGE_SHA}" "${TARGET_SHA}" "${HEAD_SHA}" > "${FX}/commit.out"
  branch_is "${TIP_FX}"
  printf '[{"id":1,"head_commit_sha":"%s"}]\n' "${HEAD_SHA}" > "${FX}/versions.out"
  plant "${HEAD_SHA}" "${TIP_FX}"
}
# nogate_fx : green, but integration-gate never passed the head (no receipt).
nogate_fx() { green_fx; rm -rf "${STORE_FX}"; }
status_fx() { green_fx; mr_json "$1" > "${FX}/mrview.out"; mr_json "$1" > "${FX}/mrapi.out"; }
fx() { printf '%s' "$2" > "${FX}/$1.out"; printf '%s' "${3:-0}" > "${FX}/$1.rc"; [ -z "${4:-}" ] || printf '%s\n' "$4" > "${FX}/$1.err"; }

run() { OUT="$("${WRAPPER}" "$@" 2>"${TMP}/err")"; RC=$?; ERR="$(cat "${TMP}/err")"; }
execs() { cat "${STUB_EXECS}"; }
reads() { cat "${STUB_READS}"; }
refused() { [ "${RC}" = 3 ] && [[ "${ERR}" == *"REFUSING"* ]] && [[ "${ERR}" == *"Fix:"* ]] && [ ! -s "${STUB_EXECS}" ]; }
# ran_once <args…> : the command reached glab exactly once, as given.
ran_once() { [ "${RC}" = 0 ] && [ "$(execs)" = "$*" ]; }
detail()  { printf 'rc=%s out=%q err=%q reads=%q execs=%q' "${RC}" "${OUT}" "${ERR}" "$(reads)" "$(execs)"; }

# expect_refused <id> <label> <must-contain> <args…>
expect_refused() {
  local id="$1" label="$2" want="$3"; shift 3
  run "$@"
  if refused && [[ "${ERR}" == *"${want}"* ]]; then ok "${id}. ${label}"
  else bad "${id}. ${label} (want refusal naming '${want}')" "$(detail)"; fi
}
# expect_ran <id> <label> <reads: none|any> <args…>
expect_ran() {
  local id="$1" label="$2" rd="$3"; shift 3
  run "$@"
  if ran_once "$@" && { [ "${rd}" = any ] || [ ! -s "${STUB_READS}" ]; }; then ok "${id}. ${label}"
  else bad "${id}. ${label} (want one exec, reads=${rd})" "$(detail)"; fi
}

echo "glab-athena merge-guard self-test"
echo "wrapper: ${WRAPPER}"
echo

echo "--- mr merge: the pin and the passed head pipeline ---"
reset_fx; green_fx
expect_refused M1 "mr merge with no --sha is refused, naming the head" "${HEAD_SHA}" mr merge 4242 --yes
reset_fx; green_fx
expect_ran M2 "mr merge --sha <head> with a passed merged-results pipeline runs" any mr merge 4242 --sha "${HEAD_SHA}" --yes
if [[ "$(reads)" == *"repository/commits/${MERGE_SHA}"* ]]; then ok "M2b. the merged-results commit was read to tie the pipeline to the head"
else bad "M2b. merged-results commit read" "$(detail)"; fi
reset_fx; green_fx
expect_refused M3 "mr merge --sha <not the head> is refused" "not the MR's head" mr merge 4242 --sha "${OTHER_SHA}" --yes
reset_fx; status_fx running
expect_refused M4 "a running head pipeline is refused (auto-merge default)" "'running', not success" mr merge 4242 --sha "${HEAD_SHA}" --yes
reset_fx; status_fx running
expect_refused M4b "a running head pipeline is refused with --auto-merge" "'running', not success" mr merge 4242 --sha "${HEAD_SHA}" --auto-merge --yes
reset_fx; status_fx running
expect_refused M4c "a running head pipeline is refused with --when-pipeline-succeeds" "'running', not success" mr merge 4242 --sha "${HEAD_SHA}" --when-pipeline-succeeds --yes
reset_fx; status_fx failed
expect_refused M5 "a failed head pipeline is refused" "'failed', not success" mr merge 4242 --sha "${HEAD_SHA}" --yes
reset_fx; green_fx
printf '{"iid":4242,"project_id":7000001,"sha":"%s","head_pipeline":null}\n' "${HEAD_SHA}" > "${FX}/mrview.out"
expect_refused M6 "no head pipeline is refused" "has no head pipeline" mr merge 4242 --sha "${HEAD_SHA}" --yes
reset_fx; green_fx; mr_json success "${HEAD_SHA}" "feature-branch" > "${FX}/mrview.out"
expect_ran M7 "a passed pipeline ON the head (branch pipeline) runs" any mr merge 4242 --sha "${HEAD_SHA}" --yes
if [[ "$(reads)" != *"repository/commits"* ]]; then ok "M7b. no commit read when the pipeline sha is the head"
else bad "M7b. unexpected commit read" "$(detail)"; fi
reset_fx; green_fx
printf '{"id":"%s","parent_ids":["%s","%s"]}\n' "${MERGE_SHA}" "${TARGET_SHA}" "${OTHER_SHA}" > "${FX}/commit.out"
expect_refused M8 "a merged-results commit whose 2nd parent is not the head is refused" "do not end in head" mr merge 4242 --sha "${HEAD_SHA}" --yes
reset_fx; green_fx; mr_json success "216e40abc081b59f341d2d1de2fdd12facee7772" "refs/merge-requests/4242/train" > "${FX}/mrview.out"
expect_refused M9 "a merge-train head pipeline cannot be tied and is refused" "cannot be tied" mr merge 4242 --sha "${HEAD_SHA}" --yes
reset_fx; green_fx; fx commit '' 1 'glab: 404 Commit Not Found'
expect_refused M10 "a failed commit read is refused" "could not read the merged-results commit" mr merge 4242 --sha "${HEAD_SHA}" --yes
reset_fx; fx mrview '' 1 'glab: 404 Not Found'
expect_refused M11 "a failed MR read is refused" "could not read the MR" mr merge 4242 --sha "${HEAD_SHA}" --yes
reset_fx; green_fx
expect_refused M12 "mr accept (merge's alias) with no --sha is refused" "no sha was given" mr accept 4242 --yes
reset_fx; green_fx
expect_refused M13 "--repo before the subcommand, no --sha, is refused" "no sha was given" --repo example-group/example-app mr merge 4242 --yes
reset_fx; green_fx
expect_refused M13b "mr -R <repo> merge, no --sha, is refused" "no sha was given" mr -R example-group/example-app merge 4242
if [[ "$(reads)" == *"mr view 4242 -R example-group/example-app -F json"* ]]; then ok "M13c. the MR is read in the -R project"
else bad "M13c. -R carried into the read" "$(detail)"; fi
reset_fx; green_fx
expect_ran M14 "--sha=<head> with combined short flags runs" any mr merge 4242 "--sha=${HEAD_SHA}" -sdy
reset_fx; green_fx
expect_ran M14b "--sha <head> --auto-merge with a passed pipeline runs" any mr merge 4242 --sha "${HEAD_SHA}" --auto-merge --yes
reset_fx; green_fx
expect_refused M15 "an unknown mr merge flag is refused" "--bogus" mr merge 4242 --sha "${HEAD_SHA}" --bogus
reset_fx; green_fx
expect_refused M16 "--sha given twice is refused" "2 times" mr merge 4242 --sha "${OTHER_SHA}" --sha "${HEAD_SHA}"
reset_fx; green_fx
expect_refused M17 "mr merge --help gets no short-circuit (judged, refused with no pin)" "no sha was given" mr merge --help
reset_fx; green_fx
expect_refused M23 "--help then --help=false (pflag: last wins, so it merges) is refused" "no sha was given" mr merge 4242 --help --help=false --yes
reset_fx; green_fx
expect_refused M24 "-h then --help=0 is refused" "no sha was given" mr merge 4242 -h --help=0 --yes
reset_fx; green_fx
expect_refused M18 "an unknown flag before the subcommand is refused" "comes before the subcommand" --bogus x mr merge 4242 --sha "${HEAD_SHA}"
reset_fx; green_fx; printf '{"iid":4242,"sha":"%s","head_pipeline":{"status":"success"}}\n' "${HEAD_SHA}" > "${FX}/mrview.out"
expect_refused M19 "an MR read with no project_id is refused" "no usable sha" mr merge 4242 --sha "${HEAD_SHA}"
reset_fx; green_fx
printf '{"id":"%s","parent_ids":["%s"]}\n' "${MERGE_SHA}" "${HEAD_SHA}" > "${FX}/commit.out"
expect_refused M20 "a merged-results commit with one parent is refused" "do not end in head" mr merge 4242 --sha "${HEAD_SHA}"
reset_fx; green_fx
expect_ran M21 "no selector: the current branch's MR, pinned and green, runs" any mr merge --sha "${HEAD_SHA}" --yes
if [[ "$(reads)" == *"mr view -F json"* ]]; then ok "M21b. the current-branch MR was read"; else bad "M21b. current-branch read" "$(detail)"; fi
reset_fx; green_fx
expect_refused M22 "mr merge -R<repo> attached, no --sha, is refused" "no sha was given" mr merge -Rexample-group/example-app 4242
# A flag cluster before the subcommand whose meaning differs between the
# guard's flag table and cobra's command walk (critic round 3). Measured, glab
# 1.112: `glab mr -ym merge x --help` prints mr merge's help, so cobra routes
# `mr -ym merge 4242` to merge (-ym is dropped from the walk), and merge's pflag
# parse then reads -y as yes and -m as the message 4242: the current branch's MR
# merges with no pin. The mr-merge table instead reads `m` as taking `merge`.
for cl in -ym -sm -dm -rm -hm; do
  reset_fx; green_fx
  expect_refused "M25${cl}" "mr ${cl} merge 4242 (a cluster before the subcommand) is refused" "before the subcommand" mr "${cl}" merge 4242
done
reset_fx; green_fx
expect_refused M26 "mr -h merge 4242 --sha <head> (help before the subcommand) is refused" "before the subcommand" mr -h merge 4242 --sha "${HEAD_SHA}" --yes
reset_fx; green_fx
expect_refused M27 "-y before mr, then merge, is refused" "before the subcommand" -y mr merge 4242 --sha "${HEAD_SHA}"
reset_fx; green_fx
expect_refused M28 "a cluster before mr merge, with a pin, is still refused" "before the subcommand" mr -ym merge 4242 --sha "${HEAD_SHA}"
# The class, not the listed sites: EVERY short flag, every two-letter cluster of
# them, and every long flag in the tables, placed before `merge` and before
# `mr`, must be refused. Only -R/--repo forms may sit there (M29-M31).
M32_BAD=""
M32_SHORT="m d s y h r X x"
M32_WORDS=""
for a in ${M32_SHORT}; do
  M32_WORDS+=" -${a}"
  for b in ${M32_SHORT} R; do M32_WORDS+=" -${a}${b}"; done
done
M32_WORDS+=" --message --sha --squash-message --auto-merge --when-pipeline-succeeds --rebase --remove-source-branch --squash --yes --help --help=false --sha=x --bogus -- -"
for w in ${M32_WORDS}; do
  for shape in pre-merge pre-mr; do
    reset_fx; green_fx
    if [ "${shape}" = pre-merge ]; then run mr "${w}" merge 4242 --sha "${HEAD_SHA}" --yes
    else run "${w}" mr merge 4242 --sha "${HEAD_SHA}" --yes; fi
    refused || M32_BAD+=" ${shape}:${w}"
  done
done
if [ -z "${M32_BAD}" ]; then ok "M32. every non-repo flag spelling before the subcommand is refused ($(wc -w <<<"${M32_WORDS}") spellings x 2 shapes)"
else bad "M32. flag spellings before the subcommand that were not refused" "${M32_BAD}"; fi
reset_fx; green_fx
expect_ran M29 "--repo <repo> before the subcommand, pinned and green, runs" any --repo example-group/example-app mr merge 4242 --sha "${HEAD_SHA}" --yes
reset_fx; green_fx
expect_ran M30 "mr --repo=<repo> merge, pinned and green, runs" any mr --repo=example-group/example-app merge 4242 --sha "${HEAD_SHA}" --yes
reset_fx; green_fx
expect_ran M31 "mr -R<repo> merge (attached), pinned and green, runs" any mr -Rexample-group/example-app merge 4242 --sha "${HEAD_SHA}" --yes

echo
echo "--- api: the REST merge route is refused outright ---"
reset_fx; green_fx
expect_refused A1 "PUT projects/:id/merge_requests/<iid>/merge" "REST merge" api -X PUT "projects/:id/merge_requests/4242/merge"
reset_fx
expect_refused A2 "--method=put, encoded project, query string" "REST merge" api --method=put "projects/example-group%2Fexample-app/merge_requests/4242/merge?sha=${HEAD_SHA}"
reset_fx
expect_refused A3 "-XPUT full URL with api/v4" "REST merge" api -XPUT "https://gitlab.com/api/v4/projects/1/merge_requests/2/merge"
reset_fx
expect_refused A4 "no method, a field -> POST" "REST merge" api "projects/1/merge_requests/2/merge" -f "sha=${HEAD_SHA}"
reset_fx
expect_refused A5 "GET with a method-override header" "REST merge" api -H "X-HTTP-Method-Override: PUT" "projects/1/merge_requests/2/merge"
reset_fx
expect_refused A6 ".json format suffix" "REST merge" api -X PUT "projects/1/merge_requests/2/merge.json"
reset_fx
expect_refused A7 "dot segments" "REST merge" api -X PUT "projects/1/./merge_requests/../merge_requests/2/merge"
reset_fx
expect_refused A8 "upper-case route word" "REST merge" api -X PUT "projects/1/MERGE_REQUESTS/2/Merge"
reset_fx
expect_refused A9 "%-encoded route word" "REST merge" api -X PUT "projects/1/merge_requests/2/%6derge"
reset_fx
expect_refused A10 "--form _method=PUT" "REST merge" api --form "_method=PUT" "projects/1/merge_requests/2/merge"
reset_fx
expect_refused A11 "an unknown api flag" "--bogus" api --bogus "projects/1/merge_requests/2/merge"
reset_fx
expect_refused A12 "a malformed escape" "cannot be normalized" api -X PUT "projects/1/merge_requests/2/merg%zz"
reset_fx
expect_refused A13 "api/v4 prefix without host" "REST merge" api -X PUT "api/v4/projects/1/merge_requests/2/merge"
reset_fx
expect_refused A14 "GET with a _method field" "REST merge" api -X GET -f "_method=PUT" "projects/1/merge_requests/2/merge"
# glab dispatches `glab -R g/r api …` to api (measured, glab 1.112), so a word
# before `api` must not hide the call from the api judgment.
reset_fx
expect_refused A15 "-R <repo> before api" "is not the first word" -R example-group/example-app api -X PUT "projects/1/merge_requests/2/merge"
reset_fx
expect_refused A16 "--repo=<repo> before api" "is not the first word" --repo=example-group/example-app api -X PUT "projects/1/merge_requests/2/merge"
reset_fx
expect_refused A17 "-X PUT before api" "PUT" -X PUT api "projects/1/merge_requests/2/merge"
reset_fx
expect_refused A18 "-- before api" "REFUSING" -- api -X PUT "projects/1/merge_requests/2/merge"
reset_fx
expect_refused A19 "-R <repo> before api, train boarding with no pin" "is not the first word" -R example-group/example-app api -X POST "projects/:id/merge_trains/merge_requests/4242"
reset_fx
expect_refused A20 "-R <repo> before api, REST merge by a field (default POST)" "is not the first word" -R example-group/example-app api "projects/1/merge_requests/2/merge" -f "sha=${HEAD_SHA}"
reset_fx; green_fx
expect_refused A21 "-R <repo> before api, train boarding with a wrong pin (default POST)" "is not the first word" -R example-group/example-app api "projects/:id/merge_trains/merge_requests/4242" -f "sha=${OTHER_SHA}"

echo
echo "--- api: merge-train boarding is the guarded path ---"
reset_fx; green_fx
expect_refused T1 "boarding with no sha field is refused" "no sha was given" api -X POST "projects/:id/merge_trains/merge_requests/4242"
reset_fx; green_fx
expect_ran T2 "boarding with -f sha=<head>, passed pipeline, runs" any api -X POST "projects/:id/merge_trains/merge_requests/4242" -f "sha=${HEAD_SHA}"
if [[ "$(reads)" == *"api projects/:id/merge_requests/4242"* ]]; then ok "T2b. the MR was read in the same project"
else bad "T2b. MR read endpoint" "$(detail)"; fi
reset_fx; green_fx
expect_refused T3 "boarding with a sha that is not the head" "not the MR's head" api -X POST "projects/:id/merge_trains/merge_requests/4242" -f "sha=${OTHER_SHA}"
reset_fx; status_fx running
expect_refused T4 "boarding while the head pipeline runs" "'running', not success" api -X POST "projects/:id/merge_trains/merge_requests/4242" -f "sha=${HEAD_SHA}"
reset_fx; green_fx; printf '%s' "${HEAD_SHA}" > "${TMP}/sha.txt"
expect_refused T5 "the sha field read from a file" "read from a file" api -X POST "projects/:id/merge_trains/merge_requests/4242" -F "sha=@${TMP}/sha.txt"
reset_fx; green_fx
expect_refused T6 "a query string on the train endpoint" "query string" api -X POST "projects/:id/merge_trains/merge_requests/4242?sha=${HEAD_SHA}"
reset_fx; green_fx; printf '{"sha":"%s"}' "${HEAD_SHA}" > "${TMP}/body.json"
expect_refused T7 "--input body on the train endpoint" "--input or --form" api -X POST "projects/:id/merge_trains/merge_requests/4242" --input "${TMP}/body.json"
reset_fx; green_fx
expect_refused T8 "sha given twice" "2 times" api -X POST "projects/:id/merge_trains/merge_requests/4242" -f "sha=${OTHER_SHA}" -f "sha=${HEAD_SHA}"
reset_fx; green_fx
expect_refused T9 "PUT on a car" "not the boarding call" api -X PUT "projects/:id/merge_trains/merge_requests/4242" -f "sha=${HEAD_SHA}"
reset_fx
expect_ran T10 "DELETE a car (take it off the train) runs with no reads" none api -X DELETE "projects/:id/merge_trains/merge_requests/4242"
reset_fx
expect_ran T11 "GET a car runs with no reads" none api "projects/:id/merge_trains/merge_requests/4242"
reset_fx; green_fx
expect_ran T12 "auto_merge=true plus the pin, passed pipeline, runs" any api -X POST "projects/:id/merge_trains/merge_requests/4242" -f auto_merge=true -f "sha=${HEAD_SHA}"
reset_fx; green_fx
expect_ran T13 "an encoded project path" any api -X POST "projects/example-group%2Fexample-app/merge_trains/merge_requests/4242" -f "sha=${HEAD_SHA}"
if [[ "$(reads)" == *"api projects/example-group%2Fexample-app/merge_requests/4242"* ]]; then ok "T13b. the encoded project was re-encoded for the MR read"
else bad "T13b. encoded project read" "$(detail)"; fi
reset_fx; green_fx; mr_json success > "${FX}/mrapi.out"; mr_json success "${MERGE_SHA}" "refs/merge-requests/4242/merge" "${HEAD_SHA}" 99 > "${FX}/mrapi.out"
expect_refused T14 "the MR read back is a different iid" "is not !4242" api -X POST "projects/:id/merge_trains/merge_requests/4242" -f "sha=${HEAD_SHA}"
reset_fx; fx mrapi '' 1 'glab: 404 Not Found'
expect_refused T15 "a failed MR read" "could not read !4242" api -X POST "projects/:id/merge_trains/merge_requests/4242" -f "sha=${HEAD_SHA}"
reset_fx; green_fx
expect_refused T16 "DELETE with a method-override header" "not the boarding call" api -X DELETE -H "X-HTTP-Method-Override: POST" "projects/:id/merge_trains/merge_requests/4242"
reset_fx; green_fx
expect_ran T17 "no method, sha field -> POST, guarded, runs" any api "projects/:id/merge_trains/merge_requests/4242" -f "sha=${HEAD_SHA}"
reset_fx; green_fx
expect_ran T18 "--hostname is carried into the MR read" any api --hostname gitlab.com -X POST "projects/:id/merge_trains/merge_requests/4242" -f "sha=${HEAD_SHA}"
if [[ "$(reads)" == *"api --hostname gitlab.com projects/:id/merge_requests/4242"* ]]; then ok "T18b. hostname in the read"
else bad "T18b. hostname in the read" "$(detail)"; fi
reset_fx; green_fx
expect_refused T19 "a _method field on the train endpoint" "_method" api -X POST "projects/:id/merge_trains/merge_requests/4242" -f "sha=${HEAD_SHA}" -f "_method=PUT"
reset_fx; green_fx; status_fx failed
expect_refused T20 "boarding with a failed head pipeline" "'failed', not success" api "projects/:id/merge_trains/merge_requests/4242" -F "sha=${HEAD_SHA}"

echo
echo "--- api graphql: mergeRequestAccept is refused wherever the query comes from ---"
Q='mutation { mergeRequestAccept(input: {projectPath: "example-group/example-app", iid: "4242", sha: "x"}) { errors } }'
reset_fx
expect_refused G1 "inline -f query" "mergeRequestAccept" api graphql -f "query=${Q}"
reset_fx; printf '%s' "${Q}" > "${TMP}/q.graphql"
expect_refused G2 "-F query=@file" "mergeRequestAccept" api graphql -F "query=@${TMP}/q.graphql"
reset_fx; printf '{"query":"mutation { mergeRequest\\u0041ccept(input: {}) { errors } }"}' > "${TMP}/q.json"
expect_refused G3 "--input JSON body with a \\u escape" "mergeRequestAccept" api graphql --input "${TMP}/q.json"
reset_fx
expect_refused G4 "-F query=@- (stdin)" "stdin" api graphql -F "query=@-"
reset_fx
expect_refused G5 "--input - (stdin)" "stdin" api graphql --input -
reset_fx; printf 'not json' > "${TMP}/bad.json"
expect_refused G6 "--input that is not JSON" "not JSON" api graphql --input "${TMP}/bad.json"
reset_fx
expect_refused G7 "an unreadable query file" "cannot read" api graphql -F "query=@${TMP}/does-not-exist"
reset_fx
expect_refused G8 "the full GraphQL URL" "mergeRequestAccept" api "https://gitlab.com/api/graphql" -f "query=${Q}"
reset_fx
expect_refused G9 "an operation alias around it" "mergeRequestAccept" api graphql -f 'query=mutation M { go: mergeRequestAccept(input: $i) { errors } }'
reset_fx
expect_ran G10 "mergeTrainsDeleteCar passes" none api graphql -f 'query=mutation { mergeTrainsDeleteCar(input: {carId: "x"}) { errors } }'
reset_fx
expect_ran G11 "a read query passes" none api graphql -f 'query=query { currentUser { username } }'
reset_fx
expect_ran G12 "mergeRequestSetLabels passes" none api graphql -f 'query=mutation { mergeRequestSetLabels(input: {}) { errors } }'


# The scan's own failure must never read as "no merge mutation". F1: mktemp
# fails for the scan file only (the isolation dir, mktemp -d, still works).
# F2: grep errors (exit 2) on the scan.
mkdir -p "${TMP}/brokenbin"
REAL_MKTEMP="$(command -v mktemp)"; REAL_GREP="$(command -v grep)"
printf '#!/usr/bin/env bash\ncase " $* " in *" -d "*) exec "%s" "$@" ;; esac\nexit 1\n' "${REAL_MKTEMP}" > "${TMP}/brokenbin/mktemp"
chmod +x "${TMP}/brokenbin/mktemp"
reset_fx; PATH="${TMP}/brokenbin:${PATH}" run api graphql -f 'query=query { currentUser { username } }'
if refused && [[ "${ERR}" == *"scratch file"* ]]; then ok "F1. the scan's scratch file cannot be made -> refused"
else bad "F1. mktemp failure fails closed" "$(detail)"; fi
rm -f "${TMP}/brokenbin/mktemp"
printf '#!/usr/bin/env bash\ncase " $* " in *" -aEiq "*) echo "grep: simulated I/O error" >&2; exit 2 ;; esac\nexec "%s" "$@"\n' "${REAL_GREP}" > "${TMP}/brokenbin/grep"
chmod +x "${TMP}/brokenbin/grep"
reset_fx; PATH="${TMP}/brokenbin:${PATH}" run api graphql -f 'query=query { currentUser { username } }'
if refused && [[ "${ERR}" == *"grep exit 2"* ]]; then ok "F2. the scan's grep errors (exit 2) -> refused"
else bad "F2. grep error fails closed" "$(detail)"; fi
rm -rf "${TMP}/brokenbin"

echo
echo "--- other merge paths ---"
reset_fx
expect_refused C1 "mcp serve (its tools can merge) is refused" "mcp" mcp serve
# `glab mr create --auto-merge` (glab 1.112: "Set the merge request to merge when
# all merge checks pass") schedules a merge of a head nobody pinned or checked.
reset_fx
expect_refused C2 "mr create --auto-merge is refused" "--auto-merge" mr create --fill --auto-merge --yes
reset_fx
expect_refused C3 "mr new (create's alias) --auto-merge=true is refused" "--auto-merge" mr new --fill --auto-merge=true --yes
reset_fx
expect_refused C4 "mr -R <repo> create --auto-merge is refused" "--auto-merge" mr -R example-group/example-app create --fill --auto-merge
reset_fx
expect_refused C5 "--auto-merge on another subcommand is refused" "--auto-merge" mr update 4242 --auto-merge

echo
echo "--- negatives: reads and non-merge writes pass as-is, with no extra reads ---"
reset_fx; expect_ran N1 "mr view" none mr view 4242
reset_fx; expect_ran N2 "mr create" none mr create --fill --yes --target-branch main
reset_fx; expect_ran N3 "mr note whose text says merge" none mr note 4242 --message "please merge"
reset_fx; expect_ran N4 "api GET an MR" none api "projects/:id/merge_requests/4242"
reset_fx; expect_ran N5 "api POST approve" none api -X POST "projects/:id/merge_requests/4242/approve"
reset_fx; expect_ran N6 "api GET the active train" none api "projects/:id/merge_trains?scope=active"
reset_fx; expect_ran N7 "api POST a note" none api -X POST "projects/:id/merge_requests/4242/notes" -f "body=merge soon"
reset_fx; expect_ran N8 "api POST cancel auto-merge" none api -X POST "projects/:id/merge_requests/4242/cancel_merge_when_pipeline_succeeds"
reset_fx; expect_ran N9 "api GET merge_ref" none api "projects/:id/merge_requests/4242/merge_ref"
reset_fx; expect_ran N10 "ci status" none ci status
reset_fx; expect_ran N11 "api PUT MR labels" none api -X PUT "projects/:id/merge_requests/4242" -f "labels=Auto-Deploy"
reset_fx; expect_ran N12 "mr list" none mr list
reset_fx; expect_ran N13 "api POST a pipeline for the MR" none api -X POST "projects/:id/merge_requests/4242/pipelines"
reset_fx; expect_ran N14 "mr create whose title says merge" none mr create --title merge --description "merge accept api" --yes
reset_fx; expect_ran N15 "help mr merge" none help mr merge

echo
echo "--- DND-1845: every merge needs integration-gate's receipt for the MR's head ---"
# The defect: glab-athena pinned the head and its passed pipeline, but never
# asked whether integration-gate passed that head. An MR integration-gate held
# at exit 4 (blast-radius, no receipt written) could still be merged or boarded
# onto the train. Every merge path the guard lets through now reads the sealed
# receipt for exactly the MR's head (ai/lib/integration-receipt.sh, the reader
# gh-athena and locked-merge use) and refuses without it.
TRAIN="projects/:id/merge_trains/merge_requests/4242"
MERGE_ARGS=(mr merge 4242 --sha "${HEAD_SHA}" --yes)
BOARD_ARGS=(api -X POST "${TRAIN}" -f "sha=${HEAD_SHA}")
# receipt_refused <id> <label> <kind> <args…> : refused with that kind, a Fix:
# naming integration-gate, and nothing that merges reached glab.
receipt_refused() {
  local id="$1" label="$2" kind="$3" fixline; shift 3
  run "$@"
  fixline="$(grep -m1 'Fix:' <<<"${ERR}")"
  if refused && [[ "${ERR}" == *"${kind}"* ]] && [[ "${fixline}" == *"integration-gate"* ]]; then ok "${id}. ${label}"
  else bad "${id}. ${label} (want ${kind}, Fix naming integration-gate)" "$(detail)"; fi
}
# receipt_ran <id> <label> <args…> : ran once, as given, after the receipt read.
receipt_ran() {
  local id="$1" label="$2"; shift 2
  run "$@"
  if ran_once "$@" && [[ "${ERR}" == *"RECEIPT ${STORE_FX}/${HEAD_SHA}.json"* ]]; then ok "${id}. ${label}"
  else bad "${id}. ${label} (want one exec and a RECEIPT line)" "$(detail)"; fi
}

reset_fx; nogate_fx
receipt_refused R1 "THE MISS: mr merge, pinned head, passed pipeline, NO receipt -> refused" "NO RECEIPT" "${MERGE_ARGS[@]}"
[[ "${ERR}" == *"${STORE_FX}/${HEAD_SHA}.json"* ]] && ok "R1b. the refusal names the receipt path it searched" || bad "R1b. searched path" "$(detail)"
[[ "$(grep -m1 'Fix:' <<<"${ERR}")" == *"${HEAD_SHA}"* ]] && ok "R1c. the Fix says to run integration-gate on that head" || bad "R1c. Fix names the head" "$(detail)"
reset_fx; nogate_fx
receipt_refused R2 "THE MISS on the train: boarding, pinned head, passed pipeline, NO receipt -> refused" "NO RECEIPT" "${BOARD_ARGS[@]}"
reset_fx; nogate_fx
receipt_refused R2b "mr merge --auto-merge with no receipt -> refused" "NO RECEIPT" mr merge 4242 --sha "${HEAD_SHA}" --auto-merge --yes
reset_fx; green_fx
receipt_ran R3 "mr merge with a receipt for the head -> runs" "${MERGE_ARGS[@]}"
reset_fx; green_fx
receipt_ran R3b "train boarding with a receipt for the head -> runs" "${BOARD_ARGS[@]}"

# Criterion 1: boarding is checked against the MR's HEAD, never the train's
# merged-result commit (the head pipeline's sha here is the merge commit).
reset_fx; nogate_fx; plant "${MERGE_SHA}" "${TIP_FX}"
receipt_refused R4 "criterion 1: a receipt for the merged-result commit, none for the head -> boarding refused" "NO RECEIPT" "${BOARD_ARGS[@]}"
[[ "${ERR}" == *"${HEAD_SHA}.json"* ]] && [[ "${ERR}" != *"${MERGE_SHA}.json"* ]] \
  && ok "R4b. the receipt searched is the head's, not the merged-result commit's" || bad "R4b. head, not merge ref" "$(detail)"

# Criterion 2: non-merge writes stay unguarded: no reads, no receipt, and not
# even a checkout needed.
mkdir -p "${TMP}/not-a-repo"; cd "${TMP}/not-a-repo" || exit 2
reset_fx; expect_ran R5a "criterion 2: api PUT an Auto-Deploy label, outside any checkout" none api -X PUT "projects/:id/merge_requests/4242" -f "add_labels=Auto-Deploy"
reset_fx; expect_ran R5b "criterion 2: mr update --label (a risk label)" none mr update 4242 --label "risk::low"
reset_fx; expect_ran R5c "criterion 2: mr note" none mr note 4242 --message "gated"
reset_fx; expect_ran R5d "criterion 2: mr approve" none mr approve 4242
reset_fx; expect_ran R5e "criterion 2: api POST approve" none api -X POST "projects/:id/merge_requests/4242/approve"
reset_fx; expect_ran R5f "criterion 2: api POST play a manual job (release deploy)" none api -X POST "projects/:id/jobs/9000000002/play"
reset_fx; expect_ran R5g "criterion 2: ci trigger a manual job" none ci trigger 9000000003
cd "${REPO_FX}" || exit 2

# Criterion 3: an exit-4 head leaves NO receipt (integration-gate writes one
# only on INTEGRATION OK), so it is refused (R1). Cleared with --owner-approval,
# the gate writes a pass receipt that records the approval; that satisfies the
# guard on both paths.
OA='.owner_approval = "click:00000000-0000-4000-8000-000000000001" | .blast_radius = "BLAST-RADIUS HOT 4cc5665 OWNER-APPROVED"'
reset_fx; nogate_fx; plant "${HEAD_SHA}" "${TIP_FX}" pass "${OA}"
receipt_ran R6 "criterion 3: an owner-approved receipt for the head -> mr merge runs" "${MERGE_ARGS[@]}"
reset_fx; nogate_fx; plant "${HEAD_SHA}" "${TIP_FX}" pass "${OA}"
receipt_ran R6b "criterion 3: an owner-approved receipt for the head -> boarding runs" "${BOARD_ARGS[@]}"

# Criterion 4: the project declares no gate (bin/prep-commit.sh and
# ai/bin/harness-gate are absent at its root), so integration-gate gates it with
# a caller-supplied --gate. An MR outside the backend is gated with that part's
# own command; its receipt is the same shape, and the guard never asks which
# suite ran.
reset_fx; nogate_fx; plant "${HEAD_SHA}" "${TIP_FX}" pass '.gate = "cd mobile && bin/test"'
receipt_ran R7 "criterion 4: a receipt whose caller-supplied gate is a non-backend suite -> runs" "${MERGE_ARGS[@]}"

# Criterion 5: nothing author-specific.
for who in human bot; do
  reset_fx; nogate_fx
  for f in mrview mrapi; do jq -c --arg w "${who}" '.author = {"username": ("a-" + $w), "bot": ($w == "bot")}' "${FX}/${f}.out" > "${FX}/${f}.tmp" && mv "${FX}/${f}.tmp" "${FX}/${f}.out"; done
  receipt_refused "R8-${who}" "criterion 5: a ${who}-authored MR with no receipt -> refused" "NO RECEIPT" "${MERGE_ARGS[@]}"
  plant "${HEAD_SHA}" "${TIP_FX}"
  receipt_ran "R8b-${who}" "criterion 5: a ${who}-authored MR with a receipt -> runs" "${MERGE_ARGS[@]}"
done

# Criterion 6: the head was re-pushed after integration-gate passed an earlier
# one (e.g. a head pushed after integration-gate --rebase that is not the
# rebased head it gated). The old head's receipt does not cover the new head.
versions_fx() { printf '[{"id":2,"head_commit_sha":"%s"},{"id":1,"head_commit_sha":"%s"}]\n' "${HEAD_SHA}" "${OTHER_SHA}" > "${FX}/versions.out"; }
reset_fx; nogate_fx; versions_fx; plant "${OTHER_SHA}" "${TIP_FX}"
receipt_refused R9 "criterion 6: a re-pushed head (receipt only for the earlier head) -> mr merge refused" "NO RECEIPT" "${MERGE_ARGS[@]}"
[[ "$(grep -m1 'Fix:' <<<"${ERR}")" == *"re-gate the new head"*"${HEAD_SHA}"* ]] && [[ "${ERR}" == *"${OTHER_SHA}"* ]] \
  && ok "R9b. the refusal names the gated earlier head and its Fix says to re-gate the new head" || bad "R9b. re-gate Fix" "$(detail)"
reset_fx; nogate_fx; versions_fx; plant "${OTHER_SHA}" "${TIP_FX}"
receipt_refused R9c "criterion 6: the same on the train" "NO RECEIPT" "${BOARD_ARGS[@]}"
[[ "$(grep -m1 'Fix:' <<<"${ERR}")" == *"re-gate the new head"* ]] && ok "R9d. train refusal says re-gate the new head" || bad "R9d. train re-gate Fix" "$(detail)"
reset_fx; nogate_fx; fx versions '' 1 'glab: 500'
receipt_refused R9e "the version history cannot be read -> still refused as NO RECEIPT" "NO RECEIPT" "${MERGE_ARGS[@]}"

# The reader's other outcomes, through this guard.
reset_fx; nogate_fx; plant "${HEAD_SHA}" "${OLD_TIP}"
run "${MERGE_ARGS[@]}"
if ran_once "${MERGE_ARGS[@]}" && [[ "${ERR}" == *"BASE MOVED"* ]]; then ok "R10. a receipt on an ancestor of the target tip -> runs, and says the base moved (DND-1463)"
else bad "R10. ancestor base" "$(detail)"; fi
reset_fx; nogate_fx; plant "${HEAD_SHA}" "${SIDE_FX}"
receipt_refused R11 "a receipt on a base that is not an ancestor of the target tip -> refused" "RECEIPT FOR ANOTHER BASE" "${MERGE_ARGS[@]}"
reset_fx; green_fx
jq 'del(.seal, .producer)' "${STORE_FX}/${HEAD_SHA}.json" > "${STORE_FX}/f.tmp" && mv "${STORE_FX}/f.tmp" "${STORE_FX}/${HEAD_SHA}.json"
receipt_refused R12 "a forged (unsealed) receipt -> refused (DND-1814)" "RECEIPT UNVERIFIED" "${MERGE_ARGS[@]}"
reset_fx; nogate_fx; plant "${HEAD_SHA}" "${TIP_FX}" red
receipt_refused R13 "a receipt whose verdict is not pass -> refused" "RECEIPT INVALID" "${MERGE_ARGS[@]}"
reset_fx; green_fx; chmod 000 "${STORE_FX}"
run "${MERGE_ARGS[@]}"; chmod 700 "${STORE_FX}"
if refused && [[ "${ERR}" == *"COULD NOT LOOK"* ]] && [[ "${ERR}" != *"NO RECEIPT"* ]]; then ok "R14. an unsearchable store -> COULD NOT LOOK, never NO RECEIPT"
else bad "R14. unsearchable store" "$(detail)"; fi

# Where the receipt is read from: the checkout of the MR's own project.
reset_fx; green_fx; cd "${TMP}/not-a-repo" || exit 2
receipt_refused R15 "run outside any checkout -> refused (COULD NOT LOOK)" "COULD NOT LOOK" "${MERGE_ARGS[@]}"
cd "${REPO_FX}" || exit 2
for other in "git@gitlab.com:example-group/other-app.git" "git@evil-gitlab.com:example-group/example-app.git" "https://gitlab.com/x/example-group/example-app.git"; do
  OFX="${TMP}/other-$RANDOM"; git init -q -b main "${OFX}"; git -C "${OFX}" remote add origin "${other}"
  reset_fx; green_fx; cd "${OFX}" || exit 2
  receipt_refused "R16 ${other}" "a checkout of another project -> refused (COULD NOT LOOK)" "COULD NOT LOOK" "${MERGE_ARGS[@]}"
  cd "${REPO_FX}" || exit 2
done
WT_FX="${TMP}/example-app-wt"
git -C "${REPO_FX}" worktree add -q --detach "${WT_FX}" "${OLD_TIP}" 2>/dev/null
reset_fx; green_fx; cd "${WT_FX}" || exit 2
receipt_ran R17 "run from a linked worktree -> reads the shared git common dir, runs" "${MERGE_ARGS[@]}"
cd "${REPO_FX}" || exit 2
HTTPS_FX="${TMP}/https-app"; git init -q -b main "${HTTPS_FX}"; git -C "${HTTPS_FX}" remote add origin "https://gitlab.com/Example-Group/Example-App.git"
reset_fx; green_fx; cd "${HTTPS_FX}" || exit 2
run "${MERGE_ARGS[@]}"
if refused && [[ "${ERR}" == *"NO RECEIPT"* ]] && [[ "${ERR}" == *"${HTTPS_FX}"* ]]; then ok "R18. an https remote (any case) matches the project; its own store is the one read"
else bad "R18. https remote matches" "$(detail)"; fi
cd "${REPO_FX}" || exit 2
# matched_in <id> <label> <dir> : run from <dir>, the guard took it as the MR's
# checkout: it searched <dir>'s own store (empty) and refused NO RECEIPT.
matched_in() {
  cd "$3" || exit 2
  run "${MERGE_ARGS[@]}"
  cd "${REPO_FX}" || exit 2
  if refused && [[ "${ERR}" == *"NO RECEIPT"* ]] && [[ "${ERR}" == *"$3/.git/integration-receipts"* ]]; then ok "$1. $2"
  else bad "$1. $2" "$(detail)"; fi
}
SSH_FX="${TMP}/ssh-app"; git init -q -b main "${SSH_FX}"; git -C "${SSH_FX}" remote add origin "ssh://git@gitlab.com:2222/example-group/example-app.git/"
reset_fx; green_fx; matched_in R26 "an ssh:// remote with a port and a trailing .git/ matches the project" "${SSH_FX}"
TWO_FX="${TMP}/two-app"; git init -q -b main "${TWO_FX}"
git -C "${TWO_FX}" remote add fork "git@gitlab.com:someone/example-app.git"; git -C "${TWO_FX}" remote add origin "git@gitlab.com:example-group/example-app.git"
reset_fx; green_fx; matched_in R27 "a checkout whose second remote is the project matches" "${TWO_FX}"
SUB_FX="${TMP}/sub-app"; git init -q -b main "${SUB_FX}"; git -C "${SUB_FX}" remote add origin "git@gitlab.com:example-group/sub/example-app.git"
reset_fx; green_fx; for f in mrview mrapi; do jq -c '.web_url = "https://gitlab.com/example-group/sub/example-app/-/merge_requests/4242"' "${FX}/${f}.out" > "${FX}/${f}.tmp" && mv "${FX}/${f}.tmp" "${FX}/${f}.out"; done
matched_in R28 "a nested subgroup project matches its checkout" "${SUB_FX}"
DOT_FX="${TMP}/dot-app"; git init -q -b main "${DOT_FX}"; git -C "${DOT_FX}" remote add origin "git@gitlabxcom:example-group/example-app.git"
reset_fx; green_fx; cd "${DOT_FX}" || exit 2
receipt_refused R29 "a remote host that matches only if '.' were a wildcard -> refused" "COULD NOT LOOK" "${MERGE_ARGS[@]}"
cd "${REPO_FX}" || exit 2
reset_fx; green_fx
receipt_refused R30 "train boarding with --hostname naming another host than the MR's -> refused" "is not the MR's host" api --hostname other.example.com -X POST "${TRAIN}" -f "sha=${HEAD_SHA}"
reset_fx; green_fx
receipt_ran R31 "mr merge reads the target tip on the MR's own host" "${MERGE_ARGS[@]}"
[[ "$(reads)" == *"api --hostname gitlab.com projects/7000001/repository/branches/main"* ]] \
  && ok "R31b. the tip read carries --hostname from the MR's web_url" || bad "R31b. hostname from web_url" "$(detail)"

# The target tip, read from the forge.
reset_fx; green_fx; fx branch '' 1 'glab: 404 Branch Not Found'
receipt_refused R19 "the target tip cannot be read -> refused (COULD NOT LOOK), the failure named" "COULD NOT LOOK" "${MERGE_ARGS[@]}"
[[ "${ERR}" == *"404 Branch Not Found"* ]] && ok "R19b. the forge's error is in the refusal" || bad "R19b. forge error named" "$(detail)"
reset_fx; green_fx; fx branch '{"commit":{"id":"not-a-sha"}}'
receipt_refused R20 "a target tip that is not a SHA -> refused" "COULD NOT LOOK" "${MERGE_ARGS[@]}"
reset_fx; green_fx; branch_is "0123456789abcdef0123456789abcdef01234567"
receipt_refused R21 "a target tip not in the local object store -> refused (COULD NOT LOOK), Fix says fetch" "COULD NOT LOOK" "${MERGE_ARGS[@]}"
[[ "${ERR}" == *"git fetch"* ]] && ok "R21b. the Fix says to fetch" || bad "R21b. fetch named" "$(detail)"
reset_fx; green_fx; jq -c 'del(.web_url)' "${FX}/mrview.out" > "${FX}/m.tmp" && mv "${FX}/m.tmp" "${FX}/mrview.out"
receipt_refused R22 "an MR read with no web_url (project unknown) -> refused" "COULD NOT LOOK" "${MERGE_ARGS[@]}"
reset_fx; green_fx; jq -c 'del(.target_branch)' "${FX}/mrview.out" > "${FX}/m.tmp" && mv "${FX}/m.tmp" "${FX}/mrview.out"
receipt_refused R23 "an MR read with no target_branch -> refused" "COULD NOT LOOK" "${MERGE_ARGS[@]}"
reset_fx; green_fx
receipt_ran R24 "train boarding with --hostname -> runs" api --hostname gitlab.com -X POST "${TRAIN}" -f "sha=${HEAD_SHA}"
[[ "$(reads)" == *"api --hostname gitlab.com projects/7000001/repository/branches/main"* ]] \
  && ok "R24b. the target tip is read on the same host" || bad "R24b. hostname on the branch read" "$(detail)"
reset_fx; green_fx; for f in mrview mrapi; do jq -c '.target_branch = "release/2026.10"' "${FX}/${f}.out" > "${FX}/${f}.tmp" && mv "${FX}/${f}.tmp" "${FX}/${f}.out"; done
receipt_ran R25 "a target branch with a slash -> runs" "${MERGE_ARGS[@]}"
[[ "$(reads)" == *"repository/branches/release%2F2026.10"* ]] && ok "R25b. the branch name is URL-encoded in the read" || bad "R25b. branch encoding" "$(detail)"

echo
echo "--- the dry-run seam ---"
reset_fx; green_fx
OUT="$(GLAB_ATHENA_MERGE_DRY_RUN=1 "${WRAPPER}" mr merge 4242 --sha "${HEAD_SHA}" 2>"${TMP}/err")"; RC=$?; ERR="$(cat "${TMP}/err")"
if [ "${RC}" = 0 ] && [[ "${OUT}" == *"dry-run: would exec glab mr merge 4242 --sha ${HEAD_SHA}"* ]] && [ ! -s "${STUB_EXECS}" ] && [ -s "${STUB_READS}" ]; then
  ok "D1. dry-run runs the guard's reads and execs nothing"
else bad "D1. dry-run seam" "$(detail)"; fi
reset_fx; green_fx
OUT="$(GLAB_ATHENA_MERGE_DRY_RUN=1 "${WRAPPER}" mr merge 4242 2>"${TMP}/err")"; RC=$?; ERR="$(cat "${TMP}/err")"
if refused; then ok "D2. dry-run still refuses"; else bad "D2. dry-run refusal" "$(detail)"; fi
reset_fx; nogate_fx
OUT="$(GLAB_ATHENA_MERGE_DRY_RUN=1 "${WRAPPER}" mr merge 4242 --sha "${HEAD_SHA}" 2>"${TMP}/err")"; RC=$?; ERR="$(cat "${TMP}/err")"
if refused && [[ "${ERR}" == *"NO RECEIPT"* ]]; then ok "D3. dry-run with no receipt refuses the same way (DND-1845)"; else bad "D3. dry-run receipt refusal" "$(detail)"; fi

# DND-1647: no gh/glab call may have fallen through past its stub.
if fsg_verify; then ok "no gh/glab call fell through past its stub (DND-1647)"
else bad "no gh/glab call fell through past its stub (DND-1647)" "see the forge-stub-guard FAIL above"; fi

echo
echo "==================================================="
echo "RESULT: ${PASS} passed, ${FAIL} failed"
if [ "${FAIL}" = 0 ]; then echo "ALL CASES PASS"; exit 0; fi
exit 1
