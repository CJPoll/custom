# frozen_string_literal: true

# slack_plugin_write_io -- the SIDE EFFECTS and the MANAGER of
# ai/hooks/slack-plugin-write-guard.sh (DND-2043). The rules live in
# ai/lib/slack_plugin_write.rb (pure); this file reads the hook payload and
# the session-mode variables, appends each deny to the deny log, and prints
# the PreToolUse decision.
#
# FAIL CLOSED: the hook is wired only for Slack MCP tools, so input it cannot
# evaluate (not JSON, not an object, no tool_name, an exception) is a deny,
# never a silent allow. The cost is that plugin READS are denied too while the
# guard is broken; the deny says so and names the fix. An allow is printed as
# nothing.

require "json"
require "time"
require "fileutils"
require_relative "slack_plugin_write"

module SlackPluginWriteIO
  module_function

  def log_path
    state = ENV.fetch("XDG_STATE_HOME", "")
    state = File.join(Dir.home, ".local", "state") if state.empty?
    File.join(state, "athena", "slack-plugin-write-guard.log")
  end

  # log(fields): one tab-separated line. Never the tool_input: a message body
  # is the owner's or a channel's text, not a record the guard needs.
  def log(fields)
    path = log_path
    FileUtils.mkdir_p(File.dirname(path))
    line = ([Time.now.utc.iso8601] + fields).map { |x| x.to_s.tr("\t\n", "  ") }.join("\t")
    File.open(path, "a", 0o600) { |f| f.puts(line) }
  rescue StandardError
    nil
  end

  def session_mode
    { entrypoint: ENV.fetch("CLAUDE_CODE_ENTRYPOINT", nil), attended: ENV.fetch("CLAUDE_CODE_SESSION_ATTENDED", nil) }
  end

  def deny_json(reason)
    JSON.generate(hookSpecificOutput: { hookEventName: "PreToolUse", permissionDecision: "deny",
                                        permissionDecisionReason: reason })
  end

  def parse(input)
    JSON.parse(input)
  rescue JSON::ParserError
    :unparseable
  end

  def main(input)
    payload = parse(input.to_s)
    if payload == :unparseable
      log(["deny", "fault", "?", "stdin is not JSON"])
      return deny_json(SlackPluginWrite.fault_reason("the hook input is not JSON"))
    end

    verdict = SlackPluginWrite.decide(payload, session_mode)
    return nil if verdict.nil?

    log(["deny", verdict[:tool], verdict[:caller], session_mode.values.map(&:inspect).join("/")])
    deny_json(verdict[:reason])
  rescue StandardError => e
    log(["deny", "fault", "?", "#{e.class}: #{e.message}"])
    deny_json(SlackPluginWrite.fault_reason("the checker raised #{e.class}"))
  end
end

if $PROGRAM_NAME == __FILE__
  out = SlackPluginWriteIO.main($stdin.read)
  puts out if out
end
