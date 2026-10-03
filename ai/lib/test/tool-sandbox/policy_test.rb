# frozen_string_literal: true

# Deterministic suite for ai/lib/tool_sandbox/policy.rb (DND-1426): the pure
# domain of ai/bin/tool-sandbox. No IO, no bwrap, no git. Facts (realpaths,
# lstat results) are fed in, so every case can feed a WRONG key and assert the
# named refusal. Run by ai/lib/test/tool-sandbox/self-test.sh, which
# harness-gate discovers. Case ids (P*, A*, X*) are the DND-1426 QA plan's.

require_relative "../../tool_sandbox/policy"

$failures = []
$checks = 0

def check(desc)
  $checks += 1
  $failures << desc unless yield
rescue StandardError => e
  $failures << "#{desc} (raised #{e.class}: #{e.message})"
end

def raises?(klass, pattern = nil)
  yield
  false
rescue klass => e
  pattern.nil? || e.message.match?(pattern)
end

P = ToolSandbox::Policy
ROOT = "/tmp"

# A healthy directory fact; each case overrides one field to make it wrong.
def facts(path, **over)
  base = { path: path, realpath: path, exists: true, directory: true, symlink: false, owned: true,
           git_entry: :none, empty: false, lstat_error: nil, holds_mirror: false }
  P::Facts.new(**base.merge(over))
end

def err?(result, pattern)
  result[0] == :error && result[1].match?(pattern)
end

# ---------------------------------------------------------------------------
# validate_tmp_root
# ---------------------------------------------------------------------------
check("T-1 a sticky world-writable /tmp is the root") { P.validate_tmp_root(realpath: "/tmp", mode: 0o41777) == [:ok, "/tmp"] }
check("T-2 a root that is not sticky+world-writable is refused (TMPDIR=$HOME cannot widen it)") do
  err?(P.validate_tmp_root(realpath: "/home/u", mode: 0o40755), %r{/home/u.*sticky})
end
check("T-3 / as the root is refused") { err?(P.validate_tmp_root(realpath: "/", mode: 0o41777), /filesystem root/) }
check("T-4 an empty/relative root is refused") do
  err?(P.validate_tmp_root(realpath: "", mode: 0o41777), /absolute/) &&
    err?(P.validate_tmp_root(realpath: "tmp", mode: 0o41777), /absolute/) &&
    err?(P.validate_tmp_root(realpath: nil, mode: 0o41777), /could not be resolved/)
end

# ---------------------------------------------------------------------------
# validate_dir (P-1 .. P-7, plus the socket / ownership / root-itself refusals)
# ---------------------------------------------------------------------------
check("P-1 absolute dir under the tmp root") do
  P.validate_dir(facts("/tmp/x/w"), tmp_root: ROOT, role: :work) == [:ok, "/tmp/x/w"]
end
check("P-2 relative path names 'not absolute'") do
  err?(P.validate_dir(facts("w"), tmp_root: ROOT, role: :work), /not absolute/)
end
check("P-3 a path outside the tmp root names the root") do
  err?(P.validate_dir(facts("/home/u/dev/custom"), tmp_root: ROOT, role: :work), %r{outside the temp root /tmp})
end
check("P-4 a symlink resolving outside names the resolved path") do
  r = P.validate_dir(facts("/tmp/link", realpath: "/home/u/.claude", symlink: true), tmp_root: ROOT, role: :work)
  err?(r, %r{/home/u/\.claude})
end
check("P-4b an intermediate symlink component resolving outside is refused on its realpath") do
  err?(P.validate_dir(facts("/tmp/a/w", realpath: "/home/u/w"), tmp_root: ROOT, role: :work), %r{/home/u/w})
end
check("P-4c a symlink leaf is refused even when it resolves inside the root") do
  err?(P.validate_dir(facts("/tmp/link", realpath: "/tmp/real", symlink: true), tmp_root: ROOT, role: :work),
       /symlink/)
