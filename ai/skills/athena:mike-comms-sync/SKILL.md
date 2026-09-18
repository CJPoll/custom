---
name: athena:mike-comms-sync
description: >-
  Collect Mike Peregrina's communications from BOTH Slack and email over the
  last 72 hours, upsert them into the "Mike Communications" Notion DB without
  creating duplicates, group them into "Mike Conversations" (many-to-many
  follow-ups), and reconcile the Status fields on both. Use whenever asked to
  "collect Mike's Slack/email communications", "sync/update Mike
  Communications", "update Mike Conversations", "catch up on Mike Peregrina", or
  to run this as a recurring digest. Idempotent — safe to re-run; it reconciles
  rather than re-inserts.
---

# athena:mike-comms-sync

Pull everything Mike Peregrina said across **Slack and email** in the trailing
**72 hours**, land each message as a row in the **Mike Communications** Notion
DB, link messages into **Mike Conversations** (grouped follow-ups), and keep the
Status on both current. Designed to be re-run on a cadence: it **upserts**, so a
second run adds only what is new and updates what changed.

## ⚠️ The one footgun that will silently lose all email

Mike's Slack profile lists `mikep@heywalt.ai`, **but his email is actually sent
from `mikep@heyamby.ai`.** These are different domains. A Gmail search filtered
on `mikep@heywalt.ai` returns **nothing** and the run looks "clean" while having
missed every email. Always search email on **`mikep@heyamby.ai`** (and by name
`Peregrina` as a backstop). Exclude marketing blasts from `hello@heyamby.ai` —
those are not Mike.

## Fixed facts

- **Person:** Mike Peregrina. Known Slack user ID `U077HU8G5LZ` — but **resolve
  it dynamically** each run (see step 1); treat `U077HU8G5LZ` as the expected
  result, not a hard-coded input.
- **Real email address:** `mikep@heyamby.ai` (NOT the `heywalt.ai` on his Slack
  profile).
- **Window:** trailing **72 hours** from now. Compute the cutoff dynamically:
  `NOW - 72h`. Slack `after:` wants `YYYY-MM-DD`; Gmail `after:` wants
  `YYYY/MM/DD` (different separator — do not mix them up). Round the cutoff DOWN
  to the day so a message from hour 71 is never excluded by date-only filtering,
  then discard hits whose real timestamp is older than the 72h mark.
- **Notion connection:** these are **work** DBs. Use the active work Notion MCP
  connection (the `notion` server here; see [[athena:ticket-management]] for how
  to resolve notion-personal vs notion-work when ambiguous). Prefer routing
  reads through the **notion-reader** subagent to keep raw payloads out of
  context; do writes yourself with the `notion` write tools.

### The two databases (discovered schema — trust this, re-verify if it drifts)

**Mike Communications** — one row per individual message. Data source
`collection://3dfb16b5-1fbf-804a-9b06-000b384b4982`
(page `3dfb16b51fbf80fcbe3ec1fb4141a733`).

| Property | Type | Notes |
|---|---|---|
| `Name` | title | Short human label for the message (e.g. subject, or first line). |
| `Source` | url | **The message identity / dedupe anchor.** Slack message permalink, or Gmail message/thread URL. |
| `Date` | date | The message timestamp (set `is_datetime=1`). |
| `Medium` | select | `Slack` \| `Email`. |
| `Channel` | select | `#team-engineering`, `#bugs`, `#marketing`, `#general`, `#product`, `#customer-feedback`, `#ext-faraday-ambyai`, `#homie-updates`, `Group DM`, `DM`, `Email`. |
| `Type` | select | `Action` \| `Question` \| `Review` \| `Decision` \| `FYI`. |
| `Scope` | select | `Internal` \| `External`. |
| `Ask` | text | What Mike is asking for / the actionable gist. |
| `Owner` | multi_select | Who **on our side** owns the reply: `Cody`, `David Tolman`, `Erich`, `Athena`, `Sarah Edelman`, `Faraday (Robbie/Michael)`, `Engineering`, `Unassigned`, `Tom Hester`. (Mike is the sender — there is **no** sender field; the DB is implicitly all-Mike.) |
| `Status` | select | `Needs Reply` \| `Action Needed` \| `Replied` \| `Not Needed`. |
| `Status Changed On` | date | Timestamp of the last `Status` change. **The skill sets this whenever IT changes `Status`** (see "The status-timer contract"). Set via expanded columns `date:Status Changed On:start` (ISO-8601), `date:Status Changed On:is_datetime`=1, `:end` NULL. |
| `Days in Status` | formula | **Read-only — never write it.** Derives days since `Status Changed On`. |
| `Conversations` | relation → Mike Conversations | Many-to-many. A message may link to **more than one** conversation. |

