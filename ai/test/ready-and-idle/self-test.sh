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
# Receipts are sealed under the machine's receipt-seal key (DND-1814): a
# private key under the suite's temp dir here, never the real one.
export ATHENA_SECRETS_ROOT="${TMP}/secrets"
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
# \`gh pr view N --json mergeable\` (the settle re-read): view.json, else UNKNOWN.
if [ "\${1:-}" = pr ] && [ "\${2:-}" = view ]; then
  if [ -e "${FIX}/view.json" ]; then cat "${FIX}/view.json"; else echo '{"mergeable":"UNKNOWN"}'; fi
  exit 0
fi
cat "${FIX}/prs.json"
STUBEOF
chmod +x "${STUB}/glab" "${STUB}/gh"
# DND-1647: a guard stands behind every gh/glab stub on PATH, so a stub
# that is missing or not executable fails the suite instead of reaching the
# real CLI (ai/lib/forge-stub-guard.sh).
. "${HERE}/../../lib/forge-stub-guard.sh"
fsg_arm "${TMP}/forge-guard"
fsg_require_stubs "${STUB}" glab gh
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

# 9a'. No CI result on the head (a no-CI repo, like custom) is NOT JUDGED, and
# never a CLEAN SCAN. Measured 2026-09-28: custom's scan said CLEAN SCAN
# (excluded: not_green=6) while three finished PRs sat unmerged.
mk_gitlab 4002 "${SHA_OLD}" false true "$(ago '10 hours')" none 0
run --repo "${WORK}" --no-fetch
[ "${CODE}" -eq 0 ] && grep -q 'NOT JUDGED' <<<"${OUT}" \
  && grep -q 'no_ci_result=1' <<<"${OUT}" && grep -q 'Fix:' <<<"${OUT}" \
  && ! grep -q 'CLEAN SCAN' <<<"${OUT}${ERR}" \
  && ok "a request with no CI result is NOT JUDGED, never a CLEAN SCAN" \
  || bad "a request with no CI result is NOT JUDGED" "code=${CODE} out=${OUT} err=${ERR}"
run --repo "${WORK}" --no-fetch --json
grep -q '"unjudged": 1' <<<"${OUT}" \
  && ok "the JSON payload counts it as unjudged" \
  || bad "the JSON payload counts it as unjudged" "out=${OUT}"

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

# ---------------------------------------------------------------------------
# 14. DND-1505: a NO-CI repo's requests are judged by the merge bar's own
# evidence (athena:merge-boarding -> The merge bar): an integration-gate
# receipt for the exact head, recorded against origin/<target> or an ancestor
# of it, plus a critic PASS for that head. Before this, every request in a
# repo with no CI (custom) read NOT JUDGED forever, so a finished, abandoned
# custom PR had no adopt cover at all.
# ---------------------------------------------------------------------------
COMMON="${WORK}/.git"
# A head that DECLARES a gate (ai/bin/harness-gate, as custom does). Built with
# commit-tree on a private index, so the work tree and HEAD never move.
GATE_BLOB="$(printf '#!/bin/sh\nexit 0\n' | git -C "${WORK}" hash-object -w --stdin)"
SHA_GATED="$(
  export GIT_INDEX_FILE="${TMP}/gated.index"
  git -C "${WORK}" read-tree "${SHA_TIP}" \
    && git -C "${WORK}" update-index --add --cacheinfo "100755,${GATE_BLOB},ai/bin/harness-gate" \
    && git -C "${WORK}" commit-tree -p "${SHA_TIP}" -m gated "$(git -C "${WORK}" write-tree)"
)"

# The same head plus CI configuration: a repo WITH CI (gen_saas-shaped).
CI_BLOB="$(printf 'on: push\n' | git -C "${WORK}" hash-object -w --stdin)"
SHA_CI="$(
  export GIT_INDEX_FILE="${TMP}/ci.index"
  git -C "${WORK}" read-tree "${SHA_GATED}" \
    && git -C "${WORK}" update-index --add --cacheinfo "100644,${CI_BLOB},.github/workflows/ci.yml" \
    && git -C "${WORK}" commit-tree -p "${SHA_GATED}" -m ci "$(git -C "${WORK}" write-tree)"
)"

