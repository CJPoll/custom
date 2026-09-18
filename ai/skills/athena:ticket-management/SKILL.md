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
3. **→ `Needs Attention`** — set `Assignee` = **Cody**, write the decision/context
   Cody needs onto the ticket body (that is the whole point of the status), and
   **DM Cody** as Athena that the ticket needs him (see the Notes "Needs Attention
   DM" rule). This is one of the three owner-notification events; it fires on the
   transition itself and applies to ANY ticket, epic or not.
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

## Design sub-docs (the architect's deliverables live in Notion)

A fleet's design artifacts are **Notion sub-pages, not local files**. The
athena-architect creates three under the **epic** page and three under **each
ticket** page:

- **Product Requirements** — what the work must satisfy.
- **Architecture & Engineering** — domain grounding, the feature-model diagrams,
  the 5-bucket structure, and access control.
- **QA Plan** — the functional test specification (`athena:format:test-matrix`).

The epic-wide trio is the whole-scope context every ticket shares; the
per-ticket trio is that one ticket's design. A captain reads BOTH its ticket's
three sub-docs AND the epic's three.

Mechanics (raw Notion API via the connection's tools):

- **Create a sub-page** with `API-post-page`, `parent` = `{"page_id": "<epic or
  ticket page id>"}`, title set to the sub-doc name — this nests it under the
  epic/ticket page.
- **Write its body** with `API-update-page-markdown` (whole-page markdown) or
  `API-patch-block-children` (append blocks); **read** it back with
  `API-retrieve-page-markdown` or `API-get-block-children`.
- **Find them** by listing the parent page's children (`API-get-block-children`
  on the epic/ticket page id) and matching titles; reuse an existing sub-page
  rather than creating a duplicate.

Local markdown (a `ai-artifacts/specs/…` or `…/feedback/…` file) is NOT a source
of truth — at most an agent's ephemeral scratch. The Notion sub-docs are
authoritative.

## Notes

- The Epics DB holds one epic per athena-admiral scope; the architect creates the
  epic and its design sub-docs, and tickets link to it via the `Epic` relation
  and carry `Depends On`↔`Blocks` edges for sequencing.
- Put the *why* on the ticket, not just in chat — a `Needs Attention` ticket must carry
  the context Cody needs to decide, in its body.
- **Needs Attention DM to Cody (owner rule).** When a ticket moves to `Needs Attention`,
  DM Cody as Athena via the `athena:slack` skill (`~/.claude/skills/athena:slack/bin/dm`,
  Cody = `U0AHNV4RJGP`) on that same transition — the one that already assigns Cody and
  writes the context onto the ticket body, so the DM rides on it. Applies to ANY ticket,
  epic or not. Slack-mrkdwn format (`<url|label>`, NOT markdown; `:notion:` + the ticket
  PAGE url):
  `:warning: :notion: <TICKET_URL|PT-NNN - Ticket Name> needs your attention — <one-line why>.`
  where `<one-line why>` is the same reason you wrote onto the ticket body. This is one of
  the three owner-notification events; the other two — an epic crossing 50% and an epic
  reaching 100% — are the **athena-admiral**'s, computed at merge time (see that agent
  def's "Epic-progress DM to the owner"). Athena no longer DMs on every merge.
