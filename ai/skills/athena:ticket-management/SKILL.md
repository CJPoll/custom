---
name: athena:ticket-management
description: The status ↔ assignee lifecycle for Notion tickets (Epics/Tickets DBs, DND-/PT-style IDs). Use whenever an orchestrator/athena-admiral takes scope of a ticket, or any status transition happens (In Progress / Needs Attention / Attention Given / Done / Ready for Release / Cancelled / Won't Fix / Parked / In Merge Queue). Defines who the ticket is assigned to at each status and how to resolve the Athena and Cody accounts for the ACTIVE Notion connection (notion-personal vs notion-work). Also the owner's priority tiers (promoted, exploitable vulnerabilities, blocking bugs, critical path, the rest), the ticket properties (Kind, Severity, Security, Path, Area, Found while), filing with dedupe, and promote/won't-fix (notify-only) — use when choosing which ticket to assign a captain next, or filing a ticket. Before filing a finding, run the finding-triage script for the Jev advisory (advisory only); when filing any ticket, run the ticket-classify script with your own Kind, Severity and Security and set the values it prints. To apply that classification to the open backlog, run the ticket-reclassify script (plan, apply, proof). Move a DND or work-tracker ticket to In Progress with the mark-in-progress script, which stamps its lead-time start.
---

# athena:ticket-management

The one rule to keep in your head: **the `Assignee` always names whoever currently
holds the ticket.** Athena holds it while it is actively being worked; Cody holds it
whenever it is waiting on him. Every status transition therefore also moves the
`Assignee` — never change status without reconciling the assignee.

Tickets are referenced by their `ID` (a `unique_id` property, e.g. `DND-29`).
Always refer to a ticket as `<PREFIX>-<number>`, never by raw page id.

## Status → Assignee map

| Status | Assignee | Meaning |
|---|---|---|
| `Backlog` | leave as-is until scoped | not yet in an athena-admiral's scope; on scope-in, normalize to `Todo` |
| `Todo` | **Athena** once in scope | in an athena-admiral's scope, queued; no engineer on it yet |
| `In Progress` | **Athena** | an athena-captain has been dispatched and is actively working it |
| `Needs Attention` | **Cody** | blocked on what needs Cody (`~/.claude/CLAUDE.md` → *Owner approval policy* → *Asking, and what counts as approval*), chiefly a step only Cody can run — put the exact step in the ticket body |
| `Attention Given` | **Cody** | Cody has answered; awaiting the owning athena-admiral to pick it back up (stays Cody until reopened) |
| `Done` | **Cody** | Cody's to review / verify / close |
| `Ready for Release` | **Cody** | work workspace only — a mobile ticket that has cleared dev but not yet the app-store process |
| `Cancelled` | leave as-is | dropped |
| `Won't Fix` | leave as-is | closed: not to be done (*Promote and won't-fix* below); reason in the body |
| `Parked` | **Athena** | work exists but is undelivered, and no captain is on it (*A ticket's status follows its captain*) |
| `In Merge Queue` | **Athena** | its PR passed review, critic and CI, and waits in a merge queue for its turn, or is merged and not yet verified live (*A ticket's status follows its captain*) |

## The transitions an orchestrator performs

1. **Taking scope** — when an orchestrator is handed a ticket or a set of tickets, it
   takes ownership: set each ticket's `Assignee` = **Athena**, and if the ticket is in
   `Backlog`, move it to `Todo`. A scoped ticket that no engineer is on yet sits at
   `Todo` (or keeps `In Progress` if it was already there).
   **Later (2026-09-27):** a ticket with no captain no longer keeps
   `In Progress`. It is `Todo`, or `Parked` if work exists (*A ticket's status
   follows its captain*).
2. **Assigning an engineer** — when an athena-captain is dispatched to the ticket, move
   the status to `In Progress`; the assignee stays **Athena**. On a DND ticket
   or a work-tracker ticket, make the move with
   `~/dev/custom/ai/skills/athena:ticket-management/scripts/mark-in-progress --ref <TICKET>`.
   On a first dispatch (DND: from `Todo` or `Backlog`; work: from the statuses
   the private overlay names) the same write stamps the ticket's dispatch date
   (DND: `In Progress at`; work: the overlay's property, DND-1341); a
   re-dispatch keeps the first stamp. That
   date is the START of the ticket's lead time (owner decision, Cody,
   2026-09-30: lead time = captain dispatch → landed on main;
   `~/dev/custom/ai/docs/lead-time-tracking.md`). A move made any other way
   leaves no stamp, and `ai/bin/lead-time` then reports that ticket as
   could-not-measure. For an unstamped ticket whose first dispatch time is on
   record, add `--backfill --at <that time>`. With no private overlay a work
   ticket is refused (exit 3, nothing written): move it with the connector,
   and it has no start.
3. **→ `Needs Attention`** (only for what needs Cody; see the Notes rule) — set `Assignee` = **Cody**, write the exact step
   Cody needs onto the ticket body (that is the whole point of the status), and
   **DM Cody** as Athena that the ticket needs him (see the Notes "Needs Attention
   DM" rule). This is one of the three owner-notification events; it fires on the
   transition itself and applies to ANY ticket, epic or not.
4. **→ `Done`** — set `Assignee` = **Cody**. Only after the merge is CONFIRMED
   (`ai/bin/confirm-merged`) **and** the change is verified live where it runs.
   If only Cody can do the live check (Cody's login or password), move the ticket
   to `Needs Attention` instead, with the exact check on the body.
5. **→ `Ready for Release`** (work workspace only) — set `Assignee` = **Cody**.
6. **`Attention Given` → `In Progress`** — a ticket in `Attention Given` is still
   assigned to **Cody** (search for tickets Cody has answered by that status). Once the
   athena-admiral resumes it and moves it back to `In Progress`, **reassign to Athena**.

A scoped ticket is Athena's from the moment it enters scope (`Backlog`→`Todo`→
`In Progress` are all Athena). It flips to **Cody** only when it moves to a
waiting-on-Cody state (`Needs Attention`, `Attention Given`, `Done`,
`Ready for Release`).

## A ticket's status follows its captain (owner rule)

Owner, Cody, 2026-09-27: "There's a difference between a ticket being
unblocked vs in progress. An unblocked ticket that hasn't been started should
be "Todo", not "In Progress"." And: "Let's add a "Parked" status, indicating
progress has been made, but the ticket is incomplete (or at least undelivered)
and not actively being worked on. A ticket which is blocked on something from
me should be "Needs Attention" instead of "Parked"". This section is its one
home; other documents cite it by name.

- **`In Progress` means a captain is working it right now,** or its admiral
  is boarding the captain's finished PR (below). Unblocked alone is `Todo`.
- **When the captain stops** (a park, an admiral stop, or a merge not yet
  delivered):
  - work exists → `Parked`, Assignee Athena. The body names the branch, the
    head SHA and the PR;
  - blocked on Cody → `Needs Attention`, Assignee Cody (transition 3);
  - no work yet → `Todo`.
- **A captain's `DONE`** hands the ticket to its admiral, who holds it at
  `In Progress` while boarding it (*When the tracker lacks a status this
  skill names*). If the admiral stops first, the ticket is `Parked`.
- **`In Merge Queue`** (owner, 2026-09-27: "Please add an "In Merge Queue"
  status."): the PR passed review, critic and CI, and waits in a merge queue
  for its turn (the merge lock, or a coordinator train). The
  admiral sets it when it queues the PR (`athena:merge-boarding`). It counts
  as active, so the live-captain check exempts it. Out of the queue on a red
  gate or critic → `Parked`.
- **Merged but not yet verified live:** it stays `In Merge Queue` while the
  admiral verifies, then goes `Done`. If only Cody can verify it,
  `Needs Attention` (transition 4). If the admiral stops first, `Parked`,
  with the verify step on the body.
- **Merged and verified live → `Done`** (transition 4).
- **An admiral that stops or drains reconciles** every `In Progress` ticket in
  its scope by these rules before it ends ([[athena:fleet-drain]],
  [[athena:admiral-final-report]]).
- **The detector** (an `In Progress` ticket with no live captain) belongs to
  [[athena:epic-clustering]] → *The pass*. Its live-captain source is the
  state logs, passed as `--started`; the fleet registry has no read path from
  harness tooling.

Measured 2026-09-27: at the owner's pause, 73 tickets read `In Progress`. 17
had already landed and 29 were parked with no captain. `In Progress` was set
at dispatch and nothing reset it.

## Keep tickets, epics and projects current (owner rule)

Owner, Cody, 2026-09-26: "Yes, please keep projects, epics, and tickets up to
date." The owner reads Notion to see what is happening. A stale status misleads
him and raises nothing, so drift is a defect.

- **Tickets** follow the transitions above at the moment they happen. Moving a
  ticket to `In Progress` is part of dispatching its captain. Moving it off
  `In Progress` when the captain stops is *A ticket's status follows its
  captain*.
- **Epics.** Set `In Progress` when the first ticket starts. Set `Done` only
  when every linked ticket, follow-ups included, is `Done` or `Cancelled`. A
  follow-up filed under a `Done` epic moves the epic back to `In Progress`.
  On the DND Epics DB, `Status` is a `select`, not a `status`:
  `{"Status": {"select": {"name": "In Progress"}}}`.

  **Later (2026-09-27):** `Won't Fix` closes a ticket too, so an epic goes
  `Done` when every linked ticket is `Done`, `Cancelled` or `Won't Fix`. The
  owner made won't-fix a status (*Promote and won't-fix* below). `Parked` keeps
  the epic open. Match by option name, never by Notion's status group: a
  group's membership is edited in the UI, and it moved on 2026-09-27.
- **Projects** move with their epics.
- **Sweep the epic** against its tickets at each epic transition and when you
  resume. Before you trust an empty filter result, confirm the filter with a
  query that should match something.
- **Warn before a burst.** Each edit notifies Cody. Before changing more than
  about 5 tickets at once, tell him a burst is coming and roughly how many.

Measured 2026-09-26: five epics disagreed with reality. Three read `Todo` while
being worked, one read `Done` while its follow-ups were built, one read
`In Progress` with every ticket `Done`. A 45-ticket sweep then surprised the
owner with a couple dozen notifications.

## Priority: critical path first (owner rule)

**The principle behind the tiers.** Owner, Cody, 2026-09-27: "Our highest
priority is getting scope management and prioritization under control. I think
of development as having 3 concentric wheels, each inner one driving the next
outer one: 1. Ticket completion & Delivery (fantastic! dozens to hundreds per
day right now) 2. Project/epic delivery: things a customer (in this case
myself) wants; each is a bet for the outcome it achieves. 3. Company/personal
outcomes, driven by the projects/epics we deliver (revenue growth, personal
growth, etc.) Right now, wheels 1 and 2 are out of alignment; we're spinning
wheel 1 super fast, but we're not completing the functional requirements of a
project to get it to a point where we're getting actual outcomes out of the
work being done. Once we have the two inner wheels aligned and spinning right,
then we can start iterating on projects to get the actual company / personal
growth outcomes and achievements" Clarified: "Delivery of a _ticket_ is the
innermost wheel. Completion of a _project or epic_ is the second wheel."

The measure of success is epics reaching their functional requirements, not
ticket throughput.

Owner, Cody, 2026-09-27 (~10:30Z, coordinator terminal): "we prioritize the
critical path over side quests in a project, completing the findings and other
issues that have been raised after the critical path. Findings should only
block previous tickets if they truly prevent the work from completing the
intended requirements." Clarified ~10:40Z: "No, the rule does not intend to
consider an epic closed when critical path is done; but we should at least be
getting value out of an epic even while we're doing follow-ups and addressing
discoveries. And yes, I would argue that we should block a ticket that
introduces security issues, but should address discovered pre-existing security
issues after the critical path is complete." 2026-09-27, later the same day:
"We want to prioritize functional requirements first; if a bug is blocking
functional requirements (or indicates the requirements are not met), then it
should be prioritized. Highest priority: Exploitable security vulnerabilities.
Next: Bugs blocking functional requirements Next: Critical path, next: other
improvements." And: "Not quite right - findings do get a captain, but only
after the functional requirements are met." This section is its one home;
other documents cite it by name.

- **The critical path** is the planned tickets whose completion delivers the
  epic's intended requirements. Each carries `Path` = `Critical` (*Ticket
  properties* below), and the property is authoritative. The architect also
  lists them in the epic body under a `Critical path` heading, in dependency
  order, citing the property. A ticket not on the path is off it: a finding, a
  follow-up, a flake, or any other raised issue.
- **Deliver value early.** Sequence the path so it ships usable value early:
  shipped, live-verified increments. Follow-ups and discoveries continue after
  that and never hold the value back.
- **Functional requirements first, for now.** Owner, 2026-09-27: "For the
  moment, I want to have the admiral focus on fulfilling the functional
  requirements of this system and do less reliability work. Focus on the
  critical path to have all the functionality, and then we can address the
  work that is brought up in the process. We'll take a TDD approach to these
  features." "This system" is the epic *Athena: unified priorities, fleet
  visibility & session control*. Until the owner lifts it, reliability work
  raised along the way in that epic is off the path, filed and worked after
  the functionality ships, unless it blocks by the test below. Features follow `~/.claude/CLAUDE.md` → *TDD
  Workflow*.
- **Order: the tiers.** This decides which unblocked ticket an admiral
  assigns to a captain next. Take the lowest tier with a ready ticket.

  | Tier | Selector (*Ticket properties*) | Order within the tier |
  |---|---|---|
  | 0 | `Path` = `Promoted`: the owner's explicit order, or an admiral's promotion (*Promote and won't-fix*) | the owner's order first, then admiral promotions, oldest first |
  | 1 | `Kind` = `Vulnerability`, `Security` = `pre-existing`, `Severity` ∈ {`CRITICAL`, `HIGH`}: exploitable | Severity, then age |
  | 2 | `Kind` = `Bug` and `Path` = `Blocking` | just ahead of the ticket it blocks |
  | 3 | `Path` = `Critical` | the epic's dependency order |
  | 4 | everything else, once its epic's critical path is met | Severity (empty last), then the Kind order, then age (oldest first) |

  - **A blocker that is not a Bug** (`Path` = `Blocking`, another Kind, such
    as a gate flake that stops the path) sorts just ahead of the ticket it
    blocks, in that ticket's tier.
  - **Tiers 1–3 are never capped.** No cap on tier 4 is decided yet.
  - **Findings get captains once the functional requirements are met.** A
    finding raised while working an epic is filed on that epic. Once the
    epic's Features, its critical path, are met, its findings get captains
    in tier order. Exploitable vulnerabilities and true blockers go at once.
    Until then a tier-4 ticket is not ready, even for an idle slot; report
    the idle slot and what holds the path. An epic with no `Critical`
    ticket (a scope of raised issues) has met its path.
  - **Merges are not ordered here.** A finished PR boards per
    `athena:merge-boarding`, where a finished security fix goes first (*A
    finished security fix merges first*). Owner, ~10:45Z: "I'm not talking
    about the merge queue; I'm talking about the order in which an admiral
    assigns tickets to captains."
  - **A free captain slot picks up `Parked` tickets too.** Owner, Cody,
    2026-09-30 (UTC), terminal: "Let's make sure that when we have free
    captains we pick up the parked tickets too." When a slot frees, the
    admiral's candidates are its own `Parked` tickets alongside its `Todo`
    ones, in the same tier order. `ai/bin/next-mission` already does this: a
    `Parked` ticket is a candidate unless `--started` names it, and within a
    tier it is resumed before a fresh one starts.
    - A resumed `Parked` ticket starts from the branch, head SHA and PR its
      body names (*A ticket's status follows its captain*). The captain's
      brief carries all three; never a fresh branch.
    - `Needs Attention` stays Cody's. It is never a candidate.
- **A finding blocks only if it truly prevents the work.** The test: does the
  planned ticket fail its acceptance criteria or intended requirements without
  this fix? If yes, set `Path` = `Blocking` and wire `Depends On`↔`Blocks` onto
  that ticket. A Bug that shows a `Done` Feature's requirement is unmet blocks
  too: reopen that Feature to `Parked` (its work exists; it goes `In Progress`
  when a captain takes it) and wire the edge. If no, file it
  with `Path` = `Off` and **no** `Depends On` / `Blocks` edge onto a
  critical-path ticket. Severity alone does not make a finding block. Edges
  between off-path tickets are fine. For a finding on an epic, `ticket-classify
  --epic` decides this Path and edge (the Classify bullet in *Filing a
  ticket*); your `--blocks` claim is its input.
- **Security, split by origin.**
  - **A security issue the ticket's own change introduces blocks that ticket,**
    whatever its severity. It is fixed inside that ticket's work, before it
    ships: a change that introduces a vulnerability does not meet its
    requirements. It never enters the queue separately.
  - **A pre-existing exploitable one (`CRITICAL`/`HIGH`) is tier 1.** It goes
    ahead of the critical path with no Slack ask. This supersedes the owner's
    ~10:50Z answer ("Assume no, but ask in slack for approval to prioritize an
    important fix"). Owner, same day, asked whether tier 1 supersedes it:
    "2. yes".
  - **A pre-existing `MEDIUM` or `LOW` one is tier 4.** When its turn comes
    it is worked with no owner wait. If an admiral thinks a `MEDIUM` one is
    urgent, it promotes it itself (*Promote and won't-fix* below) and keeps
    working.
  - `~/.claude/CLAUDE.md` → *Owner approval policy* governs **approval**, not
    **scheduling**. A security fix ships without waiting for the owner; when it
    is worked is decided here.
- **What else keeps its priority:**
  - **A fleet-wide flake or outage that stops the critical path itself**, such
    as a gate flake that reddens every merge. It blocks by the test above.
  - **An owner-directed priority** is tier 0.
- **A lane whose scope is raised issues** (the flaky lane) has no planned path
  to defer to. Its queue is its path, and it drains per its brief.
- **The harness lane (P7).** A ticket with `Area` = `Harness`, `Path` = `Off`
  or unset, that is not a `Feature`, belongs to the harness lane. A feature
  admiral files it and does not start it. It keeps a harness ticket with
  `Path` = `Promoted`, `Blocking` or `Critical`, a planned `Feature`, and a
  tier-1 vulnerability. `ai/bin/next-mission` enforces this split. The lane
  works its own queue in the same tier order. Its scope (`Harness lane: `
  epics) and its cap are in `~/dev/custom/ai/docs/ticket-lane-action-brief.md`
  → *The harness lane — the second instantiation*.
- **Epic status is unchanged.** The epic still goes `Done` only per *Keep
  tickets, epics and projects current* above: every linked ticket, follow-ups
  included, `Done`, `Cancelled` or `Won't Fix`. A finished critical path does
  not close the epic.

**Later (2026-09-28, DND-979):** this section, as DND-978 and the owner
approval policy landed it, said three things the tiers above replace:
- "**Order.** Within a project or epic, the critical path goes first", a flat
  order. Now tiers 0–4, and findings wait for the epic's functional
  requirements.
- "The architect names them in the epic body under a `Critical path`
  heading": the list was the authority. Now the `Path` property is, and the
  epic-body list cites it.
- "A pre-existing security issue found during the work is filed and fixed
  after the critical path by default … whatever its severity", with
  "Promoting one needs no approval": the admiral promoted a high-severity or
  exploitable one on its own judgment. Now a pre-existing `CRITICAL`/`HIGH`
  one is tier 1 with no promotion, and an admiral may promote a `MEDIUM` one
  per *Promote and won't-fix* below.

The owner set the tiers on 2026-09-27; the quotes are at the top of this
section.

### Ticket properties

The DND Tickets data source carries these. The values are stated here once.

| Property | Type | Values |
|---|---|---|
| `Kind` | select | `Feature` · `Bug` · `Vulnerability` · `Hardening` · `Refactor` · `Test` · `Flake` · `Docs` · `Ops` |
| `Severity` | select | `CRITICAL` · `HIGH` · `MEDIUM` · `LOW` |
| `Security` | select | `none` · `introduced` · `pre-existing` |
| `Path` | select | `Critical` · `Blocking` · `Promoted` · `Off` |
| `Area` | select | `Product` · `Harness` |
| `Found while` | relation → Tickets | the ticket being worked when it was found |

- **`Kind`** names what the ticket is. How it was found is `Found while`;
  where the fix lands is `Area`. So a bug in a gate is `Bug` + `Harness`.
  - **Feature:** a planned functional requirement the architect authored.
  - **Bug:** it does something other than its requirements or intended
    behaviour: a wrong result, a crash, a lost event, a miss that reads as
    success.
  - **Vulnerability:** a concrete security defect with a nameable path, or a
    security control that misreports.
  - **Hardening:** makes an attack or a failure harder or less damaging, with
    no concrete defect shown.
  - **Refactor:** structure, not behaviour: architecture drift, dead code,
    duplication, naming.
  - **Test:** missing or weak tests, or test infrastructure, with no known bug.
  - **Flake:** a non-deterministic test; its own lane (`athena:flaky-ticket`).
  - **Docs:** doc, contract or prose drift, no behaviour change.
  - **Ops:** infra, deploy, retention, capacity or cost work, no defect.
  - **One Kind per ticket.** When two fit, take the first in this order, which
    is also tier 4's Kind order: Vulnerability > Bug > Feature > Hardening >
    Test > Refactor > Ops > Docs. A Bug that leaks data is a Vulnerability.
  - **Bug or the rest?** Ask "does it do something wrong today?" Yes is Bug
    (or Vulnerability). "It could be better" is Hardening, Refactor, Test,
    Docs or Ops.
- **`Severity`** (empty on a Feature). Rate the harm the ticket shows now,
  not its worst case. The levels already place a risk that has not
  happened, so never lower a level again for it. Rate a security exposure
  with a real path by that path, used or not. Otherwise, when two levels
  fit, take the lower.
  - **CRITICAL:** prod down now, data loss, or an actively exploitable
    exposure. A risk of an outage, or a past outage cited as context, is
    not CRITICAL on its own; an outage still happening is.
  - **HIGH:** a wrong result or a security exposure with a real path and no
    workaround, or it stops the fleet (a red main, or a red gate every
    change needs). Also a prod capacity or availability defect shown to
    exhaust a shared resource prod depends on, even while prod is up.
  - **MEDIUM:** a wrong result with a workaround, or a silent-failure class.
    Also a failure the code can already produce but has not yet.
  - **LOW:** hygiene, dead code, docs drift, cosmetic (a misleading message
    with a correct exit code), or defence in depth with no shown path: a
    check gap when nothing it misses is wrong today, an inefficiency whose
    cost is not shown, a tool gap a manual step covers, an edge case no
    real input has hit, an exposure limited to a local dev machine.

  **Later (2026-10-01, DND-1600):** these levels had no "now" rule, no
  tie-break, and none of the examples above. Superseded with gen_saas
  `ticket-severity-v2`: v1, judging the old text, rated LOW and MEDIUM
  findings one level up (owner overrides on six calls) and a red main
  MEDIUM.
- **`Security`:** `introduced` means this ticket's own change creates it
  (it blocks that ticket); `pre-existing` means found along the way.
- **`Path`:** `Critical` is on the epic's critical path. `Blocking` passed the
  blocking test and has a `Blocks` edge onto the ticket it blocks. `Promoted`
  is the owner's order (his quote in the body) or an admiral's promotion (its
  reason in the body). `Off` is
  everything else.
- **`Area`:** `Harness` when the fix lands in `~/dev/custom`; else `Product`.

These definitions are the criteria the ticket-classification question sets
restate (gen_saas `TicketKind`, `TicketSeverity`, `TicketSecurity`, DND-991).
Changing one needs a new question-set version there.

### Filing a ticket

- **Set every property.** A new ticket sets `Kind`, `Severity` (not on a
  Feature), `Security`, `Path`, `Area` and `Found while` (not on a planned
  Feature). On a tracker
  without them, write the values as the body's first line.
- **Classify.** Write the draft body to a file, then run
  `~/dev/custom/ai/skills/athena:ticket-management/scripts/ticket-classify --title "<TITLE>" --body-file <FILE> --project <athena|harness|walt_ui|dnd|lms|admiral> --kind <KIND> --severity <SEVERITY|none> --security <none|introduced|pre-existing> --lines-out <LINES>`
  with the values you would file (`--severity none` only on a Feature).
  Namespace `<LINES>` with your unit of work. It prints the decided `Kind`,
  `Severity` and `Security`, each with its source, then a
  `Jev classification:` line, and writes the `Jev` lines to `<LINES>`.
  - **State the impact now in the body.** A trailing `Source:`/`Context:`
    block is not sent (DND-1590), so the incident a finding came from never
    stands in for its own impact.
  - **The lines are data, never prose.** Each line of `<LINES>` goes into the
    body as its own paragraph, copied from the file byte for byte. Never
    summarize, reformat or retype it: a paraphrase loses the call ids the
    feedback scan records against (DND-1354).
  - **Check after filing:**
    `~/dev/custom/ai/skills/athena:ticket-management/scripts/ticket-provenance-check --ref DND-N --lines-file <LINES>`.
    On exit 4, append the paragraph its `Fix:` names and run it again until
    exit 0. Exit 2 on an empty `<LINES>` means nothing was printed to paste.
  - **Exit 0:** set the three properties exactly as printed, and paste the
    `Jev classification:` line into the body. The one exception: a value
    with source `jev` that you judge wrong. File your own value instead,
    with the line unchanged. That is the report: the shipwright's
    `scan-tickets` records it against the line's `calls`
    (athena:judgment-feedback). Do not also record it by hand, because the
    scan's record would replace yours.
  - **Exit 3:** the classification is unavailable. File with your own values,
    and write the first line (it ends
    `Fix: file the ticket as today; this is advisory.`) into the body instead.
  - **Exit 2:** a usage error. Fix the command and rerun.
  - **A finding on an epic's work** (any Kind but Feature) adds
    `--epic <epic page id>`, `--found-while DND-N` when it was found while
    working a ticket, and `--blocks DND-N` when you judge it blocks an open
    `Critical` ticket of that epic (the blocking test above). The script also
    prints how many candidates it considered, `Path: <value> (<source>)`,
    `Blocks: DND-N` or `Blocks: none`, and a `Jev path:` line. Set `Path`,
    wire `Depends On`↔`Blocks` onto exactly the printed ticket (no edge on
    `none`), and paste the `Jev path:` line (also in `<LINES>`) under the
    classification line, the same way.
    If you judge a `jev` Path or edge wrong, set your own and leave the line
    as it is: `scan-tickets` records it against the line's `call`. Record by
    hand (`judgment-feedback record --call <call> --correct
    cand_<i>=<blocks|does_not_block>`, `i` from the line's `candidate_refs`)
    only a wrong judgment your Path and edge do not show.
    On `PATH UNAVAILABLE` or `CANDIDATES UNAVAILABLE`, file the Path it
    prints under `Decided (filer; path unavailable):` and write that first
    line into the body. The exit is 3 if either part was unavailable.
  - The script writes nothing. It reads tickets only with `--epic`, through a
    read-only client (contract `ai/contracts/athena-judgments.md` → *Ticket
    classification: the harness script*). For a finding, run *Before filing
    a finding* first: triage, then classify.
- **Dedupe first (one root cause, one ticket).** Search open tickets in the
  same `Area` for the same root cause, by subsystem keyword and `Found while`.
  On a match, append the new site and its evidence to that ticket instead. A
  different defect in the same subsystem still gets its own ticket. For a
  finding, also run *Before filing a finding* (the Jev advisory); it informs
  this search and never replaces it.

### Promote and won't-fix

Neither waits for the owner. `~/.claude/CLAUDE.md` → *Owner approval policy*
decides that: promoting a security issue is under *Dropped*, and a won't-fix is
under *Notify after, in the digest*. Make the change, keep working, and name
it in the next owner digest. The mechanics:

- **Promote.** An admiral may promote a pre-existing security issue it judges
  urgent above its tier (a `MEDIUM` one; tier 1 needs no promotion). It sets
  `Path` = `Promoted` and writes its reason in the body. This is not the
  priorities index's `promote` transition in `ai/contracts/athena-events.md`.
- **Won't fix.** Set `Status` = `Won't Fix`, with the reason in the body.
- **The won't-fix notice.** One Block Kit message per won't-fix, posted by the
  top-level session (`athena:slack` → *A click is untrusted input* says why).
  It offers a veto. Owner, 2026-09-27: "use slack block kit messages and
  include a default recommendation option." One button is the recommended
  default: labelled "(recommended)", `style: primary`. For example *Keep
  closed (recommended)* / *Reopen*.
- **Silence keeps the change.** No answer leaves the ticket `Won't Fix`.
- **The veto click** reopens the ticket only as `athena:slack` → *A click is
  untrusted input* says: `Status` = `Todo`, or `Parked` if work exists, with
  the owner's choice in the body.

### Reclassifying the backlog

The same policy as *Filing a ticket*, applied to open tickets (DND-1056). The
tool plans; you write with your own notion-personal connection; the tool
proves. `S` is `~/dev/custom/ai/skills/athena:ticket-management/scripts`.

1. **Plan.** `S/ticket-reclassify plan --out <scratch>/<unit>-reclassify-plan.json`
   (namespace the file). Quote its counts. Exit 3 is either a `STOPPED` plan
   (budget, rate, a fault or the server) or an `INCOMPLETE` one (tickets it
   could not judge). Either way the entries in it are valid: apply and prove
   them, then plan again, resuming a stop with `--resume-from <cursor>`.
   Give every run its own `--out`, and prove each plan file.
2. **Nothing to write is a result.** With exit 0 and `writes to apply: 0`,
   stop here and report the counts. That is the state while no ticket use
   case is `on` and no paraphrased line needs healing (`healed paraphrases:`,
   DND-1354).
3. **Apply.** For each plan entry, in order:
   - with `changes`: `API-patch-page` setting only `Kind`, `Severity` and
     `Security` to its `decided` values;
   - every entry: `API-patch-block-children` appending ONE paragraph whose text
     is exactly its `provenance_line`.
   Touch nothing else: never `Status`, `Path`, `Area`, `Epic`, `Assignee`,
   edges or title. On a 429, wait its `retry_after` and retry; a 429 is never
   done.
4. **Prove.** `S/ticket-reclassify proof --against <plan>` until exit 0. Exit
   4 names each ticket and property still wrong.
5. **Re-plan.** Run `plan` again: `planned` and `unchanged` must be 0, except
   tickets someone edited in between (name them).
6. **Record.** Write the counts on the epic body and in the admiral's report.
   Bulk ticket changes are *Notify after, in the digest* (`~/.claude/CLAUDE.md`
   → *Owner approval policy*): no DM, no wait.

A ticket whose values differ from its last `Jev classification:` line was
edited by hand after the classifier wrote it. The plan skips it as `locked`:
the edit wins.

## When the tracker lacks a status this skill names

**The option set is per-tracker, and the statuses above are not guaranteed to
exist in the one you are on.** The personal DND tracker has no `In Review` and no
`Ready for Release`; the walt_ui work tracker has both. So the status you are
about to set is a *lookup*, and it can miss.

**Resolve the options before you set a status** — read the `Status` property's
option list off the data source (`API-retrieve-a-data-source`) rather than
assuming this skill's vocabulary. Do it once when you take scope, and record the
available set in the run's state log so every captain dispatched into that
tracker inherits it instead of rediscovering it.

When the status you would set does not exist:

1. **Never invent one.** Do not create an option and do not substitute a
   differently-meaning status (a captain's finished-but-unmerged work is not
   `Done`). Notion rejects an unknown option, but a *plausible wrong* one is
   accepted silently, which is worse.
2. **Hold at the nearest earlier status that does exist, and make the hold
   explicit.** On a tracker with no `In Review`: a captain finishing its work
   sets **no** status and leaves the ticket at `In Progress`; the **athena-admiral**
   makes the terminal move (`Done`) on confirmed merge. The captain says so in
   its report — "left at `In Progress`, no `In Review` on this tracker, terminal
   move is the admiral's" — so the holder is stated rather than inferred from
   silence.
3. **The assignee rule still binds.** `Assignee` always names whoever holds the
   ticket, even when the status cannot move to say so. If work is genuinely
   waiting on Cody and there is no status that expresses it, set `Assignee` =
   **Cody** and write the reason on the body — the assignee is the load-bearing
   signal, the status is the label.
4. **A missing option is a fact to report, never a silent skip.** A rejected
   status write, or an option list that comes back empty, is an error: surface it
   (report + state log) naming the tracker and the option you looked for. "I set
   no status" and "this tracker has no such status" must never read the same —
   per `~/.claude/CLAUDE.md` → *A failed lookup must never look like an empty
   one*.

## Before filing a finding

A **finding** is an anomaly you observed and are about to ticket (`~/.claude/CLAUDE.md`
→ *Find it, ticket it, fix it, verify it live*; that rule is unchanged). Before you
create its ticket, ask Jev whether it duplicates or relates to an existing one
(DND-713; contract `ai/contracts/athena-judgments.md` → *Finding triage: the
harness script*):

1. **Run the script.** Write the draft body to a file, then:
   `~/dev/custom/ai/skills/athena:ticket-management/scripts/finding-triage --title "<TITLE>" --body-file <FILE> --project <athena|harness|walt_ui|dnd|lms|admiral>`.
   It searches the DND tracker for candidates itself (same project, open or edited
   in the last 90 days, at most 20) and prints how many it considered, even 0.
2. **Paste its output verbatim** into the new ticket body under a heading
   **"Jev advisory (not a decision)"**. That includes an unavailable line.
3. **The filer decides.** A `duplicate` or `related` line is advice to check the
   named ticket, never a verdict. The advisory never blocks filing.
   **When the advice is wrong, record it** (DND-1468), per athena:judgment-feedback
   → *Recording a wrong judgment*. The `call:` line names the call; `cand_<i>`
   beside a candidate is its question. One command per filing, with every
   correction in it, since a second report from this machine replaces the first:
   - you file anyway after a `duplicate` advisory:
     `--signal filed_despite_advice --correct cand_<i>=<related|unrelated>`;
   - an advised `related` candidate is not: `--correct cand_<i>=unrelated`.

   A duplicate found later is recorded by athena:epic-clustering's C3 step,
   from this machine too, so its report replaces yours for that call.
4. **Never auto-close, auto-merge or auto-cancel** anything on the strength of it,
   the new ticket or the candidate. The script writes nothing to Notion.
5. **When it is unavailable, file as today.** Exit 3 prints one line ending
   `Fix: file the ticket as today; this is advisory.` While `finding_triage`'s
   mode is `off` every call prints `JUDGMENTS UNAVAILABLE: not_configured`. The
   owner's key exists (DND-711); the owner sets the mode, and `on` needs no
   eval or threshold (DND-1450). An unknown `--project` prints `domain_not_permitted`.
   `COULD NOT REACH SERVER` and
   `CANDIDATES UNAVAILABLE` mean the same for filing: file it.

Exit 2 is a usage error: fix the command and rerun. If the Notion search cannot
run on your machine, `--candidates-file` takes a JSON array of
`{"ref","title","summary"}` instead.

## Resolving the two accounts (per active connection)

Match the **active Notion connection** — use the `notion-personal` tools in the personal
workspace and `notion-work` in the work workspace. Never cross connections, and never
hardcode an account across workspaces; resolve it for the connection you are on.

**Athena** = the bot service account of the active connection. Resolve it live with the
connection's "get self" call (raw API: `API-get-self`) and use the returned `id`. Bots
**can** be set as a `people` value (verified).

**Cody** = the human owner of that workspace. Resolve dynamically; fall back to the known
ids below only for the connection you are actually on. If unknown, find the non-bot
person via `API-get-users`, or read a ticket's `created_by`.

| Connection | Workspace | Athena (bot) id | Cody (person) id |
|---|---|---|---|
| `notion-personal` | "Cody" | `a22b6502-92b2-4b22-978d-9a49895afc1b` | `a6557c85-7931-480b-9e68-7f7fb2d889a7` |
| `notion-work` | work | resolve via `API-get-self` | the roster below, else `private-overlay get notion .work.owner_person_id` |

The `notion-work` Cody id lives in `<repo-root>/.claude/agent-messages/roster.json`
as `notion_person_id`; the flaky-lane tooling already resolves it that way. This
repo is public, so the fallback is the private overlay:
`~/dev/custom/ai/bin/private-overlay get notion .work.owner_person_id`. A non-zero
exit leaves the assignment undone: report the resolver's stderr line and its
`Fix:`, and never pick a person by name (`ai/contracts/athena-private-overlay.md`
→ *Consumer obligation*).

## Mechanics (raw Notion API via the connection's tools)

- **Status is a `status`-type property.** Set it as
  `{"Status": {"status": {"name": "Done"}}}`. A `{"select": ...}` value is rejected with
  `"Status is expected to be status."`
- **Assignee is a `people`-type property.** Set it as
  `{"Assignee": {"people": [{"id": "<user-id>"}]}}`. Clear it with `{"people": []}`.
- Update with `API-patch-page` (page id = the ticket). Query a DB with
  `API-query-data-source`; find the owning DB/data-source ids by searching the connection
  (`API-post-search`) — they differ per workspace.
- A 404 "make sure ... shared with your integration" means the DB/page is not shared with
  the Athena integration yet — it must be shared (Connections → add Athena) before you can
  read or write it.
- **`API-create-a-comment` does not work — do not spend a call on it.** On every
  connection (`notion-personal`, `notion-work`, `notion-athena`) it returns
  `400 missing_version`: *"Notion-Version header failed validation: ... instead was
  `undefined`"*. The MCP server omits the header, so this is not something a caller
  can pass around — it fails before the request reaches your page id, so a well-formed
  call and a bogus one fail identically. **Property writes are unaffected**:
  `API-patch-page` (status, assignee) works fine; only the comment endpoint is
  broken. **`API-post-page` truncates a large input** (measured 2026-09-22: it
  silently cuts inputs around ~2,000 bytes → a JSON parse error), so a
  normal-length ticket/sub-page BODY cannot be created through it in one call —
  it is fine for the page's properties (title, relations) and a short body only.
  For a full-length body, create the page with its properties via `API-post-page`
  then write the body in chunks with `API-patch-block-children`; or fall back to
  `curl` with the connection's token and a `Notion-Version: 2022-06-28` header
  (the same fallback the comment endpoint needs). **Instead** of a comment, put
  the note where it will actually be read: append
  it to the ticket page body (`API-patch-block-children`), or record it in the MR/PR
  description and your report. Say in the report that the comment endpoint was
  unavailable, so the absence of a comment is never read as an absence of the note.
  [measured 2026-09-20; recurring since at least 2026-09-12 — two work-repo tickets, dnd-140,
  and DND-219 each rediscovered it]
  **It is already ticketed as DND-458. Do not file or propose another ticket for
  it.** DND-586, DND-641 and DND-755 are re-filings of the same defect. A report
  that hit it says "known, DND-458" and nothing more.

## Design sub-docs (the architect's deliverables live in Notion)

A fleet's design artifacts are **Notion sub-pages, not local files**. The
athena-architect creates three under the **epic** page and three under **each
ticket** page:

- **Product Requirements** — what the work must satisfy.
- **Architecture & Engineering** — domain grounding, the feature-model diagrams,
  the 5-bucket structure, and access control.
- **QA Plan** — the functional test specification (`athena:format:test-matrix`).

The epic-wide trio is the whole-scope context every ticket shares; the
per-ticket trio is that one ticket's design. A captain reads BOTH its ticket's
three sub-docs AND the epic's three.

Mechanics (raw Notion API via the connection's tools):

- **Create a sub-page** with `API-post-page`, `parent` = `{"page_id": "<epic or
  ticket page id>"}`, title set to the sub-doc name — this nests it under the
  epic/ticket page.
- **Write its body** with `API-update-page-markdown` (whole-page markdown) or
  `API-patch-block-children` (append blocks); **read** it back with
  `API-retrieve-page-markdown` or `API-get-block-children`.
- **Find them** by listing the parent page's children (`API-get-block-children`
  on the epic/ticket page id) and matching titles; reuse an existing sub-page
  rather than creating a duplicate.

Local markdown (a `ai-artifacts/specs/…` or `…/feedback/…` file) is NOT a source
of truth — at most an agent's ephemeral scratch. The Notion sub-docs are
authoritative.

## Notes

- The Epics DB holds one epic per athena-admiral scope; the architect creates the
  epic and its design sub-docs, and tickets link to it via the `Epic` relation
  and carry `Depends On`↔`Blocks` edges for sequencing. A finding gets such an
  edge onto a planned ticket only per *Priority: critical path first*.
- **A ticket has exactly one `Epic`.** Moving a ticket to another epic
  REPLACES its `Epic` relation; never append a second epic. A relation naming
  more than one page resolves the ticket's project as `failed`
  (`ai/contracts/athena-events.md` → *A ticket's project*), so gen_saas's
  resync logs `ambiguous_epic` for it every hour and its project is unknown.
  Measured 2026-10-01: an admiral added a second epic to DND-1027 at 16:02Z;
  the coordinator found it by the resync failures at 17:01Z.
- Put the *why* on the ticket, not just in chat — a `Needs Attention` ticket must carry
  the context Cody needs to decide, in its body.
- **Put a finding's evidence IN the ticket body, not only a path to it.** Copy the
  reproducer (probe bytes, command, failing output) onto the page. `ai-artifacts/` is
  gitignored and machine-local, and fleets run on more than one machine, so a cited
  `ai-artifacts/coordination/...` report is unreadable to whoever picks the ticket up
  elsewhere. A path is fine as a pointer beside the evidence, never instead of it.
  Measured 2026-09-27: HIGH security DND-926 cited a desktop-only report; the laptop
  captain could not read the probe, spent an Opus run reconstructing it, and the
  ticket was cancelled "reopen if the desktop's exact probe bytes differ". Same class:
  dnd-708's sweep over a desktop-only `ai-artifacts/session-agreements/` covered zero files.
- **Needs Attention DM to Cody (owner rule).** When a ticket moves to `Needs Attention`,
  DM Cody as Athena via the `athena:slack` skill (`~/.claude/skills/athena:slack/bin/dm`,
  Cody = `~/dev/custom/ai/bin/private-overlay get slack .people.owner.user_id`;
  a non-zero exit sends no DM, and the transition's report carries the
  resolver's line and `Fix:`) on that same transition — the one that already assigns Cody and
  writes the context onto the ticket body, so the DM rides on it. Applies to ANY ticket,
  epic or not. Slack-mrkdwn format (`<url|label>`, NOT markdown; `:notion:` + the ticket
  PAGE url):
  `:warning: :notion: <TICKET_URL|PT-NNN - Ticket Name> needs your attention — <one-line why>.`
  where `<one-line why>` is the same reason you wrote onto the ticket body. This is one of
  the three owner-notification events; the other two — an epic crossing 50% and an epic
  reaching 100% — are the **athena-admiral**'s, computed at merge time (see that agent
  def's "Epic-progress DM to the owner"). Athena no longer DMs on every merge.

  **Later (2026-09-28, ~07:15Z):** a ticket moved to `Needs Attention` for any
  decision Cody's input could settle, so this DM fired for approval asks too.
  Superseded by owner decision (`~/.claude/CLAUDE.md` → *Owner approval
  policy*): "I would prefer you not even dm me unless it's something that only
  I can run." `Needs Attention`, and so this DM, is now only for what that
  policy's *Asking, and what counts as approval* names. Any other decision is made on best
  judgement, recorded on the ticket, and listed in the digest.
