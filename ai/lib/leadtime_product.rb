# frozen_string_literal: true

# leadtime_product -- the DOMAIN of the lead-time product-repo lane (DND-1540).
#
# An improve run may change an improve repo R other than custom (the owner's
# grant, 2026-10-01). It works R in a per-run lane, opens a PR as Athena, and a
# LATER run lands that PR through R's normal bar, because CI outlives a
# 50-minute session. These are the rules that work turns on: lane and branch
# names, the run's manifest, the product-PR store and its fold, what a sweep
# does with one PR, how integration-gate / locked-merge / confirm-merged exits
# read, the deploy verdict, and when a lane's branch is stranded.
#
# Pure: no file, process, network or clock access. The side effects and the
# manager are ai/lib/leadtime_product_io.rb; the CLI is ai/bin/leadtime-product.
# Every refusal raises LeadTimeProduct::Error carrying the Fix: the caller prints.

require "json"
require "time"

module LeadTimeProduct
  # A refusal, with the instruction that makes the next attempt pass.
  class Error < StandardError
    attr_reader :fix

    def initialize(message, fix)
      super(message)
      @fix = fix
    end
  end

  NAME_RE  = /\A[A-Za-z0-9][A-Za-z0-9._-]*\z/.freeze
  PHASE_RE = /\A[a-z][a-z0-9-]{0,31}\z/.freeze
  UTC_RE   = /\A\d{8}T\d{6}Z\z/.freeze
  RUN_RE   = /\Arun-\d{8}T\d{6}Z-\d+\z/.freeze
  SHA_RE   = /\A[0-9a-f]{40}\z/.freeze

  module_function

  # ── names ──────────────────────────────────────────────────────────────────

  # The branch a product lane is cut on: leadtime/<repo>-<phase>-<utc>.
  def branch_name(repo, phase, utc)
    name!(repo, "repo")
    unless phase.is_a?(String) && phase.match?(PHASE_RE)
      raise Error.new("phase #{phase.inspect} is not a lead-time phase name (#{PHASE_RE.source})",
                      "pass --phase as the ledger's phase name, lower case, e.g. verify or tail.")
    end
    unless utc.is_a?(String) && utc.match?(UTC_RE)
      raise Error.new("utc stamp #{utc.inspect} is not YYYYMMDDTHHMMSSZ", "this is a caller bug; pass the cut time in UTC.")
    end
    "leadtime/#{repo}-#{phase}-#{utc}"
  end

  def name!(value, what)
    return value if value.is_a?(String) && value.match?(NAME_RE)

    raise Error.new("#{what} #{value.inspect} is not a valid name", "use the repo's name as ai/bin/lead-time-repos prints it.")
  end

  # ── the run's manifest (written by scripts/athena-leadtime-run.sh) ─────────

  RepoLane = Struct.new(:name, :path, :common, :lanes_dir, :lane, :lock, :idle_workflow, keyword_init: true)
  IDLE_WORKFLOW_RE = /\A(none|[A-Za-z0-9][A-Za-z0-9_.-]*\.ya?ml)\z/.freeze

  Manifest = Struct.new(:run_id, :state_dir, :repos, keyword_init: true) do
    def repo(name)
      found = repos.find { |r| r.name == name }
      return found if found

      have = repos.map(&:name)
      raise Error.new("repo #{name.inspect} has no product lane in this run (this run's product repos: #{have.empty? ? 'none' : have.join(', ')})",
                      "pass --repo as one of this run's product repos: an improve repo other than custom on this machine (ai/bin/lead-time-repos).")
    end
  end

  def parse_manifest(text)
    doc = begin
      JSON.parse(text)
    rescue JSON::ParserError => e
      raise Error.new("the product manifest is not JSON (#{e.message.lines.first.to_s.strip})",
                      "the runner writes it; re-run from a cron tick, never by hand.")
    end
    bad_manifest("is not an object") unless doc.is_a?(Hash)
    run_id = doc["run_id"]
    bad_manifest("run_id #{run_id.inspect} is not run-<utc>-<pid>") unless run_id.is_a?(String) && run_id.match?(RUN_RE)
    state = doc["state_dir"]
    abs!(state, "state_dir")
    list = doc["repos"]
    bad_manifest("repos is not a list") unless list.is_a?(Array)
    repos = list.map { |r| repo_lane(r, run_id) }
    dupes = repos.map(&:name).tally.select { |_, n| n > 1 }.keys
    bad_manifest("names #{dupes.join(', ')} more than once") unless dupes.empty?
    Manifest.new(run_id: run_id, state_dir: state, repos: repos)
  end

  def repo_lane(r, run_id)
    bad_manifest("a repo entry is not an object") unless r.is_a?(Hash)
    name!(r["name"], "manifest repo")
    %w[path common lanes_dir lane lock].each { |k| abs!(r[k], "#{r['name']}.#{k}") }
    unless r["lane"] == File.join(r["lanes_dir"], run_id) && r["lock"] == "#{r['lane']}.lock"
      bad_manifest("#{r['name']}: lane and lock must be <lanes_dir>/#{run_id} and its .lock")
    end
    idle = r["idle_workflow"]
    unless idle.nil? || (idle.is_a?(String) && idle.match?(IDLE_WORKFLOW_RE))
      bad_manifest("#{r['name']}: idle_workflow #{idle.inspect} is not a workflow file name or none")
    end
    RepoLane.new(name: r["name"], path: r["path"], common: r["common"], lanes_dir: r["lanes_dir"],
                 lane: r["lane"], lock: r["lock"], idle_workflow: idle)
  end

  # ── the landing bar: R's post-merge workflow ────────────────────────────────

  # locked-merge's idle flag for R (athena:merge-boarding -> The merge bar: on
  # gen_saas pass --require-idle-workflow post-merge.yml). Undeclared refuses
  # the landing: deny by default, never a merge without the repo's own bar.
  def idle_args(idle)
    return [] if idle == "none"
    return ["--require-idle-workflow", idle] if idle.is_a?(String) && idle.match?(IDLE_WORKFLOW_RE)

    raise Error.new("the repo declares no idle_workflow, so its merge bar (locked-merge --require-idle-workflow) is unknown; nothing lands",
                    "add \"idle_workflow\": \"<its post-merge workflow file>\" (or \"none\" when it has none) to the repo's entry in this machine's lead-time config (ai/bin/lead-time-repos --help).")
  end

  # The latest run of R's post-merge workflow on main: a failed deploy stops
  # the line (merge-boarding: on a failed deploy, merge nothing but the fix or
  # the revert). -> a reason to hold, or nil. Busy is locked-merge's to wait on.
  def base_deploy_hold(runs)
    latest = Array(runs).find { |r| r["status"] == "completed" }
    return nil unless latest && DEPLOY_FAILED.include?(latest["conclusion"].to_s)

    "the latest post-merge run on main (#{latest['headSha'].to_s[0, 12]}) concluded #{latest['conclusion']}"
  end

  # locked-merge prints "WARN base deploy ... concluded <x>; merging anyway" when
  # the base's deploy did not succeed. -> that line, or nil.
  def merge_warning(output)
    output.to_s.lines.find { |l| l.start_with?("WARN base deploy") }&.strip
  end

  def abs!(value, what)
    return if value.is_a?(String) && value.start_with?("/") && !value.include?("\n")

    bad_manifest("#{what} #{value.inspect} is not an absolute path")
  end

  def bad_manifest(why)
    raise Error.new("the product manifest #{why}", "the runner writes it; this is a runner bug, read scripts/athena-leadtime-run.sh.")
  end

  # ── the store: <state>/product-prs.jsonl, append-only events ────────────────

  # Every event names its repo and PR. The fields each kind requires.
  EVENT_FIELDS = {
    "opened" => %w[url phase branch head run_id],
    "head" => %w[head],
    "closed" => %w[reason],
    "merged" => %w[merge_sha],
    "deployed" => [],
    "no-deploy" => [],
    "revert-owed" => %w[reason]
  }.freeze
  STATUS_OF = { "opened" => "open", "head" => "open", "closed" => "closed", "merged" => "merged",
                "deployed" => "deployed", "no-deploy" => "no-deploy", "revert-owed" => "revert-owed" }.freeze

  # -> a Hash ready for one JSON line. Raises on an unknown kind or a missing field.
  def event(kind, at:, repo:, pr:, **fields)
    need = EVENT_FIELDS[kind]
    raise Error.new("unknown product-PR event #{kind.inspect}", "use one of #{EVENT_FIELDS.keys.join(', ')}.") unless need

    name!(repo, "event repo")
    raise Error.new("event PR #{pr.inspect} is not a positive integer", "pass the PR number.") unless pr.is_a?(Integer) && pr.positive?

    fields = fields.transform_keys(&:to_s)
    missing = need.reject { |k| fields[k].is_a?(String) && !fields[k].empty? }
    raise Error.new("a #{kind} event lacks #{missing.join(', ')}", "this is a caller bug; pass every field.") unless missing.empty?

    { "event" => kind, "at" => at, "repo" => repo, "pr" => pr }.merge(fields)
  end

  # One stored line -> its event Hash. A line that is not an event is an error
  # naming its line number: an unreadable store is never an empty one.
  def parse_line(line, number)
    doc = JSON.parse(line)
    raise Error.new("product-prs.jsonl line #{number} is not an object", fix_store) unless doc.is_a?(Hash)

    kind = doc["event"]
    raise Error.new("product-prs.jsonl line #{number}: unknown event #{kind.inspect}", fix_store) unless EVENT_FIELDS.key?(kind)

    doc
  rescue JSON::ParserError
    raise Error.new("product-prs.jsonl line #{number} is not JSON", fix_store)
  end

  def fix_store = "read the named line of <state>/product-prs.jsonl; it is append-only, so repair or remove only that line."

  PrState = Struct.new(:repo, :pr, :url, :phase, :branch, :head, :status, :merge_sha, :merged_at, :opened_at, :reason,
                       keyword_init: true)

  # Events (oldest first) -> one PrState per (repo, pr), in first-seen order.
  def fold(events)
    by = {}
    events.each do |e|
      key = [e["repo"], e["pr"]]
      if e["event"] == "opened"
        by[key] = PrState.new(repo: e["repo"], pr: e["pr"], url: e["url"], phase: e["phase"], branch: e["branch"],
                              head: e["head"], status: "open", opened_at: e["at"])
        next
      end
      s = by[key] or raise Error.new("product-prs.jsonl has a #{e['event']} event for #{e['repo']}##{e['pr']}, which was never opened",
                                     fix_store)
      s.status = STATUS_OF.fetch(e["event"])
      s.head = e["head"] if e["event"] == "head"
      if e["event"] == "merged"
        s.merge_sha = e["merge_sha"]
        s.merged_at = e["at"]
      end
      s.reason = e["reason"] if e["reason"]
    end
    by.values
  end

  def open_count(states) = states.count { |s| s.status == "open" }

  # ── CI: GitHub's statusCheckRollup ─────────────────────────────────────────

  GREEN = %w[SUCCESS NEUTRAL SKIPPED].freeze
  RED   = %w[FAILURE CANCELLED TIMED_OUT ACTION_REQUIRED STARTUP_FAILURE ERROR STALE].freeze

  # -> :green, :red, :pending or :none. Only every check concluded green is
  # green; no checks at all is :none, never green; an unknown value is pending.
  def ci_state(rollup)
    list = Array(rollup)
    return :none if list.empty?

    verdicts = list.map { |c| check_verdict(c) }
    return :red if verdicts.include?(:red)
    return :pending if verdicts.include?(:pending)

    :green
  end

  def check_verdict(c)
    if c["__typename"] == "StatusContext" || (c.key?("state") && !c.key?("conclusion"))
      st = c["state"].to_s.upcase
      return :green if st == "SUCCESS"
      return :red if %w[FAILURE ERROR].include?(st)

      return :pending
    end
    return :pending unless c["status"].to_s.upcase == "COMPLETED"

    con = c["conclusion"].to_s.upcase
    return :green if GREEN.include?(con)
    return :red if RED.include?(con)

    :pending
  end

  # ── what a sweep does with one open PR ─────────────────────────────────────

  Decision = Struct.new(:action, :reason)

  # view: { state: "OPEN"|"MERGED"|"CLOSED", head: sha, ci: ci_state }.
  def decide(pr, view, line_stopped:)
    case view[:state]
    when "MERGED" then return Decision.new(:record_merged, "merged outside the run")
    when "CLOSED" then return Decision.new(:record_closed, "closed outside the run")
    when "OPEN" then nil
    else
      raise Error.new("PR #{pr.repo}##{pr.pr} has forge state #{view[:state].inspect}", "read it with gh pr view #{pr.pr}; this sweep knows OPEN, MERGED and CLOSED.")
    end
    if view[:head] != pr.head
      return Decision.new(:wait, "head moved to #{view[:head].to_s[0, 12]} (the run pushed #{pr.head.to_s[0, 12]}); the run lands only a head it pushed")
    end

    case view[:ci]
    when :red then Decision.new(:close, "CI red on #{pr.head[0, 12]}")
    when :pending then Decision.new(:wait, "CI pending")
    when :none then Decision.new(:wait, "no CI reported on the head yet")
    when :green
      return Decision.new(:wait, "CI green, but the line is stopped: #{line_stopped}") if line_stopped

      Decision.new(:land, "CI green")
    else
      raise Error.new("unknown CI state #{view[:ci].inspect}", "this is a caller bug; pass ci_state's result.")
    end
  end

  # ── integration-gate (R's declared gate plus the standing judge) ───────────

  # A recorded BLOCK: the verdict reader's line (critic-review --verdict-for,
  # which integration-gate prints) or the judge's own.
  CRITIC_BLOCK_RE = /critic-review: (VERDICT BLOCK for|BLOCKED)/.freeze

  def gate_outcome(exit_code, output, head_before:, head_after:)
    case exit_code
    when 0
      return Decision.new(:merge, "INTEGRATION OK on #{head_after[0, 12]}") if head_before == head_after

      Decision.new(:rebased, "INTEGRATION OK on the rebased head #{head_after[0, 12]}; its CI must go green before it lands")
    when 4 then Decision.new(:close, "integration-gate exit 4 (blast-radius): merging causes a real-world action, a Cody-only step the cron never clears")
    when 3
      # Exit 3 is also a judge that failed open or could not look: only a
      # recorded BLOCK is a verdict on the change.
      return Decision.new(:close, "integration-gate exit 3: critic BLOCK on the head") if output.to_s.match?(CRITIC_BLOCK_RE)

      Decision.new(:retry, "integration-gate exit 3 with no recorded critic BLOCK (the judge did not deliver a verdict)")
    when 1 then Decision.new(:close, "integration-gate exit 1: the declared gate is RED on the integrated head")
    when 2
      return Decision.new(:close, "integration-gate exit 2: REBASE CONFLICT with main") if output.to_s.include?("REBASE CONFLICT")

      Decision.new(:retry, "integration-gate exit 2 (usage or environment, not a verdict on the change)")
    when 6 then Decision.new(:retry, "integration-gate exit 6: the gate did not run (no test slot)")
    else Decision.new(:retry, "integration-gate exit #{exit_code}")
    end
  end

  # locked-merge (see its --help): landed, try again later, or stop the line.
  def merge_outcome(exit_code)
    case exit_code
    when 0 then Decision.new(:merged, "locked-merge landed it")
    when 10 then Decision.new(:merged, "locked-merge landed it (the worktree stack teardown failed)")
    when 2, 3, 4, 5, 6, 9 then Decision.new(:retry, "locked-merge exit #{exit_code}: nothing landed")
    when 7 then Decision.new(:stop_line, "locked-merge exit 7: LANDED UNGATED (parent or tree mismatch)")
    when 8 then Decision.new(:stop_line, "locked-merge exit 8: the merge ran but the landing is not confirmed")
    else Decision.new(:stop_line, "locked-merge exit #{exit_code}: unknown outcome, never retried blind")
    end
  end

  def confirm_outcome(exit_code)
    return Decision.new(:confirmed, "confirm-merged confirmed it") if exit_code.zero?

    Decision.new(:stop_line, "confirm-merged exit #{exit_code}: the landing is not confirmed")
  end

  # ── deploy: the merge commit's post-merge runs ─────────────────────────────

  # A deploy workflow may be triggered by CI's completion (workflow_run), so
  # "CI finished and no deploy" is believed only this long after the last run
  # (or after the merge, when nothing ran at all).
  DEPLOY_SETTLE_S = 1800
  # Only these conclusions owe a revert. cancelled (a superseded run in a
  # concurrency group), skipped and neutral are not a verdict on the change.
  DEPLOY_FAILED = %w[failure timed_out startup_failure].freeze
  DEPLOY_NO_VERDICT = %w[cancelled skipped neutral stale].freeze

  # runs: gh run list --commit <sha> rows (name, status, conclusion, headSha,
  # updatedAt). deploy_re: ai/bin/lead-time's deploy rule (LEAD_TIME_DEPLOY_RE,
  # default "deploy"). Each workflow is judged on its LATEST run, so a re-run
  # or a superseding run decides. -> :pending, :success, :failed or :none (no
  # deploy verdict DEPLOY_SETTLE_S after CI finished, or after the merge).
  def deploy_state(runs, merge_sha, deploy_re, now:, merged_at: nil)
    mine = Array(runs).select { |r| r["headSha"] == merge_sha }
    return settled?([merged_at], now) ? :none : :pending if mine.empty?

    latest = mine.group_by { |r| r["name"].to_s }.values.map { |rs| rs.max_by { |r| parse_time(r["updatedAt"]) || Time.at(0) } }
    deploys = latest.select { |r| r["name"].to_s.match?(deploy_re) }
    return :pending if deploys.any? { |r| r["status"] != "completed" }
    return :failed if deploys.any? { |r| DEPLOY_FAILED.include?(r["conclusion"].to_s) }

    verdicts = deploys.reject { |r| DEPLOY_NO_VERDICT.include?(r["conclusion"].to_s) }
    return :success if !verdicts.empty? && verdicts.all? { |r| r["conclusion"] == "success" }
    return :pending unless verdicts.empty? # a conclusion this rule does not know
    return :pending unless latest.all? { |r| r["status"] == "completed" }

    settled?(mine.map { |r| parse_time(r["updatedAt"]) }, now) ? :none : :pending
  end

  # Every time is known and the newest is DEPLOY_SETTLE_S old.
  def settled?(times, now)
    !times.empty? && !times.include?(nil) && now - times.max >= DEPLOY_SETTLE_S
  end

  def parse_time(text)
    Time.iso8601(text.to_s)
  rescue ArgumentError
    nil
  end

  # ── a lane's branch at teardown ─────────────────────────────────────────────

  # :delete (its work is on origin/main), :awaiting (the tip is the head an
  # open improver PR records: awaiting landing, never STRANDED), or :stranded
  # (a commit that was never pushed to a recorded PR).
  def retire(tip:, on_main:, recorded_head:)
    return :delete if on_main
    return :awaiting if recorded_head && recorded_head == tip

    :stranded
  end

  # ── reporting ──────────────────────────────────────────────────────────────

  def summary(open_n, landed)
    "product_prs=#{open_n} landed=#{landed.empty? ? 'none' : landed.join(',')}"
  end

  # The PR body: the run's evidence, then the experiment trailer block when
  # the caller has one (DND-1529 supplies it; nil today).
  def pr_body(evidence, trailer)
    text = evidence.to_s.rstrip
    raise Error.new("the PR body (evidence) is empty", "write the change's before/after evidence to the --body-file.") if text.strip.empty?

    text += "\n\n#{trailer.rstrip}" if trailer && !trailer.strip.empty?
    "#{text}\n"
  end
end
