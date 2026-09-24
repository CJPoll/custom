#!/usr/bin/env bash
# self-test.sh -- the fleet-control suite (DND-443). Discovered by harness-gate
# (every committed `self-test.sh` runs) and run by `ai/bin/fleet-control
# --self-test`.
#
# TDD order:
#   1. domain  -- lib/fleet/control-domain.sh: shapes, desired/3 mirror, the
#      local rule, work-hours math (DST, weekend, holiday, boundaries), causes;
#   2. effects -- lib/fleet/control-effects.sh: cache path, atomic write, read;
#   3. end to end -- bin/fleet-control against a FAKE server (loopback only;
#      never prod): every basis, every cause as its own outcome (the MISS is
#      tested, not just the hit), the coordinator's acceptance case, and resume
#      through a stale drain cache.

set -u

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
TESTS="$(cd -- "${HERE}/.." && pwd -P)"
LIB="$(cd -- "${TESTS}/.." && pwd -P)"
AI="$(cd -- "${LIB}/../.." && pwd -P)"
BIN="${AI}/bin/fleet-control"
FAKE="${TESTS}/fake-fleet-server.py"

PASS=0
FAIL=0
ok()   { PASS=$((PASS + 1)); printf 'ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL + 1)); printf 'FAIL %s\n' "$1"; [ -n "${2:-}" ] && printf '     %s\n' "$2"; return 0; }
check() { local name="$1"; shift; if "$@"; then ok "${name}"; else bad "${name}"; fi; }
eq()   { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$3], got [$2]"; fi; }
has()  { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "[$3] not in [$2]" ;; esac; }
hasnt() { case "$2" in *"$3"*) bad "$1" "[$3] unexpectedly in [$2]" ;; *) ok "$1" ;; esac; }

for dep in jq curl python3 git flock timeout date; do
  command -v "${dep}" >/dev/null 2>&1 || { echo "fleet-control self-test: FAIL -- ${dep} is not on PATH"; echo "  Fix: install ${dep}; this suite does not skip."; exit 1; }
done
[ -f /usr/share/zoneinfo/America/Denver ] || [ -f "${TZDIR:-/nonexistent}/America/Denver" ] || {
  echo "fleet-control self-test: FAIL -- the tz database has no America/Denver"; echo "  Fix: install tzdata; the work-hours cases need it."; exit 1; }

# shellcheck source=../../domain.sh
. "${LIB}/domain.sh"
# shellcheck source=../../control-domain.sh
. "${LIB}/control-domain.sh"

TMP="$(mktemp -d)" || { echo "FAIL mktemp"; exit 1; }
SERVER_PID=""
cleanup() {
  [ -n "${SERVER_PID}" ] && kill "${SERVER_PID}" 2>/dev/null
  rm -rf "${TMP}"
}
trap cleanup EXIT INT TERM

# den <YYYY-MM-DD HH:MM[:SS]> -- epoch of a wall-clock time in America/Denver.
den() { TZ=America/Denver date -d "$1" +%s; }

SID="0cc59a5e-6c65-495e-a216-83c6a0bf2d56"
THU_10=$(den "2026-09-24 10:00")      # Thursday, work hours (the acceptance instant)
P1_SNAP='{"override":null,"effective_domain":"personal","metering":{"enabled":false}}'
METER_SNAP="$(fleet_local_rule_snapshot gen_saas)"   # metering on, personal, 08-18 M-F

# answer <desired> <reason> <until-json> <snapshot-json> [sid]
answer() {
  jq -n -c --arg s "${5:-${SID}}" --arg d "$1" --arg r "$2" --argjson u "$3" --argjson p "$4" \
    '{claude_session_id: $s, desired: $d, reason: $r, until: $u, policy_snapshot: $p}'
}

echo "== domain"

check "fleet worker: athena-admiral"   fleet_is_fleet_worker athena-admiral
check "fleet worker: athena-captain"   fleet_is_fleet_worker athena-captain
for t in athena-architect athena-diff-critic Explore general-purpose "" athena-admiralx xathena-captain; do
  check "not a fleet worker: [${t}]" bash -c '. "$0"; . "$1"; ! fleet_is_fleet_worker "$2"' "${LIB}/domain.sh" "${LIB}/control-domain.sh" "${t}"
done

