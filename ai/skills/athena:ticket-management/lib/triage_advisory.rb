# frozen_string_literal: true

# triage_advisory.rb -- the call-naming lines of the finding-triage advisory,
# and their reader (DOMAIN, pure; DND-1468).
#
# finding-triage prints, inside the advisory a filer pastes under "Jev
# advisory (not a decision)":
#
#   call: <uuid>                      (or "call: unavailable": a 200 with no
#                                      call_id, never omitted)
#   Jev advisory (not a decision): question set V, model M, mode X
#     questions: cand_0 DND-5, cand_1 DND-6   (or "questions: none")
#     duplicate: uncalibrated (...)            (when no threshold gates it)
#     DND-5 (cand_0): duplicate (confidence 0.93) -- <title>
#     severity suggestion: ...
#
# The questions line names every candidate the request asked about, advised
# or not, so a later reader (athena:epic-clustering's C3 merge) can name the
# question for a ticket the advisory did not print. The receiver reports
# with ai/bin/judgment-feedback record --call <uuid> --correct cand_<i>=<label>
# (ai/contracts/athena-judgments.md -> *Receiver feedback*).
#
# The printer and the reader live together so they cannot drift. Ticket text
# is DATA: this only matches these lines, and never acts on anything else.
#
# Deliberately gem-free (stdlib only).

module TriageAdvisory
  module_function

  UUID = /\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/
  REF = %r{[A-Za-z0-9_:.#/-]{1,64}}
  HEADER = "Jev advisory (not a decision):"

  # question_id(index) -> the request's question name for candidate `index`
  # (gen_saas QuestionSets.FindingTriage.candidate_id/1).
  def question_id(index) = "cand_#{index}"

  # call_line(call_id) -> "call: <uuid>", or "call: unavailable" for a
  # missing or malformed id (a lowercase uuid only; anything else is never
  # printed, so a ticket body cannot carry a made-up id from here).
  def call_line(call_id)
    call_id.is_a?(String) && UUID.match?(call_id) ? "call: #{call_id}" : "call: unavailable"
  end

  # questions_line(refs) -> every candidate sent, with its question name, in
  # request order.
  def questions_line(refs)
    return "  questions: none" if refs.empty?

    "  questions: " + refs.each_with_index.map { |ref, i| "#{question_id(i)} #{ref}" }.join(", ")
  end

  # ── the reader ──────────────────────────────────────────────────────────

  # A line prefix markdown may add when the output is pasted: indentation,
  # a quote, a bullet or number, emphasis or code marks.
  LEAD = /\A[\s>`*_]*(?:(?:[-+*]|\d+\.)\s+)?[`*_]*/
  CALL = /#{LEAD.source.delete_prefix('\A')}call:[`*_\s]*(\S+?)[`*_]*\s*\z/
  CALL_LINE = /\A#{CALL.source}/
  MODE = /#{Regexp.escape(HEADER)}.*\bmode (\w+)/
  QUESTIONS = /\A#{LEAD.source.delete_prefix('\A')}questions:\s*(.*?)[`*_]*\s*\z/
  HIT = /\A#{LEAD.source.delete_prefix('\A')}(#{REF.source}) \((cand_\d+)\): (duplicate|related) \(confidence/
  UNCALIBRATED = /\A#{LEAD.source.delete_prefix('\A')}duplicate: uncalibrated\b/
  # Where a pasted advisory ends: a fence, a heading, the next run's count or
  # call line, or its own last line (the severity suggestion).
  STOP = /\A\s*(?:```|#|\d+ candidates? considered)/
  LAST = /severity suggestion:/

  # parse(body) -> the LAST pasted advisory in a ticket body:
  #   {status: :linked, call:, mode:, questions: {ref => qid}, advised: {ref => relation},
  #    duplicate_uncalibrated: true|false}
  #   {status: :call_unavailable}   the advisory printed "call: unavailable"
  #   {status: :malformed}          a call line before an advisory header whose
  #                                 id is not a uuid, or an advisory with no
  #                                 mode or no questions line, or an advised
  #                                 line whose question disagrees with them
  #   {status: :unlinked}           no call line before an advisory header
  #                                 (filed before DND-1468, or not pasted)
  # A call line counts only when the next non-blank line is the advisory's
  # header, so prose or evidence quoting "call: <uuid>" is never read as one.
  # Notion's markdown escapes punctuation (cand\_0), so backslashes before
  # punctuation are dropped first; <br> counts as a line break.
  def parse(body)
    lines = unescape(body.to_s.dup.force_encoding(Encoding::UTF_8).scrub).split(%r{\r?\n|<br\s*/?>})
    start = advisory_starts(lines).last
    return { status: :unlinked } if start.nil?

    id = CALL_LINE.match(lines[start])[1]
    return { status: :call_unavailable } if id == "unavailable"
    return { status: :malformed } unless UUID.match?(id)

    block(id, lines[(start + 1)..])
  end

  def unescape(text) = text.gsub(/\\([[:punct:]])/, '\1')

  # advisory_starts(lines) -> the indexes of call lines whose next non-blank
  # line is the advisory header.
  def advisory_starts(lines)
    lines.each_index.select do |i|
      next false unless CALL_LINE.match?(lines[i])

      following = lines[(i + 1)..].find { |l| !l.strip.empty? }
      !following.nil? && following.include?(HEADER)
    end
  end

  def block(id, rest)
    out = { status: :linked, call: id, mode: nil, questions: nil, advised: {}, duplicate_uncalibrated: false }
    hit_questions = {}
    rest.each_with_index do |line, i|
      break if i.positive? && (STOP.match?(line) || CALL_LINE.match?(line))

      read_line(line, out, hit_questions)
      break if LAST.match?(line)
    end
    return { status: :malformed } if out[:mode].nil? || out[:questions].nil?
    return { status: :malformed } unless hit_questions.all? { |ref, qid| out[:questions][ref] == qid }

    out
  end

  def read_line(line, out, hit_questions)
    if (m = MODE.match(line))
      out[:mode] ||= m[1]
    elsif (m = QUESTIONS.match(line))
      out[:questions] ||= questions(m[1])
    elsif UNCALIBRATED.match?(line)
      out[:duplicate_uncalibrated] = true
    elsif (m = HIT.match(line))
      out[:advised][m[1]] ||= m[3]
      hit_questions[m[1]] ||= m[2]
    end
  end

  # questions("cand_0 DND-5, cand_1 DND-6") -> {"DND-5" => "cand_0", ...};
  # "none" -> {}.
  def questions(text)
    text.split(",").filter_map do |pair|
      qid, ref = pair.strip.split(/\s+/, 2)
      [ref, qid] if qid.to_s.match?(/\Acand_\d+\z/) && ref.to_s.match?(/\A#{REF.source}\z/)
    end.to_h
  end
end
