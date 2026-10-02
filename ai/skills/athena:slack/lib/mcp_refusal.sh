#!/usr/bin/env bash
# lib/mcp_refusal.sh -- the one reader of the athena MCP server's refusal shape
# (DND-1661). Sourced by lib/claim.sh and lib/topic_route.sh, never run.
#
# BUCKET. Domain: pure string-in / string-out.
#
# THE SHAPE. The athena server sends a tool refusal as Hermes' Error.execution:
# a JSON-RPC `error` with code -32000 whose message is the text (DND-1645). An
# `isError` tool result carrying the text is read the same way, so either
# server shape works and the landing order of a server change does not matter.
# A JSON-RPC error with any other code (-32601 method not found, -32603
# internal error, ...) is a protocol fault, never a refusal: its message may
# read `refused: ...` and still be a fault, and a caller that took it for a
# refusal would print the refusal's Fix and send the agent away from the MCP
# path it should be diagnosing. Each caller keeps its own token mapping; only
# the shape is shared, so the two readers cannot drift apart again.

MCP_EXECUTION_ERROR_CODE=-32000

# mcp_refusal_text <json-rpc-message>
# The server's refusal text, or nothing when the answer carries no tool
# refusal. Nothing is also what a protocol error, a success and non-JSON give.
mcp_refusal_text() {
  printf '%s' "$1" | jq -r --argjson code "${MCP_EXECUTION_ERROR_CODE}" '
      if (.result.isError // false) then
        ([.result.content[]? | .text? // empty] | join(" ") | if . == "" then "a tool error" else . end)
      elif (.error | type) == "object" and .error.code == $code then (.error.message // "an MCP error" | tostring)
      else empty end' 2>/dev/null
}
