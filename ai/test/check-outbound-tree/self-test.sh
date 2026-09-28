#!/usr/bin/env bash
# Self-test for ai/bin/check-outbound-tree, the harness-gate tree scan
# (DND-699 part 2; the design's QA case 13).
#
# The matrix: the machine mark (the outbound pre-push hook installed or not, or
# undeterminable) x the overlay (absent, malformed, zero patterns, no committed
# floor, hits, clean). Only ABSENT on a machine known to be unmarked may pass
# unscanned, and that pass must never read as CLEAN.
#
# Hermetic: fixture repos and fixture overlays under mktemp -d, a fake HOME,
# the global/system git config replaced. Synthetic values only (SYNTH-TOKEN-1).
# The real overlay is never read and no real hook is touched: the "hook" is a
# marker file written into FIXTURE repos' .git/hooks only.
#
# Run another copy of the check (old-vs-new evidence) with
#   CHECK_UNDER_TEST=/path/to/check-outbound-tree bash ai/test/check-outbound-tree/self-test.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT="$(cd "${HERE}/../../.." && pwd -P)"
CHECK="${CHECK_UNDER_TEST:-${ROOT}/ai/bin/check-outbound-tree}"

TMP="$(mktemp -d)" || { echo "FAIL: mktemp"; exit 1; }
trap 'chmod -R u+rwx "${TMP}" 2>/dev/null; rm -rf "${TMP}"' EXIT INT TERM
PASS=0; FAIL=0; SKIP=0
ok()  { printf '  ok    %s\n' "$1"; PASS=$((PASS+1)); }
skip() { printf '  SKIP  %s\n' "$1"; SKIP=$((SKIP+1)); }
bad() { printf '  FAIL  %s\n        %s\n' "$1" "$2"; FAIL=$((FAIL+1)); }

TOKEN="SYNTH-TOKEN-1"

# ---- hermetic environment ---------------------------------------------------
for v in $(env | sed -n 's/^\(GIT_CONFIG_\(KEY\|VALUE\)_[0-9]*\)=.*/\1/p'); do unset "$v"; done
unset GIT_CONFIG_COUNT GIT_CONFIG_PARAMETERS GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR \
  ATHENA_OUTBOUND_WAIVE ATHENA_PRIVATE_ROOT XDG_STATE_HOME
export HOME="${TMP}/home"; mkdir -p "${HOME}"
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL="${TMP}/gitconfig"
printf '[user]\n\tname = t\n\temail = t@t\n[init]\n\tdefaultBranch = main\n' > "${GIT_CONFIG_GLOBAL}"
export GIT_TERMINAL_PROMPT=0

# ---- fixtures -----------------------------------------------------------------
# mk_overlay <dir> <patterns> [nogit] : a git-backed overlay (patterns committed).
mk_overlay() {
  local d="$1"
  mkdir -p "${d}/outbound" && chmod 700 "${d}"
  printf '{"kind":"athena-private-overlay","schema":1}\n' > "${d}/athena-overlay.json"
  printf '%b' "$2" > "${d}/outbound/patterns.tsv"
  if [ "${3:-}" != nogit ]; then
    git -C "${d}" init -q && git -C "${d}" add -A && git -C "${d}" commit -q -m overlay
  fi
}
PATTERNS='# synthetic fixture patterns\nsynth-token\tSYNTH-TOKEN-[0-9]+\n'
mk_overlay "${TMP}/ov-good" "${PATTERNS}"
mk_overlay "${TMP}/ov-zero" '# nothing but a comment\n'
mk_overlay "${TMP}/ov-nofloor" "${PATTERNS}" nogit
GOOD="${TMP}/ov-good"; ZERO="${TMP}/ov-zero"; NOFLOOR="${TMP}/ov-nofloor"

