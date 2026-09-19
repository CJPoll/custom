# Sabotage records — `athena:inbox`

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
no test protects. This run produced **seven** on the first pass. **Six of them
were real gaps and were closed** (S2, S11, S14, S18, S31, S35 — see *What the
first pass got wrong*); the seventh, **S12**, is a genuine unreachability and
is written up rather than quietly dropped.

Every mutation was applied by an exact-substring replace that asserted the
anchor occurs **exactly once** before writing (a sabotage applied by substring
lands wherever the substring first occurs; the wrong site gives a green run
that reads as "the test is dead"), and restored with `cp` from a byte-for-byte
backup taken before the run — never `mv`, whose preserved mtime has burned this
repo before, and never `git checkout --`, which cannot restore a file that is
not yet committed. Two anchors did not match on the first attempt and were
reported as `ANCHOR NOT UNIQUE (0)` rather than silently skipped; both were
corrected and re-run.

---

## 2026-09-18 — DND-183: the domain libraries and `inbox-status`

- **Domain:** athena:inbox (the counting slice)
- **Date:** 2026-09-18
- **Code under test:** `lib/names.sh`, `lib/descriptor.sh`, `lib/logchan.sh`,
  `lib/maildir.sh` (unread filter only), `lib/fs.sh`, `lib/inbox.sh`,
  `bin/inbox-status`
- **Suite run:** `bash test/self-test.sh` (no network — nothing here makes one;
  the inbox root is always a `mktemp -d`; ~2s wall)
- **Baseline:** `VERDICT: PASS (231 cases)` (131 at the first pass; 11 added
  after the sabotage run found six checks the suite did not actually protect,
  plus the state-rewrite rule that arrived mid-build, plus 46 more from the
  `athena-diff-critic` round and the `code-reviewer`/`adr-reviewer` pair — see
  *What the reviewers found that sabotage did not*)
- **Runner:** 38 mutations, one at a time, full suite after each.

### What the suite proves

| # | Mutation | Cases reddened | Failure string(s) |
|---|---|---|---|
| S1 | `names.sh`: the 128-byte name limit raised to 100000 | 1 | `FAIL  D-4 a 129-byte name is rejected` |
| S2 | `names.sh`: the `*..*` arm of the inbox-name grammar → `: ;;` | 1 | `FAIL  D-3 an embedded [..] is rejected even with no separator` |
| S3 | `names.sh`: the leading-dot arm → `: ;;` | 3 | `FAIL  D-3 name [../x.jsonl] is rejected …` / `FAIL  D-3 name [.hidden.jsonl] is rejected …` / `FAIL  an illegal log path is rejected: [a/.x.jsonl]` |
| S4 | `names.sh`: the `..|.)` arm of `names_resolve_in_root` → a pattern that never matches | 1 | `FAIL  D-5 escaping path [../x.jsonl] is refused with a Fix: clause` |
| S5 | `names.sh`: a log path's final component no longer has to pass the name grammar | 2 | `FAIL  an illegal log path is rejected: [a/x.json]` / `… [a/.x.jsonl]` |
| S6 | `names.sh`: a log path's namespace segments no longer checked | 3 | `FAIL  an illegal log path is rejected: [../x.jsonl]` / `… [a/../x.jsonl]` / `… [A/x.jsonl]` |
| S7 | `names.sh`: state-name derivation stops stripping the `.jsonl` suffix | 5 | `FAIL  D-6 state path derives by suffix substitution` / `FAIL  a log channel resolves its state path` / `FAIL  counts are reported POST-dedupe …` / `FAIL  the reset is reported rather than hidden` / `FAIL  an offset past EOF is reset to 0 …` |
| S8 | `descriptor.sh`: an unknown registry `v` accepted instead of refused | 1 | `FAIL  an unknown registry v is a hard error naming the version found` |
| S9 | `descriptor.sh`: the top-level key allow-list silently gains the typo `chanels` | 1 | `FAIL  D-8 an unknown TOP-LEVEL key is a hard error, naming it` |
| S10 | `descriptor.sh`: the per-channel allow-list silently gains `dedup`/`typo` | 3 | `FAIL  D-8 an unknown PER-CHANNEL key is a hard error, naming it` / `FAIL  a malformed registry entry is a hard error, not zero channels` / `FAIL  a malformed registry entry is a hard error with a Fix: clause` |
| S11 | `descriptor.sh`: the log-path **grammar** check removed (containment left in place) | 3 | `FAIL  a contained-but-ungrammatical log path [x.txt] is still rejected` / `… [Bad/x.jsonl] …` / `… [.hidden.jsonl] …` |
| S12 | `descriptor.sh`: a maildir namespace's **containment** call removed (grammar left in place) | **0 — measured zero, see below** | — |
| S13 | `descriptor.sh`: an unrecognised `dedupe` member stops being a hard error | 1 | `FAIL  an unrecognised dedupe member is a hard error naming it` |
| S14 | `descriptor.sh`: a missing maildir required field stops being an error | 1 | `FAIL  D-9 the refusal names the missing field, as a missing field` |
| S15 | `descriptor.sh`: a maildir channel may read and write the same directory | 1 | `FAIL  maildir read and write must differ` |
| S16 | `descriptor.sh`: **selection falls back** — any registry entry matches any repo | **11** | `FAIL  E2E-8 a session sees exactly its own project's channels` / `FAIL  A-8 an unregistered repo selects NOTHING -- there is no fallback` / `FAIL  E2E-8 the other project sees its own, from the same registry directory` / … |
| S17 | `descriptor.sh`: two entries claiming one repo stops being an error | 1 | `FAIL  two entries claiming one repo is a hard error with a Fix: clause` |
| S18 | `descriptor.sh`: `descriptor_resolve` stops refusing an undeclared channel | 1 | `FAIL  an undeclared channel is refused by resolution itself, not just by the manager` |
| S19 | `logchan.sh`: the partial final line is **included** in the complete prefix | 1 | `FAIL  D-13 the offset does not advance past the partial final line` |
| S20 | `logchan.sh`: an unknown line `v` counted as new instead of unreadable | 2 | `FAIL  D-15 the readable lines still count` / `FAIL  D-15 the unknown-v line is counted separately as unreadable` |
| S21 | `logchan.sh`: the dedupe check removed — every duplicate counts again | 5 | `FAIL  D-16 a line whose event_id is already seen is not counted` / `FAIL  a duplicate within one slice is counted once` / `FAIL  D-17 a line whose channel:ts is already seen is not counted` / `FAIL  counts are reported POST-dedupe …` / `FAIL  zero across the board prints nothing` |
| S22 | `logchan.sh`: a line with **no dedupe key at all** counted as new | 2 | `FAIL  a line with no dedupe key at all is unreadable, not counted` / `FAIL  a line with no dedupe key at all is not counted as new` |
| S23 | `logchan.sh`: display order reverts to file position instead of `ts` | 1 | `FAIL  D-19 display order is by ts, not by file position` |
| S24 | `logchan.sh`: the seen-set ring buffer loses its cap | 2 | `FAIL  D-18 the ring buffer is capped at 500` / `FAIL  D-18 the oldest entry is evicted` |
| S25 | `maildir.sh`: `tmp/`, `.acked/` and dotfiles stop being excluded from unread | 4 | `FAIL  D-24 tmp/, .acked/ and dotfiles are excluded from unread` / `FAIL  inbox-status reports the maildir channel's count` / `FAIL  --json counts the maildir unread …` / `FAIL  zero across the board prints nothing` |
| S26 | `fs.sh`: the symlink refusal removed | 1 | `FAIL  a symlinked .jsonl is refused with a Fix: clause` |
| S27 | `fs.sh`: the regular-file assertion removed (a FIFO is accepted) | 1 | `FAIL  a FIFO at an inbox path is refused` |
| S28 | `fs.sh`: realpath containment always passes | 1 | `FAIL  a path outside the root fails containment` |
| S29 | `fs.sh`: an unparseable registry file degrades to silence instead of refusing | **21** | `FAIL  E2E-8 a session sees exactly its own project's channels` / `FAIL  an unparseable registry file is a hard error with a Fix: clause` / … |
| S30 | `inbox.sh`: a stale offset past EOF is trusted instead of reset | 2 | `FAIL  an offset past EOF is reset to 0 and the whole file re-read` / `FAIL  the reset is reported rather than hidden` |
| S31 | `inbox.sh`: the manager stops dropping `messages` — per-message data leaks upward | 1 | `FAIL  --json carries counts only -- no per-message data of any kind` |
| S32 | `inbox.sh`: a never-delivered channel is indistinguishable from an empty one | 1 | `FAIL  a never-delivered log channel is distinguished from 'nothing new'` |
| S33 | `inbox.sh`: the denial **echoes** the requested foreign channel name | 1 | `FAIL  A-8 the refusal does not echo the requested foreign channel name` |
| S34 | `inbox.sh`: the undeclared-channel denial removed entirely | 2 | `FAIL  A-8 the refusal names only this entry's channels` / `FAIL  A-8 the refusal does not echo the requested foreign channel name` |
| S35 | `inbox.sh`: a fatal registry error degrades to zero channels (in `inbox_channels`) | 1 | `FAIL  an unparseable registry FILE is fatal to inbox_channels, not silent zero` |
| S36 | `bin/inbox-status`: `$n > 0` → `$n >= 0` — zero no longer suppresses the line | 1 | `FAIL  zero across the board prints nothing` |
| S37 | `bin/inbox-status`: an unknown argument is silently ignored | 1 | `FAIL  an unknown argument is refused with a Fix: clause` |
| S38 | `logchan.sh`: the state rewrite emits a fixed key set, discarding unrecognised keys | 2 | `FAIL  a state rewrite preserves an unrecognised key it did not write` / `FAIL  a state rewrite preserves an unrecognised STRUCTURED value intact` |

