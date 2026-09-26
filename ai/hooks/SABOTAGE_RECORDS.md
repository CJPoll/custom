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
- **Baseline:** `RESULT: 202 passed, 0 failed` / `VERDICT: PASS` (79 at the first commit; critic round 1 added I27-I30 and A14; round 2 A15-A18; round 3 I31-I39 and OK11; self-review A19-A21; round 4 A22-A27; bounds A28, N1; round 6 I40-I58 and S1-S8; round 7 I59-I65 and F7; fix round W2a-W2c, R7-R41, I66-I77 and Z1-Z8).

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
