# Athena Judgments — contract

**Kind: living normative document.** Amended in place, per `~/dev/custom/CLAUDE.md`
→ *Documentation conventions*.

**Status:** normative. **Adopted:** 2026-09-25. This document is the contract for
**judgments**: typed, probabilistic answers that Athena asks of an external model
(TypeSafe's Jev) and feeds into deterministic policy as advisory input. It states
the trust posture, the data that leaves the machine, the port, the fallback, the
modes, the threshold rules, the budget and the lifecycle. The implementation is
gen_saas `Athena.Judgments` (DND-709) and its consumers.

**Normative home:** `~/dev/custom/ai/contracts/athena-judgments.md`. The design
record it is drawn from is the Notion epic "Athena × TypeSafe (Jev) judgments"
and its Architecture & Engineering page (a dated record, cited for provenance
only). Where that design and this contract disagree, **this contract wins**.

**How this document is amended.** As a living normative document:

- **Normative prose is amended in place.** A superseded rule is replaced, not
  left beside its replacement.
- **Each amendment that supersedes an existing rule is announced by exactly one
  paragraph opening with a bold dated label** — `**Later (YYYY-MM-DD):** …`, in
  UTC — at the definitional mention. It says what the rule was, what replaced
  it, and why.
- **Purely additive content carries no label.**

Sections are cited **by name**, never by number.

**Conformance language.** MUST / MUST NOT / SHOULD / MAY carry their usual force.
A **use case** is one fixed purpose Athena judges for (`finding_triage`,
`slack_routing`, `priority_scoring`, `ticket_kind`, `ticket_severity`,
`ticket_security`, `ticket_blocking`, or `eval:<use_case>`). A **question set** is
the versioned code that turns a use case's input into the request. A **caller**
is the consumer that asked for a judgment and acts on the result. An
implementation that violates a MUST is non-conformant.

**Every refusal, hard error and fault-class fallback specified here MUST carry
a greppable `Fix:` clause** in its log line or structured field, naming the
corrective action (*Fallback: every error equals today's behaviour, loudly*
says which fallbacks are faults), per `~/dev/custom/CLAUDE.md` →
*Guard/error messages are written for the LLM*. This contract quotes exact
`Fix:` text only where a fixture pins it: *Finding triage: the harness script*
(DND-713) and *Ticket classification: the harness script* (DND-1054), both in
`ai/contracts/fixtures/athena-judgments-quoted-fix.txt`. When an
implementation pins more exact text, the ticket that ships it adds the quote
and its pin together (`ai/contracts/test/check-quoted-fix.rb`, DND-411).

---

## Purpose and non-goals

A judgment answers a narrow typed question — a choice among fixed options, or a
score on a fixed scale — with a confidence. Four consumers use it today:

- **Finding triage** (DND-713): before a finding is filed, advise whether it
  duplicates or relates to an existing ticket, and suggest a severity.
- **Slack routing** (DND-716): route a new conversation the owner wrote to the
  owning session by topic. The router order is
  `ai/contracts/athena-events.md` → *New conversations may route by an advisory
  topic judgment*.
- **Priority scoring** (DND-718): add bounded urgency and importance reasons to
  an indexed item's rank (`ai/contracts/athena-events.md` → *Ranking*).
- **Ticket classification** (DND-991, DND-1054): when a ticket is filed, decide
  its `Kind`, `Severity` and `Security` by deterministic policy from the
  filer's values and three judgments (`ticket_kind`, `ticket_severity`,
  `ticket_security`). For a finding filed with `--epic` (DND-1057), also
  decide its `Path` (`Blocking` or `Off`) and the one critical-path ticket it
  blocks, from the filer's claim and a fourth judgment (`ticket_blocking`).

Every consumer's result has a **receiver**, and the receiver can record that
the judgment was wrong. That record, with the exact request Jev was sent, is
how accuracy is measured and improved (*Receiver feedback*).

Non-goals. A judgment never:

- authorizes anything, closes, merges or cancels a ticket, sends a reply, or
  decides an owner-gated step;
- generates text (no generative use). Item summaries
  (`ai/contracts/athena-events.md` → *Priority index* → *Item summaries*) are
  generative. They are not judgments: they use their own port, key and
  budget, and nothing in this contract governs them;
- routes a thread reply (thread claims own that:
  `ai/contracts/athena-events.md` → *Thread replies route to the thread's
  claimant*);
- depends on a fine-tuned model (the domain goes into the state and the
  criteria);
- runs on an inbound webhook's response path. A caller that needs a judgment
  for a webhook's delivery writes an obligation row in the delivery's
  transaction, acks, and judges in a supervised worker (gen_saas ADR 21,
  *Webhooks Verify, Persist and Ack*). The Slack router's form of this is
  `ai/contracts/athena-events.md` → *Routing runs after the ack*. So no use
  case needs a latency bar to protect a sender's ack.

This contract changes nothing in walt_ui. walt_ui may adopt the triage script
later, as its own change.

## Trust posture

> A judgment is advisory input to deterministic policy. It never authorizes an action, never grants or widens access, and never selects a destination or target outside a set the owner already authorized. It is never the sole basis for a destructive, irreversible, owner-gated or security-relevant step. The `state` sent for judgment is untrusted data: its text can steer the answer (TypeSafe, jev-1.13 jaggedness, *Adversarial content*). A use case is admissible only if a wrong answer costs at most one of: a recoverable misroute between the owner's own sessions, a misranked item, or a wrong advisory line a human or agent reads before acting. Typed output guarantees the interface, not truth.

This mirrors the inbox rule that content can cause a report but never authorize
an action (`ai/contracts/athena-inbox.md` → *Untrusted input*). That rule's
one exception, an owner click passing four checks, has no judgment analogue. A judgment-routed
Slack line is inbox content like any other: the receiving session re-verifies it
and treats its body as untrusted, exactly as for a line the channel route
delivered.

Concretely:

- **Slack routing chooses only among the owner's own topic routes**, each
  authorized by `:add_slack_route` when it was written.
- **Only the owner's own text is judged for routing.** A new conversation from
  anyone else follows the channel route by code, with no call. This bounds the
  adversarial surface. The conversation context sent with a root (*Egress and
  data flow*, the `slack_routing` row) holds only the owner's own earlier text
  and session labels for Athena's own posts; the owner filter is applied in
  code, on the server, whatever the caller passed.
- **Triage prints advice only.** It never closes, merges or re-prioritizes a
  ticket. The filer decides.
- **Priority adds bounded reason deltas.** An owner override always wins, and
  the default `vip_asker` weight exceeds the largest combined judged delta.
- **Ticket classification sets only Kind, Severity and Security**, through
  deterministic policy. It never lowers a security classification, never
  assigns or replaces `Feature`, and never touches `Status`. Every
  fallback starts from the filer's own value; the one change with no judgment
  is a raise (the Vulnerability floor, *Ticket classification: the harness
  script*).
- **Ticket blocking decides only a finding's `Path` and one `Blocks` edge**
  (DND-1057), through deterministic policy (gen_saas
  `TicketBlockingPolicy`). The value is `Blocking` or `Off`, never `Critical`
  or `Promoted`: those are authored, and a ticket the filer names a
  `Feature` is never sent. The edge may point only at a candidate the
  harness chose in code (the epic's open `Critical` tickets, at most 10, by
  ID) or, by the introduced-security rule below, the Found while ticket. A
  security
  issue the ticket's own change introduced blocks the ticket it was found
  while working, by rule, with no call. A judgment never removes a blocking
  claim the filer made for a finding whose Security is not `none`. The
  filer sets `Path` and wires the edge from the printed decision; nothing
  writes the tracker.

  **Later (2026-09-30, DND-1057):** the bullet above ended "and never touches
  `Status` or `Path`". Superseded by the ticket-blocking bullet: Path's
  `Blocking`/`Off` choice for a finding is now decided by policy, with a
  judgment as one input. `Critical` and `Promoted` stay authored.
- **Arithmetic, dates, sender identity and all policy stay in code.** jev-1.13
  is unreliable at counting, math, dates and indirection, so none of them is
  asked of it.

## Egress and data flow

**D1 (owner, 2026-09-25, RESOLVED): work content may go to TypeSafe.** Cody,
in-session, verbatim: "That is fine. This is a work-paid-for API key, and if I
stop working there then the webhooks will stop flowing to us, and we'll lose
access to the jev account anyways."

**D2 (owner, 2026-09-25, RESOLVED): personal-domain content may go too.** Cody,
verbatim: "Yes, personal too". Jev may judge `work`, `blend` and `personal`
content: personal-project findings (the dnd, lms and admiral apps) and
`personal` priority items included. There is **no** `domain_not_permitted`
fallback for personal content. Every call still records its content domain, for
cost attribution. A call whose domain is absent or not one of `work`, `blend`
or `personal` is refused as `domain_not_permitted` (deny by default).

**What is sent, per use case.** Only the fields below. Nothing else is added to
the request's `state`.

| Use case | Sent |
| --- | --- |
| `finding_triage` | the finding's title, body (at most 2,000 characters) and project; up to 20 candidate tickets as ref, title and summary (at most 500 characters each) |
| `slack_routing` | the owner's own message text and its line `kind` (`im`, `mpim` or `mention`); and the conversation before it: of the six most recent top-level messages in the same channel within the 60 minutes before it (whoever sent them, oldest first), the owner's own text (each at most 500 characters), and Athena's own posts as the posting session's label only (`walt_ui`, `harness`, `gen_saas` or `other`), never their text. Anyone else's message holds its place among the six and is sent in no form: nobody else's text is ever sent. The window, the cap and the text cap are part of the question-set version (`slack-routing-v2`) |
| `priority_scoring` | the item's `title`, `source` and `status`, plus `message_text` for a `slack_ask`; never a date and never the asker |
| `ticket_kind`, `ticket_severity`, `ticket_security` | the ticket's title, body (at most 2,000 characters, its trailing `Source:`/`Context:` provenance block dropped) and project; never its status, dates, assignee or author |
| `ticket_blocking` | the finding's title, body (at most 2,000 characters) and project; up to 10 candidate tickets as ref, title and summary (at most 800 characters of the candidate's body, its requirements); never a status, date, assignee, author or the filer's claim |
| `eval:<use_case>` | the same request the product use case builds, for a labelled case |

**Later (2026-09-28):** the `slack_routing` row read "the owner's own message
text and its line `kind` (`im`, `mpim` or `mention`)", the root alone
(`slack-routing-v1`). Superseded by DND-1048 (`slack-routing-v2`). Why: the
owner, labelling DND-715's corpus, found roots they could not route without the
conversation before them, so a root-only judge would be blind on them. Athena's
posts go as a session label, not text, because their text can quote a third
party. The context is read from gen_saas's own `slack_events` and
`slack_thread_claims`, never from the Slack API; it is built in memory for the
request and stored nowhere.

**Later (2026-10-01, DND-1590):** the ticket classification row read "body
(at most 2,000 characters)", the body as filed. Superseded by the dropped
provenance block (*Ticket classification: the harness script* → *A trailing
provenance block is not sent*). Why: `ticket-severity-v1` rated 8 of 9
findings CRITICAL because each body ended by citing the prod outage it was
found during, and the filer overrode all 8.

