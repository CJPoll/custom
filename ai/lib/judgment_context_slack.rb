# frozen_string_literal: true

# ai/lib/judgment_context_slack.rb -- SIDE EFFECT (adapter): read what one
# JudgmentContext request names from Slack, as ATHENA'S OWN BOT (DND-1047).
#
# It runs the athena:slack skill's read bins (whoami, read-channel,
# read-thread), which carry only the bot token (xoxb-, refused otherwise),
# never the owner's account. Reads only: no post, no reaction, no claim.
#
# It returns raw reader messages plus Athena's own ids; the caller (a
# manager) hands them to JudgmentContext.build. Every failure is
# [:error, reason], never an empty read: a caller must be able to tell
# "nobody wrote anything in the hour before" from "could not look"
# (ai/CLAUDE.md, *A failed lookup must never look like an empty one*).
#
# Deliberately gem-free (stdlib only).

require "json"
require "open3"
require_relative "judgment_context"

class JudgmentContextSlack
  TIMEOUT_S = 30
  REASON_CAP = 200

  # bin_dir: the athena:slack skill's bin/ (holds whoami, read-channel,
  # read-thread). timeout_s bounds each reader run.
  def initialize(bin_dir, timeout_s: TIMEOUT_S)
    @bin_dir = bin_dir
    @timeout_s = timeout_s
    @athena_ids = nil
  end

  # read(request) -> [:ok, messages, athena_ids] | [:error, reason].
  # request: a JudgmentContext.request with a source ("channel" or "thread").
  def read(req)
    ids = athena_ids
    return ids if ids.first == :error

    out = run(argv(req))
    return out if out.first == :error

    messages = parse(out.last)
    return messages if messages.first == :error

    [:ok, messages.last, ids.last]
  end

  private

  def argv(req)
    if req["source"] == "thread"
      [bin("read-thread"), req["channel"], req["thread_ts"], "--json"]
    else
      [bin("read-channel"), req["channel"], "--since", req["oldest"], "--before", req["latest"], "--json"]
    end
  end

  # athena_ids -> [:ok, [user_id, bot_id]] | [:error, reason]. Only a success
  # is remembered: one transient whoami failure must not blank every later row.
  def athena_ids
    return @athena_ids if @athena_ids

    out = run([bin("whoami")])
    return [:error, "could not resolve Athena's bot user id: #{out.last}"] if out.first == :error

    user = out.last[/^user_id:\s*(\S+)/, 1]
    bot = out.last[/^bot_id:\s*(\S+)/, 1]
    return [:error, "whoami printed no usable user_id (got #{user.inspect})"] unless user && JudgmentContext::USER_ID.match?(user)

    ids = [user]
    ids << bot if bot && JudgmentContext::AUTHOR_ID.match?(bot)
    @athena_ids = [:ok, ids]
  end

  def bin(name)
    File.join(@bin_dir, name)
  end

  # run(argv) -> [:ok, stdout] | [:error, reason]. stdin is closed, so a
  # reader can never wait on the terminal the owner is typing into.
  def run(argv)
    return [:error, "the Slack reader #{argv.first} is missing or not executable"] unless File.executable?(argv.first)

    out, err, status = Open3.capture3("timeout", @timeout_s.to_s, *argv, stdin_data: "")
    return [:ok, out] if status.success?
    return [:error, "the Slack read timed out after #{@timeout_s}s"] if status.exitstatus == 124

    [:error, reason(err, status)]
  rescue SystemCallError => e
    [:error, "could not run #{File.basename(argv.first)}: #{e.class}"]
  end

  # reason(stderr, status) -> the reader's own last "athena-slack: ..." line
  # (a fixed reason plus Slack's error code; it never carries a token or a
  # message body), else the exit status. The caller sanitises it for display.
  def reason(err, status)
    line = err.to_s.scrub("?").lines.map(&:strip).reject(&:empty?).reverse.find { |l| l.start_with?("athena-slack: ") }
    text = line ? line.delete_prefix("athena-slack: ") : "the Slack reader exited #{status.exitstatus}"
    text[0, REASON_CAP]
  end

  # parse(stdout) -> [:ok, [message]] | [:error, reason]. One JSON object per
  # line; blank lines are skipped.
  def parse(out)
    messages = out.to_s.scrub("?").lines.map(&:strip).reject(&:empty?).map do |line|
      row = JSON.parse(line)
      return [:error, "the Slack reader printed a line that is not a JSON object"] unless row.is_a?(Hash)

      row
    end
    [:ok, messages]
  rescue JSON::ParserError
    [:error, "the Slack reader printed a line that is not JSON"]
  end
end
