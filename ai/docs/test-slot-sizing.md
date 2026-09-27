# test-slot sizing: how N is chosen, per machine

**Kind: dated record** (DND-489, 2026-09-27). It records what was measured on
its date and why N was set from it. Later measurements are added as new dated
sections; nothing here is rewritten to match later reality.

## What N is, and where it lives

`ai/bin/test-slot` bounds how many heavy gates run at once on one machine at
N. Each machine has its own pool under `~/.local/state/athena/test-slots/`,
and what a slot costs depends on that machine's hardware. So N is per machine:
`n_for_host` in `ai/bin/test-slot` maps a hostname to a measured N, and each
measured entry cites this record. A host with no entry gets `TEST_SLOT_N` (3)
labelled `provisional, unmeasured on host <name>`, and `--status` shows that
label. A miss is visible, never silent.

N changes only by a commit to `n_for_host`, landed on `main` and fast-forwarded
into the main checkout. That is the copy every caller runs
(`~/dev/custom/ai/bin/test-slot`). No per-machine file outside git holds it, so
nothing about N is owner-gated beyond the normal merge.

## The decision rule (fixed before measuring)

Measured with `ai/bin/test-slot-bench`. Its header states the rule; this is the
same rule.

- A level k is scored from its **clean** reps and needs at least `--min-reps`
  (2) of them; otherwise it is `n/a`, never 0.
- A rep is clean when, right before it starts, load1 has settled to at most
  `--bg-threshold` (2.0), no heavy run is going outside a slot (UNSLOTTED),
  and no slot the bench does not own is held. The same probe runs every 30 s
  during the rep. Any hit marks the rep CONTAMINATED, with the reason.
- k qualifies when every run of every clean rep passed and every clean rep's
  peak load1 is at most the **ceiling**.
- N is the largest scored k such that it and every lower scored k qualify.
  k=1 must qualify, or there is no baseline and the rule refuses.
- If the first failing level is more than one above N, the rule asks for the
  midpoint (3 passes and 5 fails: measure 4). It never extrapolates above the
  largest measured k.

**Ceiling = 12, not nproc (16).** The ticket's Product Requirements wrote the
ceiling as nproc. The owner directive of 2026-09-26 came later: hold captain
dispatch while 1-min load is over 12. A pool that alone pushes load over 12
would hold dispatch for as long as it is full. So the ceiling is 12. The bench
records the peak for every level, so the nproc reading can still be done from
the same data.

## Gate classes

What a slot costs depends on which gate holds it. On 2026-09-27 ~01:40Z, with
the pool full and read with no load added, three gen_saas prep-commits used
1-9 cores each (docker CPU 100-880%), and load1 reached 28-37. At ~01:30Z,
three custom harness-gates used 0.4-0.9 host cores each, and load1 was about
6. A single N sized for the heavy class leaves the machine idle when light
gates hold the slots. A single N sized for the light class overloads it when
heavy gates do.

So every run records its **gate class**, and `test-slot` itself derives it:
`"<repo>:<tool>"`, from the command's argv and the cwd only
(`test-slot --class -- CMD`, and the `class` field in holder JSON and
`events.jsonl`). A caller label never enters it. A shell running a string
(`bash -c ...`) is its own class, `<repo>:opaque`, and never a known tool's.
The bench records the class exactly as `test-slot` derives it, and `--decide`
refuses data that mixes classes. Weighted admission by class is a separate
ticket; this record supplies its per-class data.

## Method

- Gate: gen_saas `bin/prep-commit.sh`, default check mode (no `--fix`),
  class `gen_saas:prep-commit.sh`. N comes from this class, the heaviest.
- Second class, measured for the weights ticket and not for N: custom
  `timeout 1500 ./ai/bin/harness-gate`, class `custom:harness-gate`, levels
  1, 3, 5, one rep, in five detached custom worktrees at one SHA.
- Five gen_saas worktrees (`~/.local/worktrees/gen_saas/dnd-489-bench-{1..5}`),
  all at one pinned SHA. Each was bootstrapped (deps, compile, test DB) and
  warmed with one untimed prep-commit before measuring. So every measured run
  starts from the same warm state.
- Levels 1, 3, 5, two reps each, rep-major (1, 3, 5, then again). The whole
  run held every slot (`test-slot --exclusive`) in a quiet window. The
  coordinator held gate and test dispatch across the desktop fleets for it.
- Samples every 5 s: load1, load5, runnable count. Peak load1 is over the run
  plus a 60 s tail, because load1 lags. Mean load1 is over the run window.
- Raw data: `~/.local/state/athena/test-slots/bench/<utc>/` on the measuring
  machine (`runs.csv`, `levels.csv`, `load-*.csv`, census snapshots).

## Measurement: home-office-linux, 2026-09-27

**PARTIAL: the window was cut short because the owner needed the desktop.**
Pinned gen_saas SHA `37405cbaac5a6d91d66f4b68e38a89bf3facc965`, nproc 16,
class `gen_saas:prep-commit.sh`, bench output `bench/dnd-489-20260927T025250Z`.

| k | rep | passed | wall s | peak load1 | mean load1 | peak runnable | bg load1 | contaminated |
|---|---|---|---|---|---|---|---|---|
| 1 | 1 | 1/1 | 189.2 | 12.09 | 7.07 | 33 | 1.43 | no |
| 3 | 1 | n/a | n/a | n/a | n/a | n/a | ~8 | stopped during settle, no run |
| 5, and all of rep 2 | | not run | | | | | | |

One clean rep is below `--min-reps` 2, so no N is decided from this. One gen_saas
prep-commit alone reaches load1 12.09, which is already the ceiling. N stays at
the provisional 3 until the remaining levels are measured.

## Rollout

PENDING.

## Known limits

- One gate was measured. gen_saas prep-commit was the heaviest known gate. It
  is not the commonest slot holder: see *Gate classes* above.
- load1 is a damped 1-minute average. The runnable-count samples show short
  spikes that load1 smooths out.
- A heavy run inside a container started without a host-side prep-commit or
  full `mix test` is invisible to the UNSLOTTED probe. Only the load it adds
  is visible.
