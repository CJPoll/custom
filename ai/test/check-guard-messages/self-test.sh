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
BIN_LIB="$(dirname "${BIN}")/../lib/landed.rb"

if [ ! -f "${BIN}" ]; then
  echo "check-guard-messages self-test: FAIL -- ${BIN} does not exist" >&2
  echo "Fix: point CHECK_GUARD_MESSAGES_UNDER_TEST at a real checker, or restore ai/bin/check-guard-messages." >&2
  exit 1
fi

TMP="$(mktemp -d)"; trap 'rm -rf "${TMP}"' EXIT
PASS=0; FAIL=0
ok()  { printf '  ok    %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  FAIL  %s\n        %s\n' "$1" "$2"; FAIL=$((FAIL+1)); }

# Fixtures get a hermetic git config. Case 12 (the live tree) must NOT: it
# measures what `ai/bin/check-guard-messages` measures when harness-gate runs
# it directly, so it keeps the caller's git config -- including the user-global
# excludes file, which is what ignores this repo's ai-artifacts/ (DND-512).
LIVE_GIT_ENV=(env -u GIT_CONFIG_NOSYSTEM -u GIT_CONFIG_GLOBAL)
[ -n "${GIT_CONFIG_NOSYSTEM+x}" ] && LIVE_GIT_ENV+=("GIT_CONFIG_NOSYSTEM=${GIT_CONFIG_NOSYSTEM}")
[ -n "${GIT_CONFIG_GLOBAL+x}" ] && LIVE_GIT_ENV+=("GIT_CONFIG_GLOBAL=${GIT_CONFIG_GLOBAL}")
export GIT_CONFIG_NOSYSTEM=1
export GIT_CONFIG_GLOBAL="${TMP}/gitconfig"
: > "${GIT_CONFIG_GLOBAL}"

TAB="$(printf '\t')"

# land <root>: commit the whole tree, push it to the fixture's bare origin as
# refs/heads/main, and point refs/remotes/origin/main at it -- "the owner
# landed this on main". The classification ratchet (DND-510) reads its bar from
# origin/main and the merge-base, never from the working tree, and (DND-538)
# cross-checks the local ref against `git ls-remote origin refs/heads/main`.
land() {
  git -C "$1" add -A >/dev/null 2>&1
  git -C "$1" -c user.name=fixture -c user.email=fixture@example.invalid \
    commit -q --allow-empty -m landed >/dev/null 2>&1
  git -C "$1" push -q -f origin HEAD:refs/heads/main >/dev/null 2>&1
  git -C "$1" update-ref refs/remotes/origin/main HEAD
}

# new_fixture <name>: a git repo holding the checker, one compliant hook, and
# an empty classification table, landed on a local bare origin (<name>.origin.git)
# and its refs/remotes/origin/main. Prints its path.
new_fixture() {
  local root="${TMP}/$1"
  mkdir -p "${root}/ai/bin" "${root}/ai/hooks"
  cp "${BIN}" "${root}/ai/bin/check-guard-messages"
  chmod +x "${root}/ai/bin/check-guard-messages"
  printf '#!/bin/sh\necho "DENY: x. Fix: do y." >&2; exit 2\n' > "${root}/ai/hooks/good-guard.sh"
  chmod +x "${root}/ai/hooks/good-guard.sh"
  printf '# path<TAB>class<TAB>reason\n' > "${root}/ai/guard-classification.tsv"
  # Since DND-543 the checker requires the shared landed-bar library. A pre-
  # DND-543 checker under test has none, and the fixture then carries none.
  if [ -f "${BIN_LIB}" ]; then
    mkdir -p "${root}/ai/lib"
    cp "${BIN_LIB}" "${root}/ai/lib/landed.rb"
    printf 'ai/lib/landed.rb\tlibrary\tshared landed-bar library required by the checker; the caller prints the Fix:\n' \
      >> "${root}/ai/guard-classification.tsv"
  fi
  git -C "${root}" init -q
  git init -q --bare "${root}.origin.git"
  git -C "${root}" remote add origin "${root}.origin.git"
  land "${root}"
  printf '%s\n' "${root}"
}

