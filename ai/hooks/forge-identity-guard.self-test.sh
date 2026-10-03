#!/bin/sh
# Self-test for forge-identity-guard.sh.
#
# Pipes crafted PreToolUse stdin JSON into the hook and asserts the DENY/allow
# behavior described in the spec. DND-577: this guard DENIES (a PreToolUse
# permissionDecision "deny", which stops the command BEFORE it runs) — a
# non-blocking additionalContext warn reached the model only with the tool
# result, after the owner-attributed push had already gone out. So "deny" here
# means the hook emitted permissionDecision "deny" with a reason, and "allow"
# means it emitted nothing.
# Hermetic: no network, no state mutation outside a mktemp dir; the git-push
# cases (DND-389) build throwaway repos there so the hook can resolve a remote.
#
# Exit 0 iff every case passes.

HOOK="$(dirname "$0")/forge-identity-guard.sh"
HOOK=$(CDPATH= cd "$(dirname "$HOOK")" && printf '%s/%s' "$(pwd)" "$(basename "$HOOK")")

[ -f "$HOOK" ] || { echo "FAIL: hook not found at $HOOK"; exit 1; }

PASS=0
FAIL=0

run() {
  OUT=$(printf '%s' "$1" | sh "$HOOK" 2>/dev/null)
  STATUS=$?
}

is_deny() {
  [ "$STATUS" -eq 0 ] && printf '%s' "$OUT" | grep -q '"permissionDecision":"deny"' \
    && printf '%s' "$OUT" | grep -q '"permissionDecisionReason":"forge-identity:'
}

is_allow() {
  [ "$STATUS" -eq 0 ] && [ -z "$OUT" ]
}

# check <label> <expected: deny|allow>
check() {
  _label=$1
  _expect=$2
  if [ "$_expect" = "deny" ]; then
    if is_deny; then _r=PASS; else _r=FAIL; fi
  else
    if is_allow; then _r=PASS; else _r=FAIL; fi
  fi
  if [ "$_r" = PASS ]; then
    PASS=$((PASS + 1))
    printf '  PASS  %s (expected %s)\n' "$_label" "$_expect"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL  %s (expected %s) status=%s out=[%s]\n' "$_label" "$_expect" "$STATUS" "$OUT"
  fi
}

bash_json() {
  jq -cn --arg c "$1" '{tool_name:"Bash",tool_input:{command:$c}}'
}

# bash_json_cwd <cwd> <command> : the hook input as Claude Code sends it, with cwd.
bash_json_cwd() {
  jq -cn --arg d "$1" --arg c "$2" '{tool_name:"Bash",cwd:$d,tool_input:{command:$c}}'
}

# is_deny_with <needle> : a deny whose text also carries <needle>.
is_deny_with() {
  is_deny && printf '%s' "$OUT" | grep -qF -- "$1"
}

# check_text <label> <needle> : the last run denied AND carried <needle>.
check_text() {
  if is_deny_with "$2"; then
    PASS=$((PASS + 1)); printf '  PASS  %s\n' "$1"
  else
    FAIL=$((FAIL + 1)); printf '  FAIL  %s (needle [%s]) status=%s out=[%s]\n' "$1" "$2" "$STATUS" "$OUT"
  fi
}

TMP=$(mktemp -d) || { echo "FAIL: mktemp"; exit 1; }
trap 'rm -rf "$TMP"' EXIT
# Sandbox git: no owner/global config can change what a remote resolves to.
GIT_CONFIG_NOSYSTEM=1; GIT_CONFIG_GLOBAL="$TMP/gitconfig"; export GIT_CONFIG_NOSYSTEM GIT_CONFIG_GLOBAL
: > "$GIT_CONFIG_GLOBAL"
mkrepo() { git init -q "$TMP/$1" && git -C "$TMP/$1" remote add origin "$2"; }
mkrepo gh_scp 'git@github.com:o/r.git'
mkrepo gh_https 'https://github.com/o/r.git'
mkrepo gl 'git@gitlab.com:g/r.git'
mkrepo gl_https 'https://gitlab.com/g/r.git'
mkrepo gh_glpush 'https://github.com/o/r.git'
git -C "$TMP/gh_glpush" config remote.origin.pushurl 'git@gitlab.com:g/r.git'
mkrepo local "$TMP/bare.git"
mkrepo gl_ghpush 'git@gitlab.com:g/r.git'
git -C "$TMP/gl_ghpush" config remote.origin.pushurl 'git@github.com:o/r.git'
mkdir -p "$TMP/norepo"
mkrepo gopath "$TMP/go/src/github.com/o/r.git"

echo "forge-identity-guard self-test"
echo "hook: $HOOK"
echo

echo "--- WARN cases (bare create/merge = owner-attributed write) ---"

run "$(bash_json 'gh pr create --title x --body y')"
check "1a. bare gh pr create" deny

run "$(bash_json 'gh -R o/r pr create --fill')"
check "1b. gh pr create with flags before subcommand" deny

run "$(bash_json 'glab mr create --fill')"
check "1c. bare glab mr create" deny

run "$(bash_json 'gh pr merge 5 --squash')"
check "2a. bare gh pr merge" deny
check_text "2a2. the deny names integration-gate then locked-merge, not a bare gh-athena merge (DND-969)" 'integration-gate` from the worktree of the PR, then `~/dev/custom/ai/skills/athena:merge-boarding/scripts/locked-merge --pr <n> --head <sha>'

run "$(bash_json 'gh -R o/r pr merge 5 --auto')"
check "2b. gh pr merge with flags before subcommand" deny

run "$(bash_json 'glab mr merge 42')"
check "2c. bare glab mr merge" deny
check_text "2c2. the deny names the pinned glab-athena path" 'glab-athena mr merge <iid> --sha <head sha>'

# DND-742: bare glab merges beyond `mr merge` run as the owner and skip
# glab-athena's merge guard.
run "$(bash_json 'glab mr accept 42 --yes')"
check "2q. bare glab mr accept (merge's alias)" deny

run "$(bash_json 'glab -R g/r mr accept 42')"
check "2r. glab mr accept with flags before the subcommand" deny

run "$(bash_json 'glab api -X PUT "projects/:id/merge_requests/42/merge"')"
check "2s. bare glab api PUT …/merge_requests/<iid>/merge" deny

run "$(bash_json 'glab api --method PUT projects/g%2Fr/merge_requests/42/merge?sha=abc')"
check "2t. bare glab api merge route with a query string" deny

run "$(bash_json 'glab api -X POST "projects/:id/merge_trains/merge_requests/42" -f sha=abc')"
check "2u. bare glab api merge-train boarding" deny
# (The reason is JSON, so its double quotes arrive escaped.)
check_text "2u2. the deny names the guarded boarding path" 'glab-athena api -X POST \"projects/:id/merge_trains/merge_requests/<iid>\" -f sha=<head sha>'

run "$(bash_json "glab api graphql -f query='mutation { mergeRequestAccept(input: {projectPath: \"g/r\", iid: \"42\", sha: \"x\"}) { errors } }'")"
check "2v. bare glab api graphql mergeRequestAccept" deny

run "$(bash_json 'cd /tmp && /usr/bin/glab api -X PUT projects/1/merge_requests/42/merge')"
check "2w. path-qualified glab after a separator" deny

run "$(bash_json '~/dev/custom/ai/bin/glab-athena api -X POST "projects/:id/merge_trains/merge_requests/42" -f sha=abc')"
check "2x. glab-athena train boarding (the wrapper judges it)" allow

run "$(bash_json '~/dev/custom/ai/bin/glab-athena mr accept 42 --sha abc')"
check "2y. glab-athena mr accept (the wrapper judges it)" allow

run "$(bash_json 'glab api "projects/:id/merge_trains?scope=active"')"
check "2z. bare glab api read of the active train" allow

run "$(bash_json 'glab api projects/:id/merge_requests/42/merge_ref')"
check "2z2. bare glab api read of merge_ref" allow

run "$(bash_json 'glab api -X POST projects/:id/merge_requests/42/notes -f body=merge')"
check "2z3. bare glab api note (not a merge route; a write since DND-1179)" deny

run "$(bash_json "glab api graphql -f query='mutation { mergeRequestSetLabels(input: {}) { errors } }'")"
check "2z4. bare glab api graphql mergeRequestSetLabels (a mutation, DND-1179)" deny

# DND-728: a bare `gh api` merge runs as the owner and skips gh-athena's guard.
run "$(bash_json 'gh api -X PUT repos/o/r/pulls/5/merge -f merge_method=squash')"
check "2d. bare gh api PUT …/pulls/<n>/merge" deny

run "$(bash_json 'gh api --method PUT /repos/o/r/pulls/5/merge/')"
check "2e. bare gh api merge route, leading and trailing slash" deny

run "$(bash_json 'gh api -X POST repos/o/r/merges -f base=main -f head=f')"
check "2f. bare gh api POST …/merges" deny

