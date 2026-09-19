#!/bin/sh
# Self-test for forge-auth-guard.sh.
#
# Pipes crafted PreToolUse stdin JSON into the hook and asserts the deny/allow
# behavior described in the spec. Hermetic: no network, no state mutation, no
# temp files, no reliance on anything outside the hook + jq.
#
# Exit 0 iff every case passes.

HOOK="$(dirname "$0")/forge-auth-guard.sh"
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

bash_json() {
  jq -cn --arg c "$1" '{tool_name:"Bash",tool_input:{command:$c}}'
}

echo "forge-auth-guard self-test"
echo "hook: $HOOK"
echo

echo "--- DENY cases (auth-mutating) ---"

run "$(bash_json 'gh auth login')"
check "1a. gh auth login" deny

run "$(bash_json 'gh auth logout --hostname github.com')"
check "1b. gh auth logout" deny

run "$(bash_json 'gh auth refresh -s repo')"
check "1c. gh auth refresh" deny

run "$(bash_json 'gh auth token')"
check "1d. gh auth token" deny

run "$(bash_json 'gh-athena auth login')"
check "1e. gh-athena auth login (wrapper)" deny

run "$(bash_json 'glab auth login --hostname gitlab.com')"
check "2a. glab auth login" deny

run "$(bash_json 'glab auth refresh')"
check "2b. glab auth refresh" deny

run "$(bash_json 'glab-athena auth logout')"
check "2c. glab-athena auth logout (wrapper)" deny

run "$(bash_json 'gh api --method POST /login/oauth/access_token -f code=x')"
check "3a. gh api POST oauth token" deny

run "$(bash_json 'curl -X POST https://gitlab.com/oauth/token -d grant_type=refresh_token')"
check "3b. curl POST oauth/token" deny

run "$(bash_json 'echo hax >> ~/.config/gh/hosts.yml')"
check "4a. append to gh hosts.yml" deny

run "$(bash_json 'sed -i s/x/y/ ~/.config/glab-cli/config.yml')"
check "4b. sed -i glab-cli config.yml" deny

run "$(bash_json 'rm ~/.config/gh/hosts.yml')"
check "4c. rm gh hosts.yml" deny

echo
echo "--- MUST-NOT-BLOCK cases (reads / ordinary forge use) ---"

run "$(bash_json 'gh auth status')"
check "M1. gh auth status (read)" allow

run "$(bash_json 'glab auth status')"
check "M2. glab auth status (read)" allow

run "$(bash_json '~/dev/custom/ai/bin/gh-athena pr create --title x --body y')"
check "M3. gh-athena pr create (identity write, not auth)" allow

run "$(bash_json 'glab mr merge 42')"
check "M4. glab mr merge (not auth)" allow

run "$(bash_json 'gh api /repos/o/r/pulls --method GET')"
check "M5. gh api GET (read, no oauth)" allow

run "$(bash_json 'cat ~/.config/gh/hosts.yml')"
check "M6. cat gh hosts.yml (read)" allow

run "$(bash_json 'grep github ~/.config/glab-cli/config.yml')"
check "M7. grep glab config (read)" allow

run "$(bash_json 'gh pr list && glab ci status')"
check "M8. ordinary forge reads" allow

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

run '{"tool_name":"SendMessage","tool_input":{"message":"gh auth login"}}'
check "F6. non-Bash tool with auth text -> allow" allow

echo
echo "==================================================="
printf 'RESULT: %d passed, %d failed\n' "$PASS" "$FAIL"
echo "==================================================="

[ "$FAIL" -eq 0 ] || exit 1
echo "ALL CASES PASS"
exit 0
