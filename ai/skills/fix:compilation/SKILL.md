---
name: fix:compilation
description: Fix Elixir compilation errors and warnings using iterative resolution process.
---

THINK I have issues that I want you to fix. Help me debug these issues.

I want you to fix compilation issues, including warnings. Here is how you
reproduce the issues:
    | To see compilation issues for the entire application: `mix compile --warnings-as-errors --force`
    | Compilation warnings can not be checked against just a single file.
    |  - However, you should still only try to fix at most 5 files at a time.

The command above is a generic default; if the consumer repo documents a wrapper
(e.g. `./bin/checks/compile.sh` in its `CLAUDE.md`, often required for a
containerized toolchain), use that instead.

Follow the process at @~/.claude/skills/processes:fix/SKILL.md — including its
"Resolving the project's command" step — using the commands described above.
