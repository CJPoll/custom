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

### Shipwright commit discipline (`athena-shipwright-commit.sh`)

The shipwright is an autonomous committer on an hourly cron, in a checkout a
human or another agent may be typing in. Two guards keep it from absorbing
somebody else's work, and **neither may be weakened**:

- `athena-shipwright-commit.sh` is the only sanctioned way the shipwright
  commits. It takes an explicit list of individual **files** after `--`, and
  refuses every other shape **as a class**, never by enumerating spellings:
  the plain catch-alls (`.`, `-A`, absolute paths, `..` escapes), any magic
  pathspec (anything starting with `:` — `:/`, `:(top)`, `:(glob)**`, `:!x` all
  mean "everything" to git), any **glob** (`*`, `?`, `[` — `ai/*` passes every
  other check and stages the whole subtree), and any **directory** (`git add --
  hypr` reproduces the original incident exactly). Paths and the `-F` message
  file resolve against the **caller's** cwd, not the repo root. It stages only those
  paths, then commits **pathspec-limited** (`git commit -- <paths>`) so even
  content another session staged into the index between the `add` and the
  `commit` cannot ride along. Foreign dirt is reported by **path-set
  difference** — never a line-count subtraction, which an untracked directory
  silently zeroes out — and is never touched and never a reason to abort:
  aborting would discard a run's real work, while the pathspec limit already
  makes the commit safe. Exit codes: `1` git refused, `2` bad arguments, `3` the
  named paths contain nothing to commit.
- `athena-shipwright-run.sh` **yields the tick** when the worktree is dirty:
  exit 0, a `Fix:` line on stderr (cron mails it) and a `.skipped` record beside
  the run logs. This exists for a hazard narrowed staging does *not* cover — the
  run's first act is `git pull --rebase --autostash`, which stashes and re-applies
  a concurrent editor's work underneath them. Untracked strays count as dirt (the
  file swept in the real incident was untracked). Override with
  `SHIPWRIGHT_ALLOW_DIRTY=1` when you know the dirt is inert.
  **A wedged lane does not look like a quiet one**: after
  `SHIPWRIGHT_SKIP_ESCALATE` consecutive skips (default 6, i.e. six hours) the
  skip exits **75** instead of 0, so a stray file nobody clears becomes a loud
  cron failure rather than an hourly silence indistinguishable from "nothing to
  do". Any run that actually starts resets the counter, so a passing editor
  never accumulates into a false alarm. `ai-artifacts/` is excluded from the
  dirt check **explicitly**, not via an ignore rule — it holds the runner's own
  logs, `run.lock` and `.skipped` records, and is gitignored only by the user's
  machine-local `~/.config/git/gitignore`, which is not in this repository.

**The repository-scoped lock is NOT in place, and that is a decision.** What
exists is: a runner `flock` (cron-vs-cron), and a commit helper whose
pathspec limit makes a concurrent writer's work unreachable whichever entry
point started the agent. What does **not** exist is a lock every writer takes
for the length of a run. Building one means choosing where it is taken, and
there is no honest choice available today: the runner is the wrong place (a
directly-invoked agent skips it), and the commit helper can only cover its own
stage-and-commit critical section, not the `pull --rebase --autostash → edit →
commit → push` span where the real interleaving happens. Covering that span
requires the agent's cooperation — which is prose, i.e. advisory — or a
`PreToolUse` hook, which is the same enforcement mechanism invariant 8 is
waiting on. So it is one ticket: **a repo-scoped lock and the hook that makes
it unavoidable**, together. A lock shipped before that hook would serialise the
paths that already do not fail and read, to anyone glancing at it, as "this is
handled".

**Which guard covers which entry point.** The commit helper is
entry-point-independent: the shipwright uses it whether cron started it or a
human invoked the agent directly. The runner's two guards — the `flock` and the
dirty-tree yield — cover the **cron path only**, because a directly-invoked
agent never runs that script. On 2026-09-18 at 21:00 exactly that happened: a
directly-invoked shipwright ran alongside the cron run, and nothing in the
harness serialised them (the second agent blocked on the first by its own
judgement). **A repository-level lock — one every writer takes, not one per
entry point — is the real fix, and is deliberately left to its own ticket**; a
half-measure lock on the runner would look like coverage while leaving the agent
path open. Related: `run.lock` is held via `flock(2)` on an open descriptor, so
an empty, apparently-stale `run.lock` on disk is normal and proves nothing about
whether a run is live. Never delete it to "clean up" — that hands the next
invocation a fresh inode and a lock that excludes nobody.

Why: on 2026-09-18T21:03:07 a run staged the whole worktree while another agent
was mid-edit and swept an unrelated `hypr/hyprland.conf` change plus a 230-line
`.bak` into `ce70e04`, a commit whose message is entirely about harness-gate
self-tests. The other agent caught it by hand.

`scripts/test/athena-shipwright/self-test.sh` covers both guards (run it
directly, or `scripts/athena-shipwright-commit.sh --self-test`). It builds
throwaway repos and stubs `claude`, so no real repo, crontab, network or token
is touched.

`harness-gate` runs it automatically and needs **no wiring**: since DND-209
(`880fe12`) the gate DISCOVERS every tracked `**/self-test.sh` — globbed and
intersected with `git ls-files` — instead of requiring a declaration. This
suite is at `scripts/test/athena-shipwright/self-test.sh`, so it matches by
being what it is rather than by being registered. Verified: 17/17 PASS, 5
suites discovered, this one among them.

The discovery contract is that exact filename. A suite named anything else is
invisible to the gate — so if you add cases here, add them to this file rather
than beside it.

### Athena inbox client supervision

