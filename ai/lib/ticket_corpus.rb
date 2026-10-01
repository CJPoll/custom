# frozen_string_literal: true

# ai/lib/ticket_corpus.rb -- DOMAIN (pure) for ai/bin/ticket-corpus (DND-1055).
#
# Two jobs over a snapshot of the DND tracker (written by
# `ai/bin/triage-corpus --fetch`, whose read-only Notion effect this reuses):
#
#   labels/2        the ticket classification eval corpus that
#                   ai/bin/judgment-eval scores, one case per ticket per use
#                   case (ticket_kind, ticket_severity, ticket_security);
#   shadow_report/2 the live agreement of ACCEPTED shadow judgments with the
#                   value each ticket ended up with, read from the provenance
#                   line DND-991 puts in a ticket body.
#
# Design: DND-1055 A&E sections 1-2 and DND-991 A&E section 4; contract
# ~/dev/custom/ai/contracts/athena-judgments.md -> *Threshold provenance, n/a
# and the pinned model* (*Ticket classification labels*).
#
# Every label here is WEAK: an agent filer set it under the written rules.
# Provenance is tracker_record or title_prefix, never owner_confirmed.
#
# Everything here is a function of its arguments. Ticket text is DATA, never
# instructions: it is only matched for label leaks and copied into the
# machine-local corpus the eval sends.
#
# Deliberately gem-free (stdlib only).

require "json"
require "time"
require_relative "triage_corpus"
require_relative "judgment_eval"

