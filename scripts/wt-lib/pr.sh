#!/bin/bash
# pr.sh - Pull request and push operations for wt scripts
# This file is meant to be sourced, not executed directly

# Prevent direct execution
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    echo "Error: This script is meant to be sourced, not executed directly" >&2
    exit 1
fi

# Include guard to prevent multiple sourcing
if [[ -z "${WT_LIB_PR_SOURCED:-}" ]]; then
    WT_LIB_PR_SOURCED="true"

    # Source dependencies
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    source "${SCRIPT_DIR}/common.sh"
    source "${SCRIPT_DIR}/worktree.sh"
    source "${SCRIPT_DIR}/stack.sh"
    source "${SCRIPT_DIR}/stack-advanced.sh"

    create_stack_prs() {
        local open_in_browser="${1:-false}"

        # Check if Graphite is available
        if ! command -v gt &>/dev/null; then
            error "Graphite (gt) is required for creating stack PRs"
        fi

        # Get the current branch
        local current_branch=$(get_current_branch)
        if [ -z "$current_branch" ]; then
            error "Not in a git repository"
        fi

        log "Creating PRs for the current stack..."

        # First, ensure the stack is synced
        log "Syncing stack to ensure consistency..."
        gt stack sync --no-interactive || {
            error "Failed to sync stack. Please resolve any issues and try again."
        }

        # Create PRs for the stack
        log "Creating/updating PRs..."
        if [ "$open_in_browser" = "true" ]; then
            # Create PRs and open in browser
            gt stack submit --no-interactive --open || {
                error "Failed to create PRs. Please check the output above."
            }
        else
            # Create PRs without opening browser
            gt stack submit --no-interactive || {
                error "Failed to create PRs. Please check the output above."
            }
        fi

        log "✓ Stack PRs created/updated successfully!"

        # Show the PR URLs
        log ""
        log "PR URLs:"
        gt stack ls --no-interactive | grep -E "https://github.com/.*pull/[0-9]+" || true
    }

    push_stack() {
        local force="${1:-false}"

        # Check if Graphite is available
        if ! command -v gt &>/dev/null; then
            error "Graphite (gt) is required for pushing stacks"
        fi

        # Get the current branch
        local current_branch=$(get_current_branch)
        if [ -z "$current_branch" ]; then
            error "Not in a git repository"
        fi

        log "Pushing stack to remote..."

        # Get all branches in the stack
        local branches=($(get_stack_branches))
        if [ ${#branches[@]} -eq 0 ]; then
            error "No branches found in stack"
        fi

        log "Found ${#branches[@]} branches in stack to push:"
        for branch in "${branches[@]}"; do
            log "  - $branch"
        done
        log ""

        local failed_pushes=()
        local pushed_branches=()

        # Push each branch in the stack
        for branch in "${branches[@]}"; do
            # Get the worktree for this branch
            local worktree_path=$(get_worktree_dir "$branch")
            if [ -z "$worktree_path" ]; then
                log "⚠ No worktree for $branch, skipping..."
                continue
            fi

            log "Pushing $branch..."

            # Run git push in the worktree
            if [ "$force" = "true" ]; then
                if (cd "$worktree_path" && git push --force-with-lease origin "$branch"); then
                    log "  ✓ Force pushed $branch"
                    pushed_branches+=("$branch")
                else
                    log "  ✗ Failed to push $branch"
                    failed_pushes+=("$branch")
                fi
            else
                if (cd "$worktree_path" && git push origin "$branch"); then
                    log "  ✓ Pushed $branch"
                    pushed_branches+=("$branch")
                else
                    # Try with --set-upstream if this is the first push
                    if (cd "$worktree_path" && git push --set-upstream origin "$branch"); then
                        log "  ✓ Pushed $branch (with upstream set)"
                        pushed_branches+=("$branch")
                    else
                        log "  ✗ Failed to push $branch"
                        failed_pushes+=("$branch")
                    fi
                fi
            fi
        done

        # Summary
        log ""
        log "Push Summary:"
        log "  Successful: ${#pushed_branches[@]} branches"
        if [ ${#failed_pushes[@]} -gt 0 ]; then
            log "  Failed: ${#failed_pushes[@]} branches"
            for branch in "${failed_pushes[@]}"; do
                log "    - $branch"
            done
            log ""
            log "To force push failed branches, run: wt push-stack --force"
            return 1
        fi

        log ""
        log "✓ Stack pushed successfully!"
    }

    # Helper function to push a single branch
    push_branch() {
        local branch="${1:-$(get_current_branch)}"
        local force="${2:-false}"

        if [ -z "$branch" ]; then
            error "No branch specified and could not determine current branch"
        fi

        local worktree_path=$(get_worktree_dir "$branch")
        if [ -z "$worktree_path" ]; then
            error "No worktree found for branch: $branch"
        fi

        log "Pushing $branch..."

        if [ "$force" = "true" ]; then
            if (cd "$worktree_path" && git push --force-with-lease origin "$branch"); then
                log "✓ Force pushed $branch"
            else
                error "Failed to push $branch"
            fi
        else
            if (cd "$worktree_path" && git push origin "$branch"); then
                log "✓ Pushed $branch"
            elif (cd "$worktree_path" && git push --set-upstream origin "$branch"); then
                log "✓ Pushed $branch (with upstream set)"
            else
                error "Failed to push $branch"
            fi
        fi
    }

    # Create a single PR for the current branch
    create_pr() {
        local open_in_browser="${1:-false}"

        if ! command -v gt &>/dev/null; then
            error "Graphite (gt) is required for creating PRs"
        fi

        local current_branch=$(get_current_branch)
        if [ -z "$current_branch" ]; then
            error "Not in a git repository"
        fi

        log "Creating PR for $current_branch..."

        # Ensure the branch is pushed
        push_branch "$current_branch" false

        # Create the PR
        if [ "$open_in_browser" = "true" ]; then
            gt branch submit --no-interactive --open || {
                error "Failed to create PR"
            }
        else
            gt branch submit --no-interactive || {
                error "Failed to create PR"
            }
        fi

        log "✓ PR created successfully!"
    }

fi # End of include guard