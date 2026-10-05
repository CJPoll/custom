#!/usr/bin/env bash
# fleet-lifecycle.sh -- the fleet-worker lifecycle hook (DND-560). Reports the
# FACTS of each athena-admiral / athena-captain spawn, start and end to the
# Athena fleet registry through ai/bin/fleet-report; the server derives every
# state from them. Contract: ai/contracts/athena-events.md -> *Fleet report
# kinds and their closed schema* -> "Who sends what", *Agent lifecycle* (and
# *Run binding*), *Mission pointers are metadata only*.
#
#   PreToolUse (Agent|Task), fleet subagent_type   -> agent_spawn
#       captain: ticket_ref parsed locally from the description, else a
#       `Mission: <REF>` prompt line; none -> mapping unmapped, LOUD (below).
#       admiral: mapping not_applicable. Both: run_hint = the one distinct
#       ai-artifacts/coordination/<dir>/ in the prompt. The description and
#       prompt never leave the machine.
#   PostToolUse (Agent|Task), tool_response.agentId -> agent_bound
#   PostToolUseFailure (Agent|Task)                  -> agent_end spawn_failed
#       (error_class from the failure text's `error type <class>`, else other)
#   SubagentStart                                    -> agent_start
#   SubagentStop                                     -> agent_end stopped
#   StopFailure with an agent_id                     -> agent_end api_error
#   Anything else (a non-fleet type, the top-level session's own StopFailure,
#   another event) sends nothing and logs nothing.
#
# ADVISORY, NEVER A GATE. It never prints a permissionDecision and always exits
# 0 (an EXIT trap forces it, whatever happens above it). Enforcement stays in
# fleet-drain-guard.sh. The only stdout it ever writes is the unmapped-captain
# notice, as PreToolUse hookSpecificOutput.additionalContext, so the spawning
# admiral sees it and the call proceeds.
#
# NEVER ADDS LATENCY. Each report runs detached (setsid -f, re-entering this
# script as `--detached`) under timeout(1), stdin and stdout closed; the hook
# returns once it has parsed stdin. Not throttled: these events are rare.
#
# FAILURE IS STILL VISIBLE. Hook stderr on exit 0 reaches nobody, so every
# failed report, every refusal of its own (unparseable stdin, no session_id, a
# fleet event with an unusable id) and every unmapped captain is appended with
# its `Fix:` to $XDG_STATE_HOME/athena/fleet/report-failures.log, which the
# next SessionStart announces (fleet-report.sh).
#
# --self-test runs ai/hooks/fleet-lifecycle.self-test.sh (declared in
# harness-gate by that file's path).

set -u
trap 'exit 0' EXIT

SELF="$(realpath -- "${BASH_SOURCE[0]}")"
HOOK_DIR="$(dirname -- "${SELF}")"
AI="$(cd -- "${HOOK_DIR}/.." && pwd -P)"
BIN="${AI}/bin/fleet-report"

case "${1:-}" in
  --self-test) trap - EXIT; exec "${HOOK_DIR}/fleet-lifecycle.self-test.sh" ;;
  -h|--help)
    cat <<'EOF'
fleet-lifecycle.sh -- Claude Code hook (PreToolUse / PostToolUse /
PostToolUseFailure on Agent|Task; SubagentStart; SubagentStop; StopFailure).
Reads the hook JSON on stdin and reports athena-admiral / athena-captain
spawns, starts and ends to the fleet registry via ai/bin/fleet-report,
detached. Always exits 0 and never denies. Writes stdout only for a captain
spawn that names no single ticket ref (additionalContext, no permissionDecision).
  --self-test   run ai/hooks/fleet-lifecycle.self-test.sh
EOF
    exit 0 ;;
esac

# shellcheck source=../lib/fleet/domain.sh
. "${AI}/lib/fleet/domain.sh"
# shellcheck source=../lib/fleet/effects.sh
. "${AI}/lib/fleet/effects.sh"
# shellcheck source=../lib/fleet/manager.sh
. "${AI}/lib/fleet/manager.sh"

if [ "${1:-}" = "--detached" ]; then
  shift
  trap - EXIT
  fleet_run_detached "$@"
  exit 0
fi

# fail <session_id-or-empty> <message with Fix:> -- a refusal by the hook
# itself: stderr (verbose mode) AND the durable failure log.
fail() {
  printf 'fleet-lifecycle hook: %s\n' "$2" >&2
  fleet_log_failure "${1:--}" lifecycle "fleet-lifecycle hook: $2" 2>/dev/null
}

command -v jq >/dev/null 2>&1 || { fail "" "jq is not on PATH, so no fleet lifecycle fact was reported. Fix: install jq."; exit 0; }

INPUT="$(cat 2>/dev/null)" || exit 0
[ -n "${INPUT}" ] || exit 0

