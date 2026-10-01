# frozen_string_literal: true

# docker_stacks_host — the side-effect half of ai/bin/pool-headroom and
# ai/bin/teardown-stack (DND-864): every docker, git, gh and glab process they
# run. It returns raw text or plain hashes; ai/lib/docker_stacks.rb decides.
#
# A command that fails raises DockerStacks::Unreadable naming the command, so a
# daemon that is down never reads as "no networks" or "no containers".
#
# Every process runs under a wall-clock bound (DND-1088): a hung glab once held
# every wt-preflight on a machine for 28 minutes. Past its bound a command's
# whole process group is killed and DockerStacks::TimedOut (an Unreadable) is
# raised naming the command, so a hang reads as UNKNOWN, never as an answer.
# A forge CLI or docker that timed out is not run again by this Host: the next
# call raises TimedOut at once ("not run"), so N stacks cost one bound, not N.
#
# Test seams (self-tests only): ATHENA_DOCKER_BIN, ATHENA_GH_BIN,
# ATHENA_GLAB_BIN name stub executables in place of docker / gh / glab;
# ATHENA_FORGE_TIMEOUT_S and ATHENA_DOCKER_TIMEOUT_S shorten those bounds. A
# malformed value, or one above the default, raises: a seam can only tighten
# a bound, never lengthen or remove it.
#
# git is bounded but not remembered: a wedged git is usually one checkout (a
# lock, a dead mount), so one hang does not skip git for every other stack.

require "json"
require "shellwords"
require_relative "bounded_command"
require_relative "docker_stacks"

