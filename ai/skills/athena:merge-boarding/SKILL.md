---
name: athena:merge-boarding
description: How the athena-admiral protects the latency between a green MR and a landed deploy — the merge bar (incl. the no-CI-repo rule), merge-train boarding on GitLab, the GitHub squash-merge path, batching one deploy per batch with the Auto-Deploy label, the label-assertion before a batch tail, confirming a merge actually landed with confirm-merged, the Oban worker-rename gate, and landing onto a main that other fleets are moving under you (gate the head, merge one at a time under the lock; a main that moved past the gated base needs a re-gate only on a conflict). Use when a captain reports DONE and you are boarding/merging its MR. Merging is the admiral's alone.
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

- **Merging is the admiral's alone, and a hook enforces it.**
  `ai/hooks/merge-role-guard.sh` (DND-726) denies a merge, a landing onto a
  protected branch, or a spawn of an admiral to every subagent but
  athena-admiral; the one carve-out is the cron shipwright's push from its own
  lane. Its header lists what it matches. If it denies you as the admiral,
  escalate; do not work around it.

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
- **The review floor ran on this change.** The captain's local `code-reviewer`
  + `adr-reviewer` pair is mandatory on every PR/MR (`athena-captain` →
  *Drive CI and review to green*), and the captain names it in its report "so
  the athena-admiral can board on it". Check that the report names it. A
  review bot is not the floor, and on a repo with no bot (gen_saas) the bot
  clause above is empty. A captain that reported DONE-LOCAL (committed, no PR:
  CI paused) never reached that step and says "Review floor: not run". Before
  you merge that head, run the floor yourself against the diff over its
  merge-base, or resume the captain to run it; fix must-fix items like any
  other round. Measured 2026-09-29 (`2026-09-28-unified-priorities`): DND-1183
  and DND-1184 both reported DONE-LOCAL with "Review floor: not run … whoever
  opens the PR should run" it, and the admiral's queue had it push and open
  those PRs itself.

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
captain's worktree is still moving. The one exception is a clean rebase of
that head onto a moved main in `~/dev/custom` (the no-CI landing below): the
report's head is what you confirm, and the rebased SHA you push carries it.

**Later (2026-10-01, DND-1463):** this rule and the verdict rule below had no
exception: the SHA landed had to be the one the report names and the judge
passed. Superseded for a clean rebase in `~/dev/custom` by the owner decision
quoted under the no-CI landing below.

