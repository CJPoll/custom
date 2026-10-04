# frozen_string_literal: true

# Deterministic suite for ai/lib/glab_ci_wait.rb (DOMAIN, DND-1940): reading
# one `glab api -i` response, validating the keys, choosing the current
# pipelines on a sha, following trigger bridges to their downstream
# pipelines, and judging the verdict. Run by ai/test/glab-ci-wait/self-test.sh,
# which harness-gate discovers.
#
# Every input is a value (response text, a Time). No process, file or clock
# access. Functional only (DND-1222). Projects, shas and ids are synthetic.

require "json"
require_relative "../../lib/glab_ci_wait"

W = GlabCiWait
NOW = Time.utc(2026, 10, 4, 1, 0, 0)
SHA = "a" * 40
PROJ = "acme/app"

$failures = []
$checks = 0

def check(desc)
  $checks += 1
  $failures << desc unless yield
rescue StandardError => e
  $failures << "#{desc} (raised #{e.class}: #{e.message})"
end

def raised
  yield
  nil
rescue W::Usage => e
  e
end

# A `glab api -i` stdout: status line, headers, blank line, body.
def http(status, headers = {}, body = "{}")
  reason = { 200 => "OK", 401 => "Unauthorized", 403 => "Forbidden", 404 => "Not Found",
             429 => "Too Many Requests", 502 => "Bad Gateway" }[status]
  lines = ["HTTP/2.0 #{status} #{reason}"] + headers.map { |k, v| "#{k}: #{v}" }
  "#{lines.join("\r\n")}\r\n\r\n#{body}"
end

def pl(id, status, source: "push", ref: "main", sha: SHA, project: PROJ)
  { "id" => id, "status" => status, "source" => source, "ref" => ref, "sha" => sha,
    "web_url" => "https://gitlab.com/#{project}/-/pipelines/#{id}" }
end

def bridge(name, status, downstream: nil, allow_failure: false)
  { "id" => 900 + name.length, "name" => name, "stage" => "deploy", "status" => status,
    "allow_failure" => allow_failure, "downstream_pipeline" => downstream }
end

T = W::Target.new(project: PROJ, sha: SHA, ref: nil, source: nil, include_children: false)
TC = W::Target.new(project: PROJ, sha: SHA, ref: "main", source: "push", include_children: true)

# ---- P: parsing one response ---------------------------------------------------
check("P1 a 200 with a JSON array is :ok") do
  r = W.parse(stdout: http(200, {}, "[]"), stderr: "", now: NOW)
  r.kind == :ok && r.body == [] && r.next_page.nil? && r.reset_at.nil?
end
check("P2 a 200 whose body is not JSON is :error, never :ok") do
  W.parse(stdout: http(200, {}, "<html>"), stderr: "", now: NOW).kind == :error
end
check("P3 a 429 with Retry-After is :rate_limited, reset at now + Retry-After") do
  r = W.parse(stdout: http(429, { "Retry-After" => "90", "RateLimit-Remaining" => "0" }, '{"message":"429 Too Many Requests"}'),
              stderr: "glab: 429 Too Many Requests (HTTP 429)", now: NOW)
  r.kind == :rate_limited && r.reset_at == NOW + 90
end
check("P4 a 429 with only RateLimit-Reset (epoch) resets then") do
  r = W.parse(stdout: http(429, { "RateLimit-Reset" => (NOW.to_i + 400).to_s }, "{}"), stderr: "", now: NOW)
  r.kind == :rate_limited && r.reset_at == NOW + 400
end
check("P5 a 429 with no reset header falls back, and is still a limit") do
  r = W.parse(stdout: http(429, {}, "{}"), stderr: "", now: NOW)
  r.kind == :rate_limited && r.reset_at > NOW
end
check("P6 a 200 with RateLimit-Remaining 0 carries the reset (honoured, not ignored)") do
  r = W.parse(stdout: http(200, { "RateLimit-Remaining" => "0", "RateLimit-Reset" => (NOW.to_i + 45).to_s }, "[]"),
              stderr: "", now: NOW)
  r.kind == :ok && r.reset_at == NOW + 45
