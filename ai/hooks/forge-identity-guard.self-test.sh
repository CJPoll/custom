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
mkrepo gl_https 'https://gitlab.com/g/r.git'
mkrepo gh_glpush 'https://github.com/o/r.git'
git -C "$TMP/gh_glpush" config remote.origin.pushurl 'git@gitlab.com:g/r.git'
mkrepo local "$TMP/bare.git"
mkrepo gl_ghpush 'git@gitlab.com:g/r.git'
git -C "$TMP/gl_ghpush" config remote.origin.pushurl 'git@github.com:o/r.git'
mkdir -p "$TMP/norepo"
mkrepo gopath "$TMP/go/src/github.com/o/r.git"

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

run "$(bash_json_cwd "$TMP/norepo" "git -C $TMP/local push origin HEAD; git -C $TMP/gh_scp push origin HEAD")"
check_text "3m. two pushes, the SECOND to github -> warns (every push examined)" 'to a github.com remote'

run "$(bash_json_cwd "$TMP/norepo" "git -C $TMP/gl push origin HEAD; git -C $TMP/gh_scp push origin HEAD")"
check_text "3m2. gitlab push then github push -> the gitlab warn does not hide the github one" 'to a github.com remote'
check_text "3m3. ...and the gitlab one is reported too" 'to a gitlab.com remote'

run "$(bash_json_cwd "$TMP" 'cd gh_scp && git push')"
check_text "3n. relative cd resolved against the input cwd" 'to a github.com remote'

run "$(bash_json_cwd "$TMP/gh_scp" "$(printf 'git push\necho done')")"
check_text "3o. multi-line: push's args end at its line (origin=github still warns)" 'to a github.com remote'

run "$(bash_json_cwd "$TMP/gh_scp" 'git push orgin HEAD')"
check_text "3p. a target that is neither a remote nor a URL -> could-not-resolve warn" 'could not resolve its remote'

run "$(bash_json_cwd "$TMP/gh_scp" 'git push origin HEAD')"
check_text "3j. push warn carries the escalate Fix:" 'Fix: push through the wrapper'
check_text "3k. push warn says escalate to your admiral" 'escalate to your admiral with the command + error and wait'

run "$(bash_json 'gh pr create --fill')"
check_text "3l. create warn carries the escalate clause" 'escalate to your admiral with the command + error and wait'

echo
echo "--- GitLab push cases (DND-393) ---"

run "$(bash_json_cwd "$TMP/gl" 'git push origin HEAD')"
check "G1. plain git push, origin git@gitlab.com: (cwd)" warn
check_text "G1a. gitlab push warn names gitlab.com" 'to a gitlab.com remote'
check_text "G1b. gitlab push warn points at glab-athena git" '~/dev/custom/ai/bin/glab-athena git push'
check_text "G1c. gitlab push warn carries the escalate Fix:" 'escalate to your admiral with the command + error and wait'

run "$(bash_json_cwd "$TMP/gl_https" 'git push')"
check_text "G2. plain git push, default remote -> https gitlab origin" 'to a gitlab.com remote'

run "$(bash_json_cwd "$TMP/norepo" "git -C $TMP/gl push -u origin HEAD")"
check_text "G3. git -C <gitlab repo> push -u from another dir" 'to a gitlab.com remote'

run "$(bash_json_cwd "$TMP/local" 'git push ssh://git@gitlab.com/g/r.git HEAD')"
check_text "G4. git push to a literal ssh://git@gitlab.com URL" 'to a gitlab.com remote'

run "$(bash_json_cwd "$TMP/gh_glpush" 'git push')"
check_text "G5. github fetch url but a gitlab.com pushurl" 'to a gitlab.com remote'

run "$(bash_json_cwd "$TMP/norepo" 'git push origin HEAD')"
check_text "G6. unresolvable remote names both forges' fixes" 'glab-athena git push'

run "$(bash_json_cwd "$TMP/gl" '~/dev/custom/ai/bin/glab-athena git push origin HEAD')"
check "G7. glab-athena git push (wrapper) -> allow" allow

run "$(bash_json_cwd "$TMP/gl" 'GIT_TERMINAL_PROMPT=0 ~/dev/custom/ai/bin/glab-athena git push -u origin HEAD && echo pushed')"
check "G8. the documented glab-athena push form -> allow" allow

echo
echo "--- DND-397: a wrapper invoked through a shell variable must not warn ---"

run "$(bash_json_cwd "$TMP/gl" 'W=~/dev/custom/ai/bin/glab-athena; "$W" git push origin x')"
check "V1. W=glab-athena; \"\$W\" git push" allow

