#!/bin/sh
# Self-test for merge-role-guard.sh (DND-726).
#
# Pipes crafted PreToolUse stdin JSON into the hook and asserts deny/allow per
# role. The payload shapes are the ones measured on Claude Code 2.1.286
# (DND-726 step 0): a subagent's PreToolUse(Bash) carries agent_id and
# agent_type; a top-level session carries neither; a top-level
# `claude -p --agent X` carries agent_type X and no agent_id.
#
# Functional only (DND-1222): one pass, no load, no timing. Hermetic: HOME and
# XDG_STATE_HOME point into one trap-removed temp dir. Every git repo is a
# fixture under that dir with a local bare remote; nothing is pushed or merged,
# because the hook only reads command TEXT and git state.
#
# The hook under test is a COPY committed into a fixture "home" repo, so the
# shipwright-lane carve-out (a lane under the hook's own repo's git common dir)
# is exercised for real, without a test seam in the hook.
# MRG_SRC=<dir> copies the hook from another ai/ tree (used for the sabotage
# records); MRG_HOOK=<path> runs every case against another hook instead (used
# to record the regression evidence).
#
# Exit 0 iff every case passes.

SRC_AI="${MRG_SRC:-$(cd -- "$(dirname -- "$(realpath -- "$0")")/.." && pwd -P)}"
for f in hooks/merge-role-guard.sh lib/merge_role.rb lib/merge_role_io.rb; do
  [ -f "${SRC_AI}/${f}" ] || { echo "FAIL: ${SRC_AI}/${f} is missing. Fix: restore it from git, or point MRG_SRC at an ai/ tree that has it."; exit 1; }
done
command -v jq >/dev/null 2>&1 || { echo "FAIL: jq is not on PATH. Fix: install jq; the cases are built with it."; exit 1; }
command -v git >/dev/null 2>&1 || { echo "FAIL: git is not on PATH. Fix: install git; the fixtures are git repos."; exit 1; }

TMP=$(mktemp -d) || { echo "FAIL: mktemp -d failed. Fix: check /tmp is writable."; exit 1; }
TMP=$(cd -- "${TMP}" && pwd -P)
trap 'rm -rf "${TMP}"' EXIT INT TERM
# Resolve the real ruby BEFORE HOME moves: a version-manager shim (asdf) needs
# the real HOME, and the hook would otherwise fail open on every case.
RUBY_BIN=$(ruby -e 'print RbConfig.ruby' 2>/dev/null)
[ -x "${RUBY_BIN}" ] || { echo "FAIL: no runnable ruby on PATH. Fix: install ruby; the hook's checker is ruby."; exit 1; }
mkdir -p "${TMP}/rubybin" && ln -sf "${RUBY_BIN}" "${TMP}/rubybin/ruby"
PATH="${TMP}/rubybin:${PATH}"
REAL_PATH="${PATH}"
export HOME="${TMP}/home" XDG_STATE_HOME="${TMP}/state"
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL="${TMP}/gitconfig"
# The agent-stash env (DND-775) must not reach fixture git calls.
unset GIT_CONFIG_COUNT GIT_CONFIG_PARAMETERS GIT_DIR GIT_WORK_TREE
mkdir -p "${HOME}" "${XDG_STATE_HOME}"
git config --file "${GIT_CONFIG_GLOBAL}" user.email t@example.invalid
git config --file "${GIT_CONFIG_GLOBAL}" user.name test
git config --file "${GIT_CONFIG_GLOBAL}" init.defaultBranch main

q() { "$@" >/dev/null 2>&1 || { echo "FAIL: fixture step failed: $*. Fix: read the command; the fixture could not be built."; exit 1; }; }

# repo <dir> <branch> : a repo with one commit on <branch> and a bare origin
# whose HEAD names <branch>.
repo() {
  q git init -q -b "$2" "$1"
  q git -C "$1" commit -q --allow-empty -m init
  q git init -q --bare -b "$2" "$1.origin.git"
  q git -C "$1" remote add origin "$1.origin.git"
  q git -C "$1" push -q origin "$2"
  q git -C "$1" fetch -q origin
  q git -C "$1" remote set-head origin "$2"
}

# The fixture home repo carries the hook, as ~/dev/custom does.
HOMEREPO="${TMP}/custom"
repo "${HOMEREPO}" main
mkdir -p "${HOMEREPO}/ai/hooks" "${HOMEREPO}/ai/lib"
cp "${SRC_AI}/hooks/merge-role-guard.sh" "${HOMEREPO}/ai/hooks/"
cp "${SRC_AI}/lib/merge_role.rb" "${SRC_AI}/lib/merge_role_io.rb" "${HOMEREPO}/ai/lib/"
chmod +x "${HOMEREPO}/ai/hooks/merge-role-guard.sh"
q git -C "${HOMEREPO}" add -A
q git -C "${HOMEREPO}" commit -q -m hook
HOOK="${MRG_HOOK:-${HOMEREPO}/ai/hooks/merge-role-guard.sh}"

