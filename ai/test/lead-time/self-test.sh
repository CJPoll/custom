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
NOREPO="${TMP}/no-such-repo"
SINCE="2026-09-19T00:00:00Z"

OUT=""; ERR=""; CODE=0
run() { OUT="$(ruby "$bin" "$@" 2>"${TMP}/err" </dev/null)"; CODE=$?; ERR="$(cat "${TMP}/err")"; }

# 1. The pure-logic suite.
if ruby "$bin" --self-test >"${TMP}/st" 2>&1; then
  ok "lead-time --self-test passes"
else
  bad "lead-time --self-test passes" "$(tail -5 "${TMP}/st")"
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
accepted "the shipwright's --since --slow --json shape still parses" --repo "${NOREPO}" --since "${SINCE}" --slow 90 --json
accepted "--repo --mr still parses" --repo "${NOREPO}" --mr 1188
accepted "--repo --pr --json still parses" --repo "${NOREPO}" --pr 14 --json
accepted "flag order does not matter" --json --slow 90 --since "${SINCE}" --repo "${NOREPO}"

run --help --bogus
[ "${CODE}" -eq 0 ] && grep -q 'Usage:' <<<"${OUT}" \
  && ok "--help is still answered first (stdout, exit 0)" \
  || bad "--help is answered first" "code=${CODE} out=$(head -c 160 <<<"${OUT}")"

printf '\nlead-time self-test: %d passed, %d failed\n' "${PASS}" "${FAIL}"
if [ "${FAIL}" -ne 0 ]; then
  echo "Fix: make ai/bin/lead-time parse argv with ai/lib/strict_argv.rb before it touches the repo: an unknown flag, a value flag with no value (or a non-integer --slow), --flag=VALUE, a repeated flag, --pr with --mr or --since, or --self-test beside another flag must exit 1 (usage) naming the flag with a Fix: line; keep the pure-logic --self-test green." >&2
  exit 1
fi
exit 0
