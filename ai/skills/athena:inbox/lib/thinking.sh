#!/usr/bin/env bash
# thinking.sh -- "Athena is thinking…" for the owner's Slack messages (DND-1783).
#
# A non-peek `read-inbox` of a Slack channel sets athena:slack's thinking
# status for each owner DM/thread line it delivers. It used to be a step the
# attendant had to remember after every read (athena:inbox-attend -> *Show that
# Athena is thinking*), and nothing enforced it: on 2026-10-02 about a dozen
# owner replies went out with no status before any of them. Now the read sets
# it, the way the read acks.
#
# Two halves:
#   thinking_targets  DOMAIN. Pure: the read document in, the conversations to
#                     set out. No effect.
#   thinking_set      MANAGER. Resolves the owner id (the private overlay) and
#                     calls the status tool (athena:slack/bin/status, the one
#                     place the Slack call lives) for each target.
#
# THE STATUS IS A COURTESY; THE READ IS THE JOB. Every failure here -- an owner
# id that does not resolve or is malformed, a status call that fails or times
# out, a line whose channel or ts is malformed -- prints a named stderr line
# with a Fix: and RETURNS 0. It never changes read-inbox's exit status, never
# writes stdout (stdout is the --json document), and runs only after the ack
# and after the consumer lock is released.
#
# The status text is the tool's default, never message content: everyone in
# the conversation sees it.

