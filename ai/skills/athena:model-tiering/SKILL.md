---
name: athena:model-tiering
description: The criteria the athena-admiral uses to pick a captain's model (Sonnet vs Opus) from a mission's real complexity. Use when dispatching a captain and deciding whether to override the captain default of Opus with Sonnet. Encodes the Sonnet-when-all / Opus-when-any tests, worked examples, and the first-of-a-series rule. The safety-preserving defaults — default to Opus when unsure, and record the choice — live resident in the admiral definition.
---

# athena:model-tiering

**Pick the engineer's model from the Mission's complexity.** The athena-captain
definition defaults to `model: opus`; override it with `model: "sonnet"` on the
`Agent` call when the Mission is *bounded and mechanical*, and leave Opus for
anything that needs judgment. Decide on the Mission as it actually is (read it
and the code it names), not on its label, and write the choice and the one-line
reason into the state log next to the dispatch. Default to Opus whenever unsure —
a Sonnet engineer that goes STUCK gets re-dispatched once under Opus into the
same worktree, and that costs more than the tokens Sonnet saved.

**Sonnet** when *all* of these hold: the change is fully specified before
dispatch (an exact recipe, a landed sibling to copy, a lab commit to
cherry-pick, a rename/sweep/config-key change); it touches test, config, CI, or
docs only — or a small, well-covered runtime surface (≤ ~3 files, no new module,
no new seam); it needs no design decision, no access-control interpretation, and
no investigation of *why* something behaves as it does; and success is checkable
by a tool (the suite is green, a count matches, a grep is empty). Examples from
this fleet: a `pool_size` config change with the lab's evidence already in hand;
a tenant-fixture sweep across files whose pattern is already landed; an ADR 017
record move; a CI variable rename.

**Opus** when *any* of these hold: the Mission asks for a design or a mechanism
(a new case template, a new adapter/seam, a process manager, an authorization
rule); it touches prod topology or restart/leader-election behaviour, migrations,
or anything schema-destructive; it needs root-cause work (a flake, a race, "why
is this sync", a regression hunt); the acceptance criteria leave room to
interpret (access control, cross-subdomain boundaries, what "done" means); it
must reconcile with another open MR or a colleague's work; or its blast radius is
> ~3 runtime files. Examples: PT-582's per-process Commanded instance, an async
tranche that must *find* each file's real reason for being sync, a deploy-gating
CI change, anything the athena-captain doctrine calls "stop early and report".

A tranche of look-alike Missions is not automatically Sonnet: the *first* of a
series (the one that establishes the pattern) is Opus; the follow-ups that copy a
landed pattern are Sonnet candidates.
