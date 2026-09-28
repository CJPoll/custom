# frozen_string_literal: true

# Deterministic suite for ai/lib/bounded_command.rb (DND-1088). Real child
# processes, no network. The cases that matter are the hangs: the call must
# return within its bound, say timed_out, and leave no process of the group
# alive, including one that ignores TERM and one that holds the pipes open.

require "tmpdir"
require "rbconfig"
require_relative "../../lib/bounded_command"

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

def alive?(pid)
  Process.kill(0, pid)
  # A zombie answers kill(0); read its state so it counts as dead.
  File.read("/proc/#{pid}/stat").split(") ").last.start_with?("Z") ? false : true
rescue Errno::ESRCH, Errno::ENOENT
  false
end

# A KILL is delivered asynchronously: a loaded machine may not have run the
# target's exit yet when run returns. Poll a short bound for it to die. A leaked
# process was never signalled and lives for its whole sleep, so it still fails.
# Measured 2026-09-28 at load 32: b7's bare alive? check failed 1 run in 6 on
# the unchanged library.
def dead_soon?(pid, bound = 2)
  deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + bound
  while alive?(pid)
    return false if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

    sleep 0.05
  end
  true
end

def elapsed
  t = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  r = yield
  [r, Process.clock_gettime(Process::CLOCK_MONOTONIC) - t]
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

  # b5 the hang: a leader that waits on a TERM-ignoring child holding stdout.
  pids = File.join(tmp, "pids")
  script = "echo $$ > #{pids}; (trap '' TERM; echo $$ >> #{pids}; exec sleep 300) & wait"
  r, secs = elapsed { BoundedCommand.run(["bash", "-c", script], timeout: 1) }
  check("b5 hang returns timed_out", r.timed_out && r.exitstatus.nil? && !r.success?, r.inspect)
  bound = 1 + BoundedCommand::KILL_GRACE_S + BoundedCommand::READER_GRACE_S + 2
  check("b5 returns within the bound plus grace (#{secs.round(1)}s <= #{bound}s)", secs <= bound)
  recorded = File.exist?(pids) ? File.read(pids).split.map(&:to_i) : []
  check("b5 recorded the leader and the child", recorded.size == 2, recorded.inspect)
  survivors = recorded.reject { |p| dead_soon?(p) }
  check("b5 no process of the group survives (TERM-ignoring child included)", survivors.empty?, survivors.inspect)
  survivors.each { |p| Process.kill("KILL", p) rescue nil } # rubocop:disable Style/RescueModifier

  # b7 the leader exits 0 in time, but a helper it started keeps stdout open
  # (a keyring/credential helper): the bound covers the reads, so this is
  # timed_out and the helper is killed, never a 15s (or endless) block.
  hpids = File.join(tmp, "helper")
  r, secs = elapsed { BoundedCommand.run(["bash", "-c", "sleep 300 & echo $! > #{hpids}; echo hi"], timeout: 1) }
  check("b7 exit 0 with a helper holding stdout is timed_out", r.timed_out && !r.success?, r.inspect)
  check("b7 returns within the bound plus grace (#{secs.round(1)}s <= #{bound}s)", secs <= bound)
  helper = File.exist?(hpids) ? File.read(hpids).to_i : 0
  check("b7 the helper holding stdout was killed", helper.positive? && dead_soon?(helper), helper.to_s)

  # b8 the CALLER is interrupted (Ctrl-C, an outer timeout) while the child
  # hangs: the child is in its own group, so the caller must kill it on the way
  # out, and must not wait for it.
  lib = File.expand_path("../../lib/bounded_command", __dir__)
  cpid = File.join(tmp, "caller-child")
  caller = Process.spawn(RbConfig.ruby, "-r", lib, "-e",
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
  check("b8 an interrupted caller leaves no hung child", child.positive? && dead_soon?(child), child.to_s)
  unless gone
    Process.kill("KILL", caller)
    Process.wait(caller)
  end
  Process.kill("KILL", child) if child.positive? && alive?(child)

  # b9 the caller is interrupted just AFTER the child is spawned. With Open3's
  # block form that was before run's cleanup was armed: the interrupt left a
  # hung orphan, or Open3's ensure joined the child and waited out its whole
  # life. Measured 2026-09-28 under load 42: b8 hit the window 2 runs in 4.
  # A slow Process.detach (called right after the spawn) makes it deterministic.
  cpid9 = File.join(tmp, "caller-child-9")
  slow_detach = "module Process; class << self; alias_method :bc_detach, :detach; " \
                "def detach(pid); t = bc_detach(pid); sleep 1; t; end; end; end"
  caller9 = Process.spawn(RbConfig.ruby, "-r", lib, "-e",
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
  check("b9 it leaves no hung child", child9.positive? && dead_soon?(child9), child9.to_s)
  unless gone9
    Process.kill("KILL", caller9)
    Process.wait(caller9)
  end
  Process.kill("KILL", child9) if child9.positive? && alive?(child9)

  [0, -1, nil, "5"].each do |bad|
    raised = begin
      BoundedCommand.run(["true"], timeout: bad)
      false
    rescue ArgumentError
      true
    end
    check("b6 bound #{bad.inspect} refused, never read as no bound", raised)
  end
end

puts "bounded_command: #{$pass}/#{$pass + $fail} checks passed"
if $fail.positive?
  warn "Fix: repair ai/lib/bounded_command.rb until every case above passes; a hung command must return within its bound and leave no process behind."
  exit 1
end
