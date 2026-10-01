#!/usr/bin/env bash
# lib/topic_route.sh -- the owner's Slack topic routes over the athena MCP
# tools slack_topic_route_list and slack_topic_route_put (DND-1538, the
# harness half of DND-1523). Sourced by bin/topic-route, never run.
#
# BUCKETS. Everything here is DOMAIN: pure string-in / string-out, tested
# directly by test/self-test.sh. The MCP call is athena:inbox lib/mcp.sh's
# `mcp_call_tool` (the machine token reaches curl only on stdin, DND-839), and
# bin/topic-route is the only caller of it.
#
# THE SERVER'S ANSWER, TWO SHAPES. A success is the reply map, as
# `structuredContent` or as the JSON text of the first content item. An error
# is Hermes' Error.execution, a JSON-RPC `error` whose message is the text; an
# `isError` tool result carrying the text is read the same way, so either
# server shape works. The texts are exactly `not found`, `refused: ... Fix: ...`
# or `invalid: ... Fix: ...`; anything else is an mcp-error, never a refusal.
#
# A FAILED LOOKUP NEVER LOOKS LIKE AN EMPTY ONE. A list reply that does not
# carry an app_id, a count, and that many well-formed routes is an mcp-error,
# never "count=0".

# The reason tokens. `mcp-error:<text>` is the one open-ended token.
TOPIC_ROUTE_REASONS="usage no-token mcp-unregistered mcp-error not-found refused invalid project-unresolved"

# topic_route_field <text> -- one key=value-safe field, by allowlist: every
# byte outside `A-Za-z0-9._:@/+-` becomes `_` (so whitespace, `=`, control
# characters and every non-ASCII byte, a C1 or bidi control included), at most
# 120 bytes, and an empty value is `none`. Server values are printed outside
# any fence, so they can never forge a second field or a second line.
topic_route_field() {
  local v
  v="$(printf '%s' "$1" | LC_ALL=C tr -c 'A-Za-z0-9._:@/+-' '_' | cut -c1-120)"
  printf '%s' "${v:-none}"
}

# topic_route_quoted <text> -- a display name as one double-quoted field
# (DND-1568). Names carry spaces ("Fake Desktop"), so the bare-field allowlist
# above would turn them into an underscore name that no tool resolves. Here
# printable ASCII is kept, `"` and `\` are backslash-escaped, every other byte
# becomes `_`, at most 120 bytes; empty is `none` (unquoted). Nothing inside
# the quotes can end them, forge a field, or start a line. It is a label for a
# human: the address another tool accepts is the machine id beside it.
topic_route_quoted() {
  local v
  v="$(printf '%s' "$1" | LC_ALL=C tr -c ' -~' '_' | cut -c1-120 | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')"
  if [ -z "${v}" ]; then printf 'none'; else printf '"%s"' "${v}"; fi
}

# topic_route_words <text> -- the server's words as one line of printable
# ASCII (every other byte becomes a space), at most 600 bytes: long enough to
# keep the server's own `Fix:` clause, which is the point of printing them.
topic_route_words() {
  printf '%s' "$1" | LC_ALL=C tr -c '[:print:]' ' ' | sed -e 's/^ *//' -e 's/ *$//' | cut -c1-600
}

# topic_route_put_args <label> <agent_instance_id> <true|false> <bot_id-or-empty>
# The slack_topic_route_put arguments. Never owner, owner_id, machine_id or
# slack_app_id: the server derives the owner from the machine token and
# refuses those.
topic_route_put_args() {
  jq -n -c --arg l "$1" --arg i "$2" --argjson e "$3" --arg b "$4" \
    '{label: $l, agent_instance_id: $i, enabled: $e} + (if $b == "" then {} else {bot_id: $b} end)'
}

# topic_route_list_args <bot_id-or-empty> -- the slack_topic_route_list arguments.
topic_route_list_args() {
  jq -n -c --arg b "$1" 'if $b == "" then {} else {bot_id: $b} end'
}

