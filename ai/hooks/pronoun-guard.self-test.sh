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
  OUT=$(printf '%s' "$1" | HOME="$SANDBOX" XDG_STATE_HOME="$SANDBOX/state" sh "$HOOK" 2>/dev/null)
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

# --- Case 7: code tokens are not prose (DND-738) ---
# The pronoun letters glued to a code joiner -- a flag dash, a path slash, a
# variable sigil, a dotted name, an assignment or a call -- are not a word a
# reader sees. `\b` treated them as standalone, so a python edit script that
# carried `grep -hE` was denied (measured: 5 denials, laptop run
# 2026-09-25-laptop-harness, DND-670 captain).
# jq builds these so they may carry quotes, backslashes and newlines.
jbash() { jq -cn --arg c "$1" '{tool_name:"Bash",tool_input:{command:$c}}'; }
jmsg()  { jq -cn --arg m "$1" '{tool_name:"SendMessage",tool_input:{message:$m}}'; }
NL='
'

# The measured command shape: a python heredoc edit carrying `grep -hE`.
run "$(jbash "cd /tmp/wt && python3 - <<'EOF'${NL}p='ai/hooks/x.sh'${NL}s=open(p).read()${NL}o='''  A=\$(find \"\$D\" -name 'snapshot-*.sh' -exec grep -hE '^alias ' {} + 2>/dev/null)'''${NL}s=s.replace(o,o+'# note',1)${NL}open(p,'w').write(s)${NL}EOF")"
check "7a. python edit script with grep -hE -> allow" allow

run "$(jbash "find ~/.claude/shell-snapshots -name 'snapshot-*.sh' -exec grep -hE '^alias ' {} + | wc -c")"
check "7b. grep -hE flag -> allow" allow

run "$(jbash 'ls -He /tmp; tar --his x; cmd -HIM')"
check "7c. -He / --his / -HIM flags -> allow" allow

run "$(jbash 'cat /srv/he/notes /home/him/x ./his')"
check "7d. path segments /he/ /him/ ./his -> allow" allow

run "$(jbash 'echo "$he ${his} $HIM" \he')"
check "7e. variables and escapes \$he \${his} \\he -> allow" allow

run "$(jbash 'python3 -c "he=1; his(x); print(obj.he, he.txt, x.his)"')"
check "7f. identifiers he= his( obj.he he.txt -> allow" allow

run "$(jbash "grep -n -w -i -E 'he|him|his' *.md; python3 -c 's=t[:hs]+b+t[he:]; k=\"he:#{n}\"'")"
check "7g. regex alternation he|him|his, slice [he:], key he:#{n} -> allow" allow

# --- Case 8: prose inside Bash and messages is still caught (DND-738) ---
run "$(jbash 'git commit -m "Cody said he wants this merged"')"
check "8a. commit message with he (double-quoted in JSON) -> deny" deny

run "$(jbash "gh pr create --title x --body 'Ask Cody; his call.'")"
check "8b. PR body with his -> deny" deny

run "$(jbash "gh pr create --body-file - <<'EOF'${NL}Summary${NL}${NL}He approved the plan.${NL}EOF")"
check "8c. heredoc PR body, He at line start -> deny" deny

run "$(jmsg "Cody invoked run-autonomously again. He's away, possibly overnight.")"
check "8d. He's (apostrophe) -> deny" deny

run "$(jmsg "Status:${NL}he approved it")"
check "8e. he at the start of a new line (JSON \\n before it) -> deny" deny

run "$(jmsg "Status:	his review is done")"
check "8f. his after a tab (JSON \\t before it) -> deny" deny

run "$(jmsg 'Ask (him) or *him* or "him", then go.')"
check "8g. him in parens / markdown / quotes -> deny" deny

run "$(jmsg 'Waiting on him: the key is his.')"
check "8h. him: / his. at punctuation -> deny" deny

run "$(jmsg "Waiting on him:${NL}the key")"
check "8h2. him: at the end of a line -> deny" deny

run "$(jmsg 'Cody uses they/them, never he/him')"
check "8i. he/him mention -> deny (conservative: a pronoun list is still prose)" deny

run "$(jmsg 'Cody -- he said -- ok')"
check "8j. he between spaced dashes -> deny" deny

run '{"tool_name":"mcp__notion-personal__API-patch-page","tool_input":{"properties":{"Notes":{"rich_text":[{"text":{"content":"He will review."}}]}}}}'
check "8k. nested Notion write value -> deny" deny

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

