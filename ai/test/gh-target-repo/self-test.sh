#!/usr/bin/env bash
# Self-test for ai/lib/gh-target-repo.sh (DND-2006): which repository a gh
# write reaches, resolved as gh 2.96 resolves it. The defect it pins: an empty
# -R was read as "the checkout" while gh used GH_REPO, so the outbound scan
# read a PRIVATE checkout and gh wrote to a PUBLIC GH_REPO unscanned.
#
# Pure: the library runs no command and reads no network, so this needs no
# stub. The wrapper-level cases are in ai/test/gh-athena-outbound/self-test.sh.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=../../lib/gh-target-repo.sh
. "${HERE}/../../lib/gh-target-repo.sh"

PASS=0; FAIL=0
ok()  { printf '  ok    %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  FAIL  %s\n        %s\n' "$1" "$2"; FAIL=$((FAIL+1)); }

# shown : GTR_TARGETS as one string, "" shown as <checkout>.
shown() {
  local t out=""
  for t in "${GTR_TARGETS[@]}"; do out+="[${t:-<checkout>}]"; done
  printf '%s' "${out}"
}
# expect <name> <want targets> <has_url> [-R values...] (GH_REPO from the caller)
expect() {
  local name="$1" want="$2" rc; shift 2
  gtr_resolve "$@"; rc=$?
  if [ "${rc}" = 0 ] && [ "$(shown)" = "${want}" ]; then ok "${name}"; else bad "${name}" "got rc=${rc} targets=$(shown) why=${GTR_WHY}"; fi
}
# refuses <name> <has_url> [-R values...]
refuses() {
  local name="$1"; shift
  if ! gtr_resolve "$@" && [[ "${GTR_WHY}" == *"COULD NOT LOOK"* ]] && [[ "${GTR_WHY}" == *"Fix:"* ]]; then ok "${name}"; else bad "${name}" "targets=$(shown) why=${GTR_WHY}"; fi
}

echo "gh-target-repo self-test"

echo "--- no GH_REPO ---"
unset GH_REPO
expect "no -R: the checkout" "[<checkout>]" 0
expect "-R o/r" "[o/r]" 0 o/r
expect "-R '': the checkout, as gh falls back" "[<checkout>]" 0 ""
expect "-R o/r -R '': o/r is kept, and gh uses the checkout" "[o/r][<checkout>]" 0 o/r ""
expect "-R '' -R o/r: the last wins" "[o/r]" 0 "" o/r
expect "a URL and no -R: no checkout" "" 1
expect "a URL and -R '': no checkout" "" 1 ""

echo "--- GH_REPO set (the DND-2006 cases) ---"
export GH_REPO=synth-owner/pub
expect "no -R: GH_REPO" "[synth-owner/pub]" 0
expect "-R '': GH_REPO, never the checkout" "[synth-owner/pub]" 0 ""
expect "-R o/r: -R wins" "[o/r]" 0 o/r
expect "-R o/r -R '': o/r and GH_REPO" "[o/r][synth-owner/pub]" 0 o/r ""
expect "a URL and -R '': GH_REPO" "[synth-owner/pub]" 1 ""
export GH_REPO=""
expect "GH_REPO empty: the checkout" "[<checkout>]" 0 ""

echo "--- forms gh reads ---"
unset GH_REPO
for v in o/r host.example/o/r https://github.com/o/r git@github.com:o/r.git ssh://git@github.com/o/r; do
  expect "accepted: ${v}" "[${v}]" 0 "${v}"
done

echo "--- unresolvable: refused, never read as private ---"
for v in not-a-repo a/b/c/d " " "a b/c" "o/" "/r" "o//r"; do
  refuses "-R '${v}' refused" 0 "${v}"
done
for v in not-a-repo a/b/c/d " " "a b/c"; do
  GH_REPO="${v}" refuses "GH_REPO='${v}' behind -R '' refused" 0 ""
  GH_REPO="${v}" refuses "GH_REPO='${v}' with no -R refused" 0
done
GH_REPO=not-a-repo expect "a malformed GH_REPO is not read when a -R names the repo" "[o/r]" 0 o/r
# Stricter than gh on purpose (header): refused, never sent.
GH_REPO=not-a-repo refuses "a malformed GH_REPO beside a URL refuses" 1
unset GH_REPO
refuses "an overridden malformed -R refuses" 0 junk o/r
GH_REPO=$'o/r\nx' refuses "a GH_REPO with a newline refuses" 0 ""
if [[ "${GTR_WHY}" != *$'\n'* ]]; then ok "the refusal shows the value quoted, with no raw newline"; else bad "quoted value" "${GTR_WHY}"; fi

echo
echo "gh-target-repo self-test: ${PASS} passed, ${FAIL} failed"
[ "${FAIL}" = 0 ]
