# Sabotage records — the DND-775 agent-stash guard

A test is not finished until you have watched it fail. Each row below names a
mutation, the suite run, and the cases that went red. Re-apply the mutation to a
SCRATCH COPY and point the suite's seam at it; the named cases must fail. If one
still passes, the check it protects has stopped being load-bearing.

- Hook suite: `bash ai/test/agent-stash-guard/self-test.sh`
  (seam: `AGENT_STASH_HOOK_UNDER_TEST=<copy>`; baseline: `AGENT_STASH_NO_INJECT=1`).
- Wrapper suite: `bash ai/test/agent-bin-git/self-test.sh`
  (seam: `AGENT_BIN_GIT_UNDER_TEST=<copy>`; baseline: `AGENT_BIN_GIT_OFF=1`).
- Both run in fixture repos under `mktemp -d`; no real stash list is touched.

Measured 2026-09-26/27 on git 2.55.0 (laptop), branch `dnd-775-agent-stash-hook`.

## Baselines (fail-first: the guard absent)

| Run | Result |
|---|---|
| Hook suite, `AGENT_STASH_NO_INJECT=1` | `RESULT: 12 passed, 30 failed`. Every H, P1-P12, Z1-Z5, W1-W9, F1 and A1 case failed: each write went through. The OK cases passed. |
| Wrapper suite, `AGENT_BIN_GIT_OFF=1` | `RESULT: 39 passed, 50 failed`. Every deny case (D1-D5, AL, R) failed: git ran and wrote. The allow and false-positive cases passed. |
| Hook suite, guard present | `RESULT: 47 passed, 0 failed, 0 skipped` (the baseline above predates P13, P14 and T3) |
| Wrapper suite, guard present | `RESULT: 93 passed, 0 failed` |

## Hook (`ai/git-hooks/agent-stash-guard.sh`)

| Mutation | Red cases |
|---|---|
| Drop R1 (value change on refs/stash is `continue`d) | W4 update-ref, W5 update-ref --stdin, W6 fetch into refs/stash. The other W cases stay green because they run inside `git stash`, where R2 also refuses them. |
| Drop R2 (the `*/stash` parent-name match never matches) | P1-P12, Z1-Z5, A1 (18 cases) |
| Drop the pack-refs exemption | OK4 pack-refs --all, OK6 maintenance run --task=gc |
| Drop the rebase/merge/pull exemption | OK7 rebase --autostash, OK10 merge --autostash. Note: before the suite asserted "no hook refusal in the output", this mutation stayed GREEN: rebase exits 0 and restores the tree even when its inner `stash apply` is refused. `allowed` now fails on any `agent-stash-guard: REFUSED` line. |
| Exemption on the ancestor name alone (the round-1 hook, with no `in_autostash` check) | P13 `rebase -x` running a stash pop (rc=1, but entries 2 -> 1: the pop landed and dropped), P14 a pre-merge-commit hook running a stash pop (rc=0, entries 1). Critic round 2 found this bypass; the fix requires a real autostash in progress. |
| Registry: drop `Fix:` and the `--remove-env` disable from the inline hook command | F1 |

## Wrapper (`ai/agent-bin/git`)

| Mutation | Red cases |
|---|---|
| Drop D1 (the `stash)` branch never matches) | D1.1-D1.14, AL1-AL11, AL14, R1-R5, FT5 (32 cases). The pop/apply cases fail on the worktree-unchanged assert as well as the list. |
| Drop alias resolution (break before any lookup) | AL1-AL14, D5.8, FT1 (16 cases) |
| Drop D5 (`is_hook_key` refusal on -c/--config-env) | D5.1-D5.4, D5.8 |
| Drop the not-checked fault line (DND-802) | FT1 |
| Drop the self-skip (`is_wrapper` in the PATH walk) | The wrapper execs itself: `PATH=<wrapper dir>:/usr/bin git --version` exits 126 (ATHENA_AGENT_GIT_SEEN grows until E2BIG) instead of printing the version. FT3 and FT4 cover this shape under `timeout 5`, and every `denied`/`allowed` case is bounded by `timeout 60`, so a looping wrapper reads as FAIL, never as a hung suite. |

## check-hooks-registered and setup-hooks

Covered by in-suite cases rather than a file mutation (`ai/bin/check-hooks-registered --self-test`, `scripts/setup-hooks --self-test`):
- one env key removed from the settings -> DRIFT, exit 1;
- the hook command pointing at a worktree path -> DRIFT, exit 1;
- the hook script missing in the main checkout -> FAIL naming `--remove-env`;
- install over a differing `ATHENA_AGENT_BIN` -> refused, file byte-identical.

## check-guard-messages

| Mutation | Result |
|---|---|
| `ai/agent-bin/git` with every `Fix:` rewritten | `check-guard-messages: FAILED ... guard(s) with a bare failure message (no 'Fix:' self-correction): ai/agent-bin/git`. Both files are listed `guard` in `ai/guard-classification.tsv` (they sit outside GUARD_DIRS, which stays `ai/hooks ai/bin`). |

## gh-athena self-test case 1 (the bug fix)

| Run | Result |
|---|---|
| Unfixed suite, run with a pre-set `GIT_CONFIG_COUNT=2` (the injection shape) | `RESULT: 26 passed, 1 failed`: `FAIL 1. SSH-form origin rewritten with bot auth` (the header landed at `GIT_CONFIG_KEY_2`; the case pins index 0). |
| Fixed suite (`unset GIT_CONFIG_COUNT` in the hermetic block, plus case 18), same pre-set env | `RESULT: 28 passed, 0 failed` |
| Fixed suite, clean env | `RESULT: 28 passed, 0 failed` |

## harness-gate self-test case 13c (rebase onto the parallel gate, 2026-09-28)

Main's `d2120b0` ("harness-gate: run checks on a bounded worker pool") made
`run_checks` schedule checks on a worker pool (pre-pool serial run, pooled units, final serial run). Each runner
destructured an entry as `[label, argv]`, so the legacy suite's
`:stash_fixture_optout` element would be dropped and the suite would run with
the guard injected. Both runners now pass the element through `check_env`;
case 13c pins it on the pre-pool and pooled paths.

| Run | Result |
|---|---|
| Both runners reverted to `\|(label, argv)\|` with `env: pin_env` / `env: env` (`harness-gate --self-test`) | `self-test: FAIL — case 13c: the per-check env option was not applied on every scheduling path (GIT_CONFIG_COUNT seen: {"pre" => "0", "pooled" => "0", "plain" => "0"}; want pre/pooled unset, plain 0)` / `harness-gate: self-test FAILED`, rc=1 |
| Fixed | `harness-gate: self-test OK (106 checks declared, 56 of them discovered self-test suites)`, rc=0 |

## check-hooks-registered combined exit (critic, rebase round 2)

The live check exited `[run, run_agent_stash_env].max`, so a visible hook
failure (1) beside an env it could not measure (3) exited 3, breaking the
header's rule that a visible failure stands. `combined_exit` now returns 1
when either side is 1, and the worse otherwise.

| Run | Result |
|---|---|
| New cases against the unfixed rule (`combined_exit` = `[hook, env].max`), `check-hooks-registered --self-test` | `FAIL exit: hook 1 + env 3 -> 1`, `FAIL exit: hook 3 + env 1 -> 1`, `SELF-TEST FAILED`, rc=1 |
| Fixed | all eight `exit: hook h + env e` cases `ok`, `ALL CASES PASS`, rc=0 |
