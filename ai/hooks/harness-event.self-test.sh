#!/bin/sh
# Self-test for ai/hooks/harness-event.sh, the retired PostToolUse hook
# (DND-1487). It must stay a no-op while a live settings file still wires it:
# exit 0, print nothing, and write nothing, the old telemetry sink included.
# Run with stdin closed: ai/hooks/harness-event.self-test.sh </dev/null

HOOK="$(cd -- "$(dirname -- "$0")" && pwd -P)/harness-event.sh"
TMP=$(mktemp -d) || { echo "harness-event.self-test: FAIL - mktemp. Fix: free space in TMPDIR."; exit 1; }
trap 'rm -rf "$TMP"' EXIT INT TERM
fail=0
note() { echo "  FAIL $1"; fail=1; }

[ -x "$HOOK" ] || note "the hook is not executable (a wired settings entry would dangle)"

# A real PostToolUse payload, with HOME pointed at an empty scratch dir so any
# write under ~/dev/custom/ai-artifacts/telemetry would land here and be seen.
mkdir -p "$TMP/home"
out=$(printf '%s' '{"tool_name":"Bash","tool_response":{"is_error":true}}' \
  | HOME="$TMP/home" HARNESS_EVENT_SINK="$TMP/sink.jsonl" "$HOOK" 2>&1)
rc=$?
[ "$rc" -eq 0 ] || note "a payload exits $rc, want 0"
[ -z "$out" ] || note "a payload printed output: $out"
[ ! -e "$TMP/sink.jsonl" ] || note "the hook wrote the HARNESS_EVENT_SINK file"
[ -z "$(find "$TMP/home" -mindepth 1 -print -quit)" ] || note "the hook wrote under HOME"

# Empty stdin is still exit 0.
HOME="$TMP/home" "$HOOK" </dev/null >/dev/null 2>&1 || note "empty stdin did not exit 0"

if [ "$fail" -eq 0 ]; then
  echo "harness-event.self-test: OK"
  exit 0
fi
echo "harness-event.self-test: FAILED. Fix: keep ai/hooks/harness-event.sh a no-op that drains stdin and exits 0 until no settings.json wires it."
exit 1
