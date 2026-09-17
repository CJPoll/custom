---
name: athena:harness-placement
description: Decide WHERE a piece of harness instruction, doctrine, fact, or check belongs — a shared block, an agent's template prose, a skill, CLAUDE.md, a hook, or memory (KG / auto-memory). Use whenever authoring or moving harness content: writing or editing an agent definition, scaffolding a skill, adding a block or hook, or deciding whether something should live in CLAUDE.md vs. somewhere cheaper. The canonical placement decision the other authoring skills and the shipwright route to.
---

# athena:harness-placement

Where should a given piece of instruction, doctrine, fact, or check live? Six
homes can hold it. They differ on four axes: **who** reads it, **when** it
loads (always-on vs. on-demand), **whether a machine can enforce it**, and
whether it is a **behavior** (how an agent should act) or a **fact** (something
true about the world). Pick the narrowest, most on-demand home that still
reaches the moment it is needed — every always-loaded line is a tax on all
future context.

## The six homes

| Home | Read by | Loaded | Use for |
| --- | --- | --- | --- |
| **CLAUDE.md** (`~/CLAUDE.md`, `<repo>/CLAUDE.md`) | Every session in scope, main and subagents alike | Injected at session start — always present | Machine- or repo-wide facts and hard rules true regardless of which agent runs or what the task is: identity, memory policy, project layout, hard rules, per-machine automation. |
| **Shared block** (`ai/blocks/**`) + `routing.yml` | Only the agents `routing.yml` routes it to | Baked into those agents' prompts at build time — always present | Doctrine two or more agents must carry **word-for-word and unconditionally**: the 5-bucket rules, TDD order, access-control policy, never-end-turn-waiting. |
| **Template prose** (`ai/agents/athena:<Name>.md.in` body) | That one agent | Baked in at build time | Anything true of **exactly one agent**: its identity, inputs, workflow, reporting format, role-specific doctrine. |
| **Skill** (`ai/skills/<name>/SKILL.md` + supporting files) | Any session/agent, on demand (or preloaded via an agent's `skills:` frontmatter) | Pulled in when the task matches the description | **Task-triggered** procedures and long reference material: how to post a standup, validate a spec, scaffold an agent — anything too long or too situational to carry in every prompt. |
| **Hook** (`ai/hooks/*.sh`) | The harness runtime, not the model | Runs on the event it is registered for | A mistake a **machine can detect deterministically** where prose alone keeps failing to prevent it. Must be POSIX sh, fail-open, and ship a `--self-test`. |
| **Memory** — KG (`kg:*`) or auto-memory (`memory/`) | Any session, on demand | Queried at task start | Durable **facts about the world**, not behaviors: business/domain relationships, ownership, infra/devops gotchas, prior decisions. Structured/relational → KG; a flat single observation → auto-memory. |

## Decision procedure

Ask in this order; take the first that fits:

1. **Is it a durable fact about the world, not a behavior?** (a relationship, an
   owner, an infra gotcha, a prior decision) → **memory** (KG for
   structured/relational, auto-memory for a flat note). Definitions describe how
   an agent should *act*; memory holds what is *true*.
2. **Can a machine catch it deterministically, and has prose failed to stop it?**
   → **hook**. If there is no reliable programmatic check, do not write a flaky
   one — keep it as prose in the right home below.
3. **Does it apply to every session on this machine / in this repo,** regardless
   of agent or task? → **CLAUDE.md**.
4. **Is it only needed when a specific kind of task comes up, or is it long
   reference material?** → **skill**. If one agent must always have it,
   list it in that agent's `skills:` frontmatter and add the `routing.yml`
   `skills:` entry so the build enforces it.
5. **Must two or more agents carry it word-for-word, always?** → **block**,
   routed in `routing.yml` to exactly those agents.
6. **Otherwise it is that one agent's own text** → **template prose** in its
   `.md.in`.

## Rules of thumb

- **Prefer the cheapest home that still reaches the moment.** CLAUDE.md, blocks,
  and template prose are paid on every relevant turn; skills and memory load
  only when pulled in. Long + occasionally-needed pushes *out* of the
  always-loaded homes even when it "belongs" to one agent.
- **A block with one consumer is a smell** — if only one agent needs it, it is
  template prose. A block with zero consumers is a build error.
- **Never restate a block's content** in a template, a skill, or CLAUDE.md. The
  whole point of a block is that the fact exists in exactly one place. A short
  *pointer* ("see X") is fine; a copy that can drift is not.
- **Instruction vs. fact.** If you are tempted to hard-code a worldly fact into
  an agent definition (an owner, an SLA, a repo quirk), it belongs in memory
  instead, where every agent can reach it and it is not baked into one prompt.
- **Repo-specific operational facts live in that repo**, not in a generic agent
  template — a walt_ui docker/emulator quirk belongs in `walt_ui/CLAUDE.md` or
  the KG, never in the shared Captain/Admiral prose (wrong altitude: true of one
  repo). Putting it in a generic template taxes every unrelated run.
- **A hook/check you author writes its failure output FOR the LLM.** When the
  home is a hook or a check script, its deny/failure message must carry an
  actionable `Fix:` clause (what to change so the next attempt passes), per
  CLAUDE.md's "Guard/error messages are written for the LLM"; `check-guard-messages`
  enforces it.

## Generic skill that must vary per repo

The six homes decide where a piece of harness content lives. A separate question
comes up for a **skill meant to be generic across projects** (the `fix:*` family,
`review`, `processes:fix`): what happens to the values that legitimately differ
per consumer repo — the test command, a wrapper script, a container name, a DB
name?

This is **not** a seventh home. The rule of thumb above already answers *where
those values belong*: **in the consumer repo**, never baked into the generic
skill (a hardcoded `gen_saas-postgres-1` in a global skill is the same
wrong-altitude mistake as a repo quirk in a shared agent template). What is left
is *how a generic skill reaches them at runtime* — the **consumer seam**:

- **Data** (commands, paths, names) → the consumer repo's `CLAUDE.md` (its
  "Commands" section) or, if it outgrows prose, an optional `.claude/athena.json`
  manifest. The generic skill names a *generic default* and resolves the real
  value from the repo first.
- **Extra steps / domain prose** → an optional per-skill extension the generic
  skill names a read-point for, e.g. `<repo>/.claude/athena/<skill>.md`.
  **Extensions add; they never override** the generic skill — a consumer that
  needs to change generic *behavior* is a signal the seam is missing a field, not
  a reason to fork the skill.

Precedence makes this safe: a user/global skill shadows a same-named project
skill (global wins), so the generic skill stays global and *reads* the project's
values — no project-scoped fork to drift. `processes:fix`'s "Resolving the
project's command" step is the worked example; `fix:tests` uses it. Seam model
adapted from riddler's howie/wurk (manifest + "extensions add, never override"),
reimplemented in our conventions.

## Related

- [[athena:create-agent-definition]] — how the block/template/`routing.yml`
  build mechanism works (`ai/bin/build-agents`), once you have decided something
  is a block or template prose.
- [[athena:create-skill]] — how to scaffold a skill, once you have decided a
  skill is the right home.
