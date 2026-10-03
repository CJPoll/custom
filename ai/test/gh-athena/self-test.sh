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
# The calling session may inject its own config entries (DND-775: agent sessions
# carry the agent-stash hook as GIT_CONFIG_COUNT/KEY_n/VALUE_n). Case 1 pins the
# header at index 0, so start from none, as glab-athena's suite does. Case 18
# covers a pre-set count explicitly. This drops the agent-stash hook inside this
# sandbox (DND-775 condition b), which only ever creates fixture repos.
unset GIT_CONFIG_COUNT
FAKE_TOKEN="ghs_SELFTESTFAKETOKEN0000"
printf '12345\n' > "${TMP}/app-id"
printf 'not-a-key\n' > "${TMP}/key.pem"
printf '%s\t%s\n' "${FAKE_TOKEN}" "$(( $(date +%s) + 86400 ))" > "${TMP}/token-cache"
chmod 600 "${TMP}/token-cache"
export GH_ATHENA_APP_ID_FILE="${TMP}/app-id"
export GH_ATHENA_KEY="${TMP}/key.pem"
export GH_ATHENA_TOKEN_CACHE="${TMP}/token-cache"
# A push through the wrapper emits merge.landed (DND-1475): never into the
# machine's real store from a fixture.
export ATHENA_TELEMETRY_DIR="${TMP}/telemetry"
unset ATHENA_UNIT
# Receipts are sealed under the machine's receipt-seal key (DND-1814): a
# private key under TMP here, never the real one.
export ATHENA_SECRETS_ROOT="${TMP}/secrets"

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

echo "--- HIT: an SSH-form origin is rewritten to the route's HTTPS transport, with the grant ---"
R="$(new_repo scp 'git@github.com:o/r.git')"
gha "${R}" push origin HEAD
if [ "${RC}" = 0 ] && [[ "${OUT}" == *"dry-run: url athena-forge::https://github.com/o/r.git"* ]] \
  && [[ "${OUT}" == *"[credential.helper=]"* ]] \
  && [[ "${OUT}" == *"[url.athena-forge::https://github.com/.insteadOf=git@github.com:]"* ]] \
  && [[ "${OUT}" == *"[url.athena-forge::https://github.com/.insteadOf=https://github.com/]"* ]] \
  && [[ "${OUT}" == *"cred: granted (one forge URL: https://github.com/o/r.git)"*"[AUTHORIZATION: basic <x-access-token:REDACTED>]"* ]] \
  && [[ "${OUT}" == *"dry-run: exec git [--no-pager]"* ]] \
  && [[ "${OUT}" != *"extraheader"* ]] && [[ "${OUT}" != *"GIT_CONFIG_KEY"* ]] \
  && [[ "${OUT}" == *"[core.askPass=]"* ]]; then
  ok "1. git@github.com: origin -> athena-forge::https://github.com/o/r.git, helper off, pager off, the header granted to the transport alone (DND-1868)"
else bad "1. SSH-form origin rewritten to the transport with the grant" "rc=${RC} out='${OUT}' err='${ERR}'"; fi

B64="$(printf 'x-access-token:%s' "${FAKE_TOKEN}" | openssl base64 -A)"
if [[ "${OUT}${ERR}" != *"${FAKE_TOKEN}"* ]] && [[ "${OUT}${ERR}" != *"${B64}"* ]]; then
  ok "2. dry-run never prints the token (raw or base64)"
else bad "2. dry-run leaks the token" "out='${OUT}'"; fi

gha "${R}" push
if [ "${RC}" = 0 ] && [[ "${OUT}" == *"dry-run: url athena-forge::https://github.com/o/r.git"* ]]; then
  ok "3. bare \`push\` resolves the default remote (origin) and rewrites it"
else bad "3. default-remote push rewritten" "rc=${RC} out='${OUT}' err='${ERR}'"; fi

gha "${R}" -c credential.helper= -c 'url.https://github.com/.insteadOf=git@github.com:' push origin HEAD
if [ "${RC}" = 0 ] && [[ "${OUT}" == *"dry-run: url athena-forge::https://github.com/o/r.git"* ]]; then
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

gha "${R}" -c alias.pz=push -c url.athena-forge::https://github.com/.insteadOf=ssh://git@github.com/ pz origin HEAD
if [ "${RC}" = 0 ] && [[ "${OUT}" == *"dry-run: url athena-forge::https://github.com/o/r.git"* ]]; then
  ok "13i. an aliased push whose remote DOES resolve to the route's HTTPS transport passes"
else bad "13i. aliased https push passes" "rc=${RC} out='${OUT}' err='${ERR}'"; fi

R="$(new_repo https 'https://github.com/o/r.git')"
gha "${R}" push origin HEAD
if [ "${RC}" = 0 ] && [[ "${OUT}" == *"dry-run: url athena-forge::https://github.com/o/r.git"* ]] && [ -z "${ERR}" ]; then
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

