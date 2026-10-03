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

# The eleven kinds and the reportable admiral states, exactly as the contract
# (*Fleet report kinds and their closed schema*) names them. The four lifecycle
# kinds and admiral_state parked are DND-560's (DND-541).
FLEET_KINDS="session_started session_seen session_ended admiral_started admiral_scope admiral_seen admiral_state agent_spawn agent_bound agent_start agent_end"
FLEET_ADMIRAL_STATES="draining drained finished parked"

# The fleet workers: the only subagent_type / agent_type the lifecycle kinds
# carry, and the spawns the drain guard gates.
FLEET_WORKER_TYPES="athena-admiral athena-captain"

# The lifecycle kinds' closed enums (contract, same section). FLEET_ERROR_CLASSES
# is what Claude Code 2.1.282's StopFailure reports in `error` (measured,
# DND-541) plus `other`, the class any unlisted value is mapped to.
FLEET_MAPPINGS="mapped unmapped not_applicable"
FLEET_END_OUTCOMES="stopped api_error spawn_failed spawn_denied"
FLEET_ERROR_CLASSES="rate_limit overloaded authentication_failed oauth_org_not_allowed account_on_hold verification_required billing_error invalid_request model_not_found server_error max_output_tokens cloud_credential_error unknown other"

# The ticket-ref grammar (contract: `ticket_ref` on agent_spawn), and the same
# ref word-bounded for a scan of free text (*Mission pointers are metadata
# only*: a ref inside a longer token, such as XDND-5Y, does not count).
FLEET_TICKET_REF_RE='^[A-Z][A-Z0-9]{1,9}-[1-9][0-9]{0,6}$'
FLEET_TICKET_REF_SCAN='(?<![A-Za-z0-9_])[A-Z][A-Z0-9]{1,9}-[1-9][0-9]{0,6}(?![A-Za-z0-9_])'
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

# fleet_valid_notion_id <id> -- a Notion page id: 32 hex digits, bare or dashed
# 8-4-4-4-12, either case. The server applies the same rule and stores the
# canonical dashed lowercase form (gen_saas Athena.Fleet.NotionId, DND-444); a
# URL or a partial id is refused here so it never reaches the wire.
fleet_valid_notion_id() {
  local LC_ALL=C h='[0-9A-Fa-f]'
  [[ "${1:-}" =~ ^${h}{32}$ ]] ||
    [[ "${1:-}" =~ ^${h}{8}-${h}{4}-${h}{4}-${h}{4}-${h}{12}$ ]]
}

# fleet_valid_admiral_state <state>
fleet_valid_admiral_state() {
  case " ${FLEET_ADMIRAL_STATES} " in *" ${1:-} "*) [ -n "${1:-}" ] ;; *) return 1 ;; esac
}

# fleet_member <word> <space-separated list> -- status 0 when <word> is one of
# the list's words (never for an empty word).
fleet_member() {
  [ -n "${1:-}" ] || return 1
  case " ${2:-} " in *" $1 "*) return 0 ;; *) return 1 ;; esac
}

# fleet_is_fleet_worker <type> -- status 0 for athena-admiral / athena-captain.
fleet_is_fleet_worker() {
  fleet_member "${1:-}" "${FLEET_WORKER_TYPES}"
}

# --- lifecycle kinds (DND-560) ------------------------------------------------
# Normative home: athena-events.md -> *Fleet report kinds and their closed
# schema*, *Agent lifecycle* (and its *Run binding*), *Mission pointers are
# metadata only*. The description and prompt are parsed HERE, locally; only
# the parsed ref and run hint ever leave the machine.

# fleet_valid_ticket_ref <ref> -- the contract's ref grammar, whole string.
fleet_valid_ticket_ref() {
  local LC_ALL=C
  [[ "${1:-}" =~ ${FLEET_TICKET_REF_RE} ]]
}

