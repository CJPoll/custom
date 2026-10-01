# Lead-time improver loop (custom)

**Kind: dated record (2026-10-01).** It says what was decided on its date.
Corrections are added as `**Later (<date>):**` paragraphs, never rewritten
(`~/dev/custom/CLAUDE.md` → *Documentation conventions*). Once built, the
normative homes are the ones *Where things live* names.

## The request

Owner, Cody, coordinator terminal turn, 2026-10-01 ~05:45Z:

> "I'd like to set up another feedback loop: a lead time improver. It tracks the
> lead time of all PRs for custom, analyzes what is slowing it down, and makes
> improvements to the system to speed up lead time without reducing quality
> bars."

Then: "Custom only for now; we may expand that to gen_saas later." And, later
the same turn: "Let's also add to its scope the ability to add
instrumentation/telemetry (on-system only) to better measure things and get the
data it needs to best improve lead time and velocity."

Lead time is the owner's definition: captain dispatch (the ticket's
`In Progress at` stamp) → landed on main (`ai/docs/lead-time-tracking.md`).

## What is wrong today (measured 2026-10-01 ~05:50Z)

- **Most custom landings are invisible.** `ai/bin/lead-time --since` lists PRs
  only. On 2026-09-30/10-01, `36df93fe`, `7d508d88`, `1a4c225e`, `4b5bfbea`
  and `1a34230d` landed by direct push with no PR, and no scan saw them. On
  2026-09-28 the coordinator measured 84 landings in a window where the tool
  saw 9 (DND-1009, filed then, still Todo).
