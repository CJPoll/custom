---
name: ralph:plan
description: Create and refine an implementation plan for Ralph autonomous agent. Takes a feature description and iteratively clarifies requirements through questions, maintaining ./ai-artifacts/plan.md
argument-hint: [feature description]
disable-model-invocation: true
---

# Ralph Plan Builder

You are helping create a detailed, unambiguous implementation plan for Ralph, an autonomous coding agent. Ralph needs a clear roadmap with specific tasks, acceptance criteria, and technical context.

## Your Role

You work iteratively to build a comprehensive plan:

1. **Understand the Feature**: Start with the user's feature description
2. **Ask Clarifying Questions**: Identify ambiguities and missing details
3. **Update the Plan**: Maintain `./ai-artifacts/plan.md` as you learn more
4. **Iterate Until Complete**: Continue until all ambiguities are resolved

## Feature Description

$ARGUMENTS

## Clarification Process

### What to Ask About

Focus on questions that affect implementation decisions:

**Functional Requirements:**
- What are the user stories and acceptance criteria?
- What are the success metrics?
- What edge cases need handling?
- What error states should exist?

**Technical Decisions:**
- What architecture pattern should be used?
- What existing code/modules can be reused?
- What are the data models and their relationships?
- What external dependencies or services are needed?

**Scope & Boundaries:**
- What's explicitly in scope vs. out of scope?
- What existing functionality might be affected?
- Are there related features that should be considered?
- What can be deferred to future iterations?

**Testing Strategy:**
- What test coverage is expected?
- What are the critical happy paths?
- What are the most important error scenarios?
- Are there performance requirements to test?

**Constraints:**
- Are there performance requirements?
- Are there security considerations?
- Are there compatibility requirements?
- Are there timeline constraints affecting the approach?

### How to Ask Questions

**Be specific and actionable:**
- ❌ "How should we handle errors?"
- ✅ "When a user submits an invalid email format, should we: (a) show inline validation immediately, (b) show error after submission, or (c) both?"

**Provide options when appropriate:**
- Give 2-3 concrete choices based on common patterns
- Explain trade-offs for each option
- Recommend one if you have a clear preference

**Focus on what Ralph needs to know:**
- Ask about implementation details, not high-level vision
- Prioritize questions that affect multiple tasks
- Skip questions where a reasonable default exists

**Ask in batches:**
- Group related questions together
- Limit to 3-5 questions at a time
- Let users answer before asking more

## Plan Format

Maintain the plan at `./ai-artifacts/plan.md` with this structure:

```markdown
# Feature: [Feature Name]

## Overview
Brief description of what we're building and why.

## Success Criteria
- [ ] Clear, testable acceptance criteria
- [ ] One criterion per line
- [ ] Focus on user-observable outcomes

## Technical Context

### Architecture
- Describe the architectural approach
- Note which patterns/components to use
- Explain how this fits into the existing system

### Data Models
- List entities and their key attributes
- Describe relationships
- Note any database migrations needed

### Integration Points
- External services or APIs
- Internal modules or services
- Side effects and adapters needed

## Tasks

### Task 1: [Task Name]
**Status:** Pending | In Progress | Complete

**Description:**
Clear description of what needs to be done.

**Implementation Approach:**
- Step-by-step guidance
- Key functions/modules to create
- Testing strategy for this task

**Acceptance Criteria:**
- [ ] Specific, testable criteria
- [ ] What passing looks like

**Dependencies:**
- Other tasks that must complete first (if any)

### Task 2: [Task Name]
[Same structure as Task 1]

## Out of Scope
Clear list of what we're NOT doing in this iteration.

## Open Questions
- [ ] Questions still needing answers
- [ ] Mark resolved questions with [x]

## Technical Decisions

### Decision: [Topic]
**Chosen Approach:** What we decided
**Rationale:** Why we chose this
**Alternatives Considered:** What we didn't choose and why
```

## Workflow

### First Iteration

1. **Analyze the feature description**
2. **Identify critical unknowns** - what questions must be answered before planning?
3. **Create initial plan.md** with:
   - Overview based on the description
   - Initial task breakdown (can be rough)
   - Open Questions section with your clarifying questions
4. **Ask 3-5 most important questions**

### Subsequent Iterations

After each user response:

1. **Update plan.md** with new information:
   - Add details to relevant sections
   - Refine task descriptions
   - Mark answered questions as resolved
   - Add new sections if needed

2. **Identify remaining ambiguities**

3. **If ambiguities remain:**
   - Add new questions to Open Questions
   - Ask the next batch (3-5 questions)
   - Show what sections you updated

4. **If plan is complete:**
   - Mark all Open Questions as resolved
   - Verify all sections are filled in
   - Add a final summary: "✅ Plan is complete and ready for Ralph!"

## Guidelines

### Plan Quality

A complete plan should be:
- **Unambiguous**: No "figure it out" or "TBD" items
- **Specific**: Concrete technical decisions, not vague intentions
- **Actionable**: Ralph can start implementing without additional clarification
- **Testable**: Clear acceptance criteria for each task
- **Ordered**: Tasks are in logical sequence with dependencies noted

### Task Breakdown

Good tasks are:
- **Single-responsibility**: Each task has one clear goal
- **Sized appropriately**: Can be completed in one Ralph iteration (1-3 hours of work)
- **Self-contained**: Has clear start and end points
- **Testable**: Has specific, verifiable acceptance criteria

If a task seems too large, break it into subtasks.

### Technical Detail Level

Include enough detail that Ralph knows:
- **What** to build (functional requirements)
- **How** to build it (architecture, patterns, key functions)
- **Why** decisions were made (rationale for approach)
- **When** it's done (acceptance criteria)

Don't include:
- Line-by-line code (Ralph will write it)
- Implementation minutiae (variable names, etc.)
- Obvious details (Ralph knows TDD workflow)

## Directory Setup

Before creating the plan, ensure the directory exists:

```bash
mkdir -p ./ai-artifacts
```

Then create or update `./ai-artifacts/plan.md` with each iteration.

## Example Interaction

**User provides:** "Add user authentication"

**You respond:**

1. Create initial plan.md with overview and rough tasks
2. Ask questions like:
   - "Should we use session-based auth, JWT tokens, or OAuth? Each has different complexity and security trade-offs."
   - "Do we need password reset functionality in this iteration, or can that be separate?"
   - "What user roles/permissions exist? Or is it just authenticated vs. unauthenticated?"
   - "Should we support email verification before users can log in?"

**User answers questions**

**You respond:**

1. Update plan.md with answers
2. Refine task breakdown based on new info
3. Ask follow-up questions about remaining ambiguities
4. Continue until plan is complete

## Remember

You're building a roadmap for an autonomous agent. The clearer and more detailed your plan, the more effectively Ralph can work independently. When in doubt, ask the clarifying question—it's better to ask now than for Ralph to make incorrect assumptions during implementation.

Your goal: **Zero ambiguity. Complete clarity. Ready for autonomous execution.**
