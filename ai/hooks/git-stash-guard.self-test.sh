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
# A fixture Bash-tool shell snapshot, holding oh-my-zsh style shell aliases.
export CLAUDE_CONFIG_DIR="$TMP/claude"
mkdir -p "$CLAUDE_CONFIG_DIR/shell-snapshots"
cat > "$CLAUDE_CONFIG_DIR/shell-snapshots/snapshot-zsh-1-fixture.sh" <<'EOF'
alias -- ll='ls -l'
alias -- gstp='git stash pop'
alias -- gstl='git stash list'
alias -- g=git
alias -- gsp2=gstp
alias -- gst='git status'
alias -g GSP='stash pop'
alias -s stashfile='git stash apply'
EOF
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
	z = -c color.ui=never stash pop
	np = --no-pager stash
	npl = --no-pager stash list
	x2 = !git sp
	x3 = !git st"a"sh pop
	x4 = !git status
	rx = reflog expire --expire=now
	c1 = c2
	c2 = c3
	c3 = c4
	c4 = c5
	c5 = c6
	c6 = c7
	c7 = c8
	c8 = c9
	c9 = c10
	c10 = c11
	c11 = c12
	c12 = stash pop
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
guarded "git reflog delete 'stash@{0}'"
check "W2a. reflog delete stash@{0} from the linked worktree" deny
guarded 'git reflog expire --expire=now stash'
check "W2b. reflog expire stash from the linked worktree" deny
guarded 'git reflog expire --expire=now --all'
check "W2c. reflog expire --all from the linked worktree" deny
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
case_cmd "I27. git --attr-source <tree> stash pop (two-word option)" deny 'git --attr-source HEAD stash pop'
case_cmd "I28. an unknown two-word option before stash" deny 'git --some-future-opt val stash pop'
case_cmd "I29. \$GIT with an unknown two-word option" deny '$GIT --some-future-opt val stash'
case_cmd "I30. unknown option then a read" allow 'git --some-future-opt val stash list'
case_cmd "I31. -C with a quoted dir holding a space" deny 'git -C "/tmp/a b" stash pop'
case_cmd "I32. -c with a quoted value holding a space" deny 'git -c "user.name=A B" stash pop'
case_cmd "I33. --git-dir= with a quoted space" deny 'git --git-dir="/x y/.git" stash drop'
case_cmd "I34. -c k=\"v w\" (quote mid-word)" deny 'git -c core.editor="code --wait" stash'
case_cmd "I35. nested quotes inside bash -c" deny 'bash -c "git -c \"k=v w\" stash pop"'
case_cmd "I36. single-quoted value with a space" deny "git -c 'user.name=A B' stash pop"
case_cmd "I37. backslash-escaped space in -C" deny 'git -C /tmp/a\ b stash pop'
case_cmd "I38. quoted read with a spaced option value" allow 'git -c "user.name=A B" stash list'
case_cmd "I39. a quoted format string (no stash)" allow 'git log --format="%h %s" -3'
case_cmd "I40. brace expansion git {stash,pop}" deny 'git {stash,pop}'
case_cmd "I41. brace expansion git {stash,} pop" deny 'git {stash,} pop'
case_cmd "I42. glob subcommand git st?sh pop" deny 'git st?sh pop'
case_cmd "I43. glob subcommand git st*" deny 'git st*'
case_cmd "I44. glob in the git command word" deny '/usr/bin/g?t stash pop'
case_cmd "I45. glob in the git-stash command word" deny '/usr/libexec/git-core/git-st*sh pop'
case_cmd "I46. glob in the stash verb" deny 'git stash l?st'
case_cmd "I47. bracket glob subcommand" deny 'git st[a]sh pop'
case_cmd "I48. glob command word with a read" allow '/usr/bin/g?t stash list'
case_cmd "I49. a quoted glob is not expanded" allow "git log -- '*.md'"
case_cmd "I50. a glob in a git argument" allow 'git add ai/hooks/*.sh'
case_cmd "I51. a glob in another command" allow 'ls ai/hooks/*.sh'
case_cmd "I52. an unquoted stash ref brace" allow 'git stash show stash@{0}'
case_cmd "I53. glob command word after env VAR=x" deny 'env A=1 /usr/bin/g?t stash pop'
case_cmd "I54. glob command word after a separator" deny 'true && /usr/bin/g?t stash'
case_cmd "I55. glob git-stash word with a read verb" allow '/usr/libexec/git-core/git-st*sh list'
case_cmd "I56. glob git-stash word, option-first (implicit push)" deny '/usr/libexec/git-core/git-st*sh -u'
case_cmd "I57. glob command word running a stash alias" deny '/usr/bin/g?t sp'
case_cmd "I58. glob command word, unrelated subcommand" allow '/usr/bin/g?t status'
case_cmd "I59. --no-pager diff with an expanded argument" allow 'git --no-pager diff $BASE'
case_cmd "I60. --no-pager show with an unquoted brace ref" allow 'git --no-pager show HEAD@{1}'
case_cmd "I61. --no-pager log with a glob pathspec" allow 'git --no-pager log -- ai/hooks/*.sh'
case_cmd "I62. -P log with an expanded argument" allow 'git -P log $SHA'
case_cmd "I63. --no-pager with an expanded subcommand" deny 'git --no-pager $SUB'
case_cmd "I64. unknown option, then diff with an expanded argument" allow 'git --some-future-opt diff $X'
case_cmd "I65. unknown option, then a stash alias" deny 'git --some-future-opt v sp'
case_cmd "I66. redirect joined to the subcommand: git stash>/dev/null" deny 'git stash>/dev/null'
case_cmd "I67. redirect joined to the subcommand, then pop" deny 'git stash>/dev/null pop'
case_cmd "I68. redirect before the subcommand" deny 'git >/dev/null stash pop'
case_cmd "I69. fd redirect before the subcommand" deny 'git 2>/dev/null stash pop'
case_cmd "I70. git-stash binary with a joined redirect" deny '/usr/libexec/git-core/git-stash>/dev/null pop'
case_cmd "I71. &> redirect before the subcommand" deny 'git &>/dev/null stash pop'
case_cmd "I72. fd duplication before the subcommand" deny 'git 2>&1 stash pop'
case_cmd "I73. input redirect before the subcommand" deny 'git </dev/null stash drop'
case_cmd "I74. a stash write inside a process substitution" deny 'cat <(git stash pop)'
case_cmd "I75. redirect after a read" allow 'git stash list >/tmp/out 2>&1'
case_cmd "I76. redirect before a read" allow 'git 2>/dev/null stash list'
case_cmd "I77. heredoc into an unrelated command" allow 'cat <<EOF
hello
EOF'

