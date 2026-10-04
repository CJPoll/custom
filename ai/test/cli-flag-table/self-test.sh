#!/usr/bin/env bash
# Self-test for ai/bin/cli-flag-table (DND-1976).
#
# What it pins: gh-athena's and glab-athena's outbound scans read argv with a
# table of every flag of each command they judge and whether the flag takes a
# value. A flag the table wrongly calls a switch hands its value word to the
# next flag, which is how `-l -t -b X` sent X unscanned. The tables are built
# from the CLI's own help and a `--help --<flag>` probe, and pinned to one
# CLI version.
#
# Cases 1-9 run the tool against a stub CLI (CLI_FLAG_TABLE_BIN) that prints a
# fixed help: no real CLI, no network. Case 10 compares each committed table
# with the installed CLI when one is present: a local help read with no
# credentials (the tool strips every token and uses an empty config dir), and
# holds a table that cannot be compared to the copy landed on origin/main.
#
# Gated: ai/bin/harness-gate runs every tracked **/self-test.sh.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
AI_DIR="$(cd "${HERE}/../.." && pwd -P)"
TOOL="${AI_DIR}/bin/cli-flag-table"

TMP="$(mktemp -d)" || { echo "FAIL: mktemp"; exit 1; }
trap 'rm -rf "${TMP}"' EXIT INT TERM
PASS=0; FAIL=0
ok()  { printf '  ok    %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  FAIL  %s\n        %s\n' "$1" "$2"; FAIL=$((FAIL+1)); }

# The stub CLI. ${STUB_NAME} is its name in --version. Every command's help
# lists -t/--title (takes a value), -d/--draft (a switch) and the inherited
# --help; gh's `pr create` also has an ALIASES section. A probe
# `<cmd> --help --<flag>` fails with pflag's message for a flag named in
# ${STUB_VALUED}, misbehaves for one named in ${STUB_ODD}, and shows the help
# otherwise. ${STUB_NOFLAGS}=1 prints a help with no FLAGS section. In glab
# style (${STUB_NAME}=glab) headers are padded and flags are `-t --title`, and
# `mr new` is an alias of `mr create`; `issue new` does not exist.
STUB="${TMP}/cli"
cat > "${STUB}" <<'EOF'
#!/usr/bin/env bash
name="${STUB_NAME:-gh}"
if [ "$1" = --version ]; then
  if [ "$name" = gh ]; then echo "gh version ${STUB_VERSION:-9.9.9} (2026-01-01)"; else echo "WARNING: something"; echo "glab ${STUB_VERSION:-9.9.9} (abc)"; fi
  exit 0
fi
if [ "$name" = glab ] && [ "$1 $2" = "issue new" ]; then echo "unknown command"; exit 1; fi
last="${*: -1}"
case "$last" in
  --help) ;;
  --*)
    f="${last#--}"
    if [[ " ${STUB_ODD:-} " == *" $f "* ]]; then echo "something else went wrong"; exit 1; fi
    if [[ " ${STUB_VALUED:-title} " == *" $f "* ]]; then echo "Flag needs an argument: --$f"; exit 1; fi ;;
esac
echo "Do a thing."
echo
if [ "$name" = gh ] && [ "$1 $2" = "pr create" ]; then printf 'ALIASES\n  gh pr new\n\n'; fi
if [ "${STUB_NOFLAGS:-}" = 1 ]; then printf 'USAGE\n  thing\n'; exit 0; fi
if [ "$name" = gh ]; then
  printf 'FLAGS\n'
  printf '  -d, --draft        Mark it\n'
  printf '  -t, --title string Title for it\n'
  printf '                     a wrapped line that mentions --body in the text\n'
  printf '\nINHERITED FLAGS\n      --help   Show help\n\nEXAMPLES\n  $ gh thing --title x\n'
else
  printf '  FLAGS  \n         \n'
  printf '    -d --draft     Mark it\n'
  printf '    -t --title     Title for it\n'
  printf '         \n  EXAMPLES  \n    glab thing --title x\n'
