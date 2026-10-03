#!/usr/bin/env bash
# Self-test for forge identity at the process layer (DND-1803): the agent PATH
# wrappers ai/agent-bin/gh and ai/agent-bin/glab, and the push check the agent
# PATH git wrapper (ai/agent-bin/git) runs through ai/lib/agent-forge-push.sh.
#
# The defect this pins: ai/hooks/forge-identity-guard.sh reads the Bash command
# TEXT. A `git push` written into a script and run as `bash <script>` was not in
# that text, so it went out with the machine owner's credentials (2026-10-02,
# a work-repo branch push). The same holds for `gh pr create` and `glab mr
# create` in a script. The wrappers judge the real argv of the process instead.
#
# NO NETWORK, EVER. The "real" gh, glab and git behind the wrappers are fixture
# stand-ins in a stub dir that record every call; the git stand-in fakes every
# push and network read and passes everything else to the real git. Belts:
# GIT_ALLOW_PROTOCOL=file, GIT_SSH_COMMAND=false, a forge-stub-guard behind the
# stubs, and the gh-athena / glab-athena tokens are fixture values (no mint).
#
# Seam (fail-first evidence only): AGENT_FORGE_ROOT_UNDER_TEST=<dir> runs the
# wrappers and the Athena routes from <dir>/ai instead of this checkout's.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO="$(cd "${HERE}/../../.." && pwd -P)"
ROOT="${AGENT_FORGE_ROOT_UNDER_TEST:-${REPO}}"
WBIN="${ROOT}/ai/agent-bin"

TMP="$(mktemp -d)" || { echo "FAIL: mktemp"; exit 1; }
trap 'rm -rf "${TMP}"' EXIT INT TERM
PASS=0; FAIL=0
ok()  { printf '  ok    %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  FAIL  %s\n        %s\n' "$1" "$2"; FAIL=$((FAIL+1)); }

# ---- hermetic environment ---------------------------------------------------
for v in $(env | sed -n 's/^\(GIT_CONFIG_\(KEY\|VALUE\)_[0-9]*\)=.*/\1/p'); do unset "$v"; done
unset GIT_CONFIG_COUNT GIT_CONFIG_PARAMETERS GIT_TRACE2 GIT_DIR GIT_WORK_TREE GIT_ASKPASS SSH_ASKPASS \
  ATHENA_AGENT_GIT_SEEN ATHENA_AGENT_GH_SEEN ATHENA_AGENT_GLAB_SEEN ATHENA_AGENT_BIN \
  GH_TOKEN GITHUB_TOKEN GH_CONFIG_DIR GH_HOST GH_ENTERPRISE_TOKEN \
  GITLAB_TOKEN GLAB_CONFIG_DIR GITLAB_HOST GITLAB_URI GITLAB_API_HOST
# The base PATH: every directory that holds an agent wrapper (the session's own
# ai/agent-bin) is dropped, so the only wrappers on PATH are the ones under test.
BASEPATH=
IFS=: read -r -a _dirs <<< "${PATH}"
for d in "${_dirs[@]}"; do
  _skip=0
  for t in git gh glab; do
    if [ -f "${d}/${t}" ] && grep -q '(agent wrapper)' "${d}/${t}" 2>/dev/null; then _skip=1; fi
  done
  [ "${_skip}" = 1 ] && continue
  BASEPATH="${BASEPATH:+${BASEPATH}:}${d}"
done
export PATH="${BASEPATH}"
REAL_G="$(command -v git)" || { echo "FAIL: no git on PATH"; exit 1; }
export REAL_G
export HOME="${TMP}/home"; mkdir -p "${HOME}"
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL="${TMP}/gitconfig"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
export GIT_ALLOW_PROTOCOL=file GIT_SSH_COMMAND=false GIT_TERMINAL_PROMPT=0
printf '[init]\n\tdefaultBranch = main\n[alias]\n\tp = push\n' > "${GIT_CONFIG_GLOBAL}"
# gh-athena: a fixture App config and a cached token, so it never mints.
printf '12345\n' > "${TMP}/app-id"; printf 'not-a-key\n' > "${TMP}/key.pem"
printf '%s\t%s\n' "ghs_SELFTESTFAKE0000" "$(( $(date +%s) + 86400 ))" > "${TMP}/token-cache"
chmod 600 "${TMP}/token-cache"
export GH_ATHENA_APP_ID_FILE="${TMP}/app-id" GH_ATHENA_KEY="${TMP}/key.pem" GH_ATHENA_TOKEN_CACHE="${TMP}/token-cache"
# glab-athena: a fixture PAT.
printf 'glpat-SELFTESTFAKE0000\n' > "${TMP}/glab-token"; chmod 600 "${TMP}/glab-token"
export GITLAB_ATHENA_TOKEN_FILE="${TMP}/glab-token"
export ATHENA_TELEMETRY_DIR="${TMP}/telemetry" ATHENA_SECRETS_ROOT="${TMP}/secrets"
unset ATHENA_UNIT

