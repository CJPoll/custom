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
  payload — a predicate matches only the present (see *The predicate grammar*).
- **`owner`** — the account the event belongs to. Every event is
  ingress-originated, so its owner MUST be stamped by the platform from the
  **authenticated ingress**, and MUST NEVER be read from the payload; a payload
  field that purports to name an owner is untrusted content, and using it to
  select an owner is a privilege-escalation defect. An event whose owner cannot
  be resolved from its authenticated ingress MUST be rejected with a `Fix:` (name
  the ingress and that owner resolution failed), never defaulted to an arbitrary
  or "system" owner.
- **`occurred_at`** — when the transition happened.
- **`source`** — provenance, drawn from a **closed set of FORMS**: `webhook:slack`,
  `webhook:notion`, `poller:<source>`, and `emit:<machine_id>`. The set of *forms*
  is closed (exactly these four), so every enumerated `type` has a legal `source`
  and an owner predicate leaf on the matchable `event.source` field never reads an
  undefined value. Two forms carry a **parameterized, registration-supplied
  substring** — `poller:<source>` and `emit:<machine_id>` — bound by no
  grammar/charset rule in this contract (see *Templating and the per-adapter
  Escaper contract*, which depends on exactly that). That open substring is **not**
  a hole: `source` is not a component of any store key (the stores key on
  `type` / `rule_id` — see *Event disposition and dead-letter*), it is never an
  authorization input (next sentence), and it always passes through the adapter's
  Escaper (the first-pass trusted set is empty — see *Templating and the
  per-adapter Escaper contract*). `source` is **diagnostic only**. It MUST NEVER be an
  authorization input — nothing may grant an event more trust or more scope
  because of what its `source` says. (Authentication of the source is the
  ingress's sender-verification step; `source` is the label recorded after that
  step already succeeded, not a substitute for it.)
- **`idempotency_key`** — see *Idempotency is per (event, rule)*.

### The event taxonomy is open

The taxonomy is **open and extensible**: any state-based change can become an
event, and new sources and new fleet events add new `type`s. Adding a new `type`
**value** within an already-modeled family is **config, no schema change**;
adding a genuinely **new type family** is a **declared increment** that declares
its model — its payload schema, identity field, revision token, origination
membership, and enrichment posture (see *Extending the taxonomy — a new type
family declares its model*). `type` is a namespaced dotted string precisely so this holds. This is
what lets fleet-control transitions (an admiral spinning a captain down early),
retraction messages, and future sources all be ordinary events matched by
ordinary rules, rather than special cases in code.

### Extending the taxonomy — a new type family declares its model

The open taxonomy (*The event taxonomy is open*) extends in **two shapes**,
which cost differently:

- **A new `type` VALUE within an already-modeled family** — one that reuses an
  existing family's closed payload schema, identity field, and revision basis
  (e.g. a further `notion.ticket.*` verb over the enriched-ticket model of
  *Payload fields and their types per event type*) — is **config, no schema
  change and no code change**: it inherits that family's payload schema, its
  idempotency basis and `subject` (see *Idempotency is per (event, rule)* and
  *Enabled flag and dedupe window*), and its enrichment posture, and it need
  only be added to its ingress kind's **finite registered origination set** (see
  *Which event types an ingress kind may originate*), which every type already
  requires.

- **A genuinely NEW type FAMILY** — one with no already-modeled payload schema
  (`fleet.*` is the roadmap instance — see *Harness-emit*; a future forge source
  natively supplying deltas is another) — is a **declared increment, not a free
  addition**. The first-pass machinery this contract instantiates for the
  enumerated families is defined **per family**, so registering a new family is
  **config, not code, but NOT "nothing to declare"**: the family MUST declare,
  at registration, the same five things the enumerated families already have, or
  the guarantees this contract makes silently do not hold for it —

  1. **Its closed payload schema** — the `payload.*` fields it carries, each
     with a declared **type** and **cardinality**, exactly as *Payload fields
     and their types per event type* declares for the enumerated types. This is
     what rule save-time field-path / type / cardinality validation binds
     against (see *The predicate grammar* → *Evaluation contract*); without it,
     no `payload.*` leaf on the family is authorable.
  2. **Its identity field** — the change-invariant handle identifying the
     subject the event is about (the `entity_id` analogue for a persistent
     entity; or, for a transient event never updated, the per-event identity as
     `slack.message.received` uses `payload.event_id`). This is the **`subject`**
     of the dedupe window (see *Enabled flag and dedupe window*).
  3. **Its change/revision token** — the discriminator separating two distinct
     changes to the same identity (the `revision` analogue), **or** an explicit
     statement that the event is transient and never updated, so identity alone
     is unique and no revision token exists (as for `slack.message.received`).
     Items 2 and 3 together are the family's **event-level idempotency basis**
     (see *Idempotency is per (event, rule)*). A family with neither declared
     has an **undefined** idempotency basis and an **undefined** `(rule_id,
     subject)` dedupe grain, and MUST NOT fall back to `rule_id` alone — the
     silent cross-subject miss this contract names a defect (see *Enabled flag
     and dedupe window*).
  4. **Its origination membership** — which ingress kind may originate it, added
     to that ingress's **finite registered origination set** (see *Which event
     types an ingress kind may originate*). A source-emitted family is
     verified-ingress-only; a `fleet.*` family is harness-emit-only.
  5. **Its enrichment posture** — whether its ingress enriches a metadata-only
     signal before emitting (declaring the least-privilege, read-only, on-demand
     fetch per *Sender verification and payload completeness*), or — like
     harness-emit — does not enrich at all. Harness-emitted families (`fleet.*`)
     do not enrich.

  Declaring these is a **registration-time config act** (no code change) and
  introduces **no platform routing, membership, or per-change sequence state** —
  it is static per-family registration config, the same nature as the
  origination set. What it forbids is *originating or routing* a family the
  platform has no model for, which would otherwise route with an undefined
  idempotency basis, an undefined dedupe `subject`, and an unauthorable payload
  schema — three instances of the failed-lookup class this contract legislates
  against everywhere (`~/dev/custom/ai/CLAUDE.md` → *A failed lookup must never
  look like an empty one*).

  The **registration mechanism** for a new family is a **roadmap increment** (it
  lands with harness-emit and any future delta-supplying source — see
  *Harness-emit*); this section fixes **what such a registration MUST declare**,
  so the increment is a natural later addition and not a rewrite — exactly as the
  harness-emit envelope is specified now though its ingress is roadmap.

### Event disposition and dead-letter

Every event resolves through a **two-level** model. The dead-letter trigger keys
on the first level ONLY; the per-delivery outcomes live at the second.

**Level 1 — event ROUTING disposition (total over exactly two outcomes)**, keyed
on *"does any of the event owner's enabled rules apply to this event's `type`?"*:

- **HANDLED** — at least one of the **event owner's** enabled rules declares an
  `event_type(s)` that includes this event's `type` (≥1 of the owner's rules
  *applied*). **Not** dead-lettered, regardless of what then happens to the
  individual deliveries.
- **UNMATCHED** — **none** of the **event owner's** enabled rules applies to the
  event's `type` at all (no owner rule's declared `event_type(s)` includes it).
  **This is the sole dead-letter trigger.** Scoping to the owner's own rules is
  required so that another account's rules can neither mark an event HANDLED nor
  suppress the owner's dead-letter record.

An **UNMATCHED** event MUST be **dead-lettered and persisted** to queryable
storage for audit and debugging; it MUST NOT be silently dropped, and it MUST NOT
be **merely counted** — a bare counter cannot answer "which event, of what type,
for which owner, went unmatched?", exactly the failed-lookup discipline
(`~/dev/custom/ai/CLAUDE.md` → *A failed lookup must never look like an empty
one*): a legitimate miss MUST remain observable as the specific thing it was. A
**HANDLED** event MUST NOT be dead-lettered.

**Level 2 — per-`(event, rule)` DELIVERY outcome (total over exactly six
outcomes).** Because of fan-out (see *Fan-out: every match fires*) a single
HANDLED event has one outcome **per applied rule**, evaluated independently at the
`(event, rule)` grain *Idempotency is per (event, rule)* defines — an event can be
DELIVERED on rule X, SUPPRESSED on Y, and terminally FAILED on Z at once, so only
the Level-1 routing question is genuinely per-event; every delivery outcome is
per-`(event, rule)`:

1. **DELIVERED** — predicate TRUE and the delivery succeeded.
2. **FILTERED** — predicate FALSE; the rule applied and correctly produced no
   delivery.
