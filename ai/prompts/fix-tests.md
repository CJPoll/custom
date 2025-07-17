THINK I need to systematically debug and fix failing tests in this Elixir application using a structured, iterative approach with parallel subagent execution.

**PRIMARY OBJECTIVE:** Achieve 100% test suite success rate through systematic issue identification and resolution.

**EXECUTION ENVIRONMENT:**
- Language: Elixir
- Test Framework: ExUnit via Mix
- Primary Commands:
  - Full suite: `mix test`
  - Single file: `mix test <file> --max-failures 1`
- Process Documentation: @~/dev/custom/ai/prompts/processes/fix.md

**ITERATIVE DEBUG PROTOCOL:**

**Phase 1: Discovery & Assessment**
1. Execute `mix test` to establish baseline failure state
2. Parse output to extract:
   - Total test count and failure count
   - Specific failing test files (with line numbers)
   - Error types (compilation, assertion, timeout, etc.)
   - Dependency-related failures
3. **Success Criteria:** Command executes without system errors
4. **Error Handling:** If mix command fails, diagnose environment issues first

**Phase 2: Issue Prioritization**
1. Rank failing files by:
   - Dependency impact (files that block other tests)
   - Error severity (compilation > assertion > flaky)
   - Test count (files with most failing tests)
2. Select maximum 5 highest-priority files for parallel processing
3. **Validation:** Ensure selected files have distinct, non-overlapping issues

**Phase 3: Parallel Subagent Execution**
For each selected file (max 5 concurrent subagents):

**Subagent Specification:**
- **Role:** Single-file test repair specialist
- **Input:** File path, specific error details, dependency context
- **Validation Requirements:**
  - Verify file exists and is readable
  - Confirm test file syntax before modification
  - Run `mix test <file> --max-failures 1` before and after changes
- **Success Criteria:** All tests in assigned file pass
- **Error Recovery:** If fix introduces new failures, revert and try alternative approach
- **Output:** Status report with before/after test results

**Subagent Coordination:**
- No simultaneous modification of shared dependencies
- Report completion status before proceeding
- Validate no cross-file breaking changes introduced

**Phase 4: Convergence Validation**
1. After all subagents complete, execute full suite: `mix test`
2. **Success Branch:** If all tests pass, mission complete
3. **Iteration Branch:** If failures remain, return to Phase 1 with remaining issues
4. **Error Handling:** If new failures introduced, identify regression source

**QUALITY GATES:**
- Each iteration must reduce total failure count
- No subagent may introduce failures to previously passing tests
- Maximum 10 iterations before escalating to manual review
- All changes must maintain code compilation

**TERMINATION CONDITIONS:**
- **Success:** `mix test` returns exit code 0 with all tests passing
- **Failure:** No progress after 3 consecutive iterations
- **Error:** System-level issues preventing test execution

Execute this protocol systematically, reporting progress after each phase.
