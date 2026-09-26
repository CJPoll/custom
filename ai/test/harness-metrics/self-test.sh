#!/usr/bin/env bash
# CLI-level argv suite for ai/bin/harness-metrics (DND-526) — discovered and
# run by ai/bin/harness-gate.
#
# harness-metrics' default action parses every session under
# ~/.claude/projects and WRITES ai/telemetry/metrics.json. A typo such as
# `--sessoin x` used to fall through to that default. The tool's own
# --self-test pins parse_cli in-process; this suite pins the ENTRY POINT: it
# runs the real CLI, so reverting the dispatch to ARGV.include?/ARGV.index
# turns it red.
#
# It never runs harness-metrics against this checkout or the real session
# store. Each case runs a COPY of the tool and ai/lib in a mktemp -d, with HOME
# pointed at a sandbox holding one session file, so a fall-through is visible
# as a metrics.json written in the copy.
#
# Run: bash ai/test/harness-metrics/self-test.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/../../.." && pwd)"

PASS=0; FAIL=0
ok()  { printf '  ok    %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  FAIL  %s\n        %s\n' "$1" "$2"; FAIL=$((FAIL+1)); }

# Resolve the real interpreter BEFORE any case swaps HOME: a version-manager
# shim (asdf) reads its config from HOME and exits 126 under a sandboxed one.
RUBY="$(ruby -e 'print RbConfig.ruby')" || {
  echo "harness-metrics CLI self-test: FAIL — could not resolve the ruby interpreter" >&2
  echo "Fix: put a working ruby on PATH." >&2
  exit 1
}

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

mk_copy() { # mk_copy <dir>
  local d="$1"
  mkdir -p "${d}/ai/bin" "${d}/home/.claude/projects/p"
  cp "${REPO}/ai/bin/harness-metrics" "${d}/ai/bin/harness-metrics"
  cp -R "${REPO}/ai/lib" "${d}/ai/lib"
  printf '%s\n' '{"type":"user","timestamp":"2026-09-26T00:00:00Z","message":{"role":"user","content":"hi"}}' \
    > "${d}/home/.claude/projects/p/s.jsonl"
}

OUT=""; ERR=""; CODE=0
run() { # run <sandbox> <args...>
  local d="$1"; shift
  OUT="$(HOME="${d}/home" "${RUBY}" "${d}/ai/bin/harness-metrics" "$@" 2>"${TMP}/err" </dev/null)"; CODE=$?
  ERR="$(cat "${TMP}/err")"
}
wrote_metrics() { [ -e "$1/ai/telemetry/metrics.json" ]; }

# refused <label> <needle> <args...>: exit 2, names <needle>, carries Fix:,
# stdout empty, no metrics.json written.
refused() {
  local label="$1" needle="$2"; shift 2
  local d="${TMP}/case-$((PASS+FAIL))"
  mk_copy "${d}"
  run "${d}" "$@"
  if [ "${CODE}" -eq 2 ] && grep -qF -- "${needle}" <<<"${ERR}" && grep -q 'Fix:' <<<"${ERR}" \
     && [ -z "${OUT}" ] && ! wrote_metrics "${d}"; then
    ok "${label}"
  else
    local w="no"; wrote_metrics "${d}" && w="YES (metrics.json)"
    bad "${label}" "code=${CODE} wrote=${w} err=$(head -c 200 <<<"${ERR}")"
  fi
}

refused "a typo of --session (--sessoin x) exits 2 and writes no metrics" "--sessoin" --sessoin x
refused "a typo of --json exits 2 and writes no metrics" "--jsn" --jsn
refused "a valueless --dir exits 2 and writes no metrics" "--dir needs a value" --dir
refused "--dir swallowing the next flag exits 2" "--dir needs a value" --dir --json
refused "--session with --dir exits 2 (--dir was silently ignored)" "--dir" --session x --dir y
refused "a stray word exits 2 and writes no metrics" "stray" stray

# Accepted: the default still reports and writes metrics.json in the copy.
D="${TMP}/accept-default"; mk_copy "${D}"
run "${D}" --json
if [ "${CODE}" -eq 0 ] && wrote_metrics "${D}" && grep -q '"records"' <<<"${OUT}"; then
  ok "--json still reports and writes metrics.json"
else
  bad "--json still reports" "code=${CODE} err=$(head -c 200 <<<"${ERR}")"
fi

D="${TMP}/help"; mk_copy "${D}"
run "${D}" --help --bogus
if [ "${CODE}" -eq 0 ] && grep -q 'Usage:' <<<"${OUT}" && ! wrote_metrics "${D}"; then
  ok "--help is still answered first (stdout, exit 0, writes nothing)"
else
  bad "--help is answered first" "code=${CODE} out=$(head -c 160 <<<"${OUT}")"
fi

printf '\nharness-metrics CLI self-test: %d passed, %d failed\n' "${PASS}" "${FAIL}"
if [ "${FAIL}" -ne 0 ]; then
  echo "Fix: ai/bin/harness-metrics must dispatch on parse_cli(ARGV) (ai/lib/strict_argv.rb), never on ARGV.include?/ARGV.index: an unknown flag, a stray word, a valueless value flag, --flag=VALUE, a repeated flag or --session with --dir must exit 2 with a Fix: line BEFORE any session is read, so no metrics.json is written." >&2
  exit 1
fi
exit 0