run "$(bash_json 'gh api -X POST repos/o/r/merge-upstream -f branch=main')"
check "2g. bare gh api POST …/merge-upstream" deny

run "$(bash_json "gh api graphql -f query='mutation { m: mergePullRequest(input: {pullRequestId: \"x\"}) { clientMutationId } }'")"
check "2h. bare gh api graphql mergePullRequest" deny

run "$(bash_json "gh api graphql -f query='mutation { enablePullRequestAutoMerge(input: {pullRequestId: \"x\"}) { clientMutationId } }'")"
check "2i. bare gh api graphql enablePullRequestAutoMerge" deny

run "$(bash_json "gh api graphql -f query='mutation { enqueuePullRequest(input: {pullRequestId: \"x\"}) { clientMutationId } }'")"
check "2j. bare gh api graphql enqueuePullRequest" deny

run "$(bash_json "gh api graphql -f query='mutation { mergeBranch(input: {repositoryId: \"R\", base: \"main\", head: \"f\"}) { clientMutationId } }'")"
check "2k. bare gh api graphql mergeBranch" deny
check_text "2k2. the deny names the guarded path, integration-gate then locked-merge (DND-969)" 'integration-gate` from the worktree of the PR, then `~/dev/custom/ai/skills/athena:merge-boarding/scripts/locked-merge --pr <n> --head <sha>'

run "$(bash_json 'cd /tmp && /usr/bin/gh api -X PUT repos/o/r/pulls/5/merge')"
check "2l. path-qualified gh after a separator" deny

run "$(bash_json '~/dev/custom/ai/bin/gh-athena api -X PUT repos/o/r/pulls/5/merge')"
check "2m. gh-athena api merge (the wrapper judges it)" allow

run "$(bash_json 'gh api -X PUT repos/o/r/issues/5/labels -f labels[]=bug')"
check "2n. bare gh api PUT to a non-merge route (a write since DND-1179)" deny

run "$(bash_json "gh api graphql -f query='mutation { disablePullRequestAutoMerge(input: {pullRequestId: \"x\"}) { clientMutationId } }'")"
check "2o. bare gh api graphql disablePullRequestAutoMerge (a mutation, DND-1179)" deny

run "$(bash_json 'gh api repos/o/r/git/refs/heads/merge-x')"
check "2p. bare gh api read of a branch named merge-x" allow

# DND-741: a bare `gh api` write that moves or creates a ref runs as the owner
# AND puts commits on a branch with no pinned head and no green check.
run "$(bash_json 'gh api -X PATCH repos/o/r/git/refs/heads/main -f sha=abc -F force=true')"
check "4a. bare gh api PATCH git/refs/heads/main" deny
check_text "4a2. the deny names the branch-push path" 'gh-athena git push'
check_text "4a3. ...and the guarded merge path, integration-gate then locked-merge (DND-969)" 'integration-gate` from the worktree of the PR, then `~/dev/custom/ai/skills/athena:merge-boarding/scripts/locked-merge --pr <n> --head <sha>'

run "$(bash_json 'gh api repos/o/r/git/refs -f ref=refs/heads/x -f sha=abc')"
check "4b. bare gh api git/refs with fields, no -X (POST)" deny

run "$(bash_json 'gh api -XPATCH /repos/o/r/git/refs/heads/feat --input body.json')"
check "4c. -XPATCH with --input on any branch" deny

run "$(bash_json "gh api -H 'X-HTTP-Method-Override: PATCH' repos/o/r/git/refs/heads/main")"
check "4d. GET + method-override header on git/refs" deny

run "$(bash_json 'gh api --method=PUT repos/o/r/contents/lib/a.ex -f message=x -f content=eA==')"
check "4e. bare gh api PUT contents/<path>" deny

# DND-1886: an option's VALUE that looks like -X<method> is not the method. The
# real method is POST/PATCH, so the ref-write rule must own the deny and its Fix
# (the guarded push path), not leave the call to the generic api-write rule.
run "$(bash_json 'gh api -X POST repos/o/r/git/refs -f ref=refs/heads/x -f sha=abc --jq -XGET')"
check "4e1. -X POST + --jq -XGET on git/refs" deny
check_text "4e2. ...the deny is the ref-write one, naming the guarded push path" 'creates or moves a ref'
run "$(bash_json 'gh api --method PATCH repos/o/r/git/refs/heads/main -f sha=abc -q -XGET')"
check "4e3. --method PATCH + -q -XGET on git/refs" deny
check_text "4e4. ...the deny is the ref-write one" 'creates or moves a ref'
run "$(bash_json 'gh api -X GET repos/o/r/git/refs/heads/main --jq -XPATCH')"
check "4e5. verdict unchanged: -X GET + --jq -XPATCH is still denied" deny

run "$(bash_json 'gh api -X DELETE repos/o/r/contents/lib/a.ex -f message=x -f sha=abc')"
check "4f. bare gh api DELETE contents/<path>" deny

run "$(bash_json 'gh api -X POST repos/o/r/branches/feat/rename -f new_name=main')"
check "4g. bare gh api POST branches/<b>/rename" deny

run "$(bash_json 'gh api -X PUT repos/o/r/pulls/5/update-branch')"
check "4h. bare gh api PUT pulls/<n>/update-branch" deny

run "$(bash_json "gh api graphql -f query='mutation { createCommitOnBranch(input: {branch: {branchName: \"main\"}}) { commit { oid } } }'")"
check "4i. bare gh api graphql createCommitOnBranch" deny

run "$(bash_json "gh api graphql -f query='mutation { updateRef(input: {refId: \"x\", oid: \"y\"}) { clientMutationId } }'")"
check "4j. bare gh api graphql updateRef" deny

run "$(bash_json "gh api graphql -f query='mutation { updateRefs(input: {repositoryId: \"x\", refUpdates: []}) { clientMutationId } }'")"
check "4k. bare gh api graphql updateRefs" deny

run "$(bash_json "gh api graphql -f query='mutation { createRef(input: {repositoryId: \"x\", name: \"refs/heads/y\", oid: \"z\"}) { clientMutationId } }'")"
check "4l. bare gh api graphql createRef" deny

run "$(bash_json "gh api graphql -f query='mutation { updatePullRequestBranch(input: {pullRequestId: \"x\"}) { clientMutationId } }'")"
check "4m. bare gh api graphql updatePullRequestBranch" deny

run "$(bash_json 'cd /tmp && /usr/bin/gh -R o/r api -X PATCH repos/o/r/git/refs/heads/main -f sha=abc')"
check "4n. path-qualified gh, flags before api, after a separator" deny

run "$(bash_json 'gh api repos/o/r/git/refs/heads/main --jq .object.sha')"
check "4o. bare gh api READ of git/refs/heads/main" allow

run "$(bash_json 'gh api -X DELETE repos/o/r/git/refs/heads/dnd-1-done')"
check "4p. bare gh api DELETE of a branch ref (not a ref MOVE, but an owner-attributed write, DND-1179)" deny

run "$(bash_json 'gh api -X GET repos/o/r/contents/README.md -f ref=main')"
check "4q. -X GET contents with a ref field (a read)" allow

run "$(bash_json "gh api graphql -f query='mutation { deleteRef(input: {refId: \"x\"}) { clientMutationId } }'")"
check "4r. bare gh api graphql deleteRef (a mutation, DND-1179)" deny

run "$(bash_json '~/dev/custom/ai/bin/gh-athena api -X PATCH repos/o/r/git/refs/heads/main -f sha=abc')"
check "4s. gh-athena api ref write (the wrapper judges it)" allow

run "$(bash_json 'gh api -X POST repos/o/r/git/commits -f message=x -f tree=abc')"
check "4t. bare gh api POST git/commits (an object only; a write since DND-1179)" deny

run "$(bash_json 'gh api repos/o/r/git/refs/heads/main; echo -f x')"
check "4u. a field flag in a LATER command does not make a read a write" allow

run "$(bash_json_cwd "$TMP/gh_scp" 'git push origin HEAD')"
check "3a. plain git push, origin git@github.com: (cwd)" deny

run "$(bash_json_cwd "$TMP/gh_https" 'git push')"
check "3b. plain git push, default remote -> https github origin" deny

run "$(bash_json_cwd "$TMP/norepo" "git -C $TMP/gh_scp push origin HEAD")"
check "3c. git -C <github repo> push from another dir" deny

run "$(bash_json_cwd "$TMP/norepo" "cd $TMP/gh_scp && git push -u origin HEAD")"
check "3d. cd <github repo> && git push -u" deny

run "$(bash_json_cwd "$TMP/gl" 'git push https://github.com/o/r.git HEAD')"
check "3e. git push to a literal github.com URL" deny

run "$(bash_json_cwd "$TMP/gh_scp" '/usr/bin/git push origin HEAD')"
check "3f. path-qualified /usr/bin/git push" deny

run "$(bash_json_cwd "$TMP/gh_scp" 'GIT_TERMINAL_PROMPT=0 git -c credential.helper= push origin HEAD')"
check "3g. helper-disabled plain git push (still the owner, not the wrapper)" deny

