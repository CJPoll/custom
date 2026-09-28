#!/usr/bin/env bash
# Self-test for ai/bin/outbound-scan and its pre-push hook (DND-699).
#
# The defect this pins: a push to the PUBLIC ~/dev/custom repo that carries a
# work-domain value (a colleague's Slack id, a work ticket id) goes out, and
# nothing says so. Case 1 records that BEFORE state on a fixture repo with no
# hook; every later case runs the hook as git runs it.
#
# The design's QA table (cases 1-12; case 11, the gh-athena body scan, is
# ai/test/gh-athena-outbound/self-test.sh; case 13, tree mode at 0 hits in the
# gate, waits for DND-704/705/706) plus the parser and state edges.
#
# Hermetic: fixture repos and a fixture overlay under mktemp -d, a fake HOME,
# GIT_ALLOW_PROTOCOL=file, the global/system git config replaced. Synthetic
# values only (SYNTH-TOKEN-1, UFAKE00001). The real overlay directory is never
# read and no real hook is installed: the hook is copied into FIXTURE repos'
# .git/hooks only.
#
# Run another copy of the scanner (old-vs-new evidence) with
#   OUTBOUND_SCAN_UNDER_TEST=/path/to/outbound-scan bash ai/test/outbound-scan/self-test.sh
# (the hook cases always run the fixture main checkout's scanner, which links
# to this checkout's ai/).
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT="$(cd "${HERE}/../../.." && pwd -P)"
SCAN="${OUTBOUND_SCAN_UNDER_TEST:-${ROOT}/ai/bin/outbound-scan}"
HOOK="${ROOT}/ai/git-hooks/outbound-pre-push.sh"

TMP="$(mktemp -d)" || { echo "FAIL: mktemp"; exit 1; }
trap 'rm -rf "${TMP}"' EXIT INT TERM
PASS=0; FAIL=0
ok()  { printf '  ok    %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  FAIL  %s\n        %s\n' "$1" "$2"; FAIL=$((FAIL+1)); }

TOKEN="SYNTH-TOKEN-1"
PERSON="UFAKE00001"

# ---- hermetic environment ---------------------------------------------------
for v in $(env | sed -n 's/^\(GIT_CONFIG_\(KEY\|VALUE\)_[0-9]*\)=.*/\1/p'); do unset "$v"; done
unset GIT_CONFIG_COUNT GIT_CONFIG_PARAMETERS GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR \
  ATHENA_OUTBOUND_WAIVE ATHENA_PRIVATE_ROOT XDG_STATE_HOME
export HOME="${TMP}/home"; mkdir -p "${HOME}"
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL="${TMP}/gitconfig"
printf '[user]\n\tname = t\n\temail = t@t\n[init]\n\tdefaultBranch = main\n[advice]\n\tdetachedHead = false\n' > "${GIT_CONFIG_GLOBAL}"
export GIT_ALLOW_PROTOCOL=file GIT_TERMINAL_PROMPT=0 GIT_SSH_COMMAND=false

