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

for f in "${BIN}" "${LIB}" "${SRC_ROOT}/ai/lib/strict_argv.rb" "${SRC_ROOT}/ai/lib/agent_stash_env.rb" "${SETUP}"; do
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
  /usr/bin/ruby -rjson -e '
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
  mkdir -p "${d}/main/ai/bin" "${d}/main/ai/lib" "${d}/main/scripts/lib"
  cp "${SRC_ROOT}/scripts/lib/main-checkout.sh" "${d}/main/scripts/lib/main-checkout.sh"
  cp "${BIN}" "${d}/main/ai/bin/check-hooks-registered"
  cp "${LIB}" "${d}/main/ai/lib/landed.rb"
  cp "${SRC_ROOT}/ai/lib/strict_argv.rb" "${d}/main/ai/lib/strict_argv.rb"
  cp "${SRC_ROOT}/ai/lib/agent_stash_env.rb" "${d}/main/ai/lib/agent_stash_env.rb"
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
expect "...and the output says an offline machine exits 3" 3 "offline machine.*could not measure"
# 9b. A real failure the check CAN see outranks the bar it cannot read: a wired
#     hook that cannot run is broken whatever landed, so it is exit 1, not 3.
D="$(new_fixture unreachable-and-dangling)"
wire "${D}/settings.json" "SessionStart=${D}/main/ai/hooks/a.sh" "SessionStart=${D}/main/ai/hooks/gone.sh"
git -C "${D}/main" remote set-url origin "${D}/no-such-origin.git"
check "${D}"; expect "origin unreachable, but a wired hook is dangling -> FAIL, exit 1" 1 "gone\.sh"
expect "...and it still says the landed bar was not measured" 1 "could not measure"

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

# 14. The gate's pin (DND-735): origin main moves after the pin is taken. The
#     pinned run measures the pin; the unpinned run sees a stale local ref.
D="$(new_fixture pinned)"
wire "${D}/settings.json" "SessionStart=${D}/main/ai/hooks/a.sh"
PIN="$(git -C "${D}/main" rev-parse HEAD)"
KEY="$(cd "$(git -C "${D}/main" rev-parse --path-format=absolute --git-common-dir)" && pwd -P)"
git clone -q -b main "${D}/origin.git" "${D}/other" >/dev/null 2>&1
commit "${D}/other" moved; git -C "${D}/other" push -q origin HEAD:refs/heads/main >/dev/null 2>&1
OUT="$(ATHENA_LANDED_PIN_SHA="${PIN}" ATHENA_LANDED_PIN_REPO="${KEY}" HOOKS_SETTINGS_FILE="${D}/settings.json" \
  "${D}/wt/ai/bin/check-hooks-registered" 2>&1)"; RC=$?
expect "origin moved after the gate pinned it -> pass against the pin" 0 "pinned at harness-gate start"
OUT="$(env -u ATHENA_LANDED_PIN_SHA -u ATHENA_LANDED_PIN_REPO HOOKS_SETTINGS_FILE="${D}/settings.json" \
  "${D}/wt/ai/bin/check-hooks-registered" 2>&1)"; RC=$?
expect "...and unpinned, the stale local origin/main -> could not measure, exit 3" 3 "disagrees with origin"

# 14b. RETIRED HOOKS (DND-1517). The registry's `retired` list names a wiring
#      (event, matcher, script) that must leave the machine. Before the fix the
#      checker ignored it: a retired hook still wired passed, and nothing said
#      `setup-hooks --install` would unwire it. The retirement that counts is the
#      LANDED one, like every other bar here (DND-743): a branch that adds one
#      is pending, and a branch that drops a landed one cannot lower the bar.
retire() { # retire <root> <event=script-basename>...: add a `retired` list to the registry
  local root="$1"; shift
  REG="${root}/ai/hooks/registry.json" /usr/bin/ruby -rjson -e '
    reg = JSON.parse(File.read(ENV["REG"]))
    reg["retired"] = ARGV.map { |kv| ev, s = kv.split("=", 2); { "event" => ev, "matcher" => "", "script" => "ai/hooks/#{s}" } }
    File.write(ENV["REG"], JSON.pretty_generate(reg) + "\n")' "$@"
}
D="$(new_fixture r1517-a)"
hook "${D}/main" r.sh; retire "${D}/main" "PostToolUse=r.sh"; commit "${D}/main" retire-r
git -C "${D}/main" push -q origin HEAD:refs/heads/main >/dev/null 2>&1; git -C "${D}/main" fetch -q origin >/dev/null 2>&1
git -C "${D}/wt" "${GITC[@]}" rebase -q origin/main >/dev/null 2>&1
wire "${D}/settings.json" "SessionStart=${D}/main/ai/hooks/a.sh" "PostToolUse=${D}/main/ai/hooks/r.sh"
check "${D}"; expect "landed retired hook still wired -> FAIL naming it and the installer" 1 \
  "PostToolUse.*r\.sh.*retired, still wired"
