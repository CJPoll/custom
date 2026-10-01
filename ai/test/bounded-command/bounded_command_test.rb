# frozen_string_literal: true

# Deterministic suite for ai/lib/bounded_command.rb (DND-1088). Real child
# processes, no network. The cases that matter are the hangs: the call must
# return through its bound, say timed_out, and leave no process of the group
# alive, including one that ignores TERM and one that holds the pipes open.
# Every verdict is an event (a return, an exit, a file, the kernel's process
# state); the clock only caps a hang, reported as HANG (DND-1569, DND-1595).

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
# How long a hung child sleeps: past every hang cap and the b8/b9 callers' 600
# s bound, so it never ends on its own while a case waits on it, yet finite,
# so a child a broken library leaks dies within the hour (DND-1595).
CHILD_LIFE_S = 3600
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

# "The call returned" is an EVENT too (DND-1595). The block runs on a thread
# and the wait ends when that thread does: [:returned, value]. The clock only
# caps a hang: [:hang, note], and the thread is killed, so run's own cleanup
# kills its group; the note says whether that cleanup itself finished. Before
# DND-1595, b5 and b7 judged `seconds <= bound`, so a call that returned
# correctly on a slow machine read as a FAIL.
def await_return(cap: HANG_CAP_S, clock: MONO, pause: PAUSE, &blk)
  t = Thread.new(&blk)
  t.report_on_exception = false
  return [:returned, t.value] if await_event(cap: cap, clock: clock, pause: pause) { !t.alive? } == :done

  t.kill
  ended = t.join(cap)
  [:hang, ended ? "its cleanup then finished" : "its cleanup was still running after a second cap"]
end

# Kernel state of +pid+ for a HANG line: diagnostic text, never a verdict.
def proc_note(pid)
  f = ProcState.fields(pid)
  f ? "state #{f.first}" : "gone"
rescue SystemCallError, ProcState::Unreadable => e
  "unknown (#{e.class})"
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

# r-cases (DND-1595): the waits b5, b7, b8 and b9 use. A slow machine moves
# the clock, never the verdict; the clock only caps a hang. Each clock is
# injected, so these cases do not depend on how fast this machine is.
#
# r1 a call that returns after 10 s of slow-machine time. b5 and b7 used to
# judge `seconds <= 7` (the 1 s bound plus graces), so this correct return
# read as a FAIL. The call moves the clock only after the wait has read its
# deadline (the first pause), so the 10 s always fall inside the wait.
skew = 0.0
waiting = Queue.new
state, v = await_return(clock: -> { MONO.call + skew }, pause: lambda {
  waiting << true if waiting.empty?
  PAUSE.call
}) do
  waiting.pop
  skew += 10
  :ok
end
check("r1 a call that returns after 10 s of slow-machine time is :returned, not a FAIL",
      state == :returned && v == :ok, [state, v].inspect)

# r2 an event (a pid file, a caller's exit) that comes after 16 s of
# slow-machine time. b8 and b9 used to give up at 10 s and FAIL.
polls = 0
skew = 0.0
r = await_event(clock: -> { MONO.call + skew }, pause: lambda {
  polls += 1
  skew += 4
}) { polls >= 4 }
check("r2 an event after 16 s of slow-machine time is :done, not a FAIL", r == :done, "#{r.inspect} after #{polls} polls")