# mk_repo <name> <clean|dirty> <marked|unmarked|foreign> : a fixture public repo.
mk_repo() {
  local r="${TMP}/$1"
  git init -q "${r}"
  printf 'hello\n' > "${r}/README"
  if [ "$2" = dirty ]; then printf 'line one\ncontact %s\n' "${TOKEN}" > "${r}/notes.md"; fi
  git -C "${r}" add -A && git -C "${r}" commit -q -m init
  case "$3" in
    marked)  printf '#!/bin/sh\nexec "$HOME/x/ai/git-hooks/outbound-pre-push.sh" "$@"\n' > "${r}/.git/hooks/pre-push" ;;
    foreign) printf '#!/bin/sh\necho some other hook\n' > "${r}/.git/hooks/pre-push" ;;
  esac
  printf '%s' "${r}"
}

# run_check <repo> [env assignments...] -> OUT, RC
run_check() {
  local r="$1"; shift
  OUT="$(cd "${r}" && env "$@" "${CHECK}" 2>&1)"; RC=$?
}

# expect <name> <rc> <first-line glob> [extra glob...]
expect() {
  local name="$1" want_rc="$2" first="$3"; shift 3
  local line1="${OUT%%$'\n'*}" g
  if [ "${RC}" != "${want_rc}" ]; then bad "${name}" "rc=${RC} want ${want_rc}: ${OUT}"; return; fi
  # shellcheck disable=SC2053
  if [[ "${line1}" != ${first} ]]; then bad "${name}" "first line: ${line1}"; return; fi
  for g in "$@"; do
    # shellcheck disable=SC2053
    if [[ "${OUT}" != ${g} ]]; then bad "${name}" "missing ${g}: ${OUT}"; return; fi
  done
  if [[ "${OUT}" == *"${TOKEN}"* ]]; then bad "${name}" "the literal was printed"; return; fi
  ok "${name}"
}

ABSENT_ENV=(-u ATHENA_PRIVATE_ROOT HOME="${HOME}")
MALFORMED_ENV=(ATHENA_PRIVATE_ROOT=relative/path)

echo "check-outbound-tree self-test"
echo "check: ${CHECK}"
echo

echo "--- help and usage ---"
OUT="$("${CHECK}" --help 2>/dev/null)"; RC=$?
if [ "${RC}" = 0 ] && [[ "${OUT}" == *"Usage:"* ]] && [[ "${OUT}" == *"NOT MEASURED"* ]]; then ok "--help on stdout, exit 0"; else bad "--help" "rc=${RC}"; fi
OUT="$("${CHECK}" --bogus 2>&1)"; RC=$?
if [ "${RC}" = 2 ] && [[ "${OUT}" == *"Fix:"* ]]; then ok "an unknown argument is USAGE (exit 2) with Fix:"; else bad "usage" "rc=${RC} ${OUT}"; fi

for m in marked unmarked; do
  echo "--- ${m} machine ---"
  CLEAN_R="$(mk_repo "clean-${m}" clean "${m}")"
  DIRTY_R="$(mk_repo "dirty-${m}" dirty "${m}")"

  run_check "${DIRTY_R}" ATHENA_PRIVATE_ROOT="${GOOD}"
  expect "${m} + hits: FAIL with file:line + label, never the literal" 1 "check-outbound-tree: FAIL: HITS: 1 match(es)*" \
    "*notes.md:2 label=synth-token*" "*SCANNED commits=0 lines=3 patterns=1 hits=1*" "*Fix:*"

  run_check "${CLEAN_R}" ATHENA_PRIVATE_ROOT="${GOOD}"
  expect "${m} + clean: CLEAN with the counts line" 0 "check-outbound-tree: CLEAN:*" "*SCANNED commits=0 lines=1 patterns=1 hits=0*"

  run_check "${CLEAN_R}" "${MALFORMED_ENV[@]}"
  expect "${m} + malformed overlay: FAIL COULD NOT MEASURE" 3 "check-outbound-tree: FAIL: COULD NOT MEASURE: the private overlay is MALFORMED*" \
    "*NOT SCANNED*" "*Fix:*"

  run_check "${CLEAN_R}" ATHENA_PRIVATE_ROOT="${ZERO}"
  expect "${m} + zero patterns: FAIL COULD NOT MEASURE" 3 "check-outbound-tree: FAIL: COULD NOT MEASURE: *zero patterns*" "*Fix:*"

  run_check "${CLEAN_R}" ATHENA_PRIVATE_ROOT="${NOFLOOR}"
  expect "${m} + no committed floor: FAIL COULD NOT MEASURE" 3 "check-outbound-tree: FAIL: COULD NOT MEASURE: *committed floor*" "*Fix:*"