expect "...and its Fix: is setup-hooks --install from the main checkout" 1 "Fix: run .scripts/setup-hooks --install. from the MAIN checkout"
wire "${D}/settings.json" "SessionStart=${D}/main/ai/hooks/a.sh"
check "${D}"; expect "landed retired hook unwired -> pass" 0 "" "retired, still wired"
# A branch that drops the landed retirement cannot make a still-wired hook pass.
registry "${D}/wt" "SessionStart=a.sh"; commit "${D}/wt" drop-retirement
wire "${D}/settings.json" "SessionStart=${D}/main/ai/hooks/a.sh" "PostToolUse=${D}/main/ai/hooks/r.sh"
check "${D}"; expect "branch drops a landed retirement, hook still wired -> still FAIL" 1 "r\.sh.*retired, still wired"

D="$(new_fixture r1517-b)"
hook "${D}/main" r.sh; registry "${D}/main" "SessionStart=a.sh" "PostToolUse=r.sh"; commit "${D}/main" add-r
git -C "${D}/main" push -q origin HEAD:refs/heads/main >/dev/null 2>&1; git -C "${D}/main" fetch -q origin >/dev/null 2>&1
git -C "${D}/wt" "${GITC[@]}" rebase -q origin/main >/dev/null 2>&1
registry "${D}/wt" "SessionStart=a.sh"; retire "${D}/wt" "PostToolUse=r.sh"; commit "${D}/wt" retire-r
wire "${D}/settings.json" "SessionStart=${D}/main/ai/hooks/a.sh" "PostToolUse=${D}/main/ai/hooks/r.sh"
check "${D}"; expect "a retirement only this branch adds, still wired -> pass, named as pending" 0 \
  "r\.sh.*pending retirement" "retired, still wired"

D="$(new_fixture r1517-d)"
REG="${D}/main/ai/hooks/registry.json" /usr/bin/ruby -rjson -e '
  reg = JSON.parse(File.read(ENV["REG"])); reg["retired"] = {}
  File.write(ENV["REG"], JSON.generate(reg))'
commit "${D}/main" bad-retired
git -C "${D}/main" push -q origin HEAD:refs/heads/main >/dev/null 2>&1; git -C "${D}/main" fetch -q origin >/dev/null 2>&1
git -C "${D}/wt" "${GITC[@]}" rebase -q origin/main >/dev/null 2>&1
registry "${D}/wt" "SessionStart=a.sh"; commit "${D}/wt" fix-on-branch
wire "${D}/settings.json" "SessionStart=${D}/main/ai/hooks/a.sh"
check "${D}"; expect "landed retired list malformed -> could not measure, exit 3 (never read as none retired)" 3 \
  "could not measure"

D="$(new_fixture r1517-c)"
retire "${D}/wt" "SessionStart=a.sh"; commit "${D}/wt" both
wire "${D}/settings.json" "SessionStart=${D}/main/ai/hooks/a.sh"
check "${D}"; expect "branch registry both declares and retires one row -> FAIL naming it" 1 "a\.sh.*(both|declared and retired)"

