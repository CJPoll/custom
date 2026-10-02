#!/usr/bin/env bash
# Discovered self-test for scripts/lib/lead-time-repos.sh (DND-1604): the one
# reader of `ai/bin/lead-time-repos --json` that the lead-time runner and
# setup-leadtime-cron share.
#
# Each case runs lt_repos_resolve against a fake resolver (a script that prints
# a fixed --json and exits a fixed code) and asserts every LT_RES_* variable.
# The fault cases assert the miss is an error at its source, never an empty
# list: a malformed --json, a resolver that exits 0 listing no repo, and one
# that prints nothing at all.
set -euo pipefail

here="$(cd -- "$(dirname -- "$0")" && pwd -P)"
helper="${here}/../../lib/lead-time-repos.sh"
[ -r "${helper}" ] || { echo "FAIL helper not readable: ${helper}"; exit 1; }
# shellcheck source=scripts/lib/lead-time-repos.sh
. "${helper}"

fails=0
passes=0
tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT
US=$'\x1f'

ok()  { echo "PASS $1"; passes=$((passes + 1)); }
bad() { echo "FAIL $1"; fails=$((fails + 1)); }
eq() { # desc expected actual
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (want [$2] got [$3])"; fi
}

# fake <name> <exit> <stdout-file|-> [<stderr text>] — a resolver at
# ${tmp}/<name> that prints the file (nothing for -), the stderr text, and
# exits <exit>. Prints its path.
fake() {
  local p="${tmp}/$1"
  {
    printf '#!/bin/sh\n'
    [ "$3" = - ] || printf "cat '%s'\n" "$3"
    [ -z "${4:-}" ] || printf "printf '%%s\\\\n' '%s' >&2\n" "$4"
    printf 'exit %s\n' "$2"
  } >"${p}"
  chmod +x "${p}"
  printf '%s' "${p}"
}
# json <name> — writes stdin to ${tmp}/<name>.json and prints the path.
json() { cat >"${tmp}/$1.json"; printf '%s' "${tmp}/$1.json"; }

# all_empty — every on-success variable is empty: no half-read list survives.
all_empty() {
  [ -z "${LT_RES_JSON}${LT_RES_SOURCE}${LT_RES_PATH}${LT_RES_CONSIDERED}${LT_RES_REPOS}" ] \
    && [ -z "${LT_RES_NAMES}${LT_RES_DESC}${LT_RES_TSV}${LT_RES_SKIPPED}${LT_RES_SKIPPED_RUN}${LT_RES_TEXT}" ]
}

# --- 1. a healthy list: every field, in each caller's form ------------------
j="$(json healthy <<'EOF'
{"source":"override","path":"/cfg/lead-time-repos.json","window":20,
 "repos":[{"name":"custom","path":"/src/custom","mode":"improve","idle_workflow":"none"},
          {"name":"fakeapp","path":"/src/fakeapp","mode":"watch","idle_workflow":null}],
 "skipped":[{"name":"ghost","path":"/src/ghost","reason":"not checked out here"}],
 "considered":3}
EOF
)"
lt_repos_resolve "$(fake healthy 0 "${j}")"
eq "healthy: RC 0" 0 "${LT_RES_RC}"
eq "healthy: fault none" none "${LT_RES_FAULT}"
eq "healthy: ran exit 0" "exit 0" "${LT_RES_RAN}"
eq "healthy: source" override "${LT_RES_SOURCE}"
eq "healthy: path" /cfg/lead-time-repos.json "${LT_RES_PATH}"
eq "healthy: considered" 3 "${LT_RES_CONSIDERED}"
eq "healthy: names" custom,fakeapp "${LT_RES_NAMES}"
eq "healthy: desc" "custom (improve, /src/custom); fakeapp (watch, /src/fakeapp)" "${LT_RES_DESC}"
eq "healthy: tsv" "custom"$'\t'"improve"$'\n'"fakeapp"$'\t'"watch" "${LT_RES_TSV}"
eq "healthy: repos rows (a null idle_workflow is empty)" \
  "custom${US}improve${US}/src/custom${US}none"$'\n'"fakeapp${US}watch${US}/src/fakeapp${US}" "${LT_RES_REPOS}"
