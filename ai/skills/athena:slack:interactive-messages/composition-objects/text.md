# Text object

Slack doc:
<https://docs.slack.dev/reference/block-kit/composition-objects/text-object>
(verified 2026-09-25).

Every piece of text inside a block or element.

## Structure

```json
{"type": "mrkdwn", "text": "Merge *PR #42* now?"}
```

```json
{"type": "plain_text", "text": "Approve", "emoji": true}
```

| Field | Required | Notes |
|---|---|---|
| `type` | yes | `plain_text` or `mrkdwn` |
| `text` | yes | 1 to 3,000 characters by default; the containing field may set a lower cap |
| `emoji` | no | `plain_text` only: escape emoji into `:colon:` form |
| `verbatim` | no | `mrkdwn` only: `true` stops auto-linking of URLs, channel names and mentions |

## Limits

- `text`: 1 to 3,000 characters here. The field that holds the object often
  caps it lower. Examples: a header's text at 150, a button's at 75, a section
  `fields` item at 2,000, a confirmation dialog's title at 100.
- Some fields take **`plain_text` only**: a header's `text`, a button's
  `text`, and the confirmation dialog's `title`, `confirm` and `deny`.

## In Athena

- `mrkdwn` is Slack's own markup, not Markdown: `*bold*`, `_italic_`,
  `<https://x|label>` links, `<@U…>` mentions. Formatting reference:
  <https://docs.slack.dev/messaging/formatting-message-text>.
- The top-level `text` of the message is a plain string beside `blocks`, not a
  text object. It is still required (see [SKILL.md](../SKILL.md)).
