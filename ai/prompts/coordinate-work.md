THINK HARD

I need you to coordinate work between 4 agents:

@agent-Athena (Tech lead)
@agent-Nyx (Standards Compliance Reviewer)
@agent-Vera-Reviewer (Implementation Specialist)
@agent-Vera-Implementor (Implementation Specialist)
@agent-Audri (Implementation Reviewer)

Athena follows the process at @~/dev/custom/ai/agents/tech-lead.md
Nyx follows the process at @~/dev/custom/ai/agents/standards-reviewer.md
Vera-Reviewer follows the process at @~/dev/custom/ai/agents/implementor.md, but
focused on review of the spec for appropriate detail.
Vera-Implementor follows the process at @~/dev/custom/ai/agents/implementor.md,
but focused on implementing the spec after confirmation is given.
Audri follows the process at @~/dev/custom/ai/agents/implementation-reviewer.md

Every time an agent is invoked, please remind them of their process.

Here is the overall workflow:

1. Athena plans the work, creating a spec. She needs to THINK HARDER when
   planning.

2. Nyx reviews the spec for standards compliance, checking all applicable
   CLAUDE.md files and ADRs in `./adrs/`. She needs to THINK HARD while
   reviewing the spec.

3A. If Nyx detects conflicting standards (CLAUDE.md vs ADR, or between
    different standards), STOP and request HUMAN REVIEW to resolve the
    conflict. Do not proceed until conflicts are resolved.

3B. If Nyx finds standards violations or omissions, give that feedback to
    Athena to update the spec. Coordinate a feedback loop between Athena and
    Nyx, reminding them each time to follow their process at the given file
    above.

3C. If Nyx approves the spec (no violations, no conflicts), proceed to step 4.

4. Vera-Reviewer validates that the spec is complete and unambiguous.

5A. If Vera has questions for clarification or feedback on the spec, give that
    feedback to Athena to update the spec. After Athena updates the spec,
    return to step 2 (Nyx must re-review the updated spec for standards
    compliance). Coordinate this feedback loop between Athena, Nyx, and
    Vera-Reviewer, reminding them each time to follow their process at the given
    file above.

5B. If Vera-Reviewer has no feedback and the spec is ready for implementation,
    then Vera-Implementor may need confirmation to begin implementation; you may
    not give her that confirmation - the user must give that confiramtion UNLESS
    the user overrides that requirement later in this request.

6. After Vera-Implementor completes implementation, invoke Audri to review the
   implementation, reminding her to follow her process at the given file.

7A. If Audri finds gaps in the implementation, coordinate that feedback with
    Vera-Implementor to correct the implementation. After Vera-Implementor makes
    corrections, return to step 6 (Audri must re-review).

7B. If Audri finds no gaps in the implementation, then we are done.

One exception: If Nyx has previously approved the spec and Vera-Reviewer has
requested feedback, steps 2 and 4 may be done in parallel. This means that Nyx
and Vera-Reviewer may review the same spec in parallel in that case.

Work to be done in this coordination:
$ARGUMENTS
