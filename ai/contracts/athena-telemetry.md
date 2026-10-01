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
- Tests: `ai/test/telemetry/self-test.sh` and `ai/test/telemetry/telemetry_test.rb`.

**Provenance.** The design record is `ai/docs/lead-time-improver.md` →
*Telemetry*, a dated record. Where it disagrees with this contract, **this
contract wins**.

**Scope.** On-system only (owner, Cody, 2026-10-01: "the ability to add
instrumentation/telemetry (on-system only)"). Telemetry feeds the lead-time
improver's phase ledger. It is never sent anywhere (*No network*).

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
| `repo` | the basename of the git common dir's parent (`custom` for every checkout and worktree of `~/dev/custom`), or `null` outside a repo |
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

Step 3 uses the ticket-ref parser `ai/bin/lead-time` uses
(`LeadTime.ticket_ref`): one parser, not two. The writer loads that file
wrapped in its own module, so its top-level helpers never reach the caller's
namespace. A DND ref always counts. A branch naming any other ticket-shaped ref
also reads the private overlay's work-ticket prefix, as `lead-time` does, so a
work branch resolves on a machine with the overlay. A word shaped like a ticket
(`fix-utf-8`) is not one, and the branch name is the unit.

A unit is a label (*The registry* → label). One that is not is dropped,
counted as `unit_invalid`, and the next step applies. If the parser cannot
load, the branch name is the unit and `unit_parser_unavailable` is counted, so
the fallback is visible.

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

`telemetry.probe` is the writer's own probe (attr `note`). Use it to check the
writer by hand. It is never a phase anchor.

## Store

- **Path:** `${XDG_STATE_HOME:-$HOME/.local/state}/athena/telemetry/<YYYY-MM-DD UTC>.jsonl`.
  An `XDG_STATE_HOME` that is not absolute is ignored.
- **Modes:** directory 0700, files 0600, created on first write.
- **Day file:** chosen by the UTC date at WRITE time. A line is therefore in
  the file of its `at` day or a later one, never an earlier one.
- **`write-failures`:** a JSON object counting failures and drops by reason
  (*Fails open*). It is cumulative; pruning never resets it.

## Append

- One `write(2)` per line, opened `O_APPEND | O_CREAT | O_NOFOLLOW`, so lines
  from concurrent writers never interleave.
- A line is at most 4096 bytes. If the attrs push it over, attrs are dropped
  from the last one back until it fits, `attrs_truncated: true` is set, and
  `attrs_truncated` is counted. The core fields are never cut.

## Fails open

- A write never raises to the caller, never changes its exit code, and never
  retries.
- Every failure or drop increments its reason in `write-failures`, under an
  exclusive `flock`.
- If even that write fails, the process prints ONE stderr line, prefixed
  `athena-telemetry:` and carrying `Fix:`, once per process.

The reasons:

| Reason | Meaning | Line written? |
|---|---|---|
| `event_unregistered` | the event is not in the registry | no |
| `attr_unregistered`, `attr_type`, `label_too_long`, `label_newline` | an attr was dropped | yes |
| `unit_invalid`, `label_invalid` | a unit, repo or host was not a label; it reads `null` or the next unit source | yes |
| `unit_parser_unavailable` | the ticket-ref parser did not load | yes |
| `head_invalid` | a head that is not 40 hex; it reads `null` | yes |
| `at_invalid`, `duration_invalid` | a start that is not a time, or a negative or non-numeric duration | no |
| `attrs_truncated` | attrs were cut to fit 4096 bytes | yes |
| `line_too_long` | the core alone exceeds 4096 bytes | no |
| `day_cap` | the day file is at its cap (*Size cap*) | no |
| `short_write`, `write_error` | the append failed | no |
| `config_invalid` | a malformed seam, or no absolute `HOME`/`XDG_STATE_HOME` | no |
| `registry_unreadable` | `events.json` cannot be read or parsed | no |
| `internal_error` | a bug in the writer | no |
| `counter_corrupt` | the counter itself was unreadable JSON and was restarted | n/a |

## Retention

`telemetry-emit --prune [--retain-days N]` removes day files whose date is
more than N days before today (UTC). N defaults to `ATHENA_TELEMETRY_RETAIN_DAYS`,
else 30. It touches no other file. It exits non-zero with `Fix:` if it cannot
read the directory or remove a file. No store is not a failure: it prints
`pruned 0: no telemetry store at …` and exits 0. The lead-time improver's
runner prunes each tick. Per-day files are the rotation.

## Size cap

A day file at or over 64 MiB (`ATHENA_TELEMETRY_DAY_CAP_BYTES`) takes no more
appends that day. Each refused line is counted as `day_cap`, so a runaway
emitter cannot fill the disk and cannot hide.

## The reader

`AthenaTelemetry.read(since:, until:, events:, unit:)` returns the matching
events, oldest first, with a status that keeps three cases apart:

| Status | Meaning |
|---|---|
| `no_store` | could not look: the store does not exist or cannot be listed. `reason` says which. |
| `ok_empty` | looked, and nothing matched. `unit` names the unit searched for. |
| `ok` | events found. |

Every result carries the `write-failures` counter (`nil` with
`failures_reason` when it cannot be read), the count of malformed lines, and
any day file it could not read. A malformed line is counted, never silently
skipped. `since` and `until` bound `at` (`until` exclusive). A reader that
turns events into phases reports `no_store` as "could not measure", never as
zero.

## The CLI

`ai/bin/telemetry-emit` (`--help` for the full text):

- `--event NAME [--at ISO|now] [--duration S] [--head SHA] [--unit U] [--attr K=V]...`
  emits one event. `--attr` values are converted to the registered type. Once
  the command line parses it always exits 0.
- `--prune [--retain-days N]` (*Retention*).
- `--stats [--since ISO] [--until ISO]`: events per day and per event, the
  latest line, the failures counter and the malformed count. Exit 3,
  `COULD NOT LOOK`, on `no_store` or an unreadable day file; never "0 events".
- `--self-test` runs the library suite. `--help` prints on stdout, exits 0 and
  writes nothing.
- Exit codes: 0 ok, 1 prune failed, 2 usage (with `Fix:`), 3 could not look.

A shell emitter calls it outside any measured check's own execution, bounded
and fail-open: `timeout 2 ai/bin/telemetry-emit --event … || true`. That costs
one Ruby start; it is not wall-clock tested (DND-1222).

## Privacy

Values are numbers, booleans, shas, ids and short labels. Never argv, the
environment, paths outside the repo, message bodies, secrets
(`ai/contracts/athena-machine-secrets.md`) or work values. A work-ticket unit
is allowed in the local store on this machine only, never in a committed
fixture: tests use synthetic refs (`DND-`, `ZQ-12`).

## No network

The writer, the reader and the CLI never open a socket, ever.

## Test seams

`ATHENA_TELEMETRY_DIR` (an absolute store path), `ATHENA_TELEMETRY_NOW` (ISO
8601 "now") and `ATHENA_TELEMETRY_DAY_CAP_BYTES`. They exist for tests. A
malformed value is `config_invalid` for an emit, and a failure with `Fix:`
for `--prune` (exit 1) and `--stats` (exit 3). There is no switch that turns telemetry off: nothing needs
one, because it fails open.
