#!/usr/bin/env bash
# Self-test for ai/hooks/flaky-marker-sweep.sh — the activity-independent
# stale-marker sweeper for the flaky-coordinator lock (DND-277).
#
# Hermetic: every case points FLAKY_MARKER_PATH at a temp file, so the real
# ~/.claude/flaky-coordinator.lock is never read, backdated, or removed. Asserts:
#   PURE decision boundaries (age just over / exactly at / just under 12h).
#   HIT  — a WEDGED-IDLE stale marker (present, mtime backdated >12h, no new
#          activity) IS swept.
#   MISS — a FRESH marker (<12h) is NOT removed (a live admiral draining must
#          be preserved).
#   MISSING — no marker at all is a no-op success (exit 0, no error), distinct
#          from a stale one.
#   MALFORMED KEY — an empty FLAKY_MARKER_PATH is rejected with a Fix: line but
#          stays non-blocking (exit 0), per "A failed lookup must never look
#          like an empty one".
# Run with stdin closed.
set -u

HOOK="$(cd -- "$(dirname -- "$0")" && pwd -P)/flaky-marker-sweep.sh"
FAILED=0
note() { printf '%s\n' "$*" >&2; }

# --- PURE decision boundaries (source the lib, do not trigger the sweep) ---
# shellcheck disable=SC1090
FLAKY_MARKER_SWEEP_LIB=1 . "$HOOK"

MAX=43200 # 12h
d_over=$(flaky_marker_decision 1000000 $((1000000 - (MAX + 1))) "$MAX")   # age 43201 -> sweep
d_at=$(flaky_marker_decision   1000000 $((1000000 - MAX))       "$MAX")   # age 43200 -> sweep (>=, mirrors poll)
d_under=$(flaky_marker_decision 1000000 $((1000000 - (MAX - 1))) "$MAX")  # age 43199 -> keep
[ "$d_over" = "sweep" ]  || { note "FAIL — age >12h should decide sweep, got '$d_over'"; FAILED=1; }
[ "$d_at" = "sweep" ]    || { note "FAIL — age ==12h should decide sweep (>= mirrors the poll's freshness test), got '$d_at'"; FAILED=1; }
[ "$d_under" = "keep" ]  || { note "FAIL — age <12h should decide keep, got '$d_under'"; FAILED=1; }

TMP=$(mktemp -d) || { echo "flaky-marker-sweep.self-test: FAIL — mktemp"; exit 1; }
LOG="$TMP/sweep.log" # durable trace lands here, never the real ~/.claude one

# --- HIT: wedged-idle stale marker (mtime backdated >12h) IS swept ---
STALE="$TMP/stale.lock"
: > "$STALE"
touch -d "13 hours ago" "$STALE" 2>/dev/null || touch -t "$(date -d '13 hours ago' +%Y%m%d%H%M 2>/dev/null)" "$STALE"
# stdout is CAPTURED (not discarded) and asserted empty: a SessionStart hook's
# stdout is injected as session context, so any stray echo would pollute every
# session on the machine. All diagnostics go to stderr / the log, never stdout.
out=$(FLAKY_MARKER_PATH="$STALE" FLAKY_MARKER_LOG="$LOG" "$HOOK" </dev/null 2>/dev/null)
rc=$?
[ "$rc" = "0" ] || { note "FAIL — sweep run did not exit 0 (rc=$rc)"; FAILED=1; }
[ -e "$STALE" ] && { note "FAIL — stale (>12h) marker in wedged-idle state was NOT swept"; FAILED=1; }
[ -z "$out" ] || { note "FAIL — sweep path wrote to STDOUT (injected as session context): $out"; FAILED=1; }
# The destructive action must leave a durable, greppable trace (so the trace
# cannot be silently deleted and the gate stay green).
grep -q "aged out stale" "$LOG" 2>/dev/null || { note "FAIL — a sweep left no durable trace in the log"; FAILED=1; }

