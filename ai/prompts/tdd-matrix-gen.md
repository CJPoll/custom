THINK I have a ticket: $ARGUMENTS

DO NOT make any changes to tests or code.

You have generated context on that ticket and saved it in @ai-artifacts/context.md

You have generated an implementation plan based on that context and saved it in
@ai-artifacts/implementation-plan.md

Follow this process:
1. For each file described in the DAG for the implementation plan, I want you to
   use a subagent to generate comprehensive test matrices for me based on that
   implementation plan and the linear ticket. Each file should be processed in
   parallel by a different subagent.
   - Do not include performance tests.
   - Do cover failure cases.
   - Ensure every single code branch in the implementation plan is covered.
   - The output for the file undertest MUST follow the format in
     @~/dev/custom/ai/prompts/format/test-matrix
   - The output for the file under test MUST be saved in the file/directory
     structure described in @~/dev/custom/ai/prompts/format/test-matrix-directory
2. For each test matrix file that is generated, have subagents do the following
   tasks in parallel:
   - Evaluate whether the directory/file structure strictly follows the
     structure described in @~/dev/custom/ai/prompts/format/test-matrix-directory.
     If so, then the subagent approves. Otherwise, the subagent rejects.
   - Evaluate whether each matrix in the file strictly follows the format in
     @~/dev/custom/ai/prompts/format/test-matrix. If so, then the subagent
     approves. Otherwise, the subagent rejects.
   - Evaluate whether all requirements related to the file under test have test
     cases in the matrix file. If so, then the subagent approves. Otherwise, the
     subagent rejects.
3. Once every matrix file has been approved by its evaluating subagents, wait
   for the user to approve the matrix files. They may arbitrarily change the
   plan, the file, or request additional information.
