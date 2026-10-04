# frozen_string_literal: true

require "open3"
require "time"
require_relative "glab_ci_wait"

# glab_ci_wait_io.rb -- MANAGER (Waiter) and SIDE EFFECTS (GlabApiReader) for
# ai/bin/glab-ci-wait (DND-1940). The rules are in glab_ci_wait.rb.
module GlabCiWait
  # Outcome of one wait. verdict: :done, :failed, :canceled, :timeout,
  # :not_found or :could_not_look. line is the VERDICT: line; jobs are the
  # failing jobs ({ pipeline:, id:, words:, web_url: }); fix is nil only for :done.
  Outcome = Struct.new(:verdict, :line, :fix, :jobs, :reads, keyword_init: true)

  RATE_FIX = "this is not idle and not failed: nothing was read. Re-run glab-ci-wait after the reset " \
             "(or with a --timeout that covers it). Never fall back to a faster poll, to `glab ci status " \
             "--live`, or to the owner's glab."
  JOBS_FIX = "read a failing job's log once with `~/dev/custom/ai/bin/glab-athena api " \
             "projects/<namespace>%2F<project>/jobs/<job id>/trace` (or its web_url); a red pipeline never " \
             "merges or deploys, and a retry to green is a flake to ticket (athena:flaky-ticket)"

  # Raised inside a poll for a read that ends the wait at once.
  class Stop < StandardError
    attr_reader :outcome

    def initialize(outcome)
      super("stop")
      @outcome = outcome
    end
  end

  # MANAGER: read, judge, sleep, until a verdict or the --timeout bound.
  # reader: ->(path, timeout_s) { Read }; clock: -> { Time }; sleeper: ->(seconds) {};
  # log: ->(line) {} for progress (stderr in the CLI).
  class Waiter
    READ_TIMEOUT_S = 60
    READ_FLOOR_S = 10
    MAX_JOB_READS = 5

    def initialize(reader:, clock:, sleeper:, log:)
      @reader = reader
      @clock = clock
      @sleeper = sleeper
      @log = log
    end

    def wait(target, interval:, max:, grace:)
      @target = target
      @reads = Hash.new(0)
      @max = max
      @commit_ok = false
      started = @clock.call
      @deadline = started + max
      errors_in_row = 0
      last_state = nil
      last_error = nil
      @last_ok_at = nil

      loop do
        read, state = poll
        case read.kind
        when :ok
          errors_in_row = 0
          last_error = nil
          @last_ok_at = @clock.call
          final = finish(state, started, grace)
          return final if final

          note(state.summary) if last_state&.summary != state.summary
          last_state = state
        when :deadline
          return stop(last_state, last_error)
        when :rate_limited
          last_error = read.detail
          note("RATE-LIMITED (#{read.detail}) until #{read.reset_at.utc.iso8601}")
        else
          errors_in_row += 1
          last_error = read.detail
          note("read error #{errors_in_row} in a row: #{read.detail}")
        end

        step = GlabCiWait.next_wait(read: read, now: @clock.call, deadline: @deadline, interval: interval,
                                    errors_in_row: errors_in_row)
        case step.first
        when :give_up then return rate_limited(read)
        when :stop then return stop(last_state, last_error)
        else @sleeper.call(step.last)
        end
      end
    rescue Stop => e
      e.outcome
    rescue Unreadable => e
      could_not_look("unreadable response: #{e.message}",
                     "the API answered with a body this cannot judge; check --project, --sha and --ref")
    end

    private

    # One poll: every read a verdict needs. Returns [read, state]: read is the
    # poll's outcome as one Read (the first read that was not :ok, or an :ok
    # carrying the latest spent-budget reset), state the judged State.
    def poll
      spent = nil
      unless @commit_ok
        r = read_once(GlabCiWait.commit_path(@target))
        return [r, nil] unless r.kind == :ok

        @commit_ok = true
        spent = r.reset_at
      end
      r = read_once(GlabCiWait.list_path(@target))
      return [r, nil] unless r.kind == :ok

      spent = [spent, r.reset_at].compact.max
      sel = GlabCiWait.current_pipelines(r.body, @target, next_page: r.next_page)
      top = sel[:current].map { |p| { project: @target.project, pipeline: p } }
      entries = []
      if @target.include_children
        queue = top.map { |n| [n[:project], n[:pipeline]["id"], 0] }
        until queue.empty?
          project, id, depth = queue.shift
          b = read_once(GlabCiWait.bridges_path(project, id))
          return [b, nil] unless b.kind == :ok

          spent = [spent, b.reset_at].compact.max
          GlabCiWait.bridge_entries(b.body, next_page: b.next_page).each do |e|
            entries << e.merge(parent: id)
            next unless e[:kind] == :child

            if depth + 1 > GlabCiWait::MAX_DEPTH
              raise Unreadable, "pipeline #{e[:pipeline]['id']} is nested deeper than #{GlabCiWait::MAX_DEPTH} " \
                                "levels of trigger bridges; this follows no deeper"
            end
            if top.size + entries.count { |x| x[:kind] == :child } > GlabCiWait::MAX_PIPELINES
              raise Unreadable, "more than #{GlabCiWait::MAX_PIPELINES} pipelines under the sha"
            end

            queue << [e[:project], e[:pipeline]["id"], depth + 1]
          end
        end
      end
      state = GlabCiWait.judge(top: top, entries: entries, superseded: sel[:superseded])
      [Read.new(kind: :ok, reset_at: spent), state]
    end

    # One bounded read, counted. A read never runs past the deadline by more
    # than READ_FLOOR_S. A read no later read can fix ends the wait here.
    # No read starts at or after the deadline: a poll can be many reads (the
    # bridges of every pipeline, the job lists), and --timeout is a hard bound.
    def read_once(path)
      left = (@deadline - @clock.call).ceil
      return Read.new(kind: :deadline, detail: "--timeout reached before #{path} was read") if left <= 0

      read = @reader.call(path, left.clamp(READ_FLOOR_S, READ_TIMEOUT_S))
      @reads[read.kind] += 1
      raise Stop, key_outcome(path, read) if %i[not_found auth refused].include?(read.kind)

      read
    end

    def finish(state, started, grace)
      case state.state
      when :success
        outcome(:done, "DONE", state, nil)
      when :failed, :canceled
        jobs = failing_jobs(state)
        words = jobs.empty? ? "" : "; failing jobs: " + jobs.map { |j| "#{j[:pipeline]} #{j[:words]}" }.join(", ")
        outcome(state.state, state.state.to_s.upcase, state, JOBS_FIX, words: words, jobs: jobs)
      when :none
        return nil if @clock.call - started < grace

        not_found("no pipeline listed after #{(@clock.call - started).floor}s (grace #{grace}s)")
      end
    end

    # The failing jobs of each failed or canceled pipeline. A job-list read
    # that fails leaves the verdict as judged, and says so.
    def failing_jobs(state)
      jobs = state.failing.first(MAX_JOB_READS).flat_map do |n|
        id = n[:pipeline]["id"]
        r = read_job_list(n[:project], id)
        next [{ pipeline: id, words: "(job list not read: --timeout reached)" }] if r.kind == :deadline

        begin
          raise Unreadable, r.detail unless r.kind == :ok

          GlabCiWait.failing_jobs(r.body, next_page: r.next_page).map { |j| j.merge(pipeline: id) }
        rescue Unreadable => e
          [{ pipeline: id, words: "(job list unreadable: #{e.message})" }]
        end
      end
      more = state.failing.size - MAX_JOB_READS
      jobs << { pipeline: "-", words: "(#{more} more failing pipelines; their jobs were not read)" } if more.positive?
      jobs
    end

    def read_job_list(project, id)
      read_once(GlabCiWait.jobs_path(project, id))
    rescue Stop => e
      Read.new(kind: :error, detail: e.outcome.line.sub(/\AVERDICT: \S+ /, ""))
    end

    def outcome(verdict, word, state, fix, words: "", jobs: [])
      Outcome.new(verdict: verdict, line: "VERDICT: #{word} #{desc} pipelines=#{state.ids.join(',')}: " \
                                          "#{state.summary}#{words} #{reads_words}",
                  fix: fix, jobs: jobs, reads: @reads)
    end

    def not_found(why)
      filters = [@target.ref && "ref=#{@target.ref}", @target.source && "source=#{@target.source}"].compact
      fix = "the commit exists but has no pipeline#{filters.empty? ? '' : " matching #{filters.join(' ')}"}: " \
            "its workflow rules may have created none, or it was never pushed to this project's branch. " \
            "This is not pending and not green. Drop --ref/--source to see every pipeline on the sha, " \
            "or pass a larger --grace if the push was only just made"
      Outcome.new(verdict: :not_found, line: "VERDICT: NOT-FOUND #{desc}: #{why} #{reads_words}", fix: fix,
                  jobs: [], reads: @reads)
    end

    def stop(last_state, last_error)
      unless @reads[:ok].positive?
        return could_not_look("no read succeeded in #{@max}s; last error: #{last_error}",
                              "check the network and ~/dev/custom/ai/bin/forge-preflight; this is not idle and not pending")
      end
      if last_error
        since = @last_ok_at ? "the reads after #{@last_ok_at.utc.iso8601}" : "every poll"
        return could_not_look("#{since} failed (last: #{last_error}); " \
                              "the newest state seen was: #{last_state&.summary || 'none'}",
                              "re-run glab-ci-wait once the API answers; this is not idle, not pending and not green")
      end
      if last_state.nil?
        return could_not_look("the #{@max}s --timeout passed before one poll finished",
                              "pass a larger --timeout; this is not idle, not pending and not green")
      end
      return not_found("no pipeline listed within the #{@max}s --timeout") if last_state.state == :none

      Outcome.new(verdict: :timeout,
                  line: "VERDICT: TIMEOUT #{desc} pipelines=#{last_state.ids.join(',')} after #{@max}s: " \
                        "#{last_state.summary} #{reads_words}",
                  fix: "still pending and nothing failed yet: re-run glab-ci-wait (it reads the live state) or pass " \
                       "a larger --timeout. A pipeline that is `manual` waits for a person; one that is " \
                       "`waiting_for_resource` waits for its resource_group",
                  jobs: [], reads: @reads)
    end

    def rate_limited(read)
      could_not_look("rate-limited (#{read.detail}) until #{read.reset_at.utc.iso8601}, past the #{@max}s bound",
                     RATE_FIX)
    end

    # A read that names a key GitLab does not know, or that cannot run as
    # Athena. Never NOT-FOUND: a wrongly computed key is not "no pipeline".
    def key_outcome(path, read)
      project = path[%r{\Aprojects/([^/?]+)}, 1].to_s.split("%2F").join("/")
      case read.kind
      when :not_found
        if read.detail.to_s.include?("Commit Not Found")
          could_not_look("sha #{@target.sha} is not a commit in project #{project} (#{read.detail})",
                         "check --sha: pass the full sha of a commit pushed to --project (a wrong sha is not NOT-FOUND)")
        elsif project != @target.project
          could_not_look("downstream project #{project}, named by a bridge's downstream pipeline, is unknown or not " \
                         "visible to the bot (#{read.detail}; read #{path})",
                         "this is not --project: the bot glab-athena reads as cannot see the downstream project " \
                         "a trigger bridge started; drop --include-children or give the bot access")
        else
          could_not_look("project #{project} is unknown or not visible to the bot (#{read.detail}; read #{path})",
                         "check --project: the <namespace>/<project> path as GitLab spells it, and that the " \
                         "bot glab-athena reads as can see the project (a wrong path is not NOT-FOUND)")
        end
      when :auth
        could_not_look("GitLab refused the bot (#{read.detail}; read #{path})",
                       "check the bot's access with ~/dev/custom/ai/bin/forge-preflight (owner-gated if it fails)")
      else
        could_not_look("glab-athena refused the read (#{read.detail})",
                       "run ~/dev/custom/ai/bin/forge-preflight and follow its Fix; never fall back to the owner's glab")
      end
    end

    def could_not_look(why, fix)
      Outcome.new(verdict: :could_not_look, line: "VERDICT: COULD-NOT-LOOK #{desc}: #{why} #{reads_words}",
                  fix: fix, jobs: [], reads: @reads)
    end

    def desc
      d = "project=#{@target.project} sha=#{@target.sha[0, 12]}"
      d += " ref=#{@target.ref}" if @target.ref
      d += " source=#{@target.source}" if @target.source
      d += " children" if @target.include_children
      d
    end

    def reads_words
      "reads=" + @reads.sort.map { |k, v| "#{k}:#{v}" }.join(",")
    end

    def note(line)
      @log.call(line)
    end
  end

  # SIDE EFFECTS: one bounded `<glab> api -i <path>` GET, through glab-athena
  # (which resolves the bot for the project's namespace).
  class GlabApiReader
    def initialize(glab:, clock:)
      @glab = glab
      @clock = clock
    end

    def call(path, timeout_s)
      out, err, st = Open3.capture3("timeout", timeout_s.to_s, *@glab, "api", "-i", path)
      err = "#{err}glab api timed out after #{timeout_s}s\n" if st.exitstatus == 124
      GlabCiWait.parse(stdout: out, stderr: err, now: @clock.call)
    rescue SystemCallError => e
      Read.new(kind: :error, detail: "could not run #{@glab.first}: #{e.message}")
    end
  end
end