### What the first pass got wrong

Seven mutations were survived by the green suite. Recording them is the point
of the exercise; **six were real holes** (the seventh, S12, is the measured
zero below) and the suite gained cases closing every one. This is the honest
accounting of what the first draft of the tests did not actually prove:

| Row | What the green run meant | What was added |
|---|---|---|
| S2 | The `..` arm was only ever exercised by inputs the **separator** or **suffix** arms already reject, so the traversal arm itself was dead weight as far as the suite knew. | `D-3 an embedded [..] is rejected even with no separator` (`a..b.jsonl` — no separator, correct suffix, no leading dot; nothing else catches it). |
| S11 | D-10 passed on the **containment** check alone. The path grammar could be deleted and a `path` of `x.txt` or `Bad/x.jsonl` would have been accepted. | Three cases asserting contained-but-ungrammatical paths are still rejected. |
| S14 | The refusal for a missing `read` happened to contain the substring `read` via the *downstream* "illegal read/write directory name" message, so the assertion passed against the wrong error. | The needle is now the whole phrase `missing required field "read"`. A substring assertion that can be satisfied by an unrelated message is not an assertion. |
| S18 | Deny-by-default was proven only at the **manager**; the domain's own copy in `descriptor_resolve` was untested, so the next entry point calling it directly would have had no check. | A domain-level refusal case on `descriptor_resolve`. |
| S31 | The sentinel assertions proved no body leaked **that day** — but only because the per-message record happens not to carry `text`. They could not prove no body leaks tomorrow. | A **structural** assertion: the status object carries counts and no per-message key of any kind. |
| S35 | Two use cases each carry their own copy of the "a fatal registry error is fatal" check; only `inbox_status_json`'s was covered, so `inbox_channels` could silently report zero channels on a broken registry — indistinguishable from "not opted in". | `an unparseable registry FILE is fatal to inbox_channels, not silent zero`. |

### What the reviewers found that sabotage did not

Mutation testing proves a check is load-bearing. It cannot find a defect in
code **no mutation targets**, and it cannot find a defect whose correct
behaviour nothing in the suite ever described. The `athena-diff-critic` round
found three of those, and they are recorded here because the gap between the
two techniques is the lesson:

| Finding | Why 38 mutations missed it |
|---|---|
| `descriptor_select` returned status **1** for *ambiguous ownership* and status **1** for *no entry matched*, so the manager's "nothing owned → zero channels, exit 0" branch swallowed the hard error and `inbox-status` printed nothing and exited 0 on a registry nobody can resolve. | S17 removed the ambiguity check and reddened the domain-level case, which passed. No mutation could reveal that the *status* the check returns is indistinguishable from success one layer up — the bug was in code that was present and running. Closed by four cases through `inbox_channels` and `bin/inbox-status`. |
| `names_valid_namespace` and `names_resolve_in_root` iterated an **unquoted** expansion (`for seg in ${ns}` with `IFS=/`), so each word was pathname-expanded: a namespace of `*` globbed against the **caller's cwd**, and the component validated was not the component returned. A domain file's verdict depended on where it was called from. | No case fed a glob metacharacter to any grammar function, so no mutation of the *code* could redden something the *suite never exercised*. Closed by eight cases asserting literal treatment from inside a directory with entries to match. |
| `fs_slice_from` carried `[ -f "$2" ]` — testing the byte **offset** as a pathname, discarding the result. It read as a missing-file guard and was not one. | Mutating a no-op changes nothing, by definition. |

Two further findings were doc-level: this file's headline count disagreed with
its own evidence (five vs. six), and `bin/inbox-status` deviated from a
contract **MUST** (a never-delivered `log` channel must be reported with a
`Fix:` clause naming producer registration) with the deviation argued in the
skill rather than honoured. Both are fixed; the never-delivered report gained
three cases.

A second round, with a `code-reviewer` and an `adr-reviewer` reading the PR,
found six more of the same species. Every one is now covered by §8 of the
suite:

| Finding | Why nothing caught it before |
|---|---|
| A non-string `event_id` on a log line (`"event_id": 7`) made jq abort the scan of **every remaining line** — `Cannot index object with number` is fatal, not a lookup that misses. One hostile line cost the whole channel. | The D-15 cases cover an *unparseable* line; nothing covered well-formed JSON with an unexpected value **type**. The line is written by other people, so nothing guarantees either. |
| The manager did not check the scan's status, and `$(...)` discards it. A failed scan yields no output, jq on empty input emits nothing and **exits 0**, so the failure travelled as a successful count of nothing, discarded every other channel's count, and `--json` emitted an unparseable blank line while claiming success. | Mutating a missing check is impossible: there was no line to remove. |
| The maildir count was **peer-controllable**: `ls -A` + a line filter counted a filename containing a newline twice, and a subdirectory as a message. The slug is prose the sender chose, so the sender decided how many messages it had sent. | Every fixture used conformant filenames. The count is the only number this command publishes. |
| `$((offset + bytes))` and `tail -c "+$(( $2 + 1 ))"` are arithmetic contexts, and bash **executes a command substitution inside an array subscript** there. Confirmed: `logchan_scan 'a[$(touch /tmp/PWNED)]'` created the file. Unreachable through the manager, which sanitizes — but both are documented as strings-in primitives with no stated precondition, and their taint source becomes writable the moment the ack ticket lands. | A primitive that is only safe because of its current caller is not safe, and no mutation expresses "safe for the wrong reason". |
| `fs_registry_records` hard-failed on **every** file in `projects/`, so one project's typo wedged `inbox-status` for every project on the machine — and the refusal printed another tenant's registry **filename**, the same disclosure `descriptor_select` refuses by name. | Every fixture had one registry file. Multi-tenancy is the whole point of the directory. |
| A corrupt state file reset the offset to 0 AND emptied the seen-sets, silently disabling dedupe, with no flag — so every acked message was re-announced as new. | Every state fixture was well-formed. The failure produced a *larger* count, which looks exactly like a busy morning. |
| `inbox_status_json` returned on any single channel's failure, so one symlinked inbox suppressed the counts for every other channel — contradicting `err.sh`'s own contract, which returns a status rather than exiting *"so a caller can refuse one channel without killing a multi-channel run"*. | No fixture had a broken channel and a healthy one at the same time. |

A third round found the worst one of all: a **corrupt state file degraded into
silence**. An unparseable state document, or a non-numeric `offset`, or a
`seen_event_ids` that is not an array of strings, fell through every
`2>/dev/null` into `offset=0` with EMPTY seen-sets — so the channel re-read the
whole file AND had deduping silently switched off, and every message ever acked
came back as `new`. Unlike the offset-past-EOF path one line below it, nothing
set a flag, so the inflated count was indistinguishable from real mail in the
pre-prompt position: the tool appearing to work perfectly while announcing a
month of old messages as this morning's. It is now recovered (re-reading
over-reports, which is recoverable; refusing would wedge the channel) and
**reported** — `state_unreadable`, a refusal with a `Fix:` clause, and a line
on the count itself saying the numbers include messages already read. Twelve
cases, including the two that keep the warning honest: a healthy state file and
an absent one must not raise it.

