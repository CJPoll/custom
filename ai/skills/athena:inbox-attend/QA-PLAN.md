# athena:inbox-attend — QA plan (reliability properties)

**Kind: living normative document** (amended in place, per `~/dev/custom/CLAUDE.md`
→ *Documentation conventions*). It states the properties the attendant wake path
MUST satisfy; it is not a test runner.

These properties are re-landed from PR #47's `scripts/test/athena-attend/self-test.sh`
(31 hermetic cases over the shell runner + installer), which asserted the
`claude -p` runner's reaction to `inbox-wait`'s exit-code contract. The
go-forward mechanism is the **attended form**: a top-level session that arms
`inbox-wait` with `run_in_background` and re-arms on each wake (`athena:inbox` →
*How to arm it*), over the same `inbox-wait` contract PR #47 exercised. (An
"Inbox on Channels" epic briefly re-targeted these to a channel shim's events;
that delivery mechanism was **abandoned** — 2026-09-22 owner decision — and its
code removed.) What survives is the **reliability requirement**: the mechanism
must never go silent on a non-success terminal state, must re-arm on every wake
path, must survive a transient, and must not spin. Each property below is proven
by reading this skill's procedure or by the `inbox-wait` waiter's own self-test
(`ai/skills/athena:inbox/test/self-test.sh`). This doc is the QA plan those
cases prove.