# ---- the fixture "real" CLIs -------------------------------------------------
export LOG="${TMP}/calls.log"
STUBS="${TMP}/stubs"; mkdir -p "${STUBS}"
cat > "${STUBS}/gh" <<'EOF'
#!/usr/bin/env bash
# fixture gh: answers the visibility read gh-athena makes, records the rest.
case "$*" in
  *"repo view"*"--json visibility"*) echo PRIVATE; exit 0 ;;
  --help) echo "FIXTURE-GH-HELP Usage: gh <command>"; exit 0 ;;
esac
printf 'REAL-GH %s|token=%s|cfg=%s\n' "$*" "${GH_TOKEN:+set}" "${GH_CONFIG_DIR##*/}" >> "${LOG}"
exit 0
EOF
cat > "${STUBS}/glab" <<'EOF'
#!/usr/bin/env bash
# fixture glab: records every call.
[ "$*" = --help ] && { echo "FIXTURE-GLAB-HELP Usage: glab <command>"; exit 0; }
printf 'REAL-GLAB %s|token=%s|cfg=%s\n' "$*" "${GITLAB_TOKEN:+set}" "${GLAB_CONFIG_DIR##*/}" >> "${LOG}"
exit 0
EOF
cat > "${STUBS}/git" <<'EOF'
#!/usr/bin/env bash
# fixture git: a push, fetch, pull or network ls-remote is recorded and faked
# (exit 0, nothing sent); with SHIM_REAL_PUSH=1 a push runs for real (a local
# remote). Everything else goes to the real git.
args=("$@")
while [ $# -gt 0 ]; do
  case "$1" in
    -C|-c|--git-dir|--work-tree|--namespace|--config-env|--attr-source|--shallow-file) shift 2; continue ;;
    -*) shift; continue ;;
  esac
  break
done
sub="${1:-}"
case "${sub}" in
  push)
    hdr=none; i=0
    while [ "${i}" -lt "${GIT_CONFIG_COUNT:-0}" ]; do
      k="GIT_CONFIG_KEY_${i}"
      case "${!k:-}" in http.https://*/.extraheader) hdr="${!k}" ;; esac
      i=$((i+1))
    done
    printf 'REAL-GIT %s|hdr=%s\n' "${args[*]}" "${hdr}" >> "${LOG}"
    [ "${SHIM_REAL_PUSH:-0}" = 1 ] && exec "${REAL_G}" "${args[@]}"
    exit 0 ;;
  fetch|pull)
    printf 'REAL-GIT %s\n' "${args[*]}" >> "${LOG}"; exit 0 ;;
  ls-remote)
    case " ${args[*]} " in *" --get-url "*) ;; *) printf 'REAL-GIT %s\n' "${args[*]}" >> "${LOG}"; exit 0 ;; esac ;;
esac
exec "${REAL_G}" "${args[@]}"
EOF
chmod +x "${STUBS}/gh" "${STUBS}/glab" "${STUBS}/git"
# DND-1647/1667: a guard right behind the stubs, so a stub that is missing or not
# executable fails the suite instead of reaching the real tool.
. "${REPO}/ai/lib/forge-stub-guard.sh"
fsg_make "${TMP}/stub-guard" gh glab git
fsg_require_stubs "${STUBS}" gh glab git
# The wrappers under test come first; they search PATH after their own entry,
# so they find the stubs (this layout is what is under test: no guard between
# the wrappers and the stubs).
APATH="${WBIN}:${STUBS}:${FSG_DIR}:${BASEPATH}"

