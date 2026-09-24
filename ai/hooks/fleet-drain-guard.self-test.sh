#!/usr/bin/env bash
# fleet-drain-guard.self-test.sh -- the drain guard hook's matrix (DND-443).
# Declared in ai/bin/harness-gate. Pipes PreToolUse JSON shaped like DND-428's
# measured stdin into the REAL hook, which runs the REAL ai/bin/fleet-control
# against a FAKE server (loopback only; never prod).
#
# Matrix (contract, *Enforcement layers* -> *Layer 1: the drain guard hook*):
#   drain -> deny, reason == the pinned Fix: line in
#            ai/contracts/fixtures/athena-events-quoted-fix.txt, filled in;
#   run   -> silent pass;
#   each unknown cause -> a visible warning, never a silent run;
#   a non-fleet subagent type -> passes with NO server call;
#   unparseable stdin, or a fleet spawn with no session_id -> deny;
#   a fleet-control error -> deny, never read as run;
#   resume -> the server's run beats a stale drain cache.

set -u

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
AI="$(cd -- "${HERE}/.." && pwd -P)"
HOOK="${HERE}/fleet-drain-guard.sh"
TESTS="${AI}/lib/fleet/test"
FAKE="${TESTS}/fake-fleet-server.py"
FIXTURE="${AI}/contracts/fixtures/athena-events-quoted-fix.txt"