echo "== S: shell aliases from the Bash tool snapshot =="
case_cmd "S1. shell alias gstp = git stash pop" deny 'gstp'
case_cmd "S2. shell alias gstl = git stash list (read)" allow 'gstl'
case_cmd "S3. shell alias g = git, then a git stash alias" deny 'g sp'
case_cmd "S4. shell alias chain gsp2 -> gstp" deny 'gsp2'
case_cmd "S5. shell alias after a separator" deny 'cd /tmp && gstp'
case_cmd "S6. shell alias name as an argument only" allow 'echo gstp'
case_cmd "S7. unrelated shell alias gst = git status" allow 'gst'
case_cmd "S8. a child sh -c loads no aliases" allow "sh -c 'gstp'"
case_cmd "Z1. zsh =git (EQUALS expansion)" deny '=git stash pop'
case_cmd "Z2. zsh =git-stash" deny '=git-stash pop'
case_cmd "Z3. zsh =git after env" deny 'env =git stash'
case_cmd "Z4. zsh global alias in argument position" deny 'git GSP'
case_cmd "Z5. zsh suffix alias" deny 'notes.stashfile'
case_cmd "Z6. noglob precommand with a glob command word" deny 'noglob /usr/bin/g?t stash pop'
case_cmd "Z7. = in an ordinary test expression" allow '[ a = b ] && git status'
case_cmd "Z8. =git with a read" allow '=git stash list'

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
run "$(json / "cd $OWNER && git lp")"
check "A14. repo-local alias reached by a same-command cd" deny
case_cmd "A15. alias value with a global option: z = -c k=v stash pop" deny 'git z'
case_cmd "A16. alias np = --no-pager stash (bare)" deny 'git np'
case_cmd "A17. alias np + pop" deny 'git np pop'
case_cmd "A18. alias npl = --no-pager stash list (read)" allow 'git npl'
case_cmd "A19. alias names match case-insensitively (git SP)" deny 'git SP'
case_cmd "A20. alias through --config-env" deny 'P="stash pop" git --config-env=alias.p=P p'
case_cmd "A21. alias through GIT_CONFIG_KEY_n" deny 'GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=alias.p GIT_CONFIG_VALUE_0=x git p'
case_cmd "A22. shell alias chaining to a stash alias: x2 = !git sp" deny 'git x2'
case_cmd "A23. shell alias with a quote-split body" deny 'git x3'
case_cmd "A24. shell alias with an unrelated body: x4 = !git status" allow 'git x4'
case_cmd "A25. a stash alias through an expanded command word: \$GIT sp" deny '$GIT sp'
case_cmd "A26. an expanded word with an expanded argument" allow '$EDITOR $FILE'
case_cmd "A27. a quote-split git word running a stash alias" deny 'g"i"t sp'
case_cmd "A28. an alias chain past the resolution bound (12 deep)" deny 'git c1'
# N1: `git stash pop` nested in 10 levels of bash -c "...", past the re-read bound.
_nest='git stash pop'
for _k in 1 2 3 4 5 6 7 8 9 10; do
  _nest="bash -c \"$(printf '%s' "$_nest" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')\""
