# Parallel merges, deploy latest (GitLab)

**Kind: living normative document.** Amended in place, per
`~/dev/custom/CLAUDE.md` → *Documentation conventions*. Until its tickets
land, the homes it names (`athena:merge-boarding`, `~/dev/custom/CLAUDE.md`,
the tools) still hold the old rules. When a ticket lands, its home becomes
normative and this document defers to it.

## The request

Owner, Cody, coordinator terminal, 2026-10-05 ~07:55Z (session
`0cc59a5e-6c65-495e-a216-83c6a0bf2d56`), relayed verbatim by the
GitLab-migration admiral:

1. CI must be passing before merges can happen.
2. Merges happen in parallel.
3. When multiple merges are queued, just deploy them in one go (deploy
   latest).
4. DO NOT run CI again post-merge.

Also relayed: Cody does not want `locked-merge`'s serialization, and does not
want the fleet asking permission for this work. Cody's words are the
authority for removing that serialization, so removing it is not item 5
(*Owner approval policy* → *Loosening a quality bar*). Everything else stays:
a merge is pinned to the reviewed head, and that head has a green pipeline.

Scope: the harness side in `~/dev/custom`, GitLab only. gen_saas's own
`.gitlab-ci.yml` is the laptop session's. This document lists only the
constraints the harness puts on it (*gen_saas: constraints on its pipeline*).

## What serializes merges today

| # | Mechanism | Where | Effect |
|---|---|---|---|
| S1 | `custom-merge.lock` held around fetch, rebase and push | `athena:merge-boarding` → *The merge bar* → the no-CI landing, steps 2-3; `~/dev/custom/CLAUDE.md` → *An admiral merges that PR*, steps 1-2 | One custom landing at a time. Prose only: nothing checks it (DND-1370). |
| S2 | `locked-merge` flock, `~/.local/state/athena/<repo>-merge.lock`, `--wait 900` | `scripts/locked-merge`, `--pr` and `--mr` | One merge at a time per repo per machine. |
| S3 | `locked-merge` asserts the landed commit's parent is the base B it checked, and its tree is `merge-tree(B, head)` (exit 7) | `scripts/locked-merge`, steps 3 and 7 | This assertion is why S2 exists. Without the lock, any concurrent landing makes it fail. |
| S4 | `--require-idle-workflow post-merge.yml` | `scripts/locked-merge`, step 4, GitHub only | One merge per deploy run: waits for the deploy between merges. Refused with `--mr`, so it does not apply on GitLab. |
| S5 | "Merge one at a time" | `athena:merge-boarding` → *Merge one at a time*; *Landing onto a moving main* | The doctrine S1-S3 enforce. |

Nothing on GitLab waits for a deploy between merges. `gmg_line_check` reads a
pending tip pipeline as not red, so a merge onto a deploying tip proceeds. S4
is the only deploy wait, and it is GitHub-only.

S1 and S2 do not protect correctness on their own. They make S3's
check-then-merge safe, because neither forge call takes a precondition on the
target's current SHA. `glab mr merge` and the merge API merge onto whatever
`main` is when GitLab runs them.

## What runs after a merge today

- **custom's `.gitlab-ci.yml` re-runs the full gate on `main`.** Its workflow
  rules run a branch pipeline for every branch with no open MR, "main
  included". A landing pushed to `main` runs `harness-gate` again. This
  violates goal 4. The file has no deploy job; custom deploys nothing through
  CI.
- **`main-health check` re-gates a merged tip locally.** A tip that is
  exactly a gated head is green from its receipt with no run. A tip that is a
  clean rebase or merge onto a moved `main` costs one local `harness-gate`.
  It is detection, never a merge gate, and it holds no lock. Whether goal 4
  covers it is Q1.
- **The project, read 2026-10-05 08:02Z** (`glab api
  projects/athena-ai-harness%2Fcustom`): `merge_method` `merge`,
  `only_allow_merge_if_pipeline_succeeds` false, no merge trains,
  `auto_cancel_pending_pipelines` enabled, `ci_forward_deployment_enabled`
  true, visibility private. The pipeline list was empty at that time.
