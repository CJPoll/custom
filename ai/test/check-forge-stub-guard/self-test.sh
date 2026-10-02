#!/usr/bin/env bash
# Self-test for ai/bin/check-forge-stub-guard (DND-1666), end to end.
#
# The defect it pins: DND-1647 added ai/lib/forge-stub-guard.sh and converted
# the 10 suites that stub gh/glab on PATH, but nothing stopped a NEW suite from
# stubbing gh on PATH without the helper. Such a suite passed the gate, and the
# fall-through class (a missing or non-executable stub reaching the real forge
# CLI) could come back with no signal.
#
# DND-1680 (R10): the bar was only what this tree's scanner could see, so a
# landed guarded suite rewritten into a shape the scanner does not model, with
# the helper dropped, passed. The landed set is now read from origin/main.
#
# Each case builds a fixture repo, stages a fixture suite, and runs the check
# against it with --root. The fixture suites are data: nothing here runs them,
# and no gh or glab is ever executed.
#
# Hermetic: fixture repos under mktemp -d, a fake HOME, global/system git config
# replaced. Run another copy of the check (old-vs-new evidence) with
#   CHECK_UNDER_TEST=/path/to/check-forge-stub-guard bash ai/test/check-forge-stub-guard/self-test.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT="$(cd "${HERE}/../../.." && pwd -P)"
CHECK="${CHECK_UNDER_TEST:-${ROOT}/ai/bin/check-forge-stub-guard}"

TMP="$(mktemp -d)" || { echo "FAIL: mktemp"; exit 1; }
trap 'rm -rf "${TMP}"' EXIT INT TERM
PASS=0; FAIL=0
ok()  { printf '  ok    %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  FAIL  %s\n        %s\n' "$1" "$2"; FAIL=$((FAIL+1)); }

# ---- hermetic git ---------------------------------------------------------------
for v in $(env | sed -n 's/^\(GIT_CONFIG_\(KEY\|VALUE\)_[0-9]*\)=.*/\1/p'); do unset "$v"; done
unset GIT_CONFIG_COUNT GIT_CONFIG_PARAMETERS GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR
export HOME="${TMP}/home"; mkdir -p "${HOME}"
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL="${TMP}/gitconfig"
printf '[user]\n\tname = t\n\temail = t@t\n[init]\n\tdefaultBranch = main\n' > "${GIT_CONFIG_GLOBAL}"
export GIT_TERMINAL_PROMPT=0

# ---- fixture suites (data; written into fixture repos, never run) ----------------
write_unguarded() { # a suite that stubs gh on PATH with no helper: the defect
  cat > "$1" <<'SUITE'
#!/usr/bin/env bash
set -uo pipefail
TMP="$(mktemp -d)"
mkdir -p "${TMP}/bin"
cat > "${TMP}/bin/gh" <<'EOF'
#!/bin/sh
echo '{"state":"MERGED"}'
EOF
chmod +x "${TMP}/bin/gh"
export PATH="${TMP}/bin:${PATH}"
gh pr view 7
SUITE
}

write_guarded() { # the same suite, converted the DND-1647 way
  cat > "$1" <<'SUITE'
#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
TMP="$(mktemp -d)"
mkdir -p "${TMP}/bin"
. "${HERE}/../../lib/forge-stub-guard.sh"
fsg_arm "${TMP}/forge-guard"
cat > "${TMP}/bin/gh" <<'EOF'
#!/bin/sh
echo '{"state":"MERGED"}'
EOF
chmod +x "${TMP}/bin/gh"
fsg_require_stubs "${TMP}/bin" gh
export PATH="${TMP}/bin:${PATH}"
gh pr view 7
fsg_verify || exit 1
SUITE
}

write_loop_unguarded() { # strict-argv-cli's shape: stubs written in a loop, no helper
  cat > "$1" <<'SUITE'
#!/usr/bin/env bash
TMP="$(mktemp -d)"; mkdir -p "${TMP}/stubs"
for s in gh glab gh-athena; do
  cat > "${TMP}/stubs/${s}" <<EOF
#!/bin/sh
exit 1
EOF
  chmod +x "${TMP}/stubs/${s}"
done
export PATH="${TMP}/stubs:${PATH}"
SUITE
}

write_env_selected() { # a gh stub chosen by env var, never put on PATH
  cat > "$1" <<'SUITE'
#!/usr/bin/env bash
FAKE="$(mktemp -d)"
printf '#!/bin/sh\nexit 0\n' > "$FAKE/gh"
chmod +x "$FAKE/gh"
export TOOL_GH="$FAKE/gh"
GITSHIM="$(mktemp -d)"
out="$(PATH="$GITSHIM:$PATH" true)"
SUITE
}

