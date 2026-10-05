#!/usr/bin/env bash
# Self-test for the forge transport's own push-range scan (DND-2023).
#
# The defect this pins: a push through the Athena route (`gh-athena git push`,
# `glab-athena git push`) from a repository whose pre-push hook is the outbound
# hook (ai/git-hooks/outbound-pre-push.sh) went out UNSCANNED when git was told
# to skip its hooks: `--no-verify`, `-c core.hooksPath=<elsewhere>`, the same
# setting through GIT_CONFIG_PARAMETERS or GIT_CONFIG_COUNT. The route's push
# parse accepts `--no-verify` (FG_PUSH_PLAIN in ai/lib/forge-git-passthrough.sh),
# so a commit carrying a work-domain value reached the public repo. The fix:
# the route's transport (ai/lib/forge-transport/git-remote-athena-forge) runs
# the same landed scan on the range it is asked to push, through
# ai/lib/forge-push-scan, whatever git did with its hooks.
#
# NO NETWORK, EVER. Every git here goes through a shim that runs the real git
# with --exec-path=<a copy of git's exec-path> whose git-remote-https is a
# FIXTURE: it maps https://github.com/<o>/<r> to a local bare repository and
# speaks either the remote-helper `push` capability (as git's real
# git-remote-https does) or `connect` (FX_MODE=connect). The App token is a
# fixture cache (no mint); the overlay is a fixture under mktemp -d with
# synthetic values only (SYNTH-TOKEN-1). A guard sits behind the git shim
# (ai/lib/forge-stub-guard.sh, DND-1647/1667).
#
# Run another copy of the route (old-vs-new evidence) with
#   GH_ATHENA_UNDER_TEST=/path/to/gh-athena bash ai/test/forge-push-scan/self-test.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT="$(cd "${HERE}/../../.." && pwd -P)"
AI_DIR="${ROOT}/ai"
WRAPPER="${GH_ATHENA_UNDER_TEST:-${AI_DIR}/bin/gh-athena}"
GLAB_WRAPPER="${GLAB_ATHENA_UNDER_TEST:-${AI_DIR}/bin/glab-athena}"
HOOK="${AI_DIR}/git-hooks/outbound-pre-push.sh"

case "${1:-}" in
  -h | --help)
    sed -n '2,25p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
    exit 0 ;;
esac

TMP="$(mktemp -d)" || { echo "FAIL: mktemp"; exit 1; }
trap 'rm -rf "${TMP}"' EXIT INT TERM
PASS=0; FAIL=0
ok()  { printf '  ok    %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  FAIL  %s\n        %s\n' "$1" "$2"; FAIL=$((FAIL+1)); }

TOKEN="SYNTH-TOKEN-1"

# ---- hermetic environment ---------------------------------------------------
for v in $(env | sed -n 's/^\(GIT_CONFIG_\(KEY\|VALUE\)_[0-9]*\)=.*/\1/p'); do unset "$v"; done
unset GIT_CONFIG_COUNT GIT_CONFIG_PARAMETERS GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR \
  ATHENA_OUTBOUND_WAIVE ATHENA_PRIVATE_ROOT ATHENA_UNIT GIT_EXEC_PATH
export HOME="${TMP}/home"; mkdir -p "${HOME}"
export XDG_STATE_HOME="${TMP}/state"
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL="${TMP}/gitconfig"
printf '[user]\n\tname = t\n\temail = t@t\n[init]\n\tdefaultBranch = main\n[advice]\n\tdetachedHead = false\n' > "${GIT_CONFIG_GLOBAL}"
export GIT_ALLOW_PROTOCOL=file:athena-forge:https GIT_TERMINAL_PROMPT=0 GIT_SSH_COMMAND=false
FAKE_TOKEN="ghs_SELFTESTFAKETOKEN0000"
printf '12345\n' > "${TMP}/app-id"; printf 'not-a-key\n' > "${TMP}/key.pem"
printf '%s\t%s\n' "${FAKE_TOKEN}" "$(( $(date +%s) + 86400 ))" > "${TMP}/token-cache"; chmod 600 "${TMP}/token-cache"
export GH_ATHENA_APP_ID_FILE="${TMP}/app-id" GH_ATHENA_KEY="${TMP}/key.pem" GH_ATHENA_TOKEN_CACHE="${TMP}/token-cache"
export ATHENA_TELEMETRY_DIR="${TMP}/telemetry" ATHENA_SECRETS_ROOT="${TMP}/secrets"

