#!/usr/bin/env bash
# Self-test for the gh-athena `git` passthrough (DND-389).
#
# The defect this pins: `gh-athena git push` against an SSH-form remote went out
# over SSH with the machine OWNER's key, so GitHub recorded every agent push as
# CJPoll. Nothing failed and nothing said so. The wrapper now (a) rewrites the
# SSH form to HTTPS, (b) keeps every owner credential source out, and (c) REFUSES
# a network op that would still reach github.com over a non-HTTPS transport.
#
# NO NETWORK, EVER. GIT_ALLOW_PROTOCOL=file makes git itself refuse every
# non-local transport, GIT_SSH_COMMAND=false backs that up, the global/system git
# config is replaced with a sandbox file, and the App token comes from a fixture
# cache (no mint). Resolution is observed through the GH_ATHENA_GIT_DRY_RUN=1
# seam, which prints the resolved URLs and the git argv instead of exec'ing.
#
# Run against another copy of the wrapper (old-vs-new evidence) with
#   GH_ATHENA_UNDER_TEST=/path/to/gh-athena bash ai/test/gh-athena/self-test.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AI_DIR="$(cd "${HERE}/../.." && pwd)"
WRAPPER="${GH_ATHENA_UNDER_TEST:-${AI_DIR}/bin/gh-athena}"

TMP="$(mktemp -d)"; trap 'rm -rf "${TMP}"' EXIT
PASS=0; FAIL=0
ok()  { printf '  ok    %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  FAIL  %s\n        %s\n' "$1" "$2"; FAIL=$((FAIL+1)); }

# ---- hermetic environment ---------------------------------------------------
export GIT_CONFIG_NOSYSTEM=1
export GIT_CONFIG_GLOBAL="${TMP}/gitconfig"
printf '[user]\n\tname = t\n\temail = t@t\n[init]\n\tdefaultBranch = main\n' > "${GIT_CONFIG_GLOBAL}"
export GIT_ALLOW_PROTOCOL=file
export GIT_SSH_COMMAND=false
export GIT_TERMINAL_PROMPT=0
FAKE_TOKEN="ghs_SELFTESTFAKETOKEN0000"
printf '12345\n' > "${TMP}/app-id"
printf 'not-a-key\n' > "${TMP}/key.pem"
printf '%s\t%s\n' "${FAKE_TOKEN}" "$(( $(date +%s) + 86400 ))" > "${TMP}/token-cache"
chmod 600 "${TMP}/token-cache"
export GH_ATHENA_APP_ID_FILE="${TMP}/app-id"
export GH_ATHENA_KEY="${TMP}/key.pem"
export GH_ATHENA_TOKEN_CACHE="${TMP}/token-cache"

# new_repo <name> <origin-url> -> a repo with one commit, origin set, echoes path.
new_repo() {
  local d="${TMP}/$1"
  git init -q "${d}" && git -C "${d}" commit -q --allow-empty -m init \
    && git -C "${d}" remote add origin "$2"
  printf '%s' "${d}"
}

# gha <dir> <args...> : run the wrapper's git passthrough in <dir>, dry-run.
gha() {
  local d="$1"; shift
  OUT="$(cd "${d}" && GH_ATHENA_GIT_DRY_RUN=1 "${WRAPPER}" git "$@" 2>"${TMP}/err")"; RC=$?
  ERR="$(cat "${TMP}/err")"
}

is_refusal() { [ "${RC}" = 3 ] && [[ "${ERR}" == *"REFUSING"* ]] && [[ "${ERR}" == *"Fix:"* ]] \
  && [[ "${ERR}" == *"escalate to your admiral"* ]]; }

echo "gh-athena git-passthrough self-test"
echo "wrapper: ${WRAPPER}"
echo

