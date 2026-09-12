---
name: athena:analyze-code
description: Generate comprehensive Elixir architectural reports analyzing module dependencies, control flow, and structural patterns. Use when analyzing architecture, mapping dependencies, or understanding how a code area is structured.
argument-hint: <code-area-path> [--depth shallow|moderate|deep] [--focus data_flow,otp,phoenix,genserver,database,integrations]
---

# athena:analyze-code — Elixir Architecture Analysis

Generate a comprehensive architectural report for the specified code area.

**Input:** `$ARGUMENTS`

Parse the arguments for:
- **code_area_path** (required): directory path or module namespace to analyze (e.g. `lib/my_app/user_management` or `MyApp.UserManagement`)
- **--depth** (default: `moderate`): `shallow` (direct deps only), `moderate` (direct + first-level transitive), or `deep` (complete dependency tree within service boundaries)
- **--focus** (optional, comma-separated): `data_flow`, `otp`, `phoenix`, `genserver`, `database`, `integrations`

If the path doesn't exist or contains no `.ex`/`.exs` files, HALT and suggest valid paths.

---

## Phase 0: Ground in the domain model (if one exists)

Before cataloging code, load the project's *intended* domain model so the
analysis has something to measure the code against. Invoke
**`athena:domain-grounding`** — it reads the project's athena:system-spec model
(`ai-artifacts/domain/<app>/*.spec.json`, when present): the intended entities,
relationships, constraints, the access-control model, and the **bucket** each
module was specced into.

Use it two ways:

- **Bucket classification (Phase 1 Module Classification):** prefer the bucket
  the model assigns a module; infer a bucket only where the model is silent.
- **Drift detection:** where the code's actual structure, dependencies, or
  authorization enforcement diverges from the model, that gap is a finding —
  record it with an ID, severity, and confidence like any other.

If no model exists, note its absence in the report header and analyze from the
code alone.

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

Classify every module by its **architectural bucket** — the 5-bucket
architecture (see your architecture doctrine). Assign each module exactly one
bucket; this is the categorization the rest of the report is built on:

- **Framework** — controllers, routers, middleware, LiveViews: the entry-point
  layer receiving external requests.
- **UI Components** — views, templates, presentation components.
- **Side Effects** — adapters/repositories: databases, external APIs, the file
  system, message queues, other OTP processes.
- **Domain** — pure, side-effect-free business logic.
- **Managers** — orchestration between Side Effects and Domain to fulfil a use
  case.

Where a module's bucket is ambiguous or it spans two buckets, record it with
lowered confidence and say why — a module that straddles buckets is itself a
finding.

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

### Context Analysis (if the app uses contexts)

Contexts are a general Elixir boundary pattern, not Phoenix-specific — analyze
them wherever the app defines business-logic boundary modules.

- Map context boundaries and their public APIs
- Analyze caller-to-context dependency patterns (controllers, LiveViews, other
  contexts, background jobs)
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

### Context Patterns (if the app uses contexts)

- **Context design**: boundary definitions, encapsulation quality, API consistency
- **Cross-context communication**: inter-context patterns and violations

### Phoenix Patterns (if Phoenix detected)

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

If no other output location is specified, write the report to
`ai-artifacts/architecture-report-[code_area_name]-[YYYY-MM-DD-HHMMSS].md`. If
another location is specified, write the report to that location.

Sanitize the code area name for use in the filename (replace `/` and invalid characters with `-`).

### Format rules (apply to every section)

**Prose explains; structure answers.** Lead every section with something
scannable — a table, a rated list, a diagram — and reserve prose for rationale.
A fact that could be a table cell is a table cell.

- **Findings have IDs and a fixed shape.** ID by section prefix and sequence
  (`DEP-01`, `OTP-02`, `FLOW-03`, `AP-04`). Every finding, wherever it appears,
  is the same four lines: **What** / **Where** (`Module` + `file:line`) / **Why
  it matters** / **Action**. The full detail lives once, in the §5 register;
  §1–4 reference IDs rather than restating.
- **Severity and confidence on every finding.** Severity: `CRIT` / `HIGH` /
  `MED` / `LOW` / `INFO`. Confidence: `high` / `med` / `low` — static analysis
  guesses; say when it is guessing.
- **Ratings name their driver.** A 🟢 / 🟡 / 🔴 cell must cite the finding ID
  (or "—") that earned it.
