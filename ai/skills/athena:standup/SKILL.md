---
name: athena:standup
description: Post Cody's daily standup to Slack as the Athena bot. Find today's "Daily Standup Agent" thread in the standup channel, answer the four questions from what shipped since 9AM MT of the last business day, list what's queued for today, flag any In-Progress work that should move back to Todo/Backlog, and reply in-thread as Athena (never as Cody). Use whenever asked to do/post/thread the standup.
---

# athena:standup

Post Cody's daily standup as Athena's own bot, threaded under the day's Daily
Standup Agent prompt. Athena does the work on Cody's behalf, so this is *Cody's*
standup, reported by Athena — matching the team convention (Margie posts
"*Tom's standup* (via Margie)").

## Post AS Athena, never as Cody

Use the **`athena:slack`** bot scripts (Athena's own `xoxb-` token) — NOT the
`claude.ai Slack` MCP plugin, which posts under Cody's OAuth (his name on
Athena's words) and is frequently 404-down. See [[athena:slack]].

- Scripts: `~/.claude/skills/athena:slack/bin/…` (`whoami`, `read-channel`, `reply`).
- If anything is confusing, run `bin/whoami` first — expect user `athena`,
  `U0BU75F8EUR`, team Amby AI. If it shows Cody, stop: you're on the wrong path.

## 1. Find today's standup thread

- **Channel:** `C074G1DDUV8` (the standup channel).
- The daily prompt is posted by **"Daily Standup Agent"** and contains the four
  questions plus a trailing "Also: did you start any work that should be moved
  back to Backlog or Todo?".
- Read recent history and take the **latest** such prompt whose thread Athena
  has not already replied to:
  ```sh
  ~/.claude/skills/athena:slack/bin/read-channel C074G1DDUV8 --limit 15
  ```
  Use that message's `ts` as the parent `thread_ts`. (A Slack URL ending
  `p1788531151081349` → ts `1788531151.081349` — insert the decimal point six
  digits from the end.)
- **Reply in that thread.** Never post a new top-level message.

## 2. Reporting window: yesterday 9AM MT → today 8:59AM MT

The window is bounded on **both** ends: from **09:00 America/Denver of the last
business day** (weekends roll back to Friday) through **08:59:59 America/Denver
of today**. Both bounds matter — without the upper bound a run at 3PM would sweep
in this afternoon's work and report it as yesterday's.

Compute both UTC bounds with the skill's own script (never inline `date` — the
naive `TZ=America/Denver date -d "…09:00" -u` idiom is silently six hours wrong,
because `-u` parses the string in UTC; the script embeds `TZ` in the `-d` string
and is DST-correct, MDT vs MST):

```sh
WIN="$(~/.claude/skills/athena:standup/scripts/standup-window.sh)"
CUTOFF=$(printf '%s\n' "$WIN"  | sed -n 's/^CUTOFF=//p')   # e.g. 2026-09-21T15:00:00Z
CEILING=$(printf '%s\n' "$WIN" | sed -n 's/^CEILING=//p')  # e.g. 2026-09-22T14:59:59Z
echo "$CUTOFF .. $CEILING"
```

The window computation is self-tested (`test/self-test.sh` pins the expected
UTC bounds for an MDT and an MST date); do not hand-roll the formula.

## 3. Gather the content — Cody/Athena ONLY

Scope strictly to Athena/Cody work. Other people's MRs (`tom888`/`johnnyt1`/
`david1816`/`erich…`) are theirs, not this standup's.

- **Q1 — accomplished:** MRs **merged** in the window authored by Athena or Cody,
  plus prod deploys and any ADRs. From `backend/`:
  ```sh
  glab api --paginate \
    "projects/amby_ai%2Fwalt_ui/merge_requests?state=merged&order_by=updated_at&sort=desc&updated_after=$CUTOFF&per_page=50" \
    | jq -r --arg lo "$CUTOFF" --arg hi "$CEILING" \
        '.[] | select(.merged_at >= $lo and .merged_at <= $hi)
             | select(.author.username=="athena-amby" or .author.username=="cody")
             | [.iid, .merged_at, .title] | @tsv'
  ```
  Filter on **both** bounds: `merged_at` in `[$CUTOFF, $CEILING]`. An MR merged
  after `$CEILING` (this morning) belongs to *today's* window, not this one.
  Group by theme/epic/lane; cite `!MR` and `PT-###` inline. Note which reached
  prod HEALTHY.
- **Q2 — today:** In-Progress + next-queued work. Query the Notion Tickets DB
  (data source `305c55b5-3ca5-4087-8b12-852007d38182`) for Athena's
  `Status = In Progress`, and read the athena-admiral ledgers for what's queued:
  `~/dev/custom/ai-artifacts/coordination/*/state.md`.
- **Q3 — blockers:** anything blocked, awaiting a Cody decision, or an infra
  issue (a deploy hang, a down integration). Be honest; "none hard" is a fine
  answer when true.
- **Q4 — anything else:** decisions that need Cody's call, notable
  findings/risks (e.g. an authz footgun found + fixed).
- **The "Also:" backlog self-check:** find Athena tickets marked `In Progress`
  that are not actually under a live engineer (queued-but-flagged) and move them
  back to `Todo`. Report what moved, or "nothing to revert." (This is Cody's
  internal check — keep it out of the public thread body unless it's material.)

## 4. Format and post

- Slack `mrkdwn`: `*bold*` section headers, `•` bullets, `` `code` `` for
  identifiers/paths, `_italic_` for ticket-number lists.
- **Lead line:** `*Cody's standup* (via Athena)` then the four `*Question?*`
  sections. One bullet per theme; cite MR/PT numbers inline. Keep it scannable.
- Write the body to a scratch file and pipe it in via stdin (keeps it out of
  argv, dodges quoting):
  ```sh
  ~/.claude/skills/athena:slack/bin/reply C074G1DDUV8 <thread_ts> < /path/to/standup.txt
  ```
- The script prints the resulting `ts` + permalink. Report the permalink to Cody.

## Gotchas

- If `bin/reply` errors `not_in_channel`, the athena bot needs inviting to
  `C074G1DDUV8` — surface that to Cody; do NOT fall back to the MCP (that posts
  as Cody).
- Don't hardcode a `thread_ts` — the prompt is a new message each day; always
  re-read the channel to find the current one.
- If the reporting window spans a deploy still in flight, say so ("deploy in
  flight") rather than claiming HEALTHY before the watcher verdict.
