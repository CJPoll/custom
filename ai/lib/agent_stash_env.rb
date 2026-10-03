# frozen_string_literal: true

# agent_stash_env — the activation state of the DND-775 agent-stash guard, for
# ai/bin/check-hooks-registered.
#
# ai/hooks/registry.json's `env` section is what scripts/setup-hooks --install-env
# (the owner's activation step; plain --install never touches it) merges into the Claude Code settings `env`: four GIT_CONFIG pairs that
# register the reference-transaction hook ai/git-hooks/agent-stash-guard.sh,
# GIT_TRACE2=/dev/null, and ATHENA_AGENT_BIN (the PATH git wrapper's directory).
# {{MAIN}} in a value is the MAIN checkout's absolute path, never a worktree's.
#
# Three states of the settings env, and they must never read alike (a fourth,
# PENDING RESTART, is about the session, below):
#   INACTIVE  none of the guard's keys (its four GIT_CONFIG keys,
#             ATHENA_AGENT_BIN, or the install stamp ATHENA_AGENT_ENV_INSTALLED_AT)
#             is in the settings env. Exit 0 with its own
#             line: the guard lands inert and the owner activates it
#             (condition e). Not activated is a state, not "fine" and not a
#             failure.
#   ACTIVE    every key is present with its exact value, the GIT_CONFIG pairs
#             inside GIT_CONFIG_COUNT. Then the runtime is asserted too (the
#             hook script exists and is executable in the main checkout; git
#             lists the hook; the wrapper is executable and its directory
#             holds nothing but what ai/agent-bin/ holds AS LANDED; the
#             CLAUDE_ENV_FILE script carries the PATH line)
#             and each failure is exit 1 with a Fix:.
#   DRIFT     some keys present, or a value that differs (a hook path in a
#             worktree, say). Exit 1, each difference named.
# A settings env that cannot be read (GIT_CONFIG_COUNT not a number, a value
# that is not a string) is DRIFT as well, never INACTIVE: a failed read must not
# look like an empty one.
#
# PENDING RESTART (DND-1036) is ACTIVE for a session that predates the install.
# Claude Code hot-reloads the settings env into a running session, so after
# --install-env an old session carries ATHENA_AGENT_BIN, but its Bash tool
# need not pick up CLAUDE_ENV_FILE: Claude Code 2.1.283 reads it at the
# session's first Bash command and caches the result for the session (read
# from its bundle, not measured on a hot-reload). So its PATH can still lack
# the wrapper. That session is not drift: a restart fixes it.
#
# HOW THE WRAPPER REACHES THE BASH TOOL'S PATH (DND-1080). The Bash tool runs
# each command as `zsh -c "source <snapshot> && <CLAUDE_ENV_FILE text> ... &&
# eval <command>"`. The snapshot is built at session start by sourcing
# ~/.zshrc, but it ENDS with `export PATH=<Claude Code's own process PATH>`, so
# a PATH change made in ~/.zshrc never reaches the tool shell. The
# CLAUDE_ENV_FILE text runs after the snapshot: ai/agent-env/session-env.sh
# carries ENV_LINE, which prepends ATHENA_AGENT_BIN. The settings env sets
# CLAUDE_ENV_FILE to that file. It is PENDING RESTART
# (exit 0) only when ALL of these hold: the settings values match the landed
# env, every runtime check passes, the session's ATHENA_AGENT_BIN is the right
# one, the only problem is the first git on PATH, and the snapshot this
# process's shell sourced was built BEFORE the install. Both times are read:
#   - install time: ATHENA_AGENT_ENV_INSTALLED_AT in the settings env, an ISO
#     UTC second the installer writes in the same file write that adds
#     ATHENA_AGENT_BIN or CLAUDE_ENV_FILE (the keys whose arrival puts the
#     wrapper on a new session's PATH), and at no other time: a later
#     --install-env that only
#     adds GIT_CONFIG pairs leaves it alone, so a session started after the
#     wrapper arrived cannot be re-dated as pending. It is machine state, never
#     the branch's. settings.json's mtime is not used: any later edit moves it,
#     which would read a session started after the install as pending.
#   - session time: "session start" means the SNAPSHOT. The snapshot is built
#     once, at session start, and CLAUDE_ENV_FILE is read no earlier (see
#     above), so the snapshot's build time (the epoch ms in its
#     file name) is the earliest moment this session's PATH could have been
#     fixed. The nearest ancestor naming a snapshot in its argv
#     wins, so a gate run under test-slot/harness-gate, or a nested session,
#     reads its own shell's snapshot.
# Either time that cannot be read (no stamp, a malformed stamp, a stamp in the
# future, no snapshot ancestor, an unreadable /proc) is COULD NOT MEASURE (exit
# 3), never PENDING. A snapshot built at or after the install is FAIL: the
# restart already happened and the wrapper is still not first.
#
# The disable is `scripts/setup-hooks --remove-env`, then restart sessions.

