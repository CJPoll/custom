---
name: athena:critic-convergence
description: Decide whether an iterated review/critic loop is converging or walking in circles, and what to do when it is walking — the cluster-round procedure, the escalation, and the hard stop that terminates a loop no round will converge. Use at round N>=2 of any loop where a resolver fixes findings and the judge re-runs on the new SHA (athena-diff-critic via ai/bin/critic-review, or review-loop), BEFORE fixing this round's findings — and again whenever an already-escalated cluster signals a second time.
---

# athena:critic-convergence

**Kind: living normative document.** Amended in place, per `~/dev/custom/CLAUDE.md`
→ *Documentation conventions*.

A loop where a resolver fixes findings and a judge re-runs on the new SHA is
supposed to descend: each round's findings are fewer, and they are defects that
were always there. When instead the fixes keep *creating* the next round's
findings, the loop is a random walk and it does not terminate on its own.

Measured twice, independently, both eight rounds:
`ai/skills/athena:inbox/SABOTAGE_RECORDS.md` ("the last critic round, on the
machinery the previous one added"), and DND-232 on 2026-09-20
(`ai-artifacts/coordination/2026-09-20-notif-platform/state.md`, `## Log`,
rounds 1–8: round 3 "a REGRESSION from round-2 note handling", round 5 "2 are
regressions from round-4 fixes" — one of them set corruption). In both, the
resolver eventually worked out for itself that it should stop patching. This
skill is that judgement, made early and on purpose.

## The convergence check — run it BEFORE fixing this round's findings

At round N >= 2, classify each finding:

1. **Pre-existing** — the judge found it on a deeper read; no earlier round
   caused it. Patch it normally.
2. **Mechanical follow-on** — it exists because of an earlier round's edit, but
   it is a stale name, citation, path, or reference. This is an incomplete
   sweep, not a structural problem. Patch it AND sweep its class (repo
   `CLAUDE.md` -> *A failed lookup must never look like an empty one*, "patch
   the class, not the site"). It is NOT a cluster signal.
3. **Semantic follow-on — the cluster signal.** It exists because of an earlier
   round's edit AND it is a *contradiction* (two clauses cannot both hold), an
   *unsatisfiability* (a MUST no case can meet), or an *unreachability* (a
   branch, type, or path that can now never fire). One clause's correctness
   depends on another's, so fixing them one at a time moves the defect rather
   than removing it.

**One finding of kind 3 triggers a cluster round.** Not a ratio, not a repeat.
The 2026-09-20 loop's first kind-3 finding was in round 3 and it ran to round 8.

The two kinds are worth separating because kind 2 is loud and cheap and kind 3
is the one that compounds. Round 6 (four mis-cited files) and round 8 (one
mis-targeted citation) of that loop were pure kind 2, and both were correctly
handled as ordinary patch rounds — round 8's own report records "no new edges".

## The cluster round

Not a rewrite. A scoped, bounded redesign:

1. **Name the cluster.** List the areas — sections, modules, clauses — whose
   consistency is joint. Derive it from the findings of EVERY round so far, not
   just this one; the earlier rounds are what map the cluster's extent. Write
   the list down before editing anything.
2. **State the joint invariant** the named areas must satisfy together, and
   design all of them against it at once. This is the step the per-finding loop
   structurally cannot do.
3. **Apply it as one edit**, not finding-by-finding.
4. **Re-read the whole flow end to end** and reconcile every cross-reference —
   the kind-2 sweep, now over the redesign. Splitting or moving a section
   dangles citations into it; find them here rather than in round N+1.
5. **Report**: the cluster named, the joint invariant, and an explicit
   confirmation that every previously-resolved finding is STILL resolved.

### Bounds — what makes a false trigger cheap

These are what let the trigger fire on a single finding. Without them an
over-eager trigger restarts churn, which is worse than the loop it replaced.
The asymmetry the trigger is set against: firing one round too early costs about
one coherence pass; firing five rounds too late is what was measured, twice.

- **Only the named cluster** may be redesigned. Everything else stays as it is,
  including patches from earlier rounds that are working.
- **No previously-resolved finding may be re-opened.** If the redesign seems to
  require re-opening one, that is a sign the cluster was named too narrowly —
  widen the cluster, do not regress the fix.
- **One cluster round per cluster.** If the SAME cluster signals again after a
  cluster round, the artifact's requirements are underdetermined and no further
  round will find that out. Stop and escalate: a captain to its admiral, an
  admiral to the architect, an architect to its caller. (And only below the
  round-12 artifact ceiling — see *After the escalation*.)

## After the escalation — the second re-signal, and the stop

Escalating is not a termination rule. It hands the cluster to someone with
design authority and the loop then resumes on the implemented decision. If the
SAME cluster signals kind-3 **again** after that decision has landed, two things
are true, and the loop still has no bound unless both are acted on.

**The escalation was scoped too narrowly — widen it, do not repeat it.** This is
the cluster-round bound *widen the cluster, do not regress the fix* one level up.
A decision taken seam-by-seam answers each seam and leaves the seams' *joint*
requirement as undetermined as it was; the re-signal is that gap, not a worse
critic. The second escalation asks for one of exactly two deliverables:
**requirements closure over the whole subsystem** — every open question in it
decided together, against one stated invariant — **or a recommendation to descope
to a coherent core**. Name which you want. "Look at it again" reproduces the
first escalation and buys another re-signal.

**A closure pass is verifiable or it is just another cluster round.** It reports
a table with one row per open question, each row CLOSED (already resolved and
still holding), DECIDED (with the decision and where in the artifact it landed),
or DESCOPED — and the descoped parts are filed as follow-up tickets, never
silently dropped. Without the table, "the closure covers it" is the same
unverifiable claim as "the redesign covers it"; with it, the next re-critic's
findings can be checked against the rows rather than re-argued.

**HARD STOP — if kind-3 signals again after a closure/descope pass — the same
subsystem after a subsystem-scoped one, ANYWHERE in the artifact after an
artifact-scoped one — stop.** (**Later (2026-09-20):** this rung read "if the
same subsystem re-signals kind-3"; that scoping left the artifact-scoped rung
below with no terminal.) Do not iterate, do not override, do not escalate a
third time. **PARK** the work at its last clean-gate SHA, unmerged, and hand it
to the owner as a product-judgment item: what the requirements *should be* has
stopped being an engineering question, and no one in the loop can answer it.
Parking is the only outcome that both terminates the loop and leaves the bar
exactly where it was — nothing merges with findings unresolved.

**Every rung above is scoped to the same CLUSTER; this one is scoped to the
ARTIFACT.** Otherwise an artifact admits one full trip up the ladder per cluster
and the stop cannot fire while the judge keeps finding a *fresh* one. So: **at
round 12 or later, a kind-3 finding no longer buys a cluster round — it routes to
the artifact-scope decision, whatever rung its own cluster is on.**
`ai/bin/critic-review` prints the round number on every BLOCK; that is the
counter, and it does not reset on a rebase or on a mid-loop re-spec (a re-spec
that deletes the failing sections IS a descope — it spends this rung, it does not
refund it). Kind-1 and kind-2 rounds never trigger this, so a judge still reading
real pre-existing defects out of a long artifact is never cut short. Twelve,
because both loops that RESOLVED took eight rounds; the one that did not was at
round 13 when its admiral had to invent the closure pass unaided.

**The artifact-scope decision** is the closure/descope pass above taken over the
whole artifact, biased to the split: land the **coherent core** — the sections
that have produced no kind-3 — with the same row-per-open-question table, and
file the rest as follow-up tickets (*descoped-and-landed*); or **PARK** if no
core separates from the kind-3 sections. The core still lands only on
`FINDINGS: none`.

State which of the three a loop reached — **clean**, **descoped-and-landed**, or
**parked-for-owner** — so its outcome is legible without replaying the rounds.

Measured 2026-09-20 (DND-232): the first escalation's three seam decisions landed
in round 12, round 13 re-signaled kind-3 in the same cluster, and the second
escalation — whole-subsystem closure — produced a 14-row table after which the
re-critic found zero kind-3 in that subsystem. The admiral invented that pass on
the spot; it is written down so the next loop does not.

## The bar does not move

Round count and loop fatigue are reasons to change METHOD or to ESCALATE. They
are never a reason to:

- override the judge (`integration-gate --critic-override` — which the gate
  REFUSES outright once a BLOCK is recorded for the head, its scope being the
  absence of a verdict; see [[athena:merge-boarding]] -> *The merge bar*),
- carry a finding forward as a known-open,
- merge with findings unresolved, or
- narrow what the judge looks at.

A cluster round ends the way every other round ends: the judge re-runs on the
new SHA and the loop exits only on `FINDINGS: none` for the SHA being landed.
"The redesign covers it" is not a resolution — the re-critic saying none is.
(`ai/blocks/ops/safety-checks.md`: faster, never weaker.)

## Related

- `ai/bin/critic-review` — records the per-SHA verdicts the round count is read
  from, and points here on a BLOCK at round >= 2.
- [[athena:merge-boarding]] -> *A loop that is not converging* — the admiral's
  side: what to put in a re-dispatch brief, and when to stop resuming.
- [[review-loop]] — the generic `/review` loop; this skill is its termination
  discipline.