end
check("P-5 empty string and nil are errors, never ok") do
  err?(P.validate_dir(facts(""), tmp_root: ROOT, role: :work), /empty/) &&
    err?(P.validate_dir(facts(nil), tmp_root: ROOT, role: :work), /empty/)
end
check("P-5b a nil realpath (key could not be resolved) is an error, never ok") do
  err?(P.validate_dir(facts("/tmp/w", realpath: nil), tmp_root: ROOT, role: :work), /could not be resolved/)
end
check("P-6 prefix trick: /tmpfoo is not under /tmp (component compare)") do
  err?(P.validate_dir(facts("/tmpfoo/w"), tmp_root: ROOT, role: :work), /outside the temp root/)
end
check("P-6b the tmp root itself is refused (it would bind every other process's /tmp entries)") do
  err?(P.validate_dir(facts("/tmp"), tmp_root: ROOT, role: :work), /is the temp root itself/)
end
check("P-7 a work dir whose .git is a file (linked worktree) names 'linked worktree'") do
  err?(P.validate_dir(facts("/tmp/w", git_entry: :file), tmp_root: ROOT, role: :work), /linked worktree/)
end
check("P-7b a work dir whose .git is a directory (a full clone) is fine") do
  P.validate_dir(facts("/tmp/w", git_entry: :dir), tmp_root: ROOT, role: :work)[0] == :ok
end
check("P-8 a missing work dir is refused, naming the path") do
  err?(P.validate_dir(facts("/tmp/w", exists: false, realpath: nil), tmp_root: ROOT, role: :work), %r{/tmp/w.*does not exist})
end
check("P-9 a regular file is not a directory") do
  err?(P.validate_dir(facts("/tmp/f", directory: false), tmp_root: ROOT, role: :out), /not a directory/)
end
check("P-10 a socket/fifo/device beneath the dir is refused, naming it (a bound socket is host command execution)") do
  r = P.validate_contents(path: "/tmp/w", role: :work, special: "/tmp/w/tmux-1000/default")
  err?(r, %r{socket, fifo, device.*/tmp/w/tmux-1000/default})
end
check("P-10b only the explicit :clean passes the contents check; nil (a walk that did not run) is refused") do
  P.validate_contents(path: "/tmp/w", role: :work, special: :clean) == [:ok, "/tmp/w"] &&
    err?(P.validate_contents(path: "/tmp/w", role: :work, special: nil), /did not report/) &&
    err?(P.validate_contents(path: "/tmp/w", role: :out, special: ""), /did not report/)
end
check("P-11 a dir owned by another uid is refused") do
  err?(P.validate_dir(facts("/tmp/w", owned: false), tmp_root: ROOT, role: :out), /not owned/)
end
check("P-12 every refusal names the path it judged") do
  r = P.validate_dir(facts("/tmpfoo/w"), tmp_root: ROOT, role: :out)
  r[1].include?("/tmpfoo/w") && r[1].include?("--out")
end
check("P-14 a path that cannot be inspected (EACCES) is a named path refusal, not an internal error") do
  err?(P.validate_dir(facts("/tmp/x/w", exists: false, realpath: nil, lstat_error: "EACCES"), tmp_root: ROOT,
                      role: :work), %r{/tmp/x/w cannot be inspected \(EACCES\)})
end
check("P-15 a --work or --out that holds an origin.git mirror (a DEST) is refused") do
  err?(P.validate_dir(facts("/tmp/c", holds_mirror: true), tmp_root: ROOT, role: :work), /origin\.git mirror/) &&
    err?(P.validate_dir(facts("/tmp/c", holds_mirror: true), tmp_root: ROOT, role: :out), /origin\.git mirror/)
end
check("P-16 the contents message names hardlinks too") do
  err?(P.validate_contents(path: "/tmp/w", role: :work, special: "/tmp/w/f (hardlinked, 2 links)"), /hardlink/)