GHA="${ROOT}/ai/bin/gh-athena"
GLA="${ROOT}/ai/bin/glab-athena"

# ---- fixture repos ----------------------------------------------------------
K=0
# repo <origin-url> : a repo on branch feat with one commit; sets R.
repo() {
  K=$((K+1)); R="${TMP}/r${K}"
  "${REAL_G}" init -q -b main "${R}" && "${REAL_G}" -C "${R}" commit -q --allow-empty -m init \
    && "${REAL_G}" -C "${R}" checkout -q -b feat && "${REAL_G}" -C "${R}" remote add origin "$1" \
    || { echo "FAIL: fixture repo ${K}"; exit 1; }
}

# run <dir> <cmd...> : run with the wrappers on PATH, bounded; sets OUT and RC.
run() {
  local d="$1"; shift
  : > "${LOG}"
  OUT="$(cd "${d}" && export PATH="${APATH}" && timeout 60 "$@" 2>&1)"; RC=$?
  CALLS="$(cat "${LOG}")"
}
# script <dir> <line> : the incident's shape: the command in a script file run
# as `bash <script>`, so no Bash command text ever names it.
script() {
  printf '#!/usr/bin/env bash\n%s\n' "$2" > "${TMP}/script.sh"
  run "$1" bash "${TMP}/script.sh"
}
# refused <label> <tool> <route> <recorded-pattern> : exit 1, the wrapper's
# REFUSED line, a Fix: naming the Athena route, and nothing reached the
# fixture CLI.
refused() {
  if [ "${RC}" = 1 ] && [[ "${OUT}" == *"$2 (agent wrapper): REFUSED"* ]] && [[ "${OUT}" == *"Fix:"* ]] \
    && [[ "${OUT}" == *"$3"* ]] && [[ "${CALLS}" != *"$4"* ]]; then ok "$1"
  else bad "$1" "rc=${RC} calls=[${CALLS}] out=$(printf '%s' "${OUT}" | head -c 400)"; fi
}
# passed <label> <recorded-pattern> : exit 0, no refusal, and the call reached
# the fixture CLI.
passed() {
  if [ "${RC}" = 0 ] && [[ "${OUT}" != *"REFUSED"* ]] && [[ "${CALLS}" == *"$2"* ]]; then ok "$1"
  else bad "$1" "rc=${RC} calls=[${CALLS}] out=$(printf '%s' "${OUT}" | head -c 400)"; fi
}

echo "agent forge-identity self-test"
echo "wrappers: ${WBIN}"
echo

echo "--- git push to a forge, not routed: REFUSED (the incident) ---"
repo 'https://github.com/synth-owner/synth-repo.git'
script "${R}" 'git push origin HEAD:refs/heads/feat'
refused "P1. a script running git push to an https github.com remote" git gh-athena 'REAL-GIT'
repo 'git@github.com:synth-owner/synth-repo.git'
script "${R}" 'git push -u origin feat'
refused "P2. a script running git push -u to an SSH-form github.com remote" git gh-athena 'REAL-GIT'
repo 'https://gitlab.com/synth-group/synth-repo.git'
script "${R}" 'git push origin HEAD:refs/heads/feat'
refused "P3. a script running git push to a gitlab.com remote" git glab-athena 'REAL-GIT'
repo 'ssh://git@github.com/synth-owner/synth-repo.git'
run "${R}" git push origin HEAD
refused "P4. git push to an ssh:// github.com remote" git gh-athena 'REAL-GIT'
repo 'https://github.com/synth-owner/synth-repo.git'
run "${R}" git push
refused "P5. a bare git push (default remote) to github.com" git gh-athena 'REAL-GIT'
run "${R}" git p origin HEAD
refused "P6. the alias p = push to github.com" git gh-athena 'REAL-GIT'
repo "${TMP}/nowhere.git"
"${REAL_G}" -C "${R}" config remote.origin.pushurl 'https://github.com/synth-owner/synth-repo.git'
run "${R}" git push origin HEAD
refused "P7. a local origin whose pushurl is github.com" git gh-athena 'REAL-GIT'
repo 'gh:synth-owner/synth-repo.git'
"${REAL_G}" -C "${R}" config url.https://github.com/.insteadOf gh:
run "${R}" git push origin HEAD
refused "P8. an insteadOf that rewrites a remote to github.com" git gh-athena 'REAL-GIT'
repo "${TMP}/nowhere.git"
run "${R}" git push 'https://github.com/synth-owner/synth-repo.git' HEAD
refused "P9. a literal github.com URL" git gh-athena 'REAL-GIT'

