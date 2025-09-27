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

        # Replace slashes in branch name with dashes to avoid tmux issues
        local safe_branch=$(echo "$branch" | tr '/' '-')
        local session_name="${project_name}-wt-${safe_branch}"

        # Check if session already exists
        if tmux has-session -t "$session_name" 2>/dev/null; then
            # Attach to existing session
            log "Attaching to existing tmux session: $session_name"

            if [ -n "$TMUX" ]; then
                # If we're inside tmux, switch to the session
                tmux switch-client -t "$session_name"
            else
                # If we're outside tmux, attach
                tmux attach-session -t "$session_name"
            fi
        else
            # Create new session
            log "Creating new tmux session: $session_name"

            # First, source bashrc or zshrc to ensure the session has proper env
            local shell_config=""
            if [ -n "$ZSH_VERSION" ]; then
                shell_config="$HOME/.zshrc"
            elif [ -n "$BASH_VERSION" ]; then
                shell_config="$HOME/.bashrc"
            fi

            # Create the session detached, starting in the worktree directory
            tmux new-session -d -s "$session_name" -c "$worktree_dir"

            # Set up the initial window with a meaningful name
            tmux rename-window -t "$session_name:0" "main"

            # Create additional windows as needed
            tmux new-window -t "$session_name:1" -n "git" -c "$worktree_dir"
            tmux new-window -t "$session_name:2" -n "test" -c "$worktree_dir"

            # Set some useful environment variables in the session
            tmux send-keys -t "$session_name:0" "export WT_BRANCH='$branch'" C-m
            tmux send-keys -t "$session_name:0" "export WT_PROJECT='$project_name'" C-m
            tmux send-keys -t "$session_name:0" "clear" C-m

            # Display branch info in the first window
            tmux send-keys -t "$session_name:0" "echo '━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━'" C-m
            tmux send-keys -t "$session_name:0" "echo 'Worktree: $branch'" C-m
            tmux send-keys -t "$session_name:0" "echo 'Project:  $project_name'" C-m
            tmux send-keys -t "$session_name:0" "echo 'Path:     $worktree_dir'" C-m
            tmux send-keys -t "$session_name:0" "echo '━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━'" C-m
            tmux send-keys -t "$session_name:0" "echo ''" C-m

            # If we have graphite, show the stack
            if command -v gt &>/dev/null; then
                tmux send-keys -t "$session_name:0" "gt ls" C-m
            fi

            # Select the first window
            tmux select-window -t "$session_name:0"

            # Attach to the new session
            if [ -n "$TMUX" ]; then
                # If we're inside tmux, switch to the session
                tmux switch-client -t "$session_name"
            else
                # If we're outside tmux, attach
                tmux attach-session -t "$session_name"
            fi
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

        if tmux has-session -t "$session_name" 2>/dev/null; then
            log "Killing tmux session: $session_name"
            tmux kill-session -t "$session_name"
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