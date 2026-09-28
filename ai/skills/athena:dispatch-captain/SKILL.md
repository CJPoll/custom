---
name: athena:dispatch-captain
description: The checklist for building an athena-captain's dispatch brief — everything the brief must carry so a captain never has to ask (worktree path, Mission, domain context, reports-dir path, MR target branch, the admiral's own agentId as reply-to, the Notion status values, and the fleet-mode design sub-docs). Use each time you dispatch a captain into a prepared worktree. Model choice: [[athena:model-tiering]]; worktree creation and the ≤5 cap stay resident on the admiral. Also batch Missions for tier-4 tickets (up to 3 same-Area tickets, stacked, one slot) and the machine-capacity gate every dispatch passes (1-min load threshold, test-slot, lowering the cap on a load-based failure).
---

# athena:dispatch-captain

Front-load context generously — there's no one for a captain to ask later. Once
a Mission is unblocked and has a free slot (worktree already created via
`~/dev/custom/scripts/wt-preflight <branch> <repo>`, `PREFLIGHT OK` seen; cap
≤5 enforced by the admiral):

0. **Run the control checkpoint first:** `~/dev/custom/ai/bin/fleet-control check`.
   Exit 0 dispatches. Exit 3, or any other exit, dispatches nothing. If the
   spawn itself comes back refused with `is draining` (the drain guard hook),
   that is **PAUSE**: mark the Mission `PARKED`, never retry the spawn, and never
   do the captain's work in-line. Then run the drain protocol:
   [[athena:fleet-drain]].
   Exit 0 then passes the **machine-capacity gate** (*Machine capacity gates
   every dispatch*, below) before the spawn.
