# Oban worker renames ship their queue migration in the same MR

**Kind: dated record** (an incident note — annotate, never rewrite; per
`~/dev/custom/CLAUDE.md` → Documentation conventions).

**Incident #473 · 2026-09-02.**

Renaming an Oban worker module **orphans rows enqueued under the old name** —
including SCHEDULED-FUTURE rows that are invisible to any git diff (measured:
48h-ahead follow-up nudges discarding at 100% as each came due).

## The rule

Any MR renaming a worker **MUST include a data migration** renaming the old→new
worker strings in `oban_jobs`:

- Cover the states `scheduled` / `available` / `retryable`.
- Match `Oban.Pro.Worker` too.
- Beware **intermediate spellings** when a module was renamed twice.

## What the MR must answer

- **Rollout section** answers both directions:
  - "previous release vs this schema?" and
  - "new release vs the persisted queue?"
- **Exposure analysis** enumerates `scheduled_at` horizons, not just in-flight
  rows — the future-scheduled rows are the ones a diff cannot see.

## Enforcement

The [[athena:merge-boarding]] gate references this doc: before merging an MR that
renames an Oban worker, the athena-admiral confirms the queue migration ships in
the same MR.

---

*Source (behavior-preserving relocation): athena-admiral "Worker renames ship
their queue migration in the same MR (incident #473, 2026-09-02)". The admiral
keeps a resident one-line trigger pointing here.*
