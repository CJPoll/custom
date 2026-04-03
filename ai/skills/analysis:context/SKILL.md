---
name: analysis:context
description: Generate comprehensive Elixir architectural reports analyzing module dependencies, control flow, and structural patterns. Use when analyzing architecture, mapping dependencies, or understanding how a code area is structured.
argument-hint: <code-area-path> [--depth shallow|moderate|deep] [--focus data_flow,otp,phoenix,genserver,database,integrations]
---

# Elixir Architecture Analysis

Generate a comprehensive architectural report for the specified code area.

**Input:** `$ARGUMENTS`

Parse the arguments for:
- **code_area_path** (required): directory path or module namespace to analyze (e.g. `lib/my_app/user_management` or `MyApp.UserManagement`)
- **--depth** (default: `moderate`): `shallow` (direct deps only), `moderate` (direct + first-level transitive), or `deep` (complete dependency tree within service boundaries)
- **--focus** (optional, comma-separated): `data_flow`, `otp`, `phoenix`, `genserver`, `database`, `integrations`

If the path doesn't exist or contains no `.ex`/`.exs` files, HALT and suggest valid paths.

---

## Phase 1: Code Discovery

Discover and catalog all Elixir modules within the specified code area.

### File Discovery

- Recursively scan for `*.ex` and `*.exs` files
- Exclude `deps/`, `_build/`, `.git/`, and `test/` unless explicitly requested

### Module Cataloging

For each module found:
1. Extract module name, namespace, and nesting hierarchy from `defmodule`
2. Identify OTP behaviors (`GenServer`, `Agent`, `Task`, `Supervisor`, etc.)
3. List public functions with arities and `@doc` annotations
4. Extract `@moduledoc`, `@behaviour`, and other significant attributes

### Module Classification

Classify each module into one of:
- **OTP Processes**: GenServers, Agents, Tasks, Supervisors
- **Phoenix Contexts**: Business logic boundary modules
- **Schemas**: Ecto schemas and data structures
- **Controllers**: Phoenix controllers and LiveViews
- **Utilities**: Helper modules and shared functions
- **Interfaces**: Protocol implementations and API modules

### Dependency Extraction

Extract dependencies from:
- `alias` statements (including `as:` clauses)
- `import` statements (including `only:` filters)
- `use` statements (behavior injection)
- `require` statements (macro usage)
- Direct `Module.function(args)` calls
- Aliased module calls resolved through alias mappings
- Pipe chain (`|>`) data flow
- Pattern matching dependencies

---

## Phase 2: Dependency Analysis

Build the dependency graph and analyze structural relationships. Run these analyses in parallel where possible.

### Dependency Graph

- Build a directed graph of module dependencies
- Weight edges by dependency strength: `import` < `alias` < `use` < direct calls
- Detect circular dependencies and problematic cycles
- Calculate metrics: fan-in, fan-out, depth per module
- Identify architectural layers and validate dependency direction
- Flag critical modules (highest dependency impact)

### OTP Structure Analysis

- Map supervision trees and child process relationships
- Analyze GenServer state dependencies and message patterns (`call`, `cast`, `info`)
- Identify process communication channels
- Detect shared state patterns and potential bottlenecks
- Validate OTP design principle compliance

### Phoenix Context Analysis (if Phoenix detected)

- Map context boundaries and their public APIs
- Analyze controller-to-context dependency patterns
- Validate context encapsulation and boundary integrity
- Identify cross-context dependencies and boundary violations
- Assess schema organization and Ecto relationship patterns

### Transitive Dependencies (moderate/deep depth)

- Traverse the graph to identify indirect dependencies (respect depth setting)
- Detect and break cycles for analysis
- Assess change impact: which modules are affected by changes to each module
- Measure coupling strength (tight vs loose)
- Identify architectural debt in dependency patterns

---

## Phase 3: Control Flow Analysis

Map control flow patterns and data processing paths.

### Phoenix Request Flows (if Phoenix detected)

- Trace request paths from controller actions / LiveView handlers through contexts
- Map data transformations through pipe chains and function compositions
- Analyze response rendering and serialization paths
- Map Plug pipelines, authentication flow, and authorization enforcement points

### OTP Message Flows

