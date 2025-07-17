THINK I need to systematically resolve code quality violations detected by Credo linter using a structured, iterative approach with parallel subagent execution.

**PRIMARY OBJECTIVE:** Achieve zero Credo violations in strict mode while maintaining code functionality and readability.

**EXECUTION ENVIRONMENT:**
- Language: Elixir
- Static Analysis Tool: Credo
- Primary Commands:
  - Full codebase: `mix credo --strict`
  - Single file: `mix credo --strict <file>`
- **CRITICAL:** `--strict` flag is mandatory for comprehensive violation detection
- Process Documentation: @~/dev/custom/ai/prompts/processes/fix.md

**ITERATIVE CODE QUALITY PROTOCOL:**

**Phase 1: Violation Discovery & Assessment**
1. Execute `mix credo --strict` to establish baseline violation state
2. Parse Credo output to extract:
   - Total violation count by severity (Critical, High, Normal, Low)
   - Specific files with violations (with line numbers and rule names)
   - Violation categories (Consistency, Design, Readability, Refactor, Warning)
   - Auto-fixable vs manual-fix-required violations
3. **Success Criteria:** Credo executes successfully and produces parseable output
4. **Error Handling:** If Credo fails, validate configuration and dependency installation

**Phase 2: Violation Prioritization**
1. Rank violating files by:
   - **Severity Impact:** Critical/High violations take absolute priority
   - **Fix Complexity:** Auto-fixable violations processed first within severity level
   - **File Importance:** Core business logic files prioritized over test/config files
   - **Violation Density:** Files with highest violation count per LOC
2. Select maximum 5 highest-priority files for parallel processing
3. **Validation:** Ensure selected files have no circular dependencies or shared modules

**Phase 3: Parallel Subagent Execution**
For each selected file (max 5 concurrent subagents):

**Subagent Specification:**
- **Role:** Single-file code quality improvement specialist
- **Input:** File path, specific violations with rule names and line numbers
- **Pre-Execution Validation:**
  - Verify file compiles: `mix compile`
  - Baseline violation check: `mix credo --strict <file>`
  - Backup current file state
- **Fix Protocol:**
  - Address violations in severity order: Critical → High → Normal → Low
  - Apply Credo's suggested fixes when available
  - Maintain code semantics and performance characteristics
  - Preserve existing functionality and test compatibility
- **Post-Fix Validation:**
  - Ensure file still compiles: `mix compile`
  - Verify violation resolution: `mix credo --strict <file>`
  - Confirm no new violations introduced
- **Success Criteria:** Zero violations in assigned file with maintained compilation
- **Error Recovery:** If fix breaks compilation or introduces new violations, revert to backup and try alternative approach
- **Output:** Detailed report with before/after violation counts and fix descriptions

**Subagent Coordination:**
- No simultaneous modification of files with `use` or `import` relationships
- Report completion and new violation status before proceeding
- Validate no cross-file style consistency breaks

**Phase 4: Integration Validation**
1. After all subagents complete, execute full analysis: `mix credo --strict`
2. **Success Branch:** If zero violations detected, mission complete
3. **Iteration Branch:** If violations remain, return to Phase 1 with remaining issues
4. **Regression Check:** Ensure compilation still succeeds: `mix compile`
5. **Error Handling:** If new violations introduced, identify regression source and revert problematic changes

**QUALITY GATES:**
- Each iteration must reduce total violation count
- No subagent may break compilation or introduce new violations
- All fixes must preserve code semantics and performance
- Maximum 10 iterations before escalating to manual review
- Code style changes must maintain team consistency standards

**CREDO-SPECIFIC HANDLING:**
- **Auto-fixable violations:** Apply Credo suggestions directly when safe
- **Design violations:** Require careful consideration of architectural impact
- **Consistency violations:** Ensure fixes align with project-wide patterns
- **Performance warnings:** Validate fixes don't degrade runtime characteristics

**TERMINATION CONDITIONS:**
- **Success:** `mix credo --strict` returns zero violations
- **Failure:** No progress after 3 consecutive iterations
- **Error:** Repeated compilation failures or Credo configuration issues

Execute this protocol systematically, reporting Credo violation counts and categories after each phase.
