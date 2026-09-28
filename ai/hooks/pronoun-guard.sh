#!/bin/sh
# PreToolUse pronoun guard.
#
# If a tool call's text (every string anywhere in its tool_input) contains a
# standalone "he", "him", or "his", block the tool ONCE with a reminder to
# verify that none of them refer to Cody (who uses they/them). A content-hash
# marker lets the deliberate re-send pass, so the reminder fires once per
# distinct tool input, never in a loop.
#
# Scope: EVERY tool. Wired as one PreToolUse row with matcher "*" (DND-932,
# owner decision 2026-09-27: "fire on all tools, not just specific known
# tools"). So it never assumes a tool's input shape: it scans every string
# value, recursively, whatever the fields are called.
#
# Design guarantees:
#   * FAIL-OPEN — any error (missing jq, unparseable input, no sha256, …) exits
#     0 and allows the tool. A bug here can never wedge the session or a fleet.
#     An input it cannot read is noted, with a Fix:, in
#     ${XDG_STATE_HOME:-~/.local/state}/athena/pronoun-guard.log.
#   * WHOLE INPUT, NO SHELL BUFFERS — every string is scanned, however large:
#     no size cap, because a cap would stop catching prose the guard caught
#     before (DND-932 critic). Input and text go through temp files, never
#     shell variables or argv, so a huge input costs time (~0.1 s per MiB),
#     never an E2BIG or a truncated scan. NUL bytes in a string are dropped
#     before matching; grep -a treats every other byte as text.
#   * LOOP-SAFE — at most one deny per distinct tool input; an identical re-send
#     (or a corrected version, re-confirmed once) passes.
#   * The confirmation signal is a marker FILE keyed on a hash of the tool input
#     — nothing is ever added to the message content itself.

MARKDIR="${HOME}/.claude/.pronoun-checked"
LOGDIR="${XDG_STATE_HOME:-${HOME}/.local/state}/athena"
LOG="${LOGDIR}/pronoun-guard.log"

# note <what> <fix>: one line in the guard's log. Never fails the hook.
note() {
  mkdir -p "$LOGDIR" 2>/dev/null &&
    printf '%s pronoun-guard: %s; allowed unscanned. Fix: %s\n' \
      "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" "$2" >> "$LOG" 2>/dev/null
  return 0
}

mkdir -p "$MARKDIR" 2>/dev/null || exit 0
WORK=$(mktemp -d 2>/dev/null) || exit 0
trap 'rm -rf "$WORK"' EXIT INT TERM

cat > "$WORK/in" 2>/dev/null || exit 0
[ -s "$WORK/in" ] || exit 0

if ! command -v jq > /dev/null 2>&1; then
  note "jq not found" "install jq (the guard needs it to read tool input)"
  exit 0
fi

# Canonicalize the tool input (sorted keys, compact) for the marker hash.
if ! jq -cS '.tool_input' < "$WORK/in" > "$WORK/ti" 2>/dev/null; then
  note "unparseable hook stdin (not JSON)" \
    "if this repeats, capture the payload and check the Claude Code hook input format"
  exit 0
fi
case "$(head -c 5 "$WORK/ti")" in null|'') exit 0 ;; esac

# Match against the DECODED string values, never the JSON encoding. In the
# encoding a line-initial "he" reads `\nhe` and a tab-led "his" reads `\this`:
# the escape letter is a word character, so those prose pronouns were missed
# (DND-738). NUL bytes are dropped before matching.
jq -r '[.. | strings] | join("\n")' < "$WORK/ti" 2>/dev/null | tr -d '\000' > "$WORK/text"

# A pronoun counts only as a PROSE word. `\b` also split code tokens, so a
# python edit script carrying `grep -hE` was denied (DND-738). Not prose:
#   left  joined to  - / \ $ { . @ % = |  (flag, path, escape, variable,
#                                            name, regex alternation)
#   right joined to  - \ ( = |            (compound, escape, call,
#                                            assignment, regex alternation)
#   right .  followed by a word char        (he.txt)
#   right :  followed by anything but whitespace (t[he:], "he:#{n}", he:x)
# A right-hand "/" stays a boundary so a pronoun list ("he/him") is still
# caught. The guard does not parse shell to find prose arguments: a misparse
# there would drop real prose silently, while a code token that slips this
# shape test costs one confirm-and-resend.
PRONOUN='(^|[^[:alnum:]_/\\$.{@%=|-])(he|him|his)([^[:alnum:]_\\(=.:|-]|[.]([^[:alnum:]_]|$)|:([[:space:]]|$)|$)'

# No prose he/him/his anywhere in the tool input -> allow (no opinion).
grep -aiEq "$PRONOUN" "$WORK/text" 2>/dev/null || exit 0

# Drop stale markers (abandoned sends) older than 15 minutes.
find "$MARKDIR" -type f -mmin +15 -delete 2>/dev/null

HASH=$(sha256sum < "$WORK/ti" 2>/dev/null | cut -d' ' -f1) || exit 0
[ -n "$HASH" ] || exit 0
MARK="${MARKDIR}/${HASH}"

if [ -f "$MARK" ]; then
  # Already reminded for this exact tool input -> allow once and clear the marker.
  rm -f "$MARK" 2>/dev/null
  exit 0
fi

# First time for this tool input: record it and block with a reminder to Athena.
: > "$MARK" 2>/dev/null
cat <<'JSON'
{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"PRONOUN CHECK: this tool call's text contains \"he\", \"him\", or \"his\". Before it runs, confirm that NONE of those pronouns refer to Cody, who uses they/them. Fix: if any refer to Cody, rewrite them to they/them. Then re-send: this check is one-time per tool input, so re-sending the identical call (or the corrected version, which will be re-confirmed once) will pass."}}
JSON
exit 0
