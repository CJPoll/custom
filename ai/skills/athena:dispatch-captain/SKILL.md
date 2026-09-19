---
name: athena:dispatch-captain
description: The checklist for building an athena-captain's dispatch brief — everything the brief must carry so a captain never has to ask (worktree path, Mission, domain context, reports-dir path, MR target branch, the admiral's own agentId as reply-to, the Notion status values, and the fleet-mode design sub-docs). Use each time you dispatch a captain into a prepared worktree. Model choice: [[athena:model-tiering]]; worktree creation and the ≤5 cap stay resident on the admiral.
---

# athena:dispatch-captain

Front-load context generously — there's no one for a captain to ask later. Once
a Mission is unblocked and has a free slot (worktree already created via
`~/dev/custom/scripts/wt-preflight <branch> <repo>`, `PREFLIGHT OK` seen; cap
≤5 enforced by the admiral):

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
- **The Notion status values it needs** — specifically `In Review`, which it
  sets itself once its MR is open. Where the tracker has no `In Review`-
  equivalent, the brief must say **"set NO Notion status at all"**, never a value
  the DB cannot accept (see the substitution in [[athena:fleet-inputs]]).

**In fleet mode, also point it at the design in Notion** — its ticket page's
three sub-docs (**Product Requirements / Architecture & Engineering / QA Plan**)
AND the epic's three, which it reads for full context — as the design it
implements to. Tell it to run its Pass-2 review of that design against current
system reality and to raise any gap it finds **to you** (in its report),
non-blocking: it proceeds on best judgment while you carry the substantive gaps
to the architect. **Do NOT tell it to message the architect directly.**

**Pick the captain's model from the Mission's real complexity** — read the
Mission and the code it names, not its label. The captain defaults to
`model: opus`; override to `model: "sonnet"` on the `Agent` call **only** for
bounded, fully-specified, tool-checkable work. Invoke [[athena:model-tiering]]
for the Sonnet-when-*all* / Opus-when-*any* criteria, the worked examples, and
the first-of-a-series rule. **Default to Opus whenever unsure** — a Sonnet
captain that goes STUCK is re-dispatched once under Opus into the same worktree,
which costs more than the tokens Sonnet saved — and **write the choice and its
one-line reason into the state log** next to the dispatch.

Every environment fact you put in the brief must be VERIFIED, not inferred —
see [[athena:brief-verification]].

---

*Source (behavior-preserving relocation): athena-admiral §4 "Create worktrees
and dispatch work" (the dispatch-brief checklist). The worktree-creation rule
and the ≤5 concurrency cap stay resident on the admiral; this skill is the brief
contents. The admiral keeps a resident one-line trigger pointing here.*
