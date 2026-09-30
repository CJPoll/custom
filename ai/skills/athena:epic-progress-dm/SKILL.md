---
name: athena:epic-progress-dm
description: Compute and report the athena-admiral's epic milestone when a just-merged ticket moves its epic across the 50% or 100% completion boundary. The milestone goes on the epic page, to whoever launched the admiral, and into the owner digest; it is NOT a DM to the owner. Use at merge time — after CONFIRMING a merge landed and moving the ticket to its terminal status — when the merged ticket belongs to an epic. Encodes the fire-once-per-boundary crossing math, the completed-count recompute from Notion, where the milestone goes, and the decisions-digest shaping under run-autonomously.
---

# athena:epic-progress-dm

The admiral reports an epic milestone at exactly two events: an epic crossing
**50%** complete, and an epic reaching **100%**. Both are computed at merge
time (below). Merging an MR, on its own, reports nothing. The skill keeps its
old name; it no longer sends a DM.

**No owner DM.** Cody is DMed only for what `~/.claude/CLAUDE.md` → *Owner
approval policy* → *Asking, and what counts as approval* names, chiefly a step
only Cody can run. A milestone is none of those. A `Needs Attention` ticket is
one, and its DM is [[athena:ticket-management]]'s, not this skill's.

**Later (2026-09-30):** this skill DMed Cody at each crossing, as one of
"exactly three" owner notifications. Superseded by the owner decision of
2026-09-28 07:15Z (*Owner approval policy*): "I would prefer you not even dm
me unless it's something that only I can run." Admirals had re-derived that
three times and one still planned the DM: jev 09-28 07:15Z, harness-lane
09-28 10:54Z and parallel-gates 09-30 03:27Z each suppressed it, while the
mimic-removal handoff of 09-30 said "The next DM fires when the epic crosses
50%".

## When you compute the milestone

After you merge a ticket's MR and move that ticket to its terminal status
(having CONFIRMED the merge landed — see the admiral's "Confirm a merge actually
landed"), if the just-merged ticket belongs to an epic (it has a non-empty
`Epic` relation), recompute the epic's completion from Notion and report the
milestone if this merge just crossed a threshold. A ticket **not** in an epic
cannot trigger these — per-epic only.

## Completed definition

A ticket counts as completed when its status is `Done` **OR** `Ready for
Release` (the work-workspace pre-release terminal). `M` (total) = every ticket
linked to the epic via the `Epic`↔tickets relation; `N` (completed) = those in a
completed status. Recompute both by re-reading Notion (the `Epic` relation on the
just-merged ticket → the epic's linked tickets and their current statuses),
never from a running tally — a missed wake or a parallel merge must not desync
the count. Because you serialize your own merges, the recompute-after-each is
race-free.

## Crossing semantics — fire ONCE per boundary, never spam

Frame it as a before/after comparison around THIS merge: `after` = completed
count now (includes the ticket you just moved to terminal); `before` = the
completed count computed with that ticket's PRIOR (non-terminal) status — i.e.
`after - 1` in the normal case, or `before == after` if the ticket was already
terminal (then nothing fires).

- **50%:** report only when `before/M < 0.5` **and** `after/M >= 0.5` — the
  merge moved the epic from under half to at least half. It never re-fires
  while the epic stays ≥50%.
- **100%:** report only when `after == M` **and** `before < M` — this merge
  completed the epic's final ticket.

A single merge can cross both boundaries at once (e.g. a 1-of-2-ticket epic going
0→100%); report one milestone per boundary this merge actually crossed, at most
one each.

Only a merge you yourself performed counts (your own glab-athena/gh-athena call,
or your engineer's under your direction); never a merge by a human or another
harness you merely observed while watching main or pipelines.

## Where the milestone goes

1. **Your state log**, one line: `Epic <name> crossed 50% (N/M)` or
   `Epic <name> complete (M/M)`.
2. **Whoever launched you** (the coordinator or `main`, by SendMessage), the
   same line. A launcher that is gone is not a fault; the state log and the
   final report still carry it.
3. **Your final report** ([[athena:admiral-final-report]]), under the
   milestones this run crossed, with the decisions digest below.

Never a Slack DM to Cody, and never a channel post (`~/.claude/CLAUDE.md` →
*Owner approval policy*, item 3).

## A milestone carries a decisions digest

The 50%/100% milestone doubles as a "here's what we decided on your behalf,
take a look" checkpoint. When running under **athena:run-autonomously**, the
fleet records every judgement call and assumption on the work item — per that
skill, on the parent **epic** first (the ticket only when there is no parent).
So when you write a milestone into the final report, gather those recorded
decisions from the epic page (its decisions/assumptions section), falling back
to the epic's ticket bodies, and append a short digest. This is the running,
partial form of run-autonomously's "when the user returns, report all
decisions" — at 50% it covers the calls made so far, at 100% the complete set;
keep the two in sync so they don't drift.

Keep it digestible — SUMMARIZE, never dump every raw assumption:
- List at most the **5 highest-judgement** calls, one terse bullet each (the
  consequential / hard-to-reverse ones, not routine choices).
- If more were recorded, add a final line `…and K more — see the epic.`
- Always end with the epic page URL so Cody can read the full record; if NO
  decisions were recorded, the one-line milestone stands alone (no digest
  block).

Shape:

  Epic <Epic Name> is 50% complete (N/M tickets). <EPIC_URL>
  Decisions made on your behalf so far:
  • <highest-judgement call 1>
  • <highest-judgement call 2>
  …and K more — see the epic.
