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

# emit <reason-or-empty> <warning-or-empty>
# A deny when <reason> is set; otherwise a pass that carries the warning. A
# pass with no warning prints nothing.
emit() {
  local reason="$1" warning="$2"
  if [ -n "${reason}" ]; then
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
  [ (.session_id // ""), (.tool_input.subagent_type // ""), (.cwd // "") ]
  | map(if type == "string" then . else tostring end | gsub("[\u001f\n]"; " "))
  | join("\u001f") end' 2>/dev/null)" || fields=""
if [ -z "${fields}" ]; then
  emit "fleet-drain-guard: the hook JSON on stdin could not be parsed, so this spawn could not be classified and was refused. Fix: report this (Claude Code's hook payload shape may have changed; DND-428 measured it), and do not retry the spawn in a loop." ""
fi
IFS=$'\x1f' read -r sid subagent_type cwd <<<"${fields}"

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
