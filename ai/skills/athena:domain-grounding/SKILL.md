---
name: athena:domain-grounding
description: Ground yourself in a project's domain model before designing, analyzing, or implementing — read its athena:system-spec model (the JSON-encoded domain: entities, relationships, constraints, authz, tenancy), its ADRs, and reconcile against the knowledge graph. Use at the start of feature modeling, architecture analysis, or implementation whenever you need the canonical domain facts and the access-control model rather than your own reading of the tickets.
---

# athena:domain-grounding

Before you design, analyze, or implement, load the **canonical domain model**
and let it — not your reading of the tickets — be the source of truth. When a
ticket and the model disagree, the model wins; record the conflict rather than
silently following one.

The domain model is encoded with **athena:system-spec** — a JSON document (or a
set of them) validating against that skill's `spec.schema.json`. Read the
`athena:system-spec` SKILL first if you are not already fluent in the encoding,
so you know what each collection means.

## 1. Locate the model

- Look for the project's spec document(s): `*.spec.json` files, typically under
  `ai-artifacts/domain/<app>/` (this is where athena:system-spec models are
  saved). There may be one file or several, split by subdomain/aggregate.
- **If it is a multi-layer model**, a `*.composition.json` manifest sits at the
  `ai-artifacts/domain/` root and references each member system's spec by path.
  Read the manifest first to see the whole system's shape, then read the member
  `*.spec.json` your task touches (and its `system_relationships` for how the
  members wire together).
- **If a model exists**, it is your primary source. Read it in full.
- **If no model exists**, that absence is itself signal: note it. Fall back to
  the code's Ecto schemas, `seeds.exs`, and context modules to reconstruct the
  facts you need, and consider whether producing an athena:system-spec model is
  in scope for your task.

## 2. Extract the domain facts

From the model (or the fallback sources), pull out and write down what your
task actually touches:

- **Entities & fields** — the persisted shapes and their types.
- **Relationships** — `entity_relationships`, and the `*_id` references that
  wire entities together.
- **Invariants & constraints** — the `constraints` and `boundary_conditions`
  collections especially. These are the rules the system must uphold; every one
  your task touches becomes a thing you must not break (and, downstream,
  something to test).

## 3. Extract the access-control model — specifically

Authorization is not an afterthought; pull it out on its own:

- `authz_models` and their `style`; `capabilities`, `authz_roles`,
  `role_capabilities`.
- Scope and reach: `scope_hierarchies`, `role_assignment_rules`,
  `resource_assignment_kinds`, `permission_delegations`.
- Tenancy boundaries: `tenancy_models`, `data_planes`, `ownership_rules`.

Identify **which modules already enforce authorization and how callers invoke
them**. You integrate with that system — you do not design a parallel one.

## 4. Reconcile against other sources

- Read `./adrs/` if it exists — your work MUST comply, including the
  authorization ADRs.
- Query the **knowledge graph** for prior decisions, constraints, and gotchas
  in this area (see the `kg` skills). Nothing found is also signal.

## 5. Record what you found

Produce a short grounding note before moving on:

- Which parts of the model your task touches.
- Which constraints it must uphold.
- The access-control model it must integrate with.
- **Any conflict** between sources (ticket vs model vs ADR vs graph): state the
  conflict, which source you followed, and why.
