# frozen_string_literal: true

# Deterministic suite for ai/lib/block_optimize.rb (DND-528): the pure domain of
# ai/bin/block-optimize. No model, no git, no network. Run by
# ai/lib/test/block-optimize/self-test.sh, which harness-gate discovers.
# Case ids (S*, D*, E*, L*) are the QA plan's on the DND-528 ticket.

require "json"
require_relative "../../block_optimize"

$failures = []
$checks = 0

def check(desc)
  $checks += 1
  $failures << desc unless yield
rescue StandardError => e
  $failures << "#{desc} (raised #{e.class}: #{e.message})"
end

def raises_with(klass, pattern)
  yield
  false
rescue klass => e
  e.message.match?(pattern) && e.message.include?("Fix:")
end

AI_DIR = File.expand_path("../../..", __dir__)
REAL_ROUTING = File.read(File.join(AI_DIR, "blocks", "routing.yml"))
BO = BlockOptimize
TEMPLATE = "ai/agents/athena-admiral.md.in"

# ---------------------------------------------------------------------------
# Scope
# ---------------------------------------------------------------------------
allowed = BO::Scope.allowed_paths(REAL_ROUTING)

check("S1 allowlist from the real routing.yml is the admiral template + its routed blocks minus safety-checks") do
  allowed.sort == [TEMPLATE, "ai/blocks/ops/fleet-coordination.md", "ai/blocks/ops/forge-identity.md",
                   "ai/blocks/ops/never-end-turn-waiting.md"].sort
end
check("S1 safety-checks is never allowlisted") { !allowed.include?("ai/blocks/ops/safety-checks.md") }

check("S2 routing with no admiral consumer raises with Fix:, never an empty list") do
  raises_with(BO::ScopeError, /no block routed to `admiral`/) do
    BO::Scope.allowed_paths("blocks:\n  arch/5-bucket: [captain]\nskills: {}\n")
  end
end
check("S2 unparsable routing raises with Fix:") do
  raises_with(BO::ScopeError, /does not parse/) { BO::Scope.allowed_paths("blocks: [unclosed\n  :") }
end
check("S2 routing without a blocks map raises with Fix:") do
  raises_with(BO::ScopeError, /no `blocks:` map/) { BO::Scope.allowed_paths("skills: {}\n") }
end
check("S2 empty routing text raises with Fix:") do
  raises_with(BO::ScopeError, /no `blocks:` map|does not parse/) { BO::Scope.allowed_paths("") }
end

deny_samples = {
  "ai/bin/check-agent-size" => "ai/bin/",
  "ai/hooks/safe-wait-guard.sh" => "ai/hooks/",
  "ai/eval/admiral-fixtures/AE-18-refused-spawn-is-pause/meta" => "ai/eval/",
  "ai/lib/eval_score.rb" => "ai/lib/",
  "ai/lib/critic_prompt.rb" => "ai/lib/",
  "ai/blocks/ops/safety-checks.md" => "safety-checks",
  "ai/blocks/routing.yml" => "routing.yml",
  "ai/agents/athena-admiral.md" => "rendered agent",
  "ai/tools/risk.yml" => "ai/tools/",
  "ai/inbox/registry.json" => "ai/inbox/",
  "ai/blast-radius/manifest.yml" => "ai/blast-radius/",
  "ai/guard-classification.tsv" => "guard-classification",
  "ai/hooks/registry.json" => "ai/hooks/",
  "some/where/registry.json" => "registry.json"
}
deny_samples.each do |path, why|
  check("S3 denylisted #{path} is a violation even when injected into the allowlist") do
    v = BO::Scope.violations([path], allowed + [path])
    v.size == 1 && v[0][0] == path && v[0][1].include?(why)
  end
end

%w[ai/agents/athena-captain.md.in ai/skills/x/SKILL.md ai/blocks/arch/5-bucket.md CLAUDE.md].each do |path|
  check("S4 allowed-looking but unlisted #{path} is a violation") do
    v = BO::Scope.violations([path], allowed)
    v.size == 1 && v[0][1].include?("not in the allowlist")
  end
