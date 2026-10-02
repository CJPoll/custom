#!/usr/bin/env bash
# Self-test for ai/bin/priority-next (DND-445).
#
# The MCP server is faked by a curl shim on PATH: the tool's only transport is
# curl reading its config on stdin (athena:inbox lib/mcp.sh), so the shim
# answers initialize / notifications / tools/call from fixture files and
# records every call, its arguments, and whether the bearer arrived on stdin.
#
# The cases that matter are the misses: no session id, a bad domain or item
# id make NO request; a server that cannot be reached, or answers something
# unreadable, exits 5 and never 3 (3 is only the server's own `none`); and
# the machine token never appears in argv.
#
# Hermetic: throwaway HOME, git repo and config; no network.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOL="$(cd "${HERE}/../.." && pwd)/bin/priority-next"
PASS=0; FAIL=0
TMP="$(mktemp -d)"; trap 'rm -rf "${TMP}"' EXIT
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t

ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; [ -n "${2-}" ] && printf '%s\n' "$2" | sed 's/^/       /'; }

BEARER="mt_fake_machine_token_0123456789abcdef"
SID="5d7c7a4e-0000-4000-8000-000000000001"
ITEM="0b7b2f2e-1c3d-4e5f-8a9b-0c1d2e3f4a5b"
MCP_URL="https://athena.example.test/mcp"

SHIMBIN="${TMP}/shimbin"; mkdir -p "${SHIMBIN}"
cat > "${SHIMBIN}/curl" <<'EOF'
#!/usr/bin/env bash
# Fake athena MCP over curl: config on stdin. Records argv, calls, tool
# arguments, and whether the stdin config carried the expected bearer.
set -u
d="${SHIM_DIR}"
printf '%s\n' "$*" >> "$d/argv"
[ -f "$d/down" ] && exit 7
[[ " $* " == *" --config - "* ]] || { echo "curl shim: expected --config -" >&2; exit 99; }
cfg="$(cat)"
field() { printf '%s\n' "${cfg}" | sed -n "s/^$1 = \"\\(.*\\)\"$/\\1/p" | head -n 1; }
req="$(field data-binary)"; req="${req#@}"
hdr="$(field dump-header)"; out="$(field output)"
printf '%s\n' "${cfg}" | grep -qx "header = \"Authorization: Bearer ${SHIM_BEARER}\"" && echo ok >> "$d/bearer"
m="$(jq -r '.method' "${req}")"
case "${m}" in
  initialize)
    echo initialize >> "$d/calls"
    printf 'HTTP/1.1 200 OK\r\nmcp-session-id: sess-123\r\n\r\n' > "${hdr}"
    printf '{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2025-03-26"}}' > "${out}"
    printf 200 ;;
  notifications/initialized)
    echo initialized >> "$d/calls"; : > "${hdr}"; : > "${out}"; printf 202 ;;
  tools/call)
    tool="$(jq -r '.params.name' "${req}")"
    echo "tools/call ${tool}" >> "$d/calls"
    jq -c '.params.arguments' "${req}" > "$d/args.json"
    : > "${hdr}"
    cp "$d/answer" "${out}" 2>/dev/null || : > "${out}"
    cat "$d/code" 2>/dev/null || printf 200 ;;
  *) printf 400 ;;
esac
exit 0
EOF
chmod +x "${SHIMBIN}/curl"
# DND-1667: a guard leads PATH, behind the curl shim and in front of the real
# curl, so a shim that is missing or not executable fails the suite instead
# of reaching the network (ai/lib/forge-stub-guard.sh).
. "${HERE}/../../lib/forge-stub-guard.sh"
fsg_arm "${TMP}/curl-guard" curl
fsg_require_stubs "${SHIMBIN}" curl

CASE_N=0
# setup_case: a fresh HOME with the athena MCP registered for a git repo, a
# machine token in the inbox client config, and an empty shim record.
setup_case() {
  CASE_N=$((CASE_N+1))
  CHOME="${TMP}/home${CASE_N}"; mkdir -p "${CHOME}"
  SHIM_DIR="${TMP}/shim${CASE_N}"; mkdir -p "${SHIM_DIR}"
  PROJ="${CHOME}/dev/proj"; mkdir -p "${PROJ}"
  ( cd "${PROJ}" && git init -q . && git commit -q --allow-empty -m init )
  MAIN="$(cd "${PROJ}" && dirname "$(realpath "$(git rev-parse --git-common-dir)")")"
  jq -n --arg p "${MAIN}" --arg u "${MCP_URL}" '{projects: {($p): {mcpServers: {athena: {type: "http", url: $u}}}}}' \
    > "${CHOME}/.claude.json"
  jq -n --arg t "${BEARER}" '{token: $t}' > "${CHOME}/client.json"; chmod 600 "${CHOME}/client.json"
  SESSION="${SID}"
}

