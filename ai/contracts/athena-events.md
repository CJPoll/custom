# The Athena Event Platform — contract

**Kind: living normative document.** Amended in place, per `~/dev/custom/CLAUDE.md`
→ *Documentation conventions*.

**Status:** normative. **Adopted:** 2026-09-20. This document is the contract for
the Athena event platform: the deterministic notification / event-handling
substrate that `apps/athena` implements. Notification logic leaves the LLM and
becomes owner-configured, deterministic **config, not code** — three ingress
kinds feed one router, the router matches each event against the owner's handling
rules and dispatches through delivery adapters, and the inbox is one adapter
among several.

**Normative home:** `~/dev/custom/ai/contracts/athena-events.md`. The
`~/dev/custom` harness owns the *mechanism* — the event envelope, the taxonomy
rules, the predicate grammar, the trust posture, the security MUSTs. Owners own
their *rules, config, and secrets* (server-side per-account data, never
committed). The design record this contract is drawn from is
`ai-artifacts/coordination/2026-09-19-inbox-lanes/design.md` (a gitignored,
machine-local dated record cited for provenance only — this contract is
self-contained and an implementer is **not** required to have that file); where
that design and this contract disagree on a normative point, **this contract
wins**.

**How this document is amended.** As a living normative document (not a dated
record):

- **Normative prose is amended in place.** A reader implements from the current
  text, so a superseded rule is replaced rather than left standing beside its
  replacement.
- **Each amendment that supersedes an existing rule is announced by exactly one
  paragraph opening with a bold dated label** — `**Later (YYYY-MM-DD):** …`, in
  UTC, dated against the adoption date above — placed at the definitional
  mention, the place a reader grepping the superseded term lands. It says what
  the rule used to be, what replaced it, and why. One pointer per amendment.
- **Purely additive content carries no label** — a new section or a rule where
  there was none has no superseded text to warn a reader about, and labelling
  additions would bury the supersessions in noise.

Sections are cited **by name**, never by number.

**Conformance language.** MUST / MUST NOT / SHOULD / MAY carry their usual force.
An **ingress** is any process that normalizes an external or harness signal into
an event. The **router** is the mechanism that evaluates an event against the
owner's rules. An **adapter** is any process that delivers a matched event to a
destination. An implementation that violates a MUST is non-conformant.

**Every refusal, rejection, and hard error specified in this document MUST carry
a greppable `Fix:` clause** on stderr (or the equivalent structured field),
naming the corrective action, alongside a non-zero result — per `~/dev/custom/CLAUDE.md`
→ *Guard/error messages are written for the LLM*. This applies to every rejection
below, not only to the ones that spell out the marker inline.

---

## The event

An event is a record of a **transition** — a change that occurred — not merely a
notification. Its envelope is:

```
{ type, payload, owner, occurred_at, source, idempotency_key }
```

- **`type`** — a namespaced dotted string naming the transition (see *The event
  taxonomy is open*). It is the primary thing rules match on. It is NOT a member
  of a fixed enum.
- **`payload`** — the enriched **current** values of the entity the event is
  about (for a ticket: status, labels, assignee, title, ticket number). The
  payload carries *present* state only; "what was it before?" is never in the
  payload (see *Predicates match the present; the membership diff handles the
  past*).
- **`owner`** — the account the event belongs to. For an **ingress-originated**
  event it MUST be stamped by the platform from the **authenticated ingress**,
  and MUST NEVER be read from the payload; a payload field that purports to name
  an owner is untrusted content, and using it to select an owner is a
  privilege-escalation defect. An **ingress-originated** event whose owner cannot
  be resolved from its authenticated ingress MUST be rejected with a `Fix:` (name
  the ingress and that owner resolution failed), never defaulted to an arbitrary
  or "system" owner. A **platform-derived** event (a `lane.member.*` transition,
  `source` = `derived:<rule_id>`, originated by no ingress) instead **inherits
  the `owner` of the originating membership rule** — the rule's own
  author-stamped owner (see *Rule ownership is stamped from the authenticated
  author*), resolved from the rule, not from any payload/caller-supplied value —
  so the "reject if unresolvable from ingress" clause above applies to
  ingress-originated events only. This is the **fourth owner seam** alongside the
  triad: **derived-inherits-rule-owner**.
- **`occurred_at`** — when the transition happened.
- **`source`** — provenance, from this **closed** set: `webhook:slack`,
  `webhook:notion`, `poller:<lane>`, `emit:<machine_id>`, and
  **`derived:<rule_id>`** for a **platform-derived** event (a membership-diff
  transition — `lane.member.added` / `lane.member.retracted` — which is
  originated by no ingress; its `source` names the membership rule whose diff
  produced it). Every enumerated `type` therefore has a legal `source`, so an
  owner predicate leaf on the matchable `event.source` field never reads an
  undefined value. `source` is **diagnostic only**. It MUST NEVER be an
  authorization input — nothing may grant an event more trust or more scope
  because of what its `source` says. (Authentication of the source is the
  ingress's sender-verification step; `source` is the label recorded after that
  step already succeeded, not a substitute for it.)
- **`idempotency_key`** — see *Idempotency is per (event, rule)*.

### The event taxonomy is open

The taxonomy is **open and extensible**: any state-based change can become an
event, and new sources and new fleet events add new `type`s **without a schema
change**. `type` is a namespaced dotted string precisely so this holds. This is
what lets fleet-control transitions (an admiral spinning a captain down early),
retraction messages, and future sources all be ordinary events matched by
ordinary rules, rather than special cases in code.

### Event disposition and dead-letter

Every event resolves to **exactly one** of three dispositions, and the
dead-letter MUST fires for only the third:

- **(a) DELIVERED** — at least one enabled rule produced a delivery: a `notify`
  rule matched, or a `membership` rule's diff emitted an `add`/`retract`
  transition (its own delivery).
- **(b) EVALUATED, NO-OP** — at least one enabled rule **applied** to the event
  (its trigger set includes this event's `type` — a `notify` rule's declared
  `event_type(s)`, or a membership rule's trigger set — see *Membership rules and
  the lane-membership store*) but produced **no** delivery: e.g. a `notion.ticket.updated`
  for a ticket already a stored member that **still** passes the predicate, so
  the diff is empty; or a `notify` predicate that evaluated false. The platform
  looked at the event and correctly did nothing.
- **(c) UNMATCHED** — **no** enabled rule applies to the event's `type` at all
  (no rule's trigger set includes it).

**An event is HANDLED when its disposition is (a) OR (b); the dead-letter MUST
fires for (c) ONLY.** An **UNMATCHED** event MUST be **dead-lettered and
persisted** to queryable storage for audit and debugging; it MUST NOT be silently
dropped, and it MUST NOT be **merely counted** — a bare counter cannot answer
"which event, of what type, for which owner, went unmatched?", exactly the
failed-lookup discipline (`~/dev/custom/ai/CLAUDE.md` → *A failed lookup must
never look like an empty one*): a legitimate miss MUST remain observable as the
specific thing it was. A **DELIVERED** or **EVALUATED-NO-OP** event MUST NOT be
dead-lettered.

**Why (b) is a distinct disposition, not a miss.** A membership rule declared on
`notion.ticket.*` applies to every ticket event in its trigger set, and most such
events change nothing about the set (the ticket was already a member and still
qualifies) — those are (b): the rule applied and correctly produced no
transition. Collapsing (b) into (c) would flood the dead-letter store (whose
whole purpose is "which event went **unmatched**?") with routine no-ops and their
full Path-2 payloads. Separately, a membership-derived `lane.member.*` transition
is itself disposition **(a)** — delivered by its originating rule, never
dead-lettered for want of a `notify` match; an owner MAY additionally declare a
`notify` rule on `lane.member.*`, whose own (a)/(b)/(c) disposition is determined
independently for that derived event.

The dead-letter store is **per-account** and its record grain is **one
exemplar-plus-count per `(owner, type)`**: the **first-seen full event payload** of
an unmatched `(owner, type)` — the **exemplar**, which alone answers the
failed-lookup question "which event, of what type, for which owner, went
unmatched?" — plus a monotonic **count** of subsequent unmatched events of that
same `(owner, type)` and a **last-seen** timestamp. The 2nd..Nth unmatched events
of an already-recorded `(owner, type)` **increment the count** and update the
last-seen timestamp; they store **no** new payload. The exemplar payload may carry
third-party content, so the record is **Path-2 untrusted** when read into an LLM
(see *Trust posture — two paths*), and read access is the owning account's.

**This one-exemplar-plus-count-per-`(owner, type)` grain bounds the store by a
structural quantity — the number of distinct unmatched `type`s per owner** (a
small finite set drawn from the enumerable taxonomy), independent of traffic
volume: a million unmatched Slack events of one type collapse to one exemplar +
count 1,000,000, rather than the million full payloads a disabled rule could
otherwise flood it with. The **"MUST NOT be merely counted"** rule is **honored,
not weakened** — an exemplar payload is retained for every distinct unmatched
`(owner, type)`, so the store still names which/what/whose event went unmatched;
the count is *added* metadata showing scale, never a *replacement* for the
payload.

Its retention follows the **same doctrine as the sibling inbox contract**
(`ai/contracts/athena-inbox.md` → *Retention* → *The principle*), not a
wholesale age-out — and the per-`(owner, type)`-exemplar grain is what makes that
doctrine **structurally safe**, where per-event it was not: an **unread exemplar**
is the canonical **never-delivered, never-read** item — and the sole evidence of
the miss this section insists stay observable — so retention MUST NOT destroy it
until it has been **read/triaged**. An unread exemplar has an **unbounded**
lifetime ("unread bytes are mail, and mail is kept until it is delivered, however
old it gets"), now bounded in aggregate at **at most one unread exemplar per
`(owner, type)`**; age-out under the product data-retention policy applies **only
after** it has been read/triaged. Destroying an unread miss would erase the very
observability the dead-letter store exists to provide. **The store carries no cap
or TTL number in this contract:** any operational cap/TTL is **ops/owner
config, explicitly outside this contract's MUST surface** — the contract states
**shape** only ("one exemplar + count per `(owner, type)`, unbounded-until-read").
No MUST here carries a number.

### Enumerated first-pass event types

The following `type`s are defined for the first pass. The namespace stays open —
this enumeration is the set that exists today, **not** a closed universe, and an
implementation MUST NOT reject or hard-code against an unknown well-formed `type`
(it dead-letters it per *Event disposition and dead-letter*).

**Source-emitted** (an ingress verified and normalized a real change at the
source):

- `slack.message.received`
- `notion.ticket.created`
- `notion.ticket.updated` — the coarse "a property changed" signal; its payload
  carries the changed property identifiers plus the enriched **current** values.
- `notion.ticket.deleted`
- `notion.ticket.undeleted`
- `notion.comment.created`
- `notion.comment.updated`
- `notion.comment.deleted`

**Membership-derived** (the platform's own membership diff produced a
transition — see *Membership rules and the lane-membership store*):

- `lane.member.added`
- `lane.member.retracted`

**Why value-direction lives on the membership side.** "A label was *added*" vs
"a label was *removed*", "an assignee was *set*" vs "*cleared*", and
"a ticket that *had* the label was *deleted*" are transitions of a specific
value's **direction**. The source does not carry direction (a Notion webhook is
metadata-only, with no before/after — see *Sender verification and payload
completeness*). Therefore there is **no** source-level `notion.label.removed`
type; that direction is produced by the membership diff and surfaces as
`lane.member.retracted`. Present-state membership entering a lane predicate
surfaces as `lane.member.added`.

### Payload fields and their types per event type

Every enumerated `type` declares a **closed payload schema** — the set of
`payload.*` fields it carries, each with a **type** and a **cardinality**
(scalar or collection). This schema is what a field-path binds against at rule
save time and what an operator's cardinality is checked against (see *The
predicate grammar*). It is closed: a `payload.*` path not in the declaring type's
schema is an unknown-path save-time error. The **envelope** fields are common to
every type — `event.type` (scalar string), `event.source` (scalar string),
`event.occurred_at` (scalar timestamp).

