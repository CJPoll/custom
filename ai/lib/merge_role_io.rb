# frozen_string_literal: true

# merge_role_io -- the SIDE EFFECTS and the MANAGER of
# ai/hooks/merge-role-guard.sh (DND-726). The rules live in ai/lib/merge_role.rb
# (pure); this file reads the hook payload, resolves the git facts the rules
# need (read-only git calls), appends each deny to the deny log, and prints the
# PreToolUse decision.
#
# Fail-open: anything it cannot evaluate (stdin that is not a JSON object, a
# tool it does not handle, an exception) prints nothing and exits 0, so a
# fault here never wedges a session's Bash. A crash is still written to the
# log, because hook stderr on exit 0 reaches nobody (DND-433). A deny is only
# ever emitted for a positive merge-class match by a role the allow-list does
# not name.

require "json"
require "open3"
require "time"
require "fileutils"
require_relative "merge_role"

module MergeRoleIO
  LANE_DIRS = %w[shipwright-lanes leadtime-lanes].freeze

  module_function

  def log_path
    state = ENV.fetch("XDG_STATE_HOME", "")
    state = File.join(Dir.home, ".local", "state") if state.empty?
    File.join(state, "athena", "merge-role-guard.log")
  end

  def log(fields)
    path = log_path
    FileUtils.mkdir_p(File.dirname(path))
    line = ([Time.now.utc.iso8601] + fields).map { |x| x.to_s.tr("\t\n", "  ") }.join("\t")
    File.open(path, "a", 0o600) { |f| f.puts(line) }
  rescue StandardError
    nil
  end

  # mask(text) -> text with credentials replaced by ***: an Authorization /
  # PRIVATE-TOKEN / JOB-TOKEN header value, a GitHub or GitLab token, and a
  # token=/password=/secret= value. The deny log keeps the command for a live
  # verify; it never keeps a secret the command carried. A GitLab token runs
  # through its '.' segments (routable tokens are dot-segmented, DND-1982) and
  # ends on a non-'.', so a sentence's trailing period stays
  # (athena-machine-secrets.md -> Credential patterns).
  def mask(text)
    text.to_s
        .gsub(/((?:Authorization|PRIVATE-TOKEN|JOB-TOKEN)\s*:\s*)(?:(?:token|bearer|basic)\s+)?\S+/i, '\1***')
        .gsub(/\b(?:gh[pousr]_|github_pat_)[A-Za-z0-9_-]+/, "***")
        .gsub(/\b(?:glpat-|glrt-)[A-Za-z0-9_.-]*[A-Za-z0-9_-]/, "***")
        .gsub(/((?:token|password|secret|passwd)=)[^\s&]+/i, '\1***')
  end

  # git(dir, *args) -> stdout stripped, or nil on any failure. Read-only calls
  # only; GIT_OPTIONAL_LOCKS=0 so a status-like read never takes the index lock.
  def git(dir, *args)
    out, status = Open3.capture2({ "GIT_OPTIONAL_LOCKS" => "0" }, "git", "-C", dir, *args, err: File::NULL)
    status.success? ? out.strip : nil
  rescue StandardError
    nil
  end

  def realpath(path)
    File.realpath(path)
  rescue StandardError
    nil
  end

  # facts_for(dir, remote) -> MergeRole::Facts. A dir that does not exist or is
  # not a git work tree is unresolved; a detached HEAD resolves to "".
  def facts_for(dir, remote)
    return MergeRole::UNRESOLVED if dir == :unresolved || !File.directory?(dir.to_s)
    return MergeRole::UNRESOLVED unless git(dir, "rev-parse", "--is-inside-work-tree") == "true"

    current = git(dir, "symbolic-ref", "-q", "--short", "HEAD") || ""
    r = remote.to_s.match?(/\A[\w.-]+\z/) ? remote : "origin"
    head = git(dir, "symbolic-ref", "-q", "--short", "refs/remotes/#{r}/HEAD")
    # A missing remote HEAD is an unknown default, never "no default".
    default = head.nil? || head.empty? ? :unknown : head.delete_prefix("#{r}/")
    MergeRole::Facts.new(resolved: true, current: current, default: default,
                         push_dests: push_dests(dir, r, current), remotes: remotes(dir))
  end

  # The repo's remote names: [] only when `git remote` ran and printed none,
  # nil when it failed (a failed read is never "no remote"), and nil for a repo
  # whose shared config says bare: a linked worktree of a bare origin is not
  # scratch work.
  def remotes(dir)
    return nil unless git(dir, "config", "--bool", "--get", "core.bare").to_s != "true"

    git(dir, "remote")&.split
  end

  # Where `git push [<remote>]` with no refspec sends commits, from config:
  # remote.<r>.push refspecs, else push.default (matching: every matching
  # branch; upstream/tracking: branch.<cur>.merge; otherwise the current
  # branch). A configured destination is the one checked, never assumed away.
  def push_dests(dir, remote, current)
    configured = git(dir, "config", "--get-all", "remote.#{remote}.push")
    return configured.lines.map { |l| MergeRole.refspec_dest(l.strip) }.compact if configured && !configured.empty?

    case git(dir, "config", "--get", "push.default").to_s.downcase
    when "matching" then [:all]
    when "upstream", "tracking"
      merge = current.empty? ? nil : git(dir, "config", "--get", "branch.#{current}.merge")
      merge ? [MergeRole.branch_name(merge)].compact : [:unresolved]
    else [:current]
    end
  end

  # home_common(hook_dir) -> the realpath of the git common dir of the repo the
  # hook itself lives in (~/dev/custom/.git in production), or nil.
  def home_common(hook_dir)
    c = git(hook_dir, "rev-parse", "--path-format=absolute", "--git-common-dir")
    c && realpath(c)
  end

  # lane?(dir, home) -> true when dir is the top of a linked worktree at
  # <home common dir>/{shipwright,leadtime}-lanes/<run-...> AND git agrees that
  # its common dir is that home repo's. A product repo's lead-time lane, or a
  # look-alike path elsewhere, is not a lane of the hook's repo.
  def lane?(dir, home)
    return false if home.nil? || dir == :unresolved

    top = git(dir.to_s, "rev-parse", "--show-toplevel")
    top = top && realpath(top)
    return false if top.nil?
    return false unless LANE_DIRS.any? { |d| File.dirname(top) == File.join(home, d) }
    return false unless File.basename(top).start_with?("run-")

    common = git(dir.to_s, "rev-parse", "--path-format=absolute", "--git-common-dir")
    !common.nil? && realpath(common) == home
  end

  def deny_json(reason)
    JSON.generate(hookSpecificOutput: { hookEventName: "PreToolUse", permissionDecision: "deny",
                                        permissionDecisionReason: reason })
  end

  # main(stdin, hook_dir) -> the string to print ("" to allow silently).
  def main(stdin, hook_dir)
    payload = JSON.parse(stdin)
    return "" unless payload.is_a?(Hash)

    judge(payload, hook_dir)
  rescue JSON::ParserError
    ""
  rescue StandardError => e
    log(["crashed", "", "", "", "#{e.class}: #{e.message}"[0, 200]])
    ""
  end

  def judge(payload, hook_dir)
    tool = payload["tool_name"].to_s
    intents = classify(tool, payload)
    return "" if intents.empty?

    facts = {}
    intents.each do |it|
      next if it.dir.nil?

      facts[MergeRole.facts_key(it)] ||= facts_for(it.dir, it.remote)
    end
    found = MergeRole.findings(intents, facts)
    home = nil
    lane_of = lambda do |dir|
      home ||= home_common(hook_dir) || :none
      home != :none && lane?(dir, home)
    end
    verdict = MergeRole.decide(found, agent_id: payload["agent_id"], agent_type: payload["agent_type"],
                                      lane_of: lane_of)
    return "" if verdict.nil?

    f = verdict[:finding]
    log(["deny", payload["session_id"], payload["agent_id"], payload["agent_type"],
         "#{f[:rule]}: #{f[:text]} -> #{f[:target]}",
         mask(tool == "Bash" ? payload.dig("tool_input", "command").to_s : tool)[0, 200]])
    deny_json(MergeRole.deny_reason(verdict))
  end

  def classify(tool, payload)
    case tool
    when "Bash"
      dir = MergeRole.start_dir(payload["cwd"], payload["agent_id"])
      MergeRole.classify_bash(payload.dig("tool_input", "command").to_s, dir, Dir.home)
    when "Agent", "Task" then MergeRole.classify_spawn(payload["tool_input"])
    else tool.start_with?("mcp__") ? MergeRole.classify_mcp(tool) : []
    end
  end
end

if $PROGRAM_NAME == __FILE__
  hook_dir = ARGV[0].to_s
  out = MergeRoleIO.main($stdin.read, hook_dir)
  puts out unless out.empty?
  exit 0
end