done
case_cmd "N1. a stash write nested past the re-read bound" deny "$_nest"

echo "== R: stash refs written without the stash subcommand =="
case_cmd "R1. git update-ref -d refs/stash" deny 'git update-ref -d refs/stash'
case_cmd "R2. git reflog delete refs/stash@{0}" deny 'git reflog delete refs/stash@{0}'
case_cmd "R3. git reflog expire on refs/stash" deny 'git reflog expire --expire=now refs/stash'
case_cmd "R4. rm the stash reflog file" deny "rm $OWNER/.git/logs/refs/stash"
case_cmd "R5. redirect into refs/stash" deny "echo x > $OWNER/.git/refs/stash"
case_cmd "R6. read the stash path (no write)" allow 'git rev-parse --git-path refs/stash'
case_cmd "R7. reflog delete stash@{0} (short name, quoted)" deny "git reflog delete 'stash@{0}'"
case_cmd "R8. reflog expire --expire=now stash (short name)" deny 'git reflog expire --expire=now stash'
case_cmd "R9. reflog expire --expire=now --all" deny 'git reflog expire --expire=now --all'
case_cmd "R10. reflog drop stash" deny 'git reflog drop stash'
case_cmd "R11. reflog delete stash@{0} (unquoted brace)" deny 'git reflog delete stash@{0}'
case_cmd "R12. reflog delete refs/stash@{1}" deny "git reflog delete 'refs/stash@{1}'"
case_cmd "R13. update-ref -d stash (short name)" deny 'git update-ref -d stash'
case_cmd "R14. update-ref --stdin (unreadable batch)" deny 'printf "delete refs/x\n" | git update-ref --stdin'
case_cmd "R15. xargs-fed update-ref -d (no literal ref)" deny 'git for-each-ref --format="%(refname)" | xargs git update-ref -d'
case_cmd "R16. symbolic-ref refs/stash <ref>" deny 'git symbolic-ref refs/stash refs/heads/main'
case_cmd "R17. fetch into refs/stash" deny 'git fetch . +HEAD:refs/stash'
case_cmd "R18. push into refs/stash" deny 'git push . HEAD:refs/stash'
case_cmd "R19. fetch with a refs/* mirror refspec" deny "git fetch --prune origin '+refs/*:refs/*'"
case_cmd "R20. inline gc.reflogExpire then gc" deny 'git -c gc.reflogExpire=now gc'
case_cmd "R21. config gc.reflogExpireUnreachable" deny 'git config gc.reflogExpireUnreachable now'
case_cmd "R22. filter-branch -- --all" deny 'git filter-branch --tree-filter true -- --all'
case_cmd "R23. reflog expire via a git alias with args" deny 'git rx stash'
case_cmd "R24. reflog expire with an expanded ref" deny 'git reflog expire --expire=now $REF'
case_cmd "R25. reflog delete through an unknown global option" deny "git --some-future-opt v reflog delete 'stash@{0}'"
case_cmd "R35. push . --delete stash (short name)" deny 'git push . --delete stash'
case_cmd "R36. push . --delete refs/stash" deny 'git push . --delete refs/stash'
case_cmd "R37. push . :stash (delete refspec)" deny 'git push . :stash'
case_cmd "R38. push . +HEAD:stash (overwrite refspec)" deny 'git push . +HEAD:stash'
case_cmd "R39. push --mirror" deny 'git push --mirror .'
case_cmd "R40. fetch into the short stash name" deny 'git fetch . +HEAD:stash'
case_cmd "R41. fetch with a bare * glob refspec" deny "git fetch . '+*:*'"
case_cmd "R26. reflog show stash (read)" allow 'git reflog show stash'
case_cmd "R27. reflog (bare, read)" allow 'git reflog -5'
case_cmd "R28. reflog expire a branch" allow 'git reflog expire --expire=now refs/heads/tmp'
case_cmd "R29. update-ref a branch" allow 'git update-ref refs/heads/tmp HEAD'
case_cmd "R30. update-ref -d a branch" allow 'git update-ref -d refs/heads/tmp'
case_cmd "R31. push a branch named stash to a remote" allow 'git push origin HEAD:stash-fix'
case_cmd "R32. fetch a normal refspec" allow 'git fetch origin main:refs/remotes/origin/main'
case_cmd "R33. symbolic-ref read HEAD" allow 'git symbolic-ref --short HEAD'
case_cmd "R34. plain gc" allow 'git gc'

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
case_cmd "OK11. -C a dir named stash, then a read-only subcommand" allow 'git -C stash status'