**This payload schema is the schema half of the per-(source, type) type
registry** (see *Membership rules and the lane-membership store*): the same
per-(source, type) record that fixes each type's **direction class** (a/b/c) also
fixes its payload schema, so a source's type is described in **one place** —
schema + direction class + which of its fields are **platform-minted** vs
**source-supplied / enrichment-derived**. That platform-minted marking is what the
trusted-slot check reads (see *Templating and the per-adapter Escaper contract* →
*Engine*), so field trust and field schema cannot drift out of sync.

| Event type(s) | `payload.*` field | Type | Cardinality |
|---|---|---|---|
| `notion.ticket.created`, `notion.ticket.updated`, `notion.ticket.undeleted` (the **enriched** ticket types) | `entity_id` — stable source entity handle, e.g. `notion:<uuid>` | string | scalar |
| | `status` | string | scalar |
| | `labels` | string | **collection** |
| | `assignee` | person-id | **collection** |
| | `title` | string | scalar |
| | `ticket_number` | string | scalar |
| | `changed_properties` (`notion.ticket.updated` only) | string | **collection** |
| `notion.ticket.deleted` (the **un-enriched** delete type — diffed WITHOUT a fetch; see *Membership rules and the lane-membership store*, trigger class (b)) | `entity_id` — stable source entity handle | string | scalar |
| | `ticket_number` — cached display field | string | scalar |
| | `title` — cached display field | string | scalar |
| `notion.comment.*` | `entity_id` — stable source entity handle | string | scalar |
| | `comment_text` | string | scalar |
| | `ticket_number` | string | scalar |
| | `title` | string | scalar |
| `slack.message.received` | `text` | string | scalar |
| | `channel` | string | scalar |
| | `user` | string | scalar |
| | `ts` | string | scalar |
| | `thread_ts` | string | scalar |
| | `event_id` | string | scalar |
| `lane.member.added`, `lane.member.retracted` | `rule_id` | string | scalar |
| | `lane` | string | scalar |
| | `op` | `"add"` \| `"retract"` | scalar |
| | `entity_id` | string | scalar |
| | `display` fields — **declared per lane SOURCE** (see below) | per source | per source |

**`entity_id` is the declared, bindable entity handle carried by every
source-emitted type that names an ENTITY with a membership lifecycle** — the
Notion ticket types (`notion.ticket.*`) and comment types (`notion.comment.*`)
each declare it (above) as the stable source identifier (e.g. `notion:<uuid>`),
and the membership-derived types (`lane.member.*`) carry the same field for the
member's handle. It is what the lane-membership store keys members on, what the
trigger classes scope current-members / non-members by, and what the
membership-derived idempotency basis references. It is a first-class declared
field, not an undeclared handle buried in a key. It is **distinct from the
display fields** `ticket_number` / `title` (which render a line and may be
cached); `entity_id` is identity.

**`slack.message.received` carries NO `entity_id` — by design, and this is what
the closed schema above says.** Its identity field is `payload.event_id` (paired
with `channel:ts` for cross-source dedupe — see below and *Idempotency is per
(event, rule)*), not an `entity_id`. A Slack message is a **transient event, not
an entity with a set-membership lifecycle**: it is never "added to" then
"retracted from" a working set, so there is no stable entity handle for the
lane-membership store to key on. The prose here therefore does **not** claim a
universal `entity_id` across all source-emitted types — the identity field is
**per source**, and only the Notion entity types (plus the membership-derived
types) carry `entity_id`, exactly as the closed table declares.

**Consequence for membership lanes: a source can feed a membership lane only if
its types carry `entity_id`.** Because the store keys members on `entity_id` and
trigger classes (b)/(c) scope current-members / non-members by it (see
*Membership rules and the lane-membership store*), a source with no `entity_id`
has nothing to key membership on. **A `slack.message.received`-sourced membership
lane is therefore not expressible in the first pass** — Slack messages carry no
member handle — and a `membership` rule declared solely on `slack.*` types is a
save-time HARD ERROR with a `Fix:` (a membership lane requires a source whose
types declare `entity_id`; the first-pass membership source is Notion). A
`notify` rule on `slack.message.received` is unaffected — it matches the present
message and needs no entity handle. This keeps the store's "source-agnostic —
carries over to a forge or any other membership lane" claim honest: any
membership source (Notion, a forge, …) is one whose entities carry `entity_id`,
which a Slack message is not.

**`notion.ticket.deleted` carries a NARROWER schema than the enriched ticket
types — by design, not omission.** A delete is diffed **without enrichment** (the
entity may already be unfetchable — see *Membership rules and the lane-membership
store*, trigger class (b)), so it can carry only `entity_id` (identity) plus the
`ticket_number` / `title` the store cached at add time; it does **not** carry
`status`, `labels`, or `assignee`. Those enrichment-only fields are therefore
**not in `notion.ticket.deleted`'s payload schema at all** (above), and a
field-path binding against them follows the ordinary save-time rules (see *The
predicate grammar* and the *Evaluation contract*): a rule declared **solely** on
`notion.ticket.deleted` with a leaf on `payload.labels` (or `status` /
`assignee`) is an **unknown-path save-time HARD ERROR** with a `Fix:` — **not** a
save-valid predicate that reads `absent` forever at runtime, which would be the
failed-lookup class this document legislates against (a leaf that binds valid at
save but can never match). This is deliberately **distinct** from the sanctioned
**union-binding absent-by-design** case: a rule spanning an enriched ticket type
**and** `notion.ticket.deleted` (e.g. `notion.ticket.updated` +
`notion.ticket.deleted`) binds such a leaf validly against the **union** of their
schemas and reads `absent` on the delete event — there another declared type
**supplies** the field, so the leaf is meaningful on at least one of the rule's
types; a delete-only rule has no such supplier, so the field never exists for it
and the bind is rejected where it is authored.

**The membership-derived types have a closed payload schema** — the lane/rule
identity (`rule_id`, `lane`), the transition `op`, the `entity_id` (the member's
handle, same field name as the source event carries), and the **display
fields**. The display fields are **declared per lane SOURCE**, not two
hardcoded Notion columns: a **Notion** lane declares `ticket_number` (scalar) and
`title` (scalar); a **forge** lane (or any other) declares its own display shape.
This keeps the store's "source-agnostic — carries over to a forge or any other
membership lane" claim honest and consistent with the open taxonomy: a
non-Notion lane is **config**, not a schema change. The display shape stays
**closed per source** (so it is still save-time-bindable): the platform validates
a `lane.member.*` predicate/template against the display shape the lane's source
declares — resolved from the consuming `notify` rule's declared **`source_lane`**
(see *Binding a `notify` rule on a `lane.member.*` transition*), since a rule that
matched every one of the owner's lanes could not resolve a single display shape
to bind against. This is deliberate — the contract makes a `notify` rule on a
`lane.member.retracted` transition first-class (see *Retraction-driven consumer
patterns*), so a predicate leaf or a template slot on that event MUST have a
closed, bindable, save-time-validated schema exactly like a source-emitted type.
The display fields are the same minimal ones the lane-membership store caches at
add time so a retract renders after the entity is gone (see *Membership rules and
the lane-membership store*), and they remain **Path-2 untrusted** when they reach
an LLM.

**`slack.message.received` carries `ts` and `event_id`** (not just
`occurred_at`): the deployed inbox reader keys cross-source dedupe on
`channel:ts` and on seen `event_id`s (against the Slack Web-API backstop — see
`ai/contracts/athena-inbox.md`), which `occurred_at` alone does not cover. They
are part of the closed schema so a rule may bind them and the dedupe pairing is
expressible.

### Idempotency is per (event, rule)

Because of fan-out (see *Fan-out: every match fires*), one event fires every
matching rule independently, so each `(event, rule)` delivery MUST be deduped and
retried on its own. The `idempotency_key` in the envelope is the **event-level**
key; the platform combines it with the matched `rule_id` to form the
**per-delivery** key. An implementation MUST dedupe and retry at the
`(event, rule)` grain, never only at the event grain.

The event-level key basis is defined for **every** enumerated type, so a derived
event dedupes as reliably as a source-emitted one:

- **Source-emitted** — the source's own event identity: Slack's `payload.event_id`;
  a Notion entity's `payload.entity_id` (`notion:<uuid>`) combined with a change
  token. (A reconciliation backstop hit reuses the same basis so it dedupes
  against the primary path — see *Poller (fallback only)*.)
- **Membership-derived** (`lane.member.added` / `lane.member.retracted`) — no
  source event identity exists, so the key is composed from the transition's own
  identity: **`rule_id` + `entity_id` + `op` + the triggering event's
  `idempotency_key`** (each a declared payload field — see *Payload fields and
  their types per event type*). This makes a given add/retract, produced by a given rule
  for a given entity off a given triggering event, idempotent under the fan-out
  and per-`(event, rule)` retry machinery like any other event. A transition
  emitted by the **reconciliation sweep** (see *Membership rules and the
  lane-membership store* → *The reconciliation sweep*) has no triggering source
  event — a swept `retract` recovers a member absent from the snapshot, for which
  no source delta arrived — so the **sweep run's own identity** (its snapshot/run
  id) supplies the triggering component of the key: `rule_id` + `entity_id` + `op`
  + the sweep run id. This keeps the swept transition retry-idempotent like any
  other; cross-run re-emission is separately prevented by the serialized diff
  against current stored state (an already-applied transition leaves no diff), not
  by this key.

---

## Ingress — three kinds, one event

There are exactly three ingress kinds, all normalizing to one event:
**inbound-webhook (PREFERRED)**, **poller (FALLBACK)**, and **harness-emit**.
Webhooks are preferred over pollers wherever a source supports an adequate one —
a poller carries a long-lived source token and more reliability infrastructure to
own, so it is the fallback used only where a source lacks an adequate webhook, or
for a trigger no webhook expresses (e.g. a time/SLA-based "sitting N days").

### Inbound webhook (preferred, first-class)

A verified `POST` from an external source, normalized to an event.

**Sender verification is mandatory and is the ingress's authorization of the
SOURCE — never of the CONTENT.** Every inbound webhook MUST verify a
signature/HMAC before doing anything else:

- The signature MUST be computed over the **raw request bytes as received**, not
  over a re-parsed or re-serialized copy — re-serialized JSON produces different
  bytes and will fail to match a legitimate signature (and, worse, could be made
  to match a tampered body). Verify the bytes as received.
- The comparison MUST be **constant-time**.
- An unverified or failed-verification body is a **hard reject** carrying a
  `Fix:` (name the header checked and that verification failed); it MUST NEVER be
  normalized into an event.

