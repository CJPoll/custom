#!/usr/bin/env bash
# Self-test for glab-athena's outbound scan (DND-1938).
#
# The defect this pins: glab-athena sent MR, issue, note and release text to a
# PUBLIC GitLab project with no scan, so a work-domain value in a description
# went out and nothing said so. gh-athena has scanned the same text on GitHub
# since DND-699. Now every glab-athena write that carries free text is scanned
# by ai/bin/outbound-scan, through the same rules as gh-athena (one shared
# library, ai/lib/outbound-text-scan.sh), when its target project reads public
# or internal. An unreadable visibility refuses (COULD NOT LOOK, never read as
# private).
#
# NO NETWORK, EVER. `glab` is a stub on PATH. It answers the visibility reads
# (`api [--hostname H] projects/<ref>` and `api groups/<ref>`) from fixture
# files and records every other call as a SEND. A refusal case asserts that no
# SEND happened. The Athena token comes from a fixture file; the overlay is a
# fixture with one synthetic pattern under mktemp -d.
#
# Gated: ai/bin/harness-gate runs every tracked **/self-test.sh.
#
# Run against another copy of the wrapper (old-vs-new evidence) with
#   GLAB_ATHENA_UNDER_TEST=/path/to/glab-athena bash ai/test/glab-athena-outbound/self-test.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
AI_DIR="$(cd "${HERE}/../.." && pwd -P)"
WRAPPER="${GLAB_ATHENA_UNDER_TEST:-${AI_DIR}/bin/glab-athena}"

TMP="$(mktemp -d)" || { echo "FAIL: mktemp"; exit 1; }
trap 'rm -rf "${TMP}"' EXIT INT TERM
PASS=0; FAIL=0
ok()  { printf '  ok    %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  FAIL  %s\n        %s\n' "$1" "$2"; FAIL=$((FAIL+1)); }

TOKEN="SYNTH-TOKEN-1"

# ---- hermetic environment ---------------------------------------------------
for v in $(env | sed -n 's/^\(GIT_CONFIG_\(KEY\|VALUE\)_[0-9]*\)=.*/\1/p'); do unset "$v"; done
unset GIT_CONFIG_COUNT GIT_CONFIG_PARAMETERS GIT_DIR GIT_WORK_TREE ATHENA_OUTBOUND_WAIVE \
  GLAB_ATHENA_MERGE_DRY_RUN GLAB_ATHENA_GIT_DRY_RUN XDG_STATE_HOME
export HOME="${TMP}/home"; mkdir -p "${HOME}"
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL="${TMP}/gitconfig"
printf '[user]\n\tname = t\n\temail = t@t\n[init]\n\tdefaultBranch = main\n' > "${GIT_CONFIG_GLOBAL}"

FAKE_TOKEN="glpat-SELFTESTFAKETOKEN0000"
printf '%s\n' "${FAKE_TOKEN}" > "${TMP}/token"; chmod 600 "${TMP}/token"
export GITLAB_ATHENA_TOKEN_FILE="${TMP}/token"

mkdir -p "${TMP}/bin"
export STUB_LOG="${TMP}/calls.log" STUB_VIS="${TMP}/vis"
# The stub glab. A visibility read answers from ${STUB_VIS}.<ref> (the ref as
# given, `/` and `%` turned into `_`), else ${STUB_VIS}.default; an empty or
# missing fixture is a failed read (exit 1). Every other call is a SEND: it is
# logged, and the content of each file glab would read (`-F k=@f`, `--input f`,
# `--notes-file f`) is echoed so a replaced stdin is observable.
cat > "${TMP}/bin/glab" <<'STUB'
#!/usr/bin/env bash
[ "${GITLAB_TOKEN:-}" = "glpat-SELFTESTFAKETOKEN0000" ] || { echo "stub: GITLAB_TOKEN not the Athena token" >&2; exit 97; }
printf '%s\n' "$*" >> "${STUB_LOG}"
# DND-2006: the repo-override variables glab would read, as glab sees them.
printf 'GITLAB_REPO=%s GITLAB_HEAD_REPO=%s\n' "${GITLAB_REPO-<unset>}" "${GITLAB_HEAD_REPO-<unset>}" >> "${STUB_LOG}.env"
args=("$@")
if [ "${args[0]:-}" = api ] && [ "${args[1]:-}" = --hostname ]; then args=(api "${args[@]:3}"); fi
if [ "${#args[@]}" = 2 ] && [ "${args[0]}" = api ] && [[ "${args[1]}" =~ ^(projects|groups)/[^/]+$ ]]; then
  ref="$(printf '%s' "${args[1]#*/}" | tr '/%' '__')"
  f="${STUB_VIS}.${ref}"; [ -e "$f" ] || f="${STUB_VIS}.default"
  if [ -s "$f" ]; then cat "$f"; exit 0; fi
  echo "stub: 404 Project Not Found" >&2; exit 1
fi
prev=""
for a in "$@"; do
  case "$prev" in
    -F|--field|--form) [[ "$a" == *=@* ]] && { printf 'stub-body:'; cat "${a#*=@}"; } ;;
    --input|--notes-file) printf 'stub-body:'; cat "$a" ;;
  esac
  case "$a" in
    -F*=@*|--field=*=@*) printf 'stub-body:'; cat "${a#*=@}" ;;
    --input=*) printf 'stub-body:'; cat "${a#--input=}" ;;
    --notes-file=*) printf 'stub-body:'; cat "${a#--notes-file=}" ;;
  esac
  prev="$a"
done
echo "stub: SENT $*"
exit 0
STUB
chmod +x "${TMP}/bin/glab"
# DND-1647: a guard stands behind every gh/glab stub on PATH, so a stub that is
# missing or not executable fails the suite instead of reaching the real CLI.
. "${HERE}/../../lib/forge-stub-guard.sh"
fsg_arm "${TMP}/forge-guard"
fsg_require_stubs "${TMP}/bin" glab
export PATH="${TMP}/bin:${PATH}"

# A fixture overlay with one synthetic pattern, git-backed (the committed floor).
OVERLAY="${TMP}/overlay"
mkdir -p "${OVERLAY}/outbound" && chmod 700 "${OVERLAY}"
printf '{"kind":"athena-private-overlay","schema":1}\n' > "${OVERLAY}/athena-overlay.json"
printf 'synth-token\tSYNTH-TOKEN-[0-9]+\n' > "${OVERLAY}/outbound/patterns.tsv"
git -C "${OVERLAY}" init -q && git -C "${OVERLAY}" add -A && git -C "${OVERLAY}" commit -q -m overlay
export ATHENA_PRIVATE_ROOT="${OVERLAY}"

WORK="${TMP}/work"; mkdir -p "${WORK}"

vis() { # vis <ref|default> <public|internal|private|raw:<json>|none>
  local f="${STUB_VIS}.$(printf '%s' "$1" | tr '/%' '__')"
  case "$2" in
    none) : > "$f" ;;
    raw:*) printf '%s\n' "${2#raw:}" > "$f" ;;
    *) printf '{"id":7000001,"visibility":"%s"}\n' "$2" > "$f" ;;
  esac
}
reset_vis() { rm -f "${STUB_VIS}".*; vis default public; }

# gla <args...> : run the wrapper in WORK. Sets OUT (stdout+stderr), RC, CALLS.
gla() {
  : > "${STUB_LOG}"
  OUT="$(cd "${WORK}" && "${WRAPPER}" "$@" 2>&1)"; RC=$?
  CALLS="$(cat "${STUB_LOG}")"
}
# gla_in <stdin text> <args...> : the same, with <stdin text> on stdin.
gla_in() {
  local input="$1"; shift
  : > "${STUB_LOG}"
  OUT="$(cd "${WORK}" && printf '%s\n' "${input}" | "${WRAPPER}" "$@" 2>&1)"; RC=$?
  CALLS="$(cat "${STUB_LOG}")"
}
sent() { [[ "${OUT}" == *"stub: SENT"* ]]; }
# The matched text never appears in anything but the stub's echo of what glab
# received (a body glab was allowed to send).
no_literal() { [ "$(printf '%s\n' "${OUT}" | grep -v '^stub-body:' | grep -c -- "${TOKEN}")" = 0 ]; }
refused_hit() { [ "${RC}" = 1 ] && ! sent && [[ "${OUT}" == *"REFUSED"* ]] && [[ "${OUT}" == *"label=synth-token"* ]] \
  && [[ "${OUT}" == *"PUBLIC project"* ]] && [[ "${OUT}" == *"Fix:"* ]] && no_literal; }
