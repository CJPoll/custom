---
name: athena:memory-maintenance
description: Maintain the memory substrate (Knowledge Graph + auto-memory) — consolidate and dedup near-duplicate facts, archive stale ones, keep it indexed and retrievable — as a reviewed PROPOSAL, never a silent mutation. Use on a cadence (e.g. a shipwright pass), when memory has grown noisy, duplicated, or stale, or when MEMORY.md nears its load limit.
---

# athena:memory-maintenance

Memory earns its keep only if it stays clean and retrievable. Over time the KG
(`kg:*`) and auto-memory (`memory/`) accrete duplicates, stale facts, and
orphans that dilute retrieval. This skill gives that substrate a lifecycle —
consolidation, dedup, decay/archive, indexing, and an explicit retrieval policy.

**The one safety property: never lose a unique fact.** Every change here is a
**proposal a human (or the shipwright, on review) approves** — this skill
proposes and explains; it does not silently mutate memory. When in doubt, keep.

## Scope

- **Knowledge Graph** (`kg:*`) — structured, relational facts. Prefer it as the
  home when consolidating: a fact expressible as a node + relationships belongs
  in the KG, not as a flat note.
- **Auto-memory** (`memory/MEMORY.md` + linked notes) — flat, single
  observations, preferences, project context.

## Procedure

Run these as a read-first, propose-then-apply loop. Produce the full proposal
before changing anything.

### 1. Inventory
- Read the KG (query the relevant graphs) and the auto-memory files.
- Note each entry's substance, provenance (where it came from), and last-touched
  signal if available.

### 2. Dedup + consolidate (propose)
- Group entries that assert the **same fact**. Two are true duplicates only when
  one carries **no information the other lacks** — same subject, same claim, no
  extra qualifier, scope, date, or relationship.
- For each duplicate group, propose a single merged entry that **unions** every
  detail (keep the richer provenance, the tighter scope, every relationship).
- **A near-duplicate that adds any qualifier is NOT a duplicate** — keep it, or
  merge only if the qualifier is folded into the survivor. If unsure, keep both
  and flag for human judgement.
- When a fact lives in auto-memory but is structured/relational, propose
  **promoting it to the KG** (and leaving a pointer), not duplicating it.

### 3. Decay + archive (propose)
- An entry is a decay candidate when it is **stale and unreferenced** — it
  describes a state of the world that has since changed, or nothing points at it.
- **Archive, never hard-delete.** Move it to a recoverable archive (an
  `archived` section/graph or an archive note), with the reason and date. A fact
  wrongly archived must be one edit to restore.
- A durable fact (a decision, a constraint, a relationship, an infra gotcha) does
  not decay just because it is old — age is not staleness. Only archive when the
  fact is genuinely superseded or obsolete.

### 4. Index
- Ensure entries are findable: consistent naming, the right graph/section, and
  cross-links so a task-start query surfaces them. Propose renames/links that
  improve retrieval; do not rewrite the fact itself.

### 5. Retrieval policy (the standing rule)
This is the policy every agent follows at task start (it complements CLAUDE.md's
memory-read guidance):
- **Query before substantive work** — feature/infra/planning/debugging/business
  tasks. Check: relevant business terms + stakeholders, prior decisions/
  constraints in the area, related entities + relationships, recorded
  lessons/gotchas.
- **KG first for structured/relational** lookups; auto-memory for flat notes and
  preferences.
- **A miss is signal** — if the graph has nothing on the topic, that itself is
  worth recording from once the task surfaces durable knowledge.
- Prefer the **most specific** matching entry; when two conflict, prefer the one
  with the later provenance and flag the conflict for consolidation.

## Output: the proposal

Emit a proposal, not a mutation:
- **Merges**: each duplicate group → the proposed survivor (with the unioned
  detail) and the entries it subsumes.
- **Archives**: each decay candidate → the archive target + reason + date.
- **Promotions**: auto-memory → KG moves.
- **Index changes**: renames/links.
- **Unique facts preserved**: an explicit assertion that no unique fact is
  dropped — list anything you were tempted to drop but kept, with why.

Apply only after review. Prefer `kg:*` write skills for KG changes and ordinary
edits for auto-memory; keep the archive recoverable.

## Index budget (auto-memory `MEMORY.md`)

`MEMORY.md` is loaded into every session, but only up to a size limit. Past it
the TAIL is cut, and the tail holds the NEWEST lessons. Nothing errors: the
entries just stop loading. Captains report the loader's numbers as a 24.4KB
read limit, with compaction requested below 17.1KB.

The file is shared by every session, so no one captain rewrites it, and it
fills. Measured: DND-241 saw it truncated at 25.8KB; DND-774 and DND-761
(2026-09-26) each flagged it near the limit; it was 25366 bytes when the
shipwright compacted it that day.

**Who compacts it:** the shipwright, on its cadence, when the file passes
~22KB. It is the reviewer this skill names, so it proposes and applies in one
pass. Any other session that finds the file over the limit reports it rather
than rewriting a shared file.

**How, losslessly:**
- Change index LINES only. The linked note files hold the facts; never edit or
  delete one here.
- Back up the whole file first (the shipwright keeps copies in
  `ai-artifacts/shipwright/memory-index-backups/`).
- Merge a duplicate pair into ONE line that links BOTH files.
- Trim long descriptions at a word boundary, ending with `…`. Keep the title
  and link intact.
- Assert afterwards that the set of linked files is unchanged.
- Write via a temp file and rename, and refuse if the file's mtime moved
  since you read it (another session appended).

## Guardrails

- Proposal-only; no silent mutation of memory.
- Never drop a unique fact; archive (recoverable), never hard-delete.
- Prefer the KG (structured) over auto-memory (flat) when consolidating.
- Age is not staleness — durable decisions/constraints/gotchas persist.
