# frozen_string_literal: true

# ai/lib/harness_tools.rb — WHICH FIRST-PARTY EXECUTABLES ARE HARNESS TOOLS.
#
# ai/bin/check-bin-help (every tool answers --help cheaply) and
# ai/bin/check-tool-risk (every tool carries a risk class) judge the same set.
# Until DND-508 each globbed ai/bin/ on its own, so the harness's other
# agent-callable executables -- ai/skills/*/bin/*, and the merge-boarding
# integration-gate -- were never checked, and the gate said OK anyway. Both now
# read this one scope over ai/lib/first_party.rb's discovery.
#
# THE SCOPE RULE. Every first-party executable (FirstParty.executables: tracked,
# plus untracked first-party, minus untracked node_modules/.venv/vendor/bundle,
# minus test suites) falls under exactly one SCOPE entry, first match wins:
#
#   ai/hooks/           OUT  hook event handlers
#   ai/                 IN   the harness's agent-callable tools
#   scripts/            OUT  the owner's personal PATH utilities
#   git-custom/, hypr/, system-files/, .auto-completions/   OUT  personal config
#
# An executable no entry covers is UNSCOPED, and both checks FAIL on it. A new
# top-level directory of executables is a scope decision someone has to make,
# not a silent pass. Each OUT entry carries its reason, which the checks print.
#
# Deliberately gem-free (stdlib only).

require_relative "first_party"

module HarnessTools
  SCOPE = [
    ["ai/hooks/", :out,
     "hook event handlers: Claude Code runs them with a JSON event on stdin, " \
     "never with argv flags or from an agent's Bash call; check-hooks-registered " \
     "and check-guard-messages cover them"],
    ["ai/", :in,
     "the harness's agent-callable tools: ai/bin/*, ai/skills/*/bin/*, " \
     "ai/skills/*/scripts/*, and any future executable under ai/"],
    ["scripts/", :out,
     "the owner's personal PATH utilities, predating the harness. " \
     "Their CLI contract is the owner's, the harness-run ones are cron or " \
     "owner-run installers rather than agent tools, and their generic names " \
     "(cap, sr, dr, check, upload) would word-match unrelated Bash commands in " \
     "ai/hooks/workflow-phase-guard.sh"],
    ["git-custom/", :out, "personal git aliases, run by the owner as `git <name>`"],
    ["hypr/", :out, "desktop theme scripts"],
    ["system-files/", :out, "root-installed system files, run by OpenRC"],
    [".auto-completions/", :out, "zsh completion definitions, sourced by compinit"],
  ].freeze

  # tools: in-scope repo-relative paths. out_of_scope: {path => reason}.
  # unscoped: paths no SCOPE entry covers. skipped: untracked third-party.
  Result = Struct.new(:tools, :out_of_scope, :unscoped, :skipped, keyword_init: true)

  module_function

  # [:in | :out, reason] for a repo-relative path, or nil when unscoped.
  def scope_of(rel, scope = SCOPE)
    entry = scope.find { |prefix, _, _| rel.start_with?(prefix) }
    entry && entry[1..2]
  end

  # Discovers and scopes. Raises FirstParty::MeasureError when git cannot be
  # asked, or when discovery or the in-scope set comes back EMPTY: this repo
  # always has harness tools, so zero means the lookup broke, and an empty set
  # would pass every check that iterates it.
  def discover(root, scope = SCOPE)
    executables, _found, skipped = FirstParty.executables(root)
    raise FirstParty::MeasureError, "discovered 0 first-party executables under #{root}" if executables.empty?

    result = Result.new(tools: [], out_of_scope: {}, unscoped: [], skipped: skipped)
    executables.each do |rel|
      verdict, reason = scope_of(rel, scope)
      case verdict
      when :in  then result.tools << rel
      when :out then result.out_of_scope[rel] = reason
      else result.unscoped << rel
      end
    end
    raise FirstParty::MeasureError, "0 of #{executables.size} first-party executables under #{root} are in scope" if result.tools.empty?

    result
  end

  # The name a tool is classified under in ai/tools/risk.yml, and the word
  # ai/hooks/workflow-phase-guard.sh matches in a Bash command. An ai/bin tool
  # keeps its bare name (ai/bin is on the agents' PATH convention and the
  # registry has always used it). Any other tool is its path under ai/, e.g.
  # `skills/athena:slack/bin/post`: unique where basenames collide (two skills
  # ship a read-inbox), and a substring of both `ai/skills/...` and
  # `~/.claude/skills/...`, the two ways an agent invokes it.
  def risk_key(rel)
    return File.basename(rel) if File.dirname(rel) == "ai/bin"

    rel.delete_prefix("ai/")
  end
end
