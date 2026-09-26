#!/usr/bin/env bash
# Self-test for ai/hooks/fleet-report.sh (DND-433), against the loopback fake
# server in ai/lib/fleet/test/. Never prod. Declared in harness-gate by THIS
# file's path (the hook reads stdin, so `fleet-report.sh --self-test` just
# execs this).
#
# [ticket] cases: the throttle holds (one report per 60 s per (session,
# agent_id)); the hook never adds latency (it returns while the server is still
# sleeping). Also: a failed detached report is logged durably with its Fix:
# and announced at the next SessionStart on stdout (session context).

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

LOG="${XDG_STATE_HOME}/athena/fleet/report-failures.log"
logn() { local c; c="$(cat "${LOG}.1" "${LOG}" 2>/dev/null | grep -c .)"; printf '%s\n' "${c:-0}"; }
eq "the two refusals above were logged durably" "$(logn)" "2"
rm -f -- "${LOG}" "${LOG}.1"

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
if [ "${MS}" -lt 2500 ]; then ok "[ticket] the hook returned in ${MS} ms while the server was still sleeping 3 s"
else bad "[ticket] the hook returned in ${MS} ms while the server was still sleeping 3 s" "it waited on the network"; fi
eq "PostToolUse writes nothing on stdout" "${OUT}" ""
settle 1
fleet_respond '{"status":202,"body":{"ok":true}}'

echo "== hook: a failed background report is recorded and announced"
before="$(logn)"
fleet_point_at "http://127.0.0.1:$(fleet_closed_port)/mcp"
: > "${PIDS}"
hook "$(post fail001 athena-captain)"
eq "PostToolUse stays silent on stdout about a failure" "${OUT}" ""
settle 1
eq "an unreachable server appends one line to the failure log" "$(logn)" "$((before + 1))"
line="$(tail -n 1 "${LOG}")"
case "${line}" in *"${SID}"*"session_seen"*"could not reach"*"Fix: "*) ok "the line names the session, the kind and fleet-report's own Fix:" ;; *) bad "the line names the session, the kind and fleet-report's own Fix:" "${line}" ;; esac
fleet_point_at "http://127.0.0.1:${SERVER_PORT}/mcp"
: > "${PIDS}"
hook "$(jq -n -c --arg s "${SID}" --arg c "${TMP}/repo" '{hook_event_name: "SessionStart", session_id: $s, cwd: $c}')"
settle 1
case "${OUT}" in *"background fleet registry report(s) failed"*"could not reach"*"report-failures.log"*"Fix: "*) ok "the next SessionStart announces it on stdout (session context), with the log path and Fix:" ;; *) bad "the next SessionStart announces it on stdout (session context), with the log path and Fix:" "${OUT}" ;; esac
eq "announcing does not delete the log line" "$(logn)" "$((before + 1))"
hook "$(jq -n -c --arg s "${SID}" --arg c "${TMP}/repo" '{hook_event_name: "SessionStart", session_id: $s, cwd: $c}')"
eq "a later SessionStart does not announce the same failure twice" "${OUT}" ""
hook '{"hook_event_name":"PostToolUse","cwd":"/"}'
case "$(tail -n 1 "${LOG}")" in *"hook"*"no usable session_id"*"Fix: "*) ok "a refusal by the hook itself is logged too" ;; *) bad "a refusal by the hook itself is logged too" "$(tail -n 1 "${LOG}")" ;; esac
hook "$(jq -n -c --arg s "${SID}" --arg c "${TMP}/repo" '{hook_event_name: "SessionStart", session_id: $s, cwd: $c}')"
case "${OUT}" in *"1 background fleet registry report(s) failed"*"no usable session_id"*) ok "and announced at the next SessionStart" ;; *) bad "and announced at the next SessionStart" "${OUT}" ;; esac
settle 3