Verifying the *sender* does not make the *content* trusted. A verified Slack or
Notion webhook still carries a workspace member's arbitrary text, which remains
untrusted wherever it reaches an LLM (see *Trust posture — two paths*).

**Normalization** turns the source-specific verified payload into an event.
Source-specific knowledge stays inside the ingress adapter; the emitted event is
clean, and the router and rules own delivery. For a metadata-only source, the
ingress enriches the verified event via a least-privilege API fetch before
emitting (see *Sender verification and payload completeness*).

### Poller (fallback only)

A scheduled source poll, used **only where a source lacks an adequate webhook**,
or as a **low-frequency reconciliation backstop** for a webhook source (a
periodic snapshot of the current in-scope set, to catch entities that existed
before the subscription and events dropped during downtime). A poller keeps a
server-side cursor and emits one event per new hit.

**A reconciliation backstop separates DELIVERY dedupe from its RUN audit**, and
the two MUST NOT be conflated:

- **Delivery dedupes against the primary path by the same `idempotency_key`
  machinery.** A backstop hit on an entity a verified webhook already delivered
  produces **no duplicate delivery** — the primary path's delivery wins and the
  backstop hit is suppressed at delivery. (This is what "same dedupe machinery"
  means.)
- **The reconciliation RUN is recorded and reported on its own**, never folded
  into the primary path's dedupe. Each run emits its own audit signal — "checked
  the in-scope set, found it consistent" or "found N gaps the webhook path
  missed" — and that signal MUST survive **even when every individual hit deduped
  away at delivery**. Suppressing a hit's *delivery* MUST NOT erase the *run's*
  evidence that it checked and found nothing missing. (This is what "not
  conflated in reporting" means.)

This split is what makes "nothing is queued" **provably** true rather than merely
unobserved (failed-lookup discipline): the backstop's value is the run-level "I
checked" signal, which a delivery-level dedupe would otherwise destroy.

**For a MEMBERSHIP lane the backstop MUST run the full reconciliation sweep, not
merely emit one event per new hit.** "One event per new hit" recovers **adds**
(entities the webhook path missed) but never the **retracts** of stored members
that left scope during the gap: a member deleted, relabelled, or reassigned while
the webhook was down is simply **absent** from the snapshot and so produces no
hit, leaving the dropped `retract` unrecovered forever and the entity a stored
member permanently — the silent-never-retract class the membership store exists to
prevent. The backstop therefore re-evaluates the whole `(owner, membership-rule)`
set against the snapshot per *Membership rules and the lane-membership store* →
*The reconciliation sweep* — snapshot-not-stored → `add`, stored-not-in-snapshot →
`retract` — so the reconciliation guarantee covers **both** directions. Each
emitted transition still dedupes against the primary path by the same
`idempotency_key` machinery (above), so a `retract` the webhook path already
delivered is not re-emitted; the sweep recovers only the genuinely-missed ones.

### Harness-emit

`POST` from the fleet/harness via a small deterministic "fire `{type, payload}`"
primitive, authenticated by the **machine token**; the owner is resolved
server-side from that token (never from the payload). It carries no notification
logic — it only produces an event. (Roadmap increment; the envelope is specified
now so it is a natural later increment, not a rewrite.)

### Which event types an ingress kind may originate

`source` is diagnostic and MUST NEVER be an authorization input (see *The
event*), so nothing is trusted *because of* the provenance it claims. That rule
alone is not enough: it constrains how a `source` label is read, but not what an
authenticated ingress is allowed to **originate**. Authentication of an ingress
(a verified webhook signature, the machine token) proves *who* is emitting, not
*what* they may emit. Without a second constraint, a machine-token holder could
`POST` a `notion.ticket.deleted` or a `lane.member.retracted` and drive a
fan-out delivery — including to a Path-1 auto-cancel fleet-control consumer (see
*Retraction-driven consumer patterns*), which is "authorized by definition" —
that only a verified source ingress or the platform's own membership diff should
ever produce.

Therefore **each ingress kind is registered with the event-type namespace(s) it
is permitted to originate, and the platform MUST reject, at ingress, any event
whose `type` falls outside the set its kind is permitted to originate**, with a
`Fix:` naming the ingress kind and the disallowed `type`. The constraint is
fixed at ingress **registration** (per ingress kind, not per event) and
re-checked on every event, so a crafted payload cannot bypass it.

**This origination-permission registration is DISTINCT from the per-(source, type)
type registry** (see *Membership rules and the lane-membership store* and *Payload
fields and their types per event type*), and the two never overlap. This
registration governs **origination permission** at the **namespace** grain, keyed
**per ingress kind** — "may THIS transport mint this type?", an
authorization/security control. The per-(source, type) **type registry** governs a
type's **direction class and payload schema**, keyed **per (source, type)** and
shared across all of that source's ingress kinds — pure semantic classification.
They answer different questions, so neither is "authoritative over" the other and
there is no ambiguity between them.

The first-pass permitted-origination rule:

- **Membership-derived types (`lane.member.added`, `lane.member.retracted`) are
  PLATFORM-INTERNAL.** They are produced ONLY by the platform's own membership
  diff (see *Membership rules and the lane-membership store*). **NO ingress of
  any kind** — inbound-webhook, poller, or harness-emit — may originate a
  `lane.member.*` event; an ingress-originated `lane.member.*` event MUST be
  rejected with a `Fix:`.
- **Source-emitted webhook types (`slack.*`, `notion.*`) are
  VERIFIED-INGRESS-ONLY.** They may be originated ONLY by the inbound-webhook
  ingress (or the reconciliation poller) for that source, whose sender
  verification established that the change is real (the poller does no HMAC, but
  reads the source directly under its own authorized token, so it is likewise an
  authorized originator of that source's types). **Harness-emit MUST NOT be
  able to synthesize a source-emitted webhook type** — a machine-token holder
  cannot mint a `notion.ticket.deleted` or a `slack.message.received` that no
  verified webhook produced; such an event MUST be rejected with a `Fix:`.
- **Harness-emit** may originate only `type`s in the namespace reserved for
  fleet/harness events (e.g. `fleet.*`), never a source-emitted or a
  membership-derived type.

This is the origination dual of the `source`-is-not-authz rule: `source` governs
what a label may *earn*, and this governs what an ingress may *mint*. Both are
required to stop a machine token from manufacturing a platform-internal or
verified-source transition.

**First pass registers ONLY Notion as a membership-capable source.** The
per-(source, type) type registry (see *Membership rules and the lane-membership
store*) is **designed** to carry a forge or any other source — the mechanism is
source-agnostic — but the **first pass registers only Notion** as a
membership-capable source. This removes, for now, the burden of proving
multi-source coherence (per-source snapshot capability, per-source direction
classes across N sources, and the type-unregistration lifecycle — see the
append-only type registry under *Membership rules and the lane-membership
store*). **Multi-source membership and
the type-unregistration lifecycle are roadmap**, landing as one increment; only
the first-pass *registration* is single-source, and the mechanism it registers
against does not change. (`notify` rules on `slack.*` are unaffected — this bounds
only which sources may feed a **membership lane**.)

---

## Handling rules — fan-out, predicate-driven, config not code

A rule is **config the platform evaluates, never executable code**. A rule
carries: the `event_type(s)` it applies to, its **predicate** (see *The predicate
grammar*), its **kind** (`notify` / `membership`), its **adapter + target** (see
*Delivery adapters* and *Both-ends-or-silently-dark*), its **template + format**
(see *Templating and the per-adapter Escaper contract*), its **enabled flag +
dedupe window** (see *Enabled flag and dedupe window*), and — **only when it is a
`notify` rule declaring a `lane.member.*` event type** — a **`source_lane`**
naming the membership rule (lane) whose transitions it consumes (see *Binding a
`notify` rule on a `lane.member.*` transition*). Every field named here has a
normative section behind it; there are no dangling schema entries.

### Rule ownership is stamped from the authenticated author

A rule carries an `owner`, and Path 1's entire safety argument is that the
owner's own configured rules are "authorized by definition" (see *Trust posture —
two paths*) — including a fleet-control **auto-cancel of an in-flight captain**
(see *Retraction-driven consumer patterns*). A rule authored with **someone
else's** `owner` is therefore a direct escalation into that account's fleet and
destinations. Therefore **a rule's `owner` MUST be stamped from the authenticated
author's session at create/edit time, and MUST NEVER be accepted from the request
body.** An attempt to create or edit a rule whose `owner` is any account other
than the authenticated author's MUST be refused with a `Fix:` (name that a rule
may be authored only for the authoring account). No "admin" or "on-behalf-of"
path widens this in the first pass.

**This completes the owner-binding triad — three authenticated-identity stamps,
plus a fourth inheritance seam for derived events.** Every seam at which an
`owner` enters the system fixes it from an **authenticated identity**, NEVER from
a request/payload body:

1. **Event owner — ingress-stamp.** An ingress-originated event's owner is
   stamped from the authenticated ingress, never read from the payload (see *The
   event*). Stops an account **minting** another's events.
2. **Delivery target — target-bind.** A rule's target MUST resolve to a
   machine/channel registered to the rule's owner (see
   *Both-ends-or-silently-dark*). Stops an account **delivering into** another's
   surfaces.
3. **Rule authoring — author-stamp.** A rule's `owner` is stamped from the
   authenticated author (this section). Stops an account **authoring rules
   under** another's authority.
4. **Derived event — derived-inherits-rule-owner.** A platform-derived
   `lane.member.*` event (no ingress to stamp from) inherits the `owner` of its
   originating membership rule — the rule's own author-stamped owner from seam 3,
   never a caller-supplied value (see *The event*). This is what makes the
   `owner` MUST satisfiable for derived events.

Seams 1–3 stamp the owner from an authenticated identity; seam 4 inherits it from
an already-stamped rule owner. In every case an `owner` is an
authenticated-identity fact, never a caller-supplied one.

**Owner-scoping of ACCESS to an existing rule — the read/mutate dual of the
stamps.** The four seams above fix how an `owner` is **written** — stamped onto
events, stamped onto a rule at authoring, inherited by a derived event: the
*entry* axis. They do not by themselves govern **access to an already-stored
rule**, which is a distinct and equally first-class MUST: **read, list, edit,
delete, disable, and enable of a rule MUST be scoped to the rule's owning
account.** An actor MUST NOT read, list, edit, delete, disable, or enable a rule
owned by any account other than its own authenticated account; each such attempt
MUST be refused with a `Fix:` (name that a rule is accessible only to its owning
account). The author-stamp (seam 3) does not cover this — it fixes only the
`owner` a *new or edited* rule is written with, and says nothing about who may
reach an existing rule to read or mutate it. This matters on both axes:

- **Read / inspect.** A rule's **inspection surface** — the queryable, plaintext
  config the *Config vs secret* boundary deliberately keeps unencrypted "to run
  and debug rules" (predicates, targets, templates, and the workspace / channel /
  person / label IDs they name — see *Config vs secret — the encryption boundary*)
  — MUST be scoped to the owning account. Plaintext-for-diagnostics MUST NOT mean
  cross-account-readable: an ID grants nothing without a credential, but the *map*
  of another owner's channels, people, targets, and predicates is itself a
  disclosure.
- **Mutate.** Deleting or disabling another owner's `membership` rule **destroys
  their lane** and, per *Retraction-driven consumer patterns*, their
  retraction-driven **auto-cancel path**; editing another owner's rule silently
  re-points their deliveries. Each is a direct attack on that account's fleet and
  surfaces.