A fourth round ran after DND-202's contract merged into this branch, against
prose that did not exist when the code was written. It found two **MUSTs the
implementation had never seen**:

| Finding | Why nothing caught it |
|---|---|
| **`projects/` is reserved** — no channel `path` or `namespace` may resolve inside it. Containment cannot catch this one, and the contract says so explicitly: `projects/` is *inside* the root, so `"namespace": "projects"` passed every check and pointed a MESSAGE surface at the TENANCY directory. In this counting slice it would have counted other tenants' registry entries as unread mail. | The rule was written after the code. No amount of mutation finds a requirement the author never read. |
| The **failed-candidate count** is required in *ordinary* status output, not only when nothing matched — a skipped candidate might have been this session's own entry. The implementation surfaced it only on the no-match path, dropping the warning in exactly the case where the session cannot tell it was dropped. | Same: the clause post-dates the code. The suite encoded the existing behaviour as if it were the specification. |

That round also caught the `Fix:` clause of the unparseable-registry refusal
being **unrunnable**: it globbed `<dirname of root>/athena/projects/*.json`,
correct only when the root's basename happens to be `athena`, so under any
custom root the agent reading the refusal was sent to an empty path. The repo
convention is that a deny message tells the agent how to self-correct, and a
`Fix:` that does not run is a `Fix:` in name only — so there is now a case that
**extracts the command from the refusal and runs it**, asserting it names the
broken file. Asserting the marker is present was never enough.

And a bug introduced by that same fix, caught before it shipped: the count was
first threaded through a global set inside `inbox_entry` — which every caller
invokes inside `$(...)`, a **subshell**. The assignment could never reach the
caller, so the count would have read `0` everywhere and the MUST would have
looked satisfied while doing nothing. It is a function now.

A fifth round found two more **silent dark channels** — the same shape as
everything else here, reached by different inputs:

| Finding | Why nothing caught it |
|---|---|
| The session's identity was canonicalised (`fs_git_common_dir` → `realpath`) but the entry's `repo` was compared as a **raw string**, while the contract makes the match bilateral: *"Matched exactly, after realpath, against the session's own."* A grammatically fine entry whose `repo` carried a trailing slash, a `..`, or a symlinked-but-equivalent prefix never matched, was never validated, and was not even a **failed candidate** — it parses and has a string `repo`. The session reported `{"channels":[],"failed_candidates":0}`, exit 0. | Every fixture wrote the `repo` key by realpathing it, so every fixture was already canonical. The suite asserted the *session* side of the equality and never the *entry* side. |
| A **tab or newline in a log `path`** is contract-legal (the grammar bars only `/ \ NUL ..`, a leading dot and >128 bytes) and collides with **both** delimiters of the `<label>\t<path>` protocol that `descriptor_resolve` emits and `_inbox_path` parses. The path truncated, real mail reported as *"nothing has EVER been delivered"*, and `inbox` and `state` resolved to the **same** truncated path — which the ack ticket's state writer would have written over the channel file. | This is the delimiter-collision class already fixed once for the registry *filename* (the "JSON first" ordering). Fixing an instance is not fixing a class, and nothing went looking for the second instance. |

Both are now refused, and the second is a **named deviation**: the grammar is
deliberately stricter than the contract's, in the safe direction.

The pattern across all five rounds is worth naming, because it is the argument
for running a reader alongside the mutations: **sabotage proves a check that exists
is load-bearing; it cannot find a check that was never written, one that is
safe only by accident of its caller, or one whose failure is indistinguishable
from success one layer up.**

### Measured zeros

**S12 — a maildir namespace's containment call cannot be reddened.**

`_descriptor_validate_maildir` checks the namespace twice: once against
`names_valid_namespace` (the grammar) and once through `names_resolve_in_root`
(containment). Removing the containment call leaves the suite green, and no
mutation of the *test* can change that, because **every input the containment
call would reject is already rejected by the grammar one line earlier** — a
namespace segment must match `^[a-z0-9][a-z0-9_-]*$`, which admits neither
`..` nor a leading `/`.

The call is kept anyway, and the honest label for it is **defence in depth, not
a tested check**. It costs one line and it is the check the contract names by
name, so a future loosening of the namespace grammar does not silently become a
traversal. But this table must not imply a test protects it. Nothing does.

**The NUL arm of the name grammar is unreachable and is deliberately absent.**

The Ruby client's `valid_name?` rejects a name containing NUL. `names.sh` has
no arm for it, and that omission is the safe direction twice over:

1. bash cannot hold a NUL in a variable at all — the assignment truncates — so
   the arm could never fire from shell.
2. Writing it anyway is **actively dangerous**, and this is not hypothetical.
   The salvaged draft of `names.sh` carried `*$'\0'*) return 1 ;;`. In bash
   `$'\0'` is the **empty string**, so that arm compiles to the pattern `**`,
   which matches every string — the grammar rejected *everything*. It reddened
   `D-1` and `D-4` on the very first run of the suite, which is the only reason
   it was caught before the file was ever committed as working code.

The test asserts the reachable claim instead: `D-3 a NUL cannot survive a bash
variable (grammar arm unreachable)`.

### Not exercised by this run

This slice is DND-183 only. The following ship with later tickets and have no
rows here: the fence renderer (`fence.sh`, QA D-26/D-27 and A-1/A-2), the
consumer lock (`lock.sh`, M-1…M-5, A-6, A-7), the maildir filename grammar,
seq allocation and frontmatter rules (D-20…D-23, D-25, A-3), the atomic state
writer and everything that advances an offset (M-1, M-7…M-12, I-7), the
doorbell waiter (I-1…I-3), the client supervisor (I-8…I-11), and the
SessionStart hook (F-1…F-12, A-9, A-10).

`maildir.sh` here contains exactly one function — the unread filter — because
`bin/inbox-status` cannot produce an honest count for a maildir channel
without it. Its header says so.

---

## 2026-09-18 — DND-184, read-inbox, ack, and the consumer lock

- **Domain:** the Athena Inbox read/ack path (`ai/contracts/athena-inbox.md`
  → *The designated consumer*, *Untrusted input*, *Lifetimes*)
- **Date:** 2026-09-18
- **Code under test:** `lib/fence.sh`, `lib/lock.sh`, `lib/session.sh`, the
  retention predicates in `lib/logchan.sh`, the maildir grammar and frontmatter
  rules in `lib/maildir.sh`, the ack/gate/sweep managers in `lib/inbox.sh`,
  `bin/read-inbox`
- **Suite run:** `bash ai/skills/athena:inbox/test/self-test.sh` (no network;
  inbox root always a `mktemp -d`; the live delivery path is never touched)
- **Baseline:** `VERDICT: PASS (393 cases)` — 373 at the start of this run,
  379 after two measured zeros were closed, 381 after a retention boundary,
  393 after the missing-input sweep.
- **Runner:** same discipline as DND-208 — every mutation an exact-substring
  replace that asserts the anchor occurs **exactly once** before writing, and
  a restore by `cp` from a backup taken before the run.

### Mutations