**What is stored: no text on the call record; the request, for a bounded
time, beside it.** The call record (`judgment_calls`) holds no state text. It
holds an opaque `subject_ref` (an event id, a ticket ref or an item id), the
outcome and reason, the model, the answers (choice or score, probabilities,
confidence) and token usage and cost. For a call that reached the port it also
holds the call's latency (`latency_ms`) and, when the caller declared when it
began waiting, its wait (`wait_ms`, *Modes*). It MUST refuse a `state`, `text`
or `body` key in the stored answers. Rows are pruned after 30 days.

The judgment stores text in exactly two places, both for *Receiver feedback*:

- **`judgment_payloads`**: the request sent to TypeSafe (`state`, `questions`,
  `model`; never the key) of every **answered product** call. An `eval:*`
  call and a fallback store none. A payload row is deleted with its call, at
  30 days.
- **`judgment_feedback`**: a copy of that payload on each feedback row, with
  the receiver's optional `note` (at most 500 characters). Kept 90 days.

Neither holds anything that was not already sent to TypeSafe, except the
receiver's own `note`. The eval corpus stays machine-local and untracked,
joined to its source by id. The `slack_routing` root snapshot
(*Threshold provenance, n/a and the pinned model* → *Slack routing labels*)
also copies Slack lines, because the Slack inbox rotates: the owner's root
text and the owner's earlier text in its context window. Anyone else's line
keeps only its user id and ts, with its text emptied. It is 0600 under the
inbox root, never in a repo.

Those are the judgment's own stores. The Slack router's stores hold message
text for delivery, not for a judgment: a `slack_events` line, pruned 24 h
after it arrives once delivered, and a `slack_route_requests` row, which holds
the parsed event until it is routed and is then deleted
(`ai/contracts/athena-events.md` → *Routing runs after the ack*).

**Later (2026-10-01, DND-1448):** this read "joined to its source by id,
never copied into a second file". Superseded by the root snapshot: joined
to the rotating inbox, the `slack_routing` corpus shrank instead of
accumulating.

**Later (2026-10-01):** this paragraph was "**What is stored: no text.**
gen_saas stores no state text for any judgment." Superseded by the owner's
feedback loop (Cody, 2026-10-01 ~05:20Z: wrong judgments "should be recorded
(along with the event that was judged incorrectly) so the shipwright cron can
evaluate how to improve the payloads"). Why: a judged input is gone or changed
by the time a receiver says it was wrong (a delivered `slack_events` row is
pruned at 24 h; a ticket body is edited), so a payload rebuilt then is not the
request Jev answered. `judgment_calls` keeps its no-text rule and CHECKs; the
text lives in its own two tables, with their own retention and read path
(gen_saas ADR 22).

**What TypeSafe keeps** is TypeSafe's data-handling terms, read 2026-09-25:
TypeSafe does not train on requests, and its DPA covers retention. Zero data
retention is enterprise-only, and this contract assumes we do not have it.

## The port and its closed error set

One endpoint: `POST /v1/systemone` with a bearer key, body
`{state, model, questions}`. The response carries the versioned `model` that
answered, the `answers`, and `usage` (`input_tokens`, `output_tokens`).

The port (`Athena.Judgments.Port`) MUST:

- take the key as an argument only. It never stores, logs or puts the key in an
  error term;
- take its base URL from config, never from argv;
- enforce a hard receive timeout from the caller's deadline;
- never retry. Retry is the caller's policy;
- request the pinned model (*Threshold provenance, n/a and the pinned model*).

A port error is exactly one of:

| Port error | Cause |
| --- | --- |
| `unauthorized` | HTTP 401 or 403 |
| `request_rejected` (with detail) | HTTP 400 or 422 |
| `rate_limited` (with `retry-after` seconds, or none) | HTTP 429 |
| `overloaded` | HTTP 529 |
| `http_status` (with the status) | any other non-2xx status |
| `timeout` | no response within the deadline |
| `transport_error` | connection failure |
| `undecodable_body` | a 2xx whose body is not JSON |

A `request_rejected` detail never quotes the response body, which can echo the
request's state text. A 422's detail is its first error's `type` and `loc`
identifiers, or `unprocessable` when it has none it can use; a 400's detail is
`bad_request`.

**Later (2026-09-30, DND-948):** `request_rejected` was HTTP 422 only, and a 400
fell into `http_status`. Replaced by 400 or 422: the real API refuses most
requests we built badly with 400 (too many options or levels, a noul with
neither instructions nor criteria, an unknown model; captured 2026-09-27), and
sends 422 only for a schema failure. As `http_status`, our own bug read as a
TypeSafe service fault.

A test double of the port MUST reject what the real API rejects (for example,
a Choice with 256 options), so a request the real API would refuse cannot pass
in tests.

## Fallback: every error equals today's behaviour, loudly

**The rule.** When a judgment is not accepted, for any reason, the caller does
exactly what it did before judgments existed. Nothing is dropped, queued for a
retry storm, or silently succeeded. Every non-accepted outcome leaves

1. a `judgment_calls` row, or a caller-side record, with the exact reason from
   the list below;
2. a `[:athena, :judgments, :fallback]` telemetry event carrying the reason and
   its class.

**Each reason has a class.** A **`state`** reason is the system working as
configured: the mode is off, the sender is not the owner, an answer is under
its label's enabled threshold. There is nothing to fix, so it logs at debug level with no
`Fix:` clause, and it never changes a use case's health. A **`fault`** reason
means something is wrong: a missing key, a rejected credential, a spent budget,
a service error, our own bug. A fault is loud: it also logs a warning (an error
for our own bugs) naming the use case, the reason, the owner and the
`subject_ref`, with a `Fix:` clause, and it moves health to `unavailable`.
Which alert it raises is *Owner alerts: one rule per reason*. So a real fault
is never buried under routine fallbacks.

A fallback whose reason is a missing key also names **the key it searched for**,
`(owner_id, :typesafe_api_key)`, so a key looked up wrongly never reads as a key
correctly absent (`~/dev/custom/CLAUDE.md` → *A failed lookup must never look
like an empty one*).

**The order of checks.** One `judge` call records exactly one row, with the
reason of the first check that fails:

1. content domain;
2. building and validating the question set's request;
3. mode (skipped for `eval:*`);
4. price, budget and local rate;
5. the key is stored;
6. the credential latch (an `unauthorized` recorded after the key was stored);
7. reading the key from custody and making the call, under the deadline;
8. parsing the answer strictly against the request;
9. the answering model equals the pinned model.

Every check that fails before step 7 makes **no** call to TypeSafe.

**The closed reason list.** A reason not on this list is non-conformant. Adding
one is an amendment to this table.

| Reason | Class | Where | Means |
| --- | --- | --- | --- |
| `mode_off` | state | judge | the use case's mode is `off`; the manager returns `not_configured` |
| `key_missing` | fault | judge | no key stored for the owner; the manager returns `not_configured`; the record names the searched key |
| `domain_not_permitted` | fault | judge | the content domain is absent or not `work`, `blend` or `personal` |
| `invalid_request` | fault | judge | our question set built an invalid request (our bug: error-level log) |
| `price_unknown` | fault | judge | no configured price for the pinned model, or a call in the budget window has no cost, so spend could not be measured |
| `budget_exhausted` | fault | judge | a dollar cap would be exceeded; the record names which cap (`monthly` or `daily`) and whose (the total or the use case) |
| `rate_limited_local` | fault | judge | the owner's local rate limit is reached |
| `credential_rejected` | fault | judge | the port returned `unauthorized`, or the latch holds from an earlier one |
| `custody_fault` | fault | judge | reading the key from custody raised |
| `timeout` | fault | judge | the deadline passed |
| `rate_limited` | fault | judge | TypeSafe returned 429 |
| `overloaded` | fault | judge | TypeSafe returned 529 |
| `request_rejected` | fault | judge | TypeSafe returned 400 or 422 (our bug: error-level log) |
| `http_status` | fault | judge | TypeSafe returned another non-2xx status; the record carries it |
| `transport_error` | fault | judge | the connection failed |
| `undecodable_body` | fault | judge | the response body was not JSON |
| `malformed_answer` | fault | judge | the answer does not match the request; recorded as `malformed_answer:<detail>` |
| `model_mismatch` | fault | judge | the answering model is not the pinned model |
| `below_threshold` | state | caller | the confidence is under the accepted threshold, or the answer is `unclear` |
| `threshold_unset` | state | caller | the label's threshold row is malformed (our bug); never accepts, whatever the confidence |
| `label_disabled` | state | caller | the Slack router's topic route for the accepted label (or the session mention's label, DND-717) has `enabled=false`: the owner's own opt-out |
| `label_unconfigured` | state | caller | the Slack router has no topic route for the accepted or mentioned label (DND-1522) |
| `label_stale` | state | caller | the label's topic route exists and cannot be used: its instance or machine is soft-deleted, the machine's owner is not the app's owner, or the instance is no longer a `<project>-slack.jsonl` inbox; the record names the instance and which (DND-1522) |
| `sender_rule` | state | Slack router | the conversation is not the owner's own, so no judgment is asked |
| `context_unavailable` | fault | Slack router | reading the conversation context failed (or the root's `ts` is malformed), so no judgment was asked; the caller-side record is the router's outcome log, with no `judgment_calls` row |
| `route_overdue` | fault | Slack router | the route request was not routed within its routing deadline or its attempt budget (the route worker is down, stuck or behind), so it was delivered by the channel route; the caller-side record is the router's outcome log, and a `judgment_calls` row exists only if a call was made (`ai/contracts/athena-events.md` → *Routing runs after the ack*) |

A successful call records outcome `answered` with no reason.

**Later (2026-10-01, DND-1450):** `threshold_unset` meant "no threshold
exists for the key; never accepts". Replaced by the row above: a label with
no row is accepted on the model's answer (*Threshold provenance, n/a and the
pinned model* → *What `on` accepts*), so only a malformed row still falls
back. Why: the owner's threshold waiver, quoted in *Modes*.

`threshold_unset` stays class `state`, though it now names our bug. A class
says who decides, not how bad it is: a `fault` is the judge failing to
answer, and a `state` is the caller declining an answer it got. The caller
reads the row and declines it. Rows are written only by the eval apply,
through a changeset that validates the threshold, so a malformed row is not
expected to come from the store at all; the reason exists so that one never
reads as an accept.

**Later (2026-10-01, DND-1450):** `label_disabled` also meant "the answer's
label is disabled" (an `n/a` threshold row). Replaced by the row above: an
`n/a` row accepts the model's answer, so `label_disabled` names only a
missing destination. Why: the same waiver.

