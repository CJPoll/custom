# Installing the athena:slack polling hook

The hook is a **`SessionStart`** hook, declared in `ai/hooks/registry.json` (the
committed source of truth for which hooks are wired) and installed by merging
that registry into `~/.claude/settings.json`:

```sh
scripts/setup-hooks --install   # MERGES; never rewrites the hooks block
scripts/setup-hooks --check     # asserts it is wired (== ai/bin/check-hooks-registered)
```

Do **not** hand-edit `~/.claude/settings.json` — a full rewrite of the hooks
block is what silently dropped two guards on 2026-09-17, which is why the
installer merges. `setup-hooks` wires the command at the **main checkout's**
path (resolved through git's common dir), so it survives a worktree being
cleaned up.

It is on `SessionStart`, not `UserPromptSubmit`: the harness abandoned the
per-prompt cadence on 2026-09-11 (it does not compose with a Monitor loop and
couples a network call to the user typing). Mid-session coverage comes from a
Monitor loop.

## Check it

```sh
# 1. The token is readable and is a bot token.
~/.claude/skills/athena:slack/bin/whoami

# 2. The hook runs clean and says nothing when there is nothing to say.
#    (~/.claude/hooks is a symlink to the repo's ai/hooks/.)
sh ~/.claude/hooks/athena-slack-poll.sh; echo "rc=$?"

# 3. Force the next run to actually poll (the marker is a 5-minute rate limit).
rm -f ~/.claude/athena-slack-last-poll
```

Expect **no output and `rc=0`** from step 2 in the normal case. That is the
design: the hook is silent unless something is waiting for Athena. To see it
speak, have someone DM the bot, then remove the marker and run it again.

## When it is silent and should not be

Failures are silent by design — a hook that interrupts a turn to complain about
itself is worse than one that is quietly off — but every reason is logged:

```sh
tail ~/.claude/athena-slack-poll.log
```

State it keeps, all safe to delete:

| Path | Question it answers |
|---|---|
| `~/.claude/athena-slack-last-poll` | when did it last **attempt**? (the 5-minute limit) |
| `~/.claude/athena-slack-last-success` | when did it last **succeed**? (is the silence healthy?) |
| `~/.claude/athena-slack-last-warn` | when did it last **say** so? (rate limit on the warning) |
| `${ATHENA_INBOX_ROOT:-~/.local/share/athena}/slack-inbox.state.json` | the shared seen-state: per-conversation watermark + the cross-source `seen_keys` |

Merging any two of the first three markers breaks one of the three answers.

The seen-state is **shared with the `athena:inbox` file channel** — one file, so
the two Slack sources cannot double-report each other (`$SLACK_INBOX_STATE`
overrides its path). Deleting it does **not** replay the backlog: a conversation
with no entry is treated as first sight, which records where it is and reports
nothing. That is deliberate — the alternative is announcing every DM in the
workspace at once. A pre-existing `~/.cache/athena-slack/inbox-state.json` is
migrated into it on the first run.

## Removing it

```sh
scripts/setup-hooks --remove
```

Nothing else runs on a timer; the scripts are inert until called.
