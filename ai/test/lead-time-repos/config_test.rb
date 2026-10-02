# frozen_string_literal: true

# Deterministic suite for ai/lib/lead_time_config.rb (DOMAIN, DND-1526): the
# lead-time repo list's discovery, schema, presence and resolution rules. Run
# by `ai/bin/lead-time-repos --self-test` and ai/test/lead-time-repos/self-test.sh,
# which harness-gate discovers.
#
# Every input is a value: env hashes, file facts, git probes. No file, process
# or clock access. Functional only (DND-1222). Ids and paths are synthetic.

require "json"
require_relative "../../lib/lead_time_config"

C = LeadTimeConfig

$failures = []
$checks = 0

def check(desc)
  $checks += 1
  $failures << desc unless yield
rescue StandardError => e
  $failures << "#{desc} (raised #{e.class}: #{e.message})"
end

# -> the error raised (class and message), or nil when nothing raised.
def raised
  yield
  nil
rescue C::Error => e
  e
end

TRACKED = "/repo/ai/config/lead-time-repos.json"
EUID = 1000

def doc(repos, window: 20, epic: "epic-id") = JSON.generate("repos" => repos, "window" => window, "improvement_epic" => epic)

def repo(name, mode = "watch", path: "/src/#{name}", **extra) = { "name" => name, "path" => path, "mode" => mode }.merge(extra.transform_keys(&:to_s))

def facts(present: true, regular: true, uid: EUID, mode: 0o100644, stat_error: nil)
  C::FileFacts.new(present: present, regular: regular, uid: uid, mode: mode, stat_error: stat_error)
end

def probe(path, name, exists: true, directory: true, symlink: false, git_error: nil, toplevel: nil, common: nil)
  C::Probe.new(path: path, exists: exists, symlink: symlink, directory: directory, realpath: path,
               git_error: git_error, toplevel: toplevel || path, common_dir: common || "#{File.dirname(path)}/#{name}/.git")
end

# ── discovery: where to look ────────────────────────────────────────────────

check("D1 ATHENA_LEADTIME_CONFIG set is authoritative") do
  c = C.candidate("ATHENA_LEADTIME_CONFIG" => "/etc/x.json", "HOME" => "/home/u")
  c.kind == :env && c.path == "/etc/x.json"
end
check("D1 set but EMPTY is an error, never a fall-through") do
  e = raised { C.candidate("ATHENA_LEADTIME_CONFIG" => "", "HOME" => "/home/u") }
  e && e.message.include?("set but empty") && e.fix.include?("unset")
end
check("D1 set to a relative path is an error") do
  e = raised { C.candidate("ATHENA_LEADTIME_CONFIG" => "x.json", "HOME" => "/home/u") }
  e && e.message.include?("not an absolute path")
end
check("D2 no env: XDG_CONFIG_HOME/athena/lead-time-repos.json") do
  c = C.candidate("XDG_CONFIG_HOME" => "/cfg", "HOME" => "/home/u")
  c.kind == :xdg && c.path == "/cfg/athena/lead-time-repos.json"
end
check("D2 no XDG_CONFIG_HOME: HOME/.config") do
  C.candidate("HOME" => "/home/u").path == "/home/u/.config/athena/lead-time-repos.json"
end
check("D2 an empty XDG_CONFIG_HOME means unset (the XDG rule)") do
  C.candidate("XDG_CONFIG_HOME" => "", "HOME" => "/home/u").path == "/home/u/.config/athena/lead-time-repos.json"
end
check("D2 a relative XDG_CONFIG_HOME is an error, not ignored") do
  e = raised { C.candidate("XDG_CONFIG_HOME" => "cfg", "HOME" => "/home/u") }
  e && e.message.include?("XDG_CONFIG_HOME")
end
check("D4 HOME unset with no env path is an error") { raised { C.candidate({}) }&.message.to_s.include?("HOME") }
check("D4 HOME empty is an error") { raised { C.candidate("HOME" => "") }&.message.to_s.include?("HOME") }
check("D4 HOME relative is an error") { raised { C.candidate("HOME" => "home/u") }&.message.to_s.include?("HOME") }
check("D5 the retired LEAD_TIME_PHASES_CONFIG seam is an error, never silently ignored") do
  e = raised { C.candidate("LEAD_TIME_PHASES_CONFIG" => "/t/x.json", "HOME" => "/home/u") }
  e && e.message.include?("LEAD_TIME_PHASES_CONFIG") && e.fix.include?("ATHENA_LEADTIME_CONFIG")
