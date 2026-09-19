---
name: athena:flaky-ticket
description: The owner rule that every flaky test in the athena-admiral's lane becomes a worked ticket, fixed at its root cause and NEVER masked with a retry, allow_failure, `@tag :skip`, or a loosened tolerance. Use whenever a captain reports a flake or you see a test fail-then-pass in a merge-train/CI pipeline you own — before boarding the MR.
---

# athena:flaky-ticket

A flake is a defect (a race, an order dependency, a shared-resource collision, an
unpinned clock/window, a load-dependent timeout) and it is fixed **at its root
cause** — NEVER dispositioned with a retry, `allow_failure`, `@tag :skip`, or a
loosened tolerance (root ADR 002 / backend ADR 018). Masking a flake is exactly
the "weaken a safety check" the safety rules forbid: the suite's whole value is
its signal.

For every flake that touches your lane — a captain reported one, or you saw a
test fail-then-pass in a merge-train / CI pipeline you own — you guarantee two
things:

1. **It gets a ticket.** Confirm the engineer filed `Flaky: <module> — <symptom>`
   (with the failure string, run reference, and suspected mechanism) and named
   the id in its report; if it did not, **file it yourself before boarding the
   MR**. If an existing Flaky ticket already names that mechanism, append the
   instance there rather than duplicating. A flake in a Mission's OWN new test is
   filed by **reopening that Mission (Back to Work)**, not a separate Flaky
   ticket.
2. **It gets worked.** A filed Flaky ticket is only worked if the standing
   flaky-test lane can see it: title starts `Flaky:`, status Backlog/Todo, and it
   carries the `flaky-tests` label (the flaky lane auto-stamps new `Flaky:`
   Missions; add the label yourself if you file one). Route it to that lane
   rather than letting it sit — a Backlog Flaky ticket nobody is assigned is an
   unworked flake, which is exactly what this rule exists to prevent.

**Never merge past a flake by re-running until green and moving on:** an
unticketed flake is a lost finding, and a masked one is worse than a visible one.
The one non-fix disposition is "genuinely unfixable in code we control" (a true
external-vendor issue with no race on our side), reached only after root-causing
and recorded with that analysis — never "add a retry".

---

*Source (behavior-preserving relocation): athena-admiral "Every flaky test
becomes a worked ticket" (owner rule, 2026-09-04). The admiral keeps a resident
one-line trigger pointing here.*
