---
name: athena:captain-return
description: How an athena-admiral handles a captain's terminal return (DONE / BLOCKED_ON_DEPENDENCY / STUCK) and frees + refills the concurrency slot, plus propagating a finished dependency's branch into a dependent worktree and retargeting an already-open MR. Use whenever a captain reports, a report file appears, or a dependency resolves. Reports arrive by FILE; the watcher is a fast path only.
---

# athena:captain-return

Each captain reports one of `DONE`, `BLOCKED_ON_DEPENDENCY`, or `STUCK`.

## Reports arrive by file, not by message

Every captain writes its terminal report to
`.../[run-id]/reports/[mission]-report.md` before ending its turn — **that file,
not any chat reply, `SendMessage`, or task-notification, is the authoritative
record.** Message-passing can silently drop; treat any inbound message or nudge
as "go check now," never as the report itself (see [[athena:fleet-liveness]]).

**Listen with a background watcher, and treat it as a fast path, not the only
path.** Once per run, right after your first dispatch batch, start a single
`Monitor` (`persistent: true`) on
`~/dev/custom/ai/bin/admiral-report-watch [run-id]` instead of hand-polling.
That script emits one line per new/updated report file and forces one staleness
heartbeat roughly every 45 minutes even when nothing changes — the heartbeat is
what makes the staleness rule actually fire on a quiet run. Run it **only** under
`Monitor`, never via a bare `Bash` call — its poll loop is the harness-wakeup
path, not a hand-rolled shell spin. When notified — by a report line or the
heartbeat — do a full sweep, not just a check of whatever the notification
mentioned.

Before re-dispatching or "waking" a captain, **read its report file first** — if
a fresh terminal report is already there, it needs reading and acting on, not
waking. Only re-dispatch if the file is missing/stale *and* `ListAgents` shows
it's gone. If one tells you it already reported, your monitor missed the file —
check directly, don't ask it to redo anything. After any interruption to your
own turn, confirm the `Monitor` is still running before trusting its silence.

**A report that accumulated rounds has a head that can be older than its body.**
When a Mission runs several passes into one report file, take the terminal facts
— status, head SHA, what actually landed — from the **newest dated section**, and
never from the top-line summary when the two disagree. The file's mtime is fresh
either way, so nothing in its shape warns you. And when they do disagree, treat
it as a defect in that file rather than reading around it silently: say so in
your state log, and make reconciling the head part of the next dispatch into it
(see [[athena:dispatch-captain]]). Measured 2026-09-20 (`notif-platform`):
`dnd-232-report.md` opened `Status: DONE` / `Final commit: ace49df` for twenty
rounds while its body ended at `78d5be9`, past a full re-spec — an admiral that
boarded on the head would have merged a twelve-round-old SHA.

## Each return frees a slot

`DONE`, `BLOCKED_ON_DEPENDENCY`, and `STUCK` each free a concurrency slot —
**immediately dispatch the next `QUEUED` Mission, if any** (via
[[athena:dispatch-captain]]).

**"Record it in your state log" means BOTH surfaces, and the row is the one
that goes stale.** The state log is a `## Mission state` table plus a `## Log`
below it ([[athena:fleet-liveness]] → *The state log has TWO surfaces*), so
every instruction below that says "state log" is an instruction to do two
things: **overwrite the Mission's row** — status token, worktree, branch, MR,
head SHA — and **append the narrative** to the log. Appending only to the log
satisfies the sentence while leaving the row exactly as the dispatch plan wrote
it, and nothing about a busy, current, honest log warns you the table beneath
it is describing a different world.

