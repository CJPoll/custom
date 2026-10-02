# frozen_string_literal: true

# SCRATCH-HOME SENTINEL (DND-1316).
#
# The hazard. A test that points HOME at a scratch directory and then runs a
# tool found through PATH gets, in an agent session, a version-manager shim
# (~/.asdf/shims/ruby). The shim resolves its install through HOME, finds none
# under the scratch one, and exits 126 with no output. DND-1203: every mock
# client of a suite-reaper case died that way, the suite waited out each ready
# bound (~835 s a gate), and the case PASSED having tested nothing. A cron
# lane's PATH has no shim, so the same suite was fast and honest there, and
# nothing said the two differ.
#
# The check. harness-gate runs every check with a fresh sentinel directory
# first on PATH. It holds one entry per watched tool name, each a symlink to
# one small bash script. When a check runs a watched tool through PATH, the
# sentinel runs first: if HOME is not the gate's own HOME, it appends one line
# (tool, HOME, cwd) to the directory's `violations` log. Either way it then
# execs the next `<tool>` on the check's PATH, so a check that keeps that PATH
# behaves exactly as it would without the sentinel. After the check exits the gate reads the log;
# any line FAILS the check with a Fix:, whatever the check's own exit status.
# The directory is per check, so a line names the check that caused it.
#
# It fires wherever the gate runs, not only where a shim is installed: the
# FLOOR names are watched on every machine that has them on PATH, so a cron
# lane catches `ruby` under a scratch HOME as surely as an agent session does.
# Every name in a PATH directory named `shims` (asdf, rbenv, pyenv, mise) is
# watched too, which adds the machine's own shimmed tools (glab, terraform...).
# A name nothing on PATH provides gets no sentinel. While a check keeps the
# PATH it was given, `command -v` answers as it would without the sentinel.
#
# Legitimate forms, which never reach the sentinel or pass it: an absolute path
# (/usr/bin/ruby, DND-931/958); an interpreter resolved under the real HOME
# first (`/usr/bin/ruby -e 'print RbConfig.ruby'`); a PATH the check builds
# itself with its own stub first; a call with HOME set back to the real home.
#
# A sentinel never execs another sentinel (a nested gate's, or its own
# directory under a second spelling): it skips them.
#
# A version manager's `system` fallback leads back to the sentinel (DND-1726).
# asdf with `ruby system` (this machine's ~/.tool-versions) execs the first
# `ruby` on PATH outside its shims dir, and that is the sentinel, which used to
# exec the shim again: an exec loop in one pid that burned CPU until the gate's
# timeout killed the check (DND-1697's judgment-eval, 1295 s). The sentinel
# records its exec chain in HARNESS_GATE_SENTINEL_CHAIN (pid, tool, sentinel,
# argv, and the entries it exec'd from a PATH dir named `shims`). An exec
# keeps the pid, and the fallback passes the same arguments, so a run with the
# same pid, tool, sentinel and argv is a re-entry: it skips those shims, logs
# nothing more, and execs the next tool, which is what the manager meant by
# `system`. With nothing left it exits 127 with a Fix:. A child process (new
# pid) or a re-exec with other arguments starts a fresh chain and goes
# through the shim as it would without the sentinel. Only a shim is skipped,
# so a real tool that re-execs itself still gets itself. The variable is
# inherited by every tool and child the check runs.
# Named limits: a tool that exec()s the same name through PATH, in its own
# pid, with identical arguments, skips the shim on that second pass (under an
# asdf real version it would get the next tool on PATH, not the shim's
# version). A version manager whose shim dir is not named `shims` is not
# skipped, so its `system` fallback still loops. A recycled pid that matches
# a stale chain on tool, sentinel and argv is read as a re-entry.
#
# A sentinel directory, script or log that is gone after the check (a check
# that deleted it) FAILS the check as "could not measure", never as clean.
#
# What it cannot see (named, not hidden): a check that rebuilds PATH from a
# fixed list (it drops the sentinel directory with the rest), a tool reached by
# an absolute path into a shim directory, and a tool name outside the watched
# set. Each passes with no log line. A check that drops a tool's provider from
# PATH but keeps the sentinel's directory still finds the sentinel with
# `command -v`, and running it exits 127 with a Fix:.
require "fileutils"
require "shellwords"
require "tmpdir"

