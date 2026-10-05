# Approval friction: hold what weakens a bar

**Kind: dated record (proposal, 2026-10-05).** Later corrections are appended
as `**Later (date):**` paragraphs, per `~/dev/custom/CLAUDE.md` →
*Documentation conventions*. Nothing here changes what holds. Narrowing a
hold is item 5 and changing what clears one is item 6 (`~/.claude/CLAUDE.md` →
*Owner approval policy* → *What stays with Cody*), so each such step lands
only on Cody's own words. The steps that add a report and change no hold can
start now (*Build order*).

Ticket: DND-2036. Related: DND-1984 (click carry), DND-2037 (a Slack message
from Cody is approval), DND-1832 (*The carry*), DND-998 (terraform plan
verifier).

## The ask

Cody, Slack, 2026-10-05 ~04:35Z:

> OK, how do we reduce the friction here? The goal of these safety checks is
> to prevent LLM non-determinism from just deleting important tests ("Hey
> look! They pass now!") or other poor behavior. But this level of tedium is
> slowing down the work, and not increasing safety in the process. Have a
> shipwright figure out a better way to manage these kinds of things.

So the hold should fire on the act Cody named: a change that makes the bar
easier to pass. It should not fire on the files a change happens to touch.

## What holds today, and what it costs

`integration-gate` exit 4 comes from `ai/bin/blast-radius`. For harness
files, the class is `owner-approval-policy` in `ai/blast-radius/surfaces.json`:
48 path patterns, held `always`. It covers the approval verifiers and also
every guard that enforces the merge and push bar: merge-role, forge-identity,
forge-auth, the agent-bin wrappers, gh-athena, glab-athena, the merge guards,
main-health, critic-review, harness-gate and their libraries. A second entry
holds two markdown sections by content (*Owner approval policy*, *Owner
approval grants*).

Measured, from the friction review (artifact XD2nLhXhYHNH5Pxe4t6xoc, item 2,
2026-09-30..10-04) and the 2026-10-03/04 state logs:

- About 51 tickets held at exit 4 for a click since 2026-09-30.
- On 2026-10-03, owner clicks were 19,180 s of 24,076 s of queue time
  (`ai-artifacts/lead-time/journal.md`). DND-1907 waited 7.2 h.
- 7 of 7 approvals on 2026-10-04/05 went stale after unrelated landings. The
  carry compares `git diff --binary <merge-base> <head>` byte for byte, so a
  rebase that only moves hunk offsets refuses as `diff_changed` (#367,
  5e6dea6a → 25dc253c, same patch-id; DND-1984).
- A message with several approve buttons loses all but the last click. Check 5
  in `ai/lib/owner_click.rb` treats any later owner click on the same message
  with a different value as a reversal, even when it names another PR.
- Fail-closed fixes to guards wait on clicks, because the guards are on the
  held list: DND-1908, 1911, 1934, 1938, 1941, 1943, 2000, 1982 (#383 says
  "owner-held" in its title).

What the hold caught: in the 13 held PRs read for this design (#121, 362,
363, 367, 371, 372, 374, 375, 376, 378, 382, 383, 388), one change set out to
make a bar easier to pass: #121, DND-1095, the git-stash-guard thinning (held
as item 5, correctly). The rest added refusals, added tests, or fixed false
denies. The hold had no way to tell them apart, because a path cannot.

## The design in brief

Three changes, each measurable on its own:

1. **Hold the weakening, by content.** A deterministic detector,
   `ai/bin/bar-diff`, reads base and head from git objects. It reports each
   place where the change makes a bar easier to pass: a test case removed,
   skipped or no longer run; an assertion weakened; an allowlist widened; a
   numeric or boolean bar moved the loose way; a check dropped from a gate;
   approval-rule text changed. Each finding is held, and each has a `Fix:` the
   author can apply alone, which is to restore the bar. An agent clears such a
   hold by undoing the weakening. Cody is asked only when the weakening is the
   point of the change.
2. **Hold by path only what decides the hold or the merge.** Code can weaken a
   guard with every test and every `Fix:` intact (`[ -n "$X" ] && exit 0`, a
   branch no test sets). No content rule sees that, so the files that decide
   whether a merge or push is accepted, as whom, and on whose approval stay
   held by path (*H8*). Every other harness path and every product path
   leaves the path hold and is judged by content alone.