3. **SUPPRESSED** — predicate TRUE, but the delivery was collapsed by the owner's
   **dedupe window** (observable per *Enabled flag and dedupe window* — "recorded
   and countable as 'suppressed by dedupe window', never a silent drop").
4. **REFUSED** — predicate TRUE, but a **delivery-time owner↔destination check refused the delivery before it left the platform**. Every such check is inherently delivery-time (a save-time-only check cannot cover it — a binding can be deregistered after save, and DNS rebinding defeats a save-time destination check), and **each declares its own refusal-cause class** in the open-but-declared set of *Delivery refusal — the refused-delivery store*. First-pass: (a) the **target-bind re-assertion** — the target no longer resolves to the rule's owner (see *Mechanism vs config boundary, and both-ends-or-dark*, the delivery-time re-assertion enforcement point); and (b) the **generic-webhook egress guard** — the resolved destination is not on the owner allowlist, or resolves to a blocked (loopback / link-local / private / metadata) range (see *The generic-webhook egress model*). Roadmap owner-supplied-destination adapters add their own: the **email/SMS owner-verified-recipient** check (cause class `owner-verified-recipient`, see *Adapter classification — two orthogonal axes (egress model × owner↔destination bind)*). A REFUSED delivery is **recorded in the refused-delivery store — one exemplar-plus-count per `(owner, rule_id, refusal-cause)` — and reported to the owner** (see *Delivery refusal — the refused-delivery store*): never a silent drop, and never a bare counter. **Every** REFUSED trigger is **permanent** — the rule keeps matching and refusing on every delivery until the owner acts — so, exactly like a terminal FAILED delivery, REFUSED gets sibling-consistent observability (an exemplar the store *names*, plus an owner report), not merely a count.
5. **FAILED (terminal)** — predicate TRUE, delivery attempted, retries exhausted /
   adapter 5xx / credential revoked. Recorded in the **failed-delivery store**
   (below), **never** dead-lettered as UNMATCHED.
6. **COLLAPSED** — predicate TRUE and the delivery matched, but its
   `(entity_id, revision)` idempotency key collided with an earlier delivery's
   because the source's revision granularity is coarser than its change rate — a
   **sub-granularity source-revision collapse** (e.g. two Notion edits within one
   `last_edited_time` minute share one `revision`), so the two deliveries collapse
   to one. Recorded and **countable as the `collapsed-by-idempotency-key`
   outcome** (see *Idempotency is per (event, rule)*), **kept DISTINCT from
   SUPPRESSED** — which is strictly the owner's dedupe-window case — never a silent
   drop.

**Each Level-2 outcome that is not DELIVERED is individually observable** —
FILTERED via ordinary accounting, SUPPRESSED per *Enabled flag and dedupe window*,
REFUSED via the **refused-delivery store and an owner report** (see *Delivery refusal — the
refused-delivery store*), covering **every declared owner↔destination refusal-cause class** — the target-bind re-assertion (per *Mechanism vs config boundary, and both-ends-or-dark*), the generic-webhook egress guard (per *The generic-webhook egress model*), and the roadmap email/SMS owner-verified-recipient check (per *Adapter classification — two orthogonal axes (egress model × owner↔destination bind)*), FAILED per the failed-delivery store, COLLAPSED as the
`collapsed-by-idempotency-key` outcome per *Idempotency is per (event, rule)* — so
**no matched delivery is ever a silent drop.**

**Why FILTERED is not a miss, and must not flood the dead-letter store.** A
routing rule declared on `notion.ticket.updated` applies to every ticket-update
event, and many such events do not satisfy its predicate (a different property
changed, or the current state does not match) — those are **FILTERED**: the rule
applied and correctly produced no delivery. Collapsing FILTERED into UNMATCHED
would flood the dead-letter store (whose whole purpose is "which event went
**unmatched**?") with routine no-ops and their full Path-2 payloads. Equally,
FILTERED must not be conflated with SUPPRESSED, REFUSED, COLLAPSED, or terminally
FAILED — those are matched deliveries that did not (separately) arrive, each
separately observable above, not benign no-ops.

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
structural quantity — the number of distinct unmatched `type`s per owner**,
independent of traffic volume. That quantity is finite because **the set of `type`
values that can enter the platform at all is the union of the ingress kinds'
finite registered origination sets** (see *Which event types an ingress kind may
originate* — origination is a registered finite set of `type` values, never an
open prefix, so no emitter can mint an unbounded stream of distinct `type`s); the
taxonomy is open, but what any ingress may *originate* is not. The bound is
therefore a **registration-time config quantity**, not a property of the open
taxonomy: a million unmatched Slack events of one type collapse to one exemplar +
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

#### Terminal delivery failure — the failed-delivery store

A **terminally-FAILED** matched delivery (Level-2 outcome 5 — retries exhausted,
adapter 5xx, credential revoked) MUST be recorded in a **failed-delivery store**,
**distinct from the dead-letter store**, and MUST be **reported to the owner**. A
terminally-failed matched delivery is **never** dead-lettered as UNMATCHED — it
*matched* a rule; dead-lettering it would both corrupt the dead-letter store's
"which `type` went unmatched?" purpose and mask a delivery failure as a routing
miss.

- **Grain — one exemplar-plus-count per `(owner, rule_id, terminal-cause)`**,
  mirroring the dead-letter store's structural bound. The **exemplar** is the
  first-seen failed delivery's **full event payload plus the terminal error**
  (cause class + adapter + target), which alone answers the failed-lookup question
  "which delivery, of which rule, to which target, terminally failed, and why?".
  Subsequent failures of the same `(owner, rule_id, terminal-cause)` **increment a
  monotonic count** and update **last-seen**, storing **no** new payload. This
  bounds the store by a **structural quantity** — distinct `(rule, cause)` pairs
  per owner, a finite set — **independent of traffic volume**: a revoked credential
  failing a million deliveries collapses to one exemplar + count 1,000,000, not a
  million rows.
- **Never merely counted; observable.** As with the dead-letter store, the
  exemplar is retained so the store *names* the failed delivery; the count is
  added scale metadata, never a replacement. The exemplar payload carries
  third-party content, so the record is **Path-2 untrusted** when read into an LLM
  (see *Trust posture — two paths*), and read access is the **owning account's**
  only.
- **Reported, not merely stored.** A rule whose deliveries are terminally failing
  is a delivery the owner configured that is silently not arriving — strictly more
  urgent than the existing "a rule matching **zero** over a long window MUST be
  reported" (see *Mechanism vs config boundary, and both-ends-or-dark*). Terminal
  delivery failure MUST likewise be **reported to the owner, never left silently
  quiet**, carrying the LLM-actionable marker: `Fix: rule <rule_id> has <count>
  terminal delivery failures to <adapter>:<target> (cause: <class>); check the
  target/credential or disable the rule — see the failed-delivery store exemplar
  for the first-seen event.`
- **Retention — the never-destroy-unread doctrine applies, made safe by the
  grain.** Follow the sibling inbox doctrine (`ai/contracts/athena-inbox.md` →
  *Retention* → *The principle*), exactly as the dead-letter store does: an
  **un-triaged** failed-delivery exemplar has an unbounded lifetime (it is the sole
  evidence of the miss); age-out applies only after read/triage; the per-`(owner,
  rule_id, terminal-cause)` grain bounds it to at most one unread exemplar per
  pair. **The store carries no cap or TTL number in this contract** — any
  operational cap/TTL is ops/owner config, outside this contract's MUST surface.
- **Reconciled with idempotency.** "Terminal" means the per-`(event, rule)`
  idempotency/retry budget of *Idempotency is per (event, rule)* is exhausted; the
  failed-delivery record is that key's terminal state. The idempotency key store is
  separate, so a later re-processing of the same `(event, rule)` still dedupes and
  does **not** manufacture a second failure record.

#### Delivery refusal — the refused-delivery store

A **REFUSED** matched delivery (Level-2 outcome 4 — predicate TRUE, but a delivery-time policy
check refused the delivery before it left the platform) MUST be recorded in a **refused-delivery
store**, **distinct from the dead-letter store, the failed-delivery store, and the
ingress-failure store**, and MUST be **reported to the owner**. A REFUSED delivery *matched* a
rule, so it is **never** dead-lettered as UNMATCHED; and no attempt reached the destination, so
it is **never** a terminal FAILED — no per-`(event, rule)` retry budget is consumed, and a
refused destination MUST NOT be retried.

Both REFUSED triggers are **persistent**, which is exactly why a bare counter is insufficient —
the condition holds for the same rule until the owner acts:

- **Target-bind re-assertion refusal** — the target machine no longer resolves to the rule's
  owner (deregistered or re-owned; see *Mechanism vs config boundary, and both-ends-or-dark*). The
  rule matches and refuses on **every** delivery until it is re-authored.
- **Generic-webhook egress refusal** — the resolved destination is not on the owner allowlist, or
  resolves to a blocked (loopback / link-local / private / metadata) range (see *The
  generic-webhook egress model*). The rule matches and refuses on **every** delivery until the
  allowlist or destination is corrected.

In both cases the rule **IS matching**, so the "a rule matching **zero** over a long window MUST
be reported" backstop (see *Mechanism vs config boundary, and both-ends-or-dark*) does **not**
fire, and a count alone cannot say **which rule → which target/destination** was refused, or
**why**. The owner's configured delivery then silently never arrives — the failure this contract
calls *strictly more urgent* than a zero-match rule (see *Terminal delivery failure — the
failed-delivery store*).

- **Grain — one exemplar-plus-count per `(owner, rule_id, refusal-cause)`**, mirroring the
  failed-delivery store and bounding the store by a **structural quantity** — distinct `(rule,
  refusal-cause)` pairs per owner, a finite set — **independent of traffic volume**.
  `refusal-cause` is an **open-but-declared set**: each **owner↔destination check declares its own cause class**, exactly as *Extending the taxonomy — a new type family declares its model* makes a new event family a declared increment rather than a free addition. The set is "open" in that a new owner-supplied-destination check adds its class with **no edit to this store**; it is "declared" in that **no delivery may be refused under a cause class the refusing check has not declared** — an undeclared cause is a hard error, never an unlabelled miss (`~/dev/custom/ai/CLAUDE.md` → *A failed lookup must never look like an empty one*). First-pass the declared classes are **target-bind re-assertion** and **generic-webhook egress**; the roadmap **email/SMS owner-verified-recipient** check declares **`owner-verified-recipient`** (see *Adapter classification — two orthogonal axes (egress model × owner↔destination bind)*), and any future owner-supplied-destination check declares its own. Because the key is the declared class, the grain stays bounded by a **structural quantity** — distinct `(rule, declared-cause)` pairs per owner — independent of traffic volume, and correct the moment a new check declares its class. The **exemplar** is the first-seen refused delivery's **full event
  payload plus the refusal detail** (cause class + adapter + the target/destination that was
  refused), which alone answers "which delivery, of which rule, to which target, was refused, and
  why?". Subsequent refusals of the same `(owner, rule_id, refusal-cause)` **increment a monotonic
  count** and update **last-seen**, storing **no** new payload. A revoked binding refusing a
  million deliveries collapses to one exemplar + count 1,000,000, not a million rows.
- **Never merely counted; observable.** As with the sibling stores, the exemplar is retained so
  the store *names* the refused delivery; the count is added scale metadata, never a replacement.
  The exemplar payload carries third-party content, so the record is **Path-2 untrusted** when
  read into an LLM (see *Trust posture — two paths*), and read access is the **owning account's**
  only.
- **Reported, not merely stored.** REFUSED MUST be **reported to the owner, never left silently
  quiet**, carrying the LLM-actionable marker: `Fix: rule <rule_id> has <count> refused deliveries to <adapter>:<target> (refusal-cause: <cause>) — apply the remediation the refusing owner↔destination check declares for <cause>: target-bind re-assertion → re-author the rule against a machine registered to its owner; generic-webhook egress → correct the owner allowlist or the destination; owner-verified-recipient (email/SMS) → verify the recipient or the sending domain for this owner, or correct the rule. See the refused-delivery store exemplar for the first-seen event and its declared refusal detail.`
- **Retention — the never-destroy-unread doctrine applies, made safe by the grain**, exactly as
  the dead-letter, failed-delivery, and ingress-failure stores (see *Event disposition and
  dead-letter*): an un-triaged refused-delivery exemplar has an **unbounded** lifetime (it is the
  sole evidence of the miss); age-out under the product data-retention policy applies **only
  after** it has been read/triaged; the per-`(owner, rule_id, refusal-cause)` grain bounds it to
  **at most one unread exemplar per pair**. **The store carries no cap or TTL number in this
  contract** — any operational cap/TTL is ops/owner config, explicitly outside this contract's
  MUST surface.
- **No routing state.** The refused-delivery store is **per-account exemplar-plus-count AUDIT
  data**, exactly like the three existing stores; it holds no membership set and no per-change
  sequence/routing state, and adds none.

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
  carries the changed property identifiers (`changed_properties`) plus the
  enriched **current** values.
- `notion.ticket.deleted`
- `notion.ticket.undeleted`
- `notion.comment.created`
- `notion.comment.updated`
- `notion.comment.deleted`

**`notion.ticket.updated` is the coarse property-change signal; which property
changed is expressed by filtering.** The first pass mints **no** per-property
ticket types — there is no `notion.ticket.status_changed`,
`notion.ticket.labels_changed`, or `notion.ticket.assignment_changed`. A rule that
cares which property changed filters the coarse `notion.ticket.updated` on its
declared `changed_properties` collection, e.g.
`{"field":"payload.changed_properties","op":"contains","value":"<status-prop-id>"}`
— that carries the full "which property" signal, so a finer separate type would
buy no routing power and is not minted. (Finer separate types are roadmap; they
would land with their own payload-schema rows only if a real need appears.) A
routing rule authored against one of those non-existent finer types fails loud at
**save** time on **two** independent grounds, so it is caught **whatever its
predicate**: (1) the **declared-type-membership** check — a finer type is not a
registered type, an unknown-`event_type` save-time HARD ERROR (see *The predicate
grammar* → *Evaluation contract*), which fires **even for an envelope-only
predicate**; and (2) for a predicate that additionally binds a `payload.*` leaf,
the existing unknown-path save-time HARD ERROR (a finer type has no payload
schema, so any `payload.*` leaf is unbindable). The redirecting `Fix:` is: `Fix: unknown event type '<type>' — the first pass emits no per-property ticket types (no notion.ticket.status_changed/labels_changed/assignment_changed). Declare notion.ticket.updated and filter on which property changed with a predicate leaf {"field":"payload.changed_properties","op":"contains","value":"<property-id>"}.`

**Direction is NOT emitted for a metadata-only source; the consumer derives it.**
"A label was *added*" vs "*removed*", "an assignee was *set*" vs "*cleared*" are
transitions of a value's **direction**. A metadata-only source (a Notion webhook,
with no before/after — see *Sender verification and payload completeness*) does
not carry direction, and the platform holds **no prior state** to compute it
from. Therefore the platform MUST NOT emit direction-resolved value-change types
(`notion.label.added` / `notion.label.removed`) for such a source: it emits a
coarse **current-state** event, and the **consumer derives direction** by diffing
that current state against its own held set (see *The consumer owns membership*).
Direction-resolved types MAY exist in the open taxonomy for a **future source
that natively supplies deltas** (a forge sending real before/after) — that is a
source capability, never a platform store.

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
| `notion.ticket.created`, `notion.ticket.updated`, `notion.ticket.undeleted` (the **enriched** ticket types) | `entity_id` — stable source entity handle, e.g. `notion:<uuid>` | string | scalar |
| | `status` | string | scalar |
| | `labels` | string | **collection** |
| | `assignee` | person-id | **collection** |
| | `title` | string | scalar |
| | `ticket_number` | string | scalar |
| | `revision` — source revision indicator (Notion: `last_edited_time`, or finer) | string | scalar |
| | `changed_properties` (`notion.ticket.updated` only) | string | **collection** |
| `notion.ticket.deleted` (the **un-enriched** delete type — the entity may already be unfetchable, so it carries identity only) | `entity_id` — stable source entity handle | string | scalar |
| | `revision` — source revision indicator from the deletion event (not an enrichment fetch) | string | scalar |
| `notion.comment.created`, `notion.comment.updated` (the **enriched** comment types) | `entity_id` — stable source entity handle | string | scalar |
| | `comment_text` | string | scalar |
| | `ticket_number` | string | scalar |
| | `title` | string | scalar |
| | `revision` — source revision indicator (Notion: `last_edited_time`, or finer) | string | scalar |
| `notion.comment.deleted` (the **un-enriched** delete type — the comment may already be unfetchable, so it carries identity only) | `entity_id` — stable source entity handle | string | scalar |
| | `revision` — source revision indicator from the deletion event (not an enrichment fetch) | string | scalar |
| `slack.message.received` | `text` | string | scalar |
| | `channel` | string | scalar |
| | `user` | string | scalar |
| | `ts` | string | scalar |
| | `thread_ts` | string | scalar |
| | `event_id` | string | scalar |

**`entity_id` is the declared, bindable entity handle carried by every
source-emitted type that names a persistent ENTITY** — the Notion ticket types
(`notion.ticket.*`) and comment types (`notion.comment.*`) each declare it
(above) as the stable source identifier (e.g. `notion:<uuid>`). It is the
event-level idempotency handle for a Notion entity (see *Idempotency is per
(event, rule)*), and it is what a **consumer** keys its own held set on when it
derives add/drop (see *The consumer owns membership*). It is a first-class
declared field, not an undeclared handle buried in a key. It is **distinct from
the display fields** `ticket_number` / `title` (which render a line);
`entity_id` is identity.

**`slack.message.received` carries NO `entity_id` — by design, and this is what
the closed schema above says.** Its identity field is `payload.event_id` (paired
with `channel:ts` for cross-source dedupe — see below and *Idempotency is per
(event, rule)*), not an `entity_id`. A Slack message is a **transient event, not
a persistent entity**, so there is no stable entity handle for it. The identity
field is therefore **per source**: only the Notion entity types carry
`entity_id`, exactly as the closed table declares.

**`notion.ticket.deleted` carries a NARROWER schema than the enriched ticket
types — by design, not omission.** A delete is not enriched (the entity may
already be unfetchable), so it carries only `entity_id` (identity) plus the
source-supplied `revision` **read from the deletion webhook event, not from an
enrichment fetch**; it does **not** carry `status`, `labels`, `assignee`, `title`,
or `ticket_number`. A
consumer that needs a display line for a departed entity renders it from its own
held state (it recorded those fields when it added the entity — see *The consumer
owns membership*), never from a platform cache. Those enrichment-only fields
being **not in `notion.ticket.deleted`'s payload schema at all** (above) means a
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

**`notion.comment.deleted` carries a NARROWER schema than the enriched comment
types — by design, not omission.** A deleted comment may already be unfetchable,
so it carries only `entity_id` plus the source-supplied `revision` **read from the
deletion webhook event, not an enrichment fetch**; a rule declared **solely** on
`notion.comment.deleted` with a leaf on `payload.comment_text`, `title`, or
`ticket_number` is an **unknown-path save-time HARD ERROR** with a `Fix:` — **not**
a save-valid predicate that reads `absent` forever at runtime. The sanctioned
**union-binding absent-by-design** case (a rule spanning `notion.comment.updated`
+ `notion.comment.deleted`) is unaffected — the enriched type **supplies** the
field, so the leaf binds against the union and reads `absent` on the delete event.
The `Fix:` reuses the existing unknown-field-path save-time path, naming the type:
`Fix: field-path 'payload.comment_text' is not in notion.comment.deleted's payload
schema (identity-only: entity_id). A delete carries no enrichment — remove the
leaf, or declare the rule on an enriched comment type (notion.comment.created /
updated) as well.`

**`slack.message.received` carries `ts` and `event_id`** (not just
`occurred_at`): the deployed inbox reader keys cross-source dedupe on
`channel:ts` and on seen `event_id`s (against the Slack Web-API backstop — see
`ai/contracts/athena-inbox.md`), which `occurred_at` alone does not cover. They
are part of the closed schema so a rule may bind them and the dedupe pairing is
expressible.

**`payload.revision` is the source-supplied event-level idempotency change token
for every Notion entity type.** It is the source's own revision/version indicator
for the entity state the event reflects (Notion: `last_edited_time`, or a finer
source-provided revision token where one exists — the ingress binds the finest the
source exposes). It is **source-supplied, not platform-minted** — so it is escaped
like any source field and is **not** trusted-slot-eligible (see *Templating and
the per-adapter Escaper contract*) — and it is what separates two changes to the
same `entity_id` at the idempotency layer (see *Idempotency is per (event,
rule)*): it MUST be **stable** across at-least-once redeliveries of the **same**
source change and **distinct across different source changes at the source's
revision granularity** — where the source's revision indicator is coarser than its
change rate (Notion's `last_edited_time` is minute-granular), two same-window
changes collapse to one key, an **observable `collapsed-by-idempotency-key`**
outcome defined in *Idempotency is per (event, rule)*, never a silent drop. The
enriched types read it during enrichment; the identity-only delete types
(`notion.ticket.deleted`, `notion.comment.deleted`) source it from the deletion
**webhook event itself, not an enrichment fetch** — preserving their identity-only
property while still distinguishing delete → undelete → delete of one entity.
`slack.message.received` carries **no** `revision`: a Slack message is transient
and never updated, and its `payload.event_id` is already unique.

### Idempotency is per (event, rule)

Because of fan-out (see *Fan-out: every match fires*), one event fires every
matching rule independently, so each `(event, rule)` delivery MUST be deduped and
retried on its own. The `idempotency_key` in the envelope is the **event-level**
key; the platform combines it with the matched `rule_id` to form the
**per-delivery** key. An implementation MUST dedupe and retry at the
`(event, rule)` grain, never only at the event grain.

The event-level key basis is defined for **every** enumerated type:

- **Source-emitted** — the source's own event identity: Slack's `payload.event_id`;
  a Notion entity's `payload.entity_id` (`notion:<uuid>`) combined with
  `payload.revision` (the source-supplied revision indicator declared in *Payload
  fields and their types per event type*). (A reconciliation backstop hit reuses
  the same basis so it dedupes against the primary path — see *Poller (fallback
  only)*.)

  `payload.entity_id` is **stable across changes** (it is identity), so two
  distinct changes to one entity share it; `payload.revision` is what separates
  their keys **at the source's revision granularity**. `revision` MUST be
  **stable** across at-least-once redeliveries of the **same** source change (a
  redelivered webhook for one edit dedupes to one delivery), and **distinct across
  different source changes to the extent the source's revision granularity
  permits**. Where a source's revision indicator is coarser than its change rate —
  **Notion's `last_edited_time` is minute-granular**, so two distinct edits to one
  entity within the same minute carry the **same** `revision` — the two changes
  resolve to **one** `(entity_id, revision)` key and their `(event, rule)`
  deliveries **collapse to one**. Such a collapse MUST be **observable**: recorded
  and **countable as a `collapsed-by-idempotency-key` outcome**, exactly as a
  dedupe-window suppression is recorded (see *Enabled flag and dedupe window*) —
  **never a silent drop** (failed-lookup discipline, `~/dev/custom/ai/CLAUDE.md` →
  *A failed lookup must never look like an empty one*). A **missing or
  unresolvable** `revision` remains an **error, not an empty value that collapses
  keys**: the ingress MUST **reject** emitting a Notion entity event whose
  `revision` cannot be resolved, rather than emit one whose idempotency key
  silently merges with another change's — `Fix: a notion.<entity>.<verb> event has
  no resolvable source revision (payload.revision — e.g. Notion last_edited_time,
  or the deletion event's source timestamp). Emit is rejected: entity_id alone is
  stable across changes, so a missing revision would collapse two distinct changes
  to one idempotency key and silently drop the second delivery. Supply the source
  revision indicator.`

  The basis above is defined for **every enumerated (first-pass) type**. A **new
  type family** (a `fleet.*` family, a future delta-supplying source) has **no**
  idempotency basis until it **declares** one — its identity field plus its
  change/revision token, or an explicit 'transient, never updated, identity alone
  is unique' statement — as part of registering the family (see *Extending the
  taxonomy — a new type family declares its model*). A family whose basis is
  undeclared MUST NOT be originated or routed, and MUST NOT fall back to
  `rule_id`-alone dedupe — the silent cross-subject miss named in *Enabled flag
  and dedupe window*.

  This bounds `revision` to what a **stateless** platform can derive from a
  source-supplied token; the platform never synthesizes a per-change sequence
  (that would require platform state — see the roadmap follow-up **DND-257**
  (collision-proof per-change revision)).
  Because a membership lane's authoritative set is the **consumer's own re-query**
  (see *The lane channel is a change stream, not the authoritative set*) and every
  forwarded event carries **current** enriched state, a sub-granularity collapse
  does not corrupt a lane's set — it reduces two same-window edits to their final
  current state, which is what a state-based consumer acts on; the residual is
  bounded, observable sub-granularity notify completeness.

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
emitting; a **failed** enrichment fetch is handled there — never emitted
un-enriched, never silently dropped (see *Sender verification and payload
completeness*).

**Per-account owner resolution (the ingress stamps `owner` from the authenticated
ingress, never from the payload — see *The event*).** Sender verification proves
the request is genuine; it does **not** by itself name the owner, because one
credential can serve many accounts. Owner is resolved per ingress kind:

- **Notion webhook** — the per-subscription `verification_token` that verified the
  request is registered per-account (owner-stamped when the subscription is
  created), so verifying against it **both** authenticates the sender **and**
  identifies the owning account.
- **Slack webhook** — the app signing secret authenticates that the request is
  from Slack, but one Slack app is installed into many workspaces, so it does
  **not** identify the owner. Owner is resolved by looking up the payload's
  `team_id`/`enterprise_id` (with `api_app_id`) as a **key** into a per-install
  record `(api_app_id, team_id | enterprise_id) → owning account`, whose owning
  account was **stamped at OAuth-install time from the authenticated installing
  account** (the owner-from-auth invariant of *Mechanism vs config boundary, and
  both-ends-or-dark* → machine-token create authority). The `team_id` in the
  payload is a lookup key into a pre-authenticated record, **not** an owner claim,
  so "owner is never read from the payload" holds. The install-record
  issuance/custody is server-side gen_saas (the GS-8 Notion-token / GS-4
  machine-token analog); this contract states the binding invariant and defers
  custody there. A `team_id`/`enterprise_id` that resolves to **no** install
  record is an **owner-unresolvable reject** (per *The event*), never defaulted.
- **Reconciliation poller** — the owner is the account its per-account source-read
  token belongs to, resolved server-side from that token (as harness-emit resolves
  owner from the machine token), never from fetched content.

These **instantiate** MUSTs the contract already carries (they add no new MUST);
they are stated so an implementer has the Slack-specific marker:

- Inbound verification failure (the existing *Inbound webhook* hard-reject, named
  for Slack):
  `Fix: inbound Slack webhook rejected — X-Slack-Signature did not match v0=HMAC-SHA256(signing_secret,"v0:"+X-Slack-Request-Timestamp+":"+raw_body) (constant-time; timestamp within the freshness window). Do not normalize an unverified body. Check the Slack app signing secret in KMS custody.`
- Owner-unresolvable (the existing *The event* owner-reject, named for Slack):
  `Fix: owner could not be resolved for a verified Slack webhook (api_app_id <id>, team_id/enterprise_id <id>) — no OAuth install record binds this install to an owning account. Reject; never default to a 'system' or arbitrary owner. Install the Slack app authenticated as the owning account (install record is owner-stamped from the authenticated installer), or correct the install-record lookup key.`

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

**The backstop re-emits missed CHANGE EVENTS; it computes no membership.** It
recovers **adds** — entities that changed while the webhook was down, or that
existed before the subscription — by emitting the same source-emitted change
events the webhook would have, each deduped against the primary path by the same
`idempotency_key` machinery (above). It holds no set and diffs no membership: a
**consumer** that tracks a working set catches any departure the fast path missed
through its own authoritative re-sync (see *The consumer owns membership*), so
set correctness never depends on any platform-side set reconciliation. The
platform holds no set and reconciles none.

### Harness-emit

`POST` from the fleet/harness via a small deterministic "fire `{type, payload}`"
primitive, authenticated by the **machine token**; the owner is resolved
server-side from that token (never from the payload). It carries no notification
logic — it only produces an event. (Roadmap increment; the envelope is specified
now so it is a natural later increment, not a rewrite. The `fleet.*` family is
itself a **new type family**: the roadmap increment that lands harness-emit also
**declares the fleet family's model** — its payload schema, its identity field,
its change/revision token (or its transient-identity statement), its origination
membership, and its no-enrichment posture — per *Extending the taxonomy — a new
type family declares its model*.)

### Which event types an ingress kind may originate

`source` is diagnostic and MUST NEVER be an authorization input (see *The
event*), so nothing is trusted *because of* the provenance it claims. That rule
alone is not enough: it constrains how a `source` label is read, but not what an
authenticated ingress is allowed to **originate**. Authentication of an ingress
(a verified webhook signature, the machine token) proves *who* is emitting, not
*what* they may emit. Without a second constraint, a machine-token holder could
`POST` a `notion.ticket.deleted` and drive a fan-out delivery — including to a
consumer that drops a ticket from its working set on that event — that only a
verified source ingress should ever produce.

Therefore **each ingress kind is registered with a *finite, explicitly-enumerated
set* of the `type` values it is permitted to originate — a registered set, NOT an
open prefix or namespace-glob — and the platform MUST reject, at ingress, any
event whose `type` is not a member of the set its kind is permitted to
originate**, with a `Fix:` naming the ingress kind and the disallowed `type`. The
constraint is fixed at ingress **registration** (per ingress kind, not per event)
and re-checked on every event, so a crafted payload cannot bypass it.

**The origination set is a finite set of `type` values, never an unbounded
suffix.** A registered prefix such as `fleet.*` names the *namespace a type may be
registered INTO*; it does **not** license an ingress to originate an unbounded
stream of distinct `fleet.<arbitrary-suffix>` values. An ingress MUST be permitted
only the specific, enumerated `type` values registered to it. This keeps
origination — and therefore the set of distinct `(owner, type)` keys any store can
accrue (see *Event disposition and dead-letter* and *Sender verification and
payload completeness*) — bounded by a **registration-time config quantity**, never
by traffic. It **preserves the open taxonomy** (see *The event taxonomy is open* and
*Extending the taxonomy — a new type family declares its model*): a new `type`
**value within an already-modeled family** is added by **registering** it into
the origination set — config, no schema change and no code change — exactly as
before; a **new type family** is added by **declaring its model** (payload
schema, identity field, revision token, origination membership, enrichment
posture) — config, not code, but **not "nothing to declare."** What is forbidden
either way is *originating* a `type` no ingress registration enumerated. This adds **no per-event routing state**: it is a
membership test against static per-ingress registration config, the same check
this section already mandates, tightened from prefix-membership to
set-membership. It is the **ingress-origination** check, distinct from the router
rule that an unknown well-formed `type` which *reaches routing* is **dead-lettered,
never rejected** (see *Enumerated first-pass event types* and *Event disposition
and dead-letter*) — origination-rejection happens before an event exists; the
router still never rejects.

The first-pass permitted-origination rule:

- **Source-emitted webhook types (`slack.*`, `notion.*`) are
  VERIFIED-INGRESS-ONLY.** They may be originated ONLY by the inbound-webhook
  ingress (or the reconciliation poller) for that source, whose sender
  verification established that the change is real (the poller does no HMAC, but
  reads the source directly under its own authorized token, so it is likewise an
  authorized originator of that source's types). That source's
  permitted-origination set is likewise the **finite, enumerated set of that
  source's `type` values** — the enumerated types of *Enumerated first-pass event
  types*, extended only by *registering* a new type for that source — because the
  ingress adapter normalizes to exactly that set; `slack.*` / `notion.*` denote
  the **registered members**, never an open licence to originate an arbitrary
  `slack.<x>` / `notion.<x>`. **Harness-emit MUST NOT be
  able to synthesize a source-emitted webhook type** — a machine-token holder
  cannot mint a `notion.ticket.deleted` or a `slack.message.received` that no
  verified webhook produced; such an event MUST be rejected with a `Fix:`.
- **Harness-emit** may originate only the **finite set of `fleet.*` `type` values
  registered to its machine token** at ingress registration — never a
  source-emitted type, and never an unenumerated `fleet.<arbitrary>` value. The
  `fleet.*` namespace bounds what MAY be registered; origination is bounded to the
  **registered members** of it, not the open prefix (see the finite-set rule
  above). An event whose `type` is a well-formed but unregistered `fleet.*` value
  is rejected at ingress: `Fix: harness-emit is not permitted to originate type '<type>' — it may originate only the fleet.* type values registered to this machine token. Register the type into this token's origination set (config, no code change); if it belongs to a fleet.* family the platform has no model for yet, that family MUST first declare its payload schema, identity field, revision token, origination membership, and enrichment posture (see 'Extending the taxonomy — a new type family declares its model'). Otherwise correct the emitter.`

This is the origination dual of the `source`-is-not-authz rule: `source` governs
what a label may *earn*, and this governs what an ingress may *mint*. Both are
required to stop a machine token from manufacturing a verified-source transition
no webhook produced.

---

## Handling rules — fan-out, predicate-driven, config not code

A rule is **config the platform evaluates, never executable code**. A rule
carries: a platform-assigned **`rule_id`** (see *Rule identity — `rule_id`*), the
`event_type(s)` it applies to, its **predicate** (see *The predicate grammar*), its **adapter +
target** (see *Delivery adapters* and *Mechanism vs config boundary, and both-ends-or-dark*), its
**template + format** (see *Templating and the per-adapter Escaper contract*), and its **enabled
flag + dedupe window** (see *Enabled flag and dedupe window*). There is **one** rule kind — a stateless
routing/notify rule — so a rule carries no `kind` discriminator and no membership
fields. Every field named here has a normative section behind it; there are no
dangling schema entries.

### Rule identity — `rule_id`

Every rule carries a **`rule_id`**: a **platform-assigned**, per-account-unique identifier,
minted once when the rule is **created** and **stable for the entire life of the rule**. It is
the field the per-`(event, rule)` idempotency key combines with the event-level key (see
*Idempotency is per (event, rule)*), and the field the failed-delivery and refused-delivery
stores key on (see *Terminal delivery failure — the failed-delivery store* and *Delivery refusal
— the refused-delivery store*). Those keys are only as stable as `rule_id`, so its stability is a
**correctness MUST, not a convenience**:

- **An edit preserves `rule_id`.** Editing any other field of a rule — predicate, adapter +
  target, template + format, `enabled`, dedupe window, or `event_type(s)` — MUST retain the
  **same** `rule_id`. Minting a new id on edit would re-key every prior `(event, rule)`
  idempotency record, so deliveries already deduped as received would **re-fire**, breaking the
  `(event, rule)`-grain dedupe guarantee across the edit; it would also orphan the rule's
  failed-delivery and refused-delivery exemplars, hiding an ongoing miss behind a fresh key.
- **Only delete + recreate mints a new `rule_id`.** A deleted rule's id is never reused; a
  recreated rule is a new rule with a new id and a fresh idempotency/store history. This is the
  one sanctioned way a rule's id changes, and it is explicit.
- **`rule_id` is platform-assigned, never caller-supplied** — like `owner` (see *Rule ownership
  is stamped from the authenticated author*), it is not read from the request body. A create
  request that supplies a `rule_id`, or an edit that attempts to change one, is refused with a
  `Fix:`. This keeps the identity the idempotency and store keys depend on under the platform's
  control, not the caller's.

The refusal for a caller-supplied or edit-mutated `rule_id` carries:

```
Fix: rule_id is platform-assigned and stable for the life of the rule — it is not accepted from the request body and an edit MUST NOT change it. Remove the rule_id from the request (it is minted at create); to obtain a new id, delete the rule and create a new one.
```

### Rule ownership is stamped from the authenticated author

A rule carries an `owner`, and Path 1's entire safety argument is that the
owner's own configured rules are "authorized by definition" (see *Trust posture —
two paths*). A rule authored with **someone else's** `owner` is therefore a
direct escalation into that account's fleet and destinations. Therefore **a
rule's `owner` MUST be stamped from the authenticated
author's session at create/edit time, and MUST NEVER be accepted from the request
body.** An attempt to create or edit a rule whose `owner` is any account other
than the authenticated author's MUST be refused with a `Fix:` (name that a rule
may be authored only for the authoring account). No "admin" or "on-behalf-of"
path widens this in the first pass.

**This completes the owner-binding triad — three authenticated-identity stamps.**
Every seam at which an `owner` enters the system fixes it from an **authenticated
identity**, NEVER from a request/payload body:

1. **Event owner — ingress-stamp.** An ingress-originated event's owner is
   stamped from the authenticated ingress, never read from the payload (see *The
   event*). Stops an account **minting** another's events.
2. **Delivery target — target-bind.** A rule's target MUST resolve to a
   machine/channel registered to the rule's owner (see
   *Mechanism vs config boundary, and both-ends-or-dark*). Stops an account **delivering into** another's
   surfaces.