# 15. THE AGENT-STASH ENV AND A SESSION STARTED BEFORE ITS INSTALL (DND-1036).
#     Claude Code hot-reloads the settings env into a running session, so after
#     `setup-hooks --install-env` an old session carries ATHENA_AGENT_BIN while
#     its Bash tool still sources the shell snapshot built at session start,
#     whose PATH has no wrapper. The pre-fix checker FAILED every such session,
#     so installing the env redded every harness-gate on the machine until a
#     fleet-wide restart (measured 2026-09-28 07:19Z-07:25Z). The fix reads the
#     install time the installer records in the settings env and the build
#     time of the snapshot this process's shell sourced (named in an ancestor's
#     argv), and reports PENDING RESTART only when the snapshot predates the
#     install. The fixture parent below carries a snapshot path in its argv the
#     way the Bash tool's `zsh -c "source <snapshot> ..."` does; the nearest
#     such ancestor wins, so the live session running this suite is never read.
env_fixture() { # env_fixture <name>: new_fixture plus the env landed on origin
  local d; d="$(new_fixture "$1")"
  mkdir -p "${d}/main/ai/git-hooks" "${d}/main/ai/agent-bin" "${d}/main/ai/agent-env" "${d}/home"
  cp "${SRC_ROOT}/ai/git-hooks/agent-stash-guard.sh" "${d}/main/ai/git-hooks/agent-stash-guard.sh"
  cp "${SRC_ROOT}/ai/agent-bin/git" "${d}/main/ai/agent-bin/git"
  chmod +x "${d}/main/ai/git-hooks/agent-stash-guard.sh" "${d}/main/ai/agent-bin/git"
  REG_SRC="${SRC_ROOT}/ai/hooks/registry.json" REG_DST="${d}/main/ai/hooks/registry.json" /usr/bin/ruby -rjson -e '
    src = JSON.parse(File.read(ENV["REG_SRC"]))
    dst = JSON.parse(File.read(ENV["REG_DST"]))
    File.write(ENV["REG_DST"], JSON.pretty_generate(dst.merge("env" => src.fetch("env"))) + "\n")'
  commit "${d}/main" land-env
  git -C "${d}/main" push -q origin HEAD:refs/heads/main >/dev/null 2>&1
  git -C "${d}/main" fetch -q origin >/dev/null 2>&1
  git -C "${d}/wt" "${GITC[@]}" rebase -q origin/main >/dev/null 2>&1
  # The CLAUDE_ENV_FILE script the settings env names (DND-1080), verbatim.
  cp "${SRC_ROOT}/ai/agent-env/session-env.sh" "${d}/main/ai/agent-env/session-env.sh"
  printf '%s\n' "${d}"
}

# env_settings <dir> <installed-at|-> [drop-key]: the settings file the
# installer writes -- the landed hook wired, the env expanded against the MAIN
# checkout, and the install stamp (omitted for "-"; drop-key removes one key).
env_settings() {
  D_MAIN="$1/main" STAMP="$2" DROP="${3:-}" OUTF="$1/settings.json" /usr/bin/ruby -rjson -e '
    main = ENV["D_MAIN"]
    spec = JSON.parse(File.read(File.join(main, "ai/hooks/registry.json"))).fetch("env")
    ex = ->(v) { v.gsub("{{MAIN}}", main) }
    env = { "GIT_CONFIG_COUNT" => spec["git_config"].size.to_s }
    spec["git_config"].each_with_index do |e, i|
      env["GIT_CONFIG_KEY_#{i}"] = e["key"]; env["GIT_CONFIG_VALUE_#{i}"] = ex.call(e["value"])
    end
    spec["vars"].each { |k, v| env[k] = ex.call(v) }
    env["ATHENA_AGENT_ENV_INSTALLED_AT"] = ENV["STAMP"] unless ENV["STAMP"] == "-"
    env.delete(ENV["DROP"]) unless ENV["DROP"].to_s.empty?
    hooks = { "SessionStart" => [{ "matcher" => "", "hooks" => [{ "type" => "command",
              "command" => File.join(main, "ai/hooks/a.sh") }] }] }
    File.write(ENV["OUTF"], JSON.generate({ "hooks" => hooks, "env" => env }))'
}

