# implement

IMPORTANT: Before implementing, invoke the `ruby-testing-pyramid` skill to understand the testing and implementation order:

```
Skill(skill: "ruby-testing-pyramid")
```

Based on the spec files defined for this feature, let's implement the feature following TDD and the testing pyramid.

## Implementation Order

Follow this sequence strictly (skip layers not specified in the feature):

1. **Domain Layer Tests** → **Domain Layer Implementation**
   - Write exhaustive tests for all pure functions and domain logic
   - Implement domain structs and pure functions
   - No mocking needed (pure logic)

2. **Adapter Layer Tests** → **Adapter Layer Implementation**
   - Write repository contract tests with in-memory database
   - Implement repositories and mappers
   - Test CRUD operations and constraints

3. **Manager Layer Tests** → **Manager Layer Implementation**
   - Write exhaustive tests with mocked adapters
   - Implement orchestration logic
   - Mock all dependencies (adapters, cross-domain managers)

4. **UI Layer Implementation** (minimal/no automated tests)
   - Implement GTK widgets following callback pattern
   - Manual testing preferred
   - Focus on interaction contracts (on_complete, on_select, etc.)

5. **Integration Tests** (happy path only)
   - Write minimal end-to-end tests with real adapters
   - Cover critical user workflows only
   - Non-exhaustive (edge cases covered by unit tests)

6. **MCP Layer Implementation** (minimal/no automated tests)
   - Implement GTK widgets following callback pattern
   - Manual testing preferred
   - Focus on interaction contracts (on_complete, on_select, etc.)

## Per-Layer Testing Requirements

- **Domain**: 100% coverage of logic, all edge cases
- **Adapters**: Core CRUD + constraints
- **Managers**: All code paths with mocked dependencies
- **Integration**: Happy path workflows only
- **UI**: Manual testing

Skip any layers not required by the feature specification.
Systematically work through each layer in implementation order until the entire
feature is completed.

$ARGUMENTS
