# frozen_string_literal: true

# Deterministic suite for GhCiWait::Waiter (MANAGER, ai/lib/gh_ci_wait_io.rb):
# the read-judge-sleep loop, with the gh adapter, the clock and the sleeper
# all faked. A fake sleeper advances the fake clock, so a 570 s wait runs in
# microseconds. Functional only (DND-1222): no real sleep, no network.

require "json"
require_relative "../../lib/gh_ci_wait"
require_relative "../../lib/gh_ci_wait_io"

W = GhCiWait
T0 = Time.utc(2026, 10, 2, 8, 0, 0)
SHA = "c" * 40

$failures = []
$checks = 0

def check(desc)
  $checks += 1
  $failures << desc unless yield
rescue StandardError => e
  $failures << "#{desc} (raised #{e.class}: #{e.message} #{e.backtrace&.first})"
end

# Builds a Waiter over a scripted list of reads. Each entry is a Read, or a
# lambda(now) -> Read. The last entry repeats.
class Rig
  attr_reader :now, :sleeps, :paths, :log, :timeouts

  def initialize(script)
    @script = script
    @now = T0
    @sleeps = []
    @paths = []
    @log = []
    @timeouts = []
  end

  def waiter
    reader = lambda do |path, timeout_s|
      @paths << path
      @timeouts << timeout_s
      entry = @script.length > 1 ? @script.shift : @script.first
      entry.respond_to?(:call) ? entry.call(@now) : entry
    end
    W::Waiter.new(reader: reader, clock: -> { @now }, sleeper: ->(s) { @sleeps << s; @now += s },
                  log: ->(line) { @log << line })
  end
end

def ok(body) = W::Read.new(kind: :ok, status: 200, body: body)

def checks(*rows) = ok("total_count" => rows.size, "check_runs" => rows)

def cr(name, status, conclusion = nil) = { "name" => name, "status" => status, "conclusion" => conclusion }

TC = W::Target.new(mode: :checks, repo: "acme/app", sha: SHA, min_checks: 1)
TR = W::Target.new(mode: :run_id, repo: "acme/app", id: "77", sha: SHA)

def run(rig, target = TC, interval: 60, max: 570) = rig.waiter.wait(target, interval: interval, max: max)

# ---- M: the loop --------------------------------------------------------------
check("M1 green on the first read: DONE, no sleep") do
  rig = Rig.new([checks(cr("a", "completed", "success"))])
  o = run(rig)
  o.verdict == :done && rig.sleeps.empty? && o.line.start_with?("VERDICT: DONE")
end
check("M2 pending then green: one sleep of the interval, then DONE") do
  rig = Rig.new([checks(cr("a", "in_progress")), checks(cr("a", "completed", "success"))])
  o = run(rig)
  o.verdict == :done && rig.sleeps == [60] && o.reads[:ok] == 2
end
check("M3 a red check: FAILED naming it, with a Fix") do
  rig = Rig.new([checks(cr("a", "completed", "success"), cr("lint", "completed", "failure"))])
  o = run(rig)
  o.verdict == :failed && o.line.include?("lint(failure)") && o.fix.to_s.length.positive?
end
check("M4 pending to the deadline: TIMEOUT, bounded by --max, never DONE") do
  rig = Rig.new([checks(cr("a", "queued"))])
  o = run(rig, max: 300)
  o.verdict == :timeout && rig.now - T0 <= 300 && rig.sleeps.sum == 300 && o.line.include?("not completed")
end
check("M5 rate limited, reset inside the bound: sleeps until the reset, then reads on and finishes") do
  rl = W::Read.new(kind: :rate_limited, status: 403, resource: "core", reset_at: T0 + 200, secondary: false, detail: "x")
  rig = Rig.new([rl, checks(cr("a", "completed", "success"))])
  o = run(rig)
  o.verdict == :done && rig.sleeps == [200] && o.reads[:rate_limited] == 1 &&
    rig.log.any? { |l| l.include?("RATE-LIMITED") && l.include?("core") }
end
check("M6 rate limited past the bound: COULD-NOT-LOOK naming the reset time, at once, never terminal-failed or empty") do
  rl = W::Read.new(kind: :rate_limited, status: 403, resource: "core", reset_at: T0 + 3600, secondary: false, detail: "x")
  rig = Rig.new([rl])
  o = run(rig)
  o.verdict == :could_not_look && rig.sleeps.empty? && o.line.include?("rate-limited") &&
    o.line.include?("2026-10-02T09:00:00Z") && o.line.include?("resource=core") && o.fix.include?("not idle")