# r3 a call still blocked when the cap lapses is :hang, reported apart from a
# FAIL, and its thread is killed so nothing outlives the wait.
lapsed = 0.0
blocked = Queue.new
state, = await_return(clock: -> { lapsed += 1000 }, pause: -> {}) { blocked.pop }
check("r3 a call still blocked at the cap is :hang, never a FAIL verdict", state == :hang, state.inspect)

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
  # The child names itself with $BASHPID: inside a ( ) subshell $$ is still
  # the leader's pid, so the gone checks never looked at the child (DND-1594).
  # The child outlives every cap, so the call can only return through its own
  # bound: the return is the event (DND-1595), and nothing times it.
  pids = File.join(tmp, "pids")
  script = "echo $$ > #{pids}; (trap '' TERM; echo $BASHPID >> #{pids}; exec sleep #{CHILD_LIFE_S}) & wait"
  state, r = await_return { BoundedCommand.run(["bash", "-c", script], timeout: 1) }
  if state == :hang
    hang("b5 the hang returns", "BoundedCommand.run still blocked at the #{HANG_CAP_S}s hang cap; #{r}")
  else
    check("b5 hang returns timed_out", r.timed_out && r.exitstatus.nil? && !r.success?, r.inspect)
  end
  recorded = File.exist?(pids) ? File.read(pids).split.map(&:to_i) : []
  check("b5 recorded the leader and the child", recorded.size == 2, recorded.inspect)
  # DND-1594: two copies of the leader's pid would make the gone checks below
  # pass without ever looking at the TERM-ignoring child.
  check("b5 the recorded child is not the leader", recorded.uniq.size == 2, recorded.inspect)
  survivors = recorded.reject { |p| check_gone("b5 no process of the group survives (TERM-ignoring child included): pid #{p}", p) }
  survivors.each { |p| Process.kill("KILL", p) rescue nil } # rubocop:disable Style/RescueModifier

  # b7 the leader exits 0 in time, but a helper it started keeps stdout open
  # (a keyring/credential helper): the bound covers the reads, so this is
  # timed_out and the helper is killed, never an endless block. The helper
  # outlives every cap, so a return at all is the bound's.
  hpids = File.join(tmp, "helper")
  state, r = await_return { BoundedCommand.run(["bash", "-c", "sleep #{CHILD_LIFE_S} & echo $! > #{hpids}; echo hi"], timeout: 1) }
  if state == :hang
    hang("b7 a helper holding stdout does not block the call", "BoundedCommand.run still blocked at the #{HANG_CAP_S}s hang cap; #{r}")
  else
    check("b7 exit 0 with a helper holding stdout is timed_out", r.timed_out && !r.success?, r.inspect)
  end
  helper = File.exist?(hpids) ? File.read(hpids).to_i : 0
  unless check_gone("b7 the helper holding stdout was killed", helper)
    Process.kill("KILL", helper) rescue nil # rubocop:disable Style/RescueModifier
  end

  # b8 the CALLER is interrupted (Ctrl-C, an outer timeout) while the child
  # hangs: the child is in its own group, so the caller must kill it on the way
  # out, and must not wait for it.
  #
  # b8 and b9 deliver INT to a caller they spawn. An ignored signal survives
  # fork+exec, and Ruby leaves an INT it inherited ignored alone, so a gate
  # launched with `&` from a non-interactive shell (SIGINT ignored) ran these
  # callers deaf to INT: 4 deterministic FAILs that read as a load flake
  # (measured 2026-09-29, 2 of 2 backgrounded gates; the DND-815b class). Each
  # caller is launched with INT reset to default, and this process ignores INT
  # around b8/b9 so every run exercises the hostile environment.
  #
  # Every wait here is on an event (DND-1595): the child's pid file, then the
  # caller's exit. Before, each was a 10 s verdict. The caller's own bound
  # (600 s) is past the hang cap, so a caller that ignored the INT is a HANG,
  # never an exit that reads as prompt; and the exit must be the INT's.
  lib = File.expand_path("../../lib/bounded_command", __dir__)
  default_int = ["env", "--default-signal=INT"]
  prior_int = Signal.trap("INT", "IGNORE")
  # A caller still running at a cap is KILLed with the groups of its children,
  # which run started in their own groups: nothing a HANG leaves outlives it.
  kill_caller = lambda do |caller|
    kids = begin
      File.read("/proc/#{caller}/task/#{caller}/children").split.map(&:to_i)
    rescue SystemCallError
      []
    end
    Process.kill("KILL", caller)
    Process.wait(caller)
    kids.each { |k| Process.kill("KILL", -k) rescue nil } # rubocop:disable Style/RescueModifier
  end
  interrupted_caller = lambda do |label, what, prelude, pidfile|
    code = "#{prelude}BoundedCommand.run(['bash', '-c', 'echo $$ > #{pidfile}; exec sleep #{CHILD_LIFE_S}'], timeout: 600)"
    caller = Process.spawn(*default_int, RbConfig.ruby, "-r", lib, "-e", code, %i[out err] => File::NULL)
    status = nil
    reap = -> { status ||= Process.waitpid2(caller, Process::WNOHANG)&.last }
    child = 0
    if await_event { File.size?(pidfile) || reap.call } == :hang
      hang("#{label} the hung child started", "no pid file at the #{HANG_CAP_S}s hang cap; caller #{proc_note(caller)}")
    else
      child = File.size?(pidfile) ? File.read(pidfile).to_i : 0
      check("#{label} the hung child started", child.positive?, "the caller exited first: #{status.inspect}")
    end
    Process.kill("INT", caller) unless status
    if await_event { reap.call } == :hang
      hang("#{label} a caller #{what} exits",
           "caller #{caller} #{proc_note(caller)} at the #{HANG_CAP_S}s hang cap; child #{child.positive? ? proc_note(child) : 'not recorded'}")
      kill_caller.call(caller)
    else
      check("#{label} a caller #{what} exits on the interrupt", status.termsig == Signal.list["INT"], status.inspect)
    end
    check_gone("#{label} a caller #{what} leaves no hung child", child)
    begin
      Process.kill("KILL", child) if child.positive? && ProcState.running?(child)
    rescue SystemCallError, ProcState::Unreadable
      nil
    end
  end
  interrupted_caller.call("b8", "interrupted while run waits", "", File.join(tmp, "caller-child"))

  # b9 the caller is interrupted just AFTER the child is spawned. With Open3's
  # block form that was before run's cleanup was armed: the interrupt left a
  # hung orphan, or Open3's ensure joined the child and waited out its whole
  # life. Measured 2026-09-28 under load 42: b8 hit the window 2 runs in 4.
  # The first Process.detach (called right after the spawn) blocks until the
  # INT arrives, so the INT lands between the spawn and wait_bounded however
  # slow the machine is. It may land even earlier, between the spawn and that
  # first detach; then run's cleanup makes the first call, while unwinding the
  # Interrupt ($! is set), so the override never blocks on the cleanup path.
  slow_detach = "module Process; class << self; alias_method :bc_detach, :detach; " \
                "def detach(pid); held = @bc_held; @bc_held = true; t = bc_detach(pid); sleep unless held || $!; t; end; end; end; "
  interrupted_caller.call("b9", "interrupted before cleanup is armed", slow_detach, File.join(tmp, "caller-child-9"))
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
