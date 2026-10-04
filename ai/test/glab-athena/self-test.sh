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
# DND-1647: a guard stands behind every gh/glab stub on PATH, so a stub
# that is missing or not executable fails the suite instead of reaching the
# real CLI (ai/lib/forge-stub-guard.sh).
. "${HERE}/../../lib/forge-stub-guard.sh"
fsg_arm "${TMP}/forge-guard"
fsg_require_stubs "${TMP}/stubbin" glab
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

echo "--- HIT: an SSH-form origin is rewritten to the route's HTTPS transport, with the PAT grant ---"
R="$(new_repo scp 'git@gitlab.com:example-group/example-app.git')"
gla "${R}" push origin HEAD
if [ "${RC}" = 0 ] && [[ "${OUT}" == *"dry-run: url athena-forge::https://gitlab.com/example-group/example-app.git"* ]] \
  && [[ "${OUT}" == *"[credential.helper=]"* ]] \
  && [[ "${OUT}" == *"[core.askPass=]"* ]] \
  && [[ "${OUT}" == *"[url.athena-forge::https://gitlab.com/.insteadOf=git@gitlab.com:]"* ]] \
  && [[ "${OUT}" == *"[url.athena-forge::https://gitlab.com/.insteadOf=https://gitlab.com/]"* ]] \
  && [[ "${OUT}" == *"cred: granted (one forge URL: https://gitlab.com/example-group/example-app.git)"*"[AUTHORIZATION: basic <oauth2:REDACTED>]"* ]] \
  && [[ "${OUT}" == *"dry-run: exec git [--no-pager]"* ]] && [[ "${OUT}" != *"GIT_CONFIG_KEY"* ]]; then
  ok "1. git@gitlab.com: origin -> athena-forge::https://gitlab.com/..., helper off, pager off, the oauth2 PAT header granted to the transport alone (DND-1868)"
else bad "1. SSH-form origin rewritten with PAT header" "rc=${RC} out='${OUT}' err='${ERR}'"; fi

if [[ "${OUT}${ERR}" != *"${FAKE_TOKEN}"* ]] && [[ "${OUT}${ERR}" != *"${B64}"* ]] \
  && [[ "$(printf '%s' "${OUT}" | grep 'exec git')" != *extraheader* ]]; then
  ok "2. dry-run never prints the PAT (raw or base64) and the header is not on argv"
else bad "2. dry-run leaks the PAT or puts the header on argv" "out='${OUT}'"; fi

gla "${R}" push
if [ "${RC}" = 0 ] && [[ "${OUT}" == *"dry-run: url athena-forge::https://gitlab.com/example-group/example-app.git"* ]]; then
  ok "3. bare \`push\` resolves the default remote (origin) and rewrites it"
else bad "3. default-remote push rewritten" "rc=${RC} out='${OUT}' err='${ERR}'"; fi

gla "${R}" push -u origin HEAD:refs/heads/feature
if [ "${RC}" = 0 ] && [[ "${OUT}" == *"dry-run: url athena-forge::https://gitlab.com/example-group/example-app.git"* ]]; then
  ok "3b. \`push -u origin HEAD:<ref>\` rewrites"
else bad "3b. push -u rewritten" "rc=${RC} out='${OUT}' err='${ERR}'"; fi

echo
echo "--- MISS: a remote the rewrite cannot cover is REFUSED with a Fix: ---"
R="$(new_repo sshurl 'ssh://git@gitlab.com/example-group/example-app.git')"
gla "${R}" push origin HEAD
is_refusal && [[ "${ERR}" == *"gitlab.com"* ]] && [[ "${ERR}" == *"athena-amby"* ]] \
  && ok "4. ssh://git@gitlab.com/ origin -> refused (exit 3, Fix:, escalate, names athena-amby)" \
  || bad "4. ssh:// origin refused" "rc=${RC} out='${OUT}' err='${ERR}'"

R="$(new_repo pushurl 'https://gitlab.com/example-group/example-app.git')"
git -C "${R}" config remote.origin.pushurl 'ssh://git@gitlab.com/example-group/example-app.git'
gla "${R}" push origin HEAD
is_refusal && ok "5. https origin with an ssh:// pushurl override -> refused" \
  || bad "5. pushurl override refused" "rc=${RC} out='${OUT}' err='${ERR}'"

