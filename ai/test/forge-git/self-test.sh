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
# Functional only (DND-1222): no timing, no load, no network, no token.
set -uo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT="$(cd -- "${HERE}/../../.." && pwd -P)"
FG="${ROOT}/ai/bin/forge-git"

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
  "git@gitlab.com:cjpoll/custom.git|glab-athena" \
  "https://gitlab.com/cjpoll/custom.git|glab-athena"; do
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

j=0
for url in "ssh://git@github.com/CJPoll/custom.git" "ssh://git@gitlab.com/cjpoll/custom.git" "git@github.com-work:CJPoll/custom.git"; do
  j=$((j + 1)); r="${TMP}/refuse-${j}"; mkrepo "${r}" "${url}"; reset_logs
  err="$(PATH="${TRIP}:${PATH}" "${FG}" -C "${r}" fetch origin 2>&1 >/dev/null)"; rc=$?
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

# ---------------------------------------------------------------------------
echo "B. refusals and unresolvable keys (exit 64, never plain git)"
r="${TMP}/keys"; mkrepo "${r}" "git@gitlab.com:cjpoll/custom.git"
expect64() { # expect64 <label> <args...>
  local label="$1"; shift; reset_logs
  err="$(PATH="${TRIP}:${PATH}" "${FG}" "$@" 2>&1 >/dev/null)"; rc=$?
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
nr="${TMP}/noremote"; git init -q -b main "${nr}"; git -C "${nr}" commit -q --allow-empty -m s
expect64 "a repo with no origin and no named remote is refused" -C "${nr}" fetch

# ---------------------------------------------------------------------------
echo "C. the route follows the repository git reaches"
r="${TMP}/two"; mkrepo "${r}" "git@gitlab.com:cjpoll/custom.git"
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
echo "D. unattended paths never reach a forge origin with plain git"
FX="${TMP}/fx"; mkrepo "${FX}" "git@github.com:example/widgets.git"
SHA="$(git -C "${FX}" rev-parse HEAD)"
git -C "${FX}" update-ref refs/remotes/origin/main "${SHA}"

# expect_routed <label> <want-substring> <cmd...>: run cmd with the tripwire
# first on PATH; pass when plain.log is empty and routed.log has the read.
expect_routed() {
  local label="$1" want="$2"; shift 2; reset_logs
  out="$(PATH="${TRIP}:${PATH}" "$@" 2>&1)"; rc=$?
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

# The owner's own wt use keeps plain git (attended; the owner's key is theirs).
reset_logs
PATH="${TRIP}:${PATH}" bash -c 'cd "$1" && . "$2/scripts/wt-lib/push.sh" && wt_git_pull origin main --ff-only' _ "${FX}" "${ROOT}" >/dev/null 2>&1
[ -s "${TMP}/plain.log" ] && [ ! -s "${TMP}/routed.log" ] \
  && ok "wt's owner path (no WT_AGENT_PUSH) still pulls with plain git" \
  || bad "wt owner path" "plain=[$(cat "${TMP}/plain.log")] routed=[$(cat "${TMP}/routed.log")]"

# ---------------------------------------------------------------------------
echo "E. no plain-git origin read in the sources Part D does not drive"
# Shell: a git command word followed by fetch/pull/ls-remote. Ruby: an argv
# array or git helper call naming one. Comment lines and message text (a
# backtick, Fix:, die/warn/echo/note/printf/record) are skipped, and so is a
# line that runs forge-git itself (FORGE_GIT / forge_git).
SH_RE='(^|[;&|(!]|\$\(|then |do |timeout [0-9]+ )[[:space:]]*(LC_ALL=C[[:space:]]+)?git([[:space:]]+-C[[:space:]]+[^[:space:]]+)?([[:space:]]+-q|[[:space:]]+--quiet)?[[:space:]]+(fetch|pull|ls-remote)\b'
RB_RE='"git",[^]]*"(fetch|ls-remote|pull)"|\b(Git\.call|call|git_ok|git_status)\([^)]*"(fetch|ls-remote|pull)"'
MSG_RE='`|Fix|die |warn|echo |note |printf|record|raise|^[[:space:]]*#'
for f in \
  "ai/skills/athena:merge-boarding/scripts/integration-gate" \
  "ai/skills/athena:merge-boarding/scripts/locked-merge" \
  "ai/bin/lead-time" \
  "ai/lib/leadtime_product_io.rb" \
  "ai/bin/ready-and-idle" \
  "ai/bin/main-health" \
  "ai/bin/confirm-merged" \
  "ai/lib/landed.rb" \
  "ai/bin/push-actor-check" \
  "scripts/wt-preflight" \
  "scripts/wt-lib/merge.sh"; do
  [ -f "${ROOT}/${f}" ] || { bad "${f} is missing (the list is stale)"; continue; }
  hits="$(grep -nE -e "${SH_RE}" -e "${RB_RE}" "${ROOT}/${f}" | grep -vE -e "${MSG_RE}" | grep -viF forge_git || true)"
  if [ -z "${hits}" ]; then
    ok "${f}: no plain-git fetch/pull/ls-remote"
  else
    bad "${f}: plain-git origin read" "${hits}"
  fi
done

echo
echo "${pass} passed, ${fail} failed"
[ "${fail}" -eq 0 ]
