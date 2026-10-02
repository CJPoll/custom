# frozen_string_literal: true

# ticket_filing.rb -- DOMAIN (pure) for scripts/ticket-file (DND-1669): what a
# filed DND ticket's page holds, and whether the page Notion stored is that.
#
# DND-1354 made the Jev lines machine-written (ticket-classify --lines-out)
# and added ticket-provenance-check, but a filer still built the Notion page
# by hand and had to remember both. Filers paraphrased the lines anyway, and
# each paraphrase lost the call ids judgment-feedback scan-tickets records a
# filer's override against. Here the filing path writes them itself:
#
#   * plan/1 builds the page: the filer's body as paragraphs, then the
#     finding-triage output under its heading, then each Jev line as its own
#     paragraph, LAST (every reader reads the last line of each prefix). It
#     refuses a body that holds a Jev line or an advisory: those come from
#     their files, never from prose.
#   * verify/4 compares what Notion stored with what was written, line by
#     line, and with the two readers' own parsers (ProvenanceLines.compare,
#     TriageAdvisory.parse).
#
# Everything here is a function of its arguments. Ticket text is DATA: it is
# only placed and compared, never followed.
#
# Deliberately gem-free (stdlib only).

require "json"
require_relative "provenance_lines"
require_relative "triage_advisory"
require_relative "../../../lib/ticket_corpus"