# --- MISS: fresh marker (<12h, a live admiral draining) is PRESERVED ---
FRESH="$TMP/fresh.lock"
: > "$LOG"      # reset the trace to prove the miss writes nothing
: > "$FRESH"    # mtime = now
out=$(FLAKY_MARKER_PATH="$FRESH" FLAKY_MARKER_LOG="$LOG" "$HOOK" </dev/null 2>/dev/null)
rc=$?
[ "$rc" = "0" ] || { note "FAIL — fresh run did not exit 0 (rc=$rc)"; FAILED=1; }
[ -e "$FRESH" ] || { note "FAIL — a FRESH (<12h) marker was removed (a live admiral would be lost)"; FAILED=1; }
[ -s "$LOG" ] && { note "FAIL — a kept (fresh) marker wrote a sweep trace"; FAILED=1; }
[ -z "$out" ] || { note "FAIL — keep path wrote to STDOUT (injected as session context): $out"; FAILED=1; }

# --- MISSING: no marker is a no-op success, not an error ---
# (FLAKY_MARKER_LOG set too, so hermeticity holds by construction, not just by
# the control-flow that exits before log_event.)
MISSING="$TMP/does-not-exist.lock"
FLAKY_MARKER_PATH="$MISSING" FLAKY_MARKER_LOG="$LOG" "$HOOK" </dev/null
rc=$?
[ "$rc" = "0" ] || { note "FAIL — missing marker should be a no-op success (rc=$rc)"; FAILED=1; }
[ -e "$MISSING" ] && { note "FAIL — missing marker was somehow created"; FAILED=1; }

# --- MALFORMED KEY: empty path rejected with Fix:, still non-blocking ---
err=$(FLAKY_MARKER_PATH="" FLAKY_MARKER_LOG="$TMP/empty.log" "$HOOK" </dev/null 2>&1 >/dev/null)
rc=$?
[ "$rc" = "0" ] || { note "FAIL — empty FLAKY_MARKER_PATH must stay non-blocking (rc=$rc)"; FAILED=1; }
printf '%s' "$err" | grep -q "Fix:" || { note "FAIL — empty-path rejection must carry a Fix: line"; FAILED=1; }

# --- EMPTY LOG PATH falls back to the DEFAULT log, never to silence: a sweep
#     with FLAKY_MARKER_LOG="" must still leave a trace. Point HOME at a temp
#     dir so the default (~/.claude/flaky-marker-sweep.log) resolves under it,
#     never the real one. ---
FAKE_HOME="$TMP/home"; mkdir -p "$FAKE_HOME"
STALE2="$TMP/stale2.lock"; : > "$STALE2"
touch -d "13 hours ago" "$STALE2" 2>/dev/null || touch -t "$(date -d '13 hours ago' +%Y%m%d%H%M 2>/dev/null)" "$STALE2"
HOME="$FAKE_HOME" FLAKY_MARKER_PATH="$STALE2" FLAKY_MARKER_LOG="" "$HOOK" </dev/null
rc=$?
[ "$rc" = "0" ] || { note "FAIL — empty-log sweep did not exit 0 (rc=$rc)"; FAILED=1; }
[ -e "$STALE2" ] && { note "FAIL — empty-log run did not sweep the stale marker"; FAILED=1; }
grep -rq "aged out stale" "$FAKE_HOME/.claude/flaky-marker-sweep.log" 2>/dev/null \
  || { note "FAIL — empty FLAKY_MARKER_LOG went to SILENCE, not the default log"; FAILED=1; }

# --- UNSET HOME with FLAKY_MARKER_PATH set: must not abort (still exit 0) ---
env -u HOME FLAKY_MARKER_PATH="$TMP/no-home.lock" FLAKY_MARKER_LOG="$LOG" "$HOOK" </dev/null
rc=$?
[ "$rc" = "0" ] || { note "FAIL — unset HOME aborted the hook (rc=$rc); must stay non-blocking"; FAILED=1; }

