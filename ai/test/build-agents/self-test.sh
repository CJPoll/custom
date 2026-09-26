#!/usr/bin/env bash
# Self-test for ai/bin/build-agents argv handling (DND-526) — discovered and
# run by ai/bin/harness-gate.
#
# build-agents' DEFAULT action rewrites every ai/agents/athena-*.md. A typo of
# `--check` used to fall through to that default, so an unknown flag was a
# silent mutation of the harness. This suite pins the refusal: every argument
# must be a declared flag, and a refused command line writes nothing.
#
# It NEVER runs build-agents against this checkout. Each case runs a COPY of
# the tool, ai/lib, ai/agents and ai/blocks inside a mktemp -d, with HOME
# pointed into the sandbox so a stray --install could only reach the sandbox.
# One generated .md in the copy is made stale on purpose: a run that falls
# through to the default rewrites it, and the suite sees the rewrite.
#
# Run: bash ai/test/build-agents/self-test.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/../../.." && pwd)"

PASS=0; FAIL=0
ok()  { printf '  ok    %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  FAIL  %s\n        %s\n' "$1" "$2"; FAIL=$((FAIL+1)); }

# Resolve the real interpreter BEFORE any case swaps HOME: a version-manager
# shim (asdf) reads its config from HOME and exits 126 under a sandboxed one.
RUBY="$(ruby -e 'print RbConfig.ruby')" || {
  echo "build-agents self-test: FAIL — could not resolve the ruby interpreter" >&2
  echo "Fix: put a working ruby on PATH." >&2
  exit 1
}

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

# A fresh sandbox copy per case, so one case's write cannot mask another's.
# mk_copy <dir>: copy the inputs build-agents reads, then make one render stale.
STALE_NAME=""
mk_copy() {
  local d="$1"
  mkdir -p "${d}/ai/bin" "${d}/home"
  cp "${REPO}/ai/bin/build-agents" "${d}/ai/bin/build-agents"
  cp -R "${REPO}/ai/lib" "${d}/ai/lib"
  cp -R "${REPO}/ai/agents" "${d}/ai/agents"
  cp -R "${REPO}/ai/blocks" "${d}/ai/blocks"
  local first
  first="$(find "${d}/ai/agents" -maxdepth 1 -name 'athena-*.md' -type f | sort | head -n 1)"
  if [ -z "${first}" ]; then
    echo "build-agents self-test: FAIL — no rendered ai/agents/athena-*.md to copy under ${REPO}" >&2
    echo "Fix: run this suite from a checkout whose ai/agents holds the rendered definitions." >&2
    exit 1
  fi
  STALE_NAME="$(basename "${first}")"
  printf '\nSTALE-MARKER-DND-526\n' >> "${first}"
}

OUT=""; ERR=""; CODE=0
run() { # run <sandbox> <args...>
  local d="$1"; shift
  OUT="$(HOME="${d}/home" "${RUBY}" "${d}/ai/bin/build-agents" "$@" 2>"${TMP}/err" </dev/null)"; CODE=$?
  ERR="$(cat "${TMP}/err")"
}

still_stale() { grep -q 'STALE-MARKER-DND-526' "$1/ai/agents/${STALE_NAME}"; }
nothing_installed() { [ -z "$(find "$1/home" -mindepth 1 -print -quit)" ]; }

# refused <label> <needle> <args...>: exit 2, names <needle>, carries Fix:,
# prints nothing on stdout, rewrites nothing and installs nothing.
refused() {
  local label="$1" needle="$2"; shift 2
  local d="${TMP}/case-$((PASS+FAIL))"
  mk_copy "${d}"
  run "${d}" "$@"
  if [ "${CODE}" -eq 2 ] && grep -qF -- "${needle}" <<<"${ERR}" && grep -q 'Fix:' <<<"${ERR}" \
     && [ -z "${OUT}" ] && still_stale "${d}" && nothing_installed "${d}"; then
    ok "${label}"
  else
    local wrote="no"; still_stale "${d}" || wrote="YES (${STALE_NAME} rewritten)"
    bad "${label}" "code=${CODE} wrote=${wrote} out=$(head -c 160 <<<"${OUT}") err=$(head -c 200 <<<"${ERR}")"
  fi
}

# --- refusals: each of these used to run the rewriting default -----------
refused "a typo of --check (--chek) exits 2 and rewrites nothing" "--chek" --chek
refused "a typo of --install (--instal) exits 2 and rewrites nothing" "--instal" --instal
refused "a stray positional word exits 2 and rewrites nothing" "stray" stray
refused "--check=VALUE is refused, not read as the default" "--check=yes" --check=yes
refused "--check --install together is refused (which mode wins is a guess)" "--install" --check --install
refused "--install --check (reversed) is refused the same way" "--install" --install --check
refused "a valid flag given twice is refused" "--check" --check --check
refused "a single-dash typo (-check) exits 2" "-check" -check

# --- accepted invocations (every in-repo shape) still behave --------------
D="${TMP}/accept-check"; mk_copy "${D}"
run "${D}" --check
if [ "${CODE}" -eq 1 ] && grep -qF "${STALE_NAME%.md}" <<<"${ERR}" && still_stale "${D}"; then
  ok "--check on a stale render exits 1 naming it, and writes nothing"
else
  bad "--check on a stale render exits 1 and writes nothing" "code=${CODE} err=$(head -c 200 <<<"${ERR}")"
fi

D="${TMP}/accept-default"; mk_copy "${D}"
run "${D}"
if [ "${CODE}" -eq 0 ] && ! still_stale "${D}"; then
  ok "no arguments still builds (rewrites the stale render, exit 0)"
else
  bad "no arguments still builds" "code=${CODE} err=$(head -c 200 <<<"${ERR}")"
fi
run "${D}" --check
[ "${CODE}" -eq 0 ] \
  && ok "--check on a fresh render exits 0" \
  || bad "--check on a fresh render exits 0" "code=${CODE} err=$(head -c 200 <<<"${ERR}")"

D="${TMP}/accept-install"; mk_copy "${D}"
run "${D}" --install
if [ "${CODE}" -eq 0 ] && [ -f "${D}/home/.claude/agents/${STALE_NAME}" ]; then
  ok "--install still builds and installs (into the sandboxed HOME)"
else
  bad "--install still builds and installs" "code=${CODE} err=$(head -c 200 <<<"${ERR}")"
fi

for h in --help -h; do
  D="${TMP}/help${h}"; mk_copy "${D}"
  run "${D}" "${h}" --bogus
  if [ "${CODE}" -eq 0 ] && grep -q 'Usage:' <<<"${OUT}" && still_stale "${D}"; then
    ok "${h} is still answered first (stdout, exit 0, writes nothing), even beside a bad flag"
  else
    bad "${h} is answered first" "code=${CODE} out=$(head -c 160 <<<"${OUT}")"
  fi
done

printf '\nbuild-agents self-test: %d passed, %d failed\n' "${PASS}" "${FAIL}"
if [ "${FAIL}" -ne 0 ]; then
  echo "Fix: make ai/bin/build-agents parse its argv with ai/lib/strict_argv.rb (CLI_SPEC + parse_cli) BEFORE any build or write: an unknown flag, a stray word, --flag=VALUE, a repeated flag, or --check with --install must exit 2 with a Fix: line and write nothing; --help/-h stays answered first." >&2
  exit 1
fi
exit 0
