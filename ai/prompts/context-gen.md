THINK I have a ticket: $ARGUMENTS

Our goal is to complete the ticket in its entirety. We will start off by not
generating any code or tests.

Right now, do the following in order:
1. Pull the ticket information from Linear
2. Mark the ticket as "In Progress" and assign it to me
3. Identify code that is potentially relevant to the ticket
4. Summarize the identified code areas based on the format in
   @~/dev/custom/ai/prompts/format/code-explain
5. Have subagents do the following tasks in parallel:
   - Evaluate whether the output strictly matches the requested format from
     @~/dev/custom/ai/prompts/format/code-explain. If so, then the subagent
     approves. Otherwise the subagent rejects.
6. After all subagents have approved the context, wait for the user to approve
   the context. They may optionally request additional information.
7. Once they approve the context, save the context at `ai-artifacts/context.md`
