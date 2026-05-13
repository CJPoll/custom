# Review Loop

Our task is to do the following in a loop:
1. Invoke the `/review` skill with a subagent
2. Read the review comments
3. Evaluate the comments for validity
4. Address the valid comments

Continue these steps in a loop until the subagent has no further valid feedback.
When looping again, make sure to note for the new subagent why any previous
invalid feedback was invalid.

Commit your changes each iteration of the loop.
When you are done, check if an MR for the branch exists. If it does, push to the
MR. If it does not exist, do nothing and await further instructions.
