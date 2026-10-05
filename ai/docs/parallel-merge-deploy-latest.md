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

## What serializes merges (as of 2026-10-05)

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

## What runs after a merge (as of 2026-10-05)

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
- **custom's MR pipeline was not green on 2026-10-05.** DND-1946's header says so (13 of
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
   refused (exit 3, as in `locked-merge`).
3. Read that tree against `ai/config/main-content-checks.json`. A duplicated
   migration version is a `SEMANTIC CONFLICT` (exit 3, as in `locked-merge`).
4. Run the red-tip judgment on B, split by repo (*D2*): gen_saas reads
   `gmg_line_check` (the tip's pipelines and content); custom reads the
   `main-health` marker. Never wire `gmg_line_check` for custom: with no
   `main` pipeline (*D5*) it reads every custom tip as COULD NOT LOOK and
   refuses every landing. What counts as a fix while the tip is red is
   DND-2061's rule (*D7*), never "H contains the red SHA".
5. When B is an ancestor of H, M is H itself: skip the commit, and the push
   is a fast-forward of the reviewed head. Otherwise make M with `git
   commit-tree <tree> -p B -p H` (which always makes a merge commit, so the
   fast-forward case is special-cased, never left to it).
6. Push `M:main` through `glab-athena git push`, never forced.
7. A rejected non-fast-forward means another landing won. Go back to step 1:
   fetch, recompute, re-check, retry. Bounded: 5 attempts, then exit 6 with a
   `Fix:`. A clean recompute needs no re-gate (DND-1463 stands). A conflict
   on the recompute is exit 3, as in `locked-merge`.
8. `confirm-merged --mr <iid>`. GitLab marks an MR merged when its head
   reaches the target, and H is a parent of M.

What this keeps, against `locked-merge` as of 2026-10-05:

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

**Why a merge commit, not a rebase.** Before T5, custom lands by a clean rebase
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
   the push guard reads them as of 2026-10-05.

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

1. Take a deploy lock under the git common dir, blocking on it with a bound
   (`flock -w`). It covers the deploy only, never a merge. A caller that
   finds it held waits; it never exits on the holder's behalf. A timeout is
   an error with a `Fix:` naming the holder.
2. Read the deployed-SHA marker D. Fetch; T = `origin/main`.
3. If D == T, release and exit 0: an earlier holder already deployed this
   caller's landing. That is the coalescing.
4. Otherwise fast-forward the main checkout to T, run `landing-installers
   --from D --to T`, write D = T, and loop to step 2. Release only when
   step 3 holds.

Every landing runs `deploy-latest` after its push. So a landing that arrives
after a holder's last check is not lost: its own call waits for the lock,
then finds D behind T and deploys it.

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
it landed, which is weaker than `locked-merge`'s prevention. Q4.

A collision is the one non-textual refusal this design keeps. Fixing it means
renumbering the branch's migration, a new commit and a new pipeline. That is
a change to the branch's own content, never a requirement to build on the
current `main`.

### D7. A branch is mergeable on the base it was built on

Owner, Cody, coordinator terminal, 2026-10-05 ~08:27Z and ~08:28Z (relayed
verbatim by the admiral): "I do NOT want to require a rebase on each merge;
that's the point of the parallel merges. Running CI repeatedly just for that
reason is a big time slowdown." "Specifically, I don't want a branch to have
to be built on latest main to be mergeable. That's the point of parallel
merges."

So a head H on any earlier `main`, with a green pipeline on H, a critic PASS
and integration-gate's receipt, lands as it stands, on custom and gen_saas.
Nothing requires H to equal, contain, or be rebased onto the current tip, or
to contain a red SHA. The only refusals are a textual conflict and the
migration collision (*D6*). D1 already lands this way: M = merge(B, H) is
built at landing time, and H is never rewritten, so its pipeline never
re-runs.

**T11 lowers a bar, and says so.** `integration-gate`'s "branch behind
target" refusal makes the local gate test a tree that contains the tip at
gate time. After T11 it tests H on its own base, while the tree that lands is
merge(B, H). That narrows what the gate catches, so T11 is item 5
(*Owner approval policy* → *What stays with Cody*), not a speed-up under
`ai/blocks/ops/safety-checks.md`. Two facts bound the loss. First, DND-1463
already lands a clean merge onto a moved `main` with no re-gate, so the
integrated tree was already ungated whenever `main` moved after the gate.
Second, the textual-conflict and migration-collision checks still read the
exact landed tree (*D1*), and `main-health` still gates it after the landing.
The authority is Cody's terminal turn of 2026-10-05 ~08:27Z and ~08:28Z
(session `0cc59a5e-6c65-495e-a216-83c6a0bf2d56`), quoted above. This
document has it only as the admiral's relay, which approves nothing. So T11's
PR carries Cody's verified record (`integration-gate --owner-approval`, or
Cody's own verified Slack message naming the PR and head), or Cody lands the
new bar himself.

Every site that forces a branch onto the latest `main`, as of 2026-10-05:

| Site | What it forces | Replaced by |
|---|---|---|
| `integration-gate` (`--help`: "Asserts that HEAD contains the current target ref"; exit 2 "branch behind target") | H must contain `origin/main` to be gated | T11: gate H as it stands. Record the receipt base as `merge-base(H, origin/main)`, an ancestor of the tip, which every receipt reader accepts (DND-1463). Refuse only a textual conflict, read by `git merge-tree` of H into the target. |
| `integration-gate --rebase`, prescribed in `athena:dispatch-captain`, `athena:shipwright-lane`, `athena:lead-time-improve`, `ai/bin/leadtime-product` and `~/dev/custom/CLAUDE.md` | the branch is rewritten onto the tip, so its MR pipeline must re-run | T11 makes the flag unnecessary; T9 sweeps those briefs to the plain call. The flag stays for a deliberate rebase only. |
| `athena:merge-boarding` → *The merge bar* → the no-CI landing, steps 2-4 (rebase H onto `origin/main`, ff push) | custom lands only a head rebased onto the tip | *D1*: push M = merge(B, H). A merge commit, never a rebase. |
| `athena:merge-boarding` → *Merge one at a time* ("merge `origin/<base>` into a published PR branch … and re-gate") | a forward-merge after any conflict | Kept only for a textual conflict and the migration collision. A moved `main` alone needs nothing. |
| `locked-merge` exit 11, the `gh-athena` and `glab-athena` merge guards' red-tip judgment, and its "red-main fix" exception (the head must contain the red tip) | while `main` is red, only a head containing the red SHA lands | DND-2061 (dispatched 2026-10-05) changes `glmg_tip_gate` and its gh twin. This design takes that rule as given and does not restate it. |
| `forge-git-passthrough.sh` → *Red-main refusal* (custom's `main-health` marker: a push to `main` while red needs a head that contains the red SHA and a receipt on exactly the pushed commit) | the same, on the push path D1 uses | T12: apply DND-2061's rule to the push path, unless DND-2061 already covers it. Under D1, M always contains B, so containment of the red SHA no longer says anything about H. |
| `locked-merge` and the readers in `ai/lib/integration-receipt.sh` | a receipt base that is an ancestor of the tip, contained in H | No change: that is H's own base, not the tip. |
| `scripts/wt-preflight` (a new branch descends from `origin/main`) | only at creation | No change: it is not a merge requirement. |

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
  lander and `deploy-latest` by name before either ships (T5, T6). Denial is
  the guard's existing deny with its `Fix:`.
- **As whom:** the namespace's Athena bot through `glab-athena`
  (`ai/config/forge-identities.json`). Never the owner's credentials.
- **Where it is enforced:** the push guard in `ai/lib/forge-git-passthrough.sh`
  (receipt, pipeline on H, red tip), server-side protected `main` (no force
  push, roles only on gitlab.com Free), and
  `only_allow_merge_if_pipeline_succeeds` for UI and API merges.
- **Forks:** a pipeline from another project never counts. A fork MR is
  refused, as `locked-merge --mr` refuses it.
- **No new owner hold.** This design adds no owner-approval step beyond what
  *Owner approval policy* holds. The lander takes whatever classification
  `ai/blast-radius/surfaces.json` gives the merge and push tools when T5
  lands. On 2026-10-05 (~08:08Z, Cody's terminal turn, relayed by the
  admiral) a separate change narrows the owner hold to the written policy
  and takes merge and push tooling off it.

## Accepted risk, unchanged

*Green-alone is not green-merged* stands (DND-1463). Two heads with disjoint
files can each pass and fail together, and no gate runs on that tree before it
lands. `main-health` finds it after the landing. Under D7 it is the only
detector left: T11 gates each head on its own base, and T9 drops `--rebase`
from the briefs, so no routine gate runs on the current `main` tree. Q1
therefore cannot drop `main-health` without leaving this risk undetected.

## Tickets, in order

| # | Title | Kind | Severity | Files | What proves it |
|---|---|---|---|---|---|
| T1 | custom's MR pipeline passes in the CI image (DND-1998, reopened) | Bug | HIGH | `.gitlab-ci.yml`, the runner kit | A pipeline on a healthy custom head reads `success`, every gate check passing. Prerequisite for T3 on custom. |
| T2 | custom CI: no pipeline on `main` (goal 4) | Ops | MEDIUM | `.gitlab-ci.yml`, `ai/test/gitlab-ci/self-test.sh`, `ai/test/gitlab-ci/check.rb` | Self-test case: the default-branch rule exists and comes before the branch rule (fails on the file as of 2026-10-05). Live: after a landing, `pipelines?sha=<tip>&ref=main` lists none. If `blast-radius` still holds `.gitlab-ci.yml` when T2 lands, the gate exits 4 and the admiral routes it per *Owner approval policy*. Land it before the flip (DND-1947), so no custom landing is ever measured on a `main` pipeline. |
| T3 | Push guard: a push to `main` on GitLab needs a `success` pipeline on the gated head H | Feature (merge-bar control) | HIGH | `ai/lib/forge-git-passthrough.sh`, `ai/lib/glab-merge-guard.sh` (shared pipeline reader), `ai/test/glab-athena-*` | Cases: H with no pipeline, `running`, `failed`, a fork's pipeline, an unreadable read: each refused with `Fix:`. `success` on H: passes. M = merge(B, H): H read as M's second parent. Sabotage record in the suite's `SABOTAGE_RECORDS.md`. Depends on T1. |
| T4 | Audit readers of a linear `main` before merge commits land | Refactor | MEDIUM | `scripts/lib/lane-own-commits.sh`, `ai/bin/lead-time` (patch-id landing match), `ai/bin/confirm-merged --sha`, `ai/bin/landing-installers` | Each reader gets a fixture with a merge commit M(B, H) and keeps its verdict. A reader that cannot is fixed in this ticket. |
| T5 | CAS lander: `scripts/land-merge` in `athena:merge-boarding`, no lock | Feature | HIGH | new `ai/skills/athena:merge-boarding/scripts/land-merge`, its `test/`, `ai/lib/merge_role.rb` | Self-test on a local bare origin. A race injected through a test seam between compute and push: the loser retries and lands. A race that brings in a duplicate migration version: refused `SEMANTIC CONFLICT` on retry. Textual conflict: exit 3. Retries exhausted: exit 6 with `Fix:`. Tree and parent of what landed equal what was checked. merge-role-guard denies a non-admiral. No load, no wall-clock thresholds (DND-1222). Depends on T3, T4. |
| T6 | `deploy-latest`: coalescing post-landing deploy for custom | Feature | MEDIUM | new `ai/bin/deploy-latest`, `ai/bin/landing-installers`, `ai/guard-classification.tsv` | Two landings, one run: installs the union range once and writes the marker. A second caller while the lock is held waits, then finds D == T and exits 0 with nothing installed. The holder loops when the tip moves (seam). A tip that moves between the holder's last check and its release is deployed by the late landing's own call (seam). A lock wait past its bound is an error with `Fix:`. A missing marker is an error with `Fix:`. |
| T7 | Lead time under deploy latest and lock-free landing | Bug | MEDIUM | `ai/bin/lead-time`, `ai/lib/lead_time_phases.rb`, `ai/config/lead-time-series-breaks.json` | A ticket whose own deploy was superseded ends at the first successful deploy whose SHA contains its landing commit (as of 2026-10-05 a canceled or failed deploy ends nothing, so a coalesced ticket never ends). A series-break row at the first lock-free landing (`athena:lead-time-improve` → *Declaring a series break*). |
| T8 | GitLab: `only_allow_merge_if_pipeline_succeeds` true on custom and gen_saas | Ops | MEDIUM | none (project settings) | Only Cody can run: `glab api -X PUT projects/athena-ai-harness%2Fcustom -f only_allow_merge_if_pipeline_succeeds=true`, the same for gen_saas. Verify by reading the field back. Developer push to `main` stays allowed (D1 needs it). |
| T9 | Doctrine sweep: lock-free landing, deploy latest (lands after the 2026-10-05 owner-hold narrowing, which also edits `athena:merge-boarding`) | Docs | MEDIUM | `athena:merge-boarding` (*The merge bar* no-CI landing, *Merge one at a time*, *Landing onto a moving main*, *GitLab path (no merge train)*), `~/dev/custom/CLAUDE.md` (*An admiral merges that PR*, *Two fleets in one repo*), `athena:gitlab`, `athena:shipwright-lane` (cron push: push the branch, wait for its pipeline, then land), `ai/docs/lead-time-improver.md`, `ai/telemetry/events.json` (`merge.lock_wait`) | `grep` for `custom-merge.lock`, `locked-merge --mr`, `one at a time` and `Hold the lock` returns only `Later` labels and GitHub-scoped text. The epic's open ticket bodies (DND-1947 included) are swept too, with an inline pointer where a captain acts (*A supersession sweeps the tickets*). Lands with or right after T5. |
| T10 | Retire `locked-merge --mr` | Refactor | LOW | `scripts/locked-merge`, its GitLab suite | `--mr` exits 2 with `Fix:` naming `land-merge`. After T5 has landed live at least once on each GitLab project. |
| T11 | integration-gate gates a head on its own base (*D7*) | Feature | HIGH | `ai/skills/athena:merge-boarding/scripts/integration-gate`, `ai/lib/integration-receipt.sh`, `ai/skills/athena:merge-boarding/test/` | A head behind `origin/main` with no conflict: gated, receipt base = `merge-base`, `INTEGRATION OK` (exit 2 before the change). A head that conflicts textually with the tip: refused, naming the paths. Every receipt reader (`locked-merge`, both merge guards, the push guard) accepts that receipt. Ship it before T5 so the lander has receipts to land. Item 5 (*D7*): the PR needs Cody's verified record on its head. |
| T12 | Red-main push refusal follows DND-2061's rule | Bug | HIGH | `ai/lib/forge-git-passthrough.sh` (*Red-main refusal*), `ai/lib/main-health.sh`, `ai/test/gh-athena/` | Only if DND-2061 does not cover the push path. While the marker reads RED, a push of M = merge(B, H) is judged by DND-2061's rule, not by M containing the red SHA. Cases per that rule. Depends on DND-2061. |

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
