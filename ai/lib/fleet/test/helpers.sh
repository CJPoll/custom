#!/usr/bin/env bash
# helpers.sh -- shared fixture plumbing for the fleet-report suites
# (lib/fleet/test/self-test.sh and hooks/fleet-report.self-test.sh). Sourced,
# never run. Expects TMP (a private temp dir) and FAKE (the fake server path).
#
# fleet_fixture_env sets up an isolated world under $TMP: a fake machine-token
# config, a fake ~/.claude.json whose athena URL points at the loopback fake
# server, an empty inbox registry, and a private XDG_STATE_HOME. Nothing here
# reads or writes the real ~/.claude.json, the real token, or prod.

FLEET_TEST_TOKEN="fleet-test-token-$$-$RANDOM-a7f3c9"

fleet_fixture_env() {
  mkdir -p "${TMP}/cfg" "${TMP}/inbox/projects" "${TMP}/state"
  chmod 700 "${TMP}/inbox" "${TMP}/inbox/projects"
  printf '%s\n' "${FLEET_TEST_TOKEN}" > "${TMP}/token"
  jq -n --arg t "${FLEET_TEST_TOKEN}" '{server_url: "wss://example.invalid/machine/websocket", token: $t, inbox_root: "x", instances: {}}' > "${TMP}/cfg/config.json"
  chmod 600 "${TMP}/cfg/config.json"
  export ATHENA_INBOX_CLIENT_CONFIG="${TMP}/cfg/config.json"
  export FLEET_CLAUDE_JSON="${TMP}/claude.json"
  export ATHENA_INBOX_ROOT="${TMP}/inbox"
  export XDG_STATE_HOME="${TMP}/state"
  printf '[]\n' > "${TMP}/responses.json"
  : > "${TMP}/server.log"
}

# fleet_point_at <url> -- register <url> as the user-scope athena MCP server.
fleet_point_at() {
  jq -n --arg u "$1" '{mcpServers: {athena: {type: "http", url: $u}}}' > "${FLEET_CLAUDE_JSON}"
}

# fleet_respond <json> -- what the fake server answers next.
fleet_respond() { printf '%s\n' "$1" > "${TMP}/responses.json"; }

# fleet_start_server -- start the fake server; sets SERVER_PID and SERVER_PORT.
fleet_start_server() {
  local i
  python3 "${FAKE}" "${TMP}/port" "${TMP}/server.log" "${TMP}/responses.json" "${TMP}/token" &
  SERVER_PID=$!
  for i in $(seq 1 100); do
    [ -s "${TMP}/port" ] && break
    sleep 0.05
  done
  [ -s "${TMP}/port" ] || { echo "FAIL fake server did not start"; return 1; }
  SERVER_PORT="$(cat "${TMP}/port")"
  fleet_point_at "http://127.0.0.1:${SERVER_PORT}/mcp"
  fleet_respond '{"status":202,"body":{"ok":true}}'
}

# fleet_closed_port -- a loopback port with nothing listening on it.
fleet_closed_port() {
  python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()'
}

# fleet_log_count -- requests the fake server has logged so far.
fleet_log_count() { local c; c="$(grep -c . "${TMP}/server.log" 2>/dev/null)"; printf '%s\n' "${c:-0}"; }

# fleet_last_request -- the most recent logged request.
fleet_last_request() { tail -n 1 "${TMP}/server.log"; }

# fleet_wait_count <n> -- bounded poll until at least <n> requests are logged.
fleet_wait_count() {
  local want="$1" i
  for i in $(seq 1 200); do
    [ "$(fleet_log_count)" -ge "${want}" ] && return 0
    sleep 0.05
  done
  return 1
}

# fleet_wait_pids <pidfile> <n> -- wait until <n> detached reporters recorded
# their pids, then block on each until it exits (bounded).
fleet_wait_pids() {
  local f="$1" n="$2" i p c
  for i in $(seq 1 200); do
    c="$(grep -c . "${f}" 2>/dev/null)"
    [ "${c:-0}" -ge "${n}" ] && break
    sleep 0.05
  done
  while read -r p; do
    [ -n "${p}" ] && timeout 20 tail --pid="${p}" -f /dev/null
  done < "${f}"
}
