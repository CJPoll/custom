---
name: athena:admiral-final-report
description: How the athena-admiral writes its end-of-scope summary AND reconciles the tracker against the forge in ALL THREE directions before writing it — catching both the silent tracker-behind-forge drift that a fleet-wide kill or the no-`In Review` substitution leaves behind, and the finished-but-unmerged MR the run is about to abandon. Use whenever the run is ending for ANY reason — every Mission terminal, but also a usage ceiling, an interruption, or scope exhaustion.
---

# athena:admiral-final-report

When your run is ending — every Mission in scope `DONE`, `BLOCKED_ON_DEPENDENCY`
with no unblocked work left, or `STUCK`, **or your turn ending for any other
reason** (see the trigger note below) — produce a summary:

- Missions completed, with MR URLs and merge targets
- Docker stacks torn down for every merged Mission — name any left up and why
  (see [[athena:teardown-worktree-stack]])
- Missions still blocked, and on what
- Missions stuck, and why
- New Missions created for discovered dependencies
- Findings ticketed during the run, including captains' proposed tickets you
  filed, as one batched list with priorities (`~/.claude/CLAUDE.md` → *Find it,
  ticket it, fix it, verify it live*)
- Assumptions you made unassisted, and why
- Location of the full state log for anyone picking this up later

When the scope is exhausted, also report the run `finished` to the fleet
registry; a ceiling or an interruption reports nothing
([[athena:fleet-liveness]] → *Fleet registry reports*).

**A drain is its own end reason, `drained`.** The owner paused the session, and
you ended only after your last captain returned. Report `admiral-state drained`
(not `finished`). List the `PARKED` Missions with each resume point, and name
the `DRAINED session=… run=…` line you wrote to the state log once the last
captain returned, which is what the resume finds ([[athena:fleet-drain]]).

## Before you write it, reconcile the tracker against the forge

Take the list of MRs/PRs you confirmed merged (via
[[athena:merge-boarding]] / `confirm-merged`) and the list of Missions at a
terminal status, and **diff them in both directions**:

- Every merged MR must have its Mission at `Done` / `Ready for Release`.
- Every Mission still at `In Progress` must have unmerged work.
- **Every MR you OPENED is merged, or named as a live hand-off.** An open MR
  that is non-draft, green on its head SHA, with no unresolved discussion and no
  unmet approval is **not** "unmerged work in progress" — the direction above
  *passes* on it, because the predicate it checks is satisfied. It is finished
  work with no actor, which is the most expensive state in the fleet. Enumerate
  it with `ai/bin/ready-and-idle --repo <repo>`, and for each one either take it
  through the merge bar now or record it as blocked/stuck with the reason.
  *"The run ended" is not a reason; it is the failure.* Read its exit code: `3`
  = UNAVAILABLE, no list, so report the sweep as not taken; `4` = the list is
  COMPLETE and actionable, only the `drift` column is a `>=N` lower bound. A `4`
  is not a failure — treating it as one abandons a valid orphan list.
- **An MR whose merge-train is still running is ridden to landed, not left as
  "running".** See [[athena:merge-boarding]] → *Ride a boarded train to landed*.
  End the run only once it is CONFIRMED landed or explicitly HANDED-OFF; a final
  report that says "the train is still running" is the abandonment above, not a
  status.
- Do the same for the human-waiting statuses: a Mission sitting at
  `Needs Attention` whose blocking condition you later resolved is asking the
  owner for work that is already finished — so clear it or restate it.

**This is not covered by the per-merge transition.** That transition fires on an
event, and two things routinely break the event:

1. a fleet-wide kill between the merge and the status move, and
2. the no-`In Review`-option substitution (see [[athena:fleet-inputs]]), which
   deliberately decouples the ticket from the captain and makes the terminal
   move **yours alone**.

Both leave the tracker behind the repos silently — nothing errors, and your own
state log holds both lists without ever comparing them.

*Measured 2026-09-18-athena-inbox: DND-208 appeared under "Confirmed MERGED"
(`custom` PR #7) while the last completion roll-up omitted it and still carried
it as Running/`In Progress`; and DND-203's remediation was recorded done while
the ticket stayed `Needs Attention`, assigned to Cody, still asking for it.*

*Measured 2026-09-19/21, walt_ui !1187 / !1189 / !1190: all three were open,
non-draft, green, approved and unblocked within ~8 minutes of their last commit,
then sat untouched for ~2.4 days each — **610,039s (7.06 days) of ready-and-idle,
91.8% of their combined start→merge time**. A run opened them, merged its other
MRs, and ended still holding these three; nothing noticed. The idle is not free
waiting: when a later run drained them, `origin/main` had moved 19 commits under
!1187 alone, costing 4 full pipeline runs and 2 extra reviews to absorb the
drift. `lead-time` could not have caught it — it queries `state=merged`, so an
orphaned open MR is invisible to it until it merges, which is 2.5 days after the
damage stops being recoverable.*

**Also fire this skill whenever your turn is ending for ANY reason** — ceiling,
interruption, scope exhaustion — not only when every Mission reached a terminal
state. A run that abandons finished work is precisely a run that never reaches
terminal state, so gating this on terminal state means the check cannot fire in
the one case it exists for. [[athena:admiral-resume]] is the resume half of a
pair; this is the suspend half. (A HARD kill executes nothing, so this cannot
cover that case — the athena-shipwright cron's hourly `ready-and-idle` sweep is
what covers a hard kill. Do not read this paragraph as making that sweep
redundant.)

---

*Source (behavior-preserving relocation): athena-admiral "Final report". The
admiral keeps a resident one-line trigger pointing here.*

## `HELD FOR OWNER` — the section that must never be omitted

Every Mission at `HELD_FOR_OWNER` (see [[athena:fleet-inputs]] → *Status-vocabulary
mapping*) gets its own entry, because it is the only class of finished work that
goes nowhere unless the owner acts. Per Mission:

- the PR URL and the head SHA;
- the `BLAST-RADIUS HOT` block **verbatim** — what merging would cause;
- any architect design sign-off (a design sign-off is not an authorization to
  spend, but the owner wants to know it exists);
- the decision you need, in one sentence;
- **the exact command that lands it once the owner says yes** —
  `integration-gate --owner-approval '<their words>'`, run from the named
  worktree.

A security fix is here only for a step only the owner can perform (their
credentials, a console action). An exit 4 alone does not hold it: it merges
under the owner's standing approval (`~/.claude/CLAUDE.md` → *Security fixes
ship without owner approval*). List it among the merged work with its `BLAST-RADIUS HOT` block and the approval line
it merged under.

A held Mission reported only as a status string leaves the owner to reconstruct
the merge, which is how a held MR becomes a forgotten one.
