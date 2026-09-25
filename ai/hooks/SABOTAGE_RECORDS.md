# Sabotage records — `ai/hooks/` self-tests

A test is not finished until you have watched it fail: delete or corrupt the
thing it exists to prove, run it, confirm the failure names the right criterion,
and write the failure string down next to the claim it supports. Root ADR 002
makes that mandatory per subproject, in stack-neutral vocabulary, so a shell
suite is in scope exactly as an Elixir one is.

## How to use this

Pick a row. Re-apply the mutation. The named case should fail. If it still
passes, the check it protects has stopped being load-bearing and the row is now
a bug report. Restore with `git checkout --` (these suites are committed) or
`cp` from a byte-for-byte backup — never `mv` (its preserved mtime has burned
this repo before). If a sabotage writes into the real `$HOME`, clean it up by
exact set-difference against a pre-sabotage snapshot, protecting this machine's
own live markers.

---

## 2026-09-19 — DND-224, hardening the "real `$HOME` untouched" guard

- **Domain:** the SessionStart inbox-poll hook's self-test
  (`ai/hooks/athena-inbox-poll.self-test.sh`), its final guard that the suite
  never mutates the live rate-limit state under the real `$HOME`.
- **Code under test:** `real_markers_fingerprint()` and the two end-of-suite
  checks — the fake-project-hash leak detector (1) and the daemon-untouched
  mtime fingerprint (2).
- **Suite run:** `bash ai/hooks/athena-inbox-poll.self-test.sh` (no network;
  fake `$HOME` + `mktemp -d` per case).
- **Baseline:** `VERDICT: PASS (177 cases)`.

### Why the guard was changed (the P1 that started this)

`origin/main` failed `ai/bin/harness-gate` 18/19 on this suite. The suite passed
in isolation (176/176) but failed inside the ~150s sequential gate. Root cause:
the old `real_markers_fingerprint()` captured the mtime of the WHOLE marker
family, including `athena-inbox-last-poll`, `athena-inbox-poll.log` and the
`athena-inbox-seen` directory — three things the REAL SessionStart poll rewrites
on EVERY new session (the attempt marker, the log, and this machine's own
per-project markers under its REAL repo hash `f697ca3e…`). Solo, the suite
finished before a live write landed; inside the gate a legitimate concurrent
poll write landed mid-run and the guard cried wolf. A FALSE-POSITIVE guard, not
a hook defect.

### S-DND224-1 — the guard must still CATCH a genuine leak (positive sabotage)

- **Mutation:** `pm()` (the per-case marker-path helper) rewritten to build its
  path from `${REAL_HOME}` instead of the per-case `${HOME}` — the realistic
  "a helper wrote a real-`$HOME` path" bug. Every case that does
  `touch "$(pm …)"` then writes a marker into the real
  `~/.claude/athena-inbox-seen/` keyed to the FAKE project it fabricated under
  `$TMP`.
- **Expected failure:** check (1) reddens, naming each leaked fake-keyed marker.
- **Observed:**
  ```
  FAIL  no fake-project marker leaked into the real $HOME seen dir
        the suite wrote per-project marker(s) into /home/cjpoll/.claude/athena-inbox-seen keyed to a FAKE
        project it fabricated under /tmp/tmp.MeV5XFsrjR -- so a case ran the hook against the
        real $HOME rather than its per-case tmp home:
        15a05f6ba6ae23ca5814186c2936ff26.success  (fake project: /tmp/tmp.MeV5XFsrjR/case-10/proj/.git)
        15a05f6ba6ae23ca5814186c2936ff26.warn  (fake project: /tmp/tmp.MeV5XFsrjR/case-10/proj/.git)
        …
  VERDICT: FAIL (10 of 177 cases)
  ```
  The check names WHAT leaked (the fake-project hash and its key) and how to
  self-correct, per this repo's "guard messages are written for the LLM" and
  "a failed lookup must never look like an empty one" conventions.
- **Cleanup:** restored the suite with `git checkout --`; removed the 32 leaked
  markers from `~/.claude/athena-inbox-seen/` by exact set-difference against a
  pre-sabotage `ls` snapshot, protecting the live `f697ca3e…` markers. Verified
  the real seen dir was byte-identical to the baseline afterward.

### S-DND224-2 — the OLD guard cried wolf; the NEW one does not (differential proof)

