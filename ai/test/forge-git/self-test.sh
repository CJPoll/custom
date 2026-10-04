#!/usr/bin/env bash
# self-test for ai/bin/forge-git and the unattended harness paths that read a
# remote through it (DND-1977).
#
# Part A-C: forge-git's own routing. A github.com origin goes to gh-athena, a
# gitlab.com origin to glab-athena (git@ and https forms), any other forge form
# is refused with exit 3, a local path runs plain git, and the route follows
# the repository git itself reaches (a named remote, the branch's upstream, a
# URL).
#
# Part D: THE CLASS TEST. Each unattended path is run against a fixture whose
# origin is a forge URL, with a `git` first on PATH that records and FAILS any
# fetch / pull / ls-remote / push it is asked to run. The forge wrappers are
# replaced by stand-ins (forge-git's FORGE_GIT_GH_ATHENA / FORGE_GIT_GLAB_ATHENA
# seams) that record the call and fail as an unreachable forge would. A path
# passes only when its read reached a stand-in and plain git saw no network
# command: a path that still runs plain git against origin FAILS here.
#
# Part E: the same class, read from the source of the paths Part D cannot
# drive in isolation (integration-gate, the landing script, lead-time,
# leadtime_product_io's branch fetch): no line runs plain git's fetch, pull or
# ls-remote.
#
# Part F (DND-1995): ai/bin/forge-push, the push half. It asks forge-git for
# the route (forge-git --route), so there is one host table: github.com ->
# gh-athena git push, gitlab.com -> glab-athena git push, everything else
# (ssh://, a host alias, another host, a local path) refused with a Fix:.
# Part D also drives every unattended push (the landing / lane sync-up
# command, the lead-time product lane, wt under WT_AGENT_PUSH=1) against a
# github.com and a gitlab.com origin, and Part E scans the source for any
# push that runs plain git or names a wrapper by hand.
#
# Functional only (DND-1222): no timing, no load, no network, no token.
set -uo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT="$(cd -- "${HERE}/../../.." && pwd -P)"
FG="${ROOT}/ai/bin/forge-git"
FP="${ROOT}/ai/bin/forge-push"

pass=0; fail=0
ok()  { pass=$((pass + 1)); printf '  ok    %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf '  FAIL  %s\n' "$1"; [ -n "${2-}" ] && printf '%s\n' "$2" | sed 's/^/        /'; }

TMP="$(mktemp -d)"
trap 'rm -rf -- "${TMP}"' EXIT
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
export ATHENA_SECRETS_ROOT="${TMP}/secrets"

REAL_GIT="$(command -v git)"

# Forge wrapper stand-ins: record argv to ${TMP}/routed.log, exit STUB_RC
# (default 128, an unreachable forge).
STUBS="${TMP}/stubs"; mkdir -p "${STUBS}"
for w in gh-athena glab-athena; do
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "%s $*" >> "%s/routed.log"\nexit "${STUB_RC:-128}"\n' \
    "${w}" "${TMP}" > "${STUBS}/${w}"
  chmod +x "${STUBS}/${w}"
done
export FORGE_GIT_GH_ATHENA="${STUBS}/gh-athena" FORGE_GIT_GLAB_ATHENA="${STUBS}/glab-athena"

# A plain-git tripwire: first on PATH in Part D. A network subcommand is
# recorded to ${TMP}/plain.log and fails; everything else runs the real git.
TRIP="${TMP}/trip"; mkdir -p "${TRIP}"
cat > "${TRIP}/git" <<EOF
#!/usr/bin/env bash
args=("\$@"); i=0; sub=""
while [ \$i -lt \${#args[@]} ]; do
  a="\${args[\$i]}"
  case "\$a" in
    -C|-c|--git-dir|--work-tree|--namespace) i=\$((i + 2)); continue ;;
    -*) i=\$((i + 1)); continue ;;
    *) sub="\$a"; break ;;
  esac
done
case "\$sub" in
  fetch|pull|ls-remote|push|send-pack|fetch-pack|remote-https|clone)
    printf '%s\n' "git \$*" >> "${TMP}/plain.log"
    echo "fatal: plain git reached the network (test tripwire)" >&2
    exit 128 ;;
esac
exec "${REAL_GIT}" "\$@"
EOF
chmod +x "${TRIP}/git"
# The tripwire is a git stub on PATH: guard it (DND-1647/DND-1667). fsg_make,
# not fsg_arm, because the suite runs the real git for its fixtures. A
# missing or non-executable tripwire would let plain git reach origin.
. "${ROOT}/ai/lib/forge-stub-guard.sh"
fsg_make "${TMP}/git-guard" git
fsg_require_stubs "${TRIP}" git

reset_logs() { : > "${TMP}/routed.log"; : > "${TMP}/plain.log"; }

# mkrepo DIR URL -> a repo on main with one commit and origin=URL.
mkrepo() {
  git init -q -b main "$1"
  git -C "$1" commit -q --allow-empty -m seed
  git -C "$1" remote add origin "$2"
}

# ---------------------------------------------------------------------------
echo "A. routing table"
if out="$("${FG}" --help 2>/dev/null)" && grep -q '^Usage:' <<<"${out}"; then
  ok "--help prints usage on stdout, exit 0"
else
  bad "--help" "${out}"
fi

