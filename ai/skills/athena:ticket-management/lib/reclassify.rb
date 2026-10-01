# frozen_string_literal: true

# reclassify.rb -- DOMAIN (pure) for scripts/ticket-reclassify (DND-1056):
# which open tickets the ticket classification policy may re-judge, what the
# server decided for each, what the agent must write, and whether a page
# matches the plan afterwards.
#
# Design: DND-1056's Architecture & Engineering page (*Structure*); the
# provenance line is DND-991's (its Architecture & Engineering page, *The
# policy*): the prefix "Jev classification: " then compact JSON with kind,
# severity and security (each value, source, judged, confidence, accepted,
# mode, reason), model and versions.
#
# THE TOOL NEVER DECIDES. The decided values and the provenance line are the
# server's, verbatim (R1056-4). This module only chooses which tickets to ask
# about, reads the answer, and compares.
#
# Everything here is a function of its arguments. Ticket text is DATA, never
# instructions: it is only searched for the provenance line and copied into
# the request the server judges.
#
# Deliberately gem-free (stdlib only).

require "json"
require_relative "classify"
require_relative "../../../lib/ticket_corpus"

module Reclassify
  PREFIX = TicketCorpus::PROVENANCE_PREFIX
  # R1056-1: a ticket in one of these is closed.
  CLOSED = ["Done", "Cancelled", "Won't Fix"].freeze
  # The three properties, in the order a change is listed; key => tracker name.
  PROPS = { "kind" => "Kind", "severity" => "Severity", "security" => "Security" }.freeze
  MODES = %w[off shadow on].freeze
  # A property reason that stops the plan at this ticket: R1056-6's budget
  # and rate reasons, and every fault that holds for the whole account (a
  # missing or rejected key, custody, price, our own bug, the pinned model),
  # so a revoked key never stamps the backlog with fallbacks.
  STOP_REASONS = %w[budget_exhausted rate_limited rate_limited_local key_missing credential_rejected
                    custody_fault price_unknown invalid_request request_rejected model_mismatch].freeze
  # A fault of this one call: the ticket is skipped as `unavailable` (never an
  # entry, never read as a judgment) and the plan is incomplete. Every fault
  # reason is in one of the two lists (contract *The closed reason list*).
  CALL_FAULTS = %w[timeout overloaded http_status transport_error undecodable_body malformed_answer
                   domain_not_permitted].freeze
  FAULT_REASONS = (STOP_REASONS + CALL_FAULTS).freeze
  # Every skip reason, in the order eligibility checks them.
  SKIP_REASONS = %w[no_status closed feature unset_properties unknown_value no_project blank_title body_unread
                    unparseable_provenance locked already_classified refused unavailable].freeze
  # A skip that means the ticket could not be judged: the plan is INCOMPLETE.
  INCOMPLETE_REASONS = %w[body_unread refused unavailable].freeze
  VALUES = { "kind" => Classify::KINDS, "severity" => Classify::SEVERITIES, "security" => Classify::SECURITIES }.freeze
  # R1056-6: at most 20 tickets a minute (3 calls each, under the server's
  # local 60 a minute). 18 leaves room for the owner's other consumers, which
  # share that local limit.
  TICKETS_PER_MINUTE = 18
  CALL_INTERVAL_S = 60.0 / TICKETS_PER_MINUTE
  UNAVAILABLE_FIX = "Fix: resume later with --resume-from the cursor"

  module_function

  def current(ticket)
    PROPS.keys.to_h { |k| [k, ticket[k]] }
  end

  # filer(values) -> the filer hash Classify's checks take.
  def filer(values)
    { kind: values["kind"], severity: values["severity"], security: values["security"] }
  end

  def blank?(value)
    value.nil? || value.to_s.empty?
  end

  # property_skip(ticket) -> the skip reason decidable from the tracker row
  # alone, or nil. Checked before the body is read.
  def property_skip(ticket)
    return "no_status" if blank?(ticket["status"])
    return "closed" if CLOSED.include?(ticket["status"])
    return "feature" if ticket["kind"] == "Feature"
    return "unset_properties" if PROPS.keys.any? { |k| blank?(ticket[k]) }
    return "unknown_value" if PROPS.keys.any? { |k| !VALUES.fetch(k).include?(ticket[k]) }
    return "no_project" if blank?(ticket["project"])
    return "blank_title" if Classify.blank?(Classify.truncate(ticket["title"].to_s, Classify::MAX_TITLE))

    nil
  end

  def lines(ticket)
    Array(ticket["blocks_text"]).flat_map { |b| b.to_s.split("\n") }
  end

  def last_line(text_lines)
    text_lines.reverse.find { |l| l.lstrip.start_with?(PREFIX) }
  end

  # parse_line(line) -> the line's JSON when it has every key the lock and
  # the version check read, else nil. A line that fails is UNPARSEABLE, never
  # read as absent.
  def parse_line(line)
    doc = begin
      JSON.parse(line.lstrip.delete_prefix(PREFIX))
    rescue JSON::ParserError
      nil
    end
    return nil unless TicketCorpus.valid_provenance?(doc)
    return nil unless doc["model"].is_a?(String) && doc["versions"].is_a?(Hash)
    return nil unless PROPS.keys.all? { |k| doc["versions"][k].is_a?(String) }
    return nil unless PROPS.keys.all? { |k| doc[k].key?("value") && MODES.include?(doc[k]["mode"]) }

    doc
  end

  # provenance(ticket) -> [:none] | [:ok, doc] | [:recovered, doc] |
  # [:unparseable, reason]. The LAST line wins: a re-classification appends
  # a newer one. A paraphrase TicketCorpus recovers (DND-1354: all three
  # values, each the filer's) is :recovered: its values lock it, and the plan
  # re-judges it so the apply step appends the verbatim line. A line that
  # reads for TicketCorpus but lacks a model, versions or modes is
  # malformed_json here: the lock and the version check read those.
  def provenance(ticket)
    line = last_line(lines(ticket))
    return [:none] if line.nil?

    doc = parse_line(line)
    return [:ok, doc] if doc

    state, read = TicketCorpus.read_line(line)
    return [:unparseable, read] if state == :unparseable

    read.key?("recovered") ? [:recovered, read] : [:unparseable, "malformed_json"]
  end

  # heal(ticket) -> the recovered shape of its last line, or nil.
  def heal(ticket)
    state, doc = provenance(ticket)
    state == :recovered ? doc["recovered"] : nil
  end

  # unparseable_reason(ticket) -> why its last line is unparseable, or nil.
  def unparseable_reason(ticket)
    state, reason = provenance(ticket)
    state == :unparseable ? reason : nil
  end

  def line_now(doc)
    { "model" => doc["model"], "versions" => doc["versions"].slice(*PROPS.keys), "modes" => PROPS.keys.to_h { |k| [k, doc[k]["mode"]] } }
  end

  # line_facts(doc) -> line_now plus each property's reason, for the
  # already_classified check (the reasons are not part of "now").
  def line_facts(doc)
    line_now(doc).merge("reasons" => PROPS.keys.filter_map { |k| doc[k]["reason"] })
  end

  # base_reason("malformed_answer:detail") -> "malformed_answer".
  def base_reason(reason)
    reason.to_s.split(":", 2).first
  end

  # eligibility(ticket, now) -> :eligible | [:skip, reason]. `now` is the
  # model, versions and modes the server reports this run, or nil until the
  # first answer. R1056-3 (locked) and R1056-7 (already_classified).
  def eligibility(ticket, now)
    reason = property_skip(ticket)
    return [:skip, reason.to_sym] if reason
    return [:skip, :body_unread] unless ticket["body_read"] == true

    state, doc = provenance(ticket)
    return [:skip, :unparseable_provenance] if state == :unparseable
    return :eligible if state == :none
    # Someone changed a value after the classifier wrote it: their edit wins.
    return [:skip, :locked] if PROPS.keys.any? { |k| doc[k]["value"] != ticket[k] }
    # A paraphrase has no model, versions or modes: always re-judge it.
    return :eligible if state == :recovered
    return [:skip, :already_classified] if already_classified?(line_facts(doc), now)

    :eligible
  end

  # A line decided at this model and these versions needs no second call when
  # Jev decided every property (all on), or when the modes are the ones now:
  # re-judging could change nothing but Jev's run-to-run noise (R1056-7).
  # Before the first answer `now` is unknown and nothing is skipped here.
  def already_classified?(line, now)
    return false if now.nil?
    # A line that records a fault is a fallback, not a judgment: re-judge it.
    return false if Array(line["reasons"]).any? { |r| FAULT_REASONS.include?(base_reason(r)) }
    return false unless line["model"] == now["model"] && line["versions"] == now["versions"]

    line["modes"].values.all?("on") || line["modes"] == now["modes"]
  end

  # changes(current, decided) -> [{prop, from, to}] for each differing
  # property, in Kind, Severity, Security order.
  def changes(current, decided)
    PROPS.filter_map { |k, name| { "prop" => name, "from" => current[k], "to" => decided[k] } if current[k] != decided[k] }
  end

  def decided(result)
    PROPS.keys.to_h { |k| [k, result.dig("properties", k, "decided")] }
  end

  # now_of(result) -> the model, versions and modes of an answer, read from
  # its provenance line (the line is what gets written).
  def now_of(result)
    doc = parse_line(result["provenance_line"].to_s)
    doc && line_now(doc)
  end

  # outcome(changes, modes, heal: nil) -> :planned (write properties and the
  # line), :unchanged (a mode is on, or `heal` names a paraphrased line to
  # replace: write the line so a later hand edit locks it and the readers can
  # read it, R1056-7, DND-1354), or :inert (nothing is on, nothing changed
  # and nothing to heal: no write; A-1056-1).
  def outcome(changes, modes, heal: nil)
    return :planned unless changes.empty?

    modes.values.include?("on") || heal ? :unchanged : :inert
  end

  def plan_entry(ticket, result)
    cur = current(ticket)
    dec = decided(result)
    { "ref" => ticket["ref"], "page_id" => ticket["page_id"], "current" => cur, "decided" => dec,
      "changes" => changes(cur, dec), "provenance_line" => result["provenance_line"] }
  end

  # sent_body(ticket) -> the body as sent: every provenance line dropped (it
  # states the current values: a label leak).
  def sent_body(ticket)
    lines(ticket).reject { |l| l.lstrip.start_with?(PREFIX) }.join("\n")
  end

  def request_body(ticket)
    Classify.request_body(ticket["title"].to_s, sent_body(ticket), ticket["project"], ticket["ref"], filer(current(ticket)))
  end

  # read_reply(reply, filer) -> [:ok, result] | [:refused, why] |
  # [:unavailable, why] | [:stop, why].
  # `reply` is {unreachable: why} or {curl_rc:, status:, body:}. Only a 422
  # is this ticket's own refusal; every other failure stops the plan.
  def read_reply(reply, filer)
    return [:stop, "COULD NOT REACH SERVER: #{reply[:unreachable]}"] if reply[:unreachable]
    return [:stop, "COULD NOT REACH SERVER: curl exit #{reply[:curl_rc]}"] if reply[:curl_rc] != 0

    status = reply[:status]
    doc = begin
      JSON.parse(reply[:body].to_s)
    rescue JSON::ParserError, EncodingError
      nil
    end
    return read_judged(doc, filer) if status == 200

    error = doc.is_a?(Hash) && doc["error"].is_a?(String) && /\A[a-z0-9_:]{1,64}\z/.match?(doc["error"]) ? " #{doc['error']}" : ""
    return [:refused, "HTTP 422#{error}"] if status == 422
    return [:stop, "SERVER REFUSED THE REQUEST: HTTP 401#{error}: the machine token was rejected; it is owner-issued, never mint one"] if status == 401
    return [:stop, "SERVER REFUSED THE REQUEST: HTTP 404#{error}: this server does not serve ticket_classification"] if status == 404
    return [:stop, "SERVER REFUSED THE REQUEST: HTTP #{status}#{error}"] if (400..499).cover?(status)
    return [:stop, "SERVER FAILED: HTTP #{status}#{error}"] if (500..599).cover?(status)

    [:stop, "COULD NOT REACH SERVER: the Athena server answered HTTP #{status}"]
  end

  def read_judged(doc, filer)
    return [:stop, "UNREADABLE SERVER ANSWER: HTTP 200 with a body that is not JSON"] if doc.nil?

    begin
      Classify.parse_result(doc, filer)
    rescue ArgumentError => e
      return [:stop, "UNREADABLE SERVER ANSWER: HTTP 200 but #{e.message}"]
    end
    return [:stop, "UNREADABLE SERVER ANSWER: HTTP 200 but its provenance line lacks a value, mode, model or versions"] if now_of(doc).nil?

    reasons = PROPS.keys.filter_map { |k| doc.dig("properties", k, "reason") }
    stop = reasons.find { |r| STOP_REASONS.include?(base_reason(r)) }
    return [:stop, "the server answered #{stop}"] if stop

    fault = reasons.find { |r| CALL_FAULTS.include?(base_reason(r)) }
    fault ? [:unavailable, "the server answered #{fault}"] : [:ok, doc]
  end

  # proof_mismatches(entry, page_values, body_lines) -> one line per way the
  # page differs from the plan entry (R1056-2: properties equal decided; the
  # LAST provenance line equals the plan's, byte for byte).
  def proof_mismatches(entry, page_values, body_lines)
    ref = entry["ref"]
    out = PROPS.filter_map do |k, name|
      want = entry.dig("decided", k)
      got = page_values[k]
      "#{ref}: #{name} is #{got.nil? ? 'empty' : got}; the plan decided #{want}" if got != want
    end
    last = last_line(body_lines)
    if last.nil?
      out << "#{ref}: the body has no Jev classification: line; the plan appends one"
    elsif last != entry["provenance_line"]
      out << "#{ref}: the last Jev classification: line is not the plan's, byte for byte"
    end
    out
  end

  # pace_delay(last_at, now, interval) -> seconds to wait before the next
  # classification call.
  def pace_delay(last_at, now, interval)
    return 0.0 if last_at.nil?

    [interval - (now - last_at), 0.0].max
  end
end