echo "== T: the deny text =="
run "$(json "$WT" 'git stash pop')"
if printf '%s' "$OUT" | grep -q 'git worktree add' && printf '%s' "$OUT" | grep -q 'commit'; then
  record "T1. Fix: names a WIP commit and git worktree add" PASS
else
  record "T1. Fix: names a WIP commit and git worktree add" FAIL
fi

echo "== B: inputs past one exec argument's limit (MAX_ARG_STRLEN, 128 KiB) =="
# The kernel refuses (E2BIG) any single argv or environment string over 128
# KiB, so data handed to the evaluator that way fails to exec and the hook
# used to allow. Measured 2026-09-26: the desktop's snapshots held ~172 KB of
# relevant aliases. Every case here is over that limit and must still decide.
# jsonstdin <cwd> : a Bash-tool JSON whose command is read from stdin (the
# command itself may be past the argument limit, so it never goes through argv).
jsonstdin() {
  jq -cRs --arg d "$1" '{tool_name:"Bash",cwd:$d,tool_input:{command:.}}'
}
# runin <claude-config-dir> <git-global-config> <json> : run the hook with
# those config roots.
runin() {
  OUT=$(printf '%s' "$3" | CLAUDE_CONFIG_DIR="$1" GIT_CONFIG_GLOBAL="$2" sh "$HOOK" 2>/dev/null)
  STATUS=$?
}
BIG="$TMP/big"
mkdir -p "$BIG/distinct/shell-snapshots" "$BIG/dup/shell-snapshots" "$BIG/multi/shell-snapshots"
# 4000 DISTINCT git-valued aliases with long names (~290 KB, and a name list
# past 128 KiB too), so no amount of deduplication brings them under the limit.
awk 'BEGIN { for (i = 1; i <= 4000; i++) printf "alias -- galias_padding_padding_padding_padding_%d=\047git log --oneline -n %d\047\n", i, i
  print "alias -- gstp=\047git stash pop\047" }' > "$BIG/distinct/shell-snapshots/snapshot-zsh-1-big.sh"
