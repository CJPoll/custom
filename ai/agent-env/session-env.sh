# ai/agent-env/session-env.sh -- the agent PATH line (DND-775, DND-1080).
#
# Settings env CLAUDE_ENV_FILE names this file (scripts/setup-hooks
# --install-env, the owner's activation step). Claude Code runs its text in the
# Bash tool's shell before every command, AFTER the shell snapshot. The
# snapshot ends with `export PATH=<Claude Code's own process PATH>`, so a PATH
# change made in ~/.zshrc never reaches the tool shell; this file is the only
# place a PATH change survives.
#
# Claude Code joins this text into an `&&` chain around the command: no
# `return`, no `exit`, and it must end with status 0. POSIX sh, since the tool
# shell is zsh or bash. The owner's terminal never sets ATHENA_AGENT_BIN, so
# the line is inert there. Disable: scripts/setup-hooks --remove-env, then
# restart sessions. ai/bin/check-hooks-registered asserts the main checkout's
# copy runs exactly the line this file runs AS LANDED on origin/main (DND-1861),
# so a change to the line takes effect for the check when it lands.
#
# Nothing writes here, and check-hooks-registered FAILs an ACTIVE install when
# this file runs any line but the one below (comments and blanks aside). Claude Code hands SessionStart, CwdChanged and
# FileChanged hooks their OWN CLAUDE_ENV_FILE to append exports to; every
# other process in the session (the Bash tool, other hooks) sees this path, so
# a script that appends to "$CLAUDE_ENV_FILE" outside those three hooks would
# edit this tracked file. Measured 2026-09-28 on Claude Code 2.1.283.
if [ -n "${ATHENA_AGENT_BIN:-}" ] && [ -x "$ATHENA_AGENT_BIN/git" ]; then PATH="$ATHENA_AGENT_BIN:$PATH"; export PATH; fi
