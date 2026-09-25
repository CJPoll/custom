---
name: athena:dispatch-captain
description: The checklist for building an athena-captain's dispatch brief — everything the brief must carry so a captain never has to ask (worktree path, Mission, domain context, reports-dir path, MR target branch, the admiral's own agentId as reply-to, the Notion status values, and the fleet-mode design sub-docs). Use each time you dispatch a captain into a prepared worktree. Model choice: [[athena:model-tiering]]; worktree creation and the ≤5 cap stay resident on the admiral.
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

## A `CONTENTION:` line lowers the cap for the rest of the run

Captains run heavyweight per-worktree stacks, and several full suites at once
can starve the box, so a Mission's verification fails for a reason that is the
FLEET's doing and no single captain's to avoid. A captain that suspects this is
required to attach a `~/dev/custom/ai/bin/contention-census` reading from the
failure and from the re-run, as a `CONTENTION:` line in its report.

**Treat that line as the feedback signal on your own concurrency:** the first
`CONTENTION:` line from a Mission in a given repo lowers your effective cap for
that repo **by one** for the remainder of the run — once per report, never more
than once for the same report. It only ever moves DOWN, and the resident `≤5,
ever` invariant is untouched; this can only tighten it.

Two things this deliberately is **not**:

- **Not a probe.** Do not sample the box's load at dispatch time and pick a cap
  from it. Load now says nothing about load forty minutes later when three
  suites collide — that is a guess wearing a measurement's clothes. React to a
  measurement a captain actually took, or to a number the repo declares.
- **Not a tolerance.** The red still blocks, the finding is still reported, and
  nothing is retried, skipped, or loosened — the standing rule is that a safety
  check gets FASTER, never weaker, and you carry it resident. The census
  makes contention *attributable*; it never makes a failure acceptable.

**Record the cap and where it came from** in the state log — `cap 3 — default`,
or `cap 2 — lowered by DND-213 CONTENTION`. Without the provenance, a cap you
chose and a cap that was forced on you read identically on resume, which is the
same failed-lookup trap one level up.

---

*Source (behavior-preserving relocation): athena-admiral §4 "Create worktrees
and dispatch work" (the dispatch-brief checklist). The worktree-creation rule
and the ≤5 concurrency cap stay resident on the admiral; this skill is the brief
contents. The admiral keeps a resident one-line trigger pointing here.*
