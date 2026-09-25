#!/bin/sh
# Self-test for git-stash-guard.sh (DND-670).
#
# Pipes crafted PreToolUse stdin JSON into the hook and asserts its deny/allow
# decision. "deny" means the hook emitted permissionDecision "deny" with a
# reason carrying `Fix:`; "allow" means it emitted nothing.
#
# The incident case is proven end to end against a throwaway fixture: an owner
# repo holding a stash entry, plus a linked worktree of it. The worktree shares
# the owner's stash list (refs/stash lives in the common dir), so an unguarded
# `git stash pop` in the worktree consumes the OWNER's entry (case M1 shows the
# mechanism). With the guard in front, the pop is denied and the owner's stash
# list is byte-identical afterwards (cases W1-W3).
#
# Hermetic: every repo is under a mktemp dir; the global git config is a fixture
# file (GIT_CONFIG_GLOBAL), and system config is ignored (GIT_CONFIG_NOSYSTEM).
# Nothing here touches a real repo's stash.
#
# Exit 0 iff every case passes.

HOOK="$(dirname "$0")/git-stash-guard.sh"
HOOK=$(CDPATH= cd "$(dirname "$HOOK")" && printf '%s/%s' "$(pwd)" "$(basename "$HOOK")")

PASS=0
FAIL=0

TMP=$(mktemp -d) || { echo "FAIL: mktemp"; exit 1; }
trap 'rm -rf "$TMP"' EXIT INT TERM

# Hermetic git identity + config for the fixtures AND for the hook's alias read.
export GIT_CONFIG_NOSYSTEM=1
export GIT_CONFIG_GLOBAL="$TMP/gitconfig"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
cat > "$GIT_CONFIG_GLOBAL" <<'EOF'
[init]
	defaultBranch = main
[alias]
	sp = stash pop
	s = stash
	sl = stash list
	x = !git stash
	y = sp
	st = status
EOF

run() {
  OUT=$(printf '%s' "$1" | sh "$HOOK" 2>/dev/null)
  STATUS=$?
}

is_deny() {
  [ "$STATUS" -eq 0 ] && printf '%s' "$OUT" | grep -q '"permissionDecision":"deny"' \
    && printf '%s' "$OUT" | grep -q '"permissionDecisionReason":"git-stash-guard:' \
    && printf '%s' "$OUT" | grep -q 'Fix:'
}

is_allow() {
  [ "$STATUS" -eq 0 ] && [ -z "$OUT" ]
}

record() {
  if [ "$2" = PASS ]; then
    PASS=$((PASS + 1)); printf '  PASS  %s\n' "$1"
  else
    FAIL=$((FAIL + 1)); printf '  FAIL  %s status=%s out=[%s]\n' "$1" "$STATUS" "$OUT"
  fi
}

# check <label> <deny|allow>
check() {
  if [ "$2" = deny ]; then
    if is_deny; then record "$1 (expected deny)" PASS; else record "$1 (expected deny)" FAIL; fi
  else
    if is_allow; then record "$1 (expected allow)" PASS; else record "$1 (expected allow)" FAIL; fi
  fi
}

# json <cwd> <command>
json() {
  jq -cn --arg d "$1" --arg c "$2" '{tool_name:"Bash",cwd:$d,tool_input:{command:$c}}'
}

# case_cmd <label> <deny|allow> <command> : decided from the fixture worktree.
case_cmd() {
  run "$(json "$WT" "$3")"
  check "$1" "$2"
}

# ---- fixture: owner repo with a stash entry, plus a linked worktree --------
# build_fixture <dir> : owner checkout at <dir>/owner holding one stash entry
# ("OWNER-ENTRY"), worktree at <dir>/wt on its own branch.
build_fixture() {
  mkdir -p "$1"
  git init -q "$1/owner" || return 1
  printf 'base\n' > "$1/owner/f.txt"
  git -C "$1/owner" add f.txt && git -C "$1/owner" commit -q -m init || return 1
  printf 'owner in-flight work\n' > "$1/owner/f.txt"
  git -C "$1/owner" stash push -q -m OWNER-ENTRY || return 1
  git -C "$1/owner" worktree add -q -b captain "$1/wt" || return 1
  # A repo-local alias in the fixture, which the hook must also resolve.
  git -C "$1/owner" config alias.lp 'stash pop'
}

build_fixture "$TMP/a" || { echo "FAIL: fixture a"; exit 1; }
OWNER="$TMP/a/owner"
WT="$TMP/a/wt"