R="$(new_repo pushinsteadof 'https://gitlab.com/example-group/example-app.git')"
gla "${R}" -c 'url.git@gitlab.com:.pushInsteadOf=https://gitlab.com/' push origin HEAD
is_refusal && ok "6. a pushInsteadOf that forces SSH -> refused" \
  || bad "6. pushInsteadOf-to-SSH refused" "rc=${RC} out='${OUT}' err='${ERR}'"

R="$(new_repo literal 'https://gitlab.com/example-group/example-app.git')"
gla "${R}" push ssh://git@gitlab.com:22/example-group/other.git HEAD
is_refusal && ok "7. a literal ssh://...:22 URL argument -> refused" \
  || bad "7. literal ssh:// refused" "rc=${RC} out='${OUT}' err='${ERR}'"

gla "${R}" push http://gitlab.com/example-group/other.git HEAD
is_refusal && ok "8. a literal http:// (non-TLS) URL -> refused" \
  || bad "8. literal http:// refused" "rc=${RC} out='${OUT}' err='${ERR}'"

R="$(new_repo pushremote 'https://gitlab.com/example-group/example-app.git')"
git -C "${R}" remote add sshr 'ssh://git@gitlab.com/example-group/example-app.git'
git -C "${R}" config branch.main.pushRemote sshr
gla "${R}" push
is_refusal && ok "9. branch.<cur>.pushRemote -> an ssh:// remote -> refused" \
  || bad "9. pushRemote default refused" "rc=${RC} out='${OUT}' err='${ERR}'"

gla "${TMP}" -C "${R}" push sshr HEAD
is_refusal && ok "10. \`-C <repo> push\` from outside the repo -> refused (global opts replayed)" \
  || bad "10. -C push refused" "rc=${RC} out='${OUT}' err='${ERR}'"

R="$(new_repo alias 'ssh://git@gitlab.com/example-group/example-app.git')"
gla "${R}" -c alias.p=push p origin HEAD
is_refusal && ok "11. a git alias expanding to push -> refused" \
  || bad "11. alias to push refused" "rc=${RC} out='${OUT}' err='${ERR}'"

gla "${R}" -c 'alias.sp=!git push' sp
is_refusal && [[ "${ERR}" == *"shell alias"* ]] && ok "12. a shell alias (!...) -> refused" \
  || bad "12. shell alias refused" "rc=${RC} out='${OUT}' err='${ERR}'"

R="$(new_repo submod 'https://gitlab.com/example-group/example-app.git')"
gla "${R}" push --recurse-submodules=on-demand origin HEAD
is_refusal && ok "13. \`push --recurse-submodules=on-demand\` -> refused" \
  || bad "13. recursive push refused" "rc=${RC} out='${OUT}' err='${ERR}'"
# Recursion from config is judged in a repo that has submodules (DND-1841).
printf '[submodule "lib"]\n\tpath = lib\n\turl = https://gitlab.com/example-group/lib.git\n' > "${R}/.gitmodules"
gla "${R}" -c submodule.recurse=true push origin HEAD
is_refusal && [[ "${ERR}" == *"submodule.recurse"* ]] && ok "13b. \`-c submodule.recurse=true push\` -> refused (DND-1841)" \
  || bad "13b. submodule.recurse push refused" "rc=${RC} out='${OUT}' err='${ERR}'"
# A command submodule foreach runs inherits the bot's header and pushes
# through git's exec-path, unjudged (DND-1844).
gla "${R}" submodule foreach 'git push'
is_refusal && [[ "${ERR}" == *"runs a command"* ]] && [[ "${ERR}" == *"git -C <submodule>"* ]] \
  && [[ "${OUT}" != *"dry-run: exec git"* ]] \
  && ok "13c. \`submodule foreach 'git push'\` -> refused, Fix: run it per submodule (DND-1844)" \
  || bad "13c. submodule foreach refused" "rc=${RC} out='${OUT}' err='${ERR}'"
