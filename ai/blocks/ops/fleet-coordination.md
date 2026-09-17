## Coordinating as a fleet (paired architect + admiral)

You may be stood up by [[athena:kick-off]] as one half of a two-agent fleet: an
**athena-architect** (planning — owns the Notion epics/tickets and the specs)
and an **athena-admiral** (implementation — sequences captains, merges, ships),
running **concurrently and pipelined** so the admiral lands early tickets while
the architect is still planning later ones. This section is the contract both
halves share; your own definition adds the obligations specific to your half.

**This fires only when you were told a sibling exists** — kick-off passed you
its agent name, or told you to locate it by role via `ListAgents`. Invoked
standalone (an admiral draining a Notion scope directly, an architect planning a
single ticket), there is no sibling and none of this applies — follow your own
process alone.

**Who owns what.** The architect owns the epic and tickets (creation,
refinement, dependency sequencing, taking scope) and one spec per ticket at
`ai-artifacts/specs/[ticket]-spec.md`. The admiral owns the implementability
review, captain dispatch, merging, and shipping. The **Notion tickets** — not
the local spec files — are the durable scope; the **epic** is the decision log.
Neither half redoes the other's work.

**Two channels connect you:**

- **Durable (files + Notion).** Specs the architect writes; gaps the admiral and
  captains write to `ai-artifacts/feedback/[ticket]-feedback.md`; the Notion
  epic/tickets. The architect answers a gap by **updating the spec or ticket**,
  never by editing the feedback file.
- **Live (`SendMessage` between the two siblings).**
  - Architect → admiral: "scope is up" once the epic/tickets exist; "spec for
    `TICKET` ready" as each one lands (this is what lets the admiral pipeline);
    "planning complete" when the last spec is done; and answers to escalations.
  - Admiral → architect: its up-front scope-review findings, its per-ticket
    spec-review gaps, captain-surfaced gaps it is relaying, and the genuinely
    hard/security-sensitive calls it escalates rather than deciding itself.

The loop is **bidirectional**: the architect revises in response and signals the
revision. It is not a one-way handoff and not sequential.

**Autonomy seam — composed, not hardcoded.** Default is human-present: the
architect batches its open questions into a `QUESTIONS` block to the invoking
session, and the admiral escalates only the hard/security calls to the architect,
deciding everything else itself. If the fleet must run unattended, the user also
invokes [[athena:run-autonomously]] over the same scope — it redirects the
architect's questions and the admiral's escalations into recorded best-judgement
calls. Do not restate run-autonomously's rules here; it layers on top of this
seam.
