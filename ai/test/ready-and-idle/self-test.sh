#!/usr/bin/env bash
# Self-test for ai/bin/ready-and-idle — discovered and run by ai/bin/harness-gate.
#
# Two layers:
#   1. The tool's own `--self-test` (pure qualification/idle math, no I/O).
#   2. A hermetic end-to-end suite: a throwaway git repo in a temp dir, with
#      `glab` and `gh` STUBBED on PATH to return canned JSON. No network, no
#      real forge, no dependence on the machine's auth state, no model.
#
# The load-bearing cases are the ones about INDISTINGUISHABILITY, because this
# tool exists to notice something nobody noticed:
#   * a FAILED probe must exit non-zero and must NOT print the zero-orphans
#     text (~/dev/custom/CLAUDE.md -> "A failed lookup must never look like an
#     empty one"); and
#   * a GENUINELY empty result must exit 0 and be textually distinct from it.
# A suite that only ever exercised a healthy probe would prove neither.
#
# Nothing outside the sandbox is touched: the repo, the fixtures and the stub
# PATH all live in a mktemp -d that the EXIT trap removes.
#
# Run: bash ai/test/ready-and-idle/self-test.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/../../.." && pwd)"
BIN="${REPO}/ai/bin/ready-and-idle"

PASS=0; FAIL=0
ok()  { printf '  ok    %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  FAIL  %s\n        %s\n' "$1" "$2"; FAIL=$((FAIL+1)); }

if [ ! -x "${BIN}" ]; then
  echo "ready-and-idle self-test: FAIL — ${BIN} missing or not executable" >&2
  echo "Fix: chmod +x ai/bin/ready-and-idle" >&2
  exit 1
fi

TMP="$(mktemp -d)"; trap 'rm -rf "${TMP}"' EXIT
FIX="${TMP}/fixtures"; STUB="${TMP}/stub"; WORK="${TMP}/repo"
mkdir -p "${FIX}" "${STUB}"

# ---------------------------------------------------------------------------
# Sandbox repo. Real commits, so the `drift` column is computed by real git
# against a real refs/remotes/origin/main rather than asserted against a mock.
# A global core.excludesFile would otherwise leak in and make fixture files
# invisible to git; /dev/null pins it.
# ---------------------------------------------------------------------------
git init -q "${WORK}"
git -C "${WORK}" config user.email t@example.invalid
git -C "${WORK}" config user.name t
git -C "${WORK}" config core.excludesFile /dev/null
git -C "${WORK}" config commit.gpgsign false
for i in 1 2 3 4; do
  echo "$i" > "${WORK}/f${i}"
  git -C "${WORK}" add -A >/dev/null 2>&1
  git -C "${WORK}" commit -qm "c${i}" >/dev/null 2>&1
done
# SHA_OLD is 3 commits behind the target tip -> drift 3. SHA_TIP -> drift 0.
SHA_OLD="$(git -C "${WORK}" rev-parse HEAD~3)"
SHA_TIP="$(git -C "${WORK}" rev-parse HEAD)"
git -C "${WORK}" update-ref refs/remotes/origin/main "${SHA_TIP}"

# ---------------------------------------------------------------------------
# Stubs. Each records every invocation, so the --help case can assert that the
# help path executed NEITHER of them (a help branch that reaches the network is
# the defect ai/bin/check-bin-help exists for). ${STUB}/fail makes the forge
# probe fail on demand, which is how the "could not look" case is driven.
# ---------------------------------------------------------------------------
cat > "${STUB}/glab" <<STUBEOF
#!/usr/bin/env bash
echo "glab \$*" >> "${TMP}/invoked.log"
if [ -e "${STUB}/fail" ]; then
  echo "HTTP 401: Requires authentication" >&2
  exit 1
fi
path="\${2:-}"
case "\${path}" in
  */approvals)              iid="\$(echo "\${path}" | sed 's#.*/merge_requests/##; s#/approvals##')"
                            cat "${FIX}/approvals-\${iid}.json" ;;
  *state=opened*)           cat "${FIX}/mrs.json" ;;
  */merge_requests/*)       iid="\${path##*/}"; cat "${FIX}/mr-\${iid}.json" ;;
  *)                        echo "stub glab: unhandled \${path}" >&2; exit 1 ;;
esac
STUBEOF

cat > "${STUB}/gh" <<STUBEOF
#!/usr/bin/env bash
echo "gh \$*" >> "${TMP}/invoked.log"
if [ -e "${STUB}/fail" ]; then
  echo "HTTP 401: Requires authentication" >&2
  exit 1
fi
cat "${FIX}/prs.json"
STUBEOF
chmod +x "${STUB}/glab" "${STUB}/gh"
export PATH="${STUB}:${PATH}"

ago() { date -u -d "-$1" +%Y-%m-%dT%H:%M:%SZ; }

