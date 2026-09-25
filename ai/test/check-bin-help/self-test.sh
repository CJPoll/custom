#!/usr/bin/env bash
# Black-box suite for ai/bin/check-bin-help's EXEMPT ratchet (DND-543) --
# discovered and run by harness-gate.
#
# The defect this pins: EXEMPT lives in check-bin-help itself, in the diff the
# check judges. A change could exempt a tool that has no --help branch (the
# DND-246 hang class) and the check honoured the exemption it had just been
# given: green. See ~/dev/custom/CLAUDE.md -> "A check's own bar must not live
# in the diff it is checking".
#
# Every case builds a throwaway git repo holding the checker under test and its
# ai/lib/*.rb, lands it on a local bare origin, then edits the working tree. The
# checker resolves its repo from its own location, so it measures (and probes)
# the fixture's tools, never the live tree. Black-box, so it runs unchanged
# against the pre-fix checker, which is how the fail-first evidence was
# recorded:
#
#   CHECK_BIN_HELP_UNDER_TEST=/path/to/old/ai/bin/check-bin-help \
#     ai/test/check-bin-help/self-test.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AI_DIR="$(cd "${HERE}/../.." && pwd)"
BIN="${CHECK_BIN_HELP_UNDER_TEST:-${AI_DIR}/bin/check-bin-help}"
LIB_DIR="$(dirname "${BIN}")/../lib"

if [ ! -f "${BIN}" ] || [ ! -f "${LIB_DIR}/harness_tools.rb" ]; then
  echo "check-bin-help self-test: FAIL -- ${BIN} or ${LIB_DIR}/harness_tools.rb does not exist" >&2
  echo "Fix: point CHECK_BIN_HELP_UNDER_TEST at a real checker beside its ai/lib, or restore ai/bin/check-bin-help." >&2
  exit 1
fi

TMP="$(mktemp -d)"; trap 'rm -rf "${TMP}"' EXIT
PASS=0; FAIL=0
ok()  { printf '  ok    %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  FAIL  %s\n        %s\n' "$1" "$2"; FAIL=$((FAIL+1)); }

export GIT_CONFIG_NOSYSTEM=1
export GIT_CONFIG_GLOBAL="${TMP}/gitconfig"
: > "${GIT_CONFIG_GLOBAL}"

land() {
  git -C "$1" add -A >/dev/null 2>&1
  git -C "$1" -c user.name=fixture -c user.email=fixture@example.invalid \
    commit -q --allow-empty -m landed >/dev/null 2>&1
  git -C "$1" push -q -f origin HEAD:refs/heads/main >/dev/null 2>&1
  git -C "$1" update-ref refs/remotes/origin/main HEAD
}

HELPFUL='#!/bin/sh
case "${1:-}" in -h|--help) echo "usage: $(basename "$0")"; exit 0 ;; esac
exit 0'
# No --help branch at all: phase 1 fails it without executing it, unless exempt.
HELPLESS='#!/bin/sh
exec true "$@"'

add_exec() { mkdir -p "$(dirname "$1/$2")"; printf '%s\n' "$3" > "$1/$2"; chmod +x "$1/$2"; }

# exempt <root> <key>...: rewrite the fixture checker's EXEMPT table to exactly
# these keys, each with a reason, in the literal form the checker ships.
exempt() {
  local root="$1"; shift
  ruby -e 'f = ARGV.shift
    t = File.read(f)
    body = ARGV.map { |k| "  \"#{k}\" => \"passthrough wrapper: forwarding argv IS its contract\",\n" }.join
    t.sub!(/^EXEMPT = \{\n.*?^\}\.freeze\n/m) { "EXEMPT = {\n#{body}}.freeze\n" } or abort "no EXEMPT"
    File.write(f, t)' "${root}/ai/bin/check-bin-help" "$@"
}

