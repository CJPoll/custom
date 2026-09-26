# Sabotage records — forge CLI token isolation (DND-725)

A test is not finished until you have watched it fail. Each row below is a
mutation I applied to a COPY of `ai/bin` + `ai/lib`, then ran the suite against
that copy with `GLAB_ATHENA_UNDER_TEST` / `GH_ATHENA_UNDER_TEST`. The working
tree was never mutated.

## How to use this

Pick a row. Re-apply the mutation to a copy. The named cases should fail. If one
still passes, the check it protects has stopped being load-bearing, and the row
is now a bug report.

---

## 2026-09-25 — building the fix

- **Code under test:** `ai/bin/glab-athena`, `ai/bin/gh-athena`,
  `ai/lib/forge-cli-isolation.sh`
- **Suite run:** `bash ai/test/forge-token-isolation/self-test.sh` (no network;
  fake `glab`, `gh` and `curl` on PATH, fixture HOME holding a fake owner login)
- **Baseline:** `VERDICT: PASS (19 cases)`

### Fail-first: the suite against the unfixed wrappers (8bd00e2)

`RESULT: 6 passed, 12 failed`. The defect cases, verbatim:

```
FAIL  1. empty default token file refused
      rc=0 who=owner out='{"username":"owner","state":"active"}' err=''
FAIL  2. whitespace-only token file refused
      rc=0 who=owner out='{"username":"owner","state":"active"}' err=''
FAIL  3. empty override token file refused
      rc=0 who=owner out='{"username":"owner","state":"active"}' err=''
FAIL  6. healthy call isolated from the owner config
      rc=0 who=token:glpat-SELFTESTATHENA0000 owner_reachable=yes cfg=<unset>
FAIL  10. inherited identity env scrubbed
      envnames='CI_JOB_TOKEN GITLAB_ACCESS_TOKEN GITLAB_API_HOST GITLAB_URI GLAB_ENABLE_CI_AUTOLOGIN GL_HOST OAUTH_TOKEN ' ...
FAIL  13. gh isolated from the owner config
      rc=0 who=token:ghs_SELFTESTFAKETOKEN0000 reach=yes cfg=/tmp/.../home/.config/gh mode=755 err=''
FAIL  18. whitespace cached token rejected
      rc=0 who=token:  err=''
```

Case 19 did not exist yet at that run. Cases 4, 9, 11, 12, 15 and 16 passed on
the old wrappers: 4 and 9 held before, and 11/12/15/16 only count leftover dirs,
of which the old wrappers made none. Rows S4 and S10 below are what make those
cases load-bearing.

### What the suite proves

| # | Mutation | Cases reddened |
|---|---|---|
| S1 | `glab-athena`: drop the `fci_require_token` call | 1, 2, 3, 4, 5 |
| S2 | `glab-athena`: drop `fci_isolate` | 6, 7, 8, 10 |
| S3 | `glab-athena`: drop `fci_scrub_env` | 10 |
| S4 | lib: drop the EXIT trap that removes the config dir | 8, 11, 12, 15, 16, 17 |
| S5 | lib: `chmod 700` → `chmod 755` on the config dir | 7, 13 |
| S6 | lib: `fci_token_ok` accepts anything non-empty (no whitespace/control check) | 5, 18, 19 |
| S7 | `gh-athena`: drop `fci_scrub_env` | 14 |
| S8 | `gh-athena`: drop `fci_isolate` | 13, 17 |
| S9 | `gh-athena`: cache check back to `[ -n "$tok" ]` | 19 |
| S10 | `glab-athena`: run glab with `exec` again | 8, 11, 12 (and 15–17 via the shared TMPDIR leftover count) |

An earlier draft had explicit `trap 'exit 143' TERM` (and HUP/INT) handlers.
Removing them left every case green: bash runs the EXIT trap on termination by
those signals anyway. The handlers were removed as dead code, and case 12 now
pins the EXIT-trap behaviour they claimed to provide.
