#!/usr/bin/env bash
# Self-test for ai/bin/push-actor-check (DND-397).
#
# The defect this pins: the post-push actor check (GitHub activity / GitLab
# events) can lag a push by a few seconds, so a single read that finds "no event
# for your ref and SHA" is not yet a failure. The helper re-reads for a bounded
# window, sleeping between reads, and keeps three outcomes distinct: the wrong
# actor (1), no event within the window (4), and a read that could not be made
# (3) — a failed read must never look like an empty one.
#
# NO NETWORK: gh/glab are stubs selected through the PUSH_ACTOR_CHECK_GH /
# PUSH_ACTOR_CHECK_GLAB seams. Each stub call N answers from responses/N (or
# responses/default) with the exit code in responses/N.rc (default 0), and logs
# its argv so the test can count reads.
#
# Run against another copy with PUSH_ACTOR_CHECK_UNDER_TEST=/path/to/bin.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AI_DIR="$(cd "${HERE}/../.." && pwd)"
BIN="${PUSH_ACTOR_CHECK_UNDER_TEST:-${AI_DIR}/bin/push-actor-check}"

TMP="$(mktemp -d)"; trap 'rm -rf "${TMP}"' EXIT
PASS=0; FAIL=0
ok()  { printf '  ok    %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  FAIL  %s\n        %s\n' "$1" "$2"; FAIL=$((FAIL+1)); }

export GIT_CONFIG_NOSYSTEM=1
export GIT_CONFIG_GLOBAL="${TMP}/gitconfig"
: > "${GIT_CONFIG_GLOBAL}"

SHA=0123456789abcdef0123456789abcdef01234567
OLD=fedcba9876543210fedcba9876543210fedcba98

# stub <name> : a fake gh/glab answering from ${TMP}/<name>/responses.
stub() {
  local d="${TMP}/$1"
  mkdir -p "${d}/responses"
  cat > "${d}/bin" <<EOF
#!/usr/bin/env bash
d="${d}"
n=\$(( \$(cat "\${d}/count" 2>/dev/null || echo 0) + 1 ))
printf '%s' "\${n}" > "\${d}/count"
printf '%s\n' "\$*" >> "\${d}/argv"
f="\${d}/responses/\${n}"; [ -f "\${f}" ] || f="\${d}/responses/default"
[ -f "\${f}" ] && cat "\${f}"
rc=0; [ -f "\${f}.rc" ] && rc=\$(cat "\${f}.rc")
exit "\${rc}"
EOF
  chmod +x "${d}/bin"
}
reset_stub() { rm -rf "${TMP}/$1"; stub "$1"; }
reads() { cat "${TMP}/$1/count" 2>/dev/null || echo 0; }

gh_event()  { printf '[{"ref":"refs/heads/%s","after":"%s","activity_type":"push","actor":{"login":"%s"}}]' "$1" "$2" "$3"; }
gl_event()  { printf '[{"action_name":"pushed to","author":{"username":"%s"},"push_data":{"ref":"%s","commit_to":"%s"}}]' "$3" "$1" "$2"; }

mkrepo() { git init -q "${TMP}/$1" && git -C "${TMP}/$1" remote add origin "$2"; }
mkrepo repo_gh 'git@github.com:o/r.git'
mkrepo repo_gl 'https://gitlab.com/g/sub/r.git'
mkrepo repo_other 'git@example.com:o/r.git'

# run_in <repo> <args...> : run the helper there; sets OUT and RC.
run_in() {
  local repo=$1; shift
  OUT=$(cd "${TMP}/${repo}" && PUSH_ACTOR_CHECK_GH="${TMP}/gh/bin" PUSH_ACTOR_CHECK_GLAB="${TMP}/glab/bin" \
    "${BIN}" "$@" 2>&1)
  RC=$?
}

expect() {  # expect <label> <rc> [needle]
  if [ "${RC}" -ne "$2" ]; then bad "$1" "rc=${RC} want $2; out=[${OUT}]"; return; fi
  if [ -n "${3:-}" ] && ! grep -qF -- "$3" <<<"${OUT}"; then bad "$1" "missing [$3]; out=[${OUT}]"; return; fi
  ok "$1"
}

