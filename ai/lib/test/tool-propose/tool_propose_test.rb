# frozen_string_literal: true

# Deterministic suite for the pure domain of ai/bin/tool-propose (DND-176):
# ai/lib/tool_propose/{target,candidate,label}.rb. No IO, no git, no model, no
# sandbox. Case ids (D-T*, D-C*, D-L*) are the DND-176 QA plan's. Run by
# ai/lib/test/tool-propose/self-test.sh, which harness-gate discovers.

require "json"
require_relative "../../tool_propose/target"
require_relative "../../tool_propose/candidate"
require_relative "../../tool_propose/label"
require_relative "../../tool_propose/out_dir"

$failures = []
$checks = 0

def check(desc)
  $checks += 1
  $failures << desc unless yield
rescue StandardError => e
  $failures << "#{desc} (raised #{e.class}: #{e.message})"
end

T = ToolPropose::Target
C = ToolPropose::Candidate
L = ToolPropose::Label
SHA = "b" * 40
CAND = "c" * 40

def err?(result, pattern)
  result[0] == :error && result[1].match?(pattern)
end

def meta(name, guard: "foo-check", mode: "bin-stdin", expect: "fires", input: "in.txt", args: nil)
  m = { "regression" => "r-#{name}", "guard" => guard, "mode" => mode, "expect" => expect, "input" => input }
  m["args"] = args if args
  { name: name, meta: m, input: "bytes-#{name}\n" }
end

NO_BINS = { bin: false, self_test: false }.freeze
PAIR = [meta("20-foo-fires", expect: "fires"), meta("21-foo-clean", expect: "clean")].freeze

# ---------------------------------------------------------------------------
# Target.parse_meta / resolve / validate
# ---------------------------------------------------------------------------
check("parse_meta reads key=value, skips comments and blanks") do
  T.parse_meta("# c\nguard = foo-check\n\nmode=bin-stdin\nargs=[\"a=b\"]\n") ==
    { "guard" => "foo-check", "mode" => "bin-stdin", "args" => "[\"a=b\"]" }
end

names = %w[15-a 16-b 20-foo-fires 21-foo-clean]
check("D-T1 full names resolve") { T.resolve(%w[20-foo-fires 21-foo-clean], names, sha: SHA) == [:ok, %w[20-foo-fires 21-foo-clean]] }
check("D-T1 a unique prefix resolves") { T.resolve(%w[20 21], names, sha: SHA) == [:ok, %w[20-foo-fires 21-foo-clean]] }
check("D-T2 a prefix matching none names the prefix") { err?(T.resolve(%w[99], names, sha: SHA), /99/) }
check("D-T3 a prefix matching two lists both") do
  r = T.resolve(%w[1], names, sha: SHA)
  err?(r, /15-a/) && err?(r, /16-b/)
