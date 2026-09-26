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
#   * a FAILED MEMBERSHIP probe must exit 3, emit nothing, and must NOT print
#     the zero-orphans text (~/dev/custom/CLAUDE.md -> "A failed lookup must
#     never look like an empty one");
#   * a GENUINELY empty result must exit 0 and be textually distinct from it;
#   * and the INVERSE, which bites just as hard: a drift priced off
#     un-refreshed refs must NOT render as a confident bare integer. `>=0` and
#     `0` are the byte-identical-looking pair, and the stale one reads
#     HEALTHIER than reality, since the target branch only gains commits
#     between fetches.
# A suite that only ever exercised a healthy probe would prove none of them.
#
# The suite also pins the 2026-09-21 regression directly: a failed `git fetch`
# used to kill the whole scan, so the shipwright's hourly cron lane (no
# ssh-agent) got exit 3 and ZERO rows while 28 change requests were
# ready-and-idle, the oldest for 82 days. Case F1 fails if that is ever
# reintroduced.
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
[ "${CODE}" -eq 4 ] && grep -q '"orphans": 1' <<<"${OUT}" \
  && grep -q '"id": 1187' <<<"${OUT}" \
  && ok "green+idle+unblocked+approved MR is reported (exit 4: rows complete, drift soft)" \
  || bad "green+idle+unblocked+approved MR is reported" "code=${CODE} out=${OUT}"

# --no-fetch is a REQUEST not to fetch, never a licence to claim freshness.
# The same epistemic state (refs not refreshed) must not produce two different
# confidences depending on whether it arose from a flag or from a failure.
grep -q '"drift_at_least": 3' <<<"${OUT}" \
  && grep -q '"drift_commits": null' <<<"${OUT}" \
  && grep -q '"drift_quality": "stale"' <<<"${OUT}" \
  && ! grep -q '"drift_commits": 3' <<<"${OUT}" \
  && ok "--no-fetch drift is a LOWER BOUND, never an exact drift_commits" \
  || bad "--no-fetch drift is a lower bound" "out=${OUT}"

run --repo "${WORK}" --no-fetch
grep -q 'drift=>=3' <<<"${OUT}" && ! grep -qE 'drift=3([^0-9]|$)' <<<"${OUT}" \
  && ok "the table renders a stale drift as >=3, never as a bare 3" \
  || bad "the table renders a stale drift as >=3" "out=${OUT}"

# THE stale-zero pair, at the integration layer. `0` is the value that reads
# healthiest ("nothing has moved, this is cheap to land") and is the most
# tempting to collapse back to a plain integer.
mk_gitlab 1188 "${SHA_TIP}" false true "$(ago '10 hours')" success 0
run --repo "${WORK}" --no-fetch --json
grep -q '"drift_at_least": 0' <<<"${OUT}" && grep -q '"drift_commits": null' <<<"${OUT}" \
  && ok "an un-refreshed drift of 0 is >=0, never an exact 0" \
  || bad "an un-refreshed drift of 0 is >=0" "out=${OUT}"
run --repo "${WORK}" --no-fetch
grep -q 'drift=>=0' <<<"${OUT}" && ! grep -qE 'drift=0([^0-9]|$)' <<<"${OUT}" \
  && ok "the table never prints a bare drift=0 off un-refreshed refs" \
  || bad "the table never prints a bare drift=0 off un-refreshed refs" "out=${OUT}"

# ---------------------------------------------------------------------------
# 1b. THE EXACT PATH. A local bare repo whose path contains "gitlab" both
# selects the GitLab backend (detect_forge matches the substring) and gives a
# genuinely SUCCEEDING `git fetch origin` with no network — which is how a bare
# integer, and the "bare integer always means refreshed-this-run" invariant,
# get covered hermetically.
# ---------------------------------------------------------------------------
UPSTREAM="${TMP}/gitlab-upstream.git"
git clone -q --bare "${WORK}" "${UPSTREAM}"
git -C "${UPSTREAM}" symbolic-ref HEAD refs/heads/main 2>/dev/null \
  || git -C "${UPSTREAM}" symbolic-ref HEAD "refs/heads/$(git -C "${WORK}" rev-parse --abbrev-ref HEAD)"