require "open3"
require "tmpdir"

module AgentStashEnv
  PLACEHOLDER = "{{MAIN}}"
  HOOK_REL    = "ai/git-hooks/agent-stash-guard.sh"
  # The PATH line ai/agent-env/session-env.sh carries (DND-1080). Claude Code
  # runs that file's text after the shell snapshot, so this is the one place a
  # PATH change reaches the Bash tool's shell.
  ENV_LINE    = 'if [ -n "${ATHENA_AGENT_BIN:-}" ] && [ -x "$ATHENA_AGENT_BIN/git" ]; then PATH="$ATHENA_AGENT_BIN:$PATH"; export PATH; fi'
  ENV_FILE    = "CLAUDE_ENV_FILE"
  # The files ATHENA_AGENT_BIN may hold are those ai/agent-bin/ holds AS LANDED
  # (DND-1842): each shadows the real command on agent PATH on purpose, and
  # anything else there would shadow one by accident. ai/bin/check-hooks-registered
  # reads the list from git at the landed tip; it is never kept here. A constant
  # in this file is in the diff it judges (DND-1803 finding 2), and an older
  # pinned tree's constant misjudges a main checkout that a newer landing has
  # already filled (the false main-health RED on 5414505c, 2026-10-03).
  BIN_REL     = "ai/agent-bin"
  # Vars other tools set too. Their presence alone is no trace of the guard.
  SHARED_VARS = ["GIT_TRACE2", ENV_FILE].freeze
  DISABLE     = "scripts/setup-hooks --remove-env"
  # The install stamp scripts/setup-hooks --install-env writes (DND-1036).
  INSTALLED_AT = "ATHENA_AGENT_ENV_INSTALLED_AT"
  STAMP_RE     = /\A(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})Z\z/.freeze
  # Claude Code's Bash tool runs `zsh -c "source <home>/.claude/shell-snapshots/
  # snapshot-<shell>-<epoch ms>-<id>.sh ..."`. Matched structurally: a shell's
  # `-c` script that STARTS by sourcing the snapshot. A path merely mentioned
  # elsewhere in some ancestor's argv (a grep, a prompt, `ls <path>; ...`) is
  # not the snapshot that shell sourced, and would date the session wrongly.
  SNAPSHOT_RE  = %r{\A\s*(?:source|\.)\s+(/\S*/shell-snapshots/snapshot-[A-Za-z0-9]+-(\d{12,})-[A-Za-z0-9]+\.sh)(?:\s|;|\z)}.freeze
  SHELLS       = %w[zsh bash sh dash].freeze
  # Clock skew tolerated before a time "in the future" is refused.
  SKEW_S       = 300

  Result = Struct.new(:state, :lines, :code)

  # A time the pending decision needs could not be read. Never PENDING.
  class Unmeasured < StandardError; end

  module_function

  # The registry's env section expanded for `main`, as
  # {pairs: [[key, value], ...], vars: {name => value}}; nil when the registry
  # has no env section.
  def expected(registry, main)
    env = registry.is_a?(Hash) ? registry["env"] : nil
    return nil unless env.is_a?(Hash)

    ex = ->(v) { v.to_s.gsub(PLACEHOLDER, main) }
    { pairs: Array(env["git_config"]).map { |e| [e["key"].to_s, ex.call(e["value"])] },
      vars: (env["vars"] || {}).to_h { |k, v| [k.to_s, ex.call(v)] } }
  end

  # The keys whose presence means the guard was installed (GIT_TRACE2 or
  # CLAUDE_ENV_FILE alone is not: the owner may set either for other reasons).
  def marker_keys(exp)
    exp[:pairs].map(&:first) + (exp[:vars].keys - SHARED_VARS)
  end

  # Whether a settings env carries ANY trace of the guard, judged by a fixed
  # rule that no registry supplies: a GIT_CONFIG_KEY_n (any n, inside the count
  # or not) naming hook.agentstash.* or hook.reference-transaction.* (section
  # and variable case-insensitive, as git reads them), or ATHENA_AGENT_BIN. It
  # decides INACTIVE, so it must not come from the registry a branch can edit
  # (critic round 4): a branch that deleted or renamed the env section would
  # otherwise make a live guard read INACTIVE.
  GUARD_KEY = /\A[hH][oO][oO][kK]\.(agentstash|reference-transaction)\./.freeze

  def any_guard_key?(env)
    return true unless env.nil? || env.is_a?(Hash) # an unreadable env is not "none"
    return false if env.nil?

    env.key?("ATHENA_AGENT_BIN") || env.key?(INSTALLED_AT) ||
      env.any? { |k, v| k.to_s.match?(/\AGIT_CONFIG_KEY_\d+\z/) && v.to_s.match?(GUARD_KEY) }
  end

  # The GIT_CONFIG entries of a settings env: [[index, key, value], ...] for
  # every index below GIT_CONFIG_COUNT, plus the stray KEY_n at or past it.
  # Raises ArgumentError when the count or an entry cannot be read.
  def config_entries(env)
    raw = env.fetch("GIT_CONFIG_COUNT", "0")
    raise ArgumentError, "GIT_CONFIG_COUNT is #{raw.inspect}, not a count" unless raw.is_a?(String) && raw.match?(/\A\d+\z/)

    count = raw.to_i
    inside = (0...count).map do |i|
      k = env["GIT_CONFIG_KEY_#{i}"]
      v = env["GIT_CONFIG_VALUE_#{i}"]
      raise ArgumentError, "GIT_CONFIG_KEY_#{i}/VALUE_#{i} missing or not strings (GIT_CONFIG_COUNT=#{count})" unless k.is_a?(String) && v.is_a?(String)

      [i, k, v]
    end
    stray = env.keys.grep(/\AGIT_CONFIG_KEY_(\d+)\z/).map { |k| k[/\d+\z/].to_i }.select { |i| i >= count }
    [inside, stray.sort, count]
  end

  # -> Result for the settings `env` hash against the expectation.
  def settings_state(env, exp)
    env ||= {}
    return Result.new(:drift, ["settings env is not an object: #{env.class}"], 1) unless env.is_a?(Hash)

    begin
      inside, stray, count = config_entries(env)
    rescue ArgumentError => e
      return Result.new(:drift, ["the settings env cannot be read: #{e.message}"], 1)
    end
    keys_present = inside.map { |(_, k, _)| k } + stray.map { |i| env["GIT_CONFIG_KEY_#{i}"] }
    present = marker_keys(exp).select { |k| keys_present.include?(k) || env.key?(k) }
    return Result.new(:inactive, [], 0) if present.empty?

    diffs = []
    exp[:pairs].each do |(key, value)|
      hits = inside.select { |(_, k, _)| k == key }
      if hits.empty?
        where = stray.find { |i| env["GIT_CONFIG_KEY_#{i}"] == key }
        diffs << (where ? "#{key} is at GIT_CONFIG_KEY_#{where}, past GIT_CONFIG_COUNT=#{count} (git never reads it)" : "#{key} is missing")
      elsif hits.size > 1
        diffs << "#{key} is set #{hits.size} times (indexes #{hits.map(&:first).join(', ')})"
      elsif hits.first[2] != value
        diffs << "#{key} at index #{hits.first[0]} differs: have #{hits.first[2].inspect}, want #{value.inspect}"
      end
    end
    exp[:vars].each do |(name, value)|
      if !env.key?(name) then diffs << "#{name} is missing"
      elsif env[name] != value then diffs << "#{name} differs: have #{env[name].inspect}, want #{value.inspect}"
      end
    end
    diffs.empty? ? Result.new(:active, [], 0) : Result.new(:drift, diffs, 1)
  end

  # The entries of the live wrapper directory `bin` that `allowed` does not
  # name, sorted. Empty only when the directory does not exist: the
  # missing-wrapper problem in runtime_problems reports that case. Any other
  # read failure raises, so the caller reports COULD NOT MEASURE: a directory
  # that cannot be listed must not read as one holding nothing extra.
  def bin_extras(bin, allowed)
    (Dir.children(bin) - allowed).sort
  rescue Errno::ENOENT
    []
  end

  # Runtime problems of an ACTIVE install: [] when all hold. bin_files is the
  # wrapper directory's allowlist, and bin_bar names where it was read (the
  # landed ai/agent-bin/, or a newer origin/main's).
  def runtime_problems(env, exp, main:, bin_files:, bin_bar:)
    out = []
    hook = File.join(main, HOOK_REL)
    unless File.file?(hook) && File.executable?(hook)
      out << "the hook script #{hook} is #{File.exist?(hook) ? 'not executable' : 'missing'}: every ref " \
             "update in an agent session fails closed. Fix: restore it (git -C #{main} checkout -- #{HOOK_REL}), " \
             "or the owner runs #{File.join(main, DISABLE)} and restarts sessions."
    end
    listed = hook_listed(env)
    unless listed == "agentstash"
      out << "`git hook list reference-transaction` under the settings env printed #{listed.inspect}, not " \
             "\"agentstash\": this git does not load the config-based hook. Fix: record `git --version`; " \
             "config-based hooks need git >= 2.54 (DND-775 probe 3). Until git is upgraded, the owner runs " \
             "#{File.join(main, DISABLE)}."
    end
    bin = exp[:vars]["ATHENA_AGENT_BIN"].to_s
    wrapper = File.join(bin, "git")
    if !(File.file?(wrapper) && File.executable?(wrapper))
      out << "the PATH git wrapper #{wrapper} is missing or not executable; the CLAUDE_ENV_FILE line then leaves PATH " \
             "alone and drop/reflog go unguarded. Fix: restore ai/agent-bin/git in #{main}."
    elsif (extra = bin_extras(bin, bin_files)).any?
      allowed = bin_files.empty? ? "nothing (it lands no file there)" : bin_files.sort.join(", ")
      out << "#{bin} holds #{extra.join(', ')} besides #{allowed} (#{bin_bar}); anything there " \
             "shadows a real command on agent PATH. Fix: move it out of #{bin}, or land it in #{BIN_REL}/ on " \
             "main first."
    end
    out.concat(env_file_problems(exp, main))
    out
  end

  # The CLAUDE_ENV_FILE script the landed env names must carry ENV_LINE, and
  # nothing else but comments: it is the only thing that puts the wrapper on
  # the Bash tool's PATH (DND-1080).
  def env_file_problems(exp, main)
    file = exp[:vars][ENV_FILE].to_s
    if file.empty?
      return ["the landed env sets no #{ENV_FILE}, so nothing puts the wrapper on the Bash tool's PATH (the " \
              "shell snapshot ends with Claude Code's own PATH, whatever ~/.zshrc did). Fix: land the " \
              "#{ENV_FILE} var in ai/hooks/registry.json's env, then the owner runs " \
              "`#{File.join(main, 'scripts/setup-hooks')} --install-env` and restarts sessions."]
    end
    restore = "Fix: restore ai/agent-env/session-env.sh in #{main} (git -C #{main} checkout -- " \
              "ai/agent-env/session-env.sh), then restart sessions."
    begin
      code = File.read(file).lines.map(&:strip).reject { |l| l.empty? || l.start_with?("#") }
      unless code.include?(ENV_LINE)
        return ["#{ENV_FILE} #{file} does not carry the agent PATH line, so the wrapper never reaches the Bash " \
                "tool's PATH. #{restore}"]
      end
      # The text runs before every Bash command in every session, and every
      # such process sees CLAUDE_ENV_FILE pointing here, so a stray
      # `>> "$CLAUDE_ENV_FILE"` would land here. Anything but ENV_LINE is
      # foreign: it runs in every session, and one that fails breaks the `&&`
      # chain Claude Code builds around the command.
      extra = code - [ENV_LINE]
      return [] if extra.empty?

      ["#{ENV_FILE} #{file} runs #{extra.size} line(s) besides the agent PATH line (first: " \
       "#{extra.first[0, 80].inspect}); they run before every Bash command in every session. #{restore}"]
    rescue SystemCallError => e
      ["#{ENV_FILE} #{file} cannot be read (#{e.class}), so the wrapper never reaches the Bash tool's PATH. " \
       "#{restore}"]
    end
  end

  # `git hook list reference-transaction` in a throwaway repo with ONLY the
  # settings env's GIT_CONFIG entries (the process's own are dropped).
  def hook_listed(env)
    Dir.mktmpdir("agent-stash-env") do |d|
      child = ENV.keys.grep(/\AGIT_CONFIG_(KEY|VALUE)_\d+\z/).to_h { |k| [k, nil] }
      child["GIT_CONFIG_PARAMETERS"] = nil
      env.each { |k, v| child[k] = v if k.start_with?("GIT_CONFIG_") }
      child["GIT_CONFIG_COUNT"] = env.fetch("GIT_CONFIG_COUNT", "0")
      _o, _e, st = Open3.capture3(child, "git", "init", "-q", d)
      return "(git init failed)" unless st.success?

      out, err, st = Open3.capture3(child, "git", "-C", d, "hook", "list", "reference-transaction")
      st.success? ? out.strip : "(rc=#{st.exitstatus}: #{err.strip.lines.first.to_s.strip})"
    end
  rescue SystemCallError => e
    "(could not run git: #{e.message})"
  end

  # The process this check runs in. When it carries ATHENA_AGENT_BIN, it is an
  # activated agent session, and its PATH must put the wrapper first.
  # Returns [note_lines, problem_lines, path_problem]. path_problem is the
  # first-git-on-PATH line (nil when the wrapper is first), kept apart because
  # it alone can be a pending restart rather than a failure (DND-1036).
  def session_state(exp, proc_env: ENV)
    want_bin = exp[:vars]["ATHENA_AGENT_BIN"].to_s
    have_bin = proc_env["ATHENA_AGENT_BIN"].to_s
    if have_bin.empty?
      return [["this process does not carry the agent-stash env (not an agent session, or one started " \
               "before activation: restart it to load the settings env)."], [], nil]
    end
    probs = []
    probs << "this session's ATHENA_AGENT_BIN is #{have_bin.inspect}, want #{want_bin.inspect}. Fix: restart it." if have_bin != want_bin
    first = proc_env.fetch("PATH", "").split(":").map { |d| File.join(d.empty? ? "." : d, "git") }
                    .find { |g| File.file?(g) && File.executable?(g) }
    path_problem = nil
    unless first && File.expand_path(first) == File.join(File.expand_path(have_bin), "git")
      path_problem = "this session's first git on PATH is #{first.inspect}, not #{File.join(have_bin, 'git')}: the " \
                     "#{ENV_FILE} script did not prepend the wrapper after the shell snapshot. Fix: check this " \
                     "session's #{ENV_FILE} is #{exp[:vars][ENV_FILE].inspect} and carries the agent PATH " \
                     "line, then restart the session."
    end
    [[], probs, path_problem]
  end

  # The install time recorded in the settings env, as a UTC Time. Raises
  # Unmeasured when it is absent, malformed, or later than now + SKEW_S (a
  # future stamp would read every running session as pending).
  def installed_at(env, now: Time.now)
    raw = env.is_a?(Hash) ? env[INSTALLED_AT] : nil
    if raw.nil?
      raise Unmeasured, "the settings env has no #{INSTALLED_AT}, so the install time is unknown (an install " \
                        "made before DND-1036 recorded none)"
    end
    m = raw.is_a?(String) ? raw.match(STAMP_RE) : nil
    raise Unmeasured, "#{INSTALLED_AT} is #{raw.inspect}, not a UTC time like 2026-09-28T07:19:25Z" unless m

    t = begin
      Time.utc(*m.captures.map(&:to_i))
    rescue ArgumentError
      nil
    end
    raise Unmeasured, "#{INSTALLED_AT} is #{raw.inspect}, which is not a real UTC time" unless t && iso(t) == raw
    raise Unmeasured, "#{INSTALLED_AT} is #{raw}, in the future (now #{iso(now)})" if t > now + SKEW_S

    t
  end

  # The shell snapshot this process's shell sourced: [build Time (UTC), path].
  # Walks the ancestors from `pid` through `proc_root`; the nearest whose argv
  # names a snapshot wins. Raises Unmeasured when no ancestor names one, when
  # /proc cannot be read, or when the build time is in the future.
  def session_snapshot(pid: Process.pid, proc_root: "/proc", now: Time.now)
    walked = []
    seen = {}
    while pid.positive? && !seen[pid]
      seen[pid] = true
      argv = begin
        File.binread(File.join(proc_root, pid.to_s, "cmdline")).split("\0")
      rescue SystemCallError => e
        raise Unmeasured, "cannot read #{File.join(proc_root, pid.to_s, 'cmdline')} (#{e.class}) while looking " \
                          "for this session's shell snapshot"
      end
      if (m = sourced_snapshot(argv))
        ms = m[2].to_i
        t = Time.at(ms / 1000, ms % 1000, :millisecond).utc
        raise Unmeasured, "the shell snapshot #{m[1]} claims a build time #{iso(t)}, in the future" if t > now + SKEW_S

        return [t, m[1]]
      end
      walked << pid
      pid = parent_pid(pid, proc_root)
    end
    raise Unmeasured, "no ancestor of this process sourced a Claude Code shell snapshot (walked pids " \
                      "#{walked.join(' ')}), so when this session's PATH was fixed is unknown"
  end

  # The SNAPSHOT_RE match when argv is a shell (by basename, a login `-zsh`
  # included) run with `-c <script>` whose script starts by sourcing a
  # snapshot; else nil.
  def sourced_snapshot(argv)
    return nil unless SHELLS.include?(File.basename(argv.first.to_s).delete_prefix("-"))

    i = argv.index("-c")
    i && argv[i + 1] ? argv[i + 1].match(SNAPSHOT_RE) : nil
  end

  # The PPid field of /proc/<pid>/stat (the field after the state, which
  # follows the last ")" -- the comm may itself hold parentheses or spaces).
  def parent_pid(pid, proc_root)
    stat = File.read(File.join(proc_root, pid.to_s, "stat"))
    close = stat.rindex(")")
    raise Unmeasured, "#{File.join(proc_root, pid.to_s, 'stat')} is malformed" unless close

    Integer(stat[(close + 1)..].split[1], 10)
  rescue SystemCallError, ArgumentError, TypeError => e
    raise Unmeasured, "cannot read the parent of pid #{pid} from #{File.join(proc_root, pid.to_s, 'stat')} (#{e.class})"
  end

  # Pure: the verdict on a session whose only problem is the first git on PATH.
  # :pending when the snapshot was built strictly before the install, else
  # :fail. The stamp is truncated to the second, so a snapshot inside the
  # install's own second reads :fail (the conservative side).
  def pending_verdict(snapshot_time, install_time)
    snapshot_time < install_time ? :pending : :fail
  end

  def iso(time)
    time.utc.strftime("%Y-%m-%dT%H:%M:%SZ")
  end
end
