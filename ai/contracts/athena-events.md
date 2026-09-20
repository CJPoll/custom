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
`ai-artifacts/coordination/2026-09-19-inbox-lanes/design.md` (a dated record);
where that design and this contract disagree on a normative point, **this
contract wins**.

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

An event whose `type` matches **no** enabled rule MUST be **dead-lettered and
persisted** to queryable storage for audit and debugging. It MUST NOT be silently
dropped, and it MUST NOT be **merely counted** — a bare counter cannot answer
"which event, of what type, for which owner, went unmatched?", and that question
is exactly the failed-lookup discipline (`~/dev/custom/CLAUDE.md` → *A failed
lookup must never look like an empty one*): an unmatched event is a legitimate
miss, and a legitimate miss MUST remain observable as the specific thing it was.

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
server-side cursor and emits one event per new hit, deduped by the same
`idempotency_key` machinery as the primary path. A reconciliation backstop is
what makes "nothing is queued" **provably** true rather than merely unobserved
(failed-lookup discipline), so it MUST NOT be conflated with the primary trigger
in dedupe or in reporting.

### Harness-emit

`POST` from the fleet/harness via a small deterministic "fire `{type, payload}`"
primitive, authenticated by the **machine token**; the owner is resolved
server-side from that token (never from the payload). It carries no notification
logic — it only produces an event. (Roadmap increment; the envelope is specified
now so it is a natural later increment, not a rewrite.)

---

## Handling rules — fan-out, predicate-driven, config not code

A rule is **config the platform evaluates, never executable code**. A rule
carries: the `event_type(s)` it applies to, its **predicate** (see *The predicate
grammar*), its **kind** (`notify` / `membership`), its **adapter + target**, its
**template + format** (see *Templating and the per-adapter Escaper contract*),
and its **enabled flag + dedupe window**.

### Fan-out: every match fires

One event MUST be evaluated against **all** of the owner's enabled rules, and
**every** matching rule fires **independently**, each producing its own delivery.
There is **no first-match, no rule ordering, and no short-circuit.** A single
"ticket updated" event where `assignee == Cody` **and** label `Flaky Test` is
present fires BOTH a "DM me in Slack" rule AND a "push to flaky lane" rule → two
independent deliveries, each with its own per-`(event, rule)` idempotency and
retry.

### Two rule kinds

- **`notify` (stateless).** Predicate matches the present event → render + escape
  → dispatch to an adapter. Fires per event. The "DM me when assigned" case.
- **`membership` / lane (stateful).** The predicate defines a **set**; the
  platform maintains the derived membership per `(owner, rule)` in the
  lane-membership store (see *Membership rules and the lane-membership store*).
  Each relevant event → enrich current state → re-evaluate the predicate → diff
  against the stored set → emit an `add` or `retract` transition, which drives
  the delivery.

### The predicate grammar

A predicate is a **JSON tree**, evaluated by the platform; it is never code.

**Comparison leaf:**

```
{ "field": <field-path>, "op": <comparator>, "value": <literal> }
```

- **field-path** addresses the event with a dotted path to a **bounded depth**:
  `event.type`, `payload.assignee`, `payload.labels`, `payload.status`,
  `payload.title`, …. An unresolvable path evaluates to **absent** (matchable —
  see the evaluation contract), never to an error.
- **comparators:**
  - `eq`, `ne`, `lt`, `lte`, `gt`, `gte` — scalar comparison.
  - `in` — scalar is a member of the literal set.
  - `contains` — a collection field contains the literal (e.g. a multi-select
    `labels` contains `"Flaky Test"`).
  - `intersects` — a collection field's intersection with a literal set is
    non-empty (e.g. `assignee` ∈ {Cody, Athena}).
  - `exists` / `absent` — presence / absence of the field on the **current**
    payload (the matchable form of a cleared assignee or a removed field).

**Boolean nodes:** `{ "all": [ … ] }` (AND), `{ "any": [ … ] }` (OR),
`{ "not": <node> }`. A predicate is therefore an **arbitrarily nested tree** of
boolean nodes over comparison leaves (e.g. `all[ any[a, b], not[c], d ]`),
bounded only by a depth/size cap.

**Evaluation contract.** Predicate evaluation MUST be **pure, total,
deterministic, and side-effect-free** (Domain code, per `~/dev/custom/CLAUDE.md`
→ *Architecture*). No arithmetic beyond comparison, no regex, no code, fixed
type-coercion rules, bounded depth/size. Specifically:

- **A missing field is `absent`** — matchable by `absent`/`exists`, and a leaf
  that reads it yields a defined non-match rather than a crash. Evaluation MUST
  NEVER throw on a missing or unexpected field.
- **A malformed predicate is a HARD ERROR at rule-SAVE time**, naming the fault
  with a `Fix:` (which node, which field, what is wrong). It MUST NOT be a silent
  eval-time non-match at dispatch. A bad rule must be **loud where it is
  authored, not dark where it runs** — this is the failed-lookup discipline: a
  malformed rule that silently matches nothing is indistinguishable from a
  correct rule that legitimately matched nothing.

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

**Worked owner examples:**

- *"ticket assigned where assignee == me → Slack DM"* (`notify`):
  `{all:[{field:"event.type",op:"in",value:["notion.ticket.created","notion.ticket.updated"]},
  {field:"payload.assignee",op:"eq",value:"<cody-person-id>"}]}` → Slack adapter.
- *"ticket created OR updated where assignee ∈ {Cody, Athena} AND label 'Flaky
  Test' present → flaky-lane inbox channel"* (`membership`):
  `{all:[{field:"event.type",op:"in",value:["notion.ticket.created","notion.ticket.updated"]},
  {field:"payload.assignee",op:"intersects",value:["<cody>","<athena>"]},
  {field:"payload.labels",op:"contains",value:"Flaky Test"}]}` → inbox adapter,
  flaky channel; the membership diff emits `add`/`retract`.

The router evaluates all rules with a pure matcher, a pure renderer, and a pure
membership-diff (Domain), and dispatches through adapters and the membership store
(Side Effects). Generic router code is tenant-blind: it takes the owner's rules as
input and contains none.

---

## Membership rules and the lane-membership store

The lane-membership store is the platform's **source of prior state**, and it is
what makes retraction reliable **without** source deltas.

- Per `(owner, membership-rule)` the store holds the member **entity IDs** plus
  the **minimal display fields** needed to render a retract (e.g. ticket number
  and title).
- On each relevant event: **enrich** current state → **re-evaluate** the
  membership predicate → **diff** against the stored member set → append an `add`
  (a new member entered the set) or a `retract` (a member left the set — it now
  fails the predicate, or it was deleted).
- Because the store caches the minimal display fields **at add time**, a
  `retract` can be rendered even after the entity is deleted and can no longer be
  fetched (a `notion.ticket.deleted` on a stored member emits a `retract` from
  the cached fields). This is exactly "deleted-that-had-the-label".

The store is source-agnostic — it carries over to a forge or any other membership
lane — and turns "retraction" from an unanswerable source-delta question into a
store diff. The cached display fields are the owner's own workspace data,
deliberately minimized to what a retract line needs, and remain **Path-2
untrusted** when they reach an LLM (see *Trust posture — two paths*).

### The lane channel is a change stream, not the authoritative set

A membership lane delivered to an inbox `log` channel carries an **add/retract
stream** — `{op:"add"|"retract", …}` lines — and the lane's working set is
`fold(adds − retracts)`. This is still a conformant append-only `log` channel:
the *lines* are appended; the *derived set* is what changes.

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