1. **Move the Mission's Notion status to `In Progress`** and set its `Assignee`
   to **Athena** (the active connection's bot — see [[athena:ticket-management]]).
2. **Dispatch an athena-captain, named uniquely and Mission-qualified** (e.g.
   `athena-captain-DND-398`) — never the bare role name. Several run
   concurrently; `ListAgents` can't disambiguate identical bare names, and a
   report aimed at one can silently misroute.

Give the captain, in the brief:

- **The worktree path.**
- **The Mission.**
- **Domain context** — prior decisions, related Missions, pointers into the
  codebase — **but NOT the architect's raw domain model**; the captain grounds
  in the Notion design sub-docs (below).
- **The absolute reports-directory path** for this run.
- **If this Mission's report file already exists** — a fix round, a re-dispatch,
  a second worker on the same Mission — say that the worker **owns the whole
  file, not just the section it appends**: its pass must leave the top-line
  status, the summary, and any head-SHA / "final commit" field describing **its**
  pass. A worker that appends a round and leaves the head alone produces a file
  whose opening lines contradict its own body, and the head is what a resumed
  reader greps first. Measured 2026-09-20 (`notif-platform`):
  `dnd-232-report.md` still opened "**Status: DONE.** Eight critic rounds
  resolved" with `Final commit: ace49df` while its body ran to round 20 at
  `78d5be9` — twelve rounds and a whole re-spec later, across three separate
  appending passes that each left the head untouched. A stale head SHA in a
  report is the failed-lookup class: it reads exactly like a working answer.
- **The MR target branch** (from your dependency map — the repo's default branch
  if this Mission has no unmerged dependency, otherwise the dependency's branch).
- **Your own `agentId` as the explicit reply-to.** A captain never told who
  dispatched it addresses its terminal report to the main session, which then
  has to relay it by hand (measured 2026-09-18: four captains in one run
  misrouted to the main session; the fix would otherwise have died with the run).
  The captain definition tells it to message "your athena-admiral by its agentId
  (it is in your brief)" — the bare role name bounces — so the brief is the only
  place that `agentId` can come from. Carry it next to the reports-directory
  path, and keep the precedence straight: **the file write is the delivery**, the
  message is the latency optimization (see [[athena:fleet-liveness]]).

  **You cannot look your own `agentId` up — it has to be given to you.**
  `ListAgents` reports the agents you can *send to* and says outright that the
  calling process "is not listed below"; there is no self-id anywhere in its
  output, and from inside your own process the only address you have is the
  bare word `main` for whoever spawned you. Your `agentId` exists in exactly one
  place: the **`Agent` tool result your dispatcher received when it spawned
  you**. So obtain it from your dispatcher — `SendMessage` to `main` asking for
  your own `agentId` — and do it **before your first captain dispatch**, not
  after a captain has already misrouted. Send the request and carry on preparing
  worktrees while you wait; never park a turn on it.

  **If you do not have it yet, say so in the brief — never omit the line.** A
  brief silently missing its reply-to is the case that misroutes; a brief
  saying *"no reply-to is available: write your report file and do not message
  anyone"* costs only the latency optimization, which was never the delivery.
  Fill the reply-to in on every brief from the moment your dispatcher answers.

  This is the *how* the rule above always assumed and never stated. Measured
  twice: 2026-09-18, four captains in one run addressed the main session; then
  again on 2026-09-20 `notif-platform` — *after* the requirement was already
  written here — where the state log records "reply-to misrouted to coordinator
  **again**" and the run was only repaired when the **coordinator supplied this
  admiral's `agentId`**, which is the one route the admiral could not take for
  itself. An instruction to carry a value nobody tells you how to get is the
  repo's *A claimed mechanism must be able to fire* class.
- **The Notion status values it needs** — specifically `In Review`, which it
  sets itself once its MR is open. Where the tracker has no `In Review`-
  equivalent, the brief must say **"set NO Notion status at all"**, never a value
  the DB cannot accept (see the substitution in [[athena:fleet-inputs]]).

- **The forge-identity rule, cited by name.** Every brief carries this line:
  *"Forge writes and pushes run as Athena: follow *Pushing as Athena* in
  **athena:github** (github.com) or **athena:gitlab** (gitlab.com) for every
  push, and **athena:github** → *When a forge
  write can't be done as Athena* when any forge operation can't run under the
  Athena identity; escalate to me, the admiral."* Cite it; do not restate the
  rule in the brief. A captain
  that pushes with a plain `git push` puts the owner's name on its work
  (measured 2026-09-23, every gen_saas branch push).

- **The bug-fix regression rule, cited by name.** Every brief carries this line,
  bug Mission or not, since any Mission can end up fixing a defect: *"Any bug
  fix follows the regression-test rule in `~/dev/custom/ai/CLAUDE.md` → *TDD
  Workflow*: record the test failing on the unfixed code, then passing, and put
  that evidence where the rule says."* Cite it; do not restate it. The standing
  judge blocks a fix commit without the evidence, so a captain who learns the
  rule from the critic pays a whole review round for it.

- **The findings rule, cited by name.** Every brief carries this line: *"An
  anomaly you find outside this Mission follows `~/dev/custom/ai/CLAUDE.md` →
  *Find it, ticket it, fix it, verify it live*: list it in your report as a
  proposed ticket with its `Kind`, `Severity`, `Security` and `Area`, and say
  whether this Mission fails its requirements without it; do not fix it in
  this MR."* Cite it; do not restate it. The properties and that answer (the
  blocking test, which sets `Path`) are [[athena:ticket-management]] →
  *Priority: critical path first*; you file the finding with them.

- **The no-stash rule.** Every brief carries this line: *"Never `git stash`. To
  park WIP, commit it to your worktree branch."* A linked worktree shares ONE
  stash list with the owner's main checkout (`refs/stash` lives in the common
  git dir), so a captain's `git stash pop` can pop the owner's entry. Measured
  2026-09-25 on walt_ui: a captain popped the owner's own stash entry
  (DND-670). The `git-stash-guard` hook denies every stash write; the line saves
  the captain the denied call. Once the owner activates DND-775, git itself
  refuses stash writes in agent sessions (the `agentstash` reference-transaction
  hook, ai/git-hooks/agent-stash-guard.sh) and the agent `git` wrapper
  (ai/agent-bin/git) refuses pop/apply/drop before git runs; the text guard
  retires after that is verified live.