echo "push-actor-check self-test"
echo "bin: ${BIN}"
[ -x "${BIN}" ] || { echo "FAIL: ${BIN} not executable"; exit 1; }

# --help: stdout, exit 0, does nothing else.
reset_stub gh
HELP=$("${BIN}" --help 2>/dev/null); RC=$?
if [ "${RC}" -eq 0 ] && grep -q 'Usage:' <<<"${HELP}" && [ "$(reads gh)" = 0 ]; then ok "1. --help on stdout, exit 0, no read"; else bad "1. --help" "rc=${RC} help=[${HELP}]"; fi

# GitHub: bot event on the first read.
reset_stub gh; gh_event feat "${SHA}" 'athena-harness[bot]' > "${TMP}/gh/responses/default"
run_in repo_gh --sha "${SHA}" --window 5 --interval 1 feat
expect "2. github bot event -> 0" 0 'athena-harness[bot]'
grep -qF 'repos/o/r/activity' "${TMP}/gh/argv" && ok "2a. owner/repo parsed from the SSH-form URL" || bad "2a. owner/repo" "$(cat "${TMP}/gh/argv")"
reset_stub gh; gh_event 'a&b#c' "${SHA}" 'athena-harness[bot]' > "${TMP}/gh/responses/default"
run_in repo_gh --sha "${SHA}" --window 5 --interval 1 'a&b#c'
expect "2b. a branch with & and # still matches" 0 'athena-harness[bot]'
grep -qF 'ref=refs%2Fheads%2Fa%26b%23c&' "${TMP}/gh/argv" && ok "2c. the branch is URL-encoded in the query" || bad "2c. query encoding" "$(cat "${TMP}/gh/argv")"

# GitHub: the event appears only on the third read (the lag this exists for).
reset_stub gh
printf '[]' > "${TMP}/gh/responses/1"; printf '[]' > "${TMP}/gh/responses/2"
gh_event feat "${SHA}" 'athena-harness[bot]' > "${TMP}/gh/responses/default"
run_in repo_gh --sha "${SHA}" --window 10 --interval 1 feat
expect "3. lagging event found on a re-read -> 0" 0 'athena-harness[bot]'
[ "$(reads gh)" = 3 ] && ok "3a. exactly three reads" || bad "3a. read count" "reads=$(reads gh)"

# GitHub: a warning on stderr does not spoil a good read; a failure's stderr is reported.
reset_stub gh; gh_event feat "${SHA}" 'athena-harness[bot]' > "${TMP}/gh/responses/default"
sed -i 's#^exit#echo "warning: gh update available" >\&2; exit#' "${TMP}/gh/bin"
run_in repo_gh --sha "${SHA}" --window 5 --interval 1 feat
expect "3b. a stderr warning beside valid JSON -> still 0" 0 'athena-harness[bot]'

# GitHub: the owner is the actor.
reset_stub gh; gh_event feat "${SHA}" 'CJPoll' > "${TMP}/gh/responses/default"
run_in repo_gh --sha "${SHA}" --window 5 --interval 1 feat
expect "4. wrong actor -> 1" 1 'CJPoll'
expect "4a. wrong actor carries Fix:" 1 'Fix:'
[ "$(reads gh)" = 1 ] && ok "4b. a wrong actor is final, not re-read" || bad "4b. reads" "reads=$(reads gh)"

# GitHub: no event for this SHA within the window (only an older SHA's event).
reset_stub gh; gh_event feat "${OLD}" 'athena-harness[bot]' > "${TMP}/gh/responses/default"
run_in repo_gh --sha "${SHA}" --window 2 --interval 1 feat
expect "5. no event for ref+SHA within the window -> 4" 4 'no event'
expect "5a. the miss names the ref and the SHA" 4 "feat ${SHA}"
R=$(reads gh); if [ "${R}" -ge 2 ] && [ "${R}" -le 4 ]; then ok "5b. bounded re-reads (${R})"; else bad "5b. bounded re-reads" "reads=${R}"; fi

