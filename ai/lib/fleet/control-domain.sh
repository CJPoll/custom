#!/usr/bin/env bash
# control-domain.sh -- DOMAIN: pure. The session-control rules (DND-443) as
# string-in, string-out functions. Nothing here reads a file, the environment,
# or the network. jq and date(1) are used as pure functions: date(1) reads the
# tz database, which is fixed data, and the caller (the manager) has already
# checked the zone exists through an effect.
#
# Normative home: ai/contracts/athena-events.md -> *Fleet registry and session
# control* -> *Session control: desired state*, *Reading control state and the
# control cache*, *Unknown control state* and *Enforcement layers* -> *Layer 1:
# the drain guard hook*.
#
# Source order: domain.sh, then this file. Requires jq and GNU date.

# The fleet workers the drain guard gates. Every other spawn passes.
FLEET_WORKER_TYPES="athena-admiral athena-captain"

# A cache older than this is `expired-cache` (its snapshot is still used).
FLEET_CACHE_STALE_S=86400

# The two halves of an unknown answer's basis. The first set says why the
# server gave nothing; the second says what the cache gave. No two outcomes
# share a token (contract, *Unknown control state*).
FLEET_SERVER_CAUSES="server-unconfigured server-unreachable server-refused session-unregistered malformed-answer"
FLEET_CACHE_CAUSES="expired-cache no-cache malformed-cache invalid-cache-path"

# The owner's OQ-1 local rule (2026-09-24): used only when there is no usable
# cache. Personal-domain sessions may not spawn fleet workers in these hours.
FLEET_LOCAL_TZ="America/Denver"
FLEET_LOCAL_DAYS="[1,2,3,4,5]"
FLEET_LOCAL_START="08:00"
FLEET_LOCAL_END="18:00"

# fleet_is_fleet_worker <subagent_type> -- status 0 for a fleet worker.
fleet_is_fleet_worker() {
  case " ${FLEET_WORKER_TYPES} " in *" ${1:-} "*) [ -n "${1:-}" ] ;; *) return 1 ;; esac
}

# fleet_control_url <origin> <claude_session_id>
# The REST read (contract, *Reading control state and the control cache*):
# GET <origin>/api/v1/fleet/sessions/<id>/control. The id must already be a
# valid id (fleet_valid_id), so it is a single safe path segment.
fleet_control_url() {
  fleet_valid_id "${2:-}" || return 1
  printf '%s/api/v1/fleet/sessions/%s/control\n' "$1" "$2"
}

# fleet_project_domain <project>
# The repo defaults the local rule uses: walt_ui work, custom blend, gen_saas
# personal. An unmapped or unresolved project counts as personal.
fleet_project_domain() {
  case "${1:-}" in
    walt_ui) printf 'work\n' ;;
    custom)  printf 'blend\n' ;;
    *)       printf 'personal\n' ;;
  esac
}

# fleet_local_rule_snapshot <project>
# The local rule written as a policy snapshot, so ONE evaluator
# (fleet_desired) serves the server's snapshot, a cached one, and the local
# rule. No override; metering on for personal in the owner's work hours; no
# holiday source (the owner overrides on a holiday).
fleet_local_rule_snapshot() {
  jq -n -c --arg d "$(fleet_project_domain "${1:-}")" --arg tz "${FLEET_LOCAL_TZ}" \
    --argjson days "${FLEET_LOCAL_DAYS}" --arg s "${FLEET_LOCAL_START}" --arg e "${FLEET_LOCAL_END}" \
    '{override: null, effective_domain: $d,
      metering: {enabled: true, timezone: $tz,
                 work_windows: [{days: $days, start: $s, end: $e}],
                 metered_domains: ["personal"], holidays: []}}'
}

