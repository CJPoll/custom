# frozen_string_literal: true

# critic_prompt — the ONE copy of the prompt handed to athena-diff-critic.
#
# WHY THIS FILE EXISTS
#
# Two callers build this prompt: `ai/bin/critic-review` (the SHIPPING path — the
# blocking review step that decides pass/block on a real change) and
# `ai/bin/critic-eval` (the MEASURING path — the labeled-fixture scorer whose
# recall/precision numbers are the stated reason the critic is trusted as a
# blocking step at all).
#
# critic-eval's entire claim is "the judge that ships scores recall >= 0.8 and
# precision >= 0.8". That claim holds only while the two callers send the judge
# the SAME prompt. Built independently they were byte-identical and silently
# free to drift: the first edit to the shipping prompt that did not land in the
# eval would leave the eval scoring a prompt nobody runs, still printing a
# number, still reading as PASS. The measurement would go on looking healthy
# while measuring the wrong thing -- `A claimed mechanism must be able to fire`,
# pointed at the instrument the harness uses to trust its own judge.
#
# So the builder is extracted here BEFORE the two diverge rather than after.
# `ai/bin/critic-review --self-test` asserts the single-copy property directly
# (neither bin may re-inline a prompt of its own), because a convention that
# only lives in this comment is one edit away from being untrue.
#
# Deliberately gem-free (stdlib only), no I/O, no model call: it is a pure
# string builder, so both callers' deterministic self-tests can exercise it.
module CriticPrompt
  INSTRUCTION = "Review this change against your rubric and end with the FINDINGS trailer."

  # The prompt inputs this builder actually accepts -- the SINGLE source of
  # truth for "which inputs exist", read by the shipping caller's self-test and
  # by critic-eval's fixture validator.
  #
  # WHY WHICH-INPUTS-EXIST IS DATA AND NOT A COMMENT
  #
  # A fixture is only as meaningful as the input that distinguishes it. A
  # fixture authored for an input the builder cannot yet carry is not a neutral
  # placeholder -- it is MISLABELED. The judge is shown a diff with the
  # discriminating context absent, answers correctly for what it was actually
  # shown, and the fixture records a MISS (or a false positive). The later step
  # that finally supplies the input is then credited with a gain that was only
  # the label becoming true. That is the flattering direction, which is the
  # dangerous one: it makes a change look like it worked.
  #
  # So `critic-eval` REFUSES TO SCORE a fixture naming a token absent here,
  # rather than scoring it as a zero. A zero is a measurement; an absent input
  # is the lack of one, and the two must not print the same.
  #
  # token: what a fixture's `requires=` names (the corpus-facing name)
  # key:   the keyword `build` takes (what the shipping caller must pass)
  # file:  the file inside a fixture directory that carries it
  INPUTS = {
    "diff" => { key: :diff, file: "input.diff" },
    # The change's commit messages (subjects AND bodies). Step 2 of
    # ai/docs/critic-loop-cost-design.md named this input; DND-400 lands it,
    # because the bug-fix rule below can only fire on a fix claim the judge can
    # see, and that claim lives in the commit messages, not the diff.
    "commit-msg" => { key: :commit_messages, file: "commit-msg" },
  }.freeze

  # The keyword arguments `build` accepts.
  #
  # `critic-review --self-test` asserts the SHIPPING caller passes every one of
  # these. That is the standing guard against a builder parameter only
  # `critic-eval` ever passes: an eval feeding the judge a prompt shape no
  # shipping caller produces still prints a number and still reads as PASS,
  # while measuring something nobody runs -- the divergence this whole file
  # exists to prevent.
  SUPPORTED_INPUTS = INPUTS.values.map { |spec| spec[:key] }.freeze

  # The corpus-facing tokens a fixture may declare in `requires=`.
  SUPPORTED_TOKENS = INPUTS.keys.freeze

  # The enforceable half of the bug-fix regression-test rule (DND-400).
  #
  # The RULE lives once, in ~/dev/custom/ai/CLAUDE.md -> "TDD Workflow". The
  # judge's rubric proper lives in ai/agents/athena-diff-critic.md(.in); this
  # addendum rides in the prompt so the check fires from the shipping path
  # (critic-review) and the measuring path (critic-eval) alike. It is part of
  # the STABLE prefix, so it costs nothing against the prompt cache.
  BUG_FIX_RULE = <<~TXT.freeze
    Rubric addendum: bug-fix regression evidence (the rule is ~/dev/custom/ai/CLAUDE.md -> "TDD Workflow").

    A change is a BUG FIX when a commit message below claims to fix a defect: its subject or body says it fixes a bug, defect, regression, crash, or flaky test, or it names a bug/defect/Flaky ticket or a bug ticket type or label.
    Exempt, so this addendum does not apply: features, refactors, and changes whose diff touches no executable code or test (docs, prose, comments), even when the message says "fix".

    A bug fix needs BOTH:
    1. A test in the diff that exercises the defect (added or changed).
    2. Fail-before evidence: the RECORDED failing output of that test run against the UNFIXED code (the failure line, assertion message, or failing case name with its non-zero result), plus the passing re-run after the fix. It counts when it appears in a commit message below, or in a report or sabotage-record file inside the diff. A bare claim ("verified red/green", "test failed before") with no recorded output is not evidence. For a flaky-test fix, the evidence is the recorded failing run(s) on the unfixed code with the seed or repeat count that reproduced it.

    A bug fix missing either is a `tests` finding. Every finding blocks, so it is must-fix. Name which part is missing.
    If the commit messages are NOT SUPPLIED below, you cannot see a fix claim: note this addendum as "unable to assess", never as a finding.
  TXT

  # The three states of the commit-messages input, kept textually distinct:
  # "nobody passed them" must never read the same as "there were none".
  COMMITS_NOT_SUPPLIED = "Commit messages: NOT SUPPLIED to this prompt."
  COMMITS_NONE         = "Commit messages: none (no commits between the base and HEAD)."

  # Build the critic prompt for a diff.
  #
  # diff:            the change under review, as unified-diff text.
  # commit_messages: the change's commit messages, oldest first. nil means the
  #                  caller did not supply them (a fixture that does not declare
  #                  requires=commit-msg, or critic-review failing to read the
  #                  log, which it says on stderr); "" means there were none.
  #
  # The diff goes LAST, inside a fenced block. Order is load-bearing, not
  # cosmetic: the instruction (and anything else stable across rounds) forms a
  # byte-identical prefix that stays prompt-cache-hittable across a loop's many
  # rounds, while the parts that vary per round sit at the end.
  def self.build(diff:, commit_messages: nil)
    "#{INSTRUCTION}\n\n#{BUG_FIX_RULE}\n#{commits_section(commit_messages)}\n\n```diff\n#{diff}\n```"
  end

  def self.commits_section(commit_messages)
    return COMMITS_NOT_SUPPLIED if commit_messages.nil?
    return COMMITS_NONE if commit_messages.strip.empty?

    # One backtick longer than the longest run inside, so a pasted ``` fence
    # (the natural way to quote failing test output) cannot close the block.
    fence = "`" * [3, (commit_messages.scan(/`+/).map(&:length).max || 0) + 1].max
    "Commit messages on this change (oldest first):\n\n#{fence}text\n#{commit_messages}\n#{fence}"
  end
  private_class_method :commits_section
end