# A REAL exec of a local command through the wrapper: git sees the route's
# rewrite to its transport, and never the bot header (DND-1868: only the
# transport holds it; DND-1880).
R="$(new_repo hdr 'git@github.com:o/r.git')"
( cd "${R}" && "${WRAPPER}" git config --get-all http.https://github.com/.extraheader ) >"${TMP}/out" 2>"${TMP}/err"; RC=$?
( cd "${R}" && "${WRAPPER}" git remote get-url --push origin ) >"${TMP}/out2" 2>>"${TMP}/err"; RC2=$?
if [ "${RC}" = 1 ] && [ ! -s "${TMP}/out" ] && [ "${RC2}" = 0 ] && [ "$(cat "${TMP}/out2")" = "athena-forge::https://github.com/o/r.git" ]; then
  ok "17. real exec: git resolves origin to the route's transport and sees no bot header"
else bad "17. git sees the transport rewrite and no header" "rc=${RC} rc2=${RC2} out2='$(cat "${TMP}/out2")' err='$(cat "${TMP}/err")'"; fi

# DND-775 condition (a): agent sessions carry the agent-stash hook as injected
# config entries. The header must be APPENDED after them (index COUNT), never
# written over index 0, and the hook must still be registered in the git the
# passthrough execs. The injected entries come from ai/hooks/registry.json.
REGISTRY="${AI_DIR}/hooks/registry.json"
R="$(new_repo inject 'git@github.com:o/r.git')"
inject_env() {
  python3 - "${REGISTRY}" <<'PY'
import json, shlex, sys
env = json.load(open(sys.argv[1]))["env"]
pairs = [("user.name", "caller-kept")] + [(e["key"], e["value"]) for e in env["git_config"]]
out = ["GIT_CONFIG_COUNT=%d" % len(pairs)]
for i, (k, v) in enumerate(pairs):
    out.append("GIT_CONFIG_KEY_%d=%s" % (i, shlex.quote(k)))
    out.append("GIT_CONFIG_VALUE_%d=%s" % (i, shlex.quote(v)))
print(" ".join(out))
PY
}
INJ="$(inject_env)"
N="$(eval "${INJ}"; printf '%s' "${GIT_CONFIG_COUNT}")"
OUT="$(cd "${R}" && eval "export ${INJ}" && GH_ATHENA_GIT_DRY_RUN=1 "${WRAPPER}" git push origin HEAD 2>"${TMP}/err")"; RC=$?
( cd "${R}" && eval "export ${INJ}" && "${WRAPPER}" git config --get user.name \
    && ! "${WRAPPER}" git config --get-all http.https://github.com/.extraheader \
    && "${WRAPPER}" git hook list reference-transaction ) >"${TMP}/out" 2>>"${TMP}/err"; RC2=$?
if [ "${RC}" = 0 ] && [[ "${OUT}" == *"cred: granted"* ]] && [[ "${OUT}" != *"GIT_CONFIG_KEY"* ]] \
  && [ "${RC2}" = 0 ] \
  && [ "$(cat "${TMP}/out")" = "caller-kept"$'\n'"agentstash" ]; then
  ok "18. injected entries (count ${N}) are kept, no header is added to them (DND-1868), and the agent-stash hook stays registered"
else bad "18. append after injected entries" "rc=${RC} rc2=${RC2} n=${N} out='${OUT}' real='$(cat "${TMP}/out")' err='$(cat "${TMP}/err")'"; fi

echo
echo "--- DND-1841: a push that recurses into submodules is REFUSED, from every source ---"
# A real superproject with a real submodule, both pushing to local bare
# repositories (no network). Every recursion source git reads is tried: the
# flag (and its abbreviation and separate-value form), push.recurseSubmodules,
# submodule.recurse, from repo config, from -c and from the environment config
# channel, and the order git applies them in (the LAST of the two config keys
# wins). Each submodule push would run through git's exec-path, outside this
# wrapper's checks, so a recursing push is refused, not half-checked.
SUBBARE="${TMP}/sm-sub.git"; SUPBARE="${TMP}/sm-super.git"
git init -q --bare "${SUBBARE}"; git init -q --bare "${SUPBARE}"
git init -q "${TMP}/sm-seed" && git -C "${TMP}/sm-seed" commit -q --allow-empty -m s1 \
  && git -C "${TMP}/sm-seed" push -q "${SUBBARE}" HEAD:refs/heads/main
SM="$(new_repo sm-super "${SUPBARE}")"
git -C "${SM}" -c protocol.file.allow=always submodule -q add "${SUBBARE}" s >/dev/null 2>&1
git -C "${SM}" commit -q -m 'add submodule'
git -C "${SM}/s" commit -q --allow-empty -m s2
git -C "${SM}" add s && git -C "${SM}" commit -q -m 'bump submodule'
[ -f "${SM}/.gitmodules" ] && [ -d "${SM}/s" ] || bad "S0. submodule fixture" "no submodule in ${SM}"

# sm_refused <label> : exit 3, a Fix: naming the separate submodule push, and git never ran.
sm_refused() {
  if is_refusal && [[ "${ERR}" == *"submodule"* ]] && [[ "${ERR}" == *"--no-recurse-submodules"* ]] \
    && [[ "${OUT}" != *"dry-run: exec git"* ]]; then ok "$1"
  else bad "$1" "rc=${RC} out='${OUT}' err='${ERR}'"; fi
}
# sm_passed <label> : exit 0, no refusal, git would run.
sm_passed() {
  if [ "${RC}" = 0 ] && [[ "${OUT}" == *"dry-run: exec git"* ]] && [[ "${ERR}" != *"REFUSING"* ]]; then ok "$1"
  else bad "$1" "rc=${RC} out='${OUT}' err='${ERR}'"; fi
}

gha "${SM}" -c submodule.recurse=true push origin HEAD:refs/heads/feat
sm_refused "S1. -c submodule.recurse=true -> refused"
git -C "${SM}" config submodule.recurse true
gha "${SM}" push origin HEAD:refs/heads/feat
sm_refused "S2. submodule.recurse=true in the repo config -> refused"
gha "${SM}" -c alias.pp=push pp origin HEAD:refs/heads/feat
sm_refused "S3. an alias to push, submodule.recurse=true in the repo config -> refused"
gha "${SM}" subtree push -P s "${SUBBARE}" feat
# DND-1867: subtree push is refused outright now, whatever its recursion.
if is_refusal && [[ "${ERR}" == *"writes a remote ref"* ]]; then
  ok "S4. subtree push (its inner git push reads submodule.recurse too) -> refused (outright, DND-1867)"
else bad "S4. subtree push refused" "rc=${RC} out='${OUT}' err='${ERR}'"; fi
git -C "${SM}" config --unset submodule.recurse
git -C "${SM}" config push.recurseSubmodules no
gha "${SM}" -c submodule.recurse=true push origin HEAD:refs/heads/feat
sm_refused "S5. push.recurseSubmodules=no in the repo, then -c submodule.recurse=true (the later key wins) -> refused"
git -C "${SM}" config --unset push.recurseSubmodules
gha "${SM}" -c push.recurseSubmodules=on-demand push origin HEAD:refs/heads/feat
sm_refused "S6. -c push.recurseSubmodules=on-demand -> refused"
( cd "${SM}" && GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=submodule.recurse GIT_CONFIG_VALUE_0=yes \
    GH_ATHENA_GIT_DRY_RUN=1 "${WRAPPER}" git push origin HEAD:refs/heads/feat ) >"${TMP}/out" 2>"${TMP}/err"
RC=$?; OUT="$(cat "${TMP}/out")"; ERR="$(cat "${TMP}/err")"
sm_refused "S7. submodule.recurse=yes from the environment config channel -> refused"
gha "${SM}" push --recurse-submodules=on-demand origin HEAD:refs/heads/feat
sm_refused "S8. --recurse-submodules=on-demand -> refused"
gha "${SM}" push --recurse-submodules only origin HEAD:refs/heads/feat
sm_refused "S9. --recurse-submodules only (the value as a separate word) -> refused"
gha "${SM}" push --recu=on-demand origin HEAD:refs/heads/feat
sm_refused "S10. the abbreviation --recu=on-demand -> refused"
gha "${SM}" push --no-recurse-submodules --recurse-submodules=on-demand origin HEAD:refs/heads/feat
sm_refused "S11. --no-recurse-submodules then --recurse-submodules=on-demand (the last flag wins) -> refused"
gha "${SM}" -c submodule.recurse=true push -o --no-recurse-submodules origin HEAD:refs/heads/feat
sm_refused "S12. --no-recurse-submodules as the VALUE of -o is not the flag -> refused"

gha "${SM}" push origin HEAD:refs/heads/feat
sm_passed "S13. no recursion configured: a push from the superproject is unchanged"
gha "${SM}" -c submodule.recurse=true push --no-recurse-submodules origin HEAD:refs/heads/feat
sm_passed "S14. -c submodule.recurse=true with --no-recurse-submodules (the flag wins) passes"
gha "${SM}" -c submodule.recurse=true push --recurse-submodules=check origin HEAD:refs/heads/feat
sm_passed "S15. --recurse-submodules=check (checks, pushes no submodule) passes"
git -C "${SM}" config submodule.recurse true
gha "${SM}" -c push.recurseSubmodules=no push origin HEAD:refs/heads/feat
sm_passed "S16. submodule.recurse=true in the repo, then -c push.recurseSubmodules=no (the later key wins) passes"
git -C "${SM}" config --unset submodule.recurse
R="$(new_repo sm-none "${SUPBARE}")"
gha "${R}" -c submodule.recurse=true push origin HEAD:refs/heads/plain
sm_passed "S17. submodule.recurse=true in a repo with no submodules: the push is unchanged"
gha "${R}" push --recurse-submodules=on-demand origin HEAD:refs/heads/plain
sm_refused "S18. an explicit --recurse-submodules=on-demand is refused in a repo with no submodule markers too"
git -C "${R}" update-index --add --cacheinfo "160000,$(git -C "${SM}/s" rev-parse HEAD),lib"
gha "${R}" -c submodule.recurse=true push origin HEAD:refs/heads/plain
sm_refused "S19. a gitlink in the index with no .gitmodules still counts as a submodule -> refused"
gha "${SM}" push -o -- --recurse-submodules=on-demand origin HEAD:refs/heads/feat
sm_refused "S20. \`-o --\`: the -- is -o's value, not the end of options, so the next flag counts -> refused"
gha "${SM}" -c submodule.recurse=true push --recurse-submodules check origin HEAD:refs/heads/feat
sm_passed "S21. --recurse-submodules check (the value as a separate word) passes"
gha "${SM}" -c 'alias.pq=push "--recurse-submodules=on-demand"' pq origin HEAD:refs/heads/feat
if is_refusal && [[ "${ERR}" == *"quotes or backslashes"* ]]; then
  ok "S22. an alias with a quoted flag (split differently by git) -> refused"
else bad "S22. quoted alias refused" "rc=${RC} out='${OUT}' err='${ERR}'"; fi
git -C "${SM}" config submodule.recurse true
gha "${SM}" subtree push -P s "${SUBBARE}" feat
if is_refusal && [[ "${ERR}" == *"git subtree split -P <prefix> -b <branch>"* ]]; then
  ok "S23. subtree push refusal names the split-then-push Fix (DND-1867)"
else bad "S23. subtree push Fix" "rc=${RC} out='${OUT}' err='${ERR}'"; fi
gha "${SM}" -c push.recurseSubmodules=no subtree push -P s "${SUBBARE}" feat
if is_refusal && [[ "${ERR}" == *"writes a remote ref"* ]]; then
  ok "S24. -c push.recurseSubmodules=no subtree push is refused too: no flag makes subtree push judged (DND-1867)"
else bad "S24. subtree push with recursion off refused" "rc=${RC} out='${OUT}' err='${ERR}'"; fi
git -C "${SM}" config --unset submodule.recurse

echo
echo "--- DND-1475: a push that moves the remote's default branch is merge.landed ---"
# Real pushes to local bare origins. Each case has its own store.
landed() { cat "$1"/*.jsonl 2>/dev/null | jq -c 'select(.event == "merge.landed")'; }
landed_n() { local n; n="$(landed "$1" | grep -c .)"; printf '%s' "${n:-0}"; }
# origin_with_main <name> -> a bare origin whose main has one commit, and a
# clone "<name>-wt" of it with one more commit on main. Sets O, W, BEFORE, AFTER.
origin_with_main() {
  O="${TMP}/$1-origin.git"; W="${TMP}/$1-wt"
  git init -q --bare -b main "${O}"
  git init -q -b main "${W}" && git -C "${W}" commit -q --allow-empty -m c0 && git -C "${W}" remote add origin "${O}"
  git -C "${W}" push -q origin main 2>/dev/null
  BEFORE="$(git -C "${W}" rev-parse HEAD)"
  git -C "${W}" commit -q --allow-empty -m c1; AFTER="$(git -C "${W}" rev-parse HEAD)"
}
ghpush() { # <dir> <store> <git args...> -> OUT RC ERR
  local d="$1" s="$2"; shift 2
  OUT="$(cd "${d}" && ATHENA_TELEMETRY_DIR="${s}" "${WRAPPER}" git "$@" 2>"${TMP}/err")"; RC=$?
  ERR="$(cat "${TMP}/err")"
}

origin_with_main p1; S="${TMP}/p1-store"
# DND-1501: the event is timed. at = the push start (inside the bracket the
# test reads around the push), duration_s = its wall (a number, not null).
T_PRE="$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)"
ghpush "${W}" "${S}" push -q origin HEAD:main
T_POST="$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)"
EV="$(landed "${S}")"
EV_AT="$(jq -r .at <<<"${EV}" 2>/dev/null)"
if [ "${RC}" = 0 ] && [ "$(landed_n "${S}")" = 1 ] \
  && [ "$(jq -cS .attrs <<<"${EV}")" = "$(jq -cnS --arg b "${BEFORE}" --arg a "${AFTER}" '{via:"push",before:$b,after:$a}')" ] \
  && [ "$(jq -r .head <<<"${EV}")" = "${AFTER}" ] && [ "$(jq -r '.duration_s | type' <<<"${EV}")" = number ] \
  && [[ ! "${EV_AT}" < "${T_PRE}" ]] && [[ ! "${EV_AT}" > "${T_POST}" ]] \
  && [ ! -e "${S}/write-failures" ]; then
  ok "19. a push that moves origin's main: one merge.landed via=push, before/after/head right, timed from the push start (DND-1501), no drops"
else bad "19. merge.landed on a main push" "rc=${RC} ev='${EV}' pre=${T_PRE} post=${T_POST} err='${ERR}' failures='$(cat "${S}/write-failures" 2>/dev/null)'"; fi

S="${TMP}/p2-store"; git -C "${W}" commit -q --allow-empty -m c2
ghpush "${W}" "${S}" push -q origin HEAD:refs/heads/topic
[ "${RC}" = 0 ] && [ "$(landed_n "${S}")" = 0 ] && ok "20. a push to a non-default branch: no event" \
  || bad "20. non-default branch push" "rc=${RC} events='$(cat "${S}"/*.jsonl 2>/dev/null)'"

S="${TMP}/p3-store"; git -C "${W}" reset -q --hard "${BEFORE}"; git -C "${W}" commit -q --allow-empty -m diverged
( cd "${W}" && git push -q origin HEAD:main ) >/dev/null 2>&1; PLAIN_RC=$?
ghpush "${W}" "${S}" push -q origin HEAD:main
[ "${RC}" != 0 ] && [ "${RC}" = "${PLAIN_RC}" ] && [ "$(landed_n "${S}")" = 0 ] \
  && ok "21. a refused (non-ff) push: exit ${RC} passed through as plain git's, no event" \
  || bad "21. refused push" "rc=${RC} plain=${PLAIN_RC} events='$(cat "${S}"/*.jsonl 2>/dev/null)'"

S="${TMP}/p4-store"
ghpush "${W}" "${S}" push -q origin "${AFTER}:main"
[ "${RC}" = 0 ] && [ "$(landed_n "${S}")" = 0 ] && ok "22. a push that leaves main where it was: no event" \
  || bad "22. up-to-date push" "rc=${RC} events='$(cat "${S}"/*.jsonl 2>/dev/null)'"

O5="${TMP}/p5-origin.git"; git init -q --bare -b main "${O5}"; git -C "${W}" remote add empty "${O5}"
S="${TMP}/p5-store"
ghpush "${W}" "${S}" push -q empty HEAD:main
EV="$(landed "${S}")"
[ "${RC}" = 0 ] && [ "$(landed_n "${S}")" = 1 ] && [ "$(jq -r '.attrs | has("before")' <<<"${EV}")" = false ] \
  && [ "$(jq -r .attrs.after <<<"${EV}")" = "$(git -C "${W}" rev-parse HEAD)" ] \
  && ok "23. creating main on an empty origin: merge.landed with no before (null, never a guess)" \
  || bad "23. main created" "rc=${RC} ev='${EV}'"

origin_with_main p6; S="${TMP}/p6-store"
OUT="$(cd "${TMP}" && ATHENA_TELEMETRY_DIR="${S}" "${WRAPPER}" git -C "${W}" push -q origin HEAD:main 2>"${TMP}/err")"; RC=$?
EV="$(landed "${S}")"
[ "${RC}" = 0 ] && [ "$(landed_n "${S}")" = 1 ] && [ "$(jq -r .repo <<<"${EV}")" = p6-wt ] && [ "$(jq -r .attrs.after <<<"${EV}")" = "${AFTER}" ] \
  && ok "24. \`git -C <repo> push\` from elsewhere: the event names that repo" \
  || bad "24. -C push" "rc=${RC} ev='${EV}' err='$(cat "${TMP}/err")'"

origin_with_main p7; S="${TMP}/p7-store"
( cd "${W}" && ATHENA_TELEMETRY_DIR="${S}" GH_ATHENA_GIT_DRY_RUN=1 "${WRAPPER}" git push origin HEAD:main ) >/dev/null 2>&1
[ ! -e "${S}" ] && [ "$(git --git-dir="${O}" rev-parse main)" = "${BEFORE}" ] && ok "25. the dry-run seam pushes nothing and emits nothing" \
  || bad "25. dry-run emitted" "$(cat "${S}"/*.jsonl 2>/dev/null)"

# 25b. The unit: the one local branch (not main) whose tip is the pushed
# commit names the work, as the Mission branch does after the admiral's
# rebase. The ledger joins the landing by unit or head (DND-1477).
origin_with_main p9; S="${TMP}/p9-store"; git -C "${W}" branch dnd-42-fixture "${AFTER}"
ghpush "${W}" "${S}" push -q origin "${AFTER}:main"
EV="$(landed "${S}")"
[ "${RC}" = 0 ] && [ "$(jq -r '[.unit, .unit_source, .head] | join(" ")' <<<"${EV}")" = "DND-42 branch ${AFTER}" ] \
  && ok "25b. pushed from main: unit from the Mission branch at the pushed commit (DND-42), head = after" \
  || bad "25b. unit from the pushed commit's branch" "rc=${RC} ev='${EV}'"

# 25d. Another actor moves main DURING a push to another branch (a git shim
# lands a commit on origin/main right after the real push): main moved, but
# not by this push, so no landing.
SHIM2="${TMP}/shim2"; mkdir -p "${SHIM2}"; REALGIT="$(command -v git)"
# DND-1667: a guard right behind each git shim below, so a shim that is
# missing or not executable fails the suite instead of reaching the real git
# (ai/lib/forge-stub-guard.sh). fsg_make, not fsg_arm: the suite runs the
# real git for its fixtures.
. "${AI_DIR}/lib/forge-stub-guard.sh"
fsg_make "${TMP}/git-guard" git
origin_with_main p11; S="${TMP}/p11-store"
OTHER="$(git --git-dir="${O}" commit-tree "$(git --git-dir="${O}" rev-parse main^{tree})" -p "$(git --git-dir="${O}" rev-parse main)" -m other)"
printf '#!/bin/sh\n%s "$@"; rc=$?\nfor a in "$@"; do\n  if [ "$a" = push ]; then %s --git-dir=%s update-ref refs/heads/main %s; fi\ndone\nexit $rc\n' \
  "${REALGIT}" "${REALGIT}" "${O}" "${OTHER}" > "${SHIM2}/git"; chmod +x "${SHIM2}/git"
fsg_require_stubs "${SHIM2}" git
OUT="$(cd "${W}" && PATH="${SHIM2}:${FSG_DIR}:${PATH}" ATHENA_TELEMETRY_DIR="${S}" "${WRAPPER}" git push -q origin HEAD:refs/heads/topic 2>&1)"; RC=$?
[ "${RC}" = 0 ] && [ "$(git --git-dir="${O}" rev-parse main)" = "${OTHER}" ] && [ "$(landed_n "${S}")" = 0 ] \
  && ok "25d. main moved by another actor during a topic push: no phantom landing" \
  || bad "25d. concurrent move read as a landing" "rc=${RC} events='$(cat "${S}"/*.jsonl 2>/dev/null)' out='${OUT}'"

# 25e. Two local branches at the pushed commit: the unit is ambiguous, so no
# hint; it falls back to the checked-out branch (main).
origin_with_main p12; S="${TMP}/p12-store"
git -C "${W}" branch dnd-42-a "${AFTER}"; git -C "${W}" branch dnd-43-b "${AFTER}"
ghpush "${W}" "${S}" push -q origin HEAD:main
[ "${RC}" = 0 ] && [ "$(landed "${S}" | jq -r '[.unit, .unit_source] | join(" ")')" = "main branch-name" ] \
  && ok "25e. two branches at the pushed commit: no guess, the checked-out branch names the unit" \
  || bad "25e. ambiguous unit" "rc=${RC} ev='$(landed "${S}")'"

# 25c. The BEFORE read fails (a git shim fails the first ls-remote only): a
# push naming main still lands with no before; a push to another branch does
# not become a phantom landing. The telemetry child never sees the auth header.
SHIM="${TMP}/shim"; mkdir -p "${SHIM}"; REALGIT="$(command -v git)"
printf '#!/bin/sh\nfor a in "$@"; do\n  if [ "$a" = --symref ]; then exit 128; fi\ndone\nexec %s "$@"\n' "${REALGIT}" > "${SHIM}/git"; chmod +x "${SHIM}/git"
fsg_require_stubs "${SHIM}" git
origin_with_main p10; S="${TMP}/p10-store"
OUT="$(cd "${W}" && PATH="${SHIM}:${FSG_DIR}:${PATH}" ATHENA_TELEMETRY_DIR="${S}" "${WRAPPER}" git push -q origin HEAD:refs/heads/topic 2>&1)"; RC=$?
[ "${RC}" = 0 ] && [ "$(landed_n "${S}")" = 0 ] && ok "25c. before unreadable, a push to another branch: no phantom landing" \
  || bad "25c. phantom landing" "rc=${RC} events='$(cat "${S}"/*.jsonl 2>/dev/null)' out='${OUT}'"
OUT="$(cd "${W}" && PATH="${SHIM}:${FSG_DIR}:${PATH}" ATHENA_TELEMETRY_DIR="${S}" "${WRAPPER}" git push -q origin HEAD:main 2>&1)"; RC=$?
EV="$(landed "${S}")"
[ "${RC}" = 0 ] && [ "$(landed_n "${S}")" = 1 ] && [ "$(jq -r '.attrs | has("before")' <<<"${EV}")" = false ] \
  && [ "$(jq -r .attrs.after <<<"${EV}")" = "${AFTER}" ] \
  && ok "25c. before unreadable, a push naming main: landed with no before (null)" \
  || bad "25c. before-unknown landing" "rc=${RC} ev='${EV}' out='${OUT}'"

# 26. FAIL-OPEN: an unwritable store. The push still lands, exits 0, and its
# stdout is identical to the writable twin's (each twin its own origin).
mkdir -p "${TMP}/ro"; chmod 500 "${TMP}/ro"
origin_with_main p8a; ghpush "${W}" "${TMP}/p8-rw" push origin HEAD:main; O1="${OUT}"; R1="${RC}"
origin_with_main p8b; ghpush "${W}" "${TMP}/ro/telemetry" push origin HEAD:main; O2="${OUT}"; R2="${RC}"
chmod 700 "${TMP}/ro"
[ "${R1}" = 0 ] && [ "${R2}" = 0 ] && [ "${O1}" = "${O2}" ] && [ "$(git --git-dir="${O}" rev-parse main)" = "${AFTER}" ] \
  && [ ! -e "${TMP}/ro/telemetry" ] && [ "$(landed_n "${TMP}/p8-rw")" = 1 ] \
  && ok "26. unwritable store: the push lands, exit 0, stdout identical to the writable twin's" \
  || bad "26. fail-open push" "rc=${R1}/${R2} out1='${O1}' out2='${O2}' err='${ERR}'"

echo
echo "--- DND-1482: a push to main is REFUSED while main-health records main RED ---"
# red_marker <work dir> <red sha> : write main-health's red marker into the
# repo's git common dir, as ai/bin/main-health does on a RED verdict.
red_marker() {
  local c; c="$(git -C "$1" rev-parse --path-format=absolute --git-common-dir)"
  mkdir -p "${c}/main-health"
  printf 'schema=main-health-red/1\nsha=%s\nfirst_red=%s\nsince=2026-10-01T00:00:00Z\nrecord=%s/main-health/verdicts/%s\nalert=\n' \
    "$2" "$2" "${c}" "$2" > "${c}/main-health/red"
}
# pass_receipt <work dir> <head> <base> : integration-gate's pass receipt for
# <head>, sealed as the gate seals it (DND-1814).
pass_receipt() {
  forge_receipt "$@" \
    && "${AI_DIR}/bin/receipt-seal" seal --kind integration "$(git -C "$1" rev-parse --path-format=absolute --git-common-dir)/integration-receipts/$2.json"
}
# forge_receipt <work dir> <head> <base> : the same receipt, UNSEALED -- what
# a person or branch code writes by hand.
forge_receipt() {
  local c; c="$(git -C "$1" rev-parse --path-format=absolute --git-common-dir)"
  mkdir -p "${c}/integration-receipts"
  jq -n --arg h "$2" --arg b "$3" '{schema:"integration-receipt/1", verdict:"pass", head:$h, base:$b,
    target_ref:"origin/main", recorded_at:"2026-10-01T00:00:00Z"}' > "${c}/integration-receipts/$2.json"
}
is_red_refusal() { [ "${RC}" = 3 ] && [[ "${ERR}" == *"RED MAIN"* ]] && [[ "${ERR}" == *"Fix:"* ]]; }

# 27. No marker: a push to main proceeds (no red is known).
origin_with_main r1
ghpush "${W}" "${TMP}/r1-store" push -q origin HEAD:main
[ "${RC}" = 0 ] && [ "$(git --git-dir="${O}" rev-parse main)" = "${AFTER}" ] \
  && ok "27. no red-main marker: a push to main lands" \
  || bad "27. no marker blocks nothing" "rc=${RC} err='${ERR}'"

# 28. Marker RED at origin's main; an ungated commit on top: REFUSED, origin
# untouched, and the refusal names the red SHA.
origin_with_main r2; red_marker "${W}" "${BEFORE}"
ghpush "${W}" "${TMP}/r2-store" push -q origin HEAD:main
is_red_refusal && [ "$(git --git-dir="${O}" rev-parse main)" = "${BEFORE}" ] && [[ "${ERR}" == *"${BEFORE}"* ]] \
  && ok "28. main RED, ungated head: push refused (exit 3, RED MAIN, Fix:), origin main unmoved" \
  || bad "28. red main refuses an ungated push" "rc=${RC} err='${ERR}' main=$(git --git-dir="${O}" rev-parse main)"

# 29. Same, explicit <sha>:refs/heads/main spelling, and the dry-run seam.
gha "${W}" push origin "${AFTER}:refs/heads/main"
is_red_refusal && ok "29. <sha>:refs/heads/main is refused too, before the dry-run print" \
  || bad "29. explicit refspec refused" "rc=${RC} out='${OUT}' err='${ERR}'"

# 30. The fix: the head contains the red SHA and integration-gate passed
# exactly it. It lands, with a note.
pass_receipt "${W}" "${AFTER}" "${BEFORE}"
ghpush "${W}" "${TMP}/r2-store" push -q origin HEAD:main
[ "${RC}" = 0 ] && [ "$(git --git-dir="${O}" rev-parse main)" = "${AFTER}" ] && [[ "${ERR}" == *"lands as the fix"* ]] \
  && ok "30. main RED, gated head containing the red SHA: lands as the fix" \
  || bad "30. gated fix lands" "rc=${RC} err='${ERR}'"

# 31. A gated head that does NOT contain the red SHA is not a fix.
origin_with_main r3
SIDE="$(git -C "${W}" commit-tree "$(git -C "${W}" rev-parse HEAD^{tree})" -m side)"
red_marker "${W}" "${BEFORE}"; pass_receipt "${W}" "${SIDE}" "${SIDE}"
gha "${W}" push origin "${SIDE}:main"
is_red_refusal && [[ "${ERR}" == *"does not contain"* ]] \
  && ok "31. a gated head that does not contain the red SHA is refused" \
  || bad "31. unrelated gated head refused" "rc=${RC} err='${ERR}'"

# 32. A push to another branch, and a --dry-run push to main, are not landings.
gha "${W}" push origin HEAD:refs/heads/topic
[ "${RC}" = 0 ] && ok "32. main RED: a push to another branch proceeds" \
  || bad "32. topic push blocked" "rc=${RC} err='${ERR}'"
gha "${W}" push --dry-run origin HEAD:main
[ "${RC}" = 0 ] && ok "32b. main RED: a --dry-run push to main proceeds (it lands nothing)" \
  || bad "32b. dry-run push blocked" "rc=${RC} err='${ERR}'"

# 33. A bare `push` and `push origin HEAD` from main name main implicitly.
gha "${W}" push
is_red_refusal && ok "33. main RED: a bare push from the main branch is refused" \
  || bad "33. bare push refused" "rc=${RC} err='${ERR}'"
gha "${W}" push origin HEAD
is_red_refusal && ok "33b. main RED: push origin HEAD from the main branch is refused" \
  || bad "33b. HEAD push refused" "rc=${RC} err='${ERR}'"

# 33c. The refspec spellings a parse could miss: an alias for push, --repo,
# a wildcard. A delete and a push to another remote land nothing on origin/main.
origin_with_main r5; red_marker "${W}" "${BEFORE}"
gha "${W}" -c alias.p=push p origin HEAD:main
is_red_refusal && ok "33c. main RED: a push through a git alias (alias.p=push) is refused" \
  || bad "33c. alias push refused" "rc=${RC} err='${ERR}'"
gha "${W}" push --repo origin HEAD:main
is_red_refusal && ok "33d. main RED: push --repo origin HEAD:main is refused" \
  || bad "33d. --repo push refused" "rc=${RC} err='${ERR}'"
gha "${W}" push origin 'refs/heads/*:refs/heads/*'
is_red_refusal && ok "33e. main RED: a wildcard refspec that covers main is refused" \
  || bad "33e. wildcard push refused" "rc=${RC} err='${ERR}'"
gha "${W}" push -d origin topic
[ "${RC}" = 0 ] && ok "33f. main RED: push -d (a delete) proceeds" \
  || bad "33f. delete push blocked" "rc=${RC} err='${ERR}'"
git init -q --bare -b main "${TMP}/r5-other.git"; git -C "${W}" remote add other "${TMP}/r5-other.git"
gha "${W}" push other HEAD:main
[ "${RC}" = 0 ] && ok "33g. main RED: a push to main on a remote other than origin proceeds (the marker is origin's)" \
  || bad "33g. other-remote push blocked" "rc=${RC} err='${ERR}'"

# 34. A marker that cannot be read is COULD NOT LOOK, never "no red".
origin_with_main r4
C4="$(git -C "${W}" rev-parse --path-format=absolute --git-common-dir)"
mkdir -p "${C4}/main-health"; printf 'garbage\n' > "${C4}/main-health/red"
gha "${W}" push origin HEAD:main
[ "${RC}" = 3 ] && [[ "${ERR}" == *"COULD NOT LOOK"* ]] && [[ "${ERR}" == *"Fix:"* ]] \
  && ok "34. a malformed marker refuses as COULD NOT LOOK (not read as no red)" \
  || bad "34. malformed marker" "rc=${RC} err='${ERR}'"

echo
echo "--- DND-1690: in a gated repo a push to main needs a receipt, on a GREEN main too ---"
# gated_origin <name> : a bare origin whose main (B) declares a gate
# (ai/bin/harness-gate), and a clone W on a lane-shaped branch
# (shipwright/run-<name>) with one more commit H. No red marker anywhere.
# Sets O, W, B, H.
gated_origin() {
  O="${TMP}/$1-origin.git"; W="${TMP}/$1-wt"
  git init -q --bare -b main "${O}"
  git init -q -b main "${W}" && git -C "${W}" remote add origin "${O}"
  mkdir -p "${W}/ai/bin"; printf '#!/bin/sh\nexit 0\n' > "${W}/ai/bin/harness-gate"
  printf 'a\n' > "${W}/a.txt"; printf 'b\n' > "${W}/b.txt"
  git -C "${W}" add -A && git -C "${W}" commit -q -m base
  git -C "${W}" push -q origin main 2>/dev/null
  B="$(git -C "${W}" rev-parse HEAD)"
  git -C "${W}" checkout -q -b "shipwright/run-$1"
  printf 'b2\n' > "${W}/b.txt"; git -C "${W}" commit -q -am "lane change"
  H="$(git -C "${W}" rev-parse HEAD)"
}
# move_origin_main <work dir> : another actor lands a commit touching a.txt on
# origin's main; the work dir then fetches it (as the lane's sync down does).
move_origin_main() {
  local o="${TMP}/mover-$$-${RANDOM}"
  git clone -q "${O}" "${o}" && printf 'a2\n' > "${o}/a.txt" \
    && git -C "${o}" commit -q -am "other landing" && git -C "${o}" push -q origin main
  git -C "$1" fetch -q origin
  M="$(git -C "$1" rev-parse origin/main)"
}
is_gate_refusal() { [ "${RC}" = 3 ] && [[ "${ERR}" == *"NO RECEIPT"* ]] && [[ "${ERR}" == *"Fix:"* ]] \
  && [[ "${ERR}" == *"integration-gate --with-critic"* ]]; }

# 35. THE DEFECT: main is green (no marker), the lane's head has no receipt.
# Before DND-1690 this landed (bcfd66b6). Now it is refused, origin unmoved.
gated_origin g1
ghpush "${W}" "${TMP}/g1-store" push -q origin HEAD:main
is_gate_refusal && [ "$(git --git-dir="${O}" rev-parse main)" = "${B}" ] && [[ "${ERR}" == *"${H}"* ]] \
  && ok "35. green main, gated repo, lane head with no receipt: push to main refused (NO RECEIPT, Fix:), origin unmoved" \
  || bad "35. ungated lane push to a green main refused" "rc=${RC} err='${ERR}' main=$(git --git-dir="${O}" rev-parse main)"

# 35b. The dry-run seam judges it too, and the explicit refs/heads/main spelling.
gha "${W}" push origin "${H}:refs/heads/main"
is_gate_refusal && ok "35b. <sha>:refs/heads/main refused before the dry-run print" \
  || bad "35b. dry-run push refused" "rc=${RC} out='${OUT}' err='${ERR}'"

# 35c. DND-1814: a FORGED receipt for exactly the head -- the right shape,
# written by hand (or by branch code during a gate), with no seal. Before
# DND-1814 this landed on main. Now it is refused, origin unmoved.
forge_receipt "${W}" "${H}" "${B}"
ghpush "${W}" "${TMP}/g1-store" push -q origin HEAD:main
is_gate_refusal && [[ "${ERR}" == *"UNSEALED"* ]] && [ "$(git --git-dir="${O}" rev-parse main)" = "${B}" ] \
  && ok "35c. a forged (unsealed) receipt for the pushed head does not pass the push guard, origin unmoved" \
  || bad "35c. forged receipt refused" "rc=${RC} err='${ERR}' main=$(git --git-dir="${O}" rev-parse main)"
# 35d. A sealed receipt edited after sealing (its base moved by hand) is refused.
pass_receipt "${W}" "${H}" "${B}"
C="$(git -C "${W}" rev-parse --path-format=absolute --git-common-dir)/integration-receipts/${H}.json"
jq -c '.target_ref = "origin/elsewhere"' "${C}" > "${C}.t" && mv "${C}.t" "${C}"
gha "${W}" push origin "${H}:refs/heads/main"
is_gate_refusal && [[ "${ERR}" == *"FORGED OR EDITED"* ]] \
  && ok "35d. a sealed receipt edited by hand does not pass the push guard" \
  || bad "35d. edited receipt refused" "rc=${RC} err='${ERR}'"

# 36. The lane-shaped push that PASSES: integration-gate's receipt for exactly
# the head (as `integration-gate --with-critic --rebase` writes it).
pass_receipt "${W}" "${H}" "${B}"
ghpush "${W}" "${TMP}/g1-store" push -q origin HEAD:main
[ "${RC}" = 0 ] && [ "$(git --git-dir="${O}" rev-parse main)" = "${H}" ] && [[ "${ERR}" == *"integration-gate passed exactly ${H}"* ]] \
  && ok "36. lane head with its own receipt: lands on main, with a note naming the receipt" \
  || bad "36. receipted lane push lands" "rc=${RC} err='${ERR}'"

# 37. DND-1463, kept: H gated on B; origin main moved to M; the clean rebase
# P of H onto M has no receipt of its own and lands as the gated head.
gated_origin g2; pass_receipt "${W}" "${H}" "${B}"
move_origin_main "${W}"
git -C "${W}" rebase -q origin/main; P="$(git -C "${W}" rev-parse HEAD)"
ghpush "${W}" "${TMP}/g2-store" push -q origin HEAD:main
[ "${RC}" = 0 ] && [ "${P}" != "${H}" ] && [ "$(git --git-dir="${O}" rev-parse main)" = "${P}" ] \
  && [[ "${ERR}" == *"clean rebase of the gated head ${H}"* ]] \
  && ok "37. clean rebase of a gated head onto a moved main lands with no re-gate (DND-1463)" \
  || bad "37. clean rebase of a gated head lands" "rc=${RC} p=${P} err='${ERR}'"

# 38. The same rebase with an UNGATED commit on top is refused: its tree is
# not the gated head's change on M.
gated_origin g3; pass_receipt "${W}" "${H}" "${B}"
move_origin_main "${W}"
git -C "${W}" rebase -q origin/main
printf 'sneak\n' > "${W}/c.txt"; git -C "${W}" add c.txt; git -C "${W}" commit -q -m "lane change"
gha "${W}" push origin HEAD:main
is_gate_refusal && [[ "${ERR}" == *"candidate"* ]] \
  && ok "38. a rebased head plus an ungated commit is refused, and the refusal counts the candidates it checked" \
  || bad "38. ungated commit on a rebased head refused" "rc=${RC} err='${ERR}'"

# 39. A receipt for the pushed head that cannot be read is COULD NOT LOOK,
# never a pass.
gated_origin g4
C="$(git -C "${W}" rev-parse --path-format=absolute --git-common-dir)"
mkdir -p "${C}/integration-receipts"; printf '{not json\n' > "${C}/integration-receipts/${H}.json"
gha "${W}" push origin HEAD:main
[ "${RC}" = 3 ] && [[ "${ERR}" == *"COULD NOT LOOK"* ]] && [[ "${ERR}" == *"Fix:"* ]] \
  && ok "39. an unreadable receipt for the pushed head refuses as COULD NOT LOOK" \
  || bad "39. unreadable receipt" "rc=${RC} err='${ERR}'"

# 40. The gate is read on the LANDED main, not the pushed head: a head that
# deletes the gate script is still refused.
gated_origin g5
git -C "${W}" rm -q ai/bin/harness-gate && git -C "${W}" commit -q -m "lane change"
gha "${W}" push origin HEAD:main
is_gate_refusal && ok "40. a head that deletes the declared gate is still refused (the bar is origin/main's)" \
  || bad "40. gate read from the landed main" "rc=${RC} err='${ERR}'"

# 41. A receipt whose recorded base is not an ancestor of origin/main does
# not cover a rebase onto it, even when the head contains that base: the
# base H here is unlanded lane work, so the gate never judged it against main.
gated_origin g6
printf 'c\n' > "${W}/c.txt"; git -C "${W}" add c.txt; git -C "${W}" commit -q -m "second lane change"
pass_receipt "${W}" "$(git -C "${W}" rev-parse HEAD)" "${H}"
move_origin_main "${W}"
git -C "${W}" rebase -q origin/main
gha "${W}" push origin HEAD:main
is_gate_refusal && ok "41. a gated head whose receipt base is not an ancestor of origin/main does not cover the rebase" \
  || bad "41. receipt for another base" "rc=${RC} err='${ERR}'"

# 42. What is not a landing on main proceeds with no receipt: a push to the
# lane branch, a --dry-run push to main, and a push of what main already is.
gated_origin g7
gha "${W}" push origin HEAD:refs/heads/shipwright/run-g7
[ "${RC}" = 0 ] && ok "42. gated repo: an ungated push to a non-main branch proceeds" \
  || bad "42. branch push blocked" "rc=${RC} err='${ERR}'"
gha "${W}" push --dry-run origin HEAD:main
[ "${RC}" = 0 ] && ok "42b. gated repo: a --dry-run push to main proceeds (it lands nothing)" \
  || bad "42b. dry-run push blocked" "rc=${RC} err='${ERR}'"
gha "${W}" push origin "${B}:main"
[ "${RC}" = 0 ] && ok "42c. gated repo: pushing the commit origin/main already is proceeds (nothing new lands)" \
  || bad "42c. up-to-date push blocked" "rc=${RC} err='${ERR}'"

# 43. A merge commit of the landed main and a gated head (the `wt merge`
# shape) lands: its tree is the clean merge of the gated head onto main.
gated_origin g8; pass_receipt "${W}" "${H}" "${B}"
move_origin_main "${W}"
git -C "${W}" checkout -q -B main origin/main && git -C "${W}" merge -q --no-edit "${H}"
gha "${W}" push origin main
[ "${RC}" = 0 ] && [[ "${ERR}" == *"${H}"* ]] \
  && ok "43. a clean merge commit of origin/main and a gated head proceeds" \
  || bad "43. merge of a gated head" "rc=${RC} err='${ERR}'"

# 44. The landed main is the PUSHED remote's: a clone whose remote is named
# upstream (no origin/main at all) and a head that deletes the gate is still
# judged against upstream/main, and refused.
gated_origin g9
U="${TMP}/g9-up"; git clone -q -o upstream "${O}" "${U}"
git -C "${U}" rm -q ai/bin/harness-gate && git -C "${U}" commit -q -m "lane change"
gha "${U}" push upstream HEAD:main
is_gate_refusal && [[ "${ERR}" == *"ai/bin/harness-gate on ${B}"* ]] \
  && ok "44. remote named upstream: judged on upstream/main, a gate-deleting head is refused" \
  || bad "44. non-origin remote" "rc=${RC} err='${ERR}'"

# 45. No landed main is known (a URL push, no tracking ref): the repo counts as
# gated because the pushed commit's history held the gate, so deleting it in
# the pushed commit does not escape the bar.
gha "${U}" push "file://${O}" HEAD:main
is_gate_refusal && [[ "${ERR}" == *"no landed main is known"* ]] \
  && ok "45. URL push with no tracking ref: gate found in history, ungated head refused" \
  || bad "45. URL push, no landed main" "rc=${RC} err='${ERR}'"

# 46. A candidate gated head whose receipt cannot be read: COULD NOT LOOK,
# never "no candidate covers it".
gated_origin g10
C="$(git -C "${W}" rev-parse --path-format=absolute --git-common-dir)"
mkdir -p "${C}/integration-receipts"; printf '{not json\n' > "${C}/integration-receipts/${H}.json"
move_origin_main "${W}"
git -C "${W}" rebase -q origin/main
gha "${W}" push origin HEAD:main
[ "${RC}" = 3 ] && [[ "${ERR}" == *"COULD NOT LOOK"* ]] && [[ "${ERR}" == *"${H}"* ]] && [[ "${ERR}" == *"Fix:"* ]] \
  && ok "46. an unreadable receipt on a candidate gated head refuses as COULD NOT LOOK" \
  || bad "46. unreadable candidate receipt" "rc=${RC} err='${ERR}'"

# 47. The cron shape: a LINKED WORKTREE lane with two commits, gated, then
# rebased onto a main another actor moved. It lands by real push.
gated_origin g11
git -C "${W}" checkout -q main
LANE="${TMP}/g11-lane"; git -C "${W}" worktree add -q -b leadtime/run-g11 "${LANE}" origin/main
printf 'x\n' > "${LANE}/x.txt"; git -C "${LANE}" add x.txt; git -C "${LANE}" commit -q -m "lane one"
printf 'y\n' > "${LANE}/y.txt"; git -C "${LANE}" add y.txt; git -C "${LANE}" commit -q -m "lane two"
H2="$(git -C "${LANE}" rev-parse HEAD)"; pass_receipt "${LANE}" "${H2}" "${B}"
move_origin_main "${LANE}"
git -C "${LANE}" rebase -q origin/main; P="$(git -C "${LANE}" rev-parse HEAD)"
ghpush "${LANE}" "${TMP}/g11-store" push -q origin HEAD:main
[ "${RC}" = 0 ] && [ "$(git --git-dir="${O}" rev-parse main)" = "${P}" ] && [[ "${ERR}" == *"gated head ${H2}"* ]] \
  && ok "47. linked-worktree lane, two commits, gated then rebased onto a moved main: lands" \
  || bad "47. worktree lane rebase lands" "rc=${RC} err='${ERR}'"

# 48. DND-1809: ir_push_covered lists EVERY gated head that covers a clean
# rebase (IR_COVER_HEADS), so the lead-time ledger can refuse to guess when
# two do. H and H2 are one change gated twice (same author, author date,
# subject and tree; only the committer date differs). The push guard's own
# answer is unchanged: covered, IR_COVER_HEAD the first cover, and
# IR_RECEIPT that head's receipt.
gated_origin g12; pass_receipt "${W}" "${H}" "${B}"
H2="$(GIT_COMMITTER_DATE=2026-10-01T00:00:09Z git -C "${W}" commit -q --amend --no-edit && git -C "${W}" rev-parse HEAD)"
pass_receipt "${W}" "${H2}" "${B}"
move_origin_main "${W}"
git -C "${W}" rebase -q origin/main; P="$(git -C "${W}" rev-parse HEAD)"
C="$(git -C "${W}" rev-parse --path-format=absolute --git-common-dir)"
COV="$(bash -c '. "$1" && ir_push_covered "$2" "$3" "$4"; printf "%s|%s|%s|%s\n" "$?" "$IR_COVER" "$(printf "%s\n" "${IR_COVER_HEADS[@]}" | sort | tr "\n" " ")" "$IR_COVER_HEAD:$IR_RECEIPT"' \
  _ "${AI_DIR}/lib/integration-receipt.sh" "${C}" "${P}" "${M}")"
WANT_HEADS="$(printf '%s\n' "${H}" "${H2}" | sort | tr '\n' ' ')"
FIRST="${COV##*|}"; FIRST="${FIRST%%:*}"
[ "${H}" != "${H2}" ] && [[ "${COV}" == "0|rebase|${WANT_HEADS}|"* ]] \
  && [[ "${COV}" == *"|${FIRST}:${C}/integration-receipts/${FIRST}.json" ]] \
  && ok "48. two gated heads of one change both cover the rebase: IR_COVER_HEADS lists both; IR_RECEIPT is the first cover's (DND-1809)" \
  || bad "48. every covering head listed" "cov='${COV}' want heads='${WANT_HEADS}'"

echo
echo "--- DND-1843: an option VALUE is never read as the subcommand, the repository or a flag ---"
# git's own grammar: a global option that takes a value (--attr-source,
# --shallow-file) consumes the next word; a push option that takes a value
# consumes the next word under any unambiguous abbreviation (--push-o) and
# at the end of a short cluster (-vo). Each spelling below once hid the push,
# its repository, or its destination from the checks.
R="$(new_repo v1843 'ssh://git@github.com/o/r.git')"
gha "${R}" --attr-source HEAD push origin HEAD
is_refusal && ok "S25. --attr-source HEAD push: the value is not the subcommand, the ssh:// origin is refused" \
  || bad "S25. --attr-source push judged" "rc=${RC} out='${OUT}' err='${ERR}'"
gha "${R}" --shallow-file "${TMP}/no-shallow" push origin HEAD
is_refusal && ok "S26. --shallow-file <file> push: judged, the ssh:// origin is refused" \
  || bad "S26. --shallow-file push judged" "rc=${RC} out='${OUT}' err='${ERR}'"
gha "${R}" push --push-o ci.skip
is_refusal && ok "S27. push --push-o ci.skip: the default remote (ssh://) is judged, not ci.skip" \
  || bad "S27. abbreviated push option" "rc=${RC} out='${OUT}' err='${ERR}'"
gha "${R}" push -vo ci.skip
is_refusal && ok "S28. push -vo ci.skip: a cluster ending in o takes the value; the default remote is refused" \
  || bad "S28. short cluster value" "rc=${RC} out='${OUT}' err='${ERR}'"
gha "${R}" push --recurse-submodules no
is_refusal && ok "S29. push --recurse-submodules no: the value is not the repository; the default remote is refused" \
  || bad "S29. recurse-submodules separate value" "rc=${RC} out='${OUT}' err='${ERR}'"
gha "${R}" push --synth-unknown origin HEAD
if is_refusal && [[ "${ERR}" == *"--synth-unknown"* ]]; then ok "S30. a push option git push does not have is refused (deny by default)"
else bad "S30. unknown push option" "rc=${RC} out='${OUT}' err='${ERR}'"; fi
gha "${R}" --synth-unknown push origin HEAD
if is_refusal && [[ "${ERR}" == *"--synth-unknown"* ]]; then ok "S31. a global option git does not have is refused (deny by default)"
else bad "S31. unknown global option" "rc=${RC} out='${OUT}' err='${ERR}'"; fi
R="$(new_repo v1843b 'https://github.com/o/r.git')"
gha "${R}" push --push-opt ci.skip --force-with-lease origin HEAD:refs/heads/feat
if [ "${RC}" = 0 ] && [[ "${OUT}" == *"dry-run: url athena-forge::https://github.com/o/r.git"* ]]; then
  ok "S32. an abbreviated push option and an optional-value flag still push to the named HTTPS remote"
else bad "S32. abbreviated option happy path" "rc=${RC} out='${OUT}' err='${ERR}'"; fi
gha "${R}" --version
if [ "${RC}" = 0 ] && [[ "${OUT}" == *"dry-run: exec git"* ]]; then ok "S33. --version (no subcommand) still passes"
else bad "S33. --version passes" "rc=${RC} out='${OUT}' err='${ERR}'"; fi

# The red-main and ungated-main refusals read the refspecs from the same parse:
# a value spelled like --dry-run or -n is a value, not a dry run.
origin_with_main v1843r; red_marker "${W}" "${BEFORE}"
gha "${W}" push --push-o --dry-run origin HEAD:main
is_red_refusal && ok "S34. main RED: push --push-o --dry-run origin HEAD:main is refused (--dry-run is a value)" \
  || bad "S34. red main, dry-run as a value" "rc=${RC} out='${OUT}' err='${ERR}'"
gha "${W}" push -vo -n origin HEAD:main
is_red_refusal && ok "S35. main RED: push -vo -n origin HEAD:main is refused (-n is the cluster's value)" \
  || bad "S35. red main, -n as a value" "rc=${RC} out='${OUT}' err='${ERR}'"
gha "${W}" push --dry origin HEAD:main
[ "${RC}" = 0 ] && ok "S36. main RED: push --dry (an abbreviated --dry-run) proceeds: it lands nothing" \
  || bad "S36. abbreviated dry-run" "rc=${RC} out='${OUT}' err='${ERR}'"
gated_origin v1843g
gha "${W}" push --push-option --delete origin HEAD:main
is_gate_refusal && ok "S37. gated repo: push --push-option --delete origin HEAD:main needs a receipt (--delete is a value)" \
  || bad "S37. gated, delete as a value" "rc=${RC} out='${OUT}' err='${ERR}'"
# Review round: git applies the LAST of --dry-run / --no-dry-run and of
# --delete / --no-delete, and reads every word after `--` as a refspec.
gha "${W}" push --dry-run --no-dry-run origin HEAD:main
is_gate_refusal && ok "S38. gated repo: --dry-run --no-dry-run pushes, so it needs a receipt" \
  || bad "S38. negated dry-run" "rc=${RC} out='${OUT}' err='${ERR}'"
gha "${W}" push -d --no-delete origin HEAD:main
is_gate_refusal && ok "S39. gated repo: -d --no-delete pushes, so it needs a receipt" \
  || bad "S39. negated delete" "rc=${RC} out='${OUT}' err='${ERR}'"
git -C "${W}" update-ref refs/heads/-x HEAD
gha "${W}" push origin -- -x:main
is_gate_refusal && ok "S40. gated repo: push origin -- -x:main (a refspec after --) needs a receipt" \
  || bad "S40. dash refspec after --" "rc=${RC} out='${OUT}' err='${ERR}'"
R="$(new_repo v1843c 'ssh://git@github.com/o/r.git')"
gha "${R}" push --repo=https://github.com/o/r.git --no-repo
is_refusal && ok "S41. push --repo=<https> --no-repo: git pushes to the default remote (ssh://), which is refused" \
  || bad "S41. --no-repo cancels --repo" "rc=${RC} out='${OUT}' err='${ERR}'"

echo
echo "--- DND-1844: a subcommand that runs a command git starts itself is REFUSED ---"
# A command git runs itself (submodule foreach, bisect run, rebase --exec, ...)
# inherits the bot's header from the environment config channel, and a push it
# runs goes through git's exec-path, where no wrapper judges the remote, the
# recursion, a red main or the gate. Each such form is refused, never run.
# rc_refused <label> [<text the Fix must carry>] : exit 3 with the
# command-running refusal and its Fix, and git never ran.
rc_refused() {
  if is_refusal && [[ "${ERR}" == *"runs a command"* ]] && [[ "${OUT}" != *"dry-run: exec git"* ]] \
    && [[ "${ERR}" == *"${2:-Fix:}"* ]]; then ok "$1"
  else bad "$1" "rc=${RC} out='${OUT}' err='${ERR}'"; fi
}
# rc_passed <label> : exit 0, no refusal, git would run.
rc_passed() {
  if [ "${RC}" = 0 ] && [[ "${OUT}" == *"dry-run: exec git"* ]] && [[ "${ERR}" != *"REFUSING"* ]]; then ok "$1"
  else bad "$1" "rc=${RC} out='${OUT}' err='${ERR}'"; fi
}
PER_SM="git -C <submodule>"
gha "${SM}" submodule foreach 'git push'
rc_refused "C1. submodule foreach 'git push' -> refused, Fix: run it per submodule through the route" "${PER_SM}"
gha "${SM}" submodule --quiet foreach --recursive git push origin HEAD:refs/heads/feat
rc_refused "C2. submodule --quiet foreach --recursive git push -> refused" "${PER_SM}"
gha "${SM}" submodule--helper foreach 'git push'
rc_refused "C3. submodule--helper foreach (the helper git-submodule calls) -> refused" "${PER_SM}"
gha "${SM}" -c 'alias.fe=submodule foreach git push' fe
rc_refused "C4. an alias that expands to submodule foreach -> refused" "${PER_SM}"
gha "${SM}" -c alias.submodule=status submodule foreach 'git push'
rc_refused "C5. alias.submodule=status does not hide foreach (git ignores an alias named for a git command)" "${PER_SM}"
gha "${SM}" bisect run git push
rc_refused "C6. bisect run <cmd> -> refused"
gha "${SM}" -c alias.bisect=status bisect run git push
rc_refused "C7. alias.bisect=status does not hide bisect run (git ignores it)"
gha "${SM}" rebase --exec 'git push' HEAD~1
rc_refused "C8. rebase --exec <cmd> -> refused"
gha "${SM}" rebase -x 'git push' HEAD~1
rc_refused "C9. rebase -x <cmd> -> refused"
gha "${SM}" rebase -ix 'git push' HEAD~1
rc_refused "C10. rebase -ix <cmd> (x inside a short cluster) -> refused"
gha "${SM}" rebase --ex='git push' HEAD~1
rc_refused "C11. rebase --ex=<cmd> (an abbreviation git accepts) -> refused"
gha "${SM}" difftool --extcmd='git push' HEAD~1
rc_refused "C12. difftool --extcmd <cmd> -> refused"
gha "${SM}" mergetool --tool=vimdiff
rc_refused "C13. mergetool (it always launches a tool command) -> refused"
gha "${SM}" grep -O'git push' init
rc_refused "C14. grep -O<pager> -> refused"
gha "${SM}" grep --open-files-in-pager='git push' init
rc_refused "C15. grep --open-files-in-pager=<pager> -> refused"
gha "${SM}" filter-branch --tree-filter 'git push' HEAD
rc_refused "C16. filter-branch (its filters are shell) -> refused"
gha "${SM}" send-email --to-cmd='git push' HEAD~1
rc_refused "C17. send-email (its --*-cmd options run commands) -> refused"
gha "${SM}" hook run pre-push
rc_refused "C18. hook run <hook> -> refused"
gha "${SM}" -c 'alias.x=!git push' x
if is_refusal && [[ "${ERR}" == *"shell alias"* ]]; then
  ok "C19. -c 'alias.x=!git push' (a shell alias from -c) -> refused"
else bad "C19. shell alias from -c refused" "rc=${RC} out='${OUT}' err='${ERR}'"; fi
gha "${SM}" push --receive-pack='git push; true' "${SUPBARE}" HEAD:refs/heads/feat
rc_refused "C20. push --receive-pack=<cmd> (run locally for a local remote) -> refused"
gha "${SM}" push --exec='git push; true' "${SUPBARE}" HEAD:refs/heads/feat
rc_refused "C21. push --exec=<cmd> -> refused"
gha "${SM}" push --rece 'git push; true' "${SUPBARE}" HEAD:refs/heads/feat
rc_refused "C22. push --rece <cmd> (an abbreviation of --receive-pack) -> refused"
gha "${SM}" fetch --upload-pack='git push; true' "${SUBBARE}"
rc_refused "C23. fetch --upload-pack=<cmd> -> refused"
gha "${SM}" ls-remote --u='git push; true' "${SUBBARE}"
rc_refused "C24. ls-remote --u=<cmd> (an abbreviation of --upload-pack) -> refused"
gha "${TMP}" clone -u 'git push; true' "${SUBBARE}" "${TMP}/c-clone"
rc_refused "C25. clone -u <cmd> -> refused"
gha "${SM}" archive --remote="${SUPBARE}" --exec='git push; true' HEAD
rc_refused "C26. archive --exec=<cmd> -> refused"
gha "${SM}" -c protocol.ext.allow=always fetch 'ext::sh -c git% push' main
rc_refused "C27. an ext:: URL (its address is a shell command) -> refused"
R="$(new_repo extremote 'ext::sh -c git% push')"
gha "${R}" -c protocol.ext.allow=always fetch origin
rc_refused "C27b. a remote whose configured URL is ext:: -> refused"
gha "${SM}" --exec-path="${TMP}/evil-exec" status
rc_refused "C28. --exec-path=<dir> (git runs its helpers from there) -> refused"
OUT="$(cd "${SM}" && GIT_EXEC_PATH="${TMP}/evil-exec" GH_ATHENA_GIT_DRY_RUN=1 "${WRAPPER}" git status 2>"${TMP}/err")"; RC=$?
ERR="$(cat "${TMP}/err")"
rc_refused "C29. GIT_EXEC_PATH set to another directory -> refused"

gha "${SM}" submodule status
rc_passed "C30. submodule status passes"
gha "${SM}" submodule init
rc_passed "C31. submodule init passes"
gha "${SM}" submodule sync
rc_passed "C32. submodule sync passes"
gha "${SM}" submodule update --recursive
rc_passed "C33. submodule update passes"
gha "${SM}" rebase --no-exec HEAD~1
rc_passed "C34. rebase with no exec passes"
gha "${SM}" grep -e TODO -- init
rc_passed "C35. grep with no pager option passes"
gha "${SM}" bisect log
rc_passed "C36. bisect log passes"
gha "${SM}" hook list pre-push
rc_passed "C37. hook list passes"
OUT="$(cd "${SM}" && GIT_EXEC_PATH="$(env -u GIT_EXEC_PATH git --exec-path)" GH_ATHENA_GIT_DRY_RUN=1 "${WRAPPER}" git status 2>"${TMP}/err")"; RC=$?
ERR="$(cat "${TMP}/err")"
rc_passed "C38. GIT_EXEC_PATH set to git's own exec-path (as git exports it to its children) passes"
# Review round: forms of the same class the first walk did not know.
gha "${SM}" ls-remote --exec='git push; true' "${SUBBARE}"
rc_refused "C39. ls-remote --exec=<cmd> (a hidden spelling of --upload-pack) -> refused"
gha "${SM}" ls-remote --exe='git push; true' "${SUBBARE}"
rc_refused "C40. ls-remote --exe=<cmd> (its abbreviation) -> refused"
gha "${SM}" -c "fe.repo=${SM}" for-each-repo --config=fe.repo -- -c 'alias.z=!git push' z
rc_refused "C41. for-each-repo (it runs a git argv per repository, from git's exec-path) -> refused" "git -C <repository>"
gha "${SM}" send-pack --receive-pack='git push; true' "${SUPBARE}" main
rc_refused "C42. send-pack --receive-pack=<cmd> -> refused"
gha "${SM}" send-pack --exec='git push; true' "${SUPBARE}" main
rc_refused "C43. send-pack --exec=<cmd> -> refused"
gha "${SM}" fetch-pack --upload-pack='git push; true' "${SUBBARE}" main
rc_refused "C44. fetch-pack --upload-pack=<cmd> -> refused"
gha "${SM}" fetch-pack --exec='git push; true' "${SUBBARE}" main
rc_refused "C45. fetch-pack --exec=<cmd> -> refused"
gha "${SM}" remote-ext origin 'sh -c git% push'
rc_refused "C46. remote-ext <remote> <cmd> (the ext helper called directly) -> refused"
gha "${TMP}" clone --template="${TMP}/tpl" "${SUBBARE}" "${TMP}/c-tpl"
rc_refused "C47. clone --template=<dir> (its post-checkout hook runs during the clone) -> refused"
gha "${TMP}" init --template="${TMP}/tpl" "${TMP}/i-tpl"
rc_refused "C48. init --template=<dir> -> refused"
gha "${SM}" instaweb --httpd='git push'
rc_refused "C49. instaweb -> refused"
gha "${SM}" daemon --access-hook='git push' --export-all
rc_refused "C50. daemon -> refused"
gha "${SM}" -c 'alias.hr=hook run' hr pre-push
rc_refused "C51. an alias that expands to hook run -> refused"
gha "${SM}" log --grep=ext::x
rc_passed "C52. an ext:: word in a subcommand that names no repository (log --grep) passes"
gha "${SM}" fetch "${SUBBARE}"
rc_passed "C53. fetch from a local path with no command option passes"

echo
echo "--- DND-1867: a command that writes a remote ref other than \`git push\` is REFUSED ---"
# send-pack, http-push, a transport helper called directly (remote-<name>) and
# subtree push each write a remote ref, but only \`push\` is judged for its
# remote, its recursion, a red main and the gate. Each is refused, with a Fix:
# that names the routed \`git push\`. So is a subcommand git does not know: under
# help.autocorrect git runs the closest command (pusj -> push) unjudged.
# rw_refused <label> [<text the Fix must carry>] : exit 3 with the remote-ref
# refusal and its Fix, and git never ran.
rw_refused() {
  if is_refusal && [[ "${ERR}" == *"writes a remote ref"* ]] && [[ "${OUT}" != *"dry-run: exec git"* ]] \
    && [[ "${ERR}" == *"${2:-git push}"* ]]; then ok "$1"
  else bad "$1" "rc=${RC} out='${OUT}' err='${ERR}'"; fi
}
# un_refused <label> : exit 3, the unknown-subcommand refusal, git never ran.
un_refused() {
  if is_refusal && [[ "${ERR}" == *"no command git knows"* ]] && [[ "${ERR}" == *"help.autocorrect"* ]] \
    && [[ "${OUT}" != *"dry-run: exec git"* ]]; then ok "$1"
  else bad "$1" "rc=${RC} out='${OUT}' err='${ERR}'"; fi
}
AC="help.autocorrect"

# W1. THE DEFECT: a gated repo on a green main; the head has no receipt. A
# routed push to main is refused (35); send-pack to the same main landed.
gated_origin w1
ghpush "${W}" "${TMP}/w1-store" send-pack "${O}" HEAD:refs/heads/main
if is_refusal && [[ "${ERR}" == *"writes a remote ref"* ]] && [[ "${ERR}" == *"git push"* ]] \
  && [ "$(git --git-dir="${O}" rev-parse main)" = "${B}" ]; then
  ok "W1. gated repo, no receipt: send-pack <origin> HEAD:refs/heads/main refused (exit 3, Fix: git push), origin main unmoved"
else bad "W1. send-pack to main refused" "rc=${RC} err='${ERR}' main=$(git --git-dir="${O}" rev-parse main) base=${B}"; fi
ghpush "${W}" "${TMP}/w1-store" -c alias.sp=send-pack sp "${O}" HEAD:refs/heads/main
if is_refusal && [[ "${ERR}" == *"writes a remote ref"* ]] && [ "$(git --git-dir="${O}" rev-parse main)" = "${B}" ]; then
  ok "W2. the same through an alias (alias.sp=send-pack): refused, origin main unmoved"
else bad "W2. alias to send-pack refused" "rc=${RC} err='${ERR}' main=$(git --git-dir="${O}" rev-parse main)"; fi
ghpush "${W}" "${TMP}/w1-store" -c "${AC}=immediate" pusj -q origin HEAD:main
un_refused "W3. -c ${AC}=immediate pusj (git runs push) to main: refused"
ghpush "${W}" "${TMP}/w1-store" -c "${AC}=immediate" send-pak "${O}" HEAD:refs/heads/main
un_refused "W4. -c ${AC}=immediate send-pak (git runs send-pack): refused"
git -C "${W}" config "${AC}" immediate
gha "${W}" pusj origin HEAD:main
un_refused "W5. ${AC} from the repository's own config, then pusj: refused"
git -C "${W}" config --unset "${AC}"
[ "$(git --git-dir="${O}" rev-parse main)" = "${B}" ] && ok "W6. after W1-W5 origin main is still the gated base" \
  || bad "W6. origin main moved" "main=$(git --git-dir="${O}" rev-parse main) base=${B}"

# W7. main RED: send-pack to main is refused there too, and to any branch.
origin_with_main w7; red_marker "${W}" "${BEFORE}"
gha "${W}" send-pack "${O}" HEAD:refs/heads/main
rw_refused "W7. main RED: send-pack HEAD:refs/heads/main -> refused"
origin_with_main w8
gha "${W}" send-pack "${O}" HEAD:refs/heads/topic
rw_refused "W8. send-pack to a topic branch on a green main -> refused too (Fix: git push)"
gha "${W}" send-pack --all "${O}"
rw_refused "W9. send-pack --all -> refused"
gha "${W}" -c alias.send-pack=status send-pack "${O}" HEAD:refs/heads/main
rw_refused "W10. an alias named send-pack (git ignores it and runs send-pack) -> refused"
gha "${W}" http-push https://github.com/o/r.git main
rw_refused "W11. http-push <url> <ref> -> refused"
gha "${W}" -c alias.http-push=status http-push https://github.com/o/r.git main
rw_refused "W12. an alias named http-push (git runs the git-http-push command, not the alias) -> refused"
for h in remote-https remote-http remote-ftps remote-ftp remote-fd; do
  gha "${W}" "${h}" origin https://github.com/o/r.git </dev/null
  rw_refused "W13. ${h} <remote> <url> (a transport helper called directly; it pushes what stdin asks) -> refused"
done
gha "${W}" -c alias.rh=remote-https rh origin https://github.com/o/r.git </dev/null
rw_refused "W14. an alias to remote-https -> refused"

# W15. subtree push: a real split history on a local bare origin, main RED.
# A plain push of the split to main is refused (control); subtree push landed.
ST_O="${TMP}/st-origin.git"; ST_W="${TMP}/st-wt"
git init -q --bare -b main "${ST_O}"
git init -q -b main "${ST_W}" && git -C "${ST_W}" remote add origin "${ST_O}"
mkdir -p "${ST_W}/lib"; printf 'a\n' > "${ST_W}/lib/a"
git -C "${ST_W}" add -A && git -C "${ST_W}" commit -q -m base
git -C "${ST_W}" subtree split -q -P lib -b split >/dev/null 2>&1
git -C "${ST_W}" push -q origin split:main 2>/dev/null; git -C "${ST_W}" fetch -q origin
ST_B="$(git --git-dir="${ST_O}" rev-parse main)"
printf 'b\n' > "${ST_W}/lib/b"; git -C "${ST_W}" add -A && git -C "${ST_W}" commit -q -m more
red_marker "${ST_W}" "${ST_B}"
ghpush "${ST_W}" "${TMP}/st-store" subtree push -q -P lib origin main
if is_refusal && [[ "${ERR}" == *"writes a remote ref"* ]] && [[ "${ERR}" == *"subtree split"* ]] \
  && [ "$(git --git-dir="${ST_O}" rev-parse main)" = "${ST_B}" ]; then
  ok "W15. main RED: subtree push -P lib origin main refused (Fix: split, then git push), origin main unmoved"
else bad "W15. subtree push to a red main refused" "rc=${RC} err='${ERR}' main=$(git --git-dir="${ST_O}" rev-parse main) base=${ST_B}"; fi
ghpush "${ST_W}" "${TMP}/st-store" subtree -P lib push origin main
if is_refusal && [[ "${ERR}" == *"writes a remote ref"* ]] && [ "$(git --git-dir="${ST_O}" rev-parse main)" = "${ST_B}" ]; then
  ok "W16. subtree -P lib push origin main (the option before the command) refused, origin main unmoved"
else bad "W16. subtree option-first push refused" "rc=${RC} err='${ERR}' main=$(git --git-dir="${ST_O}" rev-parse main)"; fi
gha "${ST_W}" subtree push --prefix=lib origin topic
rw_refused "W17. subtree push to a topic branch -> refused too" "subtree split"

# What must still pass.
gha "${ST_W}" subtree split -P lib
rc_passed "W18. subtree split (local, writes no remote ref) passes"
gha "${W}" -c alias.st=status st
rc_passed "W19. an alias to a builtin (alias.st=status) passes"
gha "${W}" fetch-pack "${O}" refs/heads/main
rc_passed "W20. fetch-pack with no command option (read-only) passes"
gha "${W}" push -q origin HEAD:refs/heads/topic
rc_passed "W21. a routed push to a topic branch still passes"

# Review round. W22: a git-<name> program on PATH that is not git's own runs
# with the bot header in its environment; its own push to main went unjudged.
gated_origin w22
PX="${TMP}/w22-path"; mkdir -p "${PX}"
printf '#!/bin/sh\nexec git push -q origin HEAD:main\n' > "${PX}/git-shipit"; chmod +x "${PX}/git-shipit"
OUT="$(cd "${W}" && PATH="${PX}:${PATH}" ATHENA_TELEMETRY_DIR="${TMP}/w22-store" "${WRAPPER}" git shipit 2>"${TMP}/err")"; RC=$?
ERR="$(cat "${TMP}/err")"
if is_refusal && [[ "${ERR}" == *"program on PATH"* ]] && [ "$(git --git-dir="${O}" rev-parse main)" = "${B}" ]; then
  ok "W22. a git-<name> on PATH (git shipit, which pushes HEAD:main) -> refused, origin main unmoved"
else bad "W22. PATH git-<name> refused" "rc=${RC} err='${ERR}' main=$(git --git-dir="${O}" rev-parse main) base=${B}"; fi
OUT="$(cd "${W}" && PATH="${PX}:${PATH}" GH_ATHENA_GIT_DRY_RUN=1 "${WRAPPER}" git -c alias.si=shipit si 2>"${TMP}/err")"; RC=$?
ERR="$(cat "${TMP}/err")"
if is_refusal && [[ "${ERR}" == *"program on PATH"* ]]; then ok "W23. an alias to that program -> refused"
else bad "W23. alias to PATH program refused" "rc=${RC} out='${OUT}' err='${ERR}'"; fi

# W24: an alias chain 11 deep stopped the walk at 10 and ran unjudged.
CH=(); for i in 0 1 2 3 4 5 6 7 8 9; do CH+=(-c "alias.a${i}=a$((i + 1))"); done
ghpush "${W}" "${TMP}/w22-store" "${CH[@]}" -c 'alias.a10=push -q origin HEAD:main' a0
if is_refusal && [[ "${ERR}" == *"more than 10 aliases deep"* ]] && [ "$(git --git-dir="${O}" rev-parse main)" = "${B}" ]; then
  ok "W24. an 11-deep alias chain ending in push HEAD:main -> refused, origin main unmoved"
else bad "W24. deep alias chain refused" "rc=${RC} err='${ERR}' main=$(git --git-dir="${O}" rev-parse main) base=${B}"; fi
CH=(); for i in 0 1 2 3 4 5 6 7 8; do CH+=(-c "alias.a${i}=a$((i + 1))"); done
gha "${W}" "${CH[@]}" -c 'alias.a9=status' a0
rc_passed "W25. a 10-deep alias chain ending in status passes"

# W26: a command list git cannot give is COULD NOT LOOK, never "no command".
SHIM3="${TMP}/shim3"; mkdir -p "${SHIM3}"
printf '#!/bin/sh\nfor a in "$@"; do case "$a" in --list-cmds=*) exit 1 ;; esac; done\nexec %s "$@"\n' "${REALGIT}" > "${SHIM3}/git"
chmod +x "${SHIM3}/git"; fsg_require_stubs "${SHIM3}" git
OUT="$(cd "${W}" && PATH="${SHIM3}:${FSG_DIR}:${PATH}" GH_ATHENA_GIT_DRY_RUN=1 "${WRAPPER}" git status 2>"${TMP}/err")"; RC=$?
ERR="$(cat "${TMP}/err")"
if is_refusal && [[ "${ERR}" == *"COULD NOT LOOK"* ]] && [[ "${OUT}" != *"dry-run: exec git"* ]]; then
  ok "W26. git --list-cmds failing -> refused as COULD NOT LOOK (not read as an empty list)"
else bad "W26. list-cmds failure refused" "rc=${RC} out='${OUT}' err='${ERR}'"; fi

# Critic round: the LAST name of each command list never matched, since a
# command substitution strips the list's trailing newline.
LAST_OWN="$(git --list-cmds=main | tail -n 1)"
gha "${W}" "${LAST_OWN}" -h
if [ "${RC}" = 0 ] && [[ "${OUT}" == *"dry-run: exec git"* ]]; then
  ok "W27. git's last-listed own command (${LAST_OWN}) passes as git's own"
else bad "W27. last own command passes" "rc=${RC} out='${OUT}' err='${ERR}'"; fi
printf '#!/bin/sh\nexec git push -q origin HEAD:main\n' > "${PX}/git-zzzz-last"; chmod +x "${PX}/git-zzzz-last"
LAST_PATH="$(PATH="${PX}:${PATH}" git --list-cmds=others | tail -n 1)"
OUT="$(cd "${W}" && PATH="${PX}:${PATH}" GH_ATHENA_GIT_DRY_RUN=1 "${WRAPPER}" git -c alias.zzzz-last=status zzzz-last 2>"${TMP}/err")"; RC=$?
ERR="$(cat "${TMP}/err")"
if [ "${LAST_PATH}" = zzzz-last ] && is_refusal && [[ "${ERR}" == *"program on PATH"* ]]; then
  ok "W28. the last-listed PATH program (git-zzzz-last), shadowing alias.zzzz-last=status -> refused"
else bad "W28. last PATH program refused" "last='${LAST_PATH}' rc=${RC} out='${OUT}' err='${ERR}'"; fi

echo
echo "--- DND-1868: the bot credential reaches only the forge transport ---"
# A command git starts itself (a hook, a config or environment command, a
# config-defined hook) ran with the bot's header in its environment, and a push
# it made was judged by nothing. Now the header reaches only the route's
# transport, git-remote-athena-forge, through a one-shot pipe that it drains
# before any caller-chosen command starts.
#
# NO NETWORK. Every git here goes through a shim that runs the real git with
# --exec-path=<a copy of git's exec-path> whose git-remote-https is a FIXTURE:
# it records its start, maps https://github.com/<o>/<r> to a local bare repo
# under X_FORGE, and speaks the remote-helper `connect` capability.
X="${TMP}/x1868"; mkdir -p "${X}/bin" "${X}/shim" "${X}/exec"
export X_REAL_GIT="$(git --exec-path)/git" X_EXEC="${X}/exec" X_FORGE="${X}/forge"
export X_STUB_LOG="${X}/stub.log" X_PROBE_LOG="${X}/probe.log" X_B64="${B64}" X_USER=x-access-token
for f in "$(git --exec-path)"/*; do ln -s "${f}" "${X_EXEC}/${f##*/}"; done
rm -f "${X_EXEC}/git-remote-https"
cat > "${X_EXEC}/git-remote-https" <<'EOF'
#!/usr/bin/env bash
# fixture git-remote-https (DND-1868): no network.
url="${2:-$1}"; hdr=none; gpg=""; via=direct; i=0
while [ "${i}" -lt "${GIT_CONFIG_COUNT:-0}" ]; do
  k="GIT_CONFIG_KEY_${i}"; v="GIT_CONFIG_VALUE_${i}"
  case "${!k}" in
    http.https://*/.extraheader)
      dec="$(printf '%s' "${!v#AUTHORIZATION: basic }" | openssl base64 -d -A 2>/dev/null)"
      if [ "${!v}" = "AUTHORIZATION: basic ${X_B64}" ]; then hdr="ok:${dec%%:*}"; else hdr="wrong:${dec%%:*}"; fi ;;
  esac
  i=$((i + 1))
done
case "${GIT_CONFIG_PARAMETERS:-}" in *refuse-signing*) via=transport ;; esac
for k in gpg.program gpg.openpgp.program gpg.x509.program gpg.ssh.program; do gpg="${gpg}${k}=$(git config --get "${k}" | sed 's|.*/||'),"; done
eff="gpg:$(git config --get gpg.program | sed 's|.*/||'),helper:$(git config --get-all credential.helper | tail -n 1 | sed 's|.*/||'),askpass:$(git config --get core.askPass | sed 's|.*/||')"
printf 'start via=%s url=%s hdr=%s gpg=%s eff=%s argv=%s\n' "${via}" "${url}" "${hdr}" "${gpg}" "${eff}" "$*" >> "${X_STUB_LOG}"
repo="${X_FORGE}/${url#https://*/}"
while IFS= read -r line; do
  case "${line}" in
    capabilities) printf 'connect\n\n' ;;
    "connect "*) printf '\n'; exec env -u GIT_DIR git "${line#connect git-}" "${repo}" ;;
    '') exit 0 ;;
    *) exit 1 ;;
  esac