- **The test-slot rule.** Every brief carries this line: *"Run every heavy gate
  — a full suite, `bin/prep-commit.sh`, `harness-gate`, `integration-gate` — as
  ONE Bash command that starts in your worktree: `cd <worktree> &&
  ~/dev/custom/ai/bin/test-slot -- timeout 1500 <cmd>`. For `harness-gate`,
  `<cmd>` is your worktree's own `./ai/bin/harness-gate`. Quote its `gating
  <root>` line with the result. Exit 75 with `test-slot: TIMEOUT` means it
  never ran: run it again; never count it as a pass."*
  `integration-gate` wraps its whole run, fetch included, in test-slot
  (DND-486, DND-1064); its
  own "never ran" is exit 6, `GATE NOT RUN`, and never a pass either. The
  captain definition's Verify step names test-slot. Nothing wraps a captain's
  other heavy runs mechanically, so this line is still what does.
- **Why the `cd` is in the same command.** A subagent's Bash cwd resets to the
  session root between calls, and that is often the main checkout. A gate
  named by its main-checkout path, or run after a `cd` in an earlier call,
  gates the main checkout. `harness-gate` refuses that run
  (`foreign_gate_tree`), so the attempt is lost, not wrong. Measured twice in
  two runs: DND-840/DND-896 (harness-epics-ab, 2026-09-26) and DND-864
  (slack-interactive, 2026-09-27, "It ran the main checkout's binary and was
  REFUSED").
- **Never put `timeout` outside `test-slot`.** `timeout 1500 test-slot -- <cmd>`
  counts the queue wait against the command's budget, so a deep queue kills a
  gate that never started (rc 124). Measured 2026-09-26: DND-814's harness-gate
  timed out after 900 s of its 1500 s spent queued, and DND-790's timed out with
  3/3 slots held and the gate never run. Bound the wait with
  `--wait-timeout` instead.
- **The one-command final check.** Every brief carries this line: *"Your
  final check is ONE command on your final commit: `cd <worktree> &&
  ~/dev/custom/ai/bin/test-slot -- timeout 1500
  ~/dev/custom/ai/bin/integration-gate --with-critic --rebase`. It runs the
  standing judge beside the gate, so it costs the slower of the two, not their
  sum. It refuses a dirty tree, and it records both receipts I land on. If
  main moved while it queued, it rebases your branch onto it inside the slot
  and gates the rebased head; push that head as Athena with
  `--force-with-lease` (`athena:github` → *Pushing as Athena*). Quote its
  INTEGRATION OK line. On a RED gate or a BLOCK, fix every finding from both
  in one round, commit, and run it again."* It replaces a separate
  `critic-review` then gate on the final commit (`athena:merge-boarding` →
  *Landing onto a moving main*).
- **The don't-chase-main rule.** Every brief carries this line: *"Your gate bar
  is ONE green gate on a head that contained `origin/main` when the gate
  started. If main moves after that, do not rebase and re-gate to catch it:
  report the gated SHA and the main it contained. I forward and re-gate the
  integrated head when it lands. The final check's `--rebase` absorbs a main
  that moved while you queued. If it refuses with REBASE CONFLICT, rebase onto
  `origin/main` yourself, resolve the named paths, commit, and run it once
  more; if it refuses again, stop and report. Rebase earlier only on a real
  conflict or when I ask."* This is the
  captain half of `athena:merge-boarding` → *Landing onto a moving main*; the
  merge bar is unchanged, since you still re-gate the integrated head under
  the lock. Measured 2026-09-26/27 (harness-epics-ab): DND-838 re-gated three
  times ("Main moved under each of them"), DND-785 ran `integration-gate`
  three times and never got a clean run, and DND-887 hit the same cycle. Two
  admirals then issued this rule by hand, mid-run (15:23Z to DND-497, 02:32Z
  to DND-785).

  **Later (2026-09-28, DND-1064):** the final check had no `--rebase`, and
  this line said "If the gate refuses because main moved while you queued,
  rebase once and run it once more". Superseded: `integration-gate` read
  `origin/main` before a test-slot wait that now runs 5-26 min, longer than
  the gap between landings, so the retry refused too (DND-907, DND-896+945 and
  DND-902 each refused twice on 2026-09-28). It now takes the slot first and
  reads main inside it, and `--rebase` replays the branch there.

**In fleet mode, also point it at the design in Notion** — its ticket page's
three sub-docs (**Product Requirements / Architecture & Engineering / QA Plan**)
AND the epic's three, which it reads for full context — as the design it
implements to. Tell it to run its Pass-2 review of that design against current
system reality and to raise any gap it finds **to you** (in its report),
non-blocking: it proceeds on best judgment while you carry the substantive gaps
to the architect. **Do NOT tell it to message the architect directly.**

**Pick the captain's model from the Mission's real complexity** — read the
Mission and the code it names, not its label. The captain defaults to
`model: claude-opus-4-8`; override to `model: "sonnet"` on the `Agent` call **only** for
bounded, fully-specified, tool-checkable work. Invoke [[athena:model-tiering]]
for the Sonnet-when-*all* / Opus-when-*any* criteria, the worked examples, and
the first-of-a-series rule. **Default to Opus whenever unsure** — a Sonnet
captain that goes STUCK is re-dispatched once under Opus into the same worktree,
which costs more than the tokens Sonnet saved — and **write the choice and its
one-line reason into the state log** next to the dispatch.

Every environment fact you put in the brief must be VERIFIED, not inferred —
see [[athena:brief-verification]].

## Batch Missions (tier 4)

Tier 4 is defined in [[athena:ticket-management]] → *Priority: critical path
first* (its tier table), which also sets when those tickets run. Owner, 2026-09-27: "findings do
get a captain, but only after the functional requirements are met." A batch is
how such tier-4 tickets get that captain cheaply. Do not batch any other tier.

- **What may be batched.** Up to **3** tier-4 tickets with the same `Area` and
  the same subsystem, given to ONE captain as one batch Mission. Same subsystem
  means the same skill, tool, or app module. That is your judgment, and nothing
  checks it; the aim is one context load for every ticket.
- **One slot.** The batch counts as one captain slot against the concurrency
  cap, however many tickets it carries.
- **One ticket, one change.** The captain delivers a stacked series: one commit
  (a repo that ships by fast-forward) or one PR (a forge repo) per ticket, in
  the order the brief lists them. Each ticket gets its own critic PASS, judged
  alone with `--base`. The critic may block bundled unrelated changes as
  `[scope]`. The batch saves the dispatch, the worktree and the context load,
  never the per-ticket review.
- **Landing: one ticket at a time, bottom of the stack first.** Each ticket
  lands only on its own `integration-gate` pass, per [[athena:merge-boarding]]
  → *Landing onto a moving main*. `integration-gate` reads only the verdict of
  the head it gates, so landing the tip alone would leave the lower tickets'
  verdicts unchecked. Never land a stack in one step.
  - **A repo that ships by fast-forward** (the captain's *Repos with no MR/CI
    system*): fast-forward main to ticket 1's head, then to ticket 2's, each
    after its own `integration-gate`. The heads already stack, so nothing is
    rebased.
  - **A forge repo, `~/dev/custom` included:** `locked-merge` squash-merges one
    PR into that PR's own base. So after ticket N lands, retarget PR N+1 to
    the MR target branch (`gh-athena pr edit <n> --base <branch>`, as in
    [[athena:captain-return]]). Then rebase it onto the landed squash with
    `git rebase --onto origin/<branch> <old head SHA of ticket N>`, and push
    as Athena. A plain rebase would replay ticket N's commits. A retarget alone
    starts no CI run; the push does.
  - A rebase rewrites the ticket's SHA and orphans its critic receipt. You
    re-run `critic-review` in the Mission's worktree for the new head, per the
    *On exit 3* bullet of [[athena:merge-boarding]] → *The merge bar*; the
    captain has ended by then.

The batch brief carries everything above for one Mission, plus:

- **The tickets, in stack order**, each with its own Notion page and design
  sub-docs.
- **The branches.** One worktree, one branch per ticket, each cut from the
  branch of the ticket below it. The worktree's own branch is the first
  ticket's. In a forge repo, each PR targets the branch of the ticket below it;
  the first targets the MR target branch.
- **The critic line:** *"Judge each ticket alone: on that ticket's head, run
  `~/dev/custom/ai/bin/critic-review --base <the branch of the ticket below>`
  (the first ticket: the MR target branch). Without `--base`, the diff is the
  whole stack."*
- **The gate line:** one heavy gate on the tip of the stack, per the test-slot
  line.
- **The report.** One file, named for the batch (e.g. `DND-539+538-report.md`),
  with one section per ticket: status, head SHA, the recorded critic verdict
  line, the PR URL (forge repos), files changed, and its own proposed findings.
  A STUCK ticket holds every ticket stacked above it; its section says so.
- **The Notion transitions, per ticket.** Move each ticket to `In Progress` with
  Athena as `Assignee` at dispatch. In a forge repo, the captain's `In Review`
  rule (or "set NO Notion status at all") applies to each ticket as its own PR
  opens. You move each ticket on its own landing.

**Precedent** (harness-epics-ab): 00:51Z, "DND-539+538 dispatched to one captain
… as stacked branches"; 01:07Z, "one ff lands 508+539+538". That was one
fast-forward of the tip, before `locked-merge` existed. It is history, not the
pattern: land one ticket at a time, as above.


## Machine capacity gates every dispatch

**Later (2026-09-26):** this section was *A `CONTENTION:` line lowers the cap
for the rest of the run*. Its *Not a probe* bullet forbade sampling load at
dispatch time, and a `CONTENTION:` line lowered one repo's cap. Superseded by
owner directive (Cody, 2026-09-26 ~14:15Z): "You have as many captain slots as
are enabled by the hardware (if you see load-based failures, lower the number of
captains)." The same directive gave a second machine its own pool. A load
reading now gates each dispatch but never picks a count, and a load-based
failure lowers the whole cap, because load is the machine's.

Captain capacity belongs to the machine. The resident cap of 5 is your ceiling;
below it, these rules decide.

- **Hold while the machine is loaded.** Immediately before each spawn (initial,
  refill, resume re-dispatch), after `fleet-control check` exits 0, read the
  1-min load: `cut -d' ' -f1 /proc/loadavg`. Over **12** (owner, 2026-09-26):
  do not dispatch. Keep the Mission `QUEUED`, log `Load <value> -> holding`, and
  re-read on your next sweep. At or under 12, dispatch and log `Load <value>` on
  the dispatch line. A load you cannot read is not load 0: hold, and tell the
  session that launched you.
- **A gate, not a count.** A reading clears ONE dispatch. Never turn it into a
  number of slots ("load 3, so dispatch four"). Load now says nothing about load
  forty minutes later, when several captains reach their suites at once. The
  reading does not cover that gap. Three things do: the cap of 5 bounds any
  burst, heavy runs queue through `test-slot` instead of colliding, and a
  load-based failure lowers the cap.
- **Heavy gates go through `test-slot`.** Wrap your own (`integration-gate`,
  `harness-gate`, a full suite) as `~/dev/custom/ai/bin/test-slot -- <cmd>`,
  always the main checkout's copy, so every fleet shares one pool. Give every
  captain the test-slot brief line. Exit 75 with `test-slot: TIMEOUT` means the
  command never ran.
- **A load-based failure lowers your cap by one** for the rest of the run, and
  you tell the session that launched you (it apportions the machine across
  admirals). Load-based failures: a captain's `CONTENTION:` line (captains
  attach a `~/dev/custom/ai/bin/contention-census` reading from the failure and
  the re-run), or a gate of yours that fails with Postgres `57014`, a timeout
  under load, or a kill, with a census reading taken at the failure. One
  lowering per report or failure. The cap only moves down; a new brief from the
  launching session is how it comes back up.
- **A gate that never left the `test-slot` queue is not a load-based failure.**
  Exit 75, or an rc 124 from a `timeout` wrapped around `test-slot`, means the
  command never ran, so it measured the pool, not the machine. It does not
  lower the cap and is not reported as a load failure. Tell them apart with
  `~/dev/custom/ai/bin/test-slot --status`: all N slots held with 1-min load
  under 12 means the pool is the limiter. Measured 2026-09-26 ~16:30Z: two
  fleets froze dispatch on "load-based failures" that were DND-814's queued
  gate timing out; one then read load 7.5 on 16 cores with 9 waiters. Pool
  size and FIFO order are DND-827 and DND-823.
- **The pool is per machine.** Another machine may have its own pool (a captain
  count its admirals share) or its own threshold. The launching session
  apportions it, and the share your brief names is your cap, as a lane brief's
  `{{MAX_CAPTAINS}}` is. With no share in your brief, 5 and 12 apply.
- **The docker address pool gates a stack-running dispatch.** `wt-preflight`
  runs `ai/bin/pool-headroom` before it creates a worktree for any repo whose
  worktrees run a stack, so `PREFLIGHT OK` means a subnet was free when it ran
  (a concurrent preflight can take it). A refusal names the `MERGED-BUT-UP`
  stacks with their `teardown-stack` line. Tear down your own fleet's, ask the
  owner of any other, re-run `wt-preflight`
  ([[athena:teardown-worktree-stack]]). Never create the worktree some other
  way to get past it.
- **Not a tolerance.** The red still blocks, the finding is still reported, and
  nothing is retried, skipped, or loosened — the standing rule is that a safety
  check gets FASTER, never weaker, and you carry it resident. The census
  makes contention *attributable*; it never makes a failure acceptable.

**Record the cap and where it came from** in the state log — `cap 5 — default`,
`cap 4 — brief share`, or `cap 3 — lowered by DND-213 CONTENTION` — with the
load reading on every dispatch line. Without the provenance, a cap you
chose and a cap that was forced on you read identically on resume, which is the
same failed-lookup trap one level up.

---

*Source (behavior-preserving relocation): athena-admiral §4 "Create worktrees
and dispatch work" (the dispatch-brief checklist). The worktree-creation rule
and the ≤5 concurrency cap stay resident on the admiral; this skill is the brief
contents. The admiral keeps a resident one-line trigger pointing here.*
