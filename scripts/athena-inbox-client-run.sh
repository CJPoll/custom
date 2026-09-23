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
# Watchdog (DND-316 / DND-333): the invocation that finds the lock HELD — the
# */5 cron tick while a supervisor is alive — is no longer a bare no-op. It
# judges the client from its log (lib/liveness.sh). A client stuck mid-
# reconnect past its allowance is WEDGED: the tick CAPTURES it
# (scripts/inbox-client-capture) and only then SIGTERMs it, and the owning
# supervisor relaunches it. Never restart first. A progressing client is never
# captured or signalled. Run this script by hand to force a watchdog pass now.
#
# Usage:
#   athena-inbox-client-run.sh            supervise the client (blocks), or, if
#                                         a supervisor already holds the lock,
#                                         run one watchdog pass and exit 0
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
#   ATHENA_INBOX_CLIENT_WEDGE_AFTER   seconds past a reconnect step's declared
#                                     backoff before the client is WEDGED (60)
#   XDG_STATE_HOME                    base of the client's dump directory, as
#                                     the client derives it (~/.local/state)
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
# Log size: the CLIENT bounds its own log. The supervisor exports
# ATHENA_INBOX_CLIENT_LOG=<the log below>, which switches on the LV-1 client's
# own size-capped rotation (8 MiB x 4 generations: <log>.1 .. <log>.3); without
# that variable the rotation is dormant and the client logs to stderr, which
# this script appends to the same file. The supervisor's own lines are appended
# by PATH, so they follow a rotation into the fresh file. The between-runs trim
# below remains for a crash-looping client (the rewrite replaces the inode, so
# it only ever runs while no client is alive).
#
# Liveness (DND-316) and the dump directory: the supervisor sources
# ai/skills/athena:inbox/lib/liveness.sh — the ONE wedge predicate and the ONE
# dump-dir derivation this machine has — and creates the client's SIGQUIT dump
# directory (0700) before every client start. (Missing, it degrades loudly
# rather than refusing to supervise: see degraded_notice.) The client creates it lazily on
# its first dump, so without this "no dumps yet" and "the dump path is broken"
# read the same until the wedge whose evidence has nowhere to go.
#
# Exit codes: 0 ok (client exited cleanly, or another instance holds the lock
#             and the watchdog pass ran, or the stop marker is present)
#             · 1 usage/arg error
#             · 2 missing prerequisite (no launcher, no flock, unusable state dir)
#             A missing liveness library or inbox-client-capture is NOT fatal:
#             the client is still supervised, the gap is reported on stderr and
#             in the log, and inbox-doctor's `watchdog` finding fails.
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

# The liveness library (the wedge predicate and the dump-dir derivation, shared
# with inbox-doctor so the two can never disagree) and inbox-client-capture are
# the watchdog's two tools. Their absence DEGRADES the supervisor, it never
# stops it: delivery outranks diagnostics, so a missing diagnostic tool must not
# be the reason the relay goes dark. Missing either one, the supervise path
# still keeps the client alive and says so loudly (stderr once per supervisor
# start, so cron mails it, and the log), and the watchdog pass is skipped with
# a log line; inbox-doctor's `watchdog` finding fails until they are restored.
__liveness_lib="$(cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")" && pwd -P)/../ai/skills/athena:inbox/lib/liveness.sh"
HAVE_LIVENESS=0
if [ -r "$__liveness_lib" ]; then
  # shellcheck source=ai/skills/athena:inbox/lib/liveness.sh
  . "$__liveness_lib" && HAVE_LIVENESS=1
fi
HAVE_CAPTURE=0
[ -x "$(cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")" && pwd -P)/inbox-client-capture" ] && HAVE_CAPTURE=1