run "$(bash_json_cwd "$TMP/gl_ghpush" 'git push')"
check "3h. gitlab fetch url but a github.com pushurl" deny

run "$(bash_json_cwd "$TMP/norepo" 'git push origin HEAD')"
check "3i. unresolvable remote (not a repo) -> still denies, never silent" deny
check_text "3i'. the unresolvable deny says it could not resolve" 'could not resolve its remote'

run "$(bash_json_cwd "$TMP/norepo" "git -C $TMP/local push origin HEAD; git -C $TMP/gh_scp push origin HEAD")"
check_text "3m. two pushes, the SECOND to github -> denies (every push examined)" 'to a github.com remote'

run "$(bash_json_cwd "$TMP/norepo" "git -C $TMP/gl push origin HEAD; git -C $TMP/gh_scp push origin HEAD")"
check_text "3m2. gitlab push then github push -> the gitlab deny does not hide the github one" 'to a github.com remote'
check_text "3m3. ...and the gitlab one is reported too" 'to a gitlab.com remote'

run "$(bash_json_cwd "$TMP" 'cd gh_scp && git push')"
check_text "3n. relative cd resolved against the input cwd" 'to a github.com remote'

run "$(bash_json_cwd "$TMP/gh_scp" "$(printf 'git push\necho done')")"
check_text "3o. multi-line: push's args end at its line (origin=github still denies)" 'to a github.com remote'

run "$(bash_json_cwd "$TMP/gh_scp" 'git push orgin HEAD')"
check_text "3p. a target that is neither a remote nor a URL -> could-not-resolve deny" 'could not resolve its remote'

run "$(bash_json_cwd "$TMP/gh_scp" 'git push origin HEAD')"
check_text "3j. push deny carries the escalate Fix:" 'Fix: push through the wrapper'
check_text "3k. push deny says escalate to your admiral" 'escalate to your admiral with the command + error and wait'

echo
echo "--- DND-1862: push argv read with git's grammar (fg_push_argv), not word by word ---"
# Each push below goes to the github origin as git reads it: an option VALUE
# is not the repository, so git falls back to the default remote.
run "$(bash_json_cwd "$TMP/gh_scp" 'git push -fo /tmp/x.git')"
check_text "A1. push -fo <path>: -o takes the path as its value, origin=github denies" 'to a github.com remote'
run "$(bash_json_cwd "$TMP/gh_scp" 'git push --push-o /tmp/x.git')"
check_text "A2. push --push-o <path> (an abbreviation of --push-option) denies" 'to a github.com remote'
run "$(bash_json_cwd "$TMP/gh_scp" 'git push --repo=/tmp/x.git --no-repo')"
check_text "A3. push --repo=<path> --no-repo: the default remote (github) denies" 'to a github.com remote'
run "$(bash_json_cwd "$TMP/gh_scp" 'git push -o ci.skip -v')"
check_text "A4. push -o <value> -v: the value is not the repository" 'to a github.com remote'
# The global peel: a global option's value is not the subcommand.
run "$(bash_json_cwd "$TMP/gh_scp" 'git --namespace ns push origin HEAD')"
check_text "A5. git --namespace <ns> push (a global value option) denies" 'to a github.com remote'
run "$(bash_json_cwd "$TMP/norepo" "git -C $TMP -C gh_scp push origin HEAD")"
check_text "A6. git -C <a> -C <b> push: -C values join, as git applies them" 'to a github.com remote'
run "$(bash_json_cwd "$TMP/local" "git --git-dir $TMP/gh_scp/.git push origin HEAD")"
check_text "A7. git --git-dir <github repo> push: the remote is read in that repo" 'to a github.com remote'
run "$(bash_json_cwd "$TMP/local" 'git -c remote.origin.url=git@github.com:o/r.git push origin HEAD')"
check_text "A8. git -c remote.origin.url=<github> push: the override is read" 'to a github.com remote'
# Deny by default: an option git push's grammar does not have.
run "$(bash_json_cwd "$TMP/local" 'git push --bogus-flag origin HEAD')"
check_text "A9. push with an option git push does not have -> deny, names it" '--bogus-flag'
# As git reads them, in the allow direction too.
run "$(bash_json_cwd "$TMP/local" "git push -fo ci.skip $TMP/bare.git HEAD")"
check "A10. push -fo <value> <local path>: the repository is the path -> allow" allow
run "$(bash_json_cwd "$TMP/gh_scp" 'git --no-pager log --grep push')"
check "A11. git --no-pager log --grep push (log is the subcommand) -> allow" allow
run "$(bash_json_cwd "$TMP/gh_scp" 'git --version push')"
check "A12. git --version push (prints and exits; nothing is pushed) -> allow" allow
# An empty quoted word is still a word to git (review round).
run "$(bash_json_cwd "$TMP/gh_scp" "git -C '' push")"
check_text "A15. git -C '' push: -C '' is the cwd, push is the subcommand" 'to a github.com remote'
run "$(bash_json_cwd "$TMP/gh_scp" 'git --namespace "" push origin HEAD')"
check_text "A16. git --namespace \"\" push origin" 'to a github.com remote'
# A redirection is not argv: git never sees it as the repository.
run "$(bash_json_cwd "$TMP/gh_scp" 'git push 2>/dev/null')"
check_text "A17. git push 2>/dev/null: the default remote (github) denies" 'to a github.com remote'
run "$(bash_json_cwd "$TMP/gh_scp" 'git push > /tmp/push.log 2>&1')"
check_text "A18. git push > <file> 2>&1: the default remote (github) denies" 'to a github.com remote'
run "$(bash_json_cwd "$TMP/gh_scp" "git push $TMP/bare.git HEAD 2>/dev/null")"
check "A19. git push <local path> HEAD 2>/dev/null -> allow" allow
run "$(bash_json_cwd "$TMP/local" 'git push --repo=git@github.com:o/r.git')"
check_text "A20. git push --repo=<github url>: the --repo value is the repository" 'to a github.com remote'
# DND-1887: help as the FIRST push argument prints usage and exits before git
# reads a remote, so it is allowed (the same rule merge-role-guard has, DND-1865).
# Help anywhere else is judged as before: git accepts abbreviated long options,
# so `--push-op -h` makes -h an option value.
run "$(bash_json_cwd "$TMP/gh_scp" 'git push -h')"
check "B1. git push -h (help first, origin=github) -> allow" allow
run "$(bash_json_cwd "$TMP/gh_scp" 'git push --help')"
check "B2. git push --help -> allow" allow
run "$(bash_json_cwd "$TMP/norepo" "git -C $TMP/gh_scp push -h")"
check "B3. git -C <github repo> push -h -> allow" allow
run "$(bash_json_cwd "$TMP/gh_scp" 'git push -h 2>&1')"
check "B4. git push -h 2>&1 -> allow" allow
run "$(bash_json_cwd "$TMP/gh_scp" 'git push origin -h')"
check_text "B5. git push origin -h (help after the repository) is judged: denies" 'to a github.com remote'
run "$(bash_json_cwd "$TMP/gh_scp" 'git push -- -h')"
check_text "B6. git push -- -h (after --, -h is a repository word) is judged: denies" 'could not resolve its remote'
run "$(bash_json_cwd "$TMP/gh_scp" 'git push --push-op -h')"
check_text "B7. git push --push-op -h (-h is the option's value) denies" 'to a github.com remote'
run "$(bash_json_cwd "$TMP/gh_scp" 'git push -f -h origin main')"
check_text "B8. git push -f -h origin main (help behind another option) denies" 'to a github.com remote'
run "$(bash_json_cwd "$TMP/gh_scp" 'git push -o -h')"
check_text "B9. git push -o -h (-o takes -h as its value) denies" 'to a github.com remote'
run "$(bash_json_cwd "$TMP/gh_scp" 'git push -h; git push origin HEAD')"
check_text "B10. help, then a real push: the second push is still examined" 'to a github.com remote'
run "$(bash_json_cwd "$TMP/gh_scp" 'git push -h origin main')"
check "B11. git push -h origin main: git prints usage and exits, so -h first allows" allow
run "$(bash_json_cwd "$TMP/gh_scp" 'git -c k=v push -h')"
check "B12. git -c k=v push -h: a global value option does not hide help-first" allow
run "$(bash_json_cwd "$TMP/gh_scp" 'git push -hf origin main')"
check_text "B13. git push -hf (a cluster, not the help word) is judged: denies" 'to a github.com remote'
run "$(bash_json_cwd "$TMP/gh_scp" 'git push -h && git push origin HEAD')"
check_text "B14. help && a real push: the second push is still examined" 'to a github.com remote'
# The grammar cannot be read (a hook copy with no ../lib beside it): a push
# is denied as unresolved, naming the file, never allowed as "not a forge".
mkdir -p "$TMP/nolib/hooks"
cp "$HOOK" "$TMP/nolib/hooks/forge-identity-guard.sh"
OUT=$(bash_json_cwd "$TMP/local" 'git push origin HEAD' | sh "$TMP/nolib/hooks/forge-identity-guard.sh" 2>/dev/null); STATUS=$?
check_text "A13. no push grammar to read -> the push is denied, naming the file" 'restore ai/lib/forge-git-passthrough.sh'
OUT=$(bash_json_cwd "$TMP/local" 'git log --oneline' | sh "$TMP/nolib/hooks/forge-identity-guard.sh" 2>/dev/null); STATUS=$?
check "A14. no push grammar, and no push in the command -> allow" allow

