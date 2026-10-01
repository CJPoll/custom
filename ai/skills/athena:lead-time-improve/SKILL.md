---
name: athena:lead-time-improve
description: The procedure an athena-shipwright runs when its brief says `MODE: lead-time` (a lead-time improver run) — for each `improve` repo in ai/config/lead-time-repos.json, ingest the phase ledger, judge pending before/after experiments (keep, revert, pending, inconclusive; decline a revert the hard constraint forbids) with scripts/experiment, pick the biggest phase, act exactly once (one safety-preserving change, one instrumentation change, one architect, or no action), and journal; for each `watch` repo, the outlier scan and architect hand-off the shipwright ran before. Use whenever a brief or prompt says "MODE: lead-time" or "lead-time improver run".
---

# athena:lead-time-improve

You are an athena-shipwright in `MODE: lead-time`. This skill is your whole
run: no report mining, no owner-notes pass, no judgment-feedback pass. Design
record: `ai/docs/lead-time-improver.md` (*The improvement procedure*,
Decisions 2, 3 and 8).

## The hard constraint

Faster, never weaker: `ai/blocks/ops/safety-checks.md`, which you carry
verbatim as *Speed a safety check up; never weaken it*. It outranks every
speedup. Out of bounds:

- everything that block forbids;
- moving a bar: `~/.claude/CLAUDE.md` → *Owner approval policy*, item 5.

A candidate that needs either goes under *Decisions / Won't-change* with the
reason. It is never landed, and it is never your run's action.

## Setup

- **State dir:** `<main checkout>/ai-artifacts/lead-time` (gitignored), where
  `<main checkout>` is `dirname "$(git rev-parse --path-format=absolute
  --git-common-dir)"`. Both tools resolve it the same way. When your brief
  names another state dir, `export LEAD_TIME_STATE_DIR=<that dir>` before
  running any tool, so the tools and your journal agree. It holds
  `ledger.jsonl`, `cursor.<repo>.txt`, `experiments.jsonl`, `journal.md`,
  `watch-cursor.<repo>.txt` and `runs/`. Never derive it from your cwd.
- **Lane:** `athena:shipwright-lane` (*Where you run*, *Sync down first*).
  Every commit goes through its commit wrapper.
- **Read the journal first.** Its *Decisions / Won't-change* entries bind
  this run.
- **Repos and modes:** `ai/config/lead-time-repos.json`. Its
  `improvement_epic` is the epic an architect files tickets on.

Tools, from your lane (`<skill>` is `ai/skills/athena:lead-time-improve`):

```
ai/bin/lead-time-phases --ingest --repo R
ai/bin/lead-time-phases --summary --repo R --json
<skill>/scripts/experiment judge --repo R
<skill>/scripts/experiment record --repo R --phase P --metric M --commit SHA --kind change|instrumentation --hypothesis-file F
<skill>/scripts/experiment list --repo R
<skill>/scripts/experiment decline --repo R --id ID --constraint safety-checks|bug-fix --reason-file F
```

Each answers `--help`. Read an exit code before its output:
`lead-time-phases` exit 3 is SCAN INCOMPLETE; `experiment` exit 3 is "could
not look" (no ledger). Neither is "nothing to do". Exit 4 from either is
"configured, but its checkout is not on this machine"
(`ai/bin/lead-time-repos`): skip that repo this run and journal the skip.

## For each `improve` repo, in order

### 1. Ingest

`lead-time-phases --ingest --repo R`. Exit 3: nothing was ingested and the
cursor stayed. Exit 1 or 2: a tool, state or config fault. Either way,
journal it with the error line and take **no action** on R this run
("cannot measure: <why>"). Never act on a stale window as if it were
current. The same holds for an `experiment` exit 1, 2 or 3 in step 2.
Telemetry pruning is the runner's, not yours.

### 2. Judge pending experiments

`experiment judge --repo R`, before anything new starts. Per pending
experiment it prints `keep`, `revert`, `pending` or `inconclusive`, with the
before and after numbers, and records the verdict.