i=0
for case in \
  "git@github.com:CJPoll/custom.git|gh-athena" \
  "https://github.com/CJPoll/custom.git|gh-athena" \
  "git@gitlab.com:athena-ai-harness/custom.git|glab-athena" \
  "https://gitlab.com/athena-ai-harness/custom.git|glab-athena"; do
  i=$((i + 1)); url="${case%%|*}"; want="${case##*|}"
  r="${TMP}/route-${i}"; mkrepo "${r}" "${url}"; reset_logs
  STUB_RC=0 "${FG}" -C "${r}" fetch --quiet origin main >/dev/null 2>&1; rc=$?
  got="$(cat "${TMP}/routed.log")"
  if [ "${rc}" = 0 ] && [ "${got}" = "${want} git -C ${r} fetch --quiet origin main" ]; then
    ok "${url} routes through ${want}"
  else
    bad "${url} expected ${want}" "rc=${rc} routed=[${got}]"
  fi
done

r="${TMP}/route-fail"; mkrepo "${r}" "git@github.com:CJPoll/custom.git"; reset_logs
STUB_RC=7 "${FG}" -C "${r}" ls-remote origin >/dev/null 2>&1; rc=$?
[ "${rc}" = 7 ] && [ "$(wc -l < "${TMP}/routed.log")" = 1 ] \
  && ok "a failed routed read returns the wrapper's exit code, with no fallback attempt" \
  || bad "failed routed read" "rc=${rc} routed=[$(cat "${TMP}/routed.log")]"

r="${TMP}/route-case"; mkrepo "${r}" "git@GitHub.com:CJPoll/custom.git"; reset_logs
STUB_RC=0 "${FG}" -C "${r}" fetch origin >/dev/null 2>&1
[ "$(cat "${TMP}/routed.log")" = "gh-athena git -C ${r} fetch origin" ] \
  && ok "the host is matched case-insensitively (git@GitHub.com: routes through gh-athena)" \
  || bad "uppercase host" "routed=[$(cat "${TMP}/routed.log")]"

j=0
for url in "ssh://git@github.com/CJPoll/custom.git" "ssh://git@gitlab.com/athena-ai-harness/custom.git" "git@github.com-work:CJPoll/custom.git" \
           "gh:CJPoll/custom.git" "git@example.com:o/r.git" "https://example.com/o/r.git"; do
  j=$((j + 1)); r="${TMP}/refuse-${j}"; mkrepo "${r}" "${url}"; reset_logs
  err="$(PATH="${TRIP}:${FSG_DIR}:${PATH}" "${FG}" -C "${r}" fetch origin 2>&1 >/dev/null)"; rc=$?
  if [ "${rc}" = 3 ] && [ ! -s "${TMP}/routed.log" ] && [ ! -s "${TMP}/plain.log" ] && grep -q 'Fix:' <<<"${err}"; then
    ok "${url} is refused (exit 3, Fix:), no route and no plain-git attempt"
  else
    bad "${url} expected refusal" "rc=${rc} routed=[$(cat "${TMP}/routed.log")] plain=[$(cat "${TMP}/plain.log")] err=${err}"
  fi
done

bare="${TMP}/bare.git"; git init -q --bare "${bare}"
seed="${TMP}/seed"; mkrepo "${seed}" "${bare}"; git -C "${seed}" push -q origin main
r="${TMP}/local"; mkrepo "${r}" "${bare}"; reset_logs
"${FG}" -C "${r}" fetch --quiet origin >/dev/null 2>&1; rc=$?
[ "${rc}" = 0 ] && [ ! -s "${TMP}/routed.log" ] && git -C "${r}" rev-parse -q --verify refs/remotes/origin/main >/dev/null \
  && ok "a local-path origin fetches with plain git and calls no wrapper" \
  || bad "local-path origin" "rc=${rc} routed=[$(cat "${TMP}/routed.log")]"
reset_logs
"${FG}" -C "${r}" fetch --quiet "file://${bare}" main >/dev/null 2>&1; rc1=$?
"${FG}" -C "${r}" fetch --quiet ../bare.git main >/dev/null 2>&1; rc2=$?
[ "${rc1}" = 0 ] && [ "${rc2}" = 0 ] && [ ! -s "${TMP}/routed.log" ] \
  && ok "a file:// URL and a relative path are local too (plain git, no wrapper)" \
  || bad "file:// and relative path" "rc1=${rc1} rc2=${rc2} routed=[$(cat "${TMP}/routed.log")]"

# ---------------------------------------------------------------------------
echo "B. refusals and unresolvable keys (exit 64, never plain git)"
r="${TMP}/keys"; mkrepo "${r}" "git@gitlab.com:athena-ai-harness/custom.git"
expect64() { # expect64 <label> <args...>
  local label="$1"; shift; reset_logs
  err="$(PATH="${TRIP}:${FSG_DIR}:${PATH}" "${FG}" "$@" 2>&1 >/dev/null)"; rc=$?
  if [ "${rc}" = 64 ] && [ ! -s "${TMP}/routed.log" ] && [ ! -s "${TMP}/plain.log" ] && grep -q 'Fix:' <<<"${err}"; then
    ok "${label}"
  else
    bad "${label}" "rc=${rc} routed=[$(cat "${TMP}/routed.log")] plain=[$(cat "${TMP}/plain.log")] err=${err}"
  fi
}
expect64 "no -C is refused" fetch origin
expect64 "a non-repository -C is refused" -C "${TMP}/nowhere" fetch origin
expect64 "push is refused (pushes go through the wrappers)" -C "${r}" push origin main
expect64 "a local subcommand is refused" -C "${r}" status
expect64 "a word that is neither a remote nor a URL is refused" -C "${r}" fetch nosuchremote
expect64 "fetch --all is refused (several remotes, one route)" -C "${r}" fetch --all
expect64 "an option whose value is the next word is refused" -C "${r}" fetch --depth 1 origin
expect64 "an abbreviation of such an option is refused too (git accepts --dep 1)" -C "${r}" fetch --dep 1 origin
expect64 "a short option whose value is the next word is refused" -C "${r}" fetch -j 2 origin
nr="${TMP}/noremote"; git init -q -b main "${nr}"; git -C "${nr}" commit -q --allow-empty -m s
expect64 "a repo with no origin and no named remote is refused" -C "${nr}" fetch