end
check("S5 the rendered admiral in the diff is a violation") do
  BO::Scope.violations(["ai/agents/athena-admiral.md"], allowed).size == 1
end
check("Scope: an allowlisted path is clean") { BO::Scope.violations([TEMPLATE], allowed).empty? }
check("Scope: an empty path list has no violations (the diff parser reports zero files, not Scope)") do
  BO::Scope.violations([], allowed).empty?
end
check("Scope.render? matches only a top-level rendered agent") do
  BO::Scope.render?("ai/agents/athena-captain.md") && !BO::Scope.render?("ai/agents/athena-captain.md.in") &&
    !BO::Scope.render?("ai/agents/sub/x.md")
end

# ---------------------------------------------------------------------------
# Diff
# ---------------------------------------------------------------------------
def git_patch(old, new = old, extra: "", minus: "a/#{old}", plus: "b/#{new}")
  <<~P
    diff --git a/#{old} b/#{new}
    #{extra}index 1111111..2222222 100644
    --- #{minus}
    +++ #{plus}
    @@ -1,2 +1,2 @@
     keep
    -old line
    +new line
  P
end

def fenced(body)
  "Here is the diff.\n```diff\n#{body}```\n"
end

d1 = BO::Diff.headers(fenced(git_patch(TEMPLATE)))
check("D1 a modify of an allowed file parses with no violation") do
  d1.is_a?(Hash) && d1[:files] == [TEMPLATE] && d1[:violations].empty?
end
check("D1 a plain unified diff (no `diff --git` line) parses") do
  plain = "--- a/#{TEMPLATE}\n+++ b/#{TEMPLATE}\n@@ -1 +1 @@\n-a\n+b\n"
  r = BO::Diff.headers(fenced(plain))
  r[:files] == [TEMPLATE] && r[:violations].empty?
end
check("D1 --diff input may be raw (unfenced) when fenced: false") do
  r = BO::Diff.headers(git_patch(TEMPLATE), fenced: false)
  r[:files] == [TEMPLATE] && r[:violations].empty?
end
check("D1 extract returns the patch body with a trailing newline") do
  BO::Diff.extract(fenced(git_patch(TEMPLATE))) == git_patch(TEMPLATE)
end

d2 = {
  "rename" => [git_patch(TEMPLATE, "ai/blocks/ops/forge-identity.md",
                         extra: "similarity index 90%\nrename from #{TEMPLATE}\nrename to ai/blocks/ops/forge-identity.md\n"),
               /rename/],
  "copy" => [git_patch(TEMPLATE, "ai/blocks/ops/forge-identity.md",
                       extra: "copy from #{TEMPLATE}\ncopy to ai/blocks/ops/forge-identity.md\n"), /copy/],
  "new file" => [git_patch(TEMPLATE, extra: "new file mode 100644\n", minus: "/dev/null"), /new file/],
  "delete" => [git_patch(TEMPLATE, extra: "deleted file mode 100644\n", plus: "/dev/null"), /delet/],
  "mode change" => [git_patch(TEMPLATE, extra: "old mode 100644\nnew mode 100755\n"), /mode/],
  "binary" => ["diff --git a/#{TEMPLATE} b/#{TEMPLATE}\nindex 1..2 100644\nBinary files a/#{TEMPLATE} and " \
               "b/#{TEMPLATE} differ\n", /binary/i],
  "symlink" => [git_patch(TEMPLATE).sub("100644", "120000"), /symlink/],
  "bare /dev/null new" => ["--- /dev/null\n+++ b/#{TEMPLATE}\n@@ -0,0 +1 @@\n+x\n", /new file/]
}
d2.each do |label, (patch, want)|
  check("D2 #{label} is a violation") do
    r = BO::Diff.headers(fenced(patch))
    r.is_a?(Hash) && r[:violations].any? { |(_p, why)| why.match?(want) }
  end
end