# answer_ok <json-object>  /  answer_err <text>  -- the tools/call answer (SSE).
answer_ok() {
  jq -n -c --argjson r "$1" '{jsonrpc:"2.0", id:2, result:{isError:false, content:[{type:"text", text:($r|tojson)}]}}' \
    | sed 's/^/data: /' | { cat; printf '\n'; } > "${SHIM_DIR}/answer"
}
answer_err() {
  jq -n -c --arg t "$1" '{jsonrpc:"2.0", id:2, result:{isError:true, content:[{type:"text", text:$t}]}}' \
    > "${SHIM_DIR}/answer"
}

# run <args...> -- sets OUT, ERR, RC.
run() {
  OUT="$(cd "${PROJ}" && env -u CLAUDE_CODE_SESSION_ID HOME="${CHOME}" PATH="${SHIMBIN}:${PATH}" \
    SHIM_DIR="${SHIM_DIR}" SHIM_BEARER="${BEARER}" ATHENA_INBOX_CLIENT_CONFIG="${CHOME}/client.json" \
    ${SESSION:+CLAUDE_CODE_SESSION_ID="${SESSION}"} "${TOOL}" "$@" 2>"${TMP}/err${CASE_N}")"
  RC=$?
  ERR="$(cat "${TMP}/err${CASE_N}")"
}
calls() { cat "${SHIM_DIR}/calls" 2>/dev/null || true; }
tool_args() { cat "${SHIM_DIR}/args.json" 2>/dev/null || true; }
requests() { [ -f "${SHIM_DIR}/argv" ] && wc -l < "${SHIM_DIR}/argv" || echo 0; }

LEASED='{"result":"leased","claude_session_id":"'"${SID}"'","item":{"item_id":"'"${ITEM}"'","source":"notion_personal","source_ref":"notion_personal:DND-445","url":"https://www.notion.so/page-445","title":"P3-6 leases","domain":"personal"},"leased_at":"2026-09-28T12:00:00Z","lease_window_s":3600}'
NONE='{"result":"none","considered":3,"eligible":0,"excluded":{"owner_only":1,"leased":1,"domain":1},"ingest_failures_unread":2}'

echo "-- priority-next -------------------------------------------------------------"

# 1. --help: usage on stdout, exit 0, zero requests.
setup_case; run --help
if [ "${RC}" -eq 0 ] && [[ "${OUT}" == *"priority-next next"* ]] && [ "$(requests)" -eq 0 ]; then
  ok "--help: usage on stdout, exit 0, no request"
else bad "--help: usage on stdout, exit 0, no request" "rc=${RC} requests=$(requests) out='${OUT:0:200}'"; fi

# 2. next, leased: prints the id, ref, url and title; exit 0; the arguments
#    are exactly the session id.
setup_case; answer_ok "${LEASED}"; run next
if [ "${RC}" -eq 0 ] \
   && [[ "${OUT}" == *"result=leased item_id=${ITEM} source=notion_personal ref=notion_personal:DND-445 domain=personal lease_window_s=3600"* ]] \
   && [[ "${OUT}" == *"url=https://www.notion.so/page-445"* ]] && [[ "${OUT}" == *"title=P3-6 leases"* ]] \
   && [ "$(tool_args)" = "{\"claude_session_id\":\"${SID}\"}" ] \
   && [ "$(calls)" = "$(printf 'initialize\ninitialized\ntools/call priority_next')" ]; then
  ok "next: leased -> item_id, ref, url, title on stdout; exit 0; args are only the session id"
else bad "next: leased -> item_id, ref, url, title on stdout; exit 0; args are only the session id" \
  "rc=${RC} out='${OUT}' err='${ERR}' args='$(tool_args)' calls='$(calls)'"; fi

