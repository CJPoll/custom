# frozen_string_literal: true

require "json"

# ToolSandbox::Policy -- the pure domain of ai/bin/tool-sandbox (DND-1426).
#
# This module is the AUTHORIZATION POINT of the sandbox: `argv` is the only
# place a bind mount or an environment variable is added, and nothing reaches
# the sandboxed command except through it. Deny by default: a host path that
# is not listed here does not exist inside the sandbox.
#
# Pure: no IO, no process execution. Every fact about the host (realpaths,
# lstat results, the /bin-style links, tool locations) is gathered by
# ai/lib/tool_sandbox/host.rb and passed in, so a test can feed a WRONG key and
# assert the named refusal (~/dev/custom/ai/CLAUDE.md -> "A failed lookup must
# never look like an empty one"). Results are [:ok, value] or [:error, reason];
# the caller prints the reason with a Fix:.
module ToolSandbox
  module Policy
    # Facts about one candidate directory, gathered by the host adapter.
    #   path       the path as given on the command line
    #   realpath   its resolved realpath (for a DEST that does not exist yet:
    #              the parent's realpath + the basename); nil if unresolvable
    #   exists / directory / symlink (the LEAF is a symlink) / owned (by our uid)
    #   git_entry  :none | :dir | :file | :other -- what <dir>/.git is
    #   empty      the directory has no entries
    #   lstat_error  nil, or the errno name when the path could not be inspected
    #   holds_mirror the directory has an `origin.git` child: it is a
    #              --prepare-clone DEST, and binding it would make the mirror
    #              writable
    # What lies BENEATH the directory is judged separately (validate_contents),
    # after validate_dir passed, so a refused path is never walked.
    Facts = Struct.new(:path, :realpath, :exists, :directory, :symlink, :owned, :git_entry, :empty,
                       :lstat_error, :holds_mirror, keyword_init: true)

    # The ONLY variables the child sees (bwrap --clearenv first). No flag adds one.
    ENV_ALLOWLIST = {
      "PATH" => "/usr/bin:/bin",
      "HOME" => "/home/sandbox",
      "LANG" => "C.UTF-8",
      "TMPDIR" => "/tmp",
      "TERM" => "dumb",
      "XDG_STATE_HOME" => "/home/sandbox/.local/state",
      "XDG_CACHE_HOME" => "/home/sandbox/.cache"
    }.freeze
    # bwrap itself sets PWD to the --chdir target. Named so a probe can tell it
    # from a leak.
    BWRAP_SET_ENV = { "PWD" => "/work" }.freeze

    SANDBOX_HOME = "/home/sandbox"
    WORK_MOUNT = "/work"
    OUT_MOUNT = "/out"
    ORIGIN_MOUNT = "/origin"

    TIMEOUT_DEFAULT = 1800
    TIMEOUT_RANGE = (1..7200).freeze
    KILL_AFTER = 10
    FSIZE_BYTES = 1_073_741_824
    NOFILE = 1024

    # The host's top-level links into /usr, mirrored (never bound).
    TOP_LINKS = %w[/bin /lib /lib64 /sbin].freeze
    OPTIONAL_LINKS = %w[/lib64].freeze

    ROLES = {
      work: "--work", out: "--out", origin: "the origin mirror", dest: "--prepare-clone DEST"
    }.freeze

    # timeout(1)'s own exits when it had to stop the command: 124 after its
    # TERM, 128+9 after --kill-after's KILL. Read as a timeout only when the
    # wall time actually reached --timeout (an external KILL is not one).
    TIMEOUT_STATUSES = [124, 137].freeze
    EXIT_TIMEOUT = 124
    EXIT_SETUP = 125
    EXIT_USAGE = 2
    SIGNALS = { "INT" => 2, "HUP" => 1, "TERM" => 15 }.freeze

    module_function

    # The temp root every dir must sit under. It must be a real shared temp dir
    # (sticky and world-writable), so TMPDIR=$HOME cannot widen it to HOME.
    def validate_tmp_root(realpath:, mode:)
      return [:error, "the temp root (Dir.tmpdir) could not be resolved to an absolute realpath"] if realpath.nil?
      return [:error, "the temp root #{realpath.inspect} is not absolute"] unless absolute?(realpath)
      return [:error, "the temp root is the filesystem root /"] if realpath == "/"
      unless mode.is_a?(Integer) && (mode & 0o1000).positive? && (mode & 0o002).positive?
        return [:error, "the temp root #{realpath} is not a sticky, world-writable temp directory"]
      end

      [:ok, realpath]
    end

    def validate_dir(facts, tmp_root:, role:)
      label = ROLES.fetch(role) { raise ArgumentError, "unknown role #{role.inspect}" }
      path = facts.path
      return [:error, "#{label} is empty"] if path.nil? || path.empty?
      return [:error, "#{label} #{path} is not absolute"] unless absolute?(path)
      return [:error, "#{label} #{path} cannot be inspected (#{facts.lstat_error})"] if facts.lstat_error

      if role == :dest
        return [:error, "#{label} #{path} exists and is not a directory"] if facts.exists && !facts.directory
        return [:error, "#{label} #{path} exists and is not empty"] if facts.exists && !facts.empty
      else
        return [:error, "#{label} #{path} does not exist"] unless facts.exists
      end

      real = facts.realpath
      return [:error, "#{label} #{path} could not be resolved to a realpath"] unless absolute?(real)
      return [:error, "#{label} #{path} is a symlink (resolves to #{real}); pass the real directory"] if facts.symlink
      return [:error, "#{label} #{path} is the temp root itself (#{tmp_root}); pass a directory beneath it"] if real == tmp_root
      return [:error, "#{label} #{path} resolves to #{real}, outside the temp root #{tmp_root}"] unless under?(real, tmp_root)
      return [:ok, real] if role == :dest && !facts.exists

      return [:error, "#{label} #{path} is not a directory"] unless facts.directory
      return [:error, "#{label} #{path} is not owned by this user"] unless facts.owned
      if role == :work && facts.git_entry == :file
        return [:error, "#{label} #{path} is a linked worktree (its .git is a file pointing at a host repo)"]
      end
      if %i[work out].include?(role) && facts.holds_mirror
        return [:error, "#{label} #{path} holds an origin.git mirror (it is a --prepare-clone DEST); bound " \
                        "read-write, the mirror could be rewritten. Pass DEST/repo instead"]
      end

      [:ok, real]
    end

    # special: :clean when the walk found nothing, else what it found (the
    # first socket, fifo, device or hardlinked file beneath the dir, or a dir
    # it could not list). Anything but the explicit :clean is a refusal: a walk
    # that did not run must never read as a clean one.
    def validate_contents(path:, role:, special:)
      label = ROLES.fetch(role) { raise ArgumentError, "unknown role #{role.inspect}" }
      return [:ok, path] if special == :clean

      what = special.is_a?(String) && !special.empty? ? special : "the contents walk did not report"
      [:error, "#{label} #{path} contains a socket, fifo, device or hardlinked file, or a directory that cannot " \
               "be listed (#{what}); a bound socket reaches a host process and a hardlink writes a host file"]
    end

    # The bound dirs must not overlap: an --out that is (or holds, or sits in)
    # the origin mirror would make the read-only /origin writable through
    # /out, and sandboxed code could move "what landed".
    def validate_disjoint(work:, out: nil, origin: nil)
      named = { "--work" => work, "--out" => out, "the origin mirror" => origin }.compact
      named.to_a.combination(2).each do |(a, pa), (b, pb)|
        next unless pa == pb || under?(pa, pb) || under?(pb, pa)

        return [:error, "#{a} #{pa} and #{b} #{pb} overlap; each bound directory must be separate"]
      end
      [:ok, named.values]
    end

    # Facts about a --stdin FILE (DND-176), gathered by the host adapter:
    #   path / realpath / exists / regular (a plain file) / symlink (the LEAF)
    #   owned (by our uid) / nlink / size / lstat_error
    StdinFacts = Struct.new(:path, :realpath, :exists, :regular, :symlink, :owned, :nlink, :size, :lstat_error,
                            keyword_init: true)
    STDIN_MAX_BYTES = 16 * 1024 * 1024

    # --stdin FILE is validated as a key, like --work: absolute, an existing
    # regular file that is not a symlink, owned by us, with one link, at most
    # STDIN_MAX_BYTES, and strictly beneath the temp root. The host reads it and
    # feeds its bytes through a pipe, so the child never holds the file itself.
    def validate_stdin(facts, tmp_root:)
      path = facts.path
      return [:error, "--stdin is empty"] if path.nil? || path.empty?
      return [:error, "--stdin #{path} is not absolute"] unless absolute?(path)
      return [:error, "--stdin #{path} cannot be inspected (#{facts.lstat_error})"] if facts.lstat_error
      return [:error, "--stdin #{path} does not exist"] unless facts.exists
      return [:error, "--stdin #{path} is a symlink; pass the real file"] if facts.symlink

      real = facts.realpath
      return [:error, "--stdin #{path} could not be resolved to a realpath"] unless absolute?(real)
      return [:error, "--stdin #{path} resolves to #{real}, outside the temp root #{tmp_root}"] unless under?(real, tmp_root)
      return [:error, "--stdin #{path} is not a regular file"] unless facts.regular
      return [:error, "--stdin #{path} is not owned by this user"] unless facts.owned
      return [:error, "--stdin #{path} is hardlinked (#{facts.nlink} links)"] unless facts.nlink == 1
      unless facts.size.is_a?(Integer) && facts.size <= STDIN_MAX_BYTES
        return [:error, "--stdin #{path} is over #{STDIN_MAX_BYTES} bytes"]
      end

      [:ok, real]
    end

    def validate_timeout(secs)
      return [:ok, TIMEOUT_DEFAULT] if secs.nil?
      return [:ok, secs] if secs.is_a?(Integer) && TIMEOUT_RANGE.cover?(secs)

      [:error, "--timeout #{secs.inspect} is outside 1-7200 seconds"]
    end

    # host: { "/bin" => "usr/bin" | "/usr/bin" | :absent | :not_symlink, ... }
    # -> [:ok, [[target, name], ...]] -- bwrap --symlink TARGET NAME pairs.
    def top_links(host)
      links = []
      TOP_LINKS.each do |name|
        return [:error, "no fact was gathered for #{name}"] unless host.key?(name)

        target = host[name]
        next if target == :absent && OPTIONAL_LINKS.include?(name)
        return [:error, "#{name} is absent on this host"] if target == :absent
        unless target.is_a?(String)
          return [:error, "#{name} is not a symlink into /usr (this host is not merged-/usr)"]
        end

        rel = target.delete_prefix("/")
        parts = rel.split("/")
        unless parts.first == "usr" && !parts.include?("..") && !parts.include?(".")
          return [:error, "#{name} points at #{target}, not into /usr"]
        end

        links << [rel, name]
      end
      [:ok, links]
    end

    # The full argv tool-sandbox execs: timeout -> prlimit -> bwrap -> CMD.
    # Every path must already be a validated realpath. Raises ArgumentError on
    # input that validation should have refused (a programming error).
    #
    # hard_limits: the caller's current hard rlimits { cpu:, fsize:, nofile: },
    # nil meaning unlimited. prlimit cannot raise a hard limit, so each limit
    # is the LOWER of the policy's and the caller's: a nested tool-sandbox
    # (the sandboxed gate runs the escape probes) narrows, never fails.
    def argv(tools:, links:, work:, timeout:, status_fd:, cmd:, hard_limits:, out: nil, origin: nil)
      raise ArgumentError, "--timeout #{timeout.inspect} is outside 1-7200 seconds" unless TIMEOUT_RANGE.cover?(timeout)
      raise ArgumentError, "CMD is empty" if !cmd.is_a?(Array) || cmd.empty? || !cmd.all?(String)
      raise ArgumentError, "status fd must be an Integer >= 3" unless status_fd.is_a?(Integer) && status_fd >= 3

      %i[timeout prlimit bwrap].each do |k|
        raise ArgumentError, "tool #{k} path #{tools[k].inspect} is not absolute" unless absolute?(tools[k])
      end
      { work: work, out: out, origin: origin }.each do |k, v|
        next if v.nil? && k != :work
        raise ArgumentError, "#{k} bind source #{v.inspect} is not absolute" unless absolute?(v)
      end

      cpu = capped(timeout, hard_limits, :cpu)
      fsize = capped(FSIZE_BYTES, hard_limits, :fsize)
      nofile = capped(NOFILE, hard_limits, :nofile)
      [
        tools[:timeout], "--kill-after=#{KILL_AFTER}", timeout.to_s,
        tools[:prlimit], "--cpu=#{cpu}", "--fsize=#{fsize}", "--nofile=#{nofile}", "--core=0", "--",
        tools[:bwrap],
        "--unshare-all", "--die-with-parent", "--new-session", "--cap-drop", "ALL", "--clearenv",
        *ENV_ALLOWLIST.flat_map { |k, v| ["--setenv", k, v] },
        "--ro-bind", "/usr", "/usr",
        *links.flat_map { |target, name| ["--symlink", target, name] },
        "--ro-bind", "/etc", "/etc",
        "--proc", "/proc", "--dev", "/dev", "--perms", "1777", "--tmpfs", "/tmp", "--dir", SANDBOX_HOME,
        "--bind", work, WORK_MOUNT,
        *(out ? ["--bind", out, OUT_MOUNT] : []),
        *(origin ? ["--ro-bind", origin, ORIGIN_MOUNT] : []),
        "--chdir", WORK_MOUNT,
        "--json-status-fd", status_fd.to_s,
        "--", *cmd
      ]
    end

    def capped(want, hard_limits, key)
      raise ArgumentError, "no hard limit fact for #{key}" unless hard_limits.is_a?(Hash) && hard_limits.key?(key)

      hard = hard_limits[key]
      return want if hard.nil?
      raise ArgumentError, "hard limit #{key} #{hard.inspect} is not a positive Integer" unless hard.is_a?(Integer) && hard.positive?

      [want, hard].min
    end

    # bwrap's --json-status-fd stream: one JSON object per line; `child-pid`
    # once the sandbox is up, `exit-code` when the child exits. Anything
    # unparseable, or an exit with no start, reads as "not started": a status
    # we cannot read must never become the child's verdict.
    def parse_status(text)
      started = false
      exit_code = nil
      text.to_s.each_line do |line|
        next if line.strip.empty?

        obj = JSON.parse(line)
        return { started: false, exit_code: nil } unless obj.is_a?(Hash)

        started = true if obj["child-pid"].is_a?(Integer)
        exit_code = obj["exit-code"] if obj["exit-code"].is_a?(Integer)
      end
      return { started: false, exit_code: nil } unless started

      { started: true, exit_code: exit_code }
    rescue JSON::ParserError
      { started: false, exit_code: nil }
    end

    # status: tool-sandbox's direct child's exit (128+N when signalled).
    # elapsed / timeout: wall seconds the run took, and the --timeout it had.
    # interrupted: the signal name tool-sandbox forwarded (TERM/INT/HUP), or nil.
    # -> [:pass, n] | [:timeout] | [:interrupted, signame] | [:setup, reason]
    def classify_exit(status:, started:, exit_code:, elapsed:, timeout:, interrupted: nil)
      return [:pass, exit_code] if started && !exit_code.nil?
      return [:interrupted, interrupted] if SIGNALS.key?(interrupted)
      raise ArgumentError, "unknown forwarded signal #{interrupted.inspect}" unless interrupted.nil?

      unless started
        return [:setup, "the sandbox never started (bwrap exited #{status} before running the command)"]
      end
      return [:timeout] if TIMEOUT_STATUSES.include?(status) && elapsed.is_a?(Numeric) && elapsed >= timeout

      # bwrap writes child-pid before it sets the mounts up, so a missing bind
      # source and an unexecutable CMD both land here: the command never
      # produced a status of its own.
      [:setup, "the command did not run to completion: bwrap failed while setting the sandbox up, the command " \
               "could not be executed inside it, or bwrap was killed (exit #{status}, no exit status from bwrap)"]
    end

    def exit_code_for(outcome)
      case outcome[0]
      when :pass then outcome[1]
      when :timeout then EXIT_TIMEOUT
      when :setup then EXIT_SETUP
      when :interrupted then 128 + SIGNALS.fetch(outcome[1])
      else raise ArgumentError, "unknown outcome #{outcome.inspect}"
      end
    end

    def absolute?(path)
      path.is_a?(String) && path.start_with?("/")
    end

    # Component compare: /tmpfoo is not under /tmp.
    def under?(path, root)
      path.start_with?(root.end_with?("/") ? root : "#{root}/")
    end
  end
end
