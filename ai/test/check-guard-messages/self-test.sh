#!/usr/bin/env bash
# Self-test for ai/bin/check-guard-messages (DND-218) -- discovered and run by
# harness-gate.
#
# The defect this pins: the checker scanned only ai/hooks/*.sh plus a hand-kept
# GUARD_BINS list. A bare-failure guard anywhere else -- scripts/, an ai/bin
# tool nobody listed, a skill's bin/ -- was never read, and the checker still
# printed OK. A check whose scope silently excludes a directory reports success
# for files it never looked at.
#
# Every case builds a throwaway git repo, copies the checker under test into
# its ai/bin/, and runs it there. The checker resolves its repo from its own
# location, so it measures the fixture and never the live tree. That makes
# this suite black-box: it runs unchanged against the pre-fix checker, which
# is how the fail-first evidence was recorded:
#
#   CHECK_GUARD_MESSAGES_UNDER_TEST=/path/to/old/check-guard-messages \
#     ai/test/check-guard-messages/self-test.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AI_DIR="$(cd "${HERE}/../.." && pwd)"
BIN="${CHECK_GUARD_MESSAGES_UNDER_TEST:-${AI_DIR}/bin/check-guard-messages}"

if [ ! -f "${BIN}" ]; then
  echo "check-guard-messages self-test: FAIL -- ${BIN} does not exist" >&2
  echo "Fix: point CHECK_GUARD_MESSAGES_UNDER_TEST at a real checker, or restore ai/bin/check-guard-messages." >&2
  exit 1
fi

TMP="$(mktemp -d)"; trap 'rm -rf "${TMP}"' EXIT
PASS=0; FAIL=0
ok()  { printf '  ok    %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  FAIL  %s\n        %s\n' "$1" "$2"; FAIL=$((FAIL+1)); }

export GIT_CONFIG_NOSYSTEM=1
export GIT_CONFIG_GLOBAL="${TMP}/gitconfig"
: > "${GIT_CONFIG_GLOBAL}"

TAB="$(printf '\t')"

# new_fixture <name>: a git repo holding the checker, one compliant hook, and
# an empty classification table. Prints its path.
new_fixture() {
  local root="${TMP}/$1"
  mkdir -p "${root}/ai/bin" "${root}/ai/hooks"
  cp "${BIN}" "${root}/ai/bin/check-guard-messages"
  chmod +x "${root}/ai/bin/check-guard-messages"
  printf '#!/bin/sh\necho "DENY: x. Fix: do y." >&2; exit 2\n' > "${root}/ai/hooks/good-guard.sh"
  chmod +x "${root}/ai/hooks/good-guard.sh"
  printf '# path<TAB>class<TAB>reason\n' > "${root}/ai/guard-classification.tsv"
  git -C "${root}" init -q
  printf '%s\n' "${root}"
}

# add_exec <root> <relpath> <body>: write an executable file.
add_exec() {
  mkdir -p "$(dirname "$1/$2")"
  printf '%s\n' "$3" > "$1/$2"
  chmod +x "$1/$2"
}

classify() { printf '%s%s%s%s%s\n' "$2" "${TAB}" "$3" "${TAB}" "$4" >> "$1/ai/guard-classification.tsv"; }

track() { git -C "$1" add -A >/dev/null 2>&1; }

# run <root>: run the fixture's checker; sets RC and OUT (stdout+stderr).
run() {
  OUT="$(cd "$1" && ruby ai/bin/check-guard-messages 2>&1)"; RC=$?
}

BARE='#!/bin/sh
echo "FAIL: something is wrong" >&2
exit 1'

echo "== check-guard-messages: coverage beyond ai/hooks and GUARD_BINS =="

# 1. Positive control: everything classified and compliant -> exit 0.
R="$(new_fixture control)"; track "${R}"; run "${R}"
if [ "${RC}" -eq 0 ]; then ok "1 a fully classified, compliant tree passes"
else bad "1 a fully classified, compliant tree passes" "rc=${RC} out=${OUT}"; fi