FEAT="${TMP}/wt/feat"                                  # a captain's worktree
q git -C "${HOMEREPO}" worktree add -q -b feat "${FEAT}"
LANE="${HOMEREPO}/.git/shipwright-lanes/run-x"         # the shipwright cron lane
q git -C "${HOMEREPO}" worktree add -q -b shipwright/run-x "${LANE}"
LTLANE="${HOMEREPO}/.git/leadtime-lanes/run-y"         # the lead-time cron lane
q git -C "${HOMEREPO}" worktree add -q -b leadtime/run-y "${LTLANE}"
HANDWT="${HOME}/.local/worktrees/custom/sw-hand"       # a hand-spawned shipwright
q git -C "${HOMEREPO}" worktree add -q -b sw-hand "${HANDWT}"
TRUNK="${TMP}/trunkrepo"                               # default branch is not main
repo "${TRUNK}" trunk
PROD="${TMP}/prod"                                     # a product repo's lead-time lane
repo "${PROD}" main
PRODLANE="${PROD}/.git/leadtime-lanes/run-z"
q git -C "${PROD}" worktree add -q -b leadtime/prod-run-z "${PRODLANE}"
# Repos whose CONFIG sends a no-refspec push to main from a feature branch.
CFGREPO="${TMP}/cfgrepo"                               # remote.origin.push
repo "${CFGREPO}" main
q git -C "${CFGREPO}" checkout -q -b feat
q git -C "${CFGREPO}" config remote.origin.push HEAD:refs/heads/main
UPREPO="${TMP}/uprepo"                                 # push.default=upstream, tracking main
repo "${UPREPO}" main
q git -C "${UPREPO}" checkout -q -b feat --track origin/main
q git -C "${UPREPO}" config push.default upstream
MATCHREPO="${TMP}/matchrepo"                           # push.default=matching
repo "${MATCHREPO}" main
q git -C "${MATCHREPO}" checkout -q -b feat
q git -C "${MATCHREPO}" config push.default matching
mkdir -p "${TMP}/x/wt"                                 # a plain dir named wt
NOHEAD="${TMP}/nohead"                                 # no refs/remotes/origin/HEAD
repo "${NOHEAD}" main
q git -C "${NOHEAD}" remote set-head origin -d
q git -C "${NOHEAD}" checkout -q -b feat

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); printf '  PASS  %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL  %s -- %s\n' "$1" "$2"; }

# payload <role> <command> <cwd> <tool> : the measured PreToolUse shapes.
payload() {
  case "$1" in
    top)       _r='{}' ;;
    captain)   _r='{"agent_id":"a1111111111111111","agent_type":"athena-captain"}' ;;
    admiral)   _r='{"agent_id":"a2222222222222222","agent_type":"athena-admiral"}' ;;
    gp)        _r='{"agent_id":"a3333333333333333","agent_type":"general-purpose"}' ;;
    shipwright) _r='{"agent_id":"a4444444444444444","agent_type":"athena-shipwright"}' ;;
    architect) _r='{"agent_id":"a5555555555555555","agent_type":"athena-architect"}' ;;
    notype)    _r='{"agent_id":"a6666666666666666","agent_type":""}' ;;
    nokey)     _r='{"agent_id":"a7777777777777777"}' ;;
    agent-captain) _r='{"agent_type":"athena-captain"}' ;;
    agent-admiral) _r='{"agent_type":"athena-admiral"}' ;;
    *) echo "FAIL: unknown role $1 in the self-test. Fix: use a role payload() defines."; exit 1 ;;
  esac
  # For the Agent/Task tool, <command> is the spawn's subagent_type.
  jq -cn --argjson r "${_r}" --arg c "$2" --arg d "$3" --arg t "$4" \
    '{session_id:"s1",transcript_path:"/nonexistent/s1.jsonl",cwd:$d,permission_mode:"bypassPermissions",hook_event_name:"PreToolUse",tool_name:$t,tool_input:(if $t == "Agent" or $t == "Task" then {description:"d",prompt:"p",subagent_type:$c} else {command:$c} end),tool_use_id:"toolu_x"} + $r'
}

# run <role> <command> [cwd] [tool] -> OUT, RC
run() {
  OUT=$(payload "$1" "$2" "${3:-${HOMEREPO}}" "${4:-Bash}" | "${HOOK}" 2>/dev/null)
  RC=$?
}
decision() {
  if [ -z "${OUT}" ]; then printf 'allow'; return; fi
  printf '%s' "${OUT}" | jq -r '.hookSpecificOutput.permissionDecision // "allow"' 2>/dev/null || printf 'unparseable'
}
reason() { printf '%s' "${OUT}" | jq -r '.hookSpecificOutput.permissionDecisionReason // ""' 2>/dev/null; }

