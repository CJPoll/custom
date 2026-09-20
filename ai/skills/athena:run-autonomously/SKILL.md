---
name: athena:run-autonomously
description: Invoke when the user is stepping away from the keyboard (possibly overnight) and wants the fleet to drive a scope of work — an epic, milestone, project, or ticket — to completion without them. Sets the no-human-present operating rules for admirals: use best judgement on ambiguities, escalate only the genuinely hard or security-sensitive calls to the planning architect, record every decision/assumption on the work item, and report them all when the user returns.
---

# athena:run-autonomously

The user is away and will **not** be available to answer questions — possibly
overnight. Drive the given scope of work (epic / milestone / project / ticket)
through to completion without them.

## Operating rules while autonomous

1. **Own it end-to-end.** See the scope through to done — plan, implement,
   verify, review, and merge/ship per the normal bar. Do not stop to ask a
   question you could reasonably resolve yourself.

2. **Ship to production.** Carry the work all the way to shipped — **merge each
   MR and deploy it once CI passes** and it meets the bar. Do not park merged
   work or wait for the user to release it; there is no one to give the
   go-ahead. Watch each deploy through.

3. **Decide with best judgement.** When an ambiguity or a decision arises,
   choose the option a careful senior engineer would, consistent with the
   plan, the domain model, and existing conventions. Keep moving.

4. **Escalate only the hard calls.** If a decision is *particularly complex or
   security-sensitive* — architecturally significant, hard to reverse, or with
   real security/data implications — delegate that specific decision to the
   `athena-architect` that planned this ticket/epic/milestone/project. Everything
   else, decide yourself.

5. **Record every decision and assumption.** Write each judgement call or
   assumption onto the **relevant epic / milestone / project**. Only fall back
   to recording on the ticket if there is no parent epic/milestone/project — if
   one exists, it goes there, not on the ticket. Note what was decided, the
   options considered, and why.

6. **Owner-credential gates throttle merging, not progress.** *Ship to
   production* still governs everything you can ship. The one exception is a
   step only the owner can perform — their actual credentials, or an
   interactive console/account action the pipeline cannot self-service (an
   out-of-band IAM/terraform apply, a provider-console app reinstall or
   scope-add). Do not halt and do not sit idle waiting on it. Keep the base
   change fixed-and-ready but **unmerged**; stack the dependent changes on top
   as ready-to-merge PRs — fully implemented, reviewed with the fail-closed
   critic, CI-green — and merge none of that stack. Carry every other
   independent piece of work to done and merged as normal. In *When the user
   returns*, give the owner the precise credential/console step **and** the
   ordered list of the stacked, ready-to-merge PRs, so one manual step lands
   the whole stack. This owner-creds/console class is the ONLY thing that
   cannot be shipped autonomously — everything else, security fixes included,
   still ships.

## When the user returns

Include a **report of all decisions and assumptions** made while running
autonomously — pulled from what was recorded on the work items — so the user
can review and reverse anything they'd have chosen differently.
