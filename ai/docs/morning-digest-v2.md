# Morning digest v2 (DND-1737, DND-1738)

**Kind: dated record.** Design of 2026-10-02. Later changes are annotated, not
rewritten (`CLAUDE.md` → *Documentation conventions*).

## The ask

Cody, Slack DM, 2026-10-02 13:18Z (DND-1737), verbatim:

> 1. Things that need my attention from the /priorities list, with a link to
> the priorities page. 2. A status report on what work was completed overnight
> grouped by session and epic. 3. An overview of my meetings for the day,
> including a tl;dr of anything I should do to prep. each should have a slack
> block kit going vs maybe vs not going

DND-1738: the epic-clustering cron's owner message ("daily ticket digest …;
tier-4 queue 527 …") goes silent. Its asks fold into the morning digest.
Bookkeeping counts go to the run record only.

Cody approved starting both by a verified Block Kit click, 2026-10-02 13:30Z.

## Two digests exist today

| | gen_saas `Athena.Digest` (DND-446) | clustering cron's "daily ticket digest" |
| --- | --- | --- |
| Sender | the server, `Slack.owner_dm/3` | a headless architect, `mcp__athena__slack_post` |
| When | 07:00 America/Denver, Mon–Fri, once per local day (`SendStore`) | the 07:00 Denver clustering run (`scripts/athena-clustering-run.sh`) |
| Content | owner queue (max 10), top N leasable per domain, link to `/priorities` | tier-4 queue counts, next 10, won't-fix candidates, pass counts |
| Owner's verdict | "helpful" | "I don't know what to do with" |

So "the morning digest" the owner likes is the server's. The clustering
message is the one DND-1738 silences.

## Decision: gen_saas `Athena.Digest` owns the new digest

Why:

1. **It already is the morning digest.** Scheduler, once-per-day claim
   (`digest_sends`), DST handling, owner-only recipient and the
   `/priorities` "Last digest" line all exist and are tested.
2. **It holds the data for every section.** Section 1 is the priority
   index's owner queue. Section 2 is the fleet registry (`fleet_sessions`,
   admiral runs, reported missions) plus the index's ingested Notion `Epic`
   relation. Section 3 is DND-447's Google Calendar adapter (gen_saas PR
   #576, open).
3. **No agent tokens.** It is deterministic server code. The owner's
   token-efficiency direction is met by construction: no agent reads a Notion
   page to build it. The one model call is the prep tl;dr, a Jev judgment over
   a few fields of one event.
4. **The harness cannot read the calendar.** Measured 2026-10-02 from a
   scratch dir: a headless `claude -p` on this machine lists the claude.ai
   Claude Docs connector but **no** Google Calendar tool, by name or by
   ToolSearch. The connector also reported "session expired" in an
   interactive session the same hour. So no cron or script can read the
   owner's calendar today. The server path (DND-447's OAuth) is the only one.
5. **The RSVP write needs a server-side actor.** A digest the server posts
   fails *A click is untrusted input* check 3 for every session (the session
   did not post it). So no session can act on its click. The server can,
   through an owner approval grant (below).

Rejected: a harness cron that assembles the digest with an agent. It cannot
read the calendar (point 4), cannot act on the RSVP (point 5), and spends
tokens daily on what the server computes for free.

## The digest, section by section

The order is the owner's. Each section is present even when empty, with a
one-line reason ("Nothing needs you." / "No work completed since <time>." /
"No meetings today." / "Calendar not connected: …"). An empty section never
reads as a missing one (`~/.claude/CLAUDE.md` → *A failed lookup must never
look like an empty one*).

### 1. Needs your attention

- **Source:** unchanged. `Priorities.list_ranked/2` with the owner's user:
  `proposed` items and `active` `owner_only` items, rank order, max 10, then
  "and N more".
- **Link:** the section header links `/priorities` (the owner tab).
- **DND-1738's Needs Attention asks land here with no new code.** A ticket
  moved to `Needs Attention` is assigned to the owner
  ([[athena:ticket-management]]), and the index marks it `owner_only`
  (`Priorities.Classification.owner_only/3`). It arrives through the existing
  Notion ingest. DND-1738's live verify proves it.