# 2. THE DEFECT: a new script under scripts/, classified nowhere, with a bare
#    failure message. The old checker never looked at scripts/ and said OK.
R="$(new_fixture unclassified)"
add_exec "${R}" scripts/new-gate "${BARE}"; track "${R}"; run "${R}"
if [ "${RC}" -ne 0 ] && printf '%s' "${OUT}" | grep -F 'scripts/new-gate' >/dev/null && printf '%s' "${OUT}" | grep -F 'Fix:' >/dev/null; then
  ok "2 an unclassified new script under scripts/ fails loudly, named, with Fix:"
else bad "2 an unclassified new script under scripts/ fails loudly, named, with Fix:" "rc=${RC} out=${OUT}"; fi

# 3. THE DEFECT, second shape: an ai/bin tool absent from GUARD_BINS with a
#    bare failure. Every ai/bin executable is a guard unless classified otherwise.
R="$(new_fixture unlisted-bin)"
add_exec "${R}" ai/bin/unlisted-check "${BARE}"; track "${R}"; run "${R}"
if [ "${RC}" -ne 0 ] && printf '%s' "${OUT}" | grep -F 'ai/bin/unlisted-check' >/dev/null; then
  ok "3 a bare-failure ai/bin tool that no list names is flagged"
else bad "3 a bare-failure ai/bin tool that no list names is flagged" "rc=${RC} out=${OUT}"; fi

# 4. A classified file that has vanished must fail, not shrink the scope.
R="$(new_fixture vanished)"
classify "${R}" scripts/gone-guard guard ""; track "${R}"; run "${R}"
if [ "${RC}" -ne 0 ] && printf '%s' "${OUT}" | grep -F 'scripts/gone-guard' >/dev/null; then
  ok "4 a classified file that vanished fails loudly, named"
else bad "4 a classified file that vanished fails loudly, named" "rc=${RC} out=${OUT}"; fi

# 5. A skill's bin/ is first-party too.
R="$(new_fixture skill-bin)"
add_exec "${R}" "ai/skills/athena:demo/bin/do-thing" "${BARE}"; track "${R}"; run "${R}"
if [ "${RC}" -ne 0 ] && printf '%s' "${OUT}" | grep -F 'ai/skills/athena:demo/bin/do-thing' >/dev/null; then
  ok "5 an unclassified skill bin fails loudly, named"
else bad "5 an unclassified skill bin fails loudly, named" "rc=${RC} out=${OUT}"; fi

# 6. A sourced library under a lib/ directory is discovered even though it is
#    not executable.
R="$(new_fixture lib)"
mkdir -p "${R}/scripts/lib"; printf 'die() { echo "no" >&2; exit 1; }\n' > "${R}/scripts/lib/helpers.sh"
track "${R}"; run "${R}"
if [ "${RC}" -ne 0 ] && printf '%s' "${OUT}" | grep -F 'scripts/lib/helpers.sh' >/dev/null; then
  ok "6 an unclassified sourced library under lib/ fails loudly, named"
else bad "6 an unclassified sourced library under lib/ fails loudly, named" "rc=${RC} out=${OUT}"; fi

# 7. A script classified guard must still carry Fix: -- classification is not
#    an exemption.
R="$(new_fixture guard-bare)"
add_exec "${R}" scripts/some-gate "${BARE}"
classify "${R}" scripts/some-gate guard ""; track "${R}"; run "${R}"
if [ "${RC}" -ne 0 ] && printf '%s' "${OUT}" | grep -F 'scripts/some-gate' >/dev/null; then
  ok "7 a classified guard with a bare failure message is flagged"
else bad "7 a classified guard with a bare failure message is flagged" "rc=${RC} out=${OUT}"; fi

# 8. A non-guard classification needs a reason; an empty one is refused.
R="$(new_fixture no-reason)"
add_exec "${R}" scripts/util "${BARE}"
classify "${R}" scripts/util tool ""; track "${R}"; run "${R}"
if [ "${RC}" -ne 0 ] && printf '%s' "${OUT}" | grep -F 'scripts/util' >/dev/null; then
  ok "8 a non-guard classification with no reason is refused"