# session_check <dir> <snapshot-epoch-ms> <path-mode>: run the worktree's
# checker as an activated agent session would -- ATHENA_AGENT_BIN set by the
# settings env, under a parent shell whose argv names the snapshot it sourced.
# path-mode "stale" is a PATH with no wrapper (the snapshot predates the env);
# "wrapper" puts the wrapper first by hand; "fresh" builds the PATH the way a
# session started after the install does (DND-1080): the stale PATH the
# snapshot restores, then the script the settings env's CLAUDE_ENV_FILE names,
# which Claude Code runs after the snapshot and before the command.
session_check() {
  local d="$1" ms="$2" mode="$3" path="/usr/bin:/bin" envfile=""
  [ "${mode}" = "wrapper" ] && path="${d}/main/ai/agent-bin:${path}"
  [ "${mode}" = "fresh" ] && envfile="$(/usr/bin/ruby -rjson -e \
    'print JSON.parse(File.read(ARGV[0])).fetch("env", {}).fetch("CLAUDE_ENV_FILE", "")' "${d}/settings.json")"
  local snap="${d}/home/.claude/shell-snapshots/snapshot-zsh-${ms}-fx0001.sh"
  # Keep the trailing `exit $?`: without it bash execs the checker in place of
  # itself, the fixture parent vanishes from the ancestry, and the walk reads
  # the LIVE session's snapshot instead of this one.
  OUT="$(env HOME="${d}/home" HOOKS_SETTINGS_FILE="${d}/settings.json" \
      ATHENA_AGENT_BIN="${d}/main/ai/agent-bin" PATH="${path}" \
      bash -c "source ${snap} 2>/dev/null || true; if [ -n \"\$1\" ]; then . \"\$1\"; fi; \"\$0\"; exit \$?" \
      "${d}/wt/ai/bin/check-hooks-registered" "${envfile}" 2>&1)"; RC=$?
}

# Times: the snapshot 2026-09-26T19:31:09Z (ms), the install 2026-09-28T07:19:25Z.
SNAP_OLD=1790451069047
INSTALL_AFTER="2026-09-28T07:19:25Z"
INSTALL_BEFORE="2026-09-25T00:00:00Z"

D="$(env_fixture env-pending)"
env_settings "${D}" "${INSTALL_AFTER}"
session_check "${D}" "${SNAP_OLD}" stale
expect "env installed after this session's snapshot, PATH lacks the wrapper -> PENDING RESTART, exit 0" 0 \
  "agent-stash env: PENDING RESTART" "agent-stash env: (FAIL|DRIFT|ACTIVE)"
expect "...and it names the snapshot and the install time" 0 "snapshot-zsh-${SNAP_OLD}-fx0001\.sh.*2026-09-28T07:19:25Z|2026-09-28T07:19:25Z.*snapshot-zsh-${SNAP_OLD}"
session_check "${D}" "${SNAP_OLD}" wrapper
expect "same install, wrapper first on PATH -> ACTIVE" 0 "agent-stash env: ACTIVE" "PENDING"

# A FRESH session, started after the install, gets the wrapper first on PATH
# from the installed env alone (DND-1080). Before the fix nothing in the
# settings env put it there: the ~/.zshrc line ran while the snapshot was
# built, and the snapshot's closing `export PATH=` discarded it.
SNAP_NEW=1790582400000 # 2026-09-28T08:00:00Z, after INSTALL_AFTER
D="$(env_fixture env-fresh-session)"
env_settings "${D}" "${INSTALL_AFTER}"
session_check "${D}" "${SNAP_NEW}" fresh
expect "fresh session after the install: CLAUDE_ENV_FILE puts the wrapper first -> ACTIVE, exit 0" 0 \
  "agent-stash env: ACTIVE" "agent-stash env: (FAIL|DRIFT|PENDING)"
env_settings "${D}" "${INSTALL_AFTER}" CLAUDE_ENV_FILE
session_check "${D}" "${SNAP_NEW}" fresh
expect "fresh session, settings env without CLAUDE_ENV_FILE -> DRIFT naming it, exit 1" 1 \
  "CLAUDE_ENV_FILE is missing" "agent-stash env: (ACTIVE|PENDING)"

D="$(env_fixture env-newer-session)"
env_settings "${D}" "${INSTALL_BEFORE}"
session_check "${D}" "${SNAP_OLD}" stale
expect "session snapshot built AFTER the install, still no wrapper -> FAIL, exit 1" 1 \
  "agent-stash env: FAIL.*" "PENDING RESTART"
expect "...naming the first git on PATH" 1 "first git on PATH"

D="$(env_fixture env-partial)"
env_settings "${D}" "${INSTALL_AFTER}" ATHENA_AGENT_BIN
session_check "${D}" "${SNAP_OLD}" stale
expect "partial env (ATHENA_AGENT_BIN missing from settings), old session -> DRIFT, exit 1" 1 \
  "agent-stash env: DRIFT" "PENDING RESTART"
