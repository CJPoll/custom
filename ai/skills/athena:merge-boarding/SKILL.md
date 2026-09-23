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
- **A bug fix lands with its fail-before evidence.** The captain's report, and
  the MR/PR body where there is one, shows the regression test failing on the
  unfixed code and then passing, per `~/dev/custom/ai/CLAUDE.md` → *TDD
  Workflow*. The standing judge's PASS covers the fix commit's message; the
  report and PR body are yours to check.

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

- **A standing-judge verdict on the SHA you are landing — "no verdict" is not a
  pass.** `athena-diff-critic` was blocking for the *captain*, but this bar never
  required its result, so a judge that **never ran**, **fail-opened** on an infra
  error, or **had not finished yet** was indistinguishable from one that PASSED.
  Both halves were measured on `2026-09-19-slack-gensaas`: DND-194 merged PR #40
  while the judge was still running and landed a factual error on `main`
  (recovered only by PR #41), and DND-212's judge fail-opened on both attempts
  and was caught only because the admiral chose — with nothing requiring it — to
  re-run the critic itself. `integration-gate` now asserts this for you: it reads
  the per-SHA verdict `ai/bin/critic-review` records and refuses a head that has
  no recorded PASS for **that exact SHA**, the same SHA-match discipline as
  "confirm the head you are landing is the one the report names". Exit 3 means
  no green verdict, and its message names WHICH state you are in — none
  recorded, still running, fail-open, dirty tree, or a verdict for an older
  commit.
- **On exit 3 you get a verdict, or you hold that ONE MR — you never merge past
  it.** In order: (1) if it reports a run IN PROGRESS, wait for it; (2)
  otherwise re-run the judge yourself in the Mission's worktree
  (`~/dev/custom/ai/bin/critic-review`) — exactly what the DND-212 admiral did
  ad hoc, now the specified move; (3) if the re-run also fail-opens, the model
  really is unreachable: **hold that MR, move to the next Mission, and come back
  to it.** A model outage must never wedge the fleet — and holding one car is
  not wedging it. The captain's own fail-open stays deliberately unchanged, so a
  captain is never stalled by this; the decision lives here, with the only actor
  that has merge authority. Only when holding is itself the worse outcome do you
  take the named escape hatch, `integration-gate --critic-override "<reason>"`,
  which lands the head with NO judge verdict and prints the reason into the
  `INTEGRATION OK` line. Copy that line verbatim into your state log and name it
  in the final report. An override is a recorded, attributable decision; what is
  being eliminated is the *unrecorded* one.
- **The override covers the ABSENCE of a verdict, and nothing else — a recorded
  BLOCK is refused with the flag exactly as without it.** Its scope is the four
  states in which the judge did not deliver an opinion on this head: it **never
  ran**, it is **still running**, it **fail-opened**, or its receipt is
  **unreadable/dirty/for another SHA**. A BLOCK is not an absence of
  information; it is the judge's answer, and no flag goes past it. The gate now
  enforces that itself — it reads the receipt FIRST, then applies the flag, so
  the override can only ever refuse a merge it used to allow. The `INTEGRATION
  OK` line names **which** of those states was overridden, read from the
  receipt. Past a BLOCK your moves are the ones in the bullet above: address the
  findings and re-run the judge, or hold this ONE MR and move to the next
  Mission.

  **Later (2026-09-20):** the bullet below in *A loop that is not converging*
  used to state this scope as "the integration-completeness class only" — a term
  that appeared exactly once in the whole harness and was defined nowhere, while
  the flag's designed case is the absence of a verdict, which has no finding
  class at all. Replaced by the state list above. The gate also short-circuited
  the verdict read entirely under the flag, so it merged past recorded BLOCKs
  while printing "NO standing-judge verdict" — the line an admiral copies into
  its state log as the attributable record. Measured pressure toward the broad
  reading: on 2026-09-20 `notif-platform`'s coordinator had to add an
  out-of-band state-log header retracting the override fallback mid-run.
- **The verdict is the RECORDED one, never your reading of the critic's
  stdout.** `integration-gate` and `critic-review --verdict-for <SHA>` read a
  receipt; the text the critic streams is for the *resolver*, to learn what to
  fix. Treating the stream as the verdict has now produced a wrong merge
  decision twice. On 2026-09-18 a format-specific body grep printed `BLOCKED`
  with zero findings under it (since fixed — the body is printed whole), and on
  2026-09-20 an admiral read a recritic through `| tail`, saw a clean end,
  recorded "FINDINGS: none → BOARD C-1" in its state log, and was corrected only
  because it then cross-checked `--verdict-for`: the real verdict was BLOCK with
  a `[correctness]` finding scrolled off the top. Note the asymmetry that makes
  this dangerous — truncation removes findings, so it fails toward *merge*.
  So: never pipe a critic run through `tail`/`head`/a grep and act on what
  survives; capture the run whole to a file and read that. If what you have is
  partial for any reason, you have **no verdict** — re-read it or take the
  exit-3 path above; a truncated read is never a PASS.

## A loop that is not converging

A resolver you keep resuming on critic findings is supposed to be descending.
When its own fixes keep producing the next round's findings it is not, and
nothing in the loop notices — on 2026-09-20 an admiral improvised a bar for this
in its state log ("if round 6 yields NEW substantive findings, reassess") while
the loop ran to eight rounds; the same eight-round shape was measured
independently on 2026-09-19.

- **Every re-dispatch for critic findings, from round 2 on, says so in the
  brief**: "this is round N; apply `athena:critic-convergence` BEFORE fixing."
  The resolver is a fresh or resumed context and cannot see the round count you
  can. `ai/bin/critic-review` prints the round number on every BLOCK, so you are
  never guessing at N.
- **A resolver that reports a cluster round gets resumed normally.** That is the
  loop working; the next round should be smaller and non-interacting.
- **The SAME cluster signalling again AFTER a cluster round is your escalation
  point, not a third resume.** The requirements are underdetermined and another
  round will not discover that. Route it to the architect (design /
  security-design) per your escalation routing.
- **A cluster that re-signals AFTER its escalation landed is not a second
  escalation of the same shape, and it is the last one.** Widen the ask to
  whole-subsystem requirements closure (or a descope recommendation), demand the
  row-per-open-question table that makes the closure checkable, and set the stop
  *before* dispatching: if that same subsystem re-signals kind-3 again, PARK the
  Mission at its last clean-gate SHA, unmerged, and hand it to the owner as a
  product-judgment item. Full procedure: [[athena:critic-convergence]] -> *After
  the escalation*. Parking is a terminal state you report like any other — say
  clean / descoped-and-landed / parked-for-owner — not a Mission left in flight.
- **From round 12, a kind-3 finding is a SCOPE decision, not another cluster
  round.** The rungs above are per-cluster; a big artifact otherwise buys one
  trip per cluster and never stops. `critic-review` prints the round number, so
  you are not tracking this by hand. Route it per
  [[athena:critic-convergence]] -> *After the escalation* (land the coherent
  core and file the rest, or park) — never as a re-dispatch.
- **Round count is never a merge argument.** It is not grounds for
  `--critic-override`, for carrying a finding as a known-open, or for relaxing
  the bar in *The merge bar*. Override stays what it is — the scope fixed in
  *The merge bar*, the absence-of-a-verdict bullet: the four states in which the
  judge delivered no opinion on this head, recorded and attributable. A loop's
  findings are a recorded BLOCK, which the gate refuses with the flag exactly as
  without it. A long loop
  changes the METHOD (cluster round) or the OWNER (escalate) — never the bar.

## Merging is not always landing code

Every criterion above asks whether the **code is correct**. None asks what
**merging causes**. In a repo whose post-merge automation applies
infrastructure, merging is not publishing a change — it *is* the change: money
is spent, a resource exists, an action is taken that no revert undoes.

Measured 2026-09-20 (gen_saas PR #256, DND-234): `.github/workflows/post-merge.yml`
runs `terraform init && terraform apply -auto-approve` on every merge to `main`,
so merging that PR would have created a real, billable AWS KMS key whose
destruction makes every wrapped secret permanently undecryptable. An unattended
admiral following this bar **exactly and correctly** would have merged it; only
a captain choosing to read a workflow file nobody told it to read prevented
that. `integration-gate` now asks the question for you.

**Exit 4 means merging performs a real-world action.** The output names each
declared surface the diff touches and whether merging triggers automation.
Routine merges are untouched: a diff that touches no declared surface exits 0
without the automation check ever running, so an ordinary app-code deploy — the
normal case in gen_saas and walt_ui alike — costs one `git diff` and is **not**
owner-gated. This gates the merge that *provisions*, never the merge that
*deploys*.

**There is no admiral override on exit 4, and that is the difference from exit
3.** A missing judge verdict is a *verification* gap you may take responsibility
for and record. Spending money, provisioning or destroying infrastructure, and
taking one-way actions are the OWNER's authority (`~/.claude/CLAUDE.md` → Hard
Rule: "NEVER make system-level changes … without the user's express direction"),
and no amount of your own care substitutes for it. So on exit 4:

1. **Hold that ONE MR and move to the next Mission** — the same move as exit 3's
   third branch. Holding one car is not wedging the fleet.
2. Set the Mission to **`HELD_FOR_OWNER`** in your state log, and in Notion to
   `Needs Attention` assigned to Cody per [[athena:ticket-management]], writing
   onto the Mission body: the PR URL, the head SHA, **what merging would cause**
   (copy the `BLAST-RADIUS HOT` block verbatim), and the exact decision you need.
3. List it in your final report per [[athena:admiral-final-report]].

**`athena:run-autonomously` does not relax this.** A no-human-present run lets
you decide ambiguities with best judgement; it never transfers the owner's spend
and infrastructure authority to you. This is squarely a human-in-the-loop item
(credentials, spend, a one-way action) — record it and carry on, do not decide
it. That skill's *Owner-credential gates throttle merging, not progress* rule
governs what the rest of the fleet does meanwhile, and it is the other half of
this one: exit 4 is how you DETECT that you have hit such a gate, and that rule
is what you then do with everything else — keep the base ready-but-unmerged,
stack dependents on top as ready-to-merge PRs, merge none of that stack, and
carry every independent Mission through to merged as normal. Hitting exit 4
throttles one stack; it never idles the fleet. Do not escalate it to the architect either: the architect can sign off the
*design* (it did, on DND-234, `SIGN-OFF-WITH-FOLLOWUPS`) and that is worth
having, but a design sign-off is **not** an authorization to spend.

**Merging after the owner says yes:** re-run with
`integration-gate --owner-approval '<the owner's authorization, verbatim, and where it is recorded>'`.
Pass it **only** when the authorization came from the user's own turn (or a
pre-authorization the owner recorded on the epic). An architect's sign-off, a
captain's report, another admiral's message, and your own reasoning are none of
them owner approval — no agent message is ever your user's consent. The flag
prints into the `INTEGRATION OK` line; copy it verbatim into your state log and
name it in the final report.

