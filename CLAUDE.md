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
~/CLAUDE.md -> ~/dev/custom/ai/CLAUDE.md
```

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
ln -sf ~/dev/custom/ai/CLAUDE.md ~/CLAUDE.md

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
  `athena-inbox.md`, the local multi-tenant message facility). A project opts
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
- Support `--help` where appropriate

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

## Guard/error messages are written for the LLM

Every first-party guard, hook, check, or gate-wrapper that can DENY or FAIL must
tell the agent HOW TO SELF-CORRECT, not just that it failed. (Convention adapted
from riddler's howie/wurk harness — "errors written for the LLM.")

- The failure/deny output carries the greppable marker **`Fix:`** followed by an
  actionable instruction: what to change so the next attempt passes. Exemplars:
  `ai/bin/check-generic-skills`, `ai/hooks/safe-wait-guard.sh`,
  `ai/hooks/pronoun-guard.sh`.
- A script with no deny/failure path (a context injector, a notifier) is exempt;
  record it in `EXEMPT` in `ai/bin/check-guard-messages` with a reason.
- `ai/bin/check-guard-messages` enforces this (part of the shipwright gate); a
  new hook is covered by default, so a bare failure message turns the gate red.

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
at `~/.local/worktrees/<project>/<branch>`, while a robot's own persistent tree
belongs somewhere nobody will wander into — the shipwright's lives inside
`.git/`). This is the same discipline captains have always had; it is now the
rule for every agent, including the unattended ones that had quietly been
exempt.

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
