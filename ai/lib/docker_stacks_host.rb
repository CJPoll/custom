# frozen_string_literal: true

# docker_stacks_host — the side-effect half of ai/bin/pool-headroom and
# ai/bin/teardown-stack (DND-864): every docker, git, gh and glab process they
# run. It returns raw text or plain hashes; ai/lib/docker_stacks.rb decides.
#
# A command that fails raises DockerStacks::Unreadable naming the command, so a
# daemon that is down never reads as "no networks" or "no containers".
#
# Test seams (self-tests only): ATHENA_DOCKER_BIN, ATHENA_GH_BIN,
# ATHENA_GLAB_BIN name stub executables in place of docker / gh / glab.

require "open3"
require "json"
require_relative "docker_stacks"

module DockerStacks
  class Host
    def initialize(env = ENV)
      @docker = env["ATHENA_DOCKER_BIN"] || "docker"
      @gh = env["ATHENA_GH_BIN"] || "gh"
      @glab = env["ATHENA_GLAB_BIN"] || "glab"
    end

    # -> [stdout, stderr, success?]; a missing executable is a failure, not a raise.
    def run(argv, chdir: nil)
      opts = chdir ? { chdir: chdir } : {}
      out, err, status = Open3.capture3(*argv, **opts)
      [out, err, status.success?]
    rescue SystemCallError => e
      ["", e.message, false]
    end

    # -> [stdout, stderr, exit status]; a missing executable is 127.
    def run_code(argv)
      out, err, status = Open3.capture3(*argv)
      [out, err, status.exitstatus]
    rescue SystemCallError => e
      ["", e.message, 127]
    end

    def run!(argv, chdir: nil)
      out, err, ok = run(argv, chdir: chdir)
      return out if ok

      raise Unreadable, "`#{argv.join(' ')}` failed: #{first_line(err, out)}"
    end

    # ---- docker ---------------------------------------------------------------
    def docker_reachable!
      run!([@docker, "info", "--format", "{{.ServerVersion}}"])
    end

    def address_pools_raw
      run!([@docker, "info", "--format", "{{json .DefaultAddressPools}}"])
    end

    def networks_raw
      ids = run!([@docker, "network", "ls", "-q", "--no-trunc"]).split
      return "[]" if ids.empty? # the domain refuses an empty list

      run!([@docker, "network", "inspect", *ids])
    end

    # Every compose container on the host: [{ project:, working_dir: }].
    def compose_containers
      ids = run!([@docker, "ps", "-aq", "--no-trunc", "--filter", "label=#{PROJECT_LABEL}"]).split
      return [] if ids.empty?

      parsed = DockerStacks.parse_json(run!([@docker, "inspect", *ids]), "docker inspect")
      raise Unreadable, "docker inspect returned #{parsed.class}, not a list" unless parsed.is_a?(Array)

      parsed.map do |c|
        labels = c.dig("Config", "Labels") || {}
        { project: labels[PROJECT_LABEL], working_dir: labels[WORKDIR_LABEL] }
      end
    end

    # -> { containers: n, volumes: n, networks: n } carrying the project label.
    def project_resources(project)
      filter = "label=#{PROJECT_LABEL}=#{project}"
      {
        containers: run!([@docker, "ps", "-aq", "--filter", filter]).split.size,
        volumes: run!([@docker, "volume", "ls", "-q", "--filter", filter]).split.size,
        networks: run!([@docker, "network", "ls", "-q", "--filter", filter]).split.size,
      }
    end

    def compose_down(project, dir)
      run([@docker, "compose", "-p", project, "down", "-v", "--remove-orphans"], chdir: dir)
    end

    # ---- filesystem -----------------------------------------------------------
    # -> [compose file at <dir>'s root?, compose file one level down?]. An
    # unreadable subdirectory counts as holding one: never read it as "none".
    def compose_layout(dir)
      root = Dir.children(dir).any? { |f| DockerStacks.compose_file?(f) }
      subdirs = Dir.children(dir).map { |c| File.join(dir, c) }
                   .select { |p| File.directory?(p) && !File.basename(p).start_with?(".") }
      [root, subdirs.any? { |d| compose_in?(d) }]
    end

    # Do this repo's worktrees run a per-worktree stack? A compose file at the
    # root (docker's default project), or a repo teardown script (a repo that
    # names its stacks its own way, like walt_ui's backend/). Compose files
    # only below the root with no script (~/dev/custom's templates/) are not
    # a stack.
    def stack_repo?(repo)
      compose_layout(repo).first ||
        REPO_SCRIPTS.any? { |s| File.file?(File.join(repo, s)) && File.executable?(File.join(repo, s)) }
    end

    # ---- git ------------------------------------------------------------------
    def worktrees(repo)
      run!(["git", "-C", repo, "worktree", "list", "--porcelain"])
    end

    def git(dir, *args)
      out, _err, ok = run(["git", "-C", dir, *args])
      ok ? out.strip : nil
    end

    # ---- forge ----------------------------------------------------------------
    def pr_head_branch(number, repo)
      raw = run!([@gh, "pr", "view", number.to_s, "--json", "headRefName"], chdir: repo)
      branch = DockerStacks.parse_json(raw, "gh pr view #{number}")["headRefName"]
      raise Unreadable, "gh pr view #{number} has no headRefName" unless branch.is_a?(String) && !branch.empty?

      branch
    end

    def mr_head_branch(number, repo)
      raw = run!([@glab, "mr", "view", number.to_s, "-F", "json"], chdir: repo)
      branch = DockerStacks.parse_json(raw, "glab mr view #{number}")["source_branch"]
      raise Unreadable, "glab mr view #{number} has no source_branch" unless branch.is_a?(String) && !branch.empty?

      branch
    end

    # The merged PR/MR number whose head is <branch>, or nil when none merged.
    def merged_change_for(branch, dir, forge)
      if forge == :github
        raw = run!([@gh, "pr", "list", "--head", branch, "--state", "merged", "--json", "number", "--limit", "1"], chdir: dir)
        list = DockerStacks.parse_json(raw, "gh pr list")
        key = "number"
      else
        raw = run!([@glab, "mr", "list", "--source-branch", branch, "--merged", "-F", "json"], chdir: dir)
        list = DockerStacks.parse_json(raw, "glab mr list")
        key = "iid"
      end
      raise Unreadable, "forge list for #{branch} is not a list" unless list.is_a?(Array)
      return nil if list.empty?

      number = list.first.is_a?(Hash) ? list.first[key] : nil
      raise Unreadable, "forge list for #{branch} has an entry without an integer #{key}" unless number.is_a?(Integer)

      number
    end

    private

    def compose_in?(dir)
      Dir.children(dir).any? { |f| DockerStacks.compose_file?(f) }
    rescue SystemCallError
      true
    end

    def first_line(*texts)
      texts.map(&:to_s).map(&:strip).find { |t| !t.empty? }.to_s.lines.first.to_s.strip
    end
  end
end
