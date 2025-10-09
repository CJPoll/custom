#!/bin/bash
# worktree.sh - Worktree management functions for wt scripts
# This file is meant to be sourced, not executed directly

# Prevent direct execution
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    echo "Error: This script is meant to be sourced, not executed directly" >&2
    exit 1
fi

# Include guard to prevent multiple sourcing
if [[ -z "${WT_LIB_WORKTREE_SOURCED:-}" ]]; then
    WT_LIB_WORKTREE_SOURCED="true"

    # Source dependencies
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    source "${SCRIPT_DIR}/common.sh"

init_worktrees() {
    log "Initializing worktrees directory..."

    if [ ! -d "$PROJECT_DIR/.git" ]; then
        echo "Error: Not in a git repository" >&2
        exit 1
    fi

    mkdir -p "$WORKTREES_DIR"

    log "Worktrees directory initialized at: $WORKTREES_DIR"
}

list_worktrees() {
    if [ ! -d "$WORKTREES_DIR" ]; then
        echo "No worktrees directory found. Run 'wt init' first."
        return 0
    fi

    echo "Worktrees for $PROJECT_NAME:"
    echo ""

    # Get git worktree list output
    local git_worktrees
    git_worktrees=$(git worktree list --porcelain 2>/dev/null || echo "")

    if [ -z "$git_worktrees" ]; then
        echo "No worktrees found."
        return 0
    fi

    # Parse porcelain output
    local worktree_path=""
    local branch=""
    local commit=""
    local is_detached=false
    local is_current=false
    local worktrees_found=false

    # Add header
    printf "%-40s %-25s %s\n" "Branch/Worktree" "Status" "Location"
    printf "%s\n" "$(printf '%.0s-' {1..90})"

    while IFS= read -r line; do
        if [[ "$line" =~ ^worktree[[:space:]](.+) ]]; then
            # Process previous worktree if exists
            if [ -n "$worktree_path" ]; then
                # Only show worktrees in our worktrees directory or the main project
                if [[ "$worktree_path" == "$WORKTREES_DIR/"* ]] || [[ "$worktree_path" == "$PROJECT_DIR" ]]; then
                    local display_branch=""
                    local display_path=""
                    local status=""

                    # Determine display path
                    if [[ "$worktree_path" == "$PROJECT_DIR" ]]; then
                        display_path="(main project)"
                    else
                        display_path="${worktree_path#$WORKTREES_DIR/}"
                    fi

                    # Build branch display and status
                    if [ "$is_detached" = true ]; then
                        # For detached HEAD, show the short commit SHA
                        if [ -n "$commit" ]; then
                            display_branch="${commit:0:8} (detached)"
                        else
                            display_branch="detached HEAD"
                        fi
                        status="detached"
                    else
                        display_branch="${branch:-unknown}"
                        status="on branch"
                    fi

                    # Mark current
                    if [ "$is_current" = true ]; then
                        status="$status [current]"
                        printf "► %-38s %-25s %s\n" "$display_branch" "$status" "$display_path"
                    else
                        printf "  %-38s %-25s %s\n" "$display_branch" "$status" "$display_path"
                    fi

                    worktrees_found=true
                fi
            fi

            # Reset for new worktree
            worktree_path="${BASH_REMATCH[1]}"
            branch=""
            commit=""
            is_detached=false
            is_current=false

            # Check if this is the current directory
            if [[ "$(pwd)" == "$worktree_path" ]]; then
                is_current=true
            fi
        elif [[ "$line" =~ ^HEAD[[:space:]](.+) ]]; then
            commit="${BASH_REMATCH[1]}"
        elif [[ "$line" =~ ^branch[[:space:]]refs/heads/(.+) ]]; then
            branch="${BASH_REMATCH[1]}"
        elif [[ "$line" == "detached" ]]; then
            is_detached=true
        fi
    done <<< "$git_worktrees"

    # Process last worktree
    if [ -n "$worktree_path" ]; then
        if [[ "$worktree_path" == "$WORKTREES_DIR/"* ]] || [[ "$worktree_path" == "$PROJECT_DIR" ]]; then
            local display_branch=""
            local display_path=""
            local status=""

            # Determine display path
            if [[ "$worktree_path" == "$PROJECT_DIR" ]]; then
                display_path="(main project)"
            else
                display_path="${worktree_path#$WORKTREES_DIR/}"
            fi

            # Build branch display and status
            if [ "$is_detached" = true ]; then
                # For detached HEAD, show the short commit SHA
                if [ -n "$commit" ]; then
                    display_branch="${commit:0:8} (detached)"
                else
                    display_branch="detached HEAD"
                fi
                status="detached"
            else
                display_branch="${branch:-unknown}"
                status="on branch"
            fi

            # Mark current
            if [ "$is_current" = true ]; then
                status="$status [current]"
                printf "► %-38s %-25s %s\n" "$display_branch" "$status" "$display_path"
            else
                printf "  %-38s %-25s %s\n" "$display_branch" "$status" "$display_path"
            fi

            worktrees_found=true
        fi
    fi

    if [ "$worktrees_found" = false ]; then
        echo "No worktrees found in $WORKTREES_DIR"
    fi
}