# ---- registration: the guard fires on EVERY tool (DND-932) ----
# pronoun-guard.sh never checks the tool name, so its registry matcher IS its
# scope. Owner decision (Cody, 2026-09-27 ~10:20Z): "the pronoun blocker should
# block on all write-tools, not just notion. If it's easier to keep to that
# intent, we can just have it fire on all tools, not just specific known
# tools." So: ONE PreToolUse row, matcher "*" (Claude Code's match-all), and no
# second row for the same script, which would double-fire.
REGISTRY="$(dirname "$HOOK")/registry.json"
if REG_OUT=$(REGISTRY="$REGISTRY" python3 - 2>&1 <<'PY'
import json, os, sys
rows = [(e["event"], e.get("matcher")) for e in json.load(open(os.environ["REGISTRY"]))["hooks"]
        if e["script"] == "ai/hooks/pronoun-guard.sh"]
sys.exit(0 if rows == [("PreToolUse", "*")] else
         "pronoun-guard rows are %r, want exactly [('PreToolUse', '*')]" % rows)
PY
); then
  PASS=$((PASS + 1)); printf '  PASS  %s\n' "9a. registry: one pronoun-guard row, PreToolUse, matcher \"*\" (every tool)"
else
  FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "9a. registry: one pronoun-guard row, PreToolUse, matcher \"*\" (every tool)"
  echo "      $REG_OUT"
  echo "      Fix: replace every pronoun-guard row in ai/hooks/registry.json with one {\"event\": \"PreToolUse\", \"matcher\": \"*\"} row (owner decision, DND-932)."
fi

# The installer writes that row as ONE match-all wiring. Installed from a
# fixture repo that is its own main checkout (setup-hooks wires only scripts
# the main checkout has, DND-743), so this runs the same from any worktree.
REPO_ROOT="$(CDPATH= cd "$(dirname "$HOOK")/../.." && pwd -P)"
FIXTURE="${SANDBOX}/hooks-fixture"
INSTALL_OUT=$(
  . "${REPO_ROOT}/ai/test/lib/landed-fixture.bash" &&
  landed_fixture "$REPO_ROOT" "$FIXTURE" scripts/setup-hooks scripts/lib/main-checkout.sh ai/bin/check-hooks-registered ai/lib/landed.rb ai/lib/strict_argv.rb ai/hooks &&
  printf '{}\n' > "${SANDBOX}/installed.json" &&
  HOOKS_SETTINGS_FILE="${SANDBOX}/installed.json" "${FIXTURE}/scripts/setup-hooks" --install 2>&1 &&
  SETTINGS="${SANDBOX}/installed.json" python3 - <<'PY'
import json, os, sys
s = json.load(open(os.environ["SETTINGS"]))
w = [(ev, g.get("matcher")) for ev, gs in s.get("hooks", {}).items() for g in gs
     for h in g.get("hooks", []) if h.get("command", "").endswith("/pronoun-guard.sh")]
sys.exit(0 if w == [("PreToolUse", "*")] else "installed pronoun-guard wirings: %r" % w)
PY
) 2>&1
if [ $? -eq 0 ]; then
  PASS=$((PASS + 1)); printf '  PASS  %s\n' "9b. setup-hooks installs exactly one match-all pronoun-guard wiring"
else
  FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "9b. setup-hooks installs exactly one match-all pronoun-guard wiring"
  printf '%s\n' "$INSTALL_OUT" | tail -3 | sed 's/^/      /'
fi

# --- Case 10: any tool's input shape (it now runs on every tool) ---
run '{"tool_name":"Read","tool_input":{"file_path":"/home/x/src/app.ex","offset":10,"limit":50}}'
check "10a. Read of a plain path -> allow" allow
run '{"tool_name":"Grep","tool_input":{"pattern":"did he say","path":"docs","-i":true}}'
check "10b. Grep pattern with prose he -> deny" deny
run '{"tool_name":"Edit","tool_input":{"file_path":"a.md","old_string":"They said","new_string":"he said it was done"}}'
check "10c. Edit new_string with prose he -> deny" deny
run '{"tool_name":"Write","tool_input":{"file_path":"notes.md","content":"Meeting notes\n\nhis PR landed"}}'
check "10d. Write content with a line-initial his -> deny" deny
run '{"tool_name":"mcp__x__y","tool_input":{"a":{"b":[1,true,null,{"c":["ask him first"]}]},"n":3.5}}'
check "10e. unknown mcp__x__y, pronoun nested in arrays/objects -> deny" deny
run '{"tool_name":"mcp__x__y","tool_input":{"a":[1,2,{"b":false}],"c":null}}'
check "10f. unknown tool with no strings at all -> allow" allow
run '{"tool_name":"mcp__x__y","tool_input":"he wrote a bare string input"}'
check "10g. a bare-string tool_input is scanned -> deny" deny

