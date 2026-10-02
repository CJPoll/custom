# frozen_string_literal: true

# Deterministic suite for ReapTags's exec-window rule (DND-1016, DND-1202).
#
# While a tagged process execs, /proc/<pid> passes through states where its
# environment cannot be read yet. The rule: each such state is "cannot tell
# yet" (re-read), never "untagged". A pid read as untagged mid-exec is dropped
# from the scan, and a leak caught there outlives the sweep.
#
# The harness-gate self-test proves this against a real process that re-execs
# in a loop and is scanned 200 times, so its verdict depends on where the
# scheduler lands each read. Here each state is a fixture /proc served to the
# scanner in a fixed order, one state per settle poll: the clock and the poll
# are injected, so no case waits, spins or races. The states are the ones the
# kernel and bash were measured to show:
#   zero_bounds   env_start/env_end 0 0, before the kernel lays out the stack
#   equal_bounds  env_start == env_end, before the kernel walks the new env
#                 (start_code still 0: load_elf_binary sets it only after
#                 create_elf_tables has walked the environment, DND-1626)
#   exec_in_read  the bounds change between the two stat reads around the read
#   short_read    fewer bytes than the bounds span (a read cut at a page)
#   unreadable    environ cannot be opened although the bounds are settled
#   torn          our entry split in two, its '=' a NUL (bash importing it)

require "tmpdir"
require "fileutils"
require_relative "../../lib/reap_tags"

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

TAG = ReapTags.new_tag("selftest-exec-window")
VAR = ReapTags::VAR
PID = 4210
BASE = 1000
EXEC_DONE = 4_194_304 # a start_code: the exec has finished

# One fixture pid under <root>/<pid>. `present(state)` writes the files the
# scanner reads for that state. exec_in_read is the one state that changes
# between two reads inside one classify: its first stat read shows old bounds,
# and the fixture moves them before the environ read.
class FakeProc
  attr_reader :shown

  def initialize(root, pid)
    @root = root
    @pid = pid
    @dir = File.join(root, pid.to_s)
    @shown = []
    @pending_exec = false
    FileUtils.mkdir_p(@dir)
    File.write(File.join(@dir, "status"), "Name:\tfake\nUid:\t#{Process.uid}\t#{Process.uid}\t#{Process.uid}\t#{Process.uid}\n")
    File.write(File.join(@dir, "cmdline"), "fake\0")
  end

  def present(state)
    @shown << state
    env = "HOME=/x\0#{VAR}=other,#{TAG}\0"
    FileUtils.chmod(0o644, environ) if File.exist?(environ)
    case state
    when :settled then write(env, BASE, BASE + env.bytesize)
    when :zero_bounds then write("", 0, 0, start_code: 0)
    when :equal_bounds then write("", BASE, BASE, start_code: 0)
    when :empty_env then write("", BASE, BASE)
    when :short_read then write(env[0, 8], BASE, BASE + env.bytesize)
    when :torn
      torn = "HOME=/x\0#{VAR}\0other,#{TAG}\0"
      write(torn, BASE, BASE + torn.bytesize)
    when :unreadable
      write(env, BASE, BASE + env.bytesize)
      FileUtils.chmod(0o000, environ)
    when :exec_in_read
      write(env, BASE + 4096, BASE + 4096 + env.bytesize)
      @pending_exec = true
    when :untagged_other_torn
      other = "HOME\0/x\0#{VAR}=other\0"
      write(other, BASE, BASE + other.bytesize)
    else raise ArgumentError, "unknown state #{state}"
    end
  end

  # Called after each stat read of this pid: the exec lands between the
  # scanner's "before" and "after" stat reads.
  def after_stat_read
    return unless @pending_exec

    @pending_exec = false
    env = File.binread(environ)
    write(env, BASE, BASE + env.bytesize)
  end

  def environ
    File.join(@dir, "environ")
  end

  private

  # start_code is stat field 26: 0 in a new mm until load_elf_binary finishes,
  # the text address once it has (EXEC_DONE).
  def write(env, b0, b1, start_code: EXEC_DONE)
    File.write(File.join(@dir, "stat"),
               "#{@pid} (fake) S#{' 0' * 18} 100#{' 0' * 3} #{start_code}#{' 0' * 23} #{b0} #{b1} 0\n")
    File.binwrite(environ, env)
  end
end

