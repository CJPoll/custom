#!/bin/sh
# Self-test for pronoun-guard.sh.
#
# Pipes crafted PreToolUse stdin JSON into the hook and asserts the deny/allow
# behavior described in the spec. Runs the hook under an isolated HOME so the
# marker directory it creates is a throwaway temp tree (idempotent, no pollution
# of the real ~/.claude/.pronoun-checked).
#
# Exit 0 iff every case passes.

HOOK="$(dirname "$0")/pronoun-guard.sh"
HOOK=$(CDPATH= cd "$(dirname "$HOOK")" && printf '%s/%s' "$(pwd)" "$(basename "$HOOK")")

[ -f "$HOOK" ] || { echo "FAIL: hook not found at $HOOK"; exit 1; }

# Isolated HOME -> hook's MARKDIR lives under here and gets wiped at the end.
SANDBOX=$(mktemp -d) || { echo "FAIL: mktemp"; exit 1; }
trap 'rm -rf "$SANDBOX"' EXIT INT TERM

PASS=0
FAIL=0

# run <json> -> stdout of the hook (stderr discarded); exit status in $STATUS
run() {
  OUT=$(printf '%s' "$1" | HOME="$SANDBOX" sh "$HOOK" 2>/dev/null)
  STATUS=$?
}

is_deny() {
  # A block == exit 0 AND output containing permissionDecision":"deny".
  [ "$STATUS" -eq 0 ] && printf '%s' "$OUT" | grep -q '"permissionDecision":"deny"'
}

is_allow() {
  # An allow == exit 0 AND no output at all.
  [ "$STATUS" -eq 0 ] && [ -z "$OUT" ]
}

check() {
  # check <label> <expected: deny|allow>
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

# Convenience JSON builders (Bash command payloads).
bash_json() {
  # $1 = command string (must be JSON-safe: no embedded quotes/backslashes here)
  printf '{"tool_name":"Bash","tool_input":{"command":"%s"}}' "$1"
}

echo "pronoun-guard self-test"
echo "hook:    $HOOK"
echo "sandbox: $SANDBOX"
echo

# --- Case 1: no he/him/his -> allow (no output) ---
run "$(bash_json 'echo the team shipped it today')"
check "1. clean message -> allow" allow

# --- Case 2: contains he/him/his, first time -> deny ---
MSG_HE='{"tool_name":"SendMessage","tool_input":{"message":"he approved the plan"}}'
run "$MSG_HE"
check "2. first pronoun encounter -> deny" deny
FIRST_DENY_OUT=$OUT

# --- Case 3: same input again -> allow (marker consumed) ---
run "$MSG_HE"
check "3. identical re-send -> allow (confirm-once)" allow
SECOND_OUT=$OUT

# Sanity: a THIRD identical send should deny again (marker was consumed in #3).
run "$MSG_HE"
check "3b. third send (marker gone) -> deny again" deny

# --- Case 4: a DIFFERENT pronoun-bearing input -> deny (its own hash) ---
run '{"tool_name":"SendMessage","tool_input":{"message":"give him the report"}}'
check "4. different pronoun message -> deny (own hash)" deny

# --- Case 5: word-boundary correctness ---
# Non-triggers: words that merely CONTAIN he/his/him as substrings.
run "$(bash_json 'git log --oneline shows the history here in the shell')"
check "5a. history/the/here/shell -> allow (no false trigger)" allow

run "$(bash_json 'these theses cohere with the theme')"
check "5b. these/theses/cohere/theme -> allow" allow

# Triggers: standalone pronouns, various casing / punctuation boundaries.
run "$(bash_json 'His change was merged')"
check "5c. standalone His -> deny" deny

run '{"tool_name":"SendMessage","tool_input":{"message":"Ask HIM, then tell HER."}}'
check "5d. standalone HIM (uppercase) -> deny" deny

run '{"tool_name":"SendMessage","tool_input":{"message":"I think he. wrote it."}}'
check "5e. he. at a punctuation boundary -> deny" deny

# --- Case 6: FAIL-OPEN on malformed / empty stdin ---
run ''
check "6a. empty stdin -> allow (fail-open)" allow

run 'this is not json at all'
check "6b. non-JSON stdin -> allow (fail-open)" allow

run '{"tool_name":"Bash","tool_input":'
check "6c. truncated JSON -> allow (fail-open)" allow

run '{"tool_name":"Bash"}'
check "6d. no tool_input key -> allow (fail-open)" allow

run '{"tool_name":"Bash","tool_input":null}'
check "6e. null tool_input -> allow" allow

echo
echo "----- evidence: block-then-allow for the same message -----"
echo "first send  (deny):  $FIRST_DENY_OUT"
echo "second send (allow): [${SECOND_OUT}]"
echo

echo "==================================================="
printf 'RESULT: %d passed, %d failed\n' "$PASS" "$FAIL"
echo "==================================================="

[ "$FAIL" -eq 0 ] || exit 1
echo "ALL CASES PASS"
exit 0
