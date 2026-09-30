# frozen_string_literal: true

# Integration suite for `ai/bin/tool-sandbox --prepare-clone` and the origin
# mirror it binds at /origin (DND-1426 QA plan, C-1..C-6). No mocks: a
# throwaway source repo with a synthetic origin, real git, real bwrap. No
# network, no model. Run by ai/lib/test/tool-sandbox/self-test.sh, which
# harness-gate discovers.

require "digest"
require "fileutils"
require "open3"
require "rbconfig"
require "tmpdir"

$failures = []
$checks = 0

# -> true when the case passed, so `check(...) || warn(detail)` prints detail on a failure only.
def check(desc)
  $checks += 1
  ok = yield ? true : false
  $failures << desc unless ok
  ok
rescue StandardError => e
  $failures << "#{desc} (raised #{e.class}: #{e.message})"
  false
end

TOOL = File.expand_path("../../../bin/tool-sandbox", __dir__)
GIT_ENV = {
  "GIT_AUTHOR_NAME" => "tool-sandbox-test", "GIT_AUTHOR_EMAIL" => "tool-sandbox-test@localhost",
  "GIT_COMMITTER_NAME" => "tool-sandbox-test", "GIT_COMMITTER_EMAIL" => "tool-sandbox-test@localhost",
  "GIT_CONFIG_GLOBAL" => "/dev/null", "GIT_CONFIG_NOSYSTEM" => "1"
}.freeze

def git(dir, *args)
  out, err, st = Open3.capture3(GIT_ENV, "git", "-C", dir, *args)
  raise "git #{args.join(' ')} failed in #{dir}: #{err}" unless st.success?

  out.strip
end

def tool(*args, chdir:)
  out, err, st = Open3.capture3(GIT_ENV, "/usr/bin/timeout", "120", RbConfig.ruby, TOOL, *args, chdir: chdir)
  [out, err, st.exitstatus]
end

# The source repo's state C-4 compares: refs, HEAD, index bytes, worktree list.
def fingerprint(src)
  [git(src, "for-each-ref", "--format=%(refname) %(objectname)"), git(src, "rev-parse", "HEAD"),
   Digest::SHA256.file(File.join(src, ".git/index")).hexdigest, git(src, "worktree", "list", "--porcelain")]
end