# The desktop's shape: the same alias set in 30 snapshots (~180 KB in total,
# small once deduplicated).
awk 'BEGIN { for (i = 1; i <= 120; i++) printf "alias -- gl%d=\047git log --oneline -n %d\047\n", i, i
  print "alias -- gstp=\047git stash pop\047" }' > "$BIG/dup/one.sh"
for _k in $(seq 1 30); do cp "$BIG/dup/one.sh" "$BIG/dup/shell-snapshots/snapshot-zsh-$_k-dup.sh"; done
rm -f "$BIG/dup/one.sh"
# One alias name with a different value in two snapshots: the Bash tool loads
# whichever snapshot its session has, so every value counts.
printf "alias -- gzz='git stash pop'\n" > "$BIG/multi/shell-snapshots/snapshot-zsh-1-a.sh"
printf "alias -- gzz='git status'\n" > "$BIG/multi/shell-snapshots/snapshot-zsh-2-b.sh"
# 4000 git aliases in the global config (~150 KB), with a stash alias last.
{ printf '[alias]\n'
  awk 'BEGIN { for (i = 1; i <= 4000; i++) printf "\tpadding-padding-padding-%d = log --oneline -n %d\n", i, i }'
  printf '\tsp = stash pop\n'; } > "$BIG/gitconfig"
_pad=$(awk 'BEGIN { s = "x"; while (length(s) < 140000) s = s s; print s }')

runin "$BIG/distinct" "$GIT_CONFIG_GLOBAL" "$(printf 'gstp' | jsonstdin "$WT")"
check "B1. shell alias among >128 KiB of distinct snapshot aliases" deny
runin "$BIG/dup" "$GIT_CONFIG_GLOBAL" "$(printf 'gstp' | jsonstdin "$WT")"
check "B2. shell alias among >128 KiB of duplicated snapshots (desktop shape)" deny
runin "$BIG/dup" "$GIT_CONFIG_GLOBAL" "$(printf 'gl7' | jsonstdin "$WT")"
check "B3. unrelated alias among >128 KiB of snapshots" allow
runin "$CLAUDE_CONFIG_DIR" "$BIG/gitconfig" "$(printf 'git sp' | jsonstdin "$WT")"
check "B4. git alias among >128 KiB of global git aliases" deny
runin "$CLAUDE_CONFIG_DIR" "$GIT_CONFIG_GLOBAL" "$(printf 'git stash pop; echo %s' "$_pad" | jsonstdin "$WT")"
check "B5. a command longer than 128 KiB" deny
runin "$CLAUDE_CONFIG_DIR" "$GIT_CONFIG_GLOBAL" "$(printf 'git status; echo %s' "$_pad" | jsonstdin "$WT")"
check "B6. a harmless command longer than 128 KiB" allow
runin "$BIG/multi" "$GIT_CONFIG_GLOBAL" "$(printf 'gzz' | jsonstdin "$WT")"
check "B7. an alias name with a stash value in any snapshot" deny