env_settings "${D}" "${INSTALL_AFTER}" GIT_CONFIG_KEY_3
session_check "${D}" "${SNAP_OLD}" stale
expect "partial env (a GIT_CONFIG key missing), old session -> DRIFT, exit 1" 1 \
  "agent-stash env: DRIFT" "PENDING RESTART"

D="$(env_fixture env-no-stamp)"
env_settings "${D}" -
session_check "${D}" "${SNAP_OLD}" stale
expect "install time absent from the settings env -> COULD NOT MEASURE, exit 3, never pending" 3 \
  "agent-stash env: COULD NOT MEASURE" "PENDING RESTART"
env_settings "${D}" "yesterday"
session_check "${D}" "${SNAP_OLD}" stale
expect "install time unreadable -> COULD NOT MEASURE, exit 3, never pending" 3 \
  "agent-stash env: COULD NOT MEASURE.*|could not be read" "PENDING RESTART"
env_settings "${D}" "2999-01-01T00:00:00Z"
session_check "${D}" "${SNAP_OLD}" stale
expect "install time in the future -> COULD NOT MEASURE, exit 3 (it would make every session pending)" 3 \
  "agent-stash env: COULD NOT MEASURE" "PENDING RESTART"

# 16. AHEAD OF THE PINNED BAR (DND-1552). The gate pins origin's main at its
#     start; then a newer commit lands (it retires a.sh and adds b.sh) and the
#     owner runs `setup-hooks --install` from the MAIN checkout. The live wiring
#     now equals what the NEWER origin/main declares, and the pinned bar read
#     the unwired a.sh as drift: every concurrent gate went red. Live wiring
#     that passes the newer origin/main's bar in full passes, named as "ahead
#     of the pinned bar". Anything else still fails.
# ahead_fixture <name>: pin origin main (PIN, KEY), land the newer registry on
# main, and install it into D/settings.json from the main checkout.
ahead_fixture() {
  D="$(new_fixture "$1")"
  wire "${D}/settings.json" "SessionStart=${D}/main/ai/hooks/a.sh"
  PIN="$(git -C "${D}/main" rev-parse HEAD)"
  KEY="$(cd "$(git -C "${D}/main" rev-parse --path-format=absolute --git-common-dir)" && pwd -P)"
  hook "${D}/main" b.sh; registry "${D}/main" "SessionStart=b.sh"; retire "${D}/main" "SessionStart=a.sh"
  commit "${D}/main" newer
  git -C "${D}/main" push -q origin HEAD:refs/heads/main >/dev/null 2>&1
  git -C "${D}/main" fetch -q origin >/dev/null 2>&1
  ( cd "${D}/main" && HOOKS_SETTINGS_FILE="${D}/settings.json" scripts/setup-hooks --install >/dev/null 2>&1 )
}
pinned_check() { # run the worktree's checker under the gate's pin
  OUT="$(ATHENA_LANDED_PIN_SHA="${PIN}" ATHENA_LANDED_PIN_REPO="${KEY}" HOOKS_SETTINGS_FILE="${D}/settings.json" \
    "${D}/wt/ai/bin/check-hooks-registered" 2>&1)"; RC=$?
}

ahead_fixture ahead
if grep -q "a\.sh" "${D}/settings.json" || ! grep -q "${D}/main/ai/hooks/b\.sh" "${D}/settings.json"; then
  bad "16 fixture: the main-checkout install unwired a.sh and wired b.sh" "settings: $(cat "${D}/settings.json")"
fi
pinned_check; expect "live wiring equals a NEWER origin/main -> pass, named ahead of the pinned bar" 0 \
  "a\.sh.*ahead of the pinned bar"

# The miss: neither the pinned row (a.sh) nor the newer one (b.sh) is wired.
ahead_fixture ahead-miss
printf '{"hooks": {}}\n' > "${D}/settings.json"
pinned_check; expect "live wiring matches neither the pinned nor the newer bar -> still FAIL" 1 "a\.sh" \
  ": ahead of the pinned bar"

