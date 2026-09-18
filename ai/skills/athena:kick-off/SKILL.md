---
name: athena:kick-off
description: Turn a finished conversation about work-to-be-done or requirements into a running fleet — stand up an athena-architect (planning: it owns the Notion epics/tickets AND the design docs) and an athena-admiral (implementation), wired to coordinate live via a bidirectional review/feedback loop. Invoke (by user or model) at the seam between "we've agreed what to build" and "go build it," once requirements are settled enough to plan against.
---

# athena:kick-off

You have just had a conversation that established **what needs to be built** —
requirements, a feature, an epic's worth of work. This skill launches the fleet
that delivers it: one **athena-architect** (planning) and one **athena-admiral**
(implementation), running concurrently and coordinating through a live
bidirectional loop. You (the invoking session) are the launcher and the relay —
you spawn both agents, wire them to each other, and stay available to answer the
architect's questions unless autonomy is in scope (see below).

Do **not** do the planning or the implementation yourself. Your job is to hand
off cleanly and keep the two agents talking.

## Prerequisite: `athena:ticket-management` must be in scope

The architect turns the requirements conversation into **Notion epics and
tickets** — that ticket scope is the unit of work handed to the admiral, and the
epic is where autonomous decisions get recorded. So the tooling behind
[[athena:ticket-management]] (the active Notion connection, the target
Epics/Tickets DB, and the blocked/unblocked semantics) must be available.

Before spawning anything, confirm you can name:

- **Which Notion connection** is active (`notion-personal` vs `notion-work`) and
  the target **Epics/Tickets DB** the new tickets will live in.
- **How "blocked" is represented** for that DB (a relation like `Depends On` /
  `Blocked By`, or a status) — the admiral needs this to sequence.

If you cannot, say so and get it before proceeding — this is foundational, and a
wrong guess wastes the whole run. This is the "presumes ticket-management is in
scope, or says it needs to be" contract: state the gap rather than inventing a
DB or a semantics.

## The two roles and what each owns

- **athena-architect (planning).** Owns the Notion **epics/tickets** — it
  creates or refines them from the requirements conversation via
  [[athena:ticket-management]], sequences them with dependency edges, and takes
  scope (assign Athena; `Backlog`→`Todo`). It authors the **design docs in
  Notion** (never authoritative local files): for the epic, and for each ticket,
  three sub-pages — **Product Requirements**, **Architecture & Engineering**,
  **QA Plan**. To do this it first authors its own **domain model** as an
  athena:system-spec JSON document under `ai-artifacts/domain/` — its **private
  grounding context** (a schema-validated file on disk, never Notion), used
  solely so it grounds well enough to write the sub-docs. The domain model is
  NOT shared with the admiral or captain — they consume only the Notion
  sub-docs the architect derived from it.
  The **Notion epic/tickets are the durable scope** handed to the admiral.
- **athena-admiral (implementation).** Consumes that scope, runs the plan-time
  scope review with the architect (Pass 1, below), then drives the fleet of
  captains, merges, and ships. It never writes production code and never plans —
  it sequences and lands.

## Coordination contract (the bidirectional loop)

Both agent definitions already carry this contract — each its own half — via the
shared `ops/fleet-coordination` doctrine baked into them. So your job is to
**launch, pair, and relay**, not to re-teach the protocol; the summary here is
what you need to wire them correctly and to answer the architect's questions.

The two run **concurrently and pipelined** — the admiral starts landing early
tickets while the architect is still planning later ones — and coordinate over
two channels:

**Durable channel — Notion is the source of truth:**
- Design docs: the architect writes the epic-wide and per-ticket **Product
  Requirements / Architecture & Engineering / QA Plan** Notion sub-pages. There
  are no authoritative local spec files; a captain reads BOTH its ticket's three
  sub-docs AND the epic's three.
- Feedback: a captain raises its findings **up to the admiral**, which carries
  them to the architect; the architect answers by **revising the Notion
  sub-doc/ticket**. Local `.md` is only ephemeral agent scratch.
- Notion epic/tickets: the shared scope and the decision log.

**Live channel (`SendMessage` between the two sibling agents):**
- Architect → admiral: "epic/tickets are up, here is the scope"; then "design
  for `TICKET` is ready" as each ticket's sub-docs land (this is what lets the
  admiral pipeline); finally "planning complete."
- Admiral → architect: its **Pass-1 scope-review** findings, the captains'
  **Pass-2** gaps it is relaying, and — when running autonomously — the genuinely
  hard/security-sensitive calls the admiral escalates rather than deciding
  itself.
- Architect → admiral: revised sub-docs / tickets in response, and answers to
  escalations.

### Two review points, two owners

1. **Pass 1 — plan time (admiral ↔ architect).** Before any captain is
   dispatched, the admiral collaborates with the architect over the whole scope
   and the mission inter-dependencies — the fleet-leadership review only the
   admiral can do (it alone sees every mission and its edges). Structural fixes
   are cheapest here, before implementation starts.
2. **Pass 2 — assignment/implementation time (the captain).** When a captain is
   dispatched to a ticket, IT reviews that ticket's design against **current
   system reality** (sibling missions merged, the tree drifted, hands on the
   code). It raises gaps up to the admiral and proceeds on best judgment — it
   does not stall. A ticket gets a captain only once its design docs are ready
   **and** its dependencies are merged.

## Steps

1. **Confirm the prerequisite** — the active Notion connection, target DB, and
   blocked semantics (above). Block and ask if unknown.
2. **Spawn the athena-architect** with: the requirements from this conversation,
   the Notion connection + target Epics/Tickets DB, and its mandate — own the
   epic/tickets in Notion, sequence them, and produce each ticket's design
   sub-docs (Product Requirements / Architecture & Engineering / QA Plan) in
   dependency order, signalling the admiral as each ticket's docs land.
3. **Spawn the athena-admiral** with: the same Notion connection + DB + blocked
   semantics (its required inputs), and its mandate — run the Pass-1 plan-time
   scope review with the architect first, then drive captains (each of which
   runs its own Pass-2 design review), merge, and ship.
4. **Wire their identities to each other.** After both are up, give the admiral
   the architect's agent name and the architect the admiral's agent name (relay
   the names, or tell each to locate the other by role via `ListAgents`) so they
   can `SendMessage` directly. Tell each it is running as a fleet half with the
   other as its sibling — both already carry the contract, so you confirm the
   pairing and pass the scope inputs rather than re-teaching the protocol.
5. **Relay and stay available.** Carry messages between them if the harness
   requires it, and answer the architect's `QUESTIONS` block yourself (unless
   autonomy is in scope). Do not declare the kick-off done until both agents are
   live, wired, and the architect has begun turning requirements into tickets.

## Autonomy: compose, don't hardcode

This skill is **agnostic** about whether a human is present. By default:
- the architect batches its open questions into a `QUESTIONS` block to **you**,
  the invoking session; and
- the admiral escalates only the genuinely hard/security-sensitive calls to the
  architect, deciding everything else itself.

If the user is stepping away and the fleet must run unattended, they **also**
invoke [[athena:run-autonomously]] over the same scope — that skill redirects the
architect's would-be questions and the admiral's escalations into best-judgement
calls recorded on the epic, and defines the "when the user returns" report. Do
not duplicate those rules here; kick-off just names the seam and lets
`run-autonomously` layer on top.
