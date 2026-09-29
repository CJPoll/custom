#!/usr/bin/env bash
# CLI-level argv suite for the DND-813 strict-argv sweep. Discovered and run by
# harness-gate.
#
# The class (~/dev/custom/ai/CLAUDE.md -> "A failed lookup must never look like
# an empty one", applied to a command line): an argument a tool does not
# recognise must be REFUSED, never dropped. Three shapes of it, each measured on
# these tools before this sweep:
#   * an unknown flag or stray word is ignored and the DEFAULT runs
#     (`check-agent-size --self-tset` ran the live check and exited 0;
#     `forge-preflight --chek` ran its default, which mints a GitHub App token);
#   * a value flag with no value swallows the next argument as its value
#     (`check-tool-risk --class-of --json` printed the class of "--json");
#   * a flag given twice silently keeps one of the two values.
#
# Every case runs the REAL entry point, not a parse function: a DND-526 critic
# round blocked on argv tests that stayed green with the entry-point wiring
# reverted. A refused case asserts the tool's usage exit (2), a stderr that
# names the offending argument and carries `Fix:`, and an EMPTY stdout (a tool
# that fell through to its default prints its result there). Where a
# fall-through would touch the outside world, a seam points it at a stub that
# records the call, and the case asserts the stub was never called.
#
# Sandboxed: HOME, XDG_STATE_HOME, the inbox root and client config, and the
# test-slot pool all live in a mktemp -d; gh/glab on PATH are stubs that fail.
# No network is reachable from a fall-through: the fleet tools find no server
# config and the forge tools find only stubs.
#
# Run against another tree with STRICT_ARGV_CLI_AI=/path/to/ai (the BEFORE
# evidence in the DND-813 commits ran this file against origin/main's ai/).
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AI="${STRICT_ARGV_CLI_AI:-$(cd "${HERE}/../.." && pwd)}"
BIN="${AI}/bin"

TMP="$(mktemp -d)"; trap 'rm -rf "${TMP}"' EXIT
PASS=0; FAIL=0
ok()  { printf '  ok    %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  FAIL  %s\n        %s\n' "$1" "$2"; FAIL=$((FAIL+1)); }

# --- sandbox ------------------------------------------------------------------
# Resolve the real ruby BEFORE HOME moves: a version-manager shim (asdf) reads
# its config from HOME, so under the sandboxed HOME it exits 126 and every Ruby
# tool below would "fail" for a reason that has nothing to do with argv.
REAL_RUBY_DIR="$(dirname "$(ruby -e 'print RbConfig.ruby')")" || {
  echo "strict-argv CLI suite: FAIL -- no working ruby on PATH"
  echo "  Fix: install ruby; this suite does not skip."; exit 1; }
mkdir -p "${TMP}/home" "${TMP}/state" "${TMP}/inbox" "${TMP}/stubs" "${TMP}/pool"
chmod 700 "${TMP}/pool"
export HOME="${TMP}/home"
export XDG_STATE_HOME="${TMP}/state"
export ATHENA_INBOX_ROOT="${TMP}/inbox"
export ATHENA_INBOX_CLIENT_CONFIG="${TMP}/no-client-config.json"
export FLEET_CLAUDE_JSON="${TMP}/no-claude.json"
export ATHENA_TEST_SLOT_DIR="${TMP}/pool"
export GIT_CONFIG_NOSYSTEM=1
export GIT_CONFIG_GLOBAL="${TMP}/gitconfig"
: > "${GIT_CONFIG_GLOBAL}"
unset CLAUDE_CODE_SESSION_ID ATHENA_TEST_SLOT_HELD BLAST_RADIUS_FIXTURE_MANIFEST

CALLS="${TMP}/stub-calls"
: > "${CALLS}"
for s in gh glab gh-athena glab-athena; do
  cat > "${TMP}/stubs/${s}" <<EOF
#!/bin/sh
echo "${s} \$*" >> "${CALLS}"
echo "stub ${s}: no network in this suite" >&2
exit 1
EOF
  chmod +x "${TMP}/stubs/${s}"