# Write the GitLab fixture set for ONE merge request and use it as the whole
# open list, so each case isolates exactly one variable.
# mk_gitlab <iid> <sha> <draft> <blocking_resolved> <updated_at> <pipeline> <approvals_left>
mk_gitlab() {
  cat > "${FIX}/mrs.json" <<EOF
[{"iid":$1,"title":"fixture mr $1","source_branch":"b$1","target_branch":"main",
  "sha":"$2","draft":$3,"work_in_progress":$3,
  "blocking_discussions_resolved":$4,"updated_at":"$5"}]
EOF
  printf '{"head_pipeline":{"status":"%s"}}\n' "$6" > "${FIX}/mr-$1.json"
  printf '{"approvals_required":0,"approvals_left":%s}\n' "$7" > "${FIX}/approvals-$1.json"
}

OUT=""; ERR=""; CODE=0
run() { # run <args...>
  OUT="$("${BIN}" "$@" 2>"${TMP}/err")"; CODE=$?
  ERR="$(cat "${TMP}/err")"
}

git -C "${WORK}" remote add origin git@gitlab.com:fixture/proj.git

# ---------------------------------------------------------------------------
# 0. The tool's own pure-logic suite.
# ---------------------------------------------------------------------------
if "${BIN}" --self-test >/dev/null 2>&1; then
  ok "tool --self-test (pure qualification/idle math) passes"
else
  bad "tool --self-test passes" "$("${BIN}" --self-test 2>&1 | tail -5)"
fi

# ---------------------------------------------------------------------------
# 1. A green, idle, unblocked, approved MR IS reported.
# ---------------------------------------------------------------------------
mk_gitlab 1187 "${SHA_OLD}" false true "$(ago '10 hours')" success 0
run --repo "${WORK}" --no-fetch --json
[ "${CODE}" -eq 0 ] && echo "${OUT}" | grep -q '"orphans": 1' \
  && echo "${OUT}" | grep -q '"id": 1187' \
  && ok "green+idle+unblocked+approved MR is reported" \
  || bad "green+idle+unblocked+approved MR is reported" "code=${CODE} out=${OUT}"

# The drift column is the accruing rebase debt, and it is the number that makes
# the cost legible — assert it against real git, not against the fixture.
echo "${OUT}" | grep -q '"drift_commits": 3' \
  && ok "drift counts commits the target gained since the green head (3)" \
  || bad "drift counts commits since the green head" "out=${OUT}"

mk_gitlab 1188 "${SHA_TIP}" false true "$(ago '10 hours')" success 0
run --repo "${WORK}" --no-fetch --json
echo "${OUT}" | grep -q '"drift_commits": 0' \
  && ok "drift is 0 when the target has not moved" \
  || bad "drift is 0 when the target has not moved" "out=${OUT}"

# ---------------------------------------------------------------------------
# 2-7. Each disqualifier INDIVIDUALLY excludes an otherwise-qualifying MR.
# ---------------------------------------------------------------------------
excl() { # excl <label> <mk_gitlab args...>
  local label="$1"; shift
  mk_gitlab "$@"
  run --repo "${WORK}" --no-fetch --json
  if [ "${CODE}" -eq 0 ] && echo "${OUT}" | grep -q '"orphans": 0'; then
    ok "${label} excludes the MR"
  else
    bad "${label} excludes the MR" "code=${CODE} out=${OUT}"
  fi
}
excl "draft"                     2001 "${SHA_OLD}" true  true  "$(ago '10 hours')" success 0
excl "red pipeline"              2002 "${SHA_OLD}" false true  "$(ago '10 hours')" failed  0
excl "pending pipeline"          2003 "${SHA_OLD}" false true  "$(ago '10 hours')" running 0
excl "no pipeline at all"        2004 "${SHA_OLD}" false true  "$(ago '10 hours')" none    0
excl "unresolved discussion"     2005 "${SHA_OLD}" false false "$(ago '10 hours')" success 0
excl "unmet required approval"   2006 "${SHA_OLD}" false true  "$(ago '10 hours')" success 1
excl "activity below threshold"  2007 "${SHA_OLD}" false true  "$(ago '30 minutes')" success 0

# ---------------------------------------------------------------------------
# 8. --idle-hours boundary. One MR, idle ~3h: reported at 2, excluded at 4.
# ---------------------------------------------------------------------------
mk_gitlab 3001 "${SHA_OLD}" false true "$(ago '3 hours')" success 0
run --repo "${WORK}" --no-fetch --json --idle-hours 2
echo "${OUT}" | grep -q '"orphans": 1' \
  && ok "--idle-hours 2 reports a 3h-idle MR" \
  || bad "--idle-hours 2 reports a 3h-idle MR" "code=${CODE} out=${OUT}"
