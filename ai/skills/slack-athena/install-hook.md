# Installing the slack-athena polling hook

These scripts do not edit `~/.claude/settings.json`. Add the block below
yourself.

## The block

`hooks.UserPromptSubmit` is an array of matcher groups. If you already have one
(the agent-messages poll lives there), **add this hook to the existing group's
`hooks` array** rather than adding a second group.

```json
{
  "hooks": {
    "UserPromptSubmit": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "$HOME/.claude/skills/slack-athena/hooks/slack-athena-poll.sh"
          }
        ]
      }
    ]
  }
}
```

`~/.claude/skills` is a symlink to `~/dev/custom/ai/skills`, so that path
resolves for every project and every worktree, and there is one hook for the
machine rather than one per checkout.

## Check it

```sh
# 1. The token is readable and is a bot token.
~/.claude/skills/slack-athena/bin/whoami

# 2. The hook runs clean and says nothing when there is nothing to say.
sh ~/.claude/skills/slack-athena/hooks/slack-athena-poll.sh; echo "rc=$?"

# 3. Force the next run to actually poll (the marker is a 5-minute rate limit).
rm -f ~/.claude/slack-athena-last-poll
```

Expect **no output and `rc=0`** from step 2 in the normal case. That is the
design: the hook is silent unless something is waiting for Athena. To see it
speak, have someone DM the bot, then remove the marker and run it again.

## When it is silent and should not be

Failures are silent by design — a hook that interrupts a turn to complain about
itself is worse than one that is quietly off — but every reason is logged:

```sh
tail ~/.claude/slack-athena-poll.log
```

State it keeps, all safe to delete:

| Path | Question it answers |
|---|---|
| `~/.claude/slack-athena-last-poll` | when did it last **attempt**? (the 5-minute limit) |
| `~/.claude/slack-athena-last-success` | when did it last **succeed**? (is the silence healthy?) |
| `~/.claude/slack-athena-last-warn` | when did it last **say** so? (rate limit on the warning) |
| `~/.cache/slack-athena/inbox-state.json` | last-seen ts per conversation |

Merging any two of the first three breaks one of the three answers.

Deleting `inbox-state.json` does **not** replay the backlog: a conversation with
no entry is treated as first sight, which records where it is and reports
nothing. That is deliberate — the alternative is announcing every DM in the
workspace at once.

## Removing it

Delete the entry from `settings.json`. Nothing else runs on a timer; the
scripts are inert until called.
