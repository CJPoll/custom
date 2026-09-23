#!/usr/bin/env bash
# Regression test for DND-398.
#
# scripts/wt-lib/pr.sh and scripts/wt-lib/merge.sh call `error "..."` on every
# failure path, but no `error` function was defined anywhere under scripts/.
# On a real failure bash reports `error: command not found`, exits 127, and
# the intended message is lost — the owner drives `wt` interactively and
# never sees why it failed.
#
# Hermetic: no network, no real git remote side effects. Each case sources
# the wt-lib modules in a subshell with WORKTREES_DIR/PROJECT_DIR pointed at
# a throwaway temp tree and PATH stripped of `gt`, then drives a real
# wt-lib failure path and asserts:
#   - the intended message reached stderr
#   - the exit code is non-zero
#   - the exit code is NOT 127 (the "function doesn't exist" signature)
#
# Exit 0 iff every case passes.
set -uo pipefail

here="$(cd -- "$(dirname -- "$0")" && pwd -P)"
scripts_dir="$(cd -- "${here}/../.." && pwd -P)"
lib="${scripts_dir}/wt-lib"

fails=0
passes=0
pass() { echo "PASS $1"; passes=$((passes+1)); }
fail() { echo "FAIL $1"; fails=$((fails+1)); }

tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT

export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1

# A minimal real git repo to act as PROJECT_DIR, so worktree.sh's git calls
# have something real (but harmless) to talk to.
project="${tmp}/project"
mkdir -p "${project}"
git -C "${project}" init -q -b main
git -C "${project}" -c user.email=t@example.com -c user.name=t commit -q --allow-empty -m init

worktrees_dir="${tmp}/worktrees"
mkdir -p "${worktrees_dir}"

# A PATH with no `gt` on it, so `command -v gt` fails without a real
# Graphite install and without touching the owner's.
no_gt_path="${tmp}/no-gt-bin"
mkdir -p "${no_gt_path}"
# Keep the rest of the real PATH so `git`, `bash`, coreutils still resolve.
export NO_GT_PATH="${no_gt_path}:${PATH}"
# Strip any real `gt` off that PATH by prepending shadowing empty dir first
# (already done: no_gt_path has nothing named gt, and we do not add gt to it).

run_case() {
    # run_case <fn-invocation...> -- runs in a subshell, sourcing the lib.
    (
        set -uo pipefail
        PROJECT_DIR="${project}"
        WORKTREES_DIR="${worktrees_dir}"
        PROJECT_NAME="project"
        QUIET=false
        CURRENT_DIR="${project}"
        export PROJECT_DIR WORKTREES_DIR PROJECT_NAME QUIET CURRENT_DIR
        # shellcheck disable=SC1091
        source "${lib}/common.sh"
        source "${lib}/worktree.sh"
        source "${lib}/stack.sh"
        source "${lib}/stack-advanced.sh"
        source "${lib}/push.sh"
        source "${lib}/pr.sh"
        source "${lib}/merge.sh"
        cd "${project}" || exit 99
        "$@"
    )
}

# --- 1. the `error` function itself exists and behaves -----------------------
out="$(run_case error "boom" 2>"${tmp}/stderr")"; rc=$?
err="$(cat "${tmp}/stderr")"
if [ "$rc" -ne 0 ] && [ "$rc" -ne 127 ] && [[ "$err" == *"boom"* ]]; then
  pass "error() prints its message and exits non-zero, non-127"
else
  fail "error() direct call: rc=$rc err=[$err]"
fi

# --- 2. create_pr's missing-gt path (pr.sh) -----------------------------------
out="$(PATH="${no_gt_path}" run_case create_pr false 2>"${tmp}/stderr")"; rc=$?
err="$(cat "${tmp}/stderr")"
if [ "$rc" -ne 0 ] && [ "$rc" -ne 127 ] && [[ "$err" == *"Graphite"* ]]; then
  pass "create_pr: missing gt fails loudly (not exit 127 with the message lost)"
