#!/usr/bin/env bash
# fleet-report.sh -- SessionStart / SessionEnd / PostToolUse hook: report this
# session (and any admiral in it) to the Athena fleet registry through
# ai/bin/fleet-report. Contract: ai/contracts/athena-events.md -> *Fleet report
# kinds and their closed schema* -> "Who sends what" (DND-433).
#
#   SessionStart -> session_started   (fires once per top-level session, never
#                                      in a subagent: DND-428)
#   SessionEnd   -> session_ended     (absent on SIGKILL: the server derives
#                                      `lost`/`ended` from silence, not from us)
#   PostToolUse  -> admiral_seen when stdin's agent_type is athena-admiral,
#                   session_seen otherwise; at most once per 60 s per
#                   (session_id, agent_id), under an flock'd stamp in
#                   $XDG_STATE_HOME/athena/fleet/seen/
#
# NEVER ADDS LATENCY, NEVER BLOCKS. The network call runs detached (setsid -f,
# re-entering this script as `--detached`) under `timeout`, with stdin and
# stdout closed, so the hook returns as soon as it has parsed stdin and (for
# PostToolUse) checked the stamp. It always exits 0.
#
# FAILURE IS STILL VISIBLE. Hook stderr on exit 0 reaches neither the model nor
# (outside verbose mode) the human, so it is not where a failure goes. Every
# failed report -- a detached one, or one this hook refuses itself (no
# session_id, unparseable stdin) -- is appended with its `Fix:` to the durable
# $XDG_STATE_HOME/athena/fleet/report-failures.log. The SessionStart hook prints
# a one-line notice of failures it has not announced before on its STDOUT,
# which Claude Code adds to the new top-level session's context. Announcing
# never deletes a log line.
#
# --self-test runs ai/hooks/fleet-report.self-test.sh (a hook reads stdin, so the
# suite is a dedicated file; harness-gate declares that file, never this one
# with a flag).

set -u

SELF="$(realpath -- "${BASH_SOURCE[0]}")"
HOOK_DIR="$(dirname -- "${SELF}")"
AI="$(cd -- "${HOOK_DIR}/.." && pwd -P)"
BIN="${AI}/bin/fleet-report"

# shellcheck source=../lib/fleet/domain.sh
. "${AI}/lib/fleet/domain.sh"
# shellcheck source=../lib/fleet/effects.sh
. "${AI}/lib/fleet/effects.sh"

# run_detached <session_id> <kind> <limit-s> <command...>
# The body of one background report. Its stderr goes to a private temp file
# (removed by the trap); on failure its first line -- fleet-report's own
# one-line `Fix:` -- is appended to the failure log.
run_detached() {
  local sid="$1" kind="$2" limit="$3" tmp rc msg
  shift 3
  tmp="$(mktemp 2>/dev/null)" || tmp="/dev/null"
  # shellcheck disable=SC2064
  trap "rm -f -- '${tmp}'" EXIT
  trap 'exit 143' TERM INT HUP
  [ -n "${FLEET_HOOK_PIDFILE:-}" ] && printf '%s\n' "$$" >> "${FLEET_HOOK_PIDFILE}"
  timeout "${limit}" "$@" </dev/null >/dev/null 2>"${tmp}"
  rc=$?
  [ "${rc}" -eq 0 ] && return 0
  if [ "${rc}" -eq 124 ]; then
    msg="fleet-report: ${kind} did not finish within ${limit}s and was killed. Fix: check the network and the server; the next report retries on its own."
  else
    msg="$(grep -m 1 'Fix:' "${tmp}" 2>/dev/null)"
    [ -n "${msg}" ] || msg="fleet-report: ${kind} failed (exit ${rc}) with no message. Fix: run ai/bin/fleet-report by hand for this kind to see why."
  fi
  fleet_record_failure "${sid}" "${kind}" "${msg}"
}

case "${1:-}" in
  --detached) shift; run_detached "$@"; exit 0 ;;
  --self-test) exec "${HOOK_DIR}/fleet-report.self-test.sh" ;;
  -h|--help)
    cat <<'EOF'
fleet-report.sh -- Claude Code hook (SessionStart, SessionEnd, PostToolUse).
Reads the hook JSON on stdin and reports to the fleet registry via
ai/bin/fleet-report, detached and throttled. Always exits 0. Writes stdout only
on SessionStart, and only to announce failed reports (it becomes session context).
  --self-test   run ai/hooks/fleet-report.self-test.sh
EOF
    exit 0 ;;
esac

# fail <session_id-or-empty> <message with Fix:> -- a refusal by the hook
# itself: stderr (verbose mode) AND the durable failure log.
fail() {
  printf 'fleet-report hook: %s\n' "$2" >&2
  fleet_record_failure "${1:--}" hook "fleet-report hook: $2" 2>/dev/null
}