**Later (2026-10-01, DND-1539):** `label_disabled` meant every missing
destination: a topic route that is missing, disabled or not live. Replaced
by the three rows above (DND-1522). Why: a label with no route read the same
as the owner's opt-out, so a broken route looked deliberate. All three are
state reasons and never move health. Whether a miss is a route flag is the
Slack router's rule (`ai/contracts/athena-events.md` → *New conversations
may route by an advisory topic judgment* → *Route flags*). DND-1522 deployed
on 2026-10-01 (gen_saas PR #655); before that, the router recorded every miss
as `label_disabled`.

**The credential latch.** An `unauthorized` port error (HTTP 401 or 403) sets a
latch keyed on the key's stored-at time. While it holds, every call falls back
as `credential_rejected` with **no** call to TypeSafe, so a revoked key makes
one call, not one per event. Storing a new key (a newer stored-at time) clears
the latch by construction.

**Owner alerts: one rule per reason.** A use case's health is
`unavailable(<reason>)` after a fault-class outcome and `ok` after an answered
call; a state-class outcome leaves it unchanged. Health is what the owner's
health view shows. Alerts go through the existing owner-alert path, and each
reason feeds exactly one alert rule:

- **A state-class reason never alerts.**
- **`budget_exhausted` alerts only by the budget rule**: the first of a UTC
  calendar month sends one alert (*Budget*). A change of health into or out of
  `unavailable(budget_exhausted)` sends no alert about `budget_exhausted`, so a
  daily cap that exhausts and resets each day does not alert each day. (A
  change out of it to `ok` can still send the recovery of an earlier alerted
  fault, per *Recovery follows the last alerted state*.)
- **Every other fault-class reason alerts on a health transition.** When a use
  case's health changes to `unavailable(<reason>)` from any other value, one
  alert goes out. N faults in a row with one reason are N records and one
  alert.
- **Recovery follows the last alerted state.** The **last alerted state** is
  the `unavailable(<reason>)` of the most recent transition alert raised
  (queued for the owner-alert path), until a recovery alert is raised. When health changes to `ok` and the last alerted
  state is a fault-class reason other than `budget_exhausted`, one recovery
  alert goes out, naming that reason, whatever transitions came between. So
  `timeout` → `budget_exhausted` → `ok` sends the `timeout` recovery, and
  `budget_exhausted` → `ok` with no earlier alert sends none.

**Later (2026-09-26):** the recovery rule was "when it leaves that value for
`ok`, one recovery alert goes out", keyed on the health just left. Replaced by
*Recovery follows the last alerted state* above (ruling E8, DND-782). Why:
under the old rule, `timeout` → `budget_exhausted` → `ok` left the owner with
an `unavailable(timeout)` alert and no recovery, because leaving
`unavailable(budget_exhausted)` sends none. The owner saw the outage start and
must see it end.

## Modes

Each (owner, use case) has one mode:

- **`off`** — the shipped default, and the reading of an absent settings row. No
  call is made. The caller does today's behaviour. A caller that asks the judge
  anyway gets `not_configured`, and the judge's record says `mode_off`. A
  caller MAY instead read the mode first and, in `off`, not ask at all. Then
  there is no judgment and so no outcome: no `judgment_calls` row, no caller
  record, no fallback telemetry, and the caller's output is today's, byte for
  byte. One fault is still recorded in `off`: a Slack route request owed from
  before the switch that is delivered late records `route_overdue`, though
  its line is the pre-epic line (`ai/contracts/athena-events.md` → *Routing
  runs after the ack*). `mode_off` is a `state` reason, which never alerts or moves health, so
  skipping its record hides no fault. The Slack router reads the mode first
  (`ai/contracts/athena-events.md` → *New conversations may route by an
  advisory topic judgment*).

  **Later (2026-09-28):** this said only "the record says `mode_off`", which
  read as a record on every `off` path. Superseded by DND-716 (gen_saas PR
  #479), whose Slack router reads the mode before the sender rule and records
  nothing in `off`, so the pre-epic line stays byte-identical.
- **`shadow`** — judge and record, but act exactly as today. The record shows
  what would have happened. `shadow` is an operator tool: the lever to stop
  acting while still judging, for example to roll back a harm. It is never a
  step a use case must pass through.
- **`on`** — act on accepted judgments (*Threshold provenance, n/a and the
  pinned model* → *What `on` accepts*).

**Activation.** A use case goes from wired straight to `on`. An eval is
optional and for measurement only. Where a run's threshold is enabled it
gates its label in `on`; nothing requires a run, a threshold or a period in
`shadow` before `on`.

**`on` and `shadow` are refused** only when the use case has no registered
question set, because both make real calls. **`off` is never refused.** No
threshold row, eval run or latency figure gates `on`. A use case MAY add a
refusal of its own; none does. `eval:*` ignores the mode, but not the key,
the domain or the budget. The owner's writer is gen_saas
`Athena.Judgments.Settings.set_mode/3` (DND-714); every refusal carries
`Fix:`.

**Slack routing watches its queue, not a latency** (DND-1455, gen_saas ADR
21 rule 6). No judgment runs inside Slack's ack: the route worker judges
after it, under a 5,000 ms deadline, and a request not routed within 60 s
goes by the channel route as `route_overdue`, whose health transition is the
alert (`ai/contracts/athena-events.md` → *Routing runs after the ack*). The
judgments tile's `slack_routing` row shows, for the owner's own Slack apps
only: the pending route requests and the oldest one's age, and the median
and max `route_delay_ms` of the requests delivered in the last 24 hours. An
empty queue reads `0 pending`; no delivered request reads "no routed
requests in 24 h", never a 0 ms delay. No latency figure is read for a mode
or shown. `judge/4` still records `wait_ms` (from the caller's
`:wait_started_ms` to the end of the TypeSafe call) beside `latency_ms` (the
call task alone); nothing reads it.

**Later (2026-10-01, DND-1455):** the health tile read the owner's own
`slack_routing` rows of the last 30 days that reached the port, were of the
registered question set's version and carried a `wait_ms`, and showed their
discrete p95 against an advisory target: at least 20 such calls, the first at
least 3 days old (else `unmeasured`), with a p95 of at most 1,000 ms
(`within_target`, else `over_target`), gen_saas `CallStore.on_bar_latency/4`
and `ModePolicy.latency_reading/1` (DND-1398). Replaced by the queue figures
above; the reading and its helpers are removed. Why: since DND-1454 the
judgment runs after the ack, so the wait guarded nothing, and ADR 21 rule 6
says to measure the queue, not the request.

**Later (2026-10-01, DND-1456):** this said what kept a slow judgment inside
Slack's 3 s ack was the router's 1,500 ms call deadline, and that `wait_ms`
was the topic step's share of that ack. Superseded by DND-1454 (gen_saas PR
#644, ADR 21): the webhook writes a route request and acks, and the route
worker reads the context and judges after the ack, under a 5,000 ms deadline.
So `wait_ms` now measures the worker's topic step, and the 1,000 ms target no
longer guards an ack. Why: the owner asked why Jev was on the ack path at all
(Cody, 2026-10-01).

**An eval apply re-checks an existing `on`** (DND-1380). Applying a run
(*Eval runs*) is the one other mode write, and it only lowers a mode. In the
apply's transaction, after the new threshold rows are written, it reads the
run owner's mode for that use case. Thresholds never gate `on`, so a run
that disables or drops a label leaves it `on`. Only an `on` whose use case
has no registered question set drops to `off`. The apply's answer names the
change in `mode_change` (`nil` when none), and a warning is logged. A
downgrade that fails to write rolls the whole apply back. Both writers take
one transaction-scoped advisory lock per (owner, use case) before they read,
so they never interleave.

**Later (2026-10-01, DND-1450):** `on` was refused unless the owner's
thresholds for (use case, question-set version, pinned model) held an
ENABLED, eval-produced row for an **advisory label** (finding triage
`duplicate` or `related`; every ticket classification option; ticket
blocking `blocks`; priority scoring's levels above the lowest; Slack
routing's routable labels), so a use case went off, then `shadow`, then an
eval and its thresholds, then `on`. Replaced by *Activation* and the refusal
rule above: only a registered question set is needed. The consequence the
owner accepted: an uncalibrated answer now acts wherever its label is
accepted, including a non-advisory one. Ticket blocking's `does_not_block`
with no threshold removes a filer's non-security `Blocks` claim (a security
claim is kept by `policy_guard`). Why: the owner's
decisions, Cody, coordinator terminal turn, 2026-10-01, session `0cc59a5e-6c65-495e-a216-83c6a0bf2d56`: ~04:40Z "No, please don't do
that. Just enable jev. If we find issues, surface them and we can address
them."; ~05:10Z "Waive the threshold for jev - at worst, the sessions can
reroute to the correct session if needed. I don't want a "shadow period";
I want us to get it done."; ~05:20Z "OK, I don't want shadow phases.
Please stop shadow phases in the lifecycle. Please just start using jev,
and if accuracy is noted to be a problem then we'll address it."

**Later (2026-10-01, DND-1450):** Slack routing's `on` was refused until
that latency was measured (`latency_unmeasured`) and its p95 `wait_ms` was
at most 1,000 ms (`latency_too_high`). Replaced by the advisory reading
above. Why: the same owner decisions. The call's deadline and the fallback
to the channel route are the safety net until an asynchronous router lands.

**Later (2026-10-01, DND-1450):** an apply moved an `on` whose thresholds no
longer held an enabled advisory label to `shadow`. Replaced by the recheck
above. Why: thresholds no longer gate `on`, so that downgrade would undo the
owner's `on` at the next eval apply.

**Later (2026-10-01, DND-1380):** this said `set_mode/3` is the owner's only
mode writer. Replaced by the text above (gen_saas PR #624:
`ModePolicy.recheck/3`, `Evals.apply_thresholds/3`,
`SettingsStore.lock_mode/2`). Why: `on` was judged only when set. A later
apply that disabled its advisory label left the mode `on` with no enabled
label behind it, a state `set_mode` refuses.

**Later (2026-09-28):** this read "`on` is refused unless a threshold row
exists for (owner, use case, question-set version, pinned model) that an eval
run produced", and named no refusal for `shadow`. Replaced by the text above
(DND-714). Why: a row existing is not calibration. An all-n/a run writes rows,
and an enabled `unrelated` row enables nothing a caller acts on, so either
would have turned a use case on with no advice it could give.

**Later (2026-09-28):** this said Slack routing refuses `on` while the p95
over its "shadow-mode" rows exceeds 1,000 ms, and that until the measurement
was built its `on` was refused outright. Replaced by the text above (DND-717,
gen_saas `ModePolicy.permit/5` and `CallStore.latency/3`, stacked on the
DND-714 mode writer). Why: the rows record no mode, so the bar reads every
call that reached the port; and a p95 over too few calls or too short a
window is not a measurement, so it is refused as `latency_unmeasured`, never
passed. The 20 calls and 3 days are DND-717's shadow bar ("at least 3 days,
or at least 20 new owner conversations, whichever is later").

**Later (2026-09-30, DND-1334):** this said the Slack routing `on` bar is a p95
`latency_ms` over all of the owner's `slack_routing` rows that reached the
port, whatever their question-set version (gen_saas `CallStore.latency/3`).
Replaced by the text above: a p95 `wait_ms` over the registered version's
rows only (DND-1334, gen_saas PR #594, `CallStore.latency/4`). Why: DND-1048's
`slack-routing-v2` sends the conversation context, so v1 calls say nothing
about v2's latency; and the router waits on its context reads as well as the
call, inside Slack's 3 s ack, so the call alone understated the wait. The
1,000 ms bar, the 20 calls and the 3 days are unchanged.

## Threshold provenance, n/a and the pinned model

**The pinned model is `jev-1.13.0`.** Requests name the versioned id, never an
alias such as `jev-latest`, because an alias moves when TypeSafe ships a release.
A response whose `model` differs is `model_mismatch` and falls back. A model
upgrade is a deliberate re-eval and a change to this section, never a drift.

**Thresholds are keyed by (owner, use case, question-set version, model,
label).** A change to a question set's criteria text is a new version, and it
invalidates the old thresholds.

**Every threshold carries its provenance**: the eval run that produced it
(`eval_run_id`, owned by the same owner), the Wilson 95% lower bound on
precision, the coverage and the case count. A threshold without an eval run
cannot be written.

**How a threshold is chosen.** For each label, the eval tries thresholds 0.00,
0.05, …, 0.95. The chosen threshold is the smallest whose Wilson 95% lower bound
on precision is at least 0.90, with at least 10 routed cases. The bound is the
binding rule: even with every case correct, it reaches 0.90 only at 35 routed
cases, so a label needs at least that many before it can be enabled.

**n/a.** A label with no qualifying threshold is **`n/a`**: its row is
written disabled. `n/a` is not 0 and not a failure.

**What `on` accepts** (gen_saas `Athena.Judgments.Decision`):

- an answer named `unclear` falls back as `below_threshold`, whatever its row;
- a label with an ENABLED row is accepted at or over its threshold, and
  otherwise falls back as `below_threshold`;
- a label with no row, or a disabled (`n/a`) one, is accepted on the model's
  answer, whatever its confidence;
- a malformed row is our bug: `threshold_unset`, never accepted.

Every accepted decision records its **basis**, `threshold_met` or
`no_threshold`, where the caller stores the decision: the Slack router's
outcome record (`basis=`), the `reason` of a `jev` decision in a ticket
provenance line (`no_threshold`; null when a threshold was met), finding
triage's per-candidate `basis`, and `priority_items.judged_basis`. Every
call's answers and probabilities stay on its `judgment_calls` row, in every
mode. That makes accuracy measurable by provenance; *Receiver feedback*
reads it. The verdict does not
depend on the mode: `shadow` records what `on` would have done.

**Later (2026-10-01, DND-1450):** this said an `n/a` label falls back
(`label_disabled`) and a label with no row reads `threshold_unset`, and that
neither ever accepts. Replaced by *What `on` accepts* above. Why: the owner's
threshold waiver, quoted in *Modes*.

**Unscored is not wrong.** An eval case that fell back (a service error, a
missing key) is excluded from precision and counted as `unscored`, by reason. A
run where every case fell back reports `scored: 0`, never a precision of 0.

**Eval runs** (DND-710: gen_saas `Athena.Judgments.Evals`, harness
`ai/bin/judgment-eval`).

- **The same path as the product.** Each labelled case runs through the
  product use case's question set and the same judge path, recorded under
  `eval:<use_case>`. A question set is evaluable only if it names which answer
  is the label (its eval reading). A use case whose question set has not
  shipped is refused as such, never read as an empty run.
- **The owner is the machine token's**, never the body's. An eval run belongs
  to one owner; another owner's run id reads exactly as an absent one. The
  one run a token does not start is priority scoring's owner-action run
  (below): an operator starts it by rpc for one owner, and it reads only
  that owner's index. Its thresholds are applied like any other run's.

  **Later (2026-09-28):** this said only that the owner is the machine
  token's. Replaced by the text above (DND-719). Why: owner-action labels are
  read from the index on the server, so no request body carries them, and
  an operator starts that run in system context.
- **What a run stores**: the caller's opaque case id, the owner's label, and
  the chosen label with its confidence, or the unscored reason. Never the
  input.
- **The curve.** For label L at threshold t, the routed cases are those the
  judgment labelled L with confidence at least t. Precision is correct over
  routed; coverage is correct over the scored cases the owner labelled L (the
  recall half of the PR curve). No routed case means no precision and no
  bound, never 0.
- **The server computes the thresholds** from the stored run; a caller cannot
  supply one. Applying a run replaces every threshold row for its (owner, use
  case, question-set version, model), each stamped with the run. An n/a label
  is written disabled, so an earlier run's enabled label cannot survive. A run
  that scored nothing cannot be applied, and an applied run takes no more
  cases. The apply then re-checks the owner's `on` (*Modes*).
- **Proposed labels** (confirmed by no owner, record or rule) never enter a
  run, so they never select a threshold. A label whose id the corpus lacks is
  reported by count and id. A run's provenances are `forward_record`,
  `owner_confirmed`, `tracker_record`, `rule_confirmed`, `title_prefix` and
  `owner_action`; each names what confirmed it. Only `owner_confirmed` (the
  owner confirmed the label) and `owner_action` (the owner acted on the
  item) come from the owner.

  **Later (2026-09-28, DND-1055):** the list above ended at `rule_confirmed`.
  Ticket classification adds `title_prefix` (*Ticket classification labels*
  below); the rule that `proposed` never enters is unchanged.

  **Later (2026-09-28):** this ended "only `owner_confirmed` means the owner
  did". Replaced by the text above (DND-719). Why: priority scoring's labels
  are `owner_action`, read from what the owner did on the index, which is the
  owner's own evidence without a confirmation step.

  **Later (2026-09-28):** this read "Proposed labels (not yet confirmed by the
  owner)", which read as if only the owner's confirmation lets a label into a
  run. Replaced by the text above (DND-714). Why: `forward_record` already
  entered runs unconfirmed by the owner, and finding triage adds
  `tracker_record` and `rule_confirmed`; the rule that `proposed` never
  enters is unchanged.
- **Slack routing labels** (DND-715, `ai/bin/judgment-label`) cover the
  owner's new-conversation roots only (D7), one row per `event_id`, in the
  machine-local `slack-routing-labels.jsonl`. The corpus is the root
  snapshot, `<inbox root>/evals/slack-routing-roots.jsonl` (DND-1448):
  append-only, one line per owner root the first time `--propose` sees it,
  with the root's own fields and text and the context `judgment-eval` would
  build for it then (anyone else's text emptied, D7), marked
  `window_complete` when every inbox file reached back over the window. The
  inbox is a channel's live file and its rotated generation (`<file>.1`,
  `athena-inbox.md` → *Retention*), read together as one stream, oldest
  first (DND-1497). `judgment-label` reads its roots from
  `walt_ui-slack.jsonl.1` and `walt_ui-slack.jsonl` itself (a bad line
  stops it); both tools read context and coverage through one reader,
  `ai/lib/slack_inbox_files.rb`. The labels are built over the
  snapshot's roots and the inbox's, so a root that rotated out of
  `walt_ui-slack.jsonl` keeps its row, and a root still in
  `walt_ui-slack.jsonl.1` is snapshotted until the next rotation deletes
  the generation. "Reached back" is judged per stream: its earliest line is
  at or before the window's start, or the stream never rotated, so it lost
  nothing however late it began. Never rotated means no `.1` and a
  `rotated_at` in its state file within the 14-day sweep (`athena-inbox.md`
  → *Lifetimes*: every rotation leaves a `.1` until the next rotation or that
  sweep). A missing or unreadable `rotated_at` is "could not tell", so the
  earliest-line rule applies. The residual reads as never rotated when it
  did: a `.1` deleted by hand, a state file recreated or its `rotated_at`
  reset after a sweep, or a stream that held the channel and has vanished. A label whose root is in no corpus row is `n/a`, never
  scored: `judgment-eval` names it with how many such labels are
  `owner_confirmed`, and its `Fix:` says how a root reaches the snapshot.
  Forward
  records rotate too, so what a row recorded is one more vote beside the
  current records: a `forward_record` label with no current record is kept,
  a recorded conflict stays a conflict, and a current record that disagrees
  with a recorded label makes a conflict. An absent snapshot while label
  rows would be dropped is refused, exit 1, unless `--new-snapshot` starts
  one. `judgment-eval` adds a snapshot row's context lines to the inbox's,
  and prints and records in the run file how many cases carry one. A
  snapshot row whose `window_complete` is not `true` (a file holding the
  root's channel began after the window opened, or the flag is absent or
  malformed) is not a measurement: `judgment-eval` leaves it out of the run,
  `n/a`, never scored as a hit or a miss, and names it
  (`window-incomplete excluded: N (n/a, ...): <ids>`, and
  `window_incomplete_excluded` in the run file). A run in which every case
  is window-incomplete sends nothing and exits 3. A live-inbox row (no
  snapshot) is unchanged. The labels file still holds no text. The owner's
  answer at a terminal (`--confirm`, one message at a time) is
  `owner_confirmed` and always wins. Otherwise a root whose text addresses a
  session is `rule_confirmed` with `"rule": "session_mention"`, by the
  router's own grammar (`ai/contracts/athena-events.md` → *New conversations
  may route by an advisory topic judgment*, rule 2; a forward record that
  agrees stays `forward_record`, one that disagrees is overridden and
  counted). A root that an R4 forward record names is `forward_record`. With
  `--propose --rule-default`, a root nothing else labels is `walt_ui`,
  `rule_confirmed` with `"rule": "default_walt_ui"` (the owner's rule 3);
  without it that root stays `proposed`. `--confirm` presents the
  `default_walt_ui` rows with the `proposed` ones, and the owner's answer
  replaces them; it never presents a `session_mention` row, which no run
  scores. An agent never writes `owner_confirmed`. A session-addressed
  root is routed by the rule and never judged, so `judgment-eval` leaves it
  out of a `slack_routing` run, whatever its provenance, and counts it
  (`session-mention excluded: N`): its label records the router's rule, not
  ground truth for the judge. An eval case carries the context the
  server's `POST /api/v1/judgments/slack_routing/context` builds (DND-1048),
  which runs the router's own selection over the local inbox lines (anyone
  but the owner with the text emptied) and the app's claims. The rule is the
  router's; the data is this machine's inbox, which can differ from the
  server's `slack_events`. A root received before HG-22 carries the legacy
  kind `dm` (`athena-inbox.md` → *Channel kind: `log`*), which the endpoint
  and the state refuse. `judgment-eval` maps it before it sends, in one place
  (`JudgmentEval.contract_kind`): a `dm` in a `D` channel is `im`, any other
  `dm` is `mpim` (DND-1567). `judgment-eval` refuses a reply whose question-set
  version, rules or owner id differ from its own, so a mismatch fails loudly
  instead of starving the context. Its owner id is the private overlay's
  `slack .people.owner.user_id` (`athena-private-overlay.md`); one that does
  not resolve, or that matches none of the labelled roots, stops the run
  before anything is sent, never reading as "no root is the owner's". A case
  whose context cannot be built is
  unscored `context_unavailable` and is never sent with an empty context.

  **Later (2026-10-01, DND-1448):** this read "The corpus is
  `walt_ui-slack.jsonl` itself, so the text is never copied." Superseded by
  the root snapshot above. The inbox rotates, and `--propose` dropped every
  non-owner-confirmed row whose root had left it, so the corpus could never
  reach the bar's n.

  **Later (2026-10-01, DND-1483):** this read "Those cases are scored on the
  context known", of the snapshot cases whose window the inbox did not reach
  back over. Superseded by the exclusion above. A case judged on partial
  context reads as a router miss when the context is what was missing, so
  recall and precision mixed partial-context cases with complete ones.

  **Later (2026-10-01, DND-1497):** this read "built over the snapshot's
  roots and the live inbox's", and the inbox reader read `*-slack.jsonl`
  only. Superseded by the stream above. The owner confirmed ten roots on
  2026-09-28; the inbox rotated on 09-29 and moved them to
  `walt_ui-slack.jsonl.1`; the snapshot started on 10-01 from the live file,
  so none of the ten joined and the eval scored nothing.

  **Later (2026-09-28):** this said "the owner confirms the rest one message
  at a time at a terminal": every root without a forward record waited for
  the owner. Replaced by the text above (DND-717, epic decision D-R2): the
  owner's routing rule of 2026-09-28 ~04:25Z ("if I'm replying to a message,
  the session that sent it is the intended recipient. If I specify a session,
  then great. Most messages from slack will be for walt_ui") is applied
  mechanically under `rule_confirmed`, so the eval does not wait on a confirm
  batch. The Wilson bar is unchanged. Rule 1 labels no root: a root is not a
  reply.
- **The owner confirms with the conversation context** (DND-1047). Before
  each message, `judgment-label --confirm` shows the context window that
  the routing judge uses (slack-routing-v2): the same channel's top-level
  messages from the hour before, at most 6, each marked with what that judge
  will see of it (the owner's text, Athena's post as a session label, or
  nothing, D7). The builder is `ai/lib/judgment_context.rb`. The judge's
  selection (gen_saas `Athena.SlackEvents.RoutingContext`, DND-1048) applies
  the same rule: the six most recent top-level messages from any sender, then
  only the owner's text and Athena's session labels. `judgment-eval` takes its
  window from this builder's constants and refuses a server whose context
  rules differ, so the window, the cap and the text cap cannot drift apart
  silently. That check compares those three numbers only: the selection
  logic itself (counting every sender toward the six, what is top-level) is
  two hand-kept copies, Ruby and Elixir, and nothing pins them together. It
  reads Slack as
  Athena's bot, for that terminal only; nothing egresses. A row
  records `"context": "shown"` or `"unavailable"`; an `owner_confirmed` row
  without `"shown"` is re-presented by `--confirm --recheck`, and its answer
  stays in force until then. judgment-eval reads only `id`, `label` and
  `provenance`, so the mark never changes a run.

  **Later (2026-09-28):** this bullet said DND-1048 "uses that builder, or a
  parity check pins the two windows together". Replaced by the rule above
  (DND-1048): the judge is gen_saas Elixir, so it cannot call this Ruby
  builder; the pin is judgment-eval's check of the server's `rules` against
  this builder's constants, which covers the three numbers and not the
  selection logic.
- **Finding triage labels** (DND-714, `ai/bin/triage-corpus`) come from the
  DND tracker's own history, in the machine-local
  `finding-triage-labels.jsonl` (ids only) and `finding-triage-corpus.jsonl`
  (the inputs sent, redacted of ticket refs and of lines naming a duplicate).
  A pair is kept only when both tickets are in one known project (an epic's
  DND Projects row, or, with no mapped epic, Area Harness for the harness
  project), and its content domain comes from that project, never guessed
  (E12). Provenance:
  `tracker_record` for a `duplicate` (the body names it) or a `related` (a
  Depends On or Blocks link, or a body citation); `rule_confirmed` for an
  `unrelated` pair that the mechanical rule `different_area_unlinked`
  confirms (different Areas, no link, no citation). `rule_confirmed` is never
  `owner_confirmed`. Every other sampled pair stays `proposed`. Severity labels
  are weak (an agent assigned them) and are not evaluated.
- **Ticket classification labels** (DND-1055, `ai/bin/ticket-corpus`) come
  from the same tracker snapshot (`triage-corpus --fetch`, which reads through
  the read-only `ai/lib/notion_read.rb`), one case per ticket per use case, in the machine-local
  `ticket-{kind,severity,security}-{labels,corpus}.jsonl`. Labels use the
  tracker's spelling (`Bug`, `MEDIUM`; Security reads `security` for
  `introduced` or `pre-existing` and `none` for `none`; an unset or other
  value is excluded, never read as `none`). Every row is weak (an agent filer
  set it, `"weak": true`) and never `owner_confirmed`:
  - `tracker_record`: the property, on a ticket created at or after
    2026-09-27T22:00Z (filed under the W2 rules). Earlier values are the W4
    backfill and are excluded as `before_cutoff`.
  - `title_prefix`: Severity from a title that starts `CRITICAL`, `HIGH`,
    `MEDIUM` or `LOW`, at any date; a post-cutoff property wins.
  - Excluded and counted by reason: `feature` (Kind and Severity; Feature is
    authored), `property_unset`, `unknown_value`, `unknown_project` (never
    guessed), `body_unread`, `blank_title`, `jev_decided` (a ticket whose
    provenance line says Jev set that property is excluded for that use
    case, a title prefix included), `provenance_unparseable`, and
    `provenance_unread` (a truncated body: its last provenance line may lie
    past the page read; the shadow report skips it the same way). A snapshot whose rows lack a Kind, Severity or Security
    select (a renamed property) is refused, never read as unset.
  - The input sent is the title without its severity prefix, and the title
    and body without the `Jev classification:` line or any classification
    statement ("Kind Bug", "Severity: HIGH", "a HIGH severity", "Bug
    MEDIUM"), so a case is judged on content, not on a label leak.
  - `ticket_blocking` (DND-1057) is one case per (finding, candidate) pair,
    in `ticket-blocking-{labels,corpus}.jsonl`, from post-cutoff findings
    (any Kind but `Feature`), all `tracker_record` and weak. `blocks`: a
    finding with `Path` = `Blocking` and a `Blocks` edge onto a `Critical`
    ticket, one pair per such edge. `does_not_block`: a finding with `Path`
    = `Off` whose Found while ticket's epic has open `Critical` tickets, one
    pair per ticket, at most 3 by ID. The candidate is sent as the script
    sends it (title, first 800 characters of its body); the finding drops its
    `Jev` lines, its Path statements, refs and stated edges. Excluded by
    reason as above, plus `authored_path` (`Critical`, `Promoted`),
    `path_unset`, `relations_truncated`, `blocking_without_critical_edge`,
    `no_found_while`, `no_open_critical` and `candidate_unread`. A snapshot
    fetched before DND-1057 (no Path) is refused, never read as unset. The
    candidates are today's open tickets, not those open at filing: the
    corpus is an approximation, and that is why its rows are weak. Two
    known skews: a `blocks` pair may name a `Critical` ticket of another
    epic, or one closed since, which the live script would not offer; and
    the negatives are the lowest (oldest) ids.

  `ticket-corpus --shadow-report --since` measures judgments against
  DND-1055's accuracy bar (Product Requirements R1055-3: at least 3 days, at
  least 35 accepted judgments, and a Wilson 95% lower bound of at least 0.90
  on their agreement; short of it at 14 days reads insufficient evidence).
  It is a measurement, never a gate on `on`. It reads ticket bodies alone: each ticket's LAST provenance line, every ACCEPTED judgment
  made in mode `shadow` compared with the value the ticket ended up with.
  A judgment in mode `on` is excluded (`mode_on`: the value may be Jev's
  own), as are a Feature's Kind and Severity (`feature`) and an unset value
  (`current_unset`). Nothing accepted reads n/a, never 0.
  `ticket_blocking`'s section reads each finding's last `Jev path:` line:
  a shadow line whose `would` has source `jev` is an accepted judgment,
  agreeing when the ticket's current `Path` (and, for `Blocking`, its
  `Blocks` edge) matches. The bar is the same. It counts only judgments made
  in mode `shadow`, so a use case that goes straight to `on` reads n/a here.

  **Later (2026-10-01):** the report above was the gate a ticket use case
  passed before `on` ("a use case short of it at 14 days stays shadow").
  Superseded by owner decision (Cody, 2026-10-01: "I don't want shadow
  phases … Please just start using jev"): no use case waits in shadow, and
  accuracy after `on` is the wrong-rate from *Receiver feedback*. The report
  still runs over shadow lines already written; it gates nothing.
- **Priority scoring labels come from the owner's actions** (DND-719, gen_saas
  `Athena.Priorities.OwnerActionEvaluation`). Provenance `owner_action`: what
  the owner did on the priority index, as the index records it now. An active
  item's `pin_top`, `pin_bottom` or `score` override, and a `dismissed` item,
  are actions; an active item with no override is `unmarked`. The index keeps
  no action history, so a promotion and a completion are not labels. The
  server reads these from the owner's own index and builds the run itself; a
  request body carrying an owner-action label is refused, so the label cannot
  be supplied by a caller. One case is one (item, dimension).
  - **`unmarked` is inferred, not confirmed.** The owner never said an
    unmarked item belongs below a pin; it is the list the pin was placed
    against. It is still a record, read from what the index holds, not a
    `proposed` label. It is the weakest side of any pair, and it enters only
    as a pin's or a dismissal's partner.
  - **Pairs.** "The owner put A above B": `pin_top` above a score override,
    `pin_bottom` and `dismissed`; a score override above the overrides with
    the next lower value (not every lower one) and above `pin_bottom` and
    `dismissed`; each pin or dismissal against up to five `unmarked` items.
    Other combinations say nothing about order and are not pairs.
  - **Pairs share items, so every item's pairs are capped, on both sides.**
    A pair reuses both sides' judgments, so the pairs are not independent. To
    bound that, among the acted items each item is the upper side of at most
    five pairs and the lower side of at most five; each pin or dismissal
    takes at most five unmarked partners, and each unmarked item serves at
    most five. Counterparts are picked by a fixed rotation that skips one
    already used five times. The Wilson bound below is computed over pairs
    anyway: the cap limits how far one judgment can be counted, and it does
    not make the pairs independent. A dimension clears the bar only with at
    least 35 decisive pairs; the gen_saas readiness check counts the pairs an
    index implies before any call.
  - **The curve is pairwise, per dimension.** At threshold t an item's delta
    is its judged level when accepted at t, else 0, as the product ranks it.
    A pair is correct when the deltas order it as the owner did, wrong when
    they reverse it, and decides nothing on a tie; ties are counted and
    excluded. For a pairwise curve, `n` is the decisive pairs, precision is
    correct over decisive, and coverage is correct over the scored pairs.
    The chosen threshold follows *How a threshold is chosen* with decisive
    pairs in place of routed cases. A pair with an unscored side is
    excluded, never scored as wrong.
  - **Rows.** A dimension's result is written to each of its level labels,
    because the product accepts a level by its label's row: one threshold per
    dimension, with no per-level precision. A dimension with too few pairs is
    `n/a` on every level label, its row carrying the point with the most
    decisive pairs. A run holds owner-action labels or level labels, never
    both, and a mixed run cannot be applied.
  - **Paced.** Eval calls count toward the local rate limit (*Budget*), so
    the run pauses a minute between batches of at most 50 cases.
