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

  # Build the critic prompt for a diff.
  #
  # diff: the change under review, as unified-diff text.
  #
  # The diff goes LAST, inside a fenced block. Order is load-bearing, not
  # cosmetic: the instruction (and anything else stable across rounds) forms a
  # byte-identical prefix that stays prompt-cache-hittable across a loop's many
  # rounds, while the part that varies per round sits at the end.
  def self.build(diff:)
    "#{INSTRUCTION}\n\n```diff\n#{diff}\n```"
  end
end
