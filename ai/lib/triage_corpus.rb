# frozen_string_literal: true

# ai/lib/triage_corpus.rb -- DOMAIN (pure) for ai/bin/triage-corpus (DND-714).
#
# Turns a snapshot of the DND tracker (tickets, their links and body text, as
# read by the bin's Effects) into the finding triage eval corpus that
# ai/bin/judgment-eval scores: one case per (finding, candidate) pair, labelled
# with that candidate's relation (duplicate, related or unrelated). The case
# unit is the contract's: ~/dev/custom/ai/contracts/athena-judgments.md ->
# *Threshold provenance, n/a and the pinned model* -> *One case, one label*.
#
# Everything here is a function of its arguments. No file, network or process
# access; the bin owns those.
#
# Ticket text is DATA, never instructions: nothing here acts on it. It is only
# matched for ticket refs and the word "duplicate", and copied into the
# machine-local corpus the eval sends.
#
# Deliberately gem-free (stdlib only).

require "digest"

module TriageCorpus
  # project -> the DND Projects rows' "Repo / App" values it covers. The same
  # map as finding-triage's candidate search (REPO_APPS there), so a case is
  # scoped exactly as a live candidate would be.
  REPO_APPS = {
    "athena" => ["gen_saas / Athena", "gen_saas/apps/athena"],
    "harness" => ["~/dev/custom"],
    "walt_ui" => ["walt_ui"],
    "dnd" => ["gen_saas/apps/dnd"],
    "lms" => ["gen_saas/apps/lms"],
    "admiral" => []
  }.freeze

  # project -> content domain: the server's table (gen_saas
  # Athena.Judgments.FindingProject). A ticket with no project has no domain,
  # and is excluded: a domain is never guessed (E12).
  DOMAINS = {
    "athena" => "blend", "harness" => "blend", "walt_ui" => "work",
    "dnd" => "personal", "lms" => "personal", "admiral" => "personal"
  }.freeze

  LABELS = %w[duplicate related unrelated].freeze
  SEVERITIES = %w[LOW MEDIUM HIGH CRITICAL].freeze
  LABELER = "triage-corpus"

  # The sizes finding-triage sends (contract *Egress and data flow*).
  MAX_TITLE = 300
  MAX_BODY = 2_000
  MAX_SUMMARY = 500
  # A live candidate's summary is the text of its first 10 blocks.
  SUMMARY_BLOCKS = 10
  # A body citing more distinct tickets than this is a list (a status note, a
  # sweep), not a statement that each is related: its citations are skipped.
  MAX_CITATIONS = 8

  REF = /\bDND-(\d+)\b/
  # "duplicate of DND-12", "duplicates DND-12", "a duplicate: DND-12", "to
  # duplicate DND-12", "dup of DND-12": the ref right after the phrase. A bare
  # "duplicate DND-n" is an adjective ("the duplicate DND-5 guard"), and
  # "duplicated by DND-n" (code a change duplicated) is not a ticket
  # duplicate; neither matches.
  DUP_PHRASE = /(?:\bduplicate\s+of|\bduplicates|\bduplicate\s*:|\bto\s+duplicate|\bdup\s+of)\s*:?\s*(?:ticket\s+)?\bDND-(\d+)\b/i
  DUPLICATE = DUP_PHRASE
  # "not a duplicate of", "isn't a duplicate", "no duplicate": a negation just
  # before the word voids the match.
  NEGATION = /\b(?:not|no|isn't|isnt|never)\s+(?:an?\s+|the\s+)?/i
  NEGATED = /#{NEGATION.source}\z/i
  # The span redaction removes: a duplicate phrase and its ref, negated or
  # not, across a line break. A negated one leaks the label as surely as a
  # plain one ("not a duplicate of DND-3" says related-or-unrelated).
  LEAK_SPAN = /(?:#{NEGATION.source})?#{DUP_PHRASE.source}/i
  DUP_WORD = /duplicat|\bdup\b/i
  SEVERITY_PREFIX = /\A\s*(LOW|MEDIUM|HIGH|CRITICAL)\s*:/

  # Why a case or a label is not in the corpus. Counted, never dropped silently.
  class InputError < StandardError
    attr_reader :fix

    def initialize(message, fix)
      super(message)
      @fix = fix
    end
  end

  module_function

  # ── Notion rows -> snapshot rows ─────────────────────────────────────────

  def relation_ids(row, name)
    Array(row.dig("properties", name, "relation")).map { |r| r["id"] }.compact
  end

  def relation_truncated?(row)
    %w[Depends\ On Blocks Found\ while Epic].any? { |n| row.dig("properties", n, "has_more") == true }
  end

  # ticket_from_row(row) -> the snapshot's ticket, or nil when the row has no
  # DND id. Body text is added by the fetch (blocks_text, body_read).
  def ticket_from_row(row)
    uid = row.dig("properties", "ID", "unique_id") || {}
    return nil unless uid["prefix"] == "DND" && uid["number"].is_a?(Integer)

    {
      "page_id" => row["id"],
      "ref" => "DND-#{uid['number']}",
      "title" => Array(row.dig("properties", "Name", "title")).map { |t| t["plain_text"].to_s }.join,
      "status" => row.dig("properties", "Status", "status", "name"),
      "area" => row.dig("properties", "Area", "select", "name"),
      "severity" => row.dig("properties", "Severity", "select", "name"),
      # ai/bin/ticket-corpus (DND-1055): the creation instant decides whether
      # a property was set by its filer (W2 rules) or by the W4 backfill.
      "created_time" => row["created_time"],
      "kind" => row.dig("properties", "Kind", "select", "name"),
      "security" => row.dig("properties", "Security", "select", "name"),
      # A property renamed or retyped reads nil like an unset one; naming it
      # here lets ticket-corpus refuse the snapshot instead of 0 labels.
      "schema_missing" => %w[Kind Severity Security].reject { |n| row.dig("properties", n).is_a?(Hash) && row.dig("properties", n).key?("select") },
      # ai/bin/ticket-corpus's ticket_blocking pairs (DND-1057). path_select
      # says the row carries a Path select at all, so a renamed property is
      # refused there, never read as "Path unset".
      "path" => row.dig("properties", "Path", "select", "name"),
      "path_select" => row.dig("properties", "Path").is_a?(Hash) && row.dig("properties", "Path").key?("select"),
      "epic_ids" => relation_ids(row, "Epic"),
      "depends_on" => relation_ids(row, "Depends On"),
      "blocks" => relation_ids(row, "Blocks"),
      "found_while" => relation_ids(row, "Found while"),
      "relations_truncated" => relation_truncated?(row),
      # judgment-feedback scan-tickets (DND-1470) needs the Blocks edges only.
      "blocks_truncated" => row.dig("properties", "Blocks", "has_more") == true
    }
  end

  # project_row(row) -> {repo_app:, epic_ids:} from a DND Projects row.
  def project_row(row)
    { "repo_app" => row.dig("properties", "Repo / App", "select", "name"), "epic_ids" => relation_ids(row, "Epics") }
  end

  # block_text(block) -> the plain text of one block, or nil.
  def block_text(block)
    rich = block.dig(block["type"].to_s, "rich_text")
    rich.is_a?(Array) ? rich.map { |t| t["plain_text"].to_s }.join : nil
  end

  # ── corpus ───────────────────────────────────────────────────────────────

  # epic_projects(project_rows) -> {epic_id => project}. An epic claimed by two
  # projects maps to nil (ambiguous), so its tickets are excluded rather than
  # guessed. A mapped Repo / App value no row carries raises: a stale map
  # would silently drop a whole project.
  def epic_projects(project_rows)
    app_to_project = REPO_APPS.flat_map { |project, apps| apps.map { |a| [a, project] } }.to_h
    seen = {}
    out = {}
    project_rows.each do |row|
      app = row["repo_app"]
      project = app_to_project[app]
      next if project.nil?

      seen[app] = true
      Array(row["epic_ids"]).each do |id|
        out[id] = out.key?(id) && out[id] != project ? nil : project
      end
    end
    missing = app_to_project.keys.reject { |a| seen[a] }
    raise InputError.new("no DND Projects row has Repo / App #{missing.join(', ')}", "update REPO_APPS in ai/lib/triage_corpus.rb and finding-triage together") unless missing.empty?

    out
  end

  # project_of(ticket, epic_projects) -> the ticket's project, or nil.
  # An epic mapped to exactly one project decides it. When no epic maps, a
  # ticket whose Area is Harness is the harness project: the Area is a
  # recorded property naming the harness repo, so this is a mapping, not a
  # guess. Anything else (no mapped epic and another or no Area, or epics in
  # two projects) has no project and is excluded.
  def project_of(ticket, epic_projects)
    epics = Array(ticket["epic_ids"])
    return nil if epics.any? { |id| epic_projects.key?(id) && epic_projects[id].nil? } # an ambiguous epic

    projects = epics.filter_map { |id| epic_projects[id] }.uniq
    return projects.first if projects.size == 1
    return nil if projects.size > 1

    ticket["area"] == "Harness" ? "harness" : nil
  end

  def number(ref)
    ref.to_s[/\ADND-(\d+)\z/, 1]&.to_i
  end

  def body_text(ticket)
    Array(ticket["blocks_text"]).join("\n")
  end

  # refs_in(text) -> distinct "DND-n" refs, in order of first mention.
  def refs_in(text)
    text.to_s.scan(REF).map { |(n)| "DND-#{n.to_i}" }.uniq
  end

  # duplicate_refs(text) -> the refs the text names as duplicates.
  def duplicate_refs(text)
    refs = []
    text.to_s.to_enum(:scan, DUPLICATE).each do
      m = Regexp.last_match
      next if NEGATED.match?(text[0...m.begin(0)])

      refs << "DND-#{m[1].to_i}"
    end
    refs.uniq
  end

  # redact(text) -> body text as the eval sends it. Every line that names a
  # duplicate AND cites a ticket is dropped; then every duplicate phrase left
  # with its ref is removed by its match span (the span may cross a line
  # break, as the phrase match does), and a line left with no word is
  # dropped; then every other ref becomes "[ref]". A live finding does not
  # yet cite the ticket it duplicates, so a case that did would be judged on
  # a label leak, not on content. A line that only uses the word ("a
  # near-duplicate merge") is content and stays.
  def redact(text)
    lines = text.to_s.each_line.reject { |l| DUP_WORD.match?(l) && REF.match?(l) }.join
    spans = lines.gsub(LEAK_SPAN, "").each_line.select { |l| l.match?(/[[:alnum:]]/) }.join
    spans.gsub(REF, "[ref]").strip
  end

  # redact_title(text) -> a title as sent: a duplicate phrase and its ref
  # become "[ref]" (so "Duplicate of DND-9" leaks no label), other refs
  # "[ref]". A title is never dropped.
  def redact_title(text)
    text.to_s.gsub(LEAK_SPAN, "[ref]").gsub(REF, "[ref]").strip
  end

  # blank_title?(ticket) -> true when the title as sent would be blank (the
  # server trims Unicode whitespace and refuses a blank title, so the case
  # would be unscored invalid_request, never judged).
  def blank_title?(ticket)
    redact_title(ticket["title"]).gsub(/[[:space:]​﻿]/, "").empty?
  end

  # summary(candidate) -> its first blocks, each redacted, on one line.
  def summary(candidate)
    blocks = Array(candidate["blocks_text"]).first(SUMMARY_BLOCKS).map { |b| redact(b) }
    blocks.reject(&:empty?).join(" ").gsub(/\s+/, " ")
  end

  def truncate(text, max)
    text.length > max ? text[0, max] : text
  end

  def pair_key(a, b)
    [a, b].sort_by { |r| number(r) }.join("|")
  end

  # links(tickets, by_page) -> {pair_key => {rules:, finding:}} for every
  # linked pair, in any direction, plus the stats of what was skipped.
  # Relation rules, strongest first: duplicate_text > depends_on/blocks >
  # citation. found_while links a pair (so it is never sampled as unrelated)
  # but is not a relation: a finding found while doing X is usually not X.
  def links(tickets, by_page, by_ref)
    out = Hash.new { |h, k| h[k] = { rules: [], finding: nil, candidate: nil } }
    stats = Hash.new(0)
    tickets.each do |t|
      a = t["ref"]
      text = "#{t['title']}\n#{body_text(t)}"
      dups = duplicate_refs(text)
      dups.each do |b|
        next stats[:self_ref] += 1 if b == a
        next stats[:unknown_ref] += 1 unless by_ref.key?(b)

        e = out[pair_key(a, b)]
        e[:rules] << "duplicate_text"
        # A mutual declaration (each names the other) takes the later,
        # higher-numbered ticket as the finding, whatever the scan order.
        if e[:finding].nil? || number(a) > number(e[:finding])
          e[:finding] = a
          e[:candidate] = b
        end
      end
      { "depends_on" => t["depends_on"], "blocks" => t["blocks"], "found_while" => t["found_while"] }.each do |rule, ids|
        Array(ids).each do |pid|
          b = by_page[pid]
          next stats[:unknown_ref] += 1 if b.nil?
          next if b == a

          out[pair_key(a, b)][:rules] << rule
        end
      end
      cited = refs_in(text) - dups - [a]
      if cited.size > MAX_CITATIONS
        # A list is no relation label, but its pairs ARE linked: they must
        # never be sampled as unrelated.
        stats[:citation_list_skipped] += 1
        cited.each { |b| out[pair_key(a, b)][:rules] << "citation_list" if by_ref.key?(b) }
        next
      end
      cited.each do |b|
        next stats[:unknown_ref] += 1 unless by_ref.key?(b)

        out[pair_key(a, b)][:rules] << "citation"
      end
    end
    [out, stats]
  end

  # relation(rules) -> [label, rule] or nil (linked but no relation label).
  def relation(rules)
    return ["duplicate", "duplicate_text"] if rules.include?("duplicate_text")

    rule = %w[depends_on blocks citation].find { |r| rules.include?(r) }
    rule ? ["related", rule] : nil
  end

  # sample_key(seed, key) -> a stable pseudo-random order for sampling.
  def sample_key(seed, key)
    Digest::SHA256.hexdigest("#{seed}:#{key}")
  end

  # The mechanical confirmation of an unrelated pair (brief, DND-714): the two
  # tickets carry DIFFERENT Areas, and no relation link and no citation join
  # them (the pool is already unlinked). Anything else stays proposed.
  UNRELATED_RULE = "different_area_unlinked"

  def rule_confirms_unrelated?(a, b)
    !a["area"].nil? && !b["area"].nil? && a["area"] != b["area"]
  end

  # build(snapshot, unrelated: N, related: M, seed: S) -> {labels:, corpus:,
  # severity:, counts:, excluded:}. Every duplicate is kept; at most M related
  # pairs are (a sample, so related does not swamp the other labels and make
  # its precision a base rate); at most N unrelated pairs per provenance.
  # Deterministic: the same snapshot, N, M and seed give the same output,
  # byte for byte.
  def build(snapshot, unrelated:, related:, seed:)
    tickets = Array(snapshot["tickets"])
    raise InputError.new("the snapshot holds no tickets", "re-run triage-corpus --fetch; zero tickets is a failed read, not an empty tracker") if tickets.empty?

    epic_projects = snapshot.fetch("epic_projects")
    labeled_at = snapshot.fetch("fetched_at")
    by_ref = tickets.to_h { |t| [t["ref"], t] }
    by_page = tickets.to_h { |t| [t["page_id"], t["ref"]] }
    projects = tickets.to_h { |t| [t["ref"], project_of(t, epic_projects)] }
    excluded = Hash.new(0)
    linked, stats = links(tickets, by_page, by_ref)
    stats.each { |k, v| excluded[k] += v }

    # why_not(finding, candidate) -> the exclusion reason, or nil when usable.
    why_not = lambda do |finding, candidate|
      if by_ref[finding]["body_read"] != true || by_ref[candidate]["body_read"] != true then :body_unread
      elsif projects[finding].nil? || projects[candidate].nil? then :no_project
      elsif projects[finding] != projects[candidate] then :cross_project
      elsif blank_title?(by_ref[finding]) || blank_title?(by_ref[candidate]) then :blank_title
      end
    end

    kept = { "duplicate" => [], "related" => [] }
    linked.sort_by { |k, _| k }.each do |key, e|
      label, rule = relation(e[:rules])
      next if label.nil?

      # The duplicate's declarer is the finding; otherwise the later ticket.
      finding, candidate = label == "duplicate" ? [e[:finding], e[:candidate]] : key.split("|").reverse
      reason = why_not.call(finding, candidate)
      next excluded[reason] += 1 if reason

      kept[label] << [finding, candidate, label, "tracker_record", rule]
    end
    sampled = kept["related"].sort_by { |row| sample_key(seed, row[0, 2].join(":")) }.first(related)
    excluded[:related_not_sampled] += kept["related"].size - sampled.size if kept["related"].size > sampled.size
    rows = kept["duplicate"] + sampled
    pool_truncated = tickets.count { |t| t["body_read"] == true && projects[t["ref"]] && truncated?(t) }
    excluded[:unrelated_pool_truncated] += pool_truncated if pool_truncated.positive?
    unrelated_pairs(tickets, projects, linked, unrelated, seed).each do |a, b, provenance|
      rows << [a, b, "unrelated", provenance, provenance == "proposed" ? nil : UNRELATED_RULE]
    end

    labels = rows.map do |finding, candidate, label, provenance, rule|
      { "id" => "#{finding}:#{candidate}", "label" => label, "provenance" => provenance, "rule" => rule, "labeler" => LABELER, "labeled_at" => labeled_at }
    end
    corpus = rows.map do |finding, candidate, _label, _provenance, _rule|
      project = projects[finding]
      { "id" => "#{finding}:#{candidate}", "content_domain" => DOMAINS.fetch(project), "input" => input(by_ref[finding], by_ref[candidate], project) }
    end
    labels.sort_by! { |row| [LABELS.index(row["label"]), row["id"]] }
    corpus.sort_by! { |row| row["id"] }
    { labels: labels, corpus: corpus, severity: severity_labels(tickets, projects, labeled_at),
      counts: counts(labels, corpus), excluded: excluded.sort.to_h }
  end

  # truncated?(ticket) -> true when its links or body were not read whole: a
  # relation with has_more, or a body past the first page of blocks. A link or
  # citation may hide in the unread part, so such a ticket never enters the
  # unrelated pool (it could be sampled "unrelated" with a ticket it names).
  def truncated?(ticket)
    ticket["relations_truncated"] == true || ticket["body_truncated"] == true
  end

  # unrelated_pairs -> [[finding, candidate, provenance]]: up to N
  # rule_confirmed pairs and up to N proposed ones, sampled from unlinked
  # same-project pairs of readable tickets. The finding is the later ticket.
  # Pairs whose titles share a keyword are sampled first: a live candidate is
  # found by a title keyword, so these are the negatives triage actually sees.
  def unrelated_pairs(tickets, projects, linked, n, seed)
    readable = tickets.select { |t| t["body_read"] == true && projects[t["ref"]] && !blank_title?(t) && !truncated?(t) }
    by_project = readable.group_by { |t| projects[t["ref"]] }
    words = readable.to_h { |t| [t["ref"], title_words(t["title"])] }
    confirmable = []
    other = []
    by_project.each_value do |group|
      group.combination(2) do |x, y|
        key = pair_key(x["ref"], y["ref"])
        next if linked.key?(key)

        shared = words[x["ref"]].intersect?(words[y["ref"]]) ? 0 : 1
        (rule_confirms_unrelated?(x, y) ? confirmable : other) << [shared, key]
      end
    end
    pick = ->(pairs) { pairs.sort_by { |shared, k| [shared, sample_key(seed, k)] }.first(n).map(&:last) }
    pick.call(confirmable).map { |k| k.split("|").reverse + ["rule_confirmed"] } +
      pick.call(other).map { |k| k.split("|").reverse + ["proposed"] }
  end

  # title_words(title) -> the title's search words, as finding-triage's
  # candidate search takes them: severity prefix dropped, lowercased, 4+
  # characters, no stopwords.
  def title_words(title)
    words = title.to_s.sub(SEVERITY_PREFIX, "").downcase.scan(/[a-z0-9][a-z0-9_-]{3,}/)
    (words - STOPWORDS).uniq
  end

  # finding-triage's stopword list (its Triage::STOPWORDS).
  STOPWORDS = %w[
    about after again also when where which while with without from into onto that this
    these those there their then than have has had does done doing must should would could
    only just never ever every each over under still some more most less many much very
    what work fails fail failed failing issue issues ticket tickets finding using used uses
    low medium high critical
  ].freeze

  def input(finding, candidate, project)
    {
      "finding" => {
        "title" => truncate(redact_title(finding["title"]), MAX_TITLE),
        "body" => truncate(redact(body_text(finding)), MAX_BODY),
        "project" => project
      },
      "candidates" => [{
        "ref" => candidate["ref"],
        "title" => truncate(redact_title(candidate["title"]), MAX_TITLE),
        "summary" => truncate(summary(candidate), MAX_SUMMARY)
      }]
    }
  end

  # severity_labels -> WEAK labels (an agent assigned them): the title prefix,
  # else the Severity property. Not evaluated in v1 (the contract: severity has
  # no threshold); kept so agreement can be measured later.
  def severity_labels(tickets, projects, labeled_at)
    tickets.filter_map do |t|
      next nil if projects[t["ref"]].nil?

      prefix = t["title"].to_s[SEVERITY_PREFIX, 1]
      level, source = prefix ? [prefix, "title_prefix"] : [t["severity"], "severity_property"]
      next nil unless SEVERITIES.include?(level)

      { "id" => t["ref"], "label" => level, "source" => source, "weak" => true, "labeler" => LABELER, "labeled_at" => labeled_at }
    end.sort_by { |r| number(r["id"]) }
  end

  # counts -> {by_label_provenance: {"duplicate/tracker_record" => n},
  # by_label_domain:, by_rule:, empty_body_by_label: {label => n}, eval_usable: n}.
  # An empty sent finding body (redaction left nothing) is counted per label,
  # so a relation judged mostly on titles is visible.
  def counts(labels, corpus)
    domain = corpus.to_h { |r| [r["id"], r["content_domain"]] }
    empty = corpus.select { |r| r.dig("input", "finding", "body").to_s.empty? }.to_h { |r| [r["id"], true] }
    {
      "empty_body_by_label" => labels.select { |l| empty[l["id"]] }.group_by { |l| l["label"] }.transform_values(&:size).sort.to_h,
      "by_label_provenance" => labels.group_by { |l| "#{l['label']}/#{l['provenance']}" }.transform_values(&:size).sort.to_h,
      "by_label_domain" => labels.reject { |l| l["provenance"] == "proposed" }
                                 .group_by { |l| "#{l['label']}/#{domain[l['id']]}" }.transform_values(&:size).sort.to_h,
      "by_rule" => labels.group_by { |l| l["rule"] || "(proposed)" }.transform_values(&:size).sort.to_h,
      "eval_usable" => labels.count { |l| l["provenance"] != "proposed" }
    }
  end
end
