#!/usr/bin/env bash
# Self-test for the agent PATH git wrapper, ai/agent-bin/git (DND-775).
#
# The wrapper is the courtesy early-deny layer: it refuses stash-list writes
# BEFORE git runs, which matters for pop/apply (the hook refuses them only after
# git has written the entry into the worktree) and is the only layer for drop and
# reflog delete|expire (no ref transaction, so the hook never sees them).
#
# This suite tests the WRAPPER alone: the reference-transaction hook is NOT
# injected, so a case refused here was refused before git ran. Every deny case
# asserts exit 1, a `Fix:`, the owner's list byte-identical and, for pop/apply,
# the worktree untouched. The hook has its own suite
# (ai/test/agent-stash-guard/self-test.sh).
#
# Fixture owner entries are seeded by the real git with the wrapper off PATH: a
# stated fixture opt-out. Hermetic: mktemp -d repos, fixture HOME and global
# config, system config ignored.
#
# Seams (evidence runs only; see ai/test/agent-stash-guard/SABOTAGE_RECORDS.md):
#   AGENT_BIN_GIT_UNDER_TEST=<path>  run this wrapper file instead of the repo's
#   AGENT_BIN_GIT_OFF=1              leave the wrapper off PATH (the fail-first
#                                    baseline: every deny case should FAIL)
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT="$(cd "${HERE}/../../.." && pwd -P)"
WRAPPER_SRC="${AGENT_BIN_GIT_UNDER_TEST:-${ROOT}/ai/agent-bin/git}"

TMP="$(mktemp -d)" || { echo "FAIL: mktemp"; exit 1; }
trap 'rm -rf "${TMP}"' EXIT INT TERM
PASS=0; FAIL=0
ok()  { printf '  ok    %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  FAIL  %s\n        %s\n' "$1" "$2"; FAIL=$((FAIL+1)); }

# ---- hermetic environment ---------------------------------------------------
for v in $(env | sed -n 's/^\(GIT_CONFIG_\(KEY\|VALUE\)_[0-9]*\)=.*/\1/p'); do unset "$v"; done
unset GIT_CONFIG_COUNT GIT_CONFIG_PARAMETERS GIT_TRACE2 GIT_TRACE2_PARENT_NAME GIT_TRACE2_PARENT_SID \
  GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR ATHENA_AGENT_GIT_SEEN ATHENA_AGENT_BIN
BASEPATH=
IFS=: read -r -a _dirs <<< "${PATH}"
for d in "${_dirs[@]}"; do
  if [ -f "${d}/git" ] && grep -q 'git (agent wrapper)' "${d}/git" 2>/dev/null; then continue; fi
  BASEPATH="${BASEPATH:+${BASEPATH}:}${d}"
done
export PATH="${BASEPATH}"
G="$(command -v git)" || { echo "FAIL: no git on PATH"; exit 1; }
GDIR="${G%/*}"
export HOME="${TMP}/home"; mkdir -p "${HOME}"
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL="${TMP}/gitconfig"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
cat > "${GIT_CONFIG_GLOBAL}" <<'EOF'
[init]
	defaultBranch = main
[alias]
	sp = stash pop
	chain = sp
	s = stash
	sl = stash list
	st = status
	pp = !git stash pop
	pl = !git log -1 --format=%s
	z = -c color.ui=never stash pop
	np = --no-pager stash
	dd = stash drop
	rx = reflog expire --expire=now --all
	loop1 = loop2
	loop2 = loop1
EOF

# The wrapper directory holds only `git`, as ai/agent-bin does.
WBIN="${TMP}/agent-bin"
mkdir -p "${WBIN}"
cp "${WRAPPER_SRC}" "${WBIN}/git"; chmod +x "${WBIN}/git"
# DND-1667: every git this suite puts on PATH is proven executable before use
# (ai/lib/forge-stub-guard.sh). The wrapper's own PATH layouts are what this
# suite tests, so no guard goes inside them: the wrapper searches PATH after
# its own entry, and a guard there would answer in place of the real git.
. "${ROOT}/ai/lib/forge-stub-guard.sh"
fsg_require_stubs "${WBIN}" git
if [ "${AGENT_BIN_GIT_OFF:-}" = 1 ]; then
  echo "MODE: WRAPPER OFF PATH (fail-first baseline; every deny case should FAIL)"
  APATH="${BASEPATH}"
else
  APATH="${WBIN}:${BASEPATH}"