run "$(bash_json_cwd "$TMP/gh_scp" 'W=~/dev/custom/ai/bin/gh-athena; "$W" git push origin x')"
check "V2. W=gh-athena; \"\$W\" git push" allow

run "$(bash_json_cwd "$TMP/gh_scp" 'W=~/dev/custom/ai/bin/gh-athena; $W git push origin x')"
check "V3. unquoted \$W git push" allow

run "$(bash_json_cwd "$TMP/gl" 'W="$HOME/dev/custom/ai/bin/glab-athena" && GIT_TERMINAL_PROMPT=0 "${W}" git push -u origin x')"
check "V4. \${W} with a quoted \$HOME assignment" allow

run "$(bash_json_cwd "$TMP/gh_scp" 'export GHA=~/dev/custom/ai/bin/gh-athena; "$GHA" git -c credential.helper= push origin x')"
check "V5. export-assigned var, global options before push" allow

echo
echo "--- DND-397: a REAL plain push must still warn ---"

run "$(bash_json_cwd "$TMP/gh_scp" "bash -c 'git push origin HEAD'")"
check_text "R1. bash -c '<push>' still warns" 'to a github.com remote'

run "$(bash_json_cwd "$TMP/norepo" "sh -c \"cd $TMP/gh_scp && git push\"")"
check_text "R2. sh -c \"cd <gh repo> && git push\" still warns" 'to a github.com remote'

run "$(bash_json_cwd "$TMP/gh_scp" "$(printf "bash <<'EOF'\ngit push origin HEAD\nEOF")")"
check_text "R3. heredoc fed to bash still warns" 'to a github.com remote'

run "$(bash_json_cwd "$TMP/gh_scp" "$(printf "cat <<'EOF' | sh\ngit push origin HEAD\nEOF")")"
check_text "R4. heredoc piped into sh still warns" 'to a github.com remote'

run "$(bash_json_cwd "$TMP/gh_scp" "$(printf 'python3 - <<EOF\nx = \"$(git push origin HEAD)\"\nEOF')")"
check_text "R5. unquoted-delimiter heredoc whose body runs \$(git push) still warns" 'to a github.com remote'

run "$(bash_json_cwd "$TMP/gh_scp" 'echo "$(git push origin HEAD)"')"
check_text "R6. \$(git push) inside a double-quoted string still warns" 'to a github.com remote'

run "$(bash_json_cwd "$TMP/gh_scp" 'eval "git push origin HEAD"')"
check_text "R7. eval \"git push ...\" still warns" 'to a github.com remote'

run "$(bash_json_cwd "$TMP/gh_scp" "echo 'git push' ; git push origin HEAD")"
check_text "R8. a quoted mention AND a real push -> the real one warns" 'to a github.com remote'

run "$(bash_json_cwd "$TMP/gh_scp" "$(printf "cat > f <<'EOF'\ngit push\nEOF\ngit push origin HEAD")")"
check_text "R9. a real push AFTER a heredoc's terminator still warns" 'to a github.com remote'

run "$(bash_json_cwd "$TMP/gh_scp" 'git push "origin" HEAD')"
check_text "R10. a quoted one-word remote still resolves" 'to a github.com remote'

run "$(bash_json_cwd "$TMP/norepo" "git -C \"$TMP/gh_scp\" push origin HEAD")"
check_text "R11. a quoted -C dir still resolves" 'to a github.com remote'

run "$(bash_json_cwd "$TMP/gh_scp" 'W=~/dev/custom/ai/bin/gh-athena; git push origin HEAD')"
check_text "R12. a wrapper var is assigned but the push is plain -> warns" 'to a github.com remote'

run "$(bash_json_cwd "$TMP/gh_scp" 'X=~/dev/custom/ai/bin/gh-athena; "$W" git push origin HEAD')"
check_text "R13. \$W was never assigned a wrapper -> warns" 'to a github.com remote'

run "$(bash_json_cwd "$TMP/gh_scp" 'W=~/dev/custom/ai/bin/gh-athena; W=/usr/bin/env; "$W" git push origin HEAD')"
check_text "R14. \$W reassigned away from the wrapper -> warns" 'to a github.com remote'

run "$(bash_json_cwd "$TMP/gl" "zsh -c 'git push origin HEAD'")"
check_text "R15. zsh -c '<push>' to gitlab still warns" 'to a gitlab.com remote'

