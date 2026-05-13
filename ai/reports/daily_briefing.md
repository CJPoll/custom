# Daily Briefing

Generate a daily status briefing for Cody Poll covering work completed
since 6:00 AM the previous business day through now, plus today's
schedule.

On Mondays, the window starts at 6:00 AM Friday. Include any work
accomplished over the weekend (Saturday and Sunday) as well.

## Data Sources

- **GitLab**: All repos under `https://gitlab.com/amby_ai/`
- **Linear**: Tickets and projects
- **Notion**: "Tasks Tracker" database
- **Google Calendar**: Events for today

## Data Collection

### GitLab MRs

Find all GitLab MRs that Cody Poll authored or updated since 6:00 AM
the previous business day through now (and weekend, if today is Monday).
Include both merged/closed and still-open MRs.

Do NOT search for MRs that Cody reviewed. Automated reviews use Cody's
credentials, which would introduce significant noise.

### Linear Tickets

For each MR, check if a corresponding Linear ticket exists. If the MR
branch name matches the pattern `[Pp]-[0-9]+`, the branch was likely named
after a pre-existing Linear ticket. When a matching ticket is found:
- Verify the owner is correct (Cody Poll)
- Verify the status matches the MR state:
  - Merged MR -> Done
  - Open MR -> In Progress
- Ensure the ticket has a meaningful description (not empty or placeholder)

If no Linear ticket exists for an MR, create one with appropriate status,
owner, and description.

Also collect any other open Linear tickets assigned to Cody that are not in
a backlog status, as well as any tickets completed since 6:00 AM the
previous business day through now.

### Notion Tasks

Query the "Tasks Tracker" database for:
- Tasks completed since 6:00 AM the previous business day through now
  (and weekend if Monday)
- Tasks with a due date on the previous business day that are not complete
- Tasks with a due date of today

For completion dates: if "Completed At" has a date, use that. If it is
blank but the status is Done, use the Due Date as the completion date.

### Google Calendar

List events for today. Exclude:
- Standup meetings
- "Reminder to Discuss Bugs" events
- Any "discuss X in standup" style events

---

## Output Destination

Create a new entry in the Notion "Morning Briefs Hub" database. Use the
title format: `Morning Brief DD/MM/YYYY` where the date is today.

Place the full report in the entry's body. Write a separate concise TL;DR
(2-4 bullet points covering the most important items) and put it in the
entry's "tl;dr" field.

---

## Report Format

Output the report using the following structure.

### Section 1: Previous Day (Completed)

Header: `MM/DD/YYYY (Completed)` using the previous business day's date.
On Mondays, if there is weekend work, use `MM/DD – MM/DD/YYYY (Completed)`
spanning Friday through Sunday. If work was completed early today (between
midnight and now), include it in this section with a note that it was
completed today.

Group completed work across all three systems. Related items from Notion,
Linear, and GitLab should be combined into a single entry. Not every entry
will have all three links — only include links that actually exist.

For each group:
1. Summarize the work in 1-2 sentences.
2. List links to the relevant Notion task, Linear ticket, and/or GitLab MR.

Format:

```
MM/DD/YYYY (Completed)

Task: <Short Task Name>
Description: <1-2 sentence summary>
Links:
- :notion: [Notion Task Title](<notion url>)
- :linear: [Linear Ticket Title](<linear url>)
- :gitlab: [GitLab MR Title](<mr url>)
```

### Section 2: Previous Day (Incomplete)

Header: `MM/DD/YYYY (Incomplete)` using the same date logic as Section 1.

Collect:
1. Open MRs authored by Cody that were created or updated since 6:00 AM
   the previous business day, summarized in 1-2 sentences each.
2. Notion tasks with a due date on the previous business day that are not
   complete.
3. Open Linear tickets assigned to Cody (exclude backlog status).

Group related items from all three systems, same as Section 1. Use the
same format as completed tasks.

### Section 3: Today

#### Important Calls

List Google Calendar events for today (excluding standups, "Reminder to
Discuss Bugs" events, and "discuss X in standup" events). Include time
and event title.

#### Notion Tasks

List Notion tasks with a due date of today, sorted by priority (highest
first). Include task name and priority level.

#### Linear Tickets

List Linear tickets that are assigned to Cody. EXCLUDE: Backlog, Done. Group by
status.
