---
name: athena:test-specification
description: Enumerate and specify the FUNCTIONAL test cases that prove a design — map every domain constraint and acceptance criterion (including access-control negative cases) to a test, order them for TDD, and specify each as setup/exercise/assertions. Renders the enumeration in the athena:format:test-matrix layout. Use after feature-modeling to define what must be tested before implementation begins.
---

# athena:test-specification

Define the tests that prove the design. Work from the grounded domain model
(its constraints) and the settled design (athena:feature-modeling), not from
the happy path alone.

## Scope: functional tests only

Define FUNCTIONAL test cases. **No** performance, load, migration/rollback, or
infrastructure tests — those are out of scope here.

## Enumerate — every constraint and criterion gets a test

- Every **constraint** from domain grounding — every relevant `constraints` /
  `boundary_conditions` row in the athena:system-spec model — needs an
  automated test. Enumerate them and map each to the test that proves it.
- Every **acceptance criterion** from the requirements needs at least one test.
- **Access-control tests are functional tests and are required.** Enumerate the
  negative cases — who must be *denied*, and where — not just the authorized
  path. A design's authorization branch is only proven when its denials are.

Leave no constraint or criterion without a proving test; if one cannot be
tested as written, that is a gap to surface, not to skip.

## Order for TDD

Order the tests so implementation can follow the TDD workflow (see your
architecture doctrine): domain tests first, then managers with adapters mocked,
then a few integration happy paths, then UI/framework wiring. The test order is
the implementation order.

## Specify each test

For every test, give three parts:

1. **Setup** — the exact data to insert; the fixtures/factories to call.
2. **Exercise** — the function under test and the specific arguments passed.
3. **Assertions** — the specific assertions that prove the acceptance criterion
   or constraint (return values, emitted logs, raised exceptions, side effects).

Vague setup or hand-wavy assertions make a test unimplementable — be exact.

## Output format

Render the enumerated cases in the **athena:format:test-matrix** layout: grouped
by file, then by public function, one markdown table per function with a row per
test case (`#`, `Test Case`, `Inputs`, `Expected Output`, `Category`). Invoke
that skill for the exact table shape; the three-part specification above is the
detail behind each row.
