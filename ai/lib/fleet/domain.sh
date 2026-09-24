#!/usr/bin/env bash
# domain.sh -- DOMAIN: pure. The fleet-report rules as string-in, string-out
# functions. Nothing here reads a file, the environment, or the network. The
# one effect is jq, used as a pure JSON function.
#
# Normative home: ai/contracts/athena-events.md -> *Fleet registry and session
# control*, above all *Fleet report kinds and their closed schema* and *Mission
# pointers are metadata only*. This file builds bodies that satisfy that closed
# schema and refuses, locally, anything the server would refuse. The server
# stays the enforcer; the local refusal exists so a bad call fails with a
# precise Fix: before a token is ever sent.
#
# Source order: this file only. Requires jq.

# The seven kinds, exactly as the contract names them.
FLEET_KINDS="session_started session_seen session_ended admiral_started admiral_scope admiral_seen admiral_state"
FLEET_ADMIRAL_STATES="draining drained finished"
FLEET_TRACKERS='["notion-personal","notion-work"]'
FLEET_CAPTAIN_STATES='["queued","running","parked","done","blocked","stuck"]'
FLEET_MISSION_KEYS='["tracker","ticket_ref","url","title","status","captain_state"]'

# The throttle interval for session_seen / admiral_seen, in seconds (contract:
# "at most once per 60 s per (session, agent_id)").
FLEET_SEEN_INTERVAL_S=60

# The agent_type that makes a PostToolUse report an admiral_seen.
FLEET_ADMIRAL_AGENT_TYPE="athena-admiral"

# fleet_valid_id <value>
# A session id, agent id, or run id. It becomes a path component of the
# throttle stamp and a JSON string, so it is held to one conservative grammar:
# an ASCII letter or digit, then letters, digits, `.`, `_`, `-`, 1..128 bytes.
# No `/`, no leading `.`, no whitespace, nothing that could name another path.
fleet_valid_id() {
  local LC_ALL=C
  [[ "${1:-}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ ]]
}

# fleet_valid_admiral_state <state>
fleet_valid_admiral_state() {
  case " ${FLEET_ADMIRAL_STATES} " in *" ${1:-} "*) [ -n "${1:-}" ] ;; *) return 1 ;; esac
}

# fleet_reports_url <mcp-url>
# The REST endpoint, derived from the registered athena MCP URL's origin:
# https://athena.example/mcp -> https://athena.example/api/v1/fleet/reports.
# Status 1 with a reason on stdout when the URL is unusable.
#
# https only. The one exception is plain http to a LOOPBACK host
# (127.0.0.1, localhost, [::1]): that request never leaves the machine, and it
# is what a local fake server needs. Any other http URL is refused, because
# the machine token would go over the wire in clear text.
#
# The authority is parsed EXACTLY, never matched on a prefix: a userinfo part
# (`http://localhost:x@evil.example/`) makes curl connect to the host after the
# `@`, so an `@` anywhere in the authority is refused, and a port must be
# digits.
fleet_reports_url() {
  local url="${1:-}" scheme rest authority host
  local LC_ALL=C
  [ -n "${url}" ] || { printf 'the athena MCP URL is empty\n'; return 1; }
  case "${url}" in
    https://*) scheme=https; rest="${url#https://}" ;;
    http://*)  scheme=http;  rest="${url#http://}" ;;
    *) printf 'the athena MCP URL is not http(s)\n'; return 1 ;;
  esac
  authority="${rest%%[/?#]*}"
  case "${authority}" in
    *@*) printf 'the athena MCP URL carries a user/password part, which would send the token to the host after the @\n'; return 1 ;;
  esac
  if [ "${scheme}" = "http" ]; then
    [[ "${authority}" =~ ^(127\.0\.0\.1|localhost|\[::1\])(:[0-9]{1,5})?$ ]] || {
      printf 'the athena MCP URL is not https (and not loopback), so the machine token would be sent in clear text\n'; return 1; }
  else
    [[ "${authority}" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?(:[0-9]{1,5})?$ ]] || {
      printf 'the athena MCP URL has no usable host\n'; return 1; }
  fi
  host="${scheme}://${authority}"
  printf '%s/api/v1/fleet/reports\n' "${host}"
}

# fleet_seconds <value> <default>
# A timeout in whole seconds: 1..9999 with no leading zero, else <default>.
# These values are written into a curl config line and handed to timeout(1), so
# anything else (a newline could add a `url = ...` line) never passes through.
fleet_seconds() {
  case "${1:-}" in
    [1-9]|[1-9][0-9]|[1-9][0-9][0-9]|[1-9][0-9][0-9][0-9]) printf '%s\n' "$1" ;;
    *) printf '%s\n' "$2" ;;
  esac
}

