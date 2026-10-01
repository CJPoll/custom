# frozen_string_literal: true

# judgment_feedback_scan.rb -- the pure rules of `judgment-feedback
# scan-tickets` (DND-1469): which hand edits of a DND ticket's Kind, Severity
# or Security are a "wrong" signal for the Jev call that decided the value,
# and the correction each one records. Since DND-1470 also its Path and
# Blocks edge against the `Jev path:` line (the ticket_blocking section
# below). Domain only: no I/O, no process, no
# clock. The normative home is ai/contracts/athena-judgments.md -> *Receiver
# feedback* (the ticket rows); the server is gen_saas ADR 22.
#
# The rule is ticket-reclassify's lock read the other way round: the LAST
# `Jev classification:` line is the decision (TicketCorpus.provenance), and a
# property whose value differs from that line's was edited by hand (DND-1056:
# the edit wins). When that line says the value was Jev's (source jev,
# accepted) and names the call that answered it, the edit is feedback:
# signal field_changed, correction {question => the current value in the
# question's own label spelling}.
#
# Nothing is ever silently skipped. Every ticket is counted once by
# TICKET_REASONS and every property of a ticket with a line once by
# PROPERTY_REASONS; the bin adds the outcome of each record it sends.
#
# Deliberately gem-free (stdlib only).

require "json"
require "set"
require "time"
require_relative "ticket_corpus"
require_relative "blocking_corpus"

