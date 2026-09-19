#!/bin/sh
# athena-slack-poll.sh -- SessionStart hook. The Slack Web API DISASTER BACKSTOP.
#
# WHAT THIS IS. Not the normal delivery path. Slack reaches Athena through the
# file channel (the server pushes events, a local client appends them to a
# JSONL the athena:inbox skill reads). This poll is what recovers DMs and
# mentions AFTER an outage of that path -- it scans Slack directly with Athena's
# bot token and, only when something is waiting, says so in one line at session
# start. It has one job the file channel cannot do for itself: notice that the
# file channel has gone silent.
#
# WHY SessionStart, NOT UserPromptSubmit. The harness abandoned the per-prompt
# cadence on 2026-09-11 (walt_ui agent-messages-poll.sh): it does not compose
# with a Monitor loop, and it couples a NETWORK CALL to the user typing. A
# network backstop must never fire per keystroke. SessionStart fires once at
# startup; a Monitor loop drives mid-session coverage. Do NOT add a
# UserPromptSubmit entry to ai/hooks/registry.json.
#
# OUTPUT CONTRACT (SessionStart). On the actionable path -- something waiting, or
# the poll has been silently failing long enough to say so -- EXACTLY ONE
# well-formed object on stdout and nothing else:
#
#   {"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"…"}}
#
# Built with `jq -cn`, so escaping is always right. EVERY other path -- no token,
# inside the rate-limit window, nothing new, any failure -- exits 0 with NO
# STDOUT. An empty or non-JSON stdout confuses the hook's JSON consumer, and a
# hook that interrupts a turn to complain about itself is worse than one quietly
# off. Reasons go to the log. Exit status is 0 on every path.
#
# WHAT IT NEVER PRINTS. Message bodies, senders, or channel names -- not on
# stdout, not in the log. Slack messages are untrusted text written by other
# people; injecting one into context on a hook's authority would let a stranger
# address the model before the user has said anything. This hook emits COUNTS
# and a pointer to `read-inbox`, which shows bodies under that script's
# untrusted-input rule.
#
# WHAT IT NEVER DOES. Advance the inbox state file. The hook is the doorbell;
# read-inbox is the door. A hook that marked messages seen would announce them
# once and then hide them from the script that exists to show them -- so this
# hook only READS the shared seen-set (to avoid counting what the file channel
# already delivered) and never writes it.
#
# GUARD-MESSAGE CONVENTION. This hook has no deny path: it emits a notice or
# stays quiet, and it cannot fail a turn. It lives under ai/hooks/, so
# check-guard-messages does scan it, and it is EXEMPT there with a reason (same
# species as main-session-policy.sh / athena-inbox-poll.sh). The `Fix:` in its
# staleness notice is guidance for whoever is diagnosing the silence, not a
# denial.

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

# This hook lives in ai/hooks/ (so setup-hooks / check-hooks-registered wire it
# like every other registry hook, at the main checkout's path), but the scan
# logic lives in the athena:slack skill. Resolve the skill's lib/ from the repo
# root rather than a path relative to the hook, exactly as athena-inbox-poll.sh
# reaches its skill's bin/.
HOOK_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
AI_DIR="$(CDPATH= cd -- "$HOOK_DIR/.." && pwd)"
LIB_DIR="$AI_DIR/skills/athena:slack/lib"

# Private state, 0600/0700 by construction rather than a chmod a later edit can
# forget.
umask 077

# Nowhere to record anything -- including the fact that there was nowhere -- so
# the only honest move is the silent one.
if [ -z "${HOME:-}" ]; then exit 0; fi

# emit <text> -- the ONE well-formed object, and nothing else, ever. Reached
# only after the jq check below, so jq is always present here.
emit() {
  jq -cn --arg ctx "$1" \
    '{hookSpecificOutput:{hookEventName:"SessionStart",additionalContext:$ctx}}'
}

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

# The one thing this hook ever says about ITSELF, and only once the silence has
# stopped being momentary. Prints the warning TEXT (no framing) and stamps the
# warn marker, or prints nothing. Reachable ONLY when a token is configured:
# "no token" is a deliberate off state, not a breakage, and warning about it
# would nag every machine that has chosen not to set the skill up.
#
# A MISSING success marker counts as stale: there is no evidence of a prior
# success to call this failure momentary against, and a token that has never
# once worked is the most likely thing to be wrong -- so a never-working setup
# warns on its first attempt.
warn_text_if_stale() {
  if [ -f "$SUCCESS_MARKER" ] &&
     [ -n "$(find "$SUCCESS_MARKER" -mmin -"$STALE_MINUTES" 2>/dev/null)" ]; then
    return 0
  fi
  if [ -f "$WARN_MARKER" ] &&
     [ -n "$(find "$WARN_MARKER" -mmin -"$WARN_INTERVAL_MINUTES" 2>/dev/null)" ]; then
    return 0
  fi
  : > "$WARN_MARKER" 2>/dev/null || return 0
  printf 'athena-slack backstop has not succeeded in %sh, so a Slack outage may be going unheard. Fix: check %s for the reason, then run /athena:slack whoami to test the token.' \
    "$STALE_SUCCESS_HOURS" "$LOG"
}

