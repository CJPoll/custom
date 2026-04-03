---
name: verify-plan
description: Gap analysis between ticket requirements, context, and implementation plan.
argument-hint: <ticket identifier>
disable-model-invocation: true
---

THINK I have a ticket: $ARGUMENTS

DO NOT make any changes to tests or code.

You have generated context on that ticket and saved it in @ai-artifacts/context.md

You have generated an implementation plan based on that context and saved it in
@ai-artifacts/implementation-plan.md

You have generated test matrices based on that implementation plan and saved
them in the file structure under @ai-artifacts/test-matrices/ . Those matrices
should follow the structure of @~/.claude/skills/format:test-matrix/SKILL.md and
@~/.claude/skills/format:test-matrix-directory/SKILL.md.

Without making any changes, check whether there are any gaps between:
1. The ticket requirements and the context
2. The context and the implementation plan
3. The implementation plan and the test matrices