# mk_noci_pr <number> <head sha> [mergeable] [base] : one open PR with NO check
mk_noci_pr() {
  cat > "${FIX}/prs.json" <<EOF
[{"number":$1,"title":"fixture no-ci pr $1","headRefName":"b$1","baseRefName":"${4:-main}",
  "headRefOid":"$2","isDraft":false,"updatedAt":"$(ago '10 hours')",
  "reviewDecision":"","statusCheckRollup":[],"mergeable":"${3:-MERGEABLE}"}]
EOF
}
mk_ir_receipt() { # mk_ir_receipt <head> <base> [critic override reason]
  local co="null"
  [ -n "${3:-}" ] && co="\"$3\""
  mkdir -p "${COMMON}/integration-receipts"
  printf '{"schema":"integration-receipt/1","verdict":"pass","head":"%s","base":"%s","target_ref":"main","critic_override":%s,"recorded_at":"2026-10-01T00:00:00Z"}\n' \
    "$1" "$2" "${co}" > "${COMMON}/integration-receipts/$1.json"
  "${REPO}/ai/bin/receipt-seal" seal --kind integration "${COMMON}/integration-receipts/$1.json"
}
mk_critic() { # mk_critic <head> <pass|block>
  mkdir -p "${COMMON}/critic-verdicts"
  printf '{"schema":2,"tool":"critic-review","sha":"%s","base":"main","merge_base":"%s","verdict":"%s","findings":["fixture finding"],"dirty":false,"at":"2026-10-01T00:00:00Z"}\n' \
    "$1" "${SHA_TIP}" "$2" > "${COMMON}/critic-verdicts/$1.json"
  "${REPO}/ai/bin/receipt-seal" seal --kind critic "${COMMON}/critic-verdicts/$1.json"
}
clear_evidence() { rm -rf "${COMMON}/integration-receipts" "${COMMON}/critic-verdicts"; }

git -C "${WORK}" remote set-url origin git@github.com:fixture/proj.git

# 14a. THE ACCEPTANCE CASE: a green (receipt + critic PASS), abandoned no-CI PR
# is REPORTED. On the unfixed tool this read NOT JUDGED and listed nothing.
clear_evidence; mk_ir_receipt "${SHA_GATED}" "${SHA_TIP}"; mk_critic "${SHA_GATED}" pass
mk_noci_pr 77 "${SHA_GATED}"
run --repo "${WORK}" --no-fetch --json
[ "${CODE}" -eq 4 ] && grep -q '"orphans": 1' <<<"${OUT}" && grep -q '"id": 77' <<<"${OUT}" \
  && grep -q '"evidence": "integration receipt + critic PASS' <<<"${OUT}" \
  && grep -q '"unjudged": 0' <<<"${OUT}" \
  && ok "no-CI: a PR with an integration receipt and a critic PASS on its head is reported" \
  || bad "no-CI: a receipted, critic-PASSed PR is reported" "code=${CODE} out=${OUT} err=${ERR}"
run --repo "${WORK}" --no-fetch
grep -q '^#77 ' <<<"${OUT}" && ! grep -q 'NOT JUDGED' <<<"${OUT}${ERR}" \
  && ok "no-CI: the table lists it and does not call it NOT JUDGED" \
  || bad "no-CI: the table lists it" "code=${CODE} out=${OUT} err=${ERR}"

# 14b. The critic receipt went with a REMOVED worktree. The integration receipt
# alone still proves the PASS: integration-gate writes one only after reading a
# green verdict for that head, unless it records a --critic-override.
clear_evidence; mk_ir_receipt "${SHA_GATED}" "${SHA_TIP}"
run --repo "${WORK}" --no-fetch --json
[ "${CODE}" -eq 4 ] && grep -q '"orphans": 1' <<<"${OUT}" \
  && grep -q '"evidence": "integration receipt (critic PASS attested by the gate' <<<"${OUT}" \
  && ok "no-CI: a receipt with no override attests the critic PASS when the critic receipt is gone" \
  || bad "no-CI: the receipt attests the critic PASS" "code=${CODE} out=${OUT} err=${ERR}"

# 14c-f. Evidence that LOOKED and found the PR not finished: a judged
# exclusion, so the scan is CLEAN, and the reason is counted by name.
noci_excl() { # noci_excl <label> <excluded key>
  local label="$1"
  run --repo "${WORK}" --no-fetch
  if [ "${CODE}" -eq 0 ] && grep -q 'CLEAN SCAN' <<<"${OUT}" && grep -q "$2=1" <<<"${OUT}" \
     && ! grep -q 'NOT JUDGED' <<<"${OUT}${ERR}"; then
    ok "no-CI: ${label} excludes the PR as $2 (judged, not NOT JUDGED)"
  else
    bad "no-CI: ${label} excludes the PR as $2" "code=${CODE} out=${OUT} err=${ERR}"
  fi
}
clear_evidence; mk_critic "${SHA_GATED}" pass
noci_excl "no integration receipt" no_local_receipt
# Receipts are local to this machine, so the clean line must say where it looked.
grep -q 'THIS machine' <<<"${OUT}" \
  && ok "no-CI: no_local_receipt says it searched this machine's receipts only" \
  || bad "no-CI: no_local_receipt names the machine-local search" "out=${OUT}"
