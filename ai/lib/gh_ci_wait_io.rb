# frozen_string_literal: true

require "open3"
require "time"
require_relative "gh_ci_wait"

# gh_ci_wait_io.rb -- MANAGER (Waiter) and SIDE EFFECTS (GhApiReader) for
# ai/bin/gh-ci-wait (DND-1708, DND-1706). The rules are in gh_ci_wait.rb.
module GhCiWait
  # Outcome of one wait. verdict: :done, :failed, :timeout, :could_not_look
  # or :wrong_head. line is the VERDICT: line; fix is nil only for :done.
  Outcome = Struct.new(:verdict, :line, :fix, :reads, keyword_init: true)

  RATE_FIX = "this is not idle and not failed: nothing was read. Re-run gh-ci-wait after the reset " \
             "(or with a --max that covers it). Fleet pollers read through gh-athena, the App's own " \
             "budget; never fall back to a faster poll or to plain gh."

  # MANAGER: read, judge, sleep, until a verdict or the --max bound.
  # reader: ->(path, timeout_s) { Read }; clock: -> { Time }; sleeper: ->(seconds) {};
  # log: ->(line) {} for progress (stderr in the CLI).
  class Waiter
    READ_TIMEOUT_S = 60
    READ_FLOOR_S = 10

    def initialize(reader:, clock:, sleeper:, log:)
      @reader = reader
      @clock = clock
      @sleeper = sleeper
      @log = log
    end

    def wait(target, interval:, max:)
      @target = target
      @desc = GhCiWait.describe(target)
      @reads = Hash.new(0)
      @max = max
      deadline = @clock.call + max
      errors_in_row = 0
      last_state = nil
      last_error = nil
      @last_ok_at = nil

      loop do
        # A read never runs past the deadline by more than READ_FLOOR_S, so a
        # hung final read cannot push the wait past one foreground tool call.
        left = (deadline - @clock.call).ceil
        read = @reader.call(GhCiWait.path_for(target), left.clamp(READ_FLOOR_S, READ_TIMEOUT_S))
        @reads[read.kind] += 1
        case read.kind
        when :ok
          errors_in_row = 0
          last_error = nil
          @last_ok_at = @clock.call
          state = begin
            GhCiWait.judge(target, read.body)
          rescue Unreadable => e
            return could_not_look("unreadable response: #{e.message}", unreadable_fix(e))
          end
          final = finish(state)
          return final if final

          note("#{state.summary}") if last_state != state.summary
          last_state = state.summary
        when :auth, :not_found
          return could_not_look(read.detail, key_fix(read.kind))
        when :rate_limited
          last_error = read.detail
          note("RATE-LIMITED #{limit_words(read)} until #{read.reset_at.utc.iso8601}")
        else
          errors_in_row += 1
          last_error = read.detail
          note("read error #{errors_in_row} in a row: #{read.detail}")
        end

        step = GhCiWait.next_wait(read: read, now: @clock.call, deadline: deadline, interval: interval,
                                  errors_in_row: errors_in_row)
        case step.first
        when :give_up then return rate_limited(read)
        when :stop then return stop(last_state, last_error)
        else @sleeper.call(step.last)
        end
      end
    end

    private

    def finish(state)
      case state.state
      when :success
        Outcome.new(verdict: :done, line: "VERDICT: DONE #{@desc}: #{state.summary} #{reads_words}", reads: @reads)
      when :failure
        Outcome.new(verdict: :failed, line: "VERDICT: FAILED #{@desc}: #{state.summary} #{reads_words}",
                    fix: "read the failed run's log (athena:diagnose-github-actions-failure); a red check never " \
                         "merges, and a re-run to green is a flake to ticket (athena:flaky-ticket)",
                    reads: @reads)
      when :wrong_head
        Outcome.new(verdict: :wrong_head, line: "VERDICT: WRONG-HEAD #{@desc}: #{state.summary} #{reads_words}",
                    fix: "the run is for another commit: pass the run of the head you pushed, or wait by " \
                         "--workflow NAME --sha <head>",
                    reads: @reads)
      end
    end

    def stop(last_state, last_error)
      unless @reads[:ok].positive?
        return could_not_look("no read succeeded in #{@max}s; last error: #{last_error}",
                              "check the network and gh-athena --check; this is not idle and not pending")
      end
      # The last read failed: the newest state seen is old, so it is not "still
      # pending at --max". Say when it was seen and what failed since.
      if last_error
        return could_not_look("the reads after #{@last_ok_at.utc.iso8601} failed (last: #{last_error}); " \
                              "the newest state seen then was: #{last_state}",
                              "re-run gh-ci-wait once the API answers; this is not idle, not pending and not green")
      end
      Outcome.new(verdict: :timeout,
                  line: "VERDICT: TIMEOUT #{@desc} after #{@max}s: #{last_state} #{reads_words}",
                  fix: "still pending and nothing failed yet: re-run gh-ci-wait (it reads the live state) " \
                       "or pass a larger --max",
                  reads: @reads)
    end

    def rate_limited(read)
      could_not_look("rate-limited (#{limit_words(read)}) until #{read.reset_at.utc.iso8601}, " \
                     "past the #{@max}s bound", RATE_FIX)
    end

    def could_not_look(why, fix)
      Outcome.new(verdict: :could_not_look, line: "VERDICT: COULD-NOT-LOOK #{@desc}: #{why} #{reads_words}",
                  fix: fix, reads: @reads)
    end

    def unreadable_fix(error)
      if error.message.include?("total_count")
        return "more than one page of results: wait by --run-id <id> on the run you need, or by --workflow NAME"
      end

      "the API answered with a body this mode cannot judge; check --repo, --sha and --run-id"
    end

    def key_fix(kind)
      return "check the App's access with ~/dev/custom/ai/bin/gh-athena --check (owner-gated if it fails)" if kind == :auth

      "the repo, sha or run id matches nothing: check --repo, --sha and --run-id (a wrong key is not pending)"
    end

    def limit_words(read)
      "#{read.secondary ? 'secondary' : 'primary'} limit, resource=#{read.resource}, HTTP #{read.status || '?'}"
    end

    def reads_words
      "reads=" + @reads.sort.map { |k, v| "#{k}:#{v}" }.join(",")
    end

    def note(line)
      @log.call(line)
    end
  end

  # SIDE EFFECTS: one bounded `<gh> api -i <path>` GET.
  class GhApiReader
    def initialize(gh:, clock:)
      @gh = gh
      @clock = clock
    end

    def call(path, timeout_s)
      out, err, st = Open3.capture3("timeout", timeout_s.to_s, *@gh, "api", "-i", path)
      err = "#{err}gh api timed out after #{timeout_s}s\n" if st.exitstatus == 124
      GhCiWait.parse(stdout: out, stderr: err, now: @clock.call)
    rescue SystemCallError => e
      Read.new(kind: :error, detail: "could not run #{@gh.first}: #{e.message}")
    end
  end
end
