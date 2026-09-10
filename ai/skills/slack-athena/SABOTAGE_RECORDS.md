# Sabotage records — `slack-athena`

A test is not finished until you have watched it fail: delete the thing it
exists to prove, run it, confirm the failure names the right criterion, and
write the failure string down next to the claim it supports. Root ADR 002 makes
that mandatory per **subproject**, in deliberately stack-neutral vocabulary, so
a shell suite is in scope exactly as an Elixir one is.

## How to use this

Pick a row. Re-apply the mutation. The named case should fail with the named
string. If it still passes, the check it protects has stopped being
load-bearing and the row is now a bug report.

Rows recording a **measured zero** are the important ones — they mark a claim
no test protects. This run produced one (S28), and it is written up below
rather than quietly dropped.

Every mutation was applied by an exact-substring replace that asserted the
anchor occurs **exactly once** before writing (a sabotage applied by substring
lands wherever the substring first occurs; the wrong site gives a green run
that reads as "the test is dead"), and restored with `cp` from a byte-for-byte
backup taken before the run — never `mv`, whose preserved mtime has burned this
repo before, and never `git checkout --`, which cannot restore a file that is
not yet committed.

---

## 2026-09-01 — building the skill

- **Domain:** slack-athena
- **Date:** 2026-09-01
- **Code under test:** `lib/slack.sh`, `lib/inbox.sh`,
  `hooks/slack-athena-poll.sh`, `bin/post`, `bin/reply`, `bin/dm`,
  `bin/react`, `bin/read-inbox`, `bin/upload`
- **Suite run:** `bash test/self-test.sh` (no network — curl is a PATH shim; ~7s)
- **Baseline:** `VERDICT: PASS (55 cases)` (47 at the first pass; 5 added after
  the live smoke test found two real defects, 3 more to cover `upload`, which
  had none — see the closing sections)
- **Runner:** 42 mutations, one at a time, full suite after each.

### What the suite proves

