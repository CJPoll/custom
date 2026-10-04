#!/usr/bin/env bash
# Self-test for gh-athena's outbound scan (DND-699, design QA case 11).
#
# The defect this pins: a PR or issue body bound for a PUBLIC repository went
# out through `gh-athena` with a work-domain value in it, and nothing said so.
# Now the title/body/body-file of pr/issue writes to a PUBLIC target is scanned
# by ai/bin/outbound-scan before gh runs.
#
# DND-1976: the argv is read the way gh's pflag reads it, with the pinned flag
# table. Before that, an unknown flag swallowed the next flag word
# (`pr create -l -t -b X`: gh sends body X, the guard read `-t` as the title)
# and X went out unscanned. The DND-1976 sections pin that, and the sweep to
# the pr/issue aliases and release text.
#
# Hermetic: a stub gh on PATH (it records every call; `repo view` answers the
# visibility from a fixture), the App token from a fixture cache (no mint, no
# network), a fixture overlay under mktemp -d with synthetic patterns, a fake
# HOME. The "marked machine" cases run a COPY of ai/bin + ai/lib inside a
# fixture repo whose .git/hooks/pre-push is a fixture: no real hook is read or
# installed.
#
# Run another copy of the wrapper (old-vs-new evidence) with
#   GH_ATHENA_UNDER_TEST=/path/to/gh-athena bash ai/test/gh-athena-outbound/self-test.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
AI_DIR="$(cd "${HERE}/../.." && pwd -P)"
WRAPPER="${GH_ATHENA_UNDER_TEST:-${AI_DIR}/bin/gh-athena}"

TMP="$(mktemp -d)" || { echo "FAIL: mktemp"; exit 1; }
trap 'rm -rf "${TMP}"' EXIT INT TERM
PASS=0; FAIL=0
ok()  { printf '  ok    %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  FAIL  %s\n        %s\n' "$1" "$2"; FAIL=$((FAIL+1)); }

TOKEN="SYNTH-TOKEN-1"

# ---- hermetic environment ---------------------------------------------------
for v in $(env | sed -n 's/^\(GIT_CONFIG_\(KEY\|VALUE\)_[0-9]*\)=.*/\1/p'); do unset "$v"; done
unset GIT_CONFIG_COUNT GIT_CONFIG_PARAMETERS GIT_DIR GIT_WORK_TREE ATHENA_OUTBOUND_WAIVE \
  GH_ATHENA_MERGE_DRY_RUN GH_REPO XDG_STATE_HOME
export HOME="${TMP}/home"; mkdir -p "${HOME}"
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL="${TMP}/gitconfig"
printf '[user]\n\tname = t\n\temail = t@t\n[init]\n\tdefaultBranch = main\n' > "${GIT_CONFIG_GLOBAL}"

FAKE_TOKEN="ghs_SELFTESTFAKETOKEN0000"
printf '12345\n' > "${TMP}/app-id"
printf 'not-a-key\n' > "${TMP}/key.pem"
printf '%s\t%s\n' "${FAKE_TOKEN}" "$(( $(date +%s) + 86400 ))" > "${TMP}/token-cache"
chmod 600 "${TMP}/token-cache"
export GH_ATHENA_APP_ID_FILE="${TMP}/app-id" GH_ATHENA_KEY="${TMP}/key.pem" GH_ATHENA_TOKEN_CACHE="${TMP}/token-cache"

mkdir -p "${TMP}/bin"
export STUB_LOG="${TMP}/calls.log" STUB_VIS="${TMP}/visibility"
cat > "${TMP}/bin/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${STUB_LOG}"
case "$*" in
  "repo view"*"--json visibility"*)
    # A per-repo fixture (visibility.<owner>_<repo>) wins over the default.
    if [ "$3" != "--json" ]; then
      f="${STUB_VIS}.$(printf '%s' "$3" | tr '/' '_')"
      if [ -s "$f" ]; then cat "$f"; exit 0; fi
    fi
    if [ -s "${STUB_VIS}" ]; then cat "${STUB_VIS}"; exit 0; fi
    echo "stub: no visibility" >&2; exit 1 ;;
  "alias list"*) exit 0 ;;
  # DND-2007: the merge guard now runs before the scan, so a `pr merge` reaches
  # the scan only past the guard. These answer its reads for one PR whose head
  # is green on a base tip that is the WORK checkout's own commit (no gate).
  "pr view"*"--json number,url,baseRefName,headRefOid"*)
    printf '{"number":5,"url":"https://github.com/synth-owner/pub/pull/5","baseRefName":"main","headRefOid":"%s"}\n' "${STUB_HEAD}"; exit 0 ;;
  "api graphql"*"statusCheckRollup"*)
    if [[ "$*" == *"oid=${STUB_TIP}"* ]]; then
      echo '{"data":{"repository":{"object":{"__typename":"Commit","statusCheckRollup":null}}}}'
    else
      echo '{"data":{"repository":{"object":{"__typename":"Commit","statusCheckRollup":{"contexts":{"totalCount":1,"pageInfo":{"hasNextPage":false},"nodes":[{"__typename":"CheckRun","name":"Build","status":"COMPLETED","conclusion":"SUCCESS"}]}}}}}}'
    fi
    exit 0 ;;
  "api repos/"*"/git/ref/heads/"*)
    printf '{"ref":"refs/heads/main","object":{"sha":"%s","type":"commit"}}\n' "${STUB_TIP}"; exit 0 ;;
  "pr merge"*) echo "stub: SENT pr merge"; exit 0 ;;
  # DND-2007: an api call is a send. An --input file's content is echoed the
  # way gh would read it, so a replaced stdin body is observable.
  "api "*)
    prev=""; for a in "$@"; do
      case "$prev" in --input) printf 'stub-body:'; cat "$a" ;; esac
      case "$a" in --input=*) printf 'stub-body:'; cat "${a#--input=}" ;; esac
      prev="$a"
    done
    echo "stub: SENT api"; exit 0 ;;
  "pr create"*|"pr new"*|"pr comment"*|"pr edit"*|"pr review"*|"pr close"*|"pr reopen"*|"issue "*|"release "*)
    # Echo the body file's content the way gh would read it, so a replaced
    # stdin body file is observable.
    prev=""; for a in "$@"; do
      case "$prev" in --body-file|-F|--notes-file) printf 'stub-body:'; cat "$a" ;; esac
      case "$a" in
        --body-file=*) printf 'stub-body:'; cat "${a#--body-file=}" ;;
        --notes-file=*) printf 'stub-body:'; cat "${a#--notes-file=}" ;;
        -F?*) printf 'stub-body:'; cat "${a#-F}" ;;
      esac
      prev="$a"
    done
    echo "stub: SENT $1 $2"; exit 0 ;;
  *) echo "stub: passthrough $*"; exit 0 ;;
esac
STUB
chmod +x "${TMP}/bin/gh"
# DND-1647: a guard stands behind every gh/glab stub on PATH, so a stub
# that is missing or not executable fails the suite instead of reaching the
# real CLI (ai/lib/forge-stub-guard.sh).
. "${HERE}/../../lib/forge-stub-guard.sh"
fsg_arm "${TMP}/forge-guard"
fsg_require_stubs "${TMP}/bin" gh
export PATH="${TMP}/bin:${PATH}"

