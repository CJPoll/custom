#!/usr/bin/env bash
# fleet-control suite, part server (DND-1007 split of DND-443's suite): fleet-control check/fetch against the fake server, and usage.
# Discovered by harness-gate; `ai/bin/fleet-control --self-test` runs every part.
# Shared setup: ../common.sh (and ../fixture.sh for the fake-server parts).

# shellcheck source=../common.sh
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)/common.sh"

# shellcheck source=../fixture.sh
. "${CONTROL}/fixture.sh"

echo "== end to end (fake server)"
fleet_start_server || exit 1
fleet_respond "{\"status\":200,\"body\":${GOOD}}"

fc check --session-id "${SID}" --cwd "${GS}" --now "${THU_10}"
eq "[acceptance] gen_saas session, 10:00 MT, server says run: exit 0" "${RC}" 0
eq "[acceptance] ... basis server" "${OUT}" "desired=run reason=default until=unbounded basis=server"
eq "server answer: no warning" "${ERR}" ""
REQ="$(fleet_last_request)"
eq "GET, not POST" "$(jq -r .method <<<"${REQ}")" GET
eq "the control path" "$(jq -r .path <<<"${REQ}")" "/api/v1/fleet/sessions/${SID}/control"
eq "bearer token sent" "$(jq -r .auth_ok <<<"${REQ}")" true
eq "token in no argv" "$(jq -c .argv_leak <<<"${REQ}")" "[]"
eq "token in no environment" "$(jq -c .environ_leak <<<"${REQ}")" "[]"
check "cache written" test -f "${CACHE}"
eq "cache = answer + fetched_at" "$(jq -c 'del(.fetched_at)' "${CACHE}")" "${GOOD}"
eq "fetched_at is the check's now" "$(jq -r .fetched_at "${CACHE}")" "$(fleet_epoch_iso "${THU_10}")"

# Warm cache, server gone: recompute says run (the coordinator's acceptance, basis recomputed).
kill "${SERVER_PID}" 2>/dev/null; wait "${SERVER_PID}" 2>/dev/null; SERVER_PID=""
fleet_point_at "http://127.0.0.1:$(fleet_closed_port)/mcp"
fc check --session-id "${SID}" --cwd "${GS}" --now "$((THU_10 + 600))"
eq "[acceptance] warm cache, server unreachable: exit 0" "${RC}" 0
eq "[acceptance] ... basis recomputed:server-unreachable" "${OUT}" "desired=run reason=default until=unbounded basis=recomputed:server-unreachable"
has "recomputed: warns on stderr" "${ERR}" "WARNING"
has "recomputed: the warning names the basis" "${ERR}" "basis recomputed:server-unreachable"
has "recomputed: the warning carries Fix:" "${ERR}" "Fix:"

# The owner-accepted consequence: no cache, gen_saas, work hours -> deny, loudly.
rm -f "${CACHE}"
fc check --session-id "${SID}" --cwd "${GS}" --now "${THU_10}"
eq "no cache, gen_saas, 10:00 MT: exit 3 (drain)" "${RC}" 3
eq "... basis local-rule:server-unreachable,no-cache" "${OUT}" "desired=drain reason=metering:personal until=2026-09-25T00:00:00Z basis=local-rule:server-unreachable,no-cache"
has "... warns naming the project and domain" "${ERR}" "project gen_saas, domain personal"
fc check --session-id "${SID}" --cwd "${GS}" --now "$(den "2026-09-24 19:00")"
eq "no cache, gen_saas, 19:00 MT: run" "${RC}:${OUT##* }" "0:basis=local-rule:server-unreachable,no-cache"
has "... still warns" "${ERR}" "WARNING"
fc check --session-id "${SID}" --cwd "${CU}" --now "${THU_10}"
eq "no cache, custom (blend), 10:00 MT: run" "${RC}" 0
has "... warns" "${ERR}" "WARNING"
fc check --session-id "${SID}" --cwd "${TMP}" --now "${THU_10}"
eq "no cache, unregistered repo counts as personal: drain" "${RC}" 3
check "no cache file was created by a failed read" test ! -e "${CACHE}"

