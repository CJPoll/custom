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

## DND-1867: only `git push` writes a remote ref through the route

Before the fix, against the unfixed wrapper at origin/main e1b4840d
(`GH_ATHENA_UNDER_TEST`), every new case was red, and S4, S23 and S24
expected the old subtree-push behaviour. The cases that carry the defect,
each on a local bare origin:

```
  FAIL  W1. send-pack to main refused
        rc=0 err='To /tmp/tmp.M88xcbXFpz/w1-origin.git
  FAIL  W3. -c help.autocorrect=immediate pusj (git runs push) to main: refused
        rc=0 out='' err='WARNING: You called a Git command named 'pusj', which does not exist.
  FAIL  W13. remote-https <remote> <url> (a transport helper called directly; it pushes what stdin asks) -> refused
        rc=0 out='gh-athena: dry-run: env GIT_CONFIG_KEY_0=[http.https://github.com/.extraheader] ...
  FAIL  W22. PATH git-<name> refused
        rc=0 err='' main=e37e5b6a... base=e1bb713a...
  FAIL  W24. deep alias chain refused
        rc=0 err='git (agent wrapper): alias chain for a10 is deeper than 10; not checked' main=e37e5b6a... base=e1bb713a...
RESULT: 173 passed, 28 failed
```

W1-W21 were written first (172 passed, 24 failed with S4, S23, S24); W22-W26
came from the review round. After: `RESULT: 201 passed, 0 failed`.

| Mutation | Red cases |
|---|---|
| M12 drop the `fg_writes_remote_ref` refusal | 13g, S4, S23, S24, W1, W2, W6-W17 |
| M13 an unknown subcommand with no alias passes (`break`) | W3, W4, W5, W6 |
| M14 a git-<name> on PATH is not refused | W22, W23 |
| M15 the alias walk stops at depth 10 instead of refusing | W24 |

The critic round found that a command substitution stripped each command
list's trailing newline, so the last name never matched. Measured on the
review-round head 0cfb1b10, before the fix: `RESULT: 201 passed, 2 failed`,
`FAIL W27` (`write-tree`, git's last own command, refused as unknown) and
`FAIL W28` (rc=0: the last PATH program ran, through a same-named alias).
After: `RESULT: 203 passed, 0 failed`.

## DND-1868: the bot credential reaches only the forge transport

The DND-1868 cases (P1-P3, H1-H4, C1-C8, E1-E3, M1-M2, X1, DND-1880) were
added first, with a fixture forge (a git shim whose exec-path copy holds a
stub git-remote-https; no network). Run against the unfixed wrapper at
8b271b9a (`GH_ATHENA_UNDER_TEST`), with the final test file:
`RESULT: 197 passed, 30 failed`. Every new case but X1 (it calls the new
transport directly) and P3 (a non-regression: the outbound scan still runs)
was red, and cases 1, 3, 3b, 13i, 14, 17, 18 and S32 (they now assert the
transport rewrite and the absent header). The lines that carry the defect:

```
  FAIL  H1. pre-push hook
        probe=[h1 hdr=present fd=nofd transport=absent]
  FAIL  E1. template dir hook
        probe=[e1 hdr=present fd=nofd transport=absent]
  FAIL  DND-1880. config read shows the bot header
        rc=0 out-has-header=yes
```

In the first unfixed run, H4's reference-transaction hook made a plain
`git push https://github.com/o/r2.git` that the stub saw with the bot's
header (`start via=direct url=https://github.com/o/r2.git
hdr=ok:x-access-token`): a push from inside the route, as the bot, judged by
nothing. After: `RESULT: 227 passed, 0 failed`.

The review round (code-reviewer and adr-reviewer) found three commands that
reached the grant or the header anyway: core.fsmonitor and a rebasing pull's
post-index-change hook both run before the transport (measured on git 2.54),
and the wrapper's header-carrying ls-remote probes followed a repository
insteadOf to another helper. Cases R1-R3 were added first. On the
first-round head 58dd556a: `RESULT: 227 passed, 3 failed`:

```
  FAIL  R1. fsmonitor before the transport
        r1a=0 r1b=0 r1c=1 rc=0
  FAIL  R2. pull --rebase
        a_rc=1 a_err='git-remote-athena-forge: REFUSING the connection to https://github.com/o/r.git: the route's one credential grant for this command was already used: ...
  FAIL  R3. probe insteadOf
        rc=0 out= err= probe=[r3 hdr=present fd=nofd transport=refused
```

R2's "already used" is the post-index-change hook having drained the grant
before the fetch; R3's `hdr=present` is the helper holding the header. After
(fg_refuse_pre_transport, https-only probes): `RESULT: 230 passed, 0 failed`.

The critic round found the transport ran whatever absolute path the grant's
first line named, so a forged pipe could swap git's helper for any program.
Case X1d was added first. On the review-round head (rebased as 8645ae99) the
transport ran `/bin/true` from a forged grant and exited 0 (`rc=0 out=`), so
X1d was red. After (the transport resolves `git --exec-path` itself and runs
the grant's helper only when the two agree): `RESULT: 231 passed, 0 failed`.

The second critic round found that a caller's own `-c` beats the
environment config channel and reaches the transport's subtree through
GIT_CONFIG_PARAMETERS, so `-c gpg.program`, `-c credential.helper` and
`-c core.askPass` still named the programs git used where the header is.
Case C6b was added first (the fixture helper records the effective config in
its subtree). On 9e978d9b: `RESULT: 231 passed, 1 failed`,
`FAIL C6b` with `eff=gpg:p-c6b,helper:p-c6h,askpass:p-c6a`. After (the
transport appends its values last to GIT_CONFIG_PARAMETERS):
`RESULT: 232 passed, 0 failed`.

The third critic round found the rebasing-pull check read only four exact
spellings, while git also takes an abbreviation (`--reb`) and a short
cluster (`-qr`). R2 gained both. On 6be49b40: `RESULT: 231 passed, 1
failed`, `FAIL R2` with `c_rc=1 d_rc=1` (not refused) and the
post-index-change hook's probe lines `r2 hdr=absent fd=pipe transport=RAN`:
the hook held the grant and used it. After (any prefix of --rebase, any
short cluster with r, counts as rebasing): `RESULT: 232 passed, 0 failed`.