run "$(bash_json_cwd "$TMP/norepo" "$(printf "python3 - <<'EOF'\nprint(1)\nEOF\ngit push origin HEAD")")"
check_text "R16. unresolvable real push after a heredoc keeps DND-389's warn" 'could not resolve its remote'

run "$(bash_json_cwd "$TMP/gh_scp" "echo \"\$(bash -c 'git push origin HEAD')\"")"
check_text "R17. a shell nested inside \"\$(…)\" -> nothing masked, still warns" 'to a github.com remote'

run "$(bash_json_cwd "$TMP/gh_scp" "$(printf "git commit -m \"\$(cat <<'EOF'\nmsg\nEOF\n)\" && git push origin HEAD")")"
check_text "R18. a commit-message heredoc then a real push -> warns" 'to a github.com remote'

echo
echo "--- DND-397: a quoted command string run by any runner still warns ---"

run "$(bash_json_cwd "$TMP/gh_scp" '$SHELL -c "git push origin HEAD"')"
check_text "C1. \$SHELL -c \"<push>\"" 'to a github.com remote'

run "$(bash_json_cwd "$TMP/gh_scp" 'x=bash; $x -c "git push origin HEAD"')"
check_text "C2. x=bash; \$x -c \"<push>\"" 'to a github.com remote'

run "$(bash_json_cwd "$TMP/gh_scp" 'script -qc "git push origin HEAD" /dev/null')"
check_text "C3. script -qc \"<push>\"" 'to a github.com remote'

run "$(bash_json_cwd "$TMP/gh_scp" 'flock /tmp/l -c "git push origin HEAD"')"
check_text "C4. flock <lock> -c \"<push>\"" 'to a github.com remote'

run "$(bash_json_cwd "$TMP/gh_scp" 'tmux new-window "git push origin HEAD"')"
check_text "C5. tmux new-window \"<push>\"" 'to a github.com remote'

run "$(bash_json_cwd "$TMP/gh_scp" "node -e \"require('child_process').execSync('git push origin HEAD')\"")"
check_text "C6. an unlisted interpreter's code string (node -e)" 'to a github.com remote'

run "$(bash_json_cwd "$TMP/gh_scp" "$(printf "cat > s.sh <<'EOF'\ngit push origin HEAD\nEOF\nchmod +x s.sh && ./s.sh")")"
check_text "C7. heredoc writes a script, ./s.sh runs it" 'to a github.com remote'

run "$(bash_json_cwd "$TMP/gh_scp" "git -c 'alias.p=!git push origin HEAD' p")"
check_text "C8. git -c '<alias that pushes>' is never masked" 'to a github.com remote'

run "$(bash_json_cwd "$TMP/gh_scp" "echo 'git push origin HEAD' | at now")"
check_text "C9. echo '<push>' | at now" 'to a github.com remote'

run "$(bash_json_cwd "$TMP/gh_scp" 'env -S "git push origin HEAD"')"
check_text "C10. env -S \"<push>\"" 'to a github.com remote'

run "$(bash_json_cwd "$TMP/gh_scp" 'timeout 60 sudo -u me sh -c "git push origin HEAD"')"
check_text "C11. prefixes before a shell" 'to a github.com remote'

run "$(bash_json_cwd "$TMP/gh_scp" 'W=/usr/bin/env; "$W" git push origin HEAD; W=~/dev/custom/ai/bin/gh-athena')"
check_text "C12. a wrapper assigned AFTER the use does not bless it" 'to a github.com remote'

run "$(bash_json_cwd "$TMP/gh_scp" 'W=~/dev/custom/ai/bin/gh-athena; "$W" git push origin x; W=/usr/bin/env; "$W" git push origin HEAD')"
check_text "C13. same var: wrapper use, reassignment, plain use -> the plain one warns" 'to a github.com remote'

echo
echo "--- DND-397: text runners the parked mention-masking missed — must warn ---"

run "$(bash_json_cwd "$TMP/gh_scp" 'git rebase --exec "git push origin HEAD" main')"
check_text "C14. git rebase --exec \"<push>\"" 'to a github.com remote'

run "$(bash_json_cwd "$TMP/gh_scp" 'git rebase -x "git push origin HEAD" main')"
check_text "C15. git rebase -x \"<push>\"" 'to a github.com remote'

run "$(bash_json_cwd "$TMP/gh_scp" 'git submodule foreach "git push origin HEAD"')"
check_text "C16. git submodule foreach \"<push>\"" 'to a github.com remote'

run "$(bash_json_cwd "$TMP/gh_scp" "$(printf "cat <<'EOF' | perl\nsystem(\"git push origin HEAD\")\nEOF")")"
check_text "C17. heredoc piped into perl" 'to a github.com remote'