git -C "${UPSTREAM}" update-ref refs/heads/main "${SHA_TIP}"
git -C "${WORK}" remote set-url origin "${UPSTREAM}"
mk_gitlab 1189 "${SHA_OLD}" false true "$(ago '10 hours')" success 0
run --repo "${WORK}" --json
[ "${CODE}" -eq 0 ] \
  && grep -q '"drift_commits": 3' <<<"${OUT}" \
  && grep -q '"drift_at_least": null' <<<"${OUT}" \
  && grep -q '"drift_quality": "measured"' <<<"${OUT}" \
  && ! grep -q 'DEGRADED' <<<"${ERR}" \
  && ok "a SUCCESSFUL fetch gives an exact drift and exit 0 (bare integer == refreshed)" \
  || bad "a successful fetch gives an exact drift and exit 0" "code=${CODE} out=${OUT} err=${ERR}"

# ---------------------------------------------------------------------------
# F1. THE REGRESSION. A FAILED `git fetch` must NOT suppress the orphan list.
# GIT_SSH_COMMAND=/bin/false reproduces the cron lane's missing ssh-agent with
# no network and no DNS.
# ---------------------------------------------------------------------------
git -C "${WORK}" remote set-url origin git@gitlab.com:fixture/proj.git
mk_gitlab 1187 "${SHA_OLD}" false true "$(ago '10 hours')" success 0
GIT_SSH_COMMAND=/bin/false GIT_TERMINAL_PROMPT=0 run --repo "${WORK}" --json
[ "${CODE}" -eq 4 ] && [ -n "${OUT}" ] \
  && grep -q '"orphans": 1' <<<"${OUT}" && grep -q '"id": 1187' <<<"${OUT}" \
  && grep -q 'DEGRADED SCAN' <<<"${ERR}" \
  && ! grep -q 'SCAN INCOMPLETE' <<<"${ERR}" \
  && ok "a FAILED git fetch degrades the drift column but still emits the orphan list" \
  || bad "a failed git fetch still emits the orphan list" "code=${CODE} out=${OUT} err=${ERR}"

grep -q '"degraded"' <<<"${OUT}" && grep -q '"refs_refreshed": false' <<<"${OUT}" \
  && ok "the degraded marker is in the JSON PAYLOAD (a consumer ignoring stderr cannot misread it)" \
  || bad "the degraded marker is in the JSON payload" "out=${OUT}"

GIT_SSH_COMMAND=/bin/false GIT_TERMINAL_PROMPT=0 run --repo "${WORK}"
grep -q 'Fix:' <<<"${ERR}" \
  && grep -q 'ssh-add' <<<"${ERR}" \
  && grep -q 'ACT ON THE ROWS' <<<"${ERR}" \
  && grep -q 'exit 3' <<<"${ERR}" \
  && ok "the DEGRADED banner tells the caller to act on the rows and not to call it unavailable" \
  || bad "the DEGRADED banner is actionable" "err=${ERR}"

# F2. The relaxation must NOT have leaked into MEMBERSHIP. A fetch failure AND
# a forge failure together is still exit 3 with nothing on stdout.
: > "${STUB}/fail"
GIT_SSH_COMMAND=/bin/false GIT_TERMINAL_PROMPT=0 run --repo "${WORK}"
F2_CODE="${CODE}"; F2_OUT="${OUT}"; F2_ERR="${ERR}"
rm -f "${STUB}/fail"
[ "${F2_CODE}" -eq 3 ] && [ -z "${F2_OUT}" ] \
  && grep -q 'SCAN INCOMPLETE' <<<"${F2_ERR}" \
  && ! grep -q 'DEGRADED SCAN' <<<"${F2_ERR}" \
  && ok "a forge failure still blocks the scan even when the fetch also failed" \
  || bad "a forge failure still blocks the scan" "code=${F2_CODE} out=${F2_OUT} err=${F2_ERR}"

