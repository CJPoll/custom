# frozen_string_literal: true

# Deterministic suite for ai/lib/athena_telemetry.rb (DND-1473). Run by
# ai/test/telemetry/self-test.sh, which harness-gate discovers.
#
# TDD order: the domain (pure), then the store, then the manager and the
# reader. Every store case runs in a temp dir through ATHENA_TELEMETRY_DIR,
# with the clock injected through ATHENA_TELEMETRY_NOW. Functional only
# (DND-1222): no sleeps, no timing, no load. The fork case checks that two
# writers' lines never interleave; it is a correctness case, not a load test.
# Fixture ids are synthetic.

require "json"
require "tmpdir"
require "fileutils"
require "stringio"
require "time"
require_relative "../../lib/athena_telemetry"

T = AthenaTelemetry

$failures = []
$checks = 0

def check(desc)
  $checks += 1
  $failures << desc unless yield
rescue StandardError => e
  $failures << "#{desc} (raised #{e.class}: #{e.message})"
end

FIXTURE_REGISTRY = JSON.generate(
  "v" => 1,
  "events" => {
    "fixture.run" => {
      "description" => "a fixture event",
      "attrs" => { "jobs" => "int", "wall" => "float", "ok" => "bool", "base" => "sha", "name" => "label" },
    },
  },
)
SHA = "0123456789abcdef0123456789abcdef01234567"
AT = Time.utc(2026, 10, 1, 5, 26, 35.123r)

def build(**over)
  T::Event.build(**{ name: "fixture.run", at: AT, duration_s: 126.4, unit: "DND-1463", unit_source: "branch",
                     repo: "custom", head: SHA, host: "box", pid: 12_345, attrs: { "jobs" => 8 } }.merge(over))
end

# ---------------------------------------------------------------------------
# Domain: Event.build / serialize
# ---------------------------------------------------------------------------

line, drops = build
check("build: every T1 field, in order") do
  line.keys == %w[v event at duration_s unit unit_source repo head host pid attrs] && drops.empty?
end
check("build: v is 1, at is UTC with ms") { line["v"] == 1 && line["at"] == "2026-10-01T05:26:35.123Z" }
check("build: the values pass through") do
  line["duration_s"] == 126.4 && line["unit"] == "DND-1463" && line["unit_source"] == "branch" &&
    line["repo"] == "custom" && line["head"] == SHA && line["host"] == "box" && line["pid"] == 12_345 &&
    line["attrs"] == { "jobs" => 8 }
end
check("build: a point event has duration_s null") { build(duration_s: nil)[0]["duration_s"].nil? }
check("build: an integer duration is a float") { build(duration_s: 2)[0]["duration_s"] == 2.0 }
check("build: a negative duration drops the event") { build(duration_s: -1) == [nil, ["duration_invalid"]] }
check("build: a non-numeric duration drops the event") { build(duration_s: "1.5") == [nil, ["duration_invalid"]] }
check("build: a non-Time at drops the event") { build(at: "2026-10-01") == [nil, ["at_invalid"]] }
check("build: a head that is not 40 hex reads null, counted") do
  l, d = build(head: "abc")
  l["head"].nil? && d == ["head_invalid"]
end
check("build: an at with a zone is written in UTC") do
  build(at: Time.new(2026, 10, 1, 1, 0, 0, "-04:00"))[0]["at"] == "2026-10-01T05:00:00.000Z"
end

full = build(attrs: { "jobs" => 8, "name" => "x" * 120 })[0]
check("serialize: one JSON object and a newline") do
  s, trunc = T::Event.serialize(full, max_bytes: 4096)
  s.end_with?("\n") && s.count("\n") == 1 && JSON.parse(s) == full && trunc == false
end
big = build(attrs: (1..60).to_h { |i| ["a#{i}", "y" * 100] })[0]
check("serialize: over the cap, attrs are cut and attrs_truncated is set; the core is intact") do
  s, trunc = T::Event.serialize(big, max_bytes: 4096)
  parsed = JSON.parse(s)
  core = %w[v event at duration_s unit unit_source repo head host pid]
  trunc == true && s.bytesize <= 4096 && parsed["attrs_truncated"] == true &&
    core.all? { |k| parsed[k] == big[k] } && parsed["attrs"].size < 60 && parsed["attrs"].key?("a1")