# --- is the skill configured at all? ---------------------------------------
# Unconfigured is silent AND unlogged: it would be every session on every
# machine that has not set this up.
TOKEN_FILE="${SLACK_TOKEN_FILE:-$HOME/.claude/slack-bot-token}"
if [ -z "${SLACK_BOT_TOKEN:-}" ] && [ ! -f "$TOKEN_FILE" ]; then
  exit 0
fi

# --- the rate limit ---------------------------------------------------------
# A network call must not fire on every session start when several open in a
# burst. Inside the window: no output, no request.
if [ -f "$MARKER" ] && [ -n "$(find "$MARKER" -mmin -"$POLL_MINUTES" 2>/dev/null)" ]; then
  exit 0
fi

# Stamp the attempt marker BEFORE the network calls, not after. If Slack is
# hanging or erroring, an after-the-fact touch would leave the marker stale and
# fire a fresh scan on every session start; stamping the attempt caps the damage
# at one attempt per interval no matter how it goes.
mkdir -p "$(dirname "$MARKER")" 2>/dev/null || exit 0
: > "$MARKER" 2>/dev/null || exit 0

# jq is required to emit the JSON object safely. Without it there is no
# well-formed output to produce, so stay silent (logged) rather than print a
# bare or broken line into a JSON channel.
if ! command -v jq >/dev/null 2>&1; then
  log_failure "missing-tool:jq"
  exit 0
fi

# --- the scan ---------------------------------------------------------------
# curl missing is a failed poll, not a hard stop: the staleness warning can
# still fire (jq is present), which is the whole point of the backstop.
POLL_OK=0
DMS=0
MENTIONS=0

if ! command -v curl >/dev/null 2>&1; then
  log_failure "missing-tool:curl"
else
  HOOKTMP="$(mktemp -d 2>/dev/null)" || { log_failure "mktemp-failed"; HOOKTMP=""; }
  if [ -n "$HOOKTMP" ]; then
    trap 'rm -rf "$HOOKTMP"' EXIT INT TERM
    NEW="$HOOKTMP/new.jsonl"
    REASON="$HOOKTMP/reason"

    # The scan runs in a subshell so that lib/slack.sh's `set -e` discipline and
    # its exit-on-failure slack_die cannot take the hook down with them.
    # slack_die is redefined to record a fixed reason and fail the subshell; the
    # hook decides what to do, and the answer is always "exit 0 quietly".
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
      # The reason is written by slack_die from a fixed string plus a Slack
      # error code -- never a message body. Truncated anyway.
      why="$(cut -c1-120 < "$REASON" 2>/dev/null | tr -d '\n')"
      if [ -z "$why" ]; then why="scan-failed rc=$RC"; fi
      log_failure "scan: $why"
    else
      POLL_OK=1
      DMS="$(grep -c '"kind":"dm"' "$NEW" 2>/dev/null)"
      MENTIONS="$(grep -c '"kind":"mention"' "$NEW" 2>/dev/null)"
      case "$DMS" in ''|*[!0-9]*) DMS=0 ;; esac
      case "$MENTIONS" in ''|*[!0-9]*) MENTIONS=0 ;; esac
    fi
  fi
fi

# A completed scan is a success whether or not it found anything -- the question
# the marker answers is "is this backstop still working", not "did anything
# arrive". A FAILURE must NEVER stamp the success marker (it is the one the whole
# signal rests on). A success also clears the warn marker, so the next outage
# gets its own warning rather than being suppressed by this one.
if [ "$POLL_OK" -eq 1 ]; then
  : > "$SUCCESS_MARKER" 2>/dev/null || true
  rm -f "$WARN_MARKER" 2>/dev/null || true
fi

# --- what to say ------------------------------------------------------------
MESSAGE=""

TOTAL=$((DMS + MENTIONS))
if [ "$TOTAL" -gt 0 ]; then
  MESSAGE="$DMS new Slack DM(s) and $MENTIONS mention(s) for Athena — run /athena:slack read-inbox"
fi

# The staleness warning fires only on a run that did NOT succeed (a run that
# succeeded is, by construction, not stale). It travels as the SAME JSON object
# -- a bare text line into a JSON channel is exactly the malformed stdout this
# contract refuses.
if [ "$POLL_OK" -eq 0 ]; then
  WARN_TEXT="$(warn_text_if_stale)"
  if [ -n "$WARN_TEXT" ]; then
    MESSAGE="${MESSAGE:+${MESSAGE}
}${WARN_TEXT}"
  fi
fi

# Nothing to say: NO STDOUT AT ALL, exit 0.
[ -n "$MESSAGE" ] || exit 0

emit "$MESSAGE"
exit 0
