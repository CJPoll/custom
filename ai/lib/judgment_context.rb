# frozen_string_literal: true

# ai/lib/judgment_context.rb -- DOMAIN (pure): the conversation context of one
# Slack message (DND-1047).
#
# A routing label often cannot be read off one message: "yes, do that" means
# nothing without what came before it. This module says WHAT to read for a
# message and shapes what was read. It does no I/O; the adapter
# ai/lib/judgment_context_slack.rb reads Slack as Athena's own bot, and the
# caller decides where the context goes. Today that is only the owner's
# terminal, in judgment-label --confirm. Nothing here egresses.
#
# The window is the one DND-1048's design ("slack-routing-v2", 2026-09-28)
# specifies for the routing judge's context. That judge is not built yet; when
# it is, it builds its input with this module (or a parity check pins the two
# together), so the owner labels with what the judge will see:
#   - same channel as the message; top-level messages only (thread_ts nil or
#     equal to ts); ts within WINDOW_S before it; oldest first; at most
#     MAX_MESSAGES;
#   - each message carries its ROLE and what the JUDGE will see of it (D7):
#       owner  -> "text"          the owner's own text, capped at JUDGE_TEXT_CAP
#       athena -> "session_label" Athena's own post, as a session label only
#       other  -> "none"          anyone else, never (even in an mpim)
# A message inside a thread gets its thread instead: the parent plus the latest
# replies before it. The judge never sees thread context, so every thread
# message is judge "none". judgment-label never asks for a thread (its roots
# are top-level); the thread path is kept for DND-1048, which judges replies.
# Nothing after the message is context: the label is what the sender meant
# then, not what happened next.
#
# The two steps:
#   request(anchor) -> which conversation, which window.
#   build(request, messages, owner:, athena:) -> a context (athena: the bot's
#   ids, its user id and bot id, since a post can carry either);
#   unavailable(request, reason) -> one that says why there is none.
# A context is never silently empty: "no earlier message in the window"
# (status ok, messages []) and "could not read" (status unavailable, reason)
# are different values.
#
# Context shape (string keys, plain JSON):
#   {"status"    => "ok" | "unavailable",
#    "source"    => "channel" | "thread" | nil,   # nil: the anchor was unusable
#    "channel"   => the anchor's channel, as given,
#    "anchor_ts" => the message's own ts,
#    "window"    => {"oldest", "latest", "max_messages"} (channel) or
#                   {"thread_ts", "max_messages"} (thread) or nil,
#    "messages"  => [{"ts", "user", "name", "text", "thread_ts", "role", "judge"}],
#                   oldest first, every one strictly before the anchor,
#    "omitted"   => earlier messages in the window dropped by the cap,
#    "in_thread" => channel-read messages dropped for being thread replies,
#    "malformed" => reader messages with no usable ts, dropped and counted,
#    "reason"    => nil | why the context is unavailable}
#
# Trust: every message is untrusted input. This module copies text; it never
# interprets it.

