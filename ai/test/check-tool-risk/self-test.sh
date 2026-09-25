#!/usr/bin/env bash
# Black-box suite for ai/bin/check-tool-risk's ratchets (DND-543) -- discovered
# and run by harness-gate.
#
# The defect this pins: ai/tools/risk.yml and the SCOPE table in
# ai/lib/harness_tools.rb live in the same diff check-tool-risk judges. A change
# could relabel a destructive tool readOnly (loosening
# ai/hooks/workflow-phase-guard.sh, which reads the registry), or move a
# directory from IN to OUT of scope, and the check compared the change against
# the bar the change had just written: green. See ~/dev/custom/CLAUDE.md -> "A
# check's own bar must not live in the diff it is checking".
#
# Every case builds a throwaway git repo holding the checker under test and its
# ai/lib/*.rb, lands it on a local bare origin, then edits the working tree. The
# checker resolves its repo from its own location, so it measures the fixture,
# never the live tree. The suite is black-box, so it runs unchanged against the
# pre-fix checker, which is how the fail-first evidence was recorded:
#
#   CHECK_TOOL_RISK_UNDER_TEST=/path/to/old/ai/bin/check-tool-risk \
#     ai/test/check-tool-risk/self-test.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AI_DIR="$(cd "${HERE}/../.." && pwd)"
BIN="${CHECK_TOOL_RISK_UNDER_TEST:-${AI_DIR}/bin/check-tool-risk}"
LIB_DIR="$(dirname "${BIN}")/../lib"

if [ ! -f "${BIN}" ] || [ ! -f "${LIB_DIR}/harness_tools.rb" ]; then
  echo "check-tool-risk self-test: FAIL -- ${BIN} or ${LIB_DIR}/harness_tools.rb does not exist" >&2
  echo "Fix: point CHECK_TOOL_RISK_UNDER_TEST at a real checker beside its ai/lib, or restore ai/bin/check-tool-risk." >&2
  exit 1
fi

TMP="$(mktemp -d)"; trap 'rm -rf "${TMP}"' EXIT
PASS=0; FAIL=0
ok()  { printf '  ok    %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  FAIL  %s\n        %s\n' "$1" "$2"; FAIL=$((FAIL+1)); }

LIVE_GIT_ENV=(env -u GIT_CONFIG_NOSYSTEM -u GIT_CONFIG_GLOBAL)
[ -n "${GIT_CONFIG_NOSYSTEM+x}" ] && LIVE_GIT_ENV+=("GIT_CONFIG_NOSYSTEM=${GIT_CONFIG_NOSYSTEM}")
[ -n "${GIT_CONFIG_GLOBAL+x}" ] && LIVE_GIT_ENV+=("GIT_CONFIG_GLOBAL=${GIT_CONFIG_GLOBAL}")
export GIT_CONFIG_NOSYSTEM=1
export GIT_CONFIG_GLOBAL="${TMP}/gitconfig"
: > "${GIT_CONFIG_GLOBAL}"

POST=skills/athena:slack/bin/post
PEEK=skills/athena:demo/bin/peek

# land <root>: commit everything, push it to the bare origin's main, and point
# refs/remotes/origin/main at it -- "the owner landed this on main".
land() {
  git -C "$1" add -A >/dev/null 2>&1
  git -C "$1" -c user.name=fixture -c user.email=fixture@example.invalid \
    commit -q --allow-empty -m landed >/dev/null 2>&1
  git -C "$1" push -q -f origin HEAD:refs/heads/main >/dev/null 2>&1
  git -C "$1" update-ref refs/remotes/origin/main HEAD
}

add_exec() {
  mkdir -p "$(dirname "$1/$2")"
  printf '#!/bin/sh\ncase "${1:-}" in -h|--help) echo usage; exit 0 ;; esac\n' > "$1/$2"
  chmod +x "$1/$2"
}

# registry <root> <key:class>...: write the fixture's ai/tools/risk.yml.
registry() {
  local root="$1"; shift
  mkdir -p "${root}/ai/tools"
  {
    printf 'version: 1\ndefault: destructive\nclasses: [readOnly, idempotent, destructive]\ntools:\n'
    local kv
    for kv in "$@"; do printf '  %s: { class: %s, reason: t }\n' "${kv%%=*}" "${kv#*=}"; done
  } > "${root}/ai/tools/risk.yml"
}

