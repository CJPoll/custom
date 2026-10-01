# shellcheck shell=bash
# scripts/lib/mcp-preflight.sh — the ONE MCP preflight for the cron loops that
# launch a headless Claude session with an --mcp-config (DND-1571).
#
# Claude Code keeps local-scope MCP servers in its config (~/.claude.json),
# under .projects[<launch dir>].mcpServers. The lead-time and clustering
# runners launch from a lane, not the main checkout, so they copy the servers
# registered for the MAIN checkout into the session's --mcp-config. A server
# that is not registered there is a tick that exits 78.
#
# Every caller sources this file and calls mcp_preflight, so the rules live
# once: the runner's preconditions, its --dry-run, and its installer's --check,
# --install and --dry-run. An installer that said OK while its runner's first
# tick failed this check is the defect this closes (a check that could not
# fire for the state it vouched for).
#
# mcp_preflight <claude_json> <main_checkout> <env_var> <purpose> <server>...
#   <claude_json>   the Claude Code config to read
#   <main_checkout> the key the servers are registered under (an absolute path)
#   <env_var>       the caller's override for <claude_json>, named in a Fix:
#   <purpose>       why the run needs the servers, one clause, for the message
#   <server>...     the servers that must be registered (at least one)
# Reads only; writes nothing, prints nothing. Sets:
#   MCP_PF_RESULT   ok | could-not-look | not-registered
#   MCP_PF_WHY      what failed, one line (empty on ok)
#   MCP_PF_FIX      what to do, one line (empty on ok)
#   MCP_PF_SERVERS  on ok: the JSON object of EVERY server registered for the
#                   key (the caller filters it); else empty
#   MCP_PF_MISSING  on not-registered: the required servers not found
# Returns 0 on ok, 1 otherwise.
#
# "could-not-look" (no jq, the config missing, unreadable or not valid JSON)
# and "not-registered" (the config was read; the servers are not under the
# key) are distinct results with distinct text: a config the preflight cannot
# read is never reported as a missing server, and never as an empty one.
# A key that matches no project is not-registered, and the message names the
# key it searched and how many projects do have servers, so a wrongly
# computed key is visible rather than silent.
#
# Safe under `set -euo pipefail`.

# mcp_register_cmd <server> — how to register one server, from the main
# checkout. An unknown server gets Claude Code's own command.
mcp_register_cmd() {
  case "$1" in
    notion-personal) printf '%s' "scripts/add-notion --personal" ;;
    athena)          printf '%s' "scripts/add-athena-mcp" ;;
    *)               printf '%s' "claude mcp add --scope local $1 <its command>" ;;
  esac
}

# mcp_register_clause <main_checkout> <server>... — "from <M>, run <cmd>
# (registers <s>) and <cmd> (registers <s>)": names each server and its command.
mcp_register_clause() {
  local m="$1" s parts=""; shift
  for s in "$@"; do
    [ -z "${parts}" ] || parts="${parts} and "
    parts="${parts}$(mcp_register_cmd "${s}") (registers ${s})"
  done
  printf 'from %s, run %s' "${m}" "${parts}"
}

