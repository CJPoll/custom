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

module BoundedCommand
  # termsig is the signal that ended the child; nil when it exited, timed out
  # (see timed_out) or never spawned. A
  # signalled child also reads exitstatus 128+n (existing callers depend on
  # it), which alone cannot tell a KILL from a real `exit 137`.
  Result = Struct.new(:out, :err, :exitstatus, :timed_out, :seconds, :termsig, keyword_init: true) do
    def success?
      !timed_out && exitstatus.zero?
    end
  end

  # How long TERM gets before KILL (the default; a caller that runs under an
  # outer bound passes a shorter kill_grace:), and how long the pipe readers
  # get once the group is dead (a grandchild that left the group may still
  # hold a pipe).
  KILL_GRACE_S = 2
  READER_GRACE_S = 2

  # The production clock and wait primitive (run's clock: and join:).
  MONOTONIC = -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }
  JOIN = ->(thread, seconds) { thread.join(seconds) }

  # One run's clock and wait primitive, carried to its helpers.
  Timing = Struct.new(:clock, :join_fn) do
    def now
      clock.call
    end

    def join(thread, seconds)
      join_fn.call(thread, seconds)
    end
  end
  private_constant :Timing

  # A bound must be a positive number of seconds. Anything else is a caller
  # error, never "no bound".
  def self.check_bound!(seconds, name = "timeout")
    return seconds if seconds.is_a?(Numeric) && seconds.positive?

    raise ArgumentError, "#{name} must be a positive number of seconds, got #{seconds.inspect}"
  end

  # -> Result. argv is an Array of Strings; chdir is optional. stdin is a file
  # path the child reads as its stdin (default /dev/null: a child that reads
  # stdin sees EOF, never the caller's terminal). kill_grace is how long TERM
  # gets before KILL, on a timeout and on an interrupt alike; a caller whose
  # own process can be killed by an outer bound passes one shorter than that
  # bound's TERM-to-KILL gap, so the group is dead before the caller is.
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
  # survives KILL, and run's cleanup then waits for the kernel to
  # release it.
  #
  # clock: and join: are test seams (DND-1648), so a suite can read the SIZE
  # of every bounded wait instead of timing it. clock -> monotonic seconds;
  # join(thread, seconds) -> the thread, or nil when the wait lapsed. Every
  # bounded wait in run goes through join; the one unbounded wait, the final
  # reap in run's cleanup, is that D-state residual. Callers pass neither.
  def self.run(argv, timeout:, chdir: nil, env: {}, stdin: File::NULL, kill_grace: KILL_GRACE_S,
               clock: MONOTONIC, join: JOIN)
    check_bound!(timeout)
    check_bound!(kill_grace, "kill_grace")
    opts = { pgroup: true, in: stdin }
    opts[:chdir] = chdir if chdir
    timing = Timing.new(clock, join)
    deadline = timing.now + timeout
    out_r, out_w = IO.pipe
    err_r, err_w = IO.pipe
    pid = nil
    wait = nil
    settled = false
    readers = []
    # The cleanup is armed BEFORE the spawn, and the pid is its only input.
    # Open3's block form left a window between its spawn and the block: an
    # interrupt there escaped with the child alive in its own group, or reached
    # Open3's ensure, which joins the child and so waited out its whole life.
    # Measured 2026-09-28 at load 42: b8 of the suite hit it 2 runs in 4.
    # (Thread.handle_interrupt cannot close it: it does not mask signal traps.)
    begin
      pid = Process.spawn(env, *argv, **opts, out: out_w, err: err_w)
      wait = Process.detach(pid)
      out_w.close
      err_w.close
      settled, result = wait_bounded(out_r, err_r, wait, readers, timeout, deadline, kill_grace, timing)
      result
    ensure
      if pid && !settled
        wait ||= Process.detach(pid)
        kill_group(wait, kill_grace, timing)
      end
      readers.each { |t| t.kill if t.alive? }
      [out_r, out_w, err_r, err_w].each { |io| io.close unless io.closed? }
      wait&.join
    end
  rescue SystemCallError => e
    Result.new(out: "", err: e.message, exitstatus: 127, timed_out: false, seconds: timeout)
  end

  # -> [settled, Result]. `readers` is filled in place so run's cleanup can
  # kill them whatever raises here.
  def self.wait_bounded(out, err, wait, readers, timeout, deadline, kill_grace, timing)
    readers.push(Thread.new { read_all(out) }, Thread.new { read_all(err) })
    status = timing.join(wait, timeout)&.value
    drained = status && readers.all? { |t| timing.join(t, [deadline - timing.now, 0].max + READER_GRACE_S) }
    if drained
      return [true, Result.new(out: readers[0].value, err: readers[1].value,
                               exitstatus: status.exitstatus || (128 + status.termsig.to_i),
                               termsig: status.termsig, timed_out: false, seconds: timeout)]
    end

    kill_group(wait, kill_grace, timing)
    texts = readers.map { |t| timing.join(t, READER_GRACE_S) ? t.value.to_s : "" }
    [true, Result.new(out: texts[0], err: texts[1], exitstatus: nil, timed_out: true, seconds: timeout)]
  end

  # A pipe closed under a reader (run's cleanup) ends the read quietly.
  def self.read_all(io)
    io.read
  rescue IOError
    ""
  end

  # KILL follows TERM whether or not the leader died: a group member that
  # ignores TERM would otherwise outlive a leader that honoured it.
  def self.kill_group(wait, grace, timing)
    signal_group("TERM", wait.pid)
    timing.join(wait, grace)
    signal_group("KILL", wait.pid)
    timing.join(wait, grace)
  end

  def self.signal_group(sig, pid)
    Process.kill(sig, -pid)
  rescue Errno::ESRCH, Errno::EPERM
    nil
  end
  private_class_method :read_all, :kill_group, :signal_group, :wait_bounded
end
