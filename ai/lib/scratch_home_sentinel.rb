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

  Violation = Struct.new(:tool, :home, :cwd)

  # Raised when the real HOME cannot anchor the comparison. The sentinel then
  # cannot tell a scratch HOME from the real one, which is "could not measure",
  # never "no violation".
  class SetupError < StandardError; end

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
      # then execs the next one on PATH. It never changes what the caller gets.
      real_home=#{real_home.shellescape}
      physical_home=#{physical_home.shellescape}
      self=${0%/*}
      name=${0##*/}
      if [ "${HOME-}" != "$real_home" ] && [ "${HOME-}" != "$physical_home" ]; then
        here=$(cd -P -- "${HOME:-/nonexistent-home}" 2>/dev/null && pwd)
        if [ "$here" != "$physical_home" ]; then
          printf '%s\\t%s\\t%s\\n' "$name" "${HOME-(unset)}" "$PWD" >> "$self/#{LOG}"
        fi
      fi
      IFS=: read -r -a entries <<< "${PATH-}"
      for d in "${entries[@]}"; do
        [ -n "$d" ] || d=.
        [ "$d" = "$self" ] && continue
        if [ -f "$d/$name" ] && [ -x "$d/$name" ]; then exec "$d/$name" "$@"; fi
      done
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
    dir = Dir.mktmpdir("harness-gate-sentinel-", tmp)
    File.write(File.join(dir, SCRIPT), script(home, physical))
    File.chmod(0o755, File.join(dir, SCRIPT))
    names(path).each { |n| File.symlink(SCRIPT, File.join(dir, n)) }
    dir
  end

  # The PATH a check runs with: the sentinel directory first.
  def path_with(dir, path)
    path.to_s.empty? ? dir : "#{dir}:#{path}"
  end

  def violations(dir)
    log = File.join(dir, LOG)
    return [] unless File.exist?(log)

    File.readlines(log, chomp: true).map { |l| Violation.new(*l.split("\t", 3)) }
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
