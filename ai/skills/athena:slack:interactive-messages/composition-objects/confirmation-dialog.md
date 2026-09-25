# Confirmation dialog object

Slack doc:
<https://docs.slack.dev/reference/block-kit/composition-objects/confirmation-dialog-object>
(verified 2026-09-24).

A confirm/deny dialog shown before an interactive element's click is sent.

## Structure

```json
{
  "title": {"type": "plain_text", "text": "Delete the branch?"},
  "text": {"type": "plain_text", "text": "This cannot be undone."},
  "confirm": {"type": "plain_text", "text": "Delete"},
  "deny": {"type": "plain_text", "text": "Cancel"},
  "style": "danger"
}
```

| Field | Required | Notes |
|---|---|---|
| `title` | yes | `plain_text` text object |
| `text` | yes | explanatory text; see the note on its type below |
| `confirm` | yes | `plain_text`: the confirm button's label |
| `deny` | yes | `plain_text`: the cancel button's label |
| `style` | no | `primary` (default) or `danger`, applied to the confirm button |

## Limits

- `title`: at most 100 characters.
- `text`: at most 300 characters.
- `confirm`, `deny`: at most 30 characters each.
- `text` type: the field table says `plain_text`, but the page's own example
  uses `mrkdwn`, and `blocks.validate` accepted `mrkdwn` on 2026-09-24. Use
  `plain_text` to stay inside the documented contract.

## In Athena

- Put it on a button whose click is consequential and hard to undo — a merge,
  a delete, a deploy. It costs the owner a second click, so skip it for
  reversible answers.
- Slack's doc says `deny` "cancels the action". So a denied dialog should
  send no click: no phase 1 and no inbox line. This was not probed live.