write_git_unguarded() { # DND-1667: a git shim on PATH with no helper
  cat > "$1" <<'SUITE'
#!/usr/bin/env bash
TMP="$(mktemp -d)"; mkdir -p "${TMP}/gitshim"
cat > "${TMP}/gitshim/git" <<'EOF'
#!/bin/sh
echo "fatal: shim" >&2; exit 128
EOF
chmod +x "${TMP}/gitshim/git"
out="$(PATH="${TMP}/gitshim:${PATH}" run_under_test)"
SUITE
}

write_git_guarded() { # the same suite, guarded with fsg_make (git is also used for real)
  cat > "$1" <<'SUITE'
#!/usr/bin/env bash
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
TMP="$(mktemp -d)"; mkdir -p "${TMP}/gitshim"
. "${HERE}/../../lib/forge-stub-guard.sh"
fsg_make "${TMP}/git-guard" git
cat > "${TMP}/gitshim/git" <<'EOF'
#!/bin/sh
echo "fatal: shim" >&2; exit 128
EOF
chmod +x "${TMP}/gitshim/git"
fsg_require_stubs "${TMP}/gitshim" git
out="$(PATH="${TMP}/gitshim:${FSG_DIR}:${PATH}" run_under_test)"
fsg_verify || exit 1
SUITE
}

write_git_guard_off_path() { # fsg_make, but the guard is never put behind the shim
  cat > "$1" <<'SUITE'
#!/usr/bin/env bash
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
TMP="$(mktemp -d)"; mkdir -p "${TMP}/gitshim"
. "${HERE}/../../lib/forge-stub-guard.sh"
fsg_make "${TMP}/git-guard" git
printf '#!/bin/sh\nexit 128\n' > "${TMP}/gitshim/git"
out="$(PATH="${TMP}/gitshim:${PATH}" run_under_test)"
fsg_verify || exit 1
SUITE
}

write_unmodeled_unguarded() { # DND-1680: the guarded suite rewritten into a shape
  # the scanner does not model (a stub written through a helper function), with
  # the helper dropped. Its stub still sits on PATH, unguarded.
  cat > "$1" <<'SUITE'
#!/usr/bin/env bash
set -uo pipefail
TMP="$(mktemp -d)"
mkdir -p "${TMP}/bin"
mkstub() { printf '#!/bin/sh\necho {}\n' > "$1"; chmod +x "$1"; }
mkstub "${TMP}/bin/gh"
export PATH="${TMP}/bin:${PATH}"
gh pr view 7
SUITE
}

write_guarded_relative_unguarded() { # write_guarded, moved: the helper dropped and
  # the stub written to a relative path (`cd D; cat > gh`, not modeled)
  cat > "$1" <<'SUITE'
#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
TMP="$(mktemp -d)"
mkdir -p "${TMP}/bin"
cd "${TMP}/bin" && cat > gh <<'EOF'
#!/bin/sh
echo '{"state":"MERGED"}'
EOF
chmod +x "${TMP}/bin/gh"
export PATH="${TMP}/bin:${PATH}"
gh pr view 7
SUITE
}

write_unmodeled_guarded() { # the same unmodeled shape, helper kept
  cat > "$1" <<'SUITE'
#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
TMP="$(mktemp -d)"
mkdir -p "${TMP}/bin"
. "${HERE}/../../lib/forge-stub-guard.sh"
fsg_arm "${TMP}/forge-guard"
mkstub() { printf '#!/bin/sh\necho {}\n' > "$1"; chmod +x "$1"; }
mkstub "${TMP}/bin/gh"
fsg_require_stubs "${TMP}/bin" gh
export PATH="${TMP}/bin:${PATH}"
gh pr view 7
fsg_verify || exit 1
SUITE
}

# The check's ratchet (DND-1680) reads what LANDED on origin/main, so every
# fixture repo has a local bare origin: landed_fixture lands a baseline README,
# and the suites under test are written on top of it. No network, no real
# origin; a gate pin is keyed to the real repo, so it does not apply here.
. "${ROOT}/ai/test/lib/landed-fixture.bash"
SRC="${TMP}/src"; mkdir -p "${SRC}"; printf 'fixture\n' > "${SRC}/README"

