# frozen_string_literal: true

# next_mission -- the pure selection rule behind ai/bin/next-mission (DND-985).
#
# Given the tickets in an admiral's scope (plus the status of every dependency
# that lies outside it), pick the ONE ticket to dispatch next and name the rule
# that picked it. The rule is the owner-approved priority order of 2026-09-27
# (ai-artifacts/coordination/2026-09-27-scope-growth-proposal.md, section 6
# "Priority order", confirmed in section 7); its prose home is
# athena:ticket-management -> "Priority: critical path first" (the tier table,
# as amended by DND-979).
#
#   tier 0  Path=Promoted                         (owner order; ID as proxy)
#   tier 1  Severity CRITICAL/HIGH, and Kind=Vulnerability with
#           Security=pre-existing (exploitable) or
#           Control=fails-open/fails-closed (a security control misreports)
#   tier 2  Kind=Bug, Path=Blocking               (blocks a functional requirement)
#   tier 3  Path=Critical, in dependency order    (topological, ties by ID)
#   tier 4  everything else: Severity, then Kind order, then age
#
# Control (DND-1747, owner decision 2026-10-02): a security control that fails
# CLOSED is Kind=Bug, not security, but it is prioritized at the same level as
# one that fails OPEN. Control carries that signal apart from Kind, so a
# fail-closed Bug is tier 1 at CRITICAL/HIGH and ranks with Vulnerability in
# tier 4's Kind order. An unset Control on an open CRITICAL/HIGH ticket whose
# tier it could change is reported (control_unset), never read as "none".
#
# Functional-first (owner correction, 2026-09-27): a tier-4 ticket that is not a
# Feature (and not a blocker) is held while any Path=Critical or Kind=Feature
# ticket in scope is unfinished. Tiers 0-2 and blockers are never held.
#
# The harness lane (DND-987, P7): an Area=Harness, Path=Off (or unset),
# non-Feature ticket is the lane's (lane_ticket?). --harness-lane keeps only
# those; without it they are dropped (not_lane) and listed in left_to_lane,
# except at tier 1: an exploitable vulnerability, or a security control that
# misreports at CRITICAL/HIGH, is never deferred.
#
# Inside every tier, a Parked ticket (progress exists, nobody on it) is resumed
# before a fresh one is started; that key comes before severity, kind and age.
#
# Pure: no I/O. Every value outside the known vocabularies raises DataError, so
# a Notion schema change can never be read as "not a candidate".
require "set"

