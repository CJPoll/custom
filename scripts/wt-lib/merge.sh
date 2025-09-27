#!/bin/bash
# merge.sh - Merge and rebase operations for wt scripts
# This file is meant to be sourced, not executed directly

# Prevent direct execution
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    echo "Error: This script is meant to be sourced, not executed directly" >&2
    exit 1
fi

# Include guard to prevent multiple sourcing
if [[ -z "${WT_LIB_MERGE_SOURCED:-}" ]]; then
    WT_LIB_MERGE_SOURCED="true"

    # Source dependencies
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    source "${SCRIPT_DIR}/common.sh"
    source "${SCRIPT_DIR}/worktree.sh"
    source "${SCRIPT_DIR}/stack.sh"
    source "${SCRIPT_DIR}/stack-advanced.sh"

    merge_worktree() {
        local branch_to_merge="$1"
        local merge_into="${2:-main}"
        local keep_branch="${3:-false}"

        log "Starting merge of '$branch_to_merge' into '$merge_into'"

        # Check if branch exists
        if ! branch_exists_locally "$branch_to_merge"; then
            error "Branch '$branch_to_merge' does not exist locally"
        fi

        # Ensure we have a worktree for the target branch
        local target_worktree=$(get_worktree_dir "$merge_into")
        if [ -z "$target_worktree" ]; then
            error "No worktree found for branch '$merge_into'. Create one with: wt create $merge_into"
        fi

        # Get the branch's children before merging (if using graphite)
        local children=()
        if command -v gt &>/dev/null; then
            mapfile -t children < <(get_branch_children "$branch_to_merge")
        fi

        # Switch to the target worktree
        log "Switching to $merge_into worktree"
        switch_worktree "$merge_into"

        # Update the target branch
        log "Pulling latest changes for $merge_into"
        git pull origin "$merge_into" --ff-only || {
            error "Failed to update $merge_into. Resolve conflicts manually."
        }

        # Perform the merge
        log "Merging $branch_to_merge into $merge_into"
        if ! git merge "$branch_to_merge" --no-edit; then
            error "Merge failed. Resolve conflicts and commit, then run: wt merge-continue $branch_to_merge"
        fi

        # Push the merged changes
        log "Pushing merged changes"
        git push origin "$merge_into" || {
            error "Failed to push. Resolve any issues and push manually."
        }

        # Handle children if any exist
        if [ ${#children[@]} -gt 0 ]; then
            log "Found ${#children[@]} child branches that need rebasing:"
            for child in "${children[@]}"; do
                log "  - $child"
            done

            # Rebase children
            rebase_children_after_merge "$branch_to_merge" "$merge_into" "${children[@]}"
        fi

        # Clean up the merged branch
        if [ "$keep_branch" = "false" ]; then
            log "Cleaning up merged branch"

            # Remove the worktree
            local merged_worktree=$(get_worktree_dir "$branch_to_merge")
            if [ -n "$merged_worktree" ]; then
                log "Removing worktree for $branch_to_merge"
                git worktree remove "$merged_worktree" --force
            fi

            # Delete the local branch
            git branch -d "$branch_to_merge" 2>/dev/null || \
            git branch -D "$branch_to_merge" 2>/dev/null || \
            log "Could not delete local branch (might still be checked out somewhere)"

            # Delete the remote branch
            log "Deleting remote branch"
            git push origin --delete "$branch_to_merge" 2>/dev/null || \
            log "Could not delete remote branch (might already be deleted or protected)"
        else
            log "Keeping branch $branch_to_merge as requested"
        fi

        log "✓ Merge completed successfully!"
    }

    rebase_children_after_merge() {
        local merged_branch="$1"
        local new_parent="$2"
        shift 2
        local children=("$@")

        if [ ${#children[@]} -eq 0 ]; then
            return 0
        fi

        log ""
        log "Rebasing child branches onto $new_parent..."

        local failed_rebases=()

        for child in "${children[@]}"; do
            log ""
            log "Processing child branch: $child"

            # Ensure we have a worktree for this child
            local child_worktree=$(get_worktree_dir "$child")
            if [ -z "$child_worktree" ]; then
                log "  Creating worktree for $child"
                create_worktree "$child"
                child_worktree=$(get_worktree_dir "$child")
            fi

            # Switch to the child worktree
            log "  Switching to $child worktree"
            switch_worktree "$child"

            # Update parent metadata if using graphite
            if command -v gt &>/dev/null; then
                log "  Updating parent metadata to $new_parent"
                gt branch parent -s "$new_parent"
            fi

            # Perform the rebase
            log "  Rebasing $child onto $new_parent"
            if ! git rebase "$new_parent"; then
                log "  ⚠ Rebase conflict! Resolve conflicts and run: git rebase --continue"
                failed_rebases+=("$child")
                git rebase --abort
                continue
            fi

            # Push the rebased branch
            log "  Force pushing rebased $child"
            git push --force-with-lease origin "$child"

            log "  ✓ Successfully rebased $child"

            # Recursively handle this child's children
            local grandchildren=()
            if command -v gt &>/dev/null; then
                mapfile -t grandchildren < <(get_branch_children "$child")
            fi

            if [ ${#grandchildren[@]} -gt 0 ]; then
                log "  Found ${#grandchildren[@]} grandchildren to rebase"
                rebase_children_after_merge "$merged_branch" "$child" "${grandchildren[@]}"
            fi
        done

        if [ ${#failed_rebases[@]} -gt 0 ]; then
            log ""
            log "⚠ Warning: The following branches had rebase conflicts:"
            for branch in "${failed_rebases[@]}"; do
                log "  - $branch"
            done
            log "Please resolve these manually."
        fi

        # Return to the new parent branch
        log ""
        log "Returning to $new_parent"
        switch_worktree "$new_parent"
    }

fi # End of include guard