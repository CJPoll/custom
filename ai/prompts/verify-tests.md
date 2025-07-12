THINK I have a ticket: $ARGUMENTS

DO NOT make any changes to tests or code.

You have generated context on that ticket and saved it in @ai-artifacts/context.md

You have generated an implementation plan based on that context and saved it in
@ai-artifacts/implementation-plan.md

You have generated test matrices based on that implementation plan and saved
them in the file structure under @ai-artifacts/test-matrices/ . Those matrices
should follow the structure of @~/dev/custom/ai/prompts/format/test-matrix and
@~/dev/custom/ai/prompts/format/test-matrix-directory.

You have generated tests based off those test matrices. These are TDD tests - no
implementation has been generated yet.

Without making any changes, have subagents working in parallel evaluate whether there are any gaps between:
- The ticket requirements and the context
- The context and the implementation plan
- The implementation plan and the test matrices
- The test matrices and the current test coverage
- The implementation plan and the current test coverage

For every gap, address the gap and rerun the evaluations. Do not stop until all
the parallel subagents approve and say there are no gaps.
