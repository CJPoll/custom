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
  model judgments that deterministic policy may consume; and
  `athena-telemetry.md`, the on-system telemetry schema, writer and
  store). A project opts
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

## This repo is public: work values live in the private overlay

`CJPoll/custom` is PUBLIC. Never commit a work-domain value: work people and
contacts, work Slack ids, work Notion ids, work ticket ids and bodies, or work
repo internals. That covers code, prose, tests, fixtures, commit messages and PR
bodies. Tests use synthetic values (`UFAKE00001`).

- Work values live in the **private overlay**, an on-machine directory
  (`~/.config/athena/work`, or `ATHENA_PRIVATE_ROOT`). It is optional, and it
  is never pushed.
- Read a value with `ai/bin/private-overlay get <file> <.key.path>`. A non-zero
  exit is reported with its Fix. Never replace it with a guess.
- `scripts/setup-private-overlay` creates the overlay from the public skeleton
  (`--init`), wires its `work` plugin and the pre-push hook (`--install`), and
  reports each piece (`--check`, read-only). Who may run `--init` and
  `--install`: `~/.claude/CLAUDE.md` → *Owner approval policy* → *Notify after*.
- Contract: `ai/contracts/athena-private-overlay.md` → *Discovery*, *States and
  exit codes*, *Consumer obligation*, *Installer*.

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
- **A living normative document is timeless.** No now, new, currently, soon,
  or "does not yet" for standing behavior. Name the date or the ticket
  instead, or use a *Later* label. Describe behavior in the present tense,
  never with a hypothetical "would". Point by section name, never "above" or
  "below". Headings use sentence case. A task heading starts with a bare
  verb ("Install the hook"), not an -ing form.
  ([Google: timeless](https://developers.google.com/style/timeless-documentation),
  [tense](https://developers.google.com/style/tense),
  [headings](https://developers.google.com/style/headings))

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
- **Owner notes** (DND-988): `owner-notes.md` in the same state dir is the
  owner's message channel to the cron ("When we find poor prioritization causes
  issues, we can leave messages for the shipwright cron to address it." — Cody,
  2026-09-27). The owner appends with `ai/bin/owner-notes --add --source owner
  --text "…"` from their own terminal; an agent relays instead. How a note is
  written, verified, acted on and closed is defined once, in `ai/bin/owner-notes
  --help` and the shipwright template's *Where the evidence lives*.
- **Install / restore / verify:** `scripts/setup-shipwright-cron` is the
  committed, idempotent source of the entry — re-run it to reinstall after a
  reset (`--dry-run` to preview, `--remove` to uninstall). `--check` asserts the
  entry is live and that the runner's own `--dry-run` passes (read-only;
  DND-1729), so a green check means a tick can start. `--install` and
  `--dry-run` run that dry run too, and `--install` writes nothing when it
  refuses. `--backup <file>` snapshots the current crontab to a
  local (gitignored) file. The committed installer is the canonical source, so
  the loop is always restorable even without the snapshot. The entry names the
  main checkout's runner; `--install` and `--remove` refuse from a linked
  worktree (exit 5), whose runner vanishes on cleanup (DND-1639).

  **Later (2026-10-02, DND-1643):** this refusal was exit 4 here and exit 3 in
  `setup-leadtime-cron`. Superseded by one code, 5, in both installers: 4 and 3
  each already meant something else in the other one (COULD NOT LOOK, need
  root). `setup-clustering-cron` and `setup-athena-inbox-client` have no
  worktree refusal.
- **A dirty main checkout yields the tick; STALE dirt escalates once
  (DND-692).** The yield is exit 0 and never feeds the wedge counter, so on
  2026-09-22..25 one machine skipped 84 consecutive ticks on days-old leftovers
  (an abandoned `node_modules`, an `erl_crash.dump`) with no signal at all.
  Every skip now classifies its dirt, and the verdict is in its `.skipped`
  record: LIVE if some dirty path changed within `SHIPWRIGHT_STALE_DIRT_AGE_S`
  (6h), else STALE. After `SHIPWRIGHT_STALE_DIRT_ESCALATE` (3) consecutive
  STALE skips on one unchanged signature (sorted path list + newest mtime), ONE
  `harness-alerts` message names the paths, the first-seen tick and the owner's
  options: commit, gitignore, or remove. No repeat until the signature changes.
  The runner never touches the dirt. The thresholds and their reasons are in
  `scripts/athena-shipwright-run.sh`; the classifier is
  `scripts/lib/shipwright-stale-dirt.sh`.
- **A WEDGED lane leaves a record and alerts once per episode (DND-834).**
  Past `SHIPWRIGHT_FAIL_ESCALATE` consecutive failures a tick exits 75 and
  spawns no session. That used to reach only cron mail, and the laptop's mail
  spool has been empty since 2025, so its lane sat wedged for three days
  unseen. Every wedged tick now writes `<ts>.wedged` in `runs/` (why, the
  counter, when it wedged, the re-arm command), and the first wedged tick of an
  episode sends ONE `harness-alerts` message naming that record. The episode
  ends when the counter is cleared (`rm ai-artifacts/shipwright/consecutive-failures`,
  the re-arm); a later wedge alerts again. The exit stays 75 whatever the
  record or the send does.
- **Every tick snapshots the Slack roots (DND-1502).** Before the yield and
  wedge guards, the tick runs `ai/bin/slack-roots-tick`, which runs
  `judgment-label --propose`. An inbox generation is deleted at its second
  rotation, so a root not snapshotted by then is lost to the slack_routing
  eval for good. The run is idempotent and bounded (600 s). A tick that ran
  leaves `ai-artifacts/slack-roots/runs/<ts>.propose`: judgment-label's
  output, then `ok: appended=N` or `failed: …`. A tick that found another
  running leaves `<ts>.skipped`. The tool's stderr is in the shipwright's
  `runs/<ts>.slack-roots.log`. After 3 failed ticks in a row, ONE
  `harness-alerts` message (slug `slack-roots-failing`) goes out per episode;
  a healthy tick ends the episode. Its outcome never changes the tick's exit
  code. No crontab change: it rides the existing hourly entry. Residual: a
  tool that cannot make its state dir (exit 3, no record) or is missing is
  named in that log and never alerts.
- **Lead time is not this cron's.** The lead-time improver cron owns it
  (*Lead-time improver cron* below); this cron does no lead-time work. Fleet
  **lead time** is captain dispatch → landed. `ai/bin/lead-time`
  reads the start from the ticket's dispatch date, which `mark-in-progress`
  stamps at dispatch, and derives the end from git + the forge's CI (GitHub
  `gh` / GitLab `glab`, auto-detected). A DND ticket's date is `In Progress
  at`; a work (walt_ui) ticket's tracker and property come from the private
  overlay (DND-1341). A row with no stamp reads could-not-measure, and so does
  a walt_ui row on a machine with no overlay. The design and the rejected
  markers are in `ai/docs/lead-time-tracking.md`.

  **Later (2026-10-01, DND-1480):** this bullet was *Lead-time feedback
  loop*: each shipwright run scanned `--slow 90` outliers newer than a
  per-repo `lead-cursor.<repo>.txt` in this state dir, and spawned an
  athena-architect when a slow shape qualified. Superseded by the improver
  cron, its own runner at `:30`, because a lead-time run (measure, judge an
  experiment, land one change) does not fit inside the shipwright's run
  (`ai/docs/lead-time-improver.md` → *Decisions*: *A second cron*, *The
  session is an `athena-shipwright`*, *One loop owns lead time*). Its watch
  scan is that scan moved verbatim, and `setup-leadtime-cron` seeded its
  cursors from those files.

  **Later (2026-09-30, DND-1318):** the start was the earliest branch commit,
  "capturing nothing". Superseded by the owner's definition, lead time =
  captain dispatch → landed: a squash reset the commit start (PR #129 read
  21m 19s for a 46m 17s ticket).

  **Later (2026-09-30, DND-1341):** "The stamp is DND-only, so a repo on
  another tracker (walt_ui) measures only its `tail`." Superseded: the work
  tracker carries the same stamp, its database and property read from the
  private overlay, so the owner's metric covers walt_ui work.

## Epic-clustering cron (12h, DND-983)

A second USER crontab entry runs `scripts/athena-clustering-run.sh` twice a day.
It spawns one athena-architect that runs `athena:epic-clustering`. The
shipwright cron never writes Notion, so this is its own runner.

- **Schedule:** `0 7,19 * * *` in machine-local time (America/Denver here), so
  07:00 and 19:00 Denver. That is 13:00/01:00 UTC under MDT and 14:00/02:00 UTC
  under MST; cronie follows DST. The run before Denver noon also writes the
  daily digest to its run record, `runs/<ts>.digest.md`, once per Denver day.
  The `.run` record names it, or says `digest: MISSING`. No bookkeeping from
  the pass reaches the owner. What needs the owner still does: a won't-fix
  notice is its own DM, and a `Needs Attention` move sends its usual one-line
  DM (`athena:epic-clustering` → *Who runs it, and when*).
  The cron's headless session is the pass's top-level session, so it posts
  each won't-fix notice (DND-1749). The `.run` record has one `notice:` line
  per won't-fix closure: `notice: posted <channel>/<ts> DND-N veto=<veto>`,
  `notice: NOT POSTED DND-N <why>; veto=<veto>`, `notice: UNREADABLE`,
  `notice: UNKNOWN` (the session ended early), or `notice: none`. No session
  can verify a click on a cron notice, so it has no buttons. Its veto is a
  `ticket.wontfix_veto` owner approval grant the server acts on
  (`veto=grant <grant_id> <channel>/<ts>`), or, when the server cannot give
  one, by hand in Notion (`veto=by-hand <reason>`). `veto=UNSTATED`,
  `veto=CONFLICT` and any by-hand reason but `no_tool` or `class_unsupported`
  are loud
  (`athena:epic-clustering` → *Won't-fix notices* → *On the cron*, DND-1758).

  **Later (2026-10-02, DND-1758):** this said the cron notice's veto was
  always by hand, and the `notice:` lines had no `veto=`. Superseded by the
  owner's choice of a server-side veto grant.

  **Later (2026-10-02, DND-1738):** the morning run also sent the daily
  digest to the owner's DM. Superseded by the owner: "I guess I found the
  morning digest itself helpful; it's the epic clustering message I don't
  know what to do with." The counts are bookkeeping; the morning digest the
  owner reads is the server's (`ai/docs/morning-digest-v2.md`).
- **Fragility:** the same as the shipwright's. It is a per-user crontab line,
  so a crontab reset stops it silently. The session is launched from a scratch
  lane, and the Notion/Athena MCP servers are registered on the main checkout,
  so the runner copies them into a `--mcp-config`. A missing server, or the
  skill not landed in the main checkout, is exit 78 and counts as a failure.
  So does a `scripts/lib` file the tick sources (`mcp-preflight.sh`,
  `dbus-env.sh`) that is missing, unreadable, unloadable, or lacks a function
  the tick calls (DND-1603, DND-1728): it leaves a
  `.failed` record, feeds the wedge counter and the one wedge alert, and the
  lead-time runner treats it the same. The shipwright runner does too, for
  `dbus-env.sh` and `shipwright-stale-dirt.sh`.
- **Install / restore / verify:** `scripts/setup-clustering-cron`
  (`--dry-run`, `--check`, `--remove`, `--backup <file>`). `--check`, the
  install, the installer's install `--dry-run` and the runner's `--dry-run`
  run the runner's own skill and MCP preflight
  (`scripts/lib/mcp-preflight.sh`, DND-1571). The installer's three then run
  the runner's own `--dry-run`, which also checks the `scripts/lib` files a
  tick loads (DND-1728), so a green check means a tick can start. The admiral that
  lands a change to it runs it in the main checkout and notifies the owner
  (`ai/CLAUDE.md` → *Owner approval policy*). State and per-run
  records are in `ai-artifacts/clustering/`. The wedge follows the shipwright's
  pattern (see the wedge bullet in *Cross-session reflection loop* above):
  2 failures in a row exit 75 and write a `runs/<ts>.wedged` record. The first
  wedged tick of an episode sends ONE `harness-alerts` message (slug
  `clustering-wedged`). Re-arm: `rm ai-artifacts/clustering/consecutive-failures`.
  A session that never reaches the model is BLOCKED (exit 69). It never
  wedges, but 2 in a row send ONE `clustering-blocked` alert per episode,
  because an auth or account fault does not clear by itself. Every run that
  spawned a session ends with one `harness-lane-drain` request, which
  `athena:inbox-attend` → *A fourth writer* routes to the harness lane
  (`ai/docs/ticket-lane-action-brief.md` → *On a drain request*). The run's
  `.run` record says `drain: sent <name>` or `drain: FAILED to send`.

## Lead-time improver cron (hourly, DND-1480)

Another USER crontab entry runs `scripts/athena-leadtime-run.sh` at `:30`
every hour. Each tick spawns one athena-shipwright in `MODE: lead-time`, which
runs `athena:lead-time-improve` once. It is the only loop that acts on lead
time. The design record is `ai/docs/lead-time-improver.md`.

- **Scope:** per machine. `ai/bin/lead-time-repos` resolves this machine's
  repos and their modes; its `--help` says where the list comes from. The
  runner, the installer and the skill read only its result. The tracked
  default has custom `improve` and gen_saas, walt_ui `watch`. An `improve`
  repo gets the phase ledger, before/after experiments, the `ready-and-idle`
  sweep (no CI: `ready-and-idle --help`), and at most one change per run. A
  harness change lands in custom. A lead-time improve run
  may also change any repo its OWN machine's list has in `improve` mode,
  its local tooling and its CI/CD and deploy included, through that repo's
  normal bar (the DND-1540 product lane: a PR, CI green, a critic PASS,
  `integration-gate --with-critic`, `locked-merge`, `confirm-merged`, the
  deploy concluded): a run opens the PR, and a later tick lands it. No
  quality bar is lowered: moving a bar stays with Cody (`~/.claude/CLAUDE.md`
  → *Owner approval policy*, item 5), and the run never clears an
  `integration-gate` exit 4. Every other agent, and the shipwright outside
  `MODE: lead-time`, is unchanged. The grant's words and the procedure:
  `athena:lead-time-improve` → *The grant*, *The product lane*. A `watch`
  repo gets the outlier scan, the `ready-and-idle` sweep and an architect
  hand-off, and is read-only to it. A
  repo not checked out on the machine is skipped by name in the run's `.run`.
  A list that does not resolve, zero repos included, is a failed tick (exit
  78) with the resolver's `Fix:`.

  **Later (2026-10-01, DND-1527):** this bullet read "**Scope:**
  `ai/config/lead-time-repos.json`". Superseded: a machine-local override
  (DND-1526) can replace that file, and a session's lane copy of it cannot
  see the override, so every reader goes through the resolver.

  **Later (2026-10-01, DND-1542):** the lead-time loop never touched a
  product repo, and this bullet said "at most one landed change per run": an
  `improve` repo other than custom acted in custom only (DND-1533;
  `ai/docs/lead-time-improver.md` → *Who may do what*). Superseded for
  improve-mode lead-time runs only, by the owner's grant. Cody, laptop
  terminal, 2026-10-01 ~14:20Z: "improve gen_saas should be able to change
  whatever in the gen_saas repo is causing lead time issues without lowering
  quality bars. This includes things that are locally run and also CI/CD
  improvements." Confirmed by Cody, Slack DM to Athena, 2026-10-01, relayed
  by the custom coordinator: "Yes, the cron should work in the repos it is
  configured to work in to improve lead time without closing quality bars".
  A product change is a PR that a later tick lands, so "landed change" became
  "change".
- **One machine per repo** (coordinator, 2026-10-01): a repo appears in at
  most one machine's list, in either mode. Two journals on one repo split its
  history and double-count its landings. An overlap is a config error.
  Nothing locks or detects it across machines: each resolver sees only its
  own machine's config, so whoever writes an override checks the others by
  running `ai/bin/lead-time-repos` on each.
- **The hard constraint** is `ai/blocks/ops/safety-checks.md`, carried
  verbatim by the shipwright, architect, admiral and captain: **make a safety
  check faster, never weaker**. Never drop, skip, downgrade, or path-exclude
  tests, linters, type checks, scanners, coverage/mutation gates, deploy
  watchers, or review gates.
- **Schedule:** `30 * * * *`, half an hour off the shipwright's `:00`, so the
  two hourly loops never start together.
- **Fragility:** the same as the shipwright's. It is a per-user crontab line,
  so a crontab reset stops it silently.
- **Install / restore / verify:** `scripts/setup-leadtime-cron` (`--install`,
  `--dry-run`, `--check`, `--remove`, `--backup <file>`). The entry always
  names the main checkout's runner, and `--install` and `--remove` refuse to
  run from a linked worktree (exit 5, the same code as `setup-shipwright-cron`'s
  refusal). `--check` is red on a missing, duplicated or
  stale entry, and on any precondition that would make a tick exit 78: the
  skill, the repo list, or the runner's own MCP preflight
  (`scripts/lib/mcp-preflight.sh` in the main checkout, DND-1571), which
  `--install`, its `--dry-run` and the runner's `--dry-run` run too. Last,
  `--check`, `--install` and its `--dry-run` run the runner's own
  `--dry-run`, which also checks the `scripts/lib` files a tick loads
  (DND-1728). NOT
  REGISTERED (exit 2) and COULD NOT LOOK (exit 4) are told apart. The admiral that lands a change to it runs `--backup`,
  `--install` and `--check` in the main checkout right after the
  fast-forward, so there is no hour with no lead-time loop.
  `--install` seeds each missing cursor and never overwrites one: a watch
  repo's `watch-cursor.<repo>.txt` from the shipwright's old cursor file, and
  an improve repo's `cursor.<repo>.txt` at 14 days back. Who may run it:
  `~/.claude/CLAUDE.md` → *Owner approval policy* → *Notify after*.
- **State** (gitignored) is in `ai-artifacts/lead-time/`: `ledger.jsonl`,
  `experiments.jsonl`, `journal.md`, the cursors and `runs/`, plus
  `product-prs.jsonl` and `product-line-stopped.<R>` for a product repo
  (`ai/bin/leadtime-product --help`). Each run's lane is
  `.git/leadtime-lanes/run-<utc>-<pid>`, cut from `origin/main`; a product
  repo's lane is the same path under that repo's git common dir.
- **Failures:** the runner's `--help` is the normative list. Three
  unsuccessful outcomes in a row wedge it: exit 75, a `runs/<ts>.wedged`
  record, and ONE `leadtime-wedged` alert per episode. Re-arm:
  `rm ai-artifacts/lead-time/consecutive-failures`. Two blocked ticks in a row
  send ONE `leadtime-blocked` alert. A lane commit not on origin/main is
  STRANDED (exit 72) and its branch is kept; in a product lane, a commit
  pushed on a recorded improver PR is awaiting landing instead. A failed
  post-merge deploy stops that repo's line until the owner re-arms it (`rm`
  its `product-line-stopped.<R>`). An improve repo with no observe record
  for the run, an unreadable one, a failed observe or a failed ingest is a
  counted failure too (DND-1820, the next bullet). Unlike the shipwright
  runner, it has no dirty-main-checkout yield.
- **A phase it cannot measure escalates (DND-1806).** A phase that stays
  unmeasurable while its hand-off ticket is open gets that ticket promoted
  and ONE `leadtime-unmeasurable` alert per episode. The rule and its
  outcomes: `athena:lead-time-improve` → *Escalate what stays unmeasurable*.
  The run's session does it through that skill's `unmeasurable` tool, and
  the runner checks that the session ran it (DND-1820). After a session
  that reached the model, `unmeasurable check` reads this run's record for
  every improve repo the tick covered. No record is `observe-missing`, a
  record it cannot read is `observe-could-not-look`, an `observe` that
  failed before counting is `observe-failed`, and a repo whose ingest
  failed, so it had no summary to observe, is `ingest-failed`. Each is
  named in the `.run` record and counted, so three in a row wedge the lane
  and send the `leadtime-wedged` alert; the exits are in the runner's
  `--help`. It proves the call, not the escalation: an `observe` that could
  not read or promote the ticket passes, with `exit=3` on its `.run` line,
  and the next run retries. The count is `unmeasurable.json` in the state
  dir; the per-run record is `runs/<run id>.observe.<repo>.json`.

  **Later (2026-10-02, DND-1820):** this bullet ended "so it fires only on a
  run that calls the tool; nothing checks that it did". Superseded by the
  runner's observe check above. A session that skipped `observe` read as an
  ok tick, which silently re-created the re-noting DND-1806 was filed to
  end.

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
  `athena-inbox-client-run.sh`, `athena-clustering-run.sh`,
  `athena-leadtime-run.sh`) source it after their early-exit arg parsing and
  single-run lock, so `--help`/`--dry-run` and the `*/5` lock-held relaunch
  never trigger it. `notify-idle.sh` sources it too, so the Stop hook is guarded
  in every session regardless of how launched.
  **Later (2026-09-23):** this called the lock-held `*/5` invocation a "no-op
  relaunch". Since DND-316/DND-333 it is a watchdog pass that may capture and
  SIGTERM a wedged client. It still runs before `dbus-env.sh` is sourced, and
  nothing it starts (`inbox-client-capture`: `ss`, `/proc` reads, `kill`) is a
  D-Bus client, so the autolaunch reasoning above is unchanged.
  **Later (2026-10-02, DND-1725, DND-1728):** this said the wrappers source
  `dbus-env.sh` only after the lock, so `--dry-run` never loads it. Superseded
  for `athena-shipwright-run.sh`, `athena-leadtime-run.sh` and
  `athena-clustering-run.sh`: their `--dry-run` now sources it, before the
  lock, to check that it loads and defines what the tick calls. A dry run
  never calls `athena_dbus_env_setup` and starts no D-Bus client, so
  autolaunch still cannot fire. That holds while `dbus-env.sh` stays
  definition-only at top level.
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
  The required set is the registry **as landed on origin/main** (DND-743), never
  the branch's copy: a hook a branch adds is reported as *pending* and passes
  unwired, and a branch cannot remove a landed hook from its own bar. A wired
  hook whose script is missing or not executable fails as *dangling*. A bar it
  cannot read is exit 3, could not measure.
  A wiring is identified by **(event, matcher, script)**, so one script may
  have several rows on one event, each checked on its own (DND-887: keyed on
  (event, script), a second-matcher row was never installed and read as
  wired). An omitted matcher, `""` and `"*"` compare equal. The landed bar and
  *pending* apply per row: a matcher row only the branch declares is pending.
  A declared script wired under a matcher that neither the landed nor the
  branch registry declares for it fails as *stale*. A branch that changes a
  landed row's matcher cannot lower its own bar: the landed matcher stays
  required until the change lands, and the new one is pending.
  Under harness-gate the bar is origin/main as pinned at gate start. When it
  fails and origin/main has since moved past the pin, live wiring that passes
  the NEWER bar in full is named *ahead of the pinned bar* and passes
  (DND-1552). The newer bar is the newer origin/main's registry plus any
  landed point older than the pin (a merge-base before it), so only the pin
  is superseded and a branch that needs a rebase still fails. So a
  main-checkout install after a landing no longer reddens every concurrent
  gate. Wiring that passes neither bar still fails.
- **Recover:** `scripts/setup-hooks --install` MERGES the registry into
  `settings.json` (backing it up first, idempotent) — it never rewrites the whole
  block, because a full rewrite is exactly what caused the outage. Run from the
  main checkout, it replaces a stale matcher, touching only that registry
  script's wiring; from anywhere else it keeps the stale wiring and names it.
  `--check`
  delegates to the gate check, `--dry-run` previews, `--remove` unwires,
  `--self-test` verifies install/idempotency/merge-safety on a temp file.
- **Retiring a hook (DND-1517):** deleting a row does not unwire it, because
  the live settings outlive the registry. Move the row to `registry.json`'s
  `retired` list instead: one exact (event, matcher, script) per entry, never
  also a `hooks` row. After it lands, `scripts/setup-hooks --install` from the
  main checkout unwires exactly that wiring and nothing else: the same script
  under another matcher, other tools' hooks and the owner's own entries stay.
  From anywhere else it keeps the wiring and names it, like a stale matcher.
  `check-hooks-registered` fails while a **landed** retired row is still wired
  (*retired, still wired*, with that `--install` as its `Fix:`), the same exit
  as *stale*. A retirement only the branch adds is *pending*, and a branch that
  drops a landed one cannot excuse a wiring it still names. Keep the script on
  disk (a no-op is enough) until no machine wires it, then delete the script
  and its `retired` row together. Who runs the installer is the same as under
  *Editing hooks* below.
- **Worktrees:** hooks are always wired at the MAIN checkout's path, never a
  worktree's — a worktree path vanishes on cleanup and silently disables the
  guard. Both tools resolve the main checkout through `git rev-parse
  --git-common-dir`, so `check-hooks-registered` passes from a worktree and
  `setup-hooks --install` wires main-checkout paths wherever it is run from.
- **Editing hooks:** change `registry.json` on the branch. Wire it only **after
  it lands**, with `scripts/setup-hooks --install` in the main checkout. Wiring
  before landing points settings at a main-checkout script that does not exist
  yet, so every matching event fails with exit 127 (DND-670); `--install` now
  skips such an entry and names it. Do not hand-write the `settings.json` hooks
  block (that is the clobber path). Hooks load at session start, so reload a
  session to activate. Who may run the installer, and on whose word:
  `~/.claude/CLAUDE.md` → *Owner approval policy* → *Notify after*.

  **Later (2026-09-26):** this bullet read "change `registry.json` and run
  `scripts/setup-hooks --install`", and *Detect drift* compared the live
  settings against the branch's own `registry.json`. Superseded by DND-743. A
  branch that added a hook could not pass the gate until it was wired, so the
  DND-670 captain ran `--install` from its worktree. That wired a main-checkout
  path with no script behind it, and every Bash call failed with exit 127 until
  the branch landed. The bar is now what landed on origin, and wiring waits for
  the landing.
- **The agent-stash env (DND-775):** `registry.json` also has an `env` section:
  the GIT_CONFIG_* pairs that register the git reference-transaction hook
  `ai/git-hooks/agent-stash-guard.sh`, `GIT_TRACE2=/dev/null`,
  `ATHENA_AGENT_BIN` (the directory of the agent PATH wrappers: `git`, and
  the forge-identity `gh` and `glab` of DND-1803), and `CLAUDE_ENV_FILE`, which names
  `ai/agent-env/session-env.sh`. Claude Code runs that script in the Bash
  tool's shell after the shell snapshot and before each command; it prepends
  `ATHENA_AGENT_BIN` to PATH. Plain `--install` never touches it:
  that is the routine drift fix agents run. `scripts/setup-hooks --install-env`
  merges it and is the OWNER's activation step; `--remove-env` removes exactly
  it (the one-command disable). Restart sessions after either. Like a hook,
  it is installed only after it lands. The expected values are read from the
  registry AS LANDED, like the hooks' bar. So is what `ATHENA_AGENT_BIN` may
  hold: the entries of `ai/agent-bin/` at the landed tip, never a list in the
  checker (DND-1842). A live file only a newer origin/main lands is *ahead of
  the pinned bar*; one a branch adds is *pending*.
  The same PATH carries forge identity (DND-1803): the git wrapper refuses a
  push to github.com or gitlab.com not made through `gh-athena git` /
  `glab-athena git` (`ai/lib/agent-forge-push.sh`), and the `gh` / `glab`
  wrappers refuse a forge write not made through `gh-athena` / `glab-athena`
  (`ai/lib/agent-forge-cli.sh`), wherever the command came from, a script
  included. `forge-identity-guard.sh` stays the earlier, lexical layer. The
  `gh` and `glab` wrappers need no env change: they are on PATH once they land
  in the main checkout. `check-hooks-registered` fails on any other file in
  `ai/agent-bin/`, because it would shadow a real command.
  `check-hooks-registered` prints its own agent-stash line: INACTIVE (exit 0),
  ACTIVE (exit 0, runtime asserted), PENDING RESTART (exit 0), DRIFT/FAIL
  (exit 1), or COULD NOT MEASURE (exit 3: guard keys present but the landed
  env cannot be read, or a time the pending decision needs cannot be read).
  INACTIVE is a fixed rule on the settings (no `hook.agentstash.*` /
  `hook.reference-transaction.*` GIT_CONFIG key, no `ATHENA_AGENT_BIN` and no
  `ATHENA_AGENT_ENV_INSTALLED_AT`), never read from a branch's registry;
  `CLAUDE_ENV_FILE` alone, like `GIT_TRACE2`, is no trace.
  PENDING RESTART is a session started before the install: Claude Code
  hot-reloads the settings env, but the session's Bash tool need not pick up
  `CLAUDE_ENV_FILE` (`ai/lib/agent_stash_env.rb` says why), so git may not
  yet be the wrapper. It requires everything ACTIVE requires except the
  PATH, and a snapshot built before the install. The install time is
  `ATHENA_AGENT_ENV_INSTALLED_AT`, which `--install-env` writes into the
  settings env when it adds `ATHENA_AGENT_BIN` or `CLAUDE_ENV_FILE`; the
  snapshot time is in the name of the snapshot an ancestor shell sourced. Both are machine state, and either one unreadable is
  COULD NOT MEASURE. An install made before DND-1036 has no stamp, so its old
  sessions read COULD NOT MEASURE: restart them. Re-stamping such an install
  dates it now and reads every session since as pending, so do it only
  together with restarting every session. The rule and its reasons live in
  `ai/lib/agent_stash_env.rb`.

  **Later (2026-09-28, DND-1036):** a session started before
  `--install-env` read FAIL (exit 1), because its first git on PATH is not the
  wrapper. Superseded by PENDING RESTART. Measured 07:19Z-07:25Z that day:
  installing the env redded the check in every running session, so every
  harness-gate on the machine failed until a fleet-wide restart. A session
  whose snapshot was built after the install still FAILs.

  **Later (2026-09-28, DND-1080):** this bullet said the last line of
  `dotfiles/.zshrc` prepends `ATHENA_AGENT_BIN` to PATH. Superseded by
  `CLAUDE_ENV_FILE` and `ai/agent-env/session-env.sh`; the `.zshrc` line is
  removed. That line never reached the Bash tool: the shell snapshot ends with
  `export PATH=<Claude Code's own process PATH>`, so a PATH change made while
  `~/.zshrc` is sourced is discarded. Measured 09:53Z-09:55Z that day: a fresh
  headless session had `ATHENA_AGENT_BIN` set but `command -v git` =
  `/usr/sbin/git`, so activation redded every fresh session's gate. With the
  settings env carrying `CLAUDE_ENV_FILE`, a fresh session's first git is the
  wrapper. An install made before this change lacks `CLAUDE_ENV_FILE` and
  reads DRIFT; re-run `--install-env` (it adds the key and re-stamps the
  install time), then restart sessions. PENDING RESTART's reason changed with
  it: it said the old session keeps the shell snapshot built at its start,
  but the snapshot never carried the wrapper for any session.

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
  from the committed text **as landed on origin/main** (DND-792). Environment-safe:
  passes with a note when there is no inbox root and no landed entry's repo is
  checked out here (CI/agent env), so it never false-fails; a root that exists
  with no `projects/` is real drift, not "not this environment". An entry or
  channel a branch adds, retires or edits is reported as *pending* and does not
  fail; provision it after it lands, from the main checkout. A malformed branch
  `registry.json` is exit 2; a landed bar it cannot read is exit 3, could not
  measure. Under harness-gate, a live entry that drifts from the pinned bar but
  equals what a NEWER origin/main declares for it is named *ahead of the
  pinned bar* and passes. Its mode and repo identity are still checked
  (DND-1552).

  **Later (2026-09-26):** this bullet said the check compares against "the
  committed text", which was the branch's own `registry.json`. Superseded by
  DND-792, the same defect DND-743 fixed in `check-hooks-registered`. A branch
  that added a channel failed until the machine was provisioned with it, and a
  branch that removed an entry lowered its own bar.
- **Recover:** `scripts/setup-inbox-registry --install` materialises the declared
  entries, copying anything it replaces to
  `$XDG_STATE_HOME/athena/inbox-registry-backups/` first. It **merges**: it
  writes only the *entries* the committed list declares (plus the root and
  `projects/` themselves), so another project's entry is never moved or removed.
  Who may run it: `~/.claude/CLAUDE.md` → *Owner approval policy* → *Notify
  after*.
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
it per `athena:merge-boarding` (the no-CI rule there names the steps):
1. under `~/.local/state/athena/custom-merge.lock`, held around the fetch,
   rebase and push only, rebase onto `origin/main`;
2. a clean rebase: push the rebased head fast-forward to `main` as Athena,
   then release the lock; a conflicted rebase: release the lock, resolve,
   re-gate (`integration-gate --with-critic`), and start again;
3. confirm it landed (`ai/bin/confirm-merged`);
4. fast-forward the main checkout (`git merge --ff-only`);
5. run the landing's installers from the main checkout
   (`ai/bin/landing-installers`; its `--help` says which, and
   `~/.claude/CLAUDE.md` → *Owner approval policy* → *Notify after* says
   who may run them);
6. check the new `main`: `ai/bin/main-health check` (outside the lock; it is
   detection, not a merge gate).

A red `main` or a failed deploy stops the line: nothing more lands until it is
fixed. Here that is enforced: `ai/bin/main-health` gates `origin/main` after a
landing (the admiral's step 6, and the hourly shipwright tick as the
backstop), keeps a red marker under the git common dir while the tip is RED,
and alerts once per red episode on harness-alerts. While it is red,
`gh-athena git push` refuses a push to `main` except a gated fix: a head that
contains the red SHA and has its own `INTEGRATION OK` receipt. On a green
`main` too, it refuses a push to `main` whose commit integration-gate did not
pass, unless it is a clean rebase of a head it passed (DND-1690). A cron lane
therefore runs `integration-gate --with-critic --rebase` before it pushes.
`athena:merge-boarding` → the no-CI landing has the steps.

**Later (2026-10-02, DND-1664):** the steps above went from the fast-forward
straight to `main-health check`, with no installer step. A landing that added
a hook or inbox registry row then gated RED: both checks read the bar as
landed, and nothing had wired the row (DND-1653's landing, 01:17Z). Step 5
now runs `ai/bin/landing-installers` first.

**Later (2026-10-01, DND-1482):** this paragraph ended at "nothing more lands
until it is fixed", and nothing checked `origin/main` after a landing.
Superseded by `ai/bin/main-health` and the push refusal above.

**Later (2026-10-01, DND-1463):** steps 1-3 read "rebase onto
`origin/main`; re-gate the integrated head (`integration-gate`); merge, then
confirm it landed", with a re-gate after every rebase and no lock scope. Superseded by owner decision (Cody):
"I'm comfortable with the risk of multiple merges at the same time; sometimes
that will cause issues and we'll fix those asap. The velocity increase is
worth the risk of incompatible concurrent merges." "That is true for both
custom and gen_saas." A full re-gate is needed only after a conflicted rebase.

The author still never pushes to main and never merges its own PR. An
`integration-gate` exit 4 is held for the owner; it fires only for what
`~/.claude/CLAUDE.md` → *Owner approval policy* keeps.

**Later (2026-09-28):** this read "held for the owner unless a standing
approval covers it (*Standing owner approvals*)". Superseded by *Owner
approval policy*: nothing needs approval by default, and exit 4 fires only
for the items that policy keeps.

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
gates its head, lands onto current `origin/main` (re-gating only after a
conflict), and merges one MR at a time. The merge itself runs under a lock
(`athena:merge-boarding` → *Landing onto a moving main*), so the base
`locked-merge` checks is the base the merge lands on, and the landed tree can
be compared with the merge it computed. Detecting the other fleet is the wrong
question
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

**Later (2026-10-01, DND-1463):** this paragraph said each admiral "rebases
onto current `origin/main`, re-runs the gate on the **integrated** head", and
that the lock exists "because a GitHub squash onto a moved base lands an
ungated tree". Superseded by owner decision (Cody: "The velocity increase is
worth the risk of incompatible concurrent merges."): a head gated on an
ancestor of the moved main lands without a re-gate, so that tree is now
accepted. The lock keeps the merge serial and the landed tree checkable.

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

**It is enforced by `ai/hooks/worktree-escape-guard.sh`** (`PreToolUse`,
matcher `Bash|Edit|Write|MultiEdit|NotebookEdit`). It denies a write to a main
checkout's working tree, with a `Fix:` naming the worktree to use:

- **Who is guarded.** Every subagent: stdin carries `agent_id`, and the rule
  binds every spawned agent. Also an unattended top-level session whose project
  dir is a linked worktree, such as a shipwright cron lane. The attended
  top-level session is never guarded; that is the human-present exception. An
  unattended top-level session rooted in a main checkout is not guarded either;
  it was not dispatched into a worktree, and it is where a repair happens.
- **What is a main checkout.** A non-bare tree whose git dir is its common dir,
  that has a linked worktree or lives under `~/dev/`. Paths are realpath'd, so
  a write through `~/.claude/skills` counts.
- **What is denied.** A file edit of a path git does not ignore. A mutating git
  subcommand run there (`add`, `commit`, `checkout`, `restore`, `reset`,
  `merge` or `pull` without `--ff-only`, …). A redirection, `tee`, `sed -i`,
  `cp`/`mv`/`ln`/`install` destination, `mv` source, `rm`, `touch` or
  `truncate` on an unignored path.
- **What passes.** The four exceptions above as they apply to it:
  `--ff-only` publishing, gitignored runtime state, a repair from the
  top-level session, and the attended session. Also `fetch`, `worktree`, `.git`
  internals, and every read-only command. Quoted text, comments, arithmetic
  and heredoc bodies are data. The one exception is the script of
  `sh|bash|zsh|dash -c`, which is parsed as commands.
- **How it fails.** It fails open, because it is hot-loaded into every session
  on the machine. Non-JSON stdin, a git error, or a crash of the checker
  itself is allowed with a visible warning and a log line in
  `$XDG_STATE_HOME/athena/worktree-escape-guard.log`. Empty stdin, a command
  it cannot parse (`unparsed`), and a target it cannot resolve
  (`unresolved`) are allowed with a log line and no warning. A wrapper
  (`env`, `timeout`, `sudo`, …; the header lists them) is parsed from its full
  option table. An option missing from that table, or an `env -S` string that
  does not split, is logged `unparsed` and also warned about visibly.
- **It is not a sandbox.** It models the forms agents type. A write shape it
  does not model passes with no log line; the hook's header gives examples
  (an interpreter, a heredoc fed to a shell, `xargs`, `eval`, a variable not
  set in the same command).

**Later (2026-09-26, DND-840):** this paragraph said "It is currently doctrine,
not enforcement": nothing denied a write to a main checkout, and the
`PreToolUse` hook was a ticketed follow-up. Superseded by the hook above. On
2026-09-26 a captain edited `ai/agents/athena-captain.md.in` and a skill in the
main checkout. Every session loaded the half-edited skill until it reverted
them with `git checkout --`, which could have destroyed someone else's
uncommitted edits. The repository-scoped lock is still unbuilt.