- **custom's MR pipeline is not green yet.** DND-1946's header says so (13 of
  194 checks failed in the image), DND-1998 is reopened, and DND-2039 fixed
  the runner kit on 2026-10-05. Goal 1 cannot bind custom's landings until
  that pipeline passes on a healthy head (T1).

## Design

### D1. Land by a compare-and-swap push, with no lock

The forge cannot merge with a precondition on the target SHA. A git push can.
A non-force push of commit M to `main` succeeds only if `main` is an ancestor
of M. So when M's first parent is B, the push lands only if `main` is still B.
The push is the atomic check that S1-S3 rebuild with a lock.

The lander, per gated head H:

1. Fetch. B = `origin/main`.
2. Compute the tree `git merge-tree --write-tree B H`. A textual conflict is
   refused (exit 3, as today).
3. Read that tree against `ai/config/main-content-checks.json`. A duplicated
   migration version is a `SEMANTIC CONFLICT` (exit 3, as today).
4. Run the red-tip judgment on B (`gmg_line_check`, *D2*).
5. Make M with `git commit-tree <tree> -p B -p H`. When B is an ancestor of
   H, M is H itself and the push is a fast-forward of the reviewed head.
6. Push `M:main` through `glab-athena git push`, never forced.
7. A rejected non-fast-forward means another landing won. Go back to step 1:
   fetch, recompute, re-check, retry. Bounded: 5 attempts, then exit 6 with a
   `Fix:`. A clean recompute needs no re-gate (DND-1463 stands). A conflict
   on the recompute is exit 3, as today.
8. `confirm-merged --mr <iid>`. GitLab marks an MR merged when its head
   reaches the target, and H is a parent of M.

What this keeps, against `locked-merge` today:

| Guarantee | `locked-merge` | CAS lander |
|---|---|---|
| Landed tree == checked tree | asserted after the merge (exit 7) | by construction: M is the commit checked |
| Landed parent == checked base | asserted after the merge (exit 7) | by the push: non-fast-forward is refused by git |
| Content check on the landed tree | on `merge-tree(B, H)` under the lock | on M's own tree, rechecked on every retry |
| Textual conflict refused | yes | yes |
| Pinned to the reviewed head | `--sha <head>` | H is M's second parent, or M itself |
| Serialization | flock per repo per machine | none, on any machine |

Exit 7, `LANDED UNGATED`, cannot happen on this path. Cross-machine landings
are covered too, which the flock never covered (*Landing onto a moving main*
→ *Across machines*).

**Why a merge commit, not a rebase.** custom lands today by a clean rebase
and a fast-forward push. A rebase makes new SHAs. No pipeline ever ran on
them, and the MR never reads merged. A merge commit keeps H in `main`'s
history, so:

- the green pipeline is on a commit that is literally in `main`, with no
  carry argument;
- GitLab closes the MR as merged on its own;
- the no-CI landing's two-probe `confirm-merged` special case
  (`athena:merge-boarding` → *Confirm the merge actually landed*) goes away
  for GitLab.

`ir_push_covered` already accepts "a clean rebase (or merge) of a gated head
onto the landed main" (`ai/lib/forge-git-passthrough.sh` → *Ungated-main
refusal*), so the receipt rule needs no change. Readers of a linear history
must be audited before the switch (T4).

### D2. Goal 1 on the push: a green pipeline on exactly H

GitLab's "pipelines must succeed" binds MR merges only. A push to `main`
skips it, and the bot pushes as Developer. So the push guard enforces goal 1
itself, on the GitLab route of `forge-git-passthrough.sh`. A push to `main`
in a GitLab project is refused unless, for the gated head H that the pushed M
carries:

1. integration-gate's sealed receipt covers M (exists, DND-1690);
2. the project has a pipeline on exactly H with status `success`, from this
   project (never a fork's), whether an MR pipeline or a branch pipeline.
   No pipeline, a running one or a failed one is refused, with a `Fix:`
   naming H and the pipeline. A pipeline read that fails is COULD NOT LOOK
   and refused. The reader is the one `glmg_check_head` uses;
3. the red-tip judgment on B passes: `gmg_line_check` (the tip's pipelines
   and content) for gen_saas, and the `main-health` marker for custom, as
   today.

Set `only_allow_merge_if_pipeline_succeeds` true on both projects, so a merge
through GitLab's own UI or API also needs a green pipeline. That tightens a
bar. The bot is a Developer and cannot change project settings, so this is a
step only Cody can run (T8).

This adds a check. Nothing in the local bar is removed: integration-gate, the
critic PASS, the review floor, the receipt, `blast-radius` exit 4 and the
red-main stop all stay.

### D3. Remove the serialization

- The custom landing takes no `custom-merge.lock` (S1 retired).
- On GitLab, the CAS lander replaces `locked-merge --mr` (S2, S3 retired
  there). `locked-merge --pr` stays for GitHub until the migration's Phase D
  retires GitHub; that path's forge has no compare-and-swap.
- *Merge one at a time* (S5) becomes "land in parallel; the push decides".
- `merge.lock_wait` is no longer emitted on GitLab. The lead-time phase
  `land_start` falls back to the timed `merge.landed` start (DND-1939), so
  that phase boundary moves. It is a series break (T7).

### D4. Deploy latest

**custom.** custom has no CI deploy. Its deploy is per machine: fast-forward
the main checkout, then `landing-installers` for the landed range
(`athena:merge-boarding` → the no-CI landing, step 5). With parallel landers,
each lander running its own range breaks in two ways:

- two `setup-hooks --install` runs merge into `settings.json` at once;
- a lander that loses the race to fast-forward installs a range that is no
  longer the tip.

So the deploy step coalesces: `ai/bin/deploy-latest --repo <main checkout>`.

1. Take a short deploy lock under the git common dir. It covers the deploy
   only, never a merge.
2. Read the deployed-SHA marker D. Fetch; T = `origin/main`.
3. Fast-forward the main checkout to T, run `landing-installers --from D --to
   T`, write D = T.
4. If `origin/main` moved meanwhile, loop to step 2. Then release.
5. A caller that finds the lock held exits 0 and names the holder, because
   the holder loops to the tip.

A missing or unreadable marker is an error with a `Fix:`, never "deploy
everything" (`~/.claude/CLAUDE.md` → *A failed lookup must never look like an
empty one*). The pre-push `landing-installers --dry-run` check (the no-CI
landing, step 3) stays: a range no one may install is still held.

**gen_saas** deploys latest in its own pipeline (*gen_saas: constraints on
its pipeline*).

### D5. Goal 4 in custom's CI

The workflow rules skip the default branch:

```yaml
    - if: '$CI_COMMIT_BRANCH == $CI_DEFAULT_BRANCH'
      when: never
```

This goes before the branch-pipeline rule. MR pipelines and branch pipelines
for branches with no MR are unchanged. `ai/test/gitlab-ci/self-test.sh`
asserts the rule. With no pipeline on `main`, `glmg_tip_health` reads a
custom tip as COULD NOT LOOK, so `glab-athena mr merge` refuses on custom.
That is correct: custom lands by D1's push, and its red-main signal is the
`main-health` marker.

### D6. Migration-version collisions stay prevented, in parallel

DND-2034 keyed `main-content-checks.json` on the GitLab paths. Under D1 the
content check reads the exact tree that is pushed. A loser of the race
recomputes against the new tip and re-checks before it retries. So two MRs
that each add one migration version cannot both land, and nothing
serializes. The guarantee is the same as `locked-merge`'s, without the lock.

This holds only if gen_saas lands through D1. A gen_saas merge through
`glab-athena mr merge` with no lock would check B and land on whatever `main`
is when GitLab runs it. A collision could then land and be caught only after
it landed, which is weaker than today. Q4.

### gen_saas: constraints on its pipeline

The laptop session owns gen_saas's `.gitlab-ci.yml`. The harness needs:

1. **No test jobs on `main`** (goal 4). The MR pipeline on H is the test.
2. **Every push to `main` still makes a pipeline on its SHA** (the deploy).
   `glmg_tip_health` reads a tip with no pipeline as COULD NOT LOOK and
   refuses every merge onto it. Rules that skip the deploy for docs-only
   changes must still create a pipeline, or the tip judge must learn "no
   pipeline by design", which is a bar change (Q5).
