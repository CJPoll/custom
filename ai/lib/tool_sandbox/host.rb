# frozen_string_literal: true

require "fileutils"
require "tmpdir"
require_relative "policy"

# ToolSandbox::Host -- the side-effect adapter of ai/bin/tool-sandbox
# (DND-1426). It reads the host (realpaths, lstat, the /bin-style links, where
# the trusted tools live) into plain facts for ToolSandbox::Policy, makes and
# removes a --prepare-clone DEST, and runs the ONE argv Policy.argv built. It
# decides nothing: every judgement is the Policy's.
module ToolSandbox
  module Host
    # Tools are found only here, never through the caller's PATH: a PATH shim
    # named bwrap (or git) would otherwise decide what "sandboxed" means.
    TRUSTED_TOOL_DIRS = %w[/usr/bin /usr/sbin /bin /sbin].freeze
    TOOLS = { timeout: "timeout", prlimit: "prlimit", bwrap: "bwrap" }.freeze
    STATUS_FD = 3
    # The environment of timeout/prlimit/bwrap themselves. The child's is
    # bwrap's --clearenv + Policy::ENV_ALLOWLIST; this is a second belt, so no
    # caller variable (LD_PRELOAD, a token) reaches even the trusted launchers.
    # TOOL_SANDBOX_LAUNCHER is a canary: bwrap's --clearenv must remove it, so
    # the E-8 probe sees a lost --clearenv even though this belt would
    # otherwise hide it.
    LAUNCH_ENV = { "PATH" => "/usr/bin:/bin", "LANG" => "C.UTF-8", "TOOL_SANDBOX_LAUNCHER" => "1" }.freeze
    FORWARDED_SIGNALS = Policy::SIGNALS.keys.freeze
    MIRROR = "origin.git"

    module_function

    def tmp_root
      real = File.realpath(Dir.tmpdir)
      [real, File.stat(real).mode]
    rescue SystemCallError
      [nil, nil]
    end

    # -> Policy::Facts for one path. role :dest may name a path that does not
    # exist yet; its key is then the parent's realpath + the basename. The
    # contents walk (first_special) is a separate step the caller runs only
    # after Policy.validate_dir passed, so a refused path is never walked.
    def facts(path, role:)
      base = { path: path, realpath: nil, exists: false, directory: false, symlink: false, owned: false,
               git_entry: :none, empty: false, lstat_error: nil, holds_mirror: false }
      return Policy::Facts.new(**base) if path.nil? || path.empty? || !path.start_with?("/")

      st = begin
        File.lstat(path)
      rescue Errno::ENOENT, Errno::ENOTDIR
        nil
      rescue SystemCallError => e
        return Policy::Facts.new(**base, lstat_error: errno_name(e))
      end
      return Policy::Facts.new(**base, realpath: pending_realpath(path, role)) if st.nil?

      real = safe_realpath(path)
      dir = !real.nil? && File.directory?(real)
      Policy::Facts.new(
        **base, exists: true, realpath: real, symlink: st.symlink?, directory: dir,
                owned: dir && File.stat(real).uid == Process.uid,
                git_entry: dir ? git_entry(real) : :none,
                empty: dir && Dir.empty?(real),
                holds_mirror: dir && (File.exist?(File.join(real, MIRROR)) || File.symlink?(File.join(real, MIRROR)))
      )
    rescue SystemCallError => e
      Policy::Facts.new(**base, lstat_error: errno_name(e))
    end

    def errno_name(err)
      err.class.name.split("::").last
    end

    def pending_realpath(path, role)
      return nil unless role == :dest

      parent = safe_realpath(File.dirname(path))
      parent && File.join(parent, File.basename(path))
    end

    def safe_realpath(path)
      File.realpath(path)
    rescue SystemCallError
      nil
    end

    def git_entry(dir)
      st = File.lstat(File.join(dir, ".git"))
      return :dir if st.directory?
      return :file if st.file?

      :other
    rescue Errno::ENOENT
      :none
    end

    # The first socket, fifo, device or hardlinked file beneath dir (not
    # following symlinks), or a directory we cannot list: what the child could
    # reach through a bind that validation cannot see must be a refusal, not a
    # pass. A hardlink shares its inode with a file elsewhere (possibly under
    # HOME), so writing it inside writes that file. :clean when the whole tree
    # was walked and held none.
    def first_special(dir)
      stack = [dir]
      until stack.empty?
        d = stack.pop
        entries = begin
          Dir.children(d)
        rescue SystemCallError => e
          return "#{d} (unreadable: #{errno_name(e)})"
        end
        entries.each do |name|
          p = File.join(d, name)
          st = begin
            File.lstat(p)
          rescue Errno::ENOENT
            next # removed while we walked: nothing left to reach
          end
          return p if st.socket? || st.pipe? || st.chardev? || st.blockdev?
          return "#{p} (hardlinked, #{st.nlink} links)" if st.file? && st.nlink > 1

          stack << p if st.directory?
        end
      end
      :clean
    end

    # -> { "/bin" => "usr/bin" | :absent | :not_symlink, ... }
    def top_links
      Policy::TOP_LINKS.to_h do |name|
        st = File.lstat(name)
        [name, st.symlink? ? File.readlink(name) : :not_symlink]
      rescue Errno::ENOENT
        [name, :absent]
      end
    end

    # -> { cpu:, fsize:, nofile: } this process's hard rlimits; nil = unlimited.
    def hard_limits
      { cpu: :CPU, fsize: :FSIZE, nofile: :NOFILE }.transform_values do |res|
        hard = Process.getrlimit(res)[1]
        hard == Process::RLIM_INFINITY ? nil : hard
      end
    end

    # The realpath of an executable NAME in TRUSTED_TOOL_DIRS, or nil.
    def find_tool(name)
      hit = TRUSTED_TOOL_DIRS.map { |d| File.join(d, name) }.find { |p| File.file?(p) && File.executable?(p) }
      hit && File.realpath(hit)
    end

    # -> [{ timeout:, prlimit:, bwrap: } realpaths, missing names]
    def tools
      found = {}
      missing = []
      TOOLS.each do |key, name|
        hit = find_tool(name)
        hit ? found[key] = hit : missing << name
      end
      [found, missing]
    end

    def exists?(path)
      File.exist?(path) || File.symlink?(path)
    end

    # A validated DEST: created 0700 when absent. -> true if we created it.
    def make_dest(dest)
      return false if exists?(dest)

      Dir.mkdir(dest, 0o700)
      true
    end

    # Undo a failed --prepare-clone: only what it made inside a validated DEST.
    def remove_clone(dest, created)
      FileUtils.rm_rf([File.join(dest, MIRROR), File.join(dest, "repo")])
      Dir.rmdir(dest) if created
    end

    # -> Policy::StdinFacts for a --stdin FILE (DND-176).
    def stdin_facts(path)
      base = { path: path, realpath: nil, exists: false, regular: false, symlink: false, owned: false, nlink: 0,
               size: nil, lstat_error: nil }
      return Policy::StdinFacts.new(**base) if path.nil? || path.empty? || !path.start_with?("/")

      st = begin
        File.lstat(path)
      rescue Errno::ENOENT, Errno::ENOTDIR
        return Policy::StdinFacts.new(**base)
      end
      Policy::StdinFacts.new(**base, exists: true, realpath: safe_realpath(path), symlink: st.symlink?,
                                     regular: st.file?, owned: st.uid == Process.uid, nlink: st.nlink, size: st.size)
    rescue SystemCallError => e
      Policy::StdinFacts.new(**base, lstat_error: errno_name(e))
    end

    # The bytes of a validated --stdin file, read without following a symlink
    # swapped in after validation, and capped.
    def read_stdin(real)
      File.open(real, File::RDONLY | File::NOFOLLOW) do |f|
        st = f.stat # the opened file itself, re-checked: no swap between validation and open
        unless st.file? && st.uid == Process.uid && st.nlink == 1 && st.size <= Policy::STDIN_MAX_BYTES
          raise Errno::EINVAL, "#{real} changed after validation (not a single-link regular file of ours within the cap)"
        end

        f.read(Policy::STDIN_MAX_BYTES + 1).to_s.b.tap do |data|
          raise Errno::EFBIG, real if data.bytesize > Policy::STDIN_MAX_BYTES
        end
      end
    end

    # Run the Policy argv. stdin is /dev/null, or (--stdin) a pipe the host
    # writes the file's bytes into, so the child never holds a descriptor of
    # the host file and cannot reopen or write it through /proc/self/fd/0.
    # Every fd but 0-2 and the status pipe is closed, and the environment is
    # LAUNCH_ENV only.
    # -> { status: Integer (128+N if signalled), status_text: String,
    #      elapsed: wall seconds, interrupted: forwarded signal name or nil }
    def execute(argv, stdin_bytes: nil)
      reader, writer = IO.pipe
      in_r, in_w = stdin_bytes ? IO.pipe : [nil, nil]
      feeder = nil
      state = { pid: nil, interrupted: nil }
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      status = with_forwarded_signals(state) do
        state[:pid] = Process.spawn(LAUNCH_ENV, *argv, unsetenv_others: true, close_others: true,
                                                       in: in_r || File::NULL, STATUS_FD => writer)
        writer.close
        if in_r
          in_r.close
          feeder = Thread.new { feed(in_w, stdin_bytes) }
        end
        # A signal that arrived before the pid existed is delivered now.
        forward(state) if state[:interrupted]
        Process.wait2(state[:pid])[1]
      end
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
      text = reader.read.to_s
      code = status.exited? ? status.exitstatus : 128 + status.termsig.to_i
      { status: code, status_text: text, elapsed: elapsed, interrupted: state[:interrupted] }
    ensure
      writer.close if writer && !writer.closed?
      reader&.close
      in_r.close if in_r && !in_r.closed?
      in_w.close if in_w && !in_w.closed?
      feeder&.join
    end

    # Write the bytes, then close: the child sees EOF. A child that exits
    # without reading closes the pipe, which ends the write with EPIPE.
    def feed(io, bytes)
      io.write(bytes)
    rescue Errno::EPIPE, IOError
      nil
    ensure
      io.close unless io.closed?
    end

    # A TERM/INT/HUP to tool-sandbox is passed on to timeout(1), which stops
    # bwrap, whose --die-with-parent stops the sandbox. The traps are set
    # BEFORE the spawn, so there is no window in which a signal kills
    # tool-sandbox and leaves the sandbox running until the wall timeout.
    def with_forwarded_signals(state)
      previous = FORWARDED_SIGNALS.to_h do |sig|
        [sig, Signal.trap(sig) do
          state[:interrupted] ||= sig
          forward(state)
        end]
      end
      yield
    ensure
      previous&.each { |sig, handler| Signal.trap(sig, handler || "DEFAULT") }
    end

    def forward(state)
      Process.kill("TERM", state[:pid]) if state[:pid]
    rescue Errno::ESRCH
      nil
    end
  end
end