end
check("serialize: a core that alone exceeds the cap gives no line") do
  T::Event.serialize(big, max_bytes: 100) == [nil, true]
end

# ---------------------------------------------------------------------------
# Domain: Registry
# ---------------------------------------------------------------------------

REG = T::Registry.parse(FIXTURE_REGISTRY)

def registry_error(json)
  T::Registry.parse(json)
  nil
rescue T::RegistryError => e
  e.message
end

check("registry: malformed JSON raises RegistryError") { registry_error("{nope")&.include?("not JSON") }
check("registry: a wrong v names the key") { registry_error('{"v":2,"events":{}}')&.include?("v") }
check("registry: a bad attr type names the event and attr") do
  msg = registry_error('{"v":1,"events":{"a.b":{"description":"d","attrs":{"n":"str"}}}}')
  msg&.include?("a.b") && msg.include?("n") && msg.include?("str")
end
check("registry: a bad event name is named") do
  registry_error('{"v":1,"events":{"Bad":{"description":"d","attrs":{}}}}')&.include?("Bad")
end
check("registry: an event without a description is named") do
  registry_error('{"v":1,"events":{"a.b":{"attrs":{}}}}')&.include?("a.b")
end

check("registry: attrs_for gives an event's registered attrs, nil for an unknown event") do
  REG.attrs_for("fixture.run")&.fetch("jobs", nil) == "int" && REG.attrs_for("fixture.nope").nil?
end

check("filter: registered attrs of the right type are kept") do
  REG.filter("fixture.run", { "jobs" => 8, "wall" => 1.5, "ok" => true, "base" => SHA, "name" => "lbl" }) ==
    [{ "jobs" => 8, "wall" => 1.5, "ok" => true, "base" => SHA, "name" => "lbl" }, []]
end
check("filter: a float attr takes an integer as a float") do
  REG.filter("fixture.run", { "wall" => 2 }) == [{ "wall" => 2.0 }, []]
end
check("filter: an unregistered attr is dropped: attr_unregistered") do
  REG.filter("fixture.run", { "jobs" => 1, "argv" => "x" }) == [{ "jobs" => 1 }, ["attr_unregistered"]]
end
check("filter: a wrong type is dropped: attr_type") do
  REG.filter("fixture.run", { "jobs" => "8", "ok" => 1, "base" => "abc" }) == [{}, %w[attr_type attr_type attr_type]]
end
check("filter: a bool is not an int") { REG.filter("fixture.run", { "jobs" => true }) == [{}, ["attr_type"]] }
check("filter: a 121-character label is dropped: label_too_long") do
  REG.filter("fixture.run", { "name" => "x" * 121 }) == [{}, ["label_too_long"]]
end
check("filter: a 120-character label is kept") { REG.filter("fixture.run", { "name" => "x" * 120 })[1].empty? }
check("filter: a label with a newline is dropped: label_newline") do
  REG.filter("fixture.run", { "name" => "a\nb" }) == [{}, ["label_newline"]]
end
check("filter: an unregistered event builds nothing: event_unregistered") do
  REG.filter("nope.run", { "jobs" => 1 }) == [nil, ["event_unregistered"]]
end
check("coerce: CLI strings become the registered types") do
  REG.coerce("fixture.run", { "jobs" => "8", "wall" => "1.5", "ok" => "false", "name" => "x", "zz" => "1" }) ==
    { "jobs" => 8, "wall" => 1.5, "ok" => false, "name" => "x", "zz" => "1" }
end
check("coerce: an unconvertible value stays a string, so filter drops it") do
  c = REG.coerce("fixture.run", { "jobs" => "eight" })
  REG.filter("fixture.run", c) == [{}, ["attr_type"]]
end

