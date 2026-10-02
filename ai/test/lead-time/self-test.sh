#!/usr/bin/env bash
# self-test for ai/bin/lead-time — discovered and run by harness-gate.
#
# Two layers:
#   1. The tool's own pure-logic --self-test (no network, no git).
#   2. argv handling through the real CLI (DND-526). Every case points --repo at
#      a path that does not exist, so a command line the parser ACCEPTS stops at
#      the "not a git worktree" check and never reaches the forge. A refused one
#      must stop earlier, naming the offending flag — never reach the repo check
#      at all. The old parser read a valueless `--slow` as nil and silently
#      dropped the --slow filter, which is the regression pinned here.
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
bin="$here/../../bin/lead-time"

if [ ! -x "$bin" ]; then
  echo "lead-time self-test: FAIL — $bin missing or not executable" >&2
  echo "Fix: chmod +x ai/bin/lead-time" >&2
  exit 1
fi

PASS=0; FAIL=0
ok()  { printf '  ok    %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  FAIL  %s\n        %s\n' "$1" "$2"; FAIL=$((FAIL+1)); }

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT
# DND-1647: a guard stands behind every gh/glab stub below, so a stub that is
# missing or not executable fails the suite instead of reaching the real CLI.
# shellcheck source=../../lib/forge-stub-guard.sh
. "$here/../../lib/forge-stub-guard.sh"
fsg_arm "${TMP}/forge-guard"
NOREPO="${TMP}/no-such-repo"
SINCE="2026-09-19T00:00:00Z"

OUT=""; ERR=""; CODE=0
run() { OUT="$(/usr/bin/ruby "$bin" "$@" 2>"${TMP}/err" </dev/null)"; CODE=$?; ERR="$(cat "${TMP}/err")"; }

# 1. The pure-logic suite.
if /usr/bin/ruby "$bin" --self-test >"${TMP}/st" 2>&1; then
  ok "lead-time --self-test passes"
else
  bad "lead-time --self-test passes" "$(tail -5 "${TMP}/st")"
fi

# 1b. The landing rules (DND-1317) against a real fixture repo with a stubbed gh.
if /usr/bin/ruby "$here/lead_time_test.rb" >"${TMP}/lt" 2>&1; then
  ok "lead_time_test.rb: landing rules ($(tail -1 "${TMP}/lt"))"
else
  bad "lead_time_test.rb: landing rules" "$(cat "${TMP}/lt")"
fi

# 1c. The Notion start lookup's retry policy (DND-1519) over a fake Notion on
#     loopback. LC_ALL=C pins the read of a raw UTF-8 body (DND-1054).
if LC_ALL=C /usr/bin/ruby "$here/notion_retry_test.rb" >"${TMP}/nr" 2>&1; then
  ok "notion_retry_test.rb: Notion retry ($(tail -1 "${TMP}/nr"))"
else
  bad "notion_retry_test.rb: Notion retry" "$(cat "${TMP}/nr")"
fi

# 2a. Refused: exit 1 (lead-time's documented usage code; 2 already means "PR
#     not found"), names the flag, carries Fix:, stdout empty, and the repo
#     was never consulted.
refused() { # refused <label> <needle> <args...>
  local label="$1" needle="$2"; shift 2
  run "$@"
  if [ "${CODE}" -eq 1 ] && grep -qF -- "${needle}" <<<"${ERR}" && grep -q 'Fix:' <<<"${ERR}" \
     && [ -z "${OUT}" ] && ! grep -q 'not a git worktree' <<<"${ERR}"; then
    ok "${label}"
  else
    bad "${label}" "code=${CODE} err=$(head -c 240 <<<"${ERR}")"
  fi
}
refused "a valueless --slow is refused (was: silently no filter)" "--slow" --repo "${NOREPO}" --since "${SINCE}" --slow
refused "--slow swallowing the next flag is refused" "--slow" --repo "${NOREPO}" --since "${SINCE}" --slow --json
refused "a non-integer --slow is refused (was: silently no filter)" "--slow" --repo "${NOREPO}" --since "${SINCE}" --slow 1.5
refused "a valueless --since is refused" "--since" --repo "${NOREPO}" --since
refused "a valueless --repo is refused" "--repo" --since "${SINCE}" --repo
refused "--pr with --since is refused (--since was silently ignored)" "--since" --repo "${NOREPO}" --pr 1 --since "${SINCE}"
refused "--pr with --mr is refused (which wins is a guess)" "--mr" --repo "${NOREPO}" --pr 1 --mr 2
refused "a repeated --repo is refused" "--repo" --repo /tmp --repo "${NOREPO}" --pr 1
refused "--since=VALUE is refused" "--since=" --repo "${NOREPO}" --since="${SINCE}"
refused "an unknown flag is refused" "--jsn" --repo "${NOREPO}" --pr 1 --jsn
refused "--self-test beside another flag is refused" "--self-test" --self-test --json