- **The custom cursor is stuck.** It sits at `2026-09-30T20:45:44Z` (#172).
  #173–#177 are visible to `lead-time --since` and all measure, but the loop
  runs `--slow 90`, they are all under 90 minutes, and the cursor advances
  only to the newest row the filter printed. Every hourly run re-reads the
  same window and journals "#172 seen. No new rows."
- **Outliers only.** Typical values are never tracked, so a change that moves
  the median cannot be seen.
- **A date-only `--since` crashes** with a raw `Time.xmlschema` backtrace and
  no `Fix:` (DND-1009).
- **Two phases, both coarse.** `code` (dispatch → landing) is one number. In
  custom `tail` is always 0 (no CI). Nothing says whether the time went to
  implementation, the gate, critic rounds, the queue for an admiral, or the
  merge lock.
- **The phase data exists only in pieces.**
  - `harness-gate` appends per-check `wall_s` to
    `~/.local/state/athena/harness-gate/timings.jsonl`, keyed by head. No run
    id, no run wall time, no test-slot wait.
  - `critic-review` records `started_at` and `duration_s` per head, but in the
    **worktree's** `$GIT_DIR/critic-verdicts`. Removing the worktree after
    landing deletes them.
  - `integration-gate` receipts (`<common>/integration-receipts/<head>.json`)
    carry `recorded_at` only.
  - `locked-merge`, the custom ff push, and `test-slot` record no wait time.

## Decisions

1. **A second cron, `30 * * * *`, its own runner and installer.** It is
   modelled on the clustering runner (wedge, blocked, `.run` records,
   `--mcp-config` copy). It gets a per-run git lane like the shipwright's,
   because it lands harness changes. Reason: the owner's recommendation, and a
   lead-time run's work (measure, judge an experiment, land one change) does
   not fit inside the shipwright's 55-minute mining run.
2. **The session is an `athena-shipwright` in `MODE: lead-time`, not a new
   agent.** The shipwright already carries the lane, the commit wrapper, the
   forge identity and the safety-checks block verbatim. A new agent would add
   a resident baseline that every turn pays (*Harness information-architecture
   principles* #2). The procedure moves to a JIT skill,
   `athena:lead-time-improve`. The shipwright template's long lead-time section
   shrinks to a mode switch and a pointer, so the shipwright's resident size
   goes down.
3. **One loop owns lead time for every repo; only custom is improved.** A
   committed config, `ai/config/lead-time-repos.json`, lists each repo with a
   `mode`:

   **Later (2026-10-01):** that file is now only the default. The list is per
   machine, resolved by `ai/bin/lead-time-repos` (DND-1526), and the runner,
   installer and skill read only its result (DND-1527). Where the list comes
   from: `ai/bin/lead-time-repos --help`.

   - `improve`: full phase measurement, ledger, experiments, landed changes.
     custom only.
   - `watch`: today's shipwright behaviour moved verbatim (outlier scan,
     architect on a recurring shape, product changes filed as tickets).
     gen_saas and walt_ui.

   Reason: the brief asked to remove the lead-time section from the
   shipwright. Removing it outright would silently drop gen_saas and walt_ui
   coverage, which nobody asked for. Moving them in `watch` mode keeps
   coverage, keeps one loop acting, and makes "expand to gen_saas" a one-line
   config change.
4. **Measure every landing, not every PR.** A landing is a push to
   `refs/heads/main`, read from the GitHub activity log. It may come from a PR
   merge, an ff-landed PR, or a direct push. A landing's tickets come from
   its commits' subjects and its PR branch. An unticketed landing has no
   start: its lead is n/a, and its gate and merge phases are still measured.
5. **Phases, each n/a when unmeasurable, never 0.**

   | Phase | From | To |
   |---|---|---|
   | `implement` | dispatch stamp | first `harness_gate.run` for the unit |
   | `verify` | first gate run | last critic PASS for the unit before landing |
   | `queue` | last critic PASS | `integration_gate.run` start |
   | `integrate` | integration-gate start | its end (receipt) |
   | `merge` | integration-gate end | the landing push |

   Counters ride along: gate runs, gate wall total, slot wait total, critic
   rounds and BLOCKs, critic wall total, lock wait, the top per-check walls on
   the landed head. A missing anchor makes its two adjacent phases n/a with a
   reason. An anchor out of order (a gate before the dispatch stamp, from a
   re-dispatch) makes the phase `invalid` with a reason, never negative.

   **Later (2026-10-01, DND-1530):** the `implement` end is the first
   `harness_gate.run` **or `gate.run`** for the unit, and the gate counters
   read both. `gate.run` is written by test-slot for a declared gate other
   than harness-gate run under it (gen_saas's `bin/prep-commit.sh`). Before
   it, such a gate wrote nothing, so a repo whose gate it is could never get
   `implement` or `verify` measured, even in `improve` mode. A repo in
   `watch` mode still gets no phases, by design.

   **Later (2026-10-01, DND-1477):** as built, `verify` ends at the last clean
   critic PASS before the `integration_gate.run` start (before its end when
   only the receipt is known), not "before landing". A `--with-critic` PASS
   runs inside integration-gate, so ending there would make `queue` negative.
   A dirty PASS never counts. A ticket's events are bounded below by its
   previous landing, and telemetry is scoped to the repo it was written in.
   The normative description is `ai/bin/lead-time-phases --help`.
6. **Rolling window, typical and slow.** The ledger keeps every measured
   landing. The summary reports, per phase, over the last 20 landings: n
   measured, n n/a, median, p90, and the summed time. The biggest contributor
   is the phase with the largest summed time.
7. **On-system telemetry, one schema, one writer.** Specified below.
8. **One action per run, experiments judged before/after.** Specified below.
9. **Lands like any custom change.** Lane worktree, `harness-gate`, critic
   PASS, `integration-gate`, ff push with `custom-merge.lock` held around the
   push only (owner decision 2026-10-01: concurrent merges, stop-the-line on
   red, no forced re-gate because main moved; DND-1459, DND-1463). Never a
   product repo.
10. **Adopt DND-1009 rather than file a duplicate.** It is the measurement
    bug this epic needs fixed first, filed 2026-09-28 and still Todo.

## Telemetry

Owner scope: instrumentation "on-system only", added wherever a phase reads
n/a or is too coarse.

- **Contract:** `ai/contracts/athena-telemetry.md` (a living normative
  document, created by the writer ticket). This section is the design; the
  contract wins once it exists.
- **Event line:** one JSON object per line.

  ```json
  {"v":1,"event":"harness_gate.run","at":"2026-10-01T05:26:35.123Z",
   "duration_s":126.4,"unit":"DND-1463","unit_source":"branch",
   "repo":"custom","head":"<40 hex or null>","host":"<short hostname>",
   "pid":12345,"attrs":{"jobs":8,"slot_wait_s":41.2,"ok":true}}
  ```

  `at` is the start (UTC, ms). `duration_s` is null for a point event.
- **Unit of work:** resolved once, in the writer. `ATHENA_UNIT` if set, else
  a ticket id parsed from the current branch, else the branch name, else
  `null` with `unit_source: "none"`. It uses the same ticket-ref parser
  `lead-time` uses: one parser, not two.
- **Event registry:** `ai/telemetry/events.json` names every event and its
  allowed attrs and types. An unregistered event or attr is dropped and
  counted, never written. Strings are labels only: at most 120 characters, no
  newline. No argv, no environment, no message bodies, no secrets, no work
  values. A check asserts every emitter's events are registered.
- **Writer:** `ai/lib/athena_telemetry.rb`, used in-process by the Ruby
  emitters. `ai/bin/telemetry-emit` is the CLI for shell emitters. It is the
  same library, so there is one implementation.
- **Store:** `${XDG_STATE_HOME:-~/.local/state}/athena/telemetry/<UTC date>.jsonl`.
  Directory mode 0700, files 0600. Each line is one `write(2)` with
  `O_APPEND`, capped at 4096 bytes (attrs truncated, `attrs_truncated: true`).
- **Fails open, observably.**
  - A write error never raises, never changes an exit code, never retries.
  - Each failure or drop increments a counter file, `telemetry/write-failures`.
  - The reader reports that count with every summary, so a missing event is
    never read as "nothing happened".
  - The reader keeps "no store" (could not look) distinct from "no events for
    this unit" (n/a, with the unit it searched for).
- **Retention:** 30 days (`ATHENA_TELEMETRY_RETAIN_DAYS`). The improver
  runner prunes each tick (`telemetry-emit --prune`). Per-day files are the
  rotation. A day file over 64 MiB stops taking appends for that day; the
  drops are counted, so a runaway emitter cannot fill the disk.
- **Cost:** in-process appends in the gate and the critic. A shell emitter
  costs one Ruby start, run outside any check's own execution under
  `timeout 2`. Not wall-clock tested (DND-1222).
- **First emitters**, the ones the phase table needs:

  | Emitter | Events | Feeds |
  |---|---|---|
  | `harness-gate` | `harness_gate.run` (wall, jobs, slot wait, ok), `harness_gate.check` (label, wall, ok) | `implement` end, `verify`, per-check walls |
  | `test-slot` | `test_slot.wait` (pool, weight, wait, outcome) | slot wait under gate and critic |
  | `critic-review` | `critic.round` (verdict, duration, carried, slot wait) | `verify` end, critic counters; survives worktree removal |
  | `integration-gate` | `integration_gate.run` (duration, exit, head, base) | `queue`, `integrate` |
  | `locked-merge`, custom ff push | `merge.lock_wait`, `merge.landed` (before/after sha) | `merge`, lock wait |
  | `mark-in-progress`, `fleet-report admiral-scope` | `ticket.dispatched`, `mission.status` | dispatch cross-check, captain DONE → boarding |

  **Later (2026-10-01, DND-1475):** the custom ff push emits
  `merge.landed` (via=push) only. Its lock is taken by hand, so its
  `merge.lock_wait` reads n/a until DND-1370 gives that path a tool;
  `locked-merge` emits both.

## The improvement procedure (`athena:lead-time-improve`)

Each `improve`-mode run does these steps in order:

1. **Prune and ingest.** Prune telemetry. Ingest every landing since the
   repo's cursor into the ledger (idempotent by landing sha). The cursor
   advances to `scanned_through` and never on `SCAN INCOMPLETE`.

   **Later (2026-10-01, DND-1490):** a squash landing's sha is the forge's
   commit, so receipts, verdicts and timings keyed on the gated head never
   joined it. On the live ledger at 2026-10-01T12:30Z, 154 of 535 custom rows
   (of 160 merge rows) had a phase reading "merge landing: ... is the forge's
   commit, not the gated head"; in the other 6, no phase fell back to a
   head-keyed source (telemetry matched by unit). `lead-time` now emits each
   PR row's head as `head_commit`, and ingest joins on it (the row's
   `gated_head`). The ledger stays first-write-wins: a plain re-ingest never
   rewrites a row. The backfill is explicit, `lead-time-phases --ingest
   --since WHEN --rejoin`: it replaces only merge rows ledgered with no gated
   head, keeps any row whose fresh copy lost a measurement, and appends each
   original to `ledger-replaced.jsonl` first.
2. **Judge pending experiments first.** An experiment whose comparable
   after-set has reached K is judged before anything new starts.
3. **Pick the biggest contributor** from the window summary. If that phase is
   n/a on more than half its rows, the finding is "cannot measure X", and the
   action is instrumentation.
4. **Act once:**
   - land one small, safety-preserving harness change; or
   - land one instrumentation change; or
   - spawn ONE `athena-architect` for a larger design, which files DND tickets
     on the improvement epic named in the config; or
   - record "no action" with the reason.

   No new experiment may start on a phase that already has one pending.
   Two changes on one phase confound each other. Instrumentation is exempt,
   because it does not move a duration.

   **Later (2026-10-01, DND-1508):** the improvement epic is a standing epic
   that never closes, distinct from the epic that built the loop. The config
   first named the build epic, so the first live run filed its tickets on an
   epic meant to close. `improvement_epic` now names the standing epic.

   **Later (2026-10-01, DND-1529):** "one pending change per phase" held per
   machine only: `experiments.jsonl` is machine-local, and the desktop and
   the laptop both land harness changes in custom (residual R1 of the
   multi-project design, on the epic's Architecture & Engineering page). Every
   change, instrumentation change and revert now lands with the commit
   trailer `Lead-time-experiment: <measured repo> <phase> <metric>`
   (`ai/lib/lead_time_trailer.rb`); `record` refuses a commit without the
   matching one (exit 2), and records already stored are not re-validated.
   Judge reads custom's main (the runner's own repo; and the measured repo's
   main when it is another, for a product-repo PR) for trailers committed
   between the before-set's first landing and the after-set's last. A
   trailer for the same phase from another commit, other than the
   experiment's own and a revert of it, from any machine and any measured
   repo, makes the verdict `confounded`: recorded, terminal, treated as
   inconclusive, naming each other commit. It is never keep and never
   revert. Instrumentation stays exempt both ways. A log judge cannot read
   is exit 3, never "no confounder". No threshold or guard moved. A
   product-repo lane commit carries the trailer (`leadtime-product cut
   --metric` records it, and `pr` refuses a lane with no commit carrying
   it), because locked-merge's squash keeps commit messages, not the PR
   body.
5. **Journal** in `ai-artifacts/lead-time/journal.md`, with a *Decisions /
   Won't-change* section the next run honours.

**The hard constraint** is `ai/blocks/ops/safety-checks.md`, which the
shipwright carries verbatim: faster, never weaker. A change that drops, skips,
downgrades or path-excludes a check is never an improvement. Moving a bar
stays with Cody (`~/.claude/CLAUDE.md` → *Owner approval policy*, item 5).
`integration-gate` exit 4 still fires mechanically for a check's suppression
list.

**Experiments** live in `ai-artifacts/lead-time/experiments.jsonl`, one row
per landed change: commit, phase, metric, hypothesis, the baseline (n, median,
p90 over the last K comparable landings), and a status.

- **Comparable:** same repo, same metric measured on both sides, excluding
  the experiment's own landing. A phase that telemetry added after the
  baseline was taken has no before-set, so it is `n/a`, never compared.
  (A cross-repo experiment splits at `live_at` and excludes no landing: see
  the DND-1528 note under *Revert*.)
- **K = 10 per side.**
- **Keep** when the median falls at least 10%, the p90 does not rise, and the
  quality guards do not worsen. The guards are: critic BLOCK rate, gate red
  rate, and reverts on main.
- **Revert** when the median rises or a guard worsens. The revert lands
  through the same path.

  **Later (2026-10-01, DND-1547):** a revert can conflict with the hard
  constraint. custom:integrate:25c8114295af was judged revert on its median
  alone (every guard improved), but reverting it would delete a self-test
  assertion and bring back an orphaned-process leak. The tool could not record
  the shipwright's refusal, so `REVERT OWED` repeated every run and integrate
  admitted no new change. `experiment decline --constraint
  <safety-checks|bug-fix> --reason-file F` now records a `declined` status:
  terminal, never a gain, and not blocking its phase. It is admitted only on
  a latest status of `revert` whose guards are all measured and not worse. A
  revert a worse or unmeasured guard drove is never declined: land it, or a fix-forward an architect
  tickets. Judge never writes `declined`; only the verb does. Keep's
  thresholds are unchanged.

  **Later (2026-10-01, DND-1548):** an experiment was judged only on a phase,
  a total or a counter. custom:integrate:25c8114295af's check fell
  120 s -> 5 s, yet the integrate median rose: the other checks grew +180 s
  and the gate run rate rose 57%. The phase measured the fleet's load, not
  the change. A change may now be recorded on `--metric check:<label>`, the
  wall of one harness-gate check on each landing's gated head. Ingest writes
  it as `check_walls` (`{label => wall_s}`, from the same reader as
  `top_checks`, which is now its top 5), or `check_walls_na` with the reason.
  Rows ingested earlier have no key, so a check metric has no before-set on
  them: pending, never a gain. Record refuses a label that matches no check
  on the last `window` landings that carry `check_walls` (exit 2, the
  closest labels named) and reads no landing with `check_walls` as could not
  look (exit 3). Judge prints the
  phase median beside the verdict, labelled context; it never feeds it. The
  verdict rules, thresholds and guards are unchanged, `--phase` still admits
  the experiment, and no recorded experiment changes its metric.

  **Later (2026-10-01, DND-1549):** the revert rule was mechanical, and only
  the shipwright's judgement caught that reverting
  custom:integrate:25c8114295af would delete a self-test assertion. `record`
  now stores `revert_deletes_tests`: the commit's paths where
  `FirstParty.test_path?` holds and lines were added (`git show --numstat`),
  or `revert_deletes_tests_na` with the reason, never `[]` for unknown. A
  revert verdict (fresh or owed) whose record lists a test, or carries
  `_na`, prints `REVERT HELD` with the paths and a Fix: a partial revert
  that keeps the tests and git's `This reverts commit <sha>.` line (judge
  records `reverted` only from it), or `decline --constraint safety-checks`
  when decline would admit it. A record written earlier has no field, and a
  record-time `_na` may have been a one-off, so judge computes either with
  the same adapter. The status stays `revert`, a fresh revert's status row
  gains a `held` field, and judge's tally counts held on its own. No threshold or
  guard moved, and nothing becomes keep.

  **Later (2026-10-01, DND-1528):** an experiment's commit had to be on the
  measured repo's main, and the split was that commit's own landing row. A
  harness change for gen_saas lands in custom, so a gen_saas improve run
  could never record one. `record --change-repo C` (default: `--repo`) now
  takes a commit on C's main. The split is `live_at`, when it went live on
  C's main: the `landed_at` (push or merge time) of C's first ledger row
  whose landed commit carries it (`live_at_source: ledger`). Until such a
  row is ingested, it is the committer time of the commit's first-parent
  landing (the commit, or the merge that brought it in;
  `live_at_source: committer`). A fast-forward push follows that time,
  often by the whole gate and critic round, so record warns, and judge
  splits at the ledger time once a row carries it. Never the author date.
  The measured repo's landings before it are the before-set, those after
  it the after-set, and none is excluded. The row records `change_repo`,
  `commit`, `live_at` and `live_at_source`; judge and list print them. One
  commit can be an experiment on custom and on gen_saas at once, with
  different ids; their verdicts are judged apart and never reconciled. The test-additions read
  (DND-1549) and the owed revert use C's git: a revert is of that commit in
  C. C resolves as `ai/bin/lead-time-repos --repo-path C` prints: its
  configured path, or, for the runner's own repo (custom), its main checkout
  from `git rev-parse --git-common-dir`, even on a machine that does not
  measure it. An unresolvable C is refused (exit 2, Fix:). A same-repo
  record is byte-identical to before.
