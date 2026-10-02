# Capacity gate: which metric, and how to measure it

**Kind: dated record (design, 2026-10-02).** Later corrections are appended as
`**Later (<date>):**` paragraphs, never rewritten.

Asked by the owner, Cody, terminal, 2026-10-02 ~04:45Z: "let's figure out what
the best metric would be, and the best way to measure said metric."

Tickets (epic *Harness lane: test-slot, processes & machine hygiene*):

- **DND-1686**: passive sampler (*Measurement plan*).
- **DND-1687**: analysis (*Analysis*). Depends on DND-1686.
- **DND-1688**: the gate change (*Recommendation*). Depends on DND-1687 and on
  the owner approving the final threshold.

## Today's gate

`athena:dispatch-captain` → *Machine capacity gates every dispatch*. Before
each dispatch an admiral reads `cut -d' ' -f1 /proc/loadavg` and holds while
it is over 12. The owner's 2026-09-26 words name no number: "You have as many
captain slots as are enabled by the hardware (if you see load-based failures,
lower the number of captains)." 12 is a coordinator default, about 75% of 16
cores. Nothing calibrated it.

Known weaknesses:

1. A fixed number. The desktop and laptop each have 16 cores, and the laptop
   also hosts 4 gen_saas GitHub runners.
2. loadavg lags (an exponential average) and counts D-state tasks. On
   2026-10-02 it read 18 while `vmstat r` was 6-13.
3. It gates new dispatches only. Gates and suites already running are not
   gated: two harness-gates plus a dockerized gen_saas suite pushed load to
   21-37 that night, ~35% of CPU time in the kernel from fork churn.
4. Containerized tests run outside `nice` (DND-1325).

## What the gate protects, in order

1. **The owner's interactive use**: games, Zoom, the editor. The harm is
   latency: a runnable interactive task waiting for a CPU, or stalled on a
   page fault or IO.
2. **Gate and test reliability**: no load-induced failures (Postgres 57014,
   timeouts, kills). The harm is again waiting: a query or a test step whose
   wall time exceeds a deadline because it sat runnable but not running, or
   stalled on memory or IO.
3. **Throughput**: captains landing work. The harm is the gate holding when
   nothing above was at risk.

So the metric we want is **how much time work spends waiting for a resource**,
not how busy the CPU is. A 100%-busy machine where nothing waits harms nobody.
A machine at 60% busy where interactive tasks queue behind a fork storm harms
outcome 1 and 2 both. Throughput is the cost side: the threshold is chosen by
how often it would hold.

## Readings on this machine (read-only, 2026-10-02 04:3x-04:40Z)

Desktop, kernel `6.18.41-gentoo-dist`, `CONFIG_PSI=y`,
`CONFIG_PSI_DEFAULT_DISABLED` unset, no `psi=` on the command line, nproc 16,
swap 8 of 15 GB used.

| Source | First reading | Second reading (04:40Z) |
|---|---|---|
| `/proc/loadavg` 1/5/15 | 15.59 18.71 20.29 | 12.92 16.45 19.15 |
| `procs_running` (instant) | 3 | 17 |
| `/proc/pressure/cpu` some avg10/avg60/avg300 | 6.87 / 15.53 / 19.23 | 4.12 / 12.28 / 16.42 |
| `/proc/pressure/cpu` full | 0 / 0 / 0, total=0 | (same) |
| `/proc/pressure/memory` full avg10/avg60 | 0.02 / 0.04 | — |
| `/proc/pressure/io` full avg10/avg60 | 0.08 / 0.02 | — |
| `/sys/fs/cgroup/docker/cpu.pressure` some avg60 | 13.15 | 11.22 |
| `/sys/fs/cgroup/docker/cpu.pressure` full avg60 | 0.31 | 0.71 |
| `/sys/fs/cgroup/5/cpu.pressure` some avg60 | 0.94 | — |

What these establish, per CLAUDE.md → *A claimed mechanism must be able to
fire*:

- **System CPU PSI `some` fires here.** It moves with the load, it is not
  stuck at 0, and it read 12-16% while load was 13-19.
