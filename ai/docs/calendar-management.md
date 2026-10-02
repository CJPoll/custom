# Calendar management (DND-1761)

**Kind: dated record.** Design of 2026-10-02. Later changes are annotated, not
rewritten (`CLAUDE.md` → *Documentation conventions*).

## The ask

Cody, Slack DM, 2026-10-02 ~15:50Z (DND-1761), verbatim:

> I'd like calendar management in general. I'd like for the MCP to
> create/update/reschedule/invite/uninvite/attach zoom. How this gets divided
> across tools should be decided by an architect (one tool, many tools, what
> boundaries, etc.). Also accept/maybe/reject an invite. I'd like to be able to
> rsvp in the priorities page, click on a zoom link if a zoom meeting is
> attached (might be in the body, in the meeting location, etc.); don't show
> google meet links.

Cody started it by a verified owner click, 2026-10-02 15:51Z.

## What exists

- **DND-447** (gen_saas PR #576, `b9e9b2e3`): the owner's primary Google
  calendar, OAuth scope `calendar.events`, connected 2026-10-02. Today's
  meetings are `meeting` index items with only `source_ref`, `url`, `title`
  and `starts_at` (`ai/contracts/athena-events.md` → *The storage
  boundary*). `Athena.Calendar.Event.from_google/1` drops the description,
  attendees, location and conference data at the adapter boundary. A page
  load is database reads only; nothing calls Google on a page load.
- **DND-1742** (laptop, promoted): Going / Maybe / Not going on
  `/priorities`, a `respond(owner_id, event_id, response)` adapter call, and
  the owner's own `responseStatus` stored on each meeting item.
- **The Attend relabel bug** (interim): Attend reads as an RSVP and writes
  nothing. DND-1742 replaces the button; the relabel only covers the gap.
- **DND-1743**: the prep tl;dr reads the description at digest time, never
  stored (OQ-5 reversed by the owner, 2026-10-02).
- **DND-1744** (custom PR #268, held at exit 4 for Cody's words) and
  **DND-1745** (parked): the `calendar.rsvp` grant class and Slack RSVP
  buttons.
- **The athena MCP** (gen_saas `Athena.MCP.Server`, Hermes): every call is
  authenticated by a machine token, and the owner is the machine's owner.
  A refusal is a tool error whose text starts with its code, then a sentence
  with its `Fix:`. Write tools read the raw arguments against a closed schema,
  so an undeclared key such as `owner_id` is refused by name
  (`Athena.MCP.Tools.LeaseReply`).

This design reuses all of it. RSVP on `/priorities` is DND-1742's, not built
twice; the MCP RSVP tool calls DND-1742's `respond`.

## 1. The tool surface

### The split, and why

Nine tools: two reads, six writes, one status read.

| Tool | Does | Reaches other people |
| --- | --- | --- |
| `calendar_events` | lists events in a window | never |
| `calendar_event` | one event, with its guest list | never |
| `calendar_create` | creates an event (title, times, location, description, guests, Zoom link) | when it has guests |
| `calendar_update` | changes title, location, or start and end (reschedule) | when the event has other guests |
| `calendar_invite` | adds guests | always |
| `calendar_uninvite` | removes guests | always |
| `calendar_attach_zoom` | puts a pasted Zoom link on an event | when the event has other guests |
| `calendar_rsvp` | the owner's own response: accepted, tentative, declined | the organizer, always |
| `calendar_change` | the state of a change waiting for approval | never |

The boundaries follow two questions: what the owner must approve, and whose
role the owner plays.

- **Reads apart from writes.** Claude Code permissions are per tool name, so a
  session can be allowed the reads and denied the writes.
- **Invite and uninvite are their own tools.** They always reach people, so
  their intent is explicit in the tool name and their refusals are exact
  (`not_a_guest`, `already_a_guest`).
- **Reschedule is `calendar_update` with `starts_at` and `ends_at`.** It is the
  same Google PATCH under the same rule. A separate tool would duplicate the
  arguments, the checks and the tests. The tool's description says
  "reschedule" so a session finds it.
- **RSVP is its own tool.** The owner acts as a guest there, never as the
  organizer, and its approval rule differs (*2. Reaching other people*).
- **Attach Zoom is its own tool.** It validates a Zoom URL and refuses
  anything else, Google Meet included.
- **Not one tool with an `op` argument.** An op union cannot keep a closed
  schema per operation, its refusals blur, and a permission rule cannot tell
  a read from an invite.
- **No `notify` or `sendUpdates` argument.** The server decides whether a call
  reaches anyone, from the event as Google holds it now. A caller cannot opt
  out of the approval by saying it will not notify. `sendUpdates=none` would
  not help anyway: the guests' copies still change.

Not built: deleting or cancelling an event, editing a whole recurring series,
editing a description after creation (*Arguments and return shapes* →
`calendar_update`), and
choosing a calendar other than the owner's primary one.

### Rules every tool shares

- **Caller.** A session on one of the owner's machines, through the machine
  token. The calendar is the machine owner's primary calendar, through
  DND-447's credentials (`Secrets.with_secret/4`, ADR 18). No argument names an
  owner or a calendar.
- **Write tools take `claude_session_id`**, which must be a fleet session bound
  to the frame machine, as the lease tools require. It attributes the change
  in the change log and the digest. An unknown session is `not_found`.
- **Closed schema on the raw arguments.** An unknown key is
  `invalid_argument` naming the key.
- **Event ids** are the ids `calendar_events` returns. For a recurring event
  that is one occurrence's id; a write changes that occurrence only. Before
  every write the server reads the event from the owner's primary calendar.
  An id not there is `not_found`.
- **Times** are RFC 3339 with an offset (`2026-10-05T15:00:00-06:00`). A time
  with no offset is `invalid_argument` naming the field. `ends_at` must be
  after `starts_at`, at most 24 hours later. All-day events are read but not
  created.
- **Organizer-only writes.** Update, invite, uninvite and attach Zoom need the
  owner to be the organizer (`organizer.self`). Otherwise `not_organizer`.
- **Guest-only RSVP.** `calendar_rsvp` needs the owner on the guest list and
  not the organizer. Otherwise `not_an_attendee`.
- **Never a Google Meet link.** No tool returns `hangoutLink` or
  `conferenceData`. No write requests a Meet conference, so Google adds none.
  The only meeting link any surface shows is `join_url`, a Zoom URL
  (*3. Zoom links* → *Extraction rules*).
- **Dormant until connected.** `not_configured`, `not_connected` and `revoked`
  carry DND-447's `Fix:` text (`Athena.Calendar.Refusal`).
- **Today stays current.** After a write is applied to an event that starts in
  the owner's local today, the manager runs `sync_today/2`, so `/priorities`
  shows it. A failed sync does not fail the write; the sync records its own
  outcome, as today.

### Arguments and return shapes

`EventSummary`:

```json
{"event_id": "abc123_20261005T210000Z", "title": "Weekly sync",
 "starts_at": "2026-10-05T15:00:00-06:00", "ends_at": "2026-10-05T15:30:00-06:00",
 "all_day": false, "html_link": "https://www.google.com/calendar/event?eid=...",
 "self_response": "accepted", "organizer_is_owner": true, "other_guests": 3,
 "recurring": true, "join_url": "https://us02web.zoom.us/j/81234567890?pwd=..."}
```

`self_response` is `accepted`, `tentative`, `declined`, `needsAction`, or
`null` when the owner is not on the guest list. `join_url` is `null` when no
Zoom link is found. Cancelled events are not listed.

**`calendar_events {from, to}`** → `{"window": {"from", "to"}, "count": n,
"events": [EventSummary]}`. Both bounds are required, and `to - from` is at
most 31 days. The window is echoed, so an empty list says which window found
nothing. More than 250 events is `too_many_events`.

**`calendar_event {event_id}`** → `EventSummary` plus `"location": string|null`,
`"guests_omitted": bool` and `"guests": [{"email", "response", "organizer",
"optional"}]`. The description is never returned (DND-1743's read stays the
only description read, and it is digest-only).

**`calendar_create {claude_session_id, title, starts_at, ends_at, location?,
description?, guests?, zoom_url?}`** → `{"result": "created", "event":
EventSummary}`, or `{"result": "pending_approval", "change": Change}` when
`guests` is not empty. `zoom_url` is checked as in `calendar_attach_zoom` and
written to `location`, so `location` and `zoom_url` together are
`invalid_argument`. The event's time zone is the owner's fleet-policy zone.

**`calendar_update {claude_session_id, event_id, title?, location?, starts_at?,
ends_at?}`** → `{"result": "updated", "event": EventSummary}` or
`pending_approval`. At least one field. `starts_at` and `ends_at` come
together. No `description`: a session cannot read the description, so it may
not overwrite it.

**`calendar_invite {claude_session_id, event_id, guests}`** and
**`calendar_uninvite {claude_session_id, event_id, guests}`** → always
`pending_approval`. `guests` holds 1 to 20 addresses, lowercased and
de-duplicated. A malformed address is `invalid_argument` naming it. Inviting
a current guest is `already_a_guest`; uninviting someone not on the list is
`not_a_guest`, each naming the address. The organizer cannot be uninvited.

**`calendar_attach_zoom {claude_session_id, event_id, zoom_url, replace?}`** →
`updated` or `pending_approval`. `zoom_url` must pass `ZoomLink.valid?/1`
(*3. Zoom links* → *Extraction rules*); anything else, a Meet link included,
is `not_a_zoom_link`. The
link goes in `location`: an empty location becomes the URL; a location without
a Zoom link becomes `<url> · <old location>`; a location that already holds a
Zoom link is `zoom_already_attached` unless `replace: true`, which swaps that
link only. The description is never touched.

**`calendar_rsvp {claude_session_id, event_id, response}`** → `{"result":
"responded", "event_id", "response"}`. `response` is `accepted`, `tentative`
or `declined`. It PATCHes only the owner's own attendee entry, with
`attendeesOmitted: true` and `sendUpdates=all`, exactly as DND-447's Skip
does.

**`calendar_change {change_id}`** → `Change`.

`Change`:

```json
{"change_id": "uuid", "kind": "invite", "event_id": "...", "title": "Weekly sync",
 "summary": "invite 2 guests to Weekly sync (Mon 15:00)", "reaches": 5,
 "state": "proposed", "approval_url": "https://<athena host>/calendar/changes/<id>?t=<token>",
 "expires_at": "2026-10-03T16:00:00Z"}
```

`approval_url` appears only in the answer to the write that proposed it, never
from `calendar_change`. `state` is `proposed`, `applying`, `applied`, `rejected`,
`expired`, `stale` or `failed`.

### Refusals

Each is a tool error, `<code>: <sentence> Fix: <step>`.

| Code | When | Fix |
| --- | --- | --- |
| `not_configured`, `not_connected`, `revoked` | no calendar access | DND-447's: store the client on /secrets, connect at /oauth/google/start |
| `invalid_argument` | unknown key, missing field, bad time, bad address, bad combination | names the field and the expected form |
| `not_found` | no such event on the owner's primary calendar, no such change for this owner, or an unknown session | call `calendar_events` for a current id; call from the session's own machine |
| `not_organizer` | update, invite, uninvite, attach Zoom on an event someone else organizes | ask the organizer, or RSVP with `calendar_rsvp` |
| `not_an_attendee` | RSVP on an event the owner organizes or is not invited to | use `calendar_update`, or nothing to answer |
| `already_a_guest`, `not_a_guest` | invite or uninvite does nothing for that address | drop the address named |
| `not_a_zoom_link` | `zoom_url` fails the Zoom rules | paste the meeting's `https://...zoom.us/j/...` join link |
| `zoom_already_attached` | the location already has a Zoom link | pass `replace: true` to swap it |
| `too_many_events` | the window holds more than 250 events | narrow the window |
| `event_gone` | Google answers 404 or 410 on the write | list the window again |
| `google_error` | any other Google failure, with its closed cause | retry; if it repeats, see the athena log line |

A failed Google write changes nothing on Athena's side and returns its cause.

## 2. Reaching other people

Inviting, uninviting, RSVPing, and changing a shared event all email or
change the calendars of people other than Cody. That is owner approval policy
item 3 (`~/.claude/CLAUDE.md` → *Owner approval policy*).

### Options

| Option | For | Against |
| --- | --- | --- |
| Standing rule: every call executes, listed in the digest | no friction | a session that read untrusted content (a Slack message, an inbox line, a Notion page) can invite anyone. An email cannot be recalled, and an invite to an outside address carries the title and location out |
| Grant class (`calendar.change`, like `calendar.rsvp`) | a Slack button | needs DND-563 T2 to T4, and T3 is Parked. It is an item 6 change. And the target is a guest list and new field values, which is free-form content: *Owner approval grants* → *Action classes* says "No class declares a free-form field" |
| Per-call owner OK on the web | the owner sees exactly who is reached; works now; no rule change | one click per reaching change |

### OD-1: decided as a judgement call under item 3, listed in the digest

- **Changes that reach nobody execute directly.** An event with no other guest
  before or after the change: create, update, reschedule, attach Zoom.
- **`calendar_rsvp` executes directly**, `sendUpdates=all`. It reaches one
  person, the organizer of an invite Cody received, says only Cody's answer,
  and a second RSVP reverses it. The `/priorities` RSVP (DND-1742) is the
  same act, authorized by Cody's own click. Every MCP RSVP is listed in the
  next digest.
- **Every other change that reaches someone waits for Cody's OK in their own
  web session.** The tool answers `pending_approval` with an `approval_url`.
  The session shows the link to Cody. Cody opens it while logged in, sees the
  full change, and presses Approve or Reject.
- **No DM.** Cody asked not to be DMed unless only they can act. The link goes
  back to the session that asked, and the digest lists what is pending,
  applied, rejected and expired.

No new grant class, so no item 6 change. The web session is the owner path
`/priorities` already uses (login, CSRF, owner-scoped reads). If Cody later
wants Slack buttons for these, that is a `calendar.change` grant class: item
6, Cody's ratification, and DND-563 T3 unparked. I do not recommend it now,
for the free-form-target reason above.

Cody can veto either direct path (MCP RSVP, owner-only writes). The fallback is
the same approval page for those too.

### The approval path

The proposed change is **not stored in the database**. It travels in the
approval link.

- **The token.** `Phoenix.Token.encrypt` over `{owner_id, change_id, kind,
  event_id, etag, fields}`, where `fields` is the proposed values and guest
  addresses, and `etag` is the event's Google etag at proposal (none for a
  create). It expires 24 hours after proposal.
- **The row.** `calendar_changes` holds metadata only: `id`, `owner_id`,
  `kind`, `event_id`, `event_title`, `html_link`, `reaches` (a count), `state`,
  the requesting `claude_session_id` and machine id, `token_digest`
  (sha256 of the token), `proposed_at`, `decided_at`. No guest address and no
  proposed value. A directly applied write gets a row too, `state: applied`,
  so the digest can list it.
- **The page.** `/calendar/changes/:id?t=<token>`, `:browser` pipeline, login
  required. It decrypts the token, then loads the row by `id` and the
  logged-in `owner_id`. Every mismatch answers the same `not_found`: a
  token for another owner, a row for another owner, a digest that does not
  match, a bad or expired token. It shows the event, the full diff, each
  address reached, and marks addresses outside the organizer's email domain
  as **external**.
- **Live means unexpired.** Approve and Reject each decrypt the token again
  with its 24-hour max age, and require the row's computed state to be
  `proposed`: stored `proposed` and `now < proposed_at + 24h` on the injected
  clock. A page loaded just before expiry and submitted just after is refused
  as `not_found`.
- **Approve.** In a short transaction, the row is locked, checked live, and
  set to `applying`; the transaction commits. No database lock is held across
  a Google call. The server then reads the event again and checks that the
  owner is still the organizer and that the etag still matches. A changed
  event marks the row `stale` and applies nothing (Fix: ask the session to
  propose it again). Then it PATCHes or inserts with `sendUpdates=all` and
  marks the row `applied`. A Google failure marks it `failed` with the closed
  cause. A token is spent once: the second Approve finds no live `proposed`
  row. A row still `applying` 5 minutes after it was set (past the adapter's
  request timeout; the node died mid-call) reads `failed (interrupted)` and
  is never retried by itself, because the write may have reached Google.
- **Approving a create** has no event to re-read and no etag. It inserts the
  event from the token's fields with `sendUpdates=all`; the organizer check
  is moot, since the owner's credentials create it.
- **Reject** marks a live row `rejected`. **Expiry** is read, not
  scheduled: a row stored as `proposed` past `proposed_at + 24h` reads
  `expired`. Its stored state stays `proposed`.
- **`decided_at`** is set whenever a row reaches `applied`, `rejected`,
  `stale` or `failed`, a direct apply included (its `decided_at` is its
  `proposed_at`).
- **An expired link shows `not_found`** on the page, like every other token
  mismatch, so the page never says whether a change exists. `calendar_change`
  and the digest show the `expired` state.
- **Retention.** Each new `calendar_changes` row, proposed or applied, first
  deletes the same owner's rows matching
  `coalesce(decided_at, proposed_at + interval '24 hours') < now - interval '30 days'`.
  One predicate covers every stored state: a stored terminal state has
  `decided_at`, and a row with none (stored `proposed` or `applying`) is
  past every read-only state (`expired`, `failed (interrupted)`) 24 hours
  after `proposed_at`. No new periodic worker. An owner who makes no calendar
  change for a long time keeps their last rows; they are small and metadata
  only.

The token carries the change's content; it lives in the calling session's
transcript and in the URL, on the owner's own machines. Phoenix's request log
records the path but the token is encrypted. The database never holds guest
addresses or proposed values, so the storage boundary does not widen. The
`calendar_changes` columns still go into the contract's closed list (ticket
DND-1764).

