---
name: athena:create-agent-definition
description: Scaffold a new subagent definition (.md under ~/dev/custom/ai/agents/ or a project's .claude/agents/) following Claude Code's agent-naming rules and the Athena harness convention. Critically encodes that agent names CANNOT contain a colon, so the harness prefix uses a hyphen (`athena-`), not the `athena:` used for skills. Use whenever asked to create, add, or scaffold a new agent/subagent definition.
---

# athena:create-agent-definition

Create a new subagent definition. Agent definitions are Markdown files with YAML
frontmatter, discovered from:

- **project scope** — `<repo>/.claude/agents/*.md`
- **user scope** — `~/.claude/agents/*.md` (this machine symlinks the Athena
  collection at `~/dev/custom/ai/agents/`)

The registered agent name comes **from the frontmatter `name:` field only** —
the filename is not used for registration. Keep the filename matching the name
anyway, to avoid confusion.

## The naming rule that bites: NO COLONS in agent names

This is the whole reason this skill is separate from [[athena:create-skill]].

**Skills** namespace with a colon (`athena:standup`). **Agents cannot** — the
colon is reserved as the plugin namespace separator (`plugin:agent`) and is
forbidden in the `name:` field. The published validation regex for agent names
is:

```
^[a-z0-9]([a-z0-9-]{1,48}[a-z0-9])?$
```

- Allowed: lowercase letters `a-z`, digits `0-9`, hyphens `-`.
- Forbidden: colons (`:`), underscores (`_`), periods (`.`), uppercase, leading
  hyphen. Length 3–50.
- `main` is reserved (auto-renamed).

Empirically, **project-scope** agents on this machine have registered with
uppercase names (`Admiral`, `Captain`) despite the docs saying lowercase-only —
so enforcement is looser than the published regex for project agents. Do not
rely on that: it's undocumented, contradicts the regex, and will fail the
moment the agent is packaged as a plugin. **Write compliant names: lowercase +
hyphens.**

## Harness prefix for agents: use a hyphen

Because `:` is illegal, the Athena harness prefix for **agents** is
**`athena-`** (hyphen), the parallel of the skills' `athena:`. So the same
identity that gives a skill `athena:standup` gives an agent `athena-admiral`.

### Default and alternatives

- **Default: prefix new agent names with `athena-`.** A request for an agent
  `deploy-runner` becomes `athena-deploy-runner`.
- Other harnesses use their own hyphen prefix (e.g. `beryl-`). Honor a
  user-requested prefix.

### Don't double-prefix

If the requested name **already starts with a known harness prefix**, don't
prepend another.

| User asks for | Resulting agent name |
|---|---|
| `deploy-runner` | `athena-deploy-runner` (default prefix) |
| `athena-deploy-runner` | `athena-deploy-runner` (unchanged) |
| `beryl-something` | `beryl-something` (unchanged) |
| `deploy` + "use the beryl prefix" | `beryl-deploy` |

Detection rule: if the name already begins with `athena-` or another known
harness prefix (`beryl-`, …), leave it. Otherwise prepend `athena-` (or the
user's requested prefix). Since hyphens are also ordinary name characters, match
on the **known prefix list**, not merely "starts with letters then a hyphen".

## Reference docs in this skill

| File | Read it when |
| --- | --- |
| [preprocessor.md](preprocessor.md) | Creating or editing any **athena** agent under `~/dev/custom/ai/agents/` — those are generated from `.md.in` templates plus shared blocks by `ai/bin/build-agents`. Also read it when deciding whether text belongs in a block, a skill, CLAUDE.md, or the agent's own template. Skip it for project-scope agents in a repo's `.claude/agents/`, which are plain hand-written `.md`. |

## Steps

1. **Resolve the final name** per the rules above (lowercase, hyphens,
   harness-prefixed, no colon).
2. **Choose the location**: project `.claude/agents/` for repo-specific agents,
   or `~/dev/custom/ai/agents/` (user scope) for machine-wide Athena agents.
   For the user-scope location, write `<final-name>.md.in` (a template) and
   build it — see [preprocessor.md](preprocessor.md). The `.md` there is
   generated output; never hand-write it. Steps 3–5 below describe the
   content, which is the same in either case.
3. **Write `<final-name>.md`** (or `.md.in` for athena agents):
   ```markdown
   ---
   name: <final-name>
   description: <what the agent is for + WHEN to invoke it — this is the routing text the orchestrator/model reads>
   model: <opus | sonnet | haiku | fable>   # optional; omit to inherit
   color: <a display color>                  # optional
   tools: <comma-separated allowlist>        # optional; omit for all tools
   ---

   <the system prompt / operating instructions for the agent>
   ```
   - `name:` is what everything else must reference to spawn it.
   - `description:` should make the "when to use me" obvious — it's what an
     Admiral/orchestrator matches against.
4. **Update all references.** Renaming or introducing an agent means every place
   that spawns it must use the exact `name:` — sibling agent definitions that
   reference it, skills, `flaky-coordinator-spawn.txt`, and the global
   `CLAUDE.md` flaky-lane instructions. A reference with a colon (`athena:Admiral`)
   or a mismatched name will silently fail to resolve.
5. **Verify** the frontmatter `name:` is colon-free and regex-valid, and that
   the filename matches.

## Gotcha log

- A `:` anywhere in the `name:` field makes the definition fail to register as a
  usable type — the agent simply won't appear. (This is exactly why the legacy
  colon-named `athena:` Admiral / Captain / Architect definitions did not
  register, while the colon-free project `Admiral` / `Captain` did. They are
  now `athena-admiral` / `athena-captain` / `athena-architect`.)
- Filename ≠ identity. Registration reads `name:`; a pretty filename with a
  colon won't save a colon-bearing `name:`.