run "$(bash_json 'gh pr create --fill')"
check_text "3l. create deny carries the escalate clause" 'escalate to your admiral with the command + error and wait'

echo
echo "--- DND-1179: EVERY plain gh/glab write denies; reads still pass ---"
# 2026-09-29 00:11Z: an admiral's plain `gh pr close 119 -R CJPoll/custom`
# (output redirected) ran, and GitHub recorded the close as CJPoll. The guard
# covered create/merge only. The rule is now a positive model: per command
# group, a READ allowlist; any other verb of a known group is a write.

# deny_each <label-prefix> <cmd>... : each command must deny with the
# DND-1179 write text (not only some older rule's).
deny_each() {
  _p=$1; shift
  for _c in "$@"; do
    run "$(bash_json "$_c")"
    check_text "$_p: $_c" 'DND-1179'
  done
}

# allow_each <label-prefix> <cmd>... : each command must pass silently.
allow_each() {
  _p=$1; shift
  for _c in "$@"; do
    run "$(bash_json "$_c")"
    check "$_p: $_c" allow
  done
}

run "$(bash_json 'gh pr close 119 -R CJPoll/custom >/dev/null 2>&1')"
check "W1. the incident: gh pr close 119 -R CJPoll/custom, output redirected" deny
check_text "W1b. its Fix names the wrapper form of the same command" 'gh-athena pr close'

deny_each "W2 gh pr write" \
  'gh pr close 5' 'gh pr reopen 5' 'gh pr edit 5 --title x' 'gh pr ready 5' \
  'gh pr comment 5 --body x' 'gh pr review 5 --approve' 'gh pr lock 5' \
  'gh pr unlock 5' 'gh pr update-branch 5' 'gh pr revert 5' 'gh pr edit 5 --add-label bug' \
  'gh -R o/r pr close 5' 'gh pr --repo o/r close 5' '/usr/bin/gh pr close 5' \
  'cd /tmp && gh pr close 5' 'timeout 30 gh pr comment 5 -b x' '"gh" pr close 5' \
  'echo x | xargs gh pr close'
deny_each "W3 gh issue write" \
  'gh issue create -t x -b y' 'gh issue close 7' 'gh issue reopen 7' 'gh issue edit 7 --add-label x' \
  'gh issue comment 7 -b x' 'gh issue delete 7 --yes' 'gh issue lock 7' 'gh issue unlock 7' \
  'gh issue pin 7' 'gh issue unpin 7' 'gh issue transfer 7 o/r2' 'gh issue develop 7'
deny_each "W4 gh other groups" \
  'gh release create v1' 'gh release edit v1 --draft=false' 'gh release delete v1 --yes' \
  'gh release upload v1 a.tgz' 'gh repo create o/new --private' 'gh repo edit --visibility public' \
  'gh repo delete o/r --yes' 'gh repo fork o/r' 'gh repo rename x' 'gh repo archive o/r' \
  'gh repo sync o/fork' 'gh repo deploy-key add k.pub' 'gh secret set X --body y' \
  'gh secret delete X' 'gh variable set X --body y' 'gh variable delete X' \
  'gh label create bug' 'gh label edit bug --color fff' 'gh label delete bug --yes' \
  'gh label clone o/r2' 'gh gist create a.txt' 'gh gist edit abc' 'gh gist delete abc' \
  'gh run rerun 9' 'gh run cancel 9' 'gh run delete 9' 'gh workflow run ci.yml' \
  'gh workflow enable ci.yml' 'gh workflow disable ci.yml' 'gh cache delete k' \
  'gh project create --title x' 'gh project item-add 1 --url u' 'gh alias set pc "pr close"'
deny_each "W5 gh api write" \
  'gh api -X POST repos/o/r/issues/5/comments -f body=x' \
  'gh api --method PATCH repos/o/r/issues/5 -f state=closed' \
  'gh api -XDELETE repos/o/r/issues/comments/1' \
  'gh api --method=PUT repos/o/r/issues/5/lock' \
  'gh api repos/o/r/issues/5/comments -f body=x' \
  'gh api repos/o/r/issues -F title=x' \
  'gh api repos/o/r/issues/5/labels --raw-field labels=bug' \
  'gh api repos/o/r/issues/5/labels --field labels=bug' \
  'gh api repos/o/r/issues --input body.json' \
  "gh api -H 'X-HTTP-Method-Override: DELETE' repos/o/r/issues/comments/1" \
  "gh api graphql -f query='mutation { closePullRequest(input: {pullRequestId: \"x\"}) { clientMutationId } }'" \
  'gh api graphql -F query=@q.graphql'
run "$(bash_json 'gh api -X PUT repos/o/r/issues/5/labels -f labels[]=bug')"
check_text "W5b. 2n now denies by the DND-1179 write rule" 'DND-1179'
run "$(bash_json 'gh api -X DELETE repos/o/r/git/refs/heads/dnd-1-done')"
check_text "W5c. 4p now denies by the DND-1179 write rule" 'DND-1179'
run "$(bash_json 'gh api -X POST repos/o/r/git/commits -f message=x -f tree=abc')"
check_text "W5d. 4t now denies by the DND-1179 write rule" 'DND-1179'
run "$(bash_json 'gh api -X POST repos/o/r/issues/5/comments -f body=x')"
check_text "W5e. an api write's Fix names gh-athena api" 'gh-athena api'
run "$(bash_json 'gh api -X PUT repos/o/r/pulls/5/merge')"
check_text "W5f. a merge route keeps its own (merge) Fix, not the generic one" 'locked-merge --pr <n>'

deny_each "W6 glab write" \
  'glab mr close 4' 'glab mr reopen 4' 'glab mr update 4 --title x' 'glab mr note 4 -m x' \
  'glab mr approve 4' 'glab mr revoke 4' 'glab mr rebase 4' 'glab mr delete 4' \
  'glab mr subscribe 4' 'glab mr todo 4' 'glab -R g/r mr close 4' \
  'glab issue create -t x' 'glab issue close 3' 'glab issue update 3 --label x' \
  'glab issue note 3 -m x' 'glab issue delete 3' 'glab issue board create' \
  'glab release create v1' 'glab release upload v1 a.tgz' 'glab release delete v1' \
  'glab repo create g/new' 'glab repo fork g/r' 'glab repo delete g/r' 'glab repo transfer g/r' \
  'glab repo update --description x' 'glab repo mirror g/r' \
  'glab label create -n bug' 'glab label delete bug' 'glab variable set X y' \
  'glab variable update X y' 'glab variable delete X' 'glab ci run' 'glab ci retry 9' \
  'glab ci cancel 9' 'glab ci delete 9' 'glab ci trigger 9' 'glab pipeline run' \
  'glab schedule create' 'glab schedule run 1' 'glab milestone create' \
  'glab token create x' 'glab deploy-key add k.pub' 'glab snippet create a.txt' \
  'glab stack sync'
deny_each "W7 glab api write" \
  'glab api -X POST projects/:id/issues -f title=x' \
  'glab api --method PUT projects/:id/merge_requests/4 -f state_event=close' \
  'glab api projects/:id/merge_requests/4/notes -f body=x' \
  'glab api projects/:id/labels --field name=x' \
  "glab api graphql -f query='mutation { mergeRequestSetDraft(input: {}) { errors } }'"

echo "--- DND-1179: reads, help, wrappers and auth (forge-auth-guard's) must pass ---"
allow_each "R1 gh read" \
  'gh pr view 5' 'gh pr list --state open' 'gh pr status' 'gh pr checks 5 --watch' \
  'gh pr diff 5' 'gh pr checkout 5' 'gh -R o/r pr view 5 --json state' \
  'gh pr view 5 --json mergedAt,state >/dev/null 2>&1' \
  'gh issue view 7' 'gh issue list' 'gh issue status' 'gh release list' 'gh release view v1' \
  'gh release download v1' 'gh repo view' 'gh repo clone o/r' 'gh repo list' \
  'gh repo set-default o/r' 'gh repo deploy-key list' 'gh run view 9 --log' 'gh run list' \
  'gh run watch 9' 'gh run download 9' 'gh workflow list' 'gh workflow view ci.yml' \
  'gh label list' 'gh secret list' 'gh variable list' 'gh variable get X' 'gh gist list' \
  'gh gist view abc' 'gh cache list' 'gh search prs is:open' 'gh status' 'gh browse --no-browser' \
  'gh auth status' 'gh --version' 'gh version' 'gh help pr' 'gh pr close --help' 'gh pr' \
  'gh project list' 'gh project view 1' 'gh ruleset list' 'gh alias list' 'gh config get editor'