eq "control url" "$(fleet_control_url https://a.example "${SID}")" "https://a.example/api/v1/fleet/sessions/${SID}/control"
check "control url refuses an unsafe id" bash -c '. "$0"; . "$1"; ! fleet_control_url https://a.example "../x"' "${LIB}/domain.sh" "${LIB}/control-domain.sh"
eq "reports url still derives (origin refactor)" "$(fleet_reports_url https://a.example/mcp)" "https://a.example/api/v1/fleet/reports"

eq "domain: walt_ui is work"       "$(fleet_project_domain walt_ui)" work
eq "domain: custom is blend"       "$(fleet_project_domain custom)" blend
eq "domain: gen_saas is personal"  "$(fleet_project_domain gen_saas)" personal
eq "domain: unmapped is personal"  "$(fleet_project_domain somewhere)" personal
eq "domain: unresolved is personal" "$(fleet_project_domain "")" personal

GOOD="$(answer run default null "${P1_SNAP}")"
check "answer: P1 shape is well formed" fleet_answer_problem "${GOOD}" "${SID}"
check "answer: metering-on shape is well formed" fleet_answer_problem "$(answer drain metering:personal '"2026-09-25T00:00:00Z"' "${METER_SNAP}")" "${SID}"
check "answer: override shape is well formed" fleet_answer_problem "$(answer drain override:force_drain null '{"override":{"desired":"drain","expires_at":null},"effective_domain":"blend","metering":{"enabled":false}}')" "${SID}"
bad_answer() {
  local name="$1" json="$2" want="$3" out
  if out="$(fleet_answer_problem "${json}" "${SID}")"; then bad "answer refused: ${name}" "accepted"; else has "answer refused: ${name}" "${out}" "${want}"; fi
}
bad_answer "another session"     "$(answer run default null "${P1_SNAP}" other-session)" "not \"${SID}\""
bad_answer "extra key"           "$(jq -c '.extra = 1' <<<"${GOOD}")" "unexpected key(s) extra"
bad_answer "missing key"         "$(jq -c 'del(.until)' <<<"${GOOD}")" "missing until"
bad_answer "unknown desired"     "$(jq -c '.desired = "pause"' <<<"${GOOD}")" "is not run or drain"
bad_answer "unknown reason"      "$(jq -c '.reason = "because"' <<<"${GOOD}")" "not one of the reason classes"
bad_answer "reason contradicts desired" "$(jq -c '.reason = "override:force_drain"' <<<"${GOOD}")" "contradicts"
bad_answer "until not ISO UTC"   "$(jq -c '.until = "tomorrow"' <<<"${GOOD}")" "until is not null"
bad_answer "snapshot extra input" "$(jq -c '.policy_snapshot.holiday_source = "x"' <<<"${GOOD}")" "unexpected key(s) holiday_source"
bad_answer "metering on, no zone" "$(jq -c '.policy_snapshot.metering = {"enabled":true}' <<<"${GOOD}")" "missing"
bad_answer "window start after end" "$(jq -c --argjson m "$(jq -c '.metering.work_windows[0].start = "19:00"' <<<"${METER_SNAP}")" '.policy_snapshot = $m' <<<"${GOOD}")" "is not before end"
bad_answer "weekday 8"           "$(jq -c --argjson m "$(jq -c '.metering.work_windows[0].days = [8]' <<<"${METER_SNAP}")" '.policy_snapshot = $m' <<<"${GOOD}")" "ISO weekdays"
bad_answer "not JSON"            "not json" "not valid JSON"
check "cache: answer + fetched_at is well formed" fleet_cache_problem "$(jq -c '.fetched_at = "2026-09-24T16:00:00Z"' <<<"${GOOD}")" "${SID}"
check "cache: no fetched_at is malformed" bash -c '. "$0"; . "$1"; ! fleet_cache_problem "$2" "$3" >/dev/null' "${LIB}/domain.sh" "${LIB}/control-domain.sh" "${GOOD}" "${SID}"