# new_fixture <name>: the checker, its libraries, a destructive and a readOnly
# skill tool, and a complete registry, landed. Prints its path.
new_fixture() {
  local root="${TMP}/$1"
  mkdir -p "${root}/ai/bin" "${root}/ai/lib"
  cp "${BIN}" "${root}/ai/bin/check-tool-risk"; chmod +x "${root}/ai/bin/check-tool-risk"
  cp "${LIB_DIR}"/*.rb "${root}/ai/lib/"
  add_exec "${root}" "ai/${POST}"
  add_exec "${root}" "ai/${PEEK}"
  registry "${root}" check-tool-risk=readOnly "${POST}=destructive" "${PEEK}=readOnly"
  git -C "${root}" init -q
  git init -q --bare "${root}.origin.git"
  git -C "${root}" remote add origin "${root}.origin.git"
  land "${root}"
  printf '%s\n' "${root}"
}

# run <root>: run the fixture's checker; sets RC and OUT (stdout+stderr).
run() { OUT="$(cd "$1" && ruby ai/bin/check-tool-risk 2>&1)"; RC=$?; }
has() { printf '%s' "${OUT}" | grep -F -- "$1" >/dev/null; }

# scope_carve <root> <prefix>: insert an OUT entry for prefix ahead of ai/.
scope_carve() {
  ruby -e 'f, pre = ARGV; t = File.read(f)
    t.sub!(/^(\s*)\["ai\/", :in,/) { "#{$1}[\"#{pre}\", :out, \"carved out\"],\n#{$1}[\"ai/\", :in," } or abort "no ai/ entry"
    File.write(f, t)' "$1/ai/lib/harness_tools.rb" "$2"
}

echo "== check-tool-risk: the risk registry is ratcheted against what landed =="

# 1. Positive control: the landed fixture passes.
R="$(new_fixture control)"; run "${R}"
if [ "${RC}" -eq 0 ]; then ok "1 the landed fixture passes"
else bad "1 the landed fixture passes" "rc=${RC} out=${OUT}"; fi

# 2. THE DEFECT: destructive -> readOnly in the diff under test.
R="$(new_fixture relabel)"
registry "${R}" check-tool-risk=readOnly "${POST}=readOnly" "${PEEK}=readOnly"; run "${R}"
if [ "${RC}" -ne 0 ] && has "${POST}" && has "destructive" && has "weaken" && has "Fix:"; then
  ok "2 destructive -> readOnly fails, named, with Fix:"
else bad "2 destructive -> readOnly fails, named, with Fix:" "rc=${RC} out=${OUT}"; fi

# 2b. destructive -> idempotent is a weakening too (one step down the order).
R="$(new_fixture relabel-idem)"
registry "${R}" check-tool-risk=readOnly "${POST}=idempotent" "${PEEK}=readOnly"; run "${R}"
if [ "${RC}" -ne 0 ] && has "${POST}" && has "weaken"; then
  ok "2b destructive -> idempotent fails"
else bad "2b destructive -> idempotent fails" "rc=${RC} out=${OUT}"; fi

# 2c. A relabel COMMITTED on the branch (not just in the working tree) fails.
R="$(new_fixture relabel-committed)"
registry "${R}" check-tool-risk=readOnly "${POST}=readOnly" "${PEEK}=readOnly"
git -C "${R}" -c user.name=f -c user.email=f@example.invalid commit -qam relabel >/dev/null 2>&1; run "${R}"
if [ "${RC}" -ne 0 ] && has "${POST}" && has "weaken"; then
  ok "2c a committed destructive -> readOnly relabel fails"
else bad "2c a committed destructive -> readOnly relabel fails" "rc=${RC} out=${OUT}"; fi

# 3. The owner lands the relabel on main: the bar moved outside the diff.
R="$(new_fixture owner-landed)"
registry "${R}" check-tool-risk=readOnly "${POST}=readOnly" "${PEEK}=readOnly"; land "${R}"; run "${R}"
if [ "${RC}" -eq 0 ]; then ok "3 an owner-landed relabel passes"
else bad "3 an owner-landed relabel passes" "rc=${RC} out=${OUT}"; fi

# 4. Tightening passes: readOnly -> destructive.
R="$(new_fixture tighten)"
registry "${R}" check-tool-risk=readOnly "${POST}=destructive" "${PEEK}=destructive"; run "${R}"
if [ "${RC}" -eq 0 ]; then ok "4 readOnly -> destructive (tightening) passes"
else bad "4 readOnly -> destructive (tightening) passes" "rc=${RC} out=${OUT}"; fi

# 5. A genuinely new tool passes and is NAMED, so a reviewer sees its class.
R="$(new_fixture new-tool)"
add_exec "${R}" ai/skills/athena:demo/bin/fresh
registry "${R}" check-tool-risk=readOnly "${POST}=destructive" "${PEEK}=readOnly" \
  "skills/athena:demo/bin/fresh=readOnly"; run "${R}"
if [ "${RC}" -eq 0 ] && has "skills/athena:demo/bin/fresh (readOnly)" && has "new"; then
  ok "5 a new tool passes and is named with its class"
else bad "5 a new tool passes and is named with its class" "rc=${RC} out=${OUT}"; fi

# 6. A class the strictness order cannot rank fails: a diff may not invent a
#    class to escape the order.
R="$(new_fixture unranked)"
sed -i 's/^classes: .*/classes: [readOnly, idempotent, destructive, harmless]/' "${R}/ai/tools/risk.yml"
sed -i "s|^  ${POST}: { class: destructive|  ${POST}: { class: harmless|" "${R}/ai/tools/risk.yml"; run "${R}"
if [ "${RC}" -ne 0 ] && has "harmless" && has "Fix:"; then
  ok "6 a class outside readOnly < idempotent < destructive fails"
else bad "6 a class outside readOnly < idempotent < destructive fails" "rc=${RC} out=${OUT}"; fi

echo "== check-tool-risk: the SCOPE table is ratcheted against what landed =="

# 7. THE DEFECT: a directory moved from IN to OUT, and its registry entry
#    dropped so coverage stays green.
R="$(new_fixture scope-out)"
scope_carve "${R}" "ai/skills/athena:slack/"
registry "${R}" check-tool-risk=readOnly "${PEEK}=readOnly"; run "${R}"
if [ "${RC}" -ne 0 ] && has "ai/skills/athena:slack/" && has "weaken" && has "Fix:"; then
  ok "7 SCOPE in -> out fails, naming the carved-out prefix, with Fix:"
else bad "7 SCOPE in -> out fails, naming the carved-out prefix, with Fix:" "rc=${RC} out=${OUT}"; fi

# 7b. A pre-emptive carve-out of a directory with no tool in it yet is still
#     in -> out: the next tool there would never be classified.
R="$(new_fixture scope-preempt)"
scope_carve "${R}" "ai/skills/athena:later/"; run "${R}"
if [ "${RC}" -ne 0 ] && has "ai/skills/athena:later/"; then
  ok "7b a pre-emptive SCOPE carve-out of an empty directory fails"
else bad "7b a pre-emptive SCOPE carve-out of an empty directory fails" "rc=${RC} out=${OUT}"; fi

# 8. The owner lands the carve-out: passes.
R="$(new_fixture scope-landed)"
scope_carve "${R}" "ai/skills/athena:slack/"
registry "${R}" check-tool-risk=readOnly "${PEEK}=readOnly"; land "${R}"; run "${R}"
if [ "${RC}" -eq 0 ]; then ok "8 an owner-landed SCOPE carve-out passes"
else bad "8 an owner-landed SCOPE carve-out passes" "rc=${RC} out=${OUT}"; fi

# 9. A new OUT entry for a directory that was never in scope is a new scope
#    decision, not a weakening: passes, named.
R="$(new_fixture scope-new)"
ruby -e 'f = ARGV[0]; t = File.read(f)
  t.sub!(/^(\s*)\["hypr\/"/) { "#{$1}[\"docs/\", :out, \"prose only\"],\n#{$1}[\"hypr/\"" } or abort "no hypr"
  File.write(f, t)' "${R}/ai/lib/harness_tools.rb"; run "${R}"
if [ "${RC}" -eq 0 ] && has "docs/"; then ok "9 a new OUT entry for a never-scoped directory passes, named"
else bad "9 a new OUT entry for a never-scoped directory passes, named" "rc=${RC} out=${OUT}"; fi

# 10. A SCOPE entry the ratchet's reader cannot parse fails as could-not-measure:
#     writing the table differently must not hide an entry from the ratchet.
R="$(new_fixture scope-unparseable)"
ruby -e 'f = ARGV[0]; t = File.read(f)
  t.sub!(/^(\s*)\["ai\/", :in,/) { "#{$1}[%w[ai/skills/athena:slack/].first, :out, \"hidden\"],\n#{$1}[\"ai/\", :in," } or abort "no ai/"
  File.write(f, t)' "${R}/ai/lib/harness_tools.rb"
registry "${R}" check-tool-risk=readOnly "${PEEK}=readOnly"; run "${R}"
if [ "${RC}" -ne 0 ] && has "could not measure" && has "Fix:"; then
  ok "10 a SCOPE entry in an unparseable form fails as could-not-measure"
else bad "10 a SCOPE entry in an unparseable form fails as could-not-measure" "rc=${RC} out=${OUT}"; fi

echo "== check-tool-risk: the landed bar must be measurable =="

# 11. origin unreachable -> could not measure, never OK.
R="$(new_fixture unreachable)"
git -C "${R}" remote set-url origin "${TMP}/no-such-remote.git"; run "${R}"
if [ "${RC}" -ne 0 ] && has "could not measure" && has "ls-remote" && has "Fix:" && ! has "OK"; then
  ok "11 an unreachable origin fails as could-not-measure, with Fix:"
else bad "11 an unreachable origin fails as could-not-measure, with Fix:" "rc=${RC} out=${OUT}"; fi

# 12. A forged local origin/main carrying the relabel -> mismatch, both SHAs.
R="$(new_fixture forged)"; REAL="$(git -C "${R}" rev-parse HEAD)"
registry "${R}" check-tool-risk=readOnly "${POST}=readOnly" "${PEEK}=readOnly"
git -C "${R}" -c user.name=f -c user.email=f@example.invalid commit -qam relabel >/dev/null 2>&1
git -C "${R}" update-ref refs/remotes/origin/main HEAD
FORGED="$(git -C "${R}" rev-parse HEAD)"; run "${R}"
if [ "${RC}" -ne 0 ] && has "${REAL}" && has "${FORGED}" && has "Fix:" && ! has "OK"; then
  ok "12 a forged local origin/main fails, naming both SHAs, with Fix:"
else bad "12 a forged local origin/main fails, naming both SHAs, with Fix:" "rc=${RC} out=${OUT}"; fi

# 13. A landed registry that cannot be parsed -> could not measure.
R="$(new_fixture landed-malformed)"
printf 'tools: [not, a, map\n' > "${R}/ai/tools/risk.yml"; land "${R}"
registry "${R}" check-tool-risk=readOnly "${POST}=destructive" "${PEEK}=readOnly"; run "${R}"
if [ "${RC}" -ne 0 ] && has "could not measure" && has "Fix:"; then
  ok "13 a malformed landed registry fails as could-not-measure"
else bad "13 a malformed landed registry fails as could-not-measure" "rc=${RC} out=${OUT}"; fi

# 14. The OK line says the ratchet ran against the cross-checked tip, so a
#     pass that skipped it cannot read the same.
R="$(new_fixture ok-line)"; run "${R}"
TIP="$(git -C "${R}" rev-parse refs/remotes/origin/main)"
if [ "${RC}" -eq 0 ] && has "ratchet" && has "ls-remote" && has "${TIP:0:12}"; then
  ok "14 the OK output names the ratchet and the cross-checked tip"
else bad "14 the OK output names the ratchet and the cross-checked tip" "rc=${RC} out=${OUT}"; fi

echo "== check-tool-risk: a tool moved to a new path keeps its landed class (DND-551) =="

# The ratchet keys on the registry key, i.e. the tool's PATH. Before DND-551 a
# destructive tool renamed and relabelled readOnly read as a removal plus a new
# entry, and passed. A new key whose content maps to a REMOVED landed key (the
# same blob, or git's rename detection at 50%) inherits that key's class.

# A realistic, distinctive body for the landed post, so similarity means something.
POST_BODY='#!/bin/sh
# post -- send a message to a Slack channel as the Athena bot.
case "${1:-}" in -h|--help) echo "usage: post <channel> [text]"; exit 0 ;; esac
channel="${1:?channel required}"; shift
text="${*:-$(cat)}"
token="$(cat "${HOME}/.config/athena-slack/token")"
curl -sS -X POST -H "Authorization: Bearer ${token}" \
  --data-urlencode "channel=${channel}" --data-urlencode "text=${text}" \
  https://slack.com/api/chat.postMessage'

# moved_fixture <name>: new_fixture with post's distinctive body landed.
moved_fixture() {
  local root; root="$(new_fixture "$1")"
  printf '%s\n' "${POST_BODY}" > "${root}/ai/${POST}"; land "${root}"
  printf '%s\n' "${root}"
}

# 16. THE DEFECT: post -> post2, relabelled readOnly.
R="$(moved_fixture moved-relabel)"
git -C "${R}" mv "ai/${POST}" "ai/${POST}2"
registry "${R}" check-tool-risk=readOnly "${POST}2=readOnly" "${PEEK}=readOnly"; run "${R}"
if [ "${RC}" -ne 0 ] && has "${POST}2" && has "${POST} (moved here" && has "% similar" \
   && has "destructive" && has "Fix:"; then
  ok "16 post -> post2 relabelled readOnly fails, both paths and the similarity named, with Fix:"
else bad "16 post -> post2 relabelled readOnly fails, both paths and the similarity named, with Fix:" "rc=${RC} out=${OUT}"; fi

# 16b. Moved, edited (still >= 50% similar), untracked, relabelled idempotent.
R="$(moved_fixture moved-edited)"
mv "${R}/ai/${POST}" "${R}/ai/skills/athena:slack/bin/send"
printf '# send: renamed from post\n' >> "${R}/ai/skills/athena:slack/bin/send"
registry "${R}" check-tool-risk=readOnly skills/athena:slack/bin/send=idempotent "${PEEK}=readOnly"; run "${R}"
if [ "${RC}" -ne 0 ] && has "skills/athena:slack/bin/send" && has "${POST} (moved here" && has "idempotent"; then
  ok "16b post moved, edited, untracked and relabelled idempotent fails"
else bad "16b post moved, edited, untracked and relabelled idempotent fails" "rc=${RC} out=${OUT}"; fi

# 16c. Moved into ai/bin, whose registry key is the bare name: the key schema
#      changes with the path, the class still follows the content.
R="$(moved_fixture moved-to-bin)"
git -C "${R}" mv "ai/${POST}" ai/bin/slack-post
registry "${R}" check-tool-risk=readOnly slack-post=readOnly "${PEEK}=readOnly"; run "${R}"
if [ "${RC}" -ne 0 ] && has "slack-post" && has "${POST} (moved here"; then
  ok "16c post moved into ai/bin as slack-post and relabelled readOnly fails"
else bad "16c post moved into ai/bin as slack-post and relabelled readOnly fails" "rc=${RC} out=${OUT}"; fi

# 17. post -> post2 KEPT destructive: passes, and the move is named.
R="$(moved_fixture moved-kept)"
git -C "${R}" mv "ai/${POST}" "ai/${POST}2"
registry "${R}" check-tool-risk=readOnly "${POST}2=destructive" "${PEEK}=readOnly"; run "${R}"
if [ "${RC}" -eq 0 ] && has "${POST} -> ${POST}2"; then
  ok "17 post -> post2 kept destructive passes, the move named"
else bad "17 post -> post2 kept destructive passes, the move named" "rc=${RC} out=${OUT}"; fi

# 18. A genuinely new tool beside an unrelated removal passes and is named.
R="$(moved_fixture new-beside-removal)"
git -C "${R}" rm -q "ai/${POST}"
add_exec "${R}" ai/skills/athena:demo/bin/fresh
registry "${R}" check-tool-risk=readOnly "${PEEK}=readOnly" skills/athena:demo/bin/fresh=readOnly; run "${R}"
if [ "${RC}" -eq 0 ] && has "skills/athena:demo/bin/fresh (readOnly)" && has "new"; then
  ok "18 a genuinely new tool beside a removed one passes, named"
else bad "18 a genuinely new tool beside a removed one passes, named" "rc=${RC} out=${OUT}"; fi

echo "== check-tool-risk: live tree =="

# 15. The live tree passes (DND-512: keeps the caller's git config).
if OUT="$("${LIVE_GIT_ENV[@]}" ruby "${AI_DIR}/bin/check-tool-risk" 2>&1)"; then
  ok "15 the live tree passes check-tool-risk"
else bad "15 the live tree passes check-tool-risk" "${OUT}"; fi

echo
echo "check-tool-risk self-test: ${PASS} passed, ${FAIL} failed"
if [ "${FAIL}" -ne 0 ]; then
  echo "Fix: a FAIL above names the ratchet case ai/bin/check-tool-risk got wrong; see its DND-543 section."
  exit 1
fi
