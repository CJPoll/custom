---
name: fix:credo
description: Resolve Credo code quality violations iteratively using parallel subagents with strict mode enforcement.
---

# Credo Violation Resolution

Achieve zero Credo violations in strict mode while maintaining code functionality and readability.

## Commands

- **Full codebase**: `mix credo --strict`
- **Single file**: `mix credo --strict <file>`
- **Compilation check**: `mix compile`

The `--strict` flag is mandatory for comprehensive violation detection.

## Process

Follow the iterative resolution process at @~/.claude/skills/processes:fix/SKILL.md using the commands above.

## Credo-Specific Guidance

### Violation Categories

- **Consistency**: Code style and formatting issues
- **Design**: Architectural and design pattern violations
- **Readability**: Code clarity and comprehension issues
- **Refactor**: Code complexity and maintainability issues
- **Warning**: Potential bugs and performance issues

### Severity Priority Order

1. **Critical** — blocking issues requiring immediate attention
2. **High** — important quality issues
3. **Normal** — standard code quality improvements
4. **Low** — minor style and consistency issues

### Fix Strategies by Type

**Auto-fixable violations**: Apply Credo's suggested fixes when safe and semantics-preserving.

**Design violations**: Carefully evaluate architectural impact. Maintain existing API contracts and behavior.

**Consistency violations**: Ensure fixes align with project-wide patterns and team coding standards.

**Performance warnings**: Validate fixes don't degrade runtime characteristics. Prefer performance-neutral or improving fixes.

**Tuple pattern conflicts (NoTupleMatchInHead vs CaseOnBareArg)**: These require special handling — see [reference.md](reference.md) for the resolution strategy.

### Quality Gates

- Each iteration must reduce total violation count
- No subagent may break compilation or introduce new violations
- All fixes must preserve code semantics and performance
- Auto-fixable violations processed first within each severity level
- Maximum 10 iterations before escalating to manual review

### File Selection

When selecting files for parallel processing:
- Max 5 files per iteration
- No circular dependencies or shared module conflicts between selected files
- Files must be modifiable independently without cross-impact
- Avoid simultaneous modification of macro-defining and macro-using files

For detailed Credo rule patterns and fix examples, see [reference.md](reference.md).