# --- UNCOMPUTABLE DEFAULT KEY: unset HOME AND unset FLAKY_MARKER_PATH means the
#     default marker path cannot be computed. In THIS production shape the log
#     default also cannot resolve (no HOME), so the refusal must reach STDERR
#     unconditionally. Do NOT set FLAKY_MARKER_LOG — that would test a state the
#     failure cannot actually occur in. Must be observable AND non-blocking. ---
err=$(env -u HOME -u FLAKY_MARKER_PATH "$HOOK" </dev/null 2>&1 >/dev/null)
rc=$?
[ "$rc" = "0" ] || { note "FAIL — uncomputable default key must stay non-blocking (rc=$rc)"; FAILED=1; }
printf '%s' "$err" | grep -q "HOME is unset" || { note "FAIL — uncomputable default key was a SILENT no-op on stderr, not an observable refusal"; FAILED=1; }
printf '%s' "$err" | grep -q "Fix:" || { note "FAIL — uncomputable-key refusal must carry a Fix: line"; FAILED=1; }

# --- NON-NUMERIC THRESHOLD: a bad FLAKY_MARKER_MAX_AGE_SECS must be an
#     observable refusal (else the sweeper is silently OFF), and must NOT sweep. ---
BADCFG="$TMP/badcfg.lock"; : > "$BADCFG"
touch -d "13 hours ago" "$BADCFG" 2>/dev/null || touch -t "$(date -d '13 hours ago' +%Y%m%d%H%M 2>/dev/null)" "$BADCFG"
: > "$LOG"
err=$(FLAKY_MARKER_PATH="$BADCFG" FLAKY_MARKER_MAX_AGE_SECS="abc" FLAKY_MARKER_LOG="$LOG" "$HOOK" </dev/null 2>&1 >/dev/null)
rc=$?
[ "$rc" = "0" ] || { note "FAIL — non-numeric threshold must stay non-blocking (rc=$rc)"; FAILED=1; }
[ -e "$BADCFG" ] || { note "FAIL — non-numeric threshold must NOT sweep (sweeper off, but marker was removed)"; FAILED=1; }
grep -q "REFUSED:.*MAX_AGE_SECS" "$LOG" 2>/dev/null || { note "FAIL — non-numeric threshold was silent, not an observable refusal"; FAILED=1; }
printf '%s' "$err" | grep -q "Fix:" || { note "FAIL — non-numeric-threshold refusal must carry a Fix: line"; FAILED=1; }

# --- FAILED REMOVAL is observable, never silent: a stale marker that cannot be
#     removed must leave a trace and stay non-blocking (the marker survives). ---
if [ "$(id -u)" != "0" ]; then # root can unlink regardless of dir perms; skip there
  RODIR="$TMP/rodir"; mkdir -p "$RODIR"
  STUCK="$RODIR/stuck.lock"; : > "$STUCK"
  touch -d "13 hours ago" "$STUCK" 2>/dev/null || touch -t "$(date -d '13 hours ago' +%Y%m%d%H%M 2>/dev/null)" "$STUCK"
  chmod 0500 "$RODIR" # no write on the dir -> unlink of the file fails
  : > "$LOG"
  err=$(FLAKY_MARKER_PATH="$STUCK" FLAKY_MARKER_LOG="$LOG" "$HOOK" </dev/null 2>&1 >/dev/null)
  rc=$?
  chmod 0700 "$RODIR" # restore so cleanup can remove it
  [ "$rc" = "0" ] || { note "FAIL — a failed removal must stay non-blocking (rc=$rc)"; FAILED=1; }
  [ -e "$STUCK" ] || { note "FAIL — test setup wrong: marker was removable after all"; FAILED=1; }
  grep -q "REFUSED: could not remove" "$LOG" 2>/dev/null || { note "FAIL — a FAILED removal left no durable trace"; FAILED=1; }
  printf '%s' "$err" | grep -q "Fix:" || { note "FAIL — a failed removal must carry a Fix: line"; FAILED=1; }
fi

