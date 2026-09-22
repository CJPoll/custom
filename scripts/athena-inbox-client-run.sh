#!/usr/bin/env bash
#
# athena-inbox-client-run.sh — supervise the Athena inbox client on OpenRC.
#
# This host has no `systemd --user`, so the client's own `--print-service` unit
# does not apply, and an /etc/init.d script is a system-level change that
# belongs to Cody. The supported arrangement is therefore: the user crontab
# launches THIS wrapper (`@reboot` plus a low-cadence relaunch), and the wrapper
# is what keeps the client alive. Install the crontab entries with
# `scripts/setup-athena-inbox-client`.
#
# What it guarantees:
#   * ONE client at a time. An `flock` on the pidfile is held for the whole
#     supervised lifetime; a second invocation finds the lock taken and exits 0
#     without starting anything. This is what makes the `*/5` relaunch entry a
#     no-op while healthy, and it is what stops two writers from ever sharing
#     one inbox (the contract forbids that outright).
#   * The client is started through ~/.local/bin/athena-inbox-client, which
#     pins the ABSOLUTE ruby 3.3.0 path. Never the asdf shim: cron does not
#     source the login shell, so `~/.asdf/shims/ruby` cannot resolve its `asdf
#     exec` launcher — that is the bug `b5073fc fix(shipwright): run cron gate
#     under system ruby, not asdf shim` fixed for the shipwright runner. The
#     asdf default here is 2.7, below the client's MIN_RUBY of 3.2.0.
#   * A non-zero exit is retried with CAPPED EXPONENTIAL BACKOFF, EXCEPT exit 2.
#   * Exit 2 is a FULL STOP. It is the client's deliberate partial-write exit: a
#     write failed after bytes landed, so an inbox file ends in a fragment, and
#     the un-acked event will be re-pushed in full on reconnect. Restarting
#     appends that full line after the fragment and corrupts the inbox. The
#     supervisor writes ~/.local/state/athena-inbox-client.stopped with the
#     reason and never relaunches — including on later cron invocations, which
#     refuse to start while the marker exists. This is exactly what
#     `RestartPreventExitStatus=2` bought in the systemd unit (gen_saas PR #18);
#     a hand-rolled supervisor must not reintroduce the bug.
#     Recovery is manual: fix the disk, delete the trailing fragment, remove the
#     marker, then run this script again.
#
# Output discipline: cron mails ANY output a job produces, so the STEADY-STATE
# paths — supervising, restarting, and the locked-out no-op that the */5 entry
# hits while healthy — write to the log file and say nothing on stdout/stderr.
# When stderr is a terminal (a human running this by hand) the same lines are
# echoed there too.
#
# The exception is deliberate: a missing prerequisite (exit 2 — no launcher, no
# flock, an unusable state dir) DOES write to stderr, so cron mails it. That is
# a fault which never resolves itself and which no log nobody reads will
# surface; a daily mail is the cheapest way for it to reach a human. The
# installer refuses to schedule a missing launcher in the first place, so this
# should only fire when something was removed out from under a working setup.
#
# Usage:
#   athena-inbox-client-run.sh            supervise the client (blocks)
#   athena-inbox-client-run.sh --help     show this help
#
# Environment (all optional; the defaults are the production values):
#   ATHENA_INBOX_CLIENT_LAUNCHER      launcher to run   (~/.local/bin/athena-inbox-client)
#   ATHENA_INBOX_CLIENT_STATE_DIR     state/log/pid dir (~/.local/state)
#   ATHENA_INBOX_CLIENT_MIN_BACKOFF   first retry delay, seconds (5)
#   ATHENA_INBOX_CLIENT_MAX_BACKOFF   backoff cap, seconds (300)
#   ATHENA_INBOX_CLIENT_BACKOFF_RESET a run lasting at least this long resets
#                                     the backoff to MIN, seconds (120)
#   ATHENA_INBOX_CLIENT_MAX_RESTARTS  stop after N restarts; 0 = unlimited (0).
#                                     Exists so the self-test can bound a run.
#   ATHENA_INBOX_CLIENT_MAX_LOG_LINES trim the log to this many lines between
#                                     client runs (2000). See the caveat under
#                                     "Log size" below.
#
# Stopping it: kill the pid in ~/.local/state/athena-inbox-client.pid. SIGTERM
# and SIGINT reap the client and stop the SUPERVISOR — they do not fall back
# into the relaunch loop, or "stop" would mean "restart".
#
# But that stops THIS supervisor, not the service: once the crontab entries are
# installed, the `*/5` line starts a new one within five minutes. The same goes
# for the client exiting 0. To stop the service durably, remove the entries
# first — `scripts/setup-athena-inbox-client --remove` — and then kill the pid.
# (The `.stopped` marker also blocks a start, but it means "an inbox file is
# corrupt"; do not repurpose it as an off switch, or a real partial write later
# becomes indistinguishable from a deliberate stop.)
#
# Log size: the log is trimmed only BETWEEN client runs (the rewrite replaces
# the inode, so trimming under a live client would send its output into an
# unlinked file). A healthy client never exits, so a long-lived deployment does
# not reach the trim and MAX_LOG_LINES does not bound it — the trim bounds a
# crash-looping client, which is the case that actually produces volume. If the
# steady-state log ever needs bounding, rotate it out of band (logrotate with
# copytruncate) rather than trimming from in here.
#
# Exit codes: 0 ok (client exited cleanly, or another instance holds the lock,
#             or the stop marker is present) · 1 usage/arg error
#             · 2 missing prerequisite (no launcher, no flock, unusable state dir)
#             · 130 interrupted (SIGINT) · 143 terminated (SIGTERM)

