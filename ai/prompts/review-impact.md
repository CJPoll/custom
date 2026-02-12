# review-impact

Analyze the current PR's changes to identify which framework entry points (controllers, handlers, queue workers) could be impacted via transitive call dependency.

## Process

1. **Gather the diff** - Get the changed files and functions in the current branch compared to the base branch
2. **Classify changed modules** - For each changed file, classify it into its architectural bucket:
   - Framework (controllers, handlers, workers, middleware)
   - UI Components
   - Side Effects (adapters/repositories)
   - Domain (side-effect-free business logic)
   - Managers (orchestration)
3. **Trace callers transitively** - For each changed module/function, walk the call graph *upward* through callers until reaching framework entry points
4. **Report the impact map** - Present the results

## Tracing Rules

- Start from each changed function/module
- Find all direct callers of that function/module within the codebase
- For each caller, repeat the search until you reach a framework entry point or exhaust the call chain
- Track the full path from changed code to entry point

Framework entry points include:
- HTTP controllers/handlers (e.g. Phoenix controllers, Rails controllers, Express route handlers)
- WebSocket/channel handlers
- Queue/job workers (e.g. Oban workers, Sidekiq jobs, background processors)
- Scheduled tasks / cron handlers
- CLI entry points
- LiveView modules

## Output Format

### Summary

A count of impacted entry points by type (controllers, workers, channels, etc.).

### Impact Map

For each framework entry point that could be impacted:

```
EntryPoint (type)
  └── action/function affected
      └── calls ManagerOrService.function()
          └── calls ChangedModule.changed_function()  ← CHANGED
```

Group by entry point type. Within each group, sort by the depth of the
dependency chain (direct callers first, deeply transitive last).

### Direct Framework Changes

List any framework entry points that were themselves directly modified in the
diff. These don't need a dependency trace — just flag them.

### Risk Notes

Flag any of the following if detected:
- A single changed function that fans out to many entry points (high blast radius)
- Changes to shared utilities or base modules used broadly
- Changes to adapter interfaces that multiple managers depend on
- Changes to domain modules that are core to many workflows

$ARGUMENTS