end
check("M7 a secondary limit is named secondary") do
  rl = W::Read.new(kind: :rate_limited, status: 403, resource: "unknown", reset_at: T0 + 3600, secondary: true, detail: "x")
  run(Rig.new([rl])).line.include?("secondary")
end
check("M8 every read failing to the deadline: COULD-NOT-LOOK (could not look), never TIMEOUT (looked, pending)") do
  rig = Rig.new([W::Read.new(kind: :error, detail: "no HTTP response: error connecting")])
  o = run(rig, max: 570)
  o.verdict == :could_not_look && o.line.include?("error connecting") && o.reads[:error] >= 2
end
check("M9 errors back off: 60, then 120, then 240 (capped by the deadline)") do
  rig = Rig.new([W::Read.new(kind: :error, detail: "e")])
  run(rig, max: 570)
  rig.sleeps.first(3) == [60, 120, 240]
end
check("M10 an ok read resets the backoff") do
  e = W::Read.new(kind: :error, detail: "e")
  rig = Rig.new([e, e, checks(cr("a", "queued")), checks(cr("a", "completed", "success"))])
  run(rig, max: 5000)
  rig.sleeps == [60, 120, 60]
end
check("M11 an ok read then errors to the deadline is COULD-NOT-LOOK naming the stale state, never TIMEOUT") do
  rig = Rig.new([checks(cr("a", "queued")), W::Read.new(kind: :error, detail: "HTTP 502: bad gateway")])
  o = run(rig, max: 300)
  o.verdict == :could_not_look && o.line.include?("2026-10-02T08:00:00Z") && o.line.include?("502") &&
    o.line.include?("not completed")
end
check("M11b errors then an ok pending read to the deadline is TIMEOUT (the last read was fine)") do
  rig = Rig.new([W::Read.new(kind: :error, detail: "e"), checks(cr("a", "queued"))])
  run(rig, max: 300).verdict == :timeout
end
check("M18 each read is bounded: 60 s, cut near the deadline, never under 10 s") do
  rig = Rig.new([checks(cr("a", "queued"))])
  run(rig, max: 100)
  rig.timeouts.first == 60 && rig.timeouts.last == 10 && rig.timeouts.all? { |t| t.between?(10, 60) }
end
check("M19 a Retry-After of 0 waits the 30 s floor, never a 1 s re-read loop") do
  rl = W::Read.new(kind: :rate_limited, status: 403, resource: "core", reset_at: T0, secondary: true, detail: "x")
  rig = Rig.new([rl, checks(cr("a", "completed", "success"))])
  run(rig).verdict == :done && rig.sleeps == [W::MIN_INTERVAL]
end
check("M12 auth failure: COULD-NOT-LOOK at once (a re-read cannot help)") do
  rig = Rig.new([W::Read.new(kind: :auth, status: 401, detail: "HTTP 401: Bad credentials")])
  o = run(rig)
  o.verdict == :could_not_look && rig.sleeps.empty? && o.line.include?("401")
end
check("M13 not found: COULD-NOT-LOOK at once naming the key, never pending forever") do
  rig = Rig.new([W::Read.new(kind: :not_found, status: 404, detail: "HTTP 404: Not Found")])
  o = run(rig, TR)
  o.verdict == :could_not_look && o.line.include?("id=77") && rig.sleeps.empty?
end
check("M14 an unreadable 2xx body: COULD-NOT-LOOK, never read as no checks") do
  rig = Rig.new([ok("message" => "x")])
  o = run(rig)
  o.verdict == :could_not_look && o.line.include?("check_runs")
end
check("M15 a run pinned to a sha that is another head: WRONG-HEAD") do
  rig = Rig.new([ok("id" => 77, "status" => "completed", "conclusion" => "success", "head_sha" => "d" * 40)])
  o = run(rig, TR)
  o.verdict == :wrong_head && o.line.include?("dddddddddddd")
end
check("M16 the reader is asked for the target's path") do
  rig = Rig.new([checks(cr("a", "completed", "success"))])
  run(rig)
  rig.paths == [W.path_for(TC)]
end
check("M17 a state change is logged once, not every poll") do
  q = checks(cr("a", "queued"))
  rig = Rig.new([q, q, q, checks(cr("a", "completed", "success"))])
  run(rig, max: 5000)
  rig.log.count { |l| l.include?("not completed") } == 1
end

if $failures.empty?
  puts "gh-ci-wait manager: #{$checks} checks passed"
  exit 0
end
$failures.each { |f| puts "FAIL #{f}" }
puts "gh-ci-wait manager: #{$failures.size} of #{$checks} checks failed"
exit 1
