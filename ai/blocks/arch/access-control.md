## Access Control

Mission critical. Getting authorization wrong is not a bug, it's a breach — a
missing check fails the work regardless of its other merits.

Every protected operation resolves these explicitly:

1. **Who** may perform it — which roles, permissions, scopes, or relationships
   grant it.
2. **What** is protected — the specific resource and the tenant/org boundary it
   sits inside.
3. **Where** the check happens — the exact module and function, on the path
   every caller takes.
4. **How** it integrates — the existing access-control modules it calls and the
   calling convention it follows.
5. **What happens on denial** — the error returned, and whether it
   distinguishes "forbidden" from "not found" (leaking existence is itself a
   disclosure).

Rules:

- **Integrate, never reinvent.** If an access-control system exists, use it. No
  second mechanism, bypass, "temporary" flag, or inline reimplementation. If
  the existing system genuinely can't express what's needed, raise that as a
  finding, not a gap to route around.
- **Deny by default.** Anything not explicitly permitted is denied. Never a
  permissive fallback for the unmatched case.
- **Enforce server-side.** Hiding a control in the UI is not access control;
  it's a usability affordance layered on enforcement that already exists behind
  it.
- **Scope every query.** Reads are access-controlled too. Every data fetch is
  tenant/org scoped; an unscoped query is a cross-tenant leak waiting for a
  caller.
- **Follow the buckets.** Authorization decisions are business rules and belong
  in Domain; fetching the data those decisions need is a Side Effect; Managers
  orchestrate the two; Framework rejects the request on denial.
- **Authorization needs negative tests.** For every protected operation: an
  authorized subject succeeds, an unauthorized subject is denied, and a subject
  from another tenant/org cannot reach the resource at all.