end
check("P-13 an unknown role raises (a wrong key is not a default)") do
  raises?(ArgumentError) { P.validate_dir(facts("/tmp/w"), tmp_root: ROOT, role: :nope) }
end

# DEST (prepare-clone): may not exist (its parent's realpath + basename is the key), or be empty.
check("D-1 a new DEST under the root is ok") do
  P.validate_dir(facts("/tmp/c", exists: false, realpath: "/tmp/c", directory: false), tmp_root: ROOT, role: :dest) ==
    [:ok, "/tmp/c"]
end
check("D-2 an existing empty DEST is ok") do
  P.validate_dir(facts("/tmp/c", empty: true), tmp_root: ROOT, role: :dest) == [:ok, "/tmp/c"]
end
check("D-3 (C-5) a non-empty DEST is refused") do
  err?(P.validate_dir(facts("/tmp/c", empty: false), tmp_root: ROOT, role: :dest), /not empty/)
end
check("D-4 a DEST whose parent resolves outside the root is refused") do
  err?(P.validate_dir(facts("/tmp/l/c", exists: false, realpath: "/home/u/c", directory: false),
                      tmp_root: ROOT, role: :dest), /outside the temp root/)
end

# ---------------------------------------------------------------------------
# validate_disjoint: no bound dir may overlap another
# ---------------------------------------------------------------------------
check("O-1 separate work, out and origin are ok") do
  P.validate_disjoint(work: "/tmp/c/repo", out: "/tmp/o", origin: "/tmp/c/origin.git")[0] == :ok
end
check("O-2 --out equal to the origin mirror is refused (it would make /origin writable)") do
  err?(P.validate_disjoint(work: "/tmp/c/repo", out: "/tmp/c/origin.git", origin: "/tmp/c/origin.git"), /overlap/)
end
check("O-3 --out containing, or inside, the origin mirror is refused") do
  err?(P.validate_disjoint(work: "/tmp/c/repo", out: "/tmp/c", origin: "/tmp/c/origin.git"), /overlap/) &&
    err?(P.validate_disjoint(work: "/tmp/c/repo", out: "/tmp/c/origin.git/objects", origin: "/tmp/c/origin.git"), /overlap/)
end
check("O-4 --out equal to or inside --work is refused") do
  err?(P.validate_disjoint(work: "/tmp/w", out: "/tmp/w"), /overlap/) &&
    err?(P.validate_disjoint(work: "/tmp/w", out: "/tmp/w/o"), /overlap/)
end
check("O-5 prefix names are not overlap (/tmp/w vs /tmp/w2)") do
  P.validate_disjoint(work: "/tmp/w", out: "/tmp/w2")[0] == :ok
end
check("O-6 work alone is ok") { P.validate_disjoint(work: "/tmp/w")[0] == :ok }

# ---------------------------------------------------------------------------
# validate_timeout (A-6)
# ---------------------------------------------------------------------------
check("A-6 timeout 0 and 7201 are refused; 1 and 7200 are ok") do
  err?(P.validate_timeout(0), /1-7200/) && err?(P.validate_timeout(7201), /1-7200/) &&
    P.validate_timeout(1) == [:ok, 1] && P.validate_timeout(7200) == [:ok, 7200]
end
check("A-6b a nil timeout is the default 1800") { P.validate_timeout(nil) == [:ok, 1800] }

# ---------------------------------------------------------------------------
# top_links: /bin /lib /lib64 /sbin mirror the host's merged-/usr symlinks
# ---------------------------------------------------------------------------
MERGED = { "/bin" => "usr/bin", "/lib" => "usr/lib", "/lib64" => "usr/lib64", "/sbin" => "usr/bin" }.freeze
check("L-1 a merged-/usr host's links are mirrored") do
  P.top_links(MERGED) == [:ok, [%w[usr/bin /bin], %w[usr/lib /lib], %w[usr/lib64 /lib64], %w[usr/bin /sbin]]]