# _topic_route_error_text <json-rpc-message> -- the error text, or nothing.
_topic_route_error_text() {
  printf '%s' "$1" | jq -r '
      if (.result.isError // false) then
        ([.result.content[]? | .text? // empty] | join(" ") | if . == "" then "a tool error" else . end)
      elif .error then (.error.message // "an MCP error" | tostring)
      else empty end' 2>/dev/null
}

# topic_route_error <json-rpc-message>
# Status 0 and a reason token on stdout when the answer is NOT a success:
#   not-found | refused | invalid   -- the server's refusal, by kind
#   mcp-error:no-answer             -- no answer, or not JSON
#   mcp-error:server-error          -- any other error (a protocol error)
# The token is fixed text: the server's words are never part of it (they go
# on the server: line, topic_route_server_words), so they cannot forge a
# reason= or op= field. Status 1 and nothing printed when the answer carries
# no error (the render functions then judge its shape).
topic_route_error() {
  local msg="$1" err
  if [ -z "${msg}" ] || ! printf '%s' "${msg}" | jq -e 'type == "object"' >/dev/null 2>&1; then
    printf 'mcp-error:no-answer\n'; return 0
  fi
  err="$(_topic_route_error_text "${msg}")"
  [ -n "${err}" ] || return 1
  err="$(printf '%s' "${err}" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
  case "${err}" in
    "not found") printf 'not-found\n' ;;
    refused:*)   printf 'refused\n' ;;
    invalid:*)   printf 'invalid\n' ;;
    *)           printf 'mcp-error:server-error\n' ;;
  esac
  return 0
}

# topic_route_server_words <json-rpc-message> -- the server's error text as one
# bounded line, or nothing.
topic_route_server_words() {
  local err
  err="$(_topic_route_error_text "$1")"
  [ -n "${err}" ] || return 0
  topic_route_words "${err}"; printf '\n'
}