# ---------------------------------------------------------------------------
echo "C. the route follows the repository git reaches"
r="${TMP}/two"; mkrepo "${r}" "git@gitlab.com:athena-ai-harness/custom.git"
git -C "${r}" remote add github "git@github.com:CJPoll/custom.git"
reset_logs; STUB_RC=0 "${FG}" -C "${r}" fetch -q github >/dev/null 2>&1
[ "$(cat "${TMP}/routed.log")" = "gh-athena git -C ${r} fetch -q github" ] \
  && ok "a named remote routes by its own URL (github beside a gitlab origin)" \
  || bad "named remote" "routed=[$(cat "${TMP}/routed.log")]"
git -C "${r}" config branch.main.remote github
reset_logs; STUB_RC=0 "${FG}" -C "${r}" pull --ff-only >/dev/null 2>&1
[ "$(cat "${TMP}/routed.log")" = "gh-athena git -C ${r} pull --ff-only" ] \
  && ok "with no repository named, the branch's upstream remote picks the route" \
  || bad "upstream remote" "routed=[$(cat "${TMP}/routed.log")]"
git -C "${r}" config --unset branch.main.remote
reset_logs; STUB_RC=0 "${FG}" -C "${r}" fetch --quiet >/dev/null 2>&1
[ "$(cat "${TMP}/routed.log")" = "glab-athena git -C ${r} fetch --quiet" ] \
  && ok "with no repository and no upstream, origin picks the route" \
  || bad "origin default" "routed=[$(cat "${TMP}/routed.log")]"
reset_logs; STUB_RC=0 "${FG}" -C "${r}" ls-remote https://github.com/CJPoll/custom.git refs/heads/main >/dev/null 2>&1
[ "$(cat "${TMP}/routed.log")" = "gh-athena git -C ${r} ls-remote https://github.com/CJPoll/custom.git refs/heads/main" ] \
  && ok "a URL named on the command line routes by that URL" \
  || bad "URL word" "routed=[$(cat "${TMP}/routed.log")]"

# ---------------------------------------------------------------------------
echo "F. forge-push: the push half, routed by forge-git's table (DND-1995)"
if out="$("${FP}" --help 2>/dev/null)" && grep -q '^Usage:' <<<"${out}"; then
  ok "forge-push --help prints usage on stdout, exit 0"
else
  bad "forge-push --help" "${out}"
fi

i=0
for case in \
  "git@github.com:CJPoll/custom.git|gh-athena" \
  "https://github.com/CJPoll/custom.git|gh-athena" \
  "git@gitlab.com:cjpoll/custom.git|glab-athena" \
  "https://gitlab.com/cjpoll/custom.git|glab-athena" \
  "git@GitLab.com:cjpoll/custom.git|glab-athena"; do
  i=$((i + 1)); url="${case%%|*}"; want="${case##*|}"
  r="${TMP}/push-${i}"; mkrepo "${r}" "${url}"; reset_logs
  STUB_RC=0 PATH="${TRIP}:${FSG_DIR}:${PATH}" "${FP}" -C "${r}" origin HEAD:main >/dev/null 2>&1; rc=$?
  got="$(cat "${TMP}/routed.log")"
  if [ "${rc}" = 0 ] && [ "${got}" = "${want} git -C ${r} push origin HEAD:main" ] && [ ! -s "${TMP}/plain.log" ]; then
    ok "push: ${url} routes through ${want}"
  else
    bad "push: ${url} expected ${want}" "rc=${rc} routed=[${got}] plain=[$(cat "${TMP}/plain.log")]"
  fi
done

r="${TMP}/push-fail"; mkrepo "${r}" "git@gitlab.com:cjpoll/custom.git"; reset_logs
STUB_RC=3 "${FP}" -C "${r}" origin HEAD:main >/dev/null 2>&1; rc=$?
[ "${rc}" = 3 ] && [ "$(wc -l < "${TMP}/routed.log")" = 1 ] \
  && ok "push: a wrapper refusal (exit 3: RED MAIN, NO RECEIPT, ...) is returned as is, with no fallback attempt" \
  || bad "push: wrapper refusal" "rc=${rc} routed=[$(cat "${TMP}/routed.log")]"

pbare="${TMP}/push-bare.git"; git init -q --bare "${pbare}"
j=0
for url in "ssh://git@github.com/CJPoll/custom.git" "ssh://git@gitlab.com/cjpoll/custom.git" "git@gitlab.com-work:cjpoll/custom.git" \
           "gh:CJPoll/custom.git" "git@example.com:o/r.git" "https://example.com/o/r.git" "${pbare}" "file://${pbare}"; do
  j=$((j + 1)); r="${TMP}/push-refuse-${j}"; mkrepo "${r}" "${url}"; reset_logs
  err="$(STUB_RC=0 PATH="${TRIP}:${FSG_DIR}:${PATH}" "${FP}" -C "${r}" origin HEAD:main 2>&1 >/dev/null)"; rc=$?
  if [ "${rc}" = 3 ] && [ ! -s "${TMP}/routed.log" ] && [ ! -s "${TMP}/plain.log" ] && grep -q 'Fix:' <<<"${err}" && grep -qF -- "${url}" <<<"${err}"; then
    ok "push: ${url} is refused (exit 3, Fix:, names the URL); no wrapper, no plain git"
  else
    bad "push: ${url} expected refusal" "rc=${rc} routed=[$(cat "${TMP}/routed.log")] plain=[$(cat "${TMP}/plain.log")] err=${err}"
  fi
