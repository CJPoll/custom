#!/bin/bash
# stack.sh - Stack management functions for wt scripts
# This file is meant to be sourced, not executed directly

# Prevent direct execution
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    echo "Error: This script is meant to be sourced, not executed directly" >&2
    exit 1
fi

# Include guard to prevent multiple sourcing
if [[ -z "${WT_LIB_STACK_SOURCED:-}" ]]; then
    WT_LIB_STACK_SOURCED="true"

    # Source dependencies
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    source "${SCRIPT_DIR}/common.sh"
    source "${SCRIPT_DIR}/worktree.sh"

show_worktree_stack() {
    # Check if the --install flag is present
    if [ "${INSTALL_GIT_STACK:-false}" = true ]; then
        # This would install git-stack, but we're using gt now
        echo "Note: Using Graphite (gt) for stack management" >&2
        return 0
    fi

    # Check if gt (Graphite) is available
    if ! check_graphite; then
        return 1
    fi

    # Check if we're in a git repository
    if ! check_git_repo; then
        return 1
    fi

    # Simply pass through to gt ls with color preservation
    # Use --no-interactive to disable pager
    # Check if --current flag is set
    if [ "${STACK_CURRENT:-false}" = true ]; then
        gt ls -s --no-interactive
    else
        gt ls --no-interactive
    fi
}

sync_worktree_stack() {
    local continue_sync=false

    # Check for --continue flag
    if [ "${1:-}" = "--continue" ]; then
        continue_sync=true
    fi

    # Check if gt is available
    if ! check_graphite; then
        return 1
    fi

    if [ "$continue_sync" = true ]; then
        log "Continuing sync operation..."
        log ""

        # Use gt continue for resuming after conflict resolution
        if gt continue; then
            log ""
            log "Sync continued successfully!"
            log ""
            log "Updated stack:"
            gt ls --no-interactive
        else
            echo ""
            echo "Error: Failed to continue sync" >&2
            echo "Resolve any remaining conflicts and try again" >&2
            return 1
        fi
    else
        log "Syncing stack with remote changes..."
        log ""

        # Capture state before sync
        local original_branch=$(git rev-parse --abbrev-ref HEAD)
        local had_staged_changes=false
        if ! git diff --cached --quiet; then
            had_staged_changes=true
        fi

        # Show current stack before syncing
        log "Current stack:"
        gt ls --no-interactive
        log ""

        # Run gt sync
        if gt sync; then
            # Clean up any staged changes left by gt sync on main/master branches
            local current_branch=$(git rev-parse --abbrev-ref HEAD)
            if [[ "$current_branch" == "$original_branch" ]] && [[ "$current_branch" =~ ^(main|master)$ ]]; then
                if [[ "$had_staged_changes" == false ]] && ! git diff --cached --quiet; then
                    log "⚠️  Cleaning up staged changes left by sync operation..."
                    git reset HEAD -- . >/dev/null 2>&1
                fi
            fi

            log ""
            log "Sync completed successfully!"
            log ""
            log "Updated stack:"
            gt ls --no-interactive
        else
            echo ""
            echo "Error: Sync failed or was aborted" >&2
            echo "You may need to resolve conflicts and run 'wt sync --continue'" >&2
            return 1
        fi
    fi
}

restack_worktree() {
    # Check if gt is available
    if ! check_graphite; then
        return 1
    fi

    log "Restacking branches to fix parent relationships..."
    log ""

    # Show current stack before restacking
    log "Current stack:"
    gt ls --no-interactive
    log ""

    # Run gt restack
    if gt restack; then
        log ""
        log "Restack completed successfully!"
        log ""
        log "Updated stack:"
        gt ls --no-interactive
    else
        echo ""
        echo "Error: Restack failed or was aborted" >&2
        echo "You may need to resolve conflicts and run 'gt continue'" >&2
        return 1
    fi
}

