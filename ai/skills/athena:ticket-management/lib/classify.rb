# frozen_string_literal: true

# classify.rb -- DOMAIN (pure) for reading the ticket classification
# server's answer (DND-1054): the tracker's value sets, the filer checks, the
# request body, the judged-shape check and the rendering. Extracted from
# scripts/ticket-classify by DND-1056 so scripts/ticket-reclassify checks an
# answer with the same rules instead of a copy.
#
# Everything here is a function of its arguments. parse_result raises
# ArgumentError naming the first field at fault (never its value); each
# script maps that to its own failure line, which carries the Fix:.
#
# Deliberately gem-free (stdlib only).

module Classify
  module_function

  # The tracker's values (athena:ticket-management -> *Ticket properties*),
  # in its spelling. The server's input schema holds the same sets.
  KINDS = %w[Feature Bug Vulnerability Hardening Refactor Test Flake Docs Ops].freeze
  SEVERITIES = %w[LOW MEDIUM HIGH CRITICAL].freeze
  SECURITIES = %w[none introduced pre-existing].freeze
  SOURCES = %w[jev filer policy].freeze
  PROPERTIES = { "kind" => "Kind", "severity" => "Severity", "security" => "Security" }.freeze
  PROJECT = /\A[a-z0-9_]{1,32}\z/
  REF = /\A[A-Z]+-[0-9]+\z/
  REASON = /\A[a-z0-9_]{1,64}\z/
  PREFIX = "Jev classification: "
  MAX_TITLE = 300
  MAX_BODY = 2_000
  NO_SEVERITY = "(none: Feature)"
  # Shown after a jev value accepted with no eval threshold (reason
  # no_threshold, DND-1450); finding-triage marks the same case the same way.
  UNCALIBRATED_MARK = " [uncalibrated]"

  # filer_error(filer) -> [what, fix] when the filer's three values cannot be
  # sent, or nil.
  def filer_error(filer)
    kind, severity, security = filer.values_at(:kind, :severity, :security)
    severities = "pass one of #{SEVERITIES.join(', ')} (tracker spelling), or none with --kind Feature"
    return ["--kind #{kind} is not a Kind", "pass one of #{KINDS.join(', ')}"] unless KINDS.include?(kind)
    return ["--security #{security} is not a Security value", "pass one of #{SECURITIES.join(', ')}"] unless SECURITIES.include?(security)
    return ["--kind Feature takes --severity none (a Feature has no Severity)", "pass --severity none"] if kind == "Feature" && severity != "none"
    return ["--severity none is only for --kind Feature", severities] if kind != "Feature" && severity == "none"
    return ["--severity #{severity} is not a Severity", severities] unless severity == "none" || SEVERITIES.include?(severity)

    nil
  end

  # blank?(text) -> true for "" and Unicode whitespace only. The server trims
  # Unicode whitespace (String.trim), so an ASCII-only strip would send a
  # title it refuses. Zero-width characters are not whitespace to either side.
  def blank?(text)
    text.to_s.gsub(/[[:space:]]/, "").empty?
  end

  # length(text) -> the length the server measures: grapheme clusters, as
  # Elixir's String.length counts them.
  def length(text)
    text.grapheme_clusters.size
  end

  # truncate(text, max) -> at most max grapheme clusters, never a split one.
  def truncate(text, max)
    length(text) > max ? text.grapheme_clusters.first(max).join : text
  end

  # request_body(...) -> the closed body the server's schema accepts: the
  # ticket (ref only when given) and the filer's values (`none` severity is
  # null). Nothing else, and no identity field: the owner is the token's.
  def request_body(title, body, project, ref, filer)
    ticket = { "title" => truncate(title, MAX_TITLE), "body" => truncate(body, MAX_BODY), "project" => project }
    ticket["ref"] = ref if ref
    severity = filer[:severity] == "none" ? nil : filer[:severity]
    { "ticket" => ticket, "filer" => { "kind" => filer[:kind], "severity" => severity, "security" => filer[:security] } }
  end

  # parse_result(doc, filer) -> doc, when it is the contract's judged shape
  # for this filer; raises ArgumentError naming the first field at fault
  # (never its value).
  def parse_result(doc, filer)
    raise ArgumentError, "is not a JSON object" unless doc.is_a?(Hash)
    raise ArgumentError, "status is not \"judged\"" unless doc["status"] == "judged"

    props = doc["properties"]
    raise ArgumentError, "properties is missing or not an object" unless props.is_a?(Hash)

    PROPERTIES.each_key { |name| check_property(name, props[name]) }
    check_decided(props, filer)
    line = doc["provenance_line"]
    unless line.is_a?(String) && line.start_with?(PREFIX) && !/[[:cntrl:]]/.match?(line)
      raise ArgumentError, "provenance_line is missing, lacks the \"#{PREFIX}\" prefix, or holds a control character"
    end

    doc
  end

  def check_property(name, prop)
    where = "properties.#{name}"
    raise ArgumentError, "#{where} is missing or not an object" unless prop.is_a?(Hash)
    raise ArgumentError, "#{where}.source is not jev, filer or policy" unless SOURCES.include?(prop["source"])
    raise ArgumentError, "#{where}.reason is not an identifier" unless prop["reason"].nil? || (prop["reason"].is_a?(String) && REASON.match?(prop["reason"]))

    judged = prop["judged"]
    return if judged.nil? || (judged.is_a?(Hash) && judged["confidence"].is_a?(Numeric))

    raise ArgumentError, "#{where}.judged has no numeric confidence"
  end

  # The decided values must be the tracker's. Feature is authored: it is
  # decided exactly when the filer sent it, and only a Feature has an empty
  # severity. An empty value is never read as a decision.
  def check_decided(props, filer)
    kind = props["kind"]["decided"]
    raise ArgumentError, "properties.kind.decided is not one of the tracker's values" unless KINDS.include?(kind)
    raise ArgumentError, "properties.security.decided is not one of the tracker's values" unless SECURITIES.include?(props["security"]["decided"])
    if (kind == "Feature") != (filer[:kind] == "Feature")
      raise ArgumentError, "properties.kind.decided assigns or replaces Feature, which the policy never does"
    end

    severity = props["severity"]["decided"]
    if kind == "Feature"
      raise ArgumentError, "properties.severity.decided is set but the decided kind is Feature" unless severity.nil?
    elsif severity.nil?
      raise ArgumentError, "properties.severity.decided is empty but the decided kind is not Feature"
    elsif !SEVERITIES.include?(severity)
      raise ArgumentError, "properties.severity.decided is not one of the tracker's values"
    end
  end

  # decision_lines(result) -> one line per property with its source, then the
  # provenance line verbatim.
  def decision_lines(result)
    props = result["properties"]
    PROPERTIES.map { |name, label| "#{label}: #{shown(props[name]['decided'])} (#{source_note(props[name])})#{uncalibrated_mark(props[name])}" } +
      [result["provenance_line"]]
  end

  def shown(value)
    value.nil? ? NO_SEVERITY : value
  end

  # uncalibrated_mark(prop) -> the mark for a jev value accepted with no
  # threshold, else "". The provenance line is never touched.
  def uncalibrated_mark(prop)
    prop["source"] == "jev" && prop["reason"] == "no_threshold" ? UNCALIBRATED_MARK : ""
  end

  def source_note(prop)
    if prop["source"] == "jev"
      confidence = prop.dig("judged", "confidence")
      confidence.is_a?(Numeric) ? format("jev %.2f", confidence) : "jev"
    else
      prop["reason"] ? "#{prop['source']}: #{prop['reason']}" : prop["source"]
    end
  end

  # fallback_lines(filer) -> the filer's own values under a heading that says
  # the classification was unavailable (never a provenance line).
  def fallback_lines(filer)
    severity = filer[:severity] == "none" ? NO_SEVERITY : filer[:severity]
    ["Decided (filer; classification unavailable):", "Kind: #{filer[:kind]}", "Severity: #{severity}", "Security: #{filer[:security]}"]
  end
end
