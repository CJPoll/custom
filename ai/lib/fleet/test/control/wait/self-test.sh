#!/usr/bin/env bash
# fleet-control suite, part wait (DND-1361 split of DND-1007's wait part): the resume waiter (DND-484) test 1, resuming from the server alone.
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

echo "== wait: the resume waiter (DND-484)"
# The defect: with two sessions in one project, the control_changed line for
# session B lands on the project's session channel, which ANOTHER session's
# read-inbox holds (consumer lock) and acks. B never sees its wake. The waiter
# must resume B from B's own GET /control alone, touching no inbox state.
rm -f "${TMP}/port"
fleet_start_server || exit 1

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

kill "${SERVER_PID}" 2>/dev/null; wait "${SERVER_PID}" 2>/dev/null; SERVER_PID=""


finish wait
