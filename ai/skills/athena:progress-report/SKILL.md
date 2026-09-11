---
name: athena:progress-report
description: Give a progress report of work that has been assigned to
athena-admirals.
---

For each athena-admiral, give a progress report of its progress.

Format accordingly:

1. Name of athena-admiral
2. 1-3 sentence description of its scope of work
3. Table of Tickets

Tickets might represent actual tickets (in the case of a system like linear,
jira, notion tickets db, etc.) or just a set of tasks (like if they were made
using the `/ralph:plan` skill). The table of tickets should include the
following:

1. Ticket ID, if any (e.g. PT-153)
2. Ticket Name
3. 1-3 sentence summary of ticket goal
4. Status (In flight, Complete, Queued, Blocked)
5. If blocked, a 1-3 sentence description of the blocker