echo "== hook: the detached report is bounded by timeout"
fleet_respond '{"status":202,"body":{"ok":true},"delay_s":4}'
: > "${PIDS}"
t0="$(date +%s)"
mkdir -p "${TMP}/tmpd"
( export FLEET_HOOK_TIMEOUT_S=1 FLEET_MAX_TIME_S=30 TMPDIR="${TMP}/tmpd"; printf '%s' "$(post slow001 athena-captain)" | "${HOOK}" 2>/dev/null )
settle 1
el=$(( $(date +%s) - t0 ))
if [ "${el}" -lt 4 ]; then ok "the detached reporter was killed at its 1 s limit (${el} s)"; else bad "the detached reporter was killed at its 1 s limit (${el} s)"; fi
case "$(tail -n 1 "${LOG}")" in *"did not finish within 1s"*"Fix: "*) ok "a timeout is logged as its own Fix: line" ;; *) bad "a timeout is logged as its own Fix: line" "$(tail -n 1 "${LOG}")" ;; esac
# The killed fleet-report finishes its in-flight curl (bash defers the TERM
# trap until the child returns), then its EXIT trap removes its temp dir.
for i in $(seq 1 200); do
  [ -z "$(find "${TMP}/tmpd" -mindepth 1 | head -n 1)" ] && break
  sleep 0.05
done
eq "no temp file or dir survives the killed report (traps ran)" "$(find "${TMP}/tmpd" -mindepth 1 | head -n 3)" ""
fleet_respond '{"status":202,"body":{"ok":true}}'

echo "== hook: PostToolUse self-heals a missing session_started (DND-497)"
# A session that predates the hook install: SessionStart never fired for it,
# so it has no "started" stamp. The FIRST PostToolUse from such a session
# must self-heal by sending session_started (project + repo_key resolved
# from the event's cwd, same as session-start) before/alongside session_seen.
HEAL_SID="99999999-8888-4777-8666-555555555555"
: > "${PIDS}"; before="$(fleet_log_count)"
post_cwd() { jq -n -c --arg s "${1}" --arg cwd "${2}" \
  '{hook_event_name: "PostToolUse", session_id: $s, cwd: $cwd, tool_name: "Bash"}'; }
hook "$(post_cwd "${HEAL_SID}" "${TMP}/repo")"
settle 2; fleet_wait_count "$((before + 2))"
# The two detached sends race independently (both `setsid -f`), so their
# arrival order at the server is not guaranteed -- compare as a set.
kinds="$(tail -n 2 "${TMP}/server.log" | jq -r '.body.kind' | sort)"
eq "[ticket] a session with no started-stamp: first PostToolUse sends session_started and session_seen" \
  "${kinds}" "$(printf 'session_seen\nsession_started')"
started_req="$(tail -n 2 "${TMP}/server.log" | jq -c 'select(.body.kind == "session_started") | .body | [.claude_session_id, .project]' | head -n 1)"
eq "the self-healed session_started carries project+repo_key resolved from the event cwd (DND-183 rule)" \
  "${started_req}" "[\"${HEAL_SID}\",\"demo\"]"

touch -d "@$(( $(date +%s) - 61 ))" "${SEEN}/${HEAL_SID}.main.stamp"
: > "${PIDS}"; before="$(fleet_log_count)"
hook "$(post_cwd "${HEAL_SID}" "${TMP}/repo")"
settle 1; fleet_wait_count "$((before + 1))"
eq "a second PostToolUse for the same session sends only session_seen (stamp written)" \
  "$(fleet_last_request | jq -c '.body.kind')" '"session_seen"'
eq "no repeat session_started was logged for this session" \
  "$(jq -s -c --arg s "${HEAL_SID}" '[.[] | select(.body.claude_session_id == $s and .body.kind == "session_started")] | length' "${TMP}/server.log")" "1"

touch -d "@$(( $(date +%s) - 61 ))" "${SEEN}/${SID}.main.stamp"
: > "${PIDS}"; before="$(fleet_log_count)"
hook "$(jq -n -c --arg s "${SID}" --arg cwd "${TMP}/repo" '{hook_event_name: "PostToolUse", session_id: $s, cwd: $cwd, tool_name: "Bash"}')"
settle 1; fleet_wait_count "$((before + 1))"
eq "a normally-started session (SessionStart already marked it) sends no self-heal session_started" \
  "$(fleet_last_request | jq -c '.body.kind')" '"session_seen"'

