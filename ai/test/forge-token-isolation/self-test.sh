#!/usr/bin/env bash
# Self-test for forge CLI token isolation in glab-athena and gh-athena (DND-725).
#
# The defect this pins: glab-athena's normal path checked only that its token
# file was READABLE. An empty or whitespace-only file (or GITLAB_ATHENA_TOKEN_FILE
# pointing at one) exported GITLAB_TOKEN="" and exec'd glab, and glab then fell
# back to its own config and keyring: the OWNER's login. `glab-athena api user`
# answered as cjpoll, so a write meant for athena-amby would have gone out as the
# owner. Measured 2026-09-25 against glab 1.112.0.
#
# The wrappers now:
#   (a) refuse an empty, whitespace or control-character token, with a Fix:,
#       before the CLI ever runs;
#   (b) run the CLI with a fresh, empty, mode-0700 config dir (GLAB_CONFIG_DIR /
#       GH_CONFIG_DIR) so the owner's config and keyring entry are unreachable
#       even if a later bug let an empty token through, and remove that dir on
#       every exit path;
#   (c) scrub every inherited identity/host variable the CLI would read.
#
# NO NETWORK, EVER. HOME is a fixture holding a fake OWNER config for each CLI.
# `glab` and `gh` on PATH are fakes that emulate the CLI's measured lookup order
# (see ai/lib/forge-cli-isolation.sh) and record what they could reach.
#
# Old-vs-new evidence:
#   GLAB_ATHENA_UNDER_TEST=/path/glab-athena GH_ATHENA_UNDER_TEST=/path/gh-athena \
#     bash ai/test/forge-token-isolation/self-test.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AI_DIR="$(cd "${HERE}/../.." && pwd)"
GLAB_WRAPPER="${GLAB_ATHENA_UNDER_TEST:-${AI_DIR}/bin/glab-athena}"
GH_WRAPPER="${GH_ATHENA_UNDER_TEST:-${AI_DIR}/bin/gh-athena}"

TMP="$(mktemp -d)"; trap 'rm -rf "${TMP}"' EXIT
PASS=0; FAIL=0
ok()  { printf '  ok    %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  FAIL  %s\n        %s\n' "$1" "$2"; FAIL=$((FAIL+1)); }

# ---- fixture HOME: the owner's logins live here ------------------------------
FHOME="${TMP}/home"
mkdir -p "${FHOME}/.config/glab-cli" "${FHOME}/.config/gh" "${FHOME}/.claude"
printf 'hosts:\n  gitlab.com:\n    token: glpat-OWNERFIXTURE\n    user: owner\n    use_keyring: "true"\n' \
  > "${FHOME}/.config/glab-cli/config.yml"
printf 'github.com:\n  user: owner\n  oauth_token: gho_OWNERFIXTURE\n' > "${FHOME}/.config/gh/hosts.yml"
ATHENA_PAT="glpat-SELFTESTATHENA0000"
APP_TOKEN="ghs_SELFTESTFAKETOKEN0000"

