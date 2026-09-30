# frozen_string_literal: true

require "fileutils"
require "open3"
require_relative "host"

# ToolSandbox::Clone -- the throwaway pinned clone ai/bin/tool-sandbox runs
# model-written code against (DND-1426). Side effects; trusted code that runs
# OUTSIDE the sandbox.
#
#   DEST/origin.git  a bare repo whose ONLY ref is refs/heads/main = SHA. It is
#                    bound read-only at /origin, so `git ls-remote origin` inside
#                    the sandbox answers the pinned SHA with no network, and
#                    sandboxed code cannot rewrite the mirror.
#   DEST/repo        a clone of it, detached at SHA, remote origin url /origin,
#                    refs/remotes/origin/main = SHA. Writable inside the
#                    sandbox, so a DEST is single-use (ai/docs/tool-sandbox.md,
#                    "Residuals").
#
# The mirror is built with `init --bare` + a `fetch` of the pinned commit, not
# a local `clone`: a fetch copies only objects reachable from SHA through a
# pack, so neither repo shares an object store with the host (no hardlinks, no
# alternates), and neither the host's other branches nor commits after SHA are
# carried in. The host repo is only READ (rev-parse, merge-base, and
# upload-pack serving the fetch).
module ToolSandbox
  module Clone
    class Error < StandardError; end

    SHA_RE = /\A[0-9a-f]{7,40}\z/.freeze
    FULL_SHA_RE = /\A[0-9a-f]{40}\z/.freeze
    ORIGIN_REF = "refs/remotes/origin/main"
    # git runs with THIS environment only (unsetenv_others): an inherited
    # GIT_DIR, GIT_WORK_TREE, GIT_OBJECT_DIRECTORY or GIT_CONFIG_* would
    # override every `-C` below and point the fetch and update-refs at the
    # caller's repo. No global or system config is read, so no host alias,
    # hook path or url rewrite shapes the clone.
    GIT_ENV = {
      "PATH" => "/usr/bin:/bin", "LANG" => "C.UTF-8", "HOME" => "/nonexistent",
      "GIT_CONFIG_NOSYSTEM" => "1", "GIT_CONFIG_GLOBAL" => "/dev/null", "GIT_TERMINAL_PROMPT" => "0"
    }.freeze

    module_function

    # -> { repo:, origin:, sha: }. Raises Error naming what failed.
    def prepare(host_repo:, dest:, sha: nil)
      common = git_out(host_repo, "rev-parse", "--path-format=absolute", "--git-common-dir")
      raise Error, "#{host_repo} is not in a git repository (rev-parse gave #{common.inspect})" unless common.start_with?("/")

      tip = resolve(host_repo, ORIGIN_REF, "this checkout's #{ORIGIN_REF}")
      pin = sha.nil? ? tip : pinned(host_repo, sha, tip)

      origin = File.join(dest, "origin.git")
      repo = File.join(dest, "repo")
      git!(nil, "init", "--bare", "--quiet", origin)
      # Fetch the PIN itself, not origin/main then rewind: commits after the
      # pin must not ride along as unreachable objects. upload-pack serves a
      # non-tip sha only with allowReachableSHA1InWant, passed on its command
      # line so the host repo's config is not touched.
      git!(origin, "fetch", "--quiet", "--no-tags",
           "--upload-pack=#{git_bin} -c uploadpack.allowReachableSHA1InWant=true upload-pack",
           common, "#{pin}:refs/heads/main")
      git!(origin, "symbolic-ref", "HEAD", "refs/heads/main")
      git!(nil, "clone", "--quiet", "--no-hardlinks", origin, repo)
      git!(repo, "checkout", "--quiet", "--detach", pin)
      git!(repo, "remote", "set-url", "origin", "/origin")
      git!(repo, "update-ref", ORIGIN_REF, pin)
      verify(origin: origin, repo: repo, sha: pin)
      { repo: repo, origin: origin, sha: pin }
    end

    def pinned(host_repo, sha, tip)
      raise Error, "--sha #{sha.inspect} is not a hex commit id" unless sha.match?(SHA_RE)

      pin = resolve(host_repo, sha, "--sha #{sha}")
      _, _, st = run(host_repo, "merge-base", "--is-ancestor", pin, tip)
      raise Error, "--sha #{sha} (#{pin}) is not on origin/main (#{tip}): it is not an ancestor of it" unless st.exitstatus.zero?

      pin
    end

    def resolve(dir, rev, what)
      out, _, st = run(dir, "rev-parse", "--verify", "--quiet", "#{rev}^{commit}")
      sha = out.strip
      raise Error, "#{what} does not name a commit here" unless st.success? && sha.match?(FULL_SHA_RE)

      sha
    end

    # What the design promises, checked on disk after the fact.
    def verify(origin:, repo:, sha:)
      checks = {
        "repo HEAD" => git_out(repo, "rev-parse", "HEAD"),
        "repo #{ORIGIN_REF}" => git_out(repo, "rev-parse", ORIGIN_REF),
        "origin.git refs/heads/main" => git_out(origin, "rev-parse", "refs/heads/main")
      }
      checks.each { |what, got| raise Error, "#{what} is #{got.inspect}, expected #{sha}" unless got == sha }
      refs = git_out(origin, "for-each-ref", "--format=%(refname)").split("\n")
      raise Error, "origin.git carries refs other than refs/heads/main: #{refs.inspect}" unless refs == ["refs/heads/main"]

      git_dir = File.join(repo, ".git")
      raise Error, "#{git_dir} is not a real directory" unless File.directory?(git_dir) && !File.symlink?(git_dir)

      [File.join(origin, "objects/info/alternates"), File.join(git_dir, "objects/info/alternates")].each do |alt|
        raise Error, "#{alt} exists: the clone shares an object store" if File.exist?(alt)
      end
    end

    def git_out(dir, *args)
      out, err, st = run(dir, *args)
      raise Error, "git #{args.join(' ')} failed in #{dir}: #{err.strip}" unless st.success?

      out.strip
    end

    def git!(dir, *args)
      git_out(dir, *args)
      nil
    end

    def run(dir, *args)
      argv = dir ? [git_bin, "-C", dir, *args] : [git_bin, *args]
      Open3.capture3(GIT_ENV, *argv, unsetenv_others: true)
    end

    # git from the trusted dirs, never the caller's PATH (Host::TRUSTED_TOOL_DIRS).
    def git_bin
      Host.find_tool("git") or raise Error, "git not found in #{Host::TRUSTED_TOOL_DIRS.join(' ')}"
    end
  end
end
