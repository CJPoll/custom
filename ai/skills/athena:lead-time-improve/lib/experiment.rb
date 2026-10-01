# frozen_string_literal: true

# experiment -- the DOMAIN of athena:lead-time-improve's scripts/experiment
# (DND-1478). Pure: no file, process, network or clock access. Every input,
# `now` included, arrives as a value.
#
# An experiment is one landed change (or instrumentation change) on one
# phase of one `improve` repo, judged before/after on comparable landings
# from the lead-time-phases ledger (ai/docs/lead-time-improver.md ->
# *The improvement procedure*, Decision 8):
#
#   * comparable: same repo, the metric measured (non-null), the
#     experiment's own landing excluded. Pre-emitter rows are null, so they
#     never form a before-set: a metric first measured after the boundary
#     has NO before-set (n/a), never a short or empty one read as zero.
#   * K = 10 per side: before = the last K comparable landings before the
#     experiment's landing, after = the first K after it.
#   * keep: median down at least 10%, p90 not up, every guard measured on
#     both sides and none worse. revert: median up, or any guard worse.
#     pending while a side is short of K or the result is neither; after 7
#     days, inconclusive (it then no longer blocks its phase).
#   * instrumentation: success is the phase's n/a share falling. Duration is
#     not compared, and it is never reverted for a share that did not fall.
#   * one pending `change` per phase; instrumentation is exempt. A `revert`
#     verdict also blocks its phase until the revert is seen on main, when
#     judge records `reverted`, or until the decline verb records `declined`
#     (DND-1547): a median-only revert the hard constraint forbids landing.
#     Judge never writes `declined`, and a worse guard is never declined.
#   * a revert whose commit added test lines, or where git could not tell,
#     is HELD (DND-1549): still `revert`, but a plain git revert is ruled
#     out. Only FirstParty.test_path? (a pure function) is used from
#     ai/lib/first_party.rb; its git readers are not called here.
#   * a change on the same phase from ANOTHER experiment (any machine), seen
#     as a `Lead-time-experiment:` commit trailer (ai/lib/lead_time_trailer.rb)
#     landed inside the window (the before-set's first landing to the
#     after-set's last), makes the verdict `confounded` (DND-1529): recorded,
#     terminal, treated as inconclusive. It never becomes keep or revert. The
#     store is machine-local; the trailer is what another machine can see.
#     Instrumentation is exempt both ways, as it is from the blocker rule.
#   * only `improve`-mode rows count, one row per landing (batch tickets
#     sharing a landed commit are one landing).
#   * cross-repo (DND-1528): a change that landed in another repo (the
#     change repo, e.g. a harness change in custom) measured on this repo's
#     landings. It splits at live_at, when the change went live on the
#     change repo's main, and excludes no landing: the measured repo has none
#     of its own. live_at is the landed_at of the change repo's first ledger
#     row whose landed commit carries it (the push or merge time;
#     live_at_source "ledger"); until such a row is ingested, the committer
#     time of its first-parent landing commit ("committer"), which a
#     fast-forward push follows later. Never the author date. A record with
#     no change_repo, or one equal to its repo, is same-repo, unchanged.
#   * tail (DND-1613): a product change (the measured repo's own CI/CD, lever
#     product) is judged on tail, landing -> post-merge run, on `--metric
#     phase` only. A row is comparable on tail only when lead-time found a
#     post-merge run that concluded (tail_end deploy or pipeline, or a
#     nonzero tail on a row ingested before tail_end existed); a 0 from a
#     landing with no such run, or a 0 with no tail_end, is n/a with its
#     reason, never a measured 0. The change lands in the measured repo
#     itself (no --change-repo). Foreign rows (DND-1531) count:
#     their tail is read from the forge, not from this machine's telemetry,
#     so where the work was done does not change it. Its revert is a revert
#     PR in the measured repo through that repo's own bar (DND-1540).
#
# The store (experiments.jsonl) is rows of two types, latest status wins:
#   {"type":"record", "id", "repo", "phase", "metric", "kind", "commit", ...}
#   {"type":"status", "id", "status", "reason", "before", "after", "guards", ...}

require "time"
require_relative "../../../lib/lead_time_phases"
require_relative "../../../lib/first_party"
require_relative "../../../lib/lead_time_config"
require_relative "../../../lib/lead_time_trailer"