| # | Mutation | Cases reddened | First failure |
|---|---|---|---|
| T1 | `lock.sh`: `flock -n` in `acquire` always succeeds | 5 | `FAIL  M-2/A-6 a non-holder's ack exits non-zero` |
| T2 | `inbox.sh`: the subagent check removed from the consumer gate | 4 | `FAIL  M-4/A-7 a subagent's ack is refused (CLAUDE_AGENT_TYPE)` |
| T3 | `inbox.sh`: the gate never acquires the lock | 6 | `FAIL  M-2/A-6 a non-holder's ack exits non-zero` |
| T4 | `session.sh`: the `CLAUDE_AGENT_*` env signal ignored | 5 | `FAIL  M-4/A-7 a subagent's ack is refused (CLAUDE_AGENT_TYPE)` |
| T5 | `lock.sh`: a second channel's lock allowed while one is held | **0 → 3** | see *Measured zeros* |
| T6 | `lock.sh`: a symlinked `.consumer.lock` accepted | 1 | `FAIL  A-5 a symlinked .consumer.lock is refused before flock` |
| T7 | `lock.sh`: `flock -n` in `try` always succeeds (count-path sweep steals) | 1 | `FAIL  R-8 a non-holder does not sweep another session's evidence` |
| T8 | `fence.sh`: the generated-nonce attempt ceiling removed | **0 → 2** | see *Measured zeros* |
| T9 | `fence.sh`: the caller-supplied-nonce-in-body refusal removed | 1 | `FAIL  D-26 a caller-supplied nonce present in the body is refused` |
| T10 | `maildir.sh`: never-ack-your-own removed | 2 | `FAIL  D-25 a message whose from is my own identity is never acked` |
| T11 | `maildir.sh`: frontmatter `sent_at` need not agree with the filename | 1 | `FAIL  D-23 frontmatter sent_at disagreeing with the filename is refused` |
| T12 | `maildir.sh`: a required frontmatter key is not required | 1 | `FAIL  D-23 a message missing "from" is refused (it cannot be attributed)` |
| T13 | `maildir.sh`: the seq grammar accepts any digits | 1 | `FAIL  D-20 message filename [20260901T232215Z-1-slug.md] is rejected` |
| T14 | `maildir.sh`: the 48-byte slug ceiling removed | 1 | `FAIL  D-20 a 49-character slug is rejected (<= 48)` |
| T15 | `logchan.sh`: rotation ignores the EOF gate (age overrides) | 1 | `FAIL  R-1 offset < EOF is not rotated however old rotated_at is` |
| T16 | `logchan.sh`: an ABSENT `rotated_at` treated as infinitely old | 1 | `FAIL  R-6 a generation with no rotated_at is never swept on mtime alone` |
| T17 | `logchan.sh`: the sweep boundary `-gt` → `-ge` (sweeps a day early) | **0 → 1** | see *Measured zeros* |
| T18 | `logchan.sh`: the rotation size threshold ignored | 2 | `FAIL  R-3 offset == EOF, rotated_at 1 day old, 9 MiB -> rotated` |
| T19 | `inbox.sh`: the three no-entry causes collapsed back into one message | 7 | `FAIL  and it names the real cause: no git repository` |
| T20 | `inbox.sh`: the absent-registry-root branch removed | 3 | `FAIL  and it says the registry DIRECTORY does not exist` |
| T21 | `inbox.sh`: the no-git-repository branch removed | 2 | `FAIL  and it names the real cause: no git repository` |

Four further mutations re-ran the previous captain's own sabotage pass, whose
four subjects had each measured a zero before it and each redden now:
`fs_maildir_ack`'s grammar re-check (2), `fs_write_state`'s symlink lstat (1),
the `logchan_scan` dedupe-key delimiter guard (56), and the once-derived
consumer lock path in `descriptor_resolve` (7).

### Measured zeros

**T5 — one advance at a time, per process.** `inbox_lock_acquire` refuses a
second channel's lock while it holds one, because acquiring it re-execs fd 9
and **releases the first channel's lock mid-advance** with nothing saying so:
the process goes on believing it is the designated consumer of a channel
another session is now free to take. Deleting the refusal left the suite green,
because every fixture locked exactly one channel — the single-channel
assumption the guard exists to break. Closed by three cases (refused, the
FIRST lock still held, a `Fix:` clause) plus one asserting that re-acquiring
the **same** lock is still a no-op, since a read followed by its own ack would
otherwise refuse itself.

**T8 — the fence's attempt ceiling.** Unreachable against a working
`/dev/urandom` (a body would have to contain all eight independent 64-bit
draws), so no fixture could reach it. That is not evidence the ceiling is dead
weight: a wedged entropy source reaches it, and without the ceiling the
`while :` loop does not terminate. The failure mode is a **hang** — a
`read-inbox` that never returns rather than one that refuses — which is worse
than the thing the ceiling is usually described as preventing. Reached by
stubbing `fence_nonce` to a constant the body contains, run under `timeout` so
a regression is a FAIL and not a hung suite.

**T17 — the sweep boundary.** The R-6/R-7 fixtures (15 days, 13 days) sit far
enough either side of the window that `-gt` and `-ge` are indistinguishable, so
the flip measured a zero: a retention window silently one day short, which
destroys evidence early and looks like nothing. Closed by pinning the boundary
itself — at exactly the window the generation is **kept**, one second past it
is swept. Deleting a day late is recoverable; a day early is not.

### The standing review question, applied to this diff

*"What does this do when the input is MISSING rather than wrong?"* — the
defect class this epic has now produced four times. Applied to the read path
it found a live instance, not in a check but in a **message**: all three causes
of "nothing resolved" printed *"this project declares no inbox channels"*.

| Cause | Was | Now |
|---|---|---|
| cwd is in no git repository | "this project declares no inbox channels" | names the real cause; a Fix: that can work |
| the registry **directory** is absent | same message, and a Fix: naming a file to add under a directory that does not exist | says the directory does not exist, names it, and says **MACHINE-level** |
| the directory exists, nothing claims this repo | same message | the one case that really is "not opted in" |

An operator whose delivery **was** healthy and whose root was lost or unmounted
was being told their project had never been set up, and sent looking for a
missing entry under a missing directory. All three still refuse with an
identical non-zero status — a reader asked for a named channel and did not get
it — so this is a diagnosis, never a decision.

The **count** path is deliberately the opposite and was left alone: the
contract says *"No entry is not a fault — zero channels, exit 0"*, and an
unprovisioned root is caught there by `check-inbox-registry`, which runs
unprompted in the harness gate rather than waiting to be thought of.

### What sabotage could not have found

**This suite was not run by anything.** The harness gate declared twelve
checks and none of them was this file, and the repo has no CI — so 373 cases
covering the whole skill were verified only by whoever remembered to type the
command. No mutation of the code can reveal that nobody runs the tests: an
absent check is indistinguishable from a passing one, which is this epic's
standing defect class appearing in the gate itself rather than in the code.
Closed by declaring the suite, and by generalizing the gate's own
"every self-test on disk is declared" rule from `ai/hooks/*.self-test.sh` to
every place this repo puts a suite. That rule immediately found a second dark
suite — `athena:slack`'s 55 cases — which is now declared too.

### The review round (same date)

The standing `athena-diff-critic`, plus a `code-reviewer` and an `adr-reviewer`
over the branch diff. Between them they found six defects sabotage could not
have reached, and every fix was then sabotaged in turn.

| # | Mutation (the defect, re-applied) | Cases reddened | First failure |
|---|---|---|---|
| T22 | `inbox.sh`: the manager recomputes the dedupe key from raw fields | 2 | `FAIL  a poisoned ts cannot inject a second seen_keys entry via the ack` |
| T24 | `inbox.sh`: `never_delivered` dropped from the read | 3 | `FAIL  a never-delivered channel does NOT read as 'nothing new'` |
| T25 | `maildir.sh`: a frontmatter value truncated at the first tab | **0 → 3** | see below |
| T26 | `fs.sh`: the `date -d` capability check removed | 3 | `FAIL  a date(1) with no -d is REPORTED, not a silent no-op` |
| T27 | `inbox.sh`: a state file created with nothing to record | 1 | `FAIL  reading a never-delivered channel writes no state file` |

**The one that mattered: a guard bypassable by recomputing its input.**
`logchan_scan` discards a composed `channel:ts` dedupe key carrying a newline
or tab, and its comment calls itself the third instance of that class. But it
keeps `ts` and `channel` **raw** on the message record — correctly, they are
for display and go inside the fence — and `_inbox_read_log` then **rebuilt the
key from those raw fields, without the guard**. The seen-sets travel as
newline-delimited lists, so `"ts": "111\nD0:999"` became two `seen_keys`
entries and the sender chose which future message was silently suppressed: no
count, no `unreadable`, no error. The domain case was green throughout, exactly
as the maildir one was. A guard that can be bypassed by recomputing its input
is not a guard, so the scan now emits the key it used and there is nothing left
to recompute. **Fourth instance of the delimiter class; the fifth is T25.**

**T25 — the frontmatter tab.** The parser emits `<key>\t<value>` and took the
field after the first tab, but the value is **peer-written**. A peer sending
`from: athena<TAB>anything` parsed as exactly `athena` — the reader's own
identity — so the message was classed as the reader's own outgoing mail, never
acked, and re-listed on every read forever: a wedge the **sender** chose. The
first fixture measured a zero because it truncated to `peer` rather than to the
identity, which proved the truncation but not the consequence; the fixture now
claims the reader's own identity, and all three cases redden.

