# frozen_string_literal: true

require "json"

# OwnerTurn -- verify that given words are the OWNER'S OWN, typed by a human in
# an interactive Claude Code session, by reading that session's transcript.
#
# Shared by ai/bin/owner-notes (a relayed owner note, DND-988) and
# ai/bin/blast-radius (an --owner-approval record, 2026-09-28 owner approval
# policy: "--owner-approval must require a real approval record"). One
# verifier, so the two can never disagree about what counts as the owner.
#
# A reference is session:<session-uuid>/<message-uuid>. It verifies only when
# that message is a top-level (non-sidechain) user turn TYPED BY A HUMAN in an
# interactive session -- entrypoint "cli", promptSource "typed", origin.kind
# "human", as Claude Code 2.1.283 records it -- whose text holds the words
# verbatim. A headless `claude -p` prompt ("sdk-cli"/"sdk"), a tool result, a
# notification, and inbox content (a tool result) never verify. Missing fields
# fail closed.
#
# Residual, said out loud: an agent that edits a transcript, or points HOME at
# a forged one, can still forge a record. This stops free text and honest
# mistakes, not a determined forger.
module OwnerTurn
  SESSION_REF_RE = %r{\Asession:([0-9a-f-]{36})/([0-9a-f-]{36})\z}.freeze

  module_function

  def default_dir
    File.join(Dir.home, ".claude", "projects")
  end

  # -> [:verified, said] | [:unverified, reason] | [:unverifiable]
  def check(ref, words, dir: default_dir)
    m = SESSION_REF_RE.match(ref)
    return [:unverifiable] unless m

    sid, mid = m[1], m[2]
    files = Dir.glob(File.join(dir, "*", "#{sid}.jsonl"))
    return [:unverified, "transcript for session #{sid} not found under #{dir}"] if files.empty?
    return [:unverified, "#{files.size} transcripts for session #{sid} under #{dir}"] if files.size > 1

    msg = find_message(files.first, mid)
    return [:unverified, "no message #{mid} in #{files.first}"] unless msg
    unless msg["type"] == "user" && msg["isSidechain"] != true
      return [:unverified, "message #{mid} is not a top-level user turn (type=#{msg['type'].inspect}, " \
                           "sidechain=#{msg['isSidechain'].inspect})"]
    end
    human = msg["entrypoint"] == "cli" && msg["promptSource"] == "typed" &&
            msg["origin"].is_a?(Hash) && msg["origin"]["kind"] == "human"
    unless human
      return [:unverified, "message #{mid} was not typed by a human in an interactive session " \
                           "(entrypoint=#{msg['entrypoint'].inspect}, promptSource=#{msg['promptSource'].inspect}, " \
                           "origin=#{msg['origin'].inspect}); a headless `claude -p` prompt or a notification never " \
                           "corroborates"]
    end
    said = text_of(msg)
    if said.strip.empty?
      return [:unverified, "message #{mid} is not a top-level user turn with text (tool results never corroborate)"]
    end
    return [:unverified, "the words were not found verbatim in message #{mid}"] unless said.include?(words)

    [:verified, said]
  rescue SystemCallError => e
    [:unverified, "cannot read the transcript: #{e.message}"]
  end

  def find_message(path, mid)
    File.foreach(path, encoding: "UTF-8") do |line|
      j = begin
        JSON.parse(line)
      rescue JSON::ParserError
        next
      end
      return j if j.is_a?(Hash) && j["uuid"] == mid
    end
    nil
  end

  def text_of(msg)
    content = msg.dig("message", "content")
    if content.is_a?(String)
      content
    elsif content.is_a?(Array)
      content.select { |b| b.is_a?(Hash) && b["type"] == "text" }.map { |b| b["text"].to_s }.join("\n")
    else
      ""
    end
  end
end