done

r="${TMP}/push-keys"; mkrepo "${r}" "git@gitlab.com:cjpoll/custom.git"
expect64p() { # expect64p <label> <args...>
  local label="$1"; shift; reset_logs
  err="$(STUB_RC=0 PATH="${TRIP}:${FSG_DIR}:${PATH}" "${FP}" "$@" 2>&1 >/dev/null)"; rc=$?
  if [ "${rc}" = 64 ] && [ ! -s "${TMP}/routed.log" ] && [ ! -s "${TMP}/plain.log" ] && grep -q 'Fix:' <<<"${err}"; then
    ok "push: ${label}"
  else
    bad "push: ${label}" "rc=${rc} routed=[$(cat "${TMP}/routed.log")] plain=[$(cat "${TMP}/plain.log")] err=${err}"
  fi
}
expect64p "no -C is refused" origin HEAD:main
expect64p "a non-repository -C is refused" -C "${TMP}/nowhere" origin HEAD:main
expect64p "a leading 'push' word is refused (the arguments are git push's own)" -C "${r}" push origin HEAD:main
expect64p "--repo is refused (it names the remote apart from the routed word)" -C "${r}" --repo=git@github.com:o/r.git HEAD:main
expect64p "--repo as a separate word is refused" -C "${r}" --repo git@github.com:o/r.git HEAD:main
expect64p "an option git push does not have is refused" -C "${r}" --no-such-option origin HEAD:main
expect64p "an ambiguous abbreviation is refused (--re: --repo or --receive-pack)" -C "${r}" --re x origin HEAD:main
expect64p "a word that is neither a remote nor a URL is refused" -C "${r}" nosuchremote HEAD:main

# git's own grammar reads the remote (fg_push_argv): a value-taking option
# takes the next word, bundled (-fo <v>) or abbreviated (--e <v>, --push-opt
# <v>), so the routed remote is the one git pushes to. A github remote named
# beside a gitlab origin must route to gh-athena, never by the value word.
r="${TMP}/push-grammar"; mkrepo "${r}" "git@gitlab.com:cjpoll/custom.git"
git -C "${r}" remote add github "git@github.com:CJPoll/custom.git"
for args in "-o origin github HEAD:main" "-fo origin github HEAD:main" "-vfoorigin github HEAD:main" \
            "--push-opt origin github HEAD:main" "--e origin github HEAD:main" "-- github HEAD:main"; do
  reset_logs
  # shellcheck disable=SC2086
  STUB_RC=0 "${FP}" -C "${r}" ${args} >/dev/null 2>&1
  [ "$(cat "${TMP}/routed.log")" = "gh-athena git -C ${r} push ${args}" ] \
    && ok "push: '${args}' routes by the remote git reads (github), not the option's value" \
    || bad "push: grammar '${args}'" "routed=[$(cat "${TMP}/routed.log")]"
done

# A URL literal is routed after git's pushInsteadOf rewrite: a gitlab.com
# word that pushInsteadOf sends to github.com routes to gh-athena.
git -C "${r}" config url.git@github.com:.pushInsteadOf git@gitlab.com:
reset_logs; STUB_RC=0 "${FP}" -C "${r}" git@gitlab.com:cjpoll/custom.git HEAD:main >/dev/null 2>&1
[ "$(cat "${TMP}/routed.log")" = "gh-athena git -C ${r} push git@gitlab.com:cjpoll/custom.git HEAD:main" ] \
  && ok "push: a URL word routes by its pushInsteadOf rewrite (what git pushes to)" \
  || bad "push: pushInsteadOf URL word" "routed=[$(cat "${TMP}/routed.log")]"
git -C "${r}" config --unset url.git@github.com:.pushInsteadOf

# A forge-git that cannot compute the route is a failure to look (exit 64,
# naming it), never a refusal of the URL (exit 3).
cat > "${TMP}/fg-broken" <<'EOF'
#!/usr/bin/env bash
echo "forge-git: something broke" >&2
exit 64
EOF
chmod +x "${TMP}/fg-broken"
reset_logs; err="$(STUB_RC=0 FORGE_PUSH_FORGE_GIT="${TMP}/fg-broken" "${FP}" -C "${r}" origin HEAD:main 2>&1 >/dev/null)"; rc=$?
[ "${rc}" = 64 ] && [ ! -s "${TMP}/routed.log" ] && grep -q 'something broke' <<<"${err}" && grep -q 'could not be read' <<<"${err}" && grep -q 'Fix:' <<<"${err}" \
  && ok "push: a forge-git failure (exit 64) is reported as could-not-look with its message, never as a refused URL" \
  || bad "push: broken forge-git" "rc=${rc} routed=[$(cat "${TMP}/routed.log")] err=${err}"

r="${TMP}/push-url"; mkrepo "${r}" "git@github.com:CJPoll/custom.git"
git -C "${r}" remote set-url --push origin "git@gitlab.com:cjpoll/custom.git"
reset_logs; STUB_RC=0 "${FP}" -C "${r}" origin HEAD:main >/dev/null 2>&1
[ "$(cat "${TMP}/routed.log")" = "glab-athena git -C ${r} push origin HEAD:main" ] \
  && ok "push: a pushurl override routes by the URL the push really reaches (gitlab pushurl on a github url)" \
  || bad "push: pushurl" "routed=[$(cat "${TMP}/routed.log")]"