# expect <label> <role> <deny|allow> <command> [cwd] [tool] [reason-substring]
expect() {
  run "$2" "$4" "$5" "$6"
  _got=$(decision)
  if [ "${RC}" -ne 0 ]; then bad "$1 [$2]" "hook exited ${RC}: ${OUT}"; return; fi
  if [ "${_got}" != "$3" ]; then bad "$1 [$2]" "expected $3, got ${_got}: ${OUT}"; return; fi
  if [ "$3" = "deny" ] && ! reason | grep -q 'Fix:'; then bad "$1 [$2]" "deny carries no Fix: ${OUT}"; return; fi
  if [ "$3" = "allow" ] && [ -n "${OUT}" ]; then bad "$1 [$2]" "allowed, but not silently: ${OUT}"; return; fi
  if [ -n "${7:-}" ] && ! reason | grep -q -F -- "$7"; then bad "$1 [$2]" "reason lacks '$7': $(reason)"; return; fi
  ok "$1 [$2]"
}

# merge_class <label> <command> [cwd] [tool] : the four-role matrix every
# merge-class command must satisfy (acceptance 3).
merge_class() {
  expect "$1" captain deny "$2" "$3" "$4"
  expect "$1" gp deny "$2" "$3" "$4"
  expect "$1" admiral allow "$2" "$3" "$4"
  expect "$1" top allow "$2" "$3" "$4"
}

# not_merge <label> <command> [cwd] : a captain command that must pass silently.
not_merge() { expect "$1" captain allow "$2" "$3"; }

GHA="${HOME}/dev/custom/ai/bin/gh-athena"
GLA="${HOME}/dev/custom/ai/bin/glab-athena"

echo "== the DND-321 regression: a captain's wrapper merge =="
expect "DND-321: gh-athena pr merge 275 --squash --auto" captain deny "${GHA} pr merge 275 --squash --auto" "${FEAT}" "" "athena-captain"

echo "== rule 1: CLI merge =="
merge_class "gh-athena pr merge, flags after" "${GHA} pr merge 275 --squash --auto"
merge_class "flags before the number" "gh-athena pr merge --admin --squash 12"
merge_class "\$VAR command word" "G=${GHA}; \"\$G\" pr merge 5 --squash --match-head-commit abc"
merge_class "sh -c wrapping" "sh -c 'cd /x && gh-athena pr merge 3 --squash'"
merge_class "newline-joined" "echo hi
gh-athena pr merge 4 --squash"
merge_class "semicolon-joined glab-athena mr merge" "true; ${GLA} mr merge 7 --sha abc --yes"
merge_class "glab mr merge --auto-merge" "glab-athena mr merge 7 --auto-merge"
merge_class "glab mr merge --when-pipeline-succeeds" "glab-athena mr merge 7 --when-pipeline-succeeds"
merge_class "glab mr accept" "glab-athena mr accept 7 --sha abc"
merge_class "global flag between gh and pr" "gh -R o/r pr merge 9 --disable-auto"
merge_class "locked-merge (the scripted gh-athena pr merge)" "${HOME}/dev/custom/ai/skills/athena:merge-boarding/scripts/locked-merge --pr 5 --head abc"

echo "== rule 2: API merge endpoints =="
merge_class "REST pulls/<n>/merge" "gh-athena api -X PUT repos/o/r/pulls/5/merge"
merge_class "curl REST pulls/<n>/merge" "curl -X PUT https://api.github.com/repos/o/r/pulls/5/merge"
merge_class "GraphQL mergePullRequest" "gh-athena api graphql -f query='mutation { mergePullRequest(input: {pullRequestId: \"x\"}) { clientMutationId } }'"
merge_class "GraphQL enablePullRequestAutoMerge" "gh api graphql -f query='mutation { enablePullRequestAutoMerge(input: {}) { clientMutationId } }'"
merge_class "GraphQL enqueuePullRequest" "gh-athena api graphql -f query='mutation{enqueuePullRequest(input:{}){clientMutationId}}'"
merge_class "GraphQL mergeBranch" "gh-athena api graphql -f query='mutation{mergeBranch(input:{}){clientMutationId}}'"
merge_class "REST repos/<o>/<r>/merges" "gh-athena api repos/o/r/merges -f base=main -f head=x"
merge_class "GitLab merge_requests/<n>/merge" "glab-athena api -X PUT projects/1/merge_requests/7/merge"
merge_class "GitLab merge_when_pipeline_succeeds" "glab-athena api -X POST projects/1/merge_requests/7/merge_when_pipeline_succeeds"
merge_class "GitLab merge train POST" "glab-athena api -X POST \"projects/:id/merge_trains/merge_requests/7\" -f sha=abc"

