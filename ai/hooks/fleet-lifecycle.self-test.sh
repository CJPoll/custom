#!/usr/bin/env bash
# Self-test for ai/hooks/fleet-lifecycle.sh (DND-560), against the loopback
# fake server in ai/lib/fleet/test/. Never prod. Declared in harness-gate by
# THIS file's path (the hook reads stdin, so `fleet-lifecycle.sh --self-test`
# just execs this).
#
# 1. Replays every measured payload in ai/hooks/fixtures/fleet-lifecycle-
#    measured.jsonl (Claude Code 2.1.282 stdin, DND-541) and asserts the exact
#    report each one sends, or that it sends none.
# 2. The unmapped captain is loud three ways and never denied (contract,
#    *Mission pointers are metadata only*): agent_spawn unmapped, a failure-log
#    line with Fix:, and stdout additionalContext equal to the pinned notice,
#    with NO permissionDecision.
# 3. Prompt and description text never leave the machine.
# 4. The hook always exits 0 and never blocks: server down, 422, a timeout,
#    jq missing, garbage stdin. Each failure is in report-failures.log with Fix:.
# 5. It never adds latency: it returns while the server's answer is still
#    held (DND-1007: an event, not a wall-clock budget).

set -u

HOOK="$(cd -- "$(dirname -- "$0")" && pwd -P)/fleet-lifecycle.sh"
AI="$(cd -- "$(dirname -- "${HOOK}")/.." && pwd -P)"
FAKE="${AI}/lib/fleet/test/fake-fleet-server.py"
FIXTURES="${AI}/hooks/fixtures/fleet-lifecycle-measured.jsonl"
QUOTED="${AI}/contracts/fixtures/athena-events-quoted-fix.txt"

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); printf 'ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf 'FAIL %s\n' "$1"; [ -n "${2:-}" ] && printf '     %s\n' "$2"; return 0; }
eq()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$3], got [$2]"; fi; }
has() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "[$3] not in [$2]" ;; esac; }

for dep in jq curl python3 git flock setsid timeout; do
  command -v "${dep}" >/dev/null 2>&1 || { echo "fleet-lifecycle hook self-test: FAIL -- ${dep} is not on PATH"; echo "  Fix: install ${dep}; this suite does not skip."; exit 1; }
done
[ -s "${FIXTURES}" ] || { echo "fleet-lifecycle hook self-test: FAIL -- ${FIXTURES} is missing or empty"; echo "  Fix: restore it from git; it carries DND-541's measured hook payloads."; exit 1; }

TMP="$(mktemp -d)" || { echo "FAIL mktemp"; exit 1; }
SERVER_PID=""
PIDS="${TMP}/pids"
cleanup() {
  [ -n "${SERVER_PID}" ] && kill "${SERVER_PID}" 2>/dev/null
  if [ -f "${PIDS}" ]; then
    while read -r p; do [ -n "${p}" ] && kill "${p}" 2>/dev/null; done < "${PIDS}"
  fi
  rm -rf "${TMP}"
}
trap cleanup EXIT INT TERM

# shellcheck source=../lib/fleet/test/helpers.sh
. "${AI}/lib/fleet/test/helpers.sh"
fleet_fixture_env
export FLEET_HOOK_PIDFILE="${PIDS}"
fleet_start_server || exit 1
LOG="${XDG_STATE_HOME}/athena/fleet/report-failures.log"
logn() { local c; c="$(cat "${LOG}.1" "${LOG}" 2>/dev/null | grep -c .)"; printf '%s\n' "${c:-0}"; }

# hook <json> -- run the hook with stdin; sets RC, OUT, ERR.
hook() {
  OUT="$(printf '%s' "$1" | "${HOOK}" 2>"${TMP}/err")"; RC=$?
  ERR="$(cat "${TMP}/err")"
}
fixture() { jq -c --arg id "$1" 'select(.id == $id) | .stdin' "${FIXTURES}"; }

