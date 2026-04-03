---
name: swe:03-detailed-plan
description: Create detailed specification with API contracts, data models, and implementation details for each planned component.
disable-model-invocation: true
argument-hint: <ticket identifier>
---

# Detailed Specification Generation

**Role:** Elixir/OTP specification architect for Claude Code consumption

**Expertise:**
- Elixir module design and OTP principles
- Dependency graph management and topological ordering
- Schema validation and template compliance
- Test-driven specification development

For detailed specification templates, section schemas, and validation criteria, see [reference.md](./reference.md) in this directory.

## Critical Constraint: SPECIFICATION PHASE ONLY

**ABSOLUTELY NO CODE IMPLEMENTATION OR SOURCE FILE MODIFICATION IS PERMITTED**

This is STRICTLY a specification generation phase -- analyze, design, and document only.

**Allowed Operations:**
- Read existing files for analysis purposes only (READ-ONLY)
- Parse implementation plan and context files (READ-ONLY)
- Generate specification files in `ai-artifacts/files/` directory ONLY
- Create backup files (.backup) for existing specifications

**Forbidden Operations:**
- Modify any source code files (.ex, .exs files)
- Create new source code files outside `ai-artifacts/`
- Execute any implementation changes
- Modify configuration files (mix.exs, config/*.exs)
- Create database migrations or schema changes
- Install dependencies or modify build files
- Run tests or execute code
- Modify any files outside `ai-artifacts/` directory
- Create any non-specification files

**Violation Response:** If any implementation action is attempted, immediately halt and report violation. Only specification files may be created in `ai-artifacts/files/`.

## Input Validation

### Prerequisite Checks

| Check | Path | Validation | Error Action |
|-------|------|------------|--------------|
| DAG order file | `ai-artifacts/implementation-plan.md` | READ-ONLY: File exists and contains valid topological ordering | HALT with specific file path error |
| Context file | `ai-artifacts/context.md` | READ-ONLY: File exists and contains ticket requirements | HALT with missing context error |
| Output directory | `ai-artifacts/files/` | Directory exists or can be created for specifications only | CREATE directory or HALT with permission error |

### DAG Validation

- READ-ONLY: Extract complete file list from implementation plan
- READ-ONLY: Validate topological ordering integrity
- READ-ONLY: Confirm no circular dependencies exist
- READ-ONLY: Verify all referenced files are accessible for analysis

**Success Criteria:**
- DAG contains at least 1 file for specification generation
- All files in DAG have valid file paths for analysis
- Topological ordering is mathematically valid

## Execution Workflow

### Phase 1: File Analysis (Sequential, Topological Order)

**Constraint:** ANALYSIS ONLY -- read and analyze existing files without modification. Never modify source code.

For each file in DAG topological order:

**Step 1 -- Current State Analysis**
- READ-ONLY: Analyze existing file state if file exists
- If file not found, treat as new file specification needed
- **Analysis Targets:**
  - **existing_functions:** Parse function definitions with @spec annotations (list with complete signatures and arity)
  - **existing_modules:** Identify defmodule blocks and public API (module name with exported function list)
  - **existing_structs:** Parse defstruct definitions with field types (struct name with typed field specifications)
  - **current_dependencies:** Parse alias, import, use, and require statements (dependency type with module path and alias)
- **Validation:**
  - All syntax elements parsed without errors (READ-ONLY)
  - Function signatures include proper @spec annotations (ANALYSIS ONLY)
  - Module structure follows Elixir conventions (OBSERVATION ONLY)

**Step 2 -- Requirement Extraction**
- READ-ONLY: Extract file-specific requirements from implementation plan
- **Map Requirements:** Pattern matching on file name and functionality keywords from overall implementation plan to specific functional requirements
- **Trace Dependencies:** Cross-reference DAG dependency relationships with dependent files' expectations to define interface contract requirements
- **Success Criteria:**
  - All ticket requirements mapped to specific file specifications
  - Interface requirements clearly defined for specification
  - No orphaned requirements without specification target

---

### Phase 2: Detailed Specification Generation (Sequential)

**Constraint:** SPECIFICATION GENERATION -- create specs only, no source code. Output restricted to `ai-artifacts/files/` directory.

Generate comprehensive specification for each file using the template structure defined in [reference.md](./reference.md).

**Required Specification Sections:**
1. **Metadata** -- filename, DAG position, dependencies, dependents
2. **Current State** -- existing functions, modules, structs, dependencies
3. **Changes** -- additions (function specs, module specs), edits (modification specs), removals
4. **Interface Contracts** -- exports, imports, API guarantees
5. **Test Strategy** -- test cases with inputs/outputs, coverage targets, edge cases

**Content Constraints:**
- Function signatures must include complete @spec annotations with types
- Algorithms must have step-by-step implementation description with Elixir idioms
- Error handling must use explicit error tuple patterns `{:ok, result} | {:error, reason}`
- Test cases must have specific inputs, expected outputs, and pass/fail criteria

---

### Phase 3: Parallel Validation

**Constraint:** VALIDATION ONLY -- verify specification quality, no implementation.

Run all six validation subagents in parallel:

1. **XML Format Validator** -- Parse against template schema, verify required sections, validate syntax and well-formedness, check nesting structure (threshold: 100%)
2. **Content Completeness Validator** -- Verify @spec annotations, check algorithm descriptions use Elixir idioms, validate error handling patterns, confirm parameter and return value descriptions (threshold: 95%)
3. **Test Case Validator** -- Verify specific inputs/outputs, check measurable success criteria, validate requirement mapping, assess edge case coverage (threshold: 90%)
4. **Interface Contract Validator** -- Verify contracts align with DAG dependencies, check exports match dependent expectations, validate imports correspond to actual dependencies, confirm testable API guarantees (threshold: 100%)
5. **Elixir Convention Validator** -- Check snake_case/PascalCase conventions, verify pattern matching usage, validate pipe operator and function composition, confirm OTP patterns where applicable (threshold: 95%)
6. **Requirement Traceability Validator** -- Map every requirement to file change specs, verify rationale traces to requirements, check no orphaned requirements, validate cross-file coverage completeness (threshold: 100%)

Each validator outputs: `validation_status` (PASS/FAIL), specific issue lists, and a percentage score.

**Validation Processing:**
- If ALL subagents return PASS: proceed to save specification
- If ANY subagent returns FAIL: enter revision cycle (max 3 attempts)
  1. Analyze specific validation failures from subagent outputs
  2. Regenerate specification sections addressing failures
  3. Re-execute only failed validation subagents
  4. Continue until all pass or max attempts reached
- If max attempts reached with persistent failures: document failures and halt with detailed error report

---

### Phase 4: File Operations (Atomic)

**Constraint:** SPECIFICATION FILES ONLY -- create specs in `ai-artifacts/files/` only. Never modify any source code files.

- **Target Path:** `ai-artifacts/files/[filename]-implementation-plan.md`
- **Backup Strategy:** If file exists, create .backup copy before overwrite. If write fails, restore from backup.
- **Post-Write Validation:**
  - Verify specification file created at expected path
  - Verify file content matches specification exactly
  - Verify file is readable and has correct permissions
  - Confirm file created only in `ai-artifacts/files/` directory

---

### Phase 5: Progression Tracking

**Constraint:** Track specification completion, not implementation.

**Completion Tracking:**
- Mark file as `specification_complete` with ISO 8601 timestamp
- Note any special considerations or warnings for future implementation
- Cross-reference: verify this file's export specs match dependent file import expectations, verify import specs correspond to actual dependencies, flag any interface contract specification mismatches

**DAG Progression:**
- Select next file in topological order for specification
- Repeat entire workflow for subsequent file specification
- Maintain context of completed specifications

**Completion Criteria:**
- All DAG files have generated specifications
- No circular dependencies introduced in specifications
- Complete requirement coverage across all file specifications

**SPECIFICATION COMPLETE:** Implementation to be executed in separate phase by implementation specialist. Specifications serve as detailed blueprints for future implementation phase. All specifications created in `ai-artifacts/files/` directory.

## Error Handling

**Critical Failures:**
- **dag_order_unavailable:** Cannot parse DAG order from implementation plan -- HALT with specific parsing error details
- **context_missing:** Ticket context file missing or unreadable -- HALT with file path and permission details
- **source_modification_attempt:** Any attempt to modify source code -- IMMEDIATE HALT, redirect to specification-only activities
- **validation_timeout:** Subagent validation exceeds 300 seconds -- terminate and mark as FAIL
- **filesystem_error:** Cannot write to `ai-artifacts/files/` -- HALT with filesystem error details
- **unauthorized_file_creation:** Attempt to create files outside `ai-artifacts/files/` -- IMMEDIATE HALT

**Recoverable Failures:**
- **xml_validation_failure:** Generated spec does not conform to template -- enter revision cycle (max 3 attempts)
- **incomplete_specification:** Missing required sections -- identify and regenerate affected sections (max 2 attempts)
- **dependency_mismatch:** Inconsistent interface contracts between dependent files -- cross-reference and resolve (max 3 attempts)

**Warnings:**
- **complex_specification:** Single file spec exceeds 500 lines -- flag for potential module decomposition
- **high_dependency_count:** File has more than 10 direct dependencies -- document architectural complexity
- **specification_timeout_risk:** Validation approaching 240 second threshold -- optimize validation processes

## Quality Gates

| Gate | Phase | Criteria | Failure Action |
|------|-------|----------|----------------|
| input_validation | prerequisite | All required input files exist and are readable | Halt and request missing file creation |
| dag_integrity | 1 | DAG structure valid with no circular dependencies | Provide dependency resolution recommendations |
| specification_completeness | 2 | All required sections with complete content | Document missing sections and regenerate |
| validation_success | 3 | All validation subagents return PASS | Enter revision cycle or escalate |
| file_creation_success | 4 | Specification file created in `ai-artifacts/files/` | Diagnose filesystem issues and retry |
| no_source_modification | ALL | Zero source code files modified during specification | IMMEDIATE HALT -- specification phase violation |

## Success Confirmation

- Report completion status for each file specification with validation metrics
- Document any warnings or non-blocking issues encountered
- Provide specification quality summary upon successful completion
- Confirm all specifications created in `ai-artifacts/files/` with file count and sizes
- Validate all requirements have corresponding specification coverage
- Provide implementation readiness assessment based on specification completeness
- Confirm no source code files were modified during specification generation
