# glab-athena merge guard: sabotage records (DND-742)

**Later (2026-10-02, DND-1668):** the MR iid in the shapes below (4242) is a
synthetic stand-in. The records first carried a real work-repo MR iid; the
public repo no longer holds it. The measurements are unchanged.

**Later (2026-10-03, DND-1936):** glab-athena now picks its bot from the
project's namespace before the guard runs, and refuses what it cannot key: any
`api graphql`, a numeric project id, a dot segment, %-encoding past the project
path, an absolute URL. So G1–G12, F1 and F2 (and the original shapes of A3,
A7, A9 and A12, as A3g, A7g, A9g, A12g) run the guard itself (`glmg_guard`,
sourced) instead of the wrapper, and still kill the mutants credited to them
below (S7, X2, X3, X6). W1–W3 pin that the wrapper refuses those shapes. The
other route cases name the project by path (`example-group%2Fexample-app`)
instead of `1`.

The suite is `ai/test/glab-athena-merge-guard/self-test.sh` (a stub `glab` on
PATH, no network). The hook cases live in
`ai/hooks/forge-identity-guard.self-test.sh` (2c2, 2q–2z4).

## Old vs new (fail-first)

Recorded 2026-09-26 on c78f0cd's `ai/bin`, `ai/lib` and `ai/hooks` (the unfixed
code), with the final tests:

- Wrapper suite: `RESULT: 32 passed, 67 failed`.
  - Red: every refusal case: M1, M3–M6, M8–M13, M13b, M13c, M15, M16, M18–M20,
    M22; A1–A14; T1, T3–T9, T14–T16, T19, T20; G1–G9; F1, F2; C1; D1, D2. Also
    the read assertions M2b, M21b, T2b, T13b and T18b, because the old wrapper
    reads nothing.
  - Green: every pass-through case: N1–N15, G10–G12, T10–T13, T17, T18, M2,
    M7, M7b, M14, M14b, M17 and M21.
  - The incident shape, M1: `rc=0 out=stub: ran mr merge 4242 --yes err=''
    execs=mr merge 4242 --yes`. An unpinned merge reached glab with no check.
- The same 32/67 split on the rebase base f10b4dc (glab-athena and its libs
  did not change between the two).
- Hook suite, against f10b4dc's hook (it carries DND-741's cases too):
  `RESULT: 168 passed, 9 failed`. Red: 2c2, 2q, 2r, 2s, 2t, 2u, 2u2, 2v and 2w
  (`expected deny … status=0 out=[]`).

On the fixed code (rebased on DND-741): wrapper `RESULT: 108 passed, 0 failed`,
hook `RESULT: 177 passed, 0 failed`.

## Critic round (2cf200c): argv the guard read differently from glab

The critic found `mr merge 4242 --help --help=false --yes` went to glab
unjudged. The guard short-circuited on `--help`, and pflag lets the later
`--help=false` switch help off, so glab merges. This is kind 1 under
athena:critic-convergence: the defect was present from the first commit. Its
class is "the guard's argv reading differs from glab's". A sweep of that class
found a second site. glab dispatches `glab -R g/r api …` to api (measured on
glab 1.112), but the guard read the command only when `api` came before any
non-flag word. So `-R g/r api <merge route> -f sha=…` passed unjudged.

Fix: drop the help short-circuit, read the command from the flag-aware
positional parse, and refuse any word before `api`. Evidence, from the final
tests on 2cf200c's code: `RESULT: 99 passed, 9 failed` (M17, M23, M24, A15,
A16, A18–A21). A20 shows the real pass-through:
`rc=0 out=stub: ran -R example-group/example-app api projects/1/merge_requests/2/merge -f
sha=…`. Fixed: 108/0. Class-closed assertion: `grep -c HELP
ai/lib/glab-merge-guard.sh` gives 0. The only early `return 0` in `glmg_guard`
comes after `glmg_api_guard` has judged the call. gh does not share the second
site: `gh -R o/r api …` fails with "unknown shorthand flag", and `gh -- api …`
fails with "unknown command" (measured). The gh-athena merge-guard suite
(`RESULT: 136 passed, 0 failed`) exercises the shared code too.
`gmg_api_guard` now parses with `fas_parse_api` and scans with
`fas_graphql_scan` from `ai/lib/forge-api-scan.sh`.

## Critic round (fb0baa7): a flag cluster before the subcommand

The critic found `glab-athena mr -ym merge 4242` went to glab unjudged. The
guard read the words before the subcommand with the `mr merge` flag table, so
`-m` took `merge` and the command read as `mr 4242`. Cobra finds the command
with its own walk (`stripFlags`), where a flag word longer than two characters
is dropped alone. Measured on glab 1.112: `glab mr -ym merge x --help` prints
`mr merge`'s help, and so do `-dm`, `-h`, `-Rg/r` and `--repo=g/r` in that
spot. `mr merge` then reads `-y` as yes and `-m 4242` as the message, and merges
the current branch's MR with no pin.