module ScratchHomeSentinel
  # The tools asdf shims on this fleet's machines (~/.asdf/shims, measured
  # 2026-09-30). Watched on every machine where PATH provides them, shim or
  # not. python3 is not here: it is /usr/bin/python3 on these machines, and
  # the hook suites run it under a scratch HOME by design. Where a version
  # manager shims it, the `shims` directory adds it.
  FLOOR = %w[
    ruby gem bundle bundler irb erb rake
    node npm npx pnpm yarn
    elixir elixirc mix iex erl escript
    terraform glab
  ].freeze
  LOG = "violations"
  SCRIPT = ".sentinel"
  # The env var a sentinel records its exec chain in (DND-1726).
  CHAIN = "HARNESS_GATE_SENTINEL_CHAIN"

  Violation = Struct.new(:tool, :home, :cwd)

  # Raised when the sentinel cannot be built: a real HOME that cannot anchor
  # the comparison, or a directory that cannot be written. The check then
  # cannot be judged, which is "could not measure", never "no violation".
  class SetupError < StandardError; end

  # Raised when the sentinel directory, its script or its (pre-created) log is
  # gone after the check: whatever ran cannot be read, so it is not "none".
  class MeasureError < StandardError; end

  module_function

  def dirs(path)
    path.to_s.split(":").map { |d| d.empty? ? "." : d }
  end

  def executable?(file)
    File.file?(file) && File.executable?(file)
  end

  # The names to watch on `path`: FLOOR plus every executable in a `shims`
  # directory, kept only when some directory on `path` provides it.
  def names(path)
    entries = dirs(path)
    shimmed = entries.select { |d| File.basename(d) == "shims" && File.directory?(d) }.flat_map do |d|
      Dir.children(d).select { |n| executable?(File.join(d, n)) }
    rescue SystemCallError
      []
    end
    (FLOOR + shimmed).uniq.select { |n| entries.any? { |d| executable?(File.join(d, n)) } }.sort
  end

  def script(real_home, physical_home)
    <<~SH
      #!/bin/bash
      # harness-gate scratch-HOME sentinel (DND-1316, ai/lib/scratch_home_sentinel.rb).
      # Logs a PATH-resolved run of this tool under a HOME that is not the gate's,
      # then execs the next one on PATH. Its only change to what the caller gets:
      # a shim that resolves back here (DND-1726) is skipped, never exec'd again.
      real_home=#{real_home.shellescape}
      physical_home=#{physical_home.shellescape}
      self=${0%/*}
      name=${0##*/}
      # Re-entry in the same exec chain (DND-1726): a version manager's `system`
      # fallback execs the first <name> on PATH outside its shims dir, with the
      # same arguments, and that is this sentinel again. An exec keeps the pid,
      # so a chain recorded under this pid, name, sentinel and argv means the
      # shims exec'd before resolved back here: skip them, or sentinel and shim
      # exec each other forever. A child process (another pid) or a re-exec with
      # other arguments starts a fresh chain.
      me=$0
      [[ $me == /* ]] || me=$PWD/$me
      printf -v argv '%q ' "$@"
      reentry=
      visited=()
      if [ -n "${#{CHAIN}-}" ]; then
        mapfile -t chain <<< "${#{CHAIN}%$'\\n'}"
        if [ "${chain[0]-}" = "$$" ] && [ "${chain[1]-}" = "$name" ] && [ "${chain[2]-}" -ef "$me" ] &&
           [ "${chain[3]-}" = "$argv" ]; then
          reentry=1
          visited=("${chain[@]:4}")
        fi
      fi
      if [ -z "$reentry" ] && [ "${HOME-}" != "$real_home" ] && [ "${HOME-}" != "$physical_home" ]; then
        here=$(cd -P -- "${HOME:-/nonexistent-home}" 2>/dev/null && pwd)
        if [ "$here" != "$physical_home" ]; then
          printf '%s\\t%s\\t%s\\n' "$name" "${HOME-(unset)}" "$PWD" >> "$self/#{LOG}"
        fi
      fi
      # Split as bash does: the appended colon keeps a trailing empty entry (cwd).
      set -f; IFS=:
      path_="${PATH-}:"; entries=($path_)
      unset IFS; set +f
      for d in "${entries[@]}"; do
        [ -n "$d" ] || d=.
        # Skip every spelling of this sentinel (same file), or two spellings of
        # its directory would exec each other forever.
        [ "$d/$name" -ef "$0" ] && continue
        # Never exec another sentinel (a nested gate's): two sentinels that
        # each exec the other's first would loop forever. This one has logged.
        [ -e "$d/#{SCRIPT}" ] && [ "$d/$name" -ef "$d/#{SCRIPT}" ] && continue
        [ -f "$d/$name" ] && [ -x "$d/$name" ] || continue
        for v in "${visited[@]}"; do [ "$d/$name" -ef "$v" ] && continue 2; done
        # Only a shim is recorded, so only a shim is ever skipped: a real tool
        # that re-execs itself still gets itself, as it would without the sentinel.
        shim=()
        base=${d%/}
        [ "${base##*/}" = shims ] && shim=("$d/$name")
        printf -v #{CHAIN} '%s\\n' "$$" "$name" "$me" "$argv" "${visited[@]}" "${shim[@]}"
        export #{CHAIN}
        exec "$d/$name" "$@"
      done
      if [ -n "$reentry" ]; then
        printf 'harness-gate sentinel: %s resolved back to the sentinel through %s, and nothing else on PATH provides it (DND-1726)\\n' "$name" "${visited[*]}" >&2
        printf 'Fix: that is a version manager falling back to a system %s that is not installed; call the tool by absolute path (for Ruby, /usr/bin/ruby), or set the version manager to an installed version.\\n' "$name" >&2
        exit 127
      fi
      printf 'harness-gate sentinel: %s not found on PATH beyond %s\\n' "$name" "$self" >&2
      printf 'Fix: this check removed the directory that provides %s from PATH but kept the sentinel directory; build PATH from a fixed list instead, or keep the provider on it.\\n' "$name" >&2
      exit 127
    SH
  end

  # Builds a sentinel directory for `path` under `tmp` and returns it.
  def create(path:, real_home:, tmp: Dir.tmpdir)
    home = real_home.to_s
    unless home.start_with?("/")
      raise SetupError, "the gate's HOME is #{real_home.inspect}, not an absolute path, so a " \
                        "scratch HOME cannot be told from the real one"
    end

    physical = begin
      File.realpath(home)
    rescue SystemCallError
      home
    end
    dir = nil
    begin
      dir = Dir.mktmpdir("harness-gate-sentinel-", tmp)
      File.write(File.join(dir, SCRIPT), script(home, physical))
      File.chmod(0o755, File.join(dir, SCRIPT))
      File.write(File.join(dir, LOG), "")
      names(path).each { |n| File.symlink(SCRIPT, File.join(dir, n)) }
      dir
    rescue SystemCallError => e
      remove(dir)
      raise SetupError, "could not build the sentinel directory under #{tmp}: #{e.message}"
    end
  end

  # The PATH a check runs with: the sentinel directory first.
  def path_with(dir, path)
    path.to_s.empty? ? dir : "#{dir}:#{path}"
  end

  # The logged violations. The log is created empty with the directory, so a
  # missing directory, script or log raises MeasureError instead of reading as
  # "none".
  def violations(dir)
    missing = [dir, File.join(dir, SCRIPT), File.join(dir, LOG)].reject { |p| File.exist?(p) }
    raise MeasureError, "the sentinel lost #{missing.join(', ')} while the check ran" unless missing.empty?

    File.readlines(File.join(dir, LOG), chomp: true).map { |l| Violation.new(*l.split("\t", 3)) }
  rescue SystemCallError => e
    raise MeasureError, "could not read the sentinel log in #{dir}: #{e.message}"
  end

  def remove(dir)
    FileUtils.rm_rf(dir) if dir
  end

  # The FAIL text for a check's violations, with its Fix:.
  def report(violations, real_home)
    grouped = violations.group_by { |v| [v.tool, v.home] }
    lines = grouped.first(10).map do |(tool, home), vs|
      "  - `#{tool}` with HOME=#{home} (cwd #{vs.first.cwd}; #{vs.size} run#{vs.size == 1 ? '' : 's'})"
    end
    lines << "  - ... and #{grouped.size - 10} more tool/HOME pair(s)" if grouped.size > 10
    <<~TXT
      harness-gate: FAIL — this check ran a tool through PATH while HOME was not the gate's HOME (#{real_home}) (DND-1316):
      #{lines.join("\n")}
        In an agent session that tool is usually a version-manager shim (~/.asdf/shims/<tool>). A shim resolves its install through HOME, so under a scratch HOME it exits 126 with no output (DND-1203), and the suite can pass having tested nothing. The check's own verdict does not matter: a lane without shims passes it, an agent session does not.
        Fix: call the tool by absolute path (harness Ruby is /usr/bin/ruby, DND-931/958), or resolve the real binary under the real HOME before overriding HOME (`/usr/bin/ruby -e 'print RbConfig.ruby'`), or run that one call with HOME set back to the real home. Do not drop the sentinel from PATH to get past this.
    TXT
  end
end
