#!/usr/bin/env bash
# Discovered self-test for scripts/athena-mcp-headers, the athena MCP
# headersHelper (DND-839).
#
# The contract Claude Code holds it to: on success, exit 0 with a JSON object of
# string headers on stdout; on failure, a non-zero exit (Claude Code reports the
# server as failed). This suite adds the harness's own rules: every refusal
# carries a Fix:, prints nothing on stdout, and never echoes the token; the
# config path resolves as athena:inbox's does; a config readable by others is
# refused. Every token is a sentinel.
set -euo pipefail

here="$(cd -- "$(dirname -- "$0")" && pwd -P)"
helper="${here}/../../athena-mcp-headers"
[ -x "${helper}" ] || { echo "FAIL not executable: ${helper}"; exit 1; }

fails=0
pass() { echo "PASS $1"; }
fail() { echo "FAIL $1"; fails=$((fails + 1)); }
assert_eq() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (want [$2] got [$3])"; fi; }
assert_contains() { case "$2" in *"$3"*) pass "$1" ;; *) fail "$1 (missing [$3])" ;; esac; }
assert_not_contains() { case "$2" in *"$3"*) fail "$1 (unexpected [$3])" ;; *) pass "$1" ;; esac; }

tmp="$(mktemp -d)"; trap 'rm -rf "${tmp}"' EXIT
SENT="SENTINEL-839-helper"

# run <config-json-or-ABSENT> [mode] [env...] -> sets OUT ERR RC. The config is
# written at the XDG default under a temp HOME unless an env assignment moves it.
run() {
  local body="$1" mode="${2:-600}"; shift 2 || shift $#
  local h; h="$(mktemp -d "${tmp}/h.XXXXXX")"
  mkdir -p "${h}/.config/athena-inbox-client"
  if [ "${body}" != "ABSENT" ]; then
    printf '%s' "${body}" > "${h}/.config/athena-inbox-client/config.json"
    chmod "${mode}" "${h}/.config/athena-inbox-client/config.json"
  fi
  set +e
  env -u ATHENA_INBOX_CLIENT_CONFIG -u XDG_CONFIG_HOME HOME="${h}" "$@" "${helper}" >"${tmp}/out" 2>"${tmp}/err"
  RC=$?
  set -e
  OUT="$(cat "${tmp}/out")"; ERR="$(cat "${tmp}/err")"
}
refused() { # <claim> <needle>
  assert_eq "$1: exits 1" "1" "${RC}"
  assert_eq "$1: prints nothing on stdout" "" "${OUT}"
  assert_contains "$1: carries a Fix:" "${ERR}" "Fix:"
  assert_contains "$1: names the cause" "${ERR}" "$2"
  assert_not_contains "$1: never echoes the token" "${ERR}" "${SENT}"
}

# --help: stdout only, exit 0, reads nothing.
set +e; out="$(HOME=/nonexistent "${helper}" --help 2>"${tmp}/help.err")"; rc=$?; set -e
assert_eq "--help exits 0" "0" "${rc}"
assert_contains "--help describes the tool" "${out}" "headersHelper"
assert_eq "--help writes nothing to stderr" "" "$(cat "${tmp}/help.err")"

# The hit: exactly one JSON object with one string header.
run "{\"token\":\"${SENT}\",\"server_url\":\"wss://x.test/ws\"}" 600
assert_eq "hit: exits 0" "0" "${RC}"
assert_eq "hit: prints exactly the Authorization header" "{\"Authorization\":\"Bearer ${SENT}\"}" "${OUT}"
assert_eq "hit: writes nothing to stderr" "" "${ERR}"

run "{\"token\":\"${SENT}\"}" 400
assert_eq "a 0400 config is accepted" "0" "${RC}"

# The override and XDG resolution (the same as athena:inbox's).
alt="${tmp}/alt.json"; printf '{"token":"%s-alt"}' "${SENT}" > "${alt}"; chmod 600 "${alt}"
run ABSENT 600 ATHENA_INBOX_CLIENT_CONFIG="${alt}"
assert_eq "ATHENA_INBOX_CLIENT_CONFIG is honoured" "{\"Authorization\":\"Bearer ${SENT}-alt\"}" "${OUT}"
mkdir -p "${tmp}/xdg/athena-inbox-client"; printf '{"token":"%s-xdg"}' "${SENT}" > "${tmp}/xdg/athena-inbox-client/config.json"
chmod 600 "${tmp}/xdg/athena-inbox-client/config.json"
run ABSENT 600 XDG_CONFIG_HOME="${tmp}/xdg"
assert_eq "XDG_CONFIG_HOME is honoured" "{\"Authorization\":\"Bearer ${SENT}-xdg\"}" "${OUT}"

# Refusals: each its own cause, none prints a header.
run ABSENT;                                   refused "no config" "no inbox client config"
run '{"server_url":"wss://x.test/ws"}' 600;   refused "no .token" "no usable .token"
run '{"token":""}' 600;                       refused "empty token" "no usable .token"
run '{"token":42}' 600;                       refused "non-string token" "no usable .token"
run "{\"token\":\"${SENT} x\"}" 600;          refused "token with a space" "no usable .token"
run "{\"token\":\"${SENT}\\nx\"}" 600;        refused "token with a newline" "no usable .token"
run '[1,2]' 600;                              refused "config not an object" "no usable .token"
run '{broken' 600;                            refused "config not JSON" "no usable .token"
run "{\"token\":\"${SENT}\"}" 644;            refused "group/world-readable config" "must be readable only by you"
run "{\"token\":\"${SENT}\"}" 640;            refused "group-readable config" "must be readable only by you"

# A symlinked config is refused (it could be redirected anywhere).
h="$(mktemp -d "${tmp}/h.XXXXXX")"; mkdir -p "${h}/.config/athena-inbox-client"
ln -s "${alt}" "${h}/.config/athena-inbox-client/config.json"
set +e; OUT="$(env -u ATHENA_INBOX_CLIENT_CONFIG -u XDG_CONFIG_HOME HOME="${h}" "${helper}" 2>"${tmp}/err")"; RC=$?; set -e
ERR="$(cat "${tmp}/err")"; refused "symlinked config" "not a regular file"

# Usage error.
set +e; OUT="$("${helper}" --bogus 2>"${tmp}/err")"; RC=$?; set -e
assert_eq "unknown argument exits 2" "2" "${RC}"
assert_contains "unknown argument carries a Fix:" "$(cat "${tmp}/err")" "Fix:"

# The token never reaches argv: jq is handed the path only. Shim jq to record
# its argv, then call the real jq.
real_jq="$(command -v jq)"; shim="${tmp}/shim"; mkdir -p "${shim}"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "%s/jq.argv"\nexec "%s" "$@"\n' "${tmp}" "${real_jq}" > "${shim}/jq"
chmod +x "${shim}/jq"
run "{\"token\":\"${SENT}\"}" 600 PATH="${shim}:${PATH}"
assert_eq "argv probe: still prints the header" "{\"Authorization\":\"Bearer ${SENT}\"}" "${OUT}"
assert_not_contains "the token is never in jq's argv" "$(cat "${tmp}/jq.argv")" "${SENT}"

if [ "${fails}" -eq 0 ]; then
  echo "athena-mcp-headers self-test: OK"; exit 0
else
  echo "athena-mcp-headers self-test: ${fails} failure(s)"; exit 1
fi
