# frozen_string_literal: true

# lead_time_phases -- the DOMAIN of ai/bin/lead-time-phases (DND-1477). Pure:
# no file, process, network or clock access. Every input arrives as a value.
#
# A landing (one row of `ai/bin/lead-time --since --json`, DND-1009) splits
# into five phases between anchors (ai/docs/lead-time-improver.md ->
# Decision 5). The standalone-PASS flow:
#
#   dispatch --implement--> gate_first --verify--> critic_pass --queue-->
#   integrate_start --integrate--> integrate_end --merge--> landed
#
# The --with-critic flow (DND-1501), whose PASS is judged inside the run:
#
#   dispatch --implement--> gate_first --verify--> integrate_start
#   --integrate--> integrate_end --queue--> land_start --merge--> landed
#
# land_start is the first merge.lock_wait after the run ended, or the start
# of a timed merge.landed push (gh-athena, DND-1501), whichever is earlier.
#
# gate_first is the unit's first run of its repo's declared gate: a
# harness_gate.run (custom) or a gate.run that test-slot writes for any other
# declared gate run under it (DND-1530; gen_saas's bin/prep-commit.sh). Only
# an improve-mode repo gets phases (watch rows are n/a by design).
#
# Each phase is whole seconds, or null with `na_reason` when an anchor is
# missing, or null with `invalid: true` when its anchors are out of order.
# Three out-of-order shapes are not invalid (DND-1819,
# Phases.effective_anchors): a first gate run inside the final integration
# run means no gate ran before it, so verify is a measured 0; two
# neighbouring shapes are n/a with a reason naming them. Never 0 for a
# missing input, never negative. Anchors are floored to whole seconds BEFORE subtraction, so the
# five phases telescope: their sum equals landed - dispatch exactly.
#
# A source the IO side read is a Source: status :ok (found), :empty (looked,
# nothing for this key) or :could_not_look (with a reason). "could not look"
# becomes the na_reason text, so a missing source never reads as zero.

require "json"
require "time"
require_relative "lead_time_config"