{
  "dotdot" => git_patch("ai/blocks/../bin/x"),
  "absolute" => "--- /etc/passwd\n+++ /etc/passwd\n@@ -1 +1 @@\n-a\n+b\n",
  "a/b mismatch" => git_patch(TEMPLATE, "ai/blocks/ops/forge-identity.md"),
  "---/+++ mismatch" => git_patch(TEMPLATE, minus: "a/#{TEMPLATE}", plus: "b/ai/bin/x"),
  "empty segment" => git_patch("ai//bin/x"),
  "dot segment" => git_patch("ai/./bin/x"),
  "missing a/ prefix" => git_patch(TEMPLATE, minus: TEMPLATE, plus: TEMPLATE)
}.each do |label, patch|
  check("D3 #{label} is a violation") do
    r = BO::Diff.headers(fenced(patch))
    r.is_a?(Hash) && !r[:violations].empty?
  end
end

check("D4 blank text is :no_proposal") { BO::Diff.headers("  \n") == :no_proposal }
check("D4 nil is :no_proposal") { BO::Diff.headers(nil) == :no_proposal }
check("D4 prose with no fenced diff is :no_proposal") do
  BO::Diff.headers("I cannot improve this.\n#{git_patch(TEMPLATE)}") == :no_proposal
end
check("D4 a fenced block with zero file headers is a violation, distinct from :no_proposal") do
  r = BO::Diff.headers("```diff\nnothing here\n```\n")
  r.is_a?(Hash) && r[:files].empty? && r[:violations].any? { |(_p, why)| why.include?("no file header") }
end
check("D4 two fenced diffs are a violation (exactly one candidate)") do
  r = BO::Diff.headers(fenced(git_patch(TEMPLATE)) + fenced(git_patch(TEMPLATE)))
  r.is_a?(Hash) && r[:violations].any? { |(_p, why)| why.include?("more than one") }
end
check("Diff: two files in one patch list both") do
  both = git_patch(TEMPLATE) + git_patch("ai/blocks/ops/forge-identity.md")
  BO::Diff.headers(fenced(both))[:files] == [TEMPLATE, "ai/blocks/ops/forge-identity.md"]
end

# ---------------------------------------------------------------------------
# Evidence
# ---------------------------------------------------------------------------
CASE = "AE-18-refused-spawn-is-pause"
SHA12 = "623d9db81022"
def evidence(rows, subject: true)
  head = subject ? "subject: /x/ai/agents/athena-admiral.md 499 lines sha #{SHA12} (loaded inline via --agents as k)\n" : ""
  "#{head}#{rows}admiral-eval: 1/2 cases pass (runs/T2 case = 10)\n"
end
ROW18 = "PASS #{CASE}       8/10   [next-action] ok\n"
ROW13 = "PASS AE-13a-forge-auth-deny             1/1    [hook-stdin] guard=x\n"

e1 = BO::Evidence.parse(evidence(ROW18 + ROW13), CASE)
check("E1 a T2 row with k<n and a subject line parses") do
  e1 == { case_name: CASE, k: 8, n: 10, mode: "next-action", detail: "ok", subject_sha12: SHA12 }
end
check("E1 a FAIL row with k<n parses too") do
  BO::Evidence.parse(evidence("FAIL #{CASE} 2/10 [next-action] no trailer\n"), CASE)[:k] == 2
end
check("E1 --case AE-18 resolves the unique `AE-18-` fixture") do
  BO::Evidence.parse(evidence(ROW18 + "PASS AE-18b-checkpoint-before-refill 10/10 [next-action] ok\n"),
                     "AE-18")[:case_name] == CASE
end
check("E1 an ambiguous short case raises with Fix:") do
  raises_with(BO::EvidenceError, /ambiguous/) do
    BO::Evidence.parse(evidence(ROW18 + "PASS AE-18-other 3/10 [next-action] ok\n"), "AE-18")
  end
end
check("E2 case absent raises") do
  raises_with(BO::EvidenceError, /no row for case/) { BO::Evidence.parse(evidence(ROW13), CASE) }
end
check("E3 k == n raises (not a failure)") do
  raises_with(BO::EvidenceError, /not a failure/) do
    BO::Evidence.parse(evidence("PASS #{CASE} 10/10 [next-action] ok\n"), CASE)
  end