run --repo "${WORK}" --no-fetch --json --idle-hours 4
echo "${OUT}" | grep -q '"orphans": 0' \
  && ok "--idle-hours 4 excludes the same 3h-idle MR" \
  || bad "--idle-hours 4 excludes the same 3h-idle MR" "code=${CODE} out=${OUT}"

# ---------------------------------------------------------------------------
# 9. THE LOAD-BEARING PAIR: "could not look" vs "looked, found nothing".
#
# 9a. A genuinely empty result: every probe landed, nothing qualified.
# ---------------------------------------------------------------------------
mk_gitlab 4001 "${SHA_OLD}" true true "$(ago '10 hours')" success 0
run --repo "${WORK}" --no-fetch
EMPTY_OUT="${OUT}"; EMPTY_ERR="${ERR}"; EMPTY_CODE="${CODE}"
[ "${EMPTY_CODE}" -eq 0 ] && echo "${EMPTY_OUT}" | grep -q 'CLEAN SCAN' \
  && ! echo "${EMPTY_OUT}${EMPTY_ERR}" | grep -q 'SCAN INCOMPLETE' \
  && ok "a genuine empty result exits 0 and says CLEAN SCAN" \
  || bad "a genuine empty result exits 0 and says CLEAN SCAN" "code=${EMPTY_CODE} out=${EMPTY_OUT}"

# 9b. A FAILED forge probe: non-zero exit, and NOT the zero-orphans text.
: > "${STUB}/fail"
run --repo "${WORK}" --no-fetch
FAIL_OUT="${OUT}"; FAIL_ERR="${ERR}"; FAIL_CODE="${CODE}"
rm -f "${STUB}/fail"

[ "${FAIL_CODE}" -ne 0 ] \
  && ok "a failed forge probe exits non-zero (got ${FAIL_CODE})" \
  || bad "a failed forge probe exits non-zero" "code=${FAIL_CODE}"

echo "${FAIL_ERR}" | grep -q 'SCAN INCOMPLETE' \
  && ok "a failed forge probe says SCAN INCOMPLETE (could not look)" \
  || bad "a failed forge probe says SCAN INCOMPLETE" "err=${FAIL_ERR}"

! echo "${FAIL_OUT}${FAIL_ERR}" | grep -q 'CLEAN SCAN' \
  && ok "a failed forge probe never prints the zero-orphans text" \
  || bad "a failed forge probe never prints the zero-orphans text" "out=${FAIL_OUT} err=${FAIL_ERR}"

[ -z "${FAIL_OUT}" ] \
  && ok "a failed forge probe emits nothing on stdout (no result to consume)" \
  || bad "a failed forge probe emits nothing on stdout" "out=${FAIL_OUT}"

echo "${FAIL_ERR}" | grep -q 'Fix:' \
  && ok "the failed-probe path carries an actionable Fix:" \
  || bad "the failed-probe path carries Fix:" "err=${FAIL_ERR}"

echo "${FAIL_ERR}" | grep -q 'gh auth status\|glab auth status' \
  && ok "the failed-probe path enumerates the probe and how to restore it" \
  || bad "the failed-probe path enumerates the probe" "err=${FAIL_ERR}"

# 9c. The two outcomes must not be confusable by their exit codes either.
[ "${EMPTY_CODE}" -ne "${FAIL_CODE}" ] \
  && ok "empty-result and could-not-look have different exit codes (${EMPTY_CODE} vs ${FAIL_CODE})" \
  || bad "empty-result and could-not-look differ" "both=${EMPTY_CODE}"

# ---------------------------------------------------------------------------
# 10. An unmeasurable drift is a failed probe, never a silent 0.
# ---------------------------------------------------------------------------
mk_gitlab 5001 "0000000000000000000000000000000000000000" false true "$(ago '10 hours')" success 0
run --repo "${WORK}" --no-fetch
[ "${CODE}" -ne 0 ] && echo "${ERR}" | grep -q 'SCAN INCOMPLETE' \
  && ! echo "${OUT}" | grep -q 'drift=0' \
  && ok "an uncountable drift fails the scan rather than reading as 0" \
  || bad "an uncountable drift fails the scan" "code=${CODE} out=${OUT} err=${ERR}"

# ---------------------------------------------------------------------------
# 11. GitHub path: a different forge, the same verdicts.
# ---------------------------------------------------------------------------
git -C "${WORK}" remote set-url origin git@github.com:fixture/proj.git
cat > "${FIX}/prs.json" <<EOF
[{"number":42,"title":"fixture pr","headRefName":"b42","baseRefName":"main",
  "headRefOid":"${SHA_OLD}","isDraft":false,"updatedAt":"$(ago '10 hours')",
  "reviewDecision":"APPROVED",
  "statusCheckRollup":[{"__typename":"CheckRun","status":"COMPLETED","conclusion":"SUCCESS"}]}]