# ---- fixtures -----------------------------------------------------------------
# mk_overlay <dir> <committed patterns> [working-tree patterns] : a git-backed overlay.
mk_overlay() {
  local d="$1"
  mkdir -p "${d}/outbound" && chmod 700 "${d}"
  printf '{"kind":"athena-private-overlay","schema":1}\n' > "${d}/athena-overlay.json"
  printf '%b' "$2" > "${d}/outbound/patterns.tsv"
  git -C "${d}" init -q && git -C "${d}" add -A && git -C "${d}" commit -q -m overlay
  if [ $# -ge 3 ]; then printf '%b' "$3" > "${d}/outbound/patterns.tsv"; fi
}
PATTERNS='# synthetic fixture patterns\nsynth-token\tSYNTH-TOKEN-[0-9]+\nslack-person-1\tUFAKE0000[0-9]\n'
OVERLAY="${TMP}/overlay"; mk_overlay "${OVERLAY}" "${PATTERNS}"
export ATHENA_PRIVATE_ROOT="${OVERLAY}"

# mk_public <name> [hook] : bare remote + a main checkout with ai/ linked to this
# checkout's ai/ (untracked), optionally with the hook installed. Echoes the path.
mk_public() {
  local name="$1" hook="${2:-}"
  local bare="${TMP}/${name}.git" m="${TMP}/${name}"
  git init -q --bare "${bare}"
  git init -q "${m}"
  git -C "${m}" remote add origin "${bare}"
  printf 'hello\n' > "${m}/README"
  git -C "${m}" add README && git -C "${m}" commit -q -m init
  git -C "${m}" push -q origin main 2>/dev/null
  ln -s "${ROOT}/ai" "${m}/ai"
  printf 'ai\n' >> "${m}/.git/info/exclude"
  if [ -n "${hook}" ]; then cp "${HOOK}" "${m}/.git/hooks/pre-push" && chmod +x "${m}/.git/hooks/pre-push"; fi
  printf '%s' "${m}"
}

# commit_file <repo> <path> <content> <message>
commit_file() {
  mkdir -p "$(dirname "$1/$2")"
  printf '%b' "$3" > "$1/$2"
  git -C "$1" add -- "$2" && git -C "$1" commit -q -m "$(printf '%b' "$4")"
}

# push <repo> <args...> -> OUT (stdout+stderr), RC
push() {
  local r="$1"; shift
  OUT="$(git -C "${r}" push origin "$@" 2>&1)"; RC=$?
}

no_literal() { [[ "${OUT}" != *"${TOKEN}"* ]] && [[ "${OUT}" != *"${PERSON}"* ]]; }

echo "outbound-scan self-test"
echo "scanner: ${SCAN}"
echo

echo "--- 1: fail-first: with no hook, a push carrying the token succeeds (BEFORE) ---"
P0="$(mk_public p0)"
commit_file "${P0}" notes.md "line one\ncontact ${TOKEN}\n" "add notes"
push "${P0}" main
if [ "${RC}" = 0 ]; then ok "1 BEFORE: unguarded push of the token succeeded (rc=0)"; else bad "1 BEFORE" "rc=${RC} ${OUT}"; fi

echo "--- 2: hook installed: the same push is refused with file:line + label, no literal ---"
P="$(mk_public p1 hook)"
commit_file "${P}" notes.md "line one\ncontact ${TOKEN}\n" "add notes"
push "${P}" main
if [ "${RC}" != 0 ] && [[ "${OUT}" == *"outbound-scan: HITS mode=pre-push"* ]] \
   && [[ "${OUT}" == *"notes.md:2 (commit "*"label=synth-token"* ]] && [[ "${OUT}" == *"Fix:"* ]] \
   && [[ "${OUT}" == *"SCANNED commits=1 "*"patterns=2 hits=1"* ]] && no_literal; then
  ok "2 refused with location + label"
else
  bad "2 refused with location + label" "rc=${RC} ${OUT}"
fi
[ -z "$(git -C "${TMP}/p1.git" log --oneline main -- notes.md 2>/dev/null)" ] \
  && ok "2 the remote never received the commit" || bad "2 remote untouched" "$(git -C "${TMP}/p1.git" log --oneline main)"
git -C "${P}" reset -q --hard origin/main

echo "--- 3: token only in the commit message ---"
commit_file "${P}" clean.md "nothing here\n" "subject line\n\nrelates to ${PERSON}"
push "${P}" main
if [ "${RC}" != 0 ] && [[ "${OUT}" =~ commit\ [0-9a-f]{12}\ message:3\ label=slack-person-1 ]] && no_literal; then
  ok "3 message hit: commit <sha> message:3"
else
  bad "3 message hit" "rc=${RC} ${OUT}"
fi
git -C "${P}" reset -q --hard origin/main

echo "--- 4: token in a new file path: refused, path redacted ---"
commit_file "${P}" "people/${PERSON}.md" "plain\n" "add a file"
push "${P}" main
if [ "${RC}" != 0 ] && [[ "${OUT}" =~ commit\ [0-9a-f]{12}\ path\ \<redacted\>\ label=slack-person-1 ]] && no_literal; then
  ok "4 path hit, path never printed"
else
  bad "4 path hit" "rc=${RC} ${OUT}"
fi
git -C "${P}" reset -q --hard origin/main
commit_file "${P}" "docs/${PERSON}/x.md" "and ${TOKEN}\n" "both"
push "${P}" main
if [ "${RC}" != 0 ] && [[ "${OUT}" == *"<path redacted: it matches a pattern>:1 (commit "*"label=synth-token"* ]] && no_literal; then
  ok "4b a content hit inside a matching path redacts the path"
else
  bad "4b redacted content location" "rc=${RC} ${OUT}"
fi
git -C "${P}" reset -q --hard origin/main

echo "--- 5: overlay absent, hook installed: refused as COULD NOT MEASURE ---"
commit_file "${P}" clean.md "nothing here\n" "clean change"
OUT="$(env -u ATHENA_PRIVATE_ROOT git -C "${P}" push origin main 2>&1)"; RC=$?
if [ "${RC}" != 0 ] && [[ "${OUT}" == *"COULD NOT MEASURE mode=pre-push: overlay is ABSENT (probed ${HOME}/.config/athena/work)"* ]] \
   && [[ "${OUT}" == *"NOT SCANNED"* ]] && [[ "${OUT}" != *"CLEAN"* ]] && [[ "${OUT}" != *"SCANNED commits"* ]] \
   && [[ "${OUT}" == *"Fix:"* ]]; then
  ok "5 absent overlay refuses the push"
else
  bad "5 absent overlay" "rc=${RC} ${OUT}"
fi

echo "--- 6: overlay malformed / no floor / zero patterns: exit 3 naming which ---"
# scan_state <label> <overlay-root> <needle>: run --text directly against a fixture overlay.
printf 'a clean line\n' > "${TMP}/clean.txt"
scan_state() {
  local label="$1" root="$2" needle="$3"
  OUT="$(ATHENA_PRIVATE_ROOT="${root}" "${SCAN}" --text "${TMP}/clean.txt" 2>&1)"; RC=$?
  if [ "${RC}" = 3 ] && [[ "${OUT}" == *"COULD NOT MEASURE mode=text: "*"${needle}"* ]] && [[ "${OUT}" == *"Fix:"* ]] \
     && [[ "${OUT}" != *"CLEAN"* ]]; then
    ok "6 ${label}"
  else
    bad "6 ${label}" "rc=${RC} ${OUT}"
  fi
}
M1="${TMP}/ov-malformed"; mk_overlay "${M1}" "${PATTERNS}"; printf '{"kind":"nope","schema":1}' > "${M1}/athena-overlay.json"
scan_state "malformed marker" "${M1}" "overlay is MALFORMED: marker athena-overlay.json has kind other than"
M2="${TMP}/ov-empty"; mk_overlay "${M2}" "# only a comment\n"
scan_state "zero patterns" "${M2}" "overlay at $(cd "${M2}" && pwd -P) has zero patterns"
M3="${TMP}/ov-nogit"; mkdir -p "${M3}/outbound" && chmod 700 "${M3}"
printf '{"kind":"athena-private-overlay","schema":1}\n' > "${M3}/athena-overlay.json"; printf "${PATTERNS}" > "${M3}/outbound/patterns.tsv"
scan_state "not a git repo" "${M3}" "is not a git repository of its own"
M4="${TMP}/ov-nocommit"; mkdir -p "${M4}/outbound" && chmod 700 "${M4}"
printf '{"kind":"athena-private-overlay","schema":1}\n' > "${M4}/athena-overlay.json"; printf "${PATTERNS}" > "${M4}/outbound/patterns.tsv"
git -C "${M4}" init -q
scan_state "no commits" "${M4}" "has no commits"
M5="${TMP}/ov-uncommitted"; mk_overlay "${M5}" ""; git -C "${M5}" rm -q outbound/patterns.tsv; git -C "${M5}" commit -q -m drop
mkdir -p "${M5}/outbound"; printf "${PATTERNS}" > "${M5}/outbound/patterns.tsv"
scan_state "patterns only in the working tree (no committed floor)" "${M5}" "has no committed outbound/patterns.tsv"
M6="${TMP}/ov-badline"; mk_overlay "${M6}" "good\tSYNTH\nno-tab-here\n"
scan_state "a line with no TAB" "${M6}" "committed HEAD:outbound/patterns.tsv line 2 has no TAB"
M7="${TMP}/ov-badre"; mk_overlay "${M7}" "bad-re\t(unclosed\n"
scan_state "a regex that does not compile" "${M7}" "line 1 has a regex that does not compile"
M8="${TMP}/ov-badlabel"; mk_overlay "${M8}" "Bad Label\tx\n"
scan_state "a bad label" "${M8}" "line 1 has a label that is not"
M9="${TMP}/ov-badwt"; mk_overlay "${M9}" "${PATTERNS}" "${PATTERNS}broken-line\n"
scan_state "a broken working-tree line" "${M9}" "working-tree outbound/patterns.tsv line 4 has no TAB"

echo "--- 7: a pattern deleted in the overlay's working tree still applies (union with HEAD) ---"
U="${TMP}/ov-union"; mk_overlay "${U}" "${PATTERNS}" "slack-person-1\tUFAKE0000[0-9]\n"
printf 'see %s\n' "${TOKEN}" > "${TMP}/t7.txt"
OUT="$(ATHENA_PRIVATE_ROOT="${U}" "${SCAN}" --text "${TMP}/t7.txt" --label body 2>&1)"; RC=$?
if [ "${RC}" = 1 ] && [[ "${OUT}" == *"body:1 label=synth-token"* ]] && no_literal; then ok "7 committed pattern survives a working-tree delete"; else bad "7 union" "rc=${RC} ${OUT}"; fi
U2="${TMP}/ov-add"; mk_overlay "${U2}" "slack-person-1\tUFAKE0000[0-9]\n" "slack-person-1\tUFAKE0000[0-9]\nsynth-token\tSYNTH-TOKEN-[0-9]+\n"
OUT="$(ATHENA_PRIVATE_ROOT="${U2}" "${SCAN}" --text "${TMP}/t7.txt" 2>&1)"; RC=$?
if [ "${RC}" = 1 ] && [[ "${OUT}" == *"text:1 label=synth-token"* ]] && [[ "${OUT}" == *"patterns=2 "* ]]; then ok "7b an uncommitted added pattern applies too"; else bad "7b union add" "rc=${RC} ${OUT}"; fi

echo "--- 8: a clean change pushes, with counts ---"
push "${P}" main
if [ "${RC}" = 0 ] && [[ "${OUT}" == *"outbound-scan: CLEAN mode=pre-push"* ]] && [[ "${OUT}" == *"SCANNED commits=1 lines="*" patterns=2 hits=0"* ]]; then
  ok "8 clean push succeeds and prints SCANNED"
else
  bad "8 clean push" "rc=${RC} ${OUT}"
fi

echo "--- 9: waiver: allowed, WAIVED - NOT SCANNED, logged, never CLEAN ---"
commit_file "${P}" waived.md "carry ${TOKEN}\n" "waived change"
OUT="$(XDG_STATE_HOME="${TMP}/state" ATHENA_OUTBOUND_WAIVE="synthetic test waiver" git -C "${P}" push origin main 2>&1)"; RC=$?
LOG="${TMP}/state/athena/outbound-scan-waivers.log"
if [ "${RC}" = 0 ] && [[ "${OUT}" == *"WAIVED - NOT SCANNED mode=pre-push reason=synthetic test waiver"* ]] \
   && [[ "${OUT}" != *"CLEAN"* ]] && [[ "${OUT}" != *"SCANNED commits"* ]] && no_literal \
   && grep -q "pre-push.*synthetic test waiver" "${LOG}" 2>/dev/null; then
  ok "9 waiver allowed, printed, logged"
else
  bad "9 waiver" "rc=${RC} ${OUT} log=$(cat "${LOG}" 2>&1)"
fi
OUT="$(ATHENA_OUTBOUND_WAIVE="" "${SCAN}" --text "${TMP}/clean.txt" 2>&1)"; RC=$?
if [ "${RC}" = 2 ] && [[ "${OUT}" == *"a waiver needs a reason"* ]]; then ok "9b empty waiver refused"; else bad "9b empty waiver" "rc=${RC} ${OUT}"; fi
# The state "directory" is a regular file, so the log cannot be written.
: > "${TMP}/ro-file"
OUT="$(XDG_STATE_HOME="${TMP}/ro-file" ATHENA_OUTBOUND_WAIVE="x" "${SCAN}" --text "${TMP}/clean.txt" 2>&1)"; RC=$?
if [ "${RC}" = 3 ] && [[ "${OUT}" == *"could not be recorded"* ]] && [[ "${OUT}" != *"WAIVED - NOT SCANNED"* ]]; then
  ok "9c an unrecordable waiver is refused"
else
  bad "9c unrecordable waiver" "rc=${RC} ${OUT}"
fi

echo "--- 10: a push from a linked worktree runs the shared hook and the main checkout's scanner ---"
W="${TMP}/wt"
git -C "${P}" worktree add -q -b feature "${W}" main
commit_file "${W}" wt.md "from a worktree ${TOKEN}\n" "worktree change"
OUT="$(git -C "${W}" push origin feature 2>&1)"; RC=$?
if [ "${RC}" != 0 ] && [[ "${OUT}" == *"wt.md:1 (commit "*"label=synth-token"* ]] && [[ "${OUT}" == *"SCANNED commits=1 "* ]] && no_literal; then
  ok "10 worktree push refused; only the new commit scanned"
else
  bad "10 worktree push" "rc=${RC} ${OUT}"
fi
mv "${P}/ai" "${P}/ai.off"
OUT="$(git -C "${W}" push origin feature 2>&1)"; RC=$?
mv "${P}/ai.off" "${P}/ai"
if [ "${RC}" != 0 ] && [[ "${OUT}" == *"outbound-pre-push: COULD NOT MEASURE: the main checkout's scanner"* ]] && [[ "${OUT}" == *"Fix:"* ]]; then
  ok "10b no scanner in the main checkout: the hook refuses"
else
  bad "10b hook without scanner" "rc=${RC} ${OUT}"
fi

echo "--- 12: tree mode ---"
T="$(mk_public tree)"
commit_file "${T}" a/b.md "one\ntwo ${TOKEN}\n" "tree fixture"
OUT="$(cd "${T}" && "${SCAN}" --tree 2>&1)"; RC=$?
if [ "${RC}" = 1 ] && [[ "${OUT}" == *"outbound-scan: HITS mode=tree"* ]] && [[ "${OUT}" == *"a/b.md:2 label=synth-token"* ]] \
   && [[ "${OUT}" == *"hits=1"* ]] && no_literal; then
  ok "12 tree mode reports hits > 0 (count only)"
else
  bad "12 tree hits" "rc=${RC} ${OUT}"
fi
T2="$(mk_public tree2)"
OUT="$(cd "${T2}" && "${SCAN}" --tree 2>&1)"; RC=$?
if [ "${RC}" = 0 ] && [[ "${OUT}" == *"outbound-scan: CLEAN mode=tree"* ]] && [[ "${OUT}" == *"hits=0"* ]]; then ok "12b clean tree"; else bad "12b clean tree" "rc=${RC} ${OUT}"; fi
OUT="$(cd "${TMP}" && "${SCAN}" --tree 2>&1)"; RC=$?
if [ "${RC}" = 3 ] && [[ "${OUT}" == *"COULD NOT MEASURE mode=tree: git could not find the repository top level"* ]]; then ok "12c tree outside a repo is COULD NOT MEASURE"; else bad "12c tree outside a repo" "rc=${RC} ${OUT}"; fi

echo "--- parser edges ---"
E="$(mk_public edges)"
commit_file "${E}" plus.md "++ ${TOKEN}\n" "a line that looks like a diff header"
OUT="$(cd "${E}" && printf 'refs/heads/main %s refs/heads/main %s\n' "$(git rev-parse HEAD)" "$(git rev-parse origin/main)" | "${SCAN}" --pre-push --remote origin 2>&1)"; RC=$?
if [ "${RC}" = 1 ] && [[ "${OUT}" == *"plus.md:1 (commit "* ]] && no_literal; then ok "an added '++ ' line is content, not a header"; else bad "'++ ' line" "rc=${RC} ${OUT}"; fi
OUT="$(cd "${E}" && printf 'refs/heads/gone 0000000000000000000000000000000000000000 refs/heads/gone %s\n' "$(git rev-parse origin/main)" | "${SCAN}" --pre-push --remote origin 2>&1)"; RC=$?
if [ "${RC}" = 0 ] && [[ "${OUT}" == *"SCANNED commits=0 "* ]]; then ok "a deletion-only push scans zero commits"; else bad "deletion-only push" "rc=${RC} ${OUT}"; fi
OUT="$(cd "${E}" && printf 'garbage\n' | "${SCAN}" --pre-push --remote origin 2>&1)"; RC=$?
if [ "${RC}" = 3 ] && [[ "${OUT}" == *"pre-push stdin line 1 is not"* ]]; then ok "malformed pre-push stdin is COULD NOT MEASURE"; else bad "malformed stdin" "rc=${RC} ${OUT}"; fi
OUT="$(cd "${E}" && printf 'refs/heads/x %s refs/heads/x %s\n' "$(git rev-parse HEAD)" "1111111111111111111111111111111111111111" | "${SCAN}" --pre-push --remote origin 2>&1)"; RC=$?
if [ "${RC}" = 1 ] && [[ "${OUT}" == *"commits=1 "* ]]; then ok "an unknown remote tip falls back to 'not on any origin ref'"; else bad "unknown remote tip" "rc=${RC} ${OUT}"; fi
R="${TMP}/rootrepo"; git init -q "${R}"; printf 'root %s\n' "${TOKEN}" > "${R}/f"; git -C "${R}" add f; git -C "${R}" commit -q -m root
OUT="$(cd "${R}" && printf 'refs/heads/main %s refs/heads/main 0000000000000000000000000000000000000000\n' "$(git rev-parse HEAD)" | "${SCAN}" --pre-push --remote /some/url 2>&1)"; RC=$?
if [ "${RC}" = 1 ] && [[ "${OUT}" == *"f:1 (commit "* ]]; then ok "a root commit's diff is scanned"; else bad "root commit" "rc=${RC} ${OUT}"; fi

echo "--- the pushed commit cannot opt its own content out (critic round 5) ---"
GA="$(mk_public gattr)"
mkdir -p "${GA}/d"
printf '*.md -diff\n' > "${GA}/.gitattributes"
printf 'carry %s\n' "${TOKEN}" > "${GA}/d/n.md"
git -C "${GA}" add .gitattributes d/n.md && git -C "${GA}" commit -q -m "attrs and content"
prepush_head() {
  OUT="$(cd "$1" && printf 'refs/heads/main %s refs/heads/main %s\n' "$(git rev-parse HEAD)" "$(git rev-parse origin/main)" | "${SCAN}" --pre-push --remote origin 2>&1)"; RC=$?
}
prepush_head "${GA}"
if [ "${RC}" = 1 ] && [[ "${OUT}" == *"d/n.md:1 (commit "*"label=synth-token"* ]] && no_literal; then
  ok "a '-diff' .gitattributes in the pushed commit does not hide its content"
else
  bad "gitattributes opt-out" "rc=${RC} ${OUT}"
fi
printf 'bin\0ary %s\n' "${TOKEN}" > "${GA}/blob.dat"
git -C "${GA}" add blob.dat && git -C "${GA}" commit -q -m blob
prepush_head "${GA}"
if [ "${RC}" = 1 ] && [[ "${OUT}" == *"blob.dat:1 (commit "* ]] && no_literal; then ok "content with a NUL is scanned in a push"; else bad "NUL push" "rc=${RC} ${OUT}"; fi
OUT="$(cd "${GA}" && "${SCAN}" --tree 2>&1)"; RC=$?
if [ "${RC}" = 1 ] && [[ "${OUT}" == *"blob.dat:1 label=synth-token"* ]] && no_literal; then ok "content with a NUL is scanned in --tree"; else bad "NUL tree" "rc=${RC} ${OUT}"; fi

echo "--- a matching path is never printed, whatever its encoding or status (critic round 5) ---"
NA="$(mk_public nonascii)"
commit_file "${NA}" "docs/café-${PERSON}/x.md" "and ${TOKEN}\n" "non-ascii matching dir"
prepush_head "${NA}"
if [ "${RC}" = 1 ] && [[ "${OUT}" == *"<path redacted: it matches a pattern>:1 (commit "* ]] && no_literal; then
  ok "a non-ASCII matching path is redacted in a content hit"
else
  bad "non-ASCII redaction" "rc=${RC} ${OUT}"
fi
git -C "${NA}" push -q origin main 2>/dev/null   # now public; the next commit only MODIFIES it
commit_file "${NA}" "docs/café-${PERSON}/x.md" "and ${TOKEN}\nagain ${TOKEN}\n" "modify"
prepush_head "${NA}"
if [ "${RC}" = 1 ] && [[ "${OUT}" == *"<path redacted: it matches a pattern>:2 (commit "* ]] && no_literal; then
  ok "a matching path on a MODIFIED file is redacted too"
else
  bad "modified-path redaction" "rc=${RC} ${OUT}"
fi

echo "--- review floor: each pattern matches on its own; errors never quote a pattern ---"
BR="${TMP}/ov-backref"; mk_overlay "${BR}" 'first\t(x)\\1\nsecond\t(q)\\1\n'
printf 'qq\n' > "${TMP}/qq.txt"
QQ="$(mk_public qq)"; commit_file "${QQ}" q.md "qq\n" "qq"
OUT="$(cd "${QQ}" && ATHENA_PRIVATE_ROOT="${BR}" "${SCAN}" --tree 2>&1)"; RC=$?
if [ "${RC}" = 1 ] && [[ "${OUT}" == *"q.md:1 label=second"* ]]; then ok "a backreference in a later pattern still matches (tree)"; else bad "backreference tree" "rc=${RC} ${OUT}"; fi
OUT="$(cd "${QQ}" && printf 'refs/heads/main %s refs/heads/main %s\n' "$(git rev-parse HEAD)" "$(git rev-parse origin/main)" | ATHENA_PRIVATE_ROOT="${BR}" "${SCAN}" --pre-push --remote origin 2>&1)"; RC=$?
if [ "${RC}" = 1 ] && [[ "${OUT}" == *"q.md:1 (commit "*"label=second"* ]]; then ok "a backreference in a later pattern still matches (pre-push)"; else bad "backreference push" "rc=${RC} ${OUT}"; fi
MX="${TMP}/ov-mixed"; mk_overlay "${MX}" 'mixed\t(?<n>SYNTHSECRETX)(y)\\1\n'
OUT="$(ATHENA_PRIVATE_ROOT="${MX}" "${SCAN}" --text "${TMP}/qq.txt" 2>&1)"; RC=$?
if [ "${RC}" = 3 ] && [[ "${OUT}" != *"SYNTHSECRETX"* ]] && [[ "${OUT}" == *"line 1 has a regex that does not compile"* ]]; then ok "a pattern error never prints the pattern"; else bad "pattern error quoting" "rc=${RC} ${OUT}"; fi

echo "--- review floor: --tree judges the tracked (index) copy ---"
IX="$(mk_public index)"
commit_file "${IX}" held.md "held ${TOKEN}\n" "tracked value"
printf 'edited away\n' > "${IX}/held.md"   # working tree only, not staged
OUT="$(cd "${IX}" && "${SCAN}" --tree 2>&1)"; RC=$?
if [ "${RC}" = 1 ] && [[ "${OUT}" == *"held.md:1 label=synth-token"* ]]; then ok "an unstaged removal does not hide the tracked copy"; else bad "index copy" "rc=${RC} ${OUT}"; fi

echo "--- review floor: a path with a space is redacted under an anchored pattern ---"
AN="${TMP}/ov-anchored"; mk_overlay "${AN}" "${PATTERNS}anchored-path\tSYNTHPATH\\\\.md\$\n"
SP="$(mk_public space)"
commit_file "${SP}" "sp ace/SYNTHPATH.md" "and ${TOKEN}\n" "space path"
OUT="$(cd "${SP}" && printf 'refs/heads/main %s refs/heads/main %s\n' "$(git rev-parse HEAD)" "$(git rev-parse origin/main)" | ATHENA_PRIVATE_ROOT="${AN}" "${SCAN}" --pre-push --remote origin 2>&1)"; RC=$?
if [ "${RC}" = 1 ] && [[ "${OUT}" != *"SYNTHPATH"* ]] && [[ "${OUT}" == *"<path redacted: it matches a pattern>:1"* ]]; then ok "anchored path pattern redacts a spaced path"; else bad "spaced path" "rc=${RC} ${OUT}"; fi

echo "--- review floor: a push by URL uses that remote's tracking refs ---"
UR="$(mk_public byurl)"
commit_file "${UR}" u.md "clean\n" "one new commit"
URL="$(git -C "${UR}" remote get-url origin)"
OUT="$(cd "${UR}" && printf 'refs/heads/main %s refs/heads/main 0000000000000000000000000000000000000000\n' "$(git rev-parse HEAD)" | "${SCAN}" --pre-push --remote "${URL}" --url "${URL}" 2>&1)"; RC=$?
if [ "${RC}" = 0 ] && [[ "${OUT}" == *"SCANNED commits=1 "* ]]; then ok "URL remote mapped to origin: only the new commit"; else bad "URL remote" "rc=${RC} ${OUT}"; fi

echo "--- merges: only what differs from every parent is new ---"
MG="$(mk_public merges)"
git -C "${MG}" checkout -q -b feature
commit_file "${MG}" feature.md "clean feature\n" "feature work"
git -C "${MG}" checkout -q main
commit_file "${MG}" public.md "already public ${TOKEN}\n" "main carries it"
git -C "${MG}" push -q origin main 2>/dev/null   # no hook here: it is now public history
git -C "${MG}" checkout -q feature
git -C "${MG}" merge -q --no-edit main
prepush_feature() {
  OUT="$(cd "${MG}" && printf 'refs/heads/feature %s refs/heads/feature 0000000000000000000000000000000000000000\n' "$(git rev-parse HEAD)" | "${SCAN}" --pre-push --remote origin 2>&1)"; RC=$?
}
prepush_feature
if [ "${RC}" = 0 ] && [[ "${OUT}" == *"SCANNED commits=2 "* ]]; then
  ok "a merge that brings in already-public content is CLEAN"
else
  bad "clean merge" "rc=${RC} ${OUT}"
fi
git -C "${MG}" reset -q --hard HEAD~1
git -C "${MG}" merge -q --no-commit main 2>/dev/null
printf 'resolved with %s\n' "${TOKEN}" >> "${MG}/feature.md"
git -C "${MG}" add feature.md && git -C "${MG}" commit -q --no-edit
prepush_feature
if [ "${RC}" = 1 ] && [[ "${OUT}" == *"feature.md:2 (commit "*"label=synth-token"* ]] && [[ "${OUT}" == *"hits=1"* ]] && no_literal; then
  ok "text a merge adds itself (in no parent) is a hit"
else
  bad "evil merge" "rc=${RC} ${OUT}"
fi

echo "--- usage and --help ---"
for args in "" "--tree --text x" "--pre-push" "--tree --remote o" "--text x --label BAD" "--bogus"; do
  # shellcheck disable=SC2086
  OUT="$("${SCAN}" ${args} </dev/null 2>&1)"; RC=$?
  if [ "${RC}" = 2 ] && [[ "${OUT}" == *"USAGE"* ]] && [[ "${OUT}" == *"Fix:"* ]]; then ok "usage '${args}'"; else bad "usage '${args}'" "rc=${RC} ${OUT}"; fi
done
: > "${TMP}/err"; before="$(find "${TMP}" | sort | md5sum)"
OUT="$(cd "${TMP}" && env -u ATHENA_PRIVATE_ROOT "${SCAN}" --help 2>"${TMP}/err")"; RC=$?
after="$(find "${TMP}" | sort | md5sum)"
if [ "${RC}" = 0 ] && [[ "${OUT}" == *"Usage:"* ]] && [ ! -s "${TMP}/err" ] && [ "${before}" = "${after}" ]; then ok "--help"; else bad "--help" "rc=${RC}"; fi
OUT="$("${HOOK}" --help 2>&1)"; RC=$?
if [ "${RC}" = 0 ] && [[ "${OUT}" == *"pre-push hook"* ]]; then ok "hook --help"; else bad "hook --help" "rc=${RC} ${OUT}"; fi

echo
echo "outbound-scan self-test: ${PASS} passed, ${FAIL} failed"
[ "${FAIL}" -eq 0 ]
