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
`slack_routing`, `priority_scoring`, or `eval:<use_case>`). A **question set** is
the versioned code that turns a use case's input into the request. A **caller**
is the consumer that asked for a judgment and acts on the result. An
implementation that violates a MUST is non-conformant.

**Every refusal, hard error and fault-class fallback specified here MUST carry
a greppable `Fix:` clause** in its log line or structured field, naming the
corrective action (*Fallback: every error equals today's behaviour, loudly*
says which fallbacks are faults), per `~/dev/custom/CLAUDE.md` → *Guard/error messages are written for the
LLM*. This contract quotes no exact `Fix:` text. When an implementation pins
exact text, the ticket that ships it adds the quote and its pin together
(`ai/contracts/test/check-quoted-fix.rb`, DND-411).

---

## Purpose and non-goals

A judgment answers a narrow typed question — a choice among fixed options, or a
score on a fixed scale — with a confidence. Three consumers use it today:

- **Finding triage** (DND-713): before a finding is filed, advise whether it
  duplicates or relates to an existing ticket, and suggest a severity.
- **Slack routing** (DND-716): route a new conversation the owner wrote to the
  owning session by topic. The router order is
  `ai/contracts/athena-events.md` → *New conversations may route by an advisory
  topic judgment*.
- **Priority scoring** (DND-718): add bounded urgency and importance reasons to
  an indexed item's rank (`ai/contracts/athena-events.md` → *Ranking*).

Non-goals. A judgment never:

- authorizes anything, closes, merges or cancels a ticket, sends a reply, or
  decides an owner-gated step;
- generates text (no generative use);
- routes a thread reply (thread claims own that:
  `ai/contracts/athena-events.md` → *Thread replies route to the thread's
  claimant*);
- depends on a fine-tuned model (the domain goes into the state and the
  criteria).

This contract changes nothing in walt_ui. walt_ui may adopt the triage script
later, as its own change.

## Trust posture

> A judgment is advisory input to deterministic policy. It never authorizes an action, never grants or widens access, and never selects a destination or target outside a set the owner already authorized. It is never the sole basis for a destructive, irreversible, owner-gated or security-relevant step. The `state` sent for judgment is untrusted data: its text can steer the answer (TypeSafe, jev-1.13 jaggedness, *Adversarial content*). A use case is admissible only if a wrong answer costs at most one of: a recoverable misroute between the owner's own sessions, a misranked item, or a wrong advisory line a human or agent reads before acting. Typed output guarantees the interface, not truth.

This mirrors the inbox rule that content can cause a report but never authorize
an action (`ai/contracts/athena-inbox.md` → *Untrusted input*). A judgment-routed
Slack line is inbox content like any other: the receiving session re-verifies it
and treats its body as untrusted, exactly as for a line the channel route
delivered.

Concretely:

- **Slack routing chooses only among the owner's own topic routes**, each
  authorized by `:add_slack_route` when it was written.
- **Only the owner's own text is judged for routing.** A new conversation from
  anyone else follows the channel route by code, with no call. This bounds the
  adversarial surface.
- **Triage prints advice only.** It never closes, merges or re-prioritizes a
  ticket. The filer decides.
- **Priority adds bounded reason deltas.** An owner override always wins, and
  the default `vip_asker` weight exceeds the largest combined judged delta.
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
| `slack_routing` | the owner's own message text and its line `kind` (`im`, `mpim` or `mention`) |
| `priority_scoring` | the item's `title`, `source` and `status`, plus `message_text` for a `slack_ask`; never a date and never the asker |
| `eval:<use_case>` | the same request the product use case builds, for a labelled case |

**What is stored: no text.** gen_saas stores no state text for any judgment.
The call record (`judgment_calls`) holds an opaque `subject_ref` (an event id, a
ticket ref or an item id), the outcome and reason, the model, the answers
(choice or score, probabilities, confidence), token usage, cost and latency. It
MUST refuse a `state`, `text` or `body` key in the stored answers. Rows are
pruned after 30 days. The eval corpus stays machine-local and untracked, joined
to its source by id, never copied into a second file.

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
| `request_rejected` (with detail) | HTTP 422 |
| `rate_limited` (with `retry-after` seconds, or none) | HTTP 429 |
| `overloaded` | HTTP 529 |
| `http_status` (with the status) | any other non-2xx status |
| `timeout` | no response within the deadline |
| `transport_error` | connection failure |
| `undecodable_body` | a 2xx whose body is not JSON |

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
configured: the mode is off, the sender is not the owner, a label has no
accepted threshold. There is nothing to fix, so it logs at debug level with no
`Fix:` clause, and it never changes a use case's health. A **`fault`** reason
means something is wrong: a missing key, a rejected credential, a spent budget,
a service error, our own bug. A fault is loud: it also logs a warning (an error
for our own bugs) naming the use case, the reason, the owner and the
`subject_ref`, with a `Fix:` clause, and it moves health to `unavailable`
(*Owner alerts track health, not calls*). So a real fault is never buried under
routine fallbacks.

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
6. the credential latch (a 401 recorded after the key was stored);
7. the call, under the deadline;
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
| `request_rejected` | fault | judge | TypeSafe returned 422 (our bug: error-level log) |
| `http_status` | fault | judge | TypeSafe returned another non-2xx status; the record carries it |
| `transport_error` | fault | judge | the connection failed |
| `undecodable_body` | fault | judge | the response body was not JSON |
| `malformed_answer` | fault | judge | the answer does not match the request; recorded as `malformed_answer:<detail>` |
| `model_mismatch` | fault | judge | the answering model is not the pinned model |
| `below_threshold` | state | caller | the confidence is under the accepted threshold, or the answer is `unclear` |
| `threshold_unset` | state | caller | no threshold exists for the key; never accepts, whatever the confidence |
| `label_disabled` | state | caller | the answer's label is disabled, or has no live destination |
| `sender_rule` | state | Slack router | the conversation is not the owner's own, so no judgment is asked |