end

# ── discovery: which file ───────────────────────────────────────────────────

XDG = C::Candidate.new(kind: :xdg, path: "/home/u/.config/athena/lead-time-repos.json")
ENVC = C::Candidate.new(kind: :env, path: "/t/repos.json")

check("D2 no override file: the tracked default, source=default") do
  l = C.locate(XDG, facts(present: false), tracked: TRACKED, euid: EUID)
  l.source == "default" && l.path == TRACKED
end
check("D2 an override present is read in place of the tracked file: source=override, its path") do
  l = C.locate(XDG, facts, tracked: TRACKED, euid: EUID)
  l.source == "override" && l.path == XDG.path
end
check("D1 the env path is the override") do
  l = C.locate(ENVC, facts, tracked: TRACKED, euid: EUID)
  l.source == "override" && l.path == ENVC.path
end
check("D1 the env path missing is an error, never the tracked default") do
  e = raised { C.locate(ENVC, facts(present: false), tracked: TRACKED, euid: EUID) }
  e && e.message.include?("does not exist") && e.fix.include?("ATHENA_LEADTIME_CONFIG")
end
check("D3 an override that cannot be stat'd (a dangling link) is an error, never 'no override'") do
  e = raised { C.locate(XDG, facts(stat_error: "ENOENT", regular: nil, uid: nil, mode: nil), tracked: TRACKED, euid: EUID) }
  e && e.message.include?("cannot be read") && e.fix.include?(XDG.path)
end
check("D3 an override that is not a regular file is an error") do
  raised { C.locate(XDG, facts(regular: false), tracked: TRACKED, euid: EUID) }&.message.to_s.include?("not a regular file")
end
check("D3 an override owned by another user is an error") do
  e = raised { C.locate(XDG, facts(uid: 0), tracked: TRACKED, euid: EUID) }
  e && e.message.include?("owned by uid 0")
end
check("D3 a group-writable override is an error naming its mode") do
  e = raised { C.locate(XDG, facts(mode: 0o100664), tracked: TRACKED, euid: EUID) }
  e && e.message.include?("0664") && e.fix.include?("chmod go-w")
end
check("D3 an other-writable override is an error") { raised { C.locate(XDG, facts(mode: 0o100646), tracked: TRACKED, euid: EUID) } }
check("D3 the env path gets the same file checks") { raised { C.locate(ENVC, facts(mode: 0o100666), tracked: TRACKED, euid: EUID) } }
check("D3 a 0600 override passes") { C.locate(XDG, facts(mode: 0o100600), tracked: TRACKED, euid: EUID).source == "override" }

# ── schema ──────────────────────────────────────────────────────────────────

def parse(text, home: "/home/u") = C.parse(text, home: home, path: "/x.json")

check("S1 a valid doc parses, ~/ expands") do
  p = parse(doc([repo("custom", "improve", path: "~/dev/custom")]))
  p.repos.first.path == "/home/u/dev/custom" && p.window == 20 && p.improvement_epic == "epic-id"
end
check("S2 malformed JSON is an error naming the file") do
  e = raised { parse("{nope") }
  e && e.message.include?("not valid JSON") && e.message.include?("/x.json")
end
check("S2 an unknown top-level key is an error") { raised { parse(JSON.generate(JSON.parse(doc([repo("a")])).merge("x" => 1))) }&.message.to_s.include?("unknown key") }
check("S2 an unknown repo key is an error") { raised { parse(doc([repo("a", x: 1)])) }&.message.to_s.include?("unknown key") }
check("S2 a bad mode is an error naming the repo") { raised { parse(doc([repo("a", "fix")])) }&.message.to_s.include?('"a" has unknown mode') }
check("S2 a missing key is an error") { raised { parse(doc([{ "name" => "a", "path" => "/a" }])) }&.message.to_s.include?("missing mode") }
check("S2 a duplicate name is an error") { raised { parse(doc([repo("a"), repo("a")])) }&.message.to_s.include?("listed 2 times") }
check("S2 a zero window is an error") { raised { parse(doc([repo("a")], window: 0)) }&.message.to_s.include?("window") }
check("S2 an empty repo list is an error") { raised { parse(doc([])) }&.message.to_s.include?("non-empty") }
check("S2 a relative path is an error") { raised { parse(doc([repo("a", path: "dev/a")])) }&.message.to_s.include?("not absolute") }
check("S2 a ~/ path with HOME unusable is an error, not a path under /") do
  raised { parse(doc([repo("a", path: "~/dev/a")]), home: "") }&.message.to_s.include?("HOME")