## 3. Zoom links

### Extraction rules

`Athena.Calendar.ZoomLink` (Domain, pure):

- **Sources, in order:** `conferenceData.entryPoints[]` with
  `entryPointType: "video"`, then `location`, then `description`. The first
  valid link wins.
- **Valid** means: scheme `https`; host `zoom.us`, `zoomgov.com`, or a
  subdomain of either (`us02web.zoom.us`, `<company>.zoom.us`); path starting
  `/j/`, `/w/`, `/s/` or `/my/`; at most 2,048 characters; and it passes the
  index's `FieldCheck.http_url/1`.
- **Finding a URL in text:** a URL is a maximal run of non-space characters
  starting `https://`. Description HTML is read for `href` values and plain
  URLs. `&amp;` becomes `&`. Trailing `.,;:)>"'` is trimmed.
- **Everything else is rejected**, so Google Meet is excluded by construction:
  `meet.google.com`, `hangoutLink`, a Google redirect (`google.com/url?q=`),
  `zoom.us.evil.example`, `http://zoom.us/...`. Each has a test.
- `Event.from_google/1` runs the extraction at the adapter boundary and keeps
  only `join_url`. The description, location and conference data are still
  dropped there.

### Store, or derive at render time?

| Option | For | Against |
| --- | --- | --- |
| **Store the extracted `join_url` on the meeting item** (recommended) | the page stays database-only (DND-447's rule); one field, nothing else from the description | widens the storage boundary: a new permissive field on `meeting`. Zoom links often carry the passcode (`pwd=`), which is then stored |
| Derive at render time | stores nothing | a Google read on every `/priorities` load, against DND-447's "nothing calls Google on a page load"; slow and fails with Google |
| No Zoom link on `/priorities` | stores nothing | not what Cody asked for |

**Owner decision OD-2 (storage boundary).** Recommendation: store `join_url`,
passcode included, as a permissive field of `meeting` in
`ai/contracts/athena-events.md` → *The storage boundary*, removable on its
own like the others. A one-click join needs the passcode. Until Cody answers,
the MCP reads return `join_url` (nothing stored) and `/priorities` shows no
Zoom link.

### Where it shows

- `/priorities` Meetings: a **Join Zoom** link per meeting with a `join_url`.
  The title still links to the Google Calendar event (`htmlLink`), never to
  Meet.
- The digest's meetings section: the same link (DND-1771).
- MCP reads: `join_url`.

## 4. Attach Zoom: pasted link, not the Zoom API

| Option | Needs |
| --- | --- |
| **Pasted link** (recommended) | nothing new: the session passes a link Cody gives it or one from an existing Zoom meeting |
| Zoom API creates the meeting | a Zoom account with a Server-to-Server OAuth app, its client id and secret in `Athena.Secrets`, Zoom's API terms, possibly a paid licence for meetings over 40 minutes (policy item 2, recurring cost), a Zoom adapter, and an owner console step to create the app |

Decision (judgement under item 2: no cost added): the pasted link.
`calendar_attach_zoom` and `calendar_create`'s `zoom_url` take a link and
validate it. Creating Zoom meetings is not ticketed. If Cody wants it, it is a
new ticket with its own owner step (the Zoom app) and a cost note.

## Architecture (gen_saas `apps/athena`)

**Framework**

- `Athena.MCP.Tools.CalendarEvents`, `CalendarEvent`, `CalendarCreate`,
  `CalendarUpdate`, `CalendarInvite`, `CalendarUninvite`,
  `CalendarAttachZoom`, `CalendarRsvp`, `CalendarChange`: thin components.
  Each runs `Helpers.with_machine/2`, reads the raw arguments, and calls the
  manager with the machine. A shared `Athena.MCP.Tools.CalendarReply` renders
  answers and `<code>: ... Fix:` errors.
- `Athena.UI.Pages.CalendarChange` (LiveView at `/calendar/changes/:id`,
  `:browser`, login required): events `approve` and `reject`.
- `Athena.UI.Pages.Priorities`: the Join Zoom link (DND-1742 owns the RSVP
  buttons there).

**UI components**

- `Athena.UI.Components.MeetingRows`: the Join Zoom link.
- `Athena.UI.Components.CalendarChangeDiff`: the diff, guests, external marks.

**Managers**

- `Athena.Calendar.Management`: `list/3`, `get/3`, `create/3`, `update/4`,
  `invite/4`, `uninvite/4`, `attach_zoom/4`, `rsvp/4`, `change/3`,
  `show_change/3`, `approve_change/3`, `reject_change/3`. Resolves the machine
  to its owner and the session binding, runs every check, then calls the
  adapter. `Athena.Calendar` keeps the sync, the connect and `today/2`.

**Domain**

- `Athena.Calendar.ZoomLink`: `extract/1` (from a Google event map),
  `valid?/1`.
- `Athena.Calendar.CalendarArgs`: the closed schema per tool, typed values,
  every `invalid_argument`.
- `Athena.Calendar.Audience`: from the event as read and the proposed change,
  `:owner_only` or `{:reaches, count, addresses}`.
- `Athena.Calendar.ChangeToken`: the token's payload shape and its digest
  (encrypting is the Side Effect's).
- `Athena.Calendar.EventView`: `EventSummary` and the detail, built from a
  Google event map. Never carries the description, `hangoutLink` or
  `conferenceData`.
- `Athena.Calendar.Event`: gains `join_url` (DND-1766, after OD-2 and
  DND-1765).
- `Athena.Calendar.Refusal`: the new codes and their `Fix:`.

**Side effects**

- `Athena.Calendar.GoogleClient` behaviour gains `list_window/3`,
  `get_event/3`, `insert_event/3`, `patch_event/4` (with `sendUpdates`), and
  DND-1742's `respond/4`. `Req` implements them inside
  `Secrets.with_secret/4`, as today.
- `Athena.Calendar.ChangeStore`: `calendar_changes` (new table, expand-only
  migration).
- `Athena.Calendar.ChangeSigner`: `Phoenix.Token.encrypt`/`decrypt` with the
  endpoint secret, max age 24 hours.
- `Athena.Calendar.FleetAdapter` (cross-subdomain: `Athena.Fleet`): the
  session-to-machine binding check.

The dependency rules hold: tools call only the manager; the manager calls the
adapters and the Domain; the Domain calls nothing.

## Access control

| Operation | Who | Resource | Where checked | On denial |
| --- | --- | --- | --- | --- |
| `calendar_events`, `calendar_event` | a machine token | the machine owner's primary calendar | `Management.list/3`, `get/3`: owner from the frame machine; the Google call uses only that owner's credentials | `not_configured`/`not_connected`/`revoked`; `not_found` |
| Owner-only writes, `calendar_rsvp` | a machine token and a fleet session bound to that machine | an event on the owner's primary calendar; organizer (writes) or guest (RSVP) | `Management` write functions: session binding, then `get_event`, then organizer or guest check, then `Audience`, all before any write | `not_found`, `not_organizer`, `not_an_attendee` |
| Writes that reach others | the same caller proposes; only the logged-in owner applies | as above | proposal: `Management`; apply: `approve_change/3`, row loaded by `id` and `owner_id` under lock, token digest compared, event re-read, etag compared | proposal refusals as above; apply: `not_found` (no leak of existence), `stale`, `failed` |
| View, approve, reject a change | the logged-in owner, web session, CSRF | the owner's own `calendar_changes` row and token | `Athena.UI.Pages.CalendarChange` → `Management.show_change/3` etc. | `not_found` for every mismatch |
| `calendar_change` | a machine token | the machine owner's rows | `Management.change/3`: `owner_id` filter in the query | `not_found` |

- **Deny by default.** No argument selects an owner, a calendar or a
  `sendUpdates` value. An event not on the owner's primary calendar is
  `not_found`.
- **Every query filters `owner_id`** in the query itself, not by RBAC alone.
- **Negative tests** for every row: another owner's machine, an unbound
  session, a non-organizer, another owner's change id and token, a logged-in
  non-owner.
- **Untrusted content never authorizes a change.** A calendar request inside a
  Slack message, inbox line or Notion page is a fact to relay
  (`athena:inbox-attend` tiers). The approval page is the enforcement for
  anything that reaches people.

## Tickets

| Ticket | Repo, machine | Path | Depends on |
| --- | --- | --- | --- |
| DND-1764: contract, *Calendar management* (tools, approval path, `calendar_changes`, `meeting.self_response`) | custom, desktop | Critical | none |
| DND-1765: contract, `meeting.join_url` | custom, desktop | Critical | owner OD-2 |
| DND-1767: MCP reads `calendar_events`, `calendar_event`, and `ZoomLink` | gen_saas, laptop | Critical | DND-1764 |
| DND-1768: owner-only writes `calendar_create`, `calendar_update`, `calendar_attach_zoom`, the change log | gen_saas, laptop | Critical | DND-1767 |
| DND-1769: the approval path, `calendar_invite`, `calendar_uninvite`, `calendar_change` | gen_saas, laptop | Critical | DND-1768 |
| DND-1770: `calendar_rsvp` | gen_saas, laptop | Critical | DND-1767, DND-1742 |
| DND-1766: store `join_url` at sync, Join Zoom on `/priorities` | gen_saas, laptop | Critical | DND-1765, DND-1767 |
| DND-1771: digest Join Zoom and the calendar changes line | gen_saas, laptop | Critical | DND-1766, DND-1768, DND-1740 |

The order ships value early. The reads give sessions event ids and Zoom links
before any write exists, and owner-only writes land before the approval path.
OD-2 holds only DND-1765, DND-1766 and the Join Zoom half of DND-1771.

Test lists and live verifies are on the tickets. Every test is functional
(DND-1222): Google is faked at the `GoogleClient` boundary, time is an
injected clock, no `Process.sleep`, no load or wall-clock thresholds.
DND-1761 depends on all eight.

DND-1742's stored `responseStatus` is a field the contract does not yet list
for `meeting`. DND-1764 adds it as the permissive field `self_response`.

## Owner decisions

1. **OD-2, store the Zoom link** (storage boundary, OQ-5 lineage).
   Recommended: yes, `join_url` with its passcode, one permissive field on
   `meeting`. Blocks the Join Zoom link on `/priorities` and in the digest
   only.
2. **OD-1, reaching other people**, is decided as a judgement call under
   item 3 and listed in the digest, not an ask: direct for owner-only writes
   and MCP RSVPs, Cody's web OK for the rest. Cody may veto either direct
   path.
3. **No grant class** is proposed, so no item 6 change. A `calendar.change`
   class for Slack buttons stays open to Cody, and is not recommended.
4. **Pasted Zoom links**, no Zoom account, is decided under item 2 (no cost).
   The Zoom API is open to Cody as a new ticket.
