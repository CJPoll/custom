# Lead-time tracking for fleet tickets

**Kind: living normative document.** Amended in place, per `~/dev/custom/CLAUDE.md`
→ *Documentation conventions*. The worked-backfill section is a dated snapshot
and is labelled as such.

## What is measured

**Lead time = the interval from when a captain starts working a ticket to when
that ticket is fully deployed in production.** Cody's definition, precisely:

- A ticket that **deploys to prod**: lead time ends when the production
  deployment completes.
- A ticket that **does not deploy** (doc-/test-/harness-only, and possibly other
  kinds — deliberately not a fixed whitelist): lead time ends when the
  **post-merge pipeline completes**, which is not quite deployment.

## The chosen markers

| | Marker | Where it lives | Recovers historically? |
|---|---|---|---|
| **START** | earliest commit on the ticket's branch | git / `gh pr view --json commits` | yes (survives squash merge) |
| **END (deploy repo)** | completion of the `Post-Merge Deploy` run whose `headSha` is the merge commit | GitHub Actions / `gh run list` | yes |
| **END (no-deploy repo)** | the merge commit time (`PR mergedAt`) | git / `gh pr view` | yes |

The end rule is a single sentence: **the latest durable end signal that exists
for the repo.** A repo that deploys ends at deploy completion; a repo that does
not ends at merge.

### Why not unify on "deployment completed" for both (Cody's offered simplification)

Cody offered: if it tracks with more regularity, use the completed-deployment
marker as the end for both categories. We could not take it, for a concrete
reason rather than a purist one: **`~/dev/custom` has no CI and no deploy at
all** — there is no post-merge run of any kind to read, so there is no
deployment marker to unify on for half the fleet. The simplification presupposes
a deployment exists; for the no-deploy repo none does.

