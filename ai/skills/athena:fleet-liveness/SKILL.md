---
name: athena:fleet-liveness
description: How an athena-admiral judges whether its captains are alive and its Missions progressing WITHOUT relying on notifications (which drop) or on ListAgents (usually absent) — the full-sweep-on-every-trigger rule, the hard staleness rule, the disk-evidence ladder, and counting the concurrency cap from the state log. Use whenever anything wakes you, and whenever deciding if a quiet Mission is still working.
---

# athena:fleet-liveness

Notifications are a latency optimization, never proof; `ListAgents` is usually
absent. Liveness is judged from what a captain leaves **on disk**.

## Notifications can be dropped — don't rely on any single one

This has happened in production: a captain finished a Mission completely (commits
present, report file written correctly), and no completion notification for it
ever arrived — not the harness's own task-notification, and not (per the same
mechanism) necessarily your `Monitor` watcher's either. The leading explanation:
a notification is injected between turns, and if a message reaches you
**mid-turn** at the same moment a notification would land, the notification can
be swallowed and never re-queued. This applies to *any* injected event,
including `Monitor` — treat every notification channel as a latency
optimization, never the sole proof that nothing happened.

Two defenses, both required:

- **Full sweep on every trigger, not just the Mission implicated.** Whenever
  anything wakes you — a `Monitor` event, a user message, a nudge, anything —
  reconcile the *whole* fleet: check the reports directory listing and every
  `IN_PROGRESS` Mission's worktree, not only the one you were pinged about. A
  dropped notification for Mission B doesn't announce itself; the only way to
  catch it is to look at B too, every time you look at anything.
- **A hard staleness rule, independent of any push.** For every `IN_PROGRESS`
  Mission, track last-known-activity in your state log (most recent report-file
  mtime, or most recent commit timestamp in its worktree —
  `git log -1 --format=%ct`). If a Mission has had neither a fresh report nor a
  fresh commit for roughly **45–60 minutes**, treat it as suspicious *before*
  assuming it's still working: check `ListAgents` liveness and read the worktree
  directly (`git log`, `git status`) rather than waiting for a notification that
  may never come. The `Monitor` watcher's periodic heartbeat exists so this
  check fires even during a long quiet stretch with zero file changes.
- If your own slot bookkeeping says the fleet is at the concurrency cap but you
  haven't seen a completion in a while, don't trust the bookkeeping — verify
  with `ListAgents` which slots are actually still alive before concluding
  you're genuinely full.

## Judging liveness when `ListAgents` is absent

**Assume you will not have it.** Every citation of `ListAgents` is conditional:
in most runs an admiral has no agent directory at all, because an admiral is
itself a subagent. Its absence is not a blocker, not an incident, and never a
reason to skip a sweep — it is the normal case, and the substitute is stronger
evidence anyway.

Judge a Mission's captain by what it leaves on disk, in this order:

1. **Its report file** (`.../[run-id]/reports/[mission]-report.md`). A fresh
   terminal report means the Mission is done, whatever any directory says.
2. **Worktree activity** — `git -C <worktree> log -1 --format=%ct` and
   `git status --porcelain`. A fresh commit cannot be faked, and an agent can be
   alive and stuck, so this outranks a liveness flag even when you have one.
3. **Harness task-notifications**, as a latency optimization only (above).
4. **Process inspection**, last resort: tie a process to a worktree by reading
   `/proc/<pid>/cwd`. Never `pkill -f`.

Two consequences:

- **Count the concurrency cap from your own state log, not the directory.** You
  recorded every Mission you dispatched and every one whose terminal report you
  processed; the difference is your live count. Reconcile it against worktree
  activity on every sweep, and settle any doubt about a slot by reading that
  Mission's worktree — never by trusting the bookkeeping you already doubt.
- **The Missions table is KEYED BY MISSION: one row per Mission, amended in
  place.** Counting a cap, and resuming, both assume a Mission's status can be
  read off exactly one row. Never append a second row for a Mission already in
  the table — update the existing one. A leftover planning row saying
  `UNSTARTED` standing beside a later row saying `DONE` is not a history; it is
  two contradictory answers to one lookup, with nothing to tell the stale one
  from the live one. It inflates the live count, and on resume — where you are
  told to read the state log FIRST and not re-triage from Notion — it reads as a
  Mission that was never dispatched, so the fix it invites is re-dispatching a
  captain onto work that already merged. Keep the history in the append-only log
  below the table — never in a second row, and never accreted inside the row.
  - Measured 2026-09-19-slack-gensaas: the table carried SIX duplicated keys
    (DND-201/210/211/213/221/223), each with its original `UNSTARTED`
    dispatch-plan row still standing beside a `DONE/MERGED` row, plus a
    hand-written `DND-221dup` placeholder row — the admiral noticed the
    collision and, having no rule to apply, annotated the duplicate instead of
    resolving it.

  **Later (2026-09-20):** the bullet's closing sentence previously read "Keep the
  history in the row's Notes column or in prose below the table, never in a
  second row." The Notes-column option is withdrawn, because it licensed exactly
  the accretion the next bullet measures. History goes below the table; the row
  carries current state only.
- **One row is not enough — the row must give ONE answer per field.** The rule
  above governs row *count*; this is the same defect one level in. A Mission's
  **current-state fields** — its status token, the SHA it sits at, the SHA `main`
  was at, its MR state — are **overwritten** on every update. Appending a fresh
  claim beside the old one puts two answers to one lookup inside a single cell:
  the duplicate-row failure again, hidden where no count of rows can find it, and
  with no ordering convention to rescue you — a reader cannot tell which claim is
  current, and last-wins is not a safe default. Narrative (what happened, why,
  what was decided) goes in the append-only log below the table, where accretion
  is the point.
  - Measured 2026-09-20-notif-platform: the DND-232 row's Notes cell reached
    **15,103 characters** and asserted two present-tense positions at once —
    `HOLDING at 404b4f2b — nothing landed, main @e7aaee36` and `HOLDING at
    a90efed8 — nothing landed, main clean @d6fe177` — with the **stale** one
    written **last** (`d6fe177` is an ancestor of `e7aaee36`), so reading
    top-to-bottom hands you the wrong head. Its status token still read
    `ROUTER_R22_KIND1` while the cell's own body described round-26 findings,
    four rounds on. Meanwhile the log below the table took no entry after round
    22: rounds 23–26 survive only as report files and as prose stuffed into this
    cell. An earlier run of the same fleet had already mis-read this cell once,
    at half the size.
- **Sweep a quiet Mission; never trust its silence.** With no directory, silence
  carries no information whatsoever, so the staleness rule above is the only
  thing between you and a dead captain. Apply it to every `IN_PROGRESS` Mission
  on every trigger.

*Ten runs re-derived this same ladder from scratch rather than being told it:
2026-08-25 canvas-integration and brevo-fub, 2026-08-27 workflow-builder and
phase2-backlog, the 2026-09-08/09/10 flaky-lane runs, 2026-09-09 ecs-build,
2026-09-10 graphql-feature, and 2026-09-18 athena-inbox.*

---

*Source (behavior-preserving relocation): athena-admiral §3b "Notifications can
be dropped" + §3c "Judging liveness when ListAgents is absent". The admiral
keeps a resident one-line trigger pointing here.*
