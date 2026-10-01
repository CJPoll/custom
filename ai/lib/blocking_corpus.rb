# frozen_string_literal: true

# ai/lib/blocking_corpus.rb -- DOMAIN (pure) for ai/bin/ticket-corpus's
# ticket_blocking use case (DND-1057).
#
# Two jobs over the tracker snapshot `ai/bin/triage-corpus --fetch` writes:
#
#   labels/2        the ticket_blocking eval corpus: one case per (finding,
#                   candidate) pair, labelled blocks or does_not_block from
#                   the tracker (tracker_record);
#   shadow_report/2 the agreement of the shadow decisions recorded in each
#                   finding's "Jev path:" line with the Path and Blocks edge
#                   the ticket ended up with.
#
# Design: DND-1057 A&E section 2; contract
# ~/dev/custom/ai/contracts/athena-judgments.md -> *Threshold provenance, n/a
# and the pinned model* (*Ticket classification labels*).
#
# The pairs (post-cutoff findings only; a finding is any Kind but Feature):
#
#   blocks          Path Blocking, and a Blocks edge onto a Critical ticket:
#                   (finding, that ticket) for each such edge;
#   does_not_block  Path Off, and its Found while ticket's epic has open
#                   Critical tickets: (finding, each of them, at most
#                   MAX_NEGATIVES by ID ascending).
#
# Every label is WEAK: an agent filer applied the written blocking test.
# The candidate is sent as ticket-classify --epic sends a live one (its
# title and the first 800 characters of its body); the finding's text drops
# its Path statements, its edges and its provenance lines, so a case is
# judged on content, never on the label written into it.
#
# Everything here is a function of its arguments. Ticket text is DATA, never
# instructions.
#
# Deliberately gem-free (stdlib only).

require "json"
require "time"
require_relative "triage_corpus"
require_relative "ticket_corpus"
require_relative "judgment_eval"