# --- DEFAULT MARKER PATH: with FLAKY_MARKER_PATH UNSET, the hook must resolve
#     and sweep the real default key (~/.claude/flaky-coordinator.lock). A typo
#     in that default segment would silently resolve to a never-existing path
#     (-> exit 0, no trace), the exact wedged-dark failure the hook prevents,
#     turned on the hook itself. Point HOME at a temp dir so the default
#     resolves under it, never the real marker. ---
DHOME="$TMP/dhome"; mkdir -p "$DHOME/.claude"
DEF_MARKER="$DHOME/.claude/flaky-coordinator.lock"; : > "$DEF_MARKER"
touch -d "13 hours ago" "$DEF_MARKER" 2>/dev/null || touch -t "$(date -d '13 hours ago' +%Y%m%d%H%M 2>/dev/null)" "$DEF_MARKER"
: > "$LOG"
env -u FLAKY_MARKER_PATH HOME="$DHOME" FLAKY_MARKER_LOG="$LOG" "$HOOK" </dev/null
rc=$?
[ "$rc" = "0" ] || { note "FAIL — default-marker run did not exit 0 (rc=$rc)"; FAILED=1; }
[ -e "$DEF_MARKER" ] && { note "FAIL — the DEFAULT marker path was not resolved/swept (a typo there would go silently dark)"; FAILED=1; }
grep -q "aged out stale" "$LOG" 2>/dev/null || { note "FAIL — default-marker sweep left no trace"; FAILED=1; }

# --- STAT FAILURE on a PRESENT marker is an OBSERVABLE refusal, never
#     silently-off: shim `stat` to fail (mimics a non-GNU stat) while the marker
#     still exists. Must not remove it, must trace, must stay non-blocking. ---
SHIMBIN="$TMP/shimbin"; mkdir -p "$SHIMBIN"
printf '#!/bin/sh\nexit 1\n' > "$SHIMBIN/stat"; chmod +x "$SHIMBIN/stat"
PRESENT="$TMP/present.lock"; : > "$PRESENT"
touch -d "13 hours ago" "$PRESENT" 2>/dev/null || touch -t "$(date -d '13 hours ago' +%Y%m%d%H%M 2>/dev/null)" "$PRESENT"
: > "$LOG"
err=$(PATH="$SHIMBIN:$PATH" FLAKY_MARKER_PATH="$PRESENT" FLAKY_MARKER_LOG="$LOG" "$HOOK" </dev/null 2>&1 >/dev/null)
rc=$?
[ "$rc" = "0" ] || { note "FAIL — stat-failure must stay non-blocking (rc=$rc)"; FAILED=1; }
[ -e "$PRESENT" ] || { note "FAIL — stat-failure path removed the marker (must not act without a valid mtime)"; FAILED=1; }
grep -q "REFUSED:.*mtime could not be read" "$LOG" 2>/dev/null || { note "FAIL — stat-failure on a present marker left no durable trace"; FAILED=1; }
printf '%s' "$err" | grep -q "Fix:" || { note "FAIL — stat-failure refusal must carry a Fix: line"; FAILED=1; }

# --- STAT SUCCEEDS WITH NON-INTEGER OUTPUT: a malformed mtime must be an
#     observable refusal and must NOT sweep (else the sweeper is silently off). ---
SHIMBIN2="$TMP/shimbin2"; mkdir -p "$SHIMBIN2"
printf '#!/bin/sh\nprintf "not-a-number\\n"\nexit 0\n' > "$SHIMBIN2/stat"; chmod +x "$SHIMBIN2/stat"
GARBAGE="$TMP/garbage.lock"; : > "$GARBAGE"
touch -d "13 hours ago" "$GARBAGE" 2>/dev/null || touch -t "$(date -d '13 hours ago' +%Y%m%d%H%M 2>/dev/null)" "$GARBAGE"
: > "$LOG"
err=$(PATH="$SHIMBIN2:$PATH" FLAKY_MARKER_PATH="$GARBAGE" FLAKY_MARKER_LOG="$LOG" "$HOOK" </dev/null 2>&1 >/dev/null)
rc=$?
[ "$rc" = "0" ] || { note "FAIL — non-integer mtime must stay non-blocking (rc=$rc)"; FAILED=1; }
[ -e "$GARBAGE" ] || { note "FAIL — non-integer mtime path removed the marker (must not act without a valid mtime)"; FAILED=1; }
grep -q "REFUSED:.*mtime is not an integer" "$LOG" 2>/dev/null || { note "FAIL — non-integer mtime left no durable trace"; FAILED=1; }
printf '%s' "$err" | grep -q "Fix:" || { note "FAIL — non-integer-mtime refusal must carry a Fix: line"; FAILED=1; }

