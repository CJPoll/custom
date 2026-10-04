# frozen_string_literal: true

# Deterministic suite for GlabCiWait::Waiter (MANAGER, ai/lib/glab_ci_wait_io.rb,
# DND-1940): the read-judge-sleep loop, with the glab adapter, the clock and
# the sleeper all faked. A fake sleeper advances the fake clock, so a 570 s
# wait runs in microseconds. Functional only (DND-1222): no real sleep, no
# network. Projects, shas and ids are synthetic.

require "json"
require_relative "../../lib/glab_ci_wait"
require_relative "../../lib/glab_ci_wait_io"

W = GlabCiWait
T0 = Time.utc(2026, 10, 4, 1, 0, 0)
SHA = "c" * 40
PROJ = "acme/app"
ENC = "acme%2Fapp"

$failures = []
$checks = 0

def check(desc)
  $checks += 1
  $failures << desc unless yield
rescue StandardError => e
  $failures << "#{desc} (raised #{e.class}: #{e.message} #{e.backtrace&.first})"
end

# A fake GitLab: routes a path to a scripted list of answers. Each answer is a
# Read, or a lambda(now) -> Read; the last answer for a route repeats.
class Rig
  attr_reader :now, :sleeps, :paths, :log

  def initialize(routes)
    @routes = routes
    @now = T0
    @sleeps = []
    @paths = []
    @log = []
  end

  def waiter
    reader = lambda do |path, _timeout_s|
      @paths << path
      key = @routes.keys.find { |k| path.include?(k) } or raise "unrouted read #{path}"
      list = @routes[key]
      entry = list.length > 1 ? list.shift : list.first
      entry.respond_to?(:call) ? entry.call(@now) : entry
    end
    W::Waiter.new(reader: reader, clock: -> { @now }, sleeper: ->(s) { @sleeps << s; @now += s },
                  log: ->(line) { @log << line })
  end
end

def ok(body, **extra) = W::Read.new(kind: :ok, status: 200, body: body, **extra)
def pl(id, status, source: "push", ref: "main") =
  { "id" => id, "status" => status, "source" => source, "ref" => ref, "sha" => SHA,
    "web_url" => "https://gitlab.com/#{PROJ}/-/pipelines/#{id}" }
def ds(id, status, project: PROJ) =
  { "id" => id, "status" => status, "source" => "parent_pipeline", "ref" => "main", "sha" => SHA,
    "web_url" => "https://gitlab.com/#{project}/-/pipelines/#{id}" }
def br(name, status, downstream = nil, allow_failure: false) =
  { "id" => 500, "name" => name, "stage" => "deploy", "status" => status, "allow_failure" => allow_failure,
    "downstream_pipeline" => downstream }

COMMIT = ok({ "id" => SHA })
T = W::Target.new(project: PROJ, sha: SHA, ref: "main", source: "push", include_children: false)
TC = W::Target.new(project: PROJ, sha: SHA, ref: "main", source: "push", include_children: true)

def run(rig, target = T, interval: 60, max: 570, grace: 120) =
  rig.waiter.wait(target, interval: interval, max: max, grace: grace)

# ---- each verdict ---------------------------------------------------------------
check("V1 DONE: a succeeded pipeline on the first poll, naming its id, no sleep") do
  rig = Rig.new("/repository/commits/" => [COMMIT], "/pipelines?" => [ok([pl(12, "success")])])
  o = run(rig)
  o.verdict == :done && rig.sleeps.empty? && o.line.start_with?("VERDICT: DONE") && o.line.include?("pipelines=12") &&
    o.fix.nil?
end
check("V2 pending then DONE: one sleep of the interval; the commit is checked once") do
  rig = Rig.new("/repository/commits/" => [COMMIT], "/pipelines?" => [ok([pl(12, "running")]), ok([pl(12, "success")])])
  o = run(rig)
  o.verdict == :done && rig.sleeps == [60] && rig.paths.count { |p| p.include?("/repository/commits/") } == 1
end
check("V3 FAILED lists the failing jobs from the pipeline's jobs, with a Fix") do
  jobs = [{ "id" => 7, "name" => "rspec", "stage" => "test", "status" => "failed", "allow_failure" => false,
            "failure_reason" => "script_failure", "web_url" => "https://gitlab.com/acme/app/-/jobs/7" }]
  rig = Rig.new("/repository/commits/" => [COMMIT], "/pipelines?" => [ok([pl(12, "failed")])],
                "/pipelines/12/jobs" => [ok(jobs)])
  o = run(rig)
  o.verdict == :failed && o.line.include?("test/rspec (failed: script_failure)") && o.jobs.size == 1 &&
    o.jobs[0][:id] == 7 && o.fix.to_s.include?("jobs/<job id>/trace")
