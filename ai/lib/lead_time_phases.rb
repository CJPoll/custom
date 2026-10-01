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
  TOTALS = { "lead" => "lead_s", "code" => "code_s", "tail" => "tail_s" }.freeze
  # The telemetry events a phase or counter reads. telemetry.probe is never an
  # anchor (ai/telemetry/events.json).
  EVENTS = %w[harness_gate.run harness_gate.check test_slot.wait critic.round
              integration_gate.run merge.lock_wait merge.landed].freeze
  TOP_CHECKS = 5
  # A full git object name (SHA-1 or SHA-256), lowercase as git writes it and
  # as receipts and verdicts are keyed: an uppercase one would join nothing.
  SHA_RE = /\A(?:[0-9a-f]{40}|[0-9a-f]{64})\z/.freeze

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

  # One lead-time JSON row (string keys), normalised.
  module Landing
    module_function

    # -> [landing Hash, nil] or [nil, reason]. ticket is resolved by the caller
    # (a push row carries one; a PR row's comes from its branch or title);
    # ticket_na says why it could not be resolved (a fault, not "unticketed").
    def from_row(row, ticket:, ticket_na: nil)
      commit = row["landed_commit"] || row["merge_commit"]
      landed = Util.time(row["merged"])
      if commit.to_s.empty?
        what = row["pr"] ? "PR ##{row['pr']}" : "a push"
        # lead-time names why a row has no landed commit (DND-1491); a row
        # with neither is lead-time breaking that contract, never a quiet skip.
        why = row["landing_commit_unmeasured"].to_s
        if why.empty?
          why = "lead-time named no reason (landing_commit_unmeasured is absent: a row from before " \
                "DND-1491, or lead-time broke the rule; see landing_commit_keys in ai/bin/lead-time)"
        end
        return [nil, "no landed commit (#{what}): #{why}"]
      end
      return [nil, "no landing time for #{Util.short(commit)}"] unless landed

      start = Util.time(row["start"])
      gated, gated_na = gated_head_of(row, commit)
      [{ "ticket" => ticket, "ticket_na" => ticket ? nil : ticket_na, "landed_commit" => commit, "landed_at" => landed,
         "gated_head" => gated, "gated_head_na" => gated_na,
         "landed_via" => row["landed_via"], "pr" => row["pr"], "start" => start,
         "start_na" => start ? nil : row["unmeasured_reason"],
         "lead_s" => row["lead_seconds"], "code_s" => row["code_seconds"], "tail_s" => row["tail_seconds"],
         "lead_na_reason" => row["unmeasured_reason"] }, nil]
    end

    def unit_desc(landing) = landing["ticket"] || "head #{head_desc(landing)}"

    # The sha a head-keyed lookup used: the gated head, else (none known) the
    # landed commit, which is what the row is named by.
    def head_desc(landing) = Util.short(landing["gated_head"] || landing["landed_commit"])

    # Set each ticketed landing's "after": the previous landing of the same
    # ticket (from the ledger's prior rows or this batch), so a ticket that
    # lands twice never counts the first landing's events again.
    # prior: ledger rows of this repo. -> the landings, each with "after".
    def with_bounds(landings, prior)
      seen = Hash.new { |h, k| h[k] = [] }
      prior.each { |r| (t = Util.time(r["landed_at"])) && r["ticket"] && seen[r["ticket"]] << t }
      landings.each { |l| seen[l["ticket"]] << l["landed_at"] if l["ticket"] }
      landings.map do |l|
        earlier = l["ticket"] ? seen[l["ticket"]].select { |t| t < l["landed_at"] } : []
        l.merge("after" => earlier.max)
      end
    end

    # Whether the landed commit IS the gated head. A merge (squash) landing's
    # commit is made by the forge, so it is not; its gated head (when known)
    # is the PR head, in landing["gated_head"].
    def landed_is_gated_head?(landing) = landing["landed_via"] != "merge"

    # The head integration-gate, the critic and harness-gate saw, which their
    # receipts, verdicts and timings are keyed on (DND-1490). A push landing's
    # commit IS that head; a merge landing's is the forge's, so its head is the
    # PR's own head (lead-time's head_commit). -> [sha, nil] or [nil, reason].
    # A head that is absent, unread or not a sha is a reason, never "".
    def gated_head_of(row, commit)
      return [commit, nil] unless row["landed_via"] == "merge"

      head = row["head_commit"]
      return [head, nil] if head.is_a?(String) && head.match?(SHA_RE)

      forge = "merge landing: #{Util.short(commit)} is the forge's commit"
      why = if !row.key?("head_commit")
              "the row has no head_commit (it predates DND-1490; re-ingest with --since and --rejoin)"
            elsif head.to_s.empty?
              "its PR head could not be read (#{row['head_commit_unmeasured'] || 'lead-time gave no reason'})"
            else
              "its PR head #{head.inspect} is not a commit sha"
            end
      [nil, "#{forge}, and #{why}"]
    end
  end

  # Telemetry events written in this repo only (`repo` is the writer's label,
  # the basename of the repo's main checkout). A ticket can span repos.
  def self.scope_events(source, repo_label)
    Source.new(status: source.status, reason: source.reason,
               items: source.items.select { |e| e["repo"] == repo_label })
  end

  # Which telemetry events belong to a landing: by unit for a ticketed one,
  # by head for an unticketed one (P5), after the ticket's previous landing
  # and at or before this one.
  module Match
    module_function

    def at(event) = Util.time(event["at"])

    def in_span(events, landing)
      after = landing["after"]
      events.select { |e| (t = at(e)) && t <= landing["landed_at"] && (after.nil? || t > after) }
    end

    def for_unit(events, landing, name)
      key = landing["ticket"]
      in_span(events, landing).select do |e|
        e["event"] == name && (key ? e["unit"] == key : on_gated_head?(e, landing))
      end
    end

    # Events about the gated head: by head when the landed commit IS that
    # head, else (a merge landing) by unit.
    def for_gated(events, landing, name)
      return for_unit(events, landing, name) unless Landing.landed_is_gated_head?(landing)

      in_span(events, landing).select { |e| e["event"] == name && on_gated_head?(e, landing) }
    end

    # An event about the landing's gated head. No gated head matches nothing,
    # never an event that carries no head.
    def on_gated_head?(event, landing)
      head = landing["gated_head"]
      !head.nil? && event["head"] == head
    end

    def dirty?(event_or_receipt)
      event_or_receipt["dirty"] == true || attr(event_or_receipt, "dirty") == true
    end

    def end_of(event)
      t = at(event)
      d = event["duration_s"]
      d.is_a?(Numeric) ? t + d : t
    end

    def attr(event, key) = (event["attrs"].is_a?(Hash) ? event["attrs"] : {})[key]
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
        "critic_pass" => critic_pass(landing, events, verdicts, integ),
        "integrate_start" => integ[0],
        "integrate_end" => integ[1],
        "landed" => found(landing["landed_at"], "lead-time"),
      }
    end

    def dispatch(landing)
      return found(landing["start"], "dispatch stamp") if landing["start"]
      return missing(no_unit(landing, "unticketed landing: no dispatch stamp")) unless landing["ticket"]

      missing("dispatch stamp: #{landing['start_na'] || "no stamp for #{landing['ticket']}"}")
    end

    # A landing with no ticket: unticketed, or its ticket could not be read.
    def no_unit(landing, unticketed)
      landing["ticket_na"] ? "ticket: could not look (#{landing['ticket_na']})" : unticketed
    end

    def telemetry_miss(events, what)
      events.could_not_look? ? "telemetry: could not look (#{events.reason})" : what
    end

    def gate_first(landing, events)
      return missing(no_unit(landing, "unticketed landing: no unit to join gate runs on")) unless landing["ticket"]

      runs = Match.for_unit(events.items, landing, "harness_gate.run")
      return missing(telemetry_miss(events, "no harness_gate.run for #{landing['ticket']}")) if runs.empty?

      found(runs.map { |e| Match.at(e) }.min, "telemetry harness_gate.run")
    end

    # The last clean critic PASS before the integration run started (with
    # only its end known, before it ended; with neither, before the landing).
    # Telemetry critic.round for the unit and the head's verdict receipts are
    # both candidates. A dirty PASS judged an uncommitted tree: never one.
    def critic_pass(landing, events, verdicts, integ)
      cands = Match.for_unit(events.items, landing, "critic.round")
                   .select { |e| Match.attr(e, "verdict").to_s.downcase == "pass" && !Match.dirty?(e) }
                   .map { |e| [Match.end_of(e), "telemetry critic.round"] }
      cands += verdicts.items.select { |v| v["verdict"].to_s.downcase == "pass" && !Match.dirty?(v) }
                       .filter_map { |v| (t = Util.time(v["at"])) && [t, "critic verdict receipt"] }
      cands.select! { |t, _| t <= landing["landed_at"] && (landing["after"].nil? || t > landing["after"]) }
      return missing(critic_miss(landing, events, verdicts)) if cands.empty?

      bound, what = integ[0].at ? [integ[0].at, "started"] : [integ[1].at, "ended"]
      if bound
        before = cands.select { |t, _| Util.floor(t) <= bound }
        if before.empty?
          return missing("every critic PASS for #{Landing.unit_desc(landing)} ended after integration-gate " \
                         "#{what} (a --with-critic round); none stood before it")
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
        "#{Landing.head_desc(landing)})"
    end

    # -> [start Anchor, end Anchor]: the last successful integration_gate.run
    # on the landed head, else the receipt's recorded_at as the end only.
    def integrate(landing, events, receipt)
      runs = Match.for_gated(events.items, landing, "integration_gate.run")
                  .select { |e| Match.attr(e, "exit_code") == 0 }
      run = runs.max_by { |e| Match.at(e) }
      sha = Landing.head_desc(landing)
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
        # An interrupted run (ok=false, interrupted=true) was stopped, not red.
        [evs.size, wall(evs), evs.count { |e| Match.attr(e, "ok") == false && Match.attr(e, "interrupted") != true }]
      end
      family(landing, events, "test_slot.wait", %w[slot_wait_s], out, na) { |evs| [wall(evs)] }
      family(landing, events, "critic.round", %w[critic_rounds critic_blocks critic_wall_s], out, na) do |evs|
        [evs.size, evs.count { |e| Match.attr(e, "verdict").to_s.downcase == "block" }, wall(evs)]
      end
      family(landing, events, "merge.lock_wait", %w[lock_wait_s], out, na) { |evs| [wall(evs)] }
      top = top_checks(landing, events, timings)
      { "counters" => out, "counters_na" => na }.merge(top)
    end

    # The summed duration_s, or nil when no event carries one (a missing
    # duration is never summed as 0).
    def wall(evs)
      ds = evs.map { |e| e["duration_s"] }.grep(Numeric)
      ds.empty? ? nil : ds.sum.round(3)
    end

    def family(landing, events, name, keys, out, na)
      evs = Match.for_unit(events.items, landing, name)
      unit = Landing.unit_desc(landing)
      if evs.empty?
        why = Anchors.telemetry_miss(events, "no #{name} for #{unit}")
        keys.each { |k| out[k] = nil; na[k] = why }
      else
        keys.zip(yield(evs)).each do |k, v|
          out[k] = v
          na[k] = "no duration_s on any #{name} for #{unit}" if v.nil?
        end
      end
    end

    def top_checks(landing, events, timings)
      checks = Match.for_gated(events.items, landing, "harness_gate.check")
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
      sha = Landing.head_desc(landing)
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
        "landed_commit" => landing["landed_commit"], "gated_head" => landing["gated_head"],
        "landed_at" => Util.iso(landing["landed_at"]),
        "landed_via" => landing["landed_via"], "pr" => landing["pr"], "start" => Util.iso(landing["start"]),
        "lead_s" => landing["lead_s"], "code_s" => landing["code_s"], "tail_s" => landing["tail_s"],
        "lead_na_reason" => landing["lead_na_reason"], "ingested_at" => Util.iso(ingested_at) }
        .merge(landing["gated_head"] ? {} : { "gated_head_na" => landing["gated_head_na"] })
    end

    # An improve-mode merge landing ledgered with no gated head: the rows
    # DND-1490's --rejoin may replace, once each.
    def rejoinable?(row)
      row["mode"] == "improve" && row["landed_via"] == "merge" && row["gated_head"].nil?
    end

    # This scan's improve-mode merge rows, by key: the candidates to replace
    # a rejoinable row. -> {key => row}
    def rejoins(rows)
      rows.select { |r| r["mode"] == "improve" && r["landed_via"] == "merge" }.to_h { |r| [key(r), r] }
    end

    REJOIN_VERDICTS = %i[replace not_in_scan no_head would_lose].freeze

    # What --rejoin does with one rejoinable ledger row, given this scan's row
    # for its key (nil when the scan did not list it):
    #   :not_in_scan  the scan did not list it (--since after its landing)
    #   :no_head      the scan's row still has no gated head
    #   :would_lose   the scan's row lost a measurement the original has
    #                 (telemetry pruned since): the original stays
    #   :replace      otherwise
    def rejoin_verdict(old, fresh)
      return :not_in_scan unless fresh
      return :no_head unless fresh["gated_head"]
      return :would_lose if loses_measurement?(old, fresh)

      :replace
    end

    # True when a phase, counter or top_checks the original measured is null
    # in the fresh row.
    def loses_measurement?(old, fresh)
      lost = ->(a, b) { !a.nil? && b.nil? }
      PHASES.any? { |p| lost.call(old.dig("phases", p, "s"), fresh.dig("phases", p, "s")) } ||
        (old["counters"] || {}).any? { |k, v| lost.call(v, (fresh["counters"] || {})[k]) } ||
        lost.call(old["top_checks"], fresh["top_checks"])
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
    ISO_RE = /\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})/.freeze

    module_function

    # A reason with its row's own ticket, landed commit and gated head masked,
    # so one cause on many landings groups as one reason.
    def generic(reason, row)
      out = reason.to_s
      out = out.gsub(row["ticket"], "<unit>") if row["ticket"].is_a?(String) && !row["ticket"].empty?
      [row["landed_commit"], row["gated_head"]].each do |s|
        sha = s.to_s
        out = out.gsub(sha, "<sha>").gsub(sha[0, 8], "<sha>") if sha.size >= 8
      end
      out.gsub(ISO_RE, "<time>")
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

    # reverts: a Source whose items are revert subjects in the window, or nil
    # when the window is empty (nothing to look over).
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
      return { "value" => nil, "reason" => "no landings in the window" } if reverts.nil?
      return { "value" => nil, "reason" => "could not look (#{reverts.reason})" } if reverts.could_not_look?

      { "value" => reverts.items.size }
    end
  end
end