module LeadTimePhases
  SCHEMA = 1
  PHASES = %w[implement verify queue integrate merge].freeze
  ANCHORS = %w[dispatch gate_first critic_pass integrate_start integrate_end land_start landed].freeze
  # phase -> [start anchor, end anchor], for the standalone-PASS flow: a
  # clean critic PASS stood before the integration run started.
  PHASE_ANCHORS = {
    "implement" => %w[dispatch gate_first],
    "verify" => %w[gate_first critic_pass],
    "queue" => %w[critic_pass integrate_start],
    "integrate" => %w[integrate_start integrate_end],
    "merge" => %w[integrate_end landed],
  }.freeze
  # The --with-critic flow (DND-1501): no PASS stood before the integration
  # run, and its own critic judged the PASS inside it (the captain's verify
  # step IS `integration-gate --with-critic`). Verify runs to that run's
  # start (fix rounds, re-gates and earlier attempts), and the wait for the
  # admiral comes AFTER the run: queue = run end -> the landing start, merge =
  # the landing start -> the landing. The five still telescope.
  WITH_CRITIC_PHASE_ANCHORS = {
    "implement" => %w[dispatch gate_first],
    "verify" => %w[gate_first integrate_start],
    "queue" => %w[integrate_end land_start],
    "integrate" => %w[integrate_start integrate_end],
    "merge" => %w[land_start landed],
  }.freeze
  FLOWS = %w[with_critic standalone].freeze
  TOTALS = { "lead" => "lead_s", "code" => "code_s", "tail" => "tail_s" }.freeze
  # The telemetry events a phase or counter reads. telemetry.probe is never an
  # anchor (ai/telemetry/events.json).
  EVENTS = %w[harness_gate.run gate.run harness_gate.check test_slot.wait critic.round
              integration_gate.run merge.lock_wait merge.landed].freeze
  # The events that are one run of a repo's declared gate: harness-gate's own,
  # and the one test-slot writes for any other declared gate (DND-1530). Each
  # run is one of them, never both, so the gate anchor and counters read both.
  GATE_RUN_EVENTS = %w[harness_gate.run gate.run].freeze
  GATE_RUN_DESC = GATE_RUN_EVENTS.join(" or ")
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
         "tail_end" => row["end_kind"]&.to_s, "lead_na_reason" => row["unmeasured_reason"] }, nil]
    end

    def unit_desc(landing) = landing["ticket"] || "head #{head_desc(landing)}"

    # The sha a head-keyed lookup used: the gated head, else (none known) the
    # landed commit, which is what the row is named by.
    def head_desc(landing) = Util.short(landing["gated_head"] || landing["landed_commit"])

    # The key Match.for_gated searched by: the head for a push landing, else
    # (a merge landing) the unit (DND-1511). A push landing PushJoin could
    # not join to a gated head also says what it searched (DND-1809).
    def gated_desc(landing)
      return unit_desc(landing) unless landed_is_gated_head?(landing)

      miss = landing["gated_head_miss"]
      miss ? "#{head_desc(landing)} (#{miss})" : head_desc(landing)
    end

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

  # The events of the named kinds (EVENTS: the phase and counter events),
  # from a read of every kind.
  def self.only_events(source, names)
    Source.new(status: source.status, reason: source.reason,
               items: source.items.select { |e| names.include?(e["event"]) })
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

    # name: one event name, or a list of them.
    def for_unit(events, landing, name)
      key = landing["ticket"]
      names = Array(name)
      in_span(events, landing).select do |e|
        names.include?(e["event"]) && (key ? e["unit"] == key : on_gated_head?(e, landing))
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

    # A successful integration_gate.run (exit 0).
    def ok_run?(event) = event["event"] == "integration_gate.run" && attr(event, "exit_code") == 0
  end

  # DND-1809. A push landing's commit is the head integration-gate gated only
  # when the admiral pushed that head as it was. After a clean rebase onto a
  # moved main (the DND-1463 rule), the pushed commit is new, and the run,
  # the critic verdicts, the receipt and the timings are all keyed on the
  # head that was gated. PushJoin finds that head from recorded data, in
  # this order, and only a provable match counts:
  #   1. the landed commit itself: a receipt for it (the IO side's exact
  #      cover, or its receipt), or a successful integration_gate.run on it;
  #   2. the clean-rebase cover: the gated heads whose clean merge onto the
  #      pre-push main gives the landed tree (ir_push_covered in
  #      ai/lib/integration-receipt.sh, the rule gh-athena's push guard uses;
  #      the IO side runs it, with the pre-push main from the push's own
  #      merge.landed `before`);
  #   3. the ticket: the heads of the ticket's successful
  #      integration_gate.runs in this landing's span. Only when step 2
  #      could not judge (no pre-push main recorded, or the rule could not
  #      run): a ticket head the rule judged and rejected never joins.
  # The first step that finds anything decides. Exactly one head joins.
  # Two or more is ambiguous, and none is a miss: the landed
  # commit stays the key (nothing that joined before stops joining), and
  # gated_head_miss says, in short, which keys were searched;
  # gated_head_search keeps the full detail. Never a guess.
  module PushJoin
    module_function

    # The pre-push main: the `before` of a merge.landed push of the landed
    # commit, or nil (a push gh-athena did not make, or before DND-1475).
    # Two pushes of one commit with different befores is no answer.
    def before_of(landing, events)
      befores = events.items.select do |e|
        e["event"] == "merge.landed" && Match.attr(e, "via") == "push" && e["head"] == landing["landed_commit"]
      end.filter_map { |e| Match.attr(e, "before") }.select { |b| b.is_a?(String) && b.match?(SHA_RE) }.uniq
      befores.size == 1 ? befores.first : nil
    end

    # events: a Source (this repo's phase events). cover: a Source from the
    # IO side, items [{"cover" => "exact"|"rebase"|"landed", "heads" => [sha],
    # "onto" => pre-push main or nil}]. landed_receipt: the receipt Source
    # for the landed commit. -> the landing, with gated_head and either
    # gated_head_source, or gated_head_miss and gated_head_search.
    def resolve(landing, events:, cover:, landed_receipt:)
      return landing unless Landing.landed_is_gated_head?(landing)

      commit = landing["landed_commit"]
      found = cover.status == :ok ? cover.items.first : nil
      exact = found&.dig("cover") == "exact"
      if exact || !landed_receipt.items.empty?
        how = exact ? "ir_push_covered's exact cover" : "its receipt file"
        return joined(landing, commit, "an integration receipt for the landed commit (#{how})")
      end

      # A successful run only, as in step 3: a red run on the pushed commit
      # is not what let it land.
      if Match.in_span(events.items, landing).any? { |e| Match.ok_run?(e) && e["head"] == commit }
        return joined(landing, commit, "a successful integration_gate.run on the landed commit")
      end

      onto = found&.dig("onto") || before_of(landing, events)
      heads = found&.dig("cover") == "rebase" ? Array(found["heads"]).uniq : []
      onto_desc = onto ? "onto #{Util.short(onto)}" : "(no single merge.landed before for #{Util.short(commit)})"
      return joined(landing, heads.first, "the integration receipt's clean-rebase cover #{onto_desc}") if heads.size == 1
      if heads.size > 1
        return missed(landing, "ambiguous: #{heads.size} gated heads each give its tree as a clean rebase " \
                               "#{onto_desc} (#{shorts(heads)})", cover_detail(cover))
      end

      searched = searched_desc(commit, landed_receipt, cover, onto_desc)
      # With the pre-push main known, ir_push_covered judged every receipt
      # head of this change and none gives the landed tree: a ticket head
      # would be one the rule disproved (or one it could not check), so
      # the ticket is not tried.
      if onto && (cover.status == :empty || found)
        return missed(landing, "no gated head: #{searched} (the rule judged every receipt head of this change, " \
                               "so the ticket is not tried)", cover_detail(cover))
      end

      by_ticket(landing, events, searched, cover_detail(cover))
    end

    # What steps 1 and 2 searched, from what each lookup actually returned:
    # a lookup that could not run never reads as one that found nothing.
    def searched_desc(commit, landed_receipt, cover, onto_desc)
      sha = Util.short(commit)
      first = if landed_receipt.could_not_look?
                "no integration_gate.run on #{sha}, and its receipt could not be read (#{landed_receipt.reason})"
              else
                "no receipt or integration_gate.run on #{sha}"
              end
      second = if cover.could_not_look?
                 "the clean-rebase cover #{onto_desc} could not be judged (#{cover.reason})"
               else
                 "no clean-rebase cover #{onto_desc}"
               end
      "#{first}, #{second}"
    end

    # Step 3, only when the cover could not judge: no pre-push main is
    # recorded, or the rule could not run. Not tree-checked, and said so.
    def by_ticket(landing, events, searched, detail)
      unit = landing["ticket"]
      unless unit
        why = Anchors.no_unit(landing, "unticketed: no ticket to fall back to")
        return missed(landing, "no gated head: #{searched}; #{why}", detail)
      end
      heads = Match.for_unit(events.items, landing, "integration_gate.run").select { |e| Match.ok_run?(e) }
                   .map { |e| e["head"] }.select { |h| h.is_a?(String) && h.match?(SHA_RE) }.uniq
      if heads.size == 1
        return joined(landing, heads.first, "#{unit}'s only gated head (its one successful integration_gate.run " \
                                            "head, not tree-checked; first #{searched})")
      end
      if heads.size > 1
        return missed(landing, "ambiguous: #{searched}, and #{unit} has #{heads.size} gated heads " \
                               "(#{shorts(heads)})", detail)
      end

      ticket = Anchors.telemetry_miss(events, "no successful integration_gate.run for #{unit}")
      missed(landing, "no gated head: #{searched}; #{ticket}", detail)
    end

    def cover_detail(cover)
      what = case cover.status
             when :could_not_look then "could not look (#{cover.reason})"
             when :ok then "#{cover.items.first&.dig('cover')} (it names no gated head)"
             else cover.reason.to_s
             end
      "clean-rebase cover: #{what}"
    end

    def shorts(heads) = heads.map { |h| Util.short(h) }.join(", ")

    def joined(landing, head, source)
      landing.merge("gated_head" => head, "gated_head_na" => nil, "gated_head_source" => source)
             .reject { |k, _| %w[gated_head_miss gated_head_search].include?(k) }
    end

    def missed(landing, miss, detail)
      landing.merge("gated_head_miss" => miss, "gated_head_search" => "#{miss}; #{detail}")
    end
  end

  module Anchors
    # with_critic: true on a critic_pass judged inside a --with-critic
    # integration run (DND-1501), which selects WITH_CRITIC_PHASE_ANCHORS.
    Anchor = Struct.new(:at, :source, :reason, :with_critic, keyword_init: true) do
      def to_h_json = { "at" => Util.iso(at), "source" => source, "reason" => reason,
                        "with_critic" => with_critic }.compact
    end

    module_function

    def found(time, source, with_critic: nil) = Anchor.new(at: Util.floor(time), source: source,
                                                           with_critic: with_critic)
    def missing(reason) = Anchor.new(at: nil, reason: reason)

    # events/receipt/verdicts are Sources. -> {anchor name => Anchor}
    def from(landing:, events:, receipt:, verdicts:)
      run = last_ok_run(landing, events)
      integ = integrate(landing, events, receipt, run)
      {
        "dispatch" => dispatch(landing),
        "gate_first" => gate_first(landing, events),
        "critic_pass" => critic_pass(landing, events, verdicts, integ, run),
        "integrate_start" => integ[0],
        "integrate_end" => integ[1],
        "land_start" => land_start(landing, events, integ[1]),
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

      runs = Match.for_unit(events.items, landing, GATE_RUN_EVENTS)
      return missing(telemetry_miss(events, "no #{GATE_RUN_DESC} for #{landing['ticket']}")) if runs.empty?

      restart = restart_at(landing, events)
      if restart
        since = runs.reject { |e| Match.at(e) < restart }
        if since.empty?
          return missing("no #{GATE_RUN_DESC} for #{landing['ticket']} since its restart at #{Util.iso(restart)} " \
                         "(#{runs.size} before it, from before the park)")
        end
        runs = since
      end
      first = runs.min_by { |e| Match.at(e) }
      found(Match.at(first), "telemetry #{first['event']}")
    end

    # The dispatch stamp, when a ticket.dispatched for the unit recorded it as
    # a restart (DND-1838: a re-dispatch from a park restarts the stamp). Gate
    # runs before it belong to the time before the park, so they are not the
    # first gate of this dispatch. With no such event (another machine
    # dispatched it), a gate before the stamp stays value's "invalid".
    def restart_at(landing, events)
      start = landing["start"]
      return nil unless start

      hit = Match.for_unit(events.items, landing, "ticket.dispatched").any? do |e|
        Match.attr(e, "restart") == true && Match.at(e).to_i == start.to_i
      end
      hit ? start : nil
    end

    # The last clean critic PASS before the integration run started (with
    # only its end known, before it ended; with neither, before the landing).
    # Telemetry critic.round for the unit and the head's verdict receipts are
    # both candidates. A dirty PASS judged an uncommitted tree: never one.
    # When none stood before the run, the PASS its own --with-critic critic
    # judged inside it is the anchor, marked with_critic (DND-1501).
    def critic_pass(landing, events, verdicts, integ, run = nil)
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
        return with_critic_pass(landing, cands, integ, run, what) if before.empty?

        cands = before
      end
      t, src = cands.max_by(&:first)
      found(t, src)
    end

    # No clean PASS stood before the integration run. -> the last PASS judged
    # inside that run when the run is marked --with-critic (its own critic
    # judged it), else missing with the reason. The run must be known by its
    # start: with only the receipt's end, "inside" cannot be told.
    def with_critic_pass(landing, cands, integ, run, what)
      none = "every critic PASS for #{Landing.unit_desc(landing)} ended after integration-gate #{what}"
      return missing("#{none} (a --with-critic round); none stood before it") unless run && integ[0].at

      flag = Match.attr(run, "with_critic")
      unless flag == true
        return missing("#{none}, and that run is not marked --with-critic (its with_critic attr is " \
                       "#{flag.inspect}); none stood before it")
      end
      inside = cands.select do |t, _|
        f = Util.floor(t)
        f >= integ[0].at && (integ[1].at.nil? || f <= integ[1].at)
      end
      if inside.empty?
        return missing("#{none}, and none was judged inside that --with-critic run (it ended " \
                       "#{Util.iso(integ[1].at)}); none stood before it")
      end
      t, src = inside.max_by(&:first)
      found(t, "#{src}, inside the --with-critic integration_gate.run", with_critic: true)
    end

    def critic_miss(landing, events, verdicts)
      looked = []
      looked << "telemetry: could not look (#{events.reason})" if events.could_not_look?
      looked << "critic verdicts: could not look (#{verdicts.reason})" if verdicts.could_not_look?
      return looked.join("; ") unless looked.empty?

      "no critic PASS for #{Landing.unit_desc(landing)} (no critic.round, no verdict receipt on " \
        "#{Landing.head_desc(landing)})"
    end

    # The last successful integration_gate.run on the landed head, or nil.
    def last_ok_run(landing, events)
      Match.for_gated(events.items, landing, "integration_gate.run")
           .select { |e| Match.attr(e, "exit_code") == 0 }
           .max_by { |e| Match.at(e) }
    end

    # -> [start Anchor, end Anchor]: the last successful integration_gate.run
    # on the landed head (run: last_ok_run's), else the receipt's recorded_at
    # as the end only.
    def integrate(landing, events, receipt, run = last_ok_run(landing, events))
      sha = Landing.head_desc(landing)
      # sha names the head-keyed receipt; gated names the key the run lookup used.
      gated = Landing.gated_desc(landing)
      rec = receipt.items.first && Util.time(receipt.items.first["recorded_at"])
      if run
        start = found(Match.at(run), "telemetry integration_gate.run")
        return [start, found(Match.end_of(run), "telemetry integration_gate.run")] if run["duration_s"].is_a?(Numeric)
        return [start, found(rec, "integration receipt")] if rec

        return [start, missing("integration_gate.run on #{gated} has no duration and no receipt")]
      end
      no_run = telemetry_miss(events, "no integration_gate.run on #{gated}")
      return [missing("#{no_run} (the receipt gives the end only)"), found(rec, "integration receipt")] if rec

      rec_why = receipt.could_not_look? ? "receipt: could not look (#{receipt.reason})" : "no integration receipt for #{sha}"
      [missing(no_run), missing("#{no_run}; #{rec_why}")]
    end

    # When the admiral began landing the gated head (DND-1501): the earliest
    # of the first merge.lock_wait (locked-merge) and the start of a timed
    # merge.landed push (gh-athena: at = the push start, duration_s = its
    # wall), at or after the integration run ended (integ_end: an Anchor). A
    # point merge.landed (a locked-merge confirmation, or a push from before
    # DND-1501) marks only the end, so it is never a start.
    def land_start(landing, events, integ_end)
      locks = landing_events(landing, events, "merge.lock_wait")
                   .map { |e| [Match.at(e), "telemetry merge.lock_wait"] }
      pushes = landing_events(landing, events, "merge.landed")
                    .select { |e| Match.attr(e, "via") == "push" && e["duration_s"].is_a?(Numeric) }
                    .map { |e| [Match.at(e), "telemetry merge.landed (the push start)"] }
      cands = (locks + pushes).select { |t, _| integ_end.at.nil? || Util.floor(t) >= integ_end.at }
      return found(*cands.min_by(&:first)) unless cands.empty?

      missing(telemetry_miss(events, "no landing start for #{Landing.gated_desc(landing)}: no merge.lock_wait " \
                                     "and no timed merge.landed push after integration ended (a gh-athena push " \
                                     "to main records its start from DND-1501 on; the custom ff landing's " \
                                     "hand-held lock writes no merge.lock_wait until DND-1370)"))
    end

    # This landing's merge.lock_wait or merge.landed events. A push records
    # head = the pushed commit, which after a clean rebase is not the gated
    # head (DND-1809), so a push landing's are matched on either.
    def landing_events(landing, events, name)
      return Match.for_gated(events.items, landing, name) unless Landing.landed_is_gated_head?(landing)

      keys = [landing["gated_head"], landing["landed_commit"]].compact
      Match.in_span(events.items, landing).select { |e| e["event"] == name && keys.include?(e["head"]) }
    end
  end

  module Phases
    module_function

    # "with_critic" when the critic_pass anchor was judged inside a
    # --with-critic integration run (DND-1501), else "standalone" (the
    # Decision 5 rule, including every row with no PASS at all).
    def flow(anchors) = anchors["critic_pass"]&.with_critic ? "with_critic" : "standalone"

    # phase -> [start anchor, end anchor] for the flow.
    def anchor_map(anchors) = flow(anchors) == "with_critic" ? WITH_CRITIC_PHASE_ANCHORS : PHASE_ANCHORS

    # anchors: {name => Anchor} -> {phase => {"s"=>Integer|nil, "na_reason"=>.., "invalid"=>true,
    # "basis"=>..}}. "basis" is set on a measured or invalid cell that read
    # the derived verify start (DND-1819, see effective_anchors).
    def compute(anchors)
      eff, notes = effective_anchors(anchors)
      anchor_map(anchors).to_h do |phase, (from, to)|
        note = notes[phase]
        next [phase, { "s" => nil, "na_reason" => note[:na] }] if note&.key?(:na)

        cell = value(eff.fetch(from), eff.fetch(to), from, to)
        read_derived = note && (!cell["s"].nil? || cell["invalid"])
        [phase, read_derived ? cell.merge("basis" => note[:basis]) : cell]
      end
    end

    # DND-1819. Verify is the captain's time between the first gate run and
    # the final integration attempt. When no gate ran before that attempt,
    # gate_first (the earliest gate run) is out of order with verify's end:
    #   - it is inside the final integration run: the window is empty, so
    #     verify is a measured 0 that starts where it ends (the run's start in
    #     the with-critic flow, the PASS in the standalone flow), and
    #     implement ends there too. The phases still telescope.
    #   - it is after a final run whose end is not recorded: "inside" cannot
    #     be told, so verify is n/a naming that.
    #   - standalone, the PASS came before a first gate run that ran before
    #     the final run: the captain gated after the PASS, and no PASS ends
    #     verify, so verify is n/a naming that.
    # Any other order (a gate before the dispatch stamp, a first gate after
    # the final run ended) is left to value's "invalid".
    # Residual: gate_first is the first LOCAL gate run recorded for the unit.
    # A gate run that left no such event (run on another machine, a failed
    # telemetry write: the summary's write-failures) reads as "no gate ran
    # before", so verify reads 0 here where it read invalid before. Every
    # gate_first anchor carries the same residual; the basis names it.
    # -> [anchors with gate_first replaced by the derived verify start (or as
    #     given), {phase => {basis:} | {na:}}]
    def effective_anchors(anchors)
      gate = anchors["gate_first"]
      start = anchors["integrate_start"]
      return [anchors, {}] unless gate&.at && start&.at

      verify_end_name = anchor_map(anchors).fetch("verify")[1]
      verify_end = anchors.fetch(verify_end_name)
      return [anchors, standalone_pass_first(gate, verify_end, start)] if pass_before_gate_before_run?(anchors, verify_end_name)
      # A first gate in the run's own second already reads verify 0 in the
      # with-critic flow: left as it was.
      return [anchors, {}] if gate.at < start.at || (gate.at == start.at && verify_end_name == "integrate_start")
      # No PASS (standalone): verify is n/a with the PASS's own reason.
      return [anchors, {}] if verify_end.at.nil?

      fin = anchors["integrate_end"]
      return [anchors, { "verify" => { na: unknown_end(gate, start) } }] unless fin&.at
      return [anchors, {}] if gate.at > fin.at

      first_gate_inside(anchors, [gate, start, fin], verify_end_name, verify_end)
    end

    # Standalone: PASS < first gate < the final run's start, and the gate is
    # not before the dispatch stamp (that order stays invalid).
    def pass_before_gate_before_run?(anchors, verify_end_name)
      gate = anchors["gate_first"].at
      pass = anchors[verify_end_name].at
      dispatch = anchors["dispatch"]&.at
      verify_end_name == "critic_pass" && pass && pass < gate && gate < anchors["integrate_start"].at &&
        (dispatch.nil? || dispatch <= gate)
    end

    def first_gate_inside(anchors, (gate, start, fin), verify_end_name, verify_end)
      shape = "the unit's first recorded gate run (#{Util.iso(gate.at)}) is inside its final integration " \
              "run (#{Util.iso(start.at)} -> #{Util.iso(fin.at)}): no gate run was recorded before it"
      derived = Anchors.found(verify_end.at, "#{verify_end_name}: #{shape}")
      notes = {
        "verify" => { basis: "0: #{shape}, so no time passed between the first gate and the final integration " \
                             "attempt (a gate run with no local event, e.g. on another machine, is not seen)" },
        "implement" => { basis: "ends at #{verify_end_name} (#{Util.iso(verify_end.at)}), not the first gate " \
                                "run: #{shape}" },
      }
      [anchors.merge("gate_first" => derived), notes]
    end

    def unknown_end(gate, start)
      "the unit's first gate run (#{Util.iso(gate.at)}) is after its final integration run's start " \
        "(#{Util.iso(start.at)}), and that run has no recorded end, so whether the gate run is inside it " \
        "cannot be told"
    end

    def standalone_pass_first(gate, pass, start)
      { "verify" => { na: "the critic PASS (#{Util.iso(pass.at)}) is before the first gate run " \
                          "(#{Util.iso(gate.at)}), which is before the final integration run " \
                          "(#{Util.iso(start.at)}): the captain gated after the PASS, so no PASS ends verify" } }
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
    #     "top_checks_source"=>.., "top_checks_na"=>.., "check_walls"=>{label=>wall_s}
    #     | "check_walls_na"=>..}
    def compute(landing:, events:, timings:)
      out = {}
      na = {}
      family(landing, events, GATE_RUN_EVENTS, %w[gate_runs gate_wall_s gate_red], out, na) do |evs|
        # An interrupted run (ok=false, interrupted=true) was stopped, not red.
        # Both events carry the attr.
        [evs.size, wall(evs), evs.count { |e| Match.attr(e, "ok") == false && Match.attr(e, "interrupted") != true }]
      end
      family(landing, events, "test_slot.wait", %w[slot_wait_s], out, na) { |evs| [wall(evs)] }
      family(landing, events, "critic.round", %w[critic_rounds critic_blocks critic_wall_s], out, na) do |evs|
        [evs.size, evs.count { |e| Match.attr(e, "verdict").to_s.downcase == "block" }, wall(evs)]
      end
      family(landing, events, "merge.lock_wait", %w[lock_wait_s], out, na) { |evs| [wall(evs)] }
      { "counters" => out, "counters_na" => na }.merge(check_fields(landing, events, timings))
    end

    # verify.gate_runs_s (DND-1501): the summed wall of every gate run for
    # the unit (GATE_RUN_EVENTS) inside verify's window, each clipped to it.
    # It splits verify into machine time and the captain's fix time.
    # Concurrent runs each count, so it can exceed verify.
    # -> {"gate_runs_s"=>Float} or {"gate_runs_s"=>nil, "gate_runs_na"=>why}
    def verify_gate_runs(landing:, events:, anchors:)
      from, to = Phases.anchor_map(anchors).fetch("verify")
      cell = Phases.compute(anchors).fetch("verify")
      return gate_runs_na("verify n/a: #{cell['na_reason']}") if cell["s"].nil?

      # The anchors verify was read from (DND-1819: a derived start when no
      # gate ran before the final integration run, so the window is empty).
      eff, = Phases.effective_anchors(anchors)
      lo = eff.fetch(from).at
      hi = eff.fetch(to).at
      # A run starting before lo cannot exist (gate_first is the first run),
      # and one starting in hi's own second is left out (hi is floored).
      runs = Match.for_unit(events.items, landing, GATE_RUN_EVENTS).select { |e| Match.at(e) < hi }
      bare = runs.find { |e| !e["duration_s"].is_a?(Numeric) && Match.at(e) >= lo }
      if bare
        return gate_runs_na("no duration_s on the #{bare['event']} at #{Util.iso(Match.at(bare))} inside verify " \
                            "for #{Landing.unit_desc(landing)}")
      end
      wall = runs.select { |e| e["duration_s"].is_a?(Numeric) }
                 .sum(0.0) { |e| [[Match.end_of(e), hi].min - [Match.at(e), lo].max, 0].max }
      { "gate_runs_s" => wall.round(3) }
    end

    def gate_runs_na(why) = { "gate_runs_s" => nil, "gate_runs_na" => why }

    # The summed duration_s, or nil when no event carries one (a missing
    # duration is never summed as 0).
    def wall(evs)
      ds = evs.map { |e| e["duration_s"] }.grep(Numeric)
      ds.empty? ? nil : ds.sum.round(3)
    end

    # name: one event name, or a list of them (any of which counts).
    def family(landing, events, name, keys, out, na)
      evs = Match.for_unit(events.items, landing, name)
      unit = Landing.unit_desc(landing)
      desc = Array(name).join(" or ")
      if evs.empty?
        why = Anchors.telemetry_miss(events, "no #{desc} for #{unit}")
        keys.each { |k| out[k] = nil; na[k] = why }
      else
        keys.zip(yield(evs)).each do |k, v|
          out[k] = v
          na[k] = "no duration_s on any #{desc} for #{unit}" if v.nil?
        end
      end
    end

    # -> {"check_walls"=>{label=>wall_s}, "top_checks"=>top(check_walls), "top_checks_source"=>..}
    #    or, with no source, {"top_checks"=>nil, "top_checks_na"=>why, "check_walls_na"=>why}
    #    (check_walls absent). One reader feeds both (DND-1548).
    def check_fields(landing, events, timings)
      walls, source = check_walls(landing, events, timings)
      return { "check_walls" => walls, "top_checks" => top(walls), "top_checks_source" => source } if walls

      sha = Landing.head_desc(landing)
      tel = Anchors.telemetry_miss(events, "no harness_gate.check on #{Landing.gated_desc(landing)}")
      tim = timings.could_not_look? ? "timings: could not look (#{timings.reason})" : "no timings rows for #{sha}"
      why = "#{tel}; #{tim}"
      { "top_checks" => nil, "top_checks_na" => why, "check_walls_na" => why }
    end

    # [{label => wall_s}, source] for every check of the gated head's last
    # gate run (telemetry harness_gate.check by run_id, else the timings rows
    # of the newest run: harness-gate writes one `at` and `tree` per run), or
    # nil when neither source has a row. A label from an older run is never
    # carried over, and a check with no numeric wall is left out, never read
    # as 0.
    def check_walls(landing, events, timings)
      checks = Match.for_gated(events.items, landing, "harness_gate.check")
      unless checks.empty?
        runs = checks.group_by { |e| Match.attr(e, "run_id").to_s }
        last = runs.values.max_by { |evs| evs.map { |e| Match.at(e) }.max }
        return [walls(last.map { |e| [Match.attr(e, "label"), e["duration_s"]] }), "telemetry harness_gate.check"]
      end
      rows = timings.items
      return nil if rows.empty?

      last = rows.group_by { |r| [r["at"].to_s, r["tree"].to_s] }.max_by(&:first).last
      [walls(last.map { |r| [r["label"], r["wall_s"]] }), "harness-gate timings.jsonl"]
    end

    # A label reported twice in one run keeps its last wall (harness-gate
    # labels are unique per run).
    def walls(pairs) = pairs.select { |label, wall| label.is_a?(String) && wall.is_a?(Numeric) }.to_h

    # The TOP_CHECKS slowest of a check_walls map, as [{label, wall_s}].
    def top(walls)
      walls.map { |label, wall| { "label" => label, "wall_s" => wall } }
           .sort_by { |c| [-c["wall_s"], c["label"]] }.first(TOP_CHECKS)
    end
  end

  # Where a landing was worked (DND-1531). Telemetry is machine-local, so a
  # ticket worked on another machine has no local events, and its phases
  # would read n/a as if the harness could not measure them. Such a landing
  # is "foreign": counted and named, kept out of the phase stats and the
  # biggest pick. Foreign is decided only from positive evidence: a ticketed
  # landing with a dispatch stamp, a telemetry store this reader could read
  # that was already recording dispatches at that instant, and no local event
  # of any kind for the unit. Any local event, or a local receipt, verdict or
  # harness-gate timings row for the gated head, makes it "local". Anything
  # else stays undecided (origin null) with the reason, and is treated as
  # before.
  module Origin
    FOREIGN = "foreign"
    LOCAL = "local"

    module_function

    def foreign_reason(unit) = "worked on another machine (no local events for #{unit})"

    # receipt/verdicts/timings: the head Sources. -> a description of the
    # first one that found something here, or nil.
    def local_evidence(landing, receipt:, verdicts:, timings:)
      sha = Landing.head_desc(landing)
      { "integration receipt" => receipt, "critic verdict receipt" => verdicts,
        "harness-gate timings" => timings }.each do |what, src|
        return "#{what} for #{sha} on this machine" if src && !src.items.empty?
      end
      nil
    end

    # The earliest ticket.dispatched in the store (any unit), or nil. Every
    # dispatch stamp is written by mark-in-progress, which emits that event,
    # so from this instant on a dispatch made here would be in the store.
    # Retention prunes oldest first, so a pruned store moves it later.
    def dispatch_recording_since(events)
      events.items.select { |e| e["event"] == "ticket.dispatched" }.filter_map { |e| Util.time(e["at"]) }.min
    end

    # unit_events: a Source of every local telemetry event, of any registered
    # kind and any repo (a ticket's dispatch may be written from another
    # repo's checkout). evidence: from local_evidence.
    # -> {"origin"=>"local"|"foreign"|nil, "origin_source"=>.. | "origin_na"=>why}
    #
    # Any event for the unit counts, at any time: a merge.landed is confirmed
    # after the landing, and a ticket landed twice whose first landing was
    # worked here reads local for both. That errs toward local, which only
    # keeps the old n/a reading. The ledger is first-write-wins, so an
    # undecided row (a store unreadable at ingest) stays undecided.
    #
    # Residual: a landing worked here with none of the evidence above (no
    # unit-tagged event, receipt, verdict or timings) would read foreign. Every
    # local gate, critic and integration run is unit-tagged from its branch.
    def decide(landing:, unit_events:, evidence: nil)
      unit = landing["ticket"]
      return undecided(Anchors.no_unit(landing, "unticketed landing: no unit to look for local events on")) unless unit

      mine = unit_events.items.count { |e| e["unit"] == unit }
      return local("#{mine} local telemetry event(s) for #{unit}") if mine.positive?
      return local(evidence) if evidence
      return undecided("telemetry: could not look (#{unit_events.reason})") if unit_events.could_not_look?

      start = landing["start"]
      unless start
        why = landing["start_na"] || "no stamp for #{unit}"
        return undecided("no local events for #{unit}, and no dispatch stamp (#{why}): where it was worked is unknown")
      end
      since = dispatch_recording_since(unit_events)
      unless since
        return undecided("no local events for #{unit}, but the telemetry store holds no ticket.dispatched, so it " \
                         "cannot show that a dispatch made here at #{Util.iso(start)} would be recorded")
      end
      if since > start
        return undecided("no local events for #{unit}, but the store's first ticket.dispatched is at " \
                         "#{Util.iso(since)}, after the dispatch at #{Util.iso(start)} (pruned, or not yet " \
                         "recording): a missing event cannot be told from an unrecorded one")
      end

      { "origin" => FOREIGN, "origin_source" => "dispatched at #{Util.iso(start)}, the store recording dispatches " \
                                                "since #{Util.iso(since)}, and no local event, receipt, verdict or " \
                                                "timings for #{unit}" }
    end

    def local(source) = { "origin" => LOCAL, "origin_source" => source }
    def undecided(why) = { "origin" => nil, "origin_na" => why }

    def foreign?(row) = row["origin"] == FOREIGN

    # A foreign landing's five phases: null with the reason. Its anchors and
    # counters are kept as measured (they read the same misses).
    def foreign_phases(unit) = PHASES.to_h { |p| [p, { "s" => nil, "na_reason" => foreign_reason(unit) }] }
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
        "tail_end" => landing["tail_end"],
        "lead_na_reason" => landing["lead_na_reason"], "ingested_at" => Util.iso(ingested_at) }
        .merge(landing["gated_head"] ? {} : { "gated_head_na" => landing["gated_head_na"] })
        .merge(landing.slice(*PUSH_JOIN_FIELDS).compact)
    end

    # How PushJoin joined a push landing, or what it searched (DND-1809).
    PUSH_JOIN_FIELDS = %w[gated_head_source gated_head_miss gated_head_search].freeze

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

    # origin: Origin.decide's result (DND-1531). A foreign landing's phases
    # are null with the foreign reason; its anchors and counters are kept.
    # verify_gate_runs: Counters.verify_gate_runs's result, merged into the
    # verify cell (DND-1501). phase_flow names the anchor map the phases used.
    def improve_row(repo:, landing:, anchors:, counters:, telemetry_status:, ingested_at:, origin:,
                    verify_gate_runs: nil)
      phases = Origin.foreign?(origin) ? Origin.foreign_phases(landing["ticket"]) : Phases.compute(anchors)
      phases["verify"] = phases["verify"].merge(verify_gate_runs) if verify_gate_runs && !Origin.foreign?(origin)
      base(repo: repo, mode: "improve", landing: landing, ingested_at: ingested_at)
        .merge(origin)
        .merge("phase_flow" => Origin.foreign?(origin) ? nil : Phases.flow(anchors), "phases" => phases,
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

  # A post-merge CI declaration that is not one: never read as absent. It
  # carries the Fix: line the caller prints.
  class DeclarationError < StandardError
    attr_reader :fix

    def initialize(message, fix)
      super(message)
      @fix = fix
    end
  end

  # Whether a repo has post-merge CI (DND-1614). The repo's idle_workflow
  # (DND-1540, validated by ai/lib/lead_time_config.rb) is the one home of
  # that fact: a workflow file declares CI, "none" declares none. Only a repo
  # that declares nothing falls back to Stats.post_merge_ci?, the window
  # inference. A declaration is nil (absent) or a Declared.
  module TailCI
    Declared = Struct.new(:value, :workflow, :repo, keyword_init: true)
    INFERRED = "post-merge CI is inferred from the window; declare idle_workflow in the repo's lead-time " \
               "config (ai/bin/lead-time-repos) to make it a fact"

    module_function

    # -> nil (absent) or a Declared. Raises DeclarationError on any other
    # value: a value the config validator would refuse reaching here is a
    # fault, and reading it as absent would hide it.
    def declare(idle_workflow, repo)
      return nil if idle_workflow.nil?
      # IDLE_WORKFLOW_RE matches "none" too: test it first, or "none" would
      # read as a workflow file.
      return Declared.new(value: false, workflow: "none", repo: repo) if idle_workflow == "none"
      if idle_workflow.is_a?(String) && LeadTimeConfig::IDLE_WORKFLOW_RE.match?(idle_workflow)
        return Declared.new(value: true, workflow: idle_workflow, repo: repo)
      end

      raise DeclarationError.new(
        "idle_workflow #{idle_workflow.inspect} for #{repo} is not a workflow file name, \"none\" or absent, " \
        "so whether #{repo} has post-merge CI is unknown",
        "pass the repo's idle_workflow as ai/bin/lead-time-repos resolves it (LeadTimeConfig refuses any other " \
        "value, so this is a caller bug: file a DND ticket with this line)"
      )
    end

    # CI declared yes. declared_value: true, false, or nil (absent).
    def ci_declared?(decl) = !decl.nil? && decl.value == true
    # true, false, or nil (absent).
    def declared_value(decl) = decl&.value

    # The post-merge CI fact: the declaration, else the window inference.
    def ci?(decl, rows) = decl ? decl.value : Stats.post_merge_ci?(rows)

    def declared_desc(decl)
      return "#{decl.repo} declares post-merge CI (idle_workflow #{decl.workflow})" if decl.value

      "#{decl.repo} declares no post-merge CI (idle_workflow none)"
    end

    # The n/a reason of a 0 tail with no post-merge run, in a repo that
    # declares post-merge CI. end_kind nil: a row ingested before DND-1532.
    def declared_na(decl, end_kind)
      kind = end_kind || "none recorded: the row was ingested before DND-1532"
      "tail: #{declared_desc(decl)}, but lead-time found no successful post-merge run for the landing " \
        "(end kind #{kind})"
    end

    # The landings in the window that have a post-merge run: one found at a
    # deploy or pipeline end, or a nonzero tail (only such an end gives one).
    def with_run(rows)
      rows.count do |r|
        Stats::TAIL_RUN_ENDS.include?(r["tail_end"]) || (r["tail_s"].is_a?(Numeric) && r["tail_s"].positive?)
      end
    end

    # -> {"source"=>"declared"|"inferred", "value"=>bool[, "mismatch"=>N]}.
    # mismatch: a repo that declares none, with N landings that have a run.
    def report(decl, rows)
      return { "source" => "inferred", "value" => Stats.post_merge_ci?(rows) } unless decl

      out = { "source" => "declared", "value" => decl.value }
      n = decl.value ? 0 : with_run(rows)
      n.positive? ? out.merge("mismatch" => n) : out
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

    # decl: a TailCI.declare result (nil: absent, the window inference).
    def totals(rows, decl = nil)
      ci = TailCI.ci?(decl, rows)
      TOTALS.to_h do |name, key|
        cells = rows.map do |r|
          next tail_cell(r, ci, decl) if name == "tail"

          r[key].nil? ? [nil, generic(r["lead_na_reason"] || "#{name}: not measured", r)] : [r[key], nil]
        end
        [name, series(cells.map(&:first), cells.map(&:last))]
      end
    end

    # A window shows post-merge CI when one of its landings has a measured
    # nonzero tail (landing -> deploy or pipeline end, ai/bin/lead-time). An
    # inference from the window, not a per-repo fact: a window in which no
    # post-merge run succeeded reads like a repo with none. A forge it could
    # not read never gets here (lead-time: SCAN INCOMPLETE, nothing ingested).
    def post_merge_ci?(rows) = rows.any? { |r| r["tail_s"].is_a?(Numeric) && r["tail_s"].positive? }

    # The end kinds at which lead-time found a post-merge run (ai/bin/lead-time
    # pick_end). "merge" means it found none, and the tail reads 0.
    TAIL_RUN_ENDS = %w[deploy pipeline].freeze

    # -> [seconds or nil, reason or nil]. With post-merge CI (declared, or
    # inferred from the window when the repo declares nothing), a 0 tail with
    # no post-merge run found (end kind "merge", or a row ingested before
    # tail_end was kept) is not a measured 0: it is n/a with why. With none, a
    # 0 tail is a measured 0. decl: a TailCI.declare result, nil when absent.
    def tail_cell(row, ci, decl = nil)
      s = row["tail_s"]
      return [nil, generic(row["lead_na_reason"] || "tail: not measured", row)] if s.nil?
      return [s, nil] unless ci && s.zero? && !TAIL_RUN_ENDS.include?(row["tail_end"])
      return [nil, TailCI.declared_na(decl, row["tail_end"])] if TailCI.ci_declared?(decl)

      why = if row["tail_end"].nil?
              "tail: 0 with no end kind in the ledger row (ingested before DND-1532), so a 0 cannot be told " \
                "from a missing post-merge run"
            else
              "tail: lead-time found no successful post-merge CI run for the landing (end kind " \
                "#{row['tail_end']}), where other landings in the window have one"
            end
      [nil, "#{why}; #{TailCI::INFERRED}"]
    end

    # Where the fix for each biggest-contributor candidate lands: a phase is
    # the harness's; tail (landing -> deploy) is the product repo's own CI and
    # deploy.
    LEVERS = PHASES.to_h { |p| [p, "harness"] }.merge("tail" => "product").freeze

    # Whether tail competes: only with a measured nonzero tail in the window.
    # A tail with no measured nonzero value (all 0, all n/a, or a mix) never
    # does.
    # -> {"tail_candidate"=>bool[, "tail_reason"=>why]}. decl: a
    # TailCI.declare result, nil when absent (the window inference).
    def tail_candidacy(tail_stats, decl = nil)
      sum = tail_stats["sum_s"]
      return { "tail_candidate" => true } if sum&.positive?

      { "tail_candidate" => false, "tail_reason" => no_tail_reason(tail_stats, decl) }
    end

    # Why tail is not a candidate: nothing measured, or measured zeros only.
    def no_tail_reason(tail_stats, decl)
      declared = TailCI.declared_value(decl)
      if tail_stats["sum_s"].nil?
        why = "tail not measured in the window (#{tail_stats['n_na']} n/a)"
        return decl ? "#{why}: #{TailCI.declared_desc(decl)}" : why
      end

      n = tail_stats["n"]
      case declared
      when true
        "no measured nonzero tail in the window: each of its #{n} measured landing(s) had a post-merge run " \
          "that ended at the landing, and #{tail_stats['n_na']} are n/a (#{TailCI.declared_desc(decl)})"
      when false
        "no measured nonzero tail in the window: #{TailCI.declared_desc(decl)}"
      else
        "no measured nonzero tail in the window: lead-time found no successful post-merge run for any " \
          "of its #{n} measured landing(s) (no post-merge CI seen; #{TailCI::INFERRED})"
      end
    end

    # The candidate with the largest sum: the five phases, then tail when it
    # is a candidate. Ties go to the earlier candidate, so a phase beats tail.
    def biggest(phase_stats, tail_stats, decl = nil)
      cands = PHASES.filter_map { |p| (s = phase_stats[p]["sum_s"]) && [p, s] }
      tail = tail_candidacy(tail_stats, decl)
      cands << ["tail", tail_stats["sum_s"]] if tail["tail_candidate"]
      best = cands.reduce(nil) { |b, c| b.nil? || c[1] > b[1] ? c : b }
      return { "phase" => nil, "reason" => "no phase measured in the window" }.merge(tail) unless best

      { "phase" => best[0], "sum_s" => best[1], "lever" => LEVERS.fetch(best[0]) }.merge(tail)
    end

    # Foreign landings (DND-1531) are out of the phase stats and the biggest
    # pick; the forge totals (lead, code, tail) still include them.
    # idle_workflow: the repo's declared post-merge workflow, "none", or nil
    # (absent: the window inference), DND-1614. Anything else raises
    # DeclarationError. repo: the name the reasons use (default: the rows').
    def summarize(rows, idle_workflow: nil, repo: nil)
      decl = TailCI.declare(idle_workflow, repo || rows.first&.dig("repo") || "the repo")
      local = rows.reject { |r| Origin.foreign?(r) }
      ph = phases(local)
      tot = totals(rows, decl)
      org = origins(rows)
      big = biggest(ph, totals(local, decl)["tail"], decl)
      if big["phase"].nil? && local.empty? && !rows.empty?
        big["reason"] = "every landing in the window was worked on another machine (foreign: #{org['foreign']})"
      end
      { "rows" => rows.size, "foreign" => org["judged"].zero? ? nil : org["foreign"],
        "origin" => org.except("judged"), "phases" => ph, "biggest" => big, "totals" => tot,
        "unattributed" => unattributed(local), "flows" => flows(local),
        "tail_ci" => TailCI.report(decl, rows) }
    end

    # Code time attributed to no phase (DND-1501): per row with a measured
    # code_s, code minus its measured phases, summed. A phase that is n/a
    # leaves its time here, so a future anchor gap shows as a number instead
    # of vanishing. n_na: rows with no code_s (unticketed, no stamp). Sums
    # are null, never 0, when no row has code_s.
    def unattributed(rows)
      coded = rows.select { |r| r["code_s"].is_a?(Numeric) }
      gaps = coded.map { |r| r["code_s"] - PHASES.sum { |p| (s = r.dig("phases", p, "s")).is_a?(Numeric) ? s : 0 } }
      { "sum_s" => coded.empty? ? nil : gaps.sum, "code_s" => coded.empty? ? nil : coded.sum { |r| r["code_s"] },
        "n" => coded.size, "n_na" => rows.size - coded.size }
    end

    # How many rows each anchor map measured (DND-1501). A row ingested
    # before DND-1501 has no phase_flow: unrecorded.
    def flows(rows)
      out = FLOWS.to_h { |f| [f, 0] }.merge("unrecorded" => 0)
      rows.each { |r| out[FLOWS.include?(r["phase_flow"]) ? r["phase_flow"] : "unrecorded"] += 1 }
      out
    end

    # Where the window's landings were worked. foreign_units names each
    # foreign landing. A row with no origin decided is unknown with its
    # reason: undecided at ingest, a watch row, or one ingested before
    # DND-1531. "foreign" is null (not 0) when no row was decided.
    def origins(rows)
      unknown = rows.reject { |r| [Origin::LOCAL, Origin::FOREIGN].include?(r["origin"]) }
      foreign = rows.select { |r| Origin.foreign?(r) }
      reasons = unknown.map { |r| generic(unknown_reason(r), r) }.tally
                       .sort_by { |r, n| [-n, r] }.first(TOP_REASONS).map { |r, n| { "reason" => r, "count" => n } }
      { "local" => rows.count { |r| r["origin"] == Origin::LOCAL }, "foreign" => foreign.size,
        "foreign_units" => foreign.map { |r| Landing.unit_desc(r) }, "unknown" => unknown.size,
        "unknown_reasons" => reasons, "judged" => rows.size - unknown.size }
    end

    def unknown_reason(row)
      return "watch mode: where a landing was worked is not measured" if row["mode"] == "watch"
      return row["origin_na"] if row["origin_na"]

      "no origin in the ledger row (ingested before DND-1531)"
    end
  end

  module Guards
    module_function

    # reverts: a Source whose items are revert subjects in the window, or nil
    # when the window is empty (nothing to look over).
    def compute(rows, reverts:)
      {
        "critic_block_rate" => rate(rows, "critic_blocks", "critic_rounds", "no critic rounds measured in the window"),
        "gate_red_rate" => rate(rows, "gate_red", "gate_runs", "no #{GATE_RUN_DESC} measured in the window"),
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
