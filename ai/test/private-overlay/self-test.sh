#!/usr/bin/env bash
# Self-test for ai/bin/private-overlay (DND-702).
#
# The design's 14-case resolver table, plus the root-permission, status and
# root cases. Every case but the hit feeds a MISSING or WRONG input and asserts
# the resolver SAYS so -- a distinct exit, a stderr line naming the state and
# the key, and a Fix: -- never an empty value with exit 0
# (~/dev/custom/CLAUDE.md -> "A failed lookup must never look like an empty one").
#
# Hermetic: fixture roots under mktemp -d, a fake HOME, synthetic values only
# (UFAKE00001 and friends). The real overlay directory is never read: HOME is
# the fixture, and ATHENA_PRIVATE_ROOT is set or unset per case.
#
# Run another copy of the tool (old-vs-new evidence) with
#   PRIVATE_OVERLAY_UNDER_TEST=/path/to/private-overlay bash ai/test/private-overlay/self-test.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT="$(cd "${HERE}/../../.." && pwd -P)"
TOOL="${PRIVATE_OVERLAY_UNDER_TEST:-${ROOT}/ai/bin/private-overlay}"

TMP="$(mktemp -d)" || { echo "FAIL: mktemp"; exit 1; }
trap 'rm -rf "${TMP}"' EXIT INT TERM
PASS=0; FAIL=0
ok()  { printf '  ok    %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  FAIL  %s\n        %s\n' "$1" "$2"; FAIL=$((FAIL+1)); }

VALUE="UFAKE00001"
SECRETISH="SYNTH-TOKEN-1"

# mk_root <dir> : a valid overlay root (0700, marker, slack.json with a value).
mk_root() {
  local d="$1"
  mkdir -p "${d}/overlay"
  chmod 700 "${d}"
  printf '{"kind":"athena-private-overlay","schema":1}\n' > "${d}/athena-overlay.json"
  cat > "${d}/overlay/slack.json" <<EOF
{"people":{"owner":{"user_id":"${VALUE}","name":"Synthetic Owner"},"blank":{"user_id":""},"ws":{"user_id":"   "},"gone":{"user_id":null}},
 "channels":{"general":"CFAKE00001"},
 "vip":["${SECRETISH}"], "empty_list":[], "count":3}
EOF
}

# run_po <env-mode> <args...> ; env-mode: "unset" or a value for ATHENA_PRIVATE_ROOT.
# Sets OUT, ERR, RC.
run_po() {
  local mode="$1"; shift
  if [ "${mode}" = unset ]; then
    OUT="$(env -u ATHENA_PRIVATE_ROOT HOME="${FAKE_HOME}" "${TOOL}" "$@" 2>"${TMP}/err")"; RC=$?
  else
    OUT="$(env HOME="${FAKE_HOME}" ATHENA_PRIVATE_ROOT="${mode}" "${TOOL}" "$@" 2>"${TMP}/err")"; RC=$?
  fi
  ERR="$(cat "${TMP}/err")"
}

# expect_fail <label> <exit> <state> <needle-in-stderr>
expect_fail() {
  local label="$1" want="$2" state="$3" needle="$4"
  local lines
  lines="$(printf '%s' "${ERR}" | grep -c '' || true)"
  if [ "${RC}" = "${want}" ] && [ -z "${OUT}" -o "${state}" = ABSENT -o "${state}" = MALFORMED ] \
     && [[ "${ERR}" == *"private-overlay: ${state}:"* ]] && [[ "${ERR}" == *"Fix:"* ]] \
     && [[ "${ERR}" == *"${needle}"* ]] && [ "${lines}" = 1 ] \
     && [[ "${ERR}" != *"${VALUE}"* ]] && [[ "${OUT}" != *"${VALUE}"* ]] \
     && [[ "${ERR}" != *"${SECRETISH}"* ]]; then
    ok "${label} (exit ${RC}, ${state})"
  else
    bad "${label}" "want exit ${want} ${state} with '${needle}', one stderr line, no value; got rc=${RC} out=[${OUT}] err=[${ERR}]"
  fi
}

FAKE_HOME="${TMP}/home"; mkdir -p "${FAKE_HOME}"
DEFAULT="${FAKE_HOME}/.config/athena/work"

echo "private-overlay self-test"
echo "tool: ${TOOL}"
echo

echo "--- 1: env unset, no default dir -> ABSENT ---"
run_po unset get slack .people.owner.user_id
expect_fail "1 absent" 3 ABSENT "probed=${DEFAULT}"
if [[ "${ERR}" == *"unavailable"* ]] && [[ "${ERR}" != *"git clone"* ]]; then
  ok "1 absent Fix says unavailable here and never says git clone"
else
  bad "1 absent Fix wording" "${ERR}"
fi
if [[ "${ERR}" == *"key=slack.people.owner.user_id"* ]]; then ok "1 absent names the key"; else bad "1 absent names the key" "${ERR}"; fi
[ -z "${OUT}" ] && ok "1 absent: stdout empty for get" || bad "1 absent: stdout empty for get" "${OUT}"

