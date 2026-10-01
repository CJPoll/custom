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
    && "${WRAPPER}" git config --get-all http.https://github.com/.extraheader \
    && "${WRAPPER}" git hook list reference-transaction ) >"${TMP}/out" 2>>"${TMP}/err"; RC2=$?
if [ "${RC}" = 0 ] && [[ "${OUT}" == *"GIT_CONFIG_KEY_${N}=[http.https://github.com/.extraheader]"* ]] \
  && [ "${RC2}" = 0 ] \
  && [ "$(cat "${TMP}/out")" = "caller-kept"$'\n'"AUTHORIZATION: basic ${B64}"$'\n'"agentstash" ]; then
  ok "18. injected entries (count ${N}) are kept: the header lands at index ${N} and the agent-stash hook stays registered"
else bad "18. append after injected entries" "rc=${RC} rc2=${RC2} n=${N} out='${OUT}' real='$(cat "${TMP}/out")' err='$(cat "${TMP}/err")'"; fi

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
ghpush "${W}" "${S}" push -q origin HEAD:main
EV="$(landed "${S}")"
if [ "${RC}" = 0 ] && [ "$(landed_n "${S}")" = 1 ] \
  && [ "$(jq -cS .attrs <<<"${EV}")" = "$(jq -cnS --arg b "${BEFORE}" --arg a "${AFTER}" '{via:"push",before:$b,after:$a}')" ] \
  && [ "$(jq -r .head <<<"${EV}")" = "${AFTER}" ] && [ "$(jq -r .duration_s <<<"${EV}")" = null ] \
  && [ ! -e "${S}/write-failures" ]; then
  ok "19. a push that moves origin's main: one merge.landed via=push, before/after/head right, no drops"
else bad "19. merge.landed on a main push" "rc=${RC} ev='${EV}' err='${ERR}' failures='$(cat "${S}/write-failures" 2>/dev/null)'"; fi

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
origin_with_main p11; S="${TMP}/p11-store"
OTHER="$(git --git-dir="${O}" commit-tree "$(git --git-dir="${O}" rev-parse main^{tree})" -p "$(git --git-dir="${O}" rev-parse main)" -m other)"
printf '#!/bin/sh\n%s "$@"; rc=$?\nfor a in "$@"; do\n  if [ "$a" = push ]; then %s --git-dir=%s update-ref refs/heads/main %s; fi\ndone\nexit $rc\n' \
  "${REALGIT}" "${REALGIT}" "${O}" "${OTHER}" > "${SHIM2}/git"; chmod +x "${SHIM2}/git"
OUT="$(cd "${W}" && PATH="${SHIM2}:${PATH}" ATHENA_TELEMETRY_DIR="${S}" "${WRAPPER}" git push -q origin HEAD:refs/heads/topic 2>&1)"; RC=$?
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
origin_with_main p10; S="${TMP}/p10-store"
OUT="$(cd "${W}" && PATH="${SHIM}:${PATH}" ATHENA_TELEMETRY_DIR="${S}" "${WRAPPER}" git push -q origin HEAD:refs/heads/topic 2>&1)"; RC=$?
[ "${RC}" = 0 ] && [ "$(landed_n "${S}")" = 0 ] && ok "25c. before unreadable, a push to another branch: no phantom landing" \
  || bad "25c. phantom landing" "rc=${RC} events='$(cat "${S}"/*.jsonl 2>/dev/null)' out='${OUT}'"
OUT="$(cd "${W}" && PATH="${SHIM}:${PATH}" ATHENA_TELEMETRY_DIR="${S}" "${WRAPPER}" git push -q origin HEAD:main 2>&1)"; RC=$?
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
# pass_receipt <work dir> <head> <base> : integration-gate's pass receipt for <head>.
pass_receipt() {
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

# 34. A marker that cannot be read is COULD NOT LOOK, never "no red".
origin_with_main r4
C4="$(git -C "${W}" rev-parse --path-format=absolute --git-common-dir)"
mkdir -p "${C4}/main-health"; printf 'garbage\n' > "${C4}/main-health/red"
gha "${W}" push origin HEAD:main
[ "${RC}" = 3 ] && [[ "${ERR}" == *"COULD NOT LOOK"* ]] && [[ "${ERR}" == *"Fix:"* ]] \
  && ok "34. a malformed marker refuses as COULD NOT LOOK (not read as no red)" \
  || bad "34. malformed marker" "rc=${RC} err='${ERR}'"

echo
echo "==================================================="
printf 'RESULT: %d passed, %d failed\n' "${PASS}" "${FAIL}"
echo "==================================================="
[ "${FAIL}" -eq 0 ] || exit 1
echo "ALL CASES PASS"
exit 0
