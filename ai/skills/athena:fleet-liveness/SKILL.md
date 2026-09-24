---
name: athena:fleet-liveness
description: How an athena-admiral judges whether its captains are alive and its Missions progressing WITHOUT relying on notifications (which drop) or on ListAgents (usually absent) — the full-sweep-on-every-trigger rule, the hard staleness rule, the disk-evidence ladder, and counting the concurrency cap from the state log — plus the run's fleet registry reports (admiral-start, admiral-scope on every Mission status change, admiral-state finished) via ai/bin/fleet-report. Use whenever anything wakes you, whenever deciding if a quiet Mission is still working, and whenever a Mission's status changes.
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

   **Probe it by LISTING the entries, never by counting `ls`.** Use
   `find "$DIR" -mindepth 1 -type f` (or `-newer` against a reference file) and
   read the names it prints. `ls -1 "$DIR" | wc -l` **reports 1 for an EMPTY
   directory on this machine**: `ls` is aliased to a long-format variant that
   emits a `total 0` header, so the count counts the header, not the files.
   Measured 2026-09-20-ai-lms (state.md:124-134) — it produced a false
   `reports: 1 file(s)` in a fleet sweep when **no captain report existed**,
   inside the admiral's own instrumentation. Nothing errored and the number was
   well-formed, so the sweep read a silent captain as a reporting one.

   This is the sibling of the `find -newermt` false-zero recorded in
   `athena-shipwright`: a count is a lookup, and a wrongly-computed count and a
   truthfully-empty one are the same integer. Names are self-checking —
   a header line does not look like a report filename — so **print what you
   found and act on the names**, and treat any count you did not see the
   entries behind as unverified.
2. **Worktree activity** — `git -C <worktree> log -1 --format=%ct` and
   `git status --porcelain`. A fresh commit cannot be faked, and an agent can be
   alive and stuck, so this outranks a liveness flag even when you have one.
3. **Harness task-notifications**, as a latency optimization only (above).
4. **The machine test-slot pool** (`~/dev/custom/ai/bin/test-slot --status`). A
   captain whose worktree is quiet but whose label is listed as a waiter or
   holder is queued or gating, not stalled. An UNSLOTTED line names a heavy run
   that bypassed the pool; tell its captain to wrap it. A CONTAINER line is a
   heavy run inside docker whose slot cannot be read; it is not evidence either
   way.
5. **Process inspection**, last resort: tie a process to a worktree by reading
   `/proc/<pid>/cwd`. Never `pkill -f`.

Two consequences:

- **Count the concurrency cap from your own state log, not the directory.** You
  recorded every Mission you dispatched and every one whose terminal report you
  processed; the difference is your live count. Reconcile it against worktree
  activity on every sweep, and settle any doubt about a slot by reading that
  Mission's worktree — never by trusting the bookkeeping you already doubt.
- **The state log has TWO surfaces; give it both.** A `## Mission state` table —
  one row per Mission, current state only — and below it a `## Log`, append-only,
  carrying the narrative: what was decided, why, and what happened. The table
  answers *where is this Mission now*; the log answers *how did it get here*.
  Every admiral so far has invented this shape unprompted, which is why it is
  written down rather than assumed: a run that quietly stops writing the log does
  not lose the narrative, it relocates it into the table, and the two rules below
  are what it then breaks.
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

## Fleet registry reports

The owner's fleet page shows every session, its admirals and their Missions.
Normative home: `ai/contracts/athena-events.md` → *Fleet registry and session
control*. Hooks already report the session and your own activity
(`admiral_seen`, keyed on your `agentId`). Three reports are yours, each one
call to `~/dev/custom/ai/bin/fleet-report`. It reads the session id from
`$CLAUDE_CODE_SESSION_ID`, so pass none.

- **Run start: `admiral-start --run-id <run-id> --agent-id <your agentId>`**
  (optional `--scope-label "<scope>"`). Send it once you hold both values: the
  run-id you picked, and the `agentId` you asked `main` for in your first turn.
  Until then the page shows you as `run unreported`, which is true.
- **Scope: `admiral-scope --run-id <run-id> --missions <file>`** right after
  `admiral-start`, and again after **every** Mission status change in your
  state log's `## Mission state` table. It replaces the list whole, so send
  every Mission each time. Send `[]` when the scope is empty: `no missions` is a
  reported fact, while never sending reads as `scope unreported`.
  - The file is `.../[run-id]/fleet-scope.json`: a JSON array with one object
    per Mission and **exactly** these fields: `tracker` (`notion-personal` or
    `notion-work`), `ticket_ref` (e.g. `DND-433`), `url`, `title`, `status`
    (the tracker's status), `captain_state`.
  - `captain_state` comes from the row: `UNSTARTED`/`QUEUED` → `queued`,
    `IN_PROGRESS` → `running`, a Mission you hold or parked → `parked`, `DONE`
    → `done`, `BLOCKED` → `blocked`, `STUCK` → `stuck`.
  - No other field. A body, summary, comment, label or assignee is refused
    before anything is sent (*Mission pointers are metadata only*).
  - **Add `--notion-project-id <id>`** when your scope has a Notion Project:
    the page id in the scope epic's `Project` relation (read it from the epic
    page's properties once, at run start). The server classifies your run's
    domain from it (an `Athena —` project is `blend`), so apps/athena work in
    gen_saas is not metered as the repo's `personal` default. Send it on every
    `admiral-scope`: each call replaces the last, and a call without it clears
    it. Omit it only when the scope has no Project.
- **Run end: `admiral-state --run-id <run-id> --state finished`**, only when
  the scope is exhausted ([[athena:admiral-final-report]]). A usage ceiling or
  an interruption sends nothing: the server reads the silence as `quiet`, then
  `lost`, which is the truth. `draining` and `drained` belong to the drain
  protocol (the contract's *Enforcement layers* → *Layer 3: the drain protocol*).

**A failed report never blocks the fleet.** Every failure prints one stderr
line with `Fix:`, and the exit code says which failure it was:

- `3`: the server refused. Its `Fix:` is printed; act on it.
- `4`: the server was unreachable.
- `5`: server fault.
- `1`: local configuration.
- `2`: usage.

Note the failure in your `## Log` and carry on. The reports are upserts, so the
next status change re-sends the whole scope. The hooks' own background reports
cannot print to anyone: their failures go to
`$XDG_STATE_HOME/athena/fleet/report-failures.log`, and the next session start
announces them in its context.

---

*Source (behavior-preserving relocation): athena-admiral §3b "Notifications can
be dropped" + §3c "Judging liveness when ListAgents is absent". The admiral
keeps a resident one-line trigger pointing here. *Fleet registry reports* is
new with DND-433; the admiral's run-id paragraph points here for it.*