# ---- fake CLIs ----------------------------------------------------------------
FAKEBIN="${TMP}/fakebin"; mkdir -p "${FAKEBIN}"
REC="${TMP}/rec"
# Fake glab. Lookup order as measured on glab 1.112.0 (DND-725):
#   GITLAB_TOKEN non-empty > GITLAB_ACCESS_TOKEN / OAUTH_TOKEN > the config dir,
#   where the config dir is GLAB_CONFIG_DIR if set, else ~/.config/glab-cli
#   (XDG_CONFIG_HOME alone does NOT hide ~/.config/glab-cli), and a config with
#   a host entry reaches the stored token or the keyring.
cat > "${FAKEBIN}/glab" <<'FAKE'
#!/usr/bin/env bash
cfg="${GLAB_CONFIG_DIR:-${HOME}/.config/glab-cli}"
reach=no; [ -f "${cfg}/config.yml" ] && grep -q OWNERFIXTURE "${cfg}/config.yml" && reach=yes
if [ -n "${GITLAB_TOKEN:-}" ]; then who="token:${GITLAB_TOKEN}"
elif [ -n "${GITLAB_ACCESS_TOKEN:-}${OAUTH_TOKEN:-}" ]; then who=env-other
elif [ "${reach}" = yes ]; then who=owner
else who=none; fi
{
  printf 'invoked=yes\n'
  printf 'who=%s\n' "${who}"
  printf 'owner_reachable=%s\n' "${reach}"
  printf 'cfg=%s\n' "${GLAB_CONFIG_DIR:-<unset>}"
  if [ -n "${GLAB_CONFIG_DIR:-}" ] && [ -d "${GLAB_CONFIG_DIR}" ]; then
    printf 'cfg_mode=%s\n' "$(stat -c %a "${GLAB_CONFIG_DIR}")"
    printf 'cfg_entries=%s\n' "$(find "${GLAB_CONFIG_DIR}" -mindepth 1 | wc -l)"
  fi
  printf 'host=%s\n' "${GITLAB_HOST:-<unset>}"
  printf 'argv=%s\n' "$*"
  printf 'envnames=%s\n' "$(compgen -e | grep -E '^(GITLAB_|GLAB_|GL_|OAUTH_TOKEN$|CI_JOB_TOKEN$)' | grep -vxE 'GITLAB_TOKEN|GITLAB_HOST|GLAB_CONFIG_DIR|GLAB_NO_PROMPT|GLAB_CHECK_UPDATE|GLAB_SKIP_UPDATE_CHECK' | sort | tr '\n' ' ')"
} > "${FAKE_REC}"
[ -n "${FAKE_KILL_PARENT:-}" ] && kill -TERM "${PPID}"
case "${who}" in
  token:*) printf '{"username":"athena-amby","state":"active"}\n' ;;
  owner)   printf '{"username":"owner","state":"active"}\n' ;;
  *)       printf '{"message":"401 Unauthorized"}\n'; exit 1 ;;
esac
exit "${FAKE_RC:-0}"
FAKE
# Fake gh. Lookup order as measured on gh 2.83.2 (DND-725):
#   GH_TOKEN non-empty > GITHUB_TOKEN non-empty > hosts.yml in the config dir,
#   where the config dir is GH_CONFIG_DIR, else $XDG_CONFIG_HOME/gh, else
#   ~/.config/gh. An empty GH_TOKEN falls through (measured: answers as CJPoll).
cat > "${FAKEBIN}/gh" <<'FAKE'
#!/usr/bin/env bash
cfg="${GH_CONFIG_DIR:-${XDG_CONFIG_HOME:-${HOME}/.config}/gh}"
reach=no; [ -f "${cfg}/hosts.yml" ] && grep -q OWNERFIXTURE "${cfg}/hosts.yml" && reach=yes
if [ -n "${GH_TOKEN:-}" ]; then who="token:${GH_TOKEN}"
elif [ -n "${GITHUB_TOKEN:-}" ]; then who=env-other
elif [ "${reach}" = yes ]; then who=owner
else who=none; fi
{
  printf 'invoked=yes\n'
  printf 'who=%s\n' "${who}"
  printf 'owner_reachable=%s\n' "${reach}"
  printf 'cfg=%s\n' "${GH_CONFIG_DIR:-<unset>}"
  if [ -n "${GH_CONFIG_DIR:-}" ] && [ -d "${GH_CONFIG_DIR}" ]; then
    printf 'cfg_mode=%s\n' "$(stat -c %a "${GH_CONFIG_DIR}")"
    printf 'cfg_entries=%s\n' "$(find "${GH_CONFIG_DIR}" -mindepth 1 | wc -l)"
  fi
  printf 'host=%s\n' "${GH_HOST:-<unset>}"
  printf 'repo=%s\n' "${GH_REPO:-<unset>}"
  printf 'argv=%s\n' "$*"
  printf 'envnames=%s\n' "$(compgen -e | grep -E '^(GITHUB_|GH_ENTERPRISE_TOKEN$)' | sort | tr '\n' ' ')"
} > "${FAKE_REC}"
[ -n "${FAKE_KILL_PARENT:-}" ] && kill -TERM "${PPID}"
case "$*" in
  "api /installation/repositories"*) printf 'o/r\n' ;;
  *) printf 'fake-gh ok\n' ;;
esac
exit "${FAKE_RC:-0}"
FAKE
# Fake curl for gh-athena's mint: lists one installation, then issues a token.
# openssl is real (the fixture key below is a real RSA key), so the JWT path runs.
cat > "${FAKEBIN}/curl" <<'FAKE'
#!/usr/bin/env bash
case "$*" in
  *access_tokens*) printf '{"token":"ghs_SELFTESTMINTED0000","expires_at":"2099-01-01T00:00:00Z"}\n' ;;
  *app/installations*) printf '[{"id":42}]\n' ;;
  *) echo "fake curl: unexpected $*" >&2; exit 7 ;;