remove_worktree() {
    local branch="$1"
    local worktree_path="$WORKTREES_DIR/$branch"

    if [ -z "$branch" ]; then
        echo "Error: Branch name is required" >&2
        return 1
    fi

    if [ ! -d "$worktree_path" ]; then
        echo "Error: Worktree not found at: $worktree_path" >&2
        return 1
    fi

    log "Removing worktree for branch: $branch"

    # Get the project name from the current directory
    local project_name=$(basename "$PROJECT_DIR")

    # Create session name with worktree info
    # Replace slashes in branch name with dashes to avoid tmux issues
    local safe_branch=$(echo "$branch" | tr '/' '-')
    local session_name="${project_name}-wt-${safe_branch}"

    # Check if tmux session exists and kill it (use exact matching)
    if tmux has-session -t "=$session_name" 2>/dev/null; then
        log "Killing tmux session: $session_name"
        run_cmd tmux kill-session -t "=$session_name"
    fi

    # Remove the worktree
    run_cmd git worktree remove "$worktree_path" --force

    # Clean up any remaining directory if it exists
    if [ -d "$worktree_path" ]; then
        rm -rf "$worktree_path"
    fi

    # Prune worktree metadata
    run_cmd git worktree prune

    log "Worktree removed: $branch"
}

switch_worktree() {
    local branch="$1"
    local worktree_path="$WORKTREES_DIR/$branch"
    local PR_REVIEW="${PR_REVIEW:-false}"
    local PARENT_BRANCH="${PARENT_BRANCH:-main}"

    if [ -z "$branch" ]; then
        echo "Error: Branch name is required" >&2
        return 1
    fi

    # Special handling for main/master branch - use project root
    if [ "$branch" = "main" ] || [ "$branch" = "master" ]; then
        worktree_path="$PROJECT_DIR"
        # Check if the branch matches what's actually in the project root
        local project_branch=$(git -C "$PROJECT_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null)
        if [ "$project_branch" != "$branch" ]; then
            echo "Error: Project root is on branch '$project_branch', not '$branch'" >&2
            return 1
        fi
    elif [ ! -d "$worktree_path" ]; then
        echo "Error: Worktree not found at: $worktree_path" >&2
        echo "Available worktrees:" >&2
        if [ -d "$WORKTREES_DIR" ]; then
            ls -1 "$WORKTREES_DIR" 2>/dev/null | sed 's/^/  /' >&2
        fi
        return 1
    fi

    log "Switching to worktree: $branch"

    # Get the project name from the current directory
    local project_name=$(basename "$PROJECT_DIR")

    # Create session name
    if [ "$branch" = "main" ] || [ "$branch" = "master" ]; then
        # Main branch uses just the project name
        local session_name="$project_name"
    else
        # Worktrees use project-wt-branch format
        # Replace slashes in branch name with dashes to avoid tmux issues
        local safe_branch=$(echo "$branch" | tr '/' '-')
        local session_name="${project_name}-wt-${safe_branch}"
    fi

    # Check if we're in a tmux session
    if [ -n "${TMUX:-}" ]; then
        # We're in tmux, use proj to switch/create sessions
        # Call proj directly, with optional --pr-review flag
        if [ "$PR_REVIEW" = true ]; then
            # For stack-aware PR review, detect the actual parent branch
            local review_base_branch="$PARENT_BRANCH"
            if [ "$PARENT_BRANCH" = "main" ] || [ "$PARENT_BRANCH" = "master" ]; then
                # If using default, try to detect the actual parent from git config
                if declare -f get_branch_parent >/dev/null 2>&1; then
                    local detected_parent=$(get_branch_parent "$branch")
                    if [ -n "$detected_parent" ]; then
                        review_base_branch="$detected_parent"
                        log "Using detected parent branch for PR review: $review_base_branch"
                    fi
                fi
            fi
            proj "$session_name" --path "$worktree_path" --pr-review --base-branch "$review_base_branch"
        else
            proj "$session_name" --path "$worktree_path"
        fi
    else
        # Not in tmux, output the cd command for the user to execute
        if [ "$QUIET" = true ]; then
            # In quiet mode, just output the path
            echo "$worktree_path"
        else
            log "Not in tmux session. To switch to the worktree, run:"
            log ""
            echo "cd $worktree_path"
        fi
    fi
}

get_worktree_dir() {
    local branch="$1"

    if [ -z "$branch" ]; then
        return 1
    fi

    # Special handling for main/master branch - use project root
    if [ "$branch" = "main" ] || [ "$branch" = "master" ]; then
        # Check if the branch matches what's actually in the project root
        local project_branch=$(git -C "$PROJECT_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null)
        if [ "$project_branch" = "$branch" ]; then
            echo "$PROJECT_DIR"
            return 0
        else
            return 1
        fi
    fi

    # Check for worktree in the standard location
    local worktree_path="$WORKTREES_DIR/$branch"
    if [ -d "$worktree_path" ]; then
        # Verify it's actually a worktree for this branch
        local worktree_branch=$(git -C "$worktree_path" rev-parse --abbrev-ref HEAD 2>/dev/null)
        if [ "$worktree_branch" = "$branch" ]; then
            echo "$worktree_path"
            return 0
        fi
    fi

    return 1
}

is_worktree() {
    local dir="${CHECK_DIR:-$(pwd)}"

    # Get the absolute path
    dir="$(realpath "$dir" 2>/dev/null)" || return 2

    # Check if directory is an immediate child of any DEVPATH directory
    if [[ -n "$DEVPATH" ]]; then
        # Split DEVPATH by colon
        IFS=':' read -ra DEV_DIRS <<< "$DEVPATH"
        for dev_dir in "${DEV_DIRS[@]}"; do
            # Expand the dev_dir path (handle ~ and variables)
            dev_dir="$(eval echo "$dev_dir")"
            dev_dir="$(realpath "$dev_dir" 2>/dev/null)" || continue

            # Check if dir is an immediate child of this dev_dir
            local parent_dir="$(dirname "$dir")"
            if [[ "$parent_dir" == "$dev_dir" ]]; then
                # This is a project root directory, not a worktree
                return 1
            fi
        done
    fi

    # Find the git directory by traversing up from the target directory
    local git_dir="$dir"
    while [[ "$git_dir" != "/" ]]; do
        if [[ -d "$git_dir/.git" ]] || [[ -f "$git_dir/.git" ]]; then
            # Check if git worktree list contains this directory
            if git -C "$git_dir" worktree list 2>/dev/null | grep -q "^$dir\s"; then
                return 0
            else
                return 2
            fi
        fi
        git_dir="$(dirname "$git_dir")"
    done

    # Not in a git repository
    return 2
}

fi # End of include guard