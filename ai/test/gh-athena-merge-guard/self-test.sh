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
#     --match-head-commit <sha> and every judged run on that head concluded
#     green (DND-1140: a run superseded by a newer check suite's all-SUCCESS
#     runs of the same check is not judged; an order that cannot be read
#     refuses). Zero reported checks is not green.
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
  "api graphql"*"statusCheckRollup"*) answer rollup ;;
  "api repos/"*"/protection/required_status_checks"*) answer protection ;;
  "api repos/"*"/rules/branches/"*) answer rules ;;
  "api repos/"*"/git/ref/heads/"*) answer baseref ;;
  "alias list"*) answer aliases ;;
  "pr merge"*|"-R "*"pr merge"*|"--repo"*"pr merge"*) echo "stub: MERGED" ; exit 0 ;;
  *) echo "stub: passthrough $*"; exit 0 ;;
esac
STUB
chmod +x "${TMP}/bin/gh"
# DND-1647: a guard stands behind every gh/glab stub on PATH, so a stub
# that is missing or not executable fails the suite instead of reaching the
# real CLI (ai/lib/forge-stub-guard.sh).
. "${HERE}/../../lib/forge-stub-guard.sh"
fsg_arm "${TMP}/forge-guard"
fsg_require_stubs "${TMP}/bin" gh
export PATH="${TMP}/bin:${PATH}"

HEAD_SHA="b712de1d0000000000000000000000000000beef"
OTHER_SHA="0e134e88662690fe8edde401fa79bf44aa688eec"

# ---- the local checkout the guard reads (DND-969) ---------------------------
# The guard now reads the PR's base tip from the forge (stub: the baseref
# fixture), asks the LOCAL checkout of the PR's repo whether that commit
# declares an integration gate, and if so requires integration-gate's receipt.
# One fixture repo, origin = the PR's repo URL (never contacted), three base
# commits:
#   NOGATE_BASE  declares no gate (bin/prep-commit.sh, ai/bin/harness-gate absent)
#   GATED_BASE   declares bin/prep-commit.sh
#   HGATE_BASE   declares ai/bin/harness-gate only
# Every case runs with the fixture as cwd. The default base is NOGATE_BASE, so
# every pre-DND-969 case below is ALSO the "a repo that declares no gate behaves
# as before" evidence: none of them changed its expectation.
REPO_FX="${TMP}/gen_saas"
git init -q -b main "${REPO_FX}"
gfx() { git -C "${REPO_FX}" -c user.name=t -c user.email=t@t -c commit.gpgsign=false "$@"; }
gfx remote add origin git@github.com:CJPoll/gen_saas.git
echo readme > "${REPO_FX}/README"; gfx add README; gfx commit -q -m nogate
NOGATE_BASE="$(gfx rev-parse HEAD)"
mkdir -p "${REPO_FX}/bin"; printf '#!/bin/sh\nexit 0\n' > "${REPO_FX}/bin/prep-commit.sh"
gfx add bin; gfx commit -q -m gated
GATED_BASE="$(gfx rev-parse HEAD)"
gfx checkout -q -b hgate "${NOGATE_BASE}"
mkdir -p "${REPO_FX}/ai/bin"; printf '#!/bin/sh\nexit 0\n' > "${REPO_FX}/ai/bin/harness-gate"
gfx add ai; gfx commit -q -m hgate
HGATE_BASE="$(gfx rev-parse HEAD)"
gfx checkout -q main
COMMON_FX="$(git -C "${REPO_FX}" rev-parse --path-format=absolute --git-common-dir)"
STORE_FX="${COMMON_FX}/integration-receipts"
cd "${REPO_FX}" || exit 2

# base_is <sha> : the forge reports <sha> as the tip of the PR's base branch.
base_is() { printf '{"ref":"refs/heads/main","object":{"sha":"%s","type":"commit"}}\n' "$1" > "${FX}/baseref.out"; }

