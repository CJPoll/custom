#!/usr/bin/env bash
# Self-test for the glab-athena `git` passthrough (DND-393).
#
# The defect this pins: glab-athena had no git passthrough, so every agent push
# to gitlab.com went out over SSH with the machine OWNER's key and GitLab
# recorded the owner, with nothing saying so. The wrapper now (a) rewrites the
# SSH form git@gitlab.com: to HTTPS, (b) keeps every owner credential source
# out, (c) authenticates as athena-amby with the PAT from its token file, and
# (d) REFUSES a network op that would still reach gitlab.com over non-HTTPS.
#
# NO NETWORK, EVER. GIT_ALLOW_PROTOCOL=file makes git itself refuse every
# non-local transport, GIT_SSH_COMMAND=false backs that up, the global/system git
# config is replaced with a sandbox file, and the PAT comes from a fixture token
# file. Resolution is observed through the GLAB_ATHENA_GIT_DRY_RUN=1 seam.
#
# Gated: ai/bin/harness-gate's discover_self_tests runs every tracked
# **/self-test.sh (this file reports as `self-test: ai/test/glab-athena`).
#
# Run against another copy of the wrapper (old-vs-new evidence) with
#   GLAB_ATHENA_UNDER_TEST=/path/to/glab-athena bash ai/test/glab-athena/self-test.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AI_DIR="$(cd "${HERE}/../.." && pwd)"
WRAPPER="${GLAB_ATHENA_UNDER_TEST:-${AI_DIR}/bin/glab-athena}"

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
unset GIT_CONFIG_COUNT
FAKE_TOKEN="glpat-SELFTESTFAKETOKEN0000"
printf '%s\n' "${FAKE_TOKEN}" > "${TMP}/token"
chmod 600 "${TMP}/token"
export GITLAB_ATHENA_TOKEN_FILE="${TMP}/token"
# If the wrapper under test has no passthrough it would exec glab: make any
# glab it reaches a harmless stub that says so, never the real CLI.
mkdir -p "${TMP}/stubbin"
printf '#!/bin/sh\necho "STUB-GLAB-REACHED $*"\nexit 97\n' > "${TMP}/stubbin/glab"
chmod +x "${TMP}/stubbin/glab"
export PATH="${TMP}/stubbin:${PATH}"

# new_repo <name> <origin-url> -> a repo with one commit, origin set, echoes path.
new_repo() {
  local d="${TMP}/$1"
  git init -q "${d}" && git -C "${d}" commit -q --allow-empty -m init \
    && git -C "${d}" remote add origin "$2"
  printf '%s' "${d}"
}

# gla <dir> <args...> : run the wrapper's git passthrough in <dir>, dry-run.
gla() {
  local d="$1"; shift
  OUT="$(cd "${d}" && GLAB_ATHENA_GIT_DRY_RUN=1 "${WRAPPER}" git "$@" 2>"${TMP}/err")"; RC=$?
  ERR="$(cat "${TMP}/err")"
}

is_refusal() { [ "${RC}" = 3 ] && [[ "${ERR}" == *"REFUSING"* ]] && [[ "${ERR}" == *"Fix:"* ]] \
  && [[ "${ERR}" == *"escalate to your admiral"* ]]; }

B64="$(printf 'oauth2:%s' "${FAKE_TOKEN}" | openssl base64 -A)"

echo "glab-athena git-passthrough self-test"
echo "wrapper: ${WRAPPER}"
echo

echo "--- HIT: an SSH-form origin is rewritten to HTTPS with the PAT header ---"
R="$(new_repo scp 'git@gitlab.com:amby_ai/walt_ui.git')"
gla "${R}" push origin HEAD
if [ "${RC}" = 0 ] && [[ "${OUT}" == *"dry-run: url https://gitlab.com/amby_ai/walt_ui.git"* ]] \
  && [[ "${OUT}" == *"[credential.helper=]"* ]] \
  && [[ "${OUT}" == *"[core.askPass=]"* ]] \
  && [[ "${OUT}" == *"[url.https://gitlab.com/.insteadOf=git@gitlab.com:]"* ]] \
  && [[ "${OUT}" == *"GIT_CONFIG_KEY_0=[http.https://gitlab.com/.extraheader] GIT_CONFIG_VALUE_0=[AUTHORIZATION: basic <oauth2:REDACTED>]"* ]]; then
  ok "1. git@gitlab.com: origin -> https://gitlab.com/..., helper off, oauth2 PAT header via env"
else bad "1. SSH-form origin rewritten with PAT header" "rc=${RC} out='${OUT}' err='${ERR}'"; fi

if [[ "${OUT}${ERR}" != *"${FAKE_TOKEN}"* ]] && [[ "${OUT}${ERR}" != *"${B64}"* ]] \
  && [[ "$(printf '%s' "${OUT}" | grep 'exec git')" != *extraheader* ]]; then
  ok "2. dry-run never prints the PAT (raw or base64) and the header is not on argv"
