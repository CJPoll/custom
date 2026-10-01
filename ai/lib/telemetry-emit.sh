# shellcheck shell=bash
#
# telemetry-emit.sh -- the one shell binding to the telemetry CLI
# (ai/bin/telemetry-emit), for bash emitters (DND-1475). Sourced, never run.
# The contract is ai/contracts/athena-telemetry.md; its *The CLI* says how a
# shell emitter calls the writer, and this file is that call, written once.
#
# Functions:
#   athena_telemetry_emit <telemetry-emit args...>
#       One event through the CLI, bounded and fail-open: `timeout -k 1 2` (KILL a second after TERM), stdin
#       from /dev/null, stdout dropped, its status ignored. Of its stderr only
#       the writer's one `athena-telemetry:` line (which carries Fix:) reaches
#       the caller's stderr, so the contract's last-resort signal still fires.
#       It always returns 0 and never prints on stdout, so the caller's exit
#       code and stdout are what they were without it. A CLI that is missing
#       or not executable is skipped silently: the emitter's tool must not
#       change because a sibling file is gone.
#       Write the event name as a literal on the call line (`--event x.y`),
#       with literal --attr keys: ai/bin/check-telemetry-registry reads the
#       call statically and fails a computed name.
#   athena_telemetry_now
#       The current UTC time, ISO 8601 with milliseconds, for --at.
#   athena_telemetry_clock_us
#       A microsecond clock reading ($EPOCHREALTIME), or nothing.
#   athena_telemetry_seconds_since <clock_us>
#       Seconds since a clock_us reading, as S.mmm, for --duration; nothing
#       when the start is empty or the clock is unreadable (a missing duration
#       is a point event, never a zero).
#
# Safe under `set -euo pipefail`: every command that can fail is guarded.

_ATHENA_TELEMETRY_CLI="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../bin/telemetry-emit"

athena_telemetry_emit() {
  local err=""
  [ -x "${_ATHENA_TELEMETRY_CLI}" ] || return 0
  err="$(timeout -k 1 2 "${_ATHENA_TELEMETRY_CLI}" "$@" 2>&1 >/dev/null </dev/null)" || true
  if [[ "${err}" == athena-telemetry:* ]]; then
    printf '%s\n' "${err%%$'\n'*}" >&2 || true
  fi
  return 0
}

athena_telemetry_now() {
  date -u +%Y-%m-%dT%H:%M:%S.%3NZ 2>/dev/null || true
}

athena_telemetry_clock_us() {
  local t="${EPOCHREALTIME:-}"
  if [[ "${t}" =~ ^[0-9]+[.,][0-9]{6}$ ]]; then
    printf '%s' "${t//[.,]/}"
  fi
  return 0
}

athena_telemetry_seconds_since() {
  local start="${1:-}" now d
  [[ "${start}" =~ ^[0-9]+$ ]] || return 0
  now="$(athena_telemetry_clock_us)"
  [ -n "${now}" ] || return 0
  d=$(( now - start ))
  [ "${d}" -ge 0 ] || return 0
  printf '%d.%03d' "$(( d / 1000000 ))" "$(( (d % 1000000) / 1000 ))"
  return 0
}
