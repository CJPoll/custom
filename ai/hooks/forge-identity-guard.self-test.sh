#!/bin/sh
# Self-test for forge-identity-guard.sh.
#
# Pipes crafted PreToolUse stdin JSON into the hook and asserts the WARN/allow
# behavior described in the spec. This guard WARNS (non-blocking
# additionalContext) — it never denies — so "warn" here means the hook emitted
# a hookSpecificOutput.additionalContext and "allow" means it emitted nothing.
# Hermetic: no network, no state mutation outside a mktemp dir; the git-push
# cases (DND-389) build throwaway repos there so the hook can resolve a remote.
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

# bash_json_cwd <cwd> <command> : the hook input as Claude Code sends it, with cwd.
bash_json_cwd() {
  jq -cn --arg d "$1" --arg c "$2" '{tool_name:"Bash",cwd:$d,tool_input:{command:$c}}'
}

# is_warn_with <needle> : a warn whose text also carries <needle>.
is_warn_with() {
  is_warn && printf '%s' "$OUT" | grep -qF -- "$1"
}

# check_text <label> <needle> : the last run warned AND carried <needle>.
check_text() {
  if is_warn_with "$2"; then
    PASS=$((PASS + 1)); printf '  PASS  %s\n' "$1"
  else
    FAIL=$((FAIL + 1)); printf '  FAIL  %s (needle [%s]) status=%s out=[%s]\n' "$1" "$2" "$STATUS" "$OUT"
  fi
}

TMP=$(mktemp -d) || { echo "FAIL: mktemp"; exit 1; }
trap 'rm -rf "$TMP"' EXIT
# Sandbox git: no owner/global config can change what a remote resolves to.
GIT_CONFIG_NOSYSTEM=1; GIT_CONFIG_GLOBAL="$TMP/gitconfig"; export GIT_CONFIG_NOSYSTEM GIT_CONFIG_GLOBAL
: > "$GIT_CONFIG_GLOBAL"
mkrepo() { git init -q "$TMP/$1" && git -C "$TMP/$1" remote add origin "$2"; }
mkrepo gh_scp 'git@github.com:o/r.git'
mkrepo gh_https 'https://github.com/o/r.git'
mkrepo gl 'git@gitlab.com:g/r.git'
mkrepo local "$TMP/bare.git"
mkrepo gl_ghpush 'git@gitlab.com:g/r.git'
git -C "$TMP/gl_ghpush" config remote.origin.pushurl 'git@github.com:o/r.git'
mkdir -p "$TMP/norepo"

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

run "$(bash_json_cwd "$TMP/gh_scp" 'git push origin HEAD')"
check "3a. plain git push, origin git@github.com: (cwd)" warn

run "$(bash_json_cwd "$TMP/gh_https" 'git push')"
check "3b. plain git push, default remote -> https github origin" warn

run "$(bash_json_cwd "$TMP/norepo" "git -C $TMP/gh_scp push origin HEAD")"
check "3c. git -C <github repo> push from another dir" warn

run "$(bash_json_cwd "$TMP/norepo" "cd $TMP/gh_scp && git push -u origin HEAD")"
check "3d. cd <github repo> && git push -u" warn

run "$(bash_json_cwd "$TMP/gl" 'git push https://github.com/o/r.git HEAD')"
check "3e. git push to a literal github.com URL" warn

run "$(bash_json_cwd "$TMP/gh_scp" '/usr/bin/git push origin HEAD')"
check "3f. path-qualified /usr/bin/git push" warn

run "$(bash_json_cwd "$TMP/gh_scp" 'GIT_TERMINAL_PROMPT=0 git -c credential.helper= push origin HEAD')"
check "3g. helper-disabled plain git push (still the owner, not the wrapper)" warn

run "$(bash_json_cwd "$TMP/gl_ghpush" 'git push')"
check "3h. gitlab fetch url but a github.com pushurl" warn

run "$(bash_json_cwd "$TMP/norepo" 'git push origin HEAD')"
check "3i. unresolvable remote (not a repo) -> still warns, never silent" warn
check_text "3i'. the unresolvable warn says it could not resolve" 'could not resolve its remote'

run "$(bash_json_cwd "$TMP/gh_scp" 'git push origin HEAD')"
check_text "3j. push warn carries the escalate Fix:" 'Fix: push through the wrapper'
check_text "3k. push warn says escalate to your admiral" 'escalate to your admiral with the command + error and wait'

run "$(bash_json 'gh pr create --fill')"
check_text "3l. create warn carries the escalate clause" 'escalate to your admiral with the command + error and wait'

echo
echo "--- MUST-NOT-WARN cases (wrapper / reads / unrelated) ---"

run "$(bash_json_cwd "$TMP/gh_scp" '~/dev/custom/ai/bin/gh-athena git push origin HEAD')"
check "M7. gh-athena git push (wrapper)" allow

run "$(bash_json_cwd "$TMP/gh_scp" "GIT_TERMINAL_PROMPT=0 ~/dev/custom/ai/bin/gh-athena git -c credential.helper= -c 'url.https://github.com/.insteadOf=git@github.com:' push origin HEAD")"
check "M8. the documented explicit wrapper push form" allow

run "$(bash_json_cwd "$TMP/gl" 'git push origin HEAD')"
check "M9. plain git push to a GitLab remote (no Athena push path there)" allow

run "$(bash_json_cwd "$TMP/local" 'git push origin HEAD')"
check "M10. plain git push to a local bare remote" allow

run "$(bash_json_cwd "$TMP/gh_scp" 'git commit -m "push to github.com later"')"
check "M11. git commit whose message says push github.com" allow

run "$(bash_json_cwd "$TMP/gh_scp" 'git log --grep push')"
check "M12. git log --grep push (not a push)" allow

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
