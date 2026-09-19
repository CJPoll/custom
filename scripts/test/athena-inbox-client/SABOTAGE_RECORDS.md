# Sabotage records — `athena-inbox-client` supervision (DND-189)

A test is not finished until you have watched it fail: delete the thing it
exists to prove, run it, confirm the failure names the right criterion, and
write the failure string down next to the claim it supports. Root ADR 002 makes
that mandatory per **subproject**, in deliberately stack-neutral vocabulary, so
a shell suite is in scope exactly as an Elixir one is.

## How to use this

Pick a row. Re-apply the mutation. The named case should fail with the named
string. If it still passes, the check it protects has stopped being
load-bearing and the row is now a bug report.

Rows recording a **measured zero** are the important ones — they mark a claim
no mutation reddens. This run produced one (S23), and it is written up below
rather than quietly dropped.

Every mutation was applied by an exact-substring replace that asserted the
anchor occurs **exactly once** before writing (a sabotage applied by substring
lands wherever the substring first occurs; the wrong site gives a green run
that reads as "the test is dead"), and restored with `cp` from a byte-for-byte
backup taken before the run — never `mv`, whose preserved mtime has burned this
repo before, and never `git checkout --`, which cannot restore a file that is
not yet committed.

---

## 2026-09-18 — building the supervisor and its installer

- **Domain:** Athena inbox client supervision on OpenRC (QA plan §3, I-8 … I-11)
- **Date:** 2026-09-18
- **Code under test:** `scripts/athena-inbox-client-run.sh`,
  `scripts/setup-athena-inbox-client`
- **Suite run:** `bash scripts/test/athena-inbox-client/self-test.sh`
  (equivalently `scripts/setup-athena-inbox-client --self-test`). No network —
  the client is a stub script; no live crontab — `crontab(1)` is a PATH shim
  over a tmpfile. ~25s.
- **Baseline:** `VERDICT: PASS (32 cases)`
- **Runner:** 22 mutations, one at a time, full suite after each.

### What the suite proves