Treat the row update as part of *handling* the return, not as bookkeeping to
catch up on later — every trigger that moves a Mission (boarded, DONE, blocked,
parked, re-scoped, cancelled) moves its row in the same breath, and re-sends
the run's scope to the fleet registry ([[athena:fleet-liveness]] → *Fleet
registry reports*). The reason is
resume: [[athena:admiral-resume]] reads the state log FIRST and does not
re-triage from Notion, and it is the row it reads off. Measured 2026-09-20
`notif-platform`: DND-245 and DND-246 sat at `UNSTARTED` with empty
Worktree/Branch/MR cells while the log below recorded both boarded, both
reporting DONE with committed branches, DND-245 critic-BLOCKed, parked, and
finally **Cancelled** — a resume would have read `UNSTARTED` and re-dispatched a
captain onto a cancelled ticket, abandoning two committed, unpushed branches.
Same run, the DND-232 row's status token read `ROUTER_R22_KIND1` four rounds
after round 26.

- **DONE**: the captain already opened its MR, drove the pipeline green,
  addressed reviewer/bot feedback, and moved the Mission to `In Review` itself —
  it's not yours to do (unless this run has no `In Review`-equivalent, in which
  case you told it to set no status and the Mission is still yours at
  `In Progress`). Sanity-check the report before trusting it: confirm the MR URL
  is real and its latest pipeline is green (`glab mr view` / `glab ci status`),
  rather than re-running verification yourself. Record the MR URL and branch in
  your state log, then check whether any other worktree needs this branch's work
  (propagation, below). Merging is not part of DONE — board and merge per
  [[athena:merge-boarding]].
- **BLOCKED_ON_DEPENDENCY**: the report tells you whether the dependency maps to
  an existing Mission or needs a new one.
  - Existing Mission → mark the dependency relationship in Notion; if that
    Mission is itself unblocked, spin it up.
  - No Mission → create one in Notion with the dependency's scope as reported,
    mark the relationship, spin it up.
  - Move the blocked Mission to `Blocked` in your state log; it doesn't get
    redispatched until its dependency reports `DONE` and that work is
    incorporated into its worktree (propagation, below) — then move it back to
    `In Progress`.
- **STUCK**: read exactly what failed and what was tried. Retry once with any
  extra context you can supply, or mark it `Stuck` and move on — don't let one
  stuck Mission stall the rest of the run. Report it either way.

**Whenever you PARK a Mission rather than retrying it** — `STUCK` and left
stuck, `BLOCKED_ON_DEPENDENCY` with no near-term unblock, or cancelled — tear
its docker-compose stack down at that moment per
[[athena:teardown-worktree-stack]], keeping its worktree and branch untouched. A
parked Mission never reaches the merge that the usual teardown gate waits for,
so skipping this leaks a stack for the rest of the run.

## Propagate finished dependency work

When branch A (a dependency) finishes and branch B depends on it: **merge or
rebase A's branch into B's worktree** before B's captain continues (or starts).
This is your job, not theirs — they don't reach across worktrees. Do it every
time a dependency resolves, not just at the end.

If B's captain has already opened its MR against a placeholder target by the time
A merges, **retarget B's MR yourself** — `glab mr update --target-branch`;
GitHub: `gh-athena pr edit <n> --base` (an attributed write, so through the
wrapper). B's captain has likely already finished and terminated by then, so
this is yours to do, not a redispatch. **Never rewrite the captain's work** —
propagation is a git operation on that worktree, not a rewrite.

When you need to confirm an MR/PR **actually merged** (before a dependent's
terminal move, a DM, or a teardown), use `ai/bin/confirm-merged` with the forge
probe — **`--pr <n>` (GitHub) / `--mr <n>` (GitLab)**. A git-ancestry probe
(`--sha/--target`) is a supplementary check only, **never the sole probe**: a
squash merge is not a git ancestor of the target, so ancestry alone reports a
real merge as not-landed. The full merge/confirm discipline lives in
[[athena:merge-boarding]].

---

*Source (behavior-preserving relocation): athena-admiral §5 "Handle what comes
back from an athena-captain" + §6 "Propagate finished dependency work". The
admiral keeps a resident one-line trigger pointing here.*
