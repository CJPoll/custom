---
name: athena:diagnose-github-actions-failure
description: Diagnose a GitHub Actions pipeline that yields no usable result — either it FAILS without producing logs (dies in ~1-2s, 0 steps executed, dependent jobs skipped, `gh run view --log-failed` returns "log not found" / BlobNotFound; the real reason is in the check-run annotations API, headline cause billing exhaustion) or it never STARTS and sits `queued` indefinitely (headline cause an offline/unlabelled self-hosted runner, readable from the actions/runners API). Both are owner-gated and no re-run or longer wait can clear either. Use whenever a GitHub Actions pipeline fails with empty/absent logs, or stays queued for many minutes, before calling it a transient flake, re-running it, or continuing to watch it.
---

# athena:diagnose-github-actions-failure

Two signatures where the pipeline gives you **no usable result** and the obvious
response (re-run it; keep watching it) is the wrong one, because in both the
answer lives in an API the run page never shows you:

1. **It fails, with no logs** — read the check-run *annotations* (below).
2. **It never starts, staying `queued`** — read the *actions/runners* API
   (*Signature 2 — the pipeline never starts*, below).

## Signature 1 — it fails without producing logs

A GitHub Actions job that **fails in ~1-2 seconds with 0 steps executed**, with
its dependent jobs (Format / Credo / Test / …) all **skipped**, and where
`gh run view <run-id> --log-failed` returns **"log not found" / BlobNotFound**,
did NOT flake. The job never started; the log never existed. The real reason is
carried in the **check-run annotations**, not the run log — and it is usually a
**billing block**, which no amount of re-running can clear.

This has cost the fleet effort twice: the DND-152 admiral misread it as a
transient CI-infra flake and manually re-ran the `--failed` job; the
selfhosted-runner effort re-confirmed the same signature. Re-running is the wrong
move and burns time. Diagnose first.

### The signature

Treat it as this class when you see **all** of:

- job(s) fail in ~1-2s (often the first/`Build` job), and
- **0 steps** ran in the failed job, and
- every downstream job that `needs:` it is **skipped**, and
- `gh run view <run-id> --log-failed` says the log is not found (BlobNotFound).

### Diagnose it — read the annotation, don't re-run

Get the real reason from the check-run annotations API (the logs are empty):

```sh
# Find the failed check-run id for the run, then read its annotations:
gh api repos/<owner>/<repo>/check-runs/<check-run-id>/annotations
```

If you have the run but not the check-run id, list the run's jobs / check-runs
first (`gh run view <run-id> --json jobs`, or
`gh api repos/<owner>/<repo>/commits/<sha>/check-runs`) and take the failed
one's id.

The billing signature reads roughly:

> The job was not started because recent account payments have failed or your
> spending limit needs to be increased. Please check the 'Billing & plans'
> section in your settings.

### What to do about it

- **Billing exhaustion is owner-gated and external.** Do NOT touch billing,
  account, or payment state, and do NOT keep re-running — the pipeline can never
  pass until the owner restores GitHub Actions billing (Settings → Billing &
  plans). Surface it: mark the work blocked (in a Notion-tracked run, set the
  ticket to the tracker's blocked status — e.g. `Needs Attention` — and record
  that it is blocked on GitHub Actions billing), and hand it back to the owner
  with the exact annotation text and the run/commit it blocks.
- **Once billing is restored**, re-run the pipeline on the same commit.
- **If the annotation says something else** (a config/permission/quota error, a
  disabled workflow, a missing runner label), fix that specific cause — the
  point of this skill is that the *log* is a dead end for this whole class, so
  the **annotation is the source of truth**, whatever it turns out to say.

## Signature 2 — the pipeline never starts (`queued` forever)

The run is created but no job ever reaches `in_progress`: `gh pr checks` reports
everything **pending**, `gh run list` shows the run `queued`, and minutes turn
into tens of minutes. **A queue that will never drain looks exactly like a slow
one** — the failed-lookup class in a different dress (`ai/CLAUDE.md` → *A failed
lookup must never look like an empty one*). Waiting longer cannot tell them
apart; one API call can. So on a repo whose jobs declare
`runs-on: [self-hosted, …]`, do not watch a queue for more than a few minutes
without checking whether anything is listening to it.

### Diagnose it — ask who is listening, don't wait longer

```sh
gh api repos/<owner>/<repo>/actions/runners \
  --jq '.runners[] | {name, id, status, busy, labels: [.labels[].name]}'
```

Two distinct causes, both of which queue forever:

- **`"status": "offline"`** — the runner agent is not connected. Nothing will
  ever pick the job up.
- **Online but the labels don't match** the job's `runs-on` set — the job is
  waiting for a runner that does not exist. A label typo queues just as
  permanently as an outage.

Also confirm the **last successful dispatch** (`gh run list --branch <b> --json
headSha,status,createdAt`) to date the onset, and check whether a *different*
head already went green on the same job set — a CI-neutral change over a green
head is strong evidence the stall is the runner, not the diff.

**A self-hosted runner usually lives on another machine.** Measured 2026-09-20:
`cjpoll-laptop` (runner id 21, labels `[self-hosted, Linux, X64]`) was the sole
runner for `CJPoll/gen_saas` and ran on the **laptop**, while the fleet ran on
`home-office-linux`. So `pgrep`-ing for an `actions-runner` process locally, or
finding the local host healthy (load, memory, container count), proves **nothing
at all** about the runner and must not be reported as evidence either way. The
runners API is the only authority.

### What to do about it

- **Restarting it is owner-gated** and usually a system service on a machine
  this session is not even on — never touch it (`ai/CLAUDE.md` → *Hard Rule*:
  no unattended system-level changes). Surface it with the identity that makes
  the instruction actionable: runner **name, id, labels, status**, which **host**
  it runs on, the repo, and the time of the last successful dispatch.
- **Stop watching and re-plan around it.** An indefinite `gh pr checks --watch`
  is a stall, not a wait. Split the scope by what the runner gates: drive every
  **runner-independent** tier (anything landing by a local gate rather than CI)
  all the way to landed, and build the runner-dependent work as far as it goes
  — fully implemented, reviewed, local checks green — as **stacked PRs that
  merge none**. Same shape as `athena:run-autonomously`'s *Owner-credential
  gates throttle merging, not progress*: the gate throttles **merging**, never
  progress.
- **Never overclaim.** A PR whose CI never ran is not "green" or "ready" — each
  such PR and the return report says **CI-green is PENDING runner recovery**,
  explicitly.

## Escape hatch: self-hosted runner

If paying to restore hosted-Actions billing is off the table, the proven
alternative on this machine is a **self-hosted runner** — the
`setup-github-runner` script in `~/dev/custom/scripts` plus the
`system-files/*github-runner*` OpenRC services provision one (dedicated no-root
user + rootless Docker), and flipping the workflow jobs to
`runs-on: [self-hosted, linux, x64]` moves CI + deploy off paid minutes. That is
an owner decision, not something to do mid-mission without direction.