# ---- fixture overlay ----------------------------------------------------------
OVERLAY="${TMP}/overlay"; mkdir -p "${OVERLAY}/outbound"; chmod 700 "${OVERLAY}"
printf '{"kind":"athena-private-overlay","schema":1}\n' > "${OVERLAY}/athena-overlay.json"
printf '# synthetic fixture patterns\nsynth-token\tSYNTH-TOKEN-[0-9]+\n' > "${OVERLAY}/outbound/patterns.tsv"
git -C "${OVERLAY}" init -q && git -C "${OVERLAY}" add -A && git -C "${OVERLAY}" commit -q -m overlay
export ATHENA_PRIVATE_ROOT="${OVERLAY}"

# ---- the fixture forge transport --------------------------------------------
X="${TMP}/x"; mkdir -p "${X}/shim" "${X}/exec" "${X}/forge/o"
export FX_REAL_GIT="$(git --exec-path)/git" FX_EXEC="${X}/exec" FX_FORGE="${X}/forge" FX_LOG="${X}/stub.log"
for f in "$(git --exec-path)"/*; do ln -s "${f}" "${FX_EXEC}/${f##*/}"; done
rm -f "${FX_EXEC}/git-remote-https"
cat > "${FX_EXEC}/git-remote-https" <<'EOF'
#!/usr/bin/env bash
# fixture git-remote-https (DND-2023): no network. FX_MODE=push (default)
# speaks the `push` capability as git's real git-remote-https does;
# FX_MODE=connect speaks `connect`.
url="${2:-$1}"
repo="${FX_FORGE}/${url#https://*/}"
printf 'start mode=%s url=%s\n' "${FX_MODE:-push}" "${url}" >> "${FX_LOG}"
if [ "${FX_MODE:-push}" = connect ]; then
  while IFS= read -r line; do
    case "${line}" in
      capabilities) printf 'connect\n\n' ;;
      "connect "*) printf '\n'; exec env -u GIT_DIR git "${line#connect git-}" "${repo}" ;;
      '') exit 0 ;;
      *) exit 1 ;;
    esac
  done
  exit 0
fi
specs=()
while IFS= read -r line; do
  case "${line}" in
    capabilities) printf 'push\noption\n\n' ;;
    "option "*) printf 'unsupported\n' ;;
    "list for-push") git --git-dir="${repo}" for-each-ref --format='%(objectname) %(refname)'; printf '\n' ;;
    "push "*) specs+=( "${line#push }" ) ;;
    '')
      [ "${#specs[@]}" = 0 ] && exit 0
      for s in "${specs[@]}"; do
        dst="${s#*:}"
        if git push -q --no-verify "${repo}" "${s}" >/dev/null 2>&1; then printf 'ok %s\n' "${dst}"
        else printf 'error %s fixture push failed\n' "${dst}"; fi
        printf 'pushed %s\n' "${s}" >> "${FX_LOG}"
      done
      printf '\n'; specs=() ;;
    *) printf 'unknown %s\n' "${line}" >> "${FX_LOG}"; exit 1 ;;
  esac
done
EOF
chmod +x "${FX_EXEC}/git-remote-https"
printf '#!/bin/sh\nexec "$FX_REAL_GIT" --exec-path="$FX_EXEC" "$@"\n' > "${X}/shim/git"; chmod +x "${X}/shim/git"
. "${AI_DIR}/lib/forge-stub-guard.sh"
fsg_make "${TMP}/git-guard" git
fsg_require_stubs "${X}/shim" git
XPATH="${X}/shim:${FSG_DIR}:${PATH}"

