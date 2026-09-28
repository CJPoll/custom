# frozen_string_literal: true

# ai/lib/judgment_label.rb -- DOMAIN (pure) for ai/bin/judgment-label (DND-715).
#
# Everything here is a function of its arguments: parse the walt_ui slack
# inbox lines (keeping NO text), pick the owner's new-conversation roots,
# derive labels from R4 forward records, merge them with the labels already on
# disk, and count. No file, terminal or process access; the bin owns those.
#
# Design: epic "Jev judgments" A&E section 5b (Labels). The labels file is
# keyed by event_id and joined to walt_ui-slack.jsonl at eval time by
# ai/bin/judgment-eval, so the text is never copied into a second file.
#
# Trust: slack text and forward mail are untrusted inbox content. This module
# reads only Slack timestamps and one relay marker out of a forward record; a
# record can put a label on a root, never do anything else.
#
# Deliberately gem-free (stdlib only).

require "json"

module JudgmentLabel
  # D7: only the owner's own text is ever judged.
  OWNER = "U0AHNV4RJGP"
  # The SlackRouting v1 Choice options (DND-716). Exactly these four.
  LABELS = %w[walt_ui harness gen_saas unclear].freeze
  PROVENANCES = %w[forward_record owner_confirmed proposed].freeze
  ROOT_KINDS = %w[dm im mpim mention].freeze
  # A label with no forward evidence, and a root forwarded to two sessions.
  NO_EVIDENCE = "unclear"
  TOOL = "judgment-label"
  # A Slack message ts: 10 digits, a dot, 6 digits, standing alone.
  SLACK_TS = /(?<![\d.])\d{10}\.\d{6}(?![\d.])/
  # A walt_ui->custom record that asks custom to relay it on to gen_saas.
  GEN_SAAS_RELAY = /\bfor gen_saas\b|\brelay (?:it )?to gen_saas\b|\bthis is gen_saas's\b/i
  # Which label a routed session inbox stands for.
  SESSION_LABELS = { "custom" => "harness", "gen_saas" => "gen_saas" }.freeze
  EVENT_ID = /\A[A-Za-z0-9_:.#\/-]{1,200}\z/

  # A refusal of an INPUT: exit 1, one line, with a Fix:.
  class InputError < StandardError
    attr_reader :fix

    def initialize(message, fix)
      super(message)
      @fix = fix
    end
  end

  module_function

  # parse_slack(text, path) -> {lines: [{event_id, kind, user, channel, ts, thread_ts}], without_id: n}
  # An empty file is its own error, distinct from a missing one (the bin says
  # which). A parsed line keeps no text.
  def parse_slack(text, path)
    rows = jsonl(text, path, "slack")
    raise InputError.new("slack file #{path} is empty (0 lines)", "point --inbox-root at the root holding walt_ui-slack.jsonl; an empty inbox has nothing to label") if rows.empty?

    lines = []
    without_id = 0
    rows.each do |_line_no, row|
      id = row["event_id"]
      unless id.is_a?(String) && EVENT_ID.match?(id)
        without_id += 1
        next
      end
      lines << { event_id: id, kind: row["kind"], user: row["user"], channel: row["channel"], ts: row["ts"], thread_ts: row["thread_ts"] }
    end
    { lines: lines, without_id: without_id }
  end

  # root?(line, owner) -- a new conversation from the owner: a dm/im/mpim or
  # mention that is not inside a thread (thread_ts absent or its own ts).
  def root?(line, owner)
    ROOT_KINDS.include?(line[:kind]) &&
      line[:user] == owner &&
      line[:ts].is_a?(String) &&
      (line[:thread_ts].nil? || line[:thread_ts] == line[:ts])
  end

  # select_roots(lines, owner) -> {roots:, lines:, duplicates:, non_owner:, replies:, other:}
  # Duplicates (at-least-once redelivery) collapse on event_id, then on
  # (channel, ts), keeping the first. Every excluded line is counted.
  def select_roots(lines, owner)
    seen_ids = {}
    seen_msg = {}
    stats = { roots: [], lines: lines.size, duplicates: 0, non_owner: 0, replies: 0, other: 0 }
    lines.each do |line|
      if seen_ids.key?(line[:event_id])
        stats[:duplicates] += 1
        next
      end
      seen_ids[line[:event_id]] = true
      if root?(line, owner)
        msg = [line[:channel], line[:ts]]
        if seen_msg.key?(msg)
          stats[:duplicates] += 1
        else
          seen_msg[msg] = true
          stats[:roots] << line
        end
      elsif !ROOT_KINDS.include?(line[:kind])
        line[:kind] == "thread_reply" ? stats[:replies] += 1 : stats[:other] += 1
      elsif line[:user] != owner
        stats[:non_owner] += 1
      else
        stats[:replies] += 1
      end
    end
    stats
  end

  # slack_ts(text) -> every Slack ts the text names, in order, once.
  def slack_ts(text)
    text.to_s.scan(SLACK_TS).uniq
  end

  # mail_label(body) -> the label a walt_ui->custom record stands for.
  def mail_label(body)
    GEN_SAAS_RELAY.match?(body.to_s) ? "gen_saas" : "harness"
  end

  # mail_record(source, body) -> {source:, label:, ts:} or nil (no ts: not a record).
  def mail_record(source, body)
    ts = slack_ts(body)
    ts.empty? ? nil : { source: source, label: mail_label(body), ts: ts }
  end

  # routed_records(text, path, session) -> [records] from a session inbox:
  # only lines walt_ui routed there. Its label is the session's.
  def routed_records(text, path, session)
    label = SESSION_LABELS.fetch(session)
    jsonl(text, path, "session").filter_map do |_line_no, row|
      from = row.dig("from", "inbox_name") if row["from"].is_a?(Hash)
      next unless from.is_a?(String) && from.start_with?("walt_ui-")

      ts = slack_ts(row["body"])
      ts.empty? ? nil : { source: "#{session}-session", label: label, ts: ts }
    end
  end

  # match(records, lines, roots) -> {forward: {event_id => label}, conflicts: [event_id],
  #                                   matched: n, thread_only: n, unmatched: [[source, [ts]]]}
  # A record matches the roots whose ts it names. A record naming no root but
  # a line or a thread in the inbox is thread_only (a reply under a bot post,
  # or a non-owner root). A record whose ts match no line at all is UNMATCHED,
  # reported by ts, never dropped.
  def match(records, lines, roots)
    known = {}
    lines.each do |l|
      known[l[:ts]] = true if l[:ts].is_a?(String)
      known[l[:thread_ts]] = true if l[:thread_ts].is_a?(String)
    end
    root_by_ts = roots.to_h { |r| [r[:ts], r[:event_id]] }
    votes = Hash.new { |h, k| h[k] = [] }
    out = { matched: 0, thread_only: 0, unmatched: [] }
    records.each do |rec|
      hits = rec[:ts].filter_map { |t| root_by_ts[t] }
      if !hits.empty?
        out[:matched] += 1
        hits.uniq.each { |id| votes[id] << rec[:label] }
      elsif rec[:ts].any? { |t| known[t] }
        out[:thread_only] += 1
      else
        out[:unmatched] << [rec[:source], rec[:ts]]
      end
    end
    forward = {}
    conflicts = []
    votes.each do |id, labels|
      labels.uniq.size == 1 ? forward[id] = labels.first : conflicts << id
    end
    out.merge(forward: forward, conflicts: conflicts.sort)
  end

  # parse_labels(text, path) -> [row]. The file this tool writes; an empty one
  # has no rows. A malformed row names its line, never guessed around.
  def parse_labels(text, path)
    jsonl(text, path, "labels").map do |line_no, row|
      where = "#{path}:#{line_no}"
      fix = "repair or remove that line; the file is judgment-label's own output"
      raise InputError.new("#{where} has no event id", fix) unless row["id"].is_a?(String) && EVENT_ID.match?(row["id"])
      raise InputError.new("#{where} has a label outside #{LABELS.join('|')}", fix) unless LABELS.include?(row["label"])
      raise InputError.new("#{where} has an unknown provenance", fix) unless PROVENANCES.include?(row["provenance"])

      row.slice("id", "label", "provenance", "labeler", "labeled_at")
    end
  end

  # build(roots, matched, existing, now) -> {rows:, kept_orphans:, disagreements:}
  # owner_confirmed rows are the owner's work: never overwritten or dropped.
  # A recomputed row keeps its labeled_at when its label and provenance are
  # unchanged, so an unchanged input writes a byte-identical file.
  def build(roots, matched, existing, now)
    prior = existing.to_h { |r| [r["id"], r] }
    root_ids = {}
    disagreements = 0
    rows = roots.map do |root|
      id = root[:event_id]
      root_ids[id] = true
      old = prior[id]
      forward = matched[:forward][id]
      if old && old["provenance"] == "owner_confirmed"
        disagreements += 1 if forward && forward != old["label"]
        next old
      end
      label, provenance = forward ? [forward, "forward_record"] : [NO_EVIDENCE, "proposed"]
      stamp = old && old["label"] == label && old["provenance"] == provenance ? old["labeled_at"] : now
      { "id" => id, "label" => label, "provenance" => provenance, "labeler" => TOOL, "labeled_at" => stamp }
    end
    orphans = existing.select { |r| r["provenance"] == "owner_confirmed" && !root_ids.key?(r["id"]) }
    { rows: rows + orphans, kept_orphans: orphans.size, disagreements: disagreements }
  end

  # confirm(rows, id, label, owner, now) -> rows with that row owner_confirmed.
  def confirm(rows, id, label, owner, now)
    raise ArgumentError, "not a label: #{label}" unless LABELS.include?(label)

    rows.map do |r|
      r["id"] == id ? { "id" => id, "label" => label, "provenance" => "owner_confirmed", "labeler" => owner, "labeled_at" => now } : r
    end
  end

  # counts(rows) -> [[label, provenance, n]] in LABELS x PROVENANCES order, nonzero only.
  def counts(rows)
    tally = rows.group_by { |r| [r["label"], r["provenance"]] }.transform_values(&:size)
    LABELS.product(PROVENANCES).filter_map { |l, p| [l, p, tally[[l, p]]] if tally[[l, p]] }
  end

  # messages(text, path, ids) -> {event_id => {kind, received_at, text}} for
  # the confirm step only: the one place the text is read, shown, never stored.
  def messages(text, path, ids)
    wanted = ids.to_h { |id| [id, true] }
    out = {}
    jsonl(text, path, "slack").each do |_line_no, row|
      id = row["event_id"]
      next unless wanted.key?(id) && !out.key?(id)

      out[id] = { kind: row["kind"], received_at: row["received_at"], text: row["text"].to_s }
    end
    out
  end

  # printable(text) -> the text with control characters (terminal escapes in
  # untrusted content) replaced, newlines and tabs kept.
  def printable(text)
    text.to_s.gsub(/[^\n\t[:^cntrl:]]/, "?")
  end

  def render(rows)
    rows.map { |r| JSON.generate(r) + "\n" }.join
  end

  # ANSWERS: the confirm prompt's keys.
  ANSWERS = { "w" => "walt_ui", "h" => "harness", "g" => "gen_saas", "u" => "unclear" }.freeze

  # answer(input, proposal) -> [:label, L] | [:skip] | [:quit] | [:again]
  def answer(input, proposal)
    key = input.to_s.strip.downcase
    return [:label, proposal] if key.empty?
    return [:label, ANSWERS[key]] if ANSWERS.key?(key)
    return [:label, key] if LABELS.include?(key)
    return [:skip] if key == "s"
    return [:quit] if key == "q"

    [:again]
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
end
