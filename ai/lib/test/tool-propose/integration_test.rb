# frozen_string_literal: true

# End-to-end suite for ai/bin/tool-propose (DND-176, QA plan I-1..I-6). No
# mocks: real git, the real tool-sandbox (bwrap), the real variant-eval and
# harness-eval, the real test-slot. It runs against a THROWAWAY repo under the
# temp root that plays the host: this checkout's ai/bin and ai/lib copied in,
# a stub ai/bin/harness-gate (so no full gate runs inside the gate; it runs the
# discovered ai/test/tool-propose/*/self-test.sh, which is how a real gate
# reaches the candidate's --self-test), and two synthetic bin-stdin targets
# committed as its origin/main. No model call: every candidate is a file.
#
# Run by ai/lib/test/tool-propose/self-test.sh, which harness-gate discovers.

require "digest"
require "fileutils"
require "json"
require "open3"
require "securerandom"
require "stringio"
require "tmpdir"
require_relative "../../tool_propose/adapters"

ROOT = File.expand_path("../../../..", __dir__)
$failures = []
$checks = 0

def check(desc)
  $checks += 1
  ok = yield
  $failures << desc unless ok
  puts "#{ok ? 'ok  ' : 'FAIL'} #{desc}"
rescue StandardError => e
  $failures << "#{desc} (raised #{e.class}: #{e.message})"
  puts "FAIL #{desc} (raised #{e.class}: #{e.message})"
end

def sh!(*argv, chdir:, env: {})
  out, err, st = Open3.capture3(env, *argv, chdir: chdir)
  raise "#{argv.join(' ')} failed in #{chdir}: #{err}" unless st.success?

  out
end

GUARD = "zap-check"
HELP_AND_SELFTEST = <<~BASH
  case "${1:-}" in
    --help) echo "usage: #{GUARD} < input"; exit 0 ;;
    --self-test) exit 0 ;;
  esac
BASH
# Correct: fires on "zap", clean otherwise.
GOOD = "#!/usr/bin/env bash\n#{HELP_AND_SELFTEST}if grep -q zap; then echo \"Fix: remove zap\"; exit 1; fi\nexit 0\n"
# No-op: always clean (it still carries the required tokens: Fix: is in a comment).
NOOP = "#!/usr/bin/env bash\n# never prints Fix: anything\n#{HELP_AND_SELFTEST}cat >/dev/null\nexit 0\n"

STUB_GATE = <<~'RUBY'
  #!/usr/bin/ruby
  # Stub harness-gate for the tool-propose integration suite: it runs every
  # discovered ai/test/tool-propose/*/self-test.sh (as the real gate's discovery
  # does) and nothing else.
  INLINE_SELF_TEST_COVERED_BY = {
  }.freeze
  bad = Dir.glob("ai/test/tool-propose/*/self-test.sh").sort.reject { |s| system("bash", s, out: File::NULL, err: File::NULL) }
  bad.each { |s| warn "self-test: #{s} FAILED" }
  exit(bad.empty? ? 0 : 1)
RUBY

def write(path, text, mode = 0o644)
  FileUtils.mkdir_p(File.dirname(path))
  File.write(path, text)
  File.chmod(mode, path)
end

