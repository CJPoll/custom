# gh-athena git passthrough: sabotage records

Each row: a mutation of the shipped code, and the self-test cases it turned red.
Run: `bash ai/test/gh-athena/self-test.sh`.

## DND-1690: a push to main in a gated repo needs integration-gate's cover

Before the fix (unfixed `fg_git_exec`, the new cases added first):

```
  FAIL  35. ungated lane push to a green main refused
        rc=0 err='' main=35923c2c895a16c2cd03c03bc77de1e619ec2ce4
  FAIL  38. ungated commit on a rebased head refused
        rc=0 err=''
RESULT: 60 passed, 9 failed
```

After: `RESULT: 69 passed, 0 failed`.

| Mutation | Red cases |
|---|---|
| M1 drop the `fg_refuse_ungated_main` call in `fg_git_exec` | 35, 35b, 36, 37, 38, 39, 40, 41, 43 |
| M2 an unreadable exact receipt reads as a miss, not COULD NOT LOOK | 39 |
| M3 any candidate with a receipt covers (no tree comparison) | 38 |
| M4 the gate declaration is read from the pushed commit, not origin/main | 40 |
| M5 a candidate's receipt base is checked against the head, not the landed main | 41 |

36, 37 and 43 go red under M1 because the guard's success note is part of
their assertion, so each also proves the guard ran and passed.
