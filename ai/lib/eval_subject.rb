# frozen_string_literal: true

# EvalSubject — the ONE copy of "which agents have a behavioral eval, and how a
# rendered agent is loaded and contained for one" (DND-529).
#
# Every behavioral eval runner (ai/bin/admiral-eval for the admiral, captain and
# architect; ai/bin/critic-eval for the diff-critic) evaluates a RENDERED agent
# definition under the same structural containment. Until DND-529 that code
# lived inside admiral-eval as AGENT / FIXTURES_DIR / SUBJECT_KEY constants, and
# critic-eval ran `claude -p --agent athena-diff-critic`, which resolves the
# name from ~/.claude/agents (the MAIN checkout) whatever the cwd -- the DND-503
# defect, still live in the second runner. Extracting it here, rather than
# forking a copy per agent, keeps one containment argv and one subject rule.
#
# Registry: AGENTS maps a short key (routing.yml's form: admiral, captain,
# architect) to the agent's full name, the runner that measures it, its fixtures
# dir and its baseline. Downstream tools derive "which agents have a measured
# corpus" from this table at runtime rather than from a hand-kept list.
#
# SUBJECT SELECTION (DND-503): the argv carries the NAMED render's prose inline,
#   --agents '{"<name>-eval-subject": {description, model, tools, prompt}}'
#   --agent <name>-eval-subject
# under a key no agents dir supplies, so if --agents were ever not honored
# `claude` fails "agent not found" instead of silently evaluating the main
# checkout's copy.
#
# CONTAINMENT (admiral-eval design §2.1, hardened): no MCP server loads
# (--strict-mcp-config with an empty set), and Bash + Task are disallowed. The
# native Write/Edit tools stay available; the runners' plan-only framing is the
# guard there. --disallowedTools is variadic, so it stays LAST.
#
# Pure: no process execution; reads only the render file it is handed.
# Deliberately gem-free (stdlib only).

require "digest"
require "json"