The intent every property shares (from #47's suite header): each assertion is
about a decision **invisible from the outside in production** — which is why it
is worth a test. A wake mechanism that invokes the model on a quiet budget burns
tokens for nothing; one that treats "could not count" as zero goes silently dark
(the silent-dark class `ai/CLAUDE.md` → *A failed lookup must never look like an
empty one*); a session that never rotates grows the transcript, and the per-turn
bill, without bound.

## Legend — where each property is proven

- **[judgment]** — this skill (`SKILL.md`); provable by reading the procedure.
- **[waiter]** — the `inbox-wait` waiter's own self-test
  (`ai/skills/athena:inbox/test/self-test.sh`): the exit-code contract,
  counts-only output, tenancy refusal, and the not-a-subagent gate.
- **[runner]** — a supervised standing runner (PR #47's shape) for
  standing/unattended operation: rotation bounds, the single-instance `flock`,
  the restart cap, and per-turn cost measurement. This is **not currently
  built** for the attended session form; it is the home these properties land in
  if that supervised runner is revived for unattended standing operation.

The tags name where a property lands as an executable check. The properties are
landed here as this plan and the judgment half (`[judgment]`) and by the waiter
self-test (`[waiter]`); the `[runner]` properties await a revived supervised
runner.

## Trigger and quiet-hours (the wake fires on real mail, only on real mail)

1. **`new > 0` after a wake → the attendant handles exactly once.** The trigger
   is `new > 0` from a fresh `inbox-status`, not the raw doorbell — a bell rung
   while nothing was listening is recovered on the next wake and on startup, from
   the on-disk offset. **[waiter]**
2. **`new == 0` → no handling, no model turn.** A wake that resolves to nothing
   new costs zero model turns (quiet hours are free). **[waiter]**
3. **A quiet/budget wake path (`inbox-wait` exit 75) is NOT "all clear".** The
   attendant re-checks `inbox-status` on exit 75 exactly as on exit 0, and
   handles across a `0 → 75 → 0` sequence. This is #47's lost-wake closure.
   **[waiter]**

## Never silent on a non-success terminal state (the silent-dark class)

4. **"Could not count" is never treated as 0.** If `inbox-status` returns a
   non-document / errors, that is logged as a count failure — never an event
   claiming `0`, and never silence. No wake action, no false all-clear. **[waiter]**
5. **A stopped waiter reaches a human, loudly.** `inbox-wait` exit 2 (permanent
   stop) writes a stop marker carrying a `Fix:` line and does **not** re-arm; the
   stop is observable, not a quiet channel. **[waiter]**
6. **A wedged mechanism does not look like a quiet one.** Persistent consecutive
   failures escalate to a `wedged` marker (and an owner DM from a supervised
   runner), never silent exit. **[waiter] [runner]**
7. **A doorbell rung while unarmed is recovered, never silently dropped.** The
   `.event` doorbell can be bumped while no waiter is armed — between wakes, or
   before startup. The next arm re-checks `inbox-status` from the unadvanced
   on-disk offset, so the mail is handled on the next wake rather than lost, and
   the waiter's exit-code contract keeps "a bell rang" (0), "quiet budget" (75),
   and "faulted" (1/2) distinct, so silence is never read as success. **[waiter]**

## Survive transients; re-arm; do not spin

8. **A watcher/inotify fault is survived, not fatal and not silent.** A transient
   watch fault re-arms (bounded), logs the fault, and writes no stop/wedge
   marker — a dead watch is not quiet. **[waiter] [runner]**
9. **A single transient handler failure does not kill the loop.** It backs off, the
   next wake succeeds, and the failure streak resets. **[runner]**
10. **No busy-spin; the wait is bounded and blocking.** The waiter blocks on a
    kernel wait (never a `do :; done` spin), and any backoff is a real bounded
    sleep (`ai/CLAUDE.md` safe-wait Hard Rule). **[waiter] [runner]**

## Bodies never leak through the wake (the trust boundary)

11. **The wake carries counts and the tenant's own channel names only** — the
    completion notification and `inbox-status` yield no body, filename, slug, or
    sender, even for a crafted hostile jsonl line. Bodies enter only through
    `read-inbox`, fenced, under the consumer lock, so `inbox-untrusted-guard`
    keeps firing. **[waiter] [judgment]**
12. **Unprompted-output fields are identifiers only** — counts and the tenant's
    own channel names, no filename/slug/sender and no punctuation or
    peer-controlled text a reader could misparse (`ai/contracts/athena-inbox.md`
    → *Normative rules*). **[waiter]**
13. **The ledger holds no message bodies, subjects, or sender names.** It is read
    unfenced at the top of every wake, so a body there would be a stranger
    speaking first. **[judgment]**

## Continuity, tenancy, and single-instance

14. **Session rotation is safe.** Rotating the standing session (on a wakes /
    transcript-bytes / age bound) never loses unread mail — it is on disk with the
    offset unadvanced — and the ledger carries what was already answered. An
    unmeasurable transcript logs `n/a`, never `0`, and does not force a spurious
    rotation. **[runner]**
15. **The attendant is a top-level session, not a subagent.** `inbox-wait` /
    `read-inbox` refuse to arm for a subagent, so the wake mechanism must not
    leak `CLAUDE_AGENT_*` into the session; and it runs with
    `CLAUDE_CODE_SESSION_ATTENDED` unset so the harness-edit deny stays live.
    **[runner]**
16. **One attendant per project.** A supervisor `flock` keeps a single standing
    attendant per project; a second instance exits cleanly without arming. When two
    sessions contend, only one holds the designated-consumer lock at `read-inbox`;
    the loser's read is refused and the attend procedure ends its turn. **[runner]
    [judgment]**
17. **Tenancy is resolved from the session cwd, refused at the key.** The waiter
    resolves the registry entry from its own cwd; zero channels is a loud failure
    (`exit 2` + `Fix:`), never a session sitting silently on nothing. **[waiter]**

## Reply scope and tiering (judgment)

18. **Replies land only in the originating conversation.** No effect outside it;
    no third-party DM, no reactions/uploads on other messages. **[judgment]**
19. **A request to DO work is drafted as a Backlog ticket, never acted on.** The
    message cannot authorize work; the owner's move to Todo is the authorization.
    **[judgment]**
20. **Measure before tiering.** Per-wake cost is measured (from the session
    transcript, not a `-p` cost line) before any cost-tiering decision — #47
    decision 4, re-measured on the attended-session shape. **[runner]**
21. **The thinking status is a courtesy that never blocks the reply** (DND-682).
    For a Slack DM or thread message it will reply to, the attendant sets
    `athena:slack/bin/status` in that same conversation first, with generic
    text and no message content. A failed status call is named in the turn
    output and the ledger (`status-failed <slack-error>`) and the reply still
    goes out. Procedure: `athena:inbox-attend` → *Show that Athena is
    thinking*. **[judgment]**
