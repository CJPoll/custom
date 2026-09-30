# Cron Jobs

## System

- **Daemon**: cronie
- **Init**: OpenRC
- **Drop-in directory**: `/etc/cron.d/`

## Installation

Cron files in this directory use the `/etc/cron.d/` system format (with a
user field). cronie requires drop-in files in `/etc/cron.d/` to be owned
by root and not group/world-writable.

To install a cron file, copy it into `/etc/cron.d/` (requires root):

```bash
sudo cp ~/dev/custom/crons/<name>.cron /etc/cron.d/<name>
```

After editing a cron file, re-copy it to apply changes:

```bash
sudo cp ~/dev/custom/crons/<name>.cron /etc/cron.d/<name>
```

## Installed Cron Jobs

| File | Installed To | Schedule | Description |
|------|-------------|----------|-------------|
| `weekly_report.cron` | `/etc/cron.d/weekly_report` | Mon 6:00 AM | Generates weekly status report in Notion Morning Briefs Hub |
| `daily_briefing.cron` | `/etc/cron.d/daily_briefing` | Mon–Fri 6:00 AM | Generates daily status briefing in Notion Morning Briefs Hub |
| `experiment.cron` | `/etc/cron.d/experiment` | Every 10 min | Free agent experiment recording findings in "Agents with Agency" knowledge graph |

**Later (2026-09-30):** `weekly_report.cron` and `daily_briefing.cron` are
retired. Their files and prompts (`ai/reports/weekly_report.md`,
`ai/reports/daily_briefing.md`) are removed. Owner decision on DND-701 (Cody,
terminal, 2026-09-30 ~15:05Z): "Let's remove them for now". Cody removed
`/etc/cron.d/weekly_report` and `/etc/cron.d/daily_briefing` first, so no
installed job was left reading a missing prompt. To restore one, recover its
files from git history and re-install it as above. `experiment.cron` is not
part of that decision.