gla "${R}" submodule status
[ "${RC}" = 0 ] && [[ "${OUT}" == *"dry-run: exec git"* ]] && [[ "${ERR}" != *"REFUSING"* ]] \
  && ok "13d. \`submodule status\` is unchanged (DND-1844)" \
  || bad "13d. submodule status passes" "rc=${RC} out='${OUT}' err='${ERR}'"
# DND-1867: a remote-ref writer other than push, and an unknown subcommand
# (help.autocorrect runs the closest command), are refused on this route too.
gla "${R}" send-pack https://gitlab.com/example-group/example-app.git HEAD:refs/heads/main
is_refusal && [[ "${ERR}" == *"writes a remote ref"* ]] && [[ "${ERR}" == *"glab-athena git push"* ]] \
  && ok "13e. \`send-pack <url> HEAD:refs/heads/main\` -> refused, Fix: glab-athena git push (DND-1867)" \
  || bad "13e. send-pack refused" "rc=${RC} out='${OUT}' err='${ERR}'"
gla "${R}" subtree push -P lib origin main
is_refusal && [[ "${ERR}" == *"subtree split"* ]] \
  && ok "13f. \`subtree push\` -> refused, Fix: split, then glab-athena git push (DND-1867)" \
  || bad "13f. subtree push refused" "rc=${RC} out='${OUT}' err='${ERR}'"
gla "${R}" -c help.autocorrect=immediate pusj origin HEAD:main
is_refusal && [[ "${ERR}" == *"no command git knows"* ]] \
  && ok "13g. an unknown subcommand under help.autocorrect (pusj) -> refused (DND-1867)" \
  || bad "13g. autocorrect refused" "rc=${RC} out='${OUT}' err='${ERR}'"

R="$(new_repo notoken 'git@gitlab.com:example-group/example-app.git')"
( cd "${R}" && GITLAB_ATHENA_TOKEN_FILE="${TMP}/no-such-token" GLAB_ATHENA_GIT_DRY_RUN=1 "${WRAPPER}" git push origin HEAD ) \
  >"${TMP}/out" 2>"${TMP}/err"; RC=$?; OUT="$(cat "${TMP}/out")"; ERR="$(cat "${TMP}/err")"
is_refusal && [[ "${ERR}" == *"token file"* ]] && [[ "${ERR}" == *"refresh"* ]] \
  && ok "14. a missing token file -> refused (never falls back to the owner), says not to refresh" \
  || bad "14. missing token refused" "rc=${RC} out='${OUT}' err='${ERR}'"

echo
echo "--- NEGATIVE: what must pass untouched ---"
R="$(new_repo https 'https://gitlab.com/example-group/example-app.git')"
gla "${R}" push origin HEAD
if [ "${RC}" = 0 ] && [[ "${OUT}" == *"dry-run: url athena-forge::https://gitlab.com/example-group/example-app.git"* ]] && [ -z "${ERR}" ]; then
  ok "15. an HTTPS origin is untouched (same URL, no refusal)"
else bad "15. HTTPS origin untouched" "rc=${RC} out='${OUT}' err='${ERR}'"; fi

R="$(new_repo status-only 'ssh://git@gitlab.com/example-group/example-app.git')"
gla "${R}" status --short
if [ "${RC}" = 0 ] && [[ "${OUT}" == *"dry-run: exec git"* ]] && [ -z "${ERR}" ]; then
  ok "16. a non-network command (status) is not refused, even with an ssh:// origin"
else bad "16. non-network command passes" "rc=${RC} out='${OUT}' err='${ERR}'"; fi

# A REAL exec (no dry-run) to a local bare remote whose path contains
# gitlab.com: the injected options do not break a real push, and a local path
# is never mistaken for gitlab.com.
BARE="${TMP}/src/gitlab.com/example-group/r.git"; mkdir -p "$(dirname "${BARE}")"
git init -q --bare "${BARE}"
R="$(new_repo real "${BARE}")"
( cd "${R}" && "${WRAPPER}" git push -q origin HEAD:refs/heads/landed ) >"${TMP}/out" 2>"${TMP}/err"; RC=$?
if [ "${RC}" = 0 ] && [ "$(git -C "${BARE}" rev-parse refs/heads/landed 2>/dev/null)" = "$(git -C "${R}" rev-parse HEAD)" ]; then
  ok "17. real exec: push to a local bare remote under .../gitlab.com/... lands"