# A receipt says nothing about a target that moved into a conflict.
clear_evidence; mk_ir_receipt "${SHA_GATED}" "${SHA_TIP}"; mk_critic "${SHA_GATED}" pass
mk_noci_pr 77 "${SHA_GATED}" CONFLICTING
noci_excl "a conflicting PR, receipt or not," conflicting
mk_noci_pr 77 "${SHA_GATED}"
clear_evidence; mk_ir_receipt "${SHA_GATED}" "${SHA_TIP}"; mk_critic "${SHA_GATED}" block
noci_excl "a recorded critic BLOCK" critic_block
clear_evidence; mk_ir_receipt "${SHA_GATED}" "${SHA_TIP}" "model unreachable"
noci_excl "a receipt that overrode the critic, and no PASS" no_critic_pass
# The recorded base is not an ancestor of origin/main (the PR head itself).
clear_evidence; mk_ir_receipt "${SHA_GATED}" "${SHA_GATED}"; mk_critic "${SHA_GATED}" pass
noci_excl "a receipt for another base" stale_gate_receipt
# A receipt of the right shape that integration-gate never sealed (written by
# hand, by branch code, or edited after sealing): UNVERIFIED, so judged
# stale_gate_receipt, never reported ready (DND-1814).
clear_evidence; mk_ir_receipt "${SHA_GATED}" "${SHA_TIP}"; mk_critic "${SHA_GATED}" pass
printf '{"schema":"integration-receipt/1","verdict":"pass","head":"%s","base":"%s","target_ref":"main","critic_override":null,"recorded_at":"2026-10-01T00:00:00Z"}\n' \
  "${SHA_GATED}" "${SHA_TIP}" > "${COMMON}/integration-receipts/${SHA_GATED}.json"
noci_excl "a hand-written (unsealed) receipt" stale_gate_receipt

# 14g. COULD NOT LOOK is not "no receipt": a head this checkout does not have
# cannot be asked whether it declares a gate. It is NOT JUDGED, never CLEAN,
# and the line names the request and the Fix.
clear_evidence
mk_noci_pr 78 "1111111111111111111111111111111111111111"
run --repo "${WORK}" --no-fetch
[ "${CODE}" -eq 0 ] && grep -q 'NOT JUDGED' <<<"${OUT}" && grep -q 'evidence_unreadable=1' <<<"${OUT}" \
  && ! grep -q 'CLEAN SCAN' <<<"${OUT}${ERR}" && grep -q '#78' <<<"${ERR}" && grep -q 'Fix:' <<<"${OUT}" \
  && ok "no-CI: an unreadable head is NOT JUDGED (could not look), never a clean miss" \
  || bad "no-CI: an unreadable head is NOT JUDGED" "code=${CODE} out=${OUT} err=${ERR}"
run --repo "${WORK}" --no-fetch --json
grep -q '"unjudged": 1' <<<"${OUT}" \
  && ok "no-CI: the JSON counts the unreadable one as unjudged" \
  || bad "no-CI: the JSON counts it as unjudged" "out=${OUT}"

# 14h. An UNREADABLE receipt store is could-not-look too, not "no receipt".
if [ "$(id -u)" -ne 0 ]; then
  clear_evidence; mk_ir_receipt "${SHA_GATED}" "${SHA_TIP}"; mk_critic "${SHA_GATED}" pass
  chmod 000 "${COMMON}/integration-receipts"
  mk_noci_pr 79 "${SHA_GATED}"
  run --repo "${WORK}" --no-fetch
  chmod 755 "${COMMON}/integration-receipts"
  [ "${CODE}" -eq 0 ] && grep -q 'NOT JUDGED' <<<"${OUT}" && grep -q 'evidence_unreadable=1' <<<"${OUT}" \
    && ! grep -q 'no_local_receipt' <<<"${OUT}" && grep -q 'COULD NOT LOOK' <<<"${ERR}" \
    && ok "no-CI: an unreadable receipt store is NOT JUDGED, not no_local_receipt" \
    || bad "no-CI: an unreadable receipt store is NOT JUDGED" "code=${CODE} out=${OUT} err=${ERR}"
fi

# 14i. A head that declares NO gate keeps the old reading: nothing can judge
# it, so it is NOT JUDGED (no_ci_result), whatever receipts exist.
clear_evidence
mk_noci_pr 80 "${SHA_OLD}"
run --repo "${WORK}" --no-fetch
[ "${CODE}" -eq 0 ] && grep -q 'NOT JUDGED' <<<"${OUT}" && grep -q 'no_ci_result=1' <<<"${OUT}" \
  && ! grep -q 'CLEAN SCAN' <<<"${OUT}" \
  && ok "no-CI: a head that declares no gate stays NOT JUDGED" \
  || bad "no-CI: a head that declares no gate stays NOT JUDGED" "code=${CODE} out=${OUT} err=${ERR}"