allow_each "R2 gh api read" \
  'gh api repos/o/r/pulls/5' 'gh api user --jq .login' 'gh api -X GET repos/o/r/issues -f state=open' \
  'gh api --method GET search/issues -F q=x' 'gh api --paginate repos/o/r/issues' \
  "gh api graphql -f query='{ viewer { login } }'" \
  "gh api graphql -f query='query(\$o: String!) { repository(owner: \$o, name: \"r\") { id } }' -f o=x"
allow_each "R3 glab read" \
  'glab mr view 4' 'glab mr list' 'glab mr diff 4' 'glab mr checkout 4' 'glab issue view 3' \
  'glab issue list' 'glab issue board view' 'glab ci status' 'glab ci view' 'glab ci trace 9' \
  'glab ci list' 'glab ci lint' 'glab pipeline list' 'glab release list' 'glab release view v1' \
  'glab repo view' 'glab repo clone g/r' 'glab label list' 'glab variable list' \
  'glab variable get X' 'glab schedule list' 'glab auth status' 'glab version' 'glab mr' \
  'glab api projects/:id/merge_requests/4' 'glab api -X GET projects/:id/issues -f state=opened' \
  "glab api graphql -f query='{ currentUser { username } }'"
allow_each "R4 wrappers and prose" \
  '~/dev/custom/ai/bin/gh-athena pr close 119 -R CJPoll/custom' \
  '~/dev/custom/ai/bin/gh-athena api -X POST repos/o/r/issues/5/comments -f body=x' \
  '~/dev/custom/ai/bin/glab-athena mr note 4 -m x' \
  '~/dev/custom/ai/bin/glab-athena api -X POST projects/:id/issues -f title=x' \
  'echo the gh CLI is fine' 'ls ~/dev/gh-pages' 'git log --oneline -3'

echo "--- DND-1843: -h / --help as a flag's VALUE is not help ---"
deny_each "X0 help word read as a value or an argument" \
  'gh issue create --title -h --body b' 'gh release create --notes --help v1' \
  'gh label create -- --help' 'glab issue create --title --help'
allow_each "X0b help where the CLI reads it as help" \
  'gh issue create -h' 'gh label create --help' 'gh issue create --title=t --help' 'glab mr note --help'

echo "--- DND-1179 review round: writes that passed, reads that were denied ---"
deny_each "X1 placeholder braces stay inside the word" \
  'gh api repos/{owner}/{repo}/issues -f title=x -f body=y' \
  'gh api repos/{owner}/{repo}/pulls/3/reviews -f event=APPROVE' \
  'gh pr {close,} 1'
deny_each "X2 group aliases" \
  'glab var set FOO bar' 'glab project delete o/r' 'glab project update --description x' \
  'glab pipe run' 'glab pipeline cancel 5' 'glab stacks sync' 'glab sched create' \
  'glab skd run 1' 'gh agent create x' 'gh agents create x' 'gh agent-tasks create x' \
  'gh cs delete x'
deny_each "X3 groups the first pass missed" \
  'gh discussion create' 'gh discussion comment 1' 'gh discussion edit 1' 'gh skill publish' \
  'gh skills publish' 'glab runner delete 1' 'glab runner pause 1' 'glab runner update 1' \
  'glab opentofu state delete x' 'glab opentofu state lock x' 'glab todo done 3' \
  'glab runner-controller create' 'glab runner-controller token rotate 1' \
  'gh copilot -p fix-it' 'glab mcp serve' 'glab duo cli'
deny_each "X3b glab 1.112 groups (K2 found them unclassified)" \
  'glab container-registry tag delete 1 latest' 'glab container-registry repository delete 1' \
  'glab packages delete 5' 'glab packages upload f --name n --version 1' \
  'glab security config enable sast' 'glab security config disable sast' \
  'glab orbit setup' 'glab orbit local' 'glab skills install' 'glab skills update'
allow_each "Y1b glab 1.112 reads" \
  'glab container-registry repository list' 'glab container-registry tag list 1' \
  'glab packages list' 'glab packages download --name n --version 1 --filename f' \
  'glab security config status sast' 'glab orbit remote status' 'glab search semantic x' \
  'glab skills list' 'glab dependency-firewall ci-summary' 'glab whatsnew'
deny_each "X4 glab api --form POSTs" \
  'glab api projects/:id/uploads --form file=@x.png' \
  'glab api projects/:id/issues --form title=x' \
  'glab api projects/:id/issues --form=title=x'
deny_each "X5 a graphql query this guard cannot read" \
  "gh api graphql -f query=\"\$(cat m.graphql)\"" \
  "gh api graphql -f query=\"\$Q\"" \
  "glab api graphql -f query=\"\`cat m.graphql\`\""
deny_each "X6 backticks" \
  'gh pr `printf close` 1' \
  'echo `gh pr close 5`'
allow_each "Y1 verb aliases and reads the first pass denied" \
  'gh pr ls' 'gh pr co 5' 'gh issue ls' 'gh repo ls' 'gh run ls' 'gh workflow ls' \
  'gh release ls' 'gh label ls' 'gh secret ls' 'gh variable ls' 'gh gist ls' 'gh cache ls' \
  'gh project ls' 'gh repo read-file README.md' 'gh discussion list' 'gh discussion view 1' \
  'gh rs ls' 'gh cs ls' 'gh codespace ports' 'gh skill search x' \
  'glab mr ls' 'glab mr show 3' 'glab issue ls' 'glab issue show 3' 'glab incident show 1' \
  'glab var ls' 'glab var get X' 'glab project view' 'glab pipe list' 'glab mr note list 3' \
  'glab cluster graph' 'glab runner list' 'glab todo list' 'glab duo ask what' \
  'glab opentofu state list' 'glab stacks list' 'glab work-items list'
allow_each "Y2 api reads with valued flags and placeholders" \
  'gh api --cache 1h graphql -f query=x' 'gh api --cache=1h graphql -f query=x' \
  'glab api --output json projects/:id' 'gh api repos/{owner}/{repo}/pulls' \
  'echo `gh pr view 5`'

echo "--- DND-1179 critic round 2: a backslash-newline continuation is ONE command ---"
# The shell joins `\`+newline before it runs anything; the guard turned the
# newline into a separator first, so each half was judged alone.
run "$(bash_json "$(printf 'gh api repos/o/r/issues/5/comments \\\n  -f body=x')")"
check_text "L1. gh api … \\⏎ -f body=x (a POST split across lines)" 'DND-1179'
run "$(bash_json "$(printf 'gh pr \\\nclose 5')")"
check_text "L2. gh pr \\⏎close 5" 'DND-1179'
run "$(bash_json "$(printf 'glab mr \\\n  note 4 -m x')")"
check_text "L3. glab mr \\⏎note 4" 'DND-1179'
run "$(bash_json_cwd "$TMP/norepo" "$(printf "git -C $TMP/gh_scp \\\\\npush origin HEAD")")"
check_text "L4. git -C <github repo> \\⏎push (the push rule had the same split)" 'to a github.com remote'
run "$(bash_json "$(printf 'gh pr view 5 \\\n  --json state')")"
check "L5. a READ split across lines still passes" allow
run "$(bash_json_cwd "$TMP/gh_scp" "$(printf 'git status\ngit log -1')")"
check "L6. a plain newline (no backslash) still separates two reads" allow

echo "--- DND-1179 critic round 3: a separator INSIDE quotes is data, not a command break ---"
deny_each "Q1 a field after a quoted separator" \
  "gh api repos/o/r/issues --jq '.number | tostring' -f title=x" \
  "gh api 'repos/o/r/issues?q=(x)' -f body=y" \
  'gh api repos/o/r/issues --jq ".a; .b" -f title=x' \
  "glab api projects/:id/issues --jq '.[] | .iid' -f title=x" \
  "gh api repos/o/r/issues -H 'Accept: a&b' --method POST" \
  "sh -c 'gh api repos/o/r/issues --jq \".a | .b\" -f title=x'"
allow_each "Q2 reads with quoted separators still pass" \
  "gh api repos/o/r/issues --jq '.[] | .number'" \
  'gh pr list --search "is:open (label:a) | x"' \
  "glab api projects/:id/issues --jq '.[] | .iid'"

# DND-1179 critic round 4: masking quoted separators in the push rule lost
# these unspaced payload pushes. The mask was reverted; the quoted-option gap
# it aimed at (`git -c 'core.x=a;b' push`) is DND-1206, out of scope here.
run "$(bash_json_cwd "$TMP/gh_scp" "sh -c 'true;git push origin HEAD'")"
check_text "Q3. sh -c 'true;git push origin HEAD' (unspaced, before git)" 'to a github.com remote'
run "$(bash_json_cwd "$TMP/gh_scp" "bash -c 'git push;echo ok'")"
check_text "Q4. bash -c 'git push;echo ok' (unspaced, after push)" 'to a github.com remote'
run "$(bash_json_cwd "$TMP/gh_scp" "git commit -m 'a; b' && git log -1")"
check "Q5. a quoted separator in a non-push git command still passes" allow

