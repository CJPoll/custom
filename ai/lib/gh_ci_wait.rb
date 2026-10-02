# frozen_string_literal: true

require "json"

# gh_ci_wait.rb -- DOMAIN for ai/bin/gh-ci-wait (DND-1708, DND-1706).
#
# Pure rules, no I/O: read one `gh api -i` response into a Read, judge CI
# state from a response body, and decide how long to wait before the next
# read. The manager loop and the gh adapter are in ai/lib/gh_ci_wait_io.rb.
#
# The two defects this exists to close:
#   * A rate-limited read (HTTP 403/429) was treated as terminal by one watcher
#     and as "no runs" by another. Here it is its own kind, :rate_limited, with
#     the time it clears; it is never :ok and never empty.
#   * Default-cadence watchers (`gh run watch` polls every 3 s, `gh pr checks
#     --watch` every 10 s) exhausted the owner's 5000/h core budget. Here the
#     interval has a floor (MIN_INTERVAL) and errors back off.
module GhCiWait
  MIN_INTERVAL = 30
  DEFAULT_INTERVAL = 60
  DEFAULT_MAX = 570
  MAX_BACKOFF = 300
  # GitHub's documented wait for a secondary limit that sends no Retry-After.
  SECONDARY_FALLBACK_S = 60
  SUCCESS_CONCLUSIONS = %w[success skipped neutral].freeze
  # gh-athena's refusals that no re-read can fix (its `die` texts).
  GH_ATHENA_PERMANENT = /missing App ID|missing private key|has no installation|not found\. Fix: install|cannot load|JWT signing failed/.freeze

  # A usage error: a key that is malformed for its type. Carries its Fix.
  class Usage < StandardError
    attr_reader :fix

    def initialize(message, fix)
      super(message)
      @fix = fix
    end
  end

  # A 2xx body that does not hold what the read asked for. Never read as empty.
  class Unreadable < StandardError; end

  Read = Struct.new(:kind, :status, :body, :resource, :reset_at, :secondary, :detail, keyword_init: true)
  State = Struct.new(:state, :total, :pending, :failed, :summary, keyword_init: true)

  module_function

  # parse(stdout:, stderr:, now:) -> Read. stdout is `gh api -i` output.
  # kind: :ok, :rate_limited, :auth, :not_found or :error.
  def parse(stdout:, stderr:, now:)
    status, headers, body = split_http(stdout.to_s)
    err = stderr.to_s.strip
    return parse_without_status(err, now) if status.nil?

    message = json_message(body)
    if status.between?(200, 299)
      begin
        return Read.new(kind: :ok, status: status, body: JSON.parse(body))
      rescue JSON::ParserError
        return Read.new(kind: :error, status: status, detail: "HTTP #{status} body is not JSON")
      end
    end
    if status == 429 || (status == 403 && rate_limited?(headers, message))
      return rate_limited_read(status, headers, message, now)
    end

    detail = "HTTP #{status}: #{message || err.lines.first.to_s.strip}"
    kind = case status
           when 401, 403 then :auth
           when 404, 422 then :not_found
           else :error
           end
    Read.new(kind: kind, status: status, detail: detail)
  end

  # -> [status Integer or nil, headers Hash (downcased keys), body String]
  def split_http(text)
    head, body = text.split(/\r?\n\r?\n/, 2)
    first, *lines = head.to_s.split(/\r?\n/)
    m = first.to_s.match(%r{\AHTTP/[\d.]+\s+(\d{3})})
    return [nil, {}, ""] unless m

    headers = {}
    lines.each do |line|
      k, v = line.split(":", 2)
      headers[k.strip.downcase] = v.to_s.strip if v
    end
    [m[1].to_i, headers, body.to_s]
  end

  def json_message(body)
    msg = JSON.parse(body)["message"]
    msg.is_a?(String) ? msg : nil
  rescue JSON::ParserError, TypeError
    nil
  end

  def rate_limited?(headers, message)
    headers["x-ratelimit-remaining"] == "0" || headers.key?("retry-after") ||
      message.to_s.match?(/rate limit/i)
  end

  def rate_limited_read(status, headers, message, now)
    secondary = message.to_s.match?(/secondary/i)
    reset_at = if headers["retry-after"].to_s.match?(/\A\d+\z/)
                 now + headers["retry-after"].to_i
               elsif headers["x-ratelimit-reset"].to_s.match?(/\A\d+\z/) && headers["x-ratelimit-remaining"] == "0"
                 [Time.at(headers["x-ratelimit-reset"].to_i).utc, now + 1].max
               else
                 now + SECONDARY_FALLBACK_S
               end
    Read.new(kind: :rate_limited, status: status, resource: headers["x-ratelimit-resource"] || "unknown",
             reset_at: reset_at, secondary: secondary,
             detail: "HTTP #{status}: #{message || 'rate limited'}")
  end

  # No status line: gh never reached a response (network, missing binary), or
  # gh printed only its stderr summary. A rate-limit summary is still a limit.
  def parse_without_status(err, now)
    if err.match?(/rate limit/i)
      return Read.new(kind: :rate_limited, resource: "unknown", reset_at: now + SECONDARY_FALLBACK_S,
                      secondary: err.match?(/secondary/i), detail: err.lines.first.to_s.strip)
    end
    # The wrapper refused before any request for a reason a re-read cannot fix
    # (no App config, no installation): auth. Its other refusals (could not
    # reach the API, a token mint that failed) can be transient: :error.
    if err.start_with?("gh-athena: ") && err.match?(GH_ATHENA_PERMANENT)
      return Read.new(kind: :auth, detail: err.lines.first.to_s.strip)
    end

    Read.new(kind: :error, detail: "no HTTP response: #{err.empty? ? '(no output)' : err.lines.first.strip}")
  end

  # checks_state(body, min_checks:, runs_body:) -> State for GET
  # commits/<sha>/check-runs. runs_body is the sha's workflow-runs list
  # (runs_path_for), read only when needs_runs? says so; nil judges every row.
  def checks_state(body, min_checks:, runs_body: nil)
    rows = check_rows!(body)
    return State.new(state: :pending, total: 0, pending: 0, failed: [], summary: "no check-runs on the sha yet") if rows.empty?

    sorted = supersede(rows, runs_body.nil? ? nil : runs_by_suite!(runs_body))
    judged = sorted[:judged]
    open = judged.reject { |r| r["status"] == "completed" }
    awaiting = sorted[:awaiting]
    failed = judged.select { |r| r["status"] == "completed" && !SUCCESS_CONCLUSIONS.include?(r["conclusion"]) }
                   .map { |r| "#{r['name']}(#{r['conclusion']})" }
    current = judged.size
    old = superseded_words(sorted[:superseded])
    if open.any? || awaiting.any?
      wait = awaiting.empty? ? "" : ", and #{awaiting.size} older non-green runs await their check's newer run"
      return State.new(state: :pending, total: current, pending: open.size + awaiting.size, failed: failed,
                       summary: "#{open.size} of #{current} check-runs not completed#{wait}#{old}")
    end
    if current < min_checks
      return State.new(state: :pending, total: current, pending: 0, failed: failed,
                       summary: "#{current} of at least #{min_checks} check-runs reported#{old}")
    end
    if failed.any?
      return State.new(state: :failure, total: current, pending: 0, failed: failed,
                       summary: "#{failed.size} of #{current} check-runs did not succeed: #{failed.join(', ')}#{old}")
    end
    State.new(state: :success, total: current, pending: 0, failed: [],
              summary: "all #{current} check-runs succeeded#{old}")
  end

  def check_rows!(body)
    rows = body.is_a?(Hash) ? body["check_runs"] : nil
    raise Unreadable, "check-runs body has no check_runs array" unless rows.is_a?(Array)

    total_count = body["total_count"].to_i
    if total_count > rows.size
      raise Unreadable, "check-runs total_count #{total_count} exceeds the #{rows.size} rows read (one page of 100); " \
                        "the set is incomplete"
    end
    rows
  end

  # ---- superseded runs (DND-1727) --------------------------------------------
  # `filter=latest` keeps one row per check name WITHIN a check suite, not
  # across suites. A force-push that cancels a duplicate run leaves both runs'
  # check-runs on the head (gen_saas PR #726: 10 cancelled + 10 success read
  # as "10 of 20 did not succeed"). The rule is gh-athena's merge guard's
  # (DND-1140, GMG_ROLLUP_JUDGE in ai/lib/gh-merge-guard.sh), applied to the
  # REST shapes this tool reads. It is a second copy because the guard is jq
  # over GraphQL and is a refusal, while a waiter also needs a pending outcome;
  # self-test.sh pins the two to the same verdict on the PR #726 case.
  #   * A check's identity is (app id, workflow id, event, check name), so a
  #     push run and a pull_request run of one workflow are both current, and
  #     two workflows with a same-named job never fold.
  #   * Within an identity the runs are grouped by check suite; the suite of
  #     the newest workflow run (created_at, then run id) is current, and every
  #     run in it is judged.
  #   * Older suites' runs are superseded only when every current run of that
  #     identity completed SUCCESS (a newer skipped or neutral run proves
  #     nothing). While a current run is still open they await it (pending);
  #     once the current runs completed without that, they are judged.
  #   * A row whose identity cannot be read (no name, suite or app; a
  #     non-Actions app; an Actions suite the runs list does not hold) is
  #     judged on its own, never folded. This is stricter than the guard, which
  #     orders a non-Actions app's suites by start time.

  # needs_runs?(target, body) -> true when some (app, check name) has runs
  # from more than one check suite, so only the runs list can tell which is
  # current. Otherwise nothing can be superseded and one read is enough.
  def needs_runs?(target, body)
    return false unless target.mode == :checks

    check_rows!(body).group_by { |r| [r.dig("app", "id"), r["name"]] }
                     .any? { |_, rs| rs.map { |r| r.dig("check_suite", "id") }.uniq.size > 1 }
  end

  # runs_by_suite!(runs_body) -> { check_suite_id => run }.
  def runs_by_suite!(runs_body)
    runs = runs_body.is_a?(Hash) ? runs_body["workflow_runs"] : nil
    raise Unreadable, "runs body has no workflow_runs array" unless runs.is_a?(Array)
    if runs_body["total_count"].to_i > runs.size
      raise Unreadable, "runs total_count #{runs_body['total_count']} exceeds the #{runs.size} rows read " \
                        "(one page of 100); a newer run may be on another page"
    end

    runs.select { |r| r["check_suite_id"].is_a?(Integer) }.to_h { |r| [r["check_suite_id"], r] }
  end

  # supersede(rows, by_suite) -> { judged:, awaiting:, superseded: [[row, run]] }.
  def supersede(rows, by_suite)
    out = { judged: [], awaiting: [], superseded: [] }
    return out.merge(judged: rows) if by_suite.nil?

    alone, keyed = rows.partition { |r| check_identity(r, by_suite).nil? }
    out[:judged].concat(alone)
    keyed.group_by { |r| check_identity(r, by_suite) }.each_value do |group|
      suites = group.group_by { |r| r.dig("check_suite", "id") }
                    .sort_by { |suite, _| run_order(by_suite.fetch(suite)) }
      current = suites.last.last
      out[:judged].concat(current)
      older = suites[0...-1].flat_map(&:last)
      if current.all? { |r| r["status"] == "completed" && r["conclusion"] == "success" }
        older.each { |r| out[:superseded] << [r, by_suite.fetch(r.dig("check_suite", "id"))] }
      elsif current.any? { |r| r["status"] != "completed" }
        older.each { |r| (green?(r) ? out[:judged] : out[:awaiting]) << r }
      else
        out[:judged].concat(older)
      end
    end
    out
  end

  def check_identity(row, by_suite)
    name = row["name"]
    suite = row.dig("check_suite", "id")
    app = row.dig("app", "id")
    return nil unless name.is_a?(String) && !name.empty? && suite.is_a?(Integer) && app.is_a?(Integer)
    return nil unless row.dig("app", "slug") == "github-actions"

    run = by_suite[suite]
    return nil unless run && run["workflow_id"].is_a?(Integer) && run["event"].is_a?(String) && !run["event"].empty?

    [app, run["workflow_id"], run["event"], name]
  end

  def green?(row)
    row["status"] == "completed" && SUCCESS_CONCLUSIONS.include?(row["conclusion"])
  end

  def run_order(run)
    [run["created_at"].to_s, run["id"].to_i]
  end

  # "; superseded by a newer run of the same check: run 1 CI pull_request (a(cancelled), ...)"
  def superseded_words(pairs)
    return "" if pairs.empty?

    runs = pairs.group_by { |_, run| run["id"] }.map do |id, ps|
      run = ps.first.last
      "run #{id} #{run['name']} #{run['event']} (#{ps.map { |r, _| "#{r['name']}(#{r['conclusion']})" }.join(', ')})"
    end
    "; #{pairs.size} superseded by a newer run of the same check: #{runs.join('; ')}"
  end

  # run_state(run, sha:) -> State for one workflow run. sha nil: not pinned.
  def run_state(run, sha:)
    status = run.is_a?(Hash) ? run["status"] : nil
    raise Unreadable, "run body has no status" unless status.is_a?(String)

    id = run["id"]
    head = run["head_sha"].to_s
    if sha && head != sha
      return State.new(state: :wrong_head, summary: "run #{id} is for #{head[0, 12]}, not the pinned #{sha[0, 12]}")
    end
    return State.new(state: :pending, summary: "run #{id} #{status}") unless status == "completed"

    conclusion = run["conclusion"].to_s
    if SUCCESS_CONCLUSIONS.include?(conclusion)
      State.new(state: :success, summary: "run #{id} completed #{conclusion}")
    else
      State.new(state: :failure, summary: "run #{id} completed #{conclusion.empty? ? '(no conclusion)' : conclusion}")
    end
  end

  # pick_run(body, workflow:, sha:) -> the newest run of that workflow (its
  # name, or its file name) on that sha, or nil when none is listed yet.
  def pick_run(body, workflow:, sha:)
    workflow_runs!(body, workflow: workflow, sha: sha).max_by { |r| run_order(r) }
  end

  # workflow_runs!(body, workflow:, sha:) -> every run of that workflow on that sha.
  def workflow_runs!(body, workflow:, sha:)
    runs = body.is_a?(Hash) ? body["workflow_runs"] : nil
    raise Unreadable, "runs body has no workflow_runs array" unless runs.is_a?(Array)
    if body["total_count"].to_i > runs.size
      raise Unreadable, "runs total_count #{body['total_count']} exceeds the #{runs.size} rows read (one page of 100); " \
                        "the newest run may be on another page"
    end

    runs.select { |r| r["head_sha"] == sha && workflow_match?(r, workflow) }
  end

  # workflow_state(body, target) -> State of the workflow on the sha: the
  # newest run per event is current (a push run and a pull_request run are
  # both current, as in the merge guard), and every older run is superseded
  # and named (DND-1727). Any current run open: pending; any current run
  # completed without success: failure.
  def workflow_state(body, target)
    matched = workflow_runs!(body, workflow: target.workflow, sha: target.sha)
    return State.new(state: :pending, summary: no_run_summary(body, target)) if matched.empty?

    current = matched.group_by { |r| r["event"].to_s }.values.map { |rs| rs.max_by { |r| run_order(r) } }
                     .sort_by { |r| run_order(r) }
    states = current.map { |r| run_state(r, sha: target.sha) }
    older = (matched - current).sort_by { |r| run_order(r) }
    old = if older.empty?
            ""
          else
            "; superseded by a newer run of the workflow: " +
              older.map { |r| "run #{r['id']} #{r['event']} (#{r['status']}/#{r['conclusion'] || '-'})" }.join(", ")
          end
    state = %i[wrong_head pending failure].find { |s| states.any? { |st| st.state == s } } || :success
    State.new(state: state, summary: states.map(&:summary).join("; ") + old)
  end

  def workflow_match?(run, workflow)
    run["name"] == workflow || File.basename(run["path"].to_s) == workflow
  end

  # next_wait(...) -> [:sleep, seconds], [:stop] (deadline reached) or
  # [:give_up] (rate limited past the deadline: polling into it only burns
  # the budget, and the caller must say COULD-NOT-LOOK with the reset time).
  def next_wait(read:, now:, deadline:, interval:, errors_in_row:)
    if read.kind == :rate_limited
      # Never re-read a limit sooner than MIN_INTERVAL: a Retry-After of 0, or
      # a reset our clock already passed, would otherwise poll into the limit
      # once a second, the failure this tool exists to stop.
      wait = [(read.reset_at - now).ceil, MIN_INTERVAL].max
      return [:give_up] if now + wait > deadline

      return [:sleep, wait]
    end
    left = (deadline - now).floor
    return [:stop] if left <= 0

    base = interval
    base = [interval * (2**[errors_in_row - 1, 4].min), MAX_BACKOFF].min if read.kind == :error && errors_in_row > 1
    [:sleep, [base, left].min]
  end

  # ---- argument validation: a wrongly computed key is an error -------------
  def repo!(value)
    v = value.to_s
    return v if v.match?(%r{\A[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+\z})

    raise Usage.new("--repo must be OWNER/NAME, got #{v.inspect}", "pass the full repo, e.g. --repo CJPoll/gen_saas")
  end

  def sha!(value)
    v = value.to_s.downcase
    return v if v.match?(/\A[0-9a-f]{40}\z/)

    raise Usage.new("--sha must be a full 40-hex commit sha, got #{value.to_s.inspect}",
                    "pass the pushed head's full sha (git rev-parse HEAD); a prefix can match the wrong commit")
  end

  def run_id!(value)
    v = value.to_s
    return v if v.match?(/\A\d+\z/)

    raise Usage.new("--run-id must be a numeric run id, got #{v.inspect}", "pass the run's databaseId")
  end

  def interval!(value)
    n = positive_int(value, "--interval")
    return n if n >= MIN_INTERVAL

    raise Usage.new("--interval #{n} is under the #{MIN_INTERVAL} s floor (DND-1706: fast polls exhaust the API budget)",
                    "pass --interval #{MIN_INTERVAL} or more, or omit it for #{DEFAULT_INTERVAL}")
  end

  def max!(value)
    positive_int(value, "--max")
  end

  def min_checks!(value)
    positive_int(value, "--min-checks")
  end

  def positive_int(value, flag)
    v = value.to_s
    return v.to_i if v.match?(/\A\d+\z/) && v.to_i.positive?

    raise Usage.new("#{flag} must be a positive integer, got #{v.inspect}", "pass #{flag} N with N >= 1")
  end

  # ---- what to wait on, and how to read and judge it -----------------------
  Target = Struct.new(:mode, :repo, :sha, :id, :workflow, :min_checks, keyword_init: true)

  # The one GET each mode reads. Check-runs: `filter=latest` keeps one row per
  # check name (a re-run replaces it, never doubles it).
  def path_for(target)
    case target.mode
    when :checks then "repos/#{target.repo}/commits/#{target.sha}/check-runs?filter=latest&per_page=100"
    when :run_id then "repos/#{target.repo}/actions/runs/#{target.id}"
    when :run_workflow then "repos/#{target.repo}/actions/runs?head_sha=#{target.sha}&per_page=100"
    else raise ArgumentError, "unknown mode #{target.mode.inspect}"
    end
  end

  # The sha's workflow-runs list, read in checks mode when needs_runs? says so.
  def runs_path_for(target)
    "repos/#{target.repo}/actions/runs?head_sha=#{target.sha}&per_page=100"
  end

  # judge(target, body, runs_body = nil) -> State. Raises Unreadable on a body
  # that does not hold what the mode asked for.
  def judge(target, body, runs_body = nil)
    case target.mode
    when :checks then checks_state(body, min_checks: target.min_checks || 1, runs_body: runs_body)
    when :run_id then run_state(body, sha: target.sha)
    when :run_workflow then workflow_state(body, target)
    else raise ArgumentError, "unknown mode #{target.mode.inspect}"
    end
  end

  # Names the workflows that DO have runs on the sha, so a mistyped --workflow
  # reads as "matches none of these", not as an endless "not listed yet".
  def no_run_summary(body, target)
    seen = body["workflow_runs"].select { |r| r["head_sha"] == target.sha }
                                .map { |r| "#{r['name']} (#{File.basename(r['path'].to_s)})" }.uniq.sort
    saw = seen.empty? ? "no runs of any workflow yet" : "runs seen on it: #{seen.join(', ')}"
    "no '#{target.workflow}' run on #{target.sha[0, 12]} listed yet; #{saw}"
  end

  def describe(target)
    case target.mode
    when :checks then "checks repo=#{target.repo} sha=#{target.sha[0, 12]}"
    when :run_id then "run repo=#{target.repo} id=#{target.id}#{target.sha ? " sha=#{target.sha[0, 12]}" : ''}"
    when :run_workflow then "run repo=#{target.repo} workflow='#{target.workflow}' sha=#{target.sha[0, 12]}"
    end
  end
end
