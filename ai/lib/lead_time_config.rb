# frozen_string_literal: true

# lead_time_config -- the DOMAIN of the lead-time repo list (DND-1526): where
# the list is read from, its schema, whether each configured repo is checked
# out on this machine, and the resolved result. Pure: every input arrives as a
# value (an env hash, FileFacts, a Probe per repo). The IO that gathers those
# values is ai/lib/lead_time_config_io.rb; the one CLI is ai/bin/lead-time-repos.
#
# Discovery (the private-overlay contract's *Discovery* shape):
#   1. ATHENA_LEADTIME_CONFIG set, even empty: authoritative. An absolute path
#      to a valid file, or an error. Never a fall-through.
#   2. Else ${XDG_CONFIG_HOME:-$HOME/.config}/athena/lead-time-repos.json.
#      Absent: the tracked ai/config/lead-time-repos.json (source=default).
#      Present: its repo list, window and epic replace the tracked file's
#      (source=override), and each repo entry it lists inherits every optional
#      key (REPO_OPTIONAL) the tracked default declares for the same repo name
#      and the entry omits (DND-1672). The entry's own keys win; a repo the
#      override drops stays dropped. ATHENA_LEADTIME_CONFIG inherits nothing:
#      it is authoritative.
#   3. An override that cannot be stat'd, is not a regular file, is not owned
#      by this user, or is group/other-writable is an error, never "no
#      override".
#   4. HOME unset, empty or relative with no env path is an error.
#
# Presence (~/.claude/CLAUDE.md -> *A failed lookup must never look like an
# empty one*): a configured path that does not exist is SKIPPED, by name, and
# counted. A path that exists but is not a git repository's top, or whose main
# checkout's basename (the telemetry repo label) is not the repo's name, is an
# error. Zero repos left is NoRepos.
#
# Every error carries the message and a Fix: the caller prints.

require "json"
require_relative "gitlab_pipeline_selector"