# new_fixture <name>: the checker, its libraries, one wrapper that is exempt,
# and one tool that answers --help, landed. Prints its path.
new_fixture() {
  local root="${TMP}/$1"
  mkdir -p "${root}/ai/bin" "${root}/ai/lib"
  cp "${BIN}" "${root}/ai/bin/check-bin-help"; chmod +x "${root}/ai/bin/check-bin-help"
  cp "${LIB_DIR}"/*.rb "${root}/ai/lib/"
  add_exec "${root}" ai/bin/wrap "${HELPLESS}"
  add_exec "${root}" ai/bin/tool "${HELPFUL}"
  exempt "${root}" ai/bin/wrap
  git -C "${root}" init -q
  git init -q --bare "${root}.origin.git"
  git -C "${root}" remote add origin "${root}.origin.git"
  land "${root}"
  printf '%s\n' "${root}"
}

run() { OUT="$(cd "$1" && ruby ai/bin/check-bin-help 2>&1)"; RC=$?; }
has() { printf '%s' "${OUT}" | grep -F -- "$1" >/dev/null; }

echo "== check-bin-help: EXEMPT is ratcheted against what landed =="

# 1. Positive control.
R="$(new_fixture control)"; run "${R}"
if [ "${RC}" -eq 0 ]; then ok "1 the landed fixture passes"
else bad "1 the landed fixture passes" "rc=${RC} out=${OUT}"; fi

# 2. THE DEFECT: a new EXEMPT entry excusing a tool with no --help branch.
R="$(new_fixture new-exempt)"
add_exec "${R}" ai/skills/athena:demo/bin/nohelp "${HELPLESS}"
exempt "${R}" ai/bin/wrap ai/skills/athena:demo/bin/nohelp; run "${R}"
if [ "${RC}" -ne 0 ] && has "ai/skills/athena:demo/bin/nohelp" && has "EXEMPT" && has "Fix:"; then
  ok "2 a new EXEMPT entry fails, named, with Fix:"
else bad "2 a new EXEMPT entry fails, named, with Fix:" "rc=${RC} out=${OUT}"; fi

# 2b. A new EXEMPT entry for a tool that DOES answer --help is still a
#     weakening: it takes the tool out of the probe.
R="$(new_fixture new-exempt-helpful)"
exempt "${R}" ai/bin/wrap ai/bin/tool; run "${R}"
if [ "${RC}" -ne 0 ] && has "ai/bin/tool" && has "EXEMPT"; then
  ok "2b a new EXEMPT entry for a tool that answers --help fails"
else bad "2b a new EXEMPT entry for a tool that answers --help fails" "rc=${RC} out=${OUT}"; fi

# 3. The owner lands the exemption on main: passes.
R="$(new_fixture owner-landed)"
add_exec "${R}" ai/skills/athena:demo/bin/nohelp "${HELPLESS}"
exempt "${R}" ai/bin/wrap ai/skills/athena:demo/bin/nohelp; land "${R}"; run "${R}"
if [ "${RC}" -eq 0 ]; then ok "3 an owner-landed EXEMPT entry passes"
else bad "3 an owner-landed EXEMPT entry passes" "rc=${RC} out=${OUT}"; fi

# 4. Removing an exemption (tightening) passes once the tool answers --help.
R="$(new_fixture tighten)"
add_exec "${R}" ai/bin/wrap "${HELPFUL}"; exempt "${R}"; run "${R}"
if [ "${RC}" -eq 0 ]; then ok "4 removing an EXEMPT entry (tightening) passes"
else bad "4 removing an EXEMPT entry (tightening) passes" "rc=${RC} out=${OUT}"; fi

# 5. A landed table keyed by bare ai/bin names (the pre-DND-508 schema) is
#    read as ai/bin/<name>: the same exemption, not a new one.
R="$(new_fixture legacy-keys)"
exempt "${R}" wrap; land "${R}"; exempt "${R}" ai/bin/wrap; run "${R}"
if [ "${RC}" -eq 0 ]; then ok "5 a landed bare-name key matches its ai/bin/<name> path"
else bad "5 a landed bare-name key matches its ai/bin/<name> path" "rc=${RC} out=${OUT}"; fi

# 6. An EXEMPT entry the ratchet's reader cannot parse fails as
#    could-not-measure: writing the table differently must not hide an entry.
R="$(new_fixture unparseable)"
add_exec "${R}" ai/bin/nohelp "${HELPLESS}"
ruby -e 'f = ARGV[0]; t = File.read(f)
  t.sub!(/^EXEMPT = \{\n/) { "EXEMPT = {\n  %w[ai/bin/nohelp].first => \"hidden\",\n" } or abort "no EXEMPT"
  File.write(f, t)' "${R}/ai/bin/check-bin-help"; run "${R}"
if [ "${RC}" -ne 0 ] && has "could not measure" && has "Fix:"; then
  ok "6 an EXEMPT entry in an unparseable form fails as could-not-measure"
else bad "6 an EXEMPT entry in an unparseable form fails as could-not-measure" "rc=${RC} out=${OUT}"; fi

echo "== check-bin-help: the landed bar must be measurable =="

# 7. origin unreachable -> could not measure, never OK.
R="$(new_fixture unreachable)"
git -C "${R}" remote set-url origin "${TMP}/no-such-remote.git"; run "${R}"
if [ "${RC}" -ne 0 ] && has "could not measure" && has "ls-remote" && has "Fix:" && ! has "OK"; then
  ok "7 an unreachable origin fails as could-not-measure, with Fix:"
else bad "7 an unreachable origin fails as could-not-measure, with Fix:" "rc=${RC} out=${OUT}"; fi

# 8. A forged local origin/main carrying the exemption -> mismatch.
R="$(new_fixture forged)"; REAL="$(git -C "${R}" rev-parse HEAD)"
add_exec "${R}" ai/bin/nohelp "${HELPLESS}"; exempt "${R}" ai/bin/wrap ai/bin/nohelp
git -C "${R}" add -A >/dev/null 2>&1
git -C "${R}" -c user.name=f -c user.email=f@example.invalid commit -qm exempt >/dev/null 2>&1
git -C "${R}" update-ref refs/remotes/origin/main HEAD; run "${R}"
if [ "${RC}" -ne 0 ] && has "${REAL}" && has "Fix:" && ! has "OK"; then
  ok "8 a forged local origin/main fails, naming the remote SHA, with Fix:"
else bad "8 a forged local origin/main fails, naming the remote SHA, with Fix:" "rc=${RC} out=${OUT}"; fi

# 9. The OK line names the ratchet and the cross-checked tip.
R="$(new_fixture ok-line)"; run "${R}"
TIP="$(git -C "${R}" rev-parse refs/remotes/origin/main)"
if [ "${RC}" -eq 0 ] && has "EXEMPT ratchet" && has "ls-remote" && has "${TIP:0:12}"; then
  ok "9 the OK output names the EXEMPT ratchet and the cross-checked tip"
else bad "9 the OK output names the EXEMPT ratchet and the cross-checked tip" "rc=${RC} out=${OUT}"; fi

echo
echo "check-bin-help self-test: ${PASS} passed, ${FAIL} failed"
if [ "${FAIL}" -ne 0 ]; then
  echo "Fix: a FAIL above names the EXEMPT ratchet case ai/bin/check-bin-help got wrong; see its DND-543 section."
  exit 1
fi
