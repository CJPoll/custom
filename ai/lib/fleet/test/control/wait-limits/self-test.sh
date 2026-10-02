#!/usr/bin/env bash
# fleet-control suite, part wait-limits (DND-1361 split of DND-1007's wait part): the resume waiter (DND-484) tests 3-5 (refusals, usage, the budget), its trap, own, and test 7b.
# Discovered by harness-gate; `ai/bin/fleet-control --self-test` runs every part.
# Shared setup: ../common.sh, ../fixture.sh and ../wait-fixture.sh.
# The wait parts spend their time in the waiter's real 1 s polls and 2-3 s
# budgets. Split three ways they run side by side in the gate; every case and
# assertion of the one wait part is kept, each in exactly one part.

# shellcheck source=../common.sh
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)/common.sh"

# shellcheck source=../fixture.sh
. "${CONTROL}/fixture.sh"

# shellcheck source=../wait-fixture.sh
. "${CONTROL}/wait-fixture.sh"

echo "== wait-limits: refusals, usage, the budget, the trap, own and 7b (DND-484)"
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
# DND-1719: the poll below must not take that refusal (it says "--budget 600s")
# for the waiter's budget line. When it did, it killed the waiter before the
# line was written, and the verdict turned on scheduling.
has "[DND-1719] fixture: the refusal names --budget, as the stale file did" "$(cat "${TMP}/uerr")" "--budget 600s"
if fw_budget_line_seen "${TMP}/uerr"; then
  bad "[DND-1719] the 600s refusal is not read as the waiter's budget line" "$(cat "${TMP}/uerr")"
else
  ok "[DND-1719] the 600s refusal is not read as the waiter's budget line"
fi
( export CLAUDE_CODE_ENTRYPOINT=sdk-cli CLAUDE_CODE_SESSION_ATTENDED=0 FLEET_WAIT_INTERVAL_S=1; unset CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS
  fw_until_budget_line "${TMP}/uerr" )
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

# DND-1719: a client that is gone before its answer is written (the killed
# waiter's curl above) is not a fake-server error. The server used to print a
# BrokenPipeError traceback for it, which filled a failing run's tail and hid
# the real FAIL detail. Made deterministic: a second fake server, its stderr
# kept apart; the client resets the connection (SO_LINGER 0) while the answer
# is held, the answer is released only after that, and the test waits on the
# server's "answered" marker, which it writes after its own error handling and
# which says what became of the answer.
GONE="${TMP}/gone"
mkdir -p "${GONE}"
printf '{"status":200,"hold_file":"%s/release","answered_file":"%s/answered","body":{}}\n' "${GONE}" "${GONE}" > "${GONE}/responses.json"
python3 "${FAKE}" "${GONE}/port" "${GONE}/server.log" "${GONE}/responses.json" "${TMP}/token" 2>"${GONE}/server.err" &
SPARE_SERVER_PID=$!
for i in $(seq 1 1200); do [ -s "${GONE}/port" ] && break; sleep 0.05; done
check "[DND-1719] fixture: the second fake server started" test -s "${GONE}/port"
timeout 60 python3 - "$(cat "${GONE}/port" 2>/dev/null)" "${GONE}/server.log" <<'PY'
import os, socket, struct, sys, time
port, log = int(sys.argv[1]), sys.argv[2]
s = socket.create_connection(("127.0.0.1", port))
s.sendall(b"GET /api/v1/fleet/sessions/x/control HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n")
# The request is logged before the held answer; close only once it is.
while not (os.path.exists(log) and os.path.getsize(log) > 0):
    time.sleep(0.05)
s.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER, struct.pack("ii", 1, 0))
s.close()
PY
touch "${GONE}/release"
for i in $(seq 1 1200); do [ -e "${GONE}/answered" ] && break; sleep 0.05; done
eq "[DND-1719] fixture: the server found the client gone when it answered" "$(cat "${GONE}/answered" 2>/dev/null)" "gone"
kill "${SPARE_SERVER_PID}" 2>/dev/null; wait "${SPARE_SERVER_PID}" 2>/dev/null; SPARE_SERVER_PID=""
eq "[DND-1719] a client gone before its answer is not a fake-server error" "$(cat "${GONE}/server.err")" ""

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

finish wait-limits