# A fixture overlay with synthetic patterns, git-backed (the committed floor).
OVERLAY="${TMP}/overlay"
mkdir -p "${OVERLAY}/outbound" && chmod 700 "${OVERLAY}"
printf '{"kind":"athena-private-overlay","schema":1}\n' > "${OVERLAY}/athena-overlay.json"
printf 'synth-token\tSYNTH-TOKEN-[0-9]+\n' > "${OVERLAY}/outbound/patterns.tsv"
git -C "${OVERLAY}" init -q && git -C "${OVERLAY}" add -A && git -C "${OVERLAY}" commit -q -m overlay
export ATHENA_PRIVATE_ROOT="${OVERLAY}"

WORK="${TMP}/work"; mkdir -p "${WORK}"
# DND-2007: WORK is a checkout of the PR's repo, so the merge guard can read
# the base tip (its one commit, which declares no integration gate).
git init -q -b main "${WORK}"
git -C "${WORK}" remote add origin git@github.com:synth-owner/pub.git
echo readme > "${WORK}/README"
git -C "${WORK}" add README && git -C "${WORK}" commit -q -m base
export STUB_TIP; STUB_TIP="$(git -C "${WORK}" rev-parse HEAD)"
export STUB_HEAD="b712de1d0000000000000000000000000000beef"
MH="--match-head-commit ${STUB_HEAD}"

# gha <args...> : run the wrapper in WORK. Sets OUT (stdout+stderr), RC.
gha() {
  : > "${STUB_LOG}"
  OUT="$(cd "${WORK}" && "${WRAPPER}" "$@" 2>&1)"; RC=$?
  CALLS="$(cat "${STUB_LOG}")"
}
sent() { [[ "${CALLS}" == *"$1"* ]] && [[ "${OUT}" == *"stub: SENT"* ]]; }
not_sent() { [[ "${CALLS}" != *"$1"* ]] && [[ "${OUT}" != *"stub: SENT"* ]]; }
# The matched text never appears in anything but the stub's own echo of what
# gh received (a stdin body gh was allowed to send).
no_literal() { [ "$(printf '%s\n' "${OUT}" | grep -v '^stub-body:' | grep -c -- "${TOKEN}")" = 0 ]; }

printf 'body with %s inside\n' "${TOKEN}" > "${TMP}/body-hit.md"
printf 'a clean body\n' > "${TMP}/body-clean.md"

echo "gh-athena outbound-scan self-test"
echo "wrapper: ${WRAPPER}"
echo

echo "--- 11: pr create --body-file with the token, PUBLIC target: refused before gh is called ---"
echo PUBLIC > "${STUB_VIS}"
gha pr create --title "a title" --body-file "${TMP}/body-hit.md" --base main
if [ "${RC}" = 1 ] && not_sent "pr create" && [[ "${OUT}" == *"body-file:1 label=synth-token"* ]] \
   && [[ "${OUT}" == *"REFUSED"* ]] && [[ "${OUT}" == *"Fix:"* ]] && no_literal; then
  ok "11 refused, gh never ran pr create"
else
  bad "11 refused" "rc=${RC} calls=[${CALLS}] ${OUT}"
fi

echo "--- title, --body, --body=, -b and -t spellings ---"
for spelling in "--title x${TOKEN}" "-t x${TOKEN}" "--body x${TOKEN}" "-b x${TOKEN}" "--body=x${TOKEN}" "--title=x${TOKEN}"; do
  # shellcheck disable=SC2086
  gha pr create ${spelling}
  if [ "${RC}" = 1 ] && not_sent "pr create" && no_literal; then ok "refused: ${spelling%%x*}"; else bad "refused: ${spelling%%x*}" "rc=${RC} ${OUT}"; fi
done
echo "--- attached short-flag values (critic round 1: -bVALUE went out unscanned) ---"
gha pr create "-bx${TOKEN}"
if [ "${RC}" = 1 ] && not_sent "pr create" && no_literal; then ok "refused: -bVALUE"; else bad "refused: -bVALUE" "rc=${RC} ${OUT}"; fi
gha pr create "-tx${TOKEN}"
if [ "${RC}" = 1 ] && not_sent "pr create" && no_literal; then ok "refused: -tVALUE"; else bad "refused: -tVALUE" "rc=${RC} ${OUT}"; fi
gha pr create "-F${TMP}/body-hit.md"
if [ "${RC}" = 1 ] && not_sent "pr create" && no_literal; then ok "refused: -F/path"; else bad "refused: -F/path" "rc=${RC} ${OUT}"; fi
OUT="$(cd "${WORK}" && : > "${STUB_LOG}" && printf 'clean via -F-\n' | "${WRAPPER}" pr create -F- 2>&1)"; RC=$?; CALLS="$(cat "${STUB_LOG}")"
if [ "${RC}" = 0 ] && sent "pr create" && [[ "${OUT}" == *"stub-body:clean via -F-"* ]]; then ok "-F- is replaced by the scanned copy"; else bad "-F-" "rc=${RC} calls=[${CALLS}] ${OUT}"; fi
gha pr create -d --body "clean"
if [ "${RC}" = 0 ] && sent "pr create"; then ok "a lone boolean short flag passes"; else bad "lone short flag" "rc=${RC} ${OUT}"; fi
gha pr create --body "x${TOKEN}" --body "clean"
if [ "${RC}" = 1 ] && not_sent "pr create"; then ok "every --body occurrence is scanned (first dirty)"; else bad "repeat first" "rc=${RC} ${OUT}"; fi
gha pr create --body "clean" --body "x${TOKEN}"
if [ "${RC}" = 1 ] && not_sent "pr create"; then ok "every --body occurrence is scanned (last dirty)"; else bad "repeat last" "rc=${RC} ${OUT}"; fi

echo "--- pr merge: a squash subject/body becomes a server-side commit (critic round 2) ---"
for spelling in "--subject x${TOKEN}" "--subject=x${TOKEN}" "-t x${TOKEN}" "--body x${TOKEN}"; do
  # shellcheck disable=SC2086
  gha pr merge 5 --squash ${MH} ${spelling}
  if [ "${RC}" = 1 ] && [[ "${CALLS}" != *"pr merge"* ]] && [[ "${OUT}" == *"REFUSED"* ]] && [[ "${OUT}" == *"label=synth-token"* ]] && no_literal; then
    ok "refused: pr merge ${spelling%%x*}"
  else
    bad "refused: pr merge ${spelling%%x*}" "rc=${RC} calls=[${CALLS}] ${OUT}"
  fi
done

echo "--- a scratch-file write failure refuses (critic round 2: it used to skip the scan) ---"
# ulimit -f 0 makes the wrapper's `printf > file` fail with EFBIG (SIGXFSZ is
# ignored so the shell sees an error, not a signal); mktemp -d still succeeds.
OUT="$(cd "${WORK}" && : > "${STUB_LOG}" && (trap '' XFSZ; ulimit -f 0; "${WRAPPER}" pr create --body "clean") 2>&1)"; RC=$?
if [ "${RC}" = 3 ] && [[ "${OUT}" == *"could not write the body"* ]] && [[ "${OUT}" == *"Fix:"* ]] && [[ "${OUT}" != *"stub: SENT"* ]]; then
  ok "write failure refused, gh never sent"
