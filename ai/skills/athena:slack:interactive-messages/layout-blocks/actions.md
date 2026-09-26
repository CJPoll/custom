# Actions block

Slack doc: <https://docs.slack.dev/reference/block-kit/blocks/actions-block>
(verified 2026-09-25). Surfaces: messages, modals, Home tabs.

Holds interactive elements in a row. This is where a question's answer buttons
go.

## Structure

```json
{
  "type": "actions",
  "block_id": "merge-42-v1",
  "elements": [
    {"type": "button", "action_id": "approve", "text": {"type": "plain_text", "text": "Approve"}, "style": "primary", "value": "approve"},
    {"type": "button", "action_id": "reject", "text": {"type": "plain_text", "text": "Reject"}, "value": "reject"}
  ]
}
```

| Field | Required | Notes |
|---|---|---|
| `type` | yes | always `actions` |
| `elements` | yes | interactive element objects |
| `block_id` | no | see limits |

## Limits

- `elements`: at most **25**. `blocks.validate` rejects 26 with
  `max_items` (probed 2026-09-25).
- `block_id`: at most 255 characters, unique per message and per revision.
- Each element's `action_id` should be unique within the block.

## In Athena

- Slack lists buttons, selects, overflow menus and date pickers as valid here.
  **Only buttons** survive the athena MCP; see
  [not-supported-phase-1.md](../not-supported-phase-1.md).
- Two to four buttons is the useful range. Past that, the question is
  probably free-form, and plain text serves better (athena:slack → *Block Kit
  is the default for asking a person*).
- After the owner clicks a terminal button, the server removes the whole
  `actions` block and puts a `working…` line where it was (phase 1). The
  phase-2 `slack_update` replaces that with the outcome. A click on a button
  marked `"athena_terminal": false` leaves the block as it is (see
  [button.md](../block-elements/button.md) → *In Athena*).

  **Later (2026-09-26):** DND-616. This said the block is removed after any
  owner click. Since DND-549 a non-terminal button's click leaves it.