end
check("P7 a 200 with budget left carries no reset") do
  r = W.parse(stdout: http(200, { "RateLimit-Remaining" => "1999", "RateLimit-Reset" => (NOW.to_i + 45).to_s }, "[]"),
              stderr: "", now: NOW)
  r.reset_at.nil?
end
check("P8 a 404 is :not_found and keeps GitLab's message") do
  r = W.parse(stdout: http(404, {}, '{"message":"404 Project Not Found"}'), stderr: "", now: NOW)
  r.kind == :not_found && r.detail.include?("404 Project Not Found")
end
check("P9 401 and 403 are :auth") do
  W.parse(stdout: http(401, {}, '{"message":"401 Unauthorized"}'), stderr: "", now: NOW).kind == :auth &&
    W.parse(stdout: http(403, {}, '{"message":"403 Forbidden"}'), stderr: "", now: NOW).kind == :auth
end
check("P10 a 502 is a transient :error") do
  W.parse(stdout: http(502, {}, "{}"), stderr: "", now: NOW).kind == :error
end
check("P11 a glab-athena refusal (no HTTP status) is :refused, never retried as transient") do
  r = W.parse(stdout: "", stderr: "glab-athena: REFUSING: the token file is missing.\n  Fix: ...\n", now: NOW)
  r.kind == :refused && r.detail.include?("REFUSING")
end
check("P12 no response at all is a transient :error") do
  W.parse(stdout: "", stderr: "dial tcp: lookup gitlab.com: no such host\n", now: NOW).kind == :error
end
check("P13 a next page is recorded from X-Next-Page") do
  W.parse(stdout: http(200, { "X-Next-Page" => "2" }, "[]"), stderr: "", now: NOW).next_page == "2"
end
check("P14 an empty X-Next-Page is no next page") do
  W.parse(stdout: http(200, { "X-Next-Page" => "" }, "[]"), stderr: "", now: NOW).next_page.nil?
end

# ---- K: keys. A wrongly computed key is an error, never NOT-FOUND ---------------
check("K1 a group/project path is accepted and %2F-encoded") do
  W.project!("acme/app") == "acme/app" && W.encode_project("acme/sub/app") == "acme%2Fsub%2Fapp"
end
check("K2 a URL is refused with a Fix naming the path form") do
  e = raised { W.project!("https://gitlab.com/acme/app") }
  e && e.fix.include?("acme/app")
end
check("K3 a numeric id is refused (it names no namespace)") { raised { W.project!("12345") } }
check("K4 a single segment is refused") { raised { W.project!("app") } }
check("K5 an already %-encoded path is refused") { raised { W.project!("acme%2Fapp") } }
check("K6 a .git suffix is refused") { raised { W.project!("acme/app.git") } }
check("K7 a .. segment is refused") { raised { W.project!("acme/../app") } }
check("K8 a leading or trailing slash is refused") { raised { W.project!("/acme/app") } && raised { W.project!("acme/app/") } }
check("K9 an ssh remote is refused") { raised { W.project!("git@gitlab.com:acme/app.git") } }
check("K10 --source takes push or merge_request_event only") do
  W.source!("push") == "push" && W.source!("merge_request_event") == "merge_request_event" && raised { W.source!("merge_request") }
end
check("K11 --ref refuses whitespace and an empty value") { raised { W.ref!("") } && raised { W.ref!("ma in") } }
check("K12 an MR ref is accepted") { W.ref!("refs/merge-requests/7/head") == "refs/merge-requests/7/head" }
check("K13 a short sha is refused (shared rule)") { raised { W.sha!("abc123") } }
check("K14 --grace 0 is allowed; a negative or a word is not") do
  W.grace!("0").zero? && raised { W.grace!("-1") } && raised { W.grace!("soon") }
end

# ---- A: the paths read. Project by %2F path only (DND-1936 refuses ids) ----------
check("A1 the commit read") { W.commit_path(T) == "projects/acme%2Fapp/repository/commits/#{SHA}" }
check("A2 the pipelines list, unfiltered") do
  W.list_path(T) == "projects/acme%2Fapp/pipelines?sha=#{SHA}&order_by=id&sort=desc&per_page=100"
end
check("A3 the pipelines list with ref and source, the ref query-encoded") do
  t = W::Target.new(project: PROJ, sha: SHA, ref: "refs/merge-requests/7/head", source: "merge_request_event")
  W.list_path(t) == "projects/acme%2Fapp/pipelines?sha=#{SHA}&order_by=id&sort=desc&per_page=100" \
                    "&ref=refs%2Fmerge-requests%2F7%2Fhead&source=merge_request_event"
