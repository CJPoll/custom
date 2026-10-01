#!/usr/bin/env bash
# self-test.sh -- the fleet-report suite (DND-433). Discovered by harness-gate
# (every committed `self-test.sh` runs) and run by `ai/bin/fleet-report
# --self-test`.
#
# Three layers, in TDD order:
#   1. domain  -- lib/fleet/domain.sh, pure functions, no fixtures;
#   2. effects -- lib/fleet/effects.sh against temp dirs and throwaway git repos;
#   3. end to end -- bin/fleet-report and hooks/fleet-report.sh against a FAKE
#      server (fake-fleet-server.py) that implements the contract's answers.
#      Never prod: every URL here is 127.0.0.1.
#
# The four cases the ticket names are marked [ticket]: the throttle holds; an
# unreachable server is distinct from a refusal; a relative git-common-dir is
# resolved (the DND-183 class); the token is never in argv (read from /proc).

set -u
# DND-1163: the athena:inbox bins resolve the session's project from
# CLAUDE_PROJECT_DIR, then /proc/$CLAUDE_PID/cwd, before the cwd. Scrubbed so
# the fixtures, not the Claude session running this suite, decide the project.
unset CLAUDE_PROJECT_DIR CLAUDE_PID

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
LIB="$(cd -- "${HERE}/.." && pwd -P)"
AI="$(cd -- "${LIB}/../.." && pwd -P)"
BIN="${AI}/bin/fleet-report"
HOOK="${AI}/hooks/fleet-report.sh"
FAKE="${HERE}/fake-fleet-server.py"

PASS=0
FAIL=0
ok()   { PASS=$((PASS + 1)); printf 'ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL + 1)); printf 'FAIL %s\n' "$1"; [ -n "${2:-}" ] && printf '     %s\n' "$2"; return 0; }
check() { local name="$1"; shift; if "$@"; then ok "${name}"; else bad "${name}"; fi; }
eq()   { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$3], got [$2]"; fi; }

for dep in jq curl python3 git flock setsid timeout; do
  command -v "${dep}" >/dev/null 2>&1 || { echo "fleet-report self-test: FAIL -- ${dep} is not on PATH"; echo "  Fix: install ${dep}; this suite does not skip."; exit 1; }
done

# shellcheck source=../domain.sh
. "${LIB}/domain.sh"

TMP="$(mktemp -d)" || { echo "FAIL mktemp"; exit 1; }
SERVER_PID=""
cleanup() {
  [ -n "${SERVER_PID}" ] && kill "${SERVER_PID}" 2>/dev/null
  # Detached reporters this suite started, by recorded pid only.
  if [ -f "${TMP}/pids" ]; then
    while read -r p; do [ -n "${p}" ] && kill "${p}" 2>/dev/null; done < "${TMP}/pids"
  fi
  rm -rf "${TMP}"
}
trap cleanup EXIT INT TERM

echo "== domain"

check "valid id: uuid"              fleet_valid_id "0cc59a5e-6c65-495e-a216-83c6a0bf2d56"
check "valid id: run id"            fleet_valid_id "2026-09-24-p1-fleet"
check "invalid id: empty"           bash -c '. "$0"; ! fleet_valid_id ""' "${LIB}/domain.sh"
check "invalid id: slash"           bash -c '. "$0"; ! fleet_valid_id "a/b"' "${LIB}/domain.sh"
check "invalid id: dot-dot"         bash -c '. "$0"; ! fleet_valid_id ".."' "${LIB}/domain.sh"
check "invalid id: leading dot"     bash -c '. "$0"; ! fleet_valid_id ".x"' "${LIB}/domain.sh"
check "invalid id: space"           bash -c '. "$0"; ! fleet_valid_id "a b"' "${LIB}/domain.sh"
check "invalid id: newline"         bash -c '. "$0"; ! fleet_valid_id "$(printf "a\nb")"' "${LIB}/domain.sh"
check "invalid id: 129 bytes"       bash -c '. "$0"; ! fleet_valid_id "$(printf "a%.0s" $(seq 1 129))"' "${LIB}/domain.sh"

check "notion id: dashed"           fleet_valid_notion_id "3e2349da-87fb-81ac-a4f5-ff241e915946"
check "notion id: bare"             fleet_valid_notion_id "3e2349da87fb81aca4f5ff241e915946"
check "notion id: upper case"       fleet_valid_notion_id "3E2349DA87FB81ACA4F5FF241E915946"
for bad_id in "" "Athena" "3e2349da87fb81aca4f5ff241e91594" "3e2349da87fb-81aca4f5ff241e915946" \
  "https://www.notion.so/3e2349da87fb81aca4f5ff241e915946" " 3e2349da87fb81aca4f5ff241e915946" \
  "3e2349da87fb81aca4f5ff241e91594g"; do
  check "notion id refused: ${bad_id@Q}" bash -c '. "$0"; ! fleet_valid_notion_id "$1"' "${LIB}/domain.sh" "${bad_id}"
done
check "admiral state: finished"     fleet_valid_admiral_state finished
check "admiral state: running is not reportable" bash -c '. "$0"; ! fleet_valid_admiral_state running' "${LIB}/domain.sh"
check "admiral state: empty"        bash -c '. "$0"; ! fleet_valid_admiral_state ""' "${LIB}/domain.sh"

eq "reports url from https mcp url" "$(fleet_reports_url https://athena.cjpoll.me/mcp)" "https://athena.cjpoll.me/api/v1/fleet/reports"
eq "reports url keeps the port"     "$(fleet_reports_url http://127.0.0.1:4567/mcp)" "http://127.0.0.1:4567/api/v1/fleet/reports"
eq "reports url, no path"           "$(fleet_reports_url https://h.example)" "https://h.example/api/v1/fleet/reports"
check "reports url refuses plain http off-loopback" bash -c '. "$0"; ! fleet_reports_url http://athena.cjpoll.me/mcp >/dev/null' "${LIB}/domain.sh"
check "reports url refuses http to a loopback-looking host" bash -c '. "$0"; ! fleet_reports_url http://127.0.0.1.evil.example/mcp >/dev/null' "${LIB}/domain.sh"
check "reports url refuses empty"   bash -c '. "$0"; ! fleet_reports_url "" >/dev/null' "${LIB}/domain.sh"
for u in "http://localhost:x@evil.example/mcp" "http://127.0.0.1:@evil.example/mcp" "http://[::1]:1@evil.example/mcp" \
         "http://127.0.0.1:80@evil.example/mcp" "https://user:pw@athena.example/mcp" "https://athena.example@evil.example/mcp" \
         "http://localhost:abc/mcp" "https://athena.example:/mcp"; do
  check "reports url refuses userinfo / a bad port: ${u}" bash -c '. "$0"; ! fleet_reports_url "$1" >/dev/null' "${LIB}/domain.sh" "${u}"
done
eq "reports url: localhost without a port" "$(fleet_reports_url http://localhost/mcp)" "http://localhost/api/v1/fleet/reports"
eq "reports url: [::1] with a port"        "$(fleet_reports_url 'http://[::1]:8080/mcp')" "http://[::1]:8080/api/v1/fleet/reports"
eq "reports url: https with a port"        "$(fleet_reports_url https://athena.example:8443/mcp?x=1)" "https://athena.example:8443/api/v1/fleet/reports"
check "reports url refuses no host" bash -c '. "$0"; ! fleet_reports_url "https:///mcp" >/dev/null' "${LIB}/domain.sh"

eq "seen kind: admiral with id"     "$(fleet_seen_kind athena-admiral abc123)" "admiral_seen"
eq "seen kind: admiral without id"  "$(fleet_seen_kind athena-admiral "")" "session_seen"
eq "seen kind: captain"             "$(fleet_seen_kind athena-captain abc123)" "session_seen"
eq "seen kind: top level"           "$(fleet_seen_kind "" "")" "session_seen"

eq "seconds: a plain number passes"  "$(fleet_seconds 10 30)" "10"
eq "seconds: empty -> default"      "$(fleet_seconds "" 30)" "30"
eq "seconds: zero -> default"       "$(fleet_seconds 0 30)" "30"
eq "seconds: a curl-config injection -> default" "$(fleet_seconds "$(printf '5\nurl = "https://evil.example"')" 30)" "30"
eq "seconds: 5 digits -> default"   "$(fleet_seconds 10000 30)" "30"

eq "throttle key: agent"            "$(fleet_throttle_key s1 a1)" "s1.a1"
eq "throttle key: top level"        "$(fleet_throttle_key s1 "")" "s1.main"

check "due: no stamp"               fleet_seen_due 1000 ""
check "due: exactly 60 s"           fleet_seen_due 1060 1000
check "not due: 59 s"               bash -c '. "$0"; ! fleet_seen_due 1059 1000' "${LIB}/domain.sh"
check "due: stamp in the future"    fleet_seen_due 1000 5000

eq "outcome 202"                    "$(fleet_outcome 0 202)" "ok"
eq "outcome 422"                    "$(fleet_outcome 0 422)" "refused"
eq "outcome 404"                    "$(fleet_outcome 0 404)" "refused"
eq "outcome 500"                    "$(fleet_outcome 0 500)" "server-fault"
eq "outcome connect failure"        "$(fleet_outcome 7 000)" "unreachable"
eq "outcome timeout"                "$(fleet_outcome 28 "")" "unreachable"
eq "exit: ok/refused/unreachable/fault" \
   "$(fleet_exit_for ok)$(fleet_exit_for refused)$(fleet_exit_for unreachable)$(fleet_exit_for server-fault)" "0345"

eq "refusal fix: server's own"      "$(fleet_refusal_fix 422 '{"error":"unprocessable_entity","fix":"remove owner"}')" "remove owner"
case "$(fleet_refusal_fix 404 '{"error":"not_found"}')" in *"bound to the machine"*) ok "refusal fix: 404 not_found names machine binding" ;; *) bad "refusal fix: 404 not_found names machine binding" ;; esac
case "$(fleet_refusal_fix 404 '<html>')" in *"DND-431"*) ok "refusal fix: 404 without JSON names the missing endpoint" ;; *) bad "refusal fix: 404 without JSON names the missing endpoint" ;; esac