else bad "17. real local push lands" "rc=${RC} err='$(cat "${TMP}/err")'"; fi

# A REAL exec of a local command: git resolves origin to the route's
# transport and never sees the oauth2 PAT header (DND-1868, DND-1880).
R="$(new_repo hdr 'git@gitlab.com:example-group/example-app.git')"
( cd "${R}" && "${WRAPPER}" git config --get-all http.https://gitlab.com/.extraheader ) >"${TMP}/out" 2>"${TMP}/err"; RC=$?
( cd "${R}" && "${WRAPPER}" git remote get-url --push origin ) >"${TMP}/out2" 2>>"${TMP}/err"; RC2=$?
if [ "${RC}" = 1 ] && [ ! -s "${TMP}/out" ] && [ "${RC2}" = 0 ] \
  && [ "$(cat "${TMP}/out2")" = "athena-forge::https://gitlab.com/example-group/example-app.git" ]; then
  ok "18. real exec: git resolves origin to the route's transport and sees no PAT header (DND-1880)"
else bad "18. git sees the transport rewrite and no header" "rc=${RC} rc2=${RC2} out2='$(cat "${TMP}/out2")' err='$(cat "${TMP}/err")'"; fi

# A caller's own GIT_CONFIG_COUNT entries survive, and no header joins them.
( cd "${R}" && GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=user.name GIT_CONFIG_VALUE_0=kept \
    "${WRAPPER}" git config --get user.name ) >"${TMP}/out" 2>"${TMP}/err"; RC=$?
( cd "${R}" && GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=user.name GIT_CONFIG_VALUE_0=kept \
    "${WRAPPER}" git config --get-all http.https://gitlab.com/.extraheader ) >"${TMP}/out2" 2>>"${TMP}/err"
if [ "${RC}" = 0 ] && [ "$(cat "${TMP}/out")" = kept ] && [ ! -s "${TMP}/out2" ]; then
  ok "19. a caller's GIT_CONFIG_COUNT entry is kept, and no header is added (DND-1868)"
else bad "19. GIT_CONFIG_COUNT append" "out='$(cat "${TMP}/out")' out2='$(cat "${TMP}/out2")' err='$(cat "${TMP}/err")'"; fi

# DND-1868, mirrored: a REAL routed push to a fixture gitlab.com (no network:
# a git shim runs git with a copy of its exec-path whose git-remote-https is a
# stub mapping https://gitlab.com/<g>/<r> to a local bare repo). The push
# lands with the oauth2 header at the transport alone; a pre-push hook gets no
# header and finds the grant used.
X="${TMP}/x1868"; mkdir -p "${X}/shim" "${X}/exec" "${X}/forge/g"
export X_REAL_GIT="$(git --exec-path)/git" X_EXEC="${X}/exec" X_FORGE="${X}/forge" X_LOG="${X}/stub.log" X_B64="${B64}"
for f in "$(git --exec-path)"/*; do ln -s "${f}" "${X_EXEC}/${f##*/}"; done
rm -f "${X_EXEC}/git-remote-https"
cat > "${X_EXEC}/git-remote-https" <<'EOF'
#!/usr/bin/env bash
url="${2:-$1}"; hdr=none; i=0
while [ "${i}" -lt "${GIT_CONFIG_COUNT:-0}" ]; do
  k="GIT_CONFIG_KEY_${i}"; v="GIT_CONFIG_VALUE_${i}"
  case "${!k}" in http.https://gitlab.com/.extraheader) [ "${!v}" = "AUTHORIZATION: basic ${X_B64}" ] && hdr=ok:oauth2 || hdr=wrong ;; esac
  i=$((i + 1))
done
printf 'start url=%s hdr=%s\n' "${url}" "${hdr}" >> "${X_LOG}"
while IFS= read -r line; do
  case "${line}" in
    capabilities) printf 'connect\n\n' ;;
    "connect "*) printf '\n'; exec env -u GIT_DIR git "${line#connect git-}" "${X_FORGE}/${url#https://*/}" ;;
    *) exit 0 ;;
  esac