real = File.expand_path("../../telemetry/events.json", __dir__)
check("registry: ai/telemetry/events.json parses") { T::Registry.parse(File.read(real)).is_a?(T::Registry) }
check("registry: it holds the events the emitter tickets need") do
  names = T::Registry.parse(File.read(real)).event_names
  %w[harness_gate.run harness_gate.check test_slot.wait critic.round integration_gate.run merge.lock_wait
     merge.landed ticket.dispatched mission.status telemetry.probe].all? { |n| names.include?(n) }
end

# ---------------------------------------------------------------------------
# Domain: Unit.parse (with the ticket-ref parser lead-time uses)
# ---------------------------------------------------------------------------

PARSER = T::TicketRefs.parser
check("unit: the lead-time ticket-ref parser loads") { PARSER.respond_to?(:call) }
check("unit: env_unit wins: source env") do
  T::Unit.parse(branch: "dnd-1463-receipt-base", env_unit: "DND-7", ticket_ref: PARSER)[0, 2] == ["DND-7", "env"]
end
check("unit: an explicit unit wins over env") do
  T::Unit.parse(branch: "x", env_unit: "DND-7", explicit: "DND-9", ticket_ref: PARSER)[0, 2] == ["DND-9", "explicit"]
end
check("unit: a ticket branch gives the ticket: source branch") do
  T::Unit.parse(branch: "dnd-1463-receipt-base", env_unit: nil, ticket_ref: PARSER)[0, 2] == ["DND-1463", "branch"]
end
check("unit: an unticketed branch gives its name: source branch-name") do
  T::Unit.parse(branch: "harness-tidy", env_unit: nil, ticket_ref: PARSER)[0, 2] == ["harness-tidy", "branch-name"]
end
check("unit: a word shaped like a ticket is not one") do
  T::Unit.parse(branch: "fix-utf-8", env_unit: nil, ticket_ref: PARSER)[0, 2] == ["fix-utf-8", "branch-name"]
end
check("unit: no branch gives null: source none") do
  T::Unit.parse(branch: nil, env_unit: nil, ticket_ref: PARSER)[0, 2] == [nil, "none"]
end
check("unit: a detached HEAD gives null: source none") do
  T::Unit.parse(branch: "HEAD", env_unit: "", ticket_ref: PARSER)[0, 2] == [nil, "none"]
end
check("unit: an env unit with a newline is ignored and counted") do
  T::Unit.parse(branch: "harness-tidy", env_unit: "a\nb", ticket_ref: PARSER) == ["harness-tidy", "branch-name", ["unit_invalid"]]
end
check("unit: no parser (it failed to load) counts and falls back to the branch name") do
  T::Unit.parse(branch: "dnd-1463-x", env_unit: nil, ticket_ref: nil) == ["dnd-1463-x", "branch-name", ["unit_parser_unavailable"]]
end

# ---------------------------------------------------------------------------
# Domain: Retention.expired
# ---------------------------------------------------------------------------

check("retention: 30 days at 2026-10-31 drops 2026-09-30, keeps 2026-10-01, ignores other files") do
  names = %w[2026-09-30.jsonl 2026-10-01.jsonl 2026-10-31.jsonl write-failures notes.txt 2026-13-40.jsonl]
  T::Retention.expired(names, now: Time.utc(2026, 10, 31, 12), days: 30) == ["2026-09-30.jsonl"]
end

# ---------------------------------------------------------------------------
# Store and manager (a temp dir through ATHENA_TELEMETRY_DIR)
# ---------------------------------------------------------------------------

def with_store
  Dir.mktmpdir("telemetry-test") do |tmp|
    T.reset_process_state!
    yield File.join(tmp, "telemetry"), tmp
  ensure
    FileUtils.chmod_R(0o700, tmp) if File.exist?(tmp)
  end
end

def env_for(dir, now: "2026-10-01T05:00:00.000Z", **extra)
  { "ATHENA_TELEMETRY_DIR" => dir, "ATHENA_TELEMETRY_NOW" => now }.merge(extra)
end

def lines_in(path)
  File.exist?(path) ? File.readlines(path).map { |l| JSON.parse(l) } : []
end

def capture_stderr
  old = $stderr
  $stderr = StringIO.new
  yield
  $stderr.string