- **Won't-fix notices are not folded.** Each carries a one-click veto. A
  harness session posts it, and that session's four checks verify the click.
  A veto button inside a server-posted digest would fail check 3 for every
  session, so the veto would stop working. Moving the veto server-side is a
  new grant class: a change to the approval rules, which stays with the owner
  (policy item 6). So each won't-fix notice stays its own DM, sent only when a
  candidate exists. It is an ask, which DND-1738 keeps.

  **Later (2026-10-02, DND-1749):** on the clustering cron the poster is the
  cron's headless session, which exits after the pass, so no session can
  verify a click there either. A cron notice has no buttons; the owner vetoes
  by reopening the ticket (`athena:epic-clustering` → *Won't-fix notices* →
  *On the cron*).
- The per-domain "top N leasable" lists stay, after section 3, under "Up
  next". The owner called the current digest helpful; nothing in the ask
  removes them.

### 2. Overnight

- **Window:** from the previous successful digest send for this owner to now.
  With no previous send, the last 24 h. Capped at 72 h, so Monday covers the
  weekend. The header names the window: "Since Fri 07:00".
- **Sources, all server-side:**
  - fleet registry: admiral runs active in the window, their session (machine
    and session label), `scope_label`, and reported missions whose status
    reached done or merged in the window;
  - priority index: Notion ticket items whose state moved to `done` in the
    window, with their `Epic` relation (ingested today; `Backfill` warns when
    a binding has no `Epic` property).
- **Grouping:** session, then epic, then tickets. A done ticket with no fleet
  mission goes under "Outside a fleet run". A ticket with no epic goes under
  "No epic". Each ticket is its ref linked to its url, plus its title.
- **Join key:** the Notion page id. A mission's `lookup` and an index item's
  `source_ref` both resolve to it. A mission whose lookup does not resolve is
  counted and named ("2 missions not matched"), never dropped.
- **Still running:** one line per session ("3 missions still running").
- **Storage boundary:** titles, refs and urls only, as section 1.

### 3. Today's meetings

