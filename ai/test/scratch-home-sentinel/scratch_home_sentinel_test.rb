# frozen_string_literal: true

# Functional suite for ai/lib/scratch_home_sentinel.rb (DND-1316).
#
# Each case builds a fixture PATH: a fake version-manager shim directory
# (`.../shims`) whose `ruby` behaves like asdf's, exiting 126 unless HOME is
# the real one, and then runs a small fixture suite with the sentinel first on
# PATH, as harness-gate does. No case depends on timing: each asserts what the
# sentinel logged and what the fixture printed.
#
# The cases the ticket names:
#   * a suite that runs `ruby` through PATH under a scratch HOME is flagged,
#     even when it swallows the shim's exit 126 and exits 0 (DND-1203's
#     vacuous pass);
#   * a suite that resolves the real binary under the real HOME first passes.

require "open3"
require "tmpdir"
require "fileutils"
require "shellwords"
require_relative "../../lib/scratch_home_sentinel"

$pass = 0
$fail = 0
def check(label, cond, detail = nil)
  if cond
    $pass += 1
    puts "  ok   #{label}"
  else
    $fail += 1
    puts "  FAIL #{label}#{detail ? " -- #{detail}" : ''}"
  end
end

REAL_RUBY = "/usr/bin/ruby"

# A fake asdf: `shims/ruby` runs the real ruby only under `home`, else exits
# 126 with the shim's message, as asdf does with no version under HOME.
def fake_shims(root, home)
  shims = File.join(root, "fake-asdf", "shims")
  FileUtils.mkdir_p(shims)
  File.write(File.join(shims, "ruby"), <<~SH)
    #!/bin/bash
    [ "${HOME}" = #{home.shellescape} ] || { echo "No version is set for command ruby" >&2; exit 126; }
    exec #{REAL_RUBY} "$@"
  SH
  File.write(File.join(shims, "shimonly-tool"), "#!/bin/sh\necho shimonly \"$HOME\"\n")
  File.chmod(0o755, File.join(shims, "ruby"))
  File.chmod(0o755, File.join(shims, "shimonly-tool"))
  shims
end

# Runs `body` (bash) as a fixture suite with HOME=home and the sentinel on PATH.
def run_suite(root, body, home:, base_path:)
  sentinel = ScratchHomeSentinel.create(path: base_path, real_home: home, tmp: root)
  suite = File.join(root, "suite-#{File.basename(sentinel)}.sh")
  File.write(suite, "#!/bin/bash\nset -u\nscratch=#{File.join(root, 'scratch-home').shellescape}\n" \
                    "mkdir -p \"$scratch\"\n#{body}\n")
  File.chmod(0o755, suite)
  env = { "HOME" => home, "PATH" => ScratchHomeSentinel.path_with(sentinel, base_path) }
  out, status = Open3.capture2e(env, suite, chdir: root)
  [status, out, ScratchHomeSentinel.violations(sentinel), sentinel]
end

Dir.mktmpdir("scratch-home-sentinel-test") do |root|
  root = File.realpath(root)
  home = File.join(root, "real-home")
  FileUtils.mkdir_p(home)
  shims = fake_shims(root, home)
  base_path = "#{shims}:/usr/bin:/bin"

  # --- names --------------------------------------------------------------
  names = ScratchHomeSentinel.names(base_path)
  check("names: a FLOOR tool PATH provides is watched (ruby)", names.include?("ruby"), names.inspect)
  check("names: a tool only a shims dir provides is watched (shimonly-tool)",
        names.include?("shimonly-tool"), names.inspect)
  check("names: a FLOOR tool nothing on PATH provides is not watched",
        !ScratchHomeSentinel.names("#{root}/empty").include?("ruby"))
  check("names: a non-shims dir adds no names (bash, sh stay unwatched)",
        !names.include?("bash") && !names.include?("sh"), names.inspect)

  # --- the ticket's flagged case -----------------------------------------
  flagged_body = <<~SH
    # DND-1203's shape: bare ruby under a scratch HOME, failure swallowed.
    HOME="$scratch" ruby -e 'puts :booted' || echo "shim exit $?"
    exit 0
  SH
  status, out, v, = run_suite(root, flagged_body, home: home, base_path: base_path)
  check("flagged: the fixture suite itself exits 0 (the vacuous pass)", status.success?, out)
  check("flagged: the shim really died under the scratch HOME (exit 126)", out.include?("shim exit 126"), out)
  check("flagged: the sentinel logged `ruby` under the scratch HOME",
        v.size == 1 && v.first.tool == "ruby" && v.first.home == File.join(root, "scratch-home"),
        v.inspect)
  report = ScratchHomeSentinel.report(v, home)
  check("flagged: the report names the tool, the HOME and DND-1316",
        report.include?("`ruby` with HOME=#{File.join(root, 'scratch-home')}") && report.include?("DND-1316"),
        report)
  check("flagged: the report carries Fix:", report.include?("Fix:"), report)

  # --- the ticket's passing case -----------------------------------------
  resolved_body = <<~SH
    # Resolve the interpreter under the real HOME, then use it under the scratch one.
    R="$(ruby -e 'print RbConfig.ruby')" || exit 1
    HOME="$scratch" "$R" -e 'puts :booted'
  SH
  status, out, v, = run_suite(root, resolved_body, home: home, base_path: base_path)
  check("passes: resolving the real binary first runs and boots", status.success? && out.include?("booted"), out)
  check("passes: no violation logged", v.empty?, v.inspect)

  abs_body = %(HOME="$scratch" #{REAL_RUBY} -e 'puts :booted')
  status, out, v, = run_suite(root, abs_body, home: home, base_path: base_path)
  check("passes: an absolute /usr/bin/ruby under the scratch HOME", status.success? && v.empty?, "#{out} #{v.inspect}")

  # --- transparency: the sentinel never changes what the caller gets ------
  status, out, v, = run_suite(root, "ruby -e 'print ENV[%q(HOME)]'; echo; shimonly-tool",
                              home: home, base_path: base_path)
  check("transparent: under the real HOME the tool runs and nothing is logged",
        status.success? && out.include?(home) && out.include?("shimonly #{home}") && v.empty?,
        "#{out} #{v.inspect}")
  status, out, v, = run_suite(root, "HOME=\"$scratch\" shimonly-tool; echo rc=$?", home: home, base_path: base_path)
  check("transparent: a shim-dir tool still runs under the scratch HOME, and is logged",
        out.include?("shimonly #{File.join(root, 'scratch-home')}") && out.include?("rc=0") &&
        v.map(&:tool) == ["shimonly-tool"], "#{out} #{v.inspect}")
  status, out, v, = run_suite(root, "command -v ruby >/dev/null && echo found", home: home, base_path: base_path)
  check("transparent: command -v still finds the tool", out.include?("found") && v.empty?, out)
  status, out, v, = run_suite(root, "HOME=\"$scratch\" PATH=/usr/bin:/bin ruby -e 'puts :direct'",
                              home: home, base_path: base_path)
  check("named limit: a PATH rebuilt from a fixed list bypasses the sentinel (not logged)",
        status.success? && out.include?("direct") && v.empty?, "#{out} #{v.inspect}")

  status, out, v, = run_suite(root, "PATH=\"${PATH%%:*}\" ruby -e 0; echo rc=$?", home: home, base_path: base_path)
  check("named limit: a PATH left with only the sentinel exits 127 with a Fix:",
        out.include?("rc=127") && out.include?("Fix:") && v.empty?, "#{out} #{v.inspect}")

  # --- HOME spellings -----------------------------------------------------
  link = File.join(root, "home-link")
  File.symlink(home, link)
  status, out, v, = run_suite(root, "HOME=#{link.shellescape} ruby -e 0; HOME=#{home.shellescape}/ ruby -e 0",
                              home: home, base_path: base_path)
  check("HOME: a symlink or trailing slash to the real home is the real home", v.empty?, v.inspect)
  status, out, v, = run_suite(root, "unset HOME; ruby -e 0 2>/dev/null; true", home: home, base_path: base_path)
  check("HOME: an unset HOME is logged as (unset)", v.map(&:home) == ["(unset)"], v.inspect)

  # --- a HOME that cannot anchor the comparison is an error --------------
  %w[relative/home].push("").each do |bad|
    raised = begin
      ScratchHomeSentinel.create(path: base_path, real_home: bad, tmp: root)
      false
    rescue ScratchHomeSentinel::SetupError => e
      e.message.include?("absolute")
    end
    check("setup: real HOME #{bad.inspect} raises SetupError (could not measure, never 'no violation')", raised)
  end

  # --- cleanup ------------------------------------------------------------
  dir = ScratchHomeSentinel.create(path: base_path, real_home: home, tmp: root)
  ScratchHomeSentinel.remove(dir)
  check("remove: the sentinel directory is gone", !File.exist?(dir))
end

puts "scratch-home-sentinel: #{$pass} passed, #{$fail} failed"
if $fail.positive?
  puts "Fix: repair ai/lib/scratch_home_sentinel.rb so a PATH-resolved watched tool run under a HOME " \
       "other than the gate's is logged, and every other run is passed through untouched."
  exit 1
end
