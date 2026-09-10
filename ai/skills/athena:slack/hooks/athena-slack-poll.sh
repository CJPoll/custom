#!/bin/sh
# UserPromptSubmit hook: at most once every 5 minutes, look for Slack DMs and
# mentions addressed to Athena and, only when something is actually waiting,
# print ONE line.
#
# WHY A HOOK. A skill has no timer. Hooks are the only thing that fires on a
# cadence, and UserPromptSubmit is the only frequent event whose stdout on exit
# 0 is added to the model's context.
#
# WHY IT IS SILENT. The common case is "nothing new", and a line on every
# prompt would spend context on every turn to say nothing. Zero prints nothing.
# So does every failure: no token, no network, a Slack error and a malformed
# response all exit 0 with no output, because a hook that interrupts a turn to
# complain about itself is worse than a hook that is quietly off. The reasons
# go to ~/.claude/athena-slack-poll.log so the silence stays diagnosable.
#
# WHAT IT NEVER PRINTS. Message bodies, senders, or channel names. Slack
# messages are untrusted text written by other people; injecting one into
# context on a hook's authority would let a stranger address the model before
# the user has said anything. This hook emits COUNTS and a pointer to
# `read-inbox`, which shows bodies under that script's untrusted-input rule.
#
# WHAT IT NEVER DOES. Advance the inbox state file. The hook is the doorbell;
# read-inbox is the door. A hook that marked messages seen would announce them
# once and then hide them from the script that exists to show them.
#
# Exit status is 0 on every path. A UserPromptSubmit hook exiting 2 BLOCKS the
# user's prompt, and nothing this script can discover justifies that.

set -u

POLL_MINUTES="${SLACK_POLL_MINUTES:-5}"
LOG="$HOME/.claude/athena-slack-poll.log"
LOG_MAX_LINES=200
MARKER="$HOME/.claude/athena-slack-last-poll"
SUCCESS_MARKER="$HOME/.claude/athena-slack-last-success"
WARN_MARKER="$HOME/.claude/athena-slack-last-warn"
# How long the poll may go without a SUCCESSFUL run before it says so out loud,
# and how often it may repeat that. A single silent failure is right; an
# indefinitely silent one is shaped exactly like the healthy state, so a
# revoked token would stop Athena hearing anything and nothing would ever say
# so. Same reasoning, same numbers, as the agent-messages poll.
STALE_SUCCESS_HOURS=6
STALE_MINUTES=$((STALE_SUCCESS_HOURS * 60))
WARN_INTERVAL_MINUTES=$((STALE_SUCCESS_HOURS * 60))

HOOK_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
LIB_DIR="$HOOK_DIR/../lib"

# Appends a fixed reason to a bounded local log. Never writes the token, a
# response body, or any Slack text -- callers pass a literal string.
log_failure() {
  mkdir -p "$(dirname "$LOG")" 2>/dev/null || return 0
  printf '%s %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$1" >> "$LOG" 2>/dev/null || return 0
  lines="$(wc -l < "$LOG" 2>/dev/null || echo 0)"
  if [ "$lines" -gt "$LOG_MAX_LINES" ] 2>/dev/null; then
    tail -n "$LOG_MAX_LINES" "$LOG" > "$LOG.tmp" 2>/dev/null && mv "$LOG.tmp" "$LOG" 2>/dev/null
  fi
  return 0
}

# The one thing this hook ever says about itself, and only once the silence has
# stopped being momentary. Reachable ONLY when a token is configured: "no
# token" is a deliberate off state, not a breakage, and warning about it would
# nag every machine that has chosen not to set the skill up.
#
# A missing success marker counts as stale: there is no evidence of a prior
# success to call this failure momentary against, and a token that has never
# once worked is the most likely thing to be wrong.
maybe_warn_stale() {
  if [ -f "$SUCCESS_MARKER" ] &&
     [ -n "$(find "$SUCCESS_MARKER" -mmin -"$STALE_MINUTES" 2>/dev/null)" ]; then
    return 0
  fi
  if [ -f "$WARN_MARKER" ] &&
     [ -n "$(find "$WARN_MARKER" -mmin -"$WARN_INTERVAL_MINUTES" 2>/dev/null)" ]; then
    return 0
  fi
  : > "$WARN_MARKER" 2>/dev/null || return 0
  printf 'athena-slack poll has not succeeded in %sh — see %s\n' \
    "$STALE_SUCCESS_HOURS" "$LOG"
}