# The jq definitions every shape check shares. Each `*_problem` def yields a
# problem string, or empty when the value is well formed. Shapes are CLOSED: a
# key the contract does not list is a problem, because a snapshot with an
# input this evaluator does not know would be recomputed wrongly and silently.
FLEET_SHAPE_JQ='
  def iso: type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\\.[0-9]{1,9})?Z$");
  def hhmm: type == "string" and test("^([01][0-9]|2[0-3]):[0-5][0-9]$");
  def domain: . == "work" or . == "blend" or . == "personal";
  def closed($k): (keys - $k) as $x | if ($x | length) > 0 then "unexpected key(s) \($x | join(", "))" else empty end;
  def needs($k): ($k - keys) as $m | if ($m | length) > 0 then "missing \($m | join(", "))" else empty end;
  def window_problem:
    if type != "object" then "a work window is not an object"
    else ( closed(["days","start","end"]) // needs(["days","start","end"])
      // (if (.days | type) != "array" or (.days | length) == 0 or any(.days[]; (type != "number") or . != floor or . < 1 or . > 7) or ((.days | unique | length) != (.days | length))
           then "work window days must be a non-empty list of distinct ISO weekdays 1..7" else empty end)
      // (if (.start | hhmm | not) or (.end | hhmm | not) then "work window start/end must be HH:MM" else empty end)
      // (if .start >= .end then "work window start \(.start) is not before end \(.end)" else empty end) )
    end;
  def metering_problem:
    if type != "object" then "metering is not an object"
    elif .enabled == false then closed(["enabled"])
    elif .enabled != true then "metering.enabled is not a boolean"
    else ( closed(["enabled","timezone","work_windows","metered_domains","holidays"])
      // needs(["enabled","timezone","work_windows","metered_domains","holidays"])
      // (if (.timezone | type) != "string" or (.timezone | test("^[A-Za-z][A-Za-z0-9_+-]*(/[A-Za-z0-9][A-Za-z0-9_+-]*)*$") | not) then "metering.timezone is not a zone name" else empty end)
      // (if (.work_windows | type) != "array" or (.work_windows | length) == 0 then "metering.work_windows must be a non-empty list" else empty end)
      // ([.work_windows[] | window_problem] | first)
      // (if (.metered_domains | type) != "array" or any(.metered_domains[]; domain | not) then "metering.metered_domains must list work/blend/personal" else empty end)
      // (if (.holidays | type) != "array" or any(.holidays[]; (type != "string") or (test("^[0-9]{4}-[0-9]{2}-[0-9]{2}$") | not)) then "metering.holidays must list YYYY-MM-DD dates" else empty end) )
    end;
  def snapshot_problem:
    if type != "object" then "policy_snapshot is not an object"
    else ( closed(["override","effective_domain","metering"]) // needs(["override","effective_domain","metering"])
      // (if .override == null then empty
          elif (.override | type) != "object" then "policy_snapshot.override is neither null nor an object"
          else (.override | (closed(["desired","expires_at"]) // needs(["desired","expires_at"])
                 // (if .desired != "run" and .desired != "drain" then "override.desired is not run or drain" else empty end)
                 // (if .expires_at != null and (.expires_at | iso | not) then "override.expires_at is not null or an ISO 8601 UTC time" else empty end)))
          end)
      // (if (.effective_domain | domain | not) then "policy_snapshot.effective_domain is not work, blend or personal" else empty end)
      // (.metering | metering_problem) )
    end;
  def answer_problem($sid):
    if type != "object" then "the answer is not a JSON object"
    else ( closed(["claude_session_id","desired","reason","until","policy_snapshot"])
      // needs(["claude_session_id","desired","reason","until","policy_snapshot"])
      // (if .claude_session_id != $sid then "the answer names session \(.claude_session_id | tojson), not \($sid | tojson)" else empty end)
      // (if .desired != "run" and .desired != "drain" then "desired \(.desired | tojson) is not run or drain" else empty end)
      // (if (.reason | type) != "string" or (.reason | test("^(default|override:force_drain|override:force_run|metering:(work|blend|personal))$") | not)
           then "reason \(.reason | tojson) is not one of the reason classes" else empty end)
      // (if ({"default":"run","override:force_drain":"drain","override:force_run":"run"}[.reason] // (if (.reason | startswith("metering:")) then "drain" else null end)) != .desired
           then "reason \(.reason) contradicts desired \(.desired)" else empty end)
      // (if .until != null and (.until | iso | not) then "until is not null or an ISO 8601 UTC time" else empty end)
      // (.policy_snapshot | snapshot_problem) )
    end;
'

# fleet_answer_problem <answer-json> <claude_session_id>
# Status 0 = a well-formed server answer for THIS session. Status 1 prints the
# first problem.
fleet_answer_problem() {
  local p
  p="$(printf '%s' "${1:-}" | jq -r --arg sid "${2:-}" "${FLEET_SHAPE_JQ} answer_problem(\$sid) // empty" 2>/dev/null)" \
    || { printf 'the answer is not valid JSON\n'; return 1; }
  [ -z "${p}" ] && return 0
  printf '%s\n' "${p}"; return 1
}

# fleet_cache_problem <cache-json> <claude_session_id>
# A cache is the answer plus `fetched_at` (contract). Same check, one key more.
fleet_cache_problem() {
  local p
  p="$(printf '%s' "${1:-}" | jq -r --arg sid "${2:-}" "${FLEET_SHAPE_JQ}
    if type != \"object\" then \"the cache is not a JSON object\"
    elif (.fetched_at | iso | not) then \"fetched_at is missing or not an ISO 8601 UTC time\"
    else (del(.fetched_at) | answer_problem(\$sid)) end // empty" 2>/dev/null)" \
    || { printf 'the cache is not valid JSON\n'; return 1; }
  [ -z "${p}" ] && return 0
  printf '%s\n' "${p}"; return 1
}

# fleet_iso_epoch <iso> -- epoch seconds of an ISO 8601 UTC time.
fleet_iso_epoch() { date -u -d "$1" +%s 2>/dev/null; }

# fleet_epoch_iso <epoch> -- the canonical ISO 8601 UTC form.
fleet_epoch_iso() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; }

# fleet_desired <snapshot-json> <now-epoch>
# Prints `<desired>\t<reason>\t<until-iso-or-empty>`. It mirrors the server's
# Athena.Fleet.ControlPolicy.desired/3 (contract, *Session control: desired
# state*): an unexpired override (a null expires_at never expires); then
# metering, only when enabled -- a session whose effective domain is metered
# drains while `now`, in the policy's zone, falls in a work window on a
# non-holiday (start inclusive, end exclusive), until that window's end; then
# run with reason `default`. The snapshot must already have passed
# snapshot_problem and its zone must exist.
fleet_desired() {
  local snap="$1" now="$2" ov_d ov_exp enabled dom tz day dow hm win until
  # US (0x1f), never a tab: tab is IFS whitespace, so an empty field would
  # collapse and shift every later one.
  IFS=$'\x1f' read -r ov_d ov_exp enabled dom tz < <(printf '%s' "${snap}" | jq -r '
    .effective_domain as $d
    | [ (.override.desired // ""), (.override.expires_at // ""), (.metering.enabled | tostring),
        (if .metering.enabled and ((.metering.metered_domains | index($d)) != null) then $d else "" end),
        (.metering.timezone // "") ] | join("\u001f")')
  if [ -n "${ov_d}" ]; then
    if [ -z "${ov_exp}" ] || [ "$(fleet_iso_epoch "${ov_exp}")" -gt "${now}" ]; then
      printf '%s\toverride:force_%s\t%s\n' "${ov_d}" "${ov_d}" "${ov_exp}"
      return 0
    fi
  fi
  if [ "${enabled}" = "true" ] && [ -n "${dom}" ]; then
    read -r day dow hm < <(TZ="${tz}" date -d "@${now}" '+%F %u %H:%M')
    if ! printf '%s' "${snap}" | jq -e --arg d "${day}" '.metering.holidays | index($d) != null' >/dev/null; then
      win="$(printf '%s' "${snap}" | jq -r --argjson dow "${dow}" --arg hm "${hm}" '
        [ .metering.work_windows[] | select((.days | index($dow)) != null and .start <= $hm and $hm < .end) ]
        | sort_by(.end) | last | if . == null then "" else .end end')"
      if [ -n "${win}" ]; then
        until="$(fleet_epoch_iso "$(TZ="${tz}" date -d "${day} ${win}" +%s)")"
        printf 'drain\tmetering:%s\t%s\n' "${dom}" "${until}"
        return 0
      fi
    fi
  fi
  printf 'run\tdefault\t\n'
}

# fleet_local_rule_blind <project>
# The local rule when the tz database lacks the owner's zone: the hours cannot
# be told, so the most restrictive reading holds -- a personal session drains
# (with no end it can compute), work and blend run.
fleet_local_rule_blind() {
  if [ "$(fleet_project_domain "${1:-}")" = "personal" ]; then
    printf 'drain\tmetering:personal\t\n'
  else
    printf 'run\tdefault\t\n'
  fi
}

# fleet_answer_decision <answer-or-cache-json>
# The server's own `desired`, `reason`, `until`, tab-separated.
fleet_answer_decision() {
  printf '%s' "$1" | jq -r '[.desired, .reason, (.until // "")] | join("\t")'
}

# fleet_basis <server|recomputed|local-rule> [server-cause] [cache-cause]
# `server`, `recomputed:<cause>[,expired-cache]`, `local-rule:<cause>,<cause>`.
fleet_basis() {
  case "$1" in
    server) printf 'server\n' ;;
    *) printf '%s:%s%s\n' "$1" "$2" "${3:+,$3}" ;;
  esac
}

# fleet_control_cause <curl-exit> <http-code> <body> <claude_session_id>
# One outcome word for a server read: `ok`, or the server half of a basis.
#   server-unreachable  no HTTP answer (connect failure, DNS, timeout)
#   session-unregistered 404 {"error":"not_found"}
#   server-refused      401, 403 or 422: the server refused the request
#   malformed-answer    anything else: a 200 that is not the answer shape, a
#                       5xx, a 404 with no JSON (no endpoint deployed), ...
fleet_control_cause() {
  local rc="$1" code="${2:-}" body="${3:-}" sid="${4:-}"
  if [ "${rc}" != "0" ] || [ -z "${code}" ] || [ "${code}" = "000" ]; then
    printf 'server-unreachable\n'; return 0
  fi
  case "${code}" in
    200) if fleet_answer_problem "${body}" "${sid}" >/dev/null; then printf 'ok\n'; else printf 'malformed-answer\n'; fi ;;
    404) if printf '%s' "${body}" | jq -e 'type == "object" and .error == "not_found"' >/dev/null 2>&1; then
           printf 'session-unregistered\n'; else printf 'malformed-answer\n'; fi ;;
    401|403|422) printf 'server-refused\n' ;;
    *) printf 'malformed-answer\n' ;;
  esac
}