fi

# ---- fixtures ---------------------------------------------------------------
K=0
fresh() {
  K=$((K+1))
  local d="${TMP}/c${K}"
  ( "${G}" init -q "${d}/owner" && cd "${d}/owner" && printf 'base\n' > f && "${G}" add f \
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
tree_state() { printf '%s|%s' "$(cat "${WT}/f")" "$("${G}" -C "${WT}" status --porcelain)"; }

# denied <label> <cmd...>: through the wrapper; want exit 1, the refusal and a
# Fix:, the list intact and the worktree unchanged. A case that let a write
# through (a sabotaged wrapper) rebuilds the fixture for the next case, so each
# case's verdict is its own. Every case is bounded: a wrapper that recursed
# into itself would hang, and must read as a failure instead.
denied() {
  local label="$1"; shift
  local before out rc
  list_intact || { local keep; keep="$(cat "${WT}/f")"; fresh; printf '%s\n' "${keep}" > f; }
  before="$(tree_state)"
  out="$( (export PATH="${APATH}"; timeout 60 "$@") 2>&1)"; rc=$?
  if [ "${rc}" -eq 1 ] && [[ "${out}" == *"git (agent wrapper): REFUSED"* ]] && [[ "${out}" == *"Fix:"* ]] \
    && list_intact && [ "$(tree_state)" = "${before}" ]; then ok "${label}"
  else bad "${label}" "rc=${rc} list_intact=$(list_intact && echo y || echo n) out=$(printf '%s' "${out}" | head -c 300)"; fi
}
# allowed <label> <cmd...>: through the wrapper; want rc 0, no refusal, list intact.
allowed() {
  local label="$1"; shift
  local out rc
  list_intact || fresh
  out="$( (export PATH="${APATH}"; timeout 60 "$@") 2>&1)"; rc=$?
  if [ "${rc}" -eq 0 ] && [[ "${out}" != *"REFUSED"* ]] && list_intact; then ok "${label}"
  else bad "${label}" "rc=${rc} out=$(printf '%s' "${out}" | head -c 300)"; fi
}

echo "agent-bin git wrapper self-test"
echo "wrapper: ${WRAPPER_SRC}"
echo "git:     ${G}"
echo

echo "--- D1: stash writes ---"
fresh; printf 'mine\n' >> f
denied "D1.1 bare git stash" git stash
denied "D1.2 git stash push" git stash push
denied "D1.3 git stash save" git stash save x
denied "D1.4 git stash -u" git stash -u
denied "D1.5 git stash -- f" git stash -- f
"${G}" checkout -q -- f
denied "D1.6 git stash pop" git stash pop
denied "D1.7 git stash pop --index" git stash pop --index
denied "D1.8 git stash apply" git stash apply
denied "D1.9 git stash drop" git stash drop
denied "D1.10 git stash drop stash@{1}" git stash drop 'stash@{1}'
denied "D1.11 git stash clear" git stash clear
denied "D1.12 git stash store <sha>" git stash store -m x "${STASH_REF}"
denied "D1.13 git stash branch" git stash branch newb
denied "D1.14 git stash --quiet pop (option first)" git stash --quiet pop

echo "--- aliases and config channels (resolved by asking git) ---"
denied "AL1. alias sp = stash pop" git sp
denied "AL2. alias chain -> sp" git chain
denied "AL3. alias s = stash (a push)" git s
denied "AL4. -c alias.p='stash pop' p" git -c 'alias.p=stash pop' p
denied "AL5. --config-env=alias.p=PENV" env PENV='stash pop' git --config-env=alias.p=PENV p
denied "AL6. --config-env alias.p=PENV (separate)" env PENV='stash pop' git --config-env alias.p=PENV p
denied "AL7. GIT_CONFIG_KEY_0=alias.p" env GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=alias.p GIT_CONFIG_VALUE_0='stash pop' git p
denied "AL8. GIT_CONFIG_PARAMETERS alias" env "GIT_CONFIG_PARAMETERS='alias.p=stash pop'" git p
denied "AL9. alias with a global option: -c color.ui=never stash pop" git z
denied "AL10. alias --no-pager stash" git np
denied "AL11. alias dd = stash drop (hook-invisible)" git dd
denied "AL12. alias rx = reflog expire --all (hook-invisible)" git rx
denied "AL13. shell alias !git stash pop" git pp
denied "AL14. repo-local alias" sh -c 'git config alias.lp "stash pop" && git lp'
"${G}" config --unset alias.lp

echo "--- other argv routes to git ---"
denied "R1. git -C <dir> stash pop" git -C "${WT}" stash pop
# xargs reports a child's exit 1 as 123; map it back so `denied` reads the wrapper's.
denied "R2. xargs-fed" sh -c "printf 'stash\npop\n' | xargs git; rc=\$?; [ \$rc -eq 123 ] && exit 1; exit \$rc"
denied "R3. python3 subprocess" python3 -c 'import subprocess,sys; sys.exit(subprocess.call(["git","stash","pop"]))'
denied "R4. command word from a variable" sh -c 'G=git; $G stash pop'
denied "R5. --git-dir= and --work-tree= stash pop" git --git-dir="${OWNER}/.git" --work-tree="${WT}" stash pop

echo "--- D2-D4: reflog and ref plumbing on the stash ---"
denied "D2.1 reflog delete refs/stash@{1}" git reflog delete 'refs/stash@{1}'
denied "D2.2 reflog delete stash@{0}" git reflog delete 'stash@{0}'
denied "D2.3 reflog expire --all" git reflog expire --expire=now --all
denied "D2.4 reflog expire refs/stash" git reflog expire --expire=now refs/stash
denied "D3.1 update-ref refs/stash HEAD" git update-ref refs/stash HEAD
denied "D3.2 update-ref -d refs/stash" git update-ref -d refs/stash
denied "D3.3 update-ref stash HEAD" git update-ref stash HEAD
denied "D4.1 symbolic-ref refs/stash" git symbolic-ref refs/stash refs/heads/main

echo "--- D5: tamper with the hook config ---"
denied "D5.1 -c hook.agentstash.command=true" git -c hook.agentstash.command=true commit --allow-empty -m x
denied "D5.2 -c hook.reference-transaction.enabled=false" git -c hook.reference-transaction.enabled=false commit --allow-empty -m x
denied "D5.3 -c HOOK.agentstash.enabled=false (case)" git -c HOOK.agentstash.enabled=false commit --allow-empty -m x
denied "D5.4 --config-env=hook.agentstash.enabled=E" env E=false git --config-env=hook.agentstash.enabled=E commit --allow-empty -m x
denied "D5.5 GIT_CONFIG_PARAMETERS" env "GIT_CONFIG_PARAMETERS='hook.agentstash.enabled=false'" git commit --allow-empty -m x
denied "D5.6 GIT_CONFIG_KEY_n disabling" env GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=hook.agentstash.enabled GIT_CONFIG_VALUE_0=false git commit --allow-empty -m x
denied "D5.7 GIT_CONFIG_KEY_n naming the command twice" env GIT_CONFIG_COUNT=2 GIT_CONFIG_KEY_0=hook.agentstash.command GIT_CONFIG_VALUE_0=a GIT_CONFIG_KEY_1=hook.agentstash.command GIT_CONFIG_VALUE_1=true git commit --allow-empty -m x
denied "D5.8 alias carrying -c hook.agentstash.command" git -c 'alias.cc=-c hook.agentstash.command=true commit' cc --allow-empty -m x

echo "--- allowed ---"
fresh
allowed "OK1. git stash list" git stash list
allowed "OK2. git stash show" git stash show
allowed "OK3. git stash create" git stash create
allowed "OK4. alias sl = stash list" git sl
allowed "OK5. commit -m naming git stash pop" git commit -q --allow-empty -m "git stash pop"
allowed "OK6. log --grep=stash" git log --grep=stash
allowed "OK7. -C \"\$D\" status (DND-799)" sh -c 'D="$1"; git -C "$D" status --short' _ "${WT}"
allowed "OK8. alias to a non-stash command" git st
allowed "OK9. --no-pager diff" git --no-pager diff
allowed "OK10. shell alias not naming stash" git pl
allowed "OK11. git --version" git --version
allowed "OK12. reflog expire on a branch ref" git reflog expire --expire=90.days.ago refs/heads/main
allowed "OK13. the injected hook config itself (4 keys, once each, enabled)" env GIT_CONFIG_COUNT=4 \
  GIT_CONFIG_KEY_0=hook.agentstash.event GIT_CONFIG_VALUE_0=reference-transaction \
  GIT_CONFIG_KEY_1=hook.agentstash.command GIT_CONFIG_VALUE_1=true \
  GIT_CONFIG_KEY_2=hook.agentstash.enabled GIT_CONFIG_VALUE_2=true \
  GIT_CONFIG_KEY_3=hook.reference-transaction.enabled GIT_CONFIG_VALUE_3=true git status --short
allowed "OK14. update-ref on a branch" git update-ref refs/heads/other HEAD
allowed "OK15. alias loop is left to git (no hang)" sh -c 'timeout 10 git loop1; [ $? -ne 124 ]'

echo "--- faults ---"
if [ "${AGENT_BIN_GIT_OFF:-}" = 1 ]; then
  bad "FT1-FT5. faults" "wrapper off PATH (baseline mode)"
else
  fresh
  printf '[alias\n\tbroken\n' > "${TMP}/bad-gitconfig"
  out="$( (export PATH="${APATH}" GIT_CONFIG_GLOBAL="${TMP}/bad-gitconfig"; git xyz) 2>&1)"
  if [[ "${out}" == *"could not resolve alias xyz"*"not checked"* ]]; then
    ok "FT1. an unreadable alias config prints the not-checked line (DND-802), then git decides"
  else bad "FT1. unreadable alias config is named" "out=${out}"; fi
  out="$(PATH="${WBIN}" "${WBIN}/git" status 2>&1)"; rc=$?
  if [ "${rc}" -eq 127 ] && [[ "${out}" == *"no real git on PATH"*"Fix:"* ]]; then
    ok "FT2. no real git on PATH: exit 127 with a Fix:"
  else bad "FT2. no real git" "rc=${rc} out=${out}"; fi
  mkdir -p "${TMP}/wb2"; cp "${WBIN}/git" "${TMP}/wb2/git"; fsg_require_stubs "${TMP}/wb2" git
  out="$(PATH="${WBIN}:${TMP}/wb2" timeout 5 "${WBIN}/git" status 2>&1)"; rc=$?
  if [ "${rc}" -eq 127 ]; then ok "FT3. two wrapper copies and no real git: exit 127, no recursion"
  else bad "FT3. wrapper copies never exec each other in a loop" "rc=${rc} (124 = hung) out=$(printf '%s' "${out}" | head -c 200)"; fi
  out="$(PATH="${WBIN}:${TMP}/wb2:${GDIR}" timeout 5 "${WBIN}/git" rev-parse --is-inside-work-tree 2>&1)"; rc=$?
  if [ "${rc}" -eq 0 ] && [ "${out}" = true ]; then ok "FT4. two wrapper copies then the real git: reaches git"
  else bad "FT4. chained wrappers reach git" "rc=${rc} out=${out}"; fi
  ln -s "${WBIN}" "${TMP}/wlink"
  out="$(PATH="${TMP}/wlink:${GDIR}" timeout 5 "${TMP}/wlink/git" stash pop 2>&1)"; rc=$?
  if [ "${rc}" -eq 1 ] && [[ "${out}" == *REFUSED* ]] && list_intact; then
    ok "FT5. a symlinked wrapper directory skips itself and still refuses"
  else bad "FT5. symlinked wrapper dir" "rc=${rc} out=${out}"; fi
  # DND-1103: a shim AHEAD of the wrapper on PATH that delegates back to it
  # (admiral-eval's sandbox git, a test's git.real symlink). The wrapper must
  # exec the git after its own entry, never the shim again: an exec loop ends
  # only at ARG_MAX ("Argument list too long") or the timeout.
  mkdir -p "${TMP}/shim" "${TMP}/shim2"
  printf '#!/bin/sh\nexec "%s/git" "$@"\n' "${WBIN}" > "${TMP}/shim/git"
  printf '#!/bin/sh\nexec git.real "$@"\n' > "${TMP}/shim2/git"
  ln -s "${WBIN}/git" "${TMP}/shim2/git.real"
  chmod +x "${TMP}/shim/git" "${TMP}/shim2/git"
  fsg_require_stubs "${TMP}/shim" git; fsg_require_stubs "${TMP}/shim2" git
  for s in shim shim2; do
    out="$(PATH="${TMP}/${s}:${WBIN}:${GDIR}" timeout 10 git --version 2>&1)"; rc=$?
    if [ "${rc}" -eq 0 ] && [[ "${out}" == "git version"* ]]; then
      ok "FT6. ${s} ahead of the wrapper execs it back: reaches the git after the wrapper"
    else bad "FT6. ${s} ahead of the wrapper" "rc=${rc} (124 = looped) out=$(printf '%s' "${out}" | head -c 200)"; fi
    fresh
    out="$(PATH="${TMP}/${s}:${WBIN}:${GDIR}" timeout 10 git stash pop 2>&1)"; rc=$?
    if [ "${rc}" -eq 1 ] && [[ "${out}" == *REFUSED*"Fix:"* ]] && list_intact; then
      ok "FT7. ${s} ahead of the wrapper: a refused form is still refused"
    else bad "FT7. ${s} ahead of the wrapper still refuses" "rc=${rc} out=$(printf '%s' "${out}" | head -c 200)"; fi
  done
  # The fallback layouts: nothing after the wrapper's entry (or no entry), so
  # the first git anywhere stands in, and that is the shim. The shim is then
  # remembered as passed through, and the second pass reaches the real git.
  for layout in "A|${TMP}/shim:${GDIR}" "B|${TMP}/shim:${GDIR}:${WBIN}"; do
    name="${layout%%|*}"; lp="${layout#*|}"
    out="$(PATH="${lp}" timeout 10 "${WBIN}/git" --version 2>&1)"; rc=$?
    if [ "${rc}" -eq 0 ] && [[ "${out}" == "git version"* ]]; then
      ok "FT10${name}. shim ahead, no git after the wrapper: the shim is passed through once, git is reached"
    else bad "FT10${name}. fallback layout ${lp}" "rc=${rc} (124 = looped) out=$(printf '%s' "${out}" | head -c 200)"; fi
    fresh
    out="$(PATH="${lp}" timeout 10 "${WBIN}/git" stash pop 2>&1)"; rc=$?
    if [ "${rc}" -eq 1 ] && [[ "${out}" == *REFUSED*"Fix:"* ]] && list_intact; then
      ok "FT11${name}. fallback layout: a refused form is still refused"
    else bad "FT11${name}. fallback layout still refuses" "rc=${rc} out=$(printf '%s' "${out}" | head -c 200)"; fi
  done
  TO="$(command -v timeout)"
  out="$(PATH="${TMP}/shim" "${TO}" 10 "${WBIN}/git" --version 2>&1)"; rc=$?
  if [ "${rc}" -eq 127 ] && [[ "${out}" == *"no real git on PATH"*"Fix:"* ]]; then
    ok "FT12. a shim that execs the wrapper and no real git: exit 127 with a Fix:, never a loop"
  else bad "FT12. shim and no real git" "rc=${rc} (124 = looped) out=$(printf '%s' "${out}" | head -c 200)"; fi
  # ai/lib/agent-free-git.sh, the fixtures' way to the real git (DND-1103):
  # it skips the wrapper, and a PATH holding only the wrapper is a named miss.
  out="$(PATH="${WBIN}:${GDIR}" bash -c '. "$1"; agent_free_git' _ "${ROOT}/ai/lib/agent-free-git.sh" 2>&1)"; rc=$?
  if [ "${rc}" -eq 0 ] && [ "${out}" = "${GDIR}/git" ]; then ok "FT8. agent_free_git skips the wrapper and names the git after it"
  else bad "FT8. agent_free_git skips the wrapper" "rc=${rc} out=${out}"; fi
  out="$(PATH="${WBIN}" "${BASH}" -c '. "$1"; agent_free_git' _ "${ROOT}/ai/lib/agent-free-git.sh" 2>&1)"; rc=$?
  if [ "${rc}" -eq 1 ] && [[ "${out}" == *"besides the agent wrapper"*"Fix:"* ]]; then
    ok "FT9. agent_free_git with only the wrapper on PATH: exit 1 with a Fix:, never the wrapper's path"
  else bad "FT9. agent_free_git names the miss" "rc=${rc} out=${out}"; fi
fi

echo "--- false-positive corpus: non-git commands never reach git (DND-799/800/786) ---"
# A recorder `git` is the only git on PATH: a command that never execs git
# leaves its log empty, so the wrapper cannot have run. gh and docker are
# no-op stubs (the payload reaches them as argv; nothing contacts a network).
TB="${TMP}/tracebin"; mkdir -p "${TB}"
printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "%s/git.log"\nexit 0\n' "${TMP}" > "${TB}/git"
printf '#!/bin/sh\nexit 0\n' > "${TB}/gh"; printf '#!/bin/sh\nexit 0\n' > "${TB}/docker"
chmod +x "${TB}/git" "${TB}/gh" "${TB}/docker"
# DND-1647/DND-1667: a guard stands behind every gh/git/docker stub on PATH,
# so a stub that is missing or not executable fails the suite instead of
# reaching the real tool (ai/lib/forge-stub-guard.sh). From here on every git
# the suite runs is "${G}" or a PATH it builds itself.
fsg_arm "${TMP}/forge-guard" gh glab git docker
fsg_require_stubs "${TB}" gh git docker
FP="${TMP}/fp"; mkdir -p "${FP}/dir"
printf 'FAIL one\npassed two\nstash word\n12\n' > "${FP}/f"; cp "${FP}/f" "${FP}/g"; cp "${FP}/f" "${FP}/dir/h"
printf '[1,2]\n' > "${FP}/f.json"
while IFS= read -r c; do
  [ -n "${c}" ] || continue
  : > "${TMP}/git.log"
  ( cd "${FP}" && PATH="${TB}:${FSG_DIR}:${BASEPATH}" bash -c "${c}" ) >/dev/null 2>&1
  if [ ! -s "${TMP}/git.log" ]; then ok "FP. never reaches git: ${c}"
  else bad "FP. ${c}" "git was exec'd: $(cat "${TMP}/git.log")"; fi
done <<'CORPUS'
gh pr view -q '{state,checks:[.statusCheckRollup[]|{name,conclusion}]}'
gh run list -q '.[] | "\(.headSha[0:8])"'
python3 -c '[print(p) for p in ["a"]]'
grep -E 'FAIL|passed' f
grep -rn 'a\|b' dir
grep -i stash f
grep -n -i stash f g
python3 -c 'd=[{"text": 1}]; print(d[0]["text"])'
/usr/bin/ruby -e 'fix = 1; puts "#{fix}"'
python3 -c 'import sys; p=sys.argv[1]' x
gh pr view --jq '{reviews: .reviews}'
docker ps --format '{{.Names}}'
grep '[0-9]\+' f
jq '.[]' f.json
test '[ ]'
grep '[1-9]' f
awk '{a[$1]++}' f
v=; echo "${v:-x}"
printf '%s\n' 'git stash pop' > script-naming-stash.sh
CORPUS
# The heredoc forms, as files (a heredoc cannot sit on one corpus line).
printf 'python3 - <<'"'"'EOF'"'"'\nprint("abcdef"[0:2])\nEOF\n' > "${TMP}/hd1.sh"
printf 'cat > s.sh <<'"'"'EOF'"'"'\ngit stash pop\nEOF\n' > "${TMP}/hd2.sh"
printf '/usr/bin/ruby - <<'"'"'EOF'"'"'\nfix = 1\nputs "#{fix}"\nEOF\n' > "${TMP}/hd3.sh"
for h in hd1 hd2 hd3; do
  : > "${TMP}/git.log"
  ( cd "${FP}" && PATH="${TB}:${FSG_DIR}:${BASEPATH}" bash "${TMP}/${h}.sh" ) >/dev/null 2>&1
  if [ ! -s "${TMP}/git.log" ]; then ok "FP. never reaches git: heredoc ${h} ($(sed -n 2p "${TMP}/${h}.sh"))"
  else bad "FP. heredoc ${h}" "git was exec'd: $(cat "${TMP}/git.log")"; fi
done
# The corpus commands that DO run git reach the wrapper and are allowed.
fresh
allowed "FP-git. git -C \"\$D\" log" sh -c 'D="$1"; git -C "$D" log -1 --oneline' _ "${WT}"
allowed "FP-git. ls of \$(git --exec-path)/git-stash" sh -c 'ls -la "$(git --exec-path)/git-stash" >/dev/null 2>&1; true'

# DND-1647/DND-1667: no call may have fallen through past its stub.
if fsg_verify; then ok "no gh/glab/git/docker call fell through past its stub (DND-1647/DND-1667)"
else bad "no gh/glab/git/docker call fell through past its stub (DND-1647/DND-1667)" "see the forge-stub-guard FAIL above"; fi

echo
echo "==================================================="
printf 'RESULT: %d passed, %d failed\n' "${PASS}" "${FAIL}"
if [ "${FAIL}" -eq 0 ]; then echo "VERDICT: PASS"; exit 0; fi
echo "VERDICT: FAIL"
exit 1