echo "--- 2: env relative -> MALFORMED ---"
run_po "relative/path" get slack .people.owner.user_id
expect_fail "2 relative env" 4 MALFORMED "not an absolute path"

echo "--- 3: env names a missing dir while the default is valid -> MALFORMED, no fallthrough ---"
mk_root "${DEFAULT}"
run_po "${TMP}/nope" get slack .people.owner.user_id
expect_fail "3 no fallthrough" 4 MALFORMED "does not exist"
run_po "" get slack .people.owner.user_id
expect_fail "3b set-but-empty env" 4 MALFORMED "set but empty"

echo "--- 4: default present, no marker -> MALFORMED ---"
rm -f "${DEFAULT}/athena-overlay.json"
run_po unset get slack .people.owner.user_id
expect_fail "4 marker missing" 4 MALFORMED "marker athena-overlay.json is missing"

echo "--- 5: marker bad JSON / wrong kind / schema 99 -> MALFORMED naming which ---"
printf '{nope' > "${DEFAULT}/athena-overlay.json"
run_po unset get slack .people.owner.user_id
expect_fail "5a marker bad JSON" 4 MALFORMED "not valid JSON"
printf '{"kind":"something-else","schema":1}' > "${DEFAULT}/athena-overlay.json"
run_po unset get slack .people.owner.user_id
expect_fail "5b marker wrong kind" 4 MALFORMED "has kind other than"
printf '{"kind":"athena-private-overlay","schema":99}' > "${DEFAULT}/athena-overlay.json"
run_po unset get slack .people.owner.user_id
expect_fail "5c marker schema 99" 4 MALFORMED "schema 99 is unsupported"
printf '[1]' > "${DEFAULT}/athena-overlay.json"
run_po unset get slack .people.owner.user_id
expect_fail "5d marker not an object" 4 MALFORMED "not a JSON object"
printf '{"kind":"athena-private-overlay"}' > "${DEFAULT}/athena-overlay.json"
run_po unset get slack .people.owner.user_id
expect_fail "5e marker schema missing" 4 MALFORMED "missing or not an integer"

echo "--- 6: valid root, no overlay/slack.json -> KEY_NOT_FOUND naming the file ---"
R6="${TMP}/r6"; mk_root "${R6}"; rm "${R6}/overlay/slack.json"
run_po "${R6}" get slack .people.owner.user_id
expect_fail "6 file missing" 5 KEY_NOT_FOUND "overlay/slack.json does not exist"

echo "--- 7: slack.json unparseable -> MALFORMED ---"
R7="${TMP}/r7"; mk_root "${R7}"; printf '{"people":' > "${R7}/overlay/slack.json"
run_po "${R7}" get slack .people.owner.user_id
expect_fail "7 file unparseable" 4 MALFORMED "overlay/slack.json is not valid JSON"

R="${TMP}/good"; mk_root "${R}"

echo "--- 8: key absent; key null -> KEY_NOT_FOUND naming the key ---"
run_po "${R}" get slack .people.nobody.user_id
expect_fail "8a key absent" 5 KEY_NOT_FOUND "slack.people.nobody is not present"
run_po "${R}" get slack .people.gone.user_id
expect_fail "8b key null" 5 KEY_NOT_FOUND "slack.people.gone.user_id is null"
run_po "${R}" get slack .vip[3]
expect_fail "8c index out of range" 5 KEY_NOT_FOUND "slack.vip[3] is not present"

echo "--- 9: empty value -> MALFORMED ---"
run_po "${R}" get slack .people.blank.user_id
expect_fail "9a empty string" 4 MALFORMED "is an empty string"
run_po "${R}" get slack .people.ws.user_id
expect_fail "9b whitespace string" 4 MALFORMED "is an empty string"
run_po "${R}" get slack .empty_list
expect_fail "9c empty array" 4 MALFORMED "is an empty array"
run_po "${R}" get slack .people.owner.user_id.deeper
expect_fail "9d wrong type on the way down" 4 MALFORMED "is not an object"

echo "--- 10: valid -> value on stdout, stderr empty ---"
run_po "${R}" get slack .people.owner.user_id
if [ "${RC}" = 0 ] && [ "${OUT}" = "${VALUE}" ] && [ -z "${ERR}" ]; then ok "10 found"; else bad "10 found" "rc=${RC} out=[${OUT}] err=[${ERR}]"; fi
run_po "${R}" get slack .vip[0]
if [ "${RC}" = 0 ] && [ "${OUT}" = "${SECRETISH}" ]; then ok "10b array index"; else bad "10b array index" "rc=${RC} out=[${OUT}]"; fi
run_po "${R}" get slack .channels
if [ "${RC}" = 0 ] && [ "${OUT}" = '{"general":"CFAKE00001"}' ]; then ok "10c object as compact JSON"; else bad "10c object" "rc=${RC} out=[${OUT}]"; fi
run_po "${R}" get slack .count
if [ "${RC}" = 0 ] && [ "${OUT}" = 3 ]; then ok "10d number"; else bad "10d number" "rc=${RC} out=[${OUT}]"; fi

