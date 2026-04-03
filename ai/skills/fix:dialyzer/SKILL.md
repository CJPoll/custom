---
name: fix:dialyzer
description: Resolve Dialyzer type analysis issues iteratively, fixing the first 5 issues per iteration with parallel subagents.
---

# Dialyzer Issue Resolution

Systematically resolve Dialyzer type analysis issues while maintaining code functionality and type safety.

## Commands

- **Full application**: `mix dialyzer`
- **Compilation check**: `mix compile`

**Critical constraints**:
- Dialyzer cannot be run against single files — always analyzes the entire application
- Fix maximum **5 issues per iteration** — always the **first 5 issues** in output order

## Process

Follow the iterative resolution process at @~/.claude/skills/processes:fix/SKILL.md using the commands above, with these Dialyzer-specific overrides:

- **Max iterations**: 20 (Dialyzer issues can cascade)
- **Batch size**: 5 (first 5 issues in Dialyzer output order — no reordering)
- **Convergence**: Each iteration must resolve at least 1 of the targeted 5 issues

## Dialyzer-Specific Guidance

### Issue Categories

- **Type mismatch**: Function return types don't match specifications
- **Missing specs**: Functions lack proper `@spec` declarations
- **Contract violation**: Type contracts violated by implementation
- **Unreachable code**: Dead code or impossible execution paths
- **Pattern matching**: Incomplete or impossible pattern matches
- **External calls**: Issues with external library function calls

### Resolution Strategies

**Add type specs**: Add missing `@spec` declarations with correct types. Include all parameter types and return type variants. Consider error cases and exception types.

**Correct existing specs**: Fix incorrect type specifications. Determine if `@spec` needs correction or implementation needs adjustment.

**Refine implementation**: Adjust code to match intended type contracts. Apply minimal fix that preserves function semantics.

**Pattern match completion**: Add missing pattern match clauses. Include appropriate default cases or error handling. Validate pattern completeness with Dialyzer's expectations.

**Guard clause addition**: Add guard clauses for type safety where appropriate.

**External type handling**: Properly handle external library types and their contracts.

### Quality Gates

- Each iteration must resolve at least 1 of the targeted 5 issues
- No fixes may introduce new Dialyzer issues or break compilation
- All type specifications must accurately reflect function behavior
- Type contracts must be consistent across module boundaries
- Maximum 20 iterations before escalating to manual review

### Parallelization Rules

- No more than one subagent per file simultaneously
- Coordinate type specification changes that affect multiple modules
- Lock shared type definitions during modification
- Prevent concurrent modification of related function signatures

### Error Recovery

- **PLT build failure**: Execute `mix dialyzer --plt` to rebuild, then retry
- **Compilation breakdown**: Revert recent changes and apply more conservative fixes
- **Type consistency conflict**: Coordinate type resolution across modules or rollback