GOOD_M='[{"tracker":"notion-personal","ticket_ref":"DND-433","url":"https://notion.so/x","title":"T","status":"In Progress","captain_state":"running"}]'
check "missions: valid list"        fleet_missions_problem "${GOOD_M}"
check "missions: empty list is a reported fact" fleet_missions_problem '[]'
p="$(fleet_missions_problem "$(printf '%s' "${GOOD_M}" | jq -c '.[0].body = "secret text"')")"
case "${p}" in *"body"*"may not carry"*) ok "missions: refuses an extra field by name (body)" ;; *) bad "missions: refuses an extra field by name (body)" "${p}" ;; esac
p="$(fleet_missions_problem "$(printf '%s' "${GOOD_M}" | jq -c 'del(.[0].url)')")"
case "${p}" in *"missing url"*) ok "missions: refuses a missing field" ;; *) bad "missions: refuses a missing field" "${p}" ;; esac
p="$(fleet_missions_problem "$(printf '%s' "${GOOD_M}" | jq -c '.[0].captain_state = "idle"')")"
case "${p}" in *"captain_state"*) ok "missions: refuses an unknown captain_state" ;; *) bad "missions: refuses an unknown captain_state" "${p}" ;; esac
p="$(fleet_missions_problem "$(printf '%s' "${GOOD_M}" | jq -c '.[0].tracker = "jira"')")"
case "${p}" in *"tracker"*) ok "missions: refuses an unknown tracker" ;; *) bad "missions: refuses an unknown tracker" "${p}" ;; esac
p="$(fleet_missions_problem "$(printf '%s' "${GOOD_M}" | jq -c '.[0].status = 3')")"
case "${p}" in *"non-string"*"status"*) ok "missions: refuses a wrong type" ;; *) bad "missions: refuses a wrong type" "${p}" ;; esac
p="$(fleet_missions_problem "$(printf '%s' "${GOOD_M}" | jq -c '. + .')")"
case "${p}" in *"more than once"*) ok "missions: refuses a duplicate (tracker, ticket_ref)" ;; *) bad "missions: refuses a duplicate (tracker, ticket_ref)" "${p}" ;; esac
p="$(fleet_missions_problem '{"a":1}')"
case "${p}" in *"JSON array"*) ok "missions: refuses a non-array" ;; *) bad "missions: refuses a non-array" "${p}" ;; esac
p="$(fleet_missions_problem 'not json')"
case "${p}" in *"not valid JSON"*) ok "missions: refuses non-JSON" ;; *) bad "missions: refuses non-JSON" "${p}" ;; esac

b="$(fleet_body_session_started S "" /r/.git)"
eq "body session_started: project stated as null" "$(printf '%s' "${b}" | jq -c .)" '{"kind":"session_started","claude_session_id":"S","project":null,"repo_key":"/r/.git"}'
b="$(fleet_body_session_started S custom /r/.git)"
eq "body session_started: project named" "$(printf '%s' "${b}" | jq -r .project)" "custom"
eq "body session_seen: optional fields omitted" "$(fleet_body_seen session_seen S "" "")" '{"kind":"session_seen","claude_session_id":"S"}'
eq "body admiral_seen" "$(fleet_body_seen admiral_seen S A athena-admiral)" '{"kind":"admiral_seen","claude_session_id":"S","agent_id":"A","agent_type":"athena-admiral"}'
eq "body session_ended with reason" "$(fleet_body_session_ended S other)" '{"kind":"session_ended","claude_session_id":"S","end_reason":"other"}'
eq "body admiral_started" "$(fleet_body_admiral_started S R A "")" '{"kind":"admiral_started","claude_session_id":"S","run_id":"R","agent_id":"A"}'
eq "body admiral_scope" "$(fleet_body_admiral_scope S R '[]')" '{"kind":"admiral_scope","claude_session_id":"S","run_id":"R","missions":[]}'
eq "body admiral_scope: an empty notion id is omitted, never null" "$(fleet_body_admiral_scope S R '[]' "")" '{"kind":"admiral_scope","claude_session_id":"S","run_id":"R","missions":[]}'
eq "body admiral_scope with a notion project id" "$(fleet_body_admiral_scope S R '[]' 3e2349da87fb81aca4f5ff241e915946)" '{"kind":"admiral_scope","claude_session_id":"S","run_id":"R","missions":[],"notion_project_id":"3e2349da87fb81aca4f5ff241e915946"}'
eq "body admiral_state" "$(fleet_body_admiral_state S R finished)" '{"kind":"admiral_state","claude_session_id":"S","run_id":"R","state":"finished"}'

# No body builder may ever emit an identity field the server stamps.
all_bodies="$(fleet_body_session_started S p /r; fleet_body_seen session_seen S A T; fleet_body_session_ended S x;
  fleet_body_admiral_started S R A L; fleet_body_admiral_scope S R "${GOOD_M}"; fleet_body_admiral_state S R finished)"
if printf '%s\n' "${all_bodies}" | jq -e 'has("owner") or has("owner_id") or has("machine") or has("machine_id")' >/dev/null 2>&1; then
  bad "no body carries owner/machine"
else ok "no body carries owner/machine"; fi

echo "== domain: lifecycle kinds (DND-560)"
# Contract: athena-events.md -> *Fleet report kinds and their closed schema*,
# *Agent lifecycle*, *Mission pointers are metadata only*.
D="${LIB}/domain.sh"
eq "the eleven kinds" "$(printf '%s\n' ${FLEET_KINDS} | sort | tr '\n' ' ')" \
  "admiral_scope admiral_seen admiral_started admiral_state agent_bound agent_end agent_spawn agent_start session_ended session_seen session_started "
