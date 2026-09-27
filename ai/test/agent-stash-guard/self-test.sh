#!/usr/bin/env bash
# Self-test for the agent-stash reference-transaction hook (DND-775):
# ai/git-hooks/agent-stash-guard.sh, injected exactly as ai/hooks/registry.json's
# `env` section injects it (the inline hook command included).
#
# Every case builds a fixture: an owner repo holding two stash entries (seeded by
# the real git with the injection UNSET: a stated fixture opt-out) and a linked
# worktree, then runs the command FROM THE WORKTREE with the injection in place
# and asserts the refusal AND a byte-identical refs/stash + logs/refs/stash.
#
# This suite tests the HOOK layer alone: PATH is stripped of any agent git
# wrapper (ai/agent-bin/git), so a case refused here was refused by git itself.
# The wrapper has its own suite (ai/test/agent-bin-git/self-test.sh).
#
# Hermetic: fixture repos under mktemp -d, HOME and the global config are
# fixtures, system config ignored. No real repo's stash, refs or config is read
# or written.
#
# Seams (evidence runs only; see ai/test/agent-stash-guard/SABOTAGE_RECORDS.md):
#   AGENT_STASH_HOOK_UNDER_TEST=<path>  run this hook file instead of the repo's
#   AGENT_STASH_NO_INJECT=1             run every case with NO injection (the
#                                       fail-first baseline: every write lands)
#
# Condition (b): suites that unset GIT_CONFIG_COUNT in their own sandbox
# (gh-athena, glab-athena, and every `env -i` suite) drop the hook there. They
# create only fixture repos, so that is acceptable; it is stated here and in the
# hook's header.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT="$(cd "${HERE}/../../.." && pwd -P)"
REGISTRY="${ROOT}/ai/hooks/registry.json"
HOOK="${AGENT_STASH_HOOK_UNDER_TEST:-${ROOT}/ai/git-hooks/agent-stash-guard.sh}"

TMP="$(mktemp -d)" || { echo "FAIL: mktemp"; exit 1; }
trap 'rm -rf "${TMP}"' EXIT INT TERM
PASS=0; FAIL=0; SKIP=0
ok()   { printf '  ok    %s\n' "$1"; PASS=$((PASS+1)); }
bad()  { printf '  FAIL  %s\n        %s\n' "$1" "$2"; FAIL=$((FAIL+1)); }
skip() { printf '  SKIP  %s (%s)\n' "$1" "$2"; SKIP=$((SKIP+1)); }

# ---- hermetic environment ---------------------------------------------------
# Drop whatever the calling session injected: this suite injects its own.
for v in $(env | sed -n 's/^\(GIT_CONFIG_\(KEY\|VALUE\)_[0-9]*\)=.*/\1/p'); do unset "$v"; done
unset GIT_CONFIG_COUNT GIT_CONFIG_PARAMETERS GIT_TRACE2 GIT_TRACE2_PARENT_NAME GIT_TRACE2_PARENT_SID \
  GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR ATHENA_AGENT_GIT_SEEN ATHENA_AGENT_BIN
# PATH without any agent git wrapper: this suite judges the hook alone.
newpath=
IFS=: read -r -a _dirs <<< "${PATH}"
for d in "${_dirs[@]}"; do
  if [ -f "${d}/git" ] && grep -q 'git (agent wrapper)' "${d}/git" 2>/dev/null; then continue; fi
  newpath="${newpath:+${newpath}:}${d}"
done
export PATH="${newpath}"
G="$(command -v git)" || { echo "FAIL: no git on PATH"; exit 1; }
export HOME="${TMP}/home"; mkdir -p "${HOME}"
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL="${TMP}/gitconfig"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
cat > "${GIT_CONFIG_GLOBAL}" <<'EOF'
[init]
	defaultBranch = main
[alias]
	sp = stash pop
	chain = sp
	pp = !git stash pop
	save2 = stash
EOF