set -uo pipefail

# cron's PATH is minimal, so pin a known-good one rather than inheriting
# whatever the daemon offers: losing flock(1) would silently defeat the
# single-instance guarantee, the same shape of failure as the asdf-shim bug
# above. Deliberately no asdf shims — the launcher pins its own absolute ruby.
#
# /usr/sbin is listed for portability, not because this box needs it: Gentoo's
# usrmerge makes /usr/sbin a symlink to bin here, so flock resolves through
# /usr/bin either way. That is why the suite's minimal-PATH case cannot be
# reddened by dropping /usr/sbin from this line (SABOTAGE_RECORDS S28a, a
# measured zero) — the pin still matters on a host where the two differ.
export PATH="${HOME}/.local/bin:/usr/local/bin:/usr/bin:/bin:/usr/local/sbin:/usr/sbin:/sbin"
export LANG="${LANG:-C.UTF-8}"
export LC_ALL="${LC_ALL:-C.UTF-8}"

usage() { awk 'NR==1{next} /^#/{sub(/^# ?/,"");print;next} {exit}' "$0"; }

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  "") : ;;
  *) echo "error: unknown argument: $1" >&2
     echo "  Fix: run 'athena-inbox-client-run.sh' with no arguments, or --help." >&2
     exit 1 ;;
esac

LAUNCHER="${ATHENA_INBOX_CLIENT_LAUNCHER:-${HOME}/.local/bin/athena-inbox-client}"
STATE_DIR="${ATHENA_INBOX_CLIENT_STATE_DIR:-${HOME}/.local/state}"
MIN_BACKOFF="${ATHENA_INBOX_CLIENT_MIN_BACKOFF:-5}"
MAX_BACKOFF="${ATHENA_INBOX_CLIENT_MAX_BACKOFF:-300}"
BACKOFF_RESET="${ATHENA_INBOX_CLIENT_BACKOFF_RESET:-120}"
MAX_RESTARTS="${ATHENA_INBOX_CLIENT_MAX_RESTARTS:-0}"
MAX_LOG_LINES="${ATHENA_INBOX_CLIENT_MAX_LOG_LINES:-2000}"

LOG="${STATE_DIR}/athena-inbox-client.log"
PIDFILE="${STATE_DIR}/athena-inbox-client.pid"
CLIENT_PIDFILE="${STATE_DIR}/athena-inbox-client.client.pid"
STOPFILE="${STATE_DIR}/athena-inbox-client.stopped"
STOP_NOTICE="${STATE_DIR}/athena-inbox-client.stopped.notified"

mkdir -p -- "$STATE_DIR" 2>/dev/null || {
  echo "error: cannot create state dir: $STATE_DIR" >&2
  echo "  Fix: create it yourself (mkdir -p '$STATE_DIR') or point" \
       "ATHENA_INBOX_CLIENT_STATE_DIR at a writable directory." >&2
  exit 2
}

# say <msg> : one timestamped line into the log, and onto stderr only when a
# human is watching. UTC, matching the client's own log formatter.
say() {
  local line
  line="$(date -u '+%Y-%m-%dT%H:%M:%SZ') SUPERVISOR $*"
  printf '%s\n' "$line" >>"$LOG" 2>/dev/null || true
  [ -t 2 ] && printf '%s\n' "$line" >&2
  return 0
}

# Keep the log bounded. Only ever called BETWEEN client runs: the rewrite
# replaces the inode, and a client holding the old fd would otherwise keep
# writing into an unlinked file.
trim_log() {
  local lines
  [ -f "$LOG" ] || return 0
  lines="$(wc -l <"$LOG" 2>/dev/null || echo 0)"
  [ "$lines" -gt "$MAX_LOG_LINES" ] 2>/dev/null || return 0
  local keep=$(( MAX_LOG_LINES * 3 / 4 ))
  tail -n "$keep" "$LOG" >"${LOG}.trim" 2>/dev/null \
    && mv -f "${LOG}.trim" "$LOG" 2>/dev/null
  rm -f "${LOG}.trim" 2>/dev/null
  return 0
}