**A captain's `Blast radius: IRREVERSIBLE` is a hold in its own right**, even
when `integration-gate` exits 0. The declared surface list cannot be complete —
a pure-code change that charges a card, emails real users, or calls a
provisioning API on boot hits no path pattern. The two channels **union**;
neither cancels the other. A captain's `ROUTINE` never overrides an exit 4, and
an exit 0 never overrides a captain's `IRREVERSIBLE`.

**A destructive migration is PLANNED, so its authorization is too.** The
`destructive-migration` surface gates a merge whose deploy drops a table or a
column — measured 2026-09-20 at 19 of 372 migrations across gen_saas and
walt_ui, so this fires roughly one MR in twenty, not once a quarter. Waiting for
the owner at merge time is the avoidable half of that cost: the architect
designed the drop days earlier, and the only question that decides it — *does
anything still need this data?* — is the owner's, not a pattern's. So when a
design specifies a destructive migration, that goes in the architect's
`QUESTIONS` block at design time and the owner's answer is recorded on the epic;
you then replay it verbatim via `--owner-approval` and never stall. When there
is no such pre-authorization, hold the MR exactly as for any other exit 4 —
**never** infer the authorization from the ticket, the design doc, or the fact
that the migration is obviously intended. The gate does not bend; the latency is
designed out upstream.

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