# 2b. Accepted: every in-repo shape reaches the repo check (so it parsed).
accepted() { # accepted <label> <args...>
  local label="$1"; shift
  run "$@"
  if [ "${CODE}" -eq 1 ] && grep -q 'not a git worktree' <<<"${ERR}"; then
    ok "${label}"
  else
    bad "${label}" "code=${CODE} err=$(head -c 240 <<<"${ERR}")"
  fi
}
accepted "the watch scan's --since --slow --json shape still parses" --repo "${NOREPO}" --since "${SINCE}" --slow 90 --json
accepted "--repo --mr still parses" --repo "${NOREPO}" --mr 1188
accepted "--repo --pr --json still parses" --repo "${NOREPO}" --pr 14 --json
accepted "flag order does not matter" --json --slow 90 --since "${SINCE}" --repo "${NOREPO}"

refused "a valueless --meta is refused, naming the flag" "--meta" --repo "${NOREPO}" --since "${SINCE}" --meta
refused "--meta without --since is refused (it reports a window scan)" "--meta" --repo "${NOREPO}" --pr 1 --meta "${TMP}/m.json"
accepted "--since --slow --json --meta parses" --repo "${NOREPO}" --since "${SINCE}" --slow 90 --json --meta "${TMP}/m.json"

# 2c. DND-1009: a date-only --since is a date. It reaches the repo check with
#     no backtrace (it used to raise Time.xmlschema from the forge scan).
run --repo "${NOREPO}" --since 2026-09-30
if [ "${CODE}" -eq 1 ] && grep -q 'not a git worktree' <<<"${ERR}" && ! grep -qiE 'xmlschema|\.rb:[0-9]+:in' <<<"${ERR}"; then
  ok "a date-only --since parses and stops at the repo check, no backtrace"
else
  bad "a date-only --since parses" "code=${CODE} err=$(head -c 240 <<<"${ERR}")"
fi

# 2c'. The same date-only --since against a GitHub-origin repo, with a `gh` on
#      PATH that fails, so the scan reaches the forge offline. It used to raise
#      a raw Time.xmlschema backtrace there; now the failed probe is SCAN
#      INCOMPLETE (exit 3) with a Fix:, never a crash.
GHREPO="${TMP}/gh-origin-repo"
FAKEBIN="${TMP}/fakebin"
mkdir -p "${FAKEBIN}"
printf '#!/bin/sh\necho "fake gh: offline" >&2\nexit 1\n' >"${FAKEBIN}/gh"
chmod +x "${FAKEBIN}/gh"
fsg_require_stubs "${FAKEBIN}" gh
git init -q "${GHREPO}" && git -C "${GHREPO}" remote add origin https://github.com/example-org/example-repo.git
OUT="$(PATH="${FAKEBIN}:${PATH}" /usr/bin/ruby "$bin" --repo "${GHREPO}" --since 2026-09-30 2>"${TMP}/err" </dev/null)"; CODE=$?
ERR="$(cat "${TMP}/err")"
if [ "${CODE}" -eq 3 ] && grep -q 'SCAN INCOMPLETE' <<<"${ERR}" && grep -q 'Fix:' <<<"${ERR}" \
   && ! grep -qiE 'xmlschema|\.rb:[0-9]+:in' <<<"${ERR}" && [ -z "${OUT}" ]; then
  ok "a date-only --since reaches the forge scan without a backtrace (SCAN INCOMPLETE on an offline gh)"
else
  bad "a date-only --since reaches the forge scan without a backtrace" "code=${CODE} err=$(head -c 300 <<<"${ERR}")"
fi

# 2d. Anything else unparseable is a usage error: exit 1 like every other
#     usage error (DND-1489: it was 2, the code for a missing PR), Fix:, the
#     accepted forms named, and the repo never reached.
for bad_since in yesterday 2026-09-30T22:00:00 2026-02-31; do
  run --repo "${NOREPO}" --since "${bad_since}"
  if [ "${CODE}" -eq 1 ] && grep -q 'Fix:' <<<"${ERR}" && grep -q 'YYYY-MM-DD' <<<"${ERR}" \
     && ! grep -q 'not a git worktree' <<<"${ERR}" && [ -z "${OUT}" ]; then
    ok "--since ${bad_since} is refused (exit 1, Fix:), repo never reached"
  else
    bad "--since ${bad_since} is refused (exit 1)" "code=${CODE} err=$(head -c 240 <<<"${ERR}")"
  fi
done

