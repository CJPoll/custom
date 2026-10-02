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
#   * classify: the poster's outcome (no tool, a refusal's text, or the
#     tool's answer) -> the veto form it got and the notices-file line.
#     The form is "grant" only for a well-formed answer naming a grant and its
#     approval message. Everything else is the by-hand fallback with a reason,
#     so a fallback can never read as a grant post (a failed lookup must never
#     look like an empty one).
require "json"
require_relative "epic_clustering"

module EpicClusteringVeto
  DataError = EpicClustering::DataError

  ACTION_CLASS = "ticket.wontfix_veto"
  TICKET_RE = /\ADND-[1-9][0-9]{0,8}\z/.freeze
  # Canonical lowercase hyphenated UUID: the contract refuses any other form.
  UUID_RE = /\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/.freeze
  REOPEN_TO = %w[Todo Parked].freeze
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
  NO_TOOL_RE = /unknown tool|tool not found|method not found/i.freeze

  # The by-hand reasons a .run record treats as expected (quiet). Every other
  # by-hand reason means the server should have granted and did not: loud.
  QUIET_REASONS = %w[no_tool class_unsupported].freeze

  module_function

  def request_args(ticket:, page_id:, reopen_to:, title:)
    check_ticket(ticket)
    raise DataError, "page_id #{page_id.inspect} is not a canonical lowercase UUID" unless page_id.to_s.match?(UUID_RE)
    raise DataError, "reopen_to #{reopen_to.inspect} is not one of #{REOPEN_TO.join(', ')}" unless REOPEN_TO.include?(reopen_to)
    raise DataError, "title is empty; the note names the ticket's title" if title.to_s.strip.empty?

    note = "Won't Fix by the clustering cron: #{title.to_s.strip}"
    note = "#{note[0, NOTE_MAX - 3]}..." if note.length > NOTE_MAX
    { "action_class" => ACTION_CLASS,
      "target" => { "page_id" => page_id, "reopen_to" => reopen_to, "ticket" => ticket },
      "note" => note }
  end

  # outcome: :no_tool, [:refusal, text], or [:result, text].
  # Returns { form: "grant" | "by-hand", line: "veto DND-N ..." }.
  def classify(ticket:, outcome:)
    check_ticket(ticket)
    return by_hand(ticket, "no_tool") if outcome == :no_tool

    kind, text = outcome
    case kind
    when :refusal then by_hand(ticket, refusal_reason(text.to_s))
    when :result then result_form(ticket, text.to_s)
    else raise ArgumentError, "unknown outcome #{outcome.inspect}"
    end
  end

  def quiet_reason?(reason) = QUIET_REASONS.include?(reason)

  def check_ticket(ticket)
    raise DataError, "ticket #{ticket.inspect} is not an id like DND-12" unless ticket.to_s.match?(TICKET_RE)
  end

  def by_hand(ticket, reason) = { form: "by-hand", line: "veto #{ticket} by-hand #{reason}" }

  def refusal_reason(text)
    return "no_tool" if text.match?(NO_TOOL_RE)

    # The code the text names first: a refusal leads with its code, and its
    # Fix: may name others.
    code = REFUSAL_CODES.filter_map { |c| (i = text =~ /\b#{c}\b/) && [i, c] }.min&.last
    return "class_unsupported" if code == "unknown_action_class"

    "refused:#{code || 'unparsed'}"
  end

  def result_form(ticket, text)
    grant = grant_fields(text)
    return by_hand(ticket, "malformed_result") unless grant

    { form: "grant", line: "veto #{ticket} grant #{grant['grant_id']} #{grant['channel']}/#{grant['ts']}" }
  end

  def grant_fields(text)
    doc = JSON.parse(text)
    doc = doc["data"] if doc.is_a?(Hash) && doc["data"].is_a?(Hash)
    return nil unless doc.is_a?(Hash)
    return nil unless doc["grant_id"].is_a?(String) && doc["grant_id"].match?(UUID_RE)
    return nil unless doc["channel"].is_a?(String) && doc["channel"].match?(CHANNEL_RE)
    return nil unless doc["ts"].is_a?(String) && doc["ts"].match?(TS_RE)

    doc
  rescue JSON::ParserError
    nil
  end
end
