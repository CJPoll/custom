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
# NEVER ADDS LATENCY, NEVER BLOCKS. The network call runs detached (setsid -f)
# under `timeout`, with stdin/stdout closed, so the hook returns as soon as it
# has parsed stdin and (for PostToolUse) checked the stamp. It always exits 0
# and never writes stdout (SessionStart stdout would become session context).
#
# FAILURE IS STILL VISIBLE. A detached report that fails leaves its one
# `Fix:` line in $XDG_STATE_HOME/athena/fleet/seen/<session_id>.last-error.
# The next due PostToolUse in that session prints it on stderr once and removes
# it. A failure this hook itself detects (unparseable stdin, no session_id)
# prints its own one-line `Fix:` on stderr.
#
# --self-test runs ai/hooks/fleet-report.self-test.sh (a hook reads stdin, so the
# suite is a dedicated file; harness-gate declares that file, never this one
# with a flag).

set -u

SELF="$(realpath -- "${BASH_SOURCE[0]}")"
HOOK_DIR="$(dirname -- "${SELF}")"
AI="$(cd -- "${HOOK_DIR}/.." && pwd -P)"
BIN="${AI}/bin/fleet-report"

case "${1:-}" in
  --self-test) exec "${HOOK_DIR}/fleet-report.self-test.sh" ;;
  -h|--help)
    cat <<'EOF'
fleet-report.sh -- Claude Code hook (SessionStart, SessionEnd, PostToolUse).
Reads the hook JSON on stdin and reports to the fleet registry via
ai/bin/fleet-report, detached and throttled. Always exits 0; never writes stdout.
  --self-test   run ai/hooks/fleet-report.self-test.sh
EOF
    exit 0 ;;
esac

say() { printf 'fleet-report hook: %s\n' "$*" >&2; }

command -v jq >/dev/null 2>&1 || { say "jq is not on PATH, so nothing was reported. Fix: install jq."; exit 0; }

INPUT="$(cat 2>/dev/null)" || exit 0
[ -n "${INPUT}" ] || exit 0

# shellcheck source=../lib/fleet/domain.sh
. "${AI}/lib/fleet/domain.sh"
# shellcheck source=../lib/fleet/effects.sh
. "${AI}/lib/fleet/effects.sh"

fields="$(printf '%s' "${INPUT}" | jq -r '
  if type != "object" then empty else
  [ (.hook_event_name // ""), (.session_id // ""), (.cwd // ""),
    (.agent_id // ""), (.agent_type // ""), (.reason // "") ]
  | map(if type == "string" then . else tostring end | gsub("[\u001f\n]"; " "))
  | join("\u001f") end' 2>/dev/null)"
if [ -z "${fields}" ]; then
  say "could not parse the hook JSON on stdin, so nothing was reported. Fix: report this; Claude Code's hook payload shape may have changed (DND-428 measured it)."
  exit 0
fi
# The separator is US (0x1f), not a tab: tab is IFS WHITESPACE, so empty fields
# (a top-level call has no agent_id) would collapse and shift every later one.
IFS=$'\x1f' read -r event sid cwd agent_id agent_type reason <<<"${fields}"

if ! fleet_valid_id "${sid}"; then
  say "hook stdin has no usable session_id (${event:-unknown event}), so nothing was reported. Fix: report this; every hook payload carries the top-level session_id (DND-428)."
  exit 0
fi
[ -n "${agent_id}" ] && ! fleet_valid_id "${agent_id}" && agent_id=""

if ! seen_dir="$(fleet_seen_dir)"; then
  say "XDG_STATE_HOME (${XDG_STATE_HOME:-}) is not absolute, so nothing was reported. Fix: set XDG_STATE_HOME to an absolute path or unset it."
  exit 0
fi
mkdir -p -- "${seen_dir}" 2>/dev/null || { say "cannot create ${seen_dir}, so nothing was reported. Fix: make it writable."; exit 0; }
err_file="${seen_dir}/${sid}.last-error"

[ -d "${cwd}" ] && cd -- "${cwd}" 2>/dev/null

# detach <label> <fleet-report args...>
# One background report: its own session (setsid -f), stdin/stdout closed,
# bounded by timeout, its temp stderr removed by a trap, and promoted to the
# session's last-error file only when the report failed.
detach() {
  local label="$1"; shift
  setsid -f bash -c '
    err="$1"; label="$2"; limit="$3"; shift 3
    tmp="${err}.$$.tmp"
    trap '\''rm -f -- "${tmp}"'\'' EXIT
    trap '\''exit 143'\'' TERM INT HUP
    [ -n "${FLEET_HOOK_PIDFILE:-}" ] && printf "%s\n" "$$" >> "${FLEET_HOOK_PIDFILE}"
    timeout "${limit}" "$@" </dev/null >/dev/null 2>"${tmp}"
    rc=$?
    [ "${rc}" -eq 0 ] && exit 0
    if [ "${rc}" -eq 124 ]; then
      printf "fleet-report: %s did not finish within %ss and was killed. Fix: check the network and the server; the next report retries on its own.\n" "${label}" "${limit}" >> "${tmp}"
    fi
    mv -f -- "${tmp}" "${err}"
  ' fleet-report-detached "${err_file}" "${label}" "${FLEET_HOOK_TIMEOUT_S:-30}" "${BIN}" "$@" \
    </dev/null >/dev/null 2>&1
}

case "${event}" in
  SessionStart)
    detach session_started session-start --session-id "${sid}" --cwd "${cwd:-${PWD}}" ;;
  SessionEnd)
    if [ -n "${reason}" ]; then
      detach session_ended session-end --session-id "${sid}" --reason "${reason}"
    else
      detach session_ended session-end --session-id "${sid}"
    fi ;;
  PostToolUse)
    fleet_throttle_claim "$(fleet_throttle_key "${sid}" "${agent_id}")" "$(date +%s)" || exit 0
    if [ -s "${err_file}" ]; then
      say "an earlier background report failed:"
      head -n 3 -- "${err_file}" >&2
      rm -f -- "${err_file}"
    fi
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
