#!/bin/sh
# harness-event.sh: RETIRED (DND-1487). A no-op kept only so a settings.json
# that still wires it does not dangle.
#
# It was a PostToolUse hook that appended {ts,tool,ok} lines to
# ai-artifacts/telemetry/events.jsonl, a second telemetry schema beside
# ai/contracts/athena-telemetry.md. It is no longer in ai/hooks/registry.json
# and writes nothing. ~/.claude/settings.json is not in git, so a live wiring
# outlives the registry row. Deleting this file while it is wired would fail
# every tool call's PostToolUse and turn check-hooks-registered red (dangling)
# on the machine.
#
# Delete this file once no machine's settings.json wires it. scripts/setup-hooks
# cannot unwire a hook that left the registry; that gap is ticketed separately.
#
# It drains stdin so the writer never sees a broken pipe, and always exits 0.
cat >/dev/null 2>&1
exit 0
