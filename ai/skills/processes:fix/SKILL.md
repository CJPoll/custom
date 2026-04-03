---
name: processes:fix
description: Generic iterative issue resolution process using parallel subagents. Referenced by fix:tests, fix:credo, fix:dialyzer, fix:compilation, and fix:jest.
user-invocable: false
---

# Iterative Issue Resolution Process

Systematically resolve issues across an entire application using parallel subagent processing. This is a generic process — the calling skill provides the specific tool commands.

## Iterative Workflow

Repeat this cycle until zero issues remain or stagnation is detected:

### Step 1: Global Analysis

Run the designated analysis tool against the entire application.

**Capture**: Complete output, exit code, issue count, severity breakdown, file-specific details with line numbers.

**If zero issues**: SUCCESS — process complete.
**If issues found**: Continue to step 2.

### Step 2: Prioritize and Select Files

Select up to **5 files** with the highest-impact issues for parallel processing.

**Prioritization factors**:

| Factor | Weight | Description |
|--------|--------|-------------|
| Severity impact | 40% | Critical/high-severity issues take priority |
| Issue density | 30% | Issues per line of code |
| File importance | 20% | Business logic > config > tests |
| Fix complexity | 10% | Prefer higher auto-fixable ratio |

**Selection constraints**:
- Maximum 5 files per iteration
- No shared dependencies between selected files (avoid conflicts)
- Files must be independently modifiable in parallel

### Step 3: Parallel Subagent Execution

Deploy one subagent per selected file, processing concurrently.

**Each subagent**:
1. Verify file compiles/parses before modifications
2. Establish baseline issue count for the file
3. Fix issues in severity order (critical → low)
4. Apply tool-suggested fixes when safe; analyze complex issues carefully
5. Preserve semantics — all changes must maintain original behavior
6. Verify file still compiles after modifications
7. Run analysis tool on modified file to confirm resolution (if single-file mode available)

**Subagent reports**: resolution status (SUCCESS/PARTIAL/FAILURE), issues resolved, issues remaining, changes made.

**Error recovery**:
- **Compilation failure**: Revert to backup, try more conservative fix
- **New issues introduced**: Analyze root cause, revert or fix
- **Unable to resolve after 3 attempts**: Mark for manual review, continue

### Step 4: Integration Validation

Re-run the analysis tool against the entire application.

**Collect metrics**: Total issues, issue reduction, new issues, resolved files.

**Validate**: Application still compiles/builds successfully.

**Decision tree**:

| Condition | Outcome | Action |
|-----------|---------|--------|
| Zero issues | **SUCCESS** | Process complete |
| Issues reduced, no regressions, compiles | **PROGRESS** | Return to step 1 |
| No progress for 3 consecutive iterations | **STAGNATION** | Escalate to manual review |
| New issues or compilation failure | **REGRESSION** | Rollback problematic changes |

## Quality Gates

- Each iteration must reduce total issue count by at least 1
- Application must maintain compilation integrity throughout
- No subagent may introduce regressions or new issues
- All changes must preserve functionality and semantics
- Auto-fixable issues applied when safe and beneficial
- Complex issues analyzed for architectural impact