else
  bad "write failure" "rc=${RC} ${OUT}"
fi

for cmd in "pr comment 5" "pr edit 5" "pr review 5 --comment" "issue create" "issue comment 7" "issue edit 7"; do
  # shellcheck disable=SC2086
  gha ${cmd} --body "x${TOKEN}"
  if [ "${RC}" = 1 ] && not_sent "${cmd%% *}" && no_literal; then ok "refused: ${cmd}"; else bad "refused: ${cmd}" "rc=${RC} ${OUT}"; fi
done

echo "--- a clean body is sent, with CLEAN shown ---"
gha pr create --title "clean" --body-file "${TMP}/body-clean.md"
if [ "${RC}" = 0 ] && sent "pr create" && [[ "${OUT}" == *"outbound-scan: CLEAN mode=text"* ]]; then ok "clean body sent"; else bad "clean body sent" "rc=${RC} ${OUT}"; fi

echo "--- --body-file - : stdin is scanned, and gh gets the scanned copy ---"
OUT="$(cd "${WORK}" && : > "${STUB_LOG}" && printf 'from stdin %s\n' "${TOKEN}" | "${WRAPPER}" pr create --body-file - 2>&1)"; RC=$?; CALLS="$(cat "${STUB_LOG}")"
if [ "${RC}" = 1 ] && not_sent "pr create" && [[ "${OUT}" == *"body-file:1 label=synth-token"* ]]; then ok "stdin body with the token refused"; else bad "stdin hit" "rc=${RC} ${OUT}"; fi
OUT="$(cd "${WORK}" && : > "${STUB_LOG}" && printf 'clean stdin body\n' | "${WRAPPER}" pr create --body-file - 2>&1)"; RC=$?; CALLS="$(cat "${STUB_LOG}")"
if [ "${RC}" = 0 ] && sent "pr create" && [[ "${OUT}" == *"stub-body:clean stdin body"* ]]; then ok "clean stdin body reaches gh intact"; else bad "stdin clean" "rc=${RC} ${OUT}"; fi
OUT="$(cd "${WORK}" && : > "${STUB_LOG}" && printf 'clean stdin body\n' | "${WRAPPER}" pr create --body-file=- 2>&1)"; RC=$?; CALLS="$(cat "${STUB_LOG}")"
if [ "${RC}" = 0 ] && sent "pr create" && [[ "${OUT}" == *"stub-body:clean stdin body"* ]]; then ok "--body-file=- reaches gh intact"; else bad "--body-file=-" "rc=${RC} ${OUT}"; fi

echo "--- PRIVATE target: not scanned ---"
echo PRIVATE > "${STUB_VIS}"
gha pr create --body "x${TOKEN}"
if [ "${RC}" = 0 ] && sent "pr create" && [[ "${OUT}" != *"outbound-scan:"* ]]; then ok "private target not scanned"; else bad "private target" "rc=${RC} ${OUT}"; fi
gha pr create -R some/repo --body "x${TOKEN}"
if [ "${RC}" = 0 ] && [[ "${CALLS}" == *"repo view some/repo --json visibility"* ]]; then ok "-R names the repo whose visibility is read"; else bad "-R repo" "calls=[${CALLS}]"; fi

echo "--- the target is every repo the write can reach (critic round 3: a URL positional) ---"
echo PRIVATE > "${STUB_VIS}"                 # the current directory's repo
echo PUBLIC > "${STUB_VIS}.synth-owner_pub"
echo PRIVATE > "${STUB_VIS}.synth-owner_priv"
gha pr comment https://github.com/synth-owner/pub/pull/3 --body "x${TOKEN}"
if [ "${RC}" = 1 ] && not_sent "pr comment" && [[ "${CALLS}" == *"repo view synth-owner/pub --json visibility"* ]] && no_literal; then
  ok "a PR URL to a PUBLIC repo is scanned from a PRIVATE cwd"
else
  bad "PR URL public" "rc=${RC} calls=[${CALLS}] ${OUT}"
fi
gha issue comment https://github.com/synth-owner/priv/issues/9 --body "x${TOKEN}"
if [ "${RC}" = 0 ] && sent "issue comment"; then ok "an issue URL to a PRIVATE repo is not scanned"; else bad "issue URL private" "rc=${RC} ${OUT}"; fi
gha pr comment -R synth-owner/priv https://github.com/synth-owner/pub/pull/3 --body "x${TOKEN}"
if [ "${RC}" = 1 ] && not_sent "pr comment"; then ok "-R private plus a PUBLIC URL is scanned"; else bad "-R + URL" "rc=${RC} ${OUT}"; fi
gha pr comment https://github.com/ --body "x${TOKEN}"
if [ "${RC}" = 1 ] && not_sent "pr comment" && [[ "${OUT}" == *"cannot parse; scanning as PUBLIC"* ]]; then ok "an unparsable URL is scanned as PUBLIC"; else bad "unparsable URL" "rc=${RC} ${OUT}"; fi
OUT="$(cd "${WORK}" && : > "${STUB_LOG}" && GH_REPO=synth-owner/pub "${WRAPPER}" pr comment 3 --body "x${TOKEN}" 2>&1)"; RC=$?; CALLS="$(cat "${STUB_LOG}")"
if [ "${RC}" = 1 ] && not_sent "pr comment" && [[ "${CALLS}" == *"repo view synth-owner/pub"* ]]; then ok "GH_REPO names the target"; else bad "GH_REPO" "rc=${RC} calls=[${CALLS}] ${OUT}"; fi
gha pr comment --body "x${TOKEN}" -- https://github.com/synth-owner/pub/pull/3
if [[ "${CALLS}" == *"repo view synth-owner/pub"* ]]; then ok "a URL after -- is still a target"; else bad "URL after --" "calls=[${CALLS}] ${OUT}"; fi

echo "--- DND-2006: an empty -R is not a target; gh falls back to GH_REPO ---"
# gh 2.96 (cmdutil.OverrideBaseRepoFunc): an empty -R/--repo value falls back
# to GH_REPO, then to the checkout. `gh repo view` with no argument ignores
# GH_REPO (measured 2026-10-04). The guard read `-R ''` as "a -R was given",
# skipped GH_REPO, and read the checkout's visibility (PRIVATE here) while gh
# wrote to the PUBLIC GH_REPO: the text went out unscanned.
# gha_env <VAR=value...> -- <args...> : gha with extra environment.
gha_env() {
  local -a envs=()
  while [ "$1" != -- ]; do envs+=("$1"); shift; done; shift
  : > "${STUB_LOG}"
  OUT="$(cd "${WORK}" && env "${envs[@]}" "${WRAPPER}" "$@" 2>&1)"; RC=$?
  CALLS="$(cat "${STUB_LOG}")"
}
gha_env GH_REPO=synth-owner/pub -- pr create -R '' -b "x${TOKEN}"
if [ "${RC}" = 1 ] && not_sent "pr create" && [[ "${CALLS}" == *"repo view synth-owner/pub --json visibility"* ]] \
   && [[ "${OUT}" == *"label=synth-token"* ]] && no_literal; then
  ok "DND-2006 regression: GH_REPO=<public> pr create -R '' -b <planted> is scanned and refused"
else
  bad "DND-2006 regression: GH_REPO=<public> pr create -R '' -b <planted>" "rc=${RC} calls=[${CALLS}] ${OUT}"
