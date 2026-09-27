# frozen_string_literal: true

# ReapTags -- find and reap every process a check or suite started, by a tag
# in its environment, not by a pid list or a process name (DND-818).
#
# The mechanism is shared with scripts/test/lib/suite-reaper.bash: a run adds a
# unique tag to ATHENA_REAP_TAGS (a comma-separated list, so nested runs each
# keep their own), every descendant inherits it, and the tag survives
# reparenting. A process that outlived its run is found even when nobody
# learned its pid and whatever name it runs under -- the measured DND-818
# orphan was `ruby .../old/athena-inbox-client.rb`, which the name-matching
# check-inbox-mock-orphans cannot see at all.
#
# harness-gate uses it per check: each check runs with its own tag, and once
# the check has exited, anything still carrying that tag after a short grace
# period is killed and the check FAILS, naming what it left behind. The failure
# lands on the check that leaked, in the run that leaked it -- not on the next
# gate run on the machine, which is what check-inbox-mock-orphans's --min-age
# margin produced on 2026-09-26 (dnd-735 leaked, dnd-742 went red).
#
# Ruby 2.7 compatible (no endless methods, no pattern matching).

require "securerandom"

module ReapTags
  VAR = "ATHENA_REAP_TAGS"
  PREFIX = "athena-reap:"
  # A check's descendants may still be exiting when the check itself returns
  # (a suite that signals a child and does not wait). Only what is still alive
  # after this is a leak.
  DEFAULT_GRACE_S = 5.0
  POLL_S = 0.1
  KILL_PASSES = 10

  module_function

  # new_tag("gate-check") -> "athena-reap:gate-check-<uuid>"
  def new_tag(kind)
    "#{PREFIX}#{kind}-#{SecureRandom.uuid}"
  end

  # The environment entry that adds `tag` to the inherited list.
  def env_with(tag, inherited = ENV[VAR])
    list = inherited.to_s.split(",").reject(&:empty?)
    { VAR => (list + [tag]).join(",") }
  end

  # Pids of this uid (never this process) whose ATHENA_REAP_TAGS holds `tag`
  # as a whole element. Processes that vanish or cannot be read mid-scan are
  # skipped: they are not ours to judge.
  def tagged_pids(tag, proc_root: "/proc", uid: Process.uid, exclude: [Process.pid])
    needle = "#{VAR}="
    Dir.glob(File.join(proc_root, "[0-9]*")).filter_map do |dir|
      pid = File.basename(dir).to_i
      next if exclude.include?(pid)

      begin
        next unless File.stat(dir).uid == uid

        env = File.binread(File.join(dir, "environ"))
      rescue SystemCallError, IOError
        next
      end
      entry = env.split("\0").find { |e| e.start_with?(needle) }
      next unless entry && entry.byteslice(needle.bytesize..-1).split(",").include?(tag)

      pid
    end
  end

  def cmdline(pid, proc_root: "/proc")
    File.binread(File.join(proc_root, pid.to_s, "cmdline")).tr("\0", " ").strip
  rescue SystemCallError, IOError
    "?"
  end

  # Wait up to `grace` seconds for tagged processes to exit on their own, then
  # SIGKILL whatever is left (repeating, bounded, for anything mid-fork).
  # Returns [[pid, cmdline], ...] for each process it had to kill -- empty when
  # nothing outlived the grace period.
  def reap(tag, grace: DEFAULT_GRACE_S, proc_root: "/proc")
    deadline = monotonic + grace
    left = tagged_pids(tag, proc_root: proc_root)
    while !left.empty? && monotonic < deadline
      sleep POLL_S
      left = tagged_pids(tag, proc_root: proc_root)
    end
    killed = []
    KILL_PASSES.times do
      break if left.empty?

      left.each do |pid|
        killed << [pid, cmdline(pid, proc_root: proc_root)] unless killed.any? { |(p, _)| p == pid }
        begin
          Process.kill("KILL", pid)
        rescue Errno::ESRCH, Errno::EPERM
          nil
        end
      end
      sleep POLL_S
      left = tagged_pids(tag, proc_root: proc_root)
    end
    killed
  end

  def monotonic
    Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end
end