read_was() { [[ "${CALLS}" == *"$1"* ]]; }
# lib_guard <args...> : runs glos_guard straight from the library, as the
# wrapper calls it after isolation, and prints "stub: SENT" when it passes.
# For the merge commands, whose wrapper path the merge guard (DND-742) refuses
# first without an MR fixture; the scan runs after it on a pinned, gated merge.
lib_guard() {
  : > "${STUB_LOG}"; mkdir -p "${TMP}/cfg"
  OUT="$(cd "${WORK}" && FCI_CFG_DIR="${TMP}/cfg" GITLAB_TOKEN="${FAKE_TOKEN}" \
    bash -c 'set -eu; . "$1"; shift; glos_guard "$@"; echo "stub: SENT (the guard passed)"' _ "${AI_DIR}/lib/glab-outbound-scan.sh" "$@" 2>&1)"; RC=$?
  CALLS="$(cat "${STUB_LOG}")"
}

printf 'body with %s inside\n' "${TOKEN}" > "${TMP}/body-hit.md"
printf 'a clean body\n' > "${TMP}/body-clean.md"

echo "glab-athena outbound-scan self-test"
echo "wrapper: ${WRAPPER}"
echo
reset_vis

echo "--- a PUBLIC project with a planted value: refused before glab sends ---"
gla mr create --title "a title" --description "x${TOKEN}" --target-branch main
if refused_hit && read_was "api projects/:id"; then ok "mr create --description refused (visibility read as Athena)"; else bad "mr create --description" "rc=${RC} calls=[${CALLS}] ${OUT}"; fi

echo "--- the same text to a PRIVATE project is sent unscanned ---"
vis default private
gla mr create --title "a title" --description "x${TOKEN}" --target-branch main
if [ "${RC}" = 0 ] && sent && [[ "${OUT}" != *"outbound-scan:"* ]]; then ok "private project not scanned"; else bad "private project" "rc=${RC} ${OUT}"; fi
reset_vis

echo "--- an INTERNAL project is scanned (any signed-in gitlab.com user reads it) ---"
vis default internal
gla mr note 5 -m "x${TOKEN}"
if refused_hit; then ok "internal project scanned"; else bad "internal project" "rc=${RC} ${OUT}"; fi
reset_vis

echo "--- an unreadable visibility refuses: COULD NOT LOOK, never read as private ---"
vis default none
gla mr create --description "a clean body"
if [ "${RC}" = 3 ] && ! sent && [[ "${OUT}" == *"COULD NOT LOOK"* ]] && [[ "${OUT}" == *"Fix:"* ]]; then ok "failed read refused"; else bad "failed read" "rc=${RC} ${OUT}"; fi
vis default 'raw:{"id":1}'
gla issue note 3 -m "a clean note"
if [ "${RC}" = 3 ] && ! sent && [[ "${OUT}" == *"COULD NOT LOOK"* ]]; then ok "a read with no visibility refused"; else bad "no visibility field" "rc=${RC} ${OUT}"; fi
vis default 'raw:{"visibility":"secret-ish"}'
gla issue note 3 -m "a clean note"
if [ "${RC}" = 3 ] && ! sent && [[ "${OUT}" == *"secret-ish"* ]]; then ok "an unknown visibility value refused"; else bad "unknown visibility value" "rc=${RC} ${OUT}"; fi
reset_vis

echo "--- every spelling and every text-bearing command is scanned ---"
for argv in "mr create --title x${TOKEN}" "mr create -t x${TOKEN}" "mr create -tx${TOKEN}" "mr create -t=x${TOKEN}" \
  "mr create --title=x${TOKEN}" "mr create -d x${TOKEN}" "mr create --description=x${TOKEN}" "mr new -d x${TOKEN}" \
  "mr update 5 -d x${TOKEN}" "mr update 5 --title x${TOKEN}" "mr note 5 -m x${TOKEN}" "mr note 5 --message=x${TOKEN}" \
  "mr comment 5 -m x${TOKEN}" \
  "issue create -t x${TOKEN}" "issue new -d x${TOKEN}" "issue update 3 --description x${TOKEN}" \
  "issue note 3 -m x${TOKEN}" "issue comment 3 --message x${TOKEN}" \
  "incident note 3 -m x${TOKEN}" "incident comment 3 --message=x${TOKEN}" \
  "mr create -l -t -d x${TOKEN}" "mr create --label --title --description x${TOKEN}" \
  "mr update 5 -a -t -d x${TOKEN}" "issue create -l -t -d x${TOKEN}" "release create v1 -a -n -N x${TOKEN}" \
  "release create v1 --assets-links x${TOKEN}" \
  "release create v1 --notes x${TOKEN}" "release create v1 -N x${TOKEN}" "release create v1 --name x${TOKEN}" \
  "release create v1 -T x${TOKEN}"; do
  # shellcheck disable=SC2086
  gla ${argv}
  if refused_hit; then ok "refused: ${argv%%x${TOKEN}}"; else bad "refused: ${argv%%x${TOKEN}}" "rc=${RC} calls=[${CALLS}] ${OUT}"; fi
done
MV=merge
for argv in "mr ${MV} 5 --squash-message x${TOKEN}" "mr ${MV} 5 -m x${TOKEN}" "mr accept 5 --message=x${TOKEN}"; do
  # shellcheck disable=SC2086
  lib_guard ${argv}
  if refused_hit; then ok "refused (library): ${argv%%x${TOKEN}}"; else bad "refused (library): ${argv%%x${TOKEN}}" "rc=${RC} calls=[${CALLS}] ${OUT}"; fi
done
lib_guard mr "${MV}" 5 -d -s --sha 0123abc -m "clean"
if [ "${RC}" = 0 ] && sent && [[ "${OUT}" == *"CLEAN mode=text"* ]]; then ok "a clean merge message passes (library), -d/-s stay switches"; else bad "clean merge message" "rc=${RC} ${OUT}"; fi
gla mr note 5 -m "clean" -m "x${TOKEN}"
if refused_hit; then ok "every occurrence is scanned (last dirty)"; else bad "repeat" "rc=${RC} ${OUT}"; fi
gla mr create -yd "x${TOKEN}"
if refused_hit; then ok "a cluster is read letter by letter: -y a switch, -d the description (DND-1976)"; else bad "cluster" "rc=${RC} ${OUT}"; fi
gla mr create -m milestone-1 --description "clean"
if [ "${RC}" = 0 ] && sent && [[ "${OUT}" == *"outbound-scan: CLEAN mode=text"* ]]; then ok "a clean description is sent, CLEAN shown"; else bad "clean send" "rc=${RC} ${OUT}"; fi

echo "--- a file and stdin are scanned, and glab gets the scanned copy ---"
gla release create v1 --notes-file "${TMP}/body-hit.md"
if refused_hit; then ok "release --notes-file <file> refused"; else bad "notes-file hit" "rc=${RC} ${OUT}"; fi
gla release create v1 -F "${TMP}/body-hit.md"
if refused_hit; then ok "release -F <file> refused"; else bad "-F file hit" "rc=${RC} ${OUT}"; fi
gla_in "from stdin ${TOKEN}" release create v1 -F -
if refused_hit; then ok "release -F - (stdin) refused"; else bad "-F stdin hit" "rc=${RC} ${OUT}"; fi
gla_in "clean stdin notes" release create v1 --notes-file -
if [ "${RC}" = 0 ] && sent && [[ "${OUT}" == *"stub-body:clean stdin notes"* ]] && [[ "${CALLS}" != *"--notes-file -"* ]]; then
  ok "clean stdin notes reach glab as the scanned copy"
else
  bad "clean stdin notes" "rc=${RC} calls=[${CALLS}] ${OUT}"
fi
gla release create v1 --notes-file "${TMP}/body-clean.md"
if [ "${RC}" = 0 ] && sent && [[ "${CALLS}" != *"${TMP}/body-clean.md"* ]] && [[ "${OUT}" == *"stub-body:a clean body"* ]]; then
  ok "glab is handed the scanned copy, not the original path"