get_branch_parent() {
    local branch="$1"
    local worktree_path=""

    # First, check if the branch exists locally
    local branch_exists_locally=false
    if branch_exists_locally "$branch"; then
        branch_exists_locally=true
    fi

    # If branch doesn't exist locally but exists on remote, we need special handling
    if [ "$branch_exists_locally" = false ]; then
        if branch_exists_on_remote "$branch"; then
            # Try to get parent from gt metadata for remote branch
            # Create a temporary local ref to query gt
            git update-ref "refs/heads/temp-parent-query-$branch" "refs/remotes/origin/$branch" 2>/dev/null || true

            # Now try to get parent from gt metadata
            local parent=$(gt branch info "temp-parent-query-$branch" 2>/dev/null | grep "^Parent:" | sed 's/^Parent:[[:space:]]*//' | cut -d' ' -f1) || true

            # Clean up temporary ref
            git update-ref -d "refs/heads/temp-parent-query-$branch" 2>/dev/null || true

            if [ -n "$parent" ]; then
                echo "$parent"
                return 0
            fi

            # If we still don't have parent, try to get it from the stack output
            local stack_output=$(gt ls --no-interactive 2>/dev/null || echo "")
            if [ -n "$stack_output" ]; then
                parent=$(echo "$stack_output" | awk -v branch="$branch" '
                    BEGIN { found = 0; parent_line = "" }
                    {
                        # Remove tree drawing characters and extract branch name
                        line = $0
                        gsub(/^[[:space:]]*[│├└][─\s]*/, "", line)
                        gsub(/[[:space:]]*\(.*\)[[:space:]]*$/, "", line)
                        gsub(/^[[:space:]]*/, "", line)
                        gsub(/[[:space:]]*$/, "", line)

                        if (found == 1 && line != "") {
                            # This is the line after our branch, which is its parent in the tree
                            parent_line = line
                            found = 2
                        }

                        if (line == branch) {
                            found = 1
                        }

                        if (found == 0 && line != "") {
                            # Keep track of the previous branch for parent detection
                            potential_parent = line
                        }
                    }
                    END {
                        if (found == 1 && potential_parent != "") {
                            # Our branch was found and we have a previous branch
                            print potential_parent
                        }
                    }
                ')
            fi

            echo "$parent"
            return 0
        fi
    fi

    # For local branches, proceed with the existing logic
    # Find the worktree path for this branch
    if [ -n "$branch" ]; then
        # Check if it's a worktree branch (handle branches with slashes)
        local potential_worktree="$WORKTREES_DIR/$branch"
        if [ -d "$potential_worktree" ] && [ -f "$potential_worktree/.git" ]; then
            # Make sure it's actually a worktree (has .git file)
            worktree_path="$potential_worktree"
        else
            # Check if we're in the main project and this is the current branch
            local current_branch=$(get_current_branch)
            if [ "$branch" = "$current_branch" ]; then
                if [ -d "$PROJECT_DIR/.git" ]; then
                    worktree_path="$PROJECT_DIR"
                else
                    # We might be in a worktree ourselves, use current directory
                    worktree_path="$(pwd)"
                fi
            fi
        fi
    fi

    # If we still don't have a worktree path, try to use current directory if branch matches
    if [ -z "$worktree_path" ]; then
        local current_branch=$(get_current_branch)
        if [ "$branch" = "$current_branch" ]; then
            worktree_path="$(pwd)"
        else
            # Can't find worktree, but we can still try to get parent from gt directly
            worktree_path="."
        fi
    fi

    # Get the parent branch from Graphite
    # Try using gt branch info first (faster if available)
    local parent=""
    if command -v gt &>/dev/null; then
        # Check if we can query the branch directly
        if [ "$branch_exists_locally" = true ]; then
            # Try to get parent from gt branch info
            local gt_output=$(gt branch info "$branch" 2>/dev/null || (cd "$worktree_path" 2>/dev/null && gt branch info 2>&1))
            parent=$(echo "$gt_output" | grep "^Parent:" | sed 's/^Parent:[[:space:]]*//' | cut -d' ' -f1)
        fi
    fi

    # Fallback to parsing .graphite_repo_config if gt command fails
    if [ -z "$parent" ] && [ -f "$worktree_path/.git/.graphite_repo_config" ]; then
        # Parse JSON config file for branch parent
        # Using grep and sed for compatibility (jq might not be available)
        parent=$(grep -A 10 "\"$branch\"" "$worktree_path/.git/.graphite_repo_config" 2>/dev/null | grep '"parentBranchName"' | head -1 | sed 's/.*"parentBranchName"[[:space:]]*:[[:space:]]*"//' | sed 's/".*//')
    fi

    # Additional fallback: check the main project's .graphite_repo_config
    if [ -z "$parent" ] && [ -f "$PROJECT_DIR/.git/.graphite_repo_config" ]; then
        parent=$(grep -A 10 "\"$branch\"" "$PROJECT_DIR/.git/.graphite_repo_config" 2>/dev/null | grep '"parentBranchName"' | head -1 | sed 's/.*"parentBranchName"[[:space:]]*:[[:space:]]*"//' | sed 's/".*//')
    fi

    echo "$parent"
}

set_stack_parent() {
    # Handle help first
    if [ "$1" = "--help" ] || [ "$1" = "-h" ]; then
        echo "Usage: wt stack parent [<new-parent>] [--restack] [--switch]"
        echo ""
        echo "Show or set the parent branch of the current branch"
        echo ""
        echo "Options:"
        echo "  --restack    Restack the branch hierarchy after setting parent"
        echo "  --switch     Switch to the parent branch's worktree after setting"
        echo "  --help, -h   Show this help message"
        echo ""
        echo "Examples:"
        echo "  wt stack parent              # Show current parent"
        echo "  wt stack parent main          # Set parent to main"
        echo "  wt stack parent feat --restack # Set parent and restack"
        return 0
    fi

    local parent_branch=""
    local do_restack=false
    local do_switch=false

    # Parse arguments
    while [ $# -gt 0 ]; do
        case "$1" in
            --restack)
                do_restack=true
                shift
                ;;
            --switch)
                do_switch=true
                shift
                ;;
            *)
                if [ -z "$parent_branch" ]; then
                    parent_branch="$1"
                else
                    echo "Error: Unexpected argument: $1" >&2
                    echo "Usage: wt stack parent [<new-parent>] [--restack] [--switch]" >&2
                    return 1
                fi
                shift
                ;;
        esac
    done

    # Get current branch
    local current_branch=$(get_current_branch)
    if [ -z "$current_branch" ]; then
        echo "Error: Not in a git repository" >&2
        return 1
    fi

    # If no parent branch specified, show the current parent
    if [ -z "$parent_branch" ]; then
        # Check if branch is tracked first
        if ! gt ls --no-interactive 2>/dev/null | grep -q "^[◯◉][[:space:]]*$current_branch"; then
            echo "Branch '$current_branch' is not tracked by Graphite"
            echo "Run 'wt stack parent <parent-branch>' to track it and set a parent"
            return 0
        fi

        local current_parent=$(get_branch_parent "$current_branch")
        if [ -n "$current_parent" ]; then
            echo "Parent of '$current_branch': $current_parent"
        else
            echo "Branch '$current_branch' has no parent"
        fi
        return 0
    fi

    # Check if parent branch exists
    if ! branch_exists_locally "$parent_branch" && ! branch_exists_on_remote "$parent_branch"; then
        echo "Error: Parent branch '$parent_branch' does not exist locally or on origin" >&2
        return 1
    fi

    # Don't allow setting a branch as its own parent
    if [ "$current_branch" = "$parent_branch" ]; then
        echo "Error: Cannot set a branch as its own parent" >&2
        return 1
    fi

    # Check if gt is available
    if ! check_graphite; then
        return 2
    fi

    log "Setting parent of '$current_branch' to '$parent_branch'"

    # Check if branch is tracked by Graphite
    local is_tracked=false
    if gt ls --no-interactive 2>/dev/null | grep -q "^[◯◉][[:space:]]*$current_branch"; then
        is_tracked=true
    fi

    if [ "$is_tracked" = false ]; then
        # Branch is not tracked, use gt track
        log "Branch is not tracked, tracking with Graphite..."
        if ! gt track --parent "$parent_branch" -q; then
            echo "Error: Failed to track branch and set parent" >&2
            return 1
        fi
    else
        # Branch is already tracked, use gt move --onto
        log "Moving branch onto new parent..."
        if ! gt move --onto "$parent_branch" --no-interactive; then
            echo "Error: Failed to change parent" >&2
            echo "If there are conflicts, resolve them and run 'wt continue'" >&2
            return 1
        fi
    fi

    log "✓ Parent relationship configured: $current_branch -> $parent_branch"

    # Handle --restack flag
    if [ "$do_restack" = true ]; then
        log "Restacking branches..."
        if ! gt restack --no-interactive; then
            echo "Error: Restack failed" >&2
            echo "If there are conflicts, resolve them and run 'wt continue'" >&2
            return 1
        fi
        log "✓ Stack restacked successfully"
    fi

    # Handle --switch flag
    if [ "$do_switch" = true ]; then
        log "Switching to parent worktree..."
        switch_worktree "$parent_branch"
    fi

    return 0
}