**In a no-CI GitHub repo the pinned merge cannot run.** `gh-athena` refuses a
merge when no check has reported on the head (`ai/lib/gh-merge-guard.sh`, the
`EMPTY` case), so `locked-merge` exits 4 there however good the report is. Do
not retry it, and do not reach for `gh api`: the guard refuses API merges and
ref writes too. `~/dev/custom` lands by a fast-forward `gh-athena git push` of
the gated head (the guard's header names that path). That push is the merge
step, so it takes the same lock `locked-merge` does
(`~/.local/state/athena/custom-merge.lock`, *Landing onto a moving main*).
The landing, as Cody confirmed it (2026-10-01):

1. The report names a head with `INTEGRATION OK` and a critic PASS on it.
   That is the head the merge bar checks.
2. Under the lock, `git fetch origin`, then rebase that head onto
   `origin/main` if main moved. Record the fetched `origin/main` SHA: it is
   the landed range's base in steps 3 and 5.
3. A **clean** rebase lands with no re-gate: push the rebased head
   fast-forward (`gh-athena git push origin <sha>:main`), still under the
   lock, then release it. The pushed SHA is not the reported one; the clean
   rebase carries the reported head's gate and verdict. `gh-athena` checks
   that at the push (DND-1690): in a repo that declares a gate it refuses a
   push to main (`NO RECEIPT`, exit 3) unless integration-gate passed exactly
   the pushed commit, or the pushed tree is the clean merge of a head it
   passed onto `origin/main`. So fetch before the rebase, as above: the
   wrapper reads `origin/main` locally. A stacked ticket's report head was
   gated against the ticket below, so it is never covered: re-gate it
   ([[athena:dispatch-captain]] → *Batch Missions (tier 4)* → the
   `~/dev/custom` landing). Hold the lock around
   the fetch, rebase and push only, never around a gate. Before the push, run
   `~/dev/custom/ai/bin/landing-installers --dry-run --from <step 2's SHA>
   --to <the head>`. If it names an installer and nothing authorizes you to
   run it (step 5), do not push: release the lock, hold the landing, and
   report the install as the step awaiting authorization.
4. A **conflicted** rebase is the one case that needs a full re-gate: release
   the lock, resolve the conflict, run `integration-gate --with-critic` on the
   new head, and start again.
5. **Fast-forward, install, then check `main` after the push**, outside the
   lock, in this order:
   - Fast-forward the main checkout: `git -C ~/dev/custom merge --ff-only
     origin/main` (after `git fetch origin`). A refusal is reported, never
     forced (`~/dev/custom/CLAUDE.md` → *Agents work in worktrees, not the
     main checkout* → *Publishing by fast-forward*). Until it is cleared,
     the installers cannot run (exit 3), so hold the health check too.
   - Run the landing's installers from that main checkout:
     `~/dev/custom/ai/bin/landing-installers --repo ~/dev/custom --from
     <step 2's SHA> --to <the SHA step 3 pushed>`. It installs what the
     landed range needs, keyed on the diff touching a landed-bar registry;
     its `--help` is the one list of which. Skip it and a landed hook or
     inbox row reads as drift, so the tip gates RED (DND-1664). Running an
     installer is an owner-notify item, and that item says which session
     may run it: `~/.claude/CLAUDE.md` → *Owner approval policy* → *Notify
     after* (step 3's dry run kept an unauthorized landing from reaching
     here). Exit 4 names the owner's `setup-hooks --install-env`: ask Cody
     for it per *Only Cody can run*, and run the health check after it.
   - Then `~/dev/custom/ai/bin/main-health check --repo ~/dev/custom` (it
     queues its own gate in test-slot; never wrap it in test-slot). A
     landing that pushed the gated head unchanged is green from its receipt
     with no gate run; only a clean rebase onto a moved `main` costs one
     `harness-gate` of the new tip. Run it in the background if you have
     more to land; it is detection, not a merge gate, so it never holds the
     next push. The hourly shipwright cron runs the same check as the
     backstop for landings made by anyone else.
   - If the landing changed how `ai/bin/lead-time-phases` measures a phase
     (its report or PR body names a series break and its phases), declare
     it: add one row naming the SHA step 3 pushed to
     `ai/config/lead-time-series-breaks.json`, in a follow-up change that
     lands the same way (`athena:lead-time-improve` → *Declaring a series
     break*, DND-1810). The experiment judge sees only declared breaks.

   A cron lane (the shipwright and lead-time runs) stops after step 3: its
   runner fast-forwards the main checkout, and nothing on the cron path
   authorizes an installer. So a cron run whose step-3 dry run names one
   does not push (`athena:shipwright-lane` → *Sync up*).
6. **Stop the line** on a red main or a failed deploy: land nothing more until
   it is fixed, and fix it first. In `~/dev/custom`, `main-health` exit 1 (or
   a `main-red` message on harness-alerts) means `main` is red. While it is,
   `gh-athena git push` refuses any push to `main` (exit 3, `RED MAIN`) except
   a gated fix: a head that contains the red SHA and has its own
   `INTEGRATION OK` receipt. Land the fix, then run `main-health check` again;
   GREEN clears the marker and unblocks the queue. A red you believe was
   environmental: `main-health check --recheck` re-gates the tip. A red whose
   only failure is `check-hooks-registered` or `check-inbox-registry` drift on
   a row the landing added is a skipped install, not a bad landing: run step
   5's `landing-installers` for that landing, then `main-health check
   --recheck`.

**Later (2026-10-02, DND-1664):** step 5 was "Check `main` after the push"
and ran `main-health check` first, with no fast-forward or installer before
it. A landing that added a hook or inbox registry row then gated RED, because
both checks read the bar as landed (DND-1653's landing e4eed785, 01:17Z).
Superseded by the fast-forward and `landing-installers` sub-steps above, and
step 3's dry run, which holds a landing no one here may install.

**Later (2026-10-01, DND-1482):** step 5 said "In `~/dev/custom` nothing gates
`main` after a landing, so the next `integration-gate` is the detector … When
in doubt, run `harness-gate` in a worktree at `origin/main`." Superseded by
`ai/bin/main-health`: the post-landing check above, the red-main marker, and
the push refusal that reads it. The no-re-gate-before-push rule (step 3) is
unchanged.

Nothing in `gh-athena` checks the lock on this path (DND-1370). Measured
2026-09-30 ~10:38Z: an admiral pushed DND-1048/717 unlocked while another held
the lock gating DND-1359, whose push then failed NOT-FF and cost a re-gate.

**Later (2026-10-01, DND-1463):** this said to hold `flock` across
`integration-gate --rebase` AND the push, and to push exactly the SHA
`INTEGRATION OK` names. Superseded by owner decision (Cody): "I'm comfortable
with the risk of multiple merges at the same time; sometimes that will cause
issues and we'll fix those asap. The velocity increase is worth the risk of
incompatible concurrent merges." "That is true for both custom and gen_saas."
A clean rebase onto a moved main is accepted without a re-gate. The lock
still serialises the push itself.

For any other no-CI repo, land CI first, or escalate the merge to Cody as a
step only Cody can run. Measured 2026-09-29 (`2026-09-25-dnd-671-650-644`,
22:02Z): anchor#28 was DONE, gated and critic-PASSed, and the merge was
refused. It waited on Cody, whose click chose "CI first"; DND-1279's workflow
took one captain and a 24 s run.

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
  no green verdict, and its message names WHICH state you are in — no receipt
  in any checkout, still running, fail-open, dirty tree, conflicting receipts,
  could not look, or a verdict for an older commit. The read covers every
  checkout of the repo (main and all worktrees), so you may gate from the main
  checkout on a head the captain judged in its worktree. A receipt inside a
  worktree that has been REMOVED is gone with it, so read the verdict before
  tearing the worktree down.
- **A recorded PASS counts only when the landed judge SEALED it on this
  machine (DND-1814).** Receipts were plain JSON, so a PASS hand-written for a
  head no judge ever ran on read `VERDICT PASS`, and a gate step (the branch's
  own code, run unsandboxed by `integration-gate`) could write one mid-gate.
  `critic-review` now seals every verdict: the producer (the git blobs of its
  own judge files) and an HMAC under this machine's receipt-seal key
  (`ai/lib/receipt_seal.rb`; the key is the per-machine secret
  `receipt-seal-key`). `--verdict-for` reads a PASS only when the seal
  verifies AND every producer blob is the reader's own copy or a version that
  landed on `origin/main`. Otherwise it is exit 3 with the reason:
  `UNSEALED`, `FORGED OR EDITED`, `SEALED UNDER ANOTHER KEY`, `PRODUCED BY A
  JUDGE THAT NEVER LANDED`, or `COULD NOT LOOK` (no key, or a landed history it
  cannot read). The integration receipt is sealed the same way; see *Landing
  onto a moving main*. A carry only carries a sealed source, and a sealed PASS
  copied onto another head's name never counts. The fix is always a re-run of
  the landed judge (or the gate), which seals what it records. A verdict
  recorded before DND-1814 reads `UNSEALED`: re-judge that head. Residual,
  said out loud: this closes every receipt that is merely WRITTEN, not
  deliberate forgery. Code running as this user, a gate step included, can
  still run the sealer (`ai/bin/receipt-seal seal`) or read the key and get a
  receipt every reader accepts. Closing that needs a privilege boundary
  branch code cannot cross (a sealer under another uid, or branch code run
  sandboxed away from the key), not a file format; `ai/lib/receipt_seal.rb`
  says so in its header. Two things stay OPEN, both DND-1808's (which stays
  open; this seal does not fix it): (a) the sealer is an oracle to any
  same-uid process, so deliberate forgery is not closed; (b) gen_saas's
  declared gate needs the docker socket and the network, so it cannot be
  sandboxed. The key is minted once per machine by
  `ai/bin/receipt-seal init-key` (metadata only; a sealing run mints it where
  that has not run).
- **On exit 3 you get a verdict, or you hold that ONE MR — you never merge past
  it.** In order: (1) if it reports a run IN PROGRESS, wait for it; (2)
  otherwise re-run the judge yourself in the Mission's worktree
  (`~/dev/custom/ai/bin/critic-review`) — exactly what the DND-212 admiral did
  ad hoc, now the specified move. On a rebased head whose change is identical
  (same patch bytes, commit messages, prompt and critic definition, and no BLOCK
  on it anywhere), the owner's rule applies: "If a rebase doesn't change the
  branch itself and the last critic review for the branch passed, the critic's
  job should only be to see if the changes from the rebase cause a problem."
  (Cody, 2026-09-27). The earlier PASS covers the branch's own diff, and the
  judge reviews ONLY the upstream delta the rebase brought in, against the
  branch: `PASS (CARRIED + INTERACTION)`, and the gate's OK line says
  `CRITIC CARRIED + INTERACTION` with the range. An interaction BLOCK is a
  BLOCK. With nothing new upstream it says `PASS (CARRIED)` with no model call.
  A changed patch is judged in full, and `--no-carry` forces a fresh full
  review (DND-986); (3) if the re-run also fail-opens, the model
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
  **unreadable/dirty/for another SHA/unverified** (an unsealed or forged
  receipt is no verdict, DND-1814). A BLOCK is not an absence of
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

**Exit 4 means merging does something only Cody's verified decision clears**:
Cody's words in a terminal turn, or Cody's click on the decision DM
(`~/.claude/CLAUDE.md` → *Owner approval policy* → *What still holds
mechanically*). The output names each
declared surface the diff touches, whether it holds (`hold:`), and whether
merging triggers automation. A diff that touches no surface exits 0 without the
automation check ever running, so an ordinary app-code deploy costs one `git
diff` and is not owner-gated. What holds:

- **Only under merge-time automation:** a destructive migration, and terraform.
  Terraform holds whatever the plan until DND-998 can tell a destroy or a cost
  change from a harmless update. Request the go with the plan's summary.
- **In any repo:** forge settings (`.github/settings.yml`, `CODEOWNERS`), a
  check's suppression list, the approval table itself (`ai/CLAUDE.md` → *Owner
  approval policy*), and the classifier and verifier that enforce it.
- **Never:** a deploy-automation edit. It prints `hold: no` and exits 0.

**There is no admiral override on exit 4, and that is the difference from exit
3.** A missing judge verdict is a *verification* gap you may take responsibility
for and record. What exit 4 names is the owner's authority, and no amount of
your own care substitutes for it. So on exit 4:

1. **Hold that ONE MR and move to the next Mission** — the same move as exit 3's
   third branch. Holding one car is not wedging the fleet.
2. Set the Mission to **`HELD_FOR_OWNER`** in your state log, and in Notion to
   `Needs Attention` assigned to Cody per [[athena:ticket-management]], writing
   onto the Mission body: the PR URL, the head SHA, **what merging would cause**
   (copy the `BLAST-RADIUS HOT` block verbatim), and the exact decision you need.
3. **Request the go**: send Cody a Block Kit decision DM (`~/.claude/CLAUDE.md`
   → *Owner approval policy* → *Asking, and what counts as approval*). Do not
   wait silently. The DM names the PR and the full head SHA, and its approve
   button's `value` is `approve-exit4 <owner>/<repo>#<pr>@<full head sha>`,
   shown verbatim in its text too, posted with `inbox_name` set to this
   project's `session` inbox (`athena:slack` → *Asking the owner for a
   decision*). That button is what the gate can verify.
