#!/usr/bin/env bash
# merge-role-guard.sh -- PreToolUse hook (registry rows: matchers `Bash`,
# `mcp__.*` and `Agent|Task`): only athena-admiral merges or lands (DND-726).
#
# athena:merge-boarding says "merging is the admiral's alone", and the captain
# template says "Do not merge to main at any point". Until this hook, both were
# prose: forge-identity-guard denies only the BARE `gh pr merge`, and the
# wrapper form is its sanctioned path for every role. On 2026-09-22 the DND-321
# captain ran `gh-athena pr merge 275 --squash --auto` against its brief, past
# the admiral's integration-gate exit 4 (an owner-gated merge).
#
# WHO MAY (an allow-list; deny by default once a call is merge-class):
#   * a top-level session: no agent_id, and either no agent_type (the human,
#     the coordinator, a cron runner's parent session) or an attended
#     interactive `claude --agent X` for any X (DND-1934; FleetView starts
#     its coordinators as `claude --agent claude`). Attended means Claude
#     Code's own CLAUDE_CODE_ENTRYPOINT=cli AND CLAUDE_CODE_SESSION_ATTENDED=1
#     in the hook's environment (MergeRole.attended?). The same test holds for
#     every merge class below, not only the admiral spawn;
#   * agent_type athena-admiral, any merge-class call, any repo;
#   * agent_type athena-shipwright, ONLY a push to a protected branch run
#     inside a cron lane of this hook's own repo
#     (<common dir>/shipwright-lanes/run-* or leadtime-lanes/run-*): the cron
#     lane's documented `gh-athena git ... push origin HEAD:main`
#     (athena:shipwright-lane -> Sync up).
# Everyone else is denied: athena-captain, athena-architect, general-purpose,
# claude, Explore, a hand-spawned shipwright, a headless `claude -p --agent X`
# for any X but the admiral, a `--agent X` session whose mode the guard cannot
# tell (a missing, half or contradictory pair of mode variables), and a
# subagent whose agent_type is empty.
# Measured on Claude Code 2.1.286 (DND-726 step 0): a subagent's
# PreToolUse(Bash) stdin carries agent_id + agent_type; a top-level session
# carries neither; `claude -p --agent X` carries agent_type X, no agent_id.
# Measured again on 2.1.286 for DND-1934, in a PreToolUse hook's own
# environment: an interactive `claude --agent claude` sends that same
# payload (agent_type claude, no agent_id) with ENTRYPOINT=cli and
# ATTENDED=1; its subagents inherit cli + 1 and carry an agent_id; a
# `claude -p --agent claude` gets sdk-cli + 0 even when launched with cli + 1
# set, because -p overwrites both.
# A subagent's Bash starts in the session root (the payload cwd) on every
# call; a top-level session's Bash keeps an earlier call's `cd`, so for it a
# command with no `cd`/`-C` runs in a directory the guard cannot resolve.
#
# WHAT IS MERGE-CLASS (ai/lib/merge_role.rb holds the rules):
#   1. `pr merge`, `mr merge`, `mr accept`, `locked-merge`, as tokens anywhere
#      (any wrapper, `$VAR` command word, `sh -c` script, `;`/newline join,
#      quotes and backslash escapes removed as the shell removes them);
#   2. API merge and ref-write endpoints: REST pulls/<n>/merge,
#      repos/<o>/<r>/merges and merge-upstream; GraphQL mergePullRequest,
#      enablePullRequestAutoMerge, enqueuePullRequest, mergeBranch,
#      createCommitOnBranch, updateRef(s); GitLab merge_requests/<n>/merge,
#      .../merge_when_pipeline_succeeds, merge_trains/merge_requests; and,
#      only with a write method or fields, REST git/refs and contents/, GitLab
#      repository/commits and repository/files;
#   3. a `git push`, `git send-pack` or `git subtree push` (plain or through
#      gh-athena/glab-athena git) whose destination is main, master or the
#      remote's default branch, or --all/--mirror; a no-refspec push goes
#      where config sends it (remote.<r>.push, push.default), and a push whose
#      destination is set by -c, GIT_CONFIG_* or xargs is unresolved;
#   4. a local landing on such a branch: merge, rebase, cherry-pick, reset,
#      pull (except a sync with origin), and update-ref / branch -f|-M|-C /
#      checkout -B / switch -C / fetch <src>:<dst> / rebase <up> <branch>
#      onto one;
#   5. `wt merge`, `gt merge` in command position;
#   6. an MCP tool whose name says merge or enqueue;
#   7. an Agent/Task spawn of athena-admiral: an admiral a non-admiral spawns
#      could merge on its behalf. Only top-level sessions start admirals.
# Two harmless shapes pass (DND-1865): a `git update-ref` in a resolved work
# tree whose repo has no remote at all (a scratch repo; a repo with remotes, a
# bare repo, or a failed `git remote` read keeps the full check), and
# `git push -h|--help` before any refspec (usage only; nothing is sent).
# Anything it cannot resolve (a `cd "$VAR"`, a cd in a subshell or after `||`,
# --git-dir/GIT_DIR, a destination in a variable, a path that is not a repo)
# is never read as "not main": a non-admiral is denied, naming what it could
# not tell.
#
# ACCEPTED FALSE POSITIVE: matching is lexical, so a non-admiral command that
# only MENTIONS a merge (a heredoc, a commit message, a grep) is denied. That
# costs one retry through a file; a miss costs an owner-gated merge.
#
# RESIDUALS (not closed here; DND-726 names them): code the guard cannot read
# (a script written then run, an encoded command, a git hook, an alias); a
# headless `claude -p` started from a subagent's Bash (top level, so allowed);
# likewise an interactive `claude --agent X` a subagent starts in a terminal
# multiplexer (attended by the mode variables, so allowed; it reaches nothing
# the plain `claude -p` above does not);
# the shared forge identity (server-side separation is owner-gated); a stacked
# PR whose target is a sibling feature branch; trusted top-level sessions; and
# a look-alike lane: a hand-spawned shipwright that adds its own worktree under
# <common dir>/shipwright-lanes/run-* passes the lane check (it is not tied to
# the runner's lock).
#
# FAIL-OPEN: stdin that is not a JSON object, a tool it does not handle, no
# ruby on PATH, or a crash of the checker exits 0 with no output. Every deny,
# and every input it could not check, is appended to
# ${XDG_STATE_HOME:-~/.local/state}/athena/merge-role-guard.log (credentials
# masked). That log is the only trace of a guard gone dark; nothing reads it
# on a schedule.
#
# --self-test runs ai/hooks/merge-role-guard.self-test.sh.