module DockerStacks
  class Host
    # gitlab.com and github.com answer a list in about a second; 20s is a hung
    # CLI, not a slow network.
    FORGE_TIMEOUT_S = 20
    # docker reads (info, ls, inspect, ps) against a live daemon.
    DOCKER_TIMEOUT_S = 30
    # `compose down -v`: each container gets docker's 10s stop grace.
    COMPOSE_DOWN_TIMEOUT_S = 300
    # A repo's own teardown script (walt_ui: several compose projects).
    SCRIPT_TIMEOUT_S = 600
    # Local git reads.
    GIT_TIMEOUT_S = 30
    # ai/bin/confirm-merged: forge reads plus a git ancestry check.
    CONFIRM_TIMEOUT_S = 120

    def initialize(env = ENV)
      @docker = env["ATHENA_DOCKER_BIN"] || "docker"
      @gh = env["ATHENA_GH_BIN"] || "gh"
      @glab = env["ATHENA_GLAB_BIN"] || "glab"
      @forge_timeout = seam_seconds(env, "ATHENA_FORGE_TIMEOUT_S", FORGE_TIMEOUT_S)
      @docker_timeout = seam_seconds(env, "ATHENA_DOCKER_TIMEOUT_S", DOCKER_TIMEOUT_S)
      @hung = {} # executable -> the TimedOut it raised
    end

    # -> [stdout, stderr, success?]; a missing executable is a failure, not a
    # raise. A command past its bound raises TimedOut. With no timeout given,
    # the bound follows the executable (forge, docker, git, else a script).
    def run(argv, chdir: nil, timeout: nil)
      r = bounded(argv, timeout || timeout_for(argv), chdir: chdir)
      [r.out, r.err, r.success?]
    end

    # -> [stdout, stderr, exit status]; a missing executable is 127. A command
    # past its bound raises TimedOut.
    def run_code(argv, timeout:)
      r = bounded(argv, timeout)
      [r.out, r.err, r.exitstatus]
    end

    def run!(argv, chdir: nil)
      out, err, ok = run(argv, chdir: chdir)
      return out if ok

      raise Unreadable, "`#{display(argv)}` failed: #{first_line(err, out)}"
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

    # The project's volumes, each with its creation time: [{ name:, created_at: }].
    def project_volumes(project)
      names = run!([@docker, "volume", "ls", "-q", "--filter", "label=#{PROJECT_LABEL}=#{project}"]).split
      return [] if names.empty?

      DockerStacks.volumes_from_inspect(run!([@docker, "volume", "inspect", *names]))
    end

    # The project's networks: [{ id:, name: }]. A network without an id is
    # unreadable: a marker pins a network by its id.
    def project_networks(project)
      ids = run!([@docker, "network", "ls", "-q", "--no-trunc", "--filter", "label=#{PROJECT_LABEL}=#{project}"]).split
      return [] if ids.empty?

      DockerStacks.networks_from_inspect(run!([@docker, "network", "inspect", *ids])).map do |n|
        raise Unreadable, "docker network inspect: network #{n[:name]} has no Id" if n[:id].to_s.empty?

        { id: n[:id], name: n[:name] }
      end
    end

    # Remove exactly these volumes / networks. -> [stdout, stderr, success?]
    def remove_volumes(names)
      run([@docker, "volume", "rm", *names])
    end

    def remove_networks(ids)
      run([@docker, "network", "rm", *ids])
    end

    def compose_down(project, dir)
      run([@docker, "compose", "-p", project, "down", "-v", "--remove-orphans"], chdir: dir, timeout: COMPOSE_DOWN_TIMEOUT_S)
    end

    # ---- filesystem -----------------------------------------------------------
    # Do this repo's worktrees run a per-worktree stack? A compose file at the
    # root (docker's default project), or a repo teardown script (a repo that
    # names its stacks its own way, like walt_ui's backend/). Compose files
    # only below the root with no script (~/dev/custom's templates/) are not
    # a stack.
    def stack_repo?(repo)
      Dir.children(repo).any? { |f| DockerStacks.compose_file?(f) } ||
        REPO_SCRIPTS.any? { |s| File.file?(File.join(repo, s)) && File.executable?(File.join(repo, s)) }
    end

    # The stack marker's path: the worktree's own git dir (DND-1576). A git
    # that cannot answer is Unreadable, never "no marker".
    def marker_path(wt)
      dir = git(wt, "rev-parse", "--path-format=absolute", "--git-dir")
      raise Unreadable, "git rev-parse --git-dir failed in #{wt}" if dir.nil? || !dir.start_with?("/")

      File.join(dir, MARKER_FILE)
    end

    # -> the marker's text, or nil when no file is there. Only ENOENT is
    # "absent": EACCES or an unreadable directory raises (Unreadable).
    def read_marker(path)
      File.read(path)
    rescue Errno::ENOENT
      nil
    rescue SystemCallError => e
      raise Unreadable, "cannot read stack marker #{path}: #{e.message}"
    end

    # Atomic: a temp file in the same directory, then rename.
    def write_marker(path, text)
      tmp = "#{path}.#{Process.pid}.tmp"
      File.write(tmp, text)
      File.rename(tmp, path)
    rescue SystemCallError => e
      File.unlink(tmp) if tmp && File.exist?(tmp)
      raise Unreadable, "cannot write stack marker #{path}: #{e.message}"
    end

    # ---- git ------------------------------------------------------------------
    def worktrees(repo)
      run!(["git", "-C", repo, "worktree", "list", "--porcelain"])
    end

    # -> stripped stdout, or nil when git fails. A git past its bound raises
    # TimedOut: a hung read is not "not a git checkout".
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
    # A forge that fails or hangs raises (TimedOut for a hang): never nil.
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

    # Run argv under a bound. A forge CLI or docker that already timed out in
    # this Host is not run again: the call raises at once, naming why.
    def bounded(argv, seconds, chdir: nil)
      exe = argv.first.to_s
      if (prior = @hung[exe])
        raise TimedOut.new("`#{display(argv)}` not run: `#{File.basename(exe)}` timed out earlier in this run " \
                           "(`#{prior.command}` after #{prior.seconds}s)", command: prior.command, seconds: prior.seconds)
      end

      r = BoundedCommand.run(argv, timeout: seconds, chdir: chdir)
      return r unless r.timed_out

      where = chdir ? " (run in #{chdir})" : ""
      err = TimedOut.new("`#{display(argv)}` timed out after #{seconds}s#{where} and was killed",
                         command: display(argv), seconds: seconds)
      @hung[exe] = err if [@gh, @glab, @docker].include?(exe)
      raise err
    end

    def timeout_for(argv)
      case argv.first
      when @gh, @glab then @forge_timeout
      when @docker then @docker_timeout
      when "git" then GIT_TIMEOUT_S
      else SCRIPT_TIMEOUT_S
      end
    end

    # The command as a person would type it: the executable's basename, so a
    # test stub or an absolute path reads as the tool it stands for.
    def display(argv)
      Shellwords.join([File.basename(argv.first.to_s), *argv.drop(1).map(&:to_s)])
    end

    def seam_seconds(env, name, default)
      raw = env[name]
      return default if raw.nil?
      value = raw.match?(/\A[1-9][0-9]*\z/) ? Integer(raw, 10) : nil
      return value if value && value <= default

      raise ArgumentError, "#{name} must be a whole number of seconds from 1 to #{default} " \
                           "(a test seam may only shorten the bound), got #{raw.inspect}"
    end

    def first_line(*texts)
      texts.map(&:to_s).map(&:strip).find { |t| !t.empty? }.to_s.lines.first.to_s.strip
    end
  end
end