done
EOF
chmod +x "${X_EXEC}/git-remote-https"
printf '#!/bin/sh\nexec "$X_REAL_GIT" --exec-path="$X_EXEC" "$@"\n' > "${X}/shim/git"; chmod +x "${X}/shim/git"
. "${AI_DIR}/lib/forge-stub-guard.sh"
fsg_make "${TMP}/git-guard" git
fsg_require_stubs "${X}/shim" git
git init -q --bare -b main "${X_FORGE}/g/r.git"
R="$(new_repo x1868 'git@gitlab.com:g/r.git')"
cat > "${R}/.git/hooks/pre-push" <<'EOF'
#!/usr/bin/env bash
hdr=absent; i=0
while [ "${i}" -lt "${GIT_CONFIG_COUNT:-0}" ]; do k="GIT_CONFIG_KEY_${i}"; case "${!k}" in *extraheader*) hdr=present ;; esac; i=$((i + 1)); done
out="$(git-remote-athena-forge origin https://gitlab.com/g/r.git </dev/null 2>&1)"
tr=other; [[ "${out}" == *"already used"* ]] && tr=already-used
printf 'hook hdr=%s transport=%s\n' "${hdr}" "${tr}" >> "${X_LOG}"
exit 0
EOF
chmod +x "${R}/.git/hooks/pre-push"
( cd "${R}" && PATH="${X}/shim:${FSG_DIR}:${PATH}" GIT_ALLOW_PROTOCOL=file:athena-forge "${WRAPPER}" git push -q origin HEAD:main ) >"${TMP}/out" 2>"${TMP}/err"; RC=$?
if [ "${RC}" = 0 ] && [ "$(git --git-dir="${X_FORGE}/g/r.git" rev-parse main 2>/dev/null)" = "$(git -C "${R}" rev-parse HEAD)" ] \
  && [ "$(grep -c '^start url=https://gitlab.com/g/r.git hdr=ok:oauth2$' "${X_LOG}")" = 1 ] \
  && grep -q '^hook hdr=absent transport=already-used$' "${X_LOG}" \
  && [ -z "$(grep -rlF -e "${FAKE_TOKEN}" -e "${B64}" "${X}" 2>/dev/null)" ]; then
  ok "X1868. a routed push to a fixture gitlab.com lands with the oauth2 header at the transport alone; the pre-push hook gets no header and finds the grant used"
else bad "X1868. routed gitlab push through the transport" "rc=${RC} err='$(cat "${TMP}/err")' log='$(cat "${X_LOG}" 2>/dev/null)'"; fi
if fsg_verify; then ok "X1868. no git call fell through past its shim (DND-1667)"
else bad "X1868. a git call fell through past its shim (DND-1667)" "see the forge-stub-guard FAIL above"; fi

# DND-1690: the passthrough is shared, so glab-athena refuses an ungated
# push to main in a gated repo too (bin/prep-commit.sh declares the gate).
O="${TMP}/gated-origin.git"; W="${TMP}/gated-wt"
git init -q --bare -b main "${O}"
git init -q -b main "${W}" && git -C "${W}" remote add origin "${O}"
mkdir -p "${W}/bin"; printf '#!/bin/sh\nexit 0\n' > "${W}/bin/prep-commit.sh"
git -C "${W}" add -A && git -C "${W}" commit -q -m base && git -C "${W}" push -q origin main
git -C "${W}" checkout -q -b lane && git -C "${W}" commit -q --allow-empty -m "lane change"
gla "${W}" push origin HEAD:main
if [ "${RC}" = 3 ] && [[ "${ERR}" == *"NO RECEIPT"* ]] && [[ "${ERR}" == *"Fix:"* ]] && [[ "${ERR}" == *"bin/prep-commit.sh"* ]]; then
  ok "20. gated repo: an ungated push to main is refused (NO RECEIPT, Fix:), shared with gh-athena (DND-1690)"
else bad "20. glab ungated push to main refused" "rc=${RC} out='${OUT}' err='${ERR}'"; fi