# reclassify <root> <path> <class> <reason>: replace path's table line.
reclassify() {
  local tsv="$1/ai/guard-classification.tsv"
  grep -v -F "$2${TAB}" "${tsv}" > "${tsv}.new"; mv "${tsv}.new" "${tsv}"
  classify "$@"
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

echo "== check-guard-messages: classification ratchet against origin/main (DND-510) =="

# DND-510: the table is in the same diff the check judges. A change could
# relabel a real guard as tool, delete its Fix: line, and the gate stayed green.
# The bar is now the LANDED classification (origin/main tip and the merge-base),
# read out of git. Weakening fails; tightening and new entries pass.

GUARDED='#!/bin/sh
echo "DENY: x. Fix: do y." >&2
exit 2'
TOOL_REASON="first-party utility; its only failure is a usage error"

# 18. A guard relabelled tool, its Fix: line deleted -> FAIL, named.
R="$(new_fixture relabel)"
add_exec "${R}" scripts/some-gate "${GUARDED}"
classify "${R}" scripts/some-gate guard ""; land "${R}"
reclassify "${R}" scripts/some-gate tool "${TOOL_REASON}"
add_exec "${R}" scripts/some-gate "${BARE}"; track "${R}"; run "${R}"
if [ "${RC}" -ne 0 ] && printf '%s' "${OUT}" | grep -F 'scripts/some-gate' >/dev/null \
   && printf '%s' "${OUT}" | grep -F 'weaken' >/dev/null && printf '%s' "${OUT}" | grep -F 'Fix:' >/dev/null; then
  ok "18 a landed guard relabelled tool (Fix: removed) fails as a weakening, named, with Fix:"
else bad "18 a landed guard relabelled tool (Fix: removed) fails as a weakening, named, with Fix:" "rc=${RC} out=${OUT}"; fi

# 19. An existing ai/bin file (default guard) newly listed no-fail-path -> FAIL.
R="$(new_fixture bin-nofail)"
add_exec "${R}" ai/bin/existing-check "${GUARDED}"; land "${R}"
classify "${R}" ai/bin/existing-check no-fail-path "prints a number and never denies anything"
add_exec "${R}" ai/bin/existing-check "${BARE}"; track "${R}"; run "${R}"
if [ "${RC}" -ne 0 ] && printf '%s' "${OUT}" | grep -F 'ai/bin/existing-check' >/dev/null \
   && printf '%s' "${OUT}" | grep -F 'weaken' >/dev/null; then
  ok "19 a landed ai/bin guard newly listed no-fail-path fails as a weakening"
else bad "19 a landed ai/bin guard newly listed no-fail-path fails as a weakening" "rc=${RC} out=${OUT}"; fi

# 20. The owner landed that reclassification on main (tip and merge-base) -> PASS.
R="$(new_fixture owner-landed)"
add_exec "${R}" ai/bin/existing-check "${GUARDED}"; land "${R}"
classify "${R}" ai/bin/existing-check no-fail-path "prints a number and never denies anything"
add_exec "${R}" ai/bin/existing-check "${BARE}"; land "${R}"; run "${R}"
if [ "${RC}" -eq 0 ] && printf '%s' "${OUT}" | grep -F 'ratchet' >/dev/null; then
  ok "20 an owner-landed reclassification already on origin/main passes"
else bad "20 an owner-landed reclassification already on origin/main passes" "rc=${RC} out=${OUT}"; fi

# 21. The owner landed it on origin/main AFTER this branch forked: the
#     merge-base still says guard, so the lowest landed value is guard -> FAIL
#     until the branch rebases (the bar is the strictest of tip and merge-base).
R="$(new_fixture stale-branch)"
add_exec "${R}" ai/bin/existing-check "${GUARDED}"; land "${R}"
FORK="$(git -C "${R}" rev-parse HEAD)"
classify "${R}" ai/bin/existing-check no-fail-path "prints a number and never denies anything"
add_exec "${R}" ai/bin/existing-check "${BARE}"; land "${R}"
git -C "${R}" reset -q --soft "${FORK}"   # the branch has the same edit, uncommitted, forked at FORK
run "${R}"
if [ "${RC}" -ne 0 ] && printf '%s' "${OUT}" | grep -F 'ai/bin/existing-check' >/dev/null; then
  ok "21 a reclassification on origin/main but not the merge-base still fails (rebase first)"
else bad "21 a reclassification on origin/main but not the merge-base still fails (rebase first)" "rc=${RC} out=${OUT}"; fi

# 21b. The reverse: main TIGHTENED a tool to guard after this branch forked,
#      and the branch still says tool. The tip says guard -> FAIL (rebase).
R="$(new_fixture stale-tightened)"
add_exec "${R}" scripts/util "${GUARDED}"
classify "${R}" scripts/util tool "${TOOL_REASON}"; land "${R}"
FORK="$(git -C "${R}" rev-parse HEAD)"
reclassify "${R}" scripts/util guard ""; land "${R}"
git -C "${R}" reset -q --hard "${FORK}"
run "${R}"
if [ "${RC}" -ne 0 ] && printf '%s' "${OUT}" | grep -F 'scripts/util' >/dev/null; then
  ok "21b a guard tightened on origin/main after the fork binds the branch too"
else bad "21b a guard tightened on origin/main after the fork binds the branch too" "rc=${RC} out=${OUT}"; fi

# 22. Genuinely new entries pass and are NAMED: a new scripts/ tool and a new
#     ai/bin tool that did not exist at any landed point.
R="$(new_fixture new-entry)"
add_exec "${R}" scripts/brand-new-util "${BARE}"
classify "${R}" scripts/brand-new-util tool "${TOOL_REASON}"
add_exec "${R}" ai/bin/brand-new-tool "${BARE}"
classify "${R}" ai/bin/brand-new-tool tool "${TOOL_REASON}"; track "${R}"; run "${R}"
if [ "${RC}" -eq 0 ] && printf '%s' "${OUT}" | grep -F 'scripts/brand-new-util' >/dev/null \
   && printf '%s' "${OUT}" | grep -F 'ai/bin/brand-new-tool' >/dev/null \
   && printf '%s' "${OUT}" | grep -F 'new' >/dev/null; then
  ok "22 genuinely new entries pass and are named in the output"
else bad "22 genuinely new entries pass and are named in the output" "rc=${RC} out=${OUT}"; fi

# 23. Tightening (tool -> guard, now with a Fix: line) passes.
R="$(new_fixture tighten)"
add_exec "${R}" scripts/util "${BARE}"
classify "${R}" scripts/util tool "${TOOL_REASON}"; land "${R}"
reclassify "${R}" scripts/util guard ""
add_exec "${R}" scripts/util "${GUARDED}"; track "${R}"; run "${R}"
if [ "${RC}" -eq 0 ]; then ok "23 tightening a tool to guard passes"
else bad "23 tightening a tool to guard passes" "rc=${RC} out=${OUT}"; fi

# 24. No origin/main: the landed bar cannot be read -> FAIL, "could not
#     measure", every probe named, never OK.
R="$(new_fixture no-origin)"; git -C "${R}" update-ref -d refs/remotes/origin/main; run "${R}"
if [ "${RC}" -ne 0 ] && printf '%s' "${OUT}" | grep -F 'could not measure' >/dev/null \
   && printf '%s' "${OUT}" | grep -F 'refs/remotes/origin/main' >/dev/null \
   && printf '%s' "${OUT}" | grep -F 'Fix:' >/dev/null; then
  ok "24 no origin/main fails as could-not-measure, probes named, with Fix:"
else bad "24 no origin/main fails as could-not-measure, probes named, with Fix:" "rc=${RC} out=${OUT}"; fi

# 25. origin/main shares no history with HEAD (no merge-base) -> could-not-measure.
R="$(new_fixture no-merge-base)"
git -C "${R}" checkout -q --orphan unrelated
git -C "${R}" -c user.name=fixture -c user.email=fixture@example.invalid commit -q -m unrelated >/dev/null 2>&1
run "${R}"
if [ "${RC}" -ne 0 ] && printf '%s' "${OUT}" | grep -F 'could not measure' >/dev/null \
   && printf '%s' "${OUT}" | grep -F 'merge-base' >/dev/null; then
  ok "25 no merge-base with origin/main fails as could-not-measure"
else bad "25 no merge-base with origin/main fails as could-not-measure" "rc=${RC} out=${OUT}"; fi

# 26. A shallow clone cannot prove its merge-base -> could-not-measure.
R="$(new_fixture shallow-src)"; land "${R}"
S="${TMP}/shallow"
git clone -q --depth 1 "file://${R}" "${S}" 2>/dev/null
git -C "${S}" update-ref refs/remotes/origin/main HEAD   # the ref exists; only depth is missing
OUT="$(cd "${S}" && ruby ai/bin/check-guard-messages 2>&1)"; RC=$?
if [ "${RC}" -ne 0 ] && printf '%s' "${OUT}" | grep -F 'could not measure' >/dev/null \
   && printf '%s' "${OUT}" | grep -F 'shallow' >/dev/null; then
  ok "26 a shallow clone fails as could-not-measure"
else bad "26 a shallow clone fails as could-not-measure" "rc=${RC} out=${OUT}"; fi

# 27. A guard entry removed while its file remains: a guard under a test/
#     directory falls back to the "test" rule class -> FAIL.
R="$(new_fixture entry-removed)"
add_exec "${R}" scripts/test/gatekeeper "${GUARDED}"
classify "${R}" scripts/test/gatekeeper guard ""; land "${R}"
grep -v -F "scripts/test/gatekeeper${TAB}" "${R}/ai/guard-classification.tsv" > "${R}/t.new"
mv "${R}/t.new" "${R}/ai/guard-classification.tsv"
add_exec "${R}" scripts/test/gatekeeper "${BARE}"; track "${R}"; run "${R}"
if [ "${RC}" -ne 0 ] && printf '%s' "${OUT}" | grep -F 'scripts/test/gatekeeper' >/dev/null; then
  ok "27 a removed guard entry whose file remains fails as a weakening"
else bad "27 a removed guard entry whose file remains fails as a weakening" "rc=${RC} out=${OUT}"; fi

# 28. A landed ai/bin guard that loses its exec bit drops out of discovery; the
#     file is still there, so that is a weakening, not a deletion -> FAIL.
R="$(new_fixture lost-exec)"
add_exec "${R}" ai/bin/existing-check "${GUARDED}"; land "${R}"
printf '%s\n' "${BARE}" > "${R}/ai/bin/existing-check"; chmod -x "${R}/ai/bin/existing-check"
track "${R}"; run "${R}"
if [ "${RC}" -ne 0 ] && printf '%s' "${OUT}" | grep -F 'ai/bin/existing-check' >/dev/null; then
  ok "28 a landed guard that lost its exec bit fails as a weakening"
else bad "28 a landed guard that lost its exec bit fails as a weakening" "rc=${RC} out=${OUT}"; fi

# 29. Deleting a landed guard outright is not a weakening of a classification.
R="$(new_fixture deleted)"
add_exec "${R}" ai/bin/retired-check "${GUARDED}"; land "${R}"
git -C "${R}" rm -q ai/bin/retired-check; run "${R}"
if [ "${RC}" -eq 0 ]; then ok "29 a deleted landed guard passes (removal, not reclassification)"
else bad "29 a deleted landed guard passes (removal, not reclassification)" "rc=${RC} out=${OUT}"; fi

echo "== check-guard-messages: a guard moved to a new path keeps its bar (DND-539) =="

# DND-539: the ratchet keyed on PATH. A landed guard deleted at its old path and
# re-added at a new one read as a removal plus a genuinely new entry, so it
# could be classified tool and lose its Fix: line while the gate stayed green.
# A new entry whose content maps to a removed landed guard -- the same blob, or
# a git rename at >= 50% similarity -- now inherits that guard's bar.

# A realistic guard: long enough that git's similarity score means something.
LONG_GUARD='#!/usr/bin/env bash
# some-guard: refuse a command that would do the wrong thing.
set -euo pipefail
input="$(cat)"
command="$(printf "%s" "${input}" | jq -r ".tool_input.command // empty")"
if [ -z "${command}" ]; then
  exit 0
fi
case "${command}" in
  *"rm -rf /"*)
    echo "DENY: refusing to delete the filesystem root." >&2
    echo "Fix: name the exact directory you meant to delete." >&2
    exit 2
    ;;
  *"git push --force"*)
    echo "DENY: refusing a force push." >&2
    echo "Fix: push without --force, or use --force-with-lease on your own branch." >&2
    exit 2
    ;;
