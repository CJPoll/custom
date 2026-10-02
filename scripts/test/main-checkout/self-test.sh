#!/usr/bin/env bash
# Self-test for scripts/lib/main-checkout.sh (DND-1720): the main checkout from
# a main checkout and from a linked worktree, and an error, never a fallback
# directory, outside git. Runs in a temp git repo; no real checkout is read.
#
# Run: bash scripts/test/main-checkout/self-test.sh

set -uo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/lib/main-checkout.sh
. "${HERE}/../../lib/main-checkout.sh"

PASS=0; FAIL=0
ok()  { printf '  ok    %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  FAIL  %s\n        %s\n' "$1" "${2:-}"; FAIL=$((FAIL+1)); }
expect() { # <claim> <expected> <actual>
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$2] got [$3]"; fi
}

T="$(mktemp -d)"
trap 'rm -rf -- "$T"' EXIT
unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR

printf '\nmain_checkout — the main checkout, never a linked worktree\n'
GR="${T}/repo"; mkdir -p "${GR}/scripts"
git -C "$GR" init -q -b main >&2
git -C "$GR" -c user.email=t@example.invalid -c user.name=t -c commit.gpgsign=false commit -q --allow-empty -m seed >&2
GR="$(cd -- "$GR" && pwd -P)"
git -C "$GR" worktree add -q "${T}/wt" >&2
mkdir -p "${T}/wt/scripts"
main_checkout "${GR}/scripts" 2>"${T}/err"; rc=$?
expect "from the main checkout: the main checkout, not in a worktree" "0|${GR}|0" "${rc}|${MAIN_CHECKOUT}|${MAIN_CHECKOUT_IN_WORKTREE}"
main_checkout "${T}/wt/scripts" 2>"${T}/err"; rc=$?
expect "from a linked worktree: still the MAIN checkout, and in a worktree" "0|${GR}|1" "${rc}|${MAIN_CHECKOUT}|${MAIN_CHECKOUT_IN_WORKTREE}"

ln -s "${T}/wt" "${T}/wt-link"
main_checkout "${T}/wt-link/scripts" 2>"${T}/err"; rc=$?
expect "through a symlink to a worktree: the main checkout, symlinks resolved" "0|${GR}" "${rc}|${MAIN_CHECKOUT}"

printf '\nmain_checkout — a failed resolution is an error, never a directory\n'
mkdir -p "${T}/nogit"
MAIN_CHECKOUT=stale
GIT_CEILING_DIRECTORIES="${T}" main_checkout "${T}/nogit" who 2>"${T}/err"; rc=$?
if [ "$rc" = 2 ] && [ -z "${MAIN_CHECKOUT}" ] && grep -q '^who: .* not inside a git checkout' "${T}/err" && grep -q 'Fix:' "${T}/err"; then
  ok "outside any git checkout: exit 2, the caller's name, a Fix:, and no main checkout (never stale, never the dir itself)"
else
  bad "outside any git checkout: exit 2 with Fix: and no main checkout" "rc=$rc main=${MAIN_CHECKOUT} err=$(cat "${T}/err")"
fi
MAIN_CHECKOUT=stale
main_checkout "${T}/does-not-exist" 2>"${T}/err"; rc=$?
if [ "$rc" = 2 ] && [ -z "${MAIN_CHECKOUT}" ] && grep -q 'Fix:' "${T}/err"; then
  ok "a directory that does not exist: exit 2 with Fix:, and no main checkout"
else
  bad "a directory that does not exist: exit 2 with Fix:" "rc=$rc main=${MAIN_CHECKOUT} err=$(cat "${T}/err")"
fi

printf '\n'
TOTAL=$((PASS+FAIL))
if [ "$FAIL" -eq 0 ]; then
  printf 'VERDICT: PASS (%d cases)\n' "$TOTAL"
  exit 0
fi
printf 'VERDICT: FAIL (%d of %d cases)\n' "$FAIL" "$TOTAL"
printf '  Fix: read each FAIL above; repair scripts/lib/main-checkout.sh, then re-run\n'
printf '       bash scripts/test/main-checkout/self-test.sh.\n'
exit 1
