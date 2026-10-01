# frozen_string_literal: true

# Deterministic suite for ai/lib/proc_state.rb (DND-1550). The zombie is
# FORCED: this process spawns the target and does not wait on it, so once
# killed it stays a zombie until the suite reaps it. No load, no repeated runs;
# each bounded wait only caps a hang.

require_relative "../../lib/proc_state"

$pass = 0
$fail = 0
def check(label, cond, detail = nil)
  if cond
    $pass += 1
    puts "  ok   #{label}"
  else
    $fail += 1
    puts "  FAIL #{label}#{detail ? " -- #{detail}" : ''}"
  end
end

def state(pid)
  raw = File.read("/proc/#{pid}/stat")
  raw[(raw.rindex(") ") + 2)..].split.first
rescue SystemCallError
  nil
end

def await_state(pid, want, bound = 30)
  deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + bound
  sleep 0.05 until state(pid) == want || Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
  state(pid) == want
end

puts "proc_state self-test"
pids = []
begin
  # R-1: a live process.
  live = Process.spawn("sleep", "600", out: File::NULL, err: File::NULL)
  pids << live
  start = ProcState.starttime(live)
  check("R-1 a live sleep is running", ProcState.running?(live))
  check("R-1 with its own start time it is running", ProcState.running?(live, start: start), start.inspect)
  check("R-1 with another start time it is another process (pid reused)", !ProcState.running?(live, start: "1"))
  check("R-1 wait_gone on a live process is false at the bound", ProcState.wait_gone(live, timeout: 0.2) == false)

  # R-2: the C-10 state. Killed, not reaped: a zombie.
  z = Process.spawn("sleep", "600", out: File::NULL, err: File::NULL)
  pids << z
  Process.kill("KILL", z)
  if await_state(z, "Z")
    premise = begin
      Process.kill(0, z)
      true
    rescue Errno::ESRCH
      false
    end
    check("R-2 premise: the killed target is a zombie and Process.kill(0) still succeeds", premise)
    check("R-2 a zombie is not running", !ProcState.running?(z), "state=#{state(z)}")
    check("R-2 wait_gone on a zombie is true", ProcState.wait_gone(z, timeout: 30))
  else
    check("R-2 fixture: the killed target becomes a zombie", false, "state=#{state(z).inspect}")
  end

  # R-3: a reaped pid.
  r = Process.spawn("true")
  Process.wait(r)
  check("R-3 a reaped pid is not running", !ProcState.running?(r))

  # R-4: malformed input is an error, never "gone".
  ["", nil, "abc", "0", "-5", "12x"].each do |bad|
    raised = begin
      ProcState.running?(bad)
      false
    rescue ArgumentError => e
      e.message.include?("Fix:")
    end
    check("R-4 running?(#{bad.inspect}) raises ArgumentError with a Fix:", raised)
  end
ensure
  pids.each do |p|
    Process.kill("KILL", p) rescue nil
    Process.wait(p) rescue nil
  end
end

puts
if $fail.zero?
  puts "VERDICT: PASS (#{$pass} cases)"
  exit 0
end
puts "VERDICT: FAIL (#{$fail} failed, #{$pass} passed)"
puts "  Fix: read each FAIL above; repair ai/lib/proc_state.rb and re-run ai/test/proc-state/self-test.sh."
exit 1
