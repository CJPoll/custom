# frozen_string_literal: true

# Domain suite for ai/lib/gitlab_pipeline_selector.rb (DND-1952): the GitLab
# form of a repo's idle_workflow, and the end of one landing's post-merge
# pipeline (and its deploy child) on GitLab. Pure: every pipeline, bridge and
# child is a literal hash shaped like the GitLab REST answer. Run by
# self-test.sh beside it. Functional only (DND-1222): no clock, no sleep.

require_relative "../../lib/gitlab_pipeline_selector"

S = GitLabPipelineSelector
$checks = 0
$failures = []

def check(desc)
  $checks += 1
  $failures << desc unless yield
rescue StandardError => e
  $failures << "#{desc} (raised #{e.class}: #{e.message})"
end

SEL_TEXT = "gitlab:ref=main,source=push,child=deploy"
SEL, = S.parse(SEL_TEXT)
BARE, = S.parse("gitlab:ref=main,source=push")
SHA = "ab" * 20
OTHER = "cd" * 20

# ── parse: the hit and every miss ──────────────────────────────────────────

check("P1 the full selector parses into ref, source and child") do
  SEL && SEL.ref == "main" && SEL.source == "push" && SEL.child == "deploy" && SEL.text == SEL_TEXT
end
check("P2 child is optional") { BARE && BARE.child.nil? && BARE.ref == "main" }
check("P3 key order does not matter") do
  s, = S.parse("gitlab:child=deploy,source=push,ref=main")
  s && [s.ref, s.source, s.child] == %w[main push deploy]
end
check("P4 a branch name with a slash is a ref") { S.parse("gitlab:ref=release/2026,source=push")[0]&.ref == "release/2026" }
{
  "P5 no prefix" => "ref=main,source=push",
  "P6 a workflow file is not a selector" => "post-merge.yml",
  "P7 an empty body" => "gitlab:",
  "P8 ref is required" => "gitlab:source=push",
  "P9 source is required" => "gitlab:ref=main",
  "P10 an unknown key" => "gitlab:ref=main,source=push,stage=deploy",
  "P11 a repeated key" => "gitlab:ref=main,ref=dev,source=push",
  "P12 an empty value" => "gitlab:ref=,source=push",
  "P13 a pair with no =" => "gitlab:ref=main,source",
  "P14 a trailing comma" => "gitlab:ref=main,source=push,",
  "P15 whitespace" => "gitlab:ref=main, source=push",
  "P16 an unknown pipeline source" => "gitlab:ref=main,source=pushh",
  "P17 a ref with .." => "gitlab:ref=../main,source=push",
  "P18 a child with a space" => "gitlab:ref=main,source=push,child=de ploy",
  "P19 an uppercase prefix" => "GitLab:ref=main,source=push",
}.each do |desc, text|
  check("#{desc} is refused, with a reason naming the text") do
    s, why = S.parse(text)
    s.nil? && why.is_a?(String) && why.include?(text.inspect)
  end
end
check("P20 a non-string is refused") { [nil, 5, ["gitlab:ref=main,source=push"]].all? { |v| S.parse(v)[0].nil? } }
check("P21 selector? is the prefix only: a malformed selector is still a selector (so it is refused, never read as a file)") do
  S.selector?("gitlab:junk") && !S.selector?("post-merge.yml") && !S.selector?(nil)
end

# ── status classes ─────────────────────────────────────────────────────────

check("C1 success concludes") { S.status_class("success") == :success }
check("C2 every waiting or running status is busy, waiting_for_resource included") do
  %w[created waiting_for_resource preparing pending running scheduled manual canceling].all? { |s| S.status_class(s) == :busy }
end
check("C3 failed, canceled and skipped conclude without success") { %w[failed canceled skipped].all? { |s| S.status_class(s) == :failed } }
check("C4 a status this code does not know is unknown, never idle") { [nil, "", "Success", "weird"].all? { |s| S.status_class(s) == :unknown } }

# ── pick_pipeline: which parent pipeline is the landing's ──────────────────

def pipe(id, sha: SHA, ref: "main", source: "push", status: "success", finished_at: "2026-10-03T10:00:00Z")
  { "id" => id, "sha" => sha, "ref" => ref, "source" => source, "status" => status, "finished_at" => finished_at }
end

check("K1 the landing's push pipeline on the ref is picked") do
  p, why = S.pick_pipeline(SEL, [SHA], [pipe(10)])
  p && p["id"] == 10 && why.nil?
end
check("K2 the newest of several matching pipelines (by id) is picked") do
  S.pick_pipeline(SEL, [SHA], [pipe(10), pipe(12), pipe(11)])[0]["id"] == 12
end
check("K3 both sides are filtered: a pipeline of another sha, ref or source never matches") do
  others = [pipe(1, sha: OTHER), pipe(2, ref: "dev"), pipe(3, source: "web"), pipe(4, source: "merge_request_event")]
  p, why = S.pick_pipeline(SEL, [SHA], others)
  p.nil? && why.include?("matched no pipeline") && why.include?(SEL_TEXT) && why.include?(SHA[0, 12]) &&
    why.include?("4 pipeline(s) read")
end
check("K4 a selector that matches nothing is a named could-not-measure, never idle") do
  p, why = S.pick_pipeline(SEL, [SHA], [])
  p.nil? && why.start_with?("could not measure") && why.include?("0 pipeline(s) read")
end
check("K5 the first sha (in the caller's order) with a match wins") do
  S.pick_pipeline(SEL, [OTHER, SHA], [pipe(5), pipe(4, sha: OTHER)])[0]["id"] == 4