echo "--- HIT: an SSH-form origin is rewritten to HTTPS with bot auth ---"
R="$(new_repo scp 'git@github.com:o/r.git')"
gha "${R}" push origin HEAD
if [ "${RC}" = 0 ] && [[ "${OUT}" == *"dry-run: url https://github.com/o/r.git"* ]] \
  && [[ "${OUT}" == *"[credential.helper=]"* ]] \
  && [[ "${OUT}" == *"[url.https://github.com/.insteadOf=git@github.com:]"* ]] \
  && [[ "${OUT}" == *"GIT_CONFIG_KEY_0=[http.https://github.com/.extraheader] GIT_CONFIG_VALUE_0=[AUTHORIZATION: basic <x-access-token:REDACTED>]"* ]] \
  && [[ "${OUT}" != *"exec git"*"extraheader"* ]] \
  && [[ "${OUT}" == *"[core.askPass=]"* ]]; then
  ok "1. git@github.com: origin -> https://github.com/o/r.git, helper off, bot header via env (not argv)"
else bad "1. SSH-form origin rewritten with bot auth" "rc=${RC} out='${OUT}' err='${ERR}'"; fi

B64="$(printf 'x-access-token:%s' "${FAKE_TOKEN}" | openssl base64 -A)"
if [[ "${OUT}${ERR}" != *"${FAKE_TOKEN}"* ]] && [[ "${OUT}${ERR}" != *"${B64}"* ]]; then
  ok "2. dry-run never prints the token (raw or base64)"
else bad "2. dry-run leaks the token" "out='${OUT}'"; fi

gha "${R}" push
if [ "${RC}" = 0 ] && [[ "${OUT}" == *"dry-run: url https://github.com/o/r.git"* ]]; then
  ok "3. bare \`push\` resolves the default remote (origin) and rewrites it"
else bad "3. default-remote push rewritten" "rc=${RC} out='${OUT}' err='${ERR}'"; fi

gha "${R}" -c credential.helper= -c 'url.https://github.com/.insteadOf=git@github.com:' push origin HEAD
if [ "${RC}" = 0 ] && [[ "${OUT}" == *"dry-run: url https://github.com/o/r.git"* ]]; then
  ok "3b. the documented explicit form (caller's own -c flags) still resolves to HTTPS"
else bad "3b. explicit universal form" "rc=${RC} out='${OUT}' err='${ERR}'"; fi

echo
echo "--- MISS: a push the rewrite cannot cover is REFUSED with a Fix: ---"
R="$(new_repo sshurl 'ssh://git@github.com/o/r.git')"
gha "${R}" push origin HEAD
is_refusal && ok "4. ssh:// origin -> refused (exit 3, Fix:, escalate)" \
  || bad "4. ssh:// origin refused" "rc=${RC} out='${OUT}' err='${ERR}'"

R="$(new_repo pushurl 'https://github.com/o/r.git')"
git -C "${R}" config remote.origin.pushurl 'ssh://git@github.com/o/r.git'
gha "${R}" push origin HEAD
is_refusal && ok "5. https origin with an ssh:// pushurl override -> refused" \
  || bad "5. pushurl override refused" "rc=${RC} out='${OUT}' err='${ERR}'"

R="$(new_repo pushinsteadof 'https://github.com/o/r.git')"
gha "${R}" -c 'url.git@github.com:.pushInsteadOf=https://github.com/' push origin HEAD
is_refusal && ok "6. a pushInsteadOf that forces SSH -> refused" \
  || bad "6. pushInsteadOf-to-SSH refused" "rc=${RC} out='${OUT}' err='${ERR}'"

R="$(new_repo literal 'https://github.com/o/r.git')"
gha "${R}" push ssh://git@github.com/o/other.git HEAD
is_refusal && ok "7. a literal ssh:// URL argument -> refused" \
  || bad "7. literal ssh:// refused" "rc=${RC} out='${OUT}' err='${ERR}'"

gha "${R}" push http://github.com/o/other.git HEAD
is_refusal && ok "8. a literal http:// (non-TLS) URL -> refused" \
  || bad "8. literal http:// refused" "rc=${RC} out='${OUT}' err='${ERR}'"