Keeps the Athena inbox client (the process that appends Slack/agent-mail
deliveries to `~/.local/share/athena/*.jsonl`) alive on this OpenRC host. There
is no `systemd --user` here and `/etc/init.d` needs root, so the arrangement is
**user crontab + a supervising wrapper** — the same shape as the shipwright
loop above.

- `athena-inbox-client-run.sh` — the supervisor. Holds an `flock` on its pidfile
  for the whole supervised lifetime, so a second invocation exits 0 silently;
  that is what makes the `*/5` relaunch entry a free safety net rather than a
  machine for creating a second writer on an inbox the delivery contract says
  has exactly one consumer. It runs `~/.local/bin/athena-inbox-client`, which
  pins the **absolute** Ruby 3.3.0 path — never the asdf shim, which cron's
  minimal environment cannot resolve (the bug `b5073fc` fixed for the shipwright
  runner).
  **Exit 2 is a full stop, not a retry.** It is the client's deliberate
  partial-write exit: an inbox file ends in a fragment and the un-acked event is
  re-pushed in full on reconnect, so relaunching appends a complete line after
  the fragment and corrupts the file. The supervisor writes
  `~/.local/state/athena-inbox-client.stopped` and refuses to start — on this
  and every later invocation — until a human deletes the fragment and removes
  the marker. Any other non-zero exit relaunches with capped exponential
  backoff. SIGTERM/SIGINT reap the client and stop the supervisor — but once the
  crontab entries are installed that stops only *that* supervisor, since the
  `*/5` line starts a new one within five minutes. **To stop the service, run
  `--remove` first, then kill the pid.** Do not repurpose the `.stopped` marker
  as an off switch: it means "an inbox file is corrupt", and overloading it
  makes a real partial write indistinguishable from a deliberate stop.
  A `kill -9` skips the reaper and orphans the client; the next supervisor
  detects the orphan by its recorded pid and terminates it before starting a
  new one, so the inbox never gets a second writer.
  The log is trimmed only *between* client runs — a healthy client never exits,
  so `MAX_LOG_LINES` bounds a crash-looping client rather than the steady state.
  Rotate out of band (logrotate `copytruncate`) if the steady-state log ever
  needs bounding.
- `setup-athena-inbox-client` — the committed idempotent installer:
  `--install` (default) · `--check` · `--dry-run` · `--remove` · `--self-test` ·
  `-h`, order-independent. It installs `@reboot` and `*/5 * * * *` entries,
  editing the crontab read-modify-write and filtering its own runner path out
  before re-appending, so unrelated entries (notably the shipwright's hourly
  line) survive install and remove. `--check` is read-only and safe for an agent
  or CI: `OK` and exit 0, or `MISSING` plus a `Fix:` line and exit 1.
- `test/athena-inbox-client/` — the self-test (QA plan I-8 … I-11) and its
  `SABOTAGE_RECORDS.md`. The suite never opens a socket (the client is a stub)
  and never touches the real crontab (`crontab(1)` is a PATH shim over a
  tmpfile).

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

### Athena user provisioning

Two root-run, idempotent scripts that stand up the `athena` system user (a
non-root user with no sudo/wheel). Provide instructions/execution for the
system-level steps; safe to re-run.

- `setup-athena-user` - Creates `athena` (home `/home/athena` on a dedicated
  btrfs subvolume, bash shell, no sudo), applies a 250 GB btrfs qgroup quota to
  her home, and caps her total RAM at 16 GB via cgroup v2 + libcgroup
  `cgrulesengd`. Asserts she is never in `wheel`/`sudo`.
- `setup-athena-docker` - Gives athena **rootless** Docker (deliberately NOT the
  root-equivalent `docker` group). Accepts the `~amd64` keyword for
  `sys-apps/rootlesskit`, emerges `rootlesskit` + `slirp4netns` +
  `fuse-overlayfs`, enables lingering, and installs the
  `docker-rootless-athena` OpenRC service (from `system-files/`) that runs her
  daemon at boot. Run `setup-athena-user` first. `--dry-run` previews.

### Self-hosted CI runner provisioning (`setup-{github,gitlab}-runner*`)

Two parallel families of root-run, idempotent scripts stand up a self-hosted CI
runner as its **own** non-root user with its **own** rootless Docker, isolated
from your account and from each other. Run them in order; each `--dry-run`
previews.

- **GitHub Actions** (serves the `gen_saas` GitHub repo): `setup-github-runner-user`
  → `setup-github-runner-docker` → `setup-github-runner`.
- **GitLab CI** (serves the `walt_ui` gitlab.com project, with gitlab.com shared
  runners as fallback): `setup-gitlab-runner-user` → `setup-gitlab-runner-docker`
  → `setup-gitlab-runner`. The GitLab runner uses the **docker executor** (each
  job runs in a container, so the host needs no node/jq toolchain and no .NET/ICU
  workaround), `privileged = false`, and builds images with **rootless BuildKit**
  (`moby/buildkit:rootless`, no privileged) so the same untagged job runs on both
  the self-hosted runner and gitlab.com SaaS. Architecture + the Cody-runs enable
  steps + the walt_ui `.gitlab-ci.yml` `buildctl` rewrite spec live in
  **`system-files/gitlab-runner-runbook.md`** (DND-177).

Both runner users get a non-overlapping subuid/subgid block (athena `165536`,
github-runner `231072`, gitlab-runner `296608`, each `:65536`). Neither is ever in
`wheel`/`sudo`/`docker` — the setup scripts assert it. Registration (a repo/project
token) and the actual `sudo` install are **yours to run**; the scripts install the
OpenRC service but never start it until a runner is registered.
