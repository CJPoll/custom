---
name: athena:system-spec
description: JSON Schema encoding of the SpecMaker domain-model DSL (spec_maker/lib/spec_maker/domain_model.ex). Use when authoring, validating, or generating a system/domain spec as JSON instead of the Elixir DSL — a Spec describing a target codebase's architecture, modules, functions, data entities, authz/tenancy, rules, use cases, CQRS message flow, and tests.
---

# athena:system-spec

`schemas/` is a self-contained JSON Schema (Draft 2020-12) for authoring and
validating a system/domain model as JSON. **Authoring a model has no external
dependency** — everything you need is this skill's `schemas/` and `examples/`.

> **Provenance (origin only, not a live dependency).** The ontology these
> schemas encode was originally derived from the Elixir DSL at
> `spec_maker/lib/spec_maker/domain_model.ex` in the `gen_saas` project. That is
> a note on where the vocabulary came from — nothing about authoring or
> validating a model reads, requires, or touches `gen_saas`. Do **not** go read
> that file to author a model; read these schemas and `examples/`.

Validate a single-system document against **`schemas/spec.schema.json`**. A
worked example lives in `examples/demo.spec.json`. A multi-layer model
(subsystems/supersystems) adds a **`schemas/composition.schema.json`** manifest —
see *Multi-layer models* below.

## Where the model lives

The model is a project artifact, authored **in the target project's own
`ai-artifacts/` tree** (not this repo, and not inside any per-Mission worktree —
commit it to the project's main checkout so every worktree can read it):

- **Per-system spec** → `ai-artifacts/domain/<app>/<app>.spec.json` (one
  directory per target app; split by subdomain/aggregate into several
  `*.spec.json` files there if a single system is large).
- **Supersystem manifest** (multi-layer only) →
  `ai-artifacts/domain/<composition>.composition.json`, at the `domain/` root
  above the per-app directories.

This is the same path `athena:domain-grounding` and `athena:analyze-code` read
from, so authoring and grounding meet at one convention.

## The encoding

A SpecMaker `Spec` is the DSL's only RBAC root — every other entity carries
`belongs_to(:spec)`. So **the whole JSON document is one Spec**:

- The Spec's own fields (`name`, `description`, `status`, `target_app`,
  `target_repo_path`) sit at the **root** of the document.
- Every other entity lives in a **top-level collection** keyed by its plural
  (`modules`, `functions`, `entities`, `capabilities`, `command_dispatches`,
  …). The model is flat and relational, mirroring the Ecto tables the DSL
  compiles to, rather than deeply nested.
- Each entity object carries a document-unique **`id`** (author-assigned).
- Each DSL `belongs_to(:assoc, …)` becomes an **`assoc_id`** string that
  references another object's `id` (a foreign key). Example: a `Function`'s
  `belongs_to(:module)` is `"module_id": "<some module's id>"`.
- Each DSL `has_many` is just the inverse of those references and is **not**
  stored separately.
- The implicit `belongs_to(:spec)` on every entity is **omitted** — the
  document itself is the spec.

### Faithful-translation rules

- `field(:x, :string \| :integer \| :boolean)` → `"x": {type: string \| integer \| boolean}`.
- `field(:x, {:array, :string})` → array of strings.
- `required: true` on a field or `belongs_to` → the property is in `required`.
- `default: v` → carried through as JSON Schema `default: v` (documentation
  only; validators do not inject it).
- Free-string fields the DSL leaves unconstrained (`kind`, `style`, `strategy`,
  `visibility`, `purity`, …) stay `type: string`; the schema only adds
  `description` hints with common values — it does **not** invent enums, to
  match the DSL's permissiveness.
- Where the DSL comments say a row "belongs to X or Y — exactly one of the
  two" (`Parameter`, `ReturnValue`, `MessageField`, `EventSubscription`'s
  handler/process-manager), that intent is enforced with `oneOf` on the two
  reference properties.
- `additionalProperties: false` everywhere — unknown keys are rejected.

### Deliberately excluded

The `default_role`/`defrole`/`permissions` declarations on `Spec` are
SpecMaker's *own* access control over spec records (owner/editor/viewer). They
are platform machinery, not content describing a target system, and are fully
derivable boilerplate — so they are not part of this instance schema.

### Not enforceable by JSON Schema

