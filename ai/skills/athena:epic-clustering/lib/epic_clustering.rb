# frozen_string_literal: true

# epic_clustering -- the pure rules behind athena:epic-clustering (DND-982,
# plan row W5 of ai-artifacts/coordination/2026-09-27-scope-growth-proposal.md).
#
# What it decides, with no I/O:
#   - the never-movable set of an epic (the owner's constraint: a clustering
#     move "should not remove critical path or functional requirements items");
#   - the before/after proof over that set;
#   - the clustering trigger (open Path=Off > open on-path);
#   - C3 near-duplicate CANDIDATES (the architect confirms the root cause);
#   - status hygiene (In Progress with no live captain) and ticket hygiene
#     (a body that cannot answer the problem, the repro/exploit path, or the
#     affected code);
#   - the daily digest's content.
# Its text and Block Kit, and the won't-fix notice, are epic_clustering_view.rb.
#
# Tier and tier-4 order are next-mission's (ai/lib/next_mission.rb), called
# here, never copied. The prose homes are athena:ticket-management ->
# "Priority: critical path first" and "Ticket properties".
#
# Every value that cannot be placed raises DataError, so a miss never reads as
# an empty answer (~/dev/custom/ai/CLAUDE.md -> "A failed lookup must never
# look like an empty one").
require "set"
require "time"
require_relative "../../../lib/next_mission"