# --- RELATIVE FLAKY_MARKER_PATH is malformed-for-its-type: an observable refusal,
#     never resolved against cwd and taken as a silent "missing" no-op. ---
: > "$LOG"
err=$(FLAKY_MARKER_PATH="relative/marker.lock" FLAKY_MARKER_LOG="$LOG" "$HOOK" </dev/null 2>&1 >/dev/null)
rc=$?
[ "$rc" = "0" ] || { note "FAIL — relative FLAKY_MARKER_PATH must stay non-blocking (rc=$rc)"; FAILED=1; }
grep -q "REFUSED:.*must be an absolute path" "$LOG" 2>/dev/null || { note "FAIL — relative marker path was not refused observably"; FAILED=1; }
printf '%s' "$err" | grep -q "Fix:" || { note "FAIL — relative-path refusal must carry a Fix: line"; FAILED=1; }

# --- NON-NUMERIC FLAKY_MARKER_LOG_MAX_LINES must not error the hook (coerced) ---
STALE4="$TMP/stale4.lock"; : > "$STALE4"
touch -d "13 hours ago" "$STALE4" 2>/dev/null || touch -t "$(date -d '13 hours ago' +%Y%m%d%H%M 2>/dev/null)" "$STALE4"
: > "$LOG"
FLAKY_MARKER_PATH="$STALE4" FLAKY_MARKER_LOG="$LOG" FLAKY_MARKER_LOG_MAX_LINES="abc" "$HOOK" </dev/null
rc=$?
[ "$rc" = "0" ] || { note "FAIL — non-numeric FLAKY_MARKER_LOG_MAX_LINES errored the hook (rc=$rc)"; FAILED=1; }
[ -e "$STALE4" ] && { note "FAIL — non-numeric max-lines run did not sweep"; FAILED=1; }
grep -q "aged out stale" "$LOG" 2>/dev/null || { note "FAIL — non-numeric max-lines dropped the sweep trace"; FAILED=1; }

# --- LOG ROTATION: an over-long log is trimmed to FLAKY_MARKER_LOG_MAX_LINES ---
ROT="$TMP/rot.log"; i=0; while [ "$i" -lt 20 ]; do echo "line $i" >> "$ROT"; i=$((i + 1)); done
STALE3="$TMP/stale3.lock"; : > "$STALE3"
touch -d "13 hours ago" "$STALE3" 2>/dev/null || touch -t "$(date -d '13 hours ago' +%Y%m%d%H%M 2>/dev/null)" "$STALE3"
FLAKY_MARKER_PATH="$STALE3" FLAKY_MARKER_LOG="$ROT" FLAKY_MARKER_LOG_MAX_LINES=5 "$HOOK" </dev/null
n=$(wc -l < "$ROT" | tr -d ' ')
[ "$n" = "5" ] || { note "FAIL — log not rotated to FLAKY_MARKER_LOG_MAX_LINES (got $n lines)"; FAILED=1; }
grep -q "aged out stale" "$ROT" 2>/dev/null || { note "FAIL — rotation dropped the newest (sweep) line"; FAILED=1; }

rm -rf "$TMP"
if [ "$FAILED" = "0" ]; then
  echo "flaky-marker-sweep.self-test: OK"
  exit 0
fi
note "flaky-marker-sweep.self-test: FAILED"
note "  Fix: keep flaky-marker-sweep.sh activity-independent and fail-safe — a >12h stale marker is swept, a <12h marker is kept, a missing marker is a no-op exit 0, and an empty FLAKY_MARKER_PATH is rejected with a Fix: line without blocking session start."
exit 1