echo
echo "--- a forged marker is not the route: REFUSED ---"
repo 'https://github.com/synth-owner/synth-repo.git'
run "${R}" env GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=http.https://github.com/.extraheader \
  'GIT_CONFIG_VALUE_0=AUTHORIZATION: basic eDp5' git push origin HEAD
refused "F1. the bot header alone, owner credential helper still on" git gh-athena 'REAL-GIT'
run "${R}" env GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=http.https://github.com/.extraheader \
  'GIT_CONFIG_VALUE_0=AUTHORIZATION: basic eDp5' git -c credential.helper= -c core.askPass= \
  -c credential.helper=store push origin HEAD
refused "F2. the full marker, then a credential helper added back" git gh-athena 'REAL-GIT'
repo 'https://github.com/synth-owner/synth-repo.git'
run "${R}" env GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=http.https://gitlab.com/.extraheader \
  'GIT_CONFIG_VALUE_0=AUTHORIZATION: basic eDp5' git -c credential.helper= -c core.askPass= push origin HEAD
refused "F3. a gitlab.com header on a github.com push" git gh-athena 'REAL-GIT'
run "${R}" env GH_TOKEN=forged gh pr create --title t --body b
refused "F4. gh with a token in the env but no isolated config dir" gh gh-athena 'REAL-GH'
repo 'git@github.com:synth-owner/synth-repo.git'
run "${R}" env GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=http.https://github.com/.extraheader \
  'GIT_CONFIG_VALUE_0=AUTHORIZATION: basic eDp5' git -c credential.helper= -c core.askPass= push origin HEAD
refused "F6. the full marker on an SSH-form remote with no rewrite (git would push over SSH)" git gh-athena 'REAL-GIT'
repo 'https://synth-user:SYNTHSECRET0000@github.com/synth-owner/synth-repo.git'
run "${R}" git push origin HEAD
if [[ "${OUT}" != *"SYNTHSECRET0000"* ]]; then refused "F7. a credential in the remote URL: refused, never printed" git gh-athena 'REAL-GIT'
else bad "F7. a credential in the remote URL is printed" "out=$(printf '%s' "${OUT}" | head -c 400)"; fi
"${REAL_G}" init -q -b main "${TMP}/sub"; "${REAL_G}" -C "${TMP}/sub" commit -q --allow-empty -m s
repo "${TMP}/nowhere.git"
printf '[submodule "s"]\n\tpath = s\n\turl = https://github.com/synth-owner/synth-sub.git\n' > "${R}/.gitmodules"
run "${R}" git -c submodule.recurse=true push origin HEAD
refused "F8. submodule.recurse=true in a repo with submodules (each submodule push is unchecked)" git 'no-recurse-submodules' 'REAL-GIT'
# DND-1841: git applies the LAST recursion flag, and the LAST of the two config
# keys (push.recurseSubmodules, submodule.recurse) in config order; an earlier
# "no" does not switch off a later "on".
run "${R}" git push --no-recurse-submodules --recurse-submodules=on-demand origin HEAD
refused "F9. --no-recurse-submodules then --recurse-submodules=on-demand (the last flag wins)" git 'no-recurse-submodules' 'REAL-GIT'
"${REAL_G}" -C "${R}" config push.recurseSubmodules no
run "${R}" git -c submodule.recurse=true push origin HEAD
refused "F10. push.recurseSubmodules=no in the repo, then -c submodule.recurse=true (the later key wins)" git 'no-recurse-submodules' 'REAL-GIT'
"${REAL_G}" -C "${R}" config --unset push.recurseSubmodules
run "${R}" git -c submodule.recurse=true push --no-recurse-submodules origin HEAD
passed "F11. submodule.recurse=true with --no-recurse-submodules to a local remote passes" 'REAL-GIT'
run "${R}" git push -o -- --recurse-submodules=on-demand origin HEAD
refused "F12. \`-o --\`: the -- is -o's value, so the next flag still counts" git 'no-recurse-submodules' 'REAL-GIT'
mkdir -p "${TMP}/not-isolated"
run "${R}" env GH_TOKEN=forged GH_HOST=github.com GH_CONFIG_DIR="${TMP}/not-isolated" gh pr create --title t --body b
refused "F5. gh with a config dir that is not gh-athena's" gh gh-athena 'REAL-GH'