run "$(bash_json_cwd "$TMP/gh_scp" "echo 'git push origin HEAD' | python3")"
check_text "C18. echo '<push>' | python3" 'to a github.com remote'

run "$(bash_json_cwd "$TMP/gh_scp" "echo 'git push origin HEAD' | awk '{system(\$0)}'")"
check_text "C19. echo '<push>' | awk system" 'to a github.com remote'

run "$(bash_json_cwd "$TMP/gh_scp" "echo 'git push origin HEAD' | sed e")"
check_text "C20. echo '<push>' | sed e" 'to a github.com remote'

run "$(bash_json_cwd "$TMP/gh_scp" "\$(echo 'git push origin HEAD')")"
check_text "C21. \$(echo '<push>') as the command word" 'to a github.com remote'

run "$(bash_json_cwd "$TMP/gh_scp" "\"\$(echo 'git push origin HEAD')\"")"
check_text "C22. \"\$(echo '<push>')\" as the command word" 'to a github.com remote'

run "$(bash_json_cwd "$TMP/gh_scp" "gh alias set --shell p 'git push origin HEAD' && gh p")"
check_text "C23. gh alias set --shell '<push>' (not a DATA subcommand)" 'to a github.com remote'

run "$(bash_json_cwd "$TMP/gh_scp" "git -C . -c 'alias.p=!git push origin HEAD' p")"
check_text "C24. git -C . -c '<alias>' (value before the subcommand)" 'to a github.com remote'

run "$(bash_json_cwd "$TMP/gh_scp" "grep -rn 'git push' . || sh -c 'git push origin HEAD'")"
check_text "C25. || then a shell still warns" 'to a github.com remote'

run "$(bash_json_cwd "$TMP/gh_scp" "git grep -O\"sh -c 'git push origin HEAD'\" x")"
check_text "C26. git grep -O\"<pager that pushes>\"" 'to a github.com remote'

run "$(bash_json_cwd "$TMP/gh_scp" "echo 'git push origin HEAD' > .git/hooks/post-commit && chmod +x .git/hooks/post-commit && git commit -qm x")"
check_text "C27. a hook written by echo, fired by git commit" 'to a github.com remote'

run "$(bash_json_cwd "$TMP/gh_scp" "python3 -c \"import os; os.system('git push origin HEAD')\"")"
check_text "C28. python3 -c running a push" 'to a github.com remote'

run "$(bash_json_cwd "$TMP/gh_scp" '(W=~/dev/custom/ai/bin/gh-athena); $W git push origin HEAD')"
check_text "C29. W set only in a subshell -> the later \$W git push is plain, warns" 'to a github.com remote'

run "$(bash_json_cwd "$TMP/gh_scp" 'W=~/dev/custom/ai/bin/gh-athena true; $W git push origin HEAD')"
check_text "C30. W as a command-prefix assignment does not persist -> warns" 'to a github.com remote'

run "$(bash_json_cwd "$TMP/gh_scp" 'W=~/dev/custom/ai/bin/gh-athena | cat; $W git push origin HEAD')"
check_text "C31. W set in a pipeline element does not persist -> warns" 'to a github.com remote'

run "$(bash_json_cwd "$TMP/gh_scp" 'X=$(W=~/dev/custom/ai/bin/gh-athena; echo); $W git push origin HEAD')"
check_text "C32. W set inside \$( … ) does not persist -> warns" 'to a github.com remote'

run "$(bash_json_cwd "$TMP/gh_scp" 'W=~/dev/custom/ai/bin/gh-athena && (cd . && "$W" git push origin x)')"
check "V6. only the next-statement shape is blessed; a use in a later subshell still warns" warn

run "$(bash_json_cwd "$TMP/gl" "$(printf 'W=~/dev/custom/ai/bin/glab-athena\n"$W" git push origin x')")"
check "V7. newline-separated W=glab-athena then \"\$W\" git push" allow

run "$(bash_json_cwd "$TMP/gh_scp" 'echo W=~/dev/custom/ai/bin/gh-athena; $W git push origin HEAD')"
check_text "C33. W=… as an echo ARGUMENT sets nothing -> warns" 'to a github.com remote'

run "$(bash_json_cwd "$TMP/gh_scp" 'false && W=~/dev/custom/ai/bin/gh-athena; $W git push origin HEAD')"
check_text "C34. a conditional assignment -> warns" 'to a github.com remote'