module LeadTimeConfig
  MODES = %w[improve watch].freeze
  ENV_PATH = "ATHENA_LEADTIME_CONFIG"
  RETIRED_ENV = "LEAD_TIME_PHASES_CONFIG"
  OVERRIDE_REL = "athena/lead-time-repos.json"
  TOP_KEYS = %w[repos window improvement_epic].freeze
  REPO_KEYS = %w[name path mode].freeze
  REPO_OPTIONAL = %w[product_epic idle_workflow].freeze
  NAME_RE = /\A[A-Za-z0-9][A-Za-z0-9_.-]*\z/.freeze
  # idle_workflow (DND-1540): the repo's post-merge CI. On GitHub, the
  # post-merge workflow FILE a product-repo landing passes to locked-merge
  # --require-idle-workflow; on GitLab, an idle pipeline selector
  # (ai/lib/gitlab_pipeline_selector.rb, DND-1952); or "none". The accepted
  # values have one home, idle_workflow_kind.
  IDLE_WORKFLOW_RE = /\A(none|[A-Za-z0-9][A-Za-z0-9_.-]*\.ya?ml)\z/.freeze
  SCHEMA_HINT = "repos: [{name, path, mode improve|watch, optional product_epic, idle_workflow (required for improve)}], window, improvement_epic"

  # A refusal: message plus the Fix: line the caller prints.
  class Error < StandardError
    attr_reader :fix

    def initialize(message, fix)
      super(message)
      @fix = fix
    end
  end

  # A --repo that is not in the resolved config at all.
  class NotConfigured < Error; end
  # A --repo that is configured but not checked out on this machine.
  class Skipped < Error; end
  # Every configured repo was skipped.
  class NoRepos < Error; end
  # The IO side could not look (a file it could not read, git that could not
  # run): never "absent", never "not on this machine".
  class CouldNotLook < Error; end
  # A change repo (DND-1528) whose path cannot be resolved: not configured and
  # not the runner's own repo, or configured but skipped on this machine.
  class Unresolved < Error; end

  # The runner's own repo (DND-1528): the main checkout of the repo this code
  # runs from, found from its git common dir. path and label are nil when it
  # could not be found; error then says why.
  OwnRepo = Struct.new(:path, :label, :error, keyword_init: true)

  # inherited: the optional keys this entry took from the tracked default
  # (DND-1672), in REPO_OPTIONAL order; empty when it inherited nothing.
  Repo = Struct.new(:name, :path, :mode, :product_epic, :product_epic_source, :idle_workflow, :inherited,
                    keyword_init: true) do
    def to_h = { "name" => name, "path" => path, "mode" => mode, "product_epic" => product_epic,
                 "product_epic_source" => product_epic_source, "idle_workflow" => idle_workflow,
                 "inherited" => inherited || [] }
  end
  # inherits_from: the Inheritance's path when parse was given one, else nil.
  Parsed = Struct.new(:repos, :window, :improvement_epic, :inherits_from, keyword_init: true)
  # kind: :env (ATHENA_LEADTIME_CONFIG) | :xdg (the per-user override path)
  Candidate = Struct.new(:kind, :path, keyword_init: true)
  # What the IO side saw at a candidate path. present: lstat found an entry.
  # stat_error: set when it is present but stat (following links) failed.
  FileFacts = Struct.new(:present, :regular, :uid, :mode, :stat_error, keyword_init: true)
  # inherits: true for the per-user override only; its repo entries then
  # inherit from the tracked default (DND-1672).
  Location = Struct.new(:path, :source, :inherits, keyword_init: true)
  # The tracked default as an inheritance source (DND-1672): its path, and per
  # repo name the optional keys it declares, as written.
  Inheritance = Struct.new(:path, :entries, keyword_init: true)
  # What the IO side saw at a repo's path. exists follows symlinks; symlink is
  # lstat's answer. git_error is set when `git rev-parse` refused.
  Probe = Struct.new(:path, :exists, :symlink, :directory, :realpath, :git_error, :toplevel, :common_dir,
                     keyword_init: true)
  Skip = Struct.new(:name, :path, :reason, keyword_init: true) do
    def to_h = { "name" => name, "path" => path, "reason" => reason }
  end

  # inherits_from: the tracked default's path when the source is the per-user
  # override (the file its entries inherit from, whether or not any key came
  # across), else nil.
  Resolution = Struct.new(:source, :path, :inherits_from, :window, :improvement_epic, :repos, :skipped, :considered,
                          keyword_init: true) do
    # -> the Repo; raises Skipped (configured, not here) or NotConfigured.
    def find(name)
      hit = repos.find { |r| r.name == name }
      return hit if hit

      skip = skipped.find { |s| s.name == name }
      if skip
        raise Skipped.new("#{name}: skipped on this machine: #{skip.reason}",
                          "check out #{name} at #{skip.path}, or drop it from #{path}")
      end

      raise NotConfigured.new("no repo #{name.inspect} in #{path} (configured: #{(repos + skipped).map(&:name).join(', ')})",
                              "pass one of the configured repos, or add #{name} to #{path}")
    end

    # -> the path of a CHANGE repo (DND-1528): the repo a change landed in,
    # which need not be a measured repo. own: an OwnRepo.
    #   1. configured and present: its configured path (validated as that
    #      checkout by presence);
    #   2. the runner's own repo (own.label == name): its main checkout, so the
    #      harness repo resolves on a machine that does not configure it;
    #   3. otherwise refused: Unresolved (skipped here, or neither configured
    #      nor own), or CouldNotLook when own could not be looked at, since
    #      then the name may well be the runner's own repo.
    def path_for(name, own)
      raise Unresolved.new("an empty repo name resolves to nothing", "pass a repo name") if name.to_s.empty?

      hit = repos.find { |r| r.name == name }
      return hit.path if hit
      return own.path if own.path && own.label == name

      skip = skipped.find { |s| s.name == name }
      if skip
        raise Unresolved.new("#{name}: skipped on this machine: #{skip.reason}",
                             "check out #{name} at #{skip.path}, or drop it from #{path}")
      end
      unless own.path
        raise CouldNotLook.new("#{name} is not configured in #{path}, and the runner's own repo could not be " \
                               "resolved (#{own.error}), so #{name} cannot be checked against it",
                               "run from a checkout of the harness repo (git rev-parse --git-common-dir must work there), " \
                               "or add #{name} to #{path}")
      end

      configured = (repos + skipped).map(&:name).join(", ")
      raise Unresolved.new("no repo #{name.inspect}: not in #{path} (configured: #{configured}) and not the runner's " \
                           "own repo (#{own.label} at #{own.path})",
                           "pass #{own.label} or a configured repo, or add #{name} to #{path}")
    end

    def require_any!
      return self unless repos.empty?

      raise NoRepos.new("no configured repo is checked out on this machine (#{considered} considered, " \
                        "#{skipped.size} skipped: #{skipped.map(&:name).join(', ')}; config #{path})",
                        "check out a configured repo, or write an override at " \
                        "${XDG_CONFIG_HOME:-~/.config}/#{OVERRIDE_REL} listing the repos this machine has")
    end

    def to_h
      { "source" => source, "path" => path, "inherits_from" => inherits_from, "window" => window,
        "improvement_epic" => improvement_epic, "repos" => repos.map(&:to_h), "skipped" => skipped.map(&:to_h), "considered" => considered }
    end
  end

  module_function

  # ── discovery ─────────────────────────────────────────────────────────────

  # -> Candidate, or raises Error. env: a Hash of the process environment.
  def candidate(env)
    if env.key?(RETIRED_ENV)
      raise Error.new("#{RETIRED_ENV} is retired (DND-1526) and is not read",
                      "set #{ENV_PATH} to the config file instead, and unset #{RETIRED_ENV}")
    end
    return env_candidate(env[ENV_PATH].to_s) if env.key?(ENV_PATH)

    base = env["XDG_CONFIG_HOME"].to_s
    if base.empty?
      home = env["HOME"].to_s
      unless home.start_with?("/")
        raise Error.new("HOME is #{home.empty? ? 'unset or empty' : "relative (#{home.inspect})"}, so the override path cannot be computed",
                        "set HOME to an absolute path, or set #{ENV_PATH} to the config file")
      end
      base = File.join(home, ".config")
    elsif !base.start_with?("/")
      raise Error.new("XDG_CONFIG_HOME is relative (#{base.inspect}), so the override path cannot be computed",
                      "set XDG_CONFIG_HOME to an absolute path, or unset it")
    end
    Candidate.new(kind: :xdg, path: File.join(base, OVERRIDE_REL))
  end

  def env_candidate(path)
    if path.empty?
      raise Error.new("#{ENV_PATH} is set but empty", "unset #{ENV_PATH}, or set it to the absolute path of a config file")
    end
    unless path.start_with?("/")
      raise Error.new("#{ENV_PATH}=#{path.inspect} is not an absolute path", "set #{ENV_PATH} to an absolute path, or unset it")
    end

    Candidate.new(kind: :env, path: path)
  end

  # -> Location, or raises Error. facts: FileFacts at candidate.path.
  def locate(candidate, facts, tracked:, euid:)
    unless facts.present
      return Location.new(path: tracked, source: "default", inherits: false) if candidate.kind == :xdg

      raise Error.new("#{ENV_PATH}=#{candidate.path} does not exist", "point #{ENV_PATH} at an existing config file, or unset it")
    end

    where = candidate.kind == :env ? "#{ENV_PATH}=#{candidate.path}" : "the override #{candidate.path}"
    remedy = candidate.kind == :env ? "or unset #{ENV_PATH}" : "or remove it to use the tracked default"
    if facts.stat_error
      raise Error.new("#{where} exists but cannot be read (#{facts.stat_error}; a dangling link?)",
                      "repair or remove #{candidate.path}; an unreadable override is never read as 'no override'")
    end
    raise Error.new("#{where} is not a regular file", "replace #{candidate.path} with a regular file, #{remedy}") unless facts.regular
    unless facts.uid == euid
      raise Error.new("#{where} is owned by uid #{facts.uid}, not this user (uid #{euid})",
                      "chown it to this user, #{remedy}")
    end
    if facts.mode.to_i.anybits?(0o022)
      raise Error.new(format("%<w>s is group/other-writable (mode %<m>04o)", w: where, m: facts.mode & 0o7777),
                      "chmod go-w #{candidate.path}")
    end

    Location.new(path: candidate.path, source: "override", inherits: candidate.kind == :xdg)
  end

  # ── schema ────────────────────────────────────────────────────────────────

  # -> Parsed, or raises Error naming the file and what is wrong. inherit: an
  # Inheritance (the tracked default) whose optional keys fill each repo entry
  # that omits them (DND-1672), or nil.
  def parse(text, home:, path:, inherit: nil)
    doc = JSON.parse(text)
    bad!(path, "the config is not a JSON object") unless doc.is_a?(Hash)

    keys!(path, doc, TOP_KEYS, [], "the config")
    window = doc["window"]
    bad!(path, "window must be a positive integer, got #{window.inspect}") unless window.is_a?(Integer) && window.positive?

    epic = doc["improvement_epic"]
    bad!(path, "improvement_epic must be a non-empty string") unless nonblank?(epic)

    repos = doc["repos"]
    bad!(path, "repos must be a non-empty list") unless repos.is_a?(Array) && !repos.empty?

    parsed = repos.each_with_index.map { |r, i| repo(path, r, i, home, epic, inherit) }
    dup = parsed.map(&:name).tally.find { |_, n| n > 1 }
    bad!(path, "repo #{dup[0].inspect} is listed #{dup[1]} times") if dup

    Parsed.new(repos: parsed, window: window, improvement_epic: epic, inherits_from: inherit&.path)
  rescue JSON::ParserError => e
    bad!(path, "the config is not valid JSON (#{e.message.lines.first.to_s.strip})")
  end

  # -> Inheritance from the tracked default's text. The text is parsed in full
  # first, so a tracked default that does not parse is an Error naming it,
  # never "nothing to inherit".
  def inheritable(text, home:, path:)
    parse(text, home: home, path: path)
    entries = JSON.parse(text)["repos"].to_h { |r| [r["name"], r.slice(*REPO_OPTIONAL)] }
    Inheritance.new(path: path, entries: entries)
  end

  def repo(path, entry, index, home, improvement_epic, inherit = nil)
    bad!(path, "repos[#{index}] is not an object") unless entry.is_a?(Hash)

    name = entry["name"]
    inherited = []
    if inherit && name.is_a?(String)
      extra = inherit.entries.fetch(name, {}).reject { |k, _| entry.key?(k) }
      inherited = REPO_OPTIONAL.select { |k| extra.key?(k) }
      entry = entry.merge(extra)
    end
    keys!(path, entry, REPO_KEYS, REPO_OPTIONAL, "repos[#{index}] (#{name.inspect})")
    bad!(path, "repos[#{index}] name #{name.inspect} is not a plain name") unless name.is_a?(String) && NAME_RE.match?(name)

    mode = entry["mode"]
    bad!(path, "repo #{name.inspect} has unknown mode #{mode.inspect} (known: #{MODES.join(', ')})") unless MODES.include?(mode)

    product = improvement_epic
    source = "improvement_epic"
    if entry.key?("product_epic")
      bad!(path, "repo #{name.inspect} product_epic must be a non-empty string, or absent") unless nonblank?(entry["product_epic"])
      product = entry["product_epic"]
      source = "repo"
    end
    idle = entry["idle_workflow"]
    if entry.key?("idle_workflow") && idle_workflow_kind(idle).nil?
      bad!(path, "repo #{name.inspect} idle_workflow #{idle.inspect} must be a workflow file name (post-merge.yml), " \
                 "a GitLab idle pipeline selector (#{idle_selector_error(idle)}), or \"none\", or absent")
    end
    if mode == "improve" && idle.nil?
      raise Error.new("#{path}: repo #{name.inspect} is mode improve and declares no idle_workflow; the lead-time ingest would infer post-merge CI per batch and can write two lead definitions into one ledger",
                      "add \"idle_workflow\": \"<post-merge workflow file>.yml\" (or \"none\" when the repo has no post-merge workflow) to repo #{name.inspect} in #{path}")
    end
    Repo.new(name: name, path: expand(path, entry["path"], name, home), mode: mode,
             product_epic: product, product_epic_source: source, idle_workflow: idle, inherited: inherited)
  end

  def nonblank?(value) = value.is_a?(String) && !value.strip.empty?

  # The one home of the values idle_workflow accepts (DND-1671, DND-1952).
  # -> :none, :workflow (a GitHub workflow file), :gitlab (a valid GitLab idle
  # pipeline selector), or nil (not an idle_workflow value). A value that
  # starts with "gitlab:" is a selector or nothing, never a file name.
  def idle_workflow_kind(value)
    return nil unless value.is_a?(String)
    return (GitLabPipelineSelector.parse(value)[0] ? :gitlab : nil) if GitLabPipelineSelector.selector?(value)
    return :none if value == "none"

    IDLE_WORKFLOW_RE.match?(value) ? :workflow : nil
  end

  # Why a value is not a GitLab selector, for a refusal's message.
  def idle_selector_error(value)
    return GitLabPipelineSelector.form unless GitLabPipelineSelector.selector?(value)

    GitLabPipelineSelector.parse(value)[1] || GitLabPipelineSelector.form
  end

  def keys!(path, hash, wanted, optional, what)
    missing = wanted - hash.keys
    extra = hash.keys - wanted - optional
    bad!(path, "#{what} is missing #{missing.join(', ')}") unless missing.empty?
    bad!(path, "#{what} has unknown key(s) #{extra.join(', ')}") unless extra.empty?
  end

  def expand(path, raw, name, home)
    p = raw.to_s
    if p.start_with?("~/")
      bad!(path, "repo #{name.inspect} path #{raw.inspect} needs HOME, which is unset or not absolute") unless home.to_s.start_with?("/")
      p = File.join(home, p[2..])
    end
    bad!(path, "repo #{name.inspect} path #{raw.inspect} is not absolute or ~/-relative") unless p.start_with?("/")

    p
  end

  def bad!(path, what)
    raise Error.new("#{path}: #{what}", "correct #{path} (#{SCHEMA_HINT})")
  end

  # ── presence ──────────────────────────────────────────────────────────────

  # The repo label the telemetry writer stamps on every event
  # (AthenaTelemetry::GitContext): the basename of the main checkout.
  def repo_label(common_dir) = File.basename(File.dirname(common_dir))

  # -> OwnRepo from the runner's git common dir (nil when git could not say,
  # with `why`). The key is validated where it is produced: a relative path,
  # or a common dir that is not <checkout>/.git (a bare repo), is an error
  # value, never a path that would match the wrong checkout.
  def own_repo(common_dir, why: nil)
    return OwnRepo.new(error: why || "no git common dir") if common_dir.nil? || common_dir.to_s.empty?

    dir = common_dir.to_s
    return OwnRepo.new(error: "the runner's git common dir #{dir.inspect} is not absolute") unless dir.start_with?("/")
    unless File.basename(dir) == ".git"
      return OwnRepo.new(error: "the runner's git common dir #{dir} is not <checkout>/.git (a bare repo has no main checkout)")
    end

    OwnRepo.new(path: File.dirname(dir), label: repo_label(dir))
  end

  # -> nil (present), a Skip (not on this machine), or raises Error.
  def presence(repo, probe)
    unless probe.exists
      why = probe.symlink ? "#{repo.path} is a dangling symlink" : "no such path #{repo.path}"
      return Skip.new(name: repo.name, path: repo.path, reason: why)
    end

    fix = "point #{repo.name}'s path at the top of its git checkout, or drop #{repo.name} from the config"
    raise Error.new("repo #{repo.name}: #{repo.path} exists but is not a directory", fix) unless probe.directory
    raise Error.new("repo #{repo.name}: #{repo.path} is not a git repository (#{probe.git_error})", fix) if probe.git_error
    unless probe.toplevel == probe.realpath
      raise Error.new("repo #{repo.name}: #{repo.path} is not the top of its git checkout (that is #{probe.toplevel})", fix)
    end

    label = repo_label(probe.common_dir)
    unless label == repo.name
      raise Error.new("repo #{repo.name}: #{repo.path}'s main checkout is named #{label.inspect}; telemetry labels its " \
                      "events #{label.inspect}, so #{repo.name} would join zero events",
                      "rename the entry to #{label.inspect}, or point it at the checkout named #{repo.name}")
    end
    nil
  end

  # ── resolve ───────────────────────────────────────────────────────────────

  # -> Resolution. probes: { repo name => Probe }. A repo with no probe is an
  # error: the IO side failed to look, which is never "not on this machine".
  def resolve(location, parsed, probes)
    repos = []
    skipped = []
    parsed.repos.each do |r|
      probe = probes[r.name] or
        raise Error.new("repo #{r.name}: no probe was taken (an internal fault)", "file a DND ticket with this line")
      skip = presence(r, probe)
      skip ? skipped << skip : repos << r
    end
    Resolution.new(source: location.source, path: location.path, inherits_from: parsed.inherits_from,
                   window: parsed.window,
                   improvement_epic: parsed.improvement_epic, repos: repos, skipped: skipped,
                   considered: parsed.repos.size)
  end
end