echo "== C: a config source the hook cannot read =="
# The command points git at a config the hook never reads (another git dir, a
# different global config or HOME, an include, a cd/-C target that is
# expanded or holds whitespace). An alias defined there is unknowable, so a
# subcommand that is not a git builtin is denied; builtins stay allowed.
# Decided from / so the cwd resolves no repo config.
printf '[alias]\n\tap = stash pop\n' > "$TMP/altcfg"
mkdir -p "$TMP/h" "$TMP/xdg/git"
cp "$TMP/altcfg" "$TMP/h/.gitconfig"; cp "$TMP/altcfg" "$TMP/xdg/git/config"
# case_root <label> <deny|allow> <command> : decided with cwd /.
case_root() {
  run "$(json / "$3")"
  check "$1" "$2"
}
case_root "C1. --git-dir to a repo with a local stash alias" deny "git --git-dir=$OWNER/.git lp"
case_root "C2. --git-dir as two words" deny "git --git-dir $OWNER/.git lp"
case_root "C3. GIT_DIR to a repo with a local stash alias" deny "GIT_DIR=$OWNER/.git git lp"
case_root "C4. exported GIT_DIR" deny "export GIT_DIR=$OWNER/.git; git lp"
case_root "C5. GIT_CONFIG_GLOBAL set by the command" deny "GIT_CONFIG_GLOBAL=$TMP/altcfg git ap"
case_root "C6. HOME set by the command" deny "HOME=$TMP/h git ap"
case_root "C7. XDG_CONFIG_HOME set by the command" deny "XDG_CONFIG_HOME=$TMP/xdg git ap"
case_root "C8. -c include.path" deny "git -c include.path=$TMP/altcfg ap"
case_root "C9. cd to an expanded dir" deny 'cd "$D" && git lp'
case_root "C10. -C with an expanded dir" deny 'git -C "$D" lp'
case_root "C11. cd to a dir holding whitespace" deny 'cd "/tmp/a b" && git lp'
case_root "C12. GIT_CONFIG_SYSTEM set by the command" deny "GIT_CONFIG_SYSTEM=$TMP/altcfg git ap"
case_root "C13. --git-dir with a builtin" allow "git --git-dir=$OWNER/.git status"
case_root "C14. GIT_DIR with a builtin" allow "GIT_DIR=$OWNER/.git git log --oneline"
case_root "C15. HOME with a builtin" allow 'HOME=/tmp git status'
case_root "C16. cd to an expanded dir, then a builtin" allow 'cd "$D" && git status'
case_root "C17. --git-dir with a stash read" allow "git --git-dir=$OWNER/.git stash list"
case_root "C18. --git-dir with a global alias that is not a stash write" allow "git --git-dir=$OWNER/.git st"

