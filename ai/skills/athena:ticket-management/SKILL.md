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
4. **→ `Done`** — set `Assignee` = **Cody**. Only after the merge is CONFIRMED
   (`ai/bin/confirm-merged`) **and** the change is verified live where it runs.
   If only Cody can do the live check (his login, his machine), move the ticket
   to `Needs Attention` instead, with the exact check on the body.
5. **→ `Ready for Release`** (work workspace only) — set `Assignee` = **Cody**.
6. **`Attention Given` → `In Progress`** — a ticket in `Attention Given` is still
   assigned to **Cody** (search for tickets Cody has answered by that status). Once the
   athena-admiral resumes it and moves it back to `In Progress`, **reassign to Athena**.

A scoped ticket is Athena's from the moment it enters scope (`Backlog`→`Todo`→
`In Progress` are all Athena). It flips to **Cody** only when it moves to a
waiting-on-Cody state (`Needs Attention`, `Attention Given`, `Done`,
`Ready for Release`).

## Keep tickets, epics and projects current (owner rule)

Owner, Cody, 2026-09-26: "Yes, please keep projects, epics, and tickets up to
date." The owner reads Notion to see what is happening. A stale status misleads
him and raises nothing, so drift is a defect.

- **Tickets** follow the transitions above at the moment they happen. Moving a
  ticket to `In Progress` is part of dispatching its captain.
- **Epics.** Set `In Progress` when the first ticket starts. Set `Done` only
  when every linked ticket, follow-ups included, is `Done` or `Cancelled`. A
  follow-up filed under a `Done` epic moves the epic back to `In Progress`.
  On the DND Epics DB, `Status` is a `select`, not a `status`:
  `{"Status": {"select": {"name": "In Progress"}}}`.
- **Projects** move with their epics.
- **Sweep the epic** against its tickets at each epic transition and when you
  resume. Before you trust an empty filter result, confirm the filter with a
  query that should match something.
- **Warn before a burst.** Each edit notifies Cody. Before changing more than
  about 5 tickets at once, tell him a burst is coming and roughly how many.

Measured 2026-09-26: five epics disagreed with reality. Three read `Todo` while
being worked, one read `Done` while its follow-ups were built, one read
`In Progress` with every ticket `Done`. A 45-ticket sweep then surprised the
owner with a couple dozen notifications.

## When the tracker lacks a status this skill names

**The option set is per-tracker, and the statuses above are not guaranteed to
exist in the one you are on.** The personal DND tracker has no `In Review` and no
`Ready for Release`; the walt_ui work tracker has both. So the status you are
about to set is a *lookup*, and it can miss.

**Resolve the options before you set a status** — read the `Status` property's
option list off the data source (`API-retrieve-a-data-source`) rather than
assuming this skill's vocabulary. Do it once when you take scope, and record the
available set in the run's state log so every captain dispatched into that
tracker inherits it instead of rediscovering it.

When the status you would set does not exist:

1. **Never invent one.** Do not create an option and do not substitute a
   differently-meaning status (a captain's finished-but-unmerged work is not
   `Done`). Notion rejects an unknown option, but a *plausible wrong* one is
   accepted silently, which is worse.
2. **Hold at the nearest earlier status that does exist, and make the hold
   explicit.** On a tracker with no `In Review`: a captain finishing its work
   sets **no** status and leaves the ticket at `In Progress`; the **athena-admiral**
   makes the terminal move (`Done`) on confirmed merge. The captain says so in
   its report — "left at `In Progress`, no `In Review` on this tracker, terminal
   move is the admiral's" — so the holder is stated rather than inferred from
   silence.
3. **The assignee rule still binds.** `Assignee` always names whoever holds the
   ticket, even when the status cannot move to say so. If work is genuinely
   waiting on Cody and there is no status that expresses it, set `Assignee` =
   **Cody** and write the reason on the body — the assignee is the load-bearing
   signal, the status is the label.
4. **A missing option is a fact to report, never a silent skip.** A rejected
   status write, or an option list that comes back empty, is an error: surface it
   (report + state log) naming the tracker and the option you looked for. "I set
   no status" and "this tracker has no such status" must never read the same —
   per `~/.claude/CLAUDE.md` → *A failed lookup must never look like an empty
   one*.

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
- **`API-create-a-comment` does not work — do not spend a call on it.** On every
  connection (`notion-personal`, `notion-work`, `notion-athena`) it returns
  `400 missing_version`: *"Notion-Version header failed validation: ... instead was
  `undefined`"*. The MCP server omits the header, so this is not something a caller
  can pass around — it fails before the request reaches your page id, so a well-formed
  call and a bogus one fail identically. **Property writes are unaffected**:
  `API-patch-page` (status, assignee) works fine; only the comment endpoint is
  broken. **`API-post-page` truncates a large input** (measured 2026-09-22: it
  silently cuts inputs around ~2,000 bytes → a JSON parse error), so a
  normal-length ticket/sub-page BODY cannot be created through it in one call —
  it is fine for the page's properties (title, relations) and a short body only.
  For a full-length body, create the page with its properties via `API-post-page`
  then write the body in chunks with `API-patch-block-children`; or fall back to
  `curl` with the connection's token and a `Notion-Version: 2022-06-28` header
  (the same fallback the comment endpoint needs). **Instead** of a comment, put
  the note where it will actually be read: append
  it to the ticket page body (`API-patch-block-children`), or record it in the MR/PR
  description and your report. Say in the report that the comment endpoint was
  unavailable, so the absence of a comment is never read as an absence of the note.
  [measured 2026-09-20; recurring since at least 2026-09-12 — PT-789, dnd-140,
  PT-1080, DND-219 each rediscovered it]

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
