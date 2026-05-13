---
name: lessons:capture
description: Capture a lesson into persistent memory before declaring a task done. Detects which write trigger fired (multi-iteration fix, user-explained-why, or reality-surprised-you), distills the lesson, classifies it, and writes it to the knowledge graph or auto-memory as appropriate. Use whenever a task surfaces durable knowledge that should outlive the conversation.
argument-hint: <optional brief description of the lesson; omit to have the skill walk you through identifying it>
---

# Capture Lesson

A task is wrapping up and one of the write triggers fired. Record the
lesson before context is lost. Persistent memory is only useful if it
gets populated — and the moment to populate it is now, while the
context is still loaded.

Lesson hint (optional): $ARGUMENTS

## Triggers — confirm one applies

Don't capture for the sake of capturing. Confirm at least one of
these fired:

1. **A fix or task took more than one iteration.** The gap between
   what you expected to work and what actually worked is the lesson.
2. **The user explained *why* something failed, mattered, or works
   the way it does.** Causal explanations from the user are the
   highest-value captures — knowledge you could not derive from the
   repo or prompt alone.
3. **Reality surfaced something your inputs didn't predict.** A test,
   CI run, system response, stakeholder reply, or document revealed
   a constraint or fact not visible in the code or prompt.

If none fired, stop. Don't fabricate a lesson to justify the skill.

## Process

### 1. Distill the lesson

Write a one-sentence statement of the lesson in your head before
deciding where it goes. A good lesson statement names:
- The **symptom** (what looked wrong, surprised you, or took multiple tries)
- The **constraint** that caused it (the underlying truth)
- The **adjustment** (what to do differently next time)

If you can't state all three crisply, the lesson is probably not yet
durable. Either keep working until it is, or skip capture.

### 2. Classify destination

| Lesson shape | Destination |
|--------------|-------------|
| Anti-pattern in Claude's own behavior (a tic, a default move, a way of misreading prompts) | KG — `Claude Collaboration Knowledge` ontology, `InteractionAntipattern` class |
| Positive collaboration behavior worth repeating (confirmed by user agreement or accepted-without-pushback) | KG — `Claude Collaboration Knowledge` ontology, `CollaborationPattern` class |
| Non-obvious operational fact about a specific project's workflow | KG — `Claude Collaboration Knowledge` ontology, `ProjectOperationalFact` class |
| Explicit preference Cody has stated about how to work (communication, code style, tooling) | KG — `Claude Collaboration Knowledge` ontology, `UserPreference` class |
| Business domain fact (entity, relationship, attribute) | KG — relevant domain ontology (e.g. `Real Estate CRM Domain`) |
| Architectural pattern / principle observation | KG — `Software Architecture` ontology |
| Single flat note that doesn't fit any class above (e.g. pointer to an external doc) | Auto-memory — `reference` type |
| Transient project context (current sprint focus, who's doing what this week) | Auto-memory — `project` type |

When unsure between KG and auto-memory: if the fact has structure
(typed attributes, relationships to other entities), use the KG. If
it's a single flat observation with no useful structure, use
auto-memory.

### 3. Check for duplicates

Before creating a new node or memory file:
- For KG: `describe_knowledge_base` on the destination KB and search
  for existing nodes with similar labels. Update the existing node
  rather than duplicating.
- For auto-memory: read `MEMORY.md` index and check whether an
  existing memory file covers the same topic. Update the existing
  file rather than creating a near-duplicate.

### 4. Write

**For knowledge graph (`Claude Collaboration Knowledge` ontology):**

The ontology has structural backbone classes — `Conversation`,
`Event`, `Project` — that knowledge nodes link to via relationships.
Wire your new node into that backbone, don't leave it floating.

a. **Ensure a Conversation node exists for this session.** Search
   the KB for a Conversation node with today's date and matching
   topic. If none exists, create one with `date`, `topic`, and link
   it to the relevant `Project` via `concerning`.

b. **Create the lesson node** with a clear label and assert its
   required attributes:
   - `InteractionAntipattern`: `trigger`, `behavior`, `why_avoid`
     (required) + `better_alternative` (optional)
   - `ProjectOperationalFact`: `area`, `fact`, `why_structural`
     (required) + `implication` (optional). Note: `project_name` is
     no longer an attribute — link via the `about` relationship instead.
   - `CollaborationPattern`: `pattern`, `when_to_apply`, `why_works`
     (required) + `evidence` (optional)
   - `UserPreference`: `preference` (required) + `domain`, `reason`
     (optional)

c. **Wire the node to the backbone via relationships:**
   - All four lesson classes: `surfaced_in` → the Conversation node
     for this session
   - `ProjectOperationalFact`: `about` → the relevant `Project` node
     (create the Project node if it doesn't exist)
   - `CollaborationPattern`: `applies_to` → `Project` node, when
     project-specific
   - `InteractionAntipattern`: `applies_to` → `Project` node, when
     project-specific (most are general — skip if so)
   - `InteractionAntipattern`: `triggered_by` → an `Event` node, if
     a discrete incident generalized into the lesson. Create the
     Event node and link it to the Conversation via `occurred_in`.
   - `UserPreference`: `stated_in` → the Conversation node

d. Use a consistent `source` value for in-conversation captures:
   `User conversation with Cody, YYYY-MM-DD`. For lessons from a
   document, CI run, or external system, use a more specific source.

**For auto-memory:**
- Write a new file under the per-project `memory/` directory with
  the proper frontmatter (name, description, type).
- For feedback/project types: structure the body as the rule/fact,
  then `**Why:**` and `**How to apply:**` lines.
- Add a one-line entry to `MEMORY.md` linking to the new file.

### 5. Confirm and report

Tell the user concisely:
- What was captured
- Where it landed (KB and node label, or memory file path)
- Any caveats — e.g. "this might be transient and worth re-evaluating
  in a few weeks", or "I updated an existing node rather than
  creating a new one"

## Anti-patterns to avoid

- **Capturing every iteration.** Most multi-iteration fixes are just
  typos, missing args, or normal back-and-forth. Capture only when
  the iteration revealed a *constraint* you didn't know about.
- **Capturing the symptom without the cause.** "The deploy failed"
  is not a lesson. "The deploy failed because the GitLab HTTP
  backend requires `-backend-config` on init when the backend type
  changes" is.
- **Recording transient state.** In-progress task status, current
  sprint focus, today's bug — these belong in tasks/plans, not
  memory.
- **Skipping the "why".** Without the reason, future-you can't
  judge whether the lesson still applies in an edge case. Always
  include the constraint, not just the rule.