echo "--- DND-1179: every installed gh/glab command group is classified ---"
# A group the hook does not know is ALLOWED (it reads as prose), so a CLI
# upgrade that adds a group with a write verb would fail open. This turns it red.
# The tables live in the classifier the hook shares with the agent PATH
# wrappers (DND-1803).
FWC_LIB="$(dirname "$HOOK")/../lib/forge-write-class.awk"
KNOWN=$( { grep -oE 'RD\["(gh|glab) [a-z0-9-]+"\]' "$FWC_LIB" | sed -E 's/^RD\["//; s/"\]$//'
  sed -nE 's/^[[:space:]]*AGS\["(gh|glab)"\] = "([^"]*)".*/\1 \2/p' "$FWC_LIB" |
    while read -r _c _rest; do for _w in $_rest; do echo "$_c $_w"; done; done
  echo 'gh api'; echo 'glab api'; } | sort -u)
unclassified() {
  while read -r _n; do
    [ -n "$_n" ] || continue
    printf '%s\n' "$KNOWN" | grep -qxF -- "$1 $_n" || printf '%s ' "$_n"
  done
}
if command -v gh >/dev/null 2>&1; then
  GH_GROUPS=$(gh --help 2>/dev/null | awk '
    /^[A-Z][A-Z ]*COMMANDS$/ { on = ($0 !~ /ALIAS|EXTENSION/); next }
    /^$/ { on = 0 }
    on && /^  [a-z0-9-]+:/ { sub(/^  /, ""); sub(/:.*/, ""); print }')
  GH_ALL=$(for _g in $GH_GROUPS; do echo "$_g"; gh "$_g" --help 2>/dev/null | awk '
    /^ALIASES$/ { on = 1; next } /^$/ { on = 0 }
    on { gsub(/,/, " "); for (i = 1; i <= NF; i++) if ($i != "gh") print $i }'; done)
  _miss=$(printf '%s\n' "$GH_ALL" | unclassified gh)
  if [ -n "$GH_GROUPS" ] && [ -z "$_miss" ]; then
    PASS=$((PASS + 1)); printf '  PASS  K1. every gh %s group and group alias is classified (%s names)\n' "$(gh --version | awk 'NR==1{print $3}')" "$(printf '%s\n' "$GH_ALL" | grep -c .)"
  else
    FAIL=$((FAIL + 1)); printf '  FAIL  K1. gh groups not classified in the hook: [%s] (parsed %s names from gh --help). Fix: in ai/lib/forge-write-class.awk add RD["gh <group>"] with its read verbs (every other verb is denied), or add it to AGS["gh"] there if it has no forge write.\n' "$_miss" "$(printf '%s\n' "$GH_ALL" | grep -c .)"
  fi
else
  echo "  NOTE  K1. gh is not on PATH: gh group coverage NOT measured here"
fi
if command -v glab >/dev/null 2>&1; then
  GL_ALL=$(glab __complete '' 2>/dev/null | awk -F '\t' '/^[a-z0-9-]+\t/ { print $1 }')
  _miss=$(printf '%s\n' "$GL_ALL" | unclassified glab)
  if [ -n "$GL_ALL" ] && [ -z "$_miss" ]; then
    PASS=$((PASS + 1)); printf '  PASS  K2. every glab %s group is classified (%s names; group aliases are not listed by glab and are kept by hand)\n' "$(glab --version | awk 'NR==1{print $2}')" "$(printf '%s\n' "$GL_ALL" | grep -c .)"
  else
    FAIL=$((FAIL + 1)); printf '  FAIL  K2. glab groups not classified in the hook: [%s] (parsed %s names from glab __complete). Fix: in ai/lib/forge-write-class.awk add RD["glab <group>"] with its read verbs, or add it to AGS["glab"] there if it has no forge write.\n' "$_miss" "$(printf '%s\n' "$GL_ALL" | grep -c .)"
  fi
else
  echo "  NOTE  K2. glab is not on PATH: glab group coverage NOT measured here"
fi

echo
echo "--- DND-577: the 2026-09-24 incident — a plain push is STOPPED, not warned about ---"

mkrepo custom_incident 'git@github.com:CJPoll/custom.git'
run "$(bash_json_cwd "$TMP/custom_incident" 'git push -u origin hyprpaper-08-syntax')"
check "D1. captain's plain push of hyprpaper-08-syntax to CJPoll/custom -> deny" deny
check_text "D1a. the deny names the gh-athena push form" '~/dev/custom/ai/bin/gh-athena git'
if printf '%s' "$OUT" | grep -q '"additionalContext"'; then
  FAIL=$((FAIL + 1)); printf '  FAIL  %s out=[%s]\n' "D1b. no after-the-fact additionalContext-only warn" "$OUT"
else
  PASS=$((PASS + 1)); printf '  PASS  %s\n' "D1b. no after-the-fact additionalContext-only warn"
fi

run "$(bash_json_cwd "$TMP/norepo" "cd $TMP/custom_incident && git push -u origin HEAD")"
check "D2. admiral's cd <repo> && git push -u (first push of a PR branch) -> deny" deny

echo
echo "--- GitLab push cases (DND-393) ---"

run "$(bash_json_cwd "$TMP/gl" 'git push origin HEAD')"
check "G1. plain git push, origin git@gitlab.com: (cwd)" deny
check_text "G1a. gitlab push deny names gitlab.com" 'to a gitlab.com remote'
check_text "G1b. gitlab push deny points at glab-athena git" '~/dev/custom/ai/bin/glab-athena git push'
check_text "G1c. gitlab push deny carries the escalate Fix:" 'escalate to your admiral with the command + error and wait'

run "$(bash_json_cwd "$TMP/gl_https" 'git push')"
check_text "G2. plain git push, default remote -> https gitlab origin" 'to a gitlab.com remote'

run "$(bash_json_cwd "$TMP/norepo" "git -C $TMP/gl push -u origin HEAD")"
check_text "G3. git -C <gitlab repo> push -u from another dir" 'to a gitlab.com remote'

run "$(bash_json_cwd "$TMP/local" 'git push ssh://git@gitlab.com/g/r.git HEAD')"
check_text "G4. git push to a literal ssh://git@gitlab.com URL" 'to a gitlab.com remote'

run "$(bash_json_cwd "$TMP/gh_glpush" 'git push')"
check_text "G5. github fetch url but a gitlab.com pushurl" 'to a gitlab.com remote'

run "$(bash_json_cwd "$TMP/norepo" 'git push origin HEAD')"
check_text "G6. unresolvable remote names both forges' fixes" 'glab-athena git push'

run "$(bash_json_cwd "$TMP/gl" '~/dev/custom/ai/bin/glab-athena git push origin HEAD')"
check "G7. glab-athena git push (wrapper) -> allow" allow

run "$(bash_json_cwd "$TMP/gl" 'GIT_TERMINAL_PROMPT=0 ~/dev/custom/ai/bin/glab-athena git push -u origin HEAD && echo pushed')"
check "G8. the documented glab-athena push form -> allow" allow

echo
echo "--- DND-397: a wrapper invoked through a shell variable must not be denied ---"

run "$(bash_json_cwd "$TMP/gl" 'W=~/dev/custom/ai/bin/glab-athena; "$W" git push origin x')"
check "V1. W=glab-athena; \"\$W\" git push" allow

run "$(bash_json_cwd "$TMP/gh_scp" 'W=~/dev/custom/ai/bin/gh-athena; "$W" git push origin x')"
check "V2. W=gh-athena; \"\$W\" git push" allow

run "$(bash_json_cwd "$TMP/gh_scp" 'W=~/dev/custom/ai/bin/gh-athena; $W git push origin x')"
check "V3. unquoted \$W git push" allow

run "$(bash_json_cwd "$TMP/gl" 'W="$HOME/dev/custom/ai/bin/glab-athena" && GIT_TERMINAL_PROMPT=0 "${W}" git push -u origin x')"
check "V4. \${W} with a quoted \$HOME assignment" allow

run "$(bash_json_cwd "$TMP/gh_scp" 'export GHA=~/dev/custom/ai/bin/gh-athena; "$GHA" git -c credential.helper= push origin x')"
check "V5. export-assigned var, global options before push" allow

echo
echo "--- DND-397: a REAL plain push must still deny ---"

run "$(bash_json_cwd "$TMP/gh_scp" "bash -c 'git push origin HEAD'")"
check_text "R1. bash -c '<push>' still denies" 'to a github.com remote'

run "$(bash_json_cwd "$TMP/norepo" "sh -c \"cd $TMP/gh_scp && git push\"")"
check_text "R2. sh -c \"cd <gh repo> && git push\" still denies" 'to a github.com remote'

run "$(bash_json_cwd "$TMP/gh_scp" "$(printf "bash <<'EOF'\ngit push origin HEAD\nEOF")")"
check_text "R3. heredoc fed to bash still denies" 'to a github.com remote'

run "$(bash_json_cwd "$TMP/gh_scp" "$(printf "cat <<'EOF' | sh\ngit push origin HEAD\nEOF")")"
check_text "R4. heredoc piped into sh still denies" 'to a github.com remote'

run "$(bash_json_cwd "$TMP/gh_scp" "$(printf 'python3 - <<EOF\nx = \"$(git push origin HEAD)\"\nEOF')")"
check_text "R5. unquoted-delimiter heredoc whose body runs \$(git push) still denies" 'to a github.com remote'

run "$(bash_json_cwd "$TMP/gh_scp" 'echo "$(git push origin HEAD)"')"
check_text "R6. \$(git push) inside a double-quoted string still denies" 'to a github.com remote'

run "$(bash_json_cwd "$TMP/gh_scp" 'eval "git push origin HEAD"')"
check_text "R7. eval \"git push ...\" still denies" 'to a github.com remote'

run "$(bash_json_cwd "$TMP/gh_scp" "echo 'git push' ; git push origin HEAD")"
check_text "R8. a quoted mention AND a real push -> the real one denies" 'to a github.com remote'

run "$(bash_json_cwd "$TMP/gh_scp" "$(printf "cat > f <<'EOF'\ngit push\nEOF\ngit push origin HEAD")")"
check_text "R9. a real push AFTER a heredoc's terminator still denies" 'to a github.com remote'

run "$(bash_json_cwd "$TMP/gh_scp" 'git push "origin" HEAD')"
check_text "R10. a quoted one-word remote still resolves" 'to a github.com remote'

run "$(bash_json_cwd "$TMP/norepo" "git -C \"$TMP/gh_scp\" push origin HEAD")"
check_text "R11. a quoted -C dir still resolves" 'to a github.com remote'

