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
  # "duplicate of DND-12", "duplicates DND-12", "dup of DND-12": the ref
  # within 60 characters of the word, on the same line and sentence.
  DUPLICATE = /\b(?:duplicat\w*|dup)\b[^\n.]{0,60}?\bDND-(\d+)\b/i
  # "not a duplicate of", "isn't a duplicate", "no duplicate": a negation just
  # before the word voids the match.
  NEGATED = /\b(?:not|no|isn't|isnt|never)\s+(?:an?\s+|the\s+)?\z/i
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
      "epic_ids" => relation_ids(row, "Epic"),
      "depends_on" => relation_ids(row, "Depends On"),
      "blocks" => relation_ids(row, "Blocks"),
      "found_while" => relation_ids(row, "Found while"),
      "relations_truncated" => relation_truncated?(row)
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

  # project_of(ticket, epic_projects) -> the ticket's project, or nil when it
  # has no epic, an unmapped epic, or epics in two projects.
  def project_of(ticket, epic_projects)
    projects = Array(ticket["epic_ids"]).map { |id| epic_projects[id] }.uniq
    projects.size == 1 ? projects.first : nil
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

  # redact(text) -> the text as the eval sends it: every ticket ref replaced by
  # "[ref]" and every line naming a duplicate dropped. A live finding does not
  # yet cite the ticket it duplicates, so a case that did would be judged on a
  # label leak, not on content.
  def redact(text)
    text.to_s.each_line.reject { |l| DUP_WORD.match?(l) }.join.gsub(REF, "[ref]").strip
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
        e[:finding] ||= a
        e[:candidate] ||= b
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
        stats[:citation_list_skipped] += 1
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

  # build(snapshot, unrelated: N, seed: S) -> {labels:, corpus:, severity:,
  # counts:, excluded:}. Deterministic: the same snapshot, N and seed give the
  # same output, byte for byte.
  def build(snapshot, unrelated:, seed:)
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

    labels = []
    corpus = []
    add = lambda do |finding, candidate, label, provenance, rule|
      f = by_ref[finding]
      c = by_ref[candidate]
      if f["body_read"] != true || c["body_read"] != true
        excluded[:body_unread] += 1
      elsif projects[finding].nil? || projects[candidate].nil?
        excluded[:no_project] += 1
      elsif projects[finding] != projects[candidate]
        excluded[:cross_project] += 1
      else
        id = "#{finding}:#{candidate}"
        labels << { "id" => id, "label" => label, "provenance" => provenance, "rule" => rule, "labeler" => LABELER, "labeled_at" => labeled_at }
        corpus << { "id" => id, "content_domain" => DOMAINS.fetch(projects[finding]), "input" => input(f, c, projects[finding]) }
      end
    end

    linked.sort_by { |k, _| k }.each do |key, e|
      label, rule = relation(e[:rules])
      next if label.nil?

      finding, candidate = if label == "duplicate"
                             [e[:finding], e[:candidate]]
                           else
                             key.split("|").reverse # the later ticket is the finding
                           end
      add.call(finding, candidate, label, "tracker_record", rule)
    end

    unrelated_pairs(tickets, projects, linked, unrelated, seed).each do |a, b, provenance|
      add.call(a, b, "unrelated", provenance, provenance == "proposed" ? nil : UNRELATED_RULE)
    end

    order = ->(row) { [LABELS.index(row["label"]), row["id"]] }
    labels.sort_by!(&order)
    corpus.sort_by! { |row| row["id"] }
    { labels: labels, corpus: corpus, severity: severity_labels(tickets, projects, labeled_at),
      counts: counts(labels, corpus), excluded: excluded.sort.to_h }
  end

  # unrelated_pairs -> [[finding, candidate, provenance]]: up to N
  # rule_confirmed pairs and up to N proposed ones, sampled from unlinked
  # same-project pairs of readable tickets. The finding is the later ticket.
  def unrelated_pairs(tickets, projects, linked, n, seed)
    readable = tickets.select { |t| t["body_read"] == true && projects[t["ref"]] }
    by_project = readable.group_by { |t| projects[t["ref"]] }
    confirmable = []
    other = []
    by_project.each_value do |group|
      group.combination(2) do |x, y|
        key = pair_key(x["ref"], y["ref"])
        next if linked.key?(key)

        (rule_confirms_unrelated?(x, y) ? confirmable : other) << key
      end
    end
    pick = ->(keys) { keys.sort_by { |k| sample_key(seed, k) }.first(n) }
    pick.call(confirmable).map { |k| k.split("|").reverse + ["rule_confirmed"] } +
      pick.call(other).map { |k| k.split("|").reverse + ["proposed"] }
  end

  def input(finding, candidate, project)
    {
      "finding" => {
        "title" => truncate(redact(finding["title"]), MAX_TITLE),
        "body" => truncate(redact(body_text(finding)), MAX_BODY),
        "project" => project
      },
      "candidates" => [{
        "ref" => candidate["ref"],
        "title" => truncate(redact(candidate["title"]), MAX_TITLE),
        "summary" => truncate(redact(Array(candidate["blocks_text"]).first(SUMMARY_BLOCKS).join(" ")).gsub(/\s+/, " "), MAX_SUMMARY)
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

  # counts -> {by_label_provenance: {"duplicate/tracker_record" => n}, by_domain: {...}, eval_usable: n}
  def counts(labels, corpus)
    domain = corpus.to_h { |r| [r["id"], r["content_domain"]] }
    {
      "by_label_provenance" => labels.group_by { |l| "#{l['label']}/#{l['provenance']}" }.transform_values(&:size).sort.to_h,
      "by_label_domain" => labels.reject { |l| l["provenance"] == "proposed" }
                                 .group_by { |l| "#{l['label']}/#{domain[l['id']]}" }.transform_values(&:size).sort.to_h,
      "by_rule" => labels.group_by { |l| l["rule"] || "(proposed)" }.transform_values(&:size).sort.to_h,
      "eval_usable" => labels.count { |l| l["provenance"] != "proposed" }
    }
  end
end
