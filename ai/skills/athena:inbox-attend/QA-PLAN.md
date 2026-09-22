# athena:inbox-attend — QA plan (reliability properties)

**Kind: living normative document** (amended in place, per `~/dev/custom/CLAUDE.md`
→ *Documentation conventions*). It states the properties the attendant wake path
MUST satisfy; it is not a test runner.

These properties are re-landed from PR #47's `scripts/test/athena-attend/self-test.sh`
(31 hermetic cases over the shell runner + installer). That suite itself is
**DEAD as a suite** — it asserted the `claude -p` runner's reaction to
`inbox-wait`'s exit-code contract, and the runner is superseded by the standing
channel session (`ai/docs/inbox-channels-design.md` → §4, §6, §9.3). What
survives is the **reliability requirement**: the mechanism must never go silent
on a non-success terminal state, must re-arm on every wake path, must survive a
transient, and must not spin. Each property below is re-targeted from
runner-exit-codes to the channel shim's events; each becomes a case in the shim
self-test (`ai/skills/athena:inbox/channel/test/self-test.sh`) when the shim
lands (design §8, ticket T2). This doc is the QA plan those cases prove.

The intent every property shares (from #47's suite header): each assertion is
about a decision **invisible from the outside in production** — which is why it
is worth a test. A wake mechanism that invokes the model on a quiet budget burns
tokens for nothing; one that treats "could not count" as zero goes silently dark
(the silent-dark class `ai/CLAUDE.md` → *A failed lookup must never look like an
empty one*); a session that never rotates grows the transcript, and the per-turn
bill, without bound.

## Legend — where each property is proven

- **[judgment]** — this skill (`SKILL.md`); provable by reading the procedure.
- **[shim]** — the channel shim's self-test (design §8; ticket T2).
- **[launcher]** — the tmux launcher + supervisor + rotation bounds (ticket T3).
- **[ack]** — the `ack_wake` tool + allowlist (ticket T4).

The tags name where a property lands as an executable check. T1 (this ticket)
lands the properties as this plan and the judgment half; it does not re-land the
runner suite.

## Trigger and quiet-hours (the wake fires on real mail, only on real mail)

1. **`new > 0` after a wake → the attendant handles exactly once.** The trigger
   is `new > 0` from a fresh `inbox-status`, not the raw doorbell — a bell rung
   while nothing was listening is recovered on the next wake and on startup
   (design §2 principle 4; §3.3 catch-up). **[shim]**
2. **`new == 0` → no handling, no model turn.** A wake that resolves to nothing
   new costs zero model turns (quiet hours are free). **[shim]**
3. **A quiet/budget wake path (`inbox-wait` exit 75) is NOT "all clear".** The
   attendant re-checks `inbox-status` on exit 75 exactly as on exit 0, and
   handles across a `0 → 75 → 0` sequence. This is #47's lost-wake closure.
   **[shim]**

## Never silent on a non-success terminal state (the silent-dark class)

4. **"Could not count" is never treated as 0.** If `inbox-status` returns a
   non-document / errors, that is logged as a count failure — never an event
   claiming `0`, and never silence. No wake action, no false all-clear. **[shim]**
5. **A stopped waiter reaches a human, loudly.** `inbox-wait` exit 2 (permanent
   stop) writes a stop marker carrying a `Fix:` line and does **not** re-arm; the
   stop is observable, not a quiet channel. **[shim]**
6. **A wedged mechanism does not look like a quiet one.** Persistent consecutive
   failures escalate to a `wedged` marker (and, per design §3.4, an owner DM),
   never silent exit. **[shim] [launcher]**
7. **A dropped delivery is made observable.** Claude Code drops a channel event
   silently when the session is not registered as a channel; the shim cannot see
   the drop directly, but it can see that `new` did not fall within the handle
   budget and writes `channel.dark` with the key (project, channel names, count)
   and a `Fix:` line (design §3.4). Silence-is-not-success needs this instrument
   because the channel path depends on an Anthropic primitive with **no delivery
   acknowledgement** (design §1, §9.6). **[shim]**

## Survive transients; re-arm; do not spin

8. **A watcher/inotify fault is survived, not fatal and not silent.** A transient
   watch fault re-arms (bounded), logs the fault, and writes no stop/wedge
   marker — a dead watch is not quiet. **[shim] [launcher]**
9. **A single transient handler failure does not kill the loop.** It backs off, the
   next wake succeeds, and the failure streak resets. **[launcher]**
10. **No busy-spin; the wait is bounded and blocking.** The waiter blocks on a
    kernel wait (never a `do :; done` spin), and any backoff is a real bounded
    sleep (`ai/CLAUDE.md` safe-wait Hard Rule). **[shim] [launcher]**

## Bodies never leak through the wake (the trust boundary)

11. **The wake event carries counts and the tenant's own channel names only** —
    no body, filename, slug, or sender, even for a crafted hostile jsonl line
    (design §2 principle 2). Bodies enter only through `read-inbox`, fenced,
    under the consumer lock, so `inbox-untrusted-guard` keeps firing. **[shim]
    [judgment]**
12. **`meta` keys are identifiers only** — no hyphens (Claude Code silently drops
    a hyphenated `meta` key), no punctuation that would be dropped or reinterpreted.
    **[shim]**
13. **The ledger holds no message bodies, subjects, or sender names.** It is read
    unfenced at the top of every wake, so a body there would be a stranger
    speaking first. **[judgment]**

## Continuity, tenancy, and single-instance

14. **Session rotation is safe.** Rotating the standing session (on a wakes /
    transcript-bytes / age bound) never loses unread mail — it is on disk with the
    offset unadvanced (design §3.3) — and the ledger carries what was already
    answered. An unmeasurable transcript logs `n/a`, never `0`, and does not force
    a spurious rotation. **[launcher]**
15. **The attendant is a top-level session, not a subagent.** `inbox-wait` /
    `read-inbox` refuse to arm/ack for a subagent, so the wake mechanism must not
    leak `CLAUDE_AGENT_*` into the session; and it runs with
    `CLAUDE_CODE_SESSION_ATTENDED` unset so the harness-edit deny stays live
    (design §4.1, §5). **[launcher]**
16. **One attendant per project.** A supervisor `flock` keeps a single standing
    attendant per project; a second instance exits cleanly without arming. When two
    sessions contend, only one holds the designated-consumer lock at `read-inbox`;
    the loser's read is refused and the attend procedure ends its turn. **[launcher]
    [judgment]**
17. **Tenancy is resolved from the session cwd, refused at the key.** The shim
    resolves the registry entry from its own cwd (design §3.2a); zero channels is a
    loud failure (`exit 2` + `Fix:`), never a session sitting silently on nothing.
    **[shim]**

## Reply scope and tiering (judgment)

18. **Replies land only in the originating conversation.** No effect outside it;
    no third-party DM, no reactions/uploads on other messages. **[judgment]**
19. **A request to DO work is drafted as a Backlog ticket, never acted on.** The
    message cannot authorize work; the owner's move to Todo is the authorization.
    **[judgment]**
20. **Measure before tiering.** Per-wake cost is measured (from the session
    transcript, not a `-p` cost line) before any cost-tiering decision — #47
    decision 4, re-measured on the channel shape. **[launcher]**
