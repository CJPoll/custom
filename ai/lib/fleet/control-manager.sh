#!/usr/bin/env bash
# control-manager.sh -- MANAGER for session control (DND-443). Orchestrates one
# control read: ask the server (effects), fall back to the cache, then to the
# owner's local rule (domain), and turn the result into one stdout line, one
# exit code, and -- for every basis other than `server` -- one stderr warning.
# It holds no rule of its own.
#
# Framework (bin/fleet-control) calls only this file and the domain files,
# never an effects file directly.
#
# Source order: domain.sh, control-domain.sh, the athena:inbox libs,
# effects.sh, control-effects.sh, then this file.

# fleet_control_ask <claude_session_id> <session-cwd> <harness-dir>
# One server read. Sets:
#   FC_CAUSE   `ok`, or the server half of a basis (control-domain.sh);
#   FC_DETAIL  what happened, in words, for the warning or the Fix: line;
#   FC_ANSWER  the compact answer JSON when FC_CAUSE is ok.
fleet_control_ask() {
  local sid="$1" cwd="$2" harness="$3" common session_main="" harness_main=""
  local mcp_url origin url token rc=0
  FC_CAUSE="server-unconfigured"; FC_DETAIL=""; FC_ANSWER=""

  if common="$(fs_git_common_dir "${cwd}")"; then session_main="$(fleet_main_checkout_of "${common}")"; fi
  if common="$(fs_git_common_dir "${harness}")"; then harness_main="$(fleet_main_checkout_of "${common}")"; fi
  mcp_url="$(fleet_mcp_url "${session_main}" "${harness_main}")" || rc=$?
  case "${rc}" in
    0) ;;
    1) FC_DETAIL="the server was not asked: no athena MCP server is registered in $(fleet_claude_json_path) (register it with scripts/add-athena-mcp)"; return 0 ;;
    2) FC_DETAIL="the server was not asked: an MCP lookup key was not an absolute path (internal error)"; return 0 ;;
    *) FC_DETAIL="the server was not asked: the athena MCP entry in $(fleet_claude_json_path) is unreadable or has no url"; return 0 ;;
  esac
  if ! origin="$(fleet_api_origin "${mcp_url}")"; then
    FC_DETAIL="the server was not asked: ${origin}"; return 0
  fi
  url="$(fleet_control_url "${origin}" "${sid}")" || { FC_DETAIL="the server was not asked: session id ${sid@Q} is not a valid id"; return 0; }

  rc=0
  token="$(fleet_read_token)" || rc=$?
  case "${rc}" in
    0) ;;
    1) FC_DETAIL="the server was not asked: no machine token config at $(fleet_client_config_path) (this machine has no Athena inbox client)"; return 0 ;;
    *) FC_DETAIL="the server was not asked: $(fleet_client_config_path) is unreadable or has no token"; return 0 ;;
  esac
  if ! FLEET_RESPONSE_MAX=65536 fleet_get "${url}" "${token}"; then
    token=""
    FC_DETAIL="the server was not asked: ${FLEET_POST_REASON}"; return 0
  fi
  token=""

  FC_CAUSE="$(fleet_control_cause "${FLEET_CURL_RC}" "${FLEET_HTTP_CODE}" "${FLEET_RESPONSE}" "${sid}")"
  case "${FC_CAUSE}" in
    ok) FC_ANSWER="$(printf '%s' "${FLEET_RESPONSE}" | jq -c .)" ;;
    server-unreachable) FC_DETAIL="no answer from ${url} (curl exit ${FLEET_CURL_RC}, HTTP ${FLEET_HTTP_CODE:-none})" ;;
    session-unregistered) FC_DETAIL="the server does not know session ${sid} from this machine (HTTP 404 not_found; report session_started from this machine first)" ;;
    server-refused) FC_DETAIL="the server refused the read (HTTP ${FLEET_HTTP_CODE}): $(fleet_refusal_fix "${FLEET_HTTP_CODE}" "${FLEET_RESPONSE}")" ;;
    *)
      if [ "${FLEET_HTTP_CODE}" = "200" ]; then
        FC_DETAIL="the server's answer is not the session_control shape: $(fleet_answer_problem "${FLEET_RESPONSE}" "${sid}")"
      else
        FC_DETAIL="the server answered HTTP ${FLEET_HTTP_CODE}, not a control answer (a 404 with no JSON means the endpoint is not deployed: DND-441)"
      fi ;;
  esac
  return 0
}

# fleet_control_store <claude_session_id> <answer-json> <now-epoch>
# Writes the cache (answer + fetched_at). Status 0 written; 2 invalid cache
# path; 1 the write failed. FC_CACHE_PATH names the path it used.
fleet_control_store() {
  local rc=0
  FC_CACHE_PATH="$(fleet_control_cache_path "$1")" || return 2
  fleet_write_cache "${FC_CACHE_PATH}" \
    "$(printf '%s' "$2" | jq -c --arg t "$(fleet_epoch_iso "$3")" '. + {fetched_at: $t}')" || rc=1
  return "${rc}"
}