fi
EOF
chmod +x "${STUB}"
export CLI_FLAG_TABLE_BIN="${STUB}" CLI_FLAG_TABLE_FILE="${TMP}/table.sh"

echo "cli-flag-table self-test"

echo "--- 1: --help prints usage on stdout, exit 0, and does nothing else ---"
out="$("${TOOL}" --help 2>/dev/null)"; rc=$?
if [ "${rc}" = 0 ] && [[ "${out}" == *"Usage:"* ]] && [ ! -e "${TMP}/table.sh" ]; then ok "--help"; else bad "--help" "rc=${rc}"; fi

echo "--- 2: --print reads flags, kinds and aliases from gh's help ---"
out="$("${TOOL}" --cli gh --print 2>&1)"; rc=$?
if [ "${rc}" = 0 ] && [[ "${out}" == *"['pr create']=' b:d:draft v:t:title b::help '"* ]] \
   && [[ "${out}" == *"['pr new']='pr create'"* ]] && [[ "${out}" == *"GFT_VERSION='9.9.9'"* ]] \
   && [[ "${out}" != *"body"* ]]; then
  ok "flags (a wrapped description line is not a flag), kinds, alias and version"
else
  bad "--print gh" "rc=${rc} ${out}"
fi

echo "--- 3: the printed table is valid bash that the scan can source ---"
printf '%s\n' "${out}" > "${TMP}/printed.sh"
if v="$(bash -c '. "$1"; printf "%s|%s" "${GFT_FLAGS[pr create]}" "${GFT_ALIAS[pr new]}"' _ "${TMP}/printed.sh")" \
   && [ "${v}" = " b:d:draft v:t:title b::help |pr create" ]; then ok "sourceable"; else bad "sourceable" "${v:-<failed>}"; fi

echo "--- 4: glab's help format, its version line, and an alias found by its flags ---"
out="$(STUB_NAME=glab "${TOOL}" --cli glab --print 2>&1)"; rc=$?
if [ "${rc}" = 0 ] && [[ "${out}" == *"['mr create']=' b:d:draft v:t:title '"* ]] && [[ "${out}" == *"LFT_VERSION='9.9.9'"* ]] \
   && [[ "${out}" == *"['mr new']='mr create'"* ]] && [[ "${out}" != *"['issue new']"* ]]; then
  ok "glab table"
else
  bad "--print glab" "rc=${rc} ${out}"
fi

echo "--- 5: --write, then --check on the same version: match ---"
"${TOOL}" --cli gh --write >/dev/null 2>&1; out="$("${TOOL}" --cli gh --check 2>&1)"; rc=$?
if [ "${rc}" = 0 ] && [[ "${out}" == *"OK"* ]]; then ok "write + check"; else bad "write + check" "rc=${rc} ${out}"; fi

echo "--- 6: a flag that changed kind is DRIFT (exit 1, with Fix:) ---"
out="$(STUB_VALUED="title draft" "${TOOL}" --cli gh --check 2>&1)"; rc=$?
if [ "${rc}" = 1 ] && [[ "${out}" == *"DRIFT"* ]] && [[ "${out}" == *"Fix:"* ]] && [[ "${out}" == *"v:d:draft"* ]]; then ok "drift named"; else bad "drift" "rc=${rc} ${out}"; fi

echo "--- 7: another version is not compared (exit 2, with Fix:) ---"
out="$(STUB_VERSION=1.0.0 "${TOOL}" --cli gh --check 2>&1)"; rc=$?
if [ "${rc}" = 2 ] && [[ "${out}" == *"pinned to gh 9.9.9"* ]] && [[ "${out}" == *"Fix:"* ]]; then ok "version mismatch"; else bad "version mismatch" "rc=${rc} ${out}"; fi

