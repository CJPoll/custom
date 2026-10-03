# Sabotage records: forge identity at the process layer

A test is not finished until you have watched it fail. Each row below names a
mutation, the suite run and the cases that went red. To repeat one, apply the
mutation to a SCRATCH COPY of `ai/` and point the suite's seam at it; the named
cases must fail. If one still passes, the check it protects has stopped being
load-bearing.

- Suite: `bash ai/test/agent-forge-identity/self-test.sh`
  (seam: `AGENT_FORGE_ROOT_UNDER_TEST=<dir>`, a directory holding the `ai/`
  tree under test).
- Fixture repos and remotes live under `mktemp -d`. The only remote that is
  written is a local bare repository; the forge URLs are synthetic, and
  `GIT_ALLOW_PROTOCOL=file` and `GIT_SSH_COMMAND=false` stop any other.

## DND-1881: remote-ref writers other than push (the agent PATH git wrapper)

Measured 2026-10-03 on git 2.54.0, branch `dnd-1881-agentbin-writers`.

| Run | Result |
|---|---|
| Baseline: the unfixed tree (origin/main `e2821cc8`) | `agent forge-identity: 81 passed, 21 failed`. X1-X21 all failed. Every N case passed. Each writer reached git unjudged, and where it ran for real it moved a ref of the local remote: X1 `send-pack <github URL>` created `main`, X9 `subtree push` created `synth-x9`, X12 a `git-<name>` program on PATH moved `main`, X14 `pusj` under `help.autocorrect=immediate` moved `main`. |
| The fix | `agent forge-identity: 102 passed, 0 failed` |

| Mutation | Red cases |
|---|---|
| M1. `afp_writer` skips the writer test (`fg_writes_remote_ref … \|\| exit 0` becomes `exit 0`) | X1-X4, X6-X11, X16-X21 (16 cases) |
| M2. The wrapper reads a name with no command and no alias as before (the `rc 1` refusal becomes `break`) | X14, X15 |
| M3. The wrapper never asks the check about a non-builtin (`_frc=10`) | X6-X13, X17, X19-X21, and N2-N5 and N10, whose `subtree` the alias walk then reads as an unknown name (17 cases) |
| M4. `afp_writer_reaches` drops the as-written host test | X1-X4, X6, X7, X9, X11. send-pack and http-push apply no insteadOf, so a forge URL the repository rewrites to a local path still goes to the forge. For X9 and X11 (subtree's inner push applies insteadOf) the refusal is the accepted false refusal the header names |
| M5. The wrapper judges only `push` after the walk, not `send-pack` | X1-X4, X16 |
