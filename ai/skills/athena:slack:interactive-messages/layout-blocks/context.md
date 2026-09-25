# Context block

Slack doc: <https://docs.slack.dev/reference/block-kit/blocks/context-block>
(verified 2026-09-25). Surfaces: messages, modals, Home tabs.

Small, muted text and images. For metadata, not for the question.

## Structure

```json
{
  "type": "context",
  "elements": [
    {"type": "mrkdwn", "text": "harness session · DND-289 · 2:14 PM MT"}
  ]
}
```

| Field | Required | Notes |
|---|---|---|
| `type` | yes | always `context` |
| `elements` | yes | [text objects](../composition-objects/text.md) and `image` elements |
| `block_id` | no | see limits |

## Limits

- `elements`: at most 10 items.
- `block_id`: at most 255 characters, unique per message and per revision.

## In Athena

- Good for: the sending session, the ticket id, a time in **MT** (athena:slack
  → *The existing Slack rules still apply*).
- The server's own phase-1 `working…` line is a context block. A phase-2
  update replaces it; do not leave it standing.
