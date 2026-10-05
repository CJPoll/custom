# Fork MR pipeline refusal: sabotage records (DND-1942)

The suite is `ai/test/glab-athena-fork-pipeline/self-test.sh` (a stub `glab`
on PATH, no network). It runs `ai/bin/glab-athena`, the agent PATH glab
(`ai/agent-bin/glab`) with the routed marker built by hand, and the two
chained, as in an agent session.

## Old vs new (fail-first)

Recorded 2026-10-03 against fb24dc1c (origin/main when the branch was cut;
the unfixed wrappers), through the suite's own seam
`AGENT_FORGE_ROOT_UNDER_TEST=<checkout of fb24dc1c>`, with the first
round's 64 cases:

- `16 passed, 48 failed`.
  - Red: every refusal case, in all three fronts, and the two read
    assertions (the MR list read for the current branch; `-R` naming the
    project read), because the old wrappers read nothing.
  - Green: every pass-through case (a same-project MR pipeline, a branch
    ref, a branch job, `ci list`, a GET, `schedule run` on a branch).
  - The incident shape, the first case: `exit 0, want 3; out: stub: ran api
    -X POST projects/7000001/merge_requests/11/pipelines`, with !11 a fork
    MR (source project 8000002, target 7000001). A fork MR's pipeline was
    created in the parent with no check.

`ai/test/glab-athena-merge-guard/self-test.sh` changed with this: its MR
fixture now carries `source_project_id` and `target_project_id`, and N13 (an
MR pipeline), R5f and R5g (a manual job play/trigger) now stage the MR or job
the fork check reads, and expect reads. On the fixed code: `ALL CASES PASS`.

## Review round (code-reviewer and adr-reviewer)

The review found five ways through the first round's guard and one false
denial. Each now has a case. Against the first round's code (e6bfff0d), the
final suite is `69 passed, 10 failed`; the red cases:

- `ci create`, glab's alias of `ci run` (glab 1.92.1 `run.go`,
  `Aliases: create`), on an MR ref and with `--mr`: ran unjudged.
- `ci run --mr -b OWNER:BRANCH`: glab lists MRs by the BRANCH part
  (`mrutils.resolveOwnerAndBranch`); the guard listed `OWNER:BRANCH`, found
  none, and allowed it.
- `;` in the query string: a server that splits parameters on `;` reads a
  `ref` the guard did not.
- A branch, tag or release made from a fork MR ref (`repository/branches`,
  `repository/tags`, `releases`, `release create --ref`): it puts the fork's
  code and CI file on a parent ref, whose pipeline then runs here.
- A branch named `fix-merge-requests-list` was refused as COULD NOT LOOK (a
  substring match). It now passes; it reads the branch and no MR.
- `schedule update --update-variable` was refused as an unknown flag (update
  has its own variable flags).

On the fixed code: `79 passed, 0 failed`.

## Critic round (athena-diff-critic BLOCK on 62525e38)

The critic found the branch, tag and release routes still passed a ref that
was not spelled as an MR ref: a fork MR's head commit sha, which GitLab keeps
in the parent, made a parent branch or tag of the fork's code with no read.
The rule is now deny by default: a ref the caller names must be an MR ref
(judged) or an existing branch or tag of the project, read by its exact name;
anything else is COULD NOT LOOK. A ref GitLab itself recorded on a job,
pipeline or schedule is judged only in its MR form.

The same round found two vacuous assertions: "a branch ref reads nothing" and
"that branch reads nothing" reset the fixtures before reading the log, so
they could not fail. They now read the log first.

