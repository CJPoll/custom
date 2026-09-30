#!/usr/bin/env bash
# fleet-control suite, part wait (DND-1007 split of DND-443's suite): the resume waiter (DND-484), its trap, own, and test 7b.
# Discovered by harness-gate; `ai/bin/fleet-control --self-test` runs every part.
# Shared setup: ../common.sh (and ../fixture.sh for the fake-server parts).

# shellcheck source=../common.sh
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)/common.sh"

# shellcheck source=../fixture.sh
. "${CONTROL}/fixture.sh"

echo "== wait: the resume waiter (DND-484)"
# The defect: with two sessions in one project, the control_changed line for
# session B lands on the project's session channel, which ANOTHER session's
# read-inbox holds (consumer lock) and acks. B never sees its wake. The waiter
# must resume B from B's own GET /control alone, touching no inbox state.
rm -f "${TMP}/port"
fleet_start_server || exit 1
SID_B="5f488432-6c65-495e-a216-000000000484"
DRAIN_B="$(answer drain override:force_drain null "${OV_DRAIN}" "${SID_B}")"
RUN_B="$(answer run default null "${P1_SNAP}" "${SID_B}")"
CACHE_B="${XDG_STATE_HOME}/athena/fleet/${SID_B}.json"

# fw <args...> -- run fleet-control wait for session B; sets OUT, ERR, RC, HITS.
fw() {
  local before
  before="$(fleet_log_count)"
  OUT="$(timeout 60 "${BIN}" wait --session-id "${SID_B}" --cwd "${CU}" "$@" 2>"${TMP}/werr")"; RC=$?
  ERR="$(cat "${TMP}/werr")"
  HITS=$(( $(fleet_log_count) - before ))
}

# The non-holder world: session B's line is on the shared session channel,
# already acked by the holder (offset past it), with the consumer lock held by
# another process for the whole wait.
SCH="${ATHENA_INBOX_ROOT}/custom-session.jsonl"
jq -n -c --arg b "${SID_B}" '{producer: "platform", kind: "fleet.session.control_changed", entity_id: "fleet_session:9", payload: {claude_session_id: $b, desired: "run", reason: "default"}}' > "${SCH}"
jq -n -c --argjson o "$(stat -c %s "${SCH}")" '{offset: $o}' > "${ATHENA_INBOX_ROOT}/custom-session.state.json"
: > "${ATHENA_INBOX_ROOT}/custom-session.consumer.lock"
flock "${ATHENA_INBOX_ROOT}/custom-session.consumer.lock" sleep 120 &
HOLDER_PID=$!
held=""
# A hang cap, not a budget (DND-1007: it was 5 s); the holder keeps the lock 120 s.
for i in $(seq 1 1200); do
  if ! flock -n "${ATHENA_INBOX_ROOT}/custom-session.consumer.lock" true; then held=1; break; fi
  sleep 0.05
done
eq "[DND-484 test 1] fixture: another process holds the session consumer lock" "${held}" 1
inbox_sum() { find "${ATHENA_INBOX_ROOT}" -maxdepth 1 -type f -name 'custom-session*' -printf '%f %s %T@\n' | sort | md5sum; }
SUM_BEFORE="$(inbox_sum)"

fleet_respond "[{\"status\":200,\"body\":${DRAIN_B}},{\"status\":200,\"body\":${DRAIN_B}},{\"status\":200,\"body\":${RUN_B}}]"
fw --interval 1 --budget 30
eq "[DND-484 test 1] non-holder: wait exits 0 when the server says run" "${RC}" 0
eq "[DND-484 test 1] ... on poll 3 (drain, drain, run)" "${HITS}" 3
eq "[DND-484 test 1] ... stdout is the check line, basis server" "${OUT}" "desired=run reason=default until=unbounded basis=server"
has "[DND-484 test 1] ... stderr names the next step" "${ERR}" "athena:fleet-drain"
eq "[DND-484 test 1] ... every request was B's own control read" \
  "$(tail -n 3 "${TMP}/server.log" | jq -r .path | sort -u)" "/api/v1/fleet/sessions/${SID_B}/control"
eq "[DND-484 test 1] ... the inbox channel, state and lock are untouched" "$(inbox_sum)" "${SUM_BEFORE}"

