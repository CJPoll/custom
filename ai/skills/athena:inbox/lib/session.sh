#!/usr/bin/env bash
# session.sh -- SIDE EFFECT: it reads ambient process state (the environment,
# and the hook's stdin JSON when there is one). That is a small effect but it
# is still one, which is why this is not in the domain pile: the same inputs on
# two machines give two answers.
#
# ONE QUESTION: is this session a SUBAGENT?
#
# A subagent never advances a channel's consumption state. It would steal the
# offset from the session that is actually going to report to the owner: the
# subagent reads the mail, marks it consumed, finishes, and the main session
# then sees a clean inbox and reports nothing. Nobody is told, nothing is
# logged, and the message is simply gone -- the exact silent-loss shape the
# whole facility exists to eliminate.
#
# THE PREDICATE IS THE ONE IN ai/hooks/main-session-policy.sh, not a second
# mechanism. Same signals, same precedence, same fail-open direction:
#
#   * env CLAUDE_AGENT_ID / CLAUDE_AGENT_TYPE set non-empty, OR
#   * agent_id / agent_type / agentId / agentType present and non-empty/false
#     on the hook's stdin JSON;
#   * ANY positive signal -> subagent;
#   * no signal at all, or unparseable JSON -> MAIN (fail open).
#
# FAIL OPEN IS DELIBERATE and the contract says so explicitly: "the cost of a
# missed subagent is a rare contended ack; the cost of failing closed is a main
# session that can never consume anything." A reader that failed closed would
# be an inbox that silently never drains -- and that failure reads exactly like
# a quiet week.
#
# ONE DEVIATION FROM "VERBATIM", NAMED: the hook parses its stdin JSON with
# python3; this parses it with jq. The skill's existing dependency is jq
# (`bin/inbox-status` refuses without it) and adding a second interpreter to
# this dependency chain for one object lookup is not worth it. The SIGNALS and
# the FAIL-OPEN DIRECTION -- the two things that decide the answer -- are
# identical, and the suite asserts each of them independently rather than
# trusting the resemblance.
#
# Source order: err.sh, then this file. Requires jq only when given JSON.

# inbox_is_subagent [hook-stdin-json]
# Status 0 = subagent. Status 1 = main session (including "no signal at all").
inbox_is_subagent() {
  local input="${1:-}"

  if [ -n "${CLAUDE_AGENT_ID:-}" ] || [ -n "${CLAUDE_AGENT_TYPE:-}" ]; then
    return 0
  fi
  [ -n "${input}" ] || return 1

  # `jq -e` exits non-zero on false/null AND on a parse error, so an
  # unparseable document lands on "main" -- the fail-open direction -- without
  # a separate branch. The `false` guard mirrors the hook's `v not in (None,
  # "", False)`: a literal `false` is a signal that is not a signal.
  printf '%s' "${input}" | jq -e '
    if type != "object" then false
    else [ .agent_id, .agent_type, .agentId, .agentType ]
         | map(select(. != null and . != "" and . != false))
         | length > 0
    end' >/dev/null 2>&1
}
