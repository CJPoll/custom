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
require "time"
require_relative "judgment_context"
require_relative "judgment_label"

module JudgmentEval
  USE_CASES = %w[finding_triage slack_routing priority_scoring ticket_kind ticket_severity ticket_security ticket_blocking].freeze
  PROVENANCES = %w[forward_record owner_confirmed tracker_record rule_confirmed title_prefix proposed].freeze
  DOMAINS = %w[work blend personal].freeze
  MAX_BATCH = 50
  # The corpus key a label's id joins on. Slack routing joins judgment-label's
  # root snapshot of the inbox's lines on event_id (DND-1448).
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

  # missing_line(missing, labels, usable, id_key, use_case) -> [what, fix] for
  # the labels whose id the corpus lacks: n/a, not scored, counted by how
  # many the owner confirmed, and named (DND-1497). For slack_routing the
  # reason is where a root comes from: judgment-label's snapshot holds a root
  # only if --propose ran while the root was in the inbox or its rotated
  # generation.
  def missing_line(missing, labels, usable, id_key, use_case)
    wanted = missing.to_h { |id| [id, true] }
    owner = labels.count { |l| wanted.key?(l[:id]) && l[:provenance] == "owner_confirmed" }
    what = "join: #{missing.size} of #{usable} labels have no corpus row with that #{id_key} (n/a, not scored; #{owner} owner_confirmed): #{missing.join(', ')}"
    fix = if use_case == "slack_routing"
            "the root snapshot keeps a root only if judgment-label --propose ran while it was in the inbox or its rotated generation " \
              "(walt_ui-slack.jsonl, walt_ui-slack.jsonl.1); run judgment-label --propose and re-run. A root gone from both before that is lost and stays n/a"
          else
            "point --corpus at the file these labels were made from, or drop the stale labels; they are not in this run"
          end
    [what, fix]
  end

  # without_rule_routed(cases, use_case) -> [cases, excluded_count]
  # slack_routing only: a root whose text addresses a session is routed by
  # the router's rule (athena-events.md -> The session mention;
  # session-mention-v3), never
  # judged, so scoring it would measure the judge on input it never gets
  # (DND-717). Such a case leaves the run, whatever its provenance, and is
  # counted.
  def without_rule_routed(cases, use_case)
    return [cases, 0] unless use_case == "slack_routing"

    kept, routed = cases.partition do |c|
      input = c["input"]
      JudgmentLabel.session_mention(input.is_a?(Hash) ? input["text"] : nil).nil?
    end
    [kept, routed.size]
  end

  # without_incomplete_window(cases, use_case) -> [cases, excluded_ids]
  # slack_routing only: a root snapshot row (judgment-label, DND-1448) whose
  # window_complete is not exactly true was snapshotted after part of its
  # context window had rotated out of the inbox. Judged, it would be judged on
  # partial context, and a miss would read as the router's when it is the
  # context's. So it is not a measurement: it leaves the run, n/a, and is
  # named (DND-1483). "Could not tell" (no flag, a flag that is not a boolean,
  # a snapshot that is not an object) is not complete either. A case with no
  # snapshot member (a live-inbox corpus) is unchanged.
  def without_incomplete_window(cases, use_case)
    return [cases, []] unless use_case == "slack_routing"

    kept, incomplete = cases.partition do |c|
      input = c["input"]
      !(input.is_a?(Hash) && input.key?("snapshot")) || (input["snapshot"].is_a?(Hash) && input["snapshot"]["window_complete"] == true)
    end
    [kept, incomplete.map { |c| c["case_id"] }]
  end

  # window_incomplete_line(ids) -> the run's line for the excluded cases, or
  # nil when there are none.
  def window_incomplete_line(ids)
    return nil if ids.empty?

    "window-incomplete excluded: #{ids.size} (n/a, not scored: the root's context window had partly rotated out of the inbox when it was snapshotted): #{ids.join(', ')}"
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
  # (DND-714): the row is written disabled, and that is not a precision of 0.
  # In mode on the label's answer is still accepted, uncalibrated (DND-1450).
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

  # ── per-case verdicts over repeated samples (DND-1637) ─────────────────────
  #
  # One sample per case let an answer near confidence 0, which flips between
  # identical runs, decide a keep/revert bar as a win or a loss. A verdict now
  # needs at least MIN_SAMPLES samples, every one scored and every one the
  # same answer:
  #   match    -- every sample gave the label
  #   miss     -- every sample gave the same answer, not the label
  #   unstable -- the samples' answers differ (a flip; never a match or miss)
  #   n/a      -- fewer than MIN_SAMPLES samples, or one unscored or absent
  #               (unscored is not wrong, and one sample decides nothing)
  # No confidence floor and no threshold: agreement alone decides.
  MIN_SAMPLES = 2
  MAX_REPEAT = 5
  VERDICTS = %w[match miss unstable n/a].freeze

  # case_verdicts(labels, samples) -> [{case_id:, label:, verdict:, answers:}]
  # labels: {case_id => label}; samples: one results array per sample run.
  # Ordered by case_id. answers names each sample's answer, in sample order.
  def case_verdicts(labels, samples)
    by_sample = samples.map { |results| results.to_h { |r| [r["case_id"], r] } }
    labels.keys.sort.map do |case_id|
      picks = by_sample.map { |s| s[case_id] }
      label = labels[case_id]
      { case_id: case_id, label: label, verdict: verdict(label, picks), answers: picks.map { |r| answer_text(r) } }
    end
  end

  def verdict(label, picks)
    return "n/a" if picks.size < MIN_SAMPLES || !picks.all? { |r| scored?(r) }

    predicted = picks.map { |r| r["predicted"] }.uniq
    return "unstable" if predicted.size > 1

    predicted.first == label ? "match" : "miss"
  end

  def scored?(result)
    result.is_a?(Hash) && result["outcome"] == "scored" && result["predicted"].is_a?(String)
  end

  def answer_text(result)
    return "absent" unless result.is_a?(Hash)
    return "unscored #{safe(result['reason'])}" unless scored?(result)

    conf = result["confidence"]
    answer = safe(result["predicted"])
    conf.is_a?(Numeric) ? format("%s %.2f", answer, conf) : "#{answer} (no confidence)"
  end

  # verdict_lines(verdicts, repeat) -> lines. One sample per case computes no
  # verdict at all, and says how to get one.
  def verdict_lines(verdicts, repeat)
    if repeat < MIN_SAMPLES
      return ["per-case verdicts: not computed (1 sample per case; an answer near confidence 0 can flip between runs). " \
              "For a keep/revert bar, re-run with --repeat 3 (DND-1637)."]
    end

    counts = VERDICTS.map { |v| "#{v} #{verdicts.count { |x| x[:verdict] == v }}" }.join(", ")
    ["per-case verdicts over #{repeat} samples: #{counts}"] +
      verdicts.map { |v| "  #{v[:case_id]} (#{v[:label]}): #{v[:verdict]} [#{v[:answers].join(', ')}]" }
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


  # ── slack_routing: the conversation context (DND-1048) ───────────────────
  #
  # Each slack_routing case is judged with the conversation before its root
  # (contract athena-judgments.md -> Egress and data flow, the slack_routing
  # row). The SERVER selects the context: POST
  # /api/v1/judgments/slack_routing/context runs the router's own function.
  # This side gathers the candidates, and it does re-state two of the
  # server's rules to do so: the root's channel, top-level only, one line per
  # ts, the window before the root. So check_context/2 refuses a reply whose
  # version, rules or owner differ from what this side assumed: a mismatch
  # must fail loudly, never quietly starve the context.
  #
  # Every sender's line is a candidate, because the server's cap counts every
  # sender (the labeller's rule, ai/lib/judgment_context.rb). Only the
  # owner's lines carry their text; anyone else's goes with an empty text,
  # so another person's words never leave this machine. The server sends
  # nothing of them to the judge either way.

  QUESTION_SET_VERSION = "slack-routing-v2"
  # The labeller's constants (DND-1047) ARE this harness's expectation of the
  # server: one definition, so the labeller, the eval and (through
  # check_context/2) the router's window, cap and text cap cannot drift apart
  # silently. The selection logic itself is not compared: nothing pins the
  # Ruby and Elixir copies together.
  CONTEXT_RULES = {
    "window_s" => JudgmentContext::WINDOW_S,
    "max_entries" => JudgmentContext::MAX_MESSAGES,
    "max_text" => JudgmentContext::JUDGE_TEXT_CAP
  }.freeze
  CONTEXT_WINDOW_S = CONTEXT_RULES.fetch("window_s")
  MAX_CANDIDATES = 200
  SLACK_TS = /\A(\d{1,10})\.(\d{6})\z/

  # slack_ts_us(ts) -> integer microseconds, or nil for anything but a Slack
  # ts ("<seconds>.<6 digits>"). Never coerced.
  def slack_ts_us(ts)
    m = ts.is_a?(String) ? SLACK_TS.match(ts) : nil
    m && (m[1].to_i * 1_000_000 + m[2].to_i)
  end

  # context_candidates(root, lines, owner) -> [candidate]. The top-level lines
  # in the root's channel with a ts in the window strictly before the root's,
  # one per ts, oldest first, at most MAX_CANDIDATES (the most recent), each
  # reduced to the endpoint's fields. Only the owner's lines keep their text.
  # A root with a malformed ts gets none; the server refuses it, and the case
  # is unscored context_unavailable.
  def context_candidates(root, lines, owner)
    root_us = slack_ts_us(root["ts"])
    return [] if root_us.nil? || !owner.is_a?(String) || owner.empty?

    from_us = root_us - CONTEXT_WINDOW_S * 1_000_000
    kept = lines.select do |line|
      line.is_a?(Hash) && line["channel"] == root["channel"] && top_level?(line) &&
        line["user"].is_a?(String) && (ts = slack_ts_us(line["ts"])) && ts < root_us && ts >= from_us
    end
    kept.uniq { |line| line["ts"] }.sort_by { |line| slack_ts_us(line["ts"]) }.last(MAX_CANDIDATES).map { |line| candidate(line, owner) }
  end

  # window_covered?(root, files) -> whether every inbox file holding a line
  # in the root's channel reaches back to the start of the root's context
  # window: its earliest line's ts is at or before root ts - CONTEXT_WINDOW_S
  # (DND-1448). A file that starts later may have rotated lines of that
  # window away; a file with no line in the channel cannot hold its context.
  # FILES is SlackInboxFiles.read's streams, [{name:, rows:, generation:,
  # rotated_at:}]. No such file, or an unreadable ts, is false:
  # "could not tell" never reads as covered.
  #
  # NOW given (DND-1497): a stream that NEVER ROTATED lost nothing, however
  # late it began (a second inbox created after the root), so it covers. By
  # the inbox's retention rules (athena-inbox.md -> Retention) every
  # rotation leaves <name>.1 until the next rotation (which leaves a new one)
  # or the sweep, 14 days after rotated_at. So no generation (generation:
  # false, stated, never assumed) and a rotated_at no older than the sweep
  # window means the channel never rotated. A missing, malformed or future
  # rotated_at, or no clock, is "could not tell": the earliest-line rule
  # above. Residual: reads as never rotated when it did -- a .1 deleted by
  # hand, a state file recreated or its rotated_at reset after a sweep
  # (the reader restamps it to now), or a stream that once held the channel
  # and has vanished entirely.
  def window_covered?(root, files, now: nil)
    root_us = slack_ts_us(root["ts"])
    holding = files.select { |f| f[:rows].any? { |line| line.is_a?(Hash) && line["channel"] == root["channel"] } }
    return false if root_us.nil? || holding.empty?

    from_us = root_us - CONTEXT_WINDOW_S * 1_000_000
    holding.all? { |f| never_rotated?(f, now) || ((us = earliest_us(f[:rows])) && us <= from_us) }
  end

  # The inbox's sweep window for a rotated generation (athena-inbox.md ->
  # Lifetimes): 14 days after rotated_at.
  GENERATION_SWEEP_S = 14 * 86_400

  # never_rotated?(stream, now) -> true only when the stream states it has no
  # rotated generation and its rotated_at is a time in [now - 14 days, now].
  def never_rotated?(stream, now)
    return false unless now.is_a?(Time) && stream[:generation] == false

    at = begin
      Time.iso8601(stream[:rotated_at].to_s)
    rescue ArgumentError
      nil
    end
    !at.nil? && at <= now && now - at < GENERATION_SWEEP_S
  end

  # earliest_us(lines) -> the smallest Slack ts (microseconds) among lines,
  # or nil when none has one.
  def earliest_us(lines)
    lines.filter_map { |line| line.is_a?(Hash) ? slack_ts_us(line["ts"]) : nil }.min
  end

  # snapshot_candidates(cases) -> the context lines the root snapshot kept
  # for these cases (DND-1448), and how many cases carried one. A case whose
  # input is no snapshot row contributes nothing. A window-incomplete case
  # never reaches here: without_incomplete_window/2 took it out (DND-1483).
  def snapshot_candidates(cases)
    snaps = cases.filter_map { |c| c["input"].is_a?(Hash) && c["input"]["snapshot"].is_a?(Hash) ? c["input"]["snapshot"] : nil }
    lines = snaps.flat_map { |s| s["context_candidates"].is_a?(Array) ? s["context_candidates"].select { |l| l.is_a?(Hash) } : [] }
    { lines: lines, cases: snaps.size }
  end

  def top_level?(line)
    line["thread_ts"].nil? || line["thread_ts"] == line["ts"]
  end

  def candidate(line, owner)
    text = line["user"] == owner && line["text"].is_a?(String) ? line["text"] : ""
    { "channel" => line["channel"], "user" => line["user"], "ts" => line["ts"], "text" => text, "thread_ts" => nil }
  end

  # contract_kind(root) -> the root's kind in the vocabulary the context
  # endpoint and the slack-routing-v2 state take: im, mpim or mention
  # (athena-judgments.md -> the slack_routing row). A root received before
  # HG-22 carries the legacy "dm", which covered both a 1:1 and a group DM
  # (athena-inbox.md -> Line format). A Slack 1:1 lives in a D channel, so a
  # dm in a D channel is im and a dm in any other channel is mpim (DND-1567).
  # A dm with no channel string, and any other kind, passes unchanged: it is
  # never guessed, and the server's 422 names it.
  def contract_kind(root)
    kind = root["kind"]
    channel = root["channel"]
    return kind unless kind == "dm" && channel.is_a?(String) && !channel.empty?

    channel.start_with?("D") ? "im" : "mpim"
  end

  # context_request(root, candidates, bot_id) -> the endpoint's body for one root.
  def context_request(root, candidates, bot_id = nil)
    body = { "channel" => root["channel"], "ts" => root["ts"], "kind" => contract_kind(root), "candidates" => candidates }
    bot_id ? body.merge("bot_id" => bot_id) : body
  end

  # check_context(doc, owner) -> nil when the server's reply matches what this
  # side assumed, else the mismatch as text. A reply that is missing a field
  # is a mismatch too: "could not check" is never "checked". OWNER is the
  # private overlay's owner Slack id, a work value: the text never quotes it,
  # nor the server's.
  def check_context(doc, owner)
    version = doc["question_set_version"]
    return "the server's question set is #{safe(version)}, this harness builds for #{QUESTION_SET_VERSION}" unless version == QUESTION_SET_VERSION
    return "the server's context rules #{JSON.generate(doc['rules'])} differ from #{JSON.generate(CONTEXT_RULES)}" unless doc["rules"] == CONTEXT_RULES
    return "the server's owner Slack user id differs from the private overlay's (neither is printed)" unless doc["owner_slack_user_id"] == owner

    nil
  end

  # context_input(root, context) -> the v2 case input: the root's text and
  # kind, and the context the server built. Nothing else from the line.
  def context_input(root, context)
    { "text" => root["text"], "kind" => contract_kind(root), "context" => context }
  end

  # context_lines(built, unavailable) -> lines. A case whose context could not
  # be built is unscored context_unavailable and named, never sent with an
  # empty context.
  def context_lines(built, unavailable)
    total = built + unavailable.size
    lines = ["context: built #{built} of #{total}"]
    return lines if unavailable.empty?

    lines << "unscored #{unavailable.size} (context_unavailable, not sent): #{unavailable.map { |u| u[:case_id] }.join(', ')}"
  end
end
