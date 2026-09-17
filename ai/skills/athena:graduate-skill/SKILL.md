---
name: athena:graduate-skill
description: Promote a recurring session pattern into a durable harness home — a skill, a shared block, or a CLAUDE.md rule. Detect recurrence from telemetry + the shipwright journal, route the placement decision, and emit a reviewed PROPOSAL with a concrete diff (never an auto-commit). Use when the same ad-hoc guidance or workaround keeps recurring across sessions and should become a first-class part of the harness.
---

# athena:graduate-skill

The harness improves when knowledge that keeps getting re-derived in sessions is
**promoted** to a durable home instead of being rediscovered each time. The
authoring mechanics already exist (`athena:create-skill`,
`athena:create-agent-definition`, `athena:harness-placement`); the missing half
was the **signal of recurrence** — now supplied by telemetry (`A3`/`A4`) and the
shipwright's cross-session aggregation (`A6`). `beryl:ruby-testing-pyramid` is a
prior manual graduation.

## Step 1 — Detect recurrence (the signal)

A pattern qualifies for graduation only if it **recurs** — the shipwright's bar:
appears in **≥2 independent runs/sessions**, or is a single unambiguous factual
gap.

- Run `ai/bin/harness-metrics` then `ai/bin/harness-signals` for metric-backed
  recurrence (a tool/skill firing repeatedly, a recurring failure class).
  Telemetry aggregates across all sessions, so a surfaced signal is already
  cross-session evidence.
- Cross-check the shipwright journal (`ai-artifacts/shipwright/journal.md`) and
  the KG/auto-memory for the same pattern captured more than once.
- A **single-session** pattern does **not** qualify — record it as
  watched-but-not-actioned; do not graduate prematurely.

State the evidence (which sessions / which metric) before proposing.

## Step 2 — Route the placement (where it graduates to)

Use `athena:harness-placement` to pick the home:

- A **task-triggered procedure or long reference** → a **skill**
  (`athena:create-skill`).
- **Doctrine ≥2 agents must carry word-for-word** → a **shared block**, routed in
  `routing.yml` (`athena:create-agent-definition`).
- **A machine-wide/repo-wide rule** → **CLAUDE.md**.
- **A durable worldly fact** (owner, constraint, gotcha) → **memory**, not a
  definition.
- **A deterministically-catchable mistake** → hand off to
  `athena:lesson-to-guard` (a guard, not just prose).

## Step 3 — Precedence & safety checks

- **Global-wins precedence** (verified): a user/global skill SHADOWS a same-named
  project skill. If you propose graduating a **global** skill, flag that it will
  shadow any project skill of the same name — pick a name that will not collide,
  or intend the shadow.
- **A block with one consumer is a smell** — if only one agent needs it, it is
  template prose, not a block (`athena:harness-placement`).
- **Never restate** existing content — a graduation that duplicates a block/skill
  is a pointer, not a copy.

## Step 4 — Emit the proposal (dry-run, no auto-commit)

Output a **proposal**, not a committed change:

- The pattern + its recurrence evidence (sessions / metric line).
- The chosen home (with the `athena:harness-placement` rationale).
- A **concrete diff** (the new skill/block/CLAUDE.md text, and the `routing.yml`
  entry if a block).
- Precedence/shadow notes.

The shipwright reviews and applies it through the normal authoring skills +
gate — this skill never auto-commits or self-installs a graduation.

## Guardrails

- Recurrence bar: ≥2 sessions (or one unambiguous factual gap); no premature
  graduation from a single session.
- Dry-run: propose + diff only; the shipwright applies after review.
- Respect global-wins precedence; flag any shadowing.
- Route via `athena:harness-placement`; never restate existing content.
