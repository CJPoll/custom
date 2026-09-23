#!/usr/bin/env bash
# routed.sh -- DOMAIN. Routed session messages (HG-17 / DND-312): the pure half
# of `send-mail --routed` and of reading a `session.message` line.
#
# Strings in, strings out. No file, no network, no git. The one effect is a
# refusal on stderr through err.sh, the same declared shape as every other
# domain file here, plus `routed_render_platform`'s use of fence_render, whose
# only impurity (the nonce) is declared in fence.sh.
#
# WHAT A ROUTED SEND IS. `send-mail --routed` hands a message to the `athena`
# MCP server's `session_send` tool (gen_saas HG-16). The server stamps `from`
# from the machine token, checks the recipient is one of the owner's own
# machines and a declared inbox on it, and delivers a `session.message` line
# into that inbox's `log` channel. It NEVER writes a local maildir: a routed
# send that fell back to one silently would deliver to a peer who may not read
# that channel, and say "sent". The fallback rule is HG-19's, and it is explicit.
#
# THE SENDER'S OWN INBOX (`from_inbox`) IS RESOLVED, NEVER TYPED. The server
# requires it (D39) so the recipient can reply: `from = {machine_id, inbox_name}`
# where `machine_id` comes from the token and `inbox_name` is this project's
# declared session inbox. It is taken from THIS project's registry entry (the
# one the session resolves by git common dir): the channel named `session`, a
# `log` channel with `producer: "platform"` whose path is
# `<project>-session.jsonl` (epic D41). A project that declares none is
# refused: a message nobody can answer is worse than one that was not sent.
#
# WHY `-session`, NOT `-mail` (D41). The first draft of the convention named the
# file `<project>-mail.jsonl`, and custom's entry already had a MAILDIR channel
# named `walt_ui-mail` (custom's outbound mail to walt_ui). walt_ui's routed
# inbox `walt_ui-mail.jsonl` would then have printed as "walt_ui-mail" too, for
# the opposite direction of a different transport.
#
# Source order: err.sh, names.sh, fence.sh, then this file. Requires jq.

# The session inbox's channel name and filename suffix, as the registry
# convention names them (`ai/contracts/athena-inbox.md` -> *Platform `log` line
# kinds* -> "Registry convention for a session inbox").
ROUTED_SESSION_CHANNEL="session"
ROUTED_SESSION_SUFFIX="-session.jsonl"

# The server's exact R9 refusal text (gen_saas
# `Athena.Events.FleetSessionMessage.re_or_thread_fix/0`), repeated here so the
# client refuses with the SAME words before it spends a network call.
ROUTED_RE_OR_THREAD_FIX="a session message must name what it is about — set re: <path|url> or thread: <event_id of the message you are answering>"

# Server-stamped identifiers printed OUTSIDE the untrusted fence must match
# this grammar (a UUID or similar opaque id). Anything else stays inside.
ROUTED_ID_RE='^[A-Za-z0-9][A-Za-z0-9-]{0,63}$'

# The server-stamped `sent_at` (ISO-8601 UTC, from DateTime.to_iso8601) must
# match this before it is printed outside the fence.
ROUTED_TS_RE='^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]{1,6})?(Z|[+-][0-9]{2}:[0-9]{2})$'