4. List it in your final report per [[athena:admiral-final-report]].

**Later (2026-09-28):** exit 4 fired for every declared surface, deploy-workflow
edits included, and a change a standing approval covered (a security fix)
merged past it by replaying the rule's quoted text. Superseded by *Owner
approval policy*: exit 4 fires only for what that policy keeps, no standing
approval is replayed, and `--owner-approval` takes a verifiable record.

**`athena:run-autonomously` does not relax this.** A no-human-present run lets
you decide ambiguities with best judgement; it never transfers the owner's
authority to you. Record it and carry on; do not decide it. That skill's
*Owner-credential gates throttle merging, not progress* rule governs what the
rest of the fleet does meanwhile: keep the base ready-but-unmerged, stack
dependents on top as ready-to-merge PRs, merge none of that stack, and carry
every independent Mission through to merged as normal. Hitting exit 4 throttles
one stack; it never idles the fleet. Do not escalate it to the architect either:
the architect can sign off the *design* (it did, on DND-234,
`SIGN-OFF-WITH-FOLLOWUPS`), but a design sign-off is **not** the owner's go.

**Merging after the owner says yes:** re-run with
`integration-gate --owner-approval 'session:<session-uuid>/<message-uuid> quote:<the owner's words, verbatim>'`.
The reference names the turn the owner typed, in the Claude Code session where
they typed it. `blast-radius` checks the transcript and refuses anything else:
free text, a rule citation, an architect's sign-off, a captain's report,
another agent's message, a Slack reply. A coordinator that heard the owner
relays the reference, never a paraphrase. A record passed on a head nothing
holds is refused (exit 2), so drop it there. The record prints into the
`INTEGRATION OK` line and the receipt; copy the line into your state log and
name it in the final report.

**Or merge on the owner's click:** re-run with
`integration-gate --owner-approval 'click:<delivery_id>'`, the `delivery_id`
of the owner's `slack.interaction` line on this project's `session` channel
(`read-inbox --json`). `blast-radius` reads that line itself and refuses, with
a `Fix:`, a click relayed from another channel or project, a non-owner
click, a click on another message, a click for another PR, an approve the
owner later reversed or held, and a record it cannot verify (`integration-gate
--help`). The click names one head, A. It also clears head B, origin's
current head of the same PR, when the PR's own diff (`git diff --binary
<merge-base(target, head)> <head>`, against the gate's target) is
byte-identical at A and B (DND-1832). So a rebase or a merge of main that moves no byte of the PR's own
change needs no new click: push B, then run the approval gate on B without
`--rebase`. Any byte difference refuses with both merge-bases named, and
needs a new DM and a new click on B. The gate needs A's objects; it says
"could not look" with a fetch `Fix:` when they are missing. This clears
every hold, the approval rules' own surface included.

**Later (2026-10-03, DND-1832):** a gate that rebased always needed a new DM
and a new click, so the advice was to rebase and gate first, then ask.
Superseded by the carry rule above, which the owner approved by click
(`~/.claude/CLAUDE.md` → *Owner approval policy* → *Asking, and what counts
as approval*).

**Later (2026-10-02, DND-1784):** exit 4 was cleared only by "Cody's verified
words", the terminal-turn record, so a click-decided exit 4 waited for typed
words. Superseded by owner decision, Cody, terminal turn
2026-10-02T17:45:26Z: "Gate accepts a verified owner click, without
hesitation."

**A captain's `Blast radius: IRREVERSIBLE` is yours to judge**, even when
`integration-gate` exits 0. It flags what the classifier cannot see
(*Owner approval policy* items 1–3): a pure-code change that deletes prod data,
starts a recurring charge, or emails real users hits no path pattern. Decide it
on the policy's best judgement (prefer reversible; never casually destroy prod
data), record the call on the Mission, and list it in your final report. A
captain's `ROUTINE` never overrides an exit 4.

**Later (2026-09-28, ~07:15Z):** this was "a hold in its own right … Hold it
and request the go as for exit 4." Superseded by owner decision (*Owner
approval policy*): "I would prefer you not even dm me unless it's something
that only I can run." Items 1–3 are judgement calls; only exit 4 still holds.

**A destructive migration is PLANNED, so its authorization is too.** The
`destructive-migration` surface gates a merge whose deploy drops a table or a
column — measured 2026-09-20 at 19 of 372 migrations across gen_saas and
walt_ui, so this fires roughly one MR in twenty, not once a quarter. Waiting for
the owner at merge time is the avoidable half of that cost: the architect
designed the drop days earlier, and the only question that decides it — *does
anything still need this data?* — is the owner's, not a pattern's. So when a
design specifies a destructive migration, that goes in the architect's
`QUESTIONS` block at design time, and the reference to the owner's answering
turn is recorded on the epic; you then replay that record via
`--owner-approval` and never stall. When there is no such pre-authorization,
hold the MR exactly as for any other exit 4 — **never** infer the authorization
from the ticket, the design doc, or the fact that the migration is obviously
intended. The gate does not bend; the latency is designed out upstream.

## A finished security fix merges first

Among the MRs you have ready to merge, a finished security fix goes first. On
a GitLab merge train, board it first. Owner, Cody, 2026-09-27 (~10:45Z,
coordinator terminal), asked whether a finished security fix still goes to the
front of the merge queue under the critical-path rule: "1. 'A finished fix'
sure - that's fine. I'm not talking about the merge queue; I'm talking about
the order in which an admiral assigns tickets to captains."

A fix for a security control that fails closed (`Control` = `fails-closed`)
goes first too. It is a Bug, not security, but it keeps security's priority
(`~/.claude/CLAUDE.md` → *Owner approval policy* → *Security fixes*).

It orders only your own ready set. The fix still meets *The merge bar*, and it
still waits for the merge lock like any other merge (*Landing onto a moving
main*). Which ticket a captain works next is [[athena:ticket-management]] →
*Priority: critical path first*.

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

**Before boarding or merging any MR, with the Mission's worktree as the cwd,
run the main checkout's copy:**

```
cd <the Mission's worktree> && ~/dev/custom/ai/bin/integration-gate \
    [--target origin/main] [--since <baseline main SHA>] [--gate '<cmd>']
