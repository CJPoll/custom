THINK I have a ticket: $ARGUMENTS

DO NOT make any changes to tests or code.

You have generated context on that ticket and saved it in @ai-artifacts/context.md

You have generated an implementation plan based on that context and saved it in
@ai-artifacts/implementation-plan.md

I want you to generate comprehensive test matrices for me based on that implementation plan.
- Do not include performance tests.
- Do cover failure cases.
- Ensure every single code branch in the implementation plan is covered.

The output for the file undertest MUST follow the format in
@~/dev/custom/ai/prompts/format/test-matrix

The output for the file under test MUST be saved in the file/directory structure
described in @~/dev/custom/ai/prompts/format/test-matrix-directory