end
check("E4 0/0 raises (unsampled)") do
  raises_with(BO::EvidenceError, /unsampled/) do
    BO::Evidence.parse(evidence("FAIL #{CASE} 0/0 [next-action] invalid case config\n"), CASE)
  end
end
check("E5 a [hook-stdin] row raises (a hook, not prose)") do
  raises_with(BO::EvidenceError, /hook/) do
    BO::Evidence.parse(evidence("FAIL AE-13a-forge-auth-deny 0/1 [hook-stdin] got=clean\n"), "AE-13a-forge-auth-deny")
  end
end
check("E6 no subject: line raises") do
  raises_with(BO::EvidenceError, /no `subject:` line/) { BO::Evidence.parse(evidence(ROW18, subject: false), CASE) }
end
check("E6 two different subject lines raise") do
  two = evidence(ROW18) + "subject: /y 1 lines sha aaaaaaaaaaaa (loaded inline via --agents as k)\n"
  raises_with(BO::EvidenceError, /more than one `subject:`/) { BO::Evidence.parse(two, CASE) }
end
check("E-dup two rows for the case raise") do
  raises_with(BO::EvidenceError, /more than one row/) { BO::Evidence.parse(evidence(ROW18 + ROW18), CASE) }
end
check("E-mode a row with no [mode] raises") do
  raises_with(BO::EvidenceError, /no \[mode\]/) { BO::Evidence.parse(evidence("FAIL #{CASE} 2/10\n"), CASE) }
end
check("E-blank empty evidence raises") do
  raises_with(BO::EvidenceError, /empty/) { BO::Evidence.parse("", CASE) }
end
check("E7 subject sha12 != base render raises STALE") do
  raises_with(BO::EvidenceError, /STALE/) { BO::Evidence.check_subject!(e1, "d6934f982adc" + "0" * 52) }
end
check("E7 a matching subject passes") { BO::Evidence.check_subject!(e1, SHA12 + "0" * 52).nil? }

# ---------------------------------------------------------------------------
# Label
# ---------------------------------------------------------------------------
VAR = "a" * 40
BASE = "b" * 40
SUBJ_B = { "lines" => 470, "sha256" => "1" * 64 }.freeze
SUBJ_V = { "lines" => 470, "sha256" => "2" * 64 }.freeze

def row(name, bk, vk, flip, n: 10)
  { "name" => name, "base" => bk && { "k" => bk, "n" => n }, "var" => vk && { "k" => vk, "n" => n }, "flip" => flip }
end

def proposal(verdict:, t2: [row(CASE, 8, 9, "inconclusive")], regressions: [], improvements: [])
  scored = !%w[blocked unmeasured].include?(verdict)
  {
    "schema" => "variant-eval/proposal@1", "variant" => VAR, "variant_sha" => VAR, "baseline" => BASE,
    "baseline_sha" => BASE, "corpus" => "full", "runs" => 10, "gate_ok" => verdict != "blocked",
    "gate_detail" => verdict == "blocked" ? ["harness-gate: FAIL x"] : nil, "verdict" => verdict,
    "unmeasured" => verdict == "unmeasured" ? { "side" => "variant", "part" => "T2", "reason" => "auth" } : nil,
    "deterministic" => { "regressed" => [], "fixed" => [], "new" => [] },
    "t2_subjects" => { "base" => SUBJ_B, "var" => SUBJ_V }, "t2" => scored ? t2 : nil,
    "regressions" => scored ? regressions : nil, "improvements" => scored ? improvements : nil
  }
end

def decide(json, renders: [])
  BO::Label.decide(json, target: CASE, variant_sha: VAR, baseline_sha: BASE, renders_changed: renders)
end

l1 = decide(proposal(verdict: "blocked"))
check("L1 BLOCKED is REJECTED, never UNPROVEN") { l1[:label] == :rejected && l1[:reason].include?("BLOCKED") }
l2 = decide(proposal(verdict: "unmeasured"))
check("L2 UNMEASURED is REJECTED") { l2[:label] == :rejected && l2[:reason].include?("UNMEASURED") }
l3 = decide(proposal(verdict: "revert", t2: [row(CASE, 8, 9, "inconclusive"), row("AE-01-x", 10, 5, "regressed")],
                     regressions: ["t2:AE-01-x"]))