# DND-1668: the work GitLab group name is a work value. `refresh` reads it from
# the private overlay (gitlab .group) and never from a literal in the wrapper.
RB="${TMP}/refreshbin"; mkdir -p "${RB}"
printf '#!/bin/sh\necho "$*" >> "%s/glab.args"\necho "{\\"id\\": null}"\n' "${TMP}" > "${RB}/glab"
chmod +x "${RB}/glab"
run_refresh() { # <overlay-root-or-empty>
  rm -f "${TMP}/glab.args"
  local root="${TMP}/no-such-overlay"
  [ -z "$1" ] || root="$1"
  OUT="$(env ATHENA_PRIVATE_ROOT="${root}" PATH="${RB}:${PATH}" "${WRAPPER}" refresh 2>"${TMP}/err")"; RC=$?
  ERR="$(cat "${TMP}/err")"
}
run_refresh ""
if [ "${RC}" = 1 ] && [[ "${ERR}" == *"private overlay"* ]] && [[ "${ERR}" == *"Fix:"* ]] && [ ! -e "${TMP}/glab.args" ]; then
  ok "21. refresh with no overlay: refused with Fix:, glab never called (DND-1668)"
else bad "21. refresh, overlay absent" "rc=${RC} err='${ERR}' args='$(cat "${TMP}/glab.args" 2>/dev/null)'"; fi

OV="${TMP}/overlay-root"; mkdir -p "${OV}/overlay"; chmod 700 "${OV}"
printf '{"kind":"athena-private-overlay","schema":1}\n' > "${OV}/athena-overlay.json"
printf '{}\n' > "${OV}/overlay/gitlab.json"
run_refresh "${OV}"
if [ "${RC}" = 1 ] && [[ "${ERR}" == *"Fix:"* ]] && [ ! -e "${TMP}/glab.args" ]; then
  ok "22. refresh with the overlay present but no gitlab .group: refused with Fix:, glab never called (DND-1668)"
else bad "22. refresh, key missing" "rc=${RC} err='${ERR}'"; fi

printf '{"group":"synthetic-group"}\n' > "${OV}/overlay/gitlab.json"
run_refresh "${OV}"
if [[ "$(cat "${TMP}/glab.args" 2>/dev/null)" == "api groups/synthetic-group" ]] && [[ "${ERR}" == *"synthetic-group"* ]]; then
  ok "23. refresh looks the group up by the overlay's value (DND-1668)"
else bad "23. refresh, overlay value used" "rc=${RC} err='${ERR}' args='$(cat "${TMP}/glab.args" 2>/dev/null)'"; fi

echo
echo "--- DND-2000: a URL on another forge's host, or any host but gitlab.com, is REFUSED ---"
# The defect, mirrored: glab-athena judged only URLs on gitlab.com, so a
# github.com remote went out over SSH with the machine OWNER's key.
# NO NETWORK: GIT_SSH_COMMAND is a RECORDING stub. On the unfixed wrapper git
# starts it; after the fix the wrapper refuses first and the log stays empty.
XF="${TMP}/x2000"; mkdir -p "${XF}/ssh" "${XF}/shim"
XF_LOG="${XF}/ssh.log"; : > "${XF_LOG}"
printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "%s"\nexit 1\n' "${XF_LOG}" > "${XF}/ssh/ssh-rec"
chmod +x "${XF}/ssh/ssh-rec"
fsg_require_stubs "${XF}/ssh" ssh-rec
xf() {
  local d="$1"; shift
  : > "${XF_LOG}"
  OUT="$(cd "${d}" && GIT_ALLOW_PROTOCOL=file:ssh GIT_SSH_COMMAND="${XF}/ssh/ssh-rec" \
    timeout 60 "${WRAPPER}" git "$@" 2>"${TMP}/err" </dev/null)"; RC=$?
  ERR="$(cat "${TMP}/err")"
}
xf_refused_hub() {
  is_refusal && [ ! -s "${XF_LOG}" ] && [[ "${ERR}" == *"github.com"* ]] \
    && [[ "${ERR}" == *"gh-athena git"* ]] && [[ "${ERR}" == *"ai/bin/forge-push"* ]]
}
xf_diag() { printf 'rc=%s ssh-log=[%s] out=[%s] err=[%s]' "${RC}" "$(tr '\n' ';' < "${XF_LOG}")" "${OUT}" "${ERR}"; }