This mirrors the dead-letter store, whose read access this contract already scopes
to the owning account's (see *Event disposition and dead-letter*). Together with
the four stamping seams it makes the owner-binding honest on **both** axes — an
`owner` is fixed from an authenticated identity when it **enters** (stamp), and it
gates **who may read or mutate** the thing thereafter (scope); neither axis alone
is sufficient, so the "every seam" claim above is the write half of a security
story whose read/mutate half is this MUST.

### Enabled flag and dedupe window

Two owner-facing schema fields carried by every rule:

- **`enabled`** — a boolean gate. Only **enabled** rules are evaluated (see
  *Fan-out: every match fires*); a disabled rule is inert — it neither matches,
  fires, nor contributes to the dead-letter "handled" accounting (see *Event
  disposition and dead-letter*) — and MAY be re-enabled. **Re-enabling a `notify`
  rule is lossless**: it is stateless, so it simply resumes matching present
  events. **Re-enabling a `membership` rule is NOT automatically lossless**: while
  disabled the rule saw no events and its stored set **froze**, so entities that
  left scope during the disable window (deleted, relabelled, reassigned) are still
  stored members and entities that entered are still missing — and the incremental
  per-event path can never notice, because it only re-diffs an entity that later
  receives a triggering event. Re-enabling a `membership` rule therefore MUST run
  the **full reconciliation sweep** (see *Membership rules and the lane-membership
  store* → *The reconciliation sweep*) — reconciling the frozen stored set against
  a fresh snapshot and emitting the missed `add`s/`retract`s — **before the rule is
  considered live**. Only after that sweep is the "no loss" property restored; a
  re-enable that skipped it would silently keep the members that left scope during
  the disable window, the silent set-corruption this document refuses throughout.
  **DELETE — as distinct from disable — of a `membership` rule tears down its
  lane-membership store partition**: the `(owner, membership-rule)` set no longer
  exists, alongside the invalidation of its `source_lane` consumers (see *Binding
  a `notify` rule on a `lane.member.*` transition*, the referential-integrity
  lifecycle). Disable **freezes** the set (and re-enable sweeps it, above); delete
  **removes** it — the last store-lifecycle case, closed.
- **`dedupe window`** — an **owner-facing rate control**, deliberately distinct
  from the correctness-guaranteeing `idempotency_key` (see *Idempotency is per
  (event, rule)*). The idempotency key prevents a **re-processed same delivery**
  from firing twice — a correctness guarantee, always in force. The dedupe window
  is an owner **preference** that collapses **distinct** deliveries of the same
  rule within a time window into one ("don't DM me about this lane more than once
  an hour"). It is a **duration** (unit: **seconds**; **default: `0`** = no
  windowing, every distinct delivery fires). **The dedupe window is a
  `notify`-only rate control.** A `membership` rule's `add`/`retract` transitions
  are **never** collapsed by it: their fold **is** the working set, so suppressing
  a distinct `retract` would corrupt the set (and drop exactly the
  cancel-in-flight that must fire) — that is set corruption, not rate control.
  Only `notify` deliveries are windowed. **What the field MEANS on a `membership`
  rule is defined at save time, never left to be silently ignored:** a
  `membership` rule MAY carry only the inert **default (`0` = no windowing)**; a
  `membership` rule whose dedupe window is set to any **non-zero** value is a
  **save-time HARD ERROR** with a `Fix:` (drop the dedupe window — it is a
  `notify`-only rate control, and a membership rule's `add`/`retract` transitions
  are the working set, never rate-collapsed). This is the same discipline as the
  `event.type`-in-a-membership-predicate hard error (see *Predicates match the
  present; the membership diff handles the past*): owner config that cannot be
  honored is refused **where it is authored**, never accepted-and-silently-inert —
  a silently-ignored rate control would read to the owner as "my lane is
  throttled" while every transition still fires, the loud-not-dark rule this
  document holds throughout. A suppression within the window MUST
  be **observable** — recorded and countable as "suppressed by dedupe window",
  **never a silent drop** (the document legislates against silent drops
  throughout — failed-lookup discipline). The two mechanisms are **orthogonal**:
  the dedupe window never widens or narrows the idempotency key, and a window of
  `0` leaves idempotency untouched.

### Fan-out: every match fires

One event MUST be evaluated against **all** of the owner's enabled rules, and
**every** matching rule fires **independently**, each producing its own delivery.
There is **no first-match, no rule ordering, and no short-circuit.** A single
"ticket updated" event whose **assignees include Cody** (a `contains` match —
`assignee` is a collection) **and** whose labels contain `Flaky Test` fires BOTH
a "DM me in Slack" rule AND a "push to flaky lane" rule → two
independent deliveries, each with its own per-`(event, rule)` idempotency and
retry.

### Two rule kinds

- **`notify` (stateless).** Predicate matches the present event → render + escape
  → dispatch to an adapter. Fires per event. The "DM me when assigned" case.
- **`membership` / lane (stateful).** The predicate defines a **set**; the
  platform maintains the derived membership per `(owner, rule)` in the
  lane-membership store (see *Membership rules and the lane-membership store*).
  Each **relevant event** — the rule's declared predicate types, its
  exit/deletion types scoped to stored members, and its re-entry types scoped to
  non-members, as defined in that section — →
  enrich current state → re-evaluate the predicate → diff
  against the stored set → emit an `add` or `retract` transition, which drives
  the delivery. That emitted transition is **disposition (a) — DELIVERED by this
  originating membership rule** (its own delivery is the handling), so it is
  **never dead-lettered** merely because no separate `notify` rule matches it
  (see *Event disposition and dead-letter*).

### The predicate grammar

A predicate is a **JSON tree**, evaluated by the platform; it is never code.

**Comparison leaf:**

```
{ "field": <field-path>, "op": <comparator>, "value": <literal> }
```

- **field-path** addresses the event with a dotted path to a **bounded depth**,
  drawn from a **closed, enumerated field set** (below), not an open document.
  A field-path **outside** that set — a misspelling like `payload.asignee`, a
  nonexistent `payload.lables` — is a **hard error at rule-SAVE time**, NOT an
  `absent` match (see the evaluation contract). A path that names a **known**
  field of the set which is simply missing from a given event's payload
  evaluates to **absent** (matchable — see the evaluation contract), never an
  error. The two dispositions are distinct and MUST NOT be conflated: an
  **unknown** path is rejected at save time; a **known** path missing at runtime
  is `absent`.

  **The enumerated field set** is closed, not an open document, and each field
  carries a declared **type and cardinality** (see *Payload fields and their
  types per event type*):
  - **Envelope fields:** `event.type`, `event.source`, `event.occurred_at`
    (all scalar). (`owner` is not matchable — a rule belongs to exactly one owner
    and never matches across owners.)
  - **Payload fields:** the `payload.*` fields the **declaring type's closed
    payload schema** lists — e.g. for a `notion.ticket.updated` event (an
    enriched ticket type) `payload.status` (scalar), `payload.labels`
    (collection), `payload.assignee` (collection), `payload.title` (scalar),
    `payload.ticket_number` (scalar); every enumerated type, including
    `notion.ticket.deleted` (narrower — see *Payload fields and their types per
    event type*) and the membership-derived ones, has such a schema.

  Because a rule declares the `event_type(s)` it applies to, the platform
  validates every field-path in the rule against the **union of those types'
  declared payload schemas** at save time — both that the path exists and that
  the operator's cardinality matches the field's (see the comparators below and
  the evaluation contract). A field-path is valid when it appears in **any** one
  of the rule's declared types' schemas (the union); **at runtime, on an event
  whose specific type does not carry that field, the path evaluates to `absent`
  by design** — e.g. `payload.changed_properties` is declared only on
  `notion.ticket.updated`, so a rule spanning `notion.ticket.created` and
  `notion.ticket.updated` binds it at save time and it reads `absent` on a
  `created` event. This is the intended interaction of union-binding with the
  known-field-missing `absent` rule, not a gap.
- **comparators:**
  - `eq`, `ne`, `lt`, `lte`, `gt`, `gte` — scalar comparison.
  - `in` — scalar is a member of the literal set.
  - `contains` — a collection field contains the literal (e.g. a multi-select
    `labels` contains `"Flaky Test"`).
  - `intersects` — a collection field's intersection with a literal set is
    non-empty (e.g. `assignee` ∈ {Cody, Athena}).
  - `exists` / `absent` — presence / absence of the field on the **current**
    payload (the matchable form of a cleared assignee or a removed field). These
    are **presence operators**: they take **no `value`**. A `value` supplied
    alongside `exists`/`absent` is a **save-time HARD ERROR** with a `Fix:` (drop
    the `value` — `exists`/`absent` test only presence; to compare the field's
    value use `eq`/`ne`/`in`), **never silently disregarded**. Silently ignoring
    it is the accept-and-silently-inert pattern this document refuses everywhere
    (the membership dedupe-window and `event.type`-in-a-membership-predicate hard
    errors): `{"field":"payload.status","op":"absent","value":"done"}` reads to
    the author as *"status is not done"* but would evaluate as *"status is
    missing"* — wrong, not empty — so it MUST be loud where it is authored, not
    silently mis-evaluated where it runs.

**Operators are typed to the field's cardinality.** `eq`, `ne`, `lt`, `lte`,
`gt`, `gte`, `in` are **scalar** operators; `contains` and `intersects` are
**collection** operators; `exists` / `absent` apply to a field of either
cardinality. An operator whose cardinality does not match the bound field's
declared cardinality (see *Payload fields and their types per event type*) is a
**save-time HARD ERROR**, not a dispatch-time non-match:
`{"field":"payload.status","op":"contains"}` (a collection op on a scalar) and
`{"field":"payload.labels","op":"eq"}` (a scalar op on a collection) are both
rejected at save time with a `Fix:`. A wrongly-typed operator is a
wrongly-computed key — it would otherwise match nothing forever, the same
failed-lookup class as an unknown field-path.

**Operators are ALSO typed to the field's declared TYPE — the declared `Type`
column (see *Payload fields and their types per event type*) is CONSUMED at save
time, not decorative.** In addition to the cardinality check above, the platform
save-time-checks each leaf — its comparator **and** its `value` literal(s) —
against its bound field's declared **type**, with **no cross-type coercion**:

- **Ordering comparators `lt` / `lte` / `gt` / `gte` apply ONLY to an ORDERED
  type** — a `timestamp` (e.g. `event.occurred_at`) or a numeric field. On a
  `string`, `person-id`, or enum field they are a **save-time HARD ERROR** with a
  `Fix:` (naming the field, its declared type, and that ordering compares only
  ordered types). `{"field":"payload.title","op":"gt","value":5}` — an ordering
  comparator on a `string` — is rejected at save on this ground.
- **The `value` literal(s) MUST match the bound field's declared type** — for
  `eq` / `ne` / `in` the field's own type, for `contains` / `intersects` the
  collection's element type. A literal of the wrong type (a number against a
  `string` field, a string against a `timestamp` field) is a **save-time HARD
  ERROR** with a `Fix:` (naming the field, its declared type, and the offending
  literal). The same example fails this check too — the numeric `5` against the
  `string` `title`.
- `eq` / `ne` compare within a single type; `exists` / `absent` are
  type-agnostic presence operators and take no `value` (above).

