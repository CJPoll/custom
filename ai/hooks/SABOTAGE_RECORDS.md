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