- **Pending** while either side has fewer than K. A pending row is never
  reported as a gain. Still pending after 7 days: journaled as inconclusive,
  and it no longer blocks its phase.
- An instrumentation change succeeds when its phase's n/a share falls.

## Build plan: what each step consumes and who creates it

Per `~/dev/custom/CLAUDE.md` → *can step N's inputs exist at step N?*

| # | Ticket | Consumes | Created by |
|---|---|---|---|
| 1 | DND-1009: every landing measured | git, the activity log, Notion stamps | exists today |
| 2 | DND-1473: telemetry writer + contract + registry | nothing new | — |
| 3 | DND-1474: verify-phase emitters (gate, test-slot, critic) | writer, registry | 2 |
| 4 | DND-1475: merge-phase emitters (integration-gate, locked-merge, ff push) | writer, registry | 2 |
| 5 | DND-1476: dispatch/mission emitters | writer, registry | 2 |
| 6 | DND-1477: phase ledger + window summary (`lead-time-phases`) | landing rows; telemetry schema; events from 3–5 | 1; 2; 3–5 |
| 7 | DND-1478: `athena:lead-time-improve` skill + experiment compare | ledger, summary | 6 |
| 8 | DND-1479: runner `scripts/athena-leadtime-run.sh` | the skill in the main checkout | 7 |
| 9 | DND-1480: installer, the shipwright/doc sweep, live install | runner; emitters live | 8; 3–5 |

