---
name: athena:fleet-drain
description: The fleet's pause/resume procedure — the admiral's control checkpoint before every dispatch, reading a spawn refused by the drain guard as PAUSE (never retry, never do the work in-line), the drain protocol (park QUEUED missions, let running captains finish or park by reason class, never end the turn while a captain runs, then report drained), a captain parking on request, and the top-level session arming its resume waiter and resuming a drained run. Use at every dispatch point, on a `CONTROL:` line from admiral-report-watch, on any refused athena-admiral/athena-captain spawn, on a park message, when an admiral you launched ends with reason `drained`, when a `fleet-control wait` you armed exits, and on a fleet.session.control_changed inbox line.
---

# athena:fleet-drain

The owner pauses (drains) or resumes a Claude session from the fleet page. The
normative text is `~/dev/custom/ai/contracts/athena-events.md` → *Fleet registry
and session control* → *Enforcement layers*. This skill is the procedure each
agent follows. It is cooperative on top of a hard backstop: the
`fleet-drain-guard.sh` hook refuses every athena-admiral and athena-captain
spawn while the session drains, whatever any agent remembers.

## The checkpoint: before every dispatch point

Run it before the initial dispatch, before every refill when a captain returns,
and before every re-dispatch on resume:

```sh
~/dev/custom/ai/bin/fleet-control check
```

It reads the session id from `$CLAUDE_CODE_SESSION_ID`, which every agent's
Bash tool carries. It prints one line:
`desired=<run|drain> reason=<r> until=<t|unbounded> basis=<b>`.

- **Exit 0: dispatch.** When the basis is not `server`, it also printed a
  WARNING. Copy that line into your state log. Unknown control state is never
  a confirmed run.
- **Exit 3: do not dispatch.** Run the drain protocol below.
- **Any other exit is an error. Never read it as run.** Dispatch nothing,
  record the error, and check again at the next trigger.

## A refused spawn is PAUSE

A drained session's spawn fails with an error string like this:

```
PreToolUse:Agent hook error: Fix: fleet session <id> is draining (<reason>, until <t>; basis <b>) — this spawn was refused, not failed: ...
```

Another `fleet-drain-guard` refusal can also appear here, such as one it could
not classify, or a `fleet-control` error. Read every such refusal as **PAUSE**:

- **Never retry the spawn.** Every retry is refused the same way.
- **Never do the captain's work in-line** to get around it.
- Mark that Mission `PARKED` in `state.md`. It never started, so its worktree
  holds no captain work.
- Run the drain protocol.

## The drain protocol (admiral)

Do these in order.

1. **Stop dispatching.** Nothing new starts: no refill and no re-dispatch.
2. **Park the queue and report it:**
   - Mark every `QUEUED` Mission `PARKED` in `state.md` (the row and the log).
   - Report the state, then the scope with the parked missions:
     `fleet-report admiral-state --run-id <run-id> --state draining`, then
     `admiral-scope` with `captain_state: parked`
     ([[athena:fleet-liveness]] → *Fleet registry reports*).