check "admiral state: parked"       fleet_valid_admiral_state parked
check "admiral state: lost is not reportable" bash -c '. "$0"; ! fleet_valid_admiral_state lost' "${D}"
check "fleet worker: athena-admiral" fleet_is_fleet_worker athena-admiral
check "fleet worker: athena-captain" fleet_is_fleet_worker athena-captain
for t in "" general-purpose athena-architect "athena-captain x" athena; do
  check "not a fleet worker: ${t@Q}" bash -c '. "$0"; ! fleet_is_fleet_worker "$1"' "${D}" "${t}"
done

for r in DND-541 WEB-1289 AB-1 A1-9999999 ABCDEFGHIJ-5; do
  check "ticket ref valid: ${r}" fleet_valid_ticket_ref "${r}"
done
for r in "" dnd-5 DND-0 DND- DND-12345678 "DND-5:x" "DND-5 " " DND-5" A-5 ABCDEFGHIJK-5 "DND-05" $'DND-5\n'; do
  check "ticket ref refused: ${r@Q}" bash -c '. "$0"; ! fleet_valid_ticket_ref "$1"' "${D}" "${r}"
done

# fleet_parse_ticket_ref <description> <prompt> -> "mapped <REF>" | "unmapped"
eq "ref: description names one"      "$(fleet_parse_ticket_ref 'DND-541 captain' 'no ref here')" "mapped DND-541"
eq "ref: the same ref twice is one"  "$(fleet_parse_ticket_ref 'DND-541 captain for DND-541' '')" "mapped DND-541"
eq "ref: two refs in the description are ambiguous" "$(fleet_parse_ticket_ref 'DND-541 and DND-542' 'Mission: DND-9')" "unmapped"
eq "ref: prompt Mission line when the description has none" "$(fleet_parse_ticket_ref 'captain' "$(printf 'You are a captain.\nMission: DND-9\nMission: DND-10')")" "mapped DND-9"
eq "ref: bold **Mission:**"          "$(fleet_parse_ticket_ref 'captain' "$(printf 'x\n**Mission:** WEB-1289 (MEDIUM)')")" "mapped WEB-1289"
eq "ref: bold **Mission**:"          "$(fleet_parse_ticket_ref 'captain' "$(printf '  **Mission**: DND-7')")" "mapped DND-7"
eq "ref: neither"                    "$(fleet_parse_ticket_ref 'captain' 'do the work')" "unmapped"
eq "ref: lower case is not a ref"    "$(fleet_parse_ticket_ref 'dnd-5 captain' 'Mission: dnd-5')" "unmapped"
eq "ref: a ref inside a longer token does not count" "$(fleet_parse_ticket_ref 'XDND-5Y captain' '')" "unmapped"
eq "ref: 8 digits is not a ref"      "$(fleet_parse_ticket_ref 'DND-12345678' '')" "unmapped"
eq "ref: a Mission line mid-sentence does not count" "$(fleet_parse_ticket_ref 'captain' 'Your Mission: DND-9 is set')" "unmapped"
eq "ref: a Mission line with a bad ref does not count" "$(fleet_parse_ticket_ref 'captain' 'Mission: DND-0')" "unmapped"
eq "ref: refs in the prompt body alone do not count" "$(fleet_parse_ticket_ref 'captain' 'see DND-541 and WEB-1')" "unmapped"
eq "ref: punctuation is a boundary"  "$(fleet_parse_ticket_ref '[DND-560]: hook' '')" "mapped DND-560"