| # | Mutation | Cases reddened | Failure string(s) |
|---|---|---|---|
| S1 | `lib/slack.sh`: the `.ok == true` check → `if false` (a 200 with `ok:false` is read as success) | 4 | `FAIL  ok:false on a 200 exits non-zero with the Slack error on stderr` / `FAIL  missing_scope reports the needed scope` / `FAIL  hook: warns after 6h with no successful poll` / `FAIL  hook: a recent success keeps a one-off failure silent (but logged)` |
| S2 | the `xoxb-` prefix check dropped (a user token would be accepted) | 1 | `FAIL  a non-xoxb token is refused before any request` |
| S3 | the token also passed as `-H "Authorization: Bearer $TOKEN"` on the command line | 1 | `FAIL  the token never appears in curl's argv` |
| S4 | `umask 077` → `umask 022` when writing the curl config | 1 | `FAIL  the token travels as a Bearer header in a 0600 curl config` |
| S5 | the `Content-Type: application/json` header dropped | 1 | `FAIL  post: channel/text body, JSON content type, prints ts and permalink` |
| S6 | `slack_paginate`: the `next_cursor` loop → unconditional `break` | 1 | `FAIL  pagination: next_cursor is followed and both pages are returned` |
| S7 | `if [ "$_rq_http" = "429" ]` → `if false` | 2 | `FAIL  429: waits out Retry-After and retries, then succeeds` / `FAIL  429: gives up with an error rather than retrying forever` |
| S8 | `slack_users_ensure`: the unknown-id branch → `if false` | 1 | `FAIL  users cache: an unknown id triggers exactly one refresh` |
| S9 | the `sed '1!G;h;$!d'` oldest-first reversal removed from the text renderer | 1 | `FAIL  read-channel: messages print oldest-first` |
| S10 | hook: the 5-minute rate-limit guard → `if false` | 2 | `FAIL  hook: a marker younger than 5 minutes suppresses the poll entirely` / `FAIL  hook: a failed poll still stamps the marker` |
| S11 | hook: the pre-request `: > "$MARKER"` → `true` (stamped only implicitly, after the scan) | 1 | `FAIL  hook: a failed poll still stamps the marker` |
| S12 | hook: `[ "$TOTAL" -gt 0 ] \|\| exit 0` → `-ge 0` (zero no longer suppresses the line) | 3 | `FAIL  hook: zero new prints absolutely nothing, rc=0` / `FAIL  hook: a channel message without <@bot> is not a mention` / `FAIL  hook: the bot's own messages are ignored` |
| S13 | hook: the mention count matcher `"kind":"mention"` → `"kind":"dm"` | 1 | `FAIL  hook: N>0 prints exactly one line with the right DM and mention counts` |
| S14 | hook: the output line interpolates `$(cat "$NEW")` — i.e. it prints the message bodies | 2 | `FAIL  hook: N>0 prints exactly one line with the right DM and mention counts` / `FAIL  hook: no message body, sender or channel reaches stdout or the log` |
| S15 | hook: `maybe_warn_stale` body → `return 0` (the warning never fires) | 1 | `FAIL  hook: warns after 6h with no successful poll` |
| S16 | hook: the recent-success guard → `if false` (every failure warns) | 1 | `FAIL  hook: a recent success keeps a one-off failure silent (but logged)` |
| S17 | hook: the warn-marker guard → `if false` (the warning repeats every prompt) | 1 | `FAIL  hook: the staleness warning is itself rate-limited` |
| S18 | hook: the "is a token configured at all" guard → `if false` | 2 | `FAIL  hook: no token configured is silent, unlogged, and makes no request` / `FAIL  hook: an unconfigured machine is never warned at` |
| S19 | `lib/inbox.sh`: `select((.user // "") != $me)` → `select(true)` | 1 | `FAIL  hook: the bot's own messages are ignored` |
| S20 | `lib/inbox.sh`: the `<@BOT>` containment test → `select(true)` | 1 | `FAIL  hook: a channel message without <@bot> is not a mention` |
| S21 | `lib/inbox.sh`: the first-sight `continue` → `if false` | 1 | `FAIL  read-inbox: first sight of a conversation records its ts and reports nothing` |
| S22 | `lib/inbox.sh`: the per-tick channel budget check → `if false` | 1 | `FAIL  inbox scan: the channel budget caps the requests per tick and says so` |
| S23 | `lib/inbox.sh`: `&oldest=…` dropped from the history query | 1 | `FAIL  read-inbox: a known conversation is read incrementally with oldest` |
| S24 | `lib/inbox.sh`: the DM listing put back into a pipeline (`slack_paginate … \| jq … \|\| slack_die`) | 2 | `FAIL  hook: warns after 6h with no successful poll` / `FAIL  hook: a recent success keeps a one-off failure silent (but logged)` |
| S25 | `bin/reply`: `thread_ts` dropped from the body | 1 | `FAIL  reply: thread_ts is sent and reply_broadcast is absent by default` |
| S26 | `bin/dm`: `conversations.open` skipped, the user id used as the channel | 1 | `FAIL  dm: conversations.open precedes the post and supplies the channel` |
| S27 | `bin/read-inbox`: the `--peek` guard removed (it advances anyway) | 1 | `FAIL  read-inbox: --peek shows messages without advancing the state file` |
| S28 | `bin/read-inbox`: the OPENING untrusted-content fence removed | **0 → 1** | see below |
| S28b | `bin/read-inbox`: the CLOSING untrusted-content fence removed | 1 | `FAIL  read-inbox: bodies are fenced between an opening and a closing untrusted marker` |
| S29 | `bin/post`: the empty-message refusal removed | 1 | `FAIL  post: an empty message is refused, not sent` |
| S30 | `bin/react`: the `:colon:` stripping removed | 1 | `FAIL  react: :name: is normalised and sent as timestamp/name` |
| S31 | `lib/inbox.sh`: the Slackbot IM no longer excluded from the DM list | 1 | `FAIL  inbox scan: the Slackbot IM is excluded before a history call is spent on it` |
| S32 | `lib/inbox.sh`: a failed history call aborts the scan instead of being skipped | 2 | `FAIL  inbox scan: an unreadable conversation is skipped, counted, and the rest still scanned` / `FAIL  inbox scan: a scan in which every conversation failed is an error, not an empty inbox` |
| S33 | `lib/inbox.sh`: the all-failed guard → `if false` (a dead read reads as an empty inbox) | 1 | `FAIL  inbox scan: a scan in which every conversation failed is an error, not an empty inbox` |
| S34 | `bin/read-inbox`: the skipped-conversation note removed | 1 | `FAIL  inbox scan: an unreadable conversation is skipped, counted, and the rest still scanned` |
| S35 | `lib/inbox.sh`: an empty first-sight conversation records no baseline | 1 | `FAIL  inbox scan: an empty conversation records a zero baseline, not nothing` |
| S36 | `lib/inbox.sh`: the zero baseline recorded as a far-future ts instead | 1 | `FAIL  inbox scan: an empty conversation records a zero baseline, not nothing` |
| S37 | `bin/upload`: `files.completeUploadExternal` skipped (the file attaches to nothing) | 1 | `FAIL  upload: exact byte length, bytes PUT to upload_url, then completed onto the channel` |
| S38 | `bin/upload`: the byte length guessed (`LENGTH=1024`) instead of measured | 2 | `FAIL  upload: exact byte length, bytes PUT to upload_url, then completed onto the channel` / `FAIL  upload: an empty file is refused before any request` |
| S39 | `bin/upload`: the bot token sent to the pre-signed upload URL | 1 | `FAIL  upload: the bot token is not sent to the pre-signed upload URL` (see the note below — the first attempt at this mutation was invalid) |
| S40 | `bin/upload`: the empty-file refusal removed | 1 | `FAIL  upload: an empty file is refused before any request` |

