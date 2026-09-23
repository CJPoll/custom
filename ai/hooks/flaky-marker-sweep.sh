#!/usr/bin/env bash
# flaky-marker-sweep.sh — SessionStart hook: age out a STALE flaky-coordinator
# marker (`~/.claude/flaky-coordinator.lock`) whose mtime is older than 12h.
#
# WHY (DND-277): the flaky lane treats a present marker as "an admiral is
# draining", so a stale marker left by a dead/aborted admiral wedges the lane
# dark. Before H-4/DND-248, the ONLY activity-independent age-out of that
# marker lived in walt_ui's flaky-ticket-poll.sh ("the poll also self-heals a
# marker older than 12h"). H-4/DND-248 has now retired that poll as a trigger
# (owner directive, 2026-09-23; ai/CLAUDE.md → *Ticket-driven lanes*), and the
# inbox-count trigger CANNOT replace the age-out (the .event doorbell is an
# mtime bump AFTER an append — there is no platform periodic sweep). This hook
# re-provisions the age-out half so it survives the poll's retirement as a
# trigger: it fires on EVERY session start, independent of flaky-lane
# activity, so the wedged-idle state (stale marker + no new activity) is
# still swept even if walt_ui's poll is no longer running.
#
# FAIL-SAFE and NON-BLOCKING: a SessionStart hook must never break session
# start, so every path exits 0. It removes ONLY a stale (>12h) marker; a fresh
# (<12h) marker — a live admiral draining — is always preserved. Removal is
# idempotent, so this hook is the only age-out THIS HARNESS guarantees;
# running alongside walt_ui's poll, if it is still wired there (its removal
# is walt_ui's own separate change, not yet confirmed done), is harmless.
#
# OBSERVABLE: removing the marker is the one destructive action here, and the
# lane reads a present marker as "an admiral is draining", so a silent removal
# would be "Make every miss observable" (A failed lookup must never look like an
# empty one) inverted onto a hit. Each sweep — and each key-misconfiguration —
# appends a timestamped line to a durable, greppable log (default
# ~/.claude/flaky-marker-sweep.log, last 200 lines), the same way the sibling
# SessionStart hook athena-inbox-poll.sh keeps its own log rather than trusting
# harness-captured stderr to be a persistent surface.
#
# Config (all overridable — the self-test relies on FLAKY_MARKER_PATH and
# FLAKY_MARKER_LOG so it never touches the real marker or log):
#   FLAKY_MARKER_PATH          marker to age out (default ~/.claude/flaky-coordinator.lock)
#   FLAKY_MARKER_MAX_AGE_SECS  staleness threshold in seconds (default 43200 = 12h)
#   FLAKY_MARKER_LOG           durable trace file (default ~/.claude/flaky-marker-sweep.log)
#   FLAKY_MARKER_LOG_MAX_LINES rotate the log to this many lines (default 200)
#
# --self-test lives in ai/hooks/flaky-marker-sweep.self-test.sh (the dedicated
# script form, not a --self-test FLAG — that would be the gate's false-green
# trap). Source this file with FLAKY_MARKER_SWEEP_LIB=1 to unit-test the pure
# decision without triggering the sweep.
set -u

# PURE (Domain): given the current time, the marker's mtime, and the max age —
# all epoch seconds — decide whether to sweep. Prints "sweep" or "keep". No
# I/O, no filesystem: the whole decision is arithmetic, so the self-test drives
# every boundary directly. The boundary is `age >= max_age` (see the `-ge`
# rationale below): a marker at exactly the threshold is SWEPT, mirroring the
# poll's freshness test so the two runners agree at the boundary.
flaky_marker_decision() {
  local now=$1
  local mtime=$2
  local max_age=$3
  local age=$(( now - mtime ))
  # `-ge`: mirror the poll's freshness test EXACTLY. The poll treats a marker as
  # fresh iff `age < stale_sec` (walt_ui flaky-ticket-poll.sh: `lock_fresh =
  # (time.time() - getmtime) < stale_sec`), so it treats age == threshold as
  # stale. Sweeping at `>=` keeps the two runners agreeing at the boundary
  # instead of disagreeing by one second.
  if [ "$age" -ge "$max_age" ]; then
    echo sweep
  else
    echo keep
  fi
}