esac
exit 0'

# 30. A landed guard moved (same blob) to a new path and classified tool -> FAIL.
R="$(new_fixture moved-to-tool)"
add_exec "${R}" ai/bin/moving-check "${LONG_GUARD}"; land "${R}"
mkdir -p "${R}/scripts"; git -C "${R}" mv ai/bin/moving-check scripts/moved-util
classify "${R}" scripts/moved-util tool "${TOOL_REASON}"; track "${R}"; run "${R}"
if [ "${RC}" -ne 0 ] && printf '%s' "${OUT}" | grep -F 'scripts/moved-util' >/dev/null \
   && printf '%s' "${OUT}" | grep -F 'ai/bin/moving-check' >/dev/null \
   && printf '%s' "${OUT}" | grep -F 'weaken' >/dev/null && printf '%s' "${OUT}" | grep -F 'Fix:' >/dev/null; then
  ok "30 a landed guard moved to a new path and classified tool fails as a weakening, both paths named"
else bad "30 a landed guard moved to a new path and classified tool fails as a weakening, both paths named" "rc=${RC} out=${OUT}"; fi

# 30b. The same move with the content edited (its Fix: lines deleted), left
#      UNTRACKED at the new path (plain mv, no git add), and listed no-fail-path
#      -> FAIL: git's rename detection still maps it to the removed guard.
R="$(new_fixture moved-edited)"
add_exec "${R}" ai/hooks/old-guard.sh "${LONG_GUARD}"; land "${R}"
grep -v 'Fix:' "${R}/ai/hooks/old-guard.sh" > "${R}/ai/bin/renamed-report"
chmod +x "${R}/ai/bin/renamed-report"; rm -f "${R}/ai/hooks/old-guard.sh"
classify "${R}" ai/bin/renamed-report no-fail-path "prints a report and never denies anything"; run "${R}"
if [ "${RC}" -ne 0 ] && printf '%s' "${OUT}" | grep -F 'ai/bin/renamed-report' >/dev/null \
   && printf '%s' "${OUT}" | grep -F 'ai/hooks/old-guard.sh' >/dev/null \
   && printf '%s' "${OUT}" | grep -F 'weaken' >/dev/null; then
  ok "30b a landed guard moved, edited, untracked and listed no-fail-path fails as a weakening"
