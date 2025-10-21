#!/bin/bash
# stack-advanced.sh - Advanced stack operations for wt scripts
# This file is meant to be sourced, not executed directly

# Prevent direct execution
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    echo "Error: This script is meant to be sourced, not executed directly" >&2
    exit 1
fi

# Include guard to prevent multiple sourcing
if [[ -z "${WT_LIB_STACK_ADVANCED_SOURCED:-}" ]]; then
    WT_LIB_STACK_ADVANCED_SOURCED="true"

    # Source dependencies
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    source "${SCRIPT_DIR}/common.sh"
    source "${SCRIPT_DIR}/worktree.sh"
    source "${SCRIPT_DIR}/stack.sh"
    source "${SCRIPT_DIR}/create.sh"
    source "${SCRIPT_DIR}/tmux.sh"

    get_branch_children() {
        local branch="$1"
        local children=()

        # Use gt metadata to find direct children of the branch
        if command -v gt &>/dev/null; then
            # Read parent metadata directly from git refs - much faster than calling gt branch info
            local metadata_dir="$PROJECT_DIR/.git/refs/branch-metadata"

            if [ -d "$metadata_dir" ]; then
                # Find all branches with metadata
                find "$metadata_dir" -type f 2>/dev/null | while read -r metadata_file; do
                    # Get branch name from file path
                    local candidate="${metadata_file#$metadata_dir/}"

                    # Skip the branch itself
                    [ "$candidate" = "$branch" ] && continue

                    # Read the metadata blob
                    local blob_sha=$(cat "$metadata_file" 2>/dev/null)
                    if [ -n "$blob_sha" ]; then
                        # Extract parent from the JSON blob
                        local parent=$(git cat-file -p "$blob_sha" 2>/dev/null | grep '"parentBranchName"' | sed 's/.*"parentBranchName"[[:space:]]*:[[:space:]]*"//' | sed 's/".*//')

                        if [ "$parent" = "$branch" ]; then
                            echo "$candidate"
                        fi
                    fi
                done | while read -r child; do
                    [ -n "$child" ] && children+=("$child")
                    echo "$child"  # Pass through to parent shell
                done
            else
                # Fallback to using gt branch info if metadata directory doesn't exist
                local all_branches=$(git for-each-ref --format='%(refname:short)' refs/heads/)

                for candidate in $all_branches; do
                    # Skip the branch itself
                    [ "$candidate" = "$branch" ] && continue

                    # Check if this branch's parent is our target branch
                    local parent=$(gt branch info "$candidate" 2>/dev/null | grep "Parent:" | sed 's/.*Parent: *//' | cut -d' ' -f1)
                    if [ "$parent" = "$branch" ]; then
                        children+=("$candidate")
                    fi
                done
            fi
        else
            # Fallback to checking only worktrees if gt is not available
            # Check main project
            local main_branch=$(git -C "$PROJECT_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null)
            if [ -n "$main_branch" ]; then
                local main_parent=$(get_branch_parent "$main_branch")
                if [ "$main_parent" = "$branch" ]; then
                    children+=("$main_branch")
                fi
            fi

            # Check all worktrees
            if [ -d "$WORKTREES_DIR" ]; then
                for wt in "$WORKTREES_DIR"/*; do
                    [ -d "$wt" ] || continue
                    local wt_branch=$(git -C "$wt" rev-parse --abbrev-ref HEAD 2>/dev/null)
                    if [ -n "$wt_branch" ]; then
                        local wt_parent=$(get_branch_parent "$wt_branch")
                        if [ "$wt_parent" = "$branch" ]; then
                            children+=("$wt_branch")
                        fi
                    fi
                done
            fi
        fi

        # Output children one per line
        for child in "${children[@]}"; do
            echo "$child"
        done
    }

    get_stack_branches() {
        # Get all branches in the current stack using gt
        if ! command -v gt &>/dev/null; then
            echo "Error: Graphite (gt) is required for stack operations" >&2
            return 1
        fi

        # Get the current branch
        local current_branch=$(get_current_branch)
        if [ -z "$current_branch" ]; then
            echo "Error: Not in a git repository" >&2
            return 1
        fi

        # Get the stack using gt ls and parse the output
        # This gets all branches in the current stack
        local stack_output=$(gt ls --no-interactive 2>/dev/null)

        # Parse the output to extract branch names
        # Look for lines with branch indicators (◯ or ◉)
        echo "$stack_output" | grep -E "^[[:space:]]*[◯◉]" | sed 's/^[[:space:]]*[◯◉][[:space:]]*//' | sed 's/[[:space:]].*//'
    }

    navigate_stack() {
        local direction="$1"

        if [ -z "$direction" ]; then
            echo "Error: Direction (next/prev) is required" >&2
            return 1
        fi

        # Get current branch
        local current_branch=$(get_current_branch)
        if [ -z "$current_branch" ]; then
            echo "Error: Not in a git repository" >&2
            return 1
        fi

        local target_branch=""

        case "$direction" in
            next)
                # Navigate to the first child branch
                local children=($(get_branch_children "$current_branch"))
                if [ ${#children[@]} -eq 0 ]; then
                    echo "No child branches found for $current_branch"
                    return 1
                fi

                # If multiple children, show them and ask user to choose
                if [ ${#children[@]} -gt 1 ]; then
                    echo "Multiple child branches found:"
                    local i=1
                    for child in "${children[@]}"; do
                        echo "  $i) $child"
                        ((i++))
                    done
                    echo -n "Select branch (1-${#children[@]}): "
                    read -r selection

                    # Validate selection
                    if [[ "$selection" =~ ^[0-9]+$ ]] && [ "$selection" -ge 1 ] && [ "$selection" -le ${#children[@]} ]; then
                        target_branch="${children[$((selection-1))]}"
                    else
                        echo "Invalid selection"
                        return 1
                    fi
                else
                    target_branch="${children[0]}"
                fi
                ;;

            prev)
                # Navigate to the parent branch
                local parent=$(get_branch_parent "$current_branch")
                if [ -z "$parent" ]; then
                    echo "No parent branch found for $current_branch"
                    return 1
                fi
                target_branch="$parent"
                ;;

            *)
                echo "Error: Invalid direction '$direction'. Use 'next' or 'prev'" >&2
                return 1
                ;;
        esac

        # Switch to the target branch's worktree
        log "Navigating from $current_branch to $target_branch"
        switch_worktree "$target_branch"
    }

    run_in_worktree() {
        local branch="$1"
        shift  # Remove branch from arguments
        local command="$*"

        local worktree_path=$(get_worktree_dir "$branch")
        if [ -z "$worktree_path" ]; then
            echo "Error: No worktree found for branch: $branch" >&2
            return 1
        fi

        log "Running in $branch: $command"

        # Run the command in the worktree directory
        (cd "$worktree_path" && eval "$command")
        local result=$?

        if [ $result -eq 0 ]; then
            log "✓ Command succeeded in $branch"
        else
            log "✗ Command failed in $branch with exit code $result"
        fi

        return $result
    }

    run_across_stack() {
        local command="$1"

        if [ -z "$command" ]; then
            echo "Error: Command is required" >&2
            return 1
        fi

        # Get all branches in the stack
        local branches=($(get_stack_branches))
        if [ ${#branches[@]} -eq 0 ]; then
            echo "Error: No branches found in stack" >&2
            return 1
        fi

        log "Running command across ${#branches[@]} branches in stack"
        log "Command: $command"
        log ""

        local failed_branches=()
        local succeeded_branches=()

        # Run command in each worktree
        for branch in "${branches[@]}"; do
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo "Branch: $branch"
            echo "────────────────────────────────────────"

            if run_in_worktree "$branch" "$command"; then
                succeeded_branches+=("$branch")
            else
                failed_branches+=("$branch")
            fi
            echo ""
        done

        # Summary
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "Summary:"
        echo "────────────────────────────────────────"
        echo "Succeeded: ${#succeeded_branches[@]} branches"
        if [ ${#succeeded_branches[@]} -gt 0 ]; then
            for branch in "${succeeded_branches[@]}"; do
                echo "  ✓ $branch"
            done
        fi

        if [ ${#failed_branches[@]} -gt 0 ]; then
            echo ""
            echo "Failed: ${#failed_branches[@]} branches"
            for branch in "${failed_branches[@]}"; do
                echo "  ✗ $branch"
            done
            return 1
        fi

        return 0
    }

    # Open worktrees for all branches in a stack leading up to the target branch
    open_stack_branches() {
        local target_branch="$1"
        local create_sessions=false

        # Check for --create-sessions flag (passed via global variable)
        if [ "${STACK_CREATE_SESSIONS:-false}" = true ]; then
            create_sessions=true
        fi

        if [ -z "$target_branch" ]; then
            echo "Error: Branch name is required" >&2
            echo "Usage: wt stack open <branch> [--create-sessions]" >&2
            return 1
        fi

        # Check if we're running from the main branch worktree
        set +e
        (
            CHECK_DIR="$(pwd)"
            is_worktree
        )
        local is_wt_result=$?
        set -e

        if [ $is_wt_result -ne 1 ]; then
            echo "Error: 'wt stack open' must be run from the main branch worktree" >&2
            exit 1
        fi

        # Check if gt is available
        if ! command -v gt &>/dev/null; then
            echo "Error: Graphite (gt) is required for stack operations" >&2
            echo "Install with: brew install graphite or visit https://graphite.dev" >&2
            exit 2
        fi

        log "Fetching branch and its stack from remote..."

        # Save current branch to return to it after gt get
        local original_branch=$(git rev-parse --abbrev-ref HEAD)

        # Check if working directory is clean before proceeding
        if ! git diff --quiet || ! git diff --cached --quiet; then
            echo "Error: Working directory has uncommitted changes. Please commit or stash them first." >&2
            exit 3
        fi

        # Use gt get to fetch the branch and all its downstack dependencies
        if ! gt get "$target_branch" --downstack 2>&1; then
            echo "Error: Failed to fetch branch '$target_branch' and its stack" >&2
            exit 2
        fi

        # Return to original branch since gt get checked out the target branch
        if [ "$original_branch" != "$target_branch" ]; then
            git checkout "$original_branch" --quiet
        fi

        # Clean up any staged or unstaged changes left by gt get
        # This prevents main from accumulating unwanted changes
        if ! git diff --quiet || ! git diff --cached --quiet; then
            log "Cleaning up changes left by gt get..."
            git reset --hard HEAD --quiet
        fi

        # Get the list of branches in the stack from trunk to target
        log "Discovering branches in stack..."
        local branches_to_create=()
        local current="$target_branch"
        local visited_branches=()
        local max_depth=50

        # Build the stack by following parent relationships
        while [ -n "$current" ] && [ "$current" != "main" ] && [ "$current" != "master" ] && [ ${#visited_branches[@]} -lt $max_depth ]; do
            # Check for cycles
            for visited in "${visited_branches[@]}"; do
                if [ "$visited" = "$current" ]; then
                    echo "Error: Cycle detected in branch stack at '$current'" >&2
                    exit 2
                fi
            done

            visited_branches+=("$current")
            branches_to_create=("$current" "${branches_to_create[@]}")

            # Get parent from gt metadata
            local parent=$(get_branch_parent "$current")
            current="$parent"
        done

        if [ ${#branches_to_create[@]} -eq 0 ]; then
            log "No branches to create - target branch is main/master or has no parents"
            return 0
        fi

        log "Creating worktrees for ${#branches_to_create[@]} branches in stack"

        # Create worktrees for each branch in order
        local created_count=0
        local existing_count=0
        local skipped_count=0
        for branch in "${branches_to_create[@]}"; do
            # Skip graphite-base branches (internal Graphite merge bases)
            if [[ "$branch" =~ ^graphite-base/ ]]; then
                log "Skipping Graphite internal branch: $branch"
                skipped_count=$((skipped_count + 1))
                continue
            fi

            # Check if worktree already exists
            local worktree_path="$WORKTREES_DIR/$branch"
            if [ -d "$worktree_path" ]; then
                existing_count=$((existing_count + 1))
            else
                if ! create_worktree "$branch"; then
                    echo "Error: Failed to create worktree for branch '$branch'" >&2
                    exit 3
                fi
                created_count=$((created_count + 1))
            fi

            # Create tmux session if requested (without attaching)
            if [ "$create_sessions" = true ]; then
                create_tmux_session_for_worktree "$branch" "$worktree_path" "$PROJECT_NAME" false
            fi
        done

        if [ $created_count -gt 0 ]; then
            log "✓ Created $created_count new worktrees"
        fi
        if [ $existing_count -gt 0 ]; then
            log "✓ $existing_count worktrees already existed"
        fi
        if [ $skipped_count -gt 0 ]; then
            log "✓ Skipped $skipped_count Graphite internal branches"
        fi
        if [ "$create_sessions" = true ]; then
            log "✓ Created tmux sessions for all branches"
        fi
        return 0
    }

fi # End of include guard