esac
FAKE
chmod +x "${FAKEBIN}/glab" "${FAKEBIN}/gh" "${FAKEBIN}/curl"

BASE_PATH="${FAKEBIN}:${PATH}"
export FAKE_REC="${REC}"

# rec_get <key> : a value from the fake's record ('' when the fake never ran).
rec_get() { [ -f "${REC}" ] && sed -n "s/^$1=//p" "${REC}" | head -n1; }

# run_glab <env assignments...> -- <glab-athena args...>
run_glab() {
  local envs=()
  while [ "$#" -gt 0 ] && [ "$1" != -- ]; do envs+=("$1"); shift; done
  shift
  rm -f "${REC}"
  OUT="$(cd "${TMP}" && env -i PATH="${BASE_PATH}" HOME="${FHOME}" TMPDIR="${TMPD}" FAKE_REC="${REC}" \
    "${envs[@]}" "${GLAB_WRAPPER}" "$@" 2>"${TMP}/err")"; RC=$?
  ERR="$(cat "${TMP}/err")"
}
run_gh() {
  local envs=()
  while [ "$#" -gt 0 ] && [ "$1" != -- ]; do envs+=("$1"); shift; done
  shift
  rm -f "${REC}"
  OUT="$(cd "${TMP}" && env -i PATH="${BASE_PATH}" HOME="${FHOME}" TMPDIR="${TMPD}" FAKE_REC="${REC}" \
    GH_ATHENA_APP_ID_FILE="${TMP}/app-id" GH_ATHENA_KEY="${TMP}/key.pem" \
    GH_ATHENA_TOKEN_CACHE="${GH_CACHE}" "${envs[@]}" "${GH_WRAPPER}" "$@" 2>"${TMP}/err")"; RC=$?
  ERR="$(cat "${TMP}/err")"
}

# A private TMPDIR so "the per-call dir was removed" is an exact count.
TMPD="${TMP}/tmpdir"; mkdir -p "${TMPD}"
leftovers() { find "${TMPD}" -mindepth 1 -maxdepth 1 | wc -l; }

never_reached_a_user() {
  [ "$(rec_get invoked)" != yes ] && [[ "${OUT}" != *username* ]]
}
is_token_refusal() {
  [ "${RC}" -ne 0 ] && [[ "${ERR}" == *REFUSING* ]] && [[ "${ERR}" == *"Fix:"* ]] \
    && [[ "${ERR}" == *"escalate to your admiral"* ]]
}

echo "forge token isolation self-test (DND-725)"
echo "glab-athena: ${GLAB_WRAPPER}"
echo "gh-athena:   ${GH_WRAPPER}"
echo

echo "--- glab-athena: a token that is not a token is REFUSED before glab runs ---"
: > "${FHOME}/.claude/gitlab-athena-token"; chmod 600 "${FHOME}/.claude/gitlab-athena-token"
run_glab -- api user
is_token_refusal && never_reached_a_user && [[ "${ERR}" == *empty* ]] \
  && ok "1. empty default token file -> refused (Fix:), glab never runs, no user resolved" \
  || bad "1. empty default token file refused" "rc=${RC} who=$(rec_get who) out='${OUT}' err='${ERR}'"

printf '  \n\t \n' > "${FHOME}/.claude/gitlab-athena-token"
run_glab -- api user
is_token_refusal && never_reached_a_user \
  && ok "2. whitespace-only default token file -> refused, glab never runs" \
  || bad "2. whitespace-only token file refused" "rc=${RC} who=$(rec_get who) out='${OUT}' err='${ERR}'"

printf '%s\n' "${ATHENA_PAT}" > "${FHOME}/.claude/gitlab-athena-token"
: > "${TMP}/empty-override"; chmod 600 "${TMP}/empty-override"
run_glab GITLAB_ATHENA_TOKEN_FILE="${TMP}/empty-override" -- api user
is_token_refusal && never_reached_a_user && [[ "${ERR}" == *"${TMP}/empty-override"* ]] \
  && ok "3. GITLAB_ATHENA_TOKEN_FILE -> an empty file -> refused, names that file" \
  || bad "3. empty override token file refused" "rc=${RC} who=$(rec_get who) out='${OUT}' err='${ERR}'"