# Side Effect: append one timestamped line to the durable trace log, then rotate
# it to the last FLAKY_MARKER_LOG_MAX_LINES. Fail-open — a log we cannot write
# must never break session start.
log_event() {
  local msg=$1
  # `:-` (not `-`): an empty FLAKY_MARKER_LOG falls back to the default log, NOT
  # to silence — a set-but-empty log must never let the destructive sweep happen
  # untraced. `${HOME:-}` keeps the default safe under `set -u` with HOME unset.
  local log="${FLAKY_MARKER_LOG:-${HOME:-}/.claude/flaky-marker-sweep.log}"
  local max_lines="${FLAKY_MARKER_LOG_MAX_LINES:-200}"
  # A non-numeric rotation knob would make the `-gt` compare below error; coerce
  # it to the default rather than skipping rotation, so a typo cannot let the log
  # grow without bound.
  case "$max_lines" in '' | *[!0-9]*) max_lines=200 ;; esac
  [ -n "$log" ] || return 0
  mkdir -p "$(dirname "$log")" 2>/dev/null || return 0
  printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)" "$msg" >> "$log" 2>/dev/null || return 0
  local n
  n=$(wc -l < "$log" 2>/dev/null) || return 0
  [ "$n" -gt "$max_lines" ] 2>/dev/null || return 0
  local tmp="$log.tmp.$$"
  if tail -n "$max_lines" "$log" > "$tmp" 2>/dev/null; then
    mv -f -- "$tmp" "$log" 2>/dev/null || rm -f -- "$tmp" 2>/dev/null
  fi
  return 0
}

# Observable refusal — the ONE place every error/refusal path routes through, so
# a non-legitimate exit can never be a silent no-op ("A failed lookup must never
# look like an empty one" / "Make every miss observable"). It writes to BOTH the
# durable log (best-effort) AND stderr (unconditional): the log is the persistent
# surface, but stderr is the ONLY surface guaranteed when no writable log
# location exists — notably when HOME is unset, where the log default itself
# cannot resolve. So observability never depends solely on a writable log. Every
# caller still exits 0 afterwards; a SessionStart hook must not break the session.
#   refuse <human msg (no leading marker)> <fix instruction>
refuse() {
  log_event "REFUSED: $1"
  echo "flaky-marker-sweep: $1" >&2
  echo "  Fix: $2" >&2
}

# PURE predicate: is the argument a non-empty run of digits (a non-negative
# integer)? Every value fed to the arithmetic staleness compare (now, mtime,
# max_age) is validated through this — a value that is malformed FOR ITS TYPE
# (empty, a float, "abc", a `stat` that prints garbage) must be an observable
# refusal, not a decision that silently falls to "keep".
is_uint() {
  case "$1" in
    '' | *[!0-9]*) return 1 ;;
    *) return 0 ;;
  esac
}

