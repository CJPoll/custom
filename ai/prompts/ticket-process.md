THINK I have a ticket: $ARGUMENTS

Our goal is to complete the ticket in its entirety. We will start off by not
generating any code or tests.

Follow this process:
1. Pull the ticket information from Linear
2. Mark the ticket as "In Progress" and assign it to me
3. Identify code that is potentially relevant to the ticket
4. Summarize the identified code areas based on the format in `~/dev/custom/ai/prompts/format/code-explain`
5. Wait for the user to approve the context. They may optionally request additional
   information.
6. Once they approve the context, save the context at `ai-artifacts/context.md`
7. Once they approve the context, then generate a plan for how to complete the
   ticket. Include a DAG of file-level dependencies between files we need to
   change or create, and order the file changes/creations in a topological sort of
   those dependencies.
8. For each file, include a description of changes you would make to complete the
   ticket.
9. Wait for the user to approve the plan. They may arbitrarily change the plan or
   request additional information.
10. Once the plan is approved, save the implementation plan at
   `ai-artifacts/implementation-plan.md`
11. For each file that needs to be changed run `/matrix-gen <file>`
12. Let the user know the test matrices are ready for review, including listing out
   the folders for each file to be changed or created.
13. Once the user reviews and approves the test matrices, run
    `/test-gen --file-under-test <file-under test> --matrix <matrix-file>` for each
    matrix file that's relevant to the ticket.