eq "healthy: skipped (brief form)" "ghost (not checked out here)" "${LT_RES_SKIPPED}"
eq "healthy: skipped (.run form)" "ghost(not checked out here)" "${LT_RES_SKIPPED_RUN}"
want_text="Repos (ai/bin/lead-time-repos: source=override /cfg/lead-time-repos.json):
  custom    improve /src/custom
  fakeapp   watch   /src/fakeapp
  skipped ghost: not checked out here
  3 considered, 2 resolved, 1 skipped"
eq "healthy: printable text" "${want_text}" "${LT_RES_TEXT}"
eq "healthy: the --json is kept as printed" "$(cat "${j}")" "${LT_RES_JSON}"

# --- 2. no skip: the .run form says none; a long name still gets a space -----
j="$(json noskip <<'EOF'
{"source":"default","path":"/cfg/d.json","repos":[{"name":"averyverylongname","path":"/p","mode":"improve"}],"considered":1}
EOF
)"
lt_repos_resolve "$(fake noskip 0 "${j}")"
eq "no skip: RC 0" 0 "${LT_RES_RC}"
eq "no skip: skipped empty" "" "${LT_RES_SKIPPED}"
eq "no skip: .run form none" none "${LT_RES_SKIPPED_RUN}"
eq "no skip: a name past the column keeps one space" "  averyverylongname improve /p" "$(printf '%s\n' "${LT_RES_TEXT}" | sed -n 2p)"

# --- 3. a value with a newline or the field separator never shifts a field ---
printf '{"source":"default","path":"/a\\nb","repos":[{"name":"x","path":"/p\\u001fq","mode":"watch"}],"considered":1}\n' >"${tmp}/nl.json"
lt_repos_resolve "$(fake nl 0 "${tmp}/nl.json")"
eq "flattened: RC 0" 0 "${LT_RES_RC}"
eq "flattened: newline in path becomes a space" "/a b" "${LT_RES_PATH}"
eq "flattened: separator in a value becomes a space" "x${US}watch${US}/p q${US}" "${LT_RES_REPOS}"

# --- 4. the faults: each is an error at its source, never an empty list -------
# unreadable <label> <stdout-file|-> <detail needle>
unreadable() {
  lt_repos_resolve "$(fake "u$RANDOM" 0 "$2")"
  if [ "${LT_RES_RC}" = 1 ] && [ "${LT_RES_FAULT}" = unreadable ] && [ "${LT_RES_RAN}" = "exit 0" ] \
     && grep -qF -- "$3" <<<"${LT_RES_DETAIL}" && all_empty; then
    ok "$1: RC 1, fault unreadable, detail names it, every list variable empty"
  else
    bad "$1: rc=${LT_RES_RC} fault=${LT_RES_FAULT} detail=${LT_RES_DETAIL} names=${LT_RES_NAMES}"
  fi
}
printf 'this is not json {\n' >"${tmp}/garbage.json"
unreadable "malformed --json" "${tmp}/garbage.json" "parse error"
printf '{"source":"default","path":"/c","repos":[],"skipped":[],"considered":0}\n' >"${tmp}/empty.json"
unreadable "exit 0 with an empty repo list" "${tmp}/empty.json" "no resolved repos"
printf '{"source":"default","path":"/c","considered":0}\n' >"${tmp}/norepos.json"
unreadable "exit 0 with no repos key" "${tmp}/norepos.json" "no resolved repos"
unreadable "exit 0 printing nothing at all" - "no repo record"
printf '[1,2]\n' >"${tmp}/array.json"
unreadable "a JSON array, not an object" "${tmp}/array.json" "not a JSON object"
printf '{"source":"default","path":"/c","repos":[{"path":"/p","mode":"watch"}],"considered":1}\n' >"${tmp}/noname.json"
unreadable "a repo with no name" "${tmp}/noname.json" "no string name"
printf '{"source":"default","path":"/c","repos":[{"name":"x","path":"/p","mode":null}],"considered":1}\n' >"${tmp}/nomode.json"
unreadable "a repo whose mode is null" "${tmp}/nomode.json" "no string mode"
printf '{"source":"default","path":"/c","repos":[{"name":"x","path":"/p","mode":"watch"}],"skipped":"no","considered":1}\n' >"${tmp}/badskip.json"
unreadable "skipped that is not an array" "${tmp}/badskip.json" ".skipped is not an array"