# The miss, again: the newer row is wired under a matcher neither bar declares.
ahead_fixture ahead-matcher
/usr/bin/ruby -rjson -e '
  s = { "hooks" => { "SessionStart" => [{ "matcher" => "Bash", "hooks" => [{ "type" => "command", "command" => ARGV[0] }] }] } }
  File.write(ARGV[1], JSON.generate(s))' "${D}/main/ai/hooks/b.sh" "${D}/settings.json"
pinned_check; expect "newer row wired under the wrong matcher -> still FAIL" 1 "a\.sh" ": ahead of the pinned bar"

# The miss, a third way: every newer row is wired, plus a stale extra matcher.
ahead_fixture ahead-stale
/usr/bin/ruby -rjson -e '
  g = ->(m) { { "matcher" => m, "hooks" => [{ "type" => "command", "command" => ARGV[0] }] } }
  File.write(ARGV[1], JSON.generate({ "hooks" => { "SessionStart" => [g.call(""), g.call("Bash")] } }))' \
  "${D}/main/ai/hooks/b.sh" "${D}/settings.json"
pinned_check; expect "newer rows wired plus a stale matcher -> still FAIL" 1 "a\.sh" ": ahead of the pinned bar"

# Only the pin is superseded. A branch cut BEFORE the pin keeps its merge-base
# in the bar: a row the merge-base requires and the newer main retired still
# fails, and says rebase, exactly as it does with no newer main.
D="$(new_fixture ahead-old-base)"
hook "${D}/main" b.sh; registry "${D}/main" "SessionStart=a.sh" "SessionStart=b.sh"; commit "${D}/main" pin
git -C "${D}/main" push -q origin HEAD:refs/heads/main >/dev/null 2>&1; git -C "${D}/main" fetch -q origin >/dev/null 2>&1
PIN="$(git -C "${D}/main" rev-parse HEAD)"
KEY="$(cd "$(git -C "${D}/main" rev-parse --path-format=absolute --git-common-dir)" && pwd -P)"
registry "${D}/main" "SessionStart=b.sh"; retire "${D}/main" "SessionStart=a.sh"; commit "${D}/main" newer
git -C "${D}/main" push -q origin HEAD:refs/heads/main >/dev/null 2>&1; git -C "${D}/main" fetch -q origin >/dev/null 2>&1
printf '{}\n' > "${D}/settings.json"
( cd "${D}/main" && HOOKS_SETTINGS_FILE="${D}/settings.json" scripts/setup-hooks --install >/dev/null 2>&1 )
pinned_check; expect "branch cut before the pin, merge-base row the newer main retired -> still FAIL" 1 "a\.sh" \
  ": ahead of the pinned bar"

# A newer origin/main with no registry cannot say what the wiring should be:
# could not judge, never an empty bar that excuses everything.
D="$(new_fixture ahead-no-registry)"
PIN="$(git -C "${D}/main" rev-parse HEAD)"
KEY="$(cd "$(git -C "${D}/main" rev-parse --path-format=absolute --git-common-dir)" && pwd -P)"
git -C "${D}/main" rm -q ai/hooks/registry.json >/dev/null 2>&1; commit "${D}/main" drop-registry
git -C "${D}/main" push -q origin HEAD:refs/heads/main >/dev/null 2>&1; git -C "${D}/main" fetch -q origin >/dev/null 2>&1
printf '{"hooks": {}}\n' > "${D}/settings.json"
pinned_check; expect "newer origin/main has no registry -> pinned drift stands, says it could not judge" 1 \
  "could not read a newer origin/main" ": ahead of the pinned bar"