done
export PATH="${TMP}/stubs:${REAL_RUBY_DIR}:${PATH}"
export GH_ATHENA_BIN="${TMP}/stubs/gh-athena"
export GLAB_ATHENA_BIN="${TMP}/stubs/glab-athena"
export PUSH_ACTOR_CHECK_GH="${TMP}/stubs/gh"
export PUSH_ACTOR_CHECK_GLAB="${TMP}/stubs/glab"
export PUSH_ACTOR_CHECK_GIT="${TMP}/stubs/gh"

# A throwaway repo with a github.com remote, so forge-preflight's default (were
# it reached) resolves a managed forge and calls the gh-athena stub.
REPO="${TMP}/repo"
git init -q -b main "${REPO}"
git -C "${REPO}" -c user.email=t@t -c user.name=t commit -q --allow-empty -m base
git -C "${REPO}" remote add origin https://github.com/example/example.git
BASE_SHA="$(git -C "${REPO}" rev-parse HEAD)"
echo x > "${REPO}/README"
git -C "${REPO}" add README
git -C "${REPO}" -c user.email=t@t -c user.name=t commit -q -m head
HEAD_SHA="$(git -C "${REPO}" rev-parse HEAD)"
cp "${AI}/blast-radius/surfaces.json" "${TMP}/m.json"

# refused NAME NEEDLE TOOL ARGS... -- run TOOL (a path under ai/bin) from
# ${REPO} and assert the usage refusal. NEEDLE must appear in stderr.
refused() {
  local name="$1" needle="$2" tool="$3"; shift 3
  : > "${CALLS}"
  local out err rc
  out="$(cd "${REPO}" && timeout 60 "${BIN}/${tool}" "$@" 2>"${TMP}/err" </dev/null)"; rc=$?
  err="$(cat "${TMP}/err")"
  local why=""
  [ "${rc}" -eq 2 ] || why="exit=${rc} (want 2)"
  case "${err}" in *"${needle}"*) ;; *) why="${why:+${why}; }stderr does not name ${needle}" ;; esac
  case "${err}" in *"Fix:"*) ;; *) why="${why:+${why}; }no Fix: line" ;; esac
  [ -z "${out}" ] || why="${why:+${why}; }stdout not empty (fell through?): $(printf '%s' "${out}" | head -c 160 | tr '\n' ' ')"
  [ ! -s "${CALLS}" ] || why="${why:+${why}; }a forge stub was called: $(head -c 160 "${CALLS}" | tr '\n' ' ')"
  if [ -z "${why}" ]; then ok "${name}"; else bad "${name}" "${why} | err=$(printf '%s' "${err}" | head -c 200 | tr '\n' ' ')"; fi
}

# accepted NAME WANT_RC TOOL ARGS... -- a valid in-repo invocation still runs.
accepted() {
  local name="$1" want="$2" tool="$3"; shift 3
  local out rc
  out="$(cd "${REPO}" && timeout 120 "${BIN}/${tool}" "$@" 2>"${TMP}/err" </dev/null)"; rc=$?
  if [ "${rc}" -eq "${want}" ]; then ok "${name}"; else bad "${name}" "exit=${rc} (want ${want}) out=$(printf '%s' "${out}" | head -c 160) err=$(head -c 200 "${TMP}/err")"; fi
}

echo "strict-argv CLI suite (tools under ${BIN})"

# --- Ruby checks: unknown / stray / repeated ------------------------------------
for t in check-agent-size check-bin-help check-generic-skills check-pipefail-grep check-ruby-floor check-guard-messages check-hooks-registered check-tool-risk; do
  refused "${t}: a typo of --self-test is refused, not run as the live check" "--self-tset" "${t}" --self-tset
  refused "${t}: a stray word is refused" "stray" "${t}" stray
  refused "${t}: --self-test twice is refused" "--self-test given more than once" "${t}" --self-test --self-test
done