module JudgmentContext
  MAX_MESSAGES = 6
  WINDOW_S = 60 * 60
  # The judge sees at most this much of the owner's own earlier text (DND-1048).
  JUDGE_TEXT_CAP = 500
  CHANNEL_ID = /\A[CDG][A-Z0-9]{2,30}\z/
  USER_ID = /\A[UW][A-Z0-9]{2,30}\z/
  # A post names its author by user id, or by bot id when it has no user.
  AUTHOR_ID = /\A[UWB][A-Z0-9]{2,30}\z/
  SLACK_TS = /\A\d{10}\.\d{6}\z/
  MESSAGE_KEYS = %w[ts user name text thread_ts].freeze
  JUDGE_VIEW = { "owner" => "text", "athena" => "session_label", "other" => "none" }.freeze

  module_function

  # request(anchor) -> request Hash. anchor: {channel:, ts:, thread_ts:}
  # (symbol keys, as judgment-label parses a slack inbox line). An unusable
  # anchor still yields a request, carrying the reason, so build() turns it
  # into an unavailable context instead of an empty one.
  def request(anchor)
    channel = anchor[:channel]
    ts = anchor[:ts]
    thread_ts = anchor[:thread_ts]
    base = { "channel" => channel, "anchor_ts" => ts }
    return base.merge("source" => nil, "error" => "the root has no usable channel id (got #{channel.inspect})") unless channel.is_a?(String) && CHANNEL_ID.match?(channel)
    return base.merge("source" => nil, "error" => "the root has no usable Slack ts (got #{ts.inspect})") unless ts.is_a?(String) && SLACK_TS.match?(ts)
    # A thread_ts that is present but malformed is an error, never "top-level":
    # read as top-level, it would show the wrong conversation as "shown".
    return base.merge("source" => nil, "error" => "the root has an unusable thread_ts (got #{thread_ts.inspect})") unless thread_ts.nil? || (thread_ts.is_a?(String) && SLACK_TS.match?(thread_ts))

    if thread_ts && thread_ts != ts
      base.merge("source" => "thread", "thread_ts" => thread_ts)
    else
      # The WHOLE window is read (no count limit): a window of one hour is
      # bounded, and only a full read makes "omitted" exact, since thread
      # broadcasts would otherwise take slots the cap is counted against.
      base.merge("source" => "channel", "oldest" => shift(ts, -WINDOW_S), "latest" => ts)
    end
  end

  # build(request, messages, owner:, athena:) -> context. messages: what the
  # reader returned, Hashes with string keys, in any order. owner and athena
  # are Slack user ids: the owner's, and Athena's own bot user. A role is
  # decided by id only, never by a display name a message could carry.
  def build(req, messages, owner:, athena:)
    return unavailable(req, req["error"]) if req["source"].nil?
    return unavailable(req, "the owner's Slack user id is unusable (got #{owner.inspect})") unless owner.is_a?(String) && USER_ID.match?(owner)

    athena = Array(athena)
    unless !athena.empty? && athena.all? { |id| id.is_a?(String) && AUTHOR_ID.match?(id) } && athena.any? { |id| USER_ID.match?(id) }
      return unavailable(req, "Athena's Slack bot ids are unusable (got #{athena.inspect})")
    end

    usable, malformed = messages.partition { |m| m.is_a?(Hash) && m["ts"].is_a?(String) && SLACK_TS.match?(m["ts"]) }
    before = usable.select { |m| key(m["ts"]) < key(req["anchor_ts"]) }.uniq { |m| m["ts"] }.sort_by { |m| key(m["ts"]) }
    kept, omitted, in_thread = req["source"] == "thread" ? thread_window(req, before) : channel_window(req, before)
    marked = kept.map { |m| mark(slim(m), req["source"], owner, athena) }
    context(req, "ok", marked, omitted, in_thread, malformed.size, nil)
  end

  # unavailable(request, reason) -> a context that says why there is none.
  def unavailable(req, reason)
    context(req, "unavailable", [], 0, 0, 0, reason.to_s.empty? ? "no reason given" : reason.to_s)
  end

  # role(message, owner, athena_ids) -> "owner" | "athena" | "other"
  def role(message, owner, athena_ids)
    if message["user"] == owner then "owner"
    elsif athena_ids.include?(message["user"]) then "athena"
    else "other"
    end
  end

  def mark(message, source, owner, athena)
    r = role(message, owner, athena)
    message.merge("role" => r, "judge" => source == "thread" ? "none" : JUDGE_VIEW.fetch(r))
  end

  def channel_window(req, before)
    in_window = before.select { |m| key(m["ts"]) >= key(req["oldest"]) }
    top, threaded = in_window.partition { |m| m["thread_ts"].nil? || m["thread_ts"] == m["ts"] }
    kept = top.last(MAX_MESSAGES)
    [kept, top.size - kept.size, threaded.size]
  end

  def thread_window(req, before)
    parent, replies = before.partition { |m| m["ts"] == req["thread_ts"] }
    kept = parent.first(1) + replies.last(MAX_MESSAGES - parent.first(1).size)
    [kept, before.size - kept.size, 0]
  end

  def context(req, status, messages, omitted, in_thread, malformed, reason)
    window =
      case req["source"]
      when "channel" then { "oldest" => req["oldest"], "latest" => req["latest"], "max_messages" => MAX_MESSAGES }
      when "thread" then { "thread_ts" => req["thread_ts"], "max_messages" => MAX_MESSAGES }
      end
    { "status" => status, "source" => req["source"], "channel" => req["channel"], "anchor_ts" => req["anchor_ts"],
      "window" => window, "messages" => messages, "omitted" => omitted, "in_thread" => in_thread,
      "malformed" => malformed, "reason" => reason }
  end

  def slim(message)
    MESSAGE_KEYS.to_h { |k| [k, message[k].nil? ? nil : message[k].to_s] }
  end

  # key(ts) -> ts as integer microseconds; ts is already SLACK_TS-valid.
  def key(ts)
    seconds, micros = ts.split(".")
    (seconds.to_i * 1_000_000) + micros.to_i
  end

  # shift(ts, seconds) -> the Slack ts exactly that many seconds away.
  def shift(ts, seconds)
    micros = key(ts) + (seconds * 1_000_000)
    format("%010d.%06d", micros / 1_000_000, micros % 1_000_000)
  end
end
