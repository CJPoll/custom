#!/usr/bin/env bash
# self-test.sh -- the glab-ci-wait suite (DND-1940). Discovered by
# harness-gate (every committed `self-test.sh` runs).
#
# Layers, in TDD order:
#   1. the domain suite (domain_test.rb): parsing a `glab api -i` response,
#      the keys, choosing the current pipelines, bridges, the verdict;
#   2. the manager suite (manager_test.rb): the read-judge-sleep loop with a
#      fake reader, clock and sleeper (every verdict, NOT-FOUND after the
#      grace, a 429 backing off, a child pipeline followed);
#   3. the CLI end to end against a FAKE glab (GLAB_CI_WAIT_GLAB) that answers
#      each read from a recorded response chosen by its path. Every case ends
#      on its first poll, so nothing sleeps. It never reaches GitLab and never
#      runs glab-athena.
# Every miss is tested, not just the hit (~/.claude/CLAUDE.md -> *A failed
# lookup must never look like an empty one*): an unknown project or sha is a
# named COULD-NOT-LOOK, never NOT-FOUND. Functional only (DND-1222): no
# sleeps, no timing, no load. Projects and shas are synthetic.

set -u

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT="$(cd -- "${HERE}/../../.." && pwd -P)"
BIN="${ROOT}/ai/bin/glab-ci-wait"

PASS=0
FAIL=0
ok()    { PASS=$((PASS + 1)); printf 'ok   %s\n' "$1"; }
bad()   { FAIL=$((FAIL + 1)); printf 'FAIL %s\n' "$1"; [ -n "${2:-}" ] && printf '     %s\n' "$2"; return 0; }
eq()    { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$3], got [$2]"; fi; }
has()   { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "no [$3] in: $2" ;; esac; }
lacks() { case "$2" in *"$3"*) bad "$1" "unexpected [$3] in: $2" ;; *) ok "$1" ;; esac; }

[ -x /usr/bin/ruby ] || { echo "glab-ci-wait self-test: FAIL -- /usr/bin/ruby is missing"; echo "  Fix: install the harness Ruby at /usr/bin/ruby (DND-931); this suite does not skip."; exit 1; }
[ -x "${BIN}" ] || { echo "glab-ci-wait self-test: FAIL -- ${BIN} missing or not executable"; echo "  Fix: chmod +x ai/bin/glab-ci-wait"; exit 1; }

echo "== domain suite"
if /usr/bin/ruby "${HERE}/domain_test.rb"; then ok "domain suite"; else bad "domain suite"; fi
echo "== manager suite"
if /usr/bin/ruby "${HERE}/manager_test.rb"; then ok "manager suite"; else bad "manager suite"; fi

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT
SHA="$(printf 'e%.0s' $(seq 1 40))"

