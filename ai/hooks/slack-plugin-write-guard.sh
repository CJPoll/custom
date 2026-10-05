#!/usr/bin/env bash
# slack-plugin-write-guard.sh -- PreToolUse hook (registry matcher
# `mcp__([^_]|_(?!_))*[Ss][Ll][Aa][Cc][Kk]([^_]|_(?!_))*__.*`): deny the Slack
# plugin's WRITE tools to every agent session (DND-2043).
#
# WHY: the Slack plugin (slack@claude-plugins-official, remote MCP server
# https://mcp.slack.com/mcp) acts with the OWNER's OAuth user token. A
# message, reaction, canvas, Slack List, channel or upload made through it
# reads in Slack as Cody Poll, and a post into the owner-Athena DM reads on
# Athena's inbox as the owner's own message. athena:slack forbade that use in
# prose only (*Two Slack identities*); nothing denied it. Measured from the
# session transcripts on 2026-10-05: subagents made 9 slack_send_message calls
# through the plugin (2026-08-31, 2026-09-01), and one headless `claude -p`
# made 1 (2026-09-07).
#
# WHAT IS DENIED: a tool whose MCP server segment (between `mcp__` and the
# next `__`) contains "slack" in any case: this plugin, the same server
# through another plugin (slack-by-salesforce), a user server such as slack or
# slack-work, a claude.ai Slack connector. `mcp__athena__slack_post` is out of
# scope (server athena). Such a tool is denied unless it is one of the 14
# listed reads (SlackPluginWrite::READ_TOOLS) or the caller is an attended
# top-level session. The list is an ALLOW-list of reads, so a tool the server
# adds later is denied, even a read_* one, until it is listed. The plugin's
# list is the server's, not on disk; the list and its source are in
# ai/lib/slack_plugin_write.rb.
#
# WHO MAY WRITE: only an attended top-level session: the payload has no
# agent_id key, and Claude Code's mode variables both say attended
# (CLAUDE_CODE_ENTRYPOINT=cli, CLAUDE_CODE_SESSION_ATTENDED=1; MergeRole's
# attended?, measured on 2.1.286 in DND-1934). That includes an interactive
# `claude --agent X` (no agent_id). DECISION: the attended session keeps the
# plugin because a need was measured: one attended session made 25
# slack_send_message calls through it (2026-08-26), and the plugin's own
# commands (slack:draft-announcement, slack:standup) post as the person who
# runs them. Denied: every subagent (it carries agent_id, attended parent or
# not), an agent_id key that is empty or null, a headless `claude -p`
# (sdk-cli + 0, with or without --agent), a cron runner, and any session
# whose mode the guard cannot tell (a missing or half signal).
#
# FAIL CLOSED: the matcher sends only Slack-server tools here, so input the
# guard cannot evaluate is a deny: stdin that is not a JSON object or has no
# tool_name, no ruby on PATH, a checker that crashes or exits without a
# decision. Fail-open would re-open the impersonation silently; fail-closed
# costs the plugin's reads while the guard is broken, and the deny says why
# and names the fix. (merge-role-guard and worktree-escape-guard fail open
# because they sit on every Bash call; this one sits on one MCP server.)
#
# RESIDUALS: an attended session can still write as Cody (by design, above).
# An interactive `claude` started in a terminal multiplexer, by a subagent or
# a fleet launcher, reads as attended (merge-role-guard names the same
# residual). A checker that hangs past Claude Code's hook timeout is a
# non-blocking hook error, so the call runs. A Slack server whose name lacks
# "slack", and a call to the Slack Web API with Cody's token outside MCP, are
# not tools this hook sees.
#
# Every deny is appended to
# ${XDG_STATE_HOME:-~/.local/state}/athena/slack-plugin-write-guard.log (tool,
# caller, mode; never the message text), mode 0600.
#
# --self-test runs ai/hooks/slack-plugin-write-guard.self-test.sh.

SELF="$(realpath -- "${BASH_SOURCE[0]}" 2>/dev/null || printf '%s' "${BASH_SOURCE[0]}")"
HOOK_DIR="$(dirname -- "${SELF}")"

case "${1:-}" in
  --self-test) exec "${HOOK_DIR}/slack-plugin-write-guard.self-test.sh" ;;
  -h|--help)
    cat <<'EOF'
slack-plugin-write-guard.sh -- Claude Code PreToolUse hook (matcher: an MCP
tool whose server segment contains "slack", any case). Reads the hook JSON on
stdin. Denies every such tool but the 14 listed reads (send, schedule,
draft, react, canvas, Slack List edits, conversation, upload, and any tool
not listed) unless the caller is an attended top-level session (no agent_id;
CLAUDE_CODE_ENTRYPOINT=cli and CLAUDE_CODE_SESSION_ATTENDED=1). The plugin
uses the owner's user token, so its writes read as the owner; the deny points
to the Athena bot (mcp__athena__slack_post, athena:slack). Input it cannot
evaluate is denied (fail closed). Denies are logged to
$XDG_STATE_HOME/athena/slack-plugin-write-guard.log.
  --self-test   run ai/hooks/slack-plugin-write-guard.self-test.sh
EOF
    exit 0 ;;
esac

# deny_static <what>: the deny printed when the ruby checker cannot answer.
# Plain text only (no quotes or backslashes), so the JSON needs no escaping.
deny_static() {
  _log="${XDG_STATE_HOME:-${HOME}/.local/state}/athena/slack-plugin-write-guard.log"
  mkdir -p -- "$(dirname -- "${_log}")" 2>/dev/null
  (umask 077 && printf '%s\tdeny\tfault\t?\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" >>"${_log}") 2>/dev/null
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"slack-plugin-write-guard (DND-2043): %s; a Slack plugin call it cannot evaluate is denied (fail closed). Fix: post as Athena through mcp__athena__slack_post or the athena:slack skill bin/ scripts, never through the Slack plugin; then repair the guard: run ai/hooks/slack-plugin-write-guard.sh --self-test and fix what it names."}}\n' "$1"
}

INPUT=$(cat 2>/dev/null) || { deny_static "stdin could not be read"; exit 0; }

command -v ruby >/dev/null 2>&1 || { deny_static "no ruby on PATH"; exit 0; }
OUT=$(printf '%s' "${INPUT}" | ruby "${HOOK_DIR}/../lib/slack_plugin_write_io.rb" 2>/dev/null)
RC=$?
if [ "${RC}" -ne 0 ]; then
  deny_static "the checker exited ${RC}"
  exit 0
fi
[ -n "${OUT}" ] && printf '%s\n' "${OUT}"
exit 0
