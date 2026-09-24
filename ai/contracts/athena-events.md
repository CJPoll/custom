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
  `webhook:notion`, `poller:<source>`, `emit:<machine_id>`, and `platform` (a
  platform-originated family, *Which event types an ingress kind may originate*
  → *Platform-originated*). The set of *forms* is closed (exactly these five),
  so every enumerated or declared `type` has a legal `source`
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

  **Later (2026-09-23):** the set of forms was exactly four, without
  `platform`. Superseded (DND-395): the platform-originated `fleet.machine.*`
  family carries `source` `platform`, which no ingress form described. Why:
  its producer is the server itself, not an ingress, so none of the four
  forms is true of it.
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
     verified-ingress-only; a `fleet.*` family is harness-emit-only, except a
     family the platform itself originates (*Which event types an ingress kind
     may originate* → *Platform-originated*).

     **Later (2026-09-23):** this item said every `fleet.*` family is
     harness-emit-only, with no exception. Superseded (DND-395): the
     `fleet.machine.*` family (gen_saas HG-20/DND-315) is originated by the
     platform's own reachability sweeper, never by harness-emit, and is
     declared as such. Why an exception rather than a rename: the name
     describes fleet state, which is what the family reports; the type is
     already shipped, so an owner rule saved against it would stop matching
     and an inbox line routed from it would change its `kind` (the type
     itself, per *Relationship to the Athena Inbox contract*), for no gain in
     safety. What matters is that no machine token can mint one, and the
     exception states that. The same amendment names the platform's producer
     in the dead-letter store's bound (*Event disposition and dead-letter*)
     and beside the three ingress kinds (*Ingress — three kinds, one event*),
     which each defer to *Platform-originated*.
  5. **Its enrichment posture** — whether its ingress enriches a metadata-only
     signal before emitting (declaring the **on-demand read** enrichment fetch,
     least-privilege enforced server-side per-caller rather than by token scope,
     per *Sender verification and payload completeness* and *Secret custody*), or
     — like harness-emit — does not enrich at all. Harness-emitted families
     (`fleet.*`) do not enrich.

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
on *"does any of the event owner's enabled rules apply to this event's `type`, or
did the event carry its own direct delivery?"*:

- **HANDLED** — at least one of the **event owner's** enabled rules declares an
  `event_type(s)` that includes this event's `type` (≥1 of the owner's rules
  *applied*), **or** the event is an addressed `fleet.session.message` or
  `fleet.session.control_changed` that received its own direct (rule-less)
  delivery (D40; *Declared families beyond the first pass* —
  `fleet.session.message`, `fleet.session.control_changed`). **Not**
  dead-lettered, regardless
  of what then happens to the individual deliveries.
- **UNMATCHED** — **none** of the **event owner's** enabled rules applies to the
  event's `type` at all (no owner rule's declared `event_type(s)` includes it),
  **and** the event carries no direct delivery. **This is the sole dead-letter
  trigger.** Scoping to the owner's own rules is required so that another
  account's rules can neither mark an event HANDLED nor suppress the owner's
  dead-letter record.

  **Later (2026-09-23):** the HANDLED/UNMATCHED split above previously keyed
  Level 1 on owner-rule matches alone. Superseded (D40, HG-16/DND-311): an
  addressed `fleet.session.message` with zero matching owner rules still has a
  delivery — the direct delivery the router creates unconditionally for an
  addressed event (below) — so treating it as UNMATCHED would dead-letter an
  event that in fact delivered. The direct delivery is the second way an event
  can be HANDLED; it does not touch UNMATCHED's dead-letter trigger for a truly
  rule-less, unaddressed event.

An **UNMATCHED** event MUST be **dead-lettered and persisted** to queryable
storage for audit and debugging; it MUST NOT be silently dropped, and it MUST NOT
be **merely counted** — a bare counter cannot answer "which event, of what type,
for which owner, went unmatched?", exactly the failed-lookup discipline
(`~/dev/custom/ai/CLAUDE.md` → *A failed lookup must never look like an empty
one*): a legitimate miss MUST remain observable as the specific thing it was. A
**HANDLED** event MUST NOT be dead-lettered.

