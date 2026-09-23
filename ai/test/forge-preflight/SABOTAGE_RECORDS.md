# Sabotage records — forge-identity preflight (DND-206)

A test is not finished until you have watched it fail: delete the thing it
exists to prove, run it, confirm the failure names the right criterion, and
write the failure string down next to the claim it supports. Root ADR 002 makes
that mandatory per subproject, in stack-neutral vocabulary, so this shell suite
is in scope exactly as an Elixir one is.

## How to use this

Pick a row. Re-apply the mutation. The named case should fail with the named
string. If it still passes, the check it protects has stopped being
load-bearing and the row is now a bug report. Rows recording a **measured zero**
mark a claim no test protects — they are the important ones, written up rather
than quietly dropped.

Backups were taken with `cp` before each mutation and restored with `cp` after
(never `mv`, whose preserved mtime has burned this repo before; never
`git checkout --`, which cannot restore an as-yet-uncommitted file).

---

## 2026-09-19 — building the guard

- **Code under test:** `ai/bin/forge-preflight`, `ai/hooks/forge-identity-guard.sh`
- **Suite run:** `bash ai/test/forge-preflight/self-test.sh` (no network — the
  gh-athena/glab-athena wrappers are shims passed via GH_ATHENA_BIN /
  GLAB_ATHENA_BIN; each records its argv)
- **Baseline:** `VERDICT: PASS (19 cases)` (11 at first pass; 8 added over three
  athena-diff-critic rounds — the GitLab identity gap, the failed-lookup gaps,
  the flags-before-subcommand gap, and the alias-host gap — see the review-round
  section)
- **Runner:** 10 mutations, one at a time, full suite after each; restored between.

### What the suite proves

| # | Mutation | Cases reddened | Failure string(s) |
|---|---|---|---|
| S1 | `forge-preflight`: GitHub probe `"$GH_ATHENA" --check` → `"$GH_ATHENA" api user` (**THE TRAP** — probe with the endpoint an App install token 403s on) | 2 | `FAIL  healthy github: passes silently` / `FAIL  403-from-api-user while --check passes: PASSES via --check` |
| S2 | the refuse message's own `Fix:` line no longer names `~/.claude/github-athena-app-id` | 1 | `FAIL  creds absent: refuses with a Fix: line naming the file` |
| S3 | GitLab probe `"$GLAB_ATHENA" api user` → `--check` (breaks the per-forge asymmetry) | 1 | `FAIL  healthy gitlab: passes silently via 'api user'` |
| S4 | unknown-host branch `exit 0` → `exit 1` (refuses on a forge it does not manage) | 1 | `FAIL  unmanaged host: passes and invokes no wrapper` |
| S5 | hook regex `gh[[:space:]]+pr[[:space:]]+create` → `gh.*pr.*create` (so `gh-athena pr create` also matches) | 1 | `FAIL  wrapper path not surfaced` |
| S6 | hook `additionalContext` → `permissionDecision:"deny"` (block instead of warn) | 1 | `FAIL  bare 'gh pr create': surfaced as a non-blocking warn` |
| S7 | GitLab identity assertion `jq -e '.username=="athena-amby" and .state=="active"'` → `grep -q '"username"'` (accept any authenticated user) | 1 | `FAIL  gitlab wrong identity: refuses` |
| S8 | the no-origin refuse block `exit 1` → `exit 0` (a failed lookup reads as a clean pass) | 1 | `FAIL  no origin remote: refuses` |
| S9 | drop the `github.com-*`/`*.github.com` alias patterns from the `case` (an alias host falls through to the unmanaged-host pass) | 2 | `FAIL  github alias host classified as github` / `FAIL  github subdomain classified as github` |
| S10 | drop the host lowercasing (`tr '[:upper:]' '[:lower:]'`) so a mixed-case host misses the `case` arms | 1 | `FAIL  mixed-case host normalized to github` |

S1 is the row that matters most: it is the single most likely way to get this
ticket wrong (per DND-203/DND-206), and it reddens two cases — the healthy pass
AND the explicit 403-vs-`--check` regression guard — because the shim 403s on
`api user`, so a guard that probed there both refuses a healthy wrapper and
records `api user` in its argv.

To pin S2 on the preflight's OWN output, the `gh_broken` shim emits a GENERIC
message with no filename; otherwise case 1's "names the file" assertion is
satisfied by the relayed wrapper string and a preflight that dropped its own
`Fix:` filename stays green (observed during construction, then fixed).

### Measured zeros (claims no mutation here reddens)

