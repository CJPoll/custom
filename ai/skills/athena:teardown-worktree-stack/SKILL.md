---
name: athena:teardown-worktree-stack
description: How the athena-admiral resolves and runs the per-repo teardown of a merged Mission's docker-compose stack(s) — executable as ai/bin/teardown-stack, which locked-merge runs per merged PR — and how ai/bin/pool-headroom gates dispatch on docker address-pool headroom. Use once a Mission's MR is CONFIRMED merged, when a Mission is parked, or when a run ends with a Mission's PR still open, to reclaim database memory/connections, containers, volumes, and the address-pool network. Encodes the 3-tier resolution (repo teardown script → generic default only when the compose project name is docker's default → documented prose fallback) and the confirm-it-is-gone check. The merge-gating and only-your-fleet's-stacks rules stay resident in the admiral definition.
---

# athena:teardown-worktree-stack

**Kind: living normative document.** Amended in place, per
`~/dev/custom/CLAUDE.md` → *Documentation conventions*.

Every worktree gets its own isolated docker-compose stack(s), and idle stacks
hold real capacity: database memory/connections, service containers, volumes, and
an address-pool network. Leaving them up after the Mission lands is how the box
drifts into pool starvation and "all predefined address pools have been fully
subnetted".

Tear a Mission's stack down as soon as its MR is **merged** (not merely green — a
green-but-open MR may still need its stack for review follow-ups, **while a
captain or admiral of this run is live to act on them**) — every per-worktree
stack the repo runs, including volumes, orphans, and the network. When the run
ends with the MR still open, the stack goes too (*Merged is not the only exit*,
below).

**Later (2026-09-29):** the green-but-open exception had no end. A run that
ended with its PRs open left every stack up, classified `LIVE`, and no actor
was permitted to reclaim it. Measured 2026-09-29, three times in one day: a
walt_ui dispatch found all 30 held subnets were stacks of paused or ended
fleets, and two more walt_ui dispatches were refused at 1/31 free with 25
gen_saas stacks up, 20 of them behind open PRs days old.

## The merge drives it: `ai/bin/teardown-stack`

