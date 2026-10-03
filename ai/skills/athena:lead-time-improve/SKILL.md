---
name: athena:lead-time-improve
description: The procedure an athena-shipwright runs when its brief says `MODE: lead-time` (a lead-time improver run) — for each `improve` repo ai/bin/lead-time-repos resolves for this machine, ingest the phase ledger, judge pending before/after experiments (keep, revert, pending, inconclusive, confounded; decline a revert the hard constraint forbids) with scripts/experiment, pick the biggest contributor, act exactly once (one safety-preserving change, in custom or, for an improve repo other than custom, as an improver PR in that repo; one instrumentation change, one architect, or no action), and journal; for each `watch` repo, the outlier scan and architect hand-off the shipwright ran before. Use whenever a brief or prompt says "MODE: lead-time" or "lead-time improver run".
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
  `unmeasurable.json`, `watch-cursor.<repo>.txt` and `runs/`. Never derive
  it from your cwd.
- **Run id:** the one your brief names (the cron lane's `run-<utc>-<pid>`).
  A directly-spawned run with none uses `direct-<UTC %Y%m%dT%H%M%SZ>`, fixed
  once at its start. `unmeasurable observe` counts each id once.
- **Lane:** `athena:shipwright-lane` (*Where you run*, *Sync down first*).
  Every commit goes through its commit wrapper.
- **Read the journal first.** Its *Decisions / Won't-change* entries bind
  this run.
- **Repos and modes:** the ones your brief names, with their paths, which
  `ai/bin/lead-time-repos` resolved for this machine. If your brief names
  none, run `ai/bin/lead-time-repos --json` from your lane and use its `repos`
  and `skipped`; a non-zero exit is a fault to report with its `Fix:`, never
  an empty run. Never your lane copy of `ai/config/lead-time-repos.json`: it
  cannot see a machine override. For each skipped repo, write one summary
  line `repo=<R> skipped="<reason>"`. `improvement_epic` (`--json`) is the
  epic an architect files tickets on.

Tools, from your lane (`<skill>` is `ai/skills/athena:lead-time-improve`):

```
ai/bin/lead-time-phases --ingest --repo R
ai/bin/lead-time-phases --summary --repo R --json
<skill>/scripts/experiment judge --repo R    # also reads Lead-time-experiment trailers: CONFOUNDED
<skill>/scripts/experiment record --repo R [--change-repo C] --phase P --metric M --commit SHA --kind change|instrumentation --hypothesis-file F    # SHA carries "Lead-time-experiment: R P M"
<skill>/scripts/experiment list --repo R
<skill>/scripts/experiment decline --repo R --id ID --constraint safety-checks|bug-fix --reason-file F
<skill>/scripts/experiment settling --repo R --phase P [--metric M] [--json]    # read-only: CLEAN | SETTLING | SHORT
<skill>/scripts/unmeasurable observe --repo R --run ID --summary-file F    # every run; escalates at 3 (DND-1806)
<skill>/scripts/unmeasurable handoff --repo R --phase P --ticket DND-N
<skill>/scripts/unmeasurable status [--repo R]    # read-only
<skill>/scripts/unmeasurable ingest-failed --repo R --run ID --step ingest|summary --exit N --reason TEXT    # no summary to observe (DND-1820)
<skill>/scripts/unmeasurable check --repo R --run ID    # read-only; the runner's check after you exit
```

Each answers `--help`. Read an exit code before its output:
`lead-time-phases` exit 3 is SCAN INCOMPLETE; `experiment` exit 3 is "could
not look" (no ledger, or a git log it could not read). Neither is "nothing
to do". Exit 4 from either is "configured, but its checkout is not on this
machine"
(`ai/bin/lead-time-repos`): skip that repo this run and journal the skip.
A repo your brief listed as an improve repo still gets its record: for a
`lead-time-phases` exit 4 that is `unmeasurable ingest-failed` with `--exit
4` (step 1), because the runner checks every improve repo it listed.

## For each `improve` repo, in order

### 1. Ingest

`lead-time-phases --ingest --repo R`. Exit 3: nothing was ingested and the
cursor stayed. Exit 1 or 2: a tool, state or config fault. Either way,
journal it with the error line and take **no action** on R this run
("cannot measure: <why>"). Never act on a stale window as if it were
current. The same holds for an `experiment` exit 1, 2 or 3 in step 2.
Telemetry pruning is the runner's, not yours.

A failed ingest leaves R with no summary to observe, so record that instead
(DND-1820): `unmeasurable ingest-failed --repo R --run <run id> --step
ingest --exit <its exit> --reason "<its error line>"`. A `--summary` that
exits non-zero in step 3 is recorded the same way, with `--step summary`.
The runner reads it as its own outcome, `ingest-failed`, never as a pass
(*Escalate what stays unmeasurable*). "No action" never skips that
escalation: when the ingest and the summary read both exit 0 (an
`experiment` fault in step 2, say), you still run `observe` on R.

### 2. Judge pending experiments

`experiment judge --repo R`, before anything new starts. Per pending
experiment it prints `keep`, `revert`, `pending`, `inconclusive` or
`confounded`, with the before and after numbers, and records the verdict.

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
  commit, landed through *Landing* below. Skip steps 4 and 5, except step
  4's *Escalate what stays unmeasurable*: still run `observe` on R (or
  record `ingest-failed`), which the runner checks. Judge records
  `reverted` once main carries it, and until then no new change starts on
  that phase. If two reverts are owed, land the first; the second is still
  owed next run. A cross-repo experiment's line names `change_repo=C`
  (DND-1528): its revert is of that commit in repo C, landed through C's
  path, and judge reads C's main for it. A revert in an improve repo other
  than custom goes through its product lane like any change there (*The
  product lane*).
