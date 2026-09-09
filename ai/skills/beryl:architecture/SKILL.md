---
name: beryl:architecture
description: Define architecture mermaid diagrams organized into the 5 buckets — framework, UI components, side effects (adapters/repositories), domain, and managers (orchestration).
argument-hint: <feature context>
disable-model-invocation: true
---

# Architecture

IMPORTANT: Before proceeding, check if there is a project-specific skill for feature architecture in the available Skill tool list. If a skill matching "*feature*architecture*" exists, invoke it using the Skill tool instead of proceeding manually. These skills contain project-specific patterns and best practices.

Let's define any mermaid diagrams that would be useful for implementation or communication of that implementation to other engineers in this feature's `architecture.md`, the path to which is in context.

The system SHOULD be organized into 5 different "buckets", each represented by
distinct classes/modules in the implementation:

- **Framework** — controllers, middleware, routers, and other framework-specific
  code (e.g. Phoenix controllers, plugs, LiveView lifecycle). These are the entry
  points from the outside world.
- **UI Components** — view/presentation code. HTML/CSS/JS for web applications, or
  GTK/other UI-framework code. Renders domain objects and performs simple view
  logic.
- **Side Effects** — ports/adapters, following Hexagonal Architecture. All
  interaction with the outside world lives here: databases, filesystem, email,
  HTTP calls, other OTP processes. Side Effects come in two flavors — adapters and
  repositories — described below.
- **Domain** — side-effect-free business logic. Testability (e.g. unit testing) is
  a first-class concern in designing these classes, methods, and interfaces. No
  I/O.
- **Managers (Orchestration)** — coordinate control flow between Side Effects and
  Domain, corresponding to Service Objects in Hexagonal Architecture or Use Cases
  in Clean Architecture. They generally return domain objects.

## Side Effects: adapters vs. repositories

Both are side effects, but the distinction drives how they are tested:

- **Adapters** wrap external, nondeterministic, or out-of-process effects — email,
  HTTP APIs, filesystem, message queues, cross-OTP-process calls, and
  cross-subdomain calls to another subdomain's public API (manager). Adapters are
  defined behind a behaviour/interface and **ARE mocked in tests** (e.g. Mox), so
  domain and manager tests stay fast and deterministic.
- **Repositories** are a specialized side effect for **database operations**. Each
  repository function is a single, focused database operation (one read or write)
  and contains no business logic. Repositories are **NOT mocked in tests** — they
  run against a real (test) database (e.g. the Ecto SQL sandbox), so their own
  tests and any test that exercises them prove the actual queries behave.

Rule of thumb: if the effect talks to *our* database, it's a **repository** (real
in tests); if it talks to anything else, it's an **adapter** (mocked in tests).

## Allowed dependency directions (for the dependency diagram)

- **Framework** → Managers; → UI Components (to render views); → Domain objects
  (for simple response logic only). Framework MUST NOT call Side Effects directly.
- **UI Components** → other UI Components; → Domain objects (to render them or for
  simple view logic, e.g. `if user.authorized?(action), do: render(...)`, where
  that domain object was retrieved by a Manager). UI Components MUST NOT call
  Managers or Side Effects. UI actions (button clicks, form submissions) bind to
  Framework handlers.
- **Managers** → Side Effects and Domain. Managers are the only bucket that drives
  Side Effects.
- **Side Effects** receive domain objects and return domain objects. A Side Effect
  MUST NOT call a Manager *within the same subdomain*. (Cross-subdomain is the
  exception: a subdomain uses a cross-subdomain **adapter** that calls the other
  subdomain's manager — this is allowed and correct.) Crossing an OTP process
  boundary is itself a side effect and requires an adapter.
- **Domain** is pure: it MUST NOT call Side Effects, Managers, UI Components, or
  Framework.

## Deliverable

The document SHOULD include a section mapping each class to its appropriate
bucket, with a justification for why — and for each Side Effect, whether it is an
**adapter** (mocked in tests) or a **repository** (real database, not mocked).
Ideally there is also a mermaid diagram indicating the dependencies between each
class and layer, with arrows respecting the allowed dependency directions above.

$ARGUMENTS