run "$(bash_json_cwd "$TMP/gh_scp" 'W=~/dev/custom/ai/bin/gh-athena; git push origin HEAD')"
check_text "R12. a wrapper var is assigned but the push is plain -> denies" 'to a github.com remote'

run "$(bash_json_cwd "$TMP/gh_scp" 'X=~/dev/custom/ai/bin/gh-athena; "$W" git push origin HEAD')"
check_text "R13. \$W was never assigned a wrapper -> denies" 'to a github.com remote'

run "$(bash_json_cwd "$TMP/gh_scp" 'W=~/dev/custom/ai/bin/gh-athena; W=/usr/bin/env; "$W" git push origin HEAD')"
check_text "R14. \$W reassigned away from the wrapper -> denies" 'to a github.com remote'

run "$(bash_json_cwd "$TMP/gl" "zsh -c 'git push origin HEAD'")"
check_text "R15. zsh -c '<push>' to gitlab still denies" 'to a gitlab.com remote'

run "$(bash_json_cwd "$TMP/norepo" "$(printf "python3 - <<'EOF'\nprint(1)\nEOF\ngit push origin HEAD")")"
check_text "R16. unresolvable real push after a heredoc keeps DND-389's deny" 'could not resolve its remote'

run "$(bash_json_cwd "$TMP/gh_scp" "echo \"\$(bash -c 'git push origin HEAD')\"")"
check_text "R17. a shell nested inside \"\$(…)\" -> nothing masked, still denies" 'to a github.com remote'

run "$(bash_json_cwd "$TMP/gh_scp" "$(printf "git commit -m \"\$(cat <<'EOF'\nmsg\nEOF\n)\" && git push origin HEAD")")"
check_text "R18. a commit-message heredoc then a real push -> denies" 'to a github.com remote'

echo
echo "--- DND-397: a quoted command string run by any runner still denies ---"

run "$(bash_json_cwd "$TMP/gh_scp" '$SHELL -c "git push origin HEAD"')"
check_text "C1. \$SHELL -c \"<push>\"" 'to a github.com remote'

run "$(bash_json_cwd "$TMP/gh_scp" 'x=bash; $x -c "git push origin HEAD"')"
check_text "C2. x=bash; \$x -c \"<push>\"" 'to a github.com remote'

run "$(bash_json_cwd "$TMP/gh_scp" 'script -qc "git push origin HEAD" /dev/null')"
check_text "C3. script -qc \"<push>\"" 'to a github.com remote'

run "$(bash_json_cwd "$TMP/gh_scp" 'flock /tmp/l -c "git push origin HEAD"')"
check_text "C4. flock <lock> -c \"<push>\"" 'to a github.com remote'

run "$(bash_json_cwd "$TMP/gh_scp" 'tmux new-window "git push origin HEAD"')"
check_text "C5. tmux new-window \"<push>\"" 'to a github.com remote'

run "$(bash_json_cwd "$TMP/gh_scp" "node -e \"require('child_process').execSync('git push origin HEAD')\"")"
check_text "C6. an unlisted interpreter's code string (node -e)" 'to a github.com remote'

run "$(bash_json_cwd "$TMP/gh_scp" "$(printf "cat > s.sh <<'EOF'\ngit push origin HEAD\nEOF\nchmod +x s.sh && ./s.sh")")"
check_text "C7. heredoc writes a script, ./s.sh runs it" 'to a github.com remote'

run "$(bash_json_cwd "$TMP/gh_scp" "git -c 'alias.p=!git push origin HEAD' p")"
check_text "C8. git -c '<alias that pushes>' is never masked" 'to a github.com remote'

run "$(bash_json_cwd "$TMP/gh_scp" "echo 'git push origin HEAD' | at now")"
check_text "C9. echo '<push>' | at now" 'to a github.com remote'

run "$(bash_json_cwd "$TMP/gh_scp" 'env -S "git push origin HEAD"')"
check_text "C10. env -S \"<push>\"" 'to a github.com remote'

run "$(bash_json_cwd "$TMP/gh_scp" 'timeout 60 sudo -u me sh -c "git push origin HEAD"')"
check_text "C11. prefixes before a shell" 'to a github.com remote'

run "$(bash_json_cwd "$TMP/gh_scp" 'W=/usr/bin/env; "$W" git push origin HEAD; W=~/dev/custom/ai/bin/gh-athena')"
check_text "C12. a wrapper assigned AFTER the use does not bless it" 'to a github.com remote'

run "$(bash_json_cwd "$TMP/gh_scp" 'W=~/dev/custom/ai/bin/gh-athena; "$W" git push origin x; W=/usr/bin/env; "$W" git push origin HEAD')"
check_text "C13. same var: wrapper use, reassignment, plain use -> the plain one denies" 'to a github.com remote'

echo
echo "--- DND-397: text runners the parked mention-masking missed — must be denied ---"

run "$(bash_json_cwd "$TMP/gh_scp" 'git rebase --exec "git push origin HEAD" main')"
check_text "C14. git rebase --exec \"<push>\"" 'to a github.com remote'

run "$(bash_json_cwd "$TMP/gh_scp" 'git rebase -x "git push origin HEAD" main')"
check_text "C15. git rebase -x \"<push>\"" 'to a github.com remote'

run "$(bash_json_cwd "$TMP/gh_scp" 'git submodule foreach "git push origin HEAD"')"
check_text "C16. git submodule foreach \"<push>\"" 'to a github.com remote'

run "$(bash_json_cwd "$TMP/gh_scp" "$(printf "cat <<'EOF' | perl\nsystem(\"git push origin HEAD\")\nEOF")")"
check_text "C17. heredoc piped into perl" 'to a github.com remote'

run "$(bash_json_cwd "$TMP/gh_scp" "echo 'git push origin HEAD' | python3")"
check_text "C18. echo '<push>' | python3" 'to a github.com remote'

run "$(bash_json_cwd "$TMP/gh_scp" "echo 'git push origin HEAD' | awk '{system(\$0)}'")"
check_text "C19. echo '<push>' | awk system" 'to a github.com remote'

run "$(bash_json_cwd "$TMP/gh_scp" "echo 'git push origin HEAD' | sed e")"
check_text "C20. echo '<push>' | sed e" 'to a github.com remote'

run "$(bash_json_cwd "$TMP/gh_scp" "\$(echo 'git push origin HEAD')")"
check_text "C21. \$(echo '<push>') as the command word" 'to a github.com remote'

run "$(bash_json_cwd "$TMP/gh_scp" "\"\$(echo 'git push origin HEAD')\"")"
check_text "C22. \"\$(echo '<push>')\" as the command word" 'to a github.com remote'

run "$(bash_json_cwd "$TMP/gh_scp" "gh alias set --shell p 'git push origin HEAD' && gh p")"
check_text "C23. gh alias set --shell '<push>' (not a DATA subcommand)" 'to a github.com remote'

run "$(bash_json_cwd "$TMP/gh_scp" "git -C . -c 'alias.p=!git push origin HEAD' p")"
check_text "C24. git -C . -c '<alias>' (value before the subcommand)" 'to a github.com remote'

