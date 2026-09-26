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