Built on DND-447 (PR #576): meetings are `meeting` index items
(`source_ref` `meeting:<google_event_id>`), synced from the owner's primary
calendar for the owner-local day; only title, url and start are stored.

Each meeting is one block:

- local time, linked title;
- **prep:** one line, at most 200 characters, or "No prep found.";
- **RSVP:** Going · Maybe · Not going, with the owner's current response
  marked.

**Prep tl;dr.** A Jev judgment, use case `meeting_prep` (question set v1,
`ai/contracts/athena-judgments.md`). Input: title, the event description
trimmed to 4,000 characters, attachment titles, organizer-is-owner flag,
attendee count. Output: one line or `none`. The description is read at
digest time and passed to the judgment, **never stored**: the judgment
record keeps its input hash and output only. An unavailable judgment renders
"prep: not judged (<cause>)", never a blank. This reads a field DND-447's
OQ-5 excluded (no description), so it waits on the owner (*Owner-only
steps*).

**RSVP, two phases.**

- **Phase A: links.** Each meeting links to `/priorities#meeting-<id>`.
  There, DND-447's Attend/Skip becomes Going/Maybe/Not going. Each sets the
  owner's attendee `responseStatus` to `accepted` / `tentative` / `declined`
  with `sendUpdates=all`. That is an owner web session: login, CSRF, the
  owner's own calendar. No new approval path.
- **Phase B: Slack buttons.** Three buttons per meeting in the digest. Each
  carries a v3 grant token of a new class `calendar.rsvp`, typed target
  `{event_id, response}`, consumer the gen_saas server at click time. It has
  the same shape as the ratified `priority.transition` class
  (`ai/contracts/athena-events.md` → *Owner approval grants* → *Action
  classes*). The click handler verifies the owner and the token, calls the
  same `respond` the web path uses, then replaces the buttons with the
  recorded choice. It waits on two things: the grant click path (DND-563 T2,
  T3 and T4; T3 and the DND-563 epic are Parked) and the owner ratifying the
  class.

Phase A is not a substitute for the ask. It is what can ship before the
grant path exists; Phase B delivers the Block Kit buttons the ask names.

**The RSVP reaches the organizer** (`sendUpdates=all`). That is policy item 3,
reaching another person. The design call: the owner's own click, on the
owner's own invite, choosing the owner's own response, is the authorization.
It is the same act as clicking the response in Google Calendar, and nothing
is sent that the owner did not choose. Recorded here and on DND-1737.

## Access control

| Operation | Who | Where | Denial |
| --- | --- | --- | --- |
| Build and send the digest | system, for each owner in `Priorities.digest_owners/0` | `Athena.Digest.run_due/1` | refusals recorded, shown on `/priorities` with `Fix:` (unchanged) |
| Read owner queue, overnight items, meetings | the owner's own rows only: every query filters `owner_id` | `Digest.PrioritiesAdapter`, a new `Digest.FleetAdapter`, the DND-447 calendar adapter | another owner's row is never read; fleet reads go through `Fleet`'s owner-scoped read path, never the machine-token report path |
| RSVP on `/priorities` | the logged-in owner, for an event id in today's synced set for that owner | the DND-447 meetings handler, extended | unknown or foreign event id: `:not_found`, so existence does not leak |
| RSVP by Slack click | the owner (`actor` = the app row's `owner_slack_user_id`), on a button the server's own digest send offered, with a valid unexpired v3 token of class `calendar.rsvp` whose target names an event in today's set | `SlackInteractions.handle_click/3`, the T4 grant branch, then a `Digest.Rsvp` manager | any check fails: no calendar write, a refused click is recorded, buttons unchanged |
| Prep judgment | system | the Jev judgment client | unavailable: "not judged (<cause>)" |

Deny by default: a button outside the send's offered set is refused even with
a valid signature. Enforcement is server-side; hiding a button is never the
control.

## Child tickets

| Ticket | Repo, Area | Depends on |
| --- | --- | --- |
| DND-1738: clustering run stops the owner digest DM | custom, Harness | none |
| DND-1739: contract, *Morning digest* v2 | custom, Harness | none |
| DND-1740: digest v2 layout, section 1 link | gen_saas, Product | DND-1739, DND-447 |
| DND-1741: overnight section | gen_saas, Product | DND-1740 |
| DND-1742: three-state RSVP on `/priorities`, digest meeting links | gen_saas, Product | DND-447, DND-1740 |
| DND-1743: meeting prep tl;dr judgment | gen_saas, Product | DND-1742, owner OQ-5 amendment |
| DND-1744: contract, `calendar.rsvp` grant class | custom, Harness | owner ratifies the class |
| DND-1745: Slack RSVP buttons via `calendar.rsvp` grants | gen_saas, Product | DND-1742, DND-1744, DND-563 T2/T3/T4 |

Test lists are on the tickets. DND-1737 depends on all eight. Every test is functional
(DND-1222): no load, no wall-clock thresholds; time is an injected clock.

## Owner-only steps

1. **Connect the calendar** (DND-447's, still open):
   1. Create a Google Cloud OAuth client (Web) with redirect URI
      `https://athena.cjpoll.me/oauth/google/callback`, Calendar API enabled.
   2. If the work Workspace restricts third-party apps, its admin allowlists
      that client.
   3. Paste the client JSON on Athena `/secrets` as `google_oauth_client`.
   4. Open `/oauth/google/start` and consent to `calendar.events`.
2. **Amend OQ-5 for the prep tl;dr** (DND-1743): allow the event description and
   attachment titles to be read at digest time for the judgment, never
   stored. One yes/no.
3. **Ratify grant class `calendar.rsvp`** (DND-1744, DND-1745): target
   `{event_id, response ∈ accepted|tentative|declined}`, own primary calendar,
   only an event in today's synced set, `sendUpdates=all`, consumer the server
   at click time, single use, expires at the event's end. Policy item 6: only
   the owner's own words, or a verified click on that one question.
4. **Unpark the grant click path** (DND-563 T3, and the epic) if Phase B is
   wanted soon. T3 is Parked, so DND-1745 cannot start.

## Not decided here

- Weekend sends: the digest keeps `digest_weekdays` (Mon–Fri default). The
  72 h window cap makes Monday cover the weekend.
