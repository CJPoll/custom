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

## Fleet-mechanical operations are Sonnet by default

The tests above are for *Missions*, but a fleet also dispatches a class of small
mechanical follow-ups that are almost always Sonnet and were, measurably, not
tiered. On the 2026-09-20/21 run the token accounting found **~97% of all
subagent output tokens ran on Opus and Sonnet was ~3%**, with a recorded model
rationale in only one of four coordination runs — the tiering skill existed and
was essentially unused. The clearest waste was Opus spent on work that meets
*all* the Sonnet tests by construction:

- **Verbatim application of an exact edit** an architect/admiral already wrote
  out (the marker text, the `_meta` note, the addendum line) — the change is
  fully specified, the dispatcher is asking for typing, not judgment.
- **A citation/marker/name sweep against a landed class-closed assertion** — the
  pattern is decided and success is a `grep` that must return zero
  (`~/dev/custom/CLAUDE.md` → *A failed lookup must never look like an empty
  one*, "patch the class"; [[athena:critic-convergence]] → *Closing a sweep*).
- **A rename, a config-key change, or an ADR/record move** with a landed sibling
  to copy.

**But a critic-fix / resolver loop is NOT mechanical** — do not tier it to Sonnet
by reflex. The resolver's output is re-judged by the critic every round, so a
weaker resolver buys *more rounds*, not fewer, and each round is itself an Opus
critic re-read of the whole diff. Tiering the resolver down is the false economy
this skill's *default to Opus when unsure* is guarding; keep design-bearing
resolution on Opus. (Tiering the resolver never weakens a gate — the critic, the
gate, and the tests are model-independent and unchanged — it only shifts the
cost/rework tradeoff, and for a design-heavy loop it shifts it the wrong way.)

**Record the choice for EVERY dispatch, not just the interesting ones.** The
state log's Model column with a one-line reason is required per dispatch; a blank
is a defect, not a default, and it is how a whole run silently drifts to Opus.
An unrecorded dispatch cannot be tiered in review, and the run above is what that
looks like.
