#!/usr/bin/env bash
# mcp.sh -- SIDE EFFECTS. The two outside-world touches of `send-mail --routed`:
# reading where the `athena` MCP server is registered, and calling one of its
# tools over Streamable HTTP.
#
# THE BEARER NEVER TOUCHES ARGV OR A FILE. It is `${ATHENA_MCP_BEARER}` -- the
# machine token the launcher (`scripts/athena`) exports for the session, and the
# same variable the registered MCP header expands (`scripts/add-athena-mcp`). It
# reaches curl only inside a config fed on curl's STDIN (`--config -`), so it is
# not in `ps` output and is written nowhere. Request and response BODIES do go to
# a private 0700 temp dir; they are message content, not credentials, and are
# removed on return.
#
# `lib/doctor.sh` has its own MCP client for `machine_reachable`. It is not
# reused here on purpose: it reads the token from the client config into a 0600
# file, and the routed send must use the launcher-scoped bearer and keep it out
# of every file. The protocol steps (initialize -> initialized -> tools/call, a
# body that may be plain JSON or an SSE stream) are the same.
#
# Source order: err.sh, then this file. Requires jq and curl.

MCP_PROTOCOL_VERSION="2025-03-26"

# mcp_registered_url <main-checkout-dir> <toplevel-dir>
#
# The URL of the `athena` MCP server Claude Code has registered for this
# project, from `$HOME/.claude.json`: local scope keyed by the main checkout
# (where `add-athena-mcp` is told to run), then by this worktree's toplevel,
# then user scope. Three failure statuses, never folded into one another:
#   1 -- the config file does not exist, or it names no `athena` server in any
#        of those scopes: genuinely not registered;
#   2 -- a lookup key is not an absolute path (computed wrongly; an internal
#        error, never "not registered");
#   3 -- the config exists but cannot be read or parsed, or its `athena` entry
#        has no usable `url`: a broken registration, whose repair is not
#        re-running add-athena-mcp over a file nobody has looked at.
mcp_registered_url() {
  local main="$1" top="$2" cfg="${HOME}/.claude.json" url
  case "${main}" in /*) ;; *) inbox_fail "internal: the main-checkout key for the MCP lookup is not absolute (\"${main}\")" \
    "report this; the key is computed from the git common dir and must be absolute."; return 2 ;; esac
  case "${top}" in /*) ;; *) inbox_fail "internal: the toplevel key for the MCP lookup is not absolute (\"${top}\")" \
    "report this; the key is computed from git rev-parse --show-toplevel and must be absolute."; return 2 ;; esac
  [ -e "${cfg}" ] || return 1
  local entry
  entry="$(jq -c --arg a "${main}" --arg b "${top}" '
      (.projects[$a]?.mcpServers?.athena? // .projects[$b]?.mcpServers?.athena? // .mcpServers?.athena? // null)' \
      "${cfg}" 2>/dev/null)" || return 3
  [ -n "${entry}" ] || return 3
  [ "${entry}" != "null" ] || return 1
  url="$(printf '%s' "${entry}" | jq -r 'if type == "object" and (.url | type) == "string" then .url else "" end' 2>/dev/null)"
  [ -n "${url}" ] || return 3
  printf '%s\n' "${url}"
}

# mcp_toplevel [cwd] -- the realpath of this checkout's toplevel.
mcp_toplevel() {
  local out
  out="$(cd "${1:-.}" 2>/dev/null && git rev-parse --show-toplevel 2>/dev/null)" || return 1
  [ -n "${out}" ] || return 1
  realpath -q "${out}" 2>/dev/null
}

# _mcp_post <workdir> <url> <session-id-or-empty> <json-body>
# One POST; writes <workdir>/hdr and <workdir>/body, prints the HTTP status.
_mcp_post() {
  local w="$1" url="$2" sid="$3" body="$4"
  printf '%s' "${body}" >"${w}/req.json" || return 1
  {
    printf 'url = "%s"\n' "${url}"
    printf 'request = "POST"\n'
    printf 'header = "Authorization: Bearer %s"\n' "${ATHENA_MCP_BEARER:-}"
    printf 'header = "Content-Type: application/json"\n'
    printf 'header = "Accept: application/json, text/event-stream"\n'
    [ -n "${sid}" ] && printf 'header = "mcp-session-id: %s"\n' "${sid}"
    printf 'data-binary = "@%s/req.json"\n' "${w}"
    printf 'dump-header = "%s/hdr"\n' "${w}"
    printf 'output = "%s/body"\n' "${w}"
    printf 'write-out = "%%{http_code}"\n'
    printf 'max-time = %s\n' "${ATHENA_MCP_HTTP_TIMEOUT:-30}"
    printf 'silent\n'
  } | curl --config - 2>/dev/null
}

# _mcp_json <file> -- the JSON-RPC message in a plain-JSON or SSE body.
_mcp_json() {
  if grep -q '^data:' "$1" 2>/dev/null; then
    grep '^data:' "$1" | tail -n 1 | sed 's/^data: \{0,1\}//'
  else
    cat "$1"
  fi
}

# mcp_call_tool <url> <tool> <arguments-json>
#
# Prints the tools/call JSON-RPC message on success (status 0). Failure
# statuses carry a one-line reason on stdout, and they are DIFFERENT because
# they mean different things to a sender:
#   3  -- refused BEFORE the tool call was sent (no curl, bad bearer shape,
#         endpoint unreachable, initialize refused): nothing was sent;
#   4  -- the tools/call itself failed in transport or answered non-2xx: the
#         outcome is UNKNOWN (the server may have recorded the message).
mcp_call_tool() {
  local url="$1" tool="$2" args="$3" w http sid req
  command -v curl >/dev/null 2>&1 || { printf 'curl is not on PATH\n'; return 3; }
  case "${url}" in
    *'"'*|*'\'*|*[[:space:]]*) printf 'the registered athena MCP URL contains a quote, backslash or whitespace\n'; return 3 ;;
    https://*) ;;
    *) printf 'the registered athena MCP URL is not https, and the machine token is not sent in clear text\n'; return 3 ;;
  esac
  # The bearer is written into a double-quoted curl config value: a quote,
  # backslash or whitespace in it would corrupt the header (or inject a config
  # line). Refused, never sent malformed; the value is never printed.
  case "${ATHENA_MCP_BEARER:-}" in
    *'"'*|*'\'*|*[[:space:]]*) printf 'ATHENA_MCP_BEARER contains a quote, backslash or whitespace and cannot be sent safely\n'; return 3 ;;
  esac

  w="$(mktemp -d 2>/dev/null)" || { printf 'could not create a private temp dir\n'; return 3; }
  chmod 700 "${w}"
  # shellcheck disable=SC2064
  trap "rm -rf '${w}'; trap - RETURN" RETURN

  http="$(_mcp_post "${w}" "${url}" "" "$(jq -n -c --arg v "${MCP_PROTOCOL_VERSION}" \
    '{jsonrpc:"2.0", id:1, method:"initialize", params:{protocolVersion:$v, capabilities:{}, clientInfo:{name:"athena-inbox-send-mail", version:"1"}}}')")" \
    || { printf 'the MCP endpoint %s could not be reached\n' "${url}"; return 3; }
  case "${http}" in
    2??) ;;
    401|403) printf 'the MCP endpoint refused the bearer (HTTP %s)\n' "${http}"; return 3 ;;
    *) printf 'the MCP initialize at %s answered HTTP %s\n' "${url}" "${http:-none}"; return 3 ;;
  esac
  sid="$(tr -d '\r' <"${w}/hdr" 2>/dev/null | awk 'tolower($1)=="mcp-session-id:"{print $2; exit}')"
  [ -n "${sid}" ] || { printf 'the MCP initialize returned no session id\n'; return 3; }
  # The session id goes into the curl config too; a server-sent value that is
  # not a plain token is refused rather than written into a config line.
  [[ "${sid}" =~ ^[A-Za-z0-9._:-]{1,256}$ ]] || { printf 'the MCP initialize returned a malformed session id\n'; return 3; }
  _mcp_post "${w}" "${url}" "${sid}" '{"jsonrpc":"2.0","method":"notifications/initialized","params":{}}' >/dev/null || true

  req="$(jq -n -c --arg t "${tool}" --argjson a "${args}" \
    '{jsonrpc:"2.0", id:2, method:"tools/call", params:{name:$t, arguments:$a}}')" \
    || { printf 'could not build the %s request\n' "${tool}"; return 3; }
  http="$(_mcp_post "${w}" "${url}" "${sid}" "${req}")" \
    || { printf 'the %s call to %s failed in transport\n' "${tool}" "${url}"; return 4; }
  case "${http}" in 2??) ;; *) printf 'the %s call answered HTTP %s\n' "${tool}" "${http:-none}"; return 4 ;; esac
  _mcp_json "${w}/body"
}