# 2e. DND-1489: a malformed argument and a legitimate not-found must not share
#     an exit code, or a caller cannot tell them apart. A requested PR the
#     forge reports does not exist is exit 2; a malformed --since is exit 1.
#     The stub answers as the real gh does for a nonexistent PR number.
NFBIN="${TMP}/notfoundbin"
mkdir -p "${NFBIN}"
printf '#!/bin/sh\necho "GraphQL: Could not resolve to a PullRequest with the number of 424242. (repository.pullRequest)" >&2\nexit 1\n' >"${NFBIN}/gh"
chmod +x "${NFBIN}/gh"
fsg_require_stubs "${NFBIN}" gh
PATH="${NFBIN}:${PATH}" /usr/bin/ruby "$bin" --repo "${GHREPO}" --pr 424242 >"${TMP}/pr-out" 2>"${TMP}/pr-err" </dev/null
PR_CODE=$?
run --repo "${GHREPO}" --since nonsense
SINCE_CODE="${CODE}"
if [ "${PR_CODE}" -eq 2 ] && grep -q 'Could not resolve to a PullRequest' "${TMP}/pr-err" \
   && grep -q 'Fix:' "${TMP}/pr-err" && [ ! -s "${TMP}/pr-out" ]; then
  ok "a PR the forge reports does not exist exits 2, with a Fix:"
else
  bad "a PR the forge reports does not exist exits 2" "code=${PR_CODE} err=$(head -c 240 "${TMP}/pr-err")"
fi
if [ "${SINCE_CODE}" -eq 1 ] && [ "${PR_CODE}" -eq 2 ]; then
  ok "a malformed --since (exit ${SINCE_CODE}) and a missing PR (exit ${PR_CODE}) have distinct codes"
else
  bad "a malformed --since exits 1 and a missing PR exits 2" "since=${SINCE_CODE} pr=${PR_CODE}"
fi

# 2f. DND-1510: exit 2 is a request the forge says does not exist; a forge it
#     could not read is exit 3 (could not measure), with a Fix: naming the
#     forge's own error. Before this, every failed facts probe exited 2, so an
#     offline or unauthenticated forge read as a missing PR. Each stub answers
#     as the real CLI does (stderr shapes measured 2026-10-01 with gh 2.x and
#     glab: a nonexistent PR, a nonexistent MR, a nonexistent project).
stub() { # stub <dir> <tool> <stdout> <stderr>: exits 1, printing both
  mkdir -p "$1"
  printf '%s' "$3" >"$1/$2.out"
  printf '%s\n' "$4" >"$1/$2.err"
  printf '#!/bin/sh\ncat "%s"\ncat "%s" >&2\nexit 1\n' "$1/$2.out" "$1/$2.err" >"$1/$2"
  chmod +x "$1/$2"
  fsg_require_stubs "$1" "$2"
}
GLREPO="${TMP}/gl-origin-repo"
git init -q "${GLREPO}" && git -C "${GLREPO}" remote add origin https://gitlab.com/example-group/example-repo.git

pr_case() { # pr_case <label> <want-code> <needle> <repo> <bindir> <flag>
  local label="$1" want="$2" needle="$3" repo="$4" bindir="$5" flag="$6"
  OUT="$(PATH="${bindir}:${PATH}" /usr/bin/ruby "$bin" --repo "${repo}" "${flag}" 424242 2>"${TMP}/err" </dev/null)"
  CODE=$?; ERR="$(cat "${TMP}/err")"
  if [ "${CODE}" -eq "${want}" ] && grep -qF -- "${needle}" <<<"${ERR}" && grep -q 'Fix:' <<<"${ERR}" \
     && ! grep -qiE '\.rb:[0-9]+:in' <<<"${ERR}" && [ -z "${OUT}" ]; then
    ok "${label}"
  else
    bad "${label}" "want=${want} code=${CODE} err=$(head -c 300 <<<"${ERR}")"
  fi
}

stub "${TMP}/gh-offline" gh "" "error connecting to api.github.com"
stub "${TMP}/gh-401" gh "" "HTTP 401: Bad credentials (https://api.github.com/graphql)"
stub "${TMP}/gh-norepo" gh "" "GraphQL: Could not resolve to a Repository with the name 'example-org/example-repo'. (repository)"
mkdir -p "${TMP}/gh-garbage"
printf '#!/bin/sh\necho "not json"\nexit 0\n' >"${TMP}/gh-garbage/gh"
chmod +x "${TMP}/gh-garbage/gh"
fsg_require_stubs "${TMP}/gh-garbage" gh
stub "${TMP}/gl-nomr" glab '{"message":"404 Not found"}' "glab: 404 Not found (HTTP 404)"
stub "${TMP}/gl-noproj" glab '{"message":"404 Project Not Found"}' "glab: 404 Project Not Found (HTTP 404)"
stub "${TMP}/gl-401" glab '{"message":"401 Unauthorized"}' "glab: 401 Unauthorized (HTTP 401)"

