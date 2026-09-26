# Sabotage records — check-inbox-registry landed bar (DND-792)

A test is not finished until you have watched it fail: delete the thing it
exists to prove, run it, confirm the failure names the right criterion, and
write the failure string down next to the claim it supports. Root ADR 002 makes
that mandatory per subproject, in stack-neutral vocabulary.

## How to use this

Pick a row. Re-apply the mutation to a COPY of the checker, laid out as in the
repo (`ai/bin/check-inbox-registry`, `ai/inbox/lib/registry.rb`,
`ai/lib/landed.rb`, `scripts/setup-inbox-registry`, `ai/skills/athena:inbox/lib`).
Make the copy its own git repo (`git init && git add -A && git commit`), or the
inline suite's repo-identity cases fail for a reason unrelated to the mutation.
Then run both suites against it:

```
<copy>/ai/bin/check-inbox-registry --self-test
CHECK_INBOX_REGISTRY_UNDER_TEST=<copy>/ai/bin/check-inbox-registry \
  ai/test/check-inbox-registry/self-test.sh
```

The named cases should fail. If they pass, the check they protect has stopped
being load-bearing and the row is now a bug report. Mutating a copy leaves the
committed files untouched, so there is nothing to restore.

---

## 2026-09-26 — DND-792 (folded into DND-743)

- **Defect:** the check read the BRANCH's `ai/inbox/registry.json` as the bar.
  A branch adding an entry or a channel failed until the live registry was
  provisioned with it. A branch removing or editing a landed entry lowered its
  own bar, including the "not this environment" discriminator.
- **Fail-first:** the black-box suite against origin/main `844b95c`'s checker:
  `5 passed, 10 failed`. The failures: branch-added entry; branch-added channel;
  landed entry removed on the branch; landed entry edited on the branch (both
  directions); origin unreachable; landed registry malformed; root lost with the
  branch deleting the proving entry; forged local origin/main; stale local
  origin/main unpinned. For example:
  `FAIL  branch-added entry, not installed -> pass, named as pending` /
  `exit 1, want 0; output: check-inbox-registry: FAIL — 1 registry problem(s) under .../projects: - peer.json is missing from projects/`.
  After the fix: `15 passed, 0 failed`.

| Mutation (in `ai/bin/check-inbox-registry`) | Caught by |
|---|---|
| Control: no mutation | nothing fails (inline 0 FAIL, black-box 15/0) |
| `branch-is-bar`: after `measure_landed`, replace the landed entries with the branch's | inline: 3 FAIL (`a branch-added entry, not installed, is pending -> exit 0`, ...); black-box 9/6 |
| `pending-fails`: the OK path returns `EXIT_FAIL` when anything is pending | inline: 2 FAIL (`a branch-added channel is pending, named -> exit 0`); black-box 12/3 |
| `unmeasured-passes`: `return EXIT_OK if bar.nil?` | inline: 2 FAIL (`landed bar unreadable -> exit 3`); black-box 11/4 (`origin unreachable -> could not measure, exit 3`) |
| `env-discriminator-branch`: the root-absent discriminator reads the branch list | black-box 14/1 (`root lost, landed repo checked out here, branch deletes its entry -> FAIL`) |
| `malformed-landed-passes`: a malformed landed registry becomes an empty bar | black-box 14/1 (`landed registry malformed -> could not measure, exit 3`) |

The last two are caught only by the black-box suite: the inline suite injects
the landed bar, so it cannot see how the real read treats a malformed file or
which list the discriminator uses. That is why both suites run in the gate.
