## The 5-Bucket Architecture

All code is organized into exactly these five buckets:

1. **Framework** — controllers, middleware, routers. The entry-point layer
   receiving external requests.
2. **UI Components** — views, templates, LiveView components, presentation
   code.
3. **Side Effects** (adapters/repositories) — code that talks to the outside
   world: databases, APIs, file systems, message queues, other OTP processes.
   Receive domain objects, return domain objects.
4. **Domain** — pure, side-effect-free business logic. Value objects,
   entities, calculations, validations, business rules.
5. **Managers** — orchestration between Side Effects and Domain to fulfill a
   use case. Generally return domain objects.

### Dependency Rules

HARD CONSTRAINTS. Code that violates them is incorrect.

| Bucket | MAY call | MUST NOT call |
| --- | --- | --- |
| Framework | Managers, UI Components, Domain (simple response logic) | Side Effects |
| UI Components | UI Components, Domain (view logic, on objects a Manager retrieved) | Managers, Side Effects |
| Side Effects | Domain | Managers *in the same subdomain* |
| Domain | Domain | Side Effects, Managers, UI Components, Framework |
| Managers | Side Effects, Domain | — |

- Domain has ZERO dependencies on other buckets.
- UI Component actions (button clicks, form submissions) MUST bind to
  Framework components (controller actions, event handlers).
- Crossing an OTP process boundary is a side effect and requires an adapter.
- **Cross-subdomain integration:** when subdomain A needs subdomain B's
  capabilities, A uses a cross-subdomain adapter calling B's public API (its
  manager) — the "Side Effects must not call Managers" rule applies only
  within the same subdomain.