fi
for argv in "pr create --repo= -b" "pr create --repo  -b" "pr comment 3 -R synth-owner/priv -R  -b" \
  "-R  pr comment 3 -b" "pr -R  comment 3 -b" "issue create -t t -R  -b" "issue comment 7 --repo= -b" \
  "pr close 5 -R  -c" "pr merge 5 --squash -R  -b" "release create v1 -R  -n"; do
  # The double space is an empty -R value; split by hand so it survives.
  words=(); rest="${argv}"
  while [ -n "${rest}" ]; do
    w="${rest%% *}"; words+=("${w}")
    if [ "${w}" = "${rest}" ]; then rest=""; else rest="${rest#* }"; fi
  done
  gha_env GH_REPO=synth-owner/pub -- "${words[@]}" "x${TOKEN}"
  if [ "${RC}" = 1 ] && [[ "${OUT}" != *"stub: SENT"* ]] && [[ "${CALLS}" == *"repo view synth-owner/pub --json visibility"* ]] && no_literal; then
    ok "GH_REPO is the target: ${argv}"
  else
    bad "GH_REPO is the target: ${argv}" "rc=${RC} calls=[${CALLS}] ${OUT}"
  fi
done
gha_env GH_REPO=synth-owner/pub -- pr comment 3 -R synth-owner/priv -b "x${TOKEN}"
if [ "${RC}" = 0 ] && sent "pr comment" && [[ "${CALLS}" != *"repo view synth-owner/pub"* ]]; then
  ok "a non-empty -R still wins over GH_REPO (gh's precedence)"
else
  bad "-R wins over GH_REPO" "rc=${RC} calls=[${CALLS}] ${OUT}"
fi
gha_env GH_REPO=synth-owner/priv -- pr comment 3 -R synth-owner/pub -R '' -b "x${TOKEN}"
if [ "${RC}" = 1 ] && not_sent "pr comment" && [[ "${CALLS}" == *"repo view synth-owner/pub --json visibility"* ]]; then
  ok "an earlier -R value is still scanned when a later empty -R hands gh to GH_REPO"
else
  bad "earlier -R kept" "rc=${RC} calls=[${CALLS}] ${OUT}"
fi
gha pr comment 3 -R '' -b "x${TOKEN}"
if [ "${RC}" = 0 ] && sent "pr comment" && [[ "${CALLS}" == *"repo view --json visibility"* ]]; then
  ok "-R '' with no GH_REPO reads the checkout, as gh does"
else
  bad "-R '' no GH_REPO" "rc=${RC} calls=[${CALLS}] ${OUT}"
fi
gha_env GH_REPO=synth-owner/pub -- pr comment https://github.com/synth-owner/priv/pull/3 -R '' -b "x${TOKEN}"
if [ "${RC}" = 1 ] && not_sent "pr comment" && [[ "${CALLS}" == *"repo view synth-owner/pub --json visibility"* ]]; then
  ok "GH_REPO behind an empty -R is a target beside a PR URL"
else
  bad "GH_REPO + URL" "rc=${RC} calls=[${CALLS}] ${OUT}"
fi
for bogus in "not-a-repo" "a/b/c/d" " " "a b/c"; do
  gha_env "GH_REPO=${bogus}" -- pr create -R '' -b "clean"
  if [ "${RC}" = 3 ] && not_sent "pr create" && [[ "${OUT}" == *"COULD NOT LOOK"* ]] && [[ "${OUT}" == *"Fix:"* ]]; then
    ok "an unresolvable GH_REPO refuses: '${bogus}'"
  else
    bad "unresolvable GH_REPO '${bogus}'" "rc=${RC} calls=[${CALLS}] ${OUT}"
  fi
done
gha pr create -R "not-a-repo" -b "clean"
if [ "${RC}" = 3 ] && not_sent "pr create" && [[ "${OUT}" == *"COULD NOT LOOK"* ]] && [[ "${OUT}" == *"Fix:"* ]]; then
  ok "an unresolvable -R refuses"
else
  bad "unresolvable -R" "rc=${RC} calls=[${CALLS}] ${OUT}"
fi
for good in "github.com/synth-owner/pub" "https://github.com/synth-owner/pub" "git@github.com:synth-owner/pub.git"; do
  gha pr comment 3 -R "${good}" -b "clean"
  if [ "${RC}" = 0 ] && [[ "${CALLS}" == *"repo view ${good} --json visibility"* ]]; then
    ok "a -R form gh accepts is read as given: ${good}"
  else
    bad "-R form ${good}" "rc=${RC} calls=[${CALLS}] ${OUT}"
  fi
done
rm -f "${STUB_VIS}".synth-owner_*
echo PUBLIC > "${STUB_VIS}"

echo "--- visibility unreadable: scanned as PUBLIC ---"
: > "${STUB_VIS}"
gha pr create --body "x${TOKEN}"
if [ "${RC}" = 1 ] && not_sent "pr create" && [[ "${OUT}" == *"could not be read; scanning as PUBLIC"* ]]; then ok "unknown visibility scanned"; else bad "unknown visibility" "rc=${RC} ${OUT}"; fi
echo PUBLIC > "${STUB_VIS}"

echo "--- commands outside the write list pass untouched ---"
gha pr view 5 --json body
if [ "${RC}" = 0 ] && [[ "${CALLS}" != *"repo view"* ]] && [[ "${OUT}" == *"stub: passthrough pr view 5"* ]]; then ok "pr view untouched"; else bad "pr view" "rc=${RC} calls=[${CALLS}] ${OUT}"; fi

echo "--- waiver: sent, WAIVED shown, never CLEAN ---"
OUT="$(cd "${WORK}" && : > "${STUB_LOG}" && XDG_STATE_HOME="${TMP}/state" ATHENA_OUTBOUND_WAIVE="synthetic waiver" "${WRAPPER}" pr create --body "x${TOKEN}" 2>&1)"; RC=$?; CALLS="$(cat "${STUB_LOG}")"
if [ "${RC}" = 0 ] && sent "pr create" && [[ "${OUT}" == *"WAIVED - NOT SCANNED"* ]] && [[ "${OUT}" != *"CLEAN"* ]]; then ok "waiver"; else bad "waiver" "rc=${RC} ${OUT}"; fi

echo "--- overlay ABSENT on an unmarked machine: sent with a loud UNSCANNED warning ---"
# Hermetic: the mark is read from the wrapper's OWN checkout's hooks dir, so the
# case runs a copy of ai/bin + ai/lib inside a fixture repo with no pre-push
# hook, never this checkout (whose common .git/hooks is the host's).
UM="${TMP}/unmarked"; git init -q "${UM}"; mkdir -p "${UM}/ai"
cp -r "${AI_DIR}/bin" "${AI_DIR}/lib" "${UM}/ai/"
OUT="$(cd "${WORK}" && : > "${STUB_LOG}" && env -u ATHENA_PRIVATE_ROOT "${UM}/ai/bin/gh-athena" pr create --body "x" 2>&1)"; RC=$?; CALLS="$(cat "${STUB_LOG}")"
if [ "${RC}" = 0 ] && sent "pr create" && [[ "${OUT}" == *"COULD NOT MEASURE"* ]] && [[ "${OUT}" == *"went out UNSCANNED"* ]] \
   && [[ "${OUT}" == *"not a clean result"* ]] && [[ "${OUT}" != *"CLEAN mode"* ]]; then
  ok "absent + unmarked: sent, warned"