end
check("L-2 (A3) an absent /lib64 emits no link") do
  P.top_links(MERGED.merge("/lib64" => :absent))[1].none? { |_, name| name == "/lib64" }
end
check("L-3 an absolute /usr/... target is normalised to relative") do
  P.top_links(MERGED.merge("/bin" => "/usr/bin"))[1].include?(%w[usr/bin /bin])
end
check("L-4 a real /bin directory (not merged-/usr) is refused, never bound") do
  err?(P.top_links(MERGED.merge("/bin" => :not_symlink)), %r{/bin is not a symlink into /usr})
end
check("L-5 a link leaving /usr is refused") do
  err?(P.top_links(MERGED.merge("/lib" => "../home/u")), %r{/lib}) && err?(P.top_links(MERGED.merge("/lib" => "opt/lib")), %r{/lib})
end
check("L-6 a missing key is refused (a wrong key is not an empty result)") do
  err?(P.top_links(MERGED.reject { |k, _| k == "/sbin" }), %r{/sbin})
end

# ---------------------------------------------------------------------------
# argv (A-1 .. A-5)
# ---------------------------------------------------------------------------
TOOLS = { timeout: "/usr/bin/timeout", prlimit: "/usr/bin/prlimit", bwrap: "/usr/bin/bwrap" }.freeze
LINKS = P.top_links(MERGED)[1]
def build(**over)
  P.argv(**{ tools: TOOLS, links: LINKS, work: "/tmp/c/repo", out: "/tmp/o", origin: "/tmp/c/origin.git",
             timeout: 60, status_fd: 3, cmd: %w[ai/bin/harness-gate],
             hard_limits: { cpu: nil, fsize: nil, nofile: nil } }.merge(over))
end

def pairs(argv, flag, arity)
  out = []
  argv.each_with_index { |a, i| out << argv[i + 1, arity] if a == flag }
  out
end

# Only the bwrap options (before its `--`), so a CMD word never counts as an option.
def bwrap_opts(argv)
  b = argv.index("/usr/bin/bwrap")
  argv[b..(b + argv[b..].index("--") - 1)]
end

full = build
check("A-1 hardening flags present") do
  o = bwrap_opts(full)
  %w[--unshare-all --clearenv --die-with-parent --new-session].all? { |f| o.include?(f) } &&
    pairs(o, "--cap-drop", 1) == [["ALL"]]
end
check("A-1 the timeout wraps everything") { full[0, 3] == ["/usr/bin/timeout", "--kill-after=10", "60"] }
check("A-1 prlimit carries the limits and precedes bwrap") do
  pi = full.index("/usr/bin/prlimit")
  full[pi, 6] == ["/usr/bin/prlimit", "--cpu=60", "--fsize=1073741824", "--nofile=1024", "--core=0", "--"] &&
    full[pi + 6] == "/usr/bin/bwrap"
end
check("A-1 the net namespace is never shared") { !full.include?("--share-net") }
# A nested tool-sandbox (the sandboxed gate runs the escape probes) inherits
# its parent's hard limits; prlimit cannot raise a hard limit, so asking for
# more than the parent holds must lower the request, never fail the sandbox.
check("A-8 limits never exceed the caller's hard limits (a nested run cannot raise them)") do
  a = build(timeout: 1800, hard_limits: { cpu: 1400, fsize: 1_000, nofile: 512 })
  pi = a.index("/usr/bin/prlimit")
  a[pi, 5] == ["/usr/bin/prlimit", "--cpu=1400", "--fsize=1000", "--nofile=512", "--core=0"] &&
    a[0, 3] == ["/usr/bin/timeout", "--kill-after=10", "1800"]
end
check("A-8 an unlimited (nil) or higher hard limit leaves the policy's own limits") do
  a = build(timeout: 60, hard_limits: { cpu: nil, fsize: nil, nofile: 4096 })
  pi = a.index("/usr/bin/prlimit")
  a[pi, 5] == ["/usr/bin/prlimit", "--cpu=60", "--fsize=1073741824", "--nofile=1024", "--core=0"]
