THINK I have a ticket: $ARGUMENTS

You have generated context on that ticket and saved it in @ai-artifacts/context.md

Follow this process:
1. Based on the context, generate a plan for how to complete the ticket. Include
   a DAG of file-level dependencies between files we need to change or create,
   and order the file changes/creations in a topological sort of those
   dependencies.
2. For each file, include a description of changes you would make to complete the
   ticket.
3. Have subagents do the following tasks in parallel:
   - Evaluate whether the DAG follows actual code dependencies. If so, then the
     subagent approves. Otherwise the subagent rejects.
   - Evaluate whether there are any gaps between the plan and the linear ticket
     requirements.
4. After all subagents have approved the context, wait for the user to approve
   the context. They may arbitrarily change the plan or request additional
   information.
5. Once the plan is approved, save the implementation plan at
   `ai-artifacts/implementation-plan.md`