- **REVERT HELD**: judge found that the commit added test lines (a `test/`
  path or a `*.self-test.sh`, or any common layout: `tests/`, `spec/`,
  `__tests__/`, `*_test.*`, `*.spec.*`; the `FirstParty.test_file_any_layout?`
  rule, DND-1630; or lines inside a tool's own inline `--self-test` block,
  DND-1577), or could
  not look. A plain `git revert` would delete them, so it is never the
  action. The status is still `revert`. Either land a partial revert that
  keeps every test addition and its fixture fix, or decline it as above
  (`--constraint safety-checks`) and journal it under *Decisions /
  Won't-change*. Build the partial revert with `git revert --no-commit
  <sha>`, restore the test paths, and commit keeping git's `This reverts
  commit <sha>.` line: judge records `reverted` only from that line. It is
  a change like any other: harness-gate, critic PASS, integration-gate. If
  the line says decline does not cover it (a worse or unmeasured guard),
  the partial revert is the only path. A bug-fix commit whose regression
  test (`~/.claude/CLAUDE.md` → *TDD Workflow*) is on a test path is held
  with no commit-message parsing. A test the rule cannot see, such as an
  inline `--self-test` inside a tool or a new check, is still judged by the
  hard-constraint test in the **revert** bullet above.
- **unclassified additions** (DND-1634): a revert line, and `record`'s
  output, name added paths in a test-like layout with no test word
  (`features/`, `__mocks__/`, `testing/`, `fixtures/`, a `*.feature` file;
  `FirstParty.unclassified_layout?`). Nothing is held on them. Before a
  plain revert, check each by hand; if it holds tests, treat it as **REVERT
  HELD** (partial revert or decline).
- **declined** is never a gain. It no longer blocks its phase. Judge never
  writes it; only the `decline` verb does.
- **keep, inconclusive:** journal them. An inconclusive experiment no longer
  blocks its phase.
- **confounded** (DND-1529, *Landing*): another commit's trailer on the
  same phase landed inside the window, or a declared series break on the
  phase did (DND-1810, *Declaring a series break*). Journal it with the
  commits and breaks it names. It is treated as inconclusive: never keep,
  never revert, and it no longer blocks its phase. A break confounds
  instrumentation too, and judge re-checks a settled keep or an owed revert
  against breaks declared after it. Judge exit 3 naming the series-break
  registry is could not judge: journal it, and record no verdict by hand.
  When only settled verdicts are left, judge exits 0 and its summary counts
  them as NOT re-checked for series breaks: journal that too.
- **pending** is never a gain. Never report it as one.

### 3. Summarize

`lead-time-phases --summary --repo R --json`. Keep the JSON for the journal
and for an architect's brief. `foreign` counts the landings worked on
another machine (DND-1531), named in `origin.foreign_units`. They are already
out of the summary's `phases` and `biggest`, so *Pick the biggest
contributor* and its choice rule see local landings only. Journal the count;
a foreign landing is never an instrumentation gap.

Then run the `ready-and-idle` sweep on R, as *For each `watch` repo* →
*Also sweep for finished work nobody is merging* says. Open work is outside
the summary, which sees landings only.

### 4. Pick the biggest contributor

`biggest.phase` is the candidate with the largest summed time in the window:
one of the five phases, or `tail` (landing to deploy) when the window has a
measured nonzero tail, as in a repo with post-merge CI. A tie goes to the
phase. When it is null, nothing is measured: the action is instrumentation
for the phase whose n/a reasons are the most tractable, or `no action` with
the reason.

**Later (2026-10-01, DND-1532):** this read "`biggest.phase` is the phase with
the largest summed time", over the five phases only. Superseded: `tail` is
now a candidate too, so a repo's post-merge CI and deploy time can be picked.

`biggest.lever` says where the fix lands: `harness` for the five phases,
`product` for `tail`, the repo's own CI and deploy. With no measured nonzero
tail, `tail` is never a candidate; `biggest.tail_reason` says why
(`ai/bin/lead-time-phases --help`). For `tail`, its `n`, `n_na` and
`na_reasons` are in `totals.tail`, not `phases`. A `tail` biggest is the
target like a phase: its change is a product change in the repo itself (its
CI/CD or deploy, *An improve repo other than custom*), recorded on
`--phase tail --metric phase` (*Recording the experiment*). The choice
rule's instrumentation branch does not apply to `tail`: a tail n/a is a
landing whose post-merge run never concluded, which no emitter fixes. When
`totals.tail` has `n_na > n`, journal "tail not judgeable: <na_reasons>"
and run the choice rule on the largest phase by `phases.<p>.sum_s` instead. In custom,
with no post-merge CI, `tail` is never a candidate.

Whether a repo has post-merge CI comes from its `idle_workflow`, else the
window (`tail_ci`, DND-1614; `ai/bin/lead-time-phases --help`). A
`tail_ci.mismatch` means a repo declaring `"none"` has landings with a
post-merge run: its tails stay measured, and the run files a ticket to fix
that repo's lead-time config entry.

`--metric lead` reads the ledger's `lead_s`. Ingest writes it null for a
landing with no post-merge run in a CI repo (DND-1924), so a before/after on
`lead` never mixes landing-ended and deploy-ended leads in one set. Rows
ingested before DND-1924 keep their old `lead_s`: a before-set that reaches
back to them mixes the two definitions until they age out of the window. A repo with no `idle_workflow` infers CI
per ingested batch, so declare it; watch-mode rows are not adjusted.

**Later (2026-10-01, DND-1533):** this read "The product-side action for a
`product` lever is not set by this step (DND-1533, DND-1542). Until it is,
the harness work goes on", for every repo. Superseded for an improve repo
other than custom: its product lever is now the architect hand-off below.

**Later (2026-10-01, DND-1542):** the DND-1533 rule above handed a
`product` lever in an improve repo other than custom to an architect.
Superseded: such a repo may now change itself, but a change on `tail` cannot
be judged yet, so `tail` is not a target anywhere while DND-1613 is open.

**Later (2026-10-01, DND-1613):** this read "`experiment` records phases
only and refuses `tail` … Until DND-1613 gives `tail` experiments, a `tail`
biggest is never the target, in any repo", and the run worked the largest
phase instead. Superseded: `experiment` now records and judges a change on
`tail`, so a `tail` biggest is the target.

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
REVERT, or, for a repo other than custom, an improver PR on it is pending
(*The product lane*, step 1). Then the action is `no action` ("<phase> has
experiment <id> open", or "PR R#n open"), or instrumentation on
another phase if one qualifies by the rule above. Never start a second change
on a phase with one pending: two changes confound each other.

Before a change on that phase, check its baseline is clean (DND-1622):
`experiment settling --repo R --phase P --metric M`, with the phase and
metric the change will be recorded on. Judge's confound window reaches back
over the whole before-set, so a same-phase trailer inside it (a settled
predecessor's change, or its revert) confounds the next change with
certainty. A declared series break on the phase inside it does too
(DND-1810), so settling names breaks as well. An instrumentation change
checks `--metric na_share`, which reads breaks only: no trailer confounds
instrumentation. For instrumentation, SETTLING means it would read
confounded if it landed now: not a target this run, though nothing blocks
it. A phase is a change target only when settling's `target` (`--json`) is
true, or its line says "change target: yes". Read the verdict as follows:

- **CLEAN**: the phase is a change target.
- **SETTLING**: not a target this run. The action is `no action` ("<phase>
  baseline settling after <sha>: N more landings", from its line), or
  instrumentation on another phase if one qualifies by the rule above.
- **SHORT**: not a target this run, confounder or not; read as SETTLING.
  The action is `no action` ("<phase> baseline short: <short_by> more
  comparable landings to K=10"), or instrumentation on another phase if one
  qualifies by the rule above. Do not fall through to a change on the next
  contributor. This holds for every phase, `tail` included, and for an
  instrumentation check (`--metric na_share`) that reads SHORT.

  **Later (2026-10-03, DND-1674):** this bullet read "One that names none is
  a target … pending for 7 days, then inconclusive". Superseded: a before-set
  is frozen at landing, so no later landing can fill a short one, and such a
  change is certain to read pending, then inconclusive, while it blocks the
  phase for 7 days.
- **exit 3** (could not look): no change on that phase this run. Journal the
  reason it printed. It is never CLEAN.

A phase each revert or inconclusive sends back to SETTLING waits each time.
That is correct: it has no clean baseline. The journal line shows it.

#### Escalate what stays unmeasurable (DND-1806)

Every run, on every improve repo whose summary you read in step 3, save that
JSON (exit 0 only) to a file named for this run and repo, and run
`unmeasurable observe --repo R --run <run id> --summary-file <file>`. Do it
before you choose the action: its outcome can decide it. Its `--help` is
the full rule; in short:

- It counts, per repo and phase in `unmeasurable.json`, the runs on which a
  phase is unmeasurable (`n_na > n`) and either the biggest or dark (no
  measured row, so the summary can never pick it). A run that does not
  count the phase holds its count, so the runs need not be adjacent. A
  measurable run resets it.
- On a counted run with a hand-off ticket recorded, it reads that ticket
  from DND Tickets.
- At 3 counted runs with the ticket open, once per episode, it sets Path =
  Promoted, notes the escalation on the ticket, and sends ONE
  `leadtime-unmeasurable` harness-alert naming the repo, phase, ticket and
  run count. The episode ends when the ticket lands (Done or Ready for
  Release) or the phase becomes measurable.

Put each `journal:` line it prints in this run's journal as written. Then
act on its outcome:

- **ESCALATED**, **ESCALATED-EARLIER**, or **COUNTING** naming a ticket: the
  gap is handed off and the ticket was read open this run. This phase needs
  no second hand-off. Pick the run's action as usual.
- **COUNTING** with no ticket: the choice rule above applies as usual. If
  your action hands the gap off, record the ticket (below).
- **NO-HANDOFF** (3 counted runs with no open hand-off, or with one that
  landed and left the phase unmeasurable) or **HANDOFF-CLOSED** (the
  hand-off was cancelled or won't-fixed, at any count): `no action` is not
  allowed. This run's action is the instrumentation change, or ONE
  architect (step 5.3) to file the hand-off.
- **HANDOFF-LANDED**: its fix landed less than 3 counted runs ago. If the
  top n/a reason predates the fix's emitter, "measurement maturing" as
  above. If it does not, the fix did not fire: a new finding, handed off as
  in NO-HANDOFF.
- **COULD-NOT-LOOK** (exit 3): the ticket could not be read or promoted, or
  the alert was not delivered. Journal it as "could not look: <its
  reason>", never as "already handed off". The next run retries the failed
  step. Pick the run's action as usual; a NO-HANDOFF it hid shows next run.
- **MEASURABLE**, **MEASURED**, **NO-ROWS**, **NO-PHASE**: journal the line;
  nothing to escalate.
- Exit 2 (a summary for another repo, a missing phase, a bad ticket): a
  refusal, journaled with its Fix:. Nothing was counted.

Whenever a run hands an unmeasurable phase off to a ticket (an architect
files it), record it the same run: `unmeasurable handoff --repo R --phase P
--ticket DND-N`. A hand-off the journal names that `unmeasurable status`
does not hold is recorded the same way before `observe`.

**The runner checks that you ran it (DND-1820).** `observe` writes this
run's record, `runs/<run id>.observe.<repo>.json`, and `ingest-failed`
(step 1) writes it for a repo with no summary. An `observe` that fails
before counting (exit 2 refused, exit 1, or exit 3 on an unreadable
`unmeasurable.json`) writes an `observe-failed` record with its error;
journal its Fix:. After you exit, the cron runner runs `unmeasurable check`
for every improve repo it covered:

- no record: `observe-missing`;
- a record it cannot read: `observe-could-not-look`;
- `observe-failed`: its own outcome;
- `ingest-failed`: its own outcome.

Each fails the tick and is counted toward the wedge (the runner's `--help`
has the exits). So every run observes every improve repo, or records
`ingest-failed` for it. An `observe` that ran and exited 3 on a ticket or
alert passes: the check proves the call, and its retry is the next run's.
An `observe` that exits 1 after saving its count printed that its record
was not written: run it again with the same run id, which counts once.

**Later (2026-10-02, DND-1820):** this read "The residual: this escalation
fires only on a run that calls `observe`. Nothing outside this skill checks
that the call happened." Superseded by the runner's check above.

### 5. Act once

Exactly one of these per improve repo per run:

1. **Land one safety-preserving harness change** that should shorten the
   phase: a faster check with the same guarantee, a step that waits less, a
   clearer instruction that saves a round. The hard constraint above bounds
   it. In an improve repo other than custom, a change that belongs in that
   repo is instead one improver PR opened there (*The product lane*).
2. **Land one instrumentation change:** a new event, a finer phase, a missing
   anchor. On-system only, through the telemetry writer and its registry
   (`ai/contracts/athena-telemetry.md`).
3. **Spawn ONE `athena-architect`** when the improvement needs design. Brief
   it with the summary JSON, the biggest phase and its n/a reasons, the
   experiments' state, and the constraint (it carries the same block). It
   files DND tickets on `improvement_epic`, through `notion-personal`; a
   change too large for one run in a repo other than custom goes on that
   repo's `product_epic` instead (*An improve repo other than custom*). Block
   on it and finish in the same turn; never end the turn parked on it.
4. **`no action`, with the reason.**

The change in 1 and 2 is test-first, like any harness change: a failing test,
then the fix, then `ai/bin/harness-gate` green in your lane (in a product
lane, that repo's declared gate: *The product lane*).

#### Landing

The lane and the commit wrapper are `athena:shipwright-lane`. The bar and the
push are `athena:merge-boarding` → *The merge bar*, its no-CI `~/dev/custom`
landing. A cron run lands that way; a directly-spawned run opens a PR, per
`athena:shipwright-lane`. A cron run's push needs an `integration-gate`
receipt for its head, so it runs the gate and judge before it pushes
(`athena:shipwright-lane` → *Sync up*, DND-1690); `harness-gate` green alone
is refused at the push. A change in an improve repo other than custom
never lands in the run that makes it: *The product lane*.

Every change, instrumentation change and revert lands with this trailer
line in its commit message (DND-1529), in the final paragraph with the
other trailers:

```
Lead-time-experiment: <measured repo> <phase> <metric>
```

It names what the experiment is recorded on (`custom verify phase`,
`gen_saas integrate check:<label>`); a revert repeats its experiment's
trailer. `experiment record` refuses a commit without the matching trailer
(exit 2), and a landed commit cannot gain one: journal it as unrecorded. The
store is per machine, but the trailer is on custom's main for every machine
to read: `experiment judge` reads it, and a change on the same phase from
another experiment inside a pending change's window makes that change
`confounded`, settled as inconclusive, never keep and never revert. An
`na_share` trailer confounds nothing. In a product repo, a lane commit
carries it: `leadtime-product cut --metric M` prints the line, and `pr`
refuses a lane with no commit carrying it (the squash keeps commit
messages, not the PR body).

#### Declaring a series break

A change to how the ledger MEASURES a phase (a lead-time-phases rule, an
anchor, which landings it joins) is a series break: rows before and after it
measure that phase by different rules, so no experiment is comparable across
it. Its one home is `ai/config/lead-time-series-breaks.json` (DND-1810). Add
one row: `ticket`, `commit` (the 40-hex SHA as it LANDED on custom's main),
`phases` (every phase whose values change), and `what`. A landed SHA is known
only after the landing, so the row lands in a follow-up commit: the change's
report or PR body names the phases, and the admiral that lands it adds the
row (`athena:merge-boarding` → *The merge bar*, the custom landing). Judge
reads the registry AS LANDED on custom's main, never from a working tree,
so a row in a lane or a branch applies to nothing until it lands (judge
names it as pending). Never add one to settle an experiment of your own
run. Once the row lands, judge confounds every experiment whose window
holds the break, including one it already settled keep or owes a revert
on. A revert a worse guard drove
still stands: a guard is read from counters, not the phase. A row whose
commit is not on main, or that names an unknown phase, makes judge exit 3
until it is fixed.

Residuals, named rather than closed:

- An undeclared break is invisible to judge. Nothing detects a measurement
  change that nobody declared.
- Between a break's landing and its row, a revert that lands or an
  inconclusive recorded is not re-checked; only keep and an owed revert
  are.
- Rows are frozen at ingest, so the ledger's real cutover is the first
  ingest that ran the new code, up to one hourly tick after the break's
  landing time judge uses. Against windows of days that edge is small.

A gate or the judge refusing the change (a RED, a BLOCK) is journaled, and
the run's action ends there. Never retry around a gate. On the cron path,
then reset your lane to origin/main (`git reset --hard origin/main`, in your
lane only), so it holds no unlanded commit: the runner reads any lane commit
not on origin/main as STRANDED (exit 72), keeps the branch, and counts the
tick toward its wedge. A rejected push follows `athena:shipwright-lane` →
*Sync up*; if that fails too, journal it and stop. A failed push is the one
case that leaves commits in the lane.

#### Recording the experiment

After the change is **on main** (the main of the repo it landed in), record
it with the SHA as it landed (a rebase changes it):

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
  phase still holds. A label on none of the last `window` landings that
  carry `check_walls` is refused (exit 2, naming the closest labels); exit 3
  means no landing carries `check_walls` yet. Read the printed baseline: an
  n/a or n < 10 baseline holds the phase pending until it settles
  inconclusive, so record on `phase` instead until 10 landings carry
  `check_walls`. Never re-record an experiment on another metric after
  seeing its result.
- Other metrics: `lead`, `code`, `counter:<name>` (`--help` lists them), when
  the change targets one directly.
- When the change landed in another repo than R (a harness change in
  custom, measured on R's landings), add `--change-repo <that repo>`
  (DND-1528). The SHA must be on that repo's main. The split point is
  `live_at`, when it went live there: the push or merge time from that
  repo's ledger row that carries it, else, until that row is ingested, its
  first-parent landing's committer time (record says so, and judge moves to
  the ledger time once the row exists). Never the author date. R's landings
  either side of it are the before- and after-sets. `ai/bin/lead-time-repos --repo-path C` shows which
  checkout C resolves to; custom resolves even where it is not configured.
  An unresolvable change repo is refused (exit 2).
- A change made in an improve repo R other than custom is a same-repo
  experiment: `--repo R`, no `--change-repo`, and `--commit` the commit as it
  landed on R's main (a squash: the `merge_sha` *The product lane* reads). It
  is recorded by the first run that sees it merged.
- A change in R aimed at `tail` (its CI/CD or deploy) is recorded with
  `--phase tail --metric phase`, the only metric on `tail` (DND-1613). Only
  landings whose post-merge run concluded count; the others are named as
  excluded with their reason, never as 0. Record refuses `tail` (exit 2)
  when none of R's last `window` landings has a measured tail, and exit 3
  means none carries an end kind yet. Its revert is a revert PR in R
  through *The product lane*.
- A refusal (exit 2) names the pending experiment that blocks it, or the
  trailer the commit lacks (*Landing*). Do not work around it.
- A directly-spawned run whose PR has not landed yet journals "awaiting
  landing: PR #n" under `### Experiments`. The next run records it once the
  commit is on the main it landed in.

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
- <id> revert held (<test paths | could not look>): <partial revert landed | declined | owed>

