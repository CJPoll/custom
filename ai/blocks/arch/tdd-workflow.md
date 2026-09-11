## TDD Workflow

Implement in this order; do not start a step until the previous one is proven:

1. Domain tests — prove the functional requirements and expectations.
2. Domain implementation.
3. Iterate domain tests and code until every domain-layer requirement passes.
4. Manager tests, mocking adapters/repositories.
5. Manager implementation.
6. A few integration tests for key happy paths (no mocks).
7. UI components and framework wiring last.
