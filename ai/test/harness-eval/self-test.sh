#!/usr/bin/env bash
# CLI-level argv suite for ai/bin/harness-eval (DND-526) — discovered and run
# by ai/bin/harness-gate.
#
# harness-eval's default action runs the corpus and WRITES
# ai/eval/scorecard.json; --update-baseline writes ai/eval/baseline.json. A
# typo used to fall through to that default. The tool's own --self-test pins
# parse_cli in-process; this suite pins the ENTRY POINT: it runs the real CLI,
# so reverting the dispatch to ARGV.include? turns it red.
#
# It never runs harness-eval against this checkout. Each case runs a COPY of
# the tool, ai/lib and ai/eval in a mktemp -d, with HOME sandboxed. The copy
# has no hooks or guard bins, so a fall-through corpus run is fast (every case
# reads "not found") and still writes the scorecard the suite looks for.
#
# Run: bash ai/test/harness-eval/self-test.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/../../.." && pwd)"

PASS=0; FAIL=0
ok()  { printf '  ok    %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  FAIL  %s\n        %s\n' "$1" "$2"; FAIL=$((FAIL+1)); }

# Resolve the real interpreter BEFORE any case swaps HOME: a version-manager
# shim (asdf) reads its config from HOME and exits 126 under a sandboxed one.
RUBY="$(ruby -e 'print RbConfig.ruby')" || {
  echo "harness-eval CLI self-test: FAIL — could not resolve the ruby interpreter" >&2
  echo "Fix: put a working ruby on PATH." >&2
  exit 1
}

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

mk_copy() { # mk_copy <dir>
  local d="$1"
  mkdir -p "${d}/ai/bin" "${d}/ai/eval" "${d}/home"
  cp "${REPO}/ai/bin/harness-eval" "${d}/ai/bin/harness-eval"
  cp -R "${REPO}/ai/lib" "${d}/ai/lib"
  cp -R "${REPO}/ai/eval/fixtures" "${d}/ai/eval/fixtures"
  cp "${REPO}/ai/eval/baseline.json" "${d}/ai/eval/baseline.json"
  rm -f "${d}/ai/eval/scorecard.json"
}

OUT=""; ERR=""; CODE=0
run() { # run <sandbox> <args...>
  local d="$1"; shift
  OUT="$(HOME="${d}/home" "${RUBY}" "${d}/ai/bin/harness-eval" "$@" 2>"${TMP}/err" </dev/null)"; CODE=$?
  ERR="$(cat "${TMP}/err")"
}

# refused <label> <needle> <args...>: exit 2, names <needle>, carries Fix:,
# stdout empty, no scorecard written, baseline byte-identical.
refused() {
  local label="$1" needle="$2"; shift 2
  local d="${TMP}/case-$((PASS+FAIL))"
  mk_copy "${d}"
  run "${d}" "$@"
  local wrote="no"
  [ -e "${d}/ai/eval/scorecard.json" ] && wrote="scorecard.json"
  cmp -s "${REPO}/ai/eval/baseline.json" "${d}/ai/eval/baseline.json" || wrote="${wrote}+baseline.json"
  if [ "${CODE}" -eq 2 ] && grep -qF -- "${needle}" <<<"${ERR}" && grep -q 'Fix:' <<<"${ERR}" \
     && [ -z "${OUT}" ] && [ "${wrote}" = "no" ]; then
    ok "${label}"
  else
    bad "${label}" "code=${CODE} wrote=${wrote} err=$(head -c 200 <<<"${ERR}")"
  fi
}

refused "a typo of --update-baseline exits 2 and writes no scorecard" "--update-baselin" --update-baselin
refused "a stray word exits 2 and writes no scorecard" "stray" stray
refused "--update-baseline=1 exits 2 and writes nothing" "--update-baseline=" --update-baseline=1
refused "--update-baseline twice exits 2 and writes nothing" "--update-baseline" --update-baseline --update-baseline
refused "--self-test with --update-baseline exits 2 and writes nothing" "--update-baseline" --self-test --update-baseline

# Accepted shapes still reach their mode (the corpus run writes the scorecard).
D="${TMP}/accept-default"; mk_copy "${D}"
run "${D}"
if [ -e "${D}/ai/eval/scorecard.json" ] && grep -q 'cases pass' <<<"${OUT}"; then
  ok "no arguments still runs the corpus and writes the scorecard"
else
  bad "no arguments still runs the corpus" "code=${CODE} out=$(head -c 160 <<<"${OUT}")"
fi

D="${TMP}/help"; mk_copy "${D}"
run "${D}" --help --bogus
if [ "${CODE}" -eq 0 ] && grep -q 'Usage:' <<<"${OUT}" && [ ! -e "${D}/ai/eval/scorecard.json" ]; then
  ok "--help is still answered first (stdout, exit 0, writes nothing)"
else
  bad "--help is answered first" "code=${CODE} out=$(head -c 160 <<<"${OUT}")"
fi

printf '\nharness-eval CLI self-test: %d passed, %d failed\n' "${PASS}" "${FAIL}"
if [ "${FAIL}" -ne 0 ]; then
  echo "Fix: ai/bin/harness-eval must dispatch on parse_cli(ARGV) (ai/lib/strict_argv.rb), never on ARGV.include?: an unknown flag, a stray word, --flag=VALUE, a repeated flag or two modes must exit 2 with a Fix: line BEFORE the corpus runs, so no scorecard or baseline is written." >&2
  exit 1
fi
exit 0