else
  bad "copy handed" "calls=[${CALLS}] ${OUT}"
fi
gla release create v1 --notes-file "${TMP}/no-such-file"
if [ "${RC}" = 3 ] && ! sent && [[ "${OUT}" == *"is not readable"* ]] && [[ "${OUT}" == *"Fix:"* ]]; then ok "an unreadable notes file refused"; else bad "unreadable file" "rc=${RC} ${OUT}"; fi

echo "--- DND-1976: the argv is read as glab's pflag reads it (the pinned glab table) ---"
# glab (pflag) gives --ref the next word, so `--ref -n -F <file>` is ref `-n`
# and notes read from <file>. The old parse did not know --ref takes a value,
# read `-F` as the notes text and <file> as a positional: the file went out
# unscanned.
gla release create v1 --ref -n -F "${TMP}/body-hit.md"
if refused_hit && [[ "${OUT}" == *"notes-file:1 label=synth-token"* ]]; then
  ok "DND-1976 regression (glab): release create --ref -n -F <file> scans the file"
else
  bad "DND-1976 regression (glab): release create --ref -n -F <file>" "rc=${RC} calls=[${CALLS}] ${OUT}"
fi
gla release create v1 -r -N --notes-file "${TMP}/body-hit.md"
if refused_hit; then ok "-r -N --notes-file <file>: the file is scanned"; else bad "-r -N --notes-file" "rc=${RC} ${OUT}"; fi
gla release create v1 --ref -- -F "${TMP}/body-hit.md"
if refused_hit; then ok "--ref -- -F <file>: -- is the ref, the file is scanned"; else bad "--ref --" "rc=${RC} ${OUT}"; fi
for argv in "mr update 5 -l -- -t x${TOKEN}" "mr update 5 -l -- --title=x${TOKEN}" "mr update 5 -l -t -d x${TOKEN}" "mr create -l --label -d x${TOKEN}"; do
  # shellcheck disable=SC2086
  gla ${argv}
  if refused_hit; then ok "scanned: ${argv%%x${TOKEN}}"; else bad "scanned: ${argv%%x${TOKEN}}" "rc=${RC} ${OUT}"; fi
done
for argv in "mr update 5 -l -R -t x${TOKEN}" "mr update 5 -l --repo -t x${TOKEN}" "mr create -l --target-project -t x${TOKEN}" \
  "release create v1 --ref -R -n x${TOKEN}" "release create v1 --ref -F x${TOKEN}"; do
  # shellcheck disable=SC2086
  gla ${argv}
  if [ "${RC}" = 3 ] && ! sent && [[ "${OUT}" == *"looks like a flag"* ]] && [[ "${OUT}" == *"Fix:"* ]] && no_literal; then ok "a value naming a repo or file flag refused: ${argv%%x${TOKEN}}"; else bad "value names repo/file: ${argv%%x${TOKEN}}" "rc=${RC} ${OUT}"; fi
done
echo "--- DND-1976: a flag the pinned table lacks, before a word that reads as a flag, is refused ---"
for argv in "mr note 5 --frobnicate -m x${TOKEN}" "mr update 5 --frobnicate -- -t x${TOKEN}" \
  "mr create --frobnicate --target-project -t x${TOKEN}" "mr create -Zd x${TOKEN}" "mr create -Z -d x${TOKEN}"; do
  # shellcheck disable=SC2086
  gla ${argv}
  if [ "${RC}" = 3 ] && ! sent && [[ "${OUT}" == *"not a flag of"* ]] && [[ "${OUT}" == *"Fix:"* ]] && no_literal; then ok "ambiguous refused: ${argv%%x${TOKEN}}"; else bad "ambiguous: ${argv%%x${TOKEN}}" "rc=${RC} ${OUT}"; fi
done
gla mr note 5 --frobnicate value -m "x${TOKEN}"
if refused_hit; then ok "a flag the table lacks, before a plain word, is read as a switch and the text is scanned"; else bad "unknown then plain" "rc=${RC} ${OUT}"; fi
gla mr create --frobnicate "x${TOKEN}"
if refused_hit && [[ "${OUT}" == *"argument:1 label=synth-token"* ]]; then ok "with no text flag, the word after a flag the table lacks is scanned (a newer text flag)"; else bad "unknown text flag" "rc=${RC} ${OUT}"; fi
gla release create v1 --ref main -n "clean" -F "${TMP}/body-clean.md"
if [ "${RC}" = 0 ] && sent; then ok "valued flags with plain values, then text and a file, are sent"; else bad "plain values" "rc=${RC} ${OUT}"; fi
gla mr create --draft -t "clean title" -d "x${TOKEN}"
if refused_hit; then ok "a switch before a text flag is not refused, and the text is scanned"; else bad "switch then text" "rc=${RC} ${OUT}"; fi
gla mr --help -d "x${TOKEN}"
if [ "${RC}" = 0 ] && [[ "${OUT}" != *"outbound-scan:"* ]]; then ok "a help flag before the verb passes (cobra shows the help)"; else bad "mr --help" "rc=${RC} ${OUT}"; fi
NT="${TMP}/no-table"; git init -q "${NT}"; mkdir -p "${NT}/ai"
cp -r "${AI_DIR}/bin" "${AI_DIR}/lib" "${NT}/ai/"
rm -f "${NT}/ai/lib/glab-flag-table.sh"
OUT="$(cd "${WORK}" && : > "${STUB_LOG}" && "${NT}/ai/bin/glab-athena" mr note 5 -m "clean" 2>&1)"; RC=$?
if [ "${RC}" = 3 ] && ! sent && [[ "${OUT}" == *"glab-flag-table.sh"* ]] && [[ "${OUT}" == *"Fix:"* ]]; then ok "no table: a judged write refused, named"; else bad "no table" "rc=${RC} ${OUT}"; fi

echo "--- the target is every project the write can reach ---"
vis default private
vis "synth-group%2Fpub" public
vis "synth-group%2Fpriv" private
gla mr note 5 -R synth-group/pub -m "x${TOKEN}"
if refused_hit && read_was "api projects/synth-group%2Fpub"; then ok "-R names the project whose visibility is read"; else bad "-R" "rc=${RC} calls=[${CALLS}] ${OUT}"; fi
gla -R synth-group/pub mr note 5 -m "x${TOKEN}"
if refused_hit && read_was "api projects/synth-group%2Fpub"; then ok "-R before the command path is read too"; else bad "-R prepath" "rc=${RC} calls=[${CALLS}] ${OUT}"; fi
gla mr note 5 --repo=https://gitlab.com/synth-group/pub.git -m "x${TOKEN}"
if refused_hit && read_was "api projects/synth-group%2Fpub"; then ok "-R as a full URL"; else bad "-R URL" "rc=${RC} calls=[${CALLS}] ${OUT}"; fi
gla mr note 5 -R git@gitlab.com:synth-group/pub.git -m "x${TOKEN}"
if refused_hit && read_was "api projects/synth-group%2Fpub"; then ok "-R as a git URL"; else bad "-R git URL" "rc=${RC} calls=[${CALLS}] ${OUT}"; fi
gla mr note 5 -R synth-group/priv -m "x${TOKEN}"
if [ "${RC}" = 0 ] && sent; then ok "-R to a PRIVATE project is not scanned"; else bad "-R private" "rc=${RC} ${OUT}"; fi

echo "--- DND-2006 sweep: GITLAB_REPO cannot split the read from the write ---"
# glab 1.92 reads GITLAB_REPO when -R is empty or absent, and so does
# `glab api projects/:id` (measured 2026-10-04). glab-athena scrubs every
# GITLAB_* variable before the guard and glab run, so the guard's
# projects/:id read and glab's write both resolve the checkout. This pins that:
# with GITLAB_REPO naming a PUBLIC project, neither call sees it.
: > "${STUB_LOG}.env"
: > "${STUB_LOG}"
OUT="$(cd "${WORK}" && GITLAB_REPO=synth-group/pub GITLAB_HEAD_REPO=synth-group/pub "${WRAPPER}" mr note 5 -R '' -m "x${TOKEN}" 2>&1)"; RC=$?
CALLS="$(cat "${STUB_LOG}")"; ENVS="$(cat "${STUB_LOG}.env")"
if [ "${RC}" = 0 ] && sent && read_was "api projects/:id" && ! read_was "synth-group%2Fpub" \
   && [ -n "${ENVS}" ] && [[ "${ENVS}" != *"synth-group"* ]]; then
  ok "GITLAB_REPO=<public> with -R '': scrubbed, so the read and the write both resolve the checkout"