fleet_respond "[{\"status\":200,\"body\":${DRAIN_B}},{\"status\":200,\"body\":${DRAIN_B}},{\"status\":200,\"body\":${RUN_B}}]"
ATHENA_INBOX_ROOT="${TMP}/no-such-inbox-root" fw --interval 1 --budget 30
eq "[DND-484 test 1] no inbox root at all: wait still exits 0" "${RC}" 0
eq "[DND-484 test 1] ... on poll 3" "${HITS}" 3
check "[DND-484 test 1] ... and creates no inbox root" test ! -e "${TMP}/no-such-inbox-root"
kill "${HOLDER_PID}" 2>/dev/null; wait "${HOLDER_PID}" 2>/dev/null

# Test 2: a non-server run is never a resume.
fleet_respond "{\"status\":200,\"body\":${RUN_B}}"
"${BIN}" fetch --session-id "${SID_B}" --cwd "${CU}" >/dev/null 2>&1   # warm cache: run
kill "${SERVER_PID}" 2>/dev/null; wait "${SERVER_PID}" 2>/dev/null; SERVER_PID=""
fleet_point_at "http://127.0.0.1:$(fleet_closed_port)/mcp"
fw --interval 1 --budget 3
eq "[DND-484 test 2] recomputed run (server unreachable) is NOT a resume: exit 75" "${RC}" 75
eq "[DND-484 test 2] ... nothing on stdout" "${OUT}" ""
has "[DND-484 test 2] ... warns with the basis" "${ERR}" "WARNING control state is unknown, so this answer is basis recomputed:server-unreachable"
eq "[DND-484 test 2] ... one WARNING for the one basis, not one per poll" "$(grep -c 'WARNING' <<<"${ERR}")" 1
has "[DND-484 test 2] ... budget exit says re-arm" "${ERR}" "Re-arm"
rm -f "${CACHE_B}"
fw --interval 1 --budget 3
eq "[DND-484 test 2] local-rule run (no cache, blend project) is NOT a resume: exit 75" "${RC}" 75
has "[DND-484 test 2] ... warns with the local-rule basis" "${ERR}" "basis local-rule:server-unreachable,no-cache"

# Test 3: an unregistered session is refused, never retried to the budget.
rm -f "${TMP}/port"
fleet_start_server || exit 1
fleet_respond '{"status":404,"body":{"error":"not_found"}}'
fw --interval 1 --budget 30
eq "[DND-484 test 3] unregistered session: exit 2" "${RC}" 2
has "[DND-484 test 3] ... Fix: names the cause" "${ERR}" "Fix:"
has "[DND-484 test 3] ... names session-unregistered" "${ERR}" "session-unregistered"
has "[DND-484 test 3] ... names the session id" "${ERR}" "${SID_B}"
eq "[DND-484 test 3] ... after ONE request" "${HITS}" 1
eq "[DND-484 test 3] ... nothing on stdout" "${OUT}" ""
fleet_respond '{"status":401,"body":{"error":"unauthorized","fix":"bad token"}}'
fw --interval 1 --budget 30
eq "[DND-484 test 3] refused (401): exit 2" "${RC}:${HITS}" "2:1"
has "[DND-484 test 3] ... names server-refused" "${ERR}" "server-refused"
mv "${ATHENA_INBOX_CLIENT_CONFIG}" "${TMP}/cfg.off"
fw --interval 1 --budget 30
eq "[DND-484 test 3] unconfigured (no token): exit 2, no request" "${RC}:${HITS}" "2:0"
has "[DND-484 test 3] ... names server-unconfigured" "${ERR}" "server-unconfigured"
mv "${TMP}/cfg.off" "${ATHENA_INBOX_CLIENT_CONFIG}"
before="$(fleet_log_count)"
( cd "${TMP}" && XDG_STATE_HOME="rel-state" timeout 30 "${BIN}" wait --session-id "${SID_B}" --cwd "${CU}" --interval 1 --budget 30 >/dev/null 2>"${TMP}/werr"; echo "$?" > "${TMP}/rc" )
eq "[DND-484 test 3] invalid cache path: exit 2" "$(cat "${TMP}/rc")" 2
has "[DND-484 test 3] ... names invalid-cache-path" "$(cat "${TMP}/werr")" "invalid-cache-path"
has "[DND-484 test 3] ... with Fix:" "$(cat "${TMP}/werr")" "Fix:"
eq "[DND-484 test 3] ... and asks nothing" "$(( $(fleet_log_count) - before ))" 0