- **Numbers carry a signal.** Any metrics table has a `Signal` column that
  turns the number into a judgment (e.g. "max fan-out >8 → god-module
  candidate") or "—".
- **Prose is labelled and bounded.** Free text appears only under a bold label
  — `**Why:**`, `**Rationale:**`, `**Deviation:**`, `**Consequence:**` — and is
  at most 3 lines per label. No unlabelled paragraphs inside §2–5.
- **Long material folds.** Full catalogs, matrices, message tables and code
  examples go in `<details><summary>…</summary>` blocks. Code examples are
  never inline in a finding; they fold beneath it.
- **Diagrams are indexed.** Every Mermaid/ASCII diagram is preceded by a table
  row that names it, so the reader can choose to open it.

### Report Structure

#### Header

A two-column table, not a list:

```markdown
| | |
|---|---|
| **Area** | `lib/my_app/accounts` (`MyApp.Accounts.*`) |
| **Depth / Focus** | moderate / database, phoenix |
| **Modules** | 23 (Framework 3 · UI 1 · Side Effects 5 · Domain 8 · Managers 6) |
| **Findings** | 2 CRIT · 5 HIGH · 9 MED · 6 LOW |
| **Analyzed** | YYYY-MM-DD · duration |
```

Follow with a **Reading map** (≤5 lines): which section to read for a 2-minute
overview (§1), for planning a refactor (§5 then §2), for on-call / debugging
(§3 flow index).

#### 1. Executive Summary

Three blocks, no paragraphs.

```markdown
### Verdict
> One sentence: the architecture in a clause, and its single biggest risk by ID.

### Health at a glance
| Dimension | Rating | Driver |
|---|---|---|
| Layering / dependency direction | 🟢 | 0 cycles, no upward deps |
| OTP design | 🟡 | OTP-02 |
| Separation of concerns | 🟢 | — |
| Coupling | 🟡 | DEP-04 |
| Test coverage of critical paths | 🔴 | FLOW-02 path untested |

### Top findings
1. **[CRIT] OTP-02** one-line finding → §3.2
2. **[HIGH] DEP-04** one-line finding → §2.3
(≤5 entries, severity-ordered)
```

#### 2. Dependency Analysis

```markdown
### Metrics
| Metric | Value | Signal |
|---|---|---|
| Modules | n | — |
| Avg / max fan-out | x / y (`Module`) | max >8 → god-module candidate |
| Avg / max fan-in | x / y (`Module`) | high fan-in + pure → healthy hub |
| Cycles | n | any → see Boundary violations |
| Max dependency depth | n | — |

### Layer map
(Mermaid `graph TD`: nodes clustered and colored by bucket, direction-violating
edges drawn red. Split into sub-graphs above ~25 nodes.)

### Hotspots
| Module | Fan-in | Fan-out | Bucket | Why it matters |
|---|---|---|---|---|

### Boundary violations
| ID | From → To | Kind | Rule broken | Sev | Conf |
|---|---|---|---|---|---|
(`Kind` = import / alias / use / direct call. `Rule broken` = the 5-bucket
rule or layer rule, e.g. "Domain → Side Effect".)
```

Transitive/impact analysis (moderate/deep depth): one table, `Module | Direct
dependents | Transitive dependents | Change blast radius (S/M/L)`.

#### 3. Control Flow

Open with a **Flow index**; every flow gets one row, then one subsection.

```markdown
### Flow index
| Flow | Trigger | Path (hops) | Sync/Async | Diagram | Risk |
|---|---|---|---|---|---|
| Session start | user action | A → B → C (3) | call | §3.1 | — |
| Crash recovery | Port EXIT | B ⇢ A (trap) → B' (2) | info | §3.2 | OTP-02 |

### 3.n <Flow name>
(Mermaid `sequenceDiagram` for request/message flows; `graph TD` or ASCII for
the supervision tree, annotated with restart strategy and child type.)
**Why:** ≤3 lines of rationale for the shape.

### Message contracts (OTP)
<details><summary>n messages</summary>
| Message | Direction | Kind | Handler | State touched |
|---|---|---|---|---|
</details>

### Bottlenecks
| ID | Path | Evidence | Sev | Conf |
|---|---|---|---|---|
```

#### 4. Architectural Patterns

A catalog table, then one fixed-shape card per pattern that is inconsistent
or low quality. Uniform, healthy patterns get a table row only.

```markdown
### Pattern catalog
| Pattern | Instances | Consistency | Quality | Notes |
|---|---|---|---|---|
| Observer | 3 | ✅ uniform | 🟢 | — |
| PID-guard stale filtering | 4 | ⚠️ 1 outlier | 🟡 | AP-02 |

### AP-nn · <Pattern> — <one-word verdict>
- **Where:** conforming sites ✅ · deviating sites ❌ (module + line)
- **Intent:** one line
- **Deviation:** ≤3 lines
- **Consequence:** ≤3 lines
<details><summary>Example</summary> (good and/or bad code) </details>

### Bucket classification
| Module | Bucket | Conf | Violations |
|---|---|---|---|
(Bucket = Framework / UI Component / Side Effect / Domain / Manager, per the
5-bucket architecture. `Violations` cites finding IDs or "—".)

### Anti-patterns
| ID | Anti-pattern | Module | Evidence | Sev | Conf |
|---|---|---|---|---|---|
```

#### 5. Findings & Recommendations

The single source of truth for every finding. Earlier sections link here.

```markdown
### Findings register
| ID | Sev | Conf | Finding | Location | Action | Effort |
|---|---|---|---|---|---|---|
| OTP-02 | CRIT | high | … | `Mod` L77 | … | M |
(sorted by severity, then ID; Effort = S / M / L)

### Suggested sequence
1. **ID** — why first (dependency on / unlocks other IDs).
2. …
(≤6 entries; state the ordering rationale, not just the order)

### Guidance going forward
- **Testing:** ≤3 bullets
- **Monitoring:** ≤2 bullets
- **Do not add:** patterns to avoid introducing, each tied to an ID
```

#### Appendices

Each in its own `<details>` block:

- Module catalog — `Module | Bucket | Public fns | OTP behaviour`
- Dependency matrix
- Quantitative metrics dump
- Representative code examples not already folded under a finding

### Diagram Guidelines

- Break large dependency graphs into focused sub-graphs (~25 nodes max each)
- Color-code consistently by bucket: Framework, UI Components, Side Effects, Domain, Managers; draw rule-violating edges red
- Annotate supervision trees with restart strategies and child types
- Focus sequence diagrams on the flows in the Flow index; one diagram per flow
- Every diagram is preceded by the table row that indexes it

---

## Warnings

- **Large codebase** (>100 modules): suggest focusing on specific subsystems
- **Complex dependencies** (cycles or deep nesting): highlight in report with specific refactoring recommendations
- **Parse errors**: document unparseable files and continue with partial analysis
- **Unresolved dependencies**: note limitations about dependency completeness