mcp_preflight() {
  local cj="$1" m="$2" envvar="$3" purpose="$4"; shift 4
  local s n
  MCP_PF_RESULT="could-not-look"; MCP_PF_WHY=""; MCP_PF_FIX=""; MCP_PF_SERVERS=""; MCP_PF_MISSING=""
  if [ $# -eq 0 ] || [ -z "${cj}" ] || [ -z "${m}" ]; then
    MCP_PF_WHY="mcp_preflight was called without a config path, a main checkout or a required server"
    MCP_PF_FIX="this is a bug in the caller of scripts/lib/mcp-preflight.sh; pass all five arguments."
    return 1
  fi
  case "${m}" in
    /*) ;;
    *) MCP_PF_WHY="the main checkout '${m}' is not an absolute path, so it cannot be the key Claude Code registers servers under"
       MCP_PF_FIX="this is a bug in the caller of scripts/lib/mcp-preflight.sh; resolve the main checkout to an absolute path first."
       return 1 ;;
  esac
  if ! command -v jq >/dev/null 2>&1; then
    MCP_PF_WHY="jq is not on PATH, so the MCP servers in ${cj} cannot be read."
    MCP_PF_FIX="install jq."
    return 1
  fi
  if [ ! -f "${cj}" ] || [ ! -r "${cj}" ]; then
    MCP_PF_WHY="cannot read ${cj}, where Claude Code keeps the MCP servers registered for ${m}."
    MCP_PF_FIX="confirm Claude Code has run on this machine and ${cj} is readable, or set ${envvar}."
    return 1
  fi
  # A file jq cannot parse is its own fault, never "no servers registered".
  if ! jq empty "${cj}" >/dev/null 2>&1; then
    MCP_PF_WHY="${cj} is not valid JSON (corrupt, or read mid-write), so its MCP servers cannot be read."
    MCP_PF_FIX="run 'jq empty ${cj}' to see the parse error. If it was a mid-write read, the next tick succeeds; do NOT re-register the servers."
    return 1
  fi
  MCP_PF_RESULT="not-registered"
  MCP_PF_SERVERS="$(jq -c --arg p "${m}" '.projects[$p].mcpServers // empty | select(type == "object")' \
    "${cj}" 2>/dev/null || true)"
  if [ -z "${MCP_PF_SERVERS}" ]; then
    n="$(jq '[.projects[]? | select(.mcpServers? | type == "object" and length > 0)] | length' "${cj}" 2>/dev/null || echo '?')"
    MCP_PF_MISSING="$*"
    MCP_PF_WHY="no local-scope MCP servers are registered under the key '${m}' in ${cj} (${n} project(s) have any)."
    MCP_PF_FIX="$(mcp_register_clause "${m}" "$@"), then re-run this script by hand."
    return 1
  fi
  for s in "$@"; do
    jq -e --arg s "${s}" 'has($s)' <<<"${MCP_PF_SERVERS}" >/dev/null 2>&1 || MCP_PF_MISSING="${MCP_PF_MISSING:+${MCP_PF_MISSING} }${s}"
  done
  if [ -n "${MCP_PF_MISSING}" ]; then
    MCP_PF_WHY="the MCP server(s) ${MCP_PF_MISSING} are not registered for ${m} in ${cj}; ${purpose}."
    # shellcheck disable=SC2086 # one word per server name
    MCP_PF_FIX="$(mcp_register_clause "${m}" ${MCP_PF_MISSING})."
    MCP_PF_SERVERS=""
    return 1
  fi
  MCP_PF_RESULT="ok"
  return 0
}

# --- each loop's requirement, held once for its runner and its installer -----
# The runner filters its --mcp-config by the same list it checks, so the list
# a loop needs and the list its install check proves are one variable.
LEADTIME_MCP_REQUIRED="notion-personal"
CLUSTERING_MCP_REQUIRED="notion-personal athena"

# leadtime_mcp_preflight <claude_json> <main_checkout> — the lead-time
# improver's (scripts/athena-leadtime-run.sh, scripts/setup-leadtime-cron).
leadtime_mcp_preflight() {
  # shellcheck disable=SC2086 # one word per server name
  mcp_preflight "$1" "$2" LEADTIME_CLAUDE_JSON \
    "an architect the run spawns files DND tickets through notion-personal" ${LEADTIME_MCP_REQUIRED}
}

# clustering_mcp_preflight <claude_json> <main_checkout> — the epic-clustering
# pass's (scripts/athena-clustering-run.sh, scripts/setup-clustering-cron).
clustering_mcp_preflight() {
  # shellcheck disable=SC2086 # one word per server name
  mcp_preflight "$1" "$2" CLUSTERING_CLAUDE_JSON \
    "the pass needs Notion (notion-personal) and Slack (athena)" ${CLUSTERING_MCP_REQUIRED}
}