A wrongly-typed comparator or literal is a wrongly-computed key — it would
otherwise match nothing (or evaluate undefined) forever, the same failed-lookup
class as an unknown field-path or a cardinality mismatch. This is what the
`Type` column is **for**: a rule that declared it but never enforced it would be
a declared-but-unused column implying a check that is not there.

**Boolean nodes:** `{ "all": [ … ] }` (AND), `{ "any": [ … ] }` (OR),
`{ "not": <node> }`. A predicate is therefore an **arbitrarily nested tree** of
boolean nodes over comparison leaves (e.g. `all[ any[a, b], not[c], d ]`),
bounded only by a depth/size cap.

**Evaluation contract.** Predicate evaluation MUST be **pure, total,
deterministic, and side-effect-free** (Domain code, per `~/dev/custom/ai/CLAUDE.md`
→ *Architecture*). No arithmetic beyond comparison, no regex, no code, fixed
and save-time-checked value types (no cross-type coercion — see *Operators are
ALSO typed to the field's declared TYPE*), bounded depth/size. Specifically:

- **`absent` is reserved for a KNOWN field missing from a given payload.** A
  field-path that is in the enumerated field set but not present in *this*
  event's payload evaluates to `absent` — matchable by `absent`/`exists`, and a
  leaf that reads it yields a defined non-match rather than a crash. Evaluation
  MUST NEVER throw on a known field that is missing at runtime.
- **An UNKNOWN field-path is a HARD ERROR at rule-SAVE time, never an `absent`
  match.** Every field-path in a predicate MUST be bound, at save time, to the
  enumerated field set (against the union of the rule's declared
  `event_type(s)`' payload schemas — see *The predicate grammar*). A path
  outside that set — a misspelled or nonexistent field — is rejected with a
  `Fix:` naming the offending path and the nearest valid field. This is the
  failed-lookup discipline (`~/dev/custom/ai/CLAUDE.md` → *A failed lookup must
  never look like an empty one*): a wrongly-computed key — a misspelled field —
  otherwise silently matches nothing forever, indistinguishable from a correct
  field that legitimately matched nothing. `absent` (a known field missing at
  runtime) and a save-time reject (an unknown field-path) are the two distinct
  dispositions, and an implementation MUST NOT collapse the unknown path into the
  runtime `absent` case.
- **An operator incompatible with its field's declared CARDINALITY is a HARD
  ERROR at rule-SAVE time** — a collection operator (`contains` / `intersects`)
  on a scalar field, or a scalar operator (`eq` / `ne` / `lt` / `lte` / `gt` /
  `gte` / `in`) on a collection field. It is rejected with a `Fix:` naming the
  field, its declared cardinality, and the compatible operators, never left to
  match nothing at dispatch — the same failed-lookup class as an unknown
  field-path, one binding step further in.
- **A comparator or value literal incompatible with its field's declared TYPE is
  a HARD ERROR at rule-SAVE time** — an ordering comparator (`lt` / `lte` / `gt`
  / `gte`) on a non-ordered field (`string`, `person-id`, enum), or a `value`
  literal whose type does not match the bound field's declared type (see
  *Payload fields and their types per event type* and *Operators are ALSO typed
  to the field's declared TYPE*). Rejected with a `Fix:` naming the field, its
  declared type, and the compatible comparators / value type — never left to
  match nothing or evaluate undefined at dispatch. This consumes the declared
  `Type` column; it is not decorative.
- **A `value` supplied on a presence operator (`exists` / `absent`) is a HARD
  ERROR at rule-SAVE time** with a `Fix:` (drop the `value`; use `eq` / `ne` /
  `in` to compare a value). `exists` / `absent` test presence only; silently
  ignoring a supplied `value` would let `{"op":"absent","value":"done"}` — which
  the author means as *"not done"* — evaluate as *"missing"*, the
  accept-and-silently-inert pattern refused throughout (see the grammar's
  presence-operator bullet).
- **A `membership` rule whose predicate references `event.type` is a HARD ERROR
  at rule-SAVE time** with a `Fix:` — it would defeat directional re-evaluation
  and make the lane silently never retract (see *Predicates match the present;
  the membership diff handles the past*).
- **A malformed predicate is a HARD ERROR at rule-SAVE time**, naming the fault
  with a `Fix:` (which node, which field, what is wrong — including an unknown
  field-path per the bullet above). It MUST NOT be a silent eval-time non-match
  at dispatch. A bad rule must be **loud where it is authored, not dark where it
  runs** — a malformed rule that silently matches nothing is indistinguishable
  from a correct rule that legitimately matched nothing.

**Binding a `notify` rule on a `lane.member.*` transition — the lane is named,
so the display shape resolves at save.** A `notify` rule's schema (see *Handling
rules*) names no source: its fields are `event_type(s)` + predicate + kind +
adapter/target + template/format + enabled + dedupe window. A `lane.member.*`
transition, however, has a display shape declared **per lane SOURCE** (see
*Payload fields and their types per event type*), and an owner's lanes may have
**different** sources with **different** display shapes. A `notify` rule declared
on `lane.member.added` / `lane.member.retracted` therefore matches transitions
from **every** one of the owner's lanes, and the validator would have no single
lane from which to resolve a display shape — leaving a `payload.<display-field>`
leaf or template slot bindable against no closed schema. That is precisely the
failed-lookup class this document forbids: a display path drawn from a different
lane's shape is an unknown path at runtime, which the *Evaluation contract* says
MUST NOT collapse into `absent`. Therefore:

- **A `notify` rule that declares ANY `lane.member.*` event type MUST also
  declare `source_lane`** — the id of the membership rule whose lane it consumes.
  This field (a) **scopes matching**: the rule applies only to `lane.member.*`
  events whose `payload.rule_id` equals the named `source_lane`, so it never
  receives another lane's transitions with an incompatible display shape; and (b)
  **resolves the source at save time**: the named membership rule is declared on
  a source (its own `event_type(s)`), which fixes that lane's declared display
  shape, against which the platform validates every `payload.<display-field>`
  leaf and template slot — the same save-time binding a source-emitted type gets.
- **A `notify` rule declaring a `lane.member.*` type WITHOUT a `source_lane` is a
  save-time HARD ERROR** with a `Fix:` (name the `source_lane` — the membership
  rule whose lane this rule consumes — so the display shape can be resolved). A
  `source_lane` naming a nonexistent rule, a non-`membership` rule, or a rule
  owned by a different account is likewise a save-time HARD ERROR with a `Fix:`
  (the second and third reuse the rule-authoring owner check — see *Rule
  ownership is stamped from the authenticated author*).
- **`source_lane` is meaningful ONLY on a `notify` rule declaring a
  `lane.member.*` type.** Present on any other rule (a `membership` rule, or a
  `notify` rule with no `lane.member.*` type) it is a save-time HARD ERROR with a
  `Fix:` (drop `source_lane`; it names the lane a `lane.member.*` consumer reads).
- **A `source_lane` reference gets the same referential-integrity lifecycle as a
  `rule.target` → machine-record reference** (see *Both-ends-or-silently-dark* →
  the record-immutability point, which "invalidates the dependent rules,
  refused/flagged with a `Fix:`"). It reuses that proven pattern rather than
  inventing a new one, so a `source_lane` can never be left silently dangling or
  silently killed:
  - **DELETE of the referenced membership rule → its `source_lane` dependents are
    INVALIDATED**, exactly as re-homing a machine record invalidates its dependent
    rules: each consuming `notify` rule is **refused/flagged with a `Fix:`** naming
    the now-missing lane (`source_lane` <id> no longer exists — re-point this rule
    at an existing lane, or remove it), asserted **at delivery and on the rule's
    next edit**. The reference is never left dangling. This is chosen over refusing
    the membership rule's deletion while dependents exist — it matches the
    machine-record precedent and does not let one rule's dependents block another
    rule's deletion.
  - **DISABLE of the referenced membership rule → the lane stops emitting; its
    `source_lane` dependents become INERT but OBSERVABLE, not invalidated.** A
    disable is reversible, so a hard invalidate would be wrong; instead a consumer
    whose `source_lane` is **disabled** is surfaced by the **existing**
    "a lane matching zero over a long window MUST be reported" rule (see
    *Both-ends-or-silently-dark*), extended to that case — never left silently
    quiet. Re-enabling the membership rule (which already runs the reconciliation
    sweep — see *Enabled flag and dedupe window*) resumes the consumers.

The **source-agnostic** fields of a `lane.member.*` event — the envelope
(`event.type`, `event.source`, `event.occurred_at`) plus `payload.rule_id`,
`payload.lane`, `payload.op`, and `payload.entity_id` — are guaranteed across
**all** lanes regardless of source and so bind for such a rule with or without
`source_lane`; it is the **per-source display fields** that `source_lane`
additionally makes bindable. This is chosen over restricting `lane.member.*`
rules to the source-agnostic fields alone precisely because the headline
retraction-message use case (*Retraction-driven consumer patterns*) renders the
per-source display fields — the ticket number and title — which the entity_id
handle alone cannot.

### Predicates match the present; the membership diff handles the past

Two composition mechanisms are **deliberately delineated**, and an implementation
MUST NOT blur them:

- **The in-event predicate tree matches ONLY the present** — the current event
  plus its enriched payload. It MUST NEVER read prior state. There is no
  before-value in the event to compare against.
- **The membership diff handles "was-a-member / now-not"** transitions —
  deleted-that-had-the-label, label-removed, assignee-changed-out. That direction
  is **not expressible as a predicate** (there is no prior value in the event);
  it is derived by diffing the current predicate result against the
  lane-membership store.

So a `notify` rule is a predicate tree over the present event; a `membership`
rule is a predicate tree defining set membership **plus** the store diff that
turns enter/leave into `lane.member.added` / `lane.member.retracted`. A predicate
is never asked to know history; the store is.

**A `membership` rule's predicate is evaluated over the enriched current payload
only, and MUST NOT constrain `event.type`.** The rule's declared `event_type(s)`
— plus the directional exit/re-entry scoping (see *Membership rules and the
lane-membership store*) — are the **trigger** set (*when* to re-evaluate); the
predicate decides **what is in the set** from the entity's current state
(assignee, labels, status). Gating a membership predicate on `event.type` would
defeat directional re-evaluation: a `notion.ticket.undeleted` (re-entry) or
`notion.ticket.deleted` (exit) trigger carries a *different* `type`, so an
`event.type in [created, updated]` leaf would fail on it and re-entry/exit could
never re-evaluate. (`event.type` remains a normal, valid leaf for a `notify`
rule, which matches the present event and is never re-evaluated over state.)
Because `event.type` is otherwise a valid enumerated envelope field, a validator
built to spec would accept such a predicate and the lane would then **silently
never retract** — the failed-lookup class — so a **`membership` rule whose
predicate references `event.type` in any leaf is a save-time HARD ERROR** with a
`Fix:` (drop the `event.type` leaf; declare the trigger types in the rule's
`event_type(s)` instead). This is folded into the same rule-save validation as an
unknown field-path or an operator/cardinality mismatch (see the *Evaluation
contract*), not left as a bare prohibition.

**Worked owner examples:**

- *"ticket assigned where the assignees include me → Slack DM"* (`notify`):
  `{all:[{field:"event.type",op:"in",value:["notion.ticket.created","notion.ticket.updated"]},
  {field:"payload.assignee",op:"contains",value:"<cody-person-id>"}]}` → Slack
  adapter. (`payload.assignee` is a **collection** — a Notion people property
  holds zero or more people — so it is matched with `contains` / `intersects`,
  never the scalar `eq`; both worked examples here use collection operators on
  it, consistent with its declared cardinality.)
- *"assignee ∈ {Cody, Athena} AND label 'Flaky Test' present → flaky-lane inbox
  channel"* (`membership`; **trigger `event_type(s)`** declared *separately* from
  the predicate: `notion.ticket.created`, `notion.ticket.updated`, to which the
  engine adds the directional `notion.ticket.deleted`/`undeleted` scoping):
  `{all:[{field:"payload.assignee",op:"intersects",value:["<cody>","<athena>"]},
  {field:"payload.labels",op:"contains",value:"Flaky Test"}]}` → inbox adapter,
  flaky channel; the membership diff emits `add`/`retract`. The predicate does
  **not** gate on `event.type` (see above), so it re-evaluates correctly on a
  delete or undelete trigger.

The router evaluates all rules with a pure matcher, a pure renderer, and a pure
membership-diff (Domain), and dispatches through adapters and the membership store
(Side Effects). Generic router code is tenant-blind: it takes the owner's rules as
input and contains none.

---

## Membership rules and the lane-membership store

The lane-membership store is the platform's **source of prior state**, and it is
what makes retraction reliable **without** source deltas.

**A membership rule's "relevant events" (the re-evaluation scope) — defined.**
The term "relevant event" is load-bearing: the store's headline guarantee (a
`notion.ticket.deleted` on a stored member emits a `retract`) rests on it, and a
naive "the rule's declared predicate event types" reading breaks it — the worked
flaky example declares `notion.ticket.created` / `notion.ticket.updated`, so a
delete would never reach the rule and **no retract would ever fire**, the one
case the store exists to solve. A membership rule is therefore re-evaluated on
the **union** of three trigger sets, each with its own scope:

- **(a) its declared predicate event types** (the entry/update triggers — e.g.
  `notion.ticket.created`, `notion.ticket.updated`), evaluated for the entity the
  event is about.
- **(b) exit/deletion types** (e.g. `notion.ticket.deleted`) **scoped to CURRENT
  stored members** of that `(owner, membership-rule)` — a stored member that is
  deleted emits a `retract`.
- **(c) re-entry types** (e.g. `notion.ticket.undeleted`) **scoped to
  NON-members that PASS the predicate after enrichment** — a previously-retracted
  entity that reappears and again satisfies the predicate emits an `add`.

The direction is what makes (b) and (c) different scopes, not one "exit/deletion"
set: a deleted entity is **still** a stored member, so its retract is
member-scoped (b); an **undeleted** entity was retracted on delete and is
therefore **not** a current member, so scoping undelete to members would mean it
could never re-enter — undelete is a **re-entry** trigger scoped to non-members
(c). The membership engine MUST subscribe a membership rule to all three sets,
not only its declared predicate types (equivalently, the rule MAY declare its
full trigger set), so that both retract-on-delete and re-add-on-undelete provably
fire. An (b)/(c) event for an entity outside its scope — a delete of a non-member,
an undelete of something that still fails the predicate — is simply not relevant
to that rule.

**The direction class of each type is a per-source DECLARED classification, not
by-example and not inferred.** The classes named above (`notion.ticket.deleted`
as exit (b), `notion.ticket.undeleted` as re-entry (c), `created`/`updated` as
entry (a)) are **Notion's** classification, given here as the first-pass
instance. Under the open taxonomy (see *The event taxonomy is open*) a new
membership-lane source adds its own types with no schema change, and the engine
can compute a rule's (b)/(c) subscriptions for that source **only if it knows
each type's direction**. Therefore a source that can feed a membership lane MUST
declare, for each of its types, its **direction class** — (a) entry/update,
(b) exit/deletion (member-scoped), or (c) re-entry (non-member-scoped) — in the
**per-(source, type) type registry**: a source-level registration **distinct
from** the per-ingress-kind origination-permission registration, with a different
key and a different job (see *Which event types an ingress kind may originate*).
Because the direction class is a property of an event type within a source's
taxonomy — pure semantics, identical whichever transport (a verified webhook or
the reconciliation poller) delivered the event — it resolves to **exactly one**
record per (source, type), never the two-divergent-or-none an anchor to the
per-ingress-kind registration would produce. The membership
engine derives the (b)/(c) subscriptions from that classification, so
retract-on-exit and re-add-on-re-entry provably fire for **any** source, not only
Notion. A membership rule declared on a source type that has **no** declared
direction class is a **save-time HARD ERROR** with a `Fix:` (classify the type in
the per-(source, type) type registry, or declare the rule's full trigger set
explicitly) —
this is exactly the **silent-never-retract** this section exists to prevent, made
loud at authoring rather than dark at runtime; a new source's exit/re-entry types
arriving unclassified must not silently produce a lane that never retracts. The
"the rule MAY declare its full trigger set" formulation above remains valid as an
explicit per-rule **override**; the mandatory per-source classification is what
lets the engine subscribe correctly for a source the rule did **not** fully
enumerate — which, under the open taxonomy, is the common case, so the
classification is the primary line of defense and the declared set is the
supplement, never the reverse.

**The per-(source, type) type registry also records a source-level full-snapshot
capability.** Alongside each source's per-type direction classes and payload
schemas, the registry records one **per-source fact** — whether the source is
**full-snapshot / poll-capable**, i.e. able to enumerate its current in-scope set
on demand for the reconciliation sweep. This capability is read at rule save time
(see *The reconciliation sweep* → the full-snapshot requirement, which turns it
into a save-time hard error for a source that lacks it).

**In the first pass the per-(source, type) type registry is append-only /
immutable per `(source, type)`**. The registered types are fixed — Notion's
source-emitted types plus the membership-derived set — so **no
type-unregistration path exists** to leave a saved rule bound against a vanished
type, and a saved rule's binding to the type registry cannot dangle.
**Type-unregistration**
would, like a deleted membership rule, have to **invalidate the dependent rules**
that bound their schema/direction class against the removed type; it is therefore
**roadmap**, landing with the same increment that adds multi-source membership
(see *Which event types an ingress kind may originate*). This is enumerated
so it is visibly **not** a gap, not because a first-pass mechanism is missing.

- Per `(owner, membership-rule)` the store holds each member's **`entity_id`**
  (the declared stable source handle, e.g. `notion:<uuid>` — see *Payload fields
  and their types per event type*) plus the **minimal display fields** needed to
  render a retract (e.g. ticket number and title).
- **On each relevant event the pipeline runs PER TRIGGER CLASS** — no single step
  mandates an enrichment a trigger cannot perform:
  - **(a) declared-predicate types:** **enrich** current state → **re-evaluate**
    the predicate → **diff** against the stored set → append `add`/`retract`.
  - **(b) exit/delete types** (e.g. `notion.ticket.deleted`) scoped to CURRENT
    stored members: **diff WITHOUT enrichment**. A deleted stored member fails
    the predicate **by definition**, so emit a `retract` from the **cached**
    display fields — no fetch (the entity may be unfetchable).
  - **(c) re-entry/undelete types** (e.g. `notion.ticket.undeleted`) scoped to
    NON-members: **enrich** → **re-evaluate** the predicate → if it passes,
    append `add`.
- Because the store caches the minimal display fields **at add time**, a
  `retract` can be rendered even after the entity is deleted and can no longer be
  fetched (a `notion.ticket.deleted` on a stored member emits a `retract` from
  the cached fields). This is exactly "deleted-that-had-the-label".
- **The diff for a given `(owner, membership-rule)` MUST be serialized.** It is a
  **read-modify-write** — read the stored set, re-evaluate, diff, append the
  `add`/`retract`, commit the new set — and because of fan-out and
  per-`(event, rule)` retries, two events for the same
  `(owner, membership-rule)` (or a retry overlapping its original) can otherwise
  interleave: both read the same prior set and both commit, producing a
  **duplicate `add` or a lost `retract`**. The read-modify-write MUST therefore
  be applied under a **compare-and-set (atomic read-modify-write)**, a per-`(owner,
  membership-rule)` lock, or an equivalent serialization guarantee. Concurrent
  evaluations against the same `(owner, membership-rule)` MUST NOT both read the
  same prior set and both commit; the losing writer MUST re-read the committed
  set and re-diff against it. Serialization is per `(owner, membership-rule)`;
  distinct rules and distinct owners MAY proceed concurrently.

**On a durably-emitted `retract`, the member's store entry is PURGED.** The store
caches a member's `entity_id` and minimal display fields for exactly one stated
purpose — so a `retract` can be rendered after the entity is gone (above). Once the
`retract` transition is **durably emitted** — appended to the lane channel, and
any `notify` consumers fired — that purpose is served, so the platform **purges the
member's store entry** (`entity_id` + cached display fields). This needs **no owner
retention number**; it is derived from the cache's sole stated purpose, and it
bounds the active store by the lane's **working-set size** (the owner's in-scope
entity count), not by cumulative history — closing the unbounded-store risk.
Consequences, all coherent
by construction:

- **The stored set is thereby exactly the current members** — precisely what the
  reconciliation sweep diffs against, so **purge and sweep agree**: a purged member
  is absent from a later snapshot and yields **no diff** (no spurious re-`retract`);
  a **re-appearing** entity is a class-(c) re-entry (scoped to non-members), which
  **re-enriches** and re-adds, so purge loses nothing on re-add.
- **Idempotency is unaffected:** the per-`(event, rule)` idempotency-key store is
  **separate** from the lane-membership store (see *Idempotency is per (event,
  rule)*), so a **retried** `retract` still dedupes on its key after the member is
  purged — purge removes set membership, not the delivery dedupe record.

**The reconciliation sweep — a full stored-set re-evaluation.** The
per-triggering-event pipeline above is **incremental**: it reacts to one entity's
event and can act only on transitions it actually receives. Some transitions never
arrive on that path — a `retract` dropped while the webhook was down, or every
transition missed while a rule was **disabled** or before its subscription
existed. For these the platform provides a **reconciliation sweep**: a full
re-evaluation of an entire `(owner, membership-rule)` set against a **fresh full
snapshot** of the source's current in-scope set, which — unlike the incremental
path — does **not** depend on receiving any source delta:

- **snapshot passes the predicate but is NOT a stored member → emit `add`** (it
  entered scope while the per-event path was not watching);
- **stored member ABSENT from the snapshot (or present but now failing the
  predicate) → emit `retract`** (it left scope — deleted, label removed,
  reassigned — while the per-event path was not watching).

