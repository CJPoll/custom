#!/bin/sh
# Self-test for forge-identity-guard.sh.
#
# Pipes crafted PreToolUse stdin JSON into the hook and asserts the WARN/allow
# behavior described in the spec. This guard WARNS (non-blocking
# additionalContext) — it never denies — so "warn" here means the hook emitted
# a hookSpecificOutput.additionalContext and "allow" means it emitted nothing.
# Hermetic: no network, no state mutation, no temp files, hook + jq only.
#
# Exit 0 iff every case passes.

HOOK="$(dirname "$0")/forge-identity-guard.sh"
HOOK=$(CDPATH= cd "$(dirname "$HOOK")" && printf '%s/%s' "$(pwd)" "$(basename "$HOOK")")

[ -f "$HOOK" ] || { echo "FAIL: hook not found at $HOOK"; exit 1; }

PASS=0
FAIL=0

run() {
  OUT=$(printf '%s' "$1" | sh "$HOOK" 2>/dev/null)
  STATUS=$?
}

is_warn() {
  [ "$STATUS" -eq 0 ] && printf '%s' "$OUT" | grep -q '"additionalContext"'
}

is_allow() {
  [ "$STATUS" -eq 0 ] && [ -z "$OUT" ]
}

# check <label> <expected: warn|allow>
check() {
  _label=$1
  _expect=$2
  if [ "$_expect" = "warn" ]; then
    if is_warn; then _r=PASS; else _r=FAIL; fi
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

bash_json() {
  jq -cn --arg c "$1" '{tool_name:"Bash",tool_input:{command:$c}}'
}

echo "forge-identity-guard self-test"
echo "hook: $HOOK"
echo

echo "--- WARN cases (bare create/merge = owner-attributed write) ---"

run "$(bash_json 'gh pr create --title x --body y')"
check "1a. bare gh pr create" warn

run "$(bash_json 'gh -R o/r pr create --fill')"
check "1b. gh pr create with flags before subcommand" warn

run "$(bash_json 'glab mr create --fill')"
check "1c. bare glab mr create" warn

run "$(bash_json 'gh pr merge 5 --squash')"
check "2a. bare gh pr merge" warn

run "$(bash_json 'gh -R o/r pr merge 5 --auto')"
check "2b. gh pr merge with flags before subcommand" warn

run "$(bash_json 'glab mr merge 42')"
check "2c. bare glab mr merge" warn

echo
echo "--- MUST-NOT-WARN cases (wrapper / reads / unrelated) ---"

run "$(bash_json '~/dev/custom/ai/bin/gh-athena pr create --title x')"
check "M1. gh-athena pr create (wrapper)" allow

run "$(bash_json '~/dev/custom/ai/bin/gh-athena pr merge 5 --squash')"
check "M2. gh-athena pr merge (wrapper)" allow

run "$(bash_json '~/dev/custom/ai/bin/glab-athena mr create --fill')"
check "M3. glab-athena mr create (wrapper)" allow

run "$(bash_json '~/dev/custom/ai/bin/glab-athena mr merge 42')"
check "M4. glab-athena mr merge (wrapper)" allow

run "$(bash_json 'gh pr view 5')"
check "M5. gh pr view (read)" allow

run "$(bash_json 'gh pr list && glab mr list')"
check "M6. pr/mr list (reads)" allow

echo
echo "--- FAIL-OPEN cases (never wedge Bash) ---"

run ''
check "F1. empty stdin -> allow" allow

run 'not json'
check "F2. non-JSON stdin -> allow" allow

run '{"tool_name":"Bash","tool_input":'
check "F3. truncated JSON -> allow" allow

run '{"tool_name":"SendMessage","tool_input":{"message":"gh pr merge 5"}}'
check "F4. non-Bash tool with merge text -> allow" allow

echo
echo "==================================================="
printf 'RESULT: %d passed, %d failed\n' "$PASS" "$FAIL"
echo "==================================================="

[ "$FAIL" -eq 0 ] || exit 1
echo "ALL CASES PASS"
exit 0