echo "== hook: a failed self-heal session_started leaves no stamp and retries (DND-497)"
RETRY_SID="77777777-6666-4555-8444-333333333333"
fleet_point_at "http://127.0.0.1:$(fleet_closed_port)/mcp"
: > "${PIDS}"
before_log="$(logn)"
hook "$(post_cwd "${RETRY_SID}" "${TMP}/repo")"
settle 2
eq "the unreachable self-heal attempt (and the session_seen alongside it) are both logged as failures" "$(logn)" "$((before_log + 2))"
case "$(cat "${LOG}")" in *"${RETRY_SID}"*"session_started"*"could not reach"*"Fix: "*) ok "one failure line names session_started" ;; *) bad "one failure line names session_started" "$(cat "${LOG}")" ;; esac
eq "no started-stamp was written for the failed session_started (would silence the retry)" \
  "$([ -e "${XDG_STATE_HOME}/athena/fleet/started/${RETRY_SID}.marked" ] && echo present || echo absent)" "absent"
fleet_point_at "http://127.0.0.1:${SERVER_PORT}/mcp"
# advance past the fleet_claim_seen throttle so the next PostToolUse is due
touch -d "@$(( $(date +%s) - 61 ))" "${SEEN}/${RETRY_SID}.main.stamp"
: > "${PIDS}"; before="$(fleet_log_count)"
hook "$(post_cwd "${RETRY_SID}" "${TMP}/repo")"
settle 2; fleet_wait_count "$((before + 2))"
kinds="$(tail -n 2 "${TMP}/server.log" | jq -r '.body.kind' | sort)"
eq "[ticket] a failed session_started send is retried on the next due PostToolUse" \
  "${kinds}" "$(printf 'session_seen\nsession_started')"
eq "and this time it is marked started" "$([ -e "${XDG_STATE_HOME}/athena/fleet/started/${RETRY_SID}.marked" ] && echo present || echo absent)" "present"

echo "== hook: started-stamps are pruned like the seen-stamps, but not while the session is active (DND-497)"
STARTED="${XDG_STATE_HOME}/athena/fleet/started"
DEAD_SID="66666666-5555-4444-8333-222222222222"
: > "${STARTED}/${DEAD_SID}.marked"
touch -d "@$(( $(date +%s) - 86400 - 120 ))" "${STARTED}/${DEAD_SID}.marked"
# RETRY_SID stays active: its stamp is old, but a due PostToolUse refreshes it.
touch -d "@$(( $(date +%s) - 86400 - 120 ))" "${STARTED}/${RETRY_SID}.marked"
touch -d "@$(( $(date +%s) - 61 ))" "${SEEN}/${RETRY_SID}.main.stamp"
: > "${PIDS}"; before="$(fleet_log_count)"
hook "$(post_cwd "${RETRY_SID}" "${TMP}/repo")"
settle 1; fleet_wait_count "$((before + 1))"
eq "a started-stamp silent for a day (dead session) is pruned" \
  "$([ -e "${STARTED}/${DEAD_SID}.marked" ] && echo present || echo absent)" "absent"
eq "an active session's started-stamp is refreshed by its due PostToolUse, not pruned" \
  "$([ -e "${STARTED}/${RETRY_SID}.marked" ] && echo present || echo absent)" "present"
eq "and that PostToolUse re-sent no session_started" \
  "$(fleet_last_request | jq -c '.body.kind')" '"session_seen"'

echo "== hook: a started-stamp that cannot be written is logged, not silent (DND-497)"
RO_SID="55555555-4444-4333-8222-111111111111"
chmod 500 "${STARTED}"
: > "${PIDS}"; before="$(fleet_log_count)"; before_log="$(logn)"
hook "$(jq -n -c --arg s "${RO_SID}" --arg c "${TMP}/repo" '{hook_event_name: "SessionStart", session_id: $s, cwd: $c}')"
settle 1; fleet_wait_count "$((before + 1))"
chmod 700 "${STARTED}"
eq "the session_started itself was sent" "$(fleet_last_request | jq -c '[.body.kind, .body.claude_session_id]')" "[\"session_started\",\"${RO_SID}\"]"
eq "one failure line was logged" "$(logn)" "$((before_log + 1))"
case "$(tail -n 1 "${LOG}")" in *"${RO_SID}"*"session_started"*"could not be written"*"Fix: "*) ok "it names the session, the stamp and a Fix:" ;; *) bad "it names the session, the stamp and a Fix:" "$(tail -n 1 "${LOG}")" ;; esac

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