echo
echo "--- DND-1843: an option VALUE is never read as help, a flag or the repository ---"
# git reads the word after -o / --push-option (or any abbreviation of a long
# option that takes a value, or a short cluster ending in o) as that option's
# value. Read as help, it skipped the whole check; read as the repository, it
# hid the default remote. Each push below reaches github.com as the owner.
SYNTH_GH='https://github.com/synth-owner/synth-repo.git'
repo "${TMP}/nowhere.git"
run "${R}" git push -o -h "${SYNTH_GH}" HEAD
refused "K1. push -o -h <github url>: -h is -o's value, not help" git gh-athena 'REAL-GIT'
run "${R}" git push --push-option=--help "${SYNTH_GH}" HEAD
refused "K2. push --push-option=--help <github url>" git gh-athena 'REAL-GIT'
run "${R}" git push --push-option --help "${SYNTH_GH}" HEAD
refused "K3. push --push-option --help <github url>" git gh-athena 'REAL-GIT'
run "${R}" git push -o -- -h "${SYNTH_GH}" HEAD
refused "K4. push -o -- -h <github url>: the -- is -o's value" git gh-athena 'REAL-GIT'
repo 'ssh://git@github.com/synth-owner/synth-repo.git'
run "${R}" git push --push-o ci.skip
refused "K5. push --push-o ci.skip: an abbreviated -o takes the value, the default remote is judged" git gh-athena 'REAL-GIT'
run "${R}" git push -vo ci.skip
refused "K6. push -vo ci.skip: a short cluster ending in o takes the value" git gh-athena 'REAL-GIT'
run "${R}" git push --recurse-submodules no
refused "K7. push --recurse-submodules no: the value is not the repository" git gh-athena 'REAL-GIT'
repo "${TMP}/nowhere.git"
"${REAL_G}" -C "${R}" config url.ssh://git@github.com/.insteadOf synthgh:
run "${R}" git push --push-o x synthgh:synth-owner/synth-repo.git HEAD
refused "K8. push --push-o x <insteadOf alias for ssh github>: the real repository is judged" git gh-athena 'REAL-GIT'
repo "${SYNTH_GH}"
run "${R}" git --attr-source HEAD push origin HEAD
refused "K9. git --attr-source HEAD push: the global option's value is not the subcommand" git gh-athena 'REAL-GIT'
run "${R}" git --shallow-file "${TMP}/no-shallow" push origin HEAD
refused "K10. git --shallow-file <file> push" git gh-athena 'REAL-GIT'
run "${R}" git --no-literal-pathspecs push origin HEAD
refused "K11. git --no-literal-pathspecs push (a global switch git accepts)" git gh-athena 'REAL-GIT'
run "${R}" git --synth-unknown-opt push origin HEAD
refused "K12. an unknown global option before push is refused (deny by default)" git gh-athena 'REAL-GIT'
run "${R}" git push --help
if [[ "${OUT}" != *"REFUSED"* ]] && [[ "${CALLS}" == *"REAL-GIT push --help"* ]]; then ok "K13. git push --help in a github.com repo is not judged"
else bad "K13. git push --help" "rc=${RC} calls=[${CALLS}] out=$(printf '%s' "${OUT}" | head -c 400)"; fi
run "${R}" gh pr create --title --help --body b
refused "K14. gh pr create --title --help: --help is --title's value, so it is a write" gh 'gh-athena pr create' 'REAL-GH'
run "${R}" glab mr create --title -h
refused "K15. glab mr create --title -h: -h is --title's value" glab 'glab-athena mr create' 'REAL-GLAB'
run "${R}" gh pr create -- --help
refused "K16. gh pr create -- --help: after --, --help is an argument" gh 'gh-athena pr create' 'REAL-GH'
run "${R}" gh pr create --help
passed "K17. gh pr create --help is help: a read" 'REAL-GH pr create --help'