end
check("V4 CANCELED is its own verdict") do
  rig = Rig.new("/repository/commits/" => [COMMIT], "/pipelines?" => [ok([pl(12, "canceled")])],
                "/pipelines/12/jobs" => [ok([])])
  o = run(rig)
  o.verdict == :canceled && o.line.start_with?("VERDICT: CANCELED") && o.fix
end
check("V5 TIMEOUT: still pending at the bound, bounded, never DONE") do
  rig = Rig.new("/repository/commits/" => [COMMIT], "/pipelines?" => [ok([pl(12, "waiting_for_resource")])])
  o = run(rig, max: 300)
  o.verdict == :timeout && rig.now - T0 <= 300 && o.line.include?("waiting_for_resource") && o.fix
end
check("V6 NOT-FOUND: the commit exists but no pipeline is listed within the grace") do
  rig = Rig.new("/repository/commits/" => [COMMIT], "/pipelines?" => [ok([])])
  o = run(rig, grace: 120)
  o.verdict == :not_found && rig.now - T0 >= 120 && rig.now - T0 < 570 && o.line.start_with?("VERDICT: NOT-FOUND")
end
check("V7 NOT-FOUND is never called on a pipeline that shows up inside the grace") do
  rig = Rig.new("/repository/commits/" => [COMMIT], "/pipelines?" => [ok([]), ok([pl(12, "success")])])
  run(rig, grace: 120).verdict == :done
end
check("V8 --grace 0: NOT-FOUND on the first empty list, no sleep") do
  rig = Rig.new("/repository/commits/" => [COMMIT], "/pipelines?" => [ok([])])
  o = run(rig, grace: 0)
  o.verdict == :not_found && rig.sleeps.empty?
end

# ---- a wrong key is a named error, never NOT-FOUND ------------------------------
check("W1 a project GitLab does not know: COULD-NOT-LOOK naming the project, not NOT-FOUND") do
  nf = W::Read.new(kind: :not_found, status: 404, detail: "HTTP 404: 404 Project Not Found")
  rig = Rig.new("/repository/commits/" => [nf])
  o = run(rig)
  o.verdict == :could_not_look && o.line.include?("project acme/app") && !o.line.include?("NOT-FOUND") &&
    o.fix.include?("--project")
end
check("W2 a sha not in the project: COULD-NOT-LOOK naming the sha") do
  nf = W::Read.new(kind: :not_found, status: 404, detail: "HTTP 404: 404 Commit Not Found")
  o = run(Rig.new("/repository/commits/" => [nf]))
  o.verdict == :could_not_look && o.line.include?("not a commit") && o.fix.include?("--sha")
end
check("W3 a glab-athena refusal is COULD-NOT-LOOK at once, with the forge-preflight Fix") do
  rf = W::Read.new(kind: :refused, detail: "glab-athena: BAD KEY ...")
  rig = Rig.new("/repository/commits/" => [rf])
  o = run(rig)
  o.verdict == :could_not_look && rig.sleeps.empty? && o.fix.include?("forge-preflight")
end
check("W4 an unreadable body is COULD-NOT-LOOK, never DONE") do
  rig = Rig.new("/repository/commits/" => [COMMIT], "/pipelines?" => [ok({ "message" => "surprise" })])
  run(rig).verdict == :could_not_look
end

# ---- rate limits: back off, never terminal, never empty -------------------------
check("R1 a 429 inside the bound backs off to the reset, then reads on") do
  rl = ->(now) { W::Read.new(kind: :rate_limited, status: 429, reset_at: now + 200, detail: "HTTP 429") }
  rig = Rig.new("/repository/commits/" => [COMMIT], "/pipelines?" => [rl, ok([pl(12, "success")])])
  o = run(rig)
  o.verdict == :done && rig.sleeps == [200] && rig.log.any? { |l| l.include?("RATE-LIMITED") }