# fleet_control_cached <claude_session_id> <now-epoch>
# Reads the cache. Sets FC_CACHE_CAUSE (empty = fresh and usable,
# `expired-cache` = usable but old, or a cause that makes it unusable),
# FC_CACHE_DETAIL, and FC_CACHE (the JSON, when usable).
fleet_control_cached() {
  local sid="$1" now="$2" path raw rc=0 problem tz age
  FC_CACHE_CAUSE=""; FC_CACHE_DETAIL=""; FC_CACHE=""
  if ! path="$(fleet_control_cache_path "${sid}")"; then
    FC_CACHE_CAUSE="invalid-cache-path"
    FC_CACHE_DETAIL="no cache was read: XDG_STATE_HOME (${XDG_STATE_HOME:-}) is not absolute"
    return 0
  fi
  raw="$(fleet_read_cache "${path}")" || rc=$?
  case "${rc}" in
    0) ;;
    1) FC_CACHE_CAUSE="no-cache"; FC_CACHE_DETAIL="there is no cache at ${path}"; return 0 ;;
    *) FC_CACHE_CAUSE="malformed-cache"; FC_CACHE_DETAIL="${path} is not a readable regular file of at most 64 KiB"; return 0 ;;
  esac
  if ! problem="$(fleet_cache_problem "${raw}" "${sid}")"; then
    FC_CACHE_CAUSE="malformed-cache"; FC_CACHE_DETAIL="${path} is malformed: ${problem}"; return 0
  fi
  tz="$(printf '%s' "${raw}" | jq -r '.policy_snapshot.metering.timezone // empty')"
  if [ -n "${tz}" ] && ! fleet_tz_known "${tz}"; then
    FC_CACHE_CAUSE="malformed-cache"; FC_CACHE_DETAIL="${path} names time zone ${tz@Q}, which this machine's tz database does not have"; return 0
  fi
  FC_CACHE="${raw}"
  age=$(( now - $(fleet_iso_epoch "$(printf '%s' "${raw}" | jq -r .fetched_at)") ))
  if [ "${age}" -lt 0 ]; then
    # A fetched_at in the future (the clock stepped back) has no measurable
    # age, so the cache is never trusted as fresh: it is read as expired.
    FC_CACHE_CAUSE="expired-cache"
    FC_CACHE_DETAIL="the cache at ${path} says it was fetched $(( -age / 60 )) min in the future (the clock moved back), so its age is unknown and it counts as expired; its snapshot is still used"
  elif [ "${age}" -gt "${FLEET_CACHE_STALE_S}" ]; then
    FC_CACHE_CAUSE="expired-cache"
    FC_CACHE_DETAIL="the cache at ${path} is $(( age / 3600 )) h old (stale after $(( FLEET_CACHE_STALE_S / 3600 )) h); its snapshot is still used"
  else
    FC_CACHE_DETAIL="recomputed from the cache at ${path}, fetched $(( age / 60 )) min ago"
  fi
  return 0
}

# fleet_control_local <session-cwd> <now-epoch>
# The owner's local rule for this session. Sets FC_LOCAL_DECISION
# (desired\treason\tuntil) and FC_LOCAL_DETAIL. Globals, not stdout: a
# command substitution would run it in a subshell and lose the detail.
fleet_control_local() {
  local cwd="$1" now="$2" resolved rc=0 project=""
  resolved="$(fleet_resolve_repo "${cwd}")" || rc=$?
  if [ "${rc}" -eq 0 ]; then
    project="${resolved%%$'\t'*}"
    FC_LOCAL_DETAIL="local rule for project ${project:-(none registered)}, domain $(fleet_project_domain "${project}")"
  else
    FC_LOCAL_DETAIL="local rule: the project of ${cwd@Q} could not be resolved (status ${rc}), so it counts as personal"
  fi
  if fleet_tz_known "${FLEET_LOCAL_TZ}"; then
    FC_LOCAL_DECISION="$(fleet_desired "$(fleet_local_rule_snapshot "${project}")" "${now}")"
  else
    FC_LOCAL_DETAIL="${FC_LOCAL_DETAIL}; the tz database has no ${FLEET_LOCAL_TZ}, so work hours cannot be told and a personal session drains at any hour"
    FC_LOCAL_DECISION="$(fleet_local_rule_blind "${project}")"
  fi
}