else bad "8 a non-guard classification with no reason is refused" "rc=${RC} out=${OUT}"; fi

# 9. Classified non-guards and test suites pass; so does an untracked new
#    script once classified (discovery reads the working tree, not only HEAD).
R="$(new_fixture classified)"
add_exec "${R}" scripts/util "${BARE}"
classify "${R}" scripts/util tool "desktop utility; its only failure is a usage error"
add_exec "${R}" scripts/test/util/self-test.sh "${BARE}"
track "${R}"
add_exec "${R}" scripts/untracked-util "${BARE}"
classify "${R}" scripts/untracked-util tool "desktop utility; its only failure is a usage error"
run "${R}"
if [ "${RC}" -eq 0 ]; then ok "9 classified tools and test suites pass"
else bad "9 classified tools and test suites pass" "rc=${RC} out=${OUT}"; fi

# 10. ...and an UNTRACKED unclassified script is still discovered.
R="$(new_fixture untracked)"; track "${R}"
add_exec "${R}" scripts/brand-new "${BARE}"; run "${R}"
if [ "${RC}" -ne 0 ] && printf '%s' "${OUT}" | grep -F 'scripts/brand-new' >/dev/null; then
  ok "10 an untracked unclassified script is discovered and fails"
else bad "10 an untracked unclassified script is discovered and fails" "rc=${RC} out=${OUT}"; fi

# 11. An emptied guard directory fails: "found nothing" must not read as OK.
R="$(new_fixture no-hooks)"; rm -f "${R}/ai/hooks/good-guard.sh"; track "${R}"; run "${R}"
if [ "${RC}" -ne 0 ] && printf '%s' "${OUT}" | grep -F 'ai/hooks' >/dev/null; then
  ok "11 an empty ai/hooks discovery set fails loudly"
else bad "11 an empty ai/hooks discovery set fails loudly" "rc=${RC} out=${OUT}"; fi

echo "== check-guard-messages: untracked third-party trees (DND-512) =="

# DND-512: the main checkout held an untracked, un-ignored node_modules tree
# (ai/skills/athena:inbox/channel/node_modules). Its executables and its lib/
# files were discovered as 182 unclassified first-party files and the live gate
# went red in the main checkout while every clean worktree stayed green.

# 13. An untracked node_modules tree (an executable, and a lib/ file inside it),
#     an untracked .venv, and an untracked vendor/bundle are third-party: they
#     must not fail, and the skip is counted in the OK line, not silent.
R="$(new_fixture third-party)"; track "${R}"
add_exec "${R}" "ai/skills/athena:demo/channel/node_modules/which/bin/node-which" "${BARE}"
mkdir -p "${R}/ai/skills/athena:demo/channel/node_modules/ajv/lib"
printf 'export const x = 1\n' > "${R}/ai/skills/athena:demo/channel/node_modules/ajv/lib/ajv.ts"
add_exec "${R}" "tools/.venv/bin/activate-thing" "${BARE}"
add_exec "${R}" "vendor/bundle/ruby/3.3.0/bin/rake" "${BARE}"
run "${R}"
if [ "${RC}" -eq 0 ] && printf '%s' "${OUT}" | grep -F '4 untracked third-party' >/dev/null; then
  ok "13 untracked node_modules / .venv / vendor/bundle files do not fail, and are counted"
else bad "13 untracked node_modules / .venv / vendor/bundle files do not fail, and are counted" "rc=${RC} out=${OUT}"; fi

