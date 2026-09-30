# frozen_string_literal: true

# ai/lib/machine_secrets_host.rb -- the SIDE-EFFECT half of the per-machine
# secrets practice (DND-845): the environment, the filesystem, /proc, git and
# the machine-local exports record. Every decision is handed to the pure rules
# in ai/lib/machine_secrets.rb. Contract: ai/contracts/athena-machine-secrets.md.
#
# Callers: ai/bin/check-machine-secrets and ai/bin/with-secret.
#
# No function here returns or prints a secret VALUE to its caller except
# MachineSecretsHost.read_secret, whose one caller (with-secret) hands it
# straight to exec's environment.
#
# Deliberately gem-free (stdlib only).

require "json"
require "time"
require "etc"
require "find"
require "fileutils"
require "open3"
require_relative "machine_secrets"
require_relative "landed"
require_relative "private_overlay_resolver"

module MachineSecretsHost
  REPO_ROOT = File.expand_path("../..", __dir__)
  REGISTRY_REL = "ai/secrets/registry.json"
  ALLOWLIST_REL = "ai/secrets/env-allowlist.json"
  OVERLAY_FILE = "overlay/secrets.json"
  SKIP_DIRS = %w[deps _build node_modules .git].freeze

  # TEST SEAM (self-test only): the session start, as epoch seconds, or
  # "none" for no claude ancestor (a suite run inside a session has one). It
  # can only turn a FAIL into PENDING RESTART for a name whose recorded export is
  # already gone from its file, and the output says it was injected.
  SESSION_START_SEAM = "CHECK_MS_TEST_CLAUDE_START"

  module_function

  def home(env = ENV)
    env["HOME"]
  end

  def tilde(path, env = ENV)
    h = home(env)
    return path if h.nil? || h.empty? || !path.start_with?("#{h}/")

    "~/#{path.delete_prefix("#{h}/")}"
  end

  # ----------------------------------------------------------- landed

  # -> { allowlists: [Allowlist], registries: [[Entry]], points: [...] } or
  # raises Landed::Unreadable / Landed::Mismatch / MachineSecrets::Malformed.
  def landed(root = REPO_ROOT)
    pts, probes = Landed.points(root)
    allowlists = []
    registries = []
    pts.each do |label, sha|
      text = Landed.file_at(root, sha, ALLOWLIST_REL, label)
      allowlists << MachineSecrets.parse_allowlist(text, "#{ALLOWLIST_REL} @ #{label}") if text
      text = Landed.file_at(root, sha, REGISTRY_REL, label)
      registries << MachineSecrets.parse_registry(text, "#{REGISTRY_REL} @ #{label}") if text
    rescue Landed::Unreadable => e
      raise Landed::Unreadable.new(probes + e.probes)
    end
    { allowlists: allowlists, registries: registries, points: pts }
  end

  def working_file(rel, root = REPO_ROOT)
    File.read(File.join(root, rel), mode: "rb").force_encoding(Encoding::UTF_8)
  end

  # -> [entries or nil, state] where state is :absent, :present or a
  # Malformed reason string. An absent overlay is not a fault.
  def overlay_registry(env = ENV)
    r = PrivateOverlay::Resolver.root(env: env)
    return [nil, :absent] if r.state == :absent
    return [nil, "private overlay is malformed: #{r.reason}"] unless r.state == :found

    path = File.join(r.root, OVERLAY_FILE)
    return [[], :present] unless File.exist?(path)

    [MachineSecrets.parse_registry(File.read(path, mode: "rb"), "overlay #{OVERLAY_FILE}"), :present]
  rescue MachineSecrets::Malformed => e
    [nil, e.message]
  rescue SystemCallError => e
    [nil, "overlay #{OVERLAY_FILE} could not be read (#{e.class.name.split('::').last})"]
  end

  # ------------------------------------------------------------- files

  # Stat a declared path. -> { state: :absent | :ok | :bad, shown:, problem: }.
  def check_secret_file(path, env = ENV)
    lst = File.lstat(path)
    shown = tilde(path, env)
    target = path
    if lst.symlink?
      begin
        target = File.realpath(path)
      rescue SystemCallError
        return { state: :bad, shown: "#{shown} -> (dangling)", problem: "a dangling symlink", fix_path: path }
      end
      shown = "#{shown} -> #{tilde(target, env)}"
    end
    st = File.stat(target)
    return { state: :bad, shown: shown, problem: "not a regular file", fix_path: target } unless st.file?

    problem = MachineSecrets.file_mode_problem(st.mode, st.uid, Process.uid)
    return { state: :bad, shown: shown, problem: problem, fix: "chmod 600 #{tilde(target, env)}" } if problem

    dir = File.dirname(target)
    problem = MachineSecrets.dir_mode_problem(File.stat(dir).mode)
    return { state: :bad, shown: shown, problem: problem, fix: "chmod 700 #{tilde(dir, env)}" } if problem

    { state: :ok, shown: shown }
  rescue Errno::ENOENT
    { state: :absent, shown: tilde(path, env) }
  rescue SystemCallError => e
    { state: :bad, shown: tilde(path, env), problem: "could not stat (#{e.class.name.split('::').last})" }
  end

  GLOB_FLAGS = File::FNM_EXTGLOB | File::FNM_DOTMATCH

  def glob(pattern)
    Dir.glob(pattern, GLOB_FLAGS).reject { |p| %w[. ..].include?(File.basename(p)) }.sort
  end

  # with-secret's one read of a value. Drops one trailing newline.
  def read_secret(path)
    File.read(path, mode: "rb").chomp
  end

  # ----------------------------------------------------- static config

  def shell_init_files(env = ENV, root = REPO_ROOT)
    h = home(env)
    raise MachineSecrets::Malformed, "HOME is unset, empty or relative, so the shell init files cannot be found" if h.nil? || !h.start_with?("/")

    named = %w[.zshrc .zshenv .zprofile .zlogin .profile .bashrc .bash_profile .bash_login].map { |f| File.join(h, f) }
    globbed = glob(File.join(h, ".zshrc.*")) + glob(File.join(h, ".config/environment.d/*.conf"))
    candidates = named + globbed + [File.join(root, "dotfiles/.zshrc")]
    seen = {}
    candidates.select do |p|
      next false unless File.file?(p)

      real = File.realpath(p)
      seen.key?(real) ? false : (seen[real] = true)
    end
  end

  def json_files(env = ENV)
    h = home(env)
    [File.join(h, ".claude/settings.json"), File.join(h, ".claude.json")].select { |p| File.file?(p) }
  end

  # [[loc, name]] for one static file. loc is "LINE" or a JSON key path.
  # Raises MachineSecrets::Malformed for an unparseable JSON file.
  def scan_static(path, honoured, env = ENV)
    exists = path_exists_fn(env)
    text = File.read(path, mode: "rb")
    if path.end_with?(".json")
      scan_json(path, text, honoured, exists)
    else
      MachineSecrets.shell_assignments(text).filter_map do |name, value, no|
        [no.to_s, name] if MachineSecrets.static_hit?(name, value, honoured, exists)
      end
    end
  end

  def scan_json(path, text, honoured, exists)
    doc = begin
      JSON.parse(text)
    rescue JSON::ParserError, EncodingError
      raise MachineSecrets::Malformed, "#{path} is not valid JSON"
    end
    return [] unless doc.is_a?(Hash)

    hits = []
    if File.basename(path) == "settings.json"
      env = doc["env"]
      if env.is_a?(Hash)
        env.each do |k, v|
          hits << ["env.#{k}", k] if v.is_a?(String) && MachineSecrets.static_hit?(k, v, honoured, exists)
        end
      end
    else
      servers = [["mcpServers", doc["mcpServers"]]]
      (doc["projects"].is_a?(Hash) ? doc["projects"] : {}).each do |proj, cfg|
        servers << ["projects[#{proj}].mcpServers", cfg["mcpServers"]] if cfg.is_a?(Hash)
      end
      servers.each do |prefix, map|
        next unless map.is_a?(Hash)

        map.each do |sname, server|
          hits.concat(MachineSecrets.mcp_server_hits(server, "#{prefix}.#{sname}", honoured, exists))
        end
      end
    end
    hits
  end

  # `~`, `$HOME` and `${HOME}` expanded, then File.exist?.
  def path_exists_fn(env = ENV)
    h = home(env).to_s
    lambda do |value|
      v = value.to_s.sub(/\A(?:~|\$HOME|\$\{HOME\})(?=\/|\z)/) { h }
      !v.empty? && v.start_with?("/") && File.exist?(v)
    end
  end

  # --------------------------------------------------- exports record

  def exports_path(env = ENV)
    base = env["XDG_STATE_HOME"]
    base = File.join(home(env).to_s, ".local/state") if base.nil? || base.empty?
    File.join(base, "athena/machine-secrets/exports.json")
  end

  # -> [records, nil] or [nil, reason]. A missing file is no records.
  def read_exports(env = ENV)
    path = exports_path(env)
    return [[], nil] unless File.exist?(path)

    doc = JSON.parse(File.read(path))
    list = doc.is_a?(Hash) ? doc["exports"] : nil
    return [nil, "#{tilde(path, env)} has no exports list"] unless list.is_a?(Array)

    [list.select { |r| r.is_a?(Hash) && r["name"].is_a?(String) && r["file"].is_a?(String) }, nil]
  rescue JSON::ParserError, SystemCallError => e
    [nil, "#{tilde(path, env)} could not be read (#{e.class.name.split('::').last})"]
  end

  # Upsert (name, file) -> line. Atomic write, 0600, directory 0700.
  def record_exports(seen, env = ENV)
    records, err = read_exports(env)
    return err if err

    now = Time.now.utc.iso8601
    seen.each do |name, file, line|
      rec = records.find { |r| r["name"] == name && r["file"] == file }
      if rec
        rec["line"] = line
        rec["last_seen"] = now
      else
        records << { "name" => name, "file" => file, "line" => line, "first_seen" => now, "last_seen" => now }
      end
    end
    path = exports_path(env)
    FileUtils.mkdir_p(File.dirname(path), mode: 0o700)
    tmp = "#{path}.#{Process.pid}.tmp"
    File.open(tmp, File::WRONLY | File::CREAT | File::TRUNC, 0o600) do |f|
      f.write(JSON.pretty_generate({ "schema" => 1, "exports" => records }))
    end
    File.rename(tmp, path)
    nil
  rescue SystemCallError => e
    "#{tilde(exports_path(env), env)} could not be written (#{e.class.name.split('::').last})"
  end

  # ------------------------------------------------------------- /proc

  # -> [epoch Float or nil, note]. The start time of the nearest ancestor
  # process whose comm is "claude".
  def session_start(env = ENV)
    if env.key?(SESSION_START_SEAM)
      raw = env[SESSION_START_SEAM]
      return [nil, "no ancestor claude process (#{SESSION_START_SEAM}=none)"] if raw == "none"
      return [Float(raw), "injected by the #{SESSION_START_SEAM} test seam"] if raw.match?(/\A\d+(\.\d+)?\z/)

      return [nil, "#{SESSION_START_SEAM} is not an epoch number"]
    end
    btime = File.read("/proc/stat")[/^btime (\d+)/, 1]
    return [nil, "/proc/stat has no btime"] unless btime

    hz = Etc.sysconf(Etc::SC_CLK_TCK).to_f
    pid = Process.ppid
    64.times do
      break if pid.nil? || pid <= 1

      stat = File.read("/proc/#{pid}/stat")
      comm = stat[/\((.*)\)/m, 1]
      rest = stat[(stat.rindex(")") + 2)..].split
      return [btime.to_f + (rest[19].to_f / hz), "claude pid #{pid}"] if comm == "claude"

      pid = rest[1].to_i
    end
    [nil, "no ancestor claude process"]
  rescue SystemCallError => e
    [nil, "/proc could not be read (#{e.class.name.split('::').last})"]
  end

  def mtime_l(path)
    File.stat(path).mtime.to_f
  rescue SystemCallError
    nil
  end

  # ------------------------------------------------ persistent plaintext

  # The main checkout of this repo and of every repo in the committed inbox
  # tenancy registry. -> [[dir], [missing repo notes]]
  def scan_roots(env = ENV, root = REPO_ROOT)
    roots = []
    notes = []
    common, st = Open3.capture2e("git", "-C", root, "rev-parse", "--path-format=absolute", "--git-common-dir")
    raise MachineSecrets::Malformed, "git rev-parse --git-common-dir failed in #{root}" unless st.success?

    roots << File.dirname(File.realpath(common.strip))
    reg = JSON.parse(working_file("ai/inbox/registry.json", root))
    Array(reg["projects"]).each do |p|
      repo = p.is_a?(Hash) && p["entry"].is_a?(Hash) ? p["entry"]["repo"] : nil
      next unless repo.is_a?(String)

      path = MachineSecrets.expand(repo, home(env))
      if File.directory?(path)
        roots << File.dirname(File.realpath(path))
      else
        notes << "#{repo} (#{p['file']}): not on this machine"
      end
    end
    [roots.uniq, notes]
  rescue JSON::ParserError, SystemCallError => e
    raise MachineSecrets::Malformed, "the inbox registry could not be read (#{e.class.name.split('::').last})"
  end

  # Yield every regular file under dir, pruning SKIP_DIRS; symlinks are not
  # followed. -> count of pruned directories.
  def walk(dir)
    skipped = 0
    Find.find(dir) do |p|
      st = File.lstat(p)
      if st.directory?
        if p != dir && SKIP_DIRS.include?(File.basename(p))
          skipped += 1
          Find.prune
        end
      elsif st.file?
        yield p, st
      end
    rescue SystemCallError
      next
    end
    skipped
  end

  # Every ai-artifacts directory under a main checkout, at any depth.
  def artifact_dirs(root)
    dirs = []
    Find.find(root) do |p|
      next unless File.lstat(p).directory?

      base = File.basename(p)
      if p != root && SKIP_DIRS.include?(base)
        Find.prune
      elsif base == "ai-artifacts"
        dirs << p
        Find.prune
      end
    rescue SystemCallError
      next
    end
    dirs
  end

  CHUNK = 4 * 1024 * 1024
  OVERLAP = 512

  # true when the file's bytes contain a credential value. Streamed in
  # chunks with an overlap, so a match across a chunk edge is seen.
  def file_has_credential?(path)
    File.open(path, "rb") do |f|
      tail = "".b
      while (buf = f.read(CHUNK))
        window = tail + buf
        return true if MachineSecrets.credential_content?(window)

        tail = window.byteslice([window.bytesize - OVERLAP, 0].max, OVERLAP)
      end
    end
    false
  rescue SystemCallError
    nil
  end

  def core_dump?(path, st)
    return false unless MachineSecrets::CORE_NAME_RE.match?(File.basename(path))
    return false if st.size < 18

    MachineSecrets.elf_core?(File.open(path, "rb") { |f| f.read(18) })
  rescue SystemCallError
    false
  end
end
