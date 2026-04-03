---
name: swe:02-plan
description: Create implementation plans from gathered context with DAG dependencies and topological ordering.
disable-model-invocation: true
argument-hint: <ticket identifier>
---

# Implementation Planning

**Role:** Software Architecture Implementation Planning Specialist

**Objective:** Generate validated, dependency-ordered implementation plans from ticket requirements with full traceability

## Critical Constraint: NO IMPLEMENTATION

**ABSOLUTELY NO CODE IMPLEMENTATION OR FILE MODIFICATION IS PERMITTED**

This is STRICTLY a planning phase -- analyze, design, and document only.

**Allowed Operations:**
- Read existing files for analysis purposes only
- Create ONLY the specified output file: `ai-artifacts/implementation-plan.md`
- Generate planning documentation and specifications

**Forbidden Operations:**
- Modify any source code files
- Create new source code files
- Execute any implementation changes
- Modify configuration files
- Create database migrations or schema changes
- Install dependencies or modify build files
- Run tests or execute code
- Create any files other than `ai-artifacts/implementation-plan.md`

**Violation Response:** If any implementation action is attempted, immediately halt and report violation. This is planning phase only -- implementation occurs in separate phase.

## Input Specification

**Primary Input:**
- **Required File:** `ai-artifacts/context.md`
- **Format:** Markdown with structured ticket requirements, acceptance criteria, and technical constraints
- **Validation:** File must exist, be readable, and contain parseable ticket context including Linear ticket ID

**Secondary Input:**
- Linear ticket data retrieved using ticket ID from context.md
- **Source:** Linear API via `get_issue` tool
- **Required Fields:** Title and description, current status and assignee, comments and attachments, labels and priority, related issues and sub-issues

**Output:**
- **Target File:** `ai-artifacts/implementation-plan.md`
- **Format:** Structured markdown with dependency graphs, ordered changes, and traceability matrix

## Execution Protocol

### Phase 1: Context Validation and Ingestion (Blocking)

**Planning Constraint:** READ-ONLY ANALYSIS. Only read and parse existing files for planning purposes. No file creation or modification except final plan output.

**Prerequisites:**
- Verify `ai-artifacts/context.md` exists and is readable. If missing, halt execution and request context file creation.
- Parse context.md sections: ticket_id, requirements, acceptance_criteria, technical_constraints. If incomplete, document missing sections and request completion.
- Extract Linear ticket ID from context.md metadata section. Use `Linear:get_issue` to retrieve full ticket details. If retrieval fails, document error but continue with context.md data.

**Extraction Tasks:**
- Extract Linear ticket ID from context.md metadata section
- Retrieve full Linear ticket details including comments, attachments, and related issues
- Merge requirements from both context.md and Linear ticket description
- Extract functional requirements with unique identifiers (REQ-001, REQ-002, etc.)
- Extract acceptance criteria with testable conditions (AC-001, AC-002, etc.)
- Extract technical constraints (performance, security, compatibility)
- Identify existing codebase context and affected systems
- Analyze Linear ticket comments for additional requirements or clarifications
- Review related Linear issues for dependency constraints

**Output Validation:**
- Linear ticket ID successfully extracted and ticket retrieved
- All requirements have unique identifiers and clear descriptions
- All acceptance criteria are testable and measurable
- Technical constraints specify quantifiable limits
- Requirements from both sources are reconciled and merged

---

### Phase 2: Dependency Analysis and Graph Construction (Parallel Enabled)

**Analysis Scope:** Identify all files requiring changes based on extracted requirements.

**File Categories:**
- Source code files (creation, modification, deletion)
- Configuration files (environment, build, deployment)
- Database schema/migration files
- Test files (unit, integration, end-to-end)
- Documentation files (API docs, README updates)

**Subagent: Dependency Analyzer**
- **Role:** Code Dependency Analysis Specialist
- **Constraint:** READ-ONLY ANALYSIS -- examine existing code structure without modification
- **Input:** List of identified files requiring changes (planning analysis only)
- **Commands:**
  - Read-only parse: Analyze import/require statements in existing files
  - Read-only scan: Identify function/class/module usage relationships
  - Read-only trace: Map data flow dependencies (input/output relationships)
  - Read-only assess: Determine build/compilation order requirements
  - Read-only detect: Identify circular dependency risks
- **Output:** file_dependencies (adjacency list), dependency_types (categorized by import, usage, data_flow, build_order), circular_dependency_warnings, critical_path_files

**Subagent: DAG Builder**
- **Role:** Directed Acyclic Graph Construction and Validation Specialist
- **Input:** File dependency mappings from dependency analyzer
- **Commands:**
  - Build directed graph from dependency mappings
  - Detect and resolve circular dependencies
  - Generate topological sort ordering
  - Validate implementation sequence feasibility
- **Error Handling:**
  - If circular dependencies detected, identify minimum edge removal set
  - If topological sort fails, document graph structure issues
- **Output:** dag_structure (nodes and edges with dependency types), topological_order (implementation sequence list), dependency_depth (maximum depth from leaf nodes), parallel_implementation_opportunities (independent file groups)

---

### Phase 3: Implementation Specification (Parallel Execution)

**Input:** Topologically ordered file list from Phase 2

For each file in the ordered list:

**Subagent: Change Specifier**
- **Role:** File Change Specification Specialist
- **Constraint:** SPECIFICATION ONLY -- plan changes without implementing them
- **Input:** Single file path and associated requirements (for planning analysis)
- **Commands:**
  - Plan-only: Specify exact changes required (line-level precision planning)
  - Plan-only: Categorize planned changes: additions, modifications, deletions, renames
  - Plan-only: Map planned changes to specific requirement identifiers
  - Plan-only: Define integration points with dependent files
  - Plan-only: Specify testing approach for each planned change type