### Watched, not actioned
- <finding> (biggest phase, n/a reasons, why no action)

### Decisions / Won't-change
- <candidate rejected, and why> — do not revisit unless <trigger>
```

Every candidate the hard constraint rules out goes under *Decisions /
Won't-change*, with the reason.

## An improve repo other than custom

An improve repo R other than custom (gen_saas, on a machine whose list has
it in `improve`) runs steps 1 to 6 above. Only where its action lands
differs.

- **Measured like custom.** Ingest, judge, summarize and pick the biggest
  contributor as above, with `--repo R`. The ledger rows, cursor and
  experiments are R's.
- **A harness change lands in custom.** An action under step 5.1 or 5.2
  changes custom (a skill, a gate check, test-slot, an emitter), in your
  custom lane, through *Landing*. Record it on R, attributed to the custom
  commit, once that commit is on custom's main:

  ```
  experiment record --repo R --change-repo custom --phase P --metric M \
    --commit <sha on custom's main> --kind change --hypothesis-file <file>
  ```

  The commit carries the `Lead-time-experiment` trailer naming R, as
  *Landing* says (DND-1529). The split is `live_at` (*Recording the experiment*).
- **On a machine that measures R but not custom**, custom's landings are
  never ingested there, so no custom ledger row ever carries the commit.
  `live_at` stays on its committer-time fallback (`live_at_source:
  committer`) for good: record warns, and judge and list print "(committer
  time …)". A fast-forward push lands after that time, often by a whole gate
  and critic round, so R's landings in that gap count in the after-set.
  Journal each such record as "live_at committer time: custom not measured
  on this machine".
- **A change that belongs in R itself lands in R.** R's local tooling
  (`bin/`, its declared gate, its test setup) and its CI/CD and deploy
  workflows are yours to change, through *The product lane* below and R's
  normal bar. This is the owner's grant (*The grant*).
- **`tail` is a target (DND-1613).** A change to R's CI/CD or deploy aimed
  at `tail` goes through *The product lane* (`cut --phase tail --metric
  phase`) and is recorded on `tail` once merged (*Recording the
  experiment*). Its revert is a revert PR in R through R's bar. A change in
  R on any other phase is recorded on that phase as usual.

  **Later (2026-10-01, DND-1613):** this read "`tail` is not a target while
  DND-1613 is open", and step 4 worked the largest measurable phase instead.
  Superseded: `experiment` records and judges `tail`.
- **Too large for one run:** first check whether an earlier run already
  handed off this finding for R (the same phase), and read that ticket's
  Status this run. For an unmeasurable phase, this run's `unmeasurable
  observe` line is that read (step 4). For any other, read it through
  notion-personal. Only a ticket read open this run is "already handed off:
  <ticket> (Status <s>)": journal that and pick another action. A read that
  fails is "could not look: <why>", never "already handed off". The journal's
  own prose is never the evidence.

  **Later (2026-10-02, DND-1806):** this read "first read the journal: if an
  earlier run already handed off this finding … journal "already handed off:
  <ticket>"". Superseded: the journal's word stood in for the ticket's state,
  and DND-1501 was re-noted "already handed off" for a day and a half while
  nothing escalated.

  Otherwise the run spawns ONE `athena-architect` (step 5.3), briefed as
  there plus the repo's name. It files the change on R's `product_epic`
  (`ai/bin/lead-time-repos --json`, which falls back to `improvement_epic`
  when R names none), with Area Product. The journal records the hand-off
  and its ticket under *Changed*. That is the run's one action for R.

**Later (2026-10-01, DND-1542):** this section said a change that belongs
in R is never landed, only filed on `product_epic`, and that R is never
committed to (DND-1533). Superseded by the owner's grant below, for
improve-mode lead-time runs only.

### The grant

The owner's words, quoted verbatim: the grant, then its confirmation.

- Cody, laptop terminal, 2026-10-01 ~14:20Z: "improve gen_saas should be
  able to change whatever in the gen_saas repo is causing lead time issues
  without lowering quality bars. This includes things that are locally run
  and also CI/CD improvements."
- Cody, Slack DM to Athena, 2026-10-01, confirmed and relayed by the custom
  coordinator: "Yes, the cron should work in the repos it is configured to
  work in to improve lead time without closing quality bars"

Its scope: a lead-time improve run may change any repo its OWN machine's
list (`ai/bin/lead-time-repos`) has in `improve` mode, local tooling and
CI/CD included, through that repo's normal bar. A `watch` repo stays
read-only, so a machine without R in `improve` never changes R. No quality
bar is lowered: the hard constraint holds, moving a bar stays with Cody
(`~/.claude/CLAUDE.md` → *Owner approval policy*, item 5), and the run never
clears an `integration-gate` exit 4. A change that needs a bar moved goes
under *Decisions / Won't-change*. Nothing else changes for any other agent,
or for the shipwright outside `MODE: lead-time`.

**A change to R's own bar is judged by that bar.** R's declared gate runs
from the branch (`integration-gate` only marks it EDITED BY THIS BRANCH),
and R's CI runs the PR's own workflow, so neither can catch its own
weakening. So a PR that touches R's declared gate script, a CI workflow or
a deploy workflow names each such file in its body, says which step it
changes and how that step keeps its guarantee (the same tests, checks and
watchers, only faster). Removing, skipping, path-excluding or downgrading a
step there, or loosening its threshold, is a bar move: it is never the
change, and goes under *Decisions / Won't-change*. The residual: the
critic at landing and that PR body are the only checks on this, so say it
plainly in the body.

### The product lane

The runner reserves R's lane, exports `LEADTIME_PRODUCT_MANIFEST`, and puts
the product repos and its sweep's summary (`product_prs=<n> landed=<R#n,...>`,
plus `unreadable_branches=<n>` when it kept a landing branch git could not
read or could not delete, and any stopped line) in your brief (DND-1540). A run opens the PR; a
later run lands it. Never wait on CI or a deploy inside a run, and never
merge.