git -C "${r}" remote set-url --add --push origin "git@github.com:CJPoll/custom.git"
reset_logs; err="$(STUB_RC=0 "${FP}" -C "${r}" origin HEAD:main 2>&1 >/dev/null)"; rc=$?
[ "${rc}" = 3 ] && [ ! -s "${TMP}/routed.log" ] && grep -q 'two forges' <<<"${err}" && grep -q 'Fix:' <<<"${err}" \
  && ok "push: push URLs on two forges are refused (exit 3, Fix:), nothing pushed" \
  || bad "push: two forges" "rc=${rc} routed=[$(cat "${TMP}/routed.log")] err=${err}"

r="${TMP}/push-two"; mkrepo "${r}" "git@gitlab.com:cjpoll/custom.git"
git -C "${r}" remote add github "git@github.com:CJPoll/custom.git"
reset_logs; STUB_RC=0 "${FP}" -C "${r}" github HEAD:main >/dev/null 2>&1
[ "$(cat "${TMP}/routed.log")" = "gh-athena git -C ${r} push github HEAD:main" ] \
  && ok "push: a named remote routes by its own URL (github beside a gitlab origin)" \
  || bad "push: named remote" "routed=[$(cat "${TMP}/routed.log")]"
reset_logs; STUB_RC=0 "${FP}" -C "${r}" --force-with-lease=refs/heads/main:abc -u github HEAD >/dev/null 2>&1
[ "$(cat "${TMP}/routed.log")" = "gh-athena git -C ${r} push --force-with-lease=refs/heads/main:abc -u github HEAD" ] \
  && ok "push: options before the remote are skipped and passed through unchanged" \
  || bad "push: options" "routed=[$(cat "${TMP}/routed.log")]"
for cfg in "branch.main.pushRemote" "remote.pushDefault" "branch.main.remote"; do
  git -C "${r}" config "${cfg}" github
  reset_logs; STUB_RC=0 "${FP}" -C "${r}" >/dev/null 2>&1
  [ "$(cat "${TMP}/routed.log")" = "gh-athena git -C ${r} push" ] \
    && ok "push: with no remote named, ${cfg} picks the route" \
    || bad "push: ${cfg}" "routed=[$(cat "${TMP}/routed.log")]"
  git -C "${r}" config --unset "${cfg}"
done
reset_logs; STUB_RC=0 "${FP}" -C "${r}" >/dev/null 2>&1
[ "$(cat "${TMP}/routed.log")" = "glab-athena git -C ${r} push" ] \
  && ok "push: with no remote named and no push config, origin picks the route" \
  || bad "push: origin default" "routed=[$(cat "${TMP}/routed.log")]"

# One table: forge-push routes by what forge-git --route says, never a copy.
# A stand-in forge-git that routes EVERY URL to glab-athena must send a
# github.com push to glab-athena.
cat > "${TMP}/fg-glab" <<'EOF'
#!/usr/bin/env bash
[ "$1" = --route ] && { echo glab-athena; exit 0; }
exit 64
EOF
chmod +x "${TMP}/fg-glab"
r="${TMP}/push-1"
reset_logs; STUB_RC=0 FORGE_PUSH_FORGE_GIT="${TMP}/fg-glab" "${FP}" -C "${r}" origin HEAD:main >/dev/null 2>&1
[ "$(cat "${TMP}/routed.log")" = "glab-athena git -C ${r} push origin HEAD:main" ] \
  && ok "push: the route is forge-git's (--route), not a second table in forge-push" \
  || bad "push: one table" "routed=[$(cat "${TMP}/routed.log")]"
for u in "git@github.com:a/b.git" "https://gitlab.com/a/b.git" "/a/local/path"; do
  got="$("${FG}" --route "${u}" 2>/dev/null)"; rc=$?
  case "${u}" in git@github.com:*) w=gh-athena ;; https://gitlab.com/*) w=glab-athena ;; *) w=local ;; esac
  [ "${rc}" = 0 ] && [ "${got}" = "${w}" ] && ok "forge-git --route ${u} -> ${w}" || bad "forge-git --route ${u}" "rc=${rc} got=${got}"
done
err="$("${FG}" --route "ssh://git@github.com/a/b.git" 2>&1 >/dev/null)"; rc=$?
[ "${rc}" = 3 ] && grep -q 'Fix:' <<<"${err}" && ok "forge-git --route refuses ssh:// (exit 3, Fix:)" || bad "forge-git --route ssh://" "rc=${rc} err=${err}"

# ---------------------------------------------------------------------------
echo "D. unattended paths never reach a forge origin with plain git"
FX="${TMP}/fx"; mkrepo "${FX}" "git@github.com:example/widgets.git"
SHA="$(git -C "${FX}" rev-parse HEAD)"
git -C "${FX}" update-ref refs/remotes/origin/main "${SHA}"

# expect_routed <label> <want-substring> <cmd...>: run cmd with the tripwire
# first on PATH; pass when plain.log is empty and routed.log has the read.
expect_routed() {
  local label="$1" want="$2"; shift 2; reset_logs
  out="$(PATH="${TRIP}:${FSG_DIR}:${PATH}" "$@" 2>&1)"; rc=$?
  if [ ! -s "${TMP}/plain.log" ] && grep -qF -- "${want}" "${TMP}/routed.log"; then
    ok "${label}"
  else
    bad "${label}" "rc=${rc} plain=[$(cat "${TMP}/plain.log")] routed=[$(cat "${TMP}/routed.log")] out=$(printf '%s' "${out}" | tail -n 5)"
  fi
}