**What the reviewers found that 27 mutations could not.** Every one of these is
a check that was **absent**, or present but shadowed by another check firing
first — and mutating a check that does not exist is not a thing you can do:

| Finding | Why no mutation reaches it |
|---|---|
| `maildir_validate_message` had **no production caller** — D-22/D-23 held in the domain and nowhere a message travels | Deleting the rule reddened the domain cases, which pass. Nothing asserted it at the boundary, so nothing could tell enforced from unwired. |
| `maildir_is_unread` admits any non-dot name, so a peer-delivered `notes.md` was read, rendered, then refused by the ack — re-reported every read **forever**, with the refusal naming no filename | Two correct-looking checks in the wrong order. Each mutates to a red; the *combination* is the defect. |
| `inbox_lock_try` returned 0 for both "newly acquired" and "already ours", so the ack's trailing sweep released a lock it never took | Harmless *today* because that sweep sits after the state write — so it is a property of **call ordering**, not of the lock code, and no mutation expresses "correct for a reason that will not survive a reorder". |
| Framework called an adapter directly (`inbox_lock_release` in the EXIT trap) and re-parsed the resolved record with its own `awk -F'\t'` | A layering violation changes no behaviour. It is the *next* delimiter bug's entry point, not this one's. |
| A `date(1)` without `-d` disables retention permanently and silently | The mutation is the *environment*, not the code. Nothing on this machine could have produced it. |

### The standing review question, second pass

Applied again after the first sweep, it kept paying:

- a declared `log` channel whose file has **never existed** read as "nothing
  new" through `read-inbox` — `inbox-status` had it right, and the read is the
  command an operator reaches for when a channel looks quiet, so it was where
  the distinction was most needed and least present;
- a **non-conformant file** in a maildir was neither reported nor readable —
  silence, or a permanent wedge, depending on where you looked;
- a **missing `date -d`** turned the whole retention subsystem into a no-op
  that reports success on every ack.

Three more instances of one shape: *the absent thing reads as the fine thing.*

### Third round — the judge, re-run once it could speak

The first three `critic-review` runs on this branch printed a BLOCKED verdict
with an **empty body**: the runner grepped the report for `- [category]` lines
and the critic had formatted it otherwise. Fixed in this branch
(`ai/bin/critic-review`), and the round below is what it had been trying to say.

| # | Mutation (the defect, re-applied) | Cases reddened | First failure |
|---|---|---|---|
| T28 | `maildir.sh`: an unterminated `---` block harvested to EOF | 4 | `FAIL  an unterminated frontmatter block parses as NO frontmatter` |
| T29 | `read-inbox`: the `--json` untrusted marker removed | 1 | `FAIL  --json declares its bodies untrusted` |
| T30 | `read-inbox`: the render's status + emptiness check removed | **0** | see *Measured zeros* |
| T31 | `inbox-status`: the `Fix:` reverts to naming `inbox-doctor` | 1 | `FAIL  the Fix: does not send the reader to a command that does not exist` |

**T28 — the worst defect in the whole ticket, and it shipped green.** The
contract fixes frontmatter as fenced by `---` on the first line **and a
matching `---`**. Without the closing fence the parser harvested every
`key: value`-shaped line to EOF while `maildir_body` emitted nothing. So a
message whose body happens to be `key: value`-shaped — a decision line, a log
excerpt, a quoted `Subject:` — parsed as perfectly good frontmatter, passed
validation, **rendered with an empty body, and was acked into `.acked/`**.
Peer content silently destroyed *and* recorded as ingested, in the skill whose
entire purpose is that mail is never lost quietly. The reviewer reproduced it
end to end on a message reading *"The decision is: do not deploy on Friday."*

Nothing in ~440 cases caught it, and no mutation could have: the suite only
ever fed **well-formed delimiters**, and this is the one malformation that
yields "conformant, with an empty body". Sabotage mutates the code; it cannot
invent the input class the fixtures never contained. The pairs are now
buffered and emitted only once the closing `---` is seen, so an unterminated
block yields `{}` and routes down the non-conformant path — counted, not
rendered, not acked, left on disk intact.

**T29 — `--json` emitted bodies with no marker at all.** Raised independently
by the ADR reviewer and the critic. The in-code justification was that a caller
piping the document into unprompted output "has broken the rule on its own
side" — doctrine, not a boundary. The ordinary caller of this skill is the
agent itself, and this flag was the single documented path putting peer bodies
into context unmarked, while `SKILL.md` promised two lines under the `--json`
synopsis that every body arrives inside a nonce-carrying fence. A literal text
fence would cost the flag its point, so the marker travels as fields: the same
per-render nonce, the exact marker strings, and the notice.

### Measured zeros

**T30 — the render's status-and-emptiness check.** `$(...)` discards the inner
exit status, so `printf '%s' "$(jq ...)" | fence_render || exit 1` would, on a
jq failure, emit an empty fence, succeed, and **walk on to the ack**: header
says "N message(s)", fence is empty, N messages marked consumed. `lib/inbox.sh`
names this hazard in two places and guards it; the Framework copy had neither.

It cannot be reddened, because `logchan_scan` already coerces every
peer-controlled field with `tostring`, so no input this suite can construct
makes the render fail. The honest label is the one this file already uses for
S12: **defence in depth, not a tested check.** It is kept anyway — the
manager declined exactly this "unreachable today" argument for itself, and the
Framework copy is no safer for sitting nearer the surface. Nothing protects it;
this table must not imply otherwise.

### Fourth round

| # | Mutation (the defect, re-applied) | Cases reddened | First failure |
|---|---|---|---|
| T32 | `inbox.sh`: the doorbell bump's failure swallowed with `\|\| true` | 2 | `FAIL  I-5 a PRE-EXISTING doorbell has its mtime advanced, not merely kept` |
| T33 | `inbox.sh`: the doorbell not bumped at all | 2 | same |
| T34 | `lock.sh`: a missing `flock(1)` reads as a contended lock | **0 → 4** | see below |

**T32 — and why the old case could not have caught it.** The ack's doorbell
bump was `fs_bump_doorbell ... || true`, directly under a comment saying that
without it the move "rings no bell at all and leaves the peer to poll, **which
the contract forbids**". An unwritable read directory or an `.event` replaced
by a non-regular file produced a clean exit 0 with the peer left waiting.

The existing assertion was `ls .event | wc -l` = 1 — **existence, not the
bump**. The doorbell's semantics are an mtime/attrib change (`touch` on an
existing file is ATTRIB-only, which is exactly why a waiter must watch
`attrib`), and on any *live* channel `.event` already exists because the writer
maintains it. So the case only ever exercised **creation** — the path the
contract calls optional for a reader — and passed for the deployed case whether
or not the bump happened. The fixture now pre-dates `.event` to 2020 and
asserts the mtime advanced; both mutations redden on it.

The failure is now reported and deliberately **not** fatal: the move already
happened and is durable, so failing the ack would report a loss that did not
occur. What is refused is the silence.

**T34 — an absent `flock(1)` is not a contended lock.** `inbox_lock_try`
answers 1 for "another session holds it", and `_inbox_sweep_due` treats that as
"not an error for a count" — correct, by contract. On a host without util-linux
the *same 1* meant the sweep never ran, the rotated generation was kept
forever, and every count exited 0 saying nothing. `bin/read-inbox` already
refused to ack without `flock`, so the asymmetry was one-sided: **the loud path
checked and the quiet path did not.** Reported once per process, non-fatal
(counting and `--peek` are correct without it), same shape as
`fs_require_date_d`. Two absent-capability gaps in one subsystem, both found by
asking what happens when the input is missing rather than wrong.

### Not fixed, raised instead

- **`ai/bin/critic-review` rides this branch (scope).** The judge's own runner
  is modified by the branch it judges. The fix is isolated in its own commit
  and was load-bearing for this very review — three BLOCKED verdicts printed
  no findings before it — so it is left here and flagged to the admiral as a
  split-or-keep call at merge time rather than decided unilaterally.

