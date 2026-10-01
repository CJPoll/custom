# Athena Telemetry — contract

**Kind: living normative document.** Amended in place, per `~/dev/custom/CLAUDE.md`
→ *Documentation conventions*.

**Status:** normative. **Adopted:** 2026-10-01 (DND-1473). This contract says
what an on-system telemetry event is, where it is stored, how it is written
and read, and how an event is added. It is the one home of these rules. Other
documents cite it by section name and do not restate it.

The implementation:
- `ai/lib/athena_telemetry.rb`: the one writer and reader (module
  `AthenaTelemetry`). Ruby emitters require it and call `AthenaTelemetry.emit`
  in-process.
- `ai/bin/telemetry-emit`: the CLI over the same library, for shell emitters,
  pruning and summaries (*The CLI*).
- `ai/telemetry/events.json`: the event registry (*The registry*).
- Tests: `ai/test/telemetry/self-test.sh`, `ai/test/telemetry/telemetry_test.rb`,
  and the shell binding's `ai/test/telemetry-shell/self-test.sh`.

**Provenance.** The design record is `ai/docs/lead-time-improver.md` →
*Telemetry*, a dated record. Where it disagrees with this contract, **this
contract wins**.

**Scope.** On-system only (owner, Cody, 2026-10-01: "the ability to add
instrumentation/telemetry (on-system only)"). Telemetry feeds the lead-time
improver's phase ledger. It is never sent anywhere (*No network*).

**One schema.** This is the only on-system telemetry event schema. A tool's
own operating ledger, such as test-slot's pool `events.jsonl`, is not
telemetry. The ad-hoc `{ts,tool,ok}` sink at
`ai-artifacts/telemetry/events.jsonl` was retired by DND-1487 with its one
reader (`harness-metrics`' `runtime_events`, which fed a `harness-signals`
signal that could not fire). Its writer, `ai/hooks/harness-event.sh`, is now a
no-op kept only while a live settings file still wires it. A leftover file at
that path is stale. A new emitter registers an event here (*Adding an event*);
it never writes a store of its own.

## The event line

Each line is one JSON object, keys in this order:

| Key | Value |
|---|---|
| `v` | `1`, the schema version |
| `event` | a name registered in `ai/telemetry/events.json` |
| `at` | the event's START, UTC, millisecond precision: `2026-10-01T05:26:35.123Z` |
| `duration_s` | seconds as a number, or `null` for a point event |
| `unit` | the unit of work (*Unit of work*), or `null` |
| `unit_source` | `explicit`, `env`, `branch`, `branch-name` or `none` |
| `repo` | the basename of the git common dir's parent (`custom` in every checkout of `~/dev/custom`), or `null` |
| `head` | 40 lower-case hex, or `null` |
| `host` | the short hostname |
| `pid` | the writing process's pid (for the CLI, the `telemetry-emit` process) |
| `attrs` | an object of registered attrs (*The registry*) |
| `attrs_truncated` | present, `true`, only when attrs were cut to fit (*Append*) |

`null` means "not known". It is never written as `0` or `""`.

## Unit of work

The writer resolves the unit once, in this order:

1. an explicit unit: `unit:` in Ruby, `--unit` on the CLI. Source `explicit`.
2. `ATHENA_UNIT`, if set and non-empty. Source `env`.
3. the ticket the current branch names. Source `branch`.
4. the branch name itself. Source `branch-name`.
5. `null`, with source `none`: a detached HEAD, or not in a repo.

In steps 3 and 4, a caller may name the branch instead of the checked-out
one: `unit_branch:` in Ruby, `--unit-branch` on the CLI (DND-1475). It is for
a tool that knows the work's branch but runs elsewhere: `locked-merge` names
the PR's head branch, and the `gh-athena` push names the local branch at the
pushed commit. Empty is no hint.

The branch, `repo` and `head` come from one `git rev-parse`. Outside a repo
they are `null` with nothing counted. Any other git failure (no git, a git
older than 2.31, an unborn branch) leaves them `null` too, and counts
`git_context_unavailable`, so it never reads the same as "not in a repo".
The call is bounded at one second (DND-1494), under the shell binding's
`timeout -k 1 2`. A git that has not answered by then (an index lock, a git
blocked on a pipe or the network) has its process group sent TERM, then KILL;
the three are `null` and `git_context_timeout` is counted, so the unit reads
`none` unless an explicit or `ATHENA_UNIT` unit applies. The emit still
writes its line and returns.

A git that ignores TERM is sent KILL half a second after it. That grace is
shorter than the outer timeout's one second from TERM to KILL, so under the
CLI the git's process group is dead before Ruby can be (DND-1506). If the
outer TERM reaches Ruby first, the emit is lost uncounted, but Ruby still
kills that group on its way out.

One hang the bound cannot end: a git stuck in the kernel (uninterruptible
sleep, e.g. a stuck filesystem) survives KILL, and the emit waits for the
kernel to release it.

**Later (2026-10-01, DND-1506):** this listed two hangs the bound cannot
end. The second was a git that ignores TERM: killed two seconds after it,
so under the CLI the outer `timeout` killed Ruby first and left that git
running in its own process group. Superseded by the half-second grace
above, which is shorter than the outer one-second gap, so that git is now
killed.

The writer runs no other subprocess. The ticket-ref parser load and the
overlay read below are in-process reads of regular files (the overlay reader
refuses anything that is not a regular file), so neither can block on another
process. A filesystem stuck in the kernel can still stall them, as it stalls
the store's own append; in-process I/O has no bound that kills it.

Step 3 uses the ticket-ref parser `ai/bin/lead-time` uses,
`ai/lib/ticket_ref.rb` (`TicketRef.ticket_ref`): one parser, not two. That
library defines only the `TicketRef` module, so loading it never reaches the
caller's namespace.

**Later (2026-10-01, DND-1488):** the writer loaded `ai/bin/lead-time`
itself, wrapped with `load(path, Module.new)`. Superseded by the shared
library: every emitting process also loaded lead-time's Notion and forge
classes, and a CLI file is the wrong home for a shared parser.

A DND ref always counts. A branch naming any other ticket-shaped ref
also reads the private overlay's work-ticket prefix, as `lead-time` does, so a
work branch resolves on a machine with the overlay. A word shaped like a ticket
(`fix-utf-8`) is not one, and the branch name is the unit.

A unit is a label (*The registry* → label). One that is not is dropped,
counted as `unit_invalid`, and the next step applies. If the parser cannot
load, or raises, the branch name is the unit and `unit_parser_unavailable` is
counted, so the fallback is visible. If a present overlay cannot give the work
prefix, a work branch's name is the unit and `unit_overlay_unavailable` is
counted. An absent overlay is that machine's state and is not counted.

## The registry

`ai/telemetry/events.json` lists every event and its allowed attrs:

```json
{"v":1,"events":{"<name>":{"description":"<when, what at/duration/head mean, the emitter>",
                           "attrs":{"<attr>":"<type>"}}}}
```

- **Names.** An event is dotted lower case (`harness_gate.run`). An attr is
  lower case (`slot_wait_s`).
- **Types.**
  - `int`: an integer (a boolean is not one).
  - `float`: a finite number; an integer is written as a float.
  - `bool`: `true` or `false`.
  - `sha`: 40 hex, written lower case.
  - `label`: a string of at most 120 characters with no newline.
- **An unregistered event** is not written, and is counted
  (`event_unregistered`).
- **An unregistered attr, a wrongly typed attr, or a bad label** is dropped
  from the line, and counted (`attr_unregistered`, `attr_type`,
  `label_too_long`, `label_newline`). The rest of the line is written.

The registry is the privacy control (*Privacy*): the writer can never emit an
attr nobody declared.

### Adding an event

1. Add the event to `ai/telemetry/events.json`, with a description that says
   when it fires and what `at`, `duration_s` and `head` mean for it.
2. Give each attr the narrowest type. A free-form string is a `label` only if
   it is a short, bounded value (a verdict, a pool, an outcome).
3. Check every attr against *Privacy*.
4. The emitter's own tests cover the event, including the fail-open case
   (*Fails open*). `ai/test/telemetry/self-test.sh` parses the registry with
   `Registry.parse`, so a malformed entry fails the gate.

Renaming or removing an event that has landed changes what readers find. Do it
in the same change as every reader of it.

The registry is seeded with the events DND-1474, DND-1475 and DND-1476 name,
with the attrs their requirements list.

`ai/bin/check-telemetry-registry` (a harness-gate check) fails any
first-party emitter whose event is not registered, or whose `telemetry-emit`
call passes an unregistered `--attr`. It reads an event only when it is
written as a literal: `AthenaTelemetry.emit("<event>", …)`, or
`…/telemetry-emit --event <event>` or `athena_telemetry_emit --event <event>`
on one logical line (backslash continuations are joined). An emitter it
cannot read fails too. Its header names what it does not see: the attrs of an
in-process Ruby call, and attrs a shell emitter passes through an array or a
variable, which each emitter's own tests cover (*Adding an event* step 4), and
a second CLI call made through a variable in a file that also has a readable
one.

**Later (2026-10-01, DND-1474):** the paragraph above replaces a bullet that
listed the registration check as owed by the emitter tickets, with an
emitter's own tests the only guard until then. DND-1474 built the check.

Still owed, not done here:
- the design record's `slot_wait_s` on `harness_gate.run` and slot wait on
  `critic.round`, which their requirements dropped. An emitter ticket that
  wants them adds them here.

`telemetry.probe` is the writer's own probe (attr `note`). Use it to check the
writer by hand. It is never a phase anchor.

## Store

- **Path:** `${XDG_STATE_HOME:-$HOME/.local/state}/athena/telemetry/`,
  one `<YYYY-MM-DD UTC>.jsonl` per day. An `XDG_STATE_HOME` that is not
  absolute is ignored.
- **Modes:** directory 0700, files 0600, created on first write.
- **Day file:** chosen by the UTC date at WRITE time. A caller's `at` may lie
  before or after that day, so a reader reads every day file and filters on
  `at`; it never skips a file by its name.
- **`write-failures`:** a JSON object counting failures and drops by reason
  (*Fails open*). It is cumulative; pruning never resets it. Writers hold an
  exclusive `flock` on `write-failures.lock` and replace the counter by
  rename, so a reader or a crash never sees it half written. The lock wait is
  bounded (about half a second); past it, the drop goes to the stderr line
  (*Fails open*), so an emitter never stalls behind a stuck holder.

## Append

- One `write(2)` per line, opened `O_APPEND | O_CREAT | O_NOFOLLOW`, so lines
  from concurrent writers never interleave. A short write is ended with a
  newline, best effort, so the next line stays parseable.
- A line is at most 4096 bytes. If the attrs push it over, attrs are dropped
  from the last one back until it fits, `attrs_truncated: true` is set, and
  `attrs_truncated` is counted. The core fields are never cut.

## Fails open

- A write never raises to the caller, never changes its exit code, and never
  retries. The CLI's `--event` exits 0 even when the writer cannot load.
- Every failure or drop increments its reason in `write-failures` (*Store*).
- If even that write fails, the process prints ONE stderr line, prefixed
  `athena-telemetry:` and carrying `Fix:`, once per process.

The reasons:

| Reason | Meaning | Line written? |
|---|---|---|
| `event_unregistered` | the event is not in the registry | no |
| `attr_unregistered`, `attr_type`, `label_too_long`, `label_newline` | an attr was dropped | yes |
| `unit_invalid`, `label_invalid` | a unit, repo or host was not a label; it reads `null` or the next unit source | yes |
| `unit_parser_unavailable` | the ticket-ref parser did not load, or raised | yes |
| `unit_overlay_unavailable` | a present overlay could not give the work prefix | yes |
| `git_context_unavailable` | git failed for a reason other than "not a repo" | yes |
| `git_context_timeout` | git did not answer within its bound; its process group was killed | yes |
| `head_invalid` | a head that is not 40 hex; it reads `null` | yes |
| `at_invalid`, `duration_invalid` | a start that is not a time, or a negative or non-numeric duration | no |
| `attrs_truncated` | attrs were cut to fit 4096 bytes | yes |
| `line_too_long` | the core alone exceeds 4096 bytes | no |
| `day_cap` | the day file is at its cap (*Size cap*) | no |
| `short_write`, `write_error` | the append failed | no |
| `config_invalid` | a malformed seam (*Test seams*) | no |
| `registry_unreadable` | `events.json` cannot be read or parsed | no |
| `internal_error` | a bug in the writer | no |
| `counter_corrupt` | the counter itself was unreadable JSON and was restarted | n/a |

A store path that cannot be resolved at all (a relative `ATHENA_TELEMETRY_DIR`,
no absolute `HOME` or `XDG_STATE_HOME`) has no counter to write. It goes to
the stderr line.

## Retention

`telemetry-emit --prune [--retain-days N]` removes day files whose date is
more than N days before today (UTC). N defaults to
`ATHENA_TELEMETRY_RETAIN_DAYS`, else 30. It touches no other file. A file
already gone is skipped. It exits 1 with `Fix:` if it cannot read the
directory or remove a file, naming what it removed first. No store is not a
failure: it prints `pruned 0: no telemetry store at …` and exits 0. Per-day
files are the rotation.

Who prunes: the lead-time improver's runner, `scripts/athena-leadtime-run.sh`.
It runs `--prune` first on every tick that takes its single-run lock, wedged
ticks included. A tick skipped because a run is in flight does not prune. A
prune failure is recorded on the tick's record (`prune=`) and never fails the
tick. The runner runs only on its cron, which DND-1480 installs. Until then,
retention is `--prune` by hand, and only *Size cap* bounds growth.

**Later (2026-10-01, DND-1479):** this paragraph said the runner "is to run
`--prune` each tick" and "until that runner lands, nothing prunes". The runner
has landed. What prunes is the installed cron, and only ticks that take the
lock prune.

## Size cap

A day file at or over 64 MiB (`ATHENA_TELEMETRY_DAY_CAP_BYTES`) takes no more
appends that day. Each refused line is counted as `day_cap`, so a runaway
emitter cannot fill the disk and cannot hide. The size is checked before the
write, so concurrent writers can pass the cap by about one line each.

## The reader

`AthenaTelemetry.read(since:, until:, events:, unit:)` returns the matching
events, oldest first, with a status that keeps the cases apart:

| Status | Meaning |
|---|---|
| `no_store` | could not look: the store does not exist or cannot be listed. `reason` says which. |
| `incomplete` | some day file could not be read. `unreadable` and `reason` name it; the events are from the rest. |
| `ok_empty` | looked at everything, and nothing matched. `unit` names the unit searched for. |
| `ok` | events found. |

Every result carries the `write-failures` counter (`nil` with
`failures_reason` when it cannot be read), the count of malformed lines, and
any day file it could not read. A malformed line is counted, never silently
skipped. `since` and `until` bound `at` (`until` exclusive). A reader that
turns events into phases reports `no_store` and `incomplete` as "could not
measure", never as zero. A store path that cannot be resolved raises
`AthenaTelemetry::ConfigError`.

## The CLI

`ai/bin/telemetry-emit` (`--help` for the full text):

- `--event NAME [--at ISO|now] [--duration S] [--head SHA] [--unit U]
  [--unit-branch B] [--attr K=V]...` emits one event. `--attr` values are converted to the
  registered type; a key given twice is a usage error. Once the command line
  parses it always exits 0.
- `--prune [--retain-days N]` (*Retention*).
- `--stats [--since ISO] [--until ISO]`: events per day and per event, the
  latest line, the failures counter and the malformed count. Exit 3,
  `COULD NOT LOOK`, on `no_store`, `incomplete` or an unresolvable store path;
  never "0 events".
- `--self-test` runs the library suite. `--help` prints on stdout, exits 0 and
  writes nothing.
- Exit codes: 0 ok, 1 prune failed, 2 usage (with `Fix:`), 3 could not look.

A shell emitter calls it outside any measured check's own execution, bounded
and fail-open: `timeout -k 1 2 ai/bin/telemetry-emit --event … || true`. That
costs one Ruby start; it is not wall-clock tested (DND-1222).

`ai/lib/telemetry-emit.sh` is that call, written once (DND-1475): a bash
emitter sources it and calls `athena_telemetry_emit --event …`. It runs the
CLI under `timeout -k 1 2`: TERM at two seconds, KILL one second later. The
git grace in *Unit of work* (half a second) is shorter than that one-second
gap. It drops stdout and returns 0 whatever happens; of the CLI's stderr
only the one `athena-telemetry:` line reaches the caller. Its clock helpers
give `--at` and `--duration`.

**Later (2026-10-01, DND-1492):** this section said a shell emitter, and
the binding, call the CLI under `timeout 2`. Superseded by
`timeout -k 1 2`, which the binding has run since it landed (DND-1475): a
bare `timeout 2` only sends TERM, so a CLI that does not exit on TERM is not
bounded.

## Privacy

Values are numbers, booleans, shas, ids and short labels. Never argv, the
environment, paths outside the repo, message bodies, secrets
(`ai/contracts/athena-machine-secrets.md`) or work values. A work-ticket unit
is allowed in the local store on this machine only, never in a committed
fixture: tests use synthetic refs (`DND-`, `ZQ-12`).

## No network

The writer, the reader and the CLI never open a socket, ever.

## Test seams

They exist for tests. Which mode reads which:

| Seam | emit | `--prune` | `--stats` / `read` |
|---|---|---|---|
| `ATHENA_TELEMETRY_DIR` (an absolute store path) | yes | yes | yes |
| `ATHENA_TELEMETRY_NOW` (ISO 8601 "now") | yes | yes | no |
| `ATHENA_TELEMETRY_DAY_CAP_BYTES` | yes | no | no |

A malformed value is `config_invalid` for an emit (a relative store path goes
to the stderr line), and a failure with `Fix:` naming the seam for `--prune`
(exit 1) and `--stats` (exit 3). There is no switch that turns telemetry off:
nothing needs one, because it fails open.
