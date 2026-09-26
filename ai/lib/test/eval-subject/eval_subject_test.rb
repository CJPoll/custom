# frozen_string_literal: true

# Deterministic suite for ai/lib/eval_subject.rb (DND-529): the per-agent eval
# registry, subject loading, and the containment argv every behavioral eval
# runner shares. No model, no git, no network. Run by
# ai/lib/test/eval-subject/self-test.sh, which harness-gate discovers.

require "json"
require "tmpdir"
require_relative "../../eval_subject"

$failures = []
$checks = 0

def check(desc)
  $checks += 1
  $failures << desc unless yield
rescue StandardError => e
  $failures << "#{desc} (raised #{e.class}: #{e.message})"
end

# -> the raised error, or nil when nothing (or something else) was raised.
def raised(klass)
  yield
  nil
rescue klass => e
  e
end

ES = EvalSubject
REPO = File.expand_path("../../../..", __dir__)
AI_DIR = File.join(REPO, "ai")

# --- registry ---------------------------------------------------------------
check("the registry covers admiral, architect, captain and diff-critic") do
  ES::AGENTS.keys.sort == %w[admiral architect captain diff-critic]
end
check("a short key resolves to its full agent name") { ES.agent("captain").name == "athena-captain" }
check("a full agent name resolves to the same entry") { ES.agent("athena-architect") == ES.agent("architect") }
check("the render path is ai/agents/<name>.md") { ES.agent("captain").render_rel == "ai/agents/athena-captain.md" }
check("the subject key is <name>-eval-subject") { ES.agent("admiral").subject_key == "athena-admiral-eval-subject" }
check("the admiral keeps its historical fixtures dir and baseline") do
  a = ES.agent("admiral")
  a.fixtures_rel == "ai/eval/admiral-fixtures" && a.baseline_rel == "ai/eval/admiral-baseline.json"
end
check("the critic is measured by critic-eval, over the critic corpus") do
  c = ES.agent("diff-critic")
  c.runner == "ai/bin/critic-eval" && c.fixtures_rel == "ai/eval/critic-fixtures"
end
check("admiral-eval runs admiral, architect and captain") do
  ES.keys_for_runner("ai/bin/admiral-eval") == %w[admiral architect captain]
end

# An unknown agent is an ERROR naming what is known, never zero cases.
%w[shipwright nope athena- ADMIRAL].each do |bad|
  check("an unknown agent #{bad.inspect} raises UnknownAgent with a Fix: naming the known keys") do
    e = raised(ES::UnknownAgent) { ES.agent(bad) }
    e && e.message.include?("Fix:") && e.message.include?("captain") && e.message.include?(bad)
  end
end
check("a nil agent raises UnknownAgent") { raised(ES::UnknownAgent) { ES.agent(nil) } }
check("an agent another runner measures is an error naming that runner") do
  e = raised(ES::UnknownAgent) { ES.agent("diff-critic", runner: "ai/bin/admiral-eval") }
  e && e.message.include?("ai/bin/critic-eval") && e.message.include?("Fix:")
end
check("an agent the named runner measures resolves") do
  ES.agent("captain", runner: "ai/bin/admiral-eval").name == "athena-captain"
end

# Every registered agent's corpus and render exist in THIS checkout. A missing
# fixtures dir must be a red suite here, not zero cases at run time.
ES::AGENTS.each_value do |a|
  check("#{a.key}: fixtures dir #{a.fixtures_rel} exists") { File.directory?(File.join(REPO, a.fixtures_rel)) }
  check("#{a.key}: render #{a.render_rel} loads as #{a.name}") do
    ES.argv(File.join(REPO, a.render_rel), a).include?(a.subject_key)
  end
  check("#{a.key}: the subject key is a name no agents dir supplies") do
    !File.exist?(File.join(AI_DIR, "agents", "#{a.subject_key}.md"))
  end
end