else bad "2. dry-run leaks the PAT or puts the header on argv" "out='${OUT}'"; fi

gla "${R}" push
if [ "${RC}" = 0 ] && [[ "${OUT}" == *"dry-run: url https://gitlab.com/amby_ai/walt_ui.git"* ]]; then
  ok "3. bare \`push\` resolves the default remote (origin) and rewrites it"
else bad "3. default-remote push rewritten" "rc=${RC} out='${OUT}' err='${ERR}'"; fi

gla "${R}" push -u origin HEAD:refs/heads/feature
if [ "${RC}" = 0 ] && [[ "${OUT}" == *"dry-run: url https://gitlab.com/amby_ai/walt_ui.git"* ]]; then
  ok "3b. \`push -u origin HEAD:<ref>\` rewrites"
else bad "3b. push -u rewritten" "rc=${RC} out='${OUT}' err='${ERR}'"; fi

echo
echo "--- MISS: a remote the rewrite cannot cover is REFUSED with a Fix: ---"
R="$(new_repo sshurl 'ssh://git@gitlab.com/amby_ai/walt_ui.git')"
gla "${R}" push origin HEAD
is_refusal && [[ "${ERR}" == *"gitlab.com"* ]] && [[ "${ERR}" == *"athena-amby"* ]] \
  && ok "4. ssh://git@gitlab.com/ origin -> refused (exit 3, Fix:, escalate, names athena-amby)" \
  || bad "4. ssh:// origin refused" "rc=${RC} out='${OUT}' err='${ERR}'"

R="$(new_repo pushurl 'https://gitlab.com/amby_ai/walt_ui.git')"
git -C "${R}" config remote.origin.pushurl 'ssh://git@gitlab.com/amby_ai/walt_ui.git'
gla "${R}" push origin HEAD
is_refusal && ok "5. https origin with an ssh:// pushurl override -> refused" \
  || bad "5. pushurl override refused" "rc=${RC} out='${OUT}' err='${ERR}'"

R="$(new_repo pushinsteadof 'https://gitlab.com/amby_ai/walt_ui.git')"
gla "${R}" -c 'url.git@gitlab.com:.pushInsteadOf=https://gitlab.com/' push origin HEAD
is_refusal && ok "6. a pushInsteadOf that forces SSH -> refused" \
  || bad "6. pushInsteadOf-to-SSH refused" "rc=${RC} out='${OUT}' err='${ERR}'"

R="$(new_repo literal 'https://gitlab.com/amby_ai/walt_ui.git')"
gla "${R}" push ssh://git@gitlab.com:22/amby_ai/other.git HEAD
is_refusal && ok "7. a literal ssh://...:22 URL argument -> refused" \
  || bad "7. literal ssh:// refused" "rc=${RC} out='${OUT}' err='${ERR}'"

gla "${R}" push http://gitlab.com/amby_ai/other.git HEAD
is_refusal && ok "8. a literal http:// (non-TLS) URL -> refused" \
  || bad "8. literal http:// refused" "rc=${RC} out='${OUT}' err='${ERR}'"

R="$(new_repo pushremote 'https://gitlab.com/amby_ai/walt_ui.git')"
git -C "${R}" remote add sshr 'ssh://git@gitlab.com/amby_ai/walt_ui.git'
git -C "${R}" config branch.main.pushRemote sshr
gla "${R}" push
is_refusal && ok "9. branch.<cur>.pushRemote -> an ssh:// remote -> refused" \
  || bad "9. pushRemote default refused" "rc=${RC} out='${OUT}' err='${ERR}'"

gla "${TMP}" -C "${R}" push sshr HEAD
is_refusal && ok "10. \`-C <repo> push\` from outside the repo -> refused (global opts replayed)" \
  || bad "10. -C push refused" "rc=${RC} out='${OUT}' err='${ERR}'"

R="$(new_repo alias 'ssh://git@gitlab.com/amby_ai/walt_ui.git')"
gla "${R}" -c alias.p=push p origin HEAD
is_refusal && ok "11. a git alias expanding to push -> refused" \
  || bad "11. alias to push refused" "rc=${RC} out='${OUT}' err='${ERR}'"

gla "${R}" -c 'alias.sp=!git push' sp
is_refusal && [[ "${ERR}" == *"shell alias"* ]] && ok "12. a shell alias (!...) -> refused" \
  || bad "12. shell alias refused" "rc=${RC} out='${OUT}' err='${ERR}'"

R="$(new_repo submod 'https://gitlab.com/amby_ai/walt_ui.git')"
gla "${R}" push --recurse-submodules=on-demand origin HEAD
is_refusal && ok "13. \`push --recurse-submodules=on-demand\` -> refused" \
  || bad "13. recursive push refused" "rc=${RC} out='${OUT}' err='${ERR}'"

