---
name: swe:04-implement
description: Implement features from detailed plan following TDD workflow with test-first development and quality gates.
disable-model-invocation: true
argument-hint: <ticket identifier>
---

# Test-Driven Implementation

**Role:** Test-Driven Development Implementation Specialist

**Objective:** Execute validated implementation plans using strict TDD methodology with comprehensive testing

For TDD patterns, validation templates, and progress reporting formats, see [reference.md](./reference.md) in this directory.

## Implementation Authorization: ACTIVE IMPLEMENTATION PHASE

**FULL IMPLEMENTATION ACCESS:** All source code modification and file creation permitted.

**Authorized Operations:**
- Create and modify source code files per implementation specifications
- Generate comprehensive test suites for all implementations
- Execute tests and validate implementation correctness
- Modify configuration files as specified in implementation plan
- Create database migrations and schema changes per specifications
- Install dependencies and modify build files as planned
- Run full test suites and integration tests
- Create documentation and API updates per specifications
- Implement error handling and logging as specified

**Implementation Constraints:**
- MUST follow TDD methodology: tests first, then implementation
- MUST achieve 100% test pass rate before file progression
- MUST maintain compatibility with existing passing tests
- MUST implement exactly per approved specifications
- MUST validate against original ticket requirements

**Deviation Protocol:**
- If specification ambiguity encountered, document decision and continue
- If implementation impossible as specified, document issue and propose alternative
- If tests reveal specification errors, document and implement corrective measures

## Input Validation

### Prerequisite Checks

| Check | Path/Type | Validation | Error Action |
|-------|-----------|------------|--------------|
| Context file | `ai-artifacts/context.md` | File exists with ticket requirements and acceptance criteria | HALT with missing context error |
| Implementation plan | `ai-artifacts/implementation-plan.md` | File exists with valid DAG topological ordering | HALT with missing plan error |
| Specification directory | `ai-artifacts/files/` | Directory exists with file-specific implementation specifications | HALT with missing specifications error |
| Test framework | environment | Test framework available and configured for target language | Install and configure appropriate test framework |
| Build system | environment | Build system functional and dependencies resolvable | Configure build system and resolve dependency conflicts |

### DAG Extraction

- Extract complete file list from implementation plan with topological ordering
- Validate DAG integrity and dependency relationships
- Confirm all specification files exist for DAG files
- Verify no circular dependencies in implementation order

**Success Criteria:**
- DAG contains at least 1 file for implementation
- All DAG files have corresponding specification files
- Topological ordering is valid and executable
- All file dependencies are satisfiable

### Requirement Validation

- Extract acceptance criteria from `ai-artifacts/context.md` with unique identifiers (AC-001, AC-002, etc.)
- Cross-reference: map acceptance criteria to specific file implementations
- Verify all criteria have implementation coverage

## Implementation Workflow

Iterate through DAG in strict topological order. For each file:

### Phase 1: Preparation (Blocking)

**Step 1 -- Load file specification**
- Source: `ai-artifacts/files/[current_filename]-implementation-plan.md`
- Validate specification exists and is well-formed
- If missing, halt and request specification generation

**Step 2 -- Extract implementation details**
- **Function signatures:** Parse function specifications with @spec annotations and type definitions
- **Algorithm descriptions:** Step-by-step implementation instructions using language idioms
- **Interface contracts:** Export/import specifications and API guarantees
- **Test requirements:** Comprehensive test case specifications with inputs/outputs

**Step 3 -- Verify dependencies**
- Confirm all required dependencies are implemented and available
- Verify all imports correspond to completed implementations
- Check interface contracts match dependency exports
- Identify all integration points this file depends on

**Step 4 -- Map requirements**
- Extract file-specific requirements from implementation specification
- Cross-reference to overall ticket acceptance criteria
- Verify all file requirements trace to ticket requirements
- Plan test coverage: each acceptance criterion must have corresponding test cases
- Identify boundary conditions and error scenarios

**Phase Success Criteria:**
- File specification loaded and parsed successfully
- All dependencies verified and available
- File requirements mapped to ticket acceptance criteria
- Test coverage plan complete for all requirements