else bad "30b a landed guard moved, edited, untracked and listed no-fail-path fails as a weakening" "rc=${RC} out=${OUT}"; fi

# 30c. A guard moved under a test/ directory with no table line falls to the
#      "test" rule class -> FAIL.
R="$(new_fixture moved-to-test)"
add_exec "${R}" scripts/gatekeeper "${LONG_GUARD}"
classify "${R}" scripts/gatekeeper guard ""; land "${R}"
mkdir -p "${R}/scripts/test"; git -C "${R}" mv scripts/gatekeeper scripts/test/gatekeeper
grep -v -F "scripts/gatekeeper${TAB}" "${R}/ai/guard-classification.tsv" > "${R}/t.new"
mv "${R}/t.new" "${R}/ai/guard-classification.tsv"; track "${R}"; run "${R}"
if [ "${RC}" -ne 0 ] && printf '%s' "${OUT}" | grep -F 'scripts/test/gatekeeper' >/dev/null \
   && printf '%s' "${OUT}" | grep -F 'weaken' >/dev/null; then
  ok "30c a landed guard moved into a test/ directory fails as a weakening"
else bad "30c a landed guard moved into a test/ directory fails as a weakening" "rc=${RC} out=${OUT}"; fi

# 31. A landed guard moved and KEPT guard (ai/bin default) -> PASS.
R="$(new_fixture moved-kept)"
add_exec "${R}" ai/bin/moving-check "${LONG_GUARD}"; land "${R}"
git -C "${R}" mv ai/bin/moving-check ai/bin/moved-check; track "${R}"; run "${R}"
if [ "${RC}" -eq 0 ] && printf '%s' "${OUT}" | grep -F 'ai/bin/moving-check -> ai/bin/moved-check' >/dev/null; then ok "31 a landed guard moved and kept guard passes, the move named"
else bad "31 a landed guard moved and kept guard passes, the move named" "rc=${RC} out=${OUT}"; fi

