#!/usr/bin/env bash
# session.sh -- SIDE EFFECT: it reads ambient process state (the environment,
# and the hook's stdin JSON when there is one). That is a small effect but it
# is still one, which is why this is not in the domain pile: the same inputs on
# two machines give two answers.
#
# TWO QUESTIONS: is this session a SUBAGENT (below), and which project does it
# belong to (session_project_dir, DND-1163, at the end of this file)?
#
# A subagent never advances a channel's consumption state. It would steal the
# offset from the session that is actually going to report to the owner: the
# subagent reads the mail, marks it consumed, finishes, and the main session
# then sees a clean inbox and reports nothing. Nobody is told, nothing is
# logged, and the message is simply gone -- the exact silent-loss shape the
# whole facility exists to eliminate.
#
# THE PREDICATE IS THE ONE IN ai/hooks/main-session-policy.sh, not a second
# mechanism. Same signals, same precedence, same fail-open direction:
#
#   * env CLAUDE_AGENT_ID / CLAUDE_AGENT_TYPE set non-empty, OR
#   * agent_id / agent_type / agentId / agentType present and non-empty/false
#     on the hook's stdin JSON;
#   * ANY positive signal -> subagent;
#   * no signal at all, or unparseable JSON -> MAIN (fail open).
#
# FAIL OPEN IS DELIBERATE and the contract says so explicitly: "the cost of a
# missed subagent is a rare contended ack; the cost of failing closed is a main
# session that can never consume anything." A reader that failed closed would
# be an inbox that silently never drains -- and that failure reads exactly like
# a quiet week.
#
# ONE DEVIATION FROM "VERBATIM", NAMED: the hook parses its stdin JSON with
# python3; this parses it with jq. The skill's existing dependency is jq
# (`bin/inbox-status` refuses without it) and adding a second interpreter to
# this dependency chain for one object lookup is not worth it. The SIGNALS and
# the FAIL-OPEN DIRECTION -- the two things that decide the answer -- are
# identical, and the suite asserts each of them independently rather than
# trusting the resemblance.
#
# Source order: err.sh, then this file. Requires jq only when given JSON.

# inbox_is_subagent [hook-stdin-json]
# Status 0 = subagent. Status 1 = main session (including "no signal at all").
inbox_is_subagent() {
  local input="${1:-}"

  if [ -n "${CLAUDE_AGENT_ID:-}" ] || [ -n "${CLAUDE_AGENT_TYPE:-}" ]; then
    return 0
  fi
  [ -n "${input}" ] || return 1

  # `jq -e` exits non-zero on false/null AND on a parse error, so an
  # unparseable document lands on "main" -- the fail-open direction -- without
  # a separate branch. The `false` guard mirrors the hook's `v not in (None,
  # "", False)`: a literal `false` is a signal that is not a signal.
  printf '%s' "${input}" | jq -e '
    if type != "object" then false
    else [ .agent_id, .agent_type, .agentId, .agentType ]
         | map(select(. != null and . != "" and . != false))
         | length > 0
    end' >/dev/null 2>&1
}

