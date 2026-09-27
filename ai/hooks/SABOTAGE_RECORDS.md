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
- **Baseline:** `RESULT: 258 passed, 0 failed` / `VERDICT: PASS` (79 at the first commit; fix round 2 added B1-B7, C1-C18 and F8-F13; fix round 3 V1-V17 and AC1-AC8; critic round 1 added I27-I30 and A14; round 2 A15-A18; round 3 I31-I39 and OK11; self-review A19-A21; round 4 A22-A27; bounds A28, N1; round 6 I40-I58 and S1-S8; round 7 I59-I65 and F7; fix round W2a-W2c, R7-R41, I66-I77 and Z1-Z8).

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

### Sabotage rows (re-MEASURED 2026-09-25 on the round-3 tokenizer, restored with `cp` from a backup)

| id | Mutation | Observed failure |
|---|---|---|
| S-DND670-1 | Read allowlist `^(list\|show\|create)$` also admits `pop` | W1, W3 (the owner's entry is popped through the guard), and 28 more — `RESULT: 67 passed, 30 failed` |
| S-DND670-2 | Known two-word option list emptied (`two_word` returns 0) | OK11 `git -C stash status` over-denied — `97 passed, 1 failed`. No deny case fails: the unknown-option continuation (S-5) covers every two-word option, so this list only prevents over-denial |
| S-DND670-3 | Alias resolution removed (`decide` returns "" for any non-`stash` word) | A1-A6, A10, A14-A17, F6 — `85 passed, 12 failed` |
| S-DND670-4 | Tokenizer quote states removed (a quote char is dropped, not honoured) | I31-I33, I35, I36 (a quoted value holding a space splits into words) — `92 passed, 5 failed` |
| S-DND670-5 | The unknown-option continuation removed from `git_verdict` | I28 `git --some-future-opt val stash pop`, I29 the same through `$GIT` — `95 passed, 2 failed` |
| S-DND670-6 | Quoted words no longer re-read as commands | I7 `sh -c 'git stash'`, I8 `bash -c "cd x && git stash pop"`, I35 — `94 passed, 3 failed` |
| S-DND670-7 | Tokenizer no longer marks unquoted glob/brace characters | I40-I45, I47, I53, I54, I56, I57 — `125 passed, 11 failed` (measured on the round-6 code) |
| S-DND670-8 | Shell-alias expansion in command position removed | S1, S3, S4, S5 — `132 passed, 4 failed` (measured on the round-6 code) |
| S-DND670-9 | `one_word` emptied (no global option is known to take no value) | I63 `git --no-pager $SUB` allowed — `143 passed, 1 failed` (round-7 code) |
| S-DND670-10 | A POSSIBLE subcommand decided in full (an expanded one denies too) | I64 `git --some-future-opt diff $X`, A26 `$EDITOR $FILE` over-denied — `142 passed, 2 failed` (round-7 code) |
| S-DND670-11 | `plumb()` no longer called from `decide` | R7-R11, R13-R19, R22-R25 — `156 passed, 16 failed` (fix-round code) |
| S-DND670-12 | `is_stash_ref` accepts only `refs/stash` (short name `stash` not recognised) | R7, R8, R10, R11, R13, R23, R25 — `165 passed, 7 failed` |
| S-DND670-13 | A plumbing verb with no literal ref argument is allowed | R15 (xargs-fed `update-ref -d`) — `171 passed, 1 failed` |

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

### Critic round 3 regression (a quoted option value holding a space)

The critic found `git -C "/tmp/a b" stash pop` and `git -c "user.name=A B"
stash pop` allowed: the hook dequoted the whole command before splitting it on
spaces, so one quoted value became two words and the scan stopped on the
second. Same class as rounds 1 and 2 (the scan ends early after a git head);
its root is that dequoting destroyed shell word boundaries. Fixed at the root:
the verdict now tokenizes the raw command like sh (quotes and backslashes
honoured), and re-reads a quoted word that held whitespace or a separator as a
command of its own. The new cases against the round-2 hook:

```
FAIL  I31. -C with a quoted dir holding a space (expected deny) status=0 out=[]
FAIL  I32. -c with a quoted value holding a space (expected deny) status=0 out=[]
FAIL  I33. --git-dir= with a quoted space (expected deny) status=0 out=[]
FAIL  I35. nested quotes inside bash -c (expected deny) status=0 out=[]
FAIL  I36. single-quoted value with a space (expected deny) status=0 out=[]
FAIL  I37. backslash-escaped space in -C (expected deny) status=0 out=[]
RESULT: 91 passed, 6 failed
```

After the fix: `RESULT: 98 passed, 0 failed`.

### Self-review after round 3 (alias lookup misses)

A sweep of the alias class before the next critic round found two more
misses: git matches alias names case-insensitively (`git SP` runs alias.sp;
verified on git 2.55 with a fixture alias), and an alias can be defined
through an environment variable whose value is not in the command text
(`--config-env=alias.p=P`, `GIT_CONFIG_KEY_0=alias.p`). The new cases against
the round-3 hook:

```
FAIL  A19. alias names match case-insensitively (git SP) (expected deny) status=0 out=[]
FAIL  A20. alias through --config-env (expected deny) status=0 out=[]
FAIL  A21. alias through GIT_CONFIG_KEY_n (expected deny) status=0 out=[]
RESULT: 98 passed, 3 failed
```

After the fix: `RESULT: 101 passed, 0 failed`.

### Critic round 4 regression (a shell alias that chains to a stash alias)

The critic found `alias.x2 = !git sp` (with `sp = stash pop`) allowed: a
shell alias was checked only for the literal text `stash`, never read as a
command. Same class as round 2 (an alias expansion not parsed the way the
command line is). Fixed at the root: a shell alias body goes through
`analyze`, like a `sh -c` word. Swept with it: a stash alias after an
expanded command word (`$GIT sp`), which also needed the prefilter and the
alias read to fire on an expansion, not only on a `git` word. The new cases
against the self-review hook:

```
FAIL  A22. shell alias chaining to a stash alias: x2 = !git sp (expected deny) status=0 out=[]
FAIL  A25. a stash alias through an expanded command word: $GIT sp (expected deny) status=0 out=[]
RESULT: 105 passed, 2 failed
```

After the fix: `RESULT: 107 passed, 0 failed`. Class-closed assertion: every
path that turns an alias value into words now reaches `git_verdict` or
`analyze` — `grep -nE 'mentions_stash\(v\)' ai/hooks/git-stash-guard.sh`
shows the one remaining literal check is OR-ed with `analyze`, never alone.

### Self-review after round 4 (the recursion bounds failed open)

Both recursion bounds returned "allow" when exceeded: an alias chain deeper
than 10, and a command nested in more than 8 levels of quoted `sh -c`. A bound
that allows is a bypass by construction. Now an alias chain still resolving
at the bound is denied, and nested text past the bound is denied when it
names stash. The new cases against the round-4 hook:

```
FAIL  A28. an alias chain past the resolution bound (12 deep) (expected deny) status=0 out=[]
FAIL  N1. a stash write nested past the re-read bound (expected deny) status=0 out=[]
RESULT: 107 passed, 2 failed
```

After the fix: `RESULT: 109 passed, 0 failed`.

### Critic round 6 regression (words the shell rewrites), and the shell-alias sweep

The critic found `git {stash,pop}` allowed: brace expansion rewrites the word
before git sees it. Swept as the class "the shell rewrites a word before the
command runs": glob (`git st?sh pop`, `git st[a]sh`), brace, and a glob or
brace in the command word itself (`/usr/bin/g?t`, `git-st*sh`). Fixed at the
root: the tokenizer marks an unquoted glob/brace character, a marked
subcommand or verb counts as built by expansion, and a marked command word is
judged as both git and git-stash. The same sweep found the largest member of
the class: shell ALIASES. The Bash tool sources a snapshot of the owner's zsh
profile, and oh-my-zsh's git plugin defines `gstp='git stash pop'`, `gstd`,
`gstc`, `gsta`, `gstaa`, `gstall` (measured in
`~/.claude/shell-snapshots/`). A shell alias in command position is now
expanded from those snapshots and read as a command. The new cases against the
round-5 hook:

```
FAIL  I40. brace expansion git {stash,pop} (expected deny) status=0 out=[]
FAIL  I41. brace expansion git {stash,} pop (expected deny) status=0 out=[]
FAIL  I42. glob subcommand git st?sh pop (expected deny) status=0 out=[]
FAIL  I43. glob subcommand git st* (expected deny) status=0 out=[]
FAIL  I44. glob in the git command word (expected deny) status=0 out=[]
FAIL  I45. glob in the git-stash command word (expected deny) status=0 out=[]
FAIL  I47. bracket glob subcommand (expected deny) status=0 out=[]
FAIL  I53. glob command word after env VAR=x (expected deny) status=0 out=[]
FAIL  I54. glob command word after a separator (expected deny) status=0 out=[]
FAIL  I56. glob git-stash word, option-first (implicit push) (expected deny) status=0 out=[]
FAIL  I57. glob command word running a stash alias (expected deny) status=0 out=[]
FAIL  S1. shell alias gstp = git stash pop (expected deny) status=0 out=[]
FAIL  S3. shell alias g = git, then a git stash alias (expected deny) status=0 out=[]
FAIL  S4. shell alias chain gsp2 -> gstp (expected deny) status=0 out=[]
FAIL  S5. shell alias after a separator (expected deny) status=0 out=[]
RESULT: 121 passed, 15 failed
```

After the fix: `RESULT: 136 passed, 0 failed`. Live, against the real
snapshots: `gstp`, `gstd`, `gstc`, `gsta`, `gstaa`, `gstall` deny; `gstl`,
`gsts` allow.

### Critic round 7 — cluster round (over-denial from rounds 1 + 6 together)

The critic found `git --no-pager diff $BASE` denied: round 1's unknown-option
continuation treated `diff` as a possible option value and judged `$BASE` as
the subcommand, and round 6 made that word "expanded", a deny. A semantic
follow-on of two earlier edits, so a cluster round per athena:critic-convergence.

- **Cluster:** `git_verdict` candidate selection (the continuation), the
  `expanded` verdict in `decide`, the expanded-head branch, and the option
  tables.
- **Joint invariant:** a word is the DEFINITE subcommand only when every word
  before it is a known option or a known option's value; it is decided in
  full. A word reachable only by assuming an unknown option takes (or does not
  take) a value is a POSSIBLE subcommand and denies only when it is stash or a
  stash alias. An expanded head makes every candidate possible.
- **One edit:** `one_word` table (git 2.55 usage), `unknown` state in
  `git_verdict`, and the expanded-head branch folded into it.
- **Previously resolved findings still resolved:** every earlier case (I27-I29
  unknown options, A15-A17 alias options, I31-I37 quoting, A22/A25 shell
  alias and `$GIT sp`, I40-I58 globs) passes in the same run.

The same edit dropped `cmd_prefix` by accident; the awk program then failed to
parse and the hook allowed everything, silently. The suite caught it (21
cases red). Fixed, and made observable: an evaluator crash now allows WITH an
additionalContext saying the guard did not run (F7). The new cases against the
round-6 hook:

```
FAIL  I59. --no-pager diff with an expanded argument (expected allow) ... deny
FAIL  I60. --no-pager show with an unquoted brace ref (expected allow) ... deny
FAIL  I61. --no-pager log with a glob pathspec (expected allow) ... deny
FAIL  I62. -P log with an expanded argument (expected allow) ... deny
FAIL  I64. unknown option, then diff with an expanded argument (expected allow) ... deny
FAIL  F7. a crashed evaluator allows with a notice, not silently status=0 out=[]
RESULT: 138 passed, 6 failed
```

After the fix: `RESULT: 144 passed, 0 failed`.

### 2026-09-26 fix round (admiral; desktop critic BLOCK on e3d8803): the stash reflog by its short name

The desktop critic, reproduced by the harness session, found three forms that
empty or trim the stash list with no `refs/stash` text: `git reflog delete
'stash@{0}'`, `git reflog expire --expire=now stash`, `git reflog expire
--expire=now --all`. The old check was lexical on the literal `refs/stash`.
Fixed at the class level: `plumb()` reads the arguments of ref-rewriting git
plumbing and denies any that names the stash ref in any spelling, `--all`,
`--stdin`, an expanded ref, or no literal ref. The sweep (each verified
against git 2.55 in a scratch repo) added `reflog drop`, `update-ref -d stash`,
`symbolic-ref refs/stash`, fetch/push into refs/stash or refs/*,
filter-branch/filter-repo `--all`, and setting gc.reflogExpire*. `decide` now
passes ALL remaining words, so a git alias with arguments (`rx = reflog
expire`) is judged with them. Residuals are named in the hook header: gc,
maintenance and auto-gc under the existing expiry config, `--mirror` into the
same repo, and non-git writers by computed path.

The new cases against e3d8803's hook (W3: the owner's entry is actually
expired through the worktree):

```
FAIL  W2a. reflog delete stash@{0} from the linked worktree (expected deny) status=0 out=[]
FAIL  W2b. reflog expire stash from the linked worktree (expected deny) status=0 out=[]
FAIL  W2c. reflog expire --all from the linked worktree (expected deny) status=0 out=[]
FAIL  W3. owner stash list byte-identical after the guarded attempts status=0 out=[before=[stash@{0}: On main: OWNER-ENTRY
FAIL  R7-R11, R13-R25 (18 cases)
RESULT: 153 passed, 22 failed
```

After the fix: `RESULT: 175 passed, 0 failed`.

### Fix round, critic round 2 (0fdfca3): a push that deletes the stash ref

The critic found `git push . --delete stash`, `git push . :stash` and
`git push . --delete refs/stash` allowed. The fetch/push branch of `plumb()`
read only words containing `:`, and compared the destination literally with
`refs/stash` instead of using `is_stash_ref`. Verified in a scratch repo (git
2.55): a push to the repo itself with `--delete stash` or `:stash` empties the
stash list; `+HEAD:stash` is refused by git as a "funny ref". Fixed: every
refspec destination goes through `is_stash_ref` (or a `refs/*` / `*` glob),
and for push a bare stash ref word or `--mirror` also counts. Class-closed
assertion: `grep -n '"refs/stash"' ai/hooks/git-stash-guard.sh` hits only
inside `is_stash_ref`. The new cases against 0fdfca3's hook:

```
FAIL  R35. push . --delete stash (short name) (expected deny)
FAIL  R36. push . --delete refs/stash (expected deny)
FAIL  R37. push . :stash (delete refspec) (expected deny)
FAIL  R38. push . +HEAD:stash (overwrite refspec) (expected deny)
FAIL  R39. push --mirror (expected deny)
FAIL  R40. fetch into the short stash name (expected deny)
FAIL  R41. fetch with a bare * glob refspec (expected deny)
RESULT: 175 passed, 7 failed
```

After the fix: `RESULT: 182 passed, 0 failed`.

### Fix round, critic round 3 (33d8cfb): a redirect hides the subcommand

The critic found `git stash>/dev/null pop` and `git 2>/dev/null stash pop`
allowed. sh removes a redirection (operator, fd number and target) from argv
before git runs, but the tokenizer kept it in a word, so the scan read
`stash>/dev/null` or `2>/dev/null` as the subcommand. Same class as rounds 1-3
(a token sh strips ends the scan early). Fixed at the root: the tokenizer
drops redirections, `&>` included, and reads a process substitution body as a
command. Swept against the class "tokens sh removes from argv": assignments
(already cmd_prefix), backslash-newline (already dropped), an unquoted empty
expansion (`git $EMPTY stash`, already denied as expanded), brace `{,}` forms
(already glob-marked). A `#` comment can only hide words, so it over-denies
at worst. The new cases against 33d8cfb's hook:

```
FAIL  I66. redirect joined to the subcommand: git stash>/dev/null (expected deny)
FAIL  I67. redirect joined to the subcommand, then pop (expected deny)
FAIL  I68. redirect before the subcommand (expected deny)
FAIL  I69. fd redirect before the subcommand (expected deny)
FAIL  I70. git-stash binary with a joined redirect (expected deny)
FAIL  I71. &> redirect before the subcommand (expected deny)
FAIL  I72. fd duplication before the subcommand (expected deny)
FAIL  I73. input redirect before the subcommand (expected deny)
RESULT: 186 passed, 8 failed
```

After the fix: `RESULT: 194 passed, 0 failed`.

### Fix round, critic round 4 (0e8c9d0): zsh-only word rewrites

The critic found `=git stash pop` allowed. The Bash tool runs zsh, and zsh's
EQUALS option (on by default; verified with `zsh -fc '[[ -o equals ]]'`)
expands a leading `=name` to the command's path. Same class as round 6 (a word
the shell rewrites before the command runs), zsh member. Swept the zsh-only
rewrites: EQUALS (the tokenizer drops an unquoted leading `=` before a name),
global aliases (`alias -g`, substituted in any word position), suffix aliases
(`alias -s`, a `x.ext` command word), and the `noglob` / `nocorrect` / `-`
precommand modifiers. The snapshot read now keeps `-g` and `-s` aliases (none
exist on this machine today). The new cases against 0e8c9d0's hook:

```
FAIL  Z1. zsh =git (EQUALS expansion) (expected deny)
FAIL  Z2. zsh =git-stash (expected deny)
FAIL  Z3. zsh =git after env (expected deny)
FAIL  Z4. zsh global alias in argument position (expected deny)
FAIL  Z5. zsh suffix alias (expected deny)
FAIL  Z6. noglob precommand with a glob command word (expected deny)
RESULT: 196 passed, 6 failed
```

After the fix: `RESULT: 202 passed, 0 failed`.

### Fix round 2 (d86fa3e; desktop critic BLOCK): data past one exec argument's limit

The desktop critic found that the hook handed the command, the git aliases and
the snapshot shell aliases to awk through environment variables
(`GSG_CMD`, `GSG_ALIASES`, `GSG_SHALIASES`). The kernel refuses any single argv
or environment string over MAX_ARG_STRLEN (128 KiB) with E2BIG. The desktop's
snapshots held ~172 KB of aliases, so awk never ran (exit 126) and the hook
allowed every command. The shell-alias name list also went to the prefilter
`grep` as one argv pattern; past 128 KiB that grep failed (exit 2), which
`|| exit 0` read as "no match", a silent allow.

Class: an unbounded value handed to another process through argv or the
environment, plus an internal fault that reads as "nothing found". Fixed at the
root: the command, both alias sets and the alias-name patterns now go into files
in a private `mktemp -d` dir (removed by an EXIT trap); awk gets only their
paths (`-v cmdf=... alf=... shf=...`) and reads them with getline; grep reads
patterns with `-f`. Snapshot aliases are deduplicated with `sort -u`. A name
with different values in two snapshots now keeps every value (it was last-wins,
B7). An evaluation fault (the evaluator or snapshot reader failing, a grep error,
an unreadable global git config, an unwritable work file) is a FAULT with a
lexical fallback: deny when the text names `stash` or a stash-valued alias,
otherwise allow with a notice. The header records why it is neither
deny-everything nor allow.

New cases (B1-B7, F7-F13; F7's expectation changed from "allow with notice" to
"deny") run against d86fa3e's hook:

```
FAIL  B1. shell alias among >128 KiB of distinct snapshot aliases (expected deny) status=0 out=[]
FAIL  B2. shell alias among >128 KiB of duplicated snapshots (desktop shape) (expected deny)  [awk exited 126]
FAIL  B3. unrelated alias among >128 KiB of snapshots (expected allow)  [awk exited 126]
FAIL  B4. git alias among >128 KiB of global git aliases (expected deny)  [awk exited 126]
FAIL  B5. a command longer than 128 KiB (expected deny)  [awk exited 126]
FAIL  B6. a harmless command longer than 128 KiB (expected allow)  [awk exited 126]
FAIL  B7. an alias name with a stash value in any snapshot (expected deny) status=0 out=[]
FAIL  F7. a crashed evaluator fails closed on a literal stash write (expected fault deny)
FAIL  F9. a crashed evaluator fails closed on a shell alias spelling a stash write (expected fault deny)
FAIL  F10. a crashed evaluator fails closed on a git alias spelling a stash write (expected fault deny)
FAIL  F11. an unreadable global git config is a fault, not zero aliases status=0 out=[]
FAIL  F12. an unreadable global git config fails closed on a stash write (expected fault deny)
RESULT: 203 passed, 12 failed
```

After the fix: `RESULT: 215 passed, 0 failed`.

Sabotage rows (fixed hook, one mutation each, restored with `cp` from a backup):

| Mutation | Caught by |
| --- | --- |
| drop the `trap 'rm -rf "$GSG_TMP"' EXIT` | F13 (work dir left in `$TMPDIR`) |
| shell-alias loop reads only the LAST value of a name | B7 |

Class-closed assertions over the hook, each required to print nothing:
`grep -n 'ENVIRON' ai/hooks/git-stash-guard.sh`, and an env-prefixed exec
(`VAR="$x" cmd`) grep. Every remaining expansion of `$CMD`, `$FLAT`, `$INPUT`
or `$WRITES` is a `printf '%s'` builtin into a pipe, or a `[ -n ]` test.
Swept ai/hooks/ for the same hand-off: only `main-session-policy.sh`
(`INPUT="$input" python3`) passes hook stdin through the environment;
proposed separately, not fixed here.

### Fix round 2, critic round 16 (c46fc29): an alias in a config the hook does not read

The critic found `git --git-dir=/other/.git lp` allowed when `lp = stash pop`
is a local alias of `/other`. The hook reads aliases from the global config,
the cwd repo and each literal `-C`/`cd`/`pushd` dir, so git read a config the
hook never did. Same for `GIT_DIR=`, and a command-set `GIT_CONFIG_GLOBAL=` or
`HOME=`. Class (pre-existing, kind 1): the command points git at a config
source the hook does not read. Swept at its root rather than by reading each
source (computing the path is the failed-lookup class): when the command names
any such source, a subcommand that is not a git builtin (per `git
--list-cmds=builtins,main,others,nohelpers`) is denied as an unknown alias.
Sources: `--git-dir`, GIT_DIR, GIT_COMMON_DIR, GIT_CONFIG*, HOME,
XDG_CONFIG_HOME, `include.path` / `includeIf.*.path`, bare `cd` / `cd -` /
`popd`, and a `cd`/`pushd`/`-C` target that is expanded or holds whitespace.
The last two close residuals the header used to list ("a dir reached through
a variable", "a dir whose path contains whitespace", `-c include.path`).

New cases against c46fc29's hook:

```
FAIL  C1. --git-dir to a repo with a local stash alias (expected deny) status=0 out=[]
FAIL  C2. --git-dir as two words (expected deny) status=0 out=[]
FAIL  C3. GIT_DIR to a repo with a local stash alias (expected deny) status=0 out=[]
FAIL  C4. exported GIT_DIR (expected deny) status=0 out=[]
FAIL  C5. GIT_CONFIG_GLOBAL set by the command (expected deny) status=0 out=[]
FAIL  C6. HOME set by the command (expected deny) status=0 out=[]
FAIL  C7. XDG_CONFIG_HOME set by the command (expected deny) status=0 out=[]
FAIL  C8. -c include.path (expected deny) status=0 out=[]
FAIL  C9. cd to an expanded dir (expected deny) status=0 out=[]
FAIL  C10. -C with an expanded dir (expected deny) status=0 out=[]
FAIL  C11. cd to a dir holding whitespace (expected deny) status=0 out=[]
FAIL  C12. GIT_CONFIG_SYSTEM set by the command (expected deny) status=0 out=[]
RESULT: 221 passed, 12 failed
```

After the fix: `RESULT: 233 passed, 0 failed`. C13-C18 (builtins, a stash read,
a non-stash alias under an override) pass both before and after.

| Mutation | Caught by |
| --- | --- |
| `decide` returns "" for an unread alias (the rule removed) | C1-C12 (`221 passed, 12 failed`) |
| the builtin lookup dropped (every subcommand denied under an override) | C13-C16, C18 |

The critic's per-call note (the snapshot read runs before the prefilter) is
latency, not correctness: ~45 ms for `ls` on the laptop. Not changed here.

### Fix round 3 (486f7db; desktop critic round 18): an alias value built by expansion

`V=stash; git -c alias.p="$V" p` was allowed and, in a scratch repo, created a
stash entry (reproduced by the harness session). The alias-definition check
read `$V`, not `stash`; the env-alias check matched only `--config-env` /
`GIT_CONFIG_KEY_n`; the unread-config rule did not watch arbitrary variables.

Convergence check: kind 1 (pre-existing, not caused by an earlier fix, no
contradiction). It is the fourth spelling of one class, an alias definition
the hook cannot read literally (rounds 2, 4, 16, 18). Swept at the root:
- an alias definition whose value holds an expansion, or a `-c` /
  `--config-env` argument that holds one, is an unread config source, so a
  non-builtin subcommand is denied (UNREAD_CONFIG);
- a value built by COMMAND SUBSTITUTION (backtick or `$(...)`) is denied
  outright, because the substitution also splits the command, so its use
  is not read as git.
The residual (lexical indirection) is now named in the hook header.

New cases against 486f7db's hook:

```
FAIL  V1. -c alias value from a variable (expected deny) status=0 out=[]
FAIL  V2. -c alias value from a backtick (expected deny) status=0 out=[]
FAIL  V3. -c alias value from $(...) (expected deny) status=0 out=[]
FAIL  V4. -c alias value from ${V} (expected deny) status=0 out=[]
FAIL  V5. -c alias value with an expansion after a space (expected deny) status=0 out=[]
FAIL  V6. whole -c key=value from a variable (expected deny) status=0 out=[]
FAIL  V7. --config-env key from a variable (expected deny) status=0 out=[]
FAIL  V8. git config alias from a variable, then used (expected deny) status=0 out=[]
FAIL  V11. -c alias value from $(...) as its own word (expected deny) status=0 out=[]
RESULT: 238 passed, 9 failed
```

(V9, V10 and V12-V14 passed before the fix too; V15-V17 were added after it,
as over-deny boundaries.) After the fix: `RESULT: 250 passed, 0 failed`.

| Mutation | Caught by |
| --- | --- |
| drop the command-substitution outright deny | V2, V11 |
| drop the two UNREAD_CONFIG expansion triggers | V1, V4-V8 |

### Fix round 3, critic round 21 (224f726): git help.autocorrect

`git -c help.autocorrect=immediate stsh pop` runs `git stash pop`: with
help.autocorrect on, git RUNS the closest command for a typo. `stsh` is not
stash, not an alias the hook read, and not plumbing, so the hook allowed it.
Kind 1 (pre-existing), same class as the shell's and zsh's rewrites: a word
rewritten by something other than the hook, here git itself. Fixed:
- setting help.autocorrect in the command is denied (inline `-c`,
  `git config ... help.autocorrect <v>`, `--config-env`); reading or
  unsetting it is not;
- help.autocorrect on in a config the hook reads (global, cwd repo, `-C`/`cd`
  dirs; any value but 0/false/no/off/never/show) makes a subcommand that is
  neither a builtin nor a known alias unknown, and it is denied.
The laptop's config does not set help.autocorrect (`git config --get-all
help.autocorrect` exits 1).

New cases against 224f726's hook:

```
FAIL  AC1. inline -c help.autocorrect=immediate with a typo (expected deny) status=0 out=[]
FAIL  AC2. inline -c help.autocorrect=1 (expected deny) status=0 out=[]
FAIL  AC3. setting help.autocorrect in config (expected deny) status=0 out=[]
FAIL  AC5. autocorrect on in the global config, a typo of stash (expected deny) status=0 out=[]
FAIL  AC8. autocorrect on in the repo config, a typo of stash (expected deny) status=0 out=[]
RESULT: 253 passed, 5 failed
```

After the fix: `RESULT: 258 passed, 0 failed`.

| Mutation | Caught by |
| --- | --- |
| drop the inline-setting deny | AC1-AC3 |
| ignore help.autocorrect read from config | AC5, AC8 |

## 2026-09-26 — DND-560, fleet-lifecycle hook and the drain guard's spawn_denied

- **Domain:** the fleet-worker lifecycle reporter (`ai/hooks/fleet-lifecycle.sh`)
  and the drain guard's new `agent_end spawn_denied` report
  (`ai/hooks/fleet-drain-guard.sh`).
- **Suite run:** `bash ai/hooks/fleet-lifecycle.self-test.sh` and
  `bash ai/hooks/fleet-drain-guard.self-test.sh` (loopback fake server,
  `mktemp -d` state; never prod). Restored with `git checkout --` each time.
- **Fail-first (domain, before `ai/lib/fleet/domain.sh` had the lifecycle
  functions):** `FLEET_SELF_TEST_ONLY=domain bash ai/lib/fleet/test/self-test.sh`
  gave `110 passed, 79 failed`; after, `189 passed, 0 failed`. The large-prompt
  cases failed first too (`ref: a 200 KB prompt still parses` expected
  `mapped DND-77`, got `unmapped`) while the prompt rode jq's argv.

| id | Mutation | Observed failure |
|---|---|---|
| S-DND560-1 | The top-level StopFailure skip (`no agent_id -> exit 0`) removed | `StopFailure without agent_id: not a failure either (nothing logged)` |
| S-DND560-2 | The unmapped notice also prints `permissionDecision: "allow"` | `unmapped: stdout is exactly one PreToolUse additionalContext`, `unmapped: no permissionDecision anywhere in stdout` |
| S-DND560-3 | The `trap 'exit 0' EXIT` removed and the jq-missing refusal exits 1 | `jq missing: exit 0, no stdout` |
| S-DND560-4 | `setsid -f` (detached) replaced by `setsid -w` (waits) | `never adds latency: returned in 3127 ms while the server sleeps 3 s` |
| S-DND560-5 | PostToolUseFailure's class read with `fleet_error_class` instead of the failure text's `error type` | the b1.5, b2.8 and b3.4 replays: `sends exactly the contract body` |
| S-DND560-6 | The unmapped failure-log line not written | `unmapped: one failure-log line`, `... carries Fix:`, `... names the spawn` |
| S-DND560-7 | `--caller-agent-id` dropped from a nested spawn | the b1.3 replay: `sends exactly the contract body` |
| S-DND560-8 | The drain guard's `report_denied` call removed | `the two denies above each sent one report`, `the deny sent exactly one fleet report`, `that report is agent_end spawn_denied …` (6 FAIL) |

---

## 2026-09-26 — DND-799, git-stash-guard: quoted payloads are data

- **Domain:** `ai/hooks/git-stash-guard.sh`. A quoted argument or quoted
  heredoc body that the shell will not run is read in DATA mode. In data,
  every spelling that names the write still denies (a literal stash write,
  stash-ref plumbing, a stash alias, a glob or expanded command word
  followed by a stash verb). Data mode drops only the verb-hiding
  expansion findings (a glob command word with no or expanded arguments,
  an expanded subcommand, an unread config). Data mode fails closed: a text
  is data only when every command word in it is a known non-runner
  (`safe_word()`: a tool that runs no program in any form; git, gh, glab,
  docker, sed, rg, sort and wget are NOT on it — option A, critic round 10)
  and no payload holds a command substitution. Test arguments are data. A shell alias is not
  re-expanded inside its own expansion. The deny text names no tool a
  captain lacks.
- **Suite run:** `sh ai/hooks/git-stash-guard.self-test.sh`, new section Q
  (QA allow, QB alias recursion, QX exec contexts, QD named writes in data,
  QL literal-in-data) and T2.
- **Baseline before the change:** `RESULT: 363 passed, 0 failed`.
- **After (final, critic rounds 1-12, admiral batches 7-8):** `RESULT: 556
  passed, 0 failed` / `VERDICT: PASS`. The per-round tables in this and the
  next few subsections are HISTORICAL, measured on the hook of the round
  they name; the authoritative final table is "Sabotage rows on the
  option-A hook" below (556, on 9e114a6 + the round-12 edits).

### Fail-first (the final self-test against origin/main 81ba7c2's hook)

`RESULT: 525 passed, 31 failed` (on the final suite; the count here was 495
at round 8, before later rounds added cases). Every failure is an allow
case (QA/QB) or the deny-text check T2, e.g.:

```
FAIL  QA8. awk print field (expected allow)
FAIL  QB1. grep -i stash under a self-referential grep alias (expected allow)
FAIL  QA24. DND-853: a test after a cd to an expanded dir (expected allow)
FAIL  QA44. git branch -a piped to a grep -E alternation (expected allow)
FAIL  T2. no deny reason names the Grep tool; the Fix names a script file run with bash
```

Every QX (exec context), QD (named write in data) and QL (literal in data)
case passes on the base hook: each was already denied, and the change
keeps it denied. The QA cases that pass on base are regression guards.

### Sabotage rows (measured 2026-09-26 on the final hook, one mutant copy each)

Rows 3 and 12 are retired: the mechanisms they sabotaged (`git_in_cmd`,
a runner-word list) were deleted in round 6 once the fail-closed checks
reached every case they did (their mutants stayed green).

| id | Mutation | Observed failure |
|---|---|---|
| S-DND799-1 | Every quoted payload and heredoc read as data | O103c, QX1, QX2, QX3, QX4, QX5, QX6, QX7, QX8, QX9, QX10, QX11, QX12, QX13, QX14, QX15, QX16, QX17, QX18, QX19, QX20, QX21, QX22, QX23, QX24, QX25, QX26, QX27, QX28, QX29, QX30, QX31, QX35, QX36, QX37, QX38, QX39, QX40, QX41, QX42, QX43, QX44, QX45, QX46, QX47, QX48, QX49, QX50, QX52, QX53, QX54, QX55, QX56, QX57, QX58, QX59, QX60, QX61, QX62, QX63, QX64, QX65, QX66, QX67, QX68, QX69, QX70, QX71, QX72, QX73, QX74, QX75, QX76, QX77, QX78, QX79, QX80, QX81, QX82, QX83, QX84 — `455 passed, 81 failed` |
| S-DND799-2 | `exec_text()` off (every text data) | QX1, QX2, QX3, QX4, QX5, QX6, QX7, QX8, QX9, QX10, QX11, QX12, QX13, QX14, QX15, QX16, QX17, QX18, QX19, QX20, QX21, QX22, QX23, QX24, QX25, QX26, QX31, QX36, QX37, QX38, QX39, QX40, QX41, QX42, QX43, QX44, QX45, QX46, QX47, QX48, QX49, QX50, QX52, QX53, QX54, QX55, QX56, QX57, QX58, QX59, QX60, QX61, QX62, QX63, QX64, QX65, QX66, QX67, QX68, QX69, QX70, QX71, QX72, QX73, QX74, QX75, QX76, QX77, QX78, QX79, QX80 — `465 passed, 71 failed` |
| S-DND799-4 | A payload holding `$(`, a backtick or `${(` no longer exec | O103c, QX29, QX30, QX35, QX81, QX84 — `530 passed, 6 failed` |
| S-DND799-5 | An unquoted or unterminated heredoc read as data | QX27, QX28 — `534 passed, 2 failed` |
| S-DND799-6 | `<<` after a word-leading `#` or inside `((` taken as a heredoc | QX32, QX33 — `534 passed, 2 failed` |
| S-DND799-7 | Alias self-expansion guard (`AEXP`) removed | QB1 — `535 passed, 1 failed` |
| S-DND799-8 | Test arguments no longer data (`dm = data`) | QA24, QA25 — `534 passed, 2 failed` |
| S-DND799-9 | Data drops every finding (`weak()` true for all, glob-head off in data) | QD1, QD2, QD3, QD6, QD7, QD8, QD9, QL1, QL2, QL3, QL5, QL6 — `524 passed, 12 failed` |
| S-DND799-10 | Unknown command words, git, gh, glab and docker all treated as safe (critic round 1) | QX1, QX2, QX3, QX4, QX5, QX6, QX7, QX8, QX9, QX10, QX11, QX12, QX13, QX14, QX15, QX16, QX17, QX18, QX19, QX20, QX21, QX22, QX23, QX24, QX25, QX26, QX31, QX36, QX37, QX38, QX39, QX40, QX41, QX42, QX43, QX44, QX45, QX46, QX47, QX48, QX49, QX50, QX52, QX53, QX54, QX55, QX56, QX62, QX63, QX64, QX65, QX66, QX67, QX68, QX69, QX70, QX71, QX72, QX73, QX74, QX75, QX76 — `474 passed, 62 failed` |
| S-DND799-11 | A payload nested in data no longer data | QA2, QA20, QA60, QA62 — `532 passed, 4 failed` |
| S-DND799-13 | `sed_runs()` never true (critic round 2) | QX57, QX58, QX59, QX60, QX61 — `531 passed, 5 failed` |
| S-DND799-14 | The round-2 sweep reverted (sed, ag, ack, local, declare, typeset, readonly, shift back in `safe_word()`) | QX57, QX58, QX59, QX60, QX61, QX62, QX63, QX64 — `528 passed, 8 failed` |
| S-DND799-15 | Data drops named writes again (the round-2 data mode; critic round 3) | QD1, QD2, QD3, QD6, QD7, QD8, QD9 — `529 passed, 7 failed` |
| S-DND799-16 | Data mode judges a glob command word as exec does (no false-positive relief) | QA2, QA3, QA4, QA5, QA6, QA7, QA8, QA10, QA11, QA12, QA13, QA14, QA15, QA16, QA17, QA18, QA20, QA21, QA22, QA23, QA29, QB2, QB3, QB5, QA32, QA30, QA31, QA33, QA36, QA42, QA43, QA44, QA45, QA47, QA48, QA49, QA50, QA51, QA52, QA53, QA54, QA55, QA56, QA57, QA58, QA60, QA62, QA63, QA64 — `487 passed, 49 failed` |
| S-DND799-17 | `git_read()` always true | QX19, QX20, QX26, QX48, QX53, QX54, QX65, QX66, QX67, QX69, QX70, QX72, QX73, QX74, QX75 — `521 passed, 15 failed` |
| S-DND799-18 | `gh_read()` always true (critic round 4) | QX50, QX68, QX71 — `533 passed, 3 failed` |
| S-DND799-19 | `git tag` judged by the branch listing flags again (critic round 4) | QX69, QX70 — `534 passed, 2 failed` |
| S-DND799-20 | git options skipped unchecked again (critic round 5) | QX53, QX72, QX73, QX74, QX75 — `531 passed, 5 failed` |
| S-DND799-21 | `docker_read()` always true (critic round 5) | QX76 — `535 passed, 1 failed` |
| S-DND799-22 | `prog_opt()` off: rg --pre, sort --compress-program, wget -e (critic round 6) | QX77, QX78, QX79, QX80 — `532 passed, 4 failed` |
| S-DND799-24 | `long_pre()` matches an option only by exact spelling, not getopt prefix (critic round 8) | QX86, QX87, QX88, QX89, QX90, QX91, QX92 — `544 passed, 7 failed` |
| S-DND799-25 | `short_has()` never fires (no short-bundle split; critic round 8) | QX80, QX85, QX93 — `548 passed, 3 failed` |

### Critic rounds (each a kind-1 finding; convergence check run from round 2)

- **Round 1 (e214145), closed runner list.** A program that runs a string
  but was not listed (at, batch, sg -c, tar --to-command, sched,
  watchexec, entr -s, npx -c, nodemon --exec) had its payload read as
  data. Fixed at the class: data requires every command word to be a
  KNOWN non-runner (row 10).
- **Round 2 (72c9304), sed runs a string.** Swept the list for words that
  can run a string: sed goes through `sed_runs()`; ack, ag, local,
  declare, typeset and readonly left it (rows 13, 14).
- **Round 3 (2fc1d83), evaluators outside every list** (a GIT_SSH_COMMAND
  export, a subscript a builtin re-evaluates). The third instance of one
  class: "data mode trusts the lists to prove nothing evaluates the
  string". Fixed at the root: data keeps every spelling that names the
  write (rows 9, 15). QX payloads were respelled to hide the verb
  (`true; .../git-st*sh`, an implicit push) so the exec checks stay
  load-bearing.
- **Round 4 (fe719f0), list entries too coarse.** `gh pr checkout`, `git
  tag -a`/`-v`. gh/glab are judged by a read (command, subcommand) pair;
  tag lists only bare or with -l/--list (rows 18, 19).
- **Round 5 (5b8edbe), git options unchecked.** `git -c
  core.fsmonitor=./p.sh status`. git options are allowlisted; docker is
  judged by subcommand (rows 20, 21). Deleting the git/gh/docker read
  lists was priced and rejected: it puts back the batch-7 false positives
  (`git branch -a | grep -E`, `gh pr view -q`, `docker ps --format`).
- **Round 6 (a1b4a41), program options on listed tools** (rg --pre, sort
  --compress-program, wget -e). Swept the list against each tool's --help
  and man page for program-running options: `prog_opt()` (row 22). Also
  measured on zsh: `read`, `shift`, `return` and `[[ -eq ]]` run a `$(...)`
  inside a quoted subscript, so a payload holding `$(`, a backtick or `${(`
  is exec (row 4; replaces the double-quote-only XQ flag), and read and
  shift left the list. The mutation sweep then showed `git_in_cmd` and the
  runner-word list could no longer fire on their own, so both were
  deleted rather than patched.
- **Round 8, program options read by exact spelling.**
  `prog_opt()` and `git_read()` matched a program-naming option by its full
  name, so getopt_long / git parse-options abbreviations and bundled short
  options slipped past: `wget -qe use_askpass=./p.sh`, `wget --use-ask=`,
  `sort --compress=`, `git ls-remote --upload=` all ran a script written as
  data in the same call. Kind 1, the same "list reads a runner wrong" class
  as rounds 1-6, reached through spelling rather than a missing entry.
  Confirmed fail-first against the pre-round-8 hook (d16cf71): all seven
  probe forms ALLOW. Fixed at the class: `long_pre()` matches any getopt
  prefix of a program option (every prefix a user can type is a prefix of
  the full name, so it is complete; a prefix shared with a benign option
  only over-denies), and `short_has()` scans the whole short bundle (a
  value bundled after a value-taking flag only over-denies). Path-taking
  git options (--upload-pack, --receive-pack, --exec, -O) are prefix-
  matched; the config toggles (--ext-diff, --textconv, --show-signature,
  --config) take no path, so they stay exact, which also avoids over-denying
  `git diff --text` against `--textconv`. QX85-QX93 deny; QA65-QA70 (--text,
  --exclude, --recurse-submodules, wget -O report, distinct prefix-sharing
  options) stay allowed.
- **Round 9, a repo hook written in the call.** The critic found that a
  hook file written as data and later fired by a git read falls in the
  data-mode residual, while the header named only config files. Kind 1,
  the same evaluator class as the accepted residual ("a file written in
  this call and later executed by git"). The harness session ruled it a
  documented residual (2026-09-27, option A): the header now names both
  config-file programs and repo hook files, and links DND-775 as the
  enforcement that closes the class below the text (DND-905 is the
  text-layer fallback). No code or test change: an accepted residual is
  not caught by design, and a deny case would claim coverage that does
  not exist.
- **Round 10, per-tool lists deleted (admiral decision, option A).** Round
  10 found two more cases in the class rounds 1, 2, 4, 5, 6 and 8 walked:
  a per-tool read list reading a runner wrong. Seven of ten rounds were
  that class. The admiral chose to delete the mechanism rather than patch
  it: a text is data only when every command word is a PURE DATA tool
  (`safe_word()`); git, gh, glab, docker, sed, rg, sort and wget make the
  text exec whatever their subcommand or options. `git_read()`,
  `gh_read()`, `docker_read()`, `sed_runs()`, `prog_opt()`, `long_pre()`
  and `short_has()` are gone. This is strictly stricter: it only denies
  more. 25 allow cases (git/gh/docker/sed/rg/sort/wget pipelines) now
  deny; they are kept, flipped, in a "QA-A: denied under option A; relief
  via DND-775" block. Every deny stays green. Rows 10, 13, 14, 17-22, 24
  and 25 above sabotaged deleted code and are retired.

### Sabotage rows on the option-A hook (final, measured on 9e114a6 + the
round-12 edits; supersede every table above)

Self-test `RESULT: 556 passed, 0 failed`. One mutant copy each. Rows whose
mechanisms option A deleted (the old A-3/10/12-14/17-25) are retired with
that code.

| id | Mutation | Observed failure |
|---|---|---|
| A-1 | Every quoted payload and heredoc read as data | O103c, QX1, QX2, QX3, QX4, QX5, QX6, QX7, QX8, QX9, QX10, QX11, QX12, QX13, QX14, QX15,... — `437 passed, 119 failed` |
| A-2 | `exec_text()` off | QX1, QX2, QX3, QX4, QX5, QX6, QX7, QX8, QX9, QX10, QX11, QX12, QX13, QX14, QX15, QX16, ... — `447 passed, 109 failed` |
| A-4 | A payload holding a command substitution no longer exec | O103c, QX29, QX30, QX35, QX81, QX84 — `550 passed, 6 failed` |
| A-5 | An unquoted or unterminated heredoc read as data | QX27, QX28 — `554 passed, 2 failed` |
| A-6 | `<<` after a word-leading `#` or inside `((` taken as a heredoc | QX32, QX33 — `554 passed, 2 failed` |
| A-7 | Alias self-expansion guard (`AEXP`) removed | QB1 — `555 passed, 1 failed` |
| A-8 | Test arguments no longer data | QA24, QA25 — `554 passed, 2 failed` |
| A-9 | Data drops every finding (`weak()` true for all, glob-head off in data) | QD6, QD7, QD8, QD9, QL1, QL2, QL3, QL5, QL6 — `547 passed, 9 failed` |
| A-11 | A payload nested in data no longer data | QA20, QA60, QA62 — `553 passed, 3 failed` |
| A-15 | Data drops named writes again | QD6, QD7, QD8, QD9 — `552 passed, 4 failed` |
| A-16 | Data judges a glob command word as exec does (no false-positive relief) | QA3, QA4, QA5, QA8, QA10, QA12, QA15, QA16, QA17, QA18, QA20, QA21, QA22, QA23, QA29, Q... — `529 passed, 27 failed` |
| A-26 | Pure-data list gains sh, bash, zsh | QX1, QX2, QX12, QX13, QX21, QX22, QX31, QX97 — `548 passed, 8 failed` |
| A-27 | Pure-data list gains git, gh, docker | QX19, QX20, QX26, QX48, QX50, QX53, QX54, QX55, QX56, QX65, QX66, QX67, QX68, QX69, QX7... — `515 passed, 41 failed` |
| A-28 | Pure-data list gains sed, rg, sort, wget | QX57, QX58, QX59, QX60, QX61, QX77, QX78, QX79, QX80, QX85, QX86, QX87, QX88, QX89, QX9... — `535 passed, 21 failed` |
| A-29 | Pure-data list gains at, sg, tar, watchexec | QX36, QX37, QX39, QX40, QX42 — `551 passed, 5 failed` |
| A-30 | The basename-strip is restored, so a path-qualified word reduces to its basename (critic round 11) | QX95, QX96 — `554 passed, 2 failed` |
| A-31 | `elif` dropped from cmd_prefix, so a runner after it is not in command position (critic round 12) | QX97 — `555 passed, 1 failed` |

- **Round 11, path-qualified word + stale text.** The critic found that
  `exec_text()` stripped a command word to its basename before the
  pure-data check, so a planted `./jq` or `d/cat` read as a data tool.
  Fix: a word holding `/` is a path (a script or a binary the guard will
  not vouch for), so it is exec whatever its basename; the basename strip
  is gone (row A-30, QX95/QX96). The critic also named three stale-text
  spots left by option A (the SABOTAGE Domain bullet, the exec_text
  comment, and the QA-A labels that still said "stays allowed" while
  expecting deny); all are corrected. Its guardrail note -- that the
  interpreter-string residual weakens vs base and needs a recorded OWNER
  decision, not a session ruling -- is escalated to the owner (the residual
  predates DND-799; option A only narrowed it).
- **Round 13, owner decision recorded.** The critic's last finding (a
  guardrail finding: the data-mode residual reduces what the guard catches
  and needs a recorded owner decision, not a session ruling) is answered
  by Cody's recorded acceptance (2026-09-27 ~07:20Z, "approved", relayed
  from the laptop coordinator session), quoted verbatim in the header
  RESIDUAL. DND-775 closes the class below the text; DND-905 is the
  fallback if its activation slips past 2026-10-04. No code or test change.