**Later (2026-09-19):** the gate change this record describes — declaring the
two dark suites by hand and widening the "every self-test on disk is declared"
rule to three globs — was **superseded by DND-209** (`harness-gate` discovers
and runs every `**/test/self-test.sh` repo-wide, scoped to committed source).
DND-209 landed on main while this branch was in review and its discovery
already covers both suites, so the hand-declaration was dropped in the merge.
The finding that produced it stands: this suite was dark, and nothing ran it.

---

## 2026-09-19 — DND-188: the SessionStart hook

- **Domain:** athena:inbox (the notice slice)
- **Date:** 2026-09-19
- **Code under test:** `ai/hooks/athena-inbox-poll.sh`, plus its two wiring
  sites — `ai/hooks/registry.json` and `EXEMPT` in `ai/bin/check-guard-messages`
- **Suite run:** `bash ai/hooks/athena-inbox-poll.self-test.sh </dev/null`
  (no network; every case gets a fake `$HOME`, a private `ATHENA_INBOX_ROOT`
  and its own `git init` repo under one `mktemp -d`; ~5s wall)
- **Baseline:** `VERDICT: PASS (165 cases)` (91 at the first pass; 21 added
  after the sabotage run, 46 more across eight critic rounds — see *The four
  zeros* and *What the critic found that sabotage did not*)
