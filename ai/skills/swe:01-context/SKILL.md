---
name: swe:01-context
description: Gather and analyze context from Linear tickets, codebase exploration, and ADR analysis for implementation planning.
disable-model-invocation: true
argument-hint: <ticket identifier>
---

# Context Gathering and Analysis

**Role:** Linear workflow automation specialist with software engineering focus

**Specializations:**
- Linear API integration and ticket management
- Code analysis and documentation generation
- Architecture Decision Record (ADR) analysis and compliance
- Automated workflow execution with validation gates
- File system operations and artifact management

## Task

**Primary Objective:** Complete automated ticket processing workflow with code analysis, ADR compliance assessment, and context generation

**Input:** Linear ticket ID provided in `$ARGUMENTS`

**Success Criteria:**
- Ticket successfully updated in Linear system
- Code analysis completed following specified format
- Relevant ADRs identified with compliance requirements
- All validation subagents return PASS status
- Context artifact saved to specified location with ADR guidance

## Execution Phases

### Phase 1: Ticket Setup (Sequential)

**Description:** Linear ticket initialization and requirement extraction

**Step 1 -- Retrieve ticket details**
- **Tool:** `Linear:get_issue` with ID `$ARGUMENTS`
- **Validation:**
  - Ticket exists and is accessible
  - User has permission to modify ticket
  - Ticket contains actionable requirements
- **Error Handling:**
  - If ticket not found, halt execution with specific error
  - If permission denied, halt execution with access error

**Step 2 -- Update ticket status**
- **Tool:** `Linear:update_issue`
- Set status to "In Progress" and assign to current user
- **Validation:**
  - Status successfully updated to "In Progress"
  - Assignment completed to current user

**Step 3 -- Extract ticket requirements**
- **Extraction Targets:**
  - **requirements:** Parse description for functional requirements
  - **acceptance_criteria:** Identify testable success conditions
  - **technical_specs:** Extract technical constraints, APIs, frameworks mentioned
  - **file_paths:** Identify any specific file or directory references
  - **keywords:** Extract domain-specific terms for code matching
  - **architecture_keywords:** Extract architectural patterns, design decisions, and technical approaches for ADR matching
- **Validation:**
  - All extraction targets populated with relevant data
  - Requirements are actionable and specific
  - Technical specifications are clear and complete
  - Architecture keywords identified for ADR analysis

**Phase Completion Criteria:**
- Ticket status updated successfully
- All requirements extracted and structured
- File paths and keywords identified for code analysis
- Architecture keywords extracted for ADR matching

---

### Phase 2: ADR Analysis (Sequential)

**Description:** Architecture Decision Record identification and compliance assessment

**Step 4 -- Scan and analyze ADRs**
- **Directory:** `adrs/`
- **File Patterns:** `*.md`, `*.txt`, `ADR-*.md`, `[0-9]*.md`
- **Extract Fields:**
  - **title:** ADR title or decision summary
  - **status:** Accepted, Proposed, Deprecated, Superseded
  - **context:** Problem or situation addressed
  - **decision:** Architectural decision made
  - **consequences:** Implications and constraints
  - **tags:** Technical domains, patterns, components affected
- **Validation:**
  - ADR directory exists and is accessible
  - All discoverable ADR files processed
  - Key fields extracted from each ADR

**Step 5 -- Match ticket requirements against ADR content**
- **Matching Strategy:**
  - **Keyword overlap:** Semantic similarity analysis between ticket keywords and ADR text (minimum 70% relevance score)
  - **Technical domain:** Domain classification and overlap analysis across UI/UX, API design, data storage, security, performance, integration
  - **Pattern matching:** Identify architectural patterns mentioned in both ticket and ADRs (pagination, authentication, caching, event-driven, microservices, REST, GraphQL)
- **Relevance Scoring:** 0-100 scale, threshold at 60, high relevance at 80+

**Step 6 -- Generate ADR compliance requirements**
- For each relevant ADR, extract constraints:
  - Implementation patterns that must be followed
  - Technologies or approaches that must be used
  - Technologies or approaches that must be avoided
  - Testing requirements derived from ADR consequences
  - Performance or security constraints