# 3. next, none: prints the counts, exit 3.
setup_case; answer_ok "${NONE}"; run next
if [ "${RC}" -eq 3 ] && [[ "${OUT}" == "result=none considered=3 owner_only=1 leased=1 domain=1 ingest_failures_unread=2" ]]; then
  ok "next: none -> counts on stdout, exit 3"
else bad "next: none -> counts on stdout, exit 3" "rc=${RC} out='${OUT}' err='${ERR}'"; fi

# 4. next, draining: the server's Fix, exit 4.
setup_case
answer_err "session_draining: this session's desired state is drain (reason override:force_drain), so it takes no new work. Fix: run the drain protocol (athena:fleet-drain) and park; do not retry priority_next until the session is resumed."
run next
if [ "${RC}" -eq 4 ] && [[ "${ERR}" == *"result=refused code=session_draining"* ]] \
   && [[ "${ERR}" == *"Fix: run the drain protocol"* ]] && [ -z "${OUT}" ]; then
  ok "next: session_draining -> result=refused code=session_draining, the server's Fix, exit 4"
else bad "next: session_draining -> result=refused code=session_draining, the server's Fix, exit 4" "rc=${RC} out='${OUT}' err='${ERR}'"; fi

# 5. no session id: exit 2 with a Fix, zero requests.
setup_case; SESSION=""; answer_ok "${LEASED}"; run next
if [ "${RC}" -eq 2 ] && [[ "${ERR}" == *"session=missing"* ]] && [[ "${ERR}" == *"Fix:"* ]] && [ "$(requests)" -eq 0 ]; then
  ok "no CLAUDE_CODE_SESSION_ID -> exit 2, Fix:, no request"
else bad "no CLAUDE_CODE_SESSION_ID -> exit 2, Fix:, no request" "rc=${RC} err='${ERR}' requests=$(requests)"; fi

# 5b. an unsafe session id is refused the same way.
setup_case; SESSION="../x"; run next
if [ "${RC}" -eq 2 ] && [ "$(requests)" -eq 0 ]; then ok "an unsafe session id -> exit 2, no request"
else bad "an unsafe session id -> exit 2, no request" "rc=${RC} requests=$(requests)"; fi

# 6. the server is down: exit 5, never 3.
setup_case; : > "${SHIM_DIR}/down"; run next
if [ "${RC}" -eq 5 ] && [[ "${ERR}" == *"result=unreachable"* ]] && [[ "${ERR}" == *"Fix:"* ]]; then
  ok "server unreachable -> exit 5 (never 3), Fix:"
else bad "server unreachable -> exit 5 (never 3), Fix:" "rc=${RC} err='${ERR}'"; fi

# 6b. the tools/call answers HTTP 500: outcome unknown, exit 5.
setup_case; answer_ok "${LEASED}"; printf 500 > "${SHIM_DIR}/code"; run next
if [ "${RC}" -eq 5 ] && [[ "${ERR}" == *"outcome-unknown"* ]]; then ok "tools/call HTTP 500 -> exit 5, outcome-unknown"
else bad "tools/call HTTP 500 -> exit 5, outcome-unknown" "rc=${RC} err='${ERR}'"; fi

# 6c. an empty or unknown answer is unreadable, exit 5, never none.
setup_case; : > "${SHIM_DIR}/answer"; run next
if [ "${RC}" -eq 5 ]; then ok "an empty answer -> exit 5"
else bad "an empty answer -> exit 5" "rc=${RC} out='${OUT}' err='${ERR}'"; fi
setup_case; answer_ok '{"result":"ok"}'; run next
if [ "${RC}" -eq 5 ] && [[ "${ERR}" == *"unreadable-answer"* ]]; then ok "next answered ok (not a next result) -> exit 5"
else bad "next answered ok (not a next result) -> exit 5" "rc=${RC} err='${ERR}'"; fi

# 6d. a JSON-RPC protocol error: exit 5.
setup_case
printf '{"jsonrpc":"2.0","id":2,"error":{"code":-32601,"message":"Tool not found"}}' > "${SHIM_DIR}/answer"
run next
if [ "${RC}" -eq 5 ] && [[ "${ERR}" == *"mcp-error"* ]]; then ok "a JSON-RPC error -> exit 5"
else bad "a JSON-RPC error -> exit 5" "rc=${RC} err='${ERR}'"; fi