echo "== rule 3: push to a protected branch =="
merge_class "gh-athena git push origin HEAD:main" "cd ${FEAT} && ${GHA} git -c credential.helper= push origin HEAD:main"
merge_class "HEAD:refs/heads/main" "git -C ${FEAT} push origin HEAD:refs/heads/main"
merge_class "+x:main" "git -C ${FEAT} push origin +feat:main"
merge_class ":main (delete main)" "git -C ${FEAT} push origin :main"
merge_class "origin main" "cd ${FEAT} && git push origin main"
merge_class "--all" "git -C ${FEAT} push --all origin"
merge_class "--mirror" "git -C ${FEAT} push --mirror origin"
merge_class "no refspec, on main" "cd ${HOMEREPO} && git push"
merge_class "HEAD resolves to main" "git -C ${HOMEREPO} push origin HEAD"
merge_class "the repo's default branch (trunk)" "cd ${TRUNK} && git push origin trunk"
merge_class "no refspec, on the default branch (trunk)" "git -C ${TRUNK} push"
merge_class "no refspec, stdin cwd on main" "git push" "${HOMEREPO}"
merge_class "glab-athena git push" "cd ${FEAT} && ${GLA} git push origin HEAD:main"
expect "no refspec, unresolvable branch, names it" captain deny "cd \"\$WT\" && git push" "${HOMEREPO}" "" "could not tell"
expect "no refspec, unresolvable branch" gp deny "cd \"\$WT\" && git push"
expect "no refspec, unresolvable branch" admiral allow "cd \"\$WT\" && git push"
expect "no refspec, unresolvable branch" top allow "cd \"\$WT\" && git push"
expect "no refspec, not a git repo, names it" captain deny "git -C ${TMP}/nowhere push" "${HOMEREPO}" "" "could not tell"

echo "== rule 4: land locally on a protected branch =="
merge_class "merge --ff-only of the main checkout" "git -C ${HOMEREPO} merge --ff-only origin/main"
merge_class "reset --hard on main" "cd ${HOMEREPO} && git reset --hard origin/main"
merge_class "cherry-pick on main" "cd ${HOMEREPO} && git cherry-pick abc"
merge_class "rebase on main" "cd ${HOMEREPO} && git rebase origin/main"
merge_class "pull from a non-origin remote on main" "cd ${HOMEREPO} && git pull upstream main"
merge_class "pull . <branch> on main" "cd ${HOMEREPO} && git pull . feat"
merge_class "pull origin <other branch> on main" "cd ${HOMEREPO} && git pull origin feat"
merge_class "update-ref refs/heads/main" "git -C ${FEAT} update-ref refs/heads/main abc"
merge_class "branch -f main" "git -C ${FEAT} branch -f main abc"
merge_class "branch -M x main" "git -C ${FEAT} branch -M feat main"
merge_class "branch --force main" "git -C ${FEAT} branch --force main abc"
merge_class "checkout -B main" "git -C ${FEAT} checkout -B main abc"
merge_class "switch -C main" "git -C ${FEAT} switch -C main abc"
merge_class "merge on the default branch (trunk)" "git -C ${TRUNK} merge feat"
expect "local landing, unresolvable branch, names it" captain deny "cd \"\$WT\" && git merge origin/main" "${HOMEREPO}" "" "could not tell"
# --git-dir / --work-tree / GIT_DIR / GIT_WORK_TREE move the repo away from the
# cd/-C directory; reading the cd directory's branch would be a wrong key.
expect "--git-dir= overrides the cd dir" captain deny "cd ${FEAT} && git --git-dir=${HOMEREPO}/.git merge feat" "${HOMEREPO}" "" "could not tell"
expect "--git-dir <dir> after -C" captain deny "git -C ${FEAT} --git-dir ${HOMEREPO}/.git reset --hard x" "${HOMEREPO}" "" "could not tell"
expect "--work-tree overrides the cd dir" captain deny "cd ${FEAT} && git --work-tree=${HOMEREPO} rebase origin/main"
expect "GIT_DIR= prefix" captain deny "cd ${FEAT} && GIT_DIR=${HOMEREPO}/.git git push" "${HOMEREPO}" "" "could not tell"
expect "env GIT_WORK_TREE= prefix" captain deny "cd ${FEAT} && env GIT_WORK_TREE=${HOMEREPO} git merge feat"
# With the repo unresolved, its default branch is unknown, so even a named
# feature destination may be it (critic round: a `trunk` default slipped).
expect "GIT_DIR= with a named destination: default branch unknown" captain deny "cd ${FEAT} && GIT_DIR=${HOMEREPO}/.git git push origin feat" "${HOMEREPO}" "" "could not tell"
expect "unresolved dir, push to a non-main default (trunk)" captain deny "git -C \"\$WT\" push origin HEAD:trunk" "${HOMEREPO}" "" "could not tell"
expect "unresolved dir, update-ref a non-main default (trunk)" captain deny "git -C \"\$X\" update-ref refs/heads/trunk abc"
expect "unresolved dir, push to a non-main default (trunk)" admiral allow "git -C \"\$WT\" push origin HEAD:trunk"
expect "no origin/HEAD: a named push cannot rule out the default" captain deny "git -C ${NOHEAD} push origin feat" "${HOMEREPO}" "" "set-head"
expect "no origin/HEAD: a no-refspec push from a non-main branch" captain deny "git -C ${NOHEAD} push"
expect "no origin/HEAD: a merge on a non-main branch" captain deny "git -C ${NOHEAD} merge x"
expect "no origin/HEAD: a push to main is still a landing" captain deny "git -C ${NOHEAD} push origin main"
expect "no origin/HEAD: a push" admiral allow "git -C ${NOHEAD} push origin feat"
# A subshell's cd ends with the subshell.
expect "subshell cd does not leak out" captain deny "(cd ${FEAT} && git status); git push" "${HOMEREPO}"
expect "subshell cd applies inside" captain allow "(cd ${FEAT} && git push)" "${HOMEREPO}"