check("L3 REVERT is REJECTED and names the regressions") do
  l3[:label] == :rejected && l3[:reason].include?("REVERT") && l3[:reason].include?("t2:AE-01-x")
end
l3m = decide(proposal(verdict: "revert", t2: [row(CASE, 8, 9, "inconclusive"), row("AE-02-x", 10, nil, "missing")],
                      regressions: ["t2:AE-02-x"]))
check("L3 a `missing` case is REJECTED") { l3m[:label] == :rejected && l3m[:reason].include?("AE-02-x") }
l4 = decide(proposal(verdict: "inconclusive").merge("t2_subjects" => { "base" => SUBJ_B, "var" => SUBJ_B }))
check("L4 equal T2 subjects are REJECTED (nothing the corpus can measure)") do
  l4[:label] == :rejected && l4[:reason].include?("unchanged")
end

l5 = decide(proposal(verdict: "keep", t2: [row(CASE, 3, 10, "improved")], improvements: ["t2:#{CASE}"]))
check("L5 keep + target improved is MEASURED IMPROVEMENT") { l5[:label] == :improvement }
check("L5 carries the target's base/var scores") do
  l5[:target_row][:base][:k] == 3 && l5[:target_row][:var][:k] == 10 && l5[:target_row][:base][:lo].is_a?(Float)
end

l6 = decide(proposal(verdict: "keep", t2: [row(CASE, 8, 9, "inconclusive"), row("AE-19c-x", 0, 10, "improved")],
                     improvements: ["t2:AE-19c-x"]))
check("L6 keep via another case, target inconclusive, is UNPROVEN") { l6[:label] == :unproven }
check("L6 other improvements are listed separately, never credited to the target") do
  l6[:others_improved] == ["t2:AE-19c-x"]
end
check("L6 deterministic fixes count as other improvements") do
  j = proposal(verdict: "keep", improvements: ["he:x"])
      .merge("deterministic" => { "regressed" => [], "fixed" => ["he:x"], "new" => [] })
  decide(j)[:others_improved] == ["he:x"]
end

l7 = decide(proposal(verdict: "inconclusive"))
check("L7 inconclusive at base 8/10 is UNPROVEN") { l7[:label] == :unproven }
check("L7 headroom 0.20 <= envelope reads as cannot confirm") do
  (l7[:headroom][:value] - 0.2).abs < 1e-9 && l7[:headroom][:cannot_confirm] == true
end
check("L7 headroom above the envelope can confirm") do
  decide(proposal(verdict: "inconclusive", t2: [row(CASE, 5, 6, "inconclusive")]))[:headroom][:cannot_confirm] == false
end
check("L7 headroom of exactly the envelope (7/10) cannot confirm") do
  decide(proposal(verdict: "inconclusive", t2: [row(CASE, 7, 8, "inconclusive")]))[:headroom][:cannot_confirm] == true
end

malformed = {
  "L8 target row absent" => proposal(verdict: "keep", t2: [row("AE-01-x", 9, 10, "improved")],
                                     improvements: ["t2:AE-01-x"]),
  "L8 t2 null under keep" => proposal(verdict: "keep").merge("t2" => nil),
  "L8 regressions null under inconclusive" => proposal(verdict: "inconclusive").merge("regressions" => nil),
  "L8 t2_subjects null" => proposal(verdict: "inconclusive").merge("t2_subjects" => nil),
  "L8 target base unmeasured" => proposal(verdict: "inconclusive", t2: [row(CASE, nil, 9, "new")]),
  "L8 regression flip under a keep verdict" => proposal(verdict: "keep", t2: [row(CASE, 8, 2, "regressed")]),
  "L8 unknown verdict" => proposal(verdict: "adopt"),
  "L8 wrong variant_sha (another run's JSON)" => proposal(verdict: "inconclusive").merge("variant_sha" => "c" * 40),
  "L8 wrong baseline_sha" => proposal(verdict: "inconclusive").merge("baseline_sha" => "c" * 40),
  "L8 deterministic corpus" => proposal(verdict: "inconclusive").merge("corpus" => "deterministic", "runs" => nil),
  "L8 runs not 10" => proposal(verdict: "inconclusive").merge("runs" => 3),
  "L9 wrong schema" => proposal(verdict: "inconclusive").merge("schema" => "variant-eval/proposal@2"),
  "L9 missing schema" => proposal(verdict: "inconclusive").tap { |h| h.delete("schema") },
  "L9 not an object" => [1, 2]
}
malformed.each do |label, j|
  check("#{label} is REJECTED as malformed, never UNPROVEN") do
    r = decide(j)
    r[:label] == :rejected && r[:reason].include?("malformed")
  end
