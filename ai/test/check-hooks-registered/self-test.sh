#!/usr/bin/env bash
# Black-box suite for ai/bin/check-hooks-registered's landed bar (DND-743, which
# folds in DND-478 finding 4) -- discovered and run by harness-gate.
#
# The defect this pins: the check read the BRANCH's ai/hooks/registry.json as
# the list of hooks the live settings must wire. So:
#   - a branch that ADDS a hook failed the gate until ~/.claude/settings.json
#     wired it. The only way to get green was `setup-hooks --install` from the
#     worktree, which wires the MAIN checkout's path, where the script does not
#     exist until the branch lands: exit 127 on every tool call (DND-670);
#   - a branch that REMOVES (or re-events) a landed hook lowered its own bar, so
#     drift on main passed. See ~/dev/custom/CLAUDE.md -> "A check's own bar
#     must not live in the diff it is checking".
# The fix reads the required set from what LANDED on origin (ai/lib/landed.rb),
# reports a branch-added hook as pending (non-failing), fails a wired hook whose
# script is missing (dangling), and reports an unreadable bar as could-not-measure.
#
# Every case builds a throwaway repo holding the checker under test (and
# ai/lib/landed.rb, scripts/setup-hooks), lands it on a local bare origin, and
# runs the checker from a LINKED WORKTREE on a feature branch -- the shape a
# captain runs the gate in. The checker resolves its repo from its own
# location, so it measures the fixture, never the live tree or live settings
# (HOOKS_SETTINGS_FILE always points into the fixture). Black-box, so it runs
# unchanged against the pre-fix checker; that is how the fail-first evidence
# was recorded:
#
#   CHECK_HOOKS_REGISTERED_UNDER_TEST=/path/to/old/ai/bin/check-hooks-registered \
#     ai/test/check-hooks-registered/self-test.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AI_DIR="$(cd "${HERE}/../.." && pwd)"
BIN="${CHECK_HOOKS_REGISTERED_UNDER_TEST:-${AI_DIR}/bin/check-hooks-registered}"
SRC_ROOT="$(cd "$(dirname "${BIN}")/../.." && pwd)"
LIB="${SRC_ROOT}/ai/lib/landed.rb"
SETUP="${SRC_ROOT}/scripts/setup-hooks"

for f in "${BIN}" "${LIB}" "${SETUP}"; do
  if [ ! -f "${f}" ]; then
    echo "check-hooks-registered self-test: FAIL -- ${f} does not exist" >&2
    echo "Fix: point CHECK_HOOKS_REGISTERED_UNDER_TEST at a checker inside a checkout that also has ai/lib/landed.rb and scripts/setup-hooks." >&2
    exit 1
  fi
done

TMP="$(mktemp -d)"; TMP="$(cd "${TMP}" && pwd -P)"
trap 'rm -rf "${TMP}"' EXIT
PASS=0; FAIL=0
ok()  { printf '  ok    %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  FAIL  %s\n        %s\n' "$1" "$2"; FAIL=$((FAIL+1)); }

export GIT_CONFIG_NOSYSTEM=1
export GIT_CONFIG_GLOBAL="${TMP}/gitconfig"
: > "${GIT_CONFIG_GLOBAL}"
export GIT_TERMINAL_PROMPT=0
GITC=(-c user.name=fixture -c user.email=fixture@example.invalid -c init.defaultBranch=main)

commit() { git -C "$1" add -A >/dev/null 2>&1; git -C "$1" "${GITC[@]}" commit -q --allow-empty -m "$2" >/dev/null 2>&1; }

hook() { # hook <root> <name>: an executable hook script
  mkdir -p "$1/ai/hooks"; printf '#!/bin/sh\nexit 0\n' > "$1/ai/hooks/$2"; chmod +x "$1/ai/hooks/$2"
}

registry() { # registry <root> <event=script-basename>...
  local root="$1"; shift; local sep="" kv
  mkdir -p "${root}/ai/hooks"
  {
    printf '{ "hooks": ['
    for kv in "$@"; do
      printf '%s\n  { "event": "%s", "matcher": "", "script": "ai/hooks/%s" }' "${sep}" "${kv%%=*}" "${kv#*=}"
      sep=","
    done
    printf '\n] }\n'
  } > "${root}/ai/hooks/registry.json"
}

wire() { # wire <settings-file> <event=absolute-command>...
  local file="$1"; shift
  ruby -rjson -e '
    hooks = {}
    ARGV.each do |kv|
      ev, cmd = kv.split("=", 2)
      (hooks[ev] ||= []) << { "matcher" => "", "hooks" => [{ "type" => "command", "command" => cmd }] }
    end
    puts JSON.generate({ "hooks" => hooks })
  ' "$@" > "${file}"
}