scratch = Dir.mktmpdir("tool-sandbox-clonetest-")
begin
  # A synthetic "remote" and a source checkout whose origin/main is S; the
  # source's own main moves past S and a side branch exists, so a clone that
  # reads the wrong ref, or carries other refs, is visible.
  upstream = File.join(scratch, "upstream.git")
  src = File.join(scratch, "src")
  git(scratch, "init", "--quiet", "--bare", "-b", "main", upstream)
  git(scratch, "init", "--quiet", "-b", "main", src)
  File.write(File.join(src, "a.txt"), "one\n")
  git(src, "add", "a.txt")
  git(src, "commit", "--quiet", "-m", "one")
  first = git(src, "rev-parse", "HEAD")
  File.write(File.join(src, "a.txt"), "two\n")
  git(src, "commit", "--quiet", "-am", "two")
  git(src, "remote", "add", "origin", upstream)
  git(src, "push", "--quiet", "origin", "main")
  git(src, "fetch", "--quiet", "origin")
  s = git(src, "rev-parse", "refs/remotes/origin/main")
  File.write(File.join(src, "a.txt"), "local-only\n")
  git(src, "commit", "--quiet", "-am", "local only, not on origin/main")
  git(src, "branch", "side")
  side_only = git(src, "rev-parse", "HEAD")

  before = fingerprint(src)
  dest = File.join(scratch, "c")
  out, err, code = tool("--prepare-clone", dest, chdir: src)
  repo = File.join(dest, "repo")
  origin = File.join(dest, "origin.git")

  check("C-1 prepare-clone exits 0 and prints repo= origin= sha=") do
    code.zero? && out.strip == "repo=#{File.realpath(repo)} origin=#{File.realpath(origin)} sha=#{s}"
  end || warn("  prepare-clone: exit #{code} out=#{out.inspect} err=#{err.inspect}")
  check("C-1 repo HEAD is S, detached") { git(repo, "rev-parse", "HEAD") == s && git(repo, "rev-parse", "--abbrev-ref", "HEAD") == "HEAD" }
  check("C-1 repo refs/remotes/origin/main is S") { git(repo, "rev-parse", "refs/remotes/origin/main") == s }
  check("C-1 repo's origin url is /origin") { git(repo, "remote", "get-url", "origin") == "/origin" }
  check("C-1 origin.git's only ref is refs/heads/main = S") do
    git(origin, "for-each-ref", "--format=%(refname) %(objectname)") == "refs/heads/main #{s}"
  end
  check("C-1 the host's local-only commit is not in the mirror") do
    _, _, st = Open3.capture3(GIT_ENV, "git", "-C", origin, "cat-file", "-e", "#{side_only}^{commit}")
    !st.success?
  end
  check("C-1 no alternates in either repo; repo/.git is a real directory") do
    !File.exist?(File.join(origin, "objects/info/alternates")) &&
      !File.exist?(File.join(repo, ".git/objects/info/alternates")) &&
      File.directory?(File.join(repo, ".git")) && !File.symlink?(File.join(repo, ".git"))
  end

  # C-2: offline ls-remote inside the sandbox answers S from the read-only mirror.
  out2, err2, code2 = tool("--work", repo, "--timeout", "60", "--", "/usr/bin/git", "ls-remote", "origin",
                           "refs/heads/main", chdir: scratch)
  check("C-2 `git ls-remote origin refs/heads/main` inside the sandbox prints S") do
    code2.zero? && out2.split("\t").first == s
  end || warn("  ls-remote: exit #{code2} out=#{out2.inspect} err=#{err2.inspect}")

  # C-3: the mirror is read-only inside.
  mirror_before = git(origin, "for-each-ref", "--format=%(refname) %(objectname)")
  _, err3, code3 = tool("--work", repo, "--timeout", "60", "--", "/usr/bin/git", "push", "origin", "HEAD:refs/heads/x",
                        chdir: scratch)
  check("C-3 a push to /origin fails inside and the host mirror is unchanged") do
    code3 != 0 && git(origin, "for-each-ref", "--format=%(refname) %(objectname)") == mirror_before
  end || warn("  push: exit #{code3} err=#{err3.inspect}")

  _, err3b, code3b = tool("--work", repo, "--out", origin, "--", "/usr/bin/git", "-C", "/out", "update-ref",
                          "refs/heads/main", "HEAD", chdir: scratch)
  check("C-3b --out naming the origin mirror is refused (125): /origin cannot be made writable through /out") do
    code3b == 125 && err3b.include?("overlap") &&
      git(origin, "for-each-ref", "--format=%(refname) %(objectname)") == mirror_before
  end

  check("C-4 the source repo is untouched (refs, HEAD, index, worktree list)") { fingerprint(src) == before }

  # C-5: a non-empty DEST is refused and nothing is cloned.
  busy = File.join(scratch, "busy")
  Dir.mkdir(busy)
  File.write(File.join(busy, "keep"), "x")
  _, err5, code5 = tool("--prepare-clone", busy, chdir: src)
  check("C-5 a non-empty DEST is refused (125, Fix:) and nothing is cloned") do
    code5 == 125 && err5.include?("not empty") && err5.include?("Fix:") && Dir.children(busy) == ["keep"]
  end

  # C-6: --sha not on origin/main is refused, naming the sha; a real ancestor is accepted.
  bad = File.join(scratch, "bad")
  _, err6, code6 = tool("--prepare-clone", bad, "--sha", side_only, chdir: src)
  check("C-6 --sha not on origin/main is refused, names the sha, leaves no DEST") do
    code6 == 125 && err6.include?(side_only) && err6.include?("Fix:") && !File.exist?(bad)
  end
  _, err6b, code6b = tool("--prepare-clone", File.join(scratch, "rev"), "--sha", "HEAD~1", chdir: src)
  check("C-6 --sha that is not a hex commit id is refused") { code6b == 125 && err6b.include?("not a hex commit id") }
  anc = File.join(scratch, "anc")
  out7, _, code7 = tool("--prepare-clone", anc, "--sha", first, chdir: src)
  check("C-6 an ancestor --sha is pinned: HEAD, origin/main and the mirror's main are all it") do
    code7.zero? && out7.include?("sha=#{first}") && git(File.join(anc, "repo"), "rev-parse", "HEAD") == first &&
      git(File.join(anc, "origin.git"), "rev-parse", "refs/heads/main") == first
  end
  check("C-6 commits after the pin are not in either repo (no 'future' objects ride along)") do
    [File.join(anc, "repo"), File.join(anc, "origin.git")].none? do |r|
      Open3.capture3(GIT_ENV, "git", "-C", r, "cat-file", "-e", "#{s}^{commit}")[2].success?
    end
  end

  # C-9: an inherited GIT_DIR (a git hook sets one) must not redirect the clone
  # into the caller's repo. The victim's main is NOT checked out, so a force
  # fetch into it would succeed silently if git honoured GIT_DIR.
  victim = File.join(scratch, "victim")
  git(scratch, "init", "--quiet", "-b", "other", victim)
  File.write(File.join(victim, "v"), "v")
  git(victim, "add", "v")
  git(victim, "commit", "--quiet", "-m", "victim")
  git(victim, "branch", "main")
  victim_before = git(victim, "for-each-ref", "--format=%(refname) %(objectname)")
  gd = File.join(scratch, "gd")
  out9, err9, code9 = Open3.capture3(GIT_ENV.merge("GIT_DIR" => File.join(victim, ".git"),
                                                   "GIT_WORK_TREE" => victim),
                                     "/usr/bin/timeout", "120", RbConfig.ruby, TOOL, "--prepare-clone", gd, chdir: src)
  check("C-9 an inherited GIT_DIR/GIT_WORK_TREE leaves the caller's repo untouched") do
    git(victim, "for-each-ref", "--format=%(refname) %(objectname)") == victim_before
  end
  check("C-9 ... and the clone is still built from this checkout's origin/main") do
    code9.exitstatus.zero? && out9.include?("sha=#{s}") && git(File.join(gd, "repo"), "rev-parse", "HEAD") == s
  end || warn("  GIT_DIR case: exit #{code9.exitstatus} out=#{out9.inspect} err=#{err9.inspect}")

  # C-7: a checkout without refs/remotes/origin/main is a named refusal, not an empty clone.
  lone = File.join(scratch, "lone")
  git(scratch, "init", "--quiet", "-b", "main", lone)
  File.write(File.join(lone, "a"), "a")
  git(lone, "add", "a")
  git(lone, "commit", "--quiet", "-m", "a")
  _, err8, code8 = tool("--prepare-clone", File.join(scratch, "lonec"), chdir: lone)
  check("C-7 no origin/main is refused (125), naming the ref") do
    code8 == 125 && err8.include?("refs/remotes/origin/main") && !File.exist?(File.join(scratch, "lonec"))
  end

  # C-8: a DEST outside the temp root is refused before anything is written.
  _, err9, code9 = tool("--prepare-clone", "/usr/tool-sandbox-clonetest", chdir: src)
  check("C-8 a DEST outside the temp root is refused (125)") { code9 == 125 && err9.include?("outside the temp root") }
ensure
  FileUtils.rm_rf(scratch)
end

if $failures.empty?
  puts "tool-sandbox clone: self-test OK (#{$checks} checks)"
  exit 0
end
$failures.each { |f| warn "tool-sandbox clone: FAIL -- #{f}" }
warn "tool-sandbox clone: self-test FAILED (#{$failures.size}/#{$checks})"
warn "  Fix: ai/lib/tool_sandbox/clone.rb (or the --prepare-clone path of ai/bin/tool-sandbox) no longer builds " \
     "the pinned pair the cases above describe: origin.git with main = SHA as its only ref, repo detached at SHA " \
     "with origin url /origin, no shared object store, and the source repo untouched."
exit 1