3. **Rule authoring — author-stamp.** A rule's `owner` is stamped from the
   authenticated author (this section). Stops an account **authoring rules
   under** another's authority.

In every case an `owner` is an authenticated-identity fact, never a
caller-supplied one.

**Owner-scoping of ACCESS to an existing rule — the read/mutate dual of the
stamps.** The three seams above fix how an `owner` is **written** — stamped onto
events, stamped onto a rule at authoring: the *entry* axis. They do not by
themselves govern **access to an already-stored
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
- **Mutate.** Deleting or disabling another owner's rule silently stops or
  re-points their deliveries; editing it silently re-points them elsewhere. Each
  is a direct attack on that account's fleet and surfaces.

This mirrors the dead-letter store, whose read access this contract already scopes
to the owning account's (see *Event disposition and dead-letter*). Together with
the three stamping seams it makes the owner-binding honest on **both** axes — an
`owner` is fixed from an authenticated identity when it **enters** (stamp), and it
gates **who may read or mutate** the thing thereafter (scope); neither axis alone
is sufficient, so the "every seam" claim above is the write half of a security
story whose read/mutate half is this MUST.

### Enabled flag and dedupe window

Two owner-facing schema fields carried by every rule:

- **`enabled`** — a boolean gate. Only **enabled** rules are evaluated (see
  *Fan-out: every match fires*); a disabled rule is inert — it neither matches,
  fires, nor contributes to the dead-letter "handled" accounting (see *Event
  disposition and dead-letter*) — and MAY be re-enabled. **Re-enabling a rule is
  lossless**: a routing rule is stateless, so it simply resumes matching present
  events; it holds no set to reconcile. Deleting a rule likewise removes only the
  rule — there is no platform-held set to tear down.