Off the path: DND-1481 extracts the lock, wedge and lane code the three cron
runners will share into `scripts/lib/`.

- Step 6 is built and tested on fixtures. On real data, a phase whose
  emitter has not landed reads **n/a**, never 0. Its tests assert exactly
  that, so step 6 can land before 3–5 without manufacturing a baseline.
- Comparable series: the dispatch → landed total, and the `merge` phase from
  receipts, are measurable back through the activity log's history. Telemetry
  phases start the day their emitter lands. Before that they are `n/a`, and
  no before/after crosses that line.
- Step 9 installs the cron only after 3–5 are live, so the first run measures
  real phases. It removes the shipwright's lead-time section in the same
  change that turns the new loop on, so there is no window with no loop and
  none with two.

## Where things live (once built)

| What | Where |
|---|---|
| Repo list and modes | `ai/config/lead-time-repos.json` |
| Telemetry schema and rules | `ai/contracts/athena-telemetry.md`, `ai/telemetry/events.json` |
| Procedure | `ai/skills/athena:lead-time-improve/SKILL.md` |
| Runner, installer | `scripts/athena-leadtime-run.sh`, `scripts/setup-leadtime-cron` |
| State (gitignored) | `ai-artifacts/lead-time/`: `ledger.jsonl`, `experiments.jsonl`, `journal.md`, `cursor.<repo>.txt`, `runs/` |
| Telemetry store | `$XDG_STATE_HOME/athena/telemetry/` |
| Operations summary | `~/dev/custom/CLAUDE.md` → *Lead-time improver cron* |

## Who may do what

This is single-user, on-machine harness work. Who and how:

- The cron runs as the owner's user.
- It writes only `~/dev/custom`, through the normal landing.
- It writes Notion through `notion-personal`, only for DND tickets an
  architect files.
- It never touches a product repo. The lane is a custom worktree, and
  `watch`-mode repos are read-only to it.
- Telemetry files are 0600 in a 0700 directory, and the registry keeps
  secrets and work values out by construction.
- Running the installer is a *Notify after* item
  (`~/.claude/CLAUDE.md` → *Owner approval policy*). It runs from the main
  checkout after landing; the coordinator's session authorizes it on this
  machine.
