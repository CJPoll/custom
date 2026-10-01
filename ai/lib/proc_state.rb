# frozen_string_literal: true

# ProcState -- is a process still RUNNING, and wait for it to stop. The Ruby
# twin of scripts/test/lib/proc-state.bash (DND-1550); the reasons are there.
#
# In short: Process.kill(0, pid) answers "does a process-table entry exist",
# and it succeeds on a ZOMBIE. A SIGKILLed orphan is a zombie until PID 1 (or a
# subreaper) reaps it, and the SIGKILL itself lands asynchronously. So "it is
# gone" is an event to wait on (bounded, to cap a hang), judged on the
# kernel's state letter in /proc/<pid>/stat.
#
# A malformed pid is an ArgumentError, never "gone". /proc/<pid> present but
# its stat unreadable is ProcState::Unreadable, never "gone" either.
module ProcState
  class Unreadable < StandardError; end

  module_function

  # The stat fields after "(comm) ": [0] state, [2] pgrp, [19] start time.
  # nil when the process does not exist.
  def fields(pid)
    pid = check_pid(pid)
    raw = begin
      File.read("/proc/#{pid}/stat")
    rescue Errno::ENOENT, Errno::ESRCH
      return nil
    rescue SystemCallError => e
      raise Unreadable, "/proc/#{pid}/stat exists but could not be read (#{e.class}). " \
                        "Fix: run as the user that owns the process, with /proc mounted."
    end
    return nil if raw.empty?

    raw[(raw.rindex(") ") + 2)..].split
  end

  def starttime(pid)
    f = fields(pid)
    f && f[19]
  end

  # True when the process exists, is not a zombie (Z) or dead (X/x), and, when
  # +start+ is given, is the same process (its pid not reused).
  def running?(pid, start: nil)
    f = fields(pid)
    return false unless f
    return false if %w[Z X x].include?(f[0])
    return false if start && f[19] != start.to_s

    true
  end

  # Waits up to +timeout+ seconds for the process to stop running. True when
  # it did, false when it was still running at the bound.
  def wait_gone(pid, timeout:, start: nil)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    loop do
      return true unless running?(pid, start: start)
      return false if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

      sleep 0.05
    end
  end

  def check_pid(pid)
    s = pid.to_s
    unless s.match?(/\A[1-9][0-9]*\z/)
      raise ArgumentError, "proc_state: pid #{pid.inspect} is not a positive integer. " \
                           "Fix: pass the pid the caller recorded; a missing pid must never read as 'gone'."
    end
    s.to_i
  end
end
