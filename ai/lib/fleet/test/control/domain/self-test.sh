#!/usr/bin/env bash
# fleet-control suite, part domain (DND-1007 split of DND-443's suite): the pure domain rules and the cache/zone effects (no server).
# Discovered by harness-gate; `ai/bin/fleet-control --self-test` runs every part.
# Shared setup: ../common.sh (and ../fixture.sh for the fake-server parts).

# shellcheck source=../common.sh
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)/common.sh"

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
eq "override drain with no expiry: drain, unbounded" "$(dec "${OV_DRAIN}" "${THU_10}")" "drain|override:force_drain|"
OV_EXPIRED='{"override":{"desired":"drain","expires_at":"2026-09-24T15:59:59Z"},"effective_domain":"blend","metering":{"enabled":false}}'
eq "expired override falls through to run" "$(dec "${OV_EXPIRED}" "${THU_10}")" "run|default|"
OV_AT_NOW='{"override":{"desired":"drain","expires_at":"2026-09-24T16:00:00Z"},"effective_domain":"blend","metering":{"enabled":false}}'
eq "override expiring exactly now has expired" "$(dec "${OV_AT_NOW}" "${THU_10}")" "run|default|"
OV_RUN="$(jq -c '.override = {"desired":"run","expires_at":"2026-09-24T20:00:00Z"}' <<<"${METER_SNAP}")"
eq "unexpired force_run beats metering" "$(dec "${OV_RUN}" "${THU_10}")" "run|override:force_run|2026-09-24T20:00:00Z"

# DND-877 (epic D-6, option (d)): a session with no live scoped admiral run is
# not metered. The server carries the exemption in the snapshot, so the
# harness recomputes it with no run knowledge of its own. Each row is the
# snapshot the server sends for that case (gen_saas
# Athena.FleetMeteringTest, describe "DND-877") and the answer the server
# gives at 10:00 MT Thursday with both metering switches on. Parity table:
# a harness change that meters from effective_domain alone fails row 1.
# Distinct server cases share a snapshot on purpose (no run and lost-only;
# scoped and drained): the server folds the run facts into the snapshot, and
# these rows pin that the harness needs nothing more.
NO_RUN_SNAP='{"override":null,"effective_domain":"personal","metering":{"enabled":false}}'
BLEND_RUN_SNAP="$(jq -c '.effective_domain = "blend"' <<<"${METER_SNAP}")"
NO_RUN_PAUSED="$(jq -c '.override = {"desired":"drain","expires_at":null}' <<<"${NO_RUN_SNAP}")"
while IFS='|' read -r name snap want; do
  eq "[DND-877 parity] ${name}" "$(dec "${!snap}" "${THU_10}")" "${want}"
done <<'ROWS'
no run, personal, work hours: run, so its first admiral spawns|NO_RUN_SNAP|run|default|
its run reported a personal scope: drain until 18:00 MT|METER_SNAP|drain|metering:personal|2026-09-25T00:00:00Z
its only run is lost or finished (no live run): run|NO_RUN_SNAP|run|default|
a drained personal run, the session's newest, stays live: drain|METER_SNAP|drain|metering:personal|2026-09-25T00:00:00Z
a blend-scoped run: never metered|BLEND_RUN_SNAP|run|default|
metering switch off: unchanged|P1_SNAP|run|default|
no run, owner pause: the override still drains|NO_RUN_PAUSED|drain|override:force_drain|
ROWS

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

# DND-876: `until` is the first instant the in-work-hours answer changes (the
# server's WorkHours.next_boundary/2), so abutting and overlapping windows on
# the day read as one span. Before DND-876 the harness answered the end of the
# latest-ending window covering `now`, and disagreed with the server.
wins() { jq -c --argjson w "$1" '.metering.work_windows = $w' <<<"${METER_SNAP}"; }
eq "abutting windows 08-12 + 12-18 at 10:00 MT: until 18:00 MT" \
  "$(dec "$(wins '[{"days":[4],"start":"08:00","end":"12:00"},{"days":[4],"start":"12:00","end":"18:00"}]')" "${THU_10}")" \
  "drain|metering:personal|2026-09-25T00:00:00Z"
eq "overlapping windows 08-12 + 11-14 at 09:00 MT: until 14:00 MT" \
  "$(dec "$(wins '[{"days":[4],"start":"08:00","end":"12:00"},{"days":[4],"start":"11:00","end":"14:00"}]')" "$(den "2026-09-24 09:00")")" \
  "drain|metering:personal|2026-09-24T20:00:00Z"
eq "a chain 12-13 + 08-10 + 10-12 (any order) at 09:00 MT: until 13:00 MT" \
  "$(dec "$(wins '[{"days":[4],"start":"12:00","end":"13:00"},{"days":[4],"start":"08:00","end":"10:00"},{"days":[4],"start":"10:00","end":"12:00"}]')" "$(den "2026-09-24 09:00")")" \
  "drain|metering:personal|2026-09-24T19:00:00Z"
eq "a one-minute gap 08-12 + 12:01-18 is two spans: until 12:00 MT" \
  "$(dec "$(wins '[{"days":[4],"start":"08:00","end":"12:00"},{"days":[4],"start":"12:01","end":"18:00"}]')" "${THU_10}")" \
  "drain|metering:personal|2026-09-24T18:00:00Z"