SELF="$(realpath -- "${BASH_SOURCE[0]}" 2>/dev/null || printf '%s' "${BASH_SOURCE[0]}")"
HOOK_DIR="$(dirname -- "${SELF}")"

case "${1:-}" in
  --self-test) exec "${HOOK_DIR}/merge-role-guard.self-test.sh" ;;
  -h|--help)
    cat <<'EOF'
merge-role-guard.sh -- Claude Code PreToolUse hook (matchers Bash, mcp__.*,
Agent|Task). Reads the hook JSON on stdin. Denies a merge or a landing onto a
protected branch (pr/mr merge, locked-merge, API merge and ref-write
endpoints, a push to main, a local landing on main, wt/gt merge, an MCP merge
tool) and a spawn of athena-admiral, unless the caller is a top-level session,
athena-admiral, or athena-shipwright pushing from its cron lane. Every other
call passes untouched. Fails open on input it cannot evaluate. Denies are
logged to $XDG_STATE_HOME/athena/merge-role-guard.log.
  --self-test   run ai/hooks/merge-role-guard.self-test.sh
EOF
    exit 0 ;;
esac

INPUT=$(cat 2>/dev/null) || exit 0
[ -n "${INPUT}" ] || exit 0

# Fast path, no ruby: a payload with no merge-shaped word cannot be denied,
# and a payload with no agent_id/agent_type is a top-level session, which is
# always allowed. Both tests read the raw JSON, so a word inside the command
# only ever sends the payload on to the full check (the safe direction).
# Quotes and backslashes are removed first, as the shell removes them, so
# `pu''sh` or `mer\ge` still reaches the full check.
BARE="${INPUT//[\\\'\"]/}"
case "${BARE}" in
  *merge*|*Merge*|*MERGE*|*push*|*nqueue*|*NQUEUE*|*reset*|*cherry-pick*|*rebase*|*update-ref*|*branch*|*pull*|*checkout*|*switch*|*accept*) ;;
  *fetch*|*send-pack*|*subtree*|*git/refs*|*contents/*|*repository/*|*createCommitOnBranch*|*updateRef*) ;;
  *)
    # An Agent/Task spawn is checked for an athena-admiral subagent_type.
    [[ "${INPUT}" =~ \"tool_name\"[[:space:]]*:[[:space:]]*\"(Agent|Task)\" ]] || exit 0 ;;
esac
case "${BARE}" in
  *agent_id*|*agent_type*) ;;
  *) exit 0 ;;
esac

# note <what>: one line in the deny log for an input the checker could not
# evaluate. Hook stderr on exit 0 reaches nobody (DND-433), so a guard that
# went dark is visible only here.
note() {
  _log="${XDG_STATE_HOME:-${HOME}/.local/state}/athena/merge-role-guard.log"
  mkdir -p -- "$(dirname -- "${_log}")" 2>/dev/null
  printf '%s\tunchecked\t\t\t\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" >>"${_log}" 2>/dev/null
}

command -v ruby >/dev/null 2>&1 || { note "no ruby on PATH; allowed unchecked. Fix: put ruby on the PATH Claude Code hooks run with; until then this guard denies nothing"; exit 0; }
OUT=$(printf '%s' "${INPUT}" | ruby "${HOOK_DIR}/../lib/merge_role_io.rb" "${HOOK_DIR}" 2>/dev/null)
RC=$?
[ "${RC}" -eq 0 ] || note "the checker exited ${RC}; allowed unchecked. Fix: run ai/hooks/merge-role-guard.sh --self-test and fix what it names"
[ -n "${OUT}" ] && printf '%s\n' "${OUT}"
exit 0
