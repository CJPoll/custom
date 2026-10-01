# frozen_string_literal: true

# Deterministic suite for ai/lib/bounded_command.rb (DND-1088). Real child
# processes, no network. The cases that matter are the hangs: the call must
# return within its bound, say timed_out, and leave no process of the group
# alive, including one that ignores TERM and one that holds the pipes open.

require "tmpdir"
require "rbconfig"
require_relative "../../lib/bounded_command"
require_relative "../../lib/proc_state"

$pass = 0
$fail = 0
$hang = 0
def check(label, cond, detail = nil)
  if cond
    $pass += 1
    puts "  ok   #{label}"
  else
    $fail += 1
    puts "  FAIL #{label}#{detail ? " -- #{detail}" : ''}"
  end
end

# "Gone after a kill" is an EVENT, waited on (DND-1569). A KILL lands
# asynchronously, and a killed orphan is a zombie until PID 1 reaps it, so the
# verdict is the kernel's: absent, state Z or X, or a reused pid
# (ProcState.running?, DND-1550). The clock never decides it. HANG_CAP_S only
# caps a hang; a lapsed cap is :hang, which the suite reports apart from a
# FAIL. Before DND-1569 a 2 s bound was the verdict, and it failed about 1 run
# in 6 at load 32 on the unchanged library.
HANG_CAP_S = 120
MONO = -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }
PAUSE = -> { sleep 0.05 }

# :done once the block is true, or :hang when the cap lapsed first.
def await_event(cap: HANG_CAP_S, clock: MONO, pause: PAUSE)
  deadline = clock.call + cap
  loop do
    return :done if yield
    return :hang if clock.call >= deadline

    pause.call
  end
end

# :gone, or :hang when the cap lapsed while the process still ran. The start
# time is taken at the first read, after the kill: a pid reaped and reused
# before then is waited on as a stranger, so it reads as a HANG (fail-safe,
# never a false pass).
def await_gone(pid, cap: HANG_CAP_S, clock: MONO, pause: PAUSE)
  start = ProcState.starttime(pid)
  return :gone if start.nil?

  r = await_event(cap: cap, clock: clock, pause: pause) { !ProcState.running?(pid, start: start) }
  r == :done ? :gone : :hang
end

def hang(label, detail)
  $hang += 1
  puts "  HANG #{label} -- #{detail}"
end

# Whether SIGKILL reached +pid+: pending, or the process already exiting
# (PF_EXITING). Diagnostic text for a HANG line only, never a verdict.
def kill_landed(pid)
  status = File.read("/proc/#{pid}/status")
  pending = status.scan(/^(?:SigPnd|ShdPnd):\s*(\h+)/).flatten.any? { |m| (m.to_i(16) >> 8).odd? }
  f = ProcState.fields(pid)
  return "gone at the cap" if f.nil?

  exiting = (f[6].to_i & 0x4).positive?
  pending || exiting ? "yes (the machine has not run its exit yet)" : "no (nothing killed it: a leak)"
rescue SystemCallError, ProcState::Unreadable => e
  "unknown (#{e.class})"
end

# Records a check that +pid+ is gone; false only on a HANG. A process still
# running at the cap is a HANG line and $hang, never a FAIL. A missing pid is
# a FAIL: it must never read as gone.
def check_gone(label, pid)
  unless pid.is_a?(Integer) && pid.positive?
    check(label, false, "no pid recorded (#{pid.inspect})")
    return true
  end
  if await_gone(pid) == :gone
    check(label, true)
    true
  else
    hang(label, "pid #{pid} still running after the #{HANG_CAP_S}s hang cap; KILL landed: #{kill_landed(pid)}")
    false
  end
end

def elapsed
  t = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  r = yield
  [r, Process.clock_gettime(Process::CLOCK_MONOTONIC) - t]
end

