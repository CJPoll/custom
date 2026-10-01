# frozen_string_literal: true

# lead_time_config_io -- the SIDE EFFECTS and the MANAGER of the lead-time
# repo list (DND-1526). The rules are ai/lib/lead_time_config.rb (DOMAIN);
# this file only gathers the values those rules judge:
#
#   Files.facts  lstat/stat of the override candidate -> FileFacts
#   Files.read   the chosen config file's text
#   Git.probe    one configured repo path -> Probe (exists, git top, common dir)
#   resolve      the one resolution every reader uses: candidate -> locate ->
#                read -> parse -> probe each repo -> Resolution
#
# Read-only: it writes nothing anywhere. Every failure raises a
# LeadTimeConfig::Error (or CouldNotLook) carrying the Fix: the caller prints;
# a probe that could not run is never read as "not on this machine".

require "open3"
require_relative "lead_time_config"

module LeadTimeConfigIO
  C = LeadTimeConfig
  TRACKED = File.expand_path("../config/lead-time-repos.json", __dir__)
  # git reads these before -C; a value leaked from a hook or a parent git
  # would point every probe at the wrong repository.
  GIT_ENV_UNSET = %w[GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE GIT_OBJECT_DIRECTORY GIT_PREFIX].to_h { |k| [k, nil] }.freeze

  module Files
    module_function

    # -> FileFacts. Only ENOENT is "absent"; any other lstat failure (EACCES,
    # ENOTDIR) is present-but-unreadable, so it can never read as no override.
    def facts(path)
      begin
        File.lstat(path)
      rescue Errno::ENOENT
        return C::FileFacts.new(present: false)
      rescue SystemCallError => e
        return C::FileFacts.new(present: true, stat_error: e.class.name.split("::").last)
      end
      st = File.stat(path)
      C::FileFacts.new(present: true, regular: st.file?, uid: st.uid, mode: st.mode)
    rescue SystemCallError => e
      C::FileFacts.new(present: true, stat_error: e.class.name.split("::").last)
    end

    def read(location)
      File.read(location.path)
    rescue SystemCallError => e
      fix = location.source == "default" ? "restore ai/config/lead-time-repos.json from git" : "make #{location.path} readable, or remove it"
      raise C::CouldNotLook.new("cannot read the #{location.source} config #{location.path} (#{e.class.name.split('::').last})", fix)
    end
  end

  module Git
    module_function

    # -> Probe for one configured path. Only ENOENT is "not on this machine"
    # (a missing path, or a link to one); any other stat failure (EACCES on a
    # parent, ELOOP, EIO) raises CouldNotLook. File.exist? would answer false
    # for all of them and turn an unreachable checkout into a skip.
    def probe(path)
      begin
        lst = File.lstat(path)
      rescue Errno::ENOENT
        return C::Probe.new(path: path, exists: false, symlink: false)
      end
      symlink = lst.symlink?
      begin
        st = File.stat(path)
      rescue Errno::ENOENT
        return C::Probe.new(path: path, exists: false, symlink: symlink)
      end
      return C::Probe.new(path: path, exists: true, symlink: symlink, directory: false) unless st.directory?

      real = File.realpath(path)
      out, err, st = Open3.capture3(GIT_ENV_UNSET, "git", "-C", path, "rev-parse", "--path-format=absolute",
                                    "--show-toplevel", "--git-common-dir")
      lines = out.lines.map(&:strip)
      git_error = nil
      unless st.success? && lines.size == 2 && lines.all? { |l| l.start_with?("/") }
        git_error = err.strip.lines.first.to_s.strip
        git_error = "git rev-parse exited #{st.exitstatus} with no message" if git_error.empty?
      end
      C::Probe.new(path: path, exists: true, symlink: symlink, directory: true, realpath: real, git_error: git_error,
                   toplevel: lines[0], common_dir: lines[1])
    rescue SystemCallError => e
      raise C::CouldNotLook.new("could not probe #{path}: git or the filesystem failed (#{e.message})",
                                "make sure git is on PATH and #{path} is readable; this is not a missing checkout")
    end
  end

  module_function

  # MANAGER: the one resolution. -> LeadTimeConfig::Resolution, or raises
  # LeadTimeConfig::Error. A Resolution may hold zero repos; callers that need
  # one call require_any! (ai/bin/lead-time-repos) or find (a --repo reader).
  def resolve(env, tracked: TRACKED, euid: Process.euid)
    cand = C.candidate(env)
    location = C.locate(cand, Files.facts(cand.path), tracked: tracked, euid: euid)
    parsed = C.parse(Files.read(location), home: env["HOME"].to_s, path: location.path)
    probes = parsed.repos.to_h { |r| [r.name, Git.probe(r.path)] }
    C.resolve(location, parsed, probes)
  end
end
