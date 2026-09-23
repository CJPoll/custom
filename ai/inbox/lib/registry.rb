# frozen_string_literal: true

# InboxRegistry — the one implementation of "what the committed tenant list
# says the live registry should look like".
#
# Two artifacts need this logic and MUST NOT disagree about it: the installer
# (scripts/setup-inbox-registry, which writes the entries) and the check
# (ai/bin/check-inbox-registry, which fails when they drift). Two copies of a
# render/compare rule is how an installer starts writing something its own
# check calls drift, so the rule lives here and both require this file.
#
# What it does NOT do: read message surfaces, resolve channels, or act as an
# inbox reader. It only compares the committed source of truth
# (ai/inbox/registry.json) against $ATHENA_INBOX_ROOT/projects/*.json.
#
# Contract: ai/contracts/athena-inbox.md -> "Tenancy: the registry",
# "Repo identity: the git common dir", "Provisioning".
#
# Deliberately gem-free (stdlib only).

require "json"
require "open3"
require "shellwords"

module InboxRegistry
  DEFAULT_ROOT = "~/.local/share/athena"
  PROJECTS_DIR_MODE = 0o700
  ENTRY_MODE = 0o600

  ROOT_MODE = 0o700

  # Filename grammar AND length bound from the contract's "Finding the entry".
  # The filename carries no authority, but a file that fails either is never a
  # candidate, so declaring one here would install an entry nothing can find —
  # zero channels, exit 0, silent. This grammar is also the only thing between a
  # declared "file" and a write outside projects/, since the reader's own
  # validator checks the entry body, not its filename.
  FILENAME_RE = /\A[a-z0-9][a-z0-9_-]*\.json\z/

  module_function

  def repo_dir
    File.expand_path("../../..", __dir__)
  end

  # The committed source of truth. Overridable for tests only.
  def registry_path
    ENV["ATHENA_INBOX_REGISTRY"] || File.join(repo_dir, "ai", "inbox", "registry.json")
  end

  def root
    File.expand_path(ENV["ATHENA_INBOX_ROOT"] || DEFAULT_ROOT)
  end

  def projects_dir
    File.join(root, "projects")
  end

  def entry_path(file)
    File.join(projects_dir, file)
  end

  # Expand a declared `repo` value to the absolute path an entry must carry.
  # A leading ~/ is expanded so the committed file is not wedded to one home
  # directory; the result is realpath'd when it exists, because the contract
  # matches repo identity AFTER realpath and a symlinked path would then match
  # nothing.
  def expand_repo(value)
    expanded = File.expand_path(value.to_s)
    File.exist?(expanded) ? File.realpath(expanded) : expanded
  rescue StandardError
    File.expand_path(value.to_s)
  end

  # Repo identity, resolved AT THE POINT OF CAPTURE.
  #
  # `git rev-parse --git-common-dir` prints a path relative to the directory it
  # ran in — `.git` in a main checkout, absolute only inside a worktree
  # (contract: "Repo identity: the git common dir", with the verification
  # table). Capturing the raw string and resolving it later, after a chdir or
  # in a helper running elsewhere, yields a path that exists nowhere, matches
  # no entry, and therefore means zero channels and exit 0 — a channel that
  # goes dark with no error. So the expansion happens here, against the very
  # directory the command was run in, and the raw string is never returned.
  def git_common_dir(dir)
    out = `git -C #{dir.to_s.shellescape} rev-parse --git-common-dir 2>/dev/null`.strip
    return nil if out.empty?

    absolute = File.expand_path(out, dir)
    File.exist?(absolute) ? File.realpath(absolute) : absolute
  rescue StandardError
    nil
  end

  # Parsed source of truth: [{ "file" => "custom.json", "entry" => {...} }, ...]
  # with `repo` expanded. Raises with an actionable message on a malformed file
  # — the source of truth is committed, so a broken one is a code error, not a
  # machine-state question.
  # Allow-lists, not deny-lists — the same discipline the contract imposes on the
  # entries this file carries. An ignored unknown key makes a typo
  # indistinguishable from a default.
  WRAPPER_KEYS = %w[_meta v projects].freeze
  PROJECT_KEYS = %w[file entry].freeze
  SOURCE_V = 1
  FILENAME_MAX_BYTES = 128

  def declared
    raw = File.read(registry_path)
    doc = JSON.parse(raw)
    raise Error, "#{registry_path}: top level is not a JSON object" unless doc.is_a?(Hash)

    unknown = doc.keys - WRAPPER_KEYS
    raise Error, "#{registry_path}: unknown top-level key(s): #{unknown.join(', ')}" unless unknown.empty?
    raise Error, "#{registry_path}: \"v\" is #{doc['v'].inspect}; this tool understands v=#{SOURCE_V} only" unless doc.fetch("v", SOURCE_V) == SOURCE_V

    projects = doc["projects"]
    raise Error, "#{registry_path}: top-level \"projects\" must be an array" unless projects.is_a?(Array)

    entries = projects.map { |p| declared_one(p) }
    reject_duplicates(entries)
    reject_unreadable(entries)
    reject_session_stem_collisions(entries)
    entries
  rescue Errno::ENOENT
    raise Error, "committed source of truth not found at #{registry_path}"
  rescue JSON::ParserError => e
    raise Error, "#{registry_path} is not valid JSON (#{e.message})"
  end

  class Error < StandardError; end

  def declared_one(project)
    raise Error, "#{registry_path}: every \"projects\" member must be an object" unless project.is_a?(Hash)

    unknown = project.keys - PROJECT_KEYS
    raise Error, "#{registry_path}: unknown key(s) in a project: #{unknown.join(', ')}" unless unknown.empty?

    file = project["file"]
    entry = project["entry"]
    raise Error, "#{registry_path}: every project needs a \"file\" and an \"entry\"" unless file.is_a?(String) && entry.is_a?(Hash)
    raise Error, "#{registry_path}: entry filename #{file.inspect} does not match #{FILENAME_RE.source}" unless FILENAME_RE.match?(file)
    raise Error, "#{registry_path}: entry filename #{file.inspect} is #{file.bytesize} bytes; the registry grammar allows at most #{FILENAME_MAX_BYTES}" if file.bytesize > FILENAME_MAX_BYTES
    raise Error, "#{registry_path}: #{file} entry needs a string \"repo\"" unless entry["repo"].is_a?(String)

    { "file" => file, "entry" => entry.merge("repo" => expand_repo(entry["repo"])) }
  end

  # Two declared entries claiming one repo identity is not a slow leak, it is
  # the contract's own hard error: *Finding the entry* makes a session with two
  # matching entries refuse outright, so a copy-pasted `repo` here would wedge
  # every session in that repo. A duplicate `file` is quieter and worse — the
  # later entry silently wins and the earlier declaration is never installed.
  def reject_duplicates(entries)
    %w[file repo].each do |key|
      seen = {}
      entries.each do |p|
        value = key == "file" ? p["file"] : p["entry"]["repo"]
        if seen[value]
          raise Error, "#{registry_path}: #{seen[value]} and #{p['file']} both declare #{key} #{value.inspect}; " \
                       "exactly one entry may claim a given #{key}"
        end
        seen[value] = p["file"]
      end
    end
  end

  # A routed session inbox is the platform `log` file `<project>-session.jsonl`
  # (the contract's "Registry convention for a session inbox", epic D41). Its
  # STEM (`walt_ui-session`) is what a reader sees it as, so no channel NAME in
  # any entry may equal another channel's session stem: two different things
  # would then print under one name in inbox-status and inbox-doctor. That is
  # the collision that renamed the convention from `-mail` (custom's MAILDIR
  # channel `walt_ui-mail` versus walt_ui's routed `walt_ui-mail.jsonl`), and
  # nothing on either side would otherwise refuse it -- each entry is valid on
  # its own. Raised as a defect in the committed file, like the rules above.
  SESSION_SUFFIX = "-session.jsonl"

  def reject_session_stem_collisions(entries)
    stems = {}
    entries.each do |p|
      (p["entry"]["channels"] || {}).each do |name, ch|
        next unless ch.is_a?(Hash) && ch["kind"] == "log" && ch["producer"] == "platform"
        path = ch["path"]
        next unless path.is_a?(String) && path.end_with?(SESSION_SUFFIX)

        stems[path.delete_suffix(".jsonl")] = [p["file"], name]
      end
    end
    entries.each do |p|
      (p["entry"]["channels"] || {}).each_key do |name|
        owner = stems[name]
        next if owner.nil? || owner == [p["file"], name]

        raise Error, "#{registry_path}: channel #{name.inspect} in #{p['file']} has the same name as the " \
                     "routed session inbox #{name}.jsonl (channel #{owner[1].inspect} in #{owner[0]}); " \
                     "the two would print under one name in inbox-status and inbox-doctor. " \
                     "Fix: rename channel #{name.inspect} in #{p['file']} -- a session inbox's file stem is reserved"
      end
    end
  end

  # An entry the reader refuses is a defect in the COMMITTED file, not machine
  # state, so it raises here — where both tools already treat a bad source of
  # truth as exit 2 — rather than being reported as drift whose documented
  # recovery (`--install`) refuses the same entry and cannot possibly work.
  def reject_unreadable(entries)
    entries.each do |p|
      rejection = reader_rejection(p["entry"])
      next unless rejection.is_a?(String)

      raise Error, "#{registry_path}: entry #{p['file']} is declared in a form the athena:inbox reader refuses: " \
                   "#{rejection} (validator: ai/skills/athena:inbox/lib/descriptor.sh)"
    end
  end

  # The exact bytes an installed entry should contain.
  def render(entry)
    "#{JSON.pretty_generate(entry)}\n"
  end

  def mode_of(path)
    File.stat(path).mode & 0o777
  rescue StandardError
    nil
  end

  # Drift between the declared entries and what is on disk, as a list of
  # human-readable strings (empty == clean). Every string names the entry it is
  # about: these are all this machine owner's OWN declarations, so naming them
  # is not the cross-tenant disclosure the contract's refusal rules forbid — no
  # entry outside the committed list is opened, read, or named.
  def drift(entries = declared)
    problems = []

    rmode = mode_of(root)
    problems << format("the inbox root %s has mode %04o, expected %04o", root, rmode, ROOT_MODE) if rmode && rmode != ROOT_MODE

    dmode = mode_of(projects_dir)
    if dmode.nil?
      problems << "projects/ is missing at #{projects_dir}"
    elsif dmode != PROJECTS_DIR_MODE
      problems << format("projects/ has mode %04o, expected %04o", dmode, PROJECTS_DIR_MODE)
    end

    entries.each do |p|
      file = p["file"]
      path = entry_path(file)
      want = p["entry"]

      # lstat, never stat: a symlink where an entry belongs must be reported as
      # what it is, not silently followed to whatever it points at. The contract
      # makes O_NOFOLLOW + a regular-file check the substitution defence, and
      # path canonicalisation explicitly NOT it.
      stat = begin
        File.lstat(path)
      rescue SystemCallError
        nil
      end

      if stat.nil?
        problems << "#{file} is missing from projects/"
        next
      end

      unless stat.file?
        problems << "#{file} is not a regular file (it is a #{stat.ftype}); an entry must never be a symlink or special file"
        next
      end

      mode = stat.mode & 0o777
      problems << format("%s has mode %04o, expected %04o", file, mode, ENTRY_MODE) if mode != ENTRY_MODE

      begin
        have = JSON.parse(File.read(path))
      rescue JSON::ParserError => e
        problems << "#{file} is not valid JSON (#{e.message})"
        next
      end

      problems << "#{file} does not match the committed entry (differing key(s): #{diff_keys(want, have).join(', ')})" if have != want

      problems.concat(repo_identity_problems(file, want["repo"]))
    end

    problems
  end

  # Is this the machine the committed list describes? A declared repo that is
  # actually checked out here proves it, and that is the discriminator the
  # "absent root" case needs: without it, losing the whole root — a cleanup
  # sweep under ~/.local/share, a restored home — reads as "not this
  # environment, OK", which is the silent death this triad exists to close.
  def declared_repo_present?(entries)
    entries.any? { |p| File.exist?(p["entry"]["repo"]) }
  end

  # Top-level keys whose values differ (or are absent on one side) — enough to
  # point at the edit without dumping either document.
  def diff_keys(want, have)
    keys = (want.keys | (have.is_a?(Hash) ? have.keys : [])).sort
    differing = keys.reject { |k| have.is_a?(Hash) && have[k] == want[k] }
    differing.empty? ? ["<value order or type>"] : differing
  end

  # --- would the reader actually accept what we install? ---------------------
  #
  # The athena:inbox skill's `descriptor_validate` is the ONE validator for a
  # registry entry (allow-listed keys, path grammar, read != write, and the
  # rest). Reimplementing it here would give this repo two validators that can
  # disagree, and the disagreement would show up as an entry the installer is
  # happy to write and the reader refuses to load — a channel that is
  # configured, installed, and dark. So the committed entries are validated by
  # running that validator, not by a second copy of its rules.
  #
  # Skipped, not failed, where it genuinely cannot run — no bash, no jq, or the
  # skill is not present at all (a partial checkout, a container). That is the
  # same environment-safety rule as the rest of this check, and it is REPORTED
  # rather than assumed, because "validated" and "silently not validated" must
  # not read the same. A skill directory that exists WITHOUT its libs is a
  # different thing — a rename or a half-finished edit inside this repo — and
  # fails loudly instead.
  SKILL_LIBS = %w[err.sh names.sh descriptor.sh].freeze

  def skill_lib_dir
    File.join(repo_dir, "ai", "skills", "athena:inbox", "lib")
  end

  # :ok · :no_skill · :no_tools · :incomplete_skill
  def reader_validation_state
    return @reader_validation_state if defined?(@reader_validation_state)

    @reader_validation_state =
      if !File.directory?(skill_lib_dir)
        :no_skill
      elsif SKILL_LIBS.any? { |f| !File.file?(File.join(skill_lib_dir, f)) }
        :incomplete_skill
      elsif !system("command -v bash >/dev/null 2>&1 && command -v jq >/dev/null 2>&1")
        :no_tools
      else
        :ok
      end
  end

  def validation_note
    case reader_validation_state
    when :ok then nil
    when :no_skill then "entry validation skipped — ai/skills/athena:inbox/lib is not present in this checkout"
    when :no_tools then "entry validation skipped — bash and jq are needed to run the athena:inbox validator"
    end
  end

  # nil when the entry is acceptable, :skipped when it could not be validated
  # here, otherwise the reader's own refusal (first line).
  def reader_rejection(entry)
    case reader_validation_state
    when :no_skill, :no_tools then return :skipped
    when :incomplete_skill
      return "ai/skills/athena:inbox/lib is missing #{SKILL_LIBS.reject { |f| File.file?(File.join(skill_lib_dir, f)) }.join(', ')}, " \
             "so no entry can be validated"
    end

    script = "source ./err.sh; source ./names.sh; source ./descriptor.sh; descriptor_validate \"$(cat)\""
    out, status = Open3.capture2e("bash", "-c", script, chdir: skill_lib_dir, stdin_data: JSON.generate(entry))
    return nil if status.success?

    out.to_s.lines.first.to_s.strip
  rescue StandardError => e
    "the athena:inbox validator could not be run (#{e.class}: #{e.message})"
  end

  # Does the declared repo identity match what git on THIS machine says? A repo
  # that is not checked out here cannot be checked, and its absence is not
  # drift — the entry is still the right thing to install.
  #
  # Gated on the declared `.git` path EXISTING, not merely on its parent
  # directory: for a checkout laid out some other way, the parent may belong to
  # a different repo entirely, and comparing against that repo's common dir
  # would invent drift that is not there.
  def repo_identity_problems(file, declared_repo)
    return [] unless File.exist?(declared_repo)

    worktree = File.dirname(declared_repo)
    return [] unless File.directory?(worktree)

    actual = git_common_dir(worktree)
    return [] if actual.nil? || actual == declared_repo

    ["#{file} declares repo #{declared_repo}, but git in #{worktree} resolves to #{actual}"]
  end
end
