---
name: athena:dispatch-captain
description: The checklist for building an athena-captain's dispatch brief — everything the brief must carry so a captain never has to ask (worktree path, Mission, domain context, reports-dir path, MR target branch, the admiral's own agentId as reply-to, the Notion status values, and the fleet-mode design sub-docs). Use each time you dispatch a captain into a prepared worktree. Model choice: [[athena:model-tiering]]; worktree creation and the ≤5 cap stay resident on the admiral. Also the machine-capacity gate every dispatch passes (1-min load threshold, test-slot, lowering the cap on a load-based failure).
---

# athena:dispatch-captain

Front-load context generously — there's no one for a captain to ask later. Once
a Mission is unblocked and has a free slot (worktree already created via
`~/dev/custom/scripts/wt-preflight <branch> <repo>`, `PREFLIGHT OK` seen; cap
≤5 enforced by the admiral):

0. **Run the control checkpoint first:** `~/dev/custom/ai/bin/fleet-control check`.
   Exit 0 dispatches. Exit 3, or any other exit, dispatches nothing. If the
   spawn itself comes back refused with `is draining` (the drain guard hook),
   that is **PAUSE**: mark the Mission `PARKED`, never retry the spawn, and never
   do the captain's work in-line. Then run the drain protocol:
   [[athena:fleet-drain]].
   Exit 0 then passes the **machine-capacity gate** (*Machine capacity gates
   every dispatch*, below) before the spawn.
