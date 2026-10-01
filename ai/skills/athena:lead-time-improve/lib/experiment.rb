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
#     judge records `reverted`.
#   * only `improve`-mode rows count, one row per landing (batch tickets
#     sharing a landed commit are one landing).
#
# The store (experiments.jsonl) is rows of two types, latest status wins:
#   {"type":"record", "id", "repo", "phase", "metric", "kind", "commit", ...}
#   {"type":"status", "id", "status", "reason", "before", "after", "guards", ...}

require "time"
require_relative "../../../lib/lead_time_phases"

module LeadTimeExperiment
  SCHEMA = 1
  K = 10
  MIN_DROP = 0.10
  PENDING_DAYS = 7
  KINDS = %w[change instrumentation].freeze
  STATUSES = %w[pending keep revert inconclusive reverted].freeze
  # A revert verdict is settled as a judgement but OWED as an action until
  # the revert lands, so it is not terminal.
  TERMINAL = %w[keep inconclusive reverted].freeze
  BLOCKING = %w[pending revert].freeze
  SHA_RE = /\A[0-9a-f]{40}\z/.freeze
  REVERT_RE = /This reverts commit ([0-9a-f]{40})/.freeze
  PHASES = LeadTimePhases::PHASES
  TOTALS = { "lead" => "lead_s", "code" => "code_s" }.freeze
  COUNTERS = %w[gate_runs gate_wall_s gate_red slot_wait_s critic_rounds critic_blocks critic_wall_s lock_wait_s].freeze
  GUARDS = %w[critic_block_rate gate_red_rate reverts].freeze
  NA_SHARE = "na_share"

  class UsageError < StandardError; end

  # What one experiment measures on a ledger row.
  #   phase              the experiment's phase duration (phases.<phase>.s)
  #   lead | code        the landing's total (lead_s / code_s)
  #   counter:<name>     a ledger counter (counters.<name>)
  #   na_share           instrumentation: whether the phase is n/a at all
  Metric = Struct.new(:name, :phase, keyword_init: true) do
    def self.parse(name, phase:)
      raise UsageError, "unknown phase #{phase.inspect} (known: #{PHASES.join(', ')})" unless PHASES.include?(phase)

      n = name.to_s
      known = n == "phase" || n == NA_SHARE || TOTALS.key?(n) ||
              (n.start_with?("counter:") && COUNTERS.include?(n.delete_prefix("counter:")))
      unless known
        raise UsageError, "unknown metric #{n.inspect} (known: phase, lead, code, #{NA_SHARE}, " \
                          "counter:<#{COUNTERS.join('|')}>)"
      end

      new(name: n, phase: phase)
    end

    def na_share? = name == NA_SHARE

    # The row's value, or nil when it is n/a there.
    def value(row)
      case name
      when "phase", NA_SHARE then row.dig("phases", phase, "s")
      when "lead", "code" then row[TOTALS[name]]
      else row.dig("counters", name.delete_prefix("counter:"))
      end
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

  # The rows a metric can compare, in landing order: the excluded landings
  # dropped, and (except for na_share, where n/a IS the measurement) every
  # row whose metric is null.
  # Rows ingested while the repo was in `watch` mode carry no phases, so
  # they are not comparable (they would read as n/a). Batch tickets sharing
  # one landed commit are one landing: the first by ticket counts.
  def comparable(rows, metric:, exclude:)
    skip = exclude.map(&:to_s)
    rows.reject { |r| skip.include?(r["landed_commit"].to_s) || (r.key?("mode") && r["mode"] != "improve") }
        .select { |r| at(r) && (metric.na_share? || !metric.value(r).nil?) }
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
      return { before: nil, after: after, before_na: why }
    end

    { before: before, after: after, before_na: nil }
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
    { "type" => "status", "schema" => SCHEMA, "id" => exp["id"], "judged_at" => now.utc.iso8601 }.merge(verdict)
  end

  def id_for(repo, phase, commit) = "#{repo}:#{phase}:#{commit.to_s[0, 12]}"
end
