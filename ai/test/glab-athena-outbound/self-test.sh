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
