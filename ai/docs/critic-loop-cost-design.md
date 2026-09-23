# Critic-loop cost + judge-variance — architect design (2026-09-21)

Commissioned by the 2026-09-21T06:00Z shipwright run from an `athena-architect`,
against the safety-checks constraint (make a safety check FASTER, never WEAKER).
**Not implemented this run — deliberately.** The design's own step 1 is
measurement infrastructure, and landing later steps first would assert a win
nothing measured (harness-IA principle 8). This file is the next run's primary
work item.

## Evidence that commissioned it

- notif-platform C-1/DND-232: **28 rounds**; H-2/DND-246: **14**; C-2: 9;
  DND-260: 8. kg-oauth-https: rounds 12, 14, 17.
- Judge variance, DND-260: the critic called ONE unchanged, architect-ruled hunk
  a "Note (read as intended)" in round 6 and a blocking `[scope]` in round 8.
  Cost an architect consult plus a whole extra captain dispatch.
- Counter-evidence that makes this design-weighty rather than a quick edit:
  notif-platform state.md:174, a COORDINATOR CORRECTION retracting the admiral's
  own "any BLOCK -> park" rule as "round-count fatigue, too strict… Round count
  NEVER converts a kind-1/kind-2 into a park." A naive round ceiling was already
  tried and rejected as weakening.

## Three facts the architect established first (two change the lever)

**F1. The judge is fed the diff and nothing else.** `critic-review#critic_output`
builds its whole prompt from `git diff base...HEAD`. No round number, no prior
report, no commit messages. Every round is an independent cold sample — the
mechanical cause of the DND-260 flip.

**F2. The rubric claims a check it cannot perform.** `ai/agents/athena-diff-critic.md:55`
lists `convention — … (commit format, naming, …)`. Per F1 the critic never sees a
commit message. This is a live *A claimed mechanism must be able to fire*
instance inside the judge's own rubric. Fixing it is the same edit as P2-B.

**F3. Problem 3's premise is false.** `base...HEAD` is a THREE-dot (merge-base)
diff, so main moving forward does NOT change the diff text. The H-2 rounds were
not invalidated in content; what a rebase invalidates is the per-SHA receipt, by
construction. The round-14 BLOCK was a `CHANNEL_RESOLUTION` row the captain
added mid-loop — non-exhaustiveness (P1), not stale base.

## Explicitly rejected (record these; do not revisit without new evidence)

- **A round-count ceiling on kind-1/kind-2.** Already tried and retracted by the
  fleet. Textbook weakening: a real finding stops blocking because a counter hit
  a number.