- **Runner:** 42 mutations, one at a time, full suite after each, restored by
  `cp` from a backup taken before the run. S24–S42 were added after the review
  rounds (see *What the critic found that sabotage did not*). **42 mutations,
  42 reddened, no measured zeros** — S1–S35 in one full pass, S36–S38 in a
  second (after a sibling captain's run clobbered the shared runner, below),
  S39–S42 in a third.

The mutations were applied by an exact-substring replace that asserts the
anchor occurs **exactly once** before writing, as DND-183's run did. That
discipline earned its keep twice here: one anchor reported
`ANCHOR NOT UNIQUE (0)` (an indentation mismatch) rather than silently
skipping, and the runner's own first pass reported **all 23** anchors absent —
`restore()` used a bare `for f`, and because bash locals are **dynamically
scoped** that overwrote `run_one`'s `f`, pointing every mutation at the suite
file instead of the file under test. A runner that mutates the wrong file
produces 23 green runs, which reads as "this suite is dead".

### What the suite proves

| # | Mutation | Cases reddened | Failure string(s) |
|---|---|---|---|
| S1 | the attempt marker is stamped AFTER the work instead of before | 3 | `FAIL  F-7 a failing run DOES stamp the attempt marker` |
| S2 | a FAILED poll also stamps the success marker | 10 | `FAIL  F-5 the precondition holds: no success marker exists` |
| S3 | a clean run no longer clears the warn marker | 1 | `FAIL  F-8 a succeeding run clears the warn marker` |
| S4 | the warning is rate-limited by the POLL marker, not its own | 8 | `FAIL  F-5 a never-successful setup warns on the first attempt` |
| S5 | staleness judged on the ATTEMPT marker instead of success | 6 | `FAIL  F-5 a never-successful setup warns on the first attempt` |
| S6 | an absent marker counts as FRESH rather than stale | 7 | `FAIL  F-5 a never-successful setup warns on the first attempt` |
| S7 | the health clause NAMES the channels instead of counting them | 1 | `FAIL  R8 a channel that cannot be counted is surfaced, not shown as zero` |
| S8 | the never-delivered clause is dropped | 2 | `FAIL  R8 a channel that has NEVER received anything is surfaced` |
| S9 | the unreadable-registry-entry clause is dropped | 2 | `FAIL  R12 an unreadable registry entry is surfaced` |
| S10 | the stdin read is unbounded (`timeout 2 cat` → `cat`) | 1 | `FAIL  the stdin read is bounded — an open pipe does not hang session start` |
| S11 | the reason log is never trimmed | 1 | `FAIL  the reason log is bounded to 200 lines` |
| S12 | zero unread announces itself every session | 6 | `FAIL  F-3 zero unread produces no stdout at all` |
| S13 | `--dry-run` writes the real marker family | 2 | `FAIL  --dry-run writes no attempt marker` |
| S14 | the private `umask 077` is dropped | 3 | `FAIL  the attempt marker is created 0600` |
| S15 | any non-empty stdout counts as a successful poll | 4 | `FAIL  R9 non-empty but unparseable output does NOT stamp success` |
| S16 | the notice names `read-inbox` whether or not it exists | 2 | `FAIL  R11 with read-inbox absent the notice says so` |
| S17 | the markers move into the `athena-slack-*` namespace | 4 | `FAIL  F-10 the hook shares no marker path with the athena-slack-* family` |
| S18 | the warning is emitted as a bare text line beside the JSON | 8 | `FAIL  F-9 the stale warning travels as one well-formed JSON object` |
| S19 | the notice reports the newest message body alongside the count | 2 | `FAIL  F-2 no substring of a message body reaches the notice` |
| S20 | the hook's entry is removed from `registry.json` | 2 | `FAIL  F-11 the hook is registered on SessionStart with the "" matcher` |
| S21 | the `EXEMPT` classification is removed from `check-guard-messages` | 1 | `FAIL  F-12 the hook is EXEMPT with a stated reason, not carrying a fake deny path` |
| S22 | a `UserPromptSubmit` entry is added for the hook | 2 | `FAIL  F-11 no UserPromptSubmit entry is registered for any hook` |
| S23 | `inbox-status`'s stderr is relayed into the hook's reason log | 1 | `FAIL  R10 the wrapped command's stderr does not reach the reason log` |
| S24 | the never-delivered clause drops its `.kind == "log"` filter | 2 | `FAIL  R13 an unwritten-to maildir is not announced as a missing producer` |
| S25 | the wrapped command loses its `timeout` ceiling | 2 | `FAIL  R14 a hanging inbox-status does not hang session start` |
| S26 | the unreadable-entry `Fix:` collapses back into the generic one | 3 | `FAIL  R15 the unreadable-entry Fix names something actually actionable` |
| S27 | the two warnings share one rate-limit marker again | 2 | `FAIL  R8 a fresh OUTAGE warning does not suppress a HEALTH warning` |
| S28 | a non-opted-in repo counts as a successful poll again | 5 | `FAIL  F-4 a non-opted-in repo does NOT stamp success` |
| S29 | a non-opted-in repo clears the other project's warn markers again | 2 | `FAIL  F-4 a non-opted-in repo does not clear the outage marker` |
| S30 | the vanished-entry warning is dropped | 4 | `FAIL  R16 a vanished entry is announced, not silently treated as opt-out` |
| S31 | the per-project seen marker is never recorded | 4 | `FAIL  R16 a vanished entry is announced, not silently treated as opt-out` |
| S32 | the vanished-entry warning shares the `$HOME`-level health rate limit | 1 | `FAIL  R16 another project's health warning does not silence this one` |
| S33 | the inflated-count caveat moves back behind the rate limit | 1 | `FAIL  R17 the inflated count still carries its caveat` |
| S34 | a key that cannot be hashed disables the detector in silence | 1 | `FAIL  R16 a key that cannot be hashed is LOGGED, not silently inert` |
| S35 | `inbox_status_json` stops naming the session's repo | 5 | `FAIL  R16 a vanished entry is announced, not silently treated as opt-out` |
| S36 | the other-projects clause claims the doubt is unresolved again | 2 | `FAIL  R12 an unreadable registry entry is surfaced` |
| S37 | a repair never clears the vanished-entry rate limit | 2 | `FAIL  R16 a repair clears the vanished-entry rate limit` |
| S38 | an ABSENT repo key collapses into the quiet no-git-repo case | 1 | `FAIL  R16 an inbox-status without --repo-key is logged, not silently shared` |
| S39 | the marker family goes back to being shared across projects | 5 | `FAIL  F-8 a healthy SIBLING PROJECT does not silence this project's outage warning` |
| S40 | the health warning goes back to a shared rate limit | 3 | `FAIL  F-8 project A's health warning does not silence project B's` |
| S41 | an `inbox-status` without `--repo-key` degrades in silence | 1 | `FAIL  R16 an inbox-status without --repo-key is logged, not silently shared` |
| S42 | `inbox-status` stops answering `--repo-key` | 16 | `FAIL  F-6 a stale success plus a FRESH warn marker is silent` |

### The four zeros

Four mutations ran **green** on the first pass. All four were real gaps, and
all four are closed — the table above shows each reddening after the fix.

**S15 — the shape check on `inbox-status`'s answer.** Every fixture in the
suite reached the failing path through *empty* stdout, so replacing the entire
`type == "object" and (.channels | type == "array")` test with `true` changed
nothing. The claim it protects is this epic's standing question in its sharpest
form: an answer that cannot be **read** is not an answer of **zero**. The
difference is invisible on stdout — both are silent — and visible only in the
success marker, which is what lets the staleness warning eventually fire. New
cases **R9** drive non-empty-but-unusable output (unparseable, and well-formed
JSON of the wrong shape) plus a control proving the same harness does count a
good document.

**S9 — the unreadable-registry-entry clause.** `projects/` is multi-tenant; an
entry that fails to parse is dropped from the candidate set, and the session
whose entry it was then looks *exactly* like a session that never opted in.
`inbox-status` reports the drop as `failed_candidates` and the hook renders it,
but nothing asserted that. New case **R12**, which also pins the disclosure
rule: the clause counts and does not name, because every other entry belongs to
a different tenant.

**S16 — the `read-inbox` switch.** `F-1`'s `contains "read-inbox"` passes on
*either* branch, because the not-installed sentence names the command too. The
assertion looked like it protected the switch and protected nothing. New case
**R11** asserts both branches by their distinguishing text.

**S23 — the wrapped command's discarded stderr.** `inbox-status` refuses on
stderr with paths and channel names in the clause, and the hook discards that
stream rather than relaying it. No fixture put anything identifiable on stderr,
so a mutation that logged it was green. New case **R10** puts the sentinel
there.

Closing S15, S16 and S23 needed a fixture the suite deliberately lacked: a
**stub `inbox-status`**, because the real one never produces non-empty-unusable
stdout, never has a `read-inbox` beside it (that ships later), and never puts a
recognisable string on stderr. The stub lives in a copied repo tree under the
case's tmpdir — the hook resolves its wrapped command from its own
`BASH_SOURCE`, so a copy of the hook picks up whatever is placed beside it, with
no `PATH` games and no mutation of the real skill. Every other case still runs
against the real `inbox-status`.

### What the run found in the fixtures, not the code

**A leak canary on one row of a fixture tests one row, not the claim.** S19
appended `tail -n1` of the channel file to the notice — a message body in the
pre-prompt position, the single thing `F-2` exists to forbid — and ran
**green**, because `plant_log_lines` put the sentinel on its *first* line and
`tail -n1` took the second. Every planted line now carries it.

**A fixture can be rejected by a grammar and still look like a fixture.** The
first draft of `R12` named its malformed entry `ZQXSENTINELDONOTLEAK.json`. The
registry's project-name grammar is lowercase-only, so that file was not a
*failed* candidate — it was not a candidate at all, and the case asserted
nothing while appearing to assert everything. It now uses a lowercase variant.

That second finding has a **consequence outside this ticket, recorded here
rather than fixed here**: a registry entry whose *filename* is not a legal
project name is invisible to `inbox-status` — not counted in
`failed_candidates`, not reported anywhere — so a project registered as
`Foo.json` is dark in exactly the way this epic has already paid for twice. It
belongs to the registry reader (DND-208 / `lib/descriptor.sh`), not to the
hook, and is raised to the athena-admiral in `dnd-188-report.md`.

### What the critic found that sabotage did not

The `athena-diff-critic` round found a **correctness** bug that 23 mutations
had not: the never-delivered health clause had no `.kind == "log"` filter.

`never_delivered` means opposite things for the two channel kinds. For a log
channel it is a genuine fault -- an unregistered producer and an empty channel
are identical on disk. For a **maildir** it is normal: the contract
(`ai/contracts/athena-inbox.md`) makes the read directory something the tool
that *sends* creates, so a declared peer mailbox nobody has written to yet is a
healthy channel waiting for its first message. `bin/inbox-status`'s own renderer
filters on `.kind == "log"` for precisely this reason; the hook's clause had
diverged from it.

The consequence was not cosmetic. `HEALTH_TEXT` would be permanently non-empty
for any project declaring a peer mailbox, so the branch that clears
`WARN_MARKER` on a clean run could never execute -- and the next **real** outage
would inherit a fresh warn marker from a non-fault and be rate-limited into
silence by it. That is the S21 failure the hook's own header argues against,
reached through a different door.

**Why no mutation found it.** Sabotage can only redden a claim some fixture
exercises, and the suite's single maildir fixture (`plant_mail`) *creates*
`from-peer/` before running -- so `never_delivered` was never true for a maildir
anywhere in 116 cases. The gap was in the fixture space, not the mutation set,
which is the one class a mutation run is structurally blind to. Closed by
**R13**, with a control asserting a never-delivered *log* channel still warns,
and pinned by S24 above.

The second critic round found three more of the same species -- claims no
fixture reached, so no mutation could reach them either:

**The wrapped command had no ceiling.** The hook bounds its stdin read with
`timeout 2 cat` and states why (an inherited open pipe never sees EOF), but ran
`inbox-status` unbounded. `inbox-status` scans channel files with no timeout of
its own, so a very large `.jsonl` or an inbox root on a stale mount blocks
SessionStart for as long as it takes -- the same hazard class, on the other of
the hook's two blocking inputs, with `timeout` already in hand. Now
`STATUS_TIMEOUT_SECONDS` (10s); an expiry is just another failed poll, which the
existing path already handles. **R14**, pinned by S25.

**One marker rate-limited two concerns.** `WARN_MARKER` gated both "the poll is
not working" and "the poll works and found a fault downstream". Those have
different owners and very different lifetimes: a benign health fault (a declared
log channel whose producer was never registered) is a state the reader may live
with for weeks, re-stamping every six hours, and a real outage beginning shortly
after one of those stamps was rate-limited into silence by a warning about
something else. That is this file's own S14 doctrine violated from the inside.
Split into `athena-inbox-last-warn` and `athena-inbox-last-health-warn`. **R8**
gains both directions of the independence claim -- the door 24 mutations left
open, because S4 only ever exercised poll-vs-warn, never warn-vs-warn. Pinned by
S27.

**A `Fix:` that could not answer the question it promised.** The health warning
ended "run inbox-status from this project to see which" for every clause. True
for the channel-level ones; false for `failed_candidates`, because inbox-status
is counts-only for tenant privacy and can never say *which* registry entry
failed to parse -- naming them would enumerate other tenants. An agent following
it re-ran a command that returned the same number. That is the defect **R11**
exists to prevent, arriving through the guard-message convention instead of the
read-step pointer. The clause now names what the reader can actually check, and
says outright that inbox-status cannot narrow it. **R15**, pinned by S26, with a
companion case proving the channel-level clauses kept their pointer rather than
both being flattened into one vague sentence.

**The worst of them, found in the third round: "not opted in" was recorded as a
SUCCESSFUL POLL**, which made the outage warning this hook exists to raise
structurally unreachable.

`inbox-status` answers `{"channels":[],"failed_candidates":0}` and exits 0 for
any project with no matching registry entry — correctly, per the contract: *not
opting in is not a fault*. The hook's `POLL_OK` test asked only whether
`.channels` was an array, so that answer stamped `SUCCESS_MARKER` and cleared
both warn markers. But the marker family is **per-`$HOME`** while the poll
outcome is **per-cwd**, and the hook is registered with the `""` matcher — it
runs in *every* repo on the machine. One session in walt_ui or gen_saas
refreshed the success marker, so the six-hour staleness test could never come
due, however broken the opted-in project's poll was. The same door made a
**deleted or clobbered registry entry** — the silent-dark failure `CLAUDE.md`
names for this registry — look exactly like never having opted in, in the one
piece of state that could have told the difference.

The fix is a third state. Not opted in is **neither** success nor failure:
nothing stamped, nothing cleared, nothing printed, one line in the log. The
opted-in project's markers are then only ever moved by that project's own
sessions, which is what makes them mean anything — and a project whose entry
vanishes stops stamping success, so its own next session crosses the staleness
window and warns.

**Why 27 mutations missed it.** `F-4c` was the only no-entry fixture, and it
asserted stdout, rc and stderr — everything about that path *except* the marker
state, which is the one thing it changes. And no case in the suite ever ran two
different repos against one fake `$HOME`, so the cross-project mechanism had no
fixture at all. Again a hole in the fixture space rather than the mutation set.
Closed by the new `F-4` marker assertions and a two-repos-one-`$HOME` case;
pinned by S28 and S29.

**Round four closed the other half of the same door, which round three had
opened without noticing.** Making "not opted in" stamp nothing stopped the hook
*lying* about success; it did not make the resulting absence of success
**speak**. A project whose registry entry is deleted or clobbered answers
`{"channels":[]}` exactly like one that never opted in, so the hook stamped
nothing, cleared nothing and printed nothing — forever. The staleness warning is
reachable only under `POLL_OK=0`, and that path is `POLL_OK=1`. Worse, the
record written in round three asserted the fix had this property ("a project
whose entry vanishes stops stamping success, so its own next session crosses the
staleness window and warns"), which the code did not do — **a dated record
claiming a behaviour the code lacks is worse than no record**, and it is
corrected here rather than quietly dropped.

The fix needs memory that `inbox-status` cannot have, because it cannot know a
project's history: a **per-project** marker, `athena-inbox-seen/<hash>`, stamped
whenever a session does resolve channels. Channels once, none now, is then a
distinguishable state and gets a warning naming both repairs — restore the
entry, or delete the marker if the project was retired on purpose. The identity
is the contract's own key, hashed so the filename neither is a path nor
discloses which projects this machine has registered. (**As first written, this
round took that key by sourcing the skill's `lib/fs.sh` and calling
`fs_git_common_dir` in a subshell. Round five replaced that** — it is a
Framework-bucket file calling an adapter directly, and a second computation of
the identity rule free to drift from the contract. The key now arrives as
`repo_key` on the status document. The sentence is corrected here rather than
left standing, because a reader grepping `fs_git_common_dir` lands on this
paragraph first.) Its
rate limit sits beside it, per project: a fault about one project must not be
silenced by a warning about another. **R16**, pinned by S30–S32.

**And a count known to be wrong was being announced as fact.**
`state_unreadable` means the channel was re-read from offset 0 with empty
seen-sets, so `new` includes messages already acked. The caveat lived in
`HEALTH_TEXT` → `WARN_TEXT`, which the warn rate limit blanks — so for up to a
whole six-hour window the pre-prompt notice read "12 new in slack" with nothing
marking it as inflated. The rate limit on the *warning* was laundering the
*number*. The caveat now rides the number, where no rate limit can strip it,
the way `bin/inbox-status` attaches its own per-channel `Fix:` unconditionally.
**R17**, pinned by S33.

**Round five: the detector could disable itself in silence, and it reached
below the skill's public surface to do it.** Two findings on one mechanism.

The per-project key was derived in the hook by sourcing `lib/fs.sh` and calling
`fs_git_common_dir`. That is a **Framework-bucket file calling an adapter
directly** — `lib/fs.sh`'s own header reads "SIDE EFFECTS. The only file I/O in
the skill, plus the one `git` call" — and it left two independent computations
of the identity rule free to drift from each other and from the contract, which
is the bug this facility has already paid for twice. `inbox_status_json` now
emits `repo_key` on **both** branches (including the not-opted-in one, which is
exactly when a caller needs it), and the hook reads it out of the public
surface like every other field. Pinned by S35.

And every way of failing to derive that marker name disabled R16 **silently**:
no `sha256sum`, a failed sourcing, an unhashable key — all produced an empty
marker path, whose `stamp` no-ops, so the vanished-entry warning could never
fire and nothing anywhere said so. An inert detector is indistinguishable from a
healthy project, and this is the detector whose whole purpose is to make a
silent-dark registry speak. Each failure now logs a `Fix:`; the one case that
legitimately has nothing to remember — a cwd in no git repository — stays quiet,
and a case asserts that too, so the logging cannot be satisfied by logging
always. Pinned by S34.

**Rounds seven and eight, the last three findings.** The
`failed_candidates` clause rendered **only** on the branch where its own wording
was false: `inbox_entry` makes no-match-plus-unparseable-candidate a hard
refusal (empty stdout, exit 1), which reaches the hook as a *failed poll*, so by
the time a health clause can render at all this project's entry has been found
and the unreadable ones provably belong to somebody else. It said "one of which
may be this project's" anyway, and every R12/R15 fixture called `register` first
— so no fixture ever visited the branch the wording was written for, and nothing
could contradict it. Reworded, and the hard-refusal branch now has a case of its
own. **S36.**

`SEEN_WARN_MARKER` was exempt from the S21 clear-on-success discipline the other
two markers follow, so an entry restored and clobbered *again* inside the window
was silenced by a warning about the fault that had already been repaired —
skipping the rule at the one failure with no diff and no undo. The existing
rate-limit case passed either way; a case now asserts the **repair** re-arms it.
**S37.**

And `.repo_key // ""` collapsed *absent* into *empty*. Empty means "no git
repository here", which legitimately has nothing to remember and stays quiet;
absent means the `inbox-status` beside this hook predates the field — reachable
through hook/skill version skew, since `settings.json` wires one tree's hook
path and `STATUS_BIN` resolves from that tree — and it silently made the whole
vanished-entry detector inert while looking exactly like a healthy project. That
is the round-five claim ("every way of failing to derive that marker name is
LOGGED") escaping through its last door. **S38.**

**The review floor found the last and largest instance: the marker family was
still `$HOME`-global, so ONE PROJECT'S SESSION MOVED ANOTHER PROJECT'S
MARKERS.** Round three had fixed this for a repo that never opted in (the
`OPTED_IN` third state) and stopped there. Between two *registered* projects it
was untouched, and reproducible on this machine today, whose registry holds
several entries: a healthy sibling refreshing the shared success marker kept a
broken project's outage warning six hours away **forever** — the same
structurally-unreachable warning the third state was added to close, reached
from a sibling tenant instead of an unrelated repo — and one project's health
warning rate-limited another's.

Every fixture the suite had for this used a second repo that was *unregistered*,
which is the case that was already fixed, so no mutation could have reddened it.
The whole family — success, both warn markers, the seen marker — is now keyed by
a hash of the project identity; only the attempt marker and the reason log stay
global, because they answer "did this machine attempt, and why did it stop",
which is not a question about any one project.

That fix needed the identity **on the failure path**, where the status document
does not exist — a refusal prints nothing. Rather than let the hook recompute
it (the drift this design refuses), `bin/inbox-status` grew **`--repo-key`**: it
reads no registry, cannot fail, and answers the one question that still has an
answer when everything else has failed. The degraded route — an `inbox-status`
too old to know the option — falls back to the shared names and **logs a `Fix:`
first**, because silently sharing this state is the defect being closed. S39–S42.

**The floor's nits, two of which had a wrong failure direction.**
`STALE_SECONDS` and `WARN_INTERVAL_SECONDS` were read from the environment
without the `case ''|*[!0-9]*)` guard every other number in the file carries.
Unguarded, `[ "${age}" -ge "abc" ]` errors, `marker_is_stale` reads that error
as **not stale**, and a typo in an environment variable therefore **suppressed**
the warning instead of failing loudly — the wrong direction for the one
mechanism whose job is to break a silence. And `F-4a`'s stripped `PATH` omitted
`dirname`, without which the hook cannot locate itself at all, so that case was
measuring a different failure than the one it names.

**Left as raised, not fixed:** nothing prunes `athena-inbox-seen/`, so a repo
that is deleted or moved leaves its markers behind forever. Harmless — a stale
hash is never consulted again — but there is no reaper and nothing documents
one.

### A harness hazard this run measured

**The session scratchpad is shared between concurrently running captains**, and
a sibling's `sabotage.sh` overwrote this one's mid-ticket, at the same path. The
overwritten runner then executed against *this* worktree under a `nohup`, and
the only reason nothing was corrupted is that the sibling's runner also installs
a restoring `trap`. Two agents, one directory, generic filenames. A sabotage
runner writes mutations into a real tree, so this is the one class of shared file
where a collision can silently corrupt another agent's work. Namespace the
runner (`<scratchpad>/<ticket>/`), and treat a generic filename in the session
scratchpad as unsafe.

### Not exercised by this run

The hook is a thin wrapper; everything below it — name grammar, descriptor
validation, dedupe, offsets, maildir rules — belongs to DND-183's run above.
Still unexercised anywhere: the fence renderer, the consumer lock, the atomic
state writer, the doorbell waiter, and `read-inbox` itself.