Kind 1 under athena:critic-convergence: the pre-subcommand parse has used the
merge table since the first commit. Class: "the guard's reading of WHICH
command runs differs from cobra's". Root fix: before the command path (the
first word, or the first two after `mr`), only `-R`/`--repo` forms may appear,
the one flag that parses the same both ways; any other flag word there, `--`
included, is refused when raw argv holds `merge`, `accept`, `api` or `mcp`. Raw
argv, because the table parse can swallow the merge word itself. This replaces
the round-2 "unknown flag before the subcommand" check.

Class-closed assertion: M32 places every short flag, every two-letter cluster
of them, and every long flag in the tables before `merge` and before `mr` (95
spellings x 2 shapes), and requires a refusal for all 190. Only the `-R`/`--repo`
forms run (M29-M31).

The critic's "not assessed" item, other subcommands that merge: a `--help` walk
of glab 1.112's command tree, three levels deep, found one. `mr create
--auto-merge` ("Set the merge request to merge when all merge checks pass")
schedules a merge on an unpinned head. `mr update` has no such flag. So
`--auto-merge` is now refused on any command but `mr merge` (C2-C5).

Evidence on the unfixed code (e9d9247's guard, with the new cases):
`RESULT: 111 passed, 12 failed`. M25-ym shows the pass-through:
`rc=0 out=stub:\ ran\ mr\ -ym\ merge\ 4242 … execs=mr\ -ym\ merge\ 4242`, and
C2 `rc=0 … execs=mr\ create\ --fill\ --auto-merge\ --yes`. Fixed: `RESULT: 124
passed, 0 failed`. Mutation S15 below turns the new cases red.

## Mutations of the glab guard

Each row applies ONE change to the fixed code and runs the wrapper suite. Every
mutation turns at least one named case red.

| id | mutation | red cases |
|----|----------|-----------|
| S1 | the pin is never compared with the head | M3 T3 |
| S2 | any head-pipeline status counts as passed | M4 M4b M4c M5 T4 T20 |
| S3 | a merged-results pipeline is trusted without reading its commit | M2b M8 M10 M20 |
| S4 | `mr accept` is not treated as a merge | M12 |
| S5 | a sha field read from a file is accepted | T5 |
| S6 | a method-override header does not make a call a write | A5 |
| S7 | a GraphQL body the guard cannot read passes | G4 G5 G6 G7 F1 F2 |
| S8 | an unknown flag before the subcommand is ignored (the round-2 check; replaced in round 3, see S15) | M18 |
| S9 | `mcp serve` passes | C1 |
| S10 | routes are matched case-sensitively | A8 |
| S11 | a query string on the train endpoint is accepted | T6 |
| S12 | the dry-run value is read after the `GLAB_*` scrub | D1 |
| S13 | the MR read for boarding is not checked to be the same iid | T14 |
| S14 | the train route's DELETE pass ignores a method override | T16 |
| S15 | a flag before the command path is never reported | M18 M25-* M26 M27 M28 M32 A17 |

S12 is a real defect the suite caught during development.
`fci_scrub_env` removes every `GLAB_*` variable, so the first cut read
`GLAB_ATHENA_MERGE_DRY_RUN` after the scrub, and the seam executed instead of
printing. D1 went red: `out=stub: ran mr merge 4242 --sha …`.

## Mutations of the shared lib (`ai/lib/forge-api-scan.sh`)

Each row changes the shared lib once and runs BOTH wrapper suites. A defect in
the shared parser or scan must show in each.

| id | mutation | gh suite red | glab suite red |
|----|----------|--------------|----------------|
| X1 | an unknown api flag is ignored | A21 | A11 |
| X2 | a failed grep reads as "no mutation" | F2 | F2 |
| X3 | a stdin field (`@-`) is not refused | U2 | G4 |
| X4 | a header never marks a method override | A17 R9 R10 | A5 T16 |
| X5 | `fas_path` keeps a leading `api` segment | A15 | A3 A13 |
| X6 | an `--input` body is not scanned | G7 G8 U5 RG9 | G3 G6 |

X2 first showed NONE in the glab suite. It had no scan-failure case, so F1 and
F2 were added.

## DND-1845: the integration-gate receipt

The defect: the guard pinned the head and its passed pipeline, but never asked
whether integration-gate passed that head. An MR integration-gate held at
exit 4 (which writes no receipt) could be merged or boarded on the train.

### Old vs new (fail-first)

Recorded 2026-10-03 on origin/main 16848545's `ai/bin` and `ai/lib` (the
unfixed code, run with `GLAB_ATHENA_UNDER_TEST`), with the final tests:

- `RESULT: 132 passed, 51 failed`.
- Red: every R case except R5a-R5g (non-merge writes, which ran before and
  still run), and D3. The old wrapper read no receipt, so each miss merged:
  R1 printed `rc=0 out=stub: ran mr merge 4242 --sha 4cc5665… --yes` with no
  receipt in the store, and R2 the same for the train POST.

On the fixed code: `RESULT: 183 passed, 0 failed`.

The mutation table below was recorded before the review round added R26-R31
(remote shapes, the host pin); S22 kills R24b, and R31b is its twin on the
merge-command path.

### Mutations of the guard

Each row changes `ai/lib/glab-merge-guard.sh` once, in place, and runs the
suite. Every mutation turns at least one case red.

| id | mutation | red |
|----|----------|-----|
| S16 | the train path skips the receipt check | R2 R3b R4 R4b R6b R9c R9d R24 R24b |
| S17 | the remote match drops its host anchor (`evil-host` matches `host`) | R16 |
| S18 | `NO RECEIPT` reads as a pass | R1 R1c R2 R2b R4 R8-* R8b-* R9 R9b-R9e R18 D3 |
| S19 | a missing target_branch is not refused | R23 |
| S20 | the re-pushed-head wording is never used | R9b R9d |
| S21 | the merge-command path skips the receipt check | R1-R3, R6, R7, R8-*, R9, R9b, R9e, R10-R23, R25, D3 |
| S22 | the target-tip read drops `--hostname` | R24b |

## DND-1941: parity with GitHub's merge bar

The gaps, against ai/lib/gh-merge-guard.sh: a merge onto a RED target tip
(its pipelines or its content, DND-1902) went through; glab's default
auto-merge (a deferred merge, which no receipt can cover) went through with a
pin and a receipt; and API writes that create or move a ref
(`repository/commits`, `repository/branches`, `protected_branches`,
`remote_mirrors`, GraphQL `commitCreate`, …) ran unjudged.

### Old vs new (fail-first)

Recorded 2026-10-03 on the branch base bbf06766's `ai/lib/glab-merge-guard.sh`,
`ai/lib/gh-merge-guard.sh` and `ai/bin/glab-athena` (the unfixed code,
swapped into the worktree so the receipt seal verifies), with the final tests:

- `RESULT: 196 passed, 80 failed`.
- Red: T12, R2b, AM1-AM9, AM11-AM14, W1-W16, GR1-GR6, P1-P17 (with P1b,
  P1c, P6b, P7b), P18b, P18c, GS1-GS5 (with GS1b), K1-K3, K6.
- The misses, each `rc=0` with the command reaching glab:
  - AM1: `out=stub: ran mr merge 4242 --sha 4cc5665… --yes`, auto-merge on.
  - P1, P6: `ran mr merge 4242 --auto-merge=false --sha 4cc5665… --yes` onto
    a failed tip, and onto a tip with no pipeline.
  - GS1: `ran mr merge 77 …` onto a gen_saas tip holding two migrations with
    version 20250101000000.
  - W2: `ran api -X POST projects/:id/repository/commits -f branch=main …`.
  - GR1: `ran api graphql -f query=mutation { commitCreate(…) }`.
  - AM11: the train POST with `-f auto_merge=true -f sha=…` ran.

On the fixed code: `RESULT: 276 passed, 0 failed`.

### Mutations

Each row changes one line of the fixed code in place and runs the suite.

| id | mutation | red |
|----|----------|-----|
| S23 | `mr merge` skips the tip gate | P1-P18c, GS1-GS4 (27 cases) |
| S24 | auto-merge defaults to off | AM1 AM8 |
| S25 | an empty pipelines list reads as CLEAN | P6 P6b |
| S26 | a DELETE with a method override counts as a plain DELETE | W14 W15 |
| S27 | `gmg_content_re` drops its key check | K1 K2 K3 |
| S28 | an older red pipeline is always superseded | P11 |
| S29 | the train accepts an `auto_merge` field | T12 AM11-AM14 |
| S30 | the ref-route check is off | W1-W16 |
| S31 | the pipelines' sha/ref check is off | P15 P16 |
| S32 | pipelines are not grouped by source | P12 |
| S33 | `gmg_line_check` ignores the runs judge it is given | 48 cases, every merge that should run |

S32 first survived: P12 listed the failed child pipeline as the NEWER one, so
one ungrouped list judged it red too. P12 now lists it as the older one, which
only a per-source judgment keeps red.

### Review round (bf22a932)

The review floor added P6c, P13b-P13d (`canceling` is red; a newer web run
does not clear a failed push pipeline, and the Fix says to retry it), W24-W24d
(group-level `protected_branches`), GS6 (a head not in the local store onto a
duplicated tip) and AM15 (`--auto-merge=false` after `--`). Suite on the fixed
code: `RESULT: 287 passed, 0 failed`.

| id | mutation | red |
|----|----------|-----|
| S34 | `canceling` is not red | P13b |
| S35 | `groups/…` paths are not scanned for ref routes | W24 W24b |