echo "--- 11: env root wins over a valid default ---"
mk_root "${DEFAULT}"
sed -i "s/${VALUE}/UFAKE00002/" "${DEFAULT}/overlay/slack.json"
run_po "${R}" get slack .people.owner.user_id
if [ "${RC}" = 0 ] && [ "${OUT}" = "${VALUE}" ]; then ok "11 env root wins"; else bad "11 env root wins" "rc=${RC} out=[${OUT}]"; fi
run_po unset get slack .people.owner.user_id
if [ "${RC}" = 0 ] && [ "${OUT}" = "UFAKE00002" ]; then ok "11b default used when env unset"; else bad "11b default" "rc=${RC} out=[${OUT}]"; fi

echo "--- 12: file names with / or .. -> USAGE, nothing read ---"
for f in "../x" "a/b" "Slack" "" "slack.json"; do
  run_po "${TMP}/does-not-exist" get "${f}" .people
  # The root is invalid: a resolve would say MALFORMED. USAGE proves nothing was read.
  expect_fail "12 file '${f}'" 2 USAGE "is not [a-z0-9-]+"
done
for p in "people" "." ".a..b" ".a[x]" ""; do
  run_po "${R}" get slack "${p}"
  expect_fail "12 path '${p}'" 2 USAGE "must start with '.'"
done
run_po "${R}" get slack
expect_fail "12 missing arg" 2 USAGE "unrecognised arguments"
run_po "${R}"
expect_fail "12 no command" 2 USAGE "no command given"
run_po "${R}" frobnicate
expect_fail "12 unknown command" 2 USAGE "unrecognised arguments"

echo "--- 13: a failure where the file holds a value never puts it on stderr ---"
# 9a/8b above already assert the absence of the value on every failure. One more:
# the key is missing next to a present value, and a MALFORMED sibling.
run_po "${R}" get slack .people.owner.missing
expect_fail "13 value never on stderr" 5 KEY_NOT_FOUND "slack.people.owner.missing is not present"

echo "--- 14: --help: stdout, exit 0, no writes ---"
H="${TMP}/help-home"; mkdir -p "${H}"
before="$(find "${TMP}" | sort | md5sum)"
OUT="$(cd "${H}" && env HOME="${H}" ATHENA_PRIVATE_ROOT=/nonexistent "${TOOL}" --help 2>"${TMP}/err")"; RC=$?
after="$(find "${TMP}" | sort | md5sum)"
if [ "${RC}" = 0 ] && [[ "${OUT}" == *"Usage:"* ]] && [ ! -s "${TMP}/err" ] && [ "${before}" = "${after}" ]; then
  ok "14 --help"
else
  bad "14 --help" "rc=${RC} err=$(cat "${TMP}/err")"
fi

echo "--- root permissions and ownership ---"
RP="${TMP}/perm"; mk_root "${RP}"; chmod 755 "${RP}"
run_po "${RP}" get slack .people.owner.user_id
expect_fail "perm 0755 root refused" 4 MALFORMED "group/other access (mode 0755)"
RF="${TMP}/afile"; : > "${RF}"
run_po "${RF}" status
expect_fail "root is a file" 4 MALFORMED "not a directory"
if [ "${OUT}" = "MALFORMED reason=the root is not a directory" ]; then ok "status MALFORMED line"; else bad "status MALFORMED line" "${OUT}"; fi

echo "--- a symlinked root resolves to its realpath ---"
ln -s "${R}" "${TMP}/link"
run_po "${TMP}/link" root
if [ "${RC}" = 0 ] && [ "${OUT}" = "$(cd "${R}" && pwd -P)" ]; then ok "root realpath"; else bad "root realpath" "rc=${RC} out=[${OUT}] err=[${ERR}]"; fi

echo "--- status / root ---"
run_po "${R}" status
if [ "${RC}" = 0 ] && [ "${OUT}" = "PRESENT root=$(cd "${R}" && pwd -P)" ] && [ -z "${ERR}" ]; then ok "status PRESENT"; else bad "status PRESENT" "rc=${RC} out=[${OUT}] err=[${ERR}]"; fi
rm -rf "${DEFAULT}"
run_po unset status
expect_fail "status ABSENT" 3 ABSENT "probed=${DEFAULT}"
if [ "${OUT}" = "ABSENT probed=${DEFAULT}" ]; then ok "status ABSENT line"; else bad "status ABSENT line" "${OUT}"; fi
run_po unset root
expect_fail "root ABSENT" 3 ABSENT "probed=${DEFAULT}"
[ -z "${OUT}" ] && ok "root ABSENT: stdout empty" || bad "root ABSENT: stdout empty" "${OUT}"
OUT="$(env -u ATHENA_PRIVATE_ROOT -u HOME "${TOOL}" status 2>"${TMP}/err")"; RC=$?; ERR="$(cat "${TMP}/err")"
expect_fail "HOME unset is MALFORMED, not ABSENT" 4 MALFORMED "HOME is unset or empty"

echo
echo "private-overlay self-test: ${PASS} passed, ${FAIL} failed"
[ "${FAIL}" -eq 0 ]
