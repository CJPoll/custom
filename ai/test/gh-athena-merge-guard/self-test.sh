#!/usr/bin/env bash
# Self-test for the gh-athena merge guard (DND-609).
#
# The defect this pins: on 2026-09-25 06:03Z `gh-athena pr merge 362 --squash
# --auto` merged gen_saas PR #362 IMMEDIATELY while CI run 36100824066 on head
# b712de1d was still queued. `--auto` waits only on the base branch's REQUIRED
# checks, and CJPoll/gen_saas has none: branch protection and rulesets both
# answer 403 "Upgrade to GitHub Pro". The skills said "branch protection is the
# gate" -- a mechanism that could not fire. The wrapper now:
#   * REFUSES `pr merge --auto` unless it can READ a non-empty required-checks
#     set for the PR's base branch. An empty set, a 403/404, or any failed
#     lookup is "could not establish a gate", never "fine".
#   * REFUSES a non-auto `pr merge` unless it names the exact head with
#     --match-head-commit <sha> and every check reported on that head concluded
#     green. Zero reported checks is not green.
#   * REFUSES every `gh api` call that merges (DND-728): REST …/pulls/<n>/merge,
#     …/merges, …/merge-upstream, and the GraphQL merge mutations, however the
#     method, endpoint or query is spelled or supplied.
#   * REFUSES every `gh api` write that creates or moves a ref (DND-741): REST
#     …/git/refs (not a plain DELETE), …/contents/…, …/branches/<b>/rename,
#     …/pulls/<n>/update-branch, and the GraphQL ref-write mutations, on ANY
#     branch, by the same parser. A ref DELETE and deleteRef pass.
#   Old-vs-new evidence and mutation results: SABOTAGE_RECORDS.md next to this
#   file.
#
# NO NETWORK, EVER. `gh` is a stub on PATH that answers from fixture files and
# logs every call; the App token comes from a fixture cache (no mint). The only
# write the stub knows is `pr merge`, and every refusal case asserts it was
# never called.
#
# Run against another copy of the wrapper (old-vs-new evidence) with
#   GH_ATHENA_UNDER_TEST=/path/to/gh-athena bash ai/test/gh-athena-merge-guard/self-test.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AI_DIR="$(cd "${HERE}/../.." && pwd)"
WRAPPER="${GH_ATHENA_UNDER_TEST:-${AI_DIR}/bin/gh-athena}"

TMP="$(mktemp -d)"; trap 'rm -rf "${TMP}"' EXIT
PASS=0; FAIL=0
ok()  { printf '  ok    %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  FAIL  %s\n        %s\n' "$1" "$2"; FAIL=$((FAIL+1)); }

# ---- hermetic environment ---------------------------------------------------
FAKE_TOKEN="ghs_SELFTESTFAKETOKEN0000"
printf '12345\n' > "${TMP}/app-id"
printf 'not-a-key\n' > "${TMP}/key.pem"
printf '%s\t%s\n' "${FAKE_TOKEN}" "$(( $(date +%s) + 86400 ))" > "${TMP}/token-cache"
chmod 600 "${TMP}/token-cache"
export GH_ATHENA_APP_ID_FILE="${TMP}/app-id"
export GH_ATHENA_KEY="${TMP}/key.pem"
export GH_ATHENA_TOKEN_CACHE="${TMP}/token-cache"
unset GH_ATHENA_MERGE_DRY_RUN GH_REPO

FX="${TMP}/fx"; mkdir -p "${FX}" "${TMP}/bin"
export STUB_FX="${FX}" STUB_LOG="${TMP}/calls.log"

# The stub gh. Each read answers from <fx>/<kind>.out (stdout), .err (stderr)
# and .rc (exit code, default 0). A missing .out with rc 0 is a stub bug, so it
# fails loudly instead of answering empty.
cat > "${TMP}/bin/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${STUB_LOG}"
[ "${GH_TOKEN:-}" = "ghs_SELFTESTFAKETOKEN0000" ] || { echo "stub: GH_TOKEN not the App token" >&2; exit 97; }
answer() {
  local k="$1" rc=0
  [ -f "${STUB_FX}/$k.rc" ] && rc="$(cat "${STUB_FX}/$k.rc")"
  [ -f "${STUB_FX}/$k.err" ] && cat "${STUB_FX}/$k.err" >&2
  if [ -f "${STUB_FX}/$k.out" ]; then cat "${STUB_FX}/$k.out"
  elif [ "$rc" = 0 ]; then echo "stub: no fixture for $k" >&2; exit 98; fi
  exit "$rc"
}
case "$*" in
  "pr view"*"--json"*) answer prview ;;
  "api repos/"*"/protection/required_status_checks"*) answer protection ;;
  "api repos/"*"/rules/branches/"*) answer rules ;;
  "alias list"*) answer aliases ;;
  "pr merge"*|"-R "*"pr merge"*|"--repo"*"pr merge"*) echo "stub: MERGED" ; exit 0 ;;
  *) echo "stub: passthrough $*"; exit 0 ;;
esac
STUB
chmod +x "${TMP}/bin/gh"
export PATH="${TMP}/bin:${PATH}"

HEAD_SHA="b712de1d0000000000000000000000000000beef"
OTHER_SHA="0e134e88662690fe8edde401fa79bf44aa688eec"