# ---- the injection, from the registry ---------------------------------------
# registry_env <root>: print the registry's env section as NUL-free lines
#   C <key> <value>   one GIT_CONFIG pair (value may hold spaces; key cannot)
#   V <name> <value>  one plain variable
# with {{MAIN}} expanded to <root>. The value text is the registry's own.
registry_env() {
  python3 - "${REGISTRY}" "$1" <<'PY'
import json, sys
env = json.load(open(sys.argv[1]))["env"]
root = sys.argv[2]
for e in env["git_config"]:
    print("C", e["key"], e["value"].replace("{{MAIN}}", root))
for k, v in env["vars"].items():
    print("V", k, v.replace("{{MAIN}}", root))
PY
}
# The hook command expects <root>/ai/git-hooks/agent-stash-guard.sh. Point it at
# a fixture root holding the hook under test, so a sabotaged copy can be run.
FIXROOT="${TMP}/root"
mkdir -p "${FIXROOT}/ai/git-hooks"
cp "${HOOK}" "${FIXROOT}/ai/git-hooks/agent-stash-guard.sh"
chmod +x "${FIXROOT}/ai/git-hooks/agent-stash-guard.sh"
ENV_LINES="$(registry_env "${FIXROOT}")" || { echo "FAIL: registry env section unreadable"; exit 1; }
[ -n "${ENV_LINES}" ] || { echo "FAIL: registry env section is empty"; exit 1; }

# inject: APPEND the registry's GIT_CONFIG pairs after any the caller set
# (condition a), and set GIT_TRACE2. ATHENA_AGENT_BIN is the wrapper's, not
# exported here.
inject() {
  [ "${AGENT_STASH_NO_INJECT:-}" = 1 ] && return 0
  local n="${GIT_CONFIG_COUNT:-0}" tag key value
  while IFS= read -r line; do
    tag="${line%% *}"; line="${line#* }"
    key="${line%% *}"; value="${line#* }"
    case "${tag}" in
      C) export "GIT_CONFIG_KEY_${n}=${key}" "GIT_CONFIG_VALUE_${n}=${value}"; n=$((n+1)) ;;
      V) [ "${key}" = GIT_TRACE2 ] && export GIT_TRACE2="${value}" ;;
    esac
  done <<< "${ENV_LINES}"
  export GIT_CONFIG_COUNT="${n}"
}

# ---- fixtures ---------------------------------------------------------------
K=0
# fresh: owner repo at $OWNER with 2 stash entries, worktree at $WT (cwd).
fresh() {
  K=$((K+1))
  local d="${TMP}/c${K}"
  (
    for v in $(env | sed -n 's/^\(GIT_CONFIG_\(KEY\|VALUE\)_[0-9]*\)=.*/\1/p'); do unset "$v"; done
    unset GIT_CONFIG_COUNT GIT_TRACE2
    "${G}" init -q "${d}/owner" && cd "${d}/owner" && printf 'base\n' > f && "${G}" add f \
      && "${G}" commit -qm base || exit 1
    for i in 1 2; do printf 'owner%s\n' "$i" >> f; "${G}" stash push -qm "OWNER-$i" || exit 1; done
    "${G}" worktree add -q -b "cap${K}" "${d}/wt" || exit 1
  ) || { echo "FAIL: fixture ${K}"; exit 1; }
  OWNER="${d}/owner"; WT="${d}/wt"
  cd "${WT}" || exit 1
  STASH_REF="$("${G}" -C "${OWNER}" rev-parse refs/stash)"
  STASH_LOG="$(cksum < "${OWNER}/.git/logs/refs/stash")"
}
list_intact() {
  [ "$("${G}" -C "${OWNER}" rev-parse refs/stash 2>/dev/null)" = "${STASH_REF}" ] \
    && [ "$(cksum < "${OWNER}/.git/logs/refs/stash")" = "${STASH_LOG}" ]
}
count() { "${G}" -C "${OWNER}" stash list | wc -l | tr -d ' '; }