end
check("A-8 a malformed hard limit raises (a wrong key is not 'unlimited')") do
  raises?(ArgumentError, /hard limit/) { build(hard_limits: { cpu: "x", fsize: nil, nofile: nil }) } &&
    raises?(ArgumentError, /hard limit/) { build(hard_limits: { cpu: nil }) } &&
    raises?(ArgumentError, /hard limit/) { build(hard_limits: { cpu: 0, fsize: nil, nofile: nil }) }
end
check("A-2 the --setenv names are exactly ENV_ALLOWLIST, with its values") do
  pairs(bwrap_opts(full), "--setenv", 2).to_h == P::ENV_ALLOWLIST
end
check("A-2 ENV_ALLOWLIST is the PRD's seven variables") do
  P::ENV_ALLOWLIST.keys.sort == %w[HOME LANG PATH TERM TMPDIR XDG_CACHE_HOME XDG_STATE_HOME]
end
check("A-3 every bind source is /usr, /etc, work, out or origin") do
  o = bwrap_opts(full)
  srcs = (pairs(o, "--bind", 2) + pairs(o, "--ro-bind", 2)).map(&:first)
  srcs.sort == ["/etc", "/tmp/c/origin.git", "/tmp/c/repo", "/tmp/o", "/usr"].sort
end
check("A-3 /usr, /etc and origin are read-only; only work and out are writable") do
  o = bwrap_opts(full)
  pairs(o, "--bind", 2).sort == [["/tmp/c/repo", "/work"], ["/tmp/o", "/out"]].sort &&
    pairs(o, "--ro-bind", 2).sort == [["/etc", "/etc"], ["/tmp/c/origin.git", "/origin"], ["/usr", "/usr"]].sort
end
check("A-3 /home, /run, /var, /tmp, / are never a bind source") do
  o = bwrap_opts(full)
  srcs = (pairs(o, "--bind", 2) + pairs(o, "--ro-bind", 2) + pairs(o, "--dev-bind", 2)).map(&:first)
  (srcs & ["/", "/home", "/run", "/var", "/tmp", "/var/run", "/proc", "/dev", "/sys"]).empty? &&
    %w[--dev-bind --bind-try --ro-bind-try --dev-bind-try --bind-fd --ro-bind-fd --share-net].none? { |f| o.include?(f) }
end
check("A-3 fresh /proc, /dev, tmpfs /tmp, sandbox HOME; cwd /work; status on the given fd") do
  o = bwrap_opts(full)
  pairs(o, "--proc", 1) == [["/proc"]] && pairs(o, "--dev", 1) == [["/dev"]] && pairs(o, "--tmpfs", 1) == [["/tmp"]] &&
    pairs(o, "--dir", 1) == [["/home/sandbox"]] && pairs(o, "--chdir", 1) == [["/work"]] &&
    pairs(o, "--json-status-fd", 1) == [["3"]]
end
check("A-3 /tmp is a sticky world-writable tmpfs (so a nested tool-sandbox finds a valid temp root)") do
  o = bwrap_opts(full)
  o[o.index("--tmpfs") - 2, 2] == %w[--perms 1777]
end
check("A-3 the links are emitted as --symlink") do
  pairs(bwrap_opts(full), "--symlink", 2) == LINKS
end
no_extra = build(out: nil, origin: nil)
check("A-4 no out, no origin: no /out and no /origin bind") do
  !no_extra.include?("/out") && !no_extra.include?("/origin") && !no_extra.include?("/tmp/o")
end
semi = build(cmd: ["/usr/bin/echo", "a; rm -rf /", "$(x)"])
check("A-5 CMD is the argv tail after bwrap's --, one element each; no shell added") do
  b = semi.index("/usr/bin/bwrap")
  tail = semi[(b + semi[b..].index("--") + 1)..]
  tail == ["/usr/bin/echo", "a; rm -rf /", "$(x)"] && !semi.include?("sh") && !semi.include?("-c")