done
EOF
chmod +x "${X_EXEC}/git-remote-https"
printf '#!/bin/sh\nexec "$X_REAL_GIT" --exec-path="$X_EXEC" "$@"\n' > "${X}/shim/git"; chmod +x "${X}/shim/git"
fsg_require_stubs "${X}/shim" git
# The probe every caller-chosen command runs: is the header in its
# environment, does it hold the grant, can it start the transport itself, and
# does a plain push it makes land on o/r2?
cat > "${X}/probe" <<'EOF'
#!/usr/bin/env bash
tag="$1"
case "${tag}" in c1) cat ;; esac
[ -n "${X_PROBE_NESTED:-}" ] && exit 0
export X_PROBE_NESTED=1
hdr=absent; i=0
while [ "${i}" -lt "${GIT_CONFIG_COUNT:-0}" ]; do
  k="GIT_CONFIG_KEY_${i}"; case "${!k}" in *extraheader*) hdr=present ;; esac; i=$((i + 1))
done
case "${GIT_CONFIG_PARAMETERS:-}" in *extraheader*) hdr=present ;; esac
fd="${ATHENA_FG_CRED_FD:-}"; fds=nofd
[ -n "${fd}" ] && { if [ -p "/proc/self/fd/${fd}" ]; then fds=pipe; else fds=closed; fi; }
if command -v git-remote-athena-forge >/dev/null 2>&1; then
  out="$(git-remote-athena-forge origin https://github.com/o/r2.git </dev/null 2>&1)"; rc=$?
  tr=refused; [[ "${out}" == *"already used"* ]] && tr=already-used; [ "${rc}" = 0 ] && tr=RAN