- **MZ1 — refuse-message prose beyond its greppable tokens.** Deleting the
  explanatory line "so any PR opened now would be silently attributed to the …"
  left `VERDICT: PASS (11 cases)`. The suite pins only the load-bearing tokens
  (`Fix:`, the filename, `glab-athena refresh`), not the surrounding prose.
  Intentional: asserting exact wording makes the test brittle without adding
  safety.

  **Later (2026-09-23):** DND-390 made the athena-amby token refresh
  OWNER-GATED (`forge-auth-guard.sh` rule 6 denies it). Case 5 now pins the
  preflight's own `Fix: the athena-amby token needs refreshing, which is
  OWNER-GATED` line plus `escalate to your admiral`, and asserts the output
  does NOT contain `glab-athena refresh`. The `glab_broken` shim is now
  GENERIC, like `gh_broken`, so no relayed wrapper text can satisfy those
  tokens. Mutations checked: deleting the preflight's GitLab Fix: block, and
  restoring the old self-refresh Fix:, each redden case 5.
- **MZ2 — the unknown-host note wording.** Changing "is not a managed forge" to
  "is not a forge we know" left `PASS (11)`. Case 6 pins the *behaviour* (exit 0,
  no wrapper invoked), not the note text.
- **MZ3 — the hook's additionalContext prose.** Rewording the warning body
  (while keeping `Fix:` and `gh-athena`) left `PASS (11)`. Case 7/9 pin the
  greppable tokens and the warn-not-block decision, not the sentence.

### Review round (athena-diff-critic, 2026-09-19)

The standing critic raised four findings; all were valid and fixed:

1. **[correctness] GitLab probe accepted any authenticated user**, not
   specifically the athena-amby service account — so the preflight could pass
   while MRs were still opened as the owner. Fixed to assert
   `.username=="athena-amby" and .state=="active"` (the same test the wrapper's
   own `refresh` uses). Regression-guarded by case 5b / sabotage S7.
2. **[tests] no case exercised a wrong GitLab identity, a missing remote, or a
   malformed host.** Added cases 5b (wrong identity → refuse), 5c (no origin →
   refuse), 5d (empty host → refuse).
3. **[correctness] failed lookups read as clean passes.** No-origin and
   empty-host now REFUSE with a `Fix:` (repo doctrine: "a failed lookup must
   never look like an empty one"), and host classification is alias-aware
   (`github.com-work`, `ssh.github.com`) so a real github target can no longer
   slip past via an alias. A genuinely unknown host still passes with a note.
4. **[convention] relative `Fix:` paths.** The hook fires in every session,
   including product repos where `ai/bin/...` does not resolve; all `Fix:` paths
   are now absolute `~/dev/custom/ai/bin/...`.
5. **[correctness, 2nd round] hook missed flags before the subcommand.**
   `gh -R owner/repo pr create` / `glab -R x mr create` (common cross-repo
   forms) were unwrapped bare writes the hook did not surface. The regex now
   tolerates a `[^;|&]* ` flag segment between the command word and `pr`/`mr`
   (cannot cross a command separator), while the wrapper — even with the same
   flags — still does not match. Guarded by case 8b.
6. **[note→addressed] "nothing calls forge-preflight".** The preflight is now
   invoked at the top of the captain's "Open the MR" step
   (`ai/agents/athena-captain.md.in`), so a broken wrapper stops the captain
   before it writes (the DND-206 "Done when"). The bypass hook was already
   auto-active via `registry.json` + `scripts/setup-hooks --install`.
7. **[correctness, 3rd round] alias hosts untested + a template contradiction.**
   Added cases 3b/3c/3d pinning the `github.com-*` / `*.github.com` /
   `gitlab.com-*` classification patterns (sabotage S9), and fixed the captain's
   "Open the MR" step which named the bare `glab mr create` right after saying
   "do NOT fall back to a bare gh/glab write" — it now names the
   `glab-athena`/`gh-athena` wrapper. Also removed a leaked `set -e` from the self-test helpers (the suite
   runs `set -uo pipefail`, no `-e`).

### Review floor (code-reviewer + adr/convention-reviewer, 2026-09-19)

Both reviewers cleared the change with **no must-fix items**. Nits addressed:
- **case-sensitive host** → the host is now lowercased before classification so
  `GitHub.com` cannot fall through to the unmanaged-host pass (case 3b-ii,
  sabotage S10).
- **misleading remedy when `jq` is absent** → the preflight now checks for `jq`
  up front with its own `Fix:`, instead of fail-closing later with a
  `glab-athena refresh` message that would not fix a missing `jq`.
- **GitHub `--check` cannot prove the App is athena-harness specifically** (an
  installation token can't fetch the `/app` slug) → documented as an inline
  LIMITATION comment with the follow-up, matching the honesty the GitLab
  identity assertion already has.
- **hook covers only `create`** → the header now states this scope explicitly
  so it is not mistaken for full write coverage (deliberate per DND-206).
- **doc citation by number** → "step 8" is now the captain's "Open the MR" step
  (cite-by-name convention).