# 6e. a tool error with an unknown code is not read as a refusal: exit 5.
setup_case; answer_err "boom"; run next
if [ "${RC}" -eq 5 ]; then ok "an unrecognised tool error -> exit 5"
else bad "an unrecognised tool error -> exit 5" "rc=${RC} err='${ERR}'"; fi

# 7. the machine token is sent on stdin as a Bearer header, never in argv.
setup_case; answer_ok "${LEASED}"; run next
if ! grep -qF "${BEARER}" "${SHIM_DIR}/argv" && [ "$(grep -c ok "${SHIM_DIR}/bearer" 2>/dev/null)" -ge 2 ] \
   && ! grep -qF "${BEARER}" <<<"${OUT}${ERR}"; then
  ok "the machine token reaches curl on stdin only (never argv, never printed)"
else bad "the machine token reaches curl on stdin only (never argv, never printed)" \
  "argv='$(cat "${SHIM_DIR}/argv")' bearer='$(cat "${SHIM_DIR}/bearer" 2>/dev/null)'"; fi

# 8. no machine token: exit 5 with a Fix, no request.
setup_case; rm -f "${CHOME}/client.json"; run next
if [ "${RC}" -eq 5 ] && [[ "${ERR}" == *"no-token"* ]] && [ "$(requests)" -eq 0 ]; then
  ok "no machine token -> exit 5 no-token, no request"
else bad "no machine token -> exit 5 no-token, no request" "rc=${RC} err='${ERR}' requests=$(requests)"; fi

# 9. the MCP is not registered for this checkout: exit 5, no request.
setup_case; printf '{}' > "${CHOME}/.claude.json"; run next
if [ "${RC}" -eq 5 ] && [[ "${ERR}" == *"mcp-unregistered"* ]] && [ "$(requests)" -eq 0 ]; then
  ok "the athena MCP is not registered -> exit 5 mcp-unregistered, no request"
else bad "the athena MCP is not registered -> exit 5 mcp-unregistered, no request" "rc=${RC} err='${ERR}'"; fi

# 10. --domains is sent as a list; a bad domain is refused before any request.
setup_case; answer_ok "${NONE}"; run next --domains work,blend
if [ "${RC}" -eq 3 ] && [ "$(tool_args)" = "{\"claude_session_id\":\"${SID}\",\"domains\":[\"work\",\"blend\"]}" ]; then
  ok "--domains work,blend -> domains [work, blend]"
else bad "--domains work,blend -> domains [work, blend]" "rc=${RC} args='$(tool_args)'"; fi
setup_case; run next --domains everything
if [ "${RC}" -eq 2 ] && [ "$(requests)" -eq 0 ]; then ok "--domains everything -> exit 2, no request"
else bad "--domains everything -> exit 2, no request" "rc=${RC} requests=$(requests)"; fi
# The miss: `--domains "$UNSET"` must never read as "no filter".
setup_case; answer_ok "${LEASED}"; run next --domains ""
if [ "${RC}" -eq 2 ] && [[ "${ERR}" == *"domains=empty"* ]] && [ "$(requests)" -eq 0 ]; then
  ok "--domains '' -> exit 2 domains=empty, no request (never an unfiltered lease)"
else bad "--domains '' -> exit 2 domains=empty, no request (never an unfiltered lease)" "rc=${RC} err='${ERR}' requests=$(requests)"; fi
setup_case; run next --domains ,work
if [ "${RC}" -eq 2 ] && [ "$(requests)" -eq 0 ]; then ok "--domains ,work -> exit 2, no request"
else bad "--domains ,work -> exit 2, no request" "rc=${RC} requests=$(requests)"; fi

# 10b. flags and the item id in any order; a second item id is misuse.
setup_case; answer_ok '{"result":"ok"}'; run release --json "${ITEM}"
if [ "${RC}" -eq 0 ] && [ "$(jq -r .result <<<"${OUT}")" = "ok" ]; then ok "release --json <id> (flag first) -> ok"
else bad "release --json <id> (flag first) -> ok" "rc=${RC} out='${OUT}' err='${ERR}'"; fi
setup_case; run release "${ITEM}" "${ITEM}"
if [ "${RC}" -eq 2 ] && [ "$(requests)" -eq 0 ]; then ok "release <id> <id> -> exit 2, no request"
else bad "release <id> <id> -> exit 2, no request" "rc=${RC} requests=$(requests)"; fi
setup_case; run next "${ITEM}"
if [ "${RC}" -eq 2 ] && [ "$(requests)" -eq 0 ]; then ok "next <id> -> exit 2, no request"
else bad "next <id> -> exit 2, no request" "rc=${RC} requests=$(requests)"; fi