The sweep's `add`/`retract` transitions run through the **same** per-`(owner,
membership-rule)` serialized diff (the compare-and-set above): a transition the
webhook path already applied is already reflected in the committed stored set, so
the sweep produces **no diff** for it and does not re-emit it — the sweep recovers
only the genuinely-missed ones. Each transition the sweep *does* emit then flows
through the **same** per-`(event, rule)` idempotency and retry machinery as any
other delivery (its key basis is defined in *Idempotency is per (event, rule)* →
membership-derived, sweep case). Diffing **stored-members-absent-from-the-snapshot** is
what makes the store's headline guarantee — retraction **reliable without source
deltas** — hold across a gap the incremental path cannot see, rather than only
across gaps in which the delete/exit event itself was delivered. A sweep that
emitted only the snapshot's new hits (adds) and never diffed the
stored-not-in-snapshot direction would leave a dropped `retract` **unrecovered
forever** — the entity a stored member for good, the lane fold keeping an item
that left scope — which is exactly the **silent-never-retract** class this section
is built to prevent.

**The sweep is invoked at exactly two points, and both cite this definition so the
mechanism cannot drift:**

1. **The low-frequency reconciliation backstop poller** runs it for a membership
   lane (see *Poller (fallback only)*).
2. **Re-enabling a disabled membership rule** runs it before the rule is
   considered live (see *Enabled flag and dedupe window*).

**A membership lane requires a full-snapshot-capable source, and this is checked
at rule SAVE time.** The sweep diffs against a **fresh full snapshot of the
source's current in-scope set**, so the sweep MUST is **unsatisfiable** for a
source that cannot produce one — and a "best-effort sweep" would silently reopen
exactly the silent-never-retract the sweep exists to close. Therefore
full-snapshot / poll capability is a **declared source capability**, homed in the
same **per-(source, type) type registry** that holds the source's direction
classes and payload schema (see *The direction class of each type…* above), and a
membership lane requires a source that is **(i) `entity_id`-bearing** (already —
see *Payload fields and their types per event type*) **AND (ii)
full-snapshot-capable**. **A `membership` rule declared on a source that is NOT
full-snapshot-capable is a save-time HARD ERROR** with a `Fix:` (a membership lane
requires a poll-capable source able to enumerate its in-scope set for the sweep;
this source cannot — use it for a `notify` rule, or add a snapshot capability to
its registration). This is the same save-time-loud discipline as the
Slack-only-membership error (see *Payload fields and their types per event type*),
and it makes the sweep MUST **satisfiable** and its satisfiability **checked where
the rule is authored**. **Notion satisfies it**: the low-frequency reconciliation
backstop already enumerates Notion's in-scope set with its read-only, DB-scoped
enrichment token, so the sole first-pass membership source
is full-snapshot-capable and the sweep MUST is satisfiable in the first pass at
zero extra cost.

**The sweep frequency carries no contract number.** How often the
reconciliation backstop runs is **ops/owner configuration, explicitly outside this
contract's MUST surface** — the contract states **shape** only ("a low-frequency,
owner/ops-configured sweep"), never a cadence. No MUST here carries a frequency
number.

The store is source-agnostic — it carries over to a forge or any other membership
lane — and turns "retraction" from an unanswerable source-delta question into a
store diff. The cached display fields are the owner's own workspace data,
deliberately minimized to what a retract line needs, and remain **Path-2
untrusted** when they reach an LLM (see *Trust posture — two paths*).

### The lane channel is a change stream, not the authoritative set

A membership lane delivered to an inbox `log` channel carries an **add/retract
stream** — `{"v":1,"op":"add"|"retract", …}` lines — and the lane's working set
is `fold(adds − retracts)`. Each line MUST carry the mandatory `v` field that
`ai/contracts/athena-inbox.md` → *Line format* requires on **every** `log` line
(`v` plus the framing rules are the only universal fields; the remaining fields
are this producer's own schema — e.g. `op`, `ticket`, and the minimal display
fields to render a retract). This is still a conformant append-only `log`
channel: the *lines* are appended; the *derived set* is what changes.

- The channel is a **change-notification stream, NOT the authoritative set.** A
  `log` channel is retention-bounded, so the full add/retract history is not
  guaranteed reconstructable from the channel alone after a rotation or a long
  absence. That is intended.
- **The authoritative set is the server-side membership store plus the
  consumer's own authoritative re-query** (e.g. an admiral's Notion re-query). A
  session that reads only a partial stream still gets a correct set from the
  re-query; the stream accelerates the common case and lets an already-running
  consumer shrink scope (drop a retracted item) without a full re-query.
- An unprompted surface still counts new lines only (a change signal); the
  working set is computed by folding add/retract on an explicit fenced read.

---

## Retraction-driven consumer patterns

Because the taxonomy is open, a retraction/transition event can drive **any**
owner-configured action. The platform MUST support at least these consumer
patterns:

- **Set consumers** (the flaky lane) — fold add/retract into a working set;
  on a `retract` for an item in the current working set, drop it.
- **Retraction messages** — a retraction email/Slack message ("ticket X left
  scope / was deleted") via an ordinary `notify` rule on the retract transition.
  The rule names its `source_lane` (see *Binding a `notify` rule on a
  `lane.member.*` transition*), so the retract's per-source display fields — the
  ticket number and title that render "ticket X" — bind against that lane's
  declared shape at save time.
- **Fleet-control cancel-in-flight** — when a ticket is deleted, deprioritized,
  or otherwise retracted while a captain is mid-flight on it, the retraction is
  an event; a rule routes it to a fleet-control consumer that cancels the
  in-flight captain rather than letting it finish work on a ticket that left
  scope. This is the mirror of "spin a captain up". The routing rule is a
  `notify` rule on the `lane.member.retracted` transition and names its
  `source_lane` (see *Binding a `notify` rule on a `lane.member.*` transition*),
  scoping the auto-cancel to exactly the lane whose retraction should trigger it
  rather than firing on any lane's retraction.

**Cancel-in-flight and the trust boundary — Path 1 vs Path 2.** How a retraction
acts on the fleet is governed by which trust path delivers it:

- **Path 1 (auto-cancel) is legitimate as deterministic config the owner
  authored** — the owner's rule authorizes it by definition; the only open
  question is the *delivery mechanism*, answered by the roadmap note below.
- **Path 2 (recommend only)** — a retraction arriving as untrusted *content* into
  an LLM session can only **recommend** a cancel; it MUST NOT self-authorize one.

Which path a given lane uses is config. First-pass builds the **set-consumer** and
the Path-2 **recommend-only** path; the event/predicate/transition model is
specified now to carry the rest.

**Cancel-in-flight fleet control is roadmap.** When it lands it MUST deliver
through a **fixed-destination internal-control adapter** — a platform-operated
control plane on a closed, platform-registered allowlist of control endpoints. It
is classified fixed-destination and therefore carries no generic-webhook egress
model; it is explicitly **NOT** the generic-webhook adapter (whose egress model
would forbid the internal destination it requires) and **NOT** an unclassified
direct call (which the adapter-classification MUST forbids). Its security review
is a precondition of building it.

---

## Delivery adapters

Every platform is split into **inbound** (an ingress: verify sender, content
untrusted at the LLM) and **outbound** (a delivery adapter: format + escape,
credentials). Several platforms are bidirectional; the interface accommodates
both, and build is staged.

### Fixed-destination vs owner-supplied-destination

Every outbound adapter is exactly one of:

- **Fixed-destination** — a known host (Slack, email, SMS, Discord, Notion, and
  the inbox adapter, and — roadmap — a platform-operated fleet-control plane; see
  *Retraction-driven consumer patterns*). It carries **no** egress/SSRF model.
- **Owner-supplied-destination** — the **generic webhook** adapter, which calls
  an arbitrary owner-supplied endpoint. **Only** this adapter carries the
  egress/SSRF model (see *The generic-webhook egress model*), and it ships
  **last, after its own security review**.

An implementation MUST classify each adapter into exactly one of these, and MUST
NOT apply the egress model to a fixed-destination adapter (it would only obstruct
a known-safe destination) nor omit it from the generic-webhook adapter.

### The generic-webhook egress model

The generic-webhook adapter (owner-supplied destination) MUST:

- enforce an owner allowlist;
- reject destinations resolving to loopback, link-local, private, or metadata
  ranges (including `169.254.169.254`, `10/8`, `172.16/12`, `192.168/16`, `::1`,
  `fc00::/7`), with a `Fix:` naming the rejected destination;
- **resolve → validate the resolved IP → connect to that same IP** to close the
  DNS-rebinding TOCTOU window;
- follow no internal redirects; enforce timeouts and size caps; reflect no
  credentials;
- egress from a network position that cannot reach internal services.

The allow-predicate is pure (Domain); the connecting adapter is a hardened Side
Effect. This adapter is **SECURITY-REVIEW-gated and ships last.**

---

## Templating and the per-adapter Escaper contract

The "this content, this format" of a rule. There is **no LLM in this path**
(Path 1), so injection safety here is an **escaping/encoding** obligation, not an
authorization one — but it is a real one: untrusted payload values (a Slack
author's text, a ticket title) flow through it.

### Engine

- **Templates are logic-less** (named-slot interpolation, no arbitrary code
  execution) — a template is data, never a program, so a compromised or erroneous
  template cannot execute. Structured formats (Block Kit, JSON, embeds) MUST be
  built as **data structures then encoded**, never by string concatenation.
- **Auto-escaping is default-ON and context-aware.** Every interpolated value
  MUST pass through the target adapter's Escaper for the surrounding context.
- **Emitting a value raw requires an explicit, owner-marked "trusted" slot.** The
  **generating rule**: a field is **trusted-slot-eligible iff the platform itself
  MINTS its value** — the value is computed by the platform or drawn from a closed
  platform-controlled set, with **no** source-supplied or enrichment-derived
  substring. A field whose value originated at a source, arrived on a webhook, or
  was returned by an enrichment fetch is **never** trusted-slot-eligible, however
  structured it looks. The **closed first-pass trusted set** is exactly:
  - `event.type` — platform-normalized, from the closed taxonomy;
  - `event.source` — platform-stamped, from the closed `source` set;
  - `payload.rule_id` — the platform's own rule identifier;
  - `payload.lane` — the platform's own lane identifier;
  - `payload.op` — platform-minted, closed set `"add"` | `"retract"`.

  **Everything else MUST go through the escaper — the exclusions are enumerated by
  name so the wrong line cannot be drawn silently:** every enrichment-derived /
  source-supplied field — `title`, `ticket_number`, `status`, `labels`,
  `assignee`, `comment_text`, and the Slack fields `text`, `channel`, `user`,
  `ts`, `thread_ts`, `event_id`. **`payload.entity_id` is EXCLUDED** from the
  trusted set: it is the **source handle** (e.g. `notion:<uuid>`) — a
  source-supplied value that only *looks* like a platform-owned identifier — so it
  is escaped like any source field. **`event.occurred_at` is also NOT trusted**: a
  timestamp carries no markup, so escaping it is a no-op and marking it trusted
  would only widen the raw surface for nothing — a field earns trusted status only
  if it is platform-minted **and** has a formatting reason to be raw.
- **A raw/trusted slot referencing any field OUTSIDE the enumerated trusted set is
  a save-time HARD ERROR** with a `Fix:` (name the field; a trusted slot admits
  only a platform-minted field — use an ordinary escaped slot instead). This is the
  same loud-at-author discipline every other unhonorable config gets (the
  membership dedupe-window, the `exists`/`absent`-with-`value`, and the
  `event.type`-in-a-membership-predicate hard errors): the trusted-slot boundary is
  enforced where it is authored, not trusted to be drawn correctly at render time.
- **Trusted-eligibility is READ FROM the per-(source, type) type registry** (see
  *Payload fields and their types per event type* and *Membership rules and the
  lane-membership store*): a field is trusted-eligible only if that registry marks
  it platform-minted, so the trusted set cannot drift out of sync with the payload
  schema.
- The renderer is **pure Domain**; the Escaper is a **per-adapter behaviour**.

### Per-adapter Escaper contract

Each adapter MUST implement `escape(value, context) → safe_fragment`. A new
adapter MUST NOT ship without its escaper, and the templating tests MUST feed
hostile payload values (fence markers, `</script>`, `\r\nBcc:`, `*bold*`,
`{"x":1}`) and assert they render inert in every adapter context.

| Adapter | Contexts + escaping |
|---|---|
| **Slack** | mrkdwn text: escape `&`→`&amp;`, `<`→`&lt;`, `>`→`&gt;`. **Block Kit**: values go into JSON string fields — JSON-encode; build blocks as data structures, never by string concat. |
| **Email** | HTML body: HTML-entity-escape all values. **Headers (Subject/To/From)**: strip/reject CR/LF (CRLF header injection); use a library that separates headers from body — never interpolate into a raw header line. |
| **SMS** | plain text: strip control chars; handle GSM-7 vs UCS-2 encoding and length/segmentation deterministically; no markup to escape, but truncate/segment safely. |
| **Discord** | markdown: escape `* _ ~ ` \| > @`; embeds are JSON — encode, don't concat. |
| **Notion** | rich-text / block JSON: build the block and rich-text objects as **data structures then encode**, never assemble Notion block JSON by string concat; escape/normalize any text run per Notion's rich-text rules and never inject markup through a `text.content` field. |
| **Generic webhook** | JSON body: JSON-encode every value; never string-build JSON; content-type fixed. |
| **Inbox** | a conformant inbox `log` line, per `ai/contracts/athena-inbox.md`; its untrusted body reaches an LLM (Path 2) and is fenced by the inbox contract's *Untrusted input* rules. |

