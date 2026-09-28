#!/bin/sh
# agent-stash-guard — git reference-transaction hook that stops agent sessions
# from writing the stash list (DND-775; the incident is DND-670).
#
# WHY. Every linked worktree shares ONE stash list with the main checkout:
# refs/stash and its reflog live in the common git dir. A captain's stash pop in
# a fleet worktree popped the owner's saved entry. The PreToolUse text guard
# (ai/hooks/git-stash-guard.sh) read command TEXT, and every new spelling of
# indirection was a new bypass. This hook runs inside git, after git has
# resolved every alias, script, subprocess and typo to the real command.
#
# SCOPE. Agent sessions only. It is a config-based hook, injected through the
# Claude Code settings `env` (GIT_CONFIG_COUNT / GIT_CONFIG_KEY_n /
# GIT_CONFIG_VALUE_n, plus GIT_TRACE2=/dev/null). `scripts/setup-hooks
# --install-env` (the owner's activation step, never plain --install) merges that
# env from ai/hooks/registry.json. The owner's terminal
# never carries it, so the owner's own stash use is untouched. Nothing is
# written to any repo's .git/config or .git/hooks, the global git config, or a
# system file. git runs it with one argument, the transaction state, and the
# queued updates on stdin as `<old> <new> <ref>` lines.
#
# THE RULE (runs on `prepared`; every other state drains stdin and exits 0):
#   R1  a line for refs/stash whose new value differs from the ref's current
#       value is refused (push, save, bare stash, store, clear, drop of the last
#       entry, update-ref, fetch into refs/stash, a conflicting autostash).
#   R1d a line DELETING refs/stash is refused, unless the command git resolved
#       is pack-refs (also run by gc and maintenance): it packs the value, then
#       deletes the loose copy in a second transaction that looks like a delete.
#   R2  any transaction while GIT_TRACE2_PARENT_NAME ends in `stash` is
#       refused, unless an ancestor component is rebase, merge or pull AND an
#       autostash is really in progress (rebase-merge/autostash,
#       rebase-apply/autostash or MERGE_AUTOSTASH exists): the --autostash
#       paths apply a sha, not a list entry. The ancestor name alone is not
#       enough: `rebase -x 'git stash pop'` and a git hook run during a merge
#       also run stash as rebase/stash or merge/stash. pop and apply
#       always write AUTO_MERGE through a transaction, so this catches every
#       spelling of pop/apply/branch except the autostash-window residual
#       below. The name is git's own name for the
#       resolved builtin, not command text: `stash` for a direct call, an alias
#       or an alias chain; `_run_shell_alias_/stash` for a `!` alias;
#       `_run_dashed_/stash` for autocorrect.
# Only one git subprocess runs, and only when a line names refs/stash.
#
# ON REFUSAL git aborts the transaction and exits 128; this prints one stderr
# line naming what was refused and a Fix:. A refused push leaves the change in
# the worktree. A refused pop/apply has ALREADY written the entry's changes into
# the worktree before the transaction (the list keeps the entry): the message
# says not to commit them. The PATH wrapper ai/agent-bin/git refuses pop/apply
# before git runs, so this is the path only for spellings that bypass it.
#
# FAILS CLOSED. The registry's hook command is an inline sh snippet that checks
# this file is executable first. If it is missing, every ref update in an agent
# session aborts with a Fix: naming the one-command disable (owner only):
#   ~/dev/custom/scripts/setup-hooks --remove-env   then restart sessions.
# The path is always the MAIN checkout's (never a worktree's, which vanishes on
# cleanup); ai/bin/check-hooks-registered asserts it.
#
# RESIDUAL (accepted by the owner, Q2, 2026-09-27):
#   - stash drop while more than one entry exists, drop stash@{n}, reflog
#     delete|expire: git rewrites the reflog with no ref transaction, so this
#     hook cannot see them. ai/agent-bin/git refuses their argv spellings. Not
#     caught by either: absolute-path git, `command -p git`, `env PATH=... git`,
#     the inner git of a `!` alias (git puts its exec-path first on the child's
#     PATH), a non-git library. A dropped entry stays a dangling commit until
#     gc.pruneExpire (default two weeks), so it is recoverable.
#   - drop of the ONLY entry: git rewrites the reflog before the ref deletion is
#     refused, so `stash list` reads empty while refs/stash still holds it. The
#     owner restores it with `git stash store -m <msg> $(git rev-parse refs/stash)`.
#   - a stash command run by `rebase -x`, or by a git hook, WHILE a
#     --autostash rebase or merge holds a real autostash (a dirty tree): the
#     autostash state exists, so R2 cannot tell that call from the autostash
#     apply. Without --autostash on a dirty tree the same spelling is refused.
#     Pinned by the suite (T3).
#   - deliberate tampering with the injected env (GIT_CONFIG_COUNT=0, env -u,
#     GIT_TRACE2 unset: R2 goes blind, and a pre-set
#     GIT_TRACE2_PARENT_NAME=pack-refs then passes R1d's pack-refs exemption
#     for a refs/stash delete). The wrapper refuses -c/--config-env
#     spellings aimed at hook.agentstash.* or hook.reference-transaction.*.
#   - git inside a container, or under a process that replaces GIT_CONFIG_COUNT.
#     Suites that do this in their own sandbox drop the hook there, and create
#     only fixture repos (see ai/test/agent-stash-guard/self-test.sh, condition
#     b): gh-athena and glab-athena (unset GIT_CONFIG_COUNT) and the `env -i`
#     suites.