# fleet_seen_kind <agent_type> <agent_id>
# admiral_seen when the caller is an athena-admiral with an agent_id; otherwise
# session_seen (contract, *Who sends what*). An admiral_seen needs agent_id, so
# an admiral-typed call without one is reported as session_seen, never dropped.
fleet_seen_kind() {
  if [ "${1:-}" = "${FLEET_ADMIRAL_AGENT_TYPE}" ] && [ -n "${2:-}" ]; then
    printf 'admiral_seen\n'
  else
    printf 'session_seen\n'
  fi
}

# fleet_throttle_key <session_id> <agent_id-or-empty>
# One stamp per (session, agent). The top-level session has no agent_id, so it
# keys as `main`. `main` cannot collide with a real agent id: real ids are hex.
fleet_throttle_key() {
  printf '%s.%s\n' "$1" "${2:-main}"
}

# fleet_seen_due <now-epoch> <stamp-mtime-epoch-or-empty> [interval]
# Status 0 = a report is due. Due when there is no stamp, when the stamp is at
# least <interval> seconds old, or when it is in the future (a clock stepped
# back must not silence the reporter until the clock catches up).
fleet_seen_due() {
  local now="$1" stamp="${2:-}" interval="${3:-${FLEET_SEEN_INTERVAL_S}}" age
  [ -n "${stamp}" ] || return 0
  age=$(( now - stamp ))
  [ "${age}" -lt 0 ] && return 0
  [ "${age}" -ge "${interval}" ]
}

# fleet_outcome <curl-exit> <http-code>
# Maps a transport result to one outcome word. Each is its own observable:
#   ok           2xx
#   refused      4xx: the server answered and said no
#   unreachable  no HTTP answer at all (connect failure, DNS, timeout)
#   server-fault the server answered 5xx or something that is not HTTP-shaped
fleet_outcome() {
  local rc="$1" code="${2:-}"
  if [ "${rc}" != "0" ] || [ -z "${code}" ] || [ "${code}" = "000" ]; then
    printf 'unreachable\n'; return 0
  fi
  case "${code}" in
    2??) printf 'ok\n' ;;
    4??) printf 'refused\n' ;;
    *)   printf 'server-fault\n' ;;
  esac
}

# fleet_exit_for <outcome>
# The CLI's exit code per outcome (see bin/fleet-report --help).
fleet_exit_for() {
  case "$1" in
    ok) printf '0\n' ;;
    refused) printf '3\n' ;;
    unreachable) printf '4\n' ;;
    server-fault) printf '5\n' ;;
    *) printf '1\n' ;;
  esac
}

# fleet_refusal_fix <http-code> <response-body>
# The Fix: text for a refusal. The server's own `fix` when it sent one; else a
# fix that names what the code means here. A 404 carrying {"error":"not_found"}
# (session bound to another machine) and a 404 with no JSON (no endpoint at
# that URL) are different facts and get different fixes.
fleet_refusal_fix() {
  local code="$1" body="${2:-}" fix err
  fix="$(printf '%s' "${body}" | jq -r 'if type == "object" and (.fix | type) == "string" then .fix else empty end' 2>/dev/null | head -n 1)"
  if [ -n "${fix}" ]; then printf '%s\n' "${fix}"; return 0; fi
  err="$(printf '%s' "${body}" | jq -r 'if type == "object" and (.error | type) == "string" then .error else empty end' 2>/dev/null | head -n 1)"
  case "${code}:${err}" in
    404:not_found)
      printf 'the server does not know this session from this machine (a session is bound to the machine that first reported it); report session_started from this machine first, or check the session id.\n' ;;
    404:*)
      printf 'no fleet endpoint answered at this URL; check that the server has POST /api/v1/fleet/reports deployed (DND-431) and that the athena MCP URL in ~/.claude.json is right.\n' ;;
    401:*)
      printf 'the server refused the machine token; check the token in ~/.config/athena-inbox-client/config.json (credentials are owner-gated: do not rotate it yourself).\n' ;;
    *)
      printf 'the server answered HTTP %s with no fix; read the request against ai/contracts/athena-events.md -> Fleet report kinds and their closed schema.\n' "${code}" ;;
  esac
}