- Generate test requirements:
  - Integration tests verifying ADR compliance
  - Unit tests validating architectural constraints
  - Performance tests ensuring ADR-defined thresholds
  - Security tests validating ADR security decisions

**Phase Completion Criteria:**
- All ADRs discovered and parsed successfully
- Relevant ADRs identified with relevance scoring
- Compliance requirements extracted for each relevant ADR
- Test requirements generated for ADR compliance validation

---

### Phase 3: Code Analysis (Sequential)

**Description:** Relevant code identification and analysis using specified format

**Step 7 -- Identify relevant code files**
- **Identification Strategy:**
  - **Explicit file paths:** File paths mentioned directly in ticket description
  - **Keyword matching:** Keywords from ticket title/description matching file/function names
  - **Recent modifications:** Recently modified files in related directories (check git history)
  - **ADR-related files:** Files mentioned in relevant ADRs or implementing ADR decisions
- **Validation:**
  - At least one relevant file identified
  - File identification rationale documented
  - Files are accessible and readable
  - ADR-related files included in analysis scope

**Step 8 -- Analyze identified code**
- Follow format from `@~/.claude/skills/format:code-explain/SKILL.md`
- **Adherence Level:** strict
- **Analysis Scope:**
  - Function signatures and purpose
  - Data structures and types
  - Dependencies and imports
  - Error handling patterns
  - Performance considerations
  - Integration points
  - ADR compliance assessment for analyzed code

**Step 9 -- Generate code summary**
- Follow exact structure from code-explain format
- Include all mandatory sections
- Maintain consistent formatting and style
- Provide actionable technical insights
- Include ADR compliance assessment for existing code
- Highlight any existing ADR violations or compliance gaps

**Phase Completion Criteria:**
- All relevant code files identified and analyzed
- Code summary generated following reference format
- Analysis provides actionable insights for ticket completion
- ADR compliance assessment completed for existing code

---

### Phase 4: Validation and Output (Sequential)

**Description:** Parallel validation and context artifact generation

**Step 10 -- Execute validation subagents in parallel**

**Subagent: Format Validator**
- **Role:** Code Explanation Format Compliance Specialist
- **Input:** Generated code summary and reference format from `@~/.claude/skills/format:code-explain/SKILL.md`
- **Commands:**
  - Load reference format document
  - Compare generated summary against required sections
  - Validate formatting consistency and style adherence
  - Check completeness of all mandatory elements
- **Success Criteria:**
  - All required sections present in correct order
  - Formatting matches reference style exactly
  - No missing mandatory elements
  - Content structure follows reference template
- **Output:** format_validation_status (PASS/FAIL), missing_sections, formatting_violations, completeness_score

**Subagent: Technical Accuracy Validator**
- **Role:** Technical Content Accuracy Specialist
- **Input:** Generated code summary and original source code files
- **Commands:**
  - Cross-reference summary content with actual code
  - Verify function signatures and descriptions are accurate
  - Validate dependency and import listings
  - Check error handling pattern descriptions
- **Success Criteria:**
  - All function signatures accurately represented
  - Dependencies and imports correctly listed
  - Code behavior descriptions match implementation
  - No technical inaccuracies or misrepresentations
- **Output:** accuracy_validation_status (PASS/FAIL), signature_mismatches, dependency_errors, behavior_discrepancies

**Subagent: Completeness Validator**
- **Role:** Analysis Completeness Assessment Specialist
- **Input:** Generated code summary and ticket requirements
- **Commands:**
  - Compare analysis scope against ticket requirements
  - Verify all relevant code areas are covered
  - Check that analysis addresses ticket concerns
  - Validate actionability of generated insights
- **Success Criteria:**
  - Analysis covers all code areas relevant to ticket
  - Ticket requirements adequately addressed
  - Insights are actionable for ticket completion
  - No significant gaps in analysis coverage
- **Output:** completeness_validation_status (PASS/FAIL), uncovered_areas, unaddressed_requirements, actionability_score

**Subagent: ADR Compliance Validator**
- **Role:** Architecture Decision Record Compliance Specialist
- **Input:** Generated code summary, relevant ADRs, and extracted compliance requirements
- **Commands:**
  - Cross-reference code analysis against ADR implementation constraints
  - Verify no prohibited patterns are suggested or present
  - Validate mandatory patterns are identified and addressed
  - Check that architectural constraints are properly considered
  - Assess completeness of ADR compliance testing strategy