# degraded_notice <to-stderr:0/1> — name each missing watchdog tool, with a Fix:.
degraded_notice() {
  local loud="$1" msg
  [ "$HAVE_LIVENESS" -eq 1 ] || {
    msg="the liveness library is missing ($__liveness_lib): no wedge detection, no dump directory"
    say "DEGRADED: $msg"
    [ "$loud" -eq 1 ] && { echo "warning: $msg" >&2; echo "  Fix: restore ai/skills/athena:inbox/lib/liveness.sh with git; the client is still supervised meanwhile." >&2; }
  }
  [ "$HAVE_CAPTURE" -eq 1 ] || {
    msg="scripts/inbox-client-capture is missing or not executable: a wedge cannot be captured before restart (D35); the watchdog will restart it with NO evidence"
    say "DEGRADED: $msg"
    [ "$loud" -eq 1 ] && { echo "warning: $msg" >&2; echo "  Fix: restore scripts/inbox-client-capture with git and chmod +x it; the client is still supervised meanwhile." >&2; }
  }
  return 0
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

# ---- the watchdog (DND-316 detector + DND-333 capture, epic D35) ------------
# Runs on the lock-held path, i.e. in the */5 cron invocation that finds a live
# supervisor. The ORDER is the whole point and is fixed:
#
#   1. judge  — liveness_verdict on the client log. Anything but `wedged` is a
#               no-op: a client that is connected (however quiet) or still
#               inside its reconnect allowance is never captured or killed.
#   2. find   — the client is the supervisor's ONE child (inbox-client-capture
#               --resolve-client: pidfile → pgrep -P → uid/exe/cmdline
#               asserted). Never a pattern match. If it cannot be identified
#               (e.g. the child is the backoff `sleep`), NOTHING is signalled,
#               and the log says "could not identify", distinct from any
#               capture outcome.
#   3. capture — inbox-client-capture <pid>: SIGQUIT for the LV-1 dump, sockets,
#               fds, status, log tail, signature. It must FINISH before step 4.
#   4. restart — only now SIGTERM the client (bounded wait, then SIGKILL); the
#               owning supervisor sees it exit and relaunches it with backoff.
#   5. alert  — (DND-334) inbox-client-alert drops ONE message on the local
#               harness-alerts maildir, for the harness session to verify and
#               file or increment the [wedge:<sig8>] ticket. AFTER the restart
#               (or after the decision not to signal), bounded, and a failure
#               is logged, never fatal.
#
# NEVER RESTART FIRST. On 2026-09-22 the wedged client was SIGTERM'd first and
# the evidence of the wedge was destroyed; the root cause is still unknown.
#
# If NO capture is possible — the capture FAILS (exit 2: no dump directory) or
# the capture tool is missing — the client is still restarted: a dark relay
# outranks the evidence. One rule for both, applied only after the attempt (or
# the finding that none can be made), and logged where the capture would have
# been named. An absent DUMP is not a capture failure (it is recorded evidence).
#
# The wedge allowance (ATHENA_INBOX_CLIENT_WEDGE_AFTER, 60 s past any declared
# backoff) is above every LV-1 per-step deadline (dns 10 s, tcp 10 s, tls 15 s,
# ws_upgrade 15 s, join 10 s), so a client that is failing SLOWLY during a
# server outage logs its failed step and reconnects before it can read as
# wedged. Only a step that outlives its own deadline trips the watchdog.
#
# The last wedge acted on is remembered (its log line) so the SAME wedge line
# is not captured twice; a new wedge has a new last line because the restart
# writes new ones.
CAPTURE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")" && pwd -P)/inbox-client-capture"
ALERT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")" && pwd -P)/inbox-client-alert"
WATCHDOG_MARK="${STATE_DIR}/athena-inbox-client.watchdog"

watchdog_pass() {
  local v state step age detail line c out rc dir="" sig dump
  if [ "$HAVE_LIVENESS" -ne 1 ]; then
    say "WATCHDOG: skipped — the liveness library is missing, so a wedge cannot be judged"
    return 0
  fi
  v="$(liveness_verdict "$LOG")"
  IFS=$'\t' read -r state step age detail <<<"$v"
  [ "$state" = "wedged" ] || return 0

  line="$(liveness_last_event "$LOG" 2>/dev/null)"
  if [ -n "$line" ] && [ "$(cat "$WATCHDOG_MARK" 2>/dev/null)" = "$line" ]; then
    return 0
  fi

  if [ ! -x "$CAPTURE" ]; then
    # ONE rule for "no capture is possible", whether the tool is missing or the
    # capture fails: a dark relay outranks the evidence, so the client is still
    # restarted -- after saying loudly that nothing was captured. Identity is
    # still asserted (without the tool, from the pidfile's one child directly).
    say "WATCHDOG: client WEDGED (${detail}) but $CAPTURE is missing — NO CAPTURE POSSIBLE; restarting anyway (a dark relay outranks the evidence)"
    say "  Fix: restore scripts/inbox-client-capture (git); inbox-doctor's watchdog finding fails until then."
    c="$(fallback_client)" || { say "WATCHDOG: could not identify the client — ${c}; nothing signalled"; return 0; }
    restart_client "$c" "$line"
    return 0
  fi

  if ! c="$("$CAPTURE" --resolve-client 9>&- 2>/dev/null)"; then
    say "WATCHDOG: client WEDGED (${detail}) but could not identify the client — ${c#could not identify the client: }; nothing captured, nothing signalled"
    return 0
  fi

  say "WATCHDOG: client pid ${c} WEDGED (${detail}); capturing BEFORE restart (D35)"
  out="$("$CAPTURE" "$c" --step "$step" --reason "watchdog: ${detail}" --trigger watchdog 9>&- 2>&1)"; rc=$?
  case "$rc" in
    0)
      dir="$(printf '%s\n' "$out" | awk -F'\t' '$1=="dir"{print $2}')"
      sig="$(printf '%s\n' "$out" | awk -F'\t' '$1=="signature"{print substr($2,1,8)}')"
      dump="$(printf '%s\n' "$out" | awk -F'\t' '$1=="dump"{print $2}')"
      say "WATCHDOG: captured ${dir} (signature ${sig}, dump ${dump})"
      # DND-367: retention's `note:` lines (references unreadable, or a capture
      # an unread alert references pruned at the hard max) belong in this log.
      printf '%s\n' "$out" | grep '^note: ' | while IFS= read -r n; do say "WATCHDOG: capture ${n}"; done
      ;;
    3)
      # The client changed identity between resolve and capture (it exited, or
      # the pid is a backoff sleep now). Nothing was signalled; do not kill it.
      say "WATCHDOG: could not identify the client at capture time — $(printf '%s' "$out" | head -n 1); nothing signalled"
      return 0
      ;;
    *)
      say "WATCHDOG: capture FAILED (exit ${rc}: $(printf '%s' "$out" | head -n 1)); restarting anyway — a dark relay outranks the evidence"
      ;;
  esac

  # The capture took up to ~10s. In that window the client may have exited and
  # been relaunched (a new pid), or its pid may even have been reused by an
  # unrelated process of this user. So identity is RE-ASSERTED immediately
  # before every signal: the pid must still be the supervisor's one child and
  # still our ruby client. Anything else is logged and NOT signalled.
  if ! still_client "$c"; then
    say "WATCHDOG: client pid ${c} is no longer the supervised client after the capture; not signalling"
    alert_capture "$dir"
    return 0
  fi
  restart_client "$c" "$line"
  alert_capture "$dir"
  return 0
}

