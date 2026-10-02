# frozen_string_literal: true

# Deterministic suite for ai/lib/proc_state.rb (DND-1550). The zombie is
# FORCED: this process spawns the target and does not wait on it, so once
# killed it stays a zombie until the suite reaps it. No load, no repeated runs;
# each bounded wait only caps a hang.

require "tmpdir"
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
  cut = raw.rindex(") ")
  cut && raw[(cut + 2)..].split.first
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

  # R-5: a process name holding ") Z (" and a newline. The kernel names a
  # script's process after the script file; a first-line or first-") " parse
  # would read state "Z".
  Dir.mktmpdir("proc-state-r5") do |dir|
    weird = File.join(dir, "x) Z (\ny")
    File.write(weird, "#!/bin/bash\nwhile :; do sleep 600; done\n")
    File.chmod(0o755, weird)
    # [path, argv0]: a single string with metacharacters would go to /bin/sh.
    w = Process.spawn([weird, weird], pgroup: true, out: File::NULL, err: File::NULL)
    pids << w
    comm = nil
    300.times do
      comm = File.read("/proc/#{w}/comm") rescue nil
      break if comm == "x) Z (\ny\n"

      sleep 0.05
    end
    check("R-5 premise: the process name is \"x) Z (\\ny\"", comm == "x) Z (\ny\n", comm.inspect)
    ws = ProcState.starttime(w)
    check("R-5 its start time parses", ws.to_s.match?(/\A[0-9]+\z/), ws.inspect)
    check("R-5 it is running, not a zombie", ProcState.running?(w, start: ws))
    Process.kill("KILL", -w) # the group: the script and its sleep
    if await_state(w, "Z")
      check("R-5 killed, it is not running", !ProcState.running?(w))
    else
      check("R-5 fixture: the killed target becomes a zombie", false, "state=#{state(w).inspect}")
    end
  end

  # R-6 (DND-1625): the pure parse every Ruby reader shares, on a FIXTURE
  # stat whose comm holds a newline and ") ". No process is started.
  odd = "4242 (x) Z 7 9\n) T) S 1 4242 4242 0 -1 4194560 0 0 0 0 0 0 0 0 20 0 1 0 555 1000 10\n"
  if ProcState.respond_to?(:stat_fields)
    f = ProcState.stat_fields(odd)
    check("R-6 stat_fields takes the fields after the LAST \") \": state S", f&.first == "S", f.inspect)
    check("R-6 stat_fields: pgrp 4242 and starttime 555", f && f[2] == "4242" && f[19] == "555", f.inspect)
    check("R-6 stat_fields: no ') ' is nil, never a guess", ProcState.stat_fields("88 (broken S 1 88 88\n").nil?)
    check("R-6 stat_fields: empty is nil", ProcState.stat_fields("").nil?)
  else
    check("R-6 ProcState.stat_fields exists", false, "undefined")
  end

  # R-7 (DND-1625): harness-gate's SIGTERM self-test judged its fixture
  # processes with File.read(stat)[/\) (\S)/, 1], the FIRST ") ", which reads
  # the fixture above as a zombie. It now asks ProcState, the shared rule.
  hg = File.read(File.expand_path("../../bin/harness-gate", __dir__))
  check("R-7 harness-gate has no first-\") \" stat parse", !hg.include?('/stat")[/\) (\S)/'))
  check("R-7 harness-gate reads its fixture's state through ProcState.fields",
        hg.include?("ProcState.fields(hp)&.first"))

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