case "${1:-}" in
  -h | --help)
    printf '%s\n' "agent-stash-guard.sh <preparing|prepared|committed|aborted>" \
      "  A git reference-transaction hook (DND-775): git runs it, with the queued" \
      "  ref updates on stdin, and it refuses any stash-list write in agent sessions." \
      "  Not run by hand. Registered through ai/hooks/registry.json's env section" \
      "  (scripts/setup-hooks --install-env); disabled with --remove-env."
    exit 0 ;;
esac

state=${1:-}
if [ "$state" != prepared ]; then
  cat >/dev/null
  exit 0
fi

parent=${GIT_TRACE2_PARENT_NAME:-}
FIX="Fix: agent sessions never write the stash list. To park WIP, commit it on your worktree branch (git add -A && git commit -m \"WIP: <what>\"); for a clean tree, git worktree add <path> -b <scratch-branch>. Read-only stash list/show/create stay allowed."

refuse() {
  printf 'agent-stash-guard: REFUSED %s (git command: %s). Every worktree shares ONE stash list with the owner'"'"'s main checkout (refs/stash lives in the common git dir). %s %s\n' \
    "$1" "${parent:-unknown}" "$2" "$FIX" >&2
  cat >/dev/null
  exit 1
}

is_zero() {
  case "$1" in *[!0]*) return 1 ;; *) return 0 ;; esac
}

while read -r _old new ref; do
  [ "$ref" = refs/stash ] || continue
  if is_zero "$new"; then
    case "/$parent" in */pack-refs) continue ;; esac
    refuse "deleting refs/stash" "If stash list now reads empty, the entry is still in refs/stash: the owner restores it with git stash store -m <msg> \$(git rev-parse refs/stash)."
  fi
  cur=$(git rev-parse -q --verify refs/stash 2>/dev/null) || cur=
  [ "$new" = "$cur" ] && continue
  refuse "changing refs/stash" "The list is unchanged; a refused push leaves your change in the worktree."
done

# in_autostash: true only while a rebase or merge really holds an autostash.
# The ancestor name alone is not enough: `git rebase -x 'git stash pop'`, or a
# hook git runs during a merge, also runs stash as rebase/stash or merge/stash
# (critic round 2, probed). A real autostash apply runs while
# rebase-merge/autostash, rebase-apply/autostash or MERGE_AUTOSTASH exists.
in_autostash() {
  # One path per line, read whole: a git dir path may hold spaces.
  _paths=$(git rev-parse --git-path rebase-merge/autostash --git-path rebase-apply/autostash 2>/dev/null)
  while IFS= read -r f; do
    [ -n "$f" ] && [ -f "$f" ] && return 0
  done <<EOF
$_paths
EOF
  git rev-parse -q --verify MERGE_AUTOSTASH >/dev/null 2>&1
}

case "/$parent" in
  */stash)
    case "/$parent/" in
      */rebase/* | */merge/* | */pull/*) in_autostash || refuse "a ref update inside git stash run under $parent with no autostash in progress" "The list keeps the entry. If this was pop/apply (for example from rebase -x or a git hook), git has ALREADY written the entry's changes into this worktree: do not commit them, and report which files it touched to your admiral." ;;
      *) refuse "a ref update inside git stash" "The list keeps the entry. If this was pop/apply, git has ALREADY written the entry's changes into this worktree: do not commit them, and report which files it touched to your admiral." ;;
    esac
    ;;
esac
exit 0
