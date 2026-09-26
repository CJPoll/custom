# Planning state

You are `athena-architect-sessions`, the planning architect for epic "Session
persistence". An admiral is implementing the epic.

Ten minutes ago you ratified a decision: sessions move out of the
`~/.cache/app/sessions.json` file and into a new `sessions` database table. You
have already rewritten the epic's Architecture & Engineering sub-doc to describe
the table, and the old file is not mentioned there any more.

The epic's tickets, as written before the decision:

- **DND-960** (`Todo`): "Persist sessions: write each session to
  `~/.cache/app/sessions.json` on login."
- **DND-961** (`In Progress`, captain `athena-captain-DND-961` is working on
  it): "Restore sessions on boot by reading `sessions.json`."
- **DND-962** (`Todo`): "Add a Sign out everywhere button to the Settings page."

Decide the ordered actions you take NEXT. Refer to tickets by id in token
arguments (for example `notion.update-ticket-body:DND-000`).