else
  bad "GITLAB_REPO scrubbed" "rc=${RC} calls=[${CALLS}] env=[${ENVS}] ${OUT}"
fi
gla mr create --target-project synth-group/pub -d "x${TOKEN}"
if refused_hit && read_was "api projects/synth-group%2Fpub"; then ok "mr create --target-project is a target"; else bad "--target-project" "rc=${RC} calls=[${CALLS}] ${OUT}"; fi
vis default public
gla mr create --label -R synth-group/priv -d "x${TOKEN}"
if [ "${RC}" = 3 ] && ! sent && [[ "${OUT}" == *"looks like a flag"* ]]; then ok "an -R that is --label's value is refused, not read as a target (DND-1976)"; else bad "-R as a label value" "rc=${RC} calls=[${CALLS}] ${OUT}"; fi
vis default private
gla mr note https://gitlab.com/synth-group/pub/-/merge_requests/3 -m "x${TOKEN}"
if refused_hit && read_was "api projects/synth-group%2Fpub"; then ok "an MR URL to a PUBLIC project is scanned from a PRIVATE cwd"; else bad "MR URL" "rc=${RC} calls=[${CALLS}] ${OUT}"; fi
gla mr note -R synth-group/priv https://gitlab.com/synth-group/pub/-/merge_requests/3 -m "x${TOKEN}"
if refused_hit; then ok "-R private plus a PUBLIC URL is scanned"; else bad "-R + URL" "rc=${RC} ${OUT}"; fi
gla mr note https://gitlab.com/ -m "x${TOKEN}"
if refused_hit && [[ "${OUT}" == *"scanning as PUBLIC"* ]]; then ok "an unparsable URL is scanned as PUBLIC"; else bad "unparsable URL" "rc=${RC} ${OUT}"; fi
vis "synth-group%2Fmissing" none
gla mr note 5 -R synth-group/missing -m "clean"
if [ "${RC}" = 3 ] && ! sent && [[ "${OUT}" == *"COULD NOT LOOK"* ]] && [[ "${OUT}" == *"synth-group/missing"* ]]; then ok "an unreadable -R project refused, named"; else bad "unreadable -R" "rc=${RC} ${OUT}"; fi
gla --verbose mr note 5 -m "x${TOKEN}"
if [ "${RC}" = 3 ] && ! sent && [[ "${OUT}" == *"Fix:"* ]]; then ok "a flag before the command path is refused"; else bad "prepath flag" "rc=${RC} ${OUT}"; fi
reset_vis

echo "--- api writes: fields, @file, @- (stdin), --input and the query string ---"
gla api -X POST projects/:id/merge_requests/5/notes -f "body=x${TOKEN}"
if refused_hit; then ok "api -f body refused"; else bad "api -f" "rc=${RC} calls=[${CALLS}] ${OUT}"; fi
gla api projects/:id/issues/3/notes --field "body=x${TOKEN}"
if refused_hit; then ok "api --field (implied POST) refused"; else bad "api --field" "rc=${RC} ${OUT}"; fi
gla api -X PUT projects/:id/merge_requests/5 -f "description=x${TOKEN}"
if refused_hit; then ok "api PUT merge_requests refused"; else bad "api PUT" "rc=${RC} ${OUT}"; fi
gla api projects/:id/merge_requests/5/discussions -F "body=@${TMP}/body-hit.md"
if refused_hit; then ok "api -F body=@file refused"; else bad "api @file" "rc=${RC} ${OUT}"; fi
gla_in "from stdin ${TOKEN}" api projects/:id/merge_requests/5/notes -F body=@-
if refused_hit; then ok "api -F body=@- (stdin) refused"; else bad "api @-" "rc=${RC} ${OUT}"; fi
gla_in "clean stdin note" api projects/:id/merge_requests/5/notes -F body=@-
if [ "${RC}" = 0 ] && sent && [[ "${OUT}" == *"stub-body:clean stdin note"* ]] && [[ "${CALLS}" != *"body=@-"* ]]; then ok "a clean stdin field reaches glab as the scanned copy"; else bad "api @- clean" "rc=${RC} calls=[${CALLS}] ${OUT}"; fi
gla_in "{\"body\":\"from stdin ${TOKEN}\"}" api -X POST projects/:id/issues/3/notes --input -
if refused_hit; then ok "api --input - (stdin) refused"; else bad "api --input -" "rc=${RC} ${OUT}"; fi
gla api -X POST "projects/:id/issues/3/notes?body=x${TOKEN}"
if refused_hit; then ok "text in the query string refused"; else bad "query string" "rc=${RC} ${OUT}"; fi
vis "synth-group%2Fpriv" private
gla api -X POST projects/synth-group%2Fpriv/issues/3/notes -f "body=x${TOKEN}"
if [ "${RC}" = 0 ] && sent && read_was "api projects/synth-group%2Fpriv"; then ok "api to a PRIVATE project not scanned"; else bad "api private" "rc=${RC} calls=[${CALLS}] ${OUT}"; fi
gla api -X POST projects/synth-group%2Fpriv/../7/issues/3/notes -f "body=clean"
if [ "${RC}" = 3 ] && ! sent && [[ "${OUT}" == *"Fix:"* ]]; then ok "an endpoint whose project segment does not route as spelled is refused"; else bad "dot segments" "rc=${RC} ${OUT}"; fi
vis "synth-group" public
gla api -X POST groups/synth-group/epics/1/notes -f "body=x${TOKEN}"
if refused_hit && read_was "api groups/synth-group"; then ok "a group write reads the group's visibility"; else bad "group" "rc=${RC} calls=[${CALLS}] ${OUT}"; fi
gla api -X POST snippets -f "content=x${TOKEN}"
if refused_hit && [[ "${OUT}" == *"scanning as PUBLIC"* ]]; then ok "a write with no nameable project is scanned as PUBLIC"; else bad "snippets" "rc=${RC} ${OUT}"; fi
gla api graphql -f "query=mutation { createNote(input: {noteableId: \"gid://gitlab/MergeRequest/1\", body: \"x${TOKEN}\"}) { errors } }"
if refused_hit; then ok "a GraphQL mutation is scanned as PUBLIC"; else bad "graphql mutation" "rc=${RC} ${OUT}"; fi
gla api graphql -f "query=query { project(fullPath: \"x${TOKEN}\") { id } }"
if [ "${RC}" = 0 ] && sent; then ok "a GraphQL query (a read) is not scanned"; else bad "graphql query" "rc=${RC} ${OUT}"; fi
# (A GraphQL query from stdin is refused first by the merge guard, which
# cannot read it without consuming it; a file is the supported form.)
printf 'mutation { createNote(input: {body: "x%s"}) { errors } }\n' "${TOKEN}" > "${TMP}/gql-hit.graphql"
printf 'mutation { createNote(input: {body: "clean"}) { errors } }\n' > "${TMP}/gql-clean.graphql"
gla api graphql -F "query=@${TMP}/gql-hit.graphql"
if refused_hit; then ok "a GraphQL mutation read from a file is scanned"; else bad "graphql file" "rc=${RC} ${OUT}"; fi
gla api graphql -F "query=@${TMP}/gql-clean.graphql"
if [ "${RC}" = 0 ] && sent && [[ "${OUT}" == *"stub-body:mutation"* ]] && [[ "${CALLS}" != *"${TMP}/gql-clean.graphql"* ]]; then ok "a clean GraphQL mutation reaches glab as the scanned copy"; else bad "graphql file clean" "rc=${RC} calls=[${CALLS}] ${OUT}"; fi
for ep in projects/7/wikis/graphql projects/7/repository/files/graphql projects/7/wikis/graphql.md; do
  gla api -X PUT "${ep}" -f "content=x${TOKEN}"
  if refused_hit; then ok "a REST path ending in graphql is a REST write: ${ep}"; else bad "REST graphql-suffix ${ep}" "rc=${RC} ${OUT}"; fi
