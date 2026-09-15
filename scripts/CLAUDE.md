# Scripts Directory Documentation

## Overview
This directory contains custom shell scripts and tools, with `wt` (worktree management) being the primary tool.

## WT (Worktree Management Tool)

### Purpose
`wt` is a comprehensive worktree management tool that integrates with Graphite (`gt`) for stacked PR workflows. It provides a unified interface for managing git worktrees and Graphite stacks.

### Design Principles

#### Command Structure
- **Hierarchical Commands**: Stack-related operations are grouped under `wt stack` (e.g., `wt stack move`, `wt stack parent`)
- **Consistent Interface**: All `wt` commands follow similar patterns for flags and arguments
- **Thin Wrappers**: When Graphite (`gt`) provides the needed functionality, `wt` acts as a thin wrapper
- **Custom Implementation**: Only add custom logic for worktree-specific features or enhanced UX

#### Integration with Graphite
- **Delegation Pattern**: Commands delegate to `gt` when possible:
  - `wt stack move --onto` → `gt move --onto`
  - `wt stack reorder` → `gt reorder`
  - `wt continue` → `gt continue`
  - `wt modify` → `gt modify`
- **Skip Internal Branches**: Filter out `graphite-base/*` branches (Graphite's internal merge bases)
- **Track Before Parent**: Always ensure branches are tracked by Graphite before setting parents

#### Worktree Management
- **No Automatic Switching**: Never automatically switch worktrees unless `--switch` flag is provided
- **Preserve Context**: Users stay in their current worktree during operations
- **Explicit Control**: Worktree changes require explicit user action

#### Conflict Resolution
- **Unified Interface**: Use `wt continue` to resume any paused operation
- **Clear Messaging**: Display "Conflicts detected. Resolve conflicts and run `wt continue`"
- **Stay in Place**: Don't auto-switch to conflicted branch's worktree
- **Helper Commands**: Remind users they can use `wt switch <branch>` if needed

#### Error Handling
- **Exit Codes**: Use consistent, meaningful exit codes:
  - 0: Success
  - 1: General error or missing required argument
  - 2: Operation-specific error (e.g., cannot close main/master)
  - 3: Context error (e.g., wrong worktree for operation)
- **Descriptive Messages**: Error messages go to stderr with clear explanations

#### Visual Feedback
- **Show Stack Structure**: Display before/after state for stack operations
- **Reuse Existing Display**: Use `wt stack` visualization for consistency
- **Progress Indicators**: Show what's happening during long operations

#### Safety and Preview
- **Dry-run Support**: Add `--dry-run` where feasible to preview operations
- **No Unnecessary Warnings**: Trust users, don't add confirmation prompts
- **Fail Fast**: Exit early with clear errors rather than proceeding unsafely

### Command Patterns

#### Sub-command Pattern
Commands that operate on the stack use the sub-command pattern:
```bash
wt stack <subcommand> [args] [options]
```

Examples:
- `wt stack move --onto <branch>`
- `wt stack parent <new-parent>`
- `wt stack open <branch>`
- `wt stack reorder`

#### Flag Conventions
- `--switch`: Explicitly switch to a different worktree
- `--quiet`: Suppress non-error output
- `--dry-run`: Preview what would happen without making changes
- `--all`: Apply operation to all applicable items
- `--restack`: Trigger restacking after operation
- `--parent`: Specify parent branch for operations
- `--insert`: Insert in the middle of a stack (for create command)

### Implementation Guidelines

#### Adding New Commands
1. Determine if it should be a sub-command of `wt stack` or top-level
2. Check if Graphite provides the functionality (prefer delegation)
3. Add worktree-specific enhancements only where needed
4. Update completions in `.auto-completions/_wt`
5. Document in usage/help text

#### Testing Approach
- Test with both tracked and untracked branches
- Test conflict scenarios
- Verify exit codes match specifications
- Ensure quiet mode suppresses all non-error output
- Test from both main branch and worktree contexts
- Test with `graphite-base/*` branches present

#### Environment Variables
- `WORKTREES_BASE`: Base directory for worktrees (default: `~/.local/worktrees`)
- `QUIET`: Set to true to suppress output (used internally)
- `CHECK_DIR`: Override directory for worktree checks (used internally)

## Other Scripts

### add-notion
Registers a Notion MCP server for the **current project** at local scope, using
the shared Athena API-key wrapper (`ai/bin/notion-athena-mcp`). Each mode maps
to a fixed server name and token file:

| Mode | Server | Token file | Workspace |
|------|--------|-----------|-----------|
| `--personal` / `-p` | `notion-personal` | `~/.claude/notion-personal-token` | "Cody" (personal) |
| `--work` / `-w` | `notion-work` | `~/.claude/notion-amby-token` | "Amby AI" (work) |

With no mode flag it shows an interactive menu (↑/↓, `j`/`k`, `d`/`e`, Enter;
`q` cancels). It's a thin, idempotent wrapper over `claude mcp add <server> -s
local` — safe to re-run to update an entry. `--dry-run` prints the command
without running it.

**Design rationale.** Personal and work Notion are separate Athena bot
Connections (distinct names, never one shadowing the other). Nothing is set at
user scope: each project explicitly adds only the Notion it needs. Distinct
names fail safe — a project missing its server makes a call fail loudly rather
than silently hitting the wrong workspace.

**Launch-dir rule.** Local-scope MCP servers resolve from the directory where
`claude` was started; subagents/coordinators operating in worktrees still use
the launching session's servers. So run `add-notion` from the project's **main
checkout** (where you start `claude`), not a worktree — a warning fires if it
detects a worktree. Onboarding a new work account: create its Notion
Connection, share pages with it, save the secret to a token file, then extend
the mode map near the top of the script.

### General Guidelines
- Scripts should be self-documenting with clear usage information
- Use consistent error handling and exit codes
- Prefer POSIX-compatible shell when possible
- Add completions for complex scripts

### Integration
- Scripts can call each other but should handle missing dependencies gracefully
- Use absolute paths when calling other scripts from this directory
- Check for required tools at startup and provide helpful error messages

### Bluetooth Diagnostics

Three scripts for tracking Bluetooth disconnects and their cause. They read
`/var/log/kern.log*` and `/var/log/syslog*`, which needs the `log` group.

- `bt-crash-report` - Summarizes controller firmware crashes
  (`Bluetooth: hci0: Hardware error`) from the logs: counts per day, resume
  correlation, and per-crash context (bluetoothd messages, which device
  reconnected). Use it to compare crash rates before/after a firmware or
  kernel change: `bt-crash-report --days 2`.
- `bt-watch` - Long-running watcher that logs every connect/disconnect from
  BlueZ (system D-Bus) plus kernel crash/resume/WiFi-reset lines to
  `~/.local/state/bt-watch/events.log`, tagging disconnects as
  `cause=firmware-crash` or `cause=normal`. Start from Hyprland with
  `exec-once = bt-watch --notify --quiet`; read with `bt-watch --tail`.
- `bt-trace` - Prints the HCI trace around a moment (default: the latest
  crash) from the captures written by the `btmon` OpenRC service in
  `system-files/`. `bt-trace --exceptions` tabulates every captured
  crash with its exception words, for comparing crashes across firmware
  builds. This is the only view of *what the controller was doing*
  right before it crashed, since the btintel driver fails to fetch the
  firmware's exception record.
- `bt-setup` - Runs the root-needing steps for you: `bt-setup service`
  installs and starts the btmon capture service, `bt-setup firmware <build>`
  swaps the AX210 Bluetooth firmware between known Intel builds (with
  `--restore` to undo), `bt-setup status` shows what is loaded and running.
  `--dry-run` prints the commands instead.

### desktop

Mounts the desktop's (`home-office-linux`, ssh alias `desktop`) home directory
at `~/mnt/desktop` over sshfs on demand — `desktop mount` / `desktop unmount`
— and `desktop open <path>` mounts if needed and opens the file in Firefox.
The mount sits under `$HOME` so the flatpak Firefox sandbox can read it — but
only a Firefox started *after* the mount: a sandbox snapshots the mount table
at launch. `desktop status`/`mount`/`open` warn when the running Firefox
predates the mount; `--restart-firefox` restarts it.
Requires `net-fs/sshfs`.