# mk_repo <name> [hook] : a bare fixture forge repo o/<name> with main, and a
# main checkout cloned from it with ai/ linked to this checkout's ai/
# (untracked), origin set to the SSH form the route rewrites; with `hook`,
# the outbound pre-push hook installed as setup-private-overlay installs it.
mk_repo() {
  local name="$1" hook="${2:-}" m="${TMP}/$1" bare="${FX_FORGE}/o/$1.git"
  git init -q --bare -b main "${bare}"
  git init -q -b main "${m}"
  printf 'hello\n' > "${m}/README"
  git -C "${m}" add README && git -C "${m}" commit -q -m init
  git -C "${m}" push -q "${bare}" main
  git -C "${m}" remote add origin "git@github.com:o/${name}.git"
  git -C "${m}" fetch -q "${bare}" "+refs/heads/*:refs/remotes/origin/*"
  ln -s "${AI_DIR}" "${m}/ai"
  printf 'ai\n' >> "${m}/.git/info/exclude"
  if [ -n "${hook}" ]; then cp "${HOOK}" "${m}/.git/hooks/pre-push" && chmod +x "${m}/.git/hooks/pre-push"; fi
  printf '%s' "${m}"
}
# plant <repo> <file> : a commit carrying the synthetic token.
plant() { printf 'contact %s\n' "${TOKEN}" > "$1/$2"; git -C "$1" add "$2" && git -C "$1" commit -q -m "add $2"; }
clean_commit() { printf 'plain %s\n' "$2" > "$1/$2"; git -C "$1" add "$2" && git -C "$1" commit -q -m "add $2"; }
# route <dir> [env assignments...] -- <git args...> : a REAL run of gh-athena git.
route() {
  local d="$1"; shift
  local -a envs=()
  while [ "$#" -gt 0 ] && [ "$1" != -- ]; do envs+=( "$1" ); shift; done
  shift
  OUT="$(cd "${d}" && env PATH="${XPATH}" "${envs[@]}" "${WRAPPER}" git "$@" 2>&1)"; RC=$?
}
# landed <name> <ref> : the fixture forge's sha for <ref>, or empty.
landed() { git --git-dir="${FX_FORGE}/o/$1.git" rev-parse -q --verify "$2" 2>/dev/null || true; }
no_literal() { [[ "${OUT}" != *"${TOKEN}"* ]]; }

echo "forge transport push-range scan self-test (DND-2023)"
echo "wrapper: ${WRAPPER}"
echo

echo "--- the hook alone: a plain routed push of the token is refused by the hook ---"
R="$(mk_repo r1 hook)"; plant "${R}" notes.md
route "${R}" -- push origin HEAD:refs/heads/t1
if [ "${RC}" != 0 ] && [ -z "$(landed r1 refs/heads/t1)" ] && [[ "${OUT}" == *"outbound-scan: HITS mode=pre-push"* ]] && no_literal; then
  ok "H1. hook installed, plain push: refused by the hook, nothing landed"
else bad "H1. hook refuses a plain routed push" "rc=${RC} landed=$(landed r1 refs/heads/t1) out=${OUT}"; fi

