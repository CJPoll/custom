# frozen_string_literal: true

# Deterministic suite for the won't-fix veto grant (DND-1758): the request
# arguments a cron poster sends to owner_approval_request for a
# `ticket.wontfix_veto` grant, the classifier that turns the server's answer
# into the notices-file `veto` line, and the CLI's veto-request, veto-form and
# notice --veto-by-grant. No network, no model, no Slack. Synthetic ids only.
# Run by test/self-test.sh, which harness-gate discovers.

require "json"
require "open3"
require "tmpdir"
require_relative "../lib/epic_clustering"
require_relative "../lib/epic_clustering_view"
require_relative "../lib/epic_clustering_veto"

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

EC = EpicClustering
ECV = EpicClusteringView
VETO = EpicClusteringVeto
BIN = File.expand_path("../scripts/epic-clustering", __dir__)
PAGE = "0f0f0f0f-1111-4222-8333-444455556666"
GRANT = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"

def run(*args)
  out, err, st = Open3.capture3(BIN, *args)
  [out, err, st.exitstatus]
end

# ------------------------------------------------------------ request args

check("request_args: the class is ticket.wontfix_veto and the target is exactly {ticket, page_id, reopen_to}") do
  a = VETO.request_args(ticket: "DND-9", page_id: PAGE, reopen_to: "Todo", title: "Tidy the README")
  a["action_class"] == "ticket.wontfix_veto" &&
    a["target"] == { "page_id" => PAGE, "reopen_to" => "Todo", "ticket" => "DND-9" } &&
    a["target"].keys == a["target"].keys.sort && a["note"].include?("Tidy the README") &&
    !a.key?("inbox_name")
end

check("request_args: the note is at most 300 characters (the contract's note limit)") do
  a = VETO.request_args(ticket: "DND-9", page_id: PAGE, reopen_to: "Parked", title: "x" * 900)
  a["note"].length <= 300 && a["target"]["reopen_to"] == "Parked"
end

check("request_args: a malformed target is refused, never coerced (ticket, page id, reopen_to)") do
  raises?(EC::DataError, /ticket/) { VETO.request_args(ticket: "dnd-9", page_id: PAGE, reopen_to: "Todo", title: "t") } &&
    raises?(EC::DataError, /page_id/) do
      VETO.request_args(ticket: "DND-9", page_id: PAGE.upcase, reopen_to: "Todo", title: "t")
    end &&
    raises?(EC::DataError, /page_id/) do
      VETO.request_args(ticket: "DND-9", page_id: PAGE.delete("-"), reopen_to: "Todo", title: "t")
    end &&
    raises?(EC::DataError, /reopen_to/) do
      VETO.request_args(ticket: "DND-9", page_id: PAGE, reopen_to: "Done", title: "t")
    end &&
    raises?(EC::DataError, /title/) { VETO.request_args(ticket: "DND-9", page_id: PAGE, reopen_to: "Todo", title: " ") }
end

# ------------------------------------------------------------ classifier

ok_result = JSON.generate("grant_id" => GRANT, "channel" => "D0FAKE0001", "ts" => "1700000000.000300",
                          "click_expires_at" => "2026-10-09T13:00:00Z")

check("classify: a well-formed grant answer is the grant form, naming the grant and its approval message") do
  VETO.classify(ticket: "DND-9", outcome: [:result, ok_result]) ==
    { form: "grant", line: "veto DND-9 grant #{GRANT} D0FAKE0001/1700000000.000300" }
end

check("classify: a data-wrapped grant answer is read the same") do
  VETO.classify(ticket: "DND-9", outcome: [:result, JSON.generate("data" => JSON.parse(ok_result))])[:form] == "grant"
end

check("classify: no owner_approval_request tool is the by-hand fallback, reason no_tool") do
  VETO.classify(ticket: "DND-9", outcome: :no_tool) == { form: "by-hand", line: "veto DND-9 by-hand no_tool" }
end

check("classify: a server that lacks the tool (unknown tool / method not found) is no_tool too") do
  %w[Unknown\ tool:\ owner_approval_request Method\ not\ found].all? do |t|
    VETO.classify(ticket: "DND-9", outcome: [:refusal, "MCP error -32601: #{t}"])[:line] == "veto DND-9 by-hand no_tool"
  end
end

check("classify: unknown_action_class (the server does not have the class yet) is class_unsupported") do
  text = "MCP error -32000: unknown_action_class: ticket.wontfix_veto. Fix: use one of merge.pr_only_workflow, " \
         "priority.transition"
  VETO.classify(ticket: "DND-9", outcome: [:refusal, text]) ==
    { form: "by-hand", line: "veto DND-9 by-hand class_unsupported" }
end

check("classify: any other named refusal keeps its code; an unnamed one is refused:unparsed") do
  VETO.classify(ticket: "DND-9", outcome: [:refusal, "rate_limited: wait 120 seconds. Fix: ..."])[:line] ==
    "veto DND-9 by-hand refused:rate_limited" &&
    VETO.classify(ticket: "DND-9", outcome: [:refusal, "target_invalid (field page_id); Fix: see ticket_not_wont_fix"])[:line] ==
      "veto DND-9 by-hand refused:target_invalid" &&
    VETO.classify(ticket: "DND-9", outcome: [:refusal, "something broke"])[:line] ==
      "veto DND-9 by-hand refused:unparsed"
end

check("classify: an answer missing grant_id, channel or ts, or with a malformed one, is malformed_result, never a grant") do
  bad = [
    "not json",
    JSON.generate("channel" => "D0FAKE0001", "ts" => "1700000000.000300"),
    JSON.generate("grant_id" => GRANT.upcase, "channel" => "D0FAKE0001", "ts" => "1700000000.000300"),
    JSON.generate("grant_id" => GRANT, "channel" => "d0fake", "ts" => "1700000000.000300"),
    JSON.generate("grant_id" => GRANT, "channel" => "D0FAKE0001", "ts" => 1_700_000_000.0003),
    JSON.generate([1, 2])
  ]
  bad.all? { |b| VETO.classify(ticket: "DND-9", outcome: [:result, b])[:line] == "veto DND-9 by-hand malformed_result" }