end
check("A4 bridges and jobs of one pipeline") do
  W.bridges_path("acme/app", 5) == "projects/acme%2Fapp/pipelines/5/bridges?per_page=100" &&
    W.jobs_path("acme/app", 5) == "projects/acme%2Fapp/pipelines/5/jobs?per_page=100"
end
check("A5 no path past the project is %-encoded (DND-1936's endpoint key)") do
  [W.commit_path(T), W.list_path(TC), W.bridges_path(PROJ, 1), W.jobs_path(PROJ, 1)].all? do |p|
    !p.split("?").first.sub(%r{\Aprojects/[^/]+}, "").include?("%")
  end
end

# ---- C: choosing the current pipelines on the sha -------------------------------
check("C1 the newest pipeline per (source, ref) is current; older ones are superseded") do
  c = W.current_pipelines([pl(12, "success"), pl(10, "failed")], T, next_page: nil)
  c[:current].map { |p| p["id"] } == [12] && c[:superseded].map { |p| p["id"] } == [10]
end
check("C2 a push pipeline and an MR pipeline on one sha are both current") do
  c = W.current_pipelines([pl(12, "success"), pl(11, "running", source: "merge_request_event", ref: "refs/merge-requests/3/head")],
                          T, next_page: nil)
  c[:current].map { |p| p["id"] }.sort == [11, 12]
end
check("C2b a newer \"Run pipeline\" (source web) on the same ref supersedes a failed push pipeline") do
  c = W.current_pipelines([pl(14, "success", source: "web"), pl(12, "failed")], T, next_page: nil)
  c[:current].map { |p| p["id"] } == [14] && c[:superseded].map { |p| p["id"] } == [12]
end
check("C3 a child pipeline in the list is not top level (bridges reach it)") do
  c = W.current_pipelines([pl(12, "success"), pl(13, "failed", source: "parent_pipeline")], T, next_page: nil)
  c[:current].map { |p| p["id"] } == [12]
end
check("C4 another sha's row is never judged") do
  W.current_pipelines([pl(12, "success", sha: "b" * 40)], T, next_page: nil)[:current].empty?
end
check("C5 a body that is not an array is Unreadable, never empty") do
  (W.current_pipelines({ "message" => "x" }, T, next_page: nil) rescue $!).is_a?(W::Unreadable)
end
check("C6 a second page is Unreadable: the newest pipeline may be on it") do
  (W.current_pipelines([pl(12, "success")], T, next_page: "2") rescue $!).is_a?(W::Unreadable)
end
check("C7 a row with no id or status is Unreadable") do
  (W.current_pipelines([{ "sha" => SHA }], T, next_page: nil) rescue $!).is_a?(W::Unreadable)
end

# ---- B: bridges and their downstream pipelines ----------------------------------
DS = { "id" => 77, "status" => "running", "sha" => SHA, "ref" => "main", "source" => "parent_pipeline",
       "web_url" => "https://gitlab.com/acme/app/-/pipelines/77" }.freeze
check("B1 a bridge with a downstream pipeline yields that child, its project read from web_url") do
  e = W.bridge_entries([bridge("deploy", "running", downstream: DS)], next_page: nil)
  e.size == 1 && e[0][:kind] == :child && e[0][:project] == "acme/app" && e[0][:pipeline]["id"] == 77
end
check("B2 a multi-project downstream names the other project") do
  ds = DS.merge("web_url" => "https://gitlab.com/acme/deployer/-/pipelines/77")
  W.bridge_entries([bridge("deploy", "running", downstream: ds)], next_page: nil)[0][:project] == "acme/deployer"
end
check("B3 a pending bridge not yet triggered is :open (pending), never ignored") do
  W.bridge_entries([bridge("deploy", "waiting_for_resource")], next_page: nil)[0][:kind] == :open
end
check("B4 a manual or skipped bridge with no downstream is :idle") do
  W.bridge_entries([bridge("perf", "manual", allow_failure: true), bridge("x", "skipped")], next_page: nil)
   .map { |b| b[:kind] } == %i[idle idle]