echo "== M: the mechanism the guard exists for (no guard in front) =="
# M1: the fixture reproduces the incident. From the worktree, the stash path is
# the COMMON dir's, and an unguarded pop consumes the owner's entry.
build_fixture "$TMP/m" || { echo "FAIL: fixture m"; exit 1; }
_path=$(cd "$TMP/m/wt" && git rev-parse --path-format=absolute --git-path refs/stash)
case "$_path" in
  "$TMP/m/owner/.git/refs/stash") record "M1a. worktree resolves refs/stash to the owner's common dir" PASS ;;
  *) STATUS=0; OUT=$_path; record "M1a. worktree resolves refs/stash to the owner's common dir" FAIL ;;
esac
(cd "$TMP/m/wt" && git stash pop -q) >/dev/null 2>&1
if [ -z "$(git -C "$TMP/m/owner" stash list)" ] && grep -q 'owner in-flight work' "$TMP/m/wt/f.txt"; then
  record "M1b. unguarded pop in the worktree consumes the OWNER's entry" PASS
else
  STATUS=0; OUT=$(git -C "$TMP/m/owner" stash list); record "M1b. unguarded pop in the worktree consumes the OWNER's entry" FAIL
fi

echo "== W: the incident, with the guard in front =="
BEFORE=$(git -C "$OWNER" stash list; git -C "$OWNER" rev-parse refs/stash)

# guarded <command> : what Claude Code does — run the command in the worktree
# only if the hook allows it.
guarded() {
  run "$(json "$WT" "$1")"
  if is_allow; then (cd "$WT" && sh -c "$1") >/dev/null 2>&1; fi
}

guarded 'git stash pop'
check "W1. git stash pop from the linked worktree" deny
guarded 'git stash'
check "W2. bare git stash from the linked worktree" deny
AFTER=$(git -C "$OWNER" stash list; git -C "$OWNER" rev-parse refs/stash)
if [ "$BEFORE" = "$AFTER" ] && printf '%s' "$AFTER" | grep -q OWNER-ENTRY; then
  record "W3. owner stash list byte-identical after the guarded attempts" PASS
else
  STATUS=0; OUT="before=[$BEFORE] after=[$AFTER]"; record "W3. owner stash list byte-identical after the guarded attempts" FAIL
fi
guarded 'git stash list'
check "W4. git stash list (read-only) is allowed" allow

echo "== D: every mutating form is denied =="
case_cmd "D1. git stash push -m x" deny 'git stash push -m x'
case_cmd "D2. git stash save x" deny 'git stash save x'
case_cmd "D3. git stash apply" deny 'git stash apply'
case_cmd "D4. git stash drop" deny 'git stash drop stash@{0}'
case_cmd "D5. git stash clear" deny 'git stash clear'
case_cmd "D6. git stash store <sha>" deny 'git stash store deadbeef'
case_cmd "D7. git stash branch b" deny 'git stash branch b'
case_cmd "D8. git stash -u (implicit push)" deny 'git stash -u'
case_cmd "D9. git stash -- f.txt (implicit push)" deny 'git stash -- f.txt'
case_cmd "D10. git stash; (bare, then separator)" deny 'git stash; git status'
case_cmd "D11. git stash -q pop (option before the verb)" deny 'git stash -q pop'

echo "== I: the indirection class (DND-390) =="
case_cmd "I1. path-qualified /usr/bin/git" deny '/usr/bin/git stash pop'
case_cmd "I2. git -C <wt> stash" deny "git -C $WT stash pop"
case_cmd "I3. git -c k=v stash" deny 'git -c core.pager=cat stash'
case_cmd "I4. git --git-dir=<d> stash drop" deny "git --git-dir=$OWNER/.git stash drop"
case_cmd "I5. git --work-tree <d> stash (spaced value)" deny "git --work-tree $WT stash"
case_cmd "I6. git --no-pager stash pop" deny 'git --no-pager stash pop'
case_cmd "I7. sh -c 'git stash'" deny "sh -c 'git stash'"
case_cmd "I8. bash -c \"cd x && git stash pop\"" deny 'bash -c "cd /tmp && git stash pop"'
case_cmd "I9. env VAR=x git stash" deny 'env GIT_DIR=x git stash'
case_cmd "I10. command git stash" deny 'command git stash'
case_cmd "I11. xargs git stash drop" deny 'echo | xargs git stash drop'
case_cmd "I12. cd <wt> && git stash" deny "cd $WT && git stash"
case_cmd "I13. a read then a pop in one command" deny 'git stash list; git stash pop'
case_cmd "I14. quote-split subcommand git st\"a\"sh pop" deny 'git st"a"sh pop'
case_cmd "I15. backslash-split command word" deny 'g\it stash'
case_cmd "I16. \$GIT stash pop" deny '$GIT stash pop'
case_cmd "I17. \"\$GIT\" stash" deny '"$GIT" stash'
case_cmd "I18. \${GIT:-git} stash" deny '${GIT:-git} stash'
case_cmd "I19. \$(command -v git) stash pop" deny '$(command -v git) stash pop'
case_cmd "I20. backtick which git stash" deny '`which git` stash'
case_cmd "I21. git \$SUB (expanded subcommand)" deny 'git $SUB'
case_cmd "I22. git-stash binary, path-qualified" deny '/usr/libexec/git-core/git-stash pop'
case_cmd "I23. newline-split command" deny 'echo hi
git stash'
case_cmd "I24. inside a subshell" deny '(cd /tmp; git stash pop)'
case_cmd "I25. nohup git stash" deny 'nohup git stash &'
case_cmd "I26. sudo git stash" deny 'sudo git stash'

