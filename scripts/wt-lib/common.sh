#!/bin/bash
# common.sh - Common utility functions for wt scripts
# This file is meant to be sourced, not executed directly

# Prevent direct execution
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    echo "Error: This script is meant to be sourced, not executed directly" >&2
    exit 1
fi

if [[ -z "${WT_LIB_COMMON_SOURCED:-}" ]]; then
  WT_LIB_COMMON_SOURCED="true"
  # Configuration variables
  # These can be overridden by setting them before sourcing this file

  # Determine if we're in a worktree and find the actual project root
  CURRENT_DIR="${CURRENT_DIR:-$(pwd)}"
  PROJECT_DIR="${PROJECT_DIR:-$CURRENT_DIR}"

  # Check if we're in a worktree by looking for .git file (not directory)
  if [ -f "$CURRENT_DIR/.git" ]; then
      # We're in a worktree, extract the actual project path
      GIT_DIR=$(cat "$CURRENT_DIR/.git" | grep "gitdir:" | cut -d' ' -f2)
      # Git dir for worktree looks like: /path/to/project/.git/worktrees/branch-name
      # We need to go up 3 levels to get the project root
      PROJECT_DIR=$(dirname $(dirname $(dirname "$GIT_DIR")))
  fi

  # Extract just the project name from the path
  PROJECT_NAME="${PROJECT_NAME:-$(basename "$PROJECT_DIR")}"
  WORKTREES_DIR="${WORKTREES_DIR:-${HOME}/.local/worktrees/$PROJECT_NAME}"

  # Global flags
  QUIET="${QUIET:-false}"

  # Logging function
  log() {
      if [ "$QUIET" = false ]; then
          echo "$@" >&2
      fi
  }

  # Run command with optional quiet mode
  run_cmd() {
      if [ "$QUIET" = true ]; then
          "$@" >/dev/null 2>&1
      else
          "$@"
      fi
  }

  # Check if Graphite (gt) is available
  check_graphite() {
      if ! command -v gt &>/dev/null; then
          echo "Error: Graphite (gt) is required for this operation" >&2
          echo "Install with: brew install graphite or visit https://graphite.dev" >&2
          return 1
      fi
      return 0
  }

  # Check if we're in a git repository
  check_git_repo() {
      if ! git rev-parse --git-dir &>/dev/null; then
          echo "Error: Not in a git repository" >&2
          return 1
      fi
      return 0
  }

  # Get the current branch name
  get_current_branch() {
      git rev-parse --abbrev-ref HEAD 2>/dev/null
  }

  # Check if a branch exists locally
  branch_exists_locally() {
      local branch="$1"
      git show-ref --verify --quiet "refs/heads/$branch"
  }

  # Check if a branch exists on remote
  branch_exists_on_remote() {
      local branch="$1"
      git show-ref --verify --quiet "refs/remotes/origin/$branch"
  }

  # Initialize Graphite in a worktree
  init_graphite_worktree() {
      local worktree_path="$1"

      if command -v gt &>/dev/null; then
          # Determine trunk branch (main or master)
          local trunk_branch="main"
          if ! branch_exists_locally "main"; then
              if branch_exists_locally "master"; then
                  trunk_branch="master"
              fi
          fi

          # Initialize gt silently
          gt -C "$worktree_path" repo init --trunk "$trunk_branch" -q &>/dev/null 2>&1 || true

          # Symlink .graphite_repo_config if it exists in main project
          if [ -f "$PROJECT_DIR/.git/.graphite_repo_config" ] && [ ! -e "$worktree_path/.git/.graphite_repo_config" ]; then
              ln -s "$PROJECT_DIR/.git/.graphite_repo_config" "$worktree_path/.git/.graphite_repo_config" &>/dev/null 2>&1 || true
          fi
      fi
  }
fi