ensure
  $stderr = old
end

with_store do |dir, tmp|
  e1 = T.emit("telemetry.probe", attrs: { "note" => "a" }, repo_dir: tmp, env: env_for(dir, now: "2026-10-01T23:59:59.999Z"))
  e2 = T.emit("telemetry.probe", attrs: { "note" => "b" }, repo_dir: tmp, env: env_for(dir, now: "2026-10-02T00:00:00.000Z"))
  check("emit: the injected clock picks the day file (23:59:59.999Z and 00:00:00.000Z differ)") do
    a = lines_in(File.join(dir, "2026-10-01.jsonl"))
    b = lines_in(File.join(dir, "2026-10-02.jsonl"))
    a.size == 1 && b.size == 1 && a[0]["at"] == "2026-10-01T23:59:59.999Z" && b[0]["attrs"] == { "note" => "b" }
  end
  check("emit: returns the written event") { e1.is_a?(Hash) && e2["event"] == "telemetry.probe" }
  check("emit: outside a repo the unit is null, source none, repo and head null") do
    e1["unit"].nil? && e1["unit_source"] == "none" && e1["repo"].nil? && e1["head"].nil?
  end
  check("store: dir 0700, files 0600") do
    (File.stat(dir).mode & 0o777) == 0o700 && (File.stat(File.join(dir, "2026-10-01.jsonl")).mode & 0o777) == 0o600
  end
  check("store: a clean write leaves no write-failures file") { !File.exist?(File.join(dir, "write-failures")) }
end

with_store do |dir, tmp|
  ev = T.emit("telemetry.probe", unit: "DND-5", at: Time.utc(2026, 10, 1, 4), duration_s: 3, head: SHA,
                                 repo_dir: tmp, env: env_for(dir))
  check("emit: explicit unit, at, duration and head are written") do
    ev["unit"] == "DND-5" && ev["unit_source"] == "explicit" && ev["at"] == "2026-10-01T04:00:00.000Z" &&
      ev["duration_s"] == 3.0 && ev["head"] == SHA
  end
end

with_store do |dir, tmp|
  ev = T.emit("telemetry.probe", repo_dir: tmp, env: env_for(dir, "ATHENA_UNIT" => "DND-77"))
  check("emit: ATHENA_UNIT gives source env") { ev["unit"] == "DND-77" && ev["unit_source"] == "env" }
end

with_store do |dir, tmp|
  repo = File.join(tmp, "myrepo")
  FileUtils.mkdir_p(repo)
  genv = { "GIT_CONFIG_NOSYSTEM" => "1", "GIT_CONFIG_GLOBAL" => "/dev/null",
           "GIT_AUTHOR_NAME" => "F", "GIT_AUTHOR_EMAIL" => "f@example.invalid",
           "GIT_COMMITTER_NAME" => "F", "GIT_COMMITTER_EMAIL" => "f@example.invalid" }
  ok = system(genv, "git", "-C", repo, "init", "-q", "-b", "dnd-1463-receipt-base", out: File::NULL, err: File::NULL) &&
       system(genv, "git", "-C", repo, "commit", "-q", "--allow-empty", "-m", "c", out: File::NULL, err: File::NULL)
  sub = File.join(repo, "sub")
  FileUtils.mkdir_p(sub)
  ev = T.emit("telemetry.probe", repo_dir: sub, env: env_for(dir))
  head = IO.popen(["git", "-C", repo, "rev-parse", "HEAD"], &:read).strip
  check("emit: inside a repo, unit, repo and head come from git") do
    ok && ev["unit"] == "DND-1463" && ev["unit_source"] == "branch" && ev["repo"] == "myrepo" && ev["head"] == head
  end
end

with_store do |dir, tmp|
  FileUtils.mkdir_p(dir, mode: 0o700)
  File.chmod(0o500, dir)
  err = capture_stderr do
    r1 = T.emit("telemetry.probe", repo_dir: tmp, env: env_for(dir))
    r2 = T.emit("telemetry.probe", repo_dir: tmp, env: env_for(dir))
    check("fail open: an unwritable dir returns nil, never raises") { r1.nil? && r2.nil? }
  end
  check("fail open: exactly one athena-telemetry: stderr line across two emits") do
    err.lines.size == 1 && err.start_with?("athena-telemetry:")
  end
  check("fail open: nothing was written") { Dir.children(dir).empty? }