soft_fail() {
  log_failure "$1"
  maybe_warn_stale
  exit 0
}

# --- is the skill configured at all? ---------------------------------------
# Unconfigured is silent AND unlogged: it would be every line on every machine
# that has not set this up.
TOKEN_FILE="${SLACK_TOKEN_FILE:-$HOME/.claude/slack-bot-token}"
if [ -z "${SLACK_BOT_TOKEN:-}" ] && [ ! -f "$TOKEN_FILE" ]; then
  exit 0
fi

# --- the rate limit ---------------------------------------------------------
if [ -f "$MARKER" ] && [ -n "$(find "$MARKER" -mmin -"$POLL_MINUTES" 2>/dev/null)" ]; then
  exit 0
fi

# Stamp the marker BEFORE the network calls, not after. If Slack is hanging or
# erroring, an after-the-fact touch would leave the marker stale and fire a
# fresh scan on every single prompt; stamping the attempt caps the damage at
# one attempt per interval no matter how it goes.
mkdir -p "$(dirname "$MARKER")" 2>/dev/null || exit 0
: > "$MARKER" 2>/dev/null || exit 0

for tool in curl jq; do
  command -v "$tool" >/dev/null 2>&1 || soft_fail "missing-tool:$tool"
done

HOOKTMP="$(mktemp -d 2>/dev/null)" || soft_fail "mktemp-failed"
trap 'rm -rf "$HOOKTMP"' EXIT INT TERM
NEW="$HOOKTMP/new.jsonl"
REASON="$HOOKTMP/reason"

# The scan runs in a subshell so that lib/slack.sh's `set -e` discipline and
# its exit-on-failure slack_die cannot take the hook down with them. slack_die
# is redefined to record a fixed reason and fail the subshell; the hook decides
# what to do with that, and the answer is always "exit 0 quietly".
(
  set -eu
  . "$LIB_DIR/slack.sh"
  . "$LIB_DIR/inbox.sh"
  slack_die() {
    printf '%s' "$1" > "$REASON" 2>/dev/null
    exit 1
  }
  inbox_scan "$NEW"
) >/dev/null 2>&1
RC=$?

if [ "$RC" -ne 0 ]; then
  # The reason is written by slack_die from a fixed string plus a Slack error
  # code -- never a message body. Truncated anyway, so a surprising value
  # cannot fill the log.
  why="$(cut -c1-120 < "$REASON" 2>/dev/null | tr -d '\n')"
  if [ -z "$why" ]; then why="scan-failed rc=$RC"; fi
  soft_fail "scan: $why"
fi

DMS="$(grep -c '"kind":"dm"' "$NEW" 2>/dev/null)"
MENTIONS="$(grep -c '"kind":"mention"' "$NEW" 2>/dev/null)"
case "$DMS" in ''|*[!0-9]*) DMS=0 ;; esac
case "$MENTIONS" in ''|*[!0-9]*) MENTIONS=0 ;; esac

# A completed scan is a success whether or not it found anything -- the
# question the marker answers is "is this hook still working", not "did
# anything arrive". Clearing the warn marker restarts the warning clock so the
# next outage gets its own prompt warning rather than being suppressed by this
# one.
: > "$SUCCESS_MARKER" 2>/dev/null || true
rm -f "$WARN_MARKER" 2>/dev/null || true

TOTAL=$((DMS + MENTIONS))
[ "$TOTAL" -gt 0 ] || exit 0

printf '%s new Slack DM(s) and %s mention(s) for Athena — run /athena:slack read-inbox\n' \
  "$DMS" "$MENTIONS"
exit 0