# ---- prerequisites ---------------------------------------------------------
command -v flock >/dev/null 2>&1 || {
  echo "error: flock(1) not found on PATH — the single-instance guarantee cannot be enforced." >&2
  echo "  Fix: install util-linux (it provides /usr/sbin/flock) or add its directory to PATH." >&2
  exit 2
}

[ -x "$LAUNCHER" ] || {
  echo "error: launcher not found or not executable: $LAUNCHER" >&2
  echo "  Fix: restore ~/.local/bin/athena-inbox-client (it must exec the ABSOLUTE ruby 3.3.0" \
       "path, never the asdf shim), chmod +x it, or set ATHENA_INBOX_CLIENT_LAUNCHER." >&2
  exit 2
}

# ---- the stop marker refuses the start ------------------------------------
# Checked BEFORE taking the lock so the state is reported even if a stale
# supervisor is somehow still holding it. Rate-limited: the */5 relaunch would
# otherwise write 288 identical lines a day into the log.
if [ -e "$STOPFILE" ]; then
  if [ ! -e "$STOP_NOTICE" ] || [ "$STOPFILE" -nt "$STOP_NOTICE" ]; then
    say "refusing to start: $STOPFILE exists — $(head -n 1 "$STOPFILE" 2>/dev/null)"
    say "  Fix: the inbox ends in a partial line. Delete the trailing fragment, then" \
        "'rm $STOPFILE' and run this script again. Do NOT just remove the marker."
    : >"$STOP_NOTICE" 2>/dev/null || true
  fi
  exit 0
fi

# ---- single instance -------------------------------------------------------
# Opened append-only: a truncating redirect would clobber the recorded pid
# BEFORE the lock is known to be ours. Writability is probed first because a
# failed redirect on `exec` (a special builtin) kills the shell outright, which
# would lose the actionable message.
touch -- "$PIDFILE" 2>/dev/null || {
  echo "error: cannot write the pidfile: $PIDFILE" >&2
  echo "  Fix: ensure $STATE_DIR exists and is writable, then re-run." >&2
  exit 2
}
exec 9>>"$PIDFILE"

if ! flock -n 9; then
  # Normal, expected path for the */5 relaunch entry while the client is
  # healthy. Silent by design — see the output discipline note above.
  exit 0
fi

: >"$PIDFILE" 2>/dev/null || true
printf '%s\n' "$$" >"$PIDFILE" 2>/dev/null || true

say "supervising $LAUNCHER (pid $$)"

# --- suppress D-Bus autolaunch, and reap any orphaned daemons ---------------
# See scripts/lib/dbus-env.sh: a cron process with no DBUS_SESSION_BUS_ADDRESS
# but a leaked graphical DISPLAY autolaunches a throwaway dbus-daemon that never
# exits and exhausts the inotify instance limit. Export an address so no
# descendant autolaunches, and best-effort reap earlier orphans. Placed after
# the flock so the */5 no-op relaunch does neither; silent (cron mails output).
__wrapper_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")" && pwd -P)"
# shellcheck source=scripts/lib/dbus-env.sh
. "${__wrapper_dir}/lib/dbus-env.sh"
athena_dbus_env_setup
"${__wrapper_dir}/reap-orphan-dbus" --min-age 300 >/dev/null 2>&1 || true

# ---- adopt the wreckage of a SIGKILLed supervisor --------------------------
# The lock says "a supervisor is alive" (the client is started with fd 9 closed
# so it cannot hold the lock itself — otherwise an orphan would keep the lock
# forever and every later cron tick would no-op in silence, which is precisely
# the unsupervised-client state this whole facility exists to prevent).
#
# But closing fd 9 alone trades one failure for a worse one: after `kill -9` of
# the supervisor the orphaned client keeps running AND the next invocation is
# free to take the lock and start a SECOND client — two writers on an inbox the
# delivery contract says has exactly one designated consumer. So the client's
# own pid is tracked separately, and a live orphan is terminated before a new
# client is started. Safe to do unconditionally here: we hold the exclusive
# lock, so no other supervisor can be racing us for it.
#
# SIGKILL is the realistic way to get here — it skips the reaper by design.
reap_orphaned_client() {
  local opid
  [ -f "$CLIENT_PIDFILE" ] || return 0
  opid="$(tr -d '[:space:]' <"$CLIENT_PIDFILE" 2>/dev/null)"
  rm -f "$CLIENT_PIDFILE" 2>/dev/null
  case "$opid" in ''|*[!0-9]*) return 0 ;; esac
  kill -0 "$opid" 2>/dev/null || return 0
  say "found an orphaned client (pid ${opid}) left by a supervisor that died without reaping;" \
      "terminating it before starting a new one, so the inbox never has two writers"
  kill "$opid" 2>/dev/null
  # Block on it rather than polling, bounded so a wedged client cannot hang the
  # supervisor; if it outlives the grace period, SIGKILL it.
  timeout 10 tail --pid="$opid" -f /dev/null >/dev/null 2>&1
  if kill -0 "$opid" 2>/dev/null; then
    say "orphaned client ${opid} ignored SIGTERM; sending SIGKILL"
    kill -9 "$opid" 2>/dev/null
  fi
  return 0
}
reap_orphaned_client