# alert_capture <capture-dir> -- step 5 (DND-334): drop ONE harness-alerts
# message for a capture that exists. It runs AFTER the restart -- or after the
# decision NOT to signal a client that changed identity mid-capture (the capture
# is still evidence of a wedge) -- so a slow or
# failed send can neither delay the restart nor undo the capture; the send is
# bounded by inbox-client-alert's own timeout. A failure is logged loudly with
# its Fix: and the watchdog carries on -- the capture on disk is intact and the
# message can be re-sent by hand. No capture (it failed, or the tool is
# missing) means no message: there is nothing for the attendant to verify.
alert_capture() {
  local d="$1" out rc fixline
  [ -n "$d" ] || return 0
  if [ ! -x "$ALERT" ]; then
    say "WATCHDOG: ALERT NOT SENT for ${d} — $ALERT is missing"
    say "  Fix: restore scripts/inbox-client-alert (git), then send it by hand: scripts/inbox-client-alert ${d}; inbox-doctor's watchdog finding fails until then."
    return 0
  fi
  out="$("$ALERT" "$d" 9>&- 2>&1)"; rc=$?
  if [ "$rc" -eq 0 ]; then
    say "WATCHDOG: alert sent on harness-alerts ($(printf '%s\n' "$out" | awk -F'\t' '$1=="sent"{print $2}'))"
  else
    say "WATCHDOG: ALERT NOT SENT for ${d} (exit ${rc}): $(printf '%s' "$out" | grep -v -e '^  Fix:' -e '^note: ' | head -n 1)"
    fixline="$(printf '%s\n' "$out" | grep -m1 '^  Fix:' | sed 's/^ *//')"
    [ -n "$fixline" ] && say "  $fixline"
  fi
  printf '%s\n' "$out" | grep '^note: ' | while IFS= read -r n; do say "WATCHDOG: alert ${n}"; done
  return 0
}

# restart_client <pid> <wedge-line> — SIGTERM, bounded wait, re-assert, SIGKILL.
restart_client() {
  local c="$1" line="$2"
  say "WATCHDOG: SIGTERM client pid ${c}; its supervisor relaunches it"
  printf '%s\n' "$line" >"$WATCHDOG_MARK" 2>/dev/null || true
  kill -TERM "$c" 2>/dev/null
  timeout 10 tail --pid="$c" -f /dev/null >/dev/null 2>&1
  if kill -0 "$c" 2>/dev/null; then
    if still_client "$c"; then
      say "WATCHDOG: client ${c} ignored SIGTERM for 10s; sending SIGKILL"
      kill -KILL "$c" 2>/dev/null
    else
      say "WATCHDOG: pid ${c} is alive but no longer the supervised client; not sending SIGKILL"
    fi
  fi
}