# write_specs <repo> <rel-path>=<writer>... : write each suite into the repo.
write_specs() {
  local r="$1" spec rel writer; shift
  for spec in "$@"; do
    rel="${spec%%=*}"; writer="${spec#*=}"
    mkdir -p "${r}/$(dirname "${rel}")"
    "${writer}" "${r}/${rel}"
  done
}

# mk_repo <name> <rel-path>=<writer>... : a fixture repo with a README landed
# on its origin/main and each suite staged on top (not landed).
mk_repo() {
  local r="${TMP}/$1"; shift
  landed_fixture "${SRC}" "${r}" README || return 1
  write_specs "${r}" "$@"
  git -C "${r}" add -A
  printf '%s' "${r}"
}

# mk_landed_repo <name> <rel-path>=<writer>... : each suite LANDED on the
# fixture's origin/main, the bar the ratchet reads.
mk_landed_repo() {
  local r="${TMP}/$1"; shift
  landed_fixture "${SRC}" "${r}" README || return 1
  write_specs "${r}" "$@"
  landed_fixture_land "${r}" || return 1
  printf '%s' "${r}"
}

run_check() { OUT="$("${CHECK}" --root "$1" 2>&1)"; RC=$?; }

has() { case "${OUT}" in *"$1"*) return 0 ;; esac; return 1; }

echo "check-forge-stub-guard self-test (check: ${CHECK})"

echo "--- R1: a new suite stubbing gh on PATH without the helper FAILS (the DND-1666 defect) ---"
R="$(mk_repo r1 ai/test/guarded/self-test.sh=write_guarded ai/test/newsuite/self-test.sh=write_unguarded)"
run_check "${R}"
if [ "${RC}" = 1 ] && has "ai/test/newsuite/self-test.sh" && has "Fix:" && has "forge-stub-guard.sh"; then
  ok "R1. the unguarded suite is named, exit 1, with a Fix: naming ai/lib/forge-stub-guard.sh"
else bad "R1. the unguarded suite is flagged" "rc=${RC} out=$(printf '%s' "${OUT}" | head -c 400)"; fi
if has "ai/test/guarded/self-test.sh:"; then
  bad "R1b. the guarded suite in the same repo is not flagged" "out=$(printf '%s' "${OUT}" | head -c 400)"
else ok "R1b. the guarded suite in the same repo is not flagged"; fi

echo "--- R1c: stubs written in a for loop, no helper, FAIL ---"
R="$(mk_repo r1c ai/test/guarded/self-test.sh=write_guarded ai/test/loop/self-test.sh=write_loop_unguarded)"
run_check "${R}"
if [ "${RC}" = 1 ] && has "ai/test/loop/self-test.sh" && has "gh/glab on PATH but never sources"; then
  ok "R1c. a loop-written gh/glab stub on PATH without the helper is flagged"
else bad "R1c. loop-written stubs are flagged" "rc=${RC} out=$(printf '%s' "${OUT}" | head -c 400)"; fi

echo "--- R9: a git shim on PATH without the helper FAILS (the DND-1667 defect) ---"
R="$(mk_repo r9 ai/test/guarded/self-test.sh=write_guarded ai/test/gitshim/self-test.sh=write_git_unguarded \
  ai/test/gitguarded/self-test.sh=write_git_guarded)"
run_check "${R}"
if [ "${RC}" = 1 ] && has "ai/test/gitshim/self-test.sh" && has "git on PATH but never sources" && has "Fix:"; then
  ok "R9a. an unguarded git shim on PATH is named, exit 1, with a Fix:"
else bad "R9a. an unguarded git shim on PATH is flagged" "rc=${RC} out=$(printf '%s' "${OUT}" | head -c 400)"; fi
if has "ai/test/gitguarded/self-test.sh:"; then
  bad "R9b. a git shim guarded by fsg_make, guard right behind it, is not flagged" "out=$(printf '%s' "${OUT}" | head -c 400)"
else ok "R9b. a git shim guarded by fsg_make, guard right behind it, is not flagged"; fi
R="$(mk_repo r9c ai/test/guarded/self-test.sh=write_guarded ai/test/offpath/self-test.sh=write_git_guard_off_path)"
run_check "${R}"
if [ "${RC}" = 1 ] && has "ai/test/offpath/self-test.sh" && has "not the guard"; then
  ok "R9c. fsg_make whose guard never sits behind the shim on PATH is flagged"
else bad "R9c. a guard off PATH is flagged" "rc=${RC} out=$(printf '%s' "${OUT}" | head -c 400)"; fi