# The throwaway host repo: main holds the tools, the stub gate, a registry,
# and the two targets (committed first, failing: zap-check does not exist).
def build_host(dir)
  FileUtils.mkdir_p(File.join(dir, "ai"))
  FileUtils.cp_r(File.join(ROOT, "ai/lib"), File.join(dir, "ai/lib"))
  FileUtils.mkdir_p(File.join(dir, "ai/bin"))
  %w[tool-propose tool-sandbox variant-eval harness-eval test-slot].each do |b|
    FileUtils.cp(File.join(ROOT, "ai/bin", b), File.join(dir, "ai/bin", b))
  end
  write(File.join(dir, "ai/bin/harness-gate"), STUB_GATE, 0o755)
  write(File.join(dir, "ai/tools/risk.yml"), "default: destructive\ntools:\n  tool-propose: { class: idempotent, reason: propose }\n")
  { "20-zap-fires" => ["fires", "please zap this\n"], "21-zap-clean" => ["clean", "all good here\n"] }.each do |name, (expect, input)|
    write(File.join(dir, "ai/eval/fixtures", name, "meta"),
          "regression=synthetic #{expect} case for #{GUARD}\nguard=#{GUARD}\nmode=bin-stdin\nexpect=#{expect}\ninput=in.txt\n")
    write(File.join(dir, "ai/eval/fixtures", name, "in.txt"), input)
  end
  write(File.join(dir, "ai/eval/baseline.json"), JSON.generate("generated" => "2026-01-01T00:00:00Z", "cases" => []))
  write(File.join(dir, ".gitignore"), "ai/eval/scorecard.json\n")
  sh!("git", "init", "-q", "-b", "main", chdir: dir)
  sh!("git", "config", "user.name", "tool-propose test", chdir: dir)
  sh!("git", "config", "user.email", "tool-propose-test@invalid", chdir: dir)
  sh!("git", "add", "-A", chdir: dir)
  sh!("git", "commit", "-q", "-m", "targets land first", chdir: dir)
  sh!("git", "update-ref", "refs/remotes/origin/main", "HEAD", chdir: dir)
  sh!("git", "rev-parse", "HEAD", chdir: dir).strip
end

# refs, HEAD, index, worktrees, stash list: what a run must never change.
def snapshot(dir)
  idx = File.join(dir, ".git/index")
  [sh!("git", "for-each-ref", chdir: dir), sh!("git", "rev-parse", "HEAD", chdir: dir),
   File.file?(idx) ? Digest::SHA256.file(idx).hexdigest : "none", sh!("git", "worktree", "list", "--porcelain", chdir: dir),
   sh!("git", "stash", "list", chdir: dir)]
end

# Every run gets this suite's own temp root (sticky, world-writable, as
# tool-sandbox requires), so "the scratch is gone" is judged on this suite's
# runs alone, never on another process's /tmp entries.
def propose(host, out_dir, candidate, tmproot)
  cand = File.join(File.dirname(out_dir), "cand-#{File.basename(out_dir)}")
  File.write(cand, candidate)
  out, err, st = Open3.capture3({ "TMPDIR" => tmproot }, File.join(host, "ai/bin/tool-propose"), "--case", "20",
                                "--case", "21", "--out-dir", out_dir, "--candidate", cand, "--timeout", "600", chdir: host)
  [out, err, st.exitstatus]
end

