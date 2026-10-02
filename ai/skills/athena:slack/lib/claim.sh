#!/usr/bin/env bash
# lib/claim.sh -- claiming a Slack thread for THIS session's project inbox
# (DND-491, DND-450 part 4). Sourced by bin/claim-thread, never run. Bash, like
# the athena:inbox libraries it builds on (they are sourced alongside it).
#
# WHY. A reply in a Slack thread is routed by the server to whichever inbox
# CLAIMED that thread (ai/contracts/athena-events.md -> *Thread replies route to
# the thread's claimant*). Nothing claimed a thread a session started with
# `post` or `dm`, so every reply fell through to the channel route (walt_ui's
# `slack` channel) and the session that asked the question never heard the
# answer. `post` and `dm` now run `claim-thread` on the thread they start, and
# `reply` and `dm --thread_ts` on an unclaimed thread they reply into
# (DND-1521).
#
# BUCKETS.
#   claim_parse_result, claim_refusal_kind, claim_server_words,
#   claim_reason_fix, claim_pick_slack_channel -- Domain:
#     pure string-in / string-out, tested directly.
#   claim_resolve_inbox -- Side Effect: reads git and the inbox registry through
#     athena:inbox's own adapters (fs.sh, inbox.sh), never a second copy of the
#     repo-identity rule.
#   The MCP call itself is athena:inbox lib/mcp.sh's `mcp_call_tool`: the
#     machine token is read from the inbox client's 0600 config at call time and
#     reaches curl only on stdin (DND-839). It is never in argv, the
#     environment, a file, or a log.
#
# A FAILED LOOKUP NEVER LOOKS LIKE AN EMPTY ONE. Every way a claim can fail has
# its own reason token, and a key that could not be computed is its own reason,
# never folded into `not-found`.

# The reason tokens, one per distinct cause. `mcp-error:<text>` is the one
# open-ended token: its suffix is the transport's or the server's own words.
CLAIM_REASONS="no-registry-entry registry-error no-slack-channel ambiguous-slack-channel no-identity no-token mcp-unregistered mcp-error not-found refused already-claimed invalid cwd-project-mismatch project-unresolved"

# claim_oneline <text> -- one bounded line: control characters (newlines
# included) become spaces, then at most 80 characters. Server words are printed
# outside any fence, so they are never allowed to forge a second line.
claim_oneline() {
  printf '%s' "$1" | LC_ALL=C tr '\000-\037\177' ' ' | cut -c1-80
}

# _claim_refusal_text <json-rpc-message>
#
# DOMAIN. The server's refusal text, or nothing when the answer carries no
# error. The athena server sends a refusal as Hermes' Error.execution: a
# JSON-RPC `error` whose message is the text (DND-1645). An `isError` tool
# result carrying the text is read the same way, so either server shape works
# and the landing order of a server change does not matter.
_claim_refusal_text() {
  printf '%s' "$1" | jq -r '
      if (.result.isError // false) then
        ([.result.content[]? | .text? // empty] | join(" ") | if . == "" then "a tool error" else . end)
      elif .error then (.error.message // "an MCP error" | tostring)
      else empty end' 2>/dev/null
}

# claim_refusal_kind <text>
#
# DOMAIN. One refusal text as a reason token, by EXACT token: the token alone,
# or the token followed by a colon (the server writes `<token>: ... Fix: ...`).
#   not found          -> not-found     (exactly that text, no colon)
#   refused[: ...]     -> refused
#   already_claimed[: ...] -> already-claimed
#   invalid[: ...]     -> invalid
#   anything else      -> mcp-error:<text>, so `already_claimedX`, `not found
#                         here` or a protocol error's `Invalid params` is never
#                         read as a refusal.
claim_refusal_kind() {
  local err
  # Trim edge whitespace so "not found\n" still reads as exactly "not found".
  err="$(printf '%s' "$1" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
  case "${err}" in
    "not found")                        printf 'not-found\n' ;;
    refused|refused:*)                  printf 'refused\n' ;;
    already_claimed|already_claimed:*)  printf 'already-claimed\n' ;;
    invalid|invalid:*)                  printf 'invalid\n' ;;
    *)                                  printf 'mcp-error:%s\n' "$(claim_oneline "${err}")" ;;
  esac
}

