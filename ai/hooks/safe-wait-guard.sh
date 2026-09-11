#!/bin/sh
# PreToolUse safe-wait guard.
#
# Blocks a Bash tool call whose command contains a dangerous shell wait
# construct, and tells the agent the safe alternative. This machine-enforces the
# "NEVER write a shell wait-loop that spins" Hard Rule in
# ~/dev/custom/ai/CLAUDE.md, whose motivating incident is flaky ticket PT-919:
# an orphaned `(while :; do :; done) &` reparented to PID 1, pinned load ~290
# for an hour, and flaked neighboring ExUnit suites into Postgres 57014 timeouts.
#
# What it blocks (see the messages below for the exact fixes):
#   1. Busy-spin loop      — a while/until loop with NO `sleep` in it (and not a
#                            `read`-driven stream loop).
#   2. Unreaped bg loop    — a while/until/for loop that is backgrounded
#                            (`done &`, `( … ) &`, `{ …; } &`) with no
#                            trap/kill/pkill reaper.
#   4. pgrep -f self-match — a `pgrep -f "<pattern>"` inside a while/until wait
#                            with no `grep -v $$` self-exclusion (it matches the
#                            waiting shell's own argv, so it never exits).
# (Rule #3, the foreground-`sleep`-returns-immediately gotcha, is surfaced inside
#  the messages above rather than as a standalone block, because every sanctioned
#  poll uses a foreground `sleep` — blocking on it would nuke the good pattern.)
#
# Design guarantees:
#   * FAIL-OPEN — any error (missing jq, unparseable input, missing field, non-
#     Bash tool) exits 0 and ALLOWS the tool. A bug here can never wedge Bash.
#   * NARROW    — only Bash is inspected; the required must-not-block patterns
#     (a loop that sleeps, a trap-reaped background loop, `while read … done <
#     file`, ordinary commands) all pass. False positives are costly: this gates
#     every Bash call.
#
# Wired in ~/.claude/settings.json as a PreToolUse hook scoped to Bash.

INPUT=$(cat 2>/dev/null) || exit 0
[ -n "$INPUT" ] || exit 0

# Only inspect Bash; fail-open on any jq trouble.
TOOL=$(printf '%s' "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null) || exit 0
[ "$TOOL" = "Bash" ] || exit 0

CMD=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null) || exit 0
[ -n "$CMD" ] || exit 0

# Flatten to a single logical line so line-oriented grep can see constructs that
# the author split across newlines/tabs (e.g. `done` and `&` on separate lines).
FLAT=$(printf '%s' "$CMD" | tr '\n\t' '  ')

# has_word <extended-regex-token> : token present as a shell word in FLAT.
has_word() {
  printf '%s' "$FLAT" | grep -Eq "(^|[^[:alnum:]_])($1)([^[:alnum:]_]|\$)"
}

# has <extended-regex> : arbitrary ERE present in FLAT.
has() {
  printf '%s' "$FLAT" | grep -Eq "$1"
}

# deny <reason> : emit the PreToolUse deny decision and exit (fail-open if jq
# cannot encode, which would simply allow — consistent with the guarantee).
deny() {
  jq -cn --arg r "$1" \
    '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}' \
    2>/dev/null
  exit 0
}

# A real loop needs both `do` and `done` (word `do` does not match inside "done").
HAS_DO_DONE=false
if has_word 'do' && has_word 'done'; then HAS_DO_DONE=true; fi

# while/until present, and for-loops (for shape 2).
HAS_WHILE_UNTIL=false
if has_word 'while' || has_word 'until'; then HAS_WHILE_UNTIL=true; fi
HAS_LOOP_KW=false
if [ "$HAS_WHILE_UNTIL" = true ] || has_word 'for'; then HAS_LOOP_KW=true; fi

# ---- Shape 4: pgrep -f self-match inside a while/until wait ----------------
# pgrep -f (or -lf, -af, …) in a while/until loop with no `$$` self-exclusion.
if [ "$HAS_WHILE_UNTIL" = true ] \
  && has 'pgrep[[:space:]]+-[[:alnum:]]*f' \
  && ! has '\$\$'; then
  deny 'SAFE-WAIT (pgrep -f self-match): `pgrep -f "<pattern>"` inside a wait loop matches the waiting shell'"'"'s own argv, so the loop never exits. Exclude the waiter: `pgrep -f "<pattern>" | grep -v $$`, or block on the known PID instead: `timeout N tail --pid=<pid> -f /dev/null`. (A foreground `sleep` used to pace a poll can also return immediately in this harness — prefer blocking on the child or a harness wakeup.)'
fi

# ---- Shape 1: busy-spin loop (while/until with no sleep) -------------------
# A loop that sleeps each iteration is NOT a spin; a `read`-driven loop consumes
# a stream (e.g. `while read … done < file`) and is not a wait — allow both.
if [ "$HAS_WHILE_UNTIL" = true ] && [ "$HAS_DO_DONE" = true ] \
  && ! has_word 'sleep' \
  && ! has_word 'read'; then
  deny 'SAFE-WAIT (busy-spin loop): this while/until loop has no `sleep` in its body — it pins the CPU (PT-919: an orphaned spin loop pinned load ~290 and flaked ExUnit into Postgres 57014 timeouts). Prefer letting the harness wake you (task-notification / SendMessage / Monitor), or block on the child with `timeout N tail --pid=<pid> -f /dev/null`. If it must be a poll, add a `sleep N` per iteration (cadence matched to the state) plus a max-iteration/`timeout` bound.'
fi

# ---- Shape 2: unreaped backgrounded loop ----------------------------------
# The loop is backgrounded (`done &`, `( … ) &`, `{ …; } &` — not `&&`) and no
# trap/kill/pkill reaper is installed, so a crashed parent orphans it to PID 1.
if [ "$HAS_LOOP_KW" = true ] && [ "$HAS_DO_DONE" = true ] \
  && has 'done[[:space:];)}]*&([^&]|$)' \
  && ! has_word 'p?kill|trap'; then
  deny 'SAFE-WAIT (unreaped background loop): this loop is backgrounded (`done &` / `( … ) &`) with no reaper, so a crashed or rate-limited parent orphans it to PID 1 (PT-919: pinned load ~290 for an hour, flaked ExUnit into Postgres 57014 timeouts). Install a reaper — `child=$!; trap '"'"'kill "$child" 2>/dev/null'"'"' EXIT INT TERM` — or do not background it: block in the foreground with `timeout N tail --pid=<pid> -f /dev/null`, or let the harness wake you.'
fi

# No dangerous construct detected -> allow silently.
exit 0