run "$(bash_json_cwd "$TMP/gh_scp" "grep -rn 'git push' . || sh -c 'git push origin HEAD'")"
check_text "C25. || then a shell still denies" 'to a github.com remote'

run "$(bash_json_cwd "$TMP/gh_scp" "git grep -O\"sh -c 'git push origin HEAD'\" x")"
check_text "C26. git grep -O\"<pager that pushes>\"" 'to a github.com remote'

run "$(bash_json_cwd "$TMP/gh_scp" "echo 'git push origin HEAD' > .git/hooks/post-commit && chmod +x .git/hooks/post-commit && git commit -qm x")"
check_text "C27. a hook written by echo, fired by git commit" 'to a github.com remote'

run "$(bash_json_cwd "$TMP/gh_scp" "python3 -c \"import os; os.system('git push origin HEAD')\"")"
check_text "C28. python3 -c running a push" 'to a github.com remote'

run "$(bash_json_cwd "$TMP/gh_scp" '(W=~/dev/custom/ai/bin/gh-athena); $W git push origin HEAD')"
check_text "C29. W set only in a subshell -> the later \$W git push is plain, denies" 'to a github.com remote'

run "$(bash_json_cwd "$TMP/gh_scp" 'W=~/dev/custom/ai/bin/gh-athena true; $W git push origin HEAD')"
check_text "C30. W as a command-prefix assignment does not persist -> denies" 'to a github.com remote'

run "$(bash_json_cwd "$TMP/gh_scp" 'W=~/dev/custom/ai/bin/gh-athena | cat; $W git push origin HEAD')"
check_text "C31. W set in a pipeline element does not persist -> denies" 'to a github.com remote'

run "$(bash_json_cwd "$TMP/gh_scp" 'X=$(W=~/dev/custom/ai/bin/gh-athena; echo); $W git push origin HEAD')"
check_text "C32. W set inside \$( … ) does not persist -> denies" 'to a github.com remote'

run "$(bash_json_cwd "$TMP/gh_scp" 'W=~/dev/custom/ai/bin/gh-athena && (cd . && "$W" git push origin x)')"
check "V6. only the next-statement shape is blessed; a use in a later subshell still denies" deny

run "$(bash_json_cwd "$TMP/gl" "$(printf 'W=~/dev/custom/ai/bin/glab-athena\n"$W" git push origin x')")"
check "V7. newline-separated W=glab-athena then \"\$W\" git push" allow

run "$(bash_json_cwd "$TMP/gh_scp" 'echo W=~/dev/custom/ai/bin/gh-athena; $W git push origin HEAD')"
check_text "C33. W=… as an echo ARGUMENT sets nothing -> denies" 'to a github.com remote'

run "$(bash_json_cwd "$TMP/gh_scp" 'false && W=~/dev/custom/ai/bin/gh-athena; $W git push origin HEAD')"
check_text "C34. a conditional assignment -> denies" 'to a github.com remote'

run "$(bash_json_cwd "$TMP/gh_scp" '(W=~/dev/custom/ai/bin/gh-athena; echo "("); $W git push origin HEAD')"
check_text "C35. subshell assignment with a quoted paren -> denies" 'to a github.com remote'

run "$(bash_json_cwd "$TMP/gh_scp" "W=~/dev/custom/ai/bin/gh-athena; bash -c '\$W git push origin HEAD'")"
check_text "C36. \$W used in a child shell where W is unset -> denies" 'to a github.com remote'

run "$(bash_json_cwd "$TMP/gh_scp" "W=\"\$HOME/dev/custom/ai/bin/gh-athena\" ; \"\$W\" git push origin x ; \$W git -C $TMP/gl push origin HEAD")"
if is_deny_with 'to a gitlab.com remote' && ! is_deny_with 'to a github.com remote'; then
  PASS=$((PASS + 1)); printf '  PASS  %s\n' "C37. the next statement's use is blessed (no github deny); a second use still denies (gitlab)"
else
  FAIL=$((FAIL + 1)); printf '  FAIL  %s status=%s out=[%s]\n' "C37. blessed first use, denied second use" "$STATUS" "$OUT"
fi

run "$(bash_json_cwd "$TMP/gh_scp" "W='~/dev/custom/ai/bin/gh-athena' ; \"\$W\" git push origin HEAD")"
check_text "C38. a single-quoted value (no ~ expansion) is not blessed -> denies" 'to a github.com remote'


run "$(bash_json_cwd "$TMP/gh_scp" "$(printf 'W=~/dev/custom/ai/bin/gh-athena\nW=/usr/bin/env\n"$W" git push origin HEAD')")"
check_text "C39. a reassignment on its own line is a statement, not a prefix -> denies" 'to a github.com remote'

run "$(bash_json_cwd "$TMP/gh_scp" "$(printf 'W=~/dev/custom/ai/bin/gh-athena; "$W"\ngit push origin HEAD')")"
check_text "C40. \"\$W\" then git push on the NEXT line is a plain push -> denies" 'to a github.com remote'

run "$(bash_json_cwd "$TMP/gh_scp" "$(printf 'export\nW=~/dev/custom/ai/bin/gh-athena; "$W" git push origin HEAD')")"
check_text "C41. export on its own line is not part of the assignment -> not blessed, denies" 'to a github.com remote'

run "$(bash_json_cwd "$TMP/gh_scp" "$(printf 'W=~/dev/custom/ai/bin/gh-athena\n\n  GIT_TERMINAL_PROMPT=0 "$W" git push origin x')")"
check "V8. blank line between the assignment and a prefixed use" allow

echo
echo "--- MUST-NOT-DENY cases (wrapper / reads / unrelated) ---"

run "$(bash_json_cwd "$TMP/gh_scp" '~/dev/custom/ai/bin/gh-athena git push origin HEAD')"
check "M7. gh-athena git push (wrapper)" allow

run "$(bash_json_cwd "$TMP/gh_scp" "GIT_TERMINAL_PROMPT=0 ~/dev/custom/ai/bin/gh-athena git -c credential.helper= -c 'url.https://github.com/.insteadOf=git@github.com:' push origin HEAD")"
check "M8. the documented explicit wrapper push form" allow

run "$(bash_json_cwd "$TMP/gl" 'git pull origin main')"
check "M9. git pull from a GitLab remote (not a push)" allow

run "$(bash_json_cwd "$TMP/local" 'git push origin HEAD')"
check "M10. plain git push to a local bare remote" allow

run "$(bash_json_cwd "$TMP/gh_scp" 'git commit -m "push to github.com later"')"
check "M11. git commit whose message says push github.com" allow

run "$(bash_json_cwd "$TMP/gh_scp" 'git log --grep push')"
check "M12. git log --grep push (not a push)" allow

run "$(bash_json_cwd "$TMP/gopath" 'git push origin HEAD')"
check "M13. push to a LOCAL path containing github.com (Go workspace) is not GitHub" allow

run "$(bash_json_cwd "$TMP/gl" 'git push origin fix/github.com-links')"
if is_deny && ! is_deny_with 'to a github.com remote'; then
  PASS=$((PASS + 1)); printf '  PASS  %s\n' "M14. GitLab push of a branch whose NAME mentions github.com -> gitlab deny only, never a github one"
else
  FAIL=$((FAIL + 1)); printf '  FAIL  %s status=%s out=[%s]\n' "M14. branch name mentioning github.com" "$STATUS" "$OUT"
fi

run "$(bash_json '~/dev/custom/ai/bin/gh-athena pr create --title x')"
check "M1. gh-athena pr create (wrapper)" allow

run "$(bash_json '~/dev/custom/ai/bin/gh-athena pr merge 5 --squash')"
check "M2. gh-athena pr merge (wrapper)" allow

run "$(bash_json '~/dev/custom/ai/bin/glab-athena mr create --fill')"
check "M3. glab-athena mr create (wrapper)" allow

run "$(bash_json '~/dev/custom/ai/bin/glab-athena mr merge 42')"
check "M4. glab-athena mr merge (wrapper)" allow

run "$(bash_json 'gh pr view 5')"
check "M5. gh pr view (read)" allow

run "$(bash_json 'gh pr list && glab mr list')"
check "M6. pr/mr list (reads)" allow

echo
echo "--- FAIL-OPEN cases (never wedge Bash) ---"

run ''
check "F1. empty stdin -> allow" allow

run 'not json'
check "F2. non-JSON stdin -> allow" allow

run '{"tool_name":"Bash","tool_input":'
check "F3. truncated JSON -> allow" allow

run '{"tool_name":"SendMessage","tool_input":{"message":"gh pr merge 5"}}'
check "F4. non-Bash tool with merge text -> allow" allow

echo
echo "==================================================="
printf 'RESULT: %d passed, %d failed\n' "$PASS" "$FAIL"
echo "==================================================="

[ "$FAIL" -eq 0 ] || exit 1
echo "ALL CASES PASS"
exit 0