# GitHub: every read fails -> 3, never 4.
reset_stub gh; printf 'HTTP 502\n' > "${TMP}/gh/responses/default"; printf '1' > "${TMP}/gh/responses/default.rc"
run_in repo_gh --sha "${SHA}" --window 2 --interval 1 feat
expect "6. every read failed -> 3 (could not read, not 'no event')" 3 'could not read'
expect "6a. carries Fix:" 3 'Fix:'
expect "6b. names the last error" 3 'HTTP 502'

# GitHub: unparseable output is a failed read too.
reset_stub gh; printf 'not json' > "${TMP}/gh/responses/default"
run_in repo_gh --sha "${SHA}" --window 1 --interval 1 feat
expect "7. unparseable response -> 3" 3 'could not read'

# GitLab: bot and owner authors; nested group path is URL-encoded.
reset_stub glab; gl_event feat "${SHA}" 'athena-amby' > "${TMP}/glab/responses/default"
run_in repo_gl --sha "${SHA}" --window 5 --interval 1 feat
expect "8. gitlab bot event -> 0" 0 'athena-amby'
grep -qF 'projects/g%2Fsub%2Fr/events' "${TMP}/glab/argv" && ok "8a. project path URL-encoded" || bad "8a. project path" "$(cat "${TMP}/glab/argv")"
reset_stub glab
printf '[]' > "${TMP}/glab/responses/1"; gl_event feat "${OLD}" 'athena-amby' > "${TMP}/glab/responses/2"
gl_event feat "${SHA}" 'athena-amby' > "${TMP}/glab/responses/default"
run_in repo_gl --sha "${SHA}" --window 10 --interval 1 feat
expect "8b. gitlab lagging event found on the third read -> 0" 0 'athena-amby'
[ "$(reads glab)" = 3 ] && ok "8c. exactly three gitlab reads" || bad "8c. gitlab read count" "reads=$(reads glab)"
reset_stub glab; gl_event feat "${SHA}" 'cjpoll' > "${TMP}/glab/responses/default"
run_in repo_gl --sha "${SHA}" --window 5 --interval 1 feat
expect "9. gitlab wrong author -> 1" 1 'cjpoll'

# Usage errors.
run_in repo_other --sha "${SHA}" feat
expect "10. a remote on neither forge -> 2" 2 'Fix:'
git -C "${TMP}/repo_other" remote set-url origin 'https://user:s3cr3t@example.com/o/r.git'
run_in repo_other --sha "${SHA}" feat
if [ "${RC}" -eq 2 ] && ! grep -qF 's3cr3t' <<<"${OUT}"; then ok "10a. a credential in the remote URL is never printed"; else bad "10a. credential leak" "rc=${RC} out=[${OUT}]"; fi
run_in repo_gh --sha "${SHA}" --interval 0 feat
expect "11. --interval below 1 is refused (no spinning) -> 2" 2 'Fix:'
run_in repo_gh --sha "${SHA}" --window 301 feat
expect "12. --window above the cap is refused -> 2" 2 'Fix:'
run_in repo_gh --sha "${SHA}"
expect "13. no branch -> 2" 2 'Fix:'
reset_stub gh; gh_event feat "${OLD}" 'athena-harness[bot]' > "${TMP}/gh/responses/default"
run_in repo_gh --sha "${SHA}" --window 08 --interval 09 feat
expect "13a. leading-zero numbers are decimal, never an octal abort read as exit 1" 4 'no event'
OUT=$(cd "${TMP}" && "${BIN}" --sha "${SHA}" feat 2>&1); RC=$?
expect "14. not in a git repo -> 2" 2 'Fix:'

echo
printf 'RESULT: %d passed, %d failed\n' "${PASS}" "${FAIL}"
[ "${FAIL}" -eq 0 ] || exit 1
echo "ALL CASES PASS"
