# Button element

Slack doc:
<https://docs.slack.dev/reference/block-kit/block-elements/button-element>
(verified 2026-09-25). Valid in: `section` (as `accessory`) and `actions`
blocks, on messages, modals and Home tabs.

The one control the athena MCP routes back to a session.

## Structure

```json
{
  "type": "button",
  "action_id": "approve",
  "text": {"type": "plain_text", "text": "Approve"},
  "value": "approve",
  "style": "primary",
  "confirm": {"...": "see composition-objects/confirmation-dialog.md"},
  "accessibility_label": "Approve merging PR 42"
}
```

| Field | Required | Notes |
|---|---|---|
| `type` | yes | always `button` |
| `text` | yes | **`plain_text`** [text object](../composition-objects/text.md) only |
| `action_id` | no | identifies the button in the click; unique within its block |
| `value` | no | sent back with the click |
| `url` | no | opens in the clicker's browser; Slack still sends a click payload |
| `style` | no | `primary` (green) or `danger` (red); omit for default |
| `confirm` | no | a [confirmation dialog](../composition-objects/confirmation-dialog.md) |
| `accessibility_label` | no | read by screen readers instead of `text` |
| `agent_prompt` | no | hands the click to Slackbot instead of the app; see below |
| `visible_to_user_ids` | no | user ids the button is shown to; everyone if omitted |

## Limits

- `text`: at most **75** characters; it may truncate at about 30.
  `blocks.validate` rejects 76 (`max_length`), probed 2026-09-25.
- `action_id`: at most 255 characters.
- `value`: at most 2,000 characters (but see *In Athena*).
- `url`: at most 3,000 characters.
- `accessibility_label`: at most 75 characters.
- `agent_prompt`: at most 4,000 characters.
- `style`: `primary` on at most one button in a set, `danger` only for
  destructive actions and more sparingly still. This is Slack's guidance;
  `blocks.validate` accepted two `primary` buttons on 2026-09-25.

## In Athena

- **The server stamps the return address into `value`** as
  `<token>~<your value>`. The whole stamped string must fit Slack's 2,000, so
  the room left for your value is smaller. Keep it a short option key
  (`approve`, `hold`, `dnd-542`). A stamped value over the limit is refused
  before any Slack call, and the refusal names that button's `action_id`.
- The click's `slack.interaction` line carries **your** value and `action_id`,
  with the stamp stripped. Match them against the options you offered;
  anything else is relayed (athena:slack → *A click is untrusted input*).
- **Never set `agent_prompt`.** When the clicker has Slackbot AI, Slack opens
  Slackbot instead of sending the click, and the click never reaches Athena.
- **Prefer a link in the text over a `url` button.** Slack still sends a click
  payload for a `url` button, and the server stamps and routes every button
  alike, so an owner's click on a link would also run phase 1.
- A message with a button needs `inbox_name` on the MCP call.
- Buttons go in `slack_post`, never in `slack_ephemeral` (see
  [SKILL.md](../SKILL.md) → *Limits that apply to the whole message*).