So instead of unifying on the *marker* we unified on the *rule* ("latest durable
end signal that exists"), which is just as regular and just as trustworthy,
because both signals are derived per-repo from durable artifacts that always
exist for that repo. Within `~/dev/gen_saas` the end is uniform: `post-merge.yml`
fires on **every** push to `main` with no path filter, so a doc-/test-only
gen_saas ticket still gets a `Post-Merge Deploy` run — the deploy-completion
marker is available for every merged gen_saas ticket, deploying or not.

### The START marker is honest about under-reporting

Earliest-commit-on-branch **lags true start** by the first chunk of work (the
captain reads the ticket, plans, and writes code before the first commit). It
therefore **slightly under-reports** lead time. Worked example, PR #14 (DND-185):
first commit `04:42:59Z`, PR opened `05:19:29Z`, and the admiral had dispatched
the captain earlier still. We accept the under-report rather than manufacture a
start we cannot prove. It is the honest durable floor, and it is consistent
across every ticket, so trends are comparable even if the absolute value runs a
little short.

## The markers we rejected, with evidence

- **Notion `Todo → In Progress` transition time.** Rejected on a *verified*
  fact, not a guess: the Notion public API exposes exactly two page timestamps —
  `created_time` and `last_edited_time` — and no per-property transition history.
  Retrieving DND-184 (`3df349da-87fb-8156-9f43-f829183f841a`) returned
  `created_time` `2026-09-18T19:09Z` and `last_edited_time` `2026-09-19T04:36Z`;
  the `Status` property carries only its current value (`Done`) with no
  timestamp. Worse, `last_edited_time` is whole-page and equals the *last* edit —
  here `04:36Z`, which is the status→Done edit at merge — so it cannot isolate
  the start transition even approximately. Compounding the API limit, captains
  have historically not set the status reliably (the 2026-09-18 athena-inbox run
  recorded "Captains set NO status; the admiral holds tickets at In Progress
  until merge"). Unrecoverable and unreliable: rejected.
- **Admiral dispatch time.** The admiral knows it, but it is not persisted in any
  queryable form. `state.md` records dispatch *ordering* and page IDs in prose,
  not a machine-readable per-ticket dispatch timestamp; the only trace is file
  mtimes on `ai-artifacts/coordination/*` (gitignored, local, not shared, and
  bumped by any later edit). Not durable, not queryable: rejected as the marker.
- **Branch / worktree creation time.** Durable in a local reflog but not
  recoverable across machines or after cleanup, and a branch can be cut early or
  reused, so it is neither reliable nor better than first-commit. Rejected.

## The capture mechanism: derive, don't capture

**The best capture mechanism is no capture at all.** `ai/bin/lead-time` recovers
every timestamp on demand from git + GitHub Actions, both of which retain history
independently of whether any agent remembered to do anything. There is **no new
manual step** for an agent to skip — which is the entire lesson that motivated
this work.

```
ai/bin/lead-time --repo ~/dev/gen_saas --since 2026-09-19T00:00:00Z
ai/bin/lead-time --repo ~/dev/custom   --pr 14 --json
ai/bin/lead-time --self-test        # pure date/marker logic, no network
```

- `--repo` detects whether the repo deploys by the presence of
  `.github/workflows/post-merge.yml`; that switches the end marker automatically.
- Pure date/marker math lives in module `LeadTime` and is covered by
  `ai/test/lead-time/self-test.sh`, discovered and run by `harness-gate`.
- Run it ad hoc, or on a cadence (e.g. a shipwright pass) redirecting `--json`
  into a local ledger under `ai-artifacts/` if a running history is wanted.
  Because it derives, re-running is idempotent and back-datable.

**If a manual start-capture is ever wanted** (to beat the first-commit lag), the
only place to add it with near-zero agent dependence is worktree creation (`wt`
could stamp a start file). It was deliberately **not** built: worktrees can be
created early or reused, so it trades a known small under-report for a new
unreliable signal and a new thing to maintain. First-commit stays the marker.

## Worked backfill — 2026-09-19 fleet run (dated snapshot)

**As-of 2026-09-19.** Acceptance test of the design: every ticket that shipped
tonight, lead time derived from durable data alone. All timestamps UTC.
`via=merge` = ended at merge (no-deploy repo); `via=deploy` = ended at
`Post-Merge Deploy` completion.

### `~/dev/custom` (no CI, no deploy → end = merge)

| PR | Ticket | Lead | Start (first commit) | End (merge) |
|---|---|---|---|---|
| 1  | DND-182 | 9m 21s  | 00:37:23 | 00:46:44 |
| 3  | DND-183 | 44m     | 01:31:04 | 02:15:04 |
| 5  | DND-183 f/u | 1m 13s | 02:30:07 | 02:31:20 |
| 6  | DND-183 f/u | 53s    | 02:35:34 | 02:36:27 |
| 2  | DND-189 | 38m 14s | 01:34:04 | 02:12:18 |
| 4  | DND-202 | 16m 5s  | 01:54:07 | 02:10:12 |
| 7  | DND-208 | 22m 7s  | 02:27:08 | 02:49:15 |
| 9  | DND-184 | 2h 4m   | 02:32:35 | 04:36:35 |
| 11 | DND-209 | 1h 3m   | 03:18:01 | 04:21:44 |
| 12 | DND-209 f/u | 1h 13m | 03:18:01 | 04:31:44 |
| 14 | DND-185 | 58m 22s | 04:42:59 | 05:41:21 |
| 8  | shipwright | 1m 44s | 04:24:09 | 04:25:53 |
| 10 | shipwright | 3m 46s | 04:26:43 | 04:30:29 |

### `~/dev/gen_saas` (deploys via `post-merge.yml` → end = deploy completion)

| PR | Lead | Start (first commit) | End (deploy done) |
|---|---|---|---|
| 230 | 10m 45s | 18:21:03 | 18:31:48 |
| 231 | 27m 26s | 19:11:16 | 19:38:42 |
| 232 | 42m 53s | 19:40:12 | 20:23:05 |
| 233 | 8m 41s  | 20:51:33 | 21:00:14 |
| 234 | 17m 40s | 20:59:41 | 21:17:21 |
| 235 | 12m 27s | 21:12:52 | 21:25:19 |
| 236 | 15m 4s  | 22:12:24 | 22:27:28 |
| 237 | 13m 18s | 22:47:51 | 23:01:09 |
| 238 | 21m 31s | 23:32:12 | 23:53:43 |
| 241 | 52m 15s | 01:21:40 | 02:13:55 |
| 239 | 32m 24s | 01:41:50 | 02:14:14 |
| 242 | 2h 4m   | 00:38:28 | 02:43:12 |
| 243 | 1h 9m   | 02:46:09 | 03:55:30 |
| 244 | 2h 35m  | 03:09:27 | 05:44:31 |
| 245 | 1h 42m  | 04:24:11 | 06:06:39 |

**Reading it.** Custom tickets cluster short (seconds to ~2h; the ~1h+ ones are
DND-184/209, which iterated). gen_saas tickets carry a deploy tail — end minus
merge is the CI+deploy duration, typically ~5–20 min on top of the coding
interval (e.g. PR 245 merged `05:41:21`, deploy completed `06:06:39`: a ~25 min
tail). The tail is exactly why deploy-completion, not merge, is the right end for
a deploying repo: "fully deployed" is genuinely later than "merged."

**Backfill verdict: yes, fully recoverable.** Both the start (first commit) and
the end (merge time / deploy-run completion) came entirely from git + GitHub
Actions with no reliance on any status an agent did or did not set. The start is
the first-commit floor described above, not the true dispatch instant — that
instant is not recoverable for past tickets and was not invented.