run_glab GITLAB_ATHENA_TOKEN_FILE="${TMP}/no-such-file" -- api user
[ "${RC}" -ne 0 ] && [[ "${ERR}" == *"Fix:"* ]] && never_reached_a_user \
  && ok "4. a missing token file -> refused, glab never runs" \
  || bad "4. missing token file refused" "rc=${RC} who=$(rec_get who) err='${ERR}'"

printf 'glpat-\001bad\n' > "${TMP}/ctrl-token"
run_glab GITLAB_ATHENA_TOKEN_FILE="${TMP}/ctrl-token" -- api user
is_token_refusal && never_reached_a_user \
  && ok "5. a token with a control character -> refused" \
  || bad "5. control-character token refused" "rc=${RC} who=$(rec_get who) err='${ERR}'"

echo
echo "--- glab-athena: a healthy call runs glab with the owner's config unreachable ---"
run_glab -- api user
if [ "${RC}" = 0 ] && [ "$(rec_get who)" = "token:${ATHENA_PAT}" ] && [ "$(rec_get owner_reachable)" = no ]; then
  ok "6. healthy token -> glab runs as the PAT with the owner config unreachable"
else bad "6. healthy call isolated from the owner config" "rc=${RC} who=$(rec_get who) owner_reachable=$(rec_get owner_reachable) cfg=$(rec_get cfg)"; fi

CFG="$(rec_get cfg)"
if [ "${CFG}" != "<unset>" ] && [ "$(rec_get cfg_mode)" = 700 ] && [ "$(rec_get cfg_entries)" = 0 ] \
  && [[ "${CFG}" == "${TMPD}/"* ]]; then
  ok "7. GLAB_CONFIG_DIR is a fresh, empty, 0700 dir under TMPDIR"
else bad "7. fresh empty 0700 config dir" "cfg=${CFG} mode=$(rec_get cfg_mode) entries=$(rec_get cfg_entries)"; fi

if [ -n "${CFG}" ] && [ "${CFG}" != "<unset>" ] && [ ! -e "${CFG}" ] && [ "$(leftovers)" = 0 ]; then
  ok "8. the per-call config dir is removed after glab exits"
else bad "8. per-call dir removed" "cfg=${CFG} leftovers=$(leftovers)"; fi

if [[ "$(rec_get argv)" != *"${ATHENA_PAT}"* ]] && [[ "${OUT}${ERR}" != *"${ATHENA_PAT}"* ]]; then
  ok "9. the PAT is never on glab's argv or in the wrapper's output"
else bad "9. PAT kept off argv and output" "argv=$(rec_get argv)"; fi

run_glab GITLAB_ACCESS_TOKEN=glpat-INHERITED OAUTH_TOKEN=glpat-INHERITED2 GITLAB_URI=https://evil.invalid \
  GITLAB_API_HOST=evil.invalid GL_HOST=evil.invalid GITLAB_HOST=evil.invalid CI_JOB_TOKEN=cijob \
  GLAB_ENABLE_CI_AUTOLOGIN=true GLAB_CONFIG_DIR="${FHOME}/.config/glab-cli" -- api user
if [ "${RC}" = 0 ] && [ -z "$(rec_get envnames | tr -d ' ')" ] && [ "$(rec_get host)" = gitlab.com ] \
  && [ "$(rec_get owner_reachable)" = no ] && [ "$(rec_get cfg)" != "${FHOME}/.config/glab-cli" ]; then
  ok "10. inherited GITLAB_*/GLAB_*/GL_*/OAUTH_TOKEN/CI_JOB_TOKEN are scrubbed; GLAB_CONFIG_DIR is overridden"
else bad "10. inherited identity env scrubbed" "envnames='$(rec_get envnames)' host=$(rec_get host) cfg=$(rec_get cfg) reach=$(rec_get owner_reachable)"; fi

run_glab FAKE_RC=5 -- mr list
if [ "${RC}" = 5 ] && [ "$(leftovers)" = 0 ]; then
  ok "11. glab's exit code is propagated and the dir is removed on failure too"
else bad "11. rc propagated + cleanup on failure" "rc=${RC} leftovers=$(leftovers)"; fi

run_glab FAKE_KILL_PARENT=1 -- mr list
if [ "${RC}" = 143 ] && [ "$(leftovers)" = 0 ]; then
  ok "12. SIGTERM to the wrapper mid-call -> exit 143 and the dir is still removed"
else bad "12. cleanup on SIGTERM" "rc=${RC} leftovers=$(leftovers)"; fi