# fleet_parse_ticket_ref <description> <prompt>
# Prints `mapped <REF>` or `unmapped` (contract, *Hook missions carry
# `ticket_ref` only*):
#   1. the distinct word-bounded refs in the description: exactly one maps;
#      two or more are ambiguous and give `unmapped` without reading the prompt;
#   2. none: the first prompt line of the form `Mission: <REF>` (optional
#      markdown bold around `Mission`; leading whitespace and text after the
#      ref are allowed, the ref itself must be word-bounded) maps;
#   3. otherwise `unmapped`.
# A jq failure (it is used as a pure function) reads as `unmapped`, never a guess.
fleet_parse_ticket_ref() {
  local out
  # The prompt goes in on stdin (-Rs), never argv: a brief can exceed one
  # argv string's limit (MAX_ARG_STRLEN, 128 KiB), and exec would fail.
  out="$(printf '%s' "${2:-}" | jq -rRs --arg d "${1:-}" --arg scan "${FLEET_TICKET_REF_SCAN}" \
    --arg line '^[ \t]*(?:\*\*Mission:\*\*|\*\*Mission\*\*:|Mission:)[ \t]*(?<r>[A-Z][A-Z0-9]{1,9}-[1-9][0-9]{0,6})(?![A-Za-z0-9_])' '
    . as $p
    | ([$d | scan($scan)] | unique) as $refs
    | if ($refs | length) == 1 then "mapped \($refs[0])"
      elif ($refs | length) > 1 then "unmapped"
      else
        (first($p | splits("\n") | capture($line) | .r) // null) as $m
        | if $m == null then "unmapped" else "mapped \($m)" end
      end' 2>/dev/null)" || out=""
  case "${out}" in
    "mapped "*) fleet_valid_ticket_ref "${out#mapped }" && { printf '%s\n' "${out}"; return 0; } ;;
  esac
  printf 'unmapped\n'
}

# fleet_parse_run_hint <prompt>
# Prints the run hint and returns 0, or prints nothing and returns 1 (contract,
# *Run binding*): the one distinct `ai-artifacts/coordination/<dir>/` in the
# prompt, where <dir> has the run-id shape (fleet_valid_id, the grammar
# fleet-report holds every run id to). Zero dirs, several distinct ones, or a
# single one of the wrong shape (`..`, `.hidden`) give no hint.
fleet_parse_run_hint() {
  local dirs
  # stdin (-Rs), never argv, for the same reason as fleet_parse_ticket_ref.
  dirs="$(printf '%s' "${1:-}" | jq -rRs --arg re 'ai-artifacts/coordination/([^/\s`'"'"'"]+)/' '
    [scan($re) | .[0]] | unique | .[]' 2>/dev/null)" || return 1
  [ -n "${dirs}" ] || return 1
  case "${dirs}" in *$'\n'*) return 1 ;; esac
  fleet_valid_id "${dirs}" || return 1
  printf '%s\n' "${dirs}"
}

# fleet_error_class <value> -- the value when it is a known error class, else
# `other` (the harness maps before sending, so a Claude Code upgrade that adds
# a class never gets a report refused).
fleet_error_class() {
  if fleet_member "${1:-}" "${FLEET_ERROR_CLASSES}"; then printf '%s\n' "$1"; else printf 'other\n'; fi
}

# fleet_failure_error_class <PostToolUseFailure error text>
# The class a foreground spawn's failure text names as `error type <class>`
# (measured, DND-541: "... (error type rate_limit, HTTP 429, ...)"), mapped
# through fleet_error_class; `other` when the text names none (an interrupt,
# a shape Claude Code has changed).
fleet_failure_error_class() {
  local LC_ALL=C re='error type ([a-z_]+)'
  if [[ "${1:-}" =~ ${re} ]]; then fleet_error_class "${BASH_REMATCH[1]}"; else printf 'other\n'; fi
}