# Each cause is its own outcome (the MISS, not just the hit).
rm -f "${TMP}/port"   # fleet_start_server waits for a NEW port file
fleet_start_server || exit 1
expect_basis() {
  local name="$1" want_rc="$2" want_basis="$3"
  shift 3
  fc check --session-id "${SID}" --now "${THU_10}" "$@"
  eq "${name}: exit" "${RC}" "${want_rc}"
  eq "${name}: basis" "${OUT##*basis=}" "${want_basis}"
  has "${name}: warning" "${ERR}" "WARNING control state is unknown, so this answer is basis ${want_basis}"
}
rm -f "${CACHE}"
fleet_respond '{"status":401,"body":{"error":"unauthorized","fix":"bad token"}}'
expect_basis "server-refused (401)" 0 "local-rule:server-refused,no-cache" --cwd "${CU}"
has "server-refused: the server's fix is reported" "${ERR}" "bad token"
fleet_respond '{"status":422,"body":{"error":"invalid","fix":"bad id"}}'
expect_basis "server-refused (422)" 0 "local-rule:server-refused,no-cache" --cwd "${CU}"
fleet_respond '{"status":404,"body":{"error":"not_found"}}'
expect_basis "session-unregistered" 0 "local-rule:session-unregistered,no-cache" --cwd "${CU}"
fleet_respond '{"status":404,"raw_body":"<html>no route</html>"}'
expect_basis "malformed-answer (404 html)" 0 "local-rule:malformed-answer,no-cache" --cwd "${CU}"
has "... says the endpoint may not be deployed" "${ERR}" "not deployed"
fleet_respond '{"status":503,"body":{}}'
expect_basis "malformed-answer (503)" 0 "local-rule:malformed-answer,no-cache" --cwd "${CU}"
fleet_respond '{"status":200,"body":{"desired":"run"}}'
expect_basis "malformed-answer (bad 200)" 0 "local-rule:malformed-answer,no-cache" --cwd "${CU}"
check "a malformed answer is never cached" test ! -e "${CACHE}"
mv "${FLEET_CLAUDE_JSON}" "${TMP}/claude.json.off"
expect_basis "server-unconfigured (no MCP entry)" 0 "local-rule:server-unconfigured,no-cache" --cwd "${CU}"
mv "${TMP}/claude.json.off" "${FLEET_CLAUDE_JSON}"
mv "${ATHENA_INBOX_CLIENT_CONFIG}" "${TMP}/cfg.off"
expect_basis "server-unconfigured (no token)" 0 "local-rule:server-unconfigured,no-cache" --cwd "${CU}"
mv "${TMP}/cfg.off" "${ATHENA_INBOX_CLIENT_CONFIG}"

fleet_respond '{"status":503,"body":{}}'
mkdir -p "${CACHE%/*}"
printf 'not json' > "${CACHE}"
expect_basis "malformed-cache (not JSON)" 0 "local-rule:malformed-answer,malformed-cache" --cwd "${CU}"
answer run default null "${P1_SNAP}" other-session | jq -c '.fetched_at = "2026-09-24T15:00:00Z"' > "${CACHE}"
expect_basis "malformed-cache (another session's cache)" 3 "local-rule:malformed-answer,malformed-cache" --cwd "${GS}"
jq -c '.fetched_at = "2026-09-24T15:00:00Z" | .policy_snapshot = ($m | .metering.timezone = "Mars/Olympus")' --argjson m "${METER_SNAP}" <<<"${GOOD}" > "${CACHE}"
expect_basis "malformed-cache (unknown zone)" 0 "local-rule:malformed-answer,malformed-cache" --cwd "${CU}"
has "... names the zone" "${ERR}" "Mars/Olympus"
jq -c '.fetched_at = "2026-09-22T15:00:00Z"' <<<"${GOOD}" > "${CACHE}"
expect_basis "expired-cache (still used)" 0 "recomputed:malformed-answer,expired-cache" --cwd "${GS}"
has "... names its age" "${ERR}" "49 h old"
jq -c '.fetched_at = "2026-09-24T15:00:00Z"' <<<"${GOOD}" > "${CACHE}"
expect_basis "fresh cache" 0 "recomputed:malformed-answer" --cwd "${GS}"
jq -c '.fetched_at = "2026-09-24T18:00:00Z"' <<<"${GOOD}" > "${CACHE}"
expect_basis "a future fetched_at is expired, never fresh" 0 "recomputed:malformed-answer,expired-cache" --cwd "${GS}"
has "... says why" "${ERR}" "in the future"
rm -f "${CACHE}"
expect_basis "no-cache" 0 "local-rule:malformed-answer,no-cache" --cwd "${CU}"
(
  cd "${TMP}" || exit 1
  XDG_STATE_HOME="rel-state" "${BIN}" check --session-id "${SID}" --cwd "${CU}" --now "${THU_10}" >"${TMP}/out" 2>"${TMP}/err"
  echo "$?" > "${TMP}/rc"
)
eq "invalid-cache-path: exit" "$(cat "${TMP}/rc")" 0
eq "invalid-cache-path: basis" "$(sed 's/.*basis=//' "${TMP}/out")" "local-rule:malformed-answer,invalid-cache-path"
check "invalid-cache-path: nothing written under the relative path" test ! -e "${TMP}/rel-state"

