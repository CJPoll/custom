# Sabotage records — the inbox tenancy registry's three artifacts

A test is not finished until you have watched it fail: delete the thing it
exists to prove, run it, confirm the failure names the right criterion, and
write the failure string down next to the claim it supports. Root ADR 002 makes
that mandatory per **subproject**, in deliberately stack-neutral vocabulary, so
a shell suite is in scope exactly as an Elixir one is.

## How to use this

Pick a row. Re-apply the mutation. The named case should fail. If it still
passes, the check it protects has stopped being load-bearing and the row is now
a bug report.

Rows recording a **measured zero** are the important ones — they mark a claim
no test protects. This run produced three (Z1–Z3), written up below rather than
quietly dropped.

Every mutation was applied by an exact-substring replace that asserted the
anchor occurs **exactly once** before writing (a sabotage applied by substring
lands wherever the substring first occurs; the wrong site gives a green run
that reads as "the test is dead"), and restored with `cp` from a byte-for-byte
backup taken before the run — never `mv`, whose preserved mtime has burned this
repo before, and never `git checkout --`, which cannot restore a file that is
not yet committed.

---

## 2026-09-18 — DND-208, building the three artifacts

- **Domain:** the Athena Inbox tenancy registry (`ai/contracts/athena-inbox.md`
  → *Provisioning*, *Tenancy: the registry*)
- **Date:** 2026-09-18
- **Code under test:** `ai/inbox/registry.json`, `ai/inbox/lib/registry.rb`,
  `scripts/setup-inbox-registry`, `ai/bin/check-inbox-registry`
- **Suite run:** `bash ai/inbox/test/self-test.sh` (no network; fake `$HOME` +
  `mktemp -d`; ~4s)
- **Baseline:** `VERDICT: PASS (37 cases)` — 22 at the first pass, 24 after the
  first sweep found two unprotected claims, 37 after the review round (one
  code-reviewer, one ADR-reviewer, one standing critic) found nine more
  properties nothing was pinning.
- **Runner:** 30 mutations, one at a time, full suite after each.

### What the suite proves

Case ids only; the case's own text is in `test/self-test.sh`.

| # | Mutation | File | Cases reddened |
|---|---|---|---|
| S1 | the "already installed" branch → `if false` (every run rewrites) | installer | C2, C8 |
| S2 | `rm_f` every `*.json` in `projects/` before writing — a directory rewrite, the 2026-09-17 shape | installer | **C3**, C2, C8, C8b, C31 |
| S3 | the entry is published `0644` (chmod before the rename) | installer | C1, C2, C8, C10, C25, C33 |
| S4 | the root and `projects/` created `0755` | installer | C1, C2, C33 |
| S5 | the "entry is missing" problem is not recorded | lib | C9 |
| S6 | the content comparison `have != want` → `false` | lib | C5, C6 |
| S7 | the entry-mode comparison → `if false` | lib | C11 |
| S8 | the absent-root early return removed (env-safety gone) | check | C14 |
| S9 | the early return keys off `projects/` instead of the root | check | C15 |
| S10 | `git_common_dir` returns git's RAW output — **the cwd-relative trap** | lib | C17 |
| S11 | `expand_repo` no longer expands `~` | lib | 20 cases |
| S12 | `reject_unreadable` returns early — the reader's validator is never consulted | lib | C19 |
| S13 | the check writes a marker file into `projects/` on every run | check | C7 |
| S14 | the drift failure's `Fix:` clause removed | check | C6 |
| S15 | `backup()` copies nothing | installer | C8, C8b, C13, C31 |
| S16 | an unknown flag falls back to `--install` | installer | C20 |
| S17 | a malformed source of truth exits 1, like ordinary drift | check | C21, C27 |
| S18 | the check enumerates `projects/*.json` and reports every file found | lib | C4, C8, C10, C25, C33 |
| S19 | a credential (`"token": "xoxb-…"`) added to the committed source of truth | registry.json | C22, C23 |
| S20 | backups written into `projects/` under candidate-looking names | installer | C8, C8b, C13, C24, C31 |
| S21 | the inbox root's own mode is not checked | lib | C34 |
| S22 | `File.lstat` → `File.stat` in `drift` (a symlinked entry is followed) | lib | C26 |
| S23 | truncate-in-place instead of temp+rename (writes THROUGH a symlink) | installer | C25 |
| S24 | duplicate `file`/`repo` declarations are accepted | lib | C27 |
| S25 | the declared filename grammar is not enforced | lib | C28 |
| S26 | the 128-byte filename bound is not enforced | lib | C29 |
| S27 | a renamed live entry is duplicated instead of refusing the install | installer | C30 |
| S28 | same-second backups overwrite each other | installer | C31 |
| S29 | `--check` dispatched as a shell-split single string | installer | **none — see Z3** |
| S30 | an absent root is always "not this environment" | check | C35 |

### Four cases the sweep itself produced

Four mutations were **green on first application**, and three times the fault
was the suite rather than the mutation. Each is now fixed and re-measured:

- **C7** took its "nothing changed" snapshot *after* earlier cases had already
  run a failing check, so a check that wrote the same marker file every run
  compared one polluted state against the next. It now rebuilds the sandbox and
  snapshots immediately before the call it measures.
- **C20** ran against the deliberately-invalid fixture left by C19, so the
  installer refused for the *wrong reason* while a typo'd flag silently
  installed. It now resets first and asserts nothing was written.
- **C13** asserted a backup existed, and matched the one C8 had already left
  behind — so a `remove()` that backed nothing up stayed green. It now rebuilds
  the sandbox, clears the backup directory, and asserts the backup *this*
  remove made.
- **C33** was added on review advice and immediately caught a real defect the
  advice itself introduced: `exec(CHECKER, CHECKER)` passes argv0 as an
  *argument*, so `--check` died with "unknown argument". The correct form is
  `exec([CHECKER, CHECKER])`.

All three suite faults are the same class: a case that inherits state proves the
state, not the code.

### Measured zeros — claims nothing protects

- **Z1 — "the *check* never reads an undeclared entry."** C4 proves an
  undeclared entry is neither failed nor named, and S18 reddens it. But a check
  that opened and parsed `stranger.json` and then stayed silent would pass every
  case here: the suite observes output and writes, not reads. The check only
  stats the files the committed list declares, so the property holds by
  construction and is asserted nowhere. (The *installer* does read undeclared
  entries, deliberately and only for `repo`, to refuse the identity collision
  C30 covers.) Proving it would need `strace`-class observation, which is not
  worth its weight for a single-user local facility.
- **Z2 — "the temp file is never world-readable mid-write."** The entry itself
  is now covered: it is created in a temp file at `0600` and renamed into place,
  so C1/C25 and S3 pin the published mode and S23 pins the rename. What no case
  can see is the mode of the temp file *between* `open` and `rename`; the mode
  is passed to `open`, so there is no window, but a mutation that chmod'd
  afterwards instead would not redden anything.
- **Z3 — the single-string `exec` hazard is not observable in this repo.** S29
  (`exec(CHECKER)` instead of `exec([CHECKER, CHECKER])`) left the suite green,
  and C36 — which invokes the installer through a symlinked path containing a
  space — does not catch it either: Ruby's `__dir__` *realpaths* the running
  file, so the space is resolved away before `CHECKER` is built. The hazard
  needs the **real** repo path to contain a shell metacharacter, which cannot be
  arranged without copying the whole repo. The argv0 form is kept because it is
  correct, not because a case proves it; C36 still proves the tools work when
  reached through such a path.