end
check("A-6 argv refuses an out-of-range timeout") do
  raises?(ArgumentError, /1-7200/) { build(timeout: 0) } && raises?(ArgumentError, /1-7200/) { build(timeout: 7201) }
end
check("A-7 argv refuses an empty CMD") { raises?(ArgumentError, /CMD/) { build(cmd: []) } }
check("A-7 argv refuses a relative bind source (validated realpaths only)") do
  raises?(ArgumentError, /absolute/) { build(work: "repo") } && raises?(ArgumentError, /absolute/) { build(out: "o") }
end
check("A-7 argv refuses a relative tool path (never a PATH lookup)") do
  raises?(ArgumentError, /absolute/) { build(tools: TOOLS.merge(bwrap: "bwrap")) }
end

# ---------------------------------------------------------------------------
# parse_status + classify_exit (X-1 .. X-4)
# ---------------------------------------------------------------------------
START = %({ "child-pid": 12, "net-namespace": 4026 }\n)
check("S-1 child-pid then exit-code: started, exit read") do
  P.parse_status(START + %({ "exit-code": 3 }\n)) == { started: true, exit_code: 3 }
end
check("S-2 child-pid only: started, no exit (exec failed, or bwrap killed)") do
  P.parse_status(START) == { started: true, exit_code: nil }