R="$(new_repo dashu 'ssh://git@github.com/o/r.git')"
gha "${R}" push -u origin HEAD
is_refusal && ok "9. \`push -u origin HEAD\` (flag before the remote) -> refused" \
  || bad "9. push -u refused" "rc=${RC} out='${OUT}' err='${ERR}'"

gha "${TMP}" -C "${R}" push origin HEAD
is_refusal && ok "10. \`-C <repo> push\` from outside the repo -> refused (global opts replayed)" \
  || bad "10. -C push refused" "rc=${RC} out='${OUT}' err='${ERR}'"

R="$(new_repo pushremote 'https://github.com/o/r.git')"
git -C "${R}" remote add sshr 'ssh://git@github.com/o/r.git'
git -C "${R}" config branch.main.pushRemote sshr
gha "${R}" push
is_refusal && ok "11. branch.<cur>.pushRemote -> an ssh:// remote -> refused" \
  || bad "11. pushRemote default refused" "rc=${RC} out='${OUT}' err='${ERR}'"

gha "${R}" fetch --all
is_refusal && ok "12. \`fetch --all\` with an ssh:// remote among them -> refused" \
  || bad "12. fetch --all refused" "rc=${RC} out='${OUT}' err='${ERR}'"

gha "${TMP}" clone ssh://git@github.com/o/r.git "${TMP}/clone-out"
is_refusal && ok "13. \`clone ssh://git@github.com/...\` outside any repo -> refused" \
  || bad "13. clone ssh:// refused" "rc=${RC} out='${OUT}' err='${ERR}'"

R="$(new_repo alias 'ssh://git@github.com/o/r.git')"
gha "${R}" -c alias.p=push p origin HEAD
is_refusal && ok "13b. a git alias expanding to push (alias.p=push) -> refused" \
  || bad "13b. alias to push refused" "rc=${RC} out='${OUT}' err='${ERR}'"

gha "${R}" -c 'alias.sp=!git push' sp
is_refusal && [[ "${ERR}" == *"shell alias"* ]] && ok "13c. a shell alias (!...) -> refused (cannot be checked)" \
  || bad "13c. shell alias refused" "rc=${RC} out='${OUT}' err='${ERR}'"

R2="$(new_repo alias-opt 'https://github.com/o/r.git')"
gha "${R2}" -c 'alias.p=-c url.git@github.com:.pushInsteadOf=https://github.com/ push' p origin HEAD
is_refusal && ok "13c2. an alias that starts with -c (forcing SSH via pushInsteadOf) -> refused" \
  || bad "13c2. alias with leading -c refused" "rc=${RC} out='${OUT}' err='${ERR}'"

R="$(new_repo submod 'https://github.com/o/r.git')"
git -C "${R}" config submodule.lib.url 'ssh://git@github.com/o/lib.git'
gha "${R}" submodule update --init
is_refusal && ok "13d. \`submodule update\` with an ssh:// submodule URL -> refused" \
  || bad "13d. submodule update refused" "rc=${RC} out='${OUT}' err='${ERR}'"

gha "${R}" fetch --recurse-submodules origin
is_refusal && ok "13e. \`fetch --recurse-submodules\` with an ssh:// submodule URL -> refused" \
  || bad "13e. fetch --recurse-submodules refused" "rc=${RC} out='${OUT}' err='${ERR}'"

gha "${R}" push --recurse-submodules=on-demand origin HEAD
is_refusal && ok "13f. \`push --recurse-submodules=on-demand\` -> refused (submodule remotes unchecked)" \
  || bad "13f. recursive push refused" "rc=${RC} out='${OUT}' err='${ERR}'"

gha "${R}" subtree push -P lib ssh://git@github.com/o/lib.git main
is_refusal && ok "13g. \`subtree push -P lib ssh://...\` -> refused" \
  || bad "13g. subtree push refused" "rc=${RC} out='${OUT}' err='${ERR}'"