echo "--- R2: a suite that sources the helper, arms and verifies PASSES ---"
R="$(mk_repo r2 ai/test/guarded/self-test.sh=write_guarded)"
run_check "${R}"
if [ "${RC}" = 0 ] && has "OK" && has "1 stubbing gh/glab/git/docker/curl/claude on PATH"; then
  ok "R2. exit 0; the OK line counts the suite that stubs on PATH"
else bad "R2. a guarded suite passes" "rc=${RC} out=$(printf '%s' "${OUT}" | head -c 400)"; fi

echo "--- R3: a gh stub selected by env var (its directory never on PATH) is not flagged ---"
R="$(mk_repo r3 ai/test/guarded/self-test.sh=write_guarded ai/test/envsel/self-test.sh=write_env_selected)"
run_check "${R}"
if [ "${RC}" = 0 ]; then ok "R3. an env-var-selected stub passes"
else bad "R3. an env-var-selected stub passes" "rc=${RC} out=$(printf '%s' "${OUT}" | head -c 400)"; fi

echo "--- R4: an untracked unguarded suite is not first-party yet; staged, it is read ---"
R="$(mk_repo r4 ai/test/guarded/self-test.sh=write_guarded)"
mkdir -p "${R}/ai/test/wip"; write_unguarded "${R}/ai/test/wip/self-test.sh"
run_check "${R}"
if [ "${RC}" = 0 ]; then ok "R4a. untracked: not read"
else bad "R4a. untracked: not read" "rc=${RC} out=$(printf '%s' "${OUT}" | head -c 300)"; fi
git -C "${R}" add -A
run_check "${R}"
if [ "${RC}" = 1 ] && has "ai/test/wip/self-test.sh"; then ok "R4b. staged: flagged"
else bad "R4b. staged: flagged" "rc=${RC} out=$(printf '%s' "${OUT}" | head -c 300)"; fi

echo "--- R5: found nothing and could not look both FAIL, and never print the same line ---"
R="$(mk_repo r5)"
run_check "${R}"
if [ "${RC}" = 1 ] && has "FOUND NOTHING" && ! has "COULD NOT LOOK" && has "Fix:"; then
  ok "R5a. a repo with no test suites: FOUND NOTHING, exit 1"
else bad "R5a. empty discovery fails" "rc=${RC} out=$(printf '%s' "${OUT}" | head -c 300)"; fi
R="$(mk_repo r5b ai/test/envsel/self-test.sh=write_env_selected)"
run_check "${R}"
if [ "${RC}" = 1 ] && has "FOUND NOTHING"; then
  ok "R5b. suites but none stubbing on PATH: FOUND NOTHING, exit 1"
else bad "R5b. zero PATH-stubbing suites fails" "rc=${RC} out=$(printf '%s' "${OUT}" | head -c 300)"; fi
mkdir -p "${TMP}/notgit"
run_check "${TMP}/notgit"
if [ "${RC}" = 1 ] && has "COULD NOT LOOK" && ! has "FOUND NOTHING" && has "Fix:"; then
  ok "R5c. not a git checkout: COULD NOT LOOK, exit 1"
else bad "R5c. discovery that cannot run fails" "rc=${RC} out=$(printf '%s' "${OUT}" | head -c 300)"; fi

echo "--- R10: the landed guarded set is a ratchet (DND-1680) ---"
# The defect: the bar was only what this tree's scanner can see. A guarded
# suite rewritten into a shape the scanner does not model, with the helper
# dropped, left the scan and passed. The landed set is read from origin/main.
R="$(mk_landed_repo r10a ai/test/guarded/self-test.sh=write_guarded ai/test/victim/self-test.sh=write_guarded)"
write_unmodeled_unguarded "${R}/ai/test/victim/self-test.sh"; git -C "${R}" add -A
run_check "${R}"
if [ "${RC}" = 1 ] && has "ai/test/victim/self-test.sh" && has "landed" && has "Fix:"; then
  ok "R10a. a landed guarded suite rewritten unmodeled, helper dropped: named, exit 1, with a Fix:"
else bad "R10a. a landed guarded suite that drops the helper fails" "rc=${RC} out=$(printf '%s' "${OUT}" | head -c 600)"; fi

