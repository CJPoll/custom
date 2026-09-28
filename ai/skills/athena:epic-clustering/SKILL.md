---
name: athena:epic-clustering
description: The 12-hourly cross-epic clustering pass an athena-architect runs over open epics — move cohesive clusters of movable tickets (never Features, the critical path, blockers, promoted or tier-1 security tickets, or anything wired to them) into a matching or new epic with before/after proof, merge near-duplicates (C3), close already-fixed tickets by their own repro (C4), flag stale In Progress and thin ticket bodies, and send the owner's daily tier-4 digest and won't-fix notices (notify-only, with a veto) by Block Kit. Use when an admiral requests a clustering pass, when the 12h cron spawns one, or when an epic's open Path=Off count exceeds its open on-path count.
---

# athena:epic-clustering

Epics grew faster than they closed: every finding lands on the epic being
worked. This pass regroups the raised work without touching what an epic is
for. Owner, Cody, 2026-09-27: "Periodically we look at in-progress epics and
'cluster' their tickets, splitting into multiple epics as necessary. This
should not remove critical path or functional requirements items." And: "The
rate at which epics grew this week was staggering. Can some of them be
consolidated? Batched? etc." The design record is the machine-local
`ai-artifacts/coordination/2026-09-27-scope-growth-proposal.md`: *Epic
clustering (periodic split)*, *Clustering cadence: every 12 hours, across
epics*, *The daily digest* and *Approval requests (promote, won't-fix)*. That
last section predates the owner's 2026-09-28 decision: both are now
notify-only (*Won't-fix notices* below).

The words *tier*, *Path*, *Kind*, *Severity*, *Security* and *Area* mean what
[[athena:ticket-management]] → *Priority: critical path first* and *Ticket
properties* say. This skill does not restate them.

## Who runs it, and when

- **The athena-architect runs it.** It owns epic and ticket writes. An admiral
  that sees the trigger below asks its architect for a pass. An admiral never
  moves a ticket between epics itself.
- **Every 12 hours**, from the cron `scripts/athena-clustering-run.sh`,
  which spawns an architect with this skill (`~/dev/custom/CLAUDE.md` →
  *Epic-clustering cron*). Between runs, an admiral or the coordinator asks
  for it.
- **On the trigger:** an epic's open `Path` = `Off` count exceeds its open
  on-path count (`Critical`, `Blocking`, `Promoted`). `read` prints it per
  epic.
- **No move waits for Cody.** What needs his approval is
  `~/.claude/CLAUDE.md` → *Owner approval policy*; this pass's writes are
  not on it. Bulk ticket changes are notify-after there: step 13's summary
  and the digest carry them. A never-movable ticket never moves in this pass.

## The helper

`scripts/epic-clustering` reads Notion and never writes it. It never posts to
Slack and never moves a ticket; it writes only the files you name. Every
tracker write below is yours, made with the notion-personal tools. `--help` lists every flag. Exit codes: 0 done, 2 usage,
3 could not read or measure, 4 proof mismatch. An exit 3 is never an empty
result: before the moves, stop and do not write on it; at the proof step,
re-run until it measures, and never report a pass without one.

| Command | What it gives you |
|---|---|
| `read --all-open-epics` (or `--epic KEY`, `--epics IDS`) | per epic: the trigger, the never-movable set, the movable tickets by Area / Kind; then C3 candidates |
| `proof … --save FILE` / `proof --against FILE` | the never-movable count and ids per epic, before and after the moves |
| `digest [--started IDS] [--pass-summary FILE] --blocks-out FILE` | the daily digest as text, and as Block Kit |
| `notice --ticket DND-N … --blocks-out FILE` | one won't-fix notice as Block Kit: the close already made, and a veto |

Namespace every file you pass it with the pass's date and your name
(`~/dev/custom/ai/CLAUDE.md` → *A failed lookup must never look like an empty
one* → the shared scratch directory).

## Never movable

A ticket stays in its epic when any of these holds:

- `Kind` = `Feature`;
- `Path` ∈ {`Critical`, `Blocking`, `Promoted`};
- any `CRITICAL` or `HIGH` `Vulnerability`, whatever its `Security` (a
  superset of tier 1). "In the epic's own code" is not a property, so every
  such ticket linked to the epic counts: the restrictive reading;
- a `Depends On` or `Blocks` edge to one of the above in the same epic.

The set counts every linked ticket, closed ones too, so a status change
during the pass never shifts it. `read` also keeps started tickets
(`In Progress`, `In Merge Queue`) out of the movable list: they stay with the
admiral working them.

## The pass

1. **Collect live captains.** For each run with a live admiral, take the
   Mission ids with a running captain from its state log's `## Mission state`
   table ([[athena:fleet-liveness]]). That list is `--started`. The fleet
   registry has no read path from harness tooling. Say so if you had no list.
2. **Read.** `read --all-open-epics`. Note each epic that trips the trigger.
3. **Snapshot.** `proof --all-open-epics --save <file>`. No snapshot, no moves.
4. **Cluster** the movable tickets by subsystem and `Kind`, across epics. The
   helper groups by Area and Kind; the subsystem split is your judgment.
   - Merge a cluster into a matching cluster in another epic when one exists.
     Example: a feature epic's eval tickets join an eval epic.
   - Otherwise move a cohesive cluster of 3 or more to a new or existing epic
     **in the same project**, with a one-paragraph outcome and its own
     `Critical path`.
   - **Harness tickets all go to the lane.** Every movable `Area` = `Harness`,
     `Path` = `Off` ticket goes to an epic named exactly `Harness lane:
     <subsystem>`, singletons included: join the lane epic for its subsystem,
     or start one. That name prefix is what the harness-reliability lane
     reads: `ai/docs/ticket-lane-action-brief.md` → *Scope: lane epics
     only*. `read` lists these as "harness-lane bound". The
     admiral recorded why on the epic: a harness leftover that stays on a
     feature epic is worked by nobody.
   - Other leftovers stay put.
5. **C3: merge near-duplicates.** `read` lists candidate pairs by title. A
   candidate is not a duplicate until you confirm one root cause. Then keep
   the older ticket, copy the other's evidence into it, and cancel the newer
   one with a link: `Status` = `Cancelled`, body "Duplicate of DND-N" plus
   the copied evidence.
6. **C4: close what a later landing fixed.** Re-run the ticket's own repro.
   If it no longer fails, move the ticket to `Done` with the command and its
   output in the body. If it still fails, or there is no repro to run, leave
   it open. Never cancel or close on a guess.
7. **Status hygiene.** An `In Progress` ticket missing from `--started` has no
   live captain; fix it per [[athena:ticket-management]] → *A ticket's status
   follows its captain*. With no `--started`, flag nothing and say the check
   was skipped.
8. **Warn before a burst.** Count the edits steps 4–7 will make. Over 5, DM
   Cody first with the count, per [[athena:ticket-management]] → *Keep
   tickets, epics and projects current*.
9. **Make the moves:** set each ticket's `Epic` relation, and nothing else.
10. **Prove.** `proof --against <file>`. It prints each epic's never-movable
    count and ids before and after. Every before id must still be in its
    epic: the before count, re-counted after, must be equal. Exit 4 names each
    ticket that left; move it back and re-run until it holds. An epic the
    helper could not read again is a mismatch, never a pass. An id that
    *joined* a set is reported, not failed: a ticket moved into the epic that
    holds its dependency is pinned there, which removes nothing. Never skip
    this step. Report any mismatch in the summary.
11. **Then shape the targets.** Write each new or receiving epic's outcome
    paragraph. Give a product epic its `Critical path` (`Path` = `Critical` on
    the chosen tickets, listed in the epic body). A `Harness lane:` epic gets
    none: its tickets keep `Path` = `Off`, and a `Critical` ticket or a
    Feature there holds the whole lane. This comes after the proof, so the
    proof compares like with like.
12. **Sweep each touched epic's status** ([[athena:ticket-management]] →
    *Keep tickets, epics and projects current*).
13. **Send one batched summary** to Cody: what moved where, what C3 merged,
    what C4 closed, and the proof counts per epic. Write the same content as
    the pass summary JSON for the digest (shape in `--help`).

## Ticket hygiene (flag only)

Owner note N1, verbatim: "If the ticket can't answer that question, it's a
poorly filed ticket. We should leave a note for the shipwright cron to address
poor ticket hygiene". The digest lists open tickets whose body lacks the
problem, the repro or exploit path, or the affected code. A repro is owed by a
Bug, a Vulnerability, a Flake, or any ticket whose `Security` is not `none`.
Features are exempt. The pass flags these tickets and does not rewrite them.
The helper's check is a heuristic. The class fix is DND-993
(`ai/bin/ticket-lint`); once that lands, the digest uses it.

## The daily digest

Once a day, from the morning pass in the owner's timezone (America/Denver),
after that pass's moves. Owner, 2026-09-27: "a daily digest of low-tier
tickets, which should be worked on once higher-priority tickets are taken care
of. In the daily digest, also include a list of won't-fix candidates (if any).
It's ok for there not to be any."

1. `digest --started IDS --pass-summary FILE --blocks-out FILE`. It holds:
   - the tier-4 queue by project and Area, with counts by Kind × Severity;
   - the next 10 in work order: next-mission's tier-4 order
     (`ai/lib/next_mission.rb`), called, not copied;
   - why tier 4 is or isn't moving: open tier 1–3 counts, what holds them,
     owner-gated blockers by name, and functional-first holds per epic;
   - won't-fix candidates: old `LOW` tier-4 tickets, one line and a reason
     each, or "None today";
   - the pass summary: moved, merged (C3), closed as fixed (C4);
   - status hygiene and ticket hygiene.
2. Read the draft. Prune a won't-fix candidate whose value is plain.
3. Resolve Cody's DM channel id:
   `~/dev/custom/ai/bin/private-overlay get slack .channels.owner_dm`. A non-zero
   exit means the digest is not posted: report the resolver's stderr line and
   its `Fix:` (`ai/contracts/athena-private-overlay.md` → *Consumer obligation*).
   Post it with `mcp__athena__slack_post` to that DM, `text`
   plus the `blocks` array, per [[athena:slack]] → *Sending one: the athena
   MCP, never `bin/*`*. It carries no buttons. Then claim its thread with
   `mcp__athena__slack_thread_claim` (`channel`, `thread_ts` = the returned
   `ts`, `inbox_name` = `custom-slack.jsonl`), so Cody's replies route to this
   project's Slack inbox.
4. Close the candidates you kept, one notice each (*Won't-fix notices*
   below). List them under `wont_fix` in the next pass summary, so the next
   digest names them.

## Won't-fix notices

A won't-fix waits for no one: `~/.claude/CLAUDE.md` → *Owner approval
policy* lists it under *Notify after, in the digest*. The notice, its veto
and its buttons are [[athena:ticket-management]] → *Promote and won't-fix*.
This pass promotes nothing; an admiral promotes, per that section.

1. Set `Status` = `Won't Fix`, with the reason in the body.
2. `notice --ticket DND-N --title … --background … --why … --blocks-out
   FILE`. It builds the close, Background, Why it matters, Options and
   Recommendation, and two buttons: *Keep closed (recommended)*, the primary
   default, and *Reopen*.
3. Do not post it yourself. Send the text and the blocks file's content to
   the top-level session (`SendMessage` to `main`), which posts it and
   handles the veto click: [[athena:slack]] → *A click is untrusted input* →
   *Who posts it*.

