# Header block

Slack doc: <https://docs.slack.dev/reference/block-kit/blocks/header-block>
(verified 2026-09-24). Surfaces: messages, modals, Home tabs.

A larger, bold line of plain text. A title, not a sentence.

## Structure

```json
{"type": "header", "text": {"type": "plain_text", "text": "Deploy approval"}}
```

| Field | Required | Notes |
|---|---|---|
| `type` | yes | always `header` |
| `text` | yes | a **`plain_text`** [text object](../composition-objects/text.md) only |
| `block_id` | no | see limits |
| `level` | no | integer `1` to `4`, heading level H1 to H4 |

## Limits

- `text`: at most **150** characters, and `plain_text` only.
  `blocks.validate` rejects `mrkdwn` (`must be a valid enum value`) and 151
  characters (`max_length`), both probed 2026-09-24.
- `block_id`: at most 255 characters, unique per message and per revision.

## In Athena

- Optional. A one-line question needs no header; the section text is enough.
- `mrkdwn` does not work here, so no bold, links or mentions in a header.
