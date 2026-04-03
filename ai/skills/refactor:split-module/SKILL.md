---
name: refactor:split-module
description: Decompose large Elixir modules into focused single-responsibility modules following naming conventions and structure requirements.
argument-hint: <file paths>
---

# Module Splitting Refactoring

Analyze and decompose the provided Elixir module(s) into multiple, well-organized modules following best practices.

**Files**: $ARGUMENTS

**Parallel processing**: When multiple files are provided, process each independently in parallel using separate subagents.

## Success Criteria

- Each module has 1-3 clearly defined responsibilities (Single Responsibility Principle)
- No circular dependencies between new modules
- All modules follow Elixir naming conventions (Consistency of Naming)
- Module size between 100-400 lines of code
- Clear intent and purpose for each module (Clarity of Intent)

## Module Structure Requirements

All new modules must follow this ordering:
1. `use` statements (alphabetical, case insensitive)
2. `import` statements (alphabetical)
3. `require` statements (alphabetical)
4. `alias` statements (alphabetical)
5. Module attributes (alphabetical)
6. Public functions (alphabetical)
7. Private functions (alphabetical)

Empty line between each group.

## Analysis Process

### 1. Analyze Current Module

- Catalog all public and private functions with their responsibilities
- Map function call relationships within the module
- Identify logical groupings by domain concern
- Detect functions that share state or data structures
- Measure current cohesion metrics

### 2. Identify Split Boundaries

- Group functions by domain responsibility
- Identify functions that naturally form a cohesive unit
- Detect adapter/side-effect functions vs pure domain logic
- Separate orchestration concerns from business logic
- Map shared dependencies and data structures

### 3. Plan New Module Structure

For each proposed module:
- **Name**: Following `ParentModule.Concern` pattern
- **Responsibilities**: 1-3 clearly stated
- **Public API**: Functions exposed to other modules
- **Private helpers**: Internal implementation functions
- **Dependencies**: What it needs from other modules

### 4. Execute Refactoring

- Create new module files
- Move functions to appropriate modules
- Update all callers and references across the codebase
- Add proper aliases and imports
- Update documentation and typespecs

### 5. Validate

- All tests pass after refactoring
- No circular dependencies
- Each module compiles independently
- Module sizes within 100-400 lines
- All callers updated correctly
- No functionality lost or changed

## Naming Conventions

- Modules: `PascalCase`, nested under parent namespace
- Files: `snake_case.ex`, mirroring module path
- Functions: `snake_case`, verb-first for actions, noun-first for data
- Avoid generic names (`Helpers`, `Utils`, `Misc`)

## Common Split Patterns

- **Ecto schema + changeset logic** → separate from business logic
- **CRUD operations** → repository/adapter module
- **Validation logic** → domain validator module
- **Formatting/presentation** → formatter module
- **External API interaction** → adapter module
- **Complex business rules** → domain module