done
gla api -X POST projects/:id/uploads --form "file=@${TMP}/body-hit.md"
if refused_hit; then ok "a --form upload is scanned"; else bad "--form hit" "rc=${RC} ${OUT}"; fi
gla api -X POST projects/:id/uploads --form "file=@${TMP}/body-clean.md"
if [ "${RC}" = 0 ] && sent && [[ "${OUT}" == *"stub-body:a clean body"* ]] && [[ "${CALLS}" != *"${TMP}/body-clean.md"* ]] \
   && [[ "${CALLS}" =~ file=@[^\ ]*/outbound-scan/file-0/body-clean\.md ]]; then
  ok "a --form upload is handed the scanned copy under the source's file name"
else
  bad "--form clean" "rc=${RC} calls=[${CALLS}] ${OUT}"
fi
gla api -X POST "snippets?content=x${TOKEN}"
if refused_hit && [[ "${OUT}" == *"'snippets' names no project"* ]]; then ok "a query string is scanned and never echoed"; else bad "query echo" "rc=${RC} ${OUT}"; fi
vis "synth-group%2Fpriv" private
vis 4242 public
gla api -X POST projects/synth-group%2Fpriv/merge_requests -f target_project_id=4242 -f "description=x${TOKEN}"
if refused_hit && read_was "api projects/4242"; then ok "api target_project_id is a target"; else bad "target_project_id" "rc=${RC} calls=[${CALLS}] ${OUT}"; fi
gla api projects/:id/merge_requests/5/notes
if [ "${RC}" = 0 ] && sent && [[ "${CALLS}" != *"api projects/:id"$'\n'* ]] && [ "$(grep -c . <<<"${CALLS}")" = 1 ]; then ok "an api GET is untouched (no visibility read)"; else bad "api GET" "rc=${RC} calls=[${CALLS}] ${OUT}"; fi

echo "--- DND-2009: full-URL scheme and host, placeholders glab fills, plain spelling ---"
# The cwd's project and synth-group%2Fpriv read PRIVATE; synth-group%2Fpub and
# everything else read PUBLIC. Each regression case was SENT by the code before
# DND-2009.
reset_vis
vis default private
vis "synth-group%2Fpub" public
vis "synth-group%2Fpriv" private
vis 4242 private
# refused3 <needle> : exit 3, nothing sent, a Fix:, and <needle> in the message.
refused3() { [ "${RC}" = 3 ] && ! sent && [[ "${OUT}" == *"REFUSED"* ]] && [[ "${OUT}" == *"Fix:"* ]] && [[ "${OUT}" == *"$1"* ]] && no_literal; }

# Gap 1: the scheme and host of a full URL. glab sends a full-URL endpoint to
# its own host, whatever the scheme's case and whatever --hostname says.
gla mr note "HTTPS://gitlab.com/synth-group/pub/-/merge_requests/1" -m "x${TOKEN}"
if refused_hit && read_was "api projects/synth-group%2Fpub"; then ok "DND-2009 regression: an upper-case-scheme MR URL names its project"; else bad "DND-2009 regression: HTTPS:// MR URL" "rc=${RC} calls=[${CALLS}] ${OUT}"; fi
gla mr note "https://GitLab.COM/synth-group/pub/-/merge_requests/1" -m "x${TOKEN}"
if refused_hit && read_was "api projects/synth-group%2Fpub" && [[ "${CALLS}" != *"--hostname"* ]]; then ok "DND-2009: an MR URL's host is case-folded"; else bad "DND-2009: GitLab.COM MR URL" "rc=${RC} calls=[${CALLS}] ${OUT}"; fi
gla api -X POST --hostname gitlab.com "https://public.example/api/v4/projects/4242/issues/3/notes" -f "body=x${TOKEN}"
if refused_hit && [[ "${OUT}" == *"public.example"* ]] && [[ "${OUT}" == *"scanning as PUBLIC"* ]]; then ok "DND-2009 regression: a full URL's own host decides, not --hostname"; else bad "DND-2009 regression: full URL vs --hostname" "rc=${RC} calls=[${CALLS}] ${OUT}"; fi
gla api -X POST "HTTPS://public.example/api/graphql" -f "query=query { project(fullPath: \"x${TOKEN}\") { id } }"
if refused_hit && [[ "${OUT}" == *"scanning as PUBLIC"* ]]; then ok "DND-2009 regression: a full URL to another host is never a GraphQL read"; else bad "DND-2009 regression: other-host graphql" "rc=${RC} calls=[${CALLS}] ${OUT}"; fi
gla api -X POST "HTTPS://GitLab.com/api/v4/projects/synth-group%2Fpriv/issues/3/notes" -f "body=x${TOKEN}"
if [ "${RC}" = 0 ] && sent && read_was "api projects/synth-group%2Fpriv" && [[ "${CALLS}" != *"--hostname"* ]]; then ok "DND-2009: an upper-case gitlab.com URL reads its project's visibility"; else bad "DND-2009: HTTPS://GitLab.com api" "rc=${RC} calls=[${CALLS}] ${OUT}"; fi
# A host is folded as ASCII only: bash's ${x,,} in a UTF-8 locale folds U+0130
# to `i`, and glab sends gİtlab.com to an IDNA name, not gitlab.com.
gla api -X POST "https://gİtlab.com/api/v4/projects/synth-group%2Fpriv/issues/3/notes" -f "body=x${TOKEN}"
if refused_hit && [[ "${OUT}" == *"scanning as PUBLIC"* ]]; then ok "DND-2009 review regression: a non-ASCII host never folds into gitlab.com"; else bad "DND-2009 review regression: gİtlab.com URL" "rc=${RC} calls=[${CALLS}] ${OUT}"; fi
gla api -X POST --hostname gİtlab.com projects/synth-group%2Fpriv/issues/3/notes -f "body=x${TOKEN}"
if read_was "api --hostname gİtlab.com projects/synth-group%2Fpriv"; then ok "DND-2009 review regression: a non-ASCII --hostname is read on that host"; else bad "DND-2009 review regression: --hostname gİtlab.com" "rc=${RC} calls=[${CALLS}] ${OUT}"; fi
gla api -X POST --hostname GitLab.COM projects/synth-group%2Fpriv/issues/3/notes -f "body=x${TOKEN}"
if [ "${RC}" = 0 ] && sent && [ "$(head -n1 <<<"${CALLS}")" = "api projects/synth-group%2Fpriv" ]; then ok "DND-2009: --hostname GitLab.COM is gitlab.com"; else bad "DND-2009: --hostname GitLab.COM" "rc=${RC} calls=[${CALLS}] ${OUT}"; fi
gla mr note "https://gİtlab.com/synth-group/pub/-/merge_requests/1" -m "x${TOKEN}"
if refused_hit && read_was "api --hostname gİtlab.com projects/synth-group%2Fpub"; then ok "DND-2009: an MR URL's non-ASCII host is read on that host"; else bad "DND-2009: gİtlab.com MR URL" "rc=${RC} calls=[${CALLS}] ${OUT}"; fi
gla api -X POST "https://public.example/api/v4/projects/synth-group%2Fpriv/merge_requests" -f target_project_id=4242 -f "description=x${TOKEN}"
if refused_hit && [[ "${OUT}" == *"target_project_id field names a project on a host"* ]] && ! read_was "api projects/4242"; then ok "DND-2009: target_project_id under another host's URL is unknown"; else bad "DND-2009: target_project_id other host" "rc=${RC} calls=[${CALLS}] ${OUT}"; fi
gla api -X POST "https://gitlab.com/projects/synth-group%2Fpriv/issues/3/notes" -f "body=x${TOKEN}"
if refused_hit && [[ "${OUT}" == *"scanning as PUBLIC"* ]]; then ok "DND-2009: a gitlab.com URL outside /api/v4/ names no project"; else bad "DND-2009: URL without api/v4" "rc=${RC} calls=[${CALLS}] ${OUT}"; fi

