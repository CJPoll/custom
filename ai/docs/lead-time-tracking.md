# Lead-time tracking for fleet tickets

**Kind: living normative document.** Amended in place, per `~/dev/custom/CLAUDE.md`
→ *Documentation conventions*. The worked-backfill section is a dated snapshot
and is labelled as such.

## What is measured

**Lead time = the interval from when a captain starts working a ticket to when
that ticket is fully deployed in production.** Cody's definition, precisely:

- It **starts at captain dispatch**: the ticket's move to `In Progress` in
  Notion (owner decision, Cody, Slack 2026-09-30 ~04:05Z, relayed by the
  coordinator and recorded on DND-1318).

- A ticket that **deploys to prod**: lead time ends when the production
  deployment completes.
- A ticket that **does not deploy** (doc-/test-/harness-only, and possibly other
  kinds — deliberately not a fixed whitelist): lead time ends when the
  **post-merge pipeline completes**, which is not quite deployment.

This is a **harness capability** and works across the fleet's forges. The fleet
ships on both GitHub (`gen_saas`, `custom`) and GitLab (`walt_ui`), so the tool
detects the forge from the repo's `origin` remote and reads whichever CI applies.

**Later (2026-09-19):** first written GitHub-only (a single hardcoded
`Post-Merge Deploy` workflow, end = that run's completion or, for a no-CI repo,
merge). Superseded the same day when Cody noted this is a harness change that
must work across projects: `~/dev/walt_ui` deploys on **GitLab**
(`.gitlab-ci.yml`, a `deploy` stage, Porter/GCP), read via `glab`, not `gh`. The
end marker is now a forge-independent 3-tier rule (below), and deploy detection
is **per-ticket** rather than per-repo. Nothing about a specific repo is
hardcoded; the deploy workflow/stage is matched by pattern and is overridable via
`LEAD_TIME_DEPLOY_RE` (GitHub workflow name) / `LEAD_TIME_DEPLOY_STAGE` (GitLab
job stage).

## The chosen markers

| | Marker | Where it lives |
|---|---|---|
| **START** | the ticket's first move to `In Progress` (captain dispatch), or its latest re-dispatch from a park (*Decisions* → *A park restarts the start*) | a date property on the ticket, stamped by `mark-in-progress`: DND Tickets' `In Progress at`, or the work tracker's property named in the private overlay |
| **END** | first of the 3 tiers below that exists | GitHub Actions runs / GitLab pipeline jobs / landing time (the merge, or the push that carried it) |

### The END rule — one 3-tier rule, forge-independent

For a landed ticket, gather three candidate end times and take the **first that
exists**. This maps exactly onto Cody's definition:

1. **DEPLOY completed** — the deploy step's completion time.
   - GitHub: completion (`updatedAt`) of the successful workflow run for the
     merge commit whose workflow name matches the deploy pattern (default
     `/deploy/i`; `gen_saas`'s `Post-Merge Deploy` matches).
   - GitLab: the latest `finished_at` among **successful jobs in the `deploy`
     stage** of the merge commit's pipeline on the default branch.
   - GitLab, for a repo whose `idle_workflow` is an idle pipeline selector
     (`gitlab:ref=main,source=push,child=deploy`, DND-1952): the successful
     finish of the child pipeline that the merge commit's pipeline (on that
     ref, from that source) started through the named trigger job. A deploy
     that runs as a child pipeline (`trigger: include … strategy: depend`) has
     no jobs in its parent's job list, so the stage rule cannot see it.
2. **POST-MERGE PIPELINE completed** — if no deploy step ran (a doc-/test-only
   ticket), the completion of the post-merge pipeline/run itself.
   - GitHub: latest successful non-deploy run for the merge commit.
   - GitLab: latest `finished_at` among all successful jobs in that pipeline;
     with a selector, the selected pipeline's own successful `finished_at`.
3. **LANDING time** — if there is no post-merge CI at all (e.g. `~/dev/custom`,
   no CI, no deploy), the time the change landed on the base branch: the forge
   merge (`mergedAt` / `merged_at`), or, for a GitHub PR that is CLOSED without a
   merge, the push that put its change on the base (below).

With a selector, these landings read **could not measure**, with the reason,
and never take tier 3:

- the selector matches no pipeline for the landing;
- the pipeline has no trigger job by the `child=` name, or its child is in
  another project;
- the pipeline, trigger job or child sits at `manual`, which says nothing
  about the deploy (*Why GitLab reads the deploy job, not the whole pipeline*);
- a forge read failed (the scan also reports SCAN INCOMPLETE).

A landing whose pipeline, trigger job or child is still waiting or running
(`waiting_for_resource` included) is **not concluded**. It also reads could not
measure, and it is marked `ci_pending`. `--meta`'s `scanned_through` stops
before it, and `lead-time-phases --ingest` does not ledger it yet, so the next
scan reads it again once it can end. A failed or canceled deploy ends no
deploy, as on GitHub: the row takes the next tier that exists, and
`lead-time-phases` marks a CI repo's landing-ended lead n/a.