# desired/3 mirror
dec() { fleet_desired "$1" "$2" | tr '\t' '|'; }
eq "[acceptance] P1 (metering off), personal, 10:00 MT Thursday: run default" "$(dec "${P1_SNAP}" "${THU_10}")" "run|default|"
eq "metering on, personal, 10:00 MT Thursday: drain until 18:00 MT" "$(dec "${METER_SNAP}" "${THU_10}")" "drain|metering:personal|2026-09-25T00:00:00Z"
eq "metering on, blend: run" "$(dec "$(fleet_local_rule_snapshot custom)" "${THU_10}")" "run|default|"
eq "metering on, work: run"  "$(dec "$(fleet_local_rule_snapshot walt_ui)" "${THU_10}")" "run|default|"
OV_DRAIN='{"override":{"desired":"drain","expires_at":null},"effective_domain":"blend","metering":{"enabled":false}}'
eq "override drain with no expiry: drain, unbounded" "$(dec "${OV_DRAIN}" "${THU_10}")" "drain|override:force_drain|"
OV_EXPIRED='{"override":{"desired":"drain","expires_at":"2026-09-24T15:59:59Z"},"effective_domain":"blend","metering":{"enabled":false}}'
eq "expired override falls through to run" "$(dec "${OV_EXPIRED}" "${THU_10}")" "run|default|"
OV_AT_NOW='{"override":{"desired":"drain","expires_at":"2026-09-24T16:00:00Z"},"effective_domain":"blend","metering":{"enabled":false}}'
eq "override expiring exactly now has expired" "$(dec "${OV_AT_NOW}" "${THU_10}")" "run|default|"
OV_RUN="$(jq -c '.override = {"desired":"run","expires_at":"2026-09-24T20:00:00Z"}' <<<"${METER_SNAP}")"
eq "unexpired force_run beats metering" "$(dec "${OV_RUN}" "${THU_10}")" "run|override:force_run|2026-09-24T20:00:00Z"

# Work-hours math (epic invariant I16): start inclusive, end exclusive, DST, weekend, holiday.
eq "07:59:59 MT is outside"   "$(dec "${METER_SNAP}" "$(den "2026-09-24 07:59:59")")" "run|default|"
eq "08:00:00 MT is inside"    "$(dec "${METER_SNAP}" "$(den "2026-09-24 08:00:00")" | cut -d'|' -f1)" "drain"
eq "17:59:59 MT is inside"    "$(dec "${METER_SNAP}" "$(den "2026-09-24 17:59:59")" | cut -d'|' -f1)" "drain"
eq "18:00:00 MT is outside"   "$(dec "${METER_SNAP}" "$(den "2026-09-24 18:00:00")")" "run|default|"
eq "Saturday 10:00 MT is outside" "$(dec "${METER_SNAP}" "$(den "2026-09-26 10:00")")" "run|default|"
eq "DST start Monday 08:00 MDT (14:00Z) inside, until 00:00Z" "$(dec "${METER_SNAP}" "$(date -u -d '2026-03-09 14:00' +%s)")" "drain|metering:personal|2026-03-10T00:00:00Z"
eq "DST start Monday 07:59 MDT (13:59Z) outside" "$(dec "${METER_SNAP}" "$(date -u -d '2026-03-09 13:59' +%s)")" "run|default|"
eq "DST end Monday 08:00 MST (15:00Z) inside, until 01:00Z" "$(dec "${METER_SNAP}" "$(date -u -d '2026-11-02 15:00' +%s)")" "drain|metering:personal|2026-11-03T01:00:00Z"
eq "DST end Monday 07:30 MST (14:30Z) outside" "$(dec "${METER_SNAP}" "$(date -u -d '2026-11-02 14:30' +%s)")" "run|default|"
HOLIDAY="$(jq -c '.metering.holidays = ["2026-09-24"]' <<<"${METER_SNAP}")"
eq "a holiday is outside" "$(dec "${HOLIDAY}" "${THU_10}")" "run|default|"
eq "blind local rule, personal: drain" "$(fleet_local_rule_blind gen_saas | tr '\t' '|')" "drain|metering:personal|"
eq "blind local rule, blend: run" "$(fleet_local_rule_blind custom | tr '\t' '|')" "run|default|"

eq "basis: server" "$(fleet_basis server)" server
eq "basis: recomputed" "$(fleet_basis recomputed server-unreachable)" "recomputed:server-unreachable"
eq "basis: recomputed, expired" "$(fleet_basis recomputed server-unreachable expired-cache)" "recomputed:server-unreachable,expired-cache"
eq "basis: local rule" "$(fleet_basis local-rule server-unreachable malformed-cache)" "local-rule:server-unreachable,malformed-cache"

