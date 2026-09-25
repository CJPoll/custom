# Section block

Slack doc: <https://docs.slack.dev/reference/block-kit/blocks/section-block>
(verified 2026-09-25). Surfaces: messages, modals, Home tabs.

Displays text, optionally beside one element. The body of most questions.

## Structure

```json
{
  "type": "section",
  "text": {"type": "mrkdwn", "text": "Merge PR #42 now?"},
  "fields": [
    {"type": "mrkdwn", "text": "*Gate*\ngreen"},
    {"type": "mrkdwn", "text": "*Critic*\nPASS"}
  ],
  "accessory": {"type": "button", "text": {"type": "plain_text", "text": "Open"}, "value": "open"}
}
```

| Field | Required | Notes |
|---|---|---|
| `type` | yes | always `section` |
| `text` | preferred | a [text object](../composition-objects/text.md); required unless `fields` is given |
| `fields` | if no `text` | text objects, rendered two columns side by side |
| `accessory` | no | one compatible element |
| `block_id` | no | see limits |
| `expand` | no | `true` always shows the full text, no "see more" |

## Limits

- `text`: 1 to 3,000 characters.
- `fields`: at most 10 items, each at most 2,000 characters.
- `block_id`: at most 255 characters, unique per message and per revision.
- Give `text` or `fields`. `blocks.validate` accepted a section with neither on
  2026-09-25, so the docs are the only guard here.

## In Athena

- The accessory list Slack allows includes selects, overflow, checkboxes,
  radios and pickers. **Only `button`** survives the athena MCP; see
  [not-supported-phase-1.md](../not-supported-phase-1.md). An `image`
  accessory is display-only and fine.
- Put the question in `text`, as a few short lines (athena:slack → *Slack
  writing style*). Use `fields` for two or four short facts, not for prose.
