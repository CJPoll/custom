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

check "admiral state: finished"     fleet_valid_admiral_state finished
check "admiral state: running is not reportable" bash -c '. "$0"; ! fleet_valid_admiral_state running' "${LIB}/domain.sh"
check "admiral state: empty"        bash -c '. "$0"; ! fleet_valid_admiral_state ""' "${LIB}/domain.sh"

eq "reports url from https mcp url" "$(fleet_reports_url https://athena.cjpoll.me/mcp)" "https://athena.cjpoll.me/api/v1/fleet/reports"
eq "reports url keeps the port"     "$(fleet_reports_url http://127.0.0.1:4567/mcp)" "http://127.0.0.1:4567/api/v1/fleet/reports"
eq "reports url, no path"           "$(fleet_reports_url https://h.example)" "https://h.example/api/v1/fleet/reports"
check "reports url refuses plain http off-loopback" bash -c '. "$0"; ! fleet_reports_url http://athena.cjpoll.me/mcp >/dev/null' "${LIB}/domain.sh"
check "reports url refuses http to a loopback-looking host" bash -c '. "$0"; ! fleet_reports_url http://127.0.0.1.evil.example/mcp >/dev/null' "${LIB}/domain.sh"
check "reports url refuses empty"   bash -c '. "$0"; ! fleet_reports_url "" >/dev/null' "${LIB}/domain.sh"
check "reports url refuses no host" bash -c '. "$0"; ! fleet_reports_url "https:///mcp" >/dev/null' "${LIB}/domain.sh"

eq "seen kind: admiral with id"     "$(fleet_seen_kind athena-admiral abc123)" "admiral_seen"
eq "seen kind: admiral without id"  "$(fleet_seen_kind athena-admiral "")" "session_seen"
eq "seen kind: captain"             "$(fleet_seen_kind athena-captain abc123)" "session_seen"
eq "seen kind: top level"           "$(fleet_seen_kind "" "")" "session_seen"

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
eq "body admiral_state" "$(fleet_body_admiral_state S R finished)" '{"kind":"admiral_state","claude_session_id":"S","run_id":"R","state":"finished"}'

# No body builder may ever emit an identity field the server stamps.
all_bodies="$(fleet_body_session_started S p /r; fleet_body_seen session_seen S A T; fleet_body_session_ended S x;
  fleet_body_admiral_started S R A L; fleet_body_admiral_scope S R "${GOOD_M}"; fleet_body_admiral_state S R finished)"
if printf '%s\n' "${all_bodies}" | jq -e 'has("owner") or has("owner_id") or has("machine") or has("machine_id")' >/dev/null 2>&1; then
  bad "no body carries owner/machine"
else ok "no body carries owner/machine"; fi

if [ "${FLEET_SELF_TEST_ONLY:-}" = "domain" ]; then
  printf '\n%d passed, %d failed\n' "${PASS}" "${FAIL}"
  [ "${FAIL}" -eq 0 ] || { echo "Fix: make lib/fleet/domain.sh satisfy the failing cases above."; exit 1; }
  exit 0
fi

# ---------------------------------------------------------------------------
echo "== effects"

# shellcheck disable=SC1091
INBOX_LIB="${AI}/skills/athena:inbox/lib"
. "${INBOX_LIB}/err.sh"; . "${INBOX_LIB}/names.sh"; . "${INBOX_LIB}/fs.sh"; . "${INBOX_LIB}/descriptor.sh"
. "${LIB}/effects.sh"
. "${HERE}/helpers.sh"
fleet_fixture_env

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
run admiral-seen --agent-id a5a8eb5540d6e6ab3 --agent-type athena-admiral
eq "admiral_seen body" "$(fleet_last_request | jq -c '.body | [.kind, .agent_id, .agent_type]')" '["admiral_seen","a5a8eb5540d6e6ab3","athena-admiral"]'
run admiral-state --run-id r1 --state finished
eq "admiral_state body" "$(fleet_last_request | jq -c '.body | [.kind, .run_id, .state]')" '["admiral_state","r1","finished"]'
run session-end --reason other
eq "session_ended body" "$(fleet_last_request | jq -c '.body | [.kind, .end_reason]')" '["session_ended","other"]'

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
fleet_respond '{"status":202,"body":{"ok":true},"delay_s":3}'
OUT="$(FLEET_MAX_TIME_S=1 "${BIN}" session-seen 2>"${TMP}/err")"; eq "a server slower than max-time is unreachable (4)" "$?" "4"
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