echo
echo "--- NEGATIVE: what must pass untouched ---"
R="$(new_repo alias-local 'ssh://git@github.com/o/r.git')"
gha "${R}" -c alias.st=status st
if [ "${RC}" = 0 ] && [ -z "${ERR}" ]; then
  ok "13h. an alias to a local command (alias.st=status) is not refused"
else bad "13h. local alias passes" "rc=${RC} out='${OUT}' err='${ERR}'"; fi

gha "${R}" -c alias.pz=push -c url.https://github.com/.insteadOf=ssh://git@github.com/ pz origin HEAD
if [ "${RC}" = 0 ] && [[ "${OUT}" == *"dry-run: url https://github.com/o/r.git"* ]]; then
  ok "13i. an aliased push whose remote DOES resolve to HTTPS passes"
else bad "13i. aliased https push passes" "rc=${RC} out='${OUT}' err='${ERR}'"; fi

R="$(new_repo https 'https://github.com/o/r.git')"
gha "${R}" push origin HEAD
if [ "${RC}" = 0 ] && [[ "${OUT}" == *"dry-run: url https://github.com/o/r.git"* ]] && [ -z "${ERR}" ]; then
  ok "14. an HTTPS origin is untouched (same URL, no refusal)"
else bad "14. HTTPS origin untouched" "rc=${RC} out='${OUT}' err='${ERR}'"; fi

R="$(new_repo status-only 'ssh://git@github.com/o/r.git')"
gha "${R}" status --short
if [ "${RC}" = 0 ] && [[ "${OUT}" == *"dry-run: exec git"* ]] && [ -z "${ERR}" ]; then
  ok "15. a non-network command (status) is not refused, even with an ssh:// origin"
else bad "15. non-network command passes" "rc=${RC} out='${OUT}' err='${ERR}'"; fi

# A REAL exec (no dry-run) to a local bare remote whose path contains
# github.com (a Go-workspace-style path): proves the injected -c options do not
# break a real push, and that a local path is never mistaken for github.com.
BARE="${TMP}/go/src/github.com/o/r.git"; mkdir -p "$(dirname "${BARE}")"
git init -q --bare "${BARE}"
R="$(new_repo real "${BARE}")"
( cd "${R}" && "${WRAPPER}" git push -q origin HEAD:refs/heads/landed ) >"${TMP}/out" 2>"${TMP}/err"; RC=$?
if [ "${RC}" = 0 ] && [ "$(git -C "${BARE}" rev-parse refs/heads/landed 2>/dev/null)" = "$(git -C "${R}" rev-parse HEAD)" ]; then
  ok "16. real exec: push to a local bare remote under .../github.com/... lands"
else bad "16. real local push lands" "rc=${RC} err='$(cat "${TMP}/err")'"; fi

# A REAL exec of a local command through the wrapper: git itself must see the
# bot header for https://github.com/ (proves the env config channel is wired,
# not just printed), and the token must not be on git's argv.
R="$(new_repo hdr 'git@github.com:o/r.git')"
( cd "${R}" && "${WRAPPER}" git config --get-all http.https://github.com/.extraheader ) >"${TMP}/out" 2>"${TMP}/err"; RC=$?
if [ "${RC}" = 0 ] && [ "$(cat "${TMP}/out")" = "AUTHORIZATION: basic ${B64}" ]; then
  ok "17. real exec: git sees the x-access-token basic header for https://github.com/"
else bad "17. git sees the bot header" "rc=${RC} out='$(cat "${TMP}/out")' err='$(cat "${TMP}/err")'"; fi

echo
echo "==================================================="
printf 'RESULT: %d passed, %d failed\n' "${PASS}" "${FAIL}"
echo "==================================================="
[ "${FAIL}" -eq 0 ] || exit 1
echo "ALL CASES PASS"
exit 0
