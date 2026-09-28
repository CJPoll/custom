---
name: athena:work-overlay
description: Work-domain procedures (the team standup, work comms syncs, work reports) and work-domain values live in the private work overlay and its local `work` plugin, not in this public harness. Use when a task needs a work-domain procedure or value and no `work:` skill is available, or when asked whether the private overlay is installed on this machine. Reports which piece is missing, with its Fix.
---

# athena:work-overlay

This harness is public. Work-domain values (people, ids, work ticket ids) and
work-only procedures live in the **private overlay**: an on-machine directory
(default `~/.config/athena/work`, `ATHENA_PRIVATE_ROOT` overrides) that also
serves a local Claude Code plugin marketplace, `custom-work`, with one plugin,
`work`. Its skills load as `work:<name>`. Contract:
`~/dev/custom/ai/contracts/athena-private-overlay.md`.

This skill is the loud stub for when that is missing. It never guesses a work
value and never substitutes a procedure of its own.

## What to run

1. `~/dev/custom/ai/bin/private-overlay status`
   - `PRESENT root=…` (exit 0): the overlay is here.
   - `ABSENT probed=…` (exit 3): no overlay on this machine.
   - `MALFORMED reason=…` (exit 4): an overlay is there but invalid.
2. `claude plugin list --json`: look for the entry whose `id` is
   `work@custom-work`, and whether it is `enabled`.
3. For the full picture in one read-only command:
   `~/dev/custom/scripts/setup-private-overlay --check`. It prints one line
   per component (`overlay`, `marketplace`, `plugin`, `hook`) and a `Fix:` for
   each gap. `COULD NOT MEASURE` means a read failed; it is not the same as
   missing.

## What to report

Say which piece is missing, quote its line, and give its Fix:

| Finding | Fix |
|---|---|
| overlay ABSENT | The overlay directory is missing, so work-domain features are unavailable on this machine. The owner creates it with `~/dev/custom/scripts/setup-private-overlay --init`. |
| overlay MALFORMED | Correct what the `reason=` names (contract → *Discovery*, *Marker*). |
| plugin missing or disabled | The owner runs `~/dev/custom/scripts/setup-private-overlay --install`. |
| everything present, but the `work:` skill you need is not listed | The skill has not moved into the overlay yet; say so. |

Who may run `--init` and `--install` is the contract's *Installer* → *Who
runs it*. Without the owner's explicit direction, report the command for the
owner instead of running it.

If the task cannot proceed without the work value or procedure, stop and say
so. That report is the result.