else tr=absent; fi
git -C "${X_FORGE}/../src" push -q https://github.com/o/r2.git "HEAD:refs/heads/${tag}" </dev/null >/dev/null 2>&1
printf '%s hdr=%s fd=%s transport=%s\n' "${tag}" "${hdr}" "${fds}" "${tr}" >> "${X_PROBE_LOG}"
exit 0
EOF
chmod +x "${X}/probe"
# mkprobe <tag> : a command for a config or environment value, args ignored.
mkprobe() { printf '#!/bin/sh\nexec %s %s "$@"\n' "${X}/probe" "$1" > "${X}/bin/p-$1"; chmod +x "${X}/bin/p-$1"; printf '%s' "${X}/bin/p-$1"; }
XPATH="${X}/shim:${FSG_DIR}:${PATH}"
export GIT_ALLOW_PROTOCOL=file:athena-forge:https
# xgh <dir> <git args...> : a REAL run of the route, through the shim.
xgh() {
  local d="$1"; shift
  OUT="$(cd "${d}" && PATH="${XPATH}" "${WRAPPER}" git "$@" 2>"${TMP}/err")"; RC=$?
  ERR="$(cat "${TMP}/err")"
}
# xdry <dir> <git args...> : the dry-run seam, through the shim.
xdry() {
  local d="$1"; shift
  OUT="$(cd "${d}" && PATH="${XPATH}" GH_ATHENA_GIT_DRY_RUN=1 "${WRAPPER}" git "$@" 2>"${TMP}/err")"; RC=$?
  ERR="$(cat "${TMP}/err")"
}
x_reset() { : > "${X_STUB_LOG}"; : > "${X_PROBE_LOG}"; rm -rf "${X_FORGE}/o/r2.git"; git init -q --bare "${X_FORGE}/o/r2.git"; }
# x_sync : src at the fixture forge's main, so its next push fast-forwards.
x_sync() { git -C "${X}/src" fetch -q "${X_FORGE}/o/r.git" main && git -C "${X}/src" reset -q --hard FETCH_HEAD; }
x_starts() { local n; n="$(grep -c '^start via=transport ' "${X_STUB_LOG}")"; printf '%s' "${n:-0}"; }
# probe_clean <tag> : the probe ran, saw no header, found the grant used, and
# its plain push landed nothing; the stub saw exactly one transport start.
probe_clean() {
  local lines
  lines="$(grep "^$1 " "${X_PROBE_LOG}")"
  [ -n "${lines}" ] && [[ "${lines}" != *"hdr=present"* ]] && [[ "${lines}" != *"transport=RAN"* ]] \
    && [[ "${lines}" != *"transport=refused"* ]] && [[ "${lines}" != *"transport=absent"* ]] \
    && [ -z "$(git --git-dir="${X_FORGE}/o/r2.git" for-each-ref)" ] && [ "$(x_starts)" = 1 ]
}
# probe_nofd <tag> : the probe ran with no header and no grant at all.
probe_nofd() {
  local lines
  lines="$(grep "^$1 " "${X_PROBE_LOG}")"
  [ -n "${lines}" ] && [[ "${lines}" != *"hdr=present"* ]] && [[ "${lines}" != *"fd=pipe"* ]] && [[ "${lines}" != *"fd=closed"* ]]
}
xdiag() { printf 'rc=%s out=%s err=%s probe=[%s] stub=[%s]' "${RC}" "${OUT}" "${ERR}" "$(cat "${X_PROBE_LOG}")" "$(cat "${X_STUB_LOG}")"; }

