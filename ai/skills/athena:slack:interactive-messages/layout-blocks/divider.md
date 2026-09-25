# Divider block

Slack doc: <https://docs.slack.dev/reference/block-kit/blocks/divider-block>
(verified 2026-09-25). Surfaces: messages, modals, Home tabs.

A horizontal rule.

## Structure

```json
{"type": "divider"}
```

| Field | Required | Notes |
|---|---|---|
| `type` | yes | always `divider` |
| `block_id` | no | at most 255 characters, unique per message and per revision |

## In Athena

- Use it to separate the question from long supporting detail. A short
  question with buttons needs none.