end

l11 = decide(proposal(verdict: "inconclusive"), renders: %w[ai/agents/athena-admiral.md ai/agents/athena-captain.md])
check("L11 other changed renders are listed as UNMEASURED") { l11[:unmeasured_renders] == ["athena-captain"] }
check("L11 no other renders changed -> empty list") do
  decide(proposal(verdict: "inconclusive"), renders: ["ai/agents/athena-admiral.md"])[:unmeasured_renders] == []
end

# ---------------------------------------------------------------------------
# Reference band
# ---------------------------------------------------------------------------
NB = JSON.parse(File.read(File.join(AI_DIR, "eval", "noise-band.json")))
NB_SHA = NB.dig("comparability", "subject", "sha256")

check("L10 band for a stochastic case at a matching subject") do
  b = BO::Reference.band(NB, CASE, NB_SHA)
  b.is_a?(Hash) && b[:k] == 31 && b[:n] == 40 && (b[:p] - 0.775).abs < 1e-9 && b[:lo] < 0.775 && b[:hi] > 0.775
end
check("L10 band for a stable_pass member uses `each`") do
  b = BO::Reference.band(NB, "AE-03-dm-after-confirm", NB_SHA)
  b.is_a?(Hash) && b[:k] == 40 && b[:n] == 40
end
check("L10 band for a named stable_pass entry") { BO::Reference.band(NB, "AE-01-confirm-before-done", NB_SHA)[:n] == 50 }
check("L10 band for a deterministic_fail case") { BO::Reference.band(NB, "AE-19c-drained-after-last-return", NB_SHA)[:k].zero? }
check("L10 mismatched subject -> n/a with a reason") do
  r = BO::Reference.band(NB, CASE, "0" * 64)
  r.is_a?(Array) && r[0] == :n_a && r[1].include?("subject")
end
check("L10 case not in the band -> n/a with a reason") do
  r = BO::Reference.band(NB, "AE-99-nope", NB_SHA)
  r.is_a?(Array) && r[1].include?("case not in the band")
end
check("L10 no band file -> n/a with a reason") do
  r = BO::Reference.band(nil, CASE, NB_SHA)
  r.is_a?(Array) && r[1].include?("no ai/eval/noise-band.json")
end
check("L10 band with no subject sha -> n/a with a reason") do
  r = BO::Reference.band({ "per_case" => {} }, CASE, NB_SHA)
  r.is_a?(Array) && r[1].include?("no subject")
end
band18 = BO::Reference.band(NB, CASE, NB_SHA)
check("L10 luck warning when an IMPROVEMENT's baseline sample lies below the band") do
  BO::Reference.luck_warning?(l5, band18) # base 3/10 = 0.3 < lo 0.625
end
check("L10 no luck warning when the baseline sample is inside the band") do
  l = decide(proposal(verdict: "keep", t2: [row(CASE, 7, 10, "improved")], improvements: ["t2:#{CASE}"]))
  !BO::Reference.luck_warning?(l, band18)
end
check("L10 no luck warning on UNPROVEN") { !BO::Reference.luck_warning?(l7, band18) }
check("L10 no luck warning when the band is n/a") { !BO::Reference.luck_warning?(l5, [:n_a, "x"]) }