echo "== rule 5: wt merge / gt merge =="
merge_class "wt merge" "wt merge feature/x"
merge_class "gt merge" "gt merge"

echo "== rule 6: MCP merge tools =="
merge_class "mcp merge tool" "" "${HOMEREPO}" "mcp__forge__merge_pull_request"
merge_class "mcp enqueue tool" "" "${HOMEREPO}" "mcp__forge__EnqueuePullRequest"
expect "mcp tool that does not merge" captain allow "" "${HOMEREPO}" "mcp__notion__search"
merge_class "mcp tool named in upper case" "" "${HOMEREPO}" "mcp__forge__MERGE_PR"

echo "== the admiral's documented merge paths, verbatim from the skills (acceptance 4) =="
merge_class "merge-boarding: locked-merge" "~/dev/custom/ai/skills/athena:merge-boarding/scripts/locked-merge --pr 12 --head 0123abc"
merge_class "github: squash --auto" "~/dev/custom/ai/bin/gh-athena pr merge 12 --squash --auto"
merge_class "github: pinned squash" "~/dev/custom/ai/bin/gh-athena pr merge 12 --squash --match-head-commit 0123abc"
merge_class "gitlab: merge-train POST" "~/dev/custom/ai/bin/glab-athena api -X POST \"projects/:id/merge_trains/merge_requests/7\" -f sha=0123abc"
merge_class "gitlab: mr merge --sha --yes" "~/dev/custom/ai/bin/glab-athena mr merge 7 --sha 0123abc --yes"
merge_class "merge-boarding: custom fast-forward push" "cd ${FEAT} && GIT_TERMINAL_PROMPT=0 ~/dev/custom/ai/bin/gh-athena git push origin 0123abc:main"
merge_class "merge-boarding: fast-forward the main checkout" "git -C ${HOMEREPO} merge --ff-only origin/main"
merge_class "captain template: wt merge" "wt merge dnd-1-branch"

echo "== review round: quoting and escapes the shell removes =="
expect "quoted-out destination" captain deny "git -C ${FEAT} push origin HEAD:ma''in"
expect "quoted-out push" captain deny "git -C ${FEAT} pu''sh origin HEAD:main"
expect "escaped push" captain deny "git -C ${FEAT} pu\\sh origin HEAD:main"
expect "quoted-out merge" captain deny "gh pr me''rge 5"
expect "escaped merge" captain deny "gh pr mer\\ge 5"
expect "quoted-out API route" captain deny "gh-athena api -X PUT repos/o/r/pulls/5/me\"\"rge"

echo "== review round: push destinations =="
expect "heads/main" captain deny "git -C ${FEAT} push origin HEAD:heads/main"
expect "destination in a variable" captain deny "B=main; git -C ${FEAT} push origin HEAD:\$B" "${HOMEREPO}" "" "could not tell"
expect "destination in a substitution" captain deny "git -C ${FEAT} push origin HEAD:\$(echo main)"
expect "destination by brace expansion" captain deny "git -C ${FEAT} push origin HEAD:{main,}"
expect "redirection glued to the destination" captain deny "git -C ${FEAT} push origin HEAD:main>/dev/null"
expect "-c remote.origin.push" captain deny "git -c remote.origin.push=HEAD:refs/heads/main -C ${FEAT} push origin"
expect "GIT_CONFIG_* env" captain deny "GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=remote.origin.push GIT_CONFIG_VALUE_0=HEAD:refs/heads/main git -C ${FEAT} push origin"
expect "-c push.default" captain deny "git -c push.default=upstream -C ${FEAT} push"
expect "refspec fed by xargs" captain deny "echo HEAD:main | xargs git -C ${FEAT} push origin"
expect "configured remote.origin.push" captain deny "git -C ${CFGREPO} push" "${HOMEREPO}" "" "main"
expect "configured remote.origin.push, explicit feature refspec" captain allow "git -C ${CFGREPO} push origin feat"
expect "push.default=upstream tracking main" captain deny "git -C ${UPREPO} push"
expect "push.default=matching" captain deny "git -C ${MATCHREPO} push"
expect "send-pack to main" captain deny "git -C ${FEAT} send-pack ${HOMEREPO}.origin.git HEAD:refs/heads/main"
expect "send-pack to a feature branch" captain allow "git -C ${FEAT} send-pack ${HOMEREPO}.origin.git HEAD:refs/heads/feat"
expect "subtree push to main" captain deny "git -C ${FEAT} subtree push --prefix ai origin main"