# Gap 2: glab fills :branch, :fullpath, :group, :id, :namespace, :repo, :user
# and :username after the scan.
gla api -X POST projects/synth-group%2Fpub/issues/3/notes -F "body=:branch"
if refused3 "placeholder"; then ok "DND-2009 regression: a typed -F value glab fills is refused (PUBLIC)"; else bad "DND-2009 regression: -F :branch" "rc=${RC} calls=[${CALLS}] ${OUT}"; fi
gla api -X POST "projects/synth-group%2Fpub/issues/3/notes?body=on%20:namespace" -f "x=y"
if refused3 "placeholder"; then ok "DND-2009 regression: a placeholder in the endpoint query is refused (PUBLIC)"; else bad "DND-2009 regression: query :namespace" "rc=${RC} calls=[${CALLS}] ${OUT}"; fi
gla api -X POST projects/synth-group%2Fpriv/issues/:branch/notes -f "body=clean"
if refused3 "placeholder"; then ok "DND-2009 regression: a placeholder in the endpoint path is refused, even to a PRIVATE project"; else bad "DND-2009 regression: path :branch" "rc=${RC} calls=[${CALLS}] ${OUT}"; fi
vis ":namespace" private
gla api -X POST projects/:namespace/:repo/issues/3/notes -f "body=x${TOKEN}"
if refused3 "placeholder"; then ok "DND-2009 regression: a project segment glab fills across a / is refused"; else bad "DND-2009 regression: :namespace/:repo" "rc=${RC} calls=[${CALLS}] ${OUT}"; fi
gla api -X POST "projects/:id/issues/3/notes?x=:repo" -f "body=clean"
if refused3 "placeholder"; then ok "DND-2009: projects/:id still refuses a placeholder in its query"; else bad "DND-2009: :id + query :repo" "rc=${RC} calls=[${CALLS}] ${OUT}"; fi
gla api -X POST "https://public.example/api/v4/projects/:branch/notes" -f "body=clean"
if refused3 "placeholder"; then ok "DND-2009: a placeholder in a full URL to another host is refused"; else bad "DND-2009: other-host :branch" "rc=${RC} calls=[${CALLS}] ${OUT}"; fi
gla api -X POST projects/synth-group%2Fpriv/issues/:branch/approve
if refused3 "placeholder"; then ok "DND-2009: a path placeholder is refused on a write with no text"; else bad "DND-2009: field-less :branch" "rc=${RC} calls=[${CALLS}] ${OUT}"; fi
gla api -X POST groups/:group/epics/1/notes -f "body=clean"
if refused3 "placeholder"; then ok "DND-2009: groups/:group is refused (only projects/:id and :fullpath are read as filled)"; else bad "DND-2009: groups/:group" "rc=${RC} calls=[${CALLS}] ${OUT}"; fi
gla api -X POST projects/synth-group%2Fpub/issues/3/notes -F "body=:username"
if refused3 "placeholder"; then ok "DND-2009: -F :username is refused (PUBLIC)"; else bad "DND-2009: -F :username" "rc=${RC} calls=[${CALLS}] ${OUT}"; fi
gla api -X POST projects/synth-group%2Fpub/issues/3/notes -F "body=:idle" -f "x=:branch"
if [ "${RC}" = 0 ] && sent; then ok "DND-2009: :idle is no placeholder, and -f (raw) is never filled"; else bad "DND-2009: :idle / -f" "rc=${RC} calls=[${CALLS}] ${OUT}"; fi
gla api -X POST projects/synth-group%2Fpriv/issues/3/notes -F "body=:branch"
if [ "${RC}" = 0 ] && sent; then ok "DND-2009: a typed placeholder to a PRIVATE project passes"; else bad "DND-2009: -F :branch private" "rc=${RC} calls=[${CALLS}] ${OUT}"; fi
gla api -X POST projects/:fullpath/issues/3/notes -f "body=clean"
if [ "${RC}" = 0 ] && sent && read_was "api projects/:fullpath"; then ok "DND-2009: projects/:fullpath is read as glab fills it"; else bad "DND-2009: :fullpath" "rc=${RC} calls=[${CALLS}] ${OUT}"; fi

# Gap 3: the project segment is spelled plainly (no ., .. or empty segment,
# decoded or not).
vis "synth-group%2F..%2Fpriv" private
gla api -X POST "projects/synth-group%2F..%2Fpriv/issues/3/notes" -f "body=x${TOKEN}"
if refused3 "plainly"; then ok "DND-2009 regression: an escaped .. in the project segment is refused"; else bad "DND-2009 regression: %2F..%2F" "rc=${RC} calls=[${CALLS}] ${OUT}"; fi
vis "synth-group%2F.%2Fpriv" private
gla api -X POST "projects/synth-group%2F.%2Fpriv/issues/3/notes" -f "body=x${TOKEN}"
if refused3 "plainly"; then ok "DND-2009 regression: an escaped . in the project segment is refused"; else bad "DND-2009 regression: %2F.%2F" "rc=${RC} calls=[${CALLS}] ${OUT}"; fi
vis "synth-group%2F%2Fpriv" private
gla api -X POST "projects/synth-group%2F%2Fpriv/issues/3/notes" -f "body=x${TOKEN}"
if refused3 "plainly"; then ok "DND-2009 regression: an empty segment in the project segment is refused"; else bad "DND-2009 regression: %2F%2F" "rc=${RC} calls=[${CALLS}] ${OUT}"; fi
gla api -X POST "api/v4/projects/synth-group%2Fpriv/issues/3/notes" -f "body=x${TOKEN}"
if [ "${RC}" = 0 ] && sent && read_was "api projects/synth-group%2Fpriv"; then ok "DND-2009: an api/v4/ prefix is read as its project (glab sends it to /api/v4/api/v4/, a 404)"; else bad "DND-2009: api/v4 prefix" "rc=${RC} calls=[${CALLS}] ${OUT}"; fi