# fleet_check_line <desired> <reason> <until-or-empty> <basis>
# fleet-control check's one stdout line: space-separated key=value pairs.
fleet_check_line() {
  printf 'desired=%s reason=%s until=%s basis=%s\n' "$1" "$2" "${3:-unbounded}" "$4"
}

# fleet_check_exit <desired> -- 0 for run, 3 for drain.
fleet_check_exit() {
  case "$1" in run) printf '0\n' ;; drain) printf '3\n' ;; *) printf '1\n' ;; esac
}

# fleet_drain_fix <claude_session_id> <reason> <until-or-empty> <basis>
# The drain guard's deny reason. Pinned VERBATIM in
# ai/contracts/fixtures/athena-events-quoted-fix.txt (section *Layer 1: the
# drain guard hook*); the hook suite asserts this renders that line.
fleet_drain_fix() {
  printf 'Fix: fleet session %s is draining (%s, until %s; basis %s) — this spawn was refused, not failed: do not retry it and do not do its work in-line; run the drain protocol, then wait for the session to return to run (override on the fleet page to force it).\n' \
    "$1" "$2" "${3:-unbounded}" "$4"
}

# fleet_unknown_warning <basis> <detail>
# The one stderr line every basis other than `server` prints. Never silent.
fleet_unknown_warning() {
  printf 'fleet-control: WARNING control state is unknown, so this answer is basis %s, not the server: %s. Fix: restore the server read (run ai/bin/fleet-control fetch to see its error); until then this answer is the owner'"'"'s fail-mode rule (athena-events.md -> Unknown control state), never a confirmed run.\n' "$1" "$2"
}