# The fixture forge: o/r (pushes land here), o/r2 (a probe's push must not).
mkdir -p "${X_FORGE}/o"
git init -q --bare -b main "${X_FORGE}/o/r.git"
git init -q -b main "${X}/src" && git -C "${X}/src" commit -q --allow-empty -m s0
git -C "${X}/src" push -q "${X_FORGE}/o/r.git" main
git -C "${X}/src" remote add origin 'git@github.com:o/r.git'
x_reset

# P1. A normal routed push lands, as the bot, with the token on no argv and in no file.
git -C "${X}/src" commit -q --allow-empty -m p1
S="${X}/p1-store"
OUT="$(cd "${X}/src" && PATH="${XPATH}" ATHENA_TELEMETRY_DIR="${S}" "${WRAPPER}" git push -q origin HEAD:main 2>"${TMP}/err")"; RC=$?
ERR="$(cat "${TMP}/err")"
if [ "${RC}" = 0 ] && [ "$(git --git-dir="${X_FORGE}/o/r.git" rev-parse main)" = "$(git -C "${X}/src" rev-parse HEAD)" ] \
  && grep -q '^start via=transport url=https://github.com/o/r.git hdr=ok:x-access-token ' "${X_STUB_LOG}" \
  && [ "$(x_starts)" = 1 ] && ! grep -qF "${FAKE_TOKEN}" "${X_STUB_LOG}" \
  && [ -z "$(grep -rlF -e "${FAKE_TOKEN}" -e "${B64}" "${X}" 2>/dev/null)" ] \
  && [ "$(landed_n "${S}")" = 1 ]; then
  ok "P1. a routed push lands on o/r: one transport start with the x-access-token header, token on no argv and in no file, merge.landed emitted"