# ---- supervise -------------------------------------------------------------
backoff="$MIN_BACKOFF"
restarts=0
child=""

# A reaper is mandatory: the client is backgrounded so this shell can own the
# signal handling, and a crashed or killed supervisor must never orphan it
# (the PT-919 class of failure).
reap_child() { if [ -n "$child" ]; then kill "$child" 2>/dev/null; fi; }
trap reap_child EXIT

# INT/TERM must stop the SUPERVISOR, not merely its current client. A handler
# that only reaps and returns leaves `wait` interrupted with status 128+n,
# which the loop below reads as "the client crashed" and dutifully RELAUNCHES —
# so the documented recovery ("kill the pid in the pidfile") would restart the
# very process the operator just stopped, with the pidfile still looking right.
# Exiting here is what makes the stop a stop. The EXIT trap still fires, so the
# child is reaped exactly once either way.
trap 'reap_child; say "terminated by signal; supervisor stopping"; exit 143' TERM
trap 'reap_child; say "interrupted; supervisor stopping"; exit 130' INT

while :; do
  trim_log
  started="$(date +%s)"

  # 9>&- is load-bearing, not hygiene: without it the client inherits the open
  # lock descriptor and an orphan would hold the flock for its whole life, so
  # every later invocation would exit 0 in silence and nothing would ever
  # supervise again. See reap_orphaned_client above for the other half.
  "$LAUNCHER" 9>&- >>"$LOG" 2>&1 &
  child=$!
  printf '%s\n' "$child" >"$CLIENT_PIDFILE" 2>/dev/null || true
  wait "$child"
  rc=$?
  child=""
  rm -f "$CLIENT_PIDFILE" 2>/dev/null || true

  ran=$(( $(date +%s) - started ))

  if [ "$rc" -eq 0 ]; then
    say "client exited 0 after ${ran}s; supervisor stopping"
    exit 0
  fi

  if [ "$rc" -eq 2 ]; then
    # THE bug this supervisor exists to not reintroduce. Do not relaunch, here
    # or on any later cron invocation, until a human clears the marker.
    {
      printf 'client exited 2 (partial write) at %s after %ss\n' \
        "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$ran"
      printf 'An inbox file ends in a partial line. The un-acked event is re-pushed in\n'
      printf 'full on reconnect and must NOT land after the fragment. Recovery: fix the\n'
      printf 'disk, delete the trailing fragment, remove this file, then re-run\n'
      printf 'scripts/athena-inbox-client-run.sh. See %s for the failing write.\n' "$LOG"
    } >"$STOPFILE" 2>/dev/null || true
    rm -f "$STOP_NOTICE" 2>/dev/null || true
    say "client exited 2 (partial write) after ${ran}s — STOPPING PERMANENTLY; wrote $STOPFILE"
    say "  Fix: delete the trailing partial line from the inbox file named in the client's" \
        "error above, then 'rm $STOPFILE' and re-run this script."
    exit 0
  fi

  # A run that stayed up is evidence the fault was transient, so the next
  # failure starts from the short delay again rather than the cap.
  if [ "$ran" -ge "$BACKOFF_RESET" ]; then
    backoff="$MIN_BACKOFF"
  fi

  restarts=$(( restarts + 1 ))
  if [ "$MAX_RESTARTS" -gt 0 ] && [ "$restarts" -ge "$MAX_RESTARTS" ]; then
    say "client exited ${rc} after ${ran}s; restart limit ${MAX_RESTARTS} reached, stopping"
    exit 0
  fi

  say "client exited ${rc} after ${ran}s; restart ${restarts} in ${backoff}s"

  # Backgrounded, not a plain `sleep "$backoff"`. Bash defers a trapped signal
  # until the current FOREGROUND command finishes, so a foreground sleep would
  # swallow SIGTERM for up to MAX_BACKOFF (300s by default) and the documented
  # recovery — "kill the pid in the pidfile" — would appear to do nothing for
  # five minutes. Parking the pid in `child` also means the existing reaper
  # cleans the sleep up, so nothing is left behind.
  sleep "$backoff" 9>&- &
  child=$!
  wait "$child"
  child=""

  backoff=$(( backoff * 2 ))
  [ "$backoff" -gt "$MAX_BACKOFF" ] && backoff="$MAX_BACKOFF"
done
