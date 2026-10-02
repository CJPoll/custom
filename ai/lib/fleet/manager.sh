#!/usr/bin/env bash
# manager.sh -- MANAGER. Orchestrates one fleet report: resolve where to send
# it (effects), send it (effects), and turn the answer into one outcome and one
# line of output (domain). It holds no rule of its own.
#
# Output contract: success prints one line on STDOUT. Every failure prints ONE
# line on STDERR carrying `Fix:` and returns the outcome's exit code:
#   1 local configuration (no token, no athena MCP registration, bad state dir)
#   3 the server refused (its own Fix: is printed)
#   4 the server was unreachable
#   5 the server answered with a fault (5xx or not HTTP-shaped)
#
# Framework (bin/fleet-report, hooks/fleet-report.sh) calls only this file and
# domain.sh, never effects.sh directly.
#
# Source order: domain.sh, the athena:inbox libs, effects.sh, then this file.

fleet_say_fail() {
  # fleet_say_fail <kind> <what happened> <fix>
  printf 'fleet-report: %s %s. Fix: %s\n' "$1" "$2" "$3" >&2
}

# fleet_send <kind> <body-json> <session-cwd> <harness-dir>
fleet_send() {
  local kind="$1" body="$2" cwd="$3" harness="$4" common url_rc=0 mcp_url url token tok_rc=0
  local session_main="" harness_main="" outcome code fix

  if common="$(fs_git_common_dir "${cwd}")"; then session_main="$(fleet_main_checkout_of "${common}")"; fi
  if common="$(fs_git_common_dir "${harness}")"; then harness_main="$(fleet_main_checkout_of "${common}")"; fi

  mcp_url="$(fleet_mcp_url "${session_main}" "${harness_main}")" || url_rc=$?
  case "${url_rc}" in
    0) ;;
    1) fleet_say_fail "${kind}" "was not sent: no athena MCP server is registered in $(fleet_claude_json_path)" \
         "register it for this machine with scripts/add-athena-mcp (run in ~/dev/custom); fleet-report reads the server URL from that entry."; return 1 ;;
    2) fleet_say_fail "${kind}" "was not sent: an MCP lookup key was not an absolute path (internal error)" \
         "report this; the keys come from git rev-parse --git-common-dir and must be absolute."; return 1 ;;
    *) fleet_say_fail "${kind}" "was not sent: the athena MCP entry in $(fleet_claude_json_path) is unreadable or has no url" \
         "repair that entry (scripts/add-athena-mcp) after reading it; do not re-run blindly over a file nobody has looked at."; return 1 ;;
  esac

  if ! url="$(fleet_reports_url "${mcp_url}")"; then
    fleet_say_fail "${kind}" "was not sent: ${url}" "register the athena MCP server with its https URL (scripts/add-athena-mcp)."
    return 1
  fi

  token="$(fleet_read_token)" || tok_rc=$?
  case "${tok_rc}" in
    0) ;;
    1) fleet_say_fail "${kind}" "was not sent: no machine token config at $(fleet_client_config_path)" \
         "this machine has no Athena inbox client; set it up with scripts/setup-athena-inbox-client (the token is owner-issued; never mint one yourself)."; return 1 ;;
    *) fleet_say_fail "${kind}" "was not sent: $(fleet_client_config_path) is unreadable or has no token" \
         "repair the inbox client config (owner-gated credential); fleet-report only reads it."; return 1 ;;
  esac

  if ! fleet_post "${url}" "${token}" "${body}"; then
    token=""
    fleet_say_fail "${kind}" "was not sent: ${FLEET_POST_REASON}" "fix the named value; nothing left this machine."
    return 1
  fi
  token=""

  outcome="$(fleet_outcome "${FLEET_CURL_RC}" "${FLEET_HTTP_CODE}")"
  code="${FLEET_HTTP_CODE:-none}"
  case "${outcome}" in
    ok)
      printf 'fleet-report: %s ok (HTTP %s)\n' "${kind}" "${code}" ;;
    refused)
      fix="$(fleet_refusal_fix "${FLEET_HTTP_CODE}" "${FLEET_RESPONSE}")"
      fleet_say_fail "${kind}" "was refused by the server (HTTP ${code})" "${fix}" ;;
    unreachable)
      fleet_say_fail "${kind}" "could not reach ${url} (curl exit ${FLEET_CURL_RC})" \
        "check the network and that the server is up; nothing was recorded, and the next report retries on its own." ;;
    *)
      fleet_say_fail "${kind}" "got a server fault from ${url} (HTTP ${code})" \
        "the server failed, not the request; check its health. The report is an idempotent upsert and is safe to re-send." ;;
  esac
  return "$(fleet_exit_for "${outcome}")"
}