- **Mutation / stimulus:** drove the OLD and NEW fingerprint logic over a
  synthetic real-home directory, then simulated a coinciding live poll write
  (re-stamp `athena-inbox-last-poll` + `athena-inbox-poll.log`, add/refresh a
  marker under the REAL repo hash, move the seen-dir mtime).
- **Observed:**
  - Scenario A (a live poll write coincides): OLD guard = `FAIL (cried wolf)`;
    NEW guard = `PASS`, fake-hash check = `clean`.
  - Scenario B (a genuine leak under a FAKE hash): NEW fake-hash check =
    `LEAK:…success`, reddens and names the file.
- This is the exact conflation the change removes: a concurrent live write no
  longer reads as a suite leak, while a real leak still reddens.

### S-DND224-3 — the shared poll.log is still guarded (by content)

Dropping `athena-inbox-poll.log` from the mtime fingerprint (it races the live
poll's appends) must not open a leak hole for it. Check (3) guards it by content
instead.

- **Mutation:** a suite helper appends a line mentioning the tmp root to the
  REAL log — `printf … "${TMP}" >> "${REAL_HOME}/.claude/athena-inbox-poll.log"`.
- **Observed:** `FAIL  the suite left no trace in the real $HOME poll log`
  (`VERDICT: FAIL (1 of 178 cases)`). The live poll never logs a `${TMP}` path
  nor the sentinel, so the check cannot be tripped by a concurrent live write.
- **Cleanup:** restored the suite with `git checkout --`; restored the real log
  from a byte-for-byte `cp -a` backup taken before the run.

### S-DND224-4 — check (1) fails when it looked at NOTHING

- **Mutation:** point the repo-enumerating `find` at a non-existent dir
  (`find "${TMP}/nope" …`), so the loop checks zero projects.
- **Observed:** `checked ZERO fake projects … so this check vouches for
  nothing` (`VERDICT: FAIL (1 of 178)`). A green run that examined nothing is
  now impossible — "a failed lookup must never look like an empty one".
- **Cleanup:** none — the mutation writes nothing under the real `$HOME`;
  restored the suite with `git checkout --`.

### S-DND224-5 — check (1) fails when a fake hash can't be computed

- **Mutation:** truncate the hash to zero chars (`cut -c1-0`), so every fake
  project yields an empty/bad hash.
- **Observed:** `could not compute the marker hash for fake project(s) …`
  (`VERDICT: FAIL (1 of 178)`). An uncomputable key reddens rather than silently
  skipping the project it could not vet.
- **Cleanup:** none — the mutation writes nothing under the real `$HOME`;
  restored the suite with `git checkout --`.

### Z-DND224-1 — MEASURED LIMITATION: `athena-inbox-last-poll` is unguarded

**Who can write into the real `~/.claude`?** Not the hook. Every hook invocation
in this suite goes through `run_hook` / `run_stub_hook`, and both call
`assert_fake_home` first — which FATAL-exits the whole suite the instant `HOME`
is the real home. So a hook run against the real `$HOME` is *structurally
prevented*, not merely detected after the fact; the no-channel branch also
stamps nothing (`athena-inbox-poll.sh` "no registry entry declares a channel …
the marker family was left untouched"). The dropped mtime fingerprint on
`last-poll` / `poll.log` was therefore a backstop for an event `assert_fake_home`
already prevents, and racy against the live daemon besides — removing it removed
a false-positive source, not a real guarantee.

**The one remaining vector is a suite HELPER that hardcodes `${REAL_HOME}`.**
Those are covered: a helper writing a project-keyed marker → check (1)
(S-DND224-1); a helper appending fake-env text to the log → check (3)
(S-DND224-3, since realistic helper text carries the `${TMP}` root or sentinel).

**The single residual is a helper that touches ONLY `athena-inbox-last-poll`.**
That file is a shared, 0-byte attempt marker the live poll stamps every session;
a stray touch is byte-for-byte indistinguishable from the daemon's own (no
project key, no content, only an mtime the daemon moves anyway), so no guard can
tell them apart without racing — the very false positive this ticket removed. It
is left unguarded deliberately, and it is safe: a touch of the attempt marker
changes NO rate-limit decision (it records only "when did this machine last
attempt"). The rate-limit state that gates warnings — per-project seen markers
(check 1), top-level fallback markers + settings.json (check 2), the log's
content (check 3) — all remain guarded. This row records the residual gap rather
than leaving it silent.

---

## 2026-09-20 — the `settings.json` mtime false positive (shipwright cron)

- **Domain:** the same suite's end-of-run guard that the real `$HOME` is
  untouched — specifically its coverage of `~/.claude/settings.json`, moved
  from an **mtime** fingerprint (check 2) to a **content** fingerprint
  (check 4).
- **Baseline:** `VERDICT: PASS (199 cases)` (was 197).

**What happened.** `ai/bin/harness-gate` went RED on an **untouched tree**, on
this one case, reporting only an mtime diff on `settings.json`
(`:1789882883` → `:1789887771`) with every other member matching. Run solo the
same suite passed `197/197` and left the file byte-identical. `setup-hooks
--self-test` and `check-hooks-registered` were instrumented the same way and
also left it unchanged. So the suite never wrote it: the **live Claude Code
process** did, asynchronously, mid-gate.

The check-2 comment asserted `settings.json (the hook only ever READS it)`.
That is true of the *hook* and false as a guarantee about the *file*, which is
the conflation that made the assertion racy — the identical class as DND-224
one ticket earlier, surviving on the one member DND-224 left in.

**Why the poll-log signature (check 3) could NOT be reused.** `assert_fake_home`
does *not* make a stray write to this file impossible, unlike the log: some
cases deliberately restore `HOME="${REAL_HOME}"` for the asdf ruby shims, and
`scripts/setup-hooks` resolves
`SETTINGS="${HOOKS_SETTINGS_FILE:-${HOME}/.claude/settings.json}"` — so a call
that loses that seam merges into the machine's LIVE hook wiring. And because
`setup-hooks` resolves hook paths against the MAIN CHECKOUT, such a leak writes
`/home/cjpoll/dev/custom/...` — carrying neither `${TMP}` nor `${SENTINEL}`. A
`${TMP}`/sentinel grep here would have been **a check that can never fire**.
This is PRIMARY coverage, not a backstop.

| id | Mutation | Expected failure |
|---|---|---|
| S-1 | Drop a hook command from the settings under test (what a leaked `setup-hooks --install` merge does) | `the suite left the real settings.json hook wiring untouched` — MEASURED: 12 → 11 triples, check fires RED |
| S-2 | Point `REAL_SETTINGS` at a file containing `{` | `could not parse the hook wiring out of …` after 3 bounded retries — MEASURED: yields `UNREADABLE(...)`, loud, never a silent `ok` |
| S-3 | Run with `comm` off `PATH` | `comm(1) is not on PATH …` — the backup-trail check must not silently pass when it cannot evaluate |
| S-4 | **Negative control.** Rewrite `model`/`theme`/`effortLevel` and move the mtime, hooks block untouched (simulating the live writer) | Both prongs stay GREEN — MEASURED. The OLD mtime fingerprint goes RED on this same stimulus; that conflation is exactly what was removed |

S-1/S-2/S-4 were driven over a **synthetic** real-home copy
(`cp ~/.claude/settings.json "$T/"`), per the `S-DND224-2` precedent — never
against the live file.

**Why this is a STRENGTHENING, not a relaxation.** The mtime fingerprint could
be defeated by a mutation that preserved mtime — and this file's own header
warns that `mv`'s preserved mtime "has burned this repo before". A content
fingerprint catches that; mtime did not. What it drops is coverage of a
*content-identical touch*, which is not a harm. Net: strictly more
harm-detection, minus one non-harm, minus a false-positive source.

A delimiter note, since this repo keeps re-finding the class: the fingerprint
emits **JSON triples**, not `"$event|$matcher|$command"`, because a live matcher
legitimately CONTAINS the pipe — verified on this machine, e.g.
`Bash|SendMessage|mcp__notion-(work|personal)__(...)`.

### Z-DND224-2 — MEASURED LIMITATION: non-`hooks` keys are unguarded

A suite write that changed only a NON-hooks key of the real `settings.json`
(`permissions`, `model`, `theme`, `enabledPlugins`) is not caught: it is
byte-for-byte indistinguishable from the live Claude Code writer, which rewrites
exactly those keys, so no guard can separate them without racing — the very
false positive this change removes. Accepted because the only settings-writing
tool this suite invokes is `scripts/setup-hooks`, which is covered on BOTH
prongs: it changes the hooks block, and it leaves a `settings.json.bak-<ts>`
behind.

---

## 2026-09-25 — DND-670, git-stash-guard

- **Domain:** the PreToolUse(Bash) guard that denies writes to the shared git
  stash list (`ai/hooks/git-stash-guard.sh`).
- **Suite run:** `sh ai/hooks/git-stash-guard.self-test.sh` (hermetic: fixture
  repos under `mktemp -d`, `GIT_CONFIG_GLOBAL` a fixture file,
  `GIT_CONFIG_NOSYSTEM=1`).
- **Baseline:** `RESULT: 88 passed, 0 failed` / `VERDICT: PASS` (79 at the first commit; critic round 1 added I27-I30 and A14; round 2 added A15-A18).

### Fail-first (no guard)

The hook replaced by a stub that reads stdin and exits 0 (what a session has
with no guard). The mechanism cases M1a/M1b pass (the fixture reproduces the
incident: the worktree's refs/stash is the owner's, and an unguarded pop
consumes the owner's entry). The incident cases fail:

```
FAIL  W1. git stash pop from the linked worktree (expected deny) status=0 out=[]
FAIL  W2. bare git stash from the linked worktree (expected deny) status=0 out=[]
FAIL  W3. owner stash list byte-identical after the guarded attempts status=0 out=[before=[stash@{0}: On main: OWNER-ENTRY
RESULT: 21 passed, 58 failed
```

### Sabotage rows (each MEASURED 2026-09-25, restored with `cp` from a backup)

| id | Mutation | Observed failure |
|---|---|---|
| S-DND670-1 | Read allowlist `^(list\|show\|create)$` also admits `pop` | W1, W3 (the owner's entry is popped through the guard), I1/I2/I6/I8/I13/I14/I16/I19/I22/I24, A1/A3/A5/A6/A10, T1, F5, F6 — `RESULT: 59 passed, 20 failed` |
| S-DND670-2 | Global-option skipping disabled for `-C`/`-c`/spaced long options | I2 `git -C <wt> stash`, I3 `git -c k=v stash`, I5 `git --work-tree <d> stash`, A10 — `75 passed, 4 failed` |
| S-DND670-3 | Alias resolution removed (`decide` returns "" for any non-`stash` word) | A1-A6, A10, F6 — `71 passed, 8 failed` |
| S-DND670-4 | Dequoting removed (`tr -d` of quotes/backslash replaced by `cat`) | I7 `sh -c 'git stash'`, I14 `git st"a"sh pop`, I15 `g\it stash` — `76 passed, 3 failed` |
| S-DND670-5 | The unknown-option continuation removed from `git_verdict` (a word after an unknown dash option is no longer also read as that option's value) | I28 `git --some-future-opt val stash pop`, I29 the same through `$GIT` — `82 passed, 2 failed` |

### Critic round 1 regression (the `--attr-source` miss)

The critic found `git --attr-source <tree> stash pop` allowed: the hook skipped
only a hardcoded list of two-word options. Fixed at the class level (any word
after an unknown dash option is decided and the scan continues), plus
same-command `cd` dirs for repo-local aliases. The new cases against the first
commit's hook:

```
FAIL  I27. git --attr-source <tree> stash pop (two-word option) (expected deny) status=0 out=[]
FAIL  I28. an unknown two-word option before stash (expected deny) status=0 out=[]
FAIL  I29. $GIT with an unknown two-word option (expected deny) status=0 out=[]
FAIL  A14. repo-local alias reached by a same-command cd (expected deny) status=0 out=[]
RESULT: 80 passed, 4 failed
```

After the fix: `RESULT: 84 passed, 0 failed`.

### Critic round 2 regression (an alias value that starts with an option)

The critic found `alias.z = -c color.ui=never stash pop` allowed: `decide`
took the alias value's first word (`-c`) as the subcommand, while git runs an
alias value through its own option parser. Fixed at the root: an alias value
is now parsed by the same `git_verdict` as a command line (option skipping and
the unknown-option continuation included). The new cases against the round-1
hook:

```
FAIL  A15. alias value with a global option: z = -c k=v stash pop (expected deny) status=0 out=[]
FAIL  A16. alias np = --no-pager stash (bare) (expected deny) status=0 out=[]
FAIL  A17. alias np + pop (expected deny) status=0 out=[]
RESULT: 85 passed, 3 failed
```

After the fix: `RESULT: 88 passed, 0 failed`. Class-closed assertion: `grep -c
'decide(a\[1\]' ai/hooks/git-stash-guard.sh` returns 0 — no path decides a
word list without the option parser.