- **n/a reads "insufficient evidence"** in `judgment-eval`'s run and apply
  lines: the label's row is written disabled. In `on` its answer is still
  accepted, uncalibrated (*What `on` accepts*).

  **Later (2026-10-01, DND-1450):** "the label stays disabled" meant the
  label never accepts. Replaced by the text above. Why: the owner's
  threshold waiver, quoted in *Modes*.
- **One case, one label.** A question set's eval reading names exactly one
  answer as the label, so a set that asks several questions defines its eval
  case unit. `finding_triage` (DND-713): one case is ONE (finding, candidate)
  pair, an input with exactly one candidate, labelled with that candidate's
  relation (`duplicate`, `related` or `unrelated`). A case with no candidate
  or several is unscored `malformed_answer`, never scored. Its severity Score
  is not evaluated, so severity has no threshold and is only ever shown as an
  uncalibrated suggestion. `ticket_blocking` (DND-1057) is the same shape:
  one case is ONE (finding, candidate) pair, labelled `blocks` or
  `does_not_block`; a case with any other candidate count is never scored.

## Receiver feedback

**The rule (owner, Cody, 2026-10-01 ~05:20Z):** "Each thing that we use jev to
judge on, we should include a way for the receiver to say the judgement was
wrong. Those should be recorded (along with the event that was judged
incorrectly) so the shipwright cron can evaluate how to improve the payloads
being sent to jev so we get better results. The feedback loop is critical."
Same turn: "I don't want shadow phases. … Please just start using jev, and if
accuracy is noted to be a problem then we'll address it."