echo "== review round: cd that does not reach the next command =="
expect "cd in a substitution" captain deny "x=\$(cd ${FEAT}); git push origin"
expect "cd in backticks" captain deny "x=\`cd ${FEAT}\`; git push origin"
expect "cd after ||" captain deny "true || cd ${FEAT}; git push origin"
expect "cd in a pipeline stage" captain deny "cd ${FEAT} | true; git push origin"
expect "pushd then popd" captain deny "pushd ${FEAT}; popd; git push origin"
expect "cd then && still applies" captain allow "cd ${FEAT} && git push origin"

echo "== review round: ref writes outside push =="
expect "update-ref HEAD on main" captain deny "git -C ${HOMEREPO} update-ref HEAD abc"
expect "update-ref --stdin" captain deny "printf x | git -C ${FEAT} update-ref --stdin"
expect "update-ref HEAD on a feature branch" captain allow "git -C ${FEAT} update-ref HEAD abc"
expect "fetch into main" captain deny "git -C ${FEAT} fetch . feat:main"
expect "fetch +x:refs/heads/main" captain deny "git -C ${FEAT} fetch origin +feat:refs/heads/main"
expect "fetch into a remote-tracking ref" captain allow "git -C ${FEAT} fetch origin main:refs/remotes/origin/main"
expect "fetch a branch" captain allow "git -C ${FEAT} fetch origin main"
expect "REST git/refs PATCH" captain deny "gh-athena api -X PATCH repos/o/r/git/refs/heads/main -f sha=abc"
expect "REST git/refs create" captain deny "gh-athena api repos/o/r/git/refs -f ref=refs/heads/main -f sha=abc"
expect "REST contents PUT" captain deny "gh-athena api -X PUT repos/o/r/contents/README.md -f message=x -f content=eA=="
expect "GraphQL createCommitOnBranch" captain deny "gh-athena api graphql -f query='mutation{createCommitOnBranch(input:{}){commit{oid}}}'"
expect "GraphQL updateRef" captain deny "gh-athena api graphql -f query='mutation{updateRef(input:{}){clientMutationId}}'"
expect "GraphQL updateRefs" captain deny "gh-athena api graphql -f query='mutation{updateRefs(input:{}){clientMutationId}}'"
expect "GitLab repository/commits POST" captain deny "glab-athena api -X POST projects/1/repository/commits -f branch=main"
expect "GitLab repository/files PUT" captain deny "glab-athena api --method PUT projects/1/repository/files/x -f branch=main"
expect "REST git/refs read" captain allow "gh api repos/o/r/git/refs/heads/main"
expect "REST contents read" captain allow "gh api repos/o/r/contents/README.md"
expect "GitLab file read" captain allow "glab api projects/1/repository/files/x/raw"
expect "GitLab commits read" captain allow "glab api projects/1/repository/commits"

echo "== review round: spawning an admiral (rule 7) =="
expect "spawn athena-admiral" captain deny "athena-admiral" "${HOMEREPO}" "Agent" "athena-admiral"
expect "spawn athena-admiral" gp deny "athena-admiral" "${HOMEREPO}" "Agent"
expect "spawn athena-admiral (Task)" captain deny "athena-admiral" "${HOMEREPO}" "Task"
expect "spawn athena-admiral" top allow "athena-admiral" "${HOMEREPO}" "Agent"
expect "spawn athena-admiral" admiral allow "athena-admiral" "${HOMEREPO}" "Agent"
expect "spawn athena-admiral" agent-captain deny "athena-admiral" "${HOMEREPO}" "Agent"
expect "spawn general-purpose" captain allow "general-purpose" "${HOMEREPO}" "Agent"
expect "spawn athena-captain" admiral allow "athena-captain" "${HOMEREPO}" "Agent"