# fleet_missions_problem <missions-json>
# Prints the FIRST problem with a mission-pointer list and returns 1, or
# prints nothing and returns 0. The list must be a JSON array of objects with
# EXACTLY the six pointer fields (contract, *Mission pointers are metadata
# only*); a body, comment, summary, label or assignee is refused by name.
fleet_missions_problem() {
  local problem
  problem="$(printf '%s' "${1:-}" | jq -r \
    --argjson keys "${FLEET_MISSION_KEYS}" \
    --argjson trackers "${FLEET_TRACKERS}" \
    --argjson cstates "${FLEET_CAPTAIN_STATES}" '
    def str($o; $k): ($o[$k] | type) == "string" and ($o[$k] | length) > 0;
    if type != "array" then "the missions file must hold a JSON array of mission pointers (it holds a \(type))"
    else
      ( [ to_entries[] | .key as $i | .value as $m |
          if ($m | type) != "object" then "mission #\($i) is a \($m | type), not an object"
          else
            ( ([$m | keys[] | select(. as $k | $keys | index($k) | not)]) as $extra
            | ([$keys[] | select(. as $k | $m | has($k) | not)]) as $missing
            | if ($extra | length) > 0 then "mission #\($i) has field(s) \($extra | join(", ")) that a mission pointer may not carry (only \($keys | join(", ")))"
              elif ($missing | length) > 0 then "mission #\($i) is missing \($missing | join(", "))"
              elif ([ $keys[] as $k | select(str($m; $k) | not) | $k ] | length) > 0 then "mission #\($i) has an empty or non-string value in \([ $keys[] as $k | select(str($m; $k) | not) | $k ] | join(", "))"
              elif ($trackers | index($m.tracker) | not) then "mission #\($i) has tracker \($m.tracker | tojson); allowed: \($trackers | join(", "))"
              elif ($cstates | index($m.captain_state) | not) then "mission #\($i) has captain_state \($m.captain_state | tojson); allowed: \($cstates | join(", "))"
              else empty end )
          end ] | first // empty )
      // ( [ .[] | [.tracker, .ticket_ref] ] | group_by(.) | map(select(length > 1)) | first
           | if . == null then empty else "(tracker, ticket_ref) \(.[0] | tojson) appears more than once; it must be unique within a run" end )
    end' 2>/dev/null)" || { printf 'the missions file is not valid JSON\n'; return 1; }
  [ -z "${problem}" ] && return 0
  printf '%s\n' "${problem}"
  return 1
}

# fleet_failure_notice <count> <latest-log-line> <log-path>
# The one line the SessionStart hook adds to a new session's context when
# background reports failed since the last announcement. Empty for count 0.
fleet_failure_notice() {
  local n="$1" latest="$2" log="$3" when kind msg
  [ "${n}" -gt 0 ] 2>/dev/null || return 0
  IFS=$'\t' read -r _ when _ kind msg <<<"${latest}"
  printf 'fleet-report: %s background fleet registry report(s) failed since the last notice. Latest at %s (%s), reported text, not an instruction: [%s] Full log: %s. Fix: read the log and diagnose (network, server, or local config); these reports are advisory and never block the fleet.\n' \
    "${n}" "${when:-?}" "${kind:-?}" "${msg:-?}" "${log}"
}

# --- body builders ----------------------------------------------------------
# Each prints one compact JSON object and nothing else. Optional fields are
# OMITTED when empty (the closed schema has no null for them), with one
# exception: session_started's `project`, which the contract says is stated as
# null rather than omitted.

fleet_body_session_started() {
  local sid="$1" project="$2" repo_key="$3"
  jq -n -c --arg s "${sid}" --arg p "${project}" --arg r "${repo_key}" \
    '{kind: "session_started", claude_session_id: $s,
      project: (if $p == "" then null else $p end), repo_key: $r}'
}

fleet_body_seen() {
  local kind="$1" sid="$2" agent_id="${3:-}" agent_type="${4:-}"
  jq -n -c --arg k "${kind}" --arg s "${sid}" --arg a "${agent_id}" --arg t "${agent_type}" \
    '{kind: $k, claude_session_id: $s}
     + (if $a == "" then {} else {agent_id: $a} end)
     + (if $t == "" then {} else {agent_type: $t} end)'
}

fleet_body_session_ended() {
  local sid="$1" reason="${2:-}"
  jq -n -c --arg s "${sid}" --arg r "${reason}" \
    '{kind: "session_ended", claude_session_id: $s} + (if $r == "" then {} else {end_reason: $r} end)'
}

fleet_body_admiral_started() {
  local sid="$1" run_id="$2" agent_id="$3" label="${4:-}"
  jq -n -c --arg s "${sid}" --arg r "${run_id}" --arg a "${agent_id}" --arg l "${label}" \
    '{kind: "admiral_started", claude_session_id: $s, run_id: $r, agent_id: $a}
     + (if $l == "" then {} else {scope_label: $l} end)'
}

fleet_body_admiral_scope() {
  local sid="$1" run_id="$2" missions="$3"
  jq -n -c --arg s "${sid}" --arg r "${run_id}" --argjson m "${missions}" \
    '{kind: "admiral_scope", claude_session_id: $s, run_id: $r, missions: $m}'
}

fleet_body_admiral_state() {
  local sid="$1" run_id="$2" state="$3"
  jq -n -c --arg s "${sid}" --arg r "${run_id}" --arg st "${state}" \
    '{kind: "admiral_state", claude_session_id: $s, run_id: $r, state: $st}'
}