# fleet_session_started_body <session_id> <cwd>
# Prints the session_started body, resolving project and repo_key NOW. On a
# resolution failure prints one Fix: line on stderr and returns 1.
fleet_session_started_body() {
  local sid="$1" cwd="$2" resolved rc=0
  resolved="$(fleet_resolve_repo "${cwd}")" || rc=$?
  case "${rc}" in
    0) ;;
    2) fleet_say_fail session_started "was not sent: --cwd ${cwd@Q} is not an existing absolute directory" \
         "pass the session's absolute working directory."; return 1 ;;
    3) fleet_say_fail session_started "was not sent: git could not say whether ${cwd@Q} is in a repository (git missing, dubious ownership, or a corrupt .git)" \
         "run git -C ${cwd@Q} rev-parse --git-common-dir and fix what it reports; a repo git cannot read is never reported as 'not a repo'."; return 1 ;;
    4) fleet_say_fail session_started "was not sent: two inbox registry entries claim this repo" \
         "leave exactly one entry in \$ATHENA_INBOX_ROOT/projects/ whose repo is this repo's git common dir."; return 1 ;;
    *) fleet_say_fail session_started "was not sent: no registry entry names this repo and some registry file is unparseable, so project cannot be stated" \
         "run inbox-status (athena:inbox) to find the unparseable entry and repair it."; return 1 ;;
  esac
  fleet_body_session_started "${sid}" "${resolved%%$'\t'*}" "${resolved#*$'\t'}"
}

# fleet_load_missions <file>
# Prints the mission-pointer list as compact JSON. Status 1 + a reason on
# stdout when the file is unreadable, 2 + the schema problem when it is not a
# valid pointer list (nothing is sent in either case).
fleet_load_missions() {
  local raw problem
  raw="$(fleet_read_file "$1")" || { printf '%s is not a readable file\n' "${1@Q}"; return 1; }
  problem="$(fleet_missions_problem "${raw}")" || { printf '%s\n' "${problem}"; return 2; }
  jq -c . <<<"${raw}"
}

# fleet_record_mission_status <run_id> <missions-json>
# One local `mission.status` telemetry event per mission (DND-1476;
# ai/contracts/athena-telemetry.md), unit = its ticket_ref. The caller runs it
# on a list fleet_load_missions accepted, BEFORE the POST, so a network failure
# still leaves the local record. Fails open: it prints nothing on stdout and
# returns 0 whatever happens, so the report's exit code and output are what
# they were. Needs athena_telemetry_emit (ai/lib/telemetry-emit.sh); without
# it, nothing is written. A ticket_ref outside the contract's ref grammar gets
# no event: the writer would drop it as a unit and file the event under the
# caller's branch instead. Fields travel base64-framed, one mission per line,
# so a value's own newline or tab cannot split it, on any jq.
fleet_record_mission_status() {
  local run_id="$1" b_ref b_status b_cstate ref status cstate
  declare -F athena_telemetry_emit >/dev/null 2>&1 || return 0
  while read -r b_ref b_status b_cstate; do
    ref="$(base64 -d <<<"${b_ref}" 2>/dev/null)" || continue
    status="$(base64 -d <<<"${b_status}" 2>/dev/null)" || continue
    cstate="$(base64 -d <<<"${b_cstate}" 2>/dev/null)" || continue
    fleet_valid_ticket_ref "${ref}" || continue
    athena_telemetry_emit --event mission.status --unit "${ref}" --attr "status=${status}" --attr "captain_state=${cstate}" --attr "run_id=${run_id}"
  done < <(jq -r '.[] | [.ticket_ref, .status, .captain_state] | map(@base64) | join(" ")' <<<"$2" 2>/dev/null)
  return 0
}

# fleet_claim_seen <session_id> <agent_id-or-empty>
# Status 0 = a seen report is due and now claimed; 1 = not due; 2 = the stamp
# directory or the stamp itself cannot be written, which is LOGGED (a silent 2 would silence every seen
# report with no trace).
fleet_claim_seen() {
  local rc=0
  fleet_throttle_claim "$(fleet_throttle_key "$1" "$2")" "$(date +%s)" || rc=$?
  if [ "${rc}" -eq 2 ]; then
    fleet_record_failure "$1" seen "fleet-report hook: a throttle stamp in $(fleet_seen_dir 2>/dev/null || printf '(unresolvable)') could not be created or written, so no seen report was sent. Fix: make it writable, or set XDG_STATE_HOME to an absolute, writable path." 2>/dev/null
  fi
  return "${rc}"
}