- **`dedupe window`** — an **owner-facing rate control**, deliberately distinct
  from the correctness-guaranteeing `idempotency_key` (see *Idempotency is per
  (event, rule)*). The idempotency key prevents a **re-processed same delivery**
  from firing twice — a correctness guarantee, always in force. The dedupe window
  is an owner **preference** that collapses **distinct** deliveries **of the same rule about the same
  subject** within a time window into one ("don't DM me about **this** more than once an hour" —
  *this* being the subject the deliveries concern, not every subject the rule covers). Its key
  grain is stated explicitly, like every other collapsing mechanism: **`(rule_id, subject)`**,
  where **`subject` is the change-invariant identity component of the event-level idempotency
  basis** (see *Idempotency is per (event, rule)*) — **`payload.entity_id`** for the Notion entity
  types (the handle stable across a given entity's changes) and **`payload.event_id`** for
  `slack.message.received` (a transient event carrying no persistent entity, so each message is its
  own subject). The window deliberately **omits the change-discriminator `revision`** the
  idempotency key adds — collapsing several edits of the **same** entity within the window is
  exactly its purpose — so the grain is `(rule_id, subject)`, never `(rule_id, subject, revision)`
  and never `rule_id` alone. **Rule-only grain is a silent cross-subject miss:** within one window
  it would drop the owner's notifications about **different** entities, the failed-lookup class
  this document legislates against — a delivery that matched but never arrived, invisibly
  (`~/dev/custom/ai/CLAUDE.md` → *A failed lookup must never look like an empty one*). For a
  transient type whose subject is per-event (`slack.message.received`, keyed on `event_id`) no two
  distinct messages ever share a subject, so the window collapses only the redeliveries idempotency
  already handles and never suppresses a distinct message. It is a **duration** (unit: **seconds**; **default: `0`** = no
  windowing, every distinct delivery fires). A suppression within the window MUST
  be **observable** — recorded and countable as "suppressed by dedupe window",
  **never a silent drop** (the document legislates against silent drops
  throughout — failed-lookup discipline). The two mechanisms are **orthogonal**:
  the dedupe window never widens or narrows the idempotency key, and a window of
  `0` leaves idempotency untouched. Keying by `(rule_id, subject)` reads the `subject` from the
  event in hand and keeps only the window's **existing short-lived per-window suppression state** —
  it introduces **no** membership set, held state, or routing state; it is the same state the
  window already holds, keyed one component finer. `subject` is defined above for
  the enumerated families — **`payload.entity_id`** for the Notion entity types,
  **`payload.event_id`** for `slack.message.received`. A **new type family**
  declares its own `subject` (its change-invariant identity field) as part of
  registering the family (see *Extending the taxonomy — a new type family declares
  its model*); a family with no declared `subject` has an **undefined** `(rule_id,
  subject)` grain and MUST NOT fall back to `rule_id` alone.

### Fan-out: every match fires

One event MUST be evaluated against **all** of the owner's enabled rules, and
**every** matching rule fires **independently**, each producing its own delivery.
There is **no first-match, no rule ordering, and no short-circuit.** A single
"ticket updated" event whose **assignees include Cody** (a `contains` match —
`assignee` is a collection) **and** whose labels contain `Flaky Test` fires BOTH
a "DM me in Slack" rule AND a "push to flaky lane" rule → two
independent deliveries, each with its own per-`(event, rule)` idempotency and
retry.

### One rule kind — the stateless routing rule

There is **one** rule kind: a **stateless routing/notify rule**. Its predicate
matches the present event → render + escape → dispatch to an adapter. It fires
per event and holds no state — the "DM me when assigned" case, and the "forward
the owner's ticket changes to the flaky lane's inbox channel" case alike. The
platform maintains **no** membership set and computes **no** add/retract
transition; a consumer that needs a working set derives and holds it itself (see
*The consumer owns membership*).

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
    event type*), has such a schema.

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
    (the same discipline as the unknown-field-path and wrongly-typed-operator hard
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
- **An UNKNOWN declared `event_type` is a HARD ERROR at rule-SAVE time,
  independent of the predicate.** Every `type` in a rule's declared
  `event_type(s)` MUST be a member of the platform's **registered/known type
  set** — an enumerated first-pass type, or a type whose family has declared its
  model (see *Extending the taxonomy — a new type family declares its model*). A
  declared type outside that set — a misspelling like `notion.ticket.updatd`, or
  a non-existent finer type like `notion.ticket.status_changed` — is rejected at
  save with a `Fix:`. This check does **not** depend on the predicate binding a
  `payload.*` leaf: an **envelope-only** predicate (e.g.
  `{field:"event.type",op:"in",value:[…]}`, the second worked example in
  *Predicates match the present*) binds only envelope fields, which exist for
  every type, so field-path validation alone would let a rule with a misspelled
  declared type **save cleanly and then match nothing forever** — a
  wrongly-computed key indistinguishable from a rule that legitimately matched
  nothing, the exact failed-lookup class (`~/dev/custom/ai/CLAUDE.md` → *A failed
  lookup must never look like an empty one*). It is a **rule save-time**
  (authoring) check, distinct from the router's runtime rule that an unknown
  well-formed `type` which *reaches routing* is **dead-lettered, never rejected**
  (see *Enumerated first-pass event types* and *Event disposition and
  dead-letter*): a rule cannot be authored against an unknown type; an event that
  arrives carrying one still dead-letters. `Fix: unknown event type '<type>' in this rule's event_type(s) — it is not a member of the registered type set. Correct the spelling; or, for a genuinely new type, declare its family's model before authoring rules against it (see 'Extending the taxonomy — a new type family declares its model'). For a per-property ticket route, declare notion.ticket.updated and filter on {"field":"payload.changed_properties","op":"contains","value":"<property-id>"}.`
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
- **A malformed predicate is a HARD ERROR at rule-SAVE time**, naming the fault
  with a `Fix:` (which node, which field, what is wrong — including an unknown
  field-path per the bullet above). It MUST NOT be a silent eval-time non-match
  at dispatch. A bad rule must be **loud where it is authored, not dark where it
  runs** — a malformed rule that silently matches nothing is indistinguishable
  from a correct rule that legitimately matched nothing.

### Predicates match the present

A predicate tree matches **ONLY the present** — the current event plus its
enriched payload. It MUST NEVER read prior state; there is no before-value in the
event to compare against. "Was-a-member / now-not" — deleted-that-had-the-label,
label-removed, assignee-changed-out — is a **direction**, and direction is **not
expressible as a predicate**: the platform holds no prior state, so it emits a
coarse current-state event and the **consumer** derives the direction by diffing
against its own held set (see *The consumer owns membership*).

`event.type` is a normal, valid leaf: a routing rule matches the present event,
and the rule's declared `event_type(s)` plus its predicate decide what it fires
on.

**Worked owner examples** (both are stateless routing rules):

- *"ticket assigned where the assignees include me → Slack DM"*:
  `{all:[{field:"event.type",op:"in",value:["notion.ticket.created","notion.ticket.updated"]},
  {field:"payload.assignee",op:"contains",value:"<cody-person-id>"}]}` → Slack
  adapter. (`payload.assignee` is a **collection** — a Notion people property
  holds zero or more people — so it is matched with `contains` / `intersects`,
  never the scalar `eq`.)
- *"the owner's ticket changes → the flaky lane's inbox channel"* (coarse route,
  consumer filters):
  `{field:"event.type",op:"in",value:["notion.ticket.created","notion.ticket.updated","notion.ticket.deleted","notion.ticket.undeleted"]}`
  → inbox adapter, flaky channel. The route is deliberately **coarse** — it
  forwards the owner's ticket state-changes rather than "currently has the flaky
  label", so a ticket whose flaky label was just **removed** still forwards its
  change event and the consumer can learn of the departure. The consumer decides
  add/keep/drop by diffing the forwarded current state against its own held set,
  and backstops with its authoritative re-sync (see *The consumer owns
  membership*). Narrowing this predicate to "currently matches the lane" would
  drop exactly the departures the consumer must hear about — do not.

The router evaluates all rules with a pure matcher and a pure renderer (Domain),
and dispatches through adapters (Side Effects). Generic router code is
tenant-blind: it takes the owner's rules as input and contains none.

---

## The consumer owns membership

The platform holds **no membership state** and computes **no** add/retract
transition. A consumer that needs a working set — the flaky admiral is the
first-pass instance — owns that set in its **own agent state**, and this contract
specifies the discipline it follows. This is where platform state is most
tempting; it is deliberately kept out of the platform.

1. **Hold the working set** in the consumer's own state, keyed by `entity_id`,
   with the display fields the consumer needs (it records them when it adds an
   entity, so it can render a line for one that later leaves).
2. **On a forwarded state-change event, diff against the held set:** an entity
   that matches lane scope and is not held → **add**; an entity that is held and
   no longer matches (label gone, reassigned, status moved out) → **drop**; a
   `notion.ticket.deleted` for a held entity → **drop** by `entity_id`. The
   platform never says "this is an add" or "this is a retract" — it says "this
   entity is now in this state" (or "this entity was deleted"); the consumer
   computes the transition.
3. **Periodically re-sync against the source of truth.** The consumer re-lists
   the authoritative scope from the source (the flaky admiral re-queries Notion
   for "flaky + mine + Todo/Backlog") on a cadence it controls, and reconciles the
   held set to it in **both** directions — adds present in the source but missing
   from the held set, and members absent from (or no longer matching) the source.
   This re-sync is the **authoritative correctness backstop**: forwarded events
   only accelerate the common case, and a dropped webhook drifts only the
   fast-path view, never the re-synced set. This is the "reliable without deltas"
   guarantee, now owned by the consumer rather than a platform store.
4. **Cancel-in-flight is a CONSUMER action.** When the consumer drops an entity a
   captain is mid-flight on, the consumer cancels its own captain from its own
   held state. There is **no** platform-delivered auto-cancel and **no**
   platform-delivered internal-control adapter. Path-2 trust still holds: forwarded
   content **informs, never authorizes** (see *Trust posture — two paths*) — the
   cancellation is the consumer's own authorized action on its own state, not an
   instruction obeyed from a message body.

This state lives client-side (the consumer's own action brief), never delivered
as an instruction in a message. A consumer that **cannot** hold its own state (a
dashboard, an email recipient) is **out of first-pass scope** — it would need a
platform-held view, which is a later re-architecture, and no hook, seam, or
"designed-for-now" interface for it is built now.

---

## The lane channel is a change stream, not the authoritative set

A lane delivered to an inbox `log` channel carries the **routed state-change
events** — each a current-state line (a delete carries `entity_id` only). Each
line MUST carry the mandatory `v` field that `ai/contracts/athena-inbox.md` →
*Line format* requires on **every** `log` line (`v` plus the framing rules are
the only universal fields; the remaining fields are this producer's own schema).
This is a conformant append-only `log` channel: the *lines* are appended.

- The channel is a **change-notification stream, NOT the authoritative set.** A
  `log` channel is retention-bounded, so the full history is not guaranteed
  reconstructable from the channel alone after a rotation or a long absence. That
  is intended.
- **The authoritative set is the consumer's own held set plus its authoritative
  re-query** (e.g. an admiral's Notion re-query — see *The consumer owns
  membership*). A session that reads only a partial stream still gets a correct
  set from the re-query; the stream accelerates the common case and lets an
  already-running consumer shrink scope (drop a departed item) without a full
  re-query.
- An unprompted surface still counts new lines only (a change signal); the
  working set is computed by the consumer on an explicit fenced read.

---

## Consumer patterns

Because the taxonomy is open, a forwarded state-change event can drive **any**
owner-configured action. The platform MUST support at least these consumer
patterns, all built on **stateless routing rules** delivering forwarded
state-change events:

- **Set consumers** (the flaky lane) — the consumer holds a working set and
  diffs each forwarded current-state event against it, dropping an entity on a
  delete or on a change that moves it out of scope (see *The consumer owns
  membership*).
- **Change messages** — an email/Slack message ("ticket X changed / left scope /
  was deleted") via an ordinary routing rule on the forwarded change or delete
  event. The message renders from the event's current-state payload (or, for a
  consumer-side departure line, from the consumer's own held display fields).
- **Fleet-control cancel-in-flight** — when a ticket is deleted, deprioritized,
  or otherwise moved out of scope while a captain is mid-flight on it, the
  consumer that holds the working set notices the drop on its own diff / re-sync
  and cancels the in-flight captain. This is the mirror of "spin a captain up",
  and it is a **consumer** action on the consumer's own state (see *The consumer
  owns membership*), not a platform-delivered auto-cancel.

**The trust boundary — Path 1 vs Path 2.** How a forwarded event acts is governed
by which trust path delivers it:

- **Path 1 (router → adapter delivery) is deterministic owner config** — the
  owner's routing rule authorizes the delivery by definition; the only hazard is
  format injection, handled by the per-adapter escapers.
- **Path 2 (content reaching an LLM session)** — a forwarded event arriving as
  untrusted *content* into an LLM session can only **recommend** an action; it
  MUST NOT self-authorize one. A consumer's own cancel-in-flight is not this case:
  it is the consumer acting on its own held state, not an imperative obeyed from a
  message body.

First-pass builds the **set-consumer** and the Path-2 **recommend-only** path.

---

## Delivery adapters

Every platform is split into **inbound** (an ingress: verify sender, content
untrusted at the LLM) and **outbound** (a delivery adapter: format + escape,
credentials). Several platforms are bidirectional; the interface accommodates
both, and build is staged.

### Adapter classification — two orthogonal axes (egress model × owner↔destination bind)

Every outbound adapter is classified on **two orthogonal axes**; conflating them
is the defect the target-bind paragraph of *Mechanism vs config boundary, and
both-ends-or-dark* guards against.

**Axis 1 — egress/SSRF model** (does the adapter connect to an owner-supplied
**network endpoint**?):

- **No egress/SSRF model** — a known transport: Slack, email, SMS, Discord,
  Notion, and the inbox adapter. There is no owner-supplied URL to resolve, so no
  SSRF surface.
- **Egress/SSRF model** — the **generic-webhook** adapter alone, which calls an
  arbitrary owner-supplied endpoint (see *The generic-webhook egress model*); it
  ships **last, after its own security review**.

An implementation MUST NOT apply the egress model to a no-egress adapter (it would
only obstruct a known-safe transport) nor omit it from the generic-webhook
adapter.

**Axis 2 — owner↔destination bind** (is the delivery destination scoped by the
adapter's **own credential**, or **supplied by the owner**?):

- **Credential-scopes-destination** — **Slack** (workspace-scoped bot token),
  **Notion** (tenant/DB-scoped token), and **Discord** when it delivers via a bot
  token to a guild the bot was authorized into. The credential cannot reach
  another account's destination, so the owner↔destination bind is **implied by the
  credential** — no explicit destination check is required.
- **Owner-supplied-destination** — the destination is rule config, not fixed by
  the credential, so an **explicit owner↔destination check IS required** (see the
  target-bind paragraph of *Mechanism vs config boundary, and both-ends-or-dark*):
  - the **inbox adapter** — a `machine + inbox_name` path, no credential — via the
    three-point machine↔owner bind;
  - **email / SMS** (roadmap) — the recipient is owner-supplied and the credential
    scopes the **sender, not the recipient** — via an owner-verified-recipient
    check;
  - the **generic-webhook** adapter — an owner-supplied URL — via the owner
    allowlist of *The generic-webhook egress model*, which is simultaneously its
    Axis-1 SSRF defense.

Every adapter is exactly one value on **each** axis. The axes are independent:
`no egress/SSRF` does **not** imply `credential-scopes-destination` (email, SMS,
and the inbox adapter are no-egress yet owner-supplied). The earlier intuition — that an adapter with **no owner-supplied endpoint** gets the owner↔destination bind **for free** from its credential — holds **only** for the credential-scopes-destination members (Slack, Notion), never for the **no-egress yet owner-supplied** adapters (email/SMS), whose credential scopes the sender, not the recipient.

The **email/SMS owner-verified-recipient** refusal — the delivery-time check the
target-bind paragraph of *Mechanism vs config boundary, and both-ends-or-dark*
requires for these roadmap owner-supplied-destination adapters — carries:
`Fix: delivery refused — recipient <recipient> is not a destination verified for this rule's owner. An email/SMS adapter's credential scopes the sender, not the recipient, so an owner-supplied recipient MUST be verified for the rule's owner (owner-confirmed recipient or owner-verified sending domain) before delivery. Verify the recipient/domain for this owner, or correct the rule.`
(This refusal is a Level-2 REFUSED disposition — recorded and reported, never a silent drop — exactly as the target-bind and generic-webhook egress refusals in *Delivery refusal — the refused-delivery store*. It **declares `owner-verified-recipient` as its refusal-cause class** in that store's open-but-declared cause set, so a refused email/SMS delivery keys on `(owner, rule_id, owner-verified-recipient)` — never an undefined key that would read as absence.)

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

**An egress rejection (an allowlist miss or a blocked-range resolution) is the
Level-2 REFUSED disposition — not a silent drop, and not a terminal FAILED.** The
rule matched (predicate TRUE) and the delivery was assembled, but this
delivery-time policy check refused it before connecting, so it MUST be **recorded
in the refused-delivery store and reported to the owner** (see *Delivery
refusal — the refused-delivery store*) — never a silent drop and never a bare counter — exactly
as the target-bind re-assertion refusal is. It is **distinct
from FAILED (terminal)**: no delivery was attempted against the destination and no
per-`(event, rule)` retry budget is consumed — a blocked destination MUST NOT be
retried. The `Fix:` naming the rejected destination (above) is the recorded
refusal's actionable marker.

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
  **generating rule**: a field is **trusted-slot-eligible iff it is platform-minted
  AND drawn from a closed platform-controlled set** — its value is computed by the
  platform, with **no** source-supplied or enrichment-derived substring and **no**
  unconstrained caller/registration-supplied parameter. A field whose value
  originated at a source, arrived on a webhook, or was returned by an enrichment
  fetch is **never** trusted-slot-eligible, however structured it looks.
- **In the first pass the trusted set is EMPTY — no field currently qualifies**,
  so **every** payload and envelope field passes through the adapter's Escaper.
  The two fields that might look platform-minted do not satisfy the generating
  rule's **closed-set** half:
  - `event.type` is **not from a closed set** — the taxonomy is **open and
    extensible** (see *The event taxonomy is open*; new well-formed types appear
    with no schema change), so a "closed taxonomy" premise for it is false.
  - `event.source` carries **parameterized, unconstrained** forms —
    `poller:<source>` and `emit:<machine_id>`, whose id substring is
    registration-supplied and bound by no grammar / charset / registered-value
    rule in this contract — so it is not a closed platform-controlled value; a raw
    slot would render that substring unescaped, the Path-1 format-injection hazard
    *Trust posture — two paths* names.

  Escaping these is a **no-op on real values** (`notion.ticket.created`,
  `poller:notion`) and closes the vector at zero cost. A **future** field that is
  genuinely platform-minted **AND** drawn from a **closed** platform-controlled set
  MAY become trusted-slot-eligible, but ONLY by a **contract amendment** that, at
  that time, defines how the escaper **identifies** a trusted-eligible field — the
  identification mechanism is deliberately **NOT specified while the trusted set is
  empty**, because there is nothing to identify. Until such an amendment the
  trusted set is empty and **every slot is escaped**.

  **EVERY field goes through the escaper** — every enrichment-derived /
  source-supplied field (`title`, `ticket_number`, `status`, `labels`,
  `assignee`, `comment_text`, `revision`, and the Slack fields `text`, `channel`,
  `user`, `ts`, `thread_ts`, `event_id`), **and** the envelope fields `event.type`,
  `event.source`, and `event.occurred_at`. **`payload.entity_id`** is the
  **source handle** (e.g. `notion:<uuid>`) — a source-supplied value that only
  *looks* like a platform-owned identifier — so it is escaped like any source
  field; escaping `event.occurred_at` (a timestamp, no markup) is a no-op that
  costs nothing and keeps the rule uniform.
- **A raw/trusted slot is a save-time HARD ERROR in the first pass** — the trusted
  set is empty, so **any** trusted/raw slot references a field outside it: `Fix: no
  field is trusted-slot-eligible in the first pass — the trusted set is empty.
  Remove the trusted/raw slot marking and use an ordinary escaped slot. Introducing
  a trusted field is a contract amendment that must first define how the escaper
  identifies it.` This is the same loud-at-author discipline every other
  unhonorable config gets (the `exists`/`absent`-with-`value` and unknown-field-path
  hard errors): the trusted-slot boundary is enforced where it is authored, not
  trusted to be drawn correctly at render time.
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
- The first-pass secret set is: the **Slack bot (`chat.write`) token** (OUTBOUND
  delivery); the **Slack app signing secret** — the INBOUND-webhook HMAC key;
  Slack signs each request `v0=HMAC-SHA256(signing_secret,
  "v0:"+X-Slack-Request-Timestamp+":"+raw_body)`, verified constant-time against
  `X-Slack-Signature` with the timestamp inside a freshness window (per *Inbound
  webhook*); the **Notion per-subscription `verification_token`** (the Notion
  inbound-webhook HMAC key); and a **read-only, DB-scoped Notion enrichment
  token**. Every first-pass inbound-webhook ingress therefore has its inbound-auth
  key named here — Slack's signing secret (per **app**) and Notion's
  `verification_token` (per **subscription**) — under the same KMS
  envelope-encryption custody, least-privilege at-use-only decrypt, and
  never-logged/never-on-`argv`/never-in-inbox-root posture as every other secret.
  The reconciliation poller carries no HMAC key: it reads the source under a
  per-account, source-scoped read token (for Notion first-pass reconciliation the
  read-only DB-scoped enrichment token above serves; a source needing a distinct
  poller token adds it here under the same custody). Any future adapter credential
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
- **When the enrichment fetch FAILS, the ingress MUST NOT emit an un-enriched
  event and MUST NOT silently drop** — either is the silent miss this contract
  legislates against (`~/dev/custom/ai/CLAUDE.md` → *A failed lookup must never
  look like an empty one*): an un-enriched event reads its known fields
  (`status`, `labels`, `assignee`, `title`, `ticket_number`) as `absent` at
  runtime, so a rule that should fire silently **FILTERs**, and because the event
  is **Level-1 HANDLED** (see *Event disposition and dead-letter*) it is **never
  dead-lettered** — an invisible miss; a drop is a silent drop. The three failure
  modes resolve distinctly, keyed on the fetch outcome:
  - **Transient failure (`429` / `5xx` / transient network).** The ingress
    **retries** the enrichment fetch under a **bounded budget** — a maximum
    attempt count with backoff, honoring a source-supplied `Retry-After` where
    present, capped by a maximum total elapsed time — before treating the failure
    as permanent. The budget carries **shape only**; its exact
    attempt/backoff/timeout constants are **ops/owner config, explicitly outside
    this contract's MUST surface** (exactly as the store cap/TTL constants — see
    *Event disposition and dead-letter*). This ingress-side enrichment-retry
    budget is **separate from** the per-`(event, rule)` delivery retry of
    *Idempotency is per (event, rule)*: it **precedes emission**, matches no rule,
    and requires **no platform membership or sequence state**. A fetch that
    succeeds within budget emits the enriched event normally.
  - **Exhausted or permanent failure (retry budget exhausted; a revoked/expired
    enrichment token → `401`/`403`; persistent `5xx`).** The ingress MUST record
    an **observable ingress-enrichment-failure** and MUST NOT emit. The record
    lives in an **ingress-failure store**, **distinct from both the dead-letter
    store and the failed-delivery store**: the event never reached routing, so it
    is **not UNMATCHED** (not dead-letter), and no rule matched, so it is **not a
    terminal delivery failure** — conflating it with either would corrupt that
    store's meaning, exactly as *Terminal delivery failure — the failed-delivery
    store* keeps those two distinct. Its grain **mirrors** the sibling stores:
    **one exemplar-plus-count per `(owner, type, enrichment-failure-cause)`** — the
    **exemplar** is the **verified webhook envelope** (source, `entity_id`) **plus
    the enrichment error** (cause class + status), which alone answers "which
    entity, of what `type`, for which owner, failed to enrich, and why?"; the
    2nd..Nth failures of the same key **increment a monotonic count** and update
    **last-seen**, storing **no** new payload. The exemplar may carry third-party
    content, so the record is **Path-2 untrusted** when read into an LLM (see
    *Trust posture — two paths*), and read access is the **owning account's** only.
    Retention follows the **never-destroy-unread** doctrine, made structurally safe
    by the grain (see *Event disposition and dead-letter* and *Terminal delivery
    failure — the failed-delivery store*). The `(owner, type, …)` key is bounded
    because only **source-emitted, enrichable `type`s** ever reach enrichment —
    harness-emit does not enrich and cannot originate a source type (see *Which
    event types an ingress kind may originate*) — and those `type`s are the
    source-webhook ingress's **finite registered origination set**, a
    registration-time config quantity, not the open taxonomy: an
    **un-triaged** exemplar has an **unbounded** lifetime (it is the sole evidence
    of the miss), age-out applies **only after** read/triage, and **the store
    carries no cap or TTL number in this contract** — any operational cap/TTL is
    ops/owner config, outside this contract's MUST surface. The failure MUST be
    **reported to the owner, never left silently quiet**, carrying the
    LLM-actionable marker:
    `Fix: enrichment fetch failed for a <type> event on entity <entity_id> (owner <owner>; cause: <class>, <status>). Emit is rejected: emitting un-enriched would read the known fields (status, labels, assignee, title, ticket_number) as absent, silently FILTER at rule evaluation, and — being Level-1 HANDLED — never dead-letter, an invisible miss. The ingress-side enrichment-retry budget is exhausted; check the read-only enrichment token/scope or the source, then the event re-enriches on source redelivery. See the ingress-failure store exemplar for the first-seen event.`
  - **Entity deleted between the webhook and the fetch is NOT an enrichment
    failure.** A **definitive not-found / gone** signal (a `404` on a change
    webhook whose entity has since been deleted) resolves to the **identity-only
    delete-event path**: the ingress emits the corresponding
    `notion.<entity>.deleted` event, which carries **identity only** and sources
    its `revision` from the **deletion webhook event itself, not an enrichment
    fetch** (see *Payload fields and their types per event type* and *Idempotency
    is per (event, rule)*) — exactly as this contract already acknowledges the
    entity "may already be unfetchable." This is kept distinct from an **auth**
    failure (`401`/`403` → the permanent case above) and a **transient** failure
    (`429`/`5xx` → the transient case above): only a not-found/deleted signal maps
    here.
- A write-scoped token (e.g. Notion outbound: post comment / update page) MUST be
  **separate** from the read-only enrichment token; do not widen the read token
  to gain write.

---

## Mechanism vs config boundary, and both-ends-or-dark

- **Mechanism = committed `apps/athena` code**, a tenant-blind public exemplar:
  the router, the event value, the rule engine (with no rule), the three ingress
  kinds, the ingress verifiers, the delivery adapters and their escapers, the
  poller runner. It carries no owner/project/rule/token/channel.
- **Config + secrets = server-side per-account DATA**: handling rules, lane
  routing configs, targets, templates, third-party tokens/creds. Never committed.
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
  registered to the rule's owner). An adapter whose **credential itself scopes the
  destination** gets this binding for free — **Slack** (workspace-scoped bot token)
  and **Notion** (tenant/DB-scoped token) deliver only through the owner's own
  KMS-custodied per-account credential, which cannot reach another account's
  destination. This is a property of *those* credentials, **not** of every
  fixed-host adapter: an adapter whose **destination is owner-supplied** carries no
  such implication and MUST enforce an **explicit** owner↔destination check —
  - the **inbox adapter** (the target is a `machine + inbox_name` path, no
    credential) enforces the three-point bind below;
  - an **addressed-messaging adapter whose recipient is owner-supplied rule config
    — email (SMTP), SMS** (both roadmap) — has a credential scoping the **sender,
    not the recipient**, so it MUST validate that the recipient resolves to a
    destination **verified for the rule's owner** (an owner-confirmed recipient /
    owner-verified sending domain), refused with a `Fix:` otherwise, exactly as the
    inbox target-bind and the generic-webhook allowlist are — never a free bind;
  - the **generic-webhook** adapter (owner-supplied URL) enforces the
    egress/allowlist model of *The generic-webhook egress model*.

  Only a credential-scopes-destination adapter (Slack, Notion) is exempt from an
  explicit destination check; the **inbox adapter has no credential** (the target
  is a path), so it MUST enforce the owner↔target binding explicitly, as follows.
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

  **Create authority (owner-stamp-at-issuance).** The `machine id → owning
  account` record is created only by an operation **authenticated as the owning
  account**; `owning account` is **stamped from that authenticated identity, NEVER
  from a request body**. The `machine id` is the identity **bound to the machine
  token** — there is **no** owner-chosen registration surface — so possession of a
  token issued to that `(account, machine)` under the account's authentication is
  the **proof of control**; an account cannot bind a machine it does not control
  because it cannot obtain a token bound to another account's machine. This is the
  **owner-from-auth invariant** (see *Rule ownership is stamped from the
  authenticated author*) applied at machine-token issuance — it is what makes the
  target-bind sound rather than circular. A create/issuance whose body-supplied
  owner differs from the authenticated account is refused: `Fix: a machine-token
  registration's owning account is stamped from the authenticated session, not the
  request body — re-issue authenticated as the account that will own this machine.`

  **The issuance and custody MECHANISM is server-side** (gen_saas machine-token /
  secret custody, **GS-4**; Notion token custody, **GS-8**) — see *Secret
  custody*. This contract states the binding invariant it depends on and defers the
  custody mechanism to that home; it does not re-specify custody here.

  **First-pass coupling.** The inbox adapter's target-bind is **first-pass** and
  reads this record **even though harness-emit ingress is roadmap**, so the
  record's owner-stamped-at-issuance creation is a **first-pass dependency of the
  inbox adapter** — the target-bind cannot be sound until the record is created
  under this invariant.
- **Enforcement is at THREE points, because the inbox target is a filesystem path
  with no credential to fail closed** (a **credential-scopes-destination** API adapter fails
  closed on its per-account credential; the inbox adapter has none, so the bind
  is asserted explicitly and more than once):
  1. **Save-time bind.** At rule create/edit the target machine's owning account
     is resolved from the record and the rule is refused (with a `Fix:`) if it is
     not the rule's owner — the **same layer** as the rule-authoring owner-stamp
     and predicate save-time validation.
  2. **Delivery-time re-assertion.** Before **each** delivery the platform
     re-resolves the target machine's **current** owner and refuses the delivery
     — **recording it in the refused-delivery store and reporting it to the owner, never a silent drop
     (this recorded refusal IS the Level-2 REFUSED disposition — see *Event disposition and
     dead-letter* and *Delivery refusal — the refused-delivery store*)** — if the
     record is absent, deregistered, or resolves to any account other than the
     rule's owner: `Fix: delivery refused — target machine <id> no longer resolves
     to this rule's owner (deregistered or re-owned). Re-author the rule against a
     machine registered to its owner.` This closes the window a save-time-only
     check would leave if the binding were **deregistered** — or otherwise ceased
     to resolve to the rule's owner — between save and delivery (under in-place
     immutability the current owner cannot *change*; it can only be deregistered),
     and it is cheap (one record lookup).
  3. **Record immutability per `machine id`.** The `machine id → owning account`
     binding is **immutable in place**. Re-registering or re-pointing an
     already-bound `machine id` to a **different** owner is **refused** with a
     `Fix:`, never a silent re-home and never an in-place invalidation: `Fix:
     machine id <id> is already bound to another account; the binding is immutable
     in place. Deregister it (authenticated as its current owner, which invalidates
     dependent rules) before re-registering it under a new owner.` Ownership
     changes only by an explicit **DEREGISTER**, authenticated as the **current
     owning account**, which **invalidates every dependent rule** (refused/flagged
     with a `Fix:`) **before** the `machine id` is free to be registered afresh by
     a new owner under the create authority above. **Ownership never transfers
     under a live rule's feet, and never transfers silently at all.** Re-homing a
     machine
     whose owning account can no longer authenticate a deregister is an
     account-recovery / admin concern — server-side (GS-4) and **roadmap**; no
     admin re-home path is built first pass.
  The separate *client-side* channel declaration remains the runtime
  both-ends-or-dark signal (channel-presence), distinct from this owner-binding.
- The never-delivered distinction — "no channel declared" vs "nothing arrived" —
  belongs to **`inbox-doctor`**, which `ai/contracts/athena-inbox.md` owns (see
  *The diagnostic: `inbox-doctor`* there, and *Relationship to the Athena Inbox
  contract* below). This contract does **not** restate or impose that obligation
  — it relies on it; the distinction is specified in the inbox contract, not
  here.
- A rule matching **zero** over a long window MUST be reported, not silently
  treated as healthy — never left silently quiet.

git-common-dir tenancy keying stays the inbox client resolver's job
(`ai/contracts/athena-inbox.md` → *Repo identity: the git common dir*). This
whole rule is the failed-lookup discipline (`~/dev/custom/ai/CLAUDE.md` → *A failed
lookup must never look like an empty one*): a dark channel is a lookup that
matched nothing and said nothing, and it MUST be made observable at every join.

---

## Relationship to the Athena Inbox contract

The inbox is **one delivery adapter** among several. This contract owns the event
platform (envelope, taxonomy, ingress, rules, predicates, adapters,
templating, trust posture, security). The Athena Inbox contract
(`ai/contracts/athena-inbox.md`) owns the inbox *channel mechanism* — the `log`
and `maildir` kinds, the doorbell, consumption state, tenancy resolution, and the
Path-2 *Untrusted input* boundary. Where the inbox adapter produces `log` lines,
it MUST conform to that contract; this contract does not restate or override it.

---

## Conformance checklists

These checklists **introduce no new normative requirement**. Each item **restates an existing
MUST** defined elsewhere in this contract (cited by section name) so an implementer of a given
role can self-check; where a checklist item and its home section ever diverge, the **home section
wins**. The roles are those of *Conformance language* (ingress / router / adapter).

**An ingress is conformant when it:**
- verifies every inbound webhook's signature over the **raw bytes as received**, constant-time,
  before anything else, hard-rejecting the unverified with a `Fix:` (*Inbound webhook*; *Sender
  verification and payload completeness*);
- stamps each event's `owner` from the **authenticated ingress**, never from the payload, and
  rejects an event whose owner cannot be resolved (*The event*);
- originates only the **finite, registered set** of `type` values permitted to its kind, and
  rejects any other `type` at ingress with a `Fix:` — harness-emit can never synthesize a
  source-emitted `slack.*`/`notion.*` type (*Which event types an ingress kind may originate*);
- resolves a metadata-only source by a **least-privilege, read-only, on-demand** enrichment fetch,
  and on enrichment failure **neither emits un-enriched nor silently drops** — retrying transients
  under a bounded budget, recording a permanent/exhausted failure in the **ingress-failure store**
  and **reporting it to the owner**, and mapping a definitive not-found to the identity-only delete
  path (*Sender verification and payload completeness*);
- rejects emitting a Notion entity event whose `payload.revision` cannot be resolved, rather than
  emit one whose idempotency key would silently collapse two changes (*Idempotency is per (event,
  rule)*);
- records a reconciliation-backstop **run** on its own, so the "I checked" signal survives even
  when every hit deduped at delivery (*Poller (fallback only)*).

**The router is conformant when it:**
- evaluates an event against **all** of the owner's **enabled** rules, firing **every** match
  independently — no first-match, no ordering, no short-circuit (*Fan-out: every match fires*);
- scopes the Level-1 HANDLED/UNMATCHED decision to the **event owner's own** rules, dead-letters
  **UNMATCHED** to the per-`(owner, type)` exemplar-plus-count store (never merely counted, never
  silently dropped), and never dead-letters a HANDLED event (*Event disposition and dead-letter*);
- resolves **every** non-DELIVERED Level-2 outcome to its own observable disposition — FILTERED,
  SUPPRESSED, REFUSED (refused-delivery store + report), FAILED (failed-delivery store + report),
  COLLAPSED — so no matched delivery is ever a silent drop (*Event disposition and dead-letter*;
  *Terminal delivery failure — the failed-delivery store*; *Delivery refusal — the refused-delivery
  store*);
- dedupes and retries at the **`(event, rule)`** grain using the event-level key combined with the
  stable `rule_id` (*Idempotency is per (event, rule)*; *Rule identity — `rule_id`*);
- applies the dedupe window at its declared **`(rule_id, subject)`** grain (*Enabled flag and
  dedupe window*);
- validates every rule at **save time** — **each declared `event_type` is a
  member of the registered type set** (predicate-independent, so an envelope-only
  rule with a misspelled type cannot save dark), field-paths against the union of
  declared types' schemas, operator cardinality, operator/literal type,
  presence-operator `value` — as **hard errors with a `Fix:`**, never a silent
  eval-time non-match (*The predicate grammar*; *Evaluation contract*; *Extending
  the taxonomy — a new type family declares its model*);
- evaluates predicates **purely, totally, deterministically, side-effect-free**, matching only the
  present (*Predicates match the present*; *Evaluation contract*);
- stamps a rule's `owner` and platform-assigns its `rule_id` from platform/authenticated identity,
  never the request body, and scopes read/list/edit/delete/disable/enable of a rule to its owning
  account (*Rule ownership is stamped from the authenticated author*; *Rule identity — `rule_id`*).

**A delivery adapter is conformant when it:**
- is classified on **both orthogonal axes** — its **egress/SSRF model** (present only for the generic-webhook adapter) and its **owner↔destination bind** (**credential-scopes-destination** or **owner-supplied-destination**) — and, when it is **owner-supplied-destination**, enforces the required explicit owner↔destination check as a delivery-time **Level-2 REFUSED** disposition per its member: the inbox adapter's three-point machine↔owner bind, the **email/SMS owner-verified-recipient** check, or the generic-webhook owner allowlist (*Adapter classification — two orthogonal axes (egress model × owner↔destination bind)*; *The generic-webhook egress model*);
- passes **every** interpolated value through its per-adapter **Escaper** for the surrounding
  context — the first-pass trusted set is **empty**, so a raw/trusted slot is a save-time hard
  error — building structured formats as **data then encoded**, never by string concat
  (*Templating and the per-adapter Escaper contract*);
- ships **no** new adapter without its escaper and its hostile-payload templating tests
  (*Per-adapter Escaper contract*);
- for the inbox adapter, enforces the **owner↔target bind** at save time and re-asserts it at
  **each** delivery (recording a refusal in the refused-delivery store + owner report), and emits a
  conformant `log` line carrying the mandatory `v` field (*Mechanism vs config boundary, and
  both-ends-or-dark*; *The lane channel is a change stream, not the authoritative set*);
- custodies secrets by **KMS envelope encryption**, decrypting least-privilege at use time for the
  owning account only, and never logs / argv-exposes / API-exposes a secret (*Secret custody*;
  *Config vs secret — the encryption boundary*).