# The body each measured payload must send, minus claude_session_id (asserted
# separately against the payload's own session_id). "none" = sends nothing.
declare -A WANT=(
  [a.1-PreToolUse-athena-admiral]='{"kind":"agent_spawn","tool_use_id":"toolu_01FxUwz9M5UTfB9pfoMbBTYn","subagent_type":"athena-admiral","mapping":"not_applicable"}'
  [a.2-SubagentStart-athena-admiral]='{"kind":"agent_start","agent_id":"a81c553e42da805c2","agent_type":"athena-admiral"}'
  [a.3-PreToolUse-general-purpose]=none
  [a.4-SubagentStart-general-purpose]=none
  [a.5-SubagentStop-general-purpose]=none
  [a.6-PostToolUse-general-purpose]=none
  [a.7-PreToolUse-general-purpose]=none
  [a.8-SubagentStart-general-purpose]=none
  [a.9-PostToolUse-general-purpose]=none
  [a.10-SubagentStop-athena-admiral]='{"kind":"agent_end","agent_id":"a81c553e42da805c2","agent_type":"athena-admiral","outcome":"stopped"}'
  [a.11-PostToolUse-athena-admiral]='{"kind":"agent_bound","tool_use_id":"toolu_01FxUwz9M5UTfB9pfoMbBTYn","agent_id":"a81c553e42da805c2","agent_type":"athena-admiral"}'
  [a.12-SubagentStop-general-purpose]=none
  [b1.1-PreToolUse-athena-admiral]='{"kind":"agent_spawn","tool_use_id":"toolu_01AzDx8pSjyFFrmnj8bPLokq","subagent_type":"athena-admiral","mapping":"not_applicable"}'
  [b1.2-SubagentStart-athena-admiral]='{"kind":"agent_start","agent_id":"a75e477230f8af78f","agent_type":"athena-admiral"}'
  [b1.3-PreToolUse-athena-captain]='{"kind":"agent_spawn","tool_use_id":"toolu_015vBe6dE4ZPphWNsBmUvZVR","subagent_type":"athena-captain","mapping":"mapped","caller_agent_id":"a75e477230f8af78f","ticket_ref":"DND-9005"}'
  [b1.4-SubagentStart-athena-captain]='{"kind":"agent_start","agent_id":"a88103306387f4ded","agent_type":"athena-captain"}'
  [b1.5-PostToolUseFailure-athena-captain]='{"kind":"agent_end","tool_use_id":"toolu_015vBe6dE4ZPphWNsBmUvZVR","agent_type":"athena-captain","outcome":"spawn_failed","error_class":"rate_limit"}'
  [b1.6-StopFailure-athena-captain]='{"kind":"agent_end","agent_id":"a88103306387f4ded","agent_type":"athena-captain","outcome":"api_error","error_class":"rate_limit"}'
  [b1.7-SubagentStop-athena-admiral]='{"kind":"agent_end","agent_id":"a75e477230f8af78f","agent_type":"athena-admiral","outcome":"stopped"}'
  [b1.8-PostToolUse-athena-admiral]='{"kind":"agent_bound","tool_use_id":"toolu_01AzDx8pSjyFFrmnj8bPLokq","agent_id":"a75e477230f8af78f","agent_type":"athena-admiral"}'
  [b2.1-PreToolUse-athena-captain]='{"kind":"agent_spawn","tool_use_id":"toolu_01AhYJL1BvtasxuEEL4jsnLX","subagent_type":"athena-captain","mapping":"mapped","ticket_ref":"DND-9006"}'
  [b2.2-SubagentStart-athena-captain]='{"kind":"agent_start","agent_id":"af74a79cee511cbd8","agent_type":"athena-captain"}'
  [b2.3-PostToolUse-athena-captain]='{"kind":"agent_bound","tool_use_id":"toolu_01AhYJL1BvtasxuEEL4jsnLX","agent_id":"af74a79cee511cbd8","agent_type":"athena-captain"}'
  [b2.4-StopFailure-athena-captain]='{"kind":"agent_end","agent_id":"af74a79cee511cbd8","agent_type":"athena-captain","outcome":"api_error","error_class":"rate_limit"}'
  [b2.5-PreToolUse-athena-admiral]='{"kind":"agent_spawn","tool_use_id":"toolu_01Hhzo8871gdR7U3LVJHhU7u","subagent_type":"athena-admiral","mapping":"not_applicable"}'
  [b2.6-SubagentStart-athena-admiral]='{"kind":"agent_start","agent_id":"a65222ddd2324f20f","agent_type":"athena-admiral"}'
  [b2.7-StopFailure-athena-admiral]='{"kind":"agent_end","agent_id":"a65222ddd2324f20f","agent_type":"athena-admiral","outcome":"api_error","error_class":"rate_limit"}'
  [b2.8-PostToolUseFailure-athena-admiral]='{"kind":"agent_end","tool_use_id":"toolu_01Hhzo8871gdR7U3LVJHhU7u","agent_type":"athena-admiral","outcome":"spawn_failed","error_class":"rate_limit"}'
  [b3.1-PreToolUse-athena-captain]='{"kind":"agent_spawn","tool_use_id":"toolu_01PtQUubuJRUt5jT15KCnbR2","subagent_type":"athena-captain","mapping":"mapped","ticket_ref":"DND-9008"}'
  [b3.2-SubagentStart-athena-captain]='{"kind":"agent_start","agent_id":"ac8af58287e0387cc","agent_type":"athena-captain"}'
  [b3.3-StopFailure-athena-captain]='{"kind":"agent_end","agent_id":"ac8af58287e0387cc","agent_type":"athena-captain","outcome":"api_error","error_class":"unknown"}'
  [b3.4-PostToolUseFailure-athena-captain]='{"kind":"agent_end","tool_use_id":"toolu_01PtQUubuJRUt5jT15KCnbR2","agent_type":"athena-captain","outcome":"spawn_failed","error_class":"unknown"}'
  [c2.1-PreToolUse-athena-captain]='{"kind":"agent_spawn","tool_use_id":"toolu_01LjzoDAUgrrV6AHomDLz7ZT","subagent_type":"athena-captain","mapping":"mapped","ticket_ref":"DND-9003"}'
  [c2.2-SubagentStart-athena-captain]='{"kind":"agent_start","agent_id":"a2cfba0fb42e41c92","agent_type":"athena-captain"}'
  [c2.3-PostToolUse-athena-captain]='{"kind":"agent_bound","tool_use_id":"toolu_01LjzoDAUgrrV6AHomDLz7ZT","agent_id":"a2cfba0fb42e41c92","agent_type":"athena-captain"}'
  [e.1-PreToolUse-athena-captain]='{"kind":"agent_spawn","tool_use_id":"toolu_01UMRB6Sg7zKJ8mBbbvpVyF3","subagent_type":"athena-captain","mapping":"mapped","ticket_ref":"DND-9009"}'
  [e.2-SubagentStart-athena-captain]='{"kind":"agent_start","agent_id":"ae2c37d099fc2520d","agent_type":"athena-captain"}'
  [e.3-SubagentStop-athena-captain]='{"kind":"agent_end","agent_id":"ae2c37d099fc2520d","agent_type":"athena-captain","outcome":"stopped"}'
  [e.4-PostToolUse-athena-captain]='{"kind":"agent_bound","tool_use_id":"toolu_01UMRB6Sg7zKJ8mBbbvpVyF3","agent_id":"ae2c37d099fc2520d","agent_type":"athena-captain"}'
  [e.5-SubagentStart-athena-captain]='{"kind":"agent_start","agent_id":"ae2c37d099fc2520d","agent_type":"athena-captain"}'
  [e.6-SubagentStop-athena-captain]='{"kind":"agent_end","agent_id":"ae2c37d099fc2520d","agent_type":"athena-captain","outcome":"stopped"}'
)

