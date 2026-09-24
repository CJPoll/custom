#!/usr/bin/env bash
# Self-test for ai/hooks/fleet-report.sh (DND-433), against the loopback fake
# server in ai/lib/fleet/test/. Never prod. Declared in harness-gate by THIS
# file's path (the hook reads stdin, so `fleet-report.sh --self-test` just
# execs this).
#
# [ticket] cases: the throttle holds (one report per 60 s per (session,
# agent_id)); the hook never adds latency (it returns while the server is still
# sleeping); a failed detached report is surfaced with its Fix:.

set -u

HOOK="$(cd -- "$(dirname -- "$0")" && pwd -P)/fleet-report.sh"
AI="$(cd -- "$(dirname -- "${HOOK}")/.." && pwd -P)"
FAKE="${AI}/lib/fleet/test/fake-fleet-server.py"

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); printf 'ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf 'FAIL %s\n' "$1"; [ -n "${2:-}" ] && printf '     %s\n' "$2"; return 0; }
eq()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$3], got [$2]"; fi; }

for dep in jq curl python3 git flock setsid timeout; do
  command -v "${dep}" >/dev/null 2>&1 || { echo "fleet-report hook self-test: FAIL -- ${dep} is not on PATH"; echo "  Fix: install ${dep}; this suite does not skip."; exit 1; }
done

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
SEEN="${XDG_STATE_HOME}/athena/fleet/seen"
SID="11111111-2222-4333-8444-555555555555"

# hook <json> -- run the hook with stdin; sets RC, OUT, ERR, MS (wall ms).
hook() {
  local t0 t1
  t0="$(date +%s%N)"
  OUT="$(printf '%s' "$1" | "${HOOK}" 2>"${TMP}/err")"; RC=$?
  t1="$(date +%s%N)"
  ERR="$(cat "${TMP}/err")"
  MS=$(( (t1 - t0) / 1000000 ))
}
post() { jq -n -c --arg s "${SID}" --arg a "${1:-}" --arg t "${2:-}" \
  '{hook_event_name: "PostToolUse", session_id: $s, cwd: "/", tool_name: "Bash"}
   + (if $a == "" then {} else {agent_id: $a} end) + (if $t == "" then {} else {agent_type: $t} end)'; }
settle() { fleet_wait_pids "${PIDS}" "$1"; }

echo "== hook: shape"
hook ''; eq "empty stdin: exit 0" "${RC}" "0"
hook 'not json'
eq "unparseable stdin: exit 0 (never blocks)" "${RC}" "0"
case "${ERR}" in *"Fix: "*) ok "unparseable stdin says so with Fix:" ;; *) bad "unparseable stdin says so with Fix:" "${ERR}" ;; esac
hook '{"hook_event_name":"PostToolUse","cwd":"/"}'
eq "no session_id: exit 0" "${RC}" "0"
case "${ERR}" in *"session_id"*"Fix: "*) ok "no session_id says so with Fix:" ;; *) bad "no session_id says so with Fix:" "${ERR}" ;; esac
( export XDG_STATE_HOME=relative; printf '%s' "$(post)" | "${HOOK}" 2>"${TMP}/err" ); eq "relative XDG_STATE_HOME: exit 0" "$?" "0"
case "$(cat "${TMP}/err")" in *"not absolute"*"Fix: "*) ok "relative XDG_STATE_HOME says so with Fix:" ;; *) bad "relative XDG_STATE_HOME says so with Fix:" ;; esac
eq "none of those reached the server" "$(fleet_log_count)" "0"

echo "== hook: SessionStart / SessionEnd"
git init -q "${TMP}/repo"
jq -n --arg r "$(realpath "${TMP}/repo/.git")" '{v: 1, repo: $r, channels: {}}' > "${ATHENA_INBOX_ROOT}/projects/demo.json"
hook "$(jq -n -c --arg s "${SID}" --arg c "${TMP}/repo" '{hook_event_name: "SessionStart", session_id: $s, cwd: $c, source: "startup"}')"
eq "SessionStart: exit 0" "${RC}" "0"
eq "SessionStart: writes nothing on stdout (it would become context)" "${OUT}" ""
settle 1; fleet_wait_count 1
eq "SessionStart -> session_started with the payload cwd's project" \
  "$(fleet_last_request | jq -c '.body | [.kind, .claude_session_id, .project]')" "[\"session_started\",\"${SID}\",\"demo\"]"
hook "$(jq -n -c --arg s "${SID}" '{hook_event_name: "SessionEnd", session_id: $s, cwd: "/", reason: "prompt_input_exit"}')"
settle 2; fleet_wait_count 2
eq "SessionEnd -> session_ended with end_reason" \
  "$(fleet_last_request | jq -c '.body | [.kind, .end_reason]')" '["session_ended","prompt_input_exit"]'

echo "== hook: PostToolUse throttle [ticket]"
: > "${PIDS}"; base="$(fleet_log_count)"
hook "$(post)"; hook "$(post)"; hook "$(post)"
settle 1
eq "[ticket] three top-level tool calls inside 60 s -> one session_seen" "$(fleet_log_count)" "$((base + 1))"
eq "the top-level report carries no agent fields" "$(fleet_last_request | jq -c '.body | keys')" '["claude_session_id","kind"]'
hook "$(post adm0001 athena-admiral)"; hook "$(post adm0001 athena-admiral)"
settle 2
eq "[ticket] an admiral's two calls -> one more report" "$(fleet_log_count)" "$((base + 2))"
eq "an athena-admiral's report is admiral_seen with its agent_id" \
  "$(fleet_last_request | jq -c '.body | [.kind, .agent_id, .agent_type]')" '["admiral_seen","adm0001","athena-admiral"]'
