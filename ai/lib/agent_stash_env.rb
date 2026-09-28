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
# Three states, and they must never read alike:
#   INACTIVE  none of the guard's keys (its four GIT_CONFIG keys, or
#             ATHENA_AGENT_BIN) is in the settings env. Exit 0 with its own
#             line: the guard lands inert and the owner activates it
#             (condition e). Not activated is a state, not "fine" and not a
#             failure.
#   ACTIVE    every key is present with its exact value, the GIT_CONFIG pairs
#             inside GIT_CONFIG_COUNT. Then the runtime is asserted too (the
#             hook script exists and is executable in the main checkout; git
#             lists the hook; the wrapper is executable and alone in its
#             directory; the shell profile line is present) and each failure
#             is exit 1 with a Fix:.
#   DRIFT     some keys present, or a value that differs (a hook path in a
#             worktree, say). Exit 1, each difference named.
# A settings env that cannot be read (GIT_CONFIG_COUNT not a number, a value
# that is not a string) is DRIFT as well, never INACTIVE: a failed read must not
# look like an empty one.
#
# The disable is `scripts/setup-hooks --remove-env`, then restart sessions.

require "open3"
require "tmpdir"

module AgentStashEnv
  PLACEHOLDER = "{{MAIN}}"
  HOOK_REL    = "ai/git-hooks/agent-stash-guard.sh"
  ZSHRC_LINE  = 'if [ -n "${ATHENA_AGENT_BIN:-}" ] && [ -x "$ATHENA_AGENT_BIN/git" ]; then PATH="$ATHENA_AGENT_BIN:$PATH"; fi'
  DISABLE     = "scripts/setup-hooks --remove-env"

  Result = Struct.new(:state, :lines, :code)

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

  # The keys whose presence means the guard was installed (GIT_TRACE2 alone is
  # not: the owner may set it for other reasons).
  def marker_keys(exp)
    exp[:pairs].map(&:first) + (exp[:vars].keys - ["GIT_TRACE2"])
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

    env.key?("ATHENA_AGENT_BIN") ||
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

  # Runtime problems of an ACTIVE install: [] when all hold.
  def runtime_problems(env, exp, main:, zshrc:)
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
      out << "the PATH git wrapper #{wrapper} is missing or not executable; the shell line then leaves PATH " \
             "alone and drop/reflog go unguarded. Fix: restore ai/agent-bin/git in #{main}."
    elsif (extra = Dir.children(bin) - ["git"]).any?
      out << "#{bin} holds #{extra.sort.join(', ')} besides git; anything there shadows a real command on " \
             "agent PATH. Fix: move it out of #{bin}."
    end
    text = File.exist?(zshrc) ? File.read(zshrc) : nil
    unless text&.lines&.any? { |l| l.strip == ZSHRC_LINE }
      out << "#{zshrc} does not carry the agent PATH line, so the wrapper never reaches agent PATH. " \
             "Fix: the line lives last in dotfiles/.zshrc on main; make #{zshrc} that file (it is a symlink " \
             "to it on the owner's machines) and restart sessions."
    end
    out
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
  # Returns [note_lines, problem_lines].
  def session_state(exp, proc_env: ENV)
    want_bin = exp[:vars]["ATHENA_AGENT_BIN"].to_s
    have_bin = proc_env["ATHENA_AGENT_BIN"].to_s
    if have_bin.empty?
      return [["this process does not carry the agent-stash env (not an agent session, or one started " \
               "before activation: restart it to load the settings env)."], []]
    end
    probs = []
    probs << "this session's ATHENA_AGENT_BIN is #{have_bin.inspect}, want #{want_bin.inspect}. Fix: restart it." if have_bin != want_bin
    first = proc_env.fetch("PATH", "").split(":").map { |d| File.join(d.empty? ? "." : d, "git") }
                    .find { |g| File.file?(g) && File.executable?(g) }
    unless first && File.expand_path(first) == File.join(File.expand_path(have_bin), "git")
      probs << "this session's first git on PATH is #{first.inspect}, not #{File.join(have_bin, 'git')}: the " \
               "last line of ~/.zshrc did not prepend the wrapper when the shell snapshot was built. Fix: " \
               "check ~/.zshrc ends with the agent PATH line, then restart the session."
    end
    [[], probs]
  end
end