# Scan `fake` while it steps through `states`: the first is shown before the
# scan, and each settle poll (ReapTags's sleep) shows the next one. The clock
# is advanced by the poll, never read from the machine. Returns
# [found, error_message_or_nil].
def scan_through(root, fake, states, settle: 1.0)
  queue = states.dup
  fake.present(queue.shift)
  clock = 0.0
  real_stat = ReapTags.method(:stat_fields)
  real_clock = ReapTags.method(:monotonic)
  ReapTags.define_singleton_method(:monotonic) { clock }
  ReapTags.define_singleton_method(:sleep) do |s|
    clock += s
    fake.present(queue.shift) unless queue.empty?
  end
  ReapTags.define_singleton_method(:stat_fields) do |pid, proc_root|
    r = real_stat.call(pid, proc_root)
    fake.after_stat_read if pid == PID
    r
  end
  begin
    [ReapTags.tagged_pids(TAG, proc_root: root, exclude: [], since: 0, settle: settle), nil]
  rescue ReapTags::ScanError => e
    [e.found, e.message]
  ensure
    # sleep is Kernel's, so its stub is removed; the other two are ReapTags's
    # own module functions, so they are put back.
    ReapTags.singleton_class.send(:remove_method, :sleep)
    ReapTags.define_singleton_method(:monotonic, real_clock)
    ReapTags.define_singleton_method(:stat_fields, real_stat)
  end
end

TMPDIRS = []
at_exit do
  TMPDIRS.each do |d|
    Dir.glob(File.join(d, "**", "environ")).each { |e| FileUtils.chmod(0o644, e) }
    FileUtils.rm_rf(d)
  end
end

def fresh(name)
  TMPDIRS << Dir.mktmpdir("reap-tags-#{name}")
  root = File.join(TMPDIRS.last, "proc")
  [root, FakeProc.new(root, PID)]
end

puts "reap-tags: exec-window rule (fixture /proc, injected clock)"

# 0. The baseline: a settled, tagged environment is found at once.
root, fake = fresh("settled")
found, err = scan_through(root, fake, [:settled])
check("a settled tagged environment is found", found == [PID] && err.nil?, "found=#{found} err=#{err}")

# 1. Every mid-exec state, shown in turn, then settled: the pid is found. A
#    state read as "untagged" drops the pid, so it is never found.
TRANSIENT = %i[zero_bounds equal_bounds exec_in_read short_read unreadable torn].freeze
root, fake = fresh("sequence")
found, err = scan_through(root, fake, TRANSIENT + [:settled])
check("a tagged process shown every mid-exec state in turn is found once it settles",
      found == [PID] && err.nil? && fake.shown == TRANSIENT + [:settled],
      "found=#{found} err=#{err} shown=#{fake.shown}")

# 2. Each state on its own, then settled: isolates which state a regression
#    breaks.
TRANSIENT.each do |state|
  root, fake = fresh(state.to_s)
  found, err = scan_through(root, fake, [state, :settled])
  check("#{state} then settled: found, not read as untagged",
        found == [PID] && err.nil? && fake.shown == [state, :settled], "found=#{found} err=#{err} shown=#{fake.shown}")
end

# 3. A state that never clears within the settle window is UNKNOWN: the scan
#    raises naming the pid and a Fix:, never returns "none left". Equal
#    bounds with start_code 0 are mid-exec however long they last (an exec
#    preempted inside its environment walk), so they are included (DND-1626).
(TRANSIENT - %i[exec_in_read]).each do |state|
  root, fake = fresh("#{state}-stuck")
  found, err = scan_through(root, fake, [state] * 100, settle: 0.2)
  check("#{state} that never clears: UNKNOWN naming the pid, with a Fix:",
        found.empty? && err.to_s.include?("pid=#{PID}") && err.to_s.include?("UNKNOWN") && err.to_s.include?("Fix:"),
        "found=#{found} err=#{err.inspect}")
end

# 4. Equal bounds after the exec has finished (start_code set): a genuinely
#    empty environment, decided from that state on the first read. No re-read
#    is needed, so the state shown next is never consulted (DND-1626: the old
#    rule waited one poll and read whatever came next).
root, fake = fresh("empty")
found, err = scan_through(root, fake, %i[empty_env settled])
check("equal bounds with the exec finished: empty environment, a plain no from state, no re-read",
      found.empty? && err.nil? && fake.shown == [:empty_env],
      "found=#{found} err=#{err.inspect} shown=#{fake.shown}")

# 5. Only OUR entry torn is "cannot tell": a process caught importing another
#    variable, with ours whole and untagged, is a plain "no".
root, fake = fresh("other-torn")
found, err = scan_through(root, fake, [:untagged_other_torn])
check("another variable torn, ours whole and untagged: a plain no", found.empty? && err.nil?,
      "found=#{found} err=#{err.inspect}")

puts "reap-tags: #{$pass} passed, #{$fail} failed"
exit($fail.zero? ? 0 : 1)
