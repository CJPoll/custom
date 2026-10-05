# frozen_string_literal: true

# slack_plugin_write -- the pure rules of ai/hooks/slack-plugin-write-guard.sh
# (DND-2043). No I/O: ai/lib/slack_plugin_write_io.rb reads the payload and the
# environment, logs, and prints the decision.
#
# The Slack plugin (slack@claude-plugins-official, a remote MCP server at
# https://mcp.slack.com/mcp) acts with the OWNER's OAuth user token. Every
# write through it reads in Slack as Cody, and a post into the owner-Athena
# DM reads on Athena's inbox as the owner's own message. Athena's own words
# go through the Athena bot (athena:slack). These rules decide which plugin
# calls an agent may make.

require_relative "merge_role"

module SlackPluginWrite
  # A tool on a Slack MCP server: the plugin's own (`mcp__plugin_slack_slack__`),
  # the same server through another plugin (`mcp__plugin_<p>_slack__`), a
  # user-configured server named slack, or a claude.ai Slack connector. The
  # capture is the server's tool name.
  SCOPE = /\Amcp__(?:plugin_.+_|claude_ai_)?slack__(.+)\z/i

  # The plugin's READ-ONLY tools, from the tool list Claude Code presented for
  # slack@claude-plugins-official 1.3.0 on 2026-10-05 (27 tools: these 14
  # reads and 13 writes). The list is the server's, not on disk, so this is
  # an allow-list: a tool not named here is treated as a write and denied.
  # A tool the server adds later is therefore denied until someone confirms
  # it reads only and adds it here (fail closed). Never list a tool that
  # sends, posts, reacts, creates, updates, schedules, drafts or uploads.
  READ_TOOLS = %w[
    slack_get_reactions
    slack_list_channel_members
    slack_list_user_channels
    slack_read_canvas
    slack_read_channel
    slack_read_file
    slack_read_list
    slack_read_thread
    slack_read_user_profile
    slack_search_channels
    slack_search_emojis
    slack_search_public
    slack_search_public_and_private
    slack_search_users
  ].freeze

  FIX = "Fix: say it as Athena, never as Cody. Post, reply, react, update or upload through the athena MCP " \
        "(mcp__athena__slack_post, slack_update, slack_react, slack_upload, slack_open_dm) or the athena:slack " \
        "skill's bin/ scripts (post, reply, react, dm, upload); both act as the Athena bot. Slack plugin READS " \
        "(read_*, search_*, list_*, get_reactions) stay allowed. If this tool only reads and is new to the " \
        "plugin, add it to READ_TOOLS in ai/lib/slack_plugin_write.rb; never add a tool that writes."

  module_function

  # server_tool(tool_name) -> the Slack server's tool name, or nil when the
  # tool is not on a Slack MCP server (out of scope: allowed).
  def server_tool(tool_name)
    m = SCOPE.match(tool_name.to_s)
    m && m[1]
  end

  def read_only?(server_tool)
    READ_TOOLS.include?(server_tool.to_s)
  end

  # attended_top_level?(agent_id, agent_type, mode) -> true only for a session
  # with a person at it and no subagent running: MergeRole's top-level test
  # AND its attended test (CLAUDE_CODE_ENTRYPOINT=cli and
  # CLAUDE_CODE_SESSION_ATTENDED=1). A headless top-level session (`claude
  # -p`, a cron runner) is not: nobody is there to own the words.
  def attended_top_level?(agent_id, agent_type, mode)
    MergeRole.top_level?(agent_id, agent_type, mode) &&
      MergeRole.attended?(mode[:entrypoint], mode[:attended])
  end

  # decide(payload, mode) -> nil (allow) or {tool:, caller:, reason:} (deny).
  # payload is the parsed hook JSON; mode is {entrypoint:, attended:}, the raw
  # variable values (nil when unset). A payload that is not a Hash, or has no
  # tool_name, is denied: the hook is wired only for Slack tools, so a call it
  # cannot read is a Slack call it cannot clear.
  def decide(payload, mode)
    return deny("?", "?", "the hook input is not a JSON object") unless payload.is_a?(Hash)

    tool = payload["tool_name"]
    return deny("?", caller_label(payload), "the hook input has no tool_name") if tool.to_s.empty?

    st = server_tool(tool)
    return nil if st.nil? || read_only?(st)

    agent_id = payload.key?("agent_id") ? payload["agent_id"] : nil
    return nil if attended_top_level?(agent_id, payload["agent_type"], mode)

    deny(tool, caller_label(payload),
         "#{tool} writes to Slack as the OWNER (the plugin uses Cody's OAuth user token), and " \
         "#{caller_label(payload)} is not an attended top-level session (#{MergeRole.mode_seen(mode)}).")
  end

  def caller_label(payload)
    return "an unknown caller" unless payload.is_a?(Hash)

    type = payload["agent_type"].to_s
    if payload.key?("agent_id")
      "a subagent (agent_type #{type.empty? ? '<empty>' : type})"
    elsif type.empty?
      "a top-level session"
    else
      "a top-level --agent #{type} session"
    end
  end

  def deny(tool, caller, why)
    { tool: tool.to_s, caller: caller, reason: "slack-plugin-write-guard (DND-2043): #{why} #{FIX}" }
  end

  # fault_reason(what) -> the deny text for input the hook could not evaluate.
  def fault_reason(what)
    "slack-plugin-write-guard (DND-2043): #{what}; a Slack plugin call it cannot evaluate is denied " \
      "(fail closed). #{FIX} If the guard itself is broken, run ai/hooks/slack-plugin-write-guard.sh " \
      "--self-test and fix what it names."
  end
end