R="$(new_repo notoken 'git@gitlab.com:amby_ai/walt_ui.git')"
( cd "${R}" && GITLAB_ATHENA_TOKEN_FILE="${TMP}/no-such-token" GLAB_ATHENA_GIT_DRY_RUN=1 "${WRAPPER}" git push origin HEAD ) \
  >"${TMP}/out" 2>"${TMP}/err"; RC=$?; OUT="$(cat "${TMP}/out")"; ERR="$(cat "${TMP}/err")"
is_refusal && [[ "${ERR}" == *"token file"* ]] && [[ "${ERR}" == *"refresh"* ]] \
  && ok "14. a missing token file -> refused (never falls back to the owner), says not to refresh" \
  || bad "14. missing token refused" "rc=${RC} out='${OUT}' err='${ERR}'"

echo
echo "--- NEGATIVE: what must pass untouched ---"
R="$(new_repo https 'https://gitlab.com/amby_ai/walt_ui.git')"
gla "${R}" push origin HEAD
if [ "${RC}" = 0 ] && [[ "${OUT}" == *"dry-run: url https://gitlab.com/amby_ai/walt_ui.git"* ]] && [ -z "${ERR}" ]; then
  ok "15. an HTTPS origin is untouched (same URL, no refusal)"
else bad "15. HTTPS origin untouched" "rc=${RC} out='${OUT}' err='${ERR}'"; fi

R="$(new_repo status-only 'ssh://git@gitlab.com/amby_ai/walt_ui.git')"
gla "${R}" status --short
if [ "${RC}" = 0 ] && [[ "${OUT}" == *"dry-run: exec git"* ]] && [ -z "${ERR}" ]; then
  ok "16. a non-network command (status) is not refused, even with an ssh:// origin"
else bad "16. non-network command passes" "rc=${RC} out='${OUT}' err='${ERR}'"; fi

# A REAL exec (no dry-run) to a local bare remote whose path contains
# gitlab.com: the injected options do not break a real push, and a local path
# is never mistaken for gitlab.com.
BARE="${TMP}/src/gitlab.com/amby_ai/r.git"; mkdir -p "$(dirname "${BARE}")"
git init -q --bare "${BARE}"
R="$(new_repo real "${BARE}")"
( cd "${R}" && "${WRAPPER}" git push -q origin HEAD:refs/heads/landed ) >"${TMP}/out" 2>"${TMP}/err"; RC=$?
if [ "${RC}" = 0 ] && [ "$(git -C "${BARE}" rev-parse refs/heads/landed 2>/dev/null)" = "$(git -C "${R}" rev-parse HEAD)" ]; then
  ok "17. real exec: push to a local bare remote under .../gitlab.com/... lands"
else bad "17. real local push lands" "rc=${RC} err='$(cat "${TMP}/err")'"; fi

# A REAL exec of a local command: git itself must see the oauth2 PAT header for
# https://gitlab.com/ (proves the env channel is wired, not just printed).
R="$(new_repo hdr 'git@gitlab.com:amby_ai/walt_ui.git')"
( cd "${R}" && "${WRAPPER}" git config --get-all http.https://gitlab.com/.extraheader ) >"${TMP}/out" 2>"${TMP}/err"; RC=$?
if [ "${RC}" = 0 ] && [ "$(cat "${TMP}/out")" = "AUTHORIZATION: basic ${B64}" ]; then
  ok "18. real exec: git sees the oauth2:<PAT> basic header for https://gitlab.com/"
else bad "18. git sees the PAT header" "rc=${RC} out='$(cat "${TMP}/out")' err='$(cat "${TMP}/err")'"; fi

# A caller's own GIT_CONFIG_COUNT entries survive: the header is appended.
( cd "${R}" && GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=user.name GIT_CONFIG_VALUE_0=kept \
    "${WRAPPER}" git config --get user.name ) >"${TMP}/out" 2>"${TMP}/err"; RC=$?
( cd "${R}" && GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=user.name GIT_CONFIG_VALUE_0=kept \
    "${WRAPPER}" git config --get-all http.https://gitlab.com/.extraheader ) >"${TMP}/out2" 2>>"${TMP}/err"
if [ "${RC}" = 0 ] && [ "$(cat "${TMP}/out")" = kept ] && [ "$(cat "${TMP}/out2")" = "AUTHORIZATION: basic ${B64}" ]; then
  ok "19. a caller's GIT_CONFIG_COUNT entry is kept and the header is appended"
else bad "19. GIT_CONFIG_COUNT append" "out='$(cat "${TMP}/out")' out2='$(cat "${TMP}/out2")' err='$(cat "${TMP}/err")'"; fi

echo
echo "==================================================="
printf 'RESULT: %d passed, %d failed\n' "${PASS}" "${FAIL}"
echo "==================================================="
[ "${FAIL}" -eq 0 ] || exit 1
echo "ALL CASES PASS"
exit 0
