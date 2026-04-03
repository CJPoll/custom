# Implementation Reference

This file contains TDD patterns, validation templates, and progress reporting formats referenced by the main [SKILL.md](./SKILL.md).

## Test Development Patterns

### Test Categories Detail

#### Unit Tests
- **Scope:** Individual function/method behavior validation
- **Coverage:** All public interface functions with parameter variations
- **Focus:** Input validation, output correctness, error handling

#### Integration Tests
- **Scope:** Inter-module communication and dependency interaction
- **Coverage:** All integration points identified in dependency analysis
- **Focus:** Interface contract compliance, data flow validation

#### Acceptance Tests
- **Scope:** Business logic validation per ticket requirements
- **Coverage:** All acceptance criteria mapped to this file
- **Focus:** End-to-end behavior matching ticket specifications

#### Edge Case Tests
- **Scope:** Boundary conditions and error scenarios
- **Coverage:** All identified edge cases and failure modes
- **Focus:** Error handling, boundary values, exceptional conditions

### Test Case Structure Template

```
Test Name:        [Descriptive name indicating behavior being validated]
Test Purpose:     [Clear statement of what behavior is being tested]
Setup:            [Test environment configuration and data preparation]
Input:            [Exact input parameters with types and values]
Expected Output:  [Precise expected results with success criteria]
Failure Message:  [Clear error messages for test failures]
Requirement:      [Reference to specific acceptance criteria being validated]
```

### Test Implementation Requirements

- Test must be executable with current test framework
- Test must provide clear pass/fail determination
- Test must validate meaningful behavior, not implementation details
- Test must include appropriate assertions and error handling

### Test Quality Validation

**Validator: Test Suite Quality and Completeness**

**Tasks:**
- Verify all public functions have corresponding unit tests
- Check test cases cover all acceptance criteria for this file
- Validate test assertions are specific and meaningful
- Confirm edge cases and error conditions are tested
- Verify test independence and repeatability

**Success Criteria (threshold: 100%):**
- Every public function has at least one unit test
- All file-specific acceptance criteria have test coverage
- All test assertions are specific and measurable
- Edge cases and error scenarios are comprehensively tested
- Tests are independent and can run in any order

**Output Fields:**
- `validation_status`: PASS or FAIL
- `untested_functions`: Functions without unit tests
- `uncovered_criteria`: Acceptance criteria without tests
- `weak_assertions`: Tests with vague or insufficient assertions
- `missing_edge_cases`: Unhandled boundary conditions
- `test_independence_issues`: Tests with dependencies on other tests
- `coverage_score`: 0-100% test coverage rating

### Test Refinement Process

If test quality validator returns FAIL:
1. Analyze specific validation failures
2. Regenerate failing test sections
3. Repeat validation until PASS achieved
4. Maximum 3 attempts before escalation

**Test Pruning Criteria:**
- Tests that fail validation requirements
- Tests that validate implementation details rather than behavior
- Tests that duplicate existing coverage without adding value

## TDD Cycle Details

### Failure Categorization

| Priority | Category | Description |
|----------|----------|-------------|
| 1 | Missing implementations | Blocking multiple tests |
| 2 | Incorrect behavior | Core functionality errors |
| 3 | Type/signature mismatches | Compatibility issues |
| 4 | Error handling deficiencies | Edge case failures |
| 5 | Integration/dependency issues | Cross-module problems |

### Implementation Strategy

**Minimal Implementation Principle:**
- Implement only what is necessary to make failing tests pass
- Start with simplest implementation that satisfies test requirements
- Do not add functionality not covered by tests

**Specification Compliance:**
- Implementation must match function signatures from specification
- Algorithm implementation should follow specification guidelines
- Error handling must implement specified error tuple patterns

**Code Generation Guidelines:**
- **Function implementation:** Match exact signatures, include type specifications and documentation, follow specification algorithms, implement specified error patterns
- **Module structure:** Follow language conventions, include appropriate documentation comments, expose only functions specified in interface contracts

### Regression Check Protocol

- Execute full test suite including previously passing tests
- Verify no previously passing tests now fail
- Confirm dependencies still function correctly
- If regression detected: analyze breaking changes and implement compatibility fixes
- If regression unresolvable: document and escalate

## Progress Reporting Templates

### Per-File Completion Report

```
File Name:              [name of file completed]
Implementation Status:  SUCCESS | FAILED | PARTIAL
Test Results:
  Total Tests:          [count]
  Passing:              [count]
  Failing:              [count]
  Coverage:             [percentage]
Requirements Satisfied: [list of AC-XXX criteria]
Implementation Time:    [duration]
TDD Iterations:         [count]
Deviations:             [any deviations from spec with rationale]
```

### Overall Progress Tracking

**DAG Progress:**
- Completed files: count and list
- Remaining files: count and list
- Progress percentage: overall completion
- Estimated remaining time: based on current pace

**Quality Metrics:**
- Overall test pass rate: aggregate across all files
- Requirements satisfaction rate: percentage of ticket requirements satisfied
- Integration success rate: percentage of successful integrations

### Final Completion Report

**Implementation Summary:**
- Total files implemented
- Total tests created
- Overall test pass rate
- Requirements completion percentage
- Implementation timeline (start to finish)

**Deliverable Verification:**
- Acceptance criteria status: status of all original criteria
- Integration validation: results of end-to-end testing
- Documentation completeness: status of implementation docs
- Deployment readiness: assessment of readiness

## Validation and Quality Assurance

### Requirement Compliance Check

- All file-specific acceptance criteria tests pass
- Map passing tests to original ticket requirements
- Verify no acceptance criteria left unimplemented
- Verify implemented functions match specification signatures
- Confirm exported interfaces match specification contracts
- Validate implementation follows specification algorithms

### Integration Compatibility Verification

- Confirm all imported dependencies function correctly
- Execute integration tests with dependency modules
- Verify interface contracts bidirectionally satisfied
- Confirm file provides all exports required by dependents
- Verify implemented interfaces match dependent expectations

### Code Quality Check

- Language conventions and idioms followed
- Appropriate documentation and comments present
- Comprehensive error handling implemented
- Performance requirements met from specification
- Memory and computational resource usage acceptable

### Completion Documentation Template

```
## Implementation Summary
- Files Modified: [list]
- Functions Implemented: [list with signatures]
- Tests Created: [summary with pass/fail]
- Requirements Satisfied: [list of AC-XXX]

## Implementation Notes
- Deviations: [from original specification with rationale]
- Assumptions: [made during development]
- Future Considerations: [maintenance or enhancement notes]
```