echo "--- every hook-skip route: the transport scans the range itself ---"
# skip <label> <branch> <env...> -- <git args...> : the push must be refused,
# land nothing, and name the transport's scan.
skip() {
  local label="$1" br="$2"; shift 2
  route "${R}" "$@"
  if [ "${RC}" != 0 ] && [ -z "$(landed r1 "refs/heads/${br}")" ] && [[ "${OUT}" == *"outbound-scan: HITS mode=pre-push"* ]] \
     && [[ "${OUT}" == *"forge-push-scan"* ]] && [[ "${OUT}" == *"Fix:"* ]] && no_literal; then
    ok "${label}"
  else bad "${label}" "rc=${RC} landed=$(landed r1 "refs/heads/${br}") out=${OUT}"; fi
}
skip "S1. --no-verify: refused by the transport's own scan, nothing landed" s1 -- push --no-verify origin HEAD:refs/heads/s1
skip "S2. -c core.hooksPath=<empty dir>: refused, nothing landed" s2 -- -c "core.hooksPath=${TMP}/nohooks" push origin HEAD:refs/heads/s2
skip "S3. core.hooksPath through GIT_CONFIG_PARAMETERS: refused, nothing landed" s3 \
  "GIT_CONFIG_PARAMETERS='core.hookspath'='${TMP}/nohooks'" -- push origin HEAD:refs/heads/s3
skip "S4. core.hooksPath through GIT_CONFIG_COUNT/KEY/VALUE: refused, nothing landed" s4 \
  GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.hooksPath "GIT_CONFIG_VALUE_0=${TMP}/nohooks" -- push origin HEAD:refs/heads/s4
skip "S5. --no-verify over the connect capability: refused, nothing landed" s5 FX_MODE=connect -- push --no-verify origin HEAD:refs/heads/s5
skip "S6. --no-verify, the push naming a URL: refused, nothing landed" s6 -- push --no-verify git@github.com:o/r1.git HEAD:refs/heads/s6

echo "--- a clean range passes the transport's scan and lands ---"
git -C "${R}" reset -q --hard origin/main; clean_commit "${R}" c1.md
route "${R}" -- push --no-verify origin HEAD:refs/heads/c1
if [ "${RC}" = 0 ] && [ "$(landed r1 refs/heads/c1)" = "$(git -C "${R}" rev-parse HEAD)" ] && [[ "${OUT}" == *"outbound-scan: CLEAN mode=pre-push"* ]]; then
  ok "C1. clean range, --no-verify, push capability: scanned CLEAN by the transport, landed"
else bad "C1. clean push lands" "rc=${RC} out=${OUT}"; fi
clean_commit "${R}" c2.md
route "${R}" FX_MODE=connect -- push --no-verify origin HEAD:refs/heads/c2
if [ "${RC}" = 0 ] && [ "$(landed r1 refs/heads/c2)" = "$(git -C "${R}" rev-parse HEAD)" ] && [[ "${OUT}" == *"outbound-scan: CLEAN mode=pre-push"* ]]; then
  ok "C2. clean range over the connect capability: scanned CLEAN, landed"
else bad "C2. clean connect push lands" "rc=${RC} out=${OUT}"; fi
route "${R}" -- push origin :refs/heads/c1
if [ "${RC}" = 0 ] && [ -z "$(landed r1 refs/heads/c1)" ]; then ok "C3. a delete-only push passes (nothing to scan) and deletes"
else bad "C3. delete passes" "rc=${RC} out=${OUT}"; fi
route "${R}" FX_MODE=connect -- fetch -q origin
F1="${RC}"
route "${R}" FX_MODE=connect -- ls-remote origin
if [ "${F1}" = 0 ] && [ "${RC}" = 0 ] && [[ "${OUT}" == *"refs/heads/c2"* ]]; then
  ok "C4. fetch and ls-remote from a marked repository are relayed unread and succeed"
else bad "C4. fetch/ls-remote through the scan" "fetch=${F1} rc=${RC} out=${OUT}"; fi
route "${TMP}" FX_MODE=connect -- clone -q https://github.com/o/r1.git "${TMP}/c5-clone"
if [ "${RC}" = 0 ] && [ -f "${TMP}/c5-clone/README" ]; then ok "C5. clone through the route still works"
else bad "C5. clone" "rc=${RC} out=${OUT}"; fi