# _topic_route_reply <json-rpc-message> -- the success reply map, compact, or
# nothing.
_topic_route_reply() {
  printf '%s' "$1" | jq -c '
      (.result.structuredContent // (.result.content[0].text | fromjson? // null))
      | if type == "object" then . else empty end' 2>/dev/null
}

# topic_route_render_list <json-rpc-message>
# Status 0: one line per route, then `count=<n> app=<A...>`:
#   label=<l> inbox=<inbox|none> machine=<machine_id|none> name=<"real name"|none> enabled=<b> live=<b> instance=<id>
# machine= is the server's machine id and name= its display name, quoted
# (DND-1568): the id is what send-mail --to-project <project>@<machine>, --to
# <machine_id>/<inbox> and list_my_machines accept; the name is for reading.
# Status 1: `mcp-error:<what>` on stdout when the reply is not a well-formed
# list (no app_id, no count, a count that disagrees with the routes, or a
# route missing its label, enabled or live).
topic_route_render_list() {
  local reply rows app count
  reply="$(_topic_route_reply "$1")"
  [ -n "${reply}" ] || { printf 'mcp-error:no-list-in-reply\n'; return 1; }
  printf '%s' "${reply}" | jq -e '
      (.app_id | type) == "string" and (.app_id | length) > 0
      and (.count | type) == "number" and (.routes | type) == "array"
      and (.routes | length) == .count
      and all(.routes[]; type == "object" and (.label | type) == "string"
              and (.enabled | type) == "boolean" and (.live | type) == "boolean")' >/dev/null 2>&1 \
    || { printf 'mcp-error:malformed-list-reply\n'; return 1; }
  app="$(printf '%s' "${reply}" | jq -r '.app_id')"
  count="$(printf '%s' "${reply}" | jq -r '.count')"
  rows="$(printf '%s' "${reply}" | jq -r '.routes[]
      | [.label, (.inbox_name // ""), (.machine_id // "" | tostring), (.machine_name // ""), (.enabled | tostring), (.live | tostring),
         (.agent_instance_id // "" | tostring)] | @json')"
  local row label inbox machine_id machine_name enabled live instance
  while IFS= read -r row; do
    [ -n "${row}" ] || continue
    label="$(printf '%s' "${row}" | jq -r '.[0]')"
    inbox="$(printf '%s' "${row}" | jq -r '.[1]')"
    machine_id="$(printf '%s' "${row}" | jq -r '.[2]')"
    machine_name="$(printf '%s' "${row}" | jq -r '.[3]')"
    enabled="$(printf '%s' "${row}" | jq -r '.[4]')"
    live="$(printf '%s' "${row}" | jq -r '.[5]')"
    instance="$(printf '%s' "${row}" | jq -r '.[6]')"
    printf 'label=%s inbox=%s machine=%s name=%s enabled=%s live=%s instance=%s\n' \
      "$(topic_route_field "${label}")" "$(topic_route_field "${inbox}")" \
      "$(topic_route_field "${machine_id}")" "$(topic_route_quoted "${machine_name}")" "${enabled}" "${live}" "$(topic_route_field "${instance}")"
  done <<<"${rows}"
  printf 'count=%s app=%s\n' "${count}" "$(topic_route_field "${app}")"
}

# topic_route_render_put <json-rpc-message> <requested-label> <requested-enabled>
# Status 0: `put label=<l> inbox=<inbox|none> enabled=<b>`.
# Status 1: `mcp-error:<what>` when the reply is not `status: "put"` with a
# label and a boolean enabled, or when its label or enabled is not what was
# asked (mcp-error:put-reply-mismatch): the line printed is the one written.
topic_route_render_put() {
  local reply
  reply="$(_topic_route_reply "$1")"
  [ -n "${reply}" ] || { printf 'mcp-error:no-put-in-reply\n'; return 1; }
  printf '%s' "${reply}" | jq -e '.status == "put" and (.label | type) == "string"
      and (.enabled | type) == "boolean"' >/dev/null 2>&1 \
    || { printf 'mcp-error:malformed-put-reply\n'; return 1; }
  printf '%s' "${reply}" | jq -e --arg l "$2" --arg e "$3" \
      '.label == $l and (.enabled | tostring) == $e' >/dev/null 2>&1 \
    || { printf 'mcp-error:put-reply-mismatch\n'; return 1; }
  printf 'put label=%s inbox=%s enabled=%s\n' \
    "$(topic_route_field "$(printf '%s' "${reply}" | jq -r '.label')")" \
    "$(topic_route_field "$(printf '%s' "${reply}" | jq -r '.inbox_name // ""')")" \
    "$(printf '%s' "${reply}" | jq -r '.enabled')"
}

# topic_route_fix <reason-token> -- the Fix text for one failure reason. Every
# reason in TOPIC_ROUTE_REASONS has its own text.
topic_route_fix() {
  case "$1" in
    usage)
      printf 'run topic-route list [--bot-id B...] or topic-route put <label> <agent_instance_id> [--disabled] [--bot-id B...]; label and agent_instance_id are non-empty, and a bot id is B followed by capitals and digits. topic-route --help has the details.' ;;
    no-token)
      printf 'this machine has no usable machine token in the inbox client config (~/.config/athena-inbox-client/config.json, .token). That is an owner-provisioned credential: report it rather than creating or editing it.' ;;
    mcp-unregistered)
      printf 'the athena MCP server is not registered for this session'"'"'s project. Run scripts/add-athena-mcp from the main checkout of ~/dev/custom, or run topic-route from a project that has it.' ;;
    mcp-error*)
      printf 'the call did not complete, or answered something that is not a topic-route reply; the token after mcp-error: and the detail: or server: line above name the cause (not-sent: nothing reached the server; outcome-unknown: a put may have landed, so list before you retry). Check the MCP registration and reachability with athena:inbox bin/inbox-doctor, then re-run. A put is safe to repeat: it writes the same route again.' ;;
    not-found)
      printf 'the server found no Slack app of yours for that bot id (or you have none). Run topic-route list with no --bot-id, or check bin/whoami for the bot id.' ;;
    refused)
      printf 'the server refused the route; its own words and Fix are on the server: line above. The usual cause is an agent_instance_id that is not a <project>-slack.jsonl instance on your machines: pick one from the athena MCP list_my_machines.' ;;
    invalid)
      printf 'the server judged an argument invalid; its own words and Fix are on the server: line above. The label must be one the topic judgment routes (walt_ui, harness, gen_saas or other).' ;;
    project-unresolved)
      printf 'this session'"'"'s project could not be named, so its athena MCP registration could not be found: CLAUDE_PROJECT_DIR or CLAUDE_PID is set but unusable (the athena:inbox refusal above names the value). Fix or unset it and re-run.' ;;
    *)
      printf 'unrecognised topic-route failure reason "%s"; report it (topic_route.sh has no Fix for it).' "$(topic_route_words "$1" | cut -c1-80)" ;;
  esac
  printf '\n'
}