echo "--- DND-2012: every MR or issue reference form glab 1.92.1 reads names its project ---"
# glab's MRFromArgs (cmdutils.ParseGitLabURL) reads its positional with Go's
# url.Parse and takes it as a reference when the scheme is http, https or
# NONE and the URL has a host: so `//host/<group>/<project>/-/merge_requests/N`
# writes to <group>/<project>. The scan matched only http(s)://, judged the
# cwd's (private) project, and sent the text. The cwd here is PRIVATE.
gla mr note "//gitlab.com/synth-group/pub/-/merge_requests/1" -m "x${TOKEN}"
if refused_hit && read_was "api projects/synth-group%2Fpub"; then ok "DND-2012 regression: a scheme-less //host MR URL names its project (mr note)"; else bad "DND-2012 regression: //host mr note" "rc=${RC} calls=[${CALLS}] ${OUT}"; fi
gla mr update "//GitLab.COM/synth-group/pub/-/merge_requests/1" -d "x${TOKEN}"
if refused_hit && read_was "api projects/synth-group%2Fpub" && [[ "${CALLS}" != *"--hostname"* ]]; then ok "DND-2012 regression: a scheme-less MR URL's host is case-folded (mr update)"; else bad "DND-2012 regression: //GitLab.COM mr update" "rc=${RC} calls=[${CALLS}] ${OUT}"; fi
lib_guard mr "${MV}" "//gitlab.com/synth-group/pub/-/merge_requests/1" -m "x${TOKEN}"
if refused_hit && read_was "api projects/synth-group%2Fpub"; then ok "DND-2012 regression: a scheme-less MR URL names its project (mr ${MV}, library)"; else bad "DND-2012 regression: //host mr ${MV}" "rc=${RC} calls=[${CALLS}] ${OUT}"; fi
# Go's url.Parse puts what precedes the last @ of the authority in the
# userinfo; the host is what follows it.
gla mr note "//someone@gitlab.com/synth-group/pub/-/merge_requests/1" -m "x${TOKEN}"
if refused_hit && read_was "api projects/synth-group%2Fpub" && [[ "${CALLS}" != *"--hostname"* ]]; then ok "DND-2012 regression: userinfo is not part of the host"; else bad "DND-2012 regression: //user@host" "rc=${RC} calls=[${CALLS}] ${OUT}"; fi
gla mr note "https://someone@gitlab.com/synth-group/pub/-/merge_requests/1" -m "x${TOKEN}"
if refused_hit && read_was "api projects/synth-group%2Fpub" && [[ "${CALLS}" != *"--hostname"* ]]; then ok "DND-2012: userinfo in an https MR URL is not part of the host"; else bad "DND-2012: https://user@host" "rc=${RC} calls=[${CALLS}] ${OUT}"; fi
# glab's regex takes `<project>/merge_requests/N` without the /-/ too.
gla mr note "//gitlab.com/synth-group/pub/merge_requests/1" -m "x${TOKEN}"
if refused_hit && [[ "${OUT}" == *"scanning as PUBLIC"* ]]; then ok "DND-2012 regression: a scheme-less MR URL with no /-/ is scanned as PUBLIC"; else bad "DND-2012 regression: //host no /-/" "rc=${RC} calls=[${CALLS}] ${OUT}"; fi
# Go cuts the #fragment and the ?query before it reads the path.
gla mr note "//gitlab.com/synth-group/pub/-/merge_requests/1?from=/-/x#/-/y" -m "x${TOKEN}"
if refused_hit && read_was "api projects/synth-group%2Fpub"; then ok "DND-2012: the query and fragment are cut before the path is read"; else bad "DND-2012: query/fragment" "rc=${RC} calls=[${CALLS}] ${OUT}"; fi
gla mr note "//gitlab.com/synth-group/pub/merge_requests/1#/-/x" -m "x${TOKEN}"
if refused_hit && [[ "${OUT}" == *"scanning as PUBLIC"* ]] && ! read_was "synth-group%2Fpub"; then ok "DND-2012: a /-/ in the fragment is not read as the path's"; else bad "DND-2012: fragment /-/" "rc=${RC} calls=[${CALLS}] ${OUT}"; fi
gla mr note "//gitlab.com/synth-group/pub/merge_requests/1?x=/-/y" -m "x${TOKEN}"
if refused_hit && [[ "${OUT}" == *"scanning as PUBLIC"* ]] && ! read_was "synth-group%2Fpub"; then ok "DND-2012: a /-/ in the query is not read as the path's"; else bad "DND-2012: query /-/" "rc=${RC} calls=[${CALLS}] ${OUT}"; fi
# Go's url.Parse does not check UTF-8, so a byte that is not UTF-8 leaves the
# word a reference for glab. In a UTF-8 locale a bash regex `.` does not match
# that byte, and the review-round draft read such a word as no reference at
# all. The locale is pinned: the suite's own decides whether this can fail.
export LC_ALL=C.UTF-8
gla mr note $'https://gitlab.com/synth-group/pub/-/merge_requests/1/\xff' -m "x${TOKEN}"
if refused_hit && read_was "api projects/synth-group%2Fpub"; then ok "DND-2012 review regression: a non-UTF-8 byte in an MR URL still names its project"; else bad "DND-2012 review regression: \\xff in an MR URL" "rc=${RC} calls=[${CALLS}] ${OUT}"; fi
gla issue note $'https://gitlab.com/synth-group/pub/-/issues/1?\xff' -m "x${TOKEN}"
if refused_hit && read_was "api projects/synth-group%2Fpub"; then ok "DND-2012 review regression: a non-UTF-8 byte in an issue URL's query still names its project"; else bad "DND-2012 review regression: \\xff in an issue URL" "rc=${RC} calls=[${CALLS}] ${OUT}"; fi
unset LC_ALL
# A userinfo may hold a credential: the message never shows it.
gla mr note "//someone:SECRETPW@gitlab.com/synth-group/pub/merge_requests/1" -m "x${TOKEN}"
if refused_hit && [[ "${OUT}" == *"scanning as PUBLIC"* ]] && [[ "${OUT}" != *"SECRETPW"* ]]; then ok "DND-2012 review: a URL's userinfo is never echoed"; else bad "DND-2012 review: userinfo echoed" "rc=${RC} calls=[${CALLS}] ${OUT}"; fi
# Forms glab does NOT read as a reference (glrepo.FromURL needs a host): it
# reads them as a branch name in the -R or cwd project, so that project is
# the one judged. Probed read-only against glab 1.92.1 on 2026-10-04.
gla mr note "/synth-group/pub/-/merge_requests/1" -m "x${TOKEN}"
if [ "${RC}" = 0 ] && sent && read_was "api projects/:id" && ! read_was "synth-group%2Fpub"; then ok "DND-2012: a root-relative MR path is a branch name: the cwd project is judged"; else bad "DND-2012: root-relative" "rc=${RC} calls=[${CALLS}] ${OUT}"; fi
gla mr note "https:/gitlab.com/synth-group/pub/-/merge_requests/1" -m "x${TOKEN}"
if [ "${RC}" = 0 ] && sent && read_was "api projects/:id" && ! read_was "synth-group%2Fpub"; then ok "DND-2012: https:/ (one slash) has no host: the cwd project is judged"; else bad "DND-2012: https:/ one slash" "rc=${RC} calls=[${CALLS}] ${OUT}"; fi
# glab's issue commands (issueutils.IssueFromArg) take only http(s) URLs; a
# scheme-less one is "Invalid issue format" and nothing is sent.
gla issue note "//gitlab.com/synth-group/pub/-/issues/1" -m "x${TOKEN}"
if [ "${RC}" = 0 ] && sent && read_was "api projects/:id" && ! read_was "synth-group%2Fpub"; then ok "DND-2012: a scheme-less issue URL is no reference for glab: the cwd project is judged"; else bad "DND-2012: //host issue note" "rc=${RC} calls=[${CALLS}] ${OUT}"; fi
gla issue note "HTTPS://gitlab.com/synth-group/pub/-/issues/1" -m "x${TOKEN}"
if refused_hit && read_was "api projects/synth-group%2Fpub"; then ok "DND-2012: an http(s) issue URL names its project (issue note)"; else bad "DND-2012: issue note URL" "rc=${RC} calls=[${CALLS}] ${OUT}"; fi
gla incident note "https://gitlab.com/synth-group/pub/-/issues/incident/1" -m "x${TOKEN}"
if refused_hit && read_was "api projects/synth-group%2Fpub"; then ok "DND-2012: an incident URL names its project (incident note)"; else bad "DND-2012: incident note URL" "rc=${RC} calls=[${CALLS}] ${OUT}"; fi
# A positional is a reference only where glab reads one. `release create`'s
# positionals are a tag and asset files: an MR URL there named a project glab
# never writes to, and the cwd (the real target) was dropped.
vis default public
gla release create v1 "https://gitlab.com/synth-group/priv/-/merge_requests/1" -N "x${TOKEN}"
if refused_hit && read_was "api projects/:id" && ! read_was "synth-group%2Fpriv"; then ok "DND-2012 regression: a release positional is no reference: the cwd (PUBLIC) project is judged"; else bad "DND-2012 regression: release positional URL" "rc=${RC} calls=[${CALLS}] ${OUT}"; fi
vis default private
reset_vis

echo "--- DND-2014: text glab builds itself never reaches a PUBLIC project unscanned ---"
# glab 1.92.1 `mr create` copies the --related-issue's title (fetched from the
# server, possibly a PRIVATE issue in another project) into the MR title when
# --title is empty, and into a branch it creates on the target when
# --source-branch is empty; --copy-issue-labels copies its labels. --fill and
# --fill-commit-body (mr create, mr update) write commit messages, --recover a
# saved recovery file, --signoff the account's name and email. The scan never
# sees any of it, so on a target that is not PRIVATE it is refused.
refused_authored() { [ "${RC}" = 3 ] && ! sent && [[ "${OUT}" == *"text glab builds itself"* ]] && [[ "${OUT}" == *"Fix:"* ]]; }
ISSUE_URL="https://gitlab.com/synth-group/priv/-/issues/7"
for argv in "mr create --related-issue 7 --yes" "mr create -i ${ISSUE_URL} -t T -d D" "mr create -i 7 -s br -d D" \
  "mr create -i=7 -s br -d D" "mr create --related-issue=${ISSUE_URL} -s br" \
  "mr create -i 7 -t T -s br -d D --copy-issue-labels" \
  "mr create --fill --yes" "mr create -f -y" "mr create -fy" "mr create -yf" "mr new --fill -t T" \
  "mr create -f=true -t T" "mr create --fill=1 -t T" "mr create --fill=bogus -t T" \
  "mr create --fill=false --fill -t T" "mr create --fill --fill-commit-body --yes" \
  "mr create -t T -d D --recover" "mr create -t T -d D --signoff" \
  "mr update 5 --fill --yes" "mr update 5 -fy" "mr update 5 --fill --fill-commit-body -y" \
  "issue create -t T -d D --recover" "issue new -t T -d D --recover=true" \
  "-R synth-group/pub mr create --fill --yes"; do
  # shellcheck disable=SC2086
  gla ${argv}
  if refused_authored; then ok "DND-2014 refused: ${argv}"; else bad "DND-2014 refused: ${argv}" "rc=${RC} calls=[${CALLS}] ${OUT}"; fi