echo "--- the scan's own bar: the hook's waiver, and COULD NOT MEASURE ---"
plant "${R}" w1.md
route "${R}" ATHENA_OUTBOUND_WAIVE=selftest -- push --no-verify origin HEAD:refs/heads/w1
if [ "${RC}" = 0 ] && [ -n "$(landed r1 refs/heads/w1)" ] && [[ "${OUT}" == *"WAIVED - NOT SCANNED"* ]]; then
  ok "W1. ATHENA_OUTBOUND_WAIVE=<reason> waives the transport's scan exactly as it waives the hook's (printed and logged)"
else bad "W1. waiver" "rc=${RC} out=${OUT}"; fi
route "${R}" ATHENA_PRIVATE_ROOT="${TMP}/no-overlay" -- push --no-verify origin HEAD:refs/heads/w2
if [ "${RC}" != 0 ] && [ -z "$(landed r1 refs/heads/w2)" ] && [[ "${OUT}" == *"COULD NOT MEASURE"* ]] && [[ "${OUT}" == *"Fix:"* ]]; then
  ok "U1. overlay absent on a marked repository: the scan cannot measure, the push is refused"
else bad "U1. unmeasurable refuses" "rc=${RC} out=${OUT}"; fi
route "${R}" -- push --no-verify origin refs/heads/no-such-branch:refs/heads/u2
if [ "${RC}" != 0 ] && [ -z "$(landed r1 refs/heads/u2)" ]; then ok "U2. a source git cannot resolve: refused (git or the transport), nothing landed"
else bad "U2. unresolvable source" "rc=${RC} out=${OUT}"; fi

# A marked repository whose main checkout has no outbound hook script.
R3="$(mk_repo r3 hook)"; rm "${R3}/ai"; mkdir -p "${R3}/ai/bin"; plant "${R3}" n.md
route "${R3}" -- push --no-verify origin HEAD:refs/heads/u3
if [ "${RC}" != 0 ] && [ -z "$(landed r3 refs/heads/u3)" ] && [[ "${OUT}" == *"COULD NOT MEASURE"* ]] && [[ "${OUT}" == *"Fix:"* ]]; then
  ok "U3. the main checkout's outbound-pre-push.sh is missing: refused, nothing landed"
else bad "U3. missing hook script refuses" "rc=${RC} out=${OUT}"; fi

# The scan runs with the ref lines git gives a hook and WITHOUT the bot header.
R4="$(mk_repo r4 hook)"; rm "${R4}/ai"; mkdir -p "${R4}/ai/git-hooks"
cat > "${R4}/ai/git-hooks/outbound-pre-push.sh" <<'EOF'
#!/usr/bin/env bash
hdr=absent; i=0
while [ "${i}" -lt "${GIT_CONFIG_COUNT:-0}" ]; do
  k="GIT_CONFIG_KEY_${i}"; case "${!k}" in *extraheader*) hdr=present ;; esac; i=$((i + 1))
done
case "${GIT_CONFIG_PARAMETERS:-}" in *extraheader*) hdr=present ;; esac
cfg=ok; git config --list >/dev/null 2>&1 || cfg=broken
{ printf 'args=%s hdr=%s cfg=%s\n' "$*" "${hdr}" "${cfg}"; cat; } > "${FX_PROBE}"
exit 0
EOF
chmod +x "${R4}/ai/git-hooks/outbound-pre-push.sh"
clean_commit "${R4}" p.md
route "${R4}" FX_PROBE="${TMP}/probe.out" -- push --no-verify origin HEAD:refs/heads/p1
PROBE="$(cat "${TMP}/probe.out" 2>/dev/null)"
if [ "${RC}" = 0 ] && [[ "${PROBE}" == "args=origin https://github.com/o/r4.git hdr=absent cfg=ok"* ]] \
   && [[ "${PROBE}" == *"HEAD $(git -C "${R4}" rev-parse HEAD) refs/heads/p1 0000000000000000000000000000000000000000"* ]]; then
  ok "P1. the scan gets <remote> <url> and git's pre-push ref lines, with no bot header and a readable config"