- Map synchronous call chains between GenServers
- Trace asynchronous cast/info message passing and event handling
- Identify PubSub communication patterns
- Analyze process registry and lookup patterns
- Track state mutations through GenServer callbacks
- Identify shared state access patterns and coordination mechanisms
- Map state persistence and recovery mechanisms

### Data Processing Flows (if `data_flow` focus)

- Map data transformation pipelines and processing stages
- Trace input validation and sanitization paths
- Analyze error handling and propagation patterns

### Database Interactions (if `database` focus)

- Analyze Ecto query construction and execution patterns
- Identify transaction scopes and atomicity guarantees
- Map preloading strategies and N+1 prevention patterns

### Performance Critical Paths

- Identify most frequently executed code paths
- Detect potential bottlenecks in control flow
- Analyze concurrent access patterns and potential contention

---

## Phase 4: Architectural Pattern Analysis

### OTP Patterns

- **Supervision**: restart strategies, process isolation, fault tolerance design
- **GenServer design**: state organization, callback implementations, timeout/hibernation usage
- **"Let it crash"**: evaluate failure handling philosophy implementation

### Phoenix Patterns (if Phoenix detected)

- **Context design**: boundary definitions, encapsulation quality, API consistency
- **Cross-context communication**: inter-context patterns and violations
- **Controller design**: action organization, Plug pipeline composition, response handling

### Functional Programming Patterns

- Immutable data structure usage
- Pure function usage and side effect isolation
- Function composition and pipeline patterns
- `Enum` and `Stream` usage for data processing

### Anti-Pattern Detection

Flag these issues when found:
- **Tight coupling**: overly coupled modules and functions
- **God modules**: modules with excessive responsibilities
- **Circular dependencies**: problematic dependency cycles
- **Deep nesting**: excessive function call depth
- **Blocking GenServer callbacks**: long-running operations in callbacks
- **Excessive process state**: processes managing too much state
- **Improper supervision**: poorly designed supervision trees

---

## Phase 5: Report Generation

Write the report to `ai-artifacts/architecture-report-[code_area_name]-[YYYY-MM-DD-HHMMSS].md`.

Sanitize the code area name for use in the filename (replace `/` and invalid characters with `-`).

### Report Structure

#### Header Metadata

Include at the top:
- Analysis date, code area analyzed, depth setting, focus areas
- Module count, analysis duration

#### 1. Executive Summary

- Overall architectural approach and patterns
- Module organization and namespace structure
- Key strengths and well-designed aspects
- Critical issues requiring attention
- Complexity and maintainability assessment

#### 2. Dependency Analysis

- Module count with classification breakdown
- Dependency metrics (avg fan-in/fan-out, max depth)
- Circular dependency report with impact assessment
- **Mermaid diagram**: `graph TD` with color-coded nodes by module type, weighted edges, clustered related modules
- Critical path highlighting

#### 3. Control Flow

- Request processing flows (if Phoenix) with **Mermaid sequence diagrams** for key user journeys
- **Mermaid diagram**: supervision tree (`graph TD`) with restart strategies and process types
- Key message passing patterns
- State mutation and coordination patterns
- Performance bottleneck identification

#### 4. Architectural Patterns

- Catalog of detected patterns with code examples
- Pattern implementation quality assessment
- Pattern usage consistency evaluation
- Single responsibility adherence
- Separation of concerns assessment
- OTP principle compliance

#### 5. Issues and Recommendations

- **Critical issues**: architectural debt, security concerns, performance risks
- **Refactoring opportunities**: specific recommendations with rationale
- **Pattern improvements**: suggestions for better implementations
- **Dependency optimization**: structural improvement recommendations
- **Future guidance**: development guidelines, testing strategy, monitoring suggestions

#### Appendices

- Complete module catalog with classifications
- Detailed dependency matrix
- Representative code examples for key patterns
- Quantitative metrics summary

### Diagram Guidelines

- Break large dependency graphs into focused sub-graphs for readability
- Use color-coding consistently: OTP processes, Phoenix contexts, schemas, controllers, utilities
- Annotate supervision trees with restart strategies
- Focus sequence diagrams on critical interaction patterns

---

## Warnings

- **Large codebase** (>100 modules): suggest focusing on specific subsystems
- **Complex dependencies** (cycles or deep nesting): highlight in report with specific refactoring recommendations
- **Parse errors**: document unparseable files and continue with partial analysis
- **Unresolved dependencies**: note limitations about dependency completeness
