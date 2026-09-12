---
name: athena:feature-modeling
description: Model a feature's design as three diagrams under the 5-bucket architecture — a flowchart (the algorithm), a class diagram (the structure), and a sequence diagram (the bridge that maps each algorithm step onto the modules that execute it). Use after grounding in the domain model (athena:domain-grounding) to turn a use case into a precise, bucket-checked structural design before specifying tests.
---

# athena:feature-modeling

Turn a grounded use case into a precise design. Ground yourself first — invoke
**athena:domain-grounding** — so the model, its constraints, and its
access-control system are in hand before you draw anything.

## The three diagrams and their strict roles

This separation is the whole discipline. Do not blur it:

1. **Flowchart — all algorithm, no structure.** Steps, branches, loops, error
   paths, terminal states. No modules, no layers, no classes.
2. **Class diagram — all structure, no algorithm.** Modules/classes, their
   buckets, their data, their relationships. No control flow.
3. **Sequence diagram — the bridge between the two.** It maps each flowchart
   step onto the classes/modules that execute it. This is the only diagram
   where algorithm and structure meet.

Keeping the flowchart free of structure and the class diagram free of algorithm
is what makes the sequence diagram meaningful — it has real work to do bridging
them, instead of restating one or the other.

## Step 1 — Flowchart (the algorithm)

Produce the flowchart for the use case: steps, branches, loops, error paths,
terminal states — algorithm only. **If you find yourself naming a module,
you're in the wrong step.**

The authorization decision is part of the algorithm: show it as an explicit
branch — what is checked, against which subject and resource, and where the
denied path goes. A flowchart with no authorization branch is correct only if
you have affirmatively established the operation is public; if so, say so.

Settle the flowchart before moving on.

## Step 2 — Class diagram + sequence diagram (the structure)

Once the flowchart is settled, produce the class diagram and the sequence
diagram together, as one step — structure and its bridge.

The **5-bucket architecture MUST govern both** structure and control flow (see
your architecture doctrine — Framework, UI Components, Side Effects, Domain,
Managers, and the dependency rules between them):

- Label every class-diagram box with its bucket.
- Check every sequence-diagram arrow against the dependency rules. If an arrow
  violates a rule, **restructure the design** — do not annotate the violation
  and move on.

The sequence diagram must show exactly where the **authorization check**
happens, which participant performs it, and what it calls in the existing
access-control system. The check belongs on the path every caller takes, not in
a UI component that merely hides a button. Verify no arrow reaches data or an
operation before the check guarding it.

## What the design must pin down

- Exact file paths, module names, function names, and data structures.
- The **bucket** for every module.
- The **authorization check** guarding every operation the design exposes.
- Error handling and edge cases, not just the happy path.
- Assumptions, documented explicitly — and where something is genuinely
  underdetermined by the domain model, flag it to ask rather than invent.

With the design settled, hand off to **athena:test-specification** to enumerate
the tests that prove it.