reset_fx() {
  rm -f "${FX}"/* "${STUB_LOG}"; : > "${STUB_LOG}"; printf '' > "${FX}/aliases.out"
  base_is "${NOGATE_BASE}"
  chmod -R u+rwx "${STORE_FX}" 2>/dev/null; rm -rf "${STORE_FX}"
}

# pr_view <rollup-json-array> [head] : the PR, and the same contexts as the
# head commit's rollup. Since DND-1140 the guard reads the contexts by GraphQL
# on the pinned head (the rollup fixture); prview keeps them too, so an older
# copy of the wrapper that read `pr view` sees the same runs (old-vs-new
# evidence).
pr_view() {
  printf '{"number":362,"url":"https://github.com/CJPoll/gen_saas/pull/362","baseRefName":"main","headRefOid":"%s","statusCheckRollup":%s}\n' \
    "${2:-${HEAD_SHA}}" "$1" > "${FX}/prview.out"
  rollup_fx "$1"
}
# rollup_fx <nodes-json|null> [hasNextPage] [totalCount] : the GraphQL answer
# for the head commit's statusCheckRollup.contexts.
rollup_fx() {
  jq -cn --argjson n "$1" --argjson more "${2:-false}" --argjson tc "${3:-null}" '
    {data: {repository: {object: {__typename: "Commit", statusCheckRollup:
      (if $n == null then null
       else {contexts: {totalCount: ($tc // ($n | length)), pageInfo: {hasNextPage: $more}, nodes: $n}} end)}}}}' \
    > "${FX}/rollup.out"
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
# lands_safely : the Fix: names the one recommended merge path, integration-gate
# THEN locked-merge (DND-969), never a bare `gh-athena pr merge`.
lands_safely() { [[ "$(grep -m1 'Fix:' <<<"${ERR}")" == *"integration-gate"*"locked-merge --pr <n> --head"* ]]; }

echo "gh-athena merge-guard self-test"
echo "wrapper: ${WRAPPER}"
echo

echo "--- --auto with NO readable required-checks gate is REFUSED before any write ---"
reset_fx; pr_view "${QUEUED}"; gate_unreadable
run pr merge 362 --squash --auto
if refused && lands_safely && [[ "${ERR}" == *"403"* ]] \
  && [[ "${ERR}" == *"could not establish"* ]]; then
  ok "1. the incident: --auto on gen_saas (protection 403, rules 403) -> refused, Fix names integration-gate then locked-merge, no merge call"
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
echo "--- a non-auto merge needs the exact head, and every judged check on it green ---"
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
echo "--- DND-1140: only the LATEST run of each check is judged; a newer red still refuses ---"
# The defect: gen_saas PR #488, head d0889159, 2026-09-28. CI run 36464818403
# failed Test (a ticketed flake); a close/reopen re-ran CI as run 36467382644
# on the SAME head, all green, and `gh pr checks` showed all green. The guard
# judged every check-run on the head, so the superseded failure kept refusing:
# "Test: COMPLETED/FAILURE". A check is identified by (app, workflow, event,
# name) and a status by its context. Within one identity, runs in an older
# check suite are superseded only when the newest suite's runs are all SUCCESS;
# every run inside the newest suite is judged. A run whose identity cannot be
# read is judged on its own. An order that cannot be read, or a tie for
# newest, refuses.
PR488_NODES="$(cat "${HERE}/fixtures/gen_saas-pr488-d0889159-rollup-nodes.json")"
ACT_APP=15368; CI_WF=256531677; OTHER_WF=256539999; OTHER_APP=90001; THIRD_APP=90002
# cr <name> <status> <conclusion|""> <startedAt|null> [app-id] [app-slug] [workflow-id|null] [event|null]
#   [suite-id|null] : default = the start time's digits, so runs started at
#   different times are in different check suites (a close/reopen or a new
#   workflow run); pass the same id to put runs in ONE suite.
jstr() { [ "$1" = null ] && echo null || printf '"%s"' "$1"; }
cr() {
  local suite="${9:-$(tr -dc 0-9 <<<"$4")}"
  jq -cn --arg n "$1" --arg s "$2" --arg c "$3" --argjson t "$(jstr "$4")" \
    --argjson app "${5:-${ACT_APP}}" --argjson slug "$(jstr "${6:-github-actions}")" --argjson wf "${7:-${CI_WF}}" \
    --argjson ev "$(jstr "${8:-pull_request}")" --argjson suite "${suite:-null}" '
    {__typename: "CheckRun", name: $n, status: $s, conclusion: (if $c == "" then null else $c end), startedAt: $t,
     checkSuite: {databaseId: $suite, app: {databaseId: $app, slug: $slug},
                  workflowRun: (if $wf == null and $ev == null then null
                                else {event: $ev, workflow: (if $wf == null then null else {databaseId: $wf, name: "CI"} end)} end)}}'
}
sc() { jq -cn --arg c "$1" --arg s "$2" --arg t "$3" '{__typename: "StatusContext", context: $c, state: $s, createdAt: $t}'; }
arr() { local IFS=,; printf '[%s]' "$*"; }
merge_pinned() { run pr merge 362 --squash --match-head-commit "${HEAD_SHA}"; }

reset_fx; pr_view "${PR488_NODES}"
merge_pinned
if [ "${RC}" = 0 ] && merged && [[ "${ERR}" == *"superseded"* ]] && [[ "${ERR}" == *"Test: COMPLETED/FAILURE"* ]]; then
  ok "L1. the incident (#488's 16 live runs: older Test FAILURE, newer re-run all green) -> merges; the ignored run is named"
else bad "L1. superseded failure no longer refuses" "$(detail)"; fi

reset_fx; pr_view "$(arr "$(cr Test COMPLETED SUCCESS 2026-09-28T18:40:00Z)" "$(cr Test COMPLETED FAILURE 2026-09-28T18:48:55Z)")"
merge_pinned
refused && [[ "${ERR}" == *"Test: COMPLETED/FAILURE"* ]] \
  && ok "L2. older SUCCESS + newer FAILURE, same check -> refused, names the newer failure" \
  || bad "L2. newer failure refuses" "$(detail)"

reset_fx; pr_view "$(arr "$(cr Test COMPLETED FAILURE 2026-09-28T18:40:00Z)" "$(cr Test IN_PROGRESS "" 2026-09-28T18:48:55Z)")"
merge_pinned
refused && [[ "${ERR}" == *"Test: IN_PROGRESS/-"* ]] \
  && ok "L3. older FAILURE + newer IN_PROGRESS -> refused, names the in-progress run" \
  || bad "L3. newer in-progress refuses" "$(detail)"

reset_fx; pr_view "$(arr "$(cr Test COMPLETED SUCCESS 2026-09-28T18:40:00Z)" "$(cr Test QUEUED "" null "" "" "" "" 4242)")"
merge_pinned
refused && [[ "${ERR}" == *"order cannot be read"* ]] \
  && ok "L3b. older SUCCESS + a QUEUED run with no start time -> refused (the order cannot be read)" \
  || bad "L3b. unreadable order refuses" "$(detail)"

reset_fx; pr_view "$(arr "$(cr Test COMPLETED FAILURE 2026-09-28T18:40:00Z "${OTHER_APP}" other-ci null null)" "$(cr Test COMPLETED SUCCESS 2026-09-28T18:48:55Z "${THIRD_APP}" third-ci null null)")"
merge_pinned
refused && [[ "${ERR}" == *"Test: COMPLETED/FAILURE"* ]] \
  && ok "L4. two APPS (no workflow either) report a check named Test (older one red) -> both judged, refused" \
  || bad "L4. same name across apps is not deduped" "$(detail)"

reset_fx; pr_view "$(arr "$(cr Test COMPLETED FAILURE 2026-09-28T18:40:00Z "${OTHER_APP}" other-ci null null)" "$(cr Test COMPLETED SUCCESS 2026-09-28T18:48:55Z "${OTHER_APP}" other-ci null null)")"
merge_pinned
[ "${RC}" = 0 ] && merged \
  && ok "L4e. one non-Actions app re-reports Test (older red, newer green) -> merges" \
  || bad "L4e. same app re-run is deduped" "$(detail)"

reset_fx; pr_view "$(arr "$(cr Test COMPLETED FAILURE 2026-09-28T18:40:00Z "${ACT_APP}" github-actions "${OTHER_WF}")" "$(cr Test COMPLETED SUCCESS 2026-09-28T18:48:55Z)")"
merge_pinned
refused && [[ "${ERR}" == *"Test: COMPLETED/FAILURE"* ]] \
  && ok "L4b. two WORKFLOWS with a job named Test (older one red) -> both judged, refused" \
  || bad "L4b. same name across workflows is not deduped" "$(detail)"

reset_fx; pr_view "$(arr "$(cr Test COMPLETED FAILURE 2026-09-28T18:40:00Z "${ACT_APP}" github-actions "${CI_WF}" push)" "$(cr Test COMPLETED SUCCESS 2026-09-28T18:48:55Z)")"
merge_pinned
refused && [[ "${ERR}" == *"Test: COMPLETED/FAILURE"* ]] \
  && ok "L4c. one workflow run by push AND pull_request (push run red, older) -> both judged, refused" \
  || bad "L4c. push and pull_request runs are not deduped" "$(detail)"

reset_fx; pr_view "$(arr "$(cr Test COMPLETED FAILURE 2026-09-28T18:40:00Z "${ACT_APP}" github-actions null)" "$(cr Test COMPLETED SUCCESS 2026-09-28T18:48:55Z "${ACT_APP}" github-actions null)")"
merge_pinned
refused && [[ "${ERR}" == *"Test: COMPLETED/FAILURE"* ]] \
  && ok "L4d. Actions runs whose workflow cannot be read -> never deduped, the red one refuses" \
  || bad "L4d. unreadable workflow identity is judged alone" "$(detail)"

reset_fx; pr_view "$(arr "$(cr Test COMPLETED FAILURE 2026-09-28T18:48:55Z "" "" "" "" 4201)" "$(cr Test COMPLETED SUCCESS 2026-09-28T18:48:55Z "" "" "" "" 4202)")"
merge_pinned
refused && [[ "${ERR}" == *"share the newest start time"* ]] \
  && ok "L5. two runs tie for the newest start time -> refused" || bad "L5. tie refuses" "$(detail)"

reset_fx; pr_view "$(arr "$(cr Test COMPLETED FAILURE 2026-09-28T18:40:00Z)" "$(cr Test COMPLETED SUCCESS 'yesterday' "" "" "" "" 4400)")"
merge_pinned
refused && [[ "${ERR}" == *"order cannot be read"* ]] \
  && ok "L6. a malformed start time -> refused (the order cannot be read)" || bad "L6. malformed time refuses" "$(detail)"

reset_fx; pr_view "$(arr "$(sc ext/ci FAILURE 2026-09-28T18:40:00Z)" "$(sc ext/ci SUCCESS 2026-09-28T18:48:55Z)")"
merge_pinned
[ "${RC}" = 0 ] && merged && ok "L7. a commit status: older FAILURE + newer SUCCESS, same context -> merges" \
  || bad "L7. superseded status no longer refuses" "$(detail)"

reset_fx; pr_view "$(arr "$(sc ext/ci SUCCESS 2026-09-28T18:40:00Z)" "$(sc ext/ci FAILURE 2026-09-28T18:48:55Z)")"
merge_pinned
refused && [[ "${ERR}" == *"ext/ci: FAILURE"* ]] \
  && ok "L7b. a commit status: older SUCCESS + newer FAILURE -> refused" || bad "L7b. newer status failure refuses" "$(detail)"

reset_fx; pr_view "${GREEN}"; rollup_fx "${GREEN}" true
merge_pinned
refused && [[ "${ERR}" == *"more than"* ]] \
  && ok "L8. the rollup has another page -> refused (unread runs are not green)" || bad "L8. hasNextPage refuses" "$(detail)"

reset_fx; pr_view "${GREEN}"; rollup_fx "${GREEN}" false 9
merge_pinned
refused && [[ "${ERR}" == *"9"* ]] \
  && ok "L8b. totalCount says 9 but 4 were returned -> refused" || bad "L8b. count mismatch refuses" "$(detail)"

reset_fx; pr_view "${GREEN}"; fx rollup '' 1 'gh: HTTP 502'
merge_pinned
refused && [[ "${ERR}" == *"502"* ]] \
  && ok "L9. the rollup read fails -> refused, the failure is named" || bad "L9. failed rollup read refuses" "$(detail)"

reset_fx; pr_view "${GREEN}"; fx rollup '{"data":{"repository":{"object":null}},"errors":[{"message":"Could not resolve to a Commit"}]}'
merge_pinned
refused && [[ "${ERR}" == *"Could not resolve"* ]] \
  && ok "L9b. a GraphQL error / no such commit -> refused" || bad "L9b. GraphQL error refuses" "$(detail)"

reset_fx; pr_view "${GREEN}"; fx rollup '{"data":{"repository":{"object":{"__typename":"Commit","statusCheckRollup":{"contexts":{"totalCount":1,"pageInfo":{"hasNextPage":false},"nodes":[{"__typename":"Mystery"}]}}}}}}'
merge_pinned
refused && [[ "${ERR}" == *"Mystery"* ]] \
  && ok "L9c. a context of an unknown type -> refused" || bad "L9c. unknown context type refuses" "$(detail)"

reset_fx; pr_view "${GREEN}"
merge_pinned
if [ "${RC}" = 0 ] && grep -q "^api graphql .*statusCheckRollup.* -f owner=CJPoll -f repo=gen_saas -f oid=${HEAD_SHA}\$" "${STUB_LOG}"; then
  ok "L10. the contexts are read for the PINNED head commit (oid=<sha>)"
else bad "L10. rollup read pins the head" "$(detail)"; fi

# Review round 1 (code-reviewer): three inputs where the first cut hid a red run.
reset_fx; pr_view "$(arr "$(cr Test COMPLETED FAILURE 2026-09-28T18:40:00Z "" "" "" "" 4300)" "$(cr Test COMPLETED SUCCESS 2026-09-28T18:40:05Z "" "" "" "" 4300)")"
merge_pinned
refused && [[ "${ERR}" == *"Test: COMPLETED/FAILURE"* ]] \
  && ok "L11. two current jobs share the name Test in ONE check suite (the earlier one red) -> both judged, refused" \
  || bad "L11. same-suite runs are never superseded" "$(detail)"

reset_fx; pr_view "$(arr "$(cr Test COMPLETED FAILURE 2026-09-28T18:40:00Z)" "$(cr Test COMPLETED SKIPPED 2026-09-28T18:48:55Z)")"
merge_pinned
refused && [[ "${ERR}" == *"Test: COMPLETED/FAILURE"* ]] && [[ "${ERR}" == *"does not supersede"* ]] \
  && ok "L12. an older FAILURE, then a newer SKIPPED run (a job gated off on reopen) -> refused, a skip supersedes nothing" \
  || bad "L12. SKIPPED does not supersede" "$(detail)"

reset_fx; pr_view "$(arr "$(cr Test COMPLETED FAILURE 2026-09-28T18:40:00Z)" "$(cr Test COMPLETED NEUTRAL 2026-09-28T18:48:55Z)")"
merge_pinned
refused && [[ "${ERR}" == *"does not supersede"* ]] \
  && ok "L12b. an older FAILURE, then a newer NEUTRAL run -> refused" || bad "L12b. NEUTRAL does not supersede" "$(detail)"

reset_fx; pr_view "$(arr "$(cr Test COMPLETED SUCCESS 2026-09-28T18:40:00Z)" "$(cr Test COMPLETED SKIPPED 2026-09-28T18:48:55Z)")"
merge_pinned
[ "${RC}" = 0 ] && merged \
  && ok "L12c. an older SUCCESS, then a newer SKIPPED run -> merges (every judged run is green)" \
  || bad "L12c. green older run + skipped newer run merges" "$(detail)"

reset_fx; pr_view "$(arr "$(cr Test COMPLETED FAILURE 2026-09-28T18:40:00Z "${ACT_APP}" null null null)" "$(cr Test COMPLETED SUCCESS 2026-09-28T18:48:55Z "${ACT_APP}" null null null)")"
merge_pinned
refused && [[ "${ERR}" == *"Test: COMPLETED/FAILURE"* ]] \
  && ok "L13. an app slug that cannot be read (no workflow either) -> never folded, the red run refuses" \
  || bad "L13. unreadable slug is judged alone" "$(detail)"

reset_fx; pr_view "$(arr "$(cr Test COMPLETED FAILURE 2026-09-28T18:40:00Z "" "" "" "" null)" "$(cr Test COMPLETED SUCCESS 2026-09-28T18:48:55Z)")"
merge_pinned
refused && [[ "${ERR}" == *"Test: COMPLETED/FAILURE"* ]] \
  && ok "L13b. a check suite id that cannot be read -> never folded, the red run refuses" \
  || bad "L13b. unreadable suite is judged alone" "$(detail)"

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
    && lands_safely \
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
if [ "${RC}" = 3 ] && [[ "${ERR}" == *"REFUSING"* ]] && lands_safely \
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
    && lands_safely \
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
echo "--- DND-969: a gated repo's merge needs integration-gate's receipt for the pinned head ---"
# The defect: locked-merge requires the receipt (DND-965), but a direct
# `gh-athena pr merge <n> --squash --match-head-commit <sha>` only asked whether
# CI was green, so it merged a head integration-gate never passed. The guard
# now resolves the base tip from the forge, asks the local checkout whether that
# commit declares a gate (ai/lib/integration-receipt.sh, the rule
# integration-gate uses), and if so requires the receipt for exactly the pinned
# head and exactly that base. Each refusal is asserted to happen BEFORE the
# stubbed merge call.

# plant <head> <base> [verdict] [recorded-head] : a receipt as integration-gate
# writes it.
plant() {
  mkdir -p "${STORE_FX}"
  jq -n --arg h "${4:-$1}" --arg b "$2" --arg v "${3:-pass}" \
    '{schema:"integration-receipt/1", verdict:$v, head:$h, target_ref:"origin/main", base:$b,
      gate:"bin/prep-commit.sh", recorded_at:"2026-09-27T00:00:00Z"}' > "${STORE_FX}/$1.json"
}

# receipt_refused <label> <kind> : refused with that kind, a Fix: that names
# integration-gate BEFORE locked-merge, and no merge call.
receipt_refused() {
  local fixline
  fixline="$(grep -m1 'Fix:' <<<"${ERR}")"
  if refused && [[ "${ERR}" == *"$2"* ]] && [[ "${fixline}" == *"integration-gate"*"locked-merge"* ]]; then
    ok "$1"
  else bad "$1" "$(detail)"; fi
}

reset_fx; pr_view "${GREEN}"; base_is "${GATED_BASE}"
run pr merge 362 --squash --match-head-commit "${HEAD_SHA}"
receipt_refused "D1. THE MISS: gated repo, green pinned head, NO receipt -> refused before the merge call" "NO RECEIPT"
[[ "${ERR}" == *"${STORE_FX}/${HEAD_SHA}.json"* ]] && ok "D1b. the refusal names the receipt path it searched" \
  || bad "D1b. searched path named" "$(detail)"

reset_fx; pr_view "${GREEN}"; base_is "${GATED_BASE}"; plant "${HEAD_SHA}" "${GATED_BASE}"
run pr merge 362 --squash --match-head-commit "${HEAD_SHA}"
if [ "${RC}" = 0 ] && grep -qx "pr merge 362 --squash --match-head-commit ${HEAD_SHA}" "${STUB_LOG}"; then
  ok "D2. a valid receipt for this head and this base -> the merge runs, argv unchanged"
else bad "D2. valid receipt merges" "$(detail)"; fi

# DND-1463: the receipt's base may be an ANCESTOR of the base tip (main moved
# on since the gate ran). NOGATE_BASE is GATED_BASE's parent. Before DND-1463
# this was refused as RECEIPT FOR ANOTHER BASE.
reset_fx; pr_view "${GREEN}"; base_is "${GATED_BASE}"; plant "${HEAD_SHA}" "${NOGATE_BASE}"
run pr merge 362 --squash --match-head-commit "${HEAD_SHA}"
if [ "${RC}" = 0 ] && grep -qx "pr merge 362 --squash --match-head-commit ${HEAD_SHA}" "${STUB_LOG}" \
   && [[ "${ERR}" == *"ancestor of"* ]]; then
  ok "D3. a receipt on an older base that is an ANCESTOR of the tip -> merges, and says the base moved (DND-1463)"
else bad "D3. ancestor-base receipt merges" "$(detail)"; fi

# HGATE_BASE is on a sibling branch: not an ancestor of GATED_BASE.
reset_fx; pr_view "${GREEN}"; base_is "${GATED_BASE}"; plant "${HEAD_SHA}" "${HGATE_BASE}"
run pr merge 362 --squash --match-head-commit "${HEAD_SHA}"
receipt_refused "D3b. a receipt whose base is NOT an ancestor of the tip -> refused" "RECEIPT FOR ANOTHER BASE"

reset_fx; pr_view "${GREEN}"; base_is "${GATED_BASE}"; plant "${HEAD_SHA}" "0123456789abcdef0123456789abcdef01234567"
run pr merge 362 --squash --match-head-commit "${HEAD_SHA}"
receipt_refused "D3c. a receipt base not in the local object store -> COULD NOT LOOK, never read as not-an-ancestor" "COULD NOT LOOK"
[[ "${ERR}" != *"RECEIPT FOR ANOTHER BASE"* ]] && ok "D3d. an unknown receipt base is not reported as another base" || bad "D3d. unknown vs another base" "$(detail)"

reset_fx; pr_view "${GREEN}"; base_is "${GATED_BASE}"; plant "${HEAD_SHA}" "$(gfx rev-parse "${NOGATE_BASE}^{tree}")"
run pr merge 362 --squash --match-head-commit "${HEAD_SHA}"
receipt_refused "D3e. a receipt base that is a tree, not a commit -> RECEIPT INVALID" "RECEIPT INVALID"

reset_fx; pr_view "${GREEN}"; base_is "${GATED_BASE}"; mkdir -p "${STORE_FX}"; echo '{not json' > "${STORE_FX}/${HEAD_SHA}.json"
run pr merge 362 --squash --match-head-commit "${HEAD_SHA}"
receipt_refused "D4. a malformed receipt -> RECEIPT UNREADABLE (COULD NOT LOOK)" "RECEIPT UNREADABLE"
[[ "${ERR}" != *"NO RECEIPT"* ]] && ok "D4b. an unreadable receipt is not reported as NO RECEIPT" || bad "D4b. unreadable vs absent" "$(detail)"

reset_fx; pr_view "${GREEN}"; base_is "${GATED_BASE}"; plant "${HEAD_SHA}" "${GATED_BASE}" red
run pr merge 362 --squash --match-head-commit "${HEAD_SHA}"
receipt_refused "D5. a receipt whose verdict is not pass -> RECEIPT INVALID" "RECEIPT INVALID"

reset_fx; pr_view "${GREEN}"; base_is "${GATED_BASE}"; plant "${HEAD_SHA}" "${GATED_BASE}" pass "${OTHER_SHA}"
run pr merge 362 --squash --match-head-commit "${HEAD_SHA}"
receipt_refused "D5b. a receipt whose recorded head is another SHA -> RECEIPT INVALID" "RECEIPT INVALID"

reset_fx; pr_view "${GREEN}"; base_is "${GATED_BASE}"; plant "${HEAD_SHA}" "${GATED_BASE}"; chmod 000 "${STORE_FX}"
run pr merge 362 --squash --match-head-commit "${HEAD_SHA}"
chmod 700 "${STORE_FX}"
receipt_refused "D6. a receipt store that cannot be searched -> COULD NOT LOOK" "COULD NOT LOOK"
[[ "${ERR}" != *"NO RECEIPT"* ]] && ok "D6b. an unsearchable store is not reported as NO RECEIPT" || bad "D6b. unsearchable vs absent" "$(detail)"

reset_fx; pr_view "${GREEN}"; base_is "${HGATE_BASE}"
run pr merge 362 --squash --match-head-commit "${HEAD_SHA}"
receipt_refused "D7. a repo declaring ai/bin/harness-gate (not bin/prep-commit.sh) is gated too" "NO RECEIPT"

reset_fx; pr_view "${GREEN}"; base_is "${NOGATE_BASE}"
run pr merge 362 --squash --match-head-commit "${HEAD_SHA}"
if [ "${RC}" = 0 ] && grep -qx "pr merge 362 --squash --match-head-commit ${HEAD_SHA}" "${STUB_LOG}"; then
  ok "D8. a repo that declares NO gate, no receipt -> the merge runs as before"
else bad "D8. no-gate repo unchanged" "$(detail)"; fi

reset_fx; pr_view "${GREEN}"; base_is "${GATED_BASE}"
mkdir -p "${TMP}/not-a-repo"; cd "${TMP}/not-a-repo" || exit 2
run pr merge 362 --squash --match-head-commit "${HEAD_SHA}"
cd "${REPO_FX}" || exit 2
receipt_refused "D9. run outside any checkout of the PR's repo -> refused (COULD NOT LOOK), never read as no gate" "COULD NOT LOOK"

OTHER_FX="${TMP}/other"
git init -q -b main "${OTHER_FX}"; git -C "${OTHER_FX}" remote add origin git@github.com:CJPoll/custom.git
reset_fx; pr_view "${GREEN}"; base_is "${NOGATE_BASE}"
cd "${OTHER_FX}" || exit 2
run pr merge 362 --squash --match-head-commit "${HEAD_SHA}"
cd "${REPO_FX}" || exit 2
receipt_refused "D9b. run from a checkout of ANOTHER repo -> refused (COULD NOT LOOK)" "COULD NOT LOOK"

reset_fx; pr_view "${GREEN}"; base_is "0123456789abcdef0123456789abcdef01234567"
run pr merge 362 --squash --match-head-commit "${HEAD_SHA}"
receipt_refused "D10. the base tip is not in the local object store -> refused (COULD NOT LOOK), not 'no gate'" "COULD NOT LOOK"
[[ "${ERR}" == *"git fetch"* ]] && ok "D10b. the Fix says to fetch" || bad "D10b. fetch named" "$(detail)"

reset_fx; pr_view "${GREEN}"; fx baseref '' 1 'gh: Not Found (HTTP 404)'
run pr merge 362 --squash --match-head-commit "${HEAD_SHA}"
receipt_refused "D11. the base tip cannot be read from the forge -> refused, the failure is named" "COULD NOT LOOK"
[[ "${ERR}" == *"HTTP 404"* ]] && ok "D11b. the forge's error is in the refusal" || bad "D11b. forge error named" "$(detail)"

reset_fx; pr_view "${GREEN}"; fx baseref '{"object":{"sha":"not-a-sha"}}'
run pr merge 362 --squash --match-head-commit "${HEAD_SHA}"
receipt_refused "D11c. a base-tip body that is not a SHA -> refused" "COULD NOT LOOK"

reset_fx; pr_view "${QUEUED}"; base_is "${GATED_BASE}"; plant "${HEAD_SHA}" "${GATED_BASE}"
fx protection '{"strict":true,"contexts":["Test"],"checks":[{"context":"Test","app_id":1}]}'
fx rules '[]'
run pr merge 362 --squash --auto
if refused && [[ "${ERR}" == *"--auto"* ]] && [[ "$(grep -m1 'Fix:' <<<"${ERR}")" == *"integration-gate"*"locked-merge"* ]]; then
  ok "D12. --auto in a gated repo -> refused even with required checks and a receipt (it lands later, on a base no receipt covers)"
else bad "D12. --auto in gated repo refused" "$(detail)"; fi

reset_fx; pr_view "${GREEN}"; base_is "${GATED_BASE}"
run pr merge 362 --squash
refused && [[ "${ERR}" == *"--match-head-commit"* ]] \
  && ok "D13. gated repo, no --match-head-commit -> still refused (item 2)" || bad "D13. no pin refused" "$(detail)"

WT_FX="${TMP}/gen_saas-wt"
git -C "${REPO_FX}" worktree add -q --detach "${WT_FX}" "${NOGATE_BASE}" 2>/dev/null
reset_fx; pr_view "${GREEN}"; base_is "${GATED_BASE}"; plant "${HEAD_SHA}" "${GATED_BASE}"
cd "${WT_FX}" || exit 2
run pr merge 362 --squash --match-head-commit "${HEAD_SHA}"
cd "${REPO_FX}" || exit 2
if [ "${RC}" = 0 ] && merged; then
  ok "D14. run from a LINKED worktree -> finds the receipt in the shared git common dir, merges"
else bad "D14. linked worktree reads the common store" "$(detail)"; fi

reset_fx; pr_view "${GREEN}"; base_is "${GATED_BASE}"
OUT="$(GH_ATHENA_MERGE_DRY_RUN=1 "${WRAPPER}" pr merge 362 --squash --match-head-commit "${HEAD_SHA}" 2>"${TMP}/err")"; RC=$?; ERR="$(cat "${TMP}/err")"
receipt_refused "D15. the dry-run seam on a gated merge with no receipt -> the same refusal" "NO RECEIPT"

# DND-1647: no gh/glab call may have fallen through past its stub.
if fsg_verify; then ok "no gh/glab call fell through past its stub (DND-1647)"
else bad "no gh/glab call fell through past its stub (DND-1647)" "see the forge-stub-guard FAIL above"; fi

echo
echo "==================================================="
printf 'RESULT: %d passed, %d failed\n' "${PASS}" "${FAIL}"
echo "==================================================="
[ "${FAIL}" -eq 0 ] || exit 1
echo "ALL CASES PASS"
exit 0
