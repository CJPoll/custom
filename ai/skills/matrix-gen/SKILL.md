---
name: matrix-gen
description: Generate a comprehensive test matrix for all public functions in a module, covering every code branch.
argument-hint: <file path>
---

THINK I have a file for which I want to generate tests: $ARGUMENTS

Do not generate any code. Do not generate any tests.

Generate for me a comprehensive test matrix for the module.
- Do not include performance tests.
- Do cover failure cases.
- Ensure every single code branch in the file is covered.

The output for the file under test MUST follow the format in
@~/.claude/skills/format:test-matrix/SKILL.md

The output for the file under test MUST be saved in the file/directory structure
described in @~/.claude/skills/format:test-matrix-directory/SKILL.md