# 31b. A table-listed guard moved and re-listed guard at its new path -> PASS.
R="$(new_fixture moved-kept-listed)"
add_exec "${R}" scripts/gatekeeper "${LONG_GUARD}"
classify "${R}" scripts/gatekeeper guard ""; land "${R}"
git -C "${R}" mv scripts/gatekeeper scripts/gatekeeper-v2
grep -v -F "scripts/gatekeeper${TAB}" "${R}/ai/guard-classification.tsv" > "${R}/t.new"
mv "${R}/t.new" "${R}/ai/guard-classification.tsv"
classify "${R}" scripts/gatekeeper-v2 guard ""; track "${R}"; run "${R}"
if [ "${RC}" -eq 0 ]; then ok "31b a listed guard moved and re-listed guard passes"
else bad "31b a listed guard moved and re-listed guard passes" "rc=${RC} out=${OUT}"; fi

# 32. A genuinely new tool with unrelated content, in the same diff that
#     deletes an unrelated landed guard -> PASS, and the new entry is named.
R="$(new_fixture new-beside-removal)"
add_exec "${R}" ai/bin/retired-check "${LONG_GUARD}"; land "${R}"
git -C "${R}" rm -q ai/bin/retired-check
add_exec "${R}" scripts/fresh-util "${BARE}"
classify "${R}" scripts/fresh-util tool "${TOOL_REASON}"; track "${R}"; run "${R}"
if [ "${RC}" -eq 0 ] && printf '%s' "${OUT}" | grep -F 'scripts/fresh-util' >/dev/null \
   && printf '%s' "${OUT}" | grep -F 'new' >/dev/null; then
  ok "32 a genuinely new tool beside an unrelated guard deletion passes, named"
else bad "32 a genuinely new tool beside an unrelated guard deletion passes, named" "rc=${RC} out=${OUT}"; fi

echo "== check-guard-messages: the landed tip is origin's, not a local ref (DND-538) =="

# DND-538: the ratchet trusted the LOCAL refs/remotes/origin/main. Anyone who
# can run `git update-ref` could point it at a commit carrying the relabel, and
# the "landed" bar became the diff's own bar again. The local tip is now
# cross-checked against `git ls-remote origin refs/heads/main`.

