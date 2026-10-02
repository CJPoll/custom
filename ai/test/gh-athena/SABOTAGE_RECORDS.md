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