---

## Trust posture — two paths

The untrusted boundary is about content reaching an LLM's **instruction
position**, not about outbound delivery. Two paths, and an implementation MUST
keep them distinct:

- **Path 1 — router → adapter delivery is NOT the untrusted case.** The platform
  executes the owner's own configured rules deterministically; acting on them is
  authorized by definition. The only hazard is **format injection**, handled by
  the per-adapter escapers. Third-party *content* flows here as data, formatted
  per the owner's rule, and is never interpreted as instructions.
- **Path 2 — content reaching an LLM session** (the inbox adapter → client → a
  session reads it): the Athena Inbox contract's *Untrusted input* boundary
  applies **in full** — counts-only unprompted, fenced bodies with a per-render
  nonce, imperatives are facts-to-report, content **informs but never
  authorizes**. This contract does **not** restate those rules; see
  `~/dev/custom/ai/contracts/athena-inbox.md` → *Untrusted input*, which is the
  normative home for them.

**Sender verification authenticates a webhook's source; it never makes that
source's content trusted at Path 2.** A verified Slack webhook still carries a
workspace member's arbitrary text.

---

## Security MUSTs

Each surface below is **SECURITY-REVIEW-gated** before any secret it introduces
is stored.

### Config vs secret — the encryption boundary

State the line precisely so **config is not over-encrypted and no secret is
under-encrypted**:

- **Identifiers are NOT secrets → plaintext per-account config in the product
  DB.** Workspace / team / channel / person / label IDs, DB/view IDs, target
  `inbox_name`s, rule predicates and templates are **configuration**. An ID
  grants nothing without a credential; config must be queryable and inspectable
  to run and debug rules; encrypting it would only obstruct the UI and
  diagnostics. Stored plaintext, per-account.
- **Only actual secrets → KMS envelope encryption.** A secret is anything that,
  if leaked, lets someone **act as** the account against an external service, or
  **forge/verify** its webhooks.
- **The test:** *"does possessing this value let someone do something as us?"*
  Yes → KMS. No (it only names a thing) → plaintext config. An implementer MUST
  NOT encrypt an ID "to be safe" (breaking rule inspection) nor log a token "it's
  just config" (a breach).

### Secret custody

- **The master key is AWS KMS**, provisioned in gen_saas terraform. The
  deploy-secret alternative is dropped.
- Secrets are custodied with **envelope encryption**: a per-secret data key
  wrapped by the KMS master key, held outside the app DB.
- Decrypt is **least-privilege**: only the poller/adapter runtime role may
  decrypt, and nothing else. Decrypt happens **only at use time, in memory, for
  the owning account only** — no cross-account use is expressible.
- A secret MUST NEVER be logged, placed on `argv`, echoed, made API-readable, or
  written into the inbox root.
- The first-pass secret set is: the **Slack bot (`chat.write`) token**; the
  **Notion per-subscription `verification_token`** (the webhook HMAC key); and a
  **read-only, DB-scoped Notion enrichment token**. Any future adapter credential
  (SMTP, SMS, Discord bot) joins this set under the same story.

### Sender verification and payload completeness

- An inbound webhook's signature MUST be verified over the **raw bytes as
  received**, constant-time, hard-rejecting the unverified with a `Fix:` (per
  *Inbound webhook*).
- Where a source's webhook is **metadata-only** (it signals *that* something
  changed and carries entity IDs, but not the changed values — Notion's API
  webhook is so by design), building a useful event **requires an enrichment API
  fetch** on the verified event. Enrichment uses a **least-privilege, read-only,
  DB-scoped** token, **on-demand only** (never on a timer). Enrichment targets a
  **fixed destination**, so it carries **no** generic-webhook egress surface.
- A write-scoped token (e.g. Notion outbound: post comment / update page) MUST be
  **separate** from the read-only enrichment token; do not widen the read token
  to gain write.

---

## Mechanism vs config boundary, and both-ends-or-dark

- **Mechanism = committed `apps/athena` code**, a tenant-blind public exemplar:
  the router, the event value, the rule engine (with no rule), the three ingress
  kinds, the ingress verifiers, the delivery adapters and their escapers, the
  poller runner, the lane-membership store. It carries no
  owner/project/rule/token/channel.
- **Config + secrets = server-side per-account DATA**: handling rules, ticket-lane
  configs, targets, templates, third-party tokens/creds. Never committed.
- **The only harness-side config** is the client inbox **channel declaration** in
  the committed `ai/inbox/registry.json` (in `~/dev/custom`, which owns the
  contracts; tenant repos carry nothing), via the existing `setup-inbox-registry`
  / `check-inbox-registry` tooling.

**Both-ends-or-silently-dark.** A rule routing to the inbox adapter needs BOTH
the server-side target (machine + `inbox_name`) AND the client-side `log`-channel
registry entry, or the client writes where no session's tenancy resolution
declares a channel → zero channels, exit 0, no error (the DND-183/DND-202 class).
Therefore:

- An inbox rule with an **unknown target** MUST be refused with a `Fix:` (name
  the missing target).
- **A rule's delivery target MUST resolve to a machine/channel registered to the
  RULE'S OWNER.** Existence is not enough. The inbox target is a `machine +
  inbox_name` — a **filesystem location**, not a credential-scoped API endpoint —
  so an owner whose rule names *another account's* machine would otherwise get a
  perfectly conformant target and have the platform deliver into that other
  machine's sessions. That is a **cross-account delivery hole**, and it is the
  egress dual of *Which event types an ingress kind may originate*: origination
  stops one account from minting another's events; this stops one account from
  delivering into another's surfaces. A rule whose target is owned by a different
  account MUST be refused with a `Fix:` (name the target and that it is not
  registered to the rule's owner). A **fixed-destination API adapter** (Slack,
  email, Notion) gets this binding for free — it delivers only through the
  owner's own KMS-custodied per-account credential, which cannot reach another
  account's destination — but the **inbox adapter has no such credential** (the
  target is a path), so it MUST enforce the owner↔target binding explicitly.
- **The machine↔owner binding the check reads IS the machine-token registration
  record** — the same server-side per-account record from which harness-emit
  resolves an event's owner ("the owner is resolved server-side from that token",
  see *Harness-emit*). It binds each **`machine id → owning account`**; those two
  fields are all the target-bind check reads. The check resolves the **target
  machine's owning account** from that record and refuses (with a `Fix:`) when it
  is not the rule's owner. This is **per-account server-side data** (consistent
  with *Normative home* — rules, config, and secrets are per-account data), **not
  a committed file and not a second registry concept**; the machine-token
  registration already exists for harness-emit, and the target-bind check reuses
  it.
- **Enforcement is at THREE points, because the inbox target is a filesystem path
  with no credential to fail closed** (a fixed-destination API adapter fails
  closed on its per-account credential; the inbox adapter has none, so the bind
  is asserted explicitly and more than once):
  1. **Save-time bind.** At rule create/edit the target machine's owning account
     is resolved from the record and the rule is refused (with a `Fix:`) if it is
     not the rule's owner — the **same layer** as the rule-authoring owner-stamp
     and predicate save-time validation.
  2. **Delivery-time re-assertion.** Before **each** delivery the platform
     re-resolves the target machine's **current** owner and refuses the delivery
     — **recording it, never a silent drop** — if it is not the rule's owner.
     This closes the window a save-time-only check would leave if ownership
     changed after save, and it is cheap (one record lookup).
  3. **Record immutability per `machine id`.** The machine↔owner registration is
     **immutable per machine**: re-registering a machine to a **different** owner
     does NOT silently re-home existing rules — it **invalidates the dependent
     rules**, which are refused/flagged with a `Fix:` (re-author them under the
     new owner). Ownership never transfers under a live rule's feet.
  The separate *client-side* channel declaration remains the runtime
  both-ends-or-dark signal (channel-presence), distinct from this owner-binding.
- The never-delivered distinction — "no channel declared" vs "nothing arrived" —
  belongs to **`inbox-doctor`**, which `ai/contracts/athena-inbox.md` owns (see
  *The diagnostic: `inbox-doctor`* there, and *Relationship to the Athena Inbox
  contract* below). This contract does **not** restate or impose that obligation
  — it relies on it; the distinction is specified in the inbox contract, not
  here.
- A lane matching **zero** over a long window MUST be reported, not silently
  treated as healthy. **This report is extended to `source_lane` consumers: a
  `notify` rule whose `source_lane` names a membership rule that is currently
  DISABLED MUST likewise be reported** — its source lane is emitting nothing, so
  the consumer is inert — never left silently quiet. This is the disable-side half
  of the `source_lane` referential-integrity lifecycle; a DELETED `source_lane` is
  instead **invalidated** (refused/flagged with a `Fix:`) per that same lifecycle
  (see *Binding a `notify` rule on a `lane.member.*` transition*), which mirrors
  the record-immutability invalidate-dependents rule below.

git-common-dir tenancy keying stays the inbox client resolver's job
(`ai/contracts/athena-inbox.md` → *Repo identity: the git common dir*). This
whole rule is the failed-lookup discipline (`~/dev/custom/ai/CLAUDE.md` → *A failed
lookup must never look like an empty one*): a dark channel is a lookup that
matched nothing and said nothing, and it MUST be made observable at every join.

---

## Relationship to the Athena Inbox contract

The inbox is **one delivery adapter** among several. This contract owns the event
platform (envelope, taxonomy, ingress, rules, predicates, membership, adapters,
templating, trust posture, security). The Athena Inbox contract
(`ai/contracts/athena-inbox.md`) owns the inbox *channel mechanism* — the `log`
and `maildir` kinds, the doorbell, consumption state, tenancy resolution, and the
Path-2 *Untrusted input* boundary. Where the inbox adapter produces `log` lines,
it MUST conform to that contract; this contract does not restate or override it.