So receiver feedback is how judgment accuracy is measured and improved, in
place of a shadow phase or an eval gate before `on`. The design record is
gen_saas ADR 22 (`adrs/22-judgments-carry-a-receiver-wrong-signal.md`). The
build tickets are DND-1461 to DND-1470 on the Jev epic. **Until each ships,
its signal does not exist;** this section states the target, and each bullet
names the ticket that makes it true.

This replaces measuring accuracy before activation. The shadow report's
supersession is labelled where that report is defined (*Threshold provenance,
n/a and the pinned model* → *Ticket classification labels*); the amendments to
*Modes* and to the eval-threshold rule are DND-1450's.

**Every product use case has a receiver, and the receiver can say "wrong".** A
use case without one is not admissible. Each receiver has one explicit, cheap
action, and where it already corrects a judgment in its own work, that act
records the feedback too.

| Use case | Receiver | Already happens (implicit) | Explicit | Ticket |
| --- | --- | --- | --- | --- |
| `slack_routing` | the session whose Slack inbox got the new conversation | it forwards the conversation with `session_send` and `reroute_of_event_id`: signal `reroute`, correction the destination's label | the `judgment_feedback` MCP tool, or `judgment-feedback record --use-case slack_routing --subject <event_id>`; the owner saying "wrong session" in the thread is recorded this way by that session | DND-1467 |
| `priority_scoring` | the owner, on `/priorities` | the owner pins, scores or dismisses an item whose judged level was accepted: signal `owner_override`, **weak** | a "Jev was wrong" control on the item's row, with optional right levels | DND-1465 |
| `finding_triage` | the filer, and the epic-clustering C3 merge | the filer files anyway after a `duplicate` advisory, or C3 merges a pair Jev did not judge `duplicate` (advised `related`, or not advised while `duplicate` was uncalibrated; under an enabled threshold it is counted `ambiguous`, never recorded): signal `filed_despite_advice` | `judgment-feedback record --call <id>` with the call id the advisory prints | DND-1468 |
| `ticket_kind`, `ticket_severity`, `ticket_security` | the filer, and anyone who later edits the property | a property whose last `Jev classification:` line says source `jev` is edited away from that value: signal `field_changed`, found by `judgment-feedback scan-tickets` | `judgment-feedback record --call <id>`, with the id from the line's `calls` | DND-1469 |
| `ticket_blocking` | the filer, and anyone who later changes the finding's Path or `Blocks` edge | Path or the edge changed away from a `jev`-sourced `Jev path:` line: signal `field_changed`, a `cand_<i>` correction per candidate the change contradicts (from the line's `candidate_refs`), found by `judgment-feedback scan-tickets`; a later `Critical` or `Promoted` is authored and never recorded | `judgment-feedback record --call <id>`, with the line's `call` | DND-1470 |

