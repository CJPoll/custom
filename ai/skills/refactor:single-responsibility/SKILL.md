---
name: refactor:single-responsibility
description: Refactor functions to have a single control flow structure each (pipe, case, cond, with, if, unless) while preserving functionality.
argument-hint: <file paths>
---

# Single Control-Flow Refactoring

Enforce the Single Control-Flow Principle: each function has exactly one control flow structure while preserving functionality and improving code clarity.

**Files**: $ARGUMENTS

**Parallel processing**: When multiple files are provided, process each independently in parallel using separate subagents.

## Quality Principles

1. **Clarity of Intent** — Each function has one clear, well-named purpose
2. **Consistency of Naming** — Function names indicate their control-flow type and domain responsibility
3. **Single Responsibility** — One function, one control-flow structure, one logical concern

## Control Flow Structures

Tracked structures:
- **Pipe chains** (`|>` sequences)
- **Pattern matching** (`case`, `cond`, `with`)
- **Conditional logic** (`if`, `unless`)
- **Exception handling** (`try/catch`, `rescue`)

**Exclusion**: Function head pattern matching is NOT counted as control-flow nesting.

## The Rule

A single function implementation MUST NOT have more than one control flow structure from the list above. This implies no nested control flow structures.

## Refactoring Process

### 1. Analyze

- Scan for functions containing multiple control flow structures
- Map each function's control flow nesting depth and types
- Identify which functions violate the single control-flow principle
- Assess complexity and refactoring difficulty

### 2. Plan Extraction

For each violating function:
- Identify the dominant control flow (the one that stays)
- Identify extractable control flow blocks
- Name extracted functions based on their domain purpose (not their mechanism)
- Determine appropriate visibility (public vs private)

### 3. Refactor

- Extract secondary control flow into dedicated functions
- Name extracted functions descriptively
- Update the original function to call the extracted functions
- Preserve all function signatures and return types
- Maintain error handling behavior

### 4. Validate

- All tests pass
- No new control flow violations introduced
- Function behavior preserved exactly
- Code compiles without warnings

## Naming Guidance for Extracted Functions

**Good** — named for domain purpose:
- `calculate_total/1`, `validate_input/1`, `format_response/1`
- `transform_data/1`, `build_query/1`, `extract_results/1`

**Bad** — named for mechanism:
- `do_pipe/1`, `handle_case/1`, `process_with/1`

## Example

For detailed transformation examples, see the `/limit-branching` skill which demonstrates the same principle with concrete Elixir code samples.

## Error Prevention

- Never change the public API of the module
- Never alter return types or error handling
- Test after each extraction to catch regressions early
- Keep extracted functions close to their callers (same module)
