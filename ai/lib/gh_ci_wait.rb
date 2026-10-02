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
    if [403, 429].include?(status) && rate_limited?(headers, message)
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
    # The wrapper refused before any request (no App config, a failed token
    # mint): a re-read cannot fix that, so it is auth, not a transient error.
    return Read.new(kind: :auth, detail: err.lines.first.to_s.strip) if err.start_with?("gh-athena: ")

    Read.new(kind: :error, detail: "no HTTP response: #{err.empty? ? '(no output)' : err.lines.first.strip}")
  end

  # checks_state(body, min_checks:) -> State for GET commits/<sha>/check-runs.
  def checks_state(body, min_checks:)
    rows = body.is_a?(Hash) ? body["check_runs"] : nil
    raise Unreadable, "check-runs body has no check_runs array" unless rows.is_a?(Array)

    total_count = body["total_count"].to_i
    if total_count > rows.size
      raise Unreadable, "check-runs total_count #{total_count} exceeds the #{rows.size} rows read (one page of 100); " \
                        "the set is incomplete"
    end
    return State.new(state: :pending, total: 0, pending: 0, failed: [], summary: "no check-runs on the sha yet") if rows.empty?

    open = rows.reject { |r| r["status"] == "completed" }
    failed = rows.select { |r| r["status"] == "completed" && !SUCCESS_CONCLUSIONS.include?(r["conclusion"]) }
                 .map { |r| "#{r['name']}(#{r['conclusion']})" }
    if open.any?
      return State.new(state: :pending, total: rows.size, pending: open.size, failed: failed,
                       summary: "#{open.size} of #{rows.size} check-runs not completed")
    end
    if rows.size < min_checks
      return State.new(state: :pending, total: rows.size, pending: 0, failed: failed,
                       summary: "#{rows.size} of at least #{min_checks} check-runs reported")
    end
    if failed.any?
      return State.new(state: :failure, total: rows.size, pending: 0, failed: failed,
                       summary: "#{failed.size} of #{rows.size} check-runs did not succeed: #{failed.join(', ')}")
    end
    State.new(state: :success, total: rows.size, pending: 0, failed: [],
              summary: "all #{rows.size} check-runs succeeded")
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
    runs = body.is_a?(Hash) ? body["workflow_runs"] : nil
    raise Unreadable, "runs body has no workflow_runs array" unless runs.is_a?(Array)

    runs.select { |r| r["head_sha"] == sha && workflow_match?(r, workflow) }
        .max_by { |r| [r["created_at"].to_s, r["id"].to_i] }
  end

  def workflow_match?(run, workflow)
    run["name"] == workflow || File.basename(run["path"].to_s) == workflow
  end

  # next_wait(...) -> [:sleep, seconds], [:stop] (deadline reached) or
  # [:give_up] (rate limited past the deadline: polling into it only burns
  # the budget, and the caller must say COULD-NOT-LOOK with the reset time).
  def next_wait(read:, now:, deadline:, interval:, errors_in_row:)
    if read.kind == :rate_limited
      return [:give_up] if read.reset_at > deadline

      return [:sleep, [(read.reset_at - now).ceil, 1].max]
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

    raise Usage.new("--id must be a numeric run id, got #{v.inspect}", "pass the run's databaseId")
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

  # judge(target, body) -> State. Raises Unreadable on a body that does not
  # hold what the mode asked for.
  def judge(target, body)
    case target.mode
    when :checks then checks_state(body, min_checks: target.min_checks || 1)
    when :run_id then run_state(body, sha: target.sha)
    when :run_workflow
      run = pick_run(body, workflow: target.workflow, sha: target.sha)
      return State.new(state: :pending, summary: "no '#{target.workflow}' run on #{target.sha[0, 12]} listed yet") unless run

      run_state(run, sha: target.sha)
    else raise ArgumentError, "unknown mode #{target.mode.inspect}"
    end
  end

  def describe(target)
    case target.mode
    when :checks then "checks repo=#{target.repo} sha=#{target.sha[0, 12]}"
    when :run_id then "run repo=#{target.repo} id=#{target.id}#{target.sha ? " sha=#{target.sha[0, 12]}" : ''}"
    when :run_workflow then "run repo=#{target.repo} workflow='#{target.workflow}' sha=#{target.sha[0, 12]}"
    end
  end
end