# 14j. A repo WITH CI is never judged on receipts: an empty rollup there means
# its checks did not run on this head (a conflicting PR gets none), so a
# receipt + PASS must not report it.
clear_evidence; mk_ir_receipt "${SHA_CI}" "${SHA_TIP}"; mk_critic "${SHA_CI}" pass
mk_noci_pr 81 "${SHA_CI}"
run --repo "${WORK}" --no-fetch
[ "${CODE}" -eq 0 ] && grep -q 'NOT JUDGED' <<<"${OUT}" && grep -q 'no_ci_result=1' <<<"${OUT}" \
  && ! grep -q '^#81 ' <<<"${OUT}" \
  && ok "no-CI: a head carrying CI configuration is never judged on its receipt" \
  || bad "no-CI: a CI repo is never judged on its receipt" "code=${CODE} out=${OUT} err=${ERR}"

# 14k. Unknown mergeability and an unresolvable target are COULD NOT LOOK.
clear_evidence; mk_ir_receipt "${SHA_GATED}" "${SHA_TIP}"; mk_critic "${SHA_GATED}" pass
mk_noci_pr 82 "${SHA_GATED}" UNKNOWN
run --repo "${WORK}" --no-fetch
[ "${CODE}" -eq 0 ] && grep -q 'evidence_unreadable=1' <<<"${OUT}" && ! grep -q 'CLEAN SCAN' <<<"${OUT}" \
  && grep -q '#82 NOT JUDGED.*mergeable="UNKNOWN"' <<<"${ERR}" \
  && ok "no-CI: mergeability still UNKNOWN after the re-reads is NOT JUDGED and named, never a pass" \
  || bad "no-CI: unknown mergeability is NOT JUDGED" "code=${CODE} out=${OUT} err=${ERR}"
grep -qx 3 <<<"$(grep -c 'gh pr view 82 --json mergeable' "${TMP}/invoked.log")" \
  && ok "no-CI: UNKNOWN is re-read a bounded number of times (3)" \
  || bad "no-CI: UNKNOWN is re-read 3 times" "$(grep 'pr view' "${TMP}/invoked.log")"
# GitHub computes mergeability lazily: the list says UNKNOWN, a re-read settles it.
echo '{"mergeable":"MERGEABLE"}' > "${FIX}/view.json"
run --repo "${WORK}" --no-fetch --json
rm -f "${FIX}/view.json"
[ "${CODE}" -eq 4 ] && grep -q '"id": 82' <<<"${OUT}" \
  && ok "no-CI: an UNKNOWN that a re-read settles to MERGEABLE is judged and reported" \
  || bad "no-CI: a settled UNKNOWN is judged" "code=${CODE} out=${OUT} err=${ERR}"
# A head with no declared gate never pays for the re-read.
: > "${TMP}/invoked.log"
mk_noci_pr 84 "${SHA_OLD}" UNKNOWN
run --repo "${WORK}" --no-fetch
! grep -q 'pr view' "${TMP}/invoked.log" \
  && ok "no-CI: mergeability is not re-read for a head nothing could judge" \
  || bad "no-CI: no re-read for an ungated head" "$(cat "${TMP}/invoked.log")"
mk_noci_pr 83 "${SHA_GATED}" MERGEABLE nosuchbranch
run --repo "${WORK}" --no-fetch
[ "${CODE}" -eq 0 ] && grep -q 'evidence_unreadable=1' <<<"${OUT}" \
  && grep -q '#83 NOT JUDGED.*origin/nosuchbranch does not resolve' <<<"${ERR}" \
  && ok "no-CI: an unresolvable target is NOT JUDGED and named" \
  || bad "no-CI: an unresolvable target is NOT JUDGED" "code=${CODE} out=${OUT} err=${ERR}"
clear_evidence

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
# DND-1647: no gh/glab call may have fallen through past its stub.
if fsg_verify; then ok "no gh/glab call fell through past its stub (DND-1647)"
else bad "no gh/glab call fell through past its stub (DND-1647)" "see the forge-stub-guard FAIL above"; fi

printf '\nready-and-idle self-test: %d passed, %d failed\n' "${PASS}" "${FAIL}"
if [ "${FAIL}" -ne 0 ]; then
  echo "Fix: reconcile ai/bin/ready-and-idle with the cases above — above all: a MEMBERSHIP probe that failed must exit 3 and never print the zero-orphans text; a genuinely empty result must exit 0 and stay textually distinct from it; and a drift priced off un-refreshed refs must render \`>=N\` (exit 4, rows still emitted), never a bare integer and never a suppressed list." >&2
  exit 1
fi
exit 0
