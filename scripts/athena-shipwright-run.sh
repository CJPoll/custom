#!/usr/bin/env bash
#
# athena-shipwright-run.sh — headless entrypoint for the athena-shipwright agent.
#
# Invoked by a local timer (see system-files/athena-shipwright.{service,timer}).
# Starts a headless Claude Code session in ~/dev/custom and delegates to the
# athena-shipwright agent, which mines the fleet's run artifacts, improves the
# harness, and syncs the repo with GitHub. Coordinating-session-then-delegate
# matches the main-session-policy hook: the top-level session spawns the agent
# rather than doing the work itself.
#
# Single-run: an flock guard skips the run (exit 0) if one is already going, so
# a slow run never overlaps the next timer tick.
#
# Usage:
#   scripts/athena-shipwright-run.sh          # normal (timer) invocation
#   DRY_RUN=1 scripts/athena-shipwright-run.sh  # print the brief and exit

set -euo pipefail

REPO="${HOME}/dev/custom"
CLAUDE="${HOME}/.local/bin/claude"
STATE_DIR="${REPO}/ai-artifacts/shipwright"
LOG_DIR="${STATE_DIR}/runs"
LOCK="${STATE_DIR}/run.lock"

mkdir -p "${LOG_DIR}"

BRIEF="You are coordinating; do the work by delegating. Spawn exactly one \
athena-shipwright agent (Agent tool, subagent_type: athena-shipwright) with \
this brief, and do nothing else yourself: 'Run your full retrospective now. \
Sync ~/dev/custom with its remote first (pull), mine every coordination \
artifact newer than your cursor, apply harness improvements per your Method, \
gate, and invariants, commit each change locally, push your commits, and \
update your journal and cursor.' When it finishes, relay its one-line summary \
verbatim and stop."

if [ "${DRY_RUN:-0}" = "1" ]; then
  printf '%s\n' "${BRIEF}"
  exit 0
fi

# Skip rather than queue if a run is already in flight.
exec 9>"${LOCK}"
if ! flock -n 9; then
  echo "athena-shipwright: a run is already in progress; skipping this tick." >&2
  exit 0
fi

cd "${REPO}"

ts="$(date +%Y-%m-%dT%H%M%S)"
log="${LOG_DIR}/${ts}.log"

# House pattern for unattended Claude Code (see scripts/athena).
"${CLAUDE}" --dangerously-skip-permissions -p "${BRIEF}" >"${log}" 2>&1
status=$?

echo "athena-shipwright: run ${ts} exited ${status}; log: ${log}" >&2
exit "${status}"
