---
name: athena:ticket-management
description: The status ↔ assignee lifecycle for Notion tickets (Epics/Tickets DBs, DND-/PT-style IDs). Use whenever an orchestrator/athena-admiral takes scope of a ticket, or any status transition happens (In Progress / Needs Attention / Attention Given / Done / Ready for Release / Cancelled). Defines who the ticket is assigned to at each status and how to resolve the Athena and Cody accounts for the ACTIVE Notion connection (notion-personal vs notion-work).
---

# athena:ticket-management

The one rule to keep in your head: **the `Assignee` always names whoever currently
holds the ticket.** Athena holds it while it is actively being worked; Cody holds it
whenever it is waiting on him. Every status transition therefore also moves the
`Assignee` — never change status without reconciling the assignee.

Tickets are referenced by their `ID` (a `unique_id` property, e.g. `DND-29`, `PT-895`).
Always refer to a ticket as `<PREFIX>-<number>`, never by raw page id.

## Status → Assignee map

| Status | Assignee | Meaning |
|---|---|---|
| `Backlog` | leave as-is until scoped | not yet in an athena-admiral's scope; on scope-in, normalize to `Todo` |
| `Todo` | **Athena** once in scope | in an athena-admiral's scope, queued; no engineer on it yet |
| `In Progress` | **Athena** | an athena-captain has been dispatched and is actively working it |
| `Needs Attention` | **Cody** | blocked on Cody's input/decision — put the context he needs in the ticket body |
| `Attention Given` | **Cody** | Cody has answered; awaiting the owning athena-admiral to pick it back up (stays Cody until reopened) |
| `Done` | **Cody** | Cody's to review / verify / close |
| `Ready for Release` | **Cody** | work workspace only — a mobile ticket that has cleared dev but not yet the app-store process |
| `Cancelled` | leave as-is | dropped |

## The transitions an orchestrator performs

1. **Taking scope** — when an orchestrator is handed a ticket or a set of tickets, it
   takes ownership: set each ticket's `Assignee` = **Athena**, and if the ticket is in
   `Backlog`, move it to `Todo`. A scoped ticket that no engineer is on yet sits at
   `Todo` (or keeps `In Progress` if it was already there).
2. **Assigning an engineer** — when an athena-captain is dispatched to the ticket, move
   the status to `In Progress`; the assignee stays **Athena**.
3. **→ `Needs Attention`** — set `Assignee` = **Cody**, and write the decision/context
   Cody needs onto the ticket body (that is the whole point of the status).
4. **→ `Done`** — set `Assignee` = **Cody**.
5. **→ `Ready for Release`** (work workspace only) — set `Assignee` = **Cody**.
6. **`Attention Given` → `In Progress`** — a ticket in `Attention Given` is still
   assigned to **Cody** (search for tickets Cody has answered by that status). Once the
   athena-admiral resumes it and moves it back to `In Progress`, **reassign to Athena**.

A scoped ticket is Athena's from the moment it enters scope (`Backlog`→`Todo`→
`In Progress` are all Athena). It flips to **Cody** only when it moves to a
waiting-on-Cody state (`Needs Attention`, `Attention Given`, `Done`,
`Ready for Release`).

## Resolving the two accounts (per active connection)

Match the **active Notion connection** — use the `notion-personal` tools in the personal
workspace and `notion-work` in the work workspace. Never cross connections, and never
hardcode an account across workspaces; resolve it for the connection you are on.

**Athena** = the bot service account of the active connection. Resolve it live with the
connection's "get self" call (raw API: `API-get-self`) and use the returned `id`. Bots
**can** be set as a `people` value (verified).

**Cody** = the human owner of that workspace. Resolve dynamically; fall back to the known
ids below only for the connection you are actually on. If unknown, find the non-bot
person via `API-get-users`, or read a ticket's `created_by`.

| Connection | Workspace | Athena (bot) id | Cody (person) id |
|---|---|---|---|
| `notion-personal` | "Cody" | `a22b6502-92b2-4b22-978d-9a49895afc1b` | `a6557c85-7931-480b-9e68-7f7fb2d889a7` |
| `notion-work` | work | resolve via `API-get-self` | `358d872b-594c-8171-abad-0002238e7b12` (Cody Poll) |

The `notion-work` Cody id also lives in `<repo-root>/.claude/agent-messages/roster.json`
as `notion_person_id`; the flaky-lane tooling already resolves it that way.

## Mechanics (raw Notion API via the connection's tools)

- **Status is a `status`-type property.** Set it as
  `{"Status": {"status": {"name": "Done"}}}`. A `{"select": ...}` value is rejected with
  `"Status is expected to be status."`
- **Assignee is a `people`-type property.** Set it as
  `{"Assignee": {"people": [{"id": "<user-id>"}]}}`. Clear it with `{"people": []}`.
- Update with `API-patch-page` (page id = the ticket). Query a DB with
  `API-query-data-source`; find the owning DB/data-source ids by searching the connection
  (`API-post-search`) — they differ per workspace.
- A 404 "make sure ... shared with your integration" means the DB/page is not shared with
  the Athena integration yet — it must be shared (Connections → add Athena) before you can
  read or write it.

## Notes

- The Epics DB holds one epic per athena-admiral scope; tickets link to it via the `Epic`
  relation, and carry `Depends On`↔`Blocks` edges for sequencing.
- Put the *why* on the ticket, not just in chat — a `Needs Attention` ticket must carry
  the context Cody needs to decide, in its body.
- **Ping Cody in Slack on every athena-admiral merge (owner rule).** Whenever an athena-admiral
  merges a ticket's MR — a merge it performed itself, never one it merely observed — DM
  Cody as Athena via the `athena:slack` skill (`~/.claude/skills/athena:slack/bin/dm`,
  Cody = `U0AHNV4RJGP`): one DM per merged MR, sent immediately after the merge. Use the
  Slack-mrkdwn format `(:gitlab: :merged:) :notion: <TICKET_URL|PT-NNN - Ticket Name> is
  Merged.` (append ` Deploying to Production` when the MR carried `Auto-Deploy`). The
  canonical rule + exact format lives in the **athena-admiral** agent def's "Merge
  notification DM to the owner" section — follow that; this bullet only ensures the
  ticket lifecycle records the obligation so it isn't missed.