3. **Deploy latest:** the jobs before the deploy are `interruptible: true`,
   so `auto_cancel_pending_pipelines` cancels a superseded pipeline before it
   deploys. The deploy job itself is never interruptible, so an apply is not
   cut midway. It keeps `resource_group: production` with `process_mode:
   newest_first`, and `ci_forward_deployment_enabled` (already true) fails
   an outdated deploy that would start after a newer one.
4. **The tip judge reads the tip only.** A superseded pipeline ends
   `canceled` or `failed` on an older SHA, which the judge does not read. A
   tip whose own pipeline is canceled by hand reads RED (`GLMG_TIP_JUDGE`:
   `canceled` is red). A failed deploy on the tip still stops the line.

## Access control

- **Who may land:** the athena-admiral only, plus the cron lanes' own pushes
  (the existing carve-out). `ai/hooks/merge-role-guard.sh` must match the CAS
  lander and `deploy-latest` by name before either ships (T3, T5). Denial is
  the guard's existing deny with its `Fix:`.
- **As whom:** the namespace's Athena bot through `glab-athena`
  (`ai/config/forge-identities.json`). Never the owner's credentials.
- **Where it is enforced:** the push guard in `ai/lib/forge-git-passthrough.sh`
  (receipt, pipeline on H, red tip), server-side protected `main` (no force
  push, roles only on gitlab.com Free), and
  `only_allow_merge_if_pipeline_succeeds` for UI and API merges.
- **Forks:** a pipeline from another project never counts. A fork MR is
  refused, as `locked-merge --mr` refuses it today.
- **The new tools are held surfaces.** The lander decides a merge, so it
  belongs in `ai/blast-radius/surfaces.json`'s owner-approval-policy hold
  with the merge and push guards (`athena:merge-boarding` → *The receipt
  chain is a held surface*). The `blast-radius --self-test` walk finds it by
  name.

## Accepted risk, unchanged

*Green-alone is not green-merged* stands (DND-1463). Two heads with disjoint
files can each pass and fail together, and no gate runs on that tree before it
lands. Today `main-health` finds it after the landing. If Q1 drops that local
run, the next `integration-gate --rebase` on any branch finds it, because it
gates the branch on top of the current `main`.

## Tickets, in order