echo
echo "--- the Athena routes still work (against the fixtures) ---"
repo 'git@github.com:synth-owner/synth-repo.git'
run "${R}" "${GHA}" git push origin HEAD:refs/heads/feat
passed "R1. gh-athena git push reaches git with the bot header" 'hdr=http.https://github.com/.extraheader'
repo 'https://gitlab.com/synth-group/synth-repo.git'
run "${R}" "${GLA}" git push origin HEAD:refs/heads/feat
passed "R2. glab-athena git push reaches git with the bot header" 'hdr=http.https://gitlab.com/.extraheader'
repo 'https://github.com/synth-owner/synth-repo.git'
run "${R}" "${GLA}" git push origin HEAD:refs/heads/feat
refused "R3. glab-athena git push to a github.com remote (wrong bot for the host)" git gh-athena 'REAL-GIT'
run "${R}" "${GHA}" pr create --title t --body b -R synth-owner/synth-repo
passed "R4. gh-athena pr create reaches gh as the App (token, isolated config)" 'REAL-GH pr create --title t --body b -R synth-owner/synth-repo|token=set|cfg=gh-athena-cfg.'
run "${R}" "${GLA}" mr create --title t --description d
passed "R5. glab-athena mr create reaches glab as athena-amby (token, isolated config)" 'REAL-GLAB mr create --title t --description d|token=set|cfg=glab-athena-cfg.'

echo
echo "--- plain gh / glab writes: REFUSED (scripts included) ---"
script "${R}" 'gh pr create --title t --body b'
refused "W1. a script running gh pr create" gh gh-athena 'REAL-GH'
script "${R}" 'glab mr create --title t --description d'
refused "W2. a script running glab mr create" glab glab-athena 'REAL-GLAB'
run "${R}" gh pr close 1
refused "W3. gh pr close" gh 'gh-athena pr close' 'REAL-GH'
run "${R}" gh api -X POST repos/o/r/issues -f title=x
refused "W4. gh api -X POST" gh 'gh-athena api' 'REAL-GH'
run "${R}" gh api repos/o/r/issues -f title=x
refused "W5. gh api with a field and no method (gh POSTs)" gh 'gh-athena api' 'REAL-GH'
run "${R}" gh api graphql -f 'query=mutation { addStar(input: {}) { clientMutationId } }'
refused "W6. gh api graphql with a mutation" gh 'gh-athena api' 'REAL-GH'
run "${R}" glab mr note 1 -m hi
refused "W7. glab mr note" glab 'glab-athena mr note' 'REAL-GLAB'
run "${R}" glab api -X PUT projects/1/merge_requests/2/merge
refused "W8. glab api PUT" glab 'glab-athena api' 'REAL-GLAB'
run "${R}" gh pr merge 1 --squash
refused "W9. gh pr merge: the Fix names the guarded merge path" gh 'locked-merge' 'REAL-GH'
run "${R}" glab mr merge 1
refused "W10. glab mr merge: the Fix names the pinned merge-train path" glab 'merge_trains' 'REAL-GLAB'
run "${R}" gh secret set SYNTH_NAME --body SYNTHSECRET0000
if [[ "${OUT}" != *"SYNTHSECRET0000"* ]]; then refused "W11. gh secret set: refused, its value never printed" gh 'gh-athena secret set' 'REAL-GH'
else bad "W11. gh secret set prints the value" "out=$(printf '%s' "${OUT}" | head -c 400)"; fi
run "${R}" gh alias set co2 'pr create'
refused "W12. gh alias set: the alias Fix" gh 'do not define aliases' 'REAL-GH'