# 17. THE AGENT-STASH ENV, AHEAD OF THE PINNED BAR (DND-1570). Same shape as
#     16: the gate pinned origin's main, a newer commit changed the registry's
#     env (CLAUDE_ENV_FILE names a new script), and the owner's `--install-env` from the main checkout
#     wrote the NEWER env into the settings. Live env == the newer main's env:
#     named ahead, exit 0. Live env == neither: DRIFT, exit 1. A newer main
#     whose env cannot be read is "could not judge", never an empty bar.
env_ahead_fixture() { # env_ahead_fixture <name>: pin, then land a newer env
  D="$(env_fixture "$1")"
  PIN="$(git -C "${D}/main" rev-parse HEAD)"
  KEY="$(cd "$(git -C "${D}/main" rev-parse --path-format=absolute --git-common-dir)" && pwd -P)"
  REG="${D}/main/ai/hooks/registry.json" /usr/bin/ruby -rjson -e '
    r = JSON.parse(File.read(ENV["REG"])); r["env"]["vars"]["CLAUDE_ENV_FILE"] = "{{MAIN}}/ai/agent-env/session-env2.sh"
    File.write(ENV["REG"], JSON.pretty_generate(r) + "\n")'
  cp "${D}/main/ai/agent-env/session-env.sh" "${D}/main/ai/agent-env/session-env2.sh"
  commit "${D}/main" newer-env
  git -C "${D}/main" push -q origin HEAD:refs/heads/main >/dev/null 2>&1
  git -C "${D}/main" fetch -q origin >/dev/null 2>&1
}
pinned_session() { # session_check under the gate's pin
  export ATHENA_LANDED_PIN_SHA="${PIN}" ATHENA_LANDED_PIN_REPO="${KEY}"
  session_check "$@"
  unset ATHENA_LANDED_PIN_SHA ATHENA_LANDED_PIN_REPO
}

env_ahead_fixture env-ahead
env_settings "${D}" "${INSTALL_AFTER}"   # expanded from main's working tree: the NEWER env
pinned_session "${D}" "${SNAP_OLD}" wrapper
expect "live env equals a NEWER origin/main's env -> ACTIVE, named ahead of the pinned bar, exit 0" 0 \
  "agent-stash env: ACTIVE.*ahead of the pinned bar|ahead of the pinned bar.*agent-stash env: ACTIVE" "agent-stash env: DRIFT"

env_ahead_fixture env-ahead-miss
env_settings "${D}" "${INSTALL_AFTER}" ATHENA_AGENT_BIN
pinned_session "${D}" "${SNAP_OLD}" stale
expect "live env matches neither the pinned nor the newer env -> still DRIFT" 1 "agent-stash env: DRIFT" \
  "agent-stash env: ahead of the pinned bar"

env_ahead_fixture env-ahead-no-registry
env_settings "${D}" "${INSTALL_AFTER}"
git -C "${D}/main" rm -q ai/hooks/registry.json >/dev/null 2>&1; commit "${D}/main" drop-registry
git -C "${D}/main" push -q origin HEAD:refs/heads/main >/dev/null 2>&1; git -C "${D}/main" fetch -q origin >/dev/null 2>&1
pinned_session "${D}" "${SNAP_OLD}" wrapper
expect "newer origin/main has no registry -> pinned DRIFT stands, says it could not judge" 1 \
  "could not read a newer origin/main" "agent-stash env: ahead of the pinned bar"

# The pin predates the env altogether: the env lands after the gate pinned, and
# the owner installs it. Pinned bar has no env; live env equals the newer main's.
D="$(env_fixture env-ahead-landed-later)"
PIN="$(git -C "${D}/main" rev-parse HEAD~1)"
KEY="$(cd "$(git -C "${D}/main" rev-parse --path-format=absolute --git-common-dir)" && pwd -P)"
env_settings "${D}" "${INSTALL_AFTER}"
pinned_session "${D}" "${SNAP_OLD}" wrapper
expect "pin predates the env, live env equals the newer origin/main's -> named ahead, exit 0" 0 \
  "agent-stash env: ahead of the pinned bar" "agent-stash env: FAIL"
env_settings "${D}" "${INSTALL_AFTER}" ATHENA_AGENT_BIN
pinned_session "${D}" "${SNAP_OLD}" stale
expect "pin predates the env, live env equals neither -> still FAIL" 1 "agent-stash env: FAIL" \
  "agent-stash env: ahead of the pinned bar"

# Unpinned, there is no newer origin/main to be ahead of.
D="$(new_fixture unpinned-unwired)"
printf '{"hooks": {}}\n' > "${D}/settings.json"
check "${D}"; expect "unpinned, the landed row unwired -> FAIL" 1 "a\.sh" ": ahead of the pinned bar"

echo "check-hooks-registered landed-bar suite: ${PASS} passed, ${FAIL} failed"
if [ "${FAIL}" -eq 0 ]; then echo "ALL CASES PASS"; exit 0; fi
echo "SELF-TEST FAILED"; exit 1