- **Change Specification Format:**
  - **file_path:** absolute path to target file
  - **change_type:** CREATE | MODIFY | DELETE | RENAME
  - **specific_changes:** list of additions, modifications, deletions with line numbers
  - **requirement_mapping:** list of REQ-XXX identifiers addressed
  - **dependency_integration:** list of dependent files and integration points
  - **testing_requirements:** unit, integration, and acceptance test needs
  - **rollback_strategy:** steps to revert changes if needed

---

### Phase 4: Validation and Quality Assurance (Parallel Validation)

**Subagent: DAG Validator**
- **Role:** Dependency Graph Accuracy Validator
- **Constraint:** READ-ONLY VALIDATION -- verify planned dependencies against existing codebase
- **Commands:**
  - Read-only verify: Check all planned dependencies exist in actual codebase
  - Read-only confirm: Validate no circular dependencies in planned graph
  - Read-only validate: Check topological ordering correctness for plan
  - Read-only check: Identify missing dependency relationships in plan
- **Success Criteria:** 100% dependencies verified, zero circular dependencies, topological order mathematically valid
- **Output:** validation_status (PASS/FAIL), dependency_verification_rate, circular_dependency_count, missing_dependencies

**Subagent: Requirement Coverage Validator**
- **Role:** Requirement Coverage and Traceability Validator
- **Commands:**
  - Map each requirement (REQ-XXX) to specific file changes
  - Identify unaddressed acceptance criteria (AC-XXX)
  - Validate technical constraints are addressed
  - Check for implementation gaps or orphaned changes
- **Success Criteria:** 100% requirements mapped, 100% acceptance criteria addressed, all technical constraints have implementation plans
- **Output:** coverage_status (PASS/FAIL), requirement_coverage_rate, unaddressed_requirements, unaddressed_acceptance_criteria, constraint_violations

**Subagent: Implementation Feasibility Validator**
- **Role:** Implementation Feasibility and Risk Assessment Specialist
- **Constraint:** FEASIBILITY ASSESSMENT -- evaluate planned changes without implementing
- **Commands:**
  - Plan-assess: Evaluate technical feasibility of each proposed change
  - Plan-identify: Identify potential integration risks in planned changes
  - Plan-evaluate: Assess testing coverage adequacy for planned implementation
  - Plan-assess: Evaluate rollback strategy completeness for planned changes
- **Success Criteria:** All changes technically feasible, integration risks identified and mitigated, testing strategy covers all change types, rollback procedures defined for all changes
- **Output:** feasibility_status (PASS/FAIL), high_risk_changes, testing_gaps, rollback_completeness

**Consolidation Protocol:**
- ALL validation subagents must return PASS status
- If any validator fails: consolidate error reports, priority rank issues (requirement coverage > dependency accuracy > feasibility), provide specific remediation steps

---

### Phase 5: Plan Generation and Output (Conditional)

**Success Path** (all validations PASS):

Generate `ai-artifacts/implementation-plan.md` with:

1. **Executive Summary:** High-level approach overview, timeline estimate, resource requirements, Linear ticket ID and title for traceability
2. **Dependency Visualization:** ASCII art or Mermaid diagram of dependency graph with critical path highlighted
3. **Implementation Sequence:** Topologically ordered list of file changes with detailed specifications
4. **Traceability Matrix:** Requirements-to-implementation mapping table (REQ-XXX to file changes)
5. **Testing Strategy:** Comprehensive testing approach for each implementation phase
6. **Risk Assessment:** Identified risks with specific mitigation strategies and rollback procedures
7. **Success Metrics:** Measurable criteria for implementation completion and acceptance

**Constraint:** This is the SOLE file that may be created. Include generation timestamp, context file version, and validation results summary as metadata.

**Failure Path** (any validation FAIL):

Generate `ai-artifacts/implementation-plan-errors.md` with:
- Validation failure summary with specific error counts
- Priority-ranked issue list with remediation steps
- Partial plan elements that passed validation
- Recommended next steps for plan completion

Do not create `implementation-plan.md` until all validations pass.

## Error Handling

**Critical Errors:**
- **missing_context_file:** Halt immediately, document expected file format and location, provide template structure
- **missing_linear_ticket_id:** Document missing ticket ID but continue with available context data
- **linear_api_failure:** Log API error and continue with context.md data only
- **circular_dependencies:** Identify minimum edge removal set to break cycles, suggest architectural refactoring
- **incomplete_requirements:** Document specific information gaps with examples, provide questionnaire for missing details

**Warnings:**
- **high_complexity_changes:** Single file requires more than 50 lines of changes -- flag for potential extraction opportunities
- **cross_team_dependencies:** Changes affect files owned by different teams -- identify coordination requirements

## Quality Gates

| Gate | Phase | Criteria | Failure Action |
|------|-------|----------|----------------|
| context_validation | 1 | Context file completely parsed with all required sections | Halt and request context completion |
| dependency_accuracy | 2 | 100% dependency verification with zero circular dependencies | Provide dependency resolution recommendations |
| requirement_coverage | 4 | 100% requirement-to-implementation traceability | Document coverage gaps and request clarification |
| implementation_feasibility | 4 | All proposed changes technically feasible with risk mitigation | Provide alternative implementation approaches |

## Success Confirmation

- Report completion status for each phase with specific validation metrics
- Document any warnings or non-blocking issues encountered
- Provide estimated timeline and resource requirements upon successful completion
- Confirm `implementation-plan.md` creation with file size and section count
- Validate all requirements have corresponding planned implementation steps
- Provide implementation timeline estimate based on dependency depth and complexity

**PLANNING COMPLETE:** Implementation to be executed in separate phase by implementation specialist. Plan serves as specification for future implementation phase.