# 33. A forged local origin/main: the relabel is committed and the local ref
#     moved onto it with update-ref, never pushed -> FAIL, both SHAs named.
R="$(new_fixture forged-ref)"
add_exec "${R}" scripts/some-gate "${GUARDED}"
classify "${R}" scripts/some-gate guard ""; land "${R}"
REAL="$(git -C "${R}" rev-parse HEAD)"
reclassify "${R}" scripts/some-gate tool "${TOOL_REASON}"
add_exec "${R}" scripts/some-gate "${BARE}"; track "${R}"
git -C "${R}" -c user.name=fixture -c user.email=fixture@example.invalid commit -q -m relabel >/dev/null 2>&1
git -C "${R}" update-ref refs/remotes/origin/main HEAD
FORGED="$(git -C "${R}" rev-parse HEAD)"; run "${R}"
if [ "${RC}" -ne 0 ] && printf '%s' "${OUT}" | grep -F "${REAL}" >/dev/null \
   && printf '%s' "${OUT}" | grep -F "${FORGED}" >/dev/null && printf '%s' "${OUT}" | grep -F 'Fix:' >/dev/null \
   && ! printf '%s' "${OUT}" | grep -F 'OK' >/dev/null; then
  ok "33 a forged local origin/main fails, naming the local and the remote SHA, with Fix:"
else bad "33 a forged local origin/main fails, naming the local and the remote SHA, with Fix:" "rc=${RC} out=${OUT}"; fi

# 34. origin is unreachable -> FAIL as could-not-measure; never a fallback to
#     the local ref, never OK.
R="$(new_fixture unreachable)"; track "${R}"
git -C "${R}" remote set-url origin "${TMP}/no-such-remote.git"; run "${R}"
if [ "${RC}" -ne 0 ] && printf '%s' "${OUT}" | grep -F 'could not measure' >/dev/null \
   && printf '%s' "${OUT}" | grep -F 'ls-remote' >/dev/null && printf '%s' "${OUT}" | grep -F 'Fix:' >/dev/null \
   && ! printf '%s' "${OUT}" | grep -F 'OK' >/dev/null; then
  ok "34 an unreachable origin fails as could-not-measure, with Fix:"
else bad "34 an unreachable origin fails as could-not-measure, with Fix:" "rc=${RC} out=${OUT}"; fi

# 34b. No origin remote at all (the local ref left behind) -> could-not-measure.
R="$(new_fixture no-remote)"; track "${R}"
git -C "${R}" config --remove-section remote.origin; run "${R}"
if [ "${RC}" -ne 0 ] && printf '%s' "${OUT}" | grep -F 'could not measure' >/dev/null; then
  ok "34b a missing origin remote fails as could-not-measure"
else bad "34b a missing origin remote fails as could-not-measure" "rc=${RC} out=${OUT}"; fi

# 34c. origin is reachable but has no refs/heads/main -> could-not-measure.
R="$(new_fixture no-remote-main)"; track "${R}"
git -C "${R}.origin.git" update-ref -d refs/heads/main; run "${R}"
if [ "${RC}" -ne 0 ] && printf '%s' "${OUT}" | grep -F 'could not measure' >/dev/null \
   && printf '%s' "${OUT}" | grep -F 'refs/heads/main' >/dev/null; then
  ok "34c an origin with no refs/heads/main fails as could-not-measure"
else bad "34c an origin with no refs/heads/main fails as could-not-measure" "rc=${RC} out=${OUT}"; fi

# 35. A local ref that agrees with origin passes, and the OK output says the
#     tip was cross-checked (so a pass that skipped the check cannot read the same).
R="$(new_fixture consistent)"; track "${R}"; run "${R}"
TIP="$(git -C "${R}" rev-parse refs/remotes/origin/main)"
if [ "${RC}" -eq 0 ] && printf '%s' "${OUT}" | grep -F 'ls-remote' >/dev/null \
   && printf '%s' "${OUT}" | grep -F "${TIP:0:12}" >/dev/null; then
  ok "35 a local origin/main that matches origin passes, the cross-check named"
else bad "35 a local origin/main that matches origin passes, the cross-check named" "rc=${RC} out=${OUT}"; fi

echo "== check-guard-messages: the landed ref pinned at gate start (DND-735) =="

# DND-735: harness-gate runs for 11-15 minutes, and custom main moved about as
# often. Each check ran its own `git ls-remote` at its own moment, so a push to
# origin mid-run turned every landed-ref check red with "the local landed ref
# disagrees with origin", for a reason unrelated to the change. harness-gate
# now reads origin's main ONCE at start and hands every check that pin
# (ATHENA_LANDED_PIN_SHA, keyed to the repository by ATHENA_LANDED_PIN_REPO).
# The bar is still origin's main, as of the gate start; a local ref that is not
# that commit (or a later one fetched from origin) still fails.

# pin <root> <sha>: set PIN to the env harness-gate hands a check for <root>.
pin() { PIN=(env "ATHENA_LANDED_PIN_SHA=$2" "ATHENA_LANDED_PIN_REPO=$(realpath "$1/.git")"); }

# run_pinned <root>: run the fixture's checker under PIN.
run_pinned() {
  OUT="$(cd "$1" && "${PIN[@]}" ruby ai/bin/check-guard-messages 2>&1)"; RC=$?
}