# refused <label> <cmd...>: run from the worktree, injected; want rc!=0 and the
# list byte-identical.
refused() {
  local label="$1"; shift
  local out rc
  out="$( (inject; "$@") 2>&1)"; rc=$?
  if [ "${rc}" -ne 0 ] && list_intact; then ok "${label}"
  else bad "${label}" "rc=${rc} entries=$(count) out=$(printf '%s' "${out}" | head -c 300)"; fi
}
# allowed <label> <cmd...>: want rc 0, no refusal from the hook (a command such
# as rebase --autostash can exit 0 after a refused inner step), and 2 entries
# still listed.
allowed() {
  local label="$1"; shift
  local out rc
  out="$( (inject; "$@") 2>&1)"; rc=$?
  if [ "${rc}" -eq 0 ] && [[ "${out}" != *"agent-stash-guard: REFUSED"* ]] && [ "$(count)" = 2 ]; then ok "${label}"
  else bad "${label}" "rc=${rc} entries=$(count) out=$(printf '%s' "${out}" | head -c 300)"; fi
}

echo "agent-stash-guard hook self-test"
echo "hook: ${HOOK}"
echo "git:  ${G} ($("${G}" --version))"
[ "${AGENT_STASH_NO_INJECT:-}" = 1 ] && echo "MODE: NO INJECTION (fail-first baseline; every P/W case should FAIL)"
echo

echo "--- H: the injection registers the hook ---"
fresh
out="$( (inject; "${G}" hook list reference-transaction) 2>&1)"
if [ "${out}" = agentstash ]; then ok "H1. git hook list reference-transaction prints agentstash"
else bad "H1. hook registered" "out=${out}"; fi

echo "--- P: pop/apply/branch, every spelling (R2) ---"
printf '#!/bin/sh\ngit stash pop\n' > "${TMP}/popper.sh"; chmod +x "${TMP}/popper.sh"
fresh; refused "P1. git stash pop" git stash pop
fresh; refused "P2. alias sp = stash pop" git sp
fresh; refused "P3. alias chain -> sp" git chain
fresh; refused "P4. shell alias !git stash pop" git pp
fresh; refused "P5. help.autocorrect typo stsh pop" git -c help.autocorrect=immediate stsh pop
fresh; refused "P6. script file" "${TMP}/popper.sh"
fresh; refused "P7. python3 subprocess" python3 -c 'import subprocess,sys; sys.exit(subprocess.call(["git","st"+"ash","pop"]))'
fresh; refused "P8. eval of printf" sh -c 'eval "$(printf "git %s %s" sta"sh" pop)"'
fresh; refused "P9. git stash apply" git stash apply
fresh; refused "P10. git stash branch" git stash branch newb
fresh; refused "P11. git -C <dir> stash pop --index" git -C "${WT}" stash pop --index
fresh; refused "P12. absolute-path git stash pop" "${G}" stash pop
# Stash run UNDER rebase/merge but not as an autostash (critic round 2): the
# ancestor name is rebase/stash or merge/stash, and no autostash is in progress.
fresh; "${G}" checkout -qb up && printf 'up\n' > u && "${G}" add u && "${G}" commit -qm up && "${G}" checkout -q "cap${K}" \
  && printf 't\n' > t && "${G}" add t && "${G}" commit -qm topic
refused "P13. rebase -x 'git stash pop' (stash under a rebase parent, no autostash)" git rebase -x 'git stash pop' up
"${G}" rebase --abort >/dev/null 2>&1; "${G}" checkout -q -- . 2>/dev/null
fresh; mkdir -p "${TMP}/mh${K}"; printf '#!/bin/sh\ngit stash pop\n' > "${TMP}/mh${K}/pre-merge-commit"; chmod +x "${TMP}/mh${K}/pre-merge-commit"
"${G}" checkout -qb side && printf 's\n' > s && "${G}" add s && "${G}" commit -qm side && "${G}" checkout -q "cap${K}" \
  && printf 'c\n' > c && "${G}" add c && "${G}" commit -qm c
