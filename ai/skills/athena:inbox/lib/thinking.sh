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
# id that does not resolve, a status call that fails or hangs, a line whose
# channel or ts is malformed -- prints a named stderr line with a Fix: and
# RETURNS 0. It never changes read-inbox's exit status, never writes stdout
# (stdout is the --json document), and never runs before the ack.
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
# first). With no owner id it prints the CANDIDATES (every
# qualifying line, any sender), so the caller can tell "no DM/thread line in
# this batch" from "there were some, and the owner could not be resolved".
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

# The status tool, and the overlay resolver. ATHENA_INBOX_STATUS_BIN replaces
# the status tool (the test seam: the suite points it at a stub, so no test
# ever calls Slack). Both defaults are resolved through the PHYSICAL path, so a
# read through the ~/.claude/skills symlink finds the same tree.
_thinking_skills_dir() { (cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P); }
thinking_status_bin() {
  if [ -n "${ATHENA_INBOX_STATUS_BIN:-}" ]; then
    printf '%s\n' "${ATHENA_INBOX_STATUS_BIN}"
  else
    printf '%s/athena:slack/bin/status\n' "$(_thinking_skills_dir)"
  fi
}
thinking_overlay_bin() { printf '%s/bin/private-overlay\n' "$(dirname "$(_thinking_skills_dir)")"; }

# thinking_set   (stdin: the read document)
# Sets the status on each owner conversation in the batch. Always returns 0.
thinking_set() {
  local doc candidates owner owner_err status_bin targets ch ts err rc bad=0
  doc="$(cat)"
  candidates="$(printf '%s' "${doc}" | thinking_targets "" 2>/dev/null)" || {
    printf 'athena:inbox: the thinking status was not set: the read document could not be scanned for DM/thread lines.\n' >&2
    printf '  Fix: the read and the ack are unaffected. Set it by hand with athena:slack/bin/status <channel> <thread_ts> before replying (athena:inbox-attend -> Show that Athena is thinking).\n' >&2
    return 0
  }
  # No DM/thread line from anyone: nothing to set, and no owner lookup, so a
  # machine with no overlay reads its other traffic without noise.
  [ -n "${candidates}" ] || return 0

  owner_err="$(mktemp)" || owner_err=/dev/null
  if ! owner="$("$(thinking_overlay_bin)" get slack .people.owner.user_id 2>"${owner_err}")" || [ -z "${owner}" ]; then
    printf 'athena:inbox: the thinking status was not set for %s DM/thread conversation(s): the owner'"'"'s Slack id did not resolve, so no line can be told to be the owner'"'"'s.\n' \
      "$(printf '%s\n' "${candidates}" | wc -l | tr -d ' ')" >&2
    sed 's/^/  /' "${owner_err}" >&2 2>/dev/null
    printf '  Fix: resolve the overlay error above (ai/bin/private-overlay get slack .people.owner.user_id must print the id). The read and the ack are unaffected; set the status by hand before replying (athena:inbox-attend -> Show that Athena is thinking).\n' >&2
    [ "${owner_err}" = /dev/null ] || rm -f "${owner_err}"
    return 0
  fi
  [ "${owner_err}" = /dev/null ] || rm -f "${owner_err}"

  targets="$(printf '%s' "${doc}" | thinking_targets "${owner}" 2>/dev/null)"
  [ -n "${targets}" ] || return 0
  status_bin="$(thinking_status_bin)"

  while IFS=$'\t' read -r ch ts; do
    if ! thinking_valid_target "${ch}" "${ts}"; then
      bad=$((bad + 1))
      continue
    fi
    # Bounded: the status tool retries a 429 on Slack's Retry-After, and the
    # read has already been delivered and acked by the time this runs.
    if command -v timeout >/dev/null 2>&1; then
      err="$(timeout 30 "${status_bin}" "${ch}" "${ts}" 2>&1 >/dev/null)"; rc=$?
    else
      err="$("${status_bin}" "${ch}" "${ts}" 2>&1 >/dev/null)"; rc=$?
    fi
    [ "${rc}" -eq 0 ] && continue
    [ "${rc}" -ne 124 ] || err="timed out after 30s${err:+; ${err}}"
    printf 'athena:inbox: the thinking status was not set on %s/%s (status exit %s).\n' "${ch}" "${ts}" "${rc}" >&2
    [ -z "${err}" ] || printf '%s\n' "${err}" | sed 's/^/  /' >&2
    printf '  Fix: resolve the status tool'"'"'s error above (%s). The read and the ack are unaffected; reply as normal, and log it per athena:inbox-attend -> Show that Athena is thinking.\n' "${status_bin}" >&2
  done <<<"${targets}"

  if [ "${bad}" -gt 0 ]; then
    printf 'athena:inbox: the thinking status was not set for %s owner line(s) whose channel or ts is not a Slack id/ts.\n' "${bad}" >&2
    printf '  Fix: the producer wrote a malformed channel or ts; run inbox-doctor. The read and the ack are unaffected; set the status by hand with athena:slack/bin/status if you reply there.\n' >&2
  fi
  return 0
}