end

with_store do |dir, tmp|
  r = T.emit("nope.event", repo_dir: tmp, env: env_for(dir))
  check("unregistered event: nothing is written") { r.nil? && Dir.glob(File.join(dir, "*.jsonl")).empty? }
  check("unregistered event: write-failures counts event_unregistered: 1") do
    JSON.parse(File.read(File.join(dir, "write-failures"))) == { "event_unregistered" => 1 }
  end
  check("write-failures is 0600") { (File.stat(File.join(dir, "write-failures")).mode & 0o777) == 0o600 }
end

with_store do |dir, tmp|
  ev = T.emit("telemetry.probe", attrs: { "note" => "ok", "argv" => "secret-ish" }, repo_dir: tmp, env: env_for(dir))
  check("dropped attr: the line is written without it, and counted") do
    ev["attrs"] == { "note" => "ok" } &&
      JSON.parse(File.read(File.join(dir, "write-failures"))) == { "attr_unregistered" => 1 }
  end
end

with_store do |dir, tmp|
  env = env_for(dir, "ATHENA_TELEMETRY_DAY_CAP_BYTES" => "200")
  first = T.emit("telemetry.probe", repo_dir: tmp, env: env)
  size1 = File.size(File.join(dir, "2026-10-01.jsonl"))
  check("day cap precondition: one probe line is 100..199 bytes") { first && size1.between?(100, 199) }
  T.emit("telemetry.probe", repo_dir: tmp, env: env)
  third = T.emit("telemetry.probe", repo_dir: tmp, env: env)
  check("day cap: the third emit is not appended") do
    third.nil? && lines_in(File.join(dir, "2026-10-01.jsonl")).size == 2
  end
  check("day cap: the counter has day_cap: 1") do
    JSON.parse(File.read(File.join(dir, "write-failures"))) == { "day_cap" => 1 }
  end
end

with_store do |dir, tmp|
  env = env_for(dir)
  pids = 2.times.map do |k|
    fork do
      50.times { |i| T.emit("telemetry.probe", attrs: { "note" => "child#{k}-#{i}-#{'z' * 100}" }, repo_dir: tmp, env: env) }
      exit!(0)
    end
  end
  statuses = pids.map { |p| Process.wait2(p)[1] }
  raw = File.read(File.join(dir, "2026-10-01.jsonl"))
  parsed = raw.lines.map { |l| JSON.parse(l) rescue nil }
  check("two forked writers: 100 parseable lines, none interleaved") do
    statuses.all?(&:success?) && parsed.size == 100 && parsed.none?(&:nil?) &&
      parsed.map { |e| e["attrs"]["note"] }.uniq.size == 100
  end
end

# ---------------------------------------------------------------------------
# Reader
# ---------------------------------------------------------------------------

with_store do |dir, _tmp|
  r = T.read(env: env_for(dir))
  check("read: a missing dir is no_store (could not look)") { r.status == :no_store && r.events.empty? && r.reason }
  check("read: no_store still returns the failures counter") { r.failures == {} }
end

with_store do |dir, _tmp|
  FileUtils.mkdir_p(dir, mode: 0o700)
  r = T.read(env: env_for(dir), unit: "DND-1")
  check("read: an existing empty dir is ok_empty, naming the unit searched") do
    r.status == :ok_empty && r.events.empty? && r.unit == "DND-1"
  end
end

