# gh-athena git passthrough: sabotage records

Each row: a mutation of the shipped code, and the self-test cases it turned red.
Run: `bash ai/test/gh-athena/self-test.sh`.

## DND-1690: a push to main in a gated repo needs integration-gate's cover

Before the fix (unfixed `fg_git_exec`, cases 35-43 added first), all nine new
cases were red. The two that carry the defect:

```
  FAIL  35. ungated lane push to a green main refused
        rc=0 err='' main=35923c2c895a16c2cd03c03bc77de1e619ec2ce4
  FAIL  38. ungated commit on a rebased head refused
        rc=0 err=''
RESULT: 60 passed, 9 failed
```

The other seven (35b, 36, 37, 39, 40, 41, 43) were red because nothing judged
the push: 35b, 39, 40 and 41 expected a refusal, and 36, 37 and 43 expected
the guard's success note. After: `RESULT: 73 passed, 0 failed` (cases 44-47
were added in the review round).

| Mutation | Red cases |
|---|---|
| M1 drop the `fg_refuse_ungated_main` call in `fg_git_exec` | 35, 35b, 36, 37, 38, 39, 40, 41, 43, 44, 45, 46, 47 |
| M2 an unreadable exact receipt reads as a miss, not COULD NOT LOOK | 39 |
| M3 any candidate with a receipt covers (no tree comparison) | 38 |
| M4 the gate declaration is read on the pushed commit, not the landed main | 40, 44 |
| M5 a candidate's receipt base is checked against the head, not the landed main | 41 |
| M6 the landed main is read only from origin, not the pushed remote | 44 |
| M7 with no landed main, the gate is read on the pushed commit only, not its history | 45 |
| M8 an unreadable candidate receipt is skipped as not covering | 46 |

## DND-1809: ir_push_covered lists every covering head

The lead-time ledger joins a clean-rebase push landing to its gated head by
`ir_push_covered`, and must refuse to guess when two heads cover it. Case 48
was added first. On the unfixed lib (it stopped at the first cover and set no
list) it was red:

```
  FAIL  48. every covering head listed
        cov='0|rebase| |7ba2cb92…:…/integration-receipts/7ba2cb92….json' want heads='7ba2cb92… b5713533… '
RESULT: 73 passed, 1 failed
```

After: `RESULT: 74 passed, 0 failed`. The guard's own answer (covered, the
first cover as `IR_COVER_HEAD`) is unchanged: cases 35-47 stay green.

| Mutation | Red cases |
|---|---|
| M9 drop the re-read that restores `IR_RECEIPT` to the first cover's | 48 |

## DND-1814: a receipt counts only when integration-gate's seal verifies

Before the fix (the unfixed tree at 9ea5e2c4; first measured at 4dd569fc as 73/2; cases 35c and 35d added first),
a hand-written receipt of the right shape covered the push, and main moved:

```
  FAIL  35c. forged receipt refused
        rc=0 err='gh-athena: note: integration-gate passed exactly 9ebd5863... (.../integration-receipts/9ebd5863....json)' main=9ebd58636db2f5acd9762e308d86322589fc79e5
  FAIL  35d. edited receipt refused
        rc=0 err='gh-athena: note: integration-gate passed exactly 9ebd5863... (...)'
RESULT: 74 passed, 2 failed
```

After: `RESULT: 76 passed, 0 failed` (re-measured on origin/main 9ea5e2c4 after the rebase onto DND-1809).

| Mutation | Red cases |
|---|---|
| M10 drop the `ir_verify_seal` call in `ir_read_receipt` | 35c, 35d |
| M11 `ir_verify_seal` returns 0 on a verify exit 1 (unverified read as verified) | 35c, 35d |
