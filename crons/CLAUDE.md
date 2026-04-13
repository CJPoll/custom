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