- **revert** (or a `REVERT OWED` line, repeated each run until main carries
  the revert): first test the revert against the hard constraint
  (`ai/blocks/ops/safety-checks.md`). If it would delete, skip or weaken a
  test or check, or reinstate a defect the commit fixed, do not land it. Run
  `experiment decline --repo R --id <id> --constraint <safety-checks|bug-fix>
  --reason-file <F>` and journal the decision under *Decisions /
  Won't-change* with the reason. Decline is bookkeeping, not the run's one
  action: after a decline, continue to step 3 as usual. `decline` refuses a
  revert that a worse guard drove (critic BLOCK rate, gate red rate,
  reverts), or one with a guard it could not measure: that may be a quality
  regression, so land the revert or hand a fix-forward to an architect.
  Otherwise this run's one action is a `git revert` of that experiment's
  commit, landed through *Landing* below. Skip steps 4 and 5. Judge records
  `reverted` once main carries it, and until then no new change starts on
  that phase. If two reverts are owed, land the first; the second is still
  owed next run.
- **declined** is never a gain. It no longer blocks its phase. Judge never
  writes it; only the `decline` verb does.
- **keep, inconclusive:** journal them. An inconclusive experiment no longer
  blocks its phase.
- **pending** is never a gain. Never report it as one.

### 3. Summarize

`lead-time-phases --summary --repo R --json`. Keep the JSON for the journal
and for an architect's brief.

### 4. Pick the biggest contributor

`biggest.phase` is the phase with the largest summed time in the window. When
it is null, no phase is measured: the action is instrumentation for the phase
whose n/a reasons are the most tractable, or `no action` with the reason.

**The choice rule:** if the biggest phase has `n_na > n` in the window, the
finding is "cannot measure <phase>" and the action is **instrumentation** for
it. Read its top `na_reasons` first:

- a reason no landed emitter addresses ("unticketed landing", an anchor nobody
  emits) is an instrumentation gap: fix it;
- "merge landing: ... the row has no head_commit (it predates DND-1490 ...)"
  is not a gap: those squash rows are backfillable. The action is one
  `ai/bin/lead-time-phases --ingest --repo <repo> --since <oldest such
  landed_at> --rejoin`, run only when no experiment is pending (a rejoin moves
  past summaries). Journal the counts it prints. A row it reports "not in this
  scan" needs an earlier `--since`; one "still without a PR head" is a
  forge-side gap to ticket;
- a reason that only says the event is missing on landings that predate its
  emitter is not a gap. Those rows stay n/a forever (the ledger is
  first-write-wins; `--rejoin` only re-joins a missing gated head, it cannot
  supply a missing event), and time fixes it. The action is then `no action`:
  "measurement maturing: <phase> n/a on <n_na> pre-emitter landings".

