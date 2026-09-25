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
echo "==================================================="
printf 'RESULT: %d passed, %d failed\n' "${PASS}" "${FAIL}"
echo "==================================================="
[ "${FAIL}" -eq 0 ] || exit 1
echo "ALL CASES PASS"
exit 0