end
check("D-T10 no match names the sha (not on origin/main at <sha>)") do
  err?(T.resolve(%w[99-x], names, sha: SHA), /not on origin\/main at #{SHA}/)
end
check("resolve refuses the same fixture named twice") { err?(T.resolve(%w[20 20-foo-fires], names, sha: SHA), /twice/) }
check("resolve refuses an empty prefix and no prefixes") do
  err?(T.resolve([""], names, sha: SHA), /empty/) && err?(T.resolve([], names, sha: SHA), /--case/)
end
check("resolve refuses a prefix that is a path") { err?(T.resolve(%w[../x], names, sha: SHA), /bad case/) }

check("D-T1 valid pair") do
  r = T.validate(PAIR, existing: NO_BINS)
  r[0] == :ok && r[1][:guard] == "foo-check" && r[1][:cases].map { |c| c[:expect] } == %w[fires clean] &&
    r[1][:cases].first[:input] == "bytes-20-foo-fires\n" && r[1][:cases].first[:args] == []
end
check("D-T1 args are parsed") do
  r = T.validate([meta("20-x", args: '["--strict"]'), meta("21-y", expect: "clean")], existing: NO_BINS)
  r[0] == :ok && r[1][:cases].first[:args] == ["--strict"]
end
check("D-T4 wrong mode") { err?(T.validate([meta("20-x", mode: "hook-stdin"), PAIR[1]], existing: NO_BINS), /mode/) }
check("D-T5 two guards") do
  err?(T.validate([meta("20-x"), meta("21-y", guard: "bar-check", expect: "clean")], existing: NO_BINS), /one tool per run/)
end
check("D-T6 only fires") { err?(T.validate([meta("20-x"), meta("21-y")], existing: NO_BINS), /needs >=1 clean/) }
check("D-T7 only clean") do
  err?(T.validate([meta("20-x", expect: "clean"), meta("21-y", expect: "clean")], existing: NO_BINS), /needs >=1 fires/)
end
check("D-T8 tool already exists") { err?(T.validate(PAIR, existing: { bin: true, self_test: false }), /new tools only/) }
check("D-T8 its self-test path already exists") { err?(T.validate(PAIR, existing: { bin: false, self_test: true }), /new tools only/) }
check("D-T9 bad guard name") do
  %w[../x X-up a /bin/sh].all? { |g| err?(T.validate([meta("20-x", guard: g), meta("21-y", guard: g, expect: "clean")], existing: NO_BINS), /guard/) }
end
check("validate refuses a bad expect, a bad input name, a missing input, bad args") do
  err?(T.validate([meta("20-x", expect: "pass"), PAIR[1]], existing: NO_BINS), /expect/) &&
    err?(T.validate([meta("20-x", input: "../in"), PAIR[1]], existing: NO_BINS), /input/) &&
    err?(T.validate([PAIR[0].merge(input: nil), PAIR[1]], existing: NO_BINS), /input/) &&
    err?(T.validate([meta("20-x", args: "{"), PAIR[1]], existing: NO_BINS), /args/)
end
check("validate needs existence facts (a missing fact is an error, not a pass)") do
  err?(T.validate(PAIR, existing: {}), /existence/)
end
check("the guard regex is harness-eval's") do
  he = File.read(File.expand_path("../../../bin/harness-eval", __dir__))
  he.include?("GUARD_NAME_RE = #{T::GUARD_NAME_RE.inspect}") && he.include?("INPUT_NAME_RE = #{T::INPUT_NAME_RE.inspect}")
end

# ---------------------------------------------------------------------------
# Candidate
# ---------------------------------------------------------------------------
GOOD = <<~BASH
  #!/usr/bin/env bash
  # foo-check: flags the word bad
  case "${1:-}" in
    --help) echo "usage: foo-check < input"; exit 0 ;;
    --self-test) echo ok; exit 0 ;;
  esac
  if grep -q bad; then echo "Fix: remove bad"; exit 1; fi
  exit 0
BASH

check("D-C1 one fenced block is extracted") do
  C.extract("Here it is:\n```bash\n#{GOOD}```\nThat is all.\n") == [:ok, GOOD]
end
check("D-C1 a bare fence works too") { C.extract("```\n#{GOOD}```\n") == [:ok, GOOD] }
check("D-C2 zero blocks") { err?(C.extract("no code here"), /exactly one fenced/) }
check("D-C2 two blocks") { err?(C.extract("```\na\n```\n```\nb\n```\n"), /exactly one fenced/) }
check("D-C2 an unclosed block") { err?(C.extract("```\na\n"), /exactly one fenced/) }
check("D-C1 validate accepts a good candidate") { C.validate(GOOD) == [:ok, GOOD] }
check("D-C3 missing --self-test names the token") { err?(C.validate(GOOD.gsub("--self-test", "--selftest")), /--self-test/) }
check("D-C4 missing --help names the token") { err?(C.validate(GOOD.gsub("--help", "--hlp")), /--help/) }
check("D-C4 missing Fix: names the token") { err?(C.validate(GOOD.gsub("Fix:", "Fx:")), /Fix:/) }
check("D-C5 shebang not allowlisted") do
  err?(C.validate(GOOD.sub("#!/usr/bin/env bash", "#!/usr/bin/python3")), /shebang/) &&
    err?(C.validate(GOOD.lines.drop(1).join), /shebang/)
end
check("D-C5 each allowlisted shebang passes") do
  C::SHEBANGS.all? { |s| C.validate(GOOD.sub("#!/usr/bin/env bash", s))[0] == :ok }
end
check("D-C6 too big") { err?(C.validate(GOOD + ("#" * 41 * 1024)), /KiB/) }
check("D-C6 NUL") { err?(C.validate(GOOD + "\0"), /NUL/) }
check("D-C6 invalid UTF-8") { err?(C.validate(GOOD + "\xff".b), /UTF-8/) }
check("validate refuses empty and non-String") { err?(C.validate(""), /empty/) && err?(C.validate(nil), /empty/) }

