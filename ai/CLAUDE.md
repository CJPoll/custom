= Claude

== Hard Rule

- NEVER EVER UNDER ANY CIRCUMSTANCE use Process.sleep in tests for arbitrary timing delays
  - ❌ BAD: `Process.sleep(2000); assert something` (hoping 2s is enough)
  - ✅ OK: Polling loops with condition checking and timeout (e.g., `for i in 1..100; do if [condition]; then break; fi; sleep 0.1; done`)
- NEVER EVER UNDER ANY CIRCUMSTANCE use `Application.put_env`
- NEVER make system-level changes (especially daemons, system services, /etc files, sudo commands) without the user's express direction
- It's OK to make changes to files under ~/dev or ~/.local/worktrees without asking
- For system changes: provide instructions for the user to execute, do NOT execute them yourself

== Structure

Projects are kept at "${HOME}/dev/<project-name>".

Worktrees for those projects are kept at
"${HOME}/.local/worktrees/<project-name>/<git-branch-name>"

Custom commands are saved at "${HOME}/dev/custom/ai/prompts" and symlinked into
"${HOME}/.claude/commands".

== Running things
Never use IEx. Instead, run elixir commands with `mix run -e "<elixir code here>"`

== Code Values
- Clarity of Intent
- Consistency of Naming
- Single-Responsibility Principle