# claim_parse_result <json-rpc-message>
#
# DOMAIN. The tools/call answer for slack_thread_claim, as one status token on
# stdout:
#   claimed | already_yours                  -- the claim holds (success)
#   not-found | refused | already-claimed | invalid
#                                            -- the server's refusal, by kind,
#                                               from a JSON-RPC error or an
#                                               isError result alike
#   mcp-error:<words>                        -- anything else. An empty body,
#                                               non-JSON, a protocol error, or a
#                                               result with no known status is
#                                               NEVER read as claimed and NEVER
#                                               read as not-found.
# Status 0 for claimed/already_yours, 1 otherwise.
claim_parse_result() {
  local msg="$1" err status
  if [ -z "${msg}" ] || ! printf '%s' "${msg}" | jq -e 'type == "object"' >/dev/null 2>&1; then
    printf 'mcp-error:no-answer\n'; return 1
  fi
  err="$(_claim_refusal_text "${msg}")"
  if [ -n "${err}" ]; then
    claim_refusal_kind "${err}"; return 1
  fi
  status="$(printf '%s' "${msg}" | jq -r '
      (.result.structuredContent // (.result.content[0].text | fromjson? // null)) as $r
      | if ($r | type) == "object" and ($r.status | type) == "string" then $r.status else "" end' 2>/dev/null)"
  case "${status}" in
    claimed|already_yours) printf '%s\n' "${status}"; return 0 ;;
    "") printf 'mcp-error:no-status-in-result\n'; return 1 ;;
    *)  printf 'mcp-error:unexpected-status %s\n' "$(claim_oneline "${status}")"; return 1 ;;
  esac
}

# claim_server_words <json-rpc-message>
# DOMAIN. The server's own refusal words (a JSON-RPC error's message, or an
# isError tool result's text) as one bounded line, or nothing. claim-thread
# prints them as `server: ...` beside a refusal: they are the server's Fix,
# never message content.
claim_server_words() {
  local err
  err="$(_claim_refusal_text "$1")"
  [ -n "${err}" ] || return 0
  claim_oneline "${err}"; printf '\n'
}

# claim_reason_fix <reason-token> -- the Fix text for one failure reason.
# DOMAIN. Every reason in CLAIM_REASONS has its own text; an unknown token gets
# a text that says so rather than an empty Fix.
claim_reason_fix() {
  case "$1" in
    no-registry-entry)
      printf 'the session'"'"'s project (the source= and project= fields above; the lookup: line names the repo key) has no entry in $ATHENA_INBOX_ROOT/projects/, so there is no inbox for the replies. Check it with athena:inbox bin/inbox-status from that project. The post is not undone; re-run bin/claim-thread <channel> <ts> once fixed.' ;;
    registry-error)
      printf 'the inbox registry could not be read (unparseable or ambiguous entries; the athena:inbox refusal above names the cause). Run athena:inbox bin/inbox-doctor, fix the entry, then re-run bin/claim-thread <channel> <ts>.' ;;
    no-slack-channel)
      printf 'this project declares no Slack log channel (a kind:"log" channel with no producer, or producer "slack"), so there is no inbox for the replies. Declare one in ai/inbox/registry.json and run scripts/setup-inbox-registry --install, or pass --no-claim when no reply is expected.' ;;
    ambiguous-slack-channel)
      printf 'this project declares more than one Slack log channel, and the claim will not guess which one hears the replies. Leave exactly one in its registry entry, then re-run bin/claim-thread <channel> <ts>.' ;;
    no-identity)
      printf 'the bot identity (bot_id, team_id) could not be read from auth.test. Run athena:slack bin/whoami to test the bot token (see athena:slack -> Setup); do not rotate it yourself.' ;;
    no-token)
      printf 'this machine has no usable machine token in the inbox client config (~/.config/athena-inbox-client/config.json, .token). That is an owner-provisioned credential: report it rather than creating or editing it.' ;;
    mcp-unregistered)
      printf 'the athena MCP server is not registered for this project. Run scripts/add-athena-mcp from the main checkout, then re-run bin/claim-thread <channel> <ts>.' ;;
    mcp-error*)
      printf 'the claim call did not complete; the words after mcp-error: are the cause. Check the MCP registration and reachability with athena:inbox bin/inbox-doctor, then re-run bin/claim-thread <channel> <ts> -- a repeated claim of your own thread answers already_yours.' ;;
    not-found)
      printf 'the server does not know this bot for your owner, or the inbox is not one of this machine'"'"'s agent instances. Check the inbox with the athena MCP lookup_inbox; a missing server-side AgentInstance for it is owner-provisioned.' ;;
    refused)
      printf 'the server refused the claim; its own words are on the server: line above. The usual cause is an inbox that is not one of this machine'"'"'s live Slack inboxes (check it with the athena MCP lookup_inbox).' ;;
    already-claimed)
      printf 'another inbox already holds this thread, so its replies go there. A thread belongs to whoever claimed it first, and only the holding session can move it, by forwarding the conversation to this session with session_send and reroute_of_event_id (athena:slack SKILL.md -> Forwarding a misroute); ask it to, or start a new thread with bin/post or bin/dm if this session needs the replies.' ;;
    invalid)
      printf 'the channel must be a Slack conversation id ([CDG] followed by capitals and digits) and the ts a Slack ts (digits.digits) -- the ts of the thread'"'"'s PARENT message, as bin/post and bin/dm print it.' ;;
    cwd-project-mismatch)
      printf 'the shell cwd is inside a different inbox project from this session'"'"'s own (the athena:inbox refusal above names both), so nothing was claimed: a claim moves only when its holder forwards the conversation. cd into the session'"'"'s project (project= above) or a worktree of it and re-run bin/claim-thread <channel> <ts>; or, to claim for the cwd'"'"'s project on purpose (a subagent dispatched into another repo), re-run as CLAUDE_PROJECT_DIR=<that project'"'"'s dir> bin/claim-thread <channel> <ts>. The post is not undone.' ;;
    project-unresolved)
      printf 'this session'"'"'s project could not be named: CLAUDE_PROJECT_DIR or CLAUDE_PID is set but unusable (the athena:inbox refusal above names the value). Fix or unset it, then re-run bin/claim-thread <channel> <ts>; with neither set the shell cwd is used and the output says source=cwd.' ;;
    *)
      printf 'unrecognised claim failure reason "%s"; report it (claim.sh has no Fix for it).' "$(claim_oneline "$1")" ;;
  esac
  printf '\n'
}

