# harness-gate checks: why each one is there

**Kind: living normative document.** Amended in place, per `CLAUDE.md` →
*Documentation conventions*.

`ai/bin/harness-gate` runs every check in its verified-correct form. Its
`CHECKS`/`STATIC_CHECKS` is the AUTHORITATIVE list, and `ai/bin/harness-gate
--list` prints it. This page gives each check's rationale. It is NOT a second
list to keep in sync: a check the runner declares and this page omits still
runs. The rules a gate-runner must follow are resident in
`ai/agents/athena-shipwright.md.in` → *The gate*.

The rationale used to sit in that template, resident in every shipwright turn.
It moved here on 2026-10-02 (owner note N2, token efficiency). A hand-kept
duplicate of a gate-enforced list must drift, and it had: DND-277 declared
`flaky-marker-sweep.self-test.sh` in `STATIC_CHECKS` and left the template
alone, so that list was stale from then on and nothing could catch it.

- `ai/bin/build-agents --check`: agent templates rebuild clean and the
  rendered `.md` files are current. After editing a template or block, run
  `ai/bin/build-agents` first so the render is regenerated, then `--check`.
- `ai/bin/check-agent-size` (+ its `--self-test`): every rendered
  `ai/agents/athena-*.md` is within its per-agent line budget in `BUDGETS`,
  and no rendered agent lacks a budget entry. Runs AFTER `build-agents
  --check` (it reads the rendered files). Caps the fan-out baseline
  (harness-IA #2) and stops a shrunk agent silently regrowing (#8). Ratchet a
  budget down as an agent is optimized; a new agent needs a new entry at its
  current count or lower.
- `ai/bin/confirm-merged --self-test`: the single scripted definition of "the
  merge actually landed" (forge `state==merged`+timestamp OR the head is an
  ancestor of the target), which the admiral and `athena:merge-boarding` call
  before Done/DM/teardown. Deterministic and hermetic (throwaway git repo +
  stub `gh`/`glab`), so gate-safe.
- Every hook self-test: each dedicated `ai/hooks/*.self-test.sh`, run with
  stdin closed. The runner's `--self-test` fails if a `*.self-test.sh` on disk
  is not declared; that is how `harness-event`'s (since retired) was found
  unrun. The hooks read their input from stdin, so `ai/hooks/<hook>.sh
  --self-test` is NOT a self-test: the flag is ignored and it blocks on (or
  empties) stdin, a false green.
- `ai/bin/check-generic-skills`: project-agnostic skills (the `fix:*` family,
  `processes:fix`, `review`/`review-impact`/`review-loop`, `refactor:*`) carry
  no consumer-project constants. Run its `--self-test` too if you touched the
  checker.
- `ai/bin/check-hooks-registered` (+ its `--self-test`): the hooks in
  `ai/hooks/registry.json` are wired into the live Claude Code settings, not
  just present on disk. Catches the 2026-09-17 class where a settings rewrite
  silently dropped safe-wait-guard and pronoun-guard. Environment-safe: passes
  with a note when no settings file exists. Recover drift with
  `scripts/setup-hooks --install` (merges, never clobbers). Detail:
  `CLAUDE.md` → *Hook registration*.
- `ai/bin/check-inbox-registry`: this machine's Athena Inbox tenancy registry
  (`$ATHENA_INBOX_ROOT/projects/*.json`, untracked) still matches the
  committed `ai/inbox/registry.json`. The contract defines a missing entry as
  zero channels, exit 0, no error, so a clobbered entry is a silently dead
  inbox. Environment-safe: passes with a note when there is no inbox root.
  Recover with `scripts/setup-inbox-registry --install`. Run the checker's own
  `--self-test` if you touched it or `ai/inbox/lib/registry.rb`;
  `ai/inbox/test/self-test.sh` is covered by self-test discovery (below).
  Detail: `CLAUDE.md` → *Inbox tenancy registry*.
- `ai/bin/check-guard-messages`: every first-party executable/lib is
  classified in `ai/guard-classification.tsv`, and every guard emits an
  actionable `Fix:` on failure. A new script must be classified there.
