# Test Matrix

IMPORTANT: Before creating the test matrix, invoke the `ruby-testing-pyramid` skill to understand the testing strategy:

```
Skill(skill: "ruby-testing-pyramid")
```

In @~/dev/beryl/lib/schemas/test_matrix.json, we define a JSON schema that this feature's `tests.yaml` (the path to which is in context) MUST conform to.

For each of the side-effect-free domain-layer classes and methods involved in this feature's architecture, we need to define the test matrix for automated testing of the behavior of these classes and methods. This should be put in this feature's tests.yaml, which must conform to the JSON schema in test_matrix.json as previously mentioned.

## Testing Strategy

Following the testing pyramid:
- **Domain Layer**: Exhaustive test matrices for all pure functions and domain logic
- **Manager Layer**: Exhaustive tests with mocked adapters (defined separately from matrices)
- **Adapter Layer**: Repository contract tests with in-memory database
- **Integration**: Minimal happy-path tests only

The test matrix output should include:

1. **Domain Layer Test Matrix** (tests.yaml dimensions and cases)
2. **Manager Layer Test Specifications** (detailed test descriptions)

## Domain Layer Test Matrix

Focus the test matrix dimensions and cases on **domain layer only** - the pure, side-effect-free logic that forms the base of the pyramid.

For each domain module/function identified in the architecture:
- Define dimensions representing input variations
- Generate exhaustive test cases covering all combinations
- Include boundary cases and validation cases
- Specify expected outcomes

Example dimensions:
- Input values (valid ranges, boundary values)
- Input types (different data structures)
- Edge cases (empty, nil, extreme values)

## Manager Layer Test Specifications

After defining the domain layer test matrix, create exhaustive test specifications for each manager in the feature's architecture.

For each manager class, define test cases covering:

### 1. Happy Path Operations
- Test successful orchestration of core workflows
- Verify correct delegation to adapters and domain logic
- Check return values match expected `{ok: value}` structure

### 2. Error Handling Paths
- Missing/invalid input data
- Adapter failures (returns nil or error)
- Cross-domain manager failures
- Domain validation failures

### 3. Cross-Domain Coordination
- Verify calls to cross-domain managers
- Test handling of cross-domain errors
- Verify transaction-like behavior (if applicable)

### 4. Orchestration Logic
- Correct sequence of adapter calls
- Proper data transformation between layers
- State management (if applicable)

### Test Specification Format

For each manager, provide:

```markdown
### ManagerName

**Dependencies:**
- adapter_name (mocked)
- cross_domain_manager (mocked)
- another_adapter (mocked)

**Test Cases:**

#### Happy Path
1. **test_operation_name_succeeds**
   - Setup: Mock adapter returns valid data
   - Action: Call manager.operation(params)
   - Assert: Returns {ok: result}, verify mock calls

2. **test_operation_delegates_to_cross_domain**
   - Setup: Mock cross-domain manager, mock adapters
   - Action: Call manager.operation(params)
   - Assert: Cross-domain manager called with correct args

#### Error Handling
3. **test_operation_returns_error_when_adapter_fails**
   - Setup: Mock adapter returns nil
   - Action: Call manager.operation(params)
   - Assert: Returns {error: "reason"}

4. **test_operation_returns_error_when_cross_domain_fails**
   - Setup: Cross-domain manager returns {error: "reason"}
   - Action: Call manager.operation(params)
   - Assert: Returns {error: "reason"}, does not call subsequent adapters

#### Edge Cases
5. **test_operation_with_boundary_values**
   - Setup: Mocks with extreme but valid values
   - Action: Call manager.operation(edge_case_params)
   - Assert: Handles correctly, returns expected result
```

Use the manager layer examples from the ruby-testing-pyramid skill as reference for:
- Mock setup patterns (Minitest::Mock)
- Expectation patterns (.expect method)
- Verification patterns (.verify calls)
- Result hash patterns ({ok: value} vs {error: reason})

$ARGUMENTS