end
check("B5 a failed bridge with no downstream is :dead") do
  W.bridge_entries([bridge("deploy", "failed")], next_page: nil)[0][:kind] == :dead
end
check("B6 a downstream web_url on another host is Unreadable") do
  ds = DS.merge("web_url" => "https://evil.example/acme/app/-/pipelines/77")
  (W.bridge_entries([bridge("d", "running", downstream: ds)], next_page: nil) rescue $!).is_a?(W::Unreadable)
end
check("B7 a downstream web_url whose id disagrees is Unreadable") do
  ds = DS.merge("web_url" => "https://gitlab.com/acme/app/-/pipelines/78")
  (W.bridge_entries([bridge("d", "running", downstream: ds)], next_page: nil) rescue $!).is_a?(W::Unreadable)
end
check("B8 a bridges body that is not an array is Unreadable") do
  (W.bridge_entries({}, next_page: nil) rescue $!).is_a?(W::Unreadable)
end

# ---- J: judging ---------------------------------------------------------------
def top(*ps) = ps.map { |p| { project: PROJ, pipeline: p } }

check("J1 one success: DONE, naming the pipeline id") do
  s = W.judge(top: top(pl(12, "success")), entries: [], superseded: [])
  s.state == :success && s.ids == [12] && s.summary.include?("12")
end
check("J2 running is pending") { W.judge(top: top(pl(12, "running")), entries: [], superseded: []).state == :pending }
check("J3 waiting_for_resource is pending, not stuck (resource_group deploys)") do
  s = W.judge(top: top(pl(12, "waiting_for_resource")), entries: [], superseded: [])
  s.state == :pending && s.summary.include?("waiting_for_resource")
end
check("J4 failed is :failed") { W.judge(top: top(pl(12, "failed")), entries: [], superseded: []).state == :failed }
check("J5 canceled is :canceled") { W.judge(top: top(pl(12, "canceled")), entries: [], superseded: []).state == :canceled }
check("J6 skipped is never DONE: nothing ran") do
  s = W.judge(top: top(pl(12, "skipped")), entries: [], superseded: [])
  s.state == :failed && s.summary.include?("skipped")
end
check("J7 manual is pending and says it will not finish by itself") do
  s = W.judge(top: top(pl(12, "manual")), entries: [], superseded: [])
  s.state == :pending && s.summary.include?("manual")
end
check("J8 an unknown status is Unreadable, never guessed") do
  (W.judge(top: top(pl(12, "exploded")), entries: [], superseded: []) rescue $!).is_a?(W::Unreadable)
end
check("J9 no current pipeline is :none (the caller decides NOT-FOUND)") do
  W.judge(top: [], entries: [], superseded: []).state == :none
end
check("J10 pending outranks failed: wait for every pipeline to settle") do
  W.judge(top: top(pl(12, "failed"), pl(11, "running", source: "merge_request_event", ref: "r")), entries: [], superseded: [])
   .state == :pending
end
check("J11 failed outranks canceled") do
  W.judge(top: top(pl(12, "failed"), pl(11, "canceled", source: "merge_request_event", ref: "r")), entries: [], superseded: [])
   .state == :failed
end
check("J12 a green parent with a running child is pending") do
  child = { kind: :child, project: PROJ, pipeline: DS, bridge: bridge("deploy", "running"), parent: 12 }
  W.judge(top: top(pl(12, "success")), entries: [child], superseded: []).state == :pending
end
check("J13 a green parent with a failed child is FAILED, naming the child") do
  child = { kind: :child, project: PROJ, pipeline: DS.merge("status" => "failed"), bridge: bridge("deploy", "failed"), parent: 12 }
  s = W.judge(top: top(pl(12, "success")), entries: [child], superseded: [])
  s.state == :failed && s.ids == [12, 77] && s.summary.include?("deploy")
end
check("J14 a failed child behind an allow_failure bridge does not fail the wait, and is named") do
  child = { kind: :child, project: PROJ, pipeline: DS.merge("status" => "failed"),
            bridge: bridge("perf", "failed", allow_failure: true), parent: 12 }
  s = W.judge(top: top(pl(12, "success")), entries: [child], superseded: [])
  s.state == :success && s.summary.include?("allowed to fail")