EOF
run --repo "${WORK}" --no-fetch --json
[ "${CODE}" -eq 0 ] && echo "${OUT}" | grep -q '"id": 42' && echo "${OUT}" | grep -q 'github (gh)' \
  && ok "github: a green+idle+approved PR is reported" \
  || bad "github: a green+idle+approved PR is reported" "code=${CODE} out=${OUT}"

cat > "${FIX}/prs.json" <<EOF
[{"number":43,"title":"fixture pr","headRefName":"b43","baseRefName":"main",
  "headRefOid":"${SHA_OLD}","isDraft":false,"updatedAt":"$(ago '10 hours')",
  "reviewDecision":"CHANGES_REQUESTED",
  "statusCheckRollup":[{"__typename":"CheckRun","status":"COMPLETED","conclusion":"SUCCESS"}]}]
EOF
run --repo "${WORK}" --no-fetch --json
echo "${OUT}" | grep -q '"orphans": 0' \
  && ok "github: CHANGES_REQUESTED excludes the PR" \
  || bad "github: CHANGES_REQUESTED excludes the PR" "code=${CODE} out=${OUT}"

: > "${STUB}/fail"
run --repo "${WORK}" --no-fetch
GH_CODE="${CODE}"; GH_OUT="${OUT}"; GH_ERR="${ERR}"
rm -f "${STUB}/fail"
[ "${GH_CODE}" -ne 0 ] && [ -z "${GH_OUT}" ] && echo "${GH_ERR}" | grep -q 'SCAN INCOMPLETE' \
  && ok "github: a failed probe also refuses to report a result" \
  || bad "github: a failed probe refuses to report" "code=${GH_CODE} out=${GH_OUT}"

git -C "${WORK}" remote set-url origin git@gitlab.com:fixture/proj.git

# ---------------------------------------------------------------------------
# 12. --help: stdout, exit 0, and NO action (no forge call at all).
# ---------------------------------------------------------------------------
: > "${TMP}/invoked.log"
HELP_OUT="$("${BIN}" --help 2>"${TMP}/helperr")"; HELP_CODE=$?
[ "${HELP_CODE}" -eq 0 ] && [ -n "${HELP_OUT}" ] \
  && echo "${HELP_OUT}" | grep -q 'ready-and-idle' \
  && ok "--help prints usage to stdout and exits 0" \
  || bad "--help prints usage to stdout and exits 0" "code=${HELP_CODE} out=${HELP_OUT}"
[ ! -s "${TMP}/invoked.log" ] \
  && ok "--help performs no action (neither gh nor glab was invoked)" \
  || bad "--help performs no action" "$(cat "${TMP}/invoked.log")"

# ---------------------------------------------------------------------------
# 13. Bad inputs fail loudly, with a Fix:.
# ---------------------------------------------------------------------------
run --repo "${TMP}/not-a-repo"
[ "${CODE}" -eq 1 ] && echo "${ERR}" | grep -q 'Fix:' \
  && ok "a non-repo --repo exits 1 with a Fix:" \
  || bad "a non-repo --repo exits 1 with a Fix:" "code=${CODE} err=${ERR}"

NOFORGE="${TMP}/noforge"
git init -q "${NOFORGE}"
run --repo "${NOFORGE}" --no-fetch
[ "${CODE}" -eq 1 ] && echo "${ERR}" | grep -q 'Fix:' \
  && ! echo "${OUT}" | grep -q 'CLEAN SCAN' \
  && ok "a repo whose remote is neither forge exits 1 and does not claim a clean scan" \
  || bad "a repo whose remote is neither forge exits 1" "code=${CODE} out=${OUT} err=${ERR}"

run --repo "${WORK}" --no-fetch --idle-hours nonsense
[ "${CODE}" -eq 1 ] && echo "${ERR}" | grep -q 'Fix:' \
  && ok "a non-numeric --idle-hours exits 1 with a Fix:" \
  || bad "a non-numeric --idle-hours exits 1 with a Fix:" "code=${CODE} err=${ERR}"

run --repo "${WORK}" --no-fetch --bogus
[ "${CODE}" -eq 1 ] && echo "${ERR}" | grep -q 'Fix:' \
  && ok "an unknown argument exits 1 with a Fix: (never a default action)" \
  || bad "an unknown argument exits 1 with a Fix:" "code=${CODE} err=${ERR}"

# ---------------------------------------------------------------------------
printf '\nready-and-idle self-test: %d passed, %d failed\n' "${PASS}" "${FAIL}"
if [ "${FAIL}" -ne 0 ]; then
  echo "Fix: reconcile ai/bin/ready-and-idle with the cases above — above all, a probe that FAILED must exit non-zero and must never print the zero-orphans text, and a genuinely empty result must exit 0 and stay textually distinct from it." >&2
  exit 1
fi
exit 0
