---
name: pr-update
description: Update the current PR name and description to match the branch state.
disable-model-invocation: true
---

Using @~/dev/custom/scripts/wt, the `gt` command, and the `gh` command if
necessary, let's update the PR name and description to match the current state
of the branch. Remove any irrelevant or obsolete information from both.
