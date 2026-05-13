# Weekly Report

Generate a weekly status report for Cody Poll covering the previous week
and the current week. Treat Monday as the first day of the week.

## Data Sources

- **GitLab**: All repos under `https://gitlab.com/amby_ai/`
- **Linear**: Tickets and projects
- **Notion**: "Tasks Tracker" database
- **Google Calendar**: Events for the current week

## Data Collection

### GitLab MRs

Find all GitLab MRs that Cody Poll authored during the previous week
(Monday through Sunday). Include both merged/closed and still-open MRs.

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
a backlog status.

### Notion Tasks

Query the "Tasks Tracker" database for:
- Tasks completed during the previous week
- Tasks with a due date in the previous week that are not complete
- Tasks with a due date in the current week

For completion dates: if "Completed At" has a date, use that. If it is
blank but the status is Done, use the Due Date as the completion date.

### Google Calendar

List events for the current week. Exclude:
- Standup meetings
- "Reminder to Discuss Bugs" events

---

## Output Destination

Create a new entry in the Notion "Morning Briefs Hub" database. Use the
title format: `Weekly Brief DD/MM/YYYY` where the date is the Monday of
the current week.

Place Sections 1-3 in the entry's body. Write a separate concise TL;DR
(3-5 bullet points covering the most important items across all sections)
and put it in the entry's "tl;dr" field.

Section 4 (Team Progress Report) should be created as a nested page inside
the weekly brief entry, titled `Team Progress Report DD/MM/YYYY`.

IFF the report is successfully created in Notion, send a link to the Team
Progress Report in Slack to Mike Peregrina.

---

## Report Format

Output the report using the following structure.

### Section 1: Previous Week (Completed)

Header: `Week of MM/DD/YYYY (Completed Tasks)` using the Monday of the
previous week.

Group completed work across all three systems. Related items from Notion,
Linear, and GitLab should be combined into a single entry. Not every entry
will have all three links - only include links that actually exist.

For each group:
1. Summarize the work in 1-2 sentences.
2. List links to the relevant Notion task, Linear ticket, and/or GitLab MR.

Format:

```
Week of MM/DD/YYYY (Completed Tasks)

Task: <Short Task Name>
Description: <1-2 sentence summary>
Links:
- :notion: [Notion Task Title](<notion url>)
- :linear: [Linear Ticket Title](<linear url>)
- :gitlab: [GitLab MR Title](<mr url>)

Task: <Short Task Name>
Description: <1-2 sentence summary>
Links:
- :linear: [Linear Ticket Title](<linear url>)
- :gitlab: [GitLab MR Title](<mr url>)
```

### Section 2: Previous Week (Incomplete)

Header: `Week of MM/DD/YYYY (Incomplete Tasks)` using the Monday of the
previous week.

Collect:
1. Open MRs authored by Cody, summarized in 1-2 sentences each.
2. Notion tasks with a due date in the previous week that are not complete.
3. Open Linear tickets assigned to Cody (exclude backlog status).

Group related items from all three systems, same as Section 1. Use the
same format as completed tasks.

### Section 3: Current Week

#### Important Calls

List Google Calendar events for the current week (excluding standups and
"Reminder to Discuss Bugs" events). Include date, time, and event title.

#### Notion Tasks

List Notion tasks with a due date in the current week, sorted by priority
(highest priority first). Include task name, due date, and priority level.

### Section 4: Team Progress Report (nested page)

This section is placed in a separate nested page inside the weekly brief
entry (see Output Destination above).

Begin the page with an `## Executive Summary` section (3-8 sentences).
Cover the major themes (e.g. feature work, compliance, bug fixes,
infrastructure), call out notable accomplishments, and note any
in-progress items carrying into the next week.

Formatting rules for the executive summary:
- Use concise, scannable language — no filler.
- Use bullet points or short lists where they improve readability.
- If the summary exceeds 4 sentences, break it into short paragraphs
  grouped by theme rather than writing a single block of text.
- Write in a professional tone suitable for stakeholders who may not
  read the full detail below.

Then list all Linear tickets (across the team, not just Cody) that were
moved into `Ready for Release` or `Done` status during the previous week.

Group these tickets with their corresponding GitLab MRs (all repos are
under the `https://gitlab.com/amby_ai/` GitLab org).

Group by Linear project first. If a ticket has no Linear project, use best
judgment to group it with an existing project. If no existing project fits,
create a sensible ad-hoc grouping.

Format:

```
## Team Progress Report

### <Project Name>

- [Ticket Title](<linear url>) - Done
  - :gitlab: [MR Title](<mr url>)
- [Ticket Title](<linear url>) - Ready for Release

### <Project Name>

- [Ticket Title](<linear url>) - Done
  - :gitlab: [MR Title](<mr url>)
```
