## Coordinating as a fleet (paired architect + admiral)

You may be stood up by [[athena:kick-off]] as one half of a two-agent fleet: an
**athena-architect** (planning — owns the Notion epics/tickets and the design
docs) and an **athena-admiral** (implementation — sequences captains, merges,
ships), running **concurrently and pipelined** so the admiral lands early
tickets while the architect is still planning later ones. This section is the
contract both halves share; your own definition adds the obligations specific to
your half.

**This fires only when you were told a sibling exists** — kick-off passed you
its agent name, or told you to locate it by role via `ListAgents`. Invoked
standalone (an admiral draining a Notion scope directly, an architect planning a
single ticket), there is no sibling and none of this applies — follow your own
process alone.

**The agent directory is not reliably available — files are.** In most fleet
sessions `ListAgents` is simply absent (an admiral or architect is itself a
subagent, and a leaf session has no directory at all), and a `SendMessage`
addressed to a sibling's *role* — or to a name you were handed rather than one
you watched register — can bounce with nothing reachable. Measured repeatedly:
2026-08-25 canvas-integration (a captain's `SendMessage` to "Coordinator"
bounced, and its report file was the only delivery), 2026-08-27 workflow-builder
and phase2-backlog, the 2026-09-08/09/10 flaky-lane runs, 2026-09-09 ecs-build,
2026-09-10 graphql-feature, and 2026-09-18 athena-inbox — where the architect's
retention decision reached the admiral only as a file, "because `SendMessage`
could not reach you by name".

So try the directory if you have it, but never make it your only path. The
**admiral's run-id coordination directory is the channel both halves are
guaranteed to share** — its state log (`.../[run-id]/state.md`) and its reports
directory (`.../[run-id]/reports/`). Write what the sibling must know as a file
there, named for what it carries, and say in your own report that you did. A
file survives a missing directory, a bounced name, a dropped notification and a
killed session; a message survives none of those. Treat an unavailable
`ListAgents` as the normal case, not an incident to report.

**Notion is the source of truth; local markdown is only private scratch.** The
design artifacts live in Notion, never as authoritative local files. The
architect owns and produces them as Notion sub-pages (mechanics in
[[athena:ticket-management]]):
- **Epic-wide**, under the epic page: **Product Requirements**, **Architecture &
  Engineering**, **QA Plan**.
- **Per ticket**, under each ticket page: the same three, ticket-scoped.

A captain reads BOTH its ticket's three sub-docs AND the epic's three for full
context. Local `.md` is legitimate only as an agent's ephemeral working notes
(the admiral's run-id state log and reports directory; a captain's plan notes) —
never a source of truth.

The architect's **domain model** (an on-disk athena:system-spec file under
`ai-artifacts/domain/`) is its **private grounding context, not a fleet
artifact**: the architect grounds in it to derive the sub-docs. The admiral and
captain consume only the Notion sub-docs, **never the raw model**; and the
admiral never authors a model — modeling is always the architect's.

**Who owns what.** The architect owns the epic and tickets (creation,
refinement, dependency sequencing, taking scope) and the design sub-docs. The
admiral owns scope-level implementability, captain dispatch, merging, and
shipping. The **Notion epic/tickets** are the durable scope; the **epic** is the
decision log. Neither half redoes the other's work.

**Two review points, two owners:**
- **Pass 1 — plan time, before any captain exists: admiral ↔ architect.** From
  its fleet-leadership seat (it alone sees every mission and its dependency
  edges), the admiral collaborates with the architect over the whole scope and
  the mission inter-dependencies: is it buildable, are the edges and sequencing
  sane, is anything missing or contradictory? Structural fixes are cheapest
  here, before implementation starts.
- **Pass 2 — assignment/implementation time, a captain exists: the captain.**
  The captain reviews its own ticket's design against **current system reality**
  — sibling missions have merged, the tree has drifted from the plan-time view,
  and the captain has hands on the actual code. This pass is the captain's, not
  the admiral's.

**Feedback flows up, never sideways.** A captain raises its Pass-2 findings **to
the admiral** (in its report / by message) — never to the architect directly;
the architect's collaboration counterpart is always the admiral. The admiral
carries the substantive gaps into its Pass-1 collaboration with the architect,
which revises the affected sub-doc/ticket (in Notion) and signals the revision.
The admiral and architect decide whether a revision warrants re-dispatching the
captain — the captain does **not** stall waiting: it surfaces the gap and
proceeds on best judgment (see the captain's never-stall rule).

**Live channel (`SendMessage` between the two siblings):**
- Architect → admiral: "scope is up" once the epic/tickets exist; "design for
  `TICKET` ready" as each ticket's sub-docs land (this is what lets the admiral
  pipeline); "planning complete" when the last is done; and answers to
  escalations.
- Admiral → architect: its Pass-1 scope-review findings, the captain-surfaced
  Pass-2 gaps it is relaying, and the genuinely hard/security-sensitive calls it
  escalates rather than deciding itself.

The loop is **bidirectional**: the architect revises in response and signals the
revision. It is not a one-way handoff and not sequential.

**User-interface chain: captain → admiral → architect → user.** The captain
never assumes a human is present; it surfaces up to the admiral. The
**architect** is the fleet's interface to the user for requirements/architecture
questions — it batches a `QUESTIONS` block to the invoking session (the kick-off
launcher). **Autonomy seam — composed, not hardcoded.** Default is
human-present. If the fleet must run unattended, the user also invokes
[[athena:run-autonomously]] over the same scope — the architect then records
decisions/assumptions on the epic and uses best judgement instead of asking, and
the admiral's escalations become recorded best-judgement calls. Do not restate
run-autonomously's rules here; it layers on top of this seam.
