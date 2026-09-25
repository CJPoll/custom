# Not supported in phase 1: selects, overflow, inputs

The athena MCP routes only **button** clicks back to a session. Every other
interactive element is **refused server-side**, by type, before any Slack call
(DND-241, DND-290). A refused post sends nothing.

## Why

The server stamps a signed return address into each interactive element's
`value`, and the click comes back to the inbox that address names.

- **Option values are too short.** Slack caps an option `value` at 150
  characters (option object:
  <https://docs.slack.dev/reference/block-kit/composition-objects/option-object>),
  and the stamp alone is longer.
- **Inputs, pickers and user or channel selects return no author-set value**,
  so there is nothing to stamp.

An unstamped control cannot be routed, so the server refuses it rather than
send a control whose click would go nowhere.

## Refused elements

Slack's taxonomy, block elements
(<https://docs.slack.dev/reference/block-kit/block-elements>):

- select menus, every variant: `static_select`, `external_select`,
  `users_select`, `conversations_select`, `channels_select`, and the
  `multi_*` forms;
- `overflow`;
- `checkboxes` and `radio_buttons`;
- `datepicker`, `timepicker`, `datetimepicker`;
- every input element: `plain_text_input`, `number_input`,
  `email_text_input`, `url_text_input`, `file_input`, `rich_text_input`;
- `workflow_button`, feedback buttons and icon buttons.

The server does not route modals, `view_submission`, or payloads with more
than one action either.

The non-interactive elements pass through: `image`, text objects, and a
`rich_text` block's section, list, quote and preformatted elements.

## What to do instead

- **A choice among a few options:** one button per option in an `actions`
  block (at most 25, and in practice two to four).
- **A free-form answer:** ask in plain text and read the reply (athena:slack →
  *Block Kit is the default for asking a person*: it is a default, not a
  mandate).
- **A date or a number:** offer the likely values as buttons, or ask in plain
  text.

Phase-2 support (modals, selects) is a proposed follow-up on gen_saas, not
something to work around here.