# Recompute from a drain cache with the server down: an override survives.
jq -c '.desired = "drain" | .reason = "override:force_drain" | .policy_snapshot = $o | .fetched_at = "2026-09-24T15:00:00Z"' --argjson o "${OV_DRAIN}" <<<"${GOOD}" > "${CACHE}"
expect_basis "recomputed drain from a cached override" 3 "recomputed:malformed-answer" --cwd "${CU}"
eq "... reason and until" "${OUT% basis=*}" "desired=drain reason=override:force_drain until=unbounded"

# The cache is RECOMPUTED at now, never replayed: a cached drain whose override
# has since expired reads run.
jq -c '.desired = "drain" | .reason = "override:force_drain" | .until = "2026-09-24T15:30:00Z"
       | .policy_snapshot = ($o | .override.expires_at = "2026-09-24T15:30:00Z") | .fetched_at = "2026-09-24T15:00:00Z"' \
  --argjson o "${OV_DRAIN}" <<<"${GOOD}" > "${CACHE}"
expect_basis "a cached drain whose override expired recomputes to run" 0 "recomputed:malformed-answer" --cwd "${CU}"
eq "... reason default" "${OUT% basis=*}" "desired=run reason=default until=unbounded"

# Resume: the server answers run, so a stale drain cache cannot refuse it.
fleet_respond "{\"status\":200,\"body\":${GOOD}}"
fc check --session-id "${SID}" --cwd "${CU}" --now "${THU_10}"
eq "resume: server run beats a cached drain (exit 0)" "${RC}" 0
eq "resume: basis server" "${OUT##*basis=}" server
eq "resume: the cache now says run" "$(jq -r .desired "${CACHE}")" run

# fetch
fleet_respond "{\"status\":200,\"body\":$(answer drain override:force_drain null "${OV_DRAIN}")}"
out="$("${BIN}" fetch --session-id "${SID}" --cwd "${CU}" 2>&1)"; rc=$?
eq "fetch ok: exit 0" "${rc}" 0
has "fetch ok: says where it cached" "${out}" "cached at ${CACHE}"
eq "fetch ok: cache updated" "$(jq -r .desired "${CACHE}")" drain
fetch_rc() { fleet_respond "$2"; "${BIN}" fetch --session-id "${SID}" --cwd "${CU}" >/dev/null 2>"${TMP}/ferr"; eq "fetch: $1" "$?" "$3"; grep -q 'Fix:' "${TMP}/ferr" || bad "fetch: $1 carries Fix:"; }
fetch_rc "401 is exit 3" '{"status":401,"body":{"error":"unauthorized"}}' 3
fetch_rc "not_found is exit 3" '{"status":404,"body":{"error":"not_found"}}' 3
fetch_rc "503 is exit 5" '{"status":503,"body":{}}' 5
eq "a failed fetch leaves the cache as it was" "$(jq -r .desired "${CACHE}")" drain
kill "${SERVER_PID}" 2>/dev/null; wait "${SERVER_PID}" 2>/dev/null; SERVER_PID=""
fetch_rc "unreachable is exit 4" '{}' 4
mv "${ATHENA_INBOX_CLIENT_CONFIG}" "${TMP}/cfg.off"
fetch_rc "unconfigured is exit 1" '{}' 1
mv "${TMP}/cfg.off" "${ATHENA_INBOX_CLIENT_CONFIG}"


echo "== usage"
usage_rc() { local name="$1"; shift; ( unset CLAUDE_CODE_SESSION_ID; "${BIN}" "$@" >/dev/null 2>"${TMP}/uerr" ); eq "usage: ${name} is exit 2" "$?" 2; grep -q 'Fix:' "${TMP}/uerr" || bad "usage: ${name} carries Fix:"; }
usage_rc "no subcommand"
usage_rc "unknown subcommand" poke --session-id "${SID}"
usage_rc "no session id" check
usage_rc "an unsafe session id" check --session-id "../x"
usage_rc "a relative --cwd" check --session-id "${SID}" --cwd rel
usage_rc "--now on fetch" fetch --session-id "${SID}" --now 1
usage_rc "--now not epoch" check --session-id "${SID}" --now soon
out="$("${BIN}" --help)"; rc=$?
eq "--help exits 0" "${rc}" 0
has "--help names the exit codes" "${out}" "Exit 0 = run, 3 = drain"
has "--help documents wait" "${out}" "wait "
out="$(unset CLAUDE_CODE_SESSION_ID; "${BIN}" wait --help 2>"${TMP}/herr")"; rc=$?
eq "wait --help exits 0" "${rc}" 0
has "wait --help is on stdout" "${out}" "Usage: fleet-control"
eq "wait --help writes nothing on stderr" "$(cat "${TMP}/herr")" ""


finish server