else
  bad "absent + unmarked" "rc=${RC} ${OUT}"
fi

echo "--- overlay MALFORMED: refused even on an unmarked machine ---"
OUT="$(cd "${WORK}" && : > "${STUB_LOG}" && ATHENA_PRIVATE_ROOT=/nonexistent "${WRAPPER}" pr create --body "x" 2>&1)"; RC=$?; CALLS="$(cat "${STUB_LOG}")"
if [ "${RC}" = 3 ] && not_sent "pr create" && [[ "${OUT}" == *"overlay is MALFORMED"* ]] && [[ "${OUT}" == *"REFUSED"* ]]; then ok "malformed refused"; else bad "malformed" "rc=${RC} ${OUT}"; fi

echo "--- overlay ABSENT on a MARKED machine (hook installed): refused ---"
MK="${TMP}/marked"; git init -q "${MK}"; mkdir -p "${MK}/ai"
cp -r "${AI_DIR}/bin" "${AI_DIR}/lib" "${MK}/ai/"
printf '#!/bin/sh\nexec ai/bin/outbound-scan --pre-push --remote "$1"\n' > "${MK}/.git/hooks/pre-push"
OUT="$(cd "${WORK}" && : > "${STUB_LOG}" && env -u ATHENA_PRIVATE_ROOT "${MK}/ai/bin/gh-athena" pr create --body "x" 2>&1)"; RC=$?; CALLS="$(cat "${STUB_LOG}")"
if [ "${RC}" = 3 ] && not_sent "pr create" && [[ "${OUT}" == *"overlay is ABSENT"* ]] && [[ "${OUT}" == *"this machine must measure"* ]]; then
  ok "absent + marked: refused"
else
  bad "absent + marked" "rc=${RC} ${OUT}"
fi

echo "--- a scanner that exits 1 without reporting HITS is a failure, not a result (critic round 3) ---"
CR="${TMP}/crash"; git init -q "${CR}"; mkdir -p "${CR}/ai"
cp -r "${AI_DIR}/bin" "${AI_DIR}/lib" "${CR}/ai/"
printf '#!/bin/sh\necho "Traceback: boom" >&2\nexit 1\n' > "${CR}/ai/bin/outbound-scan"
OUT="$(cd "${WORK}" && : > "${STUB_LOG}" && "${CR}/ai/bin/gh-athena" pr create --body "clean" 2>&1)"; RC=$?; CALLS="$(cat "${STUB_LOG}")"
if [ "${RC}" = 3 ] && not_sent "pr create" && [[ "${OUT}" == *"without reporting HITS"* ]]; then ok "a crash reads as a failure"; else bad "crash" "rc=${RC} ${OUT}"; fi

echo "--- review floor: every body file is copied; gh reads the scanned copy ---"
OUT="$(cd "${WORK}" && : > "${STUB_LOG}" && "${WRAPPER}" pr create --body-file <(printf 'from a pipe\n') 2>&1)"; RC=$?; CALLS="$(cat "${STUB_LOG}")"
if [ "${RC}" = 0 ] && sent "pr create" && [[ "${OUT}" == *"stub-body:from a pipe"* ]]; then ok "a process-substitution body reaches gh intact"; else bad "pipe body" "rc=${RC} ${OUT}"; fi
gha pr create --body-file "${TMP}/body-clean.md"
if [ "${RC}" = 0 ] && [[ "${CALLS}" != *"${TMP}/body-clean.md"* ]] && [[ "${OUT}" == *"stub-body:a clean body"* ]]; then ok "gh is handed the scanned copy, not the original path"; else bad "copy handed" "calls=[${CALLS}] ${OUT}"; fi

echo "--- review floor: close/reopen comments are scanned ---"
for cmd in "pr close 5 --comment" "pr reopen 5 -c" "issue close 7 --comment" "issue reopen 7 -c"; do
  # shellcheck disable=SC2086
  gha ${cmd} "x${TOKEN}"
  if [ "${RC}" = 1 ] && not_sent "${cmd%% *}" && no_literal; then ok "refused: ${cmd}"; else bad "refused: ${cmd}" "rc=${RC} ${OUT}"; fi
done
gha pr close 5 "--comment=x${TOKEN}"
if [ "${RC}" = 1 ] && not_sent "pr close"; then ok "refused: pr close --comment="; else bad "pr close --comment=" "rc=${RC} ${OUT}"; fi
gha pr review 5 --comment --body "clean"
if [ "${RC}" = 0 ] && sent "pr review"; then ok "pr review --comment stays a switch"; else bad "pr review --comment switch" "rc=${RC} ${OUT}"; fi

echo "--- review floor: 'is this machine marked?' failing reads as MUST measure ---"
NG="${TMP}/not-a-repo"; mkdir -p "${NG}/ai"
cp -r "${AI_DIR}/bin" "${AI_DIR}/lib" "${NG}/ai/"
OUT="$(cd "${WORK}" && : > "${STUB_LOG}" && env -u ATHENA_PRIVATE_ROOT GIT_CEILING_DIRECTORIES="${TMP}" "${NG}/ai/bin/gh-athena" pr create --body "x" 2>&1)"; RC=$?; CALLS="$(cat "${STUB_LOG}")"
if [ "${RC}" = 3 ] && not_sent "pr create" && [[ "${OUT}" == *"this machine must measure"* ]]; then ok "an undeterminable mark refuses"; else bad "undeterminable mark" "rc=${RC} ${OUT}"; fi

echo "--- an unreadable body file is refused ---"
gha pr create --body-file "${TMP}/no-such-file"
if [ "${RC}" = 3 ] && not_sent "pr create" && [[ "${OUT}" == *"is not readable"* ]] && [[ "${OUT}" == *"Fix:"* ]]; then ok "unreadable body file"; else bad "unreadable body file" "rc=${RC} ${OUT}"; fi

echo "--- DND-1976: an unknown flag swallowed the next flag, and its text went out unscanned ---"
# gh gives a valued flag the next word even when it starts with `-`, so
# `-l -t -b X` is label `-t`, body X. The old parse did not know -l took a
# value, read `-t` as the title (its value `-b`) and X as a positional: X was
# never scanned, and gh sent it as the body.
echo PUBLIC > "${STUB_VIS}"
gha pr create -l -t -b "x${TOKEN}"
if [ "${RC}" = 1 ] && not_sent "pr create" && [[ "${OUT}" == *"label=synth-token"* ]] && no_literal; then
  ok "DND-1976 regression: pr create -l -t -b <planted> is scanned and refused"
else
  bad "DND-1976 regression: pr create -l -t -b <planted>" "rc=${RC} calls=[${CALLS}] ${OUT}"