run "$(bash_json_cwd "$TMP/gh_scp" '(W=~/dev/custom/ai/bin/gh-athena; echo "("); $W git push origin HEAD')"
check_text "C35. subshell assignment with a quoted paren -> warns" 'to a github.com remote'

run "$(bash_json_cwd "$TMP/gh_scp" "W=~/dev/custom/ai/bin/gh-athena; bash -c '\$W git push origin HEAD'")"
check_text "C36. \$W used in a child shell where W is unset -> warns" 'to a github.com remote'

run "$(bash_json_cwd "$TMP/gh_scp" "W=\"\$HOME/dev/custom/ai/bin/gh-athena\" ; \"\$W\" git push origin x ; \$W git -C $TMP/gl push origin HEAD")"
if is_warn_with 'to a gitlab.com remote' && ! is_warn_with 'to a github.com remote'; then
  PASS=$((PASS + 1)); printf '  PASS  %s\n' "C37. the next statement's use is blessed (no github warn); a second use still warns (gitlab)"
else
  FAIL=$((FAIL + 1)); printf '  FAIL  %s status=%s out=[%s]\n' "C37. blessed first use, warned second use" "$STATUS" "$OUT"
fi

run "$(bash_json_cwd "$TMP/gh_scp" "W='~/dev/custom/ai/bin/gh-athena' ; \"\$W\" git push origin HEAD")"
check_text "C38. a single-quoted value (no ~ expansion) is not blessed -> warns" 'to a github.com remote'


run "$(bash_json_cwd "$TMP/gh_scp" "$(printf 'W=~/dev/custom/ai/bin/gh-athena\nW=/usr/bin/env\n"$W" git push origin HEAD')")"
check_text "C39. a reassignment on its own line is a statement, not a prefix -> warns" 'to a github.com remote'

run "$(bash_json_cwd "$TMP/gh_scp" "$(printf 'W=~/dev/custom/ai/bin/gh-athena; "$W"\ngit push origin HEAD')")"
check_text "C40. \"\$W\" then git push on the NEXT line is a plain push -> warns" 'to a github.com remote'

run "$(bash_json_cwd "$TMP/gh_scp" "$(printf 'export\nW=~/dev/custom/ai/bin/gh-athena; "$W" git push origin HEAD')")"
check_text "C41. export on its own line is not part of the assignment -> not blessed, warns" 'to a github.com remote'

run "$(bash_json_cwd "$TMP/gh_scp" "$(printf 'W=~/dev/custom/ai/bin/gh-athena\n\n  GIT_TERMINAL_PROMPT=0 "$W" git push origin x')")"
check "V8. blank line between the assignment and a prefixed use" allow

echo
echo "--- MUST-NOT-WARN cases (wrapper / reads / unrelated) ---"

run "$(bash_json_cwd "$TMP/gh_scp" '~/dev/custom/ai/bin/gh-athena git push origin HEAD')"
check "M7. gh-athena git push (wrapper)" allow

run "$(bash_json_cwd "$TMP/gh_scp" "GIT_TERMINAL_PROMPT=0 ~/dev/custom/ai/bin/gh-athena git -c credential.helper= -c 'url.https://github.com/.insteadOf=git@github.com:' push origin HEAD")"
check "M8. the documented explicit wrapper push form" allow

run "$(bash_json_cwd "$TMP/gl" 'git pull origin main')"
check "M9. git pull from a GitLab remote (not a push)" allow

run "$(bash_json_cwd "$TMP/local" 'git push origin HEAD')"
check "M10. plain git push to a local bare remote" allow

run "$(bash_json_cwd "$TMP/gh_scp" 'git commit -m "push to github.com later"')"
check "M11. git commit whose message says push github.com" allow

run "$(bash_json_cwd "$TMP/gh_scp" 'git log --grep push')"
check "M12. git log --grep push (not a push)" allow

run "$(bash_json_cwd "$TMP/gopath" 'git push origin HEAD')"
check "M13. push to a LOCAL path containing github.com (Go workspace) is not GitHub" allow

run "$(bash_json_cwd "$TMP/gl" 'git push origin fix/github.com-links')"
if is_warn && ! is_warn_with 'to a github.com remote'; then
  PASS=$((PASS + 1)); printf '  PASS  %s\n' "M14. GitLab push of a branch whose NAME mentions github.com -> gitlab warn only, never a github one"
else
  FAIL=$((FAIL + 1)); printf '  FAIL  %s status=%s out=[%s]\n' "M14. branch name mentioning github.com" "$STATUS" "$OUT"
fi

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
