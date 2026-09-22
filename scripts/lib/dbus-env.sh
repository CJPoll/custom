# shellcheck shell=bash
# scripts/lib/dbus-env.sh — shared D-Bus environment setup for cron wrappers.
#
# THE PROBLEM this closes (measured 2026-09-22 on home-office-linux):
# ~109 orphaned `dbus-daemon --syslog-only --fork ... --session` daemons
# accumulated (~1/hour) and exhausted the per-user inotify instance limit
# (127/128), turning fleet gates red and threatening the inbox doorbell
# (inbox-wait) and the channel attendant.
#
# ROOT CAUSE: a cron-launched process runs with NO `DBUS_SESSION_BUS_ADDRESS`
# (the crontab has none), yet a graphical `DISPLAY=:0` leaks in through the
# login-shell snapshot that Claude Code's Bash tool sources (dotfiles/.zshrc
# exports DISPLAY=:0, never DBUS_SESSION_BUS_ADDRESS). When any libdbus/GLib
# client then runs (e.g. `dunstify` in the notify-idle Stop hook) with an
# X11-reachable DISPLAY but no live/reachable session bus, libdbus AUTOLAUNCHES
# one via `dbus-launch --autolaunch`, which forks `dbus-daemon --syslog-only
# --fork ... --session`. Being `--fork`, it daemonises (reparents to PID 1) and
# never exits — one leaked bus per trigger, forever. Reproduced locally: a
# `dunstify` run with `DISPLAY=:0` and no `DBUS_SESSION_BUS_ADDRESS`, when the
# cached bus is dead, spawns exactly that daemon; setting the variable to any
# value stops libdbus from ever calling dbus-launch.
#
# THE FIX: before launching `claude`, export a `DBUS_SESSION_BUS_ADDRESS` so no
# descendant ever autolaunches. Autolaunch fires ONLY when the variable is
# unset, so any set value disables it. We prefer a REAL, reachable bus
# (so notifications still work when a live session exists) discovered at
# runtime — never a hardcoded /tmp/dbus-* path, which changes across reboots —
# and fall back to an unconnectable sentinel that SUPPRESSES autolaunch (a
# headless cron run does not need desktop notifications; a client just fails
# fast and gracefully instead of forking an orphan).
#
# Contract: `athena_dbus_env_setup` is idempotent, never blocks, never wedges,
# never overrides a value the caller set deliberately, and always leaves
# DBUS_SESSION_BUS_ADDRESS exported to a non-empty value. Safe under
# `set -euo pipefail`.

# Discover a live session bus from one of our OWN running processes' environ.
# Read-only, bounded, non-blocking. Prints a reachable `unix:path=` address on
# stdout, or nothing. Never fails (returns 0) so it is safe under `set -e`.
_athena_dbus_discover() {
  local duid="${1:-}" p owner a sp
  [ -n "${duid}" ] || return 0
  for p in /proc/[0-9]*; do
    [ -d "${p}" ] || continue
    [ -r "${p}/environ" ] || continue
    owner="$(stat -c %u "${p}" 2>/dev/null)" || continue
    [ "${owner}" = "${duid}" ] || continue
    a="$(tr '\0' '\n' < "${p}/environ" 2>/dev/null | grep -m1 '^DBUS_SESSION_BUS_ADDRESS=' || true)"
    [ -n "${a}" ] || continue
    a="${a#DBUS_SESSION_BUS_ADDRESS=}"
    case "${a}" in
      *unix:path=*)
        sp="${a#*unix:path=}"
        sp="${sp%%,*}"
        # Only accept an address whose socket actually exists (is reachable);
        # this also rejects another wrapper's suppression sentinel, whose path
        # is never a socket.
        if [ -S "${sp}" ]; then
          printf '%s' "${a}"
          return 0
        fi
        ;;
    esac
  done
  return 0
}

# Export DBUS_SESSION_BUS_ADDRESS so no descendant process autolaunches a
# throwaway session bus. Idempotent; safe to call more than once.
athena_dbus_env_setup() {
  # A value already set (by the caller, the login shell, or a real session) is
  # a deliberate choice — never override it. It also already disables autolaunch.
  if [ -n "${DBUS_SESSION_BUS_ADDRESS:-}" ]; then
    return 0
  fi

  local uid xdg addr
  uid="$(id -u 2>/dev/null || printf '%s' "${UID:-}")"
  xdg="${XDG_RUNTIME_DIR:-/run/user/${uid}}"

  # 1. systemd/elogind-style user bus socket, the modern standard location.
  if [ -n "${uid}" ] && [ -S "${xdg}/bus" ]; then
    export DBUS_SESSION_BUS_ADDRESS="unix:path=${xdg}/bus"
    return 0
  fi

  # 2. A live session bus discovered from our own processes (robust across
  #    reboots — read from a running process, never a stale cache/tmp path).
  addr="$(_athena_dbus_discover "${uid}")"
  if [ -n "${addr}" ]; then
    export DBUS_SESSION_BUS_ADDRESS="${addr}"
    return 0
  fi

  # 3. No reachable session bus (e.g. @reboot before any login). SUPPRESS
  #    autolaunch with an unconnectable sentinel. The value only needs to be
  #    non-empty and not a live socket; a dbus client then fails fast instead
  #    of forking an orphan daemon.
  export DBUS_SESSION_BUS_ADDRESS="unix:path=${xdg}/athena-no-session-bus"
  return 0
}
