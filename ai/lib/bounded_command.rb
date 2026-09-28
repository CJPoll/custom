# frozen_string_literal: true

# bounded_command — run an external command with a hard wall-clock bound
# (DND-1088).
#
# Why: a forge CLI can hang forever. On 2026-09-28 `glab mr list` blocked on
# its keyring (DND-914) for 28 minutes inside ai/bin/pool-headroom, and every
# wt-preflight on the laptop hung with it. Open3.capture3 has no bound, and
# Timeout around it leaves the child running.
#
# BoundedCommand.run starts the command in its own process group, closes its
# stdin, and reads stdout/stderr on threads. Past the bound it sends TERM to the
# whole group, then KILL after a short grace, so a helper the CLI spawned
# cannot outlive it holding the pipes open. It returns a Result; a timeout is
# `timed_out: true`, never an exit status a caller could read as an answer.
#
# A missing executable is a Result with status 127 and the error text, not a
# raise, so callers keep one shape.
#
# Because the child is not in the terminal's foreground group, a CLI that
# prompts on /dev/tty stops (SIGTTIN) until the bound kills it. That is the
# intent: these callers are unattended, and a prompt is a hang.

require "open3"

module BoundedCommand
  Result = Struct.new(:out, :err, :exitstatus, :timed_out, :seconds, keyword_init: true) do
    def success?
      !timed_out && exitstatus.zero?
    end
  end

  # How long TERM gets before KILL, and how long the pipe readers get once the
  # group is dead (a grandchild that left the group may still hold a pipe).
  KILL_GRACE_S = 2
  READER_GRACE_S = 2

  # A bound must be a positive number of seconds. Anything else is a caller
  # error, never "no bound".
  def self.check_bound!(seconds, name = "timeout")
    return seconds if seconds.is_a?(Numeric) && seconds.positive?

    raise ArgumentError, "#{name} must be a positive number of seconds, got #{seconds.inspect}"
  end

  # -> Result. argv is an Array of Strings; chdir is optional.
  #
  # The bound covers the reads too. A command that exits in time while a
  # helper it started still holds stdout/stderr open is timed_out (its output
  # cannot be known complete), and its group is killed. An exception while
  # waiting (SIGINT, an outer timeout's TERM) kills the group before it
  # propagates: the child is in its own group, so a terminal's Ctrl-C never
  # reaches it.
  #
  # Residuals: a member that calls setsid() leaves the group and is not killed
  # (the call still returns); a process in uninterruptible sleep (D state)
  # survives KILL, and Open3's own cleanup then waits for the kernel to
  # release it.
  def self.run(argv, timeout:, chdir: nil, env: {})
    check_bound!(timeout)
    opts = { pgroup: true }
    opts[:chdir] = chdir if chdir
    deadline = now + timeout
    Open3.popen3(env, *argv, **opts) do |stdin, out, err, wait|
      settled = false
      readers = []
      begin
        stdin.close
        readers = [Thread.new { read_all(out) }, Thread.new { read_all(err) }]
        status = wait.join(timeout)&.value
        drained = status && readers.all? { |t| t.join([deadline - now, 0].max + READER_GRACE_S) }
        if drained
          settled = true
          return Result.new(out: readers[0].value, err: readers[1].value,
                            exitstatus: status.exitstatus || (128 + status.termsig.to_i),
                            timed_out: false, seconds: timeout)
        end

        kill_group(wait)
        settled = true
        texts = readers.map { |t| t.join(READER_GRACE_S) ? t.value.to_s : "" }
        return Result.new(out: texts[0], err: texts[1], exitstatus: nil, timed_out: true, seconds: timeout)
      ensure
        kill_group(wait) unless settled
        readers.each { |t| t.kill if t.alive? }
      end
    end
  rescue SystemCallError => e
    Result.new(out: "", err: e.message, exitstatus: 127, timed_out: false, seconds: timeout)
  end

  def self.now
    Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end

  # A pipe closed under a reader (Open3's cleanup) ends the read quietly.
  def self.read_all(io)
    io.read
  rescue IOError
    ""
  end

  # KILL follows TERM whether or not the leader died: a group member that
  # ignores TERM would otherwise outlive a leader that honoured it.
  def self.kill_group(wait)
    signal_group("TERM", wait.pid)
    wait.join(KILL_GRACE_S)
    signal_group("KILL", wait.pid)
    wait.join(KILL_GRACE_S)
  end

  def self.signal_group(sig, pid)
    Process.kill(sig, -pid)
  rescue Errno::ESRCH, Errno::EPERM
    nil
  end
  private_class_method :now, :read_all, :kill_group, :signal_group
end
