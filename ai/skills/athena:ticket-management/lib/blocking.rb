# frozen_string_literal: true

# blocking.rb -- DOMAIN (pure) for the Path part of ticket-classify
# (DND-1057): choosing the candidates from the tracker rows, the candidate
# summaries, the request body, the judged-shape check and the rendering of
# the server's decision, and which Kind's Path is judged at all (DND-1382).
# The server is gen_saas
# Athena.Judgments.TicketBlocking (POST /api/v1/judgments/ticket_blocking),
# which applies the policy; this adds none.
#
# Everything here is a function of its arguments. A malformed row or answer
# raises ArgumentError naming the first field at fault (never its value);
# the script maps that to its own unavailable line, which carries the Fix:.
#
# Deliberately gem-free (stdlib only).

require_relative "classify"

module Blocking
  module_function

  PATHS = %w[Blocking Off].freeze
  SOURCES = %w[jev filer rule].freeze
  # Statuses that end a ticket (ticket-reclassify's CLOSED): never a
  # candidate.
  CLOSED = ["Done", "Cancelled", "Won't Fix"].freeze
  CRITICAL = "Critical"
  MAX_CANDIDATES = 10
  MAX_SUMMARY = 800
  PREFIX = "Jev path: "
  # An epic page id: 32 hex digits, dashed or not.
  EPIC = /\A[0-9a-f]{8}-?[0-9a-f]{4}-?[0-9a-f]{4}-?[0-9a-f]{4}-?[0-9a-f]{12}\z/

  # epic_id(value) -> the dashed page id, or nil when value is not one.
  def epic_id(value)
    return nil unless value.is_a?(String) && EPIC.match?(value.downcase)

    hex = value.downcase.delete("-")
    [hex[0, 8], hex[8, 4], hex[12, 4], hex[16, 4], hex[20, 12]].join("-")
  end

  # filed_kind(classification, filer) -> the Kind the filer will file: the
  # decided Kind of a parsed classification result, or the filer's own when
  # the classification was unavailable (nil). The Path part keys on it
  # (DND-1382), so Path is judged for the Kind that is filed.
  def filed_kind(classification, filer)
    return filer[:kind] if classification.nil?

    kind = classification.dig("properties", "kind", "decided")
    raise ArgumentError, "properties.kind.decided is not one of the tracker's values" unless Classify::KINDS.include?(kind)

    kind
  end

  # judged?(kind) -> whether a ticket of this Kind has its Path judged. A
  # Feature's Path is authored, never judged.
  def judged?(kind)
    kind != "Feature"
  end

  # query_filter(epic_id) -> the data source query body: the epic's tickets
  # whose Path is Critical. Status is checked in code (candidates/1), and so
  # is Path again: the filter narrows the read, it never decides.
  def query_filter(epic_id)
    {
      "filter" => {
        "and" => [
          { "property" => "Epic", "relation" => { "contains" => epic_id } },
          { "property" => "Path", "select" => { "equals" => CRITICAL } }
        ]
      },
      "page_size" => 100
    }
  end

  # candidates(rows) -> {chosen: [{ref, page_id, title}], open: n}: the open
  # Critical tickets, by ID ascending, the first MAX_CANDIDATES. Raises
  # ArgumentError for a row the tracker schema cannot explain (no DND id, no
  # Path select, no Status): an unreadable row is never read as "not a
  # candidate".
  def candidates(rows)
    open = rows.each_with_index.filter_map { |row, i| candidate(row, i) }
    sorted = open.sort_by { |c| c[:number] }
    { chosen: sorted.first(MAX_CANDIDATES).map { |c| c.slice(:ref, :page_id, :title) }, open: sorted.size }
  end

  def candidate(row, index)
    where = "row #{index}"
    raise ArgumentError, "#{where} is not an object" unless row.is_a?(Hash)

    props = row["properties"]
    raise ArgumentError, "#{where} has no properties" unless props.is_a?(Hash)

    uid = props.dig("ID", "unique_id")
    raise ArgumentError, "#{where} has no DND id" unless uid.is_a?(Hash) && uid["prefix"] == "DND" && uid["number"].is_a?(Integer)

    path = props["Path"]
    raise ArgumentError, "#{where} has no Path select (the tracker schema changed?)" unless path.is_a?(Hash) && path.key?("select")

    status = props.dig("Status", "status", "name")
    raise ArgumentError, "#{where} has no Status" unless status.is_a?(String)

    return nil unless path.dig("select", "name") == CRITICAL && !CLOSED.include?(status)

    title = Array(props.dig("Name", "title")).map { |t| t["plain_text"].to_s }.join
    title = Classify.truncate(title, Classify::MAX_TITLE)
    raise ArgumentError, "#{where} (DND-#{uid['number']}) has a blank title" if Classify.blank?(title)
    raise ArgumentError, "#{where} has no page id" unless row["id"].is_a?(String)

    { ref: "DND-#{uid['number']}", number: uid["number"], page_id: row["id"], title: title }
  end

  # block_text(block) -> the plain text of one block, or nil.
  def block_text(block)
    rich = block.is_a?(Hash) ? block.dig(block["type"].to_s, "rich_text") : nil
    rich.is_a?(Array) ? rich.map { |t| t["plain_text"].to_s }.join : nil
  end

  # summary(blocks) -> the page's text blocks joined, cut to MAX_SUMMARY
  # grapheme clusters (the candidate's requirements lead its body).
  def summary(blocks)
    text = Array(blocks).filter_map { |b| block_text(b) }.reject { |t| t.strip.empty? }.join("\n")
    Classify.truncate(text, MAX_SUMMARY)
  end

  # page_title(page) -> the text of the page's title property, or nil.
  def page_title(page)
    props = page.is_a?(Hash) ? page["properties"] : nil
    return nil unless props.is_a?(Hash)

    title = props.values.find { |p| p.is_a?(Hash) && p["type"] == "title" }
    text = Array(title && title["title"]).map { |t| t["plain_text"].to_s }.join
    text.strip.empty? ? nil : text
  end

  # epic_title(page, epics_data_source) -> the epic's title; raises
  # ArgumentError unless the page lives in the Epics data source and is not
  # trashed. A well-formed id is only a key: a ticket's page id would make the
  # Epic filter match nothing and read as "0 candidates" (a failed lookup
  # looking like an empty one).
  def epic_title(page, epics_data_source)
    raise ArgumentError, "the epic page read is not a JSON object" unless page.is_a?(Hash)

    parent = page.dig("parent", "data_source_id")
    unless parent == epics_data_source
      raise ArgumentError, "page #{page['id']} is not a DND epic (its parent is data source #{parent.inspect.delete('"')}); pass the epic's page id"
    end
    raise ArgumentError, "epic page #{page['id']} is in the trash" if page["in_trash"]

    page_title(page) || raise(ArgumentError, "epic page #{page['id']} has no title")
  end

  # considered_line(chosen, open, epic_title) -> the candidate count, printed
  # before any decision (0 included).
  def considered_line(chosen, open, epic_title)
    more = open > chosen.size ? "; the first #{chosen.size} of #{open} by ID" : ""
    "#{chosen.size} candidates considered (epic #{epic_title}, open Critical#{more})"
  end

  # request_body(...) -> the closed body the server's schema accepts. Only the
  # finding, the candidates (ref, title, summary) and the filer's security,
  # found_while and claim: nothing else, and no identity field.
  def request_body(title, body, project, candidates, filer)
    finding = { "title" => Classify.truncate(title, Classify::MAX_TITLE), "body" => Classify.truncate(body, Classify::MAX_BODY), "project" => project }
    cands = candidates.map { |c| { "ref" => c[:ref], "title" => c[:title], "summary" => c[:summary] } }
    f = { "security" => filer[:security] }
    f["found_while"] = filer[:found_while] if filer[:found_while]
    f["claimed_blocks"] = filer[:claimed_blocks] if filer[:claimed_blocks]
    { "finding" => finding, "candidates" => cands, "filer" => f }
  end

  # parse_result(doc, refs, filer) -> doc, when it is the judged shape for
  # this request; raises ArgumentError naming the first field at fault. A
  # Blocks target must be one of the candidates, or found_while by the rule.
  def parse_result(doc, refs, filer)
    raise ArgumentError, "is not a JSON object" unless doc.is_a?(Hash)
    raise ArgumentError, "status is not \"judged\"" unless doc["status"] == "judged"

    path = doc["path"]
    raise ArgumentError, "path is missing or not an object" unless path.is_a?(Hash)
    raise ArgumentError, "path.decided is not Blocking or Off" unless PATHS.include?(path["decided"])
    raise ArgumentError, "path.source is not jev, filer or rule" unless SOURCES.include?(path["source"])
    raise ArgumentError, "path.reason is not an identifier" unless path["reason"].nil? || (path["reason"].is_a?(String) && Classify::REASON.match?(path["reason"]))
    raise ArgumentError, "path.confidence is not a number" unless path["confidence"].nil? || path["confidence"].is_a?(Numeric)

    check_blocks(path, refs, filer)
    line = doc["provenance_line"]
    unless line.is_a?(String) && line.start_with?(PREFIX) && !/[[:cntrl:]]/.match?(line)
      raise ArgumentError, "provenance_line is missing, lacks the \"#{PREFIX}\" prefix, or holds a control character"
    end

    doc
  end

  def check_blocks(path, refs, filer)
    blocks = path["blocks"]
    if path["decided"] == "Off"
      raise ArgumentError, "path.blocks is set but path.decided is Off" unless blocks.nil?
      raise ArgumentError, "path is a jev Off over a claim on a security finding (a judgment never removes it)" if security_claim_removed?(path, filer)
    elsif path["source"] == "rule"
      check_rule(blocks, filer)
    elsif !refs.include?(blocks)
      raise ArgumentError, "path.blocks is not one of the candidates"
    end
  end

  # The rule blocks the found_while ticket of an introduced security issue,
  # and nothing else: a rule answer for any other filing is not this rule.
  def check_rule(blocks, filer)
    raise ArgumentError, "path.blocks is not the found_while ticket the rule blocks" unless blocks.is_a?(String) && blocks == filer[:found_while]
    raise ArgumentError, "path.source is rule but the filer's security is not introduced" unless filer[:security] == "introduced"
  end

  # The server's policy never lets a judgment remove a blocking claim on a
  # finding whose Security is not none; the harness refuses an answer that did.
  def security_claim_removed?(path, filer)
    path["source"] == "jev" && filer[:claimed_blocks] && filer[:security] != "none"
  end

  # decision_lines(result) -> Path with its source, Blocks, then the
  # provenance line verbatim.
  def decision_lines(result)
    path = result["path"]
    blocks = path["blocks"] || "none"
    ["Path: #{path['decided']} (#{source_note(path)})#{Classify.uncalibrated_mark(path)}", "Blocks: #{blocks}", result["provenance_line"]]
  end

  def source_note(path)
    if path["source"] == "jev"
      path["confidence"].is_a?(Numeric) ? format("jev %.2f", path["confidence"]) : "jev"
    else
      path["reason"] ? "#{path['source']}: #{path['reason']}" : path["source"]
    end
  end

  # fallback_lines(filer) -> the filer's own Path under a heading that says
  # the path decision was unavailable (never a provenance line). Introduced
  # security with a found_while ticket blocks that ticket: that is the
  # written rule itself, not a judgment, so the fallback applies it too.
  def fallback_lines(filer)
    target = filer[:security] == "introduced" && filer[:found_while] ? filer[:found_while] : filer[:claimed_blocks]
    ["Decided (filer; path unavailable):", "Path: #{target ? 'Blocking' : 'Off'}", "Blocks: #{target || 'none'}"]
  end
end
