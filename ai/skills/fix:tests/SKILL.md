---
name: fix:tests
description: Fix failing ExUnit tests iteratively using parallel subagents with regression prevention.
---

# ExUnit Test Resolution

Achieve 100% test suite success rate through systematic issue identification and parallel resolution.

## Commands

Tests must run inside the Docker `app` service container — running `mix test`
directly on the host connects to the wrong Postgres instance (`walt-ui-db`
instead of `gen_saas-postgres-1`) and hits its 300-connection limit.

- **Full suite**: `./bin/checks/test.sh`
- **Single file**: `./bin/checks/test.sh <file>`
- **Compilation check**: `docker compose run --rm -e MIX_ENV=test app mix compile`

`./bin/checks/test.sh` wraps `docker compose run --rm -e MIX_ENV=test app mix test --max-failures 5`.
The `MIX_ENV=test` flag is required — the `app` service defaults to `MIX_ENV=dev`,
and omitting it causes sandbox pool errors in umbrella child apps.

## Process

Follow the iterative resolution process at @~/.claude/skills/processes:fix/SKILL.md using the commands above.

## Test-Specific Guidance

### Error Categories (by priority)

1. **Compilation** — `CompileError`, `SyntaxError`, `UndefinedFunctionError`
2. **Dependency** — Module not available, dependency errors
3. **Setup** — `setup_all` failures, fixture issues
4. **Assertion** — `ExUnit.AssertionError`, `MatchError`
5. **Timeout** — `ExUnit.TimeoutError`

### Prioritization

| Factor | Weight | Description |
|--------|--------|-------------|
| Dependency impact | 40% | Files that block other tests from running |
| Error severity | 35% | Compilation=10, Dependency=8, Setup=6, Assertion=4, Timeout=2 |
| Failure density | 25% | failing_tests / total_tests_in_file |

### Repair Protocol

For each failing test file:
1. Analyze specific error messages and failure patterns
2. Identify root cause (missing imports, incorrect assertions, fixture issues)
3. Apply minimal fix addressing root cause
4. Test fix in isolation: `./bin/checks/test.sh <file>`
5. If fix successful, validate no side effects introduced
6. If fix fails, revert changes and try alternative approach

### Quality Gates

- Each iteration must reduce total failure count by at least 1
- No subagent may introduce failures to previously passing tests
- All code must maintain compilation after modifications
- Maximum 10 iterations before escalating to manual review
- **No modification to core application code** — only test files

### File Selection Rules

- Max 5 files per iteration
- No overlapping dependency conflicts between selected files
- Prefer files with compilation errors over assertion errors
- If files share critical dependencies, select only one per dependency group
- Coordinate changes to `mix.exs` or `test_helper.exs`

### Regression Prevention

- Verify no cross-file breaking changes after each subagent completion
- If cross-file conflicts detected, rollback conflicting changes
- Run full test suite after each iteration to detect regressions
