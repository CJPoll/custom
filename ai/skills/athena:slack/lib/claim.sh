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
# answer. `post` and `dm` now run `claim-thread` on the thread they start.
#
# BUCKETS.
#   claim_parse_result, claim_reason_fix, claim_pick_slack_channel -- Domain:
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
CLAIM_REASONS="no-registry-entry registry-error no-slack-channel ambiguous-slack-channel no-identity no-token mcp-unregistered mcp-error not-found refused already-claimed invalid"

# claim_oneline <text> -- one bounded line: control characters (newlines
# included) become spaces, then at most 80 characters. Server words are printed
# outside any fence, so they are never allowed to forge a second line.
claim_oneline() {
  printf '%s' "$1" | LC_ALL=C tr '\000-\037\177' ' ' | cut -c1-80
}

# claim_parse_result <json-rpc-message>
#
# DOMAIN. The tools/call answer for slack_thread_claim, as one status token on
# stdout:
#   claimed | already_yours                  -- the claim holds (success)
#   not-found | refused | already-claimed | invalid
#                                            -- the server's refusal, by kind
#   mcp-error:<words>                        -- anything else. An empty body,
#                                               non-JSON, a JSON-RPC error, or a
#                                               result with no known status is
#                                               NEVER read as claimed and NEVER
#                                               read as not-found.
# Status 0 for claimed/already_yours, 1 otherwise.
claim_parse_result() {
  local msg="$1" err status
  if [ -z "${msg}" ] || ! printf '%s' "${msg}" | jq -e 'type == "object"' >/dev/null 2>&1; then
    printf 'mcp-error:no-answer\n'; return 1
  fi
  err="$(printf '%s' "${msg}" | jq -r '
      if (.result.isError // false) then ([.result.content[]? | .text? // empty] | join(" ") | if . == "" then "a tool error" else . end)
      else empty end' 2>/dev/null)"
  if [ -n "${err}" ]; then
    # Trim edge whitespace so "not found\n" still reads as exactly "not found".
    err="$(printf '%s' "${err}" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    case "${err}" in
      "not found")          printf 'not-found\n' ;;
      refused:*)            printf 'refused\n' ;;
      already_claimed:*)    printf 'already-claimed\n' ;;
      invalid:*)            printf 'invalid\n' ;;
      *)                    printf 'mcp-error:%s\n' "$(claim_oneline "${err}")" ;;
    esac
    return 1
  fi
  err="$(printf '%s' "${msg}" | jq -r 'if .error then (.error.message // "an MCP error" | tostring) else empty end' 2>/dev/null)"
  if [ -n "${err}" ]; then
    printf 'mcp-error:%s\n' "$(claim_oneline "${err}")"; return 1
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
# DOMAIN. The server's own refusal words (an isError tool result's text) as one
# bounded line, or nothing. claim-thread prints them as `server: ...` beside a
# refusal: they are the server's Fix, never message content.
claim_server_words() {
  local err
  err="$(printf '%s' "$1" | jq -r 'if (.result.isError // false) then ([.result.content[]? | .text? // empty] | join(" ")) else empty end' 2>/dev/null)"
  [ -n "${err}" ] || return 0
  claim_oneline "${err}"; printf '\n'
}

# claim_reason_fix <reason-token> -- the Fix text for one failure reason.
# DOMAIN. Every reason in CLAIM_REASONS has its own text; an unknown token gets
# a text that says so rather than an empty Fix.
claim_reason_fix() {
  case "$1" in
    no-registry-entry)
      printf 'run from inside the project whose session should hear the replies: the inbox is found from the cwd (realpath of git rev-parse --git-common-dir) and its entry in $ATHENA_INBOX_ROOT/projects/. Check it with athena:inbox bin/inbox-status. The post is not undone; re-run bin/claim-thread <channel> <ts> once fixed.' ;;
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
      printf 'another inbox already holds this thread, so its replies go there. A thread belongs to whoever claimed it first; start a new thread with bin/post or bin/dm if this session needs the replies.' ;;
    invalid)
      printf 'the channel must be a Slack conversation id ([CDG] followed by capitals and digits) and the ts a Slack ts (digits.digits) -- the ts of the thread'"'"'s PARENT message, as bin/post and bin/dm print it.' ;;
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

# claim_resolve_inbox <cwd>
#
# SIDE EFFECT. This session's project Slack inbox name (e.g.
# custom-slack.jsonl) on stdout, status 0; otherwise the reason token on
# stdout, status 1. The identity rule is athena:inbox's `inbox_entry`: cwd ->
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
