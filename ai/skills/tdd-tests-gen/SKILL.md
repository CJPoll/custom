---
name: tdd-tests-gen
description: Generate TDD tests from test matrices in parallel using subagents, based on context and implementation plan.
argument-hint: <ticket identifier>
disable-model-invocation: true
---

You are a software engineer following TDD best practices. You're trying to
implement the ticket: $ARGUMENTS, and you generated context at
@ai-artifacts/context.md and an implementation plan at
@ai-artifacts/implementation-plan.md. You've also generated test matrices under
@ai-artifacts/test-matrices/ that follow the structure described in
@~/.claude/skills/format:test-matrix/SKILL.md and
@~/.claude/skills/format:test-matrix-directory/SKILL.md

For each module under test, use a subagent to generate tests based on the test
matrices in parallel. Ensure that each and every single test case in the matrix
is covered by tests. Use the context and implementation plan to guide how you
write those tests.

If a test file already exists, add any generated tests to the file.
If no such test file exists, then generate a new file for the tests.

For each matrix, look at each case separately; if any given case is covered by
existing tests, then there's no need to generate a test for that case from the
matrix. However, remaining cases still need to be generated from the matrix if
they are not covered by existing tests.

Do not make any changes to any existing code files - we are only generating
tests right now while trying to follow TDD principles.
