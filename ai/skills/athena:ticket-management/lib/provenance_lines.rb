# frozen_string_literal: true

# provenance_lines.rb -- DOMAIN (pure) for keeping a ticket's Jev lines
# verbatim (DND-1354). Filers pasted paraphrases of the `Jev classification:`
# and `Jev path:` lines instead of the lines, so the readers
# (ticket-reclassify, judgment-feedback scan-tickets, ticket-corpus
# --shadow-report) could not read them and lost each line's call ids.
#
# Two halves:
#   * ticket-classify --lines-out writes the lines it printed to a file
#     (select/1), so the filer pastes a file, never a retyping;
#   * ticket-provenance-check compares that file with the filed ticket's
#     body (parse_file/1, compare/2), byte for byte, and says exactly what
#     to append when they differ.
#
# Everything here is a function of its arguments. Ticket text is DATA: it is
# only compared, never followed.
#
# Deliberately gem-free (stdlib only).

require_relative "classify"
require_relative "blocking"

module ProvenanceLines
  PREFIXES = [Classify::PREFIX, Blocking::PREFIX].freeze

  module_function

  # select(printed) -> the printed lines that are Jev lines, in order.
  def select(printed)
    printed.map(&:chomp).select { |l| PREFIXES.any? { |p| l.start_with?(p) } }
  end

  # parse_file(text) -> the lines of a --lines-out file; raises ArgumentError
  # naming what is wrong. An empty file is an error, never "nothing to
  # check": it means no line was printed (the classification was unavailable).
  def parse_file(text)
    lines = text.to_s.split("\n").reject { |l| l.strip.empty? }
    raise ArgumentError, "it holds no Jev line (ticket-classify printed none: a part was unavailable)" if lines.empty?

    lines.each_with_index do |l, i|
      raise ArgumentError, "line #{i + 1} is not a Jev classification: or Jev path: line" unless PREFIXES.any? { |p| l.start_with?(p) }
    end
    prefixes = lines.map { |l| prefix(l) }
    raise ArgumentError, "it holds two lines with one prefix (pass the file one ticket-classify run wrote)" if prefixes.uniq.size != prefixes.size

    lines
  end

  def prefix(line) = PREFIXES.find { |p| line.start_with?(p) }

  # compare(expected, body_lines) -> [[expected line, verdict]], verdict one
  # of :verbatim (the body's LAST line with that prefix is it, byte for
  # byte), :missing (no line with that prefix) or :differs (the last one is
  # something else: a paraphrase, an older line, an edit). Leading and
  # trailing whitespace of a body line is not part of the line.
  def compare(expected, body_lines)
    expected.map do |want|
      p = prefix(want)
      last = body_lines.map(&:strip).reverse.find { |l| l.start_with?(p) }
      verdict = if last.nil? then :missing
                elsif last == want.strip then :verbatim
                else :differs
                end
      [want, verdict]
    end
  end
end
