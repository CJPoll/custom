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
check "1d. backgrounded busy-spin (the orphaned-spin-loop shape)" deny

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

# A PID resolved by `pgrep -f` for `tail --pid` is the same self-match with no
# loop around it. With no target alive, `pgrep -f X | head -1` returns the
# waiting `zsh -c` itself (measured 2026-09-30: `pgrep -f <unique> | head -1`
# printed the Bash tool's own zsh), so the tail blocks its full timeout on its
# own shell. With a sibling alive it returns the sibling's process (DND-1330:
# "integration-gate --with-critic" matched another captain's gate).
run "$(bash_json "timeout 590 tail --pid=\$(pgrep -f 'critic-review --base origin/main' | head -1) -f /dev/null")"
check "4c. tail --pid resolved by pgrep -f (command substitution)" deny

run "$(bash_json 'P=$(pgrep -f -o "integration-gate --with-critic"); timeout 600 tail --pid=$P -f /dev/null')"
check "4d. tail --pid on a variable set from pgrep -f -o" deny

run "$(bash_json 'timeout 900 tail --pid=$(pgrep -o -f up-critic.sh) -f /dev/null')"
check "4e. pgrep -o -f (flag after another flag) for tail --pid" deny

run "$(bash_json 'timeout 900 tail --pid=$(pgrep --full up-critic.sh) -f /dev/null')"
check "4f. pgrep --full for tail --pid" deny

run "$(bash_json 'timeout 600 tail --pid=12345 -f /dev/null')"
check "M13. tail --pid on a literal pid" allow

run "$(bash_json 'timeout 600 tail --pid=$(pgrep -x -o beam.smp) -f /dev/null')"
check "M14. tail --pid resolved by pgrep -x (comm match)" allow

run "$(bash_json 'pgrep -f mypattern; tail -n 5 /tmp/gate.log')"
check "M15. pgrep -f next to a tail with no --pid" allow

# Shape 5: the Bash tool runs `zsh -c '<command>'`, so a `pkill -f` pattern that
# matches the command text kills the tool shell (measured 2026-10-02 in a
# zsh -c repro: exit 143 with a literal pattern, survives with `[z]z…`).
run "$(bash_json 'pkill -f inbox-wait')"
check "5a. pkill -f with a literal pattern (matches its own text)" deny

run "$(bash_json 'pkill -TERM -f "critic-review --base origin/main"; echo done')"
check "5b. pkill -TERM -f with a quoted pattern after a signal" deny

run "$(bash_json 'cd /tmp && timeout 5 pkill --full up-critic')"
check "5c. pkill --full after timeout N, in a && list" deny

run "$(bash_json 'echo x; pkill -f -u cjpoll '"'"'jev-wait.*run'"'"'')"
check "5d. pkill -f single-quoted regex that matches its text" deny

run "$(bash_json 'cd /tmp
pkill -f inbox-wait')"
check "5e. pkill -f on line 2 of a multi-line command" deny

run "$(bash_json 'pkill -f inbox-wait -n')"
check "5f. option after the pattern (procps reorders options)" deny

run "$(bash_json 'pkill -f jev-wait -u me')"
check "5g. pkill -f pattern before -u ARG" deny
case $OUT in
  *'`jev-wait`'*) PASS=$((PASS + 1)); echo "  PASS  5g'. the deny names the pattern, not the -u argument" ;;
  *) FAIL=$((FAIL + 1)); echo "  FAIL  5g'. the deny names the pattern, not the -u argument: [$OUT]" ;;
esac

run "$(bash_json 'nohup env A=1 pkill -HUP -f inbox-wait >/dev/null 2>&1')"
check "5h. nohup + env VAR=x wrappers, a signal option and redirects" deny

run "$(bash_json 'git commit -m "then pkill -f foo"; echo "a; pkill -f x"')"
check "M21. separators and keywords inside quoted text are text" allow

run "$(bash_json 'pkill -f "$X" >/dev/null')"
check "M22. a redirect after an unknown pattern is not the pattern" allow

run "$(bash_json 'pkill -f "[i]nbox-wait"')"
check "M16. pkill -f bracket class (cannot match its own text)" allow

run "$(bash_json 'pkill -x inbox-wait')"
check "M17. pkill -x (comm match)" allow

run "$(bash_json 'pkill -f "$PATTERN"')"
check "M18. pkill -f on a variable (pattern unknown)" allow

run "$(bash_json 'git commit -m "never pkill -f the gate"')"
check "M19. pkill -f mentioned inside a quoted message" allow

run "$(bash_json 'kill "$pid"')"
check "M20. kill on a captured pid" allow

# Shape 6 (DND-1706/DND-1708): a default-cadence forge watcher. `gh run watch`
# polls every 3 s and `gh pr checks --watch` every 10 s; several at once
# exhausted the owner's 5000/h GitHub budget on 2026-10-02.
run "$(bash_json 'gh run watch 36983467648')"
check "6a. gh run watch <id>" deny
case $OUT in
  *gh-ci-wait*) PASS=$((PASS + 1)); echo "  PASS  6a'. the deny names the replacement, gh-ci-wait" ;;
  *) FAIL=$((FAIL + 1)); echo "  FAIL  6a'. the deny names the replacement, gh-ci-wait: [$OUT]" ;;
esac

run "$(bash_json 'cd /w && timeout 590 gh pr checks 711 --watch --interval 30 2>&1 | tail -n 15')"
check "6b. gh pr checks --watch behind cd and timeout" deny

run "$(bash_json '~/dev/custom/ai/bin/gh-athena run watch 5 --exit-status')"
check "6c. gh-athena run watch (the App budget is finite too)" deny

run "$(bash_json 'gh pr checks 711 --repo CJPoll/gen_saas --watch')"
check "6d. --watch after --repo" deny

run "$(bash_json 'timeout -k 5 590 gh pr checks 711 --watch')"
check "6e. timeout -k N before the duration" deny

run "$(bash_json 'timeout --signal KILL 590 gh run watch 5')"
check "6f. timeout --signal SIG before the duration" deny

run "$(bash_json 'timeout -k 5 590 pkill -f inbox-wait')"
check "5i. pkill -f behind timeout -k N (shared wrapper parse)" deny

run "$(bash_json 'gh pr checks 711; gh pr view 711 --json headRefOid')"
check "M23. gh pr checks without --watch (one read)" allow

run "$(bash_json 'gh run view 5 --json status')"
check "M24. gh run view (one read)" allow

run "$(bash_json 'printf "never use gh run watch\n" >/dev/null; git commit -m "drop gh pr checks --watch"')"
check "M25. the watcher named inside quoted text" allow

run "$(bash_json 'ai/bin/gh-ci-wait --repo a/b --sha "$SHA" --max 570')"
check "M26. the sanctioned waiter" allow

echo
echo "--- HEREDOC cases (only a one-line send-mail shape is exempt) ---"

# ALLOW: the exact allow-listed shapes. H1 is the measured false positive.
run "$(bash_json "$SM agent-mail note --to walt_ui <<'EOF'
The orphaned-spin-loop example was \`(while :; do :; done) &\` with no reaper.
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