**Later (2026-09-30, DND-1317):** tier 3 was "the merge commit time
(`mergedAt` / `merged_at`)", and a PR with no `mergedAt` read `via=open`.
Superseded: `~/dev/custom` lands by a fast-forward push of the gated, rebased
head (`athena:merge-boarding`), so GitHub shows those PRs CLOSED, never MERGED.
Measured 2026-09-30: `lead-time --pr 127` printed `via=open lead=n/a` while its
change was on main as `6da07d1b`, and the window scan missed #127, #125, #123
and #122 outright. The same change made `--slow` keep could-not-measure rows;
it had dropped every row without a lead, so "could not measure" read as "not an
outlier".

### A CLOSED PR's landing (GitHub)

A PR that is CLOSED with no `mergedAt` is judged by its **change**, not its state:

- **Landed** when its head is on the base, or every one of its non-merge
  commits is on the base, one base commit each (a rebase), or its whole diff's
  patch-id is one base commit (a squash). A commit is on the base when its
  patch-id is, or when a base commit with the same subject has its
  zero-context patch-id (`git diff -U0`): the base edited a line next to the
  change before it landed, so only the context differs (DND-1491). The second
  kind counts only when that subject names one base commit in the range, so a
  generic subject never pairs on a near-empty patch. A multi-commit PR squashed
  after such a context edit matches neither patch-id kind; its whole diff's
  zero-context patch-id then names the squash, counted only when that base
  commit's subject is the PR title (a trailing ` (#N)` aside) and names one
  base commit in the range (DND-1520). The landing time is the **push** to
  `refs/heads/<base>` that first carried that commit, read from GitHub's
  repository activity log (`gh api repos/{owner}/{repo}/activity`). The row
  carries `landed_via: "push"` and `landed_commit`; a forge merge carries
  `landed_via: "merge"`.
- **Closed** (`via=closed`, no lead) when none of it is on the base.

  **Later (2026-10-03, DND-1520):** a multi-commit PR squashed after the base
  edited its diff context read closed, as a known residual. The title-gated
  zero-context match in the Landed bullet closes it for the PR's own title;
  under any other subject it reads could-not-measure.
- **Could not measure** (`via=unmeasured`, with the reason on the row and on
  stderr) when only some of its commits are on the base, or its change is on
  the base only under another subject (a context-edited squash, retitled, included), or a base commit (named in the reason)
  shares a commit subject with it but not its change (a conflict-resolved or
  edited landing), or it has no commit of its own off the base, or no push carried the
  landed commit, or a push before the carrying one could not be read.
  `--slow` keeps these rows (lead `null`, `unmeasured_reason` set): a row that
  cannot be shown fast must not read as "not an outlier".

  **Later (2026-10-01, DND-1491):** every same-subject, different-patch base
  commit read could-not-measure. Superseded for a patch that differs only in
  context: that is the landing. Measured: PR #83 read could-not-measure with
  no landed commit while its change was on main as `38d76482`, landed by
  the 02:20:24Z push on 2026-09-27; main had edited a line next to its hunk.
  `lead-time-phases` skipped the row as "not ledgered" without the reason.
  The same change also superseded "closed" for a PR whose change is on the
  base only under another subject, with its context changed: it read closed,
  and now reads could-not-measure, because that match proves neither.
- A lookup that cannot run (the activity log, a `git fetch` of the base and
  `refs/pull/<n>/head`, `git patch-id`) is a failed probe, so the run ends
  `SCAN INCOMPLETE`.
- The scan window is by **close** time: every row carries `closed_at`. A push
  lands a PR seconds to minutes before its close, so a scan between the two
  cannot list it, and the next scan keeps it though it landed before `--since`.
  The JSON key `merged` holds the landing time, whichever way it landed.

**Every PR/MR row carries its own head** as `head_commit` (GitHub
`headRefOid`, GitLab `sha`), whichever way it landed (DND-1490). A squash
merge's `merge_commit` is a commit the forge made, so it is never the head
integration-gate, the critic or harness-gate saw; `head_commit` is, and
`lead-time-phases` joins receipts, verdicts and timings on it. A head the forge
did not give, or gave malformed (not a full lowercase sha), is `head_commit:
null` with `head_commit_unmeasured` naming why, never an empty string. A
direct-push row has no PR and no `head_commit`: its `landed_commit` is the head.

**Every row carries its landed commit or says why not** (DND-1491):
`landed_commit` (a push landing) or `merge_commit` (a forge merge), and
`landing_commit_unmeasured`, which is `null` when one of them is set and
otherwise names why neither is: the landing could not be decided (with that
reason), it closed without landing, it is open, or the forge gave no merge
commit or a malformed one. Never an empty string. `lead-time-phases` quotes
that reason when it leaves a row out of the ledger, and names a row with
neither a commit nor a reason as lead-time breaking this rule.

