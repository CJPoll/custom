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
