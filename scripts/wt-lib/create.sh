#!/bin/bash
# create.sh - Worktree creation functions for wt scripts
# This file is meant to be sourced, not executed directly

# Prevent direct execution
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    echo "Error: This script is meant to be sourced, not executed directly" >&2
    exit 1
fi

# Include guard to prevent multiple sourcing
if [[ -z "${WT_LIB_CREATE_SOURCED:-}" ]]; then
    WT_LIB_CREATE_SOURCED="true"

    # Source dependencies
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    source "${SCRIPT_DIR}/common.sh"
    source "${SCRIPT_DIR}/worktree.sh"

create_worktree() {
    local branch="$1"
    local worktree_path="$WORKTREES_DIR/$branch"

    # Get flags from environment variables (set by the calling script)
    local INSERT_BRANCH="${INSERT_BRANCH:-false}"
    local PARENT_BRANCH="${PARENT_BRANCH:-$(get_current_branch)}"
    local PARENT_BRANCH_EXPLICIT="${PARENT_BRANCH_EXPLICIT:-false}"
    local STAGE_ALL="${STAGE_ALL:-false}"
    local NO_VERIFY="${NO_VERIFY:-false}"
    local COMMIT_MESSAGE="${COMMIT_MESSAGE:-}"
    local NO_SYMLINK="${NO_SYMLINK:-false}"

    if [ -z "$branch" ]; then
        echo "Error: Branch name is required" >&2
        return 1
    fi

    # Check for mutually exclusive flags
    if [ "$INSERT_BRANCH" = true ] && [ "$PARENT_BRANCH_EXPLICIT" = true ]; then
        echo "Error: --insert and --parent cannot be used together" >&2
        return 1
    fi

    # Validate directory context for --insert
    if [ "$INSERT_BRANCH" = true ]; then
        # Must be in a worktree, not main project directory
        set +e
        (
            CHECK_DIR="$(pwd)"
            is_worktree
        )
        local is_wt_result=$?
        set -e

        if [ $is_wt_result -ne 0 ]; then
            echo "Error: --insert must be run from a worktree branch, not the main project directory" >&2
            echo "Current directory is the main project directory" >&2
            echo "Switch to a worktree first: wt switch <branch>" >&2
            return 3
        fi

        # Check for Graphite
        if ! check_graphite; then
            return 2
        fi

        # Get current branch for context
        local current_branch=$(get_current_branch)

        # Check for uncommitted changes if no staging flag
        if [ "$STAGE_ALL" != true ]; then
            if ! git diff --quiet || ! git diff --cached --quiet; then
                echo "Error: You have uncommitted changes. Use -a to include them or commit/stash first" >&2
                return 1
            fi
        fi
    fi

    # Check if worktree directory already exists
    if [ -d "$worktree_path" ]; then
        echo "Error: Worktree already exists at: $worktree_path" >&2
        return 1
    fi

    # Check if branch exists locally
    local branch_exists_locally=false
    if branch_exists_locally "$branch"; then
        branch_exists_locally=true
    fi

    # For non-insert operations, if branch exists locally, just create the worktree
    # For insert operations, branch shouldn't exist yet
    if [ "$INSERT_BRANCH" = true ]; then
        if [ "$branch_exists_locally" = true ]; then
            echo "Error: Branch '$branch' already exists locally (cannot insert)" >&2
            return 1
        fi
        if branch_exists_on_remote "$branch"; then
            echo "Error: Branch '$branch' already exists on remote (cannot insert)" >&2
            return 1
        fi
    fi

    if [ ! -d "$WORKTREES_DIR" ]; then
        log "Worktrees directory not found. Running init first..."
        init_worktrees
    fi

    # Handle --insert flow
    if [ "$INSERT_BRANCH" = true ]; then
        log "Inserting '$branch' into the stack..."

        # Build gt create command with appropriate flags
        local gt_cmd="gt create '$branch' --insert --no-interactive"

        # Add optional flags if provided
        [ "$STAGE_ALL" = true ] && gt_cmd="$gt_cmd --all"
        [ "$NO_VERIFY" = true ] && gt_cmd="$gt_cmd --no-verify"
        [ -n "$COMMIT_MESSAGE" ] && gt_cmd="$gt_cmd --message '$COMMIT_MESSAGE'"

        # Execute gt create --insert
        if ! eval $gt_cmd; then
            echo "Error: Failed to insert branch into stack" >&2
            echo "If there are conflicts, resolve them and run 'wt continue'" >&2
            return 1
        fi

        # Count children that were rebased (for user feedback)
        local children_count=$(gt log --reverse | grep -c "^  " || echo "0")
        if [ "$children_count" -gt 0 ]; then
            log "✓ Rebased $children_count child branch(es) onto '$branch'"
        fi

        # Now create the worktree for the newly created branch
        log "Creating worktree for '$branch'..."
        git worktree add "$worktree_path" "$branch" &>/dev/null

    else
        # Original create flow (non-insert)
        log "Setting up $branch..."

        # If branch already exists locally, just create the worktree for it
        if [ "$branch_exists_locally" = true ]; then
            git worktree add "$worktree_path" "$branch" &>/dev/null
        else
            # Determine the base branch for the new worktree
            local base_branch="$PARENT_BRANCH"

            # Create branch and worktree based on existing logic
            # Check if branch exists as remote, create from parent, etc.

            if branch_exists_on_remote "$branch"; then
                git worktree add "$worktree_path" -b "$branch" "origin/$branch" &>/dev/null
            else
                # Create new branch from the parent branch
                if [ "$base_branch" != "main" ] && [ "$base_branch" != "master" ]; then
                    # Ensure parent branch exists
                    if branch_exists_locally "$base_branch"; then
                        git worktree add "$worktree_path" -b "$branch" "$base_branch" &>/dev/null
                    else
                        echo "Error: Parent branch '$base_branch' does not exist" >&2
                        return 1
                    fi
                else
                    git worktree add "$worktree_path" -b "$branch" &>/dev/null
                fi
            fi
        fi
    fi

    # Initialize gt in the new worktree
    init_graphite_worktree "$worktree_path"

    # Configure Graphite parent relationship (for non-insert flow)
    if [ "$INSERT_BRANCH" != true ]; then
        if [ "$PARENT_BRANCH" != "main" ] || [ "$PARENT_BRANCH_EXPLICIT" = true ]; then
            if command -v gt &>/dev/null; then
                # First ensure the parent branch is tracked
                (cd "$worktree_path" && gt track "$PARENT_BRANCH" &>/dev/null 2>&1) || true
                # Now track the current branch with its parent
                (cd "$worktree_path" && gt track "$branch" --parent "$PARENT_BRANCH" &>/dev/null 2>&1) || true
            fi
        fi
    fi

    # Create symlink to .claude directory if it exists in the main project (silently)
    if [ "$NO_SYMLINK" = false ] && [ -d "$PROJECT_DIR/.claude" ]; then
        if [ ! -e "$worktree_path/.claude" ]; then
            ln -s "$PROJECT_DIR/.claude" "$worktree_path/.claude" &>/dev/null 2>&1 || true
        fi
    fi

    # Success message
    if [ "$INSERT_BRANCH" = true ]; then
        log "✓ Created and inserted branch '$branch' into the stack"
    else
        log "✓ Created worktree for branch '$branch'"
    fi

    # Explicitly return success
    return 0
}

fi # End of include guard