module EvalSubject
  class SubjectError < StandardError; end
  class UnknownAgent < StandardError; end

  Agent = Struct.new(:key, :name, :runner, :fixtures_rel, :baseline_rel, keyword_init: true) do
    def render_rel
      "ai/agents/#{name}.md"
    end

    def subject_key
      "#{name}-eval-subject"
    end
  end

  ADMIRAL_EVAL = "ai/bin/admiral-eval"
  CRITIC_EVAL = "ai/bin/critic-eval"

  AGENTS = {
    "admiral" => Agent.new(key: "admiral", name: "athena-admiral", runner: ADMIRAL_EVAL,
                           fixtures_rel: "ai/eval/admiral-fixtures", baseline_rel: "ai/eval/admiral-baseline.json"),
    "architect" => Agent.new(key: "architect", name: "athena-architect", runner: ADMIRAL_EVAL,
                             fixtures_rel: "ai/eval/architect-fixtures",
                             baseline_rel: "ai/eval/architect-baseline.json"),
    "captain" => Agent.new(key: "captain", name: "athena-captain", runner: ADMIRAL_EVAL,
                           fixtures_rel: "ai/eval/captain-fixtures", baseline_rel: "ai/eval/captain-baseline.json"),
    "diff-critic" => Agent.new(key: "diff-critic", name: "athena-diff-critic", runner: CRITIC_EVAL,
                               fixtures_rel: "ai/eval/critic-fixtures", baseline_rel: "ai/eval/critic-baseline.json")
  }.freeze

  EMPTY_MCP_CONFIG = '{"mcpServers":{}}'
  CONTAINMENT_ARGV = [
    "--strict-mcp-config", "--mcp-config", EMPTY_MCP_CONFIG,
    "--disallowedTools", "Bash", "Task"
  ].freeze

  # Linux caps ONE argv string at MAX_ARG_STRLEN (32 pages = 131072 bytes); past
  # it execve fails E2BIG. Refuse early with a Fix: rather than per-case errors.
  MAX_SUBJECT_ARG_BYTES = 131_072

  # Frontmatter keys a render may carry, and where each goes in the --agents
  # definition. `name` is checked, `color` is cosmetic. Any OTHER key is
  # refused: dropping one silently would evaluate a different agent than the
  # file describes.
  FRONTMATTER_MAP = { "description" => "description", "model" => "model", "tools" => "tools" }.freeze
  FRONTMATTER_IGNORED = %w[name color].freeze

  module_function

  # The registry entry for a short key or a full `athena-<key>` name. With
  # runner:, the agent must be one that runner measures. Raises UnknownAgent
  # (with a Fix:) otherwise: an unknown agent is never zero cases.
  def agent(key, runner: nil)
    entry = AGENTS[key.to_s] || AGENTS.values.find { |a| a.name == key.to_s }
    unless entry
      raise UnknownAgent, "unknown eval agent #{key.inspect}. Fix: pass one of #{AGENTS.keys.join(', ')} " \
                          "(or its full athena-<name>); an agent with no registered corpus has no behavioral " \
                          "eval, and that must be an error, not zero cases."
    end
    if runner && entry.runner != runner
      raise UnknownAgent, "#{runner} does not measure #{entry.key}. Fix: run `#{entry.runner}` for " \
                          "#{entry.name}; #{runner} measures #{keys_for_runner(runner).join(', ')}."
    end
    entry
  end

  def keys_for_runner(runner)
    AGENTS.values.select { |a| a.runner == runner }.map(&:key).sort
  end

  def subject_error(path, name, why)
    SubjectError.new(
      "cannot load the eval subject #{path}: #{why}. Fix: pass --agent-file a rendered #{name} definition " \
      "(e.g. <checkout>/ai/agents/#{name}.md, produced by ai/bin/build-agents) with `---` frontmatter naming " \
      "`name: #{name}` and a non-empty prompt body."
    )
  end

  # Parse a render into an --agents definition. Raises SubjectError.
  def definition(path, name)
    raise subject_error(path, name, "file not found or unreadable") unless File.file?(path) && File.readable?(path)

    m = File.read(path).match(/\A---\s*\n(.*?)\n---\s*\n(.*)\z/m)
    raise subject_error(path, name, "no `---` frontmatter block") unless m

    front = frontmatter(path, name, m[1])
    body = m[2].strip
    raise subject_error(path, name, "frontmatter name is #{front['name'].inspect}, not #{name}") unless front["name"] == name
    raise subject_error(path, name, "empty prompt body") if body.empty?

    unknown = front.keys - FRONTMATTER_MAP.keys - FRONTMATTER_IGNORED
    raise subject_error(path, name, "unsupported frontmatter key(s) #{unknown.join(', ')}") unless unknown.empty?

    defn = { "prompt" => body }
    FRONTMATTER_MAP.each do |key, field|
      next unless front.key?(key)

      defn[field] = key == "tools" ? front[key].split(",").map(&:strip).reject(&:empty?) : front[key]
    end
    defn
  end

  # Flat `key: value` frontmatter, the only shape ai/bin/build-agents renders.
  def frontmatter(path, name, block)
    block.lines.each_with_object({}) do |line, h|
      next if line.strip.empty?

      k, sep, v = line.partition(":")
      if sep.empty? || k.strip.empty?
        raise subject_error(path, name, "unparseable frontmatter line #{line.strip.inspect}")
      end

      h[k.strip] = v.strip
    end
  end

  # The contained `claude -p` argv evaluating the render at path as agent.
  def argv(path, agent)
    subject = JSON.generate(agent.subject_key => definition(path, agent.name))
    if subject.bytesize >= MAX_SUBJECT_ARG_BYTES
      raise subject_error(path, agent.name, "the inline --agents definition is #{subject.bytesize} bytes, over the " \
                                            "#{MAX_SUBJECT_ARG_BYTES}-byte single-argument limit; switch " \
                                            "EvalSubject.argv to `--agents <file>` (claude -p accepts a path)")
    end
    ["claude", "-p", "--agent", agent.subject_key, "--agents", subject, *CONTAINMENT_ARGV]
  end

  # Line count + sha256 of the render; status=missing when absent, never a
  # fingerprint that could match.
  def fingerprint(path, rel)
    return { "file" => rel, "status" => "missing" } unless File.file?(path)

    body = File.read(path)
    { "file" => rel, "lines" => body.lines.size, "sha256" => Digest::SHA256.hexdigest(body) }
  end
end