# The kinds that are a conversation with the bot. `im`/`mpim` are DMs, and a
# reply inside a DM thread is stamped `im` too (ai/contracts/athena-inbox.md
# -> *Line format* -> *Precedence*). `channel`, `mention` and `thread_reply`
# qualify only inside a thread: a top-level channel post has no thread for the
# status to show in. Anything else (`slack.interaction`, an unknown kind) never
# qualifies.
#
# thinking_targets [<owner-id>]   (stdin: the read document)
# Prints one "<channel>\t<thread parent ts>" line per conversation, deduped,
# for the owner's lines, in batch order (first line of each conversation
# first). With no owner id it prints the CANDIDATES (every qualifying line,
# any sender), so the caller can tell "no DM/thread line in this batch" from
# "there were some, and the owner could not be resolved".
thinking_targets() {
  local owner="${1-}"
  jq -r --arg owner "${owner}" '
    [ .messages[]?
      | ((.thread_ts // "") | tostring) as $tts
      | ((.kind // "") | tostring) as $k
      | select(($k == "im" or $k == "mpim")
               or ($tts != "" and ($k == "channel" or $k == "mention" or $k == "thread_reply")))
      | select($owner == "" or ((.user // "") | tostring) == $owner)
      | "\((.channel // "") | tostring)\t\(if $tts == "" then ((.ts // "") | tostring) else $tts end)" ]
    | reduce .[] as $t ([]; if index([$t]) then . else . + [$t] end)
    | .[]'
}

# thinking_valid_target <channel> <ts> -- a Slack conversation id and a Slack
# ts, by shape. A value malformed for its type is refused here rather than sent
# to Slack, where it would come back as a miss.
thinking_valid_target() {
  [[ "$1" =~ ^[CDG][A-Z0-9]+$ ]] && [[ "$2" =~ ^[0-9]+\.[0-9]+$ ]]
}

# thinking_valid_owner <id> -- a Slack user id, by shape. A well-formed but
# WRONG key would match no line and read as "the owner sent nothing"; a
# malformed one is refused, named, where it is produced.
thinking_valid_owner() {
  [[ "$1" =~ ^[UW][A-Z0-9]+$ ]]
}

# The status tool, and the overlay resolver. ATHENA_INBOX_STATUS_BIN replaces
# the status tool (the test seam: the suite points it at a stub, so no test
# ever calls Slack). Both defaults are resolved through the PHYSICAL path of
# this file, so a read through the ~/.claude/skills symlink (which links the
# whole ai/skills directory) finds ai/skills/athena:slack and ai/bin in the
# same tree. A per-skill symlink would resolve elsewhere; that fails loudly as
# the named "did not resolve" line below, never silently.
_thinking_skills_dir() { (cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P); }
thinking_status_bin() {
  if [ -n "${ATHENA_INBOX_STATUS_BIN:-}" ]; then
    printf '%s\n' "${ATHENA_INBOX_STATUS_BIN}"
  else
    printf '%s/athena:slack/bin/status\n' "$(_thinking_skills_dir)"
  fi
}
thinking_overlay_bin() { printf '%s/bin/private-overlay\n' "$(dirname "$(_thinking_skills_dir)")"; }

# The by-hand fallback every Fix: below names. It is the one place the command
# is documented.
_THINKING_BY_HAND='set it by hand before replying, with athena:slack/bin/status <channel> <thread_ts> (athena:slack -> The thinking status), and log status-failed in the attend ledger (athena:inbox-attend -> Show that Athena is thinking)'

# thinking_set   (stdin: the read document)
# Sets the status on each owner conversation in the batch. Always returns 0.
#
# Each call is capped at THINKING_CALL_TIMEOUT_S seconds (the status tool waits
# out a 429's Retry-After). After the first timeout the rest of the batch is
# skipped and named, so one slow Slack cannot hold the read N times over.
THINKING_CALL_TIMEOUT_S=30
thinking_set() {
  local doc candidates owner owner_err status_bin targets ch ts err rc
  local bad=0 skipped=0 timed_out=0
  doc="$(cat)"
  candidates="$(printf '%s' "${doc}" | thinking_targets "" 2>/dev/null)" || {
    printf 'athena:inbox: the thinking status was not set: the read document could not be scanned for DM/thread lines.\n' >&2
    printf '  Fix: the read and the ack are unaffected; %s.\n' "${_THINKING_BY_HAND}" >&2
    return 0
  }
  # No DM/thread line from anyone: nothing to set, and no owner lookup, so a
  # machine with no overlay reads its other traffic without noise.
  [ -n "${candidates}" ] || return 0

  if ! command -v timeout >/dev/null 2>&1; then
    printf 'athena:inbox: the thinking status was not set: `timeout` is not on PATH, and the status call is never run unbounded after a read.\n' >&2
    printf '  Fix: install coreutils (timeout). The read and the ack are unaffected; %s.\n' "${_THINKING_BY_HAND}" >&2
    return 0
  fi

  owner_err="$(mktemp)" || owner_err=/dev/null
  if ! owner="$("$(thinking_overlay_bin)" get slack .people.owner.user_id 2>"${owner_err}" </dev/null)" \
     || ! thinking_valid_owner "${owner}"; then
    printf 'athena:inbox: the thinking status was not set for %s DM/thread conversation(s): the owner'"'"'s Slack id %s, so no line can be told to be the owner'"'"'s.\n' \
      "$(printf '%s\n' "${candidates}" | wc -l | tr -d ' ')" \
      "$([ -s "${owner_err}" ] && printf 'did not resolve' || printf 'resolved to a value that is not a Slack user id (U... or W...)')" >&2
    sed 's/^/  /' "${owner_err}" >&2 2>/dev/null
    printf '  Fix: make ai/bin/private-overlay get slack .people.owner.user_id print the owner'"'"'s Slack user id (see any error above). The read and the ack are unaffected; %s.\n' "${_THINKING_BY_HAND}" >&2
    [ "${owner_err}" = /dev/null ] || rm -f "${owner_err}"
    return 0
  fi
  [ "${owner_err}" = /dev/null ] || rm -f "${owner_err}"

  targets="$(printf '%s' "${doc}" | thinking_targets "${owner}" 2>/dev/null)"
  [ -n "${targets}" ] || return 0
  status_bin="$(thinking_status_bin)"

  while IFS=$'\t' read -r ch ts; do
    if [ "${timed_out}" -eq 1 ]; then
      skipped=$((skipped + 1))
      continue
    fi
    if ! thinking_valid_target "${ch}" "${ts}"; then
      bad=$((bad + 1))
      continue
    fi
    # stdin is /dev/null: the tool must never read the remaining targets.
    err="$(timeout "${THINKING_CALL_TIMEOUT_S}" "${status_bin}" "${ch}" "${ts}" 2>&1 >/dev/null </dev/null)"; rc=$?
    [ "${rc}" -eq 0 ] && continue
    # Exit 4: the message was deleted before the call (DND-1804). Nothing is
    # wrong with the key or the tool, so this is named as its own outcome,
    # never as a failure to fix by hand.
    if [ "${rc}" -eq 4 ]; then
      printf 'athena:inbox: no thinking status on %s/%s: the message no longer exists in Slack (deleted before the status call).\n' "${ch}" "${ts}" >&2
      [ -z "${err}" ] || printf '%s\n' "${err}" | sed 's/^/  /' >&2
      printf '  Fix: nothing to set or retry. The read and the ack are unaffected; reply only if the deleted message still needs an answer.\n' >&2
      continue
    fi
    if [ "${rc}" -eq 124 ]; then
      timed_out=1
      err="timed out after ${THINKING_CALL_TIMEOUT_S}s${err:+; ${err}}"
    fi
    printf 'athena:inbox: the thinking status was not set on %s/%s (status exit %s).\n' "${ch}" "${ts}" "${rc}" >&2
    [ -z "${err}" ] || printf '%s\n' "${err}" | sed 's/^/  /' >&2
    printf '  Fix: resolve the status tool'"'"'s error above (%s). The read and the ack are unaffected; reply as normal, and log status-failed in the attend ledger (athena:inbox-attend -> Show that Athena is thinking).\n' "${status_bin}" >&2
  done <<<"${targets}"

  if [ "${skipped}" -gt 0 ]; then
    printf 'athena:inbox: the thinking status was not set on %s more owner conversation(s): skipped after the timeout above.\n' "${skipped}" >&2
    printf '  Fix: the read and the ack are unaffected; %s.\n' "${_THINKING_BY_HAND}" >&2
  fi
  if [ "${bad}" -gt 0 ]; then
    printf 'athena:inbox: the thinking status was not set for %s owner line(s) whose channel or ts is not a Slack id/ts.\n' "${bad}" >&2
    printf '  Fix: the producer wrote a malformed channel or ts; run inbox-doctor. The read and the ack are unaffected; %s.\n' "${_THINKING_BY_HAND}" >&2
  fi
  return 0
}
