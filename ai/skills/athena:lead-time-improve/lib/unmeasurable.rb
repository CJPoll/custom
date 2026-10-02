# frozen_string_literal: true

# LeadTimeUnmeasurable -- DOMAIN for the unmeasurable-phase escalation
# (DND-1806). Pure: no I/O, no requires.
#
# The lead-time improver's choice rule reads "cannot measure <phase>" when the
# window's biggest phase has more n/a rows than measured ones. Before
# DND-1806 the run then handed the gap off once and re-noted "already handed
# off" every hour: DND-1501 was re-noted for a day and a half and nothing
# escalated until the owner promoted it by hand. Owner, Cody, 2026-10-02:
# "The fact that something is not measurable that could meaningfully help us
# improve lead time is a red flag."
#
# The rule here: count the consecutive runs on which a phase is the biggest
# and unmeasurable, per repo and phase. At THRESHOLD, if its hand-off ticket
# is open, the episode escalates once: a note on the ticket, Path Promoted,
# and ONE harness-alerts message. The episode ends when the ticket lands or
# the phase becomes measurable; then the count resets.
module LeadTimeUnmeasurable
  # A summary, ref or argument that cannot be trusted. Never read as empty.
  class Invalid < StandardError; end

  THRESHOLD = 3
  PHASES = %w[implement verify queue integrate merge].freeze
  SLUG = "leadtime-unmeasurable"
  PROMOTED = "Promoted"
  # DND Tickets statuses (athena:ticket-management -> Status). Landed: the
  # work is on main. Closed: it will not be done. Anything else is open.
  LANDED = ["Done", "Ready for Release"].freeze
  CLOSED = ["Cancelled", "Won't Fix"].freeze
  TICKET_RE = /\ADND-[1-9][0-9]{0,6}\z/.freeze
  REPO_RE = /\A[A-Za-z0-9][A-Za-z0-9_.-]{0,63}\z/.freeze
  RUN_RE = /\A[A-Za-z0-9][A-Za-z0-9._:-]{0,95}\z/.freeze

  module_function

  def blank_entry
    { "runs" => 0, "last_run" => nil, "ticket" => nil, "ticket_landed" => false, "episode" => nil }
  end

  def key(repo, phase) = "#{repo}/#{phase}"

  def repo_name(repo)
    raise Invalid, "repo #{repo.inspect} is not a repo name (letters, digits, _ . -)" unless REPO_RE.match?(repo.to_s)

    repo
  end

  def run_id(run)
    raise Invalid, "run id #{run.inspect} is not one (letters, digits, . _ : -; the cron lane's run-<utc>-<pid>)" unless RUN_RE.match?(run.to_s)

    run
  end

  def phase_name(phase)
    raise Invalid, "phase #{phase.inspect} is not one of #{PHASES.join(', ')}" unless PHASES.include?(phase)

    phase
  end

  def ticket_ref(ref)
    raise Invalid, "ticket #{ref.inspect} is not a DND ticket (DND-N); a hand-off is filed on DND Tickets" unless TICKET_RE.match?(ref.to_s)

    ref
  end

  # measures(summary, repo) -> {biggest: phase|nil, phases: {p => :measured |
  # :unmeasured | :empty}}. summary is lead-time-phases --summary --json for
  # repo. Both sides of the lookup are checked: a summary for another repo,
  # or one missing a phase, is Invalid, never "measured".
  def measures(summary, repo)
    raise Invalid, "the summary is not a JSON object" unless summary.is_a?(Hash)
    raise Invalid, "the summary is for repo #{summary['repo'].inspect}, not #{repo}" unless summary["repo"] == repo

    phases = summary["phases"]
    raise Invalid, "the summary has no phases object" unless phases.is_a?(Hash)

    out = PHASES.to_h do |p|
      row = phases[p]
      raise Invalid, "the summary has no phase #{p}" unless row.is_a?(Hash)

      n = row["n"]
      na = row["n_na"]
      raise Invalid, "phase #{p}: n and n_na must be whole numbers (got #{n.inspect}, #{na.inspect})" unless n.is_a?(Integer) && na.is_a?(Integer)

      [p, measure(n, na)]
    end
    { biggest: biggest_phase(summary["biggest"]), phases: out }
  end

  # The choice rule (SKILL.md step 4): more n/a rows than measured ones.
  def measure(n, n_na)
    return :unmeasured if n_na > n
    return :measured if n.positive?

    :empty
  end

  # A tail or null biggest names no phase to count; anything else must be one.
  def biggest_phase(biggest)
    return nil if biggest.nil?
    raise Invalid, "the summary's biggest is not an object" unless biggest.is_a?(Hash)

    phase = biggest["phase"]
    return nil if phase.nil? || phase == "tail"
    raise Invalid, "the summary's biggest phase #{phase.inspect} is not one of #{PHASES.join(', ')} or tail" unless PHASES.include?(phase)

    phase
  end

  # advance(entry, run:, measure:, biggest:) -> [new entry, event]. Pure.
  #   measured           -> count and episode reset (:measurable when there
  #                         was something to reset)
  #   unmeasured+biggest -> one more run (once per run id): :counted
  #   anything else      -> held: not biggest this run, or no rows at all.
  #                         Holding, never resetting, keeps a phase that
  #                         flaps in and out of biggest from hiding its gap.
  def advance(entry, run:, measure:, biggest:)
    e = deep_copy(entry)
    case measure
    when :measured
      had = e["runs"].positive? || !e["episode"].nil?
      e["runs"] = 0
      e["episode"] = nil
      e["last_run"] = run
      [e, had ? :measurable : nil]
    when :unmeasured
      return [e, nil] unless biggest

      e["runs"] += 1 unless e["last_run"] == run
      e["last_run"] = run
      [e, :counted]
    else
      [e, nil]
    end
  end

  # ticket_state(status) -> :landed | :closed | :open. No status is Invalid.
  def ticket_state(status)
    raise Invalid, "the ticket has no Status" if status.nil? || status.to_s.empty?
    return :landed if LANDED.include?(status)
    return :closed if CLOSED.include?(status)

    :open
  end

  # steps(episode, path) -> what this run still owes the episode, in order.
  # A step is done once per episode; a failed one is retried next run.
  # promoted is "yes" (this tool set it), "already" (it was Promoted when
  # the episode looked) or nil (not yet).
  def steps(episode, path)
    ep = episode || {}
    owed = []
    owed << :note unless ep["noted"]
    owed << :promote if ep["promoted"].nil? && path != PROMOTED
    owed << :alert if ep["alerted"].nil?
    owed
  end

  def ticket_note(repo:, phase:, runs:, run:)
    "Promoted by the lead-time improver (DND-1806), run #{run}: #{phase} on #{repo} has been the biggest " \
      "lead-time phase and unmeasurable (more n/a rows than measured) for #{runs} consecutive improver runs, " \
      "and this hand-off has not landed. Owner, Cody, 2026-10-02: \"The fact that something is not measurable " \
      "that could meaningfully help us improve lead time is a red flag.\""
  end

  def alert_body(repo:, phase:, ticket:, runs:, run:, promoted:, record:)
    promo = case promoted
            when "yes" then "#{ticket} was promoted to Path Promoted, with a note on the ticket."
            when "already" then "#{ticket} was already Path Promoted; a note was added to the ticket."
            else "#{ticket} could NOT be promoted this run (see the record); the next improver run retries it."
            end
    <<~TXT
      The lead-time improver cannot measure #{phase} on #{repo}: it has been the biggest lead-time phase and unmeasurable for #{runs} consecutive runs (run #{run}), and its hand-off ticket #{ticket} has not landed (DND-1806).
      #{promo}
      This is a report. The record named in re: is the authority.

      repo: #{repo}
      phase: #{phase}
      ticket: #{ticket}
      consecutive_runs: #{runs}
      threshold: #{THRESHOLD}
      run: #{run}
      record: #{record}

      Fix: work #{ticket} ahead of the critical path (next-mission schedules Path Promoted first). This alert is sent once per episode; the episode ends when #{ticket} lands or #{phase} becomes measurable.
    TXT
  end

  def record_text(repo:, phase:, ticket:, runs:, run:, promoted:, noted:)
    "unmeasurable: repo=#{repo} phase=#{phase} ticket=#{ticket} runs=#{runs} threshold=#{THRESHOLD} " \
      "run=#{run} promoted=#{promoted || 'no'} noted=#{noted ? 'yes' : 'no'}\n"
  end

  def deep_copy(obj)
    case obj
    when Hash then obj.to_h { |k, v| [k, deep_copy(v)] }
    when Array then obj.map { |v| deep_copy(v) }
    else obj
    end
  end
end
