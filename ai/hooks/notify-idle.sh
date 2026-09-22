#!/usr/bin/env bash
# Claude Code "Stop" hook — sends a persistent dunst notification
# when an agent goes idle, showing project and worktree info.

set -euo pipefail

cwd="$(pwd)"
home="$HOME"

# Derive project and worktree from the working directory.
#   ~/dev/<project>                             → project=<project>, worktree=main checkout
#   ~/.local/worktrees/<project>/<branch>       → project=<project>, worktree=<branch>
project=""
worktree=""

worktree_prefix="${home}/.local/worktrees/"
dev_prefix="${home}/dev/"

if [[ "$cwd" == "${worktree_prefix}"* ]]; then
  # Strip the prefix: <project>/<branch...>
  # Branch names can contain slashes, so worktree is everything after project.
  relative="${cwd#"$worktree_prefix"}"
  project="${relative%%/*}"
  worktree="${relative#*/}"
elif [[ "$cwd" == "${dev_prefix}"* ]]; then
  relative="${cwd#"$dev_prefix"}"
  project="${relative%%/*}"
  worktree="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "main")"
else
  # Fallback: use directory name and git branch
  project="$(basename "$(git rev-parse --show-toplevel 2>/dev/null || echo "$cwd")")"
  worktree="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")"
fi

# dunstify is a libnotify/D-Bus client. When this hook runs with a graphical
# DISPLAY (e.g. leaked from the login-shell snapshot Claude Code's Bash tool
# sources) but no DBUS_SESSION_BUS_ADDRESS (a cron-launched session), libdbus
# AUTOLAUNCHES a throwaway `dbus-daemon --syslog-only --fork ... --session` that
# never exits — the leak that exhausted the inotify instance limit. Setting the
# address (to a real session bus if one is discoverable, else an unconnectable
# sentinel) stops the autolaunch: with a real bus the notification still
# reaches the user; otherwise dunstify just fails fast (guarded below). See
# scripts/lib/dbus-env.sh.
__notify_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")" && pwd -P)"
if [ -r "${__notify_dir}/../../scripts/lib/dbus-env.sh" ]; then
  # shellcheck source=../../scripts/lib/dbus-env.sh
  . "${__notify_dir}/../../scripts/lib/dbus-env.sh"
  athena_dbus_env_setup || true
fi

# The attendant runs headless in tmux with no display, where dunstify fails; the
# notification is best-effort and must never fail the hook (which would surface
# an error on every attended turn), so it is guarded.
dunstify \
  -u critical \
  -a "Claude Code" \
  -i "dialog-information" \
  "Claude Code — Idle" \
  "Project: ${project}\nWorktree: ${worktree}" 2>/dev/null || true
