#!/usr/bin/env bash
#
# athena-shipwright-run.sh — headless entrypoint for the athena-shipwright agent.
#
# Invoked by cron (this machine is OpenRC + cronie; see the crontab entry in
# the repo README/docs). Sets its own PATH because cron starts with a minimal
# environment. Starts a headless Claude Code session in ~/dev/custom and delegates to the
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

# cron starts with a minimal PATH that typically omits /usr/sbin — where this
# box's ruby lives (build-agents, the shipwright's gate, needs it) — and the
# asdf shims. Establish a known-good PATH so the gate, git, ssh, and any MCP
# servers Claude spawns resolve the same as in a login shell.
#
# ${HOME}/bin is REQUIRED and easy to forget: the asdf ruby shim
# (${HOME}/.asdf/shims/ruby) is a thin wrapper that does `exec asdf exec ruby`,
# so it needs the asdf launcher binary (${HOME}/bin/asdf) on PATH. Omit
# ${HOME}/bin and every `#!/usr/bin/env ruby` gate tool (build-agents,
# harness-metrics/signals/eval, check-generic-skills, check-guard-messages)
# dies with "asdf: not found" — the shipwright then cannot run its own gate and
# telemetry silently drops out. The login shell's PATH (.zshrc) includes it.
export PATH="${HOME}/.local/bin:${HOME}/bin:${HOME}/.asdf/shims:/usr/local/bin:/usr/bin:/bin:/usr/local/sbin:/usr/sbin:/sbin${PATH:+:${PATH}}"

# The shipwright's real work (mining + subagent) runs in background tasks that a
# headless `claude -p` session waits on. The default background-wait ceiling is
# 600s, after which the parent kills those tasks and exits 0 mid-run — leaving
# commits unpushed and the journal/cursor unwritten (observed on a smoke test).
# Raise the ceiling to a generous but BOUNDED 50 minutes so a normal run
# finishes. We deliberately do NOT use 0 ("wait indefinitely"): with no outer
# timeout and an flock single-run guard, an indefinitely-hung run would hold the
# lock forever and silently wedge every future hourly tick. 50 min sits
# comfortably under the hourly cadence; the `timeout` wrapper on the claude call
# below is the hard backstop that guarantees the lock is released before the
# next tick even if the session itself hangs.
export CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS=3000000

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
# Hard backstop: cap the whole invocation at 55 minutes (under the hourly tick)
# so a hung session is killed and the flock is released before the next run,
# rather than wedging the lane forever. `timeout` exits 124 on expiry; capture
# the status either way instead of letting `set -e` abort before we log it.
if timeout 55m "${CLAUDE}" --dangerously-skip-permissions -p "${BRIEF}" >"${log}" 2>&1; then
  status=0
else
  status=$?
fi

echo "athena-shipwright: run ${ts} exited ${status}; log: ${log}" >&2
exit "${status}"