# Test 4: a missing, empty or unsafe session id makes no request at all.
before="$(fleet_log_count)"
wait_usage() {
  local name="$1"; shift
  ( unset CLAUDE_CODE_SESSION_ID; timeout 30 "${BIN}" wait --interval 1 --budget 5 "$@" >/dev/null 2>"${TMP}/uerr" ); local rc=$?
  eq "[DND-484 test 4] ${name}: exit 2" "${rc}" 2
  has "[DND-484 test 4] ${name}: Fix:" "$(cat "${TMP}/uerr")" "Fix:"
}
wait_usage "no session id"
( export CLAUDE_CODE_SESSION_ID=""; timeout 30 "${BIN}" wait --interval 1 --budget 5 >/dev/null 2>"${TMP}/uerr" ); eq "[DND-484 test 4] empty session id: exit 2" "$?" 2
wait_usage "unsafe session id" --session-id "../x"
wait_usage "an interval of 0" --session-id "${SID_B}" --interval 0
wait_usage "a non-numeric budget" --session-id "${SID_B}" --budget soon
wait_usage "--now on wait" --session-id "${SID_B}" --now 1
eq "[DND-484 test 4] ... zero requests across all of them" "$(( $(fleet_log_count) - before ))" 0

# Test 5: the budget bounds the wait, and the waiter says which one it used.
fleet_respond "{\"status\":200,\"body\":${DRAIN_B}}"
fw --interval 1 --budget 2
eq "[DND-484 test 5] drain for the whole budget: exit 75" "${RC}" 75
has "[DND-484 test 5] ... names the budget" "${ERR}" "budget 2s"
has "[DND-484 test 5] ... names the mode" "${ERR}" "mode "
has "[DND-484 test 5] ... says drain once, as a server answer" "${ERR}" "desired=drain reason=override:force_drain"
eq "[DND-484 test 5] ... one drain notice, not one per poll" "$(grep -c 'desired=drain' <<<"${ERR}")" 1
( export CLAUDE_CODE_ENTRYPOINT=sdk-cli CLAUDE_CODE_SESSION_ATTENDED=0; unset CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS
  timeout 30 "${BIN}" wait --session-id "${SID_B}" --cwd "${CU}" --interval 1 --budget 600 >/dev/null 2>"${TMP}/uerr"; echo "$?" > "${TMP}/rc" )
eq "[DND-484 test 5] headless: a budget at the 600s ceiling is refused (exit 2)" "$(cat "${TMP}/rc")" 2
has "[DND-484 test 5] ... with Fix:" "$(cat "${TMP}/uerr")" "Fix:"
( export CLAUDE_CODE_ENTRYPOINT=sdk-cli CLAUDE_CODE_SESSION_ATTENDED=0 FLEET_WAIT_INTERVAL_S=1; unset CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS
  # The waiter is killed as soon as it prints its budget line; the 60 s timeout
  # and the poll bound are hang caps only (DND-1007: they were 5 s).
  timeout 60 "${BIN}" wait --session-id "${SID_B}" --cwd "${CU}" >/dev/null 2>"${TMP}/uerr" & p=$!
  for i in $(seq 1 1200); do grep -q 'budget' "${TMP}/uerr" 2>/dev/null && break; sleep 0.05; done
  kill "${p}" 2>/dev/null; wait "${p}" 2>/dev/null )
has "[DND-484 test 5] headless default budget is the inbox policy's 540s" "$(cat "${TMP}/uerr")" "budget 540s, ceiling 600s, mode headless"

# The trap: a waiter killed mid-request leaves no curl behind.
# The answer is held until the checks below are done (DND-1007), so the curl
# is still in flight when the waiter is killed however slow the machine is.
fleet_respond "{\"status\":200,\"hold_file\":\"${TMP}/hold-trap\",\"body\":${DRAIN_B}}"
before="$(fleet_log_count)"
# Every bound here outlasts the checks below (DND-1007), so none of them can
# end the request first: curl's max-time is 300 s, the waiter's budget 300 s,
# the server's hold cap 120 s, and each wait below caps at 60 s. A curl that
# died is one the trap killed, and a waiter that exited is one TERM ended.
# curl's argv is only `curl --config -` (the URL rides stdin), so its survivors
# are found by an environment marker every descendant inherits.
MARK="dnd484-reap-$$-${RANDOM}"
FLEET_WAIT_TEST_MARK="${MARK}" FLEET_MAX_TIME_S=300 "${BIN}" wait --session-id "${SID_B}" --cwd "${CU}" --interval 1 --budget 300 >/dev/null 2>&1 &
WPID=$!
marked() { grep -lz "^FLEET_WAIT_TEST_MARK=${MARK}\$" /proc/[0-9]*/environ 2>/dev/null | cut -d/ -f3 | tr '\n' ' ' | sed 's/ $//'; }
fleet_wait_count "$((before + 1))"
has "wait: fixture: a curl is in flight when the waiter is killed" "$(for p in $(marked); do cat "/proc/${p}/comm" 2>/dev/null; done)" curl
kill -TERM "${WPID}"; timeout 60 tail --pid="${WPID}" -f /dev/null
check "wait: killed mid-request, it exits" bash -c '! kill -0 "$0" 2>/dev/null' "${WPID}"
left=""
for i in $(seq 1 1200); do left="$(marked)"; [ -z "${left}" ] && break; sleep 0.05; done
eq "wait: ... and no descendant (its curl included) survives it" "${left}" ""
[ -n "${left}" ] && kill ${left} 2>/dev/null
touch "${TMP}/hold-trap"
fleet_respond "{\"status\":200,\"body\":${DRAIN_B}}"

