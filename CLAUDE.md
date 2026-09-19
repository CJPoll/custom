# Custom Tools Repository

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
  `athena-inbox.md`, the local multi-tenant message facility)
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
`ai-artifacts/shipwright/journal.md`, specs, ADRs, and cross-references between
skills/agents. (Conventions adapted from riddler's howie/wurk harness.)

- **Cite a skill's or document's steps by NAME, not by number.** Write
  "`processes:fix`'s command-resolution step", not "`processes:fix` step 2". A
  number is a position: insert a step above it and every external citation below
  silently points at the wrong place, and nothing checks it. A name survives
  renumbering and a stale one is greppable. Numbers inside a file's own body are
  fine (a renumber edits that file anyway); a number outside follows the name as
  decoration only ("the command-resolution step, currently step 2").
- **Never rewrite a dated document to match later reality; ANNOTATE it.** A
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
- **Editing hooks:** change `registry.json` and run `scripts/setup-hooks
  --install`; do not hand-write the `settings.json` hooks block (that is the
  clobber path). Hooks load at session start, so reload a session to activate.
