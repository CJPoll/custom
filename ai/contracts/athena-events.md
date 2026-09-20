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
- **`owner`** — the account the event belongs to. It MUST be stamped by the
  platform from the **authenticated ingress**, and MUST NEVER be read from the
  payload. A payload field that purports to name an owner is untrusted content;
  using it to select an owner is a privilege-escalation defect. An event whose
  owner cannot be resolved from its authenticated ingress MUST be rejected with a
  `Fix:` (name the ingress and that owner resolution failed), never defaulted to
  an arbitrary or "system" owner.
- **`occurred_at`** — when the transition happened.
- **`source`** — provenance: `webhook:slack`, `webhook:notion`, `poller:<lane>`,
  `emit:<machine_id>`. `source` is **diagnostic only**. It MUST NEVER be an
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

An event that is **handled by no enabled rule** MUST be **dead-lettered and
persisted** to queryable storage for audit and debugging. It MUST NOT be silently
dropped, and it MUST NOT be **merely counted** — a bare counter cannot answer
"which event, of what type, for which owner, went unmatched?", and that question
is exactly the failed-lookup discipline (`~/dev/custom/CLAUDE.md` → *A failed
lookup must never look like an empty one*): an unmatched event is a legitimate
miss, and a legitimate miss MUST remain observable as the specific thing it was.

