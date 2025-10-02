#!/bin/bash
# close.sh - Branch closing and worktree reset functions for wt scripts
# This file is meant to be sourced, not executed directly

# Prevent direct execution
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    echo "Error: This script is meant to be sourced, not executed directly" >&2
    exit 1
fi

# Include guard to prevent multiple sourcing
if [[ -z "${WT_LIB_CLOSE_SOURCED:-}" ]]; then
    WT_LIB_CLOSE_SOURCED="true"

    # Source dependencies
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    source "${SCRIPT_DIR}/common.sh"
    source "${SCRIPT_DIR}/worktree.sh"

    close_branch() {
        local branch="$1"
        local close_all=false

        # Check for --all flag
        if [ "$branch" = "--all" ]; then
            close_all=true
        fi

        if [ "$close_all" = true ]; then
            # Check if we're in the main branch worktree
            set +e
            (
                CHECK_DIR="$(pwd)"
                is_worktree
            )
            local is_wt_result=$?
            set -e

            if [ $is_wt_result -ne 1 ]; then
                echo "Error: 'wt close --all' must be run from the main branch worktree" >&2
                return 3
            fi

            # Get ALL local branches (not just those with worktrees)
            local all_branches=$(git for-each-ref --format='%(refname:short)' refs/heads/)
            local branches_to_close=()

            # Filter out main/master branches
            for branch in $all_branches; do
                if [ "$branch" != "main" ] && [ "$branch" != "master" ]; then
                    branches_to_close+=("$branch")
                fi
            done

            # Close each branch silently
            for branch_to_close in "${branches_to_close[@]}"; do
                # Call the internal close logic directly, ignore errors
                _close_single_branch "$branch_to_close" || true
            done

            # Success - no output
            return 0
        fi

        if [ -z "$branch" ]; then
            echo "Error: Branch name is required" >&2
            return 1
        fi

        # Prevent closing main/master branches
        if [ "$branch" = "main" ] || [ "$branch" = "master" ]; then
            echo "Error: Cannot close main/master branch" >&2
            return 2
        fi

        # Use the internal function for single branch close
        _close_single_branch "$branch"
    }

    _close_single_branch() {
        local branch="$1"

        # Check if branch exists locally
        if ! branch_exists_locally "$branch"; then
            # Silently exit with success if branch doesn't exist
            return 0
        fi

        # Kill tmux session if it exists (even without worktree)
        local project_name=$(basename "$PROJECT_DIR")
        local safe_branch=$(echo "$branch" | tr '/' '-')
        local session_name="${project_name}-wt-${safe_branch}"

        if tmux has-session -t "$session_name" 2>/dev/null; then
            tmux kill-session -t "$session_name" 2>/dev/null || true
        fi

        # Remove worktree if it exists (silently)
        local worktree_path="$WORKTREES_DIR/$branch"
        if [ -d "$worktree_path" ]; then
            # Temporarily set QUIET to true to suppress remove_worktree output
            local orig_quiet="$QUIET"
            QUIET=true
            remove_worktree "$branch"
            QUIET="$orig_quiet"
        fi

        # Delete the local branch (silently)
        if ! git branch -D "$branch" >/dev/null 2>&1; then
            if [ "$QUIET" = false ]; then
                echo "Error: Failed to delete branch '$branch'" >&2
                echo "Branch may be checked out in current directory" >&2
            fi
            return 1
        fi

        # Success - no output
        return 0
    }

    reset_worktrees() {
        log "Resetting all worktrees for $PROJECT_NAME..."

        # Get list of all worktrees
        local git_worktrees=$(git worktree list --porcelain 2>/dev/null || echo "")

        if [ -z "$git_worktrees" ]; then
            log "No worktrees found to reset."
            return 0
        fi

        local branches_to_close=()
        local worktree_path=""
        local branch=""

        # Parse worktree list to get branches
        while IFS= read -r line; do
            if [[ "$line" =~ ^worktree[[:space:]](.+) ]]; then
                # Process previous worktree if exists
                if [ -n "$worktree_path" ] && [ -n "$branch" ]; then
                    # Only consider worktrees in our worktrees directory (not main project)
                    if [[ "$worktree_path" == "$WORKTREES_DIR/"* ]]; then
                        # Skip main/master branches
                        if [ "$branch" != "main" ] && [ "$branch" != "master" ]; then
                            branches_to_close+=("$branch")
                        fi
                    fi
                fi

                # Reset for new worktree
                worktree_path="${BASH_REMATCH[1]}"
                branch=""
            elif [[ "$line" =~ ^branch[[:space:]]refs/heads/(.+) ]]; then
                branch="${BASH_REMATCH[1]}"
            fi
        done <<< "$git_worktrees"

        # Process last worktree
        if [ -n "$worktree_path" ] && [ -n "$branch" ]; then
            if [[ "$worktree_path" == "$WORKTREES_DIR/"* ]]; then
                if [ "$branch" != "main" ] && [ "$branch" != "master" ]; then
                    branches_to_close+=("$branch")
                fi
            fi
        fi

        if [ ${#branches_to_close[@]} -eq 0 ]; then
            log "No worktree branches found to reset."
            return 0
        fi

        log "Found ${#branches_to_close[@]} worktree branches to close:"
        for branch in "${branches_to_close[@]}"; do
            log "  - $branch"
        done
        log ""

        # Confirm with user
        echo -n "This will remove all worktrees and delete their branches. Continue? (y/N): "
        read -r response
        if [ "$response" != "y" ] && [ "$response" != "Y" ]; then
            log "Reset cancelled."
            return 0
        fi

        log ""
        local failed_branches=()

        # Close each branch
        for branch in "${branches_to_close[@]}"; do
            log "Closing branch: $branch"

            # Remove worktree if it exists
            local worktree_path="$WORKTREES_DIR/$branch"
            if [ -d "$worktree_path" ]; then
                # Get the project name from the current directory
                local project_name=$(basename "$PROJECT_DIR")

                # Create session name with worktree info
                # Replace slashes in branch name with dashes to avoid tmux issues
                local safe_branch=$(echo "$branch" | tr '/' '-')
                local session_name="${project_name}-wt-${safe_branch}"

                # Check if tmux session exists and kill it
                if tmux has-session -t "$session_name" 2>/dev/null; then
                    log "  Killing tmux session: $session_name"
                    tmux kill-session -t "$session_name" 2>/dev/null || true
                fi

                # Remove the worktree
                log "  Removing worktree at: $worktree_path"
                git worktree remove "$worktree_path" --force 2>/dev/null || true

                # Clean up any remaining directory if it exists
                if [ -d "$worktree_path" ]; then
                    rm -rf "$worktree_path"
                fi
            fi

            # Delete the local branch
            if branch_exists_locally "$branch"; then
                log "  Deleting branch: $branch"
                if ! git branch -D "$branch" 2>/dev/null; then
                    log "  ✗ Failed to delete branch '$branch' (may be checked out)"
                    failed_branches+=("$branch")
                else
                    log "  ✓ Branch deleted"
                fi
            fi
        done

        # Prune worktree metadata
        log ""
        log "Pruning worktree metadata..."
        git worktree prune

        if [ ${#failed_branches[@]} -gt 0 ]; then
            log ""
            log "Warning: Failed to delete the following branches:"
            for branch in "${failed_branches[@]}"; do
                log "  - $branch"
            done
            log "These branches may be checked out in the current directory."
            return 1
        else
            log ""
            log "✓ Reset completed successfully!"
            log "All worktrees removed and branches deleted."
        fi
    }

fi # End of include guard