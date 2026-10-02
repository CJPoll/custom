# frozen_string_literal: true

# epic_clustering_veto -- the won't-fix veto grant (DND-1758), Domain bucket:
# pure, no I/O. A cron-posted won't-fix notice cannot carry a click veto that
# a session verifies (athena:slack -> A click is untrusted input, check 3), so
# its veto is a server-side owner approval grant of class
# `ticket.wontfix_veto` (ai/contracts/athena-events.md -> Owner approval
# grants -> The `ticket.wontfix_veto` class). The server posts the approval
# message and reopens the ticket at click time; no session acts on the click.
#
# Two rules live here:
#   * request_args: the owner_approval_request arguments for one closure,
#     typed and validated as the contract pins them, never coerced.
#   * classify: the poster's outcome (no tool, no request built, or the
#     tool's answer or refusal, saved verbatim) -> the veto form it got and
#     the notices-file line. The answer is classified by its CONTENT, never by
#     which flag the poster chose. The form is "grant" only for a well-formed
#     answer naming a grant and its approval message. Everything else is the
#     by-hand fallback with a reason, so a fallback can never read as a grant
#     post (a failed lookup must never look like an empty one).
#
# Which reasons are quiet in a .run record is the runner's, in one place:
# scripts/athena-clustering-run.sh -> notice_summary.
require "json"
require_relative "epic_clustering"

module EpicClusteringVeto
  DataError = EpicClustering::DataError

  ACTION_CLASS = "ticket.wontfix_veto"
  TICKET_RE = /\ADND-[1-9][0-9]{0,8}\z/.freeze
  # Canonical lowercase hyphenated UUID: the contract refuses any other form.
  UUID_RE = /\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/.freeze
  REOPEN_TO = %w[Todo Parked].freeze
  NOTE_PREFIX = "Won't Fix by the clustering cron: "
  NOTE_MAX = 300
  CHANNEL_RE = /\A[A-Z0-9]+\z/.freeze
  TS_RE = /\A[0-9]+\.[0-9]+\z/.freeze

  # The refusal codes owner_approval_request can answer (the contract's
  # Request: owner_approval_request, plus this class's request-time reads).
  # unknown_action_class is the one that means "this server has no such class
  # yet", the expected fallback until gen_saas ships it.
  REFUSAL_CODES = %w[
    unknown_action_class class_not_requestable target_invalid slack_not_configured
    owner_slack_user_id_unset rate_limited notion_not_configured notion_unavailable
    ticket_not_found ticket_mismatch ticket_not_wont_fix
  ].freeze
  # A server that does not have the tool at all answers like this (JSON-RPC
  # -32601, or the client's own "unknown tool"): the same as no tool listed.
  # Read only when no refusal code is named, so a Fix: text cannot hide one.
  NO_TOOL_RE = /unknown tool|tool not found|method not found/i.freeze
  GRANT_KEYS = %w[grant_id channel ts click_expires_at].freeze

  module_function

  def request_args(ticket:, page_id:, reopen_to:, title:)
    check_ticket(ticket)
    raise DataError, "page_id #{page_id.inspect} is not a canonical lowercase UUID" unless page_id.to_s.match?(UUID_RE)
    raise DataError, "reopen_to #{reopen_to.inspect} is not one of #{REOPEN_TO.join(', ')}" unless REOPEN_TO.include?(reopen_to)
    raise DataError, "title is empty; the note names the ticket's title" if title.to_s.strip.empty?

    note = "#{NOTE_PREFIX}#{title.to_s.strip}"
    note = "#{note[0, NOTE_MAX - 3]}..." if note.length > NOTE_MAX
    { "action_class" => ACTION_CLASS,
      "target" => { "page_id" => page_id, "reopen_to" => reopen_to, "ticket" => ticket },
      "note" => note }
  end

  # outcome: :no_tool, :no_request, or [:answer, text] (the tool's answer or
  # refusal, saved verbatim). Returns { form: "grant" | "by-hand", line: ... }.
  def classify(ticket:, outcome:)
    check_ticket(ticket)
    return by_hand(ticket, "no_tool") if outcome == :no_tool
    return by_hand(ticket, "request_unbuilt") if outcome == :no_request

    kind, text = outcome
    raise ArgumentError, "unknown outcome #{outcome.inspect}" unless kind == :answer

    answer_form(ticket, text.to_s)
  end

  def check_ticket(ticket)
    raise DataError, "ticket #{ticket.inspect} is not an id like DND-12" unless ticket.to_s.match?(TICKET_RE)
  end

  def by_hand(ticket, reason) = { form: "by-hand", line: "veto #{ticket} by-hand #{reason}" }

  def answer_form(ticket, text)
    grant = grant_fields(text)
    if grant
      return { form: "grant", line: "veto #{ticket} grant #{grant['grant_id']} #{grant['channel']}/#{grant['ts']}" }
    end

    by_hand(ticket, refusal_reason(text))
  end

  # A named code wins; then a missing tool; then an answer that tried to be a
  # grant and is malformed; anything else is an unparsed refusal.
  def refusal_reason(text)
    code = REFUSAL_CODES.filter_map { |c| (i = text =~ /\b#{c}\b/) && [i, c] }.min&.last
    return "class_unsupported" if code == "unknown_action_class"
    return "refused:#{code}" if code
    return "no_tool" if text.match?(NO_TOOL_RE)
    return "malformed_result" if grant_shaped?(text)

    "refused:unparsed"
  end

  def grant_fields(text)
    doc = answer_object(text)
    return nil unless doc && !doc.key?("error")
    return nil unless doc["grant_id"].is_a?(String) && doc["grant_id"].match?(UUID_RE)
    return nil unless doc["channel"].is_a?(String) && doc["channel"].match?(CHANNEL_RE)
    return nil unless doc["ts"].is_a?(String) && doc["ts"].match?(TS_RE)
    return nil unless doc["click_expires_at"].is_a?(String) && !doc["click_expires_at"].empty?

    doc
  end

  def grant_shaped?(text)
    doc = answer_object(text)
    !doc.nil? && GRANT_KEYS.any? { |k| doc.key?(k) }
  end

  def answer_object(text)
    doc = JSON.parse(text)
    doc = doc["data"] if doc.is_a?(Hash) && doc["data"].is_a?(Hash)
    doc.is_a?(Hash) ? doc : nil
  rescue JSON::ParserError
    nil
  end
end