stack_move() {
    # Check for rebase/merge in progress before any operations
    if [ -d "$(git rev-parse --git-dir 2>/dev/null)/rebase-merge" ] || \
       [ -d "$(git rev-parse --git-dir 2>/dev/null)/rebase-apply" ] || \
       [ -f "$(git rev-parse --git-dir 2>/dev/null)/MERGE_HEAD" ]; then
        echo "Error: Cannot move branches while rebase or merge is in progress" >&2
        echo "Complete or abort the current operation first" >&2
        return 129
    fi

    local onto_parent=""
    local move_up=false
    local move_down=false
    local dry_run=false
    local interactive=true

    # Parse arguments
    while [ $# -gt 0 ]; do
        case "$1" in
            --onto)
                shift
                if [ $# -eq 0 ]; then
                    echo "Error: --onto requires a parent branch name" >&2
                    return 1
                fi
                onto_parent="$1"
                interactive=false
                shift
                ;;
            --up)
                move_up=true
                interactive=false
                shift
                ;;
            --down)
                move_down=true
                interactive=false
                shift
                ;;
            --dry-run)
                dry_run=true
                shift
                ;;
            -h|--help)
                echo "Usage: wt stack move [options]"
                echo ""
                echo "Options:"
                echo "  --onto <parent>  Move current branch onto a new parent"
                echo "  --up             Move branch up (earlier) among siblings"
                echo "  --down           Move branch down (later) among siblings"
                echo "  --dry-run        Show what would happen without making changes"
                echo ""
                echo "Without options, opens interactive mode (delegates to gt move)"
                return 0
                ;;
            *)
                echo "Error: Unknown option: $1" >&2
                echo "Use 'wt stack move --help' for usage" >&2
                return 1
                ;;
        esac
    done

    # Check if gt is available
    if ! check_graphite; then
        return 2
    fi

    # Handle different move operations
    if [ "$interactive" = true ]; then
        # Interactive mode - delegate to gt move
        log "Opening interactive move mode..."
        if ! gt move; then
            echo "Error: Failed to move branch" >&2
            echo "If there are conflicts, resolve them and run 'wt continue'" >&2
            return 1
        fi
    elif [ -n "$onto_parent" ]; then
        # Move onto new parent
        log "Moving current branch onto '$onto_parent'..."
        local gt_opts=""
        if [ "$dry_run" = true ]; then
            gt_opts="--dry-run"
        fi
        if ! gt move --onto "$onto_parent" --no-interactive $gt_opts; then
            echo "Error: Failed to move branch" >&2
            echo "If there are conflicts, resolve them and run 'wt continue'" >&2
            return 1
        fi
    elif [ "$move_up" = true ] || [ "$move_down" = true ]; then
        # Reorder among siblings - needs custom implementation
        echo "Note: --up/--down reordering is not yet implemented" >&2
        echo "Use 'wt stack reorder' for interactive reordering" >&2
        return 1
    else
        echo "Error: No move operation specified" >&2
        return 1
    fi

    return 0
}

fi # End of include guard