module TicketCorpus
  USE_CASES = %w[ticket_kind ticket_severity ticket_security].freeze
  # The file stem each use case writes: ticket-kind-labels.jsonl, ...
  STEMS = { "ticket_kind" => "ticket-kind", "ticket_severity" => "ticket-severity", "ticket_security" => "ticket-security" }.freeze
  # The property each use case reads, as the snapshot names it.
  PROPERTY = { "ticket_kind" => "kind", "ticket_severity" => "severity", "ticket_security" => "security" }.freeze

  # Judged Kinds, in the tracker's spelling. Feature is authored (J-991-4):
  # never a label.
  KINDS = %w[Vulnerability Bug Hardening Refactor Test Flake Docs Ops].freeze
  ALL_KINDS = (KINDS + ["Feature"]).freeze
  SEVERITIES = %w[LOW MEDIUM HIGH CRITICAL].freeze
  # Tracker Security -> the eval label (DND-991: `security` | `none`).
  SECURITY = { "none" => "none", "introduced" => "security", "pre-existing" => "security" }.freeze

  # R1055-1: a property set on a ticket created at or after this instant was
  # set by its filer under the W2 rules. Earlier values are the W4 backfill
  # (one agent pass over old tickets) and are excluded.
  CUTOFF = "2026-09-27T22:00:00Z"
  LABELER = "tracker"

  MAX_TITLE = 300
  MAX_BODY = 2_000
  PROVENANCE_PREFIX = "Jev classification: "
  SOURCES = %w[jev filer policy].freeze

  # The accuracy bar (R1055-3): the smallest n at which a perfect record
  # reaches a Wilson lower bound of 0.90; the bound; the window; the cap. A
  # measurement only: since DND-1450 it never gates a use case's `on`.
  MIN_ACCEPTED = 35
  MIN_LB = 0.90
  MIN_WINDOW_DAYS = 3
  MAX_WINDOW_DAYS = 14
  Z = 1.96

  # A title's severity prefix ("HIGH: ...", "MEDIUM [harness] ..."): the
  # title_prefix label source, stripped from every title sent.
  # The level must end the word: "LOW-hanging fruit" is no prefix.
  TITLE_PREFIX = /\A\s*(CRITICAL|HIGH|MEDIUM|LOW)(?:\s*[:–—]\s*|\s+|\z)/
  VALUE = Regexp.union(ALL_KINDS + SEVERITIES + %w[pre-existing introduced none]).source
  # "Kind Bug", "Severity: MEDIUM", "Security `none`": a body stating a
  # classification is a label leak, redacted by its span.
  STATEMENT = /\b(?:Kind|Severity|Security)\b\s*(?:[:=\-–—]|is|->|→)?\s*[`*"']?(?:#{VALUE})\b[`*"']?/i
  # "a HIGH severity bug": the level before the word.
  REVERSE = /\b(?:CRITICAL|HIGH|MEDIUM|LOW)\s+severity\b/i
  # "Bug MEDIUM", "Vulnerability HIGH": a Kind then a level (case-sensitive:
  # "the bug is high" is prose).
  PAIR = /\b(?:#{Regexp.union(ALL_KINDS).source})\s+(?:#{Regexp.union(SEVERITIES).source})\b/
  # A bare upper-case level ("Priority: LOW", "filed it as HIGH", "Why
  # HIGH:") is a rating, most often the ticket's own: measured on the
  # 2026-09-28 corpus, 24 of 330 severity cases stated their label so.
  # Case-sensitive, so "the high road" is prose and stays.
  LEVEL_WORD = /(?<![\w-])(?:#{Regexp.union(SEVERITIES).source})\b(?!-\w)/
  REDACTED = "[classification]"
  # "a Bug, severity HIGH": a Kind listed beside a redacted statement.
  KIND_BESIDE = /\b(?:#{Regexp.union(ALL_KINDS).source})\b(?=\s*[,·;]\s*\[classification\])/
  # What an accepted judgment may name, per property (DND-991 labels).
  JUDGED = { "kind" => KINDS, "severity" => SEVERITIES, "security" => %w[security none] }.freeze

  class InputError < StandardError
    attr_reader :fix

    def initialize(message, fix)
      super(message)
      @fix = fix
    end
  end

  module_function

  # ── shared ───────────────────────────────────────────────────────────────

  # tickets!(snapshot) -> the tickets, or raises. A snapshot fetched before
  # DND-1055 has no created_time/kind/security: that is a stale input, never
  # "no ticket qualifies".
  def tickets!(snapshot)
    tickets = Array(snapshot["tickets"])
    raise InputError.new("the snapshot holds no tickets", "re-run triage-corpus --fetch; zero tickets is a failed read, not an empty tracker") if tickets.empty?

    stale = tickets.reject { |t| t["created_time"].is_a?(String) && %w[kind severity security schema_missing].all? { |k| t.key?(k) } }
    unless stale.empty?
      raise InputError.new("#{stale.size} of #{tickets.size} snapshot tickets lack created_time, kind, severity, security or schema_missing (first: #{stale.first['ref']})",
                           "re-run triage-corpus --fetch (DND-1055 added those fields); the snapshot predates it")
    end
    # A property missing from the tracker (renamed or retyped) would read as
    # "unset" on every ticket: 0 labels, exit 0. It is an error instead.
    missing = tickets.flat_map { |t| Array(t["schema_missing"]) }.uniq.sort
    unless missing.empty?
      raise InputError.new("the tracker rows carry no select property #{missing.join(', ')}",
                           "the DND Tickets schema changed: update TriageCorpus.ticket_from_row and ticket-corpus to the new property, then re-run triage-corpus --fetch")
    end
    tickets
  end

  def time(value, what)
    Time.iso8601(value.to_s)
  rescue ArgumentError
    raise InputError.new("#{what} #{value.inspect} is not an ISO 8601 time", "re-run triage-corpus --fetch")
  end

  def number(ref) = TriageCorpus.number(ref) || 0

  def lines(ticket)
    Array(ticket["blocks_text"]).flat_map { |b| b.to_s.split("\n") }
  end

  # provenance(ticket) -> [:none] | [:ok, Hash] | [:unparseable, reason].
  # The LAST line wins: a re-classification appends a newer one.
  def provenance(ticket)
    line = lines(ticket).reverse.find { |l| l.lstrip.start_with?(PROVENANCE_PREFIX) }
    return [:none] if line.nil?

    read_line(line)
  end

  # ── paraphrased lines (DND-1354) ─────────────────────────────────────────
  #
  # Filers pasted paraphrases of the line instead of the line. A paraphrase
  # that keeps all three values and says each is the filer's loses nothing a
  # reader needs (a filer value is never feedback and never an accepted
  # judgment), so it is RECOVERED: the doc is the contract shape with
  # accepted false and judged null, marked "recovered" => <shape>. Anything
  # else is UNPARSEABLE with a reason, never read as absent:
  #   malformed_json      JSON that is neither the contract's shape nor an
  #                       all-filer abbreviation of it
  #   lossy_paraphrase    prose naming Jev, a judgment, shadow, a rule or a
  #                       policy decision: its call, judged label or source
  #                       is gone
  #   unrecognized_prose  prose missing a value or the filer attribution, or
  #                       naming two values for one property
  # A Feature has no Severity, so its paraphrase is never recovered.
  UNPARSEABLE_REASONS = %w[malformed_json lossy_paraphrase unrecognized_prose].freeze
  RECOVERED_SHAPES = %w[abbreviated_json prose_values].freeze
  # What a property may hold, per property, in the tracker's spelling.
  TRACKER_VALUES = { "kind" => ALL_KINDS, "severity" => SEVERITIES, "security" => SECURITY.keys }.freeze
  # A paraphrase naming Jev ("(jev)", "Jev: 0.93", "judged"), a judgment's
  # outcome ("accepted", "shadow", "mode on"), a rule or a policy decision
  # lost the part a reader needs: never read as the filer's. Only "jev-"
  # (the model, "jev-1.13.0") passes. Any other source word is lossy, so the
  # one source left in a recovered line is the filer.
  LOSSY = /\bjev\b(?!-)|\bjudged\b|\baccepted\b|\bshadow\b|\bmode\s+on\b|\bpolicy|\brule\b|\bfloor\b|vulnerability_floor|introduced_security/i
  FILER = /\bfiler\b|\bmode_off\b/i
  PROSE_VALUE = {
    "kind" => /\bKind:?\s+(#{Regexp.union(ALL_KINDS).source})\b/,
    "severity" => /\bSeverity:?\s+(#{Regexp.union(SEVERITIES).source})\b/,
    "security" => /\bSecurity:?\s+(none|introduced|pre-existing)(?![\w-])/
  }.freeze
  FILER_VALUES = %r{\bfiler values\s+(#{Regexp.union(ALL_KINDS).source})\s*/\s*(#{Regexp.union(SEVERITIES).source})\s*/\s*(none|introduced|pre-existing)(?![\w-])}

  # read_line(line) -> [:ok, doc] | [:unparseable, reason], for one line
  # that starts with the prefix.
  def read_line(line)
    text = line.lstrip.delete_prefix(PROVENANCE_PREFIX).strip
    return read_json(text) if text.start_with?("{")

    read_prose(text)
  end

  def read_json(text)
    doc = begin
      JSON.parse(text)
    rescue JSON::ParserError
      nil
    end
    return [:ok, doc] if valid_provenance?(doc)

    filer = abbreviated_filer(doc)
    filer ? [:ok, recovered(filer, "abbreviated_json", doc.slice("model", "versions"))] : [:unparseable, "malformed_json"]
  end

  # abbreviated_filer(doc) -> {property => value} when every property is a
  # filer value in the tracker's set with no judgment behind it (no
  # accepted, no judged label, mode off or absent, no call id), else nil. A
  # shadow or on mode, or a call that answered, means Jev judged: never
  # recovered as the filer's.
  def abbreviated_filer(doc)
    return nil unless doc.is_a?(Hash) && valid_calls?(doc)
    return nil if doc["calls"].is_a?(Hash) && doc["calls"].values.any?

    PROPERTY.values.to_h do |key|
      p = doc[key]
      return nil unless p.is_a?(Hash) && p["source"] == "filer" && TRACKER_VALUES.fetch(key).include?(p["value"])
      return nil unless [nil, false].include?(p["accepted"]) && p["judged"].nil? && [nil, "off"].include?(p["mode"])

      [key, p["value"]]
    end
  end

  def read_prose(text)
    return [:unparseable, "lossy_paraphrase"] if LOSSY.match?(text)
    return [:unparseable, "unrecognized_prose"] unless FILER.match?(text)

    values = prose_values(text)
    values ? [:ok, recovered(values, "prose_values", {})] : [:unparseable, "unrecognized_prose"]
  end

  # prose_values(text) -> {property => value} when the text names all three,
  # either labelled ("Kind Bug, Severity LOW, Security none") or as
  # "filer values Bug / LOW / none"; else nil.
  def prose_values(text)
    m = FILER_VALUES.match(text)
    return { "kind" => m[1], "severity" => m[2], "security" => m[3] } if m

    # Every mention, not the first: two different values for one property
    # are not a reading.
    found = PROSE_VALUE.transform_values { |re| text.scan(re).flatten.uniq }
    found.values.all? { |v| v.size == 1 } ? found.transform_values(&:first) : nil
  end

  def recovered(values, shape, extra)
    doc = values.to_h do |key, value|
      [key, { "value" => value, "source" => "filer", "accepted" => false, "judged" => nil, "mode" => nil, "reason" => nil }]
    end
    doc.merge(extra).merge("recovered" => shape)
  end

  # line_class(provenance) -> "none" | "verbatim" | "recovered_<shape>" |
  # "unparseable_<reason>": how each reader counts a ticket's last line.
  def line_class(prov)
    case prov.first
    when :none then "none"
    when :unparseable then "unparseable_#{prov[1]}"
    else prov[1].key?("recovered") ? "recovered_#{prov[1]['recovered']}" : "verbatim"
    end
  end

  # An accepted judgment must name a label of its property: an accepted
  # judgment with no answer, or an answer outside the set, is a garbled line.
  # A `calls` key (DND-1469) is optional, since a line written before it has
  # none; when present it must be exactly {kind, severity, security}, each a
  # uuid or null, or the line is garbled.
  def valid_provenance?(doc)
    doc.is_a?(Hash) && valid_calls?(doc) && PROPERTY.values.all? do |key|
      p = doc[key]
      next false unless p.is_a?(Hash) && [true, false].include?(p["accepted"]) && SOURCES.include?(p["source"])
      next false unless p["judged"].nil? || p["judged"].is_a?(String)

      p["accepted"] == false || JUDGED.fetch(key).include?(p["judged"])
    end
  end

  CALL_ID = /\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/

  def valid_calls?(doc)
    return true unless doc.key?("calls")

    calls = doc["calls"]
    calls.is_a?(Hash) && calls.keys.sort == PROPERTY.values.sort &&
      calls.values.all? { |id| id.nil? || (id.is_a?(String) && CALL_ID.match?(id)) }
  end

  # calls(doc) -> the line's {property => call id or nil}, or nil when the
  # line predates DND-1469 and carries no calls key (never read as "no call").
  def calls(doc)
    doc["calls"]
  end

  # ── labels ───────────────────────────────────────────────────────────────

  def strip_title(title)
    title.to_s.sub(TITLE_PREFIX, "").strip
  end

  # redact_body(text) -> the body as sent: provenance lines dropped, and every
  # classification statement replaced, so a case is judged on content.
  def redact_body(text)
    kept = text.to_s.each_line.reject { |l| l.lstrip.start_with?(PROVENANCE_PREFIX) }.join
    kept.gsub(REVERSE, REDACTED).gsub(STATEMENT, REDACTED).gsub(PAIR, REDACTED).gsub(LEVEL_WORD, REDACTED).gsub(KIND_BESIDE, REDACTED).strip
  end

  # sent_title(title) -> the title as the eval sends it: no severity prefix,
  # and redacted like the body.
  def sent_title(title)
    truncate(redact_body(strip_title(title)), MAX_TITLE)
  end

  def truncate(text, max) = text.length > max ? text[0, max] : text

  # common_exclusion(ticket, project, prov) -> a reason every use case shares, or nil.
  def common_exclusion(ticket, project, prov)
    return "unknown_project" if project.nil?
    return "body_unread" unless ticket["body_read"] == true
    return "blank_title" unless sent_title(ticket["title"]).gsub(REDACTED, "").match?(/[[:alnum:]]/)
    # The LAST line wins and lines are appended, so on a body cut at the page
    # the line read (or none) may not be the last: a newer one past the page
    # may say Jev set a value, which must never become its own label.
    return "provenance_unread" if ticket["body_truncated"] == true
    return "provenance_unparseable" if prov.first == :unparseable

    nil
  end

  # label_for(use_case, ticket, post_cutoff) -> [label, provenance] | [nil, reason]
  def label_for(use_case, ticket, post_cutoff)
    kind = ticket["kind"]
    case use_case
    when "ticket_kind"
      return [nil, "feature"] if kind == "Feature"

      tracker_value(ticket["kind"], KINDS, post_cutoff) { |v| v }
    when "ticket_severity"
      return [nil, "feature"] if kind == "Feature"

      value = ticket["severity"]
      return [value, "tracker_record"] if post_cutoff && SEVERITIES.include?(value)

      prefix = ticket["title"].to_s[TITLE_PREFIX, 1]
      return [prefix, "title_prefix"] if prefix

      tracker_value(value, SEVERITIES, post_cutoff) { |v| v }
    when "ticket_security"
      tracker_value(ticket["security"], SECURITY.keys, post_cutoff) { |v| SECURITY.fetch(v) }
    end
  end

  def tracker_value(value, allowed, post_cutoff)
    return [nil, "before_cutoff"] unless post_cutoff
    return [nil, "property_unset"] if value.nil? || value == ""
    return [nil, "unknown_value"] unless allowed.include?(value)

    [yield(value), "tracker_record"]
  end

  # labels(snapshot, cutoff = CUTOFF) -> {labels: {uc => rows}, corpus: {uc =>
  # rows}, exclusions: {uc => {reason => n}}}. Deterministic: rows are in
  # ticket-number order.
  def labels(snapshot, cutoff = CUTOFF)
    tickets = tickets!(snapshot).sort_by { |t| [number(t["ref"]), t["ref"].to_s] }
    epic_projects = snapshot.fetch("epic_projects")
    labeled_at = snapshot.fetch("fetched_at")
    cut = time(cutoff, "cutoff")
    out = { labels: {}, corpus: {}, exclusions: {} }
    USE_CASES.each { |uc| out[:labels][uc] = []; out[:corpus][uc] = []; out[:exclusions][uc] = Hash.new(0) }

    tickets.each do |t|
      project = TriageCorpus.project_of(t, epic_projects)
      prov = provenance(t)
      common = common_exclusion(t, project, prov)
      post = time(t["created_time"], "#{t['ref']} created_time") >= cut
      USE_CASES.each do |uc|
        next out[:exclusions][uc][common] += 1 if common
        next out[:exclusions][uc]["jev_decided"] += 1 if prov.first == :ok && prov.last.dig(PROPERTY[uc], "source") == "jev"

        label, why = label_for(uc, t, post)
        next out[:exclusions][uc][why] += 1 if label.nil?

        out[:labels][uc] << { "id" => t["ref"], "label" => label, "provenance" => why, "weak" => true,
                              "labeler" => LABELER, "labeled_at" => labeled_at }
        out[:corpus][uc] << { "id" => t["ref"], "content_domain" => TriageCorpus::DOMAINS.fetch(project), "input" => input(t, project) }
      end
    end
    out[:exclusions].transform_values! { |h| h.sort.to_h }
    out
  end

  def input(ticket, project)
    {
      "title" => sent_title(ticket["title"]),
      "body" => truncate(redact_body(lines(ticket).join("\n")), MAX_BODY),
      "project" => project
    }
  end

  # counts(rows) -> {"label/provenance" => n}
  def counts(rows)
    rows.group_by { |l| "#{l['label']}/#{l['provenance']}" }.transform_values(&:size).sort.to_h
  end

  # ── shadow report ────────────────────────────────────────────────────────

  # wilson_lower_bound(correct, n) -> the Wilson 95% lower bound (z = 1.96),
  # the server's Athena.Judgments.Eval formula; nil for n = 0 (never 0).
  def wilson_lower_bound(correct, n)
    return nil if n.zero?

    p = correct.to_f / n
    z2 = Z * Z
    spread = Z * Math.sqrt(p * (1 - p) / n + z2 / (4.0 * n * n))
    [(p + z2 / (2.0 * n) - spread) / (1 + z2 / n), 0.0].max
  end

  # current(use_case, ticket) -> the label the ticket's value reads as, or nil.
  def current(use_case, ticket)
    case use_case
    when "ticket_kind" then KINDS.include?(ticket["kind"]) ? ticket["kind"] : nil
    when "ticket_severity" then SEVERITIES.include?(ticket["severity"]) ? ticket["severity"] : nil
    when "ticket_security" then SECURITY[ticket["security"]]
    end
  end

  # shadow_report(snapshot, since) -> the agreement of ACCEPTED judgments with
  # each ticket's CURRENT value, over tickets created at or after `since`.
  def shadow_report(snapshot, since)
    from = time(since, "--since")
    fetched = time(snapshot.fetch("fetched_at"), "fetched_at")
    tickets = tickets!(snapshot).select { |t| time(t["created_time"], "#{t['ref']} created_time") >= from }.sort_by { |t| [number(t["ref"]), t["ref"].to_s] }
    report = { since: since, fetched_at: snapshot["fetched_at"], window_days: ((fetched - from) / 86_400.0).round(1),
               filings: tickets.size, lines: 0, no_provenance: [], unparseable: [], body_unread: [], provenance_unread: [],
               recovered: Hash.new { |h, k| h[k] = [] }, unparseable_reasons: Hash.new { |h, k| h[k] = [] },
               use_cases: USE_CASES.to_h { |uc| [uc, { accepted: 0, agreed: 0, excluded: Hash.new(0), by_label: Hash.new { |h, k| h[k] = { accepted: 0, agreed: 0 } } }] } }
    tickets.each do |t|
      next report[:body_unread] << t["ref"] unless t["body_read"] == true
      # A body cut at the page: the last line may be past it (see labels).
      next report[:provenance_unread] << t["ref"] if t["body_truncated"] == true

      state, doc = provenance(t)
      case state
      when :none then report[:no_provenance] << t["ref"]
      when :unparseable
        report[:unparseable] << t["ref"]
        report[:unparseable_reasons][doc] << t["ref"]
      else
        report[:lines] += 1
        report[:recovered][doc["recovered"]] << t["ref"] if doc.key?("recovered")
        USE_CASES.each { |uc| tally(report[:use_cases][uc], uc, t, doc[PROPERTY[uc]]) }
      end
    end
    report[:recovered] = report[:recovered].sort.to_h
    report[:unparseable_reasons] = report[:unparseable_reasons].sort.to_h
    report[:use_cases].each_value do |u|
      u[:lb] = wilson_lower_bound(u[:agreed], u[:accepted])
      u[:excluded] = u[:excluded].sort.to_h
      u[:by_label] = u[:by_label].sort.to_h
    end
    report
  end

  def tally(u, use_case, ticket, prop)
    return unless prop["accepted"] == true
    # Only a shadow judgment is evidence: in mode on the value may be Jev's
    # own, so it would agree with itself.
    return u[:excluded]["mode_#{prop['mode']}"] += 1 unless prop["mode"] == "shadow"
    return u[:excluded]["feature"] += 1 if use_case != "ticket_security" && ticket["kind"] == "Feature"

    now = current(use_case, ticket)
    return u[:excluded]["current_unset"] += 1 if now.nil?

    agree = prop["judged"] == now
    u[:accepted] += 1
    u[:agreed] += 1 if agree
    u[:by_label][prop["judged"]][:accepted] += 1
    u[:by_label][prop["judged"]][:agreed] += 1 if agree
  end

  # bar(report, use_case) -> "met (...)" or "not met (each failing clause)".
  # Advisory: nothing reads it as a precondition for `on` (DND-1450).
  def bar(report, use_case)
    u = report[:use_cases].fetch(use_case)
    fails = []
    fails << "window #{report[:window_days]} days < #{MIN_WINDOW_DAYS}" if report[:window_days] < MIN_WINDOW_DAYS
    fails << "accepted #{u[:accepted]} < #{MIN_ACCEPTED}" if u[:accepted] < MIN_ACCEPTED
    fails << (u[:lb].nil? ? "lb n/a" : format("lb %.3f < %.2f", u[:lb], MIN_LB)) if u[:lb].nil? || u[:lb] < MIN_LB
    return format("met (accepted %d, agreed %d, lb %.3f, window %.1f days)", u[:accepted], u[:agreed], u[:lb], report[:window_days]) if fails.empty?

    capped = report[:window_days] >= MAX_WINDOW_DAYS ? "; #{MAX_WINDOW_DAYS}-day cap reached: insufficient evidence" : ""
    "not met (#{fails.join('; ')})#{capped}"
  end

  def names(refs) = refs.empty? ? "0" : "#{refs.size} (#{refs.join(', ')})"

  # by_reason(refs, groups) -> "N (refs)", then ": reason n, ..." when any.
  def by_reason(refs, groups)
    detail = groups.map { |k, v| "#{k} #{v.size}" }.join(", ")
    detail.empty? ? names(refs) : "#{names(refs)}: #{detail}"
  end

  # shadow_lines(report) -> the printed report.
  def shadow_lines(report)
    out = ["since #{report[:since]} to #{report[:fetched_at]} (#{report[:window_days]} days): filings #{report[:filings]}, provenance lines #{report[:lines]}",
           "no_provenance #{names(report[:no_provenance])}",
           "recovered paraphrases #{by_reason(report[:recovered].values.flatten.sort_by { |r| [number(r), r] }, report[:recovered])}",
           "unparseable #{by_reason(report[:unparseable], report[:unparseable_reasons])}",
           "body_unread #{names(report[:body_unread])}", "provenance_unread (body truncated) #{names(report[:provenance_unread])}"]
    USE_CASES.each do |uc|
      u = report[:use_cases][uc]
      out << if u[:accepted].zero?
               "#{uc}: n/a (0 accepted)#{JudgmentEval::INSUFFICIENT}"
             else
               format("%s: accepted %d, agreed %d, lb %.3f", uc, u[:accepted], u[:agreed], u[:lb])
             end
      out << "  by judged label (accepted/agreed): #{u[:by_label].map { |k, v| "#{k} #{v[:accepted]}/#{v[:agreed]}" }.join(', ')}" unless u[:by_label].empty?
      under = u[:by_label].select { |_, v| v[:accepted] < MIN_ACCEPTED }.keys
      out << "  labels under #{MIN_ACCEPTED} accepted: #{under.join(', ')}" unless under.empty?
      out << "  excluded: #{u[:excluded].map { |k, v| "#{k} #{v}" }.join(', ')}" unless u[:excluded].empty?
    end
    USE_CASES.each { |uc| out << "bar #{uc}: #{bar(report, uc)}" }
    out
  end
end
