# Sabotage records — check-hooks-registered landed bar (DND-743)

A test is not finished until you have watched it fail: delete the thing it
exists to prove, run it, confirm the failure names the right criterion, and
write the failure string down next to the claim it supports. Root ADR 002 makes
that mandatory per subproject, in stack-neutral vocabulary.

## How to use this

Pick a row. Re-apply the mutation to a COPY of the checker (with `ai/lib/landed.rb`
and `scripts/setup-hooks` beside it, same layout) and point the suite at it:

```
CHECK_HOOKS_REGISTERED_UNDER_TEST=<copy>/ai/bin/check-hooks-registered \
  ai/test/check-hooks-registered/self-test.sh
```

The named cases should fail. If they pass, the check they protect has stopped
being load-bearing and the row is now a bug report. Mutating a copy leaves the
committed files untouched, so there is nothing to restore.

---

## 2026-09-26 — DND-743 (folds in DND-478 finding 4)

- **Defect:** the check read the BRANCH's `ai/hooks/registry.json` as the bar.
  A branch adding a hook failed until live settings wired it; wiring it from the
  worktree pointed settings at a main-checkout script that did not exist yet
  (exit 127 on every tool call, DND-670). A branch removing or re-eventing a
  landed hook lowered its own bar.
- **Fail-first:** the suite, run against origin/main `fbd2410`'s checker,
  `ai/lib/landed.rb` and `scripts/setup-hooks`:

```
  ok    landed hook wired, branch unchanged -> pass
  FAIL  branch-added hook unwired -> pass, named as pending
  FAIL  landed hook unwired on a hook-adding branch -> FAIL naming it
  ok    hook landed but unwired -> FAIL (drift as today)
  FAIL  landed hook removed on the branch, unwired -> still FAIL
  ok    landed hook removed on the branch, still wired -> pass
  FAIL  landed hook moved to another event on the branch -> landed event still required
  FAIL  wired hook whose script is absent from the main checkout -> FAIL (dangling)
  ok    branch registry names a script that does not exist -> FAIL
  ok    branch registry names a non-executable script -> FAIL
  FAIL  landed registry unreadable (origin unreachable) -> could not measure, exit 3
  FAIL  landed registry malformed -> could not measure, exit 3
  FAIL  branch registry malformed -> could not measure, exit 3
  ok    no settings file -> pass without reading origin
  FAIL  setup-hooks --install skips a hook not on the main checkout
check-hooks-registered landed-bar suite: 6 passed, 9 failed
```

  The two "branch registry names a script ..." rows passed before the fix only
  by accident: the old checker failed them because the new entry was unwired,
  not because the script could not run. M5 below is what proves they are
  load-bearing now.

- **After the fix:** `check-hooks-registered landed-bar suite: 15 passed, 0 failed`.

| Mutation (on a copy of the fixed code) | Caught by |
| --- | --- |
| M1: drift computed against the branch registry, not the landed one | branch-added hook unwired; landed hook unwired on a hook-adding branch; landed hook removed on the branch; landed hook moved to another event (4 failed) |
| M2: `dangle = []` | wired hook whose script is absent from the main checkout (1 failed) |
| M3: an unreadable landed bar returns `EXIT_OK` | origin unreachable; landed registry malformed (2 failed) |
| M4: setup-hooks `--install` no longer skips a script absent from the main checkout | setup-hooks --install skips a hook not on the main checkout (1 failed) |
| M5: `broken = []` (no branch consistency check) | branch registry names a script that does not exist; ... a non-executable script (2 failed) |

## 2026-09-28 — DND-1080 (the agent git wrapper never reached a fresh session's PATH)

- **Defect:** the DND-775 wrapper was put on PATH by the last line of
  `dotfiles/.zshrc`. Claude Code's shell snapshot ends with
  `export PATH=<Claude Code's own process PATH>`, so that line never reached
  the Bash tool. The fix delivers it through settings env `CLAUDE_ENV_FILE` ->
  `ai/agent-env/session-env.sh`, which runs after the snapshot.
- **Before the fix** (`scripts/setup-hooks --self-test`, fresh-session fixture):

```
  FAIL a fresh session built from the installed env must have .../ai/agent-bin/git first on PATH, got [/usr/bin/git] (CLAUDE_ENV_FILE=[]) (DND-1080)
SELF-TEST FAILED
```

- **After the fix:** `setup-hooks --self-test` ALL CASES PASS;
  `ai/bin/check-hooks-registered --self-test` ALL CASES PASS; this suite
  `32 passed, 0 failed` (adds the two fresh-session cases).

| Mutation (on a scratch copy of the fixed code) | Caught by |
| --- | --- |
| M1: registry env without `CLAUDE_ENV_FILE` (the pre-fix delivery) | setup-hooks: a fresh session built from the installed env has the wrapper first (the "before" above) |
| M2: `env_file_problems` returns `[]` | script without the PATH line; script missing; a line besides the PATH line; landed env with no CLAUDE_ENV_FILE; runtime problem beside the stale PATH (5 failed) |
| M3: lines besides `ENV_LINE` tolerated | script running a line besides the PATH line (1 failed) |
| M4: `CLAUDE_ENV_FILE` dropped from `SHARED_VARS` | the owner's own CLAUDE_ENV_FILE beside the guard -> DRIFT whose Fix: says remove it by hand (1 failed). "CLAUDE_ENV_FILE alone -> INACTIVE" still passes: `any_guard_key?`'s fixed rule decides INACTIVE first, and it never counted CLAUDE_ENV_FILE |
| M5: no shared-key `Fix:` on DRIFT | the owner's own CLAUDE_ENV_FILE beside the guard (1 failed) |

## 2026-10-01 — DND-1517 (a hook that left the registry could not be unwired)

- **Defect:** `scripts/setup-hooks` had no way to unwire a hook whose row left
  `ai/hooks/registry.json`, and this checker had no notion of a retired hook.
  DND-1487 had to keep `ai/hooks/harness-event.sh` as a no-op stub. The fix adds
  the registry's `retired` list, read from what LANDED.
- **Fail-first:** this suite with the new 14b cases, run against the unfixed
  checker (origin/main `e0f6c03f`):

```
  FAIL  landed retired hook still wired -> FAIL naming it and the installer
        exit 0, want 1
  FAIL  branch drops a landed retirement, hook still wired -> still FAIL
  FAIL  a retirement only this branch adds, still wired -> pass, named as pending
  FAIL  branch registry both declares and retires one row -> FAIL naming it
check-hooks-registered landed-bar suite: 34 passed, 4 failed
```

  The malformed-landed-list case was added in the review round, after the fix.
  M4 below is its fail-first.

- **After the fix:** `check-hooks-registered landed-bar suite: 39 passed, 0 failed`.

| Mutation (on a copy of the fixed code) | Caught by |
| --- | --- |
| M1: `still_wired = []` (retirements ignored) | landed retired hook still wired; ...its Fix:; branch drops a landed retirement (3 failed) |
| M2: retirements read from the branch registry, not the landed one | branch drops a landed retirement, hook still wired (1 failed) |
| M3: no declared-and-retired consistency check | branch registry both declares and retires one row (1 failed) |
| M4: a non-array `retired` read as empty | landed retired list malformed -> could not measure (1 failed) |
