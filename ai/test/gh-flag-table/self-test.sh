#!/usr/bin/env bash
# Self-test for ai/bin/gh-flag-table (DND-1976).
#
# What it pins: gh-athena's outbound scan reads argv with a table of every flag
# of each command it judges and whether the flag takes a value. A flag the
# table wrongly calls a switch hands its value word to the next flag, which is
# how `-l -t -b X` sent X unscanned. The table is built from gh's own help
# and a `--help --<flag>` probe, and pinned to one gh version.
#
# Cases 1-8 run the tool against a stub gh (GH_FLAG_TABLE_GH) that prints a
# fixed help: no real gh, no network. The last case compares the committed
# table with the installed gh when one is present: a local help read with no
# credentials (the tool strips every token and uses an empty config dir).
#
# Gated: ai/bin/harness-gate runs every tracked **/self-test.sh.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
AI_DIR="$(cd "${HERE}/../.." && pwd -P)"
TOOL="${AI_DIR}/bin/gh-flag-table"

TMP="$(mktemp -d)" || { echo "FAIL: mktemp"; exit 1; }
trap 'rm -rf "${TMP}"' EXIT INT TERM
PASS=0; FAIL=0
ok()  { printf '  ok    %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  FAIL  %s\n        %s\n' "$1" "$2"; FAIL=$((FAIL+1)); }

# The stub gh. Every command's help lists -t/--title (takes a value), -d/--draft
# (a switch) and the inherited --help; `pr create` also has an ALIASES section.
# A probe `<cmd> --help --<flag>` fails with pflag's message for a flag named in
# ${STUB_VALUED}, misbehaves for one named in ${STUB_ODD}, and shows the help
# otherwise. ${STUB_NOFLAGS}=1 prints a help with no FLAGS section.
STUB="${TMP}/gh"
cat > "${STUB}" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = --version ]; then echo "gh version ${STUB_VERSION:-9.9.9} (2026-01-01)"; exit 0; fi
last="${*: -1}"
case "$last" in
  --help) ;;
  --*)
    f="${last#--}"
    if [[ " ${STUB_ODD:-} " == *" $f "* ]]; then echo "something else went wrong"; exit 1; fi
    if [[ " ${STUB_VALUED:-title} " == *" $f "* ]]; then echo "flag needs an argument: --$f"; exit 1; fi ;;
esac
echo "Do a thing."
echo
if [ "$1 $2" = "pr create" ]; then printf 'ALIASES\n  gh pr new\n\n'; fi
if [ "${STUB_NOFLAGS:-}" = 1 ]; then printf 'USAGE\n  gh thing\n'; exit 0; fi
printf 'FLAGS\n'
printf '  -d, --draft        Mark it\n'
printf '  -t, --title string Title for it\n'
printf '                     a wrapped line that mentions --body in the text\n'
printf '\nINHERITED FLAGS\n      --help   Show help\n\nEXAMPLES\n  $ gh thing --title x\n'
EOF
chmod +x "${STUB}"
export GH_FLAG_TABLE_GH="${STUB}" GH_FLAG_TABLE_FILE="${TMP}/table.sh"

echo "gh-flag-table self-test"

echo "--- 1: --help prints usage on stdout, exit 0, and does nothing else ---"
out="$("${TOOL}" --help 2>/dev/null)"; rc=$?
if [ "${rc}" = 0 ] && [[ "${out}" == *"Usage:"* ]] && [ ! -e "${TMP}/table.sh" ]; then ok "--help"; else bad "--help" "rc=${rc}"; fi

echo "--- 2: --print reads flags, kinds and aliases from the help ---"
out="$("${TOOL}" --print 2>&1)"; rc=$?
if [ "${rc}" = 0 ] && [[ "${out}" == *"['pr create']=' b:d:draft v:t:title b::help '"* ]] \
   && [[ "${out}" == *"['pr new']='pr create'"* ]] && [[ "${out}" == *"GFT_GH_VERSION='9.9.9'"* ]] \
   && [[ "${out}" != *"body"* ]]; then
  ok "flags (a wrapped description line is not a flag), kinds, alias and version"