else bad "P1. routed push through the transport" "$(xdiag) landed=$(landed_n "${S}")"; fi

# P2. Routed fetch, clone, ls-remote and pull each succeed, one grant each.
git -C "${X}/src" remote set-url origin 'https://github.com/o/r.git'
p2() { # <label> <dir> <git args...>
  local l="$1" d="$2"; shift 2
  : > "${X_STUB_LOG}"; xgh "${d}" "$@"
  if [ "${RC}" = 0 ] && [ "$(x_starts)" = 1 ] && grep -q 'hdr=ok:x-access-token' "${X_STUB_LOG}"; then ok "P2. routed ${l}: succeeds, the transport saw the header exactly once"
  else bad "P2. routed ${l}" "$(xdiag)"; fi
}
p2 fetch "${X}/src" fetch -q origin
p2 ls-remote "${X}/src" ls-remote origin
p2 clone "${X}" clone -q https://github.com/o/r.git "${X}/p2-clone"
git -C "${X}/src" push -q "${X_FORGE}/o/r.git" "$(git -C "${X}/src" commit-tree -p HEAD -m p2 "$(git -C "${X}/src" rev-parse 'HEAD^{tree}')"):refs/heads/main"
p2 pull "${X}/p2-clone" pull -q --ff-only

# H1. A pre-push hook in the repository.
x_reset; x_sync; git -C "${X}/src" commit -q --allow-empty -m h1
printf '#!/bin/sh\nexec %s h1\n' "${X}/probe" > "${X}/src/.git/hooks/pre-push"; chmod +x "${X}/src/.git/hooks/pre-push"
xgh "${X}/src" push -q origin HEAD:main
if [ "${RC}" = 0 ] && [ "$(git --git-dir="${X_FORGE}/o/r.git" rev-parse main)" = "$(git -C "${X}/src" rev-parse HEAD)" ] && probe_clean h1; then
  ok "H1. a pre-push hook: the push lands; the hook gets no header and finds the grant used"
