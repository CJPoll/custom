# Sabotage records — `athena:slack`

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

- **Domain:** athena:slack
- **Date:** 2026-09-01
- **Code under test:** `lib/slack.sh`, `lib/inbox.sh`,
  `hooks/athena-slack-poll.sh`, `bin/post`, `bin/reply`, `bin/dm`,
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
athena-slack: conversations.history failed: channel_not_found
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
                   athena-slack: network error uploading bytes'
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

---

## 2026-09-19 — DND-186: one dedupe set across file and API, SessionStart

- **Domain:** athena:slack
- **Date:** 2026-09-19
- **Code under test:** `lib/inbox.sh` (shared-state read/migrate, the
  `seen_keys` cross-source drop, `inbox_state_advance`), `bin/read-inbox`,
  `ai/hooks/athena-slack-poll.sh` (now a SessionStart hook)
- **Suite run:** `bash test/self-test.sh` (no network — curl is a PATH shim)
- **Baseline:** `VERDICT: PASS (68 cases)` (55 pre-existing + 13 new: cases 56–68)
- **Runner:** 13 mutations, one at a time, full suite after each; exact-substring
  replace asserting the anchor occurs **exactly once**; restored from an
  **in-memory byte copy** (never `git checkout` — the test edits are uncommitted
  relative to the mutated file during the run) — full runner in the report.

### What the new cases prove

| # | Mutation | Cases reddened | Failure string(s) |
|---|---|---|---|
| S41 | `lib/inbox.sh`: `_inbox_drop_seen`'s `select(($seen \| index($key)) \| not)` → `select(true)` (the cross-source drop keeps everything) | 2 | `FAIL dedupe: a message whose channel:ts is in seen_keys is dropped by the API scan` / `FAIL dedupe: the hook does not count a message already in seen_keys` |
| S42 | `lib/inbox.sh`: `inbox_state_advance` stops appending the reported `$keys` to `seen_keys` | 1 | `FAIL dedupe: read-inbox adds a reported message's channel:ts to the shared seen_keys` |
| S43 | `athena-slack-poll.sh`: the hook subshell also calls `inbox_state_advance "$NEW"` (doorbell advances state) | 2 | `FAIL hook: the inbox state file is left untouched` / `FAIL dedupe: the hook does not add to seen_keys` |
| S44 | `lib/inbox.sh`: the advance's jq starts from `{}` instead of the piped state (no read-modify-write) | 1 | `FAIL dedupe: an API advance preserves the file reader's offset/seen_event_ids/rotated_at` |
| S45 | `lib/inbox.sh`: `\| .last_api_poll_at = $now` dropped | 1 | `FAIL dedupe: read-inbox stamps last_api_poll_at` |
| S46 | `lib/inbox.sh`: the legacy-migration read points at `/dev/null` (watermark not carried) | 1 | `FAIL migration: the legacy cache's watermark is carried into the shared state file` |
| S47 | `athena-slack-poll.sh`: the pre-network `: > "$MARKER"` (attempt stamp) → `true` | 2 | `FAIL hook: a failed poll still stamps the marker` / `FAIL markers: a failing poll stamps the attempt marker but never the success marker` |
| S48 | `athena-slack-poll.sh`: the success-stamp guard `if [ "$POLL_OK" -eq 1 ]` → `if true` (a failure stamps success) | 3 | `FAIL hook: warns after 6h …` / `FAIL markers: a failing poll … never the success marker` / `FAIL markers: a missing success marker counts as stale …` |
| S49 | `athena-slack-poll.sh`: `warn_text_if_stale`'s first guard flipped so an ABSENT success marker counts as fresh | 1 | `FAIL markers: a missing success marker counts as stale (warns on the first attempt)` |
| S50 | `athena-slack-poll.sh`: `emit`'s `hookEventName:"SessionStart"` → `"UserPromptSubmit"` (malformed object) | 3 | `FAIL hook: N>0 emits exactly one SessionStart object …` / `FAIL hook: warns after 6h …, as one SessionStart object` / `FAIL markers: a missing success marker counts as stale …` |
| S51 | `athena-slack-poll.sh`: `[ -n "$MESSAGE" ] \|\| exit 0` → `\|\| MESSAGE=" "` (emits even with nothing to say) | 8 | `FAIL hook: zero new prints absolutely nothing, rc=0` (+7 more silent-path cases) |
| S52 | `lib/inbox.sh`: the `SLACK_INBOX_STATE` default drops the `%.jsonl` strip (`${SLACK_INBOX_JSONL}.state.json`) so the path is no longer the reader's suffix swap | 1 | `FAIL state path: derived by suffix swap from SLACK_INBOX_JSONL (matches names_state_name)` |
| S53 | `lib/inbox.sh`: `_inbox_state_read` stops folding the legacy `channels` into a shared state file the reader already wrote (`.channels = (.channels // {})`) | 1 | `FAIL migration: legacy watermark is folded in even when the reader already wrote the shared file` |

