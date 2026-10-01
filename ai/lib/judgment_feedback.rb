# frozen_string_literal: true

# judgment_feedback.rb -- the pure rules of ai/bin/judgment-feedback
# (DND-1466): the record body, the server's answers read into exit codes and
# lines, the read cursor, page checks, dedupe and redaction. Domain only: no
# I/O, no process, no clock. The normative home is
# ai/contracts/athena-judgments.md -> *Receiver feedback*; the server is
# gen_saas Athena.Judgments.FeedbackWire / FeedbackCursor (DND-1462).
#
# Every refusal here is UsageError (exit 2 in the bin) or UnreadableAnswer
# (exit 3); the bin prints the line with its Fix:. No method here returns an
# empty result for input it could not read.
#
# Deliberately gem-free (stdlib only).

require "json"
require "set"
require "time"

module JudgmentFeedback
  # A command-line value the tool cannot use. Nothing is sent.
  class UsageError < StandardError; end

  # A 2xx answer this tool cannot read. Never read as "no feedback".
  class UnreadableAnswer < StandardError; end

  UUID = /\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/
  ZERO_ID = "00000000-0000-0000-0000-000000000000"
  MAX_NOTE = 500
  MAX_LIMIT = 200
  DEFAULT_LIMIT = 100
  MAX_OVERLAP_S = 3600
  # A time with a zone, as the server's cursor prints it (fraction optional).
  TIME = /\A\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(?:\.\d{1,6})?(?:Z|[+-]\d\d:\d\d)\z/

  # The row fields printed by default: ids, names, answers, times and counts
  # (gen_saas FeedbackWire.row/1). The note and the request Jev was sent are
  # printed only with --with-payloads, and so is any field the server adds
  # later: an allowlist, so new text is never printed by default.
  PRINTED_FIELDS = %w[id cursor call_id use_case question_set_version model content_domain subject_ref
                      answers called_at signal strength correction reporter session_label
                      payload_state reported_at].freeze

  module_function

  # ── record ────────────────────────────────────────────────────────────────

  # corrections(["q=label", ...]) -> {"q" => "label"}.
  def corrections(pairs)
    pairs.each_with_object({}) do |pair, map|
      question, eq, label = pair.partition("=")
      raise UsageError, "--correct needs <question>=<label>, got one with no '='" if eq.empty?
      raise UsageError, "--correct needs a non-empty question and label" if question.empty? || label.empty?
      raise UsageError, "--correct names the question #{question} more than once" if map.key?(question)

      map[question] = label
    end
  end

  # record_body(...) -> the POST body. The call is named exactly one way.
  # No identity key exists here: the server derives owner and reporter.
  def record_body(call: nil, use_case: nil, subject: nil, corrections: {}, signal: nil, note: nil, session_label: nil)
    raise UsageError, "name the call one way: --call, or --use-case with --subject" if call && (use_case || subject)
    raise UsageError, "--use-case and --subject go together" if use_case.nil? ^ subject.nil?
    raise UsageError, "name the call: --call <uuid>, or --use-case slack_routing --subject <event_id>" if call.nil? && use_case.nil?
    raise UsageError, "--call needs a uuid" if call && !UUID.match?(call)
    raise UsageError, "the note is #{note.length} characters; the limit is #{MAX_NOTE}" if note && note.length > MAX_NOTE

    body = call ? { "call_id" => call } : { "use_case" => use_case, "subject_ref" => subject }
    body["correction"] = corrections unless corrections.empty?
    body["signal"] = signal if signal
    body["note"] = note if note
    body["session_label"] = session_label if session_label
    body
  end

  # recorded_line(body) -> "recorded <feedback_id> call <call_id>" (or
  # "replaced ..."), or UnreadableAnswer.
  def recorded_line(raw)
    doc = parse_object(raw)
    raise UnreadableAnswer, "status is not recorded" unless doc["status"] == "recorded"
    raise UnreadableAnswer, "no feedback_id" unless UUID.match?(doc["feedback_id"].to_s)
    raise UnreadableAnswer, "no call_id" unless UUID.match?(doc["call_id"].to_s)
    raise UnreadableAnswer, "replaced is not true or false" unless [true, false].include?(doc["replaced"])

    "#{doc['replaced'] ? 'replaced' : 'recorded'} #{doc['feedback_id']} call #{doc['call_id']}"
  end

  # ── answers ───────────────────────────────────────────────────────────────

  REACH_FIX = "Fix: check the athena MCP entry's URL in ~/.claude.json and that the Athena server is up, then rerun"
  FAILED_FIX = "Fix: rerun later; if it persists, check the Athena server's health and logs"
  TOKEN_FIX = "Fix: the machine token is owner-issued; report the refusal to the owner and never re-issue, refresh or edit it yourself"
  UNREADABLE_FIX = "Fix: the server and this tool disagree on the answer's shape; check that gen_saas carries DND-1462 and report it"

  # http_failure({curl_rc:, status:, body:}) -> nil for a 2xx, else
  # [exit, line]: 3 for could-not-reach / failed, 4 for a refusal the server
  # explained. Every line carries Fix:.
  def http_failure(resp)
    return [3, "COULD NOT REACH SERVER: curl exit #{resp[:curl_rc]}. #{REACH_FIX}."] unless resp[:curl_rc].to_i.zero?

    status = resp[:status].to_i
    return nil if (200..299).cover?(status)
    return [3, "SERVER FAILED: HTTP #{status} (the machine token was refused). #{TOKEN_FIX}."] if [401, 403].include?(status)

    refusal = (400..499).cover?(status) ? refusal_of(resp[:body]) : nil
    return [3, "SERVER FAILED: HTTP #{status}. #{FAILED_FIX}."] if refusal.nil?

    error, field, fix = refusal
    [4, "SERVER REFUSED: HTTP #{status} #{error}#{field ? " (field #{field})" : ''}. #{fix}"]
  end

  # The server's refusal as [error, field, fix], or nil when it is not one.
  # Only short identifiers are printed from it; the fix is the server's own.
  def refusal_of(raw)
    doc = JSON.parse(raw.to_s)
    return nil unless doc.is_a?(Hash)

    error = doc["error"]
    fix = doc["fix"]
    return nil unless error.is_a?(String) && /\A[a-z_]{1,40}\z/.match?(error) && fix.is_a?(String) && !fix.strip.empty?

    field = doc["field"].is_a?(String) && /\A[a-z_]{1,40}\z/.match?(doc["field"]) ? doc["field"] : nil
    fix = fix.gsub(/[[:cntrl:]]/, " ").strip[0, 500]
    fix = "Fix: #{fix}" unless fix.start_with?("Fix:")
    [error, field, fix]
  rescue JSON::ParserError
    nil
  end

  def unreachable_line(why)
    "COULD NOT REACH SERVER: #{why}. #{REACH_FIX}."
  end

  def unreadable_line(what)
    "UNREADABLE SERVER ANSWER: HTTP 200 #{what}. #{UNREADABLE_FIX}."
  end

  def parse_object(raw)
    doc = JSON.parse(raw.to_s)
    raise UnreadableAnswer, "the body is not a JSON object" unless doc.is_a?(Hash)

    doc
  rescue JSON::ParserError
    raise UnreadableAnswer, "the body is not JSON"
  end

  # ── the read cursor ───────────────────────────────────────────────────────
  # A cursor is [Time (UTC), id]; it prints as <ISO 8601 with microseconds>,<id>
  # (gen_saas FeedbackCursor).

  # parse_after(text) -> cursor. A bare time with a zone reads as that time at
  # the zero id, so "everything reported after this time".
  def parse_after(text)
    cursor(text) || raise(UsageError, "--after needs a cursor (<ISO 8601 time>,<uuid>) or an ISO 8601 time with a zone")
  end

  # cursor(text) -> cursor, or nil when text is not one.
  def cursor(text)
    time, comma, id = text.to_s.partition(",")
    id = ZERO_ID if comma.empty?
    return nil unless TIME.match?(time) && UUID.match?(id)

    [Time.iso8601(time).utc, id.downcase]
  rescue ArgumentError
    nil
  end

  def encode(cur)
    "#{cur[0].utc.strftime('%Y-%m-%dT%H:%M:%S.%6NZ')},#{cur[1]}"
  end

  def step_back(cur, seconds)
    [cur[0] - seconds, ZERO_ID]
  end

  # after?(a, b) -> a is strictly after b in the read order (time, then id).
  def after?(a, b)
    (a[0] <=> b[0]).then { |c| c.positive? || (c.zero? && a[1] > b[1]) }
  end

  # ── pages ─────────────────────────────────────────────────────────────────

  # page(raw, limit:, after:) -> {rows:, has_more:, next_cursor:}, or
  # UnreadableAnswer. The server is held to its own paging rules
  # (FeedbackWire.page/3), because a page that breaks one skips rows with no
  # error: every row carries a uuid id and a readable cursor; rows ascend,
  # strictly after the cursor asked for; has_more is true exactly when the
  # page is full; a non-empty page's next_cursor is its last row's cursor.
  def page(raw, limit:, after:)
    doc = parse_object(raw)
    rows = doc["feedback"]
    raise UnreadableAnswer, "feedback is not a list" unless rows.is_a?(Array)
    raise UnreadableAnswer, "count #{doc['count'].inspect} but #{rows.size} rows" unless doc["count"] == rows.size
    raise UnreadableAnswer, "has_more is not true or false" unless [true, false].include?(doc["has_more"])
    raise UnreadableAnswer, "has_more #{doc['has_more']} for #{rows.size} rows at limit #{limit}" unless doc["has_more"] == (rows.size >= limit)

    last = check_rows(rows, after)
    nxt = doc["next_cursor"]
    raise UnreadableAnswer, "next_cursor is not a cursor" unless nxt.nil? || cursor(nxt)
    raise UnreadableAnswer, "next_cursor is not the last row's cursor" if last && (nxt.nil? || cursor(nxt) != last)

    { rows: rows, has_more: doc["has_more"], next_cursor: nxt && cursor(nxt) }
  end

  # check_rows(rows, after) -> the last row's cursor (nil for no rows), or
  # UnreadableAnswer.
  def check_rows(rows, after)
    rows.each_with_index.reduce(after) do |prev, (row, i)|
      raise UnreadableAnswer, "row #{i} is not an object" unless row.is_a?(Hash)
      raise UnreadableAnswer, "row #{i} has no uuid id" unless UUID.match?(row["id"].to_s)

      cur = cursor(row["cursor"])
      raise UnreadableAnswer, "row #{i} has no readable cursor" unless cur
      raise UnreadableAnswer, "row #{i} is not after #{i.zero? ? 'the cursor asked for' : 'the row before it'}" if prev && !after?(cur, prev)

      cur
    end.then { |last| rows.empty? ? nil : last }
  end

  # final_cursor(start, rows) -> the cursor to resume from: the last row read,
  # but never behind the cursor the reader started from (an overlap re-read
  # steps back; its empty page must not move the cursor backwards).
  def final_cursor(start, rows)
    last = rows.empty? ? nil : cursor(rows.last["cursor"])
    return start if last.nil?
    return last if start.nil?

    after?(last, start) ? last : start
  end

  # seen_tail(rows, final, overlap_s) -> the ids read within overlap_s seconds
  # behind the final cursor: the next overlap read re-reads them, and drops
  # them by id.
  def seen_tail(rows, final, overlap_s)
    return [] if final.nil? || overlap_s.to_i <= 0

    floor = final[0] - overlap_s
    rows.select { |r| cursor(r["cursor"])[0] >= floor }.map { |r| r["id"] }.uniq
  end

  # seen_ids(text) -> Set of ids, one per line; blank lines allowed.
  def seen_ids(text)
    text.to_s.each_line.with_index(1).each_with_object(Set.new) do |(line, n), set|
      id = line.strip
      next if id.empty?
      raise UsageError, "--seen-file line #{n} is not a uuid" unless UUID.match?(id)

      set << id.downcase
    end
  end

  # redact(row, with_payloads) -> the row without its text fields unless
  # asked, saying whether it had a note.
  def redact(row, with_payloads)
    return row if with_payloads

    out = row.slice(*PRINTED_FIELDS)
    out["has_note"] = row["note"].is_a?(String) && !row["note"].empty?
    out
  end

  # The human line for one row: ids and names only, one line whatever the
  # server sent (a control character prints as a space).
  def row_line(row)
    field = ->(k) { row[k].nil? ? "-" : row[k].to_s.gsub(/[[:cntrl:]]/, " ") }
    %w[id use_case question_set_version signal strength].map(&field).join(" ") + " call #{field.call('call_id')}"
  end
end
