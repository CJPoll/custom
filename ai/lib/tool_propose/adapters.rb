# frozen_string_literal: true

require "fileutils"
require "open3"
require "set"
require "tmpdir"
require_relative "label"
require_relative "out_dir"

# ToolPropose::Adapters -- the side effects of ai/bin/tool-propose (DND-176):
# host git reads, git plumbing on the throwaway clone, the proposer call,
# tool-sandbox and test-slot, and the out-dir. Every process goes through ONE
# guarded primitive, ToolPropose::Exec.capture, which refuses anything
# Exec.command_allowed? does not explicitly permit (deny by default).
#
# What the policy guarantees (adoption-gate states S1-S4, epic Arch & Eng §6):
#   - host repo: read-only verbs only (rev-parse, ls-tree, cat-file);
#   - a scratch clone: plumbing only (no ref, no HEAD, no working tree), and
#     only BEFORE its first sandbox run; once handed to tool-sandbox it is
#     tainted and every host git verb on it is refused (R2-1);
#   - the candidate executes only inside tool-sandbox: as variant-eval's
#     variant, or alone in a fresh per-target sandbox (R2-3);
#   - no forge CLI, no push/fetch/commit/merge, no shell, no network tool, and
#     `claude` only with the fixed no-tools proposer argv.
module ToolPropose
  class MutationAttempt < StandardError; end
  # An infrastructure fault: exit 3 with Fix:, never a label.
  class Infra < StandardError; end

  # The policy's state for one run: which paths this run created.
  class Containment
    attr_reader :custom_dir, :clones, :pending, :case_dirs, :stdin_files
    attr_accessor :scratch, :out_scratch, :proposer_dir, :guard

    def initialize(custom_dir)
      @custom_dir = custom_dir
      @scratch = nil
      @out_scratch = nil
      @proposer_dir = nil
      @guard = nil
      @clones = {} # DEST/repo -> used?
      @pending = Set.new # DESTs a --prepare-clone may build
      @case_dirs = Set.new
      @stdin_files = Set.new
    end

    def tool_sandbox
      File.join(@custom_dir, "ai/bin/tool-sandbox")
    end

    def test_slot
      File.join(@custom_dir, "ai/bin/test-slot")
    end

    def mark_used(repo)
      raise Infra, "no clone #{repo} to mark used" unless @clones.key?(repo)

      @clones[repo] = true
    end
  end

  module Exec
    EMPTY_MCP_CONFIG = '{"mcpServers":{}}'
    PROPOSER_DISALLOWED = %w[Bash Task Write Edit NotebookEdit WebFetch WebSearch].freeze
    # block-optimize's fixed text-only argv: `--tools ""` removes every built-in
    # tool, --strict-mcp-config with an empty config loads no MCP server, and
    # the variadic --disallowedTools is last so it cannot swallow a later flag.
    PROPOSER_ARGV = [
      "claude", "-p", "--model", "opus", "--tools", "",
      "--strict-mcp-config", "--mcp-config", EMPTY_MCP_CONFIG,
      "--disallowedTools", *PROPOSER_DISALLOWED
    ].freeze
    HOST_GIT = %w[rev-parse ls-tree cat-file].freeze
    SCRATCH_GIT = %w[hash-object read-tree update-index write-tree commit-tree diff rev-parse].freeze
    GIT_DENIED_ARGS = %w[--textconv --filters --ext-diff --exec-path --upload-pack --receive-pack].freeze
    SHA_RE = /\A[0-9a-f]{40}\z/
    LABEL_RE = /\Atool-propose [A-Za-z0-9._:-]{1,80}\z/
    TIMEOUT_RANGE = (1..7200).freeze
    ISOLATED_TIMEOUT = "60"
    GATE_CMD = ["ai/bin/harness-gate"].freeze

    module_function

    def variant_eval_cmd(cand, base)
      ["ai/bin/variant-eval", "--variant", cand, "--baseline", base, "--corpus", "deterministic",
       "--json", "/out/scorecard.json", "--out", "/out/scorecard.txt"]
    end

    # Deny by default. ctx is the run's Containment; chdir where it would run;
    # env the variables it would get.
    def command_allowed?(argv, ctx:, chdir: nil, env: nil)
      return false unless argv.is_a?(Array) && !argv.empty? && argv.all?(String)
      return false if argv.include?("--update-baseline")
      return false if argv.any? { |a| a.start_with?("--output") }

      case argv[0]
      when "git" then git_allowed?(argv.drop(1), ctx, env)
      when ctx.tool_sandbox then sandbox_allowed?(argv.drop(1), ctx, chdir)
      when ctx.test_slot then slot_allowed?(argv.drop(1), ctx)
      when "claude" then argv == PROPOSER_ARGV && !ctx.proposer_dir.nil? && chdir == ctx.proposer_dir
      else false
      end
    end

    # git -C <host repo> <read verb> | git -C <unused clone> <plumbing verb>.
    def git_allowed?(rest, ctx, env)
      return false unless rest[0] == "-C" && rest.size >= 3

      path = rest[1]
      sub = rest[2]
      args = rest.drop(3)
      return false if args.any? { |a| GIT_DENIED_ARGS.include?(a) || a.start_with?("--exec-path") }

      if path == ctx.custom_dir
        HOST_GIT.include?(sub)
      elsif ctx.clones.key?(path)
        return false if ctx.clones[path] # tainted: a sandbox has run over it (R2-1)
        return false unless SCRATCH_GIT.include?(sub)
        return false if sub == "diff" && !(args.include?("--no-ext-diff") && args.include?("--no-textconv"))
        return false if %w[read-tree update-index write-tree].include?(sub) && !scratch_index?(env, ctx)

        true
      else
        false
      end
    end

    def scratch_index?(env, ctx)
      idx = env && env["GIT_INDEX_FILE"]
      !idx.nil? && !ctx.scratch.nil? && idx.start_with?("#{ctx.scratch}/")
    end

    def sandbox_allowed?(args, ctx, chdir)
      if args[0] == "--prepare-clone"
        return args.size == 4 && ctx.pending.include?(args[1]) && args[2] == "--sha" && SHA_RE.match?(args[3]) &&
               chdir == ctx.custom_dir
      end
      sandbox_run?(args, ctx)
    end

    # The three sandboxed runs, and nothing else after `--`.
    def sandbox_run?(args, ctx)
      sep = args.index("--")
      return false if sep.nil?

      flags = args[0...sep]
      cmd = args[(sep + 1)..]
      opts = flags.each_slice(2).to_a
      return false unless opts.all? { |pair| pair.size == 2 } && opts.map(&:first).uniq.size == opts.size

      o = opts.to_h
      return false unless o["--timeout"].to_s.match?(/\A\d+\z/) && TIMEOUT_RANGE.cover?(o["--timeout"].to_i)

      work = o["--work"]
      if ctx.clones[work] == true # a used clone: the measurement or the baseline gate
        if o.keys.sort == %w[--out --timeout --work] && o["--out"] == ctx.out_scratch && !ctx.out_scratch.nil?
          return cmd.size == 11 && SHA_RE.match?(cmd[2].to_s) && SHA_RE.match?(cmd[4].to_s) &&
                 cmd == variant_eval_cmd(cmd[2], cmd[4])
        end
        return o.keys.sort == %w[--timeout --work] && cmd == GATE_CMD
      end
      if ctx.case_dirs.include?(work) # the isolated per-target re-check
        return o.keys.sort == %w[--stdin --timeout --work] && ctx.stdin_files.include?(o["--stdin"]) &&
               o["--timeout"] == ISOLATED_TIMEOUT && !ctx.guard.nil? && cmd[0] == "/work/ai/bin/#{ctx.guard}"
      end
      false
    end

    # test-slot, holding a cpu slot around exactly one allowed sandbox run.
    def slot_allowed?(args, ctx)
      return false unless args.size > 6 && args[0, 2] == ["--pool", "cpu"] && args[2] == "--label" &&
                          LABEL_RE.match?(args[3]) && args[4] == "--" && args[5] == ctx.tool_sandbox

      sandbox_run?(args.drop(6), ctx)
    end

    # The ONE execution primitive. -> [stdout, stderr, exit] (128+N when
    # signalled). An exception while waiting (a signal to tool-propose) TERMs
    # the child first, so a tool-sandbox run is stopped, not orphaned.
    def capture(argv, ctx:, chdir: nil, stdin_data: "", env: nil)
      unless command_allowed?(argv, ctx: ctx, chdir: chdir, env: env)
        raise MutationAttempt,
              "tool-propose refused a command outside its allowlist: #{argv.inspect} (cwd #{chdir.inspect}). " \
              "Fix: tool-propose is propose-only; it must never move a ref, push, touch a forge, re-baseline, run " \
              "host git on a clone a sandbox has touched, or run the candidate outside tool-sandbox."
      end
      opts = { chdir: chdir }.compact
      Open3.popen3(*(env ? [env, *argv] : argv), **opts) do |stdin, stdout, stderr, wait|
        begin
          readers = [stdout, stderr].map { |io| Thread.new { io.read } }
          begin
            stdin.write(stdin_data)
          rescue Errno::EPIPE
            nil
          end
          stdin.close
          out, err = readers.map(&:value)
          st = wait.value
          [out, err, st.exitstatus || (128 + st.termsig.to_i)]
        rescue Exception # rubocop:disable Lint/RescueException -- stop the child, then re-raise anything
          begin
            Process.kill("TERM", wait.pid)
          rescue Errno::ESRCH
            nil
          end
          raise
        end
      end
    end
  end

  # The real adapters. The manager calls only these methods.
  class Adapters
    GIT_HERMETIC = { "GIT_CONFIG_NOSYSTEM" => "1", "GIT_CONFIG_GLOBAL" => "/dev/null" }.freeze
    IDENTITY = {
      "GIT_AUTHOR_NAME" => "Athena tool-propose", "GIT_AUTHOR_EMAIL" => "noreply@invalid",
      "GIT_COMMITTER_NAME" => "Athena tool-propose", "GIT_COMMITTER_EMAIL" => "noreply@invalid",
      "GIT_AUTHOR_DATE" => "2000-01-01T00:00:00Z", "GIT_COMMITTER_DATE" => "2000-01-01T00:00:00Z"
    }.freeze
    OUT_READ_MAX = 1024 * 1024
    CANDIDATE_READ_MAX = 1024 * 1024
    FIXTURES = "ai/eval/fixtures"

    attr_reader :ctx

    def initialize(custom_dir:, out_dir:, run_id:, log: $stderr)
      @ctx = Containment.new(custom_dir)
      @out_dir = out_dir
      @run_id = run_id
      @log = log
    end

    def run(argv, **kw)
      Exec.capture(argv, ctx: @ctx, **kw)
    end

    # ---- host repo, read-only ------------------------------------------------
    def base_sha
      out, err, code = run(["git", "-C", @ctx.custom_dir, "rev-parse", "--verify", "--quiet", "--end-of-options",
                            "origin/main^{commit}"])
      sha = out.strip
      return sha if code.zero? && Exec::SHA_RE.match?(sha)

      raise Infra, "origin/main does not resolve to a commit in #{@ctx.custom_dir} (#{err.strip}). Fix: run " \
                   "`git fetch origin` there; tool-propose measures against origin/main only."
    end

    def fixture_names(sha)
      out, _err, code = run(["git", "-C", @ctx.custom_dir, "ls-tree", "--name-only", "-d", "#{sha}:#{FIXTURES}"])
      code.zero? ? out.lines.map(&:strip).reject(&:empty?) : []
    end

    def exists?(sha, path)
      _o, _e, code = run(["git", "-C", @ctx.custom_dir, "cat-file", "-e", "#{sha}:#{path}"])
      code.zero?
    end

    # The bytes of sha:path, or nil when the sha has no such blob.
    def blob(sha, path)
      return nil unless exists?(sha, path)

      out, err, code = run(["git", "-C", @ctx.custom_dir, "cat-file", "blob", "#{sha}:#{path}"])
      raise Infra, "git cat-file blob #{sha}:#{path} failed: #{err.strip}. Fix: check the repository." unless code.zero?

      out.b
    end

    # ---- candidate sources ---------------------------------------------------
    def read_candidate(path)
      File.open(path, File::RDONLY) do |f|
        raise Infra, "--candidate #{path} is not a regular file. Fix: pass a file." unless f.stat.file?

        f.read(CANDIDATE_READ_MAX + 1).to_s.b
      end
    end

    # -> [ok, stdout, stderr, stray files]. cwd is a fresh empty dir, re-checked
    # after: a file there means a tool ran that must not exist.
    def propose(prompt)
      Dir.mktmpdir("tool-propose-proposer-") do |cwd|
        @ctx.proposer_dir = cwd
        begin
          out, err, code = run(Exec::PROPOSER_ARGV, chdir: cwd, stdin_data: prompt)
          [code.zero?, out, err, Dir.children(cwd)]
        ensure
          @ctx.proposer_dir = nil
        end
      end
    end

    # ---- scratch -------------------------------------------------------------
    def with_scratch
      @ctx.scratch = File.realpath(Dir.mktmpdir("tool-propose-"))
      yield
    ensure
      if @ctx.scratch
        Scratch.remove(@ctx.scratch)
        @ctx.scratch = nil
      end
    end

    def scratch_removed?(path)
      !File.exist?(path) && !File.symlink?(path)
    end

    # tool-sandbox --prepare-clone DEST at sha. -> DEST/repo
    def prepare_clone(name, sha)
      dest = File.join(@ctx.scratch, name)
      @ctx.pending << dest
      out, err, code = run([@ctx.tool_sandbox, "--prepare-clone", dest, "--sha", sha], chdir: @ctx.custom_dir)
      @ctx.pending.delete(dest)
      repo = File.join(dest, "repo")
      unless code.zero? && out.include?("repo=#{repo} ") && out.include?("sha=#{sha}")
        raise Infra, "tool-sandbox --prepare-clone failed (exit #{code}): #{tail(err)}. Fix: check that " \
                     "`ai/bin/tool-sandbox --self-test` passes and origin/main is fetched."
      end
      @ctx.clones[repo] = false
      repo
    end

    # The candidate commit, built with plumbing on a temp index: no ref, no
    # HEAD move, no working-tree write. files: path -> [mode, bytes].
    def build_commit(repo, base, files)
      env = GIT_HERMETIC.merge("GIT_INDEX_FILE" => File.join(@ctx.scratch, "index-#{File.basename(File.dirname(repo))}"))
      git!(repo, ["read-tree", base], env: env)
      files.each do |path, (mode, bytes)|
        blob = git!(repo, ["hash-object", "-w", "--stdin"], env: GIT_HERMETIC, stdin: bytes).strip
        git!(repo, ["update-index", "--add", "--cacheinfo", "#{mode},#{blob},#{path}"], env: env)
      end
      tree = git!(repo, ["write-tree"], env: env).strip
      msg = "tool-propose candidate #{@run_id} (propose-only; on no ref)"
      git!(repo, ["commit-tree", tree, "-p", base, "-m", msg], env: GIT_HERMETIC.merge(IDENTITY)).strip
    end

    # -> [binary diff, changed paths], read BEFORE any sandbox run (R2-1).
    def diff(repo, base, cand)
      d = git!(repo, ["diff", "--no-ext-diff", "--no-textconv", "--binary", base, cand], env: GIT_HERMETIC)
      names = git!(repo, ["diff", "--no-ext-diff", "--no-textconv", "--name-only", base, cand], env: GIT_HERMETIC)
      [d, names.lines.map(&:chomp).reject(&:empty?)]
    end

    def mark_used(repo)
      @ctx.mark_used(repo)
    end

    # ---- sandboxed runs ------------------------------------------------------
    # The measurement. -> the sandbox exit (variant-eval's own, or 124/125/128+N).
    def variant_eval(repo, cand, base, timeout)
      @ctx.out_scratch = File.join(@ctx.scratch, "out")
      Dir.mkdir(@ctx.out_scratch, 0o700)
      @log.puts "tool-propose: measuring #{cand[0, 12]} against #{base[0, 12]} in tool-sandbox (timeout #{timeout}s)"
      _o, err, code = run(slot([@ctx.tool_sandbox, "--work", repo, "--out", @ctx.out_scratch, "--timeout", timeout.to_s,
                                "--", *Exec.variant_eval_cmd(cand, base)]))
      @log.puts tail(err, 8) unless err.to_s.strip.empty?
      code
    end

    # The pristine baseline gate, in a FRESH clone (R2-1). -> :green | { red: lines }
    def baseline_gate(base, timeout)
      repo = prepare_clone("b", base)
      mark_used(repo)
      @log.puts "tool-propose: the variant gate is red; running the baseline gate on a fresh clone"
      out, err, code = run(slot([@ctx.tool_sandbox, "--work", repo, "--timeout", timeout.to_s, "--", *Exec::GATE_CMD]))
      code.zero? ? :green : { red: (out.to_s + err.to_s).lines.map(&:chomp).last(12) }
    end

    # Each target alone in a fresh sandbox holding only the candidate. The host
    # classifies the result (R2-3). -> { case name => verdict }
    def isolated(guard, tool_bytes, cases)
      @ctx.guard = guard
      cases.each_with_index.to_h do |c, i|
        base = File.join(@ctx.scratch, "case-#{i}")
        work = File.join(base, "work")
        FileUtils.mkdir_p(File.join(work, "ai/bin"), mode: 0o700)
        bin = File.join(work, "ai/bin", guard)
        File.binwrite(bin, tool_bytes)
        File.chmod(0o755, bin)
        Dir.mkdir(File.join(base, "in"), 0o700)
        input = File.join(base, "in", "input")
        File.binwrite(input, c[:input])
        @ctx.case_dirs << work
        @ctx.stdin_files << input
        out, err, code = run([@ctx.tool_sandbox, "--work", work, "--stdin", input, "--timeout", Exec::ISOLATED_TIMEOUT,
                              "--", "/work/ai/bin/#{guard}", *c[:args]])
        [c[:name], Label.isolated_verdict(exit_status: code, output: "#{out}\n#{err}")]
      end
    end

    # ---- /out: untrusted (R2-2) ---------------------------------------------
    # The bytes of /out/<name>, or nil: only a regular file we own, never a
    # symlink, at most 1 MiB. Nothing else is ever read or copied.
    def read_out(name)
      return nil if @ctx.out_scratch.nil?

      path = File.join(@ctx.out_scratch, name)
      st = File.lstat(path)
      return nil unless st.file? && st.uid == Process.uid && st.size <= OUT_READ_MAX

      File.open(path, File::RDONLY | File::NOFOLLOW) do |f|
        data = f.read(OUT_READ_MAX + 1).to_s
        data.bytesize > OUT_READ_MAX ? nil : data
      end
    rescue SystemCallError, IOError
      nil
    end

    # ---- the out-dir ---------------------------------------------------------
    # Atomic: a temp file in the same directory, then rename. Data only (0644).
    def write_out(rel, bytes)
      raise Infra, "refused out-dir path #{rel.inspect}" if rel.start_with?("/") || rel.split("/").include?("..")

      path = File.join(@out_dir, rel)
      FileUtils.mkdir_p(File.dirname(path))
      tmp = "#{path}.tmp-#{Process.pid}"
      File.open(tmp, File::WRONLY | File::CREAT | File::EXCL, 0o644) { |f| f.write(bytes) }
      File.rename(tmp, path)
    rescue SystemCallError, IOError => e
      raise Infra, "could not write #{rel} into the out-dir #{@out_dir}: #{e.message}. Fix: check the out-dir is " \
                   "writable and has space; nothing was recommended."
    end

    private

    def slot(argv)
      [@ctx.test_slot, "--pool", "cpu", "--label", "tool-propose #{@run_id}", "--", *argv]
    end

    def git!(repo, args, env:, stdin: "")
      out, err, code = run(["git", "-C", repo, *args], env: env, stdin_data: stdin)
      raise Infra, "git #{args.first} failed in the scratch clone: #{err.strip}. Fix: check the clone." unless code.zero?

      out
    end

    def tail(text, n = 3)
      text.to_s.lines.map(&:rstrip).reject(&:empty?).last(n).join(" | ")
    end
  end

  # Facts for OutDir.problem, read from the host.
  module OutDirFacts
    module_function

    def gather(given, env: ENV, home: Dir.home)
      st = begin
        File.lstat(given)
      rescue Errno::ENOENT, Errno::ENOTDIR
        nil
      end
      real = if st
               safe_realpath(given)
             else
               parent = safe_realpath(File.dirname(given))
               parent && File.join(parent, File.basename(given))
             end
      state = env["XDG_STATE_HOME"].to_s.start_with?("/") ? env["XDG_STATE_HOME"] : File.join(home, ".local/state")
      {
        given: given, realpath: real, exists: !st.nil?, symlink: st&.symlink? || false,
        directory: st&.directory? || false, empty: st&.directory? ? Dir.empty?(given) : false,
        git_ancestor: real && git_ancestor(real),
        roots: [safe_realpath(Dir.tmpdir), canonical(File.join(state, "athena/tool-propose"))].compact,
        denied: [canonical(File.join(home, ".claude")), canonical(File.join(home, "dev"))].compact
      }
    end

    # The path itself or its first ancestor holding a .git entry.
    def git_ancestor(path)
      p = path
      loop do
        return p if File.exist?(File.join(p, ".git")) || File.symlink?(File.join(p, ".git"))
        return nil if p == "/"

        p = File.dirname(p)
      end
    end

    def canonical(path)
      safe_realpath(path) || path
    end

    def safe_realpath(path)
      File.realpath(path)
    rescue SystemCallError
      nil
    end
  end

  # Removing the scratch tree, which sandboxed code has written to. It never
  # follows a symlink: directories are made writable by lstat, then removed.
  module Scratch
    module_function

    def remove(root)
      make_removable(root)
      FileUtils.rm_rf(root)
    end

    def make_removable(dir)
      st = File.lstat(dir)
      return unless st.directory?

      File.chmod(0o700, dir)
      Dir.children(dir).each { |name| make_removable(File.join(dir, name)) }
    rescue SystemCallError
      nil
    end
  end
end