echo "== A: aliases =="
case_cmd "A1. configured alias sp = stash pop" deny 'git sp'
case_cmd "A2. configured alias s = stash (bare)" deny 'git s'
case_cmd "A3. configured alias s + pop" deny 'git s pop'
case_cmd "A4. configured shell alias x = !git stash" deny 'git x'
case_cmd "A5. alias chain y -> sp -> stash pop" deny 'git y'
case_cmd "A6. repo-local alias lp = stash pop (cwd repo)" deny 'git lp'
case_cmd "A7. inline -c alias.p=stash" deny 'git -c alias.p=stash p'
case_cmd "A8. inline -c 'alias.p=!git stash pop'" deny "git -c 'alias.p=!git stash pop' p"
case_cmd "A9. defining a stash alias with git config" deny 'git config --global alias.p "stash pop"'
case_cmd "A10. alias through git -C <owner>" deny "git -C $OWNER sp"
case_cmd "A11. configured read-only alias sl = stash list" allow 'git sl'
case_cmd "A12. configured alias s + list" allow 'git s list'
case_cmd "A13. unrelated alias st = status" allow 'git st'

echo "== R: stash refs written without the stash subcommand =="
case_cmd "R1. git update-ref -d refs/stash" deny 'git update-ref -d refs/stash'
case_cmd "R2. git reflog delete refs/stash@{0}" deny 'git reflog delete refs/stash@{0}'
case_cmd "R3. git reflog expire on refs/stash" deny 'git reflog expire --expire=now refs/stash'
case_cmd "R4. rm the stash reflog file" deny "rm $OWNER/.git/logs/refs/stash"
case_cmd "R5. redirect into refs/stash" deny "echo x > $OWNER/.git/refs/stash"
case_cmd "R6. read the stash path (no write)" allow 'git rev-parse --git-path refs/stash'

echo "== OK: reads and unrelated commands are allowed =="
case_cmd "OK1. git stash list" allow 'git stash list'
case_cmd "OK2. git stash show -p stash@{0}" allow 'git stash show -p stash@{0}'
case_cmd "OK3. git stash create (object only, no ref)" allow 'git stash create'
case_cmd "OK4. git -C <owner> stash list" allow "git -C $OWNER stash list"
case_cmd "OK5. git show stash@{0}" allow 'git show stash@{0}'
case_cmd "OK6. git status" allow 'git status'
case_cmd "OK7. git commit -F msg" allow 'git commit -F /tmp/msg'
case_cmd "OK8. a word containing stash" allow 'echo stashing; ls stashes'
case_cmd "OK9. git log --grep=stash" allow 'git log --grep=stash'
case_cmd "OK10. rebase --autostash (out of scope, see header)" allow 'git rebase --autostash origin/main'

echo "== T: the deny text =="
run "$(json "$WT" 'git stash pop')"
if printf '%s' "$OUT" | grep -q 'git worktree add' && printf '%s' "$OUT" | grep -q 'commit'; then
  record "T1. Fix: names a WIP commit and git worktree add" PASS
else
  record "T1. Fix: names a WIP commit and git worktree add" FAIL
fi

echo "== F: fail-open =="
run ''
check "F1. empty stdin" allow
run 'not json'
check "F2. unparseable stdin" allow
run '{"tool_name":"Bash","tool_input":'
check "F3. truncated JSON" allow
run '{"tool_name":"Write","tool_input":{"content":"git stash pop"}}'
check "F4. non-Bash tool" allow
run "$(jq -cn --arg c 'git stash pop' '{tool_name:"Bash",tool_input:{command:$c}}')"
check "F5. no cwd in the input still denies the pop" deny
run "$(json /nonexistent/dir 'git sp')"
check "F6. cwd outside any repo still resolves global aliases" deny

echo
echo "==================================================="
printf 'RESULT: %d passed, %d failed\n' "$PASS" "$FAIL"
echo "==================================================="
[ "$FAIL" -eq 0 ] || { echo "VERDICT: FAIL"; exit 1; }
echo "ALL CASES PASS"
echo "VERDICT: PASS"
exit 0