**Mike Conversations** — groups multiple follow-ups. Data source
`collection://3dfb16b5-1fbf-803b-9f5e-000b85fdc759`
(page `3dfb16b51fbf80aa867af6d58b69c922`).

| Property | Type | Notes |
|---|---|---|
| `Name` | title | The conversation topic. |
| `Communications` | relation → Mike Communications | Reverse of `Communications.Conversations`; many-to-many. |
| `Medium` | multi_select | `Slack` and/or `Email` (a conversation can span both). |
| `Status` | select | `Open` \| `Active` \| `Resolved`. |
| `Status Changed On` | date | Timestamp of the last `Status` change. Same contract as Communications — the skill stamps it when IT changes `Status`. Set via `date:Status Changed On:start` (ISO-8601), `date:Status Changed On:is_datetime`=1, `:end` NULL. |
| `Days in Status` | formula | **Read-only — never write it.** Derives days since `Status Changed On`. |
| `Topic Summary` | text | Rolling one-liner of what the thread is about. |

**What differs from a naive reading — encode these:**
- There is **no dedicated permalink/ts or message-id column.** The `Source` URL
  IS the message identity: dedupe on it (see step 5).
- Communications `Status` is **`Needs Reply`/`Action Needed`/`Replied`/`Not
  Needed`** — NOT the ticket lifecycle. Conversations `Status` is
  **`Open`/`Active`/`Resolved`**. Two different vocabularies; keep them straight.
- `Owner` is the **internal** responsible party, not Mike. Mike is the sender by
  construction; there is no "From" field to populate.
- The Communications↔Conversations relation is **genuinely many-to-many** on
  both sides — exactly the "one message, multiple follow-ups" semantic.

## The status-timer contract (`Status Changed On` / `Days in Status`)

Both DBs carry a `Status Changed On` (date) and a `Days in Status` (formula).
The intent is a "how long has this been sitting in its current status" timer. A
UI automation ("when `Status` changes → set `Status Changed On` = Now") covers
changes a **human** makes in the Notion UI — **that automation is the user's
responsibility, not this skill's** (the API cannot create Notion automations).
But this skill writes `Status` **programmatically** during reconcile, and a
programmatic write may or may not trip the UI automation, so the skill must keep
the timer honest on its own writes. The rules:

1. **Stamp on change.** Whenever the skill writes a `Status` value that differs
   from the row's current `Status` (either DB), it MUST in the SAME
   `notion-update-page` call also set `Status Changed On` to **now**. In this
   MCP that means the expanded date columns:
   - `date:Status Changed On:start` = current ISO-8601 datetime,
   - `date:Status Changed On:is_datetime` = `1`,
   - `date:Status Changed On:end` = NULL (single instant, not a range).
2. **Only on a real change.** If reconcile leaves `Status` unchanged, do NOT
   touch `Status Changed On`. Stamping it every run resets the timer to zero
   each time and makes `Days in Status` meaningless. So: read the current
   `Status` first, compare, and stamp only when old ≠ new.
3. **On insert.** A brand-new row (Communications or Conversations) is born with
   an initial `Status`, so set `Status Changed On` to that **same insert
   moment** in the create call.