### The measured zero (S28), and what closed it

Deleting the opening fence — the line that tells the reader everything below it
is untrusted data rather than instructions — left the suite **green**:

```
S28 | VERDICT: PASS (47 cases)
```

The case asserted `[[ "${OUT}" == *"untrusted content"* ]]`, and the *closing*
fence contains those same words. So the assertion was satisfied by the wrong
half of the pair, and the check protecting the skill's central safety property
would have survived its own deletion.

That is the general shape worth remembering: **an assertion on a phrase that
appears in more than one place cannot tell you which one it found.** The
untrusted fence is exactly the kind of thing that gets tidied away in a later
edit, and a green suite would have blessed it.

Closed by asserting on both markers *and* the body between them:

```bash
[[ "${OUT}" == *"untrusted content below"* ]] \
  && [[ "${OUT}" == *"end untrusted content"* ]] \
  && [[ "${OUT}" == *"untrusted content below"*"please look at MR 42"*"end untrusted content"* ]]
```

Both halves were then re-mutated (S28, S28b above); each reddens the case with
`FAIL  read-inbox: bodies are fenced between an opening and a closing untrusted marker`,
and the restored suite is back to `VERDICT: PASS (47 cases)`.

### A real defect the pass found (S24 is its regression test)

The suite went green before this pass, but two hook cases were passing for the
wrong reason. `lib/inbox.sh` originally listed DMs as:

```sh
slack_paginate conversations.list … | jq -r '.id' > "$TMP/dm-ids" || slack_die "…"
```

In POSIX `sh` the exit status of `a | b` is **b's**. `slack_die` inside
`slack_paginate` killed only its own side of the pipe; `jq` then succeeded on
the empty input it was handed, the `|| slack_die` never ran, and the scan
reported *"nothing new"*. With a revoked or wrong token the hook would have
gone on saying nothing, forever — and the staleness warning that exists to
catch precisely that would never fire either, because every run looked like a
success. The two cases that should have caught it were themselves reporting
`out='' log=''`.

Fixed by splitting the pipeline into two statements (the same fix in
`slack_refresh_users`, `slack_refresh_channels`, and `bin/read-channel`). S24
re-applies the pipeline and is the regression test.