end
check("K6 no sha to look for is a named could-not-measure") do
  p, why = S.pick_pipeline(SEL, [], [pipe(1)])
  p.nil? && why.include?("no commit")
end

# ── pick_bridge: the trigger job that starts the deploy child ──────────────

def bridge(id, name: "deploy", status: "success", downstream: { "id" => 77, "project_id" => 9, "status" => "success" })
  { "id" => id, "name" => name, "status" => status, "downstream_pipeline" => downstream }
end

check("B1 the trigger job named by child= is picked") { S.pick_bridge(SEL, pipe(10), [bridge(1, name: "lint"), bridge(2)])[0]["id"] == 2 }
check("B2 a retried trigger job: the newest wins") { S.pick_bridge(SEL, pipe(10), [bridge(3), bridge(5), bridge(4)])[0]["id"] == 5 }
check("B3 no trigger job by that name is a named could-not-measure") do
  b, why = S.pick_bridge(SEL, pipe(10), [bridge(1, name: "lint")])
  b.nil? && why.start_with?("could not measure") && why.include?("pipeline 10") && why.include?("\"deploy\"") &&
    why.include?("1 trigger job(s)")
end

# ── judge: idle (concluded) and busy deploy pipelines ──────────────────────

def child(status: "success", finished_at: "2026-10-03T10:20:00Z", project_id: 9)
  { "id" => 77, "project_id" => project_id, "status" => status, "finished_at" => finished_at }
end
PARENT = pipe(10).merge("project_id" => 9, "finished_at" => "2026-10-03T10:21:00Z")

check("J1 an idle deploy: the child concluded success, so the deploy ends at the child's finish") do
  o = S.judge(SEL, pipeline: PARENT, bridge: bridge(2), child: child)
  o.state == :concluded && o.deploy_at == "2026-10-03T10:20:00Z" && o.pipeline_at == "2026-10-03T10:21:00Z" && o.reason.nil?
end
check("J2 a busy deploy waiting for its resource group (no child yet) is not concluded, and says so") do
  o = S.judge(SEL, pipeline: PARENT.merge("status" => "running", "finished_at" => nil),
                   bridge: bridge(2, status: "waiting_for_resource", downstream: nil), child: nil)
  o.state == :busy && o.deploy_at.nil? && o.pipeline_at.nil? && o.reason.include?("waiting_for_resource") &&
    o.reason.include?("\"deploy\"")
end
check("J3 a busy deploy: the child is running") do
  o = S.judge(SEL, pipeline: PARENT.merge("status" => "running", "finished_at" => nil), bridge: bridge(2),
                   child: child(status: "running", finished_at: nil))
  o.state == :busy && o.deploy_at.nil? && o.reason.include?("child pipeline 77 is running")
end
check("J4 a failed deploy concludes with no deploy end (the GitHub rule: only a success ends a deploy)") do
  o = S.judge(SEL, pipeline: PARENT.merge("status" => "failed"), bridge: bridge(2, status: "failed"),
                   child: child(status: "failed"))
  o.state == :concluded && o.deploy_at.nil? && o.pipeline_at.nil?
end
check("J5 a child status this code does not know is a named could-not-measure") do
  o = S.judge(SEL, pipeline: PARENT, bridge: bridge(2), child: child(status: "weird"))
  o.state == :unmeasured && o.reason.include?("\"weird\"")
end
check("J6 a successful child with no finish time is could-not-measure, never a guessed end") do
  o = S.judge(SEL, pipeline: PARENT, bridge: bridge(2), child: child(finished_at: nil))
  o.state == :unmeasured && o.deploy_at.nil? && o.reason.include?("finished_at")
end
check("J7 a child in another project is could-not-measure: the selector reads this project's child") do
  o = S.judge(SEL, pipeline: PARENT, bridge: bridge(2), child: child(project_id: 8))
  o.state == :unmeasured && o.reason.include?("project")
end
check("J8 a trigger job that succeeded with no child is could-not-measure") do
  o = S.judge(SEL, pipeline: PARENT, bridge: bridge(2, downstream: nil), child: nil)
  o.state == :unmeasured && o.reason.include?("no downstream")
end
check("J9 a skipped trigger job with no child concludes with no deploy") do
  o = S.judge(SEL, pipeline: PARENT, bridge: bridge(2, status: "skipped", downstream: nil), child: nil)
  o.state == :concluded && o.deploy_at.nil? && o.pipeline_at == "2026-10-03T10:21:00Z"
end
check("J10 no child= in the selector: the parent's own end, and busy while it runs") do
  done = S.judge(BARE, pipeline: PARENT)
  busy = S.judge(BARE, pipeline: PARENT.merge("status" => "pending", "finished_at" => nil))
  done.state == :concluded && done.deploy_at.nil? && done.pipeline_at == "2026-10-03T10:21:00Z" &&
    busy.state == :busy && busy.reason.include?("pipeline 10 is pending")
end
check("J11 a parent status this code does not know is could-not-measure") do
  S.judge(BARE, pipeline: PARENT.merge("status" => "odd")).state == :unmeasured
end
check("J12 a selector with child= but no bridge given is a caller error, not an idle read") do
  begin
    S.judge(SEL, pipeline: PARENT, bridge: nil)
    false
  rescue ArgumentError
    true
  end
end

if $failures.empty?
  puts "gitlab-pipeline-selector domain: #{$checks}/#{$checks} passed"
  exit 0
end
$failures.each { |f| puts "FAIL #{f}" }
puts "gitlab-pipeline-selector domain: #{$checks - $failures.size}/#{$checks} passed"
puts "Fix: make ai/lib/gitlab_pipeline_selector.rb satisfy each FAIL line above."
exit 1
