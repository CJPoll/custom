#!/usr/bin/env bash
# main-session-policy.sh — SessionStart hook.
#
# Injects the main-session operating policy as `additionalContext`, but ONLY for
# the top-level session (and forks of it) — NOT for subagents (athena-admiral /
# athena-captain / athena-architect, or anything spawned via the Agent/Task
# tool). The fleet subagents are exactly the ones that SHOULD do the work, so
# the "don't do the work yourself" policy must not reach them.
#
# Subagent detection (defensive — any positive signal suppresses the emit):
#   * env vars CLAUDE_AGENT_ID / CLAUDE_AGENT_TYPE set non-empty, and/or
#   * agent_id / agent_type present on the SessionStart stdin JSON.
# If stdin is absent or unparseable, we fail OPEN to "main session" (inject),
# since a real subagent reliably carries one of the signals above.
#
# Output contract (main session only):
#   {"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"..."}}
set -euo pipefail

# --- read stdin (empty / a tty on manual runs) ---
input=""
if [ ! -t 0 ]; then
  input="$(cat 2>/dev/null || true)"
fi

# --- subagent detection ---
is_subagent() {
  if [ -n "${CLAUDE_AGENT_ID:-}" ] || [ -n "${CLAUDE_AGENT_TYPE:-}" ]; then
    return 0
  fi
  [ -n "$input" ] || return 1
  INPUT="$input" python3 <<'PY'
import json, os, sys
try:
    d = json.loads(os.environ["INPUT"])
except Exception:
    sys.exit(1)  # unparseable -> treat as main (do not suppress)
if not isinstance(d, dict):
    sys.exit(1)
for k in ("agent_id", "agent_type", "agentId", "agentType"):
    v = d.get(k)
    if v not in (None, "", False):
        sys.exit(0)  # subagent
sys.exit(1)          # main session
PY
}

if is_subagent; then
  exit 0  # subagent: inject nothing
fi

POLICY=$(cat <<'TXT'
OPERATING POLICY — main (top-level) session only:

This session COORDINATES; it does not do the work itself.

- Ticketed work MUST be delegated to the fleet — spawn athena-admiral /
  athena-captain subagents (and athena-architect where design or planning is
  needed). Do not work tickets in the main session.
- The main session MUST NOT make code changes directly. Route every code change
  through the fleet.
- Small ad-hoc, non-code tasks are fine to do here: fetching or reading data,
  answering questions, sending Slack DMs/messages, status checks, and the like.
- Rule of thumb for ad-hoc scope: if it would produce a code or repo change as
  its work product, delegate it; if it is read-only or communication, go ahead.
TXT
)

POLICY="$POLICY" python3 <<'PY'
import json, os
print(json.dumps({"hookSpecificOutput": {
    "hookEventName": "SessionStart",
    "additionalContext": os.environ["POLICY"],
}}))
PY
