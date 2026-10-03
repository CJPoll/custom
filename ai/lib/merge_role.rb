# frozen_string_literal: true

# merge_role -- the DOMAIN of ai/hooks/merge-role-guard.sh (DND-726): which
# tool calls merge, land onto a protected branch, or spawn an admiral, and
# which callers may make them. Pure: no I/O, no process execution. The git
# facts a decision needs (a directory's current branch, its default branch,
# where a no-refspec push goes, whether it is a cron lane) are resolved by
# ai/lib/merge_role_io.rb and passed in.
#
# The rule it enforces is athena:merge-boarding's "merging is the admiral's
# alone". It is keyed on an ALLOW-list of roles, never on a deny of
# athena-captain, so a captain's general-purpose subagent, a future role and a
# hand-spawned shipwright are denied too. There is no env var, file or marker
# that widens the list (~/dev/custom/CLAUDE.md -> "A check's own bar must not
# live in the diff it is checking"); widening it is a reviewed diff here.
# The one environment read, Claude Code's own session-mode variables
# (attended?), is not such a marker: Claude Code sets both itself, a
# subagent's Bash cannot change the process env the hook inherits, `claude -p`
# overwrites an inherited pair, and a subagent is denied by its agent_id
# whatever the pair says.
#
# Matching is LEXICAL and over-reads on purpose: subcommand tokens anywhere in
# the command, quotes and backslash escapes removed the way the shell removes
# them, `sh -c` scripts read as commands. A command that only MENTIONS a merge
# is denied for a non-admiral (the accepted false positive; DND-397: a lexical
# guard cannot prove quoted text inert). Anything it cannot resolve (a
# directory or a destination held in a variable, a push destination set by
# config) is :unresolved, which a non-admiral is denied for: an unresolved key
# never reads as "not main".
module MergeRole
  ADMIRAL = "athena-admiral"
  SHIPWRIGHT = "athena-shipwright"
  ALWAYS_PROTECTED = %w[main master].freeze

  # One merge-class candidate. kind is one of:
  #   :cli_merge     rule 1 (pr merge, mr merge/accept, locked-merge)
  #   :api_merge     rule 2 (REST/GraphQL/GitLab merge and ref-write endpoints)
  #   :push          rule 3 (needs facts: dests, or the no-refspec push_dests)
  #   :local         rule 4 (needs facts: dir's current branch)
  #   :force_ref     rule 4 (update-ref / branch -f / checkout -B / fetch /
  #                  rebase <upstream> <branch>, onto a named branch)
  #   :wt_merge      rule 5 (wt merge, gt merge)
  #   :mcp_merge     rule 6 (an MCP tool whose name merges or enqueues)
  #   :spawn_admiral rule 7 (an Agent/Task spawn of athena-admiral)
  # dir is an absolute path String, or :unresolved. dests holds branch names
  # and the symbols :current, :all and :unresolved.
  Intent = Struct.new(:kind, :text, :dir, :remote, :dests, :all, :sub, :args, :cfg_unresolved,
                      keyword_init: true)

  # The git facts for one (dir, remote), from MergeRoleIO:
  #   resolved    false when the dir could not be resolved or is not a repo
  #   current     the current branch name, "" when HEAD is detached
  #   default     the remote's default branch name; :unknown when the repo
  #               resolved but refs/remotes/<remote>/HEAD is missing
  #   push_dests  where a push with no refspec goes: [:current] by default,
  #               [:all] for push.default=matching, or the names set by
  #               remote.<r>.push / push.default=upstream
  #   remotes     the repo's remote names; [] only when git answered and the
  #               repo has none, nil when it could not be read
  Facts = Struct.new(:resolved, :current, :default, :push_dests, :remotes, keyword_init: true)
  UNRESOLVED = Facts.new(resolved: false, current: nil, default: nil, push_dests: [:current], remotes: nil)

  # Matched on the whole command, whatever the method: a merge.
  API_MERGE_PATTERNS = [
    %r{pulls/[^/\s]+/merge\b},
    %r{repos/[^/\s]+/[^/\s]+/merges\b},
    %r{repos/[^/\s]+/[^/\s]+/merge-upstream\b},
    /\b(?:mergePullRequest|enablePullRequestAutoMerge|enqueuePullRequest|mergeBranch)\b/,
    /\b(?:createCommitOnBranch|updateRefs?)\b/,
    %r{merge_requests/[^/\s]+/merge(?:_when_pipeline_succeeds)?\b},
    %r{merge_trains/merge_requests\b}
  ].freeze
  # Matched only with a write method or request fields: these routes are
  # read routinely, and only a write puts commits on a branch.
  API_WRITE_PATTERNS = [
    %r{/git/refs\b},
    %r{repos/[^/\s]+/[^/\s]+/contents/},
    %r{repository/(?:commits|files)\b}
  ].freeze
  WRITE_METHOD = /(?:-X|--method|--request)\s*=?\s*(?:POST|PUT|PATCH|DELETE)\b|\s(?:-f|-F|--field|--raw-field|--input|-d|--data)(?:\s|=|\z)/i

  GIT_VALUE_OPTS = %w[-c --git-dir --work-tree --namespace --super-prefix --config-env --exec-path].freeze
  REPO_MOVING_OPTS = %w[--git-dir --work-tree].freeze
  PUSH_CONFIG_KEYS = /\A(?:remote\..*\.push|remote\.pushdefault|push\.default|branch\..*\.(?:merge|pushremote|remote))=/i
  PUSH_VALUE_OPTS = %w[-o --push-option --receive-pack --exec --repo --prefix -P].freeze
  ARG_VALUE_OPTS = %w[-X -s --strategy --strategy-option --onto -m --message -F --file --into-name -x --exec
                      --depth -j --jobs -o --server-option --upload-pack --refmap --deepen --shallow-since
                      --shallow-exclude --negotiation-tip].freeze
  CLI_VALUE_OPTS = %w[-R --repo --hostname].freeze
  COMMAND_PREFIXES = %w[env timeout nice nohup command exec sudo time stdbuf test-slot --].freeze
  LOCAL_SUBS = %w[merge rebase cherry-pick reset pull].freeze
  ABORT_FLAGS = %w[--abort --quit --edit-todo --show-current-patch].freeze
  RESET_MODES = %w[--hard --soft --mixed --keep --merge].freeze

  module_function

  # The command as the shell reads it, one logical string: line continuations
  # joined, ${VAR} reduced to $VAR, backslash escapes and quote characters
  # removed (the shell joins `pu''sh` into `push`).
  def normalize(command)
    command.to_s.gsub(/\\\r?\n/, "").gsub(/\$\{(\w+)\}/, '$\1').gsub(/\\(.)/m, '\1').delete("\"'")
  end

  # segments(command) -> [[words, prev_sep, next_sep] | :open | :close, ...]:
  # the simple commands, split at every separator, with :open/:close where a
  # subshell (`(`, `$(`, backticks) starts and ends. Redirections are word
  # breaks; a standalone `{`/`}` is a separator.
  def segments(command)
    s = normalize(command).tr("<>", "  ")
    s = s.gsub(/`([^`]*)`/) { "\n(\n#{Regexp.last_match(1)}\n)\n" }.tr("`", "\n")
    s = s.gsub(/\$\(|\(/, "\n(\n").gsub(")", "\n)\n")
    s = s.gsub(/(?<=\A|\s|;)[{}](?=\z|\s|;)/, "\n")
    parts = s.split(/(&&|\|\||[;|&\n])/)
    out = []
    prev = nil
    parts.each_with_index do |part, i|
      next prev = part if i.odd?

      words = part.split
      next if words.empty?

      out << (words == ["("] ? :open : words == [")"] ? :close : [words, prev, parts[i + 1]])
    end
    out
  end

  # The directory a command with no `cd`/`-C` runs in. A subagent's Bash
  # resets to the session root on every call, which is the payload cwd. A
  # top-level session's Bash keeps an earlier call's `cd`, so for it (no
  # agent_id) the payload cwd is not where the command runs: :unresolved.
  def start_dir(cwd, agent_id)
    return :unresolved if agent_id.to_s.empty? || cwd.to_s.empty?

    cwd.to_s
  end

  def base(word)
    File.basename(word.to_s)
  end

  # classify_bash(command, dir, home) -> [Intent]. dir is start_dir's answer;
  # home expands `~`.
  def classify_bash(command, dir, home)
    flat = normalize(command)
    intents = api_intents(flat)
    stack = []
    segments(command).each do |seg|
      next stack.push(dir) if seg == :open
      next dir = stack.pop || dir if seg == :close

      words, prev_sep, next_sep = seg
      dir = moved_dir(words, dir, home, prev_sep, next_sep)
      intents.concat(cli_intents(words))
      intents.concat(git_intents(words, dir, home))
    end
    intents
  end

  def api_intents(flat)
    out = API_MERGE_PATTERNS.filter_map { |re| (m = flat.match(re)) && Intent.new(kind: :api_merge, text: m[0]) }
    if flat.match?(WRITE_METHOD)
      out.concat(API_WRITE_PATTERNS.filter_map { |re| (m = flat.match(re)) && Intent.new(kind: :api_merge, text: m[0]) })
    end
    out
  end

  # The directory after this segment. `cd`/`pushd` move it; a `cd` that may
  # not reach the next command (after `||`, in a pipeline, in the background)
  # and any `popd` leave it :unresolved.
  def moved_dir(words, dir, home, prev_sep, next_sep)
    return :unresolved if words[0] == "popd"
    return dir unless %w[cd pushd].include?(words[0])
    return :unresolved if ["||", "|"].include?(prev_sep) || ["|", "&"].include?(next_sep)

    target = words[1..].find { |w| !w.start_with?("-") }
    target.nil? ? home.to_s : join_dir(dir, target, home)
  end

  # Absolute, ~-expanded against home, relative to prev. A word holding a
  # variable, a glob or a brace is :unresolved, never a guess.
  def join_dir(prev, target, home)
    return :unresolved if target.empty? || target.match?(/[$*?{}\[]/)
    return File.join(home.to_s, target.delete_prefix("~")) if target == "~" || target.start_with?("~/")
    return target if target.start_with?("/")
    return :unresolved if prev == :unresolved

    File.join(prev.to_s, target)
  end

  def classify_mcp(tool_name)
    name = tool_name.to_s
    return [] unless name.start_with?("mcp__") && name.match?(/merge|enqueue/i)

    [Intent.new(kind: :mcp_merge, text: name)]
  end

  # An Agent/Task spawn of athena-admiral: an admiral a non-admiral spawns
  # could merge on its behalf.
  def classify_spawn(tool_input)
    type = tool_input.is_a?(Hash) ? tool_input["subagent_type"].to_s : ""
    type == ADMIRAL ? [Intent.new(kind: :spawn_admiral, text: "spawn #{ADMIRAL}")] : []
  end

  def cli_intents(words)
    out = []
    words.each_with_index do |w, i|
      b = base(w)
      out << Intent.new(kind: :cli_merge, text: "locked-merge") if b == "locked-merge"
      if %w[wt gt].include?(b) && words[i + 1] == "merge" && command_position?(words, i)
        out << Intent.new(kind: :wt_merge, text: "#{b} merge")
      end
      next unless %w[pr mr].include?(w)

      sub = next_subcommand(words, i + 1)
      out << Intent.new(kind: :cli_merge, text: "#{w} #{sub}") if sub == "merge" || (w == "mr" && sub == "accept")
    end
    out
  end

  # True when words[i] is where the shell finds the command: the first word,
  # or after assignments, a wrapper (env, timeout, ...) or a wrapper's number.
  def command_position?(words, i)
    words[0...i].all? { |w| w.include?("=") || COMMAND_PREFIXES.include?(base(w)) || w.match?(/\A[\d.]+[smhd]?\z/) || w.start_with?("-") }
  end

  # The first non-option word at or after index j. An option that takes a
  # separate value (-R owner/repo) skips that value too.
  def next_subcommand(words, j)
    while j < words.length
      w = words[j]
      return w unless w.start_with?("-")

      j += CLI_VALUE_OPTS.include?(w) ? 2 : 1
    end
    nil
  end

  # Every `git` invocation in the segment: global options, then the
  # subcommand. `gh-athena git ...` / `glab-athena git ...` find the same word.
  # --git-dir / --work-tree, or a GIT_DIR= / GIT_WORK_TREE= assignment before
  # the command, point git at another repo, so the directory is :unresolved.
  # A -c / GIT_CONFIG_* / --config-env that sets where a push goes, or xargs
  # feeding the arguments, leaves a push's destination unresolved.
  def git_intents(words, seg_dir, home)
    out = []
    words.each_with_index do |w, i|
      next unless base(w) == "git"

      prefix = words[0...i]
      dir = prefix.any? { |p| p.match?(/\AGIT_(?:DIR|WORK_TREE)=/) } ? :unresolved : seg_dir
      cfg = prefix.any? { |p| p.start_with?("GIT_CONFIG_") || base(p) == "xargs" }
      j = i + 1
      while j < words.length && words[j].start_with?("-")
        opt = words[j]
        dir = join_dir(dir, words[j + 1].to_s, home) if opt == "-C"
        dir = :unresolved if REPO_MOVING_OPTS.any? { |o| opt == o || opt.start_with?(o + "=") }
        cfg ||= opt == "-c" && words[j + 1].to_s.match?(PUSH_CONFIG_KEYS)
        cfg ||= opt == "--config-env" || opt.start_with?("--config-env=")
        j += opt == "-C" || GIT_VALUE_OPTS.include?(opt) ? 2 : 1
      end
      out.concat(git_sub_intents(words[j], words[(j + 1)..] || [], dir, cfg)) if words[j]
    end
    out
  end

  def git_sub_intents(sub, args, dir, cfg)
    case sub
    when "push", "send-pack" then [push_intent(args, dir, cfg)].compact
    when "subtree" then args[0] == "push" ? [push_intent(args[1..], dir, cfg)].compact : []
    when *LOCAL_SUBS then local_intents(sub, args, dir)
    when "update-ref" then update_ref_intents(args, dir)
    when "branch" then branch_intents(args, dir)
    when "checkout", "switch" then create_force_intents(sub, args, dir)
    when "fetch" then fetch_intents(args, dir)
    else []
    end
  end

  def local_intents(sub, args, dir)
    return [] if args.any? { |a| ABORT_FLAGS.include?(a) }
    return [] if sub == "reset" && !reset_moves_branch?(args)

    pos = positionals(args)
    out = [Intent.new(kind: :local, text: "git " + sub, dir: dir, sub: sub, args: pos)]
    # `git rebase <upstream> <branch>` switches to <branch> and rebases it.
    out << force(dir, "git rebase <upstream> <branch>", [branch_name(pos[1])]) if sub == "rebase" && pos[1]
    out
  end

  # `git reset` moves the branch with a mode flag or a commit argument; a bare
  # `git reset` or `git reset -- <path>` does not.
  def reset_moves_branch?(args)
    return true if args.any? { |a| RESET_MODES.include?(a) }

    args.take_while { |a| a != "--" }.any? { |a| !a.start_with?("-") }
  end

  # The non-option words before `--`, skipping the values of the options in
  # ARG_VALUE_OPTS when written apart (-X theirs).
  def positionals(args)
    out = []
    skip = false
    args.each do |a|
      break if a == "--"
      next skip = false if skip

      if a.start_with?("-")
        skip = ARG_VALUE_OPTS.include?(a)
      else
        out << a
      end
    end
    out
  end

  def force(dir, text, dests, sub: nil)
    Intent.new(kind: :force_ref, text: text, dests: dests, dir: dir, sub: sub)
  end

  # A branch name as written in a ref argument: refs/heads/x and heads/x are
  # x; HEAD/@ is :current; a variable, glob or brace is :unresolved; any other
  # refs/... (a tag, a remote-tracking ref) is nil.
  def branch_name(ref)
    r = ref.to_s.delete_prefix("+")
    return :unresolved if r.empty? || r.match?(/[$*?{}\[]/)
    return :current if %w[HEAD @].include?(r)
    return r.sub(%r{\A(?:refs/)?heads/}, "") if r.match?(%r{\A(?:refs/)?heads/})
    return nil if r.start_with?("refs/")

    r
  end

  def update_ref_intents(args, dir)
    return [force(dir, "git update-ref --stdin", [:unresolved], sub: "update-ref")] if args.include?("--stdin")

    name = branch_name(positionals(args).first)
    name.nil? ? [] : [force(dir, "git update-ref", [name], sub: "update-ref")]
  end

  def branch_intents(args, dir)
    flags = args.take_while { |a| a != "--" }.select { |a| a.start_with?("-") }
    moved = flags.any? { |a| a.match?(/\A-[a-zA-Z]*[MC][a-zA-Z]*\z/) }
    forced = moved || flags.any? { |a| a == "--force" || a.match?(/\A-[a-zA-Z]*f[a-zA-Z]*\z/) }
    names = positionals(args)
    return [] unless forced && !names.empty?

    # -M/-C <old> <new> writes <new>; -f <name> [<start>] writes <name>.
    target = branch_name(moved ? names.last : names.first)
    target.nil? ? [] : [force(dir, "git branch (forced)", [target])]
  end

  def create_force_intents(sub, args, dir)
    flags = sub == "checkout" ? %w[-B] : %w[-C --force-create]
    i = args.index { |a| flags.include?(a) }
    return [] if i.nil? || args[i + 1].nil?

    name = branch_name(args[i + 1])
    name.nil? ? [] : [force(dir, "git " + sub + " " + args[i], [name])]
  end

  # `git fetch <remote> <src>:<dst>` writes the local branch <dst>.
  def fetch_intents(args, dir)
    dests = positionals(args)[1..].to_a.select { |r| r.include?(":") }.map { |r| fetch_dest(r) }.compact
    dests.empty? ? [] : [force(dir, "git fetch <src>:<dst>", dests)]
  end

  def fetch_dest(refspec)
    dst = refspec.delete_prefix("+").split(":", 2)[1].to_s
    return :unresolved if dst.match?(/[$*?{}\[]/)
    return dst.sub(%r{\A(?:refs/)?heads/}, "") if dst.match?(%r{\A(?:refs/)?heads/})
    return nil if dst.empty? || dst.start_with?("refs/")

    dst
  end

  def push_intent(args, dir, cfg)
    pos = []
    all = false
    remote_opt = nil
    skip = nil
    ended = false
    return nil if push_help?(args)

    args.each do |a|
      if skip
        remote_opt = a if skip == "--repo"
        skip = nil
      elsif !ended && a == "--"
        ended = true
      elsif !ended && a.start_with?("-")
        all = true if %w[--all --mirror --branches].include?(a)
        remote_opt = a.split("=", 2)[1] if a.start_with?("--repo=")
        skip = a if PUSH_VALUE_OPTS.include?(a)
      else
        pos << a
      end
    end
    remote = remote_opt || pos.shift
    dests = pos.map { |r| refspec_dest(r) }.compact
    Intent.new(kind: :push, text: "git push", dir: dir, remote: remote, dests: dests, all: all, args: pos,
               cfg_unresolved: cfg)
  end

  # `git push -h` / `--help` as the FIRST argument prints usage and exits before
  # it reads a remote or sends a ref. Stricter than git, on purpose: git also
  # reads help after other options, but git accepts abbreviated long options
  # (`--push-op -h` makes -h a value), so help behind any other word is checked.
  def push_help?(args)
    %w[-h --help].include?(args.first)
  end

  # The branch a push refspec writes on the remote: :current for HEAD/@, the
  # name after `:` (or the name itself), :unresolved for a variable, glob,
  # brace or an empty destination after a source, nil for a non-branch ref.
  def refspec_dest(refspec)
    r = refspec.delete_prefix("+")
    return branch_name(r) unless r.include?(":")

    src, dst = r.split(":", 2)
    return :unresolved if dst.empty? && !src.empty?

    branch_name(dst)
  end

  def protected_set(facts)
    default = facts.default.is_a?(String) ? [facts.default] : []
    (ALWAYS_PROTECTED + default).uniq
  end

  # The key MergeRoleIO stores an intent's facts under.
  def facts_key(it)
    [it.dir, it.remote]
  end

  # findings(intents, facts_by_key) -> [{rule:, text:, target:, unresolved:,
  # dir:}] for the intents that are merge-class once the facts are known.
  def findings(intents, facts_by_key)
    intents.filter_map { |it| finding(it, facts_by_key.fetch(facts_key(it), UNRESOLVED)) }
  end

  def finding(it, facts)
    case it.kind
    when :cli_merge, :api_merge, :wt_merge, :mcp_merge, :spawn_admiral then found(it, "the target branch")
    when :force_ref then force_ref_finding(it, facts)
    when :push then push_finding(it, facts)
    when :local then local_finding(it, facts)
    end
  end

  # A ref update in a resolved work tree whose repo has no remote at all lands
  # on no forge's main: scratch work. Only update-ref. A repo with remotes,
  # whose remotes could not be read, or that is not a work tree (a bare origin)
  # keeps the full check; "no remote" is never read from a failed lookup.
  def force_ref_finding(it, facts)
    return nil if it.sub == "update-ref" && facts.resolved && facts.remotes == []

    dests_finding(it, facts, it.dests, "the branch it writes")
  end

  def push_finding(it, facts)
    return found(it, "every branch (--all/--mirror)") if it.all
    return unresolved(it, "where this push goes (config, GIT_CONFIG_* or xargs sets it)") if it.cfg_unresolved

    dests = it.dests.empty? ? facts.push_dests || [:current] : it.dests
    dests_finding(it, facts, dests, "the push destination")
  end

  def dests_finding(it, facts, dests, what)
    prot = protected_set(facts)
    dests.each do |d|
      case d
      when :all then return found(it, "every matching branch (push.default=matching)")
      when :unresolved then return unresolved(it, what)
      when :current
        return unresolved(it, "the current branch of " + dir_label(it.dir)) unless facts.resolved

        hit = branch_finding(it, facts, prot, facts.current)
        return hit if hit
      else
        hit = branch_finding(it, facts, prot, d)
        return hit if hit
      end
    end
    nil
  end

  # A named branch is a landing when it is protected; when the repo, or its
  # default branch, is unknown, a name outside main/master cannot be ruled
  # out (the default may be `trunk`), so it is unresolved.
  def branch_finding(it, facts, prot, name)
    return found(it, name) if prot.include?(name)
    return nil if name.to_s.empty? # a detached HEAD is no branch
    return unresolved(it, "the default branch of " + dir_label(it.dir)) unless facts.resolved
    return unresolved(it, DEFAULT_UNKNOWN) if facts.default == :unknown

    nil
  end

  DEFAULT_UNKNOWN = "the remote's default branch (refs/remotes/<remote>/HEAD is missing; " \
                    "`git remote set-head origin --auto` records it)"

  def local_finding(it, facts)
    return unresolved(it, "the current branch of " + dir_label(it.dir)) unless facts.resolved
    return nil if it.sub == "pull" && pull_is_sync?(it.args, facts.current)

    branch_finding(it, facts, protected_set(facts), facts.current)
  end

  # `git pull`, `git pull origin` and `git pull origin <current>` only sync the
  # protected branch with its own remote copy; anything else merges into it.
  def pull_is_sync?(args, current)
    return true if args.empty?
    return false unless args[0] == "origin"

    args[1..].all? { |r| [current, "refs/heads/" + current].include?(r) }
  end

  def found(it, target)
    { rule: it.kind, text: it.text, target: target, unresolved: nil, dir: it.dir }
  end

  def unresolved(it, what)
    { rule: it.kind, text: it.text, target: "a branch it could not resolve", unresolved: what, dir: it.dir }
  end

  def dir_label(dir)
    dir == :unresolved ? "a directory it could not resolve (a variable, glob, subshell or earlier cd)" : dir.to_s
  end

  # attended?(entrypoint, attended) -> true only when Claude Code's own mode
  # variables both say an attended interactive session: CLAUDE_CODE_ENTRYPOINT
  # exactly "cli" and CLAUDE_CODE_SESSION_ATTENDED exactly "1" (DND-1934).
  # Measured on Claude Code 2.1.286 in a PreToolUse hook's own environment:
  # interactive `claude [--agent X]` gives cli + 1 (its subagents inherit
  # it); `claude -p [--agent X]` gives sdk-cli + 0, and overwrites both an
  # inherited cli + 1 and a cli + 1 set in a `--settings` env block. Anything
  # else, a missing value, half the signal or a contradiction, cannot tell:
  # false. The same two-signal test is inbox_wait_mode in
  # ai/skills/athena:inbox/lib/budget.sh; a change to these variables sweeps
  # both.
  def attended?(entrypoint, attended)
    entrypoint.to_s == "cli" && attended.to_s == "1"
  end

  # top_level?(agent_id, agent_type, mode) -> true for a session no subagent
  # runs in. Either it carries neither field (a plain session: the human, the
  # coordinator, a cron runner's parent), or it carries an agent_type, NO
  # agent_id key at all, and mode says attended (an interactive `claude
  # --agent X` with a person at it, the fleet launcher's default being
  # `--agent claude`). A headless `claude -p --agent X` carries that same
  # payload, so without the attended signal it is NOT top level: it keeps its
  # DND-726 verdict. mode is {entrypoint:, attended:}, the raw variable values
  # (nil when unset). Every merge class uses this one test (decide).
  def top_level?(agent_id, agent_type, mode)
    return true if agent_id.to_s.empty? && agent_type.to_s.empty?

    agent_id.nil? && attended?(mode[:entrypoint], mode[:attended])
  end

  # decide(found, agent_id:, agent_type:, mode:, lane_of:) -> nil (allow) or
  # {role:, finding:, mode_seen:} (deny). mode is top_level?'s. mode_seen is
  # set when the caller has the top-level `--agent X` shape (an agent_type, no
  # agent_id) and was read as headless, so the reason can name what the guard
  # saw. lane_of.call(dir) is true when dir is a cron lane of the hook's own
  # repo.
  def decide(found, agent_id:, agent_type:, mode:, lane_of:)
    return nil if found.empty?

    type = agent_type.to_s
    return nil if top_level?(agent_id, type, mode)
    return nil if type == ADMIRAL
    return nil if type == SHIPWRIGHT && shipwright_lane_push?(found, lane_of)

    verdict = { role: type.empty? ? :unknown : type, finding: found.first }
    verdict[:mode_seen] = mode_seen(mode) if agent_id.to_s.empty? && !type.empty?
    verdict
  end

  # mode_seen(mode) -> "CLAUDE_CODE_ENTRYPOINT=<v>, CLAUDE_CODE_SESSION_ATTENDED=<v>",
  # <unset> for a missing value: what the attended test read.
  def mode_seen(mode)
    show = ->(v) { v.nil? ? "<unset>" : v.to_s }
    "CLAUDE_CODE_ENTRYPOINT=#{show.call(mode[:entrypoint])}, " \
      "CLAUDE_CODE_SESSION_ATTENDED=#{show.call(mode[:attended])}"
  end

  # The cron shipwright's documented landing: `push origin HEAD:main` from its
  # own lane. Every finding must be that, resolved, from a lane.
  def shipwright_lane_push?(found, lane_of)
    found.all? { |f| f[:rule] == :push && f[:unresolved].nil? && lane_of.call(f[:dir]) }
  end

  FIX_TAIL = "Fix: do not merge. Leave the PR/MR open and green, write your report with the head SHA, " \
             "and report DONE to your admiral; merging is its step (athena:merge-boarding -> The merge bar). " \
             "If this command only MENTIONS a merge (a heredoc, a commit message, a grep), write the text with " \
             "the Write tool and pass it by file (`git commit -F <file>`, `grep -f <file>`); never rephrase a " \
             "real merge to slip past this guard. If you ARE the admiral and see this, your agent_type was not " \
             "recognised: stop and escalate with this message; do not work around it."

  # deny_reason(verdict) -> the deny text, with the mode note when the caller
  # had the top-level `--agent X` shape and was read as headless: a person at
  # an interactive session whose mode variables did not read cli + 1 sees what
  # the guard saw, instead of advice meant for a subagent.
  def deny_reason(verdict)
    base = role_reason(verdict)
    return base unless verdict[:mode_seen]

    "#{base} This call has an agent_type and no agent_id, the shape of a headless `claude -p --agent X`, " \
      "and the session-mode variables did not both say attended (seen #{verdict[:mode_seen]}; attended is " \
      "cli and 1). Fix, if a person is attending this interactive session: stop and escalate with this " \
      "message; do not work around it."
  end

  def role_reason(verdict)
    f = verdict[:finding]
    role = verdict[:role]
    if role == :unknown
      return "merge-role-guard: could not tell the caller's role: the hook input has an agent_id but an empty " \
             "agent_type, and this call merges, lands or spawns an admiral (#{f[:text]}). Only athena-admiral " \
             "merges, so an unidentified subagent is refused. #{FIX_TAIL}"
    end
    if f[:rule] == :spawn_admiral
      return "merge-role-guard: `#{role}` may not spawn athena-admiral: an admiral it spawns could merge on " \
             "its behalf, and only a top-level session (a plain or attended interactive one, never a subagent " \
             "or a headless `claude -p --agent X`) or an admiral starts an admiral. Fix: do not spawn an " \
             "admiral; finish your own work and report to whoever launched you. If a merge is needed, say so " \
             "in your report; the admiral merges."
    end
    if f[:unresolved]
      return "merge-role-guard: `#{role}` ran #{f[:text]}, and the guard could not tell #{f[:unresolved]}, " \
             "so it cannot rule out landing on a protected branch; an unresolved key never reads as \"not " \
             "main\". Only athena-admiral merges or lands. If this is not a landing, re-run it with the repo as " \
             "a literal absolute `cd <dir> &&` or `git -C <dir>`, no --git-dir/GIT_DIR, and an explicit " \
             "literal refspec naming your feature branch. #{FIX_TAIL}"
    end
    "merge-role-guard: `#{role}` may not merge or land onto #{f[:target]} (#{f[:text]}); only " \
      "athena-admiral merges (athena:merge-boarding -> The merge bar), after integration-gate passes (exit 4 " \
      "needs the owner's go). #{FIX_TAIL}"
  end
end
