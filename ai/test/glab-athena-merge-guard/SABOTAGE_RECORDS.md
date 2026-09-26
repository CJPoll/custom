# glab-athena merge guard: sabotage records (DND-742)

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
  - The incident shape, M1: `rc=0 out=stub: ran mr merge 1473 --yes err=''
    execs=mr merge 1473 --yes`. An unpinned merge reached glab with no check.
- The same 32/67 split on the rebase base f10b4dc (glab-athena and its libs
  did not change between the two).
- Hook suite, against f10b4dc's hook (it carries DND-741's cases too):
  `RESULT: 168 passed, 9 failed`. Red: 2c2, 2q, 2r, 2s, 2t, 2u, 2u2, 2v and 2w
  (`expected deny … status=0 out=[]`).

On the fixed code (rebased on DND-741): wrapper `RESULT: 99 passed, 0 failed`,
hook `RESULT: 177 passed, 0 failed`. The gh-athena merge-guard suite
(`RESULT: 136 passed, 0 failed`) exercises the shared code too.
`gmg_api_guard` now parses with `fas_parse_api` and scans with
`fas_graphql_scan` from `ai/lib/forge-api-scan.sh`.

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
| S8 | an unknown flag before the subcommand is ignored | M18 |
| S9 | `mcp serve` passes | C1 |
| S10 | routes are matched case-sensitively | A8 |
| S11 | a query string on the train endpoint is accepted | T6 |
| S12 | the dry-run value is read after the `GLAB_*` scrub | D1 |
| S13 | the MR read for boarding is not checked to be the same iid | T14 |
| S14 | the train route's DELETE pass ignores a method override | T16 |

S12 is a real defect the suite caught during development.
`fci_scrub_env` removes every `GLAB_*` variable, so the first cut read
`GLAB_ATHENA_MERGE_DRY_RUN` after the scrub, and the seam executed instead of
printing. D1 went red: `out=stub: ran mr merge 1473 --sha …`.

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
