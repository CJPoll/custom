# frozen_string_literal: true

require "json"
require "uri"
require_relative "ci_wait"

# glab_ci_wait.rb -- DOMAIN for ai/bin/glab-ci-wait (DND-1940).
#
# Pure rules, no I/O: read one `glab api -i` response into a Read, validate
# the keys, choose the current pipelines on a sha, follow trigger bridges to
# their downstream (child) pipelines, judge the verdict, and list the failing
# jobs. The manager loop and the glab adapter are in ai/lib/glab_ci_wait_io.rb.
# The cadence, backoff and wait decision are CiWait's (ai/lib/ci_wait.rb),
# shared with gh-ci-wait.
#
# What it closes:
#   * `glab ci status --live` and `glab ci view` poll for as long as a
#     pipeline runs, and hand-rolled loops around glab have no floor. Here the
#     cadence has CiWait's floor and a hard bound.
#   * A rate-limited read (HTTP 429, or a 200 with RateLimit-Remaining: 0) is
#     never :ok-and-empty: it waits to GitLab's reset, or the wait says
#     COULD-NOT-LOOK with the reset time.
#   * "No pipeline for this sha" (NOT-FOUND) is told apart from "a pipeline is
#     still pending", and from a key computed wrongly: a malformed project path
#     is a usage error, and a project or sha GitLab does not know is a named
#     COULD-NOT-LOOK, never NOT-FOUND.
module GlabCiWait
  MIN_INTERVAL = CiWait::MIN_INTERVAL
  DEFAULT_INTERVAL = CiWait::DEFAULT_INTERVAL
  DEFAULT_MAX = CiWait::DEFAULT_MAX
  # How long a sha with no pipeline listed is still worth waiting on. A push
  # creates its pipeline within seconds; a sha whose workflow rules made none
  # should not hold a waiter for its whole bound.
  DEFAULT_GRACE = 120
  # GitLab's 429 without Retry-After or RateLimit-Reset: wait this long.
  RATE_FALLBACK_S = 60
  SOURCES = %w[push merge_request_event].freeze
  # Pipelines another pipeline started. They are reached through bridges
  # (--include-children), never judged as top-level pipelines.
  CHILD_SOURCES = %w[parent_pipeline pipeline].freeze
  # Pipeline and job statuses (GitLab REST). Anything else is Unreadable.
  PENDING = %w[created waiting_for_resource preparing pending running scheduled manual canceling].freeze
  TERMINAL = { "success" => :success, "failed" => :failed, "canceled" => :canceled, "skipped" => :failed }.freeze
  # A bridge with no downstream pipeline yet. Open: it may still trigger one.
  BRIDGE_OPEN = %w[created waiting_for_resource preparing pending running scheduled].freeze
  BRIDGE_DEAD = %w[failed canceled].freeze
  MAX_DEPTH = 3
  MAX_PIPELINES = 25
  HOST = "gitlab.com"

  Usage = CiWait::Usage
  Unreadable = CiWait::Unreadable

  # kind: :ok, :rate_limited, :auth, :not_found, :refused or :error.
  # reset_at on :ok means GitLab said the budget is spent (RateLimit-Remaining 0).
  Read = Struct.new(:kind, :status, :body, :reset_at, :next_page, :detail, keyword_init: true)
  # state: :success, :failed, :canceled, :pending or :none (no current pipeline).
  State = Struct.new(:state, :ids, :summary, :failing, keyword_init: true)
  Target = Struct.new(:project, :sha, :ref, :source, :include_children, keyword_init: true)

  module_function

  # ---- one response ---------------------------------------------------------
  def parse(stdout:, stderr:, now:)
    status, headers, body = CiWait.split_http(stdout.to_s)
    err = stderr.to_s.strip
    return parse_without_status(err) if status.nil?

    message = json_message(body)
    if status.between?(200, 299)
      begin
        parsed = JSON.parse(body)
      rescue JSON::ParserError
        return Read.new(kind: :error, status: status, detail: "HTTP #{status} body is not JSON")
      end
      return Read.new(kind: :ok, status: status, body: parsed, reset_at: spent_reset(headers, now),
                      next_page: presence(headers["x-next-page"]))
    end
    return Read.new(kind: :rate_limited, status: status, reset_at: limit_reset(headers, now),
                    detail: "HTTP 429: #{message || 'rate limited'}") if status == 429

    detail = "HTTP #{status}: #{message || err.lines.first.to_s.strip}"
    kind = case status
           when 401, 403 then :auth
           when 404 then :not_found
           else :error
           end
    Read.new(kind: kind, status: status, detail: detail)
  end

  # No status line: the wrapper refused before any request, or glab never got
  # a response. Every glab-athena refusal is configuration (no token, no
  # identity for the namespace, a key it cannot route): a re-read cannot fix it.
  def parse_without_status(err)
    first = err.lines.first.to_s.strip
    return Read.new(kind: :refused, detail: first) if err.start_with?("glab-athena: ")

    Read.new(kind: :error, detail: "no HTTP response: #{first.empty? ? '(no output)' : first}")
  end

  def json_message(body)
    msg = JSON.parse(body)["message"]
    msg.is_a?(String) ? msg : nil
  rescue JSON::ParserError, TypeError, NoMethodError
    nil
  end

  def presence(value)
    v = value.to_s.strip
    v.empty? ? nil : v
  end

  def epoch(value, now)
    v = value.to_s
    v.match?(/\A\d+\z/) ? [Time.at(v.to_i).utc, now].max : nil
  end

  # A 2xx that spent the last of the budget: the reset GitLab named, if any.
  def spent_reset(headers, now)
    return nil unless headers["ratelimit-remaining"] == "0"

    reset = epoch(headers["ratelimit-reset"], now)
    reset && reset > now ? reset : nil
  end

  def limit_reset(headers, now)
    return now + headers["retry-after"].to_i if headers["retry-after"].to_s.match?(/\A\d+\z/)

    epoch(headers["ratelimit-reset"], now) || (now + RATE_FALLBACK_S)
  end

  # ---- the wait decision (CiWait's rule) -----------------------------------
  def next_wait(read:, now:, deadline:, interval:, errors_in_row:)
    CiWait.next_wait(read: read, now: now, deadline: deadline, interval: interval, errors_in_row: errors_in_row)
  end

  # ---- keys: a wrongly computed key is an error -----------------------------
  SEGMENT = /\A[A-Za-z0-9_][A-Za-z0-9_.-]*\z/.freeze

  def project!(value)
    v = value.to_s
    fix = "pass the project's path as <namespace>/<project> (e.g. --project acme/app), unencoded; " \
          "glab-ci-wait encodes it"
    why = if v.match?(%r{\A[A-Za-z][A-Za-z0-9+.-]*://}) || v.include?("@") || v.include?(":")
            "is a URL or remote, not a project path"
          elsif v.match?(/\A\d+\z/)
            "is a numeric id, which names no namespace (glab-athena routes by namespace, DND-1936)"
          elsif v.include?("%")
            "is %-encoded"
          elsif v.end_with?(".git")
            "ends in .git"
          elsif v.start_with?("/") || v.end_with?("/")
            "has a leading or trailing slash"
          elsif !v.include?("/")
            "has no namespace"
          elsif v.split("/").any? { |s| s == "." || s == ".." || !s.match?(SEGMENT) }
            "has an empty, dot or non-path segment"
          end
    raise Usage.new("--project #{v.inspect} #{why}", fix) if why

    v
  end

  def encode_project(project)
    project.split("/").join("%2F")
  end

  def ref!(value)
    v = value.to_s
    if v.empty? || v.start_with?("-") || !v.match?(%r{\A[A-Za-z0-9_./-]+\z}) || v.include?("..")
      raise Usage.new("--ref #{v.inspect} is not a branch, tag or refs/... name",
                      "pass the pipeline's ref, e.g. --ref main or --ref refs/merge-requests/<iid>/head")
    end
    v
  end

  def source!(value)
    v = value.to_s
    return v if SOURCES.include?(v)

    raise Usage.new("--source #{v.inspect} is not one of #{SOURCES.join(', ')}",
                    "pass --source push (a branch or main push) or --source merge_request_event (an MR pipeline)")
  end

  def sha!(value)
    CiWait.sha!(value)
  end

  def interval!(value)
    CiWait.interval!(value)
  end

  def timeout!(value)
    CiWait.positive_int(value, "--timeout")
  end

  def grace!(value)
    v = value.to_s
    return v.to_i if v.match?(/\A\d+\z/)

    raise Usage.new("--grace must be a whole number of seconds, got #{v.inspect}",
                    "pass --grace N (0 says NOT-FOUND on the first read that lists no pipeline)")
  end

  # ---- what is read ----------------------------------------------------------
  # Projects are always named by %2F path, never by numeric id, and nothing
  # past the project is %-encoded (glab-athena's endpoint key, DND-1936).
  def commit_path(target)
    "projects/#{encode_project(target.project)}/repository/commits/#{target.sha}"
  end

  def list_path(target)
    q = "sha=#{target.sha}&order_by=id&sort=desc&per_page=100"
    q += "&ref=#{URI.encode_www_form_component(target.ref)}" if target.ref
    q += "&source=#{target.source}" if target.source
    "projects/#{encode_project(target.project)}/pipelines?#{q}"
  end

  def bridges_path(project, pipeline_id)
    "projects/#{encode_project(project)}/pipelines/#{pipeline_id}/bridges?per_page=100"
  end

  def jobs_path(project, pipeline_id)
    "projects/#{encode_project(project)}/pipelines/#{pipeline_id}/jobs?per_page=100"
  end

  # ---- the current pipelines on the sha -------------------------------------
  # current_pipelines(body, target, next_page:) -> { current: [...], superseded: [...] }.
  # The newest pipeline (by id) per (source, ref) is current; an older one is
  # superseded (a "Run pipeline" or a re-push of the same sha) and named.
  def current_pipelines(body, target, next_page:)
    raise Unreadable, "pipelines body is not an array" unless body.is_a?(Array)
    raise Unreadable, "more than one page of pipelines on the sha (100 per page); the newest may be on another" if next_page

    rows = body.map { |p| pipeline!(p) }
    rows = rows.select { |p| p["sha"] == target.sha && !CHILD_SOURCES.include?(p["source"]) }
    rows = rows.select { |p| p["ref"] == target.ref } if target.ref
    rows = rows.select { |p| p["source"] == target.source } if target.source
    groups = rows.group_by { |p| [p["source"], p["ref"]] }.values
    current = groups.map { |ps| ps.max_by { |p| p["id"] } }.sort_by { |p| p["id"] }
    { current: current, superseded: (rows - current).sort_by { |p| p["id"] } }
  end

  def pipeline!(row)
    unless row.is_a?(Hash) && row["id"].is_a?(Integer) && row["status"].is_a?(String)
      raise Unreadable, "a pipeline row has no integer id or no status: #{row.inspect[0, 120]}"
    end

    row
  end

  # ---- bridges -----------------------------------------------------------------
  # bridge_entries(body, next_page:) -> [{ kind:, bridge:, project:, pipeline: }]
  #   :child  a downstream pipeline exists (project read from its web_url)
  #   :open   no downstream yet, and the bridge may still trigger one: pending
  #   :dead   no downstream, and the bridge failed or was canceled
  #   :idle   no downstream, and nothing will start one by itself (manual,
  #           skipped): named, not waited on
  def bridge_entries(body, next_page:)
    raise Unreadable, "bridges body is not an array" unless body.is_a?(Array)
    raise Unreadable, "more than one page of bridges (100 per page)" if next_page

    body.map do |b|
      raise Unreadable, "a bridge row has no name or status: #{b.inspect[0, 120]}" \
        unless b.is_a?(Hash) && b["name"].is_a?(String) && b["status"].is_a?(String)

      ds = b["downstream_pipeline"]
      if ds.is_a?(Hash)
        pipeline!(ds)
        { kind: :child, bridge: b, project: downstream_project!(ds), pipeline: ds }
      elsif BRIDGE_OPEN.include?(b["status"])
        { kind: :open, bridge: b }
      elsif BRIDGE_DEAD.include?(b["status"])
        { kind: :dead, bridge: b }
      else
        { kind: :idle, bridge: b }
      end
    end
  end

  # The downstream project's path, from https://gitlab.com/<path>/-/pipelines/<id>.
  # The bridge names it only by numeric id otherwise, which glab-athena cannot route.
  def downstream_project!(ds)
    url = ds["web_url"].to_s
    m = url.match(%r{\Ahttps://#{Regexp.escape(HOST)}/(.+)/-/pipelines/(\d+)\z})
    raise Unreadable, "downstream pipeline #{ds['id']} has a web_url this cannot read: #{url.inspect}" unless m
    raise Unreadable, "downstream pipeline #{ds['id']}'s web_url names pipeline #{m[2]}" unless m[2].to_i == ds["id"]

    begin
      project!(m[1])
    rescue Usage
      raise Unreadable, "downstream pipeline #{ds['id']}'s web_url names no project path: #{url.inspect}"
    end
  end

  # ---- the verdict -----------------------------------------------------------
  def status_class!(status, what)
    return :pending if PENDING.include?(status)
    return TERMINAL.fetch(status) if TERMINAL.key?(status)

    raise Unreadable, "#{what} has status #{status.inspect}, which this does not know"
  end

  # judge(top:, entries:, superseded:) -> State.
  # top: [{ project:, pipeline: }]; entries: bridge entries (each with parent:).
  # Pending outranks failed, failed outranks canceled: the wait reports once
  # every pipeline it judges has settled, as gh-ci-wait does.
  def judge(top:, entries:, superseded:)
    return State.new(state: :none, ids: [], summary: "no pipeline listed", failing: []) if top.empty?

    classes = []
    failing = []
    words = []
    top.each do |n|
      p = n[:pipeline]
      c = status_class!(p["status"], "pipeline #{p['id']}")
      classes << c
      failing << n if %i[failed canceled].include?(c)
      words << "pipeline #{p['id']} (#{p['source']} #{p['ref']}) #{status_words(p['status'])}"
    end
    entries.each do |e|
      b = e[:bridge]
      allowed = b["allow_failure"] == true
      case e[:kind]
      when :child
        p = e[:pipeline]
        c = status_class!(p["status"], "downstream pipeline #{p['id']}")
        if allowed && %i[failed canceled].include?(c)
          words << "child #{p['id']} via #{b['name']} (#{e[:project]}) #{p['status']}, allowed to fail"
        else
          classes << c
          failing << { project: e[:project], pipeline: p, via: b["name"] } if %i[failed canceled].include?(c)
          words << "child #{p['id']} via #{b['name']} (#{e[:project]}) #{status_words(p['status'])}"
        end
      when :open
        classes << :pending
        words << "bridge #{b['name']} #{b['status']}, no downstream pipeline yet"
      when :dead
        if allowed
          words << "bridge #{b['name']} #{b['status']} with no downstream pipeline, allowed to fail"
        else
          classes << (b["status"] == "canceled" ? :canceled : :failed)
          words << "bridge #{b['name']} #{b['status']} with no downstream pipeline"
        end
      else
        words << "bridge #{b['name']} #{b['status']}, not triggered"
      end
    end
    state = %i[pending failed canceled].find { |s| classes.include?(s) } || :success
    ids = top.map { |n| n[:pipeline]["id"] } + entries.select { |e| e[:kind] == :child }.map { |e| e[:pipeline]["id"] }
    old = superseded.empty? ? "" : "; superseded: " + superseded.map { |p| "pipeline #{p['id']} (#{p['status']})" }.join(", ")
    State.new(state: state, ids: ids, summary: words.join("; ") + old, failing: failing)
  end

  def status_words(status)
    case status
    when "manual" then "manual (blocked on a manual job; it will not finish by itself)"
    when "skipped" then "skipped (no job ran)"
    else status
    end
  end

  # failing_jobs(body, next_page:) -> [{ id:, name:, stage:, status:, web_url:, words: }]
  # The failed and canceled jobs that are not allowed to fail.
  def failing_jobs(body, next_page:)
    raise Unreadable, "jobs body is not an array" unless body.is_a?(Array)

    rows = body.select do |j|
      j.is_a?(Hash) && %w[failed canceled].include?(j["status"]) && j["allow_failure"] != true
    end
    out = rows.map do |j|
      reason = j["failure_reason"] ? ": #{j['failure_reason']}" : ""
      { id: j["id"], name: j["name"].to_s, stage: j["stage"].to_s, status: j["status"], web_url: j["web_url"],
        words: "#{j['stage']}/#{j['name']} (#{j['status']}#{reason})" }
    end
    out << { name: "", words: "(more jobs on another page; this list is the first 100)" } if next_page
    out
  end
end
