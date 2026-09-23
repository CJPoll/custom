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
# Source order: err.sh, names.sh (names_safe_curl_config_value), then this
# file. Requires jq and curl.

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

# _mcp_timeout -- ATHENA_MCP_HTTP_TIMEOUT when it is a plain 1-4 digit number,
# else 30. It is written into a curl config line, so anything else (a newline
# could add a `url = ...` line) is never passed through.
_mcp_timeout() {
  case "${ATHENA_MCP_HTTP_TIMEOUT:-}" in
    [1-9]|[1-9][0-9]|[1-9][0-9][0-9]|[1-9][0-9][0-9][0-9]) printf '%s\n' "${ATHENA_MCP_HTTP_TIMEOUT}" ;;
    *) printf '30\n' ;;
  esac
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
    printf 'max-time = %s\n' "$(_mcp_timeout)"
    printf 'silent\n'
  } | curl --config - 2>/dev/null
}

# _mcp_json <file> <id> -- the JSON-RPC response with that id, from a plain-JSON
# body or an SSE stream. An SSE event may carry several `data:` lines (joined
# by newlines, per the SSE spec), and the stream may carry notifications as
# well as the response, so the response is SELECTED by id, never taken as
# "the last line". Nothing selected -> empty output, which the caller reads as
# an answer that carried neither a result nor an error.
_mcp_json() {
  local f="$1" id="$2"
  if grep -q '^data:' "${f}" 2>/dev/null; then
    awk '/^data:/ { sub(/^data: ?/, ""); buf = (buf == "" ? $0 : buf "\n" $0); next }
         /^\r?$/  { if (buf != "") print buf; buf = ""; next }
         END      { if (buf != "") print buf }' "${f}"
  else
    cat "${f}"
  fi | jq -c --argjson id "${id}" 'select(type == "object" and .id == $id)' 2>/dev/null | tail -n 1
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
    https://*) names_safe_curl_config_value "${url}" || { printf 'the registered athena MCP URL contains a quote, backslash, whitespace or control character\n'; return 3; } ;;
    *) printf 'the registered athena MCP URL is not https, and the machine token is not sent in clear text\n'; return 3 ;;
  esac
  # The bearer is written into a double-quoted curl config value: a quote,
  # backslash or whitespace in it would corrupt the header (or inject a config
  # line). Refused, never sent malformed; the value is never printed.
  names_safe_curl_config_value "${ATHENA_MCP_BEARER:-}" || { printf 'ATHENA_MCP_BEARER contains a quote, backslash, whitespace or control character and cannot be sent safely\n'; return 3; }

  w="$(mktemp -d 2>/dev/null)" || { printf 'could not create a private temp dir\n'; return 3; }
  chmod 700 "${w}"
  # The temp dir's path goes into curl config lines too ($TMPDIR chooses it).
  names_safe_curl_config_value "${w}" || { rm -rf "${w}"; printf 'the temp dir path (from $TMPDIR) contains a quote, backslash, whitespace or control character\n'; return 3; }
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
  names_safe_curl_config_value "${sid}" 256 || { printf 'the MCP initialize returned a session id that cannot be sent back safely (a quote, backslash, whitespace or control character, or over 256 bytes)\n'; return 3; }
  _mcp_post "${w}" "${url}" "${sid}" '{"jsonrpc":"2.0","method":"notifications/initialized","params":{}}' >/dev/null || true

  req="$(jq -n -c --arg t "${tool}" --argjson a "${args}" \
    '{jsonrpc:"2.0", id:2, method:"tools/call", params:{name:$t, arguments:$a}}')" \
    || { printf 'could not build the %s request\n' "${tool}"; return 3; }
  http="$(_mcp_post "${w}" "${url}" "${sid}" "${req}")" \
    || { printf 'the %s call to %s failed in transport\n' "${tool}" "${url}"; return 4; }
  case "${http}" in 2??) ;; *) printf 'the %s call answered HTTP %s\n' "${tool}" "${http:-none}"; return 4 ;; esac
  _mcp_json "${w}/body" 2
}
