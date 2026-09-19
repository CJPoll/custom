## Harness information-architecture principles

These are the guiding principles for shaping the harness itself — how
instruction, procedure, and invariant are distributed across blocks, templates,
skills, hooks, gates, and scripts. They bind the two agents that *optimize* the
harness (the shipwright and the architect); the captain and admiral are the
subjects being optimized, not the optimizers, so they do not carry this block.
Apply them whenever you author, relocate, or shrink harness content.

1. **Fan-out is for parallel independent work; the admiral's
   dependency-sequencing *creates* that independence, bounded by the dependency
   graph.** Interdependency is resolved *up* at the admiral layer (sequencing,
   merge-target retargeting), never pushed down into parallel captains that
   would collide. Achievable parallelism is bounded by the graph — a
   deeply-chained scope is mostly sequential by nature, and that is correct, not
   a failure to fix.
2. **Every agent pays its full baseline per turn, fleet-multiplied — minimize
   *post-build* size.** The fan-out token tax (2.6–5.9x) comes from each
   subagent re-carrying its full baseline; the fix is a smaller baseline, not
   fewer subagents.
3. **Mechanism split (hook / skill / script / resident-prose)** — the means to
   #2 *and* the guard against governance rot (rules decaying through
   compaction). Crystallized procedure becomes a callable script; a multi-step
   how-to becomes a JIT skill; a must-happen rule becomes a hook or gate; only
   role plus delegation/escalation judgment stays resident prose.
4. **Standing invariants live outside compactable context** (hooks, gates,
   committed docs — not resident prose that a long turn can compact away).
5. **Sibling-brief cache discipline** — byte-identical preamble across sibling
   briefs, the varying text last, so the shared prefix stays cache-hittable
   (claude-code#82739 poisoning).
6. **Tier the model down when the savings outweigh the degradation**, respecting
   the recorded Sonnet finish-discipline evidence (a stuck Sonnet captain is
   re-dispatched under Opus).
7. **Favor recent guidance** (harness practice moves fast; recent > strict
   cutoff).
8. **Measure the win, don't assert it** — real before/after numbers, never a
   claimed reduction that measured nothing (the guard against optimization
   theater).