check("D-C7 provenance at line 2, the rest byte-identical") do
  out = C.with_provenance(GOOD, "run-1")
  lines = out.lines
  lines[0] == GOOD.lines[0] && lines[1] == "# athena-tool-propose: candidate run run-1; human adoption only " \
                                         "(ai/docs/tool-propose.md)\n" &&
    lines.drop(2).join == GOOD.lines.drop(1).join
end
check("D-C7 provenance refuses a run id with a newline") { raises = begin; C.with_provenance(GOOD, "a\nb"); false; rescue ArgumentError; true; end; raises }

check("D-C8 self-test template runs the tool's --self-test and exits with its status") do
  s = C.self_test_script("foo-check")
  s.start_with?("#!/usr/bin/env bash\n") && s.include?('exec "${root}/ai/bin/foo-check" --self-test') &&
    s.include?("set -euo pipefail")
end

check("D-C9 prompt carries the tool name, inputs, expects, args, regression, contract") do
  r = T.validate([meta("20-x", args: '["--strict"]'), meta("21-y", expect: "clean")], existing: NO_BINS)[1]
  pr = C.prompt(guard: r[:guard], cases: r[:cases])
  ["ai/bin/foo-check", "bytes-20-x", "bytes-21-y", "expect: fires", "expect: clean", "--strict", "r-20-x",
   "exit 0", "Fix:", "--help", "--self-test", "stdlib only", "no network", "TMPDIR", "exactly one fenced"]
    .all? { |needle| pr.include?(needle) }
end

RISK = "default: destructive\ntools:\n  block-optimize: { class: idempotent, reason: propose }\n"
check("risk entry is appended, destructive/generated, and parses") do
  r = C.risk_text(RISK, "foo-check")
  r[0] == :ok && r[1].start_with?(RISK) && r[1].end_with?("  foo-check: { class: destructive, reason: generated }\n")
end
check("risk entry refuses a key that is already there") { err?(C.risk_text(RISK, "block-optimize"), /already/) }
check("risk entry refuses an unparseable registry") { err?(C.risk_text("tools: [\n", "foo-check"), /risk.yml/) }
check("risk entry adds a missing final newline") { C.risk_text(RISK.chomp, "foo-check")[1].include?("propose }\n  foo-check") }

GATE = "x = 1\nINLINE_SELF_TEST_COVERED_BY = {\n  \"ai/bin/a\" => \"ai/test/a/self-test.sh\",\n}.freeze\n"
check("gate coverage line is inserted after the map's opening line") do
  r = C.gate_text(GATE, "foo-check")
  r[0] == :ok && r[1].include?("INLINE_SELF_TEST_COVERED_BY = {\n  \"ai/bin/foo-check\" => " \
                               "\"ai/test/tool-propose/foo-check/self-test.sh\",\n  \"ai/bin/a\"")
end
check("gate coverage refuses a missing or doubled anchor, and a Ruby syntax error") do
  err?(C.gate_text("x = 1\n", "foo-check"), /INLINE_SELF_TEST_COVERED_BY/) &&
    err?(C.gate_text(GATE + GATE, "foo-check"), /INLINE_SELF_TEST_COVERED_BY/) &&
    err?(C.gate_text(GATE.sub("}.freeze", "}.freeze(("), "foo-check"), /parse/)
end
check("gate coverage refuses a tool already mapped") do
  err?(C.gate_text(GATE.sub("ai/bin/a", "ai/bin/foo-check"), "foo-check"), /already/)
end

check("files lists exactly the four built paths with their modes") do
  f = C.files(guard: "foo-check", text: GOOD, run_id: "r", risk: "R", gate: "G")
  f.keys.sort == ["ai/bin/foo-check", "ai/bin/harness-gate", "ai/test/tool-propose/foo-check/self-test.sh",
                  "ai/tools/risk.yml"].sort &&
    f["ai/bin/foo-check"][0] == "100755" && f["ai/tools/risk.yml"] == %w[100644 R] &&
    f["ai/bin/harness-gate"][0] == "100755" && f["ai/test/tool-propose/foo-check/self-test.sh"][0] == "100755"
end
check("check_paths accepts exactly the built set") do
  C.check_paths(C.files(guard: "foo-check", text: GOOD, run_id: "r", risk: "R", gate: "G").keys, "foo-check") == [:ok, nil]