Every receiver may also use the owner's recent-judgments view behind the
judgments tile (DND-1464), signal `explicit`, reporter `owner_ui`.

**A feedback row records** (DND-1461): the call id; the call's use case,
question-set version, model, content domain, `subject_ref`, answers (what Jev
said, with its probabilities) and time; the signal and its strength; the
correction (question name to the right label, when known); the reporter
(`machine:<id>`, `owner_ui` or `system:<writer>`, derived, never supplied);
an optional session label; an optional note (at most 500 characters); the
payload copy; and when it was reported. One row per (call, reporter): a second
report from the same reporter replaces the first.

**Signals and strength.** `explicit`, `reroute`, `field_changed` and
`filed_despite_advice` are **strong**. `owner_override` is **weak**: an owner
pins an item for reasons other than its urgency. A weak signal is recorded and
read, and never counts toward the headline wrong-rate.

**The call is named, never guessed.** Every surface that shows a judged result
also returns its `call_id`: the REST answers, the provenance lines (`calls` on
`Jev classification:`, `call` on `Jev path:`), the advisory output and the
priority item. A Slack receiver names the call by `("slack_routing",
event_id)`, the event id the routed line carries; the latest answered call for
that subject is used. Those are the only two keys. A reference carrying
neither, or a `subject_ref` with any other use case, is refused as `invalid`
with a `Fix:`, never a crash: a crash report would print the receiver's note.
A reference that resolves to no call of the caller's owner is `not_found`,
the same answer for an absent, pruned or other owner's call. A ticket filed before its line carried a call id is counted as
`unlinked` by the scan and named, never matched by title.

**What can be reported.** Only an `answered` product call. A fallback is
refused as `not_judged` (the receiver saw today's behaviour, not Jev's) and an
eval call as `eval_call`, each with a `Fix:`. A correction's labels must be
options of the stored request's questions. When the payload is pruned, a label
must still be an opaque identifier.

**The payload, retention and egress** (*Egress and data flow* → *What is
stored*). `judge/4` keeps each answered product call's request for 30 days;
feedback copies it and keeps it for 90. The text is what TypeSafe already
received. It is returned only by the owner-scoped read below, to the owner's
own authenticated machines. The harness never quotes payload text or a note in
a commit, ticket, PR or journal: it cites feedback ids, and an implementer reads
the payload through the same read.

**Access control.** The owner is the authenticated machine's owner (REST,
MCP) or the signed-in owner (UI), never a body field. A body naming `owner_id`,
`machine_id` or `reporter` is refused with `Fix:`. Every read and write is
scoped to that owner. Surfaces (DND-1462): `POST /api/v1/judgments/feedback`
and `GET /api/v1/judgments/feedback?after=<cursor>` behind the machine-token
pipeline, and the MCP tools `judgment_feedback` and `judgment_feedback_list`.
The harness client is `ai/bin/judgment-feedback` (DND-1466).

**Feedback is untrusted input, and it never acts.** A row changes no mode,
threshold, budget, route or ticket. Its note and payload are data, never
instructions (as inbox content: `ai/contracts/athena-inbox.md` → *Untrusted
input*). Nothing writes a feedback row to test a path in production: a made-up
report counts in the wrong-rate.

**The wrong-rate** (DND-1464), per (use case, question-set version): distinct
answered product calls with at least one strong feedback row, over answered
product calls, for the last 7 days and the last 30. Under 20 answered calls a
window reads **n/a**, never 0. The judgments tile shows it beside each use
case, with the weak count separately, and per version when two versions have
calls in 30 days. It flags a **rise** when the 7-day rate is at least 10
points above the rate over the 23 days before, with at least 20 answered calls
in each window and at least 3 strong reports in the 7 days.

**The unit of change is a new question-set version.** A change to what is
sent (criteria, options, context, caps) is a new version, as it already is
for thresholds. With no shadow phase, it ships `on` and is measured by its own
wrong-rate. Who proposes one: the shipwright's feedback pass
(`athena:judgment-feedback` → *The shipwright pass*). It files tickets and
changes no product code, mode or threshold.

## Finding triage: the harness script

The first product consumer (DND-713). The server is gen_saas
`Athena.Judgments.Triage` behind `POST /api/v1/judgments/finding_triage`; the
harness caller is
`ai/skills/athena:ticket-management/scripts/finding-triage`; the procedure is
athena:ticket-management → *Before filing a finding*.

- **Advisory only.** The script MUST NOT write to Notion or any tracker. Its
  Notion effect admits only reads (a data source query and a block-children
  list) and refuses any other request before sending it. It never closes,
  merges or cancels a ticket. The filer decides.
- **The owner is the machine token's**; another owner's token judges with that
  owner's key, or answers `not_configured`. Over REST, `finding_triage` is
  served at `POST /api/v1/judgments/finding_triage` and ticket classification
  at its own path (*Ticket classification: the harness script*); any other
  use case is `not_found`.

  **Later (2026-09-28):** this read "Only `finding_triage` is served over
  REST". Superseded by DND-991 (gen_saas PR #505), which serves ticket
  classification at `POST /api/v1/judgments/ticket_classification` for
  DND-1054's `ticket-classify` script. `finding_triage` is still the only use
  case the generic `:use_case` path serves.
- **The content domain is derived server-side from the project**, never taken
  from the caller: `athena` and `harness` are `blend`, `walt_ui` is `work`,
  `dnd`, `lms` and `admiral` are `personal`. An unknown project is judged with
  no domain, so it is refused and recorded as `domain_not_permitted`.
- **Candidates are retrieved in code**, not by the model: tickets in the same
  project, open or edited in the last 90 days, whose title contains a keyword
  of the finding's title, at most 20. The script prints how many it
  considered, including `0 candidates considered`, before any advice. A
  search that could not run is its own unavailable line, never 0 candidates.
- **An advisory line is printed only for an accepted candidate**: one judged
  `duplicate` or `related`, in mode `on`, that the server accepted
  (`above_threshold`, per *What `on` accepts*). One accepted with no
  threshold is marked `[uncalibrated]`; the response's per-candidate `basis`
  says which. In mode `on` the severity is printed as an uncalibrated
  suggestion. Shadow mode prints no advice at all, severity included.
