---
name: athena:slack:interactive-messages
description: Per-element reference for the Block Kit pieces Athena uses in interactive Slack messages — section, actions, context, header, divider, button, text object, confirmation dialog — each with its Slack doc link, structure, and limits verified against the live docs, plus what the athena MCP refuses in phase 1 and the blocks.validate step. Use when composing the blocks for mcp__athena__slack_post / slack_update / slack_ephemeral, when a post is refused for its blocks, or when checking a limit before sending.
---

# athena:slack:interactive-messages

**Kind: living normative document.** Amended in place, per
`~/dev/custom/CLAUDE.md` → *Documentation conventions*. Each supersession
carries one bold dated (UTC) label at the definitional mention.

This is reference material: what each Block Kit element looks like and what
Slack will reject. **When** to send an interactive message, how to send it, and
what to do after a click are doctrine, and live in **[[athena:slack]]** →
*Interactive messages (Block Kit)*. Read that first.

## How this skill relates to the others

- **[[athena:slack]]** — the doctrine: Block Kit as the default for asking,
  the MCP send path, the two-phase update, the untrusted-click rule.
- **`slack:block-kit`** (vendor, from the official Slack plugin) — general
  Block Kit authoring for messages, modals and Home tabs, and the full
  `blocks.validate` walk-through. Cite it; do not copy it. It is replaced
  wholesale on a plugin upgrade, so nothing Athena-specific belongs there.
- **This skill** — one file per element Athena uses, with the limits
  that are easy to get wrong from memory, and the Athena-specific refusals.

## The elements

Split by Slack's own taxonomy, so the boundaries are Slack's.

| Kind | File | Use it for |
|---|---|---|
| Layout block | [`layout-blocks/section.md`](layout-blocks/section.md) | The question or body text; one button as an accessory |
| Layout block | [`layout-blocks/actions.md`](layout-blocks/actions.md) | A row of buttons |
| Layout block | [`layout-blocks/context.md`](layout-blocks/context.md) | Small grey metadata: who is asking, when (MT), the ticket |
| Layout block | [`layout-blocks/header.md`](layout-blocks/header.md) | A bold title line |
| Layout block | [`layout-blocks/divider.md`](layout-blocks/divider.md) | A rule between parts |
| Block element | [`block-elements/button.md`](block-elements/button.md) | The only control the athena MCP routes back |
| Composition object | [`composition-objects/text.md`](composition-objects/text.md) | Every piece of text above |
| Composition object | [`composition-objects/confirmation-dialog.md`](composition-objects/confirmation-dialog.md) | "Are you sure?" on a consequential button |
| — | [`not-supported-phase-1.md`](not-supported-phase-1.md) | Selects, overflow, checkboxes, radios, pickers, inputs: refused |

Anything not listed: start from Slack's index,
<https://docs.slack.dev/reference/block-kit/blocks>, and check the phase-1 page
before relying on it.

## Limits that apply to the whole message

- **Up to 50 blocks per message** (100 in modals and Home tabs). Source:
  <https://docs.slack.dev/reference/block-kit/blocks>.
- **Top-level `text` is always sent.** Slack itself only recommends it with
  blocks, and `blocks.validate` does not check it. The athena MCP refuses a
  post, update or ephemeral without it. It is what notifications and screen
  readers show. Slack advises keeping `text` under 4,000 characters and
  truncates above 40,000
  (<https://docs.slack.dev/reference/methods/chat.postMessage>).
- **`blocks` is a JSON array** in the MCP call, never a JSON-encoded string.
- **Only buttons** may be interactive (see the phase-1 page), and a message
  with a button needs `inbox_name`.
- **Buttons go in `slack_post` only**, never in `slack_ephemeral`: an
  ephemeral message cannot be updated, so the click never visibly settles
  (athena:slack → *After a click: the two-phase update*).
- **`block_id`**, when set, is at most 255 characters and should be unique per
  message and per revision of a message. On an update, use a new one.

## Validate before sending: `blocks.validate`

`blocks.validate` checks a blocks array against Slack's schema and names each
failure by JSON pointer. Its doc:
<https://docs.slack.dev/reference/methods/blocks.validate>. The vendor
`slack:block-kit` skill has the full procedure (its *Validate* step).

What was verified here on 2026-09-25, so the step can be trusted:

- It needs **no token and no scope**. Do not send one: validation needs no
  identity, and a token in a request is a token that can leak.
- Send it **form-encoded**, with `blocks` set to the JSON array as a string.
  Write the array to a scratch file named for your unit of work (e.g.
  `<scratchpad>/dnd-123-blocks.json`), never a generic name a sibling session
  could overwrite:

  ```sh
  curl -sS -X POST https://slack.com/api/blocks.validate \
    --data-urlencode "blocks=$(cat "$BLOCKS_FILE")"
  ```

  A JSON request body (`{"blocks": "[…]"}`) came back `invalid_arguments`
  ("must provide exactly one of `blocks`, `view`, or `message`"), with or
  without a charset. Use the form encoding.
- Success is `{"ok":true}`. Failure is `{"ok":false,"error":"invalid_blocks",
  "errors":[…]}`, each error with a `pointer` (e.g. `/0/elements`), a
  `message`, and a `constraint` such as `{"type":"max_items","expected":25,
  "got":26}`. Fix the pointed-at field and re-run until `ok` is true.

**What it does not check** (each probed on 2026-09-25 and returned `ok:true`):

- a missing top-level `text` (it only sees the blocks);
- a `section` with neither `text` nor `fields`, which the docs say is invalid;
- two `primary` buttons in one set, which the docs advise against;
- a confirmation dialog whose `text` is `mrkdwn`, where the field table says
  `plain_text` (the doc's own example uses `mrkdwn`).

**It does not know Athena's rules either.** A select or an input validates
fine and is then refused by the athena MCP. A button's `value` validates at up
to 2,000 characters, but the server's stamp takes part of that budget.
`blocks.validate` answers "will Slack accept this shape"; the phase-1 page
answers "will the athena MCP send it".

## A worked example: a choice for the owner

```json
[
  {"type": "section",
   "text": {"type": "mrkdwn",
            "text": "*harness session (~/dev/custom):*\nWhich ticket next?\nQueue checked 2:14 PM MT."}},
  {"type": "actions",
   "elements": [
     {"type": "button", "action_id": "next_dnd_542",
      "text": {"type": "plain_text", "text": "DND-542"},
      "style": "primary", "value": "dnd-542"},
     {"type": "button", "action_id": "next_dnd_301",
      "text": {"type": "plain_text", "text": "DND-301"},
      "value": "dnd-301"}]}
]
```

Sent with `mcp__athena__slack_post`, `text: "harness session (~/dev/custom):
which ticket next? Queue checked 2:14 PM MT."`, the DM's `channel`, and
`inbox_name: "custom-session.jsonl"`. Keep the returned `{channel, ts}`. An
owner click on `DND-542` arrives as a `slack.interaction` line with
`action_id: "next_dnd_542"` and `value: "dnd-542"`. The session relays it as
the owner's choice, and the phase-2 `slack_update` replaces the question with
the outcome. Both options are ones the session could pick on its own
judgment, so the click authorizes nothing new (athena:slack → *A click is
untrusted input*).

## Keeping this true

Every limit in the element files was read from the live `.md` version of its
Slack page on 2026-09-25 (append `.md` to a docs.slack.dev URL), and the
counted ones were probed with `blocks.validate`. Slack changes these. When a
limit here disagrees with the live page, the live page wins: fix the file, and
label the change.