end
check("S2 a name that is not a plain name is an error") { raised { parse(doc([repo("../x")])) }&.message.to_s.include?("not a plain name") }
check("S3 product_epic absent falls back to improvement_epic, and says so") do
  r = parse(doc([repo("a")])).repos.first
  r.product_epic == "epic-id" && r.product_epic_source == "improvement_epic"
end
check("S3 product_epic present is carried") do
  r = parse(doc([repo("a", product_epic: "prod-epic")])).repos.first
  r.product_epic == "prod-epic" && r.product_epic_source == "repo"
end
check("S3 an empty product_epic is an error, never a silent fallback") { raised { parse(doc([repo("a", product_epic: " ")])) }&.message.to_s.include?("product_epic") }
check("S3 a non-string product_epic is an error") { raised { parse(doc([repo("a", product_epic: 7)])) } }
# idle_workflow (DND-1540): the post-merge workflow a product-repo landing
# must find idle (locked-merge --require-idle-workflow), or "none".
check("S5 idle_workflow absent is nil (undeclared), never a default") { parse(doc([repo("a")])).repos.first.idle_workflow.nil? }
check("S5 an idle_workflow file name is carried") do
  parse(doc([repo("a", "improve", idle_workflow: "post-merge.yml")])).repos.first.idle_workflow == "post-merge.yml"
end
check("S5 idle_workflow none is carried (declared: no post-merge workflow)") do
  parse(doc([repo("a", "improve", idle_workflow: "none")])).repos.first.idle_workflow == "none"
end
check("S5 an idle_workflow with a path, or blank, or not .yml, is an error") do
  ["../x.yml", " ", "deploy", 7].all? { |v| raised { parse(doc([repo("a", idle_workflow: v)])) }&.message.to_s.include?("idle_workflow") }
end

seed = C.parse(File.read(File.expand_path("../../config/lead-time-repos.json", __dir__)), home: "/home/u", path: "seed")
check("S4 the tracked default parses unchanged") { seed.repos.map { |r| [r.name, r.mode] } == [%w[custom improve], %w[gen_saas watch], %w[walt_ui watch]] }
check("S4 tracked paths expand ~/dev/<name>") { seed.repos.map(&:path) == %w[/home/u/dev/custom /home/u/dev/gen_saas /home/u/dev/walt_ui] }
check("S4 tracked window is 20, and no repo names a product_epic") { seed.window == 20 && seed.repos.all? { |r| r.product_epic_source == "improvement_epic" } }

# ── inheritance: an override entry over the tracked default (DND-1672) ──────

check("I0 only the per-user override inherits; the default and ATHENA_LEADTIME_CONFIG do not") do
  C.locate(XDG, facts, tracked: TRACKED, euid: EUID).inherits &&
    !C.locate(XDG, facts(present: false), tracked: TRACKED, euid: EUID).inherits &&
    !C.locate(ENVC, facts, tracked: TRACKED, euid: EUID).inherits
end
base = C.inheritable(doc([repo("a", idle_workflow: "none", product_epic: "pe"), repo("b", idle_workflow: "post-merge.yml"),
                          repo("gone", idle_workflow: "none")]), home: "/home/u", path: TRACKED)
def over(repos, inherit) = C.parse(doc(repos), home: "/home/u", path: "/o.json", inherit: inherit)
check("I1 an omitted idle_workflow is the tracked default's, never nil (the DND-1672 regression)") do
  r = over([repo("a", "improve")], base).repos.first
  r.idle_workflow == "none" && r.inherited.include?("idle_workflow")
end
check("I1 an omitted product_epic is the tracked default's, sourced to the repo") do
  r = over([repo("a")], base).repos.first
  r.product_epic == "pe" && r.product_epic_source == "repo" && r.inherited == %w[product_epic idle_workflow]
end
check("I2 a field the override declares wins, and is not named inherited") do
  r = over([repo("b", idle_workflow: "none")], base).repos.first
  r.idle_workflow == "none" && r.inherited.empty?
end
check("I2 the override's mode and path win: an override still changes a repo's mode") do
  r = over([repo("b", "improve", path: "/elsewhere/b")], base).repos.first
  r.mode == "improve" && r.path == "/elsewhere/b" && r.idle_workflow == "post-merge.yml"
