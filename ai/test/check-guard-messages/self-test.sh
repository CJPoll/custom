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
