# custom CI: the harness gate under a masked /proc

**Kind: living normative document.** Amended in place, per
`~/dev/custom/CLAUDE.md` → *Documentation conventions*. Until its tickets
land, `.gitlab-ci.yml` and `system-files/gitlab-runner-runbook.md` hold the
old state. When a ticket lands, its file is normative and this document
defers to it.

Ticket: DND-1998 (reopened). It is T1 of `ai/docs/parallel-merge-deploy-latest.md`
and the prerequisite for its T3 (a push to `main` needs a `success` pipeline
on the head) on custom.

## The problem

custom's `harness-gate` job runs on the `ci` runner (57033950). Its docker
`security_opt` is `["seccomp:unconfined", "apparmor:unconfined"]`. `/proc` in
the job container stays masked: Docker overmounts `/proc/kcore`,
`/proc/keys`, `/proc/timer_list` and others, and makes `/proc/sys` read-only.

`tool-sandbox` runs `bwrap --unshare-all … --proc /proc`
(`ai/lib/tool_sandbox/policy.rb`). An unprivileged process may mount a fresh
procfs only when its mount namespace already holds a fully visible procfs
(the kernel's `mount_too_revealing` → `mnt_already_visible`). Docker's
overmounts make the job's `/proc` not fully visible, so bwrap fails with
"Can't mount proc on /proc: Operation not permitted". Three suites go red:
the `tool-sandbox` self-test, `ai/lib/test/tool-sandbox` and
`ai/lib/test/tool-propose`.

PR #389 reached 195/195 with `--security-opt systempaths=unconfined`. That
key is a docker CLI flag: the CLI turns it into empty `MaskedPaths` and
`ReadonlyPaths`. The Engine API refuses it as a `security_opt`, and
gitlab-runner exposes neither `MaskedPaths` nor `ReadonlyPaths`
([gitlab-runner#36810](https://gitlab.com/gitlab-org/gitlab-runner/-/issues/36810)).
Setting it on the runner broke every `ci` job (DND-2039).

## Facts the decision rests on

- **The `ci` runner's daemon is rootless.** Each runner user has its own
  rootless dockerd (runbook, *Design invariants*; `scripts/lib/gitlab-runner-kit.sh`
  header). A job container's root is a subuid on the host, not host root.
  Measured on the live `ci` runner (runbook, DND-1999 residual): writes to
  `/proc/sysrq-trigger` and `/proc/sys/kernel/sysrq` are denied, and
  `/proc/kcore` cannot be opened.
- **The `ci` job already holds that daemon's socket.** The DND-1973 contract
  mounts `/run/user/<uid>/docker.sock` at `/var/run/docker.sock` in every
  `ci` job, with `<builds>:<builds>` at the same path so a sibling container
  can bind the checkout. Only the job's container root can connect.
- **The docker CLI accepts what the runner cannot pass.** A job that runs
  `docker run --security-opt systempaths=unconfined` sends empty
  `MaskedPaths`/`ReadonlyPaths` through the Engine API, which accepts them.

## Decision: run the gate in a sibling container the job starts

The `harness-gate` job becomes a thin launcher:

1. Its image is a docker CLI image, pinned by tag and digest.
2. It builds `dockerfiles/ci-harness` (salvaged from #389) on the `ci`
   user's rootless daemon. The tag is the content hash of that directory, so
   the daemon's layer cache makes a rebuild free. No registry, no credential.
3. It runs the gate in a sibling:
   `docker run --rm --name custom-gate-$CI_JOB_ID --user ci
   --security-opt seccomp=unconfined --security-opt apparmor=unconfined
   --security-opt systempaths=unconfined
   -v "$CI_PROJECT_DIR:$CI_PROJECT_DIR" -w "$CI_PROJECT_DIR" <image>
   ai/bin/harness-gate`. `ci` is the non-root user #389's `setup.sh`
   creates in the image.
4. Before the gate, a second short-lived container with the same options
   runs the boundary probe (*The boundary*).
5. `after_script` removes the sibling by name, so a cancelled job leaves no
   container behind.

The sibling's `/proc` is unmasked, so bwrap's `--proc /proc` mounts. Every
suite runs with the production argv. Nothing in the harness changes.

### Why not the walt_ui options

**(a) bwrap without `--proc` under a CI marker: a loosening.** Dropping
`--proc` does not weaken the sandbox. A sandbox with no `/proc` denies more.
It weakens the check:

- CI would run an argv that production never runs. The tested artifact is
  not the shipped one.
- The probes that read `/proc` inside the sandbox could not run: E-12
  (rlimits from `/proc/self/limits`), E-13 (a new pid namespace, at most 3
  pids, no host pid), E-14 (nested limits), E-21 and E-23 (stdin is a pipe;
  a write through `/proc/self/fd/0` leaves the file unchanged). So the CI run
  would no longer prove pid isolation or the rlimits.
- Under T3 the CI pipeline is the push bar, so what CI proves is the bar.
- The marker is an in-repo switch the diff under test can set
  (`~/dev/custom/CLAUDE.md` → *A check's own bar must not live in the diff
  it is checking*).

That is item 5 (`~/.claude/CLAUDE.md` → *Owner approval policy*). *Decision:
run the gate in a sibling container the job starts* makes it unnecessary, so the default is not to do it.

**(b) A runner config that unmasks `/proc`.** No Engine API form exists for
the runner to send. `privileged = true` is refused by the runbook's
invariants and would give the job every capability in its user namespace.
A shell executor runs job code as a host user that sees every host
process's command line, and drops the pinned image.

**(c) Rejected alternatives.**

- *Bind `/proc` read-only into the sandbox.* E-13 fails, correctly: the
  sandbox sees the job's processes and can read the `environ` of same-uid
  processes, which holds `CI_JOB_TOKEN`.
- *Bind a host procfs (`-v /proc:/newproc`) or a dead-pidns procfs into the
  job.* Each needs a root-made mount on the host and a runner `volumes`
  change. The first shows every host process. A read-only bind does not
  satisfy the kernel check (a locked read-only mount is skipped for a
  read-write proc mount).
- *Rootless podman with `unmask=ALL`.* It works for the same reason the
  decision works, but it needs a new package, a new service and Cody's sudo.
  The rootless dockerd already gives the same boundary.

## The boundary

The decision grants nothing the `ci` job does not already have. Holding the
socket, the job could already start any container on its rootless daemon.
The boundary is the `ci` user's user namespace, and it is unchanged.

What the sibling's unmasked `/proc` allows, and what it does not:

| Path | Before (job container) | Sibling | Why |
|---|---|---|---|
| `/proc/sys/*` write | denied (read-only bind) | denied | container root is a subuid; sysctl writes need global root |
| `/proc/sysrq-trigger` write | denied | denied | the same |
| `/proc/kcore` open | denied (masked) | denied | `0400` global root |
| `/proc/sched_debug`, `/proc/timer_list` read | masked | readable | world-readable; they list host task names and timer state |
| `/sys/firmware` read | masked | readable | world-readable firmware tables |

Residual, named: `ci` job code can read host task names, timer state and
firmware tables. It holds no deploy secret, and it is first-party code (the
fork guard in `.gitlab-ci.yml`). A narrow seccomp profile (DND-2005) is
unaffected.

The boundary probe asserts the rows that must stay denied on every run.
In its own container, started with the gate's options but as the image's
root (`--user 0`), a write to `/proc/sys/kernel/core_pattern`
and to `/proc/sysrq-trigger` must fail, and `/proc/kcore` must not open. If
any succeeds, the job fails with `Fix:` naming a rootful daemon behind the
socket. This catches the one change that would make the decision unsafe: the
`ci` entry pointed at a rootful daemon.

The gate container never gets the socket. `ai/test/gitlab-ci/check.rb`
asserts the `docker run` line carries exactly the three `--security-opt`
values above and none of `--privileged`, `--pid=host`, `--network=host`,
`--cap-add` or a `docker.sock` bind.

## Tickets

In order. The admiral files them. `#389` stays open until the third lands,
then closes as superseded.

| # | Title | Kind | Severity | Salvage from #389 | Acceptance |
|---|---|---|---|---|---|
| 1 | suite-reaper: `proc-env-scan.awk` needs no gawk `time` extension | Bug | MEDIUM | "proc-env-scan needs no gawk time extension" (awk fix, S15, the exit-3 case) | S15 fails on the unfixed awk (gawk 5.2 deprecation warning on stderr) and passes after. Independent of the runner. |
| 2 | slack users-cache: jq expression parses under jq 1.7 | Bug | MEDIUM | "slack users-cache jq parses under jq 1.7" | The self-test case fails under jq 1.7 before, passes after. Independent of the runner. |
| 3 | custom CI: run harness-gate in a sibling container on the `ci` rootless daemon | Bug | HIGH | the image (`dockerfiles/ci-harness/Dockerfile`, `setup.sh`), "no ~/dev/custom link in CI", the `check.rb`/self-test extensions, the `harness_tools.rb` OUT entry for `dockerfiles/`, the `guard-classification.tsv` row | First a throwaway-branch pipeline proves the premise: `docker version` answers in the job, and the sibling runs `bwrap --unshare-all --proc /proc -- /usr/bin/true`. If either fails, stop and return to the architect. Then: a pipeline on a healthy head reads `success` with every check passing; the job log shows the boundary probe; `check.rb` cases for each forbidden flag fail before and pass after. It ships on the normal bar. #389's exit 4 on `harness_tools.rb` does not match the landed `ai/blast-radius/` manifest, and the OUT entry loosens no bar. |
| 4 | Runbook and CI comments: the `ci` row's masked `/proc` is handled by the sibling | Docs | LOW | none | The runbook's `ci` row, its DND-2039 note and the "Known state" comment in `.gitlab-ci.yml` say how DND-1998 closed, each with a *Later* label. Fold into 3 if the captain prefers one sweep. |

Ticket 3 replaces #389. From #389, the job's in-container install and the
`systempaths=unconfined` runner claim are dropped; the rest moves into
tickets 1-3.

## Assumptions

- The `ci` entry of runner 57033950 carries the DND-1973 contract (the
  socket and `<builds>:<builds>` volumes). Ticket 3's first step verifies it.
- The `ci` user's rootless dockerd mounts procfs for containers in a mount
  namespace with a fully visible `/proc`, so an unmasked sibling can mount a
  nested one. Ticket 3's first step verifies it.
- `systempaths=unconfined` from the docker CLI works against a rootless
  daemon. Ticket 3's first step verifies it.