refused "P14. a git hook running stash pop during a merge (merge/stash, no autostash)" \
  git -c core.hooksPath="${TMP}/mh${K}" merge -q --no-edit side

echo "--- Z: DND-801 zsh command-word forms ---"
if command -v zsh >/dev/null 2>&1; then
  GD="${G%/*}"
  fresh; refused "Z1. zsh /usr/bin/g(i)t stash pop" zsh -f -o extendedglob -c "${GD}/g(i)t stash pop"
  fresh; refused "Z2. zsh /usr/bin/(git|nope) stash pop" zsh -f -o extendedglob -c "${GD}/(git|nope) stash pop"
  fresh; refused "Z3. zsh /usr/bin/gi[t] stash pop" zsh -f -o extendedglob -c "${GD}/gi[t] stash pop"
  fresh; refused "Z4. zsh =git stash pop" zsh -f -c '=git stash pop'
  fresh; refused "Z5. zsh =git stash apply" zsh -f -c '=git stash apply'
else
  skip "Z1-Z5. zsh forms" "zsh not installed"
fi

echo "--- W: writes to refs/stash (R1, R1d) ---"
fresh; printf 'mine\n' >> f
refused "W1. bare git stash" git stash
if grep -q mine f; then ok "W1b. the refused push left the change in the worktree"
else bad "W1b. change kept in worktree" "f=$(cat f)"; fi
fresh; printf 'mine\n' >> f; refused "W2. alias save2 = stash" git save2
fresh; printf 'mine\n' >> f; S="$("${G}" stash create)"; "${G}" checkout -q -- f
refused "W3. git stash store <sha>" git stash store -m x "${S}"
fresh; refused "W4. git update-ref refs/stash HEAD" git update-ref refs/stash HEAD
fresh; refused "W5. git update-ref --stdin" sh -c 'echo "update refs/stash $(git rev-parse HEAD)" | git update-ref --stdin'
fresh; refused "W6. git fetch . +HEAD:refs/stash" git fetch -q . +HEAD:refs/stash
fresh; refused "W7. git stash clear" git stash clear
fresh; refused "W8. git update-ref -d refs/stash" git update-ref -d refs/stash
fresh; printf 'mine\n' >> f; refused "W9. python3 push -u" python3 -c 'import subprocess,sys; sys.exit(subprocess.call(["git","stash","push","-u"]))'

echo "--- OK: must pass under the hook ---"
fresh
allowed "OK1. git stash list" git stash list
allowed "OK2. git stash show -p" git stash show -p
printf 'q\n' >> f; allowed "OK3. git stash create" git stash create; "${G}" checkout -q -- f
allowed "OK4. git pack-refs --all" git -C "${OWNER}" pack-refs --all
if list_intact; then ok "OK4b. pack-refs kept refs/stash and its log"; else bad "OK4b. pack-refs kept the list" "entries=$(count)"; fi
allowed "OK5. git gc" git -C "${OWNER}" gc -q
allowed "OK6. git maintenance run --task=gc" git -C "${OWNER}" maintenance run --task=gc --quiet
printf 'w\n' > g; "${G}" add g
allowed "OK8. commit in the linked worktree" git commit -qm w
allowed "OK9. branch, tag, checkout -b" sh -c 'git branch b1 && git tag t1 && git checkout -qb b2'
# OK7: a clean rebase --autostash and merge --autostash (a dirty tree carried
# across; the hook sees a stash transaction under a rebase/merge ancestor).
fresh
"${G}" checkout -qb up && printf 'up\n' > u && "${G}" add u && "${G}" commit -qm up \
  && "${G}" checkout -q "cap${K}" && printf 't\n' > g2 && "${G}" add g2 && "${G}" commit -qm topic