---

### Phase 2: Test Development (Blocking)

**Test Categories:**
- **Unit tests:** Individual function/method behavior validation. Cover all public interface functions with parameter variations. Focus on input validation, output correctness, error handling.
- **Integration tests:** Inter-module communication and dependency interaction. Cover all integration points from dependency analysis. Focus on interface contract compliance, data flow validation.
- **Acceptance tests:** Business logic validation per ticket requirements. Cover all acceptance criteria mapped to this file. Focus on end-to-end behavior matching ticket specifications.
- **Edge case tests:** Boundary conditions and error scenarios. Cover all identified edge cases and failure modes. Focus on error handling, boundary values, exceptional conditions.

**For each test case, specify:**
- Descriptive name indicating behavior being validated
- Clear statement of what behavior is being tested
- Test environment configuration and data preparation
- Exact input parameters with types and values
- Precise expected results with success criteria
- Clear error messages for test failures
- Reference to specific acceptance criteria being validated

**Test requirements:**
- Test must be executable with current test framework
- Test must provide clear pass/fail determination
- Test must validate meaningful behavior, not implementation details
- Test must include appropriate assertions and error handling

**Validation:** Run test quality validator subagent. If FAIL, analyze specific failures and regenerate failing test sections (max 3 attempts before escalation).

**Test Pruning -- Remove:**
- Tests that fail validation requirements
- Tests that validate implementation details rather than behavior
- Tests that duplicate existing coverage without adding value

**Phase Success Criteria:**
- Test quality validator returns PASS status
- All public functions have unit test coverage
- All file acceptance criteria have test coverage
- Edge cases and error conditions are tested
- Tests are independent and provide clear diagnostics

---

### Phase 3: Implementation (Iterative, max 10 iterations)

**TDD Cycle:**

1. **Run tests** -- Execute complete test suite for current file. Capture: total tests, passing, failing, failure details, coverage metrics. Success condition: 100% test pass rate.

2. **Analyze failures** (if tests fail) -- Categorize failures:
   - Missing function implementations
   - Incorrect function behavior
   - Type/signature mismatches
   - Error handling deficiencies
   - Integration/dependency issues
   - Prioritize: missing implementations blocking multiple tests > incorrect core behavior > type/signature issues > error handling/edge cases

3. **Implement fixes** (if tests fail) -- Implement only what is necessary to make failing tests pass. Start with simplest implementation satisfying test requirements. Do not add functionality not covered by tests. Match exact function signatures from specification. Follow specification algorithm descriptions. Implement specified error tuple patterns.

4. **Regression check** -- Execute full test suite including previously passing tests. Verify no previously passing tests now fail. Confirm dependencies still function correctly. If regression detected, analyze breaking changes and implement compatibility fixes.

**Termination Conditions:**
- **Success:** 100% test pass rate, no regression, all acceptance criteria tests pass
- **Failure:** Maximum iterations reached without resolution or unresolvable test failures detected -- apply fix process from `@~/.claude/skills/processes:fix/SKILL.md`, then document failures and request specification review

**External Fix Process (conditional):**
- **Trigger:** Unresolvable test failures after maximum TDD iterations
- **Process:** `@~/.claude/skills/processes:fix/SKILL.md`
- **Steps:** Apply fix methodology to problematic test cases, document specification ambiguities, implement corrected tests and code, validate no new regressions
- **Success Criteria:** All failures resolved, implementation remains spec-compliant, no new failures

**Phase Success Criteria:**
- 100% test pass rate for all file tests
- No regression in previously passing tests
- Implementation matches specification requirements
- All acceptance criteria tests pass
- Code coverage meets specified thresholds

---

### Phase 4: Validation and Progression (Blocking)

**Requirement Compliance Check:**
- All file-specific acceptance criteria tests pass
- Map passing tests to original ticket requirements
- Verify no acceptance criteria left unimplemented
- Verify all implemented functions match specification signatures
- Confirm exported interfaces match specification contracts
- Validate implementation follows specification algorithms

