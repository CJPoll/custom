#!/usr/bin/env bash
# control-effects.sh -- SIDE EFFECTS for session control (DND-443): the control
# cache on disk, the tz database, and the clock. The HTTP read is effects.sh's
# fleet_get (the token rides curl's stdin, never argv). None of these decides
# policy; that is control-domain.sh.
#
# Source order: domain.sh, control-domain.sh, the athena:inbox libs, effects.sh,
# then this file.

# fleet_control_cache_path <claude_session_id>
# $XDG_STATE_HOME/athena/fleet/<id>.json -- beside, never inside, DND-433's
# seen/ stamps. Status 2 (the contract's `invalid-cache-path`) when
# XDG_STATE_HOME is set but not absolute: no path is read or written then. An
# unsafe id also gives status 2, as a guard: bin/fleet-control already refuses
# one as a usage error (exit 2) before anything runs.
fleet_control_cache_path() {
  local d
  fleet_valid_id "${1:-}" || return 2
  d="$(fleet_state_dir)" || return 2
  printf '%s/%s.json\n' "${d}" "$1"
}

# fleet_read_cache <path>
# Prints the cache. Status 1 = no such file; 3 = it exists but is not a
# readable regular file, or is larger than any real answer (64 KiB).
fleet_read_cache() {
  [ -e "$1" ] || [ -L "$1" ] || return 1
  [ -f "$1" ] && [ -r "$1" ] || return 3
  [ "$(stat -c %s -- "$1" 2>/dev/null || echo 999999)" -le 65536 ] || return 3
  cat -- "$1"
}

# fleet_write_cache <path> <json>
# Atomic replace: a 0600 temp file in the same 0700 directory, then rename.
# A reader never sees a half-written cache. Status 1 when it cannot be written.
fleet_write_cache() {
  local path="$1" json="$2" dir tmp
  dir="${path%/*}"
  mkdir -p -- "${dir}" 2>/dev/null && chmod 700 -- "${dir}" 2>/dev/null || return 1
  tmp="$(mktemp -- "${dir}/.cache.XXXXXX" 2>/dev/null)" || return 1
  if printf '%s\n' "${json}" > "${tmp}" && chmod 600 -- "${tmp}" && mv -f -- "${tmp}" "${path}"; then
    return 0
  fi
  rm -f -- "${tmp}"
  return 1
}

# fleet_tz_known <zone> -- status 0 when the tz database has this zone. GNU
# date silently falls back to UTC for an unknown TZ, so an unchecked zone would
# compute the wrong hours and say nothing.
fleet_tz_known() {
  case "${1:-}" in ''|*..*|/*) return 1 ;; esac
  [ -f "${TZDIR:-/usr/share/zoneinfo}/$1" ]
}

# fleet_now -- the clock, epoch seconds.
fleet_now() {
  date +%s
}

# fleet_append_guard_log <line> -- one line in the drain guard's decision log,
# $XDG_STATE_HOME/athena/fleet/drain-guard.log, rotated to `.1` past 256 KiB.
# It is the evidence a live verify reads ("was the refill refused?"). Status 2
# when it cannot be written; the guard's decision never depends on it.
fleet_append_guard_log() {
  local d log size
  d="$(fleet_state_dir)" || return 2
  log="${d}/drain-guard.log"
  mkdir -p -- "${d}" 2>/dev/null || return 2
  (
    exec 8>>"${log}.lock" || exit 2
    flock -w 5 8 || exit 2
    size="$(stat -c %s -- "${log}" 2>/dev/null || echo 0)"
    if [ "${size}" -gt 262144 ]; then mv -f -- "${log}" "${log}.1" || exit 2; fi
    printf '%s\n' "$1" >> "${log}" || exit 2
  )
}