- **System CPU PSI `full` cannot fire.** At the root the kernel reports
  `full` as 0 (`total=0` since boot). Any design that reads root CPU `full` is
  reading a constant. Memory and IO `full` are live at the root.
- **The docker cgroup's CPU PSI fires,** `full` included. It isolates
  containerized suites (DND-1325's un-niced tests).
- **cgroup `/5` is not per-agent.** The Bash tool runs in `0::/5` with 232
  processes in it. Every agent session shares it, so cgroup PSI cannot
  separate one fleet from another, or the agents from the owner, without a
  cgroup layout change. That layout change needs root (`/sys/fs/cgroup` is
  root-owned), so it is a Cody-only step, not part of this plan.
  `openrc.user.cjpoll` reads all zeros; it is not where the owner's work runs.
- **`procs_running` is too noisy for a single-shot gate:** 3 then 17 within
  minutes, both instants.
- The laptop was not read. DND-1686's `--check` must read it there before any
  claim about the laptop holds.

## Candidates compared

| Metric | Measures | Lag | Portability | Failure modes | Shell cost |
|---|---|---|---|---|---|
| loadavg 1-min | runnable + D-state task count, exp. average | ~1 min time constant; reads high long after a burst | everywhere; absolute value means nothing without nproc | counts D-state (IO, NFS, fuse) as load; says nothing about waiting; 18 with 6-13 runnable | one `cut` |
| loadavg / nproc | same, normalised | same | better across core counts; not across extra tenants (the laptop runners) | same | `cut` + `nproc` |
| `procs_running` / `vmstat r` vs nproc | instantaneous runnable count | none; that is the problem | everywhere | single sample swings 3→17; needs averaging, which the gate would have to do itself | one `grep` |
| **PSI cpu `some` avg10/avg60** | % of wall time at least one runnable task waited for a CPU | avg10 ~10 s, avg60 ~60 s | kernel ≥ 4.20 with PSI enabled; % of time, so core-count independent | absent when `psi=0` or not built in (must hold, not read 0); root `full` is always 0 | one `sed` on one line |
| **PSI memory/io `full` avg60** | % of time ALL non-idle tasks stalled on memory (reclaim, swap-in) or IO | ~60 s | same | none seen; reads near 0 when healthy, as here | one `sed` |
| cgroup PSI (docker) | the same, for containerized suites only | same | needs cgroup v2 and docker's cgroup at `/sys/fs/cgroup/docker` | path differs by distro and init; cgroup `/5` mixes every agent | one `sed` |
| test-slot occupancy | units of the cpu pool held | none | ours, every machine | measures our admission, not the machine; un-slotted work (owner, runners, compiles) is invisible | `test-slot --status --json` |

Why PSI fits the outcomes: outcome 1 and outcome 2 are both "something
waited". PSI `some` is literally the share of time something runnable waited
for a CPU. loadavg is a queue length, which predicts waiting only on a fixed
machine with a fixed workload mix, and our mix changes (fork-heavy gates
versus long BEAM suites). Memory and IO `full` cover the thrash case that
CPU-only metrics miss, and swap is in use here.

Why not PSI alone without evidence: PSI `some` at 15% means "one task waited
15% of the time". That task may be a batch compile, not the owner's game.
Only the correlation against real failures and owner reports says which
level hurts. That is what DND-1687 measures.

## Measurement plan (DND-1686), passive only

DND-1222 is a Hard Rule: no stress or load runs and no repro fan-outs. All
evidence below is read from what the machine is already doing.

- **What to record.** One telemetry event, `machine.pressure`, per sample.
  Cumulative counters (PSI `total` µs for cpu some, memory some/full, io
  some/full, docker cgroup cpu some/full; `/proc/stat` user/system/iowait
  jiffies and the `processes` fork counter), so any window is an exact delta
  between two samples. Plus the point values the gate would read (cpu some
  avg10/avg60, memory full avg60, io full avg60, load1, load5,
  `procs_running`, `procs_blocked`, nproc, swap used, test-slot units held and
  waiters). An unreadable source is an absent attr plus a `read_error` label,
  never 0.
- **Cadence and length.** Once a minute from the user crontab (the
  shipwright and lead-time runners' pattern; no daemon to orphan). Counters
  make the minute cadence exact for any window ≥ 1 min. About 1 KB × 1440
  lines a day per machine. Run 14 days on the desktop and the laptop. The
  store's 30-day retention covers it.
- **Outcomes to join.** Already recorded, read-only: `harness_gate.run`,
  `gate.run`, `integration_gate.run` failures that are timeouts or kills;
  57014 and `CONTENTION:` reports in `ai-artifacts/coordination/*/reports/`
  (47 and 88 files on 2026-10-02); contention-census readings in those
  reports; `test_slot.wait`; owner slowness notes, entered with
  `ai/bin/owner-notes --add` and the word "slow". The owner's report is the
  only direct measure of outcome 1, so it is asked for once, in the digest,
  not repeatedly.

### What history already gives us

- Admiral state logs hold 366 `Load <v>` lines and 141 `holding` lines.
  Contention-census readings in reports carry loadavg at each failure. That
  is enough for a **loadavg-only baseline**: at what load did 57014 and
  timeouts happen, and how often did 12 hold.
- No telemetry event has a load or pressure attr today, and PSI was never
  recorded. So PSI cannot be judged from history. The 14-day window is the
  minimum.
- The telemetry store holds two days (2026-10-01, 2026-10-02). Older gate
  outcomes are in the coordination reports only.

## Analysis (DND-1687)

1. **Baseline from history** (no new data): loadavg against the failures
   above. This is the bar a new metric must beat.
2. **For each candidate,** compare the 10 minutes before each failure event
   with a matched sample of no-failure minutes. Report the ROC AUC, and per
   threshold the recall of failures and the **hold rate**: the share of
   dispatch-time minutes the gate would have held.
3. **Pick** the metric with the best AUC. Pick the threshold with the highest
   recall whose hold rate stays under 25% (the owner may set another budget).
   Per machine. Fewer than 10 failure events on a machine is "not enough
   events", recorded as `n/a`, never a threshold.
4. **The threshold goes to the owner.** Moving the gate's bar is item 5 of
   *Owner approval policy*; it stays with Cody.

## Recommendation (provisional; DND-1688)

- **Metric: system PSI cpu `some` avg60**, with memory `full` avg60 and io
  `full` avg60 as additional hold conditions. It measures waiting, which is
  the harm, and it is a percentage, so it ports across core counts and
  counts the laptop runners' load as the pressure it is.
- **Provisional thresholds: hold while cpu some avg60 > 15, or memory full
  avg60 > 2, or io full avg60 > 5.** 15 is near the cpu some avg60 that
  coincided with load 15-19 tonight, where today's gate already holds, so it
  is not looser than the current bar on the one evidence point we have. The
  memory and io numbers are conservative guesses. All three are replaced by
  DND-1687's numbers.
- **Until DND-1688 lands, the gate stays `loadavg > 12`.** Nothing here
  changes the live bar.
- **How the gate reads it.** A helper, `ai/bin/capacity-gate`: exit 0 clear,
  1 hold (naming each reading and threshold), 3 could not read (hold, with
  `Fix:`). An unreadable or absent `/proc/pressure` holds; it never reads as
  0. One reading clears one dispatch; never a count of slots. Thresholds live
  in landed config, ratcheted against `origin/main` (CLAUDE.md → *A check's
  own bar must not live in the diff it is checking*).
- **Running gates: admission, not preemption.** `test-slot` reads the same
  helper before it grants a NEW cpu-pool slot. It never pauses or kills a
  running suite: a paused suite turns pressure into the timeouts we are
  preventing. The stronger protection for outcome 1 is priority, not
  admission: docker's suites run un-niced (DND-1325). Lowering the docker
  cgroup's `cpu.weight` would protect the owner during a burst no gate
  anticipated; it is a root-owned write, so it goes to Cody as a step only
  they can run if DND-1687 shows docker pressure leads owner reports.

## Assumptions

- The laptop's kernel has PSI enabled. Unverified; DND-1686's `--check` reads
  it, and an absent PSI is a named hold, not a pass.
- Owner slowness notes will be sparse. If none arrive in 14 days, outcome 1 is
  judged from gate failures alone, and the analysis says so.
