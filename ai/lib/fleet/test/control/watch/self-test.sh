#!/usr/bin/env bash
# fleet-control suite, part watch (DND-1007 split of DND-443's suite): admiral-report-watch CONTROL lines.
# Discovered by harness-gate; `ai/bin/fleet-control --self-test` runs every part.
# Shared setup: ../common.sh (and ../fixture.sh for the fake-server parts).

# shellcheck source=../common.sh
. "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)/common.sh"

# shellcheck source=../fixture.sh
. "${CONTROL}/fixture.sh"

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
rm -f "${CACHE}"
fleet_respond '{"status":503,"body":{}}'
out="$(cd "${CU}" && watch --session-id "${SID}" --max-loops 3)"
eq "watch: a non-server run is announced once" "$(grep -c '^CONTROL: run on basis' <<<"${out}")" 1
has "watch: ... names its basis" "${out}" "CONTROL: run on basis local-rule:malformed-answer,no-cache, NOT the server"
has "watch: ... carries fleet-control's warning" "${out}" "WARNING control state is unknown"
fleet_respond "[{\"status\":503,\"body\":{}},{\"status\":200,\"body\":${GOOD}}]"
out="$(cd "${CU}" && watch --session-id "${SID}" --max-loops 2)"
has "watch: back to a server run is announced" "$(grep '^CONTROL:' <<<"${out}" | tail -n 1)" "CONTROL: run — desired=run"
out="$(unset CLAUDE_CODE_SESSION_ID; watch --max-loops 3)"
eq "watch: no session id says so once" "$(grep -c '^CONTROL: unavailable' <<<"${out}")" 1
has "watch: ... with a Fix:" "${out}" "Fix:"
out="$(watch --session-id "../bad" --max-loops 3)"
eq "watch: a check error prints CONTROL: unknown once" "$(grep -c '^CONTROL: unknown' <<<"${out}")" 1
has "watch: ... never as run" "${out}" "never read an error as run"
mkdir -p "${WREP}"
touch -d '+1 hour' "${WREP}/DND-1-report.md"   # newer than the watcher's start stamp
# Not through watch(): it already passes --control-s, and the watcher refuses a
# flag given twice (DND-813) rather than silently keeping the second.
out="$(timeout 60 "${WATCH}" "${WRUN}" --reports-dir "${WREP}" --poll-s 0 --control-s 999 --session-id "${SID}" --max-loops 1 2>&1)"
has "watch: a new report is still printed" "${out}" "${WREP}/DND-1-report.md"
out="$("${WATCH}" --help)"; eq "watch: --help exits 0" "$?" 0
"${WATCH}" >/dev/null 2>&1; eq "watch: no run-id is exit 2" "$?" 2
rm -f "/tmp/admiral-${WRUN}-seen"
kill "${SERVER_PID}" 2>/dev/null; wait "${SERVER_PID}" 2>/dev/null; SERVER_PID=""


finish watch