printf 'dirty\n' > f
allowed "OK7. rebase --autostash (clean)" git rebase -q --autostash up
if grep -q dirty f; then ok "OK7b. the autostashed change came back"; else bad "OK7b. autostash restored" "f=$(cat f)"; fi
fresh
"${G}" checkout -qb up2 && printf 'up\n' > u && "${G}" add u && "${G}" commit -qm up \
  && "${G}" checkout -q "cap${K}"
printf 'dirty\n' > f
allowed "OK10. merge --autostash (clean)" git merge -q --autostash up2

echo "--- F: a missing hook script fails closed with a Fix: ---"
fresh
mv "${FIXROOT}/ai/git-hooks/agent-stash-guard.sh" "${TMP}/hook.aside"
out="$( (inject; git commit -q --allow-empty -m x) 2>&1)"; rc=$?
mv "${TMP}/hook.aside" "${FIXROOT}/ai/git-hooks/agent-stash-guard.sh"
if [ "${rc}" -ne 0 ] && [[ "${out}" == *"hook script missing"* ]] && [[ "${out}" == *"Fix:"* ]] \
  && [[ "${out}" == *"setup-hooks --remove-env"* ]]; then
  ok "F1. missing script: commit refused (rc=${rc}), message names the path and the one-command disable"
else bad "F1. missing script fails closed with Fix:" "rc=${rc} out=${out}"; fi

echo "--- A: condition (a), the injection is appended after a caller's entries ---"
fresh
out="$(export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=user.name GIT_CONFIG_VALUE_0=caller-kept
       inject; git config user.name; git hook list reference-transaction; git stash pop 2>&1; echo "rc=$?")"
if [[ "${out}" == caller-kept$'\n'agentstash$'\n'* ]] && [[ "${out}" == *"agent-stash-guard: REFUSED"* ]] \
  && [[ "${out}" != *"rc=0" ]] && list_intact; then
  ok "A1. a caller's GIT_CONFIG_COUNT=1 entry is kept at index 0 and the hook still refuses pop"
else bad "A1. append after a caller's entries" "out=${out}"; fi

echo "--- T: the documented residual, pinned (the hook cannot see these) ---"
if [ "${AGENT_STASH_NO_INJECT:-}" = 1 ]; then
  skip "T1-T2" "no-injection baseline"
else
  fresh
  (inject; git stash drop -q 'stash@{1}') >/dev/null 2>&1
  if [ "$(count)" = 1 ]; then ok "T1. residual: drop stash@{1} is not seen by the hook (git rewrote the reflog; the wrapper is the layer for it)"
  else bad "T1. residual pinned" "entries=$(count): git may now route drop through a ref transaction; revisit the residual in the hook header"; fi
  fresh
  (inject; git reflog expire --expire=now --expire-unreachable=now --all) >/dev/null 2>&1
  if [ "$(count)" = 0 ]; then ok "T2. residual: reflog expire --all is not seen by the hook"
  else bad "T2. residual pinned" "entries=$(count): revisit the residual in the hook header"; fi
  fresh
  "${G}" checkout -qb up && printf 'up\n' > u && "${G}" add u && "${G}" commit -qm up && "${G}" checkout -q "cap${K}" \
    && printf 't\n' > t && "${G}" add t && "${G}" commit -qm topic
  printf 'dirty\n' > f
  (inject; git rebase --autostash -x 'git stash pop' up) >/dev/null 2>&1
  if [ "$(count)" = 1 ]; then ok "T3. residual: stash run by rebase -x DURING a real --autostash passes R2 (autostash window)"
  else bad "T3. residual pinned" "entries=$(count): the autostash-window residual changed; revisit the hook header"; fi
  "${G}" rebase --abort >/dev/null 2>&1
fi

echo
echo "==================================================="
printf 'RESULT: %d passed, %d failed, %d skipped\n' "${PASS}" "${FAIL}" "${SKIP}"
if [ "${FAIL}" -eq 0 ]; then echo "VERDICT: PASS"; exit 0; fi
echo "VERDICT: FAIL"
exit 1