### Traps hit while running this pass

- **A `pgrep` watchdog self-matches its own cmdline.** `while pgrep -f
  "scratchpad/sabotage.py"; do sleep 10; done` never exits: the waiter's own
  command line contains the pattern. Two waiters sat spinning long after the
  run had finished and written its JSON. Key on the real pid, or on the output
  artifact.
- **Running the suite while a sabotage is applied reports a phantom red.** A
  `VERDICT: FAIL (3 of 47)` mid-pass was my own concurrent run landing on
  whichever mutation was live at that instant, not a defect. Sabotage runs own
  the working tree; don't read anything else from it while one is in flight.
- **A killed runner does not restore.** The first attempt was killed by an
  agent command timeout (SIGTERM), so Python's `finally` never ran and eight
  `*.sabotage-backup` files were left beside a mutated tree. Restoring by hand
  and re-running the suite to green is the only proof that the tree is the tree
  you meant to ship — a clean `git status` would not have said so, because none
  of this is committed yet.

### Two defects the LIVE smoke test found that no mutation would have

The shim suite was green and the sabotage pass was complete before either of
these surfaced. Both needed the real workspace, and both are now covered by
cases 48–52 with the mutations above.

**1. Slackbot's IM is listed and then 404s.** `conversations.list types=im`
returns the `USLACKBOT` conversation; `conversations.history` on it answers
`channel_not_found`. The first live `read-inbox` therefore aborted:

```
slack-athena: conversations.history failed: channel_not_found
```

Eleven readable DMs went unexamined behind one unreadable one. Fixed twice
over — the Slackbot IM is dropped by name, and any single unreadable
conversation is now skipped and counted rather than fatal — with the "every
conversation failed" case kept fatal, so a genuinely broken read can never
present itself as a quiet inbox.

**2. An empty conversation recorded no baseline.** The first-sight rule stores
a conversation's newest ts and reports nothing. A conversation with *no*
messages has no newest ts, so it stored nothing, stayed "first sight" on every
subsequent scan, and would have swallowed the first message anyone ever sent
into it — silently, and only for the conversations most likely to matter (a DM
nobody has used yet is exactly where a new person's first message lands). On
the live workspace this was **10 of 13** conversations on the first scan.
Fixed by recording a `0` baseline, which means "seen nothing yet". After the
fix the same scan records all 13.

Worth noting what this says about the sabotage method: both defects were in
code the suite exercised and the mutations reddened. Sabotage certifies that a
test is about what it claims; it cannot see a case nobody considered. The live
run is what supplied the missing cases.

### A mutation the shell refused, and why it is not a zero

The first attempt at S39 added `-H "Authorization: Bearer $SLACK_TOKEN_VALUE"`
to the pre-signed upload PUT. The suite reddened — but on the **wrong case**:

```
FAIL  upload: exact byte length, bytes PUT to upload_url, then completed onto the channel
      rc=1 … err='bin/upload: line 52: SLACK_TOKEN_VALUE: unbound variable
                   slack-athena: network error uploading bytes'
  ok  upload: the bot token is not sent to the pre-signed upload URL
```

`slack_load_token` sets `SLACK_TOKEN_VALUE` in whatever shell calls it, and
`bin/upload` only ever reaches it through `STEP1="$(slack_get …)"` — a command
substitution, so the assignment lives and dies in the subshell. Under `set -u`
the mutation therefore aborted the script before any token could reach argv.
Read carelessly, that is "the leak check is dead". It is not: the mutation
never performed the leak.

Re-run reading the token from its file instead
(`-H "Authorization: Bearer $(head -n1 "$SLACK_TOKEN_FILE")"`), the leak
actually happens and the right case goes red:

```
FAIL  upload: the bot token is not sent to the pre-signed upload URL
```

Same trap as the `Ecto.Query.CastError` row in `backend/CLAUDE.md`: when a
sabotage reddens something, check that the red is a claim about a value and not
a refusal to run.