R="$(mk_landed_repo r10b ai/test/guarded/self-test.sh=write_guarded ai/test/kept/self-test.sh=write_guarded)"
write_unmodeled_guarded "${R}/ai/test/kept/self-test.sh"; git -C "${R}" add -A
run_check "${R}"
if [ "${RC}" = 1 ] && has "ai/test/kept/self-test.sh" && has "no longer reads as stubbing" \
   && ! has "kept/self-test.sh: landed guarded, but no longer sources"; then
  ok "R10b. rewritten unmodeled, helper kept: fails (its guard order can no longer be seen), named"
else bad "R10b. an unmodeled rewrite that keeps the helper fails, named" "rc=${RC} out=$(printf '%s' "${OUT}" | head -c 600)"; fi

R="$(mk_landed_repo r10c ai/test/guarded/self-test.sh=write_guarded ai/test/old/self-test.sh=write_guarded)"
git -C "${R}" rm -q ai/test/old/self-test.sh
mkdir -p "${R}/ai/test/new"; write_guarded_relative_unguarded "${R}/ai/test/new/self-test.sh"; git -C "${R}" add -A
run_check "${R}"
if [ "${RC}" = 1 ] && has "ai/test/new/self-test.sh" && has "ai/test/old/self-test.sh"; then
  ok "R10c. a landed guarded suite MOVED and stripped of the helper: the new path fails, naming the old"
else bad "R10c. a moved suite keeps its landed bar" "rc=${RC} out=$(printf '%s' "${OUT}" | head -c 600)"; fi

R="$(mk_landed_repo r10d ai/test/guarded/self-test.sh=write_guarded ai/test/gone/self-test.sh=write_guarded)"
git -C "${R}" rm -q ai/test/gone/self-test.sh
run_check "${R}"
if [ "${RC}" = 0 ] && has "removed" && has "ai/test/gone/self-test.sh"; then
  ok "R10d. a landed guarded suite deleted outright: passes, and is named as removed"
else bad "R10d. a removed suite is named" "rc=${RC} out=$(printf '%s' "${OUT}" | head -c 600)"; fi

R="$(mk_repo r10e ai/test/guarded/self-test.sh=write_guarded ai/test/fresh/self-test.sh=write_guarded)"
run_check "${R}"
if [ "${RC}" = 0 ] && has "new" && has "ai/test/fresh/self-test.sh"; then
  ok "R10e. a suite stubbing on PATH that has not landed yet: passes, and is named as new"
else bad "R10e. a new suite is named" "rc=${RC} out=$(printf '%s' "${OUT}" | head -c 600)"; fi

R="${TMP}/r10f"; git init -q "${R}"
write_specs "${R}" ai/test/guarded/self-test.sh=write_guarded; git -C "${R}" add -A
run_check "${R}"
if [ "${RC}" = 1 ] && has "could not measure" && has "refs/remotes/origin/main" && has "Fix:"; then
  ok "R10f. no landed bar to read (no origin/main): could not measure, exit 1, every probe named"
else bad "R10f. an unmeasurable bar fails" "rc=${RC} out=$(printf '%s' "${OUT}" | head -c 600)"; fi

echo "--- R6: this repo, as it stands, passes ---"
OUT="$(cd "${ROOT}" && "${CHECK}" 2>&1)"; RC=$?
if [ "${RC}" = 0 ]; then ok "R6. the live repo passes (${OUT})"
else bad "R6. the live repo passes" "rc=${RC} out=$(printf '%s' "${OUT}" | head -c 600)"; fi

echo "--- R7: --help answers on stdout, exit 0 ---"
OUT="$("${CHECK}" --help 2>/dev/null)"; RC=$?
if [ "${RC}" = 0 ] && has "Usage"; then ok "R7. --help"
else bad "R7. --help" "rc=${RC} out=$(printf '%s' "${OUT}" | head -c 200)"; fi

echo "--- R8: the gate declares the check and its self-test ---"
LIST="$(cd "${ROOT}" && ./ai/bin/harness-gate --list 2>/dev/null)"
case "${LIST}" in
  *"ai/bin/check-forge-stub-guard --self-test"*) ok "R8a. harness-gate --list runs check-forge-stub-guard --self-test" ;;
  *) bad "R8a. self-test declared in harness-gate" "not in harness-gate --list" ;;
esac
if printf '%s\n' "${LIST}" | grep -E 'ai/bin/check-forge-stub-guard$' >/dev/null; then
  ok "R8b. harness-gate --list runs ai/bin/check-forge-stub-guard"
else bad "R8b. live check declared in harness-gate" "not in harness-gate --list"; fi

echo
echo "check-forge-stub-guard self-test: ${PASS} passed, ${FAIL} failed"
[ "${FAIL}" = 0 ]
