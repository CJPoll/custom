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
require_relative "proc_state"

module ReapTags
  VAR = "ATHENA_REAP_TAGS"
  PREFIX = "athena-reap:"
  # A check's descendants may still be exiting when the check itself returns
  # (a suite that signals a child and does not wait). Only what is still alive
  # after this is a leak.
  DEFAULT_GRACE_S = 5.0
  POLL_S = 0.1
  KILL_PASSES = 10
  # How long a process that cannot be read yet (mid-exec) is re-read before it
  # is named as unknown, and how often (DND-1016).
  DEFAULT_SETTLE_S = 5.0
  SETTLE_POLL_S = 0.05

  # The scan could not look at everything (no env bounds, a malformed stat, a
  # pid that never settled): never "none found". `found` holds the matches it
  # did confirm, so a caller can still kill them; `reap` sets `killed`.
  class ScanError < StandardError
    attr_reader :found
    attr_accessor :killed

    def initialize(msg = nil, found: [])
      super(msg)
      @found = found
      @killed = []
    end
  end

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
  # as a whole element, started at or after `since` (a starttime in clock
  # ticks; default: this process's own, since nothing older can carry a tag it
  # made). A process that vanishes mid-scan is not ours to judge.
  #
  # DND-1016: /proc/<pid>/environ is NOT a stable read while the process is
  # inside execve -- it reads EMPTY (or fails EACCES) until the kernel has laid
  # out the new stack, and a read that straddles an exec is cut short at a
  # page. The suite reaper's measured orphan was
  # `asdf exec ruby .../mock-athena-inbox-client.rb`, read as untagged
  # between the asdf shim chain's execs. So a read is an answer only when the
  # kernel's own bounds for the environment (env_start/env_end, fields 50-51
  # of /proc/<pid>/stat) are set, the same before and after the read, and span
  # exactly the bytes read (#classify). Anything else is re-read every
  # SETTLE_POLL_S for up to `settle` seconds, and a pid still unreadable after
  # that raises ScanError naming it -- never silently counted as untagged.
  # DND-1202: a settled read can still be torn, because the new program may
  # rewrite its environment in place (bash's startup NULs each '=' while it
  # imports the entry). Our entry read as a bare "ATHENA_REAP_TAGS" is re-read
  # the same way.
  # scripts/lib/proc-env-scan.awk applies the same rule for shell readers, and
  # its header states the limits (a non-dumpable process cannot be read and
  # is skipped; equal bounds are decided by start_code, DND-1626).
  #
  # `since` defaults to this process's own start, read from the real /proc
  # even when `proc_root` points at a fixture.
  def tagged_pids(tag, proc_root: "/proc", uid: Process.uid, exclude: [Process.pid],
                  since: own_starttime, settle: DEFAULT_SETTLE_S)
    found = []
    unknown = []
    Dir.glob(File.join(proc_root, "[0-9]*")).each do |dir|
      pid = File.basename(dir).to_i
      next if exclude.include?(pid)

      case classify(pid, tag, proc_root, uid, since)
      when :match then found << pid
      when :unknown then unknown << pid
      end
    end
    deadline = monotonic + settle
    until unknown.empty? || monotonic >= deadline
      sleep SETTLE_POLL_S
      unknown = unknown.select do |pid|
        verdict = classify(pid, tag, proc_root, uid, since)
        found << pid if verdict == :match
        verdict == :unknown
      end
    end
    return found if unknown.empty?

    named = unknown.map { |pid| "pid=#{pid} #{cmdline(pid, proc_root: proc_root)}" }.join("; ")
    raise ScanError.new("#{unknown.size} process(es) stayed unreadable for #{settle}s (environment bounds " \
                        "never settled, or the #{VAR} entry stayed mid-rewrite), so whether they carry #{tag} is " \
                        "UNKNOWN: #{named}. Fix: find what those processes are doing (stuck in execve, an " \
                        "unreadable environ, or a program holding its environment half-rewritten) and re-run; the " \
                        "scan could not look, so it did not report 'none left'.", found: found)
  end

  # [state, starttime, env_start, env_end, start_code] from /proc/<pid>/stat,
  # all from one read (one mm), or nil when the process is gone. Raises when
  # the line is not the kernel's format or this kernel has no env bounds: a
  # scan that cannot tell mid-exec from untagged must not run at all.
  def stat_fields(pid, proc_root)
    path = File.join(proc_root, pid.to_s, "stat")
    line = begin
      File.binread(path)
    rescue SystemCallError, IOError
      return nil
    end
    f = ProcState.stat_fields(line)
    raise ScanError, "#{path} is not in the kernel's format (no \") \" after the comm). Fix: run on Linux with /proc mounted." unless f

    if f.size < 49
      raise ScanError, "#{proc_root}/#{pid}/stat has #{f.size + 2} fields; env_start/env_end (fields 50-51, " \
                       "Linux 3.5+) are missing. Fix: run on Linux 3.5 or later; the reap must not fall back " \
                       "to an unbracketed read."
    end
    [f[0], f[19].to_i, f[47].to_i, f[48].to_i, f[23].to_i]
  end

  def real_uid(pid, proc_root)
    File.foreach(File.join(proc_root, pid.to_s, "status")) do |l|
      return l.split[1].to_i if l.start_with?("Uid:")
    end
    nil
  rescue SystemCallError, IOError
    nil
  end

  # :match, :no (or cannot be ours), or :unknown (cannot tell yet).
  def classify(pid, tag, proc_root, uid, since)
    s = stat_fields(pid, proc_root) or return :no
    state, start, b0, b1, start_code = s
    return :no if %w[Z X x].include?(state) || start < since || real_uid(pid, proc_root) != uid

    path = File.join(proc_root, pid.to_s, "environ")
    # Non-dumpable (sudo, ssh-agent): root owns its /proc files, its bounds
    # read 0 0 forever and its environ is unreadable. Skipped at once, not
    # waited out; a same-uid exec keeps a process dumpable throughout.
    owner = begin
      File.stat(path).uid
    rescue SystemCallError
      return :no # gone
    end
    return :no if owner != uid
    return :unknown if b0.zero? && b1.zero? # mid-exec: no bounds yet

    # Equal bounds are ALSO mid-exec: create_elf_tables sets env_end =
    # env_start, walks the new environment, then sets env_end. Decided by
    # state, not time (DND-1626): start_code is 0 in the new mm until
    # load_elf_binary sets it after that walk. 0 is "cannot tell yet" however
    # long it lasts; set, the exec is over and the environment is empty.
    # Kernel sources: scripts/lib/proc-env-scan.awk's header.
    return(start_code.zero? ? :unknown : :no) if b0 == b1

    env = begin
      File.binread(path)
    rescue SystemCallError, IOError
      nil
    end
    after = stat_fields(pid, proc_root) or return :no
    return :unknown unless after[2] == b0 && after[3] == b1 # an exec happened during the read

    return :unknown if env.nil? # unreadable with settled bounds: transient
    return :unknown unless env.bytesize == b1 - b0 # a short read

    entries = env.split("\0")
    entry = entries.find { |e| e.start_with?("#{VAR}=") }
    return :match if entry && entry.byteslice(VAR.bytesize + 1..-1).split(",").include?(tag)

    # DND-1202: the exec is over, but the new program may be rewriting its
    # environment in place. bash's startup writes a NUL over each entry's '='
    # while it imports it, then puts the '=' back, so a read in between shows
    # our entry split in two ("ATHENA_REAP_TAGS\0<tags>"). That is a torn
    # read, not an untagged process: re-read it.
    return :unknown if entries.include?(VAR)

    :no
  end

  def own_starttime
    s = stat_fields(Process.pid, "/proc")
    raise ScanError, "cannot read /proc/#{Process.pid}/stat for this process's start time. Fix: run on Linux with /proc mounted." unless s

    s[1]
  end

  def cmdline(pid, proc_root: "/proc")
    File.binread(File.join(proc_root, pid.to_s, "cmdline")).tr("\0", " ").strip
  rescue SystemCallError, IOError
    "?"
  end

  # Wait up to `grace` seconds for tagged processes to exit on their own, then
  # SIGKILL whatever is left (repeating, bounded, for anything mid-fork).
  # Returns [[pid, cmdline], ...] for each process it had to kill -- empty when
  # nothing outlived the grace period. When any scan could not look
  # (tagged_pids raised), the matches it DID confirm are still killed, and
  # then that ScanError is raised with `killed` set: the caller reports both
  # the failure and what was killed, never "nothing leaked".
  def reap(tag, grace: DEFAULT_GRACE_S, proc_root: "/proc")
    scan_error = nil
    scan = lambda do
      tagged_pids(tag, proc_root: proc_root)
    rescue ScanError => e
      scan_error ||= e
      e.found
    end
    deadline = monotonic + grace
    left = scan.call
    while !left.empty? && monotonic < deadline
      sleep POLL_S
      left = scan.call
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
      left = scan.call
    end
    if scan_error
      scan_error.killed = killed
      raise scan_error
    end
    killed
  end

  def monotonic
    Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end
end
