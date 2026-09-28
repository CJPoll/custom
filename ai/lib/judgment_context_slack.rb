# frozen_string_literal: true

# ai/lib/judgment_context_slack.rb -- SIDE EFFECT (adapter): read one
# JudgmentContext request from Slack as ATHENA'S OWN BOT (DND-1047).
#
# It runs the athena:slack skill's read bins (read-channel, read-thread,
# whoami), which carry only the bot token (xoxb-, refused otherwise), never
# the owner's account. Reads only: no post, no reaction, no claim.
#
# Every failure is a context with status "unavailable" and a reason, never an
# empty context: a caller must be able to tell "nobody wrote anything in the
# hour before" from "could not look" (ai/CLAUDE.md, *A failed lookup must
# never look like an empty one*).
#
# Deliberately gem-free (stdlib only).

require "json"
require "open3"
require_relative "judgment_context"

class JudgmentContextSlack
  TIMEOUT_S = 30
  REASON_CAP = 200

  # bin_dir: the athena:slack skill's bin/ (holds read-channel, read-thread,
  # whoami). owner: the owner's Slack user id.
  def initialize(bin_dir, owner, timeout_s: TIMEOUT_S)
    @bin_dir = bin_dir
    @owner = owner
    @timeout_s = timeout_s
    @athena = nil
  end

  # fetch(anchor) -> a JudgmentContext context for that message.
  def fetch(anchor)
    req = JudgmentContext.request(anchor)
    return JudgmentContext.unavailable(req, req["error"]) if req["source"].nil?

    athena = athena_id
    return JudgmentContext.unavailable(req, athena.last) if athena.first == :error

    read = run(argv(req))
    return JudgmentContext.unavailable(req, read.last) if read.first == :error

    messages = parse(read.last)
    return JudgmentContext.unavailable(req, messages.last) if messages.first == :error

    JudgmentContext.build(req, messages.last, owner: @owner, athena: athena.last)
  end

  private

  def argv(req)
    if req["source"] == "thread"
      [bin("read-thread"), req["channel"], req["thread_ts"], "--json"]
    else
      [bin("read-channel"), req["channel"], "--since", req["oldest"], "--before", req["latest"], "--limit", req["limit"].to_s, "--json"]
    end
  end

  # athena_id -> [:ok, "U..."] | [:error, reason]. Asked once per process:
  # the bot's own user id is what marks a message as Athena's.
  def athena_id
    @athena ||= begin
      out = run([bin("whoami")])
      if out.first == :error
        [:error, "could not resolve Athena's bot user id: #{out.last}"]
      else
        id = out.last[/^user_id:\s*(\S+)/, 1]
        id ? [:ok, id] : [:error, "whoami printed no user_id"]
      end
    end
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
  # message body), else the exit status.
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
