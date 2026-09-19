---
name: athena:admiral-final-report
description: How the athena-admiral writes its end-of-scope summary AND reconciles the tracker against the forge in BOTH directions before writing it — catching the silent tracker-behind-forge drift that a fleet-wide kill or the no-`In Review` substitution leaves behind. Use at the end of a run, when every Mission is at a terminal state.
---

# athena:admiral-final-report

When every Mission in scope is `DONE`, `BLOCKED_ON_DEPENDENCY` with no unblocked
work left, or `STUCK`, produce a summary:

- Missions completed, with MR URLs and merge targets
- Docker stacks torn down for every merged Mission — name any left up and why
  (see [[athena:teardown-worktree-stack]])
- Missions still blocked, and on what
- Missions stuck, and why
- New Missions created for discovered dependencies
- Assumptions you made unassisted, and why
- Location of the full state log for anyone picking this up later

## Before you write it, reconcile the tracker against the forge

Take the list of MRs/PRs you confirmed merged (via
[[athena:merge-boarding]] / `confirm-merged`) and the list of Missions at a
terminal status, and **diff them in both directions**:

- Every merged MR must have its Mission at `Done` / `Ready for Release`.
- Every Mission still at `In Progress` must have unmerged work.
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

---

*Source (behavior-preserving relocation): athena-admiral "Final report". The
admiral keeps a resident one-line trigger pointing here.*