3. **Make the remaining clicks cheap.** Most of the measured click cost is
   repetition, not judgement: stale approvals after unrelated landings, one
   click per PR, one click per stack layer. Carry by patch-id, then by
   findings; one batch click for several PR@head pairs; one click per stack.

Every change with no finding and no H8 path lands on the existing merge bar
(`athena:merge-boarding` → *The merge bar*: critic PASS on the head, gate
green) and gets a digest line.

What this does not do: it does not make a guard false-positive fix click-free
when the guard is on the merge or push chain. Those still need Cody, in a
batch. Releasing them safely needs the behaviour hold in *Options
considered*, which is follow-up work.

## The holds

Each hold is a content rule over base and head. "Removed" means present at
base and absent at head, judged per case or per entry, never per line.

### H1. A test case removed or changed out from under its name

A test case is identified by its file and name: an ExUnit `test "…"` inside
its `describe`, a minitest `def test_…`, an RSpec `it "…"`, a Jest `test(…)`, a
Dart `test('…')`, a shell self-test assertion line's label, or an inline Ruby
`check.call("label", …)` (8 `ai/bin` tools carry inline suites this way).
Shell suites name their assertion verbs in the manifest (*The manifest*),
because they differ per suite (`expect_refused`, `am_refused`, `receipt_ran`,
`ok`, `refused`). Every file that answers `--self-test` is test-bearing.

A case at base is **kept** when one of these holds:

- head has a case with the same name, the same input and the same or a
  stricter verdict;
- head has a case, under any name or file in the diff, with a byte-identical
  body (a rename or move);
- head has a case whose input is identical and whose verdict is the same or
  stricter. For guard suites, *refused* is stricter than *ran*.

A case is **retired with its subject** when the module, tool or file it tests
is gone at head. That is reported, not held. Every other removed case is a
finding, and so is a same-name case whose input changed (the base input is no
longer tested).

`Fix:` restore the case. If it no longer passes, the change loosened the
behaviour it tested, and that needs Cody.

Measured by hand on #376 (DND-1941, 18a7d54e), the `glab-athena-merge-guard`
suite: base had 34 `M`-labelled cases, and head kept 31 of those labels. Most
kept labels also gained `--auto-merge=false` in their input. Under the
same-input rule each is a finding unless its base input survives in some case
at the same or a stricter verdict. That is the rule working (the base input
is no longer tested), and it is the likeliest false-hold source for a
tightening, so R3 counts it. Of the
three labels removed: M4b (`--auto-merge`, refused) and M14b (`--auto-merge`,
ran) have identical inputs in AM2 at head, refused: kept, the second one
stricter. M4c (`--when-pipeline-succeeds`, refused) has no identical input at
head (AM6 adds `--auto-merge=false`): a finding. The change was a tightening,
and M4c still passes at head, so its fix costs one restored line. Today the
same PR was held for a click by path.

### H2. A test skipped, excluded or no longer run

- ExUnit `@tag :skip`, `@moduletag :skip`, `@describetag :skip`; any added
  tag that base config excludes (`ExUnit.start(exclude: …)`); a new `exclude:`
  in `test_helper.exs`; `--exclude` added to a test command;
- `skip`, `xit`, `xdescribe`, `it.skip`, `test.skip`, `pending`, `@Skip`,
  `skip:` in Dart;
- test-selection config narrowed: `test_paths`, `testPathIgnorePatterns`,
  `testMatch`, `.rspec` exclude patterns;
- a retry wrapper or `--retry`/`--repeat-until-pass` on a test command
  (`athena:flaky-ticket` forbids it);
- CI: `allow_failure: true`, `continue-on-error: true`, `|| true` or `; true`
  after a test or check command in a CI step or a gate-list entry (not inside
  a test body, where `out=$(cmd) || true` is routine), `if: false`, a removed
  job or step that ran tests or checks, a `paths:` filter or removed
  `pull_request` trigger on a test workflow;
- a check removed from a gate list: `harness-gate`'s `CHECKS` or
  `STATIC_CHECKS`, a repo's `bin/checks`, a `mix` alias that ran a check;