Against the review round's code (62525e38), the final suite is `80 passed, 6
failed`: the sha branch, the keep-around tag, `release create --ref <sha>`,
`ci run -b <sha>`, a ref that is no branch or tag, and "a branch ref reads
only that branch". On the fixed code: `86 passed, 0 failed`.

## Mutations

Each applied alone to the fixed code, the suite run, then reverted:

| Mutation | Suite |
|---|---|
| M1 a fork MR (source != target) never refuses | 54 passed, 32 failed |
| M2 a failed API read is not refused at the read | 83 passed, 3 failed |
| M3 a `ref` in the query string is ignored | 85 passed, 1 failed |
| M4 the agent wrapper's routed path skips the check | 82 passed, 4 failed |
| M5 `ci run --mr` skips the MR list | 77 passed, 9 failed |
| M6 `api … jobs/<id>/retry|play` skips the job read | 83 passed, 3 failed |
| M7 a caller's ref skips the branch-or-tag read | 80 passed, 6 failed |

M2 first SURVIVED: a failed read leaves no JSON, so the next check refused
anyway with "is not !11", and the cases asserted only `COULD NOT LOOK`. The
unreadable-object cases now assert the read failure itself (`COULD NOT LOOK:
could not read !11`), and M2 is caught.

## Post-rebase critic round: `--mr` read as a Go bool (2026-10-04)

Defect: the guard set the `--mr` flag for any `--mr=<v>` but the exact string
`false`, and never cleared it, so `ci run --mr=0 -b <sha>` skipped the
branch-or-tag read on `-b` and passed a commit sha.

Red before the fix (new cases only, unfixed lib): `88 passed, 4 failed`. First
failing case: `ci run --mr=0 -b <sha> is no --mr run, so the sha refuses` ->
`something ran: api --paginate projects/:id/merge_requests?source_branch=0123…`.
Green after (`glfp_mr_value`: Go bool spellings, last wins, other values refuse):
`92 passed, 0 failed`.

## Rebase onto DND-1976 and DND-1936: release argv from the pinned table (2026-10-05)

Change: `glfp_release` read `glab release create` with its own hand-kept flag
lists. It now reads them from `ai/lib/glab-flag-table.sh`, the pinned table the
outbound scan reads, and refuses COULD NOT LOOK when the table is missing.

Red before (new cases, unchanged lib): `100 passed, 1 failed`. Failing case:
`no pinned glab flag table: release create refuses, naming the table` ->
`exit 0, want 3; out: stub: ran release create v1 -r main -N x`.
Green after: `101 passed, 0 failed`.

The outbound suite's 5 release reds (`--ref -n -F`, `-r -N --notes-file`,
`--ref --`, `--ref -F`, plain `--ref main`) came from its stub, which answered
no branch read: the guard read each ref as glab does and refused it as not a
branch. The stub now answers branch reads, and all 237 cases run and pass.

The DND-1936 identity map refuses an endpoint that names its project by a
numeric id, a `..` segment, and `api graphql` (BAD KEY) before this guard runs.
The suite now keys `example-group` in a fixture map and names the parent
project by path. The `..` and GraphQL cases are judged on the agent wrapper,
with one glab-athena case each pinning the BAD KEY precedence.

## A help invocation passes unread (DND-2078)

Change: a judged command whose argv asks for help (`-h`, `--help`,
`--help=true`) passes before any ref, MR or branch is read. Help is the
outbound scan's rule, `ots_help_asked` in `ai/lib/outbound-text-scan.sh`, over
a strict `ots_pflag_parse` with the command's flag table. `glos_switch_on`
moved there as `ots_switch_on`, so both read a switch one way.

Red before (new cases, unchanged libs at ec6e00c4): `110 passed, 19 failed`.
Every help case failed, on both fronts. The incident shape, the first case
(cli-flag-table's own probe): `exit 3, want 0; out: glab (agent wrapper):
REFUSING` the release create, `COULD NOT LOOK: the ref '' is empty or could
not be URL-encoded (jq failed), so it cannot be read (DND-1942)`. Every
not-help case (`--ref --help`, `-b --help`, `-H --help`, `--help=false`,
`--help --help=false`, an unknown flag beside `--help`, `-- --help`, and an
empty ref with no help) was already green and stays green.
Green after: `129 passed, 0 failed`.
