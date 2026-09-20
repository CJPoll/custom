#!/bin/sh
# Self-test for ai/hooks/main-session-policy.sh — the SessionStart hook that
# injects the "this session COORDINATES, it does not do the work" policy into
# the top-level session ONLY, and stays silent for fleet subagents.
#
# Why this suite exists: the hook is a context INJECTOR, so every way it can
# break is silent. If it stops emitting, or emits a well-formed envelope with an
# empty body, it exits 0 and nothing is written anywhere — the main session
# simply never learns it must delegate, and starts working tickets itself. That
# is the repo's "a failed lookup must never look like an empty one" class, so
# the assertions below check the BODY, not just the JSON shape.
#
# Run with stdin closed: ai/hooks/main-session-policy.self-test.sh </dev/null
#
# NOTE: every case runs the hook under `env -u CLAUDE_AGENT_ID -u
# CLAUDE_AGENT_TYPE`. This suite is itself executed from inside an agent
# session, which exports those very vars — inheriting them would make the
# main-session cases assert the sandbox's state instead of the hook's.

HOOK="$(cd -- "$(dirname -- "$0")" && pwd -P)/main-session-policy.sh"
FAILED=0
note() { printf '%s\n' "$*" >&2; }

command -v python3 >/dev/null 2>&1 || {
  echo "main-session-policy.self-test: SKIP (no python3)"; exit 0; }

# Run the hook as a MAIN session (agent vars scrubbed), stdin from $1.
run_main() { printf '%s' "$1" | env -u CLAUDE_AGENT_ID -u CLAUDE_AGENT_TYPE "$HOOK" 2>/dev/null; }

# Assert stdout is the SessionStart envelope AND carries the load-bearing
# policy text. An empty or truncated additionalContext must FAIL here.
assert_injects() {
  _label="$1"; _out="$2"
  OUT="$_out" python3 <<'PY'
import json, os, sys
raw = os.environ["OUT"]
if not raw.strip():
    print("emitted nothing", file=sys.stderr); sys.exit(1)
try:
    d = json.loads(raw)
except Exception as e:
    print("stdout is not JSON: %s" % e, file=sys.stderr); sys.exit(1)
h = d.get("hookSpecificOutput")
if not isinstance(h, dict):
    print("no hookSpecificOutput object", file=sys.stderr); sys.exit(1)
if h.get("hookEventName") != "SessionStart":
    print("hookEventName != SessionStart (%r)" % h.get("hookEventName"), file=sys.stderr); sys.exit(1)
ctx = h.get("additionalContext")
if not isinstance(ctx, str) or not ctx.strip():
    print("additionalContext empty/missing -- silent no-op", file=sys.stderr); sys.exit(1)
# The directives that make this hook a safety mechanism. If the body is ever
# gutted to a blank or placeholder string the envelope still parses, so the
# body is what gets asserted.
for needle in ("COORDINATES", "MUST NOT make code changes directly", "delegated to the fleet"):
    if needle not in ctx:
        print("policy body missing %r" % needle, file=sys.stderr); sys.exit(1)
sys.exit(0)
PY
  if [ $? -ne 0 ]; then note "FAIL — $_label: expected policy injection"; FAILED=1; fi
}

# Assert the hook stayed silent (subagent path).
assert_silent() {
  _label="$1"; _out="$2"
  if [ -n "$(printf '%s' "$_out" | tr -d '[:space:]')" ]; then
    note "FAIL — $_label: expected NO output, got: $_out"; FAILED=1
  fi
}

# --- main-session cases: the hook MUST inject ---

# 1. no stdin at all (manual / empty SessionStart)
assert_injects "empty stdin" "$(run_main '')"

# 2. a realistic SessionStart payload with no agent markers
assert_injects "main-session payload" \
  "$(run_main '{"session_id":"abc","source":"startup","cwd":"/home/x/dev/custom"}')"

# 3. unparseable stdin must FAIL OPEN to main session (documented contract:
#    a real subagent reliably carries a positive signal, so garbage is main)
assert_injects "unparseable stdin fails open" "$(run_main 'not json at all')"

# 4. JSON that is not an object also fails open
assert_injects "non-object JSON fails open" "$(run_main '[1,2,3]')"

# 5. agent keys present but null/empty are NOT a subagent signal
assert_injects "null agent_id is not a subagent" \
  "$(run_main '{"agent_id":null,"agent_type":""}')"

# --- subagent cases: the hook MUST stay silent ---

# 6. CLAUDE_AGENT_ID in the environment
assert_silent "CLAUDE_AGENT_ID set" \
  "$(printf '%s' '' | env -u CLAUDE_AGENT_TYPE CLAUDE_AGENT_ID=agent-123 "$HOOK" 2>/dev/null)"

# 7. CLAUDE_AGENT_TYPE in the environment
assert_silent "CLAUDE_AGENT_TYPE set" \
  "$(printf '%s' '' | env -u CLAUDE_AGENT_ID CLAUDE_AGENT_TYPE=athena-captain "$HOOK" 2>/dev/null)"

# 8. agent_id on the stdin payload (snake_case)
assert_silent "stdin agent_id" "$(run_main '{"agent_id":"a1","source":"startup"}')"

# 9. agentType on the stdin payload (camelCase)
assert_silent "stdin agentType" "$(run_main '{"agentType":"athena-admiral"}')"

# --- the hook must never fail the session ---

# 10. exit 0 on every path, including garbage input
for payload in '' '{"session_id":"x"}' 'garbage' '{"agent_id":"a1"}'; do
  printf '%s' "$payload" | env -u CLAUDE_AGENT_ID -u CLAUDE_AGENT_TYPE "$HOOK" >/dev/null 2>&1
  rc=$?
  [ "$rc" = "0" ] || { note "FAIL — nonzero exit ($rc) for payload: ${payload:-<empty>}"; FAILED=1; }
done

if [ "$FAILED" = "0" ]; then
  echo "main-session-policy.self-test: OK"
  exit 0
fi
note "main-session-policy.self-test: FAILED"
note "  Fix: the hook must print ONE SessionStart envelope whose additionalContext"
note "  still contains the delegation policy (COORDINATES / MUST NOT make code"
note "  changes directly / delegated to the fleet) for a main session — including"
note "  when stdin is empty or unparseable, which fails OPEN to main — and must"
note "  print NOTHING when CLAUDE_AGENT_ID/CLAUDE_AGENT_TYPE is set or the stdin"
note "  JSON carries agent_id/agent_type/agentId/agentType. Exit 0 on every path."
exit 1