# fleet_control_check <claude_session_id> <session-cwd> <harness-dir> [now-epoch]
# (an empty now reads the clock)
# `fleet-control check`: prints one line and returns 0 (run) or 3 (drain).
fleet_control_check() {
  local sid="$1" cwd="$2" harness="$3" now="${4:-$(fleet_now)}" decision desired reason until basis detail rc
  fleet_control_ask "${sid}" "${cwd}" "${harness}"
  if [ "${FC_CAUSE}" = "ok" ]; then
    decision="$(fleet_answer_decision "${FC_ANSWER}")"
    IFS=$'\t' read -r desired reason until <<<"${decision}"
    rc=0
    fleet_control_store "${sid}" "${FC_ANSWER}" "${now}" || rc=$?
    case "${rc}" in
      0) ;;
      2) printf 'fleet-control: the server answer was used but not cached: XDG_STATE_HOME (%s) is not absolute. Fix: set XDG_STATE_HOME to an absolute path or unset it, or the next server outage falls back to the local rule.\n' "${XDG_STATE_HOME:-}" >&2 ;;
      *) printf 'fleet-control: the server answer was used but could not be written to %s. Fix: make that directory writable, or the next server outage falls back to the local rule.\n' "${FC_CACHE_PATH}" >&2 ;;
    esac
    fleet_check_line "${desired}" "${reason}" "${until}" server
    return "$(fleet_check_exit "${desired}")"
  fi

  fleet_control_cached "${sid}" "${now}"
  if [ -n "${FC_CACHE}" ]; then
    decision="$(fleet_desired "$(printf '%s' "${FC_CACHE}" | jq -c .policy_snapshot)" "${now}")"
    basis="$(fleet_basis recomputed "${FC_CAUSE}" "${FC_CACHE_CAUSE}")"
    detail="${FC_DETAIL}; ${FC_CACHE_DETAIL}"
  else
    fleet_control_local "${cwd}" "${now}"
    decision="${FC_LOCAL_DECISION}"
    basis="$(fleet_basis local-rule "${FC_CAUSE}" "${FC_CACHE_CAUSE}")"
    detail="${FC_DETAIL}; ${FC_CACHE_DETAIL}; ${FC_LOCAL_DETAIL}"
  fi
  IFS=$'\t' read -r desired reason until <<<"${decision}"
  fleet_unknown_warning "${basis}" "${detail}" >&2
  fleet_check_line "${desired}" "${reason}" "${until}" "${basis}"
  return "$(fleet_check_exit "${desired}")"
}

# fleet_control_fetch <claude_session_id> <session-cwd> <harness-dir> [now-epoch]
# (an empty now reads the clock)
# `fleet-control fetch`: the server read and the cache write, nothing else.
# Exit 0 cached; 1 local configuration or the cache could not be written;
# 3 refused or unregistered; 4 unreachable; 5 malformed answer.
fleet_control_fetch() {
  local sid="$1" cwd="$2" harness="$3" now="${4:-$(fleet_now)}" rc=0 desired reason until
  fleet_control_ask "${sid}" "${cwd}" "${harness}"
  case "${FC_CAUSE}" in
    ok) ;;
    server-unconfigured)
      printf 'fleet-control: fetch failed (%s): %s. Fix: configure this machine'"'"'s athena MCP entry and machine token (owner-issued; never mint one).\n' "${FC_CAUSE}" "${FC_DETAIL}" >&2; return 1 ;;
    server-refused|session-unregistered)
      printf 'fleet-control: fetch failed (%s): %s. Fix: act on the server'"'"'s answer above; nothing was cached.\n' "${FC_CAUSE}" "${FC_DETAIL}" >&2; return 3 ;;
    server-unreachable)
      printf 'fleet-control: fetch failed (%s): %s. Fix: check the network and that the server is up; the cache was left as it was.\n' "${FC_CAUSE}" "${FC_DETAIL}" >&2; return 4 ;;
    *)
      printf 'fleet-control: fetch failed (%s): %s. Fix: the server is not answering the contract shape (athena-events.md -> Reading control state and the control cache); check its deploy.\n' "${FC_CAUSE}" "${FC_DETAIL}" >&2; return 5 ;;
  esac
  fleet_control_store "${sid}" "${FC_ANSWER}" "${now}" || rc=$?
  case "${rc}" in
    0) IFS=$'\t' read -r desired reason until <<<"$(fleet_answer_decision "${FC_ANSWER}")"
       printf 'fleet-control: fetched and cached at %s: %s\n' "${FC_CACHE_PATH}" \
         "$(fleet_check_line "${desired}" "${reason}" "${until}" server)"; return 0 ;;
    2) printf 'fleet-control: fetch got an answer but did not cache it: XDG_STATE_HOME (%s) is not absolute. Fix: set it to an absolute path or unset it.\n' "${XDG_STATE_HOME:-}" >&2; return 1 ;;
    *) printf 'fleet-control: fetch got an answer but could not write %s. Fix: make that directory writable.\n' "${FC_CACHE_PATH}" >&2; return 1 ;;
  esac
}

# fleet_guard_record <claude_session_id> <subagent_type> <allow|deny> <basis-or-why>
# Appends the drain guard's decision to its log (best effort).
fleet_guard_record() {
  local why
  why="$(printf '%s' "$4" | tr '\t\n' '  ')"
  fleet_append_guard_log "$(printf '%s\t%s\t%s\t%s\t%s' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" "$2" "$3" "${why}")" 2>/dev/null
  return 0
}