# check-guard-messages --root
refused "check-guard-messages: a valueless --root is refused" "--root needs a value" check-guard-messages --root
refused "check-guard-messages: --root does not swallow --self-test" "--root needs a value" check-guard-messages --root --self-test
refused "check-guard-messages: --root twice is refused" "--root given more than once" check-guard-messages --root "${REPO}" --root "${REPO}"
refused "check-guard-messages: --root with --self-test is refused" "--self-test" check-guard-messages --self-test --root "${REPO}"

# check-hooks-registered --norm
refused "check-hooks-registered: a valueless --norm is refused, not normalised as the empty string" "--norm needs a value" check-hooks-registered --norm
refused "check-hooks-registered: --norm does not swallow --self-test" "--norm needs a value" check-hooks-registered --norm --self-test
refused "check-hooks-registered: --norm with --self-test is refused" "--norm" check-hooks-registered --norm /x --self-test
accepted "check-hooks-registered: --norm PATH still prints its form" 0 check-hooks-registered --norm /nonexistent/dir/x.sh

# check-tool-risk modes
refused "check-tool-risk: a typo of --json is refused, not run as text mode" "--jsn" check-tool-risk --jsn
refused "check-tool-risk: --class-of does not swallow --json" "--class-of needs a value" check-tool-risk --class-of --json
refused "check-tool-risk: a valueless --class-of is refused" "--class-of needs a value" check-tool-risk --class-of
refused "check-tool-risk: a valueless --root is refused" "--root needs a value" check-tool-risk --root
refused "check-tool-risk: --json with --root is refused (json ignores --root)" "--root" check-tool-risk --json --root "${REPO}"
refused "check-tool-risk: --class-of with --json is refused" "--class-of" check-tool-risk --class-of Bash --json
refused "check-tool-risk: --class-of twice is refused" "--class-of given more than once" check-tool-risk --class-of Bash --class-of Read
accepted "check-tool-risk: --class-of TOOL still answers" 0 check-tool-risk --class-of Bash
accepted "check-tool-risk: --json (workflow-phase-guard's call) still answers" 0 check-tool-risk --json

# --- blast-radius value flags ----------------------------------------------------
refused "blast-radius: a trailing valueless --repo is refused (was a TypeError)" "--repo needs a value" blast-radius --base "${BASE_SHA}" --head "${HEAD_SHA}" --repo
refused "blast-radius: --base does not swallow --head" "--base needs a value" blast-radius --base --head "${HEAD_SHA}"
refused "blast-radius: --base twice is refused (was last-wins)" "--base given more than once" blast-radius --base "${BASE_SHA}" --base "${BASE_SHA}" --head "${HEAD_SHA}"
refused "blast-radius: --manifest outside the self-test is refused" "--manifest" blast-radius --base "${BASE_SHA}" --head "${HEAD_SHA}" --manifest "${TMP}/m.json"
refused "blast-radius: --base=VALUE is refused" "--base" blast-radius --base="${BASE_SHA}" --head "${HEAD_SHA}"
refused "blast-radius: an unknown flag is refused" "--bsae" blast-radius --bsae x
refused "blast-radius: --self-test with another argument is refused, not run" "--self-test takes no other argument" blast-radius --self-test --base "${BASE_SHA}"
accepted "blast-radius: a plain --base/--head classification still runs (COLD)" 0 blast-radius --base "${BASE_SHA}" --head "${HEAD_SHA}"

# --- forge-preflight: its default mints a token, so ANY argument is refused -------
refused "forge-preflight: a typo is refused, not run as the default (token mint)" "--chek" forge-preflight --chek
refused "forge-preflight: a stray word is refused" "stray" forge-preflight stray

# --- contention-census ---------------------------------------------------------
refused "contention-census: an argument after --self-test is refused" "--bogus" contention-census --self-test --bogus
refused "contention-census: an empty argument is refused, not read as no argument" "''" contention-census ''

