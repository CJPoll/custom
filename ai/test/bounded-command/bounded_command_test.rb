# frozen_string_literal: true

# Deterministic suite for ai/lib/bounded_command.rb (DND-1088). Real child
# processes, no network. The cases that matter are the hangs: the call must
# return within its bound, say timed_out, and leave no process of the group
# alive, including one that ignores TERM and one that holds the pipes open.

require "tmpdir"
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
  survivors = recorded.select { |p| alive?(p) }
  check("b5 no process of the group survives (TERM-ignoring child included)", survivors.empty?, survivors.inspect)
  survivors.each { |p| Process.kill("KILL", p) rescue nil } # rubocop:disable Style/RescueModifier

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