else bad "H1. pre-push hook" "$(xdiag)"; fi
rm -f "${X}/src/.git/hooks/pre-push"

# H2. core.hooksPath, from -c and from the repository's config.
x_reset; mkdir -p "${X}/hp"; printf '#!/bin/sh\nexec %s h2\n' "${X}/probe" > "${X}/hp/pre-push"; chmod +x "${X}/hp/pre-push"
x_sync; git -C "${X}/src" commit -q --allow-empty -m h2
xgh "${X}/src" -c core.hooksPath="${X}/hp" push -q origin HEAD:main
H2A=0; [ "${RC}" = 0 ] && probe_clean h2 && H2A=1
x_reset; git -C "${X}/src" config core.hooksPath "${X}/hp"; x_sync; git -C "${X}/src" commit -q --allow-empty -m h2b
xgh "${X}/src" push -q origin HEAD:main
git -C "${X}/src" config --unset core.hooksPath
if [ "${H2A}" = 1 ] && [ "${RC}" = 0 ] && probe_clean h2; then
  ok "H2. core.hooksPath (-c and repository config): the hook gets no header and finds the grant used"
else bad "H2. core.hooksPath" "h2a=${H2A} $(xdiag)"; fi

# H3. A config-defined hook on pre-push (git 2.54 hook.<name>.*).
x_reset; x_sync; git -C "${X}/src" commit -q --allow-empty -m h3
xgh "${X}/src" -c hook.probe.command="$(mkprobe h3)" -c hook.probe.event=pre-push push -q origin HEAD:main
if [ "${RC}" = 0 ] && probe_clean h3; then ok "H3. hook.<name>.command on pre-push: no header, grant used"
else bad "H3. config-defined pre-push hook" "$(xdiag)"; fi

# H4. A config-defined hook on reference-transaction, during a routed fetch.
x_reset
xgh "${X}/src" -c hook.probe.command="$(mkprobe h4)" -c hook.probe.event=reference-transaction fetch -q origin
if [ "${RC}" = 0 ] && probe_clean h4; then ok "H4. hook.<name>.command on reference-transaction in a fetch: no header, grant used"
else bad "H4. config-defined reference-transaction hook" "$(xdiag)"; fi

# C1. A smudge filter during a routed clone.
git init -q -b main "${X}/fsrc" && printf '* filter=p\n' > "${X}/fsrc/.gitattributes" && printf 'x\n' > "${X}/fsrc/f"
git -C "${X}/fsrc" add -A && git -C "${X}/fsrc" commit -q -m f
git init -q --bare -b main "${X_FORGE}/o/f.git"; git -C "${X}/fsrc" push -q "${X_FORGE}/o/f.git" main
x_reset
xgh "${X}" -c filter.p.smudge="$(mkprobe c1)" clone -q https://github.com/o/f.git "${X}/c1-clone"
if [ "${RC}" = 0 ] && [ -f "${X}/c1-clone/f" ] && probe_clean c1; then ok "C1. a smudge filter in a routed clone: the clone succeeds; the filter gets no header, grant used"
else bad "C1. smudge filter" "$(xdiag)"; fi

# C2. remote.<n>.receivepack / uploadpack on a local-path remote: no credential.
git init -q --bare -b main "${X}/local.git"
git -C "${X}/src" remote add lo "${X}/local.git"
git -C "${X}/src" config remote.lo.receivepack "$(mkprobe c2); exec git-receive-pack"
git -C "${X}/src" config remote.lo.uploadpack "$(mkprobe c2u); exec git-upload-pack"
xdry "${X}/src" push lo HEAD:main; C2D="${OUT}"
x_reset; xgh "${X}/src" push -q lo HEAD:main; xgh "${X}/src" fetch -q lo
if [[ "${C2D}" == *"cred: none"* ]] && probe_nofd c2 && probe_nofd c2u; then
  ok "C2. receivepack / uploadpack on a local remote: cred: none; the commands get no grant and no header"
else bad "C2. receivepack / uploadpack" "dry='${C2D}' $(xdiag)"; fi

# C3. remote.<n>.vcs names another transport helper: no credential.
git -C "${X}/src" config remote.origin.vcs probe
printf '#!/bin/sh\nexec %s c3\n' "${X}/probe" > "${X}/bin/git-remote-probe"; chmod +x "${X}/bin/git-remote-probe"
OUT="$(cd "${X}/src" && PATH="${X}/bin:${XPATH}" GH_ATHENA_GIT_DRY_RUN=1 "${WRAPPER}" git fetch origin 2>"${TMP}/err")"; RC=$?; C3D="${OUT}"
x_reset; ( cd "${X}/src" && PATH="${X}/bin:${XPATH}" GIT_ALLOW_PROTOCOL=file:athena-forge:https:probe "${WRAPPER}" git fetch -q origin ) >/dev/null 2>&1
git -C "${X}/src" config --unset remote.origin.vcs
if [[ "${C3D}" == *"cred: none"* ]] && [ "$(x_starts)" = 0 ] && ! grep -q '^c3 .*\(hdr=present\|fd=pipe\|fd=closed\)' "${X_PROBE_LOG}"; then
  ok "C3. remote.<n>.vcs: cred: none; nothing it starts gets a grant or a header, and no credentialed connection is made"
else bad "C3. remote vcs helper" "dry='${C3D}' $(xdiag)"; fi

# C4 / E2. core.sshCommand and GIT_SSH_COMMAND to another host: no credential.
git -C "${X}/src" remote add other 'ssh://other.invalid/r.git'
xdry "${X}/src" -c core.sshCommand="$(mkprobe c4)" fetch other; C4D="${OUT}"
x_reset
( cd "${X}/src" && unset GIT_SSH_COMMAND && PATH="${XPATH}" GIT_ALLOW_PROTOCOL=file:athena-forge:https:ssh \
    "${WRAPPER}" git -c core.sshCommand="$(mkprobe c4)" fetch -q other ) >/dev/null 2>&1
( cd "${X}/src" && PATH="${XPATH}" GIT_ALLOW_PROTOCOL=file:athena-forge:https:ssh GIT_SSH_COMMAND="$(mkprobe e2)" \
    "${WRAPPER}" git fetch -q other ) >/dev/null 2>&1
if [[ "${C4D}" == *"cred: none"* ]] && probe_nofd c4 && probe_nofd e2; then
  ok "C4/E2. core.sshCommand and GIT_SSH_COMMAND to another host: cred: none; no grant, no header"
else bad "C4/E2. ssh command" "dry='${C4D}' $(xdiag)"; fi

# C5. A pager: never started under the route; -p is refused.
xdry "${X}/src" -c pager.push="$(mkprobe c5)" push origin HEAD:main
C5D="${OUT}"
xdry "${X}/src" -p push origin HEAD:main
if [[ "${C5D}" == *"dry-run: exec git [--no-pager]"* ]] && is_refusal && [[ "${ERR}" == *"-p"* ]]; then
  ok "C5. git's argv starts --no-pager; \`-p push\` is refused (exit 3, Fix:)"
else bad "C5. pager" "dry='${C5D}' rc=${RC} err='${ERR}'"; fi

# C6. gpg.program on a signed push: the probe gets nothing; the transport
# subtree's signing programs are refuse-signing.
git -C "${X_FORGE}/o/r.git" config receive.certNonceSeed synthetic-seed
x_reset; x_sync; git -C "${X}/src" commit -q --allow-empty -m c6
xgh "${X}/src" -c gpg.program="$(mkprobe c6)" -c user.signingKey=synthetic push --signed -q origin HEAD:main
if probe_clean c6 && grep -q 'gpg=gpg.program=refuse-signing,gpg.openpgp.program=refuse-signing,gpg.x509.program=refuse-signing,gpg.ssh.program=refuse-signing,' "${X_STUB_LOG}"; then
  ok "C6. a signed push: gpg.program gets no header and finds the grant used; the transport's four signing programs are refuse-signing"
else bad "C6. signed push" "$(xdiag)"; fi

# C6b (critic round). A caller's own -c beats the environment config
# channel, and reaches the transport's subtree through GIT_CONFIG_PARAMETERS:
# gpg.program, credential.helper and core.askPass set by the caller must not
# be what git uses where the header is.
x_reset; x_sync; git -C "${X}/src" commit -q --allow-empty -m c6b
xgh "${X}/src" -c gpg.program="$(mkprobe c6b)" -c credential.helper="$(mkprobe c6h)" -c core.askPass="$(mkprobe c6a)" push -q origin HEAD:main
if [ "${RC}" = 0 ] && grep -q '^start via=transport .* eff=gpg:refuse-signing,helper:,askpass: ' "${X_STUB_LOG}"; then
  ok "C6b. a caller's -c gpg.program / credential.helper / core.askPass: inside the transport git uses refuse-signing, no helper and no askpass"
else bad "C6b. caller -c inside the transport" "$(xdiag)"; fi

# C7. A caller-written athena-forge:: rewrite to another host.
xdry "${X}/src" -c 'url.athena-forge::https://evil.invalid/.insteadOf=https://github.com/o/' push origin HEAD:main
C7R=0; is_refusal && C7R=1
exec {XFD}< <(printf '%s\n%s\n' /bin/false 'AUTHORIZATION: basic eDp5')
TOUT="$(ATHENA_FG_HOST=github.com ATHENA_FG_CRED_FD="${XFD}" "${AI_DIR}/lib/forge-transport/git-remote-athena-forge" origin https://evil.invalid/r.git </dev/null 2>&1)"; TRC=$?
IFS= read -r -t 5 LEFT <&"${XFD}"; exec {XFD}<&-
if [ "${C7R}" = 1 ] && [ "${TRC}" != 0 ] && [[ "${TOUT}" == *"Fix:"* ]] && [[ "${TOUT}" == *"evil.invalid"* ]] && [ "${LEFT}" = /bin/false ]; then
  ok "C7. an athena-forge:: URL to another host: refused up front; the transport refuses it before reading the grant"
else bad "C7. foreign athena-forge URL" "c7r=${C7R} trc=${TRC} tout='${TOUT}' left='${LEFT}' err='${ERR}'"; fi

# C8. A pushInsteadOf that turns the forge into plain https.
git -C "${X}/src" remote set-url origin 'git@github.com:o/r.git'
xdry "${X}/src" -c 'url.https://github.com/.pushInsteadOf=git@github.com:' push origin HEAD:main
if is_refusal && [[ "${ERR}" == *"pushInsteadOf"* ]]; then ok "C8. a pushInsteadOf to plain https://github.com/: refused up front (exit 3, Fix:)"
else bad "C8. pushInsteadOf to https" "rc=${RC} out='${OUT}' err='${ERR}'"; fi
git -C "${X}/src" remote set-url origin 'https://github.com/o/r.git'

# E1. GIT_TEMPLATE_DIR with a post-checkout hook during a routed clone.
mkdir -p "${X}/tpl/hooks"; printf '#!/bin/sh\nexec %s e1\n' "${X}/probe" > "${X}/tpl/hooks/post-checkout"; chmod +x "${X}/tpl/hooks/post-checkout"
x_reset
OUT="$(cd "${X}" && PATH="${XPATH}" GIT_TEMPLATE_DIR="${X}/tpl" "${WRAPPER}" git clone -q https://github.com/o/r.git "${X}/e1-clone" 2>"${TMP}/err")"; RC=$?; ERR="$(cat "${TMP}/err")"
if [ "${RC}" = 0 ] && probe_clean e1; then ok "E1. GIT_TEMPLATE_DIR post-checkout in a routed clone: the clone succeeds; no header, grant used"
else bad "E1. template dir hook" "$(xdiag)"; fi

