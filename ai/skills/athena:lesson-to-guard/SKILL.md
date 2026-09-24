---
name: athena:lesson-to-guard
description: Turn a journaled lesson into an executable guard — triage whether the mistake is machine-catchable, then scaffold a check/hook + its self-test, wire it into the gate, and add a regression case to the eval corpus. Use when a lesson (a recurring or unambiguous mistake) should become a durable automated guardrail instead of prose nobody re-reads.
---

# athena:lesson-to-guard

A lesson written down is a lesson half-kept — prose guidance gets skimmed, then
the same mistake recurs. When a mistake is **deterministically detectable**,
promote the lesson to an **executable guard** so the harness catches it
mechanically. This skill is the repeatable version of what was done by hand for
`ai/bin/check-generic-skills` (the `fix:tests` consumer-constant leak).

## Step 1 — Triage: is it machine-catchable?

Apply `athena:harness-placement` step 2: *can a machine catch it deterministically,
and has prose failed to stop it?*

- **Yes, deterministic** → proceed to scaffold. Examples: a forbidden token in a
  file, an unsafe shell shape, a missing required field, a bare failure message.
- **No / judgement-only / flaky** → **REFUSE to emit a guard.** A flaky check is
  worse than none (false positives erode trust and wedge work). Say why, and keep
  the lesson as prose in its right home (block / template / CLAUDE.md / memory,
  via `athena:harness-placement`). Do not force a check that cannot be reliable.

State the verdict explicitly before writing any code.

## Step 2 — Choose the guard's form and home

Per `athena:harness-placement`:

- **A runtime mistake the harness can intercept** (an unsafe Bash construct, an
  outgoing message problem) → a **hook** (`ai/hooks/*.sh`, PreToolUse/PostToolUse;
  POSIX-sh, fail-open). Model on `safe-wait-guard.sh` / `pronoun-guard.sh`.
- **A repo/authoring invariant checkable over files** (a forbidden constant, a
  missing convention) → a **check script** (`ai/bin/<name>`), stdlib Ruby or
  POSIX-sh. Model on `check-generic-skills` / `check-guard-messages`.

## Step 3 — Scaffold the guard + its self-test

From the exemplar (`ai/bin/check-generic-skills`):

- The guard exits non-zero (or denies) on the bad case, zero (or allows) on the
  clean case.
- It ships a **`--self-test`** (a check script) or a dedicated
  **`ai/hooks/<name>.self-test.sh`** (a hook — the flag form is a no-op because
  hooks read stdin). The self-test proves **fail-on-bad AND pass-on-clean** with
  synthetic fixtures.
- Its failure output carries an actionable **`Fix:`** line (the `B1` /
  `check-guard-messages` convention — a new hook or `ai/bin` script is a guard
  by default; any other new executable or `lib/` file must be classified in
  `ai/guard-classification.tsv`, or the check fails).
- It is deny-by-default where that fits (an unclassified/new input is treated as
  the stricter case).

## Step 4 — Wire it into the gate and the eval corpus

- Add the guard to the **shipwright gate** (the gate list in
  `athena-shipwright.md.in`), and run it in the gate loop.
- Add a **regression case to the eval corpus** (`ai/eval/fixtures/<NN-name>/`,
  per `A1`/`harness-eval`) whose fixture is the lesson's own incident, naming this
  guard and its expected verdict. Then `ai/bin/harness-eval --update-baseline`
  for the intended addition. Now the lesson is a permanent, measured regression
  the harness can never silently lose.

## Step 5 — Human-in-loop

Scaffold and propose; the shipwright reviews before it ships. Do **not** bloat
the gate with low-value or duplicative guards — one guard per genuine, recurring,
deterministic class of mistake. A lesson that qualifies under the shipwright's
"≥2 runs or one unambiguous factual gap" bar is a good candidate; a one-off is
not.

## Guardrails

- Refuse to emit a flaky/unprovable guard; keep it as prose instead.
- Every generated guard ships a self-test proving fail-on-bad + pass-on-clean,
  and an actionable `Fix:` message.
- Never weaken an existing guard to make a new one pass.