with_store do |dir, tmp|
  T.emit("telemetry.probe", unit: "DND-1", repo_dir: tmp, env: env_for(dir, now: "2026-10-01T01:00:00.000Z"))
  T.emit("telemetry.probe", unit: "DND-2", repo_dir: tmp, env: env_for(dir, now: "2026-10-01T02:00:00.000Z"))
  T.emit("ticket.dispatched", unit: "DND-1", attrs: { "tracker" => "dnd" }, repo_dir: tmp,
                              env: env_for(dir, now: "2026-10-02T03:00:00.000Z"))
  T.emit("nope.event", repo_dir: tmp, env: env_for(dir))
  File.open(File.join(dir, "2026-10-02.jsonl"), "a") { |f| f.write("{not json\n") }
  env = env_for(dir)
  all = T.read(env: env)
  check("read: events give ok, oldest first") { all.status == :ok && all.events.size == 3 && all.events[0]["unit"] == "DND-1" }
  check("read: filtered by unit") { T.read(env: env, unit: "DND-1").events.size == 2 }
  check("read: filtered by event") { T.read(env: env, events: ["ticket.dispatched"]).events.size == 1 }
  check("read: filtered by unit and event") do
    T.read(env: env, unit: "DND-2", events: ["ticket.dispatched"]).status == :ok_empty
  end
  check("read: filtered by since/until on at") do
    T.read(env: env, since: Time.utc(2026, 10, 1, 1, 30), until: Time.utc(2026, 10, 1, 23)).events.map { |e| e["unit"] } == ["DND-2"]
  end
  check("read: the failures counter comes back with the events") { all.failures == { "event_unregistered" => 1 } }
  check("read: a malformed line is counted, never silently skipped") { all.malformed == 1 }
end

# ---------------------------------------------------------------------------
# Prune
# ---------------------------------------------------------------------------

with_store do |dir, _tmp|
  FileUtils.mkdir_p(dir, mode: 0o700)
  %w[2026-09-30.jsonl 2026-10-01.jsonl write-failures notes.txt].each { |n| File.write(File.join(dir, n), "x\n") }
  r = T.prune(env: env_for(dir, now: "2026-10-31T12:00:00.000Z"), days: 30)
  check("prune: removes only the expired day file") do
    r.status == :ok && r.removed == ["2026-09-30.jsonl"] &&
      Dir.children(dir).sort == %w[2026-10-01.jsonl notes.txt write-failures]
  end
end

with_store do |dir, _tmp|
  r = T.prune(env: env_for(dir), days: 30)
  check("prune: no store is its own status, not a failure") { r.status == :no_store && r.removed.empty? }
end

# ---------------------------------------------------------------------------
# The misses (review round): a wrong or missing input must never read as a
# clean result.
# ---------------------------------------------------------------------------

def with_stub(mod, name, impl)
  orig = mod.method(name)
  mod.define_singleton_method(name, &impl)
  yield
ensure
  mod.define_singleton_method(name, orig)
end

with_store do |dir, tmp|
  T.emit("telemetry.probe", at: Time.utc(2026, 10, 3), repo_dir: tmp, env: env_for(dir, now: "2026-10-01T05:00:00.000Z"))
  r = T.read(env: env_for(dir), since: Time.utc(2026, 10, 2))
  check("miss: an at later than the write day is still found by a since read") { r.status == :ok && r.events.size == 1 }
end

with_store do |dir, tmp|
  T.emit("telemetry.probe", repo_dir: tmp, env: env_for(dir))
  File.chmod(0o000, File.join(dir, "2026-10-01.jsonl"))
  r = T.read(env: env_for(dir))
  check("miss: an unreadable day file is :incomplete, never ok_empty") do
    r.status == :incomplete && r.unreadable == ["2026-10-01.jsonl"] && r.reason.include?("2026-10-01.jsonl")
  end
end

Dir.mktmpdir("telemetry-git") do |tmp|
  check("miss: git that cannot run is git_context_unavailable, not 'no repo'") do
    T::GitContext.read(tmp, git: File.join(tmp, "no-such-git")) == [T::GitContext::NONE, "git_context_unavailable"]
  end
  check("hit: a directory outside any repo is no repo, with no drop") do
    T::GitContext.read(tmp) == [T::GitContext::NONE, nil]
  end
end