- `ai/bin/check-bin-help` (+ its `--self-test`): every harness tool (scope:
  `ai/lib/harness_tools.rb`) answers `--help` on stdout, exit 0, doing nothing
  else. One with no `--help` branch runs its DEFAULT action (measured: a model
  call, an agent rewrite, a minted token). Detail and `EXEMPT`: the check's
  header.
- `ai/bin/check-tool-risk` (+ its `--self-test`): every tool the harness can
  call carries a risk annotation in the registry, and none was added or
  renamed without one. Pairs with the `workflow-phase-guard` hook, which gates
  a tool by the workflow phase its risk class allows (DND-172/173).
- `ai/bin/harness-eval` (+ its `--self-test`): the regression corpus still
  passes and nothing regressed vs `ai/eval/baseline.json` (it writes
  `ai/eval/scorecard.json`). A change that intentionally alters a case
  updates the baseline with `--update-baseline`, never to hide a regression.
- `ai/bin/blast-radius --self-test`: the merge-consequence classifier
  `integration-gate` runs pre-merge (exit 4 = merging PERFORMS an action).
- `ai/bin/critic-review --self-test` and `ai/bin/critic-eval --self-test`: the
  LLM-judge critic tier, both deterministic and model-free. `critic-review`
  gates a BLOCKING captain self-review step, so its decision and
  FINDINGS-parser logic stay verified even when an edit did not touch it.
- `ai/bin/admiral-eval --self-test`: deterministic scorer, parser,
  majority-sampling, baseline-diff, T1-hook-primitive and inert sandbox
  (model-free). Proves a stage-4 trim still makes the right DECISION, not
  merely that the invariant's words survived. A model-in-loop `--run` is
  NEVER in the gate (`critic-eval`, `admiral-eval`); `admiral-eval --run`
  captures and verifies the baseline on the shipwright cron cadence.
- `ai/bin/variant-eval --self-test`: the harness-variant measurement
  instrument (DND-174). It scores a candidate ref against a baseline over the
  eval corpus: KEEP / REVERT / INCONCLUSIVE. Proposal-only and human-gated by
  design, with no merge/commit/push/adopt path. Only its deterministic
  `--self-test` is in the gate. Its boundary with the shipwright cron is
  resident in the shipwright template.
- `scripts/setup-hooks --self-test`: INLINE (no `self-test.sh` backs it), so
  it stays a hand-declared `CHECKS` entry. Its install, idempotency and
  merge-safety cases are the ONLY verification of the recovery path for the
  2026-09-17 hook clobber (unrun by the gate until DND-209).
- Every tracked `**/self-test.sh` in the repo: DISCOVERED, never
  hand-declared. The glob is intersected with `git ls-files`, so an
  untracked, vendored or ignored tree (e.g. `ai/skills/synced/`) is never
  promoted into the blocking gate. A future suite anywhere is covered with no
  wiring step, **provided its entry point is named exactly `self-test.sh`**:
  that filename is the whole discovery contract. `scripts/setup-athena-inbox-client
  --self-test` and `scripts/setup-inbox-registry --self-test` are covered this
  way, through the runner's `SELF_TEST_DELEGATES` map. The runner prints
  `self-tests discovered: N` and FAILS on zero (zero means the glob or the
  tracked-file filter broke). It WARNS (non-blocking) about any other `.sh`
  under a `test/` directory not named `self-test.sh`. Its `--self-test` proves
  discovery (a fixture red/green flip, the zero-discovery and stray-suite
  branches, an untracked fixture file excluded, a failed `ls-files` raising
  loud, the `--list` composition end to end) and FAILS if a `scripts/setup-*`
  advertising `--self-test` is neither declared nor delegated (DND-209).
- `ai/bin/harness-gate --self-test`: the runner itself. Its CHECKS run it as
  groups (`--group NAME`). Run it when you touch the gate's composition.
- Any skill or script self-test relevant to what you changed.