module JudgmentFeedbackScan
  # A command-line value the scan cannot use. Nothing is read or sent.
  class UsageError < StandardError; end

  # Why a ticket has no property to compare, or `lines` when it has a line.
  #   provenance_unread  its body could not be read (the scan is incomplete)
  #   no_provenance      no `Jev classification:` line: never classified
  #   unparseable        the LAST line is broken: never read as absent
  #   lines              the last line was read; its properties are counted
  TICKET_REASONS = %w[provenance_unread no_provenance unparseable lines].freeze

  # Why a property of a ticket with a line was not recorded, or that it is
  # to be (`edited`), in the order they are checked.
  #   filer_sourced    the line's source is filer: not Jev's value
  #   policy_sourced   the line's source is policy: not Jev's value
  #   unchanged        the current value is the line's value
  #   unlinked         the line predates DND-1469 and names no call
  #   no_call          the line names no call for this property
  #   not_accepted     source jev but this call's answer was not accepted (a
  #                    policy floor raised the value): its call is not wrong
  #   no_label         the current value has no label in the question (unset,
  #                    Feature, or outside the tracker's set)
  #   same_label       the edit keeps Jev's label (e.g. pre-existing to
  #                    introduced: the origin is the filer's statement)
  #   edited           Jev's value was edited away: record field_changed
  PROPERTY_REASONS = %w[filer_sourced policy_sourced unchanged unlinked no_call not_accepted no_label same_label edited].freeze

  # What sending one record came to (the bin's counts).
  #   recorded / replaced  the server stored it (a first or a later report)
  #   already_recorded     this call and correction are in the recorded file:
  #                        not sent again (a replace moves the row past the
  #                        feedback reader's cursor, so it would be read twice)
  #   refused              the server refused it (not_found, not_judged, ...)
  RECORD_OUTCOMES = %w[recorded replaced already_recorded refused].freeze

  PROPERTIES = { "kind" => "Kind", "severity" => "Severity", "security" => "Security" }.freeze
  # The question each property's judgment answered (gen_saas QuestionSets
  # TicketKind / TicketSeverity / TicketSecurity, v1).
  QUESTIONS = { "kind" => "kind", "severity" => "severity", "security" => "security" }.freeze
  # A Score's label is its level index, lowest first.
  SEVERITY_LEVELS = %w[LOW MEDIUM HIGH CRITICAL].freeze
  SIGNAL = "field_changed"
  SESSION_LABEL = "harness"
  TIME = /\A\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(?:\.\d{1,6})?(?:Z|[+-]\d\d:\d\d)\z/
  # Notion stamps last_edited_time to the minute: the next scan starts a
  # whole minute before the minute this one started in.
  OVERLAP_S = 60

  module_function

  # label(property, value) -> the value in the question's own label spelling
  # (a choice's option key, a score's level index), or nil when the question
  # has no label for it. The judged kinds' keys are their tracker names in
  # lower case; Feature is authored, never judged, so it has none.
  def label(property, value)
    case property
    when "kind" then TicketCorpus::KINDS.include?(value) ? value.downcase : nil
    when "severity" then SEVERITY_LEVELS.index(value)&.to_s
    when "security" then TicketCorpus::SECURITY[value]
    end
  end

  # judged_label(property, judged) -> Jev's own answer as a label of the same
  # spelling (the line carries it in the tracker's spelling).
  def judged_label(property, judged)
    property == "security" ? judged : label(property, judged)
  end

  # property_verdict(property, current, prop, calls) -> [reason] or
  # ["edited", call_id, {question => label}]. `prop` is the line's object
  # for the property; `calls` the line's calls, nil when it has none.
  def property_verdict(property, current, prop, calls)
    return ["filer_sourced"] if prop["source"] == "filer"
    return ["policy_sourced"] if prop["source"] != "jev"
    return ["unchanged"] if current == prop["value"]
    return ["unlinked"] if calls.nil?

    call = calls[property]
    return ["no_call"] if call.nil?
    return ["not_accepted"] unless prop["accepted"] == true && prop["judged"].is_a?(String)

    now = label(property, current)
    return ["no_label"] if now.nil?
    return ["same_label"] if now == judged_label(property, prop["judged"])

    ["edited", call, { QUESTIONS.fetch(property) => now }]
  end

  # ticket_verdict(ticket) -> {reason:, properties: [[property, verdict]]}.
  # `ticket` is TriageCorpus.ticket_from_row's shape plus body_read and
  # blocks_text. An unread body is never read as "no line".
  def ticket_verdict(ticket)
    return { reason: "provenance_unread", properties: [] } unless ticket["body_read"] == true

    state, doc = TicketCorpus.provenance(ticket)
    return { reason: "no_provenance", properties: [] } if state == :none
    return { reason: "unparseable", properties: [] } if state == :unparseable || !values?(doc)

    calls = TicketCorpus.calls(doc)
    props = PROPERTIES.keys.map { |p| [p, property_verdict(p, ticket[p], doc[p], calls)] }
    { reason: "lines", properties: props }
  end

  # The scan compares values, so a line whose properties carry no `value`
  # is as broken as one that does not parse.
  def values?(doc)
    PROPERTIES.keys.all? { |p| doc[p].key?("value") }
  end

  # record_key(call, correction) -> the recorded-file line for one record.
  # Lower case, as recorded_keys reads the file back: a call id written in
  # upper case must still match its own entry, or it is re-sent every scan.
  def record_key(call, correction)
    "#{call} #{correction.map { |q, l| "#{q}=#{l}" }.sort.join(',')}".downcase
  end

  # One recorded-file line: the call, then each question=label, sorted and
  # comma-joined (a ticket_blocking record can correct several cand_<i>).
  PAIR = "[a-z0-9_]+=[A-Za-z0-9_:.-]+"
  RECORD_KEY = /\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12} #{PAIR}(?:,#{PAIR})*\z/

  # recorded_keys(text) -> Set of record keys; blank lines allowed, anything
  # else that is not a key is usage (a corrupt file must not silently resend
  # or silently suppress).
  def recorded_keys(text)
    text.to_s.each_line.with_index(1).each_with_object(Set.new) do |(line, n), set|
      key = line.strip
      next if key.empty?
      raise UsageError, "--recorded-file line #{n} is not '<call uuid> <question>=<label>[,...]'" unless RECORD_KEY.match?(key)

      set << key.downcase
    end
  end

  # parse_since(text) -> Time (UTC). A time with a zone only: a guessed zone
  # or a bare date would move the window by hours with no error.
  def parse_since(text)
    raise UsageError, "--since needs an ISO 8601 time with a zone, e.g. 2026-10-01T07:00:00Z" unless TIME.match?(text.to_s)

    Time.iso8601(text).utc
  rescue ArgumentError
    raise UsageError, "--since needs an ISO 8601 time with a zone, e.g. 2026-10-01T07:00:00Z"
  end

  # next_since(started_at) -> where the next scan starts: a minute before the
  # minute this scan started in (Notion's last_edited_time is minute-rounded,
  # so an edit in this minute may read as stamped at its start).
  def next_since(started_at)
    t = started_at.utc
    Time.utc(t.year, t.month, t.day, t.hour, t.min) - OVERLAP_S
  end

  def iso(time)
    time.utc.strftime("%Y-%m-%dT%H:%M:%SZ")
  end

  # filter(since) -> the Notion data source filter: tickets edited at or
  # after `since`.
  def filter(since)
    { "timestamp" => "last_edited_time", "last_edited_time" => { "on_or_after" => iso(since) } }
  end

  # tally(verdicts) -> {tickets: {reason => n}, properties: {reason => n},
  # refs: {reason => [DND refs]}, edits: [[ref, property, call, correction]]}.
  # Every ticket is counted once and every property of a read line once.
  def tally(verdicts)
    tickets = TICKET_REASONS.to_h { |r| [r, 0] }
    props = PROPERTY_REASONS.to_h { |r| [r, 0] }
    refs = Hash.new { |h, k| h[k] = [] }
    edits = []
    verdicts.each do |ref, v|
      tickets[v[:reason]] += 1
      refs[v[:reason]] << ref unless v[:reason] == "lines"
      v[:properties].each do |property, verdict|
        props[verdict.first] += 1
        refs[verdict.first] << ref if %w[unlinked no_call not_accepted no_label].include?(verdict.first)
        edits << [ref, property, verdict[1], verdict[2]] if verdict.first == "edited"
      end
    end
    { tickets: tickets, properties: props, refs: refs.transform_values(&:uniq), edits: edits }
  end
  # ── ticket_blocking (DND-1470) ─────────────────────────────────────────
  #
  # A finding's LAST `Jev path:` line (BlockingCorpus.path_line, the shadow
  # report's own reader) against its current Path and Blocks edge. When the
  # line's source is jev, Jev's accepted judgment decided the Path: Blocking
  # onto `path.blocks` (an accepted `blocks` for that candidate), or Off (an
  # accepted `does_not_block` removed the claim). A later change away from it
  # is feedback on that call: signal field_changed, a correction per
  # candidate the change contradicts, keyed `cand_<i>` by the line's
  # `candidate_refs`:
  #   * the judged-blocks candidate no longer blocked: does_not_block;
  #   * a candidate now blocked that Jev accepted no `blocks` for: blocks.
  #     Under a jev Off that is every candidate (an accepted `blocks` would
  #     have decided Blocking). Under a jev Blocking onto cand_k it is only
  #     a candidate before k: the policy blocks the FIRST accepted `blocks`
  #     (TicketBlockingPolicy rule 2), so a later one may have had one too
  #     and a new edge onto it is not known to contradict Jev.
  # Only Blocking carries a Blocks claim: a stale edge under Off is not one.
  # Critical and Promoted are authored (J-991-2), never a contradiction of
  # the judgment by themselves.

  # Why a ticket's Path was not recorded, or that it is to be (`edited`), in
  # the order they are checked. Every ticket of the scan counts once.
  #   provenance_unread   its body could not be read (the scan is incomplete)
  #   no_path_line        no `Jev path:` line: its Path was never judged
  #   unparseable         the LAST path line is broken: never read as absent
  #   filer_sourced       the line's source is filer: not Jev's decision
  #   rule_sourced        the line's source is rule: no judgment was made
  #   path_unset          the Path is empty: never read as Off
  #   authored_override   the Path is now Critical or Promoted (authored)
  #   edges_unread        the ticket is Blocking but its Blocks edges could
  #                       not be read (the scan is incomplete)
  #   blocking_no_edge    the ticket is Blocking with no Blocks edge: a half
  #                       edit that says nothing about which candidate
  #   unchanged           the Path and edge still match Jev's decision
  #   unlinked            the line predates DND-1470 and names no call
  #   no_call             the line names no call (its row was not written)
  #   no_candidate_named  changed, but onto no candidate Jev was asked about
  #   not_contradicted    changed only onto a candidate after Jev's blocked
  #                       one: Jev may have accepted `blocks` for it too
  #   edited              changed away from Jev's decision: record it
  BLOCKING_REASONS = %w[provenance_unread no_path_line unparseable filer_sourced rule_sourced path_unset
                        authored_override edges_unread blocking_no_edge unchanged unlinked no_call no_candidate_named
                        not_contradicted edited].freeze
  # The reasons whose tickets are named: each needs a person or a re-run.
  BLOCKING_NAMED = %w[provenance_unread unparseable path_unset edges_unread blocking_no_edge unlinked no_call
                      no_candidate_named].freeze
  # The pseudo-property a Path edit is recorded under (the bin's refusals).
  PATH_PROPERTY = "path"
  AUTHORED_PATHS = %w[Critical Promoted].freeze
  BLOCKS_LABEL = "blocks"
  DOES_NOT_BLOCK_LABEL = "does_not_block"

  # jev_path_line(ticket) -> the parsed LAST path line when its source is
  # jev, else nil.
  def jev_path_line(ticket)
    return nil unless ticket["body_read"] == true

    state, doc = BlockingCorpus.path_line(ticket)
    state == :ok && doc.dig("path", "source") == "jev" ? doc : nil
  end

  # edges_needed?(ticket) -> whether blocking_verdict needs the refs of the
  # ticket's Blocks edges: a jev line on a ticket that is Blocking now.
  def edges_needed?(ticket)
    ticket["path"] == "Blocking" && !jev_path_line(ticket).nil?
  end

  # blocking_verdict(ticket, edge_refs) -> [reason] or ["edited", call,
  # {"cand_<i>" => label}]. `edge_refs` are the DND refs of the ticket's
  # Blocks edges, or nil when they could not be read.
  def blocking_verdict(ticket, edge_refs)
    return ["provenance_unread"] unless ticket["body_read"] == true

    state, doc = BlockingCorpus.path_line(ticket)
    return ["no_path_line"] if state == :none
    return ["unparseable"] if state == :unparseable

    source = doc.dig("path", "source")
    return ["#{source}_sourced"] unless source == "jev"
    return ["path_unset"] if ticket["path"].nil?
    return ["authored_override"] if AUTHORED_PATHS.include?(ticket["path"])

    blocked_now = ticket["path"] == "Blocking" ? edge_refs : []
    return ["edges_unread"] if blocked_now.nil?
    return ["blocking_no_edge"] if ticket["path"] == "Blocking" && blocked_now.empty?

    judged = doc.dig("path", "value") == "Blocking" ? [doc.dig("path", "blocks")] : []
    unblocked = judged - blocked_now
    newly = blocked_now.uniq - judged
    return ["unchanged"] if unblocked.empty? && newly.empty?
    return ["unlinked"] unless doc.key?("call")
    return ["no_call"] if doc["call"].nil?

    refs = doc["candidate_refs"]
    correction = path_correction(refs, unblocked, newly, judged.first)
    return ["edited", doc["call"], correction] unless correction.empty?

    newly.any? { |r| refs.include?(r) } ? ["not_contradicted"] : ["no_candidate_named"]
  end

  # path_correction(refs, unblocked, newly, judged) -> {"cand_<i>" =>
  # label}, by candidate index. `judged` is the ref Jev blocked, or nil for
  # a jev Off. A ticket that was not a candidate has no question, and a
  # newly blocked candidate after the judged one is not a contradiction.
  def path_correction(refs, unblocked, newly, judged)
    limit = judged ? refs.index(judged) : refs.size
    pairs = unblocked.map { |r| [refs.index(r), DOES_NOT_BLOCK_LABEL] } +
            newly.map { |r| [refs.index(r), BLOCKS_LABEL] }.select { |i, _| i && i < limit }
    pairs.reject { |i, _| i.nil? }.sort_by(&:first).to_h { |i, label| ["cand_#{i}", label] }
  end

  # blocking_tally(verdicts) -> {counts: {reason => n}, refs: {reason =>
  # [DND refs]}, edits: [[ref, "path", call, correction]]}.
  def blocking_tally(verdicts)
    counts = BLOCKING_REASONS.to_h { |r| [r, 0] }
    refs = Hash.new { |h, k| h[k] = [] }
    edits = []
    verdicts.each do |ref, verdict|
      counts[verdict.first] += 1
      refs[verdict.first] << ref if BLOCKING_NAMED.include?(verdict.first)
      edits << [ref, PATH_PROPERTY, verdict[1], verdict[2]] if verdict.first == "edited"
    end
    { counts: counts, refs: refs.to_h, edits: edits }
  end
end