# fleet_agent_spawn_problem <subagent_type> <mapping> <ticket_ref-or-empty>
# Prints the first combination the contract refuses and returns 1; silent 0
# otherwise. mapping is not_applicable exactly for an admiral; ticket_ref is
# present exactly when mapped, and then matches the grammar.
fleet_agent_spawn_problem() {
  local t="${1:-}" m="${2:-}" r="${3:-}"
  fleet_is_fleet_worker "${t}" || { printf 'subagent_type %s is not a fleet worker (%s)\n' "${t@Q}" "${FLEET_WORKER_TYPES}"; return 1; }
  fleet_member "${m}" "${FLEET_MAPPINGS}" || { printf 'mapping %s is not one of: %s\n' "${m@Q}" "${FLEET_MAPPINGS}"; return 1; }
  if [ "${t}" = "athena-admiral" ] && [ "${m}" != "not_applicable" ]; then
    printf 'an athena-admiral spawn carries mapping not_applicable (got %s)\n' "${m}"; return 1
  fi
  if [ "${t}" = "athena-captain" ] && [ "${m}" = "not_applicable" ]; then
    printf 'an athena-captain spawn carries mapping mapped or unmapped, never not_applicable\n'; return 1
  fi
  if [ "${m}" = "mapped" ]; then
    [ -n "${r}" ] || { printf 'mapping mapped needs a ticket ref\n'; return 1; }
    fleet_valid_ticket_ref "${r}" || { printf 'ticket ref %s does not match %s\n' "${r@Q}" "${FLEET_TICKET_REF_RE}"; return 1; }
  elif [ -n "${r}" ]; then
    printf 'a ticket ref is allowed only with mapping mapped (got %s)\n' "${m}"; return 1
  fi
  return 0
}

# fleet_agent_end_problem <agent_id> <tool_use_id> <agent_type> <outcome> <error_class>
# Prints the first combination the contract refuses and returns 1; silent 0
# otherwise. Exactly one key; stopped/api_error go by agent_id and
# spawn_failed/spawn_denied by tool_use_id; error_class exactly with api_error
# or spawn_failed, and then a known class.
fleet_agent_end_problem() {
  local a="${1:-}" u="${2:-}" t="${3:-}" o="${4:-}" c="${5:-}"
  fleet_is_fleet_worker "${t}" || { printf 'agent_type %s is not a fleet worker (%s)\n' "${t@Q}" "${FLEET_WORKER_TYPES}"; return 1; }
  fleet_member "${o}" "${FLEET_END_OUTCOMES}" || { printf 'outcome %s is not one of: %s\n' "${o@Q}" "${FLEET_END_OUTCOMES}"; return 1; }
  if [ -n "${a}" ] && [ -n "${u}" ]; then
    printf 'an agent_end carries exactly one of agent_id and tool_use_id\n'; return 1
  fi
  if [ -z "${a}" ] && [ -z "${u}" ]; then
    printf 'an agent_end carries exactly one of agent_id and tool_use_id\n'; return 1
  fi
  case "${o}" in
    stopped|api_error) [ -n "${a}" ] || { printf 'outcome %s goes by agent_id, not tool_use_id\n' "${o}"; return 1; } ;;
    *) [ -n "${u}" ] || { printf 'outcome %s goes by tool_use_id, not agent_id\n' "${o}"; return 1; } ;;
  esac
  case "${o}" in
    api_error|spawn_failed)
      [ -n "${c}" ] || { printf 'outcome %s needs an error class\n' "${o}"; return 1; }
      fleet_member "${c}" "${FLEET_ERROR_CLASSES}" || { printf 'error class %s is not one of: %s\n' "${c@Q}" "${FLEET_ERROR_CLASSES}"; return 1; } ;;
    *) [ -z "${c}" ] || { printf 'an error class is allowed only with api_error or spawn_failed (got %s)\n' "${o}"; return 1; } ;;
  esac
  return 0
}

# fleet_unmapped_notice -- the exact PreToolUse additionalContext for a captain
# spawn that names no single ticket ref (none, or two or more). Pinned in
# ai/contracts/fixtures/athena-events-quoted-fix.txt (*Mission pointers are
# metadata only*); the domain self-test asserts equality.
fleet_unmapped_notice() {
  printf '%s\n' "fleet-lifecycle: this athena-captain spawn names no single ticket ref (none, or two or more in the description), so the fleet page shows it as an unmapped captain. Fix: start the Agent description with exactly one ticket ref, the Mission's (for example DND-541 captain; a batch names only its first ticket's ref), and put a line of the form Mission: DND-541 in the brief."
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
  local origin
  origin="$(fleet_api_origin "${1:-}")" || { printf '%s\n' "${origin}"; return 1; }
  printf '%s/api/v1/fleet/reports\n' "${origin}"
}

