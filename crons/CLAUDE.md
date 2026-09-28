# Cron Jobs

## System

- **Daemon**: cronie
- **Init**: OpenRC
- **Drop-in directory**: `/etc/cron.d/`

## Installation

Cron files use the `/etc/cron.d/` system format (with a user field). cronie
requires drop-in files in `/etc/cron.d/` to be owned by root and not
group/world-writable.

To install a cron file, copy it into `/etc/cron.d/` (requires root; this is an
owner step, never an agent's):

```bash
sudo cp <path>/<name>.cron /etc/cron.d/<name>
```

After editing a cron file, re-copy it to apply changes. `/etc/cron.d` holds
copies, not symlinks, so an edit here does nothing until it is re-copied.

## Work report jobs live in the private overlay

The daily briefing and weekly report are work-domain jobs. Their prompts and
cron templates live in the private work overlay (default
`~/.config/athena/work`, contract `ai/contracts/athena-private-overlay.md`),
not in this public repo:

| Overlay path | Installed to | Schedule |
|------|-------------|----------|
| `crons/daily_briefing.cron` | `/etc/cron.d/daily_briefing` | Mon–Fri 6:00 AM |
| `crons/weekly_report.cron` | `/etc/cron.d/weekly_report` | Mon 6:00 AM |

Each job reads its prompt from the overlay's `prompts/<job>.md`. Its job line
refuses to run when that file is missing, not a readable file, or empty: it
exits 1 and logs the path with `logger -t athena-cron`
(`grep athena-cron` in the system log). The overlay's
`crons/test/guard-test.sh` proves that with stub `claude` and `logger`.

Owner install, after an edit in the overlay. `cp` onto an existing file keeps
that file's root owner and 0644 mode. For a first install, add
`sudo chmod 0644 /etc/cron.d/<job>`, because the overlay copy is 0600 and the
read-only `diff` below then needs root.

```bash
sudo cp /home/cjpoll/.config/athena/work/crons/daily_briefing.cron /etc/cron.d/daily_briefing
sudo cp /home/cjpoll/.config/athena/work/crons/weekly_report.cron /etc/cron.d/weekly_report
# read-only verify: both diffs print nothing
diff /home/cjpoll/.config/athena/work/crons/daily_briefing.cron /etc/cron.d/daily_briefing
diff /home/cjpoll/.config/athena/work/crons/weekly_report.cron /etc/cron.d/weekly_report
```

## Jobs in this directory

| File | Installed To | Schedule | Description |
|------|-------------|----------|-------------|
| `experiment.cron` | not installed | disabled (job line commented out) | Free agent experiment recording findings in "Agents with Agency" knowledge graph |