echo "== review round: narrower matches =="
expect "a dir named wt before merge-base" captain allow "git -C ${TMP}/x/wt merge-base HEAD origin/main"
expect "a dir named wt before mergetool" captain allow "git -C ${TMP}/x/wt mergetool"
merge_class "wt merge behind timeout" "timeout 60 wt merge feature/x"
expect "branch -f <new> <start main>" captain allow "git -C ${FEAT} branch -f feat2 main"
expect "pull -X theirs origin main on main is a sync" captain allow "cd ${HOMEREPO} && git pull -X theirs origin main"
expect "rebase <upstream> main rebases main" captain deny "git -C ${FEAT} rebase feat main"
expect "the deny log masks a token" captain deny "curl -H \"Authorization: token ghp_SECRETSECRET\" -X PUT https://api.github.com/repos/o/r/pulls/5/merge"
if grep -q -F 'ghp_SECRETSECRET' "${XDG_STATE_HOME}/athena/merge-role-guard.log" 2>/dev/null; then
  bad "the deny log never records the token" "found in ${XDG_STATE_HOME}/athena/merge-role-guard.log"
else
  ok "the deny log never records the token"
fi

echo "== captain negatives: never matched =="
not_merge "gh-athena pr create" "${GHA} pr create --fill --base main"
not_merge "glab-athena mr create" "${GLA} mr create --fill --target-branch main"
not_merge "pr view --json mergeable,mergeStateStatus,mergedAt" "gh pr view 5 --json mergeable,mergeStateStatus,mergedAt"
not_merge "pr checks" "gh pr checks 5"
not_merge "mr view" "glab mr view 5"
not_merge "push --force-with-lease to a feature branch" "cd ${FEAT} && ${GHA} git push --force-with-lease origin feat"
not_merge "push -u to a feature branch" "git -C ${FEAT} push -u origin feat"
not_merge "push feat:feat" "git -C ${FEAT} push origin feat:feat"
not_merge "push HEAD from a feature branch" "git -C ${FEAT} push origin HEAD"
not_merge "push with no refspec on a feature branch" "cd ${FEAT} && git push"
not_merge "push --delete a feature branch" "git -C ${FEAT} push origin --delete feat"
not_merge "merge origin/main on a feature branch" "cd ${FEAT} && git merge origin/main"
not_merge "rebase origin/main on a feature branch" "cd ${FEAT} && git rebase origin/main"
not_merge "pr edit --base" "${GHA} pr edit 5 --base main"
not_merge "pr comment" "${GHA} pr comment 5 --body-file x.md"
not_merge "pr review" "${GHA} pr review 5 --comment --body-file x.md"
not_merge "confirm-merged" "${HOME}/dev/custom/ai/bin/confirm-merged --pr 5"
not_merge "critic-review" "${HOME}/dev/custom/ai/bin/critic-review"
not_merge "integration-gate --with-critic --rebase" "cd ${FEAT} && ${HOME}/dev/custom/ai/bin/test-slot -- timeout 1500 ${HOME}/dev/custom/ai/bin/integration-gate --with-critic --rebase"
not_merge "merge-base on main" "git -C ${HOMEREPO} merge-base origin/main HEAD"
not_merge "log --merges on main" "git -C ${HOMEREPO} log --merges -3"
not_merge "branch --show-current on main" "git -C ${HOMEREPO} branch --show-current"
not_merge "commit message that says push origin main" "git -C ${FEAT} commit -m \"push origin main later\""
not_merge "pull from origin on main" "cd ${HOMEREPO} && git pull --ff-only"
not_merge "pull origin main on main" "cd ${HOMEREPO} && git pull origin main"
not_merge "fetch" "git -C ${HOMEREPO} fetch origin main"

echo "== the shipwright lane carve-out =="
SWPUSH="GIT_TERMINAL_PROMPT=0 ${GHA} git -c credential.helper= -c url.https://github.com/.insteadOf=git@github.com: push origin HEAD:main"
expect "cron lane push HEAD:main" shipwright allow "cd ${LANE} && ${SWPUSH}"
expect "lead-time lane push HEAD:main" shipwright allow "cd ${LTLANE} && ${SWPUSH}"
expect "hand-spawned worktree push HEAD:main" shipwright deny "cd ${HANDWT} && ${SWPUSH}" "${HOMEREPO}" "" "athena-shipwright"
expect "product repo's lead-time lane push HEAD:main" shipwright deny "cd ${PRODLANE} && ${SWPUSH}"
expect "lane, but a pr merge" shipwright deny "cd ${LANE} && ${GHA} pr merge 5 --squash"
expect "lane, but a local merge on main" shipwright deny "git -C ${HOMEREPO} merge --ff-only origin/main"
expect "lane push by a captain" captain deny "cd ${LANE} && ${SWPUSH}"
expect "lane push, top level" top allow "cd ${LANE} && ${SWPUSH}"
expect "architect merge" architect deny "${GHA} pr merge 5 --squash"