eq "a window on another weekday never extends the span: until 12:00 MT" \
  "$(dec "$(wins '[{"days":[4],"start":"08:00","end":"12:00"},{"days":[5],"start":"12:00","end":"18:00"}]')" "${THU_10}")" \
  "drain|metering:personal|2026-09-24T18:00:00Z"
eq "a span ending in the spring-forward gap (02:30 MT, 2026-03-08) ends when the clock jumps: 03:00 MDT" \
  "$(dec "$(wins '[{"days":[7],"start":"01:00","end":"02:30"}]')" "$(date -u -d '2026-03-08 08:30' +%s)")" \
  "drain|metering:personal|2026-03-08T09:00:00Z"
eq "a span ending in the fall-back hour (01:30 MT, 2026-11-01) ends at its first pass: 01:30 MDT" \
  "$(dec "$(wins '[{"days":[7],"start":"00:30","end":"01:30"}]')" "$(date -u -d '2026-11-01 06:45' +%s)")" \
  "drain|metering:personal|2026-11-01T07:30:00Z"
eq "a span ending in the fall-back hour, with now in the SECOND pass (01:15 MST, 08:15Z) of that same window, ends at the second pass: 01:30 MST" \
  "$(dec "$(wins '[{"days":[7],"start":"00:30","end":"01:30"}]')" "$(date -u -d '2026-11-01 08:15' +%s)")" \
  "drain|metering:personal|2026-11-01T08:30:00Z"
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

# DND-484 test 6: the resume waiter's outcome over every (exit, basis, cause)
# cell, and the foreign-line rule.
wo() { fleet_wait_outcome "$@" | tr '\t' '|'; }
eq "wait: run on basis server resumes"            "$(wo 0 server)" "resume|"
eq "wait: drain on basis server keeps polling"    "$(wo 3 server)" "continue|"
for sc in server-unreachable malformed-answer; do
  for cc in "" expired-cache; do
    eq "wait: recomputed run (${sc}${cc:+,${cc}}) is never a resume" "$(wo 0 "recomputed:${sc}${cc:+,${cc}}")" "continue|"
    eq "wait: recomputed drain (${sc}${cc:+,${cc}}) keeps polling"   "$(wo 3 "recomputed:${sc}${cc:+,${cc}}")" "continue|"
  done
  for cc in no-cache malformed-cache; do
    eq "wait: local-rule run (${sc},${cc}) is never a resume"  "$(wo 0 "local-rule:${sc},${cc}")" "continue|"
    eq "wait: local-rule drain (${sc},${cc}) keeps polling"    "$(wo 3 "local-rule:${sc},${cc}")" "continue|"
  done
  eq "wait: ${sc} with an invalid cache path is refused" "$(wo 0 "local-rule:${sc},invalid-cache-path")" "refused|invalid-cache-path"
done
for sc in session-unregistered server-refused server-unconfigured; do
  for rc in 0 3; do
    eq "wait: recomputed exit ${rc} on ${sc} is refused" "$(wo "${rc}" "recomputed:${sc}")" "refused|${sc}"
    eq "wait: local-rule exit ${rc} on ${sc} is refused" "$(wo "${rc}" "local-rule:${sc},no-cache")" "refused|${sc}"
  done
done
eq "wait: a refusal cause given directly is refused"   "$(wo "" "" invalid-cache-path)" "refused|invalid-cache-path"
eq "wait: an unknown direct cause is a fault"          "$(wo "" "" because)" "fault|because"
eq "wait: check exit 1 is a fault, never a resume"     "$(wo 1 server)" "fault|"
eq "wait: check exit 2 is a fault"                     "$(wo 2 "")" "fault|"
eq "wait: an empty basis on exit 0 is a fault"         "$(wo 0 "")" "fault|"
eq "wait: an unknown basis kind is a fault"            "$(wo 0 "guessed:server-unreachable")" "fault|"
eq "wait: an unknown cause token is a fault"           "$(wo 0 "recomputed:cosmic-rays")" "fault|cosmic-rays"
eq "wait: a bare kind with no cause is a fault"        "$(wo 0 "recomputed:")" "fault|"
eq "wait: server with a suffix is not server"          "$(wo 0 "server,x")" "fault|"
eq "line: own id is own"                 "$(fleet_control_line_is_own "${SID}" "${SID}")" own
eq "line: another session's id is foreign" "$(fleet_control_line_is_own "5f488432-0000" "${SID}")" foreign
eq "line: an empty line id is foreign"   "$(fleet_control_line_is_own "" "${SID}")" foreign
eq "line: an absent line id is foreign"  "$(fleet_control_line_is_own)" foreign
eq "line: an empty own id is never own"  "$(fleet_control_line_is_own "" "")" foreign
eq "line: a prefix is foreign"           "$(fleet_control_line_is_own "${SID%?}" "${SID}")" foreign
eq "line: an unsafe id is foreign"       "$(fleet_control_line_is_own "../${SID}" "../${SID}")" foreign
fleet_control_line_is_own "x" "${SID}" >/dev/null; eq "line: foreign is status 1" "$?" 1
fleet_control_line_is_own "${SID}" "${SID}" >/dev/null; eq "line: own is status 0" "$?" 0

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


finish domain
