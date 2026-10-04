---
name: athena:shipwright-lane
description: How an athena-shipwright provisions its own short-lived git lane (cron per-invocation lane vs. a directly-spawned named worktree/branch), syncs it down from origin/main before mining, commits through the path-limited commit wrapper, and syncs the result back up (cron fast-forward vs. a direct-spawn PR) — including the forge-git fetch through Athena's route and the refspec mechanics needed because HEAD is never `main`. Use whenever an athena-shipwright starts a run, is about to commit, or is about to sync down/up.
---

# athena:shipwright-lane

## Where you run

**You do not work in the main checkout.** Every invocation is its own unit of
work and runs in its OWN short-lived lane, created from `origin/main` and torn
down after the run — there is no standing shared lane. Uniform however you
were started:

- a **cron** invocation is dropped by its runner into a fresh lane, and
  lands on main by pushing plus a main-checkout fast-forward the runner does
  for you. Two cron runners start a shipwright, and your brief names the lane:
  - the shipwright cron (`scripts/athena-shipwright-run.sh`):
    `<repo>/.git/shipwright-lanes/run-<utc>-<pid>` on branch
    `shipwright/run-<utc>-<pid>`;
  - the lead-time improver cron (`scripts/athena-leadtime-run.sh`, brief
    `MODE: lead-time`): `<repo>/.git/leadtime-lanes/run-<utc>-<pid>` on
    branch `leadtime/run-<utc>-<pid>`;
- a shipwright **spawned directly** (by hand or by another agent) creates its
  OWN named branch and worktree under `~/.local/worktrees/custom/<branch>`
  (named for this unit of work) and **opens a PR** for an admiral to merge
  (`CLAUDE.md` → *A directly-spawned agent…*), rather than pushing to main.

Either way, never edit in the main checkout — if you find yourself in
`~/dev/custom` itself, move to a worktree first. The main checkout is the
machine's live harness surface (`~/.claude/skills` and `~/.claude/hooks`
resolve into it) and the tree interactive sessions are typing in. On
2026-09-18 a run shared it with such a session and swept that session's
`hypr/hyprland.conf` edit and a 230-line `.bak` into `ce70e04`, a commit whose
message was entirely about harness-gate self-tests.

A crashed cron run leaves a lane corpse the next cron run reaps, judging
liveness by a held `flock(2)` on the lane's lock and never by a pid (pids
recycle); reaping another run's lane by hand is not a thing anyone does.

Two consequences to carry:

- **Your memory does not move with your tree.** `$SHIPWRIGHT_STATE_DIR`
  (`cursor.txt`, `journal.md`) is always the **main
  checkout's** state, resolved via `dirname "$(git rev-parse
  --path-format=absolute --git-common-dir)"` if the env var is unset — never
  derived from your cwd.
  In `MODE: lead-time` your state dir is the one your brief names
  (`LEAD_TIME_STATE_DIR`, the main checkout's `ai-artifacts/lead-time`).
  Everything else — the code you edit, the commits you make — is your
  worktree's.

  **Later (2026-10-01, DND-1480):** this skill named only the shipwright
  cron's lane, and `$SHIPWRIGHT_STATE_DIR` held the lead-time cursors.
  Superseded: lead time moved to its own cron runner and state dir.

  **Later (2026-10-03):** the resolver had no `--path-format=absolute`.
  Superseded: without it, git prints the common dir relative to the cwd in a
  main checkout (`.git` at its root, `../.git` one level down), so `dirname`
  gives `.` or `..`, a path that names the state dir only from that cwd
  (DND-1722 report, finding 3; `~/.claude/CLAUDE.md` → *A failed lookup must
  never look like an empty one*).
- **On the cron path, you land on main by refspec, not by branch name.** Your
  HEAD is a per-invocation `shipwright/run-*` or `leadtime/run-*` branch, so a bare
  `git pull`/`git push` does the wrong thing — spell both ends out (below). A
  **directly-spawned** run does the opposite: it commits on its own named
  branch and opens a PR, never pushing to main and never fast-forwarding the
  main checkout itself.

## Sync down first

In your worktree, get current with the remote before you change anything:

```
~/dev/custom/ai/bin/forge-git -C "$PWD" fetch origin main && git rebase --autostash FETCH_HEAD
```

`forge-git` reads origin through Athena's forge route: `gh-athena git` for a
github.com origin, `glab-athena git` for a gitlab.com one, over HTTPS with the
bot's token (DND-1977). A cron session has no ssh-agent, and the owner's SSH
key is not the lane's to use.

This is also where another machine's shipwright commits land, so pulling
first is how you avoid duplicating a fix that already exists. If the rebase
hits a conflict you cannot resolve cleanly and mechanically, do **not** force
it — abort (`git rebase --abort`), journal the conflict, and skip this run's
harness edits (a dirty or half-rebased tree must never be the base for new
work). On the cron path the lane is already branched from `origin/main`, so
this is usually a no-op that only picks up anything landed since; it stays
because a directly-spawned run needs it and it is harmless when already
current.

If the `forge-git` fetch fails (its exit is non-zero: an expired bot token,
the network, or exit 3 for an origin form the route refuses), the sync is
unavailable: journal the error line and skip this run's edits. Never fall back
to plain git or to the owner's `gh` credential helper.

**Later (2026-10-04, DND-1977):** this step ran a plain `git fetch origin
main`, with an *SSH-denied fallback* through the owner's
`gh auth git-credential` helper when the cron session had no ssh-agent.
Superseded by `forge-git`: both reached origin as the owner, and neither works
against a private gitlab.com origin after the GitLab cutover (DND-1947).

## Commit only through the wrapper, naming every path

One commit per concern, in your worktree. **Commit only through
`scripts/athena-shipwright-commit.sh`, naming every path explicitly:**

```
scripts/athena-shipwright-commit.sh -F <msg-file> -- ai/agents/x.md.in ai/agents/x.md
```

(`-m 'subject'` for a one-liner; `--dry-run` shows what would go in.) It
stages only the paths you name and commits pathspec-limited, so nothing else
in the tree or the index can ride along, and it refuses a catch-all pathspec
outright. **Nothing else in this repo may stage or commit a path you did not
name** — this covers `git add -A`/`.`/`-u`, `git commit -a`, `scripts/gc
-a|--all`, a directory or glob argument, and whatever else stages more than
you listed. You run unattended on an hourly cron, and the rule earns its keep
whether or not you share a tree.

Measured 2026-09-18 (21:00 run): a whole-worktree commit swept in a
concurrent session's `hypr/hyprland.conf` edit AND a 230-line
`hyprland.conf.bak-*`, landing them under commit `ce70e04`, whose message was
entirely about harness-gate self-tests; that session had to push a corrective
commit. It is also how an unrelated in-flight change gets *attributed* to you
in `git log` — the audit trail the "commit only what you changed" invariant
relies on. If the helper reports paths dirty outside your commit, that is
someone else's work: leave it exactly as it is — do not `git add` it, do not
`git restore` it, and do not mention it in your message. When the shipwright cron starts you,
the runner has already yielded the tick rather than begin on a dirty MAIN
CHECKOUT — dirt there means a person is live in the repository. The
lead-time runner has no such yield. Either way your cron lane is freshly
created from `origin/main` and always clean. Started by hand
you get no such check, so in a dirty tree the rule applies harder, not less.

Append a journal entry (format in the agent template). Advance `cursor.txt`
only after all of a run's qualifying patterns are handled — write it as the
newest processed artifact's **full mtime including sub-second precision**
(e.g. `date -d "$(stat -c %y <file>)" +%Y-%m-%dT%H:%M:%S.%N%:z`), or a
timestamp strictly after it. `find -newer` compares sub-second mtimes, so a
whole-second cursor re-selects the last artifact on every future run
(harmless — the journal dedups it — but it re-opens a file already mined).

## Sync up

This step is the **cron path**; a directly-spawned run instead opens a PR
from its own named branch and does not push to main. After the run's commits
are in and `harness-gate` is green, **record the receipt** the push needs. Run
*Sync down first* again (so `origin/main` is current), then, from your lane:

```
~/dev/custom/ai/bin/integration-gate --with-critic --rebase
```

It takes its own test slot (never wrap it in `test-slot`) and runs the gate
and the standing judge on the lane's head. On `INTEGRATION OK` it records the
receipt for that exact commit. The forge wrapper's push refuses a push to main in
this repo unless integration-gate passed exactly the pushed commit, or the
pushed commit is a clean rebase of a head it passed onto a newer `origin/main`
(DND-1690; the refusal says `NO RECEIPT` with a `Fix:`). That holds on a green
main as well as a red one. Anything but exit 0 means do not push yet. By
exit (`integration-gate --help` has the full list):

- **1 (gate RED) or 3 (critic BLOCK or no verdict):** fix the findings in one
  more commit and run it once more. Still not OK: journal it and reset your
  lane to `origin/main` (`git reset --hard origin/main`, in your lane only),
  so the runner does not count a rejected change as a stranded push.
- **2:** read the line. `REBASE CONFLICT` follows *Sync down first*: journal
  it, reset the lane as above, skip this run's edits. A refused tree
  (uncommitted or untracked paths) means a path you meant to commit is not
  committed: commit it through the wrapper, or remove it, and re-run.
- **4 (blast radius):** only Cody clears it, so there is nothing to fix.
  Journal it and leave the commits local; the runner keeps the stranded
  branch, and an admiral lands it, as for an installer below.
- **5 or 6 (receipt not written, gate not run):** an environment fault. Re-run
  once; still failing, journal it and leave the commits local.

Never `--critic-override` from a cron lane.

**Later (2026-10-02, DND-1690):** this step pushed once "the gate is green",
meaning `harness-gate`, with no receipt and no critic verdict. Superseded: the
wrapper checked a receipt only while main was red, and on a green main a lane
pushed `bcfd66b6` ungated and main went red (DND-1685). A receipt for the
pushed commit is now required at the push itself.

Then push as Athena with an explicit refspec, through `forge-push`, which
runs the wrapper for origin's host (`gh-athena git push` for github.com,
`glab-athena git push` for gitlab.com) from forge-git's host table:

```
GIT_TERMINAL_PROMPT=0 ~/dev/custom/ai/bin/forge-push -C <your lane> origin HEAD:main
```

Never name the wrapper by hand (DND-1995): after the GitLab cutover
(DND-1947) a `gh-athena git push` no longer reaches origin as Athena. An
origin forge-push does not route (ssh://, a host alias, another host) is
refused, exit 3, with a `Fix:`: journal it and leave the commits local.

The refspec matters because your HEAD is a per-invocation `shipwright/run-*`
or `leadtime/run-*` branch: a bare push would advance that branch on the remote instead of
landing on main, and the remote rejects a non-fast-forward. If the push is
rejected because the remote moved under you, re-run *Sync down first* and
push again (bounded: at most a couple of attempts); if it still fails,
journal it and leave the commits local for the owner rather than forcing.
A clean rebase keeps the receipt's cover; if the wrapper then refuses with
`NO RECEIPT`, the rebase changed the tree, so run integration-gate again
before the next attempt.
If the wrapper refuses with exit 3 and `RED MAIN`, `origin/main` is red
(`ai/bin/main-health`, DND-1482) and only a gated fix may land: journal it,
leave the commits local, and do not retry this run.
Before the push, run `~/dev/custom/ai/bin/landing-installers --dry-run
--from origin/main --to HEAD`. If it names an installer, do not push: no cron
session may run an installer (`~/.claude/CLAUDE.md` → *Owner approval
policy* → *Notify after*), and a landed hook or inbox row reads as drift
until one runs, so `main` would go RED (DND-1664). Journal it and leave the
commits local; the runner keeps the stranded branch, and an admiral lands it
by `athena:merge-boarding`'s no-CI landing. Any other non-zero exit (HEAD
not yet on `origin/main`: re-run *Sync down first*) means the plan is
unknown, so do not push on it either.
**Never `git push --force`** on this repo. Push only `~/dev/custom` — never a
product repo through this skill. (A lead-time run's product-repo change is
pushed by `ai/bin/leadtime-product`, not here: `athena:lead-time-improve` →
*The product lane*.) If a run made no commits, there is nothing to push; still leave
your worktree current from *Sync down first*. You do **not** update the main
checkout yourself — the cron runner fast-forwards it after you exit, and
doing it by hand is work in the main checkout.
