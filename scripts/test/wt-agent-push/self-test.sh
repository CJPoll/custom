#!/usr/bin/env bash
# Discovered self-test for wt's push routing (DND-394).
#
# wt pushes as the OWNER by default: that is the owner's interactive use and a
# human's push should be the human's. Only an explicit agent signal,
# WT_AGENT_PUSH=1, routes a push through the Athena forge wrapper for the
# remote's host (gh-athena git for github.com, glab-athena git for gitlab.com).
# Under the signal nothing ever falls back to a plain push, and a Graphite
# `gt submit` (which pushes with the owner's credentials) is refused.
#
# Hermetic: no network. A `git` shim on PATH records every `git push` (and only
# passes it to real git when a case asks for it, against a local bare remote);
# the wrappers are stubs in a temp dir that WT_ATHENA_BIN_DIR points at; `gt`
# is a stub that records its argv.
#
# Exit 0 iff every case passes.
set -uo pipefail

here="$(cd -- "$(dirname -- "$0")" && pwd -P)"
scripts_dir="$(cd -- "${here}/../.." && pwd -P)"
lib="${scripts_dir}/wt-lib"
real_git="$(command -v git)"

fails=0
passes=0
pass() { echo "PASS $1"; passes=$((passes+1)); }
fail() { echo "FAIL $1"; fails=$((fails+1)); }

tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT

# Keep the owner's global/system git config (url rewrites, helpers, hooks) out.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 GIT_TERMINAL_PROMPT=0
unset WT_AGENT_PUSH

# --- fixtures ----------------------------------------------------------------
shim="${tmp}/shim"; stubs="${tmp}/stubs"; mkdir -p "${shim}" "${stubs}"
log="${tmp}/calls.log"

cat > "${shim}/git" <<EOF
#!/usr/bin/env bash
# git shim: record a push; pass through to real git only when asked.
for a in "\$@"; do
  case "\$a" in
    push) echo "git \$*" >> "${log}"
          [ "\${SHIM_REAL_PUSH:-0}" = 1 ] && exec "${real_git}" "\$@"
          exit "\${SHIM_PUSH_RC:-0}" ;;
    -*) continue ;;
    *) break ;;
  esac
done
exec "${real_git}" "\$@"
EOF

for w in gh-athena glab-athena; do
  cat > "${stubs}/${w}" <<EOF
#!/usr/bin/env bash
echo "${w} \$* GTP=\${GIT_TERMINAL_PROMPT:-unset}" >> "${log}"
if [ "\${STUB_RC:-0}" = 3 ]; then
  echo "${w}: REFUSING (stub). Fix: escalate to your admiral." >&2
fi
exit "\${STUB_RC:-0}"
EOF
done

cat > "${shim}/gt" <<EOF
#!/usr/bin/env bash
echo "gt \$*" >> "${log}"
exit 0
EOF
chmod +x "${shim}/git" "${shim}/gt" "${stubs}/gh-athena" "${stubs}/glab-athena"

# make_repo <dir> <origin-url> : a repo on branch feat with one commit.
make_repo() {
  "${real_git}" init -q -b main "$1"
  "${real_git}" -C "$1" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
  "${real_git}" -C "$1" checkout -q -b feat
  [ -n "$2" ] && "${real_git}" -C "$1" remote add origin "$2"
  return 0
}

