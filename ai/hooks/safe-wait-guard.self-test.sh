#!/bin/sh
# Self-test for safe-wait-guard.sh.
#
# Pipes crafted PreToolUse stdin JSON into the hook and asserts the deny/allow
# behavior described in the spec. Hermetic: no network, no state mutation, one
# trap-removed temp dir (the impostor send-mail), nothing outside the hook's own
# tree + jq + realpath.
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

# run_home <home> <json> : run with HOME overridden
run_home() {
  OUT=$(printf '%s' "$2" | HOME=$1 sh "$HOOK" 2>/dev/null)
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
  jq -cn --arg c "$1" --arg d "$REPO" '{tool_name:"Bash",cwd:$d,tool_input:{command:$c}}'
}

# The heredoc exemption pins send-mail by realpath against the hook's tree, and
# resolves a relative command word against the event's `cwd` (this repo root).
REPO=$(CDPATH= cd "$(dirname "$HOOK")/../.." && pwd)
SM=ai/skills/athena:inbox/bin/send-mail
# One scratch dir for the impostor case, removed on exit.
TMPD=$(mktemp -d) || { echo "FAIL: mktemp"; exit 1; }
trap 'rm -rf "$TMPD"' EXIT INT TERM

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

# `grep -v $$` does NOT exclude the waiter: the Bash tool runs `zsh -c
# '<command>'`, and the forked pipeline/substitution children carry that same
# argv (pattern included) under pids other than $$. Measured 2026-09-25: this
# exact loop never exits with no target process alive (DND-589, DND-541).
run "$(bash_json 'while pgrep -f "mypattern" | grep -v $$; do sleep 1; done')"
check "4b. pgrep -f wait with grep -v \$\$ still self-matches" deny

run "$(bash_json 'while pgrep -x beam.smp >/dev/null; do sleep 5; done')"
check "M9. pgrep -x (comm match, cannot self-match) wait" allow

run "$(bash_json 'for f in *.txt; do process "$f"; done')"
check "M10. plain for loop, not backgrounded" allow

run "$(bash_json 'for i in 1 2; do echo hi; done && echo ok')"
check "M11. done && (logical AND, not backgrounding)" allow

run "$(bash_json 'pgrep -f mypattern')"
check "M12. one-off pgrep -f, no loop" allow

echo
echo "--- HEREDOC cases (only a one-line send-mail shape is exempt) ---"