pr_case "gh offline on --pr is exit 3 naming the forge error (was 2, read as not found)" 3 \
  "error connecting to api.github.com" "${GHREPO}" "${TMP}/gh-offline" --pr
pr_case "gh unauthenticated on --pr is exit 3 naming the forge error" 3 \
  "HTTP 401: Bad credentials" "${GHREPO}" "${TMP}/gh-401" --pr
pr_case "gh repository not found is exit 3, not a missing PR" 3 \
  "Could not resolve to a Repository" "${GHREPO}" "${TMP}/gh-norepo" --pr
pr_case "gh output that is not JSON is exit 3" 3 \
  "unparseable output" "${GHREPO}" "${TMP}/gh-garbage" --pr
pr_case "gh PR not found stays exit 2" 2 \
  "Could not resolve to a PullRequest" "${GHREPO}" "${NFBIN}" --pr
pr_case "glab MR not found (404 Not found) is exit 2" 2 \
  "404 Not found" "${GLREPO}" "${TMP}/gl-nomr" --mr
pr_case "glab project not found is exit 3, not a missing MR" 3 \
  "404 Project Not Found" "${GLREPO}" "${TMP}/gl-noproj" --mr
pr_case "glab unauthenticated on --mr is exit 3 naming the forge error" 3 \
  "401 Unauthorized" "${GLREPO}" "${TMP}/gl-401" --mr

# The two outcomes must differ, and the tool error must say it measured
# nothing rather than that the request is missing.
PATH="${TMP}/gh-offline:${PATH}" /usr/bin/ruby "$bin" --repo "${GHREPO}" --pr 424242 >/dev/null 2>"${TMP}/off-err" </dev/null
OFF_CODE=$?
if [ "${OFF_CODE}" -ne "${PR_CODE}" ] && grep -q 'could not measure' "${TMP}/off-err" \
   && ! grep -q 'not found' "${TMP}/off-err"; then
  ok "an offline forge (exit ${OFF_CODE}) and a missing PR (exit ${PR_CODE}) have distinct codes and words"
else
  bad "an offline forge and a missing PR are told apart" "offline=${OFF_CODE} missing=${PR_CODE} err=$(head -c 240 "${TMP}/off-err")"
fi

# A missing PR gets exactly one Fix:, the one about the number. A generic auth
# Fix: printed first (run_json's, before DND-1510) sent that reader to auth.
PATH="${NFBIN}:${PATH}" /usr/bin/ruby "$bin" --repo "${GHREPO}" --pr 424242 >/dev/null 2>"${TMP}/nf-err" </dev/null
NF_FIXES="$(grep -c 'Fix:' "${TMP}/nf-err")"
if [ "${NF_FIXES}" -eq 1 ] && grep -q 'Fix: check the PR/MR number' "${TMP}/nf-err" \
   && ! grep -q 'auth status' "${TMP}/nf-err"; then
  ok "a missing PR prints one Fix:, about the number, not about auth"
else
  bad "a missing PR prints one Fix:, about the number" "fixes=${NF_FIXES} err=$(head -c 300 "${TMP}/nf-err")"
fi

run --help --bogus
[ "${CODE}" -eq 0 ] && grep -q 'Usage:' <<<"${OUT}" \
  && ok "--help is still answered first (stdout, exit 0)" \
  || bad "--help is answered first" "code=${CODE} out=$(head -c 160 <<<"${OUT}")"

if fsg_verify; then ok "no gh/glab call fell through past its stub (DND-1647)"
else bad "no gh/glab call fell through past its stub (DND-1647)" "see the forge-stub-guard FAIL above"; fi

printf '\nlead-time self-test: %d passed, %d failed\n' "${PASS}" "${FAIL}"
if [ "${FAIL}" -ne 0 ]; then
  echo "Fix: make ai/bin/lead-time parse argv with ai/lib/strict_argv.rb before it touches the repo: an unknown flag, a value flag with no value (or a non-integer --slow), --flag=VALUE, a repeated flag, --pr with --mr or --since, or --self-test beside another flag must exit 1 (usage) naming the flag with a Fix: line; a requested PR/MR the forge says does not exist must exit 2, and one the forge could not be read for (offline, auth, a missing repository or project, unparseable output) must exit 3 with a Fix: naming the forge error (LeadTime.lookup_miss, report_lookup_miss); keep the pure-logic --self-test green." >&2
  exit 1
fi
exit 0
