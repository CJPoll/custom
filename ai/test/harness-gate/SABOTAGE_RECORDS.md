# Sabotage records — harness-gate

A test is not finished until you have watched it fail. Delete the thing it
exists to prove, run the suite, and write down the failure next to the claim.

harness-gate's suite is inline: `ruby ai/bin/harness-gate --self-test`. It has
no `self-test.sh` here, so this directory holds only these records.

## How to use this

Pick a row. Re-apply the mutation. The named case should fail with the named
string. If it still passes, the wiring it protects is no longer load-bearing,
and the row is now a bug report.

Backups were taken with `cp` before each mutation and restored with `cp` after.

---

## 2026-09-26 — DND-735: the gate's check loop hands every check its own pin

- **Code under test:** `run_checks` in `ai/bin/harness-gate`, the loop
  `run_gate` runs. It reads the landed-ref pin once (`landed_pin_env`) and
  passes it to each check (`run_one(..., env: pin_env)`).
- **Suite run:** `ruby ai/bin/harness-gate --self-test`
- **Baseline:** `harness-gate: self-test OK (83 checks declared, 37 of them
  discovered self-test suites)`
- **Cases:** 12b (origin readable) and 12c (origin unreadable). The caller
  exports a well-formed but wrong pin (`ATHENA_LANDED_PIN_SHA=bbbb…`,
  `ATHENA_LANDED_PIN_REPO=<tmp>/inherited.git`). A declared check records the
  pin it sees.

| # | Mutation | Cases reddened | Failure string(s) |
|---|---|---|---|
| M1 | `run_checks`: `run_one(argv, chdir: chdir, env: pin_env)` → `run_one(argv, chdir: chdir)` | 12b, 12c | `a check run by the gate's loop saw "sha=bbbb… repo=<tmp>/inherited.git", not the gate's own pin "sha=<P> repo=<tmp>/repo/.git"` / `with origin unreadable, a check run by the gate's loop saw "sha=bbbb… repo=<tmp>/inherited.git"; the inherited pin must be cleared, not passed through` |
| M2 | `run_checks`: `landed_pin_env(root)` → `[{}, nil]` (no pin read) | 12b (two assertions), 12c | the same two strings, plus `run_checks did not return and print its own pin ({}, [], "harness-gate: NOTE — could not pin the landed ref; …")` |

Each mutation took the suite from `self-test OK` to `harness-gate: self-test
FAILED` (rc 1).

**Not protected by a behavioural test:** `run_gate` calling `run_checks(CHECKS)`
rather than a loop of its own. That call is one line, and every live gate run
prints the pin line from `run_checks`, so a bypass shows as a missing
`landed ref pinned` line in the gate output.

A first M2 attempt was vacuous: its `sed` pattern assumed 4-space indent, so
nothing changed and the suite stayed green. The mutation script now aborts
when the mutated text is absent.

---

## 2026-10-02 — DND-1689: the gate refuses untracked, un-ignored files

- **Code under test:** `untracked_preflight` and `untracked_files` in
  `ai/bin/harness-gate`, called by `run_gate` before discovery.
- **Suite run:** `ruby ai/bin/harness-gate --self-test --group core`
- **Baseline:** `harness-gate: self-test OK (group core; 177 checks declared,
  114 of them discovered self-test suites)`
- **Regression (before the fix):** case 6f on the unfixed `run_gate`:
  `6f: run_gate returned 0 on a tree with 2 untracked, un-ignored files its
  discovery never read; expected 1 (refused)`, with `self-tests discovered: 1`.

| # | Mutation | Case | Failure string |
|---|---|---|---|
| M1 | `run_gate`: `return 1 unless untracked_preflight(root)` → `nil` | 6f (three assertions) | `6f: run_gate returned 0 on a tree with 2 untracked, un-ignored files its discovery never read; expected 1 (refused)` |
| M2 | `untracked_files`: a failed `ls-files --others` returns `[[], []]` instead of raising | 6g | `6g: untracked_files did not raise GitTrackingError carrying git's error when` (the listing failed) |

Each mutation took the group from `self-test OK` to `harness-gate: self-test
FAILED (group core)` (rc 1). Both were confirmed applied (`grep -c` = 1)
before the run and restored by `cp` after.

**Not protected by a behavioural test:** the wrong-tree refusal running
before the untracked preflight on a real run. The suite drives `run_gate` on
a fixture only as a dry run, which reaches neither ordering.

---

## 2026-10-02 — DND-1693: the repo .gitignore ignores runtime state itself

- **Code under test:** the repo's own `.gitignore` (the `ai-artifacts/` rule),
  read through `untracked_files` in `ai/bin/harness-gate` in a fixture whose
  `core.excludesFile` is `/dev/null`, so no global excludes file can help.
- **Suite run:** `ruby ai/bin/harness-gate --self-test --group core`
- **Baseline:** `harness-gate: self-test OK (group core; 177 checks declared,
  114 of them discovered self-test suites)`
- **Regression (before the fix):** case 6h with `.gitignore` as on
  origin/main cc41d1ec: `6h: with no global excludes, the repo .gitignore
  (...) must ignore the harness's runtime state; untracked, un-ignored:
  ["ai-artifacts/clustering/consecutive-failures", ...,
  "ai-artifacts/shipwright/cursor.txt", ..., "sentinel.txt"]`, with all five
  runtime samples leaked.

| # | Mutation | Case | Failure string |
|---|---|---|---|
| M1 | `.gitignore`: delete the `ai-artifacts/` line (the unfixed tree) | 6h | `6h: with no global excludes, the repo .gitignore (...) must ignore the harness's runtime state` (5 samples leaked) |
| M2 | `.gitignore`: narrow `ai-artifacts/` to `ai-artifacts/shipwright/` | 6h | the same string, 4 samples leaked (lead-time, clustering, slack-roots, coordination) |

Each mutation took the group to `harness-gate: self-test FAILED (group core)`
(rc 1). M2 was applied by a script that aborts when the target line is absent,
and restored by `cp`. The `sentinel.txt` sample guards the other direction: a
listing that read nothing, or a rule that ignored everything, also fails 6h.
