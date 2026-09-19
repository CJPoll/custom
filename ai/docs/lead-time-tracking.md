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
| **START** | earliest commit on the ticket's branch | git; `gh pr view --json commits` / `glab api …/merge_requests/:iid/commits` |
| **END** | first of the 3 tiers below that exists | GitHub Actions runs / GitLab pipeline jobs / merge time |

### The END rule — one 3-tier rule, forge-independent

For a merged ticket, gather three candidate end times and take the **first that
exists**. This maps exactly onto Cody's definition:

1. **DEPLOY completed** — the deploy step's completion time.
   - GitHub: completion (`updatedAt`) of the successful workflow run for the
     merge commit whose workflow name matches the deploy pattern (default
     `/deploy/i`; `gen_saas`'s `Post-Merge Deploy` matches).
   - GitLab: the latest `finished_at` among **successful jobs in the `deploy`
     stage** of the merge commit's pipeline on the default branch.
2. **POST-MERGE PIPELINE completed** — if no deploy step ran (a doc-/test-only
   ticket), the completion of the post-merge pipeline/run itself.
   - GitHub: latest successful non-deploy run for the merge commit.
   - GitLab: latest `finished_at` among all successful jobs in that pipeline.
3. **MERGE time** — if there is no post-merge CI at all (e.g. `~/dev/custom`, no
   CI, no deploy), the merge commit time (`mergedAt` / `merged_at`).

This is Cody's offered simplification, made regular: a **single rule** yields a
consistently-available, trustworthy end for every ticket on every forge. It is
"slightly late" only in the benign sense that a deploy tail is included when a
deploy ran — which is exactly what "fully deployed" means.

### Why GitLab reads the deploy *job*, not the whole pipeline

walt_ui's post-merge pipeline can sit at `status=manual` (it has manual jobs like
`pages`/`release:run-scripts` and can carry a failed `release:rollback`), so
"whole pipeline succeeded" is often false even when the deploy itself succeeded.
The precise, durable signal is the latest successful **`deploy`-stage** job's
`finished_at` (e.g. MR 1188's `porter:deploy`/`release:deploy`/`release:watch`
succeeded ~06:58–07:07Z while the pipeline read `manual`). Reading the job, not
the pipeline status, is what makes the GitLab end trustworthy.

### The START marker is honest about under-reporting

Earliest-commit-on-branch **lags true start** by the first chunk of work (read
the ticket, plan, write code before the first commit). It therefore **slightly
under-reports**. Worked example, GitHub PR #14 (DND-185): first commit
`04:42:59Z`, PR opened `05:19:29Z`, admiral dispatched earlier still. We accept
the under-report rather than invent a start we cannot prove.

**Known limitation — stacked branches over-report.** For a **stacked** MR/PR
whose branch still contains an unmerged parent's commits, the forge's commit list
includes those ancestor commits, so `min(commit time)` reaches back to the
stack's base and the lead time is inflated. Observed on walt_ui's `margie/`
stacks (2026-09-19 backfill): MRs 1170/1175/1176 all resolve to the same start
`2026-09-17T22:52:20Z`, yielding 19–22h — an artefact of the stack, not the work.
GitHub's `dnd-*` branches tonight were not stacked, so they were clean. Treat a
lead time that shares a start with a sibling ticket as suspect. A robust fix
(counting only commits unique to the ticket after its stack-parent merges) is
forge- and tooling-specific and was **not** built; the plain first-commit floor
is kept, with this caveat, rather than adding fragile stack-aware logic.

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
- **Admiral dispatch time.** Not persisted queryably — `state.md` records
  dispatch *ordering* in prose, not a machine-readable per-ticket timestamp; the
  only trace is gitignored, local `ai-artifacts/coordination/*` file mtimes.
- **Branch / worktree creation time.** Not recoverable across machines or after
  cleanup; a branch can be cut early or reused. No better than first-commit.

## The capture mechanism: derive, don't capture

**The best capture mechanism is no capture at all.** `ai/bin/lead-time` recovers
every timestamp on demand from git + the forge's CI, both of which retain history
independently of whether any agent remembered to do anything. There is **no new
manual step** for an agent to skip — the whole lesson that motivated this work.

```
ai/bin/lead-time --repo ~/dev/gen_saas --since 2026-09-19T00:00:00Z   # github/gh
ai/bin/lead-time --repo ~/dev/walt_ui  --mr 1188                      # gitlab/glab
ai/bin/lead-time --repo ~/dev/custom   --pr 14 --json                 # github, no CI
ai/bin/lead-time --self-test            # pure date/marker logic, no network
```

- `--repo`'s `origin` remote selects the backend: `github.com` → `gh`,
  `gitlab.com` → `glab`. `--pr` and `--mr` are synonyms.
- Pure date/marker math lives in module `LeadTime` (Ruby stdlib only, runs on the
  system's Ruby 2.7) and is covered by `ai/test/lead-time/self-test.sh`,
  discovered and run by `harness-gate`.
- Run ad hoc, or on a cadence (e.g. a shipwright pass) redirecting `--json` into a
  local ledger under `ai-artifacts/` if a running history is wanted. Because it
  derives, re-running is idempotent and back-datable.

**If a manual start-capture is ever wanted** (to beat the first-commit lag and the
stacked-branch artefact), the only near-zero-agent-dependence place to add it is
worktree creation (`wt` could stamp a start file). It was deliberately **not**
built: worktrees can be created early or reused, trading a known bias for a new
unreliable signal and new maintenance. First-commit stays the marker.

## Worked backfill — 2026-09-19 fleet run (dated snapshot)

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
clean MRs behave the same; its stacked `margie/` MRs are the documented artefact.

**Backfill verdict: yes, recoverable across all three repos and both forges**, from
git + CI alone with no reliance on any agent-set status. The start is the
first-commit floor (over-reported for stacked branches, flagged above); the true
dispatch instant is not recoverable for past tickets and was not invented.