fi
for argv in "pr create -a -t -b x${TOKEN}" "pr create -H -t --body x${TOKEN}" "pr create --label -t --body=x${TOKEN}" \
  "pr edit 5 --add-label -t -b x${TOKEN}" "pr comment 5 -R synth-owner/pub -b x${TOKEN}" \
  "issue create -l -t -b x${TOKEN}" \
  "issue edit 7 --add-label -t -b x${TOKEN}" "issue close 7 -r -t -c x${TOKEN}"; do
  # shellcheck disable=SC2086
  gha ${argv}
  if [ "${RC}" = 1 ] && [[ "${OUT}" != *"stub: SENT"* ]] && [[ "${OUT}" == *"label=synth-token"* ]] && no_literal; then ok "refused: ${argv%%x${TOKEN}}"; else bad "refused: ${argv%%x${TOKEN}}" "rc=${RC} calls=[${CALLS}] ${OUT}"; fi
done
# DND-2007: the merge guard runs first and reads `-t` as the pinned head, which
# is not the PR's head, so it refuses before the scan; nothing is sent.
gha pr merge 5 --squash --match-head-commit -t -b "x${TOKEN}"
if [ "${RC}" = 3 ] && [[ "${OUT}" != *"stub: SENT"* ]] && [[ "${OUT}" == *"is not the PR's head"* ]]; then ok "refused by the merge guard: pr merge --match-head-commit -t -b"; else bad "pr merge --match-head-commit -t" "rc=${RC} calls=[${CALLS}] ${OUT}"; fi

echo "--- DND-1976: a value that is a file or target flag of the command is refused, not guessed ---"
gha pr create -l -F "${TMP}/body-hit.md"
if [ "${RC}" = 3 ] && not_sent "pr create" && [[ "${OUT}" == *"looks like a flag"* ]] && [[ "${OUT}" == *"Fix:"* ]]; then ok "a label value that is -F refused"; else bad "label -F" "rc=${RC} ${OUT}"; fi
gha pr create --label -R synth-owner/pub -b "clean"
if [ "${RC}" = 3 ] && not_sent "pr create" && [[ "${OUT}" == *"looks like a flag"* ]]; then ok "a label value that is -R refused"; else bad "label -R" "rc=${RC} ${OUT}"; fi
gha pr create --label -b "x${TOKEN}"
if [ "${RC}" = 1 ] && not_sent "pr create" && [[ "${OUT}" == *"argument:1 label=synth-token"* ]] && no_literal; then ok "a label value that names a text flag makes the next word text (a drifted table)"; else bad "label -b X" "rc=${RC} ${OUT}"; fi
for argv in "pr --help" "issue -h" "release --help" "pr --help create"; do
  # shellcheck disable=SC2086
  gha ${argv} -b "x${TOKEN}"
  if [ "${RC}" = 0 ] && [[ "${OUT}" != *"outbound-scan:"* ]] && [[ "${CALLS}" != *"repo view"* ]]; then ok "a help flag before the verb passes: ${argv}"; else bad "help before verb: ${argv}" "rc=${RC} ${OUT}"; fi
done
gha pr create "--label=-F" -b "clean"
if [ "${RC}" = 0 ] && sent "pr create"; then ok "an attached value is never another flag"; else bad "attached -F value" "rc=${RC} ${OUT}"; fi

echo "--- DND-1976: every word the flag table cannot classify is refused ---"
gha pr create --no-such-flag -b "x${TOKEN}"
if [ "${RC}" = 3 ] && not_sent "pr create" && [[ "${OUT}" == *"--no-such-flag"* ]] && [[ "${OUT}" == *"Fix:"* ]] && no_literal; then ok "an unknown long flag refused"; else bad "unknown long flag" "rc=${RC} ${OUT}"; fi
OUT="$(cd "${WORK}" && : > "${STUB_LOG}" && OTS_LENIENT=1 OTS_MODE=lenient "${WRAPPER}" pr create --no-such-flag value -b "x${TOKEN}" 2>&1)"; RC=$?
if [ "${RC}" = 3 ] && [[ "${OUT}" != *"stub: SENT"* ]] && [[ "${OUT}" == *"--no-such-flag"* ]]; then ok "no inherited variable makes gh's parse lenient"; else bad "inherited lenient" "rc=${RC} ${OUT}"; fi
gha pr create -Z -b "x${TOKEN}"
if [ "${RC}" = 3 ] && not_sent "pr create" && [[ "${OUT}" == *"-Z"* ]] && [[ "${OUT}" == *"Fix:"* ]]; then ok "an unknown short flag refused"; else bad "unknown short flag" "rc=${RC} ${OUT}"; fi
gha pr create -h -b "x${TOKEN}"
if [ "${RC}" = 0 ] && [[ "${OUT}" != *"outbound-scan:"* ]] && [[ "${CALLS}" != *"repo view"* ]]; then ok "-h (pflag shows the help, nothing runs) is not scanned"; else bad "-h" "rc=${RC} ${OUT}"; fi
gha pr create -b "x${TOKEN}" -h
if [ "${RC}" = 0 ] && [[ "${OUT}" != *"outbound-scan:"* ]]; then ok "-h after the body: still the help"; else bad "-h after" "rc=${RC} ${OUT}"; fi
echo PRIVATE > "${STUB_VIS}"
echo PUBLIC > "${STUB_VIS}.synth-owner_pub"
gha pr --repo synth-owner/pub create -b "x${TOKEN}"
if [ "${RC}" = 1 ] && not_sent "pr create" && [[ "${CALLS}" == *"repo view synth-owner/pub"* ]] && no_literal; then ok "a -R between the group and the verb is a target (cobra reads it)"; else bad "-R before verb" "rc=${RC} calls=[${CALLS}] ${OUT}"; fi
gha -R synth-owner/pub pr create -b "x${TOKEN}"
if [ "${RC}" = 1 ] && not_sent "pr create" && [[ "${CALLS}" == *"repo view synth-owner/pub"* ]]; then ok "a -R before the command path is a target"; else bad "-R before path" "rc=${RC} calls=[${CALLS}] ${OUT}"; fi
rm -f "${STUB_VIS}".synth-owner_*
echo PUBLIC > "${STUB_VIS}"
gha pr -d create -b "x${TOKEN}"
if [ "${RC}" = 3 ] && not_sent "pr create" && [[ "${OUT}" == *"before the command path"* ]] && [[ "${OUT}" == *"Fix:"* ]]; then ok "another flag between the group and the verb refused"; else bad "flag before verb" "rc=${RC} ${OUT}"; fi
gha --verbose pr create -b "x${TOKEN}"
if [ "${RC}" = 3 ] && not_sent "pr create" && [[ "${OUT}" == *"Fix:"* ]]; then ok "another flag before the command path refused"; else bad "flag before path" "rc=${RC} ${OUT}"; fi
gha -R -F pr create -b "clean"
if [ "${RC}" = 3 ] && not_sent "pr create" && [[ "${OUT}" == *"looks like a flag"* ]]; then ok "a -R before the path whose value looks like a flag refused"; else bad "-R -F prepath" "rc=${RC} ${OUT}"; fi