hook "$(post cap0001 athena-captain)"
settle 3
eq "a captain in the same session has its own throttle" "$(fleet_log_count)" "$((base + 3))"
eq "a captain's report is session_seen with its agent fields" \
  "$(fleet_last_request | jq -c '.body | [.kind, .agent_id, .agent_type]')" '["session_seen","cap0001","athena-captain"]'
touch -d "@$(( $(date +%s) - 61 ))" "${SEEN}/${SID}.adm0001.stamp"
hook "$(post adm0001 athena-admiral)"
settle 4
eq "[ticket] 60 s later the admiral reports again" "$(fleet_log_count)" "$((base + 4))"

echo "== hook: never adds latency [ticket]"
fleet_respond '{"status":202,"body":{"ok":true},"delay_s":3}'
: > "${PIDS}"
hook "$(post lat0001 athena-captain)"
eq "PostToolUse against a 3 s server: exit 0" "${RC}" "0"
if [ "${MS}" -lt 1500 ]; then ok "[ticket] the hook returned in ${MS} ms while the server was still sleeping 3 s"
else bad "[ticket] the hook returned in ${MS} ms while the server was still sleeping 3 s" "it waited on the network"; fi
eq "PostToolUse writes nothing on stdout" "${OUT}" ""
settle 1
fleet_respond '{"status":202,"body":{"ok":true}}'

echo "== hook: a failed background report is surfaced once"
fleet_point_at "http://127.0.0.1:$(fleet_closed_port)/mcp"
: > "${PIDS}"
hook "$(post fail001 athena-captain)"
settle 1
if [ -s "${SEEN}/${SID}.last-error" ]; then ok "an unreachable server leaves the session's last-error"
else bad "an unreachable server leaves the session's last-error"; fi
case "$(cat "${SEEN}/${SID}.last-error" 2>/dev/null)" in *"could not reach"*"Fix: "*) ok "last-error is fleet-report's own Fix: line" ;; *) bad "last-error is fleet-report's own Fix: line" ;; esac
fleet_point_at "http://127.0.0.1:${SERVER_PORT}/mcp"
hook "$(post fail001 athena-captain)"
eq "not due yet: the error waits for the next due report" "${ERR}" ""
touch -d "@$(( $(date +%s) - 61 ))" "${SEEN}/${SID}.fail001.stamp"
hook "$(post fail001 athena-captain)"
eq "the surfacing call still exits 0" "${RC}" "0"
case "${ERR}" in *"earlier background report failed"*"Fix: "*) ok "the next due call prints the earlier failure with its Fix:" ;; *) bad "the next due call prints the earlier failure with its Fix:" "${ERR}" ;; esac
if [ -e "${SEEN}/${SID}.last-error" ]; then bad "a surfaced error is removed (printed once)"; else ok "a surfaced error is removed (printed once)"; fi
settle 2

echo "== hook: the detached report is bounded by timeout"
fleet_respond '{"status":202,"body":{"ok":true},"delay_s":4}'
: > "${PIDS}"
t0="$(date +%s)"
( export FLEET_HOOK_TIMEOUT_S=1 FLEET_MAX_TIME_S=30; printf '%s' "$(post slow001 athena-captain)" | "${HOOK}" 2>/dev/null )
settle 1
el=$(( $(date +%s) - t0 ))
if [ "${el}" -lt 4 ]; then ok "the detached reporter was killed at its 1 s limit (${el} s)"; else bad "the detached reporter was killed at its 1 s limit (${el} s)"; fi
case "$(cat "${SEEN}/${SID}.last-error" 2>/dev/null)" in *"did not finish within 1s"*"Fix: "*) ok "a timeout is recorded as its own Fix: line" ;; *) bad "a timeout is recorded as its own Fix: line" "$(cat "${SEEN}/${SID}.last-error" 2>/dev/null)" ;; esac
leftover="$(find "${SEEN}" -name '*.tmp' | head -n 1)"
eq "the trap removed the detached reporter's temp file" "${leftover}" ""
fleet_respond '{"status":202,"body":{"ok":true}}'

echo "== hook: the token"
leaks="$(jq -s -c '[.[] | (.argv_leak + .environ_leak)[]]' "${TMP}/server.log")"
eq "no hook-sent request ever had the token in any process's argv or environ" "${leaks}" "[]"
eq "every hook-sent request authenticated with the machine token" "$(jq -s -c '[.[] | .auth_ok] | unique' "${TMP}/server.log")" "[true]"

printf '\n%d passed, %d failed\n' "${PASS}" "${FAIL}"
if [ "${FAIL}" -ne 0 ]; then
  echo "fleet-report hook self-test: FAILED"
  echo "  Fix: make ai/hooks/fleet-report.sh satisfy the failing cases above: detached, throttled per (session, agent_id), always exit 0, failures surfaced with Fix:."
  exit 1
fi
echo "fleet-report hook self-test: OK"
exit 0
