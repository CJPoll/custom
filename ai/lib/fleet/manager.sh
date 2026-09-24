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