end
check("D-C10 a diff touching ai/eval is REJECTED: candidate touches eval fixtures") do
  paths = C.files(guard: "foo-check", text: GOOD, run_id: "r", risk: "R", gate: "G").keys + ["ai/eval/fixtures/99-x/meta"]
  err?(C.check_paths(paths, "foo-check"), /touches eval fixtures/)
end
check("check_paths refuses any other extra or missing path") do
  base = C.files(guard: "foo-check", text: GOOD, run_id: "r", risk: "R", gate: "G").keys
  err?(C.check_paths(base + ["ai/hooks/x.sh"], "foo-check"), /ai\/hooks\/x.sh/) &&
    err?(C.check_paths(base.drop(1), "foo-check"), /missing/)
end

# ---------------------------------------------------------------------------
# Label.decide
# ---------------------------------------------------------------------------
TARGETS = [{ name: "20-foo-fires", expect: "fires" }, { name: "21-foo-clean", expect: "clean" }].freeze
ISO_OK = { "20-foo-fires" => "fires", "21-foo-clean" => "clean" }.freeze

def json(verdict: "keep", fixed: %w[he:20-foo-fires he:21-foo-clean], new_cases: [], regressed: [],
         regressions: :auto, variant_sha: CAND, baseline_sha: SHA, schema: "variant-eval/proposal@1",
         gate_detail: nil, unmeasured: nil, corpus: "deterministic")
  regs = regressions == :auto ? (%w[keep inconclusive revert].include?(verdict) ? regressed : nil) : regressions
  { "schema" => schema, "variant_sha" => variant_sha, "baseline_sha" => baseline_sha, "corpus" => corpus,
    "verdict" => verdict, "gate_ok" => verdict != "blocked", "gate_detail" => gate_detail,
    "unmeasured" => unmeasured,
    "deterministic" => %w[blocked unmeasured].include?(verdict) ? nil : { "regressed" => regressed, "fixed" => fixed, "new" => new_cases },
    "regressions" => regs, "improvements" => %w[keep inconclusive revert].include?(verdict) ? fixed : nil }
end

def decide(json: json(), sandbox_exit: 0, baseline_gate: nil, isolated: ISO_OK, targets: TARGETS)
  L.decide(json: json, cand_sha: CAND, base_sha: SHA, targets: targets, sandbox_exit: sandbox_exit,
           baseline_gate: baseline_gate, isolated: isolated)
end

def label?(r, prefix, exit)
  r[:label].start_with?(prefix) && r[:exit] == exit
end

check("D-L1 helps -> RECOMMENDED, exit 0") { label?(decide, L::RECOMMENDED, 0) && L::RECOMMENDED == "RECOMMENDED — MEASURED IMPROVEMENT; human adoption required" }
check("D-L2 no-op tool (only the clean case fixed) -> target not fixed (the fires case)") do
  r = decide(json: json(verdict: "keep", fixed: %w[he:21-foo-clean]))
  label?(r, "NOT RECOMMENDED: target not fixed", 1) && r[:label].include?("20-foo-fires") && !r[:label].include?("21-foo-clean")
end
check("D-L2 inconclusive, nothing fixed -> target not fixed") do
  label?(decide(json: json(verdict: "inconclusive", fixed: [])), "NOT RECOMMENDED: target not fixed", 1)
end
check("D-L3 always-deny tool -> target not fixed (the clean case)") do
  r = decide(json: json(fixed: %w[he:20-foo-fires]))
  label?(r, "NOT RECOMMENDED: target not fixed", 1) && r[:label].include?("21-foo-clean")
end
check("D-L4 helps but regresses -> regression (X)") do
  r = decide(json: json(verdict: "revert", regressed: %w[he:05-x]))
  label?(r, "NOT RECOMMENDED: regression", 1) && r[:label].include?("he:05-x")
end
check("D-L5 unmeasured") do
  label?(decide(json: json(verdict: "unmeasured", unmeasured: { "side" => "variant", "part" => "deterministic", "reason" => "x" }),
                sandbox_exit: 1), "NOT RECOMMENDED: UNMEASURED", 1)
end
check("D-L6 blocked, baseline green -> gate red (checks)") do
  r = decide(json: json(verdict: "blocked", gate_detail: ["check-bin-help FAILED"]), sandbox_exit: 1, baseline_gate: :green)
  label?(r, "NOT RECOMMENDED: gate red", 1) && r[:label].include?("check-bin-help")