echo "--- DND-1976: pflag's own spellings are read exactly ---"
gha pr create -db "x${TOKEN}"
if [ "${RC}" = 1 ] && not_sent "pr create" && no_literal; then ok "-db X: -d is a switch, X is the body"; else bad "-db X" "rc=${RC} ${OUT}"; fi
gha pr create "-dbx${TOKEN}"
if [ "${RC}" = 1 ] && not_sent "pr create" && no_literal; then ok "-dbVALUE: the body is attached"; else bad "-dbVALUE" "rc=${RC} ${OUT}"; fi
gha pr create "-t=x${TOKEN}"
if [ "${RC}" = 1 ] && not_sent "pr create" && no_literal; then ok "-t=VALUE"; else bad "-t=VALUE" "rc=${RC} ${OUT}"; fi
gha pr create -dF "${TMP}/body-hit.md"
if [ "${RC}" = 1 ] && not_sent "pr create" && [[ "${OUT}" == *"body-file:1 label=synth-token"* ]]; then ok "-dF <file>: the body file is scanned"; else bad "-dF file" "rc=${RC} ${OUT}"; fi
gha pr create -l bug -t "a title" -b "a clean body" -d
if [ "${RC}" = 0 ] && sent "pr create" && [[ "${OUT}" == *"CLEAN mode=text"* ]]; then ok "a clean create with valued and boolean flags is sent"; else bad "clean create" "rc=${RC} ${OUT}"; fi

echo "--- DND-1976: a missing flag table refuses a judged write, named, with Fix: ---"
NT="${TMP}/no-table"; git init -q "${NT}"; mkdir -p "${NT}/ai"
cp -r "${AI_DIR}/bin" "${AI_DIR}/lib" "${NT}/ai/"
rm -f "${NT}/ai/lib/gh-flag-table.sh"
OUT="$(cd "${WORK}" && : > "${STUB_LOG}" && "${NT}/ai/bin/gh-athena" pr create -b "clean" 2>&1)"; RC=$?; CALLS="$(cat "${STUB_LOG}")"
if [ "${RC}" = 3 ] && not_sent "pr create" && [[ "${OUT}" == *"gh-flag-table.sh"* ]] && [[ "${OUT}" == *"Fix:"* ]]; then ok "no table: pr create refused"; else bad "no table: pr create" "rc=${RC} ${OUT}"; fi
OUT="$(cd "${WORK}" && : > "${STUB_LOG}" && "${NT}/ai/bin/gh-athena" pr view 5 2>&1)"; RC=$?
if [ "${RC}" = 0 ] && [[ "${OUT}" == *"stub: passthrough pr view 5"* ]]; then ok "no table: pr view still passes"; else bad "no table: pr view" "rc=${RC} ${OUT}"; fi

echo "--- DND-1976 sweep: the aliases and release text ---"
for argv in "pr new -b x${TOKEN}" "issue new -t x${TOKEN}" "pr merge 5 ${MH} -A x${TOKEN}" \
  "release create v1 --notes x${TOKEN}" "release create v1 -n x${TOKEN}" "release create v1 -t x${TOKEN}" \
  "release new v1 -n x${TOKEN}" "release edit v1 --notes=x${TOKEN}" "release edit v1 --tag x${TOKEN}" \
  "release create v1 -n clean x${TOKEN}"; do
  # shellcheck disable=SC2086
  gha ${argv}
  if [ "${RC}" = 1 ] && [[ "${OUT}" != *"stub: SENT"* ]] && [[ "${OUT}" == *"label=synth-token"* ]] && no_literal; then ok "refused: ${argv%%x${TOKEN}}"; else bad "refused: ${argv%%x${TOKEN}}" "rc=${RC} calls=[${CALLS}] ${OUT}"; fi
done
gha release create v1 -F "${TMP}/body-hit.md"
if [ "${RC}" = 1 ] && [[ "${OUT}" != *"stub: SENT"* ]] && [[ "${OUT}" == *"notes-file:1 label=synth-token"* ]]; then ok "release -F <file> refused"; else bad "release -F" "rc=${RC} ${OUT}"; fi
OUT="$(cd "${WORK}" && : > "${STUB_LOG}" && printf 'clean notes\n' | "${WRAPPER}" release create v1 --notes-file - 2>&1)"; RC=$?; CALLS="$(cat "${STUB_LOG}")"
if [ "${RC}" = 0 ] && [[ "${OUT}" == *"stub-body:clean notes"* ]] && [[ "${CALLS}" != *"--notes-file -"* ]]; then ok "release notes from stdin reach gh as the scanned copy"; else bad "release stdin" "rc=${RC} calls=[${CALLS}] ${OUT}"; fi
rm -f "${STUB_VIS}".synth-owner_*

echo "--- DND-2007: gh api writes to a PUBLIC repository are scanned ---"
# The defect: `gh-athena api` was never scanned, so a comment, issue or PR body
# sent by REST or GraphQL to a PUBLIC repository went out with no scan.
printf 'PUBLIC\n' > "${STUB_VIS}.synth-owner_pub"
printf 'PRIVATE\n' > "${STUB_VIS}.synth-owner_priv"
echo PUBLIC > "${STUB_VIS}"
api_refused() { [ "${RC}" = 1 ] && [[ "${OUT}" != *"stub: SENT"* ]] && [[ "${OUT}" == *"label=synth-token"* ]] && [[ "${OUT}" == *"Fix:"* ]] && no_literal; }
gha api -X POST repos/synth-owner/pub/issues/1/comments -f "body=x${TOKEN}"
if api_refused && [[ "${CALLS}" == *"repo view synth-owner/pub"* ]]; then
  ok "DND-2007 regression: api POST comment body <planted> to a PUBLIC repo is scanned and refused"
else
  bad "DND-2007 regression: api POST comment body <planted>" "rc=${RC} calls=[${CALLS}] ${OUT}"
fi
for argv in "api repos/synth-owner/pub/issues -f title=x${TOKEN}" \
  "api repos/synth-owner/pub/issues --raw-field=body=x${TOKEN}" \
  "api repos/synth-owner/pub/issues -F body=x${TOKEN}" \
  "api repos/synth-owner/pub/issues --field body=x${TOKEN}" \
  "api repos/synth-owner/pub/issues -fbody=x${TOKEN}" \
  "api -X PATCH repos/synth-owner/pub/pulls/5 -f body=x${TOKEN}" \
  "api --method PUT repos/synth-owner/pub/issues/1/labels -f labels[]=x${TOKEN}" \
  "api -X POST repos/synth-owner/pub/releases -f tag_name=v1 -f body=x${TOKEN}" \
  "api -X POST repos/synth-owner/pub/pulls/5/reviews -f event=COMMENT -f body=x${TOKEN}" \
  "api https://api.github.com/repos/synth-owner/pub/issues -f body=x${TOKEN}" \
  "api repos/synth-owner/pub/issues?title=x${TOKEN} -X POST" \
  "api -X POST repos/{owner}/{repo}/issues -f body=x${TOKEN}" \
  "api -X POST gists -f description=x${TOKEN}" \
  "api -X POST repos/synth-owner/pub/issues -H X-HTTP-Method-Override:GET -f body=x${TOKEN}"; do
  # shellcheck disable=SC2086
  gha ${argv}
  if api_refused; then ok "refused: ${argv%%x${TOKEN}*}"; else bad "refused: ${argv%%x${TOKEN}*}" "rc=${RC} calls=[${CALLS}] ${OUT}"; fi