echo "--- 8: a probe it cannot read, or a help with no flags, cannot build a table (exit 3) ---"
out="$(STUB_ODD=draft "${TOOL}" --cli gh --print 2>&1)"; rc=$?
if [ "${rc}" = 3 ] && [[ "${out}" == *"--help --draft"* ]] && [[ "${out}" == *"Fix:"* ]]; then ok "an unreadable probe refuses"; else bad "odd probe" "rc=${rc} ${out}"; fi
out="$(STUB_NOFLAGS=1 "${TOOL}" --cli gh --print 2>&1)"; rc=$?
if [ "${rc}" = 3 ] && [[ "${out}" == *"lists no flags"* ]] && [[ "${out}" == *"Fix:"* ]]; then ok "a help with no flags refuses"; else bad "no flags" "rc=${rc} ${out}"; fi

echo "--- 9: usage errors ---"
for args in "" "--cli gh" "--print" "--cli gh --print --write" "--cli hg --print"; do
  # shellcheck disable=SC2086
  out="$("${TOOL}" ${args} 2>&1)"; rc=$?
  if [ "${rc}" = 64 ] && [[ "${out}" == *"Fix:"* ]]; then ok "usage: '${args}'"; else bad "usage: '${args}'" "rc=${rc} ${out}"; fi
done
out="$(CLI_FLAG_TABLE_BIN="${TMP}/no-such-cli" "${TOOL}" --cli gh --print 2>&1)"; rc=$?
if [ "${rc}" = 3 ] && [[ "${out}" == *"Fix:"* ]]; then ok "a missing CLI"; else bad "missing CLI" "rc=${rc} ${out}"; fi

echo "--- 10: each committed table matches the installed CLI, or is the landed one ---"
# The bar is outside this diff: where the installed CLI is not the pinned
# version, the committed table must be byte-identical to origin/main's, so a
# branch cannot change entries and the pin together and be waved through as
# "not compared". A CLI NEWER than the pin is drift this machine can measure
# once the table is regenerated, so it fails.
unset CLI_FLAG_TABLE_BIN CLI_FLAG_TABLE_FILE
REPO="$(cd "${AI_DIR}/.." && pwd -P)"
for cli in gh glab; do
  table_path="ai/lib/${cli}-flag-table.sh"
  out="$("${TOOL}" --cli "${cli}" --check 2>&1)"; rc=$?
  pin="$(sed -n "s/^[A-Z]*_VERSION='\(.*\)'$/\1/p" "${REPO}/${table_path}")"
  have="$(sed -n "s/.* is ${cli} \([0-9][0-9.]*\)\..*/\1/p" <<<"${out}")"
  case "${rc}" in
    0) ok "${cli}: the committed table matches the installed ${cli}" ;;
    2)
      if [ -n "${have}" ] && [ "${have}" != "${pin}" ] && [ "$(printf '%s\n%s\n' "${pin}" "${have}" | sort -V | tail -n1)" = "${have}" ]; then
        bad "${cli}: the installed ${cli} ${have} is newer than the pinned table (${cli} ${pin})" "Fix: run \`ai/bin/cli-flag-table --cli ${cli} --write\`, review the diff, and commit it."
      elif ! git -C "${REPO}" rev-parse --verify -q origin/main >/dev/null; then
        bad "${cli}: not compared, and origin/main cannot be read to check the table is the landed one" "${out} Fix: fetch origin (git fetch origin main), then re-run."
      elif ! git -C "${REPO}" cat-file -e "origin/main:${table_path}" 2>/dev/null; then
        ok "${cli}: not compared (${out#cli-flag-table: }); the table is new, with no landed copy to hold it to"
      elif [ "$(git -C "${REPO}" show "origin/main:${table_path}")" = "$(cat "${REPO}/${table_path}")" ]; then
        ok "${cli}: not compared (${out#cli-flag-table: }); the table is the landed one"
      else
        bad "${cli}: the table differs from origin/main's and cannot be compared here" "${out} Fix: regenerate and check it on a machine whose ${cli} is the pinned version (\`ai/bin/cli-flag-table --cli ${cli} --write\`, then --check)."
      fi ;;
    *) bad "${cli}: committed table vs installed ${cli}" "rc=${rc} ${out}" ;;
  esac
done

echo
echo "cli-flag-table self-test: ${PASS} passed, ${FAIL} failed"
[ "${FAIL}" -eq 0 ]
