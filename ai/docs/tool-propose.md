# tool-propose (DND-176, C5)

**Kind: living normative document.** Amended in place, per
`~/dev/custom/CLAUDE.md` → *Documentation conventions*.

`ai/bin/tool-propose` turns a written-down gap into ONE measured,
human-reviewable proposal for a NEW `ai/bin` tool. The gap is a set of
committed harness-eval `bin-stdin` target cases. It recommends the tool only
when the deterministic eval shows it fixes every target, nothing regressed, the
gate is green, and each target passes again in isolation. It is
**propose-only**: it never creates a ref, never commits on a host repo, never
opens a PR, and never adopts anything. A human adopts.

The design and its reasons are on the DND-176 ticket's three sub-pages and the
epic *Harness — sandboxed tool creation*. This page is the operator's view.

## Use

```
ai/bin/tool-propose --case 20 --case 21 --out-dir /tmp/tp-zap
ai/bin/tool-propose --case 20 --case 21 --out-dir /tmp/tp-zap --candidate ./my-tool
```

- `--case PREFIX`, repeated: each names one fixture under `ai/eval/fixtures`
  **at origin/main's sha** (the full name, or a prefix naming exactly one). It is
  read with `git ls-tree` and `git cat-file`, never from the working tree.
  Together the targets must be `mode=bin-stdin`, name one `guard=`, and hold at
  least one `expect=fires` and one `expect=clean` case. The pair defeats a
  no-op tool (it cannot fire) and an always-deny tool (it cannot stay clean).
- The targets land on origin/main **first**, as a normal PR, and they fail
  there: the tool is absent at that sha, so each scores `error`. A committed
  failing target does not turn main red, because harness-eval with
  `baseline.json` present fails only on a regression. The candidate never adds
  or edits a fixture, so it can never author the test it is scored against.
- `ai/bin/<guard>` must not exist at the sha: new tools only. tool-propose
  never replaces a tool.
- `--candidate FILE`: a human-written tool, read as data, in place of the model
  proposer. It takes the identical checks and measurement.
- `--out-dir DIR`: absolute, new or empty, beneath the temp root or
  `$XDG_STATE_HOME/athena/tool-propose/`; in no git work tree; not under
  `~/.claude` or `~/dev`. An existing one must be yours with no group or world
  write bit, so no other user can plant a symlink in it. A new one is created
  0700. It is checked before anything else runs.
- `--timeout SECS`: the sandboxed measurement's wall limit (default 3600, max 7200).

## The candidate

Without `--candidate`, tool-propose makes **one** text-only proposer call, with
block-optimize's fixed argv (`claude -p --model opus --tools ""
--strict-mcp-config` with an empty MCP config, and every tool disallowed). Its
cwd is a fresh empty directory, re-checked empty afterwards. The prompt gives
the tool name, the contract and every target's `regression=`, `expect=`, `args=`
and input bytes. The reply must hold exactly one fenced code block. There is no
retry.

The contract the candidate is held to:

- stdin in; exit 0 clean; exit 1 with a `Fix:` line to flag; anything else is
  an error;
- `--help` on stdout, exit 0, no side effect; an inline `--self-test`;
- stdlib only, no `require` of a repository file, no network, no writes outside
  `$TMPDIR`.

The shape review is mechanical and runs before anything else does: exactly one
fenced block; a first line of `#!/usr/bin/env bash`, `#!/bin/bash`,
`#!/usr/bin/env ruby` or `#!/usr/bin/ruby`; at most 40 KiB; valid UTF-8; no
NUL; the literal tokens `--help`, `--self-test` and `Fix:`.

The candidate commit holds exactly four paths, all written by tool-propose but
the tool body:

| Path | What |
|---|---|
| `ai/bin/<guard>` (100755) | the candidate, with `# athena-tool-propose: candidate run <id>; human adoption only (ai/docs/tool-propose.md)` as line 2 |
| `ai/test/tool-propose/<guard>/self-test.sh` (100755) | a fixed template that runs `ai/bin/<guard> --self-test` |
| `ai/tools/risk.yml` | one added entry, `<guard>: { class: destructive, reason: generated }` (deny by default) |
| `ai/bin/harness-gate` | one added `INLINE_SELF_TEST_COVERED_BY` line mapping the tool to that suite, which harness-gate's inline `--self-test` coverage requires |

