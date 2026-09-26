#!/usr/bin/env bash
# fleet-drain-guard.sh -- PreToolUse hook (matcher `Agent|Task`): refuse a
# fleet-worker spawn while this Claude session is draining. The PRIMARY drain
# layer (DND-443). Contract: ai/contracts/athena-events.md -> *Fleet registry
# and session control* -> *Enforcement layers* -> *Layer 1: the drain guard
# hook*. DND-428 measured every property this relies on (Claude Code 2.1.281):
# the hook fires for Agent calls made by the top-level session AND by any
# subagent, stdin's session_id is the top-level session at every depth, and a
# `permissionDecision: deny` stops the spawn in default, auto and
# bypassPermissions modes.
#
#   * Keys ONLY on tool_input.subagent_type. athena-admiral and athena-captain
#     are fleet workers; every other spawn (architect, critic, Explore, the
#     default agent when subagent_type is absent) passes untouched and without
#     a server call. Never keys on run_in_background (absent when the harness
#     backgrounds a spawn on its own) or on agent_id.
#   * Identity is stdin's session_id, never anything in tool_input.
#   * Asks `ai/bin/fleet-control check`, which asks the SERVER first: a stale
#     `drain` cache cannot refuse a resume while the server answers.
#   * drain (exit 3) -> deny, with the contract's pinned Fix: as the reason.
#     The caller sees it as `PreToolUse:Agent hook error: <reason>`.
#   * run (exit 0) on basis `server` -> silent pass. On any other basis the
#     spawn passes (the owner's fail-mode rule said run) WITH the warning,
#     surfaced to the transcript (systemMessage for the human,
#     additionalContext for the model): hook stderr on exit 0 reaches nobody.
#   * Anything else -- stdin it cannot parse, a fleet spawn with no usable
#     session_id, a fleet-control error or timeout -- is DENIED with a Fix:
#     naming the problem. A spawn it cannot classify or look up is one it
#     cannot clear.
#
# Every fleet-worker decision is appended to
# $XDG_STATE_HOME/athena/fleet/drain-guard.log (evidence for a live verify).
#
# Every DENY of a fleet worker is also reported to the fleet registry as
# `agent_end` by tool_use_id, outcome `spawn_denied` (DND-560; contract, "Who
# sends what"), detached through ai/bin/fleet-report so it never delays or
# changes the decision. A failed report lands in report-failures.log with Fix:.
#
# --self-test runs ai/hooks/fleet-drain-guard.self-test.sh.

set -u

SELF="$(realpath -- "${BASH_SOURCE[0]}")"
HOOK_DIR="$(dirname -- "${SELF}")"
AI="$(cd -- "${HOOK_DIR}/.." && pwd -P)"
BIN="${AI}/bin/fleet-control"
LIMIT_S=20

case "${1:-}" in
  --self-test) exec "${HOOK_DIR}/fleet-drain-guard.self-test.sh" ;;
  -h|--help)
    cat <<'EOF'
fleet-drain-guard.sh -- Claude Code PreToolUse hook (matcher Agent|Task).
Reads the hook JSON on stdin. Denies an athena-admiral / athena-captain spawn
while `ai/bin/fleet-control check` says this session is draining; passes every
other spawn untouched. Unknown control state passes or denies per the owner's
fail-mode rule, always with a visible warning.
  --self-test   run ai/hooks/fleet-drain-guard.self-test.sh
EOF
    exit 0 ;;
esac

# deny_raw <reason> -- the refusal when jq itself is missing: exit 2 with the
# reason on stderr, which Claude Code feeds back to the caller as a block.
deny_raw() {
  printf '%s\n' "$1" >&2
  exit 2
}

command -v jq >/dev/null 2>&1 || deny_raw "fleet-drain-guard: jq is not on PATH, so this spawn cannot be classified and was refused. Fix: install jq; until then fleet spawns cannot be cleared."

# shellcheck source=../lib/fleet/domain.sh
. "${AI}/lib/fleet/domain.sh"
# shellcheck source=../lib/fleet/control-domain.sh
. "${AI}/lib/fleet/control-domain.sh"
# shellcheck source=../lib/fleet/effects.sh
. "${AI}/lib/fleet/effects.sh"
# shellcheck source=../lib/fleet/control-effects.sh
. "${AI}/lib/fleet/control-effects.sh"
# shellcheck source=../lib/fleet/control-manager.sh
. "${AI}/lib/fleet/control-manager.sh"
# shellcheck source=../lib/fleet/manager.sh
. "${AI}/lib/fleet/manager.sh"

# The body of the detached spawn_denied report (report_denied below).
if [ "${1:-}" = "--detached" ]; then
  shift
  fleet_run_detached "$@"
  exit 0
fi

sid="" subagent_type="" cwd="" tool_use_id=""

