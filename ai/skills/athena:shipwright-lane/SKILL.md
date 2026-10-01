---
name: athena:shipwright-lane
description: How an athena-shipwright provisions its own short-lived git lane (cron per-invocation lane vs. a directly-spawned named worktree/branch), syncs it down from origin/main before mining, commits through the path-limited commit wrapper, and syncs the result back up (cron fast-forward vs. a direct-spawn PR) — including the SSH-denied cron fallback and the refspec mechanics needed because HEAD is never `main`. Use whenever an athena-shipwright starts a run, is about to commit, or is about to sync down/up.
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
  --git-common-dir)"` if the env var is unset — never derived from your cwd.
  In `MODE: lead-time` your state dir is the one your brief names
  (`LEAD_TIME_STATE_DIR`, the main checkout's `ai-artifacts/lead-time`).
  Everything else — the code you edit, the commits you make — is your
  worktree's.

  **Later (2026-10-01, DND-1480):** this skill named only the shipwright
  cron's lane, and `$SHIPWRIGHT_STATE_DIR` held the lead-time cursors.
  Superseded: lead time moved to its own cron runner and state dir.
- **On the cron path, you land on main by refspec, not by branch name.** Your
  HEAD is a per-invocation `shipwright/run-*` or `leadtime/run-*` branch, so a bare
  `git pull`/`git push` does the wrong thing — spell both ends out (below). A
  **directly-spawned** run does the opposite: it commits on its own named
  branch and opens a PR, never pushing to main and never fast-forwarding the
  main checkout itself.

## Sync down first

In your worktree, get current with the remote before you change anything:

```
git fetch origin main && git rebase --autostash FETCH_HEAD
```

This is also where another machine's shipwright commits land, so pulling
first is how you avoid duplicating a fix that already exists. If the rebase
hits a conflict you cannot resolve cleanly and mechanically, do **not** force
it — abort (`git rebase --abort`), journal the conflict, and skip this run's
harness edits (a dirty or half-rebased tree must never be the base for new
work). On the cron path the lane is already branched from `origin/main`, so
this is usually a no-op that only picks up anything landed since; it stays
because a directly-spawned run needs it and it is harmless when already
current.

**SSH-denied fallback (cron runner):** the remote is `git@github.com:...` but
the headless cron session has no ssh-agent, so a plain `git pull`/`git push`
dies with `Permission denied (publickey)` — this is an *auth gap*, not a
conflict, so do not abort/skip on it. Fall back to the repo's already-
configured `gh` HTTPS credential helper (no config change, no credential
touched):

```
git -c credential.helper='!/usr/bin/gh auth git-credential' fetch \
  https://github.com/CJPoll/custom.git main
git rebase --autostash FETCH_HEAD
git update-ref refs/remotes/origin/main FETCH_HEAD   # so status reads true
```

Only if the HTTPS fallback ALSO fails is the sync genuinely unavailable —
journal it and skip this run's edits.

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
are in and the gate is green, push as Athena with an explicit refspec,
through the wrapper (`athena:github` → *Pushing as Athena*):

```
GIT_TERMINAL_PROMPT=0 ~/dev/custom/ai/bin/gh-athena git -c credential.helper= \
  -c url.https://github.com/.insteadOf=git@github.com: push origin HEAD:main
```

The refspec matters because your HEAD is a per-invocation `shipwright/run-*`
or `leadtime/run-*` branch: a bare push would advance that branch on the remote instead of
landing on main, and the remote rejects a non-fast-forward. If the push is
rejected because the remote moved under you, re-run *Sync down first* and
push again (bounded: at most a couple of attempts); if it still fails,
journal it and leave the commits local for the owner rather than forcing.
If the wrapper refuses with exit 3 and `RED MAIN`, `origin/main` is red
(`ai/bin/main-health`, DND-1482) and only a gated fix may land: journal it,
leave the commits local, and do not retry this run.
**Never `git push --force`** on this repo. Push only `~/dev/custom` — never a
product repo through this skill. (A lead-time run's product-repo change is
pushed by `ai/bin/leadtime-product`, not here: `athena:lead-time-improve` →
*The product lane*.) If a run made no commits, there is nothing to push; still leave
your worktree current from *Sync down first*. You do **not** update the main
checkout yourself — the cron runner fast-forwards it after you exit, and
doing it by hand is work in the main checkout.
