---
name: athena:fleet-inputs
description: The athena-admiral's required inputs (Notion scope + how "blocked" is represented), the sweep that adopts finished-but-unmerged MRs a previous run abandoned, and the Notion status-vocabulary mapping — including the substitution to use when a tracker has NO `In Review`-equivalent option. Use when starting a run, before dispatching anyone, to fix the status values each stage uses, to pick up orphaned green MRs, and to decide what a captain's brief says about the status transition.
---

# athena:fleet-inputs

The foundational inputs an athena-admiral needs before triaging or dispatching,
and how to map its lifecycle onto whatever status vocabulary the tracker
actually offers.

## Required inputs (ask once, up front, if missing)

- **Which Notion Missions are in scope** — a database/view and filter. If this
  isn't given, ask before doing anything else.
- **How "blocked" is represented in Notion** — a status field, a relation
  property, or something else. If this isn't given, ask before triaging.

Scope and blocked/unblocked semantics are foundational enough that a wrong
guess wastes the whole run — so ask **one** clarifying question up front and
wait. Everything else in the process is designed to be resolved unassisted.
When you were stood up by [[athena:kick-off]], these inputs arrive from the
launcher (the same scope and semantics the architect planned against), and a
sibling architect is your escalation target instead of a silent human.

## Before dispatching: adopt the work a previous run abandoned

Run `ai/bin/ready-and-idle --repo <repo>` on each repo in scope, **and again at
each [[athena:merge-boarding]] pass**. It lists open MRs that are non-draft,
green on their head SHA, unblocked and idle — finished work with no actor,
left behind when an earlier run hit a ceiling, was killed, or simply ended
while still holding it. Adopt any that falls in your scope and carry it through
the **full, unchanged** merge bar; it is not pre-approved by having sat there.

Do this before dispatching anyone: an orphan is cheaper to land than to
re-derive, and it gets more expensive every hour. Measured 2026-09-19/21 on
walt_ui — !1187/!1189/!1190 sat green and unblocked for ~2.4 days each
(610,039s, 91.8% of their combined start→merge time), and draining them then
cost 7 extra pipeline runs and 3 extra reviews because `origin/main` had moved
under them (19 commits under !1187 alone). Re-running the check at each
boarding pass also catches the MR your own run opened and then merged past.

## Status-vocabulary mapping

Optionally the invoker gives the Notion status values to use at each stage. If
none are given, use these defaults, **matched case-insensitively against the
Mission's existing options** (only create a new option if none is a reasonable
match):

- Unblocked, work about to start → `In Progress`
- Blocked on a discovered dependency → `Blocked`
- Verification passing, MR opened → `In Review`
- Stuck → `Stuck` (or `Needs Attention` if that's the closest existing option —
  see your own state log for which one this run settled on, and stay consistent
  with it)
- Green, reviewed, and deliberately **not mergeable by the fleet** — merging
  would perform a real-world action (see [[athena:merge-boarding]] → *Merging is
  not always landing code*) → **`HELD_FOR_OWNER`** in your state log, and in
  Notion `Needs Attention` assigned to **Cody**, with the context on the Mission
  body. This is a distinct terminal state, not a flavour of the others: `Stuck`
  means the fleet could not finish the work, `Blocked` means it waits on another
  Mission, and `HELD_FOR_OWNER` means **the work is finished and correct and the
  fleet lacks the authority to land it**. Recording it as `Stuck` misreports a
  successful Mission as a failure; recording it as `Done` is a lie about a PR
  that is still open.

**Read the tracker's real option list before dispatching anyone** — do not
assume the defaults exist.

## The no-`In Review`-equivalent substitution

Some DBs genuinely have no `In Review`-equivalent at all (the `notion-personal`
Tickets DB on 2026-09-18 offered only Todo / In Progress / Attention Given /
Needs Attention / Cancelled / Done), which makes the captain's one status
transition unsatisfiable. When no `In Review`-equivalent exists:

- **Tell the captain in its dispatch to set NO Notion status at all.**
- **Hold the Mission yourself at `In Progress`** from dispatch until the MR/PR
  is merged, then move it to `Done` per [[athena:ticket-management]].
- **Record the substitution as an assumption** in your state log and **report
  the vocabulary gap to the architect**.
- Do **NOT** invent a new `In Review` option in someone's DB to satisfy the
  default.

(This decouples the ticket from the captain and makes the terminal move
**yours alone** — which [[athena:admiral-final-report]] must reconcile, because
nothing else will move the ticket when the captain never touched it.)

## Assignee lifecycle

Follow the [[athena:ticket-management]] skill, which owns it. The `Assignee`
always names whoever currently holds the Mission, so reconcile it on every
status move: take scope → **Athena** (the active connection's bot, resolved via
`get-self`, and `Backlog`→`Todo`); dispatch a captain → `In Progress` (still
Athena); any waiting-on-the-human status (`Needs Attention`, `Done`,
work-workspace `Ready for Release`) → **Cody** (for `Needs Attention` also write
the context Cody needs onto the Mission body); `Attention Given` stays Cody
until you resume it (back to `In Progress` → Athena).

---

*Source (behavior-preserving relocation): athena-admiral "Inputs you should
expect from whoever invokes you". The admiral keeps a resident one-line trigger
pointing here.*