# 14. The exclusion must never hide a first-party file: with an untracked
#     node_modules tree present, a NEW untracked script under ai/bin and one
#     under scripts/ still fail, named -- and the node_modules file is not named.
R="$(new_fixture third-party-plus-new)"; track "${R}"
add_exec "${R}" "ai/skills/athena:demo/channel/node_modules/which/bin/node-which" "${BARE}"
add_exec "${R}" ai/bin/brand-new-check "${BARE}"
add_exec "${R}" scripts/brand-new-tool "${BARE}"
run "${R}"
if [ "${RC}" -ne 0 ] \
   && printf '%s' "${OUT}" | grep -F 'ai/bin/brand-new-check' >/dev/null \
   && printf '%s' "${OUT}" | grep -F 'scripts/brand-new-tool' >/dev/null \
   && ! printf '%s' "${OUT}" | grep -F 'node-which' >/dev/null; then
  ok "14 new untracked first-party scripts under ai/bin and scripts/ still fail beside a node_modules tree"
else bad "14 new untracked first-party scripts under ai/bin and scripts/ still fail beside a node_modules tree" "rc=${RC} out=${OUT}"; fi

# 15. A TRACKED (staged or committed) file inside node_modules is repo content,
#     not a local install: it is discovered and must be classified.
R="$(new_fixture tracked-node-modules)"
add_exec "${R}" "ai/skills/athena:demo/node_modules/pkg/bin/run" "${BARE}"; track "${R}"; run "${R}"
if [ "${RC}" -ne 0 ] && printf '%s' "${OUT}" | grep -F 'ai/skills/athena:demo/node_modules/pkg/bin/run' >/dev/null; then
  ok "15 a tracked file inside node_modules is discovered and must be classified"
else bad "15 a tracked file inside node_modules is discovered and must be classified" "rc=${RC} out=${OUT}"; fi

# 16. The rule matches whole path segments only: an untracked script in a
#     directory merely NAMED like one (node_modules-tools/, vendor/ without
#     bundle/, venv-notes/) is first-party and still fails.
R="$(new_fixture near-miss)"; track "${R}"
add_exec "${R}" scripts/node_modules-tools/run "${BARE}"
add_exec "${R}" vendor/mine/run "${BARE}"
add_exec "${R}" scripts/.venv-notes/run "${BARE}"
run "${R}"
if [ "${RC}" -ne 0 ] \
   && printf '%s' "${OUT}" | grep -F 'scripts/node_modules-tools/run' >/dev/null \
   && printf '%s' "${OUT}" | grep -F 'vendor/mine/run' >/dev/null \
   && printf '%s' "${OUT}" | grep -F 'scripts/.venv-notes/run' >/dev/null; then
  ok "16 look-alike directory names are not third-party; their scripts still fail"
else bad "16 look-alike directory names are not third-party; their scripts still fail" "rc=${RC} out=${OUT}"; fi

# 17. --root measures the named tree, so the branch's checker can be run
#     read-only against another checkout (the live main-checkout verify).
A="$(new_fixture root-runner)"; track "${A}"
B="$(new_fixture root-target)"; track "${B}"
add_exec "${B}" scripts/only-in-target "${BARE}"
OUT="$(cd "${A}" && ruby ai/bin/check-guard-messages --root "${B}" 2>&1)"; RC=$?
if [ "${RC}" -ne 0 ] && printf '%s' "${OUT}" | grep -F 'scripts/only-in-target' >/dev/null; then
  ok "17 --root <dir> measures that tree, not the checker's own"
else bad "17 --root <dir> measures that tree, not the checker's own" "rc=${RC} out=${OUT}"; fi

echo "== check-guard-messages: live tree =="

# 12. The live tree: every first-party executable is classified and compliant.
if OUT="$(ruby "${AI_DIR}/bin/check-guard-messages" 2>&1)"; then
  ok "12 the live tree passes check-guard-messages"
else bad "12 the live tree passes check-guard-messages" "${OUT}"; fi

echo
echo "check-guard-messages self-test: ${PASS} passed, ${FAIL} failed"
if [ "${FAIL}" -ne 0 ]; then
  echo "Fix: a FAIL above names the coverage case the checker got wrong; see ai/bin/check-guard-messages's discovery/classification." >&2
  exit 1
fi