eq "cause: transport failure"   "$(fleet_control_cause 7 000 "" "${SID}")" server-unreachable
eq "cause: timeout"             "$(fleet_control_cause 28 "" "" "${SID}")" server-unreachable
eq "cause: 200 good"            "$(fleet_control_cause 0 200 "${GOOD}" "${SID}")" ok
eq "cause: 200 bad shape"       "$(fleet_control_cause 0 200 '{"desired":"run"}' "${SID}")" malformed-answer
eq "cause: 200 for another session" "$(fleet_control_cause 0 200 "$(answer run default null "${P1_SNAP}" other)" "${SID}")" malformed-answer
eq "cause: 404 not_found"       "$(fleet_control_cause 0 404 '{"error":"not_found"}' "${SID}")" session-unregistered
eq "cause: 404 html (no endpoint)" "$(fleet_control_cause 0 404 '<html>' "${SID}")" malformed-answer
eq "cause: 401"                 "$(fleet_control_cause 0 401 '{"error":"unauthorized"}' "${SID}")" server-refused
eq "cause: 422"                 "$(fleet_control_cause 0 422 '{"error":"x","fix":"y"}' "${SID}")" server-refused
eq "cause: 503"                 "$(fleet_control_cause 0 503 '' "${SID}")" malformed-answer

causes_all="${FLEET_SERVER_CAUSES} ${FLEET_CACHE_CAUSES}"
eq "nine distinct cause tokens" "$(printf '%s\n' ${causes_all} | sort -u | grep -c .)" 9
eq "check line" "$(fleet_check_line drain override:force_drain "" server)" "desired=drain reason=override:force_drain until=unbounded basis=server"
eq "check exit run" "$(fleet_check_exit run)" 0
eq "check exit drain" "$(fleet_check_exit drain)" 3
eq "check exit other" "$(fleet_check_exit x)" 1

echo "== effects"
# shellcheck disable=SC1091
for f in err names descriptor logchan maildir fence session fs lock inbox; do . "${AI}/skills/athena:inbox/lib/${f}.sh"; done
# shellcheck source=../../effects.sh
. "${LIB}/effects.sh"
# shellcheck source=../../control-effects.sh
. "${LIB}/control-effects.sh"

export XDG_STATE_HOME="${TMP}/xdg"
eq "cache path" "$(fleet_control_cache_path "${SID}")" "${TMP}/xdg/athena/fleet/${SID}.json"
check "cache path: relative XDG_STATE_HOME is refused (status 2)" bash -c 'XDG_STATE_HOME=rel; . "$0"; . "$1"; . "$2"; . "$3"; fleet_control_cache_path x; [ $? -eq 2 ]' \
  "${LIB}/domain.sh" "${LIB}/control-domain.sh" "${LIB}/effects.sh" "${LIB}/control-effects.sh"
check "cache path: an unsafe id is refused (status 2)" bash -c '. "$0"; . "$1"; . "$2"; . "$3"; fleet_control_cache_path "../evil"; [ $? -eq 2 ]' \
  "${LIB}/domain.sh" "${LIB}/control-domain.sh" "${LIB}/effects.sh" "${LIB}/control-effects.sh"