done

echo "--- absent overlay: the mark decides ---"
run_check "${TMP}/clean-marked" "${ABSENT_ENV[@]}"
expect "marked + absent: FAIL COULD NOT MEASURE" 3 "check-outbound-tree: FAIL: COULD NOT MEASURE: the private overlay is ABSENT*" \
  "*is marked*" "*NOT SCANNED*" "*Fix:*"

run_check "${TMP}/clean-unmarked" "${ABSENT_ENV[@]}"
expect "unmarked + absent: passes NOT MEASURED" 0 "check-outbound-tree: NOT MEASURED (no overlay on this unmarked machine; probed ${HOME}/.config/athena/work)" \
  "*not a clean result*" "*hook probed: ${TMP}/clean-unmarked/.git/hooks/pre-push*"
if [[ "${OUT}" != *CLEAN:* ]] && [[ "${OUT}" != *" OK"* ]] && [[ "${OUT}" != *SCANNED* ]]; then
  ok "unmarked + absent: the pass never reads as CLEAN, OK or SCANNED"
else
  bad "NOT MEASURED distinct from CLEAN" "${OUT}"
fi

run_check "${TMP}/dirty-unmarked" "${ABSENT_ENV[@]}"
expect "unmarked + absent, a tree that WOULD hit: still NOT MEASURED (nothing to measure with)" 0 "check-outbound-tree: NOT MEASURED*"

FOREIGN_R="$(mk_repo foreign clean foreign)"
run_check "${FOREIGN_R}" "${ABSENT_ENV[@]}"
expect "a foreign pre-push hook is not the mark: NOT MEASURED" 0 "check-outbound-tree: NOT MEASURED*"

echo "--- a mark that cannot be determined counts as marked ---"
mkdir -p "${TMP}/not-a-repo"
run_check "${TMP}/not-a-repo" "${ABSENT_ENV[@]}"
expect "no git repository + absent: FAIL (unknown mark)" 3 "check-outbound-tree: FAIL: COULD NOT MEASURE: the private overlay is ABSENT*" \
  "*could not be determined*" "*Fix:*"

UNREAD_R="$(mk_repo unreadable clean marked)"
chmod 000 "${UNREAD_R}/.git/hooks/pre-push"
if [ -r "${UNREAD_R}/.git/hooks/pre-push" ]; then
  skip "unreadable hook (running as a user that reads mode-000 files)"
else
  run_check "${UNREAD_R}" "${ABSENT_ENV[@]}"
  expect "unreadable hook + absent: FAIL (unknown mark)" 3 "check-outbound-tree: FAIL: COULD NOT MEASURE*" "*could not be determined*"
fi
chmod 600 "${UNREAD_R}/.git/hooks/pre-push"

DANGLE_R="$(mk_repo dangling clean unmarked)"
ln -s "${TMP}/does-not-exist" "${DANGLE_R}/.git/hooks/pre-push"
run_check "${DANGLE_R}" "${ABSENT_ENV[@]}"
# git resolves the hook symlink itself, and never runs a dangling hook, so the
# machine is in fact unmarked; the output names the resolved target.
expect "dangling-symlink hook + absent: NOT MEASURED, naming the resolved target" 0 "check-outbound-tree: NOT MEASURED*" \
  "*hook probed: ${TMP}/does-not-exist*"

