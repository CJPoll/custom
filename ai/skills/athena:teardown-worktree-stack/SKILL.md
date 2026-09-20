---
name: athena:teardown-worktree-stack
description: How the athena-admiral resolves and runs the per-repo teardown of a merged Mission's docker-compose stack(s). Use once a Mission's MR is CONFIRMED merged, to reclaim database memory/connections, containers, volumes, and the address-pool network. Encodes the 3-tier resolution (repo teardown script → generic default only when the compose project name is docker's default → documented prose fallback) and the confirm-it-is-gone check. The merge-gating and only-your-fleet's-stacks rules stay resident in the admiral definition.
---

# athena:teardown-worktree-stack

Every worktree gets its own isolated docker-compose stack(s), and idle stacks
hold real capacity: database memory/connections, service containers, volumes, and
an address-pool network. Leaving them up after the Mission lands is how the box
drifts into pool starvation and "all predefined address pools have been fully
subnetted".

Tear a Mission's stack down as soon as its MR is **merged** (not merely green — a
green-but-open MR may still need its stack for review follow-ups) — every
per-worktree stack the repo runs, including volumes, orphans, and the network.

**Merged is not the only exit.** A Mission that terminates **non-DONE** — `STUCK`
and parked, `BLOCKED_ON_DEPENDENCY` with no near-term unblock, or cancelled —
also gets its stack torn down, right when you park it. It will never reach a
merge, so a merge-only rule leaks its stack for the rest of the run: idle, but
still holding database memory, containers, volumes, and an address-pool slot,
which is precisely what this skill exists to prevent. A parked Mission has no
review follow-up for its stack to serve, so nothing is being preserved by
leaving it up.

**Tear down the STACK; keep the TREE.** The work is the worktree, the branch,
and the commits — never the containers. So this does not conflict with "never on
a closed-unmerged MR whose work may be revived" above: preserve the worktree and
the branch exactly as they are, and reclaim only the stack. Reviving a parked
Mission then costs one stack re-up (and, where `-v` removed build caches, a
recompile) — not a lost commit.

Applies to your own fleet's Missions only, same as everything else here. Record
the teardown and the reason (`parked STUCK`, `cancelled`) in the Mission's
state-log entry, so the next sweep does not go looking for a stack that is
deliberately gone.

## Removing the WORKTREE: never over uncommitted work

Cleaning up the worktree itself is a different act from tearing down its stack,
and it is destructive in a way the stack is not: a stack re-ups, a deleted
uncommitted edit does not. **Before `git worktree remove` / `wt remove`, read
`git -C <worktree> status --porcelain`. If it is not empty, do not remove it.**
Salvage first — the same discipline [[athena:admiral-resume]] already applies
before a re-dispatch: copy the dirty files (or record a `git stash create` sha)
into `.../[run-id]/salvage/[mission]/`, note in the state log what the worktree
held, and only then remove. A worktree that is dirty for a reason you cannot
explain is left alone and reported; it costs nothing to keep.

Note `git worktree remove` refuses a dirty tree by default — **that refusal is a
finding, not an obstacle.** Never reach for `--force` to get past it.

- Measured 2026-09-19-slack-gensaas / DND-194: the MR was merged while the
  captain's diff-critic round was still finishing, and the post-merge cleanup
  removed the worktree with two uncommitted critic fixes in it — one of them
  correcting a BLOCKING factual error (it called walt_ui's `SessionStart` polls
  `UserPromptSubmit` hooks, inverting the very distinction the document turns
  on). The error landed on `main` and needed a follow-up PR to clear.

The merge bar in [[athena:merge-boarding]] is the other half of this and was
independently in force: merge on the captain's `DONE` **plus** its report file,
never on forge state while the captain's worktree is still moving. Salvage is
what keeps a mistimed merge from also being a lost fix.

**How the teardown command is resolved is per-repo** (the project-name derivation
and working directory are repo-specific, and a bare `down -v` in the wrong repo
destroys the wrong stack's volumes). Resolve it in order:

1. **Repo-provided teardown script (preferred).** If the repo has
   `bin/teardown-worktree-stack.sh` (or `.claude/teardown-worktree-stack.sh`),
   run it with the worktree path: `<repo>/bin/teardown-worktree-stack.sh
   <worktree>`. Its contract: tear down *every* stack that worktree runs —
   containers, volumes, orphans, and network — and exit nonzero if it cannot. The
   repo owns the project-name derivation and cwd, so this cannot mis-target a
   destructive `-v`; prefer it whenever it exists.
2. **Generic default — ONLY when the compose project name is docker's default
   (the worktree-directory basename): compose at the repo/worktree root, no
   sourced env var and no explicit `name:`/`-p`.** Then, from the worktree root:
   `docker compose down -v --remove-orphans`. Do **not** use this for a repo
   whose project name comes from a sourced env var or a prefix — a bare `down`
   there targets the wrong (often shared) stack and `-v` wipes its volumes.
3. **Documented prose fallback.** If a repo isolates stacks non-standardly but
   ships no script, follow its documented teardown (its CLAUDE.md) exactly, and
   note in your report that this hand-assembled destructive path is the least
   safe — a repo that lacks a step-1 script should get one.

Rules (the admiral definition keeps the merge-gating and scope rules resident;
they are repeated here so the procedure carries its own safety):
- This is the admiral's, not the athena-captain's — they may have terminated
  before the merge happened, and their DONE must not depend on a merge they don't
  perform.
- Only ever tear down stacks belonging to YOUR fleet's Missions, and only after
  verifying the merge (`merged_at` set, or the branch an ancestor of the target)
  — never on a closed-unmerged MR whose work may be revived, and never another
  fleet's stack.
- Confirm afterwards that the stack's containers, volumes, and network are gone
  (`docker ps -a`, `docker volume ls`, `docker network ls`, filtered by the
  project name). A `down` that only removed containers leaves the network holding
  an address-pool slot.
- Record the teardown in the Mission's state-log entry.
