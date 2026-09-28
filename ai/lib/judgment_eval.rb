# frozen_string_literal: true

# ai/lib/judgment_eval.rb -- DOMAIN (pure) for ai/bin/judgment-eval (DND-710).
#
# Everything here is a function of its arguments: parse the label and corpus
# JSONL text, join them by id, split the cases into batches, and render the
# server's report as lines. No file, network or process access; the bin owns
# those (its Effects) and orchestrates (its Manager).
#
# Normative home: ~/dev/custom/ai/contracts/athena-judgments.md ->
# *Threshold provenance, n/a and the pinned model*. The server
# (gen_saas Athena.Judgments.Evals) computes every metric; this side only
# joins, batches and prints, so a metric can never differ between the two.
#
# Deliberately gem-free (stdlib only).

require "json"

module JudgmentEval
  USE_CASES = %w[finding_triage slack_routing priority_scoring ticket_kind ticket_severity ticket_security].freeze
  PROVENANCES = %w[forward_record owner_confirmed tracker_record rule_confirmed title_prefix proposed].freeze
  DOMAINS = %w[work blend personal].freeze
  MAX_BATCH = 50
  # The corpus key a label's id joins on. Slack routing joins the inbox's own
  # lines on event_id (A&E 5b: the text is never copied into a second file).
  ID_KEYS = Hash.new("id").merge("slack_routing" => "event_id").freeze
  CASE_ID = /\A[A-Za-z0-9_:.#\/-]{1,200}\z/
  LABEL = /\A[A-Za-z0-9_.:-]{1,64}\z/
  UUID = /\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/

  # A refusal of the INPUT files: exit 1, one line, with a Fix:.
  class InputError < StandardError
    attr_reader :fix

    def initialize(message, fix)
      super(message)
      @fix = fix
    end
  end

  module_function

  # parse_labels(text, path) -> [{id, label, provenance}]
  # An empty file is its own error, distinct from a missing one (the bin says
  # which): zero labels can never read as "nothing to evaluate, fine".
  def parse_labels(text, path)
    rows = jsonl(text, path, "labels")
    raise InputError.new("labels file #{path} is empty (0 rows)", "write one JSON object per line: {id, label, provenance, labeler, labeled_at}") if rows.empty?

    seen = {}
    rows.map do |line_no, row|
      label = label_row(row, path, line_no)
      raise InputError.new("#{path}:#{line_no} repeats id of line #{seen[label[:id]]}", "keep one label per id") if seen.key?(label[:id])

      seen[label[:id]] = line_no
      label
    end
  end

  def label_row(row, path, line_no)
    where = "#{path}:#{line_no}"
    id = row["id"]
    label = row["label"]
    provenance = row["provenance"]
    raise InputError.new("#{where} has no opaque id", "an id is letters, digits and _ : . # / - (at most 200)") unless id.is_a?(String) && CASE_ID.match?(id)
    raise InputError.new("#{where} has no short label", "a label is letters, digits and _ . : - (at most 64)") unless label.is_a?(String) && LABEL.match?(label)
    raise InputError.new("#{where} has provenance #{safe(provenance)}", "use one of #{PROVENANCES.join(', ')}") unless PROVENANCES.include?(provenance)

    { id: id, label: label, provenance: provenance }
  end

  # parse_corpus(text, path, use_case) -> {rows: {id => {input, content_domain}}, without_id: n}
  # A row with no id is counted, never silently dropped.
  def parse_corpus(text, path, use_case)
    key = ID_KEYS[use_case]
    rows = jsonl(text, path, "corpus")
    raise InputError.new("corpus file #{path} is empty (0 rows)", "point --corpus at the file the labels were made from") if rows.empty?

    by_id = {}
    without_id = 0
    rows.each do |_line_no, row|
      id = row[key]
      if id.is_a?(String) && !id.empty?
        by_id[id] ||= { input: row.key?("input") ? row["input"] : row, content_domain: row["content_domain"] }
      else
        without_id += 1
      end
    end
    { rows: by_id, without_id: without_id, id_key: key }
  end

  # join(labels, corpus) -> {cases:, proposed:, missing:}
  # `proposed` labels are excluded from the run (they never select a
  # threshold) and counted. A label whose id the corpus lacks is MISSING:
  # counted and named, never quietly dropped.
  def join(labels, corpus)
    proposed, usable = labels.partition { |l| l[:provenance] == "proposed" }
    cases = []
    missing = []
    usable.each do |l|
      row = corpus[:rows][l[:id]]
      if row
        cases << { "case_id" => l[:id], "label" => l[:label], "input" => row[:input], "content_domain" => row[:content_domain] }
      else
        missing << l[:id]
      end
    end
    { cases: cases, proposed: proposed.size, missing: missing }
  end

  # with_domain(cases, default) -> [cases, count_without_domain]
  def with_domain(cases, default)
    lacking = 0
    filled = cases.map do |c|
      domain = c["content_domain"] || default
      lacking += 1 if domain.nil?
      c.merge("content_domain" => domain).compact
    end
    [filled, lacking]
  end

  def batches(cases, size)
    cases.each_slice(size).to_a
  end

  def label_counts(cases)
    cases.group_by { |c| c["label"] }.transform_values(&:size).sort.to_h
  end

  def provenance_counts(labels)
    labels.group_by { |l| l[:provenance] }.transform_values(&:size).sort.to_h
  end

  # summary_lines(report) -> lines. With nothing scored there are NO label
  # lines: a run with no key can never print a precision.
  def summary_lines(report)
    scored = report.fetch("scored")
    unscored = report.fetch("unscored")
    total = unscored.values.sum
    lines = ["scored #{scored} / unscored #{total}#{reasons(unscored)}"]
    return lines if scored.zero?

    lines + report.fetch("labels").map { |row| label_line(row) }
  end

  def reasons(unscored)
    return "" if unscored.empty?

    " (" + unscored.sort.map { |reason, n| unscored.size == 1 ? reason : "#{reason} #{n}" }.join(", ") + ")"
  end

  def label_line(row)
    chosen = row["chosen"]
    return "  #{row['label']}: #{n_a(row['n_a'])}" unless chosen

    format("  %<label>s: threshold %<t>.2f (precision %<p>.3f, lb %<lb>.3f, coverage %<c>s, n %<n>d)",
           label: row["label"], t: chosen["threshold"], p: chosen["precision"], lb: chosen["precision_lb"],
           c: chosen["coverage"].nil? ? "n/a" : format("%.3f", chosen["coverage"]), n: chosen["n"])
  end

  # n_a(n_a) -> the n/a text. Every n/a reads "insufficient evidence"
  # (DND-714): the label stays disabled, and that is not a precision of 0.
  def n_a(n_a)
    why = case n_a && n_a["reason"]
          when "too_few_routed" then "n/a (n=#{n_a['n']}, needs #{n_a['needs']})"
          when "precision_below_target"
            best = n_a["best_precision_lb"]
            best_text = best.nil? ? "no case routed" : format("best lb %.3f", best)
            format("n/a (%s < %.2f at every threshold)", best_text, n_a["target"])
          else "n/a (#{safe(n_a)})"
          end
    "#{why}#{INSUFFICIENT}"
  end

  INSUFFICIENT = " -- insufficient evidence"

  # only_not_configured?(report) -- every case fell back for want of the key.
  def only_not_configured?(report)
    report.fetch("scored").zero? && report.fetch("unscored").keys == ["not_configured"]
  end

  def uuid?(value)
    value.is_a?(String) && UUID.match?(value)
  end

  # jsonl(text, path, what) -> [[line_no, Hash]]. Blank lines are skipped; a
  # line that is not a JSON object is an error naming its line, never its text.
  def jsonl(text, path, what)
    rows = []
    text.each_line.with_index(1) do |line, line_no|
      next if line.strip.empty?

      row = begin
        JSON.parse(line)
      rescue JSON::ParserError
        nil
      end
      raise InputError.new("#{path}:#{line_no} is not a JSON object", "the #{what} file is JSONL: one JSON object per line") unless row.is_a?(Hash)

      rows << [line_no, row]
    end
    rows
  end

  # A value from an input file, shown only if it is an identifier.
  def safe(value)
    value.is_a?(String) && LABEL.match?(value) ? value : "(unprintable)"
  end
end