**Level 2 — per-`(event, rule)` DELIVERY outcome (total over exactly five
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
4. **REFUSED** — predicate TRUE, but a **delivery-time owner↔destination check refused the delivery before it left the platform**. Every such check is inherently delivery-time (a save-time-only check cannot cover it — a binding can be deregistered after save, and DNS rebinding defeats a save-time destination check), and **each declares its own refusal-cause class** in the open-but-declared set of *Delivery refusal — the refused-delivery store*. First-pass: (a) the **target-bind re-assertion** — the target no longer resolves to the rule's owner, or, for a **direct** delivery (which has no rule), the event's own owner (see *Mechanism vs config boundary, and both-ends-or-dark*, the delivery-time re-assertion enforcement point); and (b) the **generic-webhook egress guard** — the resolved destination is not on the owner allowlist, or resolves to a blocked (loopback / link-local / private / metadata) range (see *The generic-webhook egress model*). Roadmap owner-supplied-destination adapters add their own: the **email/SMS owner-verified-recipient** check (cause class `owner-verified-recipient`, see *Adapter classification — two orthogonal axes (egress model × owner↔destination bind)*). A REFUSED delivery is **recorded in the refused-delivery store — one exemplar-plus-count at the grain *Delivery refusal — the refused-delivery store* states — and reported to the owner**: never a silent drop, and never a bare counter. For a **rule** delivery, **every** REFUSED trigger is **permanent** — the rule keeps matching and refusing on every delivery until the owner acts. A **direct** delivery has no standing rule to keep matching; each send is independent, so its REFUSED is a per-send outcome, not a persistent condition — but it still gets the same sibling-consistent observability (an exemplar the store *names*, plus an owner report), never merely a count.
5. **FAILED (terminal)** — predicate TRUE, delivery attempted, retries exhausted /
   adapter 5xx / credential revoked / the dispatch kept raising until its crash
   budget was spent (*Sweeper dispatch-crash rows*). Recorded in the **failed-delivery store**
   (below), **never** dead-lettered as UNMATCHED.

**Later (2026-09-23):** the "per-`(event, rule)`" grain stated above the list
previously had no exception. Superseded (D40, HG-16/DND-311): a direct
delivery is evaluated at its own key (*Declared families beyond the first
pass* → `fleet.session.message`, stated once there and deferred to here)
rather than `(event, rule)`, because it has no rule — but it can reach only
**three** of the five outcomes above, never all five: **DELIVERED**,
**REFUSED**, or **FAILED**. It can never be **FILTERED** (there is no rule and
no predicate to be false) or **SUPPRESSED** (the dedupe window is keyed
`(rule_id, subject)`, a rule field a ruleless delivery has none of — the
`fleet.session.message` direct-delivery bullets state this as a design
decision, not an oversight). Every other delivery in this document is still
per-`(event, rule)` and still totals over all five. Item 4's REFUSED
description above also previously stated its permanence with no exception
("**every** REFUSED trigger is permanent — the rule keeps matching and
refusing … until the owner acts"); superseded the same way: that holds for a
**rule** delivery, but a direct delivery has no standing rule to keep
matching, so its REFUSED is a per-send outcome, still fully observable
(store + report), just not a persistent condition.

**Each Level-2 outcome that is not DELIVERED is individually observable** —
FILTERED via ordinary accounting, SUPPRESSED per *Enabled flag and dedupe window*,
REFUSED via the **refused-delivery store and an owner report** (see *Delivery refusal — the
refused-delivery store*), covering **every declared owner↔destination refusal-cause class** — the target-bind re-assertion (per *Mechanism vs config boundary, and both-ends-or-dark*), the generic-webhook egress guard (per *The generic-webhook egress model*), and the roadmap email/SMS owner-verified-recipient check (per *Adapter classification — two orthogonal axes (egress model × owner↔destination bind)*), and FAILED per the failed-delivery store — so
**no matched delivery is ever a silent drop.**

**Why FILTERED is not a miss, and must not flood the dead-letter store.** A
routing rule declared on `notion.ticket.updated` applies to every ticket-update
event, and many such events do not satisfy its predicate (a different property
changed, or the current state does not match) — those are **FILTERED**: the rule
applied and correctly produced no delivery. Collapsing FILTERED into UNMATCHED
would flood the dead-letter store (whose whole purpose is "which event went
**unmatched**?") with routine no-ops and their full Path-2 payloads. Equally,
FILTERED must not be conflated with SUPPRESSED, REFUSED, or terminally
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
finite registered origination sets plus the declared platform-originated
families** (see *Which event types an ingress kind may originate* — origination
is a registered finite set of `type` values, never an open prefix, so no emitter
can mint an unbounded stream of distinct `type`s; its *Platform-originated*
bullet names each platform family); the taxonomy is open, but what any ingress,
or the platform itself, may *originate* is not. The bound is
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

A **terminally-FAILED** matched delivery (Level-2 outcome 5, whose causes that
item lists) MUST be recorded in a **failed-delivery store**,
**distinct from the dead-letter store**, and MUST be **reported to the owner**. A
terminally-failed matched delivery is **never** dead-lettered as UNMATCHED — it
*matched* a rule; dead-lettering it would both corrupt the dead-letter store's
"which `type` went unmatched?" purpose and mask a delivery failure as a routing
miss.

- **Grain — one exemplar-plus-count per `(owner, rule_id, terminal-cause,
  machine_id)`**, mirroring the dead-letter store's structural bound. This is the
  store's one normative statement of its key; every other mention defers to it.
  - `rule_id` is the matched rule, or `nil` for a direct (addressed, rule-less)
    delivery (the direct delivery's key is stated once in *Declared families
    beyond the first pass* → `fleet.session.message`).
  - `machine_id` is a direct delivery's **recipient machine**. It is `nil` for a
    rule delivery, because a rule has exactly one target.
  - The unique index is `NULLS NOT DISTINCT` (`nulls_distinct: false`), so every
    failure sharing one key upserts into one row, `nil` components included —
    never a row per occurrence, and never a collision between a direct row and a
    rule's.
  - The store also holds three row kinds whose cause is the platform's, not
    the owner's rule or target, each keyed on this same tuple under its own
    reserved cause: *Machine-unreachable rows*, *Sweeper dispatch-crash rows*
    and *Reconciliation re-emit rows* below each state how they fill each
    component.

  So each recipient machine's failures are a row of their own: one machine's
  unread row never absorbs another machine's failures. The **exemplar** is the
  **first failed delivery since the row was last triaged** — its **full event
  payload plus the terminal error** (cause class + adapter + target), which alone
  answers the failed-lookup question "which delivery, of which rule, to which
  target, terminally failed, and why?". A later failure of the same key
  **increments a monotonic count** and updates **last-seen**. On an **unread**
  row it stores **no** new payload. On a **read** row it **re-opens** the row
  (unread again, reported again) and its payload becomes the exemplar, so a
  re-opened row names what re-opened it. The count spans every episode of the
  row's life; only the exemplar restarts. A row aged out after triage (see
  *Retention* below) starts again at 1. This bounds the store by a
  **structural quantity** — per owner, distinct `(rule, cause)` pairs plus
  distinct `(direct recipient machine, cause)` pairs (a sweeper dispatch-crash
  row is one of either kind, under its own cause) plus one
  machine-unreachable row per machine plus one reconciliation re-emit row, a
  finite set —
  **independent of traffic volume**: a revoked credential failing a million
  deliveries collapses to one exemplar + count 1,000,000, not a million rows.

  **Later (2026-09-23):** the grain above previously assumed every failed
  delivery has a `rule_id`. Superseded (D40, HG-16/DND-311): a direct
  (addressed, rule-less) delivery's terminal failure keys with `rule_id: nil`,
  its own bucket, never colliding with any rule's, and the report marker gained
  a direct form (under *Reported, not merely stored* below).

  **Later (2026-09-23):** the grain above was then keyed on owner, rule and
  cause only, so every direct delivery of one owner under one cause shared a
  single `nil`-rule row whose exemplar named only the first-seen recipient.
  Superseded (DND-379, gen_saas #309): the key gains `machine_id`, the direct
  delivery's recipient machine (`nil` for a rule delivery). Why: with one shared
  row, a second machine's failures were counted silently into the first
  machine's unread row — no new exemplar, no new report. One row per recipient
  machine makes each machine's failure visible, and reported, on its own.

  **Later (2026-09-23):** the grain above, and the machine-unreachable bullet
  below (then titled *the one row kind that is not a delivery*), said the
  store held exactly one row kind besides failed deliveries.
  Superseded (DND-395): the store holds three — machine-unreachable, sweeper
  dispatch-crash (gen_saas DND-387) and reconciliation re-emit (gen_saas
  DND-391). Why: the code already recorded the last two, undeclared, so an
  implementation or reader following this contract did not know they exist.
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
  for the first event since last triage.` A direct row (`rule_id: nil`) carries the direct
  form instead: `Fix: direct (addressed) delivery has <count> terminal delivery
  failures to <adapter> recipients (first since last triage: <adapter>:<target>) (cause:
  <class>); check the recipient machine is connected and still declares the
  inbox, then re-send — see the failed-delivery store exemplar for the
  first event since last triage.` The row is one recipient machine's (see *Grain* above), and
  the inbox target is `<machine_id>:<inbox_name>`, so the named target
  names that machine; the row may span several of its inboxes, which is why the
  exemplar names only one of them. A direct row recorded before this grain
  may have `machine_id` `nil` (an implementation need not attribute it), and
  such a row may span machines; its named target still names only one
  machine. A row of the three platform-cause kinds under *Grain* carries
  neither form; each kind states its own marker below.

  **A failure that knows its own remedy carries it.** When a delivery
  failure's terminal error carries a non-empty `fix` — the producer knows the
  remedy, as for a line the inbox adapter cannot encode (gen_saas DND-346),
  where the fix belongs to the producer's payload, not the target or the rule
  — that `fix` replaces the generic remedy clause in either form above
  (`check the target/credential or disable the rule`, or `check the recipient
  machine is connected and still declares the inbox, then re-send`). Every
  other part of the marker is unchanged. The sweeper dispatch-crash and
  reconciliation re-emit markers below carry their exemplar's `fix` the same
  way.

  **Later (2026-09-23):** the two markers above always carried their generic
  remedy clause. Superseded (DND-395, declaring gen_saas DND-346): a
  failure's own `fix` replaces it. Why: the generic clause tells the owner to
  check a target or disable a rule when the target and the rule are fine,
  and the producer's payload is what must change.

  **Later (2026-09-23):** both markers above read `… for the first-seen event`,
  and the direct form read `(first seen: <adapter>:<target>)`. The exemplar
  (under *Grain* above) was the first-seen delivery's, with no new payload
  stored on any recurrence. Superseded (DND-386, matching gen_saas DND-373):
  a failure that re-opens a read row takes the exemplar, so the markers say
  `first since last triage`. Why: a re-opened row is reported to the owner
  again, and its report must name the failure that re-opened it, not one the
  owner already triaged.
- **Machine-unreachable rows — a row kind that is not a delivery.** The
  store also records each time a machine **becomes unreachable**, so the owner is
  told without having to write a rule for it.
  - **Cause and trigger.** Cause class `machine-unreachable`. The server judges a
    machine's reachability from delivery silence, never from socket or process
    state: a delivery to the machine older than the silence budget (the one
    *Which machine am I — the own-machine id* names), still pending or terminal
    for want of an ack, with no later ack or join, makes the machine
    unreachable (`reachable: false`). When a machine **transitions** to
    unreachable from any other verdict, the server writes this row **once per
    transition**: a latch on the machine makes a machine that stays unreachable
    write nothing more, and the latch flip and the row write commit together or
    not at all. A recovery writes nothing and never touches the row; the owner
    marks it read.
  - **Why this store.** A live-but-silent connection's deliveries terminal-FAIL
    only after the longer per-connection ack timeout, so no delivery row would
    report the outage in time. This row is the owner report, and it needs no
    rule.
  - **Key.** `rule_id` is `nil` (no rule is involved), the terminal-cause is
    `machine-unreachable`, and `machine_id` is **the machine that went
    unreachable**, under the store's *Grain* above. So there is one row per
    machine. The cause `machine-unreachable` is **reserved** for this row
    kind: a delivery's failure MUST NOT be recorded under it. That is what
    keeps this row from colliding with a direct delivery's row for the same
    machine, and why a `nil` `rule_id` means a direct delivery only for a
    delivery cause.
  - **Exemplar.** The server's own record of the transition — the machine's id
    and name, `unreachable_since`, its last ack, join and heartbeat times, and
    the count of deliveries pending at the transition — plus the terminal error:
    adapter `platform`, target `machine:<machine_id>`, the cause, the machine's
    id and name, `unreachable_since`, and the pending count. A pending count of
    `0` is stated, never omitted, so "nothing waiting" does not read as "no
    data". The record carries no third-party content.
  - **Episodes.** Every transition starts a **new episode**, even while the row
    is unread: it re-opens the row, is reported again, and **takes that
    transition's exemplar**. The count is the machine's transitions over the
    row's life; a row aged out after triage starts again at 1. This
    departs from the delivery rows' unread rule in *Grain* above on purpose:
    each transition is one outage the latch already debounced, and the recovery
    between two outages is silent, so an unread alert from an earlier outage
    must not swallow the next one. It
    is not a delivery, so no retry budget applies (*Reconciled with
    idempotency* below does not govern it).
  - **An un-notified outage is kept, up to a bound.** This is the one
    statement of the rule; every other mention defers to it. An exemplar
    is **un-notified** while the row is unread and no owner report of its
    episode has been delivered: the report failed, or has not gone out yet. A
    transition that lands on a row whose exemplar is un-notified MUST NOT
    discard it. The row **keeps** it in a list of the row's earlier un-notified
    outages, oldest first, and the new transition takes the exemplar.
    - **Bounded, never silently.** The list has an explicit bound, set by the
      implementation. Past it the row keeps the oldest entries and **counts**
      each further outage as omitted. Every omission is logged where it
      happens, and the next owner report states it (`N more earlier outage(s)
      omitted`). The transition count still includes every outage.
    - **Reported.** The next owner report MUST carry every kept earlier outage,
      at least its `unreachable_since` and pending count (a missing value
      renders `?`), and the omitted count. One report may carry several
      outages. The owner's read of the store carries every outage the row
      still keeps.
    - **Released only by delivery or triage.** A delivered owner report
      releases the earlier outages it carried and resets the omitted count to
      0; a report that fails, or that a
      newer transition superseded mid-send, releases nothing, and the next
      report carries them again. So a kept outage can be reported twice, never
      zero times. A transition on a row whose exemplar was reported, or that
      the owner has read, replaces the exemplar, starts the list empty and
      resets the omitted count to 0: the owner already has that detail.
      "Delivered" means the owner channel's transport accepted the report; a
      later bounce is outside what the platform observes.
    - **The two stated exceptions to never-destroy-unread.** Only these two
      cases discard an unread outage's detail from the store, and each leaves a
      trace:
      1. **Reported.** Once an owner report was delivered, the detail it
         carried may leave the store while the row is still unread: the
         delivery releases the earlier outages it carried, and the next
         transition replaces the reported exemplar. The detail survives in
         that delivered report, not in the store.
      2. **Overflow past the bound.** An omitted outage's detail is never kept.
         Only its count survives, and it is logged and reported as above.
  - **Marker.** `Fix: <machine> is unreachable (machine <machine_id>,
    unreachable since <unreachable_since>, <pending> pending deliveries;
    <count> transition(s) on this record) — it is connected-or-not but has
    acked nothing within the reachability window; check its inbox client
    (machine_reachable), then mark this read.` Here "the reachability window"
    is the silence budget above. `<machine>` is the machine's name, else
    `machine <machine_id>`, else `unknown machine`. A missing `<machine_id>`,
    `<unreachable_since>` or `<pending>` renders `?`. A missing pending count
    never renders `0`, which would read as "nothing waiting".
- **Sweeper dispatch-crash rows — a platform defect on a delivery.** The
  store also records a delivery whose dispatch **raised** on the periodic
  sweeper, so the owner hears of a platform defect that is holding a delivery
  back, while it is still being retried.
  - **Cause and trigger.** Cause class `sweeper-dispatch-crash`. A dispatch
    that raises (a store write raising, a bug on the dispatch path) never halts
    the sweep: the crash is logged with a `Fix:`, counted on the delivery, and
    the delivery stays pending, moves to the back of the sweep order, and is
    retried on the next pass. The crash count is cumulative over the
    delivery's life, so separate crash windows add up. A crashed dispatch is
    budget-neutral: it never spends the delivery's at-least-once retry budget
    (*Idempotency is per (event, rule)*), and never ends it as an ack timeout.
    When the count reaches the crash budget the crash is treated as permanent
    and the delivery terminates FAILED with this cause. The budget is the
    implementation's (gen_saas defaults to 240 crashes, at least an hour at
    its 15 s sweep cadence), so a transient window delays a delivery without
    failing it; like every cap here, the number is not a MUST.
  - **When a row is written.** Once per delivery episode, never per crash: on
    the delivery's **first** crash, on its **terminal** crash, and on a crash
    that finds the delivery already terminal FAILED or REFUSED with no later
    ack. In that last case the delivery's own owner-report write may be what
    raised, so this row is its only report. A delivery that left pending
    because it was acked is not reported. The crashes between log only. Unlike
    a delivery failure, the first row is written while the delivery is still
    pending, so this is the one delivery-cause row that is not always
    terminal. The terminal crash ends the delivery FAILED because its crash
    budget, not its retry budget, is spent (*Reconciled with idempotency*
    below).
  - **Key.** The crashed delivery's own key under *Grain* above: its
    `rule_id` (or `nil` for a direct delivery), the cause
    `sweeper-dispatch-crash`, and its `machine_id` (the direct recipient, `nil`
    for a rule). The cause is **reserved** for the dispatch-crash path: an
    adapter's own failure MUST NOT be recorded under it. So a delivery's crash
    reports never merge into its ordinary failure row, and the count is crash
    **reports** (first, terminal, or only-report), not crashes and not
    deliveries. A crash row takes no late-ack credit; the owner clears it.
  - **Exemplar.** The event plus the terminal error: adapter, target, the
    cause, the `delivery_id`, a summary of the exception, the crash count
    (`nil` when the crash found the delivery already out of pending), the
    disposition (`retrying`, `failed` or `not-pending`), and a `fix` saying
    this is the platform's defect, not the owner's rule or target.
  - **Marker.** `Fix: <rule <rule_id> | direct (addressed) delivery> has
    <count> dispatch crash report(s) for <adapter>:<target> (cause:
    sweeper-dispatch-crash; first: delivery <delivery_id>, <disposition>);
    <fix> — see the failed-delivery store exemplar for the first event since
    last triage.` A direct row names its target as the direct delivery
    marker above does (`<adapter> recipients (first since last triage:
    <adapter>:<target>)`). `<fix>` is the exemplar's `fix`, else `a platform
    defect; see the server log`. A missing value renders `?`.
- **Reconciliation re-emit rows — a source change the backstop could not
  re-emit.** The store also records a Notion ticket-page change that the
  reconciliation backstop (*Poller (fallback only)*) found missing and then
  failed to re-emit, so a change that never entered the platform is not lost
  silently.
  - **Cause and trigger.** Cause class `reconcile-reemit-failed`. A failed
    re-emit (the router returns an error, or the re-emit raises) puts the page
    into a **per-page retry set**, persisted per binding. The set is retried on
    every backstop run, independent of the run's watermark and of whether the
    run's snapshot succeeded, and each attempt is logged. A page leaves the set
    when it re-emits, when the platform ingests that revision (or a newer one)
    some other way, or when a newer revision supersedes it; a superseding
    revision is a new change and starts its attempts again at 1. Holding the
    watermark for a failed page is not the mechanism: one page that always
    fails would hold the window open without limit.
  - **Dispositions.** A row is written, and the owner told, in exactly three
    cases, named in the exemplar's `disposition`:
    - `exhausted` — the page is still failing at the per-revision attempt cap.
      It is reported and removed from the set in one transaction.
    - `retry-set-full` — a new failure finds the binding's set at its entry
      cap. It is reported at once and not queued.
    - `untracked` — the set's own store cannot hold the page. It is reported
      at once, unless the set already holds that revision.

    Both caps are the implementation's (gen_saas defaults to 12 attempts per
    revision and 500 entries per binding); like every cap here, neither number
    is a MUST. What is a MUST is that every page either stays in the set, is
    re-emitted or ingested, or is reported: none leaves silently.
  - **Key.** `rule_id` `nil` (no rule is involved), the cause
    `reconcile-reemit-failed`, and `machine_id` `nil` (no machine is
    involved), under *Grain* above. So there is one row per owner. The cause
    is **reserved** for this row kind: a delivery's failure MUST NOT be
    recorded under it. That is what keeps this row from colliding with a
    legacy direct row that has no machine.
  - **Exemplar.** The first page since last triage, as under *Grain* above.
    Its event carries only the page's `entity_id` and `revision`, never page
    content, and is never routed. The terminal error names adapter
    `notion-reconciliation`, the page's `entity_id` as target, the cause, the
    binding, database and page ids, the revision, the attempts made, both
    caps, the disposition, the router's `last_error` (truncated) and a `fix`.
    `last_error` can quote a store error's detail, so the owner report never
    carries it; the exemplar and the server log do.
  - **Count.** Nothing was delivered, so nothing can be acked late and the
    row takes no late-ack credit. The count is reports over the row's life,
    across episodes. It is not a delivery, so *Reconciled with idempotency*
    below does not govern it; the backstop's own retry set is its retry.
  - **Marker.** `Fix: the Notion reconciliation backstop could not re-emit
    ticket page changes (<count> report(s) on this record, all episodes;
    cause: reconcile-reemit-failed; first since last triage: page <page_id>
    at revision <revision> of database <database_id>, <disposition phrase>);
    <fix> — see the failed-delivery store exemplar for the page and the last
    error.` The disposition phrase is `exhausted after <attempts> attempt(s)`,
    `retry set full, not queued for retry`, or `the retry set could not hold
    it, not queued for retry`. `<fix>` is the exemplar's `fix`, else `a
    platform defect; see the server log`. A missing value renders `?`.
- **Retention — the never-destroy-unread doctrine applies, made safe by the
  grain.** Follow the sibling inbox doctrine (`ai/contracts/athena-inbox.md` →
  *Retention* → *The principle*), exactly as the dead-letter store does: an
  **un-triaged** failed-delivery exemplar has an unbounded lifetime (it is the sole
  evidence of the miss); age-out applies only after read/triage; the store's
  *Grain* above bounds it to at most one unread exemplar per key, plus a
  machine-unreachable row's bounded list of earlier un-notified outages
  (*Machine-unreachable rows* → *An un-notified outage is kept, up to a bound*
  above), which also states the two exceptions this store makes.
  **The store
  carries no cap or TTL number in this contract** — any
  operational cap/TTL is ops/owner config, outside this contract's MUST surface.

  **Later (2026-09-23):** this bullet previously stated the doctrine with no
  exception. Superseded (DND-386, declaring the row kind gen_saas files under
  DND-369/DND-379): a machine-unreachable row's exemplar is replaced by each new
  transition, so an unread row keeps only its latest outage's exemplar. Why:
  each transition is a separate outage, reported on its own, and the latest one
  is the outage the owner must act on.

  **Later (2026-09-23):** the label above added an exception: a
  machine-unreachable row's next transition replaced its exemplar even unread,
  and *Episodes* said only the transition count survived an earlier outage,
  plus its owner report if that went out first. Superseded (DND-396, gen_saas):
  the exception is narrowed to two stated cases: an exemplar whose owner report
  was delivered, and a logged, reported overflow past an explicit bound. An
  exemplar whose owner report has not been delivered is kept in a bounded list
  and reported, not replaced (*Machine-unreachable rows* → *An
  un-notified outage is kept, up to a bound*). Why: when an
  earlier outage's report failed, or had not gone out, before the next
  transition, the replace destroyed that outage's detail silently, and only
  the count remained.
- **Reconciled with idempotency.** "Terminal" means the per-`(event, rule)`
  at-least-once retry budget of *Idempotency is per (event, rule)* is exhausted,
  or, for a dispatch that keeps raising, its crash budget is (*Sweeper
  dispatch-crash rows* above); the failed-delivery record is that delivery's
  terminal state. The one delivery-cause record written before its delivery
  is terminal is a dispatch-crash row's first report, which that bullet
  states. A later
  at-least-once redelivery of the same `(event, rule)` is absorbed by the
  idempotent consumer and does **not** manufacture a second failure record; the
  record is keyed on the store's *Grain* above, not on any per-change dedupe
  key.

  **Later (2026-09-23):** "terminal" meant only the retry budget exhausted, and
  every delivery-cause record was a terminal state. Superseded (DND-395,
  declaring gen_saas DND-387): a crashed dispatch spends a separate crash
  budget, never the retry budget, and its first crash is reported while the
  delivery is still pending. Why: so a platform defect is neither charged to
  the owner's retry budget nor left unreported until it ends.

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

- **Grain — one exemplar-plus-count per `(owner, rule_id, refusal-cause, machine_id)`**,
  mirroring the failed-delivery store. This is the store's one normative statement of its key;
  every other mention defers to it.
  - `rule_id` is the matched rule, or `nil` for a direct (addressed, rule-less) delivery (the
    direct delivery's key is stated once in *Declared families beyond the first pass* →
    `fleet.session.message`). A direct delivery's refusal is, for example, a target-bind
    re-assertion refusal on a recipient deregistered after send.
  - `machine_id` is a direct delivery's **recipient machine**. It is `nil` for a rule delivery,
    because a rule has exactly one target.
  - The unique index is `NULLS NOT DISTINCT` (`nulls_distinct: false`), the same shape as the
    failed-delivery store's (*Terminal delivery failure — the failed-delivery store*), so every
    refusal sharing one key upserts into one row, `nil` components included — never a row per
    occurrence, and never a collision between a direct row and a rule's.

  So each recipient machine's refusals are a row of their own. This bounds the store by a
  **structural quantity** — per owner, distinct `(rule, refusal-cause)` pairs plus distinct
  `(direct recipient machine, refusal-cause)` pairs, a finite set — **independent of traffic
  volume**.

  `refusal-cause` is an **open-but-declared set**: each **owner↔destination check declares its own cause class**, exactly as *Extending the taxonomy — a new type family declares its model* makes a new event family a declared increment rather than a free addition. The set is "open" in that a new owner-supplied-destination check adds its class with **no edit to this store**; it is "declared" in that **no delivery may be refused under a cause class the refusing check has not declared** — an undeclared cause is a hard error, never an unlabelled miss (`~/dev/custom/ai/CLAUDE.md` → *A failed lookup must never look like an empty one*). First-pass the declared classes are **target-bind re-assertion** (recorded as `target-bind`) and **generic-webhook egress** (recorded as `generic-webhook-egress`); the roadmap **email/SMS owner-verified-recipient** check declares **`owner-verified-recipient`** (see *Adapter classification — two orthogonal axes (egress model × owner↔destination bind)*), and any future owner-supplied-destination check declares its own. Because the key is the declared class, the grain stays bounded by a **structural quantity** — the pairs above, each over a declared cause — independent of traffic volume, and correct the moment a new check declares its class. The **exemplar** is the **first refused delivery since the row was last triaged** — its **full event
  payload plus the refusal detail** (cause class + adapter + the target/destination that was
  refused), which alone answers "which delivery, of which rule, to which target, was refused, and
  why?". A later refusal of the same key **increments a monotonic
  count** and updates **last-seen**. On an **unread** row it stores **no** new payload. On a
  **read** row it **re-opens** the row (unread again, reported again) and its payload becomes the
  exemplar, as in the failed-delivery store's *Grain*. A revoked binding refusing a
  million deliveries collapses to one exemplar + count 1,000,000, not a million rows.

  **Later (2026-09-23):** the grain above previously assumed every refused
  delivery has a `rule_id`. Superseded (D40, HG-16/DND-311): a direct
  (addressed, rule-less) delivery's refusal keys with `rule_id: nil`, its own
  bucket, never colliding with a rule's, and the report marker gained a direct
  form (under *Reported, not merely stored* below).

  **Later (2026-09-23):** the grain above was then keyed on owner, rule and
  refusal-cause only, so every direct delivery of one owner under one cause
  shared a single `nil`-rule row whose exemplar named only the first-seen
  recipient. Superseded (DND-381, gen_saas #313): the key gains `machine_id`,
  the direct delivery's recipient machine (`nil` for a rule delivery), mirroring
  the failed-delivery store's DND-379 change. Why: with one shared row, refusals
  to a second machine were counted silently into the first machine's row. One
  row per recipient machine makes each machine's refusal visible, and reported,
  on its own.
- **Never merely counted; observable.** As with the sibling stores, the exemplar is retained so
  the store *names* the refused delivery; the count is added scale metadata, never a replacement.
  The exemplar payload carries third-party content, so the record is **Path-2 untrusted** when
  read into an LLM (see *Trust posture — two paths*), and read access is the **owning account's**
  only.
- **Reported, not merely stored.** REFUSED MUST be **reported to the owner, never left silently
  quiet**, carrying the LLM-actionable marker: `Fix: rule <rule_id> has <count> refused deliveries to <adapter>:<target> (refusal-cause: <cause>) — apply the remediation the refusing owner↔destination check declares for <cause>: <remediation>. See the refused-delivery store exemplar for the first event since last triage and its declared refusal detail.` `<remediation>` is the row's own cause's entry in the table below, and only that entry: another cause's remedy would send the owner to fix the wrong thing. A direct row (`rule_id: nil`) carries the direct form instead: `Fix: direct (addressed) delivery has <count> refused deliveries to <adapter> recipients on machine <machine_id> (first since last triage: <adapter>:<target>) (refusal-cause: <cause>) — apply the remediation the refusing owner↔destination check declares for <cause>; a direct delivery has no rule to re-author. See the refused-delivery store exemplar for the first event since last triage and its declared refusal detail.` The row is one recipient machine's (see *Grain* above) but may span several of its inboxes, so the exemplar names only one target. A direct row recorded before this grain may have `machine_id` `nil` (an implementation need not attribute it); its marker omits the `on machine <machine_id>` clause, because that row may span machines.

  The per-cause remediation table, one entry per declared refusal-cause (the cause ids are the refused-delivery store's `refusal-cause` values):

  | `refusal-cause` | Refusing check | `<remediation>` |
  | --- | --- | --- |
  | `target-bind` | target-bind re-assertion | re-author the rule against a machine registered to its owner |
  | `generic-webhook-egress` | generic-webhook egress | correct the owner allowlist or the destination |
  | `owner-verified-recipient` | email/SMS owner-verified-recipient | verify the recipient or the sending domain for this owner, or correct the rule |

  A check that declares a new cause adds its row here with its remediation. An implementation MUST NOT render a rule marker whose cause has no entry as another cause's remedy or as an empty clause. An undeclared cause cannot be recorded (the declared set above), so only a row stored under a cause since removed from the set reaches this case; its marker says `no remediation is declared for this cause (a platform defect: the cause is not in the declared set)`.

  **Later (2026-09-23):** the rule marker's remediation clause listed every declared cause's remediation after `declares for <cause>:`, each prefixed with its check's name (`target-bind re-assertion → …; generic-webhook egress → …; owner-verified-recipient (email/SMS) → …`). Superseded (DND-395, gen_saas): the clause carries only the row's own cause's remediation, from the table above. Why: the full list put another cause's remedy first in the owner email, so an owner read the wrong fix for their row.

  **Later (2026-09-23):** both markers above read `… for the first-seen event …`, and the direct
  form read `(first seen: <adapter>:<target>)`. The exemplar (under *Grain* above) was the
  first-seen refusal's, with no new payload stored on any recurrence. Superseded (DND-386,
  matching gen_saas DND-384): a refusal that re-opens a read row takes the exemplar, so the
  markers say `first since last triage`. Why: a re-opened row is reported to the owner again,
  and its report must name the refusal that re-opened it, not one the owner already triaged.
- **Retention — the never-destroy-unread doctrine applies, made safe by the grain**, exactly as
  the dead-letter, failed-delivery, and ingress-failure stores (see *Event disposition and
  dead-letter*): an un-triaged refused-delivery exemplar has an **unbounded** lifetime (it is the
  sole evidence of the miss); age-out under the product data-retention policy applies **only
  after** it has been read/triaged; the store's *Grain* above bounds it to
  **at most one unread exemplar per key**. **The store carries no cap or TTL number in this
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
- `slack.interaction.received` — a verified Slack **interactivity** callback (a
  block-action click). Originated **only** by the Slack inbound-webhook ingress
  after signature verification; **harness-emit can never mint it** (see *Which
  event types an ingress kind may originate*). Its payload and identity are in
  *Payload fields and their types per event type*.
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
schema, so any `payload.*` leaf is unbindable). The redirect is ground (1)'s own
refusal: its per-property sentence names `notion.ticket.updated` and the
`changed_properties` leaf (quoted in *The predicate grammar* → *Evaluation
contract*). A finer type is an unknown type, so it gets no refusal of its own.
Ground (1) is also the one that reports: the save checks the declared types
first and stops at the first refusal, so ground (2) never reaches the author
for a finer type.

**Later (2026-09-24):** this paragraph quoted a separate "redirecting" refusal
("unknown event type '<type>' — the first pass emits no per-property ticket
types …"). No code emitted it. The shipped code gives a finer type the one
unknown-`event_type` refusal, which already carries the redirect, and that is
the design (DND-411).

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
| | `revision` — OPTIONAL source-supplied provenance / ordering hint (Notion: `last_edited_time`, or finer); not a dedupe key | string | scalar |
| | `changed_properties` (`notion.ticket.updated` only) | string | **collection** |
| `notion.ticket.deleted` (the **un-enriched** delete type — the entity may already be unfetchable, so it carries identity only) | `entity_id` — stable source entity handle | string | scalar |
| | `revision` — OPTIONAL provenance from the deletion event (not an enrichment fetch); not a dedupe key | string | scalar |
| `notion.comment.created`, `notion.comment.updated` (the **enriched** comment types) | `entity_id` — stable source entity handle | string | scalar |
| | `comment_text` | string | scalar |
| | `ticket_number` | string | scalar |
| | `title` | string | scalar |
| | `revision` — OPTIONAL source-supplied provenance / ordering hint (Notion: `last_edited_time`, or finer); not a dedupe key | string | scalar |
| `notion.comment.deleted` (the **un-enriched** delete type — the comment may already be unfetchable, so it carries identity only) | `entity_id` — stable source entity handle | string | scalar |
| | `revision` — OPTIONAL provenance from the deletion event (not an enrichment fetch); not a dedupe key | string | scalar |
| `slack.message.received` | `text` | string | scalar |
| | `channel` | string | scalar |
| | `user` | string | scalar |
| | `ts` | string | scalar |
| | `thread_ts` | string | scalar |
| | `event_id` | string | scalar |
| `slack.interaction.received` (a verified block-action click — transient, never updated) | `channel` | string | scalar |
| | `ts` — the message the interactive element lives on | string | scalar |
| | `action_id` | string | scalar |
| | `action_ts` — Slack's action timestamp | string | scalar |
| | `value` — the interactive element's opaque `value` (carries the server-stamped tagged return address — see *Machine↔owner API binding and the outbound return-address dual*); Path-2 untrusted until its tag verifies | string | scalar |
| | `actor.user_id` — the clicking Slack user | string | scalar |
| | `actor.is_owner` — whether that user is the account's expected owner | boolean | scalar |

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
The refusal is the existing unknown-field-path save-time one, naming the
declared types: `field-path "<path>" is not in the union of this rule's declared event_type(s)' payload schemas <types>. Fix: correct the spelling (nearest valid fields: <valid fields, comma-separated> (given: "<path>")); or, if the field lives only on a type this rule does not declare, add that event_type to the rule.`
`<types>` renders as a list, e.g. `["notion.comment.deleted"]`.

**Later (2026-09-24):** this paragraph quoted a delete-specific refusal
("field-path 'payload.comment_text' is not in notion.comment.deleted's payload
schema (identity-only: entity_id). A delete carries no enrichment …"). No code
emitted it; the generic unknown-field-path refusal above is what ships, and
this quote now matches it (DND-411). The "nearest valid fields" it names is
every valid field of the declared types, not a computed nearest match.

**`slack.message.received` carries `ts` and `event_id`** (not just
`occurred_at`): the deployed inbox reader keys cross-source dedupe on
`channel:ts` and on seen `event_id`s (against the Slack Web-API backstop — see
`ai/contracts/athena-inbox.md`), which `occurred_at` alone does not cover. They
are part of the closed schema so a rule may bind them and the dedupe pairing is
expressible.

**`slack.interaction.received` is a transient event, not a persistent entity** —
like `slack.message.received`, it carries **no `entity_id`** and **no
`revision`**. Its identity is the tuple **`{channel, ts, action_ts}`** (the
message the element lives on plus Slack's action timestamp), unique per click; a
consumer that must dedupe clicks keys on that tuple. The `value` and (phase-2
modal) `private_metadata` it returns are **source-supplied and Path-2 untrusted**
— they carry the server-stamped tagged return address, and a returned `value` /
`private_metadata` is trusted **only after its tag verifies AND its account
equals the owner of the app the click arrived on** (see *Machine↔owner API
binding and the outbound return-address dual*). Neither field is
trusted-slot-eligible.

**`payload.revision` is an OPTIONAL source-supplied provenance / ordering hint
for a Notion entity type.** It is the source's own revision/version indicator for
the entity state the event reflects (Notion: `last_edited_time`, or a finer
source-provided revision token where one exists — the ingress binds the finest the
source exposes), carried **when the source exposes it**. It is **source-supplied,
not platform-minted** — so it is escaped like any source field and is **not**
trusted-slot-eligible (see *Templating and the per-adapter Escaper contract*). It
is **not** a dedupe key: delivery is at-least-once and correctness rests on
consumer idempotency over **current enriched state**, not on distinguishing two
changes to the same `entity_id` at an event-level key (see *Idempotency is per
(event, rule)*), so a coarse or **missing** `revision` is not a hazard and never an
emit-blocking error. The enriched types read it during enrichment; the
identity-only delete types (`notion.ticket.deleted`, `notion.comment.deleted`)
source it from the deletion **webhook event itself, not an enrichment fetch** —
preserving their identity-only property. `slack.message.received` carries **no**
`revision`: a Slack message is transient and never updated, and its
`payload.event_id` is already unique.

### Declared families beyond the first pass — `fleet.session.message`, `notion.agent_message.*`, `fleet.machine.*` and `fleet.session.control_changed`

Four type families are **declared** here per *Extending the taxonomy — a new type
family declares its model* (each declares its five things), so a later increment
that lands their ingress is a natural addition, not a rewrite. None is one of
the enumerated first-pass source-webhook types above.

**The `fleet.session.message` family** (session-to-session messaging):

1. **Payload schema** — `to` (**object** `{machine_id, inbox_name}`, OPTIONAL —
   the router target minus `owner`, which is never caller-supplied; its presence
   makes the message *addressed*), `from` (**object** `{machine_id, inbox_name}`
   — **server-stamped**, see origination), `subject` (string, scalar,
   **required**, non-empty), `body` (string, scalar), `re` (string, scalar,
   optional), `thread` (string, scalar, optional) — **at least one of `re` /
   `thread` is required** (the referent rule): a message naming neither is
   refused at ingress with `Fix: a session message must name what it is about —
   set re: <path|url> or thread: <event_id of the message you are answering>`.
   The addressable predicate leaves are `payload.to.machine_id`,
   `payload.to.inbox_name`, `payload.from.machine_id`, `payload.from.inbox_name`;
   any other `payload.*` leaf is the ordinary unknown-path save-time error.

   **Later (2026-09-23):** this schema previously declared `to` as a string
   scalar `owner/machine/inbox`, `from` as a string scalar, `subject` as
   optional, and no referent rule. Superseded by the architect's pin of
   2026-09-23 (epic decision D39), reconciling the contract with the HG-15
   ticket (DND-310) and its implementation. Why each: `to` is an **object**
   because it is the inbox adapter's target map `{machine_id, inbox_name}`
   verbatim (*Mechanism vs config boundary, and both-ends-or-dark*) and a
   caller-supplied `owner` segment would be a 6D violation dressed as an
   address — `owner` comes from the token and a cross-owner `to` is refused,
   so the address never carries it; `from` is an **object with an
   `inbox_name`** because a recipient cannot reply to a session without an
   inbox address (the R9 reply-ability requirement) — `from.machine_id` is
   stamped from the token and `from.inbox_name` is the sender's **declared
   sending instance**: the caller names one of its OWN machine's declared
   instances (a within-scope selector, verified server-side against the
   machine's instances, refused with a `Fix:` if it names another machine's
   or an undeclared one), never a free string; `subject` is **required**
   because the delivered `session.message` line is read fenced and
   counts-first, and a reader must be able to see what a message is about
   before opening its body; the referent rule is R9.
2. **Identity field** — the **platform event id** (per-event, as
   `slack.message.received` uses `payload.event_id`). It is the `subject` of the
   dedupe window. The `session.message` inbox line's `entity_id`
   (`ai/contracts/athena-inbox.md` → *Platform `log` line kinds*) is
   `"session:<event_id>"` (D40), where `event_id` is this identity field — the
   persisted `event_router_events` row id, not a payload field, because the
   line is built at delivery time from the persisted event, not from its own
   payload. That form is stated here, once; `athena-inbox.md` defers to it by
   name, the same pattern *Declared families beyond the first pass* uses for
   `notion.agent_message.*`'s `entity_id`.
3. **Change/revision token** — none: a session message is **transient and never
   updated**, so identity alone is unique and no revision token exists.
4. **Origination membership** — **harness-emit only** (a harness-emitted `fleet.*` family; see
   *Harness-emit* and *Which event types an ingress kind may originate*). No
   source ingress and no reconciliation poller originates it; a source-emitted
   ingress that tried would be rejected.
5. **Enrichment posture** — **none**. Harness-emitted; nothing is fetched.

`from.machine_id` is **server-stamped from the machine-token registration
record** — the same record harness-emit resolves `owner` from and the
target-bind check reads (*Machine↔owner API binding and the outbound
return-address dual*; *Mechanism vs config boundary, and both-ends-or-dark*).
`from.inbox_name` is the sending session's **declared instance on that same
machine**, selected by the caller from its own machine's instances and verified
server-side (both-ends-or-dark applies to the sender too: an undeclared sending
inbox is refused, never stamped as a free string). A caller-supplied
`from.machine_id` (or `owner`, or `type`) is **refused with a `Fix:`** — the 6D
principle for this family: `Fix: fleet.session.message 'from.machine_id' is
stamped server-side from the authenticated machine token, not the request body —
remove it and re-emit; 'from.inbox_name' must name one of this machine's
declared instances.` An **addressed**
message (`payload.to` present) is delivered **directly to the same-owner target**
(the target machine's session inbox), in addition to ordinary rule fan-out — the
delivery dual of the Slack-click direct route (design §4/§D6), same-owner only; a
**broadcast** (no `payload.to`) fans out through rules alone.

An addressed message's direct delivery, made normative (D40, HG-16/DND-311):

- **One direct, rule-less delivery, atomically with the event and its rule
  fan-out.** The router creates exactly one direct delivery row to
  `payload.to` in the same transaction it persists the event and matches
  owner rules; owner rules on `fleet.session.message` still fan out, in
  addition to the direct delivery, never instead of it.
- **HANDLED even with no matching rule.** An addressed event with zero
  matching owner rules is not dead-lettered: the direct delivery alone makes
  the event `handled`. Only a broadcast (`payload.to` absent) with no
  matching rule is `unmatched`.
- **A recipient machine not owned by the sender's owner is refused as
  `not_found`, with no write.** Same answer as a nonexistent machine (D19, no
  existence disclosure) — nothing is persisted, and the refusal happens
  before the event or any delivery row is created.
- **An undeclared recipient inbox is refused with a `Fix:`, with no write.**
  No live agent instance on the (same-owner) target machine declaring
  `to.inbox_name` is both-ends-or-dark, not a silent drop: the refusal names
  the HG-17/HG-18 registration convention, and nothing is persisted.
- **A direct delivery's key is `(owner, event)` with `rule_id: nil` — the
  ONE canonical description, used the same way everywhere this document and
  `athena-inbox.md` refer to it.** Level 2 above is defined per `(event,
  rule)`; a direct delivery has no rule, so `rule_id` is `nil` rather than
  absent — a delivery row always has the shape `(owner, event, rule_id)`, and
  a direct delivery is the one case where `rule_id` is `nil` rather than a
  real id. Because at most one direct delivery exists per event (owner-scoped,
  structurally enforced — a second `create_direct` for the same event is a
  changeset error, never a duplicate row), `(owner, event)` alone is already
  as specific as `(owner, event, rule_id)` is for a rule delivery: no second
  disambiguating component is needed. Every Level-2 store that keys on
  `rule_id` accepts a `nil` there for a direct delivery, never a collision
  with a rule's bucket; the full key, including the recipient machine, is the
  grain each store states (*Terminal delivery failure — the failed-delivery
  store*; *Delivery refusal — the refused-delivery store*). Retry (below)
  applies to this row using the same key; the sweeper's staleness query
  selects by delivery status and `last_pushed_at`, not by `rule_id`, so a
  direct delivery is retried and can terminally FAIL exactly like a rule
  delivery.
- **REFUSED (target-bind) covers a direct delivery too; SUPPRESSED (dedupe
  window) does not, by design.** The delivery-time target-bind re-assertion
  (`InboxAdapter`, Level 2's REFUSED, cause `target-bind`) is the inbox
  adapter's own delivery-time check and runs for every delivery it pushes,
  rule-based or direct, so a direct delivery whose target is deregistered
  after send is REFUSED exactly like a rule's. The dedupe window, by
  contrast, is keyed `(rule_id, subject)` (*Enabled flag and dedupe window*)
  — a **rule** field, an owner's standing preference tuned on a rule they
  configured — so a direct delivery, addressed by a human/agent choice each
  time rather than through a standing rule, has no window to key on and is
  never collapsed: nothing rate-limits one owner's session-message fan-out to
  itself. This is a design decision for this pass, not an open item.
- **A FAILED or REFUSED direct delivery reports through the same two stores,
  under the direct-delivery key and report form each store states** — *Terminal delivery
  failure — the failed-delivery store* and *Delivery refusal — the
  refused-delivery store*, each amended for this case rather than restated
  here.

**The `notion.agent_message.{created,updated,deleted}` family** (Agent Messages
routing):

1. **Payload schema** — `entity_id` (string, scalar — the stable source
   entity handle `notion:<page id>`, the same form every other `notion.*`
   family carries; see *Payload fields and their types per event type*),
   `row_id` (string, scalar — the **bare** Notion page id, which the consumer
   re-fetches the row by), `from` (string, scalar), `subject` (string, scalar),
   `sent_at` (timestamp, scalar), `to` (string, **collection**), `acked_by`
   (string, **collection**), `thread` (string, **collection**), `re` (string,
   scalar, optional), `sending_owner` (string, **collection**),
   `recipient_owner` (string, **collection**), `revision` (string, scalar).
   `notion.agent_message.deleted` carries `entity_id`, `row_id`, and
   `revision` only. **NO `body` field** — the line is a **trigger**; the Notion
   row is the authority (the consumer re-fetches the row).
2. **Identity field** — `entity_id` (`notion:<page id>`), naming the same
   page as `row_id`.

   **Later (2026-09-23):** the schema above previously carried no `entity_id`
   and named the bare page id (`row_id`) as the identity field. Superseded by
   admiral decision D-ADM-4 (AM-2/AM-5). An inbox line built from this payload
   could not be read: the inbox reader and the server line encoder both key
   every platform line on `entity_id` (`ai/contracts/athena-inbox.md` →
   *Platform `log` line kinds*). The `notion:<uuid>` form keeps this family
   consistent with the entity-handle rule every `notion.*` family follows.
3. **Change/revision token** — `revision` = the row's `last_edited_time` (a
   persistent entity that is updated).
4. **Origination membership** — the **Notion inbound-webhook ingress** and the
   **reconciliation poller** only (verified-ingress-only, exactly as the other
   `notion.*` families). Harness-emit can never mint it.
5. **Enrichment posture** — **yes**: the metadata-only Notion webhook is enriched
   on the verified event (per *Sender verification and payload completeness*),
   minus the body (no body is ever carried).

**The `fleet.machine.{unreachable,reachable}` family** (machine reachability
transitions, gen_saas HG-20/DND-315):

1. **Payload schema** — the addressable leaves, each a scalar: `entity_id`
   (string, `machine:<machine_id>`), `machine_id` (string), `machine_name`
   (string), `unreachable_since` (timestamp), `last_ack_at` (timestamp),
   `last_joined_at` (timestamp). The payload also carries `last_heartbeat_at`
   and `pending_deliveries` (an integer count, which the declared field types
   cannot type); neither is addressable, so a predicate or template slot on
   either is the ordinary unknown-path save-time error. A missing
   `pending_deliveries` is absent, never `0`.
2. **Identity field** — `payload.machine_id`, the machine the transition is
   about; it is the `subject` of the dedupe window. `payload.entity_id`
   (`machine:<machine_id>`) names the same machine. An inbox line routed from
   this family is a lane state-change line (its `kind` is the `type`, per
   *Relationship to the Athena Inbox contract*), and `entity_id` is its
   reconciliation identity (`ai/contracts/athena-inbox.md` → *A lane `log`
   channel is a change stream of state-change events*).
3. **Change/revision token** — none in the payload: each event is one
   transition and is never updated. The transition instant
   (`unreachable_since` for `unreachable`, the emit time for `reachable`) is
   folded into the event's `idempotency_key`
   (`<type>:<machine_id>:<instant>`) as provenance a consumer may dedupe on.
   The platform does not dedupe on it (*Idempotency is per (event, rule)*).
4. **Origination membership** — **platform-originated only** (*Which event
   types an ingress kind may originate* → *Platform-originated*). Harness-emit
   and every source ingress are refused.
5. **Enrichment posture** — **none**. The server already holds every field.

`owner` is the machine's owner and `source` is `platform`. The sweeper emits
`unreachable` once per transition into unreachable, and `reachable` once per
recovery that an ack or a join proves (a heartbeat alone never announces a
recovery). The unreachable transition's owner report does not depend on this
event reaching a rule: the failed-delivery store records it too (*Terminal
delivery failure — the failed-delivery store* → *Machine-unreachable rows*),
committed together with this event and the machine's latch.

**The `fleet.session.control_changed` family** (a fleet session's control
state changed; the epic "fleet visibility and control", DND-429):

1. **Payload schema** — each a scalar: `entity_id` (string,
   `fleet_session:<id>`, where `<id>` is the server's fleet-session row id),
   `claude_session_id` (string), `desired` (string, `run` | `drain`), `reason`
   (string, one of the reason classes of *Fleet registry and session control*
   → *Session control: desired state*), `until` (timestamp, OPTIONAL: absent
   when the state has no scheduled end, never `null`). Plus `to` (**object**
   `{machine_id, inbox_name}`, OPTIONAL, **server-stamped**, never supplied by
   anyone): the session's own machine and its project's session inbox
   (`<project>-session.jsonl`, `ai/contracts/athena-inbox.md` → *Registry
   convention for a session inbox*). The addressable leaves are those scalars
   plus `payload.to.machine_id` and `payload.to.inbox_name`; any other
   `payload.*` leaf is the ordinary unknown-path save-time error.
2. **Identity field** — `payload.entity_id`, the session the change is about;
   it is the `subject` of the dedupe window. The event reports the session's
   **current** control state, so a consumer reconciles, never replays.
3. **Change/revision token** — none in the payload. Each event is one committed
   transition of `{desired, reason, until}` and is never updated. The
   transition instant is folded into the `idempotency_key`
   (`<type>:<fleet session id>:<occurred_at>`) as provenance a consumer may
   dedupe on; the platform does not dedupe on it (*Idempotency is per (event,
   rule)*).
4. **Origination membership** — **platform-originated only** (*Which event
   types an ingress kind may originate* → *Platform-originated*). Harness-emit
   and every source ingress are refused.
5. **Enrichment posture** — **none**. The server already holds every field.

`owner` is the session's owner and `source` is `platform`. The platform emits
exactly one event per committed transition, in the same transaction as the
control write that caused it (*Fleet registry and session control* → *Session
control: desired state*); a write that leaves `{desired, reason, until}`
unchanged emits none.

**Every `fleet.session.control_changed` that carries `to` gets one direct
delivery to it**, with the addressed `fleet.session.message` direct-delivery
bullets above binding it unchanged: one rule-less delivery atomically with the
event and its rule fan-out, HANDLED with no matching rule, the `(owner, event)`
key with `rule_id: nil`, REFUSED by the delivery-time target-bind, never
SUPPRESSED, and FAILED/REFUSED reported through the same two stores. The two
ingress-time refusals of that list do not apply: the platform stamps `to`
itself, so nothing is refused at ingress. The platform stamps `to` only when
the session resolved to a project (its `session_started` report named one) AND
the session's machine has a live agent instance declaring that session inbox.
Otherwise the event carries no `to`, gets no direct delivery, and fans out
through owner rules alone. The wake is then missing, so the control write's
answer and the fleet page MUST name why the session cannot be woken (no project
reported, or no declared session inbox), never show a normal pause.

The line is a **wake, never an authority**. A session that receives it re-reads
its control state (*Fleet registry and session control* → *Reading control
state and the control cache*) and acts on that answer, never on the line's
`desired`. An inbox line is Path-2 untrusted (`ai/contracts/athena-inbox.md` →
*Untrusted input*), and a line alone MUST NOT change what a session does.

**Ingress rule (AM-1): an unbound parent database is dead-lettered, never
enriched or emitted.** One Notion callback carries N per-database bindings
`{database_id, family}`. A verified webhook page **whose parent database has no
binding on the callback's subscription** is **DEAD-LETTERED with reason
`:unbound_database`** — it is **not** enriched and **not** emitted as an event.
This is the failed-lookup discipline applied at ingress (`~/dev/custom/ai/CLAUDE.md`
→ *A failed lookup must never look like an empty one*): an unrecognised parent is
a named dead-letter, never a silently mis-mapped `notion.ticket.*`.

### Idempotency is per (event, rule)

Delivery is **at-least-once**: the platform delivers every matched `(event, rule)`
at least once, carrying **current enriched state**, and **never silently drops** a
matched delivery. The platform holds **no** durable idempotency-key store and
performs **no** content dedupe; it retains only transient in-flight retry state
(deliver → await ack → retry until acked or terminally FAILED).

Because of fan-out (see *Fan-out: every match fires*), one event fires every
matching rule independently, so at-least-once delivery and its retry are tracked
per `(event, rule)`, never only at the event grain. The `idempotency_key` in the
envelope is the **event-level** identity; the platform combines it with the
matched `rule_id` as the **transient** in-flight retry handle for a delivery
attempt. This handle is **ack-based in-flight tracking, not a durable content
key** — a redelivery of the same source change reaches the consumer as another
at-least-once delivery, and it is the **consumer** (below), not the platform, that
makes a duplicate harmless.

**Later (2026-09-23):** the retry handle above was, until D40 (HG-16/DND-311),
always `idempotency_key` + a **matched** `rule_id` — every delivery had a rule.
Superseded: an addressed `fleet.session.message`'s direct delivery has no
rule, so its transient in-flight retry handle uses that delivery's own key
(*Declared families beyond the first pass* → `fleet.session.message`, stated
once there). `idempotency_key` is already event-level, so it adds nothing
beyond that row's key for this case. Every other clause in this section —
at-least-once, ack-based tracking, consumer idempotency — binds a direct
delivery unchanged.

**Consumers MUST be idempotent** — a duplicate or redelivered event MUST NOT cause
an adverse effect. A consumer satisfies this by acting on the **carried current
state** and reconciling against the source of truth (e.g. a membership consumer
re-queries Notion; see *The lane channel is a change stream, not the authoritative
set*), or, for a notify consumer, by deduping at its delivery adapter (the
Athena-inbox `dedupe_key`). A consumer that can provide **neither** — a stateless
fire-and-forget digest — is **not first-pass-eligible** and is deferred until an
idempotent (platform- or adapter-held) delivery view is built for it. This is the
consumer half of a **bilateral** obligation whose producer half is stated above;
the matching consumer-side clause lives in `ai/contracts/athena-inbox.md`.

The event-level identity basis is defined for **every** enumerated type:

- **Source-emitted** — the source's own event identity: Slack's `payload.event_id`;
  a Notion entity's `payload.entity_id` (`notion:<uuid>`), carrying
  `payload.revision` as **optional provenance** (the source-supplied revision
  indicator declared in *Payload fields and their types per event type*) when the
  source exposes it. (A reconciliation backstop hit reuses the same identity so an
  idempotent consumer absorbs it against the primary path — see *Poller (fallback
  only)*.)

  `payload.entity_id` is **stable across changes** (it is identity). Correctness
  does not depend on distinguishing two distinct changes to one entity at the
  event-level key: because every forwarded event carries **current enriched
  state** and the consumer is idempotent, a consumer converges to the correct
  current state whether it sees one delivery or several. `payload.revision`, when
  present, is a provenance / ordering hint only — no longer a dedupe key — so a
  source whose revision indicator is coarser than its change rate (Notion's
  minute-granular `last_edited_time`) is not a hazard: two same-minute edits are
  each delivered at-least-once carrying current state, and the idempotent consumer
  reconciles to their final state. A **missing** `revision` is simply an absent
  optional provenance field, **not** an emit-blocking error.

  A **new type family** (a `fleet.*` family, a future delta-supplying source) still
  declares its **identity field** (its `entity_id` analogue — the `subject` of the
  dedupe window, see *Enabled flag and dedupe window*), and MAY declare a
  change/revision token as optional provenance, as part of registering the family
  (see *Extending the taxonomy — a new type family declares its model*). A family
  whose identity is undeclared MUST NOT be originated or routed, and MUST NOT fall
  back to a `rule_id`-alone dedupe window — the silent cross-subject miss named in
  *Enabled flag and dedupe window*.

  A future consumer that genuinely needs per-edit fidelity (rather than converging
  on current state) gets a finer per-change token or adapter-side sequencing built
  **then** — that would require platform state, so it is the roadmap follow-up
  **DND-257** (collision-proof per-change revision); nothing here forecloses it.
  Because a membership lane's authoritative set is the **consumer's own re-query**
  (see *The lane channel is a change stream, not the authoritative set*) and every
  forwarded event carries **current** enriched state, a duplicate or same-window
  redelivery does not corrupt a lane's set — the state-based consumer acts on the
  final current state, which is exactly what consumer idempotency guarantees. The
  consumer-side lane discipline that matches this — fast-path best-effort,
  source re-query authoritative, no per-redelivery instrument — is in
  `ai/contracts/athena-inbox.md` → *A lane `log` channel is a change stream of
  state-change events*.

---

## Ingress — three kinds, one event

There are exactly three ingress kinds, all normalizing to one event:
**inbound-webhook (PREFERRED)**, **poller (FALLBACK)**, and **harness-emit**.
The platform's own producer of a platform-originated family is not an ingress
and sits outside these three; *Which event types an ingress kind may
originate* → *Platform-originated* states what it may originate.
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

**A reconciliation backstop separates per-hit DELIVERY from its RUN audit**, and
the two MUST NOT be conflated:

- **Delivery is at-least-once (see *Idempotency is per (event, rule)*).** A
  backstop hit on an entity a verified webhook already delivered is delivered
  **again** as an ordinary at-least-once delivery carrying **current enriched
  state**; the **idempotent consumer** absorbs it with no adverse effect. The
  platform performs no per-hit suppression.
- **The reconciliation RUN is recorded and reported on its own**, never folded
  into individual deliveries. Each run emits its own audit signal — "checked
  the in-scope set, found it consistent" or "found N gaps the webhook path
  missed" — and that signal MUST survive **even when every individual hit is a
  redelivery the consumer absorbs**. What happens to a hit's *delivery* MUST NOT
  erase the *run's* evidence that it checked and found nothing missing. (This is
  what "not conflated in reporting" means.)

This split is what makes "nothing is queued" **provably** true rather than merely
unobserved (failed-lookup discipline): the backstop's value is the run-level "I
checked" signal, which folding it into per-hit delivery would otherwise obscure.

**The backstop re-emits missed CHANGE EVENTS; it computes no membership.** It
recovers **adds** — entities that changed while the webhook was down, or that
existed before the subscription — by emitting the same source-emitted change
events the webhook would have, each delivered at-least-once; a duplicate of a hit
the webhook already delivered is absorbed by the idempotent consumer (above). It
holds no set and diffs no membership: a
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
  `slack.<x>` / `notion.<x>`. The **registered Slack members** include
  `slack.message.received` and **`slack.interaction.received`** (the verified
  block-action click of *Enumerated first-pass event types*); the registered
  Notion members include the `notion.ticket.*` / `notion.comment.*` types and the
  **`notion.agent_message.{created,updated,deleted}`** family (*Declared families
  beyond the first pass*), the latter originated by the Notion inbound-webhook
  ingress and the reconciliation poller. **Harness-emit MUST NOT be
  able to synthesize a source-emitted webhook type** — a machine-token holder
  cannot mint a `notion.ticket.deleted`, a `slack.message.received`, a
  `slack.interaction.received`, or a `notion.agent_message.*` that no verified
  webhook produced; such an event MUST be rejected with a `Fix:`.
- **Harness-emit** may originate only the **finite set of `fleet.*` `type` values
  registered to its machine token** at ingress registration — never a
  source-emitted type, and never an unenumerated `fleet.<arbitrary>` value. The
  first registered `fleet.*` member is **`fleet.session.message`** (*Declared
  families beyond the first pass*); a session message is harness-emit-only, and a
  source ingress that tried to originate it would be rejected. The
  `fleet.*` namespace bounds what MAY be registered; origination is bounded to the
  **registered members** of it, not the open prefix (see the finite-set rule
  above). A platform-originated type (next bullet) is never a member, whatever
  a token's registration says. A well-formed but unregistered `fleet.*` value
  is rejected at ingress by one of two refusals, and each names only the remedy
  that can succeed for it:
  - **Not in harness-emit's family-level origination set** (an unmodeled
    `fleet.*` value). Registration cannot allow it: registering a non-member
    is itself refused. `Fix: emit one of the enumerated harness-emit types (<permitted types, comma-separated>); a genuinely new fleet.* family must first declare its payload schema, identity field, revision token, origination membership, and enrichment posture (see 'Extending the taxonomy — a new type family declares its model') before it can be originated.`
  - **A family-level member not registered to this machine token** (deny by
    default). `Fix: register "<type>" for this machine's origination set (owner-editable, no code change), then retry.`

  **Later (2026-09-24):** this bullet quoted ONE refusal for both cases:
  "harness-emit is not permitted to originate type '<type>' — it may originate
  only the fleet.* type values registered to this machine token. Register the
  type into this token's origination set …". No code emitted that text, and
  its first remedy ("register it") cannot succeed for an unmodeled type. The shipped code splits the case in two, as above, and that
  split is the design. The unmodeled-type clause gained the model list from
  the old quote (DND-411). Every quoted `Fix:` in this section is pinned
  verbatim: `ai/contracts/fixtures/athena-events-quoted-fix.txt` (checked
  by `ai/contracts/test/self-test.sh`) and a gen_saas test named in that
  fixture's header. Change all of them together.

- **Platform-originated.** The platform itself originates a `fleet.*` family
  that reports the platform's own view of the fleet, which no machine can be
  trusted to report about itself or another machine. There are two such
  families (*Declared families beyond the first pass*), each with `source`
  `platform`: **`fleet.machine.{unreachable,reachable}`**, emitted by the
  server's reachability sweeper, and **`fleet.session.control_changed`**,
  emitted by the server when a session's control state changes (*Fleet
  registry and session control* → *Session control: desired state*). Neither
  producer is a fourth ingress kind: each runs inside the server, takes no
  machine request, and holds no token. The reachability sweeper runs on a
  timer. The control producer runs only inside the owner's authorized control
  write and the metering sweeper, which applies the owner's own policy. So no
  machine can drive either. A platform-originated type is **excluded from
  harness-emit's family-level origination set**, so a machine token can never
  originate one, even for its own machine: a forged `fleet.machine.unreachable`
  would page the owner about a healthy machine, and a forged `reachable` would
  mask a real outage; a forged `fleet.session.control_changed` would wake a
  session into resuming, or draining, work the owner never paused or resumed.
  Harness-emit refuses it at ingress before any
  per-token registration is consulted, with a remedy per family, never the
  unregistered-type one above (registration cannot allow it). For
  `fleet.machine.*`: `Fix: stop
  emitting <type> — it is platform-originated (only the server's reachability
  sweeper emits it) and no machine token may originate it, whatever its
  registration says; to act on reachability, write a rule on the platform's
  own event.` For `fleet.session.control_changed`: `Fix: stop emitting
  fleet.session.control_changed — it is platform-originated (only the server
  emits it, when a session's control state changes) and no machine token may
  originate it, whatever its registration says; to pause or resume a session,
  use the owner's control on the fleet page.` The second is an obligation on
  DND-441, which adds the type to the platform-originated set; until it lands,
  harness-emit refuses the type as an unmodeled `fleet.*` value (the first
  refusal above), so no machine token can originate it at any point. A source
  ingress refuses either as a non-member of its set.
  This is an exception for a declared family, not a namespace licence: a new
  platform-originated family declares its model like any other and is named
  here.

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
the field the per-`(event, rule)` at-least-once delivery retry handle combines with the event-level key (see
*Idempotency is per (event, rule)*), and the field the failed-delivery and refused-delivery
stores key on (see *Terminal delivery failure — the failed-delivery store* and *Delivery refusal
— the refused-delivery store*). Those keys are only as stable as `rule_id`, so its stability is a
**correctness MUST, not a convenience**:

- **An edit preserves `rule_id`.** Editing any other field of a rule — predicate, adapter +
  target, template + format, `enabled`, dedupe window, or `event_type(s)` — MUST retain the
  **same** `rule_id`. Minting a new id on edit would re-key every prior `(event, rule)`
  at-least-once retry handle, so in-flight deliveries would lose their retry identity across the
  edit; it would also orphan the rule's
  failed-delivery and refused-delivery exemplars, hiding an ongoing miss behind a fresh key.
- **Only delete + recreate mints a new `rule_id`.** A deleted rule's id is never reused; a
  recreated rule is a new rule with a new id and a fresh retry/store history. This is the
  one sanctioned way a rule's id changes, and it is explicit.
- **`rule_id` is platform-assigned, never caller-supplied** — like `owner` (see *Rule ownership
  is stamped from the authenticated author*), it is not read from the request body. A create
  request that supplies a `rule_id`, or an edit that attempts to change one, is refused with a
  `Fix:`. This keeps the identity the retry and store keys depend on under the platform's
  control, not the caller's.

The refusal for a caller-supplied or edit-mutated `rule_id` carries:

```
Fix: rule_id is platform-assigned and stable for the life of the rule — it is not accepted from the request body and an edit MUST NOT change it. Remove the rule_id from the request (it is minted at create); to obtain a new id, delete the rule and create a new one.
```

This section is about `rule_id` as a **rule's** own identity. A **direct**
(addressed, rule-less) delivery's `rule_id` is `nil`, not a rule's id — see
*Declared families beyond the first pass* → `fleet.session.message` for that
one delivery-row shape's key. Everything above still holds for every rule
delivery unchanged.

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
  from the correctness-guaranteeing **consumer idempotency** (see *Idempotency is
  per (event, rule)*). Consumer idempotency makes a **redelivered same delivery**
  harmless — a correctness guarantee, always in force. The dedupe window
  is an owner **preference** that collapses **distinct** deliveries **of the same rule about the same
  subject** within a time window into one ("don't DM me about **this** more than once an hour" —
  *this* being the subject the deliveries concern, not every subject the rule covers). Its key
  grain is stated explicitly, like every other collapsing mechanism: **`(rule_id, subject)`**,
  where **`subject` is the change-invariant identity component of the event-level idempotency
  basis** (see *Idempotency is per (event, rule)*) — **`payload.entity_id`** for the Notion entity
  types (the handle stable across a given entity's changes) and **`payload.event_id`** for
  `slack.message.received` (a transient event carrying no persistent entity, so each message is its
  own subject). The window's grain is deliberately `(rule_id, subject)` — collapsing several edits
  of the **same** entity within the window is exactly its purpose — never `(rule_id, subject, revision)`
  (`revision` is optional provenance, not part of any dedupe grain)
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
  the dedupe window never widens or narrows consumer idempotency, and a window of
  `0` leaves consumer idempotency untouched. Keying by `(rule_id, subject)` reads the `subject` from the
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
independent deliveries, each with its own per-`(event, rule)` at-least-once
delivery and retry.

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
  arrives carrying one still dead-letters. `unknown event type "<type>" in this rule's event_type(s) — it is not a member of the registered type set. Fix: correct the spelling; or, for a genuinely new type, declare its family's model before authoring rules against it. For a per-property ticket route, declare notion.ticket.updated and filter on {"field":"payload.changed_properties","op":"contains","value":"<property-id>"}.`

  **Later (2026-09-24):** this quote began with `Fix:`, single-quoted the
  type, and ended its model clause with a pointer to *Extending the taxonomy —
  a new type family declares its model*. The shipped text puts the diagnosis
  first, double-quotes the type, and has no pointer. The quote now matches the
  code (DND-411). The code wins here, unlike the origination refusal, because
  DND-412 is converting this module's errors with the text held byte-identical;
  adding the pointer to the code is a follow-up once that lands.
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
line MUST carry every field `ai/contracts/athena-inbox.md` → *Line format*
requires of a platform `log` line; that section is normative for them and they
are not restated here. The remaining fields are this producer's own schema.
This is a conformant append-only `log` channel: the *lines* are appended.

**Later (2026-09-23):** this paragraph named the universal fields itself (`v`
plus the framing rules). It now defers to *Line format* by name, because
DND-372 added `delivery_id` to every platform line there and a restated list
here would have gone stale.

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
  **Notion** (per-account, workspace/integration-scoped token — *Secret custody*,
  the D13 general integration token), and **Discord** when it delivers via a bot
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
(This refusal is a Level-2 REFUSED disposition — recorded and reported, never a silent drop — exactly as the target-bind and generic-webhook egress refusals in *Delivery refusal — the refused-delivery store*. It **declares `owner-verified-recipient` as its refusal-cause class** in that store's open-but-declared cause set, so a refused email/SMS delivery records `owner-verified-recipient` as its refusal-cause at the grain *Delivery refusal — the refused-delivery store* states — never an undefined key that would read as absence.)

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

### A slot's field-path binds at save time, exactly as a predicate's does

A template slot interpolates a value addressed by a **field-path** drawn from the
**same closed, enumerated field set** a predicate leaf uses — envelope fields and
the declaring type's closed `payload.*` schema (see *The predicate grammar* → *The
enumerated field set*). A slot is the **other consumer of the same closed payload
schema**, so it binds by the **same rule and the same mechanism** as a predicate
field-path; no second mechanism is introduced.

- **A slot field-path outside the union of the rule's declared `event_type(s)`'
  payload schemas is a save-time HARD ERROR**, checked at rule save (create **and**
  edit — the same seam predicate field-paths are bound at), never a runtime empty
  render. A misspelled `{payload.asignee}` or `{payload.lables}` is rejected
  exactly as the identical predicate leaf is (see *Evaluation contract* → "An
  UNKNOWN field-path is a HARD ERROR at rule-SAVE time"): a wrongly-computed key
  otherwise renders empty forever, silently dropping content the author believed
  they were emitting — the failed-lookup class this document legislates against
  (`~/dev/custom/ai/CLAUDE.md` → *A failed lookup must never look like an empty
  one*). It binds by the same field lookup as a predicate leaf and is refused
  with its own message, naming the offending slot and the declared types' valid
  fields:
  `template slot '{<path>}' names a field-path that is not in the union of this rule's declared event_type(s)' payload schemas — the same save-time binding a predicate field-path gets. Fix: correct the spelling (valid fields: <valid fields, comma-separated>); or add the event_type that carries it. A misspelled slot otherwise renders empty forever — an invisible content drop.`

  **Later (2026-09-24):** this bullet said the refusal names "the nearest
  valid field" and quoted an example with `Fix:` first, "(nearest valid field:
  payload.assignee)", and a longer add-the-event_type clause. The shipped text
  lists every valid field of the declared types and puts the diagnosis first.
  The quote now matches the code (DND-411).
- **A delete-only (identity-only) type has no display field to slot.** A rule
  declared **solely** on `notion.ticket.deleted` (or `notion.comment.deleted`)
  with a slot on `payload.title` / `status` / `labels` / `assignee` /
  `ticket_number` (or `comment_text`) is an **unknown-path save-time HARD ERROR**,
  exactly as the identical *predicate* leaf on that type is (see
  *`notion.ticket.deleted` carries a NARROWER schema…* and
  *`notion.comment.deleted` carries a NARROWER schema…*): the field is not in that
  type's schema at all, so the slot has no supplier and is rejected where it is
  authored, not left to render empty at dispatch.

### An absent-by-design slot renders an observable sentinel, never a silent gap

A slot whose field-path **is** valid against the union but is **absent on this
delivery** is the sanctioned **union-binding absent-by-design** case — the
render-side analog of the predicate `absent` disposition (see *Evaluation
contract* → "`absent` is reserved for a KNOWN field missing from a given
payload"). It arises two ways, both legitimate, and **neither is catchable at save
time** because the path is schema-valid:

- a rule spanning an enriched type **and** a delete type (e.g.
  `notion.ticket.updated` + `notion.ticket.deleted`) renders a slot on
  `title` / `status` / `labels` / `assignee` on a **delete** delivery, where the
  delete schema does not carry it; or
- a **known** field simply missing from **this** event's payload (a cleared
  `assignee`) — exactly the predicate runtime `absent` case.

For such a slot the renderer MUST emit a **fixed platform absent-sentinel that
NAMES the field-path** — `[absent: <field-path>]`, e.g. `[absent: payload.title]`
— and **MUST NOT** emit an empty string. This is required by the failed-lookup
discipline: a **misspelled** slot is already impossible at render time (rejected
at save, above), so the only remaining way an absent render could be
**indistinguishable from a defect** is a silent empty fragment. The sentinel
removes that indistinguishability by making the miss **observable in the delivered
content itself**, naming *which* field was absent (`~/dev/custom/ai/CLAUDE.md` →
*A failed lookup must never look like an empty one*: a miss "has to be able to say
which key found zero").

The sentinel is consistent with the Escaper contract and adds **no** new platform
state or mechanism:

- **It carries no injection surface**, so it does not weaken the "trusted set is
  empty" rule. It is **platform-minted and drawn from a closed set** — a fixed
  sentinel string plus a field-path taken from the **closed enumerated field
  set**, with **no** source-supplied or enrichment-derived substring — so it is
  inert by construction. This is *not* a trusted/raw slot and does not reopen the
  empty trusted set: **every interpolated source value still passes through the
  adapter's Escaper** unchanged; only a *present* value is ever interpolated, and
  the sentinel replaces an *absent* one.
- **Its observability is the rendered sentinel in the delivered message** — a
  human or a later check reading the delivery sees the named-path marker rather
  than a gap. **No** new counter, store, or delivery disposition is introduced;
  the existing dispositions (FILTERED / SUPPRESSED / REFUSED / FAILED / DELIVERED)
  are untouched.
- **It cannot arise from an enrichment miss.** The ingress **refuses to emit an
  un-enriched event** (see *Sender verification and payload completeness*), so a
  slot is never absent merely because enrichment failed — only because the field
  is genuinely not on this delivery's type/payload. The sentinel therefore always
  denotes a real, schema-legitimate absence, never a swallowed fetch failure.

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
  inbound-webhook HMAC key); and one **general, per-account Notion integration
  token** (`:notion_integration_token`). Every first-pass inbound-webhook ingress
  therefore has its inbound-auth
  key named here — Slack's signing secret (per **app**) and Notion's
  `verification_token` (per **subscription**) — under the same KMS
  envelope-encryption custody, least-privilege at-use-only decrypt, and
  never-logged/never-on-`argv`/never-in-inbox-root posture as every other secret.
  The reconciliation poller carries no HMAC key: it reads the source under a
  per-account, source-scoped read token (for Notion first-pass reconciliation the
  general integration token above serves; a source needing a distinct poller
  token adds it here under the same custody). Any future adapter credential
  (SMTP, SMS, Discord bot) joins this set under the same story.

  **Later (2026-09-22):** this named the Notion read token a **"read-only,
  DB-scoped Notion enrichment token"** — a token whose *scope* was the
  least-privilege mitigation. Superseded (epic D13/HG-13): the server now holds
  **one general per-account Notion integration token** (`:notion_integration_token`,
  `scope_ref` = the workspace/integration id, never empty) that **enrichment, MCP
  reads, and MCP writes all share**. Least-privilege therefore no longer rests on
  token scope; the mitigation moves to **server-side per-caller authorization +
  audit** (every read/write is authz-checked and audited per caller — design §10
  D15). The custody, at-use-only decrypt, and never-logged posture are unchanged.

### Sender verification and payload completeness

- An inbound webhook's signature MUST be verified over the **raw bytes as
  received**, constant-time, hard-rejecting the unverified with a `Fix:` (per
  *Inbound webhook*).
- Where a source's webhook is **metadata-only** (it signals *that* something
  changed and carries entity IDs, but not the changed values — Notion's API
  webhook is so by design), building a useful event **requires an enrichment API
  fetch** on the verified event. Enrichment is a **read**, performed **on-demand
  only** (never on a timer), using the per-account Notion integration token
  (*Secret custody* — one general token shared by enrichment and the MCP;
  least-privilege is enforced **server-side per-caller + audit**, not by token
  scope). Enrichment targets a
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
    Notion integration token → `401`/`403`; persistent `5xx`).** The ingress MUST record
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
    `Fix: enrichment fetch failed for a <type> event on entity <entity_id> (owner <owner>; cause: <class>, <status>). Emit is rejected: emitting un-enriched would read the known fields (status, labels, assignee, title, ticket_number) as absent, silently FILTER at rule evaluation, and — being Level-1 HANDLED — never dead-letter, an invisible miss. The ingress-side enrichment-retry budget is exhausted; check the Notion integration token (Secret custody) or the source, then the event re-enriches on source redelivery. See the ingress-failure store exemplar for the first-seen event.`
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
- Notion **writes** (e.g. outbound: post comment / update page) and reads share
  the **one** general per-account integration token (*Secret custody* — the D13
  supersession); there is **no** separate write-scoped token to keep apart, and
  no read token to "widen." The read/write **token boundary** the old model gave
  is deliberately removed (D13); its replacement is **not** a server-side
  read/write split but **per-caller authorization (owner-scoping — a caller
  reaches only its own owner's workspace) + per-write audit** (design §10 D15),
  which bounds cross-account reach and makes every write attributable.

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
  / `check-inbox-registry` tooling. For an inbox-adapter **platform** delivery this
  declaration also carries the `producer: "platform"` marker, ingested by the
  reader as of DND-260 — per `athena-inbox.md` → *The inbox as an event-platform
  delivery adapter*.

  **Later (2026-09-20):** this marker was **currently undeclarable** when written,
  its `"platform"` value refused by the inbox validator pending reader support.
  DND-260 landed that reader support, so the validator now admits it; the
  declaration above is live.

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
  and **Notion** (per-account, workspace/integration-scoped token — *Secret
  custody*) deliver only through the owner's own
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

### Machine↔owner API binding and the outbound return-address dual

The machine-token registration record above is not only what the target-bind
check reads. **Harness → gen_saas API calls authenticate with the SAME
machine-token registration record** — the one server-side per-account record from
which harness-emit resolves `owner` (*Harness-emit*) and the target-bind resolves
a machine's owning account (above). One machine, one token, one record: the API
caller identity, the harness-emit owner, and the target-bind owner are the same
`{owning account, machine id}` binding, resolved server-side, never from a
request body. No second credential is minted for the API.

**The outbound dual of owner-from-auth is a server-stamped return address.**
Owner-from-auth stamps an inbound event's `owner` from the authenticated ingress,
never the payload. Its **outbound** counterpart: when the harness posts through
the API (a Slack message with interactive elements), the server **stamps a return
address from the authenticated caller's registration record** — `{account,
machine, inbox}` — and it travels in the outbound message as a **tagged opaque
value** (an integrity-tagged, server-keyed blob carried as the interactive
element's `value`, or a modal's `private_metadata`). The harness does **not**
supply it: a **caller-supplied return address is refused with a `Fix:`**, never
silently honoured or ignored — an ignored field is one a later reader starts
trusting: `Fix: the return address is stamped server-side from the authenticated
machine token, not supplied by the caller — remove the caller-supplied return
address and re-post.` This is the egress dual of *Which event types an ingress
kind may originate*: origination stops a caller minting another's events; the
server-stamped return address stops a caller routing a reply into another
machine's inbox.

**A returned `value` / `private_metadata` is untrusted until it is verified on
BOTH counts.** When Slack sends the interactive callback back
(`slack.interaction.received`), the returned `value` (or `private_metadata`) is
**not trusted** until (1) its **integrity tag verifies** against the server key,
AND (2) the account it decodes to **equals the owner of the app the click arrived
on**. A blob whose tag fails, or whose account differs from the click's app
owner, is **rejected and recorded, never forwarded** as a return route — a
workspace member who can read a message's `value` could otherwise craft a click
routing into another machine's inbox. Both checks are required: the tag alone
proves the server minted it; the account-equality check proves it came back on
the app that owns that account. (Design §3 6D and §4 are the mechanism; this
section states the invariant it rests on.)

### Thread replies route to the thread's claimant

**Why.** The harness posts to Slack with its own bot token, so the server never
sees a thread's parent `ts`. Without a record, a reply routes by channel alone
(the app's route for `(team, channel)`), which sends a reply in one project's
thread to whichever project owns the channel route. A **thread claim** is that
record. It is the thread-reply analogue of the server-stamped return address
above: the harness names only its own inbox, and the server stamps the machine
from the authenticated token. Implementing tickets: DND-487 (claims and the MCP
tool), DND-490 (the router), DND-491 (the harness claims on post). Until the
router ships, every reply routes by the channel route, as before.

**The claim.** A claim maps `(slack_app, team_id, channel, thread_ts)` to one
AgentInstance. It is written by the `athena` MCP tool **`slack_thread_claim`**,
which takes five arguments: `bot_id` (selects the app), `team_id`, `channel`,
`thread_ts` (the parent `ts`), and `inbox_name`.

- **The machine is stamped, never supplied.** The caller's machine comes from
  its machine token (the dual above). The derived-identity arguments
  `machine_id`, `owner`, and `agent_instance_id` are **refused with a `Fix:`**,
  never silently honoured or ignored. So the tool's schema declares **eight**
  arguments: the five it takes, and these three, which it always refuses. They
  must be declared, because the MCP layer strips undeclared arguments before the
  tool sees them, and a stripped argument is one silently ignored.
- **The inbox must be a live `<project>-slack.jsonl` instance on the calling
  machine.** Any other `inbox_name` — a non-Slack inbox, or an instance on
  another machine — is refused with a `Fix:`. Only a Slack-producer inbox may be
  claimed, so a Slack line can never land in a platform channel, where the reader
  would score it unreadable.
- **Who may claim.** The owner of the app, holder of `:add_slack_route` on it,
  acting through one of their own machine tokens. The check runs before any
  write. An unknown app and an app the caller's owner may not route answer the
  same `not found`, with no detail: a miss must not disclose which apps exist.
- **First claim wins.** A claim of an unclaimed thread answers `claimed`. A
  repeat by the same instance answers `already_yours` and changes nothing. A
  claim of a thread another instance holds answers `already_claimed`, **never
  naming the holder**, and leaves the existing claim untouched.
- **A claim seeds thread participation** for the key, so a channel-thread reply
  to a bot-started thread is routed rather than classified as not addressed to
  the bot.
- **The harness claims only threads it starts**: a `post`, or a `dm` without
  `--thread_ts` (`athena:slack`). It never claims a thread it merely replies in.

**Routing.** For a **thread reply only** (`thread_ts` present and not equal to
`ts`), a live claim is the destination. Anything else follows the channel route,
unchanged. **Exactly one destination per event**: a claim replaces the route for
that reply, it never adds a second copy. So one line lands in one channel, and
the designated-consumer rule (`ai/contracts/athena-inbox.md` → *The designated
consumer*) holds unchanged.

**A stale claim falls back and says so.** A claim whose instance or machine is no
longer live does not drop the reply: dropping it would be the silent-dark class
(`~/dev/custom/ai/CLAUDE.md` → *A failed lookup must never look like an empty
one*). The reply follows the channel route, and the server records the outcome
**`thread_claim_stale`** naming the claim's key. It is a delivery, not a drop.
The record is the Slack receiver's per-event outcome log (gen_saas
`Athena.SlackEvents.EventOutcome`), which already records every path through the
receiver, `unrouted` included. It is not the platform router's Level-1/Level-2
outcome sets (*Event disposition and dead-letter*): the Slack receiver is a
separate producer. If the channel route also misses, the event is `unrouted`: no
event row is stored (`ai/contracts/athena-inbox.md` → *The diagnostic:
`inbox-doctor`*, "dropped without a row"), and its outcome record, the only
durable trace of an unrouted event, names the stale claim's key too.

**The line says how it was routed.** Every Slack line the router writes carries
`route`: `thread_claim` when a live claim chose the channel, `channel_route`
otherwise (including a stale-claim fallback). The field is defined in
`ai/contracts/athena-inbox.md` → *Line format*.

**What it does not guarantee.** A claim is owner-scoped isolation, not a security
boundary between the owner's own projects. Any of the owner's machines can claim
any thread of the owner's app, including one another project started; first-wins
and claim-only-what-you-started limit that, nothing enforces it. The server also
cannot verify the bot authored `thread_ts`. See `ai/contracts/athena-inbox.md` →
*What tenancy does and does not guarantee*.

### Which machine am I — the own-machine id

The machine↔owner binding above is resolved server-side, so the harness does
not hold its own machine id; it asks. **`machine_reachable {}` (the `athena`
MCP tool, HG-20, called with no selector) is the sanctioned source of the
caller's own machine id.** Its answer carries `machine_id`, derived from the
authenticated machine token (gen_saas #307, DND-375), beside the reachability
verdict:

```json
{"machine_id": "<uuid>", "reachable": true | false | "unknown", "basis": "<str>",
 "last_ack_at": "<iso>|null", "last_joined_at": "<iso>|null",
 "pending_deliveries": <int>, "unreachable_since": "<iso>|null"}
```

- With a selector naming one of the caller's own machines, `machine_id` echoes
  that machine. A machine of another owner and a missing one both answer the
  same `not found`, with no id in it.
- `reachable` is three-valued, and `"unknown"` is **not** a failure. It means
  no recent signal, and it is what an idle, healthy machine reads once the
  server's silence budget (default 120 s) has passed since its last ack or
  join. A consumer that needs "did the question get
  answered" MUST tell an absent, malformed, or errored answer apart from
  `"unknown"`, and MUST NOT read one as the other.
- **`list_my_machines`** (HG-2) returns every machine the caller's owner owns,
  each `{id, name, live?, last_connected_at, instances, self}`. Exactly one
  entry has `self: true`: the caller's own machine.
- A server that predates #307 answers without the `machine_id` key (and
  without `self`). A consumer MUST treat that as "own id not known" and say
  so. A `machine_id` key that is present but not an id-shaped string
  (including `null`) is a MALFORMED answer, not an absent one. It MUST NOT
  guess, for example from a machine name, a hostname, or the only machine
  hosting an inbox. `athena:inbox`'s `send-mail` is the reference consumer:
  it compares `--to`'s machine with this id to decide whether a recipient is
  on this machine. `inbox-doctor`'s `send-paths` also consumes it, and reports
  absent, malformed, unavailable and not-asked as four different facts.

---

## Fleet registry and session control

The server keeps a registry of the owner's fleet: each Claude Code session on
each machine, the admirals in it, and each admiral's missions. The owner can
pause (drain) and resume a session. This section is the contract for that
registry and that control. Its implementing tickets are DND-431 (server
registry and `fleet_report`), DND-433 (harness reporters), DND-434 (fleet page),
DND-441 (server session control) and DND-443 (harness drain enforcement); each
cites the subsection it builds by name. Of the harness homes named below, only
DND-433's reporters exist: `ai/bin/fleet-report` and `ai/hooks/fleet-report.sh`.
Every sentence about the others is an obligation on its implementer, not a
description of shipped behaviour.

**Later (2026-09-24):** this paragraph said "None of the harness homes named
below exists yet." DND-433 shipped the reporters, so that is no longer true for
them. It stays true for DND-443's `ai/bin/fleet-control` and
`ai/hooks/fleet-drain-guard.sh`.

**Later (2026-09-24):** DND-443: the paragraph above said it stayed true for
`ai/bin/fleet-control` and `ai/hooks/fleet-drain-guard.sh`. DND-443 shipped
both, with the admiral drain protocol (`athena:fleet-drain`) and the
`CONTROL:` lines of `ai/bin/admiral-report-watch`. The server side of control
(DND-441) is still an obligation on its implementer.

### Fleet reports are state upserts, not events

A fleet report is a **state upsert**. It goes to `POST /api/v1/fleet/reports`
or to the equivalent `athena` MCP tool `fleet_report`, both authenticated by the
machine token (*Machine↔owner API binding and the outbound return-address
dual*). It is **not** an event: it does not pass harness-emit origination, it
matches no rule, and it is never delivered anywhere. The one event this
section defines, `fleet.session.control_changed`, is platform-originated
(*Declared families beyond the first pass*).

### Fleet report kinds and their closed schema

Every report body carries `kind` and `claude_session_id` (a non-empty string:
the `session_id` of the top-level Claude Code session, which hook stdin carries
at every agent depth). The kinds and the other fields each may carry:

| `kind` | Fields beyond `kind` and `claude_session_id` | Effect |
| --- | --- | --- |
| `session_started` | `project` (string or `null`), `repo_key` (string, absolute path) | Creates or refreshes the session and binds it to the reporting machine. |
| `session_seen` | `agent_id` (string, optional), `agent_type` (string, optional) | Refreshes the session's last-seen time. |
| `session_ended` | `end_reason` (string, optional: the SessionEnd hook's `reason`) | Marks the session ended, basis `reported`. |
| `admiral_started` | `run_id` (string), `agent_id` (string), `scope_label` (string, optional) | Creates the admiral run in state `running`. |
| `admiral_scope` | `run_id` (string), `missions` (collection of mission pointers, possibly empty) | Replaces the run's whole mission list. |
| `admiral_seen` | `agent_id` (string), `agent_type` (string, optional) | Refreshes the last-seen time of the run with that `agent_id` in this session. |
| `admiral_state` | `run_id` (string), `state` (`draining` \| `drained` \| `finished`) | Sets the run's reported state. |

- **The schema is closed, and deny is the default.** A `kind` not in this table
  is refused with a `Fix:` naming the seven kinds. So is a field the row does
  not list, a missing required field, and a value of the wrong type. Nothing
  unlisted is stored or ignored.
- **The body carries no time.** `started_at`, `last_seen_at` and `ended_at` are
  the server's receive time.
- **`project`** is the inbox-registry project name, resolved from the
  session's git common dir (`ai/contracts/athena-inbox.md` → *Repo identity:
  the git common dir*). `null` means "no registry entry matched this repo". It
  is stated, never omitted, so it stays distinct from "not reported". A
  relative `repo_key` is refused, not stored.
- **`repo_key`** is the realpath of the session's git common dir. A session
  whose cwd git says is in no work tree reports the cwd's own realpath, with
  `project: null`. When git cannot say (it is missing, refuses the repo for
  dubious ownership, or finds a corrupt `.git`), the harness sends no
  `session_started` and logs the failure. It never reports such a repo as a
  plain directory.
- **`run_id`** identifies an admiral run within its session: the name of the
  run's coordination directory. An `admiral_scope` or `admiral_state` naming a
  `run_id` this session never started is refused with a `Fix:` telling the
  admiral to report `admiral_started` first.
- **`agent_id`** is the admiral's own agentId, the id SendMessage uses, which
  its dispatch briefs already carry. PreToolUse and PostToolUse hook stdin
  carries the same value as `agent_id` inside that admiral (measured, DND-428),
  so `admiral_seen` joins to the run with no prose compliance.
- **Who sends what** (DND-433): the SessionStart hook sends `session_started`
  and the SessionEnd hook sends `session_ended`. The PostToolUse hook path sends
  `admiral_seen` when stdin's `agent_type` is `athena-admiral`, and
  `session_seen` otherwise, at most once per 60 s per (session, `agent_id`), in
  the background under a timeout. The admiral itself calls `ai/bin/fleet-report`
  for `admiral_started`, for `admiral_scope` on every mission status change in
  its `state.md`, and for `admiral_state`.

### Fleet identity: owner and machine are stamped from the token

- **Owner and machine are stamped from the machine token, never read from the
  body.** A body naming `owner`, `owner_id`, `machine` or `machine_id` is
  refused with HTTP 422 and a `Fix:` saying the field is stamped server-side
  from the token and must be removed. Nothing is written.
- **A session belongs to one machine.** `claude_session_id` is unique: its
  first report binds it to the reporting machine and that machine's owner, for
  good. Any report or `session_control` read naming it from another machine,
  of the same owner or not, answers `not_found` (HTTP 404), writes nothing,
  and never says where the session is bound.
- **An admiral run and its missions inherit the session's machine and owner.**
  Every read and write of them is scoped through that session.
- **No token answers 401.** The machine pipeline rejects the request before any
  fleet code runs.
- **Pages are owner-scoped.** The fleet page lists only rows whose owner is the
  viewer. A foreign or unknown session id answers `not_found`, never a
  forbidden that discloses existence.

### Mission pointers are metadata only

An `admiral_scope` mission entry is a **pointer** to a tracker item, with
exactly these fields:

- `tracker` (`notion-personal` | `notion-work`)
- `ticket_ref` (string, e.g. `DND-429`)
- `url` (string)
- `title` (string)
- `status` (string, the tracker's status)
- `captain_state` (`queued` | `running` | `parked` | `done` | `blocked` |
  `stuck`)

The first five are the work-item metadata the storage boundary allows. The
sixth is the admiral's own state, not work-item content. Any other field
(a body, a comment, a summary, a label, an assignee) is refused with a `Fix:`
naming the field. The boundary is enforced by the closed schema, not by
policy. The entries replace the run's list whole; `(tracker, ticket_ref)` is
unique within a run.

### Fleet liveness

The server derives liveness from report times. It never trusts a harness claim
of liveness, because SessionEnd does not fire when a session is SIGKILLed
(measured, DND-428).

- A **session** is:
  - `live` when seen within the live window (default 5 min);
  - `idle` when silent past the live window, with no admiral run in `running`
    or `draining`;
  - `quiet` when silent past the live window while one of its admiral runs is
    `running` or `draining`, but not past the lost window;
  - `lost` when silent past the lost window while one of its admiral runs is
    `running` or `draining`: a fleet stopped reporting, most likely killed;
  - `ended` when `session_ended` arrived (basis `reported`), or when silent
    past the stale window (default 24 h) with no end report (basis
    `inferred`). The basis is always shown.
- **"Seen" counts every report from the session**, from any agent in it. A
  captain's tool calls keep its admiral's session seen.
- **The lost window MUST exceed the longest interval in which a healthy fleet
  can make no tool call at all.** An admiral waiting on its captains makes no
  tool call until `ai/bin/admiral-report-watch` prints a line. Its staleness
  sweep (every 2700 s today) makes the admiral sweep its fleet, which is tool
  calls. So the default lost window is 60 min, and a change to either number
  moves the other. A shorter window would read a waiting fleet as `lost`.
- An **admiral run** reads its reported state (`running`, `draining`, `drained`,
  `finished`), except that a `running` or `draining` run reads `lost` when its
  session does. `admiral_seen` shows the admiral's own last activity. It never
  decides `lost` alone, because a waiting admiral is silent while its captains
  work.
- **`scope unreported`** is an admiral run that never sent `admiral_scope`. It
  MUST read differently from an empty scope (`no missions`), which is a
  reported fact. An `admiral_seen` whose `agent_id` matches no started run
  shows as an admiral with `run unreported`, never dropped.
- The session's reported state (`running`, `draining`, `drained`, `idle`) is
  derived from its admiral runs, never sent by the harness.

### Session control: desired state

- **Desired state is computed server-side by a pure function,**
  `Athena.Fleet.ControlPolicy.desired/3`, from the session's override, its
  effective domain and the owner's policy at time `now`, to `{desired, reason,
  until}`. `desired` is `run` or `drain`. Precedence: an unexpired override,
  then metering (added by the metering phase; skipped until then), then `run`.
- **`reason` is one of a closed set of classes.** The drain protocol keys on the
  class (*Enforcement layers* → *Layer 3: the drain protocol*):
  - `override:force_drain` and `override:force_run`: the owner's override;
  - `metering:<domain>`: the metering policy, for example `metering:personal`
    during work hours;
  - `default`: nothing overrides or meters, so `run`.
- **Only the owner changes control.** `Fleet.set_control/3` is authorized by the
  RBAC `control` permission on the session, checked before any write. A
  non-owner gets `not_found`, with no write and no event. The metering sweeper
  (metering phase) is the one other writer, and it acts only on the owner's own
  policy. No inbox line, Slack message or fleet report can change control
  state.
- **Each committed transition emits exactly one `fleet.session.control_changed`**,
  in the transaction that commits the write. That event's model and its direct
  delivery to the session's inbox are in *Declared families beyond the first
  pass*.
- **Drain gates fleet spawns only.** It never blocks the human's own turns in a
  top-level session, or any subagent that is not a fleet worker.

### Reading control state and the control cache

- **`session_control {claude_session_id}`** (an `athena` MCP tool,
  machine-token authenticated) answers `{claude_session_id, desired, reason,
  until, policy_snapshot}`. `policy_snapshot` holds every input `desired/3`
  used except `now`: the override and its expiry, the effective domain, the
  owner's timezone and work windows, and whether the policy is enabled. A
  harness can recompute `desired` from it. A session bound to another machine,
  or never reported, answers `not_found`.
- **The REST equivalent is `GET /api/v1/fleet/sessions/<claude_session_id>/control`**
  (DND-443 chose it, as DND-433 chose REST for reports: HTTP codes map cleanly
  onto outcomes). It sends `Authorization: Bearer <machine token>` and
  `Accept: application/json` and has no body. Its origin is the registered
  `athena` MCP URL's, exactly as for `POST /api/v1/fleet/reports`. It answers:
  - **200** with the same object as `session_control`, and nothing else:
    `claude_session_id` (the id in the path); `desired` (`run` | `drain`);
    `reason` (a reason class of *Session control: desired state*, agreeing with
    `desired`); `until` (an ISO 8601 UTC time ending in `Z`, or `null`); and
    `policy_snapshot`, exactly `{override, effective_domain, metering}`:
    - `override`: `null`, or `{desired: "run" | "drain", expires_at}`, where
      `expires_at` is an ISO 8601 UTC time or `null` (never expires);
    - `effective_domain`: `work` | `blend` | `personal`;
    - `metering`: `{enabled: false}`, or `{enabled: true, timezone, work_windows,
      metered_domains, holidays}` with `timezone` an IANA zone name,
      `work_windows` a non-empty list of `{days, start, end}` (`days` distinct
      ISO weekdays 1..7; `start` before `end`, both `HH:MM`), `metered_domains`
      a list of domains, and `holidays` a list of `YYYY-MM-DD` dates.

    The shape is closed at every level. A key it does not list is a malformed
    answer, because a snapshot carrying an input the harness does not know
    would be recomputed wrongly and silently.
  - **401** `{"error": "unauthorized", "fix": ...}` with no or a bad token;
    **422** `{"error", "fix"}` for an id that is not a valid session id;
    **404** `{"error": "not_found"}` for a session never reported, or bound to
    another machine (the two are indistinguishable by design).
- **Recomputing is `desired/3` run locally.** Given a snapshot and `now`: an
  override whose `expires_at` is `null` or later than `now` gives
  `{override.desired, "override:force_<desired>", expires_at}`. Otherwise, when
  `metering.enabled` is true and `effective_domain` is in `metered_domains`,
  and `now` in `timezone` falls on a work window's weekday, is not a holiday,
  and is at or after `start` and before `end`, it gives
  `{drain, "metering:<domain>", that window's end}`. Otherwise `{run, default,
  null}`. P1 has no metering, so its snapshot says `{enabled: false}`.
- **`ai/bin/fleet-control` is the one harness reader** (DND-443). The drain
  guard hook, the admiral checkpoint and the resume path all read through it.
  It asks the server first, under a bounded timeout. On an answer it writes the
  control cache, `$XDG_STATE_HOME/athena/fleet/<claude_session_id>.json`, as the
  answer plus `fetched_at`.
- **`fleet-control check` exits 0 for `run` and 3 for `drain`.** Every other
  exit is an error and is never read as `run`. Its stdout names the **basis**
  of the answer: `server`, `cached`, `recomputed:<cause>` or
  `local-rule:<cause>` (next subsection).

### Unknown control state

Control state is unknown when the server gives no usable answer. The owner's
fail-mode decision (OQ-1, 2026-09-24) applies:

- **With a usable cache, recompute.** `fleet-control` computes `desired` from
  the cached `policy_snapshot` at `now`, honouring the cached override's
  expiry. The basis is `recomputed:<cause>`.
- **With no usable cache, apply the local rule.** Work and blend sessions may
  spawn fleet workers. A personal-domain session may not, during work hours:
  America/Denver, 08:00 to 18:00, Monday to Friday, with no holiday source (the
  owner overrides on a holiday). The domain comes from the repo defaults
  (walt_ui work, custom blend, gen_saas personal). An unmapped project counts as
  personal. The basis is `local-rule:<cause>`. `fleet-control` evaluates the
  rule as a built-in snapshot (metering on for `personal` in that window)
  through the same recompute, so a local-rule drain reads reason
  `metering:personal`, until the window's end; the basis says it is local.
- **Unknown is never read as `run` silently.** Each basis other than `server`
  prints a warning on stderr naming its cause, and the hook surfaces it to the
  transcript.
- **Each cause is its own observable outcome** (`~/.claude/CLAUDE.md` → *A
  failed lookup must never look like an empty one*). No two share a token:
  - `server-unconfigured`: the server was never asked, because this machine
    has no machine token or no usable `athena` MCP URL;
  - `server-unreachable`: no answer within the timeout, or a transport error;
  - `server-refused`: the server refused the read (HTTP 401, 403 or 422);
  - `session-unregistered`: the server answered `not_found`;
  - `malformed-answer`: the server answered, but not in the shape above (this
    includes a 5xx, and a 404 with no JSON, which means no endpoint is
    deployed);
  - `expired-cache`: the cache is older than the stale window (24 h). Its
    snapshot is still used, and the warning names its age;
  - `no-cache`: no cache file exists;
  - `malformed-cache`: the cache file is not the shape above;
  - `invalid-cache-path`: `$XDG_STATE_HOME` is set but not absolute.
    `fleet-control` does not read or write any path then.

  The first five say why the server gave nothing; the last four say what the
  cache gave. Both appear in the basis, for example
  `recomputed:server-unreachable` or
  `local-rule:server-unreachable,malformed-cache`. A cache whose snapshot names
  a time zone this machine's tz database lacks is `malformed-cache`: an
  unknown zone would silently compute in UTC.

  **Later (2026-09-24):** DND-443: this list had seven tokens, and
  `invalid-cache-path` also covered a `claude_session_id` that is not a safe
  single path component. DND-443 added `server-unconfigured` and
  `server-refused`: a machine with no token, and a 401, were otherwise forced to
  share a token with a network failure or a malformed answer. An unsafe
  session id is now refused before anything is read or asked: `fleet-control`
  exits 2 (usage) and the drain guard denies the spawn with a `Fix:`.

### Enforcement layers

Drain is enforced in four layers. Each one names the mechanism that fires it
and the measurement that shows it can fire.

#### Layer 1: the drain guard hook

`ai/hooks/fleet-drain-guard.sh` (DND-443) is the **primary** layer. DND-428
measured every property it relies on (Claude Code 2.1.281):

- It is a PreToolUse hook whose matcher MUST cover the `Agent` tool (it MAY
  also list `Task`). PreToolUse fires for Agent calls made by the top-level
  session and by any subagent, foreground or background, headless or
  interactive.
- It MUST key on `tool_input.subagent_type` and act only when that is a fleet
  worker (`athena-admiral`, `athena-captain`). Any other spawn passes untouched
  and without a server call. DND-428 saw the field on every spawn it probed. A
  spawn without it runs the Agent tool's default agent, which is never a fleet
  worker, so it passes too. It MUST NOT key on
  `tool_input.run_in_background`, which is absent whenever the harness
  backgrounds a spawn on its own, nor on the presence of `agent_id`.
- It MUST look up control by stdin's `session_id`, the top-level session's id
  at every depth, through `fleet-control check`. So one answer covers admiral
  and captain spawns alike.
- On `drain` it MUST answer `permissionDecision: deny`. That stops the spawn in
  default, `auto` and `bypassPermissions` modes. Stdin it cannot parse, and a
  fleet-worker spawn whose stdin has no `session_id`, are never read as
  cleared: the hook denies each with a `Fix:` naming the problem, because a
  spawn it cannot classify, or cannot look up, is one it cannot clear.
- The caller sees only an error string, `PreToolUse:Agent hook error: <reason>`,
  with `is_error: true`. So the deny reason carries the whole instruction:
  `Fix: fleet session <claude_session_id> is draining (<reason>, until <until>; basis <basis>) — this spawn was refused, not failed: do not retry it and do not do its work in-line; run the drain protocol, then wait for the session to return to run (override on the fleet page to force it).`
  `<until>` renders `unbounded` when the answer has no `until`.
- It MUST be registered in `ai/hooks/registry.json` and pass
  `check-hooks-registered`, and its `--self-test` MUST prove the deny with a
  `drain` answer, the pass-through with `run`, and that each unknown-state
  warning reaches the transcript.
- A pass on any basis but `server` carries the warning as the hook's
  `systemMessage` (for the human) and `additionalContext` (for the model).
  Hook stderr on exit 0 reaches neither. Every fleet-worker decision is also
  appended to `$XDG_STATE_HOME/athena/fleet/drain-guard.log`, the evidence a
  live verify reads.

The athena-admiral template, `athena:dispatch-captain` and
`athena:admiral-resume` MUST each tell the admiral to read a refused spawn
carrying this `Fix:` as **PAUSE**: mark the mission `PARKED`, run the drain
protocol, never retry the spawn, and never do the captain's work in-line.

#### Layer 2: the admiral checkpoint

The admiral runs `ai/bin/fleet-control check` before every dispatch point:
initial dispatch, refill on a captain's return, and re-dispatch on resume. Exit
0 dispatches. Exit 3 starts the drain protocol. Any other exit is an error the
admiral reports, never a dispatch. `admiral-report-watch` MUST also print
`CONTROL: drain` on its existing wait cadence when `fleet-control check` turns
to `drain`, so a waiting admiral wakes. It checks about every 60 s, and also
prints `CONTROL: run` on the way back and `CONTROL: unknown` when the check
errors. The admiral's procedure is `athena:fleet-drain`. This layer is cooperative: an admiral
that skips it is still stopped by layer 1 at its next spawn, so it costs
latency, not correctness.

#### Layer 3: the drain protocol

On drain the admiral MUST, in this order:

1. Stop dispatching.
2. Mark every `QUEUED` mission `PARKED` in `state.md`, and report
   `admiral_state draining` and the updated `admiral_scope`.
3. Let each running captain reach a terminal report, and never end its own turn
   while a captain runs: ending an admiral's turn kills its running captains.
   The grace depends on the reason class (OQ-2, owner decision 2026-09-24):
   - `override:force_drain` (the owner's pause): a running captain may finish
     its current mission for at most 30 min. Then the admiral SendMessages it
     to park.
   - `metering:*`, and a `local-rule:*` drain: the admiral tells every running
     captain to park at once.

   To park, a captain commits its work in progress, pushes its branch, and
   reports `PARKED`.
4. When no captain runs, report `admiral_state drained`, write its final
   report, and end its turn.

#### Layer 4: resume

A transition to `run` emits `fleet.session.control_changed`, whose direct
delivery lands on the session's inbox and wakes the top-level session through
`inbox-wait`. The session then runs `fleet-control check`. On exit 0 on basis
`server` it claims the drained runs with `ai/bin/fleet-resume claim`, and spawns
one fresh admiral with `athena:admiral-resume` per claimed `run_id`. That admiral
salvages, adopts worktrees and re-dispatches `PARKED` missions. At most one
admiral owns a run: the claim appends a `RESUMED` marker to the run's state log
under a lock BEFORE the spawn, so two wakes for one run (a duplicated line, and a
draining admiral's hand-back) claim it once (`athena:fleet-drain` → *Run
ownership*). That spawn
passes layer 1 too. Layer 1 asks the server before it reads the cache, so a
stale `drain` cache cannot refuse a resume while the server answers. When the
event carries no `to`, nothing wakes the session. The fleet page names that
case (*Declared families beyond the first pass* →
`fleet.session.control_changed`), and the owner resumes the session by hand.

**Later (2026-09-24):** DND-443: this paragraph said the session spawns a fresh
admiral "on exit 0" of `fleet-control check`. Two changes replaced that. Resume
now needs exit 0 on basis `server`: a recomputed or local-rule `run` is the
owner's fail-mode rule, not the owner's decision to resume. And the session
claims the run with `fleet-resume claim` before it spawns. Without the claim,
two wakes for one run could each spawn an admiral for it (critic rounds 1 and 3).

---

## Relationship to the Athena Inbox contract

The inbox is **one delivery adapter** among several. This contract owns the event
platform (envelope, taxonomy, ingress, rules, predicates, adapters,
templating, trust posture, security). The Athena Inbox contract
(`ai/contracts/athena-inbox.md`) owns the inbox *channel mechanism* — the `log`
and `maildir` kinds, the doorbell, consumption state, tenancy resolution, and the
Path-2 *Untrusted input* boundary. Where the inbox adapter produces `log` lines,
it MUST conform to that contract; this contract does not restate or override it,
with one named exception immediately below.

**Later (2026-09-23):** this section previously stated that rule with no
exception. Superseded (D40, HG-16/DND-311, admiral-directed scope addition):
the inbox `log` line's `kind` value is now made normative here too, because
the mapping is this contract's own taxonomy being named, not the inbox
channel mechanism — see the exception immediately below.

**The exception, because it is this contract's own taxonomy being named: the
inbox `log` line's `kind` value for each type this contract declares.** The
inbox adapter server-stamps `kind` on every `producer:"platform"` line
(`ai/contracts/athena-inbox.md` → *A `log` channel MAY have a non-Slack
producer*, `Athena.Events.InboxLine.kind/1`) — the sender's payload never sets
it, and any `kind` a payload does carry is overwritten. The value is derived
from the **routed event's `type`**, this contract's own field, so the mapping
is normative here:

| Routed event `type` | Line `kind` |
| --- | --- |
| `fleet.session.message` | `session.message` |
| `notion.agent_message.*` | `agent_message` |
| `slack.interaction.received` | `slack.interaction` |
| `fleet.session.control_changed` | the `type` itself, verbatim: a state-change line on the session's `session` channel, not a lane |
| any other (a lane state-change line) | the `type` itself, verbatim (e.g. `notion.ticket.updated`) |

This binds every platform-producer `log` line — lane lines, the three named
delivery kinds, and the session channel's `fleet.session.control_changed` line alike. It does not touch the Slack receiver's own `log` line,
whose `kind` is that separate encoder's `im|mpim|channel|mention|thread_reply`
enum (`ai/contracts/athena-inbox.md` → *Line format*) — a different producer,
outside this contract's taxonomy. The byte-level framing this value sits inside,
and every other field a platform line carries, remain `athena-inbox.md`'s
(*Line format*), unrestated here.

The **local session wake** — pushing a delivered inbox line into a running
session — is **consumer-side**, done by the `inbox-wait` background waiter the
inbox skill arms (`ai/skills/athena:inbox/SKILL.md` → *How to arm it*), not by
this platform; a platform **session-delivery adapter** (the platform pushing
directly to a machine's session) is roadmap, not built (DND-250 / DND-253).

**Later (2026-09-22):** this named the inbox **channel shim**
(`ai/skills/athena:inbox/channel/`) as the local-wake mechanism (the "Inbox on
Channels" epic); that delivery mechanism was abandoned by owner decision and its
code removed, so the local wake is the `inbox-wait` waiter above. The
consumer-side / platform-roadmap split is unchanged.

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
  source-emitted `slack.*`/`notion.*` type or a platform-originated `fleet.machine.*` or
  `fleet.session.control_changed` type (*Which event types an ingress kind may originate*);
- resolves a metadata-only source by an **on-demand read** enrichment fetch (least-privilege
  enforced server-side per-caller, not by token scope — *Secret custody*; *Sender verification and payload completeness*),
  and on enrichment failure **neither emits un-enriched nor silently drops** — retrying transients
  under a bounded budget, recording a permanent/exhausted failure in the **ingress-failure store**
  and **reporting it to the owner**, and mapping a definitive not-found to the identity-only delete
  path (*Sender verification and payload completeness*);
- records a reconciliation-backstop **run** on its own, so the "I checked" signal survives even
  when every hit is a redelivery the idempotent consumer absorbs (*Poller (fallback only)*).

**The router is conformant when it:**
- evaluates an event against **all** of the owner's **enabled** rules, firing **every** match
  independently — no first-match, no ordering, no short-circuit (*Fan-out: every match fires*);
- scopes the Level-1 HANDLED/UNMATCHED decision to the **event owner's own** rules **or a direct
  delivery** (D40 — an addressed `fleet.session.message` with zero matching rules is still
  HANDLED), dead-letters **UNMATCHED** to the per-`(owner, type)` exemplar-plus-count store (never
  merely counted, never silently dropped), and never dead-letters a HANDLED event (*Event
  disposition and dead-letter*);
- resolves **every** non-DELIVERED Level-2 outcome to its own observable disposition — FILTERED,
  SUPPRESSED, REFUSED (refused-delivery store + report), FAILED (failed-delivery store + report)
  — so no matched delivery is ever a silent drop (*Event disposition and dead-letter*;
  *Terminal delivery failure — the failed-delivery store*; *Delivery refusal — the refused-delivery
  store*);
- delivers **at-least-once** and retries at the **`(event, rule)`** grain using the event-level key combined with the
  stable `rule_id` — or, for a direct (rule-less) delivery, its own key (*Declared families beyond
  the first pass* → `fleet.session.message`, stated once there) — holding no durable dedupe store
  and requiring consumer idempotency (*Idempotency is per (event, rule)*; *Rule identity —
  `rule_id`*);
- applies the dedupe window at its declared **`(rule_id, subject)`** grain (*Enabled flag and
  dedupe window*);
- validates every rule at **save time** — **each declared `event_type` is a
  member of the registered type set** (predicate-independent, so an envelope-only
  rule with a misspelled type cannot save dark), predicate **and template-slot**
  field-paths against the union of declared types' schemas, operator cardinality,
  operator/literal type,
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
  conformant `log` line carrying every field `athena-inbox.md` → *Line format* requires of a
  platform line (*Mechanism vs config boundary, and
  both-ends-or-dark*; *The lane channel is a change stream, not the authoritative set*);
- custodies secrets by **KMS envelope encryption**, decrypting least-privilege at use time for the
  owning account only, and never logs / argv-exposes / API-exposes a secret (*Secret custody*;
  *Config vs secret — the encryption boundary*).
