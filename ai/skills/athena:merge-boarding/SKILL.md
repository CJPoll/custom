---
name: athena:merge-boarding
description: How the athena-admiral protects the latency between a green MR and a landed deploy — the merge bar (incl. the no-CI-repo rule), merge-train boarding on GitLab, the GitHub squash-merge path, batching one deploy per batch with the Auto-Deploy label, the label-assertion before a batch tail, confirming a merge actually landed with confirm-merged, the Oban worker-rename gate, and landing onto a main that other fleets are moving under you (rebase, re-gate the integration head, merge one at a time). Use when a captain reports DONE and you are boarding/merging its MR. Merging is the admiral's alone.
---

# athena:merge-boarding

Merging is YOURS, never a captain's — their DONE ends at
green-plus-reviews-plus-report. The quality gates never move; what you control
is the latency between "green" and "landed", which was the dominant waste on
2026-08-27.

## The merge bar

Merge a Mission's MR — with the `Auto-Deploy` label — only once ALL completion
criteria hold: **local gate green, full pipeline green on the current head, and
the captain has addressed the FIRST round of review-bot findings** (must-fix
items fixed, nits replied/resolved) with threads replied.

- **One review round, no more (owner policy, 2026-09-09): there is NO
  expectation of multiple review-bot rounds.** Do NOT play the `*:request` jobs
  to force another review, and do NOT require a clean re-review round before
  merging — "the bots re-ran clean" is not the bar; "first round addressed +
  pipeline green" is. (`*:run` jobs skipping on a later pipeline is expected and
  fine — leave them skipped.)

**A merge criterion is scoped to its evidence model — in a repo with NO CI,
"green" proves nothing and the report IS the gate.** The readiness rules assume
a forge that runs CI and review bots. `~/dev/custom` has no `.github/workflows`
at all, so `gh pr checks` reports no checks and **`MERGEABLE` means only that git
can apply the diff** — a vacuous bar that will merge a branch whose author is
still committing. (Measured 2026-09-18: PR #3 was squash-merged while the
captain's final commit was in flight, and `main` briefly carried everything
EXCEPT an access-control fix.) In such a repo the bar is **the captain's explicit
`DONE` plus its report file** — both, not either — and the local gate it names
(here `ai/bin/harness-gate`) green on the head it reports. Generalising:
**an actively-committing captain is positive evidence of NOT-ready in either kind
of repo** — before merging, confirm the head SHA you are landing is the one the
report names, and never infer readiness from forge state alone while the
captain's worktree is still moving.

## Landing onto a moving main (you are never the only actor in the repo)

`origin/main` moves under you mid-run — another fleet, the shipwright cron, the
owner. Assume it; do not try to find out who. **"Is another fleet live?" is
unanswerable** — every cheap liveness claim is indistinguishable from a corpse
(`CLAUDE.md` → *Agents work in worktrees*, the zero-byte `run.lock`). **"Did
`origin/main` move since my branch point?" is two SHAs**, and it is the only
fact that changes what you do. It also covers the cron and the human, not just
another fleet.

`scripts/wt-preflight` already asserts your branch is not behind `origin/main`
when it is **created**. This is the same assertion when it **lands**.

**Before boarding or merging any MR, from the Mission's worktree, run:**

```
ai/skills/athena:merge-boarding/scripts/integration-gate \
    [--target origin/main] [--since <baseline main SHA>] [--gate '<cmd>']
```