- **An uncalibrated relation says so.** The judged response names each
  advisory relation's threshold state (`thresholds`: `enabled`, `n_a` or
  `unset`, DND-714). In mode `on`, a relation that is `n_a` or `unset` prints
  that it is uncalibrated and that the model's answer is advised. A state the
  server did not report prints "insufficient evidence" and is never advised
  or read as `enabled`, so its silence never reads as "no duplicate".

  **Later (2026-10-01, DND-1450):** an advisory line needed the owner's
  eval-produced threshold to accept the candidate, and a relation that was
  not `enabled` printed "insufficient evidence" and was never advised.
  Replaced by the two bullets above. Why: the owner's threshold waiver,
  quoted in *Modes*.
- **The advisory names its call** (DND-1468). The judged answer carries
  `call_id`, and the script prints `call: <uuid>` just before the advisory,
  or `call: unavailable` when the server named none, never omitting it. A
  `questions:` line names every candidate sent with its question
  (`cand_<i>`), and each advised line carries its own. That is what *Receiver
  feedback* records against. The reader for a pasted advisory is
  `lib/triage_advisory.rb`; athena:epic-clustering's `c3-feedback` uses it.
- **Setting the mode** follows *Modes*: `on` needs only the registered
  question set.
- **A server that answered and refused** (any 4xx, a rejected machine token
  included) prints its own line with the server's `Fix:`, distinct from a
  server that could not be reached. A 200 outside this shape is its own
  unreadable-answer line.
- **Unavailable is an answer, not an error.** The server answers 200 with
  `status` `unavailable` and a reason from *The closed reason list*
  (`not_configured` for `mode_off` and `key_missing`). The script then exits 3
  and prints one line naming why, ending with the same `Fix:` clause. While the
  feature is inert (every mode `off`, no key), every call prints exactly
  `JUDGMENTS UNAVAILABLE: not_configured. Fix: file the ticket as today; this is advisory.`
  An unreachable server and a failed candidate search print their own distinct
  lines (`COULD NOT REACH SERVER`, `CANDIDATES UNAVAILABLE`), so neither reads
  as not configured or as no duplicates.

## Ticket classification: the harness script

The second product consumer (DND-991, DND-1054). The server is gen_saas
`Athena.Judgments.TicketClassification` behind
`POST /api/v1/judgments/ticket_classification`; the harness caller is
`ai/skills/athena:ticket-management/scripts/ticket-classify`; the procedure is
athena:ticket-management → *Filing a ticket* (the Classify bullet).

- **The script writes nothing.** It writes to no tracker. Without `--epic`
  it reads no ticket either. With `--epic` it reads the epic's candidate
  tickets through the read-only `ai/lib/notion_read.rb`, which refuses any
  request but a data-source query and a page or block-children read. The
  filer sets the properties. It adds no policy of its own and prints what the
  server decided.

  **Later (2026-09-30, DND-1057):** this read "It has no tracker client: it
  reads no ticket and writes to no tracker." Superseded by the `--epic` path
  part below, which must read the candidates in code (Product Requirements
  R1057-3). It still writes nothing.
- **The filer's values are required.** The caller sends its own `Kind`,
  `Severity` and `Security` (tracker spelling; a `Feature` sends no Severity).
  Every fallback starts from them, so a fallback is always defined and is
  today's behaviour, except the Vulnerability floor below.
- **The owner is the machine token's**, never the body's: the closed body
  schema refuses any unlisted key, identity fields included.
- **The content domain is derived server-side from the project**, as for
  finding triage. An unknown project is judged with no domain, so each
  property falls back as `domain_not_permitted`.
- **The policy is the server's** (DND-991 → `TicketClassificationPolicy`).
  An accepted judgment may set Kind (never over a filer's `Feature` or
  `Vulnerability`), raise Security from `none`, and set Severity, but for a
  security-relevant ticket never below the filer's. A decided `Vulnerability`
  with Security `none` is lifted to `pre-existing` (the Vulnerability floor).
  The lift's source is `jev` when an accepted Kind judgment made the ticket a
  Vulnerability, `filer` with reason `policy_guard` when it overrides an
  accepted Security `none`, and otherwise `policy`.
