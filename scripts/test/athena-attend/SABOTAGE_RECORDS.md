# Sabotage records — athena-attend

Each case in `self-test.sh` protects a decision that is invisible from the
outside in production. This file records, per case, the mutation to the runner
(`scripts/athena-attend-run.sh`) or installer (`scripts/setup-athena-attend`)
that must turn it red — the evidence the assertion bites.

## Runner

- **new>0 triggers exactly one handler / new=0 triggers none.** Mutate
  `handle_burst` to run the handler before (or without) `resolve_new_count`:
  the quiet case then makes a model call. Mutate it to `break` after the count
  without handling: the new-mail case makes zero. Either reddens.
- **wait 75 re-checks (missed-bell closure).** Make the `case "$wrc"` treat 75
  as "all clear" (skip the `handle_burst` on 75): case 3 goes to zero handler
  calls though mail is waiting.
- **inbox-wait exit 2 = stop.** Make exit 2 fall through to the check instead of
  `write_stop`: no `attend.stopped`, the run does not exit 75, and a second run
  does not refuse.
- **blocked vs failed vs handled.** Remove the `[ ! -e "$RECEIPT" ]` branch so a
  no-receipt exit-0 reads as handled: case 6 stops exiting 69 and the blocked
  streak is lost. Drop the `rc -ne 0 -> failed` branch: case 7 stops counting a
  failure.
- **wedge escalation.** Never write `attend.wedged` / never exit 75 on the Nth
  failure: case 8 loops forever (bounded here by MAX_CYCLES) instead of turning
  a persistent failure into a loud cron exit.
- **epoch resume / rotation.** Always mint a fresh uuid (drop the `resume`
  branch of `select_epoch`): case 9 shows two `--session-id`s. Never rotate
  (drop the wakes/bytes/age checks): cases 10/11 keep `--resume`-ing one growing
  session — the unbounded-burn regression. Rotate on `n/a` bytes: case 12 breaks.
- **resume-failure retry.** Remove the `force_fresh` write on a failed resume:
  case 13's wake 3 resumes the dead session instead of starting fresh.
- **brief stability.** Interpolate anything per-wake into `$BRIEF` (a count, a
  timestamp): case 14 sees the two briefs differ — the cache-prefix regression.
- **subagent-marker leak.** Export `CLAUDE_AGENT_ID` (or set
  `CLAUDE_CODE_SESSION_ATTENDED`) around the handler: case 15 sees it SET, which
  in production is exactly what makes `inbox-wait`/`read-inbox` refuse the ack.
- **could-not-count is not zero.** Make `resolve_new_count` echo 0 on a
  non-document instead of returning non-zero: case 16 silently decides no mail
  is waiting (the silent-dark class) — it would make a handler call of 0 and
  write no "could not count" line.
- **--help / --dry-run side effects.** Move the `--help` branch below `mkdir
  "$STATE_DIR"`: case 17 finds a log written. Make `--dry-run` fall through to
  arming: case 18 makes a handler call.
- **single instance / fd 9.** Drop `9>&-` from `run_child` (or the handler): the
  orphan case (21) hangs, because a SIGKILLed supervisor's orphaned waiter keeps
  the flock and every later invocation exits 0 in silence — the exact bug this
  discipline exists to prevent, and the one this suite caught during authoring.
  Drop the `flock -n 9` guard: case 19 starts a second attendant.
- **SIGTERM stops the supervisor.** Make the TERM trap `return` instead of
  `exit 143`: case 20 sees a non-143 exit (and, in production, a "stop" that
  relaunches).

## Installer

- **idempotent, per-project, preserves others.** Append instead of
  filter-then-append: case 22 ends with 4+ matching lines on re-install. Match
  on the runner path only (drop `--project <dir>` from `$MATCH`): case 22/23
  remove another project's attendant entry.
- **refusals.** Skip the `[ -x "$RUNNER" ]` / git / inbox-wait preflight checks:
  cases 25/26/27 install a doomed entry (a vanishing worktree path, a non-repo,
  or a project with no channels — the silent-dark class at install time).
- **--check honesty.** Make `--check` exit 0 when entries are missing: case 24
  reports a durable schedule that is not there.

## Non-hermetic smoke (run once by hand; the suite cannot prove it)

No hermetic test can exercise a real `claude -p --resume`. Run once and record
the result here:

1. `scripts/athena-attend-run.sh --project ~/dev/walt_ui --dry-run` — the real
   doorbells resolve (`inbox-wait --dry-run` lists them) and the printed handler
   command line is well formed.
2. `scripts/athena-attend-run.sh --project ~/dev/walt_ui --once` with a real DM
   sent to the bot first: expect a reply in that DM, a line in
   `~/.local/state/athena-attend/walt_ui/ledger.log`, and a `wakes.log` line
   carrying a real `cost_usd` and `outcome=handled`.
3. A second `--once` with a follow-up in the same thread: expect the wakes.log
   line to carry `mode=resume` (the epoch resumed) and the reply to reflect the
   thread's earlier context.