echo "== replay every measured payload (DND-541, Claude Code 2.1.282)"
ids="$(jq -r 'select(.id) | .id' "${FIXTURES}")"
eq "every fixture payload has an expectation, and no expectation is orphaned" \
  "$(printf '%s\n' "${ids}" | sort | tr '\n' ' ')" "$(printf '%s\n' "${!WANT[@]}" | sort | tr '\n' ' ')"
expected_reports=0
for id in ${ids}; do
  stdin="$(fixture "${id}")"
  want="${WANT[${id}]:-MISSING}"
  : > "${PIDS}"
  before="$(fleet_log_count)"
  hook "${stdin}"
  eq "[${id}] exit 0, no stdout (never a decision)" "${RC}:${OUT}" "0:"
  if [ "${want}" = "none" ]; then
    eq "[${id}] detached nothing" "$(grep -c . "${PIDS}" 2>/dev/null || true)" "0"
    continue
  fi
  expected_reports=$((expected_reports + 1))
  fleet_wait_pids "${PIDS}" 1
  fleet_wait_count $((before + 1)) || true
  req="$(fleet_last_request)"
  eq "[${id}] sends exactly the contract body" "$(printf '%s' "${req}" | jq -c '.body | del(.claude_session_id)')" "${want}"
  eq "[${id}] claude_session_id is the payload's session_id" \
    "$(printf '%s' "${req}" | jq -r .body.claude_session_id)" "$(printf '%s' "${stdin}" | jq -r .session_id)"