- **The output is the server's decision**: one line per property with its
  source, then the server's provenance line verbatim, which the filer pastes
  into the ticket body. Since DND-1469 the line ends with `calls`, each
  property's answering call id or null (*Receiver feedback*); a line without
  it was filed before, and every reader accepts both. A source is `jev` (an
  accepted judgment set, raised or confirmed it), `filer`, or `policy` (the policy changed the filer's value
  with no judgment). A `filer` or `policy` value carries a reason: a reason
  from *The closed reason list*, or one of four that are not fallbacks
  (`shadow`, `policy_guard`, `vulnerability_floor`, `feature`). A `jev`
  value accepted with no threshold carries reason `no_threshold` (*What `on`
  accepts*); one that met a threshold carries none.

  **Later (2026-10-01, DND-1450):** only a `filer` or `policy` value carried
  a reason. Replaced by the sentence above. Why: the basis of every accepted
  decision is stored (the owner's threshold waiver, quoted in *Modes*). While the
  feature is inert (every mode `off`) the script exits 0 and each property is
  the filer's with reason `mode_off`, with three exceptions: a Feature's
  Severity is empty with reason `feature` (it is never asked); a
  Vulnerability filed with Security `none` is decided `pre-existing`, source
  `policy`, reason `vulnerability_floor`; and an unknown project reads
  `domain_not_permitted`, because the domain is checked before the mode.
- **A trailing provenance block is not sent** (DND-1590). The body sent is
  `Classify.sent_body` of the filed body: the run of `Source:` and
  `Context:` clauses that ends it is dropped. A clause ends at a line break
  or at a sentence end and a space (not the stop in "e.g." or "i.e."; a
  bracket or quote alone ends nothing), and every clause in the run starts
  with a label. Anything else is sent as filed: a label inside a clause, a
  block followed by any other clause, a label in another form (lower case,
  bold, a list item), and a body that is nothing but provenance. Where a finding was found is background, not its
  impact, so a filer states the defect's current impact in the body proper.
  `ticket-classify` and `ticket-reclassify` send through it, and
  `ticket-corpus` builds its eval cases with it, so an eval sends what the
  product sends. `ticket_blocking`'s body is unchanged. The redaction is the
  caller's, like `ticket-reclassify`'s dropped provenance lines, so it
  changes no question set and no version: `ticket-severity-v1` calls before
  and after it share one wrong-rate. Measured before it landed, on the
  committed fixtures in `ai/eval/judgment-fixtures/ticket-severity-provenance/`.
- **Unavailable is exit 3 with the filer's values.** Each cause prints its
  own first line: an unreachable server (`COULD NOT REACH SERVER`), a server
  that answered and refused (any 4xx, a 404 while the endpoint is not
  deployed; `SERVER REFUSED THE REQUEST`), a server that failed (a 5xx;
  `SERVER FAILED`), a 200 outside the judged shape
  (`UNREADABLE SERVER ANSWER`), and a fault in the script itself
  (`UNEXPECTED ERROR`). Every one ends with
  `Fix: file the ticket as today; this is advisory.` The filer's own values
  follow under `Decided (filer; classification unavailable):`. None prints a
  provenance line, so none reads as a decision. A per-property fallback
  inside a 200 is not unavailable: it is a decision with source `filer`.
- **The machine token never reaches argv or the environment**; it goes to curl
  on stdin, as for finding triage.
- **A finding's Path** (DND-1057). With `--epic <page id>` (and optionally
  `--found-while DND-N` and `--blocks DND-N`, the filer's claim), the script
  also decides `Path` through `POST /api/v1/judgments/ticket_blocking`, after
  the classification. Only its gate reads the classification (the filed
  Kind, below); its request and answer do not:
  - It reads the candidates first: the epic's open `Path` = `Critical`
    tickets (not Done, Cancelled or Won't Fix), by ID ascending, at most 10,
    and prints how many it considered, `0 candidates considered` included. A
    failed read is its own `CANDIDATES UNAVAILABLE` line, never 0. A
    `--blocks` that is not one of them is a usage error (exit 2) and nothing
    is sent.
  - A ticket filed as a `Feature` is never sent (its Path is authored). The
    Path part runs after the classification and keys on the Kind that is
    filed: the decided Kind, or the filer's own when the classification is
    unavailable. The policy never assigns `Feature`, and the script refuses
    an answer that does as unreadable, so the filer files its own Kind and
    the Path is judged for it. With no candidates, or for an introduced
    security issue with `--found-while`, the server decides by rule and
    makes no model call. `--epic` with `--ref` or `--json`, and
    `--found-while` or `--blocks` without `--epic`, are usage errors.

    **Later (2026-10-01, DND-1382):** this read "The Path part does not
    wait for the classification, so a Kind the server decides differently
    does not change this", and the bullet above said the Path part runs
    "independently of" the classification: the Path was gated on the
    filer's Kind alone.
    Superseded by the gate on the filed Kind above.
  - The output is `Path: <value> (<source>)`, then `Blocks: DND-N` or
    `Blocks: none`, then the server's second provenance line verbatim, which
    starts `Jev path: `. Since DND-1470 the line ends with `candidate_refs`
    (the candidates' refs, so `cand_<i>` is `candidate_refs[i]`) and `call`
    (the answering call id, or null), after every older key; a line without
    them was filed before, and every reader accepts both. The source is
    `jev` (an accepted judgment), `filer`
    (the claim stands) or `rule` (introduced security, no call). A `filer`
    or `rule` value carries a reason: one from *The closed reason list*, or
    one that is not a fallback (`shadow`, `policy_guard`,
    `introduced_security`, `no_candidates`, `no_blocks_judged`). A `jev`
    value accepted with no threshold carries reason `no_threshold`; one
    that met a threshold carries none.

    **Later (2026-10-01, DND-1450):** only a `filer` or `rule` value
    carried a reason. Replaced by the sentence above. Why: the basis of
    every accepted decision is stored (*What `on` accepts*). The script
    refuses, as an unreadable answer, a target outside the candidates, a
    `rule` answer for anything but an introduced security issue's Found while
    ticket, and a `jev` `Off` over a security finding's claim. It is a separate line, so the classification line
    DND-1354 and DND-1056 parse is unchanged. Its `would` object is the
    decision the policy would take in `on`, so a shadow report can measure
    it.
  - Unavailable is exit 3 for the path part alone: `PATH UNAVAILABLE: `
    followed by the same cause lines as above, or the `CANDIDATES
    UNAVAILABLE` line, each ending with the same clause, then the filer's claim under
    `Decided (filer; path unavailable):`. An introduced security issue with
    `--found-while` still reads `Blocking` onto that ticket in the fallback,
    since it is a rule, not a judgment. The exit is the higher of the two
    parts'.
- **The open backlog is reclassified the same way** (DND-1056):
  `scripts/ticket-reclassify plan` sends each open, non-Feature ticket's
  CURRENT values as the filer's and its id as `ticket.ref`, and records the
  server's decided values and provenance line verbatim. It reads Notion only
  (`ai/lib/notion_read.rb` refuses any other request) and writes no tracker;
  the agent applies only `Kind`, `Severity`, `Security` and the line. A ticket
  whose values differ from its last provenance line is locked: a hand edit
  wins. A line at the server's model and versions now, with no fault reason
  and every property `on` or the modes now, is not re-judged (the first
  ticket asked is, since its answer is what reports the model, versions and
  modes now). A fault answer is never recorded as a classification: an
  account-wide fault stops the plan, a per-call one skips the ticket as
  `unavailable`. `proof` re-reads every written ticket and fails on any
  difference, an unreadable page included. Procedure:
  athena:ticket-management → *Reclassifying the backlog*.
- **The lines are machine-written and checked, never retyped** (DND-1354).
  Filers pasted paraphrases of the `Jev classification:` line, which lose its
  `calls`, its judged labels and often its values. `ticket-classify
  --lines-out FILE` writes the `Jev` lines it printed to FILE, byte for byte
  (emptied, with a stderr line, when none was printed). After filing,
  `scripts/ticket-provenance-check --ref DND-N --lines-file FILE` reads the
  ticket (Notion reads only) and compares the body's LAST line of each prefix
  with FILE: exit 0 verbatim, 4 missing or not verbatim (its `Fix:` names the
  one paragraph to append), 3 unreadable, 2 usage. An empty FILE or an id that
  matches no ticket is usage, never a pass.
- **Every reader reads a known paraphrase, or counts it by reason**
  (DND-1354). `TicketCorpus.read_line` is the one parser
  (`ai/lib/ticket_corpus.rb`). A paraphrase that keeps all three values, one
  value each, and names no source but the filer is **recovered** (shapes
  `abbreviated_json`, JSON missing `accepted`/`judged`/`versions` with every
  mode off or absent and no call id; and `prose_values`, "Kind Bug, Severity
  LOW, Security none (filer: mode_off)" or "filer values Bug / LOW / none"): a
  filer value is never feedback and never an accepted judgment, so nothing a
  reader needs is lost. Every other broken line is **unparseable** with one
  reason: `malformed_json`, `lossy_paraphrase` (prose naming Jev, a judgment,
  `shadow`, a rule or a policy decision: its call and judged label are gone)
  or `unrecognized_prose`. A Feature's paraphrase has no Severity and is never
  recovered. `ticket-classify` exits 1 when `--lines-out` cannot be written;
  that file is never pasted or checked. `judgment-feedback scan-tickets`
  counts every line as `verbatim`, `recovered_<shape>` or
  `unparseable_<reason>` and names each ticket that is not verbatim;
  `ticket-corpus --shadow-report` names recovered lines by shape and
  unparseable ones by reason; `ticket-reclassify plan` lists
  `unparseable_provenance` by reason, reads a recovered line's values for the
  lock, re-judges it, and plans its verbatim line even when nothing is `on`
  (`healed_refs`), so applying the plan repairs the body.

## Budget

**D3 (owner, 2026-09-25, RESOLVED): a dollar cap.** Cody, verbatim: "Let's put a
$10 / month cap".

- **Monthly cap: $10 per calendar month (UTC), per owner, across all use
  cases.** It is enforced in dollars, computed from metered token usage at the
  configured price, not as a token count alone.
- **Daily pacing guard: $10 / days-in-month × 3** (about $0.97 in a 31-day
  month), so one day cannot spend the month. The day is the UTC day.
- **Per-use-case shares** of both caps: `slack_routing` 10%, `finding_triage`
  20%, `priority_scoring` 20%, `ticket_classification` 10%, `eval:*` 40%.
  `ticket_classification` is one share group for `ticket_kind`,
  `ticket_severity`, `ticket_security` and `ticket_blocking` together. A call
  must fit both its use case's share and the total.

  **Later (2026-09-30, DND-1057):** the group was the three classification
  use cases. `ticket_blocking` joins it with no new share: it is one call per
  finding filed with `--epic`, and the 10% is unchanged.

  **Later (2026-09-28):** this read `finding_triage` 30% and had no
  `ticket_classification` share. Superseded by DND-991 (decision J-991-5),
  which takes 10% from finding triage for ticket classification. The $10
  monthly total is unchanged. Measured basis: triage's eval run cost $0.039
  for 601 cases, and classification is about three calls of ~1.2k tokens per
  ticket.
- **The check runs before the call.** Spend so far in the window plus the
  request's estimated cost must not exceed the cap. Spend is the sum of the
  recorded costs in the window.
- **The price comes from config**, per model, per million input and output
  tokens (jev-1.13.0: $0.042 per million input tokens, output free, read
  2026-09-25). A missing or unknown price means **could not measure**: the call
  falls back as `price_unknown`, never as unlimited and never as $0. A recorded
  call with no cost in the window makes the window unmeasurable in the same way.
- **At a cap, every call falls back loudly** as `budget_exhausted`. The first
  `budget_exhausted` of a UTC calendar month sends **one** owner alert; later
  ones that month are recorded and logged, never re-alerted. It raises no
  health-transition alert (*Owner alerts: one rule per reason*). A budget
  refusal is not retried.
- **Local rate limit: 60 requests per minute per owner**, derived from the call
  records, not process state. Over it, the call falls back as
  `rate_limited_local`.

## Lifecycle

**The integration is work-owned.** The key is work-paid (D1). It ends when the
work Slack webhooks end. Personal-domain use (D2) rides the same key and ends
with it.

- **The key is held in `Athena.Secrets`** as `(owner_id, :typesafe_api_key)`,
  account-wide (`scope_ref` `""`). The owner enters it on `/secrets`, the
  write-only, owner-authenticated secret page (DND-1239). That is rule 1 of
  gen_saas ADR 18 (`adrs/18-owner-secrets-through-owner-pages.md`, #549,
  merged `cc9cfc7a`). That page stores for the logged-in owner's own account
  only and never returns or logs the value. No API route or MCP tool writes
  the key. No operator procedure may pass it over rpc (ADR 18 rule 3),
  because an rpc parameter stays in the SSM command history. That
  last rule is a procedure, not an enforced guarantee: an rpc evaluates
  arbitrary code, so it could still call `Athena.Secrets` directly.

  **Later (2026-09-30):** this bullet said the key "is stored out of band by
  the owner. No API or UI path writes it." Superseded by DND-1239 (gen_saas
  #553, `82916630`): the out-of-band store was an rpc over SSM, and the owner
  now enters the key on `/secrets` (`Athena.OwnerSecrets.store/2`;
  `Athena.Secrets.SecretType` classes `typesafe_api_key` as `:owner_entered`,
  scope `:account`).
- **Loss of access is a designed state.** A revoked key or a gone account falls
  back exactly like a missing key: loud, one health-transition alert, and no
  retry loop or crash loop.
- **Decommissioning is deleting the secret.** Every use case then falls back as
  `key_missing` and behaves as it did before judgments existed. Nothing else
  needs to change.

## Conformance checklist

- [ ] No judgment authorizes an action, widens access, or selects a destination
      outside a set the owner authorized (*Trust posture*).
- [ ] Only the fields in *Egress and data flow* are sent; `judgment_calls`
      stores no state text and refuses `state`, `text` and `body` keys.
- [ ] The content domain is recorded on every call; an absent or unknown domain
      is `domain_not_permitted`; `personal` is permitted (D2).
- [ ] The key is an argument to the port only, never logged or in an error term;
      the port never retries.
- [ ] Every non-accepted outcome does today's behaviour and leaves a record with
      a reason from the closed list and a telemetry event; a fault-class reason
      also logs a warning with `Fix:` and moves health; a state-class reason
      does neither; `key_missing` names the searched key.
- [ ] Every check before the call makes no call to TypeSafe; a latched
      `unauthorized` makes no call.
- [ ] Mode defaults to `off`; `on` and `shadow` need only a registered
      question set; no threshold, eval run or latency figure gates `on`, and
      no lifecycle step requires `shadow`.
- [ ] An eval apply never moves an `on` for what its thresholds disable; only
      an `on` with no registered question set drops to `off`, in the apply's
      transaction, under the (owner, use case) lock `set_mode` also takes,
      named in `mode_change`.
- [ ] In `on` an enabled threshold gates its label; no row or an `n/a` row
      accepts the model's answer and records basis `no_threshold`; a
      malformed row never accepts; unscored eval cases are never scored as
      wrong.
- [ ] A threshold is computed by the server from the owner's own stored eval
      run, never supplied by a caller; a run stores no input.
- [ ] Requests pin `jev-1.13.0`; a different answering model is `model_mismatch`.
- [ ] The monthly $10 and daily pacing caps are enforced in dollars from config
      prices; a missing price fails closed as `price_unknown`; one budget alert
      per UTC month.
- [ ] Each reason feeds exactly one alert rule: state reasons none,
      `budget_exhausted` the monthly budget alert only, every other fault a
      health-transition alert, once per transition, not per call; a change
      to `ok` recovers the last alerted fault, even across
      `budget_exhausted`.
- [ ] Deleting the secret returns every consumer to today's behaviour.
- [ ] Finding triage writes nothing to Notion, prints its candidate count even
      when 0, derives the content domain from the project server-side, and
      distinguishes not configured, an unreachable server and a failed
      candidate search.
- [ ] Ticket classification writes nothing to any tracker, requires the
      filer's values, prints the server's decision and provenance line, never
      lowers a security classification or replaces `Feature`, and on an
      unreachable server, a refusal, a server failure or an unreadable answer
      exits 3 with a distinct line and the filer's values.
- [ ] Ticket blocking chooses its candidates in code (open `Critical`, by ID,
      at most 10), prints their count even when 0 and a failed read as its
      own line, never sends a `Feature`, decides an introduced security
      issue by rule, never sets `Critical` or `Promoted`, never removes a
      security ticket's claim by judgment, and prints one edge at most.
- [ ] Reclassifying the backlog reads Notion only and writes no tracker,
      sends the current values as the filer's, skips a ticket whose values
      differ from its last provenance line as locked, never records a fault
      fallback as a classification, and its `proof` counts an unreadable page
      as a mismatch.
- [ ] A filed ticket's `Jev` lines come from `ticket-classify --lines-out`
      and are checked by `ticket-provenance-check`; every reader recovers a
      lossless paraphrase and counts every other broken line by reason,
      never as absent.
- [ ] A question set with several questions defines its eval case unit; a
      finding triage case is one (finding, candidate) pair.
- [ ] Every product use case has a receiver-side wrong signal; every judged
      result returns its `call_id`; a feedback reference that names no call of
      the caller's owner is `not_found`; a fallback or eval call cannot be
      reported (*Receiver feedback*).
- [ ] `judgment_calls` holds no text; the request is kept only in
      `judgment_payloads` (30 days, answered product calls) and copied onto
      feedback (90 days); feedback is read only by its owner.
- [ ] A feedback row never changes a mode, threshold, budget, route or
      ticket; the wrong-rate counts strong signals only and reads n/a under
      20 answered calls.
- [ ] A request body carrying an `owner_action` label is refused; only the
      server builds an owner-action run, from the owner's own index, with no
      item in more than five pairs on either side of a pair group.
- [ ] An owner-action run's threshold is one per dimension, written to each
      of that dimension's level labels; a mixed run is never applied.
