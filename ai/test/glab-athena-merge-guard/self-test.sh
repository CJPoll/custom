#!/usr/bin/env bash
# Self-test for the glab-athena merge guard (DND-742).
#
# The defect this pins: glab-athena ran every command as-is. `glab-athena mr
# merge` with no --sha, or while the head pipeline was running or red, went to
# GitLab, and so did `glab-athena api` merges (REST PUT …/merge, a merge-train
# POST, GraphQL mergeRequestAccept). The wrapper now requires, on every merge
# path it lets through, a pin of the MR's exact head SHA and a head pipeline
# that PASSED on that head; the REST merge route, mergeRequestAccept and `mcp
# serve` are refused outright. Design and measurements: the header of
# ai/lib/glab-merge-guard.sh. Old-vs-new evidence and mutation results:
# SABOTAGE_RECORDS.md next to this file.
#
# NO NETWORK, EVER. `glab` is a stub on PATH. It answers the guard's three reads
# (`mr view … -F json`, `api projects/<p>/merge_requests/<iid>`, `api
# projects/<p>/repository/commits/<sha>`) from fixture files, and records every
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
printf '%s\n' "$all" >> "${STUB_EXECS}"
echo "stub: ran $all"
exit 0
STUB
chmod +x "${TMP}/bin/glab"
export PATH="${TMP}/bin:${PATH}"

# Shapes measured on amby_ai/walt_ui !1473 (2026-09-26): the open MR's head
# pipeline is a merged-results pipeline on refs/merge-requests/1473/merge, whose
# commit's parents are [target, head].
HEAD_SHA="4cc5665184c838efca81646c61b461e72e6ea145"
MERGE_SHA="e8feb98c3218bbc35a684bcd047ada5d94e0f176"
TARGET_SHA="fb181a4274258faf3b2a7ba8e6b438e0c490a6e9"
OTHER_SHA="0e134e88662690fe8edde401fa79bf44aa688eec"