# Malformed input fails OPEN and leaves a note with a Fix: in the guard's log.
LOG="${SANDBOX}/state/athena/pronoun-guard.log"
rm -f "$LOG"
run '{"tool_name":"Bash","tool_input":{"command":"echo he'
if is_allow && grep -q 'unparseable' "$LOG" 2>/dev/null && grep -q 'Fix:' "$LOG" 2>/dev/null; then
  PASS=$((PASS + 1)); printf '  PASS  %s\n' "10h. malformed JSON -> allow, logged with a Fix:"
else
  FAIL=$((FAIL + 1)); printf '  FAIL  %s status=%s out=[%s] log=[%s]\n' "10h. malformed JSON -> allow, logged with a Fix:" "$STATUS" "$OUT" "$(cat "$LOG" 2>/dev/null)"
fi

# Huge input: never an error, never truncated. The whole input is scanned
# (no cap: a cap would stop catching prose the guard caught before).
HUGE="${SANDBOX}/huge.json"
python3 - "$HUGE" <<'PY'
import json, sys
json.dump({"tool_name": "Write", "tool_input": {"file_path": "big.txt",
           "content": "he said " + "x" * (6 * 1024 * 1024)}}, open(sys.argv[1], "w"))
PY
rm -f "$LOG"
# DND-1356: no wall-clock verdict (the owner's functional-tests rule). This
# used to require the deny within 5 s, a verdict that flips on a slow host.
# What it guards is that a huge input is finished, not hung: `timeout` only
# caps a hang (exit 124 is a FAIL named as such), and the verdict is the deny
# with nothing on stderr (no E2BIG, no truncated scan).
OUT=$(HOME="$SANDBOX" XDG_STATE_HOME="$SANDBOX/state" timeout 120 sh "$HOOK" < "$HUGE" 2>"${SANDBOX}/huge.err"); STATUS=$?
if [ "$STATUS" -ne 124 ] && is_deny && [ ! -s "${SANDBOX}/huge.err" ]; then
  PASS=$((PASS + 1)); printf '  PASS  %s\n' "10i. 6 MiB input, pronoun at the start -> deny, no stderr, never a hang"
else
  FAIL=$((FAIL + 1)); printf '  FAIL  %s status=%s%s err=[%s] out=[%s]\n' "10i. 6 MiB input, pronoun at the start -> deny, no stderr, never a hang" "$STATUS" "$([ "$STATUS" -eq 124 ] && printf ' (hung: killed by the 120 s hang cap)')" "$(head -c 200 "${SANDBOX}/huge.err")" "$(printf '%s' "$OUT" | head -c 80)"
fi
python3 - "$HUGE" <<'PY'
import json, sys
json.dump({"tool_name": "Write", "tool_input": {"file_path": "big.txt",
           "content": "x " * (400 * 1024) + "and then he left"}}, open(sys.argv[1], "w"))
PY
OUT=$(HOME="$SANDBOX" XDG_STATE_HOME="$SANDBOX/state" sh "$HOOK" < "$HUGE" 2>/dev/null); STATUS=$?
check "10j. pronoun at the END of an 800 KiB input -> deny (the whole text is scanned)" deny
python3 - "$HUGE" <<'PY'
import json, sys
json.dump({"tool_name": "Write", "tool_input": {"file_path": "big.txt",
           "content": "he left early\n" + "x " * (400 * 1024)}}, open(sys.argv[1], "w"))
PY
OUT=$(HOME="$SANDBOX" XDG_STATE_HOME="$SANDBOX/state" sh "$HOOK" < "$HUGE" 2>/dev/null); STATUS=$?
check "10k. 800 KiB input, pronoun at the start -> deny" deny

# Binary-ish content (NUL and control bytes in a JSON string) never errors:
# NULs are dropped, grep -a reads every other byte as text.
OUT=$(printf '%s' '{"tool_name":"Write","tool_input":{"content":"\u0000\u0001ÿ bytes\u0000 then he spoke"}}' \
      | HOME="$SANDBOX" XDG_STATE_HOME="$SANDBOX/state" sh "$HOOK" 2>"${SANDBOX}/bin.err"); STATUS=$?
if is_deny && [ ! -s "${SANDBOX}/bin.err" ]; then
  PASS=$((PASS + 1)); printf '  PASS  %s\n' "10l. NUL/control bytes in a string -> scanned, no stderr (deny)"
else
  FAIL=$((FAIL + 1)); printf '  FAIL  %s status=%s out=[%s] err=[%s]\n' "10l. NUL/control bytes in a string -> scanned, no stderr (deny)" "$STATUS" "$OUT" "$(head -c 200 "${SANDBOX}/bin.err")"
fi

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