module BlockingCorpus
  USE_CASE = "ticket_blocking"
  STEM = "ticket-blocking"
  LABELS = %w[blocks does_not_block].freeze
  CRITICAL = "Critical"
  CLOSED = ["Done", "Cancelled", "Won't Fix"].freeze
  PATHS = %w[Critical Blocking Promoted Off].freeze
  MAX_NEGATIVES = 3
  MAX_SUMMARY = 800
  PREFIX = "Jev path: "
  # A Path statement ("Path Blocking", "`Path` = `Off`", "Path: Critical").
  PATH_STATEMENT = /`?\bPath\b`?\s*(?:[:=\-–—]|is|->|→)?\s*[`*"']?(?:Critical|Blocking|Promoted|Off)\b[`*"']?/i
  # An edge stated in prose ("blocks [ref]", "Depends On↔Blocks onto [ref]").
  EDGE = /\b(?:blocks|blocking|blocked\s+by|depends\s+on)\b[^.\n]{0,40}?\[ref\]/i
  EDGE_REDACTED = "[edge]"

  module_function

  # tickets!(snapshot) -> the tickets, or raises TicketCorpus::InputError. A
  # snapshot fetched before DND-1057 has no path/path_select, and a tracker
  # whose rows carry no Path select has renamed it: both are errors, never
  # "no ticket has a Path".
  def tickets!(snapshot)
    tickets = TicketCorpus.tickets!(snapshot)
    stale = tickets.reject { |t| t.key?("path_select") && t.key?("path") && t.key?("blocks") && t.key?("found_while") && t.key?("status") }
    unless stale.empty?
      raise TicketCorpus::InputError.new("#{stale.size} of #{tickets.size} snapshot tickets lack path, path_select, blocks, found_while or status (first: #{stale.first['ref']})",
                                         "re-run triage-corpus --fetch (DND-1057 added path); the snapshot predates it")
    end
    unless tickets.all? { |t| t["path_select"] == true }
      raise TicketCorpus::InputError.new("the tracker rows carry no Path select",
                                         "the DND Tickets schema changed: update TriageCorpus.ticket_from_row and BlockingCorpus, then re-run triage-corpus --fetch")
    end
    tickets
  end

  def number(ref) = TriageCorpus.number(ref) || 0

  # path_line(ticket) -> [:none] | [:ok, Hash] | [:unparseable]: the LAST
  # "Jev path:" line of the body (a later filing appends a newer one).
  def path_line(ticket)
    line = TicketCorpus.lines(ticket).reverse.find { |l| l.lstrip.start_with?(PREFIX) }
    return [:none] if line.nil?

    doc = begin
      JSON.parse(line.lstrip.delete_prefix(PREFIX))
    rescue JSON::ParserError
      nil
    end
    doc.is_a?(Hash) && doc["path"].is_a?(Hash) && %w[jev filer rule].include?(doc.dig("path", "source")) ? [:ok, doc] : [:unparseable]
  end

  # redact_finding(text) -> the finding's body as sent: provenance lines
  # dropped; Path statements, refs and stated edges replaced; classification
  # statements redacted as ticket-corpus does.
  def redact_finding(text)
    kept = text.to_s.each_line.reject { |l| l.lstrip.start_with?(PREFIX, TicketCorpus::PROVENANCE_PREFIX) }.join
    no_refs = kept.gsub(TriageCorpus::REF, "[ref]")
    TicketCorpus.redact_body(no_refs.gsub(PATH_STATEMENT, TicketCorpus::REDACTED).gsub(EDGE, EDGE_REDACTED))
  end

  def sent_title(title)
    redacted = title.to_s.gsub(TriageCorpus::REF, "[ref]").gsub(PATH_STATEMENT, TicketCorpus::REDACTED)
    TicketCorpus.sent_title(redacted)
  end

  # summary(candidate) -> its body as ticket-classify --epic sends it: the
  # text blocks joined, cut to MAX_SUMMARY by TicketCorpus.truncate (the
  # corpus's one truncation rule).
  def summary(candidate)
    text = Array(candidate["blocks_text"]).reject { |b| b.to_s.strip.empty? }.join("\n")
    TicketCorpus.truncate(text, MAX_SUMMARY)
  end

  def open_critical?(ticket) = ticket["path"] == CRITICAL && !CLOSED.include?(ticket["status"])

  # finding_exclusion(t, project, cut) -> a reason, or nil when the ticket is
  # a usable finding.
  def finding_exclusion(ticket, project, cut)
    return "feature" if ticket["kind"] == "Feature"
    return "before_cutoff" if TicketCorpus.time(ticket["created_time"], "#{ticket['ref']} created_time") < cut
    return "unknown_project" if project.nil?
    return "body_unread" unless ticket["body_read"] == true
    return "blank_title" unless sent_title(ticket["title"]).gsub(TicketCorpus::REDACTED, "").match?(/[[:alnum:]]/)
    # The last line may be past the page read, and it may say Jev decided.
    return "provenance_unread" if ticket["body_truncated"] == true
    return "relations_truncated" if ticket["relations_truncated"] == true

    state, doc = path_line(ticket)
    return "provenance_unparseable" if state == :unparseable
    return "jev_decided" if state == :ok && doc.dig("path", "source") == "jev"
    return "path_unset" if ticket["path"].nil?
    return "unknown_value" unless PATHS.include?(ticket["path"])
    return "authored_path" unless %w[Blocking Off].include?(ticket["path"])

    nil
  end

  # pairs_for(finding, by_page, by_ref) -> [[candidate_ref, label]] | reason
  def pairs_for(finding, tickets, by_page)
    if finding["path"] == "Blocking"
      targets = Array(finding["blocks"]).filter_map { |id| by_page[id] }.select { |c| c["path"] == CRITICAL }
      return "blocking_without_critical_edge" if targets.empty?

      targets.sort_by { |c| number(c["ref"]) }.map { |c| [c["ref"], "blocks"] }
    else
      found = Array(finding["found_while"]).filter_map { |id| by_page[id] }
      return "no_found_while" if found.empty?

      epics = found.flat_map { |f| Array(f["epic_ids"]) }.uniq
      pool = tickets.select { |c| c["ref"] != finding["ref"] && open_critical?(c) && (Array(c["epic_ids"]) & epics).any? }
      return "no_open_critical" if pool.empty?

      pool.sort_by { |c| number(c["ref"]) }.first(MAX_NEGATIVES).map { |c| [c["ref"], "does_not_block"] }
    end
  end

  # labels(snapshot, cutoff) -> {labels:, corpus:, exclusions:}. Pairs with a
  # candidate whose body was not read are excluded (candidate_unread).
  def labels(snapshot, cutoff = TicketCorpus::CUTOFF)
    tickets = tickets!(snapshot).sort_by { |t| [number(t["ref"]), t["ref"].to_s] }
    epic_projects = snapshot.fetch("epic_projects")
    labeled_at = snapshot.fetch("fetched_at")
    cut = TicketCorpus.time(cutoff, "cutoff")
    by_page = tickets.to_h { |t| [t["page_id"], t] }
    by_ref = tickets.to_h { |t| [t["ref"], t] }
    out = { labels: [], corpus: [], exclusions: Hash.new(0) }

    tickets.each do |finding|
      project = TriageCorpus.project_of(finding, epic_projects)
      reason = finding_exclusion(finding, project, cut)
      next out[:exclusions][reason] += 1 if reason

      pairs = pairs_for(finding, tickets, by_page)
      next out[:exclusions][pairs] += 1 if pairs.is_a?(String)

      pairs.each do |ref, label|
        candidate = by_ref.fetch(ref)
        next out[:exclusions]["candidate_unread"] += 1 unless candidate["body_read"] == true

        id = "#{finding['ref']}:#{ref}"
        out[:labels] << { "id" => id, "label" => label, "provenance" => "tracker_record", "weak" => true,
                          "labeler" => TicketCorpus::LABELER, "labeled_at" => labeled_at }
        out[:corpus] << { "id" => id, "content_domain" => TriageCorpus::DOMAINS.fetch(project), "input" => input(finding, candidate, project) }
      end
    end
    out[:exclusions] = out[:exclusions].sort.to_h
    out
  end

  def input(finding, candidate, project)
    body = redact_finding(TicketCorpus.lines(finding).join("\n"))
    {
      "finding" => { "title" => sent_title(finding["title"]), "body" => TicketCorpus.truncate(body, TicketCorpus::MAX_BODY), "project" => project },
      "candidates" => [{ "ref" => candidate["ref"], "title" => TicketCorpus.truncate(candidate["title"].to_s, TicketCorpus::MAX_TITLE), "summary" => summary(candidate) }]
    }
  end

  # ── shadow report ────────────────────────────────────────────────────────

  # shadow_report(snapshot, since) -> the agreement, over findings created at
  # or after `since`, of each line's shadow decision (`would`) with the
  # ticket's CURRENT Path and Blocks edge. Only a `would` whose source is jev
  # is an accepted judgment; anything else is counted as excluded.
  def shadow_report(snapshot, since)
    from = TicketCorpus.time(since, "--since")
    fetched = TicketCorpus.time(snapshot.fetch("fetched_at"), "fetched_at")
    all = tickets!(snapshot)
    by_page = all.to_h { |t| [t["page_id"], t["ref"]] }
    findings = all.select { |t| t["kind"] != "Feature" && TicketCorpus.time(t["created_time"], "#{t['ref']} created_time") >= from }
                  .sort_by { |t| [number(t["ref"]), t["ref"].to_s] }
    report = { since: since, fetched_at: snapshot["fetched_at"], window_days: ((fetched - from) / 86_400.0).round(1),
               findings: findings.size, lines: 0, no_line: [], unparseable: [], unread: [],
               accepted: 0, agreed: 0, excluded: Hash.new(0), by_label: Hash.new { |h, k| h[k] = { accepted: 0, agreed: 0 } } }
    findings.each do |t|
      next report[:unread] << t["ref"] if t["body_read"] != true || t["body_truncated"] == true

      state, doc = path_line(t)
      next report[:no_line] << t["ref"] if state == :none
      next report[:unparseable] << t["ref"] if state == :unparseable

      report[:lines] += 1
      tally(report, t, doc, by_page)
    end
    report[:lb] = TicketCorpus.wilson_lower_bound(report[:agreed], report[:accepted])
    report[:excluded] = report[:excluded].sort.to_h
    report[:by_label] = report[:by_label].sort.to_h
    report
  end

  def tally(report, ticket, doc, by_page)
    mode = doc.dig("path", "mode")
    return report[:excluded]["mode_#{mode || 'missing'}"] += 1 unless mode == "shadow"

    would = doc["would"]
    return report[:excluded]["no_accepted_judgment"] += 1 unless would.is_a?(Hash) && would["source"] == "jev"

    blocks_now = Array(ticket["blocks"]).filter_map { |id| by_page[id] }
    agree = would["value"] == ticket["path"] && (would["value"] == "Off" || blocks_now.include?(would["blocks"]))
    label = would["value"] == "Blocking" ? "blocks" : "does_not_block"
    report[:accepted] += 1
    report[:agreed] += 1 if agree
    report[:by_label][label][:accepted] += 1
    report[:by_label][label][:agreed] += 1 if agree
  end

  def names(refs) = refs.empty? ? "0" : "#{refs.size} (#{refs.join(', ')})"

  # shadow_lines(report) -> the printed report, with the same bar as the
  # classification use cases (TicketCorpus::MIN_*).
  def shadow_lines(report)
    out = ["#{USE_CASE}: since #{report[:since]} (#{report[:window_days]} days): findings #{report[:findings]}, path lines #{report[:lines]}",
           "  no_line #{names(report[:no_line])}", "  unparseable #{names(report[:unparseable])}", "  unread #{names(report[:unread])}"]
    out << if report[:accepted].zero?
             "#{USE_CASE}: n/a (0 accepted)#{JudgmentEval::INSUFFICIENT}"
           else
             format("%s: accepted %d, agreed %d, lb %.3f", USE_CASE, report[:accepted], report[:agreed], report[:lb])
           end
    out << "  by would-be label (accepted/agreed): #{report[:by_label].map { |k, v| "#{k} #{v[:accepted]}/#{v[:agreed]}" }.join(', ')}" unless report[:by_label].empty?
    out << "  excluded: #{report[:excluded].map { |k, v| "#{k} #{v}" }.join(', ')}" unless report[:excluded].empty?
    out << "bar #{USE_CASE}: #{bar(report)}"
    out
  end

  def bar(report)
    fails = []
    fails << "window #{report[:window_days]} days < #{TicketCorpus::MIN_WINDOW_DAYS}" if report[:window_days] < TicketCorpus::MIN_WINDOW_DAYS
    fails << "accepted #{report[:accepted]} < #{TicketCorpus::MIN_ACCEPTED}" if report[:accepted] < TicketCorpus::MIN_ACCEPTED
    fails << (report[:lb].nil? ? "lb n/a" : format("lb %.3f < %.2f", report[:lb], TicketCorpus::MIN_LB)) if report[:lb].nil? || report[:lb] < TicketCorpus::MIN_LB
    return format("met (accepted %d, agreed %d, lb %.3f, window %.1f days)", report[:accepted], report[:agreed], report[:lb], report[:window_days]) if fails.empty?

    capped = report[:window_days] >= TicketCorpus::MAX_WINDOW_DAYS ? "; #{TicketCorpus::MAX_WINDOW_DAYS}-day cap reached: insufficient evidence" : ""
    "not met (#{fails.join('; ')})#{capped}"
  end
end