expect_routed "main-health check fetches origin through forge-git" \
  "gh-athena git -C ${FX} fetch -q origin" \
  "${ROOT}/ai/bin/main-health" check --repo "${FX}" --wait 5
expect_routed "confirm-merged --fetch fetches through forge-git" \
  "gh-athena git -C ${FX} fetch --quiet" \
  "${ROOT}/ai/bin/confirm-merged" --sha "${SHA}" --target origin/main --repo "${FX}" --fetch
expect_routed "Landed.remote_tip (harness-gate's landed bar) reads origin through forge-git" \
  "gh-athena git -C ${FX} ls-remote --exit-code origin refs/heads/main" \
  /usr/bin/ruby -I "${ROOT}/ai/lib" -e 'require "landed"; begin; Landed.remote_tip(ARGV[0], []); rescue Landed::Unreadable; end' "${FX}"
expect_routed "Landed.fetch_objects fetches through forge-git" \
  "gh-athena git -C ${FX} fetch --quiet --no-tags" \
  /usr/bin/ruby -I "${ROOT}/ai/lib" -e 'require "landed"; begin; Landed.fetch_objects(ARGV[0], "0" * 40, []); rescue Landed::Unreadable; end' "${FX}"
expect_routed "leadtime-product's fetch of main goes through forge-git" \
  "gh-athena git -C ${FX} fetch --quiet origin main" \
  /usr/bin/ruby -I "${ROOT}/ai/lib" -e 'require "leadtime_product_io"; LeadTimeProductIO::Git.fetch_main(ARGV[0])' "${FX}"
expect_routed "push-actor-check's ls-remote goes through forge-git" \
  "gh-athena git -C ${FX} ls-remote git@github.com:example/widgets.git refs/heads/main" \
  "${ROOT}/ai/bin/push-actor-check" --repo "${FX}" --sha "${SHA}" --window 1 main
expect_routed "wt-preflight's pull of the main checkout goes through forge-git" \
  "gh-athena git -C ${FX} pull --ff-only" \
  env HOME="${TMP}/home" "${ROOT}/scripts/wt-preflight" --repo "${FX}" --lock-retries 0 dnd-1977-probe
expect_routed "wt merge's pull, under WT_AGENT_PUSH=1, goes through forge-git" \
  "gh-athena git -C ${FX} pull origin main --ff-only" \
  bash -c 'cd "$1" && . "$2/scripts/wt-lib/push.sh" && WT_AGENT_PUSH=1 wt_git_pull origin main --ff-only' _ "${FX}" "${ROOT}"

# The push class (DND-1995): each unattended push, against a github.com and a
# gitlab.com origin, reaches the matching wrapper through forge-push.
FXL="${TMP}/fxl"; mkrepo "${FXL}" "git@gitlab.com:example/widgets.git"
for pair in "${FX}|gh-athena" "${FXL}|glab-athena"; do
  fx="${pair%%|*}"; w="${pair##*|}"
  expect_routed "landing / lane sync-up (forge-push -C <lane> origin HEAD:main) pushes through ${w}" \
    "${w} git -C ${fx} push origin HEAD:main" \
    env GIT_TERMINAL_PROMPT=0 "${FP}" -C "${fx}" origin HEAD:main
  expect_routed "leadtime-product's push (Forge.push) goes through ${w}" \
    "${w} git -C ${fx} push -u origin HEAD" \
    /usr/bin/ruby -I "${ROOT}/ai/lib" -e 'require "leadtime_product_io"; LeadTimeProductIO::Forge.push(ARGV[0], "-u", "origin", "HEAD")' "${fx}"
  expect_routed "wt's push, under WT_AGENT_PUSH=1, goes through ${w}" \
    "${w} git -C ${fx} push origin feat" \
    bash -c 'cd "$1" && . "$2/scripts/wt-lib/push.sh" && WT_AGENT_PUSH=1 wt_git_push origin feat' _ "${fx}" "${ROOT}"
done

# The owner's own wt use keeps plain git (attended; the owner's key is theirs).
reset_logs
PATH="${TRIP}:${FSG_DIR}:${PATH}" bash -c 'cd "$1" && . "$2/scripts/wt-lib/push.sh" && wt_git_pull origin main --ff-only' _ "${FX}" "${ROOT}" >/dev/null 2>&1
[ -s "${TMP}/plain.log" ] && [ ! -s "${TMP}/routed.log" ] \
  && ok "wt's owner path (no WT_AGENT_PUSH) still pulls with plain git" \
  || bad "wt owner path" "plain=[$(cat "${TMP}/plain.log")] routed=[$(cat "${TMP}/routed.log")]"


