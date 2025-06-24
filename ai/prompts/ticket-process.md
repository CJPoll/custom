THINK I have a ticket: $ARGUMENTS

Our goal is to complete the ticket in its entirety. We will start off by not
generating any code or tests.

Follow this process:
1. Pull the ticket information from Linear
2. Identify code that is potentially relevant to the ticket
3. Summarize the identified code areas based on the format in
   `~/dev/custom/ai/prompts/code-explain`
4. Wait for the user to approve the context. They may optionally request additional
   information.
5. Once they approve the context, then generate a plan for how to complete the
   ticket. Include a DAG of file-level dependencies between files we need to
   change or create, and order the file changes/creations in a topological sort of
   those dependencies.
6. For each file, include a description of changes you would make to complete the
   ticket.
7. Wait for the user to approve the plan. They may arbitrarily change the plan or
   request additional information.
8. Once the plan is approved, for each file that needs to be changed run
   `/matrix-gen <file>`
9. Let the user know the test matrices are ready for review, including listing out
   the folders for each file to be changed or created.
10. Once the user reviews and approves the test matrices, run
    `/test-gen --file-under-test <file-under test> --matrix <matrix-file>` for each
    matrix file that's relevant to the ticket.