# E3. GIT_EDITOR during a routed pull that merges.
git clone -q "${X_FORGE}/o/r.git" "${X}/e3" && git -C "${X}/e3" remote set-url origin https://github.com/o/r.git
git -C "${X}/e3" commit -q --allow-empty -m e3-local
git -C "${X}/src" fetch -q "${X_FORGE}/o/r.git" main && git -C "${X}/src" reset -q --hard FETCH_HEAD
git -C "${X}/src" commit -q --allow-empty -m e3-remote && git -C "${X}/src" push -q "${X_FORGE}/o/r.git" HEAD:main
x_reset
OUT="$(cd "${X}/e3" && PATH="${XPATH}" GIT_EDITOR="$(mkprobe e3)" "${WRAPPER}" git pull -q --no-rebase --no-ff --edit origin main 2>"${TMP}/err")"; RC=$?; ERR="$(cat "${TMP}/err")"
if [ "${RC}" = 0 ] && grep -q 'hdr=ok:x-access-token' "${X_STUB_LOG}" && probe_clean e3; then
  ok "E3. GIT_EDITOR in a routed pull --edit: the pull merges; the editor gets no header, grant used"
else bad "E3. editor in pull" "$(xdiag)"; fi

# M1. More than one URL that needs the credential: refused up front.
git -C "${X}/src" remote add second 'https://github.com/o/r2.git'
xdry "${X}/src" fetch --all
M1A=0; is_refusal && [[ "${ERR}" == *"one"* ]] && M1A=1
git -C "${X}/src" remote remove second
git -C "${X}/src" config --add remote.origin.pushurl 'https://github.com/o/r.git'
git -C "${X}/src" config --add remote.origin.pushurl 'https://github.com/o/r2.git'
xdry "${X}/src" push origin HEAD:main
git -C "${X}/src" config --unset-all remote.origin.pushurl
if [ "${M1A}" = 1 ] && is_refusal; then ok "M1. fetch --all over two forge remotes, and two forge pushurls: refused up front (exit 3, Fix:)"
else bad "M1. multiple forge URLs" "m1a=${M1A} rc=${RC} err='${ERR}'"; fi

# M2. A submodule fetch nested under a routed pull: the top-level fetch gets
# the grant; the nested transport finds it used, and says which URL.
git init -q -b main "${X}/subsrc" && git -C "${X}/subsrc" commit -q --allow-empty -m sub0
git init -q --bare -b main "${X_FORGE}/o/sub.git" && git -C "${X}/subsrc" push -q "${X_FORGE}/o/sub.git" main
git init -q -b main "${X}/spsrc" && git -C "${X}/spsrc" -c protocol.file.allow=always submodule add -q "${X_FORGE}/o/sub.git" sub >/dev/null 2>&1
git -C "${X}/spsrc" config -f .gitmodules submodule.sub.url ../sub.git && git -C "${X}/spsrc" add .gitmodules && git -C "${X}/spsrc" commit -q -m sp0
git init -q --bare -b main "${X_FORGE}/o/sp.git" && git -C "${X}/spsrc" push -q "${X_FORGE}/o/sp.git" main
git -C "${X}/spsrc" remote add origin https://github.com/o/sp.git && git -C "${X}/spsrc" config submodule.sub.url ../sub.git
git -C "${X}/spsrc" fetch -q "${X_FORGE}/o/sp.git" main && git -C "${X}/spsrc" update-ref refs/remotes/origin/main FETCH_HEAD
git -C "${X}/spsrc" branch -q -u origin/main main
git -C "${X}/spsrc/sub" remote set-url origin https://github.com/o/sub.git
git -C "${X}/spsrc" commit -q --allow-empty -m sp1 && git -C "${X}/spsrc" push -q "${X_FORGE}/o/sp.git" main
git -C "${X}/spsrc" reset -q --hard HEAD~1
x_reset
xgh "${X}/spsrc" pull -q --ff-only --recurse-submodules
if [ "$(git -C "${X}/spsrc" rev-parse refs/remotes/origin/main)" = "$(git --git-dir="${X_FORGE}/o/sp.git" rev-parse main)" ] \
  && [[ "${ERR}" == *"already used"* ]] && [[ "${ERR}" == *"https://github.com/o/sub.git"* ]] && [ "$(x_starts)" = 1 ]; then
  ok "M2. pull --recurse-submodules: the top-level fetch updates origin/main; the nested submodule transport fails loudly, naming its URL"
else bad "M2. nested submodule fetch" "$(xdiag) head=$(git -C "${X}/spsrc" rev-parse HEAD)"; fi

# P3. The outbound pre-push scan keeps running, and keeps blocking: a
# dispatcher of the shape of ~/dev/custom/.git/hooks/pre-push execs a scan
# that refuses a pushed commit carrying a synthetic pattern and marks each run.
cat > "${X}/scan" <<'EOF'
#!/usr/bin/env bash
printf 'ran\n' >> "${X_PROBE_LOG}.scan"
while read -r _lref lsha _rref _rsha; do
  if git log --format=%B "${lsha}" -1 | grep -q SYNTHETIC-WORK-VALUE; then
    printf 'outbound-pre-push: REFUSED: a work-domain value. Fix: remove it.\n' >&2; exit 3
  fi
done
exit 0
EOF
chmod +x "${X}/scan"
printf '#!/bin/sh\nexec %s "$@"\n' "${X}/scan" > "${X}/src/.git/hooks/pre-push"; chmod +x "${X}/src/.git/hooks/pre-push"
git -C "${X}/src" fetch -q "${X_FORGE}/o/r.git" main && git -C "${X}/src" reset -q --hard FETCH_HEAD
BEFORE3="$(git --git-dir="${X_FORGE}/o/r.git" rev-parse main)"
git -C "${X}/src" commit -q --allow-empty -m 'carries SYNTHETIC-WORK-VALUE'
x_reset; rm -f "${X_PROBE_LOG}.scan"
xgh "${X}/src" push -q origin HEAD:main; P3A_RC="${RC}"; P3A_MAIN="$(git --git-dir="${X_FORGE}/o/r.git" rev-parse main)"
git -C "${X}/src" reset -q --hard HEAD~1 && git -C "${X}/src" commit -q --allow-empty -m clean
xgh "${X}/src" push -q origin HEAD:main
if [ "${P3A_RC}" != 0 ] && [ "${P3A_MAIN}" = "${BEFORE3}" ] && [ "${RC}" = 0 ] \
  && [ "$(git --git-dir="${X_FORGE}/o/r.git" rev-parse main)" = "$(git -C "${X}/src" rev-parse HEAD)" ] \
  && [ "$(grep -c ran "${X_PROBE_LOG}.scan")" = 2 ]; then
  ok "P3. the outbound pre-push scan runs on every routed push: a commit with the pattern is refused and lands nothing; a clean one lands"
else bad "P3. outbound scan" "a_rc=${P3A_RC} a_main=${P3A_MAIN} before=${BEFORE3} $(xdiag) scan=$(cat "${X_PROBE_LOG}.scan" 2>/dev/null)"; fi
rm -f "${X}/src/.git/hooks/pre-push"

# X1. Every miss of the transport is loud: no grant, a grant that is no pipe,
# a grant already used. Three distinct messages, each with Fix: and the URL.
TR="${AI_DIR}/lib/forge-transport/git-remote-athena-forge"
X1A="$(env -u ATHENA_FG_CRED_FD ATHENA_FG_HOST=github.com "${TR}" origin https://github.com/o/r.git </dev/null 2>&1)"; X1A_RC=$?
X1B="$(ATHENA_FG_HOST=github.com ATHENA_FG_CRED_FD=0 "${TR}" origin https://github.com/o/r.git </dev/null 2>&1)"; X1B_RC=$?
exec {XFD}< <(:)
X1C="$(ATHENA_FG_HOST=github.com ATHENA_FG_CRED_FD="${XFD}" "${TR}" origin https://github.com/o/r.git </dev/null 2>&1)"; X1C_RC=$?
exec {XFD}<&-
if [ "${X1A_RC}" != 0 ] && [ "${X1B_RC}" != 0 ] && [ "${X1C_RC}" != 0 ] \
  && [[ "${X1A}" == *"not started by the Athena route"* ]] && [[ "${X1B}" == *"not a pipe"* ]] && [[ "${X1C}" == *"already used"* ]] \
  && [[ "${X1A}${X1B}${X1C}" == *"Fix:"*"Fix:"*"Fix:"* ]] \
  && [[ "${X1A}" == *"https://github.com/o/r.git"* ]] && [[ "${X1B}" == *"https://github.com/o/r.git"* ]] && [[ "${X1C}" == *"https://github.com/o/r.git"* ]]; then
  ok "X1. the transport with no grant, a grant that is no pipe, a used grant: three distinct refusals, each with Fix: and the URL"
else bad "X1. transport misses" "a=[${X1A_RC}:${X1A}] b=[${X1B_RC}:${X1B}] c=[${X1C_RC}:${X1C}]"; fi

# R1 (review round). A command git starts BEFORE the transport would drain
# the grant: core.fsmonitor (fetch, pull) and, on a pull that rebases, the
# post-index-change hook. Measured on git 2.54: each runs before the remote
# helper. A granted command with either is refused up front.
git -C "${X}/src" remote set-url origin 'https://github.com/o/r.git'
never_granted() { # <tag> : no line for <tag> saw a header, a grant pipe, or ran the transport
  ! grep -q "^$1 .*\\(hdr=present\\|fd=pipe\\|transport=RAN\\)" "${X_PROBE_LOG}"
}
x_reset
xgh "${X}/src" -c core.fsmonitor="$(mkprobe r1a)" fetch -q origin
R1A=0; is_refusal && [[ "${ERR}" == *"core.fsmonitor"* ]] && never_granted r1a && R1A=1
x_reset; git -C "${X}/src" config core.fsmonitor "$(mkprobe r1b)"
xgh "${X}/src" pull -q --no-rebase origin main
git -C "${X}/src" config --unset core.fsmonitor
R1B=0; is_refusal && [[ "${ERR}" == *"core.fsmonitor"* ]] && never_granted r1b && R1B=1
x_reset
xgh "${X}/src" -c core.fsmonitor=false fetch -q origin
R1C=0; [ "${RC}" = 0 ] && [ "$(x_starts)" = 1 ] && R1C=1
if [ "${R1A}" = 1 ] && [ "${R1B}" = 1 ] && [ "${R1C}" = 1 ]; then
  ok "R1. core.fsmonitor naming a command (-c, repository config) on a granted fetch / pull: refused up front, the command never holds the grant; core.fsmonitor=false runs"
else bad "R1. fsmonitor before the transport" "r1a=${R1A} r1b=${R1B} r1c=${R1C} $(xdiag)"; fi

x_reset; x_sync
git -C "${X}/src" config hook.r2.command "$(mkprobe r2)"; git -C "${X}/src" config hook.r2.event post-index-change
touch "${X}/src/.gitattributes-r2"; git -C "${X}/src" add .gitattributes-r2; git -C "${X}/src" commit -q -m r2; touch "${X}/src/.gitattributes-r2"
xgh "${X}/src" pull -q --rebase origin main; R2A_RC="${RC}"; R2A_ERR="${ERR}"
git -C "${X}/src" config pull.rebase true
xgh "${X}/src" pull -q origin main; R2B_RC="${RC}"; R2B_ERR="${ERR}"
git -C "${X}/src" config --unset pull.rebase
git -C "${X}/src" config --unset hook.r2.command; git -C "${X}/src" config --unset hook.r2.event
if [ "${R2A_RC}" = 3 ] && [[ "${R2A_ERR}" == *"rebase"*"Fix:"* ]] && [ "${R2B_RC}" = 3 ] && [[ "${R2B_ERR}" == *"rebase"* ]] && never_granted r2; then
  ok "R2. a granted pull that rebases (--rebase, pull.rebase): refused up front, since its post-index-change hook runs before the transport"
else bad "R2. pull --rebase" "a_rc=${R2A_RC} a_err='${R2A_ERR}' b_rc=${R2B_RC} b_err='${R2B_ERR}' probe=[$(cat "${X_PROBE_LOG}")]"; fi

# R3 (review round). The wrapper's own ls-remote probes around a push carry
# the header: a repository insteadOf must not hand it to a helper of its
# choosing. They run with https as the only allowed protocol.
x_reset; x_sync; git -C "${X}/src" commit -q --allow-empty -m r3
git -C "${X}/src" remote set-url origin 'git@github.com:o/r.git'
git -C "${X}/src" config url.r3::x/.insteadOf https://github.com/
printf '#!/bin/sh\nexec %s r3\n' "${X}/probe" > "${X}/bin/git-remote-r3"; chmod +x "${X}/bin/git-remote-r3"
OUT="$(cd "${X}/src" && PATH="${X}/bin:${XPATH}" GIT_ALLOW_PROTOCOL=file:athena-forge:https:r3 "${WRAPPER}" git push -q origin HEAD:main 2>"${TMP}/err")"; RC=$?; ERR="$(cat "${TMP}/err")"
git -C "${X}/src" config --unset url.r3::x/.insteadOf
git -C "${X}/src" remote set-url origin 'https://github.com/o/r.git'
if [ "${RC}" = 0 ] && [ "$(git --git-dir="${X_FORGE}/o/r.git" rev-parse main)" = "$(git -C "${X}/src" rev-parse HEAD)" ] && never_granted r3; then
  ok "R3. a repository insteadOf to another helper: the push lands; the wrapper's header-carrying probes never reach that helper"
else bad "R3. probe insteadOf" "$(xdiag)"; fi

# X1d (critic round). A grant whose first line is not git's own
# git-remote-https is refused: a forged pipe cannot make the transport run a
# program of its choosing in place of git's helper.
exec {XFD}< <(printf '%s\n%s\n' /bin/true 'AUTHORIZATION: basic eDp5')
X1D="$(ATHENA_FG_HOST=github.com ATHENA_FG_CRED_FD="${XFD}" "${TR}" origin https://github.com/o/r.git </dev/null 2>&1)"; X1D_RC=$?
exec {XFD}<&-
if [ "${X1D_RC}" = 1 ] && [[ "${X1D}" == *"not git's own git-remote-https"* ]] && [[ "${X1D}" == *"Fix:"* ]]; then
  ok "X1d. a grant naming another program than git's own git-remote-https: refused, never run"
else bad "X1d. forged helper path" "rc=${X1D_RC} out='${X1D}'"; fi

# DND-1880. No command under the route sees the bot header in its config.
OUT="$(cd "${X}/src" && PATH="${XPATH}" "${WRAPPER}" git config --get-all http.https://github.com/.extraheader 2>&1)"; RC=$?
if [ "${RC}" = 1 ] && [ -z "${OUT}" ]; then ok "DND-1880. \`gh-athena git config --get-all http.https://github.com/.extraheader\` prints no bot header"
else bad "DND-1880. config read shows the bot header" "rc=${RC} out-has-header=$([[ "${OUT}" == *AUTHORIZATION* ]] && echo yes || echo no)"; fi
export GIT_ALLOW_PROTOCOL=file

# DND-1667: no git call may have fallen through past its shim.
if fsg_verify; then ok "no git call fell through past its shim (DND-1667)"
else bad "no git call fell through past its shim (DND-1667)" "see the forge-stub-guard FAIL above"; fi

echo
echo "==================================================="
printf 'RESULT: %d passed, %d failed\n' "${PASS}" "${FAIL}"
echo "==================================================="
[ "${FAIL}" -eq 0 ] || exit 1
echo "ALL CASES PASS"
exit 0