case "$(fleet_control_cache_path "${SID}")" in */seen/*) bad "cache stays out of DND-433's seen/ dir" ;; *) ok "cache stays out of DND-433's seen/ dir" ;; esac
P="$(fleet_control_cache_path "${SID}")"
check "write cache" fleet_write_cache "${P}" '{"a":1}'
eq "cache mode 600" "$(stat -c %a "${P}")" 600
eq "cache dir mode 700" "$(stat -c %a "${P%/*}")" 700
eq "read cache round-trips" "$(fleet_read_cache "${P}")" '{"a":1}'
eq "no temp file left behind" "$(find "${P%/*}" -name '.cache.*' | grep -c .)" 0
fleet_read_cache "${TMP}/nope.json" >/dev/null; eq "read: absent is status 1" "$?" 1
mkdir -p "${TMP}/adir.json"; fleet_read_cache "${TMP}/adir.json" >/dev/null; eq "read: a directory is status 3" "$?" 3
head -c 70000 /dev/zero | tr '\0' 'x' > "${TMP}/big.json"; fleet_read_cache "${TMP}/big.json" >/dev/null; eq "read: oversize is status 3" "$?" 3
check "tz known: America/Denver" fleet_tz_known America/Denver
check "tz unknown: Mars/Olympus" bash -c '. "$0"; ! fleet_tz_known Mars/Olympus' "${LIB}/control-effects.sh"
check "tz refused: traversal" bash -c '. "$0"; ! fleet_tz_known ../../etc/passwd' "${LIB}/control-effects.sh"

echo "== end to end (fake server)"
# shellcheck source=../helpers.sh
. "${TESTS}/helpers.sh"
fleet_fixture_env
export FLEET_CONNECT_TIMEOUT_S=2 FLEET_MAX_TIME_S=3

# Two throwaway repos registered as the gen_saas and custom projects.
for p in gen_saas custom; do
  git init -q "${TMP}/${p}"
  jq -n --arg r "$(realpath "${TMP}/${p}/.git")" '{v: 1, repo: $r, channels: {}}' > "${ATHENA_INBOX_ROOT}/projects/${p}.json"
done
chmod 600 "${ATHENA_INBOX_ROOT}"/projects/*.json
GS="${TMP}/gen_saas"
CU="${TMP}/custom"
CACHE="${XDG_STATE_HOME}/athena/fleet/${SID}.json"

# fc <args...> -- run fleet-control check; sets OUT, ERR, RC.
fc() {
  OUT="$("${BIN}" "$@" 2>"${TMP}/err")"; RC=$?
  ERR="$(cat "${TMP}/err")"
}

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

echo "== admiral-report-watch CONTROL lines"
WATCH="${AI}/bin/admiral-report-watch"
WRUN="dnd-443-selftest-$$"
WREP="${TMP}/reports"
watch() { timeout 60 "${WATCH}" "${WRUN}" --reports-dir "${WREP}" --poll-s 0 --control-s 0 "$@" 2>&1; }
rm -f "${TMP}/port"
fleet_start_server || exit 1
DRAIN_Q="$(answer drain override:force_drain null "${OV_DRAIN}")"
fleet_respond "[{\"status\":200,\"body\":${GOOD}},{\"status\":200,\"body\":${DRAIN_Q}},{\"status\":200,\"body\":${DRAIN_Q}},{\"status\":200,\"body\":${GOOD}}]"
gets_before="$(grep -c '"method": "GET"' "${TMP}/server.log")"
out="$(watch --session-id "${SID}" --max-loops 4)"
eq "watch: run, drain, drain, run -> exactly two CONTROL lines" "$(grep -c '^CONTROL:' <<<"${out}")" 2
has "watch: the flip to drain is announced" "$(grep '^CONTROL:' <<<"${out}" | head -n 1)" "CONTROL: drain — desired=drain reason=override:force_drain"
has "watch: the flip back to run is announced" "$(grep '^CONTROL:' <<<"${out}" | tail -n 1)" "CONTROL: run — desired=run"
eq "watch: each of the 4 control checks asked the server" "$(( $(grep -c '"method": "GET"' "${TMP}/server.log") - gets_before ))" 4
fleet_respond "{\"status\":200,\"body\":${GOOD}}"
out="$(watch --session-id "${SID}" --max-loops 2)"
eq "watch: a steady run prints no CONTROL line" "$(grep -c '^CONTROL:' <<<"${out}")" 0
fleet_respond "{\"status\":200,\"body\":${DRAIN_Q}}"
out="$(watch --session-id "${SID}" --max-loops 3)"
eq "watch: a first answer of drain prints once" "$(grep -c '^CONTROL: drain' <<<"${out}")" 1
out="$(unset CLAUDE_CODE_SESSION_ID; watch --max-loops 3)"
eq "watch: no session id says so once" "$(grep -c '^CONTROL: unavailable' <<<"${out}")" 1
has "watch: ... with a Fix:" "${out}" "Fix:"
out="$(watch --session-id "../bad" --max-loops 3)"
eq "watch: a check error prints CONTROL: unknown once" "$(grep -c '^CONTROL: unknown' <<<"${out}")" 1
has "watch: ... never as run" "${out}" "never read an error as run"
mkdir -p "${WREP}"
touch -d '+1 hour' "${WREP}/DND-1-report.md"   # newer than the watcher's start stamp
out="$(watch --session-id "${SID}" --control-s 999 --max-loops 1)"
has "watch: a new report is still printed" "${out}" "${WREP}/DND-1-report.md"
out="$("${WATCH}" --help)"; eq "watch: --help exits 0" "$?" 0
"${WATCH}" >/dev/null 2>&1; eq "watch: no run-id is exit 2" "$?" 2
rm -f "/tmp/admiral-${WRUN}-seen"
kill "${SERVER_PID}" 2>/dev/null; wait "${SERVER_PID}" 2>/dev/null; SERVER_PID=""

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

echo
echo "${PASS} passed, ${FAIL} failed"
if [ "${FAIL}" -ne 0 ]; then
  echo "fleet-control self-test: FAIL"
  echo "  Fix: read the FAIL lines above; each names the rule it checks (athena-events.md -> Unknown control state)."
  exit 1
fi
echo "fleet-control self-test: OK"
