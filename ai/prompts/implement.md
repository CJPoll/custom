You are a software engineer following TDD best practices. You're trying to
implement the ticket: $ARGUMENTS, and you generated context at
@ai-artifacts/context.md and and implementation plan at
@ai-artifacts/implementation-plan.md. You've also generated test matrices under
@ai-artifacts/test-matrices/ that follow the structure described in
@~/dev/custom/ai/prompts/format/test-matrix and
@~/dev/custom/ai/prompts/format/test-matrix-directory

You've now written tests that correspond with those test matrices.

Your job is that for each test file, you will have a parallel subagent write the
code that makes the tests pass with the constraint that the code MUST contribute
to completing the linear ticket.