1. **Before any change on phase P for R**, in R or in custom, read R's
   improver PRs in `<state>/product-prs.jsonl` (append-only, one event per
   line; a PR's state is its last event). A PR whose last event is
   `opened` or `head` is open. One with a `merged` event (its last may be
   `merged`, `deployed`, `no-deploy` or `revert-owed`) is merged, and its
   `merge_sha` is on that `merged` event. An open PR on P, or a merged one
   whose `merge_sha` `experiment list --repo R` does not show yet, is a
   pending change on P, like a pending experiment in step 4: no second
   change there. A revert PR (its commit says `This reverts commit`) is
   pending only while open; it records nothing. A
   `<state>/product-line-stopped.<R>` marker means R's line is stopped:
   `cut` and `pr` refuse (exit 2) until the owner re-arms it (`rm` the
   marker). Journal it; a harness change in custom for R is still
   allowed.
2. **Cut the lane:** `ai/bin/leadtime-product cut --repo R --phase P
   --metric M`, with M the metric you will record on. It prints the lane
   and the trailer line for this change; work only there, starting each
   Bash command with `cd` to it. Exit 5 (R's bootstrap failed) is "cannot
   act on R": journal it, no retry.
3. **Test-first, then R's gate.** A failing test, then the change,
   committed in the lane with the trailer line `cut` printed in the commit
   message (*Landing*): the squash keeps commit messages, not the PR body.
   Then R's declared gate (the one `integration-gate --help` → `--gate`
   says it reads), under `ai/bin/test-slot`, green. A gate may commit or
   edit the tree (gen_saas's does): commit first, then check `git status`
   and `git log` after it, and keep the trailer on the commits that stay.
4. **Open the PR:** `ai/bin/leadtime-product pr --repo R --title <title>
   --body-file <file>`. The body is the evidence: the summary numbers, the
   phase, the hypothesis, and the gate result. Name the file for this run
   and repo, never a generic scratch name. `pr` pushes as Athena and
   records the PR; it refuses (exit 2) a lane where no commit carries the
   trailer. That is the run's one action for R. Keep the hypothesis
   in the journal too: the recording run needs it.
5. **A refusal** (gate RED, a test you cannot make pass): journal it, open
   no PR, and reset the product lane to R's `origin/main`. An unpushed
   commit left in a product lane is STRANDED (runner exit 72).
6. **Landing is the runner's**, in a later tick, through R's normal bar:
   CI green, `integration-gate --with-critic --rebase`, `locked-merge`,
   `confirm-merged`, and the post-merge deploy concluded
   (`ai/bin/leadtime-product --help` → `sweep`). A PR it closes (CI red, a
   critic BLOCK, gate RED, a rebase conflict, exit 4) records nothing:
   journal its reason. A PR closed on exit 4 goes under *Decisions /
   Won't-change*; no run reopens, retries or clears it.
7. **Record after the merge.** The first run that finds a PR with a
   `merged` event records the experiment with its `merge_sha` (*Recording
   the experiment*), using the hypothesis it journaled. A `merge_sha` that
   is not 40 hex (the sweep writes `unknown` when the forge gave none):
   read it with `gh pr view <n> --json mergeCommit` in R; if that is empty
   too, journal "awaiting merge sha: R#n" and record next run. A failed
   deploy stops R's line and owes a revert: journal it every run until the
   owner re-arms the line; the revert then goes through this lane like any
   change.

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

Each run, for every resolved `watch` repo (forge auto-detected),
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

The watch tools take the repo's checkout PATH (its resolved `path`), not its
name: `--repo ~/dev/gen_saas`, not `--repo gen_saas`.

**Also sweep for finished work nobody is merging** — `ai/bin/ready-and-idle
--repo <R>` lists open MRs that are green, unblocked and idle; `lead-time` sees
landed requests only, never open ones. Report them; the admiral merges, not you. Read the exit code: **3 =
UNAVAILABLE**, no list; **4 = the list is COMPLETE, act on it** — only `drift`
went soft, routine from a cron lane. Reading a 4 as a failure reinstates the outage.
Run it on every resolved repo, `improve` repos included, and put its count in
that repo's summary line. In a repo with no CI (custom) a request is judged
on an integration-gate receipt and a critic PASS for its head
(`ready-and-idle --help`). A scan that says NOT JUDGED is not a clean scan:
report its JSON `unjudged` as `unjudged=<n>`, never as zero.

**Later (2026-10-01, DND-1505):** this said "Do not run it on `~/dev/custom`",
because with no CI every request there read NOT JUDGED. Superseded: the
sweep now judges a no-CI request by the merge bar's machine-readable evidence,
so custom's abandoned PRs are covered. One limit: integration receipts are
local, so it sees only PRs gated on this machine, and the scan says so.

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
  `.gitlab-ci.yml`, a project's own harness) are **NOT yours to commit** — for
  a `watch` repo you touch only `~/dev/custom`, never that repo or an MR in it
  (an `improve` repo other than custom is the exception: *An improve repo
  other than custom* → *The grant*). The architect files them
  as Notion tickets; the admiral picks them up. Record the hand-off in the journal
  and report it. Never open the product MR or spawn captains to do product work.

Report each run's outliers, what qualified, what you changed here, and what you
handed to the fleet.

## Reporting

Write one summary line per repo to the summary file your brief names; else
`<state>/runs/<UTC %Y%m%dT%H%M%SZ>.summary`:

```
repo=<R> mode=improve biggest=<phase|none> action=<change|instrumentation|architect|revert|no-action> experiments=keep:<n>,revert:<n>,pending:<n>,inconclusive:<n>,confounded:<n>,declined:<n>,held:<n> ready_and_idle=<n|unavailable> unjudged=<n> reason="<one line>"
repo=<R> mode=watch outliers=<n> qualified=<n> handed_off=<n> ready_and_idle=<n|unavailable> unjudged=<n>
repo=<R> skipped="<reason>"
```

An improver PR opened in a product repo is `action=change` (or `revert`),
with "PR R#n opened" in its reason.

Then end with the shipwright's short summary to whoever invoked you: the sync
result, each repo's line, the commits you landed, and anything that qualified
but could not land safely. The journal is the durable record.