- a test or check file that loses its executable bit.

**The run-count ratchet.** Text cannot see a case that exists but never runs
(an early `exit 0`, `if false`, a conditional skip). So the gate's receipt
records the count of cases each suite ran, and a count below the landed count
is a finding, unless H1 reports the difference as removals or retirements.
This is H5's ratchet applied to a measured number.

`Fix:` remove the skip and fix the test, or file the flake per
`athena:flaky-ticket`.

### H3. An assertion weakened

Within a kept case (H1), compare its assertions at base and head, after
expanding assertion helpers the manifest declares:

- fewer assertion statements than at base;
- an exact form replaced by a looser one: `assert a == b` by `assert a`, `=~`,
  or a match with `_` where base had a value; `refute` removed; `assert_raise`
  removed; `expect(x).to eq` by `be_truthy`;
- a trivial assertion added in place of a real one (`assert true`,
  `expect(true)`);
- a tolerance loosened: an `assert_receive` timeout or `assert_in_delta`
  delta raised, or a `refute_receive` window lowered;
- a verdict flipped the loose way: a guard case from *refused*/*deny* to
  *ran*/*allow*, or an asserted exit code from a failure code to 0. The
  manifest declares which assertions carry a verdict or an exit code.

Another expected value of the same form (`== 2` to `== 3`) is a behaviour
change, not a weakening. It is reported to the critic, not held.

`Fix:` restore the assertion. If the behaviour really changed, assert the new
behaviour at the same strength.

### H4. An allowlist widened, a denylist narrowed

The manifest declares each list and its polarity:

- **allow lists**, where an added entry loosens: suppression files
  (`.dialyzer_ignore.exs`, `.sobelow-skips`, `.gitleaksignore`,
  `.semgrepignore`, `.trivyignore`, `.rubocop_todo.yml`, `.eslintignore`;
  these are today's `quality-bar` class), `.credo.exs` disabled checks,
  `check-bin-help`'s `EXEMPT`, `ai/guard-classification.tsv` rows other than
  `guard` (that table already ratchets reclassification against its landed
  copy, DND-510), `surfaces.json`'s `enforcers.excluded`, `hooks/registry.json`'s
  `retired` list;
- **deny lists**, where a removed or narrowed entry loosens: `surfaces.json`
  patterns, the detector's own manifest entries, a guard's refused-word
  tables, `hooks/registry.json` rows (a changed matcher counts as narrowed),
  `ai/config/main-content-checks.json`.

An added row for a file that is new in the same diff is not a widening: every
new tool adds a classification row. Reclassifying an existing file is.

Also held: an inline suppression added anywhere (`# credo:disable`,
`# nosemgrep`, `# rubocop:disable`, `@dialyzer {:nowarn_function`,
`eslint-disable`, `# noqa`, `# gitleaks:allow`).

Adding to a deny list or removing from an allow list is a tightening and is
never held.

### H5. A numeric or boolean bar moved the loose way

The manifest declares each bar, its file and key, and which direction
loosens: `check-agent-size` budgets, coverage minimums
(`test_coverage: [summary: [threshold: N]]`, `.coveralls.json`), a mutation
score, a critic recall/precision floor, `warnings_as_errors`, credo `strict`,
dialyzer flags, a lint rule's severity. The value is compared with the
landed value: the strictest of the merge-base and `origin/main` (the lowest
budget, the highest minimum), as `check-agent-size` does
(`~/dev/custom/CLAUDE.md` → *A check's own bar must not live in the diff it is
checking*). A bar that cannot be read on either side is a finding (fails
closed).

### H6. Approval-rule text

Unchanged from today: the `markdown-section-v1` evaluator holds the *Owner
approval policy* section of `ai/CLAUDE.md` and *Owner approval grants* of
`ai/contracts/athena-events.md` when their text differs.

### H7. A refusal removed from a guard

For each file `ai/bin/check-guard-messages` treats as a guard (a `guard` row in
`ai/guard-classification.tsv`, or a file under `ai/hooks/` or `ai/bin/` with
no row), compare the `Fix:` string literals at base and head. A literal that
is gone at head, and does not appear verbatim elsewhere at head, is a finding.
Counting literals, not lines, keeps a refactor that moves several `Fix:` lines
into one helper from reading as a loss. H7 is a tripwire for a refusal with no
test. It is easy to defeat on purpose, which is why H8 keeps the files where
that matters most.

### H8. The path set: what decides the hold or the merge

These stay held by path. Each one decides whether a merge or push is
accepted, as whom, on whose approval, or what the bar is. A weakened copy of
any of them skips every other hold, `bar-diff`'s included.

- **The hold itself:** `ai/bin/blast-radius`, `ai/blast-radius/**`,
  `ai/bin/bar-diff` and `ai/bar/**` (manifest and adapters), `ai/lib/landed.rb`
  (it resolves the landed bar every ratchet reads).
- **The approval verifiers:** `ai/lib/owner_click.rb`, `ai/lib/owner_turn.rb`,
  the owner-approvals `action_class` files, `ai/lib/private_overlay_resolver.rb`
  and `ai/lib/private_overlay.rb` (they resolve the owner's Slack id the click
  verifier compares).
- **The receipt chain:** `integration-gate` and its shim,
  `ai/lib/integration-receipt.sh`, `ai/lib/receipt_seal.rb`,
  `ai/bin/receipt-seal`.
- **The merge and push chain:** `gh-merge-guard.sh`, `glab-merge-guard.sh`,
  `ai/config/main-content-checks.json`, `forge-git-passthrough.sh`, the
  forge-transport files, `forge-http-pin.sh`, `gh-athena`, `glab-athena`,
  `forge-api-scan.sh`, `forge-cli-isolation.sh`, `locked-merge`,
  `main-health` and `main-health.sh`, the merge-role hook and libraries, the
  forge-identity and forge-auth hooks, `ai/agent-bin/*`, `agent-forge-push.sh`,
  `agent-forge-cli.sh`, `forge-write-class.awk`, `ai/agent-env/session-env.sh`.
- **The judges:** `ai/bin/critic-review`, `ai/lib/critic_carry.rb`,
  `ai/lib/critic_verdict_stores.rb`, `ai/bin/harness-gate`,
  `ai/lib/first_party.rb`, `ai/lib/harness_tools.rb`, `ai/lib/reap_tags.rb`,
  `ai/lib/scratch_home_sentinel.rb`.
- **New holds** this design adds, because it makes the critic load-bearing:
  `ai/lib/critic_prompt.rb` (pinned COLD today by DND-1807,
  `ai/bin/blast-radius` self-test) and `ai/agents/athena-diff-critic.md.in`
  with its rendered `.md`.

So the path list loses nothing it holds today, and the enforcer walk in
`blast-radius --self-test` (every merge or push enforcer candidate is held or
in `enforcers.excluded`) is unchanged. `surfaces.json` and the bar manifest
are also read with the H4 polarity rule, but stay path-held.

What leaves the path hold is everything outside this set: today that is
nothing in custom (the 48 patterns are all here), and in a product repo it is
the absence of any test protection at all. So in custom the gain is the cheap
clicks (*Approvals*), and in product repos the gain is new cover: H1–H5 hold
a test deletion there, which nothing holds today.

Follow-up, not this design: releasing a merge or push chain file from the
path hold needs a behaviour hold that sees the bypass branch (*Options
considered*). Until it exists, a guard false-positive fix on the chain still
needs Cody, in a batch.

## The manifest

`ai/bar/manifest.json` declares what H1–H5 read: test file globs and their
adapter, shell assertion verbs and which are deny-class, assertion helpers to
expand, verdict and exit-code assertions, fixture paths (reported to the
critic, not held), allow and deny lists with polarity, numeric and boolean bars
with file, key and direction, gate lists, skip tokens and suppression tokens.
Product repos are covered by generic entries, as `surfaces.json` covers them,
with nothing committed into them.

- It is in H8.
- A test file no adapter covers, or a shell assertion verb not declared, is a
  finding when it loses lines: fail closed, and the `Fix:` names the manifest
  entry to add.

## Approvals: carry, batch, stacks

These change what clears an exit 4, so all are item 6. They build on DND-2037
(a Slack message from Cody is approval), which edits `ai/lib/owner_click.rb`,
and are sequenced after it lands.

### Carry by patch-id (DND-1984)

Compare `git patch-id --verbatim` of the PR's own `git diff --binary
<merge-base> <head>` at A and B, and also the `git diff --raw` mode columns,
which patch-id does not read. Patch-id ignores line numbers and keeps
whitespace and context, so #367's offset-only rebase carries, and a change
next to a hunk, a binary change or a mode change does not.

DND-1832's record gives the reason for the carry as "a rebase or a merge of
main needed a new click though the PR's own change had not moved", and an
offset-only move is that case. But the approved words are "byte-identical"
and "Any byte difference still needs a new click", so the change is item 6,
on Cody's word. Its file is H8, so its landing needs a click too.

### Carry by findings

Later, with the detector in place, a click for head A of PR X carries to head
B when all of these hold:

- every finding at B, by fingerprint, is in the set at A. A fingerprint is
  (hold, file, case or entry name, old value, new value). For an H8 path it
  is (path, patch-id of that path's own diff, mode);
- the cases B adds in the files with findings are a superset of A's, so a
  compensating test Cody relied on cannot vanish after the click;
- every other condition of *The carry* holds (origin's PR head ref is B, no
  later hold names X, B's diff is not empty).

A new or changed weakening needs a new click, and the refusal names it.

### Batch approval

One owner act approves several named PR@head pairs.

- The value is `approve-exit4 <slug>#<pr>@<sha>;<slug>#<pr>@<sha>;…`. Slack
  allows 2,000 characters in a value, about 25 pairs.
- The visible text must match the value. Check 4 binds the value only, so
  the gate also verifies that each pair appears verbatim in the posted
  message's text, read from the inbox line of the post, and refuses
  otherwise. Each pair is listed with its findings.
- The gate clears this PR only if its own `slug#pr@head` is in the list, or
  carries from an entry in it.
- Under DND-2037, a reply in the DM's thread is the same act only in a strict
  grammar: `approve all` or `approve <pr> <pr> …`. Anything else refuses.
- Check 5 changes with it: a later owner click on the same message supersedes
  an approval only if its value contains the same PR, or names no PR. Today
  any later click with another value does, which voids every button but the
  last.

### Stacks

A stack is approved as one batch: the admiral posts one DM listing each PR in
the stack at its head, with its own findings. Approving the tip's cumulative
diff alone is not enough: a lower PR could remove a test that a higher one
restores, and the lower PR lands alone. After a restack, each entry carries.

## Measurement: each hold must be able to fire

A hold that cannot fire on a real weakening is no hold
(`~/dev/custom/CLAUDE.md` → *A claimed mechanism must be able to fire*). The
replay is `bar-diff --replay`: git reads only, one process, run under
`nice -n 19 ionice -c 3`, and only while the owner is not at the machine
(DND-1222). It is functional: each case has a fixed expected verdict.

| # | What | Corpus | Pass |
|---|---|---|---|
| R1 | Recall on synthetic weakenings | For each of the last 30 merged PRs per repo (custom, gen_saas, walt_ui) that touched a test: one mutant per rule, applied on its head (remove a case, change a case's input, add a skip, add an excluded tag, drop an assertion, flip deny→allow, flip an exit code to 0, add an allowlist row, raise a declared bar, drop a `CHECKS` entry, remove a `Fix:` literal, clear an exec bit) | every mutant HOLDs, with the rule named |
| R2 | Recall on real weakenings | #121 (DND-1095 thinning); the `check-agent-size` 500→508 raise of 2026-09-20; every commit in the three repos' history that adds `@tag :skip`, `allow_failure` or `continue-on-error`, or deletes a test file | each HOLDs, or is listed as a miss with why |
| R3 | False holds on the held PRs | the PRs the state logs list at exit 4 since 2026-09-30 (custom #121–#398; gen_saas #483–#751) | per PR: today's hold, the detector's findings, each finding hand-labelled real or false, and whether its `Fix:` clears it without Cody |
| R4 | Test deletions | every case removal in the three repos in the last 90 days | count held, retired with subject, kept; label each |
| R5 | Carry | the 7 stale approvals of 2026-10-04/05; then each with a synthetic weakening, a mode change and a dropped compensating case added after the click | patch-id and findings carry the 7; none carries a mutant |
| R6 | Run-count ratchet | the last 30 gate receipts in custom; one mutant suite with an early `exit 0` | counts stable across the 30; the mutant HOLDs |

Adoption bar, for Cody to decide on: R1, R5 and R6 at 100%; R2 at 100% with
any miss named and its adapter fixed; R3 and R4 false holds counted and
listed. The numbers go in a `**Later:**` section here.

Hand-measured while writing (not the replay): #376's suite, under H1.

## Residuals

Said out loud, so the digest and the critic are known to be the cover:

- **A bypass branch in a file outside H8.** A tool or library not on the
  merge or push chain can gain `[ -n "$X" ] && exit 0` with every test and
  `Fix:` intact. The critic's `guardrail` rubric is the cover, and the digest
  line names the file.
- **A test made vacuous without touching it.** A fixture or stub changed so a
  deny case is refused for another reason. The shell suites' reason substring
  catches some of it. Changed fixture paths are reported to the critic.
- **An undeclared allowlist or bar is invisible.** The critic rubric gains an
  item: a new allowlist or threshold not in the manifest.
- **A new hold in product repos.** A test deletion in gen_saas or walt_ui is
  not held today. R3 and R4 measure its cost before it turns on.
- **Carry by findings trusts the detector.** A miss at B is a miss the click
  never saw. Byte carry and patch-id carry have no such dependence, which is
  why T3 comes first and stands alone.
- **The visible-text check reads the post's inbox line.** A local process
  that can write the inbox can forge it, the residual clicks already carry.

## Build order

Each step names its inputs and the step that creates them.

| Ticket | What | Needs | Cody? |
|---|---|---|---|
| T1 | `ai/bin/bar-diff`, `ai/bar/manifest.json`, adapters (ExUnit, minitest, RSpec, Jest, Dart, shell, inline Ruby `check.call`), report-only. `integration-gate` prints the findings; exit codes unchanged. Mutation fixtures as its self-test | nothing | no: adds a report, moves no hold |
| T2 | The run-count record in the gate receipt, report-only | nothing | no |
| T3 | DND-1984: carry by patch-id plus modes | nothing | yes: item 6 (the approved carry says byte-identical) |
| T4 | `bar-diff --replay` and R1–R6; results appended here | T1, T2 | no |
| T5 | blast-radius holds `bar-weakening` findings (all repos); `critic_prompt.rb` and the critic definition join H8 (the DND-1807 COLD pin and the enforcer walk updated with them); critic prompt input `bar-report`; digest line | T4 meets the adoption bar | yes: items 5 and 6 (a new hold in product repos changes what holds) |
| T6 | Batch approval, visible-text check, reply grammar, check 5 per PR, stack batches | DND-2037 landed | yes: item 6 |
| T7 | Carry by findings | T5, T6 | yes: item 6 |

T1, T2 and T4 change nothing that holds, so they can start now. T3 and T6 are
where most of the measured click cost goes, and they need Cody's words.

## Options considered

- **Shrink the path list to the approval verifiers.** The first draft of this
  design released the merge and push chain to content holds. A read-only
  architect review found the bypass branch: a guard weakened with every test
  and `Fix:` intact. Rejected: the chain decides whether exit 4 is consulted
  at all.
- **Let the critic decide alone.** The critic has a `guardrail` rubric. It is
  a model, and model non-determinism is what Cody wants a check against. Kept
  as the second layer.
- **Owner approval grants per class** (`ai/contracts/athena-events.md` →
  *Owner approval grants*), for example "guard false-positive fix". It still
  needs a classifier to say which PRs are FP fixes, and the grant would cover
  a fix that also deletes a test. Rejected in favour of holding the deletion.
- **A behaviour hold for guards.** Run each guard over a command corpus at
  base and head and hold any command newly allowed, with the corpus including
  the environment variables the guard reads. This is what can release chain
  files from the path hold, because it sees a bypass branch that a corpus
  entry reaches. It needs a corpus per guard (git-stash-guard and merge-role
  have one in their self-tests), so it is follow-up work.
