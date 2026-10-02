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
#   markers: the per-run observe record (lib/unmeasurable_marker.rb,
#   DND-1820); by default the file store under runs_dir
#
# scripts/unmeasurable wires the real ports (lib/unmeasurable_notion.rb and
# ai/lib/harness-alert-send.sh); test/unmeasurable_test.rb wires fakes.
#
# Every outcome is a line the run journals verbatim. A port failure is
# COULD-NOT-LOOK (exit 3), never "already handed off"; the step it failed is
# retried next run. The state is saved after each step that succeeds, inside
# the store's lock, so a later step failing never repeats an earlier one.
# The residual window is at-least-once: a process killed between a step and
# its save, or a save that fails, lets the next run repeat that one step. A
# failed save is reported as "<step> done, but the state was not saved".

require_relative "unmeasurable"
require_relative "unmeasurable_store"
require_relative "unmeasurable_marker"

class LeadTimeUnmeasurableManager
  # A Notion or alert call that failed. The message names the call, never a
  # token.
  class PortError < StandardError; end

  U = LeadTimeUnmeasurable

  def initialize(store:, runs_dir:, notion:, alert:, markers: nil)
    @store = store
    @runs_dir = runs_dir
    @notion = notion
    @alert = alert
    @markers = markers || LeadTimeObserveMarkers.new(runs_dir)
  end

  # Record the ticket a run handed this repo's phase off to. A different
  # ticket opens a new episode at the held count. -> :recorded | :unchanged
  def handoff(repo:, phase:, ticket:)
    U.repo_name(repo)
    U.phase_name(phase)
    U.ticket_ref(ticket)
    @store.transaction do |entries, save|
      k = U.key(repo, phase)
      entry = entries[k] || U.blank_entry
      next :unchanged if entry["ticket"] == ticket

      entries[k] = U.deep_copy(entry).merge("ticket" => ticket, "ticket_landed" => false, "episode" => nil)
      save.call
      :recorded
    end
  end

  # One run's observation of repo's summary.
  # -> {code:, lines: [line...], marker_error: nil | message}
  # line: {repo:, phase:, runs:, ticket:, status:, outcome:, journal:}
  # After the count is saved, it records that this run observed repo
  # (DND-1820). A record that cannot be written is marker_error: the count
  # stands, and the caller says the runner will read this repo as not
  # observed. A refused summary (Invalid) records nothing: nothing counted.
  def observe(repo:, run:, summary:)
    U.repo_name(repo)
    U.run_id(run)
    m = U.measures(summary, repo)
    lines = []
    @store.transaction do |entries, save|
      U::PHASES.each do |phase|
        k = U.key(repo, phase)
        entry, event = U.advance(entries[k] || U.blank_entry, run: run, measure: m[:phases][phase], counts: U.counts?(m, phase))
        next unless entries.key?(k) || event

        entries[k] = entry
        save.call
        case event
        when :measurable
          lines << line(repo, phase, entry, nil, "MEASURABLE", "#{phase} is measurable on #{repo} again: the count reset and any episode ended")
        when :counted
          lines << escalate(entries, k, save, repo, phase, run)
        end
      end
    end
    lines.concat(biggest_lines(repo, m, lines))
    code = lines.any? { |l| l[:outcome] == "COULD-NOT-LOOK" } ? 3 : 0
    { code: code, lines: lines, marker_error: record_observed(repo, run, code, lines) }
  end

  # The repo had no summary to observe this run: its ingest or its summary
  # read failed (DND-1820). Recorded as its own outcome, never as observed.
  # Refused (Invalid) once this run has observed repo: a later failure does
  # not unsay an observation. An observe after it replaces it. -> :recorded
  def ingest_failed(repo:, run:, step:, exit_code:, reason:)
    doc = U.ingest_failed_marker(repo: repo, run: run, step: step, exit_code: exit_code, reason: reason)
    if observed?(@markers.read(run, repo), repo, run)
      raise U::Invalid, "run #{run} already observed #{repo}; an observed run is not an ingest failure"
    end

    @markers.write(run, repo, doc)
    :recorded
  end

  # What this run recorded for repo. Read-only. -> {result: :observed |
  # :ingest_failed | :not_recorded | :could_not_look, path:, ...}. A record
  # that cannot be read, or reads as another run's, is :could_not_look with
  # a reason, never :not_recorded.
  def check(repo:, run:)
    U.repo_name(repo)
    U.run_id(run)
    path = @markers.path(run, repo)
    begin
      doc = @markers.read(run, repo)
    rescue LeadTimeObserveMarkers::Unreadable => e
      return { result: :could_not_look, reason: e.message, path: path }
    end
    return { result: :not_recorded, path: path } if doc.nil?

    begin
      U.read_marker(doc, repo: repo, run: run).merge(path: path)
    rescue U::Invalid => e
      { result: :could_not_look, reason: "#{path}: #{e.message}", path: path }
    end
  end

  # -> entries for repo (or all). Read-only: no lock taken, nothing written.
  def status(repo: nil)
    entries = @store.load
    return entries unless repo

    U.repo_name(repo)
    entries.select { |k, _| k.start_with?("#{repo}/") }
  end

  private

  def record_observed(repo, run, code, lines)
    @markers.write(run, repo, U.observed_marker(repo: repo, run: run, code: code, outcomes: lines.map { |l| l[:outcome] }))
    nil
  rescue SystemCallError => e
    "cannot write #{@markers.path(run, repo)}: #{e.message}"
  end

  def observed?(doc, repo, run)
    U.read_marker(doc, repo: repo, run: run)[:result] == :observed
  rescue U::Invalid
    false
  end

  def biggest_lines(repo, m, lines)
    big = m[:biggest]
    return [line(repo, "none", U.blank_entry, nil, "NO-PHASE", "no phase is the biggest on #{repo} (tail or none): the biggest counts nothing this run")] if big.nil?
    return [] if lines.any? { |l| l[:phase] == big }
    return [line(repo, big, U.blank_entry, nil, "NO-ROWS", "#{big} (the biggest phase) has no rows on #{repo} this window: nothing counted")] if m[:phases][big] == :empty

    [line(repo, big, U.blank_entry, nil, "MEASURED", "#{big} (the biggest phase) is measurable on #{repo}: nothing to escalate")]
  end

  def line(repo, phase, entry, status, outcome, journal)
    { repo: repo, phase: phase, runs: entry["runs"], ticket: entry["ticket"], status: status, outcome: outcome, journal: journal }
  end

  def counted(phase, repo, runs) = "#{phase} unmeasurable on #{repo} on #{runs} counted run(s) (escalates at #{U::THRESHOLD})"

  def owed_handoff(phase, repo, runs, why)
    "#{counted(phase, repo, runs)} and #{why}: no action is not allowed; the hand-off is this run's action " \
      "(instrumentation, or an architect files it; then record it with unmeasurable handoff)"
  end

  # The phase counted this run. Updates entries[k] (saving after each step)
  # and returns its line.
  def escalate(entries, key, save, repo, phase, run)
    entry = entries[key]
    ticket = entry["ticket"]
    runs = entry["runs"]
    if ticket.nil?
      return line(repo, phase, entry, nil, "COUNTING", "#{counted(phase, repo, runs)}; no hand-off ticket is recorded") if runs < U::THRESHOLD

      return line(repo, phase, entry, nil, "NO-HANDOFF", owed_handoff(phase, repo, runs, "no hand-off ticket is recorded"))
    end
    if entry["ticket_landed"]
      return line(repo, phase, entry, nil, "HANDOFF-LANDED", landed_text(phase, repo, ticket, runs)) if runs < U::THRESHOLD

      return line(repo, phase, entry, nil, "NO-HANDOFF", owed_handoff(phase, repo, runs, "its hand-off #{ticket} landed without making it measurable"))
    end

    begin
      facts = @notion.ticket(ticket)
      state = U.ticket_state(facts[:status])
    rescue PortError, U::Invalid => e
      return line(repo, phase, entry, nil, "COULD-NOT-LOOK",
                  "#{counted(phase, repo, runs)}; could not look: cannot read hand-off #{ticket} (#{e.message}), " \
                  "so its state is unknown this run; the next run reads it again")
    end
    status = facts[:status]
    case state
    when :landed
      entries[key] = entry = U.deep_copy(entry).merge("ticket_landed" => true, "runs" => 0, "episode" => nil)
      save.call
      line(repo, phase, entry, status, "HANDOFF-LANDED", landed_text(phase, repo, ticket, 0))
    when :closed
      line(repo, phase, entry, status, "HANDOFF-CLOSED",
           "#{counted(phase, repo, runs)}; hand-off #{ticket} is #{status} without landing, so #{phase} is not handed off: " \
           "a new hand-off is this run's action (then record it with unmeasurable handoff)")
    else
      return line(repo, phase, entry, status, "COUNTING", "#{counted(phase, repo, runs)}; hand-off #{ticket} read open this run (Status #{status})") if runs < U::THRESHOLD

      run_steps(entries, key, save, repo, phase, run, facts)
    end
  end

  def landed_text(phase, repo, ticket, runs)
    "hand-off #{ticket} landed; #{phase} still unmeasurable on #{repo} (#{runs} run(s) counted since): " \
      "measurement maturing if its n/a rows predate the fix; at #{U::THRESHOLD} a new hand-off is owed"
  end

  def run_steps(entries, key, save, repo, phase, run, facts)
    entry = entries[key] = U.deep_copy(entries[key])
    ticket = entry["ticket"]
    runs = entry["runs"]
    ep = entry["episode"] ||= { "since" => run, "noted" => false, "promoted" => nil, "alerted" => nil, "record" => nil }
    owed = U.steps(ep, facts[:path])
    ep["promoted"] = "already" if ep["promoted"].nil? && facts[:path] == U::PROMOTED
    save.call
    done = []
    failed = []
    owed.each do |step|
      begin
        case step
        when :promote
          @notion.promote(facts[:id])
          ep["promoted"] = "yes"
          done << "promoted #{ticket} to Path Promoted"
        when :note
          @notion.note(facts[:id], U.ticket_note(repo: repo, phase: phase, runs: runs, run: run, promoted: ep["promoted"]))
          ep["noted"] = true
          done << "noted on the ticket"
        when :alert
          ep["record"] = write_record(repo, phase, ticket, runs, run, ep)
          body = U.alert_body(repo: repo, phase: phase, ticket: ticket, runs: runs, run: run, promoted: ep["promoted"], record: ep["record"])
          ep["alerted"] = @alert.send_alert(U::SLUG, ep["record"], body)
          done << "alerted on harness-alerts (#{ep['alerted']})"
        end
      rescue PortError, SystemCallError => e
        failed << "#{step} failed: #{e.message}"
        next
      end
      begin
        save.call
      rescue SystemCallError => e
        # The step happened; only its record did not. Say so, and stop: the
        # next run reads the old state and may repeat this step once.
        failed << "#{step} done, but the state was not saved (#{e.message}), so the next run may repeat it"
        break
      end
    end
    refresh_record(repo, phase, ticket, runs, run, ep) if ep["alerted"] && !done.empty? && !owed.include?(:alert)
    head = "#{counted(phase, repo, runs)}; hand-off #{ticket} open (Status #{facts[:status]})"
    done.unshift("#{ticket} was already Path Promoted") if owed.include?(:note) && ep["promoted"] == "already"
    if failed.any?
      return line(repo, phase, entry, facts[:status], "COULD-NOT-LOOK",
                  "#{head}: escalation (DND-1806) incomplete, could not look: #{failed.join('; ')}" \
                  "#{done.empty? ? '' : "; done: #{done.join(', ')}"}; the next run retries what failed")
    end
    if owed.empty?
      return line(repo, phase, entry, facts[:status], "ESCALATED-EARLIER",
                  "#{head}: escalated in run #{ep['since']} (alert #{ep['alerted']}); no repeat until #{ticket} lands or #{phase} is measurable")
    end

    line(repo, phase, entry, facts[:status], "ESCALATED", "#{head}: escalated (DND-1806): #{done.join(', ')}")
  end

  def write_record(repo, phase, ticket, runs, run, ep)
    Dir.mkdir(@runs_dir, 0o700) unless Dir.exist?(@runs_dir)
    path = File.join(@runs_dir, "#{run}.unmeasurable.#{repo}.#{phase}")
    File.write(path, U.record_text(repo: repo, phase: phase, ticket: ticket, runs: runs, run: run,
                                   promoted: ep["promoted"], noted: ep["noted"]))
    path
  end

  # A step retried after the alert (a promotion that failed then) appends its
  # result to the alert's record, which the inbox reader relays from.
  def refresh_record(repo, phase, ticket, runs, run, ep)
    return unless ep["record"] && File.file?(ep["record"])

    File.write(ep["record"], U.record_text(repo: repo, phase: phase, ticket: ticket, runs: runs, run: run,
                                           promoted: ep["promoted"], noted: ep["noted"]), mode: "a")
  rescue SystemCallError
    nil
  end
end
