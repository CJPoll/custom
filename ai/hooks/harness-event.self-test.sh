#!/bin/sh
# Self-test for ai/hooks/harness-event.sh — the PostToolUse telemetry hook.
# Asserts: a valid PostToolUse payload writes one well-formed event line with the
# expected tool + ok fields; a malformed payload is a no-op (exit 0, nothing
# written); the hook never errors. Run with stdin closed.

HOOK="$(cd -- "$(dirname -- "$0")" && pwd -P)/harness-event.sh"
FAILED=0
note() { printf '%s\n' "$*" >&2; }

command -v jq >/dev/null 2>&1 || { echo "harness-event.self-test: SKIP (no jq)"; exit 0; }

TMP=$(mktemp -d) || { echo "harness-event.self-test: FAIL — mktemp"; exit 1; }
SINK="$TMP/events.jsonl"

# 1. valid success payload -> one event, ok=true, tool=Bash
printf '%s' '{"tool_name":"Bash","tool_input":{"command":"ls"},"tool_response":{"stdout":"x"}}' \
  | HARNESS_EVENT_SINK="$SINK" "$HOOK"
if [ ! -f "$SINK" ]; then note "FAIL — no sink written for valid payload"; FAILED=1
else
  n=$(wc -l < "$SINK" | tr -d ' ')
  [ "$n" = "1" ] || { note "FAIL — expected 1 event, got $n"; FAILED=1; }
  jq -e '.tool == "Bash" and .ok == true and (.ts|type=="string")' "$SINK" >/dev/null 2>&1 \
    || { note "FAIL — event shape wrong: $(cat "$SINK")"; FAILED=1; }
fi

# 2. error payload -> ok=false
: > "$SINK"
printf '%s' '{"tool_name":"Bash","tool_response":{"is_error":true}}' \
  | HARNESS_EVENT_SINK="$SINK" "$HOOK"
jq -e '.ok == false' "$SINK" >/dev/null 2>&1 || { note "FAIL — is_error not mapped to ok=false"; FAILED=1; }

# 3. malformed payload -> no-op, exit 0, nothing appended
: > "$SINK"
printf '%s' 'not json at all' | HARNESS_EVENT_SINK="$SINK" "$HOOK"
rc=$?
[ "$rc" = "0" ] || { note "FAIL — malformed payload did not exit 0 (rc=$rc)"; FAILED=1; }
[ -s "$SINK" ] && { note "FAIL — malformed payload wrote an event"; FAILED=1; }

rm -rf "$TMP"
if [ "$FAILED" = "0" ]; then
  echo "harness-event.self-test: OK"
  exit 0
fi
note "harness-event.self-test: FAILED"
note "  Fix: keep the hook fail-open — a valid PostToolUse payload writes one {ts,tool,ok} line; a malformed one exits 0 and writes nothing."
exit 1
