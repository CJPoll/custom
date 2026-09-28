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
  # D7: only the owner's own text is ever judged. The owner's Slack user id is
  # a work value, so it lives in the private overlay, never in this public
  # repo (ai/contracts/athena-private-overlay.md); the bin resolves it at run
  # time and passes it in.
  OWNER_KEY = ["slack", ".people.owner.user_id"].freeze
  # A Slack user id: U or W, then upper-case letters and digits.
  SLACK_USER_ID = /\A[UW][A-Z0-9]{2,}\z/
  # The SlackRouting v1 Choice options (DND-716). Exactly these four.
  LABELS = %w[walt_ui harness gen_saas unclear].freeze
  PROVENANCES = %w[forward_record owner_confirmed rule_confirmed proposed].freeze
  # The owner's routing rule (Cody, 2026-09-28 ~04:25Z), applied mechanically
  # under provenance rule_confirmed (epic decision D-R2, DND-717). Rule 1 (a
  # reply goes to the posting session) never labels a root: roots are not
  # replies. The rule a rule_confirmed row came from is on the row.
  #   session_mention  rule 2: the owner's text addresses a session
  #   default_walt_ui  rule 3: "Most messages from slack will be for walt_ui";
  #                    applied only with --rule-default, to a root no other
  #                    evidence labels
  RULES = %w[session_mention default_walt_ui].freeze
  # Grammar session-mention-v1, the SAME grammar the server's router applies
  # (gen_saas Athena.SlackEvents.SessionMention; both suites carry one vector
  # list). Only a LEADING address counts: "harness session:" (the tag form,
  # as R1 tags posts) or a single-line lead-in of at most 80 characters
  # ending "for the harness session:". "session" is required. Names that
  # disagree are no mention.
  MENTION_GRAMMAR = "session-mention-v1"
  MENTION_NAME = "(?:walt[_ ]?ui|harness|custom|gen[_ ]?saas|laptop)"
  MENTION_NAMES = "(#{MENTION_NAME}(?:\\s*/\\s*#{MENTION_NAME})*)".freeze
  MENTION_TAIL = "\\s+session(?:\\s*\\([^)\\n]{0,60}\\))?[*_]*\\s*:"
  MENTION_FORMS = [
    Regexp.new("\\A\\s*[*_]*\\s*(?:the\\s+)?#{MENTION_NAMES}#{MENTION_TAIL}", Regexp::IGNORECASE),
    Regexp.new("\\A[^\\n:]{0,80}?\\bfor\\s+the\\s+#{MENTION_NAMES}#{MENTION_TAIL}", Regexp::IGNORECASE)
  ].freeze
  MENTION_LABELS = { "waltui" => "walt_ui", "harness" => "harness", "custom" => "harness",
                     "gensaas" => "gen_saas", "laptop" => "gen_saas" }.freeze
  MENTION_SCAN_CHARS = 400
  # Whether the owner saw the conversation context when confirming (DND-1047).
  # An owner_confirmed row without the mark was confirmed before context was
  # shown (batch 1, 2026-09-28 ~07:20Z); --confirm --recheck re-presents it.
  CONTEXT_MARKS = %w[shown unavailable].freeze
  # Which rows each confirm mode presents.
  CONFIRM_MODES = %i[proposed forward recheck].freeze
  ROOT_KINDS = %w[dm im mpim mention].freeze
  # The proposal for a root no forward record names: it stayed in walt_ui, the
  # session whose inbox it landed in (today's channel route, A&E D6).
  NO_EVIDENCE = "walt_ui"
  # The proposal for a root forwarded to two different sessions.
  CONFLICT = "unclear"
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

  # owner_problem(value) -> nil when VALUE is a Slack user id, else the reason
  # it is not. The reason never quotes the value.
  def owner_problem(value)
    return nil if value.is_a?(String) && SLACK_USER_ID.match?(value)

    "the overlay value at #{OWNER_KEY.join} is not a Slack user id (U or W, then upper-case letters and digits)"
  end

  # session_mention(text) -> the label the text addresses, or nil (grammar
  # session-mention-v1, above). Untrusted text: invalid UTF-8 is scrubbed.
  def session_mention(text)
    return nil unless text.is_a?(String)

    lead = text.scrub("?")[0, MENTION_SCAN_CHARS]
    match = MENTION_FORMS.lazy.map { |re| re.match(lead) }.find(&:itself)
    return nil unless match

    labels = match[1].split("/").map { |n| MENTION_LABELS.fetch(n.downcase.gsub(/[\s_]/, "")) }.uniq
    labels.size == 1 ? labels.first : nil
  end

  # parse_slack(text, path) -> {lines: [{event_id, kind, user, channel, ts, thread_ts, mention}], without_id: n}
  # An empty file is its own error, distinct from a missing one (the bin says
  # which). A parsed line keeps no text: only the label its text addresses
  # (session_mention), or nil.
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
      lines << { event_id: id, kind: row["kind"], user: row["user"], channel: row["channel"], ts: row["ts"], thread_ts: row["thread_ts"],
                 mention: session_mention(row["text"]) }
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
  # Invalid UTF-8 in untrusted text is scrubbed, never a crash.
  def slack_ts(text)
    text.to_s.scrub("?").scan(SLACK_TS).uniq
  end

  # mail_label(body) -> the label a walt_ui->custom record stands for.
  def mail_label(body)
    GEN_SAAS_RELAY.match?(body.to_s.scrub("?")) ? "gen_saas" : "harness"
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
  #                                   matched: n, thread_only: n, ambiguous: [ts],
  #                                   unmatched: [[source, [ts]]]}
  # A record matches the roots whose ts it names. A record naming no root but
  # a line or a thread in the inbox is thread_only (a reply under a bot post,
  # or a non-owner root). A record whose ts match no line at all is UNMATCHED,
  # reported by ts, never dropped. Records carry no channel, so a ts two roots
  # share (in different channels) labels neither: AMBIGUOUS, reported by ts.
  def match(records, lines, roots)
    known = {}
    lines.each do |l|
      known[l[:ts]] = true if l[:ts].is_a?(String)
      known[l[:thread_ts]] = true if l[:thread_ts].is_a?(String)
    end
    by_ts = roots.group_by { |r| r[:ts] }
    ambiguous = by_ts.select { |_, rs| rs.size > 1 }.keys.sort
    root_by_ts = by_ts.reject { |_, rs| rs.size > 1 }.transform_values { |rs| rs.first[:event_id] }
    votes = Hash.new { |h, k| h[k] = [] }
    out = { matched: 0, thread_only: 0, unmatched: [], ambiguous: ambiguous }
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
    seen = {}
    jsonl(text, path, "labels").map do |line_no, row|
      where = "#{path}:#{line_no}"
      fix = "repair or remove that line; the file is judgment-label's own output"
      raise InputError.new("#{where} has no event id", fix) unless row["id"].is_a?(String) && EVENT_ID.match?(row["id"])
      raise InputError.new("#{where} has a label outside #{LABELS.join('|')}", fix) unless LABELS.include?(row["label"])
      raise InputError.new("#{where} has an unknown provenance", fix) unless PROVENANCES.include?(row["provenance"])
      raise InputError.new("#{where} has a context mark outside #{CONTEXT_MARKS.join('|')}", fix) if row.key?("context") && !CONTEXT_MARKS.include?(row["context"])
      raise InputError.new("#{where} has a context mark on a #{row['provenance']} row", "a context mark belongs only on an owner_confirmed row; #{fix}") if row.key?("context") && row["provenance"] != "owner_confirmed"
      raise InputError.new("#{where} is rule_confirmed with a rule outside #{RULES.join('|')}", "a rule_confirmed row names the rule that labelled it; #{fix}") if row["provenance"] == "rule_confirmed" && !RULES.include?(row["rule"])
      raise InputError.new("#{where} has a rule on a #{row['provenance']} row", "a rule belongs only on a rule_confirmed row; #{fix}") if row.key?("rule") && row["provenance"] != "rule_confirmed"
      raise InputError.new("#{where} repeats the id of line #{seen[row['id']]}", "keep one row per id (judgment-eval refuses a repeat)") if seen.key?(row["id"])

      seen[row["id"]] = line_no
      row.slice("id", "label", "provenance", "labeler", "labeled_at", "context", "rule")
    end
  end

  # build(roots, matched, existing, now, rule_default: false)
  #   -> {rows:, kept_orphans:, dropped:, disagreements:, mention_overrides:}
  # owner_confirmed rows are the owner's work: never overwritten or dropped.
  # Otherwise, in order (the owner's rule, D-R2):
  #   1. the root's text addresses a session (rule 2): that label. A forward
  #      record that agrees keeps forward_record; any other root is
  #      rule_confirmed/session_mention, and a forward record it overrides is
  #      counted in mention_overrides;
  #   2. a forward record: forward_record;
  #   3. forwarded to two sessions: proposed unclear;
  #   4. no evidence: walt_ui, rule_confirmed/default_walt_ui with
  #      rule_default (rule 3), proposed without it.
  # A recomputed row keeps its labeled_at when its label, provenance and rule
  # are unchanged, so an unchanged input writes a byte-identical file.
  def build(roots, matched, existing, now, rule_default: false)
    prior = existing.to_h { |r| [r["id"], r] }
    root_ids = {}
    disagreements = 0
    mention_overrides = 0
    rows = roots.map do |root|
      id = root[:event_id]
      root_ids[id] = true
      old = prior[id]
      forward = matched[:forward][id]
      if old && old["provenance"] == "owner_confirmed"
        disagreements += 1 if forward && forward != old["label"]
        next old
      end
      mention_overrides += 1 if root[:mention] && forward && forward != root[:mention]
      label, provenance, rule = derive(root[:mention], forward, matched[:conflicts].include?(id), rule_default)
      stamp = old && old["label"] == label && old["provenance"] == provenance && old["rule"] == rule ? old["labeled_at"] : now
      row = { "id" => id, "label" => label, "provenance" => provenance, "labeler" => TOOL, "labeled_at" => stamp }
      rule ? row.merge("rule" => rule) : row
    end
    gone = existing.reject { |r| root_ids.key?(r["id"]) }
    orphans = gone.select { |r| r["provenance"] == "owner_confirmed" }
    { rows: rows + orphans, kept_orphans: orphans.size, dropped: gone.size - orphans.size, disagreements: disagreements,
      mention_overrides: mention_overrides }
  end

  # derive(mention, forward, conflict, rule_default) -> [label, provenance, rule-or-nil]; see build.
  def derive(mention, forward, conflict, rule_default)
    if mention && mention == forward then [forward, "forward_record", nil]
    elsif mention then [mention, "rule_confirmed", "session_mention"]
    elsif forward then [forward, "forward_record", nil]
    elsif conflict then [CONFLICT, "proposed", nil]
    elsif rule_default then [NO_EVIDENCE, "rule_confirmed", "default_walt_ui"]
    else [NO_EVIDENCE, "proposed", nil]
    end
  end

  # confirm(rows, id, label, owner, now, context) -> rows with that row
  # owner_confirmed, marked with whether the conversation context was shown.
  # A row no longer in rows (a re-propose dropped it meanwhile) is appended:
  # an owner answer is never lost.
  def confirm(rows, id, label, owner, now, context)
    raise ArgumentError, "not a label: #{label}" unless LABELS.include?(label)
    raise ArgumentError, "not a context mark: #{context}" unless CONTEXT_MARKS.include?(context)

    row = { "id" => id, "label" => label, "provenance" => "owner_confirmed", "labeler" => owner, "labeled_at" => now, "context" => context }
    return rows + [row] unless rows.any? { |r| r["id"] == id }

    rows.map { |r| r["id"] == id ? row : r }
  end

  # pending(rows, mode) -> the rows a confirm mode presents, in file order.
  #   :proposed  rows the owner has not answered: proposed, and rule_confirmed
  #              (the owner's rule applied mechanically; the owner's own
  #              answer replaces it)
  #   :forward   forward_record rows, for the owner to review
  #   :recheck   owner_confirmed rows whose context was not shown (confirmed
  #              before DND-1047, or while Slack was unreachable); their
  #              answers stay in force until rechecked
  def pending(rows, mode)
    raise ArgumentError, "not a confirm mode: #{mode}" unless CONFIRM_MODES.include?(mode)

    case mode
    when :proposed then rows.select { |r| %w[proposed rule_confirmed].include?(r["provenance"]) }
    when :forward then rows.select { |r| r["provenance"] == "forward_record" }
    else rows.select { |r| r["provenance"] == "owner_confirmed" && r["context"] != "shown" }
    end
  end

  # counts(rows) -> [[label, provenance, n]] in LABELS x PROVENANCES order, nonzero only.
  def counts(rows)
    tally = rows.group_by { |r| [r["label"], r["provenance"]] }.transform_values(&:size)
    LABELS.product(PROVENANCES).filter_map { |l, p| [l, p, tally[[l, p]]] if tally[[l, p]] }
  end

  # messages(text, path, ids) -> {event_id => {kind, received_at, text,
  # channel, ts, thread_ts}} for the confirm step only: the one place the text
  # is read, shown, never stored. channel/ts/thread_ts anchor its context.
  def messages(text, path, ids)
    wanted = ids.to_h { |id| [id, true] }
    out = {}
    jsonl(text, path, "slack").each do |_line_no, row|
      id = row["event_id"]
      next unless wanted.key?(id) && !out.key?(id)

      out[id] = { kind: row["kind"], received_at: row["received_at"], text: row["text"].to_s,
                  channel: row["channel"], ts: row["ts"], thread_ts: row["thread_ts"] }
    end
    out
  end

  # printable(text) -> untrusted text made safe for a terminal: invalid UTF-8
  # scrubbed; control (Cc, so ESC/CSI) and format (Cf, so bidi overrides)
  # characters replaced; tabs kept. One-line fields only.
  def printable(text)
    text.to_s.scrub("?").gsub(/[\p{Cc}\p{Cf}&&[^\t]]/, "?")
  end

  # fenced(text) -> the message body, each line prefixed "| " so the text can
  # never forge the end-of-message fence.
  def fenced(text)
    text.to_s.scrub("?").split("\n", -1).map { |l| "| #{printable(l)}" }.join("\n")
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
      raise InputError.new("#{path}:#{line_no} is not valid UTF-8", "the #{what} file must be UTF-8 JSONL; repair that line") unless line.valid_encoding?
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