# --- check-inotify-headroom: parse everything, then act ---------------------------
refused "check-inotify-headroom: an unknown flag after --self-test is refused" "--bogus" check-inotify-headroom --self-test --bogus
refused "check-inotify-headroom: --threshold twice is refused" "--threshold given more than once" check-inotify-headroom --threshold 50 --threshold 60

# --- admiral-report-watch ---------------------------------------------------------
refused "admiral-report-watch: --session-id does not swallow --max-loops" "--session-id needs a value" admiral-report-watch run-x --session-id --max-loops 1
refused "admiral-report-watch: --poll-s twice is refused" "--poll-s given more than once" admiral-report-watch run-x --poll-s 0 --poll-s 0 --max-loops 1
# The run-id is a key: it names /tmp/admiral-<run-id>-seen and the reports dir.
# A `/` in it made the seen-file path unwritable and the watcher looped on
# find/touch errors every poll instead of refusing (measured 2026-09-29, a live
# admiral passing a path). --reports-dir keeps a fall-through out of the repo.
refused "admiral-report-watch: a run-id with / is refused, not looped on" "is not a valid run-id" admiral-report-watch "${TMP}/runs/x" --reports-dir "${TMP}/arw-r" --poll-s 0 --max-loops 1
refused "admiral-report-watch: a run-id of .. is refused (it escapes the coordination dir)" "is not a valid run-id" admiral-report-watch .. --reports-dir "${TMP}/arw-r" --poll-s 0 --max-loops 1

# --- confirm-merged ------------------------------------------------------------
refused "confirm-merged: --pr does not swallow --json" "--pr needs a value" confirm-merged --pr --json
refused "confirm-merged: --sha twice is refused" "--sha given more than once" confirm-merged --sha "${BASE_SHA}" --sha "${BASE_SHA}" --target main --repo "${REPO}"
refused "confirm-merged: an unknown argument carries a Fix:" "--bogus" confirm-merged --bogus
refused "confirm-merged: an argument after --self-test is refused, not run" "--self-test" confirm-merged --self-test --bogus
accepted "confirm-merged: the git-ancestry probe still confirms" 0 confirm-merged --sha "${BASE_SHA}" --target main --repo "${REPO}"

# --- push-actor-check ------------------------------------------------------------
refused "push-actor-check: --repo does not swallow --sha" "--repo needs a value" push-actor-check --repo --sha "${BASE_SHA}" main
refused "push-actor-check: --window twice is refused" "--window given more than once" push-actor-check --window 5 --window 6 main

# --- fleet-control / fleet-report / fleet-resume --------------------------------
refused "fleet-control: --session-id does not swallow --cwd" "--session-id needs a value" fleet-control check --session-id --cwd /tmp
refused "fleet-control: --cwd twice is refused" "--cwd given more than once" fleet-control check --session-id s1 --cwd /tmp --cwd /tmp
refused "fleet-report: --session-id does not swallow --cwd" "--session-id needs a value" fleet-report session-start --session-id --cwd /tmp --dry-run
refused "fleet-report: --session-id twice is refused" "--session-id given more than once" fleet-report session-end --session-id a --session-id b --dry-run
refused "fleet-resume: --run-id does not swallow --root" "--run-id needs a value" fleet-resume status --run-id --root /tmp
refused "fleet-resume: --run-id twice is refused" "--run-id given more than once" fleet-resume status --session-id s1 --run-id a --run-id b

# --- test-slot -------------------------------------------------------------------
refused "test-slot: --label does not swallow --exclusive" "--label needs a value" test-slot --label --exclusive -- true
refused "test-slot: --label twice (either spelling) is refused" "--label given more than once" test-slot --label a --label=b -- true
refused "test-slot: --wait-timeout does not swallow --json" "--wait-timeout needs a value" test-slot --wait-timeout --json -- true
refused "test-slot: --self-test with --status is refused (was last-wins)" "two modes" test-slot --self-test --status
accepted "test-slot: a labelled run still runs its command" 0 test-slot --label dnd-813 -- true

echo "strict-argv CLI suite: ${PASS} passed, ${FAIL} failed"
[ "${FAIL}" -eq 0 ]