module NextMission
  # A ticket's data is unusable (unknown vocabulary, dangling dependency,
  # duplicate, malformed id). Never read as "no candidate".
  class DataError < StandardError; end

  Ticket = Struct.new(:id, :page_id, :title, :status, :kind, :severity, :path, :area,
                      :depends_on, :created, :control, :security, keyword_init: true)

  # Parked (owner, 2026-09-27): progress exists, the work is undelivered, and
  # nobody is on it. Not terminal, not started unless --started lists it.
  # In Merge Queue (2026-09-27): review, critic and CI passed; the PR waits in
  # a merge queue. Active, so started, and exempt from the stale warning.
  STATUSES   = ["Todo", "Attention Given", "Needs Attention", "Parked", "In Progress",
                "In Merge Queue", "Done", "Cancelled", "Won't Fix"].freeze
  STARTED    = ["In Progress", "In Merge Queue"].freeze
  TERMINAL   = ["Done", "Cancelled", "Won't Fix"].freeze
  SEVERITIES = %w[CRITICAL HIGH MEDIUM LOW].freeze
  KINDS      = %w[Vulnerability Bug Feature Hardening Test Refactor Ops Docs Flake].freeze
  KIND_ORDER = %w[Vulnerability Bug Feature Hardening Test Refactor Ops Docs].freeze
  PATHS      = %w[Critical Blocking Promoted Off].freeze
  AREAS      = %w[Product Harness].freeze
  # Control (DND-1747): does a security control misreport, and which way.
  CONTROLS   = %w[none fails-open fails-closed].freeze
  MISREPORTS = %w[fails-open fails-closed].freeze
  # Security (DND-1789): where a security issue came from. Tier 1(a) needs
  # pre-existing; an introduced one blocks its own ticket instead.
  SECURITIES = %w[none introduced pre-existing].freeze
  TIER1_SEVERITIES = %w[CRITICAL HIGH].freeze
  ID_RE      = /\A[A-Z]+-\d+\z/.freeze

  # The funnel, in order. Each stage keeps the tickets that pass it.
  STAGES = {
    in_scope:             "in scope",
    not_terminal:         "not terminal (Done/Cancelled/Won't Fix)",
    not_flake:            "not Kind=Flake (own lane)",
    not_lane:             "not the harness lane's (Area=Harness, Path=Off, not Feature; tier 1 stays)",
    harness_lane:         "harness lane (Area=Harness, Path=Off, not Feature)",
    not_started:          "not started (In Progress, In Merge Queue, or --started)",
    not_waiting_on_owner: "not waiting on the owner (Needs Attention)",
    unblocked:            "unblocked (every Depends On Done/Cancelled/Won't Fix)",
    functional_first:     "functional-first (tier-4 non-Feature held while a Critical/Feature ticket is unfinished)"
  }.freeze

  # stale_in_progress: in-scope In Progress ids missing from --started, or nil
  # when --started was not given (the check could not run; never an empty
  # list standing in for "not checked"). in_progress: the count checked.
  # control_unset: open in-scope tickets whose unset Control could change
  # their tier (control_unset?), named so the gap never reads as "none".
  Result = Struct.new(:pick, :tier, :rule, :funnel, :emptied_by, :held_back, :reason,
                      :started_not_in_scope, :stale_in_progress, :in_progress, :left_to_lane, :outside_lane,
                      :control_unset, :security_unset, keyword_init: true) do
    def to_h
      { ticket: pick&.id, page_id: pick&.page_id, title: pick&.title, tier: tier, rule: rule,
        funnel: funnel.map { |stage, n| { stage: stage.to_s, label: STAGES.fetch(stage), matched: n } },
        emptied_by: emptied_by&.to_s, held_back: held_back, reason: reason,
        started_not_in_scope: started_not_in_scope, left_to_lane: left_to_lane, outside_lane: outside_lane,
        stale_in_progress: stale_in_progress, stale_check: stale_check, control_unset: control_unset,
        security_unset: security_unset }
    end

    def stale_check
      return "skipped: no --started given, so there is no live-captain list to compare against" if stale_in_progress.nil?

      "checked #{in_progress} In Progress ticket(s) against --started"
    end
  end

  module_function

  def id_number(id)
    id.split("-").last.to_i
  end

  # scope:    Tickets in the admiral's scope.
  # external: Tickets outside the scope that some scope ticket depends on
  #           (only their id and status are read).
  # started:  ticket ids the state log records as started, or nil when the
  #           caller has no such list (then the stale check is skipped).
  def select(scope:, external: [], started: nil, harness_lane: false)
    validate!(scope, external)
    status_of = (external + scope).to_h { |x| [x.id, x.status] }
    ids = started || []
    # A --started id that names no ticket in scope does nothing; it may be a
    # typo, which would let the real started ticket be dispatched twice. It is
    # not an error (the state log spans scopes), but it is reported.
    stray = (ids - scope.map(&:id)).sort_by { |i| id_number(i) }
    # In Progress means a captain is on it now. One with no --started entry is
    # stale. A warning only: it stays excluded as started either way.
    in_progress = sorted_ids(scope.select { |x| x.status == "In Progress" })
    extra = { started_not_in_scope: stray, in_progress: in_progress.size, left_to_lane: [], outside_lane: [],
              stale_in_progress: started && (in_progress - ids),
              control_unset: sorted_ids(scope.select { |x| control_unset?(x) }),
              security_unset: sorted_ids(scope.select { |x| security_unset?(x) }) }
    started = ids.to_set

    funnel = []
    set = scope.dup
    funnel << [:in_scope, set.size]
    set = keep(funnel, :not_terminal, set) { |x| !TERMINAL.include?(x.status) }
    set = keep(funnel, :not_flake, set) { |x| x.kind != "Flake" }
    if harness_lane
      extra[:outside_lane] = sorted_ids(set.reject { |x| lane_ticket?(x) })
      set = keep(funnel, :harness_lane, set) { |x| lane_ticket?(x) }
    else
      lane = set.select { |x| lane_ticket?(x) && tier_of(x) != 1 }
      extra[:left_to_lane] = sorted_ids(lane)
      set = keep(funnel, :not_lane, set) { |x| !lane.include?(x) }
    end
    set = keep(funnel, :not_started, set) { |x| !STARTED.include?(x.status) && !started.include?(x.id) }
    set = keep(funnel, :not_waiting_on_owner, set) { |x| x.status != "Needs Attention" }
    set = keep(funnel, :unblocked, set) { |x| unblocked?(x, status_of) }

    unfinished = scope.select do |x|
      (x.path == "Critical" || x.kind == "Feature") && x.kind != "Flake" && !TERMINAL.include?(x.status)
    end
    held = unfinished.empty? ? [] : set.select { |x| tier_of(x) == 4 && !exempt_from_hold?(x) }
    set -= held
    funnel << [:functional_first, set.size]

    emptied = funnel.find { |_, n| n.zero? }&.first
    return empty_result(funnel, emptied, held, unfinished, extra) if set.empty?

    positions = critical_order(scope)
    tier, ranked = rank(set, positions)
    chosen = ranked.first
    Result.new(pick: chosen, tier: tier, rule: rule_for(chosen, tier, positions), funnel: funnel,
               emptied_by: nil, held_back: sorted_ids(held), reason: nil, **extra)
  end

  # Resuming a Parked ticket beats starting a fresh one in the same tier; it
  # is the first key inside every tier, ahead of severity, kind and age.
  def parked_rank(ticket)
    ticket.status == "Parked" ? 0 : 1
  end

  def sorted_ids(tickets)
    tickets.map(&:id).sort_by { |i| id_number(i) }
  end

  def keep(funnel, stage, set, &blk)
    kept = set.select(&blk)
    funnel << [stage, kept.size]
    kept
  end

  def off?(ticket)
    ticket.path.nil? || ticket.path == "Off"
  end

  # The harness lane's ticket (P7). A Feature is planned work, never the lane's.
  def lane_ticket?(ticket)
    ticket.area == "Harness" && off?(ticket) && ticket.kind != "Feature"
  end

  def unblocked?(ticket, status_of)
    ticket.depends_on.all? { |d| TERMINAL.include?(status_of.fetch(d)) }
  end

  def exempt_from_hold?(ticket)
    ticket.kind == "Feature" || ticket.path == "Blocking"
  end

  # A security control that misreports, either way (DND-1747). Not a Kind:
  # a fail-closed control is a Bug, a fail-open one a Vulnerability.
  def control_misreport?(ticket)
    MISREPORTS.include?(ticket.control)
  end

  # An exploitable vulnerability: Kind=Vulnerability and Security=pre-existing
  # (the tier table's 1(a)). Unset Security is not pre-existing.
  def exploitable?(ticket)
    ticket.kind == "Vulnerability" && ticket.security == "pre-existing"
  end

  # Security-ranked: tier 1 at CRITICAL/HIGH, else Vulnerability's place in
  # tier 4's Kind order. The owner's rule: a fail-closed control is
  # prioritized at the same level as a fail-open one.
  def security_ranked?(ticket)
    ticket.kind == "Vulnerability" || control_misreport?(ticket)
  end

  def tier1?(ticket)
    (exploitable?(ticket) || control_misreport?(ticket)) && TIER1_SEVERITIES.include?(ticket.severity)
  end

  # An open ticket whose unset Control could move it to tier 1: CRITICAL or
  # HIGH and not already security-ranked by Kind. A Feature or a Flake has no
  # control to misreport. MEDIUM and LOW stay tier 4 either way.
  def control_unset?(ticket)
    ticket.control.nil? && !TERMINAL.include?(ticket.status) && TIER1_SEVERITIES.include?(ticket.severity) &&
      !%w[Vulnerability Feature Flake].include?(ticket.kind)
  end

  # An open CRITICAL/HIGH Vulnerability whose Security is unset and which no
  # Control misreport lifts: it ranks below tier 1 until Security is set, so
  # it is named, never silently dropped from tier 1.
  def security_unset?(ticket)
    ticket.kind == "Vulnerability" && ticket.security.nil? && !control_misreport?(ticket) &&
      !TERMINAL.include?(ticket.status) && TIER1_SEVERITIES.include?(ticket.severity)
  end

  def tier_of(ticket)
    return 0 if ticket.path == "Promoted"
    return 1 if tier1?(ticket)
    return 2 if ticket.kind == "Bug" && ticket.path == "Blocking"
    return 3 if ticket.path == "Critical"

    4
  end

  # -> [tier, candidates of the best tier in pick order]
  def rank(set, positions)
    by_tier = set.group_by { |x| tier_of(x) }
    tier = by_tier.keys.min
    group = by_tier[tier]
    ordered =
      case tier
      when 0 then group.sort_by { |x| [parked_rank(x), id_number(x.id)] }
      when 1, 2 then group.sort_by { |x| [parked_rank(x), severity_rank(x), x.created, id_number(x.id)] }
      when 3 then group.sort_by { |x| [parked_rank(x), positions.fetch(x.id)] }
      else tier4_order(group)
      end
    [tier, ordered]
  end

  def severity_rank(ticket)
    SEVERITIES.index(ticket.severity) || SEVERITIES.size
  end

  def kind_rank(ticket)
    return KIND_ORDER.index("Vulnerability") if security_ranked?(ticket)

    KIND_ORDER.index(ticket.kind) || KIND_ORDER.size
  end

  def tier4_order(tickets)
    tickets.sort_by { |x| [parked_rank(x), severity_rank(x), kind_rank(x), x.created, id_number(x.id)] }
  end

  # Topological order of the scope's UNFINISHED Path=Critical tickets over
  # Depends On (Kahn's algorithm, lowest ID first among the ready). An edge to
  # a terminal ticket is satisfied, so a finished ticket's ID never moves the
  # order. validate! has already refused cycles among unfinished tickets.
  # -> { id => 1-based position }
  def critical_order(scope)
    crit = scope.select { |x| x.path == "Critical" && !TERMINAL.include?(x.status) }
    ids = crit.map(&:id).to_set
    indeg = crit.to_h { |x| [x.id, x.depends_on.count { |d| ids.include?(d) }] }
    dependents = Hash.new { |h, k| h[k] = [] }
    crit.each { |x| x.depends_on.each { |d| dependents[d] << x.id if ids.include?(d) } }
    ready = indeg.select { |_, n| n.zero? }.keys
    order = []
    until ready.empty?
      ready.sort_by! { |i| id_number(i) }
      nxt = ready.shift
      order << nxt
      dependents[nxt].each do |dep|
        indeg[dep] -= 1
        ready << dep if indeg[dep].zero?
      end
    end
    order.each_with_index.to_h { |id, i| [id, i + 1] }
  end

  def rule_for(ticket, tier, positions)
    base =
      case tier
      when 0 then "tier 0: owner-promoted (Path=Promoted)"
      when 1 then tier1_rule(ticket)
      when 2 then "tier 2: bug blocking functional requirements (Path=Blocking, #{ticket.severity || 'Severity unset'})"
      when 3
        "tier 3: critical path, dependency order ##{positions.fetch(ticket.id)} of #{positions.size} unfinished"
      else
        what = ticket.path == "Blocking" ? "blocker (Path=Blocking), not held by functional-first" : "other improvements"
        "tier 4: #{what} (#{ticket.severity || 'Severity unset'}, #{ticket.kind || 'Kind unset'}, created #{ticket.created})"
      end
    ticket.status == "Parked" ? "#{base}; resume Parked" : base
  end

  # A Vulnerability keeps its rule text; a control misreport names its
  # direction and Kind, so a fail-closed Bug never reads as a vulnerability.
  def tier1_rule(ticket)
    return "tier 1: exploitable vulnerability (#{ticket.severity})" if exploitable?(ticket)

    "tier 1: security control #{ticket.control.tr('-', ' ')} (#{ticket.kind || 'Kind unset'}, #{ticket.severity})"
  end

  def empty_result(funnel, emptied, held, unfinished, extra)
    reason =
      if emptied == :functional_first
        ids = sorted_ids(unfinished)
        "functional-first: #{held.size} tier-4 ticket(s) held (#{sorted_ids(held).join(', ')}) " \
          "while #{ids.size} Critical/Feature ticket(s) are unfinished: #{ids.join(', ')}"
      elsif emptied == :not_lane
        "no candidate: every remaining ticket is the harness lane's: #{extra[:left_to_lane].join(', ')}"
      else
        "no candidate: the #{STAGES.fetch(emptied)} filter matched 0"
      end
    Result.new(pick: nil, tier: nil, rule: nil, funnel: funnel, emptied_by: emptied,
               held_back: sorted_ids(held), reason: reason, **extra)
  end

  # A cycle among unfinished tickets can never unblock; "blocked" would send
  # the admiral to wait for a landing that cannot happen. Refuse it by name.
  def refuse_cycles!(scope)
    open = scope.reject { |x| TERMINAL.include?(x.status) }.to_h { |x| [x.id, x] }
    state = {}
    visit = lambda do |id, trail|
      return if state[id] == :done
      if state[id] == :active
        cycle = trail.drop_while { |i| i != id } + [id]
        raise DataError, "Depends On cycle among unfinished tickets: #{cycle.join(' -> ')}"
      end

      state[id] = :active
      open[id].depends_on.each { |d| visit.call(d, trail + [id]) if open.key?(d) }
      state[id] = :done
    end
    open.keys.sort_by { |i| id_number(i) }.each { |id| visit.call(id, []) }
  end

  def validate!(scope, external)
    seen = {}
    scope.each do |x|
      check_ticket!(x)
      raise DataError, "#{x.id} appears twice in scope" if seen.key?(x.id)

      seen[x.id] = true
    end
    external.each do |x|
      raise DataError, "external ticket has malformed id #{x.id.inspect}" unless x.id.to_s.match?(ID_RE)
      check_value!(x, "Status", x.status, STATUSES, allow_nil: false)
    end
    known = (scope + external).map(&:id).to_set
    scope.each do |x|
      x.depends_on.each do |d|
        next if known.include?(d)

        raise DataError, "#{x.id} depends on #{d}, whose status was never read"
      end
    end
    refuse_cycles!(scope)
  end

  def check_ticket!(x)
    raise DataError, "ticket has malformed id #{x.id.inspect}" unless x.id.to_s.match?(ID_RE)

    check_value!(x, "Status", x.status, STATUSES, allow_nil: false)
    check_value!(x, "Kind", x.kind, KINDS)
    check_value!(x, "Severity", x.severity, SEVERITIES)
    check_value!(x, "Path", x.path, PATHS)
    check_value!(x, "Area", x.area, AREAS)
    check_value!(x, "Control", x.control, CONTROLS)
    check_value!(x, "Security", x.security, SECURITIES)
    unless x.created.is_a?(String) && !x.created.empty?
      raise DataError, "#{x.id} has no created time string (tiers 1, 2 and 4 order by age): #{x.created.inspect}"
    end
    bad = Array(x.depends_on).reject { |d| d.to_s.match?(ID_RE) }
    raise DataError, "#{x.id} has malformed Depends On id(s) #{bad.inspect}" unless bad.empty?
  end

  def check_value!(ticket, prop, value, allowed, allow_nil: true)
    return if value.nil? && allow_nil
    return if allowed.include?(value)

    raise DataError, "#{ticket.id} has #{prop}=#{value.inspect}, not one of #{allowed.inspect}"
  end
end