4. **Never write `Days in Status`.** It is a read-only **formula**
   (`if(empty(prop("Status Changed On")), "—", format(dateBetween(now(),
   prop("Status Changed On"), "days")) + " days")`) — writing it is rejected.
   Also note Notion's `now()` is **not** real-time: it refreshes when the page
   is opened or edited, so `Days in Status` can lag until the row is next
   touched. That is expected; do not try to "fix" it by rewriting the timer.

## Procedure

### 1. Resolve Mike's Slack ID

`slack_search_users` for `Mike Peregrina`. Expect `U077HU8G5LZ`. If the search
returns a different or ambiguous result, use what it returns (people change
handles) but note the mismatch in your report. Hold the ID as `<@UID>`.

### 2. Search Slack (two complementary queries, both paginated)

Tool: `mcp__plugin_slack_slack__slack_search_public_and_private`. Run BOTH
queries with `after:<YYYY-MM-DD>` (the 72h cutoff, rounded down to the day).
Pass the person filter in **both** the `filters` field AND the `query` string:

- `from:<@U077HU8G5LZ>` — everything Mike posted.
- `with:<@U077HU8G5LZ>` — DM / conversation threads involving Mike (captures
  both sides of a 1:1 or group DM).

Paginate via the returned `cursor` until the response says end-of-results — do
not stop at the first page. Results span public channels, private channels,
group DMs and 1:1 DMs. For each Slack hit capture: permalink (→ `Source`),
channel/DM (→ `Channel`; use `DM`/`Group DM` for direct messages), the real
message ts (→ `Date`), and the text (→ `Name`/`Ask` gist).

### 3. Search Gmail (name + the REAL address)

Tool: `mcp__claude_ai_Gmail__search_threads`. The parameter is **`query`** (not
`q`). Gmail dates are **`YYYY/MM/DD`**. Run both:

- `Peregrina after:<YYYY/MM/DD>` — name-based; catches calendar invites/
  cancellations, doc shares, forwards where the address is buried.
- `(from:mikep@heyamby.ai OR to:mikep@heyamby.ai OR cc:mikep@heyamby.ai) after:<YYYY/MM/DD>`
  — the address-based sweep. **Use `heyamby.ai`, never `heywalt.ai`** (see
  footgun above).

Discard messages from `hello@heyamby.ai` (marketing). For each email capture:
message/thread URL (→ `Source`), subject (→ `Name`), sent time (→ `Date`),
`Medium=Email`, `Channel=Email`.

### 4. Normalize each hit to a communication record

Build an in-memory list of candidate records, each with: `Source` (canonical
permalink/URL), `Date` (datetime), `Medium`, `Channel`, `Name`, `Ask` gist, and
your inferred `Type`/`Scope`. Drop any whose true timestamp is older than the
72h cutoff (the day-rounded `after:` filter lets in a little extra).

### 5. Read existing rows and DEDUPE by message identity — not text

Query existing Communications rows via `notion-query-data-sources` on
`collection://3dfb16b5-1fbf-804a-9b06-000b384b4982` (window the query to recent
rows by `Date` to keep it cheap). Build a set of existing `Source` URLs
(normalize: strip query strings/trailing slashes so the same permalink matches).

**Dedupe rule — critical:** a candidate is a duplicate **only if its normalized
`Source` matches an existing row's `Source`.** Do NOT dedupe on message text.
The *same words from Mike sent at two different times are two different
communications* — different permalink/ts ⇒ different `Source` ⇒ two rows (which
may still belong to the same conversation). Since `Source` already encodes the
ts/message-id, matching on `Source` alone is the correct identity check; use
`Date` only as a sanity tiebreaker if a Source somehow repeats.

### 6. Upsert Communications

