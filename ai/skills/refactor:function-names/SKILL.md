---
name: refactor:function-names
description: Enforce function naming conventions that distinguish side-effect functions from pure functions in Elixir.
argument-hint: <file paths>
---

# Function Naming Refactoring

Enforce naming conventions that distinguish side-effect functions from pure functions, improving code clarity and intent.

**Files**: $ARGUMENTS

**Parallel processing**: When multiple files are provided, process each independently in parallel using separate subagents.

## Quality Principles

1. **Clarity of Intent** — Function names immediately communicate whether they have side effects or are pure transformations
2. **Consistency of Naming** — Imperative names for side-effect functions; descriptive names for pure functions
3. **Single Responsibility** — Each function has one clear purpose reflected in its naming pattern

## Naming Rules

### Side-Effect Functions (imperative verbs allowed)

Functions with side effects (CRUD, I/O, state mutations) may use imperative names:
- `get_*`, `list_*` — database queries, API calls
- `create_*`, `update_*`, `delete_*` — persistence operations
- `save_*` — persistence operations
- `send_*` — external communication
- `write_*`, `read_*` — file/stream operations
- `fetch_*` — external data retrieval
- `notify_*`, `publish_*` — event/message dispatch
- `log_*` — logging operations
- `start_*`, `stop_*` — process lifecycle

### Pure Functions (descriptive names required)

Functions without side effects MUST NOT use imperative verbs. Use descriptive names that indicate the transformation:

**Naming patterns**:
- `*_for` — compute/derive a value: `price_for/1`, `discount_for/2`
- `*_from` — extract/transform from input: `name_from/1`, `config_from/1`
- `to_*` — type/format conversion: `to_map/1`, `to_string/1`
- `valid?`, `*?` — boolean checks: `valid?/1`, `expired?/1`
- `format_*` — formatting: `format_date/1`, `format_currency/2`
- Noun/adjective forms — describe the result: `total/1`, `filtered/2`, `sorted/1`

**Forbidden for pure functions**:
- `get_*` (implies retrieval from external source)
- `fetch_*` (implies network/IO)
- `load_*` (implies reading from storage)
- `find_*` (implies searching external data)

### Edge Cases

- `build_*` — acceptable for pure construction (e.g., `build_changeset/2`)
- `calculate_*` — acceptable for pure computation
- `parse_*` — acceptable for pure transformation of input data
- `extract_*` — acceptable for pure data extraction

## Refactoring Process

### 1. Classify Functions

For each function in the file:
- Determine if it has side effects (IO, DB, state mutation, process messages)
- Check if its name matches the correct convention
- Flag violations

### 2. Rename Violations

For each misnamed function:
- Choose a name following the conventions above
- Update all callers across the codebase
- Update any documentation or typespecs

### 3. Validate

- All tests pass after renaming
- No compilation errors or warnings
- All callers updated correctly
- No functionality changed

## Common Violations

| Current Name | Problem | Suggested Name |
|-------------|---------|----------------|
| `get_total(items)` | Pure function with `get_` prefix | `total(items)` or `total_for(items)` |
| `fetch_name(user)` | Pure field access with `fetch_` prefix | `name_from(user)` |
| `find_matching(list, pred)` | Pure filter with `find_` prefix | `matching(list, pred)` |
| `load_config(map)` | Pure transformation with `load_` prefix | `config_from(map)` |