module EpicClustering
  class DataError < StandardError; end

  # epic_ids, depends_on and blocks hold Notion page ids; body is nil when the
  # page body was not read.
  Ticket = Struct.new(:id, :page_id, :title, :status, :kind, :severity, :security, :path, :area,
                      :epic_ids, :depends_on, :blocks, :created, :body, keyword_init: true)
  Epic = Struct.new(:page_id, :name, :status, :project, keyword_init: true)

  ON_PATH       = %w[Critical Blocking Promoted].freeze
  TIER1_SEV     = %w[CRITICAL HIGH].freeze
  TERMINAL      = NextMission::TERMINAL
  STARTED       = NextMission::STARTED
  SECURITIES    = %w[none introduced pre-existing].freeze
  NO_EPIC       = "(no epic)"
  WONT_FIX_AGE_DAYS = 14
  WONT_FIX_MAX  = 10
  NEXT_N        = 10
  DUP_THRESHOLD = 0.5
  DUP_MIN_SHARED = 3
  STOPWORDS = %w[the and for with from into onto that this when after before not are was its of on in to a an
                 is it be by or as at no dnd].to_set.freeze

  ProofResult = Struct.new(:mismatches, :joined, keyword_init: true) do
    def ok? = mismatches.empty?
  end

  module_function

  def open?(ticket) = !TERMINAL.include?(ticket.status)

  def id_number(id) = NextMission.id_number(id)

  def sort_ids(ids) = ids.sort_by { |i| id_number(i) }

  # The core. For security: any CRITICAL/HIGH Vulnerability, whatever its
  # Security value, a superset of next-mission's tier 1. "In the epic's own
  # code" cannot be read from a property, so every such ticket linked to the
  # epic counts: the restrictive reading.
  def core?(ticket)
    ticket.kind == "Feature" || ON_PATH.include?(ticket.path) ||
      (ticket.kind == "Vulnerability" && TIER1_SEV.include?(ticket.severity))
  end

  # epic_tickets: every ticket linked to ONE epic, any status. A closed ticket
  # stays in the set, so a status change mid-pass never shifts the proof.
  # -> sorted ticket ids.
  def never_movable(epic_tickets)
    core = epic_tickets.select { |t| core?(t) }
    core_pages = core.map(&:page_id).to_set
    pinned = epic_tickets.select { |t| (t.depends_on + t.blocks).any? { |p| core_pages.include?(p) } }
    sort_ids((core + pinned).map(&:id).uniq)
  end

  # Candidates to move: open, outside the never-movable set, and not started.
  # A started ticket (In Progress, In Merge Queue) stays with the admiral
  # working it.
  def movable(epic_tickets)
    pinned = never_movable(epic_tickets).to_set
    epic_tickets.select { |t| open?(t) && !pinned.include?(t.id) && !STARTED.include?(t.status) }
                .sort_by { |t| id_number(t.id) }
  end

  # Movable tickets grouped by [Area, Kind]; the architect splits each group by
  # subsystem (that judgment is not mechanical).
  def cluster_groups(tickets)
    tickets.group_by { |t| [t.area || "Area unset", t.kind || "Kind unset"] }
           .sort_by { |(area, kind), _| [area, NextMission::KIND_ORDER.index(kind) || 99, kind] }
  end

  # The name prefix of a harness-lane epic. The reader is next-mission's
  # harness lane (ai/docs/ticket-lane-action-brief.md -> Scope: lane epics
  # only), whose adapter holds the same value as
  # NextMissionNotion::LANE_EPIC_PREFIX; the domain cannot require an adapter,
  # so the suite asserts the two are equal. Every movable Area=Harness, Path=Off ticket
  # goes to such an epic, singletons included (the admiral's decision on the
  # epic: a harness leftover on a feature epic is worked by nobody).
  LANE_EPIC_PREFIX = "Harness lane: "

  def lane_epic?(epic) = epic.name.to_s.start_with?(LANE_EPIC_PREFIX)

  # pairs: [[Epic, [Ticket, ...]], ...] -> ids still to route to a lane epic.
  def lane_bound(pairs)
    ids = pairs.reject { |e, _| lane_epic?(e) }.flat_map do |_, ts|
      movable(ts).select { |t| t.area == "Harness" && (t.path.nil? || t.path == "Off") }.map(&:id)
    end
    sort_ids(ids.uniq)
  end

  def trigger(epic_tickets)
    open = epic_tickets.select { |t| open?(t) }
    on = open.count { |t| ON_PATH.include?(t.path) }
    off = open.count { |t| t.path.nil? || t.path == "Off" }
    { open_off: off, open_on_path: on, trips: off > on }
  end

  # ---------------------------------------------------------------- proof

  # pairs: [[Epic, [Ticket, ...]], ...] -> { epic_page_id => {name, count, ids} }
  def proof_snapshot(pairs)
    pairs.to_h do |e, ts|
      ids = never_movable(ts)
      [e.page_id, { "name" => e.name, "count" => ids.size, "ids" => ids }]
    end
  end

  # Every epic in `before` must be read again, and every id in its before set
  # must still be in its after set: the count of the before set, re-counted
  # after the moves, must be equal. That is the owner's constraint (nothing
  # never-movable LEAVES an epic).
  #
  # An id that JOINS a set is reported, not failed: a ticket moved into the
  # epic that holds its dependency becomes pinned there, which breaks
  # nothing. -> ProofResult (mismatches) plus `joined` per epic.
  def compare_proof(before, after)
    raise DataError, "the before snapshot names no epics, so nothing was proven" if before.empty?

    joined = {}
    mismatches = before.filter_map do |id, b|
      a = after[id]
      if a.nil?
        { epic: id, name: b["name"], before_count: b["count"], still_there: 0,
          missing: b["ids"], reason: "epic was not read after the move" }
      else
        extra = sort_ids(a["ids"] - b["ids"])
        joined[id] = extra unless extra.empty?
        missing = sort_ids(b["ids"] - a["ids"])
        unless missing.empty?
          { epic: id, name: b["name"], before_count: b["count"], still_there: b["count"] - missing.size,
            missing: missing, reason: "never-movable id(s) missing after the moves (left the epic, or no longer core)" }
        end
      end
    end
    ProofResult.new(mismatches: mismatches, joined: joined)
  end

  # ---------------------------------------------------------------- C3

  def title_tokens(title)
    title.to_s.downcase.scan(/[a-z0-9][a-z0-9_:-]*/).reject { |w| w.size < 3 || STOPWORDS.include?(w) }.to_set
  end

  # Near-duplicate CANDIDATES among open tickets of one Area: token Jaccard of
  # the titles >= DUP_THRESHOLD, sharing at least DUP_MIN_SHARED tokens (so
  # two short titles never pair on one word). The older ticket (created, then id) is kept.
  # A candidate is not a duplicate until the architect confirms one root cause.
  def duplicate_candidates(tickets)
    open = tickets.select { |t| open?(t) && t.kind != "Feature" }.sort_by { |t| [t.created.to_s, id_number(t.id)] }
    toks = open.to_h { |t| [t.id, title_tokens(t.title)] }
    pairs = []
    open.each_with_index do |a, i|
      open[(i + 1)..].each do |b|
        next unless a.area == b.area

        ta = toks[a.id]
        tb = toks[b.id]
        next if ta.empty? || tb.empty?

        shared = ta & tb
        next if shared.size < DUP_MIN_SHARED

        score = shared.size.to_f / (ta | tb).size
        next if score < DUP_THRESHOLD

        pairs << { keep: a.id, duplicate: b.id, score: score.round(2), shared: (ta & tb).to_a.sort }
      end
    end
    pairs.sort_by { |p| [-p[:score], id_number(p[:keep])] }
  end

  # ---------------------------------------------------------------- hygiene

  # started: ids with a live captain (the state logs' Mission tables, passed as
  # --started), or nil when no such list was given. The fleet registry has no
  # read path from harness tooling. In Merge Queue is active, so exempt.
  def status_hygiene(tickets, started:)
    in_progress = tickets.select { |t| t.status == "In Progress" }
    if started.nil?
      return { checked: in_progress.size, stale: nil,
               skipped: "no --started given; the live-captain source is --started (state logs), " \
                        "and the fleet registry has no read path from harness tooling" }
    end

    live = started.to_set
    stale = in_progress.reject { |t| live.include?(t.id) }.sort_by { |t| id_number(t.id) }.map do |t|
      { id: t.id, title: t.title,
        fix: "A ticket's status follows its captain: Parked if work exists (branch, PR), " \
             "Needs Attention if blocked on Cody, else Todo" }
    end
    # A --started id that names no open ticket may be a typo, which would
    # leave the real live ticket flagged stale. Reported, never dropped.
    open_ids = tickets.select { |t| open?(t) }.map(&:id).to_set
    { checked: in_progress.size, stale: stale, skipped: nil,
      started_not_open: sort_ids(started.uniq.reject { |i| open_ids.include?(i) }) }
  end

  PROBLEM_HEAD = /^\#{1,6}\s*(problem|symptom|observed|what happens|context)\b/i.freeze
  REPRO_HEAD   = /^\#{1,6}\s*(repro|reproduc|exploit|steps|trace|evidence)/i.freeze
  REPRO_WORDS  = /\b(repro|reproduc\w*|exploit\w*|steps to|to trigger|failing test|regression test)\b/i.freeze
  CODE_HEAD    = /^\#{1,6}\s*(affected code|where|location)\b/i.freeze
  CODE_TOKEN   = %r{(\b[\w.-]+/[\w.-]+(/[\w.-]+)*|\b[\w-]+\.(rb|ex|exs|sh|md|ts|tsx|js|py|json|ya?ml|tf|sql|heex)\b|
                    \b[A-Z]\w+(\.[A-Z]\w+)+\b)}x.freeze
  MIN_PROBLEM_WORDS = 40
  UNREAD_SHOWN = 20

  # Can the body answer the three questions of owner note N1? A heuristic
  # flag for the digest; the class fix (a real lint) is DND-993. Features are
  # exempt: their design sub-docs are the body.
  def ticket_hygiene(tickets)
    subject = tickets.select { |t| open?(t) && t.kind != "Feature" }
    unread = subject.select { |t| t.body.nil? }
    read = subject - unread
    flagged = read.filter_map do |t|
      missing = body_gaps(t.body, needs_repro: needs_repro?(t))
      { id: t.id, title: t.title, kind: t.kind, missing: missing } unless missing.empty?
    end
    { scanned: read.size, unread: sort_ids(unread.map(&:id)), flagged: flagged.sort_by { |x| id_number(x[:id]) } }
  end

  # A repro or exploit path is owed by what does something wrong today: a Bug,
  # a Vulnerability, a Flake, or any ticket with Security set (the same split
  # DND-993 proposes). Hardening, Refactor, Test, Docs and Ops owe the problem
  # and the affected code.
  def needs_repro?(ticket)
    %w[Bug Vulnerability Flake].include?(ticket.kind) || (ticket.security && ticket.security != "none")
  end

  def body_gaps(body, needs_repro: true)
    text = body.to_s
    gaps = []
    gaps << "problem" unless text.match?(PROBLEM_HEAD) || text.split.size >= MIN_PROBLEM_WORDS
    if needs_repro && !(text.match?(REPRO_HEAD) || text.include?("```") || text.match?(REPRO_WORDS))
      gaps << "repro/exploit path"
    end
    gaps << "affected code" unless text.match?(CODE_HEAD) || text.match?(CODE_TOKEN)
    gaps
  end

  # ---------------------------------------------------------------- digest

  def nm_ticket(t)
    NextMission::Ticket.new(id: t.id, page_id: t.page_id, title: t.title, status: t.status, kind: t.kind,
                            severity: t.severity, path: t.path, area: t.area, depends_on: [], created: t.created)
  end

  def tier(t) = NextMission.tier_of(nm_ticket(t))

  # Every value outside next-mission's vocabularies (Status, Kind, Severity,
  # Path, Area, created) and ours (Security) is an error, never "not a
  # candidate".
  def validate!(tickets)
    seen = Set.new
    tickets.each do |t|
      NextMission.check_ticket!(nm_ticket(t))
      begin
        Time.iso8601(t.created)
      rescue ArgumentError
        raise DataError, "#{t.id} has created=#{t.created.inspect}, not ISO 8601"
      end
      raise DataError, "#{t.id} appears twice" unless seen.add?(t.id)
      unless t.security.nil? || SECURITIES.include?(t.security)
        raise DataError, "#{t.id} has Security=#{t.security.inspect}, not one of #{SECURITIES}"
      end
      raise DataError, "#{t.id} has no epic list" unless t.epic_ids.is_a?(Array)
    end
    tickets
  rescue NextMission::DataError => e
    raise DataError, e.message
  end

  # tickets: every OPEN ticket in the tracker (so a Depends On page absent
  # from this set is closed). epics: every epic those tickets link to.
  def build_digest(tickets:, epics:, now:, pass_summary: nil, status: nil, hygiene: nil)
    validate!(tickets)
    by_epic = epics.to_h { |e| [e.page_id, e] }
    open = tickets.select { |t| open?(t) && t.kind != "Flake" }
    open.each do |t|
      missing = t.epic_ids.reject { |e| by_epic.key?(e) }
      raise DataError, "#{t.id} links epic(s) #{missing.join(', ')} that were not read" unless missing.empty?
    end
    open_pages = tickets.select { |t| open?(t) }.map(&:page_id).to_set
    now_t = Time.parse(now)

    # A Feature is planned functional work, not a low-tier ticket: it never
    # enters the tier-4 queue. One with no Path=Critical is a planning gap,
    # counted so the architect marks the path.
    tier4 = open.select { |t| tier(t) == 4 && !STARTED.include?(t.status) }
    queue = tier4.reject { |t| t.kind == "Feature" }
    {
      now: now,
      features_off_path: sort_ids((tier4 - queue).map(&:id)),
      tier4_queue: tier4_groups(queue, by_epic),
      next: next_up(queue, open_pages),
      moving: moving(open, by_epic, open_pages),
      wont_fix: wont_fix(queue, now_t),
      pass_summary: pass_summary,
      status: status,
      hygiene: hygiene
    }
  end

  def project_of(t, by_epic)
    return NO_EPIC if t.epic_ids.empty?

    t.epic_ids.map { |e| by_epic.fetch(e).project || "(no project)" }.uniq.sort.join(" + ")
  end

  def tier4_groups(queue, by_epic)
    queue.group_by { |t| [project_of(t, by_epic), t.area || "Area unset"] }.map do |(project, area), ts|
      counts = Hash.new { |h, k| h[k] = Hash.new(0) }
      ts.each { |t| counts[t.kind || "Kind unset"][t.severity || "unset"] += 1 }
      { project: project, area: area, count: ts.size, counts: counts.transform_values(&:to_h).to_h }
    end.sort_by { |g| [-g[:count], g[:project], g[:area]] }
  end

  def unblocked?(t, open_pages) = t.depends_on.none? { |p| open_pages.include?(p) }

  # The order tier 4 is worked once tiers 1-3 are clear: next-mission's
  # tier-4 order over the ready ones (unblocked, not waiting on the owner).
  def next_up(queue, open_pages)
    ready = queue.select { |t| t.status != "Needs Attention" && unblocked?(t, open_pages) }
    by_id = ready.to_h { |t| [t.id, t] }
    NextMission.tier4_order(ready.map { |t| nm_ticket(t) }).first(NEXT_N).map do |n|
      t = by_id.fetch(n.id)
      { id: t.id, title: t.title, kind: t.kind, severity: t.severity, area: t.area }
    end
  end

  def moving(open, by_epic, open_pages)
    upper = open.select { |t| (1..3).cover?(tier(t)) }
    counts = (1..3).to_h { |n| [n, upper.count { |t| tier(t) == n }] }
    owner = upper.select { |t| t.status == "Needs Attention" }
    started = upper.select { |t| STARTED.include?(t.status) }
    blocked = upper.select { |t| t.status != "Needs Attention" && !unblocked?(t, open_pages) } - started
    held = by_epic.values.filter_map do |e|
      unfinished = open.select { |t| t.epic_ids.include?(e.page_id) && (t.path == "Critical" || t.kind == "Feature") }
      waiting = open.count { |t| t.epic_ids.include?(e.page_id) && tier(t) == 4 && t.kind != "Feature" && t.path != "Blocking" }
      next if unfinished.empty? || waiting.zero?

      { epic: e.name, unfinished: sort_ids(unfinished.map(&:id)), held: waiting }
    end
    { tier_counts: counts,
      owner_gated: owner.sort_by { |t| id_number(t.id) }.map { |t| { id: t.id, title: t.title, tier: tier(t) } },
      blocked: sort_ids(blocked.map(&:id)), started: sort_ids(started.map(&:id)),
      held_by_functional_first: held.sort_by { |h| [-h[:held], h[:epic]] } }
  end

  # Old LOW tier-4 tickets whose cost may exceed their value. Never a
  # Vulnerability (security is fixed, not declined, by default) and never a
  # ticket another ticket depends on.
  def wont_fix(queue, now_t)
    queue.filter_map do |t|
      next unless t.severity == "LOW" && t.kind != "Vulnerability" && t.blocks.empty?

      days = ((now_t - Time.parse(t.created)) / 86_400).floor
      next if days < WONT_FIX_AGE_DAYS

      { id: t.id, title: t.title, days: days,
        reason: "LOW #{t.kind || 'Kind unset'}, open #{days} days, nothing depends on it" }
    end.sort_by { |x| [-x[:days], id_number(x[:id])] }.first(WONT_FIX_MAX)
  end
end