The window scan lists every PR **updated** since `--since` (`updated:>=`) and
filters on `closedAt` locally. GitHub's `closed:>=` qualifier omitted five
unmerged PRs closed inside the window (measured 2026-09-30). A GitLab MR closed
without a merge reads could-not-measure: landing by push is detected on GitHub
only.

This is Cody's offered simplification, made regular: a **single rule** yields a
consistently-available, trustworthy end for every ticket on every forge. It is
"slightly late" only in the benign sense that a deploy tail is included when a
deploy ran — which is exactly what "fully deployed" means.

### A direct push's landing (GitHub)

A landing is a push to the default branch, not a PR (DND-1009). `~/dev/custom`
lands most work by a fast-forward push, often with no PR at all, so a scan that
listed PRs only saw about one landing in ten. A `--since` scan on GitHub also
reads the default branch's activity log (the same reader the closed-PR rule
uses) and adds:

- **A push no PR row claims.** Its commits are the first-parent range
  `before..after`. It gives one row per ticket its commit subjects work, with
  the ticket parser the PR path uses (`TicketRef.subject_refs`): the refs in
  a subject's lead, before its first `": "`, else every ref in it. A ref
  after the lead is a mention. The row has `pr: null`, `ticket`, `landed_via:
  "push"`, `landed_commit` = the push's after sha, `commits`, and `merged` =
  the push time. A malformed after sha is `landed_commit: null` with
  `landing_commit_unmeasured` naming it (*Every row carries its landed commit
  or says why not*). A push naming no ticket gives one row with lead `null` and
  "no ticket in the pushed commits' subjects".

  **Later (2026-10-02):** this gave one row per ticket a subject *names*.
  Superseded: "DND-1812: … follows gen_saas DND-1768" landed as two custom
  rows, the second timed from DND-1768's dispatch with no critic PASS, so
  queue read n/a on a ticket the landing never worked.
- **A force push**: could not measure, "force push to base".
- **A PR merge no listed PR claims**: could not measure, never dropped.

A PR merge whose merge commit is a PR row's IS that PR's landing and adds no
row. A push's commits up to a PR row's landed commit are that PR's; only the
commits pushed on top of it give rows. Any other activity type in the window
(a merge queue, say) reads could not measure, never dropped. A range that
cannot be read is a failed probe tied to that push. GitLab MRs are read;
GitLab direct pushes are not, and the scan says so on stderr.

Delivery is at least once. A PR's change pushed before the PR closes is a
push row in a scan that runs between the two, and a PR row in the next. And
`--since` is inclusive, so the landing a cursor ends on is listed again.