# 10c. a leased answer with no item id, or a none with a missing count, is
#      unreadable (exit 5), never a lease or a none.
setup_case; answer_ok "$(jq -c 'del(.item.item_id)' <<<"${LEASED}")"; run next
if [ "${RC}" -eq 5 ] && [[ "${ERR}" == *"unreadable-answer"* ]]; then ok "leased with no item_id -> exit 5"
else bad "leased with no item_id -> exit 5" "rc=${RC} out='${OUT}' err='${ERR}'"; fi
setup_case; answer_ok "$(jq -c 'del(.excluded.leased)' <<<"${NONE}")"; run next
if [ "${RC}" -eq 5 ] && [[ "${ERR}" == *"unreadable-answer"* ]]; then ok "none with a missing count -> exit 5, never 3"
else bad "none with a missing count -> exit 5, never 3" "rc=${RC} out='${OUT}' err='${ERR}'"; fi

# 11. release and complete: result=ok, exit 0, exactly session + item.
for sub in release complete; do
  setup_case; answer_ok '{"result":"ok"}'; run "${sub}" "${ITEM}"
  if [ "${RC}" -eq 0 ] && [ "${OUT}" = "result=ok item_id=${ITEM}" ] \
     && [ "$(tool_args)" = "{\"claude_session_id\":\"${SID}\",\"item_id\":\"${ITEM}\"}" ] \
     && [[ "$(calls)" == *"tools/call priority_${sub}"* ]]; then
    ok "${sub}: ok -> result=ok, exit 0, args are the session and the item"
  else bad "${sub}: ok -> result=ok, exit 0, args are the session and the item" "rc=${RC} out='${OUT}' args='$(tool_args)'"; fi
done

# 12. release refusals are exit 4 with their code.
for code in not_lease_holder not_leased not_found; do
  setup_case; answer_err "${code}: words. Fix: do the thing."; run release "${ITEM}"
  if [ "${RC}" -eq 4 ] && [[ "${ERR}" == *"code=${code}"* ]]; then ok "release: ${code} -> exit 4 code=${code}"
  else bad "release: ${code} -> exit 4 code=${code}" "rc=${RC} err='${ERR}'"; fi
done

# 13. misuse makes no request: a bad item id, an unknown subcommand, no subcommand.
for argv in "release abc" "complete" "frobnicate" ""; do
  setup_case
  # shellcheck disable=SC2086
  run ${argv}
  if [ "${RC}" -eq 2 ] && [ "$(requests)" -eq 0 ] && [[ "${ERR}" == *"Fix:"* ]]; then ok "misuse '${argv}' -> exit 2, Fix:, no request"
  else bad "misuse '${argv}' -> exit 2, Fix:, no request" "rc=${RC} err='${ERR}' requests=$(requests)"; fi
done

# 14. --json prints the server's answer object.
setup_case; answer_ok "${LEASED}"; run next --json
if [ "${RC}" -eq 0 ] && [ "$(jq -r '.item.item_id' <<<"${OUT}")" = "${ITEM}" ]; then ok "--json prints the answer object"
else bad "--json prints the answer object" "rc=${RC} out='${OUT}'"; fi

# 15. a control character in a title is stripped, never printed raw.
setup_case
answer_ok "$(jq -c '.item.title = "evil\u001b[2Jtitle\nsecond"' <<<"${LEASED}")"
run next
if [ "${RC}" -eq 0 ] && ! grep -q $'\033' <<<"${OUT}" && [ "$(grep -c '^title=' <<<"${OUT}")" -eq 1 ]; then
  ok "a title's control characters and newlines are stripped"
else bad "a title's control characters and newlines are stripped" "out='$(printf '%q' "${OUT}")'"; fi

# DND-1667: no curl call may have fallen through past its shim.
if fsg_verify; then ok "no curl call fell through past its shim (DND-1667)"
else bad "no curl call fell through past its shim (DND-1667)" "see the forge-stub-guard FAIL above"; fi

echo
printf 'priority-next self-test: %d passed, %d failed\n' "${PASS}" "${FAIL}"
[ "${FAIL}" -eq 0 ]