The procedure below is executable. `~/dev/custom/ai/bin/teardown-stack` runs
it for ONE merged change. It confirms the merge with `confirm-merged`, reads
the PR/MR's head branch from the forge, and picks the one worktree with that
branch checked out. It then resolves the teardown tier and runs it. Tier 2
verifies afterwards that no container, volume or network carries the project
label. Tier 1 relies on the repo script's own contract, plus one check the
tool can make without knowing the script's project names: no compose
container is left with its working dir in the worktree. Anything it cannot
attribute is refused with a `Fix:`, and nothing is touched (`--help` has the
exit codes). Both tools share one definition of a worktree that runs a stack:
a root compose file, or a repo teardown script. Compose files only below the
root with no script (`~/dev/custom`'s `templates/`) declare no stack, so
docker is never asked. A repo that runs stacks from below its root must ship
a script (tier 1 below).

- **GitHub:** `locked-merge` runs it after every confirmed landing, per PR. A
  multi-part Mission reclaims each part's stack as that part lands, not at the
  last merge. Its exit 10 means the PR LANDED and the teardown failed: do not
  re-merge, follow the printed `Fix:`.
- **GitLab, no merge train:** `locked-merge --mr` runs it after the landing,
  as on GitHub (DND-1943).
- **GitLab merge train:** no wrapper runs the merge. Right after
  `confirm-merged --mr <n>` exits 0, run `teardown-stack --mr <n> --repo <repo>`.

  **Later (2026-10-03, DND-1943):** this bullet read "**GitLab:** no wrapper
  runs the merge", for every GitLab project. Superseded: a project with no
  merge train merges through `locked-merge --mr`, which runs the teardown.
- **Parked Missions:** `teardown-stack --worktree <wt> --parked <reason>`. The
  tree stays (*Tear down the STACK; keep the TREE*, below).
- **A stack with no containers left** (a captain's `docker compose down`
  without `-v` keeps the volumes) is removed by its **stack marker**. A
  volume's labels name the compose project but not the worktree, and the
  project name is the worktree basename, which another checkout can share. So
  `teardown-stack --record --worktree <wt>` writes
  `<the worktree's git dir>/athena-stack-marker.json` while the containers
  still prove the stack is that worktree's: the worktree, the project, and
  each volume (by name and creation time) and network (by id) whose compose
  key the worktree's own `docker compose config` declares. A labelled
  resource it does not declare is named and not recorded. `integration-gate`
  runs it after every gate, so every gated worktree has one. The git dir
  belongs to that one worktree and goes with it. At teardown, exactly the
  matched volumes and networks are removed (`docker volume rm`, `docker
  network rm`), never `down -v`. A missing marker, one naming another
  worktree or project, or any resource it does not match (a volume
  re-created since) is refused with exit 2. The refusal names every
  resource and why, and its `Fix:` gives the exact removal command for you to
  run once you have checked them by hand. Measured 2026-10-01: gen_saas PRs
  #658 and #661 each left 3 volumes and 0 containers, `locked-merge` exited
  10, and the admiral removed them by hand (DND-1576).
- **Then the worktree:** after a merged change's teardown, remove its worktree
  per *Removing the WORKTREE*, below. That half stays with you.
- **What still leaks** is named at the next dispatch by `pool-headroom`
  (*Reclaiming the address pool*, below). That covers another fleet's stack,
  a GitLab merge nobody followed up, and a worktree removed before its merge
  landed: `teardown-stack` refuses a registered worktree whose directory is
  gone unless the repo ships a script that handles that case (walt_ui's does).

**Later (2026-09-27, DND-864):** teardown was a step the admiral ran by hand
at merge time. On 2026-09-26 ~20:33Z the address pool ran out under two new
gen_saas captains, with 21 gen_saas stacks up. DND-520's four PRs (#417-#420)
had kept all four stacks up across two hours of merges.

**Merged is not the only exit.** A Mission that terminates **non-DONE** — `STUCK`
and parked, `BLOCKED_ON_DEPENDENCY` with no near-term unblock, or cancelled —
also gets its stack torn down, right when you park it. It will never reach a
merge, so a merge-only rule leaks its stack for the rest of the run: idle, but
still holding database memory, containers, volumes, and an address-pool slot,
which is precisely what this skill exists to prevent. A parked Mission has no
review follow-up for its stack to serve, so nothing is being preserved by
leaving it up.

**The run ending is an exit too.** When your run ends (the triggers in
[[athena:admiral-final-report]], a usage ceiling included) with a Mission's PR
still open — finished-but-unmerged, handed off, blocked or stuck — tear its
stack down: `teardown-stack --worktree <wt> --parked "run-end: PR #<n> open"`.
Once no captain or admiral of the run is live, no review follow-up remains for
the stack to serve, and only the owning run knows it has ended, so it is the
one actor that can release the subnet safely. Record `stack: down (run-end)` in
the Mission's state-log entry, and name the teardown in the final report. The
one exception is a PR you are still riding to landed
([[athena:merge-boarding]]); that run has not ended.

**Whoever adopts that PR re-ups first.** A resumed or later run that adopts a
Mission whose state-log entry says `stack: down`, or whose worktree has no
running stack, brings the repo's worktree stack up before the first gate, and
says so in the captain's brief ("stack is down; bring it up before the first
gate"). Otherwise the gate's first symptom is a bare database error (gen_saas:
`3D000`, the DND-1229 class). The re-up, and the recompile `-v` costs, are the
accepted price of not starving every fleet's pool.

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

**Remove a merged Mission's worktree in the same step as its stack**, once the
merge is confirmed and the tree is clean. The stack half is `teardown-stack`
(*The merge drives it*, above): its `TORN DOWN` or "nothing to tear down" line
ends with a `next:` line naming the worktree, and that is when you remove it by
hand, with the checks below. The tool does not remove the tree itself: removal
is the one step here that can destroy uncommitted work, it needs the salvage
and husk judgment below, and `locked-merge` may be running from inside that
very worktree. A merged worktree has no work left to
serve, and each one holds real disk (a gen_saas tree with `deps`/`_build` is
~3G). Measured 2026-09-27: one admiral kept 33 merged lane worktrees, `/home`
hit 100% (ENOSPC), and two fleets' gates and a state-log append failed until a
cleanup freed 90G (`2026-09-25-dnd-671-650-644/state.md`, "08:3xZ RESOURCE
FAILURE"). The stack-only rule above is about PARKED, unmerged work; merged
work keeps neither.

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

**A root-owned husk is not a failed removal — reclaim it without `sudo`.** A repo
whose stack builds inside docker (bind-mounting the worktree) leaves
`backend/deps`, `_build`, and the like owned by `root` on the host. `git worktree
remove` then deregisters the worktree cleanly but cannot `rm` those dirs, so a
root-owned husk stays behind under `~/.local/worktrees/<project>/`. Measured
2026-09-22: six husks from a single epic; the honest-but-wrong reflex is `sudo rm
-rf`, a system-level act this harness does not take unattended. The sanctioned
reclaim is a **throwaway container** operating only on the user's own
docker-created files — the same class as `docker network prune` below, not a
system change: no daemon, no `/etc`, no `sudo`. From the husk's PARENT
(`~/.local/worktrees/<project>`):

```sh
docker run --rm -v "$PWD":/mnt alpine rm -rf "/mnt/<husk-dir-basename>"
```

Target the **single** husk directory by name — never the parent, which holds
other worktrees' live siblings — and afterward confirm the siblings survived
(`ls` the parent, cross-check `git worktree list`). Do this only for a husk whose
worktree is already deregistered (or which you have just removed per the
salvage-first rule above); a husk you cannot account for is left alone and
reported.

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

## Reclaiming the address pool when it starves — a DIFFERENT class

The rules above — only your own fleet's stacks, only after a confirmed merge —
govern `docker compose down -v`, which **destroys volumes and therefore data**.
They are not the right rule for an exhausted address pool, and applying them
there leaves no sanctioned way to reclaim an orphaned network: the dead lanes
holding the last subnets belong to runs that ended, so nobody's live fleet owns
them and every fleet's next dispatch wedges on
`all predefined address pools have been fully subnetted`. That is a machine-wide
stop with no actor permitted to clear it.

**The pool is probed before every dispatch, not after the wedge.**
`~/dev/custom/ai/bin/pool-headroom` counts free subnets against docker's
configured pools (the built-in pools hold 31). It exits 1 below `--min-free`
(default 2) and names each holder: `MERGED-BUT-UP` with its `teardown-stack`
line, `ORPHAN` (worktree gone), or `LIVE`. A docker it cannot read is exit 3,
never headroom. Every docker, git and forge call it makes is bounded (DND-1088:
a hung `glab` once held every `wt-preflight` for 28 minutes). A holder whose
merge lookup fails or times out is merge state `UNKNOWN`; a LOW run's `Fix:`
names every command that hung. `UNKNOWN` never moves the OK/LOW verdict, which
is docker's pool count alone. The stack is listed, gets no teardown line, and
is torn down only after `confirm-merged` says it merged.
`scripts/wt-preflight` runs it first for any repo whose worktrees run a stack (a root compose file, or a repo teardown script), so no
stack-running worktree is created while the pool is out. Run it by hand with
`--list` to see every holder. Tear down only YOUR fleet's `MERGED-BUT-UP`
stacks; another fleet's is its admiral's, so tell that admiral or the session
that launched you. Residual: two admirals preflighting at the same moment can
both see the last free subnet (check-then-act); the default `--min-free 2`
narrows that window without closing it.

**Later (2026-09-27, DND-864):** this paragraph was a two-command shell probe
to run "before a dispatch wave". Nothing ran it. The probe is now
`pool-headroom`, and `wt-preflight` runs it.

An idle network (no container attached) from an ended run is a corpse holding a subnet.
When free subnets are running out, **`docker network prune -f` is sanctioned,
whoever created the networks** — and it is a genuinely different act from a
destructive teardown:

- Its safety predicate is exactly *no container is attached*, enforced by docker
  itself, so it cannot take a network a live lane is using. You are not judging
  liveness; docker is.
- It destroys **no volume, no image, and no data** — only an address-pool
  reservation.
- A compose project recreates its network automatically on the next `up`, so the
  reclaim is reversible by the normal path.
- It is not a system-level change: no daemon, no service, no `/etc`, no `sudo`.

Verify afterwards that every network you still need survived with its containers
still attached (re-run `pool-headroom --list`), and record the count before and after
in the state log.

Residual, accepted: an agent holding a **stopped** stack it meant to
`docker compose start` now needs `docker compose up` instead — which is the
normal path anyway, and far cheaper than a machine-wide dispatch wedge.

**Volumes are NOT in this class.** They are the data-bearing resource, and a
volume belonging to another lane is not yours to reclaim — `docker volume prune`
and friends stay off the table. A large reclaimable-volume figure is an owner
follow-up to report, never an action to take.

Measured 2026-09-20-ai-lms (DEC-010): the pool was probed at 30 networks, 27 of
them idle, with **one free subnet left** — the next dispatch of any lane would
have wedged. All fifteen `172.17–172.31/16` pools were consumed, by 24
`walt-ui-*` lanes from runs that had already ended. `docker network prune -f`
took 30 → 6 and all three live networks survived intact. The admiral got there
only by reasoning its way out of its own teardown rule mid-run; that reasoning
is what this section replaces.
