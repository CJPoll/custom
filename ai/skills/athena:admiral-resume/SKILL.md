---
name: athena:admiral-resume
description: How an athena-admiral resumes its fleet after a usage-limit pause (or any interruption to its own turn) without losing work or duplicating captains — read the state log first, salvage every worktree's uncommitted work before any re-dispatch, adopt existing worktrees, and sweep every in-flight Mission. Use on ANY resume trigger, before touching ListAgents or dispatching anything.
---

# athena:admiral-resume

A limit pause stopping the fleet is expected; staying paused once limits reset
is not. Treat "I can act again" — harness-triggered or user-prompted — as a
**resume trigger, not a fresh run**.

## On any resume

- **Read your state log first.** Don't re-triage from Notion; don't assume a
  Mission needs a new worktree just because you can't see activity.
- **Check the report files** (`.../[run-id]/reports/[mission]-report.md`) for
  every `IN_PROGRESS` Mission **before** touching `ListAgents` or dispatching
  anything — a pause can land in the gap between a captain finishing and its
  message reaching you, and the file survives that gap. A Mission with a fresh
  terminal report is already done; process it per [[athena:captain-return]].
  Restart your `Monitor` watcher if it didn't survive the pause.
- **Snapshot every worktree's UNCOMMITTED work before you dispatch anything.**
  A usage limit does not degrade a fleet gracefully — it kills the admiral and
  every captain at once, against one shared quota, leaving whatever was not
  committed sitting in the worktrees. Committed work is safe; uncommitted work
  is the only thing at risk, and the incoming captain is what threatens it,
  because it starts editing the same files. So before any re-dispatch, copy each
  worktree's dirty state (`git status --porcelain` + the modified files, or a
  `git stash create` object whose sha you record) to
  `.../[run-id]/salvage/[mission]/`, and note in your state log what each
  worktree held. It is insurance you can delete, and it costs one pass.
  - Measured 2026-09-18-athena-inbox (TWO fleet-wide kills): the first admiral's
    successor took this snapshot and later recorded "Both salvage objectives are
    met — DND-183's and DND-189's previously uncommitted work is now in git"; the
    second, after a rate-limit kill of an admiral plus three captains, inspected
    the worktrees but took no copy, with DND-184 sitting on "4 commits + 6
    modified files (mid-sabotage-pass), most at-risk work".
- **Adopt worktrees and branches, never recreate them.**
- For what's left, check `ListAgents` for the Mission-qualified name. **Alive** →
  don't duplicate, just check status. **Gone** → re-dispatch under the same
  name, into the same worktree, told explicitly this is a resume (it should
  reconstruct progress from disk, per its own "Resuming after a pause") and told
  what the salvage snapshot holds, so it reconciles against it rather than
  overwriting it.
- **Sweep every in-flight Mission**, not just the one that happened to page you
  — a partial resume is the same failure mode as no resume. (See
  [[athena:fleet-liveness]] for the sweep + staleness discipline.)
- The **concurrency cap still applies** during a resume: resume 5, queue the
  rest.

---

*Source (behavior-preserving relocation): athena-admiral §3a "Resuming after a
usage-limit pause". The admiral keeps a resident one-line trigger pointing here.*