# report_denied -- DND-560: a fleet-worker spawn this guard denies is reported
# as agent_end spawn_denied by its tool_use_id, detached and bounded, so a
# refused spawn never reads as a pending captain on the fleet page (contract,
# "Who sends what"). It never changes the decision and never delays it. A deny
# with no usable session_id or tool_use_id cannot be joined to its spawn; that
# is logged, not sent.
report_denied() {
  fleet_is_fleet_worker "${subagent_type}" || return 0
  fleet_valid_id "${sid}" || return 0   # the no-session_id deny is already logged by fleet_guard_record
  if ! fleet_valid_id "${tool_use_id}"; then
    fleet_log_failure "${sid}" agent_end "fleet-drain-guard: denied a ${subagent_type} spawn whose stdin carries no usable tool_use_id (${tool_use_id@Q}), so its spawn_denied was not reported. Fix: report this; DND-541 measured tool_use_id on every PreToolUse(Agent)." 2>/dev/null
    return 0
  fi
  (
    case "${cwd}" in /*) [ -d "${cwd}" ] && cd -- "${cwd}" 2>/dev/null ;; esac
    setsid -f "${SELF}" --detached "${sid}" agent_end "$(fleet_seconds "${FLEET_HOOK_TIMEOUT_S:-}" 30)" \
      "${AI}/bin/fleet-report" agent-end --session-id "${sid}" --tool-use-id "${tool_use_id}" \
      --agent-type "${subagent_type}" --outcome spawn_denied </dev/null >/dev/null 2>&1
  )
  return 0
}

# emit <reason-or-empty> <warning-or-empty>
# A deny when <reason> is set; otherwise a pass that carries the warning. A
# pass with no warning prints nothing.
emit() {
  local reason="$1" warning="$2"
  if [ -n "${reason}" ]; then
    report_denied
    jq -n -c --arg r "${reason}" --arg w "${warning}" \
      '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $r}}
       + (if $w == "" then {} else {systemMessage: $w} end)'
  elif [ -n "${warning}" ]; then
    jq -n -c --arg w "${warning}" \
      '{systemMessage: $w, hookSpecificOutput: {hookEventName: "PreToolUse", additionalContext: $w}}'
  fi
  exit 0
}

INPUT="$(cat 2>/dev/null)"
fields="$(printf '%s' "${INPUT}" | jq -r '
  if type != "object" then error("not an object") else
  [ (.session_id // ""), (.tool_input.subagent_type // ""), (.cwd // ""), (.tool_use_id // "") ]
  | map(if type == "string" then . else tostring end | gsub("[\u001f\n]"; " "))
  | join("\u001f") end' 2>/dev/null)" || fields=""
if [ -z "${fields}" ]; then
  emit "fleet-drain-guard: the hook JSON on stdin could not be parsed, so this spawn could not be classified and was refused. Fix: report this (Claude Code's hook payload shape may have changed; DND-428 measured it), and do not retry the spawn in a loop." ""
fi
IFS=$'\x1f' read -r sid subagent_type cwd tool_use_id <<<"${fields}"

# Not a fleet worker: pass untouched, no server call, no log line.
fleet_is_fleet_worker "${subagent_type}" || exit 0

if ! fleet_valid_id "${sid}"; then
  fleet_guard_record "-" "${subagent_type}" deny "no usable session_id"
  emit "fleet-drain-guard: this ${subagent_type} spawn carries no usable session_id on the hook's stdin, so its session's control state cannot be looked up and the spawn was refused. Fix: report this (every PreToolUse payload carries the top-level session_id; DND-428); do not retry the spawn." ""
fi

set -- check --session-id "${sid}"
case "${cwd}" in /*) [ -d "${cwd}" ] && set -- "$@" --cwd "${cwd}" ;; esac

errf="$(mktemp 2>/dev/null)" || errf=""
if [ -n "${errf}" ]; then
  # shellcheck disable=SC2064
  trap "rm -f -- '${errf}'" EXIT
  out="$(timeout "${LIMIT_S}" "${BIN}" "$@" 2>"${errf}")"; rc=$?
  err="$(grep -v '^[[:space:]]*$' "${errf}" | tr '\n' ' ' | sed 's/ *$//')"
else
  out="$(timeout "${LIMIT_S}" "${BIN}" "$@" 2>/dev/null)"; rc=$?
  err="fleet-drain-guard: could not capture fleet-control's warnings (no temp file), so this answer's basis could not be checked for a warning."
fi

# desired=<d> reason=<r> until=<u> basis=<b>
desired="" reason="" until="" basis=""
for kv in ${out}; do
  case "${kv}" in
    desired=*) desired="${kv#desired=}" ;;
    reason=*)  reason="${kv#reason=}" ;;
    until=*)   until="${kv#until=}" ;;
    basis=*)   basis="${kv#basis=}" ;;
  esac
done
[ "${until}" = "unbounded" ] && until=""

case "${rc}" in
  0)
    if [ "${desired}" != "run" ] || [ -z "${basis}" ]; then
      fleet_guard_record "${sid}" "${subagent_type}" deny "exit 0 without a run line"
      emit "fleet-drain-guard: fleet-control check exited 0 but did not print a run answer, so this spawn could not be cleared and was refused. Fix: run ai/bin/fleet-control check --session-id ${sid} and report what it prints." "${err}"
    fi
    fleet_guard_record "${sid}" "${subagent_type}" allow "${basis}"
    if [ "${basis}" != "server" ] && [ -z "${err}" ]; then
      err="fleet-control: WARNING control state is unknown, so this answer is basis ${basis}, not the server. Fix: run ai/bin/fleet-control fetch to see why."
    fi
    emit "" "${err}" ;;
  3)
    fleet_guard_record "${sid}" "${subagent_type}" deny "${basis}"
    emit "$(fleet_drain_fix "${sid}" "${reason:-unknown}" "${until}" "${basis:-unknown}")" "${err}" ;;
  124)
    fleet_guard_record "${sid}" "${subagent_type}" deny "fleet-control timed out"
    emit "fleet-drain-guard: fleet-control check did not answer within ${LIMIT_S}s, so this ${subagent_type} spawn could not be cleared and was refused. Fix: treat it as PAUSE (do not retry in a loop); check the server and ai/bin/fleet-control check by hand." "${err}" ;;
  *)
    fleet_guard_record "${sid}" "${subagent_type}" deny "fleet-control exit ${rc}"
    emit "fleet-drain-guard: fleet-control check failed (exit ${rc}), so this ${subagent_type} spawn could not be cleared and was refused: ${err:-no message}. Fix: act on that message; an error is never read as run, so treat this as PAUSE and do not retry in a loop." "" ;;
esac
