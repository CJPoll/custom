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

    # Note: This is a very large and complex function
    # It should be refactored into smaller functions in a future update
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

        log "Fetching latest branch information from remote..."
        git fetch origin --quiet 2>/dev/null || log "Warning: Could not fetch from origin"

        # First, ensure the target branch exists locally or remotely
        if ! git show-ref --verify --quiet "refs/heads/$target_branch" && \
           ! git show-ref --verify --quiet "refs/remotes/origin/$target_branch"; then
            echo "Error: Branch '$target_branch' does not exist locally or on origin" >&2
            exit 2
        fi

        # If the branch exists on remote but not locally, fetch it to get its metadata
        if ! git show-ref --verify --quiet "refs/heads/$target_branch" && \
             git show-ref --verify --quiet "refs/remotes/origin/$target_branch"; then
            log "Fetching remote branch and its metadata: $target_branch"
            git fetch origin "$target_branch:$target_branch" 2>/dev/null || true

            # Also fetch the graphite metadata
            git fetch origin "refs/branch-metadata/$target_branch:refs/branch-metadata/$target_branch" 2>/dev/null || true
        fi

        # Initialize gt if needed (this syncs metadata from remote)
        local trunk_branch="main"
        if ! git show-ref --verify --quiet "refs/heads/main"; then
            if git show-ref --verify --quiet "refs/heads/master"; then
                trunk_branch="master"
            fi
        fi

        # Initialize graphite repo if not already done
        if [ ! -f ".git/.graphite_repo_config" ]; then
            log "Initializing Graphite repository..."
            gt repo init --trunk "$trunk_branch" -q 2>/dev/null || true
        fi

        # Sync all Graphite metadata from remote
        # This will fetch branch metadata and establish proper parent relationships
        log "Syncing Graphite metadata from remote..."
        gt repo sync --no-interactive 2>/dev/null || true

        # Get the full stack structure from Graphite after fetching
        local stack_output=$(gt ls --no-interactive 2>/dev/null || echo "")

        # If stack is still empty, fall back to GitHub PR discovery
        if [ -z "$stack_output" ] || ! echo "$stack_output" | grep -q "$target_branch"; then
            log "Stack information not available from Graphite, attempting to discover stack from GitHub..."

            # Try to discover the stack from GitHub PR information if gh is available
            local branches_to_track=()

            if command -v gh &>/dev/null; then
                log "Checking GitHub for PR stack information..."

                # First, discover all branches that are part of the stack
                # We need to find not just ancestors but all related branches
                declare -A all_stack_branches
                declare -A branch_parent_map
                local branches_to_process=("$target_branch")
                local max_iterations=100
                local iterations=0

                # Process branches to discover the full stack
                while [ ${#branches_to_process[@]} -gt 0 ] && [ $iterations -lt $max_iterations ]; do
                    local current="${branches_to_process[0]}"
                    branches_to_process=("${branches_to_process[@]:1}")  # Remove first element

                    # Skip if we've already processed this branch
                    if [ "${all_stack_branches[$current]:-}" = "1" ]; then
                        continue
                    fi

                    all_stack_branches["$current"]=1

                    # Fetch the branch if it doesn't exist locally
                    if ! git show-ref --verify --quiet "refs/heads/$current"; then
                        if git show-ref --verify --quiet "refs/remotes/origin/$current"; then
                            git fetch origin "$current:$current" 2>/dev/null || true
                        else
                            continue  # Skip branches that don't exist
                        fi
                    fi

                    # Find parent from GitHub PR
                    local pr_info=$(gh pr list --head "$current" --json baseRefName --limit 1 2>/dev/null || echo "")
                    if [ -n "$pr_info" ] && [ "$pr_info" != "[]" ]; then
                        local parent=$(echo "$pr_info" | grep -o '"baseRefName":"[^"]*"' | sed 's/"baseRefName":"//' | sed 's/"//')
                        if [ -n "$parent" ]; then
                            branch_parent_map["$current"]="$parent"
                            # Add parent to process list if it's not main/master
                            if [ "$parent" != "main" ] && [ "$parent" != "master" ]; then
                                branches_to_process+=("$parent")
                            fi
                        fi
                    fi

                    # Find children (other PRs based on this branch)
                    local children_info=$(gh pr list --base "$current" --json headRefName 2>/dev/null || echo "")
                    if [ -n "$children_info" ] && [ "$children_info" != "[]" ]; then
                        while IFS= read -r child; do
                            if [ -n "$child" ]; then
                                branches_to_process+=("$child")
                            fi
                        done < <(echo "$children_info" | grep -o '"headRefName":"[^"]*"' | sed 's/"headRefName":"//' | sed 's/"//')
                    fi

                    iterations=$((iterations + 1))
                done

                # Build ordered list from target back to trunk
                branches_to_track=()
                current="$target_branch"
                local visited_in_chain=()
                local max_depth=50
                local depth=0

                while [ -n "$current" ] && [ "$current" != "main" ] && [ "$current" != "master" ] && [ $depth -lt $max_depth ]; do
                    # Check for cycles
                    for visited in "${visited_in_chain[@]}"; do
                        if [ "$visited" = "$current" ]; then
                            break 2
                        fi
                    done

                    visited_in_chain+=("$current")
                    branches_to_track=("$current" "${branches_to_track[@]}")
                    current="${branch_parent_map[$current]:-}"
                    depth=$((depth + 1))
                done
            else
                # Fallback: just track the target branch with main as parent
                log "GitHub CLI not available, tracking target branch only..."
                branches_to_track=("$target_branch")

                # Fetch the branch if it doesn't exist locally
                if ! git show-ref --verify --quiet "refs/heads/$target_branch"; then
                    if git show-ref --verify --quiet "refs/remotes/origin/$target_branch"; then
                        log "  Fetching branch: $target_branch"
                        git fetch origin "$target_branch:$target_branch" 2>/dev/null || true
                    fi
                fi
            fi

            log "Discovered ${#branches_to_track[@]} branches in stack"

            # Track all branches with their discovered parent relationships
            # First, ensure all branches in the parent map are tracked
            for branch in "${!branch_parent_map[@]}"; do
                if git show-ref --verify --quiet "refs/heads/$branch"; then
                    gt track "$branch" -q 2>/dev/null || true
                fi
            done

            # Now set the correct parent relationships
            for branch in "${!branch_parent_map[@]}"; do
                if git show-ref --verify --quiet "refs/heads/$branch"; then
                    local parent="${branch_parent_map[$branch]}"
                    if [ -n "$parent" ]; then
                        gt track "$branch" --parent "$parent" -q 2>/dev/null || true
                    fi
                fi
            done

            log "Tracked all branches with Graphite"

            # Get stack output again
            stack_output=$(gt ls --no-interactive 2>/dev/null || echo "")
        fi

        # Check if the target branch exists in the stack
        if ! echo "$stack_output" | grep -q "$target_branch"; then
            echo "Error: Branch '$target_branch' not found in stack" >&2
            echo "Available branches in stack:" >&2
            echo "$stack_output" | grep -E "^[[:space:]]*[│├└]" | sed 's/^[[:space:]]*[│├└][─\s]*/  /' >&2
            exit 2
        fi

        # Build the complete chain of branches from main to target
        # We'll use gt to discover the full ancestry even for remote-only branches
        local branches_to_create=()
        local current="$target_branch"
        local visited_branches=()
        local max_depth=50  # Prevent infinite loops

        # First, ensure the target branch exists locally or remotely
        if ! git show-ref --verify --quiet "refs/heads/$target_branch" && \
           ! git show-ref --verify --quiet "refs/remotes/origin/$target_branch"; then
            echo "Error: Branch '$target_branch' does not exist locally or on origin" >&2
            exit 2
        fi

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

            # Try to get parent from gt metadata, even for remote-only branches
            local parent=""

            # First check if branch exists locally
            if git show-ref --verify --quiet "refs/heads/$current"; then
                # Branch exists locally, use normal get_branch_parent
                parent=$(get_branch_parent "$current")
            else
                # Branch only exists on remote, try to extract parent from gt metadata
                # Fetch the branch to make it available locally (but don't check it out)
                log "Fetching remote branch: $current"
                git fetch origin "$current:refs/remotes/origin/$current" 2>/dev/null || true

                # Try to get parent info from gt by temporarily tracking the remote branch
                # Create a temporary local ref to query gt
                git update-ref "refs/heads/temp-stack-query-$current" "refs/remotes/origin/$current" 2>/dev/null || true

                # Now try to get parent from gt metadata
                parent=$(gt branch info "temp-stack-query-$current" 2>/dev/null | grep "^Parent:" | sed 's/^Parent:[[:space:]]*//' | cut -d' ' -f1) || true

                # Clean up temporary ref
                git update-ref -d "refs/heads/temp-stack-query-$current" 2>/dev/null || true

                # If we still don't have a parent, try parsing the stack output directly
                if [ -z "$parent" ]; then
                    # Look for the current branch in the stack output and find its parent
                    # The parent is the branch that appears directly above in the tree structure
                    parent=$(echo "$stack_output" | awk -v branch="$current" '
                        /^[[:space:]]*[│├└]/ {
                            # Extract branch name from the line
                            gsub(/^[[:space:]]*[│├└][─\s]*/, "")
                            gsub(/[[:space:]]*\(.*\)[[:space:]]*$/, "")
                            gsub(/^[[:space:]]*/, "")
                            gsub(/[[:space:]]*$/, "")

                            if (prev && $0 == branch) {
                                print prev_branch
                                exit
                            }

                            prev = 1
                            prev_branch = $0
                        }
                    ')
                fi
            fi

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
                # Ensure the branch exists locally before creating worktree
                if ! git show-ref --verify --quiet "refs/heads/$branch"; then
                    if git show-ref --verify --quiet "refs/remotes/origin/$branch"; then
                        git fetch origin "$branch:$branch" 2>/dev/null || true
                    fi
                fi

                if ! create_worktree "$branch"; then
                    echo "Error: Failed to create worktree for branch '$branch'" >&2
                    exit 3
                fi
                created_count=$((created_count + 1))
            fi

            # Create tmux session if requested
            if [ "$create_sessions" = true ]; then
                create_tmux_session_for_worktree "$branch" "$worktree_path" "$PROJECT_NAME"
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