check("miss: a ticket parser that raises falls back to the branch name, counted") do
  boom = ->(_b) { raise "parser bug" }
  T::Unit.parse(branch: "dnd-1-x", env_unit: nil, ticket_ref: boom) == ["dnd-1-x", "branch-name", ["unit_parser_unavailable"]]
end

with_store do |dir, tmp|
  r = T.emit("telemetry.probe", repo_dir: tmp, env: env_for(dir, now: "yesterday"))
  check("miss: a malformed clock seam is config_invalid, counted") do
    r.nil? && JSON.parse(File.read(File.join(dir, "write-failures"))) == { "config_invalid" => 1 }
  end
end

with_store do |_dir, tmp|
  err = capture_stderr do
    check("miss: a relative store path returns nil") do
      T.emit("telemetry.probe", repo_dir: tmp, env: { "ATHENA_TELEMETRY_DIR" => "relative/telemetry" }).nil?
    end
  end
  check("miss: a relative store path says so once on stderr, with Fix:") do
    err.lines.size == 1 && err.start_with?("athena-telemetry:") && err.include?("Fix:") && !File.exist?(File.join(tmp, "relative"))
  end
end

with_store do |dir, tmp|
  with_stub(T, :registry, -> { raise T::RegistryError, "broken" }) do
    T.emit("telemetry.probe", repo_dir: tmp, env: env_for(dir))
  end
  check("miss: an unreadable registry is registry_unreadable, counted") do
    JSON.parse(File.read(File.join(dir, "write-failures"))) == { "registry_unreadable" => 1 }
  end
end

with_store do |dir, tmp|
  with_stub(T::Host, :short, -> { raise "writer bug" }) do
    check("miss: a writer bug returns nil") { T.emit("telemetry.probe", repo_dir: tmp, env: env_for(dir)).nil? }
  end
  check("miss: a writer bug is internal_error, not config_invalid") do
    JSON.parse(File.read(File.join(dir, "write-failures"))) == { "internal_error" => 1 }
  end
end

with_store do |dir, tmp|
  FileUtils.mkdir_p(dir, mode: 0o700)
  File.write(File.join(dir, "write-failures"), "[1]")
  T.emit("nope.event", repo_dir: tmp, env: env_for(dir))
  check("miss: a corrupt counter restarts with counter_corrupt, and keeps counting") do
    JSON.parse(File.read(File.join(dir, "write-failures"))) == { "counter_corrupt" => 1, "event_unregistered" => 1 }
  end
end

with_store do |dir, _tmp|
  FileUtils.mkdir_p(File.join(dir, "write-failures"))
  r = T.read(env: env_for(dir))
  check("miss: an unreadable counter is nil with a reason, never {}") do
    r.failures.nil? && r.failures_reason.include?("write-failures")
  end
end

with_store do |dir, tmp|
  env = env_for(dir)
  pids = 2.times.map do
    fork do
      20.times { T.emit("nope.event", repo_dir: tmp, env: env) }
      exit!(0)
    end
  end
  statuses = pids.map { |p| Process.wait2(p)[1] }
  check("two forked writers' drops are all counted") do
    statuses.all?(&:success?) && JSON.parse(File.read(File.join(dir, "write-failures"))) == { "event_unregistered" => 40 }
  end
end

with_store do |dir, _tmp|
  FileUtils.mkdir_p(dir, mode: 0o700)
  File.write(File.join(dir, "2026-09-01.jsonl"), "x\n")
  File.chmod(0o500, dir)
  r = T.prune(env: env_for(dir, now: "2026-10-31T00:00:00Z"), days: 30)
  check("miss: a prune that cannot remove a file is :error with a reason") do
    r.status == :error && r.removed.empty? && r.reason.include?(dir)
  end
end

with_store do |dir, _tmp|
  FileUtils.mkdir_p(dir, mode: 0o700)
  check("prune: a file already gone is skipped, not an error") { T::Store.unlink(dir, "2026-01-01.jsonl") == false }
end

if $failures.empty?
  puts "telemetry_test: #{$checks} checks passed"
  exit 0
end
$failures.each { |f| puts "FAIL #{f}" }
puts "telemetry_test: #{$failures.size} of #{$checks} checks failed"
exit 1