DIRHOOK_R="$(mk_repo dirhook clean unmarked)"
mkdir "${DIRHOOK_R}/.git/hooks/pre-push"
run_check "${DIRHOOK_R}" "${ABSENT_ENV[@]}"
expect "a directory at the hook path + absent: FAIL (unknown mark)" 3 "check-outbound-tree: FAIL: COULD NOT MEASURE*" "*could not be determined*"

echo "--- core.hooksPath is honoured, both ways ---"
HP_R="$(mk_repo hookspath clean marked)"
mkdir -p "${TMP}/elsewhere-hooks"
git -C "${HP_R}" config core.hooksPath "${TMP}/elsewhere-hooks"
run_check "${HP_R}" "${ABSENT_ENV[@]}"
expect "hooksPath elsewhere (no hook there) + absent: NOT MEASURED, naming that path" 0 "check-outbound-tree: NOT MEASURED*" \
  "*hook probed: ${TMP}/elsewhere-hooks/pre-push*"
cp "${HP_R}/.git/hooks/pre-push" "${TMP}/elsewhere-hooks/pre-push"
run_check "${HP_R}" "${ABSENT_ENV[@]}"
expect "hooksPath with the outbound hook + absent: FAIL (marked)" 3 "check-outbound-tree: FAIL: COULD NOT MEASURE*" "*is marked*" \
  "*hook probed: ${TMP}/elsewhere-hooks/pre-push*"

echo "--- a tracked path that itself matches is redacted ---"
PATH_R="$(mk_repo pathhit clean unmarked)"
mkdir -p "${PATH_R}/people" && printf 'plain\n' > "${PATH_R}/people/${TOKEN}.md"
git -C "${PATH_R}" add -A && git -C "${PATH_R}" commit -q -m path
run_check "${PATH_R}" ATHENA_PRIVATE_ROOT="${GOOD}"
expect "matching path: FAIL HITS, path redacted" 1 "check-outbound-tree: FAIL: HITS*" "*tracked path <redacted> label=synth-token*"

echo "--- a linked worktree resolves its main checkout's mark ---"
git -C "${TMP}/clean-marked" worktree add -q "${TMP}/wt-marked" -b wt 2>/dev/null
run_check "${TMP}/wt-marked" "${ABSENT_ENV[@]}"
expect "worktree of a marked checkout + absent: FAIL" 3 "check-outbound-tree: FAIL: COULD NOT MEASURE*" "*is marked*"
run_check "${TMP}/wt-marked" ATHENA_PRIVATE_ROOT="${GOOD}"
expect "worktree of a marked checkout + clean: CLEAN" 0 "check-outbound-tree: CLEAN:*"

echo "--- the push waiver is not honoured by the gate ---"
run_check "${TMP}/dirty-marked" ATHENA_PRIVATE_ROOT="${GOOD}" ATHENA_OUTBOUND_WAIVE=testing
expect "ATHENA_OUTBOUND_WAIVE set + hits: still FAIL" 1 "check-outbound-tree: FAIL: HITS*"
if [ ! -e "${HOME}/.local/state/athena/outbound-scan-waivers.log" ]; then ok "no waiver was logged"; else bad "waiver log" "written"; fi

echo "--- an index copy is scanned, not the working-tree file ---"
printf 'hello\n' > "${TMP}/dirty-marked/notes.md"
run_check "${TMP}/dirty-marked" ATHENA_PRIVATE_ROOT="${GOOD}"
expect "an unstaged edit that removes the value does not hide the tracked copy" 1 "check-outbound-tree: FAIL: HITS*"

echo "--- the gate declares the check ---"
if (cd "${ROOT}" && ./ai/bin/harness-gate --list 2>/dev/null) | grep -F 'ai/bin/check-outbound-tree' >/dev/null; then
  ok "harness-gate --list runs ai/bin/check-outbound-tree"
else
  bad "declared in harness-gate" "not in harness-gate --list"
fi

echo
echo "check-outbound-tree self-test: ${PASS} passed, ${FAIL} failed, ${SKIP} skipped"
[ "${FAIL}" = 0 ]