end
check("J15 an open bridge (not yet triggered) is pending") do
  open = { kind: :open, bridge: bridge("deploy", "pending"), parent: 12 }
  W.judge(top: top(pl(12, "success")), entries: [open], superseded: []).state == :pending
end
check("J16 a dead bridge is FAILED; an idle one is named, not waited on") do
  dead = { kind: :dead, bridge: bridge("deploy", "failed"), parent: 12 }
  idle = { kind: :idle, bridge: bridge("perf", "manual", allow_failure: true), parent: 12 }
  W.judge(top: top(pl(12, "success")), entries: [dead], superseded: []).state == :failed &&
    W.judge(top: top(pl(12, "success")), entries: [idle], superseded: []).summary.include?("not triggered")
end
check("J17 a superseded pipeline is named by id") do
  W.judge(top: top(pl(12, "success")), entries: [], superseded: [pl(10, "failed")]).summary.include?("superseded")
end
check("J18 failing_nodes lists the failed and canceled pipelines to read jobs from") do
  child = { kind: :child, project: PROJ, pipeline: DS.merge("status" => "canceled"), bridge: bridge("deploy", "canceled"), parent: 12 }
  s = W.judge(top: top(pl(12, "failed")), entries: [child], superseded: [])
  s.failing.map { |n| n[:pipeline]["id"] } == [12, 77]
end

# ---- F: the failing job list --------------------------------------------------------
JOBS = [
  { "id" => 1, "name" => "rspec", "stage" => "test", "status" => "failed", "allow_failure" => false,
    "failure_reason" => "script_failure", "web_url" => "https://gitlab.com/acme/app/-/jobs/1" },
  { "id" => 2, "name" => "lint", "stage" => "test", "status" => "failed", "allow_failure" => true,
    "web_url" => "https://gitlab.com/acme/app/-/jobs/2" },
  { "id" => 3, "name" => "build", "stage" => "build", "status" => "success", "allow_failure" => false },
  { "id" => 4, "name" => "deploy", "stage" => "deploy", "status" => "canceled", "allow_failure" => false,
    "web_url" => "https://gitlab.com/acme/app/-/jobs/4" }
].freeze
check("F1 failed and canceled jobs that are not allowed to fail are listed, with the reason") do
  rows = W.failing_jobs(JOBS, next_page: nil)
  rows.map { |r| r[:name] } == %w[rspec deploy] && rows[0][:words].include?("script_failure")
end
check("F2 a truncated job list says so") do
  W.failing_jobs(JOBS, next_page: "2").last[:words].include?("more jobs")
end
check("F3 a jobs body that is not an array is Unreadable") do
  (W.failing_jobs({}, next_page: nil) rescue $!).is_a?(W::Unreadable)
end

# ---- N: the wait decision is the shared one, and honours an ok read's reset --------
deadline = NOW + 570
okr = W::Read.new(kind: :ok, body: [])
check("N1 an ok read sleeps the interval") { W.next_wait(read: okr, now: NOW, deadline: deadline, interval: 60, errors_in_row: 0) == [:sleep, 60] }
check("N2 an ok read with the budget spent sleeps to its reset") do
  r = W::Read.new(kind: :ok, body: [], reset_at: NOW + 200)
  W.next_wait(read: r, now: NOW, deadline: deadline, interval: 60, errors_in_row: 0) == [:sleep, 200]
end
check("N3 a 429 inside the bound sleeps to the reset (backs off), never sooner than the floor") do
  r = W::Read.new(kind: :rate_limited, reset_at: NOW + 5)
  W.next_wait(read: r, now: NOW, deadline: deadline, interval: 60, errors_in_row: 0) == [:sleep, W::MIN_INTERVAL]
end
check("N4 a 429 past the bound gives up") do
  r = W::Read.new(kind: :rate_limited, reset_at: NOW + 3600)
  W.next_wait(read: r, now: NOW, deadline: deadline, interval: 60, errors_in_row: 0) == [:give_up]
end
check("N5 the interval floor is the shared 30 s") { raised { W.interval!("10") } && W.interval!("30") == 30 }

puts "glab-ci-wait domain: #{$checks - $failures.size} of #{$checks} checks passed"
$failures.each { |f| puts "FAIL #{f}" }
exit($failures.empty? ? 0 : 1)