# new_fixture <name>: main checkout with hook a.sh landed on origin main, and a
# linked worktree on branch `feature`. Prints the fixture dir; main checkout is
# <dir>/main, worktree <dir>/wt, bare origin <dir>/origin.git.
new_fixture() {
  local d="${TMP}/$1"
  mkdir -p "${d}"
  git init -q --bare "${d}/origin.git"
  git "${GITC[@]}" init -q "${d}/main"
  mkdir -p "${d}/main/ai/bin" "${d}/main/ai/lib" "${d}/main/scripts"
  cp "${BIN}" "${d}/main/ai/bin/check-hooks-registered"
  cp "${LIB}" "${d}/main/ai/lib/landed.rb"
  cp "${SETUP}" "${d}/main/scripts/setup-hooks"
  hook "${d}/main" a.sh
  registry "${d}/main" "SessionStart=a.sh"
  commit "${d}/main" landed
  git -C "${d}/main" remote add origin "${d}/origin.git"
  git -C "${d}/main" push -q origin HEAD:refs/heads/main >/dev/null 2>&1
  git -C "${d}/main" fetch -q origin >/dev/null 2>&1
  git -C "${d}/main" worktree add -q -b feature "${d}/wt" >/dev/null 2>&1
  printf '%s\n' "${d}"
}

# land_branch <dir>: the owner lands the feature branch on main and fast-forwards
# the main checkout to it.
land_branch() {
  git -C "$1/wt" push -q origin HEAD:refs/heads/main >/dev/null 2>&1
  git -C "$1/main" "${GITC[@]}" merge -q --ff-only feature >/dev/null 2>&1
  git -C "$1/main" fetch -q origin >/dev/null 2>&1
}

OUT=""; RC=0
check() { # check <dir> [settings-file]: run the worktree's checker
  local settings="${2:-$1/settings.json}"
  OUT="$(HOOKS_SETTINGS_FILE="${settings}" "$1/wt/ai/bin/check-hooks-registered" 2>&1)"; RC=$?
}

expect() { # expect <label> <rc> [grep-pattern] [absent-pattern]
  local label="$1" want="$2" pat="${3:-}" absent="${4:-}"
  if [ "${RC}" -ne "${want}" ]; then bad "${label}" "exit ${RC}, want ${want}; output: ${OUT}"; return; fi
  if [ -n "${pat}" ] && ! grep -qiE -- "${pat}" <<<"${OUT}"; then bad "${label}" "output lacks /${pat}/: ${OUT}"; return; fi
  if [ -n "${absent}" ] && grep -qE -- "${absent}" <<<"${OUT}"; then bad "${label}" "output has /${absent}/: ${OUT}"; return; fi
  ok "${label}"
}

echo "check-hooks-registered landed-bar suite (checker: ${BIN})"

# 1. Baseline: the landed hook is wired, the branch changes nothing.
D="$(new_fixture baseline)"
wire "${D}/settings.json" "SessionStart=${D}/main/ai/hooks/a.sh"
check "${D}"; expect "landed hook wired, branch unchanged -> pass" 0

# 2. THE DEFECT: a branch-added hook needs no live wiring.
D="$(new_fixture branch-adds)"
hook "${D}/wt" b.sh; registry "${D}/wt" "SessionStart=a.sh" "SessionStart=b.sh"; commit "${D}/wt" add-b
wire "${D}/settings.json" "SessionStart=${D}/main/ai/hooks/a.sh"
check "${D}"; expect "branch-added hook unwired -> pass, named as pending" 0 "b\.sh"

# 3. Drift still fails, and the branch-added hook is not called drift.
wire "${D}/settings.json"
check "${D}"; expect "landed hook unwired on a hook-adding branch -> FAIL naming it" 1 "a\.sh" "- SessionStart -> ai/hooks/b\.sh"

# 4. After the branch lands, the (formerly branch-added) hook must be wired.
land_branch "${D}"
wire "${D}/settings.json" "SessionStart=${D}/main/ai/hooks/a.sh"
check "${D}"; expect "hook landed but unwired -> FAIL (drift as today)" 1 "b\.sh"

# 5. A branch that REMOVES a landed hook from its registry cannot lower the bar.
D="$(new_fixture branch-removes)"
registry "${D}/wt" ; commit "${D}/wt" remove-a
wire "${D}/settings.json"
check "${D}"; expect "landed hook removed on the branch, unwired -> still FAIL" 1 "a\.sh"
wire "${D}/settings.json" "SessionStart=${D}/main/ai/hooks/a.sh"
check "${D}"; expect "landed hook removed on the branch, still wired -> pass" 0

# 6. Re-evented on the branch: the landed (event, script) pair is still the bar.
D="$(new_fixture branch-re-events)"
registry "${D}/wt" "Stop=a.sh"; commit "${D}/wt" re-event
wire "${D}/settings.json" "Stop=${D}/main/ai/hooks/a.sh"
check "${D}"; expect "landed hook moved to another event on the branch -> landed event still required" 1 "SessionStart.*a\.sh"