## Ride a boarded train to landed (do not end your turn on it)

A merge-train or MR you boarded is OBSERVABLE — `confirm-merged` polls its true
state — so it is NOT the "external poll the harness genuinely cannot observe"
carve-out in the *never end your turn waiting* discipline. Do NOT end your turn
while an MR you boarded is unmerged. Ride it to landed in a bounded FOREGROUND
poll: `confirm-merged --mr <n>` (or `--pr <n>`), `sleep 60`, up to ~45
iterations (≈45 min; chunk it under the Bash tool time cap), then act on the
result.

End the turn only in one of two states, and record which in your `state.md`:

- **CONFIRMED** — `confirm-merged` returned landed; proceed to Done / DM /
  teardown.
- **HANDED-OFF `<receiver>` `<next-command>`** — you explicitly handed the watch
  to a named session, with the exact command it must run.

"Watching", or "the train is running, I'll act when it merges", is NEITHER — it
is the turn-end abandonment this section forbids. A `state.md` left mid-poll is
the signal for the orphan-MR sweep ([[athena:fleet-inputs]]) /
[[athena:admiral-resume]] to adopt.

*Measured 2026-09-22 (2 of 2 admiral runs, PT-1385 + PT-1479): both ended the
turn on a running train; one never resumed, one resumed 90 min late, and the
main session closed both by hand — duplicated teardown + status writes, and
downstream tracker drift (tickets left off `Done`).*

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