# fleet_parse_run_hint <prompt> -> the one distinct coordination dir, else nothing (status 1)
CP="/home/u/dev/custom/ai-artifacts/coordination"
eq "run hint: one path"              "$(fleet_parse_run_hint "reports: ${CP}/2026-09-24-p1-fleet/reports/x.md")" "2026-09-24-p1-fleet"
eq "run hint: the same dir twice"    "$(fleet_parse_run_hint "${CP}/r1/reports/ and ${CP}/r1/state.md")" "r1"
eq "run hint: a relative path"       "$(fleet_parse_run_hint "write to ai-artifacts/coordination/r2/reports/")" "r2"
eq "run hint: two distinct dirs give none" "$(fleet_parse_run_hint "${CP}/r1/reports/ ${CP}/r2/reports/")" ""
check "run hint: none -> status 1"   bash -c '. "$0"; ! fleet_parse_run_hint "no path" >/dev/null' "${D}"
eq "run hint: .. gives none"         "$(fleet_parse_run_hint "${CP}/../etc/x")" ""
eq "run hint: a bad dir beside a good one gives none" "$(fleet_parse_run_hint "${CP}/r1/x ${CP}/.hidden/y")" ""
eq "run hint: no trailing slash is not a coordination path" "$(fleet_parse_run_hint "see ai-artifacts/coordination/r1 for it")" ""
eq "run hint: a quoted path"         "$(fleet_parse_run_hint "\`${CP}/r3/reports/\`")" "r3"

# A brief longer than one argv string may be (Linux MAX_ARG_STRLEN, 128 KiB)
# must still parse: the prompt never rides argv.
BIG="$(head -c 200000 /dev/zero | tr '\0' 'x')"
eq "ref: a 200 KB prompt still parses (not passed through argv)" \
  "$(fleet_parse_ticket_ref 'captain' "$(printf '%s\nMission: DND-77\n' "${BIG}")")" "mapped DND-77"
eq "run hint: a 200 KB prompt still parses" \
  "$(fleet_parse_run_hint "$(printf '%s ai-artifacts/coordination/big-run/x\n' "${BIG}")")" "big-run"
unset BIG

# fleet_error_class <value> -> itself when in the measured enum, else other
for c in rate_limit overloaded authentication_failed oauth_org_not_allowed account_on_hold \
  verification_required billing_error invalid_request model_not_found server_error \
  max_output_tokens cloud_credential_error unknown other; do
  eq "error class: ${c}" "$(fleet_error_class "${c}")" "${c}"
done
eq "error class: teapot -> other"   "$(fleet_error_class teapot)" "other"
eq "error class: empty -> other"    "$(fleet_error_class "")" "other"
eq "error class: a prefix is not a member" "$(fleet_error_class rate_limit_x)" "other"
# fleet_failure_error_class <PostToolUseFailure error text> (measured shape, DND-541 case-b1)
MEASURED_FAIL='Agent terminated early due to an API error: API Error: Server is temporarily limiting requests (not your usage limit) · DND-541 probe injected 429 (error type rate_limit, HTTP 429, model sent to the API: claude-sonnet-5)'
eq "failure class: measured 429 text -> rate_limit" "$(fleet_failure_error_class "${MEASURED_FAIL}")" "rate_limit"
eq "failure class: error type unknown" "$(fleet_failure_error_class 'x (error type unknown, HTTP 400)')" "unknown"
eq "failure class: an unlisted type -> other" "$(fleet_failure_error_class 'x (error type teapot, HTTP 418)')" "other"
eq "failure class: no error type -> other" "$(fleet_failure_error_class 'Interrupted by user')" "other"
eq "failure class: empty -> other"   "$(fleet_failure_error_class '')" "other"

# Combination rules (closed; the server refuses the same).
check "spawn ok: captain mapped"     fleet_agent_spawn_problem athena-captain mapped DND-5
check "spawn ok: captain unmapped"   fleet_agent_spawn_problem athena-captain unmapped ""
check "spawn ok: admiral n/a"        fleet_agent_spawn_problem athena-admiral not_applicable ""
spawn_bad() { local p rc=0; p="$(fleet_agent_spawn_problem "$@")" || rc=$?; [ "${rc}" -ne 0 ] && [ -n "${p}" ]; }
check "spawn refused: admiral mapped"       spawn_bad athena-admiral mapped DND-5
check "spawn refused: captain not_applicable" spawn_bad athena-captain not_applicable ""
check "spawn refused: mapped, no ref"       spawn_bad athena-captain mapped ""
check "spawn refused: unmapped with a ref"  spawn_bad athena-captain unmapped DND-5
check "spawn refused: bad ref grammar"      spawn_bad athena-captain mapped dnd-5
check "spawn refused: mapping teapot"       spawn_bad athena-captain teapot ""
check "spawn refused: general-purpose"      spawn_bad general-purpose unmapped ""
check "end ok: stopped by agent"     fleet_agent_end_problem A "" athena-captain stopped ""
check "end ok: api_error by agent"   fleet_agent_end_problem A "" athena-admiral api_error rate_limit
check "end ok: spawn_failed by spawn" fleet_agent_end_problem "" T athena-captain spawn_failed other
check "end ok: spawn_denied by spawn" fleet_agent_end_problem "" T athena-captain spawn_denied ""
end_bad() { local p rc=0; p="$(fleet_agent_end_problem "$@")" || rc=$?; [ "${rc}" -ne 0 ] && [ -n "${p}" ]; }
check "end refused: both keys"       end_bad A T athena-captain stopped ""
check "end refused: neither key"     end_bad "" "" athena-captain stopped ""
check "end refused: stopped by spawn" end_bad "" T athena-captain stopped ""
check "end refused: spawn_denied by agent" end_bad A "" athena-captain spawn_denied ""
check "end refused: api_error without class" end_bad A "" athena-captain api_error ""
check "end refused: stopped with a class" end_bad A "" athena-captain stopped rate_limit
check "end refused: class teapot"    end_bad A "" athena-captain api_error teapot
check "end refused: outcome teapot"  end_bad A "" athena-captain teapot ""
check "end refused: non-fleet type"  end_bad A "" general-purpose stopped ""

# Body builders: exactly the contract row, optional fields omitted (never null).
eq "body agent_spawn mapped, caller, hint" \
  "$(fleet_body_agent_spawn S T athena-captain C mapped DND-5 r1)" \
  '{"kind":"agent_spawn","claude_session_id":"S","tool_use_id":"T","subagent_type":"athena-captain","mapping":"mapped","caller_agent_id":"C","ticket_ref":"DND-5","run_hint":"r1"}'
eq "body agent_spawn top-level admiral: optional fields omitted" \
  "$(fleet_body_agent_spawn S T athena-admiral "" not_applicable "" "")" \
  '{"kind":"agent_spawn","claude_session_id":"S","tool_use_id":"T","subagent_type":"athena-admiral","mapping":"not_applicable"}'
eq "body agent_bound" "$(fleet_body_agent_bound S T A athena-captain)" \
  '{"kind":"agent_bound","claude_session_id":"S","tool_use_id":"T","agent_id":"A","agent_type":"athena-captain"}'
eq "body agent_start" "$(fleet_body_agent_start S A athena-admiral)" \
  '{"kind":"agent_start","claude_session_id":"S","agent_id":"A","agent_type":"athena-admiral"}'
eq "body agent_end stopped" "$(fleet_body_agent_end S A "" athena-captain stopped "")" \
  '{"kind":"agent_end","claude_session_id":"S","agent_id":"A","agent_type":"athena-captain","outcome":"stopped"}'
eq "body agent_end spawn_failed" "$(fleet_body_agent_end S "" T athena-captain spawn_failed rate_limit)" \
  '{"kind":"agent_end","claude_session_id":"S","tool_use_id":"T","agent_type":"athena-captain","outcome":"spawn_failed","error_class":"rate_limit"}'
life_bodies="$(fleet_body_agent_spawn S T athena-captain C mapped DND-5 r1; fleet_body_agent_bound S T A athena-captain
  fleet_body_agent_start S A athena-captain; fleet_body_agent_end S A "" athena-captain api_error rate_limit)"
if printf '%s\n' "${life_bodies}" | jq -e 'has("owner") or has("machine_id") or has("prompt") or has("description") or has("last_assistant_message") or has("transcript_path")' >/dev/null 2>&1; then
  bad "no lifecycle body carries identity or prompt fields"
else ok "no lifecycle body carries identity or prompt fields"; fi

pinned_unmapped="$(awk '/^@section Mission pointers are metadata only$/ {s=1; next} /^@section / {s=0} s && /^fleet-lifecycle: /' "${AI}/contracts/fixtures/athena-events-quoted-fix.txt")"
[ -n "${pinned_unmapped}" ] || bad "the fixture pins the unmapped-captain notice"
eq "the unmapped-captain notice is the pinned line" "$(fleet_unmapped_notice)" "${pinned_unmapped}"

if [ "${FLEET_SELF_TEST_ONLY:-}" = "domain" ]; then
  printf '\n%d passed, %d failed\n' "${PASS}" "${FAIL}"
  [ "${FAIL}" -eq 0 ] || { echo "Fix: make lib/fleet/domain.sh satisfy the failing cases above."; exit 1; }
  exit 0
fi

# ---------------------------------------------------------------------------
echo "== effects"

# shellcheck disable=SC1091
INBOX_LIB="${AI}/skills/athena:inbox/lib"
for f in err names descriptor logchan maildir fence session fs lock inbox; do . "${INBOX_LIB}/${f}.sh"; done
. "${LIB}/effects.sh"
. "${HERE}/helpers.sh"
fleet_fixture_env
# admiral-scope writes mission.status telemetry (DND-1476): never into the real
# store. The telemetry section below points each case at its own store.
export ATHENA_TELEMETRY_DIR="${TMP}/telemetry"

eq "token: read from the client config" "$(fleet_read_token)" "${FLEET_TEST_TOKEN}"
( export ATHENA_INBOX_CLIENT_CONFIG="${TMP}/nope.json"; fleet_read_token >/dev/null ); eq "token: missing config is status 1" "$?" "1"
printf '{"server_url":"x"}' > "${TMP}/notoken.json"
( export ATHENA_INBOX_CLIENT_CONFIG="${TMP}/notoken.json"; fleet_read_token >/dev/null ); eq "token: config without token is status 3" "$?" "3"

jq -n '{mcpServers: {athena: {url: "https://user.example/mcp"}},
        projects: {"/p/one": {mcpServers: {athena: {url: "https://one.example/mcp"}}},
                   "/p/two": {mcpServers: {other: {url: "x"}}}}}' > "${FLEET_CLAUDE_JSON}"
eq "mcp url: first matching project key wins" "$(fleet_mcp_url /p/two /p/one)" "https://one.example/mcp"
eq "mcp url: falls back to user scope"        "$(fleet_mcp_url /p/two /p/none)" "https://user.example/mcp"
( fleet_mcp_url relative/key >/dev/null ); eq "mcp url: a relative key is an internal error (2), not a miss" "$?" "2"
jq -n '{projects: {}}' > "${FLEET_CLAUDE_JSON}"
( fleet_mcp_url /p/one >/dev/null ); eq "mcp url: registered nowhere is status 1" "$?" "1"
printf 'not json' > "${FLEET_CLAUDE_JSON}"
( fleet_mcp_url /p/one >/dev/null ); eq "mcp url: unparseable config is status 3, not a miss" "$?" "3"
( export FLEET_CLAUDE_JSON="${TMP}/absent.json"; fleet_mcp_url /p/one >/dev/null ); eq "mcp url: absent config is status 1" "$?" "1"

# [ticket] The DND-183 class: `git rev-parse --git-common-dir` answers `.git`,
# RELATIVE, in a main checkout. Resolved against the process cwd instead of the
# session's, it names the wrong repo (or none). The process cwd here is a
# DIFFERENT repo on purpose, so a resolution against it cannot pass by luck.
git init -q "${TMP}/repo" && git -C "${TMP}/repo" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
git -C "${TMP}/repo" worktree add -q "${TMP}/wt" -b wt-branch 2>/dev/null
git init -q "${TMP}/other"
REPO_KEY="$(realpath "${TMP}/repo/.git")"
eq "git common dir really is relative in a main checkout (premise)" "$(git -C "${TMP}/repo" rev-parse --git-common-dir)" ".git"
got="$(cd "${TMP}/other" && fleet_resolve_repo "${TMP}/repo")"
eq "[ticket] relative git-common-dir resolved against the session cwd, not the process cwd" "${got}" "$(printf '\t%s' "${REPO_KEY}")"
got="$(cd "${TMP}/other" && fleet_resolve_repo "${TMP}/wt")"
eq "a worktree resolves to its main checkout's common dir" "${got}" "$(printf '\t%s' "${REPO_KEY}")"
jq -n --arg r "${TMP}/repo/.git/" '{v: 1, repo: $r, channels: {}}' > "${ATHENA_INBOX_ROOT}/projects/demo.json"
got="$(cd / && fleet_resolve_repo "${TMP}/wt")"
eq "project: the registry entry naming this repo (trailing slash canonicalised)" "${got}" "$(printf 'demo\t%s' "${REPO_KEY}")"
cp "${ATHENA_INBOX_ROOT}/projects/demo.json" "${ATHENA_INBOX_ROOT}/projects/demo2.json"
( fleet_resolve_repo "${TMP}/repo" >/dev/null 2>&1 ); eq "project: two entries claiming one repo is ambiguous (4)" "$?" "4"
rm -f "${ATHENA_INBOX_ROOT}/projects/demo2.json"
printf 'broken' > "${ATHENA_INBOX_ROOT}/projects/broken.json"
got="$(fleet_resolve_repo "${TMP}/repo")"
eq "project: a broken OTHER entry does not matter once ours matched" "${got%%$'\t'*}" "demo"
( fleet_resolve_repo "${TMP}/other" >/dev/null ); eq "project: no match + an unparseable entry refuses (5), never states null" "$?" "5"
rm -f "${ATHENA_INBOX_ROOT}/projects/broken.json"
got="$(fleet_resolve_repo "${TMP}/other")"
eq "project: no entry names the repo -> empty (null)" "${got}" "$(printf '\t%s' "$(realpath "${TMP}/other/.git")")"
mkdir -p "${TMP}/plain"
got="$(fleet_resolve_repo "${TMP}/plain")"
eq "a cwd outside git keys by its own realpath" "${got}" "$(printf '\t%s' "$(realpath "${TMP}/plain")")"
( fleet_resolve_repo relative/dir >/dev/null ); eq "a relative cwd is refused (2)" "$?" "2"
# A repo git REFUSES to read (dubious ownership, corrupt .git, no git) is
# "could not tell" (3), never keyed as a non-repo directory.
mkdir -p "${TMP}/fakegit"
printf '#!/bin/sh\necho "fatal: detected dubious ownership in repository at x" >&2\nexit 128\n' > "${TMP}/fakegit/git"
chmod +x "${TMP}/fakegit/git"
( PATH="${TMP}/fakegit:${PATH}"; fleet_resolve_repo "${TMP}/repo" >/dev/null ); eq "dubious ownership is could-not-tell (3), not a non-repo" "$?" "3"
( PATH="${TMP}/fakegit:${PATH}"; fleet_resolve_repo "${TMP}/plain" >/dev/null ); eq "even for a plain dir: git failing is could-not-tell (3)" "$?" "3"
( fleet_resolve_repo "${TMP}/does-not-exist" >/dev/null ); eq "a missing cwd is refused (2)" "$?" "2"

now="$(date +%s)"
fleet_throttle_claim "s1.a1" "${now}"; eq "throttle: first claim" "$?" "0"
fleet_throttle_claim "s1.a1" "${now}"; eq "throttle: second claim inside 60 s is refused" "$?" "1"
fleet_throttle_claim "s1.a2" "${now}"; eq "throttle: another agent in the same session is independent" "$?" "0"
touch -d "@$((now - 61))" "${XDG_STATE_HOME}/athena/fleet/seen/s1.a1.stamp"
fleet_throttle_claim "s1.a1" "${now}"; eq "throttle: due again after 60 s" "$?" "0"
( exec 9>>"${XDG_STATE_HOME}/athena/fleet/seen/s1.a3.stamp"; flock 9; fleet_throttle_claim "s1.a3" "${now}"; exit $? )
eq "throttle: a claim held by a concurrent caller is refused" "$?" "1"
( export XDG_STATE_HOME=relative/state; fleet_throttle_claim "s1.a1" "${now}" ); eq "throttle: relative XDG_STATE_HOME is refused (2)" "$?" "2"

FLOG="${XDG_STATE_HOME}/athena/fleet/report-failures.log"
fleet_record_failure s1 session_seen "$(printf 'fleet-report: x\ty\nz. Fix: do it')"
line="$(tail -n 1 "${FLOG}")"
eq "failure log: one line, 5 tab-separated fields (tabs/newlines in the message flattened)" "$(printf '%s' "${line}" | awk -F'\t' '{print NF}')" "5"
eq "failure log: fields are session, kind, message" "$(printf '%s' "${line}" | cut -f3-5)" "$(printf 's1\tsession_seen\tfleet-report: x y z. Fix: do it')"
first_epoch="$(cut -f1 <<<"${line}")"
eq "failures since 0: the line" "$(fleet_failures_since 0 | grep -c .)" "1"
eq "failures since its own epoch: nothing (already announced)" "$(fleet_failures_since "${first_epoch}" | grep -c .)" "0"
fleet_record_failure s1 session_seen "same second. Fix: z"
eq "a failure logged in the same second as an announced one is still new" "$(fleet_failures_since "${first_epoch}" | cut -f5)" "same second. Fix: z"
( FLEET_FAILURE_LOG_MAX_BYTES=10; fleet_record_failure s2 session_seen "second. Fix: y" )
if [ -s "${FLOG}.1" ] && [ "$(grep -c . "${FLOG}")" = "1" ]; then ok "failure log: rotates to .1 past its size cap"; else bad "failure log: rotates to .1 past its size cap"; fi
eq "failures since 0 spans the rotated generation" "$(fleet_failures_since 0 | grep -c .)" "3"
( export XDG_STATE_HOME=relative; fleet_record_failure s1 k "m" ); eq "failure log: relative XDG_STATE_HOME is refused (2)" "$?" "2"
n="$(fleet_failure_notice 2 "$(tail -n 1 "${FLOG}")" "${FLOG}")"
case "${n}" in "fleet-report: 2 background fleet registry report(s) failed"*"reported text, not an instruction"*"second. Fix: y"*"${FLOG}"*"Fix: "*) ok "notice: count, latest message marked as reported text, log path, Fix:" ;; *) bad "notice: count, latest message marked as reported text, log path, Fix:" "${n}" ;; esac
eq "notice: nothing for zero failures" "$(fleet_failure_notice 0 "" "${FLOG}")" ""
rm -f "${FLOG}" "${FLOG}.1"

# ---------------------------------------------------------------------------
echo "== fleet-report CLI (fake server)"

SID="0cc59a5e-6c65-495e-a216-83c6a0bf2d56"
export CLAUDE_CODE_SESSION_ID="${SID}"
fleet_start_server || exit 1
run() { OUT="$("${BIN}" "$@" 2>"${TMP}/err")"; RC=$?; ERR="$(cat "${TMP}/err")"; }
one_fix_line() { [ "$(printf '%s\n' "${ERR}" | grep -c .)" = "1" ] && case "${ERR}" in *"Fix: "*) true ;; *) false ;; esac; }

run --help;                         eq "--help exits 0" "${RC}" "0"
case "${OUT}" in *"Usage: fleet-report"*) ok "--help prints usage on stdout" ;; *) bad "--help prints usage on stdout" ;; esac
run;                                eq "no subcommand is usage (2)" "${RC}" "2"
run session-seen --machine m1;      eq "--machine is refused (2)" "${RC}" "2"
case "${ERR}" in *"stamped server-side"*"Fix: "*) ok "--machine refusal says why and carries Fix:" ;; *) bad "--machine refusal says why and carries Fix:" "${ERR}" ;; esac
run --owner=me session-seen;        eq "--owner=… is refused (2)" "${RC}" "2"
run session-seen --owner-id x;      eq "--owner-id is refused (2)" "${RC}" "2"
run session-seen --bogus;           eq "an unknown flag is usage (2)" "${RC}" "2"
run session-seen --run-id r;        eq "a flag the subcommand does not take is usage (2)" "${RC}" "2"
run admiral-start --run-id r;       eq "admiral-start without --agent-id is usage (2)" "${RC}" "2"
run admiral-state --run-id r --state running; eq "admiral-state refuses running (2)" "${RC}" "2"
run session-seen --session-id "a/b"; eq "an unsafe session id is usage (2)" "${RC}" "2"
OUT="$(env -u CLAUDE_CODE_SESSION_ID "${BIN}" session-seen 2>"${TMP}/err")"; eq "no session id anywhere is usage (2)" "$?" "2"
OUT="$(PATH="${TMP}/fakegit:${PATH}" "${BIN}" session-start --cwd "${TMP}/repo" 2>"${TMP}/err")"; eq "session-start refuses when git cannot read the repo (1)" "$?" "1"
case "$(cat "${TMP}/err")" in *"could not say"*"Fix: "*) ok "that refusal names the git failure with Fix:" ;; *) bad "that refusal names the git failure with Fix:" "$(cat "${TMP}/err")" ;; esac
eq "no request reached the server for any usage error" "$(fleet_log_count)" "0"

printf '%s' "${GOOD_M}" | jq -c '.[0].summary = "leaked prose"' > "${TMP}/bad-missions.json"
run admiral-scope --run-id r1 --missions "${TMP}/bad-missions.json"
eq "admiral-scope refuses a non-pointer field locally (2)" "${RC}" "2"
case "${ERR}" in *"summary"*"Fix: "*) ok "the local refusal names the field" ;; *) bad "the local refusal names the field" "${ERR}" ;; esac
eq "the refused scope never reached the server" "$(fleet_log_count)" "0"

run session-start --dry-run --cwd "${TMP}/wt"
eq "session-start --dry-run exits 0" "${RC}" "0"
eq "session-start body: project + absolute repo_key, resolved at capture" "$(printf '%s' "${OUT}" | jq -c '[.kind, .project, .repo_key]')" "$(jq -n -c --arg r "${REPO_KEY}" '["session_started","demo",$r]')"
eq "--dry-run sent nothing" "$(fleet_log_count)" "0"

# [ticket] The token never reaches argv (or the environment). The fake server
# scans every process's /proc/<pid>/cmdline and /environ WHILE the request is in
# flight; delay_s keeps fleet-report and curl alive during the scan.
fleet_respond '{"status":202,"body":{"ok":true},"delay_s":0.3}'
run session-start --cwd "${TMP}/repo"
eq "session-start sends (0)" "${RC}" "0"
eq "success prints one stdout line" "${OUT}" "fleet-report: session_started ok (HTTP 202)"
req="$(fleet_last_request)"
eq "the request hit /api/v1/fleet/reports" "$(printf '%s' "${req}" | jq -r .path)" "/api/v1/fleet/reports"
eq "the bearer is the machine token" "$(printf '%s' "${req}" | jq -r .auth_ok)" "true"
eq "[ticket] token absent from every /proc/*/cmdline during the request" "$(printf '%s' "${req}" | jq -c .argv_leak)" "[]"
eq "token absent from every /proc/*/environ during the request" "$(printf '%s' "${req}" | jq -c .environ_leak)" "[]"
eq "body is exactly the session_started schema" "$(printf '%s' "${req}" | jq -c '.body | keys')" '["claude_session_id","kind","project","repo_key"]'
fleet_respond '{"status":202,"body":{"ok":true}}'

printf '%s' "${GOOD_M}" > "${TMP}/missions.json"
run admiral-start --run-id r1 --agent-id a5a8eb5540d6e6ab3 --scope-label "P1 fleet"
eq "admiral-start sends (0)" "${RC}" "0"
eq "admiral_started body" "$(fleet_last_request | jq -c .body)" "{\"kind\":\"admiral_started\",\"claude_session_id\":\"${SID}\",\"run_id\":\"r1\",\"agent_id\":\"a5a8eb5540d6e6ab3\",\"scope_label\":\"P1 fleet\"}"
run admiral-scope --missions "${TMP}/missions.json" --run-id r1
eq "admiral-scope sends (0), flags in any order" "${RC}" "0"
eq "admiral_scope carries the pointers verbatim" "$(fleet_last_request | jq -c .body.missions)" "$(jq -c . <<<"${GOOD_M}")"
printf '[]' > "${TMP}/empty.json"
run admiral-scope --run-id r1 --missions "${TMP}/empty.json"
eq "an empty scope is sent as [] (a reported fact)" "$(fleet_last_request | jq -c .body.missions)" "[]"
eq "no --notion-project-id: the key is absent" "$(fleet_last_request | jq -c '.body | has("notion_project_id")')" "false"
run admiral-scope --notion-project-id 3e2349da-87fb-81ac-a4f5-ff241e915946 --run-id r1 --missions "${TMP}/empty.json"
eq "admiral-scope with --notion-project-id sends (0)" "${RC}" "0"
eq "the notion project id rides the admiral_scope body" "$(fleet_last_request | jq -r .body.notion_project_id)" "3e2349da-87fb-81ac-a4f5-ff241e915946"
run admiral-scope --run-id r1 --missions "${TMP}/empty.json" --notion-project-id "https://notion.so/x"
eq "a non-id --notion-project-id is refused locally (2)" "${RC}" "2"
case "${ERR}" in *"Notion page id"*"Fix: "*) ok "that refusal names the expectation with Fix:" ;; *) bad "that refusal names the expectation with Fix:" "${ERR}" ;; esac
run admiral-start --run-id r2 --agent-id a1 --notion-project-id 3e2349da87fb81aca4f5ff241e915946
eq "--notion-project-id belongs to admiral-scope only (2)" "${RC}" "2"
run admiral-seen --agent-id a5a8eb5540d6e6ab3 --agent-type athena-admiral
eq "admiral_seen body" "$(fleet_last_request | jq -c '.body | [.kind, .agent_id, .agent_type]')" '["admiral_seen","a5a8eb5540d6e6ab3","athena-admiral"]'
run admiral-state --run-id r1 --state finished
eq "admiral_state body" "$(fleet_last_request | jq -c '.body | [.kind, .run_id, .state]')" '["admiral_state","r1","finished"]'
run session-end --reason other
eq "session_ended body" "$(fleet_last_request | jq -c '.body | [.kind, .end_reason]')" '["session_ended","other"]'

echo "== fleet-report admiral-scope: mission.status telemetry (DND-1476)"
# Synthetic refs only (DND-, ZQ-). Each case has its own store; events are
# read straight from its day files.
TWO_M='[{"tracker":"notion-personal","ticket_ref":"DND-9001","url":"https://notion.so/a","title":"A","status":"In Progress","captain_state":"running"},{"tracker":"notion-work","ticket_ref":"ZQ-12","url":"https://notion.so/b","title":"B","status":"Todo","captain_state":"queued"}]'
printf '%s' "${TWO_M}" > "${TMP}/two-missions.json"
tel_events() { cat "$1"/*.jsonl 2>/dev/null | jq -c 'select(.event == "mission.status") | [.unit, .unit_source, .attrs.status, .attrs.captain_state, .attrs.run_id]' | sort; }
tel_drops() { if [ -f "$1/write-failures" ]; then jq -c . "$1/write-failures"; else printf '{}'; fi; }
WANT_EV="$(printf '%s\n' '["DND-9001","explicit","In Progress","running","r9"]' '["ZQ-12","explicit","Todo","queued","r9"]')"

export ATHENA_TELEMETRY_DIR="${TMP}/tel-1"
n="$(fleet_log_count)"
run admiral-scope --run-id r9 --missions "${TMP}/two-missions.json"
eq "M1 a two-mission scope sends (0)" "${RC}" "0"
eq "M1 the POST still happened" "$(fleet_log_count)" "$((n + 1))"
eq "M1 two mission.status events: unit, status, captain_state, run_id" "$(tel_events "${ATHENA_TELEMETRY_DIR}")" "${WANT_EV}"
eq "M1 zero drops" "$(tel_drops "${ATHENA_TELEMETRY_DIR}")" "{}"
eq "M1 stdout is the report line only" "${OUT}" "fleet-report: admiral_scope ok (HTTP 202)"

export ATHENA_TELEMETRY_DIR="${TMP}/tel-2"
fleet_respond '{"status":500,"body":{"error":"boom"}}'
run admiral-scope --run-id r9 --missions "${TMP}/two-missions.json"
eq "M2 a failed POST keeps its server-fault exit (5)" "${RC}" "5"
eq "M2 both events were written before the POST" "$(tel_events "${ATHENA_TELEMETRY_DIR}")" "${WANT_EV}"
fleet_respond '{"status":202,"body":{"ok":true}}'

export ATHENA_TELEMETRY_DIR="${TMP}/tel-2b"
fleet_point_at "http://127.0.0.1:$(fleet_closed_port)/mcp"
run admiral-scope --run-id r9 --missions "${TMP}/two-missions.json"
eq "M2b an unreachable server keeps exit 4" "${RC}" "4"
eq "M2b both events were still written" "$(tel_events "${ATHENA_TELEMETRY_DIR}")" "${WANT_EV}"
fleet_point_at "http://127.0.0.1:${SERVER_PORT}/mcp"

export ATHENA_TELEMETRY_DIR="${TMP}/tel-2c"
fleet_respond '{"status":422,"body":{"error":"unprocessable_entity","fix":"x"}}'
run admiral-scope --run-id r9 --missions "${TMP}/two-missions.json"
eq "M2c a server refusal keeps exit 3" "${RC}" "3"
eq "M2c the events written before the POST stay" "$(tel_events "${ATHENA_TELEMETRY_DIR}")" "${WANT_EV}"
fleet_respond '{"status":202,"body":{"ok":true}}'

export ATHENA_TELEMETRY_DIR="${TMP}/tel-6"
printf '%s' "${TWO_M}" | jq -c '. + [{"tracker":"notion-personal","ticket_ref":"not a ref","url":"https://notion.so/c","title":"C","status":"Todo","captain_state":"queued"}]' > "${TMP}/three-missions.json"
run admiral-scope --run-id r9 --missions "${TMP}/three-missions.json"
eq "M6 a ref outside the ref grammar sends (0)" "${RC}" "0"
eq "M6 and gets no event (never filed under the caller's branch)" "$(tel_events "${ATHENA_TELEMETRY_DIR}")" "${WANT_EV}"
eq "M6 zero drops" "$(tel_drops "${ATHENA_TELEMETRY_DIR}")" "{}"

export ATHENA_TELEMETRY_DIR="${TMP}/tel-3"
n="$(fleet_log_count)"
run admiral-scope --run-id r9 --missions "${TMP}/bad-missions.json"
eq "M3 a malformed missions file is refused (2)" "${RC}" "2"
eq "M3 and writes no event" "$(tel_events "${ATHENA_TELEMETRY_DIR}")" ""
check "M3 not even a store" test ! -e "${ATHENA_TELEMETRY_DIR}"
eq "M3 nothing was sent" "$(fleet_log_count)" "${n}"

export ATHENA_TELEMETRY_DIR="${TMP}/tel-4"
run admiral-scope --run-id r9 --missions "${TMP}/two-missions.json" --dry-run
eq "M4 a dry run exits 0" "${RC}" "0"
check "M4 a dry run records nothing" test ! -e "${ATHENA_TELEMETRY_DIR}"

# M5 fail-open: an unwritable store changes neither the POST, the exit code nor stdout.
mkdir -p "${TMP}/tel-ro"; chmod 500 "${TMP}/tel-ro"
export ATHENA_TELEMETRY_DIR="${TMP}/tel-5"
run admiral-scope --run-id r9 --missions "${TMP}/two-missions.json"; rc1="${RC}"; out1="${OUT}"
export ATHENA_TELEMETRY_DIR="${TMP}/tel-ro/store"
n="$(fleet_log_count)"
run admiral-scope --run-id r9 --missions "${TMP}/two-missions.json"
eq "M5 an unwritable store: the POST still happened" "$(fleet_log_count)" "$((n + 1))"
eq "M5 an unwritable store: exit unchanged" "${RC}" "${rc1}"
eq "M5 an unwritable store: stdout unchanged" "${OUT}" "${out1}"
case "${ERR}" in *"athena-telemetry:"*"Fix:"*) ok "M5 the writer's last-resort line names the store, with Fix:" ;; *) bad "M5 the writer's last-resort line names the store, with Fix:" "${ERR}" ;; esac
check "M5 nothing was written there" test ! -e "${ATHENA_TELEMETRY_DIR}"
chmod 700 "${TMP}/tel-ro"
export ATHENA_TELEMETRY_DIR="${TMP}/telemetry"

echo "== fleet-report CLI: lifecycle subcommands (DND-560)"
run admiral-state --run-id r1 --state parked
eq "admiral-state parked sends (0)" "${RC}" "0"
eq "admiral_state parked body" "$(fleet_last_request | jq -c '.body | [.kind, .state]')" '["admiral_state","parked"]'
TU="toolu_01FxUwz9M5UTfB9pfoMbBTYn"
# The --dry-run body of each subcommand is exactly the contract row: the keys
# below and nothing else.
dry() { run "$@" --dry-run; printf '%s' "${OUT}"; }
eq "agent-spawn mapped captain: exact body" \
  "$(dry agent-spawn --tool-use-id "${TU}" --subagent-type athena-captain --caller-agent-id a81c553e42da805c2 --mapping mapped --ticket-ref DND-541 --run-hint 2026-09-24-p1-fleet)" \
  "{\"kind\":\"agent_spawn\",\"claude_session_id\":\"${SID}\",\"tool_use_id\":\"${TU}\",\"subagent_type\":\"athena-captain\",\"mapping\":\"mapped\",\"caller_agent_id\":\"a81c553e42da805c2\",\"ticket_ref\":\"DND-541\",\"run_hint\":\"2026-09-24-p1-fleet\"}"
eq "agent-spawn top-level admiral: exact body" \
  "$(dry agent-spawn --subagent-type athena-admiral --mapping not_applicable --tool-use-id "${TU}")" \
  "{\"kind\":\"agent_spawn\",\"claude_session_id\":\"${SID}\",\"tool_use_id\":\"${TU}\",\"subagent_type\":\"athena-admiral\",\"mapping\":\"not_applicable\"}"
eq "agent-bound: exact body" "$(dry agent-bound --tool-use-id "${TU}" --agent-id a274de64afdf9e8a2 --agent-type athena-captain)" \
  "{\"kind\":\"agent_bound\",\"claude_session_id\":\"${SID}\",\"tool_use_id\":\"${TU}\",\"agent_id\":\"a274de64afdf9e8a2\",\"agent_type\":\"athena-captain\"}"
eq "agent-start: exact body" "$(dry agent-start --agent-id a274de64afdf9e8a2 --agent-type athena-admiral)" \
  "{\"kind\":\"agent_start\",\"claude_session_id\":\"${SID}\",\"agent_id\":\"a274de64afdf9e8a2\",\"agent_type\":\"athena-admiral\"}"
eq "agent-end api_error: exact body" "$(dry agent-end --agent-id a8810 --agent-type athena-captain --outcome api_error --error-class rate_limit)" \
  "{\"kind\":\"agent_end\",\"claude_session_id\":\"${SID}\",\"agent_id\":\"a8810\",\"agent_type\":\"athena-captain\",\"outcome\":\"api_error\",\"error_class\":\"rate_limit\"}"
eq "agent-end spawn_denied: exact body" "$(dry agent-end --tool-use-id "${TU}" --agent-type athena-captain --outcome spawn_denied)" \
  "{\"kind\":\"agent_end\",\"claude_session_id\":\"${SID}\",\"tool_use_id\":\"${TU}\",\"agent_type\":\"athena-captain\",\"outcome\":\"spawn_denied\"}"
eq "agent-end maps an unknown --error-class to other before sending" \
  "$(dry agent-end --agent-id a1 --agent-type athena-captain --outcome api_error --error-class teapot | jq -r .error_class)" "other"
n="$(fleet_log_count)"
# refused <name> <args...> -- usage error (2), one stderr line carrying Fix:, nothing sent.
refused() {
  local name="$1"; shift
  run "$@"
  eq "${name}: usage (2)" "${RC}" "2"
  case "${ERR}" in *"Fix: "*) ok "${name}: says why with Fix:" ;; *) bad "${name}: says why with Fix:" "${ERR}" ;; esac
}
refused "agent-spawn with no --mapping" agent-spawn --tool-use-id "${TU}" --subagent-type athena-captain
refused "agent-spawn mapped with no ref" agent-spawn --tool-use-id "${TU}" --subagent-type athena-captain --mapping mapped
refused "agent-spawn with a bad ref" agent-spawn --tool-use-id "${TU}" --subagent-type athena-captain --mapping mapped --ticket-ref dnd-5
refused "agent-spawn admiral mapped" agent-spawn --tool-use-id "${TU}" --subagent-type athena-admiral --mapping mapped --ticket-ref DND-5
refused "agent-spawn general-purpose" agent-spawn --tool-use-id "${TU}" --subagent-type general-purpose --mapping unmapped
refused "agent-spawn with a bad run hint" agent-spawn --tool-use-id "${TU}" --subagent-type athena-captain --mapping unmapped --run-hint ../x
refused "agent-spawn with an unsafe tool_use_id" agent-spawn --tool-use-id "a/b" --subagent-type athena-captain --mapping unmapped
refused "agent-bound without --agent-type" agent-bound --tool-use-id "${TU}" --agent-id a1
refused "agent-start with a non-fleet type" agent-start --agent-id a1 --agent-type Explore
refused "agent-end with both keys" agent-end --agent-id a1 --tool-use-id "${TU}" --agent-type athena-captain --outcome stopped
refused "agent-end stopped by tool_use_id" agent-end --tool-use-id "${TU}" --agent-type athena-captain --outcome stopped
refused "agent-end api_error with no class" agent-end --agent-id a1 --agent-type athena-captain --outcome api_error
refused "agent-end stopped with a class" agent-end --agent-id a1 --agent-type athena-captain --outcome stopped --error-class rate_limit
refused "agent-start takes no --outcome" agent-start --agent-id a1 --agent-type athena-captain --outcome stopped
refused "agent-spawn takes no --prompt (prompt text never leaves)" agent-spawn --tool-use-id "${TU}" --subagent-type athena-captain --mapping unmapped --prompt x
refused "agent-spawn takes no --description" agent-spawn --tool-use-id "${TU}" --subagent-type athena-captain --mapping unmapped --description x
# The DND-813 strict parser covers the lifecycle flags too.
refused "a repeated --tool-use-id" agent-spawn --tool-use-id "${TU}" --tool-use-id other --subagent-type athena-captain --mapping unmapped
refused "a valueless --mapping (next word is a flag)" agent-spawn --tool-use-id "${TU}" --mapping --subagent-type athena-captain
refused "a repeated --outcome" agent-end --agent-id a1 --agent-type athena-captain --outcome stopped --outcome api_error --error-class rate_limit
refused "a trailing --error-class with no value" agent-end --agent-id a1 --agent-type athena-captain --outcome api_error --error-class
eq "no refused lifecycle report reached the server" "$(fleet_log_count)" "${n}"
run agent-end --agent-id a8810 --agent-type athena-captain --outcome stopped
eq "agent-end sends (0)" "${RC}" "0"
eq "agent_end reached the server" "$(fleet_last_request | jq -c '.body | [.kind, .agent_id, .outcome]')" '["agent_end","a8810","stopped"]'

fleet_respond '{"status":422,"body":{"error":"unprocessable_entity","fix":"remove the field owner; it is stamped server-side"}}'
run session-seen
eq "a 422 refusal exits 3" "${RC}" "3"
check "the refusal is one stderr line with Fix:" one_fix_line
case "${ERR}" in *"Fix: remove the field owner"*) ok "the server's own Fix: is printed" ;; *) bad "the server's own Fix: is printed" "${ERR}" ;; esac
fleet_respond '{"status":404,"body":{"error":"not_found"}}'
run session-seen;                   eq "a 404 not_found exits 3" "${RC}" "3"
fleet_respond '{"status":404,"raw_body":"<html>no route</html>"}'
run session-seen
case "${ERR}" in *"DND-431"*) ok "a 404 with no JSON names the missing endpoint, not the session" ;; *) bad "a 404 with no JSON names the missing endpoint, not the session" "${ERR}" ;; esac
fleet_respond '{"status":500,"body":{"error":"boom"}}'
run session-seen;                   eq "a 500 is a server fault (5), not a refusal" "${RC}" "5"
check "the fault is one stderr line with Fix:" one_fix_line
fleet_respond '{"status":202,"body":{"ok":true}}'

# [ticket] Unreachable is its own outcome: exit 4, never 3.
fleet_point_at "http://127.0.0.1:$(fleet_closed_port)/mcp"
run session-seen
eq "[ticket] an unreachable server exits 4, distinct from a refusal (3)" "${RC}" "4"
check "unreachable is one stderr line with Fix:" one_fix_line
case "${ERR}" in *"could not reach"*) ok "unreachable says it could not reach the server" ;; *) bad "unreachable says it could not reach the server" "${ERR}" ;; esac
fleet_point_at "http://127.0.0.1:${SERVER_PORT}/mcp"
# The answer is held until after the client gave up (DND-1007), so only curl's
# max-time can end the request: the verdict never depends on machine speed.
fleet_respond "{\"status\":202,\"body\":{\"ok\":true},\"hold_file\":\"${TMP}/hold-maxtime\"}"
OUT="$(FLEET_MAX_TIME_S=1 "${BIN}" session-seen 2>"${TMP}/err")"; eq "a server slower than max-time is unreachable (4)" "$?" "4"
touch "${TMP}/hold-maxtime"
fleet_respond '{"status":202,"body":{"ok":true}}'

n="$(fleet_log_count)"
fleet_point_at "http://athena.example.invalid/mcp"
run session-seen;                   eq "a non-loopback http URL is refused locally (1)" "${RC}" "1"
case "${ERR}" in *"clear text"*"Fix: "*) ok "the clear-text refusal says why" ;; *) bad "the clear-text refusal says why" "${ERR}" ;; esac
fleet_point_at "http://127.0.0.1:${SERVER_PORT}/mcp"
OUT="$(ATHENA_INBOX_CLIENT_CONFIG="${TMP}/nope.json" "${BIN}" session-seen 2>"${TMP}/err")"; eq "no token config is local configuration (1)" "$?" "1"
OUT="$(FLEET_CLAUDE_JSON="${TMP}/absent.json" "${BIN}" session-seen 2>"${TMP}/err")"; eq "no athena MCP entry is local configuration (1)" "$?" "1"
eq "no local-configuration failure sent anything" "$(fleet_log_count)" "${n}"

# ---------------------------------------------------------------------------
printf '\n%d passed, %d failed\n' "${PASS}" "${FAIL}"
if [ "${FAIL}" -ne 0 ]; then
  echo "fleet-report self-test: FAILED"
  echo "  Fix: make ai/lib/fleet/*.sh and ai/bin/fleet-report satisfy the failing cases above (contract: ai/contracts/athena-events.md -> Fleet registry and session control)."
  exit 1
fi
echo "fleet-report self-test: OK"
exit 0