- **New** (`Source` not seen): create a row with `notion-create-pages` into the
  Communications data source. Fill `Name`, `Source`, `Date` (datetime),
  `Medium`, `Channel`, and best-effort `Type`/`Scope`/`Ask`/`Owner`. Default
  `Status` = `Needs Reply` for an inbound that plausibly wants a response, else
  `Action Needed`/`FYI`→`Not Needed` per judgement. **Because the row is born
  with a Status, stamp `Status Changed On` to the same insert moment** (see "The
  status-timer contract").
- **Existing** (`Source` seen): update in place with `notion-update-page` only
  if a field materially changed (e.g. edited text, a thread that now has a
  reply). Never create a second row for an existing `Source`. If that update
  changes `Status`, also stamp `Status Changed On` (contract below); if `Status`
  is unchanged, leave `Status Changed On` alone.

### 7. Group / link into Conversations (many-to-many)

- Query existing Conversations rows. Decide, per communication, which
  conversation(s) it belongs to by topic/thread continuity (a Slack thread, an
  email thread, or a follow-up on the same subject).
- A single communication **may link to multiple conversations** — set the
  `Conversations` relation to ALL that apply (this is the "one message → several
  follow-ups" case). Conversely a conversation's `Communications` gathers all
  its member messages.
- Reuse an existing conversation when the topic matches; only
  `notion-create-pages` a new Conversations row when the message starts a
  genuinely new topic. A new conversation is born `Status`=`Open`, so **stamp
  its `Status Changed On` to the create moment** (contract below). Set the
  conversation's `Medium` multi-select to the union of its members' mediums (a
  thread that moved Slack→email carries both), and keep `Topic Summary` a
  current one-liner.

### 8. Reconcile Status on every touched row (stamp the timer on real changes)

Do this each run — it is the "keep it up to date" half of the job. **Every time
you change a row's `Status` here, you MUST also stamp `Status Changed On` per
"The status-timer contract" — and only when the value actually changes.**

- **Communications** (`Needs Reply` / `Action Needed` / `Replied` / `Not
  Needed`): if our side has since replied (a later message from us in the same
  thread, or the ask is resolved), move `Needs Reply`/`Action Needed` →
  `Replied`. Leave `Not Needed` alone. Purely informational messages →
  `Not Needed`.
- **Conversations** (`Open` / `Active` / `Resolved`): a conversation with new
  unanswered inbound is `Open`; one with ongoing back-and-forth is `Active`; one
  where the last exchange closed the loop is `Resolved`. Recompute from the
  member communications' states, don't just leave stale.

### 9. Report

Summarize: how many Slack hits and email hits found; new rows created vs
existing rows updated (and confirm zero duplicate `Source` inserts); new/updated
conversations; status transitions applied; and any anomaly (Slack ID mismatch,
a Source that appeared twice, an email you were unsure was Mike).

## Tool quick-reference (exact names / params)

| Purpose | Tool | Key params |
|---|---|---|
| Resolve Slack ID | `mcp__plugin_slack_slack__slack_search_users` | query `Mike Peregrina` |
| Slack search | `mcp__plugin_slack_slack__slack_search_public_and_private` | `query` + `filters` (`from:`/`with:` + `after:YYYY-MM-DD`), paginate `cursor` |
| Gmail search | `mcp__claude_ai_Gmail__search_threads` | **`query`** (not `q`); dates `YYYY/MM/DD` |
| Read Notion rows | `mcp__notion__notion-query-data-sources` (or via notion-reader) | the `collection://…` data-source URL + filter |
| Create Notion rows | `mcp__notion__notion-create-pages` | parent = data source URL |
| Update Notion row | `mcp__notion__notion-update-page` | page URL/ID + changed props; on a `Status` change also set `date:Status Changed On:start`/`:is_datetime`=1/`:end`=NULL (never write `Days in Status`) |

## Idempotency invariant

Running this twice in a row must not create a second row for any message. The
guarantee rests entirely on step 5's `Source`-URL dedupe. If you ever cannot
recover a stable `Source` for a hit, do NOT insert a placeholder that will
duplicate next run — skip it and flag it in the report instead.
