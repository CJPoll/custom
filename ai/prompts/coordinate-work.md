THINK HARD

I need you to coordinate work between 4 agents:

@agent-Athena (Tech lead)
@agent-Nyx (Standards Compliance Reviewer)
@agent-Vera (Implementation Specialist)
@agent-Audri (Implementation Reviewer)

Athena follows the process at @~/dev/custom/ai/agents/tech-lead.md
Nyx follows the process at @~/dev/custom/ai/agents/standards-reviewer.md
Vera follows the process at @~/dev/custom/ai/agents/implementor.md
Audri follows the process at @~/dev/custom/ai/agents/implementation-reviewer.md

Every time an agent is invoked, please remind them of their process.

Here is the overall workflow:

1. Athena plans the work, creating a spec. She needs to THINK HARD when
   planning.

2. Nyx reviews the spec for standards compliance, checking all applicable
   CLAUDE.md files and ADRs in `./adrs/`.

3A. If Nyx detects conflicting standards (CLAUDE.md vs ADR, or between 
    different standards), STOP and request HUMAN REVIEW to resolve the 
    conflict. Do not proceed until conflicts are resolved.

3B. If Nyx finds standards violations or omissions, give that feedback to 
    Athena to update the spec. Coordinate a feedback loop between Athena and
    Nyx, reminding them each time to follow their process at the given file
    above.

3C. If Nyx approves the spec (no violations, no conflicts), proceed to step 4.

4. Vera validates that the spec is complete and unambiguous.

5A. If Vera has questions for clarification or feedback on the spec, give that
    feedback to Athena to update the spec. After Athena updates the spec,
    return to step 2 (Nyx must re-review the updated spec for standards
    compliance). Coordinate this feedback loop between Athena, Nyx, and Vera,
    reminding them each time to follow their process at the given file above.

5B. If Vera has no feedback and the spec is ready for implementation, she may
    need confirmation to begin implementation; you may not give her that
    confirmation - the user must give that confiramtion UNLESS the user
    overrides that requirement later in this request.

6. After implementation is complete, invoke Audri to review the implementation,
   reminding her to follow her process at the given file.

7A. If Audri finds gaps in the implementation, coordinate that feedback with
    Vera to correct the implementation. After Vera makes corrections, return to
    step 6 (Audri must re-review).

7B. If Audri finds no gaps in the implementation, then we are done.

Work to be done in this coordination:
$ARGUMENTS