Otherwise the biggest phase is the target of a **change**, unless
`experiment list --repo R` shows a `change` on it that is PENDING or owes a
REVERT. Then the action is `no action` ("<phase> has experiment <id>
open"), or instrumentation on
another phase if one qualifies by the rule above. Never start a second change
on a phase with one pending: two changes confound each other.

### 5. Act once

Exactly one of these per improve repo per run:

1. **Land one safety-preserving harness change** that should shorten the
   phase: a faster check with the same guarantee, a step that waits less, a
   clearer instruction that saves a round. The hard constraint above bounds
   it.
2. **Land one instrumentation change:** a new event, a finer phase, a missing
   anchor. On-system only, through the telemetry writer and its registry
   (`ai/contracts/athena-telemetry.md`).
3. **Spawn ONE `athena-architect`** when the improvement needs design. Brief
   it with the summary JSON, the biggest phase and its n/a reasons, the
   experiments' state, and the constraint (it carries the same block). It
   files DND tickets on `improvement_epic`, through `notion-personal`. Block
   on it and finish in the same turn; never end the turn parked on it.
4. **`no action`, with the reason.**

The change in 1 and 2 is test-first, like any harness change: a failing test,
then the fix, then `ai/bin/harness-gate` green in your lane.

#### Landing

The lane and the commit wrapper are `athena:shipwright-lane`. The bar and the
push are `athena:merge-boarding` → *The merge bar*, its no-CI `~/dev/custom`
landing. A cron run lands that way; a directly-spawned run opens a PR, per
`athena:shipwright-lane`.

A gate or the judge refusing the change (a RED, a BLOCK) is journaled, and
the run's action ends there. Never retry around a gate. On the cron path,
then reset your lane to origin/main (`git reset --hard origin/main`, in your
lane only), so it holds no unlanded commit: the runner reads any lane commit
not on origin/main as STRANDED (exit 72), keeps the branch, and counts the
tick toward its wedge. A rejected push follows `athena:shipwright-lane` →
*Sync up*; if that fails too, journal it and stop. A failed push is the one
case that leaves commits in the lane.

#### Recording the experiment

After the change is **on main**, record it with the SHA as it landed (a
rebase changes it):

```
experiment record --repo R --phase P --kind change --metric phase \
  --commit <landed sha> --hypothesis-file <file>
```

- `--kind instrumentation --metric na_share` for an instrumentation change.
  It is never refused for a pending change on its phase.
- When the change's mechanism is one harness-gate check, record it on
  `--metric check:<label>`, the label exactly as the gate prints it (copy it
  from harness-gate's `timings.jsonl`). The phase median moves with every
  other landing's load and suite growth; the check's wall moves with this
  change. The hypothesis states the expected check wall and why the phase
  should follow. `--phase` is still required, and one pending change per
  phase still holds. A label on none of the window's landings is refused
  (exit 2, naming the closest labels); exit 3 means no landing carries
  `check_walls` yet. Never re-record an experiment on another metric after
  seeing its result.
- Other metrics: `lead`, `code`, `counter:<name>` (`--help` lists them), when
  the change targets one directly.
- A refusal (exit 2) names the pending experiment that blocks it. Do not work
  around it.
- A directly-spawned run whose PR has not landed yet journals "awaiting
  landing: PR #n" under `### Experiments`. The next run records it once the
  commit is on main.

A revert (step 2) and an architect hand-off record no experiment.

### 6. Journal

Append to `<state>/journal.md`, in the shipwright's journal shape (its
*Journal format*) plus an `### Experiments` section:

```
## <date> — lead-time run: <repo(s)>

### Changed
- <what> — <locus> — evidence: <summary numbers> — commit <sha>

### Experiments
- <id> <verdict>: before n/median/p90 -> after n/median/p90; guards; reason
- recorded <id>: <phase> <metric>, baseline <numbers>
- <id> declined (<constraint>): <reason>

### Watched, not actioned
- <finding> (biggest phase, n/a reasons, why no action)

### Decisions / Won't-change
- <candidate rejected, and why> — do not revisit unless <trigger>
```

Every candidate the hard constraint rules out goes under *Decisions /
Won't-change*, with the reason.

## For each `watch` repo

The procedure the shipwright ran before this skill, moved here. A `watch`
repo is read-only to you: you never commit to it, and its improvements are
filed as tickets.

**The signal.** `ai/bin/lead-time` gives every ticket's lead time = captain
dispatch (the ticket's dispatch stamp) → fully deployed (git + the
forge's CI); it splits into two phases with different levers:

- `code` (start → landing) — development + review. Lever: the **harness/process**
  (clearer specs, better skills, fewer review round-trips).
- `tail` (landing → end) — CI + deploy. Lever: **pipeline efficiency**
  (parallelize, cache, shard) — never by weakening a check.

Each run, for every `watch` repo in the config (forge auto-detected),
scan for outliers newer than your **watch cursor**:

```
ai/bin/lead-time --repo <R> --since "$(cat "<state>/watch-cursor.<repo>.txt")" --slow 90 --json --meta "<state>/watch-meta.<repo>.json"
```

`watch-cursor.<repo>.txt` lives in the state dir (main checkout)
— **one cursor per repo**, set to `scanned_through` from that
repo's meta file (delete it before the scan; read it only on exit 0), never
the newest printed row: `--slow` hides rows. A null value or **any `SCAN
INCOMPLETE`** leaves the cursor. Missing on first run → a bounded 48h window.
A row with `unmeasured_reason` could not be measured: report it as unmeasured,
never as fast or as an outlier. The start is the ticket's dispatch stamp (DND
`In Progress at`, or the work tracker's property from the private overlay), so
tickets dispatched before the stamp, and walt_ui rows on a machine with no
overlay, read unmeasured by design: count their missing starts per repo, not
as findings.
Their `tail_seconds` is still measured, so they still count toward a `tail`
outlier or a stage dominating the `tail`, which is walt_ui's lever.

The watch tools take the repo's checkout PATH (the config's `path`), not its
name: `--repo ~/dev/gen_saas`, not `--repo gen_saas`.

**Also sweep for finished work nobody is merging** — `ai/bin/ready-and-idle
--repo <R>` lists open MRs that are green, unblocked and idle; `lead-time` sees
landed requests only, never open ones. Report them; the admiral merges, not you. Read the exit code: **3 =
UNAVAILABLE**, no list; **4 = the list is COMPLETE, act on it** — only `drift`
went soft, routine from a cron lane. Reading a 4 as a failure reinstates the outage.
Do not run it on `~/dev/custom`: with no CI, every request there is NOT
JUDGED (`ready-and-idle --help`), so the sweep cannot find anything.

**Count only the fleet's own rows.** Neither tool filters by author, and
`walt_ui` is shared with human coworkers. A row is fleet work only if Athena
authored it (`athena-amby`, `athena-harness[bot]`); check with `glab mr view` /
`gh pr view`. Measured 2026-09-27: of 30 walt_ui "orphans" only 6 were
Athena's, and all 6 slow lead-time rows were coworkers'.

**Qualify before acting — same discipline as report patterns.** A single slow
ticket is *watched, not actioned*. Act only on a **recurring shape** (≥2 slow
tickets sharing a cause — the same slow CI stage, the same back-and-forth) or a
**single unambiguous systemic cost** (a stage dominating the `tail` on every
ticket). Tickets that share a `start` were dispatched together as one batch;
their `code` times overlap, so count the batch once
(`ai/docs/lead-time-tracking.md` → *The START marker*).

**Coordinate with an athena-architect.** When something qualifies, do not design
the improvement yourself — spawn ONE `athena-architect` (Agent tool) and brief it
with: the outlier rows and their `code`/`tail` split, which phase dominates, and
the safety-check constraint (it carries the same block). Ask for **concrete,
safety-preserving** improvements. Block on it and finish in the same turn (per
*Never end your turn waiting…*); never end the turn parked on it.

**Applying what comes back — stay in scope (the shipwright invariants *Stay in
scope, never force* and *Never edit … in the main checkout*).**

- **Harness improvements to THIS repo** (`~/dev/custom` — a skill, block, agent
  definition, hook, a faster gate check) land only as custom's one action of
  the run (*5. Act once*, *Landing*, and an experiment record), so the ledger
  can attribute their effect. If custom's action is already spent, the
  architect files them as a DND ticket on `improvement_epic`.
- **Project-specific improvements** (a `gen_saas` workflow, a `walt_ui`
  `.gitlab-ci.yml`, a project's own harness) are **NOT yours to commit** — you
  touch only `~/dev/custom`, never a product repo or MR. The architect files them
  as Notion tickets; the admiral picks them up. Record the hand-off in the journal
  and report it. Never open the product MR or spawn captains to do product work.

Report each run's outliers, what qualified, what you changed here, and what you
handed to the fleet.

## Reporting

Write one summary line per repo to the summary file your brief names; else
`<state>/runs/<UTC %Y%m%dT%H%M%SZ>.summary`:

```
repo=<R> mode=improve biggest=<phase|none> action=<change|instrumentation|architect|revert|no-action> experiments=keep:<n>,revert:<n>,pending:<n>,inconclusive:<n>,declined:<n> reason="<one line>"
repo=<R> mode=watch outliers=<n> qualified=<n> handed_off=<n> ready_and_idle=<n|unavailable>
```

Then end with the shipwright's short summary to whoever invoked you: the sync
result, each repo's line, the commits you landed, and anything that qualified
but could not land safely. The journal is the durable record.