PASS=0
FAIL=0
ok()   { PASS=$((PASS + 1)); printf 'ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL + 1)); printf 'FAIL %s\n' "$1"; [ -n "${2:-}" ] && printf '     %s\n' "$2"; return 0; }
eq()   { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$3], got [$2]"; fi; }
has()  { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "[$3] not in [$2]" ;; esac; }

for dep in jq curl python3 git flock timeout; do
  command -v "${dep}" >/dev/null 2>&1 || { echo "fleet-drain-guard self-test: FAIL -- ${dep} is not on PATH"; echo "  Fix: install ${dep}; this suite does not skip."; exit 1; }
done

TMP="$(mktemp -d)" || { echo "FAIL mktemp"; exit 1; }
SERVER_PID=""
cleanup() {
  [ -n "${SERVER_PID}" ] && kill "${SERVER_PID}" 2>/dev/null
  rm -rf "${TMP}"
}
trap cleanup EXIT INT TERM

# shellcheck source=../lib/fleet/test/helpers.sh
. "${TESTS}/helpers.sh"
# shellcheck source=../lib/fleet/domain.sh
. "${AI}/lib/fleet/domain.sh"
# shellcheck source=../lib/fleet/control-domain.sh
. "${AI}/lib/fleet/control-domain.sh"
fleet_fixture_env
export FLEET_CONNECT_TIMEOUT_S=2 FLEET_MAX_TIME_S=3

SID="ca4aa9d6-cc9f-46b8-bcba-b62afb5ea534"
CACHE="${XDG_STATE_HOME}/athena/fleet/${SID}.json"
GLOG="${XDG_STATE_HOME}/athena/fleet/drain-guard.log"
git init -q "${TMP}/custom"
jq -n --arg r "$(realpath "${TMP}/custom/.git")" '{v: 1, repo: $r, channels: {}}' > "${ATHENA_INBOX_ROOT}/projects/custom.json"
chmod 600 "${ATHENA_INBOX_ROOT}/projects/custom.json"
CU="${TMP}/custom"

P1='{"override":null,"effective_domain":"blend","metering":{"enabled":false}}'
OVD='{"override":{"desired":"drain","expires_at":null},"effective_domain":"blend","metering":{"enabled":false}}'
answer() {
  jq -n -c --arg s "${SID}" --arg d "$1" --arg r "$2" --argjson u "$3" --argjson p "$4" \
    '{claude_session_id: $s, desired: $d, reason: $r, until: $u, policy_snapshot: $p}'
}
RUN_ANS="$(answer run default null "${P1}")"
# A cache fetched one minute ago by the REAL clock: the hook never passes --now,
# so a fixed timestamp would turn stale (or into the future) as days pass.
FRESH="$(date -u -d '-1 min' +%Y-%m-%dT%H:%M:%SZ)"
DRAIN_ANS="$(answer drain override:force_drain '"2026-09-24T18:30:00Z"' "${OVD}")"

# stdin <subagent_type-or-empty> [session_id] -- DND-428's measured PreToolUse
# shape for an Agent call made BY an admiral subagent.
stdin() {
  jq -n -c --arg t "$1" --arg s "${2-${SID}}" --arg c "${CU}" '
    {session_id: $s, cwd: $c, hook_event_name: "PreToolUse", tool_name: "Agent",
     agent_id: "a5a8eb5540d6e6ab3", agent_type: "athena-admiral", permission_mode: "default",
     tool_input: ({description: "x", prompt: "y"} + (if $t == "" then {} else {subagent_type: $t} end))}
    | if $s == "" then del(.session_id) else . end'
}

# hook <stdin-json> -- sets OUT, RC.
hook() { OUT="$(printf '%s' "$1" | "${HOOK}" 2>"${TMP}/herr")"; RC=$?; }
decision() { printf '%s' "${OUT}" | jq -r '.hookSpecificOutput.permissionDecision // "none"' 2>/dev/null; }
reason()   { printf '%s' "${OUT}" | jq -r '.hookSpecificOutput.permissionDecisionReason // ""' 2>/dev/null; }
context()  { printf '%s' "${OUT}" | jq -r '.hookSpecificOutput.additionalContext // ""' 2>/dev/null; }
sysmsg()   { printf '%s' "${OUT}" | jq -r '.systemMessage // ""' 2>/dev/null; }

echo "== the pinned deny text"
pinned="$(awk '/^@section Layer 1: the drain guard hook$/ {s=1; next} /^@section / {s=0} s && /^Fix: fleet session/' "${FIXTURE}")"
[ -n "${pinned}" ] || bad "the fixture pins a Layer 1 line" "no 'Fix: fleet session' line under '@section Layer 1: the drain guard hook' in ${FIXTURE}"
eq "fleet_drain_fix renders the pinned line (placeholders)" \
  "$(fleet_drain_fix '<claude_session_id>' '<reason>' '<until>' '<basis>')" "${pinned}"
eq "an absent until renders 'unbounded'" \
  "$(fleet_drain_fix s r "" b)" "$(printf '%s' "${pinned}" | sed 's/<claude_session_id>/s/; s/<reason>/r/; s/<until>/unbounded/; s/<basis>/b/')"

echo "== non-fleet spawns pass with no server call"
rm -f "${TMP}/port"
fleet_start_server || exit 1
fleet_respond "{\"status\":200,\"body\":${DRAIN_ANS}}"
before="$(fleet_log_count)"
for t in athena-architect athena-diff-critic Explore general-purpose ""; do
  hook "$(stdin "${t}")"
  eq "[${t:-no subagent_type}] passes: exit 0, no output" "${RC}:${OUT}" "0:"
done
eq "non-fleet spawns made no server call" "$(fleet_log_count)" "${before}"
check_nolog() { [ ! -s "${GLOG}" ]; }
if check_nolog; then ok "non-fleet spawns write no guard log line"; else bad "non-fleet spawns write no guard log line"; fi
hook "$(stdin Explore "")"
eq "a non-fleet spawn with no session_id still passes" "${RC}:${OUT}" "0:"

echo "== drain denies with the pinned Fix"
for t in athena-captain athena-admiral; do
  hook "$(stdin "${t}")"
  eq "[${t}] drain: exit 0 with a deny" "${RC}:$(decision)" "0:deny"
  eq "[${t}] drain: reason is the pinned line, filled in" "$(reason)" \
    "$(fleet_drain_fix "${SID}" override:force_drain 2026-09-24T18:30:00Z server)"
done
has "the guard asked the server with the hook's session_id" "$(jq -r .path <<<"$(fleet_last_request)")" "/sessions/${SID}/control"
has "the deny is logged" "$(tail -n 1 "${GLOG}")" "athena-admiral	deny	server"

echo "== run passes silently"
fleet_respond "{\"status\":200,\"body\":${RUN_ANS}}"
hook "$(stdin athena-captain)"
eq "run on basis server: exit 0, no output" "${RC}:${OUT}" "0:"
has "the allow is logged" "$(tail -n 1 "${GLOG}")" "athena-captain	allow	server"

echo "== resume: the server's run beats a stale drain cache"
jq -c --arg t "${FRESH}" '.fetched_at = $t' <<<"${DRAIN_ANS}" > "${CACHE}"
hook "$(stdin athena-admiral)"
eq "resume spawn passes" "${RC}:${OUT}" "0:"
eq "the cache now says run" "$(jq -r .desired "${CACHE}")" run

echo "== unknown control state always warns, never a silent run"
# unknown_case <name> <server-response-json-or-'down'> <cache: run|drain|none|junk> <want: allow|deny> <basis>
unknown_case() {
  local name="$1" resp="$2" cache="$3" want="$4" basis="$5"
  case "${cache}" in
    run)   jq -c --arg t "${FRESH}" '.fetched_at = $t' <<<"${RUN_ANS}" > "${CACHE}" ;;
    drain) jq -c --arg t "${FRESH}" '.fetched_at = $t' <<<"${DRAIN_ANS}" > "${CACHE}" ;;
    junk)  printf 'junk' > "${CACHE}" ;;
    none)  rm -f "${CACHE}" ;;
  esac
  fleet_respond "${resp}"
  hook "$(stdin athena-captain)"
  if [ "${want}" = "allow" ]; then
    eq "${name}: passes (exit 0, no deny)" "${RC}:$(decision)" "0:none"
    has "${name}: the model sees the warning (additionalContext)" "$(context)" "basis ${basis}"
    has "${name}: the human sees the warning (systemMessage)" "$(sysmsg)" "WARNING"
  else
    eq "${name}: denies" "${RC}:$(decision)" "0:deny"
    has "${name}: the deny names the basis" "$(reason)" "basis ${basis})"
    has "${name}: the warning is shown too" "$(sysmsg)" "WARNING"
  fi
}
unknown_case "server-refused, run cache"      '{"status":401,"body":{"error":"unauthorized"}}' run   allow "recomputed:server-refused"
unknown_case "session-unregistered, no cache" '{"status":404,"body":{"error":"not_found"}}'    none  allow "local-rule:session-unregistered,no-cache"
unknown_case "malformed-answer, junk cache"   '{"status":200,"body":{"desired":"run"}}'         junk  allow "local-rule:malformed-answer,malformed-cache"
unknown_case "malformed-answer, drain cache"  '{"status":503,"body":{}}'                        drain deny  "recomputed:malformed-answer"
jq -c '.fetched_at = "2026-09-20T15:00:00Z"' <<<"${RUN_ANS}" > "${CACHE}"
fleet_respond '{"status":503,"body":{}}'
hook "$(stdin athena-captain)"
has "expired-cache: warns with the age" "$(context)" "h old"
kill "${SERVER_PID}" 2>/dev/null; wait "${SERVER_PID}" 2>/dev/null; SERVER_PID=""
fleet_point_at "http://127.0.0.1:$(fleet_closed_port)/mcp"
unknown_case "server-unreachable, run cache"  '{}' run  allow "recomputed:server-unreachable"
unknown_case "server-unreachable, drain cache" '{}' drain deny "recomputed:server-unreachable"
mv "${ATHENA_INBOX_CLIENT_CONFIG}" "${TMP}/cfg.off"
unknown_case "server-unconfigured, no cache"  '{}' none allow "local-rule:server-unconfigured,no-cache"
mv "${TMP}/cfg.off" "${ATHENA_INBOX_CLIENT_CONFIG}"
( export XDG_STATE_HOME=relative-state; cd "${TMP}" || exit 1
  printf '%s' "$(stdin athena-captain)" | "${HOOK}" > "${TMP}/relout" 2>/dev/null )
