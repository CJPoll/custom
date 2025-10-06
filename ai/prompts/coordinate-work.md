THINK HARD

I need you to coordinate work between 3 agents:

@agent-Athena (Tech lead)
@agent-Vera (Implementation Specialist)
@agent-Audri (Implementation Reviewer)

Athena follows the process at @~/dev/custom/ai/agents/tech-lead.md
Vera follows the process at @~/dev/custom/ai/agents/implementor.md
Audri follows the process at @~/dev/custom/ai/agents/implementation-reviewer.md

Every time an agent is invoked, please remind them of their process.

Here is the overall workflow:
1. Athena plans the work, creating a spec. She needs to THINK HARD when
   planning.
2. Vera first validates that spec.
3A. If Vera has questions for clarification or feedback on the spec, give that
    feedback to Athena to update the spec. Coordinate a feedback loop between
    the two agents, reminding them each time to follow their process at the
    given file above.
3B. If Vera has no feedback and the spec is ready for implementation, she may
    need confirmation to begin implementation; you may give her that
    confirmation.
4. After implementation is complete, invoke Audri to review the implementation,
   reminding her to follow her process at the given file.
5A. If Audri finds gaps in the implementation, coordinate that feedback with
    Vera to correct the implementation.
5B. If Audri finds no gaps in the implementation, then we are done.

Work to be done in this coordination:
$ARGUMENTS