end
check("D-L7 blocked, baseline red -> UNMEASURED (sandbox env)") do
  r = decide(json: json(verdict: "blocked", gate_detail: ["x FAILED"]), sandbox_exit: 1, baseline_gate: { red: ["x FAILED"] })
  label?(r, "NOT RECOMMENDED: UNMEASURED", 1) && r[:label].include?("sandbox env")
end
check("blocked with no baseline gate run is UNMEASURED, never gate red") do
  label?(decide(json: json(verdict: "blocked"), sandbox_exit: 1, baseline_gate: nil), "NOT RECOMMENDED: UNMEASURED", 1)
end
check("D-L8 JSON absent / malformed / wrong schema / not an object") do
  [nil, :unreadable, "{", json(schema: "x@1"), [1]].all? { |j| label?(decide(json: j), "NOT RECOMMENDED: UNMEASURED", 1) }
end
check("D-L9 JSON for another candidate or base") do
  label?(decide(json: json(variant_sha: "d" * 40)), "NOT RECOMMENDED: UNMEASURED", 1) &&
    label?(decide(json: json(baseline_sha: "d" * 40)), "NOT RECOMMENDED: UNMEASURED", 1)
end
check("D-L9 another corpus") { label?(decide(json: json(corpus: "full")), "NOT RECOMMENDED: UNMEASURED", 1) }
check("D-L10 sandbox timed out / failed setup / interrupted / a forged code") do
  r124 = decide(sandbox_exit: 124)
  r125 = decide(sandbox_exit: 125)
  label?(r124, "NOT RECOMMENDED: UNMEASURED", 1) && r124[:label].include?("timeout") &&
    label?(r125, "NOT RECOMMENDED: UNMEASURED", 1) && r125[:label].include?("sandbox") &&
    [130, 143, 2, 3, nil].all? { |c| label?(decide(sandbox_exit: c), "NOT RECOMMENDED: UNMEASURED", 1) }
end
check("D-L11 keep with regressions null -> UNMEASURED, never RECOMMENDED") do
  label?(decide(json: json(regressions: nil)), "NOT RECOMMENDED: UNMEASURED", 1)
end
check("keep with a malformed deterministic block -> UNMEASURED") do
  j = json
  j["deterministic"] = { "fixed" => "he:20" }
  label?(decide(json: j), "NOT RECOMMENDED: UNMEASURED", 1)
end
check("D-L12 RECOMMENDED text runs nothing: only the human instruction sentence") do
  r = decide
  text = ToolPropose::Proposal.render(label: r, targets: TARGETS, guard: "foo-check", run_id: "r", cand_sha: CAND,
                                      base_sha: SHA, scorecard: "card\n", isolated: ISO_OK)
  text.include?(L::ADOPTION) && !text.match?(/^\s*(\$ |git |ai\/bin\/|gh |glab )/) &&
    L::ADOPTION == "A human adopts: apply proposal.diff in your own worktree, reclassify the tool's risk.yml " \
                   "entry if it is not destructive, and open a PR (critic + harness-gate). Agents never apply a " \
                   "tool-propose proposal." && text.include?(L::MEASURED_NOTE)
end
check("a NOT RECOMMENDED proposal carries no adoption sentence") do
  r = decide(json: json(fixed: []))
  text = ToolPropose::Proposal.render(label: r, targets: TARGETS, guard: "foo-check", run_id: "r", cand_sha: CAND,
                                      base_sha: SHA, scorecard: nil, isolated: nil)
  !text.include?(L::RECOMMENDED) && !text.include?(L::ADOPTION)
end
check("D-L13 sandbox exit 0 with the JSON absent -> UNMEASURED") { label?(decide(json: nil, sandbox_exit: 0), "NOT RECOMMENDED: UNMEASURED", 1) }
check("D-L14 keep, all fixed, isolated mismatch -> target not fixed (isolated re-check)") do
  r = decide(isolated: { "20-foo-fires" => "clean", "21-foo-clean" => "clean" })
  label?(r, "NOT RECOMMENDED: target not fixed (isolated re-check", 1) && r[:label].include?("20-foo-fires")
end
check("D-L14 an isolated error never matches") do
  label?(decide(isolated: { "20-foo-fires" => "error", "21-foo-clean" => "clean" }), "NOT RECOMMENDED: target not fixed", 1)
end
check("D-L14 a missing isolated verdict never matches") do
  label?(decide(isolated: { "21-foo-clean" => "clean" }), "NOT RECOMMENDED: target not fixed", 1)