**"Handled" is broader than "matched by a rule declared on this `type`".** A
membership-derived transition (`lane.member.added` / `lane.member.retracted`) is
produced by a membership rule that is declared on a **different** `type` (a flaky
lane is declared on `notion.ticket.*`), so that rule is not among the rules that
*match* the derived event — yet the transition **is delivered**: it drives the
membership rule's own delivery (see *Two rule kinds*). Therefore **a
membership-derived transition emitted by a membership rule is CONSIDERED HANDLED
by that originating rule** — its own delivery is the handling — and MUST NOT be
dead-lettered because no `notify` rule matched it. The dead-letter MUST fires
**only when NO rule handled the event at all**: neither the originating
membership rule's delivery, nor any additional `notify` rule the owner declared
on `lane.member.*` (such a rule MAY match and fire **in addition**). Without this
distinction, an owner with a single flaky-lane rule and no
`notify`-on-`lane.member.*` rule would dead-letter **every** add/retract it
successfully delivered — flooding the store (whose whole purpose is "which event
went **unmatched**?") with successful deliveries and their full Path-2 payloads.
"Delivered" and "unmatched" are disjoint: a correctly-delivered transition is
never dead-lettered.

The dead-letter store is **per-account** and holds a full event payload, which
may carry third-party content, so it is **Path-2 untrusted** when read into an
LLM (see *Trust posture — two paths*), and read access is the owning account's.
Its retention follows the **same doctrine as the sibling inbox contract**
(`ai/contracts/athena-inbox.md` → *Retention* → *The principle*), not a
wholesale age-out: a dead-lettered event is the canonical **never-delivered,
never-read** item — and the sole evidence of the miss this section insists stay
observable — so retention MUST NOT destroy it until it has been **read/triaged**.
An unread dead-letter entry has an **unbounded** lifetime ("unread bytes are
mail, and mail is kept until it is delivered, however old it gets"); age-out under
the product data-retention policy applies **only after** it has been read/triaged.
Destroying an unread miss would erase the very observability the dead-letter store
exists to provide.

### Enumerated first-pass event types

The following `type`s are defined for the first pass. The namespace stays open —
this enumeration is the set that exists today, **not** a closed universe, and an
implementation MUST NOT reject or hard-code against an unknown well-formed `type`
(it dead-letters it per *The event taxonomy is open*).

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

| Event type(s) | `payload.*` field | Type | Cardinality |
|---|---|---|---|
| `notion.ticket.*` | `status` | string | scalar |
| | `labels` | string | **collection** |
| | `assignee` | person-id | **collection** |
| | `title` | string | scalar |
| | `ticket_number` | string | scalar |
| | `changed_properties` (`notion.ticket.updated` only) | string | **collection** |
| `notion.comment.*` | `comment_text` | string | scalar |
| | `ticket_number` | string | scalar |
| | `title` | string | scalar |
| `slack.message.received` | `text` | string | scalar |
| | `channel` | string | scalar |
| | `user` | string | scalar |
| | `thread_ts` | string | scalar |
| `lane.member.added`, `lane.member.retracted` | `rule_id` | string | scalar |
| | `lane` | string | scalar |
| | `op` | `"add"` \| `"retract"` | scalar |
| | `entity_id` | string | scalar |
| | `ticket_number` | string | scalar |
| | `title` | string | scalar |

**The membership-derived types have a closed payload schema of their own** — the
minimal cached display fields (`ticket_number`, `title`) plus the lane/rule
identity (`rule_id`, `lane`) and the transition `op`. This is deliberate: the
contract makes a `notify` rule on a `lane.member.retracted` transition first-class
(see *Retraction-driven consumer patterns*), so a predicate leaf or a template
slot on that event MUST have a closed, bindable, save-time-validated schema
exactly like a source-emitted type. The fields are the same minimal ones the
lane-membership store caches at add time so a retract renders after the entity is
gone (see *Membership rules and the lane-membership store*), and they remain
**Path-2 untrusted** when they reach an LLM.

### Idempotency is per (event, rule)

Because of fan-out (see *Fan-out: every match fires*), one event fires every
matching rule independently, so each `(event, rule)` delivery MUST be deduped and
retried on its own. The `idempotency_key` in the envelope is the **event-level**
key (e.g. Slack's `event_id`; a Notion entity's `notion:<uuid>` combined with a
change token); the platform combines it with the matched `rule_id` to form the
**per-delivery** key. An implementation MUST dedupe and retry at the
`(event, rule)` grain, never only at the event grain.

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
re-checked on every event, so a crafted payload cannot bypass it. The
first-pass permitted-origination rule:

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

---

## Handling rules — fan-out, predicate-driven, config not code

A rule is **config the platform evaluates, never executable code**. A rule
carries: the `event_type(s)` it applies to, its **predicate** (see *The predicate
grammar*), its **kind** (`notify` / `membership`), its **adapter + target** (see
*Delivery adapters* and *Both-ends-or-silently-dark*), its **template + format**
(see *Templating and the per-adapter Escaper contract*), and its **enabled flag +
dedupe window** (see *Enabled flag and dedupe window*). Every field named here has
a normative section behind it; there are no dangling schema entries.

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

**This completes the owner-binding triad.** Every seam at which an `owner` enters
the system stamps it from an **authenticated identity**, NEVER from a
request/payload body:

1. **Event owner — ingress-stamp.** Stamped from the authenticated ingress,
   never read from the payload (see *The event*). Stops an account **minting**
   another's events.
2. **Delivery target — target-bind.** A rule's target MUST resolve to a
   machine/channel registered to the rule's owner (see
   *Both-ends-or-silently-dark*). Stops an account **delivering into** another's
   surfaces.
3. **Rule authoring — author-stamp.** A rule's `owner` is stamped from the
   authenticated author (this section). Stops an account **authoring rules
   under** another's authority.

All three are one rule — an `owner` is an authenticated-identity fact, never a
caller-supplied one — applied at the three seams where an owner is set.

### Enabled flag and dedupe window

Two owner-facing schema fields carried by every rule:

- **`enabled`** — a boolean gate. Only **enabled** rules are evaluated (see
  *Fan-out: every match fires*); a disabled rule is inert — it neither matches,
  fires, nor contributes to the dead-letter "handled" accounting (see *The event
  taxonomy is open*) — and MAY be re-enabled with no loss.
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
  Only `notify` deliveries are windowed. A suppression within the window MUST
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
  the delivery. That emitted transition is **considered handled by this
  originating membership rule** (its own delivery is the handling), so it is
  **never dead-lettered** merely because no separate `notify` rule matches it
  (see *The event taxonomy is open*).

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
    payload schema** lists — e.g. for a `notion.ticket.*` event `payload.status`
    (scalar), `payload.labels` (collection), `payload.assignee` (collection),
    `payload.title` (scalar), `payload.ticket_number` (scalar); every enumerated
    type, including the membership-derived ones, has such a schema.

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
    are **presence operators**: the leaf's `value` is **omitted and ignored** — a
    `value` supplied alongside `exists`/`absent` is disregarded, never matched
    against.

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

**Boolean nodes:** `{ "all": [ … ] }` (AND), `{ "any": [ … ] }` (OR),
`{ "not": <node> }`. A predicate is therefore an **arbitrarily nested tree** of
boolean nodes over comparison leaves (e.g. `all[ any[a, b], not[c], d ]`),
bounded only by a depth/size cap.

**Evaluation contract.** Predicate evaluation MUST be **pure, total,
deterministic, and side-effect-free** (Domain code, per `~/dev/custom/CLAUDE.md`
→ *Architecture*). No arithmetic beyond comparison, no regex, no code, fixed
type-coercion rules, bounded depth/size. Specifically:

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
  failed-lookup discipline (`~/dev/custom/CLAUDE.md` → *A failed lookup must
  never look like an empty one*): a wrongly-computed key — a misspelled field —
  otherwise silently matches nothing forever, indistinguishable from a correct
  field that legitimately matched nothing. `absent` (a known field missing at
  runtime) and a save-time reject (an unknown field-path) are the two distinct
  dispositions, and an implementation MUST NOT collapse the unknown path into the
  runtime `absent` case.
- **An operator incompatible with its field's declared type/cardinality is a
  HARD ERROR at rule-SAVE time** — a collection operator (`contains` /
  `intersects`) on a scalar field, or a scalar operator (`eq` / `ne` / `lt` /
  `lte` / `gt` / `gte` / `in`) on a collection field. It is rejected with a
  `Fix:` naming the field, its declared cardinality, and the compatible
  operators, never left to match nothing at dispatch — the same failed-lookup
  class as an unknown field-path, one binding step further in.
- **A malformed predicate is a HARD ERROR at rule-SAVE time**, naming the fault
  with a `Fix:` (which node, which field, what is wrong — including an unknown
  field-path per the bullet above). It MUST NOT be a silent eval-time non-match
  at dispatch. A bad rule must be **loud where it is authored, not dark where it
  runs** — a malformed rule that silently matches nothing is indistinguishable
  from a correct rule that legitimately matched nothing.

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

- Per `(owner, membership-rule)` the store holds the member **entity IDs** plus
  the **minimal display fields** needed to render a retract (e.g. ticket number
  and title).
- On each relevant event (as defined above): **enrich** current state →
  **re-evaluate** the
  membership predicate → **diff** against the stored member set → append an `add`
  (a new member entered the set) or a `retract` (a member left the set — it now
  fails the predicate, or it was deleted).
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
- **Fleet-control cancel-in-flight** — when a ticket is deleted, deprioritized,
  or otherwise retracted while a captain is mid-flight on it, the retraction is
  an event; a rule routes it to a fleet-control consumer that cancels the
  in-flight captain rather than letting it finish work on a ticket that left
  scope. This is the mirror of "spin a captain up".

**Cancel-in-flight and the trust boundary — Path 1 vs Path 2.** How a retraction
acts on the fleet is governed by which trust path delivers it:

- **Path 1 (auto-cancel) is legitimate as deterministic config the owner
  authored** — e.g. a fleet-control endpoint the platform calls directly. The
  owner's rule authorizes it by definition.
- **Path 2 (recommend only)** — a retraction arriving as untrusted *content* into
  an LLM session can only **recommend** a cancel; it MUST NOT self-authorize one.

Which path a given lane uses is config. (First-pass builds the set-consumer; the
cancel-in-flight consumer is roadmap, but the event/predicate/transition model is
specified now to carry it.)

---

## Delivery adapters

Every platform is split into **inbound** (an ingress: verify sender, content
untrusted at the LLM) and **outbound** (a delivery adapter: format + escape,
credentials). Several platforms are bidirectional; the interface accommodates
both, and build is staged.

### Fixed-destination vs owner-supplied-destination

Every outbound adapter is exactly one of:

- **Fixed-destination** — a known host (Slack, email, SMS, Discord, Notion, and
  the inbox adapter). It carries **no** egress/SSRF model.
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
- **Emitting a value raw requires an explicit, owner-marked "trusted" slot**, and
  a trusted slot MAY reference **only platform-controlled fields**, never
  free-form untrusted payload text.
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
  it. The owner-bind is enforced at **rule-save time** — the target machine and
  the rule's owner are both known then, so it runs at the **same layer** as the
  rule-authoring owner-stamp and predicate save-time validation, not at ingest.
  (The separate *client-side* channel declaration is what the runtime
  both-ends-or-dark observability below covers; owner-binding is the save-time
  refusal, channel-presence is the runtime signal.)
- `inbox-doctor`'s never-delivered finding MUST distinguish "no channel declared"
  from "nothing arrived".
- A lane matching **zero** over a long window MUST be reported, not silently
  treated as healthy.

git-common-dir tenancy keying stays the inbox client resolver's job
(`ai/contracts/athena-inbox.md` → *Repo identity: the git common dir*). This
whole rule is the failed-lookup discipline (`~/dev/custom/CLAUDE.md` → *A failed
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