# --- subject loading ----------------------------------------------------------
Dir.mktmpdir("eval-subject-test-") do |d|
  cap = ES.agent("captain")
  front = "---\nname: athena-captain\ndescription: eval subject\nmodel: opus\ncolor: red\ntools: Read, Grep\n---\n\n"
  a = File.join(d, "a.md")
  b = File.join(d, "b.md")
  File.write(a, front + "You are variant A.\n")
  File.write(b, front + "You are variant B.\n")

  defn = ES.definition(a, cap.name)
  check("the prompt is the file's body, without frontmatter") do
    defn["prompt"] == "You are variant A." && !defn["prompt"].include?("name:")
  end
  check("model and description are kept") { defn["model"] == "opus" && defn["description"] == "eval subject" }
  check("tools become a list") { defn["tools"] == %w[Read Grep] }

  argv = ES.argv(a, cap)
  check("argv starts claude -p --agent <subject key>") { argv[0, 4] == ["claude", "-p", "--agent", cap.subject_key] }
  check("argv defines exactly the subject key inline via --agents") do
    JSON.parse(argv[argv.index("--agents") + 1]).keys == [cap.subject_key]
  end
  check("argv never passes the bare --agent <name> (it resolves from ~/.claude/agents)") do
    !argv.each_cons(2).include?(["--agent", cap.name])
  end
  check("two files whose prose differs yield different argv") { argv != ES.argv(b, cap) }
  check("argv loads NO MCP server") do
    i = argv.index("--mcp-config")
    argv.include?("--strict-mcp-config") && i && JSON.parse(argv[i + 1])["mcpServers"] == {}
  end
  check("--disallowedTools is last, carrying exactly Bash Task") do
    i = argv.index("--disallowedTools")
    i && argv[(i + 1)..] == %w[Bash Task]
  end

  bad = {
    "missing file" => [File.join(d, "nope.md"), nil],
    "no frontmatter" => [File.join(d, "plain.md"), "You are a captain.\n"],
    "wrong agent name" => [File.join(d, "admiral.md"), front.sub("athena-captain", "athena-admiral") + "x\n"],
    "unknown frontmatter key" => [File.join(d, "unknown.md"), front.sub("color: red", "permissionMode: bypass") + "x\n"],
    "unparseable frontmatter line" => [File.join(d, "garbled.md"), front.sub("color: red", "garbled") + "x\n"],
    "empty body" => [File.join(d, "empty.md"), front]
  }
  bad.each do |label, (path, body)|
    File.write(path, body) if body
    check("#{label}: raises SubjectError with a Fix: naming #{cap.name}") do
      e = raised(ES::SubjectError) { ES.argv(path, cap) }
      e && e.message.include?("Fix:") && e.message.include?(cap.name)
    end
  end

  big = File.join(d, "big.md")
  File.write(big, front + ("x" * (ES::MAX_SUBJECT_ARG_BYTES + 1)) + "\n")
  check("an over-size render raises SubjectError naming the single-argument limit") do
    e = raised(ES::SubjectError) { ES.argv(big, cap) }
    e && e.message.include?("single-argument limit") && e.message.include?("Fix:")
  end

  fa = ES.fingerprint(a, "a.md")
  check("the fingerprint records lines and a sha256") { fa["lines"] == 9 && fa["sha256"].match?(/\A\h{64}\z/) }
  check("different files fingerprint differently") { fa["sha256"] != ES.fingerprint(b, "b.md")["sha256"] }
  check("an absent subject fingerprints as status=missing, never a silent match") do
    ES.fingerprint(File.join(d, "gone.md"), "gone.md")["status"] == "missing"
  end
end

if $failures.empty?
  puts "eval-subject: #{$checks} checks OK"
  exit 0
end

warn "eval-subject: #{$failures.size}/#{$checks} checks FAILED"
$failures.each { |f| warn "  - #{f}" }
warn "  Fix: ai/lib/eval_subject.rb must resolve every registered agent (an unknown one raises " \
     "UnknownAgent with a Fix:), load a subject only from the named render (inline --agents under " \
     "<name>-eval-subject, never a bare --agent <name>), and keep --disallowedTools Bash Task last."
exit 1
