# Custom Tools Repository

**Kind: living normative document.** Amended in place, per *Documentation
conventions* → the living/dated rule below.

## Project Overview
This repository contains personal development tools and configurations:
- **dotfiles/**: Personal dotfiles and configurations
- **git-custom/**: Custom git commands and aliases
- **scripts/**: Custom shell scripts and tools (including `wt` for worktree management)
- **ai/**: Stored AI prompts and default CLAUDE.md templates for projects
- **ai-artifacts/**: Working documents and plans for tool development
- **system-files/**: System-level configuration files (requires root to install)

## Repository Structure

### dotfiles/
Configuration files for various tools and applications. These are symlinked to their appropriate locations in the home directory.

**Active Symlinks:**
```bash
~/.tmux.conf -> ~/dev/custom/dotfiles/.tmux.conf
~/.zshrc -> ~/dev/custom/dotfiles/.zshrc
~/.config/nvim/init.vim -> ~/dev/custom/dotfiles/init.vim
~/.config/yazi -> ~/dev/custom/dotfiles/yazi
~/.claude/CLAUDE.md -> ~/dev/custom/ai/CLAUDE.md
```

**Later (2026-09-21):** the last entry read **`~/CLAUDE.md`**, here and in the
recreate command below. Superseded: the live symlink is `~/.claude/CLAUDE.md`,
and `~/CLAUDE.md` does not exist on this machine. This is worse than a stale
note, because the path is not merely unread — it is *plausible*. A reader who
ran the documented `ln -sf … ~/CLAUDE.md` would create a file Claude Code never
loads, and get no error: the global instructions would simply not apply, and
nothing would say so. That is *A failed lookup must never look like an empty
one* pointed at the harness's own configuration. Measured 2026-09-20: a captain
mid-task found the gap and had to note it in its report
(`ai-artifacts/coordination/2026-09-20-notif-platform/reports/DND-247-h3-round3-report.md:40`
— "Note `~/CLAUDE.md` does NOT exist on this machine … which is stale"). The
other six symlinks in these two blocks were each verified live on 2026-09-21
and are correct as written.

**Theme Symlinks:**
```bash
~/.vim/colors/cyberpunk.vim -> ~/dev/custom/hypr/themes/cyberpunk.vim
~/.config/btop/themes/base16-cyberpunk.theme -> ~/dev/custom/hypr/themes/base16-cyberpunk.theme
```

To recreate symlinks if needed:
```bash
# Dotfiles
ln -sf ~/dev/custom/dotfiles/.tmux.conf ~/.tmux.conf
ln -sf ~/dev/custom/dotfiles/.zshrc ~/.zshrc
ln -sf ~/dev/custom/dotfiles/init.vim ~/.config/nvim/init.vim
ln -sf ~/dev/custom/dotfiles/yazi ~/.config/yazi
mkdir -p ~/.claude
ln -sf ~/dev/custom/ai/CLAUDE.md ~/.claude/CLAUDE.md

# Themes
ln -sf ~/dev/custom/hypr/themes/cyberpunk.vim ~/.vim/colors/cyberpunk.vim
mkdir -p ~/.config/btop/themes
ln -sf ~/dev/custom/hypr/themes/base16-cyberpunk.theme ~/.config/btop/themes/base16-cyberpunk.theme
```

### git-custom/
Custom git commands that extend git's functionality. These commands can be invoked as `git <command-name>`.

### scripts/
Standalone shell scripts and tools. The most significant is `wt` (worktree management tool) which integrates with Graphite for stacked PR workflows.

### ai/
Contains AI-related resources:
- **skills/**: Claude Code skills (symlinked to `~/.claude/skills`)
- **contracts/**: normative cross-project contracts — interfaces this machine's
  projects implement against, owned here rather than by any one consumer (e.g.
  `athena-inbox.md`, the local multi-tenant message facility; and
  `athena-events.md`, the Athena event platform — the deterministic
  notification/event-handling substrate `apps/athena` implements, of which the
  inbox is one delivery adapter; and `athena-judgments.md`, the advisory
  model judgments that deterministic policy may consume). A project opts
  into the inbox through a machine-local registry entry under
  `$ATHENA_INBOX_ROOT/projects/` (default `~/.local/share/athena`), keyed by the
  realpath of the repo's git common dir — **never** a file committed to the
  consumer repo
- **prompts/**: Legacy prompts (deprecated, migrated to skills)
- Default `CLAUDE.md` template for Elixir projects
- Other AI workflow configurations

### .auto-completions/
ZSH completion definitions for custom commands, providing tab-completion support.

### system-files/
System-level configuration files that require root privileges to install.

**Symlinks (requires sudo):**
```bash
/etc/greetd/config.toml -> ~/dev/custom/system-files/greetd-config.toml
```

To create symlinks:
```bash
sudo ln -sf ~/dev/custom/system-files/greetd-config.toml /etc/greetd/config.toml
```

## Development Guidelines

### Adding New Tools
1. Place scripts in the appropriate directory based on their purpose
2. Add completions to `.auto-completions/` if the tool has complex arguments
3. Document the tool's purpose and usage in its header comments
4. Consider creating a directory-level CLAUDE.md for complex subsystems

### Script Standards
- Use clear, descriptive names
- Include usage information in the script
- Handle errors gracefully with meaningful exit codes
- Every harness tool MUST answer `--help` on **stdout** with **exit 0**, doing
  nothing else — no model call, no network, no write, anywhere. A harness tool
  is a first-party executable that `ai/lib/harness_tools.rb` scopes in:
  `ai/bin/*`, `ai/skills/*/bin/*`, `ai/skills/*/scripts/*`, and any future
  executable under `ai/`. That file names each directory it leaves out, with
  the reason. `ai/bin/check-bin-help` enforces this in the shipwright gate.

  **Later (2026-09-24):** this read "Every executable under `ai/bin/`", and the
  check globbed `ai/bin` only. Superseded by the harness-tool scope (DND-508).
  The 13 `athena:slack` bins had no `--help` branch and nothing probed them:
  `post --help` took `--help` as its channel and read stdin as the message.

  **Later (2026-09-21):** this read "Support `--help` where appropriate."
  Superseded by the MUST above. "Where appropriate" let a tool ship with no
  `--help` branch at all, and such a tool does not *decline* to answer help —
  it runs its DEFAULT action and calls that the answer. Measured 2026-09-20:
  `ai/bin/critic-review --help` fell through to a full model-in-loop review of
  HEAD (`timeout 10 … --help </dev/null` exited 124), and the harness's
  response was to write the hang into a captain's brief
  (`ai-artifacts/coordination/2026-09-20-notif-platform/reports/H-2-DND-246-fix2-report.md`)
  rather than fix it. The sweep that followed found 17 such bins, including
  `build-agents --help` rewriting every rendered agent and `forge-preflight
  --help` minting a GitHub App installation token. A passthrough wrapper whose
  contract IS forwarding argv (`gh-athena`, `glab-athena`,
  `notion-athena-mcp`) is exempt, named with a reason in the check's `EXEMPT`
  table.

### Testing
- Test scripts in isolation before committing
- Verify completions work correctly
- Ensure scripts are executable (`chmod +x`)

### Integration
- Scripts should work well with existing tools
- Prefer composition over monolithic scripts
- Use environment variables for configuration where appropriate
- When writing scripts, the ordering of positional parameters vs flags should not matter. `wt stack open --create-sessions my-branch` should be just as valid as `wt stack open my-branch --create-sessions`

## Documentation conventions

These apply to harness docs in this repo — `ai/contracts/`, `ai/proposals/`,
`ai-artifacts/shipwright/journal.md`, this file, `ai/CLAUDE.md`, specs, ADRs,
and cross-references between skills/agents. (Conventions adapted from riddler's
howie/wurk harness.)

**Dates in every dated label below are UTC**, whichever kind of document
carries it, so a label can legitimately read one day ahead of the local date it
was written on.

- **Cite a skill's or document's steps by NAME, not by number.** Write
  "`processes:fix`'s command-resolution step", not "`processes:fix` step 2". A
  number is a position: insert a step above it and every external citation below
  silently points at the wrong place, and nothing checks it. A name survives
  renumbering and a stale one is greppable. Numbers inside a file's own body are
  fine (a renumber edits that file anyway); a number outside follows the name as
  decoration only ("the command-resolution step, currently step 2").
- **A living normative document is amended in place; a dated record is not.**
  The two rules below govern **dated records** — a proposal, a journal entry,
  an ADR, a design page, anything whose value is that it says what was true on
  its date. A **living normative document** is the opposite: a reader
  implements from its current text, so a superseded rule is replaced rather
  than left standing beside its replacement. Such a document announces each
  amendment **that supersedes an existing rule** with **one** bold dated label
  at the definitional mention — the place a reader grepping the superseded term
  lands — saying what the rule was, what replaced it, and why. The unit here is
  the **amendment**, not the document: a living document accumulates one label
  per supersession, which is the difference from the per-document rule for
  dated records below. **Purely additive content — a new section, a rule where
  there was none — carries no label**; there is no superseded text for a reader
  to be warned about, and labelling additions turns the marker into noise that
  hides the supersessions.

  **Which kind a document is, it says in its own header**; absent a header,
  treat it as a dated record. That declaration is the rule — any list of
  current living documents here would go stale the first time one is added.

  **Labelling starts at the first version a reader could have grepped.** A
  document still unmerged on its branch has no such reader, so its whole
  authoring cycle — including a review round that reverses a rule written an
  hour earlier — is composing the first published version, amended in place and
  unlabelled. This holds however long that cycle runs and however many rounds it
  takes; a same-day label on text that never shipped is the noise the
  one-label-per-supersession rule exists to prevent. Once the document lands,
  every later supersession is labelled normally. (Measured 2026-09-20: two
  workers converging the two contracts re-derived this judgement five times
  because the convention was silent on it.)
- **Never rewrite a dated document to match later reality; ANNOTATE it.**
  (**Later (2026-09-19):** this rule and the one after it once governed every
  harness doc listed above, `ai/contracts/` included. They now govern **dated
  records only** — a living normative document is amended in place, per the
  bullet above. Nothing about how a dated record is treated changed.) A
  reader who lands in a 2026-09-16 proposal or journal entry must learn what was
  true then. Corrections are added as a new paragraph whose first token is a
  bold dated label — `**Later (2026-10-01):** …` — the same shape as an existing
  entry. The label's date against the document's own date is how a reader tells
  an addition from the original, so an addition never appears as unmarked prose.
- **Annotate only what a reader will grep for** — a renamed or removed
  identifier — with the pointer inline at the definitional mention (that is where
  the grep lands), one pointer per document. Do not sweep dangling step numbers
  or line ranges through old documents; that is the rewriting this forbids.
- **An amendment that removes a mechanism must sweep everywhere that mechanism
  was RESTATED — not only the document that defines it.** Amending the contract
  and fixing the code leaves every *other* text that spelled the mechanism out
  still specifying the deleted one. Stale spec text is the *A failed lookup must
  never look like an empty one* class applied to specifications: it matches
  nothing in the current system, says nothing about that, and whoever implements
  it faithfully reproduces the removed model. Nothing raises. So, before the
  amendment is treated as complete, **grep the removed identifier — the old key,
  file, term, or field name — across every surface that could have restated it**,
  and fix or retract each hit.

  State the sweep as a class, not as a checklist of places: enumerating carriers
  is how the one nobody listed gets through. The two measured carriers are only
  exemplars. **Tracker bodies** — 2026-09-18, DND-202 moved inbox tenancy off the
  committed descriptor at the git *toplevel* onto a registry entry keyed by the
  git *common dir*, and DND-184 (In Progress at the time) and DND-190 still
  specified the deleted model; a captain implementing DND-184 as written would
  have given every worktree session zero channels, exit 0. **Unlanded sibling
  work** — 2026-09-20, C-1 removed the platform dedupe key, the `op` fold, the
  COLLAPSED outcome, and the lane-membership store from `athena-events.md` while
  C-2 sat staged-and-held on a branch whose prose still specified all four; the
  rebase was clean, because git compares lines and these two touched different
  documents.

  **Sweep the CITATIONS of what you narrowed, not only the RESTATEMENTS of what
  you removed.** Grepping the removed identifier finds every document that spelled
  the mechanism out. It cannot find the document that never restated it and merely
  *credited yours with holding it* — "the policy `X` places in `Y`", "those
  constants live in `Z`". Narrow or descope a document and every such citation
  becomes false while containing none of the text you deleted, so the grep you
  were told to run returns clean. The second grep is for the **document or section
  name you just changed**, and the question asked of each hit is whether it still
  describes what that document now holds. Measured twice on 2026-09-21. DND-247's
  descope removed `ai/CLAUDE.md`'s restatement and left both documents routing the
  tracker constants *through* it: `ai/CLAUDE.md` claimed the brief holds constants
  the brief explicitly declines to hold, while the brief cited a placement
  `ai/CLAUDE.md` no longer makes (`grep -c` = 0) — two [correctness] findings at
  critic round 10, a full apply round after the descope. In captain-500 the same
  class was fixed at one site (round 14, §6 vs the rendered captain) and re-signalled
  at the next (round 16, §1 vs §6) because the first sweep covered the site, not the
  class. Close it by construction where you can: make one place normative and have
  the others *defer by name* rather than re-state, then assert the class closed with
  a grep that must return zero.

  Two consequences worth stating outright, because each is invisible from one
  side alone:
  - **A clean rebase is not a clean reconcile, and no gate closes the hole.**
    Git reports a conflict only where lines overlap; prose that cites a document
    someone else rewrote conflicts with nothing. A mechanical gate cannot see it
    either — a contract describing a deleted mechanism passes every check. The
    re-read is the only instrument, so held work is re-read against *current*
    reality before it lands, not merely re-gated.
  - **Prefer citing a mechanism by section name over restating it.** A citation
    follows an amendment; a restatement goes stale. This is the same reason the
    first convention above cites steps by name rather than by number.

## Guard/error messages are written for the LLM

Every first-party guard, hook, check, or gate-wrapper that can DENY or FAIL must
tell the agent HOW TO SELF-CORRECT, not just that it failed. (Convention adapted
from riddler's howie/wurk harness — "errors written for the LLM.")

- The failure/deny output carries the greppable marker **`Fix:`** followed by an
  actionable instruction: what to change so the next attempt passes. Exemplars:
  `ai/bin/check-generic-skills`, `ai/hooks/safe-wait-guard.sh`,
  `ai/hooks/pronoun-guard.sh`.
- Every first-party executable, and every file under a `lib/` or `wt-lib/`
  directory, is classified in `ai/guard-classification.tsv`: `guard` (must carry
  `Fix:`), or `tool` / `no-fail-path` / `library` with the real reason it has no
  guard failure path. Test suites are classified by rule. Files under `ai/hooks/`
  and `ai/bin/` are guards unless listed.
- `ai/bin/check-guard-messages` enforces this (part of the shipwright gate). It
  fails on an unclassified file, a classified file that vanished, an empty
  discovery set, or a guard with a bare failure message. So a new script
  anywhere in the repo turns the gate red until someone classifies it. The one
  skip: an UNTRACKED path under a `node_modules/`, `.venv/`, or `vendor/bundle/`
  segment is a package manager's install output, not first-party code. It is
  counted in the check's output, and read again the moment it is staged.

  **Later (2026-09-24, DND-512):** the sentence above ended at "until someone
  classifies it", with no skip. Superseded: an untracked, un-ignored
  `node_modules` tree in the main checkout
  (`ai/skills/athena:inbox/channel/node_modules`) read as 182 unclassified
  first-party files, and the check was red in the main checkout while every
  clean worktree stayed green. Tracked files are never skipped, whatever their
  path.

  **Later (2026-09-24):** this read "record it in `EXEMPT` in
  `ai/bin/check-guard-messages`", and the check scanned only `ai/hooks/*.sh`
  plus a hand-kept `GUARD_BINS` list. Superseded by the classification table
  above (DND-218). Nothing under `scripts/`, `git-custom/`, or a skill's `bin/`
  was read, nor any `ai/bin` guard missing from the list, and the check still
  printed OK. Measured: `ai/bin/notion-athena-mcp`, `scripts/wt-preflight`,
  `scripts/prep-commit`, `scripts/check-stack`, `scripts/prep-stack`, and
  `scripts/check` all had failure paths with no `Fix:`, and none was read.

## A claimed mechanism must be able to fire

Normative text routinely discharges a gap by naming a mechanism: *the validator
rejects X*; *the added observability MUST makes Y visible*; *the residual is not
hidden, it is surfaced by Z*. That sentence is load-bearing — it is the reason
the gap counts as closed rather than papered over, and the reason a reviewer
accepts the resolution. It is also the sentence least likely to be checked,
because checking it means going and reading the named mechanism's
implementation, while the sentence already reads as true on its own.

This is *A failed lookup must never look like an empty one* moved up one level,
from a lookup to a specification. There, a wrongly-computed key matches nothing
and reports nothing. Here, a well-formed claim points at an instrument that is
structurally incapable of producing the outcome it is credited with, and the
document reports nothing either. No gate catches it: prose that attributes a
guarantee to a mechanism that cannot deliver it passes every check we have,
because it is well-formed. Only a reader who goes and looks finds it.

So, **when you write or accept a sentence crediting a named mechanism with a
guarantee, a refusal, or an observation, read that mechanism and establish it
can produce that outcome in the SPECIFIC STATE the claim is about** — not in
general, and not by its name sounding right.

- **Name the state, then ask what the instrument actually reads in it.** The
  question is not "does this mechanism exist" or "is it well-designed"; it is
  "in the exact condition I am claiming it covers, what value does it compute,
  and is that value distinguishable from the healthy case?" An instrument that
  is permanently false, or identical to healthy, in the state you cite is not a
  weaker version of the claim — it is no claim at all.
- **A residual that is "routed, not hidden" is only routed if the destination
  can receive it.** Naming a follow-up ticket, a deferred subsection, or a
  sibling mechanism as the home for what you did not close is a real discipline
  and worth keeping — but the routing is the claim, so it gets the same check.
  A residual routed to a mechanism that cannot observe it is hidden, with a
  citation on top.
- **An addition that makes a descope or narrowing "not a weakening" is the same
  claim.** If the thing rescuing a reduction from being a loss is a MUST you
  just wrote, that MUST is exactly the one to test for satisfiability before the
  reduction is accepted — it is carrying the whole argument.
- **The check belongs with the claim, not with the next reviewer.** Finding this
  by critic round is the expensive path: it costs a round, and the round after,
  and the rounds are what the convergence discipline is trying to bound.

Measured 2026-09-20, twice in one epic, in two different work items. A descope
was accepted as clean because it added a `collapsed-by-idempotency-key`
observability MUST; eight critic rounds later that MUST proved unsatisfiable —
no discriminator separates a sub-minute collapse from an at-least-once
redelivery. And a reconciliation closed a residual by pointing at
`inbox-doctor`'s never-delivered three-state distinction; one round later that
was shown unsatisfiable for the state it was cited for — `never_delivered` is
file-existence only (`[ -e "${inbox}" ] || never="true"`), so in a
producer-registration mismatch the platform IS delivering, the file exists, the
flag is permanently false, and the instrument can never fire. In both cases the
unverifiable sentence was the one doing the persuading.

### A check's own bar must not live in the diff it is checking

A gate that reads its threshold, allowlist, or marker list out of a file the
change under test may edit is not enforcing that bar — it is asking the change
what the bar should be. The failure is silent and reads as a pass: the number
moves, the check compares against the moved number, and the gate goes green. The
policy forbidding it usually exists, as prose in the check's own `Fix:` text,
where nothing executes it.

So **a numeric bar is ratcheted against its LANDED value** — the lowest across
the merge-base and the tip of `origin/main`, read out of git — and never against
the value in the working tree. Loosening fails; tightening is free; a genuinely
new entry passes and is named. **Do not build an in-repo escape hatch.** An env
var, an `approved.json`, a `# owner-approved` comment: each is writable by the
same diff, so each is the hole rather than the exemption. The hatch is that the
owner lands the new bar on `main` themselves and the branch rebases onto it —
unforgeable precisely because it is outside the diff. Say the residual out loud
(an agent that can push to `main`, or that edits the check's enforcement path,
still defeats it) rather than writing the reduction up as an elimination.

And **a bar that cannot be MEASURED is a failure, not a pass with a note.** This
is the one place to depart from the environment-safe precedent of
`check-hooks-registered` / `check-inbox-registry`: those ask whether a *subject*
exists and rightly pass when it does not, whereas here the subject is always in
the diff and what is missing is the measurement. Exit non-zero, enumerate every
candidate probed and what each gave, and keep "found nothing" textually distinct
from "could not look".

Measured 2026-09-20/21, twice. `check-agent-size`'s `BUDGETS` was raised
500 → 508 by an architect addendum, applied by a captain, and passed the gate
39/39; a critic caught it at round 10 by quoting the check's own Fix: text, and
the architect then reversed itself and landed the same required line at 499 by
shrink-to-pointer. Separately, captain-500's proposed `check-resident-invariants`
was found "defeated by the PR it constrains … threshold-lowering path the
change-under-test controls", and that design is parked after 19 rounds.

### The same question, asked of a PLAN: can step N's inputs exist at step N?

An ordered list of implementation steps reads as executable *because it is
ordered*. Nothing checks that the things step N consumes have been created by
the time step N runs, and a step whose inputs do not yet exist does not announce
itself — it runs, produces output, and the output looks like a result. That is
this section's defect moved from a sentence to a schedule.

The failure is worst where the mis-ordered step is a **measurement**, because
the number it produces is then attributed to whatever the later steps do. A
fixture whose discriminating input the harness cannot yet supply is not a
neutral placeholder: it is *mislabeled*, it scores as a miss or a false
positive, and the step that finally supplies its input gets credited with a
gain that was only the label becoming true. The flattering direction is the
dangerous one.

So **state, per step, the inputs it consumes and the step that creates each
one** — and where a step's output is a baseline, say which measurements are
comparable across steps and which are not. A corpus that grows between
measurements makes a before/after aggregate meaningless; the comparable series
is the part held byte-identical, and a not-yet-measurable case is recorded as
**`n/a`, never as `0`** (a zero is a measurement; an absent input is the lack of
one). Best is when that distinction is enforced rather than remembered: a
runner that *refuses to score* an input it cannot supply, naming the case,
cannot silently emit the zero.

Measured 2026-09-21: the same design's step 1 needed correcting in two
consecutive shipwright runs. It ordered "add fixtures 08–11, then record the
BEFORE recall/precision" ahead of the two steps that introduce the only prompt
inputs those fixtures are distinguished by — so all four were unauthorable at
the step whose entire purpose was to keep the later steps honest.

## Cross-session reflection loop (athena-shipwright cron)

The shipwright's cross-session reflection runs on an hourly cron and aggregates
across sessions — it is not a one-shot queue drain.

- **Schedule:** a USER crontab entry, `0 * * * * scripts/athena-shipwright-run.sh`.
  Fragility: this is a per-user crontab (cronie/OpenRC on this box), NOT an
  OpenRC/systemd service — if the user crontab is reset, the loop silently stops.
- **Durable state** (`ai-artifacts/shipwright/`, gitignored local runtime):
  `cursor.txt` (timestamp of the last processed artifact), `journal.md` (durable
  record + Decisions/Won't-change), `runs/` (per-run logs). The cursor makes it
  incremental; it mines `ai-artifacts/coordination/*/reports/*` newer than the
  cursor and clusters a pattern only when it recurs in ≥2 independent runs.
- **Install / restore / verify:** `scripts/setup-shipwright-cron` is the
  committed, idempotent source of the entry — re-run it to reinstall after a
  reset (`--dry-run` to preview, `--remove` to uninstall). `--check` asserts the
  entry is live (read-only); `--backup <file>` snapshots the current crontab to a
  local (gitignored) file. The committed installer is the canonical source, so
  the loop is always restorable even without the snapshot.
- **Lead-time feedback loop.** The same cron also drives fleet **lead time**
  (earliest branch commit → fully deployed) down over time. `ai/bin/lead-time`
  derives it per ticket from git + the forge's CI (GitHub `gh` / GitLab `glab`,
  auto-detected) — capturing nothing, so no agent has to remember a status; the
  design and the rejected markers are in `ai/docs/lead-time-tracking.md`. Each
  run scans `--slow 90` outliers newer than a per-repo cursor
  (`lead-cursor.<repo>.txt`, never advanced on a `SCAN INCOMPLETE`),
  splits each into `code` (start→merge, a harness/process lever) and `tail`
  (merge→deploy, a pipeline-efficiency lever), and when a slow shape qualifies
  spawns an **athena-architect** for a **safety-preserving** improvement. The
  **hard constraint** is `ai/blocks/ops/safety-checks.md`, carried verbatim by
  the shipwright/architect/admiral/captain: **make a safety check faster, never
  weaker** — never drop, skip, downgrade, or path-exclude tests, linters, type
  checks, scanners, coverage/mutation gates, deploy watchers, or review gates.
  The shipwright applies harness changes to `~/dev/custom` and files product-repo
  changes as Notion tickets for the fleet (it never touches a product repo).

## Cron D-Bus autolaunch leak (orphaned `dbus-daemon`, inotify exhaustion)

A cron-launched process runs with no `DBUS_SESSION_BUS_ADDRESS` (the crontab
sets none), yet a graphical `DISPLAY=:0` leaks in through the login-shell
snapshot that Claude Code's Bash tool sources (`dotfiles/.zshrc` exports
`DISPLAY=:0`, never the bus address). When any libdbus/GLib client then runs —
`dunstify` in the `notify-idle.sh` Stop hook is the identified one — with an
X11-reachable DISPLAY but no live/reachable session bus, libdbus AUTOLAUNCHES
one via `dbus-launch`, forking `dbus-daemon --syslog-only --fork ... --session`.
Being `--fork`, it daemonises (reparents to PID 1) and never exits — one leaked
bus per trigger. Measured 2026-09-22: ~109 accumulated (~1/hour) and exhausted
`fs.inotify.max_user_instances` (127/128), turning fleet gates red and
threatening the inbox doorbell (`inbox-wait`) and the channel attendant. The
tell was mysterious fleet-wide red gates, not a named error — the silent-dark
class. Autolaunch fires ONLY when the variable is unset, so any set value
disables it (reproduced both directions).

The durable fix, defense in depth:

- **`scripts/lib/dbus-env.sh`** — a shared helper the cron wrappers source.
  `athena_dbus_env_setup` exports a `DBUS_SESSION_BUS_ADDRESS` so no descendant
  autolaunches: a REAL bus discovered at runtime from a live session process
  (never a hardcoded `/tmp/dbus-*` path — those change across reboots), else an
  unconnectable sentinel that suppresses autolaunch (a headless run needs no
  notifications; a client just fails fast). Never overrides a value the caller
  set.
- **The cron wrappers** (`athena-shipwright-run.sh`,
  `athena-inbox-client-run.sh`) source it after their early-exit arg parsing and
  single-run lock, so `--help`/`--dry-run` and the `*/5` lock-held relaunch
  never trigger it. `notify-idle.sh` sources it too, so the Stop hook is guarded
  in every session regardless of how launched.
  **Later (2026-09-23):** this called the lock-held `*/5` invocation a "no-op
  relaunch". Since DND-316/DND-333 it is a watchdog pass that may capture and
  SIGTERM a wedged client. It still runs before `dbus-env.sh` is sourced, and
  nothing it starts (`inbox-client-capture`: `ss`, `/proc` reads, `kill`) is a
  D-Bus client, so the autolaunch reasoning above is unchanged.
- **`scripts/reap-orphan-dbus`** — belt-and-suspenders. Kills orphaned
  autolaunch session daemons (comm `dbus-daemon`; argv has `--fork` + `--session`
  + `--syslog`/`--syslog-only`; NOT `--system`/`--nofork`/`--config-file`;
  PPID 1; own uid; older than `--min-age`, default 300s). Never touches the
  system, real-session, or at-spi buses. Invoked best-effort by each wrapper, so
  no crontab change is needed; `--dry-run` inspects, `--self-test` checks the
  matcher against real signatures.
- **`ai/bin/check-inotify-headroom`** — loud observability, in the shipwright
  gate. FAILS with a `Fix:` naming the reaper when per-user inotify INSTANCE
  usage exceeds a threshold (default 80%). Environment-safe: passes with a note
  where `/proc` is absent, so it never false-fails a CI/sandbox commit; a
  re-exhaustion is now a named red, not a mysterious one.

## Hook registration (`~/.claude/settings.json` is not in git)

The `ai/hooks/*.sh` guards only run if they are *registered* in the live Claude
Code settings — a hook file can exist, pass its own `--self-test`, and still
never fire because nothing wires it. That file lives outside the repo and is not
version-controlled, so a bad edit has no diff and no `git` undo. On 2026-09-17 a
telemetry change rewrote the `hooks` block and silently dropped safe-wait-guard
and pronoun-guard; nothing detected it. The durable fix:

- **Source of truth:** `ai/hooks/registry.json` — which hook is registered on
  which event/matcher. Committed, greppable, the one place the expected wiring
  is declared.
- **Detect drift:** `ai/bin/check-hooks-registered` (in the shipwright gate)
  fails, naming each hook, if a registry entry is not live. Environment-safe: it
  passes with a note when no settings file exists (CI/agent env), so it never
  false-fails a harness commit; it only fails on a real drift in a real config.
- **Recover:** `scripts/setup-hooks --install` MERGES the registry into
  `settings.json` (backing it up first, idempotent) — it never rewrites the whole
  block, because a full rewrite is exactly what caused the outage. `--check`
  delegates to the gate check, `--dry-run` previews, `--remove` unwires,
  `--self-test` verifies install/idempotency/merge-safety on a temp file.
- **Worktrees:** hooks are always wired at the MAIN checkout's path, never a
  worktree's — a worktree path vanishes on cleanup and silently disables the
  guard. Both tools resolve the main checkout through `git rev-parse
  --git-common-dir`, so `check-hooks-registered` passes from a worktree and
  `setup-hooks --install` wires main-checkout paths wherever it is run from.
- **Editing hooks:** change `registry.json` and run `scripts/setup-hooks
  --install`; do not hand-write the `settings.json` hooks block (that is the
  clobber path). Hooks load at session start, so reload a session to activate.

## Inbox tenancy registry (`$ATHENA_INBOX_ROOT/projects/` is not in git)

**`ai/contracts/athena-inbox.md` is the normative home; this section is the
harness-operations summary and the contract wins** on any detail.

Which projects can reach the Athena Inbox is decided by machine-local, untracked
entries at `$ATHENA_INBOX_ROOT/projects/<project>.json` (default root
`~/.local/share/athena`; `0600` files in a `0700` directory). That is the same
shape as the hook wiring above, with one property that makes it worse: the
contract defines a **missing entry as zero channels, exit 0, no error**
(`ai/contracts/athena-inbox.md` → *Validation rules*, "No registry entry is not
a fault"), so a clobbered or deleted entry is a **silently dead inbox** — no
failure, no diff, no `git` undo. The same three artifacts answer it:

- **Source of truth:** `ai/inbox/registry.json` — the tenant list, one
  `{file, entry}` per project. `repo` is a project's git-common-dir realpath and
  MAY be written `~/...`. **No secret ever goes in it**; the machine token stays
  in `~/.config/athena-inbox-client/config.json`.
- **Detect drift:** `ai/bin/check-inbox-registry` (in the shipwright gate) fails,
  naming each entry that is missing, malformed, mis-permissioned, or edited away
  from the committed text. Environment-safe: passes with a note when there is no
  inbox root (CI/agent env), so it never false-fails; a root that exists with no
  `projects/` is real drift, not "not this environment".
- **Recover:** `scripts/setup-inbox-registry --install` materialises the declared
  entries, copying anything it replaces to
  `$XDG_STATE_HOME/athena/inbox-registry-backups/` first. It **merges**: it
  writes only the *entries* the committed list declares (plus the root and
  `projects/` themselves), so another project's entry is never moved or removed.
  `--check` delegates to the check, `--dry-run` previews, `--remove` reverts,
  `--self-test` runs `ai/inbox/test/self-test.sh`.
- **Repo identity is resolved at the point of capture** — `git rev-parse
  --git-common-dir` is cwd-relative in a main checkout, and resolving it later
  silently yields zero channels. The rule and its verification table live in the
  contract → *Repo identity: the git common dir*; it is repeated here only as a
  pointer, because it is the mistake this tooling is most likely to reintroduce.
- **One validator:** the committed entries are validated by the `athena:inbox`
  skill's own `descriptor_validate`, not by a second copy of its rules, so the
  installer can never write an entry the reader refuses to load. Where that
  validator cannot run (no `jq`, no skill in this checkout) both tools say so in
  their output — "validated" and "silently not validated" must never read the
  same.

## Agents work in worktrees, not the main checkout

**Default rule: an agent doing work in a git repo does it in a worktree.** The
main checkout of every repo under `~/dev` is a *shared surface*, not a spare
copy — the human types in it, several agents can be dispatched into it at once,
and for `~/dev/custom` specifically `~/.claude/skills` and `~/.claude/hooks`
resolve into it, so it is also the machine's live harness. A working tree has
one index and one set of files; two writers sharing it is not a race that
careful agents avoid, it is a race with no lock in it.

Measured on 2026-09-18 in `~/dev/custom`, all within eight minutes: the hourly
shipwright staged the whole tree and swept an interactive session's
`hypr/hyprland.conf` edit and a 230-line `.bak` into `ce70e04`, a commit whose
message was entirely about harness-gate self-tests (repaired by `7afc5a0`); two
shipwrights ran in that one tree at once, and the second yielded because it
*chose* to, having noticed the first, not because anything stopped it; and the
`run.lock` meant to serialise them was a zero-byte file that nothing could tell
apart from a corpse. A worktree makes all three structurally impossible instead
of caught by luck.

So: an agent that will edit, stage, commit, rebase, or reset **works in a
worktree** (`wt`, or `git worktree add`; house convention puts human-facing ones
at `~/.local/worktrees/<project>/<branch>`, while a robot's own tree belongs
somewhere nobody will wander into — the shipwright cron's lanes live inside
`.git/`). This is the same discipline captains have always had; it is now the
rule for every agent, including the unattended ones that had quietly been
exempt.

**One worktree per unit of work, and short-lived.** Different units of work get
different worktrees and branches — a worktree or branch is never reused for an
unrelated change. Feature branches and their worktrees are created from current
`origin/main`, merged back regularly, and cleaned up once their work has landed;
a branch or worktree lingering after its work merged is the anti-pattern, not
the resting state. Pruning a predecessor's leftover is fair game but is done
safely: check `git worktree list` against running processes, confirm the branch
is actually merged (a squash-merge is not an ancestor of `main` — confirm via
the forge), and `git worktree remove` only what no live process holds; when
unsure, leave it and note it.

**Later (2026-09-19):** this paragraph ended by naming **the shipwright cron as
the one current exception** — a single persistent tree inside `.git/` that it
rebased in place each hour, with the move to per-invocation lanes recorded as a
tracked follow-up. Superseded: that follow-up landed (PR #21, `c2317da`). The
cron now provisions a fresh lane per invocation —
`.git/shipwright-lanes/run-<utc>-<pid>` on branch `shipwright/run-<utc>-<pid>`,
created from `origin/main` and torn down after the run — so **there is no
exception left**: one worktree per unit of work, short-lived, now holds for
every agent on this machine without qualification. A crashed run leaves a lane
corpse that the next cron run reaps, judging liveness by a held `flock(2)` on
the lane's lock and never by a pid (pids recycle); reaping another run's lane by
hand is not a thing anyone does.

**A directly-spawned agent stays out of another lane's branch and worktree.**
A shipwright spawned by hand (or by another agent) is a *different unit of
work*: it takes its own named branch and worktree under
`~/.local/worktrees/<project>/<branch>`, never a cron lane's, and opens a PR
rather than pushing to main. Two actors sharing one branch or worktree is the
same no-lock race as sharing the main checkout — on 2026-09-18 a cron run and a
hand-spawned shipwright both operated on one shared shipwright branch and pushed
to main inside one window, serialized only by luck.

**An admiral merges that PR; nobody waits for the owner.** Once the PR meets
the bar (`athena:merge-boarding` → *The merge bar*: the author's DONE and
report, a recorded critic PASS on the head, the gate green), an admiral lands
it per `athena:merge-boarding`:
1. rebase onto `origin/main`;
2. re-gate the integrated head (`integration-gate`);
3. merge, then confirm it landed (`ai/bin/confirm-merged`);
4. fast-forward the main checkout (`git merge --ff-only`).

The author still never pushes to main and never merges its own PR. Owner-gated
merges stay gated: an `integration-gate` exit 4 is held for the owner unless it
is a security fix (`~/.claude/CLAUDE.md` → *Security fixes ship without owner
approval*).

**Later (2026-09-24):** this rule said a hand-spawned agent "opens a PR for the
owner to merge rather than pushing to main", so its green PRs sat until the
owner merged them by hand. Superseded by owner decision (Cody, 2026-09-24,
coordinator session). Asked "If you want admirals to merge hand-spawned PRs in
`~/dev/custom` from now on, say so and I'll write that into the repo rule," the
owner answered: "Yes, please just ship things." The branch, worktree and PR
discipline is unchanged; only who merges moved, from the owner to an admiral.

**Later (2026-09-19):** this rule used to rest on the cron owning a *named*
standing lane — **`shipwright/auto` at `.git/athena-shipwright`**, said to be
its exclusively — and the 2026-09-18 incident above was two actors on that one
branch. Superseded by the same PR #21 (`c2317da`): neither the branch nor the
path exists any more, and each cron invocation gets its own
`shipwright/run-<utc>-<pid>` lane that no other actor can name in advance. The
rule above is unchanged and is not weakened by that — it is what makes the
guarantee hold whichever way an agent was started, rather than depending on one
reserved name a hand-spawned run had to remember to avoid.

**Two fleets in one repo is normal, and it resolves at `origin/main`, not
between them.** Concurrent admirals never coordinate their *work* — each
rebases onto current `origin/main`, re-runs the gate on the **integrated** head,
and merges one MR at a time. The merge itself runs under a lock
(`athena:merge-boarding` → *Landing onto a moving main*), because a GitHub
squash onto a moved base lands an ungated tree. Detecting the other fleet is the wrong question
(a liveness marker is indistinguishable from a corpse, as above); "did
`origin/main` move since my branch point" is two SHAs, and it covers the
shipwright cron and the human too. Gate-green-alone is not gate-green-merged:
shared globals — the `check-agent-size` budgets, `ai/hooks/registry.json`,
`ai/inbox/registry.json` — are one number or one document, so two branches with
disjoint file sets can each pass alone and fail together, which git cannot see
and (with no CI here) nothing else re-checks. Mechanics and the tool:
`athena:merge-boarding` → *Landing onto a moving main*.

**Later (2026-09-26):** this said concurrent admirals "never coordinate with
each other". Superseded for the merge step: a GitHub squash-merge does not
refuse a moved base, so check-then-merge is a TOCTOU (gen_saas 2026-09-23).
Merges go through `locked-merge`, plus the coordinator's cross-machine protocol
where fleets span machines.

**This is a rule about writes, and specifically about git work.** Reading the
main checkout is normal and often necessary. Four things are genuine exceptions,
and they are exceptions because each one is *safe by construction* or has
nowhere else to happen — not because the agent judged it fine:

- **Publishing by fast-forward.** Work committed in a worktree has to reach the
  main checkout or it never takes effect on this machine. `git merge --ff-only`
  is the sanctioned way: it cannot create a commit or rewrite history, and git
  refuses it outright rather than overwrite a locally-modified file, so a
  bystander is protected by git and not by timing. Never `--force`, never a
  `reset --hard`, and a refusal is reported rather than worked around.
- **Machine-local state that is deliberately singular.** Runtime state under
  `ai-artifacts/` (the shipwright's `cursor.txt`, `journal.md`, `runs/`) is
  gitignored and must resolve to ONE location regardless of which tree is
  executing, so it is anchored to the main checkout and written there from a
  worktree. It is untracked, so it is not git work and it cannot collide with a
  commit.
- **Repairing the main checkout itself** — a wedged index, a stale worktree
  registration, a fast-forward that did not land. It is the patient; there is
  nowhere else to do it.
- **A human present and asking.** An interactive session where the user says
  "fix this and commit" is a human choosing where their own work happens. The
  rule binds *unattended and spawned* agents, which is where nobody is watching
  the collision.

The rule holds for every other case we could find, and it is deliberately stated
as a default with named exceptions rather than an absolute: an absolute that
everyone knows is violated hourly by the publish step teaches people to ignore
the rule, while four named exceptions can be checked.

**It is currently doctrine, not enforcement.** Nothing denies a write to a main
checkout — the honest choke point is a `PreToolUse` hook, which is separately
ticketed alongside the repository-scoped lock. Until that exists this holds
because agents follow it, so treat it as if it were enforced.