- **A block/advisory severity split** ("convention findings land with a
  follow-up"). This is the forbidden move named in `safety-checks.md`
  ("downgrading an approval/review gate to advisory"). If `convention` should
  leave the blocking rubric, that is an OWNER scope decision applied uniformly
  before any loop runs — never a per-loop escape hatch. Architect recommends
  keeping it: DND-247's convention findings were the failed-lookup class in
  prose, the class this harness is most burned by.
- **A descent metric based on finding COUNTS.** Not buildable today: the receipt
  records the trailer's comma-separated KIND list, not a count, and grepping the
  body for `^\s*-\s*\[` is the exact format-specific defect already removed from
  this script (DND-184). Needs a new required `FINDING-COUNT:` trailer parsed by
  BOTH `critic-review` and `critic-eval` — separate ticket (P1-C).
- **"Never raise `[scope]` outside the reviewed delta."** Would not have fired —
  DND-260's declaration came from `95b0388`, ON the branch, inside the delta.

## The design

**P1-A — exhaustiveness obligation on the judge.** New Procedure step in
`athena-diff-critic.md.in`: report every defensible finding this pass, do not
stop at the first. Descending one finding per model round is the cost; a defect
first raised at round 14 is non-exhaustiveness. Strictly strengthening — can only
ADD findings. Honest limit: removes an instruction-level reason to withhold,
cannot remove sampling nondeterminism.

**P1-B — a loop ledger.** `ai/bin/critic-review --rounds` (a FLAG, not a new bin:
`verdict_dir` resolves the store, and a second executable re-deriving that path
is a second copy of a key computation). Prints per-round sha/verdict/kinds/Δ and
a repeat-kind-set signal. Empty store is its own state, never "round 1". Reporter
→ `EXEMPT` in check-guard-messages, answers `--help` per check-bin-help. Then
extend `warn_round_notice` with a NOT-DESCENDING line when the last three rounds
carry an identical kind-set, pointing at critic-convergence's class-sweep.
Print-only: `decide` and the exit codes are untouched, which is also why
non-descent is deliberately NOT a gate failure (a red gate on round count creates
pressure to override the judge — that is the weakening).

**P2-A — the judge sees its own prior rounds, as evidence never permission.**
Runner feeds the two most recent BLOCK receipts WITH their `.report.txt` bodies
(persisted as of `a3ec7ee`, landed 2026-09-21), byte-capped with an explicit
elision line, placed LAST so the rubric-stable prefix stays cache-hittable
(harness-IA #5). Agent gains a *Prior rounds are evidence, never permission*
section: may never withhold because an earlier round was silent; must flag a
reversal explicitly naming the prior SHA; must VERIFY claimed fixes (new catch —
a falsely-claimed fix is invisible to a cold judge). **Hazard: anchoring.** An
instruction cannot guarantee non-suppression, so P2-A MUST NOT land without P2-C.

**P2-B — a `Scope-Note:` commit trailer, for `[scope]` only.**
`Scope-Note: <hunk> — <why inseparable> (ruled by <authority>, <date>)`.
Written per an admiral/architect ruling handed down in the dispatch brief
(`athena:dispatch-captain`), so a captain cannot self-issue one — the laundering
hole is closed structurally. Critic rule: a trailer is a CLAIM, not a waiver; a
trailer that does not describe the hunk it names is itself a `[convention]`
finding; it can NEVER answer correctness/tests/access-control/guardrail. Genuine
creep still exits 2 either way (no trailer → `[scope]`; false trailer →
`[convention]`, which is new coverage). Side effect: feeding commit messages
closes F2.

**P2-C — the guard that makes P2-A's claim checkable.** `critic-eval` already
scores the judge at recall ≥ 0.8 / precision ≥ 0.8. Extract the prompt builder to
ONE copy (`critic-eval#run_model` and `critic-review#critic_output` build it
twice today — diverging them means the eval stops testing the shipping prompt).
Add fixtures: `08-anchored-reversal-bad` (real authz defect + a prior report
calling it benign), `09-scope-note-good`, `10-false-scope-note-bad`,
`11-claimed-fix-not-applied-bad`. **Why it can fire:** if the critic anchors,
`parse_findings` returns `[]`, score counts a MISS, recall falls below 0.8, and
`critic-eval --run` prints BELOW BAR exit 1 — distinguishable from healthy.
Model-in-loop, so it is the `critic-eval` tier, NOT `harness-gate`.

## Problem 3 — NO CHANGE (captains should keep not rebasing)

Per F3 the premise fails. A rebase invalidates only the receipt; the admiral must
re-critic the integration head regardless and `athena:merge-boarding` already
requires it. Moving the rebase into the captain costs a model round per captain
and buys a verdict stale the moment another captain merges. Residual, named not
fixed: a captain-side critic cannot see siblings' landed changes, so the
"clean rebase is not a clean reconcile" class is catchable ONLY at the admiral's
integration-head re-critic — which is why a captain's PASS is not a merge
authorization, enforced by `--verdict-for <integrated-sha>` exiting 3 on any
other SHA.

## Implementation order (do not reorder — step 1 is the baseline)

1. **P2-C** — extract `ai/lib/critic_prompt.rb`, add fixtures 08–11, record the
   BEFORE recall/precision from `critic-eval --run`.
2. **P2-B** — commit messages into the prompt; rubric scope/convention text;
   dispatch-captain writer rule. Fixtures 09/10 must pass.
3. **P2-A** — prior-round context + the new section. Fixtures 08/11 must pass;
   **if recall drops, the section IS anchoring — revise or revert.**
4. **P1-A** — exhaustiveness. Precision must not fall (two-sided bar).
5. **P1-B** — ledger + not-descending line; extend `critic-review --self-test`
   to assert empty-store ≠ round 1.

Nothing in 1–5 touches `decide`, the exit codes, `integration-gate`, or the merge
bar. The set of things that block a merge is identical before and after; three
classes start being caught that are not caught today (falsely-claimed fix, false
in-diff scope justification, commit-format conventions).

## One item for the OWNER, not the shipwright

Whether `convention` stays a blocking rubric kind. Architect recommends yes and
designed around it rather than through it, but it is an owner scope decision and
the only version of the severity split `safety-checks.md` permits.

**Later (2026-09-21, 07:00Z shipwright run):** step 1 is **half done**. The
`ai/lib/critic_prompt.rb` extraction landed (`daaf9c8`) with both bins calling
the single builder and `critic-review --self-test` asserting the single-copy
property by red/green flip. What step 1 still owes before step 2 may start:
fixtures `08-anchored-reversal-bad`, `09-scope-note-good`,
`10-false-scope-note-bad`, `11-claimed-fix-not-applied-bad`, and the recorded
BEFORE recall/precision from `critic-eval --run`. Those need the model in the
loop, so they are a deliberate unit of their own rather than a tail on the
refactor. **Steps 2–5 remain blocked on that baseline** — the ordering rule in
*Implementation order* is unchanged, and landing P2-B/P2-A without the BEFORE
numbers is the exact "assert a win nothing measured" this design forbids.

**Later (2026-09-21, 08:00Z shipwright run):** this design was promoted from
`ai-artifacts/shipwright/pending/2026-09-21-critic-loop-cost-DESIGN.md` (which
is gitignored local runtime state) to this committed home, once step 1a landed.
Two runs had amended it and a third depends on it, and a lane teardown or a
cursor reset would have lost it with no `git` undo — the same reasoning that
puts the hook registry and the inbox registry under committed source of truth
(`CLAUDE.md`). The consulting architect recommended `ai/proposals/`; that
directory is itself gitignored (`.gitignore:8`), so promoting there would have
changed nothing while reading as durable. `ai/docs/` is the tracked home the
sibling designs already use (`admiral-500-design.md`, `admiral-eval-design.md`,
`captain-500-design.md`). This file is now canonical; the `pending/` copy is a
pointer.

---

**Later (2026-09-21, 08:00Z shipwright run — architect consult):** the
*Implementation order* below REPLACES the five-step list above, and the
`Later (2026-09-21, 07:00Z)` note's description of what step 1 still owes.
Reason: **step 1 as written was not executable.** `CriticPrompt.build` takes
`diff:` and nothing else, and a fixture is exactly `input.diff` + `meta`
(`critic-eval#run_model`, `#parse_meta`) — so 09/10's discriminating input (a
`Scope-Note:` commit trailer) does not exist until P2-B, and 08/11's (a prior
round's report) until P2-A. Authored at step 1, `09-scope-note-good` is
*mislabeled*: a cold judge shown its diff alone correctly raises `[scope]`,
`score` counts a `false_pos`, BEFORE precision is depressed, and P2-B is then
credited with a gain that is only the label becoming true. 08 degenerates into a
near-duplicate of `01-missing-authz-bad`; 11 has no discriminating content. A
baseline that cannot observe what it is credited with observing is the *A
claimed mechanism must be able to fire* instance this design's own ordering rule
exists to prevent. (The generalised rule now lives in `CLAUDE.md` → *The same
question, asked of a PLAN: can step N's inputs exist at step N?*)

### Implementation order (do not reorder; each step's inputs are named, and the step that creates them)

**Step 1a — BASELINE. LANDED 2026-09-21 (`3f49022`).**
Consumes: the current corpus (01–07) and the extracted builder (`daaf9c8`).
Creates: the frozen-core baseline.
- `ai/bin/critic-eval --run` ×3 over 01–07, recorded as a **per-fixture hit
  table** plus `corpus` membership in `ai/eval/critic-baseline.json`.
- Measured: every bad fixture 3/3; one false positive, run 1 only, on
  `07-faster-check-same-guarantee-good` (run aggregates 1.0/0.8, 1.0/1.0,
  1.0/1.0). A single run would have recorded either 1.0/1.0 or precision
  exactly on the trust bar, on sampling alone.
- Corroborates — does not prove — that `daaf9c8` left shipping behaviour
  unchanged. The **proof** is the deterministic `critic-review --self-test`.

**Step 1b — FIXTURE-INPUT DECLARATION (deterministic, no model calls). LANDED 2026-09-21 (09:00Z run).**
Consumes: nothing new. Creates: the mechanism that makes a mis-ordered fixture
an error instead of a number.
- `CriticPrompt` exposes `SUPPORTED_INPUTS` (today `[:diff]`), the single source
  of which prompt inputs exist.
- A fixture's `meta` gains two additive keys: `requires=` (comma-separated input
  tokens; absent ⇒ `diff`) and `since=` (the step that introduced it; 01–07 get
  `since=core`).
- `critic-eval --run` **refuses to score** — exit 1, `Fix:` naming the fixture
  and the missing input, no score printed — any fixture whose `requires` token
  is absent from `SUPPORTED_INPUTS` or whose declared input file is missing. A
  fixture that cannot be scored produces **no row**, so it can never be recorded
  as a `0`.
- `critic-eval --run --only <since-value>` scores a named subset, so the frozen
  core stays separately measurable after the corpus grows.
- `critic-review --self-test` gains one assertion: the shipping caller passes
  **every** key in `SUPPORTED_INPUTS` to `build`. This is the standing guard
  against an eval-only builder parameter — the divergence the `daaf9c8`
  extraction exists to prevent. Stated limit: it proves the keyword appears at
  the call site, not that a non-empty value flows; it catches forgotten wiring,
  which is the measured failure mode.
- Both deterministic and model-free; `critic-eval --run` stays outside
  `harness-gate`, both self-tests stay in it.

*As landed, with two additions the written step did not name.* `SUPPORTED_INPUTS`
is derived from a single `CriticPrompt::INPUTS` table (token → `{key, file}`)
rather than standing alone, so the corpus-facing token a fixture declares, the
keyword the shipping caller must pass, and the fixture filename cannot drift
apart — three names for one fact, declared once. And `--only <value>` matching
**zero** fixtures is an error, not an empty run: `score` returns recall 1.0 /
precision 1.0 / PASS over an empty row set, so a typo'd step name would
otherwise print a perfect score over nothing (*A failed lookup must never look
like an empty one*, inside the instrument that measures the judge). Both new
guards were verified by red/green flip — a planted `requires=prior-report`
fixture makes `--run` refuse and `critic-eval --self-test` go red; a planted
`INPUTS` entry the shipping caller does not pass makes `critic-review
--self-test` go red, naming the keyword.

**Step 2 — P2-B (commit messages).** Unchanged in content. Additionally:
`SUPPORTED_INPUTS` gains `:commit_messages`; `critic-review#critic_output`
passes them; `critic-eval` reads a fixture's `commit-msg` file. **Fixtures
`09-scope-note-good` and `10-false-scope-note-bad` are authored HERE**
(`requires=commit-msg`, `since=p2b`) — the first step at which their
discriminating input exists. Closes F2 as a side effect.

**Later (2026-09-23):** step 2's INPUT landed ahead of its content, under
DND-400. `CriticPrompt::INPUTS` now carries `commit-msg` (key
`:commit_messages`, fixture file `commit-msg`), and `critic-review` passes the
`base..HEAD` log. It was needed for the bug-fix regression-evidence addendum
(`CriticPrompt::BUG_FIX_RULE`), whose fixtures are `12`–`14` (`since=dnd-400`),
numbered past the `08`–`11` reserved here. The `Scope-Note:` trailer rule and
fixtures `09`/`10` are still unlanded. F2's "never sees a commit message" is no
longer true for runs through `critic-review` or a fixture declaring
`requires=commit-msg`.

**Step 3 — P2-A (prior rounds).** Unchanged in content. `SUPPORTED_INPUTS` gains
`:prior_rounds`; the fixture input is a `prior-report.txt`. **Fixtures
`08-anchored-reversal-bad` and `11-claimed-fix-not-applied-bad` are authored
HERE** (`requires=prior-report`, `since=p2a`). Existing rule stands: **if core
recall drops, the section IS anchoring — revise or revert.**

**Step 4 — P1-A (exhaustiveness).** Unchanged. Core precision must not fall.

**Step 5 — P1-B (ledger + not-descending line).** Unchanged; extend
`critic-review --self-test` to assert empty-store ≠ round 1.

### What the no-regression bar MEANS once the corpus grows

Three instruments, never collapsed into one number:

1. **Frozen core (01–07) — the regression instrument.** Never edited by steps
   2–5; its inputs are byte-identical at every measurement, so it is the only
   comparable series. The bar is **per fixture**: a core fixture that measured
   3/3 at step 1a and now measures ≤1/3, or any that goes from ever-HIT to
   never-HIT, is a regression and blocks the step. The judge is stochastic —
   with 4 bad fixtures one sampled miss moves aggregate recall 1.0 → 0.75,
   below the trust bar, from noise alone — so a single-run aggregate comparison
   is not evidence. N=3 does not make this statistically strong; it makes a
   *flip* distinguishable from *scatter*, which is what the bar needs and all it
   claims.
2. **Each capability fixture (08–11) — its own coverage instrument.** Its value
   before its enabling step is **undefined, recorded `n/a`** — never `0`, never
   MISS. Enforced by step 1b: an unscoreable fixture yields no row. After its
   step it must score HIT; it is *not* part of the no-regression series, having
   no before value to regress from.
3. **The mixed-corpus aggregate is not a cross-step comparison.** Recorded only
   alongside its `corpus` membership, as the current trust-bar reading (recall
   ≥ 0.8, precision ≥ 0.8 — unchanged).

Nothing in 1a–5 touches `decide`, the exit codes, `integration-gate`, or the
merge bar. The set of things that block a merge is identical before and after.