# A fault after a success leaves nothing of the earlier list behind.
lt_repos_resolve "$(fake again 0 "${tmp}/healthy.json")"
lt_repos_resolve "$(fake again2 0 "${tmp}/empty.json")"
if all_empty; then ok "a fault after a healthy read clears the earlier list"; else bad "stale list after a fault: ${LT_RES_NAMES}"; fi

# --- 5. the resolver's own refusal keeps its exit and its stderr -------------
lt_repos_resolve "$(fake refused 3 - 'lead-time-repos: cannot read /cfg' )"
eq "resolver exit 3: RC is its exit" 3 "${LT_RES_RC}"
eq "resolver exit 3: fault resolver-exit" resolver-exit "${LT_RES_FAULT}"
eq "resolver exit 3: ran exit 3" "exit 3" "${LT_RES_RAN}"
eq "resolver exit 3: stderr kept" "lead-time-repos: cannot read /cfg" "${LT_RES_ERR}"
if all_empty; then ok "resolver exit 3: no list"; else bad "resolver exit 3 left a list"; fi
# A non-zero exit is a fault even when stdout holds a well-formed list.
lt_repos_resolve "$(fake exit4 4 "${tmp}/healthy.json")"
if [ "${LT_RES_RC}" = 4 ] && [ "${LT_RES_FAULT}" = resolver-exit ] && all_empty; then
  ok "resolver exit 4 with a list on stdout: still a fault, the list ignored"
else
  bad "exit 4 with stdout: rc=${LT_RES_RC} names=${LT_RES_NAMES}"
fi

# --- 6. what never ran: the resolver missing, not executable, or no jq --------
lt_repos_resolve "${tmp}/no-such-resolver"
eq "resolver missing: RC 127" 127 "${LT_RES_RC}"
eq "resolver missing: fault" resolver-missing "${LT_RES_FAULT}"
eq "resolver missing: not run" "not run" "${LT_RES_RAN}"
cp "${tmp}/healthy" "${tmp}/noexec"; chmod -x "${tmp}/noexec"
lt_repos_resolve "${tmp}/noexec"
eq "resolver not executable: fault resolver-missing" resolver-missing "${LT_RES_FAULT}"
lt_repos_resolve ""
eq "no resolver path at all: fault resolver-missing" resolver-missing "${LT_RES_FAULT}"
# A PATH holding everything but jq.
mkdir -p "${tmp}/nojq"
for c in mktemp cat rm tr; do ln -s "$(command -v "$c")" "${tmp}/nojq/$c"; done
out="$(PATH="${tmp}/nojq" "${BASH}" -c '. "$1"; lt_repos_resolve "$2"; printf "%s %s %s" "$LT_RES_RC" "$LT_RES_FAULT" "$LT_RES_RAN"' _ "${helper}" "${tmp}/healthy")"
eq "no jq: RC 127, fault jq-missing, resolver not run" "127 jq-missing not run" "${out}"

# --- 7. safe under set -euo pipefail: a fault returns 0 and prints nothing ----
out="$(bash -c 'set -euo pipefail; . "$1"; lt_repos_resolve "$2"; echo "rc=$? fault=$LT_RES_FAULT"' _ "${helper}" "${tmp}/$(basename "$(fake strict 0 "${tmp}/garbage.json")")" 2>&1)"
eq "set -euo pipefail: a malformed list returns 0, prints nothing" "rc=0 fault=unreadable" "${out}"

echo
echo "${passes} passed, ${fails} failed"
[ "${fails}" -eq 0 ]