# move_origin <root>: another machine lands a commit on origin's main (the
# fixture's own refs are untouched). Prints the new origin tip.
move_origin() {
  local mover="$1.mover.$RANDOM"
  git clone -q -b main "$1.origin.git" "${mover}" >/dev/null 2>&1
  git -C "${mover}" -c user.name=other -c user.email=other@example.invalid \
    commit -q --allow-empty -m "landed elsewhere" >/dev/null 2>&1
  git -C "${mover}" push -q origin HEAD:refs/heads/main >/dev/null 2>&1
  git -C "${mover}" rev-parse HEAD
}

# 36. THE DEFECT: the gate pinned origin's main at P; origin moved to Q while
#     the gate ran; nothing was fetched. Before the fix the check ignored the
#     pin, read Q live, and failed with a mismatch. Now it measures P -> PASS,
#     and the OK line names P as the pinned tip.
R="$(new_fixture pinned-moved)"; track "${R}"
P="$(git -C "${R}" rev-parse refs/remotes/origin/main)"; pin "${R}" "${P}"
Q="$(move_origin "${R}")"; run_pinned "${R}"
if [ "${RC}" -eq 0 ] && printf '%s' "${OUT}" | grep -F "${P:0:12}" >/dev/null \
   && printf '%s' "${OUT}" | grep -F 'pinned' >/dev/null && [ "${P}" != "${Q}" ]; then
  ok "36 origin moving mid-gate does not redden a check pinned at gate start"
else bad "36 origin moving mid-gate does not redden a check pinned at gate start" "rc=${RC} P=${P} Q=${Q} out=${OUT}"; fi

# 36b. The same move, with no pin (the check run by hand): the live cross-check
#      still fails, exactly as before DND-735.
run "${R}"
if [ "${RC}" -ne 0 ] && printf '%s' "${OUT}" | grep -F "${Q}" >/dev/null \
   && printf '%s' "${OUT}" | grep -F 'Fix:' >/dev/null; then
  ok "36b unpinned, a moved origin still fails the live cross-check"
else bad "36b unpinned, a moved origin still fails the live cross-check" "rc=${RC} out=${OUT}"; fi

# 36c. A sibling session fetched mid-gate: the shared local ref moved to Q, a
#      descendant of the pin. The bar stays P -> PASS naming P.
git -C "${R}" fetch -q origin >/dev/null 2>&1; run_pinned "${R}"
if [ "${RC}" -eq 0 ] && printf '%s' "${OUT}" | grep -F "${P:0:12}" >/dev/null \
   && [ "$(git -C "${R}" rev-parse refs/remotes/origin/main)" = "${Q}" ]; then
  ok "36c a fetch mid-gate (local ref now ahead of the pin) still measures the pin"
else bad "36c a fetch mid-gate (local ref now ahead of the pin) still measures the pin" "rc=${RC} out=${OUT}"; fi

# 37. A forged local ref with a pin: the relabel is committed and the local ref
#     moved onto it by hand. The bar is the pin, not the local ref -> FAIL, the
#     weakened guard named.
R="$(new_fixture pinned-forged)"
add_exec "${R}" scripts/some-gate "${GUARDED}"
classify "${R}" scripts/some-gate guard ""; land "${R}"
REAL="$(git -C "${R}" rev-parse HEAD)"; pin "${R}" "${REAL}"
reclassify "${R}" scripts/some-gate tool "${TOOL_REASON}"
add_exec "${R}" scripts/some-gate "${BARE}"; track "${R}"
git -C "${R}" -c user.name=fixture -c user.email=fixture@example.invalid commit -q -m relabel >/dev/null 2>&1
git -C "${R}" update-ref refs/remotes/origin/main HEAD; run_pinned "${R}"
if [ "${RC}" -ne 0 ] && printf '%s' "${OUT}" | grep -F 'scripts/some-gate' >/dev/null \
   && printf '%s' "${OUT}" | grep -F 'Fix:' >/dev/null && ! printf '%s' "${OUT}" | grep -F 'OK' >/dev/null; then
  ok "37 a forged local ref cannot move a pinned bar: the relabel still fails"
else bad "37 a forged local ref cannot move a pinned bar: the relabel still fails" "rc=${RC} out=${OUT}"; fi