end
check("I3 a repo the override drops does not come back") { over([repo("a")], base).repos.map(&:name) == %w[a] }
check("I3 a repo only the override names inherits nothing") do
  r = over([repo("new")], base).repos.first
  r.idle_workflow.nil? && r.inherited.empty? && r.product_epic_source == "improvement_epic"
end
# One valid sample per optional repo key. A key added to REPO_OPTIONAL without
# a sample here fails I4, so its inheritance is proven when it is added.
OPTIONAL_SAMPLE = { "product_epic" => "pe", "idle_workflow" => "none" }.freeze
check("I4 every optional repo key is inheritable, so a field added later cannot vanish on a machine") do
  every = C.inheritable(doc([repo("a", **OPTIONAL_SAMPLE.transform_keys(&:to_sym))]), home: "/home/u", path: TRACKED)
  r = over([repo("a")], every).repos.first
  OPTIONAL_SAMPLE.keys.sort == C::REPO_OPTIONAL.sort && r.inherited.sort == C::REPO_OPTIONAL.sort
end
check("I5 a tracked default that does not parse is an error naming the tracked file, never 'nothing to inherit'") do
  e = raised { C.inheritable("{nope", home: "/home/u", path: TRACKED) }
  e && e.message.include?(TRACKED)
end
check("I6 no inheritance: every repo's inherited list is empty") { parse(doc([repo("a")])).repos.first.inherited == [] }
check("I7 the tracked default itself parses as an inheritance source") do
  C.inheritable(File.read(File.expand_path("../../config/lead-time-repos.json", __dir__)), home: "/home/u", path: "seed")
   .entries["custom"] == { "idle_workflow" => "none" }
end

# ── presence ────────────────────────────────────────────────────────────────

A = C::Repo.new(name: "custom", path: "/src/custom", mode: "improve", product_epic: "e", product_epic_source: "improvement_epic")

check("P1 a git repo whose main-checkout basename is the name is present") { C.presence(A, probe("/src/custom", "custom")).nil? }
check("P1 a linked worktree of the named main checkout is present") do
  C.presence(A, probe("/src/custom", "custom", common: "/main/custom/.git")).nil?
end
check("P2 a missing path is SKIPPED with its path and reason, never an error") do
  s = C.presence(A, probe("/src/custom", "custom", exists: false))
  s.is_a?(C::Skip) && s.name == "custom" && s.path == "/src/custom" && s.reason.include?("no such path")
end
check("P2 a dangling symlink is skipped and named as such") do
  C.presence(A, probe("/src/custom", "custom", exists: false, symlink: true)).reason.include?("dangling symlink")
end
check("P3 a path that is not a directory is an error") { raised { C.presence(A, probe("/src/custom", "custom", directory: false)) }&.message.to_s.include?("not a directory") }
check("P3 a directory that is not a git repository is an error, not a skip") do
  e = raised { C.presence(A, probe("/src/custom", "custom", git_error: "not a git repository")) }
  e && e.message.include?("not a git repository") && e.fix.include?("custom")
end
check("P3 a path inside a repo but not its top is an error") do
  raised { C.presence(A, probe("/src/custom", "custom", toplevel: "/src")) }&.message.to_s.include?("not the top")
end
check("P4 a basename that differs from the name is an error (telemetry would join nothing)") do
  e = raised { C.presence(A, probe("/src/custom", "custom", common: "/src/other/.git")) }
  e && e.message.include?("other") && e.message.include?("telemetry")
end
check("P4 repo_label is the main checkout's basename") { C.repo_label("/home/u/dev/custom/.git") == "custom" }

# ── resolve ─────────────────────────────────────────────────────────────────

LOC = C::Location.new(path: TRACKED, source: "default")
three = parse(doc([repo("custom", "improve"), repo("gen_saas"), repo("walt_ui")]))
all_here = three.repos.to_h { |r| [r.name, probe(r.path, r.name)] }

check("R1 every repo present: all resolve, none skipped") do
  res = C.resolve(LOC, three, all_here)
  res.repos.map(&:name) == %w[custom gen_saas walt_ui] && res.skipped.empty? && res.considered == 3
end
gone = all_here.merge("walt_ui" => probe("/src/walt_ui", "walt_ui", exists: false))
res = C.resolve(LOC, three, gone)
check("R2 a missing checkout is skipped by name and counted; the rest resolve") do
  res.repos.map(&:name) == %w[custom gen_saas] && res.skipped.map(&:name) == %w[walt_ui] && res.considered == 3