module LeadTimeExperiment
  SCHEMA = 1
  K = 10
  MIN_DROP = 0.10
  PENDING_DAYS = 7
  KINDS = %w[change instrumentation].freeze
  STATUSES = %w[pending keep revert inconclusive reverted declined confounded].freeze
  # A revert verdict is settled as a judgement but OWED as an action until
  # the revert lands, so it is not terminal. `declined` (DND-1547) is a
  # revert the hard constraint forbids landing: terminal, and not blocking.
  # `confounded` (DND-1529) is settled as inconclusive: terminal, not blocking.
  TERMINAL = %w[keep inconclusive reverted declined confounded].freeze
  BLOCKING = %w[pending revert].freeze
  # The statuses judge may write. `declined` is written only by the decline
  # verb (decline_row), so the loop never declines on its own.
  JUDGED = (STATUSES - %w[declined]).freeze
  # Why a revert may be declined. `safety-checks`: the revert would delete,
  # skip or weaken a check or test (ai/blocks/ops/safety-checks.md).
  # `bug-fix`: the revert would reinstate a defect the commit fixed.
  CONSTRAINTS = %w[safety-checks bug-fix].freeze
  SHA_RE = /\A[0-9a-f]{40}\z/.freeze
  REVERT_RE = /This reverts commit ([0-9a-f]{40})/.freeze
  PHASES = LeadTimePhases::PHASES
  # tail: landing -> post-merge run (DND-1532's biggest candidate, lever
  # product). Not a ledger phase: its seconds are the row's tail_s.
  TAIL = "tail"
  EXPERIMENT_PHASES = (PHASES + [TAIL]).freeze
  # The end kinds at which lead-time found a post-merge run that concluded,
  # lead-time-phases' own constant (Metric#measured_tail applies its rule).
  # One difference is deliberate: the summary picks a tail candidate from
  # local rows only (DND-1531), while a tail experiment compares foreign
  # rows too, since their tail is read from the forge.
  TAIL_RUN_ENDS = LeadTimePhases::Stats::TAIL_RUN_ENDS
  TOTALS = { "lead" => "lead_s", "code" => "code_s" }.freeze
  COUNTERS = %w[gate_runs gate_wall_s gate_red slot_wait_s critic_rounds critic_blocks critic_wall_s lock_wait_s].freeze
  GUARDS = %w[critic_block_rate gate_red_rate reverts].freeze
  NA_SHARE = "na_share"
  CHECK_PREFIX = "check:"
  # How many near labels a refused check:<label> names.
  CLOSEST = 5

  class UsageError < StandardError; end

  # What one experiment measures on a ledger row.
  #   phase              the experiment's phase duration (phases.<phase>.s)
  #   lead | code        the landing's total (lead_s / code_s)
  #   counter:<name>     a ledger counter (counters.<name>)
  #   check:<label>      one harness-gate check's wall on the landing's gated
  #                      head (check_walls.<label>, DND-1548): a change whose
  #                      mechanism is one check is judged on that check
  #   na_share           instrumentation: whether the phase is n/a at all
  # On tail (DND-1613) only `phase` exists: the row's measured tail_s.
  Metric = Struct.new(:name, :phase, keyword_init: true) do
    def self.parse(name, phase:)
      unless EXPERIMENT_PHASES.include?(phase)
        raise UsageError, "unknown phase #{phase.inspect} (known: #{EXPERIMENT_PHASES.join(', ')})"
      end

      n = name.to_s
      if phase == TAIL && n != "phase"
        raise UsageError, "tail is judged on --metric phase only (its measured landing -> post-merge run time), " \
                          "not #{n.inspect}"
      end
      if n.start_with?(CHECK_PREFIX)
        label = n.delete_prefix(CHECK_PREFIX)
        raise UsageError, "#{CHECK_PREFIX} needs a check label (#{CHECK_PREFIX}<label>, as harness-gate prints it)" if label.empty?
        raise UsageError, "#{CHECK_PREFIX}<label> cannot contain a control character: #{n.inspect}" if label.match?(/[[:cntrl:]]/)

        return new(name: n, phase: phase)
      end
      known = n == "phase" || n == NA_SHARE || TOTALS.key?(n) ||
              (n.start_with?("counter:") && COUNTERS.include?(n.delete_prefix("counter:")))
      unless known
        raise UsageError, "unknown metric #{n.inspect} (known: phase, lead, code, #{NA_SHARE}, " \
                          "counter:<#{COUNTERS.join('|')}>, #{CHECK_PREFIX}<label>)"
      end

      new(name: n, phase: phase)
    end

    def na_share? = name == NA_SHARE

    def check? = name.start_with?(CHECK_PREFIX)

    def check_label = check? ? name.delete_prefix(CHECK_PREFIX) : nil

    def tail? = phase == TAIL

    # The row's value, or nil when it is n/a there.
    def value(row)
      return measured_tail(row) if tail?

      case name
      when "phase", NA_SHARE then row.dig("phases", phase, "s")
      when "lead", "code" then row[TOTALS[name]]
      else check? ? check_wall(row) : row.dig("counters", name.delete_prefix("counter:"))
      end
    end

    # Why the row's value is n/a, or nil when it is measured. A check metric
    # has three distinct reasons; none of them is ever read as 0.
    def na_reason(row)
      return nil unless value(row).nil?
      return tail_na_reason(row) if tail?
      return check_na_reason(row) if check?

      why = case name
            when "phase", NA_SHARE then row.dig("phases", phase, "na_reason")
            when "lead", "code" then row["lead_na_reason"]
            else row.dig("counters_na", name.delete_prefix("counter:"))
            end
      why || "#{name} is null on this row"
    end

    private

    # tail_s only when a post-merge run concluded; a 0 from a landing with
    # none is not a measured tail. A row ingested before DND-1532 kept
    # tail_end still proves a run when its tail is nonzero: lead-time's tail
    # is nonzero only when its end was a deploy or pipeline (an end at the
    # merge reads 0; closed, open and unmeasured have no tail). This is
    # lead-time-phases' tail_cell rule, so a tail the summary measures is
    # one the judge compares.
    def measured_tail(row)
      s = row["tail_s"]
      return nil unless s.is_a?(Numeric)
      return s if TAIL_RUN_ENDS.include?(row["tail_end"])

      row["tail_end"].nil? && s.positive? ? s : nil
    end

    def tail_na_reason(row)
      return row["lead_na_reason"] || "tail: not measured on this row" unless row["tail_s"].is_a?(Numeric)
      if row["tail_end"].nil?
        return "tail: the row was ingested before DND-1532 kept its end kind, so its #{row['tail_s']}s cannot be " \
               "told apart from a landing whose run was never found"
      end

      "tail: no post-merge run concluded for the landing (lead-time end kind #{row['tail_end']}); " \
        "its #{row['tail_s']}s is not a measured tail"
    end

    def check_wall(row)
      walls = row["check_walls"]
      wall = walls.is_a?(Hash) ? walls[check_label] : nil
      wall.is_a?(Numeric) ? wall : nil
    end

    def check_na_reason(row)
      return "check_walls n/a: #{row['check_walls_na']}" if row["check_walls_na"]
      return "row predates check_walls" unless row.key?("check_walls")

      head = (row["gated_head"] || row["landed_commit"]).to_s[0, 8]
      walls = row["check_walls"]
      return "check #{check_label} has no numeric wall on #{head}" if walls.is_a?(Hash) && walls.key?(check_label)

      "check #{check_label} did not run on #{head}"
    end
  end

  module_function

  def terminal?(status) = TERMINAL.include?(status)

  # -> nil, or why this kind cannot take this metric.
  def kind_error(kind, metric_name)
    return "unknown kind #{kind.inspect} (known: #{KINDS.join(', ')})" unless KINDS.include?(kind)
    return "an instrumentation experiment measures #{NA_SHARE} (its phase's n/a share), not #{metric_name}" if kind == "instrumentation" && metric_name != NA_SHARE
    return "#{NA_SHARE} is the instrumentation metric; a change measures a duration" if kind == "change" && metric_name == NA_SHARE

    nil
  end

  def at(row) = LeadTimePhases::Util.time(row["landed_at"])

  # ── cross-repo (DND-1528) ──────────────────────────────────────────────

  # Where a cross-repo live_at came from: the change repo's ledger (the
  # push or merge time) or the landing commit's committer time (a fallback).
  LIVE_SOURCES = %w[ledger committer].freeze
  # The committer's clock and the forge's can disagree; a landing this much
  # before the commit was made is still looked at (git decides whether it
  # carries the commit, so the slack costs only reads).
  LIVE_SKEW_S = 3600

  # Whether the experiment's commit landed in a repo other than the one it
  # is measured on. A record written before DND-1528 has no change_repo.
  def cross_repo?(exp) = !exp["change_repo"].nil? && exp["change_repo"] != exp["repo"]

  # -> {boundary: Time, exclude: [sha]} or nil (same-repo, not ledgered yet).
  # Same-repo: the experiment's own landing row, which it excludes. Cross-repo:
  # live_at, excluding nothing (the measured repo has no landing of its own).
  def split(exp, rows)
    return { boundary: LeadTimePhases::Util.time(exp["live_at"]), exclude: [] } if cross_repo?(exp)

    landing = rows.find { |r| r["landed_commit"] == exp["commit"] }
    landing && { boundary: at(landing), exclude: [exp["commit"]] }
  end

  # The first-parent landing of `sha` on a main: [landing_sha, Time] or nil.
  # first_parent: [[sha, committer Time]] of main's first-parent line, newest
  # first. descendants: the SHAs that contain `sha` (any path). A commit on
  # the line landed as itself; a merged side commit landed with the OLDEST
  # first-parent commit that contains it (its merge). Its author date never
  # enters.
  def landing_point(first_parent, descendants, sha)
    own = first_parent.find { |c, _| c == sha }
    return own if own

    contains = descendants.to_h { |d| [d, true] }
    first_parent.select { |c, _| contains.key?(c) }.last
  end

  # The change repo's ledger rows that may be the landing that carried a
  # commit made at committed_at: from LIVE_SKEW_S before it on, oldest
  # first, one per landed commit. Which one carries it is git's answer.
  def ledger_live_candidates(rows, committed_at:)
    from = committed_at - LIVE_SKEW_S
    rows.select { |r| SHA_RE.match?(r["landed_commit"].to_s) && (t = at(r)) && t >= from }
        .sort_by { |r| [at(r), r["landed_commit"].to_s] }
        .uniq { |r| r["landed_commit"] }
  end

  # The judge/list text for a cross-repo experiment, nil for same-repo.
  def cross_text(exp)
    return nil unless cross_repo?(exp)

    out = "change_repo=#{exp['change_repo']} commit=#{exp['commit'].to_s[0, 12]} live_at=#{exp['live_at']}"
    return out unless exp["live_at_source"] == "committer"

    "#{out} (committer time: no change-repo ledger row carried it when recorded)"
  end

  # The rows a metric can compare, in landing order: the excluded landings
  # dropped, and (except for na_share, where n/a IS the measurement) every
  # row whose metric is null.
  # Rows ingested while the repo was in `watch` mode carry no phases, so
  # they are not comparable (they would read as n/a). Batch tickets sharing
  # one landed commit are one landing: the first by ticket counts.
  def comparable(rows, metric:, exclude:)
    improve_landings(rows, exclude: exclude) { |r| metric.na_share? || !metric.value(r).nil? }
  end

  # The improve-mode rows with a landing time, the excluded landings
  # dropped, those the block selects kept, in landing order, one row per
  # landed commit (the first selected by ticket).
  def improve_landings(rows, exclude: [], &keep)
    skip = exclude.map(&:to_s)
    rows.reject { |r| skip.include?(r["landed_commit"].to_s) || (r.key?("mode") && r["mode"] != "improve") }
        .select { |r| at(r) && keep.call(r) }
        .sort_by { |r| [r["landed_at"].to_s, r["ticket"].to_s] }
        .uniq { |r| r["landed_commit"] }
  end

  # -> {before: rows | nil, after: rows, before_na: reason | nil}
  # A row landed exactly at the boundary belongs to neither side.
  def sides(rows, metric:, exclude:, boundary:)
    comp = comparable(rows, metric: metric, exclude: exclude)
    before = comp.select { |r| at(r) < boundary }.last(K)
    after = comp.select { |r| at(r) > boundary }.first(K)
    if before.empty?
      why = "no before-set: #{label(metric)} has no measured landing before #{boundary.utc.iso8601} " \
            "(its telemetry began after the baseline, or the ledger holds nothing earlier)"
      latest = latest_unmeasured(rows, metric, exclude, boundary)
      why += "; the latest landing before it: #{latest}" if latest
      return { before: nil, after: after, before_na: why }
    end

    { before: before, after: after, before_na: nil }
  end

  # The n/a reason of the newest unmeasured landing before the boundary, so
  # an empty before-set names why (e.g. "row predates check_walls"); nil
  # when there is no such landing.
  def latest_unmeasured(rows, metric, exclude, boundary)
    last = improve_landings(rows, exclude: exclude) { |r| at(r) < boundary && metric.value(r).nil? }.last
    last && metric.na_reason(last)
  end

  # The landings from `from` to `to` (X.window) that the metric could not
  # compare, tallied by n/a reason, most first: [{"reason", "count"}]. They
  # are left out of both sides, and said so, never read as 0. na_share
  # excludes nothing: its n/a IS the measurement. A batch landing whose
  # commit a side kept (another ticket row measured it) is not excluded. The
  # reasons are made generic as the summary's are (the unit and SHAs
  # replaced), so one cause is one count, not one entry per landing.
  def excluded(rows, metric:, exclude:, from:, to:)
    return [] if metric.na_share?

    kept = comparable(rows, metric: metric, exclude: exclude).to_h { |r| [r["landed_commit"], true] }
    out = improve_landings(rows, exclude: exclude) do |r|
      (t = at(r)) >= from && t <= to && metric.value(r).nil? && !kept.key?(r["landed_commit"])
    end
    tally(out.map { |r| LeadTimePhases::Stats.generic(metric.na_reason(r), r) })
  end

  def tally(reasons) = reasons.tally.sort_by { |r, n| [-n, r] }.map { |r, n| { "reason" => r, "count" => n } }

  # nil, or why a change on `phase` cannot be recorded as landed in
  # change_repo while measured on repo. tail's lever is product: R's own
  # CI/CD and deploy, so a tail change lands in R itself, never as a
  # cross-repo harness change (DND-1613).
  def tail_change_repo_error(phase, repo, change_repo)
    return nil unless phase == TAIL && change_repo != repo

    "a change on tail lands in #{repo} itself (its CI/CD or deploy, lever product), not in #{change_repo}"
  end

  # The judge/record text for excluded landings, or nil when there are none.
  def excluded_text(ex)
    return nil if ex.nil? || ex.empty?

    "excluded #{ex.sum { |e| e['count'] }} landing(s) in the window, never read as 0: " +
      ex.map { |e| "#{e['reason']} (#{e['count']})" }.join("; ")
  end

  # nil when one of the last `window` landings has a measured tail, else why
  # tail cannot be judged on this repo now:
  #   {state: :could_not_look, n:}  no landing carries tail_end (all ingested
  #     before DND-1532, or none at all): a 0 cannot be told from no run
  #   {state: :unmeasured, n:, reasons: tally}  lead-time found no concluded
  #     post-merge run for any of them (a repo with no post-merge CI, or none
  #     succeeded in the window)
  def tail_error(rows, window:)
    m = Metric.parse("phase", phase: TAIL)
    last = improve_landings(rows) { true }.last(window)
    return nil if last.any? { |r| !m.value(r).nil? }
    return { state: :could_not_look, n: last.size } if last.all? { |r| r["tail_end"].nil? }

    { state: :unmeasured, n: last.size, reasons: tally(last.map { |r| m.na_reason(r) }) }
  end

  # The phase's own before/after stats over a check metric's two sides:
  # printed beside the verdict as context, never judged (DND-1548). A check
  # metric's phase median also moves with every other landing's load.
  def phase_context(before, after, phase:)
    m = Metric.parse("phase", phase: phase)
    { "before" => before && stats(before.reject { |r| m.value(r).nil? }, m),
      "after" => after && stats(after.reject { |r| m.value(r).nil? }, m) }
  end

  # nil when `label` names a check on at least one of the last `window`
  # landings that carry check_walls; else why it matches nothing:
  #   {state: :could_not_look, n: 0}  no landing carries a non-empty
  #     check_walls
  #   {state: :unknown, n:, closest: [label]}  a failed lookup, with the
  #     CLOSEST labels seen, nearest first
  def check_label_error(rows, label, window:)
    with = improve_landings(rows) { |r| r["check_walls"].is_a?(Hash) && !r["check_walls"].empty? }.last(window)
    return { state: :could_not_look, n: 0 } if with.empty?

    seen = with.flat_map { |r| r["check_walls"].keys }.uniq
    return nil if seen.include?(label)

    { state: :unknown, n: with.size, closest: closest(label, seen) }
  end

  def closest(label, labels, n = CLOSEST) = labels.sort_by { |l| [distance(label, l), l] }.first(n)

  # Levenshtein edit distance.
  def distance(a, b)
    prev = (0..b.size).to_a
    a.each_char.with_index(1) do |ca, i|
      cur = [i]
      b.each_char.with_index(1) do |cb, j|
        cur << [prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (ca == cb ? 0 : 1)].min
      end
      prev = cur
    end
    prev.last
  end

  def label(metric) = metric.name == "phase" ? "phase #{metric.phase}" : "#{metric.name} on #{metric.phase}"

  def stats(rows, metric)
    return nil if rows.nil?

    if metric.na_share?
      na = rows.count { |r| metric.value(r).nil? }
      return { "n" => rows.size, "na_share" => rows.empty? ? nil : (na.to_f / rows.size).round(3) }
    end
    vals = rows.map { |r| metric.value(r) }.compact.sort
    { "n" => vals.size, "median" => LeadTimePhases::Util.nearest_rank(vals, 0.5),
      "p90" => LeadTimePhases::Util.nearest_rank(vals, 0.9) }
  end

  # Each guard as before -> after; worse when both are measured and after > before.
  def guard_diff(before, after)
    GUARDS.to_h do |g|
      b = before&.dig(g, "value")
      a = after&.dig(g, "value")
      state = if b.nil? || a.nil? then "unmeasured"
              elsif a > b then "worse"
              else "ok"
              end
      [g, { "before" => b, "after" => a, "state" => state }]
    end
  end

  # recorded_at is validated when the record is folded (record_error).
  def expired?(exp, now) = (now - LeadTimePhases::Util.time(exp["recorded_at"])) >= PENDING_DAYS * 86_400

  def verdict(status, reason, before, after, guards, extra = {})
    { "status" => status, "reason" => reason, "before" => before, "after" => after, "guards" => guards }.merge(extra)
  end

  # pending, or inconclusive once PENDING_DAYS have passed since the record.
  def waiting(exp, now, reason, before, after, guards)
    if expired?(exp, now)
      return verdict("inconclusive", "#{reason}; still undecided #{PENDING_DAYS} days after it was recorded",
                     before, after, guards)
    end

    verdict("pending", reason, before, after, guards)
  end

  # The experiment's landing is not in the ledger yet (ingest lags the push,
  # or the recorded SHA never landed as recorded).
  def unlanded(exp, now:)
    waiting(exp, now, "landing #{exp['commit'].to_s[0, 12]} is not in the ledger yet (ingest after it lands; " \
                      "record the SHA as landed on main)", nil, nil, nil)
  end

  # exp: the folded experiment. before: rows or nil (n/a). after: rows.
  # guards_*: LeadTimePhases::Guards.compute output for each side.
  def judge(exp, before:, after:, guards_before:, guards_after:, now:)
    metric = Metric.parse(exp["metric"], phase: exp["phase"])
    b = stats(before, metric)
    a = stats(after, metric)
    if before.nil?
      return waiting(exp, now, "no before-set: #{label(metric)} was not measured before the experiment landed", nil, a, nil)
    end
    if before.size < K
      return waiting(exp, now, "before-set n=#{before.size} of K=#{K}: it can never grow (history is fixed), " \
                               "so this settles as inconclusive", b, a, nil)
    end
    return waiting(exp, now, "after-set n=#{after.size} of K=#{K}", b, a, nil) if after.size < K

    g = guard_diff(guards_before, guards_after)
    worse = g.select { |_, d| d["state"] == "worse" }
    unless worse.empty?
      why = worse.map { |name, d| "#{name} #{d['before']} -> #{d['after']}" }.join(", ")
      return verdict("revert", "guard worsened: #{why}", b, a, g)
    end

    metric.na_share? ? judge_share(exp, b, a, g, now) : judge_duration(exp, b, a, g, now)
  end

  def unmeasured(guards) = guards.select { |_, d| d["state"] == "unmeasured" }.keys

  def judge_share(exp, b, a, g, now)
    gaps = unmeasured(g)
    return waiting(exp, now, "n/a share did not fall (#{b['na_share']} -> #{a['na_share']})", b, a, g) unless a["na_share"] < b["na_share"]
    return waiting(exp, now, "n/a share fell but #{gaps.map { |x| "#{x} unmeasured" }.join(', ')}", b, a, g) unless gaps.empty?

    verdict("keep", "n/a share fell #{b['na_share']} -> #{a['na_share']}; guards not worse", b, a, g)
  end

  def judge_duration(exp, b, a, g, now)
    pct = b["median"].zero? ? nil : (((a["median"] - b["median"]).to_f / b["median"]) * 100).round(1)
    extra = { "change_pct" => pct }
    return verdict("revert", "median rose #{b['median']}s -> #{a['median']}s", b, a, g, extra) if a["median"] > b["median"]

    misses = []
    misses << "baseline median is 0s: nothing to reduce" if b["median"].zero?
    misses << "median #{b['median']}s -> #{a['median']}s is under the 10% bar" if a["median"] > b["median"] * (1 - MIN_DROP)
    misses << "p90 rose #{b['p90']}s -> #{a['p90']}s" if a["p90"] > b["p90"]
    misses.concat(unmeasured(g).map { |x| "#{x} unmeasured" })
    return waiting(exp, now, misses.join("; "), b, a, g).merge(extra) unless misses.empty?

    verdict("keep", "median #{b['median']}s -> #{a['median']}s (#{pct}%), p90 not up, guards not worse", b, a, g, extra)
  end

  # The `change` experiment that blocks a new one on its phase, or nil: one
  # still pending, or one judged `revert` whose revert has not landed.
  def blocker(experiments, phase:, kind:)
    return nil if kind == "instrumentation"

    experiments.find { |e| BLOCKING.include?(e["status"]) && e["kind"] == "change" && e["phase"] == phase }
  end

  def admit?(pending, phase:, kind:) = blocker(pending, phase: phase, kind: kind).nil?

  # nil, or why a record row cannot be judged (a hand edit, a corrupt line).
  def record_error(r)
    return "no id" unless r["id"].is_a?(String) && !r["id"].empty?
    return "repo is not a name" unless r["repo"].is_a?(String) && !r["repo"].empty?
    return "commit #{r['commit'].inspect} is not a 40-hex SHA" unless SHA_RE.match?(r["commit"].to_s)
    return "recorded_at #{r['recorded_at'].inspect} is not RFC 3339" unless LeadTimePhases::Util.time(r["recorded_at"])
    if r.key?("change_repo")
      return "change_repo #{r['change_repo'].inspect} is not a repo name" unless LeadTimeConfig::NAME_RE.match?(r["change_repo"].to_s)
      if cross_repo?(r) && !LeadTimePhases::Util.time(r["live_at"])
        return "live_at #{r['live_at'].inspect} is not RFC 3339 (a cross-repo record splits at it)"
      end
      if r.key?("live_at_source") && !LIVE_SOURCES.include?(r["live_at_source"])
        return "live_at_source #{r['live_at_source'].inspect} is not one of #{LIVE_SOURCES.join(', ')}"
      end
    end

    Metric.parse(r["metric"], phase: r["phase"])
    kind_error(r["kind"], r["metric"])
  rescue UsageError => e
    e.message
  end

  # -> {experiments:, orphans: [id], malformed: [[id, why]], bad_status: [[id, status]]}
  # Each experiment is its record plus "status" (latest wins; pending
  # without a status row) and "last" (that row). A malformed record, a
  # status row for an unknown id, and an unknown status are reported, never
  # folded in silently.
  def fold_all(rows)
    records = {}
    out = { orphans: [], malformed: [], bad_status: [] }
    rows.each do |r|
      case r["type"]
      when "record"
        why = record_error(r)
        next out[:malformed] << [r["id"].to_s, why] if why

        records[r["id"]] ||= r.merge("status" => "pending", "last" => nil)
      when "status"
        next out[:bad_status] << [r["id"].to_s, r["status"]] unless STATUSES.include?(r["status"])
        next out[:orphans] << r["id"] unless records.key?(r["id"])

        records[r["id"]] = records[r["id"]].merge("status" => r["status"], "last" => r)
      end
    end
    out.transform_values!(&:uniq)
    out.merge(experiments: records.values)
  end

  def fold(rows) = fold_all(rows)[:experiments]

  # The SHAs a commit body says it reverts (git revert's own line).
  def revert_refs(body) = body.to_s.scan(REVERT_RE).flatten.uniq

  COMPARED = %w[status reason before after guards].freeze

  # Whether a verdict differs from the experiment's last status row, so a
  # re-judge with the same inputs appends nothing.
  def changed?(last, verdict)
    return true if last.nil?

    COMPARED.any? { |k| last[k] != verdict[k] }
  end

  def status_row(exp, verdict, now)
    unless JUDGED.include?(verdict["status"])
      raise UsageError, "judge cannot write status #{verdict['status'].inspect} (judged: #{JUDGED.join(', ')}); " \
                        "only the decline verb writes declined"
    end

    { "type" => "status", "schema" => SCHEMA, "id" => exp["id"], "judged_at" => now.utc.iso8601 }.merge(verdict)
  end

  # nil when the experiment's revert may be declined, else [why, fix].
  # Only a revert verdict qualifies, and only one no guard drove: a worse
  # critic BLOCK rate, gate red rate or revert count is a quality signal, so
  # it is never declined. A revert row with no guards cannot show it was
  # median-only, so it is refused too.
  def decline_error(exp)
    judge_fix = "decline applies only to an experiment judged revert; experiment list shows each status"
    case exp["status"]
    when "revert" then nil
    when "pending" then return ["#{exp['id']} is pending: not judged yet", judge_fix]
    when "declined" then return ["#{exp['id']} is already declined", "nothing to do; experiment list shows it"]
    else return ["#{exp['id']} is #{exp['status']}, not an owed revert", judge_fix]
    end

    guards = exp.dig("last", "guards")
    unless guards.is_a?(Hash) && !guards.empty?
      return ["#{exp['id']}'s revert verdict carries no guards, so it cannot show it was median-only",
              "land the revert, or re-judge it; decline covers only a median-only revert"]
    end

    worse = guards.select { |_, d| d.is_a?(Hash) && d["state"] == "worse" }.keys
    unless worse.empty?
      names = worse.join(", ")
      return ["#{exp['id']}'s revert verdict came from a worse guard: #{names}",
              "a guard worsened (#{names}): land the revert, or a fix-forward ticketed by an architect; " \
              "decline does not cover a quality regression"]
    end

    # A guard that could not be measured may hide a regression, the same
    # reason keep waits on one: only an all-ok revert is median-only.
    unsure = guards.reject { |_, d| d.is_a?(Hash) && d["state"] == "ok" }.keys
    return nil if unsure.empty?

    ["#{exp['id']}'s revert verdict has guard(s) not measured ok: #{unsure.join(', ')}",
     "re-judge once #{unsure.join(', ')} can be measured, or land the revert; " \
     "decline covers only a revert whose guards are all measured and not worse"]
  end

  # nil, or why a decline constraint is not one of CONSTRAINTS.
  def constraint_error(constraint)
    return nil if CONSTRAINTS.include?(constraint)

    "unknown constraint #{constraint.inspect} (known: #{CONSTRAINTS.join(', ')})"
  end

  # The status row the decline verb appends: the revert row's numbers and
  # reason kept beside the constraint and why it was declined.
  def decline_row(exp, constraint:, reason:, now:)
    why = constraint_error(constraint)
    raise UsageError, why if why

    last = exp["last"] || {}
    { "type" => "status", "schema" => SCHEMA, "id" => exp["id"], "status" => "declined", "constraint" => constraint,
      "reason" => reason, "declined_at" => now.utc.iso8601, "prior_reason" => last["reason"],
      "before" => last["before"], "after" => last["after"], "guards" => last["guards"] }
  end

  def id_for(repo, phase, commit) = "#{repo}:#{phase}:#{commit.to_s[0, 12]}"

  # ── revert held (DND-1549) ──────────────────────────────────────────────
  # A plain `git revert` of a commit that added test lines deletes them: the
  # weakening ai/blocks/ops/safety-checks.md forbids. HELD is presentation
  # plus a `held` field on the status row. The verdict stays `revert`;
  # nothing becomes keep and no bar moves.

  # The test paths a commit added lines to, from its numstat entries
  # [[added | nil, deleted | nil, path]] (nil: a binary file, whose change
  # git does not count in lines: held, since unknown fails closed). The
  # test-path rule is FirstParty.test_path?, the guard classification's own.
  def test_additions(entries)
    entries.select { |added, _, path| FirstParty.test_path?(path) && (added.nil? || added.positive?) }
           .map(&:last).uniq.sort
  end

  # The record fields for a numstat Source: the test paths (possibly []), or
  # `_na` with the reason when git could not answer. Never [] for unknown.
  def deletes_tests_fields(src)
    return { "revert_deletes_tests_na" => src.reason } if src.could_not_look?

    { "revert_deletes_tests" => test_additions(src.items) }
  end

  # nil, or why a revert verdict is held: {"tests" => paths} or
  # {"could_not_look" => reason}. `fields` carries revert_deletes_tests or
  # revert_deletes_tests_na; neither (or a non-list) is could not look.
  def hold(status, fields)
    return nil unless status == "revert"

    na = fields["revert_deletes_tests_na"]
    return { "could_not_look" => na.to_s } if na

    tests = fields["revert_deletes_tests"]
    return { "could_not_look" => "the record carries no revert_deletes_tests list" } unless tests.is_a?(Array)

    tests.empty? ? nil : { "tests" => tests }
  end

  # The HELD line's explanation and Fix. decline_refusal: nil when the
  # decline verb would admit this revert, else why it would refuse it.
  # change_repo: the repo the commit landed in when it is not `repo`
  # (DND-1528); the revert lands there.
  # route: revert_route's text for a product revert (DND-1613), else nil.
  def hold_text(repo, id, commit, hold, decline_refusal, change_repo: nil, trailer: nil, route: nil)
    sha = commit.to_s[0, 12]
    where = change_repo ? "in #{change_repo}: " : ""
    landed = route ? ", landed #{route}" : ""
    keep_trailer = trailer ? " and the trailer line `#{trailer}` (DND-1529)" : ""
    what = if hold["could_not_look"]
             "could not look whether reverting #{sha} deletes test additions: #{hold['could_not_look']}"
           else
             "reverting #{sha} deletes test additions in #{hold['tests'].join(', ')}"
           end
    # Judge records `reverted` only from git's own "This reverts commit
    # <sha>" line (reverted?), so a partial revert must keep it.
    partial = "land a partial revert that keeps every test addition and its fixture fix " \
              "(#{where}git revert --no-commit #{commit}, restore the test paths, commit keeping git's " \
              "\"This reverts commit #{commit}.\" line so judge records reverted#{keep_trailer}#{landed})"
    fix = if decline_refusal
            "#{partial}; decline does not cover this revert (#{decline_refusal})"
          else
            "#{partial}, or run experiment decline --repo #{repo} --id #{id} --constraint safety-checks --reason-file <F>"
          end
    "#{what}; the hard constraint rules out a plain git revert. Fix: #{fix}"
  end

  # How a revert lands when it is not the harness's own (DND-1613): a
  # product change is reverted by a PR in the repo it landed in, through
  # that repo's own bar (the product lane, DND-1540). A product change is
  # one on a product-lever phase (tail), or one whose commit landed in a
  # repo other than the harness repo (DND-1542: an improve repo changing
  # itself). nil for a harness change, whose revert lands through the
  # skill's *Landing*. harness: the harness repo's name, or nil when it could
  # not be found (then only the phase can say product).
  def revert_route(exp, harness:)
    landed_in = exp["change_repo"] || exp["repo"]
    product = LeadTimePhases::Stats::LEVERS[exp["phase"]] == "product" || (!harness.nil? && landed_in != harness)
    return nil unless product

    "as a revert PR in #{landed_in} through its own bar (the product lane, DND-1540)"
  end

  # ── the experiment trailer and confounds (DND-1529) ──────────────────────

  T = LeadTimeTrailer

  # nil when the commit message carries the trailer this record needs, else
  # [what, fix]. The trailer must name the record's repo, phase and metric,
  # so judge on another machine reads the phase this record is judged on.
  def trailer_error(message, sha:, repo:, phase:, metric:)
    want = "#{T::KEY}: #{repo} #{phase} #{metric}"
    s = T.scan(message)
    return nil if s[:trailers].any? { |t| t.repo == repo && t.phase == phase && t.metric == metric }

    fix = "every improver change and revert lands with the trailer line `#{want}` (format: #{T::FORMAT}). " \
          "A landed commit without it cannot be recorded: journal it as unrecorded, and land the next change with the trailer"
    bad = s[:malformed].map { |v, why| "#{v.inspect} (#{why})" }
    if s[:trailers].empty?
      extra = bad.empty? ? "" : "; malformed trailer line(s): #{bad.join(', ')}"
      return ["#{sha.to_s[0, 12]} carries no #{T::KEY} trailer#{extra}", fix]
    end

    ["#{sha.to_s[0, 12]}'s #{T::KEY} trailer(s) name #{s[:trailers].map(&:to_s).join('; ')}, not #{repo} #{phase} #{metric}",
     "record with the repo, phase and metric its trailer names; #{fix}"]
  end

  # The confound window: from the before-set's first landing (the boundary
  # when there is no before-set) to the after-set's last (the boundary while
  # there is no after landing yet). A confounder inside it stays inside as
  # the after-set grows, so a pending verdict can be confounded now.
  def window(sides, boundary)
    before = sides[:before]
    after = sides[:after]
    [before.nil? || before.empty? ? boundary : at(before.first), after.empty? ? boundary : at(after.last)]
  end

  # commits: [[sha, committer Time, message]] from the harness repo's main
  # (and the measured repo's, when it is another). -> {confounders: [...],
  # malformed: [[sha, value, why]]}. A confounder is a commit inside the
  # window, other than the experiment's own and a revert of it, whose
  # trailer names the experiment's phase (any measured repo: one harness
  # serves every repo). A malformed trailer names no phase, so it is never a
  # confounder; it is returned so the caller can say so.
  # It carries the blocker rule's exemption: instrumentation does not move a
  # duration, so an instrumentation trailer (metric na_share, which
  # kind_error ties to instrumentation) confounds nothing, and an
  # instrumentation experiment is never confounded. Unlike the blocker,
  # which only refuses overlapping PENDING changes, the window reaches back
  # over the whole before-set: a settled predecessor's change, or its revert,
  # that landed inside it confounds too (its baseline straddles that change).
  def confounders(exp, commits, from:, to:)
    return { confounders: [], malformed: [] } if exp["kind"] == "instrumentation"

    own = exp["commit"]
    inside = commits.select { |_, t, _| t >= from && t <= to }
                    .reject { |sha, _, msg| sha == own || revert_refs(msg).include?(own) }
    out = { confounders: [], malformed: [] }
    inside.each do |sha, t, msg|
      s = T.scan(msg)
      s[:malformed].each { |v, why| out[:malformed] << [sha, v, why] }
      hit = s[:trailers].find { |tr| tr.phase == exp["phase"] && tr.metric != NA_SHARE }
      out[:confounders] << { "commit" => sha, "at" => t.utc.iso8601 }.merge(hit.to_h) if hit
    end
    out[:confounders] = out[:confounders].uniq { |c| c["commit"] }.sort_by { |c| [c["at"], c["commit"]] }
    out
  end

  def confounder_text(c) = "#{c['commit'].to_s[0, 12]} (#{c['repo']} #{c['phase']} #{c['metric']}, #{c['at']})"

  # The verdict once confounders are known: unchanged when there are none,
  # else `confounded`, naming each other commit and what the verdict would
  # have been. Never keep, never revert.
  def confound(v, confounders, phase:)
    return v if confounders.empty?

    reason = "another experiment's change on #{phase} landed inside the window: " \
             "#{confounders.map { |c| confounder_text(c) }.join(', ')}; treated as inconclusive " \
             "(unconfounded it read #{v['status']}: #{v['reason']})"
    v.merge("status" => "confounded", "reason" => reason, "confounders" => confounders)
  end
end