echo "== V: an alias defined in the command from an expansion =="
# The alias value (or the whole -c key=value) is built by the shell, so the
# hook cannot read it. Invoking a non-builtin under such a definition is denied.
case_root "V1. -c alias value from a variable" deny 'V=stash; git -c alias.p="$V" p'
case_root "V2. -c alias value from a backtick" deny 'git -c alias.p=`printf %s%s st ash` p'
case_root "V3. -c alias value from \$(...)" deny 'git -c alias.p="$(printf %s%s st ash)" p'
case_root "V4. -c alias value from \${V}" deny 'git -c alias.p=${V} p'
case_root "V5. -c alias value with an expansion after a space" deny 'git -c alias.p="x $V" p'
case_root "V6. whole -c key=value from a variable" deny 'git -c "$KV" p'
case_root "V7. --config-env key from a variable" deny 'git --config-env="$E" p'
case_root "V8. git config alias from a variable, then used" deny 'git config alias.p "$V" && git p'
case_root "V9. GIT_CONFIG_VALUE_n from a variable" deny 'GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=alias.p GIT_CONFIG_VALUE_0="$V" git p'
case_root "V10. GIT_CONFIG_PARAMETERS from a variable" deny 'GIT_CONFIG_PARAMETERS="$P" git p'
case_root "V11. -c alias value from \$(...) as its own word" deny 'git -c alias.p=$(printf %s%s st ash) p'
case_root "V12. expanded alias definition, builtin run" allow 'git -c alias.p="$V" status'
case_root "V13. -c with a literal non-alias key and an expanded value" allow 'git -c user.name="$N" commit -F msg'
case_root "V14. sh -c with an expansion, git builtin inside" allow 'sh -c "git status $X"'
case_root "V15. git log -c with a literal revision" allow 'git log -c HEAD'
case_root "V16. a commit message from a substitution" allow 'git commit -m "$(cat msg)"'
case_root "V17. sh -c from a substitution" allow 'sh -c "$(cat script.sh)"'

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
# F7-F12: an evaluation fault must not read as "nothing found". The hook
# falls back to a lexical verdict: deny when the text names stash or a stash
# alias, else allow with a notice that the guard did not run.
# A fake awk that fails comes first on PATH.
mkdir -p "$TMP/badbin"
printf '#!/bin/sh\nexit 2\n' > "$TMP/badbin/awk"; chmod +x "$TMP/badbin/awk"
# runbad <command> : run the hook with the failing awk.
runbad() {
  OUT=$(json "$WT" "$1" | PATH="$TMP/badbin:$PATH" sh "$HOOK" 2>/dev/null); STATUS=$?
}
# is_fault_deny / is_fault_allow : the fallback verdicts, each naming the fault.
is_fault_deny() { is_deny && printf '%s' "$OUT" | grep -q 'could not evaluate'; }
is_fault_allow() {
  [ "$STATUS" -eq 0 ] && printf '%s' "$OUT" | grep -q 'could not evaluate' && ! printf '%s' "$OUT" | grep -q '"deny"'
}
fault_check() {
  if [ "$2" = deny ]; then
    if is_fault_deny; then record "$1 (expected fault deny)" PASS; else record "$1 (expected fault deny)" FAIL; fi
  else
    if is_fault_allow; then record "$1 (expected fault allow + notice)" PASS; else record "$1 (expected fault allow + notice)" FAIL; fi
  fi
}
runbad 'git stash pop'
fault_check "F7. a crashed evaluator fails closed on a literal stash write" deny
runbad 'git status'
fault_check "F8. a crashed evaluator allows a command naming no stash, with a notice" allow
runbad 'gstp'
fault_check "F9. a crashed evaluator fails closed on a shell alias spelling a stash write" deny
runbad 'git sp'
fault_check "F10. a crashed evaluator fails closed on a git alias spelling a stash write" deny
printf '[alias\n\tsp = stash pop\n' > "$TMP/badconfig"
OUT=$(json "$WT" 'git status' | GIT_CONFIG_GLOBAL="$TMP/badconfig" sh "$HOOK" 2>/dev/null); STATUS=$?
if is_fault_allow && printf '%s' "$OUT" | grep -q 'global git config could not be read'; then
  record "F11. an unreadable global git config is a fault, not zero aliases" PASS
else
  record "F11. an unreadable global git config is a fault, not zero aliases" FAIL
fi
OUT=$(json "$WT" 'git stash pop' | GIT_CONFIG_GLOBAL="$TMP/badconfig" sh "$HOOK" 2>/dev/null); STATUS=$?
fault_check "F12. an unreadable global git config fails closed on a stash write" deny
# F13: the hook work dir is removed on every exit path (deny, allow, fault).
mkdir -p "$TMP/hooktmp"
for _c in 'git stash pop' 'git status' 'ls'; do
  json "$WT" "$_c" | TMPDIR="$TMP/hooktmp" sh "$HOOK" >/dev/null 2>&1
done
json "$WT" 'git stash pop' | TMPDIR="$TMP/hooktmp" PATH="$TMP/badbin:$PATH" sh "$HOOK" >/dev/null 2>&1
if [ -z "$(find "$TMP/hooktmp" -mindepth 1 -print -quit)" ]; then
  record "F13. the work dir is removed on deny, allow and fault exits" PASS
else
  STATUS=0; OUT=$(find "$TMP/hooktmp" -mindepth 1 | head -5)
  record "F13. the work dir is removed on deny, allow and fault exits" FAIL
fi

echo
echo "==================================================="
printf 'RESULT: %d passed, %d failed\n' "$PASS" "$FAIL"
echo "==================================================="
[ "$FAIL" -eq 0 ] || { echo "VERDICT: FAIL"; exit 1; }
echo "ALL CASES PASS"
echo "VERDICT: PASS"
exit 0
