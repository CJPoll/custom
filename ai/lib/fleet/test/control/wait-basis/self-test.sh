#!/usr/bin/env bash
# fleet-control suite, part wait-basis (DND-1361 split of DND-1007's wait part): the resume waiter (DND-484) test 2, a non-server run is never a resume.
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

echo "== wait-basis: a non-server run is never a resume (DND-484 test 2)"
rm -f "${TMP}/port"
fleet_start_server || exit 1

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


finish wait-basis