end
check("S-3 empty stream: never started") { P.parse_status("") == { started: false, exit_code: nil } }
check("S-4 a malformed stream is 'not started', never a verdict") do
  P.parse_status(%({ "child-pid": 12 }\n{ "exit-code": 0 )) == { started: false, exit_code: nil } &&
    P.parse_status(%({ "exit-code": 0 }\n)) == { started: false, exit_code: nil }
end

# classify_exit's clock and signal facts; a helper so each case names only what it varies.
def cls(status:, started: true, exit_code: nil, elapsed: 5, timeout: 60, interrupted: nil)
  P.classify_exit(status: status, started: started, exit_code: exit_code, elapsed: elapsed, timeout: timeout,
                  interrupted: interrupted)
end

check("X-1 a child's exit 0 / 1 / 3 passes through (bwrap's own 1 is not the child's)") do
  [0, 1, 3].all? { |n| cls(status: n, exit_code: n) == [:pass, n] }
end
check("X-1b a child that itself exits 124 passes through; it is not a timeout") do
  cls(status: 124, exit_code: 124, elapsed: 60) == [:pass, 124]
end
check("X-2 the wall timeout fired: no exit record, 124 or 137, and the wall time reached --timeout") do
  cls(status: 124, elapsed: 60) == [:timeout] && cls(status: 137, elapsed: 70.5) == [:timeout]
end
check("X-2b a 137 with no exit record BEFORE --timeout (an external KILL, OOM) is not a timeout") do
  r = cls(status: 137, elapsed: 3)
  r[0] == :setup && r[1].include?("exit 137")
end
check("X-2c a missing clock fact is never a timeout") { cls(status: 124, elapsed: nil)[0] == :setup }
check("X-3 bwrap failed before the child started -> :setup (125), even on status 1") do
  r = cls(status: 1, started: false)
  r[0] == :setup && r[1].include?("never started")
end
check("X-3b started, no exit record, not a timeout status -> :setup (a bind failed or CMD could not be executed)") do
  r = cls(status: 1)
  r[0] == :setup && r[1].match?(/could not be executed/)
end
check("X-4 a child killed by signal 9 is 137") { cls(status: 137, exit_code: 137) == [:pass, 137] }
check("X-6 a TERM tool-sandbox forwarded is :interrupted, not a setup failure") do
  cls(status: 143, interrupted: "TERM") == [:interrupted, "TERM"] &&
    cls(status: 124, elapsed: 60, interrupted: "INT") == [:interrupted, "INT"]
end
check("X-6b a child that finished before the interrupt keeps its own exit") do
  cls(status: 0, exit_code: 0, interrupted: "TERM") == [:pass, 0]
end
check("X-6c an unknown forwarded signal raises (a wrong key is not 'no signal')") do
  raises?(ArgumentError, /forwarded signal/) { cls(status: 143, interrupted: "USR1") }
end
check("X-5 exit code for each outcome") do
  P.exit_code_for([:pass, 3]) == 3 && P.exit_code_for([:timeout]) == 124 && P.exit_code_for([:setup, "x"]) == 125 &&
    P.exit_code_for([:interrupted, "TERM"]) == 143 && P.exit_code_for([:interrupted, "INT"]) == 130
end

# ---------------------------------------------------------------------------
# validate_stdin (DND-176, S-1): --stdin FILE is a key, validated like --work
# ---------------------------------------------------------------------------
def sfacts(path, **over)
  base = { path: path, realpath: path, exists: true, regular: true, symlink: false, owned: true, nlink: 1,
           size: 10, lstat_error: nil }
  P::StdinFacts.new(**base.merge(over))
end

check("S-1 a regular file beneath the temp root is accepted, as its realpath") do
  P.validate_stdin(sfacts("/tmp/x/in", realpath: "/tmp/x/in"), tmp_root: ROOT) == [:ok, "/tmp/x/in"]
end
{
  "empty" => [sfacts(""), /empty/], "relative" => [sfacts("in"), /not absolute/],
  "missing" => [sfacts("/tmp/x/in", exists: false), /does not exist/],
  "a symlink" => [sfacts("/tmp/x/in", symlink: true), /symlink/],
  "outside the temp root" => [sfacts("/tmp/x/in", realpath: "/home/u/in"), /outside the temp root/],
  "a /tmpfoo sibling" => [sfacts("/tmpfoo/in", realpath: "/tmpfoo/in"), /outside the temp root/],
  "a directory or device" => [sfacts("/tmp/x/in", regular: false), /not a regular file/],
  "not ours" => [sfacts("/tmp/x/in", owned: false), /not owned/],
  "hardlinked" => [sfacts("/tmp/x/in", nlink: 2), /hardlinked/],
  "too big" => [sfacts("/tmp/x/in", size: P::STDIN_MAX_BYTES + 1), /over/],
  "an unknown size" => [sfacts("/tmp/x/in", size: nil), /over/],
  "uninspectable" => [sfacts("/tmp/x/in", lstat_error: "EACCES"), /EACCES/],
  "unresolvable" => [sfacts("/tmp/x/in", realpath: nil), /realpath/]
}.each do |what, (f, pattern)|
  check("S-1 --stdin #{what} is refused, named") { err?(P.validate_stdin(f, tmp_root: ROOT), pattern) }
end
check("S-1 --stdin adds no bind and no env to the argv (the file is fed by the host, never bound)") do
  argv = P.argv(tools: { timeout: "/usr/bin/timeout", prlimit: "/usr/bin/prlimit", bwrap: "/usr/bin/bwrap" },
                links: [], work: "/tmp/x/w", timeout: 10, status_fd: 3, cmd: ["/usr/bin/true"],
                hard_limits: { cpu: nil, fsize: nil, nofile: nil })
  !argv.include?("--stdin") && argv.count("--bind") == 1
end

if $failures.empty?
  puts "tool-sandbox policy: self-test OK (#{$checks} checks)"
  exit 0
end
$failures.each { |f| warn "tool-sandbox policy: FAIL -- #{f}" }
warn "tool-sandbox policy: self-test FAILED (#{$failures.size}/#{$checks})"
warn "  Fix: ai/lib/tool_sandbox/policy.rb drifted from the cases above. It is the only place a bind or an " \
     "environment variable is added to the sandbox: restore deny-by-default (no new bind source, no new --setenv, " \
     "no --share-net), or change a case only together with ai/docs/tool-sandbox.md."
exit 1