A successful call records outcome `answered` with no reason.

**The credential latch.** A 401 sets a latch keyed on the key's stored-at time.
While it holds, every call falls back as `credential_rejected` with **no** call
to TypeSafe, so a revoked key makes one call, not one per event. Storing a new
key (a newer stored-at time) clears the latch by construction.

**Owner alerts track health, not calls.** A use case's health is
`unavailable(<reason>)` after a fault-class outcome and `ok` after an answered
call; a state-class outcome leaves it unchanged. When health moves between `ok`
and `unavailable(<reason>)`, one owner alert goes out through the existing
owner-alert path. N faults in a row are N records and one alert. The budget has
its own alert rule (*Budget*).

## Modes

Each (owner, use case) has one mode:

- **`off`** — the shipped default, and the reading of an absent settings row. No
  call is made. The caller does today's behaviour and the record says `mode_off`.
- **`shadow`** — judge and record, but act exactly as today. The record shows
  what would have happened.
- **`on`** — act on accepted judgments.

**`on` is refused** unless a threshold row exists for (owner, use case,
question-set version, pinned model) that an eval run produced. A use case MAY
add a refusal of its own; Slack routing refuses `on` while the p95 of
`latency_ms` over its shadow-mode `judgment_calls` rows exceeds 1,000 ms. `eval:*` ignores the mode, but not the key, the domain
or the budget.

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

**n/a.** A label with no qualifying threshold is **`n/a`**: disabled, and it
falls back. `n/a` is not 0 and not a failure. No threshold row reads as
`threshold_unset`, which also falls back. Neither ever accepts.

**Unscored is not wrong.** An eval case that fell back (a service error, a
missing key) is excluded from precision and counted as `unscored`, by reason. A
run where every case fell back reports `scored: 0`, never a precision of 0.

## Budget

**D3 (owner, 2026-09-25, RESOLVED): a dollar cap.** Cody, verbatim: "Let's put a
$10 / month cap".

- **Monthly cap: $10 per calendar month (UTC), per owner, across all use
  cases.** It is enforced in dollars, computed from metered token usage at the
  configured price, not as a token count alone.
- **Daily pacing guard: $10 / days-in-month × 3** (about $0.97 in a 31-day
  month), so one day cannot spend the month. The day is the UTC day.
- **Per-use-case shares** of both caps: `slack_routing` 10%, `finding_triage`
  30%, `priority_scoring` 20%, `eval:*` 40%. A call must fit both its use case's
  share and the total.
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
  ones that month are recorded and logged, never re-alerted. A budget refusal is
  not retried.
- **Local rate limit: 60 requests per minute per owner**, derived from the call
  records, not process state. Over it, the call falls back as
  `rate_limited_local`.

## Lifecycle

**The integration is work-owned.** The key is work-paid (D1). It ends when the
work Slack webhooks end. Personal-domain use (D2) rides the same key and ends
with it.

- **The key is held in `Athena.Secrets`** as `(owner_id, :typesafe_api_key)`,
  per DND-711. It is stored out of band by the owner. No API or UI path writes
  it.
- **Loss of access is a designed state.** A revoked key or a gone account falls
  back exactly like a missing key: loud, one alert, and no retry loop or crash
  loop.
- **Decommissioning is deleting the secret.** Every use case then falls back as
  `key_missing` and behaves as it did before judgments existed. Nothing else
  needs to change.

## Conformance checklist

- [ ] No judgment authorizes an action, widens access, or selects a destination
      outside a set the owner authorized (*Trust posture*).
- [ ] Only the fields in *Egress and data flow* are sent; no state text is
      stored; `judgment_calls` refuses `state`, `text` and `body` keys.
- [ ] The content domain is recorded on every call; an absent or unknown domain
      is `domain_not_permitted`; `personal` is permitted (D2).
- [ ] The key is an argument to the port only, never logged or in an error term;
      the port never retries.
- [ ] Every non-accepted outcome does today's behaviour and leaves a record with
      a reason from the closed list and a telemetry event; a fault-class reason
      also logs a warning with `Fix:` and moves health; a state-class reason
      does neither; `key_missing` names the searched key.
- [ ] Every check before the call makes no call to TypeSafe; a latched 401 makes
      no call.
- [ ] Mode defaults to `off`; `on` is refused without an eval-produced threshold.
- [ ] `threshold_unset` and `n/a` never accept; unscored eval cases are never
      scored as wrong.
- [ ] Requests pin `jev-1.13.0`; a different answering model is `model_mismatch`.
- [ ] The monthly $10 and daily pacing caps are enforced in dollars from config
      prices; a missing price fails closed as `price_unknown`; one budget alert
      per UTC month.
- [ ] Health transitions alert once each, not per call.
- [ ] Deleting the secret returns every consumer to today's behaviour.