end
check("R3 find: a resolved repo") { res.find("custom").mode == "improve" }
check("R3 find: a configured but skipped repo says 'skipped on this machine', distinct from not configured") do
  e = raised { res.find("walt_ui") }
  e.is_a?(C::Skipped) && e.message.include?("skipped on this machine") && e.message.include?("no such path")
end
check("R3 find: an unconfigured repo is NotConfigured, naming the configured repos") do
  e = raised { res.find("nope") }
  e.is_a?(C::NotConfigured) && e.message.include?("custom, gen_saas, walt_ui")
end
none = all_here.transform_values { |p| probe(p.path, "x", exists: false) }
check("R4 zero repos left: require_any! raises NoRepos") do
  e = raised { C.resolve(LOC, three, none).require_any! }
  e.is_a?(C::NoRepos) && e.message.include?("no configured repo is checked out on this machine")
end
check("R4 a missing probe is an error, never a silent skip") { raised { C.resolve(LOC, three, all_here.except("gen_saas")) }&.message.to_s.include?("gen_saas") }
check("R5 to_h carries the --json shape") do
  h = res.to_h
  h.keys == %w[source path inherits_from window improvement_epic repos skipped considered] &&
    h["repos"].first.keys == %w[name path mode product_epic product_epic_source idle_workflow inherited] &&
    h["skipped"].first.keys == %w[name path reason] && h["considered"] == 3
end

# ── a change repo's path (DND-1528) ─────────────────────────────────────────

own = C.own_repo("/home/u/dev/custom/.git")
check("O1 own_repo: the main checkout above an absolute <checkout>/.git, labelled by its basename") do
  own.path == "/home/u/dev/custom" && own.label == "custom" && own.error.nil?
end
check("O1 own_repo from a linked worktree's common dir is still the main checkout") do
  C.own_repo("/home/u/dev/custom/.git").path == "/home/u/dev/custom"
end
check("O2 own_repo: a relative common dir is an error value, never a path") do
  o = C.own_repo(".git")
  o.path.nil? && o.error.include?("not absolute")
end
check("O2 own_repo: a bare common dir (no /.git) is an error value") do
  o = C.own_repo("/srv/custom.git")
  o.path.nil? && o.error.include?("not <checkout>/.git")
end
check("O2 own_repo: no common dir (git failed) carries the reason") do
  o = C.own_repo(nil, why: "git rev-parse failed")
  o.path.nil? && o.error == "git rev-parse failed"
end

laptop = C.resolve(LOC, parse(doc([repo("gen_saas", "improve")])), { "gen_saas" => probe("/src/gen_saas", "gen_saas") })
check("C1 a configured, present repo resolves to its configured path") { res.path_for("gen_saas", own) == "/src/gen_saas" }
check("C2 the runner's own repo resolves on a machine that does not configure it") do
  laptop.path_for("custom", own) == "/home/u/dev/custom"
end
check("C2 a configured repo wins over the own-repo rule (the config path is validated as that checkout)") do
  res.path_for("custom", own) == "/src/custom"
end
check("C3 a name neither configured nor the runner's own is refused (Unresolved), naming both") do
  e = raised { laptop.path_for("walt_ui", own) }
  e.is_a?(C::Unresolved) && e.message.include?("walt_ui") && e.message.include?("gen_saas") &&
    e.message.include?("custom") && e.fix.include?("walt_ui")
end
check("C3 a configured repo skipped on this machine is refused (Unresolved), never a path") do
  e = raised { res.path_for("walt_ui", own) }
  e.is_a?(C::Unresolved) && e.message.include?("skipped on this machine") && e.message.include?("no such path")
end
check("C4 the own repo could not be looked at: CouldNotLook for an unconfigured name, never 'not configured'") do
  e = raised { laptop.path_for("custom", C.own_repo(nil, why: "git rev-parse failed")) }
  e.is_a?(C::CouldNotLook) && e.message.include?("git rev-parse failed")
end
check("C4 ... and a configured name still resolves without it") do
  laptop.path_for("gen_saas", C.own_repo(nil, why: "git rev-parse failed")) == "/src/gen_saas"
end
check("C5 an empty name is refused, never matched") { raised { laptop.path_for("", own) }.is_a?(C::Unresolved) }

if $failures.empty?
  puts "lead-time-repos: #{$checks} checks passed"
  exit 0
end
$failures.each { |f| puts "FAIL #{f}" }
puts "lead-time-repos: #{$failures.size} of #{$checks} checks failed"
exit 1
