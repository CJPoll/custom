# variant-eval — measured harness-variant selection (DND-174 / C3, reduced scope)

**Kind: dated record.** Written 2026-09-19. Records the reduced scope built for
the C3 pilot and the deferral rationale, so a later reader knows why the full
ADAS / Darwin-Gödel measured-adoption loop was NOT built here.

## What it is

`ai/bin/variant-eval` is a **measurement instrument**: given a candidate git ref
and a baseline ref, it measures the candidate against the existing eval corpus
and emits a **proposal** — a scorecard delta plus one of KEEP / REVERT /
INCONCLUSIVE. It is human-gated and proposal-only. It has **no** merge / commit /
push / adopt / `--update-baseline` code path; "adoption" is a human choosing to
merge the variant, and "revert" is the human simply not merging (the tool never
writes to the harness).

It runs entirely within git history: for each of {baseline, variant} it creates
a short-lived `git worktree add --detach`, runs the corpus there, collects the
per-case result set, and tears the worktree down.

## The finding that forced the reduced scope

The C3 ticket framed this as an ADAS / Darwin-Gödel loop: propose a variant, eval
it, **keep or revert on a measured delta**, automatically. Reading the existing
eval harness (`ai/bin/harness-eval`, `ai/bin/admiral-eval`,
`ai/eval/*baseline.json`) showed the premise does not hold yet:

- The "scorecard" is a set of per-case **binary pass/fail** verdicts, **not a
  numeric score**. A "delta" is a **pass-set diff**: `true->false` = regressed,
  `false->true` = fixed, plus new cases.
- There is **no noise band in code**. `admiral-eval` runs K-sample majority
  (`DEFAULT_RUNS=3`) and hands the ambiguous `2/3 -> 1/3` sampling-noise band to
  a **human re-run**. The committed `admiral-baseline.json` already carries a
  case at rate `2/3` — one flip from a majority-fail.

So a fully-automatic "measured improvement" verdict over the **model** signal is
not yet trustworthy: the harness itself defers sampling-noise disambiguation to a
human. Per epic Decision 5, the speculative measured-adoption core is **deferred**
and this pilot builds the deterministic + inconclusive-by-default reduced scope.

## What it does (built)

Corpora (`--corpus`):

- **deterministic** (default) — the exact / no-model portion:
  - `harness-eval` per-case pass-set (from its `scorecard.json`);
  - every `admiral-eval` **T1 hook-stdin** case (`mode=hook-stdin`).
  - Delta = **exact pass-set diff** (regressed / fixed / new). No sampling, no
    band — identical semantics to `harness-eval` / `admiral-eval`
    `diff_baseline`.
- **full** — additionally the `admiral-eval` **T2 model-in-loop** cases,
  characterized: run baseline ref `N` times for a per-case pass-fraction
  `p_base`, variant `N` times for `p_var` (`--runs N`, default **10** for the
  pilot). A fixed envelope **Δ_noise = 0.3** separates real delta from noise.

**Later (2026-09-24):** as built on 2026-09-19, `--corpus full` could not see a
prompt variant (DND-503). Both sides ran a bare `admiral-eval --run`, whose
`claude -p --agent athena-admiral` resolves the agent from `~/.claude/agents`, a
symlink to the **main checkout**, whatever the cwd. So baseline and variant
scored the same admiral and the T2 delta could only show noise. Now each side
runs `admiral-eval --run --agent-file <its worktree>/ai/agents/athena-admiral.md`,
and `admiral-eval` passes that file's prose inline (`--agents`) under a key no
agents directory supplies. Each side must print a `subject: … sha <12 hex>`
line matching the render it was handed, or variant-eval refuses to score. A ref
from before DND-503 ignores `--agent-file` and fails this check, so use a
`--baseline` at or after it. The proposal prints both subjects' sha and says
**IDENTICAL** when the variant does not change the render.

Gate short-circuit: before any delta, the variant ref is run through the standing
gate (`ai/bin/harness-gate`). A red gate short-circuits to **BLOCKED** with a
`Fix:` line, **before** scoring (never-commit-a-broken-harness).

Verdict:

| condition | verdict |
|---|---|
| variant gate red | **BLOCKED** (short-circuit, not scored) |
| any deterministic regression OR any T2 regression | **REVERT** |
| zero regressions AND ≥1 strict improvement beyond the envelope | **KEEP** — pending human gate |
| zero regressions, no improvement clears the envelope | **INCONCLUSIVE** — no improvement claim |

**Later (2026-09-24):** a fifth verdict, **UNMEASURED** (DND-504), ranks
between BLOCKED and REVERT. A side whose corpus ran but did not measure used to
read as "found nothing": a failed `admiral-eval` returned no T2 fractions, the
proposal printed `(no T2 cases evaluated)`, and the deterministic set alone
could print KEEP. Now each side must complete. For T2, `admiral-eval` exits 0
or 1 (1 is its own baseline-regression verdict), prints its closing
`admiral-eval: P/T cases pass` summary matching the rows, parses at least one
T2 row, samples every case, and logs no failed model invocation. For the
deterministic half, `harness-eval` exits 0 or 1 and rewrites the committed
`ai/eval/scorecard.json` during this run. Anything else is UNMEASURED, naming
the side, the corpus and the reason, with a `Fix:`. It is never KEEP or REVERT,
and it exits 1. A T1 hook that is missing or signaled now scores FAIL, never a
pass for `expect=clean` (admiral-eval's `:error` rule).

T2 flip classification (envelope Δ_noise): regression iff `p_base - p_var >
Δ_noise`; improvement iff `p_var - p_base > Δ_noise`; otherwise **inconclusive**.
A flip **within** the envelope is never a regression and never an improvement.
Deterministic cases use `N=1` and a 0-width envelope (an exact `1->0` is a
regression).

## Safety (structural, self-test-asserted)

variant-eval is security-relevant (a self-modifying-harness-adjacent tool), so
containment is **structural**, not merely documented:

- Every external command is funneled through a single guarded exec primitive.
  `command_allowed?` denies any `git merge/commit/push/rebase/reset/checkout/…`,
  any `gh`/`glab`/`gh-athena`/`glab-athena`, and any argv containing
  `--update-baseline`; only read-only git (`rev-parse`, `worktree`, …) and the
  read-only eval bins pass.
- `--self-test` (gate-wired; **no model, no git**) proves, over synthetic
  pass-sets and stub argv: (a) a `true->false` deterministic flip → REVERT; (b) a
  strictly-better zero-regression set → KEEP-pending-gate; (c) a within-envelope
  flip (`p_base=0.6, p_var=0.6`) → INCONCLUSIVE, never improvement/regressed; (d)
  no KEEP output contains an adopt/commit/merge command token; (e) a red-gate
  variant → BLOCKED before scoring; (f) every failure path carries `Fix:`. It
  also asserts `command_allowed?` denies each mutation family and that the source
  routes ALL execution through the one guarded call site (lexed with Ripper so
  the scan does not false-match its own comments/prose).
- The model-in-loop measurement run (`--variant … --corpus full`) stays **out of
  the gate**, like `admiral-eval --run` / `critic-eval --run`.

## Boundary with the shipwright cron loop

variant-eval is human-gated, proposal-only, and triggered by a **handed** variant
ref. It must **not** wrap measurement in an auto-adopt loop — that would collide
with the shipwright's autonomy and violate C3's human-gate AC. It reuses
`admiral-eval` / `harness-eval` as its selector; it does **not** invent a second
corpus and it is **not** a second autonomous committer.

## Deferred (recommend a follow-up ticket)

- **The full measured-adoption loop** (auto keep/revert on a measured delta) —
  deferred per epic Decision 5 until the T2 model signal is trustworthy enough
  for an automatic verdict.
- **A T2 noise-characterization study** — the Δ_noise = 0.3 envelope and the
  `--runs 10` depth are **pilot values**, not empirically derived. A follow-up
  should characterize the real per-case flip distributions of the T2 corpus
  (across many samples) and set the envelope / sample depth from measured
  variance, replacing the fixed pilot constant. Until then, T2 deltas are
  reported but the trustworthy verdict remains the deterministic pass-set diff.
