# frozen_string_literal: true

# ai/lib/private_overlay_install_host.rb -- the SIDE-EFFECT half of the private
# overlay installer, scripts/setup-private-overlay (DND-703). It runs `claude`
# and `git`, reads and writes the hook file, probes the scanner, and copies the
# skeleton. Every decision is made by ai/lib/private_overlay_install.rb.
#
# Failures are returned or raised as PrivateOverlayInstall::HostError with a
# reason naming what could not be done; the installer prints it with a Fix:.
#
# Deliberately gem-free (stdlib only).

require "open3"
require "fileutils"
require "tempfile"
require_relative "private_overlay_install"
require_relative "private_overlay_resolver"

module PrivateOverlayInstall
  HostError = Class.new(StandardError)

  module Host
    module_function

    # The repo this installer lives in (its checkout: main or a worktree).
    def repo_dir
      File.realpath(File.expand_path("../..", __dir__))
    end

    # The MAIN checkout: the parent of the common git dir. A linked worktree's
    # common dir is the main checkout's .git, so this is the same from both.
    # -> [dir, nil] or [nil, reason].
    def main_checkout
      out, st = Open3.capture2e("git", "-C", repo_dir, "rev-parse", "--path-format=absolute", "--git-common-dir")
      return [nil, "git could not resolve the common git dir of #{repo_dir}"] unless st.success?

      common = out.strip
      return [nil, "the common git dir #{common.inspect} is not a main checkout's .git"] unless File.basename(common) == ".git"

      [File.realpath(File.dirname(common)), nil]
    rescue SystemCallError => e
      [nil, "the main checkout could not be resolved (#{e.class.name.split('::').last})"]
    end

    # The pre-push hook path, as git (and gh-athena's mark check) resolves it.
    def hook_path(main)
      out, st = Open3.capture2e("git", "-C", main, "rev-parse", "--path-format=absolute", "--git-path", "hooks/pre-push")
      return [nil, "git could not resolve hooks/pre-push in #{main}"] unless st.success? && !out.strip.empty?

      [out.strip, nil]
    end

    # -> content String, :none, or :unreadable.
    def read_hook(path)
      return :none unless File.exist?(path) || File.symlink?(path)
      return :unreadable unless File.file?(path) && File.readable?(path)

      File.read(path)
    rescue SystemCallError
      :unreadable
    end

    def write_hook(path, body)
      FileUtils.mkdir_p(File.dirname(path))
      tmp = "#{path}.setup-private-overlay.#{Process.pid}"
      File.write(tmp, body)
      File.chmod(0o755, tmp)
      File.rename(tmp, path)
    rescue SystemCallError => e
      FileUtils.rm_f(tmp) if tmp
      raise HostError, "could not write #{path} (#{e.class.name.split('::').last})"
    end

    def delete_hook(path)
      File.delete(path)
    rescue SystemCallError => e
      raise HostError, "could not remove #{path} (#{e.class.name.split('::').last})"
    end

    # The main checkout's scanner on an empty file, waiver stripped.
    # -> { ready:, detail: }.
    def probe_scanner(main)
      scanner = File.join(main, SCANNER)
      return { ready: false, detail: "the main checkout's scanner #{scanner} is missing or not executable" } unless File.executable?(scanner)

      Tempfile.create("setup-private-overlay-probe") do |f|
        env = { "ATHENA_OUTBOUND_WAIVE" => nil }
        out, _err, st = Open3.capture3(env, scanner, "--text", f.path, "--label", "installer-probe", chdir: main)
        PrivateOverlayInstall.scanner_ready(st.exitstatus || 1, out)
      end
    rescue SystemCallError => e
      { ready: false, detail: "the scanner could not be run (#{e.class.name.split('::').last})" }
    end

    # --- claude ----------------------------------------------------------------

    def claude_available?
      ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).any? { |d| File.executable?(File.join(d, "claude")) }
    end

    # -> [Array, nil] or [nil, reason].
    def claude_list(*args, what:)
      return [nil, "the `claude` CLI is not on PATH"] unless claude_available?

      out, err, st = Open3.capture3("claude", *args)
      return [nil, "`claude #{args.join(' ')}` exited #{st.exitstatus}: #{err.lines.first.to_s.strip}"] unless st.success?

      PrivateOverlayInstall.parse_list(out, what)
    rescue SystemCallError => e
      [nil, "`claude` could not be run (#{e.class.name.split('::').last})"]
    end

    def marketplaces
      claude_list("plugin", "marketplace", "list", "--json", what: "`claude plugin marketplace list --json`")
    end

    def plugins
      claude_list("plugin", "list", "--json", what: "`claude plugin list --json`")
    end

    def claude!(*args)
      out, st = Open3.capture2e("claude", *args)
      return out if st.success?

      raise HostError, "`claude #{args.join(' ')}` exited #{st.exitstatus}: #{out.lines.last.to_s.strip}"
    rescue SystemCallError => e
      raise HostError, "`claude` could not be run (#{e.class.name.split('::').last})"
    end

    # --- overlay -----------------------------------------------------------------

    def overlay
      PrivateOverlay::Resolver.root
    end

    # Where --init would create the root. -> [path, nil] or [nil, reason].
    # Same discovery rule as the resolver, but the path must NOT exist yet.
    def init_target(env: ENV)
      if env.key?(PrivateOverlay::ENV_VAR)
        raw = env[PrivateOverlay::ENV_VAR].to_s
        return [nil, "#{PrivateOverlay::ENV_VAR} is set but empty"] if raw.empty?
        return [nil, "#{PrivateOverlay::ENV_VAR} is not an absolute path"] unless raw.start_with?("/")

        return [raw, nil]
      end
      PrivateOverlay.default_root(env["HOME"])
    end

    def skeleton_dir
      File.join(repo_dir, "ai", "private-overlay", "skeleton")
    end

    # Copy the skeleton to target (0700 root, 0600 files, 0700 dirs), git init
    # it and make one local commit. Never adds a remote.
    def init_overlay(target)
      raise HostError, "the skeleton #{skeleton_dir} is missing" unless File.directory?(skeleton_dir)

      parent = File.dirname(target)
      FileUtils.mkdir_p(parent, mode: 0o700)
      Dir.mkdir(target, 0o700)
      File.chmod(0o700, target)
      FileUtils.cp_r(File.join(skeleton_dir, "."), target)
      Dir.glob(File.join(target, "**", "*"), File::FNM_DOTMATCH).each do |p|
        next if %w[. ..].include?(File.basename(p))

        File.chmod(File.directory?(p) ? 0o700 : 0o600, p)
      end
      git!(target, "init", "--quiet")
      git!(target, "add", "--all")
      git!(target, *identity_args(target), "commit", "--quiet", "-m", "Overlay skeleton from ~/dev/custom (scripts/setup-private-overlay --init)")
    rescue SystemCallError => e
      raise HostError, "could not create #{target} (#{e.class.name.split('::').last})"
    end

    # A commit needs an identity; a fresh machine or a test HOME may have none.
    def identity_args(dir)
      out, st = Open3.capture2("git", "-C", dir, "config", "user.email")
      return [] if st.success? && !out.strip.empty?

      ["-c", "user.name=Athena overlay init", "-c", "user.email=overlay-init@localhost"]
    end

    def git!(dir, *args)
      out, st = Open3.capture2e("git", "-C", dir, *args)
      raise HostError, "`git #{args.last(2).join(' ')}` failed in #{dir}: #{out.lines.last.to_s.strip}" unless st.success?

      out
    end
  end
end