A built commit that changes any other path, or any path under `ai/eval/`, is
`REJECTED: candidate` before it is measured.

## The measurement

1. `tool-sandbox --prepare-clone` builds clone A at origin/main's sha.
2. The candidate commit is built in A with plumbing on a temp index
   (`read-tree`, `hash-object -w`, `update-index --cacheinfo`, `write-tree`,
   `commit-tree`). No ref names it and A's HEAD and working tree do not move.
   `proposal.diff` is read from A at this step.
3. A is marked used. From here no host process runs in or on A: sandboxed code
   could plant a hook or `core.fsmonitor` there for host git to run.
4. Under a `test-slot` cpu slot, tool-sandbox runs origin/main's
   `ai/bin/variant-eval --variant <cand> --baseline <sha> --corpus
   deterministic` over A. `/out` is read as untrusted data: a regular file we
   own, never a symlink (`O_NOFOLLOW`), at most 1 MiB.
5. BLOCKED: the baseline gate runs on a **fresh** clone B, never on A.
6. KEEP with every target fixed: each target runs again, alone, in its own
   fresh sandbox holding only the candidate, with its input fed on stdin
   (`tool-sandbox --stdin`). The host classifies the exit by harness-eval's
   bin-stdin rule.
7. The scratch tree is removed on every path, including an exception, SIGINT
   and SIGTERM. Removal never follows a symlink. A tree still present after
   removal is named: an exit-3 fault when nothing else failed, a warning when
   something did.

## What it writes

| File | When | What |
|---|---|---|
| `proposal.md` | always, last | the label, the targets and their isolated verdicts, the adoption sentence when RECOMMENDED |
| `proposal.diff` | the commit was built | `git diff --binary <sha> <cand>`; `git apply`-able in a human's worktree |
| `candidate/` | the commit was built | the four files as built, as data (mode 0644) |
| `scorecard.json`, `scorecard.txt` | variant-eval wrote them | variant-eval's JSON and text, copied only when readable as *The measurement* step 4 says |
| `rejected-candidate.txt` | a candidate was rejected | the raw candidate text (untrusted) |

Every file is written atomically. The label is printed only after
`proposal.md` is written.

## Labels

Exactly one, from `ToolPropose::Label.decide`.

| Label | When | Exit |
|---|---|---|
| `REJECTED: target: …` | a target is missing at origin/main, ambiguous, not bin-stdin, names two tools, lacks a fires or a clean case, or names a tool that exists | 1 |
| `REJECTED: candidate: …` | the proposer failed or left a file, the reply or shape is wrong, or the commit touches an unexpected path | 1 |
| `NOT RECOMMENDED: UNMEASURED (<why>)` | the sandbox exited 124, 125, 128+N or anything but 0/1; the JSON is absent, unreadable, the wrong schema or corpus, or for another candidate or base; verdict `unmeasured`; `regressions` is not a list; BLOCKED with the baseline gate red too | 1 |
| `NOT RECOMMENDED: gate red (<checks>)` | verdict `blocked` and the baseline gate is green | 1 |
| `NOT RECOMMENDED: regression (<cases>)` | verdict `revert`, or any regression listed | 1 |
| `NOT RECOMMENDED: target not fixed (<cases>)` | a target is under `new`, not under `fixed`, or fails its isolated re-check | 1 |
| `RECOMMENDED — MEASURED IMPROVEMENT; human adoption required` | verdict `keep`, `regressions == []`, every target under `fixed` and none under `new`, and every isolated re-check equal to its `expect` | 0 |

Every label but RECOMMENDED is followed by a `Fix:` line, on stdout and in
`proposal.md`.

A usage error, including a refused `--out-dir`, exits 2 and names the flag. An
infrastructure fault (a failed clone, a failed out-dir write, a refused exec)
exits 3 with `Fix:` and never prints a RECOMMENDED line. No exit code alone
leads to RECOMMENDED: a forged 0 with no JSON is UNMEASURED.