reset_fx() { rm -f "${FX}"/* "${STUB_LOG}"; : > "${STUB_LOG}"; printf '' > "${FX}/aliases.out"; }

# pr_view <rollup-json-array> [head]
pr_view() {
  printf '{"number":362,"url":"https://github.com/CJPoll/gen_saas/pull/362","baseRefName":"main","headRefOid":"%s","statusCheckRollup":%s}\n' \
    "${2:-${HEAD_SHA}}" "$1" > "${FX}/prview.out"
}
fx() { printf '%s' "$2" > "${FX}/$1.out"; printf '%s' "${3:-0}" > "${FX}/$1.rc"; [ -z "${4:-}" ] || printf '%s\n' "$4" > "${FX}/$1.err"; }

# The gen_saas shape, measured live 2026-09-25: both lookups 403.
gate_unreadable() {
  fx protection '{"message":"Resource not accessible by integration","status":"403"}' 1 'gh: Resource not accessible by integration (HTTP 403)'
  fx rules '{"message":"Upgrade to GitHub Pro or make this repository public to enable this feature.","status":"403"}' 1 'gh: Upgrade to GitHub Pro or make this repository public to enable this feature. (HTTP 403)'
}

GREEN='[{"__typename":"CheckRun","name":"Build","status":"COMPLETED","conclusion":"SUCCESS"},{"__typename":"CheckRun","name":"Lint","status":"COMPLETED","conclusion":"SKIPPED"},{"__typename":"CheckRun","name":"Info","status":"COMPLETED","conclusion":"NEUTRAL"},{"__typename":"StatusContext","context":"ext/ci","state":"SUCCESS"}]'
QUEUED='[{"__typename":"CheckRun","name":"Build","status":"COMPLETED","conclusion":"SUCCESS"},{"__typename":"CheckRun","name":"Test","status":"QUEUED","conclusion":""}]'

run() { OUT="$("${WRAPPER}" "$@" 2>"${TMP}/err")"; RC=$?; ERR="$(cat "${TMP}/err")"; }
merged()  { grep -q 'pr merge' "${STUB_LOG}"; }
refused() { [ "${RC}" = 3 ] && [[ "${ERR}" == *"REFUSING"* ]] && [[ "${ERR}" == *"Fix:"* ]] && ! merged; }
detail()  { printf 'rc=%s out=%q err=%q calls=%q' "${RC}" "${OUT}" "${ERR}" "$(cat "${STUB_LOG}")"; }

echo "gh-athena merge-guard self-test"
echo "wrapper: ${WRAPPER}"
echo

echo "--- --auto with NO readable required-checks gate is REFUSED before any write ---"
reset_fx; pr_view "${QUEUED}"; gate_unreadable
run pr merge 362 --squash --auto
if refused && [[ "${ERR}" == *"--match-head-commit"* ]] && [[ "${ERR}" == *"403"* ]] \
  && [[ "${ERR}" == *"could not establish"* ]]; then
  ok "1. the incident: --auto on gen_saas (protection 403, rules 403) -> refused, Fix names --match-head-commit, no merge call"
else bad "1. --auto refused when both lookups 403" "$(detail)"; fi

reset_fx; pr_view "${QUEUED}"
fx protection '{"message":"Branch not protected","status":"404"}' 1 'gh: Branch not protected (HTTP 404)'
fx rules '[]'
run pr merge 362 --squash --auto
refused && [[ "${ERR}" == *"404"* ]] && [[ "${ERR}" == *"0 required"* ]] \
  && ok "2. protection 404 + rules [] -> refused (empty set)" || bad "2. 404 + empty rules refused" "$(detail)"

reset_fx; pr_view "${QUEUED}"
fx protection '{"strict":true,"contexts":[],"checks":[]}'
fx rules '[{"type":"deletion","parameters":{}}]'
run pr merge 362 --squash --auto
refused && ok "3. protection readable but EMPTY + rules without required checks -> refused" \
  || bad "3. readable empty set refused" "$(detail)"

reset_fx; pr_view "${QUEUED}"
fx protection '' 1 'error connecting to api.github.com'
fx rules '' 1 'error connecting to api.github.com'
run pr merge 362 --squash --auto
refused && [[ "${ERR}" == *"error connecting"* ]] \
  && ok "4. both lookups fail with no body (network) -> refused, the failure is named" \
  || bad "4. failed lookup refused" "$(detail)"

reset_fx; pr_view "${QUEUED}"
fx protection 'not json' 0
fx rules '{"unexpected":"shape"}' 0
run pr merge 362 --squash --auto
refused && ok "5. malformed lookup bodies (exit 0) -> refused, never read as a gate" \
  || bad "5. malformed bodies refused" "$(detail)"

reset_fx; fx prview '' 1 'GraphQL: Could not resolve to a PullRequest with the number of 362.'
gate_unreadable
run pr merge 362 --squash --auto
refused && [[ "${ERR}" == *"Could not resolve"* ]] \
  && ok "6. the PR itself cannot be read -> refused" || bad "6. unreadable PR refused" "$(detail)"

reset_fx; pr_view "${QUEUED}"; gate_unreadable
run pr merge 362 --squash --auto=true
refused && ok "7. --auto=true -> refused" || bad "7. --auto=true refused" "$(detail)"

reset_fx; pr_view "${QUEUED}"; gate_unreadable
run -R CJPoll/gen_saas pr merge 362 --auto
refused && grep -q -- '-R CJPoll/gen_saas' "${STUB_LOG}" \
  && ok "8. -R <repo> before the subcommand -> refused, and the PR is read in that repo" \
  || bad "8. -R form refused" "$(detail)"

reset_fx; pr_view "${QUEUED}"; gate_unreadable
run pr merge --auto --squash
refused && ok "9. --auto with no PR selector (current branch) -> refused" || bad "9. no-selector refused" "$(detail)"

reset_fx; pr_view "${QUEUED}"; gate_unreadable
run pr merge 362 -sd --auto
refused && ok "10. combined short flags (-sd) do not hide --auto" || bad "10. -sd --auto refused" "$(detail)"

reset_fx; pr_view "${QUEUED}"; gate_unreadable
printf 'm: pr merge\n' > "${FX}/aliases.out"
run m 362 --auto
refused && grep -q '^pr view 362 ' "${STUB_LOG}" && ok "11. a gh alias expanding to pr merge -> expanded, judged, refused" \
  || bad "11. alias to pr merge refused" "$(detail)"

reset_fx; pr_view "${QUEUED}"; gate_unreadable
printf 'sm: !gh pr merge "$1" --auto\n' > "${FX}/aliases.out"
run sm 362
refused && [[ "${ERR}" == *"alias"* ]] && ok "12. a gh shell alias (!...) -> refused (cannot be checked)" \
  || bad "12. shell alias refused" "$(detail)"

reset_fx; pr_view "${QUEUED}"; gate_unreadable
printf 'co: pr checkout\np: pr\n' > "${FX}/aliases.out"
run p merge 362 --auto
refused && grep -q '^pr view 362 ' "${STUB_LOG}" \
  && ok "12b. an alias expanding to only part of it (p: pr, then \`p merge 362 --auto\`) -> expanded, refused" \
  || bad "12b. partial alias refused" "$(detail)"

reset_fx; pr_view "${QUEUED}"; gate_unreadable
printf 'x: pr $1 362 --auto\n' > "${FX}/aliases.out"
run x merge
refused && ok "12c. an alias whose \$1 placeholder receives 'merge' -> expanded, refused" \
  || bad "12c. placeholder alias refused" "$(detail)"

reset_fx; pr_view "${QUEUED}"; gate_unreadable
printf 'x: pr $1\n' > "${FX}/aliases.out"
run x merge 362 --auto
refused && grep -q '^pr view 362 ' "${STUB_LOG}" && [[ "${ERR}" == *"could not establish"* ]] \
  && ok "12c2. placeholder AND appended args in one expansion (x: pr \$1, then \`x merge 362 --auto\`) -> judged as --auto on 362" \
  || bad "12c2. placeholder + appended args" "$(detail)"

reset_fx; pr_view "${QUEUED}"; gate_unreadable
printf 'x: pr $1\n' > "${FX}/aliases.out"
run x '"merge"' 362 --auto
refused && [[ "${ERR}" == *"quoting"* ]] \
  && ok "12c3. an argument that brings a quote into the expansion -> refused (gh would shlex it)" \
  || bad "12c3. substituted quote refused" "$(detail)"

reset_fx; printf 'x: pr $1\n' > "${FX}/aliases.out"
run x 'view&' 362
if [ "${RC}" = 0 ] && [[ "${OUT}" == *"stub: passthrough"* ]]; then
  ok "12c4. an argument containing & is substituted literally (no patsub_replacement)"
else bad "12c4. & substituted literally" "$(detail)"; fi

reset_fx; fx aliases '' 1 'failed to read configuration'
run p merge 362 --auto
refused && [[ "${ERR}" == *"alias list"* ]] \
  && ok "12d. a non-gh first word when \`gh alias list\` FAILS -> refused (not read as no aliases)" \
  || bad "12d. failed alias lookup refused" "$(detail)"

reset_fx; fx aliases 'no aliases configured' 1
run myext do-thing
if [ "${RC}" = 0 ] && [[ "${OUT}" == *"stub: passthrough"* ]]; then
  ok "12e. gh's own 'no aliases configured' (exit 1) is an empty list -> a non-alias word runs"
else bad "12e. no-aliases passes" "$(detail)"; fi

reset_fx; printf 'pv: pr view\n' > "${FX}/aliases.out"
run pv 362
if [ "${RC}" = 0 ] && ! grep -q -- '--json' "${STUB_LOG}"; then
  ok "12f. an alias to a non-merge command (pv: pr view) runs as-is"
else bad "12f. non-merge alias passes" "$(detail)"; fi

echo
echo "--- --auto WITH a readable, non-empty required-checks set passes ---"
reset_fx; pr_view "${QUEUED}"
fx protection '{"message":"Resource not accessible by integration","status":"403"}' 1 'gh: Resource not accessible by integration (HTTP 403)'
fx rules '[{"type":"required_status_checks","parameters":{"strict_required_status_checks_policy":false,"required_status_checks":[{"context":"Test"}]}}]'
run pr merge 362 --squash --auto
if [ "${RC}" = 0 ] && [[ "${OUT}" == *"stub: MERGED"* ]] && grep -qx 'pr merge 362 --squash --auto' "${STUB_LOG}"; then
  ok "13. a ruleset requiring 1 check -> --auto passes, argv unchanged"
else bad "13. ruleset gate passes" "$(detail)"; fi

reset_fx; pr_view "${QUEUED}"
fx protection '{"strict":true,"contexts":["Test"],"checks":[{"context":"Test","app_id":1}]}'
fx rules '[]'
run pr merge 362 --squash --auto
[ "${RC}" = 0 ] && merged && ok "14. classic protection requiring checks -> --auto passes" \
  || bad "14. classic protection gate passes" "$(detail)"

echo
echo "--- a non-auto merge needs the exact head, and every check on it green ---"
reset_fx; pr_view "${GREEN}"
run pr merge 362 --squash
refused && [[ "${ERR}" == *"--match-head-commit"* ]] \
  && ok "15. no --match-head-commit -> refused" || bad "15. missing head pin refused" "$(detail)"

reset_fx; pr_view "${GREEN}"
run pr merge 362 --squash --match-head-commit "${OTHER_SHA}"
refused && [[ "${ERR}" == *"${HEAD_SHA}"* ]] \
  && ok "16. --match-head-commit != the PR head -> refused, names the real head" \
  || bad "16. head mismatch refused" "$(detail)"

reset_fx; pr_view "${QUEUED}"
run pr merge 362 --squash --match-head-commit "${HEAD_SHA}"
refused && [[ "${ERR}" == *"Test"* ]] && [[ "${ERR}" == *"QUEUED"* ]] \
  && ok "17. a QUEUED check on the head (the incident, non-auto) -> refused, names it" \
  || bad "17. queued check refused" "$(detail)"

reset_fx; pr_view '[{"__typename":"CheckRun","name":"Test","status":"COMPLETED","conclusion":"FAILURE"}]'
run pr merge 362 --squash --match-head-commit "${HEAD_SHA}"
refused && [[ "${ERR}" == *"FAILURE"* ]] && ok "18. a FAILURE check -> refused" || bad "18. failed check refused" "$(detail)"

reset_fx; pr_view '[{"__typename":"StatusContext","context":"ext/ci","state":"PENDING"}]'
run pr merge 362 --squash --match-head-commit "${HEAD_SHA}"
refused && [[ "${ERR}" == *"ext/ci"* ]] && ok "19. a PENDING commit status -> refused" || bad "19. pending status refused" "$(detail)"

reset_fx; pr_view '[]'
run pr merge 362 --squash --match-head-commit "${HEAD_SHA}"
refused && [[ "${ERR}" == *"no check"* ]] && ok "20. ZERO checks reported on the head -> refused (not green)" \
  || bad "20. zero checks refused" "$(detail)"

reset_fx; pr_view 'null'
run pr merge 362 --squash --match-head-commit "${HEAD_SHA}"
refused && ok "21. a null rollup -> refused" || bad "21. null rollup refused" "$(detail)"

reset_fx; pr_view "${QUEUED}"
run pr merge 362 --squash --auto=false --match-head-commit "${HEAD_SHA}"
refused && [[ "${ERR}" == *"QUEUED"* ]] && ok "22. --auto=false takes the non-auto path (checks asserted)" \
  || bad "22. --auto=false is non-auto" "$(detail)"

reset_fx; pr_view "${GREEN}"
run pr merge 362 --squash --match-head-commit "${HEAD_SHA}"
if [ "${RC}" = 0 ] && grep -qx "pr merge 362 --squash --match-head-commit ${HEAD_SHA}" "${STUB_LOG}"; then
  ok "23. every check SUCCESS/SKIPPED/NEUTRAL + exact head -> merge runs, argv unchanged"
else bad "23. green head merges" "$(detail)"; fi

reset_fx; pr_view "${GREEN}"
run pr merge 362 --squash "--match-head-commit=${HEAD_SHA}"
[ "${RC}" = 0 ] && merged && ok "24. --match-head-commit=<sha> form accepted" || bad "24. = form" "$(detail)"

echo
echo "--- dry-run seam: decides, never writes ---"
reset_fx; pr_view "${GREEN}"
OUT="$(GH_ATHENA_MERGE_DRY_RUN=1 "${WRAPPER}" pr merge 362 --squash --match-head-commit "${HEAD_SHA}" 2>"${TMP}/err")"; RC=$?; ERR="$(cat "${TMP}/err")"
if [ "${RC}" = 0 ] && [[ "${OUT}" == *"dry-run: would exec gh pr merge 362"* ]] && ! merged; then
  ok "25. GH_ATHENA_MERGE_DRY_RUN=1 on an allowed merge -> reports, no merge call"
else bad "25. dry-run allowed" "$(detail)"; fi

reset_fx; pr_view "${QUEUED}"; gate_unreadable
OUT="$(GH_ATHENA_MERGE_DRY_RUN=1 "${WRAPPER}" pr merge 362 --squash --auto 2>"${TMP}/err")"; RC=$?; ERR="$(cat "${TMP}/err")"
refused && ok "26. dry-run on a refused merge -> the same refusal (exit 3)" || bad "26. dry-run refused" "$(detail)"

echo
echo "--- NEGATIVE: what must pass untouched ---"
reset_fx
run pr view 362
if [ "${RC}" = 0 ] && [ "$(cat "${STUB_LOG}")" = "pr view 362" ]; then
  ok "27. a non-merge command runs as-is, with no extra reads"
else bad "27. non-merge untouched" "$(detail)"; fi

reset_fx
run pr merge 362 --disable-auto
if [ "${RC}" = 0 ] && [ "$(cat "${STUB_LOG}")" = "pr merge 362 --disable-auto" ]; then
  ok "28. pr merge --disable-auto (merges nothing) runs as-is"
else bad "28. --disable-auto untouched" "$(detail)"; fi

if [[ "$(cat "${STUB_LOG}")${OUT}${ERR}" != *"${FAKE_TOKEN}"* ]]; then
  ok "29. the token never appears in argv or output"
else bad "29. token leak" "$(detail)"; fi

echo
echo "--- DND-728: a \`gh api\` call that merges is REFUSED before gh runs ---"
# The DND-609 guard judged only `pr merge`, so every form below reached gh (the
# stub logged it and answered "passthrough"). Each is now refused with exit 3
# and a Fix: naming the guarded path, and gh is never called at all: the stub
# log stays EMPTY (`api` is a gh builtin, so not even `alias list` runs).
PR_PATH="repos/CJPoll/gen_saas/pulls/388/merge"
MUT_MERGE='mutation { mergePullRequest(input: {pullRequestId: "PR_x", mergeMethod: SQUASH}) { clientMutationId } }'
printf '%s\n' "${MUT_MERGE}" > "${TMP}/merge.graphql"
jq -cn --arg q "${MUT_MERGE}" '{query: $q}' > "${TMP}/merge-body.json"
# The same mutation with its name spelled in JSON unicode escapes: jq decodes
# it, a text grep of the file would not.
printf '{"query":"mutation { \\u006dergePullRequest(input: {pullRequestId: \\"PR_x\\"}) { clientMutationId } }"}\n' > "${TMP}/merge-body-escaped.json"
printf 'mutation { mergePullRequest(input: {pullRequestId: "PR_x"}) { clientMutationId } \n' > "${TMP}/not-json.json"

# api_refused <label> <needle> <args...> : exit 3, REFUSING, a Fix: naming the
# guarded path, <needle> in the reason, and NO gh call.
api_refused() {
  local label="$1" needle="$2"; shift 2
  reset_fx; run "$@"
  if [ "${RC}" = 3 ] && [[ "${ERR}" == *"REFUSING"* ]] && [[ "${ERR}" == *"Fix:"* ]] \
    && [[ "${ERR}" == *"pr merge <n> --squash --match-head-commit <sha>"* ]] \
    && [[ "${ERR}" == *"${needle}"* ]] && [ ! -s "${STUB_LOG}" ]; then
    ok "${label}"
  else bad "${label}" "$(detail)"; fi
}
# api_passes <label> <args...> : reaches gh unchanged, exit 0.
api_passes() {
  local label="$1"; shift
  reset_fx; run "$@"
  if [ "${RC}" = 0 ] && [[ "${OUT}" == *"stub: passthrough api"* ]] && [ "$(cat "${STUB_LOG}")" = "$*" ]; then
    ok "${label}"
  else bad "${label}" "$(detail)"; fi
}

api_refused "A1. REST: api -X PUT repos/<o>/<r>/pulls/<n>/merge" "pulls/388/merge" api -X PUT "${PR_PATH}"
api_refused "A2. REST: --method PUT with a leading slash" "merge" api --method PUT "/${PR_PATH}"
api_refused "A3. REST: --method=PUT on a full https://api.github.com URL" "merge" api --method=PUT "https://api.github.com/${PR_PATH}"
api_refused "A4. REST: -XPUT (value attached) with a body field" "merge" api -XPUT "${PR_PATH}" -f merge_method=squash
api_refused "A5. REST: -X=PUT" "merge" api -X=PUT "${PR_PATH}"
api_refused "A6. REST: combined short flags -iXPUT" "merge" api -iXPUT "${PR_PATH}"
api_refused "A7. REST: lowercase method (-X put)" "merge" api -X put "${PR_PATH}"
api_refused "A8. REST: no -X but a field (gh defaults to POST)" "merge" api "${PR_PATH}" -f sha="${HEAD_SHA}"
api_refused "A9. REST: --input body (gh defaults to POST)" "merge" api "${PR_PATH}" --input "${TMP}/merge-body.json"
api_refused "A10. REST: trailing slash" "merge" api -X PUT "${PR_PATH}/"
api_refused "A11. REST: dot segments (pulls/388/x/../merge, ./)" "merge" api -X PUT "repos/CJPoll/gen_saas/pulls/388/x/.././merge"
api_refused "A12. REST: percent-encoded (%6Derge, %2F)" "merge" api -X PUT "repos/CJPoll/gen_saas/pulls%2F388/%6Derge"
api_refused "A13. REST: upper case path" "merge" api -X PUT "REPOS/CJPoll/gen_saas/PULLS/388/MERGE"
api_refused "A14. REST: query string and double slash" "merge" api -X PUT "repos/CJPoll//gen_saas/pulls/388/merge?x=1"
api_refused "A15. REST: GHES host prefix api/v3" "merge" api -X PUT "https://ghe.example.com/api/v3/${PR_PATH}"
api_refused "A16. REST: repositories/<id> route" "merge" api -X PUT "repositories/123456/pulls/388/merge"
api_refused "A17. REST: GET + X-HTTP-Method-Override: PUT" "method" api -H 'X-HTTP-Method-Override: PUT' "${PR_PATH}"
api_refused "A18. REST: POST repos/<o>/<r>/merges (branch merge, no PR)" "merges" api -X POST repos/CJPoll/gen_saas/merges -f base=main -f head=feat
api_refused "A19. REST: POST repos/<o>/<r>/merge-upstream" "merge-upstream" api -X POST repos/CJPoll/gen_saas/merge-upstream -f branch=main
api_refused "A20. REST: endpoint after --" "merge" api -X PUT -- "${PR_PATH}"
api_refused "A21. REST: a flag the guard does not know -> refused (gh would reject it too)" "--frobnicate" api --frobnicate -X PUT repos/CJPoll/gen_saas/issues/5/labels

api_refused "G1. GraphQL: mergePullRequest via -f query=" "mergePullRequest" api graphql -f query="${MUT_MERGE}"
api_refused "G2. GraphQL: enablePullRequestAutoMerge" "enablePullRequestAutoMerge" api graphql -f query='mutation { enablePullRequestAutoMerge(input: {pullRequestId: "PR_x"}) { clientMutationId } }'
api_refused "G3. GraphQL: enqueuePullRequest (merge queue)" "enqueuePullRequest" api graphql -f query='mutation { enqueuePullRequest(input: {pullRequestId: "PR_x"}) { clientMutationId } }'
api_refused "G4. GraphQL: mergeBranch" "mergeBranch" api graphql -f query='mutation { mergeBranch(input: {repositoryId: "R", base: "main", head: "f"}) { clientMutationId } }'
api_refused "G5. GraphQL: aliased field (m: mergePullRequest) via -F query=" "mergePullRequest" api graphql -F query='mutation { m: mergePullRequest(input: {pullRequestId: "PR_x"}) { clientMutationId } }'
api_refused "G6. GraphQL: -F query=@file" "mergePullRequest" api graphql -F query=@"${TMP}/merge.graphql"
api_refused "G7. GraphQL: --input file (JSON body)" "mergePullRequest" api graphql --input "${TMP}/merge-body.json"
api_refused "G8. GraphQL: --input with the name in \\u escapes" "mergePullRequest" api graphql --input "${TMP}/merge-body-escaped.json"
api_refused "G9. GraphQL: combined -fquery=..." "mergePullRequest" api graphql -fquery="${MUT_MERGE}"
api_refused "G10. GraphQL: /graphql on a full URL" "mergePullRequest" api https://api.github.com/graphql -f query="${MUT_MERGE}"
api_refused "G11. GraphQL: the mutation in a non-query field (variables)" "mergePullRequest" api graphql -f query='mutation($q: String) { x }' -f extra="${MUT_MERGE}"
api_refused "U1. unreadable: --input - (stdin)" "stdin" api graphql --input -
api_refused "U2. unreadable: -F query=@- (stdin)" "stdin" api graphql -F query=@-
api_refused "U3. unreadable: -F query=@<missing file>" "cannot read" api graphql -F query=@"${TMP}/does-not-exist.graphql"
api_refused "U4. unreadable: --input <missing file>" "cannot read" api graphql --input "${TMP}/does-not-exist.json"
api_refused "U5. unparseable: --input body that is not JSON" "not JSON" api graphql --input "${TMP}/not-json.json"
api_refused "U6. unreadable: --input - on a REST merge path is still a merge" "merge" api -X PUT "${PR_PATH}" --input -

api_refused "A22. REST: {owner}/{repo} placeholders" "merge" api -X PUT 'repos/{owner}/{repo}/pulls/388/merge'
api_refused "G12. GraphQL: a .json suffix on the graphql endpoint" "mergePullRequest" api graphql.json -f query="${MUT_MERGE}"

# The guard's own failure must never read as "no merge found" (fail closed).
# F1: mktemp fails for the scan file only (the isolation dir, mktemp -d, still
# works, so the refusal is the guard's). F2: grep errors (exit 2) on the scan.
mkdir -p "${TMP}/brokenbin"
REAL_MKTEMP="$(command -v mktemp)"; REAL_GREP="$(command -v grep)"
cat > "${TMP}/brokenbin/mktemp" <<STUB
#!/usr/bin/env bash
case " \$* " in *" -d "*) exec "${REAL_MKTEMP}" "\$@" ;; esac
exit 1
STUB
chmod +x "${TMP}/brokenbin/mktemp"
reset_fx; PATH="${TMP}/brokenbin:${PATH}" run api graphql -f query='{ viewer { login } }'
if [ "${RC}" = 3 ] && [[ "${ERR}" == *"scratch file"* ]] && [[ "${ERR}" == *"Fix:"* ]] && [ ! -s "${STUB_LOG}" ]; then
  ok "F1. the scan's scratch file cannot be made -> refused, not read as 'no merge', no gh call"
else bad "F1. mktemp failure fails closed" "$(detail)"; fi
rm -f "${TMP}/brokenbin/mktemp"
cat > "${TMP}/brokenbin/grep" <<STUB
#!/usr/bin/env bash
case " \$* " in *" -aEiq "*) echo "grep: simulated I/O error" >&2; exit 2 ;; esac
exec "${REAL_GREP}" "\$@"
STUB
chmod +x "${TMP}/brokenbin/grep"
reset_fx; PATH="${TMP}/brokenbin:${PATH}" run api graphql -f query='{ viewer { login } }'
if [ "${RC}" = 3 ] && [[ "${ERR}" == *"grep exit 2"* ]] && [[ "${ERR}" == *"Fix:"* ]] && [ ! -s "${STUB_LOG}" ]; then
  ok "F2. the scan's grep errors (exit 2) -> refused, not read as 'no merge', no gh call"
else bad "F2. grep error fails closed" "$(detail)"; fi
rm -rf "${TMP}/brokenbin"

reset_fx; printf 'am: api -X PUT %s\n' "${PR_PATH}" > "${FX}/aliases.out"
run am
if [ "${RC}" = 3 ] && [[ "${ERR}" == *"REFUSING"* ]] && [[ "${ERR}" == *"--match-head-commit"* ]] \
  && [ "$(cat "${STUB_LOG}")" = "alias list" ]; then
  ok "L1. a gh alias expanding to an api merge -> expanded, refused; only \`alias list\` ran"
else bad "L1. alias to api merge refused" "$(detail)"; fi

reset_fx
OUT="$(GH_ATHENA_MERGE_DRY_RUN=1 "${WRAPPER}" api -X PUT "${PR_PATH}" 2>"${TMP}/err")"; RC=$?; ERR="$(cat "${TMP}/err")"
if [ "${RC}" = 3 ] && [[ "${ERR}" == *"REFUSING"* ]] && [ ! -s "${STUB_LOG}" ]; then
  ok "D1. dry-run seam on an api merge -> the same refusal, no gh call"
else bad "D1. dry-run api merge refused" "$(detail)"; fi

echo
echo "--- DND-728 NEGATIVE: api calls that do not merge pass through unchanged ---"
api_passes "N1. GET of the merge endpoint (is it merged?)" api "${PR_PATH}"
api_passes "N2. -X HEAD of the merge endpoint" api -X HEAD "${PR_PATH}"
api_passes "N3. POST to another pulls endpoint (requested_reviewers)" api -X POST repos/CJPoll/gen_saas/pulls/388/requested_reviewers -f 'reviewers[]=x'
api_passes "N4. PUT to labels with a field" api -X PUT repos/CJPoll/gen_saas/issues/5/labels -f 'labels[]=bug'
api_passes "N5. GET a ref whose branch is named merge-x (not a merge endpoint)" api repos/CJPoll/gen_saas/git/refs/heads/merge-x
api_passes "N6. GraphQL read" api graphql -f query='{ viewer { login } }'
api_passes "N7. GraphQL disablePullRequestAutoMerge (merges nothing)" api graphql -f query='mutation { disablePullRequestAutoMerge(input: {pullRequestId: "PR_x"}) { clientMutationId } }'
api_passes "N8. GraphQL with jq and paginate flags" api graphql --paginate -q '.data' -f query='{ viewer { login } }'
api_passes "N9. REST read with -H accept header and --jq" api -H 'Accept: application/vnd.github+json' repos/CJPoll/gen_saas/pulls/388 --jq .merged
api_passes "N10. a REST read whose ref names contain mergePullRequest text is not scanned" api repos/CJPoll/gen_saas/contents/mergePullRequest.md
api_passes "N11. GraphQL: an inline -F value that only CONTAINS =@ is not a file read" api graphql -F note='a=@b' -f query='{ viewer { login } }'
api_passes "N12. -X get (lower case) of the merge endpoint is still a read" api -X get "${PR_PATH}"
api_passes "N13. a benign %-escaped path is decoded, not refused" api -X PUT 'repos/CJPoll/gen%5Fsaas/issues/5/labels' -f 'labels[]=x'

echo
echo "--- DND-741: a \`gh api\` write that moves or creates a ref is REFUSED before gh runs ---"
# DND-609/728 guarded merges only. A direct ref write puts commits on a branch
# (the default branch included) with no pinned head and no green check, and a
# free private repo has no branch protection to stop it. Every ref write is
# refused, whatever branch it names (the scope decision is in
# ai/lib/gh-merge-guard.sh): branches move only by `gh-athena git push`, and the
# default branch only by the guarded `pr merge`. Each refusal names both paths,
# and gh is never called (the stub log stays EMPTY).
REF_MAIN="repos/CJPoll/gen_saas/git/refs/heads/main"
MUT_COMMIT='mutation { createCommitOnBranch(input: {branch: {repositoryNameWithOwner: "CJPoll/gen_saas", branchName: "main"}, expectedHeadOid: "abc", message: {headline: "x"}, fileChanges: {additions: []}}) { commit { oid } } }'
printf '%s\n' "${MUT_COMMIT}" > "${TMP}/commit.graphql"
printf '{"query":"mutation { \\u0075pdateRef(input: {refId: \\"REF_x\\", oid: \\"abc\\", force: true}) { clientMutationId } }"}\n' > "${TMP}/ref-body-escaped.json"
jq -cn '{sha: "abc", force: true}' > "${TMP}/ref-patch.json"

# ref_refused <label> <needle> <args...> : exit 3, REFUSING, a Fix: naming the
# branch-push path and the guarded merge path, <needle> in the reason, NO gh call.
ref_refused() {
  local label="$1" needle="$2"; shift 2
  reset_fx; run "$@"
  if [ "${RC}" = 3 ] && [[ "${ERR}" == *"REFUSING"* ]] && [[ "${ERR}" == *"Fix:"* ]] \
    && [[ "${ERR}" == *"gh-athena git push"* ]] \
    && [[ "${ERR}" == *"pr merge <n> --squash --match-head-commit <sha>"* ]] \
    && [[ "${ERR}" == *"${needle}"* ]] && [ ! -s "${STUB_LOG}" ]; then
    ok "${label}"
  else bad "${label}" "$(detail)"; fi
}

ref_refused "R1. REST: PATCH git/refs/heads/main (move the default branch)" "git/refs/heads/main" api -X PATCH "${REF_MAIN}" -f sha="${HEAD_SHA}" -F force=true
ref_refused "R2. REST: PATCH git/refs/heads/<feature> (any branch; the scope is every ref)" "git/refs/heads/feat" api -X PATCH repos/CJPoll/gen_saas/git/refs/heads/feat -f sha="${HEAD_SHA}"
ref_refused "R3. REST: POST git/refs (create a ref)" "git/refs" api -X POST repos/CJPoll/gen_saas/git/refs -f ref=refs/heads/x -f sha="${HEAD_SHA}"
ref_refused "R4. REST: git/refs with fields and no -X (gh defaults to POST)" "git/refs" api repos/CJPoll/gen_saas/git/refs -f ref=refs/tags/v1 -f sha="${HEAD_SHA}"
ref_refused "R5. REST: -XPATCH with an --input body" "git/refs" api -XPATCH "${REF_MAIN}" --input "${TMP}/ref-patch.json"
ref_refused "R6. REST: %-encoded route (git%2Frefs%2Fheads%2Fmain)" "git/refs" api -X PATCH 'repos/CJPoll/gen_saas/git%2Frefs%2Fheads%2Fmain' -f sha=x
ref_refused "R7. REST: upper case GIT/REFS, lower case method" "git/refs" api -X patch 'REPOS/CJPoll/gen_saas/GIT/REFS/HEADS/MAIN' -f sha=x
ref_refused "R8. REST: repositories/<id> route on a full URL" "git/refs" api -X PATCH https://api.github.com/repositories/123456/git/refs/heads/main -f sha=x
ref_refused "R9. REST: GET + X-HTTP-Method-Override: PATCH" "method-override" api -H 'X-HTTP-Method-Override: PATCH' "${REF_MAIN}"
ref_refused "R10. REST: DELETE + a method-override header is not a plain DELETE" "method-override" api -X DELETE -H 'X-HTTP-Method-Override: PATCH' "${REF_MAIN}"
ref_refused "R11. REST: git/ref (singular) written to" "git/ref" api -X PATCH repos/CJPoll/gen_saas/git/ref/heads/main -f sha=x
ref_refused "R12. REST: a .json suffix on git/refs" "git/refs" api -X POST repos/CJPoll/gen_saas/git/refs.json -f ref=refs/heads/x -f sha=x
ref_refused "R13. REST: {owner}/{repo} placeholders, dot segments" "git/refs" api -X PATCH 'repos/{owner}/{repo}/git/x/../refs/heads/main' -f sha=x
ref_refused "R14. REST: PUT contents/<path> (a commit on a branch)" "contents" api -X PUT repos/CJPoll/gen_saas/contents/lib/a.ex -f message=x -f content=eA== -f branch=main
ref_refused "R15. REST: DELETE contents/<path> (a commit on a branch)" "contents" api -X DELETE repos/CJPoll/gen_saas/contents/lib/a.ex -f message=x -f sha=abc
ref_refused "R16. REST: POST branches/<b>/rename" "rename" api -X POST repos/CJPoll/gen_saas/branches/feat/x/rename -f new_name=main
ref_refused "R17. REST: PUT pulls/<n>/update-branch (merges the base into the PR's head branch)" "update-branch" api -X PUT repos/CJPoll/gen_saas/pulls/388/update-branch
ref_refused "R18. REST: an endpoint after --" "git/refs" api -X PATCH -- "${REF_MAIN}" -f sha=x

ref_refused "RG1. GraphQL: createCommitOnBranch via -f query=" "createCommitOnBranch" api graphql -f query="${MUT_COMMIT}"
ref_refused "RG2. GraphQL: updateRef" "updateRef" api graphql -f query='mutation { updateRef(input: {refId: "REF_x", oid: "abc", force: true}) { clientMutationId } }'
ref_refused "RG3. GraphQL: updateRefs" "updateRefs" api graphql -f query='mutation { updateRefs(input: {repositoryId: "R", refUpdates: [{name: "refs/heads/main", afterOid: "abc", force: true}]}) { clientMutationId } }'
ref_refused "RG4. GraphQL: createRef" "createRef" api graphql -f query='mutation { createRef(input: {repositoryId: "R", name: "refs/heads/x", oid: "abc"}) { clientMutationId } }'
ref_refused "RG5. GraphQL: createLinkedBranch" "createLinkedBranch" api graphql -f query='mutation { createLinkedBranch(input: {issueId: "I", oid: "abc", name: "x"}) { clientMutationId } }'
ref_refused "RG6. GraphQL: revertPullRequest" "revertPullRequest" api graphql -f query='mutation { revertPullRequest(input: {pullRequestId: "PR_x"}) { clientMutationId } }'
ref_refused "RG7. GraphQL: updatePullRequestBranch" "updatePullRequestBranch" api graphql -f query='mutation { updatePullRequestBranch(input: {pullRequestId: "PR_x"}) { clientMutationId } }'
ref_refused "RG8. GraphQL: aliased field (c: createCommitOnBranch) via -F query=@file" "createCommitOnBranch" api graphql -F query=@"${TMP}/commit.graphql"
ref_refused "RG9. GraphQL: --input with the name in \\u escapes" "updateRef" api graphql --input "${TMP}/ref-body-escaped.json"
ref_refused "RG10. GraphQL: the mutation in a variables field" "createRef" api graphql -f query='mutation($x: String) { x }' -f extra='createRef(input: {})'

reset_fx; printf 'mv: api -X PATCH %s -f sha=x\n' "${REF_MAIN}" > "${FX}/aliases.out"
run mv
if [ "${RC}" = 3 ] && [[ "${ERR}" == *"REFUSING"* ]] && [[ "${ERR}" == *"gh-athena git push"* ]] \
  && [ "$(cat "${STUB_LOG}")" = "alias list" ]; then
  ok "RL1. a gh alias expanding to an api ref write -> expanded, refused; only \`alias list\` ran"
else bad "RL1. alias to api ref write refused" "$(detail)"; fi

reset_fx
OUT="$(GH_ATHENA_MERGE_DRY_RUN=1 "${WRAPPER}" api -X PATCH "${REF_MAIN}" -f sha=x 2>"${TMP}/err")"; RC=$?; ERR="$(cat "${TMP}/err")"
if [ "${RC}" = 3 ] && [[ "${ERR}" == *"REFUSING"* ]] && [ ! -s "${STUB_LOG}" ]; then
  ok "RD1. dry-run seam on an api ref write -> the same refusal, no gh call"
else bad "RD1. dry-run api ref write refused" "$(detail)"; fi

reset_fx; run api graphql -f query="${MUT_COMMIT} mutation { mergePullRequest(input: {pullRequestId: \"x\"}) { clientMutationId } }"
if [ "${RC}" = 3 ] && [[ "${ERR}" == *"REFUSING"* ]] && [ ! -s "${STUB_LOG}" ]; then
  ok "RG11. a query carrying BOTH a ref write and a merge -> refused"
else bad "RG11. mixed ref+merge query refused" "$(detail)"; fi

echo
echo "--- DND-741 NEGATIVE: api calls that move no ref pass through unchanged ---"
api_passes "NR1. GET git/refs/heads/main (read the branch head)" api "${REF_MAIN}"
api_passes "NR2. GET git/matching-refs with --jq" api repos/CJPoll/gen_saas/git/matching-refs/heads/dnd- --jq '.[].ref'
api_passes "NR3. -X GET contents with a ref field (fields become the query string)" api -X GET repos/CJPoll/gen_saas/contents/README.md -f ref=main
api_passes "NR4. -X DELETE git/refs/heads/<feature> (a branch delete moves nothing onto it)" api -X DELETE repos/CJPoll/gen_saas/git/refs/heads/dnd-1-done
api_passes "NR5. POST git/commits (an object only; no ref moves)" api -X POST repos/CJPoll/gen_saas/git/commits -f message=x -f tree=abc
api_passes "NR6. GET branches/<b>" api repos/CJPoll/gen_saas/branches/main
api_passes "NR7. GraphQL deleteRef (moves nothing onto a ref)" api graphql -f query='mutation { deleteRef(input: {refId: "REF_x"}) { clientMutationId } }'
api_passes "NR8. GraphQL read of a ref's target" api graphql -f query='{ repository(owner: "CJPoll", name: "gen_saas") { ref(qualifiedName: "main") { target { oid } } } }'
api_passes "NR9. a REST write whose field VALUE names a ref mutation is not scanned" api -X POST repos/CJPoll/gen_saas/issues/5/comments -f body='why not updateRef or createCommitOnBranch?'
api_passes "NR10. a REST read of a file under a contents/ path" api repos/CJPoll/gen_saas/contents/git/refs/heads/main
api_passes "NR11. a word that only CONTAINS a mutation name (createRefund)" api graphql -f query='mutation { createRefund(input: {}) { id } }'

echo
echo "==================================================="
printf 'RESULT: %d passed, %d failed\n' "${PASS}" "${FAIL}"
echo "==================================================="
[ "${FAIL}" -eq 0 ] || exit 1
echo "ALL CASES PASS"
exit 0