echo "== role resolution =="
expect "agent_id with an empty agent_type, names it" notype deny "${GHA} pr merge 5 --squash" "${HOMEREPO}" "" "could not tell the caller's role"
expect "agent_id with no agent_type key" nokey deny "${GHA} pr merge 5 --squash"
expect "agent_id with an empty agent_type, no merge" notype allow "git status"
expect "top-level --agent athena-captain" agent-captain deny "${GHA} pr merge 5 --squash"
expect "top-level --agent athena-admiral" agent-admiral allow "${GHA} pr merge 5 --squash"
# A top-level session's Bash keeps an earlier call's cd, so its payload cwd
# (the session root) says nothing about where a bare command runs.
expect "top-level --agent captain, bare push: cwd is not trusted" agent-captain deny "git push" "${FEAT}" "" "could not tell"
expect "top-level --agent captain, bare merge: cwd is not trusted" agent-captain deny "git merge feat" "${FEAT}"
expect "top-level --agent captain, explicit cd to a feature branch" agent-captain allow "cd ${FEAT} && git push"
expect "subagent, bare push: cwd is the dir it runs in" captain allow "git push" "${FEAT}"

echo "== fail-open and hook contract =="
OUT=$(printf '' | "${HOOK}" 2>/dev/null); RC=$?
if [ "${RC}" -eq 0 ] && [ -z "${OUT}" ]; then ok "empty stdin: exit 0, no output"; else bad "empty stdin" "rc=${RC} ${OUT}"; fi
OUT=$(printf 'not json pr merge' | "${HOOK}" 2>/dev/null); RC=$?
if [ "${RC}" -eq 0 ] && [ -z "${OUT}" ]; then ok "invalid JSON: exit 0, no output"; else bad "invalid JSON" "rc=${RC} ${OUT}"; fi
expect "non-Bash tool" captain allow "gh-athena pr merge 5" "${HOMEREPO}" "Edit"
# No ruby on PATH: the checker cannot run, so the hook fails open.
NORUBY="${TMP}/noruby"
mkdir -p "${NORUBY}"
for t in sh bash cat dirname realpath mkdir date printf; do
  p=$(command -v "${t}" 2>/dev/null) && [ -x "${p}" ] && ln -sf "${p}" "${NORUBY}/${t}"
done
OUT=$(payload captain "gh-athena pr merge 5 --squash" "${HOMEREPO}" Bash | PATH="${NORUBY}" "${HOOK}" 2>/dev/null); RC=$?
if [ "${RC}" -eq 0 ] && [ -z "${OUT}" ]; then ok "no ruby on PATH: exit 0, no output (fail-open)"; else bad "no ruby on PATH" "rc=${RC} ${OUT}"; fi
# No jq on PATH: the hook never needs jq, so a captain merge is still denied.
NOJQ="${TMP}/nojq"
mkdir -p "${NOJQ}"
RUBY_BIN=$(PATH="${REAL_PATH}" ruby -e 'print RbConfig.ruby' 2>/dev/null)
for t in sh bash cat dirname realpath mkdir date printf git; do
  p=$(command -v "${t}" 2>/dev/null) && [ -x "${p}" ] && ln -sf "${p}" "${NOJQ}/${t}"
done
[ -x "${RUBY_BIN}" ] && ln -sf "${RUBY_BIN}" "${NOJQ}/ruby"
OUT=$(payload captain "gh-athena pr merge 5 --squash" "${HOMEREPO}" Bash | PATH="${NOJQ}" "${HOOK}" 2>/dev/null); RC=$?
if [ "${RC}" -eq 0 ] && printf '%s' "${OUT}" | grep -q '"deny"'; then ok "no jq on PATH: the hook does not need it, the merge is still denied"; else bad "no jq on PATH" "rc=${RC} ${OUT}"; fi
if [ -z "${MRG_HOOK:-}" ]; then
  H=$("${HOOK}" --help </dev/null); RC=$?
  if [ "${RC}" -eq 0 ] && printf '%s' "${H}" | grep -q 'merge-role-guard'; then ok "--help on stdout, exit 0"; else bad "--help" "rc=${RC}"; fi
  LOG="${XDG_STATE_HOME}/athena/merge-role-guard.log"
  if [ -s "${LOG}" ] && grep -q 'athena-captain' "${LOG}" && grep -q 'deny' "${LOG}" && grep -q 'pr merge 275' "${LOG}"; then
    ok "denies are logged with role and command"
  else
    bad "denies are logged" "no matching deny line in ${LOG}"
  fi
fi

echo
echo "merge-role-guard self-test: ${PASS} passed, ${FAIL} failed"
if [ "${FAIL}" -ne 0 ]; then
  echo "Fix: read each FAIL line above; fix ai/hooks/merge-role-guard.sh or ai/lib/merge_role*.rb (or the case, if the case is wrong)."
  exit 1
fi
exit 0