**Integration Compatibility Verification:**
- Confirm all imported dependencies function correctly
- Execute integration tests with dependency modules
- Verify interface contracts are bidirectionally satisfied
- Confirm this file provides all exports required by dependents
- Verify implemented interfaces match dependent expectations

**Quality Assurance:**
- Verify code follows language-specific conventions and idioms
- Confirm appropriate documentation and comments present
- Validate comprehensive error handling implementation
- Verify implementation meets performance requirements from specification
- Check memory and computational resource usage is acceptable

**Completion Documentation:**
- Files modified: list of all files created or modified
- Functions implemented: complete list with signatures
- Tests created: summary with pass/fail status
- Requirements satisfied: list of acceptance criteria satisfied
- Deviations: any deviations from specification with rationale
- Assumptions: implementation assumptions made
- Future considerations: notes for maintenance or enhancement

**Phase Success Criteria:**
- All acceptance criteria tests pass for this file
- Integration compatibility verified with all dependencies
- Implementation matches specification requirements
- Code quality meets project standards
- Completion documentation is comprehensive

---

### DAG Progression

**File Completion Tracking:**
- Mark file as `implementation_complete` with ISO 8601 timestamp
- Record final test suite results with pass/fail counts
- Record metrics: lines of code, functions implemented, test coverage
- Update DAG progress: increment completed files, update remaining files, calculate completion percentage

**Next File Preparation:**
- Validate all dependencies for next file are complete
- Identify any files blocked by missing dependencies
- Maintain context of completed implementations for dependency resolution
- Update global integration state with new implementations

**Continuation Criteria:**
- More files exist in DAG topological order
- Next file dependencies are complete
- No unresolved implementation failures

**Completion Criteria:**
- All DAG files successfully implemented
- End-to-end integration tests pass
- All original ticket acceptance criteria satisfied

## Quality Gates

| Gate | Phase | Criteria | Failure Action |
|------|-------|----------|----------------|
| prerequisite_validation | startup | All required input files exist and are valid | Halt and request planning/specification phases |
| test_suite_quality | test_development | Test quality validator returns PASS with 100% coverage | Regenerate test suite addressing failures |
| implementation_success | implementation | 100% test pass rate with no regressions | Continue TDD cycle or apply fix process |
| requirement_satisfaction | validation | All file-specific acceptance criteria tests pass | Identify missing requirements and implement |
| integration_compatibility | validation | Integration tests pass with all dependencies | Resolve integration issues and verify compatibility |

## Error Handling

**Critical Failures:**
- **missing_prerequisites:** Required input files missing or invalid -- HALT with specific details, request planning/specification phases
- **unresolvable_test_failures:** TDD cycle cannot achieve 100% pass rate -- apply `@~/.claude/skills/processes:fix/SKILL.md`, escalate to specification review
- **specification_ambiguity:** Ambiguous or contradictory requirements -- document ambiguity, make reasonable decision, continue
- **dependency_unavailable:** Required dependency not implemented or incompatible -- HALT, check DAG ordering and dependency completion
- **integration_regression:** Implementation breaks previously passing integration tests -- analyze and fix, escalate for architectural review if unresolvable

**Recoverable Failures:**
- **test_framework_issues:** Configuration or execution problems -- diagnose and fix (max 3 attempts)
- **build_system_errors:** Compilation or build failures -- analyze and fix syntax/dependency issues (max 5 attempts)
- **performance_degradation:** Fails performance requirements -- optimize algorithms or data structures (max 3 attempts)

**Warnings:**
- **high_test_iteration_count:** TDD cycle requires more than 7 iterations -- document complexity, consider specification simplification
- **specification_deviation:** Implementation deviates due to practical constraints -- document rationale and impact
- **test_coverage_gaps:** Coverage below 95% despite passing tests -- identify uncovered paths, add tests if relevant

## Success Confirmation

**IMPLEMENTATION PHASE COMPLETE:** All planned changes successfully implemented with functional code, comprehensive test coverage, and documentation. Implementation ready for integration testing and deployment.