else
  fail "create_pr missing-gt: rc=$rc err=[$err]"
fi

# --- 3. push_stack's missing-gt path (pr.sh) ----------------------------------
out="$(PATH="${no_gt_path}" run_case push_stack false 2>"${tmp}/stderr")"; rc=$?
err="$(cat "${tmp}/stderr")"
if [ "$rc" -ne 0 ] && [ "$rc" -ne 127 ] && [[ "$err" == *"Graphite"* ]]; then
  pass "push_stack: missing gt fails loudly"
else
  fail "push_stack missing-gt: rc=$rc err=[$err]"
fi

# --- 4. push_branch's no-worktree path (pr.sh) --------------------------------
out="$(run_case push_branch does-not-exist-branch false 2>"${tmp}/stderr")"; rc=$?
err="$(cat "${tmp}/stderr")"
if [ "$rc" -ne 0 ] && [ "$rc" -ne 127 ] && [[ "$err" == *"No worktree found"* ]]; then
  pass "push_branch: no worktree fails loudly with the branch named"
else
  fail "push_branch no-worktree: rc=$rc err=[$err]"
fi

# --- 5. merge_worktree's no-such-branch path (merge.sh) -----------------------
out="$(run_case merge_worktree does-not-exist-branch main 2>"${tmp}/stderr")"; rc=$?
err="$(cat "${tmp}/stderr")"
if [ "$rc" -ne 0 ] && [ "$rc" -ne 127 ] && [[ "$err" == *"does not exist locally"* ]]; then
  pass "merge_worktree: nonexistent branch fails loudly"
else
  fail "merge_worktree no-such-branch: rc=$rc err=[$err]"
fi

# --- 6. merge_worktree's no-worktree-for-target path (merge.sh) ---------------
git -C "${project}" branch feature-x >/dev/null 2>&1
out="$(run_case merge_worktree feature-x no-such-target 2>"${tmp}/stderr")"; rc=$?
err="$(cat "${tmp}/stderr")"
if [ "$rc" -ne 0 ] && [ "$rc" -ne 127 ] && [[ "$err" == *"No worktree found for branch"* ]]; then
  pass "merge_worktree: missing target worktree fails loudly"
else
  fail "merge_worktree no-target-worktree: rc=$rc err=[$err]"
fi

# --- 7. no other wt-lib/wt-subcommand call site invokes an undefined helper --
# The class this bug belongs to: a bare-word call that resolves to nothing.
# Grep every call-shaped use of the common helper names and confirm each one
# names a function this sweep found defined somewhere under scripts/.
defined="$(grep -hoE '^\s*(function\s+)?[a-zA-Z_][a-zA-Z0-9_]*\s*\(\)' \
  "${lib}"/*.sh "${scripts_dir}/wt" "${scripts_dir}"/wt-subcommands/* 2>/dev/null \
  | sed -E 's/^\s*(function\s+)?//; s/\s*\(\)$//' | sort -u)"
undefined=""
for name in error warn info success die fatal abort fail; do
  grep -qx "$name" <<<"$defined" && continue
  hits="$(grep -nE "^[[:space:]]*${name}[[:space:]]+[\"(]" \
    "${lib}"/*.sh "${scripts_dir}/wt" "${scripts_dir}"/wt-subcommands/* 2>/dev/null \
    | grep -vE ':[0-9]+:[[:space:]]*#' \
    || true)"
  [ -n "$hits" ] && undefined="${undefined}${name}:${hits}\n"
done
if [ -z "$undefined" ]; then
  pass "no other undefined helper (warn/info/success/die/fatal/abort/fail) is called"
else
  fail "undefined helper(s) still called: $(printf '%b' "$undefined")"
fi

echo "wt-error-helper: ${passes} passed, ${fails} failed"
[ "${fails}" -eq 0 ]
