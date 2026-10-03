# frozen_string_literal: true

# ai/lib/machine_secrets.rb -- the PURE rules of the per-machine secrets
# practice (DND-845). Contract: ai/contracts/athena-machine-secrets.md.
#
# Bucket placement: Domain. Nothing here reads the environment, the
# filesystem, /proc or git; every input is passed in. The side effects live in
# ai/lib/machine_secrets_host.rb, and ai/bin/check-machine-secrets and
# ai/bin/with-secret are the Managers + Framework.
#
# THE ONE PROPERTY EVERYTHING HERE KEEPS: no function returns, raises or
# formats a secret VALUE. A value is matched and dropped. Every Finding and
# every error message carries a name, a path, a mode, a size or a count.
#
# Deliberately gem-free (stdlib only).

require "json"
require "set"

module MachineSecrets
  REGISTRY_KIND = "athena-machine-secrets"
  ALLOWLIST_KIND = "athena-machine-secrets-env-allowlist"
  SCHEMA = 1

  # Contract -> check-machine-secrets -> Credential patterns.
  NAME_RE = /TOKEN|SECRET|PASSWORD|PASSWD|BEARER|API_?KEY|PRIVATE_KEY|ACCESS_KEY|SESSION_TOKEN|CREDENTIAL|(?:\A|_)PAT(?:\z|_)/i.freeze

  # An env or config VALUE: the prefix alone, at the start.
  VALUE_START_RE = /\A(?:sk-ant-|xox[abp]-|gh[opsu]_|github_pat_|glpat-|glrt-|ntn_|(?:AKIA|ASIA)[A-Z0-9]{16}|-----BEGIN|re_[A-Za-z0-9]{20,})/.freeze

  # FILE CONTENTS: at a word boundary, with a minimum length after the prefix,
  # because prose names a prefix without a value. One pattern per prefix, each
  # starting with its literal, so the regex engine searches for the literal
  # (measured on this machine's ai-artifacts: 1.1 s, against 8.9 s for one
  # alternation behind a lookbehind). The word boundary is checked on the byte
  # before each match (content_boundary?).
  CONTENT_PATTERNS = [
    /sk-ant-[A-Za-z0-9_-]{20,}/, /xoxa-[A-Za-z0-9-]{10,}/, /xoxb-[A-Za-z0-9-]{10,}/, /xoxp-[A-Za-z0-9-]{10,}/,
    /ghp_[A-Za-z0-9]{30,}/, /gho_[A-Za-z0-9]{30,}/, /ghs_[A-Za-z0-9]{30,}/, /ghu_[A-Za-z0-9]{30,}/,
    /github_pat_[A-Za-z0-9_]{30,}/, /glpat-[A-Za-z0-9_-]{20,}/, /glrt-[A-Za-z0-9_-]{20,}/,/ntn_[A-Za-z0-9]{30,}/,
    /AKIA[A-Z0-9]{16}(?![A-Za-z0-9])/, /ASIA[A-Z0-9]{16}(?![A-Za-z0-9])/, /re_[A-Za-z0-9]{20,}/
  ].map(&:freeze).freeze
  PEM_RE = /-----BEGIN [A-Z ]*PRIVATE KEY-----/.freeze
  WORD_BYTE_RE = /[A-Za-z0-9_-]/.freeze

  ENTRY_NAME_RE = /\A[A-Za-z0-9][A-Za-z0-9_.-]*\z/.freeze
  ENV_NAME_RE = /\A[A-Za-z_][A-Za-z0-9_]*\z/.freeze
  KIND_RE = /\A[a-z0-9-]+\z/.freeze
  # A local account name (shadow's useradd rule, at most 32 characters).
  USER_RE = /\A[a-z_][a-z0-9_-]{0,31}\z/.freeze
  REQUIRED_STRINGS = %w[name path kind restart rotate].freeze
  ALLOWLIST_RULES = %w[file-path git-config-key].freeze
  GIT_CONFIG_KEY_RE = /\AGIT_CONFIG_KEY_\d+\z/.freeze

  class Malformed < StandardError; end

  module_function

  def credential_name?(name)
    NAME_RE.match?(name.to_s)
  end

  def credential_value?(value)
    VALUE_START_RE.match?(value.to_s)
  end

  def credential_content?(text)
    # The patterns are ASCII-only, so they match raw bytes: no transcoding,
    # and no encoding error on a binary file.
    s = text.to_s.b
    return true if PEM_RE.match?(s)

    CONTENT_PATTERNS.any? do |re|
      pos = 0
      hit = false
      while (m = re.match(s, pos))
        b = m.begin(0)
        break hit = true if b.zero? || !WORD_BYTE_RE.match?(s.byteslice(b - 1, 1))

        pos = b + 1
      end
      hit
    end
  end

  def looks_secret?(string)
    credential_value?(string) || credential_content?(string)
  end

  # ---------------------------------------------------------------- registry

  Entry = Struct.new(:name, :path, :copies, :consumers, :kind, :restart, :rotate, :user, :source, keyword_init: true)

  # text -> [Entry]. Raises Malformed with a reason that never quotes a value.
  def parse_registry(text, source)
    doc = begin
      JSON.parse(text)
    rescue JSON::ParserError, EncodingError
      raise Malformed, "#{source}: not valid JSON"
    end
    raise Malformed, "#{source}: top level is not an object" unless doc.is_a?(Hash)
    raise Malformed, "#{source}: kind is not #{REGISTRY_KIND.inspect}" unless doc["kind"] == REGISTRY_KIND
    raise Malformed, "#{source}: schema is not #{SCHEMA}" unless doc["schema"] == SCHEMA

    unknown = doc.keys.reject { |k| %w[kind schema secrets].include?(k) || k.start_with?("_") }
    raise Malformed, "#{source}: unknown top-level key(s) #{printable(unknown)}" unless unknown.empty?

    list = doc["secrets"]
    raise Malformed, "#{source}: secrets is not a list" unless list.is_a?(Array)

    seen = Set.new
    list.each_with_index.map do |raw, i|
      entry = parse_entry(raw, "#{source}: secrets[#{i}]", source)
      raise Malformed, "#{source}: name #{entry.name} is declared twice" unless seen.add?(entry.name)

      entry
    end
  end

  def parse_entry(raw, where, source)
    raise Malformed, "#{where} is not an object" unless raw.is_a?(Hash)

    # FIRST, before any message can name the entry: a field (or a key) that
    # holds a credential value is refused by position only. The name is one of
    # the fields checked, so a pasted value used as a name is never echoed.
    leaky = raw.flat_map { |k, v| [[k, nil], *Array(v).map { |x| [x, k] }] }
               .find { |x, _| x.is_a?(String) && looks_secret?(x) }
    if leaky
      field = leaky[1].nil? || looks_secret?(leaky[1]) ? "a field name or value" : leaky[1]
      raise Malformed, "#{where}: #{field} looks like a credential value (a registry never holds one)"
    end

    REQUIRED_STRINGS.each do |f|
      v = raw[f]
      raise Malformed, "#{where}: #{f} is missing or not a non-empty string" unless v.is_a?(String) && !v.strip.empty?
    end
    name = raw["name"]
    raise Malformed, "#{where}: name is not [A-Za-z0-9][A-Za-z0-9_.-]*" unless ENTRY_NAME_RE.match?(name)

    where = "#{source}: #{name}"
    raise Malformed, "#{where}: kind is not [a-z0-9-]+" unless KIND_RE.match?(raw["kind"])

    consumers = raw["consumers"]
    unless consumers.is_a?(Array) && !consumers.empty? && consumers.all? { |c| c.is_a?(String) && !c.strip.empty? }
      raise Malformed, "#{where}: consumers is not a non-empty list of strings"
    end
    copies = raw["copies"]
    raise Malformed, "#{where}: copies is not a string" unless copies.nil? || copies.is_a?(String)

    path_problem(raw["path"]).then { |p| raise Malformed, "#{where}: path #{p}" if p }
    copies && path_problem(copies).then { |p| raise Malformed, "#{where}: copies #{p}" if p }

    user = raw["user"]
    user_problem(user, raw["path"], copies).then { |p| raise Malformed, "#{where}: #{p}" if p }

    unknown = raw.keys - %w[name path copies consumers kind restart rotate user]
    raise Malformed, "#{where}: unknown field(s) #{printable(unknown)}" unless unknown.empty?

    Entry.new(name: name, path: raw["path"], copies: copies, consumers: consumers, kind: raw["kind"],
              restart: raw["restart"], rotate: raw["rotate"], user: user, source: source)
  end

  # Keys for a message: a plain identifier is shown, anything else is only
  # counted, so a pasted value used as a key is never echoed.
  def printable(keys)
    shown, hidden = keys.map(&:to_s).partition { |k| k.match?(/\A[A-Za-z_][A-Za-z0-9_-]{0,40}\z/) && !looks_secret?(k) }
    [*shown.sort, (hidden.empty? ? nil : "#{hidden.size} unprintable")].compact.join(", ")
  end

  # nil when an entry's optional `user` (the local account that holds the
  # file, e.g. a CI runner user) is well formed, else the reason. Such a file
  # lives in that account's tree, so its path is absolute: `~/` would expand
  # against the checking session's HOME, a wrongly computed key.
  def user_problem(user, path, copies)
    return nil if user.nil?
    return "user is not a local account name ([a-z_][a-z0-9_-]{0,31})" unless user.is_a?(String) && USER_RE.match?(user)
    return "path of an entry held by user #{user} is not absolute" unless path.start_with?("/")
    return "copies is not supported on an entry held by user #{user}" unless copies.nil?

    nil
  end

  # nil when path is well formed, else the reason.
  def path_problem(path)
    return "is empty" if path.nil? || path.empty?
    return "contains a NUL" if path.include?("\0")
    return "is neither absolute nor ~/..." unless path.start_with?("/") || path.start_with?("~/")
    return "contains a .. segment" if path.split("/").include?("..")

    nil
  end

  # Expand a registry path against home. Raises Malformed when the key cannot
  # be computed: resolving the key is its own step (ai/CLAUDE.md -> A failed
  # lookup must never look like an empty one).
  def expand(path, home)
    return path if path.start_with?("/")
    raise Malformed, "HOME is unset or empty, so #{path} cannot be expanded" if home.nil? || home.empty?
    raise Malformed, "HOME (#{home}) is not absolute, so #{path} cannot be expanded" unless home.start_with?("/")

    File.join(home, path.delete_prefix("~/"))
  end

  # Union of registries, by name. Two sources declaring one name with different
  # paths are both kept (each is checked); the same name and path is one entry.
  def union(*lists)
    lists.flatten.uniq { |e| [e.name, e.path, e.copies] }
  end

  # --------------------------------------------------------------- allowlist

  Allowlist = Struct.new(:exact, :rules, keyword_init: true) do
    def allows?(name, value, path_exists)
      return true if exact.include?(name)
      return true if rules.include?("git-config-key") && GIT_CONFIG_KEY_RE.match?(name)
      return true if rules.include?("file-path") && name.end_with?("_FILE") && !value.to_s.empty? && path_exists.call(value)

      false
    end
  end

  EMPTY_ALLOWLIST = Allowlist.new(exact: Set.new.freeze, rules: Set.new.freeze).freeze

  def parse_allowlist(text, source)
    doc = begin
      JSON.parse(text)
    rescue JSON::ParserError, EncodingError
      raise Malformed, "#{source}: not valid JSON"
    end
    raise Malformed, "#{source}: top level is not an object" unless doc.is_a?(Hash)
    raise Malformed, "#{source}: kind is not #{ALLOWLIST_KIND.inspect}" unless doc["kind"] == ALLOWLIST_KIND
    raise Malformed, "#{source}: schema is not #{SCHEMA}" unless doc["schema"] == SCHEMA

    exact = doc["exact"]
    rules = doc["rules"]
    raise Malformed, "#{source}: exact is not a list of env names" unless exact.is_a?(Array) && exact.all? { |n| n.is_a?(String) && ENV_NAME_RE.match?(n) }
    raise Malformed, "#{source}: rules is not a list" unless rules.is_a?(Array)

    bad = rules - ALLOWLIST_RULES
    raise Malformed, "#{source}: unknown rule(s) #{printable(bad)}" unless bad.empty?

    Allowlist.new(exact: exact.to_set.freeze, rules: rules.to_set.freeze)
  end

  # The honoured allowlist: an entry in the working tree AND at every landed
  # point that has the file. No landed point has it -> nothing is honoured.
  def effective_allowlist(working, landed_bars)
    return EMPTY_ALLOWLIST if landed_bars.empty?

    [working, *landed_bars].reduce do |acc, al|
      Allowlist.new(exact: (acc.exact & al.exact).freeze, rules: (acc.rules & al.rules).freeze)
    end
  end

  # ---------------------------------------------------------- env findings

  # One reported variable. reason: :name or :value. status: :finding, or
  # :unverified (only an unreadable landed allowlist would excuse it).
  EnvHit = Struct.new(:name, :reason, :status, keyword_init: true)

  # env: {name => value}. honoured: the landed allowlist, or nil when it could
  # not be read. working: the working tree's allowlist (used only to name a
  # hit as :unverified when honoured is nil).
  def env_hits(env, honoured, working, path_exists)
    env.keys.sort.filter_map do |name|
      value = env[name]
      reason = if credential_name?(name) then :name
               elsif credential_value?(value) then :value
               end
      next unless reason
      next if honoured&.allows?(name, value, path_exists)

      status = honoured.nil? && working&.allows?(name, value, path_exists) ? :unverified : :finding
      EnvHit.new(name: name, reason: reason, status: status)
    end
  end

  # ------------------------------------------------------ static config

  ASSIGN_LEAD_RE = /\A\s*(?:(?:export|typeset\s+-x|declare\s+-x|local\s+-x|readonly)\s+)?(?=[A-Za-z_][A-Za-z0-9_]*=)/.freeze
  ASSIGN_RE = /(?:\A|\s)([A-Za-z_][A-Za-z0-9_]*)=("(?:[^"\\]|\\.)*"|'[^']*'|\S*)/.freeze

  # [[name, value, line_no]] for every NAME=VALUE assignment in a shell init
  # or environment.d file. Comment lines are skipped.
  def shell_assignments(text)
    out = []
    text.to_s.dup.force_encoding(Encoding::UTF_8).scrub.each_line.with_index(1) do |line, no|
      next if line.lstrip.start_with?("#")

      m = ASSIGN_LEAD_RE.match(line)
      next unless m

      line[m.end(0)..].scan(ASSIGN_RE) { |name, raw| out << [name, unquote(raw), no] }
    end
    out
  end

  def unquote(raw)
    if raw.start_with?('"') && raw.end_with?('"') && raw.length >= 2 then raw[1..-2]
    elsif raw.start_with?("'") && raw.end_with?("'") && raw.length >= 2 then raw[1..-2]
    else raw
    end
  end

  # A static assignment is reported when its name or value is a credential,
  # unless the allowlist excuses the name. path_exists expands ~ and $HOME.
  def static_hit?(name, value, honoured, path_exists)
    return false if value.to_s.empty?
    return false unless credential_name?(name) || credential_value?(value)
    return false if honoured&.allows?(name, value, path_exists)

    true
  end

  MCP_REF_RE = /\A\$\{?[A-Za-z_][A-Za-z0-9_]*(?::-[^}]*)?\}?\z/.freeze

  # An MCP env/header/arg value that is only a ${VAR} reference is expanded
  # by Claude Code into that one child; the value is not in the file.
  def mcp_reference?(value)
    MCP_REF_RE.match?(value.to_s)
  end

  # [[key_path, name]] of credential-bearing MCP settings for one server.
  def mcp_server_hits(server, prefix, honoured, path_exists)
    return [] unless server.is_a?(Hash)

    hits = []
    %w[env headers].each do |field|
      h = server[field]
      next unless h.is_a?(Hash)

      h.each do |k, v|
        next unless v.is_a?(String)
        next if mcp_reference?(v)

        bearer = field == "headers" && v.match?(/\A\s*Bearer\s+\S/i) && !mcp_reference?(v.sub(/\A\s*Bearer\s+/i, ""))
        hits << ["#{prefix}.#{field}.#{k}", k] if bearer || static_hit?(k, v, honoured, path_exists)
      end
    end
    Array(server["args"]).each_with_index do |arg, i|
      next unless arg.is_a?(String)

      flag, eq, val = arg.partition("=")
      name = flag.sub(/\A-+/, "").tr("-", "_").upcase
      hit = looks_secret?(arg) ||
            (!eq.empty? && !mcp_reference?(val) && static_hit?(name, val, honoured, path_exists))
      hits << ["#{prefix}.args[#{i}]", eq.empty? ? "(argument #{i})" : name] if hit
    end
    url = server["url"]
    if url.is_a?(String)
      query = url.split("?", 2)[1].to_s
      named = query.split("&").map { |kv| kv.split("=", 2) }.find do |k, v|
        v && !v.empty? && !mcp_reference?(v) && credential_name?(k.to_s)
      end
      hits << ["#{prefix}.url", named ? named[0] : "(url)"] if named || looks_secret?(url)
    end
    hits
  end

  # ------------------------------------------------- PENDING RESTART

  # records: [{"name","file","line"}] for this name. still_assigned: lambda
  # file -> true when the file still assigns name. mtime: lambda file ->
  # Float|nil (stat -L). session_start: Float|nil (the nearest claude
  # ancestor's start). -> [:pending, record] or [:fail, why].
  def restart_verdict(records, still_assigned, mtime, session_start, show = ->(f) { f })
    return [:fail, "no recorded export for it (run check-machine-secrets before deleting an export)"] if records.empty?
    return [:fail, "no ancestor claude process, so a restart cannot be pending"] if session_start.nil?

    gone = records.reject { |r| still_assigned.call(r["file"]) }
    return [:fail, "its recorded export is still present at #{records.map { |r| "#{show.call(r['file'])}:#{r['line']}" }.join(', ')}"] if gone.empty?

    fresh = gone.find do |r|
      m = mtime.call(r["file"])
      m && m > session_start
    end
    return [:pending, fresh] if fresh

    [:fail, "its recorded export is gone, but #{gone.map { |r| show.call(r['file']) }.join(', ')} did not change after this session started"]
  end

  # ------------------------------------------------------- core dumps

  CORE_NAME_RE = /\A(?:core|core\..+|.+\.core)\z/.freeze

  # An ELF file whose e_type is ET_CORE (4). header: the first 18 bytes.
  def elf_core?(header)
    return false if header.nil? || header.bytesize < 18
    return false unless header.byteslice(0, 4) == "\x7FELF".b

    little = header.getbyte(5) == 1
    e_type = little ? header.byteslice(16, 2).unpack1("v") : header.byteslice(16, 2).unpack1("n")
    e_type == 4
  end

  # ------------------------------------------------------- file modes

  # nil when a secret file's stat is acceptable, else the reason.
  def file_mode_problem(mode, uid, my_uid)
    perm = mode & 0o777
    return "owned by uid #{uid}, not #{my_uid}" unless uid == my_uid
    return format("mode %04o (want 0600 or 0400)", perm) unless [0o600, 0o400].include?(perm)

    nil
  end

  def dir_mode_problem(mode)
    perm = mode & 0o777
    return format("parent directory mode %04o is group- or world-writable", perm) if perm & 0o022 != 0

    nil
  end
end