done
# Nothing detached late for a "none" payload: after a sentinel report settles,
# the server holds exactly one request per expected report.
: > "${PIDS}"
hook "$(fixture e.2-SubagentStart-athena-captain)"
fleet_wait_pids "${PIDS}" 1
eq "the replay sent one report per expected payload, and nothing else" "$(fleet_log_count)" "$((expected_reports + 1))"
eq "no replay failure was logged" "$(logn)" "0"

echo "== measured shapes the probe did not produce, derived from measured ones"
# The top-level session's own StopFailure carries no agent_id (contract, "Who sends what").
# agent_type is kept, so only the missing agent_id can be what skips it.
top_stop="$(fixture b2.7-StopFailure-athena-admiral | jq -c 'del(.agent_id)')"
n0="$(logn)"
: > "${PIDS}"; hook "${top_stop}"
eq "StopFailure without agent_id: exit 0, no stdout, nothing detached" "${RC}:${OUT}:$(grep -c . "${PIDS}" 2>/dev/null || true)" "0::0"
eq "StopFailure without agent_id: not a failure either (nothing logged)" "$(logn)" "${n0}"
# A non-Agent tool on the same events is ignored even if tool_input names a fleet type.
bash_pre="$(fixture b3.1-PreToolUse-athena-captain | jq -c '.tool_name = "Bash"')"
: > "${PIDS}"; hook "${bash_pre}"
eq "PreToolUse on a non-Agent tool: nothing detached" "${RC}:${OUT}:$(grep -c . "${PIDS}" 2>/dev/null || true)" "0::0"
# tool_name Task (the older name the matcher also covers) is the same tool.
task_pre="$(fixture b3.1-PreToolUse-athena-captain | jq -c '.tool_name = "Task"')"
: > "${PIDS}"; hook "${task_pre}"; fleet_wait_pids "${PIDS}" 1
eq "PreToolUse on Task reports like Agent" "$(fleet_last_request | jq -r .body.kind)" "agent_spawn"

echo "== mission mapping from the prompt, the run hint, and prompt privacy"
MARK="PROMPT-MARKER-7f3c9a-never-sent"
spawn() { # spawn <description> <prompt> [subagent_type] -- a measured captain spawn with new text
  fixture b1.3-PreToolUse-athena-captain | jq -c --arg d "$1" --arg p "$2" --arg t "${3:-athena-captain}" \
    '.tool_input.description = $d | .tool_input.prompt = $p | .tool_input.subagent_type = $t'
}
: > "${PIDS}"
hook "$(spawn "captain ${MARK}" "$(printf 'You are a captain. %s\n**Mission:** WEB-1289 (MEDIUM)\nReports: /home/u/dev/custom/ai-artifacts/coordination/2026-09-24-p1-fleet/reports/\n' "${MARK}")")"
fleet_wait_pids "${PIDS}" 1
eq "a Mission: line maps when the description names no ref; the run hint rides along" \
  "$(fleet_last_request | jq -c '.body | [.mapping, .ticket_ref, .run_hint]')" '["mapped","WEB-1289","2026-09-24-p1-fleet"]'
eq "a mapped spawn prints nothing" "${OUT}" ""
: > "${PIDS}"
hook "$(spawn "admiral for ${MARK}" "run ai-artifacts/coordination/2026-09-26-x/state.md ${MARK}" athena-admiral)"
fleet_wait_pids "${PIDS}" 1
eq "an admiral spawn carries its own run hint, mapping not_applicable" \
  "$(fleet_last_request | jq -c '.body | [.subagent_type, .mapping, .run_hint, has("ticket_ref")]')" '["athena-admiral","not_applicable","2026-09-26-x",false]'
if grep -q "${MARK}" "${TMP}/server.log"; then bad "no request ever carried prompt or description text" "the marker reached the server"
else ok "no request ever carried prompt or description text"; fi
if grep -rqs "${MARK}" "${XDG_STATE_HOME}"; then bad "prompt text is not written to local state either"; else ok "prompt text is not written to local state either"; fi

