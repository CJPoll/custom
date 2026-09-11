#!/bin/sh
# Self-test for safe-wait-guard.sh.
#
# Pipes crafted PreToolUse stdin JSON into the hook and asserts the deny/allow
# behavior described in the spec. Hermetic: no network, no state mutation, no
# temp files, no reliance on anything outside the hook + jq.
#
# Exit 0 iff every case passes.

HOOK="$(dirname "$0")/safe-wait-guard.sh"
HOOK=$(CDPATH= cd "$(dirname "$HOOK")" && printf '%s/%s' "$(pwd)" "$(basename "$HOOK")")

[ -f "$HOOK" ] || { echo "FAIL: hook not found at $HOOK"; exit 1; }

PASS=0
FAIL=0

# run <json> -> stdout of the hook (stderr discarded); exit status in $STATUS
run() {
  OUT=$(printf '%s' "$1" | sh "$HOOK" 2>/dev/null)
  STATUS=$?
}

is_deny() {
  [ "$STATUS" -eq 0 ] && printf '%s' "$OUT" | grep -q '"permissionDecision":"deny"'
}

is_allow() {
  [ "$STATUS" -eq 0 ] && [ -z "$OUT" ]
}

# check <label> <expected: deny|allow>
check() {
  _label=$1
  _expect=$2
  if [ "$_expect" = "deny" ]; then
    if is_deny; then _r=PASS; else _r=FAIL; fi
  else
    if is_allow; then _r=PASS; else _r=FAIL; fi
  fi
  if [ "$_r" = PASS ]; then
    PASS=$((PASS + 1))
    printf '  PASS  %s (expected %s)\n' "$_label" "$_expect"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL  %s (expected %s) status=%s out=[%s]\n' "$_label" "$_expect" "$STATUS" "$OUT"
  fi
}

# Build a Bash PreToolUse event from a command string, JSON-encoding the command
# with jq so quotes/backslashes/`$$` survive intact.
bash_json() {
  jq -cn --arg c "$1" '{tool_name:"Bash",tool_input:{command:$c}}'
}

echo "safe-wait-guard self-test"
echo "hook: $HOOK"
echo

echo "--- BLOCK cases (dangerous wait constructs) ---"

run "$(bash_json 'while :; do :; done')"
check "1a. while :; do :; done (busy-spin)" deny

run "$(bash_json 'while true; do echo checking; done')"
check "1b. while true; checks only, no sleep" deny

run "$(bash_json 'until cond; do :; done')"
check "1c. until cond; do :; done (spin)" deny

run "$(bash_json '(while :; do :; done) &')"
check "1d. backgrounded busy-spin (the PT-919 shape)" deny

run "$(bash_json '(while cond; do check; sleep 5; done) &')"
check "2a. backgrounded loop, sleeps, NO reaper" deny

run "$(bash_json '{ while cond; do check; sleep 5; done; } &')"
check "2b. brace-group backgrounded loop, no reaper" deny

run "$(bash_json 'while pgrep -f "mypattern"; do sleep 1; done')"
check "4a. pgrep -f in a while wait, no \$\$ exclusion" deny

echo
echo "--- MUST-NOT-BLOCK cases (sanctioned / benign) ---"

run "$(bash_json 'for i in 1..100; do if [ -f /tmp/x ]; then break; fi; sleep 0.1; done')"
check "M1. sanctioned for-loop poll with sleep 0.1" allow

run "$(bash_json 'for i in $(seq 1 60); do test -e /tmp/f && break; sleep 5; done')"
check "M2. sanctioned seq poll with sleep 5" allow

run "$(bash_json 'until curl -s localhost:4000; do sleep 5; done')"
check "M3. until poll that sleeps each iteration" allow

run "$(bash_json 'while ! nc -z localhost 5432; do sleep 10; done')"
check "M4. while ! cond; do sleep 10; done" allow

run "$(bash_json '(while cond; do check; sleep 5; done) & child=$!; trap '"'"'kill "$child" 2>/dev/null'"'"' EXIT INT TERM')"
check "M5. backgrounded loop WITH trap-kill reaper" allow

run "$(bash_json 'while IFS= read -r line; do echo "$line"; done < /tmp/file')"
check "M6. while read stream loop (not a wait)" allow

run "$(bash_json 'git status && mix test')"
check "M7. ordinary command, no loop" allow

run "$(bash_json "find . -name '*.ex' | xargs grep foo")"
check "M8. pipeline, no loop" allow

run "$(bash_json 'while pgrep -f "mypattern" | grep -v $$; do sleep 1; done')"
check "M9. pgrep wait WITH grep -v \$\$ exclusion" allow

run "$(bash_json 'for f in *.txt; do process "$f"; done')"
check "M10. plain for loop, not backgrounded" allow

run "$(bash_json 'for i in 1 2; do echo hi; done && echo ok')"
check "M11. done && (logical AND, not backgrounding)" allow

run "$(bash_json 'pgrep -f mypattern')"
check "M12. one-off pgrep -f, no loop" allow

echo
echo "--- FAIL-OPEN cases (never wedge Bash) ---"

run ''
check "F1. empty stdin -> allow" allow

run 'this is not json at all'
check "F2. non-JSON stdin -> allow" allow

run '{"tool_name":"Bash","tool_input":'
check "F3. truncated JSON -> allow" allow

run '{"tool_name":"Bash"}'
check "F4. no tool_input -> allow" allow

run '{"tool_name":"Bash","tool_input":{"command":null}}'
check "F5. null command -> allow" allow

run '{"tool_name":"SendMessage","tool_input":{"message":"while :; do :; done"}}'
check "F6. non-Bash tool with spin text -> allow" allow

echo
echo "==================================================="
printf 'RESULT: %d passed, %d failed\n' "$PASS" "$FAIL"
echo "==================================================="

[ "$FAIL" -eq 0 ] || exit 1
echo "ALL CASES PASS"
exit 0