has "invalid-cache-path: warns with its basis" "$(jq -r '.hookSpecificOutput.additionalContext // ""' "${TMP}/relout")" "invalid-cache-path"

echo "== what the guard cannot classify or look up is refused"
hook "not json at all"
eq "unparseable stdin: deny" "${RC}:$(decision)" "0:deny"
has "unparseable stdin: carries Fix:" "$(reason)" "Fix:"
hook '"a json string"'
eq "a non-object stdin: deny" "${RC}:$(decision)" "0:deny"
hook ""
eq "empty stdin: deny" "${RC}:$(decision)" "0:deny"
hook "$(stdin athena-captain "")"
eq "fleet spawn with no session_id: deny" "${RC}:$(decision)" "0:deny"
has "... names the missing session_id" "$(reason)" "no usable session_id"
hook "$(stdin athena-captain "../../etc")"
eq "fleet spawn with an unsafe session_id: deny" "${RC}:$(decision)" "0:deny"
# A fleet-control error (here: curl missing from PATH, so it exits 1) is never read as run.
mkdir -p "${TMP}/bin"
for c in bash jq git realpath dirname date mktemp cat grep tr sed stat timeout flock mkdir chmod mv rm head cut awk env printf; do
  p="$(command -v "${c}" 2>/dev/null)" && [ -n "${p}" ] && [ "${p#/}" != "${p}" ] && ln -sf "${p}" "${TMP}/bin/${c}"
done
OUT="$(printf '%s' "$(stdin athena-captain)" | PATH="${TMP}/bin" "${HOOK}" 2>/dev/null)"; RC=$?
eq "fleet-control error (exit 1): deny" "${RC}:$(decision)" "0:deny"
has "... names the exit" "$(reason)" "exit 1"

echo "== --help"
out="$("${HOOK}" --help)"; rc=$?
eq "--help exits 0" "${rc}" 0
has "--help names the matcher" "${out}" "Agent|Task"

echo
echo "${PASS} passed, ${FAIL} failed"
if [ "${FAIL}" -ne 0 ]; then
  echo "fleet-drain-guard self-test: FAIL"
  echo "  Fix: read the FAIL lines above; each names the Layer 1 rule it checks (athena-events.md -> Enforcement layers)."
  exit 1
fi
echo "fleet-drain-guard self-test: OK"
