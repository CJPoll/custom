---
name: athena:system-spec
description: JSON Schema encoding of the SpecMaker domain-model DSL (spec_maker/lib/spec_maker/domain_model.ex). Use when authoring, validating, or generating a system/domain spec as JSON instead of the Elixir DSL — a Spec describing a target codebase's architecture, modules, functions, data entities, authz/tenancy, rules, use cases, CQRS message flow, and tests.
---

# athena:system-spec

`schemas/` is a JSON Schema (Draft 2020-12) that encodes the SpecMaker ontology
defined by the Elixir DSL in
`~/dev/gen_saas/apps/spec_maker/lib/spec_maker/domain_model.ex`. It lets a spec
be authored and validated as a single JSON document instead of Elixir.

Validate the root document against **`schemas/spec.schema.json`**. A worked
example lives in `examples/demo.spec.json`.

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

## File layout

```
schemas/
  spec.schema.json          root — Spec fields + every top-level collection
  common.schema.json        shared Id / Ref primitives
  specs.schema.json         Bucket, Subdomain
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
root = json.load(open(os.path.join(d, "spec.schema.json")))
Draft202012Validator(root, registry=reg).validate(json.load(open("examples/demo.spec.json")))
```
