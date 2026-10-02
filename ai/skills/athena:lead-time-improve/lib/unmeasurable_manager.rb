# frozen_string_literal: true

# LeadTimeUnmeasurableManager -- MANAGER for the unmeasurable-phase
# escalation (DND-1806). It orchestrates the domain (lib/unmeasurable.rb),
# the state store (lib/unmeasurable_store.rb), and two ports injected by the
# caller:
#
#   notion.ticket(ref)          -> {id:, status:, path:}   (raises PortError)
#   notion.promote(page_id)     -> Path = Promoted          (raises PortError)
#   notion.note(page_id, text)  -> appends one paragraph    (raises PortError)
#   alert.send_alert(slug, record, body) -> delivered name  (raises PortError)
#
# scripts/unmeasurable wires the real ports (lib/unmeasurable_notion.rb and
# ai/lib/harness-alert-send.sh); test/unmeasurable_test.rb wires fakes.
#
# Every outcome is a line the run journals verbatim. A port failure is
# COULD-NOT-LOOK (exit 3), never "already handed off"; the step it failed is
# retried next run, and a step that succeeded is never repeated in its
# episode.

require_relative "unmeasurable"
require_relative "unmeasurable_store"

class LeadTimeUnmeasurableManager
  # A Notion or alert call that failed. The message names the call, never a
  # token.
  class PortError < StandardError; end

  U = LeadTimeUnmeasurable

  def initialize(store:, runs_dir:, notion:, alert:)
    @store = store
    @runs_dir = runs_dir
    @notion = notion
    @alert = alert
  end

  # Record the ticket a run handed this repo's phase off to. A different
  # ticket opens a new episode at the held count. -> :recorded | :unchanged
  def handoff(repo:, phase:, ticket:)
    U.repo_name(repo)
    U.phase_name(phase)
    U.ticket_ref(ticket)
    entries = @store.load
    k = U.key(repo, phase)
    entry = entries[k] || U.blank_entry
    return :unchanged if entry["ticket"] == ticket

    entry = U.deep_copy(entry).merge("ticket" => ticket, "ticket_landed" => false, "episode" => nil)
    entries[k] = entry
    @store.save(entries)
    :recorded
  end

  # One run's observation of repo's summary. -> {code:, lines: [line...]}
  # line: {repo:, phase:, runs:, ticket:, status:, outcome:, journal:}
  def observe(repo:, run:, summary:)
    U.repo_name(repo)
    U.run_id(run)
    m = U.measures(summary, repo)
    entries = @store.load
    lines = []
    U::PHASES.each do |phase|
      k = U.key(repo, phase)
      entry, event = U.advance(entries[k] || U.blank_entry, run: run, measure: m[:phases][phase], biggest: m[:biggest] == phase)
      case event
      when :measurable
        lines << line(repo, phase, entry, nil, "MEASURABLE", "#{phase} is measurable on #{repo} again: the count reset and any episode ended")
      when :counted
        entry, ln = escalate(entry, repo, phase, run)
        lines << ln
      end
      entries[k] = entry if entries.key?(k) || event
    end
    if m[:biggest] && lines.none? { |l| l[:phase] == m[:biggest] }
      lines << line(repo, m[:biggest], entries[U.key(repo, m[:biggest])] || U.blank_entry, nil, "MEASURED",
                    "#{m[:biggest]} (the biggest phase) is measurable on #{repo}: nothing to escalate")
    end
    lines << line(repo, "none", U.blank_entry, nil, "NO-PHASE", "no phase is the biggest on #{repo} (tail or none): nothing counted") if m[:biggest].nil?
    @store.save(entries)
    { code: lines.any? { |l| l[:outcome] == "COULD-NOT-LOOK" } ? 3 : 0, lines: lines }
  end

  # -> entries for repo (or all)
  def status(repo: nil)
    entries = @store.load
    repo ? entries.select { |k, _| k.start_with?("#{repo}/") } : entries
  end

  private

  def line(repo, phase, entry, status, outcome, journal)
    { repo: repo, phase: phase, runs: entry["runs"], ticket: entry["ticket"], status: status, outcome: outcome, journal: journal }
  end

  def counted(phase, repo, runs) = "#{phase} unmeasurable on #{repo} for #{runs} consecutive run(s) (escalates at #{U::THRESHOLD})"

  # The phase was the biggest and unmeasurable this run. -> [entry, line]
  def escalate(entry, repo, phase, run)
    ticket = entry["ticket"]
    runs = entry["runs"]
    if ticket.nil?
      return [entry, line(repo, phase, entry, nil, "COUNTING", "#{counted(phase, repo, runs)}; no hand-off ticket is recorded")] if runs < U::THRESHOLD

      return [entry, line(repo, phase, entry, nil, "NO-HANDOFF",
                          "#{counted(phase, repo, runs)} and no hand-off ticket is recorded: the hand-off is this run's action " \
                          "(an architect files it; then record it with unmeasurable handoff)")]
    end
    if entry["ticket_landed"]
      return [entry, line(repo, phase, entry, nil, "HANDOFF-LANDED", landed_text(phase, repo, ticket, runs))]
    end

    begin
      facts = @notion.ticket(ticket)
      state = U.ticket_state(facts[:status])
    rescue PortError, U::Invalid => e
      return [entry, line(repo, phase, entry, nil, "COULD-NOT-LOOK",
                          "#{counted(phase, repo, runs)}; could not look: cannot read hand-off #{ticket} (#{e.message}), " \
                          "so its state is unknown this run; the next run reads it again")]
    end
    status = facts[:status]
    case state
    when :landed
      entry = U.deep_copy(entry).merge("ticket_landed" => true, "runs" => 0, "episode" => nil)
      [entry, line(repo, phase, entry, status, "HANDOFF-LANDED", landed_text(phase, repo, ticket, 0))]
    when :closed
      [entry, line(repo, phase, entry, status, "HANDOFF-CLOSED",
                   "#{counted(phase, repo, runs)}; hand-off #{ticket} is #{status} without landing, so #{phase} is not handed off: " \
                   "a new hand-off is owed (then record it with unmeasurable handoff)")]
    else
      return [entry, line(repo, phase, entry, status, "COUNTING", "#{counted(phase, repo, runs)}; hand-off #{ticket} read open this run (Status #{status})")] if runs < U::THRESHOLD

      run_steps(entry, repo, phase, run, facts)
    end
  end

  def landed_text(phase, repo, ticket, runs)
    "hand-off #{ticket} landed; #{phase} still unmeasurable on #{repo} (#{runs} run(s) since the episode ended): " \
      "measurement maturing if its n/a rows predate the fix, else the fix did not fire and that is a new finding to hand off " \
      "(then record it with unmeasurable handoff)"
  end

  def run_steps(entry, repo, phase, run, facts)
    entry = U.deep_copy(entry)
    ticket = entry["ticket"]
    runs = entry["runs"]
    ep = entry["episode"] ||= { "since" => run, "noted" => false, "promoted" => nil, "alerted" => nil }
    owed = U.steps(ep, facts[:path])
    ep["promoted"] = "already" if ep["promoted"].nil? && facts[:path] == U::PROMOTED
    done = []
    failed = []
    owed.each do |step|
      case step
      when :note
        @notion.note(facts[:id], U.ticket_note(repo: repo, phase: phase, runs: runs, run: run))
        ep["noted"] = true
        done << "noted on the ticket"
      when :promote
        @notion.promote(facts[:id])
        ep["promoted"] = "yes"
        done << "promoted #{ticket} to Path Promoted"
      when :alert
        record = write_record(repo, phase, ticket, runs, run, ep)
        body = U.alert_body(repo: repo, phase: phase, ticket: ticket, runs: runs, run: run, promoted: ep["promoted"], record: record)
        ep["alerted"] = @alert.send_alert(U::SLUG, record, body)
        done << "alerted on harness-alerts (#{ep['alerted']})"
      end
    rescue PortError, SystemCallError => e
      failed << "#{step} failed: #{e.message}"
    end
    head = "#{counted(phase, repo, runs)}; hand-off #{ticket} open (Status #{facts[:status]})"
    done.unshift("#{ticket} was already Path Promoted") if owed.include?(:note) && ep["promoted"] == "already"
    if failed.any?
      return [entry, line(repo, phase, entry, facts[:status], "COULD-NOT-LOOK",
                          "#{head}: escalation (DND-1806) incomplete, could not look: #{failed.join('; ')}" \
                          "#{done.empty? ? '' : "; done: #{done.join(', ')}"}; the next run retries what failed")]
    end
    if owed.empty?
      return [entry, line(repo, phase, entry, facts[:status], "ESCALATED-EARLIER",
                          "#{head}: escalated in run #{ep['since']} (alert #{ep['alerted']}); no repeat until #{ticket} lands or #{phase} is measurable")]
    end

    [entry, line(repo, phase, entry, facts[:status], "ESCALATED", "#{head}: escalated (DND-1806): #{done.join(', ')}")]
  end

  def write_record(repo, phase, ticket, runs, run, ep)
    Dir.mkdir(@runs_dir, 0o700) unless Dir.exist?(@runs_dir)
    path = File.join(@runs_dir, "#{run}.unmeasurable.#{repo}.#{phase}")
    File.write(path, U.record_text(repo: repo, phase: phase, ticket: ticket, runs: runs, run: run,
                                   promoted: ep["promoted"], noted: ep["noted"]))
    path
  end
end