command -v jq >/dev/null 2>&1 || { fail "" "jq is not on PATH, so nothing was reported. Fix: install jq."; exit 0; }

INPUT="$(cat 2>/dev/null)" || exit 0
[ -n "${INPUT}" ] || exit 0

fields="$(printf '%s' "${INPUT}" | jq -r '
  if type != "object" then empty else
  [ (.hook_event_name // ""), (.session_id // ""), (.cwd // ""),
    (.agent_id // ""), (.agent_type // ""), (.reason // "") ]
  | map(if type == "string" then . else tostring end | gsub("[\u001f\n]"; " "))
  | join("\u001f") end' 2>/dev/null)"
if [ -z "${fields}" ]; then
  fail "" "could not parse the hook JSON on stdin, so nothing was reported. Fix: report this; Claude Code's hook payload shape may have changed (DND-428 measured it)."
  exit 0
fi
# The separator is US (0x1f), not a tab: tab is IFS WHITESPACE, so empty fields
# (a top-level call has no agent_id) would collapse and shift every later one.
IFS=$'\x1f' read -r event sid cwd agent_id agent_type reason <<<"${fields}"

if ! fleet_valid_id "${sid}"; then
  fail "" "hook stdin has no usable session_id (${event:-unknown event}), so nothing was reported. Fix: report this; every hook payload carries the top-level session_id (DND-428)."
  exit 0
fi
[ -n "${agent_id}" ] && ! fleet_valid_id "${agent_id}" && agent_id=""

if ! seen_dir="$(fleet_seen_dir)"; then
  printf 'fleet-report hook: %s\n' "XDG_STATE_HOME (${XDG_STATE_HOME:-}) is not absolute, so nothing was reported and no failure can be logged. Fix: set XDG_STATE_HOME to an absolute path or unset it." >&2
  exit 0
fi
mkdir -p -- "${seen_dir}" 2>/dev/null || { printf 'fleet-report hook: cannot create %s, so nothing was reported. Fix: make it writable.\n' "${seen_dir}" >&2; exit 0; }

[ -d "${cwd}" ] && cd -- "${cwd}" 2>/dev/null

# detach <kind> <fleet-report args...> -- one background report: this script
# re-entered as `--detached`, in its own session (setsid -f), stdin and stdout
# closed, bounded by timeout.
detach() {
  local kind="$1"; shift
  setsid -f "${SELF}" --detached "${sid}" "${kind}" "$(fleet_seconds "${FLEET_HOOK_TIMEOUT_S:-}" 30)" "${BIN}" "$@" \
    </dev/null >/dev/null 2>&1
}

# announce_failures -- SessionStart only: one stdout line (session context) for
# failures logged since the last announcement; then advance the marker.
announce_failures() {
  local marker since lines n latest
  marker="$(fleet_surfaced_marker_path)" || return 0
  since="$(cat -- "${marker}" 2>/dev/null)"
  case "${since}" in ''|*[!0-9]*) since=0 ;; esac
  lines="$(fleet_failures_since "${since}")"
  [ -n "${lines}" ] || return 0
  n="$(printf '%s\n' "${lines}" | grep -c .)"
  latest="$(printf '%s\n' "${lines}" | tail -n 1)"
  fleet_failure_notice "${n}" "${latest}" "$(fleet_failure_log_path)"
  printf '%s\n' "${latest%%$'\t'*}" > "${marker}.tmp" && mv -f -- "${marker}.tmp" "${marker}"
}

case "${event}" in
  SessionStart)
    detach session_started session-start --session-id "${sid}" --cwd "${cwd:-${PWD}}"
    announce_failures ;;
  SessionEnd)
    if [ -n "${reason}" ]; then
      detach session_ended session-end --session-id "${sid}" --reason "${reason}"
    else
      detach session_ended session-end --session-id "${sid}"
    fi ;;
  PostToolUse)
    fleet_throttle_claim "$(fleet_throttle_key "${sid}" "${agent_id}")" "$(date +%s)" || exit 0
    kind="$(fleet_seen_kind "${agent_type}" "${agent_id}")"
    if [ "${kind}" = "admiral_seen" ]; then
      detach admiral_seen admiral-seen --session-id "${sid}" --agent-id "${agent_id}" --agent-type "${agent_type}"
    else
      set -- session-seen --session-id "${sid}"
      [ -n "${agent_id}" ] && set -- "$@" --agent-id "${agent_id}"
      [ -n "${agent_type}" ] && set -- "$@" --agent-type "${agent_type}"
      detach session_seen "$@"
    fi
    # Opportunistic housekeeping: stamps for sessions silent a day are dead.
    find "${seen_dir}" -maxdepth 1 -name '*.stamp' -mmin +1440 -delete 2>/dev/null ;;
  *) ;;
esac
exit 0
