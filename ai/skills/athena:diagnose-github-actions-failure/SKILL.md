---
name: athena:diagnose-github-actions-failure
description: Diagnose a GitHub Actions job that fails WITHOUT producing logs — dies in ~1-2s with 0 steps executed, dependent jobs skipped, and `gh run view --log-failed` returns "log not found" / BlobNotFound. The real reason lives in the check-run annotations API, not the logs. The headline cause is billing exhaustion (failed payment / spending limit), which NO re-run can clear — so read the annotation before you retry. Use whenever a GitHub Actions pipeline fails and the logs are empty or absent, before diagnosing it as a transient/infra flake or re-running it.
---

# athena:diagnose-github-actions-failure

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

## The signature

Treat it as this class when you see **all** of:

- job(s) fail in ~1-2s (often the first/`Build` job), and
- **0 steps** ran in the failed job, and
- every downstream job that `needs:` it is **skipped**, and
- `gh run view <run-id> --log-failed` says the log is not found (BlobNotFound).

## Diagnose it — read the annotation, don't re-run

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

## What to do about it

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

## Escape hatch: self-hosted runner

If paying to restore hosted-Actions billing is off the table, the proven
alternative on this machine is a **self-hosted runner** — the
`setup-github-runner` script in `~/dev/custom/scripts` plus the
`system-files/*github-runner*` OpenRC services provision one (dedicated no-root
user + rootless Docker), and flipping the workflow jobs to
`runs-on: [self-hosted, linux, x64]` moves CI + deploy off paid minutes. That is
an owner decision, not something to do mid-mission without direction.
