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
no test protects. This run produced two (Z1, Z2), written up below rather than
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
  `mktemp -d`; ~2s)
- **Baseline:** `VERDICT: PASS (24 cases)` (22 at the first pass; C23 and C24
  were added after the sweep turned up two claims nothing protected)
- **Runner:** 20 mutations, one at a time, full suite after each.

### What the suite proves

| # | Mutation | Cases reddened | Failure string(s) |
|---|---|---|---|
| S1 | installer: the "already installed" branch → `if false` (every run rewrites) | 1 | `FAIL  C2 a second install is a no-op` |
| S2 | installer: `rm_f` every `*.json` in `projects/` before writing (a directory rewrite, the 2026-09-17 shape) | 4 | `FAIL  C3 an undeclared entry survives an install byte for byte` (+ C2, C8, C13) |
| S3 | installer: entries created and chmod'd `0644` | 4 | `FAIL  C1 install writes the entry 0600 inside a 0700 projects/` (+ C2, C8, C10) |
| S4 | installer: `projects/` created `0755` | 2 | `FAIL  C1 install writes the entry 0600 inside a 0700 projects/` (+ C2) |
| S5 | check: the "entry is missing" problem is not recorded | 1 | `FAIL  C9 a deleted entry fails the check` |
| S6 | check: the content comparison `have != want` → `false` | 2 | `FAIL  C5 a hand-edited entry fails the check, naming the entry` (+ C6) |
| S7 | check: the entry-mode comparison → `if false` | 1 | `FAIL  C11 a 0644 entry is reported as drift` |
| S8 | check: the absent-root early return removed (env-safety gone) | 1 | `FAIL  C14 no inbox root -> the check passes with a note` |
| S9 | check: the early return keys off `projects/` instead of the root (a missing registry reads as "not this environment") | 1 | `FAIL  C15 a root with no projects/ is drift, not 'not this environment'` |
| S10 | `git_common_dir` returns git's RAW output instead of resolving at the point of capture — **the cwd-relative trap** | 1 | `FAIL  C17 a main checkout's common dir resolves absolute, at the point of capture` |
| S11 | `expand_repo` no longer expands `~` | 11 | `FAIL  C16 a ~-relative repo is installed as an absolute path` (+ C1, C2, C4, C8, C10, C11, C12, C13, C18, C22) |
| S12 | `reader_rejection` never consults the `athena:inbox` validator | 1 | `FAIL  C19 an entry the reader refuses is not installed` |
| S13 | check writes a marker file into `projects/` on every run | 1 | `FAIL  C7 the check writes nothing, even when it fails` |
| S14 | check: the drift failure's `Fix:` clause removed | 1 | `FAIL  C6 the drift failure carries an actionable Fix: line` |
| S15 | installer: `backup()` copies nothing | 2 | `FAIL  C8 install repairs a drifted entry and backs up what it replaced` (+ C13) |
| S16 | installer: an unknown flag falls back to `--install` | 1 | `FAIL  C20 an unknown flag is refused with a Fix: line` |
| S17 | check: a malformed source of truth exits 1, like ordinary drift | 1 | `FAIL  C21 a malformed source of truth exits 2 with a Fix: line` |
| S18 | check: enumerate `projects/*.json` and report every file found | 3 | `FAIL  C4 an undeclared entry is neither failed nor named by the check` (+ C8, C10) |
| S19 | a credential (`"token": "xoxb-…"`) added to the committed source of truth | 1 | `FAIL  C23 the committed registry carries no credential` |
| S20 | installer: backups named `<name>-bak.json` (a filename that PARSES as a registry candidate) | 3 | `FAIL  C24 an installer backup does not match the registry filename grammar` (+ C8, C13) |

### Two cases the sweep itself produced

S13 and S16 were **green on their first application**, and both times the fault
was the suite, not the mutation:

- **C7** took its "nothing changed" snapshot *after* earlier cases had already
  run a failing check, so a check that wrote the same marker file on every run
  compared one polluted state against the next and passed. C7 now rebuilds the
  sandbox and snapshots before the first check call it measures.
- **C20** ran against the deliberately-invalid fixture left by C19, so the
  installer refused for the *wrong reason* and the case passed while a typo'd
  flag silently installed. C20 now resets the sandbox first and additionally
  asserts nothing was written.

Both are the ordinary failure mode of a shared sandbox: a case that inherits
state proves the state, not the code.

### Measured zeros — claims nothing protects

- **Z1 — "the check never *reads* an undeclared entry."** C4 proves an
  undeclared entry is neither failed nor named, and S18 reddens it. But a check
  that opened and parsed `stranger.json` and then stayed silent would pass every
  case here: the suite can observe output and writes, not reads. The
  implementation does not enumerate `projects/` at all — it only stats the files
  the committed list declares — so the property holds by construction and is
  asserted nowhere. Closing it would need `strace`-class observation, which is
  not worth its weight for a single-user local facility; recorded instead.
- **Z2 — "an entry is never world-readable, not even transiently."** C1 and C11
  observe the *final* mode. An implementation that created the file `0644` and
  chmod'd it to `0600` a microsecond later would pass both. The installer passes
  the mode to `File.open` at creation, so there is no window, but no case can
  tell the two apart. (The contract states this obligation directly — *Root and
  permissions*: `chmod` must happen **before** the file becomes visible.)