# d-cases (DND-1569): the helper that judges "gone after a kill". The verdict
# is the kernel's (absent, zombie, dead); the clock only caps a hang, and a
# lapsed cap is :hang, never a FAIL verdict. Each clock is injected, so these
# cases do not depend on how fast this machine is.
d_pids = []
begin
  # d1 a forced zombie: our own child, killed and not reaped. With a clock
  # already past any cap it is still :gone, because the kernel says so. The
  # zombie is itself an event: waited on under the hang cap, a HANG if late.
  z = Process.spawn("sleep", "600", out: File::NULL, err: File::NULL)
  d_pids << z
  Process.kill("KILL", z)
  if await_event { ProcState.fields(z)&.first == "Z" } == :hang
    hang("d1 premise: the killed, unreaped child is a zombie",
         "state #{ProcState.fields(z)&.first.inspect} after the #{HANG_CAP_S}s hang cap")
  else
    lapsed = 0.0
    r = await_gone(z, clock: -> { lapsed += 1000 })
    check("d1 a zombie is :gone whatever the clock reads", r == :gone, r.inspect)
  end

  # d2 a delayed exit on a slow machine: three polls pass while the clock
  # races 1 s per poll (past the old 2 s bound), then the KILL lands. The wait
  # ends on the exit, not on the clock.
  late = Process.spawn("sleep", "600", out: File::NULL, err: File::NULL)
  d_pids << late
  polls = 0
  skew = 0.0
  r = await_gone(late,
                 clock: -> { MONO.call + skew },
                 pause: lambda {
                   polls += 1
                   if polls <= 3
                     skew += 1
                   elsif polls == 4
                     Process.kill("KILL", late)
                   end
                   sleep 0.05
                 })
  check("d2 a KILL that lands after 3 s of slow-machine time is :gone, not a FAIL", r == :gone,
        "#{r.inspect} after #{polls} polls")

  # d3 a process nobody kills, with a clock past the cap at once: the cap
  # lapses, and that is :hang (reported apart from a FAIL), never a verdict.
  never = Process.spawn("sleep", "600", out: File::NULL, err: File::NULL)
  d_pids << never
  lapsed = 0.0
  r = await_gone(never, clock: -> { lapsed += 1000 }, pause: -> {})
  check("d3 a lapsed cap is :hang, never a FAIL verdict", r == :hang, r.inspect)
ensure
  d_pids.each do |p|
    Process.kill("KILL", p) rescue nil # rubocop:disable Style/RescueModifier
    Process.wait(p) rescue nil # rubocop:disable Style/RescueModifier
  end
end

