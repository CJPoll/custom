#!/bin/sh
# PreToolUse pronoun guard.
#
# If an outgoing message (the tool input of a message-bearing tool) contains a
# standalone "he", "him", or "his", block the tool ONCE with a reminder to
# verify that none of them refer to Cody (who uses they/them). A content-hash
# marker lets the deliberate re-send pass, so the reminder fires once per
# distinct message, never in a loop.
#
# Design guarantees:
#   * FAIL-OPEN — any error (missing jq, unparseable input, no sha256, …) exits
#     0 and allows the tool. A bug here can never wedge the session or a fleet.
#   * LOOP-SAFE — at most one deny per distinct tool input; an identical re-send
#     (or a corrected version, re-confirmed once) passes.
#   * The confirmation signal is a marker FILE keyed on a hash of the tool input
#     — nothing is ever added to the message content itself.
#
# Wired in ~/.claude/settings.json as a PreToolUse hook, scoped to the
# message-bearing tools (Bash, SendMessage, notion-athena writes).

MARKDIR="${HOME}/.claude/.pronoun-checked"
mkdir -p "$MARKDIR" 2>/dev/null || exit 0

INPUT=$(cat 2>/dev/null) || exit 0
[ -n "$INPUT" ] || exit 0

# Canonicalize the tool input (sorted keys, compact). Fail-open on any jq issue.
TI=$(printf '%s' "$INPUT" | jq -cS '.tool_input' 2>/dev/null) || exit 0
[ -n "$TI" ] && [ "$TI" != "null" ] || exit 0

# No standalone he/him/his anywhere in the tool input -> allow (no opinion).
printf '%s' "$TI" | grep -iEq '\b(he|him|his)\b' || exit 0

# Drop stale markers (abandoned sends) older than 15 minutes.
find "$MARKDIR" -type f -mmin +15 -delete 2>/dev/null

HASH=$(printf '%s' "$TI" | sha256sum 2>/dev/null | cut -d' ' -f1) || exit 0
[ -n "$HASH" ] || exit 0
MARK="${MARKDIR}/${HASH}"

if [ -f "$MARK" ]; then
  # Already reminded for this exact message -> allow once and clear the marker.
  rm -f "$MARK" 2>/dev/null
  exit 0
fi

# First time for this message: record it and block with a reminder to Athena.
: > "$MARK" 2>/dev/null
cat <<'JSON'
{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"PRONOUN CHECK: this outgoing message contains \"he\", \"him\", or \"his\". Before it sends, confirm that NONE of those pronouns refer to Cody, who uses they/them. Fix: if any refer to Cody, rewrite them to they/them. Then re-send: this check is one-time per message, so re-sending the identical message (or the corrected version, which will be re-confirmed once) will pass."}}
JSON
exit 0