else bad "P1. scan input and environment" "rc=${RC} probe=${PROBE} out=${OUT}"; fi

echo "--- an unmarked repository keeps the plain transport ---"
R5="$(mk_repo r5)"; clean_commit "${R5}" m.md
route "${R5}" -- push --no-verify origin HEAD:refs/heads/m1
if [ "${RC}" = 0 ] && [ -n "$(landed r5 refs/heads/m1)" ] && [[ "${OUT}" != *"forge-push-scan"* ]] && [[ "${OUT}" != *"outbound-scan"* ]]; then
  ok "M1. no outbound hook: the push runs on the plain transport, unscanned as before"
else bad "M1. unmarked repository" "rc=${RC} out=${OUT}"; fi
# The hook moved by a core.hooksPath in the repository's own config is still found.
R6="$(mk_repo r6)"; mkdir -p "${R6}/.githooks"; cp "${HOOK}" "${R6}/.githooks/pre-push"
git -C "${R6}" config core.hooksPath "${R6}/.githooks"; plant "${R6}" n.md
route "${R6}" -- -c "core.hooksPath=${TMP}/nohooks" push --no-verify origin HEAD:refs/heads/m2
if [ "${RC}" != 0 ] && [ -z "$(landed r6 refs/heads/m2)" ] && [[ "${OUT}" == *"outbound-scan: HITS"* ]]; then
  ok "M2. hook installed under the repository's core.hooksPath, overridden by -c: still found, refused"
else bad "M2. config-installed hook found" "rc=${RC} out=${OUT}"; fi

echo "--- glab-athena shares the transport ---"
printf 'glpat-SELFTESTFAKETOKEN0000\n' > "${TMP}/glab-token"; chmod 600 "${TMP}/glab-token"
RG="$(mk_repo rg hook)"; git -C "${RG}" remote set-url origin git@gitlab.com:o/rg.git; plant "${RG}" g.md
OUT="$(cd "${RG}" && env PATH="${XPATH}" GITLAB_ATHENA_TOKEN_FILE="${TMP}/glab-token" "${GLAB_WRAPPER}" git push --no-verify origin HEAD:refs/heads/g1 2>&1)"; RC=$?
if [ "${RC}" != 0 ] && [ -z "$(landed rg refs/heads/g1)" ] && [[ "${OUT}" == *"outbound-scan: HITS mode=pre-push"* ]] && no_literal; then
  ok "G1. glab-athena git push --no-verify of the token: refused by the transport's scan"
else bad "G1. glab-athena route" "rc=${RC} out=${OUT}"; fi

echo "--- domain rules (ai/lib/forge_push_scan.rb) ---"
DOUT="$(/usr/bin/ruby "${HERE}/domain-test.rb" 2>&1)"; DRC=$?
[ "${DRC}" = 0 ] || bad "D. domain-test.rb ran" "exit ${DRC}"
while IFS= read -r l; do
  case "${l}" in "ok "*) ok "D. ${l#ok }" ;; *) bad "D. domain" "${l}" ;; esac
done <<< "${DOUT}"

echo "--- --help answers on stdout, exit 0, and does nothing else ---"
HOUT="$("${AI_DIR}/lib/forge-push-scan" --help </dev/null 2>&1)"; HRC=$?
if [ "${HRC}" = 0 ] && [[ "${HOUT}" == *"forge-push-scan --header-index N"* ]]; then ok "H2. forge-push-scan --help"
else bad "H2. --help" "rc=${HRC} out=${HOUT}"; fi

if fsg_verify; then ok "no git call fell through past its shim (DND-1667)"
else bad "a git call fell through past its shim" "see ${FSG_DIR}/fallthrough.log"; fi

echo
printf 'forge-push-scan self-test: %d passed, %d failed\n' "${PASS}" "${FAIL}"
[ "${FAIL}" = 0 ]