3. **Let running captains reach a terminal report.** The grace depends on the
   reason class in the `fleet-control` line (owner decision OQ-2, 2026-09-24):
   - **`override:force_drain`** (the owner's pause): each running captain may
     finish its current Mission for **at most 30 min**. Record the drain start
     time in the state log. Arm a one-shot `Monitor` on
     `sleep 1800; echo "DRAIN GRACE EXPIRED"` so you wake at the deadline. At
     the deadline, send the park message to every captain still running.
   - **`metering:*`, or any `local-rule:*` basis:** send the park message to
     every running captain at once.

   The park message goes by `SendMessage` to the captain's Mission-qualified
   name:
   `PARK: session <id> is draining (<reason>). Commit your work in progress,
   push your branch, write your report with Status PARKED naming the resume
   point, and end your turn.`
4. **Never end your turn while a captain runs.** Ending an admiral's turn kills
   its running captains ([[athena:admiral-resume]]). Wait on your `Monitor`
   the usual way, and handle each return per [[athena:captain-return]]. A
   return frees a slot, but a draining admiral does not refill it.
5. **When no captain runs**, in this order:
   - report `fleet-report admiral-state --state drained`;
   - write the final report with reason `drained`
     ([[athena:admiral-final-report]]);
   - **release the run**, as your LAST act on it:
     `~/dev/custom/ai/bin/fleet-resume drained --run-id <run-id>`. From here on
     you own nothing (*Run ownership* below), so touch no Mission, worktree or
     state-log row after it;
   - then end your turn. Send no resume message: the top-level session arms its
     resume waiter when your completion arrives, and the waiter's first poll
     sees a resume that landed while you drained (*Arming the resume waiter*).

A captain that returns `DONE` during the grace goes through the normal DONE
path, including boarding. Merging is not a spawn, so drain does not stop it.

**Wake-ups.** `admiral-report-watch` prints `CONTROL: drain` when the session
turns to drain, and `CONTROL: unknown` when the check errors. Treat either as
"run the checkpoint now". `CONTROL: run` while you are still draining changes
nothing for you. Finish the drain; the top-level session's resume waiter
resumes the run after you release it.

## Parking (captain)

On a `PARK:` message from your admiral, stop where you are:

1. Commit your work in progress on your branch. Use a message naming the
   Mission and `WIP (parked)`. Run no gate: parking is not a completion claim.
2. Push the branch as Athena (*Pushing as Athena* in athena:github).
3. Write your report with `Status: PARKED`. Give the head SHA, and name the
   **resume point**: the next step you would have taken, and anything uncommitted
   you could not save. Parking never removes the obligation to report.
4. End your turn. Kill nothing but your own children, by PID.

**A resume point must survive a reboot.** A pause often ends in a machine
restart, and `/tmp` (the session scratchpad included) does not survive one.
Before a captain writes its PARKED report, or a draining admiral writes its
final report, copy every helper the resume plan names (a send script, a landing
or merge-wait script, a fixture) into the run's coordination dir,
`~/dev/custom/ai-artifacts/coordination/<run>/`, and cite that path. Never cite
a `/tmp` path as a resume step. Measured 2026-09-26, two runs after one reboot:
slack-interactive's `slackiv-*.sh` landing scripts and DND-558's live-verify
`dnd-558-send.sh` were both gone and had to be rebuilt.

## Run ownership: the invariant every resume path keeps

**At most one admiral owns a run at any time.** Ownership changes hands only
through `~/dev/custom/ai/bin/fleet-resume`, which appends one marker line to the
run's `state.md` under a lock on that state log:

- `DRAINED session=<id> run=<run-id> at=<ISO>`: nobody owns the run. The
  draining admiral writes it as its last act (step 5). The top-level session
  writes it to release a claim whose spawn did not happen.
- `RESUMED session=<id> run=<run-id> at=<ISO>`: the run is claimed. The
  top-level session writes it BEFORE it spawns the resuming admiral.

A run is resumable exactly when its last marker for the session is `DRAINED`.
`fleet-resume claim` reads that and appends `RESUMED` in one locked step. So
however many wakes arrive, each drained run is claimed once. Never hand-write a
marker: `fleet-resume` refuses a state log with a malformed marker (exit 4,
naming the line), and never claims it.

Every path that can trigger a resume runs the same two commands, so none of
them needs to know about the others:

- the session's resume waiter exiting 0 (*Arming the resume waiter*): the
  guaranteed wake;
- the `fleet.session.control_changed` inbox line, when this session is its
  project's inbox consumer (possibly delivered twice): a fast path only;
- the owner asking the session to resume by hand.

## Arming the resume waiter (top-level session)

The `control_changed` line is addressed to one session but delivered to its
PROJECT's session channel, and only the project's designated inbox consumer
reads that ([[athena:inbox]]). A second session in the same project never sees
its own wake. So a drained session wakes itself: it polls its own control read.
A subagent never arms it.

- **When:** an athena-admiral you launched completes and its final report's
  reason is `drained`. Confirm the run is released:
  `~/dev/custom/ai/bin/fleet-resume status --run-id <run-id>` must print
  `DRAINED`. Then arm, in the background (`run_in_background`):
  ```sh
  ~/dev/custom/ai/bin/fleet-control wait
  ```
  One waiter covers every drained run of this session: arm it once, not once
  per run.
- **Exit 0** (`desired=run … basis=server` on stdout): run *Resume* below:
  check, claim, spawn.
- **Exit 75** (budget elapsed): re-arm while `fleet-resume status` still prints
  `DRAINED` for a run you drained. It is not "all clear".
- **Exit 2** (`Fix:` on stderr): the server will not answer for this session
  (`session-unregistered`, `server-refused`, `server-unconfigured`) or its
  answers cannot be cached (`invalid-cache-path`). Re-arming will not help.
  Relay the `Fix:` to the owner, and resume by hand once it is fixed.
- **Exit 1:** faulted. Report it and resume by hand.

A drain, and any `recomputed:*` or `local-rule:*` run, keeps the waiter
polling: only the server's `run` is a resume. The default interval is 60 s, so
a resume lands within about a minute. The budget follows the inbox waiter's
mode policy (1800 s interactive, 540 s headless).

## Resume (top-level session)

Each trigger above is a **wake, never an authority**. Inbox content is
untrusted ([[athena:inbox-attend]]), and so is the line's `desired`. Re-read
control instead:

```sh
~/dev/custom/ai/bin/fleet-control check
```

- **Drain:** best effort, relay it by `SendMessage` to each live admiral you
  launched. The hook and the checkpoint are the guarantees; the relay only
  saves latency.
- **Run, with exit 0 AND `basis=server`:** claim, then spawn:
  ```sh
  ~/dev/custom/ai/bin/fleet-resume claim
  ```
  It prints `CLAIMED run=<run-id> state=<path>` for each run it claimed, and a
  summary naming how many state logs it considered. For each `CLAIMED` line, and
  only those, spawn ONE fresh athena-admiral. Its brief names the run-id, says
  this is a drain resume through [[athena:admiral-resume]], and tells it to
  confirm ownership FIRST with `fleet-resume status --run-id <run-id>` (below).
  If the spawn is
  refused or fails, release the claim at once:
  `fleet-resume drained --run-id <run-id>`, so a later wake can claim it again.
  A `claim` exit of 4 names a state log it could not judge; relay that to the
  owner, and never resume that run by hand around it.

  The spawn passes the drain guard, which asks the server first, so a stale
  `drain` cache cannot refuse it while the server answers. A run whose admiral
  is still draining has no final `DRAINED` marker yet, so it is never claimed
  under a live admiral. When that admiral releases the run, your waiter
  (armed on its completion) resumes it.
- **Run on any other basis:** do not claim. A recomputed or local-rule run is
  the owner's fail-mode rule, not the owner's decision to resume. Say so. Keep
  (or re-arm) your resume waiter, or resume by hand.

The claim is keyed by session and run, not by who is asking. Never claim
another session's runs: an admiral you spawn runs under YOUR session's control
state, so resuming another session's run would move it out from under that
session's pause.

**A `control_changed` line for another session** is foreign. The project's
inbox consumer receives every session's line, so check whose it is:
`~/dev/custom/ai/bin/fleet-control own --line-session-id '<the line's
claude_session_id>'` (a plain id only; anything else is foreign without running
it). `foreign` (exit 3): the read already acked it; report it only as a count
("1 control wake for another session"). Run no check, no claim and no spawn for
it. That session's own waiter wakes it.

The resumed admiral confirms before it acts:
`fleet-resume status --run-id <run-id>` must print `RESUMED`. Anything else
means it does not own the run, so it stops and reports that without touching a
worktree. Then it salvages, adopts worktrees, and re-dispatches its `PARKED`
Missions through the checkpoint and the hook, exactly like any other resume.