reset_fx() { rm -f "${FX}"/* "${STUB_READS}" "${STUB_EXECS}"; : > "${STUB_READS}"; : > "${STUB_EXECS}"; }

# mr_json <status> [pipeline sha] [pipeline ref] [head] [iid] -> an MR object.
mr_json() {
  printf '{"iid":%s,"project_id":80626362,"sha":"%s","web_url":"https://gitlab.com/amby_ai/walt_ui/-/merge_requests/%s","head_pipeline":{"id":2884842816,"sha":"%s","ref":"%s","status":"%s"}}\n' \
    "${5:-1473}" "${4:-${HEAD_SHA}}" "${5:-1473}" "${2:-${MERGE_SHA}}" "${3:-refs/merge-requests/1473/merge}" "$1"
}
# green_fx : every read answers "passed merged-results pipeline on the head".
green_fx() {
  mr_json success > "${FX}/mrview.out"
  mr_json success > "${FX}/mrapi.out"
  printf '{"id":"%s","parent_ids":["%s","%s"]}\n' "${MERGE_SHA}" "${TARGET_SHA}" "${HEAD_SHA}" > "${FX}/commit.out"
}
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
expect_refused M1 "mr merge with no --sha is refused, naming the head" "${HEAD_SHA}" mr merge 1473 --yes
reset_fx; green_fx
expect_ran M2 "mr merge --sha <head> with a passed merged-results pipeline runs" any mr merge 1473 --sha "${HEAD_SHA}" --yes
if [[ "$(reads)" == *"repository/commits/${MERGE_SHA}"* ]]; then ok "M2b. the merged-results commit was read to tie the pipeline to the head"
else bad "M2b. merged-results commit read" "$(detail)"; fi
reset_fx; green_fx
expect_refused M3 "mr merge --sha <not the head> is refused" "not the MR's head" mr merge 1473 --sha "${OTHER_SHA}" --yes
reset_fx; status_fx running
expect_refused M4 "a running head pipeline is refused (auto-merge default)" "'running', not success" mr merge 1473 --sha "${HEAD_SHA}" --yes
reset_fx; status_fx running
expect_refused M4b "a running head pipeline is refused with --auto-merge" "'running', not success" mr merge 1473 --sha "${HEAD_SHA}" --auto-merge --yes
reset_fx; status_fx running
expect_refused M4c "a running head pipeline is refused with --when-pipeline-succeeds" "'running', not success" mr merge 1473 --sha "${HEAD_SHA}" --when-pipeline-succeeds --yes
reset_fx; status_fx failed
expect_refused M5 "a failed head pipeline is refused" "'failed', not success" mr merge 1473 --sha "${HEAD_SHA}" --yes
reset_fx; green_fx
printf '{"iid":1473,"project_id":80626362,"sha":"%s","head_pipeline":null}\n' "${HEAD_SHA}" > "${FX}/mrview.out"
expect_refused M6 "no head pipeline is refused" "has no head pipeline" mr merge 1473 --sha "${HEAD_SHA}" --yes
reset_fx; green_fx; mr_json success "${HEAD_SHA}" "feature-branch" > "${FX}/mrview.out"
expect_ran M7 "a passed pipeline ON the head (branch pipeline) runs" any mr merge 1473 --sha "${HEAD_SHA}" --yes
if [[ "$(reads)" != *"repository/commits"* ]]; then ok "M7b. no commit read when the pipeline sha is the head"
else bad "M7b. unexpected commit read" "$(detail)"; fi
reset_fx; green_fx
printf '{"id":"%s","parent_ids":["%s","%s"]}\n' "${MERGE_SHA}" "${TARGET_SHA}" "${OTHER_SHA}" > "${FX}/commit.out"
expect_refused M8 "a merged-results commit whose 2nd parent is not the head is refused" "do not end in head" mr merge 1473 --sha "${HEAD_SHA}" --yes
reset_fx; green_fx; mr_json success "216e40abc081b59f341d2d1de2fdd12facee7772" "refs/merge-requests/1473/train" > "${FX}/mrview.out"
expect_refused M9 "a merge-train head pipeline cannot be tied and is refused" "cannot be tied" mr merge 1473 --sha "${HEAD_SHA}" --yes
reset_fx; green_fx; fx commit '' 1 'glab: 404 Commit Not Found'
expect_refused M10 "a failed commit read is refused" "could not read the merged-results commit" mr merge 1473 --sha "${HEAD_SHA}" --yes
reset_fx; fx mrview '' 1 'glab: 404 Not Found'
expect_refused M11 "a failed MR read is refused" "could not read the MR" mr merge 1473 --sha "${HEAD_SHA}" --yes
reset_fx; green_fx
expect_refused M12 "mr accept (merge's alias) with no --sha is refused" "no sha was given" mr accept 1473 --yes
reset_fx; green_fx
expect_refused M13 "--repo before the subcommand, no --sha, is refused" "no sha was given" --repo amby_ai/walt_ui mr merge 1473 --yes
reset_fx; green_fx
expect_refused M13b "mr -R <repo> merge, no --sha, is refused" "no sha was given" mr -R amby_ai/walt_ui merge 1473
if [[ "$(reads)" == *"mr view 1473 -R amby_ai/walt_ui -F json"* ]]; then ok "M13c. the MR is read in the -R project"
else bad "M13c. -R carried into the read" "$(detail)"; fi
reset_fx; green_fx
expect_ran M14 "--sha=<head> with combined short flags runs" any mr merge 1473 "--sha=${HEAD_SHA}" -sdy
reset_fx; green_fx
expect_ran M14b "--sha <head> --auto-merge with a passed pipeline runs" any mr merge 1473 --sha "${HEAD_SHA}" --auto-merge --yes
reset_fx; green_fx
expect_refused M15 "an unknown mr merge flag is refused" "--bogus" mr merge 1473 --sha "${HEAD_SHA}" --bogus
reset_fx; green_fx
expect_refused M16 "--sha given twice is refused" "2 times" mr merge 1473 --sha "${OTHER_SHA}" --sha "${HEAD_SHA}"
reset_fx
expect_ran M17 "mr merge --help runs with no reads" none mr merge --help
reset_fx; green_fx
expect_refused M18 "an unknown flag before the subcommand is refused" "comes before the subcommand" --bogus x mr merge 1473 --sha "${HEAD_SHA}"
reset_fx; green_fx; printf '{"iid":1473,"sha":"%s","head_pipeline":{"status":"success"}}\n' "${HEAD_SHA}" > "${FX}/mrview.out"
expect_refused M19 "an MR read with no project_id is refused" "no usable sha" mr merge 1473 --sha "${HEAD_SHA}"
reset_fx; green_fx
printf '{"id":"%s","parent_ids":["%s"]}\n' "${MERGE_SHA}" "${HEAD_SHA}" > "${FX}/commit.out"
expect_refused M20 "a merged-results commit with one parent is refused" "do not end in head" mr merge 1473 --sha "${HEAD_SHA}"
reset_fx; green_fx
expect_ran M21 "no selector: the current branch's MR, pinned and green, runs" any mr merge --sha "${HEAD_SHA}" --yes
if [[ "$(reads)" == *"mr view -F json"* ]]; then ok "M21b. the current-branch MR was read"; else bad "M21b. current-branch read" "$(detail)"; fi
reset_fx; green_fx
expect_refused M22 "mr merge -R<repo> attached, no --sha, is refused" "no sha was given" mr merge -Ramby_ai/walt_ui 1473

echo
echo "--- api: the REST merge route is refused outright ---"
reset_fx; green_fx
expect_refused A1 "PUT projects/:id/merge_requests/<iid>/merge" "REST merge" api -X PUT "projects/:id/merge_requests/1473/merge"
reset_fx
expect_refused A2 "--method=put, encoded project, query string" "REST merge" api --method=put "projects/amby_ai%2Fwalt_ui/merge_requests/1473/merge?sha=${HEAD_SHA}"
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

echo
echo "--- api: merge-train boarding is the guarded path ---"
reset_fx; green_fx
expect_refused T1 "boarding with no sha field is refused" "no sha was given" api -X POST "projects/:id/merge_trains/merge_requests/1473"
reset_fx; green_fx
expect_ran T2 "boarding with -f sha=<head>, passed pipeline, runs" any api -X POST "projects/:id/merge_trains/merge_requests/1473" -f "sha=${HEAD_SHA}"
if [[ "$(reads)" == *"api projects/:id/merge_requests/1473"* ]]; then ok "T2b. the MR was read in the same project"
else bad "T2b. MR read endpoint" "$(detail)"; fi
reset_fx; green_fx
expect_refused T3 "boarding with a sha that is not the head" "not the MR's head" api -X POST "projects/:id/merge_trains/merge_requests/1473" -f "sha=${OTHER_SHA}"
reset_fx; status_fx running
expect_refused T4 "boarding while the head pipeline runs" "'running', not success" api -X POST "projects/:id/merge_trains/merge_requests/1473" -f "sha=${HEAD_SHA}"
reset_fx; green_fx; printf '%s' "${HEAD_SHA}" > "${TMP}/sha.txt"
expect_refused T5 "the sha field read from a file" "read from a file" api -X POST "projects/:id/merge_trains/merge_requests/1473" -F "sha=@${TMP}/sha.txt"
reset_fx; green_fx
expect_refused T6 "a query string on the train endpoint" "query string" api -X POST "projects/:id/merge_trains/merge_requests/1473?sha=${HEAD_SHA}"
reset_fx; green_fx; printf '{"sha":"%s"}' "${HEAD_SHA}" > "${TMP}/body.json"
expect_refused T7 "--input body on the train endpoint" "--input or --form" api -X POST "projects/:id/merge_trains/merge_requests/1473" --input "${TMP}/body.json"
reset_fx; green_fx
expect_refused T8 "sha given twice" "2 times" api -X POST "projects/:id/merge_trains/merge_requests/1473" -f "sha=${OTHER_SHA}" -f "sha=${HEAD_SHA}"
reset_fx; green_fx
expect_refused T9 "PUT on a car" "not the boarding call" api -X PUT "projects/:id/merge_trains/merge_requests/1473" -f "sha=${HEAD_SHA}"
reset_fx
expect_ran T10 "DELETE a car (take it off the train) runs with no reads" none api -X DELETE "projects/:id/merge_trains/merge_requests/1473"
reset_fx
expect_ran T11 "GET a car runs with no reads" none api "projects/:id/merge_trains/merge_requests/1473"
reset_fx; green_fx
expect_ran T12 "auto_merge=true plus the pin, passed pipeline, runs" any api -X POST "projects/:id/merge_trains/merge_requests/1473" -f auto_merge=true -f "sha=${HEAD_SHA}"
reset_fx; green_fx
expect_ran T13 "an encoded project path" any api -X POST "projects/amby_ai%2Fwalt_ui/merge_trains/merge_requests/1473" -f "sha=${HEAD_SHA}"
if [[ "$(reads)" == *"api projects/amby_ai%2Fwalt_ui/merge_requests/1473"* ]]; then ok "T13b. the encoded project was re-encoded for the MR read"
else bad "T13b. encoded project read" "$(detail)"; fi
reset_fx; green_fx; mr_json success > "${FX}/mrapi.out"; mr_json success "${MERGE_SHA}" "refs/merge-requests/1473/merge" "${HEAD_SHA}" 99 > "${FX}/mrapi.out"
expect_refused T14 "the MR read back is a different iid" "is not !1473" api -X POST "projects/:id/merge_trains/merge_requests/1473" -f "sha=${HEAD_SHA}"
reset_fx; fx mrapi '' 1 'glab: 404 Not Found'
expect_refused T15 "a failed MR read" "could not read !1473" api -X POST "projects/:id/merge_trains/merge_requests/1473" -f "sha=${HEAD_SHA}"
reset_fx; green_fx
expect_refused T16 "DELETE with a method-override header" "not the boarding call" api -X DELETE -H "X-HTTP-Method-Override: POST" "projects/:id/merge_trains/merge_requests/1473"
reset_fx; green_fx
expect_ran T17 "no method, sha field -> POST, guarded, runs" any api "projects/:id/merge_trains/merge_requests/1473" -f "sha=${HEAD_SHA}"
reset_fx; green_fx
expect_ran T18 "--hostname is carried into the MR read" any api --hostname gitlab.com -X POST "projects/:id/merge_trains/merge_requests/1473" -f "sha=${HEAD_SHA}"
if [[ "$(reads)" == *"api --hostname gitlab.com projects/:id/merge_requests/1473"* ]]; then ok "T18b. hostname in the read"
else bad "T18b. hostname in the read" "$(detail)"; fi
reset_fx; green_fx
expect_refused T19 "a _method field on the train endpoint" "_method" api -X POST "projects/:id/merge_trains/merge_requests/1473" -f "sha=${HEAD_SHA}" -f "_method=PUT"
reset_fx; green_fx; status_fx failed
expect_refused T20 "boarding with a failed head pipeline" "'failed', not success" api "projects/:id/merge_trains/merge_requests/1473" -F "sha=${HEAD_SHA}"

echo
echo "--- api graphql: mergeRequestAccept is refused wherever the query comes from ---"
Q='mutation { mergeRequestAccept(input: {projectPath: "amby_ai/walt_ui", iid: "1473", sha: "x"}) { errors } }'
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

echo
echo "--- negatives: reads and non-merge writes pass as-is, with no extra reads ---"
reset_fx; expect_ran N1 "mr view" none mr view 1473
reset_fx; expect_ran N2 "mr create" none mr create --fill --yes --target-branch main
reset_fx; expect_ran N3 "mr note whose text says merge" none mr note 1473 --message "please merge"
reset_fx; expect_ran N4 "api GET an MR" none api "projects/:id/merge_requests/1473"
reset_fx; expect_ran N5 "api POST approve" none api -X POST "projects/:id/merge_requests/1473/approve"
reset_fx; expect_ran N6 "api GET the active train" none api "projects/:id/merge_trains?scope=active"
reset_fx; expect_ran N7 "api POST a note" none api -X POST "projects/:id/merge_requests/1473/notes" -f "body=merge soon"
reset_fx; expect_ran N8 "api POST cancel auto-merge" none api -X POST "projects/:id/merge_requests/1473/cancel_merge_when_pipeline_succeeds"
reset_fx; expect_ran N9 "api GET merge_ref" none api "projects/:id/merge_requests/1473/merge_ref"
reset_fx; expect_ran N10 "ci status" none ci status
reset_fx; expect_ran N11 "api PUT MR labels" none api -X PUT "projects/:id/merge_requests/1473" -f "labels=Auto-Deploy"
reset_fx; expect_ran N12 "mr list" none mr list
reset_fx; expect_ran N13 "api POST a pipeline for the MR" none api -X POST "projects/:id/merge_requests/1473/pipelines"
reset_fx; expect_ran N14 "mr create whose title says merge" none mr create --title merge --description "merge accept api" --yes
reset_fx; expect_ran N15 "help mr merge" none help mr merge

echo
echo "--- the dry-run seam ---"
reset_fx; green_fx
OUT="$(GLAB_ATHENA_MERGE_DRY_RUN=1 "${WRAPPER}" mr merge 1473 --sha "${HEAD_SHA}" 2>"${TMP}/err")"; RC=$?; ERR="$(cat "${TMP}/err")"
if [ "${RC}" = 0 ] && [[ "${OUT}" == *"dry-run: would exec glab mr merge 1473 --sha ${HEAD_SHA}"* ]] && [ ! -s "${STUB_EXECS}" ] && [ -s "${STUB_READS}" ]; then
  ok "D1. dry-run runs the guard's reads and execs nothing"
else bad "D1. dry-run seam" "$(detail)"; fi
reset_fx; green_fx
OUT="$(GLAB_ATHENA_MERGE_DRY_RUN=1 "${WRAPPER}" mr merge 1473 2>"${TMP}/err")"; RC=$?; ERR="$(cat "${TMP}/err")"
if refused; then ok "D2. dry-run still refuses"; else bad "D2. dry-run refusal" "$(detail)"; fi

echo
echo "==================================================="
echo "RESULT: ${PASS} passed, ${FAIL} failed"
if [ "${FAIL}" = 0 ]; then echo "ALL CASES PASS"; exit 0; fi
exit 1