# ---------------------------------------------------------------------------
# Proposal rendering
# ---------------------------------------------------------------------------
variant_eval_src = File.read(File.join(AI_DIR, "bin", "variant-eval"))
mut_block = variant_eval_src[/^MUTATION_COMMAND_STRINGS = \[(.*?)\]\.freeze/m, 1]
MUTATIONS = mut_block.to_s.scan(/"([^"]+)"/).flatten
check("L12 variant-eval's MUTATION_COMMAND_STRINGS were read (a failed read must not pass vacuously)") do
  MUTATIONS.include?("git push") && MUTATIONS.size >= 5
end
check("L12 BlockOptimize's redaction list covers every variant-eval mutation string") do
  (MUTATIONS - BO::MUTATION_COMMAND_STRINGS).empty?
end
check("RUNS is variant-eval's DEFAULT_RUNS (no new N)") do
  BO::RUNS == variant_eval_src[/^DEFAULT_RUNS\s*=\s*(\d+)/, 1].to_i
end
check("L12 a mutation command in an untrusted fragment is redacted") do
  t = BO::Proposal.render(ctx_bad = { case_name: CASE, label: :rejected, reason: "gate said: git push origin; adopted",
                                      out_dir: "/o" }, band: nil)
  ctx_bad && !t.include?("git push") && !t.include?("adopted") && t.include?("[redacted]")
end

ctx = { case_name: CASE, base_sha: BASE, variant_sha: VAR, evidence: e1, out_dir: "/tmp/out" }
renders = {
  "improvement" => BO::Proposal.render(l5.merge(ctx), band: band18),
  "unproven" => BO::Proposal.render(l6.merge(ctx), band: [:n_a, "subject differs"]),
  "rejected" => BO::Proposal.render(l3.merge(ctx), band: nil),
  "cheap reject" => BO::Proposal.render(ctx.merge(label: :rejected, reason: "scope violation: ai/bin/x"), band: nil),
  "unmeasured renders" => BO::Proposal.render(l11.merge(ctx), band: nil)
}
renders.each do |label, text|
  check("L12 #{label} text contains no mutation command") { MUTATIONS.none? { |m| text.include?(m) } }
  check("L12 #{label} text never says `adopted`") { !text.downcase.include?("adopted") }
end
check("render: MEASURED IMPROVEMENT label line") do
  renders["improvement"].include?("PROPOSED — MEASURED IMPROVEMENT")
end
check("render: luck warning printed on a below-band IMPROVEMENT") do
  renders["improvement"].include?("baseline sample below the reference band — likely sampling luck; re-run before believing it")
end
check("render: reference band printed with p and Wilson band") { renders["improvement"].match?(/reference band: p=0\.78 \[0\.\d\d,0\.\d\d\]/) }
check("render: UNPROVEN label line") do
  renders["unproven"].include?("PROPOSED — NO MEASURED REGRESSION; IMPROVEMENT UNPROVEN")
end
check("render: n/a reference band states why") { renders["unproven"].include?("reference band: n/a (subject differs)") }
check("render: other improvements listed separately") do
  renders["unproven"].include?("other improved cases (not credited to #{CASE}): t2:AE-19c-x")
end
check("render: target base/var Wilson scores printed") { renders["unproven"].match?(/base 0\.80 \[/) }
check("render: headroom states the rule cannot confirm") do
  BO::Proposal.render(l7.merge(ctx), band: nil).include?("the rule cannot confirm a gain for this case at this baseline")
end
check("render: REJECTED label line with reason") { renders["rejected"].include?("REJECTED: REVERT") }
check("render: blast radius `none` when no other render changed") { renders["unproven"].include?("blast radius: none") }
check("render: blast radius lists UNMEASURED renders") do
  renders["unmeasured renders"].include?("UNMEASURED (no behavioral corpus): athena-captain")
end
check("render: the no-regression gate is described as a tripwire, not a proof") do
  renders["unproven"].include?("tripwire")
end

if $failures.empty?
  puts "block-optimize domain: #{$checks} checks OK"
  exit 0
end
warn "block-optimize domain: #{$failures.size} of #{$checks} checks FAILED:"
$failures.each { |f| warn "  - #{f}" }
warn "  Fix: ai/lib/block_optimize.rb must match the DND-528 QA plan (S/D/E/L cases above)."
exit 1