echo
echo "--- gh-athena: the same class (sweep) ---"
printf '12345\n' > "${TMP}/app-id"
printf 'not-a-key\n' > "${TMP}/key.pem"
GH_CACHE="${TMP}/gh-cache"
printf '%s\t%s\n' "${APP_TOKEN}" "$(( $(date +%s) + 86400 ))" > "${GH_CACHE}"; chmod 600 "${GH_CACHE}"

run_gh GITHUB_TOKEN=ghp_INHERITED GH_ENTERPRISE_TOKEN=x GITHUB_ENTERPRISE_TOKEN=y GH_HOST=evil.invalid \
  GH_CONFIG_DIR="${FHOME}/.config/gh" GH_REPO=o/r -- issue list
if [ "${RC}" = 0 ] && [ "$(rec_get who)" = "token:${APP_TOKEN}" ] && [ "$(rec_get owner_reachable)" = no ] \
  && [ "$(rec_get cfg_mode)" = 700 ] && [ "$(rec_get cfg_entries)" = 0 ] && [[ "$(rec_get cfg)" == "${TMPD}/"* ]]; then
  ok "13. healthy call -> gh runs as the App token in a fresh, empty, 0700 GH_CONFIG_DIR"
else bad "13. gh isolated from the owner config" "rc=${RC} who=$(rec_get who) reach=$(rec_get owner_reachable) cfg=$(rec_get cfg) mode=$(rec_get cfg_mode) err='${ERR}'"; fi

if [ -z "$(rec_get envnames | tr -d ' ')" ] && [ "$(rec_get host)" = github.com ] && [ "$(rec_get repo)" = o/r ]; then
  ok "14. inherited GITHUB_*/GH_ENTERPRISE_TOKEN scrubbed, GH_HOST forced, GH_REPO kept"
else bad "14. gh identity env scrubbed" "envnames='$(rec_get envnames)' host=$(rec_get host) repo=$(rec_get repo)"; fi

if [ "$(leftovers)" = 0 ]; then ok "15. the per-call gh config dir is removed after gh exits"
else bad "15. gh per-call dir removed" "leftovers=$(leftovers)"; fi

run_gh FAKE_RC=4 -- issue list
[ "${RC}" = 4 ] && [ "$(leftovers)" = 0 ] \
  && ok "16. gh's exit code is propagated and the dir is removed on failure" \
  || bad "16. gh rc + cleanup" "rc=${RC} leftovers=$(leftovers)"

run_gh -- --check
if [ "${RC}" = 0 ] && [ "$(rec_get owner_reachable)" = no ] && [[ "$(rec_get cfg)" == "${TMPD}/"* ]] && [ "$(leftovers)" = 0 ]; then
  ok "17. --check probes with the same isolation"
else bad "17. --check isolated" "rc=${RC} cfg=$(rec_get cfg) reach=$(rec_get owner_reachable) err='${ERR}'"; fi

# A cached token that is whitespace is not a token: it must never reach gh.
# The fixture key cannot sign, so the re-mint fails closed.
printf ' \t%s\n' "$(( $(date +%s) + 86400 ))" > "${GH_CACHE}"
run_gh -- issue list
[ "${RC}" -ne 0 ] && [ "$(rec_get invoked)" != yes ] \
  && ok "18. a whitespace cached token is not used; the failed re-mint refuses and gh never runs" \
  || bad "18. whitespace cached token rejected" "rc=${RC} who=$(rec_get who) err='${ERR}'"

openssl genrsa -out "${TMP}/key.pem" 2048 2>/dev/null
printf ' \t%s\n' "$(( $(date +%s) + 86400 ))" > "${GH_CACHE}"
run_gh -- issue list
if [ "${RC}" = 0 ] && [ "$(rec_get who)" = "token:ghs_SELFTESTMINTED0000" ] \
  && [ "$(cut -f1 "${GH_CACHE}")" = ghs_SELFTESTMINTED0000 ]; then
  ok "19. a whitespace cached token is re-minted, and gh runs with the fresh token"
else bad "19. whitespace cache re-minted" "rc=${RC} who=$(rec_get who) err='${ERR}'"; fi

echo
echo "==================================================="
printf 'RESULT: %d passed, %d failed\n' "${PASS}" "${FAIL}"
echo "==================================================="
[ "${FAIL}" -eq 0 ] || { echo "VERDICT: FAIL"; exit 1; }
echo "VERDICT: PASS (${PASS} cases)"
exit 0