done
gha api -X POST repos/synth-owner/pub/issues -F "body=@${TMP}/body-hit.md"
if api_refused && [[ "${OUT}" == *"field-file:1 label=synth-token"* ]]; then ok "an @file field is scanned"; else bad "@file field" "rc=${RC} ${OUT}"; fi
gha api -X POST repos/synth-owner/pub/issues --input "${TMP}/body-hit.md"
if api_refused && [[ "${OUT}" == *"input:1 label=synth-token"* ]]; then ok "an --input body is scanned"; else bad "--input body" "rc=${RC} ${OUT}"; fi
OUT="$(cd "${WORK}" && : > "${STUB_LOG}" && printf 'x%s\n' "${TOKEN}" | "${WRAPPER}" api -X POST repos/synth-owner/pub/issues --input - 2>&1)"; RC=$?; CALLS="$(cat "${STUB_LOG}")"
if api_refused; then ok "an --input - (stdin) body is scanned"; else bad "--input - body" "rc=${RC} ${OUT}"; fi
OUT="$(cd "${WORK}" && : > "${STUB_LOG}" && printf '{"body":"clean"}\n' | "${WRAPPER}" api -X POST repos/synth-owner/pub/issues --input - 2>&1)"; RC=$?; CALLS="$(cat "${STUB_LOG}")"
if [ "${RC}" = 0 ] && [[ "${OUT}" == *'stub-body:{"body":"clean"}'* ]] && [[ "${CALLS}" != *"--input -"* ]] && [[ "${OUT}" == *"CLEAN mode=text"* ]]; then ok "a clean stdin body reaches gh as the scanned copy"; else bad "clean stdin body" "rc=${RC} calls=[${CALLS}] ${OUT}"; fi
gha api graphql -f "query=mutation { addComment(input: {subjectId: \"I_1\", body: \"x${TOKEN}\"}) { clientMutationId } }"
if api_refused && [[ "${OUT}" == *"GraphQL mutation"* ]]; then ok "a GraphQL mutation (target in the query) is scanned as PUBLIC"; else bad "graphql mutation" "rc=${RC} ${OUT}"; fi
GH_REPO=synth-owner/pub gha api -X POST "repos/{owner}/{repo}/issues" -f "body=x${TOKEN}"
if api_refused && [[ "${CALLS}" == *"repo view synth-owner/pub"* ]]; then ok "a {owner}/{repo} endpoint reads GH_REPO's visibility"; else bad "placeholder GH_REPO" "rc=${RC} calls=[${CALLS}] ${OUT}"; fi
unset GH_REPO

echo "--- DND-2007: what passes ---"
gha api -X POST repos/synth-owner/priv/issues -f "body=x${TOKEN}"
if [ "${RC}" = 0 ] && [[ "${OUT}" == *"stub: SENT api"* ]] && [[ "${OUT}" != *"outbound-scan:"* ]]; then ok "a write to a PRIVATE repo is sent unscanned"; else bad "private api write" "rc=${RC} ${OUT}"; fi
gha api -X POST repos/synth-owner/pub/issues -f "body=a clean body"
if [ "${RC}" = 0 ] && [[ "${OUT}" == *"stub: SENT api"* ]] && [[ "${OUT}" == *"CLEAN mode=text"* ]]; then ok "a clean write to a PUBLIC repo is scanned and sent"; else bad "clean public api write" "rc=${RC} ${OUT}"; fi
gha api "repos/synth-owner/pub/issues?q=x${TOKEN}"
if [ "${RC}" = 0 ] && [[ "${OUT}" == *"stub: SENT api"* ]] && [[ "${CALLS}" != *"repo view"* ]]; then ok "a GET reads nothing and is not scanned"; else bad "api GET" "rc=${RC} calls=[${CALLS}] ${OUT}"; fi
gha api -X GET search/issues -f "q=x${TOKEN}"
if [ "${RC}" = 0 ] && [[ "${OUT}" == *"stub: SENT api"* ]] && [[ "${CALLS}" != *"repo view"* ]]; then ok "an explicit -X GET with fields is a read"; else bad "api -X GET fields" "rc=${RC} ${OUT}"; fi
gha api graphql -f "query=query { viewer { login } }"
if [ "${RC}" = 0 ] && [[ "${OUT}" == *"stub: SENT api"* ]] && [[ "${CALLS}" != *"repo view"* ]]; then ok "a GraphQL query (no mutation) is a read"; else bad "graphql read" "rc=${RC} calls=[${CALLS}] ${OUT}"; fi
gha api -X DELETE repos/synth-owner/pub/issues/comments/9
if [ "${RC}" = 0 ] && [[ "${OUT}" == *"stub: SENT api"* ]] && [[ "${CALLS}" != *"repo view"* ]]; then ok "a write with no text reads nothing"; else bad "api DELETE" "rc=${RC} calls=[${CALLS}] ${OUT}"; fi

echo "--- DND-2007: the merge guard refuses first, with no read; the scan cannot classify -> refused ---"
gha api -X PUT repos/synth-owner/pub/pulls/5/merge -f "commit_message=x${TOKEN}"
if [ "${RC}" = 3 ] && [[ "${OUT}" != *"stub: SENT"* ]] && [[ "${CALLS}" != *"repo view"* ]] && [[ "${OUT}" == *"REST merge"* ]]; then ok "an api merge is refused by the merge guard before any visibility read"; else bad "api merge order" "rc=${RC} calls=[${CALLS}] ${OUT}"; fi
gha --verbose api -X POST repos/synth-owner/pub/issues -f "body=clean"
if [ "${RC}" = 3 ] && [[ "${OUT}" != *"stub: SENT"* ]] && [[ "${OUT}" == *"Fix:"* ]]; then ok "a flag before api is refused"; else bad "flag before api" "rc=${RC} ${OUT}"; fi
gha api -X POST 'repos/synth-owner/pub/issues%zz' -f "body=clean"
if [ "${RC}" = 3 ] && [[ "${OUT}" != *"stub: SENT"* ]] && [[ "${OUT}" == *"Fix:"* ]]; then ok "an endpoint that cannot be normalized is refused"; else bad "bad endpoint" "rc=${RC} ${OUT}"; fi
for ep in "repos/synth-owner/priv/../../synth-owner/pub/issues" "repos/synth-owner/./pub/issues" \
  "repos/synth-owner%2Fpub/x/issues" "repos//synth-owner/pub/issues"; do
  gha api -X POST "${ep}" -f "body=x${TOKEN}"
  if [ "${RC}" = 3 ] && [[ "${OUT}" != *"stub: SENT"* ]] && [[ "${OUT}" == *"does not route to the repository it spells"* ]] && [[ "${OUT}" == *"Fix:"* ]]; then ok "refused: an endpoint that does not spell its repository (${ep})"; else bad "spelled ${ep}" "rc=${RC} calls=[${CALLS}] ${OUT}"; fi
done
gha api -X POST "/api/v3/repos/synth-owner/pub/issues" -f "body=x${TOKEN}"
if api_refused; then ok "a leading /api/v3 endpoint is read as its repository"; else bad "api/v3 prefix" "rc=${RC} calls=[${CALLS}] ${OUT}"; fi
rm -f "${STUB_VIS}".synth-owner_*

# DND-1647: no gh/glab call may have fallen through past its stub.
if fsg_verify; then ok "no gh/glab call fell through past its stub (DND-1647)"
else bad "no gh/glab call fell through past its stub (DND-1647)" "see the forge-stub-guard FAIL above"; fi

echo
echo "gh-athena outbound-scan self-test: ${PASS} passed, ${FAIL} failed"
[ "${FAIL}" -eq 0 ]
