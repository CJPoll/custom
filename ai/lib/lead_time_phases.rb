# frozen_string_literal: true

# lead_time_phases -- the DOMAIN of ai/bin/lead-time-phases (DND-1477). Pure:
# no file, process, network or clock access. Every input arrives as a value.
#
# A landing (one row of `ai/bin/lead-time --since --json`, DND-1009) splits
# into five phases between six anchors (ai/docs/lead-time-improver.md ->
# Decision 5):
#
#   dispatch --implement--> gate_first --verify--> critic_pass --queue-->
#   integrate_start --integrate--> integrate_end --merge--> landed
#
# Each phase is whole seconds, or null with `na_reason` when an anchor is
# missing, or null with `invalid: true` when its anchors are out of order.
# Never 0 for a missing input, never negative. Anchors are floored to whole
# seconds BEFORE subtraction, so the five phases telescope: their sum equals
# landed - dispatch exactly.
#
# A source the IO side read is a Source: status :ok (found), :empty (looked,
# nothing for this key) or :could_not_look (with a reason). "could not look"
# becomes the na_reason text, so a missing source never reads as zero.

require "json"
require "time"

module LeadTimePhases
  SCHEMA = 1
  PHASES = %w[implement verify queue integrate merge].freeze
  ANCHORS = %w[dispatch gate_first critic_pass integrate_start integrate_end landed].freeze
  # phase -> [start anchor, end anchor]
  PHASE_ANCHORS = {
    "implement" => %w[dispatch gate_first],
    "verify" => %w[gate_first critic_pass],
    "queue" => %w[critic_pass integrate_start],
    "integrate" => %w[integrate_start integrate_end],
    "merge" => %w[integrate_end landed],
  }.freeze
  MODES = %w[improve watch].freeze
  TOTALS = { "lead" => "lead_s", "code" => "code_s", "tail" => "tail_s" }.freeze
  # The telemetry events a phase or counter reads. telemetry.probe is never an
  # anchor (ai/telemetry/events.json).
  EVENTS = %w[harness_gate.run harness_gate.check test_slot.wait critic.round
              integration_gate.run merge.lock_wait merge.landed].freeze
  TOP_CHECKS = 5

  class ConfigError < StandardError; end

  # status: :ok | :empty | :could_not_look. items: what was found (a partial
  # read may carry items AND :could_not_look). reason: why, for a miss.
  Source = Struct.new(:status, :items, :reason, keyword_init: true) do
    def self.ok(items) = new(status: :ok, items: items, reason: nil)
    def self.empty(reason) = new(status: :empty, items: [], reason: reason)
    def self.could_not_look(reason, items = []) = new(status: :could_not_look, items: items, reason: reason)

    def could_not_look? = status == :could_not_look
  end

  module Util
    module_function

    def time(value)
      return nil if value.nil? || value.to_s.empty?

      Time.iso8601(value.to_s).utc
    rescue ArgumentError
      nil
    end

    def floor(time) = time && Time.at(time.to_i).utc
    def iso(time) = time&.utc&.iso8601
    def short(sha) = sha.to_s[0, 8]

    # nearest-rank percentile over an ascending list; nil when empty
    def nearest_rank(sorted, pct)
      return nil if sorted.empty?

      sorted[[(pct * sorted.size).ceil - 1, 0].max]
    end

    def human(seconds)
      return "n/a" if seconds.nil?
      return "0s" if seconds.zero?

      s = seconds.round
      parts = [[s / 86_400, "d"], [(s % 86_400) / 3600, "h"], [(s % 3600) / 60, "m"], [s % 60, "s"]]
      parts.reject { |n, _| n.zero? }.first(2).map { |n, u| "#{n}#{u}" }.join(" ")
    end
  end

  # ai/config/lead-time-repos.json
  module Config
    Repo = Struct.new(:name, :path, :mode, keyword_init: true)
    Parsed = Struct.new(:repos, :window, :improvement_epic, keyword_init: true)
    TOP_KEYS = %w[repos window improvement_epic].freeze
    REPO_KEYS = %w[name path mode].freeze
    NAME_RE = /\A[A-Za-z0-9][A-Za-z0-9_.-]*\z/.freeze

    module_function

    # -> Parsed, or raises ConfigError naming what is wrong.
    def parse(text, home:)
      doc = JSON.parse(text)
      raise ConfigError, "the config is not a JSON object" unless doc.is_a?(Hash)

      keys!(doc, TOP_KEYS, "the config")
      window = doc["window"]
      raise ConfigError, "window must be a positive integer, got #{window.inspect}" unless window.is_a?(Integer) && window.positive?

      epic = doc["improvement_epic"]
      raise ConfigError, "improvement_epic must be a non-empty string" unless epic.is_a?(String) && !epic.strip.empty?

      repos = doc["repos"]
      raise ConfigError, "repos must be a non-empty list" unless repos.is_a?(Array) && !repos.empty?

      parsed = repos.each_with_index.map { |r, i| repo(r, i, home) }
      dup = parsed.map(&:name).tally.find { |_, n| n > 1 }
      raise ConfigError, "repo #{dup[0].inspect} is listed #{dup[1]} times" if dup

      Parsed.new(repos: parsed, window: window, improvement_epic: epic)
    rescue JSON::ParserError => e
      raise ConfigError, "the config is not valid JSON (#{e.message.lines.first.to_s.strip})"
    end

    def repo(entry, index, home)
      raise ConfigError, "repos[#{index}] is not an object" unless entry.is_a?(Hash)

      name = entry["name"]
      keys!(entry, REPO_KEYS, "repos[#{index}] (#{name.inspect})")
      raise ConfigError, "repos[#{index}] name #{name.inspect} is not a plain name" unless name.is_a?(String) && NAME_RE.match?(name)

      mode = entry["mode"]
      raise ConfigError, "repo #{name.inspect} has unknown mode #{mode.inspect} (known: #{MODES.join(', ')})" unless MODES.include?(mode)

      Repo.new(name: name, path: expand(entry["path"], name, home), mode: mode)
    end

    def keys!(hash, wanted, what)
      missing = wanted - hash.keys
      extra = hash.keys - wanted
      raise ConfigError, "#{what} is missing #{missing.join(', ')}" unless missing.empty?
      raise ConfigError, "#{what} has unknown key(s) #{extra.join(', ')}" unless extra.empty?
    end

    def expand(path, name, home)
      p = path.to_s
      p = File.join(home, p[2..]) if p.start_with?("~/")
      raise ConfigError, "repo #{name.inspect} path #{path.inspect} is not absolute or ~/-relative" unless p.start_with?("/")

      p
    end

    # -> the Repo, or raises ConfigError naming the configured repos.
    def find(parsed, name)
      parsed.repos.find { |r| r.name == name } or
        raise ConfigError, "no repo #{name.inspect} in the config (configured: #{parsed.repos.map(&:name).join(', ')})"
    end
  end

  # One lead-time JSON row (string keys), normalised.
  module Landing
    module_function

    # -> [landing Hash, nil] or [nil, reason]. ticket is resolved by the caller
    # (a push row carries one; a PR row's comes from its branch or title).
    def from_row(row, ticket:)
      commit = row["landed_commit"] || row["merge_commit"]
      landed = Util.time(row["merged"])
      return [nil, "no landed commit (#{row['pr'] ? "PR ##{row['pr']}" : 'a push'})"] if commit.to_s.empty?
      return [nil, "no landing time for #{Util.short(commit)}"] unless landed

      start = Util.time(row["start"])
      [{ "ticket" => ticket, "landed_commit" => commit, "landed_at" => landed,
         "landed_via" => row["landed_via"], "pr" => row["pr"], "start" => start,
         "start_na" => start ? nil : row["unmeasured_reason"],
         "lead_s" => row["lead_seconds"], "code_s" => row["code_seconds"], "tail_s" => row["tail_seconds"],
         "lead_na_reason" => row["unmeasured_reason"] }, nil]
    end

    def unit_desc(landing) = landing["ticket"] || "head #{Util.short(landing['landed_commit'])}"
  end

  # Which telemetry events belong to a landing: by unit for a ticketed one,
  # by head for an unticketed one (P5), at or before the landing.
  module Match
    module_function

    def at(event) = Util.time(event["at"])

    def before_landing(events, landing)
      events.select { |e| (t = at(e)) && t <= landing["landed_at"] }
    end

    def for_unit(events, landing, name)
      key = landing["ticket"]
      before_landing(events, landing).select do |e|
        e["event"] == name && (key ? e["unit"] == key : e["head"] == landing["landed_commit"])
      end
    end

    def for_head(events, landing, name)
      before_landing(events, landing).select { |e| e["event"] == name && e["head"] == landing["landed_commit"] }
    end

    def end_of(event)
      t = at(event)
      d = event["duration_s"]
      d.is_a?(Numeric) ? t + d : t
    end

    def attr(event, key) = (event["attrs"] || {})[key]
  end

  module Anchors
    Anchor = Struct.new(:at, :source, :reason, keyword_init: true) do
      def to_h_json = { "at" => Util.iso(at), "source" => source, "reason" => reason }.compact
    end

    module_function

    def found(time, source) = Anchor.new(at: Util.floor(time), source: source)
    def missing(reason) = Anchor.new(at: nil, reason: reason)

    # events/receipt/verdicts are Sources. -> {anchor name => Anchor}
    def from(landing:, events:, receipt:, verdicts:)
      integ = integrate(landing, events, receipt)
      {
        "dispatch" => dispatch(landing),
        "gate_first" => gate_first(landing, events),
        "critic_pass" => critic_pass(landing, events, verdicts, integ[0].at),
        "integrate_start" => integ[0],
        "integrate_end" => integ[1],
        "landed" => found(landing["landed_at"], "lead-time"),
      }
    end

    def dispatch(landing)
      return found(landing["start"], "dispatch stamp") if landing["start"]
      return missing("unticketed landing: no dispatch stamp") unless landing["ticket"]

      missing("dispatch stamp: #{landing['start_na'] || "no stamp for #{landing['ticket']}"}")
    end

    def telemetry_miss(events, what)
      events.could_not_look? ? "telemetry: could not look (#{events.reason})" : what
    end

    def gate_first(landing, events)
      return missing("unticketed landing: no unit to join gate runs on") unless landing["ticket"]

      runs = Match.for_unit(events.items, landing, "harness_gate.run")
      return missing(telemetry_miss(events, "no harness_gate.run for #{landing['ticket']}")) if runs.empty?

      found(runs.map { |e| Match.at(e) }.min, "telemetry harness_gate.run")
    end

    # The last critic PASS before the integration run started (or, with no
    # integration start, before the landing). Telemetry critic.round for the
    # unit and the head's verdict receipts are both candidates.
    def critic_pass(landing, events, verdicts, integrate_start)
      cands = Match.for_unit(events.items, landing, "critic.round")
                   .select { |e| Match.attr(e, "verdict").to_s.downcase == "pass" }
                   .map { |e| [Match.end_of(e), "telemetry critic.round"] }
      cands += verdicts.items.select { |v| v["verdict"].to_s.downcase == "pass" }
                       .filter_map { |v| (t = Util.time(v["at"])) && [t, "critic verdict receipt"] }
      cands.select! { |t, _| t <= landing["landed_at"] }
      return missing(critic_miss(landing, events, verdicts)) if cands.empty?

      if integrate_start
        before = cands.select { |t, _| Util.floor(t) <= integrate_start }
        if before.empty?
          return missing("every critic PASS for #{Landing.unit_desc(landing)} ended after integration-gate " \
                         "started (a --with-critic round); none stood before it")
        end
        cands = before
      end
      t, src = cands.max_by(&:first)
      found(t, src)
    end

    def critic_miss(landing, events, verdicts)
      looked = []
      looked << "telemetry: could not look (#{events.reason})" if events.could_not_look?
      looked << "critic verdicts: could not look (#{verdicts.reason})" if verdicts.could_not_look?
      return looked.join("; ") unless looked.empty?

      "no critic PASS for #{Landing.unit_desc(landing)} (no critic.round, no verdict receipt on " \
        "#{Util.short(landing['landed_commit'])})"
    end

    # -> [start Anchor, end Anchor]: the last successful integration_gate.run
    # on the landed head, else the receipt's recorded_at as the end only.
    def integrate(landing, events, receipt)
      runs = Match.for_head(events.items, landing, "integration_gate.run")
                  .select { |e| Match.attr(e, "exit_code") == 0 }
      run = runs.max_by { |e| Match.at(e) }
      sha = Util.short(landing["landed_commit"])
      rec = receipt.items.first && Util.time(receipt.items.first["recorded_at"])
      if run
        start = found(Match.at(run), "telemetry integration_gate.run")
        return [start, found(Match.end_of(run), "telemetry integration_gate.run")] if run["duration_s"].is_a?(Numeric)
        return [start, found(rec, "integration receipt")] if rec

        return [start, missing("integration_gate.run on #{sha} has no duration and no receipt")]
      end
      no_run = telemetry_miss(events, "no integration_gate.run on #{sha}")
      return [missing("#{no_run} (the receipt gives the end only)"), found(rec, "integration receipt")] if rec

      rec_why = receipt.could_not_look? ? "receipt: could not look (#{receipt.reason})" : "no integration receipt for #{sha}"
      [missing(no_run), missing("#{no_run}; #{rec_why}")]
    end
  end

  module Phases
    module_function

    # anchors: {name => Anchor} -> {phase => {"s"=>Integer|nil, "na_reason"=>.., "invalid"=>true}}
    def compute(anchors)
      PHASE_ANCHORS.to_h do |phase, (from, to)|
        a = anchors.fetch(from)
        b = anchors.fetch(to)
        [phase, value(a, b, from, to)]
      end
    end

    def value(a, b, from, to)
      return { "s" => nil, "na_reason" => a.reason } unless a.at
      return { "s" => nil, "na_reason" => b.reason } unless b.at

      if b.at < a.at
        return { "s" => nil, "invalid" => true,
                 "na_reason" => "invalid: #{to} (#{Util.iso(b.at)}) is before #{from} (#{Util.iso(a.at)})" }
      end
      { "s" => (b.at - a.at).to_i }
    end
  end

  module Counters
    module_function

    # -> {"counters"=>{..}, "counters_na"=>{name=>reason}, "top_checks"=>[..]|nil,
    #     "top_checks_source"=>.., "top_checks_na"=>..}
    def compute(landing:, events:, timings:)
      out = {}
      na = {}
      family(landing, events, "harness_gate.run", %w[gate_runs gate_wall_s gate_red], out, na) do |evs|
        [evs.size, wall(evs), evs.count { |e| Match.attr(e, "ok") == false }]
      end
      family(landing, events, "test_slot.wait", %w[slot_wait_s], out, na) { |evs| [wall(evs)] }
      family(landing, events, "critic.round", %w[critic_rounds critic_blocks critic_wall_s], out, na) do |evs|
        [evs.size, evs.count { |e| Match.attr(e, "verdict").to_s.downcase == "block" }, wall(evs)]
      end
      family(landing, events, "merge.lock_wait", %w[lock_wait_s], out, na) { |evs| [wall(evs)] }
      top = top_checks(landing, events, timings)
      { "counters" => out, "counters_na" => na }.merge(top)
    end

    def wall(evs) = evs.sum { |e| e["duration_s"].is_a?(Numeric) ? e["duration_s"] : 0 }.round(3)

    def family(landing, events, name, keys, out, na)
      evs = Match.for_unit(events.items, landing, name)
      if evs.empty?
        why = Anchors.telemetry_miss(events, "no #{name} for #{Landing.unit_desc(landing)}")
        keys.each { |k| out[k] = nil; na[k] = why }
      else
        keys.zip(yield(evs)).each { |k, v| out[k] = v }
      end
    end

    def top_checks(landing, events, timings)
      checks = Match.for_head(events.items, landing, "harness_gate.check")
      unless checks.empty?
        runs = checks.group_by { |e| Match.attr(e, "run_id").to_s }
        last = runs.values.max_by { |evs| evs.map { |e| Match.at(e) }.max }
        list = last.map { |e| { "label" => Match.attr(e, "label"), "wall_s" => e["duration_s"] } }
        return { "top_checks" => top(list), "top_checks_source" => "telemetry harness_gate.check" }
      end
      rows = timings.items
      unless rows.empty?
        latest = rows.group_by { |r| r["label"] }.map { |_, rs| rs.max_by { |r| r["at"].to_s } }
        list = latest.map { |r| { "label" => r["label"], "wall_s" => r["wall_s"] } }
        return { "top_checks" => top(list), "top_checks_source" => "harness-gate timings.jsonl" }
      end
      sha = Util.short(landing["landed_commit"])
      tel = Anchors.telemetry_miss(events, "no harness_gate.check on #{sha}")
      tim = timings.could_not_look? ? "timings: could not look (#{timings.reason})" : "no timings rows for #{sha}"
      { "top_checks" => nil, "top_checks_na" => "#{tel}; #{tim}" }
    end

    def top(list)
      list.select { |c| c["wall_s"].is_a?(Numeric) }.sort_by { |c| [-c["wall_s"], c["label"].to_s] }.first(TOP_CHECKS)
    end
  end

  module Ledger
    module_function

    def key(row) = [row["repo"], row["landed_commit"], row["ticket"]]

    def base(repo:, mode:, landing:, ingested_at:)
      { "schema" => SCHEMA, "repo" => repo, "mode" => mode, "ticket" => landing["ticket"],
        "landed_commit" => landing["landed_commit"], "landed_at" => Util.iso(landing["landed_at"]),
        "landed_via" => landing["landed_via"], "pr" => landing["pr"], "start" => Util.iso(landing["start"]),
        "lead_s" => landing["lead_s"], "code_s" => landing["code_s"], "tail_s" => landing["tail_s"],
        "lead_na_reason" => landing["lead_na_reason"], "ingested_at" => Util.iso(ingested_at) }
    end

    def improve_row(repo:, landing:, anchors:, counters:, telemetry_status:, ingested_at:)
      base(repo: repo, mode: "improve", landing: landing, ingested_at: ingested_at)
        .merge("phases" => Phases.compute(anchors),
               "anchors" => anchors.transform_values(&:to_h_json),
               "telemetry" => telemetry_status.to_s)
        .merge(counters)
    end

    def watch_row(repo:, landing:, ingested_at:)
      why = "watch mode: phases are not measured for #{repo}"
      base(repo: repo, mode: "watch", landing: landing, ingested_at: ingested_at)
        .merge("phases" => PHASES.to_h { |p| [p, { "s" => nil, "na_reason" => why }] })
    end

    # rows not yet in `existing` (by key), each new key once.
    def fresh(rows, existing)
      seen = existing.to_h { |r| [key(r), true] }
      rows.each_with_object([]) do |r, out|
        next if seen[key(r)]

        seen[key(r)] = true
        out << r
      end
    end
  end

  # Tickets sharing a start and a landing are ONE batch Mission (the
  # shipwright's rule): counted once.
  module Batch
    module_function

    # -> [kept rows, folded count]
    def dedupe(rows)
      seen = {}
      kept = rows.each_with_object([]) do |r, out|
        k = r["start"] && [r["start"], r["landed_commit"]]
        next if k && seen[k]

        seen[k] = true if k
        out << r
      end
      [kept, rows.size - kept.size]
    end
  end

  module Window
    module_function

    def select(rows, n)
      rows.sort_by { |r| [r["landed_at"].to_s, r["ticket"].to_s] }.last(n)
    end
  end

  module Stats
    TOP_REASONS = 3

    module_function

    # A reason with its row's own ticket and landed commit masked, so one
    # cause on many landings groups as one reason.
    def generic(reason, row)
      out = reason.to_s
      out = out.gsub(row["ticket"], "<unit>") if row["ticket"].is_a?(String) && !row["ticket"].empty?
      sha = row["landed_commit"].to_s
      out = out.gsub(sha, "<sha>").gsub(sha[0, 8], "<sha>") if sha.size >= 8
      out
    end

    # One series of values (nil = n/a) with their reasons.
    def series(values, reasons)
      vals = values.compact.sort
      na = reasons.compact
      grouped = na.tally
                  .sort_by { |r, n| [-n, r] }.first(TOP_REASONS).map { |r, n| { "reason" => r, "count" => n } }
      { "n" => vals.size, "n_na" => values.size - vals.size, "na_reasons" => grouped,
        "median" => Util.nearest_rank(vals, 0.5), "p90" => Util.nearest_rank(vals, 0.9),
        "sum_s" => vals.empty? ? nil : vals.sum }
    end

    def phases(rows)
      PHASES.to_h do |p|
        cells = rows.map { |r| r.dig("phases", p) || { "s" => nil, "na_reason" => "no #{p} in the ledger row" } }
        reasons = rows.zip(cells).map { |r, c| c["s"].nil? ? generic(c["na_reason"], r) : nil }
        [p, series(cells.map { |c| c["s"] }, reasons)]
      end
    end

    def totals(rows)
      TOTALS.to_h do |name, key|
        reasons = rows.map { |r| r[key].nil? ? generic(r["lead_na_reason"] || "#{name}: not measured", r) : nil }
        [name, series(rows.map { |r| r[key] }, reasons)]
      end
    end

    # The phase with the largest sum; ties go to the earlier phase.
    def biggest(phase_stats)
      best = nil
      PHASES.each do |p|
        s = phase_stats[p]["sum_s"]
        best = p if s && (best.nil? || s > phase_stats[best]["sum_s"])
      end
      best ? { "phase" => best, "sum_s" => phase_stats[best]["sum_s"] } : { "phase" => nil, "reason" => "no phase measured in the window" }
    end

    def summarize(rows)
      ph = phases(rows)
      { "rows" => rows.size, "phases" => ph, "biggest" => biggest(ph), "totals" => totals(rows) }
    end
  end

  module Guards
    module_function

    # reverts: a Source whose items are revert subjects in the window.
    def compute(rows, reverts:)
      {
        "critic_block_rate" => rate(rows, "critic_blocks", "critic_rounds", "no critic rounds measured in the window"),
        "gate_red_rate" => rate(rows, "gate_red", "gate_runs", "no harness_gate.run measured in the window"),
        "reverts" => reverts_value(reverts),
      }
    end

    def rate(rows, num, den, why)
      measured = rows.select { |r| r.dig("counters", den) }
      total = measured.sum { |r| r.dig("counters", den) }
      return { "value" => nil, "reason" => why } if total.zero?

      { "value" => (measured.sum { |r| r.dig("counters", num).to_i }.to_f / total).round(3), "of" => total }
    end

    def reverts_value(reverts)
      return { "value" => nil, "reason" => "could not look (#{reverts.reason})" } if reverts.could_not_look?

      { "value" => reverts.items.size }
    end
  end
end