echo "== an unmapped captain is loud three ways, and never denied"
pinned="$(awk '/^@section Mission pointers are metadata only$/ {s=1; next} /^@section / {s=0} s && /^fleet-lifecycle: /' "${QUOTED}")"
[ -n "${pinned}" ] || bad "the quoted-fix fixture pins the unmapped notice"
: > "${PIDS}"; n0="$(logn)"
hook "$(spawn "probe captain" "do the work, no ticket named")"
fleet_wait_pids "${PIDS}" 1
eq "unmapped: exit 0" "${RC}" "0"
eq "unmapped: stdout is exactly one PreToolUse additionalContext, the pinned notice" \
  "$(printf '%s' "${OUT}" | jq -c .)" "$(jq -n -c --arg c "${pinned}" '{hookSpecificOutput: {hookEventName: "PreToolUse", additionalContext: $c}}')"
if printf '%s' "${OUT}" | grep -q permissionDecision; then bad "unmapped: no permissionDecision anywhere in stdout" "${OUT}"
else ok "unmapped: no permissionDecision anywhere in stdout"; fi
eq "unmapped: agent_spawn still sent, mapping unmapped, no ticket_ref" \
  "$(fleet_last_request | jq -c '.body | [.kind, .mapping, has("ticket_ref")]')" '["agent_spawn","unmapped",false]'
eq "unmapped: one failure-log line" "$(logn)" "$((n0 + 1))"
has "unmapped: the log line carries Fix:" "$(tail -n 1 "${LOG}")" "Fix: start the Agent description"
has "unmapped: the log line names the spawn" "$(tail -n 1 "${LOG}")" "toolu_015vBe6dE4ZPphWNsBmUvZVR"
: > "${PIDS}"
hook "$(spawn "DND-541 and DND-542 captains" "Mission: DND-9")"
fleet_wait_pids "${PIDS}" 1
eq "two refs in the description are ambiguous: unmapped, never a guess" "$(fleet_last_request | jq -r .body.mapping)" "unmapped"
# A batch dispatch names every ticket, so the notice must say a second ref is
# what unmapped it; "names no ticket" sent two admirals hunting for a missing ref.
has "two refs: the notice names the two-ref case" "$(printf '%s' "${OUT}" | jq -r .hookSpecificOutput.additionalContext)" "two or more"
has "two refs: the notice's Fix says a batch names only its first ticket's ref" "$(printf '%s' "${OUT}" | jq -r .hookSpecificOutput.additionalContext)" "a batch names only its first ticket's ref"

echo "== a fleet event with an unusable id is logged, never silently dropped"
n0="$(logn)"; c0="$(fleet_log_count)"
: > "${PIDS}"
hook "$(fixture b3.2-SubagentStart-athena-captain | jq -c '.agent_id = "../x"')"
eq "bad agent_id: exit 0, no stdout, nothing detached" "${RC}:${OUT}:$(grep -c . "${PIDS}" 2>/dev/null || true)" "0::0"
eq "bad agent_id: logged" "$(logn)" "$((n0 + 1))"
has "bad agent_id: with Fix:" "$(tail -n 1 "${LOG}")" "Fix: "
hook "$(fixture b3.1-PreToolUse-athena-captain | jq -c 'del(.tool_use_id)')"
eq "no tool_use_id on a spawn: logged" "$(logn)" "$((n0 + 2))"
hook "$(fixture b3.2-SubagentStart-athena-captain | jq -c 'del(.session_id)')"
eq "no session_id: exit 0" "${RC}" "0"
eq "no session_id: logged" "$(logn)" "$((n0 + 3))"
eq "none of those reached the server" "$(fleet_log_count)" "${c0}"

echo "== always exit 0, never blocks"
for junk in 'not json' '"a string"' '[1,2]' ''; do
  hook "${junk}"
  eq "stdin ${junk@Q}: exit 0, no stdout" "${RC}:${OUT}" "0:"
done
has "unparseable stdin is logged with Fix:" "$(tail -n 1 "${LOG}")" "could not parse"
mkdir -p "${TMP}/nojq"
for c in bash cat realpath dirname date mktemp grep tr sed stat mkdir mv rm head flock printf env; do
  p="$(command -v "${c}" 2>/dev/null)" && [ -n "${p}" ] && [ "${p#/}" != "${p}" ] && ln -sf "${p}" "${TMP}/nojq/${c}"