| # | Title | Kind | Severity | Files | What proves it |
|---|---|---|---|---|---|
| T1 | custom's MR pipeline passes in the CI image (DND-1998, reopened) | Bug | HIGH | `.gitlab-ci.yml`, the runner kit | A pipeline on a healthy custom head reads `success`, 199/199. Prerequisite for T3 on custom. |
| T2 | custom CI: no pipeline on `main` (goal 4) | Ops | MEDIUM | `.gitlab-ci.yml`, `ai/test/gitlab-ci/self-test.sh`, `ai/test/gitlab-ci/check.rb` | Self-test case: the default-branch rule exists and comes before the branch rule (fails on today's file). Live: after a landing, `pipelines?sha=<tip>&ref=main` lists none. `.gitlab-ci.yml` is in `deploy-automation`, so integration-gate exits 4. Land it before the flip (DND-1947), so no custom landing is ever measured on a `main` pipeline. |
| T3 | Push guard: a push to `main` on GitLab needs a `success` pipeline on the gated head H | Feature (merge-bar control) | HIGH | `ai/lib/forge-git-passthrough.sh`, `ai/lib/glab-merge-guard.sh` (shared pipeline reader), `ai/test/glab-athena-*` | Cases: H with no pipeline, `running`, `failed`, a fork's pipeline, an unreadable read: each refused with `Fix:`. `success` on H: passes. M = merge(B, H): H read as M's second parent. Sabotage record in the suite's `SABOTAGE_RECORDS.md`. Depends on T1. |
| T4 | Audit readers of a linear `main` before merge commits land | Refactor | MEDIUM | `scripts/lib/lane-own-commits.sh`, `ai/bin/lead-time` (patch-id landing match), `ai/bin/confirm-merged --sha`, `ai/bin/landing-installers` | Each reader gets a fixture with a merge commit M(B, H) and keeps its verdict. A reader that cannot is fixed in this ticket. |
| T5 | CAS lander: `scripts/land-merge` in `athena:merge-boarding`, no lock | Feature | HIGH | new `ai/skills/athena:merge-boarding/scripts/land-merge`, its `test/`, `ai/lib/merge_role.rb`, `ai/blast-radius/surfaces.json` | Self-test on a local bare origin. A race injected through a test seam between compute and push: the loser retries and lands. A race that brings in a duplicate migration version: refused `SEMANTIC CONFLICT` on retry. Textual conflict: exit 3. Retries exhausted: exit 6 with `Fix:`. Tree and parent of what landed equal what was checked. merge-role-guard denies a non-admiral. No load, no wall-clock thresholds (DND-1222). Depends on T3, T4. |
| T6 | `deploy-latest`: coalescing post-landing deploy for custom | Feature | MEDIUM | new `ai/bin/deploy-latest`, `ai/bin/landing-installers`, `ai/guard-classification.tsv` | Two landings, one run: installs the union range once and writes the marker. A second caller while the lock is held exits 0 and names the holder. The holder loops when the tip moves (seam). A missing marker is an error with `Fix:`. |
| T7 | Lead time under deploy latest and lock-free landing | Bug | MEDIUM | `ai/bin/lead-time`, `ai/lib/lead_time_phases.rb`, `ai/config/lead-time-series-breaks.json` | A ticket whose own deploy was superseded ends at the first successful deploy whose SHA contains its landing commit (today a canceled or failed deploy ends nothing, so a coalesced ticket never ends). A series-break row at the first lock-free landing (`athena:lead-time-improve` → *Declaring a series break*). |
| T8 | GitLab: `only_allow_merge_if_pipeline_succeeds` true on custom and gen_saas | Ops | MEDIUM | none (project settings) | Only Cody can run: `glab api -X PUT projects/athena-ai-harness%2Fcustom -f only_allow_merge_if_pipeline_succeeds=true`, the same for gen_saas. Verify by reading the field back. Developer push to `main` stays allowed (D1 needs it). |
| T9 | Doctrine sweep: lock-free landing, deploy latest | Docs | MEDIUM | `athena:merge-boarding` (*The merge bar* no-CI landing, *Merge one at a time*, *Landing onto a moving main*, *GitLab path (no merge train)*), `~/dev/custom/CLAUDE.md` (*An admiral merges that PR*, *Two fleets in one repo*), `athena:gitlab`, `athena:shipwright-lane` (cron push: push the branch, wait for its pipeline, then land), `ai/docs/lead-time-improver.md`, `ai/telemetry/events.json` (`merge.lock_wait`) | `grep` for `custom-merge.lock`, `locked-merge --mr`, `one at a time` and `Hold the lock` returns only `Later` labels and GitHub-scoped text. The epic's open ticket bodies (DND-1947 included) are swept too, with an inline pointer where a captain acts (*A supersession sweeps the tickets*). Lands with or right after T5. |
| T10 | Retire `locked-merge --mr` | Refactor | LOW | `scripts/locked-merge`, its GitLab suite | `--mr` exits 2 with `Fix:` naming `land-merge`. After T5 has landed live at least once on each GitLab project. |

The gen_saas pipeline changes (*gen_saas: constraints on its pipeline*) are
the laptop session's tickets, not this list's.

## Questions for the owner

Q1 to Q5 are listed in the design report for the admiral to batch. Each has a
default, so no ticket waits:

- **Q1.** Is `main-health`'s local `harness-gate` on a merged tip "CI again
  post-merge"? Default: keep it. It is local, holds no lock and serializes
  nothing.
- **Q2.** Should cron lanes (shipwright, lead-time) wait for a branch
  pipeline before they land, as goal 1 reads? Default: yes, the restrictive
  reading. Cost: each cron landing waits for the runner.
- **Q3.** With CI running the same `harness-gate` on H, the local
  integration-gate run looks redundant. Default: keep both. Dropping one is
  item 5, so it is Cody's call.
- **Q4.** If gen_saas keeps `mr merge` instead of D1, a migration collision
  is caught after it lands rather than prevented. Default: gen_saas lands
  through D1.
- **Q5.** If gen_saas skips its `main` pipeline for some pushes, may the tip
  judge read "no pipeline" as clean? Default: no; gen_saas makes a pipeline
  for every push.
