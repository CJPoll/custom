#!/usr/bin/env bash
# self-test.sh -- the gh-ci-wait suite (DND-1708, DND-1706). Discovered by
# harness-gate (every committed `self-test.sh` runs).
#
# Layers, in TDD order:
#   1. the domain suite (domain_test.rb): parsing a `gh api -i` response,
#      judging CI state, the wait decision, argument validation;
#   2. the manager suite (manager_test.rb): the read-judge-sleep loop with a
#      fake reader, clock and sleeper;
#   3. the CLI end to end against a FAKE gh (GH_CI_WAIT_GH) that prints
#      recorded responses. Every case ends on its first read, so nothing
#      sleeps. It never reaches GitHub and never runs gh-athena.
# Every miss is tested, not just the hit (~/.claude/CLAUDE.md -> *A failed
# lookup must never look like an empty one*): a rate limit, a 404 and an
# unreadable body each say COULD-NOT-LOOK, never green or empty. Functional
# only (DND-1222): no sleeps, no timing, no load. Repos and shas are synthetic.

set -u

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT="$(cd -- "${HERE}/../../.." && pwd -P)"
BIN="${ROOT}/ai/bin/gh-ci-wait"

PASS=0
FAIL=0
ok()    { PASS=$((PASS + 1)); printf 'ok   %s\n' "$1"; }
bad()   { FAIL=$((FAIL + 1)); printf 'FAIL %s\n' "$1"; [ -n "${2:-}" ] && printf '     %s\n' "$2"; return 0; }
eq()    { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$3], got [$2]"; fi; }
has()   { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "no [$3] in: $2" ;; esac; }
lacks() { case "$2" in *"$3"*) bad "$1" "unexpected [$3] in: $2" ;; *) ok "$1" ;; esac; }

[ -x /usr/bin/ruby ] || { echo "gh-ci-wait self-test: FAIL -- /usr/bin/ruby is missing"; echo "  Fix: install the harness Ruby at /usr/bin/ruby (DND-931); this suite does not skip."; exit 1; }
[ -x "${BIN}" ] || { echo "gh-ci-wait self-test: FAIL -- ${BIN} missing or not executable"; echo "  Fix: chmod +x ai/bin/gh-ci-wait"; exit 1; }

echo "== domain suite"
if /usr/bin/ruby "${HERE}/domain_test.rb"; then ok "domain suite"; else bad "domain suite"; fi
echo "== manager suite"
if /usr/bin/ruby "${HERE}/manager_test.rb"; then ok "manager suite"; else bad "manager suite"; fi

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT
SHA="$(printf 'e%.0s' $(seq 1 40))"

# The fake gh: records its argv, prints the recorded response, exits as told.
FAKE="${TMP}/gh"
cat >"${FAKE}" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${FAKE_DIR}/argv"
cat "${FAKE_DIR}/stdout"
cat "${FAKE_DIR}/stderr" >&2
exit "$(cat "${FAKE_DIR}/code")"
EOF
chmod +x "${FAKE}"

OUT=""; ERR=""; CODE=0
# respond CODE STDOUT [STDERR] : what the fake gh answers next.
respond() {
  printf '%s' "$1" >"${TMP}/code"
  printf '%b' "$2" >"${TMP}/stdout"
  printf '%b' "${3:-}" >"${TMP}/stderr"
  : >"${TMP}/argv"
}
run() {
  OUT="$(FAKE_DIR="${TMP}" GH_CI_WAIT_GH="${FAKE}" /usr/bin/ruby "${BIN}" "$@" 2>"${TMP}/err" </dev/null)"
  CODE=$?
  ERR="$(cat "${TMP}/err")"
}
hdr='HTTP/2.0 200 OK\r\nX-Ratelimit-Resource: core\r\n\r\n'

echo "== --help"
OUT="$(/usr/bin/ruby "${BIN}" --help 2>/dev/null)"; CODE=$?
eq "--help exits 0" "${CODE}" "0"
has "--help is on stdout" "${OUT}" "Usage:"
has "--help names the exit codes" "${OUT}" "COULD-NOT-LOOK"

echo "== usage errors carry Fix and exit 2"
run --repo acme/app --sha abc
eq "a short sha exits 2" "${CODE}" "2"
has "a short sha names the 40-hex rule" "${ERR}" "40-hex"
has "a usage error carries Fix:" "${ERR}" "Fix:"
run --repo acme/app
eq "no --sha and no --run-id exits 2" "${CODE}" "2"
run --repo acme/app --sha "${SHA}" --interval 3
eq "an interval of 3 s (gh run watch's default) is refused" "${CODE}" "2"
run --repo acme/app --sha "${SHA}" --bogus 1
eq "an unknown flag is refused, not ignored" "${CODE}" "2"
OUT="$(GH_CI_WAIT_GH=gh /usr/bin/ruby "${BIN}" --repo acme/app --sha "${SHA}" 2>&1)"; CODE=$?
eq "a relative GH_CI_WAIT_GH is refused" "${CODE}" "2"