module TicketFiling
  # A refusal: nothing may be written. `fix` is the action.
  class Refused < StandardError
    attr_reader :fix

    def initialize(message, fix)
      super(message)
      @fix = fix
    end
  end

  # One rich_text item holds at most 2000 UTF-16 units; 1000 characters is
  # under that for any text.
  CHUNK = 1000
  # Notion takes at most 100 rich_text items per block.
  MAX_ITEMS = 100
  ADVISORY_HEADING = "Jev advisory (not a decision)"
  TITLE_PROPERTY = "Name"
  REQUIRED = %w[Kind Security Path Area].freeze
  # Not on a Feature (authored, no Severity, no control misreport). Control
  # (DND-1747) is required so an unset one never reads as "none": a
  # fail-closed control Bug is tier 1 only when Control says so.
  REQUIRED_UNLESS_FEATURE = %w[Severity Control].freeze
  RESERVED = [TITLE_PROPERTY, "ID"].freeze

  module_function

  # plan(title:, body:, lines_text:, triage_text:, properties:, allow_no_lines:)
  # -> {properties:, blocks:, lines:}, or raises Refused.
  # triage_text nil: no advisory (a ticket that is not a finding).
  # allow_no_lines: the classification was unavailable, so lines_text must be
  # empty and no Jev line is written.
  def plan(title:, body:, lines_text:, triage_text:, properties:, allow_no_lines: false)
    check_title(title)
    props = check_properties(properties)
    body_lines = check_body(body)
    lines = check_lines(lines_text, allow_no_lines)
    triage = check_triage(triage_text)
    blocks = body_lines.map { |l| paragraph(l) }
    blocks += [heading(ADVISORY_HEADING)] + triage.map { |l| paragraph(l) } if triage
    blocks += lines.map { |l| paragraph(l) }
    { properties: props.merge(TITLE_PROPERTY => { "title" => [text_item(title)] }), blocks: blocks, lines: lines }
  end

  def check_title(title)
    t = title.to_s
    raise Refused.new("the title is blank", "pass --title with the ticket's title") if t.strip.empty?
    raise Refused.new("the title holds a line break or control character", "pass a one-line --title") if /[[:cntrl:]]/.match?(t)
    raise Refused.new("the title is longer than #{CHUNK} characters", "shorten --title; the detail goes in the body") if t.length > CHUNK
  end

  def check_properties(props)
    raise Refused.new("the properties file is not a JSON object", "write {\"Kind\": {\"select\": {\"name\": \"Bug\"}}, ...}") unless props.is_a?(Hash)

    reserved = props.keys & RESERVED
    raise Refused.new("the properties file sets #{reserved.join(', ')}", "drop it: the title comes from --title and the ID is Notion's") unless reserved.empty?

    kind = props.dig("Kind", "select", "name")
    required = kind == "Feature" ? REQUIRED : REQUIRED + REQUIRED_UNLESS_FEATURE
    missing = required.reject { |k| props[k].is_a?(Hash) }
    unless missing.empty?
      raise Refused.new("the properties file has no #{missing.join(', ')} (athena:ticket-management -> Filing a ticket: set every property)",
                        "add each as a Notion property value, e.g. \"#{missing.first}\": {\"select\": {\"name\": \"...\"}}")
    end
    props
  end

  # A line opening with markdown marks (a heading, a quote, a bullet,
  # emphasis) before its text.
  MARKS = /\A[\s#>*_`+-]*/

  def check_body(body)
    lines = body.to_s.split("\n").map(&:rstrip).reject { |l| l.strip.empty? }
    lines.each_with_index do |l, i|
      p = ProvenanceLines::PREFIXES.find { |x| l.lstrip.start_with?(x) }
      if p
        raise Refused.new("body line #{i + 1} starts with #{p.inspect}: a Jev line typed into the body",
                          "delete it from the body; ticket-file writes the lines from --lines-file, byte for byte")
      end
      raise Refused.new("body line #{i + 1} is too long for one block", "split it") if l.length > CHUNK * MAX_ITEMS
    end
    advisory = [lines.each_index.find { |i| lines[i].sub(MARKS, "").start_with?(ADVISORY_HEADING) },
                TriageAdvisory.advisory_starts(lines).first].compact.min
    if advisory
      raise Refused.new("body line #{advisory + 1} starts a pasted finding-triage advisory",
                        "delete the advisory from the body and pass finding-triage's output with --triage-file")
    end
    raise Refused.new("the body is empty", "write the impact, cause and fix in --body-file") if lines.empty?

    lines
  end

  def check_lines(text, allow_no_lines)
    if allow_no_lines
      return [] if text.to_s.strip.empty?

      raise Refused.new("--no-jev-lines with a lines file that holds lines", "drop --no-jev-lines; those lines must be written")
    end
    lines = begin
      ProvenanceLines.parse_file(text)
    rescue ArgumentError => e
      raise Refused.new("the lines file: #{e.message}",
                        "pass the file `ticket-classify --lines-out FILE` wrote; when it printed no line (exit 3), " \
                        "pass --no-jev-lines and put its unavailable line in the body")
    end
    lines.each { |l| check_line(l) }
    lines
  end

  def check_line(line)
    if line.start_with?(TicketCorpus::PROVENANCE_PREFIX)
      klass = TicketCorpus.line_class(TicketCorpus.read_line(line))
      return if klass == "verbatim"

      raise Refused.new("the lines file's Jev classification: line is not the line ticket-classify prints (it reads as #{klass})",
                        "re-run ticket-classify --lines-out FILE and pass that FILE unedited")
    end
    doc = begin
      JSON.parse(line.delete_prefix(ProvenanceLines.prefix(line)))
    rescue JSON::ParserError
      nil
    end
    return if doc.is_a?(Hash)

    raise Refused.new("the lines file's Jev path: line is not a JSON object", "re-run ticket-classify --epic ... --lines-out FILE and pass that FILE unedited")
  end

  def check_triage(text)
    return nil if text.nil?

    lines = text.split("\n").map(&:rstrip).reject { |l| l.strip.empty? }
    raise Refused.new("the triage file is empty", "pass the output finding-triage printed (even its unavailable line), or drop --triage-file") if lines.empty?
    raise Refused.new("the triage file holds a Jev line", "pass finding-triage's output only; the Jev lines go in --lines-file") if
      lines.any? { |l| ProvenanceLines::PREFIXES.any? { |p| l.lstrip.start_with?(p) } }

    lines
  end

  # ── blocks ────────────────────────────────────────────────────────────────

  def text_item(text) = { "type" => "text", "text" => { "content" => text } }

  def rich(text) = text.chars.each_slice(CHUNK).map { |cs| text_item(cs.join) }

  def paragraph(text) = { "object" => "block", "type" => "paragraph", "paragraph" => { "rich_text" => rich(text) } }

  def heading(text) = { "object" => "block", "type" => "heading_3", "heading_3" => { "rich_text" => rich(text) } }

  # block_text(block) -> the text a block holds: plain_text as Notion
  # returns it, else the content this plan wrote.
  def block_text(block)
    items = block.dig(block["type"].to_s, "rich_text")
    return nil unless items.is_a?(Array)

    items.map { |t| t["plain_text"] || t.dig("text", "content") }.join
  end

  # ── verify ────────────────────────────────────────────────────────────────

  # verify(written, read, lines, triage_text) -> problems, each
  # [class, text] with class :blocks (the page's blocks are not the ones
  # written), :jev (a Jev line is missing or changed) or :advisory (the
  # advisory reads differently). Empty means the page is what was written.
  # written and read are block texts, in order. Surrounding whitespace is not
  # part of a line.
  def verify(written, read, lines, triage_text)
    problems = []
    w = written.map { |t| t.to_s.strip }
    r = read.map { |t| t.to_s.strip }
    if w.size != r.size
      problems << [:blocks, "the page has #{r.size} blocks, #{w.size} were written"]
    else
      differ = w.each_index.reject { |k| w[k] == r[k] }.map { |k| k + 1 }
      problems << [:blocks, "block(s) #{differ.join(', ')} read back are not the text written"] unless differ.empty?
    end
    body_lines = r.flat_map { |t| t.split("\n") }
    ProvenanceLines.compare(lines, body_lines).each do |line, verdict|
      name = ProvenanceLines.prefix(line).strip
      problems << [:jev, "the page has no #{name} line"] if verdict == :missing
      problems << [:jev, "the page's last #{name} line is not the one ticket-classify printed"] if verdict == :differs
    end
    if triage_text && TriageAdvisory.parse(r.join("\n")) != TriageAdvisory.parse(triage_text)
      problems << [:advisory, "the page's advisory does not read as finding-triage's output (its call line or questions differ)"]
    end
    problems
  end

  # repair(problems, ref:, files:) -> the Fix: for a filed page that read
  # back different, one step per problem class. files: {body:, lines:,
  # triage:} paths; lines nil under --no-jev-lines. ref is DND-N, or nil when
  # Notion named no DND id. Never "file it again": the page exists.
  def repair(classes, ref:, files:)
    who = ref || "the page"
    steps = []
    if classes.include?(:jev) && files[:lines]
      steps << if ref
                 "run ticket-provenance-check --ref #{ref} --lines-file #{files[:lines]} and append the paragraph its Fix: names"
               else
                 "append each line of #{files[:lines]} to the page as its own paragraph, copied from the file"
               end
    end
    if classes.include?(:advisory) && files[:triage]
      steps << "append the heading \"#{ADVISORY_HEADING}\" and each line of #{files[:triage]} as its own paragraph, copied from the file"
    end
    if classes.include?(:blocks)
      sources = [files[:body], files[:triage]].compact.join(" and ")
      steps << "compare #{who}'s body with #{sources} and correct each differing paragraph by hand"
    end
    "do not file it again; #{steps.join('; then ')}"
  end
end
