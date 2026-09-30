# frozen_string_literal: true

# Deterministic suite for ai/lib/eval_pool.rb (DND-1007). No model, no git, no
# network, and no wall-clock verdict: every ordering claim below is forced by a
# Queue or a barrier, and every wait carries a hang cap (HANG_S) that only ends
# a broken run. Run by ai/lib/test/eval-pool/self-test.sh, which harness-gate
# discovers.

require_relative "../../eval_pool"

$failures = []
$checks = 0
HANG_S = 60

def check(desc)
  $checks += 1
  $failures << desc unless yield
rescue StandardError => e
  $failures << "#{desc} (raised #{e.class}: #{e.message})"
end

def raises?(klass)
  yield
  false
rescue klass
  true
end

# Barrier: every caller waits until `n` callers have arrived, or HANG_S passes
# (a hang cap; the caller then sees false). Records the most seen in flight.
class Barrier
  attr_reader :max_in_flight

  def initialize(n)
    @n = n
    @arrived = 0
    @in_flight = 0
    @max_in_flight = 0
    @lock = Mutex.new
    @cv = ConditionVariable.new
  end

  def enter
    @lock.synchronize do
      @in_flight += 1
      @max_in_flight = [@max_in_flight, @in_flight].max
    end
  end

  def leave
    @lock.synchronize { @in_flight -= 1 }
  end

  def arrive
    deadline = EvalPool.monotonic + HANG_S
    @lock.synchronize do
      @arrived += 1
      @cv.broadcast
      while @arrived < @n
        left = deadline - EvalPool.monotonic
        return false if left <= 0

        @cv.wait(@lock, left)
      end
      true
    end
  end
end

# --- resolve: the flag wins, then the environment, then the default ---------
env = {}
check("no flag, no env -> DEFAULT") { EvalPool.resolve(nil, env) == EvalPool::DEFAULT }
check("the default is conservative and in range") { EvalPool::RANGE.cover?(EvalPool::DEFAULT) && EvalPool::DEFAULT <= 4 }
check("a caller's own default") { EvalPool.resolve(nil, env, default: 2) == 2 }
check("flag \"3\" -> 3") { EvalPool.resolve("3", env) == 3 }
check("flag Integer 3 -> 3") { EvalPool.resolve(3, env) == 3 }
check("env 2 -> 2") { EvalPool.resolve(nil, { EvalPool::ENV_VAR => "2" }) == 2 }
check("the flag wins over the env") { EvalPool.resolve("5", { EvalPool::ENV_VAR => "2" }) == 5 }
check("an empty env value is the default") { EvalPool.resolve(nil, { EvalPool::ENV_VAR => "" }) == EvalPool::DEFAULT }
%w[0 17 -1 x 2.5 07x].each do |bad|
  check("flag #{bad.inspect} is refused (UsageError), never clamped") do
    raises?(EvalPool::UsageError) { EvalPool.resolve(bad, env) }
  end
  check("env #{bad.inspect} is refused (UsageError), never clamped") do
    raises?(EvalPool::UsageError) { EvalPool.resolve(nil, { EvalPool::ENV_VAR => bad }) }
  end
end
check("the refusal names where the value came from") do
  EvalPool.resolve(nil, { EvalPool::ENV_VAR => "99" })
  false
rescue EvalPool::UsageError => e
  e.message.include?(EvalPool::ENV_VAR) && e.message.include?("99")
end

# --- map: results come back in INPUT order, whatever order they finish in ---
# Item 0 cannot finish until item 1 has: completion order is 1, 0.
done1 = Queue.new
res = EvalPool.map(%w[a b], concurrency: 2) do |item, i|
  if i.zero?
    done1.pop(timeout: HANG_S) or raise "hang: item 1 never finished"
  else
    done1 << :done
  end
  item.upcase
end
check("map returns input order when completion order is reversed") { res.map(&:value) == %w[A B] }
check("every Result carries non-negative seconds") { res.all? { |r| r.seconds.is_a?(Float) && r.seconds >= 0 } }

# --- map: K items are in flight at once, and never more than K --------------
bar = Barrier.new(3)
arrived = EvalPool.map((0...7).to_a, concurrency: 3) do |_item, i|
  bar.enter
  begin
    i < 3 ? bar.arrive : true
  ensure
    bar.leave
  end
end
check("the first K=3 items were all in flight together (the barrier opened)") { arrived.first(3).all?(&:value) }
check("never more than K=3 in flight (max #{bar.max_in_flight})") { bar.max_in_flight == 3 }

# K=1 is serial: one in flight, input order, every item run once.
serial = Barrier.new(1)
seen = []
EvalPool.map((0...5).to_a, concurrency: 1) do |item, _i|
  serial.enter
  seen << item
  serial.leave
end
check("K=1 runs one at a time") { serial.max_in_flight == 1 }
check("K=1 runs each item once, in order") { seen == [0, 1, 2, 3, 4] }

# More workers than items is fine, and an empty list is an empty result.
check("K larger than the item count") { EvalPool.map([1, 2], concurrency: 8) { |x, _| x * 10 }.map(&:value) == [10, 20] }
check("an empty list maps to []") { EvalPool.map([], concurrency: 4) { raise "never" } == [] }

# --- a raise stops new items and reaches the caller -------------------------
started = []
err = begin
  EvalPool.map(%w[ok boom never], concurrency: 1) do |item, _i|
    started << item
    raise "boom" if item == "boom"

    item
  end
  nil
rescue RuntimeError => e
  e
end
check("a block's exception is re-raised to the caller") { err && err.message == "boom" }
check("no item starts after one raised (K=1)") { started == %w[ok boom] }

check("a concurrency outside RANGE is an ArgumentError") do
  raises?(ArgumentError) { EvalPool.map([1], concurrency: 0) { nil } } &&
    raises?(ArgumentError) { EvalPool.map([1], concurrency: "2") { nil } }
end

# --- timing_line: a record, never a verdict ---------------------------------
line = EvalPool.timing_line("x-eval", wall: 12.34, concurrency: 4, seconds: [3.0, 1.0, 2.0])
check("timing_line names wall, K, count, median, max and sum (#{line})") do
  line == "x-eval: timing -- wall 12.3s, concurrency 4, 3 model call(s), per call median 2.0s, max 3.0s, sum 6.0s"
end
check("timing_line with no calls says 0, not a fabricated median") do
  EvalPool.timing_line("x-eval", wall: 0.5, concurrency: 1, seconds: []).end_with?("0 model call(s)")
end

if $failures.empty?
  puts "eval-pool: self-test OK (#{$checks} checks)"
  exit 0
end
$failures.each { |f| warn "eval-pool: FAIL -- #{f}" }
warn "eval-pool: self-test FAILED (#{$failures.size}/#{$checks})"
warn "  Fix: ai/lib/eval_pool.rb must return results in input order, keep at most K and (given K items " \
     "ready) exactly K in flight, stop starting items after a raise and re-raise it, and refuse (never " \
     "clamp) a concurrency outside #{EvalPool::RANGE}. Restore that; do not loosen a case."
exit 1