# Without pgrep the trap cannot list the poll's tree: wait refuses to start
# (exit 1, Fix:), while check -- which the drain guard runs -- does not need it.
NOPG="${TMP}/no-pgrep-bin"
mkdir -p "${NOPG}"
IFS=: read -r -a path_dirs <<<"${PATH}"
for d in "${path_dirs[@]}"; do
  [ -d "${d}" ] || continue
  for f in "${d}"/*; do
    b="${f##*/}"
    [ "${b}" = pgrep ] && continue
    [ -e "${NOPG}/${b}" ] || ln -s "${f}" "${NOPG}/${b}" 2>/dev/null
  done
done
before="$(fleet_log_count)"
PATH="${NOPG}" "${BIN}" wait --session-id "${SID_B}" --cwd "${CU}" --interval 1 --budget 5 >/dev/null 2>"${TMP}/perr"
eq "wait: no pgrep on PATH is exit 1" "$?" 1
has "wait: ... names pgrep with a Fix:" "$(cat "${TMP}/perr")" "pgrep is not on PATH"
eq "wait: ... and asks nothing" "$(( $(fleet_log_count) - before ))" 0
PATH="${NOPG}" "${BIN}" check --session-id "${SID_B}" --cwd "${CU}" >/dev/null 2>&1
eq "check: runs without pgrep (drain answer: exit 3)" "$?" 3

# The foreign-line rule, as the attendant runs it.
own_rc() { "${BIN}" own --session-id "${SID}" "$@" >"${TMP}/oout" 2>"${TMP}/oerr"; echo "$?"; }
eq "own: this session's line is own (exit 0)" "$(own_rc --line-session-id "${SID}"):$(cat "${TMP}/oout")" "0:own"
eq "own: another session's line is foreign (exit 3)" "$(own_rc --line-session-id "${SID_B}"):$(cat "${TMP}/oout")" "3:foreign"
eq "own: an empty line id is foreign" "$(own_rc --line-session-id ""):$(cat "${TMP}/oout")" "3:foreign"
eq "own: no line id is foreign" "$(own_rc):$(cat "${TMP}/oout")" "3:foreign"
eq "own: an unsafe line id is foreign" "$(own_rc --line-session-id '$(touch x)'):$(cat "${TMP}/oout")" "3:foreign"
before="$(fleet_log_count)"
own_rc --line-session-id "${SID_B}" >/dev/null
eq "own: makes no request" "$(( $(fleet_log_count) - before ))" 0

# Test 7b (deterministic half): the waiter and the inbox line both wake the
# session; each runs claim; exactly one CLAIMED, so exactly one admiral.
CROOT="${TMP}/coord"
mkdir -p "${CROOT}/run-484"
printf '# state\n' > "${CROOT}/run-484/state.md"
RESUME="${AI}/bin/fleet-resume"
"${RESUME}" drained --run-id run-484 --session-id "${SID_B}" --root "${CROOT}" >/dev/null 2>&1
fleet_respond "{\"status\":200,\"body\":${RUN_B}}"
fw --interval 1 --budget 30
eq "[DND-484 test 7b] the waiter wakes (exit 0)" "${RC}" 0
c1="$("${RESUME}" claim --session-id "${SID_B}" --root "${CROOT}" 2>/dev/null | grep -c '^CLAIMED')"
c2="$("${RESUME}" claim --session-id "${SID_B}" --root "${CROOT}" 2>/dev/null | grep -c '^CLAIMED')"
eq "[DND-484 test 7b] waiter wake claims the run once, inbox wake claims nothing" "${c1}+${c2}" "1+0"
kill "${SERVER_PID}" 2>/dev/null; wait "${SERVER_PID}" 2>/dev/null; SERVER_PID=""


finish wait