# Orchestration (Manager): resolve the key, read the mtime (Side Effect), apply
# the pure decision, remove if stale (Side Effect).
main() {
  # KEY RESOLUTION, treated as its own step with its own outcome ("A failed
  # lookup must never look like an empty one"): a key that cannot be COMPUTED is
  # an observable REFUSAL, never a silent "no marker". Three distinct cases:
  #   * FLAKY_MARKER_PATH set (even empty)  -> use it verbatim; empty is rejected below.
  #   * unset, HOME present                 -> the real default key.
  #   * unset, HOME empty/unset             -> the default key is UNCOMPUTABLE; refuse.
  # The third case is why we do NOT write `${FLAKY_MARKER_PATH-${HOME:-}/…}`:
  # that resolves to the literal `/.claude/…`, which never exists, so a wrongly
  # computed key would read as an empty miss and the lane would stay wedged dark.
  local marker
  if [ -n "${FLAKY_MARKER_PATH+x}" ]; then
    marker="$FLAKY_MARKER_PATH"
  elif [ -n "${HOME:-}" ]; then
    marker="$HOME/.claude/flaky-coordinator.lock"
  else
    refuse "HOME is unset and FLAKY_MARKER_PATH is not set — cannot resolve the default marker path." \
           "run with HOME set, or set FLAKY_MARKER_PATH to the marker's absolute path."
    exit 0
  fi
  local max_age="${FLAKY_MARKER_MAX_AGE_SECS:-43200}"
  local now mtime

  # KEY VALIDATION: an empty marker path is a MISCONFIGURED key, not "no marker".
  if [ -z "$marker" ]; then
    refuse "FLAKY_MARKER_PATH is set but empty — cannot resolve the marker to age out." \
           "unset FLAKY_MARKER_PATH to use the default (~/.claude/flaky-coordinator.lock), or set it to a real path."
    exit 0
  fi

  # KEY VALIDATION (malformed-for-its-type): a RELATIVE marker path resolves
  # against whatever cwd the session started in — a wrongly-computed key that
  # would then take the "missing -> no-op" branch and go silently dark. The
  # marker is a machine-wide lock, so its path is required absolute; reject a
  # relative one where it is produced.
  case "$marker" in
    /*) ;;
    *)
      refuse "FLAKY_MARKER_PATH must be an absolute path (start with /), got '$marker'." \
             "set FLAKY_MARKER_PATH to the marker's absolute path, or unset it to use the default."
      exit 0
      ;;
  esac

  # CONFIG VALIDATION (same class): a non-numeric threshold makes the arithmetic
  # compare error and the decision fall to "keep" — the sweeper silently OFF. A
  # bad config must not read as "nothing stale"; refuse observably instead.
  if ! is_uint "$max_age"; then
    refuse "FLAKY_MARKER_MAX_AGE_SECS must be a whole number of seconds, got '$max_age'." \
           "unset FLAKY_MARKER_MAX_AGE_SECS (default 43200), or set it to a non-negative integer."
    exit 0
  fi

  # MISSING marker is a no-op SUCCESS, explicitly distinct from an uncomputable
  # key above: no admiral is draining and there is nothing to age out.
  if [ ! -e "$marker" ]; then
    exit 0
  fi

  # `date` failing (or returning a non-integer) is catastrophic system state,
  # not "nothing stale" — refuse observably rather than exit silently.
  if ! now=$(date +%s 2>/dev/null) || ! is_uint "$now"; then
    refuse "could not read a numeric current time (date +%s) — cannot decide staleness." \
           "check that coreutils' date works on this machine; the marker survives untouched."
    exit 0
  fi

  # Side Effect: read the mtime. A failed/empty read is NOT automatically
  # "nothing to do": re-test existence to tell a genuine vanish-race (the marker
  # was cleared by a live admiral or the poll between the -e check and here →
  # legitimate silent no-op) from a marker that is STILL PRESENT but whose mtime
  # could not be read (non-GNU `stat`, a transient error → observable refusal,
  # else the sweeper is silently OFF for exactly the wedged state it clears).
  if ! mtime=$(stat -c %Y "$marker" 2>/dev/null) || [ -z "$mtime" ]; then
    if [ -e "$marker" ]; then
      refuse "the marker exists but its mtime could not be read (stat failed) — cannot decide staleness: $marker" \
             "ensure GNU coreutils' stat is on PATH (stat -c %Y); if the marker is genuinely stale, remove it by hand (rm -f $marker)."
    fi
    exit 0
  fi

  # mtime read but malformed-for-its-type (a `stat` that SUCCEEDS with non-integer
  # output): the other operand of the same compare as max_age, so it gets the same
  # guard — a bad mtime must not read as "nothing stale".
  if ! is_uint "$mtime"; then
    refuse "the marker's mtime is not an integer (stat returned '$mtime') — cannot decide staleness: $marker" \
           "ensure GNU coreutils' stat -c %Y returns an epoch integer; if the marker is genuinely stale, remove it by hand (rm -f $marker)."
    exit 0
  fi

  if [ "$(flaky_marker_decision "$now" "$mtime" "$max_age")" = "sweep" ]; then
    if rm -f "$marker" 2>/dev/null; then
      # Durable, greppable trace of the one destructive action, so a
      # silently-wedged lane leaves a record of why it was unwedged.
      log_event "aged out stale flaky-coordinator marker (mtime older than $((max_age / 3600))h): $marker"
    else
      # A FAILED removal must never look like "nothing to sweep": the marker
      # survives and the lane stays wedged dark, so the failure is the exact
      # miss the hook exists to prevent. Make it observable.
      refuse "could not remove stale marker $marker — it survives and the flaky lane may stay wedged." \
             "check the permissions on $marker and its directory, then remove it by hand (rm -f $marker)."
    fi
  fi
  exit 0
}

# Allow the self-test to source this file for unit-testing flaky_marker_decision
# without running the sweep.
if [ "${FLAKY_MARKER_SWEEP_LIB:-}" = "1" ]; then
  return 0 2>/dev/null || exit 0
fi

main "$@"