# claim_pick_slack_channel <entry-json>
#
# DOMAIN. The one Slack log channel's `path` (the inbox_name) on stdout, status
# 0. A Slack channel is a `kind:"log"` channel whose `producer` is absent or
# "slack" -- a platform log channel (session mail, flaky lane) is never picked,
# and a filename pattern is never used to guess. Otherwise the reason token on
# stdout, status 1: `no-slack-channel` (zero) or `ambiguous-slack-channel`
# (more than one).
claim_pick_slack_channel() {
  local paths n
  paths="$(printf '%s' "$1" | jq -r '
      [.channels // {} | to_entries[] | .value
       | select(type == "object" and .kind == "log" and ((.producer // "slack") == "slack"))
       | .path // empty] | .[]' 2>/dev/null)"
  n="$(printf '%s' "${paths}" | grep -c . 2>/dev/null)"; n="${n:-0}"
  case "${n}" in
    0) printf 'no-slack-channel\n'; return 1 ;;
    1) printf '%s\n' "${paths}"; return 0 ;;
    *) printf 'ambiguous-slack-channel\n'; return 1 ;;
  esac
}

# claim_resolve_inbox <project-dir>
#
# SIDE EFFECT. This session's project Slack inbox name (e.g.
# custom-slack.jsonl) on stdout, status 0; otherwise the reason token on
# stdout, status 1. <project-dir> is the SESSION's project (claim-thread gets it
# from athena:inbox's inbox_session_dir, DND-1163), never a bare shell cwd.
# The identity rule is athena:inbox's `inbox_entry`: dir ->
# realpath of the git common dir -> the registry entry naming it. A worktree
# resolves its main checkout's entry. Not in a repo, or no entry:
# `no-registry-entry`. An unreadable or ambiguous registry: `registry-error`
# (athena:inbox's own refusal is on stderr).
claim_resolve_inbox() {
  local cwd="$1" entry rc
  case "${cwd}" in /*) ;; *) printf 'no-registry-entry\n'; return 1 ;; esac
  entry="$(inbox_entry "${cwd}")"; rc=$?
  case "${rc}" in
    0) ;;
    1) printf 'no-registry-entry\n'; return 1 ;;
    *) printf 'registry-error\n'; return 1 ;;
  esac
  [ -n "${entry}" ] || { printf 'no-registry-entry\n'; return 1; }
  descriptor_validate "${entry}" || { printf 'registry-error\n'; return 1; }
  claim_pick_slack_channel "${entry}"
}