else
  bad "--print" "rc=${rc} ${out}"
fi

echo "--- 3: the printed table is valid bash that the scan can source ---"
printf '%s\n' "${out}" > "${TMP}/printed.sh"
if v="$(bash -c '. "$1"; printf "%s|%s" "${GFT_FLAGS[pr create]}" "${GFT_ALIAS[pr new]}"' _ "${TMP}/printed.sh")" \
   && [ "${v}" = " b:d:draft v:t:title b::help |pr create" ]; then ok "sourceable"; else bad "sourceable" "${v:-<failed>}"; fi

echo "--- 4: --write, then --check on the same version: match ---"
"${TOOL}" --write >/dev/null 2>&1; out="$("${TOOL}" --check 2>&1)"; rc=$?
if [ "${rc}" = 0 ] && [[ "${out}" == *"OK"* ]]; then ok "write + check"; else bad "write + check" "rc=${rc} ${out}"; fi

echo "--- 5: a flag that changed kind is DRIFT (exit 1, with Fix:) ---"
out="$(STUB_VALUED="title draft" "${TOOL}" --check 2>&1)"; rc=$?
if [ "${rc}" = 1 ] && [[ "${out}" == *"DRIFT"* ]] && [[ "${out}" == *"Fix:"* ]] && [[ "${out}" == *"v:d:draft"* ]]; then ok "drift named"; else bad "drift" "rc=${rc} ${out}"; fi

echo "--- 6: another gh version is not compared (exit 2, with Fix:) ---"
out="$(STUB_VERSION=1.0.0 "${TOOL}" --check 2>&1)"; rc=$?
if [ "${rc}" = 2 ] && [[ "${out}" == *"pinned to gh 9.9.9"* ]] && [[ "${out}" == *"Fix:"* ]]; then ok "version mismatch"; else bad "version mismatch" "rc=${rc} ${out}"; fi

echo "--- 7: a probe it cannot read, or a help with no flags, cannot build a table (exit 3) ---"
out="$(STUB_ODD=draft "${TOOL}" --print 2>&1)"; rc=$?
if [ "${rc}" = 3 ] && [[ "${out}" == *"--help --draft"* ]] && [[ "${out}" == *"Fix:"* ]]; then ok "an unreadable probe refuses"; else bad "odd probe" "rc=${rc} ${out}"; fi
out="$(STUB_NOFLAGS=1 "${TOOL}" --print 2>&1)"; rc=$?
if [ "${rc}" = 3 ] && [[ "${out}" == *"lists no flags"* ]] && [[ "${out}" == *"Fix:"* ]]; then ok "a help with no flags refuses"; else bad "no flags" "rc=${rc} ${out}"; fi

echo "--- 8: usage errors ---"
out="$("${TOOL}" 2>&1)"; rc=$?
if [ "${rc}" = 64 ] && [[ "${out}" == *"Fix:"* ]]; then ok "no mode"; else bad "no mode" "rc=${rc} ${out}"; fi
out="$("${TOOL}" --print --write 2>&1)"; rc=$?
if [ "${rc}" = 64 ] && [[ "${out}" == *"Fix:"* ]]; then ok "two modes"; else bad "two modes" "rc=${rc} ${out}"; fi
out="$(GH_FLAG_TABLE_GH="${TMP}/no-such-gh" "${TOOL}" --print 2>&1)"; rc=$?
if [ "${rc}" = 3 ] && [[ "${out}" == *"Fix:"* ]]; then ok "a missing gh"; else bad "missing gh" "rc=${rc} ${out}"; fi

echo "--- 9: the committed table matches the installed gh (when it is the pinned version) ---"
unset GH_FLAG_TABLE_GH GH_FLAG_TABLE_FILE
out="$("${TOOL}" --check 2>&1)"; rc=$?
case "${rc}" in
  0) ok "committed table matches the installed gh" ;;
  2) ok "not compared: ${out#gh-flag-table: }" ;;
  *) bad "committed table vs installed gh" "rc=${rc} ${out}" ;;
esac

echo
echo "gh-flag-table self-test: ${PASS} passed, ${FAIL} failed"
[ "${FAIL}" -eq 0 ]
