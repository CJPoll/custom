---
name: athena:admiral-resume
description: How an athena-admiral resumes its fleet after a usage-limit pause (or any interruption to its own turn) without losing work or duplicating captains — read the state log first, salvage every worktree's uncommitted work before any re-dispatch, adopt existing worktrees, and sweep every in-flight Mission. Use on ANY resume trigger, before touching ListAgents or dispatching anything.
---

# athena:admiral-resume

A limit pause stopping the fleet is expected; staying paused once limits reset
is not. Treat "I can act again" — harness-triggered or user-prompted — as a
**resume trigger, not a fresh run**.

## Your captains are children of your TURN, not independent processes

A usage limit is not the only thing that kills the whole fleet at once.
**Anything that ends your turn ends every captain you have in flight** — including
the owner interrupting you to ask a question. There is no graceful degradation and
no warning: the captains stop mid-edit, their uncommitted work sits in the
worktrees, and the owner very likely does not know it happened (measured
2026-09-20-ai-lms: Cody interrupted to ask one question and lost two in-flight
captains, "did not know that killing the turn also kills its background
subagents"). So a resume trigger is **any** return to action, whatever ended the
turn, and the salvage pass below is unconditional.

**Never read intent out of the harness's own status string.** `SendMessage`
answering *"Agent … was stopped by the user and won't be resumed"* is generic
harness wording for a dead child; it is NOT evidence that the owner decided to
stop that Mission. In the same run an admiral turned exactly that string into
"stopped by Cody, an owner decision, not a failure to recover from" and recorded
it as fact. If you need to know whether a halt was intentional, **ask** — and
until you have an answer, treat the Mission as interrupted and recoverable, which
is the reading that loses nothing if you are wrong.

## On any resume

- **Read your state log first.** Don't re-triage from Notion; don't assume a
  Mission needs a new worktree just because you can't see activity.
- **Check the report files** (`.../[run-id]/reports/[mission]-report.md`) for
  every `IN_PROGRESS` Mission **before** touching `ListAgents` or dispatching
  anything — a pause can land in the gap between a captain finishing and its
  message reaching you, and the file survives that gap. A Mission with a fresh
  terminal report is already done; process it per [[athena:captain-return]].
  Restart your `Monitor` watcher if it didn't survive the pause.
- **Snapshot every worktree's UNCOMMITTED work before you dispatch anything —
  on ANY halt, whatever caused it.** No fleet-wide kill degrades gracefully: a
  usage limit takes the admiral and every captain at once against one shared
  quota, and an interrupted turn takes them as children (above). Either way
  whatever was not committed is left sitting in the worktrees. Committed work is
  safe; uncommitted work
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
  - **UNTRACKED files are the ones that vanish silently.** A modified tracked
    file is recoverable-ish and `git clean` warns you about nothing you can see;
    an untracked new file is held by no commit, no stash you did not take, and no
    reflog. Measured 2026-09-20-ai-lms: DND-264's `apps/lms/test/lms/params_test.exs`
    was untracked when its captain was killed, and a `git clean` or a fresh
    worktree would have destroyed it with no error at all. So the snapshot uses
    `git status --porcelain` (which lists `??` entries) and copies them too, and
    the resume brief tells the incoming captain **by name** which files are its
    own in-flight work plus an explicit instruction not to `git clean`.
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
- The **concurrency cap still applies** during a resume: resume up to 5, each
  through the load gate ([[athena:dispatch-captain]] → *Machine capacity gates
  every dispatch*), and queue the rest. A fleet-wide resume after a usage-limit
  kill is exactly the burst that gate exists for.
- **A drain resume re-dispatches `PARKED` Missions.** The top-level session
  started you with a run-id after the owner resumed the session
  ([[athena:fleet-drain]] → *Resume*), after it CLAIMED the run. First confirm
  you own it: `~/dev/custom/ai/bin/fleet-resume status --run-id <run-id>` must
  print `RESUMED`. Anything else means you do not own the run: stop and report
  it, touching no worktree. A `PARKED` Mission is resumable, never stuck. Adopt its worktree, and brief the captain with the resume point from its
  `PARKED` report. Every re-dispatch still runs the control checkpoint first.
  A spawn refused with `is draining` is **PAUSE**: never retry it, never do its
  work in-line, and run the drain protocol again.

---

*Source (behavior-preserving relocation): athena-admiral §3a "Resuming after a
usage-limit pause". The admiral keeps a resident one-line trigger pointing here.*