# still_client <pid> — status 0 only while <pid> is STILL the supervisor's one
# child and our ruby client (inbox-client-capture --resolve-client, re-run; the
# fallback check when that tool is missing).
still_client() {
  local now
  if [ -x "$CAPTURE" ]; then now="$("$CAPTURE" --resolve-client 9>&- 2>/dev/null)" || return 1
  else now="$(fallback_client)" || return 1; fi
  [ "$now" = "$1" ]
}

# fallback_client — the same identity rule as inbox-client-capture
# --resolve-client, for when that tool is missing: the ONE child of the pid in
# the pidfile, our uid, a ruby executable, a cmdline naming
# athena-inbox-client.rb. Prints the pid, or the reason (status 1).
fallback_client() {
  local s kids n c exe
  s="$(tr -d '[:space:]' <"$PIDFILE" 2>/dev/null)"
  case "$s" in ''|*[!0-9]*) echo "no supervisor pid in $PIDFILE"; return 1 ;; esac
  kids="$(pgrep -P "$s" 2>/dev/null)"; n="$(printf '%s' "$kids" | grep -c '[0-9]')"
  [ "$n" -eq 1 ] || { echo "the supervisor has $n children, expected 1"; return 1; }
  c="$(printf '%s' "$kids" | tr -d '[:space:]')"
  [ "$(stat -c %u "/proc/$c" 2>/dev/null)" = "$(id -u)" ] || { echo "pid $c is not ours"; return 1; }
  exe="$(readlink "/proc/$c/exe" 2>/dev/null)"
  case "${exe##*/}" in ruby|ruby[0-9]*) ;; *) echo "pid $c is not the ruby client (exe ${exe:-?})"; return 1 ;; esac
  case "$(tr '\0' ' ' <"/proc/$c/cmdline" 2>/dev/null)" in *athena-inbox-client.rb*) ;; *) echo "pid $c cmdline does not name athena-inbox-client.rb"; return 1 ;; esac
  printf '%s\n' "$c"
}

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
  # Normal, expected path for the */5 relaunch entry: another supervisor is
  # alive. Before DND-316 this exited at once, which is exactly why a wedged
  # client could hold the lock forever while nothing ever healed it. Now the
  # tick is the WATCHDOG: it judges the client from its log and, only when the
  # client is wedged, captures and then restarts it. A progressing client is
  # never touched. Silent (log only) by design — see the output discipline note.
  watchdog_pass
  exit 0
fi

: >"$PIDFILE" 2>/dev/null || true
printf '%s\n' "$$" >"$PIDFILE" 2>/dev/null || true

say "supervising $LAUNCHER (pid $$)"
degraded_notice 1

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

# ---- the client's dump directory -------------------------------------------
# Created (0700) before every client start, so a SIGQUIT dump always has a
# directory to land in. A failure is LOGGED, not fatal: delivery does not
# depend on it, and inbox-doctor's dump-dir check fails loudly with a Fix: for
# exactly this state.
ensure_dump_dir() {
  local d
  [ "$HAVE_LIVENESS" -eq 1 ] || return 0   # already reported by degraded_notice
  if ! d="$(liveness_dump_dir)"; then
    say "cannot derive the client dump directory: XDG_STATE_HOME is relative (${XDG_STATE_HOME:-})"
    say "  Fix: set XDG_STATE_HOME to an absolute path or unset it; a wedge dump would otherwise land where nothing looks."
    return 0
  fi
  if ! { mkdir -p -- "$d" 2>/dev/null && chmod 700 -- "$d" 2>/dev/null && [ -d "$d" ] && [ ! -L "$d" ]; }; then
    say "cannot create the client dump directory $d (0700)"
    say "  Fix: make its parent writable, or remove whatever sits at $d; run inbox-doctor (dump-dir) for the detail."
  fi
  return 0
}

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

  ensure_dump_dir

  # 9>&- is load-bearing, not hygiene: without it the client inherits the open
  # lock descriptor and an orphan would hold the flock for its whole life, so
  # every later invocation would exit 0 in silence and nothing would ever
  # supervise again. See reap_orphaned_client above for the other half.
  #
  # ATHENA_INBOX_CLIENT_LOG hands the client its own log file so its size-capped
  # rotation is live (it is dormant while the variable is unset). With it set,
  # the client's logger writes ONLY to that file (never also to stderr), so no
  # line is doubled. stdout/stderr still append here, so a fatal message printed
  # before the logger exists, or the exit-2 partial-write text, is never lost --
  # though after a rotation this descriptor still points at the renamed file, so
  # such a line lands in <log>.1. The liveness reader falls back to <log>.1.
  ATHENA_INBOX_CLIENT_LOG="$LOG" "$LAUNCHER" 9>&- >>"$LOG" 2>&1 &
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
