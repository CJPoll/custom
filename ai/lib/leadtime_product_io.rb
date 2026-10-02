# frozen_string_literal: true

# leadtime_product_io -- the SIDE EFFECTS and the MANAGER of the lead-time
# product-repo lane (DND-1540). The rules are ai/lib/leadtime_product.rb
# (DOMAIN); this file gathers the values they judge and carries out what they
# decide:
#
#   Run    one external command, bounded, with git's repo-pointing env unset
#   Git    reads and lane worktrees in an improve repo R
#   Store  <state>/product-prs.jsonl (append-only), the stopped-line marker,
#          the journal
#   Locks  flock(2) on the lane locks: liveness is a held lock, never a pid
#   Forge  GitHub reads (plain gh) and writes (gh-athena, as Athena)
#   cut / open_pr / sweep / reap / teardown   the manager entry points
#
# Every refusal raises LeadTimeProduct::Error (or CouldNotLook) carrying its
# Fix:. A read that could not be made is never read as "nothing there".
#
# Test seams (each defaults to the harness's own tool or the real binary):
#   LEADTIME_GH, LEADTIME_GH_ATHENA, LEADTIME_INTEGRATION_GATE,
#   LEADTIME_LOCKED_MERGE, LEADTIME_CONFIRM_MERGED, LEADTIME_TEARDOWN_STACK,
#   LEADTIME_PRODUCT_BOOTSTRAP (a bash command; set but empty = no bootstrap),
#   LEADTIME_PRODUCT_FORGE (github|gitlab; else read from R's origin URL).

require "fileutils"
require "json"
require "open3"
require "time"
require_relative "leadtime_product"
require_relative "lead_time_trailer"