done
# An empty -t or -s value is what glab treats as absent (the issue's text fills it).
gla mr create -i 7 -t "" -s br -d D
if refused_authored; then ok "DND-2014 refused: an empty --title with --related-issue"; else bad "DND-2014: empty --title" "rc=${RC} calls=[${CALLS}] ${OUT}"; fi
gla mr create -i 7 -t T -s "" -d D
if refused_authored; then ok "DND-2014 refused: an empty --source-branch with --related-issue"; else bad "DND-2014: empty --source-branch" "rc=${RC} calls=[${CALLS}] ${OUT}"; fi
# The last occurrence wins, as pflag reads it.
gla mr create -i 7 -t T -s br -t "" -d D
if refused_authored; then ok "DND-2014 refused: the last --title is empty"; else bad "DND-2014: last --title empty" "rc=${RC} calls=[${CALLS}] ${OUT}"; fi
# The refusal names the flag, and the Fix names the explicit text to pass.
gla mr create --related-issue 7 --yes
if [[ "${OUT}" == *"--related-issue"* ]] && [[ "${OUT}" == *"--title"* ]] && [[ "${OUT}" == *"--source-branch"* ]]; then ok "DND-2014: the refusal names --related-issue and the explicit flags to pass"; else bad "DND-2014: refusal wording" "${OUT}"; fi
# Explicit text passes: every value glab sends was scanned.
for argv in "mr create -i 7 -t T -s br -d D" "mr create -i ${ISSUE_URL} --title T --source-branch br -d D" \
  "mr create --related-issue=${ISSUE_URL} -s br -t T -d D" "mr create --fill=false -t T -d D" "mr create -f=0 -t T -d D" "mr create --fill --fill=false -t T -d D" \
  "mr create --related-issue= -t T -d D" "mr create -t T -d D --recover=false --signoff=false" "mr update 5 --fill=FALSE -t T" \
  "issue create -t T -d D"; do
  # shellcheck disable=SC2086
  gla ${argv}
  if [ "${RC}" = 0 ] && sent; then ok "DND-2014 explicit text passes: ${argv}"; else bad "DND-2014 explicit: ${argv}" "rc=${RC} calls=[${CALLS}] ${OUT}"; fi
done
# A PRIVATE target is not scanned, so glab may build its own text there; the
# visibility is still read, and an unreadable one refuses.
vis default private
gla mr create --fill --yes
if [ "${RC}" = 0 ] && sent && read_was "api projects/:id"; then ok "DND-2014: --fill to a PRIVATE project is sent"; else bad "DND-2014: private --fill" "rc=${RC} calls=[${CALLS}] ${OUT}"; fi
gla mr create --related-issue 7 --yes
if [ "${RC}" = 0 ] && sent; then ok "DND-2014: --related-issue to a PRIVATE project is sent"; else bad "DND-2014: private --related-issue" "rc=${RC} calls=[${CALLS}] ${OUT}"; fi
vis "synth-group%2Fpub" public
gla -R synth-group/pub mr create --related-issue 7 --yes
if refused_authored && read_was "api projects/synth-group%2Fpub"; then ok "DND-2014: -R to a PUBLIC project from a PRIVATE cwd is refused"; else bad "DND-2014: -R public" "rc=${RC} calls=[${CALLS}] ${OUT}"; fi
vis default none
gla mr create --fill --yes
if [ "${RC}" = 3 ] && ! sent && [[ "${OUT}" == *"COULD NOT LOOK"* ]]; then ok "DND-2014: --fill with an unreadable visibility refuses"; else bad "DND-2014: unreadable --fill" "rc=${RC} calls=[${CALLS}] ${OUT}"; fi
reset_vis
# Library path: the guard itself refuses, not only the wrapper around it.
lib_guard mr create --related-issue 7 --yes
if refused_authored; then ok "DND-2014: glos_guard refuses --related-issue"; else bad "DND-2014: lib --related-issue" "rc=${RC} calls=[${CALLS}] ${OUT}"; fi
reset_vis

echo "--- commands outside the list pass untouched ---"
gla mr view 5
if [ "${RC}" = 0 ] && sent && [ "$(grep -c . <<<"${CALLS}")" = 1 ]; then ok "mr view untouched"; else bad "mr view" "rc=${RC} calls=[${CALLS}] ${OUT}"; fi
gla mr note resolve 5 3107030349
if [ "${RC}" = 0 ] && sent && [ "$(grep -c . <<<"${CALLS}")" = 1 ]; then ok "mr note resolve (no text) untouched"; else bad "mr note resolve" "rc=${RC} calls=[${CALLS}] ${OUT}"; fi

echo "--- the shared rules: the same outcomes as gh-athena ---"
OUT="$(cd "${WORK}" && : > "${STUB_LOG}" && XDG_STATE_HOME="${TMP}/state" ATHENA_OUTBOUND_WAIVE="synthetic waiver" "${WRAPPER}" mr note 5 -m "x${TOKEN}" 2>&1)"; RC=$?
if [ "${RC}" = 0 ] && sent && [[ "${OUT}" == *"WAIVED - NOT SCANNED"* ]] && [[ "${OUT}" != *"CLEAN"* ]]; then ok "waiver"; else bad "waiver" "rc=${RC} ${OUT}"; fi
OUT="$(cd "${WORK}" && : > "${STUB_LOG}" && ATHENA_PRIVATE_ROOT=/nonexistent "${WRAPPER}" mr note 5 -m "x" 2>&1)"; RC=$?
if [ "${RC}" = 3 ] && ! sent && [[ "${OUT}" == *"overlay is MALFORMED"* ]] && [[ "${OUT}" == *"REFUSED"* ]]; then ok "malformed overlay refused"; else bad "malformed" "rc=${RC} ${OUT}"; fi
CR="${TMP}/crash"; git init -q "${CR}"; mkdir -p "${CR}/ai"
cp -r "${AI_DIR}/bin" "${AI_DIR}/lib" "${CR}/ai/"
printf '#!/bin/sh\necho "Traceback: boom" >&2\nexit 1\n' > "${CR}/ai/bin/outbound-scan"
OUT="$(cd "${WORK}" && : > "${STUB_LOG}" && "${CR}/ai/bin/glab-athena" mr note 5 -m "clean" 2>&1)"; RC=$?
if [ "${RC}" = 3 ] && ! sent && [[ "${OUT}" == *"without reporting HITS"* ]]; then ok "a scanner crash reads as a failure"; else bad "crash" "rc=${RC} ${OUT}"; fi
UM="${TMP}/unmarked"; git init -q "${UM}"; mkdir -p "${UM}/ai"
cp -r "${AI_DIR}/bin" "${AI_DIR}/lib" "${UM}/ai/"
OUT="$(cd "${WORK}" && : > "${STUB_LOG}" && env -u ATHENA_PRIVATE_ROOT "${UM}/ai/bin/glab-athena" mr note 5 -m "x" 2>&1)"; RC=$?
if [ "${RC}" = 0 ] && sent && [[ "${OUT}" == *"went out UNSCANNED"* ]] && [[ "${OUT}" != *"CLEAN mode"* ]]; then ok "absent overlay + unmarked machine: sent, warned"; else bad "absent + unmarked" "rc=${RC} ${OUT}"; fi

# DND-1647: no gh/glab call may have fallen through past its stub.
if fsg_verify; then ok "no gh/glab call fell through past its stub (DND-1647)"
else bad "no gh/glab call fell through past its stub (DND-1647)" "see the forge-stub-guard FAIL above"; fi

echo
echo "glab-athena outbound-scan self-test: ${PASS} passed, ${FAIL} failed"
[ "${FAIL}" -eq 0 ]