R="$(new_repo xf-hub 'git@github.com:o/r.git')"
xf "${R}" push git@github.com:o/r.git HEAD:refs/heads/x
xf_refused_hub && ok "XF1. \`push git@github.com:…\` (a literal URL): refused, exit 3, Fix: gh-athena / ai/bin/forge-push; nothing reached ssh" \
  || bad "XF1. literal github.com push refused" "$(xf_diag)"
xf "${R}" push origin HEAD:refs/heads/x
xf_refused_hub && ok "XF2. \`push origin\` with a github.com origin: refused; nothing reached ssh" \
  || bad "XF2. github.com origin push refused" "$(xf_diag)"
xf "${R}" fetch origin
xf_refused_hub && ok "XF3. \`fetch origin\` (github.com): refused; nothing reached ssh" \
  || bad "XF3. github.com fetch refused" "$(xf_diag)"
xf "${R}" ls-remote origin
xf_refused_hub && ok "XF4. \`ls-remote origin\` (github.com): refused; nothing reached ssh" \
  || bad "XF4. github.com ls-remote refused" "$(xf_diag)"
xf "${R}" pull --no-rebase origin main
xf_refused_hub && ok "XF5. \`pull origin main\` (github.com): refused; nothing reached ssh" \
  || bad "XF5. github.com pull refused" "$(xf_diag)"
xf "${XF}" clone git@github.com:o/r.git "${XF}/clone"
xf_refused_hub && [ ! -e "${XF}/clone" ] && ok "XF6. \`clone git@github.com:…\`: refused; nothing reached ssh" \
  || bad "XF6. github.com clone refused" "$(xf_diag)"
R2="$(new_repo xf-pushurl 'https://gitlab.com/g/r.git')"
git -C "${R2}" config remote.origin.pushurl 'git@github.com:o/r.git'
xf "${R2}" push origin HEAD:refs/heads/x
xf_refused_hub && ok "XF7. a gitlab.com origin with a github.com pushurl: refused" \
  || bad "XF7. github.com pushurl refused" "$(xf_diag)"
xf "${R2}" push git@gitlab.com.:g/r.git HEAD:refs/heads/x
is_refusal && [ ! -s "${XF_LOG}" ] && [[ "${ERR}" == *"gitlab.com."* ]] \
  && ok "XF8. \`push git@gitlab.com.:…\` (trailing dot): refused; nothing reached ssh" \
  || bad "XF8. trailing-dot gitlab.com refused" "$(xf_diag)"
printf '#!/bin/sh\nfor a in "$@"; do case "$a" in get-url|--get-url) echo "fatal: synthetic" >&2; exit 128 ;; esac; done\nexec %s "$@"\n' \
  "$(command -v git)" > "${XF}/shim/git"
chmod +x "${XF}/shim/git"
fsg_require_stubs "${XF}/shim" git
OUT="$(cd "${R2}" && PATH="${XF}/shim:${TMP}/git-guard:${PATH}" GLAB_ATHENA_GIT_DRY_RUN=1 "${WRAPPER}" git push origin HEAD 2>"${TMP}/err")"; RC=$?
ERR="$(cat "${TMP}/err")"
is_refusal && [[ "${ERR}" == *"COULD NOT LOOK"* ]] \
  && ok "XF9. a remote whose URL git cannot resolve: refused, COULD NOT LOOK" \
  || bad "XF9. unresolvable remote refused" "rc=${RC} out='${OUT}' err='${ERR}'"
R3="$(new_repo xf-own 'git@gitlab.com:g/r.git')"
gla "${R3}" push origin HEAD
[ "${RC}" = 0 ] && [[ "${OUT}" == *"cred: granted"* ]] && ok "XF10. a gitlab.com origin still pushes with the grant" \
  || bad "XF10. gitlab.com origin passes" "rc=${RC} out='${OUT}' err='${ERR}'"

# DND-1647: no gh/glab call may have fallen through past its stub.
if fsg_verify; then ok "no gh/glab call fell through past its stub (DND-1647)"
else bad "no gh/glab call fell through past its stub (DND-1647)" "see the forge-stub-guard FAIL above"; fi

echo
echo "==================================================="
printf 'RESULT: %d passed, %d failed\n' "${PASS}" "${FAIL}"
echo "==================================================="
[ "${FAIL}" -eq 0 ] || exit 1
echo "ALL CASES PASS"
exit 0