echo
echo "--- reads pass through ---"
run "${R}" gh pr view 1
passed "D1. gh pr view" 'REAL-GH pr view 1|token=|cfg='
run "${R}" gh api repos/o/r/pulls
passed "D2. gh api GET" 'REAL-GH api repos/o/r/pulls'
run "${R}" gh api graphql -f 'query=query($o: String!) { repositoryOwner(login: $o) { id } }' -f o=x
passed "D3. gh api graphql query with variables (a read)" 'REAL-GH api graphql'
run "${R}" glab mr list
passed "D4. glab mr list" 'REAL-GLAB mr list'
run "${R}" gh pr close --help
passed "D5. gh pr close --help" 'REAL-GH pr close --help'
repo 'https://github.com/synth-owner/synth-repo.git'
run "${R}" git fetch origin
passed "D6. git fetch from github.com" 'REAL-GIT fetch origin'
run "${R}" git ls-remote origin
passed "D7. git ls-remote on github.com" 'REAL-GIT ls-remote origin'
run "${R}" git pull --ff-only origin main
passed "D8. git pull --ff-only from github.com" 'REAL-GIT pull --ff-only origin main'
run "${R}" git push -h
if [[ "${OUT}" != *"REFUSED"* ]] && [[ "${CALLS}" == *"REAL-GIT push -h"* ]]; then ok "D10. git push -h in a github.com repo is not judged"
else bad "D10. git push -h" "rc=${RC} calls=[${CALLS}] out=$(printf '%s' "${OUT}" | head -c 400)"; fi
"${REAL_G}" init -q --bare "${TMP}/local.git"
repo "${TMP}/local.git"
run "${R}" env SHIM_REAL_PUSH=1 git push origin HEAD:refs/heads/feat
if [ "${RC}" = 0 ] && "${REAL_G}" -C "${TMP}/local.git" rev-parse -q --verify refs/heads/feat >/dev/null; then
  ok "D9. git push to a local bare remote is allowed and lands"
else bad "D9. local push" "rc=${RC} out=$(printf '%s' "${OUT}" | head -c 400)"; fi

echo
echo "--- the wrappers themselves ---"
OUT="$(cd "${R}" && export PATH="${APATH}" && timeout 60 gh --help 2>/dev/null)"; RC=$?
if [ "${RC}" = 0 ] && [[ "${OUT}" == *"FIXTURE-GH-HELP"* ]] && [[ "${OUT}" == *"gh (agent wrapper)"* ]]; then
  ok "H1. gh --help: the real gh's help, then the wrapper's note, exit 0"
else bad "H1. gh --help" "rc=${RC} out=$(printf '%s' "${OUT}" | head -c 400)"; fi
# A PATH that holds no gh at all: only the tools the wrapper itself runs.
NOGH="${TMP}/no-gh"; mkdir -p "${NOGH}"
ln -s "$(command -v env)" "${NOGH}/env"
ln -s "$(command -v bash)" "${NOGH}/bash"
ln -s "$(command -v readlink)" "${NOGH}/readlink"
ln -s "$(command -v dirname)" "${NOGH}/dirname"
TO="$(command -v timeout)"
OUT="$(cd "${R}" && export PATH="${WBIN}:${NOGH}" && "${TO}" 60 gh --help 2>/dev/null)"; RC=$?
if [ "${RC}" = 0 ] && [[ "${OUT}" == *"gh (agent wrapper)"* ]]; then
  ok "H2. gh --help with no real gh still answers, exit 0"
else bad "H2. gh --help without gh" "rc=${RC} out=$(printf '%s' "${OUT}" | head -c 400)"; fi
OUT="$(cd "${R}" && export PATH="${WBIN}:${NOGH}" && "${TO}" 60 gh pr view 1 2>&1)"; RC=$?
if [ "${RC}" = 127 ] && [[ "${OUT}" == *"Fix:"* ]]; then
  ok "H3. no real gh after the wrapper: exit 127 with a Fix:"
else bad "H3. no real gh" "rc=${RC} out=$(printf '%s' "${OUT}" | head -c 400)"; fi
ln -s "${WBIN}" "${TMP}/wbin-again"
: > "${LOG}"
OUT="$(cd "${R}" && export PATH="${WBIN}:${TMP}/wbin-again:${STUBS}:${FSG_DIR}:${BASEPATH}" && timeout 60 gh pr view 2 2>&1)"; RC=$?
if [ "${RC}" = 0 ] && grep -q 'REAL-GH pr view 2' "${LOG}"; then
  ok "H4. the wrapper directory twice on PATH: no loop, the real gh answers"
else bad "H4. wrapper twice" "rc=${RC} out=$(printf '%s' "${OUT}" | head -c 400)"; fi

echo
fsg_verify || FAIL=$((FAIL+1))
echo "agent forge-identity: ${PASS} passed, ${FAIL} failed"
[ "${FAIL}" -eq 0 ]