done
n0="$(logn)"
OUT="$(fixture b3.2-SubagentStart-athena-captain > "${TMP}/in.json"; PATH="${TMP}/nojq" "${HOOK}" < "${TMP}/in.json" 2>/dev/null)"; RC=$?
eq "jq missing: exit 0, no stdout" "${RC}:${OUT}" "0:"
eq "jq missing: logged" "$(logn)" "$((n0 + 1))"
has "jq missing: with Fix:" "$(tail -n 1 "${LOG}")" "Fix: install jq"

fleet_respond '{"status":422,"body":{"error":"unprocessable_entity","fix":"agent_type must be a fleet worker"}}'
n0="$(logn)"; : > "${PIDS}"
hook "$(fixture b3.2-SubagentStart-athena-captain)"
fleet_wait_pids "${PIDS}" 1
eq "a 422 refusal: the hook still exited 0" "${RC}" "0"
eq "a 422 refusal: logged" "$(logn)" "$((n0 + 1))"
has "a 422 refusal: the server's Fix: is in the log" "$(tail -n 1 "${LOG}")" "Fix: agent_type must be a fleet worker"
# Both cases below hold the server's answer until the test releases it
# (DND-1007), so each verdict rests on an event, never on machine speed. The
# `timeout 60` is a hang cap only: a hook that waited on the network would sit
# on the held answer and exit 124, however fast the machine is.
HOLD="${TMP}/hold-latency"
fleet_respond "{\"status\":202,\"body\":{\"ok\":true},\"hold_file\":\"${HOLD}\"}"
: > "${PIDS}"
fixture b3.3-StopFailure-athena-captain > "${TMP}/in.json"
# curl's cap and the report's bound are raised past the 60 s hang cap, so a
# hook that waited on the network could not give up early and exit 0.
FLEET_MAX_TIME_S=120 FLEET_HOOK_TIMEOUT_S=120 timeout 60 "${HOOK}" < "${TMP}/in.json" >/dev/null 2>&1; RC=$?
eq "never adds latency: the hook exited 0 while the server's answer was still held" "${RC}" "0"
fleet_await_live_reporter "${PIDS}"
eq "never adds latency: the detached report is still waiting on the held answer" "${LIVE_REPORTER}" "yes"
touch "${HOLD}"
fleet_wait_pids "${PIDS}" 1
HOLD="${TMP}/hold-bound"
fleet_respond "{\"status\":202,\"body\":{\"ok\":true},\"hold_file\":\"${HOLD}\"}"
: > "${PIDS}"
# curl's cap is set well past the 1 s bound, so only the bound can end it.
export FLEET_HOOK_TIMEOUT_S=1 FLEET_MAX_TIME_S=30
hook "$(fixture b3.3-StopFailure-athena-captain)"
unset FLEET_HOOK_TIMEOUT_S FLEET_MAX_TIME_S
fleet_wait_pids "${PIDS}" 1
has "a report past its bound is killed and logged with Fix: (the answer was held, so only the bound could end it)" "$(tail -n 1 "${LOG}")" "did not finish within 1s"
touch "${HOLD}"
fleet_respond '{"status":202,"body":{"ok":true}}'
kill "${SERVER_PID}" 2>/dev/null; wait "${SERVER_PID}" 2>/dev/null; SERVER_PID=""
fleet_point_at "http://127.0.0.1:$(fleet_closed_port)/mcp"
n0="$(logn)"; : > "${PIDS}"
hook "$(fixture b3.2-SubagentStart-athena-captain)"
fleet_wait_pids "${PIDS}" 1
eq "server down: exit 0, no stdout" "${RC}:${OUT}" "0:"
eq "server down: logged" "$(logn)" "$((n0 + 1))"
has "server down: with Fix:" "$(tail -n 1 "${LOG}")" "could not reach"
( export XDG_STATE_HOME=relative; fixture b3.2-SubagentStart-athena-captain | "${HOOK}" >/dev/null 2>&1 ); eq "relative XDG_STATE_HOME: exit 0" "$?" "0"

echo "== --help"
out="$("${HOOK}" --help)"; rc=$?
eq "--help exits 0" "${rc}" "0"
has "--help names the events" "${out}" "SubagentStart"

echo
echo "${PASS} passed, ${FAIL} failed"
if [ "${FAIL}" -ne 0 ]; then
  echo "fleet-lifecycle hook self-test: FAIL"
  echo "  Fix: read the FAIL lines above; each names the rule it checks (athena-events.md -> Agent lifecycle, Mission pointers are metadata only)."
  exit 1
fi
echo "fleet-lifecycle hook self-test: OK"
