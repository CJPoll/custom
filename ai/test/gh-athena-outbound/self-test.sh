#!/usr/bin/env bash
# Self-test for gh-athena's outbound scan (DND-699, design QA case 11).
#
# The defect this pins: a PR or issue body bound for a PUBLIC repository went
# out through `gh-athena` with a work-domain value in it, and nothing said so.
# Now the title/body/body-file of pr/issue writes to a PUBLIC target is scanned
# by ai/bin/outbound-scan before gh runs.
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
  "pr create"*|"pr comment"*|"pr edit"*|"pr review"*|"issue "*)
    # Echo the body file's content the way gh would read it, so a replaced
    # stdin body file is observable.
    prev=""; for a in "$@"; do
      if [ "$prev" = "--body-file" ] || [ "$prev" = "-F" ]; then printf 'stub-body:'; cat "$a"; fi
      case "$a" in
        --body-file=*) printf 'stub-body:'; cat "${a#--body-file=}" ;;
        -F?*) printf 'stub-body:'; cat "${a#-F}" ;;
      esac
      prev="$a"
    done
    echo "stub: SENT $1 $2"; exit 0 ;;
  *) echo "stub: passthrough $*"; exit 0 ;;
esac
STUB
chmod +x "${TMP}/bin/gh"
export PATH="${TMP}/bin:${PATH}"

# A fixture overlay with synthetic patterns, git-backed (the committed floor).
OVERLAY="${TMP}/overlay"
mkdir -p "${OVERLAY}/outbound" && chmod 700 "${OVERLAY}"
printf '{"kind":"athena-private-overlay","schema":1}\n' > "${OVERLAY}/athena-overlay.json"
printf 'synth-token\tSYNTH-TOKEN-[0-9]+\n' > "${OVERLAY}/outbound/patterns.tsv"
git -C "${OVERLAY}" init -q && git -C "${OVERLAY}" add -A && git -C "${OVERLAY}" commit -q -m overlay
export ATHENA_PRIVATE_ROOT="${OVERLAY}"

WORK="${TMP}/work"; mkdir -p "${WORK}"

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
gha pr create -db "x${TOKEN}"
if [ "${RC}" = 3 ] && not_sent "pr create" && [[ "${OUT}" == *"short-flag cluster"* ]] && [[ "${OUT}" == *"Fix:"* ]]; then ok "a cluster hiding -b is refused"; else bad "cluster" "rc=${RC} ${OUT}"; fi
gha pr create -d --body "clean"
if [ "${RC}" = 0 ] && sent "pr create"; then ok "a lone boolean short flag passes"; else bad "lone short flag" "rc=${RC} ${OUT}"; fi
gha pr create --body "x${TOKEN}" --body "clean"
if [ "${RC}" = 1 ] && not_sent "pr create"; then ok "every --body occurrence is scanned (first dirty)"; else bad "repeat first" "rc=${RC} ${OUT}"; fi
gha pr create --body "clean" --body "x${TOKEN}"
if [ "${RC}" = 1 ] && not_sent "pr create"; then ok "every --body occurrence is scanned (last dirty)"; else bad "repeat last" "rc=${RC} ${OUT}"; fi

echo "--- pr merge: a squash subject/body becomes a server-side commit (critic round 2) ---"
for spelling in "--subject x${TOKEN}" "--subject=x${TOKEN}" "-t x${TOKEN}" "--body x${TOKEN}"; do
  # shellcheck disable=SC2086
  gha pr merge 5 --squash ${spelling}
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
OUT="$(cd "${WORK}" && : > "${STUB_LOG}" && env -u ATHENA_PRIVATE_ROOT "${WRAPPER}" pr create --body "x" 2>&1)"; RC=$?; CALLS="$(cat "${STUB_LOG}")"
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

echo
echo "gh-athena outbound-scan self-test: ${PASS} passed, ${FAIL} failed"
[ "${FAIL}" -eq 0 ]