# routed_parse_to <machine_id>/<inbox_name>
# Prints "<machine_id>\t<inbox_name>". Refuses a spec that is not exactly one
# `/` between an id-shaped machine and a valid inbox filename. A machine NAME
# (which may carry a space) is not accepted here: the server's `to.machine_id`
# is an id. Resolve a name with --to-project <project>@<machine-name>.
routed_parse_to() {
  local spec="$1" machine inbox
  case "${spec}" in
    */*/*|"")
      inbox_fail "--to must be <machine_id>/<inbox_name>, with exactly one \"/\"" \
        "pass --to <machine_id>/<project>-session.jsonl (list_my_machines gives the ids), or use --to-project <project>[@<machine>]."
      return 1 ;;
    */*) ;;
    *)
      inbox_fail "--to must be <machine_id>/<inbox_name>; there is no \"/\" in it" \
        "pass --to <machine_id>/<project>-session.jsonl, or use --to-project <project>[@<machine>]."
      return 1 ;;
  esac
  machine="${spec%%/*}"; inbox="${spec#*/}"
  if ! [[ "${machine}" =~ ${ROUTED_ID_RE} ]]; then
    inbox_fail "the machine part of --to is not a machine id" \
      "pass the machine's id (from list_my_machines), not its name; to address by name use --to-project <project>@<machine-name>."
    return 1
  fi
  if ! names_valid_inbox_name "${inbox}"; then
    inbox_fail "the inbox part of --to is not an inbox filename" \
      "pass the recipient's declared session inbox, e.g. walt_ui-session.jsonl (a bare filename ending in .jsonl)."
    return 1
  fi
  # ONLY A SESSION INBOX. The server delivers to any instance the recipient
  # machine declares, and walt_ui-slack.jsonl is one: a session message routed
  # there would land in a Slack-producer channel whose reader cannot parse it.
  case "${inbox}" in
    *"${ROUTED_SESSION_SUFFIX}") ;;
    *)
      inbox_fail "the inbox part of --to is not a session inbox (it does not end in ${ROUTED_SESSION_SUFFIX})" \
        "address the recipient's session inbox, <project>${ROUTED_SESSION_SUFFIX} (e.g. walt_ui-session.jsonl). Other inboxes on that machine carry other producers' lines, and a session message delivered there would not be readable."
      return 1 ;;
  esac
  printf '%s\t%s\n' "${machine}" "${inbox}"
}

# routed_parse_to_project <project>[@<machine>]
# Prints "<project>\t<machine-selector-or-empty>".
routed_parse_to_project() {
  local spec="$1" project machine=""
  project="${spec%%@*}"
  case "${spec}" in *@*) machine="${spec#*@}" ;; esac
  if ! [[ "${project}" =~ ^[a-z0-9][a-z0-9_-]{0,63}$ ]]; then
    inbox_fail "--to-project names no valid project" \
      "pass --to-project <project>[@<machine>], where <project> is the stem of the recipient's <project>-session.jsonl (e.g. walt_ui)."
    return 1
  fi
  case "${spec}" in
    *@)
      inbox_fail "--to-project has an \"@\" with no machine after it" \
        "pass --to-project ${project}@<machine-id-or-name>, or drop the \"@\" to let the one machine declaring ${project}${ROUTED_SESSION_SUFFIX} be chosen."
      return 1 ;;
  esac
  case "${machine}" in
    *$'\t'*|*$'\n'*|*@*)
      inbox_fail "the machine after \"@\" in --to-project is malformed" \
        "pass --to-project ${project}@<machine-id-or-name> with a single \"@\"."
      return 1 ;;
  esac
  printf '%s\t%s\n' "${project}" "${machine}"
}

# routed_project_inbox <project> -> "<project>-session.jsonl"
routed_project_inbox() { printf '%s%s\n' "$1" "${ROUTED_SESSION_SUFFIX}"; }

# routed_require_subject <subject>
routed_require_subject() {
  [ -n "$1" ] && return 0
  inbox_fail "a routed session message requires a non-empty subject" \
    "pass --subject <a short line describing the message>. (The server refuses the same: \"a fleet.session.message requires a non-empty subject (string). Fix: set payload.subject to a short line describing the message.\")"
  return 1
}

# routed_require_referent <re> <thread>
# R9: at least one. Refused with the server's exact Fix text.
routed_require_referent() {
  if [ -n "$1" ] || [ -n "$2" ]; then return 0; fi
  inbox_fail "a routed session message names neither --re nor --thread" \
    "${ROUTED_RE_OR_THREAD_FIX}. (Pass --re <path|url> or --thread <event_id>.)"
  return 1
}