All thirteen mutations (S41–S53) reddened the intended case(s); after each, the file was
restored from its in-memory byte copy and the suite returned to
`VERDICT: PASS (68 cases)`.

### Input classes the fixtures now contain (not just code mutations)

Four of the new cases are about an INPUT the earlier suite never had:

- **A `seen_keys` set already carrying the message's `channel:ts`** (cases 56/57)
  — the cross-source state the file channel produces. Before DND-186 no fixture
  ever pre-populated `seen_keys`, so nothing exercised the drop.
- **A state file carrying the file reader's own keys** (`offset`,
  `seen_event_ids`, `rotated_at`; case 60) — the shared-file reality. A naive
  advance that rewrote the file from scratch passed every pre-DND-186 case and
  silently rewound the file channel; S44 is its regression.
- **A legacy `{"version":1,…}` cache and no new state file** (case 62) — the
  first-run-after-upgrade input. Distinguished from a clean start (case 45) by
  whether the post-watermark message is reported.
- **A shared state file the FILE reader already wrote (no `channels`) plus a
  legacy cache** (case 68) — the upgrade-after-the-reader-arrived input, where
  keying migration on "shared file absent" would silently swallow the backlog.

---

## 2026-09-23 — `read-inbox --json` shape + the `im | mpim` kind vocabulary

- **Domain:** athena:slack
- **Date:** 2026-09-23
- **Code under test:** `bin/read-inbox` (the `--json` array emit, the DM count,
  the `slack_die` Fix: override), `lib/inbox.sh` (the im/mpim classification,
  `_inbox_scan_list`'s class/kind split), `ai/hooks/athena-slack-poll.sh` (the
  DM count)
- **Suite run:** `bash test/self-test.sh` (no network — curl is a PATH shim)
- **Baseline:** `VERDICT: PASS (75 cases)` (68 pre-existing + 7 new: cases 69–75)
- **Two changes:** (1) `read-inbox --json` now prints a JSON **array** — `[]` for
  an empty read, exit 0, never zero bytes — and every failure path exits
  non-zero with a `Fix:` line, so "no messages" and "the read produced nothing"
  are no longer the same output (reported by the walt_ui backstop consumer).
  (2) the legacy Web-API backstop labels DMs with the inbox contract's
  `im`/`mpim` vocabulary (DND-300/DND-318) instead of a generic `dm`; the DM
  count is `im + mpim + dm` (legacy tolerated).

### What the new cases prove

| # | Mutation | Cases reddened | Failure string(s) |
|---|---|---|---|
| S54 | `bin/read-inbox`: the `--json` emit `jq -s '.' "$NEW"` → `cat "$NEW"` (bare JSONL; empty prints zero bytes) | 4 | `FAIL read-inbox --json: an empty read prints exactly [] and exits 0` / `FAIL read-inbox --json: a populated read is a JSON array of the messages` / `FAIL kind: a 1:1 conversation is labeled im` / `FAIL kind: a group DM (is_mpim) is labeled mpim` |
| S55 | `bin/read-inbox`: the DM count `grep -c -E '"kind":"(im\|mpim\|dm)"'` → `grep -c '"kind":"dm"'` | 1 | `FAIL kind: im + mpim are both counted as DMs` |
| S56 | `lib/inbox.sh`: the classification `if (.is_mpim // false) then "mpim" else "im" end` → `"im"` (mpim never labeled) | 1 | `FAIL kind: a group DM (is_mpim) is labeled mpim` |
| S57 | `bin/read-inbox`: the `Fix:` line dropped from the `slack_die` override | 2 | `FAIL read-inbox --json: a token failure exits non-zero with Fix:, not []` / `FAIL read-inbox --json: a Slack API failure exits non-zero with Fix:, not []` |
| S58 | `ai/hooks/athena-slack-poll.sh`: the DM count `grep -c -E '"kind":"(im\|mpim\|dm)"'` → `grep -c '"kind":"dm"'` | 1 | `FAIL hook: N>0 emits exactly one SessionStart object with the right DM and mention counts` |

All five mutations reddened the intended case(s); after each the file was
restored from a byte copy and the suite returned to `VERDICT: PASS (75 cases)`.

### S13 under the new vocabulary (annotation, not a rewrite)