| # | Mutation | Cases reddened | Failure string(s) |
|---|---|---|---|
| S1 | runner: the exit-2 branch `if [ "$rc" -eq 2 ]` → `if false` (the partial-write stop is removed) | 7 | `FAIL  exit 2 stops the supervisor after exactly one client run` / `FAIL  exit 2 writes athena-inbox-client.stopped naming the partial write` / `FAIL  the stop marker tells the operator to delete the trailing fragment first` / `FAIL  a later invocation refuses to start while the stop marker exists` / `FAIL  the refusal is logged with a Fix: line` / `FAIL  the refusal notice is rate-limited to once per marker, not once per tick` / `FAIL  removing the stop marker lets the supervisor start again` |
| S2 | runner: the stop-marker preflight `if [ -e "$STOPFILE" ]` → `if false` (the stop lasts only as long as the process) | 3 | `FAIL  a later invocation refuses to start while the stop marker exists` / `FAIL  the refusal notice is rate-limited…` / `FAIL  removing the stop marker lets the supervisor start again` |
| S3 | runner: `if ! flock -n 9` → `if false` (the single-instance guarantee is gone) | 3 | `FAIL  a second invocation exits 0 without starting a duplicate client` / `FAIL  the pidfile records the supervisor that holds the lock` / `FAIL  SIGTERM stops the supervisor without relaunching the client` |
| S4 | runner: the cap `[ "$backoff" -gt "$MAX_BACKOFF" ] && backoff="$MAX_BACKOFF"` → `true` | 1 | `FAIL  the backoff is capped at MAX_BACKOFF and never exceeds it` |
| S5 | runner: the reset `if [ "$ran" -ge "$BACKOFF_RESET" ]` → `if false` | 1 | `FAIL  a run lasting at least BACKOFF_RESET resets the backoff to the minimum` |
| S6 | runner: `if [ "$rc" -eq 0 ]` → `if false` (a clean shutdown is read as a crash) | 2 | `FAIL  a clean exit 0 stops the supervisor instead of relaunching` / `FAIL  removing the stop marker lets the supervisor start again` |
| S7 | runner: the TERM trap → `trap reap_child TERM`, i.e. **the pre-fix form that reaps the child and falls back into the supervise loop** | 1 | `FAIL  SIGTERM stops the supervisor without relaunching the client` |
| S8 | runner: `reap_child()` body → `:` (the client can outlive its supervisor) | 1 | `FAIL  the client is reaped with the supervisor, never orphaned` |
| S9 | runner: the launcher preflight `[ -x "$LAUNCHER" ] \|\|` → `true \|\|` | 1 | `FAIL  the runner refuses a missing launcher with exit 2 and a Fix: line` — and the suite then **timed out** (rc=124), because the mutated runner supervises a nonexistent binary forever. The hang is itself the point of the check. |
| S10 | runner: the notice rate limit `if [ ! -e "$STOP_NOTICE" ] \|\| [ "$STOPFILE" -nt "$STOP_NOTICE" ]` → `if true` | 1 | `FAIL  the refusal notice is rate-limited to once per marker, not once per tick` |
| S11 | runner: `usage()` → `:` (the awk header extractor is dead) | 1 | `FAIL  runner --help prints the header block` |
| S12 | installer: `without_our_entries` no longer filters (`grep -vF -- "$RUNNER"` dropped) — entries are appended blindly | 4 | `FAIL  a second install is a byte-identical no-op (no duplicated entries)` / `FAIL  each entry appears exactly once after two installs` / `FAIL  --remove deletes both of our entries and keeps the unrelated one` / `FAIL  --check exits 1 with MISSING and a Fix: line when the entries are gone` |
| S13 | installer: `kept="$(without_our_entries "$current")"` → `kept=""` (unrelated entries are discarded) | 2 | `FAIL  install adds @reboot and */5 and preserves the unrelated entry` / `FAIL  --remove deletes both of our entries and keeps the unrelated one` |
| S14 | installer: the `--check` verdict `[ "$have_reboot" -eq 1 ] && [ "$have_relaunch" -eq 1 ]` → `true` (always OK) | 2 | `FAIL  --check exits 1 with MISSING and a Fix: line when the entries are gone` / `FAIL  --check handles an absent crontab as MISSING, with a Fix: line` |
| S15 | installer: `--dry-run) DRY_RUN=1` → `DRY_RUN=0` (the preview writes for real) | 2 | `FAIL  --dry-run previews and changes nothing` / `FAIL  --dry-run before --install is accepted (options are order-independent)` |
| S16 | installer: the launcher preflight `[ -x "$LAUNCHER" ] \|\|` → `true \|\|` | 1 | `FAIL  install refuses a missing client launcher with exit 2 and a Fix: line` |
| S17 | installer: `--install)` → `--install\|*)` (an unrecognised flag silently installs) | 8 | `FAIL  an unknown installer flag exits 1 with a Fix: line` / `FAIL  installer --help prints the header block…` / `FAIL  --check reports OK and exits 0…` / `FAIL  --dry-run previews and changes nothing` / `FAIL  --dry-run before --install is accepted…` / `FAIL  --remove deletes both of our entries…` / `FAIL  --check exits 1 with MISSING…` / `FAIL  --check handles an absent crontab…` |
| S18 | installer: `usage()` → `:` | 1 | `FAIL  installer --help prints the header block (the awk extractor works)` |
| S19 | installer: the `--check` `Fix:` clause replaced with a bare "(entries are absent)" | 2 | `FAIL  --check exits 1 with MISSING and a Fix: line when the entries are gone` / `FAIL  --check handles an absent crontab as MISSING, with a Fix: line` |
| S20 | runner: the restart bound `if [ "$MAX_RESTARTS" -gt 0 ] && [ "$restarts" -ge "$MAX_RESTARTS" ]` → `if true` (gives up after the first crash) | 4 | `FAIL  exit 1 relaunches the client until the restart bound is reached` / `FAIL  the backoff grows exponentially (1s then 2s)` / `FAIL  the backoff is capped…` / `FAIL  a run lasting at least BACKOFF_RESET resets…` |
| S21 | runner: `backoff=$(( backoff * 2 ))` → `* 1` (a fixed short retry wearing a supervisor's clothes) | 2 | `FAIL  the backoff grows exponentially (1s then 2s)` / `FAIL  the backoff is capped at MAX_BACKOFF and never exceeds it` |
| S22 | runner: the locked-out branch made chatty (`echo "another supervisor holds the lock" >&2`) | 1 | `FAIL  the locked-out invocation prints nothing (cron mails any output)` |

### Two zeros found, and closed rather than recorded

The first pass measured **two** zeros. Both turned out to be dead assertions in
the suite rather than untestable claims, so both were repaired and re-measured:

- **S7** (`SIGTERM stops the supervisor without relaunching the client`)
  reddened nothing because the flock case ran with `MAX_RESTARTS=1`: the
  supervisor stopped after reaping its client no matter how the TERM handler
  behaved, so a handler that reaps-and-relaunches passed. Raising the bound to
  5 gives a broken handler room to relaunch and be counted. **Now reddens.**
- **S10** (`the refusal notice is rate-limited…`) reddened nothing because the
  case invoked the supervisor only twice, giving exactly one refusal
  opportunity — a broken rate limiter counts the same as a working one. A third
  invocation was added. **Now reddens.**

Both are worth noting beyond this file: each is the same species of mistake, a
bound in the *test* that masks the behaviour the test claims to measure, and
neither was visible from a green run.

### Measured zero

| # | Claim | Status |
|---|---|---|
| S23 | `--check does not modify the crontab` | **Measured zero — no mutation reddens it.** |

`--check` reaches no write path at all: it calls `read_crontab` and returns, so
there is nothing to delete that would make it start writing. Every mutation
that could redden this case would have to *add* a `put_crontab` call, which is
not sabotage of an existing guarantee but authorship of a new defect.

The case is kept deliberately. It is a **regression guard on a property the
callers depend on**, not a test of current behaviour: `--check` is documented as
read-only and safe for an agent or CI to run unattended, and the whole point of
writing that down is that a future edit must not quietly make it false. Recorded
here as a zero so nobody later reads its green as evidence of anything.

### Defect this pass found in the code under test

S7's mutation is not hypothetical — it is the **original** salvaged code. The
supervisor shipped with a single `trap … EXIT INT TERM` that killed the child
and returned, leaving `wait` interrupted with status 143, which the loop read as
"the client crashed" and relaunched. The documented recovery ("kill the pid in
the pidfile") would therefore have restarted the very client the operator had
just stopped, with the pidfile still looking correct. Fixed by splitting the
handlers so INT/TERM reap **and exit**; case 29 and row S7 hold it.