# ALLOW: the exact allow-listed shapes. H1 is the measured false positive.
run "$(bash_json "$SM agent-mail note --to walt_ui <<'EOF'
The PT-919 example was \`(while :; do :; done) &\` with no reaper.
EOF")"
check "H1. spin text in a quoted heredoc fed to send-mail" allow

run "$(bash_json "cat <<'EOF' | $SM agent-mail note --to walt_ui
while pgrep -f \"x\"; do :; done
EOF")"
check "H2. cat <<'EOF' | send-mail (literal path)" allow

run "$(bash_json "$(printf "$SM c s --to x <<-'EOF'\n\twhile :; do :; done\n\tEOF")")"
check "H3. send-mail <<-'EOF' with tab-indented terminator" allow

run "$(bash_json "$SM c s <<\"EOF\"
while :; do :; done
EOF")"
check "H3b. double-quoted delimiter" allow

run "$(bash_json "$SM c s <<\\EOF
while :; do :; done
EOF")"
check "H3c. backslash-quoted delimiter" allow

run "$(bash_json "$SM \$CHAN s --to \${WHO} <<'EOF'
while :; do :; done
EOF")"
check "H3d. \$VAR and \${VAR} arguments" allow

mkdir -p "$TMPD/home" && ln -s "$REPO" "$TMPD/home/tree"
run_home "$TMPD/home" "$(bash_json "~/tree/$SM c s <<'EOF'
while :; do :; done
EOF")"
check "H3e. ~/ path resolved against HOME" allow

# DENY: an owner or consumer that is not the allow-listed shape.
run "$(bash_json "bash <<'EOF'
while :; do :; done
EOF")"
check "H4. owner bash" deny

run "$(bash_json "cat <<'EOF'
while :; do :; done
EOF")"
check "H5. cat alone (not allow-listed)" deny

run "$(bash_json "cat <<'EOF' | at now
while :; do :; done
EOF")"
check "H6. cat piped to at (a runner off any deny-list)" deny

run "$(bash_json "cat <<'EOF' | tee /tmp/r
while :; do :; done
EOF")"
check "H7. cat piped to tee" deny

run "$(bash_json "cat <<'EOF' | bash5
while :; do :; done
EOF")"
check "H8. cat piped to a renamed shell" deny

run "$(bash_json "git commit -m \"\$(cat <<'EOF'
while :; do :; done
EOF
)\"")"
check "H9. heredoc inside \$(...) (not allow-listed)" deny

run "$(bash_json "$SM c s --to x <<'EOF' 1>/tmp/r
while :; do :; done
EOF")"
check "H10. send-mail with a 1> redirect" deny

run "$(bash_json "$SM c s --to x <<'EOF' | sh
while :; do :; done
EOF")"
check "H11. send-mail piped onward into sh" deny

run "$(bash_json "xsend-mail c s <<'EOF'
while :; do :; done
EOF")"
check "H12. command merely ending in send-mail" deny

run "$(bash_json "bash <<'EOF' | $SM c s --to x
while :; do :; done
EOF")"
check "H12b. a shell (not cat) producing into send-mail" deny

run "$(bash_json 'bash${IFS}-s${IFS}/send-mail c s <<'"'"'EOF'"'"'
while :; do :; done
EOF')"
check "H12c. \${IFS} expansion turns the command word into bash -s" deny

run "$(bash_json '$X/send-mail c s <<'"'"'EOF'"'"'
while :; do :; done
EOF')"
check "H12d. unquoted \$VAR in the command word (can word-split)" deny

run "$(bash_json '{bash,-s}/send-mail c s <<'"'"'EOF'"'"'
while :; do :; done
EOF')"
check "H12e. brace expansion in the command word" deny

run "$(bash_json '/*/send-mail c s <<'"'"'EOF'"'"'
while :; do :; done
EOF')"
check "H12f. glob in the command word" deny

# DENY: the quoting, termination and one-line rules.
run "$(bash_json "$SM"' c s --to x <<EOF
$(while :; do :; done)
EOF')"
check "H13. unquoted delimiter (body would expand)" deny

run "$(bash_json "$SM c s --to x <<'EOF'
while :; do :; done")"
check "H14. unterminated heredoc" deny

run "$(bash_json "$SM c s --to x <<'EOF'
quoted text only
EOF
while :; do :; done")"
check "H15. real spin loop after the terminator" deny

run "$(bash_json "$SM c s --to x <<'EOF'
while :; do :; done
EOF
bash /tmp/r")"
check "H16. a second command after the terminator" deny

run "$(bash_json "cd /tmp
$SM c s --to x <<'EOF'
while :; do :; done
EOF")"
check "H17. a command line before the heredoc" deny

run "$(bash_json "$SM c s <<'A' <<'B'
while :; do :; done
A
x
B")"
check "H18. two heredocs on one command" deny

# DENY: the guard's parse must match bash's (delimiter word, continuation,
# quotes, comments). Each shape makes bash end or skip the heredoc elsewhere.
run "$(bash_json "$SM c s <<'EOF'x
EOFx
while :; do :; done
EOF")"
check "H21. chars attached to a quoted delimiter ('EOF'x is EOFx)" deny

run "$(bash_json "$SM c s <<'EO'F
EOF
while :; do :; done
EO")"
check "H22. split-quoted delimiter ('EO'F is EOF)" deny

run "$(bash_json "$SM"' c s <<\E\OF
EOF
while :; do :; done
E')"
check "H23. backslash-split delimiter (\\E\\OF is EOF)" deny

run "$(bash_json "$SM c s <<'EOF' \\
; while :; do :; done
EOF")"
check "H24. trailing backslash continues the command into the body" deny

run "$(bash_json "$SM \"c <<'EOF'
\" ; while :; do :; done
EOF")"
check "H25. quote left open into the body lines" deny

run "$(bash_json "$SM c s # <<'EOF'
while :; do :; done
EOF")"
check "H26. # comment hides the heredoc from bash" deny

run "$(bash_json "$SM c s --re 'a b' --to \"walt_ui\" <<'EOF'
while :; do :; done
EOF")"
check "H27. any quoted arg on the operator line (refused, parse by construction)" deny

run "$(bash_json "$SM c '<<\"EOF\" ' x
while :; do :; done
EOF")"
check "H27b. << inside a closed single quote is not a heredoc to bash" deny

run "$(bash_json "$SM c \"<<'EOF' \" x
while :; do :; done
EOF")"
check "H27c. << inside a closed double quote is not a heredoc to bash" deny

run "$(bash_json "cat '<<\"EOF\" ' | $SM c s
while :; do :; done
EOF")"
check "H27d. cat form with << inside a quote" deny

run "$(bash_json "$SM c @HEREDOC@ <<'EOF'
while :; do :; done
EOF")"
check "H27e. a literal @HEREDOC@ token typed in the args" deny

# The command word must resolve to THIS tree's send-mail, not just share its name.
run "$(bash_json "ai/hooks/../skills/athena:inbox/bin/send-mail c s <<'EOF'
while :; do :; done
EOF")"
check "H28. non-canonical path to the same send-mail (realpath match)" allow

mkdir -p "$TMPD/bin" && ln -s /bin/sh "$TMPD/bin/send-mail"
run "$(bash_json "$TMPD/bin/send-mail c s <<'EOF'
while :; do :; done
EOF")"
check "H29. a shell symlinked as send-mail elsewhere (impostor)" deny

run "$(bash_json "send-mail c s <<'EOF'
while :; do :; done
EOF")"
check "H30. bare send-mail resolved through PATH" deny

run "$(bash_json "\"\$SKILL/bin/send-mail\" c s <<'EOF'
while :; do :; done
EOF")"
check "H31. \$VAR path to send-mail (unresolvable here)" deny

run "$(jq -cn --arg c "$SM c s <<'EOF'
while :; do :; done
EOF" '{tool_name:"Bash",tool_input:{command:$c}}')"
check "H32. relative send-mail with no cwd in the event" deny

run "$(bash_json 'bash -c '"'"'while :; do :; done'"'"'')"
check "H19. bash -c spin loop (no heredoc)" deny

run "$(bash_json "$SM"' c s --to x <<<"while :; do :; done"')"
check "H20. here-string (<<<) is never exempt" deny

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
