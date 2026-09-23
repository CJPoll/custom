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
echo "--- DENY cases: path-qualified / quoted / chained forms (DND-388) ---"
# Each case below was ALLOWED by the pre-DND-388 hook. The rule-1/2 left
# boundary excluded '/', so a path-qualified command word never matched; quotes
# around the command word or subcommand split the pattern; rules 3/4 missed the
# attached/`=`/lowercase verb forms, gh api's implicit POST, XDG paths, and a
# path-qualified mutating tool.

run "$(bash_json 'git add -A; ~/dev/custom/ai/bin/gh-athena auth setup-git >/dev/null 2>&1; git push -u origin x')"
check "P1a. ~/.../gh-athena auth setup-git (the DND-385 command line)" deny

run "$(bash_json '~/dev/custom/ai/bin/gh-athena auth setup-git')"
check "P1b. ~/.../gh-athena auth setup-git (bare)" deny

run "$(bash_json '/usr/bin/gh auth login')"
check "P1c. /usr/bin/gh auth login" deny

run "$(bash_json './gh auth refresh')"
check "P1d. ./gh auth refresh" deny

run "$(bash_json '$HOME/dev/custom/ai/bin/glab-athena auth login')"
check "P2a. \$HOME/.../glab-athena auth login" deny

run "$(bash_json '/usr/local/bin/glab auth logout')"
check "P2b. /usr/local/bin/glab auth logout" deny

run "$(bash_json 'cd /tmp; /usr/bin/gh auth login')"
check "P3a. after ';'" deny

run "$(bash_json 'true && ~/dev/custom/ai/bin/gh-athena auth token')"
check "P3b. after '&&'" deny

run "$(bash_json 'false || /usr/bin/glab auth refresh')"
check "P3c. after '||'" deny

run "$(bash_json 'echo x | /usr/bin/gh auth login --with-token')"
check "P3d. after '|'" deny

run "$(bash_json 'T=$(~/dev/custom/ai/bin/gh-athena auth token)')"
check "P3e. inside \$( )" deny

run "$(bash_json 'T=`/usr/bin/gh auth token`')"
check "P3f. inside backticks" deny

run "$(bash_json '(cd /tmp && $HOME/dev/custom/ai/bin/glab-athena auth login)')"
check "P3g. inside a subshell" deny

run "$(bash_json '"gh" auth login')"
check "P4a. quoted command word \"gh\"" deny

run "$(bash_json "gh auth 'setup-git'")"
check "P4b. quoted subcommand 'setup-git'" deny

run "$(bash_json '\gh auth login')"
check "P4c. backslash-escaped command word" deny

run "$(bash_json "bash -c '/usr/bin/gh auth login'")"
check "P4d. inside bash -c '...'" deny

run "$(bash_json 'gh api /login/oauth/access_token -f client_id=x -f code=y')"
check "P5a. gh api oauth token with -f fields (implicit POST)" deny

run "$(bash_json 'curl -XPOST https://gitlab.com/oauth/token')"
check "P5b. curl -XPOST (attached verb)" deny

run "$(bash_json 'gh api --method=post /login/oauth/access_token')"
check "P5c. --method=post (= form, lowercase)" deny

run "$(bash_json 'curl --data-urlencode grant_type=refresh_token https://gitlab.com/oauth/token')"
check "P5d. curl --data-urlencode" deny

run "$(bash_json "curl -X POST 'https://gitlab.com/oauth/\"token\"'")"
check "P5e. quote-split oauth path" deny

run "$(bash_json '/bin/rm ~/.config/gh/hosts.yml')"
check "P6a. path-qualified /bin/rm of gh hosts.yml" deny

run "$(bash_json 'echo x > "$XDG_CONFIG_HOME/gh/hosts.yml"')"
check "P6b. write to \$XDG_CONFIG_HOME/gh/hosts.yml" deny

run "$(bash_json 'rm -rf ~/.config/glab-cli')"
check "P6c. rm -rf the glab-cli config dir" deny

run "$(bash_json 'true && $(/usr/bin/cp x ~/.config/gh/config.yml)')"
check "P6d. path-qualified cp inside \$( )" deny

run "$(bash_json 'perl -pi -e s/a/b/ ~/.config/glab-cli/config.yml')"
check "P6e. perl -pi on glab-cli config.yml" deny

