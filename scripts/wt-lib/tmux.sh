#!/bin/bash
# tmux.sh - Tmux integration for wt scripts
# This file is meant to be sourced, not executed directly

# Prevent direct execution
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    echo "Error: This script is meant to be sourced, not executed directly" >&2
    exit 1
fi

# Include guard to prevent multiple sourcing
if [[ -z "${WT_LIB_TMUX_SOURCED:-}" ]]; then
    WT_LIB_TMUX_SOURCED="true"

    # Source dependencies
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    source "${SCRIPT_DIR}/common.sh"
    source "${SCRIPT_DIR}/worktree.sh"

    create_tmux_session_for_worktree() {
        local branch="$1"
        local worktree_dir="$2"
        local project_name="$3"
        local attach="${4:-true}"  # Default to attaching unless explicitly told not to

        # Check if proj command is available
        if ! command -v proj &>/dev/null; then
            echo "Error: proj command not found" >&2
            echo "Make sure proj is in your PATH" >&2
            return 1
        fi

        # Replace slashes in branch name with dashes to avoid tmux issues
        local safe_branch=$(echo "$branch" | tr '/' '-')
        local session_name="${project_name}-wt-${safe_branch}"

        # Check if session already exists (use exact matching with = prefix)
        if tmux has-session -t "=$session_name" 2>/dev/null; then
            # Session exists, only attach if requested
            if [ "$attach" = "true" ]; then
                log "Attaching to existing tmux session: $session_name"

                if [ -n "$TMUX" ]; then
                    # If we're inside tmux, switch to the session
                    tmux switch-client -t "=$session_name"
                else
                    # If we're outside tmux, attach
                    tmux attach-session -t "=$session_name"
                fi
            else
                log "Tmux session already exists: $session_name"
            fi
        else
            # Create new session using proj
            log "Creating new tmux session: $session_name"

            # Use proj to create the session with --no-switch to prevent attaching
            # proj expects the session name to be derived from the project name
            # We'll use --path to point to the worktree directory
            if [ "$attach" = "true" ]; then
                proj "$session_name" --path "$worktree_dir"
            else
                proj "$session_name" --path "$worktree_dir" --no-switch
            fi

            # Set environment variables using tmux's setenv
            tmux setenv -t "$session_name" WT_BRANCH "$branch"
            tmux setenv -t "$session_name" WT_PROJECT "$project_name"
        fi
    }

    # Helper function to check if tmux is available
    check_tmux() {
        if ! command -v tmux &>/dev/null; then
            return 1
        fi
        return 0
    }

    # Kill tmux session for a worktree
    kill_tmux_session_for_worktree() {
        local branch="$1"
        local project_name="$2"

        # Replace slashes in branch name with dashes to avoid tmux issues
        local safe_branch=$(echo "$branch" | tr '/' '-')
        local session_name="${project_name}-wt-${safe_branch}"

        if tmux has-session -t "=$session_name" 2>/dev/null; then
            log "Killing tmux session: $session_name"
            tmux kill-session -t "=$session_name"
        fi
    }

    # List all worktree tmux sessions
    list_worktree_tmux_sessions() {
        local project_name="$1"

        if ! check_tmux; then
            echo "tmux is not installed" >&2
            return 1
        fi

        local sessions=$(tmux list-sessions -F "#{session_name}" 2>/dev/null | grep "^${project_name}-wt-" || true)

        if [ -z "$sessions" ]; then
            echo "No worktree tmux sessions found for project: $project_name"
            return 0
        fi

        echo "Worktree tmux sessions for $project_name:"
        echo "$sessions" | while read -r session; do
            # Extract branch name from session name
            local branch="${session#${project_name}-wt-}"
            # Convert dashes back to slashes for display
            branch=$(echo "$branch" | tr '-' '/')
            echo "  - $branch (session: $session)"
        done
    }

fi # End of include guard