# fleet_log_failure <session_id-or-empty> <kind> <message> -- one line in the
# durable failure log (status 2 when it cannot be written).
fleet_log_failure() {
  fleet_record_failure "$@"
}

# fleet_state_usable -- status 0 when the fleet state dir resolves (absolute).
fleet_state_usable() {
  fleet_state_dir >/dev/null
}

# fleet_announce_failures
# Prints ONE notice line for failures logged since the last announcement, then
# advances the marker. Prints nothing when there are none. The log is never
# truncated by this.
fleet_announce_failures() {
  local since lines n latest
  since="$(fleet_read_surfaced_marker)" || return 0
  lines="$(fleet_failures_since "${since}")"
  [ -n "${lines}" ] || return 0
  n="$(printf '%s\n' "${lines}" | grep -c .)"
  latest="$(printf '%s\n' "${lines}" | tail -n 1)"
  fleet_failure_notice "${n}" "${latest}" "$(fleet_failure_log_path)"
  fleet_write_surfaced_marker "${latest%%$'\t'*}"
}

# fleet_started_due <session_id>
# Status 0 = this session has no recorded session_started, so a self-heal send
# is due (DND-497). Status 1 = it has one; its stamp's mtime is refreshed, so
# an active session's stamp is never pruned as stale.
fleet_started_due() {
  fleet_started_recorded "$1" || return 0
  fleet_refresh_started "$1"
  return 1
}

# fleet_record_started <session_id>
# Called after a successful session_started send. A stamp that cannot be
# written is LOGGED: the session would re-send session_started on every due
# PostToolUse (a harmless idempotent refresh), and that must not go unseen.
fleet_record_started() {
  fleet_mark_started "$1" 2>/dev/null && return 0
  fleet_record_failure "$1" session_started "fleet-report hook: session_started was sent but its stamp in $(fleet_started_dir 2>/dev/null || printf '(unresolvable)') could not be written, so it will be re-sent on each due PostToolUse. Fix: make that directory writable, or set XDG_STATE_HOME to an absolute, writable path." 2>/dev/null
  return 2
}

# fleet_run_detached <session_id> <kind> <limit-s> <command...>
# The body of one background report, run by a hook that re-entered itself
# detached (setsid -f, stdin and stdout closed). Shared by fleet-report.sh,
# fleet-lifecycle.sh and fleet-drain-guard.sh. The command runs under
# timeout(1); its stderr goes to a private temp file (removed by the trap). On
# failure its first `Fix:` line -- fleet-report's own one-line refusal -- is
# appended to the failure log, so nothing a hook sends fails unseen.
# FLEET_HOOK_PIDFILE (tests only) collects the detached pids to wait on.
fleet_run_detached() {
  local sid="$1" kind="$2" limit="$3" tmp rc msg
  shift 3
  if tmp="$(mktemp 2>/dev/null)"; then
    # shellcheck disable=SC2064
    trap "rm -f -- '${tmp}'" EXIT
  else
    tmp="/dev/null"   # no message capture; never a trap that removes it
  fi
  trap 'exit 143' TERM INT HUP
  [ -n "${FLEET_HOOK_PIDFILE:-}" ] && printf '%s\n' "$$" >> "${FLEET_HOOK_PIDFILE}"
  timeout "${limit}" "$@" </dev/null >/dev/null 2>"${tmp}"
  rc=$?
  if [ "${rc}" -eq 0 ]; then
    # A successful session_started -- whether from the normal SessionStart
    # detach or a PostToolUse self-heal (DND-497) -- marks the session so
    # neither path resends it. A stamp that cannot be written is logged; the
    # worst case is a resend, never a lost report. What a resend does server-
    # side: the contract, "Who sends what" -> the self-heal bullet.
    [ "${kind}" = "session_started" ] && fleet_record_started "${sid}"
    return 0
  fi
  if [ "${rc}" -eq 124 ]; then
    msg="fleet-report: ${kind} did not finish within ${limit}s and was killed. Fix: check the network and the server; the next report retries on its own."
  else
    msg="$(grep -m 1 'Fix:' "${tmp}" 2>/dev/null)"
    [ -n "${msg}" ] || msg="fleet-report: ${kind} failed (exit ${rc}) with no message. Fix: run ai/bin/fleet-report by hand for this kind to see why."
  fi
  fleet_log_failure "${sid}" "${kind}" "${msg}"
}

# fleet_prune_stamps -- opportunistic housekeeping: a stamp silent for a day
# belongs to a dead session. That holds for the started-stamps too, because an
# active session refreshes its own (fleet_started_due).
fleet_prune_stamps() {
  fleet_delete_stale_stamps 1440
  fleet_delete_stale_started 1440
  return 0
}