end
check("R2 a 429 past the bound: COULD-NOT-LOOK naming the reset, after one read") do
  rl = ->(now) { W::Read.new(kind: :rate_limited, status: 429, reset_at: now + 3600, detail: "HTTP 429") }
  rig = Rig.new("/repository/commits/" => [COMMIT], "/pipelines?" => [rl])
  o = run(rig)
  o.verdict == :could_not_look && o.line.include?((T0 + 3600).iso8601) && rig.sleeps.empty? &&
    rig.paths.count { |p| p.include?("/pipelines?") } == 1
end
check("R3 an ok read with the budget spent waits to GitLab's reset, not the interval") do
  rig = Rig.new("/repository/commits/" => [COMMIT],
                "/pipelines?" => [->(now) { ok([pl(12, "running")], reset_at: now + 240) }, ok([pl(12, "success")])])
  o = run(rig)
  o.verdict == :done && rig.sleeps == [240]
end
check("R4 read errors back off, doubling, and a run of only errors is COULD-NOT-LOOK") do
  err = W::Read.new(kind: :error, detail: "no HTTP response: dial tcp")
  rig = Rig.new("/repository/commits/" => [err])
  o = run(rig)
  o.verdict == :could_not_look && rig.sleeps.first(3) == [60, 120, 240] && o.line.include?("no read succeeded")
end

# ---- --include-children: a trigger child pipeline is followed ----------------------
check("C1 a green parent whose deploy child is still running is pending, then DONE when it succeeds") do
  rig = Rig.new("/repository/commits/" => [COMMIT], "/pipelines?" => [ok([pl(12, "success")])],
                "/pipelines/12/bridges" => [ok([br("deploy", "running", ds(77, "running"))]),
                                            ok([br("deploy", "success", ds(77, "success"))])],
                "/pipelines/77/bridges" => [ok([])])
  o = run(rig, TC)
  o.verdict == :done && rig.sleeps == [60] && o.line.include?("pipelines=12,77") && o.line.include?("via deploy")
end
check("C2 without --include-children the child is not read") do
  rig = Rig.new("/repository/commits/" => [COMMIT], "/pipelines?" => [ok([pl(12, "success")])])
  o = run(rig, T)
  o.verdict == :done && rig.paths.none? { |p| p.include?("/bridges") }
end
check("C3 a failed child fails the wait, and its jobs are listed") do
  jobs = [{ "id" => 9, "name" => "kms-smoke", "stage" => "verify", "status" => "failed", "allow_failure" => false }]
  rig = Rig.new("/repository/commits/" => [COMMIT], "/pipelines?" => [ok([pl(12, "success")])],
                "/pipelines/12/bridges" => [ok([br("deploy", "failed", ds(77, "failed"))])],
                "/pipelines/77/bridges" => [ok([])], "/pipelines/77/jobs" => [ok(jobs)])
  o = run(rig, TC)
  o.verdict == :failed && o.line.include?("verify/kms-smoke") && o.jobs[0][:pipeline] == 77
end
check("C4 a bridge waiting for its resource_group (no child yet) is pending") do
  rig = Rig.new("/repository/commits/" => [COMMIT], "/pipelines?" => [ok([pl(12, "success")])],
                "/pipelines/12/bridges" => [ok([br("deploy", "waiting_for_resource")])])
  run(rig, TC, max: 120).verdict == :timeout
end
check("C5 a multi-project child is read under its own project path") do
  other = ds(88, "success", project: "acme/deployer")
  rig = Rig.new("/repository/commits/" => [COMMIT], "/pipelines?" => [ok([pl(12, "success")])],
                "/pipelines/12/bridges" => [ok([br("deploy", "success", other)])],
                "acme%2Fdeployer/pipelines/88/bridges" => [ok([])])
  o = run(rig, TC)
  o.verdict == :done && rig.paths.include?("projects/acme%2Fdeployer/pipelines/88/bridges?per_page=100")
end
check("C6 nesting past the depth bound is COULD-NOT-LOOK, never silently unfollowed") do
  routes = { "/repository/commits/" => [COMMIT], "/pipelines?" => [ok([pl(1, "success")])] }
  (1..5).each { |i| routes["/pipelines/#{i}/bridges"] = [ok([br("n#{i}", "success", ds(i + 1, "success"))])] }
  o = run(Rig.new(routes), TC)
  o.verdict == :could_not_look && o.line.include?("deeper")
end

puts "glab-ci-wait manager: #{$checks - $failures.size} of #{$checks} checks passed"
$failures.each { |f| puts "FAIL #{f}" }
exit($failures.empty? ? 0 : 1)
