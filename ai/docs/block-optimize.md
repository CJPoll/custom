# block-optimize (DND-528, C4-2)

**Kind: living normative document.**

`ai/bin/block-optimize` turns ONE labeled admiral failure into ONE
human-reviewable prose diff. It measures the diff with `variant-eval --corpus
full --json` and labels it with exactly what the landed noise rule supports.
It is **propose-only**: it never moves a ref, never pushes, never touches a
forge, and never re-baselines anything.

The design, its numbers and the reasons behind them are on the DND-528 ticket
and the DND-175 umbrella (*Honest signal*). This page is the operator's view.

## Use

```
ai/bin/admiral-eval --run --runs 10 --only AE-18 > /tmp/ae18.txt     # at origin/main
ai/bin/block-optimize --case AE-18 --evidence /tmp/ae18.txt --out-dir /tmp/bo-ae18
```

- `--case`: the failing case. The full fixture name, or a prefix that names one
  fixture (`AE-18` resolves `AE-18-refused-spawn-is-pause`).
- `--evidence`: the saved stdout of an `admiral-eval --run` at origin/main. The
  case's row must be a T2 failure (`0 < n`, `k < n`). The `subject:` sha must
  equal origin/main's rendered admiral. Anything else is refused with `Fix:`:
  case absent, `k == n`, `0/0`, `[hook-stdin]`, no `subject:` line, or STALE.
  A run that reports model invocation failures above 0 (DND-1364), has no
  `admiral-eval: invocation failures: N` line, or whose row has `n` below the
  run's 10 samples is refused too: it is an unmeasured run, not evidence.
- `--diff PATCH`: a human-authored candidate (a raw unified diff) in place of
  the model proposer. It takes the identical checks and measurement.
  `--evidence` is optional with `--diff`.
- `--out-dir`: must be new or empty, so an earlier run's scorecard can never be
  read as this run's.

**Cost.** One proposer call, plus about 500 opus calls (2 sides x 25 T2 cases x
10) and about 65 minutes for the measurement. It is model-bound, not
CPU-bound, so it queues in test-slot's MODEL pool, never a CPU unit (DND-1006):
`~/dev/custom/ai/bin/test-slot --pool model -- timeout <secs> ...`. (test-slot
routes a `block-optimize` command there by name too.) A doomed candidate
spends none of that: every scope and size check runs first.

## What it writes

| File | When | What |
|---|---|---|
| `proposal.md` | always | the label and the scorecard summary (also printed) |
| `proposal.diff` | a candidate reached measurement | the source edit only (`.md.in` / blocks), never the renders |
| `scorecard.json` | variant-eval ran | variant-eval's JSON (schema `variant-eval/proposal@1`) |
| `scorecard.txt` | variant-eval ran | variant-eval's text proposal |
| `rejected-candidate.txt` | rejected before measurement | the raw candidate text (untrusted), for diagnosis |

## Labels

Exactly one, from `BlockOptimize::Label.decide` over the JSON only. The label
never reclassifies a case: every flip is variant-eval's, from
`EvalScore.classify`.

| Label | When | Exit |
|---|---|---|
| `REJECTED: <reason>` | a refused evidence, a scope violation, a patch that does not apply, a failed build/size check, an unchanged admiral render, BLOCKED, UNMEASURED, REVERT (names the regressions), a malformed or wrong-schema JSON, or a JSON for another candidate or base | 1 |
| `PROPOSED — MEASURED IMPROVEMENT` | verdict keep AND the target's flip is `improved` | 0 |
| `PROPOSED — NO MEASURED REGRESSION; IMPROVEMENT UNPROVEN` | every other zero-regression outcome | 0 |

A usage error exits 2 and names the flag.

**UNPROVEN is the usual label, by design.** AE-18's baseline pass-rate is about
0.78, so its headroom (0.22) is below `EvalScore::PILOT_ENVELOPE` (0.3). The
rule can register a gain there only when the baseline sample under-reads: 15.9%
of the time for a perfect fix and 1.6% for a no-op, at N=10. So a PROPOSED
label also prints:

- the target's base and variant Wilson scores;
- its headroom against the envelope, saying plainly when the rule cannot
  confirm a gain at this baseline;
- every *other* improved case, listed separately and never credited to the
  target;
- the DND-225 reference band from origin/main's `ai/eval/noise-band.json`, when
  its subject sha equals the baseline render's, else `n/a (<why>)`. A MEASURED
  IMPROVEMENT whose baseline sample lies below the band prints a luck warning;
- the blast radius: each non-admiral render the build changed, as `UNMEASURED
  (no behavioral corpus)`, or `none`. The allowlisted blocks are shared, and only
  the admiral has a behavioral corpus (DND-529 adds the others).

**The no-regression gate is a tripwire, not a proof.** At N=10 it catches large
drops and usually reads a small one as inconclusive. Human PR review stays the
gate for subtle regressions.

## What it may edit

- **Allowlist:** `ai/agents/athena-admiral.md.in` plus every block that
  origin/main's `ai/blocks/routing.yml` routes to `admiral`, minus
  `ops/safety-checks`. It is read from origin/main, never from the diff.
- **Denylist (wins):** `ai/bin/`, `ai/hooks/`, `ai/eval/`, `ai/lib/`,
  `ai/tools/`, `ai/inbox/`, `ai/blast-radius/`, `ai/blocks/ops/safety-checks.md`,
  `ai/blocks/routing.yml`, `ai/guard-classification.tsv`, every rendered
  `ai/agents/*.md`, and any `registry.json`.
- **Only in-place text edits:** a rename, copy, new or deleted file, mode change,
  binary patch, symlink, absolute path, `..`, or a/ b/ mismatch is refused.
- Scope is checked three times: on the parsed headers, on the actual effect
  after `git apply` (untracked files included), and on the set after
  `build-agents` (allowlist plus renders).

## How it cannot adopt

- **The candidate is unreachable.** Built with `write-tree` + `commit-tree` in a
  detached scratch worktree, which is removed on every path. No ref ever names
  it. The end-to-end suite asserts refs, HEAD, the index and `git worktree list`
  are byte-identical before and after, and that the candidate is on no ref.
- **One exec site, deny by default.** Every command goes through one `capture`,
  which calls `command_allowed?`. It allows only read-only git; `worktree add
  --detach` / `remove --force` of the scratch path; `apply`, `add`, `write-tree`
  and `commit-tree` only with `-C <scratch>`; `build-agents` (`--check` only),
  `check-agent-size` and `variant-eval` (with `--json`) only inside the scratch
  tree; and `claude` only with the exact proposer argv. Everything else,
  including every forge CLI, `--update-baseline` and a direct `admiral-eval`, is
  refused with `MutationAttempt`.
- **The proposer can only return text.** `claude -p --model opus --tools ""
  --strict-mcp-config --mcp-config '{"mcpServers":{}}' --disallowedTools Bash
  Task Write Edit NotebookEdit WebFetch WebSearch`, with cwd an empty tmpdir
  that is re-checked afterwards. Its output is untrusted data: it is parsed,
  scope-checked and applied by origin/main's git, never executed.
- **No sandbox is needed** because the allowlist admits only prose. Every gate
  the measurement runs executes origin/main's code, never model-written code.
  That is the line between C4 and C5.

**To take a proposal**, a human applies `proposal.diff` in their own worktree
(`git apply <out>/proposal.diff`) and opens a normal PR, which runs the critic
and harness-gate.

## Tests

- `ai/lib/test/block-optimize/block_optimize_test.rb`: the domain (QA plan
  S, D, E and L cases).
- `ai/bin/block-optimize --self-test`: the manager with fake adapters (M1-M6)
  and the containment (C1-C3). Declared in harness-gate.
- `ai/lib/test/block-optimize/integration_test.sh`: end to end on a throwaway
  git repo with stub tools (I1, I2, the proposer path, scope, size, stale,
  malformed). Discovered by harness-gate through its `self-test.sh`.