# routed_select_from_inbox <entry-json>
#
# THIS project's session inbox, from its own registry entry: the channel named
# `session`, which must be kind "log", producer "platform", with a bare path
# ending in "-session.jsonl". Each way it can be wrong is its own refusal,
# because each is a different repair -- and because a from_inbox computed
# wrongly must be stopped HERE, not sent for the server to refuse:
#   * no `session` channel          -> this project cannot be replied to;
#   * the wrong kind or producer    -> it is not a routed inbox (a maildir
#                                      named `session` is the D41 collision);
#   * a path that is not a bare `<stem>-session.jsonl` -> the server names
#     instances by bare filename, so it would never match;
#   * another platform log channel also ending in "-session.jsonl" -> which
#     one is this session's is not decidable.
routed_select_from_inbox() {
  local entry="$1" ch kind producer path others
  ch="$(printf '%s' "${entry}" | jq -c --arg n "${ROUTED_SESSION_CHANNEL}" '.channels[$n] // empty' 2>/dev/null)" || {
    inbox_fail "this project's registry entry could not be read for its session inbox" \
      "run inbox-status to see whether the entry parses; fix the JSON in the registry entry."
    return 1
  }
  if [ -z "${ch}" ]; then
    inbox_fail "this project declares no session inbox, so a routed message from it could not be answered (nothing was sent)" \
      "declare a channel named \"${ROUTED_SESSION_CHANNEL}\" -- {\"kind\": \"log\", \"producer\": \"platform\", \"path\": \"<project>${ROUTED_SESSION_SUFFIX}\"} -- in ai/inbox/registry.json, install it (scripts/setup-inbox-registry --install), and have its AgentInstance declared on the server (HG-18)."
    return 1
  fi
  kind="$(printf '%s' "${ch}" | jq -r '.kind // "" | tostring')"
  producer="$(printf '%s' "${ch}" | jq -r '.producer // "" | tostring')"
  path="$(printf '%s' "${ch}" | jq -r '.path // "" | tostring')"
  if [ "${kind}" != "log" ] || [ "${producer}" != "platform" ]; then
    inbox_fail "this project's \"${ROUTED_SESSION_CHANNEL}\" channel is not a routed session inbox (kind \"${kind}\", producer \"${producer:-slack}\")" \
      "a session inbox is {\"kind\": \"log\", \"producer\": \"platform\", \"path\": \"<project>${ROUTED_SESSION_SUFFIX}\"}. Rename any other channel that uses the name \"${ROUTED_SESSION_CHANNEL}\"."
    return 1
  fi
  case "${path}" in
    *"${ROUTED_SESSION_SUFFIX}") ;;
    *) path="" ;;
  esac
  if [ -z "${path}" ] || [ "${path}" = "${ROUTED_SESSION_SUFFIX}" ] || ! names_valid_inbox_name "${path}"; then
    inbox_fail "this project's session inbox path is not a bare <project>${ROUTED_SESSION_SUFFIX} filename, so it cannot be sent as from_inbox" \
      "set the \"${ROUTED_SESSION_CHANNEL}\" channel's \"path\" to a bare <project>${ROUTED_SESSION_SUFFIX} (no directory, no leading dot). The server names instances by bare filename."
    return 1
  fi
  others="$(printf '%s' "${entry}" | jq -r --arg n "${ROUTED_SESSION_CHANNEL}" --arg sfx "${ROUTED_SESSION_SUFFIX}" '
      [ .channels | to_entries[] | select(.key != $n)
        | select((.value.path // "") | type == "string" and endswith($sfx)) ] | length')"
  if [ "${others:-0}" -gt 0 ]; then
    inbox_fail "this project declares ${others} more channel(s) whose path ends in ${ROUTED_SESSION_SUFFIX} besides \"${ROUTED_SESSION_CHANNEL}\"; which is this session's inbox is not decidable" \
      "keep exactly one ${ROUTED_SESSION_SUFFIX} channel, named \"${ROUTED_SESSION_CHANNEL}\", in this project's registry entry."
    return 1
  fi
  printf '%s\n' "${path}"
}

# routed_maildir_name_refusal <entry-json> <name>
# Status 0 (and a refusal printed) when <name> is one of this project's MAILDIR
# channels -- a routed send pointed at a maildir channel by name. A maildir
# channel is reached with plain `send-mail <channel> ...`; routing through the
# MCP to it is not a thing, and guessing what was meant would send somewhere
# the sender did not name. Status 1 when <name> is not such a channel.
routed_maildir_name_refusal() {
  local entry="$1" name="$2"
  [ -n "${name}" ] || return 1
  [ "$(printf '%s' "${entry}" | jq -r --arg n "${name}" '(.channels[$n].kind // "") | tostring' 2>/dev/null)" = "maildir" ] || return 1
  inbox_fail "\"${name}\" is one of this project's MAILDIR channels; a routed send goes through the athena MCP to a peer's session inbox, never to a maildir channel (nothing was sent)" \
    "to use that maildir, drop --routed: send-mail ${name} <slug> --to <identity>. To route to the peer project instead, name its project: --to-project <project>[@<machine>] (its <project>${ROUTED_SESSION_SUFFIX})."
  return 0
}

# routed_pick_machine <machines-json> <inbox_name> <selector>
#
# From a list_my_machines answer (an array of {id, name, instances:[{inbox_name}]}),
# the id of the machine that hosts <inbox_name>. With a selector, only machines
# whose id or name equals it are candidates. Exactly one candidate that hosts
# the inbox is required; zero and several are refused, differently. The listed
# machines are all the CALLER'S OWN (the server scopes the list to the token's
# owner), so naming them in a refusal discloses nothing.
routed_pick_machine() {
  local machines="$1" inbox="$2" sel="${3:-}" hits n
  if ! printf '%s' "${machines}" | jq -e 'type == "array"' >/dev/null 2>&1; then
    inbox_fail "list_my_machines did not answer with a list of machines" \
      "retry; if it persists the server's answer shape changed -- check the athena MCP's list_my_machines."
    return 1
  fi
  hits="$(printf '%s' "${machines}" | jq -c --arg ib "${inbox}" --arg sel "${sel}" '
      [ .[] | select(type == "object")
        | select($sel == "" or ((.id // "") | tostring) == $sel or ((.name // "") | tostring) == $sel)
        | select([.instances[]? | objects | (.inbox_name // "")] | index($ib))
        | {id: (.id // "" | tostring), name: (.name // "" | tostring)} ]' 2>/dev/null)"
  n="$(printf '%s' "${hits}" | jq 'length' 2>/dev/null)"
  case "${n}" in
    ''|*[!0-9]*)
      inbox_fail "list_my_machines answered a machine list of an unexpected shape" \
        "retry; if it persists the server's answer shape changed -- check the athena MCP's list_my_machines, or address the recipient directly with --to <machine_id>/${inbox}."
      return 1 ;;
  esac
  if [ "${n}" -eq 1 ]; then
    printf '%s' "${hits}" | jq -r '.[0].id'
    return 0
  fi
  if [ "${n}" -eq 0 ]; then
    if [ -n "${sel}" ]; then
      inbox_fail "none of your machines matching \"${sel}\" declares ${inbox}" \
        "check the machine id or name with list_my_machines, and that the recipient project's session inbox is declared as an AgentInstance on that machine (HG-18)."
    else
      inbox_fail "none of your machines declares ${inbox}" \
        "the recipient project has no session inbox on any of your machines. Declare its AgentInstance on the server (HG-18) and its ${inbox} channel in the registry, then retry."
    fi
    return 1
  fi
  inbox_fail "${n} of your machines declare ${inbox} ($(printf '%s' "${hits}" | jq -r 'map("\(.name) [\(.id)]") | join(", ")')), so the recipient is ambiguous" \
    "name the machine: --to-project ${inbox%"${ROUTED_SESSION_SUFFIX}"}@<machine-id-or-name>."
  return 1
}

# routed_session_args <to_machine> <to_inbox> <from_inbox> <subject> <re> <thread>
# The session_send tool arguments as one JSON object; the BODY IS ON STDIN.
# `from_inbox` is a TOP-LEVEL argument of the tool (and a top-level field of the
# harness-emit request it becomes), never a payload field -- the server's
# payload schema is closed and refuses it there. An empty `re`/`thread` is
# omitted, not sent as "".
routed_session_args() {
  jq -n -c --rawfile body /dev/stdin \
    --arg tm "$1" --arg ti "$2" --arg fi "$3" --arg s "$4" --arg re "$5" --arg th "$6" '
    {to: {machine_id: $tm, inbox_name: $ti}, from_inbox: $fi, subject: $s, body: $body}
    + (if $re == "" then {} else {re: $re} end)
    + (if $th == "" then {} else {thread: $th} end)'
}

# The JSON-RPC error codes that mean the server REFUSED the call before doing
# anything: -32601 (no such method/tool), -32602 (the arguments failed the
# tool's input schema), -32000 (`Hermes.MCP.Error.execution`, which is how
# gen_saas `Athena.MCP.Tools.SessionSend` returns every refusal it has --
# derived identity, payload validation, not found, and `route_failed`, which the
# server itself words "nothing was sent"). Every other error, above all -32603
# (internal error: a crash that may have come after the event was written), is
# an UNKNOWN outcome.
ROUTED_REFUSAL_CODES="-32601 -32602 -32000"

# routed_tool_result <json-rpc-message>
# The tool's result object on stdout, status 0. Otherwise the SERVER'S OWN
# WORDS go to stdout (they are its Fix, not message content) and the status
# says what they mean:
#   2 -- a refusal: an `isError` tool result, or a JSON-RPC error whose code is
#        in ROUTED_REFUSAL_CODES. Nothing was done.
#   5 -- any other JSON-RPC error: the outcome is UNKNOWN.
#   1 -- the answer carried neither a result nor an error.
routed_tool_result() {
  local msg="$1" err code res
  err="$(printf '%s' "${msg}" | jq -r '
      if (.result.isError // false) then ([.result.content[]? | .text? // empty] | join(" ") | if . == "" then "a tool error" else . end)
      else empty end' 2>/dev/null)"
  if [ -n "${err}" ]; then printf '%s\n' "${err}"; return 2; fi
  err="$(printf '%s' "${msg}" | jq -r 'if .error then (.error.message // "an MCP error" | tostring) else empty end' 2>/dev/null)"
  if [ -n "${err}" ]; then
    code="$(printf '%s' "${msg}" | jq -r '.error.code // "" | tostring' 2>/dev/null)"
    printf '%s\n' "${err}"
    case " ${ROUTED_REFUSAL_CODES} " in
      *" ${code} "*) [ -n "${code}" ] && return 2 ;;
    esac
    return 5
  fi
  res="$(printf '%s' "${msg}" | jq -c '(.result.structuredContent // (.result.content[0].text | fromjson))' 2>/dev/null)"
  [ -n "${res}" ] && [ "${res}" != "null" ] || return 1
  printf '%s\n' "${res}"
}

# routed_send_receipt <result-json> <to_machine> <to_inbox> <from_inbox>
# What send-mail --routed prints: {path, event_id, delivery_id, status, to,
# from_inbox}. A result with no event_id is not a receipt (status 1).
routed_send_receipt() {
  local res="$1"
  printf '%s' "${res}" | jq -e '(.event_id // "") | type == "string" and length > 0' >/dev/null 2>&1 || return 1
  printf '%s' "${res}" | jq -c --arg tm "$2" --arg ti "$3" --arg fi "$4" \
    '{path: "routed", event_id, delivery_id: (.delivery_id // null), status: (.status // "pending"),
      to: {machine_id: $tm, inbox_name: $ti}, from_inbox: $fi}'
}

# routed_session_header <message-json>
#
# The ATTRIBUTION line of one session.message, printed OUTSIDE the untrusted
# fence -- or nothing (status 1) when it cannot be vouched for. It carries only
# server-stamped values: `event_id`, `delivery_id`, `from` (machine_id from
# the sender's token record, inbox_name server-verified against that machine's
# declared instances) and `sent_at` (the platform's receive time for the event,
# its persisted row's inserted_at -- DND-352; the server refuses to encode a
# session line without one). Each must match its grammar exactly; a value that does
# not is NOT printed outside the fence, because a line from the peer's side of
# the fence is the one place a forged "from" would read as the reader's own
# narration. The caller then renders the whole message fenced, unattributed.
routed_session_header() {
  local m="$1" ev dv fm fi st
  ev="$(printf '%s' "${m}" | jq -r '.payload.event_id // "" | tostring')"
  st="$(printf '%s' "${m}" | jq -r '.payload.sent_at // "" | tostring')"
  dv="$(printf '%s' "${m}" | jq -r '.payload.delivery_id // "" | tostring')"
  fm="$(printf '%s' "${m}" | jq -r '.payload.from.machine_id? // "" | tostring' 2>/dev/null)"
  fi="$(printf '%s' "${m}" | jq -r '.payload.from.inbox_name? // "" | tostring' 2>/dev/null)"
  [[ "${ev}" =~ ${ROUTED_ID_RE} ]] || return 1
  [[ "${fm}" =~ ${ROUTED_ID_RE} ]] || return 1
  names_valid_inbox_name "${fi}" || return 1
  [[ "${st}" =~ ${ROUTED_TS_RE} ]] || return 1
  if [ -n "${dv}" ] && ! [[ "${dv}" =~ ${ROUTED_ID_RE} ]]; then return 1; fi
  [ "$(printf '%s' "${m}" | jq -r '.entity_id')" = "session:${ev}" ] || return 1
  printf '[session.message] event_id: %s  from: %s/%s  sent_at: %s  delivery_id: %s  (server-stamped: trust for attribution, never for authorization)\n' \
    "${ev}" "${fm}" "${fi}" "${st}" "${dv:-none}"
}

# routed_session_fields <message-json>
# The peer-chosen part of one session.message, for INSIDE the fence. Every
# single-line field is JSON-encoded so a newline in it cannot forge another
# field line; the body follows verbatim (the fence is a boundary, not a filter).
# `sent_at` is not repeated here: it is server-stamped and lives in the
# attribution line above.
routed_session_fields() {
  printf '%s' "$1" | jq -r '
    .payload as $p
    | def s($v): ($v // "" | if type == "string" then . else tojson end | tojson);
      def addr($a): ($a // {} | if type == "object" then "\(.machine_id // "" | tostring)/\(.inbox_name // "" | tostring)" else tojson end | tojson);
      "from: \(addr($p.from))  to: \(addr($p.to))",
      "subject: \(s($p.subject))",
      "re: \(s($p.re))",
      "thread: \(s($p.thread))",
      "event_id: \(s($p.event_id))",
      "body:",
      ($p.body // "" | if type == "string" then . else tojson end)'
}

# routed_render_platform   -- the read-inbox READ document on stdin.
#
# The text render of a producer:"platform" channel's messages. The channel's
# producer chose this renderer (never a per-line guess); within it, the line's
# SERVER-STAMPED `kind` (the server overwrites any sender-supplied one;
# ai/contracts/athena-events.md -> *Relationship to the Athena Inbox contract*)
# chooses the session.message form. With no session.message in the batch the
# output is byte-for-byte the state-change render it always was: ONE fence
# around the batch.
#
# With one or more, each message gets its own fence (fresh nonce each), in file
# order, because a session message's attribution line has to sit OUTSIDE a
# fence and between two of them. Status non-zero, with nothing trusted emitted,
# if any fence cannot be rendered.
routed_render_platform() {
  local doc m header out any
  doc="$(cat)"
  any="$(printf '%s' "${doc}" | jq -r '[.messages[]? | select((.payload.kind // "") == "session.message")] | length')" || return 1
  if [ "${any:-0}" -eq 0 ]; then
    out="$(printf '%s' "${doc}" | jq -r '
        .messages[]
        | "[state-change] \(.entity_id)\n\(.payload // {} | tojson)\n"')" || return 1
    [ -n "${out}" ] || return 1
    printf '%s' "${out}" | fence_render || return 1
    return 0
  fi
  while IFS= read -r m; do
    [ -n "${m}" ] || continue
    if [ "$(printf '%s' "${m}" | jq -r '.payload.kind // ""')" = "session.message" ]; then
      if header="$(routed_session_header "${m}")"; then
        printf '%s\n' "${header}"
      else
        printf '[session.message] UNATTRIBUTED: its event_id/from/delivery_id do not match the server-stamped grammar, so nothing in it is vouched for -- report it as an anomaly.\n'
      fi
      out="$(routed_session_fields "${m}")" || return 1
    else
      printf '[state-change] (not a session message)\n'
      out="$(printf '%s' "${m}" | jq -r '"\(.entity_id)\n\(.payload // {} | tojson)"')" || return 1
    fi
    [ -n "${out}" ] || return 1
    printf '%s\n' "${out}" | fence_render || return 1
  done < <(printf '%s' "${doc}" | jq -c '.messages[]')
  return 0
}