# in_wt <repo> <env...> -- <bash snippet> : source wt's pr.sh + merge.sh from
# inside <repo> with the shim on PATH, run the snippet, and print its exit code
# on the last line of stdout. get_worktree_dir is stubbed to <repo>.
in_wt() {
  local repo="$1"; shift
  local -a envs=()
  while [ "$1" != -- ]; do envs+=("$1"); shift; done
  shift
  : > "${log}"
  ( cd "${repo}" && env PATH="${shim}:${PATH}" WT_ATHENA_BIN_DIR="${stubs}" "${envs[@]}" \
      bash -c '
        source "'"${lib}"'/pr.sh"
        source "'"${lib}"'/merge.sh"
        get_worktree_dir() { pwd; }
        ( '"$1"' )
        echo "rc=$?"
      ' 2>"${tmp}/stderr" )
}

has() { grep -qF -- "$2" <<<"$1"; }
logged() { grep -qF -- "$1" "${log}"; }
# plain_pushed : the git shim recorded a push (a plain, owner-credential push).
plain_pushed() { grep -q '^git ' "${log}"; }
# any_push : anything pushed at all, plain or through a wrapper.
any_push() { grep -q 'push' "${log}"; }

gh_url="git@github.com:owner/repo.git"
gl_url="https://gitlab.com/owner/repo.git"

# --- 1. owner path, local remote: a real plain push, no wrapper ---------------
"${real_git}" init -q --bare "${tmp}/bare.git"
make_repo "${tmp}/r1" "${tmp}/bare.git"
out="$(in_wt "${tmp}/r1" SHIM_REAL_PUSH=1 -- 'push_branch feat false')"
if has "$out" "rc=0" && logged "git push origin feat" && ! logged "athena" \
   && [ "$("${real_git}" -C "${tmp}/bare.git" rev-parse feat 2>/dev/null)" = "$("${real_git}" -C "${tmp}/r1" rev-parse feat)" ]; then
  pass "owner (no signal): push_branch runs the plain push and the remote gets the ref"
else fail "owner (no signal): plain push to local remote [$out] log=[$(cat "${log}")]"; fi

# --- 2. owner path, github remote: plain push, never the wrapper --------------
make_repo "${tmp}/r2" "${gh_url}"
out="$(in_wt "${tmp}/r2" -- 'push_branch feat true')"
if has "$out" "rc=0" && logged "git push --force-with-lease origin feat" && ! logged "athena"; then
  pass "owner (no signal): github.com force push is the plain git push, argv unchanged"
else fail "owner (no signal): github.com force push [$out] log=[$(cat "${log}")]"; fi

# --- 3. WT_AGENT_PUSH=0 is the owner path -----------------------------------
out="$(in_wt "${tmp}/r2" WT_AGENT_PUSH=0 -- 'push_branch feat false')"
if has "$out" "rc=0" && logged "git push origin feat" && ! logged "athena"; then
  pass "WT_AGENT_PUSH=0: owner path"
else fail "WT_AGENT_PUSH=0 [$out] log=[$(cat "${log}")]"; fi

# --- 4. agent, github.com (scp form): through gh-athena, no plain push --------
out="$(in_wt "${tmp}/r2" WT_AGENT_PUSH=1 -- 'push_branch feat false')"
if has "$out" "rc=0" && logged "gh-athena git push origin feat GTP=0" && ! plain_pushed; then
  pass "agent: github.com (git@) push goes through gh-athena git, prompt disabled"
else fail "agent: github.com push via gh-athena [$out] log=[$(cat "${log}")]"; fi

# --- 5. agent, github.com (https form), force-with-lease ----------------------
make_repo "${tmp}/r5" "https://github.com/owner/repo.git"
out="$(in_wt "${tmp}/r5" WT_AGENT_PUSH=1 -- 'push_branch feat true')"
if has "$out" "rc=0" && logged "gh-athena git push --force-with-lease origin feat GTP=0" && ! plain_pushed; then
  pass "agent: github.com (https) force-with-lease goes through gh-athena git"
else fail "agent: github.com https force [$out] log=[$(cat "${log}")]"; fi

# --- 6. agent, gitlab.com: through glab-athena --------------------------------
make_repo "${tmp}/r6" "${gl_url}"
out="$(in_wt "${tmp}/r6" WT_AGENT_PUSH=1 -- 'push_branch feat false')"
if has "$out" "rc=0" && logged "glab-athena git push origin feat GTP=0" && ! plain_pushed && ! logged "gh-athena"; then
  pass "agent: gitlab.com push goes through glab-athena git"
else fail "agent: gitlab.com push via glab-athena [$out] log=[$(cat "${log}")]"; fi

# --- 7. agent, wrapper refusal: loud failure, never a plain push --------------
out="$(in_wt "${tmp}/r2" WT_AGENT_PUSH=1 STUB_RC=3 -- 'wt_git_push origin feat')"
err="$(cat "${tmp}/stderr")"
if has "$out" "rc=3" && logged "gh-athena git push origin feat" && ! plain_pushed \
   && has "$err" "Fix:" && has "$err" "REFUSING"; then
  pass "agent: a wrapper refusal fails loudly (exit 3, Fix:) with no plain-push fallback"
else fail "agent: wrapper refusal [$out] err=[$err] log=[$(cat "${log}")]"; fi

out="$(in_wt "${tmp}/r2" WT_AGENT_PUSH=1 STUB_RC=3 -- 'push_branch feat false')"
if ! has "$out" "rc=0" && ! plain_pushed; then
  pass "agent: push_branch after a refusal does not fall back to a plain push"
else fail "agent: push_branch refusal fallback [$out] log=[$(cat "${log}")]"; fi

# --- 8. agent, a remote no wrapper covers: refused, nothing pushed ------------
out="$(in_wt "${tmp}/r1" WT_AGENT_PUSH=1 -- 'wt_git_push origin feat')"
err="$(cat "${tmp}/stderr")"
if has "$out" "rc=3" && ! any_push && has "$err" "Fix:" && has "$err" "${tmp}/bare.git"; then
  pass "agent: a local/unknown-host remote is refused (exit 3, Fix:, names the URL), nothing pushed"
else fail "agent: unknown host [$out] err=[$err] log=[$(cat "${log}")]"; fi

make_repo "${tmp}/r8" "git@bitbucket.org:owner/repo.git"
out="$(in_wt "${tmp}/r8" WT_AGENT_PUSH=1 -- 'wt_git_push origin feat')"
if has "$out" "rc=3" && ! any_push; then
  pass "agent: a bitbucket.org remote is refused, nothing pushed"
else fail "agent: bitbucket [$out] log=[$(cat "${log}")]"; fi

# --- 9. agent, remote that does not resolve: an error, not an empty result ----
out="$(in_wt "${tmp}/r2" WT_AGENT_PUSH=1 -- 'wt_git_push nosuchremote feat')"
err="$(cat "${tmp}/stderr")"
if has "$out" "rc=3" && ! any_push && has "$err" "nosuchremote" && has "$err" "Fix:"; then
  pass "agent: an unresolvable remote is refused, naming the remote"
else fail "agent: unresolvable remote [$out] err=[$err] log=[$(cat "${log}")]"; fi

# --- 10. a malformed signal value is refused, not guessed ---------------------
out="$(in_wt "${tmp}/r2" WT_AGENT_PUSH=yes -- 'wt_git_push origin feat')"
err="$(cat "${tmp}/stderr")"
if has "$out" "rc=3" && ! any_push && has "$err" "WT_AGENT_PUSH" && has "$err" "Fix:"; then
  pass "WT_AGENT_PUSH=yes (malformed) is refused, nothing pushed"
else fail "malformed signal [$out] err=[$err] log=[$(cat "${log}")]"; fi

# --- 11. a missing wrapper is refused, not bypassed ---------------------------
out="$(cd "${tmp}/r2" && : > "${log}" && env PATH="${shim}:${PATH}" WT_ATHENA_BIN_DIR="${tmp}/empty" WT_AGENT_PUSH=1 \
  bash -c 'source "'"${lib}"'/pr.sh"; ( wt_git_push origin feat ); echo "rc=$?"' 2>"${tmp}/stderr")"
err="$(cat "${tmp}/stderr")"
if has "$out" "rc=3" && ! any_push && has "$err" "Fix:"; then
  pass "agent: a missing wrapper is refused, nothing pushed"
else fail "agent: missing wrapper [$out] err=[$err] log=[$(cat "${log}")]"; fi

# --- 12. merge's remote-branch delete follows the same routing ----------------
out="$(in_wt "${tmp}/r2" -- 'wt_delete_remote_branch feat')"
if has "$out" "rc=0" && logged "git push origin --delete feat" && ! logged "athena"; then
  pass "owner (no signal): merge's remote-branch delete is the plain push"
else fail "owner: merge delete [$out] log=[$(cat "${log}")]"; fi

out="$(in_wt "${tmp}/r2" WT_AGENT_PUSH=1 -- 'wt_delete_remote_branch feat')"
if has "$out" "rc=0" && logged "gh-athena git push origin --delete feat" && ! plain_pushed; then
  pass "agent: merge's remote-branch delete goes through gh-athena git"
else fail "agent: merge delete [$out] log=[$(cat "${log}")]"; fi

out="$(in_wt "${tmp}/r2" WT_AGENT_PUSH=1 STUB_RC=3 -- 'wt_delete_remote_branch feat')"
err="$(cat "${tmp}/stderr")"
if has "$out" "rc=3" && ! plain_pushed && has "$err" "Fix:"; then
  pass "agent: a refused remote-branch delete fails loudly (not the owner path's quiet best-effort)"
else fail "agent: merge delete refusal [$out] err=[$err] log=[$(cat "${log}")]"; fi

# --- 13. Graphite submits push with the owner's credentials: refused as agent -
for fn in 'create_stack_prs false' 'push_stack false' 'push_stack true' 'create_pr false'; do
  out="$(in_wt "${tmp}/r2" WT_AGENT_PUSH=1 -- "${fn}")"
  err="$(cat "${tmp}/stderr")"
  if ! has "$out" "rc=0" && ! logged "gt " && ! any_push && has "$err" "Fix:"; then
    pass "agent: ${fn} is refused before any gt call"
  else fail "agent: ${fn} [$out] err=[$err] log=[$(cat "${log}")]"; fi
done

out="$(cd "${tmp}/r2" && : > "${log}" && env PATH="${shim}:${PATH}" WT_AGENT_PUSH=1 \
  "${scripts_dir}/wt-subcommands/wt-stack" push 2>"${tmp}/stderr"; echo "rc=$?")"
err="$(cat "${tmp}/stderr")"
if ! has "$out" "rc=0" && ! logged "gt " && has "$err" "Fix:"; then
  pass "agent: wt stack push is refused before gt submit"
else fail "agent: wt stack push [$out] err=[$err] log=[$(cat "${log}")]"; fi

out="$(cd "${tmp}/r2" && : > "${log}" && env PATH="${shim}:${PATH}" \
  "${scripts_dir}/wt-subcommands/wt-stack" push 2>"${tmp}/stderr"; echo "rc=$?")"
if has "$out" "rc=0" && logged "gt submit --stack --no-interactive"; then
  pass "owner (no signal): wt stack push still runs gt submit"
else fail "owner: wt stack push [$out] log=[$(cat "${log}")]"; fi

# --- 13b. the refusal and the docs name the ONLY agent stack path (DND-399) ---
# Graphite has no Athena route: `gt submit` needs the owner's stored Graphite
# token and api.graphite.dev opens the PRs as the owner. So an agent stacks
# with plain branches, each pushed through the wrapper, and opens each PR with
# `gh-athena pr create --base <parent-branch>`. The refusal's Fix: and every
# doc an agent reads must say exactly that.
out="$(in_wt "${tmp}/r2" WT_AGENT_PUSH=1 -- 'push_stack false')"
err="$(cat "${tmp}/stderr")"
if has "$err" "Fix:" && has "$err" "gh-athena pr create --base <parent-branch>" \
   && has "$err" "no Athena route"; then
  pass "agent: the gt refusal's Fix: names the plain-branch + gh-athena pr create --base path"
else fail "agent: gt refusal Fix: text [$err]"; fi

wt_help="$("${scripts_dir}/wt" --help 2>&1)"
stack_help="$("${scripts_dir}/wt-subcommands/wt-stack" --help 2>&1)"
gh_skill="${scripts_dir}/../ai/skills/athena:github/SKILL.md"
for pair in "wt --help|${wt_help}" "wt stack --help|${stack_help}" \
            "athena:github SKILL.md|$(cat "${gh_skill}" 2>/dev/null)"; do
  name="${pair%%|*}"; text="${pair#*|}"
  if has "$text" "gh-athena pr create --base" && has "$text" "no Athena route"; then
    pass "docs: ${name} names the agent stack path (no Athena route for Graphite)"
  else fail "docs: ${name} does not name the agent stack path"; fi
done

# --- 14. no push site bypasses the helper ------------------------------------
# Every `git push` in wt lives in push.sh. A new raw push elsewhere would push
# as the owner even under the agent signal.
raw="$(grep -rnE '(^|[^_[:alnum:]-])git([[:space:]]+-[^[:space:]]+)*[[:space:]]+push([[:space:]]|$)' \
  "${scripts_dir}/wt" "${scripts_dir}/wt-lib" "${scripts_dir}/wt-subcommands" \
  | grep -v "^${lib}/push.sh:" | grep -vE ':[0-9]+:[[:space:]]*#' || true)"
if [ -z "$raw" ]; then
  pass "no raw \`git push\` in wt outside wt-lib/push.sh"
else fail "raw git push outside push.sh: ${raw}"; fi

echo "wt-agent-push: ${passes} passed, ${fails} failed"
[ "${fails}" -eq 0 ]
