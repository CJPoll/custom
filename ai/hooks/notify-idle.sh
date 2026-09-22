#!/usr/bin/env bash
# Claude Code "Stop" hook — sends a persistent dunst notification
# when an agent goes idle, showing project and worktree info.
#
# It ALSO writes the Athena attendant's per-session turn-end marker (T4/DND-285):
# when this session was launched by the standing channel supervisor
# (scripts/athena-channel-session.sh sets ATHENA_ATTEND_STATE_DIR in the env),
# the Stop firing means the turn has fully ended — text can follow ack_wake, so
# the ack alone is not proof the turn ended, but this marker written AFTER it is.
# The supervisor's rotation gate requires idle.<session_id> to be NEWER than
# ack.<session_id> before it may rotate, so a rotation never cuts a reply. This
# runs for EVERY session but only writes the marker for an attend session; all
# other sessions just get the dunst notification.

set -euo pipefail

# ---- Athena attendant per-session idle marker (additive; guarded) ----------
# Read the hook's stdin JSON once (Claude Code passes it; may be empty). Only an
# attend session (ATHENA_ATTEND_STATE_DIR set) writes a marker.
hook_input=""
if [ ! -t 0 ]; then hook_input="$(cat 2>/dev/null || true)"; fi

if [ -n "${ATHENA_ATTEND_STATE_DIR:-}" ]; then
  # Key the marker on ATHENA_ATTEND_SESSION_ID FIRST -- that is the exact
  # --session-id UUID the launcher generated, wrote to session.id (what the
  # rotation gate reads), and ack_wake keyed its receipt on. Anchoring to that
  # single source makes ack.<sid>, idle.<sid>, and the gate agree BY
  # CONSTRUCTION ("validate both sides of the comparison"); trusting the Stop
  # payload's .session_id first would silently divert the marker to idle.<other>
  # (and bound-rotation would never fire) if Claude Code ever reported an id
  # that differs from the flag. The stdin .session_id is only a fallback for a
  # session launched without the env var.
  sid="${ATHENA_ATTEND_SESSION_ID:-}"
  if [ -z "${sid}" ] && command -v jq >/dev/null 2>&1 && [ -n "${hook_input}" ]; then
    sid="$(printf '%s' "${hook_input}" | jq -r '.session_id // empty' 2>/dev/null || true)"
  fi
  if [ -n "${sid}" ]; then
    mkdir -p -- "${ATHENA_ATTEND_STATE_DIR}" 2>/dev/null || true
    # touch: its MTIME (now) is what the rotation gate compares against the ack's.
    : > "${ATHENA_ATTEND_STATE_DIR}/idle.${sid}" 2>/dev/null || true
  fi
fi

# ---- dunst idle notification (unchanged behaviour) -------------------------
cwd="$(pwd)"
home="$HOME"

# Derive project and worktree from the working directory.
#   ~/dev/<project>                             → project=<project>, worktree=main checkout
#   ~/.local/worktrees/<project>/<branch>       → project=<project>, worktree=<branch>
project=""
worktree=""

worktree_prefix="${home}/.local/worktrees/"
dev_prefix="${home}/dev/"

if [[ "$cwd" == "${worktree_prefix}"* ]]; then
  # Strip the prefix: <project>/<branch...>
  # Branch names can contain slashes, so worktree is everything after project.
  relative="${cwd#"$worktree_prefix"}"
  project="${relative%%/*}"
  worktree="${relative#*/}"
elif [[ "$cwd" == "${dev_prefix}"* ]]; then
  relative="${cwd#"$dev_prefix"}"
  project="${relative%%/*}"
  worktree="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "main")"
else
  # Fallback: use directory name and git branch
  project="$(basename "$(git rev-parse --show-toplevel 2>/dev/null || echo "$cwd")")"
  worktree="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")"
fi

# dunstify is a libnotify/D-Bus client. When this hook runs with a graphical
# DISPLAY (e.g. leaked from the login-shell snapshot Claude Code's Bash tool
# sources) but no DBUS_SESSION_BUS_ADDRESS (a cron-launched session), libdbus
# AUTOLAUNCHES a throwaway `dbus-daemon --syslog-only --fork ... --session` that
# never exits — the leak that exhausted the inotify instance limit. Setting the
# address (to a real session bus if one is discoverable, else an unconnectable
# sentinel) stops the autolaunch: with a real bus the notification still
# reaches the user; otherwise dunstify just fails fast (guarded below). See
# scripts/lib/dbus-env.sh.
__notify_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")" && pwd -P)"
if [ -r "${__notify_dir}/../../scripts/lib/dbus-env.sh" ]; then
  # shellcheck source=../../scripts/lib/dbus-env.sh
  . "${__notify_dir}/../../scripts/lib/dbus-env.sh"
  athena_dbus_env_setup || true
fi

# The attendant runs headless in tmux with no display, where dunstify fails; the
# notification is best-effort and must never fail the hook (which would surface
# an error on every attended turn), so it is guarded.
dunstify \
  -u critical \
  -a "Claude Code" \
  -i "dialog-information" \
  "Claude Code — Idle" \
  "Project: ${project}\nWorktree: ${worktree}" 2>/dev/null || true