# The fake glab: records its argv, and answers from the first route whose
# pattern the path contains. A route is a directory under routes/ holding
# pattern, stdout, stderr and code.
FAKE="${TMP}/glab"
cat >"${FAKE}" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${FAKE_DIR}/argv"
path="${!#}"
for r in "${FAKE_DIR}"/routes/*; do
  [ -d "${r}" ] || continue
  case "${path}" in
    *"$(cat "${r}/pattern")"*) cat "${r}/stdout"; cat "${r}/stderr" >&2; exit "$(cat "${r}/code")" ;;
  esac
done
echo "fake glab: no route for ${path}" >&2
exit 1
EOF
chmod +x "${FAKE}"

OUT=""; ERR=""; CODE=0
N=0
reset_routes() { rm -rf "${TMP}/routes"; mkdir -p "${TMP}/routes"; : >"${TMP}/argv"; N=0; }
# route PATTERN CODE STDOUT [STDERR] : the fake's answer to a path containing PATTERN.
route() {
  N=$((N + 1))
  local d="${TMP}/routes/$(printf '%03d' "${N}")"
  mkdir -p "${d}"
  printf '%s' "$1" >"${d}/pattern"
  printf '%s' "$2" >"${d}/code"
  printf '%b' "$3" >"${d}/stdout"
  printf '%b' "${4:-}" >"${d}/stderr"
}
run() {
  OUT="$(FAKE_DIR="${TMP}" GLAB_CI_WAIT_GLAB="${FAKE}" /usr/bin/ruby "${BIN}" "$@" 2>"${TMP}/err" </dev/null)"
  CODE=$?
  ERR="$(cat "${TMP}/err")"
}
hdr='HTTP/2.0 200 OK\r\nRatelimit-Remaining: 1999\r\n\r\n'
commit_ok() { route "/repository/commits/${SHA}" 0 "${hdr}"'{"id":"'"${SHA}"'"}'; }
pl() { printf '{"id":%s,"status":"%s","source":"%s","ref":"%s","sha":"%s","web_url":"https://gitlab.com/acme/app/-/pipelines/%s"}' "$1" "$2" "${3:-push}" "${4:-main}" "${SHA}" "$1"; }

echo "== --help"
OUT="$(/usr/bin/ruby "${BIN}" --help 2>/dev/null)"; CODE=$?
eq "--help exits 0" "${CODE}" "0"
has "--help is on stdout" "${OUT}" "Usage:"
has "--help names NOT-FOUND" "${OUT}" "NOT-FOUND"
has "--help names --include-children" "${OUT}" "--include-children"

echo "== usage errors carry Fix and exit 2"
reset_routes
run --project acme/app --sha abc
eq "a short sha exits 2" "${CODE}" "2"
has "a usage error carries Fix:" "${ERR}" "Fix:"
run --project https://gitlab.com/acme/app --sha "${SHA}"
eq "a URL for --project exits 2 (a wrongly computed key is not NOT-FOUND)" "${CODE}" "2"
run --project 4242 --sha "${SHA}"
eq "a numeric project id exits 2" "${CODE}" "2"
run --project acme%2Fapp --sha "${SHA}"
eq "a pre-encoded project exits 2" "${CODE}" "2"
run --project acme/app --sha "${SHA}" --interval 5
eq "an interval of 5 s is refused" "${CODE}" "2"
run --project acme/app --sha "${SHA}" --source web
eq "an unknown --source is refused" "${CODE}" "2"
run --project acme/app --sha "${SHA}" --live
eq "an unknown flag is refused, not ignored" "${CODE}" "2"
eq "no usage error read the forge" "$(wc -l <"${TMP}/argv" | tr -d ' ')" "0"
OUT="$(GLAB_CI_WAIT_GLAB=glab /usr/bin/ruby "${BIN}" --project acme/app --sha "${SHA}" 2>&1)"; CODE=$?
eq "a relative GLAB_CI_WAIT_GLAB is refused" "${CODE}" "2"

echo "== DONE: the reads it makes"
reset_routes; commit_ok
route "/pipelines?" 0 "${hdr}[$(pl 12 success)]"
run --project acme/app --sha "${SHA}" --ref main --source push
eq "a succeeded pipeline exits 0" "${CODE}" "0"
has "DONE names the pipeline id" "${OUT}" "VERDICT: DONE project=acme/app sha=eeeeeeeeeeee ref=main source=push pipelines=12:"
lacks "DONE carries no Fix" "${OUT}" "Fix:"
eq "it read the commit, then the pipelines, with api -i, the project as a %2F path" "$(cat "${TMP}/argv")" "api -i projects/acme%2Fapp/repository/commits/${SHA}
api -i projects/acme%2Fapp/pipelines?sha=${SHA}&order_by=id&sort=desc&per_page=100&ref=main&source=push"

echo "== FAILED: the failing job list"
reset_routes; commit_ok
route "/pipelines/12/jobs" 0 "${hdr}"'[{"id":31,"name":"rspec","stage":"test","status":"failed","allow_failure":false,"failure_reason":"script_failure","web_url":"https://gitlab.com/acme/app/-/jobs/31"},{"id":32,"name":"lint","stage":"test","status":"failed","allow_failure":true}]'
route "/pipelines?" 0 "${hdr}[$(pl 12 failed)]"
run --project acme/app --sha "${SHA}"
eq "a failed pipeline exits 4" "${CODE}" "4"
has "FAILED verdict" "${OUT}" "VERDICT: FAILED"
has "a JOB: line per failing job, with its id and url" "${OUT}" "JOB: pipeline=12 id=31 test/rspec (failed: script_failure) https://gitlab.com/acme/app/-/jobs/31"
lacks "an allowed-to-fail job is not listed" "${OUT}" "lint"
has "FAILED carries Fix" "${OUT}" "Fix:"

echo "== CANCELED"
reset_routes; commit_ok
route "/pipelines/12/jobs" 0 "${hdr}[]"
route "/pipelines?" 0 "${hdr}[$(pl 12 canceled)]"
run --project acme/app --sha "${SHA}"
eq "a canceled pipeline exits 5" "${CODE}" "5"
has "CANCELED verdict" "${OUT}" "VERDICT: CANCELED"

echo "== NOT-FOUND: the commit exists, no pipeline is listed"
reset_routes; commit_ok
route "/pipelines?" 0 "${hdr}[]"
run --project acme/app --sha "${SHA}" --ref main --grace 0
eq "no pipeline exits 6" "${CODE}" "6"
has "NOT-FOUND verdict" "${OUT}" "VERDICT: NOT-FOUND"
has "NOT-FOUND names the filter" "${OUT}" "ref=main"
lacks "NOT-FOUND is never DONE" "${OUT}" "DONE"

echo "== a wrongly computed key is a named error, never NOT-FOUND"
reset_routes
route "/repository/commits/" 1 'HTTP/2.0 404 Not Found\r\n\r\n{"message":"404 Project Not Found"}' "glab: 404 Project Not Found (HTTP 404)\n"
run --project acme/ap --sha "${SHA}" --grace 0
eq "an unknown project exits 3" "${CODE}" "3"
has "it names the project" "${OUT}" "project acme/ap is unknown"
lacks "an unknown project is never NOT-FOUND" "${OUT}" "VERDICT: NOT-FOUND"
reset_routes
route "/repository/commits/" 1 'HTTP/2.0 404 Not Found\r\n\r\n{"message":"404 Commit Not Found"}' "glab: 404 Commit Not Found (HTTP 404)\n"
run --project acme/app --sha "${SHA}" --grace 0
eq "an unknown sha exits 3" "${CODE}" "3"
has "it says the sha is not a commit" "${OUT}" "is not a commit in project acme/app"

echo "== a glab-athena refusal is COULD-NOT-LOOK with the preflight Fix"
reset_routes
route "/repository/commits/" 3 "" "glab-athena: BAD KEY: no identity for namespace acme.\n  Fix: ...\n"
run --project acme/app --sha "${SHA}"
eq "a refusal exits 3" "${CODE}" "3"
has "the Fix names forge-preflight" "${OUT}" "forge-preflight"
eq "exactly one read: a refusal is not retried" "$(wc -l <"${TMP}/argv" | tr -d ' ')" "1"

echo "== a 429 past --timeout: COULD-NOT-LOOK with the reset time, at once"
reset_routes; commit_ok
reset=$(( $(date +%s) + 3600 ))
route "/pipelines?" 1 "HTTP/2.0 429 Too Many Requests\r\nRatelimit-Remaining: 0\r\nRatelimit-Reset: ${reset}\r\n\r\n"'{"message":"429 Too Many Requests"}' "glab: 429 Too Many Requests (HTTP 429)\n"
run --project acme/app --sha "${SHA}" --timeout 60
eq "rate-limited past --timeout exits 3" "${CODE}" "3"
has "it names the reset time" "${OUT}" "$(date -u -d "@${reset}" +%Y-%m-%dT%H:%M:%SZ)"
has "the limit is logged on stderr" "${ERR}" "RATE-LIMITED"
eq "one pipelines read: no polling into the limit" "$(grep -c '/pipelines?' "${TMP}/argv")" "1"

echo "== --include-children follows a trigger bridge to its child pipeline"
reset_routes; commit_ok
route "/pipelines/12/bridges" 0 "${hdr}"'[{"id":40,"name":"deploy","stage":"deploy","status":"success","allow_failure":false,"downstream_pipeline":{"id":77,"status":"failed","source":"parent_pipeline","ref":"main","sha":"'"${SHA}"'","web_url":"https://gitlab.com/acme/app/-/pipelines/77"}}]'
route "/pipelines/77/bridges" 0 "${hdr}[]"
route "/pipelines/77/jobs" 0 "${hdr}"'[{"id":51,"name":"health-gate","stage":"verify","status":"failed","allow_failure":false}]'
route "/pipelines?" 0 "${hdr}[$(pl 12 success)]"
run --project acme/app --sha "${SHA}" --ref main --source push --include-children
eq "a failed child behind a green parent exits 4" "${CODE}" "4"
has "the verdict names both pipeline ids" "${OUT}" "pipelines=12,77"
has "the child's failing job is listed" "${OUT}" "JOB: pipeline=77 id=51 verify/health-gate (failed)"
has "it read the child's bridges by its project path" "$(cat "${TMP}/argv")" "api -i projects/acme%2Fapp/pipelines/77/bridges?per_page=100"
run --project acme/app --sha "${SHA}" --ref main --source push
eq "without --include-children the parent alone is judged" "${CODE}" "0"

echo "== an unreadable 2xx body"
reset_routes; commit_ok
route "/pipelines?" 0 "${hdr}"'{"message":"surprise"}'
run --project acme/app --sha "${SHA}"
eq "an unreadable body exits 3" "${CODE}" "3"
lacks "an unreadable body is never DONE" "${OUT}" "DONE"

echo
echo "glab-ci-wait self-test: ${PASS} passed, ${FAIL} failed"
if [ "${FAIL}" -ne 0 ]; then
  echo "Fix: read the FAIL lines above; the domain rules are in ai/lib/glab_ci_wait.rb, the loop in ai/lib/glab_ci_wait_io.rb"
  exit 1
fi
exit 0