end

check("classify: a bad ticket id is refused before any classification") do
  raises?(EC::DataError, /ticket/) { VETO.classify(ticket: "DND-x", outcome: :no_tool) }
end

# ------------------------------------------------------------ notice forms

notice = lambda do |**kw|
  ECV.wont_fix_notice(ticket: "DND-9", title: "Tidy the README", background: "Open 28 days at LOW.",
                      why: "Closing it shrinks the epic.", session: "clustering cron", **kw)
end

check("notice: veto_by_grant offers no buttons of its own and points at the approval message's Reopen") do
  r = notice.call(veto_by_grant: true)
  text = r[:blocks].map { |x| x.dig("text", "text").to_s }.join("\n")
  r[:blocks].none? { |x| x["type"] == "actions" } && r[:text].include?("press Reopen on its approval message") &&
    text.include?("approval message") && text.include?("Todo, or Parked if work exists") &&
    !text.include?("no click could be verified") && text.include?("Silence keeps it closed")
end

check("notice: veto_by_grant and veto_by_hand together are refused") do
  raises?(EC::DataError, /one veto form/) { notice.call(veto_by_grant: true, veto_by_hand: true) }
end

# ------------------------------------------------------------ CLI

check("cli: veto-request writes the owner_approval_request arguments (class, target, note) to --out") do
  Dir.mktmpdir do |d|
    f = File.join(d, "DND-1758-veto-args.json")
    out, _, code = run("veto-request", "--ticket", "DND-9", "--page-id", PAGE, "--reopen-to", "Todo",
                       "--title", "Tidy", "--out", f)
    a = JSON.parse(File.read(f))
    code.zero? && a["action_class"] == "ticket.wontfix_veto" && a["target"]["page_id"] == PAGE &&
      out.include?("owner_approval_request") && out.include?("inbox_name")
  end
end

check("cli: veto-request with a malformed page id is exit 2 with Fix:, and writes nothing") do
  Dir.mktmpdir do |d|
    f = File.join(d, "DND-1758-veto-args.json")
    _, err, code = run("veto-request", "--ticket", "DND-9", "--page-id", "nope", "--reopen-to", "Todo",
                       "--title", "Tidy", "--out", f)
    code == 2 && err.include?("Fix:") && !File.exist?(f)
  end
end

check("cli: veto-form --no-tool prints the by-hand form and its notices line") do
  out, _, code = run("veto-form", "--ticket", "DND-9", "--no-tool")
  code.zero? && out.lines.map(&:chomp) == ["form: by-hand", "line: veto DND-9 by-hand no_tool"]
end

check("cli: veto-form --result FILE prints the grant form; --refusal FILE the by-hand one") do
  Dir.mktmpdir do |d|
    res = File.join(d, "DND-1758-result.json")
    ref = File.join(d, "DND-1758-refusal.txt")
    File.write(res, ok_result)
    File.write(ref, "unknown_action_class: ticket.wontfix_veto")
    o1, _, c1 = run("veto-form", "--ticket", "DND-9", "--result", res)
    o2, _, c2 = run("veto-form", "--ticket", "DND-9", "--refusal", ref)
    c1.zero? && o1.include?("form: grant") && o1.include?("line: veto DND-9 grant #{GRANT} D0FAKE0001/1700000000.000300") &&
      c2.zero? && o2.include?("form: by-hand") && o2.include?("line: veto DND-9 by-hand class_unsupported")
  end
end

check("cli: veto-form needs exactly one outcome; an unreadable file is exit 3, never a fallback line") do
  _, e1, c1 = run("veto-form", "--ticket", "DND-9")
  _, e2, c2 = run("veto-form", "--ticket", "DND-9", "--no-tool", "--refusal", "/dev/null")
  o3, e3, c3 = run("veto-form", "--ticket", "DND-9", "--result", "/nonexistent/DND-1758-result.json")
  c1 == 2 && e1.include?("Fix:") && c2 == 2 && e2.include?("Fix:") &&
    c3 == 3 && e3.include?("Fix:") && !o3.include?("line:")
end

check("cli: notice --veto-by-grant writes blocks with no actions block") do
  Dir.mktmpdir do |d|
    f = File.join(d, "DND-1758-notice.json")
    out, _, code = run("notice", "--ticket", "DND-9", "--title", "Tidy", "--background",
                       "Open 28 days.", "--why", "Shrinks the epic.", "--veto-by-grant", "--blocks-out", f)
    blocks = JSON.parse(File.read(f))
    code.zero? && out.include?("approval message") && blocks.none? { |x| x["type"] == "actions" }
  end
end

check("cli: notice with both --veto-by-grant and --veto-by-hand is exit 2 with Fix:") do
  _, err, code = run("notice", "--ticket", "DND-9", "--title", "Tidy", "--background", "b", "--why", "w",
                     "--veto-by-grant", "--veto-by-hand")
  code == 2 && err.include?("Fix:")
end

if $failures.empty?
  puts "epic-clustering veto self-test: #{$checks} checks passed"
  exit 0
end
warn "epic-clustering veto self-test: #{$failures.size} of #{$checks} checks FAILED:"
$failures.each { |f| warn "  - #{f}" }
warn "Fix: make lib/epic_clustering_veto.rb, lib/epic_clustering_view.rb or scripts/epic-clustering satisfy the " \
     "failed check(s) above (DND-1758)."
exit 1