# 7. Dangling: wiring a branch-added hook at the main checkout, where its script
#    does not exist yet, is the exit-127 state -- flagged, not passed.
D="$(new_fixture dangling)"
hook "${D}/wt" b.sh; registry "${D}/wt" "SessionStart=a.sh" "SessionStart=b.sh"; commit "${D}/wt" add-b
wire "${D}/settings.json" "SessionStart=${D}/main/ai/hooks/a.sh" "SessionStart=${D}/main/ai/hooks/b.sh"
check "${D}"; expect "wired hook whose script is absent from the main checkout -> FAIL (dangling)" 1 "b\.sh.*(does not exist|dangling)|(does not exist|dangling).*b\.sh"

# 8. Branch registry consistency: an entry whose script is missing or not
#    executable on the branch fails.
D="$(new_fixture branch-missing-script)"
registry "${D}/wt" "SessionStart=a.sh" "SessionStart=c.sh"; commit "${D}/wt" add-c-no-file
wire "${D}/settings.json" "SessionStart=${D}/main/ai/hooks/a.sh"
check "${D}"; expect "branch registry names a script that does not exist -> FAIL" 1 "c\.sh"
D="$(new_fixture branch-not-executable)"
hook "${D}/wt" c.sh; chmod -x "${D}/wt/ai/hooks/c.sh"
registry "${D}/wt" "SessionStart=a.sh" "SessionStart=c.sh"; commit "${D}/wt" add-c-noexec
wire "${D}/settings.json" "SessionStart=${D}/main/ai/hooks/a.sh"
check "${D}"; expect "branch registry names a non-executable script -> FAIL" 1 "c\.sh"

# 9. Could not measure is not a pass: origin unreachable.
D="$(new_fixture origin-unreachable)"
wire "${D}/settings.json" "SessionStart=${D}/main/ai/hooks/a.sh"
git -C "${D}/main" remote set-url origin "${D}/no-such-origin.git"
check "${D}"; expect "landed registry unreadable (origin unreachable) -> could not measure, exit 3" 3 "could not measure"

# 10. Could not measure: the landed registry is malformed on origin main.
D="$(new_fixture landed-malformed)"
printf '{ not json\n' > "${D}/main/ai/hooks/registry.json"; commit "${D}/main" break
git -C "${D}/main" push -q origin HEAD:refs/heads/main >/dev/null 2>&1; git -C "${D}/main" fetch -q origin >/dev/null 2>&1
git -C "${D}/wt" "${GITC[@]}" rebase -q origin/main >/dev/null 2>&1
registry "${D}/wt" "SessionStart=a.sh"; commit "${D}/wt" fix-on-branch
wire "${D}/settings.json" "SessionStart=${D}/main/ai/hooks/a.sh"
check "${D}"; expect "landed registry malformed -> could not measure, exit 3" 3 "could not measure"

# 11. Could not measure: the branch's own registry is malformed.
D="$(new_fixture branch-malformed)"
printf '{ "hooks": 7 }\n' > "${D}/wt/ai/hooks/registry.json"; commit "${D}/wt" break
wire "${D}/settings.json" "SessionStart=${D}/main/ai/hooks/a.sh"
check "${D}"; expect "branch registry malformed -> could not measure, exit 3" 3 "could not measure"

# 12. Not this environment: no settings file passes, and needs no network.
D="$(new_fixture no-settings)"
git -C "${D}/main" remote set-url origin "${D}/no-such-origin.git"
check "${D}" "${D}/absent.json"; expect "no settings file -> pass without reading origin" 0 "nothing to assert"

# 13. setup-hooks --install from a worktree does not wire a hook whose script is
#     not on the main checkout yet (the root cause of the dangling wiring).
D="$(new_fixture setup-hooks-install)"
hook "${D}/wt" b.sh; registry "${D}/wt" "SessionStart=a.sh" "SessionStart=b.sh"; commit "${D}/wt" add-b
printf '{}\n' > "${D}/settings.json"
OUT="$(HOOKS_SETTINGS_FILE="${D}/settings.json" "${D}/wt/scripts/setup-hooks" --install 2>&1)"; RC=$?
if [ "${RC}" -ne 0 ]; then
  bad "setup-hooks --install from a worktree" "exit ${RC}: ${OUT}"
elif grep -q "b\.sh" "${D}/settings.json"; then
  bad "setup-hooks --install skips a hook not on the main checkout" "settings now wires b.sh: $(cat "${D}/settings.json")"
elif ! grep -q "${D}/main/ai/hooks/a\.sh" "${D}/settings.json"; then
  bad "setup-hooks --install still wires the landed hook" "settings: $(cat "${D}/settings.json")"
elif ! grep -q "b\.sh" <<<"${OUT}"; then
  bad "setup-hooks --install names the hook it skipped" "output: ${OUT}"
else
  ok "setup-hooks --install from a worktree wires a.sh, skips and names b.sh (not on main yet)"
fi

echo "check-hooks-registered landed-bar suite: ${PASS} passed, ${FAIL} failed"
if [ "${FAIL}" -eq 0 ]; then echo "ALL CASES PASS"; exit 0; fi
echo "SELF-TEST FAILED"; exit 1