```

That path is a shim (DND-752) for
`ai/skills/athena:merge-boarding/scripts/integration-gate`. Name it in a brief,
never the worktree's own copy.

**The judges are the landed ones (DND-1796).** When the gated repo is
`~/dev/custom` itself, the copy of `integration-gate` you start never judges.
Inside the slot it reads the target's `ai/` tree out of git into a temp dir
and re-executes the target's copy of itself from there. So
`integration-gate`, the libs it sources, `blast-radius`, its manifest
(`ai/blast-radius/surfaces.json`), the owner verifiers (`ai/lib/owner_turn.rb`,
`ai/lib/owner_click.rb`) and `critic-review` are the target's. No checkout's
working tree is read, the main checkout's included. A judge the
`--with-critic` pre-start ran from a checkout whose `critic-review` or
`ai/lib` is not the target's is stopped, and the landed judge runs. A judge
the target lacks, or an object git cannot read, is exit 2, never the branch's
copy. A branch that edits `integration-gate` itself still lands, judged by the
landed copy. The residual: this runs in the copy the caller starts, and a
branch's own copy can drop it. So run the main checkout's path above. A
receipt that copy's own judges seal does not pass: every receipt names the
judge files that sealed it, and a reader refuses one whose files never landed
(DND-1814). That copy can still run the LANDED sealer and get a receipt every
reader accepts: OPEN, DND-1808 (a), the sealer is an oracle to any same-uid
process. Another repo (gen_saas) cannot edit these judges in its diff; its
gate uses the copies beside the script, and its gate cannot be sandboxed
(OPEN, DND-1808 (b)).

**Later (2026-10-02, DND-1814):** the residual above also said "a critic
receipt is a file any process can write". Narrowed, not closed: a merely
WRITTEN receipt (unsealed, edited, or from an unlanded judge) is now refused,
but same-uid code that runs the sealer on purpose still gets an accepted
receipt (DND-1808, open; *The merge bar*, the sealed-PASS bullet).

**Later (2026-10-02, DND-1796):** this said to run the gate "from the
Mission's worktree" as `ai/skills/athena:merge-boarding/scripts/integration-gate`,
and "Either path is correct in a brief". Superseded: run from a custom
worktree, that path ran the branch's own gate, `blast-radius`, manifest and
owner verifiers. One commit that dropped a held surface from the manifest read
`BLAST-RADIUS COLD` under its own classifier and HOT, exit 4, under the landed
one.

**The receipt chain is a held surface (DND-1807).** A diff that touches
`integration-gate` (the script and its `ai/bin` shim), `ai/lib/integration-receipt.sh`,
`ai/lib/receipt_seal.rb`, `ai/bin/receipt-seal`, the merge and push guards
(`ai/lib/gh-merge-guard.sh`, `ai/lib/glab-merge-guard.sh`,
`ai/lib/forge-git-passthrough.sh`), the merge role guard
(`ai/hooks/merge-role-guard.sh`, `ai/lib/merge_role.rb`,
`ai/lib/merge_role_io.rb`), the forge identity guards that refuse a forge
write or push not made as Athena (`ai/hooks/forge-identity-guard.sh`, the agent
PATH wrappers `ai/agent-bin/git`, `ai/agent-bin/gh` and `ai/agent-bin/glab`,
`ai/lib/agent-forge-push.sh`, `ai/lib/agent-forge-cli.sh`, and
`ai/agent-env/session-env.sh`, which puts the wrappers on PATH), the forge
auth guard that keeps the owner's forge credentials from agents
(`ai/hooks/forge-auth-guard.sh`), and what they load to decide a call is a
merge, a push or a forge write (`ai/lib/forge-api-scan.sh`,
`ai/lib/forge-cli-isolation.sh`, `ai/lib/forge-write-class.awk`),
`ai/bin/gh-athena`, `ai/bin/glab-athena`,
`locked-merge`,
`ai/bin/main-health` and `ai/lib/main-health.sh` (the push guard's fix-push
exception reads a receipt), the private overlay resolver and rules the
owner-click verifier reads the owner's id through
(`ai/lib/private_overlay_resolver.rb`, `ai/lib/private_overlay.rb`), or the
critic verdict producer
(`ai/bin/critic-review`, `ai/lib/critic_carry.rb`,
`ai/lib/critic_verdict_stores.rb`) is `owner-approval-policy`, hold `always`:
exit 4, cleared by the owner's verified decision (*Owner approval policy* ->
*Asking, and what counts as approval*). The gate judges with the manifest as
landed on the target, so a new hold binds after it lands, never in the PR that
adds it. Not held: `confirm-merged`, `ai/bin/test-slot`,
`ai/bin/ready-and-idle` (it reads a receipt to
report, and decides nothing), `ai/lib/critic_prompt.rb` (the rubric text, not a
trust decision) and the judge-set utilities `proc-stat.sh` and
`telemetry-emit.sh`, which write no verdict. The manifest's
`enforcers.excluded` names every other candidate left out, with its reason.

**Later (2026-10-03, DND-1873):** this paragraph listed `ai/lib/glab-merge-guard.sh`
as not held, "though it decides GitLab merges on the receipt since DND-1845".
Superseded: the guard and `ai/bin/glab-athena` are in the same class as the
GitHub pair, so a diff that weakened `glmg_receipt_gate` no longer reads COLD.
`blast-radius --self-test` walks every tracked file that sources
`integration-receipt.sh` and fails, with a `Fix:`, on one that decides a merge
or push and is not held.

**Later (2026-10-03, DND-1888):** this paragraph did not name the merge role
guard, so DND-1865's change to it read COLD. It enforces that merging is the
admiral's alone (DND-726) and now sits in the same class: a diff that weakens
who may merge needs the owner's record. `blast-radius --self-test` has a case
per file.

**Later (2026-10-03, DND-1892):** this paragraph did not name the forge
identity guards, so DND-1881's and DND-1887's changes to them read COLD: a diff
that let an agent push to a forge on the owner's key needed no owner record.
They sit in the same class from DND-1892, with the forge auth guard and the
libraries the held files load. The third such gap in one night, so the class
is closed by a walk, not a list: `blast-radius --self-test` computes the
candidate enforcers (every hook wired or retired in `ai/hooks/registry.json`;
every file under `ai/agent-bin`, `ai/agent-env` and `ai/git-hooks`; every file
under `ai/lib`, `ai/bin`, `scripts/wt-lib` and a skill's `scripts/` or `bin/`
named for forge, merge, receipt, seal, agent or push; and every `ai/lib` file a
held file loads) and fails, with a `Fix:`, on one that neither holds nor sits in
the manifest's `enforcers.excluded` with a reason, or that is both.

**Later (2026-10-03, DND-1895):** the declared merge gate `ai/bin/harness-gate`
was in neither list, so a diff that dropped a check from it read COLD: a
lowered bar (item 5) with no owner hold. It sits in the same class from
DND-1895, with `ai/lib/first_party.rb`, `ai/lib/harness_tools.rb` and
`ai/lib/landed.rb`, which it loads to discover its checks and to read their
bar from what landed. The walk also reads `IR_DECLARED_GATES` in
`ai/lib/integration-receipt.sh`, so the gate the target declares is a
candidate whatever its path and a renamed gate cannot fall out. The gate's
other loaded libraries (`reap_tags.rb`, `proc_state.rb`,
`scratch_home_sentinel.rb`, `athena_telemetry.rb`) are in `enforcers.excluded`
with reasons.

**The gate comes from the landed target, not from you.** The first of
`bin/prep-commit.sh` (gen_saas) and `ai/bin/harness-gate` (`~/dev/custom`) that
exists on `origin/main` is the repo's declared gate, and it always runs. Omit
`--gate` there; a `--gate` that differs from it is refused (exit 2). Pass
`--gate` only in a repo that declares neither, and pass its real gate (e.g.
`--gate 'cd backend && mix test'`). A command that can never fail — `true`, `:`,
`exit 0`, `echo …`, an empty string, or a real check masked by `|| true`,
`; true` or a trailing `&` — is refused (exit 2). "The gate already ran on this
head" is not a reason to skip it: the integrated head is the one being judged.
(DND-479: `--gate true` on gen_saas PR #337 printed `INTEGRATION OK` exactly like
a real run.) A branch that edits its own declared gate (`harness-gate`) still
runs its own copy, but the
run warns and the OK line says `EDITED BY THIS BRANCH` — review that diff.

**`--target` does not retarget the gate's own stages.** A stacked branch whose
base conflicts with main gates RED under any `--target` (`integration-gate
--help` → `--target`). So a brief for a local stack behind main cannot ask for
`INTEGRATION OK`; name what the captain reports instead, and re-integrate the
stack base onto main once. (DND-302, 2026-09-28: the captain merged main into
its stacked branch; DND-1187, 2026-09-29: the brief's `INTEGRATION OK` was
unreachable.)

**Run the judge beside the gate: `integration-gate --with-critic`.** It starts
`critic-review --base <target>` on this head concurrently with the gate (queued
in test-slot's model pool; see *Weights and pools* below), unless
a PASS that covers the target is already recorded for it. A PASS covers the
target when the base it was judged against is the target or an ancestor of it;
one judged against a stacked parent covers only that branch's commits, so the
gate re-judges (and without the flag, refuses it, exit 3). It joins the judge even on a RED gate, so
one round returns both sets of findings, then reads the verdict exactly as
without the flag. Use it for a captain's final check and after every rebase
the captain makes: a new SHA needs both a new gate and a new verdict. The one
exception is the admiral's clean rebase at landing in `~/dev/custom` (*The
merge bar* → the no-CI landing), which carries the reported head's gate and
verdict. It changes the wall time,
max(gate, critic) instead of the sum, and nothing else. The judge runs in its
own process group, and the script stops that group if it leaves early.

Exit 0 means: your HEAD contains current `origin/main`, **and** the local gate
is green on that integrated head. It prints `INTEGRATION OK <sha> (GATE: <cmd>
-- <source>)` — merge *that* SHA, and copy the line whole so the record says
which gate ran (the same SHA-match discipline as the merge bar's "confirm the head
you are landing is the one the report names"). On GitHub, `locked-merge` merges
that SHA even after main moved, if the move does not conflict. In
`~/dev/custom` you push the clean rebase of it (the no-CI landing). Any other
exit tells you what to do next. Without `--rebase` it never rebases or touches
the working tree or a ref; with it, it rebases only a clean branch and refuses
on a conflict (below). Its one other write is its **receipt**: on exit 0,
and only then, it records the pass at
`<git common dir>/integration-receipts/<head-sha>.json` (head, the target SHA it
contained, gate and source, any override or owner approval, blast radius, the OK
line, UTC time), sealed (DND-1814): the producer (the git blobs of the gate
files that wrote it) and an HMAC under this machine's receipt-seal key, added by
`ai/bin/receipt-seal`. Every other exit removes the receipt for that head, and a
receipt error is exit 5 with no OK line: a stale receipt it cannot remove (before
the gate runs, so no gate ran), or a receipt it cannot write or seal after a
green gate. `locked-merge` requires the receipt, and every reader verifies the
seal (*Landing onto a moving main*).

**Later (2026-10-01, DND-1463):** this paragraph and the `--with-critic` one
above had no exception: a rebase always needed a new gate and verdict, and the
SHA landed was always the one `INTEGRATION OK` names. Superseded by the
owner's landing doctrine as the DND-1463 ticket records it: custom lands by a
clean rebase plus ff push, with `custom-merge.lock` around the push only, and
re-gates only after a conflicted rebase. Cody's words behind it are quoted
under the no-CI landing in *The merge bar*.

**Later (2026-09-27, DND-965):** this paragraph said the gate "never rebases or
writes anything". Superseded: it now writes the receipt above. Without it, "the
gate passed on this SHA" rested on the caller's word, and gen_saas #468 merged
past a RED gate because a prep script printed READY without reading the exit
code.

**Later (2026-09-28, DND-1064):** this paragraph said "It never rebases or
touches the working tree or a ref". Superseded: `--rebase` rebases a clean
branch inside the test slot and refuses on a conflict (see *`--rebase`* below).

**The gate runs in a machine test slot (DND-486), taken first (DND-1064).**
`integration-gate` takes a slot of
the main checkout's `ai/bin/test-slot`
(`~/dev/custom`, found from the script's own git common dir, so a worktree copy
never sets the budget) before it fetches. The fetch, the containment check, `--rebase`,
the gate and the verdict all run inside that slot, so "HEAD contains
`origin/main`" is judged when the gate starts, never before the queue wait. The
bar is unchanged; only when it is read moved. You do nothing extra. A
`test-slot: WAITING` line is a queue, not a stall. **Exit 6 means GATE NOT RUN**: no slot freed within the wait window (or
test-slot left no outcome). Nothing was checked, so it is neither OK nor RED.
Re-run `integration-gate`; never merge on it. A `--with-critic` judge is still
joined first, so its verdict is recorded and the re-run does not pay for it
again. `test-slot --status` names what holds the pool. A test-slot missing
from the main checkout (`~/dev/custom/ai/bin/test-slot`) is exit 2: update that
checkout; the gate never runs unslotted. `--slot-wait-timeout <secs>` sets the wait. It can only turn a wait
into exit 6, never into a pass. Running `integration-gate` itself under
`test-slot` (the captain brief's form) is safe: the inner wrap sees the slot it
already holds and does not queue again. A dirty tree and missing `--with-critic`
tools are refused before the wait, so they never cost a queue. The
`--with-critic` judge still starts before the wait on the current head; after a
`--rebase` it is stopped and the rebased head is judged.

**Weights and pools (DND-1326).** Run bare, the slot holds the weight test-slot
gives the declared gate itself (`test-slot --weight-of`): a `harness-gate` its
worker count (`HARNESS_GATE_JOBS`, else harness-gate's default), any other gate
test-slot's default. A main
checkout whose test-slot predates `--weight-of` gives the default, and the
run's "taking a machine test slot first" line says which weight it took. The
`--with-critic` judge queues in test-slot's model pool, never the CPU pool. A
judge started inside the slot (after a `--rebase`) waits for its model unit
while the gate holds its CPU units; `--slot-wait-timeout` bounds that wait, and
a judge the model pool never admits records no verdict (exit 3, test-slot's
`TIMEOUT` in its log), never a pass.
In the captain form the caller's own slot is the one that counts, so it holds
the weight `test-slot -- integration-gate` gives (the default); a caller that
knows its gate is heavier passes `--weight`.

**Later (2026-09-30, DND-1326):** this section said the slot takes
"test-slot's default CPU weight", and the judge ran outside both pools.
Superseded for bare runs: a `HARNESS_GATE_JOBS=16` gate still weighed 8, and
nothing bounded the in-gate judge by model concurrency.

**`--rebase`: absorb a main that moved while you queued.** Inside the slot,
after the fetch, if HEAD does not contain the target, it rebases the checked-out
branch onto it and gates (and judges) the rebased head. It refuses a dirty tree
before anything moves. On a conflict it aborts, names the conflicting paths as
`REBASE CONFLICT`, and exits 2 with the branch at its original head; it never
resolves one. With no `--since`, the intersection is measured from the
pre-rebase branch point. It refuses a main checkout and a detached HEAD. After
a clean rebase the branch stays rebased whatever the gate or judge then say
(the old head is `ORIG_HEAD`). Push a rebased captain branch as Athena
(`athena:github` → *Pushing as Athena*) before landing it. Without `--rebase`,
a head that does not contain the target read inside the slot is refused
exactly as before, and the `Fix:` offers `--rebase`.

**Later (2026-09-28, DND-1064):** the gate read `origin/main` and judged
containment before its test-slot wait. A captain that wrapped it in test-slot
had rebased before that outer wait, so the main its head contained was stale
by gate start. Queue waits of 5-26 min now
exceed the gap between landings, so DND-907, DND-896+945 and DND-902 each
refused twice, and the admiral lost three landing windows in a row. Unwrapped,
the same order let a gate start on a head that no longer contained the main
of gate start. The admiral's workaround was the machine-local
`ai-artifacts/coordination/2026-09-28-harness-lane/helpers/gate-in-slot.sh`
(take the slot, rebase inside it, re-enter it); the slot-first order and
`--rebase` replace it.

**Green-alone is not green-merged.** Two MRs with entirely disjoint file sets
can each pass the gate and fail together: the admiral's rendered-line budget is
a single global number (496/500 today — four lines of headroom), and
`ai/hooks/registry.json` / `ai/inbox/registry.json` are single documents. Git
sees no conflict. Since DND-1463 that combination is **not gated before it
lands**: each car's gate ran on its own base, and a car whose base main has
moved past lands without a re-gate. The defect is caught after landing, by the
next gate that runs on a `main` containing both (gen_saas: its post-merge CI;
`~/dev/custom`: the next `integration-gate`, see the no-CI landing above), and
the line stops until it is fixed. This is the risk the owner accepted.

**Later (2026-10-01, DND-1463):** this said "the only thing standing between
that defect and `main` is you running the gate on the integration result",
which "**adds** a check at a moment where none ran". Superseded by the owner
decision quoted under *Merge one at a time* below: the gate on the
integration result runs only after a conflict.

**Merge one at a time; a main that moved on does not force a re-gate.** The
merge call itself stays serial under the lock. But a receipt whose recorded
base is an **ancestor** of current `origin/<base>` is accepted: car N landing
does not invalidate car N+1's gate. Car N+1 lands if its head merges into the
new tip with no conflict. A conflict is refused (by `locked-merge` before the
call, and by GitHub). Only then do you bring main in and re-gate: merge
`origin/<base>` into a published PR branch (never rebase it), or rebase an
unpublished one, resolve, and re-gate. Stop the line on a red main or a failed
deploy: land nothing more until it is fixed.

**Later (2026-10-01, DND-1463):** this said "re-running `integration-gate`
between merges", because merging car N invalidated the check for car N+1:
the receipt's base had to EQUAL `origin/<base>`, and the head had to contain
it. Superseded by owner decision (Cody, 2026-10-01): "I'm comfortable with
the risk of multiple merges at the same time; sometimes that will cause issues
and we'll fix those asap. The velocity increase is worth the risk of
incompatible concurrent merges." "That is true for both custom and gen_saas."
"Let's soften that merge guard requirement." The accepted risk is the one
*Green-alone is not green-merged* names: two cars with disjoint files can each
pass and fail together, and no gate runs on that combination before it lands.
It is found by the next gate on `main`, and fixed first.

**Pass `--since` once you have rebased.** After a rebase the original branch
point is unrecoverable, so the incoming delta is empty *by construction* and
the tool reports the intersection `UNAVAILABLE` rather than empty — an empty
intersection would read as "the incoming delta missed my reviewed files, board
it". `--since` is the target SHA your branch was last gated against (your state
log's "baseline main =="). `--rebase` records the pre-rebase branch point
itself, so pass `--since` only after a rebase you did by hand. The intersection it then prints is the input to the
**No replay churn** coverage-intersection rule below: empty plus a green
integration gate, board it; non-empty, treat the delta as outside the reviewed
set and replay.

(Qualified: see **Later (2026-09-26)** below. This holds for the WORK phase;
the merge itself is a critical section.) **Do not negotiate with the other fleet.** No messaging, no lock, no deferring,
no reserving a budget line or a registry slot. Two peers deferring to each
other is a race with no arbiter, and it would serialize the *work* phase to
protect a number an existing check already validates at integration.
`origin/main` is the arbiter; rebase is how you lose the race safely. The
accepted, named cost: losing the race is discovered late, so a second fleet
that also spent resident admiral lines may redo one ticket's work at merge
time — rare, bounded at one ticket, and the `check-agent-size` failure names
the budget, so the redo is mechanical.

**Later (2026-09-26):** the paragraph above holds for the *work* phase, and only
there: never reserve a budget line or a registry slot, never defer work to
another fleet. It was wrong about the *merge*. "Rebase is how you lose the race
safely" assumed the forge refuses a merge onto a moved base. GitHub does not: a
squash-merge onto a base that moved after `integration-gate` ran, with no
textual conflict, lands a tree nobody gated (gen_saas 2026-09-23: AM-2's squash
landed on DND-347's merge a minute later, integrated head ungated). Check-then-
merge is a TOCTOU. `origin/main` is still the arbiter of *what is true*; it does
not serialize *who merges*. Six fleets then hand-rolled the same flock recipe
from prose (2026-09-22..26 state logs).

So the merge step is a critical section on every GitHub-merged repo:

- **Same machine:** merge through
  `ai/skills/athena:merge-boarding/scripts/locked-merge --pr <n> --head <sha>`,
  never a bare `gh-athena pr merge`. `<sha>` is the one `INTEGRATION OK` names.
  (The wrapper refuses that bare call anyway in a repo that declares a gate: it
  requires the same receipt, DND-969.) It takes the repo's merge lock (`~/.local/state/athena/<repo>-merge.lock`,
  the path fleets already share), fetches, and requires under it
  `integration-gate`'s receipt for exactly `--head`, recorded against
  `origin/<base>` or an **ancestor** of it, and contained in the head
  (DND-965, DND-1463). When main moved past the receipt's base it prints
  `BASE MOVED`. It then computes the expected squash tree, `git merge-tree`
  of the head into `origin/<base>` (the head's own tree when the base did not
  move), and refuses a conflict there (exit 3) before any merge call. It
  merges pinned to that head, runs `confirm-merged`, and asserts the landed
  commit's parent is the checked base and its tree is that expected tree, so a
  forge that lands anything else is still `LANDED UNGATED` (exit 7). Then it
  releases the lock and runs `ai/bin/teardown-stack` for the PR's worktree
  stack (DND-864). Its exit code names the next step (`--help`).
  Still run `integration-gate` first, still merge one at a time. With no
  usable receipt it refuses before merging, exit 9, and says which:
  `NO RECEIPT`, `RECEIPT UNREADABLE (COULD NOT LOOK)`, `RECEIPT INVALID`,
  `RECEIPT UNVERIFIED` (unsealed, forged or edited, sealed under another
  key, or written by a gate copy that never landed: DND-1814),
  `RECEIPT UNVERIFIABLE (COULD NOT LOOK)` (no seal key, or a landed history
  it cannot read), `RECEIPT FOR ANOTHER BASE` (the recorded base is not an
  ancestor of `origin/<base>`), or `RECEIPT BASE UNKNOWN (COULD NOT LOOK)` (an
  object is missing, so ancestry cannot be read). Each reader of the receipt
  (`locked-merge`, gh-athena's merge and push guards, glab-athena's merge
  guard, `main-health`, `ready-and-idle`) reads it through
  `ai/lib/integration-receipt.sh`, so each applies the same seal check. The
  fix is to run `integration-gate` on that head and merge the SHA its
  `INTEGRATION OK` names. The gh-athena merge guard applies the same receipt
  rule to a bare `gh-athena pr merge` (DND-969); it has no tree check.
  glab-athena's merge guard applies it to every `mr merge`/`mr accept` and
  train boarding, declared gate or not (DND-1845); it has no tree check
  either.

  **Later (2026-10-01, DND-1463):** `locked-merge` asserted `origin/<base>`
  was contained in the gated head (exit 3, "re-gate"), required the receipt's
  base to EQUAL it, and compared the landed tree with the gated head's tree.
  Superseded by the owner decision quoted under *Merge one at a time*. What
  is no longer checked: the head combined with the commits between the
  receipt's base and the tip was never gated. The tree check still fires: it
  now compares against the computed merge, which equals the old check when the
  base did not move.
  No flag or env var skips the receipt; an owner-approved HOT merge goes through
  `integration-gate --owner-approval`, which the receipt records. On gen_saas pass
  `--require-idle-workflow post-merge.yml`. The workflow's `prod-deploy`
  concurrency group and deploy guard now close interleaving (gen_saas ADR 15).
  The flag keeps one merge per deploy run, so each run's verdict belongs to one
  PR and no merge makes a running deploy refuse with exit 6. It is keyed on the
  base SHA checked under the lock (DND-1378):
  - the base commit's own run must read `completed`, re-read by id;
  - no run for that SHA is `NOT SEEN YET` or `NO RUN FOR BASE` (exit 5), never
    idle, unless the commit carries a skip marker;
  - the base-branch run list must show nothing live.

  The base run's conclusion is printed. A non-success is a `WARN`, not a
  refusal, so the fix or revert can still merge. But a failed deploy stops the
  line (owner, 2026-10-01): on that `WARN`, merge nothing but the fix or the
  revert until a deploy succeeds. Do not hand-roll a deploy waiter around it;
  retry on exit 5.

  **Later (2026-10-01, DND-1463):** this said "no ratified rule holds merges
  on a failed deploy". Superseded: Cody's landing doctrine stops the line on a
  failed deploy. `locked-merge` still only warns, and you hold the line.

  **Later (2026-09-30, DND-1378):** this said to pass the flag "until that
  workflow has a `concurrency` group (two interleaved deploys: the last one
  wins)", and the flag counted live runs in one base-branch list read. That
  read missed the just-landed commit's run, so #562 merged during #579's
  deploy. Two fleets then hand-rolled SHA-keyed waiters, and both accepted a
  failed deploy as done. Whether the flag is still needed now that the group
  exists is escalated to Cody (dropping it loosens a bar).
- **Across machines:** a local lock cannot span machines, and no merge token
  replaces it. Two machines merging at once is the risk the owner accepted
  (Cody, 2026-10-01: "I'm comfortable with the risk of multiple merges at the
  same time"; "That is true for both custom and gen_saas."). Use
  `locked-merge` on every machine. A merge that lands on another machine's
  merge reads as exit 7 `LANDED UNGATED` (parent or tree mismatch), never as a
  silent pass. If a coordinator still runs a cross-machine protocol for a
  repo, follow it too.

  **Later (2026-10-01):** this said to follow the coordinator's cross-machine
  protocol, "today: the FIFO merge token,
  `ai-artifacts/coordination/<repo>-merge-token.md`", and to "Hold the token
  AND use `locked-merge`". Superseded: the coordinator retired the gen_saas
  token at 05:29:56Z on owner decision 5 ("TOKEN PROTOCOL RETIRED", in that
  file). DND-1463's sweep missed this bullet.
- **GitLab merge trains need none of this.** The train re-tests the integrated
  result and is its own arbiter; board per *Boarding* below.

Losing the race now costs nothing unless the rebase or merge conflicts. A
conflict costs, in `~/dev/custom` (no CI), one local re-gate; in gen_saas
(~50 min CI on one runner), a CI cycle, and it can reorder deploys. The lock
is required in both.

**Later (2026-10-01, DND-1463):** this said losing the race always costs a
re-gate (custom) or a CI cycle (gen_saas). Superseded: a receipt on an
ancestor of the moved main is accepted, so only a conflict costs one.

**Later (2026-09-27):** a PR waiting its turn for the token, the lock or a
coordinator train moves its ticket to `In Merge Queue`
([[athena:ticket-management]] → *A ticket's status follows its captain*).

**Later (2026-09-26):** when you are queued behind another PR, whether for the
merge token or for the lock, **do not merge main forward until you are next.**
Main moves again when the PR ahead of you lands, so a forward made at position
2 or 3 always gets redone. On a single-runner repo it also queues a full CI run
ahead of every deploy. Keep your place on your last green head. Merge forward,
re-gate and re-run CI only when you hold the token, or when you are next and
the holder is merging. The head need not contain current main: a receipt on
an ancestor of it is accepted, so merge forward only when the merge would
conflict (`locked-merge` exit 3 names it). The head you merge still needs a
critic PASS, `INTEGRATION OK` and all-green CI. If the
coordinator's protocol asks for something else (for example a
head that contains main at request time), the protocol wins. Tell the
coordinator what the extra forward costs. Measured 2026-09-26 on gen_saas:
- DND-549 (#365) was merged forward 4 times in about 2h (slack-interactive
  state log, 09:10Z–09:46Z). Main moved about every 40 min and CI took about
  50 min.
- #396 was at position 3 and "will need another forward".
- The DND-437 admiral held #400's rebase until the holder landed, "to avoid a
  wasted CI run on the single runner" (harness-epics-ab state log, 10:43Z).
- Deploy tails of 1h14m and 1h20m (#363, #395) were mostly queue wait behind
  those runs (DND-608).

**Later (2026-10-01, DND-1463):** the paragraph above said the head you merge
"must contain current main", so every queued PR merged forward once it was
next. Superseded: it must contain only the base its receipt records, an
ancestor of current main.

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
- **The POST pins the head** (DND-742): `~/dev/custom/ai/bin/glab-athena api -X
  POST "projects/:id/merge_trains/merge_requests/<iid>" -f sha=<head sha>`.
  `glab-athena` refuses a boarding with no `sha` field, a sha that is not the
  head, a head pipeline that has not passed on that head, or a head with no
  integration-gate receipt (DND-1845). Run it from a checkout of the MR's
  project, where the receipt is. That enforces the first checklist item below;
  the other two stay yours. A refusal carries a
  `Fix:`; follow it, never board with plain `glab`. See [[athena:gitlab]] →
  *Merging*.
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

On a `github.com` remote there is **no merge train or queue**: once
`~/dev/custom/ai/bin/gh-ci-wait --repo <owner>/<repo> --sha <head>` says
`VERDICT: DONE` for the exact head (pin it first: `athena:github` → *Watching CI — Actions checks, not a pipeline*), run
`integration-gate`, then
`scripts/locked-merge --pr <n> --head <sha>` with the SHA its `INTEGRATION OK`
names (*Landing onto a moving main*). `locked-merge` makes the pinned
`gh-athena pr merge <n> --squash --match-head-commit <sha>` call; never make it
yourself. The wrapper is the floor that fires (DND-609): it REFUSES a merge
whose pinned head is not all green, and REFUSES `--auto` wherever it cannot read
a non-empty required-checks set. In a repo that declares a gate it also
REFUSES a merge with no `integration-gate` receipt for the pinned head,
recorded against the base branch's current tip or an ancestor of it
(DND-1463), and refuses `--auto` outright (DND-969). Athena's repos have no branch protection (free private
plan), so `--auto` there would merge immediately; it is refused, and branch
protection is NOT the gate. A refusal is expected, not an auth error: follow its
`Fix:`. The deploy is the repo's own post-merge Actions workflow — no `Auto-Deploy`
label; wait on it with `gh-ci-wait --repo <owner>/<repo> --workflow <name> --sha
<merged-sha>` (one 60 s waiter on the App budget; never a 3 s `gh run watch`,
DND-1706). See [[athena:github]]; GitLab
forge mechanics are in [[athena:gitlab]].

**Later (2026-09-27, DND-969):** this section named the direct
`gh-athena pr merge <n> --squash --match-head-commit <sha>` as the merge
command, with a 2026-09-26 note to run it inside `locked-merge`. Superseded: the
direct call skipped the receipt `locked-merge` requires. The wrapper now reads
the same receipt through the same library (`ai/lib/integration-receipt.sh`), so
the direct call is refused in a gated repo, and the section names
`integration-gate` then `locked-merge` as the one path.

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

*Measured 2026-09-22 (2 of 2 admiral runs, on two work tickets): both ended the
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
The no-CI landing's clean rebase is the reverse case. You push a rebased SHA
the PR never carried, so GitHub reads the PR `CLOSED`, never `MERGED`, and the
forge probe alone exits 1. That push is a fast-forward, not a squash, so the
pushed SHA's ancestry is exact proof. Pass both probes:
`confirm-merged --pr <n> --sha <pushed SHA> --target origin/main --fetch`.
Measured on #92 and #83 (2026-09-27), #181 (2026-09-28), #276 and #282
(2026-10-02); each admiral re-derived it.
Re-verify after any merge-forward, and reconcile on every wake — a dropped
train-monitor notification is not evidence the merge failed.

*Premature "Merged!" set Notion Done and the DM too early on ui-bg, pt1124,
ui-phase1/2/5, aggregate-alignment, mobile-parity, and pt1280.*

An epic-boundary crossing is reported on merge (a milestone, not an owner DM)
— see [[athena:epic-progress-dm]]. Tear the stack down per
[[athena:teardown-worktree-stack]] only after this confirmation. On GitHub,
`locked-merge` already ran `teardown-stack` for the PR (exit 10: landed,
teardown failed). On GitLab, run `ai/bin/teardown-stack --mr <n> --repo
<repo>` as soon as `confirm-merged` exits 0, for every part of a multi-MR
Mission as it lands. Then remove the worktree its `next:` line names, per
that skill's *Removing the WORKTREE*.

Landed is not working. A post-deploy live verify that disagrees with
expectation is a finding: ticket it and route it to the fleet
(`~/.claude/CLAUDE.md` → *Find it, ticket it, fix it, verify it live*).

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