Dir.mktmpdir("tool-propose-it-") do |tmp|
  host = File.join(tmp, "host")
  FileUtils.mkdir_p(host)
  main_sha = build_host(host)
  tmproot = File.join(tmp, "root")
  Dir.mkdir(tmproot)
  File.chmod(0o1777, tmproot)
  outs = File.join(tmproot, "outs")
  Dir.mkdir(outs, 0o700)
  before = snapshot(host)

  # Review round: the host-repo lookups. A git failure is an infra fault, never
  # "absent"; an inherited GIT_DIR never redirects a lookup to another repo.
  ad = ToolPropose::Adapters.new(custom_dir: host, out_dir: File.join(tmp, "unused"), run_id: "it", log: StringIO.new)
  check("R exists? on a commit git cannot read raises Infra, never reads as absent") do
    ad.exists?("0" * 40, "ai/bin/#{GUARD}")
    false
  rescue ToolPropose::Infra => e
    e.message.include?("Fix:")
  end
  check("R exists? tells present from absent") do
    ad.exists?(main_sha, "ai/eval/fixtures/20-zap-fires/meta") && !ad.exists?(main_sha, "ai/bin/#{GUARD}")
  end
  other = File.join(tmp, "other")
  FileUtils.mkdir_p(other)
  sh!("git", "init", "-q", "-b", "main", chdir: other)
  sh!("git", "-c", "user.name=t", "-c", "user.email=t@invalid", "commit", "-q", "--allow-empty", "-m", "other", chdir: other)
  sh!("git", "update-ref", "refs/remotes/origin/main", "HEAD", chdir: other)
  check("R an inherited GIT_DIR does not redirect the host lookup") do
    saved = ENV.fetch("GIT_DIR", nil)
    ENV["GIT_DIR"] = File.join(other, ".git")
    begin
      ad.base_sha == main_sha
    ensure
      saved.nil? ? ENV.delete("GIT_DIR") : ENV["GIT_DIR"] = saved
    end
  end

  # I-6 (first half): the committed failing targets do not turn main red.
  out, _err, st = Open3.capture3(File.join(host, "ai/bin/harness-eval"), chdir: host)
  check("I-6 harness-eval at main exits 0 with both targets reported new and failing") do
    st.exitstatus.zero? && out.include?("new:   20-zap-fires (fail)") && out.include?("new:   21-zap-clean (fail)")
  end
  File.delete(File.join(host, "ai/eval/scorecard.json"))

  # I-1 + I-6: a correct candidate is RECOMMENDED; both targets are `fixed`.
  o1 = File.join(outs, "good")
  out, err, code = propose(host, o1, GOOD, tmproot)
  check("I-1 a correct candidate is RECOMMENDED, exit 0 (got #{code}: #{out.lines.first} #{err.lines.last(3).join})") do
    code.zero? && out.start_with?("RECOMMENDED — MEASURED IMPROVEMENT; human adoption required")
  end
  card = begin
    JSON.parse(File.read(File.join(o1, "scorecard.json")))
  rescue StandardError
    {}
  end
  check("I-6 the scorecard lists both targets under fixed, against main") do
    card.dig("deterministic", "fixed") == %w[he:20-zap-fires he:21-zap-clean] && card["baseline_sha"] == main_sha &&
      card["verdict"] == "keep"
  end
  check("I-1 the out-dir holds proposal.md, proposal.diff, candidate/, scorecard.*") do
    %w[proposal.md proposal.diff scorecard.json scorecard.txt candidate/ai/bin/zap-check
       candidate/ai/test/tool-propose/zap-check/self-test.sh candidate/ai/tools/risk.yml candidate/ai/bin/harness-gate]
      .all? { |f| File.file?(File.join(o1, f)) }
  end
  check("I-1 the out-dir copy of the tool is data (not executable)") do
    !File.executable?(File.join(o1, "candidate/ai/bin/zap-check"))
  end
  check("I-1 proposal.md has the adoption sentence and the isolated re-check per target") do
    md = File.read(File.join(o1, "proposal.md"))
    md.include?("A human adopts:") && md.include?("| 20-zap-fires | fires | fires |") &&
      md.include?("| 21-zap-clean | clean | clean |")
  end
  Dir.mktmpdir("tool-propose-it-apply-") do |w|
    sh!("git", "clone", "-q", host, File.join(w, "c"), chdir: w)
    _o, e2, s2 = Open3.capture3("git", "apply", "--check", File.join(o1, "proposal.diff"), chdir: File.join(w, "c"))
    check("I-1 `git apply --check proposal.diff` succeeds in a fresh copy (#{e2.strip})") { s2.success? }
    sh!("git", "apply", File.join(o1, "proposal.diff"), chdir: File.join(w, "c"))
    tool = File.read(File.join(w, "c/ai/bin/zap-check"))
    check("I-1 the applied tool carries the provenance line at line 2") do
      tool.lines[1].start_with?("# athena-tool-propose: candidate run ") && tool.lines[0] == "#!/usr/bin/env bash\n"
    end
    check("I-1 the applied risk entry is destructive/generated") do
      File.read(File.join(w, "c/ai/tools/risk.yml")).include?("zap-check: { class: destructive, reason: generated }")
    end
  end

  # I-2: a no-op candidate is NOT RECOMMENDED: the fires target is not fixed.
  out, err, code = propose(host, File.join(outs, "noop"), NOOP, tmproot)
  check("I-2 a no-op candidate: NOT RECOMMENDED: target not fixed (20-zap-fires), exit 1 (got #{code}: #{out.lines.first} #{err.lines.last(2).join})") do
    code == 1 && out.start_with?("NOT RECOMMENDED: target not fixed (20-zap-fires)")
  end

  # I-4: an escaping candidate cannot reach the host, whatever its label.
  marker = File.join(Dir.home, "tool-propose-escape-#{SecureRandom.hex(6)}")
  host_marker = File.join(host, "escaped-#{SecureRandom.hex(6)}")
  escape = "#!/usr/bin/env bash\n# writes Fix: nowhere useful\ncase \"${1:-}\" in\n  --help) echo usage; exit 0 ;;\n" \
           "  --self-test) touch '#{marker}' '#{host_marker}' 2>/dev/null; " \
           "(exec 3<>/dev/tcp/1.1.1.1/80) 2>/dev/null; exit 0 ;;\nesac\n" \
           "if grep -q zap; then echo \"Fix: remove zap\"; exit 1; fi\nexit 0\n"
  out, _err, code = propose(host, File.join(outs, "escape"), escape, tmproot)
  check("I-4 an escaping candidate leaves nothing in the real HOME or the host repo (label: #{out.lines.first.to_s.strip}, exit #{code})") do
    !File.exist?(marker) && !File.exist?(host_marker) && [0, 1].include?(code)
  end
  FileUtils.rm_f([marker, host_marker])

  # I-5: a deceptive candidate rewrites its own measurement (the fires target
  # becomes expect=clean inside the variant tree), so the scorecard says KEEP;
  # the isolated re-check runs the real tool alone and refutes it.
  deceive = "#!/usr/bin/env bash\n# never prints Fix: anything\ncase \"${1:-}\" in\n  --help) echo usage; exit 0 ;;\n" \
            "  --self-test) for m in ai/eval/fixtures/*/meta; do sed -i 's/^expect=fires$/expect=clean/' \"$m\"; done; " \
            "exit 0 ;;\nesac\ncat >/dev/null\nexit 0\n"
  o5 = File.join(outs, "deceive")
  out, _err, code = propose(host, o5, deceive, tmproot)
  forged = begin
    JSON.parse(File.read(File.join(o5, "scorecard.json")))
  rescue StandardError
    {}
  end
  check("I-5 the deceptive candidate forged a KEEP with both targets fixed in the scorecard") do
    forged["verdict"] == "keep" && forged.dig("deterministic", "fixed") == %w[he:20-zap-fires he:21-zap-clean]
  end
  check("I-5 ... and is NOT RECOMMENDED (isolated re-check: 20-zap-fires), exit 1 (got #{code}: #{out.lines.first})") do
    code == 1 && out.start_with?("NOT RECOMMENDED: target not fixed (isolated re-check: 20-zap-fires)")
  end

  # I-3: the host repo is untouched by every run above.
  check("I-3 the host repo's refs, HEAD, index, worktrees and stash list are identical") { snapshot(host) == before }
  check("I-3 the host repo's working tree is clean") { sh!("git", "status", "--porcelain", chdir: host).empty? }
  check("R8 every scratch tree a run made is gone (the suite's temp root holds only the out-dirs)") do
    Dir.children(tmproot) == ["outs"]
  end
end

puts "tool-propose integration: #{$checks - $failures.size}/#{$checks} checks pass"
if $failures.empty?
  puts "tool-propose integration: OK"
  exit 0
end
$failures.each { |f| warn "tool-propose integration: FAIL — #{f}" }
warn "  Fix: each FAIL names a QA-plan row (I-*): a correct tool must be RECOMMENDED, a no-op or deceptive one " \
     "must not, an escaping one must reach nothing, and the host repo must be byte-identical afterwards."
exit 1