# ---------------------------------------------------------------------------
echo "E. no plain-git origin read anywhere in the harness source"
# The class, not a list: plain_git_scan.rb reads every tracked file under ai/,
# scripts/ and git-custom/ (its header says how, and what it cannot see). A hit
# must be one of these owner-run or fixture-only exceptions, each with its
# reason; a row that no longer matches is stale and fails too.
ALLOW="${TMP}/allow.tsv"
cat > "${ALLOW}" <<'EOF'
ai/bin/harness-gate	git.call("-C", root, "fetch", "-q", "origin")	self-test fixture: fetches a local bare origin it built
ai/bin/harness-gate	git.call("-C", fixture, "fetch", "-q", "origin")	self-test fixture: fetches a local bare origin it built
ai/bin/tool-propose	["git", "-C", "/repo", "fetch"]	a deny-list test vector; never run
ai/bin/forge-push	ls-remote --get-url	--get-url only expands the URL by config (insteadOf) and reaches no remote
scripts/athena-shipwright-run.sh	timeout 120 git -C "${dir}" fetch --quiet origin main ;;	the local-path branch of athena_fetch_origin_main; forge URLs route above it (scripts/test/runner-fetch-route)
scripts/athena-leadtime-run.sh	timeout 120 git -C "${dir}" fetch --quiet origin main ;;	the local-path branch of athena_fetch_origin_main; forge URLs route above it (scripts/test/runner-fetch-route)
scripts/mr-review	git fetch origin || {	the owner's interactive review tool; no agent runs it
scripts/pr-review	if ! git fetch origin; then	the owner's interactive review tool; no agent runs it
scripts/refresh-walt-dev	git pull --ff-only -q	the owner's walt_ui dev-stack refresh; no harness caller (its header says so)
scripts/wt-lib/push.sh	git pull "$@"	wt_git_pull's owner path (no WT_AGENT_PUSH); the agent path uses forge-git
ai/lib/glab-seed-mirror.sh	git ls-remote "$GSM_SRC_SEAM" refs/heads/main	a suite seam (GLAB_ATHENA_SEED_SOURCE_READ, honored only under GLAB_ATHENA_GIT_DRY_RUN=1) reading a fixture repo; the real source read runs gh-athena git ls-remote
ai/lib/glab-seed-mirror.sh	git ls-remote "$seam" refs/heads/main	a suite seam (GLAB_ATHENA_SEED_TARGET_READ, honored only under GLAB_ATHENA_GIT_DRY_RUN=1) reading a fixture repo; the real target read runs glab-athena git ls-remote
EOF
scan="$(/usr/bin/ruby "${HERE}/plain_git_scan.rb" "${ROOT}" "${ALLOW}" 2>&1)"; rc=$?
if [ "${rc}" -eq 0 ]; then
  ok "class scan: $(head -n 1 <<<"${scan}"); every plain-git read is an allowlisted owner-run or fixture one"
else
  bad "class scan (exit ${rc})" "${scan}"
fi

# The push class: no unattended path runs `git push` with plain git or names a
# forge wrapper for a push by hand; each push goes through ai/bin/forge-push.
PALLOW="${TMP}/push-allow.tsv"
cat > "${PALLOW}" <<'EOF'
ai/bin/admiral-eval	"git", "--version"	the eval sandbox's own self-test: its 3-line argv window reaches the blocked-push probe below
ai/bin/admiral-eval	"git", "push", "origin", "main"	the eval sandbox's self-test: asserts the sandbox BLOCKS this push
ai/bin/blast-radius	cgit.call("push", "-q", bare	self-test fixture: pushes PR head refs into a local bare repo it built
ai/bin/block-optimize	["git", "-C", s, "push"]	a deny-list test vector; never run
ai/bin/forge-push	exec "${WRAPPER}" git -C "${DIR}" push "$@"	forge-push itself: the one exec of the wrapper its route picked
ai/bin/harness-gate	git.call("-C", root, "push"	self-test fixture: pushes to a local bare origin it built
ai/bin/harness-gate	git.call("-C", other, "push"	self-test fixture: pushes to a local bare origin it built
ai/bin/harness-gate	git.call("-C", fixture, "push"	self-test fixture: pushes to a local bare origin it built
ai/bin/harness-gate	git.call("-C", f_other, "push"	self-test fixture: pushes to a local bare origin it built
ai/bin/tool-propose	["git", "-C", "/repo", "push"]	a deny-list test vector; never run
ai/bin/tool-propose	["git", "-C", a, "push"]	a deny-list test vector; never run
ai/bin/tool-propose	"--", "git", "push"]	a deny-list test vector; never run
scripts/gc	git push origin	the owner's interactive commit tool (gc --push); no agent runs it
scripts/iterate	git push	the owner's interactive iterate tool; no agent runs it
scripts/wt-lib/push.sh	git push "$@"	wt_git_push's owner path (no WT_AGENT_PUSH); the agent path uses forge-push
EOF
scan="$(/usr/bin/ruby "${HERE}/plain_git_scan.rb" "${ROOT}" "${PALLOW}" --push 2>&1)"; rc=$?
if [ "${rc}" -eq 0 ]; then
  ok "push class scan: $(head -n 1 <<<"${scan}"); no plain or hand-routed push outside the allowlisted owner-run and fixture ones"
else
  bad "push class scan (exit ${rc})" "${scan}"
fi

# The prose an agent follows for an unattended push (the custom landing, the
# lane sync-up) names forge-push, and no recipe pushes to main through a
# wrapper named by hand. The scan above cannot read prose (its header says so).
PROSE=(ai/skills/athena:merge-boarding/SKILL.md ai/skills/athena:shipwright-lane/SKILL.md ai/skills/athena:github/SKILL.md
       ai/skills/athena:gitlab/SKILL.md ai/skills/athena:lead-time-improve/SKILL.md)
hand="$(cd "${ROOT}" && grep -nE '(gh|glab)-athena git[^`]*push[^`]*:(refs/heads/)?main' "${PROSE[@]}" ai/agents/*.md.in ai/blocks -r 2>/dev/null)"
miss=""
for f in ai/skills/athena:merge-boarding/SKILL.md ai/skills/athena:shipwright-lane/SKILL.md; do
  grep -q 'forge-push -C' "${ROOT}/${f}" || miss="${miss} ${f}"
done
[ -z "${hand}" ] && [ -z "${miss}" ] \
  && ok "prose: the landing and sync-up recipes push through forge-push; none pushes to main through a wrapper named by hand" \
  || bad "prose push recipes" "hand-routed=[${hand}] missing forge-push in:[${miss}]"

# The scanner itself: it must SEE the shapes it claims to (a scan that finds
# nothing because it reads nothing passes vacuously).
SCAN_FX="${TMP}/scanfx"; mkdir -p "${SCAN_FX}/ai/bin" "${SCAN_FX}/ai/lib"
git init -q "${SCAN_FX}"
cat > "${SCAN_FX}/ai/bin/shellish" <<'EOF'
#!/usr/bin/env bash
timeout 120 git -C "${REPO}" fetch -q origin || die 3 "git fetch failed" "Fix: retry"
out="$(GIT_TERMINAL_PROMPT=0 git -c credential.helper= ls-remote origin)"
echo "Fix: run \`git fetch origin\` by hand"
"${FORGE_GIT}" -C "${REPO}" fetch -q origin
resolved="$(git ls-remote --get-url origin 2>/dev/null)"
u="$(git ls-remote --get-url origin)"; git fetch origin
git ls-remote --exit-code;printf -- --get-url
EOF
cat > "${SCAN_FX}/ai/lib/rubyish.rb" <<'EOF'
out, st = Open3.capture3("timeout", "120", "git", "-C", repo,
                         "ls-remote", "origin", "refs/heads/main")
_o, code = Git.call(dir, "fetch", "--quiet", "origin")
warn "Fix: `git fetch origin` then retry"
out, st = Open3.capture3(FORGE_GIT, "-C", repo,
                         "ls-remote", "origin")
EOF
git -C "${SCAN_FX}" add -A
: > "${TMP}/empty-allow.tsv"
scan="$(/usr/bin/ruby "${HERE}/plain_git_scan.rb" "${SCAN_FX}" "${TMP}/empty-allow.tsv" 2>&1)"; rc=$?
want="ai/bin/shellish:2: ai/bin/shellish:3: ai/bin/shellish:7: ai/bin/shellish:8: ai/lib/rubyish.rb:1: ai/lib/rubyish.rb:3:"
got="$(grep '^PLAIN' <<<"${scan}" | sed -E 's/^PLAIN ([^:]+:[0-9]+:).*/\1/' | tr '\n' ' ' | sed 's/ $//')"
[ "${rc}" -eq 1 ] && [ "${got}" = "${want}" ] \
  && ok "the scanner finds plain reads (one-liner with || die, env prefix and -c, a split Ruby argv, a helper call) and skips messages, forge-git and a local ls-remote --get-url" \
  || bad "scanner fixture" "rc=${rc} want=[${want}] got=[${got}] scan=${scan}"
cat > "${SCAN_FX}/ai/bin/pushish" <<'EOF'
#!/usr/bin/env bash
GIT_TERMINAL_PROMPT=0 "${HERE}/gh-athena" git -c credential.helper= push origin HEAD:main
git -C "${LANE}" push origin HEAD:main || die 3 "push failed" "Fix: retry"
echo "Fix: push with ~/dev/custom/ai/bin/gh-athena git push origin HEAD"
exec ~/dev/custom/ai/bin/glab-athena git -C "${D}" push -u origin HEAD
"${FORGE_PUSH}" -C "${LANE}" origin HEAD:main
if git -C "${LANE}" push origin HEAD:main; then :; fi
command git push origin HEAD
nice -n 19 git push origin HEAD
"${bin_dir}/${wrapper}" git push "$@"
"$GHA" git -c x=y push origin HEAD
EOF
cat > "${SCAN_FX}/ai/lib/pushish.rb" <<'EOF'
argv = [Cmd.forge_push, "-C", dir, "origin", "HEAD"]
def push_argv(*a)
  [Cmd.gh_athena, "git", "-c", "credential.helper=",
   "push", *a]
end
out, st = Open3.capture2e("git", "-C", dir, "push", "origin", "HEAD")
warn "Fix: `gh-athena git push origin HEAD` then retry"
EOF
git -C "${SCAN_FX}" add -A
scan="$(/usr/bin/ruby "${HERE}/plain_git_scan.rb" "${SCAN_FX}" "${TMP}/empty-allow.tsv" --push 2>&1)"; rc=$?
want="ai/bin/pushish:2: ai/bin/pushish:3: ai/bin/pushish:5: ai/bin/pushish:7: ai/bin/pushish:8: ai/bin/pushish:9: ai/bin/pushish:10: ai/bin/pushish:11: ai/lib/pushish.rb:3: ai/lib/pushish.rb:6:"
got="$(grep '^PLAIN' <<<"${scan}" | sed -E 's/^PLAIN ([^:]+:[0-9]+:).*/\1/' | tr '\n' ' ' | sed 's/ $//')"
[ "${rc}" -eq 1 ] && [ "${got}" = "${want}" ] \
  && ok "the push scanner finds a quoted wrapper path, a plain push with || die, an exec'd wrapper, if/command/nice forms, a wrapper held in a variable, a split Ruby argv naming the wrapper, a plain Ruby argv; skips messages and forge-push" \
  || bad "push scanner fixture" "rc=${rc} want=[${want}] got=[${got}] scan=${scan}"
if fsg_verify; then ok "no git call fell through past the tripwire (DND-1667)"
else bad "no git call fell through past the tripwire (DND-1667)" "see the forge-stub-guard FAIL above"; fi
echo
echo "${pass} passed, ${fail} failed"
[ "${fail}" -eq 0 ]
