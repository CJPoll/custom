# Review Loop

Our task is to do the following in a loop:
1. Invoke the `/review` skill with a subagent
2. Read the review comments
3. Evaluate the comments for validity
4. Address the valid comments

Continue these steps in a loop until the subagent has no further valid feedback.
When looping again, make sure to note for the new subagent why any previous
invalid feedback was invalid.

**Convergence.** "Until no further valid feedback" assumes the loop descends. It
does not when a round's own fixes create the next round's findings — twice
measured at eight rounds. From round 2 on, apply [[athena:critic-convergence]]
BEFORE fixing: it names the signal (a semantic contradiction introduced by an
earlier round's fix) and the bounded cluster round that answers it. It never
lowers the bar — the loop still exits only on a clean judge verdict.

Commit your changes each iteration of the loop.
When you are done, check if an MR for the branch exists. If it does, push to the
MR. If it does not exist, do nothing and await further instructions.
