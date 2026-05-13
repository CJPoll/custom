---
name: task:start
description: Open a substantive task by querying the knowledge graph and auto-memory for prior decisions, lessons, anti-patterns, and project operational facts relevant to the work. Use at the start of any non-trivial task — feature implementation, infra changes, research, planning, debugging, business questions — before committing to an approach.
argument-hint: <description of the task you're about to start>
---

# Start Task

You are about to start a substantive task. Before committing to an
approach, query persistent memory for context that would shape your
plan. The knowledge graph and auto-memory are only useful if you
actually consult them — treat this as load-bearing, not decorative.

Task you're about to start: $ARGUMENTS

## When to skip

This skill is overkill for trivial tasks. Skip it when the request is:
- A single-file edit with obvious intent ("rename this variable", "add
  a missing import")
- A pure question about code currently visible in the conversation
- A one-shot lookup that won't influence design decisions

If you're unsure, run it. The cost of a redundant check is low. The
cost of starting a refactor that contradicts a decision recorded
months ago is high.

## Process

### 1. Classify the task

Identify what kind of task this is — the classification determines
which memory areas to check:

| Task type | Likely-relevant memory |
|-----------|------------------------|
| Feature implementation in a domain | Domain ontology + knowledge base, ADRs, prior project facts |
| Infra/DevOps/CI change | Project operational facts, prior incident lessons, anti-patterns |
| Architecture decision | Software architecture KB, ADRs, prior decisions in the area |
| Business question / strategy | Domain KB, governance graph (definitions + stewardship) |
| Research / planning | Any KB whose ontology touches the topic |
| Debugging a recurring issue | Project operational facts, prior fix lessons |

Often a task spans categories — check all that apply.

### 2. Discover what graphs exist

If you don't already know what's available in the knowledge graph,
list the four graph types:

```
list_ontology_graphs
list_knowledge_bases
list_data_graphs
list_governance_graphs
```

Match the task to one or more graphs by name and description. If
nothing obviously matches, that itself is signal — the task may be
in a domain with no recorded context yet, which makes capturing
lessons from this task more important.

### 3. Read the relevant graphs

For each matched knowledge base / graph, call its `describe_*` tool
to load contents. Be aware that mature graphs can be large (>100K
characters) — if `describe_knowledge_base` returns a file path
because the result was too large, use `grep`/`jq` against the saved
file rather than reading it whole.

Look specifically for:
- **Prior decisions and constraints** in the task area
- **Anti-patterns** — things to avoid (especially in
  `Claude Collaboration Knowledge`)
- **Project operational facts** — non-obvious truths about how the
  project's workflow actually behaves
- **Related entities and relationships** that frame the work
- **Recorded lessons** from past iterations

### 4. Check auto-memory

Read `MEMORY.md` in the per-project memory directory (path is given
in your system prompt under "auto memory"). Follow pointers to any
files whose descriptions are relevant. Auto-memory carries flatter
notes — user preferences, project-specific feedback, references to
external systems.

### 5. Surface findings

Tell the user — in a few lines, not paragraphs — what you found that
will shape your approach. Format:

```
Context loaded:
- [thing 1] — implication for this task
- [thing 2] — implication for this task
- (etc.)

Nothing found on: [topics where the graph/memory was silent]
```

The "nothing found" line matters. It tells the user where the memory
is thin and flags areas that may be worth capturing from once this
task is done.

### 6. Now plan

Only after surfacing context, propose a plan that integrates what you
found. If a recorded decision conflicts with what the user just asked
for, raise that explicitly — don't silently override either side.

## Anti-patterns to avoid

- **Querying once, then ignoring results.** If you read a node and
  proceed with an approach that contradicts it, you've burned the
  query for nothing.
- **Reading the whole graph "just in case".** Match the query to the
  task. A 114K-character KB dump that you skim once doesn't beat a
  focused read of the 3 nodes that actually matter.
- **Treating "no results" as a stopping signal.** Empty results mean
  the topic is uncaptured, which is exactly when capturing from the
  current task pays off most. Note the gap and continue.
