---
name: athena:epic-progress-dm
description: Compute and send the athena-admiral's owner DM when a just-merged ticket moves its epic across the 50% or 100% completion boundary. Use at merge time — after CONFIRMING a merge landed and moving the ticket to its terminal status — when the merged ticket belongs to an epic. Encodes the fire-once-per-boundary crossing math, the completed-count recompute from Notion, the Slack mrkdwn formats, and the decisions-digest shaping under run-autonomously.
---

# athena:epic-progress-dm

The admiral does **not** DM on every merge. Owner notifications are exactly
three events: an epic crossing **50%** complete, an epic reaching **100%**, and
any ticket moving to **`Needs Attention`**. The first two are yours, computed at
merge time (below); the third rides the ticket-lifecycle transition and is owned
by **athena:ticket-management** (its "Needs Attention" DM rule) — not here.
Merging an MR, on its own, pings nobody.

## When you compute the epic DMs

After you merge a ticket's MR and move that ticket to its terminal status
(having CONFIRMED the merge landed — see the admiral's "Confirm a merge actually
landed"), if the just-merged ticket belongs to an epic (it has a non-empty
`Epic` relation), recompute the epic's completion from Notion and DM Cody if
this merge just crossed a threshold. A ticket **not** in an epic cannot trigger
these — per-epic only.

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

- **50%:** DM only when `before/M < 0.5` **and** `after/M >= 0.5` — the merge
  moved the epic from under half to at least half. It never re-fires while the
  epic stays ≥50%.
- **100%:** DM only when `after == M` **and** `before < M` — this merge completed
  the epic's final ticket.

A single merge can cross both boundaries at once (e.g. a 1-of-2-ticket epic going
0→100%); send one DM per boundary this merge actually crossed, at most one each.

## Formats

Slack mrkdwn link syntax `<url|label>`, NOT markdown; `:notion:` + the epic PAGE
url, DM'd to Cody (U0AHNV4RJGP) as Athena via the athena:slack skill
(`~/.claude/skills/athena:slack/bin/dm`):

  :chart_with_upwards_trend: :notion: <EPIC_URL|Epic Name> is 50% complete (N/M tickets).
  :tada: :notion: <EPIC_URL|Epic Name> is complete (M/M).

Only a merge you yourself performed counts (your own glab-athena/gh-athena call,
or your engineer's under your direction); never a merge by a human or another
harness you merely observed while watching main or pipelines.

## Milestone DMs carry a decisions digest

The 50%/100% DMs (NOT the `Needs Attention` DM, which already carries its own
one-line why) double as a "here's what we decided on your behalf, take a look"
checkpoint. When running under **athena:run-autonomously**, the fleet records
every judgement call and assumption on the work item — per that skill, on the
parent **epic** first (the ticket only when there is no parent). So when you
compose a milestone DM, gather those recorded decisions from the epic page (its
decisions/assumptions section), falling back to the epic's ticket bodies, and
append a short digest. This is the running, partial form of run-autonomously's
"when the user returns, report all decisions" — at 50% it covers the calls made
so far, at 100% the complete set; keep the two in sync so they don't drift.

Keep it digestible — SUMMARIZE, never dump every raw assumption:
- List at most the **5 highest-judgement** calls, one terse bullet each (the
  consequential / hard-to-reverse ones, not routine choices).
- If more were recorded, add a final line `…and K more — see the epic.`
- Always end with the epic link so Cody can read the full record; if NO
  decisions were recorded, send the one-line milestone message alone (no digest
  block).

Shape (newlines in one DM; Slack mrkdwn):

  :chart_with_upwards_trend: :notion: <EPIC_URL|Epic Name> is 50% complete (N/M tickets).
  Decisions made on your behalf so far:
  • <highest-judgement call 1>
  • <highest-judgement call 2>
  …and K more — see <EPIC_URL|the epic>.
