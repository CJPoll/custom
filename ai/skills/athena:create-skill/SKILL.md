---
name: athena:create-skill
description: Scaffold a new skill under ~/dev/custom/ai/skills/ following the Athena harness conventions — directory layout, SKILL.md frontmatter, and the harness-prefix naming rule (default `athena:`; don't double-prefix a name that already carries a known prefix). Use whenever asked to create, add, or scaffold a new skill.
---

# athena:create-skill

Create a new skill in this machine's skill collection. Skills live at
`~/dev/custom/ai/skills/<full-skill-name>/` and are surfaced to Claude Code
through the `~/.claude/skills` → `~/dev/custom/ai/skills` symlink, so a new
directory there registers automatically (no per-skill linking needed).

## Naming: the harness prefix

Skill names are namespaced with a **harness/application prefix** followed by a
colon, e.g. `athena:standup`, `athena:ticket-management`. The colon is the
skill namespace delimiter (Claude Code allows `:` in skill names; note that
**agent** names cannot use it — see [[athena:create-agent-definition]]).

### Default prefix

**By default, prefix new skill names with `athena:`** to mark them as part of
the Athena harness. So a request for a skill called `deploy-preview` becomes
`athena:deploy-preview`.

### Other prefixes

Other prefixes exist for other harnesses and applications — for example
`beryl:` (the Beryl harness). The user may explicitly request a different
prefix; honor it. If the user names a prefix that isn't yet in use, that's
fine — use it as given.

Known harness/application prefixes (not exhaustive; more may be added):

- `athena:` — the Athena harness (**the default**)
- `beryl:` — the Beryl harness/application

There are also **functional** namespaces in the collection that are not harness
prefixes but still occupy the same `<name>:` slot — e.g. `fix:`, `kg:`,
`format:`, `refactor:`, `backend:`, `slack:`. Treat any leading `<token>:`
segment as an already-present prefix for the double-prefix check below.

### Don't double-prefix

If the requested skill name **already includes a prefix** — any leading
`<token>:` segment, whether a known harness prefix like `athena:`/`beryl:` or a
functional namespace like `fix:` — do **not** prepend another. Examples:

| User asks for | Resulting skill name |
|---|---|
| `deploy-preview` | `athena:deploy-preview` (default prefix applied) |
| `athena:deploy-preview` | `athena:deploy-preview` (already prefixed — unchanged) |
| `beryl:whatever` | `beryl:whatever` (already prefixed — unchanged) |
| `fix:widgets` | `fix:widgets` (already prefixed — unchanged) |
| `deploy` + "use the beryl prefix" | `beryl:deploy` (requested prefix) |

Detection rule: if the name matches `^[a-z0-9-]+:` it already carries a prefix;
leave it alone. Otherwise prepend `athena:` (or the user's requested prefix).

## Steps

1. **Resolve the final name** per the rules above.
2. **Create the directory** `~/dev/custom/ai/skills/<final-name>/`.
3. **Write `SKILL.md`** with YAML frontmatter:
   ```markdown
   ---
   name: <final-name>
   description: <what it does + WHEN to use it, in one dense sentence or two — this is what Claude reads to decide relevance, so lead with the trigger>
   ---

   # <final-name>

   <the skill body: the actual instructions to follow when invoked>
   ```
   - `name:` **must exactly match the directory name.**
   - `description:` is the recall hook — say what the skill does *and the
     situations that should trigger it*. Write it for a reader deciding whether
     this skill applies.
4. **Add supporting files only if needed** — a skill can carry `bin/`, `lib/`,
   `test/`, reference docs, etc. beside `SKILL.md` (see `athena:slack` for a
   rich example). Keep simple skills to a single `SKILL.md`.
5. **Cross-link** related skills in the body with `[[other-skill-name]]`.
6. **Verify** the directory name and the frontmatter `name:` are identical, and
   that the description makes the trigger obvious.

## Conventions to match

- Follow the tone and structure of existing skills (`athena:standup`,
  `athena:ticket-management`) — imperative instructions, short sections,
  concrete examples over abstract description.
- Prefer one dense `SKILL.md` over sprawling files; split into supporting files
  only when the content genuinely warrants it.