module LeadTimeProductIO
  P = LeadTimeProduct
  HARNESS = File.expand_path("../..", __dir__)
  GIT_ENV_UNSET = %w[GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE GIT_OBJECT_DIRECTORY GIT_PREFIX].to_h { |k| [k, nil] }.freeze

  # A read that could not be made: exit 3, never an empty result.
  class CouldNotLook < P::Error; end

  # A branch delete git refused (DND-1702). It never fails the tick: the
  # branch is KEPT and named.
  class CouldNotDelete < CouldNotLook; end

  # The lane's bootstrap failed: "cannot act on R", journaled, not retried.
  class CannotAct < P::Error; end

  module Cmd
    module_function

    def seam(var, default)
      v = ENV[var]
      v.nil? || v.empty? ? default : v
    end

    def gh = seam("LEADTIME_GH", "gh")
    def gh_athena = seam("LEADTIME_GH_ATHENA", File.join(HARNESS, "ai/bin/gh-athena"))
    def integration_gate = seam("LEADTIME_INTEGRATION_GATE", File.join(HARNESS, "ai/bin/integration-gate"))
    def locked_merge = seam("LEADTIME_LOCKED_MERGE", File.join(HARNESS, "ai/skills/athena:merge-boarding/scripts/locked-merge"))
    def confirm_merged = seam("LEADTIME_CONFIRM_MERGED", File.join(HARNESS, "ai/bin/confirm-merged"))
    def teardown_stack = seam("LEADTIME_TEARDOWN_STACK", File.join(HARNESS, "ai/bin/teardown-stack"))
  end

  # ── one external command ─────────────────────────────────────────────────

  module Run
    module_function

    # -> [combined output, exit code]. A command that cannot start is 127; a
    # signal is 128+n. `timeout` bounds it when given (seconds). close_others:
    # no child inherits a descriptor this process got from the runner (its run
    # lock, a lane lock): a child that outlived the tick would otherwise hold
    # them, and every later tick would skip as "in flight" or never reap.
    def call(argv, chdir:, env: {}, timeout: nil)
      argv = ["timeout", "-k", "30", "#{timeout}s", *argv] if timeout
      out, st = Open3.capture2e(GIT_ENV_UNSET.merge(env), *argv, chdir: chdir, stdin_data: "", close_others: true)
      [out, st.exitstatus || (128 + st.termsig.to_i)]
    rescue SystemCallError => e
      ["#{argv.first}: #{e.message}", 127]
    end
  end

  # ── git ──────────────────────────────────────────────────────────────────

  module Git
    module_function

    def call(dir, *args, timeout: 120) = Run.call(["git", "-C", dir, *args], chdir: "/", timeout: timeout)

    def rev(dir, ref)
      out, code = call(dir, "rev-parse", "--verify", "--quiet", "#{ref}^{commit}")
      code.zero? ? out.strip : nil
    end

    # A branch's tip, or nil only when refs/heads/<branch> is absent. A ref
    # git could not read raises CouldNotLook: never read as "already gone".
    #
    # Absence is asked with `show-ref --exists` (git >= 2.43), never
    # `show-ref --verify`: --verify answers a ref file holding garbage, an
    # empty one, or an unreadable one exactly as it answers a missing ref
    # (exit 1), so a corrupt branch read as "gone" and its lane was removed
    # (DND-1662). --exists is 2 only for "does not exist" and 1 for a ref it
    # could not look up; a git without --exists (exit 129) cannot tell either.
    ABSENT = 2

    def branch_tip(dir, branch)
      tip = rev(dir, "refs/heads/#{branch}")
      return tip if tip

      out, code = call(dir, "show-ref", "--exists", "refs/heads/#{branch}")
      return nil if code == ABSENT

      why = code.zero? ? "it exists but does not resolve to a commit" : "git show-ref --exists exit #{code}: #{out.lines.last.to_s.strip}"
      raise CouldNotLook.new("cannot read branch #{branch} in #{dir} (#{why})",
                             "check the ref ('git -C #{dir} show-ref --exists refs/heads/#{branch}'; exit 129 means git predates --exists: " \
                             "upgrade to git >= 2.43); its last tip is in its reflog ('git -C #{dir} rev-parse --git-path logs/refs/heads/#{branch}'). " \
                             "Recover it, then repair or delete the ref by hand; the branch is kept.")
    end

    # Delete a branch, or raise CouldNotLook: a delete git refused is never read
    # as done (DND-1702). A branch that is gone after the failure is done.
    def delete_branch(dir, branch)
      out, code = call(dir, "branch", "-D", branch)
      return if code.zero? || branch_tip(dir, branch).nil?

      raise CouldNotDelete.new("cannot delete branch #{branch} in #{dir} (git branch -D exit #{code}: #{out.lines.last.to_s.strip})",
                             "see why git refused ('git -C #{dir} branch -D #{branch}'; a stale '<ref>.lock' file under refs/heads, or the branch " \
                             "checked out in another worktree); then delete it by hand.")
    end

    # true / false; nil when git could not tell (never read as "not landed").
    def ancestor?(dir, commit, ref)
      _, code = call(dir, "merge-base", "--is-ancestor", commit, ref)
      { 0 => true, 1 => false }[code]
    end

    def fetch_main(dir)
      _, code = call(dir, "fetch", "--quiet", "origin", "main")
      code.zero? ? "fetched" : "fetch FAILED; based on the last-fetched origin/main"
    end

    def clean?(dir)
      out, code = call(dir, "status", "--porcelain")
      raise CouldNotLook.new("git status failed in #{dir}", "check the lane is intact ('git -C #{dir} status').") unless code.zero?

      out.strip.empty?
    end

    def remove_worktree(repo, dir)
      _, code = call(repo, "worktree", "remove", "--force", dir)
      FileUtils.rm_rf(dir) unless code.zero?
      call(repo, "worktree", "prune")
    end
  end

  # ── the store ────────────────────────────────────────────────────────────

  module Store
    module_function

    def path(state) = File.join(state, "product-prs.jsonl")
    def stop_path(state, repo) = File.join(state, "product-line-stopped.#{repo}")

    def events(state)
      text = begin
        File.read(path(state))
      rescue Errno::ENOENT
        return []
      rescue SystemCallError => e
        raise CouldNotLook.new("cannot read #{path(state)} (#{e.class.name.split('::').last})", "make it readable; never delete it to clear the error.")
      end
      text.each_line.with_index(1).reject { |l, _| l.strip.empty? }.map { |l, n| P.parse_line(l, n) }
    rescue CouldNotLook
      raise
    rescue P::Error => e
      raise CouldNotLook.new(e.message, e.fix) # a store that cannot be read is exit 3
    end

    def states(state)
      P.fold(events(state))
    rescue CouldNotLook
      raise
    rescue P::Error => e
      raise CouldNotLook.new(e.message, e.fix)
    end

    # One write(2) of one line, O_APPEND, 0600.
    def append(state, event)
      FileUtils.mkdir_p(state)
      File.open(path(state), File::WRONLY | File::APPEND | File::CREAT, 0o600) { |f| f.write("#{JSON.generate(event)}\n") }
    end

    def stopped(state, repo)
      File.read(stop_path(state, repo)).strip.then { |s| s.empty? ? "(no reason recorded)" : s }
    rescue Errno::ENOENT
      nil
    rescue SystemCallError => e
      raise CouldNotLook.new("cannot read #{stop_path(state, repo)} (#{e.class.name.split('::').last})", "make it readable.")
    end

    def stop_line(state, repo, reason, now)
      FileUtils.mkdir_p(state)
      tmp = "#{stop_path(state, repo)}.#{Process.pid}"
      File.write(tmp, "#{now.iso8601} #{reason}\n", perm: 0o600)
      File.rename(tmp, stop_path(state, repo))
    end

    def journal(state, now, line)
      FileUtils.mkdir_p(state)
      File.open(File.join(state, "journal.md"), File::WRONLY | File::APPEND | File::CREAT, 0o600) do |f|
        f.write("- #{now.iso8601} leadtime-product: #{line}\n")
      end
    end
  end

  # ── lane meta (<lane>.meta, key=value lines, last wins) ─────────────────

  module Meta
    module_function

    def read(path)
      File.readlines(path, chomp: true).each_with_object({}) do |l, h|
        k, v = l.split("=", 2)
        h[k] = v if v
      end
    rescue Errno::ENOENT
      {}
    end

    def add(path, pairs)
      File.open(path, File::WRONLY | File::APPEND | File::CREAT, 0o600) { |f| pairs.each { |k, v| f.write("#{k}=#{v}\n") } }
    end
  end

  # ── locks ────────────────────────────────────────────────────────────────

  module Locks
    module_function

    # The runner holds each reserved lane lock for the whole session. A lock
    # nobody holds means the runner that reserved it is gone.
    def held!(lock)
      File.open(lock, File::RDWR) do |f|
        got = f.flock(File::LOCK_EX | File::LOCK_NB)
        if got
          f.flock(File::LOCK_UN)
          raise P::Error.new("the lane lock #{lock} is not held, so the run that reserved this lane is not alive",
                             "use a product lane only from inside the cron tick that reserved it (scripts/athena-leadtime-run.sh).")
        end
      end
    rescue Errno::ENOENT
      raise P::Error.new("no lane lock #{lock}: this run reserved no lane there", "use a product lane only from inside the cron tick that reserved it.")
    end

    # Yields with an exclusive lock on <lock>; returns :held (no yield) when a
    # live process holds it.
    def with(lock)
      File.open(lock, File::RDWR | File::CREAT | File::APPEND, 0o600) do |f|
        return :held unless f.flock(File::LOCK_EX | File::LOCK_NB)

        begin
          yield
        ensure
          f.flock(File::LOCK_UN)
        end
      end
    end
  end

  # ── forge (GitHub) ───────────────────────────────────────────────────────

  module Forge
    module_function

    def kind(repo_path)
      forced = ENV["LEADTIME_PRODUCT_FORGE"]
      return forced unless forced.nil? || forced.empty?

      out, code = Git.call(repo_path, "remote", "get-url", "origin")
      raise CouldNotLook.new("cannot read origin's URL in #{repo_path}", "check '#{repo_path}' has an origin remote.") unless code.zero?

      return "github" if out.include?("github.com")
      return "gitlab" if out.include?("gitlab")

      "unknown"
    end

    def github!(repo_lane)
      k = kind(repo_lane.path)
      return if k == "github"

      raise P::Error.new("#{repo_lane.name}'s forge is #{k}: the product lane opens and lands GitHub PRs only (locked-merge is GitHub-only)",
                         "keep #{repo_lane.name} in watch mode on this machine, or file a ticket to build the GitLab landing path.")
    end

    def json(argv, dir, what)
      out, code = Run.call(argv, chdir: dir, timeout: 120)
      raise CouldNotLook.new("#{what} failed (exit #{code}): #{out.lines.last.to_s.strip}", "run '#{argv.join(' ')}' in #{dir} by hand.") unless code.zero?

      JSON.parse(out)
    rescue JSON::ParserError
      raise CouldNotLook.new("#{what} printed no JSON", "run '#{argv.join(' ')}' in #{dir} by hand.")
    end

    def pr_view(dir, n)
      json([Cmd.gh, "pr", "view", n.to_s, "--json", "state,headRefOid,statusCheckRollup,mergeCommit"], dir, "gh pr view #{n}")
    end

    def runs_for(dir, sha)
      json([Cmd.gh, "run", "list", "--commit", sha, "--limit", "100", "--json", "name,status,conclusion,headSha,updatedAt"], dir,
           "gh run list --commit #{sha[0, 12]}")
    end

    # Athena's push form (athena:github -> Pushing as Athena).
    def push_argv(*refspec_args)
      [Cmd.gh_athena, "git", "-c", "credential.helper=", "-c", "url.https://github.com/.insteadOf=git@github.com:", "push", *refspec_args]
    end

    def push(dir, *refspec_args) = Run.call(push_argv(*refspec_args), chdir: dir, env: { "GIT_TERMINAL_PROMPT" => "0" }, timeout: 300)

    def close(dir, n, comment) = Run.call([Cmd.gh_athena, "pr", "close", n.to_s, "--comment", comment], chdir: dir, timeout: 120)
  end

  # ── the manager ─────────────────────────────────────────────────────────

  module_function

  def now
    e = ENV["LEADTIME_NOW"]
    e && e.match?(/\A\d+\z/) ? Time.at(e.to_i).utc : Time.now.utc
  end

  def runs_dir(m) = File.join(m.state_dir, "runs")

  def load_manifest(path)
    if path.nil? || path.empty?
      raise P::Error.new("no product manifest: LEADTIME_PRODUCT_MANIFEST is unset and no --manifest was given",
                         "run this only inside a lead-time cron tick, which exports LEADTIME_PRODUCT_MANIFEST.")
    end
    P.parse_manifest(File.read(path))
  rescue Errno::ENOENT
    raise P::Error.new("the product manifest #{path} does not exist", "run this only inside the cron tick that wrote it.")
  rescue SystemCallError => e
    raise CouldNotLook.new("cannot read the product manifest #{path} (#{e.class.name.split('::').last})", "make it readable.")
  end

  def refuse_if_stopped(m, rl)
    why = Store.stopped(m.state_dir, rl.name)
    return unless why

    raise P::Error.new("the line is stopped for #{rl.name}: #{why}",
                       "a revert is owed (athena:lead-time-improve's revert path); open no new #{rl.name} change. " \
                       "The owner re-arms with: rm #{Store.stop_path(m.state_dir, rl.name)}")
  end

  # A bootstrap that ran, or failed part way, may have left a stack up: either
  # way the lane's stack is torn down with it (teardown-stack --parked).
  STACK_STATES = %w[ran failed pending].freeze

  # The bootstrap command for a lane: LEADTIME_PRODUCT_BOOTSTRAP when set (empty
  # = none), else R's own bin/dev-setup when it has one, else none.
  def bootstrap_argv(lane)
    if ENV.key?("LEADTIME_PRODUCT_BOOTSTRAP")
      cmd = ENV["LEADTIME_PRODUCT_BOOTSTRAP"]
      return cmd.empty? ? nil : ["bash", "-c", cmd]
    end
    dev_setup = File.join(lane, "bin/dev-setup")
    File.executable?(dev_setup) ? [dev_setup] : nil
  end

  # -> "ran" or "none"; raises CannotAct (journaled) when it fails.
  BOOTSTRAP_CAP = 1200

  def bootstrap(m, rl, lane, label, timeout: BOOTSTRAP_CAP)
    argv = bootstrap_argv(lane)
    return "none" unless argv

    out, code = Run.call(argv, chdir: lane, timeout: timeout)
    log = File.join(runs_dir(m), "#{m.run_id}.#{rl.name}.#{label}.bootstrap.log")
    FileUtils.mkdir_p(runs_dir(m))
    File.write(log, out, perm: 0o600)
    return "ran" if code.zero?

    Store.journal(m.state_dir, now, "repo=#{rl.name} cannot act on #{rl.name}: the #{label} lane bootstrap failed (exit #{code}); not retried this run. lane=#{lane} log=#{log}")
    raise CannotAct.new("cannot act on #{rl.name}: the lane bootstrap (#{argv.last}) exited #{code}; journaled, not retried. Log: #{log}",
                        "read #{log}; fix #{rl.name}'s worktree bootstrap. The next run tries again.")
  end

  # cut: the session's product lane in R (one per repo per run).
  def cut(m, repo, phase, metric = "phase")
    rl = m.repo(repo)
    # The trailer the lane's commits carry (DND-1529): refused here, before
    # any lane exists, when it cannot be built.
    trailer = experiment_trailer(rl, "phase" => phase, "metric" => metric)
    refuse_if_stopped(m, rl)
    Locks.held!(rl.lock)
    if File.exist?(rl.lane)
      raise P::Error.new("this run's #{rl.name} lane is already cut: #{rl.lane}", "work in it; a run has one product lane per repo.")
    end
    Forge.github!(rl)
    t = now
    branch = P.branch_name(rl.name, phase, t.strftime("%Y%m%dT%H%M%SZ"))
    fetched = Git.fetch_main(rl.path)
    base = Git.rev(rl.path, "refs/remotes/origin/main") or
      raise CouldNotLook.new("#{rl.name} has no origin/main, so there is no base for a lane", "run 'git -C #{rl.path} fetch origin main' and check the remote.")
    out, code = Git.call(rl.path, "worktree", "add", "-q", "-b", branch, rl.lane, base)
    raise P::Error.new("could not cut #{rl.lane} on #{branch}: #{out.strip}", "read git's reason; a branch-name collision is never forced.") unless code.zero?

    meta = "#{rl.lane}.meta"
    Meta.add(meta, "repo" => rl.name, "branch" => branch, "phase" => phase, "metric" => metric, "base" => base, "bootstrap" => "pending")
    Meta.add(meta, "bootstrap" => bootstrap(m, rl, rl.lane, "work"))
    { lane: rl.lane, branch: branch, base: base, fetch: fetched, trailer: trailer }
  rescue CannotAct
    Meta.add("#{rl.lane}.meta", "bootstrap" => "failed") if rl && File.exist?(rl.lane)
    raise
  end

  # The lane's Lead-time-experiment trailer (DND-1529):
  # `Lead-time-experiment: <R> <phase> <metric>`, from the lane's meta (the
  # phase and metric `cut` wrote; `phase` for a lane cut before the metric
  # was recorded). A lane commit must carry it (open_pr refuses otherwise):
  # locked-merge squashes with no --body, so what lands on R's main is the
  # repo's default squash message, which keeps the commit messages
  # (COMMIT_MESSAGES) but not necessarily the PR body. The PR body carries it
  # too, for a reader. `experiment judge` reads it on R's main for confounds
  # and `experiment record` requires it. A lane with no phase cannot build
  # one: refused, so no product PR opens without its trailer.
  def experiment_trailer(repo_lane, meta)
    metric = meta["metric"].to_s.empty? ? "phase" : meta["metric"]
    LeadTimeTrailer.line(repo_lane.name, meta["phase"], metric)
  rescue LeadTimeTrailer::Error => e
    raise P::Error.new("the #{repo_lane.name} lane: #{e.message}", "re-cut the lane with 'leadtime-product cut --repo #{repo_lane.name} --phase <phase>'.")
  end

  # A commit in origin/main..HEAD must carry the lane's trailer line
  # (DND-1529): the squash keeps commit messages, not the PR body.
  def trailer_carried!(rl, line)
    out, code = Git.call(rl.lane, "log", "--format=%B", "refs/remotes/origin/main..HEAD")
    raise CouldNotLook.new("git log failed in #{rl.lane}", "check the lane is intact.") unless code.zero?

    want = LeadTimeTrailer.scan(line)[:trailers].first
    return if LeadTimeTrailer.scan(out)[:trailers].include?(want)

    raise P::Error.new("no commit in the #{rl.name} lane carries the line `#{line}`",
                       "amend the lane's commit message to end with `#{line}` (git commit --amend in #{rl.lane}); " \
                       "the squash merge keeps commit messages, not the PR body, and experiment record refuses a landing without it.")
  end

  # pr: push the lane's branch as Athena, open the PR, record it.
  def open_pr(m, repo, title:, body_file:)
    rl = m.repo(repo)
    refuse_if_stopped(m, rl)
    Locks.held!(rl.lock)
    meta = Meta.read("#{rl.lane}.meta")
    branch = meta["branch"]
    unless branch && File.directory?(rl.lane)
      raise P::Error.new("no #{rl.name} lane has been cut in this run", "run 'leadtime-product cut --repo #{rl.name} --phase <phase>' first.")
    end
    Forge.github!(rl)
    raise P::Error.new("--title is empty", "give the PR a title.") if title.to_s.strip.empty?

    evidence = begin
      File.read(body_file)
    rescue SystemCallError => e
      raise P::Error.new("cannot read --body-file #{body_file} (#{e.class.name.split('::').last})", "write the evidence to a readable file.")
    end
    body = P.pr_body(evidence, experiment_trailer(rl, meta))
    raise P::Error.new("the #{rl.name} lane has uncommitted changes", "commit or discard them in #{rl.lane} first.") unless Git.clean?(rl.lane)

    tip = Git.rev(rl.lane, "HEAD") or raise CouldNotLook.new("cannot resolve HEAD in #{rl.lane}", "check the lane is intact.")
    out, code = Git.call(rl.lane, "rev-list", "--count", "refs/remotes/origin/main..HEAD")
    raise CouldNotLook.new("git rev-list failed in #{rl.lane}", "check the lane is intact.") unless code.zero?
    raise P::Error.new("the #{rl.name} lane has no commit beyond origin/main", "commit the change in #{rl.lane} first.") if out.strip == "0"
    trailer_carried!(rl, experiment_trailer(rl, meta))

    out, code = Forge.push(rl.lane, "-u", "origin", "HEAD")
    unless code.zero?
      raise P::Error.new("the push of #{branch} as Athena failed (exit #{code}): #{out.lines.last.to_s.strip}",
                         "read the push's reason (athena:github -> When a forge write can't be done as Athena). Unpushed, the lane reads STRANDED at teardown.")
    end
    # A second `pr` in the same lane updates its open PR: one PR per branch.
    existing = Store.states(m.state_dir).find { |st| st.repo == rl.name && st.branch == branch && st.status == "open" }
    if existing
      Store.append(m.state_dir, P.event("head", at: now.iso8601, repo: rl.name, pr: existing.pr, head: tip))
      Store.journal(m.state_dir, now, "repo=#{rl.name} pr=##{existing.pr} updated (head #{tip[0, 12]}); awaiting landing by a later run")
      return existing.url
    end
    FileUtils.mkdir_p(runs_dir(m))
    bf = File.join(runs_dir(m), "#{m.run_id}.#{rl.name}.pr-body.md")
    File.write(bf, body, perm: 0o600)
    out, code = Run.call([Cmd.gh_athena, "pr", "create", "--base", "main", "--head", branch, "--title", title, "--body-file", bf],
                         chdir: rl.lane, timeout: 120)
    url = out.scan(%r{https?://\S+/pull/\d+}).last
    unless code.zero? && url
      raise P::Error.new("#{branch} is pushed but no PR was opened (exit #{code}): #{out.lines.last.to_s.strip}",
                         "open it with gh-athena pr create --head #{branch}; until a PR records it the lane reads STRANDED.")
    end
    n = url[%r{/pull/(\d+)\z}, 1].to_i
    Store.append(m.state_dir, P.event("opened", at: now.iso8601, repo: rl.name, pr: n, url: url, phase: meta["phase"].to_s,
                                                branch: branch, head: tip, run_id: m.run_id))
    Store.journal(m.state_dir, now, "repo=#{rl.name} pr=##{n} opened (phase #{meta['phase']}, head #{tip[0, 12]}); awaiting landing by a later run")
    url
  end

  # ── sweep: every open improver PR, and every merge awaiting its deploy ──
  #
  # Each PR is read ONCE, as it is now. Nothing here waits on CI or a deploy:
  # a PR or a deploy still running is left for the next tick.

  # Bounds of the landing steps. Each step's own timeout is its cap, cut to
  # what is left of the sweep's budget; a step that cannot get its floor is not
  # started (the PR stays open for the next run). locked-merge is never cut
  # short: a merge killed part way is an unknown outcome.
  GATE_EXTRA = 900       # integration-gate beyond its --slot-wait-timeout
  MERGE_CAP = 1200       # locked-merge (lock wait 600, merge, confirm, teardown)
  MERGE_LOCK_WAIT = 600
  CONFIRM_CAP = 300
  TEARDOWN_CAP = 600
  MIN_GATE = 600
  MIN_BOOTSTRAP = 300

  # A budget clock: monotonic, never the wall clock.
  class Budget
    def initialize(seconds)
      @deadline = mono + seconds
    end

    def left = (@deadline - mono).floor

    def mono = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end

  # -> [summary line, detail lines, stopped repos]. At most ONE landing per sweep.
  # The summary counts each landing branch git could not read (kept, named in
  # its detail line with a Fix:), so the runner's .run shows it (DND-1677).
  def sweep(m, gate_timeout:, budget_s:)
    budget = Budget.new(budget_s)
    lines = []
    landed = []
    unreadable = 0
    attempted = false
    names = m.repos.map(&:name)
    Store.states(m.state_dir).each do |s|
      next unless %w[open merged].include?(s.status)

      tag = "product: repo=#{s.repo} pr=##{s.pr}"
      unless names.include?(s.repo)
        lines << "#{tag} #{s.status}: not swept (#{s.repo} is not an improve product repo on this machine)"
        next
      end
      rl = m.repo(s.repo)
      begin
        if s.status == "merged"
          lines << "#{tag} #{deploy_step(m, rl, s)}"
          next
        end
        view = Forge.pr_view(rl.path, s.pr)
        d = P.decide(s, { state: view["state"], head: view["headRefOid"], ci: P.ci_state(view["statusCheckRollup"]) },
                     line_stopped: Store.stopped(m.state_dir, s.repo))
        case d.action
        when :record_merged
          Store.append(m.state_dir, P.event("merged", at: now.iso8601, repo: s.repo, pr: s.pr,
                                                      merge_sha: view.dig("mergeCommit", "oid").to_s.then { |x| x.empty? ? "unknown" : x }))
          Store.journal(m.state_dir, now, "repo=#{s.repo} pr=##{s.pr} merged outside the run; watching its deploy")
          lines << "#{tag} merged outside the run"
        when :record_closed
          Store.append(m.state_dir, P.event("closed", at: now.iso8601, repo: s.repo, pr: s.pr, reason: d.reason))
          Store.journal(m.state_dir, now, "repo=#{s.repo} pr=##{s.pr} closed outside the run")
          lines << "#{tag} closed outside the run"
        when :wait then lines << "#{tag} open: #{d.reason}"
        when :close then lines << "#{tag} #{close_pr(m, rl, s, d.reason)}"
        when :land
          if attempted
            lines << "#{tag} open: CI green; waits (one landing per run)"
          else
            attempted = true
            line, ok, kept_unreadable = land(m, rl, s, gate_timeout: gate_timeout, budget: budget)
            landed << "#{s.repo}##{s.pr}" if ok
            unreadable += kept_unreadable
            lines << "#{tag} #{line}"
          end
        end
      rescue P::Error => e
        lines << "#{tag} could not act: #{e.message} Fix: #{e.fix}"
      end
    end
    stopped = m.repos.filter_map { |rl| (why = Store.stopped(m.state_dir, rl.name)) && [rl.name, why] }
    [P.summary(P.open_count(Store.states(m.state_dir)), landed, unreadable), lines, stopped]
  end

  def close_pr(m, rl, s, reason)
    out, code = Forge.close(rl.path, s.pr, "Closed by the lead-time improver run (no retry): #{reason}")
    unless code.zero?
      Store.journal(m.state_dir, now, "repo=#{s.repo} pr=##{s.pr} close FAILED (exit #{code}); stays open: #{reason}")
      return "open: close FAILED (exit #{code}: #{out.lines.last.to_s.strip}); the next run retries: #{reason}"
    end
    Store.append(m.state_dir, P.event("closed", at: now.iso8601, repo: s.repo, pr: s.pr, reason: reason))
    Store.journal(m.state_dir, now, "repo=#{s.repo} pr=##{s.pr} CLOSED, no merge, no retry: #{reason}")
    "closed: #{reason}"
  end

  def stop(m, s, reason)
    Store.stop_line(m.state_dir, s.repo, "#{s.repo}##{s.pr}: #{reason}", now)
    Store.journal(m.state_dir, now, "repo=#{s.repo} pr=##{s.pr} LINE STOPPED: #{reason}")
  end

  def deploy_step(m, rl, s)
    sha = s.merge_sha.to_s
    sha = Forge.pr_view(rl.path, s.pr).dig("mergeCommit", "oid").to_s unless sha.match?(P::SHA_RE)
    return "merged; its merge commit is not readable yet, deploy unknown" unless sha.match?(P::SHA_RE)

    re = Regexp.new(ENV.fetch("LEAD_TIME_DEPLOY_RE", "deploy"), Regexp::IGNORECASE)
    case P.deploy_state(Forge.runs_for(rl.path, sha), sha, re, now: now, merged_at: P.parse_time(s.merged_at))
    when :pending then "merged #{sha[0, 12]}; deploy pending (deployed is not working until it concludes success)"
    when :none
      Store.append(m.state_dir, P.event("no-deploy", at: now.iso8601, repo: s.repo, pr: s.pr))
      Store.journal(m.state_dir, now, "repo=#{s.repo} pr=##{s.pr} merged (#{sha[0, 12]}); no deploy verdict for it (none ran, or cancelled/skipped)")
      "merged #{sha[0, 12]}; no deploy verdict for this merge (CI finished with no deploy run, or it was cancelled/skipped): landed"
    when :success
      Store.append(m.state_dir, P.event("deployed", at: now.iso8601, repo: s.repo, pr: s.pr))
      Store.journal(m.state_dir, now, "repo=#{s.repo} pr=##{s.pr} deployed (#{sha[0, 12]})")
      "merged #{sha[0, 12]}; deploy concluded success"
    when :failed
      why = "the post-merge deploy of #{sha[0, 12]} failed: a revert is owed"
      Store.append(m.state_dir, P.event("revert-owed", at: now.iso8601, repo: s.repo, pr: s.pr, reason: why))
      stop(m, s, why)
      "merged #{sha[0, 12]}; DEPLOY FAILED: line stopped, revert owed"
    end
  end

  # Land one green PR in a landing lane: integration-gate --with-critic (R's
  # declared gate and the standing judge), then locked-merge (with R's idle
  # post-merge workflow), then confirm-merged.
  # -> [detail, landed?, landing branches kept because git could not read them].
  def land(m, rl, s, gate_timeout:, budget:)
    idle = begin
      P.idle_args(rl.idle_workflow)
    rescue P::Error => e
      Store.journal(m.state_dir, now, "repo=#{s.repo} pr=##{s.pr} not landed: #{e.message}")
      return ["open: #{e.message} Fix: #{e.fix}", false, 0]
    end
    need = MIN_BOOTSTRAP + MIN_GATE + MERGE_CAP + CONFIRM_CAP + TEARDOWN_CAP
    return ["open: CI green, but #{budget.left}s of the sweep budget is left (a landing needs #{need}s); the next run lands it", false, 0] if budget.left < need

    FileUtils.mkdir_p(rl.lanes_dir, mode: 0o700)
    dir = File.join(rl.lanes_dir, "#{m.run_id}-land")
    lock = "#{dir}.lock"
    result = nil
    kept = nil
    held = begin
      Locks.with(lock) do
        result = land_in(m, rl, s, dir, gate_timeout, budget, idle)
      ensure
        kept = retire_land_lane(m, rl, dir, merged: result ? result[1] == true : false, keep_branch: result ? result[2] == true : false)
      end
    rescue P::Error => e
      raise unless kept

      # The landing failed, but the branch it kept is still named and counted.
      journal_kept(m, s, kept)
      return ["could not act: #{e.message} Fix: #{e.fix}; #{kept}", false, 1]
    rescue StandardError
      # Not a P::Error (an Errno from a store write, say). The exception goes on
      # unchanged, so the tick's outcome is what it was; only the kept branch's
      # journal line, computed in the ensure above, is saved before it leaves.
      # The journal write is best-effort: its own failure must not replace the
      # exception being raised.
      if kept
        begin
          journal_kept(m, s, kept)
        rescue StandardError
          nil
        end
      end
      raise
    end
    # Never delete a lock a live process holds. Removing it after the unlock
    # is safe here only because the runner's single-run lock serialises every
    # tick: no other process can be waiting on this file.
    return ["open: the landing lane lock #{lock} is held by a live process; the next run retries", false, 0] if held == :held

    FileUtils.rm_f(lock)
    line, ok = result
    unreadable = result[3] || 0
    if kept
      journal_kept(m, s, kept)
      line = "#{line}; #{kept}"
      unreadable += 1
    end
    [line, ok, unreadable]
  end

  # A kept landing branch is journaled as well as printed: after a landing
  # nothing revisits it, so the .run line alone would be its only record.
  def journal_kept(m, s, kept)
    Store.journal(m.state_dir, now, "repo=#{s.repo} pr=##{s.pr} #{kept}")
  end

  # -> [detail, landed?, keep_branch?, unreadable branches (0 or 1; omitted is 0)]
  def land_in(m, rl, s, dir, gate_timeout, budget, idle)
    if idle.any?
      hold = P.base_deploy_hold(Forge.json([Cmd.gh, "run", "list", "--workflow", idle.last, "--branch", "main", "--limit", "5",
                                            "--json", "status,conclusion,headSha"], rl.path, "gh run list --workflow #{idle.last}"))
      if hold
        stop(m, s, "#{hold}; merge nothing but the fix or the revert until a deploy succeeds")
        return ["LINE STOPPED: #{hold}", false, false]
      end
    end
    # The local landing branch is read before any fetch: a ref git cannot
    # read is never "absent" (that cut a lane with `worktree add -b` over
    # it), and it also fails the fetch, which would name the wrong cause.
    local = begin
      Git.branch_tip(rl.path, s.branch)
    rescue CouldNotLook => e
      return ["open: local branch #{s.branch} KEPT: COULD NOT TELL (#{e.message}); nothing gated, the next run retries. Fix: #{e.fix}",
              false, true, 1]
    end
    Git.fetch_main(rl.path)
    _, code = Git.call(rl.path, "fetch", "--quiet", "origin", "+refs/heads/#{s.branch}:refs/remotes/origin/#{s.branch}")
    return ["open: could not fetch #{s.branch}; the next run retries", false, false] unless code.zero?

    # A ref that cannot be read after a good fetch is could-not-look, never a
    # moved branch (DND-1703). Reported on the PR's line like the local read
    # above: the sweep goes on and the next run retries.
    ref = "refs/remotes/origin/#{s.branch}"
    remote = Git.rev(rl.path, ref)
    unless remote
      return ["open: COULD NOT TELL (cannot read #{ref} after fetching it in #{rl.path}); nothing gated, the next run retries. " \
              "Fix: check the ref ('git -C #{rl.path} rev-parse --verify #{ref}') and the remote, then fetch it again by hand.",
              false, false]
    end
    return ["open: origin's #{s.branch} is at #{remote.to_s[0, 12]}, not the recorded head", false, false] unless remote == s.head

    if local && local != s.head
      return ["open: a local branch #{s.branch} holds #{local[0, 12]}; not clobbered, the next run retries", false, true]
    end

    args = local ? [dir, s.branch] : ["-b", s.branch, dir, s.head]
    out, code = Git.call(rl.path, "worktree", "add", "-q", *args)
    return ["open: could not cut the landing lane (#{out.strip}); the next run retries", false, true] unless code.zero?

    Meta.add("#{dir}.meta", "repo" => rl.name, "branch" => s.branch, "bootstrap" => "pending")
    after_bootstrap = MIN_GATE + MERGE_CAP + CONFIRM_CAP + TEARDOWN_CAP
    Meta.add("#{dir}.meta", "bootstrap" => bootstrap(m, rl, dir, "land", timeout: [BOOTSTRAP_CAP, budget.left - after_bootstrap].min))

    gate_cap = [gate_timeout + GATE_EXTRA, budget.left - (MERGE_CAP + CONFIRM_CAP + TEARDOWN_CAP)].min
    return ["open: CI green, but only #{gate_cap}s is left for the gate; the next run lands it", false, false] if gate_cap < MIN_GATE

    out, code = Run.call([Cmd.integration_gate, "--with-critic", "--rebase", "--slot-wait-timeout", [gate_timeout, gate_cap - 60].min.to_s],
                         chdir: dir, timeout: gate_cap)
    FileUtils.mkdir_p(runs_dir(m))
    File.write(File.join(runs_dir(m), "#{m.run_id}.#{rl.name}-pr#{s.pr}.gate.log"), out, perm: 0o600)
    after = Git.rev(dir, "HEAD")
    # Same class (DND-1703): an unreadable HEAD is never an empty head, which
    # compared unequal to the recorded one and read as a rebase.
    unless after
      return ["open: COULD NOT TELL (cannot resolve HEAD in the landing lane #{dir} after the gate, exit #{code}); nothing merged or pushed, the next run retries. " \
              "Fix: check the lane ('git -C #{dir} rev-parse --verify HEAD').", false, false]
    end

    g = P.gate_outcome(code, out, head_before: s.head, head_after: after)
    case g.action
    when :close then [close_pr(m, rl, s, g.reason), false, false]
    when :retry then ["open: #{g.reason}; the next run retries", false, false]
    when :rebased then push_rebased(m, rl, s, dir, after, g.reason)
    when :merge
      return ["open: INTEGRATION OK, but #{budget.left}s is left, under locked-merge's #{MERGE_CAP}s; the next run lands it", false, false] if budget.left < MERGE_CAP + CONFIRM_CAP

      merge(m, rl, s, dir, idle)
    end
  rescue CannotAct => e
    ["open: #{e.message}", false, false]
  end

  def push_rebased(m, rl, s, dir, after, reason)
    out, code = Forge.push(dir, "--force-with-lease=refs/heads/#{s.branch}:#{s.head}", "origin", "HEAD:refs/heads/#{s.branch}")
    return ["open: #{reason}, but the push FAILED (exit #{code}: #{out.lines.last.to_s.strip}); local branch kept", false, true] unless code.zero?

    Store.append(m.state_dir, P.event("head", at: now.iso8601, repo: s.repo, pr: s.pr, head: after))
    Store.journal(m.state_dir, now, "repo=#{s.repo} pr=##{s.pr} rebased onto main and pushed (#{after[0, 12]}); lands once its CI is green")
    ["open: #{reason}; pushed", false, false]
  end

  def merge(m, rl, s, dir, idle)
    out, code = Run.call([Cmd.locked_merge, "--pr", s.pr.to_s, "--head", s.head, "--repo", dir, "--wait", MERGE_LOCK_WAIT.to_s, *idle],
                         chdir: dir, timeout: MERGE_CAP)
    FileUtils.mkdir_p(runs_dir(m))
    File.write(File.join(runs_dir(m), "#{m.run_id}.#{rl.name}-pr#{s.pr}.merge.log"), out, perm: 0o600)
    mo = P.merge_outcome(code)
    return ["open: #{mo.reason}; the next run retries", false, false] if mo.action == :retry

    if mo.action == :stop_line
      stop(m, s, mo.reason)
      return ["LINE STOPPED: #{mo.reason}", false, false]
    end
    # locked-merge confirms the landing itself (its step 6); this is the
    # ticket's own explicit confirm, from the run's side, before it records it.
    _, code = Run.call([Cmd.confirm_merged, "--pr", s.pr.to_s, "--repo", dir, "--fetch"], chdir: dir, timeout: CONFIRM_CAP)
    co = P.confirm_outcome(code)
    if co.action == :stop_line
      stop(m, s, co.reason)
      return ["LINE STOPPED: #{co.reason}", false, false]
    end
    sha = begin
      Forge.pr_view(rl.path, s.pr).dig("mergeCommit", "oid").to_s
    rescue CouldNotLook
      ""
    end
    sha = "unknown" unless sha.match?(P::SHA_RE)
    Store.append(m.state_dir, P.event("merged", at: now.iso8601, repo: s.repo, pr: s.pr, merge_sha: sha))
    Store.journal(m.state_dir, now, "repo=#{s.repo} pr=##{s.pr} LANDED (#{sha[0, 12]}); watching its deploy")
    warning = P.merge_warning(out)
    if warning
      stop(m, s, "#{warning} (merged onto a base whose deploy had not succeeded)")
      return ["landed #{sha[0, 12]}, but LINE STOPPED: #{warning}", true, false]
    end
    ["landed #{sha[0, 12]}; deploy pending", true, false]
  end

  # -> nil, or the line naming a landing branch git could not read (DND-1677) or
  # could not delete (DND-1702): it is KEPT (never skipped in silence) with its Fix:.
  def retire_land_lane(m, rl, dir, merged:, keep_branch:)
    meta = Meta.read("#{dir}.meta")
    if STACK_STATES.include?(meta["bootstrap"]) && !merged
      Run.call([Cmd.teardown_stack, "--worktree", dir, "--parked", "lead-time landing lane #{m.run_id}"], chdir: "/", timeout: TEARDOWN_CAP)
    end
    Git.remove_worktree(rl.path, dir) if File.exist?(dir)
    branch = meta["branch"]
    kept = nil
    if branch && !keep_branch
      begin
        Git.delete_branch(rl.path, branch) if Git.branch_tip(rl.path, branch)
      rescue CouldNotLook => e
        kept = "landing branch #{branch} KEPT: COULD NOT TELL (#{e.message}). Fix: #{e.fix}"
      end
    end
    FileUtils.rm_f("#{dir}.meta")
    kept
  end

  # ── a lane's end: teardown (this run's) and reap (a dead run's) ──────────

  # -> [:none|:gone|:delete|:awaiting|:stranded, branch, detail]
  def retire_lane(m, rl, dir, why)
    meta = Meta.read("#{dir}.meta")
    branch = meta["branch"]
    if branch.nil? && File.directory?(dir)
      # A lane cut before its meta was written (a run that died between the
      # two): its branch is whatever it has checked out. One it cannot read is
      # KEPT, never read as "no lane cut".
      out, code = Git.call(dir, "symbolic-ref", "-q", "--short", "HEAD")
      branch = out.strip if code.zero? && !out.strip.empty?
      return [:stranded, nil, "COULD NOT TELL: #{dir} records no branch and has none checked out; the lane is KEPT"] unless branch
    end
    # Read the tip BEFORE anything is removed: a tip git cannot read raises
    # with the worktree, stack, lock and meta all intact, so the next tick
    # can reach the lane again and judge it (the lockless reap finds a lane
    # by its directory; a lane with no meta has its branch only in it).
    tip = branch && Git.branch_tip(rl.path, branch)
    if STACK_STATES.include?(meta["bootstrap"])
      Run.call([Cmd.teardown_stack, "--worktree", dir, "--parked", why], chdir: "/", timeout: TEARDOWN_CAP)
    end
    had_worktree = File.exist?(dir)
    Git.remove_worktree(rl.path, dir) if had_worktree
    unless tip
      verdict, detail = P.no_branch_ref(lane: File.basename(dir), branch: branch, had_worktree: had_worktree)
      return [verdict, branch, detail]
    end

    on_main = Git.ancestor?(rl.path, tip, "refs/remotes/origin/main") == true
    rec = Store.states(m.state_dir).reverse.find { |st| st.repo == rl.name && st.branch == branch }
    verdict = P.retire(tip: tip, on_main: on_main, recorded_head: rec&.head)
    case verdict
    when :delete then Git.delete_branch(rl.path, branch)
                      [verdict, branch, "removed (work on origin/main)"]
    when :awaiting then Git.delete_branch(rl.path, branch)
                        [verdict, branch, "awaiting landing on PR ##{rec.pr} (#{tip[0, 12]} pushed)"]
    else [verdict, branch, "STRANDED: branch #{branch} KEPT (#{tip[0, 12]} is not the head of a recorded improver PR: unpushed, or pushed with no PR opened)"]
    end
  end

  # -> [lines, stranded?]. The runner calls it after the session, with the
  # lane locks still held, then closes them.
  def teardown(m)
    stranded = false
    lines = m.repos.map do |rl|
      unless File.exist?(rl.lane) || File.exist?("#{rl.lane}.meta")
        next "product_lane: repo=#{rl.name} none (no lane cut)"
      end

      verdict, _, detail = retire_lane(m, rl, rl.lane, "lead-time product lane #{m.run_id}")
      FileUtils.rm_f("#{rl.lane}.meta")
      stranded ||= verdict == :stranded
      "product_lane: repo=#{rl.name} #{detail}"
    rescue CouldNotDelete => e
      # Reported, never counted: a failed delete must not fail or wedge the tick.
      FileUtils.rm_f("#{rl.lane}.meta")
      "product_lane: repo=#{rl.name} COULD NOT DELETE branch, KEPT (#{e.message}). Fix: #{e.fix}"
    rescue P::Error => e
      stranded = true
      "product_lane: repo=#{rl.name} COULD NOT TELL (#{e.message}); branch kept. Fix: #{e.fix}"
    end
    [lines, stranded]
  end

  def own_lane?(m, rid) = [m.run_id, "#{m.run_id}-land"].include?(rid)

  # A product lane whose lock nobody holds belongs to a run that died before
  # its teardown. Reaped while holding its lock; a live one is left alone.
  def reap(m)
    lines = []
    m.repos.each do |rl|
      next unless File.directory?(rl.lanes_dir)

      Dir.glob(File.join(rl.lanes_dir, "run-*.lock")).sort.each do |lock|
        rid = File.basename(lock, ".lock")
        next if own_lane?(m, rid)

        dir = File.join(rl.lanes_dir, rid)
        read = nil
        got = Locks.with(lock) do
          detail, read = reap_one(m, rl, dir, "reaped dead lead-time lane #{rid}")
          lines << "product_reaped: repo=#{rl.name} lane=#{rid} #{detail}"
        end
        next if got == :held || !read

        FileUtils.rm_f([lock, "#{dir}.meta"])
      end
      Dir.glob(File.join(rl.lanes_dir, "run-*")).select { |d| File.directory?(d) }.sort.each do |dir|
        next if File.exist?("#{dir}.lock") || own_lane?(m, File.basename(dir))

        detail, read = reap_one(m, rl, dir, "reaped lockless lead-time lane")
        FileUtils.rm_f("#{dir}.meta") if read
        lines << "product_reaped: repo=#{rl.name} lane=#{File.basename(dir)} (lockless) #{detail}"
      end
    end
    lines
  end

  # One dead lane -> [detail, read?]. A lane whose state could not be read is
  # named and kept (its lock and meta stay for the next tick), and the reap
  # goes on to the next lane: one unreadable lane never stops the others.
  def reap_one(m, rl, dir, why)
    _, _, detail = retire_lane(m, rl, dir, why)
    [detail, true]
  rescue P::Error => e
    ["COULD NOT TELL (#{e.message}); branch kept. Fix: #{e.fix}", false]
  end
end