# 37b. The local ref is BEHIND the pin (origin moved before the gate started and
#      nobody fetched) -> FAIL, both SHAs named, with Fix:.
R="$(new_fixture pinned-behind)"; track "${R}"
P="$(git -C "${R}" rev-parse refs/remotes/origin/main)"; Q="$(move_origin "${R}")"
pin "${R}" "${Q}"; run_pinned "${R}"
if [ "${RC}" -ne 0 ] && printf '%s' "${OUT}" | grep -F "${P}" >/dev/null \
   && printf '%s' "${OUT}" | grep -F "${Q}" >/dev/null && printf '%s' "${OUT}" | grep -F 'Fix:' >/dev/null \
   && ! printf '%s' "${OUT}" | grep -F 'OK' >/dev/null; then
  ok "37b a local ref behind the pinned landed ref fails, both SHAs named"
else bad "37b a local ref behind the pinned landed ref fails, both SHAs named" "rc=${RC} out=${OUT}"; fi

# 37c. The local ref DIVERGED from the pin (a commit that does not descend from
#      it, moved there by hand) -> FAIL, both SHAs named.
R="$(new_fixture pinned-diverged)"; track "${R}"
P="$(git -C "${R}" rev-parse refs/remotes/origin/main)"; pin "${R}" "${P}"
D="$(git -C "${R}" -c user.name=f -c user.email=f@example.invalid commit-tree -m diverged "${P}^{tree}")"
git -C "${R}" update-ref refs/remotes/origin/main "${D}"; run_pinned "${R}"
if [ "${RC}" -ne 0 ] && printf '%s' "${OUT}" | grep -F "${P}" >/dev/null \
   && printf '%s' "${OUT}" | grep -F "${D}" >/dev/null && ! printf '%s' "${OUT}" | grep -F 'OK' >/dev/null; then
  ok "37c a local ref diverged from the pin fails, both SHAs named"
else bad "37c a local ref diverged from the pin fails, both SHAs named" "rc=${RC} out=${OUT}"; fi

# 38. A malformed pin is a missing measurement, never a fallback -> FAIL as
#     could-not-measure, naming the variable, with Fix:.
R="$(new_fixture pinned-malformed)"; track "${R}"
pin "${R}" "abc123"; run_pinned "${R}"
if [ "${RC}" -ne 0 ] && printf '%s' "${OUT}" | grep -F 'could not measure' >/dev/null \
   && printf '%s' "${OUT}" | grep -F 'ATHENA_LANDED_PIN_SHA' >/dev/null \
   && printf '%s' "${OUT}" | grep -F 'Fix:' >/dev/null; then
  ok "38 a malformed pin fails as could-not-measure, the variable named"
else bad "38 a malformed pin fails as could-not-measure, the variable named" "rc=${RC} out=${OUT}"; fi

# 38b. Half a pin (the SHA without its repository key) -> could-not-measure.
P="$(git -C "${R}" rev-parse refs/remotes/origin/main)"
OUT="$(cd "${R}" && env -u ATHENA_LANDED_PIN_REPO ATHENA_LANDED_PIN_SHA="${P}" ruby ai/bin/check-guard-messages 2>&1)"; RC=$?
if [ "${RC}" -ne 0 ] && printf '%s' "${OUT}" | grep -F 'could not measure' >/dev/null \
   && printf '%s' "${OUT}" | grep -F 'ATHENA_LANDED_PIN_REPO' >/dev/null; then
  ok "38b a pin SHA without its repository key fails as could-not-measure"
else bad "38b a pin SHA without its repository key fails as could-not-measure" "rc=${RC} out=${OUT}"; fi

# 39. A pin for ANOTHER repository is not this repository's bar: the check reads
#     origin live, so a moved origin still fails here (what a fixture repo under
#     a pinned gate gets).
R="$(new_fixture pinned-other-repo)"; track "${R}"
P="$(git -C "${R}" rev-parse refs/remotes/origin/main)"; Q="$(move_origin "${R}")"
PIN=(env "ATHENA_LANDED_PIN_SHA=${P}" "ATHENA_LANDED_PIN_REPO=${TMP}/some-other-repo/.git"); run_pinned "${R}"
if [ "${RC}" -ne 0 ] && printf '%s' "${OUT}" | grep -F "${Q}" >/dev/null; then
  ok "39 a pin keyed to another repository is not applied; origin is read live"
else bad "39 a pin keyed to another repository is not applied; origin is read live" "rc=${RC} out=${OUT}"; fi

echo "== check-guard-messages: live tree =="

# 12. The live tree: every first-party executable is classified and compliant.
if OUT="$("${LIVE_GIT_ENV[@]}" ruby "${AI_DIR}/bin/check-guard-messages" 2>&1)"; then
  ok "12 the live tree passes check-guard-messages"
else bad "12 the live tree passes check-guard-messages" "${OUT}"; fi

echo
echo "check-guard-messages self-test: ${PASS} passed, ${FAIL} failed"
if [ "${FAIL}" -ne 0 ]; then
  echo "Fix: a FAIL above names the coverage case the checker got wrong; see ai/bin/check-guard-messages's discovery/classification." >&2
  exit 1
fi