## How it cannot adopt

Every process goes through one guarded primitive, `ToolPropose::Exec.capture`,
which refuses anything `command_allowed?` does not list: host git read verbs
only; plumbing on an unused scratch clone only; `tool-sandbox` with exactly the
three sandboxed runs; `test-slot` around one of them; and `claude` only with the
proposer argv. Push, merge, commit, ref moves, fetch, every forge CLI, a shell,
`curl` and `--update-baseline` are refused. `--self-test` asserts each refusal
and lexes its sources to assert that no other known spawn primitive
(`system`, `spawn`, `exec`, the other `Open3` calls, backticks) appears. A
spawn form outside that list, such as `IO.read("|cmd")`, is not caught by the
lex; review covers it. Every git it runs gets the caller's `GIT_*` variables
unset, so an inherited `GIT_DIR` cannot point it at another repository, and
each child stream is kept to its first and last 512 KiB on the host.

The adoption gate, per state (the epic's Architecture & Engineering page, *The
adoption gate*):

| State | Where the generated code is | What stops it reaching the live harness | Fires? |
|---|---|---|---|
| S1 proposer output | a string in memory | no tools, no MCP, an empty cwd re-checked after; parsed, never executed outside the sandbox | yes: the argv is fixed and asserted |
| S2 built candidate | a commit in a throwaway clone under the temp root | no host ref names it; the clone shares no objects with the host; the exec allowlist refuses push, merge and forge CLIs | yes: the integration suite asserts the host repo's refs, HEAD, index, worktrees and stash list are identical |
| S3 executing | inside tool-sandbox | the live harness paths are not bound; no network, no token, no docker socket | yes: `tool-sandbox --self-test` escape probes, every gate |
| S4 recorded recommendation | files in the out-dir | the out-dir is under the temp root or the state dir, in no git tree, not under `~/.claude` or `~/dev`; nothing is committed, pushed or PR'd | yes for the loop: there is no code path past writing the out-dir |
| S5 adoption | a human's worktree and PR | a human applies `proposal.diff` and opens a PR, which takes critic + harness-gate | **instruction, not mechanism** |

**Residual.** S5 is instruction. An agent that applies `proposal.diff` against
the instruction produces an ordinary agent-authored PR, which an admiral may
merge on the normal bar. The provenance line makes the origin visible to the
critic and a reviewer, but a diff can remove it, so it is a signal, not a gate.
A mechanical merge hold changes the approval rules, which is Cody's
(`~/.claude/CLAUDE.md` → *Owner approval policy*, item 6); it is open question
Q1 on the epic, and no hold exists.

**Residual.** The candidate runs inside the measurement, so the gate and
regression results can be forged by a deceptive candidate. The target fixes
cannot: each is re-checked with the candidate alone in a fresh sandbox,
classified by the host. The backstop for the rest is the human's review of
`proposal.diff`, then the adopting PR's host harness-gate and critic.
`proposal.md` says so under a RECOMMENDED label.

**Also stated.** Once a human adopts a tool, the host gate runs it unsandboxed
(`check-bin-help` runs `--help`; harness-eval runs its bin-stdin cases). That is
what adoption means, and why the human step matters.

## Adoption

A RECOMMENDED proposal prints this sentence and no command:

> A human adopts: apply proposal.diff in your own worktree, reclassify the
> tool's risk.yml entry if it is not destructive, and open a PR (critic +
> harness-gate). Agents never apply a tool-propose proposal.

## Cost

With `--candidate`, no model call; without it, one. One sandboxed gate run (the
variant's, inside variant-eval), two when BLOCKED (the baseline's), plus one
short sandbox per target for the isolated re-check. The gate is CPU work, so the
measurement holds a test-slot cpu slot. A rejected target or candidate spends
none of it: every target and shape check runs first.

## Cut

Dynamic routing (routing a tool into live use is adoption); autonomous gap
detection (the target is committed eval cases); a model-in-loop eval tier (the
deterministic eval has zero variance); opening a PR (in this repo a green PR is
one admiral merge from live); a critic run inside the loop (the adopting PR
runs it); more than one attempt.