# fleet_api_origin <mcp-url>
# The scheme://authority of the registered athena MCP URL, under the rules
# above. Every fleet REST path (reports, DND-433; session control, DND-443) is
# built on it. Status 1 with a reason on stdout when the URL is unusable.
fleet_api_origin() {
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
  printf '%s\n' "${host}"
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
# Status 0 = a report is due. Due when there is no stamp, or when the stamp is
# at least <interval> seconds away from now in EITHER direction.
# A stamp less than <interval> in the future is NOT due (DND-1652): a second
# boundary or a small clock skew between the stamping caller and this one must
# not open the throttle. A stamp further in the future is due, so a clock
# stepped back far never silences the reporter until it catches up. The
# silence is bounded: a stamp under <interval> ahead stops being refused once
# now reaches stamp + interval, under 2 x <interval> from now.
fleet_seen_due() {
  local now="$1" stamp="${2:-}" interval="${3:-${FLEET_SEEN_INTERVAL_S}}" age
  [ -n "${stamp}" ] || return 0
  age=$(( now - stamp ))
  [ "${age}" -ge "${interval}" ] || [ "${age}" -le "-${interval}" ]
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

# fleet_body_admiral_scope <sid> <run_id> <missions-json> [notion_project_id]
# The Notion Project id is optional (DND-444); omitted when empty, never sent
# as null (the server refuses a null optional field).
fleet_body_admiral_scope() {
  local sid="$1" run_id="$2" missions="$3" project="${4:-}"
  jq -n -c --arg s "${sid}" --arg r "${run_id}" --argjson m "${missions}" --arg p "${project}" \
    '{kind: "admiral_scope", claude_session_id: $s, run_id: $r, missions: $m}
     + (if $p == "" then {} else {notion_project_id: $p} end)'
}

fleet_body_admiral_state() {
  local sid="$1" run_id="$2" state="$3"
  jq -n -c --arg s "${sid}" --arg r "${run_id}" --arg st "${state}" \
    '{kind: "admiral_state", claude_session_id: $s, run_id: $r, state: $st}'
}

# fleet_body_agent_spawn <sid> <tool_use_id> <subagent_type> <caller_agent_id> <mapping> <ticket_ref> <run_hint>
# caller_agent_id, ticket_ref and run_hint are omitted when empty.
fleet_body_agent_spawn() {
  jq -n -c --arg s "$1" --arg u "$2" --arg t "$3" --arg c "${4:-}" --arg m "$5" --arg r "${6:-}" --arg h "${7:-}" \
    '{kind: "agent_spawn", claude_session_id: $s, tool_use_id: $u, subagent_type: $t, mapping: $m}
     + (if $c == "" then {} else {caller_agent_id: $c} end)
     + (if $r == "" then {} else {ticket_ref: $r} end)
     + (if $h == "" then {} else {run_hint: $h} end)'
}

# fleet_body_agent_bound <sid> <tool_use_id> <agent_id> <agent_type>
fleet_body_agent_bound() {
  jq -n -c --arg s "$1" --arg u "$2" --arg a "$3" --arg t "$4" \
    '{kind: "agent_bound", claude_session_id: $s, tool_use_id: $u, agent_id: $a, agent_type: $t}'
}

# fleet_body_agent_start <sid> <agent_id> <agent_type>
fleet_body_agent_start() {
  jq -n -c --arg s "$1" --arg a "$2" --arg t "$3" \
    '{kind: "agent_start", claude_session_id: $s, agent_id: $a, agent_type: $t}'
}

# fleet_body_agent_end <sid> <agent_id> <tool_use_id> <agent_type> <outcome> <error_class>
# Exactly one of agent_id / tool_use_id is non-empty (fleet_agent_end_problem);
# the empty key and an empty error_class are omitted.
fleet_body_agent_end() {
  jq -n -c --arg s "$1" --arg a "${2:-}" --arg u "${3:-}" --arg t "$4" --arg o "$5" --arg c "${6:-}" \
    '{kind: "agent_end", claude_session_id: $s}
     + (if $a == "" then {} else {agent_id: $a} end)
     + (if $u == "" then {} else {tool_use_id: $u} end)
     + {agent_type: $t, outcome: $o}
     + (if $c == "" then {} else {error_class: $c} end)'
}