# ---------------------------------------------------------------------------
# SECOND QUESTION (DND-1163): which project does this session belong to?
#
# Every bin used to answer "the shell's cwd". The Claude Code Bash tool keeps a
# `cd` across calls, so a walt_ui session whose shell had wandered into
# ~/dev/custom (or through ~/.claude/skills, which realpaths into custom)
# claimed a Slack thread for custom's inbox: exit 0, claim=claimed, the wrong
# inbox, and nothing said the key came from the wrong project.
#
# session_project_dir
#
# The session's own project directory and the source it came from, as one
# "<source>\t<dir>" line, status 0. <dir> is absolute and physical (pwd -P),
# captured HERE, so a relative git common dir is never resolved later from
# somewhere else (athena-inbox.md -> *Repo identity: the git common dir*).
# Sources, in precedence order:
#
#   project-dir      $CLAUDE_PROJECT_DIR. Claude Code sets it for HOOKS; the
#                    Bash tool does NOT export it (measured 2026-09-28, Claude
#                    Code 2.1.283), so for a bin run by the agent it is usually
#                    the next source that fires.
#   session-process  /proc/$CLAUDE_PID/cwd. The Bash tool exports CLAUDE_PID,
#                    the Claude Code process; that process's own cwd is the
#                    directory the session started in, and the tool shell's
#                    `cd` never moves it. A subagent inherits its parent's, so
#                    a captain in a worktree resolves its repo's main checkout:
#                    the same git common dir, the same registry entry.
#                    Residuals, named: a CLAUDE_PID that outlived its session
#                    and was recycled to another of this user's processes
#                    resolves that process's cwd (the pid is not checked to be
#                    Claude Code: its comm varies by install); and a Claude Code
#                    action that chdirs the process itself (EnterWorktree,
#                    /add-dir) was not measured.
#   cwd              neither signal is set (a plain terminal, cron, a test):
#                    the shell's cwd, as before. Also the answer on a platform
#                    with no /proc, where CLAUDE_PID cannot be read. The label
#                    says so; it is never silent.
#
# A signal that is SET but unusable -- a relative or vanished
# CLAUDE_PROJECT_DIR, a CLAUDE_PID that is not a pid or whose cwd cannot be
# read -- is a refusal (status 1, Fix: naming the value), never a quiet fall
# through to the next source. Falling through would hand back exactly the
# drifted cwd this exists to distrust.
session_project_dir() {
  local d raw
  if [ -n "${CLAUDE_PROJECT_DIR:-}" ]; then
    case "${CLAUDE_PROJECT_DIR}" in
      /*) ;;
      *) inbox_fail "CLAUDE_PROJECT_DIR is not an absolute path (\"${CLAUDE_PROJECT_DIR}\"), so this session's project cannot be named" \
           "Claude Code sets CLAUDE_PROJECT_DIR to the session's absolute project dir; unset it, or set it to that directory, and re-run."
         return 1 ;;
    esac
    d="$(cd "${CLAUDE_PROJECT_DIR}" 2>/dev/null && pwd -P)" || {
      inbox_fail "CLAUDE_PROJECT_DIR names a directory that cannot be entered (\"${CLAUDE_PROJECT_DIR}\"), so this session's project cannot be named" \
        "check the directory still exists; unset CLAUDE_PROJECT_DIR (or set it to the session's project dir) and re-run."
      return 1
    }
    printf 'project-dir\t%s\n' "${d}"; return 0
  fi
  if [ -n "${CLAUDE_PID:-}" ] && [ -d /proc/self ]; then
    case "${CLAUDE_PID}" in
      *[!0-9]*|0*) inbox_fail "CLAUDE_PID is not a process id (\"${CLAUDE_PID}\"), so this session's project cannot be named" \
          "Claude Code exports CLAUDE_PID as its own pid; unset it (the cwd is then used, and labelled so) or fix it, and re-run."
        return 1 ;;
    esac
    raw="$(readlink "/proc/${CLAUDE_PID}/cwd" 2>/dev/null)"
    d=""
    case "${raw}" in /*) d="$(cd "${raw}" 2>/dev/null && pwd -P)" ;; esac
    [ -n "${d}" ] || {
      inbox_fail "the Claude Code process CLAUDE_PID=${CLAUDE_PID} has no readable cwd (gone, not yours, or its directory was deleted), so this session's project cannot be named" \
        "run this from the Claude Code session that owns the project, or unset CLAUDE_PID to use the shell cwd deliberately; the output then says source cwd."
      return 1
    }
    printf 'session-process\t%s\n' "${d}"; return 0
  fi
  d="$(pwd -P 2>/dev/null)" || {
    inbox_fail "the current directory cannot be resolved (was it deleted?)" \
      "cd into the project whose inbox you want and re-run."
    return 1
  }
  printf 'cwd\t%s\n' "${d}"
}