end
check("keep, all fixed, isolated not run -> recheck due, never RECOMMENDED") do
  r = decide(isolated: nil)
  r[:recheck] == true && label?(r, "NOT RECOMMENDED: UNMEASURED", 1)
end
check("recheck is due only on the KEEP-all-fixed path") do
  [decide(json: json(fixed: []), isolated: nil), decide(json: nil, isolated: nil), decide(sandbox_exit: 124, isolated: nil)]
    .none? { |r| r[:recheck] }
end
check("D-L15 a target under new, not fixed -> target not fixed (new, not fixed: <case>)") do
  r = decide(json: json(fixed: %w[he:21-foo-clean], new_cases: %w[he:20-foo-fires]))
  label?(r, "NOT RECOMMENDED: target not fixed (new, not fixed: ", 1) && r[:label].include?("20-foo-fires")
end
check("D-L15 new wins even when fixed also lists it") do
  r = decide(json: json(new_cases: %w[he:20-foo-fires]))
  label?(r, "NOT RECOMMENDED: target not fixed (new, not fixed", 1)
end
check("keep with a regression listed anyway -> regression, never RECOMMENDED") do
  label?(decide(json: json(regressed: %w[he:05-x])), "NOT RECOMMENDED: regression", 1)
end
check("an unknown verdict -> UNMEASURED") { label?(decide(json: json(verdict: "adopt")), "NOT RECOMMENDED: UNMEASURED", 1) }
check("no targets is never RECOMMENDED") { label?(decide(targets: [], isolated: {}), "NOT RECOMMENDED: UNMEASURED", 1) }

# isolated_verdict: harness-eval's bin-stdin rule, plus tool-sandbox's own codes.
check("isolated_verdict: 0 clean, 1+Fix: fires, everything else error") do
  v = ->(code, out = "") { L.isolated_verdict(exit_status: code, output: out) }
  v.(0) == "clean" && v.(1, "x\nFix: y") == "fires" && v.(1, "no fix") == "error" &&
    [2, 124, 125, 126, 137, 143, nil].all? { |c| v.(c, "Fix: forged") == "error" }
end

# ---------------------------------------------------------------------------
# OutDir.problem (PRD R7)
# ---------------------------------------------------------------------------
O = ToolPropose::OutDir
def odf(**over)
  { given: "/tmp/tp/out", realpath: "/tmp/tp/out", exists: false, directory: false, empty: false, symlink: false,
    git_ancestor: nil, roots: ["/tmp", "/home/u/.local/state/athena/tool-propose"],
    denied: ["/home/u/.claude", "/home/u/dev"] }.merge(over)
end
check("R7 a new dir beneath the temp root is usable") { O.problem(odf).nil? }
check("R7 an existing empty dir is usable") { O.problem(odf(exists: true, directory: true, empty: true)).nil? }
check("R7 the state dir is usable") do
  O.problem(odf(given: "/home/u/.local/state/athena/tool-propose/r1",
                realpath: "/home/u/.local/state/athena/tool-propose/r1")).nil?
end
{
  "relative" => [odf(given: "out"), /not absolute/],
  "non-empty" => [odf(exists: true, directory: true, empty: false), /not empty/],
  "a file" => [odf(exists: true, directory: false), /not a directory/],
  "a symlink" => [odf(symlink: true), /symlink/],
  "inside a git work tree" => [odf(git_ancestor: "/tmp/tp"), /git work tree/],
  "under ~/.claude" => [odf(given: "/home/u/.claude/x", realpath: "/home/u/.claude/x"), /\.claude/],
  "under ~/dev" => [odf(given: "/home/u/dev/custom/x", realpath: "/home/u/dev/custom/x"), %r{/home/u/dev}],
  "elsewhere in HOME" => [odf(given: "/home/u/x", realpath: "/home/u/x"), /not beneath/],
  "the temp root itself" => [odf(given: "/tmp", realpath: "/tmp", exists: true, directory: true, empty: true), /not beneath/],
  "an unresolvable parent" => [odf(realpath: nil), /parent/]
}.each do |what, (facts, pattern)|
  check("M-6 out-dir #{what} is refused") { O.problem(facts).to_s.match?(pattern) }
end

if $failures.empty?
  puts "tool_propose_test: OK (#{$checks} checks)"
  exit 0
end
$failures.each { |f| warn "tool_propose_test: FAIL — #{f}" }
warn "  Fix: the domain must match the DND-176 QA plan rows named above; see ai/docs/tool-propose.md."
exit 1
