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

echo "== O: over-match of the expansion rules (DND-780, narrow cut) =="
# The narrow cut carries only rules that do not depend on proving a glob
# cannot be git: `[`, `[[` and a lone `{` are not glob heads; `$?` is not a
# glob; an assignment-shaped word gives the next word command position; a
# quoted `$NAME/`-prefixed path with a plain basename is that name; the most
# specific reason wins and names what matched. Every other glob or brace
# command word is judged exactly as at cbac851, and heredoc bodies and
# quoted payloads are still read as commands.
# The deny cases below were written against a broader matcher (branch
# dnd-780-stash-guard-overmatch, deferred to an architect ticket). Here they
# deny because every non-exempt glob head is judged as at cbac851; they are
# regression guards for that follow-up, not evidence of a mechanism in this
# hook. Their "critic round N" comments name where each shape came from.
case_cmd "O1. leading test bracket" allow '[ -n "$n" ] && echo y'
case_cmd "O2. leading [[ keyword" allow '[[ -n "$n" ]] && echo y'
case_cmd "O3. test bracket with \$HOME operand" allow '[ -n "$HOME" ] && echo y'
case_cmd "O4. test bracket -f" allow '[ -f "$x" ]'
case_cmd "O5. [[ with an unquoted variable" allow '[[ -z $v ]]'
case_cmd "O6. \$? inside a quoted string" allow 'echo "R=$HOME rc=$?"'
case_cmd "O8. an expanded path with a literal basename, cd'd into" allow 'W=$(mktemp -d -p /tmp a.XXXX) && git worktree add -q -b z "$W/t" HEAD && echo "$W/t" > /tmp/p && cd "$W/t" && git fetch -q origin && git rebase -q origin/main || { echo REBASE-FAILED; exit 1; }'
case_cmd "O9. zsh brace range with a length expansion" allow 'for i in {1..${#segs}}; do echo $i; done'
case_cmd "O10. quoted ? in an API path" allow "gh api 'repos/CJPoll/custom/activity?per_page=10'"
case_cmd "O11. glob in a for list" allow 'for p in /proc/[0-9]*; do echo $p; done'
case_cmd "O12. bounded wait loop with test" allow "R=~/x; for i in \$(seq 1 19); do n=\$(find \$R -maxdepth 1 -type f -mmin -1 \\( -name 'DND-437*' -o -name 'DND-761*' \\)); test -n \"\$n\" && { echo \"changed: \$n\"; break; }; sleep 30; done"
case_cmd "O13. bounded wait loop with [" allow "R=~/x; for i in \$(seq 1 19); do n=\$(find \$R -maxdepth 1 -type f -mmin -1 \\( -name 'DND-437*' -o -name 'DND-761*' \\)); [ -n \"\$n\" ] && { echo \"changed: \$n\"; break; }; sleep 30; done"
case_cmd "O14. quoted heredoc body with brackets and globs in prose" allow "cat >> file <<'EOF'
[ -n \"\$x\" ] is a test, [[ -f y ]] too.
* a bullet, and a glob like /usr/bin/g?t | head
EOF"
case_cmd "O16. \$* and \$# are parameters" allow 'echo "args: $* count: $#"; [ $# -gt 0 ]'
case_cmd "O18. quoted heredoc into git commit -F -" allow "git commit -F - <<'EOF'
Fix: [ -n x ] and [[ -f y ]] no longer deny; *.md and ? are prose.
EOF"
case_cmd "O19. <<- quoted heredoc, tab-indented terminator" allow "cat <<-'EOF'
	[ -n x ]
	EOF
echo done"
# The guarantee stays: every one of these still denies.
case_cmd "O20. glob basename that can match git" deny '/usr/bin/[g]it stash pop'
case_cmd "O21. POSIX class in a glob command word" deny '/usr/bin/[[:alpha:]]it stash pop'
case_cmd "O22. negated class that can match git" deny '/usr/bin/[!x]it stash'
case_cmd "O23. glob with a range that can match git" deny '/usr/bin/[f-h]it stash pop'
case_cmd "O24. glob that can match git-stash" deny '/usr/libexec/git-core/git-?tash pop'
case_cmd "O25. quoted expansion with a literal git basename" deny '"$D"/git stash pop'
case_cmd "O26. unquoted expansion before a literal basename" deny '$W/t stash pop'
case_cmd "O27. quoted heredoc fed to bash" deny "bash <<'EOF'
git stash pop
EOF"
case_cmd "O28. quoted heredoc piped to sh" deny "cat <<'EOF' | sh
git stash pop
EOF"
case_cmd "O29. quoted heredoc written to a script, then run" deny "cat > /tmp/x.sh <<'EOF'
git stash pop
EOF
sh /tmp/x.sh"
case_cmd "O30. quoted heredoc to a script run by path" deny "cat > ./x.sh <<'EOF'
git stash pop
EOF
./x.sh"
case_cmd "O31. unquoted heredoc body with a substitution" deny 'cat <<EOF
$(git stash pop)
EOF'
case_cmd "O32. quoted heredoc to xargs git" deny "xargs git <<'EOF'
stash pop
EOF"
case_cmd "O33. heredoc body read by a loop that runs it" deny "while read -r l; do \$l; done <<'EOF'
git stash pop
EOF"
case_cmd "O34. a stash write after a quoted heredoc" deny "cat <<'EOF'
data
EOF
git stash pop"
case_cmd "O35. << in a comment does not hide the next line" deny "# see <<'X'
git stash pop
X"
case_cmd "O36. << in arithmetic does not hide the next line" deny "echo \$((1<<'X'))
git stash pop
X"
case_cmd "O37. a stash write inside \${...:-\$(...)}" deny 'echo ${X:-$(git stash pop)}'
case_cmd "O38. an assignment then an expanded git with stash" deny 'A=$B $GIT stash pop'
case_cmd "O39. a glob git command word in a quoted sh -c payload" deny "sh -c '/usr/bin/g?t stash pop'"
case_cmd "O40. literal git in a quoted watch payload" deny "watch 'git stash pop'"
# A heredoc body stays a command (critic rounds 1-2): each of these runs
# the body, and a lexical reader list cannot see that.
case_cmd "O42. quoted heredoc to a git shell alias defined inline" deny "git -c alias.zq='!sh' zq <<'EOF'
git stash pop
EOF"
case_cmd "O43. quoted heredoc to an interpreter on no list" deny "pwsh <<'EOF'
git stash pop
EOF"
case_cmd "O44. quoted heredoc written to a script run by bare name" deny "cat > ~/bin/f <<'EOF'
git stash pop
EOF
f"
case_cmd "O45. quoted heredoc to a gh alias" deny "gh x <<'EOF'
git stash pop
EOF"
case_cmd "O46. quoted heredoc to find -exec sh" deny "cat > f <<'EOF'
git stash pop
EOF
find . -name f -exec sh {} \\;"
case_cmd "O47. quoted heredoc written to a git hook, then commit" deny "cp /usr/bin/true .git/hooks/pre-commit && cat > .git/hooks/pre-commit <<'EOF'
#!/bin/sh
git stash pop
EOF
git commit -m x"
case_cmd "O48. quoted heredoc commit message naming a stash write (accepted false positive)" deny "git commit -F - <<'EOF'
Mentions git stash pop.
EOF"
# Admiral cases 13, 15, 16 (DND-787 folded in): jq filters, python heredoc
# bodies, ERE anchors.
case_cmd "O53. a trailing literal dollar sign" allow 'echo cost$ now'
case_cmd "O54. brace alternatives that can be git" deny '{g,x}it stash pop'
case_cmd "O55. brace alternatives in a path that can be git" deny '/usr/bin/{g,x}it stash pop'
case_cmd "O56. letter sequence brace (conservative)" deny '/usr/bin/{f..h}it stash pop'
case_cmd "O57. nested brace alternatives that can be git" deny '/usr/bin/{x,{g,y}}it stash pop'
case_cmd "O59. zsh \$=var is an expansion" deny '$=G stash pop'
# Critic round 4: the last `/` inside a quoted expansion is not a literal
# basename.
case_cmd "O64. slash inside a quoted command substitution" deny '"$(printf /usr/bin/git)" stash pop'
case_cmd "O65. slash inside a quoted \${G%/}" deny '"${G%/}" stash pop'
case_cmd "O66. slash inside a quoted \${G#*/}" deny '"${G#*/}" stash pop'
case_cmd "O67. slash inside a quoted backtick substitution" deny '"`printf /usr/bin/git`" stash pop'
case_cmd "O68. inner quotes inside a quoted substitution" deny '"$(printf "/usr/bin/git")" stash pop'
# The seven Slack-reported shapes (admiral, 2026-09-26).
case_cmd "O72. grep -E with [)]" allow "grep -E '[)]' f"
case_cmd "O73. python3 -c string with braces" allow "python3 -c \"d = {'a': 1, 'b': [2]}; print(d)\""
case_cmd "O74. heredoc holding {:ok, _}" allow "cat > t.exs <<'EOF'
{:ok, _} = File.read(\"x\")
{:error, reason} -> IO.inspect(reason)
EOF"
case_cmd "O75. a \$(python3 ...) substitution" allow "x=\$(python3 -c 'import re; print(re.sub(r\"[a-z]+\", \"\", \"x1\"))') && echo \"\$x\""
case_cmd "O76. --include=*.ex" allow 'grep -rn defmodule --include=*.ex lib/'
# Critic round 6 (broader matcher): shapes that are git only under a
# non-default glob option. This hook has no glob-option logic; they deny
# because the glob head is judged as at cbac851.
case_cmd "O85. extendedglob negation" deny 'setopt extendedglob; /usr/bin/^x* stash pop'
case_cmd "O86. extendedglob repetition" deny 'setopt extended_glob && /usr/bin/g?#t stash pop'
case_cmd "O87. nocaseglob" deny 'setopt nocaseglob; /usr/bin/G?T stash pop'
case_cmd "O88. nocaseglob class" deny 'setopt NO_CASE_GLOB; /usr/bin/[G]IT stash pop'
case_cmd "O89. braceccl" deny 'setopt braceccl; /usr/bin/{fgh}it stash pop'
case_cmd "O90. bash shopt nocaseglob" deny "bash -c 'shopt -s nocaseglob; /usr/bin/G?T stash pop'"
case_cmd "O91. zsh options[] assignment" deny 'options[extendedglob]=on; /usr/bin/^x* stash pop'
case_cmd "O92. emulate ksh" deny 'emulate ksh; /usr/bin/G?T stash pop'
# A shell alias whose name holds a glob character expands before globbing.
mkdir -p "$TMP/globalias/shell-snapshots"
printf "alias -- 'gs?'='git stash pop'\n" > "$TMP/globalias/shell-snapshots/snapshot-zsh-1-ga.sh"
OUT=$(json "$WT" 'gs?' | CLAUDE_CONFIG_DIR="$TMP/globalias" sh "$HOOK" 2>/dev/null); STATUS=$?
check "O95. a shell alias named with a glob character" deny
# Critic round 7 and its cluster audit: every one of these denies at cbac851.
case_cmd "O96. zsh colon modifier with a slash in a quoted word" deny '"$G:s/q/t" stash pop'
case_cmd "O97. zsh global substitution modifier" deny '"$G:gs/q/t" stash pop'
case_cmd "O98. a glob inside \${...:-...} with an option-only push" deny '${X:-/usr/libexec/git-core/git-st?sh} -u'
case_cmd "O99. \$* in a payload given a glob git word" deny "sh -c '\$*' sh /usr/bin/g?t"
case_cmd "O100. a non-ASCII parameter name is an expansion" deny '$é stash pop'
case_cmd "O101. an indexed assignment prefix keeps command position" deny 'a[1]=x /usr/bin/g?t stash pop'
case_cmd "O102. an append assignment prefix keeps command position" deny 'a+=x /usr/bin/g?t stash pop'
case_cmd "O103a. \${G} with an option-only push (G=git-stash) stays denied" deny '${G} -u'
case_cmd "O103b. \${G} with a write verb stays denied" deny '${G} pop'
case_cmd "O103c. residual: \${p#...} then \$(...) in a re-read quoted string (as at base)" deny 'for p in /proc/1; do echo "${p#/proc/} $(cat $p/comm)"; done'
case_cmd "O103. \${NAME}/literal basename stays allowed" allow 'git worktree add -q "${W}/t" HEAD && cd "${W}/t" && git status'
# Critic round 8: a zsh glob qualifier (on by default) can rewrite a match,
# and zshenv can set glob options for every zsh -c.
case_cmd "O112. a glob qualifier rewriting xargs to git" deny '/usr/bin/[x]args(:s/xargs/git/) -C . stash pop'
case_cmd "O113. a glob qualifier rewriting git-add to git-stash" deny '/usr/libexec/git-core/git-[a]dd(:s/add/stash/) pop'
case_cmd "O113a. a test bracket followed by a subshell still allows" allow '[ -n "$x" ] && (echo y)'
# Critic round 9: `$` + backslash-newline is a line continuation, not a
# literal dollar sign.
case_cmd "O117. \$ then a line continuation, unquoted" deny '$\
GIT stash pop'
case_cmd "O118. \$ then a line continuation, double-quoted" deny '"$\
GIT" stash pop'
# Case 19, the DND-777 captain batch (admiral, 2026-09-26).
case_cmd "O109. git -C with a variable path, builtin verbs" allow 'W=/tmp/w; git -C "$W" status --short && git -C "$W" log --oneline -3 && git -C "$W" rev-parse HEAD'
case_cmd "O110. git -C with a variable path, stash pop" deny 'W=/tmp/w; git -C "$W" stash pop'
case_cmd "O111. git -C with a variable path, stash list" allow 'git -C "$W" stash list'
# Case 17, the laptop batch (admiral, 2026-09-26).
case_cmd "O79. ruby -e with [ and sub(" allow "ruby -e 'puts ARGV[0].sub(/x/, \"y\")' ax"
case_cmd "O83. for loop over quoted worktree paths" allow 'for w in "$wt1" "$wt2"; do git -C "$w" status --short; [ -d "$w/.git" ] && echo "$w"; done'
# Quotes and backslashes the tokenizer removed must not fool the matcher.
case_cmd "O69. escaped ! in a class is a member, not negation" deny '/usr/bin/[\!g]it stash pop'
case_cmd "O70. escaped ] inside a class" deny '/usr/bin/[g\]i]it stash pop'
case_cmd "O71. quoted } inside brace alternatives" deny '/usr/bin/{x"}",g}it stash pop'
# Case 14: the deny reason names what matched.
# reason_names <label> <command> <text> : denied, and the reason holds <text>.
reason_names() {
  run "$(json "$WT" "$2")"
  if is_deny && printf '%s' "$OUT" | grep -qF -- "$3"; then record "$1" PASS; else record "$1" FAIL; fi
}
reason_names "O60. a glob head names the matched words and position" '/usr/bin/g?t stash pop' 'Matched: `/usr/bin/g?t stash pop` at word 1 of the command.'
reason_names "O61. a literal stash names its position" 'echo hi; git stash pop' 'Matched: `git stash pop` at word 3 of the command.'
reason_names "O62. a shell alias names the alias word" 'gstp' 'Matched: `gstp` at word 1 of the command.'
reason_names "O63. a quoted payload names the nested position" "sh -c 'cd /tmp && git stash pop'" 'Matched: `git stash pop` at word 3 of a nested command'
# Narrow-cut critic round 1: a quoted name makes `"A"=...` a command word.
case_cmd "O125. a quoted assignment-shaped glob command word" deny '"A"=/usr/bin/g?t stash pop'
case_cmd "O126. an indexed assignment then a glob git word" deny 'a[1]=x /usr/bin/g?t stash pop'
# The brace-group keyword keeps its body in command position.
case_cmd "O119. a brace group around a test bracket" allow '{ [ -n "$x" ] && echo y; }'
case_cmd "O120. a brace group around a glob git word" deny '{ /usr/bin/g?t stash pop; }'
case_cmd "O121. a brace group around a literal stash write" deny '{ git stash pop; }'
case_cmd "O122. a closed brace word stays a brace expansion" deny '{g,x}it stash pop'
# DND-786 (coordinator) case a: allowed by the narrow cut. Case b (a jq
# object `{a,b,...}` re-read from quotes) still denies; see the report.
case_cmd "O123. DND-786 a: fetch, log, sleep, gh run list | jq" allow "cd /tmp && git fetch -q origin && git log --oneline -2 origin/main; sleep 10; gh run list --workflow post-merge.yml --limit 2 --json databaseId,status,headSha | jq -c '.[]'"
# LOW (DND-780): a literal stash write must name the literal-stash reason even
# after an unrelated expansion that also triggers a rule.
run "$(json / 'cd "$D" && echo "$X" foo && git stash pop')"
if is_deny && printf '%s' "$OUT" | grep -q 'with a verb that writes the stash list'; then
  record "O41. a literal stash write after an unrelated expansion names the literal reason" PASS
else
  record "O41. a literal stash write after an unrelated expansion names the literal reason" FAIL
fi

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

echo "== T: git help.autocorrect runs a corrected typo =="
# With help.autocorrect on, git runs the closest command for a typo:
# `git stsh pop` runs `git stash pop`.
case_root "AC1. inline -c help.autocorrect=immediate with a typo" deny 'git -c help.autocorrect=immediate stsh pop'
case_root "AC2. inline -c help.autocorrect=1" deny 'git -c help.autocorrect=1 stahs pop'
case_root "AC3. setting help.autocorrect in config" deny 'git config --global help.autocorrect immediate'
case_root "AC4. reading help.autocorrect" allow 'git config --get help.autocorrect'
printf '[help]\n\tautocorrect = immediate\n' > "$TMP/accfg"
runin "$CLAUDE_CONFIG_DIR" "$TMP/accfg" "$(printf 'git stahs pop' | jsonstdin /)"
check "AC5. autocorrect on in the global config, a typo of stash" deny
runin "$CLAUDE_CONFIG_DIR" "$TMP/accfg" "$(printf 'git status' | jsonstdin /)"
check "AC6. autocorrect on in the global config, a builtin" allow
printf '[help]\n\tautocorrect = 0\n' > "$TMP/acoff"
runin "$CLAUDE_CONFIG_DIR" "$TMP/acoff" "$(printf 'git stahs pop' | jsonstdin /)"
check "AC7. autocorrect off (0) in the global config, a typo" allow
git -C "$OWNER" config help.autocorrect immediate
run "$(json "$OWNER" 'git stsh pop')"
check "AC8. autocorrect on in the repo config, a typo of stash" deny
git -C "$OWNER" config --unset help.autocorrect

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