Dir.mktmpdir do |tmp|
  r = BoundedCommand.run(["sh", "-c", "echo out; echo err >&2"], timeout: 10)
  check("b1 success captured", r.success? && r.out == "out\n" && r.err == "err\n" && !r.timed_out, r.inspect)

  r = BoundedCommand.run(["sh", "-c", "exit 3"], timeout: 10)
  check("b2 non-zero exit is not success", !r.success? && r.exitstatus == 3 && !r.timed_out, r.inspect)

  r = BoundedCommand.run(["/nonexistent/dnd-1088-cli"], timeout: 10)
  check("b3 missing executable is 127, not a raise", r.exitstatus == 127 && !r.timed_out && !r.success?, r.inspect)

  r = BoundedCommand.run(["pwd"], timeout: 10, chdir: tmp)
  check("b4 chdir honoured", r.out.strip == File.realpath(tmp), r.out)

  # b10 stdin (DND-1427): a file path is the child's stdin, read to EOF; the
  # default stays /dev/null, so a reader of stdin never blocks.
  input = File.join(tmp, "stdin.txt")
  File.write(input, "MARK line\nsecond\n")
  r = BoundedCommand.run(["cat"], timeout: 10, stdin: input)
  check("b10 stdin file reaches the child", r.success? && r.out == "MARK line\nsecond\n", r.inspect)
  r = BoundedCommand.run(["cat"], timeout: 10)
  check("b10 default stdin is empty, not inherited", r.success? && r.out == "", r.inspect)

  # b11 a signalled child reports termsig; an exited one reports nil. The
  # 128+n exitstatus is kept for existing callers, but only termsig can tell a
  # real `exit 137` from a KILL.
  r = BoundedCommand.run(["sh", "-c", "kill -9 $$"], timeout: 10)
  check("b11 signalled child reports termsig 9", r.termsig == 9 && !r.success? && !r.timed_out, r.inspect)
  r = BoundedCommand.run(["sh", "-c", "exit 137"], timeout: 10)
  check("b11 exit 137 is not a signal", r.termsig.nil? && r.exitstatus == 137, r.inspect)

  # b5 the hang: a leader that waits on a TERM-ignoring child holding stdout.
  pids = File.join(tmp, "pids")
  script = "echo $$ > #{pids}; (trap '' TERM; echo $$ >> #{pids}; exec sleep 300) & wait"
  r, secs = elapsed { BoundedCommand.run(["bash", "-c", script], timeout: 1) }
  check("b5 hang returns timed_out", r.timed_out && r.exitstatus.nil? && !r.success?, r.inspect)
  bound = 1 + BoundedCommand::KILL_GRACE_S + BoundedCommand::READER_GRACE_S + 2
  check("b5 returns within the bound plus grace (#{secs.round(1)}s <= #{bound}s)", secs <= bound)
  recorded = File.exist?(pids) ? File.read(pids).split.map(&:to_i) : []
  check("b5 recorded the leader and the child", recorded.size == 2, recorded.inspect)
  survivors = recorded.reject { |p| check_gone("b5 no process of the group survives (TERM-ignoring child included): pid #{p}", p) }
  survivors.each { |p| Process.kill("KILL", p) rescue nil } # rubocop:disable Style/RescueModifier

  # b7 the leader exits 0 in time, but a helper it started keeps stdout open
  # (a keyring/credential helper): the bound covers the reads, so this is
  # timed_out and the helper is killed, never a 15s (or endless) block.
  hpids = File.join(tmp, "helper")
  r, secs = elapsed { BoundedCommand.run(["bash", "-c", "sleep 300 & echo $! > #{hpids}; echo hi"], timeout: 1) }
  check("b7 exit 0 with a helper holding stdout is timed_out", r.timed_out && !r.success?, r.inspect)
  check("b7 returns within the bound plus grace (#{secs.round(1)}s <= #{bound}s)", secs <= bound)
  helper = File.exist?(hpids) ? File.read(hpids).to_i : 0
  check_gone("b7 the helper holding stdout was killed", helper)

  # b8 the CALLER is interrupted (Ctrl-C, an outer timeout) while the child
  # hangs: the child is in its own group, so the caller must kill it on the way
  # out, and must not wait for it.
  lib = File.expand_path("../../lib/bounded_command", __dir__)
  # b8 and b9 deliver INT to a caller they spawn. An ignored signal survives
  # fork+exec, and Ruby leaves an INT it inherited ignored alone, so a gate
  # launched with `&` from a non-interactive shell (SIGINT ignored) ran these
  # callers deaf to INT: 4 deterministic FAILs that read as a load flake
  # (measured 2026-09-29, 2 of 2 backgrounded gates; the DND-815b class). Each
  # caller is launched with INT reset to default, and this process ignores INT
  # around b8/b9 so every run exercises the hostile environment.
  default_int = ["env", "--default-signal=INT"]
  prior_int = Signal.trap("INT", "IGNORE")
  cpid = File.join(tmp, "caller-child")
  caller = Process.spawn(*default_int, RbConfig.ruby, "-r", lib, "-e",
                         "BoundedCommand.run(['bash', '-c', 'echo $$ > #{cpid}; exec sleep 300'], timeout: 120)",
                         %i[out err] => File::NULL)
  deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 10
  sleep 0.05 until File.size?(cpid) || Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
  child = File.size?(cpid) ? File.read(cpid).to_i : 0
  check("b8 the hung child started", child.positive?)
  Process.kill("INT", caller)
  gone = nil
  _, secs = elapsed do
    50.times do
      gone = Process.waitpid(caller, Process::WNOHANG)
      break if gone

      sleep 0.2
    end
  end
  check("b8 an interrupted caller exits promptly (#{secs.round(1)}s)", !gone.nil?)
  check_gone("b8 an interrupted caller leaves no hung child", child)
  unless gone
    Process.kill("KILL", caller)
    Process.wait(caller)
  end
  Process.kill("KILL", child) if child.positive? && ProcState.running?(child)

  # b9 the caller is interrupted just AFTER the child is spawned. With Open3's
  # block form that was before run's cleanup was armed: the interrupt left a
  # hung orphan, or Open3's ensure joined the child and waited out its whole
  # life. Measured 2026-09-28 under load 42: b8 hit the window 2 runs in 4.
  # A slow Process.detach (called right after the spawn) makes it deterministic.
  cpid9 = File.join(tmp, "caller-child-9")
  slow_detach = "module Process; class << self; alias_method :bc_detach, :detach; " \
                "def detach(pid); t = bc_detach(pid); sleep 1; t; end; end; end"
  caller9 = Process.spawn(*default_int, RbConfig.ruby, "-r", lib, "-e",
                          "#{slow_detach}; BoundedCommand.run(['bash', '-c', 'echo $$ > #{cpid9}; exec sleep 300'], timeout: 120)",
                          %i[out err] => File::NULL)
  deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 10
  sleep 0.05 until File.size?(cpid9) || Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
  child9 = File.size?(cpid9) ? File.read(cpid9).to_i : 0
  check("b9 the hung child started", child9.positive?)
  Process.kill("INT", caller9)
  gone9 = nil
  _, secs9 = elapsed do
    50.times do
      gone9 = Process.waitpid(caller9, Process::WNOHANG)
      break if gone9

      sleep 0.2
    end
  end
  check("b9 a caller interrupted before cleanup is armed exits promptly (#{secs9.round(1)}s)", !gone9.nil?)
  check_gone("b9 it leaves no hung child", child9)
  unless gone9
    Process.kill("KILL", caller9)
    Process.wait(caller9)
  end
  Process.kill("KILL", child9) if child9.positive? && ProcState.running?(child9)
  Signal.trap("INT", prior_int)

  [0, -1, nil, "5"].each do |bad|
    raised = begin
      BoundedCommand.run(["true"], timeout: bad)
      false
    rescue ArgumentError
      true
    end
    check("b6 bound #{bad.inspect} refused, never read as no bound", raised)
  end

  # b12 kill_grace (DND-1506) is a bound too: anything but a positive number
  # is a caller error, never "no grace".
  [0, -1, nil, "0.5"].each do |bad|
    raised = begin
      BoundedCommand.run(["true"], timeout: 10, kill_grace: bad)
      false
    rescue ArgumentError
      true
    end
    check("b12 kill_grace #{bad.inspect} refused", raised)
  end
  r = BoundedCommand.run(["true"], timeout: 10, kill_grace: 0.5)
  check("b12 a fractional kill_grace is accepted", r.success?, r.inspect)
end

puts "bounded_command: #{$pass}/#{$pass + $fail + $hang} checks passed, #{$fail} failed, #{$hang} hung"
if $fail.positive?
  warn "Fix: repair ai/lib/bounded_command.rb until every case above passes; a hung command must return within its bound and leave no process behind."
end
if $hang.positive?
  warn "HANG: #{$hang} process(es) still ran at the #{HANG_CAP_S}s hang cap. That is not a verdict on the timing. " \
       "Fix: read each HANG line; \"KILL landed: no\" is a leak in ai/lib/bounded_command.rb, \"yes\" is a machine " \
       "too stalled to run an exit in #{HANG_CAP_S}s, so re-run when it is idle."
end
exit 1 if $fail.positive? || $hang.positive?