fields="$(printf '%s' "${INPUT}" | jq -r '
  if type != "object" then empty else
  [ (.hook_event_name // ""), (.session_id // ""), (.cwd // ""), (.tool_name // ""),
    (.agent_id // ""), (.agent_type // ""), (.tool_use_id // ""),
    ((.tool_input | objects | .subagent_type) // ""),
    ((.tool_response | objects | .agentId) // ""),
    (.error // "") ]
  | map(if type == "string" then . else tostring end | gsub("[\u001f\n]"; " "))
  | join("\u001f") end' 2>/dev/null)"
if [ -z "${fields}" ]; then
  fail "" "could not parse the hook JSON on stdin, so no fleet lifecycle fact was reported. Fix: report this; Claude Code's hook payload shape may have changed (DND-541 measured it on 2.1.282)."
  exit 0
fi
# US (0x1f), not tab: tab is IFS whitespace, so empty fields would collapse.
IFS=$'\x1f' read -r event sid cwd tool_name agent_id agent_type tool_use_id subagent_type bound_id error <<<"${fields}"

# The fleet type this event is about: the spawned type on the Agent-tool
# events, the agent's own type on the Subagent*/StopFailure events.
case "${event}" in
  PreToolUse|PostToolUse|PostToolUseFailure)
    case "${tool_name}" in Agent|Task) ;; *) exit 0 ;; esac
    worker="${subagent_type}" ;;
  SubagentStart|SubagentStop|StopFailure)
    worker="${agent_type}" ;;
  *) exit 0 ;;
esac
fleet_is_fleet_worker "${worker}" || exit 0
# The top-level session's own StopFailure carries no agent_id: nothing to end.
[ "${event}" = "StopFailure" ] && [ -z "${agent_id}" ] && exit 0

if ! fleet_valid_id "${sid}"; then
  fail "" "a ${worker} ${event} carries no usable session_id, so it was not reported. Fix: report this; every hook payload carries the top-level session_id (DND-428)."
  exit 0
fi
if ! fleet_state_usable; then
  printf 'fleet-lifecycle hook: %s\n' "XDG_STATE_HOME (${XDG_STATE_HOME:-}) is not absolute, so nothing was reported and no failure can be logged. Fix: set XDG_STATE_HOME to an absolute path or unset it." >&2
  exit 0
fi

# bad_id <what> <value> -- a fleet event whose join key is unusable is logged,
# never silently dropped (an unjoinable report is a lost lifecycle fact).
bad_id() {
  fail "${sid}" "a ${worker} ${event} carries no usable $1 (${2@Q}), so it was not reported. Fix: report this; DND-541 measured ${1} on this event (Claude Code 2.1.282)."
  exit 0
}

[ -d "${cwd}" ] && cd -- "${cwd}" 2>/dev/null

# detach <kind> <fleet-report args...> -- one background report, bounded.
detach() {
  local kind="$1"; shift
  setsid -f "${SELF}" --detached "${sid}" "${kind}" "$(fleet_seconds "${FLEET_HOOK_TIMEOUT_S:-}" 30)" \
    "${BIN}" "$@" --session-id "${sid}" </dev/null >/dev/null 2>&1
}

case "${event}" in
  PreToolUse)
    fleet_valid_id "${tool_use_id}" || bad_id tool_use_id "${tool_use_id}"
    [ -z "${agent_id}" ] || fleet_valid_id "${agent_id}" || bad_id "agent_id (the caller)" "${agent_id}"
    description="$(printf '%s' "${INPUT}" | jq -r '(.tool_input | objects | .description) // "" | strings' 2>/dev/null)"
    prompt="$(printf '%s' "${INPUT}" | jq -r '(.tool_input | objects | .prompt) // "" | strings' 2>/dev/null)"
    set -- agent-spawn --tool-use-id "${tool_use_id}" --subagent-type "${worker}"
    [ -n "${agent_id}" ] && set -- "$@" --caller-agent-id "${agent_id}"
    hint="$(fleet_parse_run_hint "${prompt}")" && set -- "$@" --run-hint "${hint}"
    if [ "${worker}" = "athena-admiral" ]; then
      set -- "$@" --mapping not_applicable
    else
      parsed="$(fleet_parse_ticket_ref "${description}" "${prompt}")"
      case "${parsed}" in
        "mapped "*) set -- "$@" --mapping mapped --ticket-ref "${parsed#mapped }" ;;
        *)
          set -- "$@" --mapping unmapped
          fleet_log_failure "${sid}" agent_spawn "fleet-lifecycle: athena-captain spawn ${tool_use_id} (caller ${agent_id:-top level}) names no single ticket ref and was reported as an unmapped captain. $(fleet_unmapped_notice | sed 's/^.*\(Fix: \)/\1/')" 2>/dev/null
          jq -n -c --arg c "$(fleet_unmapped_notice)" \
            '{hookSpecificOutput: {hookEventName: "PreToolUse", additionalContext: $c}}' ;;
      esac
    fi
    detach agent_spawn "$@" ;;
  PostToolUse)
    # A spawn whose response carries no agentId (not measured, but possible) is
    # not an error: agent_start and agent_end still report the agent.
    [ -n "${bound_id}" ] || exit 0
    fleet_valid_id "${tool_use_id}" || bad_id tool_use_id "${tool_use_id}"
    fleet_valid_id "${bound_id}" || bad_id "tool_response.agentId" "${bound_id}"
    detach agent_bound agent-bound --tool-use-id "${tool_use_id}" --agent-id "${bound_id}" --agent-type "${worker}" ;;
  PostToolUseFailure)
    fleet_valid_id "${tool_use_id}" || bad_id tool_use_id "${tool_use_id}"
    detach agent_end agent-end --tool-use-id "${tool_use_id}" --agent-type "${worker}" \
      --outcome spawn_failed --error-class "$(fleet_failure_error_class "${error}")" ;;
  SubagentStart)
    fleet_valid_id "${agent_id}" || bad_id agent_id "${agent_id}"
    detach agent_start agent-start --agent-id "${agent_id}" --agent-type "${worker}" ;;
  SubagentStop)
    fleet_valid_id "${agent_id}" || bad_id agent_id "${agent_id}"
    detach agent_end agent-end --agent-id "${agent_id}" --agent-type "${worker}" --outcome stopped ;;
  StopFailure)
    fleet_valid_id "${agent_id}" || bad_id agent_id "${agent_id}"
    detach agent_end agent-end --agent-id "${agent_id}" --agent-type "${worker}" \
      --outcome api_error --error-class "$(fleet_error_class "${error}")" ;;
esac
exit 0
