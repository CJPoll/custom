#!/bin/sh
# harness-event.sh — PostToolUse hook: append one compact telemetry event per
# tool call to a durable local sink, for continuous harness observability
# (gap 2). Complements ai/bin/harness-metrics (which parses the session JSONL
# after the fact): this emits in real time and can capture events a later parse
# would miss.
#
# FAIL-OPEN and NON-BLOCKING: any error (no jq, unparseable input, unwritable
# sink) exits 0 and never affects the tool call. A PostToolUse hook cannot block
# a call that already ran, but it must still never error out loudly.
#
# Sink: ${HOME}/dev/custom/ai-artifacts/telemetry/events.jsonl (gitignored local
# runtime state; an ABSOLUTE path so it aggregates across every session
# regardless of the session's cwd). One JSON object per line:
#   {"ts":"<iso8601>","tool":"<tool_name>","ok":<true|false|null>}
#
# Harness contract (Claude Code hooks reference): PostToolUse receives JSON on
# stdin with the common fields plus tool_name, tool_input, and tool_response.
# Plain exit 0 with no stdout is a no-op.
#
# OPT-IN: install links this as ~/.claude/hooks/wurk-harness-event.sh only when
# asked; wire it by hand in settings.json under PostToolUse (matcher ""). The
# default install never touches hooks. Settings snippet (absolute path):
#   {"hooks":{"PostToolUse":[{"matcher":"","hooks":[{"type":"command",
#     "command":"/home/<you>/.claude/hooks/wurk-harness-event.sh"}]}]}}
#
# --self-test lives in ai/hooks/harness-event.self-test.sh (the hooks read stdin,
# so a --self-test FLAG would block; use the dedicated script).

SINK="${HARNESS_EVENT_SINK:-${HOME}/dev/custom/ai-artifacts/telemetry/events.jsonl}"

INPUT=$(cat 2>/dev/null) || exit 0
[ -n "$INPUT" ] || exit 0
command -v jq >/dev/null 2>&1 || exit 0

mkdir -p "$(dirname "$SINK")" 2>/dev/null || exit 0

TS=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null) || exit 0

# Extract tool name and a success indicator; ok is false only when the tool
# response is explicitly an error, true when a response is present, null when
# unknown. Fail-open: any jq trouble exits 0 without writing.
LINE=$(printf '%s' "$INPUT" | jq -c --arg ts "$TS" '
  {ts: $ts,
   tool: (.tool_name // "unknown"),
   ok: ( if (.tool_response | type) == "object" and (.tool_response.is_error == true) then false
         elif (.tool_response == null) then null
         else true end )}' 2>/dev/null) || exit 0

[ -n "$LINE" ] || exit 0
printf '%s\n' "$LINE" >> "$SINK" 2>/dev/null || exit 0
exit 0