# ---------------------------------------------------------------------------
# 2-7. Each disqualifier INDIVIDUALLY excludes an otherwise-qualifying MR.
# ---------------------------------------------------------------------------
excl() { # excl <label> <mk_gitlab args...>
  local label="$1"; shift
  mk_gitlab "$@"
  run --repo "${WORK}" --no-fetch --json
  if [ "${CODE}" -eq 0 ] && grep -q '"orphans": 0' <<<"${OUT}"; then
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
[ "${CODE}" -eq 4 ] && grep -q '"orphans": 1' <<<"${OUT}" \
  && ok "--idle-hours 2 reports a 3h-idle MR" \
  || bad "--idle-hours 2 reports a 3h-idle MR" "code=${CODE} out=${OUT}"
run --repo "${WORK}" --no-fetch --json --idle-hours 4
grep -q '"orphans": 0' <<<"${OUT}" \
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
[ "${EMPTY_CODE}" -eq 0 ] && grep -q 'CLEAN SCAN' <<<"${EMPTY_OUT}" \
  && ! grep -q 'SCAN INCOMPLETE' <<<"${EMPTY_OUT}${EMPTY_ERR}" \
  && ! grep -q 'DEGRADED SCAN' <<<"${EMPTY_OUT}${EMPTY_ERR}" \
  && ok "a genuine empty result exits 0 and says CLEAN SCAN" \
  || bad "a genuine empty result exits 0 and says CLEAN SCAN" "code=${EMPTY_CODE} out=${EMPTY_OUT}"

# The zero-rows rule, AND its observability. Nothing was priced, so nothing can
# be misread and the run stays at 0 — but the un-refreshed state is still
# stated, so "not refreshed" never goes unrecorded just because it was harmless
# this time.
grep -q 'refs were not refreshed this run' <<<"${EMPTY_OUT}" \
  && ok "a CLEAN SCAN off un-refreshed refs still SAYS the refs were not refreshed" \
  || bad "a CLEAN SCAN states the un-refreshed refs" "out=${EMPTY_OUT}"

# 9b. A FAILED forge probe: non-zero exit, and NOT the zero-orphans text.
: > "${STUB}/fail"
run --repo "${WORK}" --no-fetch
FAIL_OUT="${OUT}"; FAIL_ERR="${ERR}"; FAIL_CODE="${CODE}"
rm -f "${STUB}/fail"

[ "${FAIL_CODE}" -ne 0 ] \
  && ok "a failed forge probe exits non-zero (got ${FAIL_CODE})" \
  || bad "a failed forge probe exits non-zero" "code=${FAIL_CODE}"

grep -q 'SCAN INCOMPLETE' <<<"${FAIL_ERR}" \
  && ok "a failed forge probe says SCAN INCOMPLETE (could not look)" \
  || bad "a failed forge probe says SCAN INCOMPLETE" "err=${FAIL_ERR}"

! grep -q 'CLEAN SCAN' <<<"${FAIL_OUT}${FAIL_ERR}" \
  && ok "a failed forge probe never prints the zero-orphans text" \
  || bad "a failed forge probe never prints the zero-orphans text" "out=${FAIL_OUT} err=${FAIL_ERR}"

[ -z "${FAIL_OUT}" ] \
  && ok "a failed forge probe emits nothing on stdout (no result to consume)" \
  || bad "a failed forge probe emits nothing on stdout" "out=${FAIL_OUT}"

grep -q 'Fix:' <<<"${FAIL_ERR}" \
  && ok "the failed-probe path carries an actionable Fix:" \
  || bad "the failed-probe path carries Fix:" "err=${FAIL_ERR}"

grep -q 'gh auth status\|glab auth status' <<<"${FAIL_ERR}" \
  && ok "the failed-probe path enumerates the probe and how to restore it" \
  || bad "the failed-probe path enumerates the probe" "err=${FAIL_ERR}"

# 9c. The FOUR outcomes must not be confusable by their exit codes either.
# For a caller that reads only the code: 3 means "I have no list", 4 means "I
# have the list, one column is soft" — collapsing them reproduces the outage at
# the READING layer, which no amount of banner wording would prevent.
run --repo "${WORK}" --no-fetch --bogus; USAGE_CODE="${CODE}"
mk_gitlab 4002 "${SHA_OLD}" false true "$(ago '10 hours')" success 0
run --repo "${WORK}" --no-fetch; DEGRADED_CODE="${CODE}"
CODES="$(printf '%s\n' "${EMPTY_CODE}" "${FAIL_CODE}" "${USAGE_CODE}" "${DEGRADED_CODE}" | sort -u | wc -l)"
[ "${CODES}" -eq 4 ] \
  && ok "clean/degraded/incomplete/usage are four DISTINCT exit codes (${EMPTY_CODE}/${DEGRADED_CODE}/${FAIL_CODE}/${USAGE_CODE})" \
  || bad "the four outcomes have distinct exit codes" \
         "clean=${EMPTY_CODE} degraded=${DEGRADED_CODE} incomplete=${FAIL_CODE} usage=${USAGE_CODE}"

# ---------------------------------------------------------------------------
# 10. An unmeasurable drift is a failed probe, never a silent 0.
# ---------------------------------------------------------------------------
# It must never read as 0 (the original half, still load-bearing) — but it must
# also no longer KILL the scan, because an unpriceable row is still a real
# orphan and withholding it is the outage this tool exists to prevent.
mk_gitlab 5001 "0000000000000000000000000000000000000000" false true "$(ago '10 hours')" success 0
run --repo "${WORK}" --no-fetch --json
[ "${CODE}" -eq 4 ] && grep -q '"orphans": 1' <<<"${OUT}" \
  && grep -q '"drift_quality": "unmeasured"' <<<"${OUT}" \
  && ! grep -q '"drift_commits": 0' <<<"${OUT}" \
  && ! grep -q '"drift_at_least": 0' <<<"${OUT}" \
  && ok "an uncountable drift degrades the run but still reports the orphan" \
  || bad "an uncountable drift still reports the orphan" "code=${CODE} out=${OUT} err=${ERR}"
run --repo "${WORK}" --no-fetch
grep -q 'drift=n/a' <<<"${OUT}" && ! grep -q 'drift=0' <<<"${OUT}" \
  && ok "an uncountable drift renders n/a, never 0" \
  || bad "an uncountable drift renders n/a" "out=${OUT}"

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
[ "${CODE}" -eq 4 ] && grep -q '"id": 42' <<<"${OUT}" && grep -q 'github (gh)' <<<"${OUT}" \
  && grep -q '"drift_quality": "stale"' <<<"${OUT}" \
  && ok "github: a green+idle+approved PR is reported, and the degradation is forge-independent" \
  || bad "github: a green+idle+approved PR is reported" "code=${CODE} out=${OUT}"

cat > "${FIX}/prs.json" <<EOF
[{"number":43,"title":"fixture pr","headRefName":"b43","baseRefName":"main",
  "headRefOid":"${SHA_OLD}","isDraft":false,"updatedAt":"$(ago '10 hours')",
  "reviewDecision":"CHANGES_REQUESTED",
  "statusCheckRollup":[{"__typename":"CheckRun","status":"COMPLETED","conclusion":"SUCCESS"}]}]
EOF
run --repo "${WORK}" --no-fetch --json
grep -q '"orphans": 0' <<<"${OUT}" \
  && ok "github: CHANGES_REQUESTED excludes the PR" \
  || bad "github: CHANGES_REQUESTED excludes the PR" "code=${CODE} out=${OUT}"

: > "${STUB}/fail"
run --repo "${WORK}" --no-fetch
GH_CODE="${CODE}"; GH_OUT="${OUT}"; GH_ERR="${ERR}"
rm -f "${STUB}/fail"
[ "${GH_CODE}" -eq 3 ] && [ -z "${GH_OUT}" ] && grep -q 'SCAN INCOMPLETE' <<<"${GH_ERR}" \
  && ok "github: a failed probe also refuses to report a result" \
  || bad "github: a failed probe refuses to report" "code=${GH_CODE} out=${GH_OUT}"

git -C "${WORK}" remote set-url origin git@gitlab.com:fixture/proj.git

# ---------------------------------------------------------------------------
# 12. --help: stdout, exit 0, and NO action (no forge call at all).
# ---------------------------------------------------------------------------
: > "${TMP}/invoked.log"
HELP_OUT="$("${BIN}" --help 2>"${TMP}/helperr")"; HELP_CODE=$?
[ "${HELP_CODE}" -eq 0 ] && [ -n "${HELP_OUT}" ] \
  && grep -q 'ready-and-idle' <<<"${HELP_OUT}" \
  && ok "--help prints usage to stdout and exits 0" \
  || bad "--help prints usage to stdout and exits 0" "code=${HELP_CODE} out=${HELP_OUT}"
[ ! -s "${TMP}/invoked.log" ] \
  && ok "--help performs no action (neither gh nor glab was invoked)" \
  || bad "--help performs no action" "$(cat "${TMP}/invoked.log")"
grep -q '>=N' <<<"${HELP_OUT}" && grep -q 'DEGRADED' <<<"${HELP_OUT}" \
  && ok "--help documents the >=N lower bound and exit 4" \
  || bad "--help documents >=N and exit 4" "out=${HELP_OUT}"

# ---------------------------------------------------------------------------
# 13. Bad inputs fail loudly, with a Fix:.
# ---------------------------------------------------------------------------
run --repo "${TMP}/not-a-repo"
[ "${CODE}" -eq 1 ] && grep -q 'Fix:' <<<"${ERR}" \
  && ok "a non-repo --repo exits 1 with a Fix:" \
  || bad "a non-repo --repo exits 1 with a Fix:" "code=${CODE} err=${ERR}"

NOFORGE="${TMP}/noforge"
git init -q "${NOFORGE}"
run --repo "${NOFORGE}" --no-fetch
[ "${CODE}" -eq 1 ] && grep -q 'Fix:' <<<"${ERR}" \
  && ! grep -q 'CLEAN SCAN' <<<"${OUT}" \
  && ok "a repo whose remote is neither forge exits 1 and does not claim a clean scan" \
  || bad "a repo whose remote is neither forge exits 1" "code=${CODE} out=${OUT} err=${ERR}"

run --repo "${WORK}" --no-fetch --idle-hours nonsense
[ "${CODE}" -eq 1 ] && grep -q 'Fix:' <<<"${ERR}" \
  && ok "a non-numeric --idle-hours exits 1 with a Fix:" \
  || bad "a non-numeric --idle-hours exits 1 with a Fix:" "code=${CODE} err=${ERR}"

run --repo "${WORK}" --no-fetch --bogus
[ "${CODE}" -eq 1 ] && grep -q 'Fix:' <<<"${ERR}" \
  && ok "an unknown argument exits 1 with a Fix: (never a default action)" \
  || bad "an unknown argument exits 1 with a Fix:" "code=${CODE} err=${ERR}"

# 13b (DND-526). Every argument is a declared flag and every value flag has
# its value. Each of these used to run a scan (or the self-test) anyway, or
# fail without naming the flag. A refusal is the usage exit (1), names the
# flag, carries Fix:, emits no rows, and never reaches the repo.
mk_gitlab 4003 "${SHA_OLD}" false true "$(ago '10 hours')" success 0
refused() { # refused <label> <needle> <args...>
  local label="$1" needle="$2"; shift 2
  run "$@"
  if [ "${CODE}" -eq 1 ] && grep -qF -- "${needle}" <<<"${ERR}" && grep -q 'Fix:' <<<"${ERR}" \
     && [ -z "${OUT}" ] && ! grep -q 'not a git worktree' <<<"${ERR}"; then
    ok "${label}"
  else
    bad "${label}" "code=${CODE} out=$(head -c 160 <<<"${OUT}") err=$(head -c 240 <<<"${ERR}")"
  fi
}
refused "a repeated --repo is refused (was: silently scanned the last one)" "--repo" \
  --repo "${TMP}/not-a-repo" --repo "${WORK}" --no-fetch
refused "a valueless --repo is refused, naming it" "--repo needs a value" --no-fetch --repo
refused "--repo swallowing the next flag is refused" "--repo needs a value" --repo --no-fetch
refused "a valueless --idle-hours is refused, naming it" "--idle-hours needs a value" \
  --repo "${WORK}" --no-fetch --idle-hours
refused "--repo=VALUE is refused" "--repo=" --repo="${WORK}" --no-fetch
refused "a repeated switch is refused" "--no-fetch" --repo "${WORK}" --no-fetch --no-fetch
refused "--self-test beside another flag is refused (was: ran the self-test)" "--self-test" \
  --self-test --json
# --no-fetch prices drift off un-refreshed refs: exit 4, rows complete (case 9c).
run --no-fetch --json --idle-hours 2 --repo "${WORK}"
[ "${CODE}" -eq 4 ] && grep -q '4003' <<<"${OUT}" \
  && ok "flag order still does not matter" \
  || bad "flag order does not matter" "code=${CODE} err=$(head -c 240 <<<"${ERR}")"

# ---------------------------------------------------------------------------
printf '\nready-and-idle self-test: %d passed, %d failed\n' "${PASS}" "${FAIL}"
if [ "${FAIL}" -ne 0 ]; then
  echo "Fix: reconcile ai/bin/ready-and-idle with the cases above — above all: a MEMBERSHIP probe that failed must exit 3 and never print the zero-orphans text; a genuinely empty result must exit 0 and stay textually distinct from it; and a drift priced off un-refreshed refs must render \`>=N\` (exit 4, rows still emitted), never a bare integer and never a suppressed list." >&2
  exit 1
fi
exit 0