run "$(bash_json 'sed -e s/a/b/ -i ~/.config/gh/hosts.yml')"
check "P6f. sed with -i after another flag" deny

run "$(bash_json 'sed --in-place s/a/b/ ~/.config/gh/hosts.yml')"
check "P6g. sed --in-place" deny

run "$(bash_json 'unlink ~/.config/gh/hosts.yml; shred -u ~/.config/glab-cli/config.yml')"
check "P6h. unlink / shred" deny

run "$(bash_json 'rm -rf "$XDG_CONFIG_HOME/gh"')"
check "P6i. rm -rf \$XDG_CONFIG_HOME/gh (dir form)" deny

run "$(bash_json 'rm -rf ~/.config/gh; true')"
check "P6j. config dir followed by ';'" deny

run "$(bash_json '(rm -rf ~/.config/glab-cli)')"
check "P6k. config dir followed by ')'" deny

run "$(bash_json 'mv ~/.config/gh{,.bak}')"
check "P6l. config dir with brace expansion" deny

run "$(bash_json 'rm -rf ~/.config/gh*')"
check "P6m. config dir glob" deny

run "$(bash_json 'rm -rf ${XDG_CONFIG_HOME:-~/.config}/gh')"
check "P6n. \${XDG_CONFIG_HOME:-~/.config}/gh" deny

run "$(bash_json 'gsed -i s/a/b/ ~/.config/gh/hosts.yml')"
check "P6o. gsed -i (GNU sed)" deny

run "$(bash_json 'rm "$GH_CONFIG_DIR/hosts.yml"')"
check "P6p. \$GH_CONFIG_DIR/hosts.yml" deny

run "$(bash_json '~/dev/custom/ai/bin/gh-athena auth switch --user x')"
check "P7a. gh auth switch (changes the active account)" deny

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

run "$(bash_json '~/dev/custom/ai/bin/gh-athena auth status')"
check "M9. path-qualified gh-athena auth status (read)" allow

run "$(bash_json '/usr/bin/glab auth status')"
check "M10. path-qualified glab auth status (read)" allow

run "$(bash_json '~/dev/custom/ai/bin/gh-athena pr create --fill --base main')"
check "M11. path-qualified gh-athena pr create" allow

run "$(bash_json 'ls ~/dev/github/auth/login ~/ghost/auth/token')"
check "M12. paths merely containing gh" allow

run "$(bash_json '/opt/nigh auth login; ~/bin/sigh auth refresh')"
check "M13. path-qualified words merely ending in gh" allow

run "$(bash_json 'my-gh auth login; foo_glab auth login')"
check "M14. words ending in -gh/_glab (not the forge CLI)" allow

run "$(bash_json 'cat ~/.config/gh/hosts.yml 2>/dev/null')"
check "M15. read of gh hosts.yml with 2>/dev/null" allow

run "$(bash_json 'ls ~/.config/glab-cli >/dev/null 2>&1')"
check "M16. ls of glab-cli dir redirected to /dev/null" allow

run "$(bash_json 'curl -s https://gitlab.com/oauth/token/info -H "Authorization: Bearer x"')"
check "M17. GET oauth/token/info (read)" allow

run "$(bash_json 'curl -fsSL https://gitlab.com/oauth/token/info')"
check "M18. curl -fsSL GET of oauth/token/info (-f is --fail, not a POST)" allow

run "$(bash_json 'curl -D - https://gitlab.com/oauth/token/info')"
check "M19. curl -D (dump header) GET of oauth/token/info" allow

run "$(bash_json 'perl -Mstrict -ne print ~/.config/gh/hosts.yml')"
check "M20. perl -Mstrict -ne read of gh hosts.yml" allow

run "$(bash_json 'sed -n p ~/.config/gh/hosts.yml | grep -i github')"
check "M21. sed -n read piped to grep -i" allow

run "$(bash_json 'rm -rf ~/.config/gh-dash-cache')"
check "M22. a sibling dir that merely starts with gh" allow

run "$(bash_json 'GIT_TERMINAL_PROMPT=0 ~/dev/custom/ai/bin/gh-athena git -c credential.helper= push origin x')"
check "M23. gh-athena git push with the helper disabled (the sanctioned push)" allow

run "$(bash_json '~/dev/custom/ai/bin/gh-athena auth git-credential get')"
check "M24. gh-athena auth git-credential (a credential READ by git)" allow

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