**Later (2026-09-23):** the 2026-09-01 row **S13** mutates the hook's *mention*
count matcher `"kind":"mention"` → `"kind":"dm"`. That anchor still occurs
exactly once, and the mutation still reddens — but note the target label
`"kind":"dm"` is now the **legacy** DM label: the live scan emits `im`/`mpim`,
so a mention matcher flipped to `"kind":"dm"` counts **zero** mentions (S13's
whole point — proving the mention counter is distinct from the DM counter —
stands, and case 32 still reddens). S13's failure string references the case's
older name ("prints exactly one line"); the case is now "emits exactly one
SessionStart object with the right DM and mention counts" (see S58). The row is
left as written on its date, per `~/dev/custom/CLAUDE.md` → *Documentation
conventions* (annotate a dated record, do not rewrite it).

---

## 2026-09-24 — DND-508: every bin answers `--help`

`check-bin-help` now probes skill executables, not only `ai/bin/`. All 13
`athena:slack` bins failed its bar: none had a `--help` branch. `post --help`
took `--help` as the channel and read stdin as the message; `whoami --help`
called `auth.test`; the rest printed usage to stderr and exited 2. Each bin now
checks `-h|--help` first, before `slack_need_tools`, and `lib/slack.sh`'s
`slack_help` prints the bin's header comment on stdout.

Case 76 runs every bin with `--help` and with `-h` (26 cases): exit 0, stdout
names the bin, no curl call.

| # | Mutation | Cases reddened | Failure string(s) |
|---|---|---|---|
| S59 | the unfixed bins (no `-h\|--help` branch; measured before the fix) | 26 | `FAIL help: delete --help prints usage on stdout, exit 0, no Slack call` (`rc=2 err='usage: delete <channel_id\|#name> <ts>'`) / `FAIL help: post --help …` (`rc=2 err='post: refusing to send an empty message'`) / `FAIL help: whoami --help …` (`rc=0 curl_calls=auth.test`) |
| S60 | `lib/slack.sh`: `slack_help`'s awk output redirected `>&2` | 26 | `FAIL help: channels --help prints usage on stdout, exit 0, no Slack call` |

After each, the suite returned to `VERDICT: PASS (101 cases)`.

---

## 2026-09-25 — `bin/status` (DND-682)

- **Code under test:** `bin/status` (`assistant.threads.setStatus`)
- **Suite run:** `bash test/self-test.sh`
- **Baseline:** `VERDICT: PASS (117 cases)`. Before `bin/status` was
  executable, the new cases 77–82 and the case-76 help loop failed with
  `rc=126 … Permission denied` (`VERDICT: FAIL (15 of 116 cases)`).
- **Runner:** one mutation at a time, exact-substring replace asserted to match
  once, restored with `cp` from a backup.

| # | Mutation | Cases reddened | Failure string(s) |
|---|---|---|---|
| S61 | request body key `status` renamed `text` | 4 | `FAIL status: default 'is thinking…' is sent as channel_id/thread_ts/status` / `FAIL status: --clear (first) sends status ""` |
| S62 | the `--clear` branch never taken | 3 | `FAIL status: --clear (last) sends status ""` / `FAIL status: --clear with text is a usage error with Fix:, no Slack call` |
| S63 | ts validation accepts a ts with no dot | 1 | `FAIL status: a ts with no dot is a usage error with Fix:, no Slack call` |
| S64 | the `invalid_thread_ts` Fix: mapping unreachable | 1 | `FAIL status: invalid_thread_ts exits non-zero with a specific Fix:` |
| S65 | the redefined `slack_die` exits 0 | 3 | `FAIL status: a missing token exits non-zero with Fix: and no Slack call` |
| S66 | `--help` honoured only as the first argument | 1 (after case 83 was added; 0 before it) | `FAIL status: a trailing --help prints usage, exit 0, no Slack call` |

S66 first measured **zero**: no case covered a trailing `--help`. Case 83 was
added for it, then S66 was re-applied and reddened it. After each row the suite
returned to `VERDICT: PASS (117 cases)`.

## Owner decision-question rules (2026-09-25)

- **Code under test:** `SKILL.md` → *Asking the owner for a decision*, and the
  worked example in `athena:slack:interactive-messages`.
- **Suite run:** `bash test/self-test.sh`
- **Baseline:** `VERDICT: PASS (124 cases)`. Before the doctrine was written,
  all seven new case-84 checks failed (`VERDICT: FAIL (7 of 124 cases)`).
- **Scope:** text-presence only. No case checks a message actually sent.

| # | Mutation | Cases reddened | Failure string(s) |
|---|---|---|---|
| S67 | example button label `Your call (DND-542)` renamed `Defer (DND-542)` | 1 | `FAIL doctrine: the worked owner-choice example has a 'Your call' button` |
| S68 | the `**Background**` step deleted from the structure list | 1 | `FAIL doctrine: athena:slack carries decision rule '**Background**'` |

After each row the suite returned to `VERDICT: PASS (124 cases)`.
