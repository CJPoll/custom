#!/bin/sh
# Self-test for forge-auth-guard.sh.
#
# Pipes crafted PreToolUse stdin JSON into the hook and asserts the deny/allow
# behavior described in the spec. Hermetic: no network, no state mutation, no
# reliance on anything outside the hook + jq. The cwd cases run the hook with a
# pinned environment (fake HOME, forge config vars unset or set per case); the
# two symlink cases use one mktemp dir, removed on exit.
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

# run_ctx <cwd> <command> [VAR=value ...] : run the hook on a Bash call made
# from <cwd> ("" = no cwd field), under a pinned environment: HOME=/home/u,
# GH_CONFIG_DIR / GLAB_CONFIG_DIR / XDG_CONFIG_HOME unset unless a VAR=value
# argument sets one. The live session's env can never leak into a case.
run_ctx() {
  _cwd=$1; _cmd=$2; shift 2
  if [ -n "$_cwd" ]; then
    _json=$(jq -cn --arg c "$_cmd" --arg d "$_cwd" '{tool_name:"Bash",cwd:$d,tool_input:{command:$c}}')
  else
    _json=$(bash_json "$_cmd")
  fi
  OUT=$(printf '%s' "$_json" \
    | env -u GH_CONFIG_DIR -u GLAB_CONFIG_DIR -u XDG_CONFIG_HOME HOME=/home/u "$@" sh "$HOOK" 2>/dev/null)
  STATUS=$?
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

run "$(bash_json 'wget --post-data grant_type=x https://gitlab.com/oauth/token')"
check "P5f. wget --post-data" deny

run "$(bash_json 'wget --post-file body.txt https://gitlab.com/oauth/token')"
check "P5g. wget --post-file" deny

run "$(bash_json 'curl --json {} https://github.com/login/oauth/access_token')"
check "P5h. curl --json" deny

run "$(bash_json 'curl --form code=x https://github.com/login/oauth/access_token')"
check "P5i. curl --form" deny

run "$(bash_json 'http POST https://gitlab.com/oauth/token grant_type=x')"
check "P5j. httpie POST verb word" deny

run "$(bash_json 'curl -sd grant_type=x https://gitlab.com/oauth/token')"
check "P5k. curl -sd (d inside a flag cluster)" deny

run "$(bash_json 'curl -dgrant_type=x https://gitlab.com/oauth/token')"
check "P5l. curl -dVALUE (attached)" deny

run "$(bash_json 'gh api /login/oauth/access_token --field code=x')"
check "P5m. gh api --field" deny

run "$(bash_json 'gh api /login/oauth/access_token --raw-field code=x')"
check "P5n. gh api --raw-field" deny

run "$(bash_json 'gh api /login/oauth/access_token --input body.json')"
check "P5o. gh api --input" deny

run "$(bash_json '/usr/bin/glab api oauth/token -f grant_type=x')"
check "P5p. path-qualified glab api -f" deny

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

run "$(bash_json 'truncate -s0 "$GLAB_CONFIG_DIR/config.yml"')"
check "P6q. \$GLAB_CONFIG_DIR/config.yml" deny

run "$(bash_json 'ln -sf /tmp/evil.yml ~/.config/gh/hosts.yml')"
check "P6r. ln -sf over gh hosts.yml" deny

run "$(bash_json 'sed -Ei s/a/b/ ~/.config/gh/hosts.yml')"
check "P6s. sed -Ei (i inside a flag cluster)" deny

run "$(bash_json '~/dev/custom/ai/bin/gh-athena auth switch --user x')"
check "P7a. gh auth switch (changes the active account)" deny

echo
echo "--- DENY cases: residuals closed by DND-390 ---"
# Each case below was ALLOWED by the DND-388 hook (origin/main 449c318).

# V: a command word built by expansion (rule 5), or an expanded subcommand.
run "$(bash_json 'G=gh; $G auth login')"
check "V1. \$G auth login (variable command word)" deny

run "$(bash_json '${GH:-gh} auth setup-git')"
check "V2. \${GH:-gh} auth setup-git" deny

run "$(bash_json '"$GH" auth token')"
check "V3. quoted \"\$GH\" auth token" deny

run "$(bash_json '$(which gh) auth login')"
check "V4. \$(which gh) auth login (command substitution)" deny

run "$(bash_json '`command -v glab` auth logout')"
check "V5. backtick command substitution" deny

run "$(bash_json '$HOME/bin/$X auth refresh')"
check "V6. variable inside a path-qualified word" deny

run "$(bash_json 'gh auth $SUB')"
check "V7. gh auth \$SUB (expanded subcommand)" deny

run "$(bash_json 'glab-athena auth $(echo login)')"
check "V8. glab-athena auth \$(...) (substituted subcommand)" deny

run "$(bash_json 'eval "$G auth switch --user x"')"
check "V9. eval of a variable command word" deny

run "$(bash_json '${GLAB} auth configure-docker')"
check "V10. \${GLAB} auth configure-docker" deny

run "$(bash_json 'cat tok | $G auth login --with-token')"
check "V11. variable command word after a pipe" deny

# D: glab auth subcommands missing from the DND-388 list (rule 2).
run "$(bash_json 'glab auth configure-docker')"
check "D1. glab auth configure-docker (writes docker credential config)" deny

run "$(bash_json '/usr/bin/glab auth docker-helper')"
check "D2. glab auth docker-helper (registry credential helper)" deny

run "$(bash_json 'glab-athena auth dpop-gen --private-key ~/.ssh/id_ed25519')"
check "D3. glab auth dpop-gen (mints a DPoP proof JWT)" deny

# C: a write by bare name after reaching the config location (rule 4).
run "$(bash_json 'cd ~/.config && rm -rf gh')"
check "C1. cd ~/.config && rm -rf gh" deny

run "$(bash_json 'pushd $XDG_CONFIG_HOME; mv glab-cli /tmp/x')"
check "C2. pushd \$XDG_CONFIG_HOME; mv glab-cli" deny

run "$(bash_json 'cd ${XDG_CONFIG_HOME:-~/.config} && rm -rf gh*')"
check "C3. cd \${XDG_CONFIG_HOME:-~/.config} && rm -rf gh*" deny

run "$(bash_json 'cd $HOME/.config; cd gh && rm hosts.yml')"
check "C4. cd to the root, then cd gh, then a bare-name rm" deny

run "$(bash_json 'cd ~/.config && echo x > gh/extra.yml')"
check "C5. cd to the root, then a redirect into gh/" deny

run "$(bash_json 'cd ~/.config && rm -rf ./gh')"
check "C5a. cd to the root, then rm -rf ./gh (relative prefix)" deny

run "$(bash_json 'cd ~/.config && echo x > ./gh/extra.yml')"
check "C5b. cd to the root, then a redirect into ./gh/" deny

run "$(bash_json 'cd ~/.config && cd ./gh && rm hosts.yml')"
check "C5c. cd to the root, then cd ./gh, then a bare-name rm" deny

run "$(bash_json 'cd ~/.config && rm -rf ${PWD}/glab-cli')"
check "C5d. cd to the root, then rm -rf \${PWD}/glab-cli" deny

run_ctx /home/u/.config 'mv ././glab-cli /tmp/x'
check "C5e. cwd ~/.config: mv ././glab-cli" deny

run "$(bash_json 'cd -- ~/.config && rm -rf gh')"
check "C5f. cd -- to the root (option before the path)" deny

run "$(bash_json 'cd -P ~/.config && rm -rf glab-cli')"
check "C5g. cd -P to the root" deny

run "$(bash_json 'pushd -n $XDG_CONFIG_HOME; cd -L gh && rm hosts.yml')"
check "C5h. pushd -n to the root, then cd -L gh" deny

run_ctx /home/u/.config/gh 'rm hosts.yml'
check "C6. cwd ~/.config/gh (earlier cd): rm hosts.yml" deny

# The cwd deny over-denies a write that lands elsewhere, so its message must
# name the cwd and the recovery (cd out in a separate call).
run_ctx /home/u/.config/gh 'gh pr list > /tmp/out'
if printf '%s' "$OUT" | grep -q '/home/u/.config/gh' \
  && printf '%s' "$OUT" | grep -q 'OWN Bash call'; then
  check "C6m. cwd deny names the cwd and says cd out in its own call" deny
else
  STATUS=1; check "C6m. cwd deny names the cwd and says cd out in its own call" deny
fi

run_ctx /home/u/.config/glab-cli/sub 'sed -i s/a/b/ config.yml'
check "C7. cwd under ~/.config/glab-cli: sed -i" deny

run_ctx /home/u/.config 'rm -rf gh'
check "C8. cwd ~/.config: rm -rf gh" deny

run_ctx /cfg/ghdir 'echo x > hosts.yml' GH_CONFIG_DIR=/cfg/ghdir
check "C9. cwd = \$GH_CONFIG_DIR: a redirect" deny

run_ctx /cfg/glabdir/ 'unlink config.yml' GLAB_CONFIG_DIR=/cfg/glabdir/
check "C10. cwd = \$GLAB_CONFIG_DIR (trailing slashes)" deny

run_ctx /xdg 'rm -rf glab-cli' XDG_CONFIG_HOME=/xdg
check "C11. cwd = \$XDG_CONFIG_HOME: rm -rf glab-cli" deny

run_ctx /xdg/gh 'truncate -s0 hosts.yml' XDG_CONFIG_HOME=/xdg
check "C12. cwd = \$XDG_CONFIG_HOME/gh: truncate" deny

# Symlinked config dir: compare realpaths on both sides.
TMPD=$(mktemp -d 2>/dev/null) || TMPD=
if [ -n "$TMPD" ]; then
  trap 'rm -rf "$TMPD"' EXIT
  trap 'exit 130' INT TERM
  mkdir -p "$TMPD/real" && ln -s "$TMPD/real" "$TMPD/link"
  run_ctx "$TMPD/link" 'rm hosts.yml' GH_CONFIG_DIR="$TMPD/real"
  check "C13. cwd is a symlink to \$GH_CONFIG_DIR" deny
  run_ctx "$TMPD/real" 'rm hosts.yml' GH_CONFIG_DIR="$TMPD/link"
  check "C14. \$GH_CONFIG_DIR is a symlink to the cwd" deny
else
  FAIL=$((FAIL + 1)); echo "  FAIL  C13/C14: mktemp -d failed; symlink cases could not run"
fi

# H: httpie / xh infer POST from a request body (rule 3).
run "$(bash_json 'http https://github.com/login/oauth/access_token client_id=x code=y')"
check "H1. httpie data items key=value" deny

run "$(bash_json 'https gitlab.com/oauth/token grant_type:=1')"
check "H2. https command, key:=json item" deny

run "$(bash_json 'echo {} | http https://gitlab.com/oauth/token')"
check "H3. body piped into httpie" deny

run "$(bash_json 'http https://gitlab.com/oauth/token < body.json')"
check "H4. body redirected into httpie" deny

run "$(bash_json 'xh https://gitlab.com/oauth/token code=@code.txt')"
check "H5. xh key=@file item" deny

run "$(bash_json 'http --raw x https://gitlab.com/oauth/token')"
check "H6. httpie --raw body" deny

run "$(bash_json '/usr/bin/http -f https://github.com/login/oauth/access_token client_id:=1')"
check "H7. path-qualified httpie --form with key:= item" deny

run "$(bash_json 'http https://gitlab.com/oauth/token upload@/tmp/f')"
check "H8. httpie field@file upload" deny

# R: glab-athena refresh (rule 6; coordinator scope addition). Never run for real.
run "$(bash_json 'glab-athena refresh')"
check "R1. glab-athena refresh" deny

run "$(bash_json '~/dev/custom/ai/bin/glab-athena refresh')"
check "R2. path-qualified ~/.../glab-athena refresh" deny

run "$(bash_json '"glab-athena" '"'"'refresh'"'"'')"
check "R3. quoted command word and subcommand" deny

run "$(bash_json 'git status && glab-athena refresh; echo done')"
check "R4. chained after && and before ;" deny

run "$(bash_json '$HOME/dev/custom/ai/bin/glab-athena refresh >/dev/null 2>&1')"
check "R5. \$HOME/... path with redirects" deny

run "$(bash_json '(glab-athena refresh)')"
check "R6. inside a subshell" deny

run "$(bash_json "bash -c '/home/u/dev/custom/ai/bin/glab-athena refresh'")"
check "R7. inside bash -c" deny

run "$(bash_json 'G=~/dev/custom/ai/bin/glab-athena; $G refresh')"
check "R8. \$G refresh (variable command word)" deny

run "$(bash_json '${GA:-glab-athena} refresh')"
check "R9. \${GA:-glab-athena} refresh" deny

run "$(bash_json 'glab-athena $(echo refresh)')"
check "R10. glab-athena \$(...) (expanded first argument)" deny

run "$(bash_json '$(which glab-athena) refresh')"
check "R11. \$(which glab-athena) refresh" deny

run "$(bash_json '$NPM refresh')"
check "R12. any expanded command word + refresh (accepted text-match FP)" deny

# X: the same expanded-command-word class in rules 3 and 4.
run "$(bash_json '$GH api /login/oauth/access_token -f code=x')"
check "X1. \$GH api oauth token with -f (rule 3)" deny

run "$(bash_json '$H https://gitlab.com/oauth/token grant_type=x')"
check "X2. \$H url data item (rule 3, httpie by variable)" deny

run "$(bash_json 'R=rm; $R ~/.config/gh/hosts.yml')"
check "X4. \$R on gh hosts.yml (rule 4)" deny

run "$(bash_json 'cd ~/.config && $RM -rf gh')"
check "X5. cd to the root, then \$RM -rf gh (rule 4b)" deny

run_ctx /home/u/.config/gh '$EDITOR hosts.yml'
check "X6. cwd in ~/.config/gh: \$EDITOR hosts.yml (rule 4c)" deny

run "$(bash_json 'cd ~/.config && rm -rf *')"
check "X7. cd to the root, then rm -rf * (rule 4b)" deny

run_ctx /home/u/.config 'rm -rf ./*'
check "X8. cwd ~/.config: rm -rf ./* (rule 4b)" deny

run "$(bash_json 'sudo $R ~/.config/glab-cli/config.yml')"
check "X9. prefix keyword then an expanded command word (rule 4)" deny

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

run "$(bash_json 'curl -sS -L -H Accept:application/json -o out.json https://gitlab.com/oauth/token/info')"
check "M19b. ordinary curl flags (no d cluster) on a token-path GET" allow

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

# DND-390 negatives: the new shapes must not over-match.
run "$(bash_json '$GH auth status')"
check "N1. \$GH auth status (read)" allow

run "$(bash_json '${GH:-gh} auth git-credential get')"
check "N2. \${GH:-gh} auth git-credential (read)" allow

run "$(bash_json '$GH pr list; ${GLAB:-glab} mr view 1')"
check "N3. variable command word, not auth" allow

run "$(bash_json '$EDITOR notes.txt; echo $HOME/auth')"
check "N4. other variable command words" allow

run "$(bash_json 'glab auth status; /usr/bin/glab auth status --hostname gitlab.com')"
check "N5. glab auth status (read)" allow

run "$(bash_json 'http https://gitlab.com/oauth/token/info Authorization:"Bearer x"')"
check "N6. httpie GET of a token path with a header only" allow

run "$(bash_json 'http GET https://gitlab.com/oauth/token/info page==2')"
check "N7. httpie query param key==value is not a body" allow

run "$(bash_json 'http https://api.github.com/repos/o/r name=x')"
check "N8. httpie POST to a non-token endpoint" allow

run "$(bash_json 'false || http https://gitlab.com/oauth/token/info')"
check "N9. || before httpie is not a pipe" allow

run "$(bash_json 'curl -s https://example.com/x | jq . ; http https://gitlab.com/oauth/token/info')"
check "N10. a pipe into another command before an httpie GET" allow

run_ctx /home/u/.config/gh 'cat hosts.yml; ls -la'
check "N11. cwd in ~/.config/gh: reads" allow

run_ctx /home/u/.config 'ls gh; cat gh/hosts.yml'
check "N12. cwd ~/.config: reads of gh" allow

run_ctx /home/u/.config 'rm -rf nvim-cache'
check "N13. cwd ~/.config: a write to a non-forge dir" allow

run_ctx /home/u/.config/gh-dash 'rm -rf cache'
check "N14. cwd in a sibling dir gh-dash" allow

run "$(bash_json 'cd ~/.config && rm -rf nvim && gh pr list')"
check "N15. cd to the root, write a non-forge dir, then gh" allow

run "$(bash_json 'rm -rf ~/src/gh; cd /tmp && rm -rf gh')"
check "N16. bare gh operand with no config-root context" allow

run "$(bash_json 'cd -P /tmp && rm -rf gh')"
check "N16b. cd with an option to a non-config dir, then rm gh" allow

run_ctx /tmp/work 'rm x' GH_CONFIG_DIR=
check "N17. empty \$GH_CONFIG_DIR is not read as matching every cwd" allow

run_ctx /tmp/work 'rm x' GH_CONFIG_DIR=/
check "N18. \$GH_CONFIG_DIR=/ is not read as matching every cwd" allow

run_ctx /home/u/work 'rm x' GLAB_CONFIG_DIR=work
check "N19. a relative \$GLAB_CONFIG_DIR is skipped" allow

run_ctx /tmp/work 'rm -rf glab-cli' XDG_CONFIG_HOME=
check "N20. empty \$XDG_CONFIG_HOME is not read as a config root" allow

run_ctx '' 'rm hosts.yml'
check "N21. no cwd field: bare-name rm allowed (fail-open)" allow

run_ctx /home/u/.config/gh 'GIT_TERMINAL_PROMPT=0 ~/dev/custom/ai/bin/gh-athena git -c credential.helper= push origin x'
check "N22. sanctioned push from any cwd" allow

run "$(bash_json 'glab-athena api user')"
check "N23. glab-athena api user (read)" allow

run "$(bash_json 'glab-athena mr list')"
check "N24. glab-athena mr list (read)" allow

run "$(bash_json '~/dev/custom/ai/bin/glab-athena api projects')"
check "N25. path-qualified glab-athena api projects (read)" allow

run "$(bash_json 'gh-athena api /user')"
check "N26. gh-athena api /user (read)" allow

run "$(bash_json 'glab-athena mr list --search refresh')"
check "N27. refresh as a later argument, not the subcommand" allow

run "$(bash_json '$GA mr list; $X --refresh; echo refresh')"
check "N28. expanded command word without a bare refresh subcommand" allow

run "$(bash_json 'T=$(cat ~/.config/gh/hosts.yml)')"
check "N29. assignment of a read of gh hosts.yml (not a command word)" allow

run "$(bash_json 'echo $HOME/.config/gh/hosts.yml; ls $XDG_CONFIG_HOME/glab-cli')"
check "N30. expanded words in argument position, config path named" allow

run "$(bash_json 'curl -s https://gitlab.com/oauth/token/info | $JQ .scope')"
check "N31. GET of a token path piped into a variable command, no body" allow

run "$(bash_json 'cd ~/.config && rm -rf *.bak')"
check "N32. a glob at the config root that cannot match gh" allow

run "$(bash_json '$CURL -s https://gitlab.com/oauth/token/info')"
check "N33. variable curl GET of a token path" allow

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
echo "--- DENY TEXT: every rule tells the agent to escalate, not work around (DND-389) ---"

# check_escalate <label> : the last run denied AND its reason carries a Fix:
# with the owner's stop-and-escalate instruction.
check_escalate() {
  if is_deny && printf '%s' "$OUT" | grep -qF 'Fix:' \
    && printf '%s' "$OUT" | grep -qF 'do not work around this; escalate to your admiral with the command + error and wait'; then
    PASS=$((PASS + 1)); printf '  PASS  %s\n' "$1"
  else
    FAIL=$((FAIL + 1)); printf '  FAIL  %s status=%s out=[%s]\n' "$1" "$STATUS" "$OUT"
  fi
}

run "$(bash_json 'gh auth refresh')"
check_escalate "T1. rule 1 (gh auth) deny says escalate"

run "$(bash_json 'glab auth login')"
check_escalate "T2. rule 2 (glab auth) deny says escalate"

run "$(bash_json 'curl -X POST https://gitlab.com/oauth/token')"
check_escalate "T3. rule 3 (oauth token POST) deny says escalate"

run "$(bash_json 'rm ~/.config/gh/hosts.yml')"
check_escalate "T4. rule 4 (credential file write) deny says escalate"

run "$(bash_json '$G auth login')"
check_escalate "T5. rule 5 (expanded command word) deny says escalate"

run_ctx /home/u/.config/gh 'rm hosts.yml'
check_escalate "T6. rule 4c (cwd in a config dir) deny says escalate"

run "$(bash_json 'glab-athena refresh')"
check_escalate "T7. rule 6 (glab-athena refresh) deny says escalate"

echo
echo "==================================================="
printf 'RESULT: %d passed, %d failed\n' "$PASS" "$FAIL"
echo "==================================================="

[ "$FAIL" -eq 0 ] || exit 1
echo "ALL CASES PASS"
exit 0