`id` uniqueness within a collection and referential integrity of `*_id` fields
(that each points at an existing `id`) are **conventions**; JSON Schema cannot
express cross-array foreign keys. A generator/importer must check these
separately.

## Multi-layer models (subsystems / supersystems)

A `Spec` describes **one** system (one codebase) and is the DSL's only RBAC root —
every entity `belongs_to(:spec)`. So a single system is exactly one `*.spec.json`
document, and **a single-system model needs nothing else** — author one Spec and
stop (the whole single-system path is unchanged by the multi-layer support).

A **multi-layer** model composes systems *by reference*, never by cramming
several systems into one document (which would break the one-RBAC-root
invariant). A supersystem is a separate, tiny **composition manifest**
(`composition.schema.json`, a `*.composition.json` document) that:

- names each member system and points at its document by **relative path** —
  `spec_path` for a leaf system (a `*.spec.json`), or `composition_path` for a
  nested composition (another `*.composition.json`). Exactly one of the two per
  member (`oneOf`). `composition_path` is what lets a model nest to N layers
  (supersystem → subsystem → sub-subsystem) with no schema change.
- optionally records **`system_relationships`** — supersystem-level edges
  between members (e.g. `calls_public_api`, `publishes_event_to`,
  `shares_database_with`) that no single member's Spec can express.

Each member system stays a standalone, independently valid `*.spec.json`, so the
single-system authoring path and `examples/demo.spec.json` are untouched. Worked
multi-layer example: `examples/platform.composition.json` composing
`examples/identity.spec.json` and `examples/billing.spec.json`.

As with `*_id` references inside a Spec, a composition's referential integrity
(each `*_path` resolves to an existing document, member `id`s are unique, and
each relationship endpoint names a member `id`) is a **convention** JSON Schema
cannot express — a generator/importer checks it separately.

## File layout

```
schemas/
  spec.schema.json          root of ONE system — Spec fields + every collection
  composition.schema.json   multi-layer manifest — SystemComposition,
                            MemberSystem, SystemRelationship (references specs
                            and nested compositions by path)
  common.schema.json        shared Id / Ref primitives
  specs.schema.json         Bucket, Subdomain (a Spec's architectural vocabulary,
                            within one spec — not about multiple specs)
  structure.schema.json     Module, Function, Parameter, ReturnValue,
                            Contract, Callback, Implementation
  data.schema.json          Entity, Field, EntityRelationship
  authz.schema.json         AuthzModel, Capability, AuthzRole, RoleCapability,
                            ScopeHierarchy, RoleAssignmentRule,
                            ResourceAssignmentKind, PermissionDelegation
  tenancy.schema.json       TenancyModel, DataPlane, OwnershipRule
  rules.schema.json         Constraint, BoundaryCondition
  behavior.schema.json      UseCase, Step
  cqrs.schema.json          CommandedAggregate, Command, DomainEvent,
                            MessageField, CommandEmission, EventHandler,
                            EventSubscription, Projection, ProcessManager,
                            CommandDispatch
  verification.schema.json  TestCase
```

The files cross-reference by `$id` (base `https://athena.dev/spec-maker/`),
so a validator must load **all** of `schemas/` into one registry, not just
`spec.schema.json`.

## Validating

Any Draft 2020-12 validator works once every file in `schemas/` is registered.
Example with Python `jsonschema` + `referencing`:

```python
import glob, json, os
from jsonschema import Draft202012Validator
from referencing import Registry, Resource

d = "schemas"
docs = [json.load(open(p)) for p in glob.glob(os.path.join(d, "*.json"))]
reg = Registry().with_resources(
    (doc["$id"], Resource.from_contents(doc)) for doc in docs
)
spec_root = json.load(open(os.path.join(d, "spec.schema.json")))
Draft202012Validator(spec_root, registry=reg).validate(json.load(open("examples/demo.spec.json")))

# A multi-layer manifest validates against composition.schema.json (same registry):
comp_root = json.load(open(os.path.join(d, "composition.schema.json")))
Draft202012Validator(comp_root, registry=reg).validate(json.load(open("examples/platform.composition.json")))
```

A composition only structurally validates the manifest itself; validate each
member `*.spec.json` (resolved from its `spec_path`) as a Spec too, and check the
referential-integrity conventions above.
