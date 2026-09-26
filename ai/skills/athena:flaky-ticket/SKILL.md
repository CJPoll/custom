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

## Filing mechanics (for whoever files the ticket — usually the captain)

First resolve THIS repo's flaky-lane target from
`<repo-root>/.claude/flaky-lane.json` — a JSON object with `connector` (the
Notion MCP connector to use), `database_id`, `label`, and `queued_status`. Do
NOT hardcode a database id: the flaky lane is a per-repo automation, and a
captain in a different repo must never file into another repo's tracker. **If
that file is absent, this repo has no flaky lane:** do not file anywhere —
record the surviving flake (module, symptom, run reference, suspected
mechanism) in your report and move on. When it is present, create a page in
its `database_id` via its `connector`, with:

- **Title**: `Flaky: <module> — <symptom>` (include the failure string, the
  run reference, and the suspected mechanism in the description).
- **Labels** (multi_select): add the config's `label` (e.g. `flaky-tests`) —
  this is what makes the flaky lane's dispatch poll see it.
- **Status**: the config's `queued_status` (e.g. `Todo`) — the queued state
  the lane drains from.
- **Assignee** (people): the **human OWNER of this machine's harness**,
  resolved dynamically — never hardcode a person:
  1. Read your agent identity, first hit wins: `$AGENT_MESSAGES_IDENTITY`,
     then `~/.claude/agent-messages-identity`, then
     `<repo-root>/.claude/agent-messages/identity`.
  2. Map identity → owner in `<repo-root>/.claude/agent-messages/roster.json`
     (repo root after MR !739): use that agent's `notion_person_id` as the
     Assignee. (On this machine identity resolves to `Athena` → owner
     `Cody Poll` → `358d872b-594c-8171-abad-0002238e7b12`.)

Name the created ticket id in your report either way.

**Never merge past a flake by re-running until green and moving on:** an
unticketed flake is a lost finding, and a masked one is worse than a visible one.
The one non-fix disposition is "genuinely unfixable in code we control" (a true
external-vendor issue with no race on our side), reached only after root-causing
and recorded with that analysis — never "add a retry".

---

*Source (behavior-preserving relocation): athena-admiral "Every flaky test
becomes a worked ticket" (owner rule, 2026-09-04). The admiral keeps a resident
one-line trigger pointing here.*