Exit 0 means: your HEAD contains current `origin/main`, **and** the local gate
is green on that integrated head. It prints `INTEGRATION OK <sha>` — merge
*that* SHA (the same SHA-match discipline as the merge bar's "confirm the head
you are landing is the one the report names"). Any other exit tells you what to
do next. It never rebases or writes anything; a rebase can conflict and is your
judgement call.

**Green-alone is not green-merged.** Two MRs with entirely disjoint file sets
can each pass the gate and fail together: the admiral's rendered-line budget is
a single global number (496/500 today — four lines of headroom), and
`ai/hooks/registry.json` / `ai/inbox/registry.json` are single documents. Git
sees no conflict, and in a repo with no CI (`~/dev/custom`) nothing re-runs the
gate after a rebase — so the only thing standing between that defect and `main`
is you running the gate on the integration result. This **adds** a check at a
moment where none ran; it skips none.

**Merge one at a time, re-running `integration-gate` between merges.** This is
the one place the batching rule below is subordinate: batch the *deploy label*,
never the integration check. Merging car N moves `origin/main`, which
invalidates the check for car N+1. Sequential here costs minutes, and it is not
the fan-out parallelism — that already happened during the work.

**Pass `--since` once you have rebased.** After a rebase the original branch
point is unrecoverable, so the incoming delta is empty *by construction* and
the tool reports the intersection `UNAVAILABLE` rather than empty — an empty
intersection would read as "the incoming delta missed my reviewed files, board
it". `--since` is the target SHA your branch was last gated against (your state
log's "baseline main =="). The intersection it then prints is the input to the
**No replay churn** coverage-intersection rule below: empty plus a green
integration gate, board it; non-empty, treat the delta as outside the reviewed
set and replay.

**Do not negotiate with the other fleet.** No messaging, no lock, no deferring,
no reserving a budget line or a registry slot. Two peers deferring to each
other is a race with no arbiter, and it would serialize the *work* phase to
protect a number an existing check already validates at integration.
`origin/main` is the arbiter; rebase is how you lose the race safely. The
accepted, named cost: losing the race is discovered late, so a second fleet
that also spent resident admiral lines may redo one ticket's work at merge
time — rare, bounded at one ticket, and the `check-agent-size` failure names
the budget, so the redo is mechanical.

## Boarding (GitLab merge train — walt_ui, the default)

- **Trigger on DONE, not on sweeps.** Every dispatch brief carries your agentId
  and "message me the instant your report file is written". A DONE message or a
  fresh terminal report is a trigger: verify and add the MR to the merge train
  within 5 minutes. Sweep the merge queue every 5 minutes regardless.
- **No replay churn.** A bot replay is required only when the delta since the
  reviewed head touches files OUTSIDE the reviewed file set (the
  coverage-intersection rule). Merge-forward commits and nit-fix commits inside
  the reviewed set need none.
- **POST to the train only when `detailed_merge_status` is `mergeable`.** Right
  after a merge, GitLab re-checks every open MR's mergeability (`checking`); a
  `POST merge_trains/merge_requests/<iid>` in that window returns without error
  and does NOTHING (measured 2026-08-28, !568). Read the status first, then POST,
  then confirm the car appears in `merge_trains?scope=active`.
- **Board in parallel.** Every MR at the bar goes on the train immediately, all
  at once; never hold one to compose a batch.
- **The boarding checklist is exactly three items**: pipeline green on the
  current head; bot evidence (a note on that head, or the trace, or coverage per
  the rule above); threads addressed. **Read all three off GitLab, not off the
  engineer's report** — a report is bookkeeping you read after boarding, never a
  gate (owner, 2026-08-28: a green, thread-resolved car sat idle waiting for its
  report file). If the report later reveals a waived bar, pull the car or follow
  up; do not hold a green car for paperwork. "Threads addressed" means every
  resolvable bot thread is resolved with a reply on the current head — and, when
  the report arrives, that it names `/address-mr-reviews` as invoked for each bot
  round that had findings. Nothing else happens before boarding — recomputation,
  long state entries, and lessons go after.

## Batching and the deploy label

- **Batch merges, one deploy per batch.** One-merge-per-watched-deploy caps the
  whole machine at ~one merge per 75–100 min however many lanes produce (measured
  2026-08-27: 4 merges in 4.5 h with 12 MRs green). Merge every bar-clearing MR
  back-to-back, in dependency order; put `Auto-Deploy` only on the LAST MR of the
  batch — the deploy gate fires once and one deploy carries the batch. The single
  deploy carries every MR merged since the previously deployed SHA
  (`git log <last-deployed>..<tail>`); read that range yourself only to know which
  risk labels and migrations the deploy carries.
- **Merges are never paced by deploys — only the label is.** Merge (or add to
  the train) every MR the moment it clears the bar, whether or not a deploy is in
  flight; an unlabeled merge never deploys. The one thing the previous deploy
  gates is WHEN you put `Auto-Deploy` on the next tail: when the previous
  deploy's `release:deploy` job has **FINISHED** — Terraform applied, ~2–3 min
  after its merge (`glab api .../jobs?scope[]=success` on main's pipeline). **Not
  INSTANCE_HEALTHY**, and never an AppSignal window (owner decision 2026-08-28:
  `release:create`/`release:deploy` carry `resource_group: production`, so
  applies serialize and cannot collide).
- **Cut-over is confirmed by the CI pipeline itself:** the `release:watch` job
  (after `release:deploy`) proves the new MIG instance is serving and the old one
  gone, prints the `INSTANCE_HEALTHY <host> <ts>` merge-gate line, and writes a
  `HEALTHY | SUSPECT | UNKNOWN` verdict; `release:rollback` reads that verdict and
  reverts an additive-safe SUSPECT deploy or exits cleanly on HEALTHY. There is
  no separate deploy-watcher agent — do not spawn one.
- **Rollback targets the last HEALTHY revision:** a revert must target the last
  revision `release:watch` reported HEALTHY — if the previous batch's verdict is
  not yet in, the rollback target is the one before it, not merely the previous
  sha. Anything `release:rollback` refuses (a migration in the range, a non-clean
  revert) escalates to a human. NOTE: `release:watch`'s AppSignal error-rate
  comparison is SKIPPED until `APPSIGNAL_API_TOKEN` is set in CI (it stamps
  INSTANCE HEALTH ONLY), so cut-over health is MIG/serving only right now.
- Before merging, check whether another lane is mid-batch (main's newest pipeline
  has a labeled tail pending) and join it (merge unlabeled before their tail) or
  wait for it.

**Label assertion before the batch tail boards:** a batch where NO MR carries
`Auto-Deploy` merges into a SILENT no-deploy — `release:create` fails its gate
with `allow_failure:true` and the pipeline stays green. Before boarding the final
car of a batch you intend to deploy, assert at least the tail MR carries
`Auto-Deploy`; if a batch already merged unlabeled, recover with an API retry of
`release:create` (its gate accepts a manual trigger), which plays
`release:deploy` itself.

## GitHub path (no merge train)

On a `github.com` remote there is **no merge train or queue**: merge with
`~/dev/custom/ai/bin/gh-athena pr merge <n> --squash --auto` (branch protection
is the gate, and a refusal for unmet protection is expected, not an auth error),
and the deploy is the repo's own post-merge Actions workflow — no `Auto-Deploy`
label; watch it with `gh run watch <run-id>`. See [[athena:github]]; GitLab
forge mechanics are in [[athena:gitlab]].

## Confirm the merge actually landed (before Done, DM, or teardown)

`glab mr merge` prints `✓ Merged!`, and a merge train can report a car done,
BEFORE the MR is actually merged (under a train the MR `state` stays `opened` for
a while after that success line). Treat neither the CLI line nor a train
notification as proof.

Before you DM the owner, move the ticket to `Done` / `Ready for Release`, or tear
a stack down, **confirm with `ai/bin/confirm-merged` using the FORGE probe** —
`--pr <n>` on GitHub, `--mr <n>` on GitLab (state==merged + a merge timestamp).
A git-ancestry probe (`--sha/--target`) is a **supplementary** check only,
**never the sole probe**: a **squash merge is not a git ancestor** of the target,
so ancestry alone reports a real squash merge as not-landed. `confirm-merged`
exits 0 only when confirmed; treat exit 3 (could-not-determine) as NOT proof the
merge failed — re-verify on the current head rather than trusting silence.
Re-verify after any merge-forward, and reconcile on every wake — a dropped
train-monitor notification is not evidence the merge failed.

*Premature "Merged!" set Notion Done and the DM too early on ui-bg, pt1124,
ui-phase1/2/5, aggregate-alignment, mobile-parity, and pt1280.*

Owner DMs fire on merge for an epic-boundary crossing — see
[[athena:epic-progress-dm]]. Tear the stack down per
[[athena:teardown-worktree-stack]] only after this confirmation.

## Oban worker-rename gate

Before merging an MR that renames an Oban worker module, confirm it ships its
queue migration in the SAME MR — an orphaned queue is invisible to a git diff.
See `ai/docs/oban-worker-rename.md` (incident #473).

---

*Source (behavior-preserving relocation): athena-admiral §6b "Boarding" + the
merge/batch/deploy/rollback bullets of §7 "Hard constraints" + the no-CI merge
bar of §7 + the "Label assertion before the batch tail boards" bullet + "Confirm
a merge actually landed" + the "Worker renames ship their queue migration"
gate reference. The admiral keeps resident one-line triggers pointing here.*