echo "== checks: green"
respond 0 "${hdr}"'{"total_count":2,"check_runs":[{"name":"build","status":"completed","conclusion":"success"},{"name":"lint","status":"completed","conclusion":"skipped"}]}'
run --repo acme/app --sha "${SHA}"
eq "all green exits 0" "${CODE}" "0"
has "DONE verdict line" "${OUT}" "VERDICT: DONE checks repo=acme/app"
eq "it read with api -i, the sha's latest check-runs" "$(cat "${TMP}/argv")" "api -i repos/acme/app/commits/${SHA}/check-runs?filter=latest&per_page=100"
lacks "DONE carries no Fix" "${OUT}" "Fix:"

echo "== checks: red"
respond 0 "${hdr}"'{"total_count":1,"check_runs":[{"name":"test","status":"completed","conclusion":"failure"}]}'
run --repo acme/app --sha "${SHA}"
eq "a red check exits 4" "${CODE}" "4"
has "FAILED names the check" "${OUT}" "test(failure)"
has "FAILED carries Fix" "${OUT}" "Fix:"

echo "== a primary rate limit past --max: COULD-NOT-LOOK with the reset time, at once"
reset=$(( $(date +%s) + 3600 ))
respond 1 "HTTP/2.0 403 Forbidden\r\nX-Ratelimit-Remaining: 0\r\nX-Ratelimit-Reset: ${reset}\r\nX-Ratelimit-Resource: core\r\n\r\n"'{"message":"API rate limit exceeded for user ID 1."}' \
  "gh: API rate limit exceeded for user ID 1. (HTTP 403)\n"
run --repo acme/app --sha "${SHA}" --max 60
eq "rate-limited past --max exits 3" "${CODE}" "3"
has "COULD-NOT-LOOK verdict" "${OUT}" "VERDICT: COULD-NOT-LOOK"
has "it names the reset time" "${OUT}" "$(date -u -d "@${reset}" +%Y-%m-%dT%H:%M:%SZ)"
has "it names the bucket" "${OUT}" "resource=core"
has "it says not idle" "${OUT}" "not idle"
has "the limit is logged on stderr" "${ERR}" "RATE-LIMITED"
lacks "never DONE" "${OUT}" "DONE"
eq "exactly one read: no polling into the limit" "$(wc -l <"${TMP}/argv" | tr -d ' ')" "1"

echo "== a rate-limit seen only on stderr (gh without headers) is still a limit"
respond 1 "" "HTTP 403: API rate limit exceeded for user ID 1.\n"
run --repo acme/app --sha "${SHA}" --max 30
eq "stderr-only limit past --max exits 3" "${CODE}" "3"
has "stderr-only limit says rate-limited" "${OUT}" "rate-limited"

echo "== a run id that matches nothing"
respond 1 'HTTP/2.0 404 Not Found\r\n\r\n{"message":"Not Found"}' "gh: Not Found (HTTP 404)\n"
run --repo acme/app --run-id 12345
eq "404 exits 3" "${CODE}" "3"
has "404 names the run id" "${OUT}" "id=12345"
eq "a run id is read by id" "$(cat "${TMP}/argv")" "api -i repos/acme/app/actions/runs/12345"

echo "== a run for another head"
respond 0 "${hdr}"'{"id":5,"status":"completed","conclusion":"success","head_sha":"ffffffffffffffffffffffffffffffffffffffff"}'
run --repo acme/app --run-id 5 --sha "${SHA}"
eq "wrong head exits 5" "${CODE}" "5"
has "WRONG-HEAD verdict" "${OUT}" "VERDICT: WRONG-HEAD"

echo "== a deploy watch by workflow name"
respond 0 "${hdr}"'{"total_count":1,"workflow_runs":[{"id":9,"name":"Post-Merge Deploy","path":".github/workflows/deploy.yml","head_sha":"'"${SHA}"'","status":"completed","conclusion":"success","created_at":"2026-10-02T07:00:00Z"}]}'
run --repo acme/app --workflow "Post-Merge Deploy" --sha "${SHA}"
eq "the workflow's completed run exits 0" "${CODE}" "0"
eq "it lists runs by head_sha" "$(cat "${TMP}/argv")" "api -i repos/acme/app/actions/runs?head_sha=${SHA}&per_page=100"

echo "== an unreadable 2xx body"
respond 0 "${hdr}"'{"message":"surprise"}'
run --repo acme/app --sha "${SHA}"
eq "an unreadable body exits 3" "${CODE}" "3"
lacks "an unreadable body is never DONE" "${OUT}" "DONE"

echo
echo "gh-ci-wait self-test: ${PASS} passed, ${FAIL} failed"
if [ "${FAIL}" -ne 0 ]; then
  echo "Fix: read the FAIL lines above; the domain rules are in ai/lib/gh_ci_wait.rb, the loop in ai/lib/gh_ci_wait_io.rb"
  exit 1
fi
exit 0