`--meta FILE` writes `{scanned_through, landings, kept, incomplete}` for a
caller's cursor. `scanned_through` is the newest landing's window time
(`closed_at`) **before** `--slow`, so a window with no slow row still moves the
cursor. On `SCAN INCOMPLETE` it is the newest landing before the first one a
probe failed on, and `null` when a failure belongs to no single landing (no
token, a broken overlay). Neither caller uses that partial value (the
improver's watch scan, `lead-time-phases --ingest`): neither moves its cursor
on a `SCAN INCOMPLETE`.

`--since` takes `YYYY-MM-DD` (00:00:00Z that day) or RFC 3339 with a zone.
Anything else exits 1, like every other usage error, with a `Fix:` before
the repo is read. Exit 2 is never a usage error: it means the forge says a
requested PR/MR does not exist (gh's `Could not resolve to a PullRequest`,
glab's `404 Not found`). A forge that could not be read for it is exit 3,
could not measure, with a `Fix:` naming the forge's error: offline, no auth,
a rate limit, output that is not JSON, or a missing repository or project
(gh's `Could not resolve to a Repository`, glab's `404 Project Not Found`).

**Later (2026-10-01, DND-1510):** exit 2 meant "not found or the forge could
not read it", because both reached `run_scan` as a nil from the forge's
`facts`. Superseded by the split above: an offline or unauthenticated forge
read as a missing PR, the failed-lookup class one level below DND-1489. The
callers were swept: no caller runs `--pr`/`--mr`, and both window callers
(`lead-time-phases --ingest`, the improver's watch scan) already read 3 as
`SCAN INCOMPLETE` and every other non-zero code as a fault.

**Later (2026-10-01, DND-1489):** a malformed `--since` exited 2. Superseded
by exit 1: 2 already meant a requested PR/MR is not found or unreadable, so a
caller could not tell a malformed argument from a failed lookup by its code. The callers
were swept: `lead-time-phases --ingest` reads only 0 and 3 as distinct and any
other code as a fault, and the improver's watch scan reads its meta only on 0.

### Why GitLab reads the deploy *job*, not the whole pipeline

walt_ui's post-merge pipeline can sit at `status=manual` (it has manual jobs like
`pages`/`release:run-scripts` and can carry a failed `release:rollback`), so
"whole pipeline succeeded" is often false even when the deploy itself succeeded.
The precise, durable signal is the latest successful **`deploy`-stage** job's
`finished_at` (e.g. MR 1188's `porter:deploy`/`release:deploy`/`release:watch`
succeeded ~06:58–07:07Z while the pipeline read `manual`). Reading the job, not
the pipeline status, is what makes the GitLab end trustworthy.

An idle pipeline selector (DND-1952) reads a deploy that runs as a child
pipeline, whose jobs its parent's job list does not show. It reads pipeline
status, so a `manual` status reads could not measure, never busy and never
concluded. gen_saas's deploy child has no manual jobs (`.gitlab/ci/post-merge.yml`,
2026-10-04).

### The START marker: the ticket's move to In Progress

START is when the ticket first moved to `In Progress`, which is when its captain
was dispatched, or, for a ticket re-dispatched from a park, that re-dispatch
(*Decisions* → *A park restarts the start*). The Notion API keeps no history of
a property, so the move is recorded as it happens:

- **The trackers.** Two trackers carry the stamp (`ai/lib/dispatch_trackers.rb`):
  - **DND Tickets** (notion-personal): the date property `In Progress at`.
    First dispatch is a move from `Todo` or `Backlog`.
  - **The work tracker** (notion-work; walt_ui's tickets, DND-1341). Its data
    source, ticket prefix, stamp property and first-dispatch statuses are work
    values, so they live in the private overlay, `overlay/notion.json`
    `.work.tickets_data_source`, `.work.ticket_prefix`,
    `.work.in_progress_property` and `.work.first_dispatch_from`
    (`ai/contracts/athena-private-overlay.md` → *Keys in use*).
- **The stamp.** `ai/skills/athena:ticket-management/scripts/mark-in-progress
  --ref <TICKET>` picks the tracker from the ticket's prefix, sets `Status` to
  `In Progress` and stamps the date in the same write when the date is empty
  and the move is a first dispatch, or when the move is a re-dispatch from a
  park, which replaces any earlier stamp (*Decisions* → *A park restarts the
  start*). Any other re-dispatch keeps its stamp. A work ticket on a machine
  with no overlay, or with a required key missing, is refused (exit 3) with
  the resolver's line; nothing is guessed.

  **Later (2026-10-03, DND-1838):** this read "A re-dispatched ticket keeps
  its **first** stamp", with no exception for a park. Superseded: a kept
  stamp counted the park as lead time (DND-1438, stamped 2026-09-30T23:49Z,
  parked over the owner's pause, re-dispatched 2026-10-01T07:04Z), and an
  unstamped ticket re-dispatched from `Parked` got no stamp at all (DND-1095,
  could-not-measure on 2026-10-03).
- **Which moves are a park.** DND Tickets: a move from `Parked`. The work
  tracker: a move from a status in the overlay's optional
  `.work.restart_dispatch_from` (a work value). With that key absent, no
  park is detected on a work ticket, and `mark-in-progress` names the key
  with a `Fix:` on every move from a status that is neither a first dispatch
  nor `In Progress`.
- **The read.** `lead-time` names the ticket from the PR's branch, else its
  title (`DND-1318`, `dnd-1318-…`, or a work ticket), and reads that tracker's
  date. Each row carries `start_source` (`DND-1318 In Progress at`, or the work
  ticket and its property). The overlay is read only when a request names a
  ticket-shaped ref other than a DND one (a work ticket, or a word such as
  `utf-8`); a request naming only DND tickets never touches it. The earliest commit is
  still reported, as `first_commit`, and is **never** used as the start.
- **Could not measure.** The row has no lead and says why, on the row and on
  stderr, when: the branch and title name no ticket, or two tickets; the ticket
  is in neither tracker; it is not in its tracker's database; it has no stamp;
  or the stamp has no time. With no overlay on the machine, a work ticket's row
  says the work tracker is unavailable and carries the resolver's line. A
  Notion read that cannot run (no token, an HTTP failure), or an overlay that
  exists but cannot give the work tracker (a missing or malformed key), is a
  failed probe, so the run ends `SCAN INCOMPLETE`.

**Where it can misattribute.**

- A ticket re-dispatched from a park measures from the re-dispatch, so work
  done before the park is not in its lead. That undercount is chosen
  (*Decisions* → *A park restarts the start*).
- A work ticket parked on a machine whose overlay has no
  `.work.restart_dispatch_from` keeps its first stamp, so it counts the park.
  `mark-in-progress` names the missing key at that move.
- A park made by a status other than `Parked` (a ticket left `In Progress`
  with no captain, or moved through `Attention Given`) is not a park to the
  tool, so its span is counted.
- A follow-up PR on a ticket that already landed once inherits the first
  dispatch, so it reads long. `lead-time` accepts that. The phase ledger does
  not: its `implement` for a later landing starts at the follow-up dispatch
  or the previous landing (DND-1904).
- A batch Mission stamps all its tickets at one dispatch, so they share a
  start. That is real, not an artefact.
- A stamp set with `--backfill --at` is only as good as the record it came
  from.

What reads could-not-measure instead of a guess:

- A ticket moved to `In Progress` without `mark-in-progress` has no stamp.
- `mark-in-progress` stamps a first dispatch (a move from one of the
  tracker's first-dispatch statuses; DND: `Todo` or `Backlog`) and a
  re-dispatch from a park. An unstamped ticket resumed from any other status
  (DND: `Attention Given`) is not stamped with the resume time. The script
  says so with a `Fix:` naming `--backfill`, and `lead-time`'s
  could-not-measure reason carries the same `Fix:`.
- A stamp with no UTC offset cannot be placed in time.
- A stamp later than the landing (a re-dispatch after the work landed, or a
  mistaken backfill) never yields a negative lead.

**A walt_ui row is measured only on a machine with the overlay.** Without it,
a walt_ui row reads could-not-measure for its start. Its `tail` is still
measured, and `--slow` keeps those rows, so the improver's watch scan still
reads walt_ui's `tail` (its lever). A walt_ui ticket dispatched before DND-1341 has
no stamp, like a DND ticket dispatched before DND-1318.

**Later (2026-09-30, DND-1341):** this said "The start is DND-only": only DND
Tickets carried the stamp, so every walt_ui row read could-not-measure for its
start. Superseded by the work tracker above. The owner's metric (dispatch →
landed) did not cover walt_ui work.

**Later (2026-09-30, DND-1318):** START was the earliest commit on the PR,
authored or committed. Superseded by the owner's definition above. Captains
squash or rewrite before landing, which resets that date: `lead-time --pr 129`
read **21m 19s** for DND-1203, whose captain was dispatched at 02:41Z and whose
PR merged at 03:27:17Z (46m 17s). The commit start also over-reported stacked
branches, whose commit lists reach back to the stack's base.

## The markers we rejected, with evidence

- **Notion `Todo → In Progress` transition time.** Rejected on a *verified* fact:
  the Notion public API exposes exactly two page timestamps — `created_time` and
  `last_edited_time` — and no per-property transition history. Retrieving DND-184
  (`3df349da-87fb-8156-9f43-f829183f841a`) returned `created_time`
  `2026-09-18T19:09Z` and `last_edited_time` `2026-09-19T04:36Z`; the `Status`
  property carries only its current value (`Done`), no timestamp. Worse,
  `last_edited_time` is whole-page and equals the status→Done edit at merge, so it
  cannot isolate the start even approximately. Compounded by captains
  historically not setting the status. Unrecoverable and unreliable.

  **Later (2026-09-30, DND-1318):** adopted, by owner decision. The API fact
  still holds, so the transition time is not read back; it is **stamped** as it
  happens (`In Progress at`, *The START marker* above). A ticket dispatched
  before the stamp existed has no start and reads could-not-measure, unless it
  is backfilled from a recorded dispatch time.
- **Admiral dispatch time.** Not persisted queryably — `state.md` records
  dispatch *ordering* in prose, not a machine-readable per-ticket timestamp; the
  only trace is gitignored, local `ai-artifacts/coordination/*` file mtimes.

  **Later (2026-09-30, DND-1318):** dispatch time is now persisted, as the
  `In Progress at` stamp the dispatch writes. `state.md` dispatch lines are a
  source for `--backfill`, not for `lead-time`.
- **Branch / worktree creation time.** Not recoverable across machines or after
  cleanup; a branch can be cut early or reused. No better than first-commit.

## The capture mechanism: derive, don't capture

**The best capture mechanism is no capture at all.** `ai/bin/lead-time` recovers
every END timestamp on demand from git + the forge's CI, both of which retain
history independently of whether any agent remembered to do anything. START is
the one exception (below): a stamp the dispatch step writes, and a missing stamp
reads could-not-measure, never a guess.

```
ai/bin/lead-time --repo ~/dev/gen_saas --since 2026-09-19T00:00:00Z   # github/gh
ai/bin/lead-time --repo ~/dev/walt_ui  --mr 1188                      # gitlab/glab
ai/bin/lead-time --repo ~/dev/custom   --pr 14 --json                 # github, no CI
ai/bin/lead-time --self-test            # pure date/marker logic, no network
```

- `--repo`'s `origin` remote selects the backend: `github.com` → `gh`,
  `gitlab.com` → `glab`. `--pr` and `--mr` are synonyms.
- Pure date/marker math lives in module `LeadTime` (Ruby stdlib only, runs on the
  harness Ruby, system ruby 3.4 via `#!/usr/bin/ruby`) and is covered by
  `ai/test/lead-time/self-test.sh`, discovered and run by `harness-gate`.

  **Later (2026-09-27, DND-931):** this said the module runs on "the system's
  Ruby 2.7". Superseded by the owner's decision that the harness Ruby is 3.4
  (Cody, 2026-09-27: "3.4 is our global default for harness and our
  projects"); `ai/bin/check-ruby-floor` enforces it.
- Run ad hoc, or on a cadence (e.g. a shipwright pass) redirecting `--json` into a
  local ledger under `ai-artifacts/` if a running history is wanted. Because it
  derives, re-running is idempotent and back-datable.

**The one captured timestamp is START.** The dispatch writes it
(`mark-in-progress`), because nothing else keeps it. The end is still derived.

**Later (2026-09-30, DND-1318):** this said no start was captured and that
first-commit stays the marker. Superseded by the owner's definition (*What is
measured*).

## Phase decomposition and the feedback loop

Every row splits lead time into two phases, because they have **different
improvement levers**:

- **`code` = start → landing** — development + review. Lever: the **harness/process**
  (clearer specs, better skills, fewer review round-trips).
- **`tail` = landing → end** — CI + deploy. Lever: **pipeline efficiency**
  (parallelize, cache, shard, faster-equivalent tooling).

`ai/bin/lead-time --slow N` keeps the tickets with lead ≥ N minutes (sorted
slowest-first, each tagged `slow_threshold_min`) — the outlier filter — and,
after them, every could-not-measure row. Both
phases appear in the human table and in `--json` (`code_seconds`/`tail_seconds`).

The **lead-time improver cron** (`~/dev/custom/CLAUDE.md` → *Lead-time
improver cron*) runs this at `--slow 90` over each `watch` repo that
`ai/bin/lead-time-repos` resolves for the machine, newer than that repo's own
`watch-cursor.<repo>.txt`. Each `improve` repo is measured per phase
instead, by `ai/bin/lead-time-phases`; one other than custom acts in custom
or, through its product lane, in itself (`athena:lead-time-improve` → *An
improve repo other than custom*). When a slow shape recurs (≥2 tickets
sharing a cause) or one pipeline stage dominates the `tail`, it spawns an
**athena-architect** to design a **safety-preserving** improvement. A
harness change to `~/dev/custom` lands only as that run's one action;
otherwise it is filed as a DND ticket on the improvement epic. A `watch`
repo's own changes are filed as Notion tickets for the fleet: it never
changes a `watch` repo. Details live in `athena:lead-time-improve` (*For
each `watch` repo*, and *The product lane* for an `improve` repo).

**Later (2026-10-01, DND-1542):** this read "Product-repo changes are filed
as Notion tickets for the fleet (it never touches a product repo)".
Superseded for `improve` repos by the owner's grant
(`~/dev/custom/CLAUDE.md` → *Lead-time improver cron* → *Scope*).

**Later (2026-10-01, DND-1533):** this read "The `improve` repo (custom) is
measured per phase instead". Superseded: a machine's list may name an
`improve` repo other than custom.

**Later (2026-10-01, DND-1480):** the athena-shipwright cron ran this scan,
over every repo the fleet ships from, from `lead-cursor.<repo>.txt`, with its
details in the shipwright agent definition (*The lead-time feedback loop*).
Superseded: that section moved into the improver's skill, and the installer
seeded each `watch-cursor.<repo>.txt` from the old file. The shipwright also
applied every harness change its architect proposed; the improver lands at
most one per run.

**Later (2026-09-21):** the cursor was a single `lead-cursor.txt` shared by every
repo, advanced to the newest merge scanned anywhere. Superseded by one cursor per
repo, advanced only for a repo whose own scan completed and **never on a `SCAN
INCOMPLETE`**. A shared cursor makes one repo's success consume a sibling's
unscanned window, permanently and silently: `gh` auth on this machine has been
HTTP 401 for `custom` and `gen_saas` while `walt_ui` scanned clean, so a dozen
journal entries advanced the shared cursor past windows those two repos were
never measured over. Making the probe failure *loud* (the `SCAN INCOMPLETE`
refusal, added 2026-09-21) fixed the reporting half but not this one — the loop
still announced it had not measured while discarding the window it would have
needed to measure later.

**The hard constraint on all of this: never remove or weaken a safety check**
(tests, linters, type checks, scanners, coverage/mutation gates, deployment
watchers, review gates). Making a check *faster* is the goal; loosening *what it
enforces* is forbidden and outranks any speedup. The doctrine is the shared block
`ai/blocks/ops/safety-checks.md`, carried verbatim by the shipwright, architect,
admiral, and captain. A large `tail` (e.g. gen_saas PR 244 below: `code 1h 46m +
tail 48m 40s`) is a pipeline-efficiency target; a `code`-dominated ticket (PR
242: `code 1h 59m + tail 5m 25s`) is a harness/process target.

### Finer phases: the phase ledger (DND-1477)

`ai/bin/lead-time-phases` splits `code` further, per landing, into
`implement`, `verify`, `queue`, `integrate` and `merge`, from telemetry
(`ai/contracts/athena-telemetry.md`), integration receipts, critic verdicts
and harness-gate timings. `--ingest` keeps a ledger in
`ai-artifacts/lead-time/` with one cursor per repo, advanced to `lead-time
--meta`'s `scanned_through` and never on `SCAN INCOMPLETE`. `--summary` gives
the rolling-window median, p90 and sum per phase. The repos and their modes
are what `ai/bin/lead-time-repos` resolves for the machine (its `--help` says
from where). A phase it cannot measure is null with a
reason, never 0. Its `--help` is the reference for the anchors and outputs;
the design is `ai/docs/lead-time-improver.md` (Decisions 3-6).

**Later (2026-10-01, DND-1527):** this section named
`ai/config/lead-time-repos.json` as the repo list. Superseded: that file is
only the default, and a machine-local override replaces it, so the list is
the resolver's.

## Decisions

### A park restarts the start (DND-1838)

**Decision.** A re-dispatch from a park restarts the start: `mark-in-progress`
stamps the re-dispatch time, replacing any earlier stamp. Lead time for a
ticket that was parked is re-dispatch → landed.

**Why this one.** The ticket offered two rules: the sum of active spans, or a
reset start with the parked span recorded. The bar was the simplest rule that
makes a re-dispatch from a park always measurable and never counts a parked
span as active work.

- **Always measurable.** Every re-dispatch through `mark-in-progress` from a
  park writes a stamp, because the tool runs at that instant. DND-1095's
  shape, an unstamped ticket re-dispatched from `Parked`, measures. A move
  made without the tool still leaves no stamp (*The START marker* →
  *Could not measure*).
- **The park is never counted.** The start is after the park ends.
- **No new Notion property, no new tool.** The sum needs the park's start,
  and nothing records it: the admiral moves a ticket to `Parked` with the
  connector. It would also need a property to carry the active seconds
  before the park, a park step that writes it, and a reader that adds the
  spans. The reset reuses the one stamp and the one reader.
- **The cost, named.** Work done before the park is not in the lead. A
  re-dispatched captain usually resumes from a worktree and a pushed branch,
  so that work is real and is undercounted. A captain dispatched to fix a
  finished PR that left the merge queue on a red gate drops the earlier
  captain's time the same way. An undercount of a parked ticket is preferred
  to counting days of pause as captain time. If the pre-park span is ever
  needed, the sum is the follow-up: one number property (active seconds
  before the park), and a park step that writes it.

**A park is a captain dispatch, not boarding.** `mark-in-progress` is the
captain-dispatch step ([[athena:ticket-management]] → *The transitions an
orchestrator performs*). An admiral that resumes boarding a `Parked` ticket's
finished PR, with no captain, moves it to `In Progress` with the connector,
so the stamp is kept: that wait is merge latency, which lead time counts.

**The record of the reset.** The Notion page keeps only the new stamp. The
discarded one is in the line `mark-in-progress` prints (`restarted:
re-dispatch from "Parked"; discarded <old stamp>`), which reaches only its
caller, and in the `ticket.dispatched` telemetry event (`restart: true`,
`previous_stamp`), which is the durable record. Telemetry is machine-local:
it is on the machine that ran the dispatch.

**Which moves are a park.** DND: a move from `Parked`. The work tracker: the
overlay's optional `.work.restart_dispatch_from`, because the status names
are work values. The key is optional so an overlay written before it keeps
working, and its absence is never silent: `mark-in-progress` names it on
every move from a status that is neither a first dispatch nor `In Progress`.
A move from `Attention Given` is not a park: the ticket waited on Cody with
its captain's work in flight, so its stamp is kept.

**Correcting a stamp made before this rule.** Take the re-dispatch time from
the admiral's state log, then run, with `--dry-run` first:

- an unstamped ticket re-dispatched from `Parked`:
  `mark-in-progress --ref <TICKET> --backfill --at <re-dispatch time>`;
- a stamp kept across a park:
  `mark-in-progress --ref <TICKET> --backfill --restart --at <re-dispatch time>`.

`--restart` refuses an `--at` earlier than the ticket's latest local
`ticket.dispatched` with `backfill` false, and its `Fix:` names that event's
time (DND-1877); use that time. The printed line names the dispatch it
checked against, says this machine recorded none, or says it could not check
(no store, or a store it could not fully read). The check sees only this
machine's telemetry.

`--backfill` leaves the status alone. The rows DND-1838 found (DND-1095,
DND-1438) and their exact commands are on that ticket.

`lead-time` reads the stamp on every run, so a corrected stamp corrects every
later `lead-time` read. The phase ledger is first-write-wins
(`lead-time-phases --help` → `--rejoin`), so a landing it already ingested
keeps the start it was ingested with.

**A landing before the restart.** A ticket can land in parts across a park
(DND-1095 landed commits before its 2026-10-03 re-dispatch). After the
restart, `lead-time` reads each earlier landing as could-not-measure ("start
… is after the landing"), never as a negative lead. That is the same
one-stamp limit as a follow-up PR (*Where it can misattribute*). The phase
ledger's `implement` is not bound by it: a later landing starts at its
follow-up `ticket.dispatched`, else the previous landing (DND-1904).

**The phase ledger after a restart.** A resumed captain has usually run a
gate before the park. `lead-time-phases` takes `implement` to the first gate
run at or after the stamp when a local `ticket.dispatched` records the stamp
as a restart. With no such event (the dispatch ran on another machine), a
gate before the stamp leaves `implement` invalid, as for any gate before a
dispatch stamp.

## Worked backfill — 2026-09-19 fleet run (dated snapshot)

**Later (2026-09-30):** this snapshot used the old first-commit START. The
stacked-branch limitation it points to ("see limitation above") now lives in
*The START marker*'s DND-1318 note.

**As-of 2026-09-19.** Acceptance test: every ticket that shipped, lead time
derived from durable data alone. All timestamps UTC. `via=deploy` = ended at the
deploy step; `via=pipeline` = ended at post-merge pipeline completion (no deploy
step ran); `via=merge` = no post-merge CI (ended at merge).

### `~/dev/custom` — GitHub, no CI/deploy → `via=merge`

| PR | Ticket | Lead | Start | End (merge) |
|---|---|---|---|---|
| 1  | DND-182 | 9m 21s  | 00:37:23 | 00:46:44 |
| 3  | DND-183 | 44m     | 01:31:04 | 02:15:04 |
| 2  | DND-189 | 38m 14s | 01:34:04 | 02:12:18 |
| 4  | DND-202 | 16m 5s  | 01:54:07 | 02:10:12 |
| 7  | DND-208 | 22m 7s  | 02:27:08 | 02:49:15 |
| 9  | DND-184 | 2h 4m   | 02:32:35 | 04:36:35 |
| 11 | DND-209 | 1h 3m   | 03:18:01 | 04:21:44 |
| 12 | DND-209 f/u | 1h 13m | 03:18:01 | 04:31:44 |
| 14 | DND-185 | 58m 22s | 04:42:59 | 05:41:21 |
| 5/6/8/10 | follow-ups/shipwright | 53s–3m 46s | — | — |

### `~/dev/gen_saas` — GitHub, `Post-Merge Deploy` → `via=deploy`

| PR | Lead | Start | End (deploy done) |
|---|---|---|---|
| 230 | 10m 45s | 18:21:03 | 18:31:48 |
| 233 | 8m 41s  | 20:51:33 | 21:00:14 |
| 235 | 12m 27s | 21:12:52 | 21:25:19 |
| 238 | 21m 31s | 23:32:12 | 23:53:43 |
| 241 | 52m 15s | 01:21:40 | 02:13:55 |
| 242 | 2h 4m   | 00:38:28 | 02:43:12 |
| 244 | 2h 35m  | 03:09:27 | 05:44:31 |
| 245 | 1h 42m  | 04:24:11 | 06:06:39 |

(15 gen_saas PRs total merged/deployed tonight; representative rows shown.)

### `~/dev/walt_ui` — GitLab, `deploy`-stage jobs → `via=deploy`

| MR | Lead | Start | End (deploy done) | Note |
|---|---|---|---|---|
| 1177 | 3m 14s | 21:43:12 | 21:46:26 | clean |
| 1183 | 43m 14s | 00:40:03 | 01:23:17 | clean |
| 1188 | 2h 1m   | 05:05:41 | 07:07:37 | clean |
| 1186 | 4h 34m  | 09:08:00 | 13:42:03 | clean |
| 1170/1175/1176 | 19–22h | 2026-09-17T22:52:20 | 18:18–20:51 | **stacked — over-reported**, see limitation above |

**Reading it.** gen_saas deploy tails run ~5–20 min over merge (PR 245 merged
`05:41:21`, deploy done `06:06:39` — a ~25 min tail); that tail is why
deploy-completion, not merge, is the right end for a deploying repo. walt_ui's
clean MRs behave the same; its stacked MRs are the documented artefact.

**Backfill verdict: yes, recoverable across all three repos and both forges**, from
git + CI alone with no reliance on any agent-set status. The start is the
first-commit floor (over-reported for stacked branches, flagged above); the true
dispatch instant is not recoverable for past tickets and was not invented.