- **Success Criteria:**
  - All relevant ADRs properly identified and analyzed
  - Implementation approach aligns with ADR decisions
  - Prohibited patterns explicitly avoided or flagged
  - Mandatory compliance tests included in recommendations
  - Security and performance ADR constraints addressed
- **Output:** adr_compliance_status (PASS/FAIL), missing_adr_considerations, compliance_violations, missing_compliance_tests, adr_alignment_score

**Step 11 -- Process validation results**
- If any validator returns FAIL:
  - Revise analysis based on specific validation failures
  - Re-execute failed validation subagents
  - Continue revision cycle until all validators pass
  - If ADR compliance fails, re-analyze ADR relevance and constraints
- **Success Condition:** All four validation subagents return PASS status

**Step 12 -- Save validated context to ai-artifacts/context.md**
- Create `ai-artifacts/` directory if not exists
- Write to `ai-artifacts/context.md` with these sections:
  - **Metadata:** Linear Ticket ID (`$ARGUMENTS`), generated timestamp
  - **Ticket Details:** Title, description, status (In Progress), assignee
  - **Requirements:** Extracted requirements from ticket
  - **Acceptance Criteria:** Extracted acceptance criteria from ticket
  - **Technical Constraints:** Extracted technical constraints from ticket
  - **Relevant ADRs:** Identified relevant ADRs with relevance scores, compliance requirements and constraints, required compliance testing strategies, implementation guidance derived from ADR decisions
  - **Code Analysis:** Validated code analysis summary following reference format
- **Validation:**
  - File successfully created at specified path
  - Content includes Linear ticket ID and all required sections
  - ADR guidance properly integrated into context
  - File is readable and properly formatted

**Phase Completion Criteria:**
- All validation subagents return PASS status (including ADR compliance)
- Context artifact successfully saved with ADR guidance
- Workflow completion logged with success status

---

## Constraints

**Strict Prohibitions:**
- Do NOT generate any code during this workflow
- Do NOT generate any tests during this workflow
- Do NOT modify any existing code files
- Do NOT modify any existing ADR files

**Execution Requirements:**
- Halt execution immediately if Linear ticket cannot be accessed
- Require explicit PASS validation from all subagents before saving context
- Log each phase completion with detailed status confirmation
- Maintain strict sequence execution -- no parallel phase processing
- Process ADRs before code analysis to inform implementation guidance

**Error Conditions:**
- **ticket_access_failure:** Linear API returns error or ticket not found -- halt execution with specific error message
- **adr_directory_missing:** `adrs/` directory does not exist or is inaccessible -- log warning and continue workflow without ADR analysis
- **validation_failure:** Any validation subagent returns FAIL status -- enter revision cycle until all validations pass
- **file_operation_failure:** Cannot create or write to `ai-artifacts/context.md` -- report file system error and suggest alternative location

## Logging Requirements

**Phase Logging:**
- `PHASE 1 COMPLETE: Ticket setup and requirement extraction successful`
- `PHASE 2 COMPLETE: ADR analysis and compliance requirements generated`
- `PHASE 3 COMPLETE: Code analysis and summary generation successful`
- `PHASE 4 COMPLETE: Validation passed and context artifact saved`

**Step Logging Format:** `STEP {number} STATUS: {action} - {success/failure} - {details}`
- Required details: Execution time, key outputs or errors, validation results where applicable, ADR relevance scores where applicable

## Success Validation

**Overall Success Criteria:**
- Linear ticket successfully updated to "In Progress"
- All relevant code files identified and analyzed
- Relevant ADRs identified with compliance requirements extracted
- Code analysis follows reference format exactly
- All validation subagents return PASS status (including ADR compliance)
- Context artifact saved successfully to `ai-artifacts/context.md` with ADR guidance

**Failure Escalation:** If any phase fails after 3 retry attempts, report failure details and halt execution.

**Execution Directive:** Execute this Linear workflow automation in strict sequence, with mandatory validation gates including ADR compliance assessment, and comprehensive logging, ensuring complete adherence to constraints while delivering validated context artifact with architectural guidance.