1. **Move the Mission's Notion status to `In Progress`** and set its `Assignee`
   to **Athena** (the active connection's bot — see [[athena:ticket-management]]).
2. **Dispatch an athena-captain, named uniquely and Mission-qualified** (e.g.
   `athena-captain-PT-398`) — never the bare role name. Several run
   concurrently; `ListAgents` can't disambiguate identical bare names, and a
   report aimed at one can silently misroute.

Give the captain, in the brief:

- **The worktree path.**
- **The Mission.**
- **Domain context** — prior decisions, related Missions, pointers into the
  codebase — **but NOT the architect's raw domain model**; the captain grounds
  in the Notion design sub-docs (below).
- **The absolute reports-directory path** for this run.
- **If this Mission's report file already exists** — a fix round, a re-dispatch,
  a second worker on the same Mission — say that the worker **owns the whole
  file, not just the section it appends**: its pass must leave the top-line
  status, the summary, and any head-SHA / "final commit" field describing **its**
  pass. A worker that appends a round and leaves the head alone produces a file
  whose opening lines contradict its own body, and the head is what a resumed
  reader greps first. Measured 2026-09-20 (`notif-platform`):
  `dnd-232-report.md` still opened "**Status: DONE.** Eight critic rounds
  resolved" with `Final commit: ace49df` while its body ran to round 20 at
  `78d5be9` — twelve rounds and a whole re-spec later, across three separate
  appending passes that each left the head untouched. A stale head SHA in a
  report is the failed-lookup class: it reads exactly like a working answer.
- **The MR target branch** (from your dependency map — the repo's default branch
  if this Mission has no unmerged dependency, otherwise the dependency's branch).
- **Your own `agentId` as the explicit reply-to.** A captain never told who
  dispatched it addresses its terminal report to the main session, which then
  has to relay it by hand (measured 2026-09-18: four captains in one run
  misrouted to the main session; the fix would otherwise have died with the run).
  The captain definition tells it to message "your athena-admiral by its agentId
  (it is in your brief)" — the bare role name bounces — so the brief is the only
  place that `agentId` can come from. Carry it next to the reports-directory
  path, and keep the precedence straight: **the file write is the delivery**, the
  message is the latency optimization (see [[athena:fleet-liveness]]).

  **You cannot look your own `agentId` up — it has to be given to you.**
  `ListAgents` reports the agents you can *send to* and says outright that the
  calling process "is not listed below"; there is no self-id anywhere in its
  output, and from inside your own process the only address you have is the
  bare word `main` for whoever spawned you. Your `agentId` exists in exactly one
  place: the **`Agent` tool result your dispatcher received when it spawned
  you**. So obtain it from your dispatcher — `SendMessage` to `main` asking for
  your own `agentId` — and do it **before your first captain dispatch**, not
  after a captain has already misrouted. Send the request and carry on preparing
  worktrees while you wait; never park a turn on it.

  **If you do not have it yet, say so in the brief — never omit the line.** A
  brief silently missing its reply-to is the case that misroutes; a brief
  saying *"no reply-to is available: write your report file and do not message
  anyone"* costs only the latency optimization, which was never the delivery.
  Fill the reply-to in on every brief from the moment your dispatcher answers.

  This is the *how* the rule above always assumed and never stated. Measured
  twice: 2026-09-18, four captains in one run addressed the main session; then
  again on 2026-09-20 `notif-platform` — *after* the requirement was already
  written here — where the state log records "reply-to misrouted to coordinator
  **again**" and the run was only repaired when the **coordinator supplied this
  admiral's `agentId`**, which is the one route the admiral could not take for
  itself. An instruction to carry a value nobody tells you how to get is the
  repo's *A claimed mechanism must be able to fire* class.
- **The Notion status values it needs** — specifically `In Review`, which it
  sets itself once its MR is open. Where the tracker has no `In Review`-
  equivalent, the brief must say **"set NO Notion status at all"**, never a value
  the DB cannot accept (see the substitution in [[athena:fleet-inputs]]).

- **The forge-identity rule, cited by name.** Every brief carries this line:
  *"Forge writes and pushes run as Athena: follow *Pushing as Athena* in
  **athena:github** (github.com) or **athena:gitlab** (gitlab.com) for every
  push, and **athena:github** → *When a forge
  write can't be done as Athena* when any forge operation can't run under the
  Athena identity; escalate to me, the admiral."* Cite it; do not restate the
  rule in the brief. A captain
  that pushes with a plain `git push` puts the owner's name on its work
  (measured 2026-09-23, every gen_saas branch push).

- **The bug-fix regression rule, cited by name.** Every brief carries this line,
  bug Mission or not, since any Mission can end up fixing a defect: *"Any bug
  fix follows the regression-test rule in `~/dev/custom/ai/CLAUDE.md` → *TDD
  Workflow*: record the test failing on the unfixed code, then passing, and put
  that evidence where the rule says."* Cite it; do not restate it. The standing
  judge blocks a fix commit without the evidence, so a captain who learns the
  rule from the critic pays a whole review round for it.

- **The findings rule, cited by name.** Every brief carries this line: *"An
  anomaly you find outside this Mission follows `~/dev/custom/ai/CLAUDE.md` →
  *Find it, ticket it, fix it, verify it live*: list it in your report as a
  proposed ticket with a priority; do not fix it in this MR."* Cite it; do not
  restate it.

- **The no-stash rule.** Every brief carries this line: *"Never `git stash`. To
  park WIP, commit it to your worktree branch."* A linked worktree shares ONE
  stash list with the owner's main checkout (`refs/stash` lives in the common
  git dir), so a captain's `git stash pop` can pop the owner's entry. Measured
  2026-09-25 on walt_ui: the PT-1709 captain popped the owner's PT-822 entry
  (DND-670). The `git-stash-guard` hook denies every stash write; the line saves
  the captain the denied call.
- **The test-slot rule.** Every brief carries this line: *"Run every heavy gate
  — a full suite, `bin/prep-commit.sh`, `harness-gate`, `integration-gate` — as
  `~/dev/custom/ai/bin/test-slot -- <cmd>`. Exit 75 with `test-slot: TIMEOUT`
  means it never ran: run it again; never count it as a pass."* Nothing in the
  harness wraps a captain's gates yet (DND-486 is unlanded), so this line is
  the only thing that does.

**In fleet mode, also point it at the design in Notion** — its ticket page's
three sub-docs (**Product Requirements / Architecture & Engineering / QA Plan**)
AND the epic's three, which it reads for full context — as the design it
implements to. Tell it to run its Pass-2 review of that design against current
system reality and to raise any gap it finds **to you** (in its report),
non-blocking: it proceeds on best judgment while you carry the substantive gaps
to the architect. **Do NOT tell it to message the architect directly.**

**Pick the captain's model from the Mission's real complexity** — read the
Mission and the code it names, not its label. The captain defaults to
`model: claude-opus-4-8`; override to `model: "sonnet"` on the `Agent` call **only** for
bounded, fully-specified, tool-checkable work. Invoke [[athena:model-tiering]]
for the Sonnet-when-*all* / Opus-when-*any* criteria, the worked examples, and
the first-of-a-series rule. **Default to Opus whenever unsure** — a Sonnet
captain that goes STUCK is re-dispatched once under Opus into the same worktree,
which costs more than the tokens Sonnet saved — and **write the choice and its
one-line reason into the state log** next to the dispatch.

Every environment fact you put in the brief must be VERIFIED, not inferred —
see [[athena:brief-verification]].

## Machine capacity gates every dispatch

**Later (2026-09-26):** this section was *A `CONTENTION:` line lowers the cap
for the rest of the run*. Its *Not a probe* bullet forbade sampling load at
dispatch time, and a `CONTENTION:` line lowered one repo's cap. Superseded by
owner directive (Cody, 2026-09-26 ~14:15Z): "You have as many captain slots as
are enabled by the hardware (if you see load-based failures, lower the number of
captains)." The same directive gave a second machine its own pool. A load
reading now gates each dispatch but never picks a count, and a load-based
failure lowers the whole cap, because load is the machine's.

Captain capacity belongs to the machine. The resident cap of 5 is your ceiling;
below it, these rules decide.

- **Hold while the machine is loaded.** Immediately before each spawn (initial,
  refill, resume re-dispatch), after `fleet-control check` exits 0, read the
  1-min load: `cut -d' ' -f1 /proc/loadavg`. Over **12** (owner, 2026-09-26):
  do not dispatch. Keep the Mission `QUEUED`, log `Load <value> -> holding`, and
  re-read on your next sweep. At or under 12, dispatch and log `Load <value>` on
  the dispatch line. A load you cannot read is not load 0: hold, and tell the
  session that launched you.
- **A gate, not a count.** A reading clears ONE dispatch. Never turn it into a
  number of slots ("load 3, so dispatch four"). Load now says nothing about load
  forty minutes later, when several captains reach their suites at once. The
  reading does not cover that gap. Three things do: the cap of 5 bounds any
  burst, heavy runs queue through `test-slot` instead of colliding, and a
  load-based failure lowers the cap.
- **Heavy gates go through `test-slot`.** Wrap your own (`integration-gate`,
  `harness-gate`, a full suite) as `~/dev/custom/ai/bin/test-slot -- <cmd>`,
  always the main checkout's copy, so every fleet shares one pool. Give every
  captain the test-slot brief line. Exit 75 with `test-slot: TIMEOUT` means the
  command never ran.
- **A load-based failure lowers your cap by one** for the rest of the run, and
  you tell the session that launched you (it apportions the machine across
  admirals). Load-based failures: a captain's `CONTENTION:` line (captains
  attach a `~/dev/custom/ai/bin/contention-census` reading from the failure and
  the re-run), or a gate of yours that fails with Postgres `57014`, a timeout
  under load, or a kill, with a census reading taken at the failure. One
  lowering per report or failure. The cap only moves down; a new brief from the
  launching session is how it comes back up.
- **The pool is per machine.** Another machine may have its own pool (a captain
  count its admirals share) or its own threshold. The launching session
  apportions it, and the share your brief names is your cap, as a lane brief's
  `{{MAX_CAPTAINS}}` is. With no share in your brief, 5 and 12 apply.
- **Not a tolerance.** The red still blocks, the finding is still reported, and
  nothing is retried, skipped, or loosened — the standing rule is that a safety
  check gets FASTER, never weaker, and you carry it resident. The census
  makes contention *attributable*; it never makes a failure acceptable.

**Record the cap and where it came from** in the state log — `cap 5 — default`,
`cap 4 — brief share`, or `cap 3 — lowered by DND-213 CONTENTION` — with the
load reading on every dispatch line. Without the provenance, a cap you
chose and a cap that was forced on you read identically on resume, which is the
same failed-lookup trap one level up.

---

*Source (behavior-preserving relocation): athena-admiral §4 "Create worktrees
and dispatch work" (the dispatch-brief checklist). The worktree-creation rule
and the ≤5 concurrency cap stay resident on the admiral; this skill is the brief
contents. The admiral keeps a resident one-line trigger pointing here.*
