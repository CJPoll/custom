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

dunstify \
  -u critical \
  -a "Claude Code" \
  -i "dialog-information" \
  "Claude Code — Idle" \
  "Project: ${project}\nWorktree: ${worktree}"
