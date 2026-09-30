# frozen_string_literal: true

# EvalPool -- bounded concurrent sampling for the model-in-loop eval runners
# (DND-1007): ai/bin/admiral-eval, ai/bin/critic-eval, ai/bin/variant-eval.
#
# An eval sample is one `claude -p` subprocess. The runners used to take them
# one at a time, so a 500-call admiral-eval run took about 65 minutes of
# almost pure waiting. EvalPool.map runs up to K samples at once on K threads
# (each sample is a subprocess, so the GVL is not the bound) and returns the
# results in INPUT order, whatever order they finished in. That is what keeps
# the case set, the sample count and the scoring identical to a serial run: a
# caller folds the returned list exactly as its old serial loop did.
#
# What it does not change: each sample still builds its own sandbox (the
# caller's block does that), and nothing here retries, drops or reorders a
# sample.
#
# The rate-limit ceiling for K is UNMEASURED. DEFAULT is deliberately
# conservative; raise it only after a scheduled real eval run has measured
# where the model starts refusing (DND-1007 records the ceiling as unmeasured).
#
# Deliberately gem-free (stdlib only).
module EvalPool
  # 1 is the old serial behaviour. The upper bound keeps a typo from opening
  # hundreds of model calls at once.
  RANGE = (1..16)
  DEFAULT = 4
  # The environment fallback for --concurrency. variant-eval hands K to each
  # side's admiral-eval through it, so a baseline ref older than DND-1007 (whose
  # admiral-eval refuses an unknown --concurrency flag) still measures, serially.
  ENV_VAR = "ATHENA_EVAL_CONCURRENCY"

  # A value for --concurrency or ATHENA_EVAL_CONCURRENCY that is not an integer
  # in RANGE. The message names the value and where it came from; each caller
  # composes its own exit-2 refusal with a Fix:.
  class UsageError < StandardError; end

  # One item's outcome: the block's return value and its wall seconds.
  Result = Struct.new(:value, :seconds)

  module_function

  # The concurrency to use: the flag when given, else ENV_VAR, else `default`.
  # A malformed or out-of-range value raises UsageError: refused, never clamped,
  # so a typo cannot quietly run a different K than asked for.
  def resolve(flag, env = ENV, default: DEFAULT)
    raw, from = if flag.nil?
                  [env[ENV_VAR], ENV_VAR]
                else
                  [flag, "--concurrency"]
                end
    return default if raw.nil? || (from == ENV_VAR && raw.to_s.empty?)

    k = raw.is_a?(Integer) ? raw : Integer(raw.to_s, 10)
    raise UsageError, "#{from} #{raw.inspect} is out of range (#{RANGE.first}-#{RANGE.last})" unless RANGE.cover?(k)

    k
  rescue ArgumentError, TypeError
    raise UsageError, "#{from} #{raw.inspect} is not an integer (#{RANGE.first}-#{RANGE.last})"
  end

  # Runs the block once per item, at most `concurrency` at a time, and returns
  # an Array of Result in the order of `items`. The block gets (item, index).
  # The first exception a block raises stops new items from starting; the ones
  # already running finish, then that exception is re-raised here.
  def map(items, concurrency:)
    raise ArgumentError, "EvalPool.map: concurrency #{concurrency.inspect} is not in #{RANGE}" \
      unless concurrency.is_a?(Integer) && RANGE.cover?(concurrency)

    list = items.to_a
    results = Array.new(list.size)
    return results if list.empty?

    queue = Queue.new
    list.each_with_index { |item, i| queue << [item, i] }
    lock = Mutex.new
    failure = nil
    workers = Array.new([concurrency, list.size].min) do
      Thread.new do
        Thread.current.report_on_exception = false
        loop do
          break if lock.synchronize { failure }

          item, i = begin
            queue.pop(true)
          rescue ThreadError
            break
          end
          t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          begin
            value = yield(item, i)
          rescue Exception => e # rubocop:disable Lint/RescueException -- re-raised on the caller's thread
            lock.synchronize { failure ||= e }
            break
          end
          results[i] = Result.new(value, Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0)
        end
      end
    end
    workers.each(&:join)
    raise failure if failure

    results
  end

  # One stderr line summarising a run's timing: wall seconds, K, and the
  # per-sample durations (count, median, max). `seconds` is every sample's
  # Result#seconds. Never a verdict: it records what the run took.
  def timing_line(tool, wall:, concurrency:, seconds:)
    return "#{tool}: timing -- wall #{format('%.1f', wall)}s, concurrency #{concurrency}, 0 model call(s)" \
      if seconds.empty?

    sorted = seconds.sort
    mid = sorted.size / 2
    median = sorted.size.odd? ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2.0
    "#{tool}: timing -- wall #{format('%.1f', wall)}s, concurrency #{concurrency}, " \
      "#{sorted.size} model call(s), per call median #{format('%.1f', median)}s, " \
      "max #{format('%.1f', sorted.last)}s, sum #{format('%.1f', sorted.sum)}s"
  end

  def monotonic
    Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end
end
