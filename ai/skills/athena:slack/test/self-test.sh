#!/usr/bin/env bash
# Self-test for the athena:slack scripts and the polling hook.
#
# Slack is never contacted: curl is a PATH shim that records exactly what it
# was handed and answers with whatever the case set up. Every assertion here is
# about a decision that is invisible in production -- Slack's 200-with-ok:false
# convention, the token staying out of argv, cursor pagination, the hook's
# 5-minute window, and the hook's refusal to print message text or to advance
# the state file that read-inbox depends on. Each of those failures looks
# exactly like the healthy state from the outside.
#
# Run: bash test/self-test.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "${HERE}")"
BIN="${ROOT}/bin"
# The poll hook moved to ai/hooks/ (so setup-hooks / check-hooks-registered wire
# it like every other registry hook, at the main checkout's path). ROOT is
# .../ai/skills/athena:slack; the hook is two levels up under ai/hooks/.
AI_DIR="$(cd "${ROOT}/../.." && pwd)"
HOOK="${AI_DIR}/hooks/athena-slack-poll.sh"

TMP="$(mktemp -d)"; trap 'rm -rf "${TMP}"' EXIT
PASS=0; FAIL=0

# THE SESSION'S PROJECT SIGNALS ARE SCRUBBED (DND-1163), so the suite is
# hermetic. claim-thread and the athena:inbox bins resolve the session's
# project from CLAUDE_PROJECT_DIR, then the Claude Code process's own cwd
# (/proc/$CLAUDE_PID/cwd), before the shell cwd. This suite runs inside Claude
# sessions, so without this every fixture repo would be judged against the
# real session's project. The DND-1163 cases set them per case.
unset CLAUDE_PROJECT_DIR CLAUDE_PID

BOT_USER="UFAKEBOT01"
CODY="UFAKE00001"
ENG_CHANNEL="CFAKE00001"
FAKE_TOKEN="xoxb-fake-000-111-abcdefghijklmnop"
MCP_BEARER="fixture-machine-token-5e1d"
MCP_URL="https://athena.example.test/mcp"
BOT_ID="B0BOTFIX01"
TEAM_ID="TFAKE00001"

ok()  { printf '  ok    %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  FAIL  %s\n        %s\n' "$1" "$2"; FAIL=$((FAIL+1)); }

# `touch -d '10 minutes ago'` is GNU-only; BSD/macOS touch rejects it. NOT -u:
# `touch -t` reads its stamp as LOCAL time, so a UTC stamp lands offset by the
# zone and silently un-stales the case.
touch_ago() { # touch_ago <minutes> <file>
  local mins="$1" f="$2" stamp
  stamp="$(date -d "-${mins} min" +%Y%m%d%H%M 2>/dev/null \
        || date -v-"${mins}"M +%Y%m%d%H%M)"
  touch -t "${stamp}" "$f"
}

# --- the curl shim ----------------------------------------------------------
# Dispatches on the Slack API method in the URL, so one case can script a whole
# multi-call flow (conversations.open then chat.postMessage; a paginated list;
# a 429 followed by a 200).
SHIMBIN="${TMP}/shimbin"; mkdir -p "${SHIMBIN}"
cat > "${SHIMBIN}/curl" <<'SHIMEOF'
#!/usr/bin/env bash
# Records every invocation under $SHIM_DIR and replies from its fixtures.
set -u
d="${SHIM_DIR}"
mkdir -p "$d"/{rc,body,url,resp,http,hdr,count,calls.d} 2>/dev/null

printf '%s\n' "$*" >> "$d/argv"

# --- the athena MCP (DND-491): config on STDIN, never a file ----------------
# Answers initialize / notifications / tools/call from $d/mcp/, and records
# mcp.calls (method + tool), mcp.args.<tool>.json, and mcp.bearer ("ok" when
# the stdin config carried the expected Authorization header).
if [[ " $* " == *" --config - "* ]]; then
  mkdir -p "$d/mcp"
  cfg="$(cat)"
  field() { printf '%s\n' "${cfg}" | sed -n "s/^$1 = \"\\(.*\\)\"$/\\1/p" | head -n 1; }
  req="$(field data-binary)"; req="${req#@}"
  hdr="$(field dump-header)"; out="$(field output)"
  printf '%s\n' "${cfg}" | grep -qx "header = \"Authorization: Bearer ${SHIM_MCP_BEARER:-}\"" \
    && echo ok >> "$d/mcp.bearer"
  m="$(jq -r '.method' "${req}")"
  case "${m}" in
    initialize)
      echo initialize >> "$d/mcp.calls"
      printf 'HTTP/1.1 200 OK\r\nmcp-session-id: k3Jz9vQm+Pq/7XbL2wYtR0aC5dE=\r\n\r\n' > "${hdr}"
      printf '{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2025-03-26"}}' > "${out}"
      printf 200 ;;
    notifications/initialized)
      echo initialized >> "$d/mcp.calls"; : > "${hdr}"; : > "${out}"; printf 202 ;;
    tools/call)
      tool="$(jq -r '.params.name' "${req}")"
      echo "tools/call ${tool}" >> "$d/mcp.calls"
      jq -c '.params.arguments' "${req}" > "$d/mcp.args.${tool}.json"
      : > "${hdr}"
      cp "$d/mcp/${tool}.answer" "${out}" 2>/dev/null || : > "${out}"
      cat "$d/mcp/${tool}.code" 2>/dev/null || printf 200 ;;
    *) printf 400 ;;
  esac
  exit 0
fi

conf=""; prev=""; lasturl=""; databin=""
for a in "$@"; do
  case "${prev}" in --config|-K) conf="$a" ;; esac
  case "${prev}" in --data-binary) databin="$a" ;; esac
  case "$a" in https://*|http://*) lasturl="$a" ;; esac
  prev="$a"
done

url=""
if [[ -n "$conf" && -f "$conf" ]]; then
  url="$(sed -n 's/^url = "\(.*\)"$/\1/p' "$conf" | head -n1)"
fi
[[ -z "$url" ]] && url="$lasturl"

# api.method from .../api/<method>[?query]
method="${url##*/}"; method="${method%%\?*}"
[[ -z "$method" ]] && method="_unknown"
[[ -n "$databin" ]] && method="_upload"

n=$(( $(cat "$d/count/$method" 2>/dev/null || echo 0) + 1 ))
printf '%s' "$n" > "$d/count/$method"
printf '%s\n' "$method" >> "$d/calls"
printf '%s\n' "$url" > "$d/url/$method.$n"
printf '%s\n' "$url" >> "$d/urls"

if [[ -n "$conf" && -f "$conf" ]]; then
  cp "$conf" "$d/rc/$method.$n"
  { stat -c '%a' "$conf" 2>/dev/null || stat -f '%Lp' "$conf" 2>/dev/null; } \
    > "$d/rc/$method.$n.mode"
  bodyf="$(sed -n 's/^data = @//p' "$conf")"
  [[ -n "$bodyf" && -f "$bodyf" ]] && cp "$bodyf" "$d/body/$method.$n"
  hdrf="$(sed -n 's/^dump-header = //p' "$conf")"
  if [[ -n "$hdrf" ]]; then
    if [[ -f "$d/hdr/$method.$n" ]]; then cat "$d/hdr/$method.$n" > "$hdrf"
    elif [[ -f "$d/hdr/$method" ]]; then cat "$d/hdr/$method" > "$hdrf"
    else : > "$hdrf"; fi
  fi
  outf="$(sed -n 's/^output = //p' "$conf")"
  if [[ -n "$outf" ]]; then
    if   [[ -f "$d/resp/$method.$n" ]]; then cat "$d/resp/$method.$n" > "$outf"
    elif [[ -f "$d/resp/$method"    ]]; then cat "$d/resp/$method"    > "$outf"
    else printf '{"ok":true}' > "$outf"; fi
  fi
fi

if   [[ -f "$d/http/$method.$n" ]]; then code="$(cat "$d/http/$method.$n")"
elif [[ -f "$d/http/$method"    ]]; then code="$(cat "$d/http/$method")"
else code=200; fi

if [[ -f "$d/rc_exit/$method" ]]; then printf '%s' "$code"; exit "$(cat "$d/rc_exit/$method")"; fi
printf '%s' "$code"
exit 0
SHIMEOF
chmod +x "${SHIMBIN}/curl"

# --- per-case fixture -------------------------------------------------------
CASE_N=0
setup_case() {
  CASE_N=$((CASE_N+1))
  RUN_CWD=""
  CHOME="${TMP}/home${CASE_N}"
  CACHE="${CHOME}/.cache/athena-slack"
  mkdir -p "${CHOME}/.claude" "${CACHE}"
  SHIM_DIR="${TMP}/shim${CASE_N}"; mkdir -p "${SHIM_DIR}"
  printf '%s\n' "${FAKE_TOKEN}" > "${CHOME}/.claude/slack-bot-token"
  chmod 600 "${CHOME}/.claude/slack-bot-token"
  # A recent success by default, so soft-fail cases assert the silence they
  # were written for rather than tripping the staleness warning.
  : > "${CHOME}/.claude/athena-slack-last-success"
  # The seen-state now lives in the SHARED inbox-root file, not the private
  # cache. STATE is the new file; LEGACY is the pre-DND-186 cache the first run
  # migrates from. Both are passed to every runner so a case fully controls the
  # state location regardless of the ambient environment.
  STATE="${CHOME}/inbox-root/slack-inbox.state.json"
  LEGACY="${CACHE}/inbox-state.json"
  mkdir -p "$(dirname "${STATE}")"
}

# Pre-seed the caches the inbox scan reads, so a case can script the API calls
# it actually cares about instead of re-scripting identity every time.
seed_caches() {
  printf '{"ok":true,"user":"athena","user_id":"%s","team_id":"TFAKE00001"}' "${BOT_USER}" \
    > "${CACHE}/identity.json"
  printf '{"%s":"cody","%s":"athena","UFAKE00003":"colleague"}' "${CODY}" "${BOT_USER}" \
    > "${CACHE}/users.json"
  printf '[{"id":"%s","name":"eng-fixture","is_member":true},{"id":"CFAKE00002","name":"standup","is_member":false}]' \
    "${ENG_CHANNEL}" > "${CACHE}/channels.json"
}

fixture()     { mkdir -p "${SHIM_DIR}/resp"; printf '%s' "$2" > "${SHIM_DIR}/resp/$1"; }
fixture_seq() { mkdir -p "${SHIM_DIR}/resp"; printf '%s' "$3" > "${SHIM_DIR}/resp/$1.$2"; }
fixture_http() { mkdir -p "${SHIM_DIR}/http"; printf '%s' "$2" > "${SHIM_DIR}/http/$1"; }
fixture_http_seq() { mkdir -p "${SHIM_DIR}/http"; printf '%s' "$3" > "${SHIM_DIR}/http/$1.$2"; }
fixture_hdr_seq() { mkdir -p "${SHIM_DIR}/hdr"; printf '%s\n' "$3" > "${SHIM_DIR}/hdr/$1.$2"; }

# grep -c already PRINTS 0 when it matches nothing -- and exits 1 while doing
# it, so an `|| echo 0` fallback emits a second line and every comparison here
# then comes out false. Discard the status, keep the count.
calls_of() { local n; n="$(grep -c "^$1\$" "${SHIM_DIR}/calls" 2>/dev/null)"; printf '%s' "${n:-0}"; }
body_of()  { cat "${SHIM_DIR}/body/$1.${2:-1}" 2>/dev/null || echo '{}'; }
url_of()   { cat "${SHIM_DIR}/url/$1.${2:-1}" 2>/dev/null || echo ''; }
rc_of()    { cat "${SHIM_DIR}/rc/$1.${2:-1}" 2>/dev/null || echo ''; }
any_curl() { [[ -s "${SHIM_DIR}/calls" ]]; }

run_bin() { # run_bin <script> [args...]
  local script="$1"; shift
  set +e
  OUT="$(cd "${RUN_CWD:-${TMP}}" && env HOME="${CHOME}" PATH="${SHIMBIN}:${PATH}" SHIM_DIR="${SHIM_DIR}" \
    ATHENA_INBOX_ROOT="${CHOME}/inbox-root" ATHENA_INBOX_CLIENT_CONFIG="${CHOME}/client.json" \
    SHIM_MCP_BEARER="${MCP_BEARER}" \
    SLACK_INBOX_STATE="${STATE}" SLACK_INBOX_LEGACY_STATE="${LEGACY}" \
    SLACK_MAX_RETRIES="${SLACK_MAX_RETRIES_OVERRIDE:-3}" \
    "${BIN}/${script}" "$@" 2>"${TMP}/err${CASE_N}")"
  RC=$?
  set -e
  ERR="$(cat "${TMP}/err${CASE_N}")"
}

run_bin_stdin() { # run_bin_stdin <stdin> <script> [args...]
  local input="$1" script="$2"; shift 2
  set +e
  OUT="$(cd "${RUN_CWD:-${TMP}}" && printf '%s' "${input}" | env HOME="${CHOME}" PATH="${SHIMBIN}:${PATH}" \
  ATHENA_INBOX_ROOT="${CHOME}/inbox-root" ATHENA_INBOX_CLIENT_CONFIG="${CHOME}/client.json" \
  SHIM_MCP_BEARER="${MCP_BEARER}" \
    SHIM_DIR="${SHIM_DIR}" SLACK_INBOX_STATE="${STATE}" \
    SLACK_INBOX_LEGACY_STATE="${LEGACY}" "${BIN}/${script}" "$@" 2>"${TMP}/err${CASE_N}")"
  RC=$?
  set -e
  ERR="$(cat "${TMP}/err${CASE_N}")"
}

# CTX is the additionalContext string the SessionStart hook emits; OUT is the
# whole (compact JSON) object, or empty on the silent paths. ONEOBJ is "yes"
# when OUT is exactly one well-formed SessionStart object (F-1/F-9), "no"
# otherwise, and "" when OUT is empty.
run_hook() {
  set +e
  OUT="$(env HOME="${CHOME}" PATH="${SHIMBIN}:${PATH}" SHIM_DIR="${SHIM_DIR}" \
    SLACK_INBOX_STATE="${STATE}" SLACK_INBOX_LEGACY_STATE="${LEGACY}" \
    "$@" sh "${HOOK}" 2>"${TMP}/herr${CASE_N}")"
  RC=$?
  set -e
  HOOKLOG="$(cat "${CHOME}/.claude/athena-slack-poll.log" 2>/dev/null || true)"
  CTX=""; ONEOBJ=""
  if [[ -n "${OUT}" ]]; then
    if [[ "$(printf '%s' "${OUT}" | jq -s 'length' 2>/dev/null)" == "1" ]] \
       && [[ "$(printf '%s' "${OUT}" | jq -r '.hookSpecificOutput.hookEventName' 2>/dev/null)" == "SessionStart" ]]; then
      ONEOBJ="yes"
      CTX="$(printf '%s' "${OUT}" | jq -r '.hookSpecificOutput.additionalContext // ""' 2>/dev/null)"
    else
      ONEOBJ="no"
    fi
  fi
}

echo "athena:slack self-test"
echo
echo "-- Slack's 200-with-ok:false convention ---------------------------------"

# 1. The single most important check in the whole skill. Slack answers HTTP 200
#    for a bad channel, a missing scope and an expired token alike; a script
#    that reads the status line reports every one of them as success.
setup_case
fixture auth.test '{"ok":false,"error":"invalid_auth"}'
run_bin whoami
if [[ "${RC}" != 0 && "${ERR}" == *"invalid_auth"* && -z "${OUT}" ]]; then
  ok "ok:false on a 200 exits non-zero with the Slack error on stderr"
else bad "ok:false on a 200 exits non-zero with the Slack error on stderr" "rc=${RC} err='${ERR}' out='${OUT}'"; fi

# 2. The missing-scope hint. missing_scope's `needed` field is the difference
#    between a 20-second fix and an afternoon in the app config.
setup_case
fixture chat.postMessage '{"ok":false,"error":"missing_scope","needed":"chat:write"}'
run_bin post "${ENG_CHANNEL}" "hi"
if [[ "${RC}" != 0 && "${ERR}" == *"missing_scope"* && "${ERR}" == *"chat:write"* ]]; then
  ok "missing_scope reports the needed scope"
else bad "missing_scope reports the needed scope" "rc=${RC} err='${ERR}'"; fi

# 3. A non-2xx is an error too, and must not be read as an empty result.
setup_case
fixture_http auth.test 500
run_bin whoami
if [[ "${RC}" != 0 && "${ERR}" == *"HTTP 500"* ]]; then ok "a non-2xx status is an error"
else bad "a non-2xx status is an error" "rc=${RC} err='${ERR}'"; fi

echo
echo "-- the token ---------------------------------------------------------------"

# 4. No token at all: a named, actionable error -- and no request.
setup_case
rm -f "${CHOME}/.claude/slack-bot-token"
run_bin whoami
if [[ "${RC}" != 0 && "${ERR}" == *"slack-bot-token"* ]] && ! any_curl; then
  ok "no token: named error, non-zero, and no request is made"
else bad "no token: named error, non-zero, and no request is made" "rc=${RC} err='${ERR}'"; fi

# 4b. DND-845: there is no env-var fallback for the token. A token in the
#     caller's env is ignored, because a fallback invites a global export
#     (ai/contracts/athena-machine-secrets.md -> Never). Both the retired
#     $SLACK_BOT_TOKEN and an inherited $SLACK_TOKEN_VALUE (the lib's
#     same-shell cache) are covered.
setup_case
rm -f "${CHOME}/.claude/slack-bot-token"
SLACK_BOT_TOKEN="${FAKE_TOKEN}" run_bin whoami
if [[ "${RC}" != 0 && "${ERR}" == *"slack-bot-token"* ]] && ! any_curl; then
  ok "a \$SLACK_BOT_TOKEN in the env is not a token source (no request)"
else bad "a \$SLACK_BOT_TOKEN in the env is not a token source (no request)" "rc=${RC} err='${ERR}'"; fi
setup_case
rm -f "${CHOME}/.claude/slack-bot-token"
SLACK_TOKEN_VALUE="${FAKE_TOKEN}" run_bin whoami
if [[ "${RC}" != 0 && "${ERR}" == *"slack-bot-token"* ]] && ! any_curl; then
  ok "an inherited \$SLACK_TOKEN_VALUE is not a token source (no request)"
else bad "an inherited \$SLACK_TOKEN_VALUE is not a token source (no request)" "rc=${RC} err='${ERR}'"; fi

# 5. A user token where a bot token belongs. This is the failure that would
#    silently make Athena post AS CODY -- the one thing the skill exists to
#    prevent -- so it is refused by shape before it is ever sent.
setup_case
printf 'xoxp-not-a-bot-token\n' > "${CHOME}/.claude/slack-bot-token"
run_bin whoami
if [[ "${RC}" != 0 && "${ERR}" == *"not a bot token"* ]] && ! any_curl; then
  ok "a non-xoxb token is refused before any request"
else bad "a non-xoxb token is refused before any request" "rc=${RC} err='${ERR}'"; fi

# 6. The token never reaches argv, which is world-readable through ps.
setup_case
fixture chat.postMessage "{\"ok\":true,\"ts\":\"1.1\",\"channel\":\"${ENG_CHANNEL}\"}"
run_bin post "${ENG_CHANNEL}" "hello"
if ! grep -q "${FAKE_TOKEN}" "${SHIM_DIR}/argv" 2>/dev/null; then
  ok "the token never appears in curl's argv"
else bad "the token never appears in curl's argv" "argv: $(cat "${SHIM_DIR}/argv")"; fi

# 7. ...nor in the URL, where it would land in every proxy and access log.
if ! grep -q "${FAKE_TOKEN}" "${SHIM_DIR}/urls" 2>/dev/null; then
  ok "the token never appears in a URL"
else bad "the token never appears in a URL" "urls: $(cat "${SHIM_DIR}/urls")"; fi

# 8. It travels as an Authorization header in a 0600 config file.
if [[ "$(rc_of chat.postMessage)" == *"Authorization: Bearer ${FAKE_TOKEN}"* ]] \
   && [[ "$(cat "${SHIM_DIR}/rc/chat.postMessage.1.mode" 2>/dev/null)" == "600" ]]; then
  ok "the token travels as a Bearer header in a 0600 curl config"
else bad "the token travels as a Bearer header in a 0600 curl config" \
  "mode=$(cat "${SHIM_DIR}/rc/chat.postMessage.1.mode" 2>/dev/null)"; fi

echo
echo "-- request shapes ----------------------------------------------------------"

# 9. post: channel + text, and the JSON content type Slack requires for a JSON
#    body (without it Slack parses the body as form data and sees no channel).
setup_case
fixture chat.postMessage "{\"ok\":true,\"ts\":\"1700000000.000100\",\"channel\":\"${ENG_CHANNEL}\"}"
fixture chat.getPermalink '{"ok":true,"permalink":"https://x.slack.com/p/1"}'
run_bin post "${ENG_CHANNEL}" "hello world"
BODY="$(body_of chat.postMessage)"
if [[ "$(jq -r '.channel' <<<"${BODY}")" == "${ENG_CHANNEL}" ]] \
   && [[ "$(jq -r '.text' <<<"${BODY}")" == "hello world" ]] \
   && [[ "$(rc_of chat.postMessage)" == *"Content-Type: application/json; charset=utf-8"* ]] \
   && [[ "${OUT}" == *"ts=1700000000.000100"* ]] && [[ "${OUT}" == *"permalink=https"* ]]; then
  ok "post: channel/text body, JSON content type, prints ts and permalink"
else bad "post: channel/text body, JSON content type, prints ts and permalink" "body=${BODY} out='${OUT}' rc=${RC} err='${ERR}'"; fi

# 10. post with no text argument reads stdin -- the only way to send anything
#     multi-line without argv quoting eating the newlines.
setup_case
fixture chat.postMessage '{"ok":true,"ts":"2.2","channel":"C1"}'
run_bin_stdin $'line one\nline two' post "${ENG_CHANNEL}"
if [[ "$(jq -r '.text' <<<"$(body_of chat.postMessage)")" == $'line one\nline two' ]]; then
  ok "post: text may come from stdin, newlines intact"
else bad "post: text may come from stdin, newlines intact" "body=$(body_of chat.postMessage)"; fi

# 11. An empty message is refused locally rather than sent.
setup_case
run_bin_stdin '' post "${ENG_CHANNEL}"
if [[ "${RC}" != 0 ]] && ! any_curl; then ok "post: an empty message is refused, not sent"
else bad "post: an empty message is refused, not sent" "rc=${RC}"; fi

# 12. #name resolution goes through the channels cache, not the API.
setup_case
seed_caches
fixture chat.postMessage '{"ok":true,"ts":"3.3","channel":"C1"}'
run_bin post '#eng-fixture' "hi"
if [[ "$(jq -r '.channel' <<<"$(body_of chat.postMessage)")" == "${ENG_CHANNEL}" ]] \
   && [[ "$(calls_of conversations.list)" == "0" ]]; then
  ok "post: #name resolves from the channel cache without a listing call"
else bad "post: #name resolves from the channel cache without a listing call" \
  "body=$(body_of chat.postMessage) list_calls=$(calls_of conversations.list)"; fi

# 13. reply: thread_ts present, reply_broadcast absent unless asked for.
setup_case
fixture chat.postMessage '{"ok":true,"ts":"4.4","channel":"C1"}'
run_bin reply "${ENG_CHANNEL}" "1700000000.000100" "threaded"
BODY="$(body_of chat.postMessage)"
if [[ "$(jq -r '.thread_ts' <<<"${BODY}")" == "1700000000.000100" ]] \
   && [[ "$(jq -r '.reply_broadcast // "absent"' <<<"${BODY}")" == "absent" ]]; then
  ok "reply: thread_ts is sent and reply_broadcast is absent by default"
else bad "reply: thread_ts is sent and reply_broadcast is absent by default" "body=${BODY}"; fi

# 14. --broadcast is opt-in, and it is the flag that notifies a whole channel.
setup_case
fixture chat.postMessage '{"ok":true,"ts":"5.5","channel":"C1"}'
run_bin reply "${ENG_CHANNEL}" "1700000000.000100" "threaded" --broadcast
if [[ "$(jq -r '.reply_broadcast' <<<"$(body_of chat.postMessage)")" == "true" ]]; then
  ok "reply: --broadcast sets reply_broadcast"
else bad "reply: --broadcast sets reply_broadcast" "body=$(body_of chat.postMessage)"; fi

# 15. dm: conversations.open FIRST, and the channel it returns is the one
#     posted to. Slack has no "post to a user id"; a script that skipped the
#     open and passed U... to chat.postMessage would fail on some workspaces
#     and quietly post to the wrong place on others.
setup_case
fixture conversations.open '{"ok":true,"channel":{"id":"D0PENED"}}'
fixture chat.postMessage '{"ok":true,"ts":"6.6","channel":"D0PENED"}'
run_bin dm "${CODY}" "hi cody"
if [[ "$(head -n1 "${SHIM_DIR}/calls")" == "conversations.open" ]] \
   && [[ "$(jq -r '.users' <<<"$(body_of conversations.open)")" == "${CODY}" ]] \
   && [[ "$(jq -r '.channel' <<<"$(body_of chat.postMessage)")" == "D0PENED" ]]; then
  ok "dm: conversations.open precedes the post and supplies the channel"
else bad "dm: conversations.open precedes the post and supplies the channel" \
  "calls=$(cat "${SHIM_DIR}/calls") post=$(body_of chat.postMessage)"; fi

# 16. dm refuses a name -- a display name silently is not a user id.
setup_case
run_bin dm "cody" "hi"
if [[ "${RC}" != 0 ]] && ! any_curl; then ok "dm: a non-id recipient is refused"
else bad "dm: a non-id recipient is refused" "rc=${RC}"; fi

# 17. react strips the colon form, which Slack rejects as invalid_name.
setup_case
fixture reactions.add '{"ok":true}'
run_bin react "${ENG_CHANNEL}" "1.1" ":eyes:"
if [[ "$(jq -r '.name' <<<"$(body_of reactions.add)")" == "eyes" ]] \
   && [[ "$(jq -r '.timestamp' <<<"$(body_of reactions.add)")" == "1.1" ]]; then
  ok "react: :name: is normalised and sent as timestamp/name"
else bad "react: :name: is normalised and sent as timestamp/name" "body=$(body_of reactions.add)"; fi

echo
echo "-- pagination --------------------------------------------------------------"

# 18. Every listing method pages. Stopping at page one is the classic silent
#     truncation: the answer looks complete and is simply short.
setup_case
fixture_seq conversations.list 1 '{"ok":true,"channels":[{"id":"C1","name":"one","is_member":true}],"response_metadata":{"next_cursor":"CUR2"}}'
fixture_seq conversations.list 2 '{"ok":true,"channels":[{"id":"C2","name":"two","is_member":false}],"response_metadata":{"next_cursor":""}}'
run_bin channels
if [[ "${OUT}" == *"C1"* && "${OUT}" == *"C2"* ]] \
   && [[ "$(calls_of conversations.list)" == "2" ]] \
   && [[ "$(url_of conversations.list 2)" == *"cursor=CUR2"* ]]; then
  ok "pagination: next_cursor is followed and both pages are returned"
else bad "pagination: next_cursor is followed and both pages are returned" \
  "out='${OUT}' calls=$(calls_of conversations.list) url2=$(url_of conversations.list 2)"; fi

# 19. --member filters to joined channels (the only ones history works on).
setup_case
fixture conversations.list '{"ok":true,"channels":[{"id":"C1","name":"one","is_member":true},{"id":"C2","name":"two","is_member":false}],"response_metadata":{"next_cursor":""}}'
run_bin channels --member
if [[ "${OUT}" == *"C1"* && "${OUT}" != *"C2"* ]]; then ok "channels --member filters to joined channels"
else bad "channels --member filters to joined channels" "out='${OUT}'"; fi

# 20. DMs need types=im,mpim: conversations.list defaults to public_channel
#     only, so a default listing will never show one however far you page.
setup_case
fixture conversations.list '{"ok":true,"channels":[],"response_metadata":{"next_cursor":""}}'
run_bin channels --types im,mpim
if [[ "$(url_of conversations.list)" == *"types=im%2Cmpim"* ]]; then
  ok "channels --types is url-encoded into the request"
else bad "channels --types is url-encoded into the request" "url=$(url_of conversations.list)"; fi

echo
echo "-- rate limiting -----------------------------------------------------------"

# 21. A 429 is a wait, not a failure. Honour Retry-After and try again.
setup_case
fixture_http_seq chat.postMessage 1 429
fixture_hdr_seq chat.postMessage 1 "Retry-After: 1"
fixture_seq chat.postMessage 2 '{"ok":true,"ts":"9.9","channel":"C1"}'
run_bin post "${ENG_CHANNEL}" "retry me" --no-claim
if [[ "${RC}" == 0 ]] && [[ "$(calls_of chat.postMessage)" == "2" ]] \
   && [[ "${OUT}" == *"ts=9.9"* ]] && [[ "${ERR}" == *"rate limited"* ]]; then
  ok "429: waits out Retry-After and retries, then succeeds"
else bad "429: waits out Retry-After and retries, then succeeds" \
  "rc=${RC} calls=$(calls_of chat.postMessage) out='${OUT}' err='${ERR}'"; fi

# 22. ...but not forever. A permanent 429 fails loudly rather than hanging.
setup_case
fixture_http chat.postMessage 429
fixture_hdr_seq chat.postMessage 1 "Retry-After: 1"
SLACK_MAX_RETRIES_OVERRIDE=1 run_bin post "${ENG_CHANNEL}" "always limited"
unset SLACK_MAX_RETRIES_OVERRIDE
if [[ "${RC}" != 0 && "${ERR}" == *"rate limited after"* ]]; then
  ok "429: gives up with an error rather than retrying forever"
else bad "429: gives up with an error rather than retrying forever" "rc=${RC} err='${ERR}'"; fi

echo
echo "-- the users cache ---------------------------------------------------------"

# 23. A fresh cache that knows every id costs no users.list call.
setup_case
seed_caches
fixture conversations.history "{\"ok\":true,\"messages\":[{\"ts\":\"1.1\",\"user\":\"${CODY}\",\"text\":\"morning\"}],\"response_metadata\":{\"next_cursor\":\"\"}}"
run_bin read-channel "${ENG_CHANNEL}" --limit 5
if [[ "${OUT}" == *"cody"* ]] && [[ "$(calls_of users.list)" == "0" ]]; then
  ok "users cache: known ids resolve to names with no users.list call"
else bad "users cache: known ids resolve to names with no users.list call" \
  "out='${OUT}' users.list=$(calls_of users.list)"; fi

# 24. An id the cache has never seen refreshes it exactly once. Without the
#     "exactly once", a run mentioning a deleted or foreign id would re-list
#     the entire workspace per message.
setup_case
seed_caches
fixture users.list '{"ok":true,"members":[{"id":"U0NEW","name":"newperson","profile":{"display_name":"newperson"}}],"response_metadata":{"next_cursor":""}}'
fixture conversations.history '{"ok":true,"messages":[{"ts":"1.1","user":"U0NEW","text":"hi"},{"ts":"1.2","user":"U0NEW","text":"again"}],"response_metadata":{"next_cursor":""}}'
run_bin read-channel "${ENG_CHANNEL}" --limit 5
if [[ "${OUT}" == *"newperson"* ]] && [[ "$(calls_of users.list)" == "1" ]]; then
  ok "users cache: an unknown id triggers exactly one refresh"
else bad "users cache: an unknown id triggers exactly one refresh" \
  "out='${OUT}' users.list=$(calls_of users.list)"; fi

# 25. read-channel prints oldest-first. conversations.history returns newest
#     first, and a transcript in that order reads as a conversation backwards.
setup_case
seed_caches
fixture conversations.history "{\"ok\":true,\"messages\":[{\"ts\":\"2.0\",\"user\":\"${CODY}\",\"text\":\"second\"},{\"ts\":\"1.0\",\"user\":\"${CODY}\",\"text\":\"first\"}],\"response_metadata\":{\"next_cursor\":\"\"}}"
run_bin read-channel "${ENG_CHANNEL}" --limit 5
if [[ "$(printf '%s' "${OUT}" | head -n1)" == *"first"* ]]; then
  ok "read-channel: messages print oldest-first"
else bad "read-channel: messages print oldest-first" "out='${OUT}'"; fi

# 26. --since becomes `oldest`, which is what makes an incremental read
#     incremental instead of re-reading the channel every time.
setup_case
seed_caches
fixture conversations.history '{"ok":true,"messages":[],"response_metadata":{"next_cursor":""}}'
run_bin read-channel "${ENG_CHANNEL}" --since "1699999999.000000" --limit 5
if [[ "$(url_of conversations.history)" == *"oldest=1699999999.000000"* ]]; then
  ok "read-channel: --since is sent as oldest"
else bad "read-channel: --since is sent as oldest" "url=$(url_of conversations.history)"; fi

# 26b. --before becomes `latest` (DND-1047): the messages BEFORE a given one,
#      which judgment-label reads as that message's conversation context.
#      Without it, --since plus --limit returns the newest N in the window,
#      not the N just before the message.
setup_case
seed_caches
fixture conversations.history '{"ok":true,"messages":[],"response_metadata":{"next_cursor":""}}'
run_bin read-channel "${ENG_CHANNEL}" --since "1699999999.000000" --before "1700000500.000100" --limit 5
if [[ "${RC}" == 0 ]] && [[ "$(url_of conversations.history)" == *"latest=1700000500.000100"* ]] \
   && [[ "$(url_of conversations.history)" == *"oldest=1699999999.000000"* ]]; then
  ok "read-channel: --before is sent as latest"
else bad "read-channel: --before is sent as latest" "rc=${RC} url=$(url_of conversations.history)"; fi
setup_case
seed_caches
run_bin read-channel "${ENG_CHANNEL}" --before
if [[ "${RC}" == 2 ]] && ! any_curl; then
  ok "read-channel: --before with no value is a usage error, no request"
else bad "read-channel: --before with no value is a usage error, no request" "rc=${RC}"; fi

echo
echo "-- the hook: when it runs --------------------------------------------------"

# 27. Unconfigured is silent AND unlogged. Every machine without a bot token
#     runs this hook on every prompt; a warning there would be pure noise.
setup_case
rm -f "${CHOME}/.claude/slack-bot-token"
run_hook
if [[ -z "${OUT}" && "${RC}" == 0 ]] && ! any_curl && [[ -z "${HOOKLOG}" ]]; then
  ok "hook: no token configured is silent, unlogged, and makes no request"
else bad "hook: no token configured is silent, unlogged, and makes no request" \
  "rc=${RC} out='${OUT}' log='${HOOKLOG}'"; fi

# 27b. DND-845: a $SLACK_BOT_TOKEN in the env does not configure the hook.
setup_case
rm -f "${CHOME}/.claude/slack-bot-token"
run_hook SLACK_BOT_TOKEN="${FAKE_TOKEN}"
if [[ -z "${OUT}" && "${RC}" == 0 ]] && ! any_curl && [[ -z "${HOOKLOG}" ]]; then
  ok "hook: a \$SLACK_BOT_TOKEN in the env is not configuration (silent, no request)"
else bad "hook: a \$SLACK_BOT_TOKEN in the env is not configuration (silent, no request)" \
  "rc=${RC} out='${OUT}' log='${HOOKLOG}'"; fi

# 28. Inside the 5-minute window: no output and, crucially, no network call.
setup_case
seed_caches
touch "${CHOME}/.claude/athena-slack-last-poll"
run_hook
if [[ -z "${OUT}" ]] && ! any_curl; then
  ok "hook: a marker younger than 5 minutes suppresses the poll entirely"
else bad "hook: a marker younger than 5 minutes suppresses the poll entirely" \
  "out='${OUT}' calls=$(cat "${SHIM_DIR}/calls" 2>/dev/null)"; fi

# 29. Outside it, the hook polls.
setup_case
seed_caches
touch_ago 10 "${CHOME}/.claude/athena-slack-last-poll"
fixture conversations.list '{"ok":true,"channels":[],"response_metadata":{"next_cursor":""}}'
fixture conversations.history '{"ok":true,"messages":[],"response_metadata":{"next_cursor":""}}'
run_hook
if any_curl; then ok "hook: a marker older than 5 minutes polls"
else bad "hook: a marker older than 5 minutes polls" "no curl call"; fi

# 30. A FAILED poll still stamps the marker. Otherwise a broken Slack means a
#     fresh multi-second scan on every single prompt.
setup_case
seed_caches
fixture conversations.list '{"ok":false,"error":"invalid_auth"}'
run_hook
rm -f "${SHIM_DIR}/calls"
run_hook
if ! any_curl; then ok "hook: a failed poll still stamps the marker (no per-prompt retry storm)"
else bad "hook: a failed poll still stamps the marker" "curl called a second time"; fi

echo
echo "-- the hook: what it says --------------------------------------------------"

# The scan fixtures: one DM conversation and one member channel.
seed_inbox_fixtures() { # seed_inbox_fixtures <dm-messages-json> <channel-messages-json>
  fixture conversations.list '{"ok":true,"channels":[{"id":"D0CODY"}],"response_metadata":{"next_cursor":""}}'
  fixture_seq conversations.history 1 "{\"ok\":true,\"messages\":$1,\"response_metadata\":{\"next_cursor\":\"\"}}"
  fixture_seq conversations.history 2 "{\"ok\":true,\"messages\":$2,\"response_metadata\":{\"next_cursor\":\"\"}}"
}
seed_state() { printf '{"v":1,"channels":{"D0CODY":"1000.0","%s":"1000.0"},"seen_event_ids":[],"seen_keys":[]}' "${ENG_CHANNEL}" > "${STATE}"; }

# 31. Nothing new: absolutely nothing printed.
setup_case
seed_caches; seed_state
seed_inbox_fixtures '[]' '[]'
run_hook
if [[ -z "${OUT}" && "${RC}" == 0 ]]; then ok "hook: zero new prints absolutely nothing, rc=0"
else bad "hook: zero new prints absolutely nothing, rc=0" "rc=${RC} out='${OUT}'"; fi

# 32. Something new: ONE line, with the counts split DM vs mention.
setup_case
seed_caches; seed_state
seed_inbox_fixtures \
  "[{\"ts\":\"2000.1\",\"user\":\"${CODY}\",\"text\":\"ping one\"},{\"ts\":\"2000.2\",\"user\":\"${CODY}\",\"text\":\"ping two\"}]" \
  "[{\"ts\":\"2000.3\",\"user\":\"${CODY}\",\"text\":\"hey <@${BOT_USER}> look\"}]"
run_hook
if [[ "${ONEOBJ}" == "yes" ]] \
   && [[ "${CTX}" == "2 new Slack DM(s) and 1 mention(s) for Athena — run /athena:slack read-inbox" ]]; then
  ok "hook: N>0 emits exactly one SessionStart object with the right DM and mention counts"
else bad "hook: N>0 emits exactly one SessionStart object with the right DM and mention counts" "oneobj='${ONEOBJ}' ctx='${CTX}' out='${OUT}'"; fi

# 33. It never prints a body, a sender or a channel name -- not on stdout and
#     not into the log. A hook's output is injected before the user has spoken.
if [[ "${OUT}" != *"ping one"* && "${OUT}" != *"cody"* && "${OUT}" != *"D0CODY"* ]] \
   && [[ "${HOOKLOG}" != *"ping"* ]]; then
  ok "hook: no message body, sender or channel reaches stdout or the log"
else bad "hook: no message body, sender or channel reaches stdout or the log" "out='${OUT}' log='${HOOKLOG}'"; fi

# 34. A channel message WITHOUT the mention token is not a mention. Otherwise
#     the hook would announce every message in every channel the bot is in.
setup_case
seed_caches; seed_state
seed_inbox_fixtures '[]' "[{\"ts\":\"2000.9\",\"user\":\"${CODY}\",\"text\":\"just chatting\"}]"
run_hook
if [[ -z "${OUT}" ]]; then ok "hook: a channel message without <@bot> is not a mention"
else bad "hook: a channel message without <@bot> is not a mention" "out='${OUT}'"; fi

# 35. Athena's own messages are not news. Without this the bot's own reply
#     would immediately re-ring the doorbell it just answered.
setup_case
seed_caches; seed_state
seed_inbox_fixtures \
  "[{\"ts\":\"2000.1\",\"user\":\"${BOT_USER}\",\"text\":\"my own DM reply\"}]" \
  "[{\"ts\":\"2000.2\",\"user\":\"${BOT_USER}\",\"text\":\"I said <@${BOT_USER}>\"}]"
run_hook
if [[ -z "${OUT}" ]]; then ok "hook: the bot's own messages are ignored"
else bad "hook: the bot's own messages are ignored" "out='${OUT}'"; fi

# 36. The hook must NOT advance the state file. If it did, read-inbox -- the
#     only place bodies are ever shown -- would find nothing to show.
setup_case
seed_caches; seed_state
seed_inbox_fixtures "[{\"ts\":\"2000.1\",\"user\":\"${CODY}\",\"text\":\"unread\"}]" '[]'
BEFORE="$(cat "${STATE}")"
run_hook
if [[ "$(cat "${STATE}")" == "${BEFORE}" ]]; then
  ok "hook: the inbox state file is left untouched (read-inbox owns it)"
else bad "hook: the inbox state file is left untouched" "after=$(cat "${STATE}")"; fi

echo
echo "-- the hook: staleness -----------------------------------------------------"

# 37. Six hours with no successful poll, token present: say so, once.
setup_case
seed_caches
touch_ago 400 "${CHOME}/.claude/athena-slack-last-success"
fixture conversations.list '{"ok":false,"error":"invalid_auth"}'
run_hook
# F-9: the stale warning travels as the SAME well-formed SessionStart object,
# never a bare text line into a JSON channel.
if [[ "${ONEOBJ}" == "yes" ]] && [[ "${CTX}" == *"has not succeeded in 6h"* ]]; then
  ok "hook: warns after 6h with no successful poll, as one SessionStart object"
else bad "hook: warns after 6h with no successful poll, as one SessionStart object" "oneobj='${ONEOBJ}' ctx='${CTX}' out='${OUT}' log='${HOOKLOG}'"; fi

# 38. ...and does not repeat it on the next session start.
rm -f "${CHOME}/.claude/athena-slack-last-poll"
run_hook
if [[ -z "${OUT}" ]]; then ok "hook: the staleness warning is itself rate-limited"
else bad "hook: the staleness warning is itself rate-limited" "out='${OUT}'"; fi

# 39. A recent success means the silence is healthy: no warning.
setup_case
seed_caches
: > "${CHOME}/.claude/athena-slack-last-success"
fixture conversations.list '{"ok":false,"error":"invalid_auth"}'
run_hook
if [[ -z "${OUT}" ]] && [[ "${HOOKLOG}" == *"invalid_auth"* ]]; then
  ok "hook: a recent success keeps a one-off failure silent (but logged)"
else bad "hook: a recent success keeps a one-off failure silent (but logged)" "out='${OUT}' log='${HOOKLOG}'"; fi

# 40. Unconfigured never warns, however long it has been. "No token" is an off
#     switch, not a fault.
setup_case
rm -f "${CHOME}/.claude/slack-bot-token"
touch_ago 4000 "${CHOME}/.claude/athena-slack-last-success"
run_hook
if [[ -z "${OUT}" ]]; then ok "hook: an unconfigured machine is never warned at"
else bad "hook: an unconfigured machine is never warned at" "out='${OUT}'"; fi

# 41. A successful poll clears the warn marker, so the NEXT outage gets its own
#     warning instead of being suppressed by the last one.
setup_case
seed_caches; seed_state
touch_ago 400 "${CHOME}/.claude/athena-slack-last-warn"
seed_inbox_fixtures '[]' '[]'
run_hook
if [[ ! -f "${CHOME}/.claude/athena-slack-last-warn" ]] \
   && [[ -f "${CHOME}/.claude/athena-slack-last-success" ]]; then
  ok "hook: a successful poll stamps success and clears the warn marker"
else bad "hook: a successful poll stamps success and clears the warn marker" \
  "warn=$([[ -f "${CHOME}/.claude/athena-slack-last-warn" ]] && echo present || echo gone)"; fi

echo
echo "-- read-inbox --------------------------------------------------------------"

# 42. read-inbox is where bodies live, and it advances the state file past what
#     it just showed.
setup_case
seed_caches; seed_state
seed_inbox_fixtures "[{\"ts\":\"2000.5\",\"user\":\"${CODY}\",\"text\":\"please look at MR 42\"}]" '[]'
run_bin read-inbox
if [[ "${OUT}" == *"please look at MR 42"* ]] \
   && [[ "${OUT}" == *"cody"* ]] \
   && [[ "$(jq -r '.channels.D0CODY' "${STATE}")" == "2000.5" ]]; then
  ok "read-inbox: shows the body, resolves the sender, advances the state file"
else bad "read-inbox: shows the body, resolves the sender, advances the state file" \
  "out='${OUT}' state=$(cat "${STATE}")"; fi

# 43. It labels the bodies as untrusted. This is the boundary between "Slack
#     said something" and "someone asked Athena to do something".
# Both fences, and the body BETWEEN them. Asserting on the phrase alone was a
#     measured zero: deleting the opening fence left the closing one, which
#     contains the same words, and the case stayed green (sabotage S28).
if [[ "${OUT}" == *"untrusted content below"* ]] \
   && [[ "${OUT}" == *"end untrusted content"* ]] \
   && [[ "${OUT}" == *"untrusted content below"*"please look at MR 42"*"end untrusted content"* ]]; then
  ok "read-inbox: bodies are fenced between an opening and a closing untrusted marker"
else bad "read-inbox: bodies are fenced between an opening and a closing untrusted marker" "out='${OUT}'"; fi

# 44. --peek shows without consuming.
setup_case
seed_caches; seed_state
seed_inbox_fixtures "[{\"ts\":\"2000.5\",\"user\":\"${CODY}\",\"text\":\"peek at me\"}]" '[]'
BEFORE="$(cat "${STATE}")"
run_bin read-inbox --peek
if [[ "${OUT}" == *"peek at me"* ]] && [[ "$(cat "${STATE}")" == "${BEFORE}" ]]; then
  ok "read-inbox: --peek shows messages without advancing the state file"
else bad "read-inbox: --peek shows messages without advancing the state file" \
  "out='${OUT}' state=$(cat "${STATE}")"; fi

# 45. A conversation seen for the first time records where it is and reports
#     nothing. Otherwise the first run after install announces the entire
#     history of every DM at once.
setup_case
seed_caches
rm -f "${STATE}" "${LEGACY}"
seed_inbox_fixtures "[{\"ts\":\"2000.5\",\"user\":\"${CODY}\",\"text\":\"ancient history\"}]" '[]'
run_bin read-inbox
if [[ "${OUT}" != *"ancient history"* ]] \
   && [[ "$(jq -r '.channels.D0CODY' "${STATE}")" == "2000.5" ]]; then
  ok "read-inbox: first sight of a conversation records its ts and reports nothing"
else bad "read-inbox: first sight of a conversation records its ts and reports nothing" \
  "out='${OUT}' state=$(cat "${STATE}" 2>/dev/null)"; fi

# 46. The incremental read is what `oldest` buys: the second scan asks only for
#     what came after the recorded ts.
setup_case
seed_caches; seed_state
seed_inbox_fixtures '[]' '[]'
run_bin read-inbox
if [[ "$(url_of conversations.history 1)" == *"oldest=1000.0"* ]]; then
  ok "read-inbox: a known conversation is read incrementally with oldest"
else bad "read-inbox: a known conversation is read incrementally with oldest" \
  "url=$(url_of conversations.history 1)"; fi

# 47. The per-tick request budget is bounded. An agent that joins fifty
#     channels must not turn one prompt into fifty history calls.
setup_case
seed_caches
BIGLIST='{"ok":true,"channels":['
for i in $(seq 1 12); do BIGLIST+="{\"id\":\"D${i}\"},"; done
BIGLIST="${BIGLIST%,}"'],"response_metadata":{"next_cursor":""}}'
fixture conversations.list "${BIGLIST}"
fixture conversations.history '{"ok":true,"messages":[],"response_metadata":{"next_cursor":""}}'
set +e
OUT="$(env HOME="${CHOME}" PATH="${SHIMBIN}:${PATH}" SHIM_DIR="${SHIM_DIR}" \
  SLACK_INBOX_STATE="${STATE}" SLACK_INBOX_LEGACY_STATE="${LEGACY}" \
  SLACK_INBOX_MAX_CHANNELS=3 "${BIN}/read-inbox" 2>&1)"
set -e
if [[ "$(calls_of conversations.history)" == "3" ]] && [[ "${OUT}" == *"capped"* ]]; then
  ok "inbox scan: the channel budget caps the requests per tick and says so"
else bad "inbox scan: the channel budget caps the requests per tick and says so" \
  "history_calls=$(calls_of conversations.history) out='${OUT}'"; fi

echo
echo "-- conversations that cannot be read ---------------------------------------"

# 48. Slackbot's IM is listed by conversations.list and then 404s on
#     conversations.history. Measured against the real workspace: it aborted
#     the entire scan, so the inbox reported nothing while eleven readable DMs
#     sat unexamined. It can never carry a message for Athena, so it is dropped
#     by name before any history call is spent on it.
setup_case
seed_caches; seed_state
fixture conversations.list '{"ok":true,"channels":[{"id":"D0SLACKBOT","user":"USLACKBOT"},{"id":"D0CODY","user":"UFAKE00001"}],"response_metadata":{"next_cursor":""}}'
fixture conversations.history '{"ok":true,"messages":[],"response_metadata":{"next_cursor":""}}'
run_bin read-inbox
FOUND_SLACKBOT=no
for u in "${SHIM_DIR}"/url/conversations.history.*; do
  [[ -f "$u" ]] && [[ "$(cat "$u")" == *"D0SLACKBOT"* ]] && FOUND_SLACKBOT=yes
done
if [[ "${FOUND_SLACKBOT}" == "no" ]] && [[ "${RC}" == 0 ]]; then
  ok "inbox scan: the Slackbot IM is excluded before a history call is spent on it"
else bad "inbox scan: the Slackbot IM is excluded before a history call is spent on it" \
  "rc=${RC} found=${FOUND_SLACKBOT} out='${OUT}'"; fi

# 49. One unreadable conversation is skipped and SAID, not fatal: the others
#     are still scanned. A single bad channel must not blind the inbox.
setup_case
seed_caches; seed_state
fixture conversations.list '{"ok":true,"channels":[{"id":"D0BAD","user":"U1"},{"id":"D0CODY","user":"UFAKE00001"}],"response_metadata":{"next_cursor":""}}'
fixture_seq conversations.history 1 '{"ok":false,"error":"channel_not_found"}'
fixture_seq conversations.history 2 "{\"ok\":true,\"messages\":[{\"ts\":\"2000.7\",\"user\":\"${CODY}\",\"text\":\"still readable\"}],\"response_metadata\":{\"next_cursor\":\"\"}}"
fixture_seq conversations.history 3 '{"ok":true,"messages":[],"response_metadata":{"next_cursor":""}}'
run_bin read-inbox
if [[ "${RC}" == 0 ]] && [[ "${OUT}" == *"still readable"* ]] \
   && [[ "${OUT}" == *"1 conversation(s) could not be read"* ]]; then
  ok "inbox scan: an unreadable conversation is skipped, counted, and the rest still scanned"
else bad "inbox scan: an unreadable conversation is skipped, counted, and the rest still scanned" \
  "rc=${RC} out='${OUT}' err='${ERR}'"; fi

# 50. ...but if EVERY conversation fails, that is an error. Skipping silently
#     in that case would make a broken read indistinguishable from a quiet
#     inbox -- the exact failure the whole design exists to prevent.
setup_case
seed_caches; seed_state
fixture conversations.list '{"ok":true,"channels":[{"id":"D0BAD1","user":"U1"},{"id":"D0BAD2","user":"U2"}],"response_metadata":{"next_cursor":""}}'
fixture conversations.history '{"ok":false,"error":"channel_not_found"}'
run_bin read-inbox
if [[ "${RC}" != 0 ]] && [[ "${ERR}" == *"every dm conversation failed"* ]]; then
  ok "inbox scan: a scan in which every conversation failed is an error, not an empty inbox"
else bad "inbox scan: a scan in which every conversation failed is an error, not an empty inbox" \
  "rc=${RC} err='${ERR}' out='${OUT}'"; fi

# 51. An EMPTY conversation seen for the first time still gets a state entry.
#     Without one it is "first sight" on every scan forever, and the first
#     message anyone ever sends into it is swallowed by the backlog rule.
setup_case
seed_caches
rm -f "${STATE}" "${LEGACY}"
fixture conversations.list '{"ok":true,"channels":[{"id":"D0EMPTY","user":"U1"}],"response_metadata":{"next_cursor":""}}'
fixture conversations.history '{"ok":true,"messages":[],"response_metadata":{"next_cursor":""}}'
run_bin read-inbox
if [[ "$(jq -r '.channels.D0EMPTY' "${STATE}" 2>/dev/null)" == "0" ]]; then
  ok "inbox scan: an empty conversation records a zero baseline, not nothing"
else bad "inbox scan: an empty conversation records a zero baseline, not nothing" \
  "state=$(cat "${STATE}" 2>/dev/null)"; fi

# 52. ...and the NEXT message in it is then reported.
setup_case
seed_caches
printf '{"v":1,"channels":{"D0EMPTY":"0"},"seen_event_ids":[],"seen_keys":[]}' > "${STATE}"
fixture conversations.list '{"ok":true,"channels":[{"id":"D0EMPTY","user":"U1"}],"response_metadata":{"next_cursor":""}}'
fixture conversations.history "{\"ok\":true,\"messages\":[{\"ts\":\"3000.1\",\"user\":\"${CODY}\",\"text\":\"first ever message\"}],\"response_metadata\":{\"next_cursor\":\"\"}}"
run_bin read-inbox
if [[ "${OUT}" == *"first ever message"* ]]; then
  ok "inbox scan: the first message into a previously-empty conversation is reported"
else bad "inbox scan: the first message into a previously-empty conversation is reported" "out='${OUT}'"; fi

echo
echo "-- upload (the three-step external flow) ------------------------------------"

# 53. files.upload was sunset on 2025-11-12. The replacement is three calls and
#     the third is the only one that attaches the file to a channel -- skip it
#     and the upload exists but is visible to nobody, with no error anywhere.
setup_case
seed_caches
printf 'hello file contents' > "${TMP}/up${CASE_N}.txt"
fixture files.getUploadURLExternal '{"ok":true,"upload_url":"https://files.slack.com/upload/v1/ABC","file_id":"F0FAKE"}'
fixture files.completeUploadExternal '{"ok":true,"files":[{"id":"F0FAKE","permalink":"https://x.slack.com/files/F0FAKE"}]}'
run_bin upload "${ENG_CHANNEL}" "${TMP}/up${CASE_N}.txt" --title "notes" --thread_ts "1700.1" --comment "see this"
UURL="$(url_of files.getUploadURLExternal)"
CBODY="$(body_of files.completeUploadExternal)"
if [[ "${RC}" == 0 ]] \
   && [[ "${UURL}" == *"length=19"* ]] \
   && [[ "${UURL}" == *"filename=up${CASE_N}.txt"* ]] \
   && [[ "$(calls_of _upload)" == "1" ]] \
   && [[ "$(jq -r '.files[0].id' <<<"${CBODY}")" == "F0FAKE" ]] \
   && [[ "$(jq -r '.channel_id' <<<"${CBODY}")" == "${ENG_CHANNEL}" ]] \
   && [[ "$(jq -r '.thread_ts' <<<"${CBODY}")" == "1700.1" ]] \
   && [[ "$(jq -r '.initial_comment' <<<"${CBODY}")" == "see this" ]]; then
  ok "upload: exact byte length, bytes PUT to upload_url, then completed onto the channel"
else bad "upload: exact byte length, bytes PUT to upload_url, then completed onto the channel" \
  "rc=${RC} url='${UURL}' upload_calls=$(calls_of _upload) body=${CBODY} err='${ERR}'"; fi

# 54. The pre-signed upload_url must NOT carry the bot token. It is a
#     third-party-visible URL; sending workspace credentials to it would be a
#     credential leak that nothing else in this suite would notice.
if ! grep -q "${FAKE_TOKEN}" "${SHIM_DIR}/argv" 2>/dev/null; then
  ok "upload: the bot token is not sent to the pre-signed upload URL"
else bad "upload: the bot token is not sent to the pre-signed upload URL" "argv leak"; fi

# 55. An empty file is refused: getUploadURLExternal rejects length=0 anyway,
#     but locally and by name beats a Slack error two calls later.
setup_case
: > "${TMP}/empty${CASE_N}"
run_bin upload "${ENG_CHANNEL}" "${TMP}/empty${CASE_N}"
if [[ "${RC}" != 0 ]] && ! any_curl; then ok "upload: an empty file is refused before any request"
else bad "upload: an empty file is refused before any request" "rc=${RC}"; fi

echo
echo "-- DND-186: one dedupe set across file and API -----------------------------"

# 56. THE CORE CROSS-SOURCE DROP. A message whose channel:ts is already in the
#     shared seen_keys (put there by the file channel, or a prior API read) must
#     NOT be reported again by the API scan. Without this the backstop
#     double-reports everything the file path already delivered.
setup_case
seed_caches
printf '{"v":1,"channels":{"D0CODY":"1000.0"},"seen_event_ids":[],"seen_keys":["D0CODY:2000.5"]}' > "${STATE}"
fixture conversations.list '{"ok":true,"channels":[{"id":"D0CODY","user":"UFAKE00001"}],"response_metadata":{"next_cursor":""}}'
fixture conversations.history "{\"ok\":true,\"messages\":[{\"ts\":\"2000.5\",\"user\":\"${CODY}\",\"text\":\"already delivered by the file channel\"}],\"response_metadata\":{\"next_cursor\":\"\"}}"
run_bin read-inbox
if [[ "${OUT}" != *"already delivered by the file channel"* ]] \
   && [[ "${OUT}" == *"0 new DM(s)"* ]]; then
  ok "dedupe: a message whose channel:ts is in seen_keys is dropped by the API scan"
else bad "dedupe: a message whose channel:ts is in seen_keys is dropped by the API scan" "out='${OUT}'"; fi

# 57. ...and the SAME drop applies to the hook's count, so the doorbell is not
#     rung for something the file channel already delivered.
setup_case
seed_caches
printf '{"v":1,"channels":{"D0CODY":"1000.0"},"seen_event_ids":[],"seen_keys":["D0CODY:2000.5"]}' > "${STATE}"
fixture conversations.list '{"ok":true,"channels":[{"id":"D0CODY"}],"response_metadata":{"next_cursor":""}}'
fixture_seq conversations.history 1 "{\"ok\":true,\"messages\":[{\"ts\":\"2000.5\",\"user\":\"${CODY}\",\"text\":\"seen\"}],\"response_metadata\":{\"next_cursor\":\"\"}}"
run_hook
if [[ -z "${OUT}" ]]; then ok "dedupe: the hook does not count a message already in seen_keys"
else bad "dedupe: the hook does not count a message already in seen_keys" "out='${OUT}'"; fi

# 58. THE CROSS-SOURCE ADD. read-inbox records each reported message's
#     channel:ts in seen_keys, so the FILE reader will not re-report what the
#     API just delivered. (read-inbox is the door; it owns the state advance.)
setup_case
seed_caches; seed_state
seed_inbox_fixtures "[{\"ts\":\"2000.5\",\"user\":\"${CODY}\",\"text\":\"api delivered this one\"}]" '[]'
run_bin read-inbox
if [[ "${OUT}" == *"api delivered this one"* ]] \
   && [[ "$(jq -r '.seen_keys | index("D0CODY:2000.5")' "${STATE}")" != "null" ]]; then
  ok "dedupe: read-inbox adds a reported message's channel:ts to the shared seen_keys"
else bad "dedupe: read-inbox adds a reported message's channel:ts to the shared seen_keys" \
  "seen_keys=$(jq -c '.seen_keys' "${STATE}") out='${OUT}'"; fi

# 59. THE HOOK NEVER ADDS to seen_keys -- doorbell, not door. If it did, the
#     body would be marked seen before read-inbox ever showed it.
setup_case
seed_caches; seed_state
seed_inbox_fixtures "[{\"ts\":\"2000.5\",\"user\":\"${CODY}\",\"text\":\"unread\"}]" '[]'
run_hook
if [[ "$(jq -r '.seen_keys | length' "${STATE}")" == "0" ]]; then
  ok "dedupe: the hook does not add to seen_keys (read-inbox owns the state advance)"
else bad "dedupe: the hook does not add to seen_keys" "seen_keys=$(jq -c '.seen_keys' "${STATE}")"; fi

# 60. THE SHARED FILE IS NOT CLOBBERED. The file-channel reader owns offset and
#     seen_event_ids; an API-side advance must preserve them (and any other key,
#     e.g. rotated_at) verbatim, or it rewinds the file channel's consumption.
setup_case
seed_caches
printf '{"v":1,"offset":819,"channels":{"D0CODY":"1000.0"},"seen_event_ids":["Ev123"],"seen_keys":[],"rotated_at":"2026-09-18T19:30:00Z"}' > "${STATE}"
seed_inbox_fixtures "[{\"ts\":\"2000.5\",\"user\":\"${CODY}\",\"text\":\"advance me\"}]" '[]'
run_bin read-inbox
if [[ "$(jq -r '.offset' "${STATE}")" == "819" ]] \
   && [[ "$(jq -r '.seen_event_ids | index("Ev123")' "${STATE}")" != "null" ]] \
   && [[ "$(jq -r '.rotated_at' "${STATE}")" == "2026-09-18T19:30:00Z" ]] \
   && [[ "$(jq -r '.channels.D0CODY' "${STATE}")" == "2000.5" ]]; then
  ok "dedupe: an API advance preserves the file reader's offset/seen_event_ids/rotated_at"
else bad "dedupe: an API advance preserves the file reader's offset/seen_event_ids/rotated_at" \
  "state=$(cat "${STATE}")"; fi

# 61. last_api_poll_at is stamped on a read, for the file reader's staleness
#     reporting -- it is the producer-side liveness field the contract reserves.
setup_case
seed_caches; seed_state
seed_inbox_fixtures '[]' '[]'
run_bin read-inbox
if [[ "$(jq -r '.last_api_poll_at // ""' "${STATE}")" == *"T"*"Z" ]]; then
  ok "dedupe: read-inbox stamps last_api_poll_at"
else bad "dedupe: read-inbox stamps last_api_poll_at" "state=$(cat "${STATE}")"; fi

# 62. MIGRATION. A pre-DND-186 ~/.cache cache is migrated on first run: its
#     per-conversation watermark is carried across, so a message already past
#     that watermark is treated as known (not first-sight) and IS reported --
#     which is exactly what distinguishes a migrated start from a clean one
#     (case 45, where an unknown conversation reports nothing).
setup_case
seed_caches
rm -f "${STATE}"
printf '{"version":1,"channels":{"D0CODY":"1000.0"}}' > "${LEGACY}"
fixture conversations.list '{"ok":true,"channels":[{"id":"D0CODY","user":"UFAKE00001"}],"response_metadata":{"next_cursor":""}}'
fixture conversations.history "{\"ok\":true,\"messages\":[{\"ts\":\"2000.5\",\"user\":\"${CODY}\",\"text\":\"post-watermark message\"}],\"response_metadata\":{\"next_cursor\":\"\"}}"
run_bin read-inbox
if [[ "${OUT}" == *"post-watermark message"* ]] \
   && [[ "$(jq -r '.channels.D0CODY' "${STATE}")" == "2000.5" ]]; then
  ok "migration: the legacy cache's watermark is carried into the shared state file"
else bad "migration: the legacy cache's watermark is carried into the shared state file" \
  "out='${OUT}' state=$(cat "${STATE}" 2>/dev/null)"; fi

# 63. A MISSING state file (and no legacy) is a clean start, NOT an error: the
#     hook completes and stays silent, exit 0. "missing vs wrong."
setup_case
seed_caches
rm -f "${STATE}" "${LEGACY}"
fixture conversations.list '{"ok":true,"channels":[{"id":"D0CODY"}],"response_metadata":{"next_cursor":""}}'
fixture conversations.history "{\"ok\":true,\"messages\":[{\"ts\":\"2000.5\",\"user\":\"${CODY}\",\"text\":\"hi\"}],\"response_metadata\":{\"next_cursor\":\"\"}}"
run_hook
if [[ -z "${OUT}" && "${RC}" == 0 ]] && [[ "${HOOKLOG}" != *rror* ]]; then
  ok "missing state file is a clean start (first sight), not an error"
else bad "missing state file is a clean start (first sight), not an error" "rc=${RC} out='${OUT}' log='${HOOKLOG}'"; fi

echo
echo "-- DND-186: the SessionStart marker family and contract --------------------"

# 64. F-7: THE ATTEMPT MARKER IS STAMPED BEFORE THE NETWORK CALL, and a FAILING
#     poll must NEVER stamp the success marker (the one the whole signal rests
#     on). Remove both markers, run a failing poll: attempt present, success
#     still absent.
setup_case
seed_caches
rm -f "${CHOME}/.claude/athena-slack-last-success" "${CHOME}/.claude/athena-slack-last-poll"
fixture conversations.list '{"ok":false,"error":"invalid_auth"}'
run_hook
if [[ -f "${CHOME}/.claude/athena-slack-last-poll" ]] \
   && [[ ! -f "${CHOME}/.claude/athena-slack-last-success" ]]; then
  ok "markers: a failing poll stamps the attempt marker but never the success marker"
else bad "markers: a failing poll stamps the attempt marker but never the success marker" \
  "attempt=$([[ -f "${CHOME}/.claude/athena-slack-last-poll" ]] && echo yes || echo no) success=$([[ -f "${CHOME}/.claude/athena-slack-last-success" ]] && echo yes || echo no)"; fi

# 65. F-5: a MISSING success marker counts as stale, so a never-working setup
#     warns on its very first attempt (no prior success to call the failure
#     momentary against).
setup_case
seed_caches
rm -f "${CHOME}/.claude/athena-slack-last-success" "${CHOME}/.claude/athena-slack-last-warn"
fixture conversations.list '{"ok":false,"error":"invalid_auth"}'
run_hook
if [[ "${ONEOBJ}" == "yes" ]] && [[ "${CTX}" == *"has not succeeded in 6h"* ]]; then
  ok "markers: a missing success marker counts as stale (warns on the first attempt)"
else bad "markers: a missing success marker counts as stale (warns on the first attempt)" \
  "oneobj='${ONEOBJ}' ctx='${CTX}' out='${OUT}'"; fi

# 66. F-3 / the contract's silent path: a successful poll with nothing new emits
#     NO STDOUT AT ALL and exits 0 -- never an empty or "nothing new" object.
setup_case
seed_caches; seed_state
seed_inbox_fixtures '[]' '[]'
run_hook
if [[ -z "${OUT}" && "${RC}" == 0 ]]; then
  ok "contract: a successful poll with nothing new produces no stdout, exit 0"
else bad "contract: a successful poll with nothing new produces no stdout, exit 0" "rc=${RC} out='${OUT}'"; fi

# 67. THE STATE PATH IS DERIVED, NOT HARDCODED. With no SLACK_INBOX_STATE set,
#     the state file is the channel's .jsonl with the suffix swapped to
#     .state.json -- the SAME rule athena:inbox's names_state_name uses, which is
#     the only thing that makes the "one shared file" real for a per-project
#     channel. Point SLACK_INBOX_JSONL at foo-slack.jsonl and the state must land
#     at foo-slack.state.json beside it, not at a fixed slack-inbox.state.json.
setup_case
seed_caches
JDIR="${CHOME}/jroot"; mkdir -p "${JDIR}"
seed_inbox_fixtures "[{\"ts\":\"2000.5\",\"user\":\"${CODY}\",\"text\":\"derive me\"}]" '[]'
# Deliberately NO SLACK_INBOX_STATE: the derivation from SLACK_INBOX_JSONL is
# exactly what is under test.
set +e
env HOME="${CHOME}" PATH="${SHIMBIN}:${PATH}" SHIM_DIR="${SHIM_DIR}" \
  SLACK_INBOX_JSONL="${JDIR}/foo-slack.jsonl" \
  "${BIN}/read-inbox" >/dev/null 2>&1
set -e
if [[ -f "${JDIR}/foo-slack.state.json" ]] \
   && [[ ! -f "${JDIR}/foo-slack.jsonl.state.json" ]]; then
  ok "state path: derived by suffix swap from SLACK_INBOX_JSONL (matches names_state_name)"
else bad "state path: derived by suffix swap from SLACK_INBOX_JSONL (matches names_state_name)" \
  "ls: $(ls "${JDIR}" 2>/dev/null | tr '\n' ' ')"; fi

# 68. MIGRATION WHEN THE FILE READER GOT THERE FIRST. The shared state file may
#     already exist -- written by the athena:inbox reader with v/offset/seen_*
#     and NO `channels`. Migration keyed only on "shared file absent" would skip
#     here and treat every conversation as first sight, silently swallowing the
#     messages between the last cache read and the upgrade. The legacy watermark
#     must still be folded in, so a post-watermark message IS reported.
setup_case
seed_caches
# The shared file as the file reader would leave it: no channels key.
printf '{"v":1,"offset":42,"seen_event_ids":["Ev9"],"seen_keys":[]}' > "${STATE}"
printf '{"version":1,"channels":{"D0CODY":"1000.0"}}' > "${LEGACY}"
fixture conversations.list '{"ok":true,"channels":[{"id":"D0CODY","user":"UFAKE00001"}],"response_metadata":{"next_cursor":""}}'
fixture conversations.history "{\"ok\":true,\"messages\":[{\"ts\":\"2000.5\",\"user\":\"${CODY}\",\"text\":\"post-watermark, reader got there first\"}],\"response_metadata\":{\"next_cursor\":\"\"}}"
run_bin read-inbox
if [[ "${OUT}" == *"post-watermark, reader got there first"* ]] \
   && [[ "$(jq -r '.offset' "${STATE}")" == "42" ]]; then
  ok "migration: legacy watermark is folded in even when the reader already wrote the shared file"
else bad "migration: legacy watermark is folded in even when the reader already wrote the shared file" \
  "out='${OUT}' state=$(cat "${STATE}")"; fi

echo
echo "-- read-inbox --json: empty is [], a failure is never empty-and-0 ----------"

# 69. THE REPORTED DEFECT. --json with nothing new must print exactly `[]`
#     (valid JSON), exit 0 -- not zero bytes. Zero bytes make "no messages"
#     indistinguishable from "the read produced nothing", which is what made a
#     consumer fall back to conversations.history to be sure.
setup_case
seed_caches; seed_state
seed_inbox_fixtures '[]' '[]'
run_bin read-inbox --json --peek
if [[ "${OUT}" == "[]" ]] && [[ "${RC}" == 0 ]] && [[ -z "${ERR}" ]]; then
  ok "read-inbox --json: an empty read prints exactly [] and exits 0"
else bad "read-inbox --json: an empty read prints exactly [] and exits 0" "rc=${RC} out='${OUT}' err='${ERR}'"; fi

# 70. --json with messages present is a JSON ARRAY (not bare JSONL), each element
#     carrying the message, so `[]` and a populated read share one shape.
setup_case
seed_caches; seed_state
seed_inbox_fixtures "[{\"ts\":\"2000.5\",\"user\":\"${CODY}\",\"text\":\"look at MR 7\"}]" '[]'
run_bin read-inbox --json --peek
if [[ "$(printf '%s' "${OUT}" | jq -r 'type')" == "array" ]] \
   && [[ "$(printf '%s' "${OUT}" | jq -r '.[0].text')" == "look at MR 7" ]] \
   && [[ "${RC}" == 0 ]]; then
  ok "read-inbox --json: a populated read is a JSON array of the messages"
else bad "read-inbox --json: a populated read is a JSON array of the messages" "rc=${RC} out='${OUT}'"; fi

# 71. TEST THE MISS. A failure path (here: no bot token) must exit non-zero with
#     a Fix: line on stderr, and must NOT print `[]` or empty-and-0 -- otherwise
#     a broken read reads as an empty inbox, the exact class this skill fights.
setup_case
seed_caches; seed_state
rm -f "${CHOME}/.claude/slack-bot-token"
seed_inbox_fixtures '[]' '[]'
run_bin read-inbox --json --peek
if [[ "${RC}" != 0 ]] && [[ "${ERR}" == *"Fix:"* ]] && [[ "${OUT}" != "[]" ]] && [[ -z "${OUT}" ]]; then
  ok "read-inbox --json: a token failure exits non-zero with Fix:, not []"
else bad "read-inbox --json: a token failure exits non-zero with Fix:, not []" "rc=${RC} out='${OUT}' err='${ERR}'"; fi

# 72. ...and a Slack API failure is the same: non-zero, Fix:, never []. A dead
#     read must never be a quiet inbox.
setup_case
seed_caches; seed_state
fixture conversations.list '{"ok":false,"error":"invalid_auth"}'
run_bin read-inbox --json --peek
if [[ "${RC}" != 0 ]] && [[ "${ERR}" == *"Fix:"* ]] && [[ "${ERR}" == *"invalid_auth"* ]] && [[ "${OUT}" != "[]" ]]; then
  ok "read-inbox --json: a Slack API failure exits non-zero with Fix:, not []"
else bad "read-inbox --json: a Slack API failure exits non-zero with Fix:, not []" "rc=${RC} out='${OUT}' err='${ERR}'"; fi

echo
echo "-- DND-300/DND-318: the backstop's kind vocab is im | mpim -----------------"

# 73. A 1:1 conversation is labeled `im` (not the legacy `dm`), and is counted
#     as a DM. The conversation object has no is_mpim flag, so it is a 1:1.
setup_case
seed_caches; seed_state
fixture conversations.list '{"ok":true,"channels":[{"id":"D0CODY","is_im":true,"user":"UFAKE00001"}],"response_metadata":{"next_cursor":""}}'
fixture_seq conversations.history 1 "{\"ok\":true,\"messages\":[{\"ts\":\"2000.5\",\"user\":\"${CODY}\",\"text\":\"one to one\"}],\"response_metadata\":{\"next_cursor\":\"\"}}"
fixture_seq conversations.history 2 '{"ok":true,"messages":[],"response_metadata":{"next_cursor":""}}'
run_bin read-inbox --json --peek
if [[ "$(printf '%s' "${OUT}" | jq -r '.[0].kind')" == "im" ]]; then
  ok "kind: a 1:1 conversation is labeled im"
else bad "kind: a 1:1 conversation is labeled im" "out='${OUT}'"; fi

# 74. A GROUP DM (is_mpim) is labeled `mpim`, from the conversation type the API
#     returns -- the classification the whole item exists to add.
setup_case
seed_caches; seed_state
fixture conversations.list '{"ok":true,"channels":[{"id":"D0GROUP","is_mpim":true}],"response_metadata":{"next_cursor":""}}'
fixture_seq conversations.history 1 "{\"ok\":true,\"messages\":[{\"ts\":\"2000.6\",\"user\":\"${CODY}\",\"text\":\"group hello\"}],\"response_metadata\":{\"next_cursor\":\"\"}}"
fixture_seq conversations.history 2 '{"ok":true,"messages":[],"response_metadata":{"next_cursor":""}}'
# seed_state only keys D0CODY/ENG; D0GROUP is first-sight, so seed its watermark.
printf '{"v":1,"channels":{"D0GROUP":"1000.0"},"seen_event_ids":[],"seen_keys":[]}' > "${STATE}"
run_bin read-inbox --json --peek
if [[ "$(printf '%s' "${OUT}" | jq -r '.[0].kind')" == "mpim" ]]; then
  ok "kind: a group DM (is_mpim) is labeled mpim"
else bad "kind: a group DM (is_mpim) is labeled mpim" "out='${OUT}'"; fi

# 75. Both im and mpim count as DMs in the human-readable tally, so the split
#     from a single `dm` label does not change what the count means.
setup_case
seed_caches
printf '{"v":1,"channels":{"D0CODY":"1000.0","D0GROUP":"1000.0"},"seen_event_ids":[],"seen_keys":[]}' > "${STATE}"
fixture conversations.list '{"ok":true,"channels":[{"id":"D0CODY","is_im":true,"user":"UFAKE00001"},{"id":"D0GROUP","is_mpim":true}],"response_metadata":{"next_cursor":""}}'
fixture_seq conversations.history 1 "{\"ok\":true,\"messages\":[{\"ts\":\"2000.5\",\"user\":\"${CODY}\",\"text\":\"im msg\"}],\"response_metadata\":{\"next_cursor\":\"\"}}"
fixture_seq conversations.history 2 "{\"ok\":true,\"messages\":[{\"ts\":\"2000.6\",\"user\":\"${CODY}\",\"text\":\"mpim msg\"}],\"response_metadata\":{\"next_cursor\":\"\"}}"
run_bin read-inbox --peek
if [[ "${OUT}" == *"2 new DM(s)"* ]]; then
  ok "kind: im + mpim are both counted as DMs"
else bad "kind: im + mpim are both counted as DMs" "out='${OUT}'"; fi

# 77. DND-682: status sets the thread status with the documented body shape,
#     default text, and says on stdout where it set it.
echo
echo "-- status (assistant.threads.setStatus) -----------------------------------"
setup_case
fixture assistant.threads.setStatus '{"ok":true}'
run_bin status D0DMCHAN 1790360915.980679
B="$(body_of assistant.threads.setStatus)"
if [[ "${RC}" == 0 ]] && [[ "$(jq -r '.channel_id' <<<"${B}")" == "D0DMCHAN" ]] \
   && [[ "$(jq -r '.thread_ts' <<<"${B}")" == "1790360915.980679" ]] \
   && [[ "$(jq -r '.status' <<<"${B}")" == "is thinking…" ]] \
   && [[ "${OUT}" == *"status set on D0DMCHAN/1790360915.980679"* ]]; then
  ok "status: default 'is thinking…' is sent as channel_id/thread_ts/status"
else bad "status: default 'is thinking…' is sent as channel_id/thread_ts/status" "rc=${RC} body=${B} out='${OUT}' err='${ERR}'"; fi

# 78. --clear sends status "" (Slack's clear), in any flag position.
for order in first last; do
  setup_case
  fixture assistant.threads.setStatus '{"ok":true}'
  if [[ "${order}" == first ]]; then run_bin status --clear D0DMCHAN 1.2
  else run_bin status D0DMCHAN 1.2 --clear; fi
  B="$(body_of assistant.threads.setStatus)"
  if [[ "${RC}" == 0 ]] && [[ "$(jq -r '.status' <<<"${B}")" == "" ]] \
     && [[ "$(jq -r 'has("status")' <<<"${B}")" == "true" ]] \
     && [[ "${OUT}" == *"status cleared on D0DMCHAN/1.2"* ]]; then
    ok "status: --clear (${order}) sends status \"\""
  else bad "status: --clear (${order}) sends status \"\"" "rc=${RC} body=${B} out='${OUT}' err='${ERR}'"; fi
done

# 79. Custom text, and a #name resolves through the channel cache.
setup_case
seed_caches
fixture assistant.threads.setStatus '{"ok":true}'
run_bin status "#eng-fixture" 1.2 "is checking CI…"
B="$(body_of assistant.threads.setStatus)"
if [[ "${RC}" == 0 ]] && [[ "$(jq -r '.channel_id' <<<"${B}")" == "${ENG_CHANNEL}" ]] \
   && [[ "$(jq -r '.status' <<<"${B}")" == "is checking CI…" ]]; then
  ok "status: custom text is sent and #name resolves to the channel id"
else bad "status: custom text is sent and #name resolves to the channel id" "rc=${RC} body=${B} err='${ERR}'"; fi

# 80. TEST THE MISS: Slack's own refusals exit non-zero with the error and a
#     specific Fix:, and print nothing on stdout that reads as success.
for err in invalid_thread_ts channel_not_found; do
  setup_case
  fixture assistant.threads.setStatus "{\"ok\":false,\"error\":\"${err}\"}"
  run_bin status D0DMCHAN 1.2
  case "${err}" in
    invalid_thread_ts) want="PARENT ts" ;;
    channel_not_found) want="bot must be a member" ;;
  esac
  if [[ "${RC}" != 0 ]] && [[ -z "${OUT}" ]] && [[ "${ERR}" == *"${err}"* ]] \
     && [[ "${ERR}" == *"Fix:"*"${want}"* ]] && [[ "${ERR}" == *"send the reply anyway"* ]]; then
    ok "status: ${err} exits non-zero with a specific Fix:"
  else bad "status: ${err} exits non-zero with a specific Fix:" "rc=${RC} out='${OUT}' err='${ERR}'"; fi
done

# 81. ...a missing token is the same: non-zero, Fix:, and no request at all.
setup_case
rm -f "${CHOME}/.claude/slack-bot-token"
run_bin status D0DMCHAN 1.2
if [[ "${RC}" != 0 ]] && [[ -z "${OUT}" ]] && [[ "${ERR}" == *"no bot token"* ]] \
   && [[ "${ERR}" == *"Fix:"*"whoami"* ]] && ! any_curl; then
  ok "status: a missing token exits non-zero with Fix: and no Slack call"
else bad "status: a missing token exits non-zero with Fix: and no Slack call" "rc=${RC} out='${OUT}' err='${ERR}'"; fi

# 82. Malformed input is refused locally, before any Slack call: a ts that is
#     not digits.digits, --clear with text, empty text, an unknown flag, and a
#     missing thread_ts.
st_refuse() { # st_refuse <label> <args...>
  local label="$1"; shift
  setup_case
  run_bin status "$@"
  if [[ "${RC}" == 2 ]] && [[ "${ERR}" == *"Fix:"* ]] && [[ -z "${OUT}" ]] && ! any_curl; then
    ok "status: ${label} is a usage error with Fix:, no Slack call"
  else bad "status: ${label} is a usage error with Fix:, no Slack call" "rc=${RC} out='${OUT}' err='${ERR}'"; fi
}
st_refuse "a ts with no dot" D0DMCHAN 1790360915
st_refuse "a ts with letters" D0DMCHAN abc.def
st_refuse "--clear with text" D0DMCHAN 1.2 "hi" --clear
st_refuse "empty text" D0DMCHAN 1.2 ""
st_refuse "an unknown flag" D0DMCHAN 1.2 --loud
st_refuse "a missing thread_ts" D0DMCHAN

# 83. --help in a later position is still help, never a set: flag order does
#     not matter for status, so --help must not either.
setup_case
run_bin status D0DMCHAN 1.2 --help
if [[ "${RC}" == 0 ]] && [[ "${OUT}" == *"usage"* || "${OUT}" == *"status <channel"* ]] && ! any_curl; then
  ok "status: a trailing --help prints usage, exit 0, no Slack call"
else bad "status: a trailing --help prints usage, exit 0, no Slack call" "rc=${RC} out='${OUT}' calls=$(cat "${SHIM_DIR}/calls" 2>/dev/null)"; fi

# 76. DND-508: every bin answers --help (and -h) with its usage on STDOUT, exit
#     0, and no Slack call. Before this, `post --help` took "--help" as the
#     channel and read stdin as the message, `whoami --help` called auth.test,
#     and the rest printed usage to stderr with exit 2 -- a help request that
#     ran the tool's default action or read as a failure.
for bin_path in "${BIN}"/*; do
  name="$(basename "${bin_path}")"
  for flag in --help -h; do
    setup_case
    run_bin_stdin "" "${name}" "${flag}"
    if [[ "${RC}" -eq 0 && "${OUT}" == *"${name}"* ]] && ! any_curl; then
      ok "help: ${name} ${flag} prints usage on stdout, exit 0, no Slack call"
    else
      bad "help: ${name} ${flag} prints usage on stdout, exit 0, no Slack call" \
          "rc=${RC} curl_calls=$(cat "${SHIM_DIR}/calls" 2>/dev/null | tr '\n' ' ') out='${OUT}' err='${ERR}'"
    fi
  done
done

echo
echo "-- DND-491: claim the thread a post/dm starts ------------------------------"

INBOX_LIB_DIR="$(dirname "${ROOT}")/athena:inbox/lib"
# claim_fn <fn> [args...] -- one claim.sh function in a fresh bash with the
# libraries claim-thread sources, the per-case env, and RUN_CWD as cwd. Sets
# OUT, ERR, RC.
claim_fn() {
  set +e
  OUT="$(cd "${RUN_CWD:-${TMP}}" && env HOME="${CHOME}" ATHENA_INBOX_ROOT="${CHOME}/inbox-root" \
    ATHENA_INBOX_CLIENT_CONFIG="${CHOME}/client.json" INBOX_LIB_DIR="${INBOX_LIB_DIR}" CLAIM_LIB="${ROOT}/lib/claim.sh" \
    bash -c 'for f in err.sh names.sh descriptor.sh logchan.sh maildir.sh fence.sh session.sh fs.sh lock.sh inbox.sh; do . "${INBOX_LIB_DIR}/${f}"; done; . "${CLAIM_LIB}"; "$@"' \
    claim_fn "$@" 2>"${TMP}/cerr${CASE_N}")"
  RC=$?
  set -e
  ERR="$(cat "${TMP}/cerr${CASE_N}")"
}

SLACK_CH='{"slack":{"kind":"log","path":"cproj-slack.jsonl","dedupe":["event_id","channel+ts"],"schema_v":[1],"stale_after_s":0},"session":{"kind":"log","path":"cproj-session.jsonl","producer":"platform","stale_after_s":0}}'
mcp_answer() { # mcp_answer <tool> <json-rpc-message>  (served as an SSE event)
  mkdir -p "${SHIM_DIR}/mcp"
  printf 'event: message\ndata: %s\n\n' "$2" > "${SHIM_DIR}/mcp/$1.answer"
}
claim_ok_answer() { # claim_ok_answer <status>
  mcp_answer slack_thread_claim "$(jq -n -c --arg s "$1" \
    '{jsonrpc:"2.0", id:2, result:{isError:false, content:[{type:"text", text:({status:$s, claim_id:"c-1", inbox_name:"cproj-slack.jsonl"}|tojson)}]}}')"
}
claim_err_answer() { # claim_err_answer <tool-error-text>
  mcp_answer slack_thread_claim "$(jq -n -c --arg t "$1" \
    '{jsonrpc:"2.0", id:2, result:{isError:true, content:[{type:"text", text:$t}]}}')"
}
mcp_calls() { cat "${SHIM_DIR}/mcp.calls" 2>/dev/null || true; }
claim_args() { cat "${SHIM_DIR}/mcp.args.slack_thread_claim.json" 2>/dev/null || true; }

# claim_setup [channels-json] -- a project repo with a registry entry, the MCP
# registered for it, a machine token, the bot identity cached, cwd = the repo,
# and a default `claimed` answer.
claim_setup() {
  seed_caches
  printf '{"ok":true,"user":"athena","user_id":"%s","bot_id":"%s","team_id":"%s"}' \
    "${BOT_USER}" "${BOT_ID}" "${TEAM_ID}" > "${CACHE}/identity.json"
  PROJ="${CHOME}/dev/cproj"; mkdir -p "${PROJ}/sub/dir"
  ( cd "${PROJ}" && git init -q . && git config user.email t@t && git config user.name t \
    && git commit -q --allow-empty -m init )
  COMMON="$(cd "${PROJ}" && realpath "$(git rev-parse --git-common-dir)")"
  MAIN="$(dirname "${COMMON}")"
  mkdir -p "${CHOME}/inbox-root/projects"; chmod 700 "${CHOME}/inbox-root" "${CHOME}/inbox-root/projects"
  jq -n --arg r "${COMMON}" --argjson c "${1:-${SLACK_CH}}" '{v:1, repo:$r, channels:$c}' \
    > "${CHOME}/inbox-root/projects/cproj.json"
  chmod 600 "${CHOME}/inbox-root/projects/cproj.json"
  jq -n --arg p "${MAIN}" --arg u "${MCP_URL}" '{projects: {($p): {mcpServers: {athena: {type: "http", url: $u}}}}}' \
    > "${CHOME}/.claude.json"
  jq -n --arg t "${MCP_BEARER}" '{token: $t, server_url: "wss://athena.example.test/machine/websocket"}' \
    > "${CHOME}/client.json"; chmod 600 "${CHOME}/client.json"
  RUN_CWD="${PROJ}"
  claim_ok_answer claimed
}

# u1-u4. claim_parse_result: the tool's answer, one token. An empty or garbled
#        answer is never `claimed` and never `not-found`.
setup_case
parse_case() { # parse_case <label> <message> <want>
  claim_fn claim_parse_result "$2"
  if [[ "${OUT}" == "$3" ]]; then ok "claim_parse_result: $1 -> $3"
  else bad "claim_parse_result: $1 -> $3" "got '${OUT}' rc=${RC}"; fi
}
ok_msg() { jq -n -c --arg s "$1" '{jsonrpc:"2.0", id:2, result:{isError:false, content:[{type:"text", text:({status:$s}|tojson)}]}}'; }
err_msg() { jq -n -c --arg t "$1" '{jsonrpc:"2.0", id:2, result:{isError:true, content:[{type:"text", text:$t}]}}'; }
parse_case "claimed" "$(ok_msg claimed)" "claimed"
parse_case "already_yours" "$(ok_msg already_yours)" "already_yours"
parse_case "structuredContent claimed" '{"jsonrpc":"2.0","id":2,"result":{"structuredContent":{"status":"claimed"}}}' "claimed"
parse_case "a tool error 'not found'" "$(err_msg 'not found')" "not-found"
parse_case "refused: ... Fix: ..." "$(err_msg 'refused: inbox_name is not one of this machine'"'"'s Slack inboxes. Fix: use lookup_inbox')" "refused"
parse_case "already_claimed: ..." "$(err_msg 'already_claimed: another inbox holds this thread')" "already-claimed"
parse_case "invalid: thread_ts ..." "$(err_msg 'invalid: thread_ts must be digits.digits')" "invalid"
parse_case "'not found' with a trailing newline" "$(err_msg $'not found\n')" "not-found"
parse_case "an empty answer" "" "mcp-error:no-answer"
parse_case "a non-JSON answer" "<html>502</html>" "mcp-error:no-answer"
parse_case "a result with no status" '{"jsonrpc":"2.0","id":2,"result":{"content":[{"type":"text","text":"{\"claim_id\":\"x\"}"}]}}' "mcp-error:no-status-in-result"
parse_case "an unknown status" "$(ok_msg released)" "mcp-error:unexpected-status released"
parse_case "a JSON-RPC error" '{"jsonrpc":"2.0","id":2,"error":{"code":-32601,"message":"Method not found"}}' "mcp-error:Method not found"
parse_case "an unrecognised tool error, multi-line" "$(err_msg $'boom\nsecond line')" "mcp-error:boom second line"
# u4b. DND-1645: the athena server (Hermes Error.execution) sends every refusal
#      as a JSON-RPC `error` whose message is the text, not as an isError
#      result. Both shapes go through one classifier, by exact token: the
#      token alone, or the token followed by a colon. A protocol error whose
#      text is not a token stays an mcp-error.
rpc_err_msg() { jq -n -c --arg t "$1" --argjson c "${2:--32000}" '{jsonrpc:"2.0", id:2, error:{code:$c, message:$t, data:{}}}'; }
parse_case "JSON-RPC error already_claimed: ..." "$(rpc_err_msg 'already_claimed: this thread is claimed by another inbox. Fix: replies will route to that inbox; claim only threads your session started.')" "already-claimed"
parse_case "JSON-RPC error 'not found'" "$(rpc_err_msg 'not found')" "not-found"
parse_case "JSON-RPC error refused: ..." "$(rpc_err_msg 'refused: slack_thread_claim does not accept owner. Fix: remove the owner argument.')" "refused"
parse_case "JSON-RPC error invalid: ..." "$(rpc_err_msg 'invalid: thread_ts must be digits.digits')" "invalid"
parse_case "a bare already_claimed token (tool error)" "$(err_msg 'already_claimed')" "already-claimed"
parse_case "a bare already_claimed token (JSON-RPC error)" "$(rpc_err_msg 'already_claimed')" "already-claimed"
parse_case "a bare refused token (JSON-RPC error)" "$(rpc_err_msg 'refused')" "refused"
parse_case "a bare invalid token (JSON-RPC error)" "$(rpc_err_msg 'invalid')" "invalid"
parse_case "'not found' under a protocol code (-32601) is not a refusal" "$(rpc_err_msg 'not found' -32601)" "mcp-error:not found"
parse_case "already_claimedX is not the token" "$(rpc_err_msg 'already_claimedX: no')" "mcp-error:already_claimedX: no"
parse_case "'not found here' is not the token" "$(rpc_err_msg 'not found here')" "mcp-error:not found here"
parse_case "Invalid params (a protocol error) is not invalid" "$(rpc_err_msg 'Invalid params' -32602)" "mcp-error:Invalid params"
claim_fn claim_server_words "$(rpc_err_msg 'already_claimed: held. Fix: ask the holder.')"
if [[ "${OUT}" == "already_claimed: held. Fix: ask the holder." ]]; then
  ok "claim_server_words: a JSON-RPC error's message is the server's words"
else bad "claim_server_words: a JSON-RPC error's message is the server's words" "got '${OUT}' rc=${RC}"; fi
claim_fn claim_server_words "$(rpc_err_msg 'Method not found' -32601)"
if [[ -z "${OUT}" && "${RC}" == 0 ]]; then
  ok "claim_server_words: a protocol error (-32601) has no server words"
else bad "claim_server_words: a protocol error (-32601) has no server words" "got '${OUT}' rc=${RC}"; fi

# u5. claim_reason_fix: every reason has its own non-empty Fix text.
setup_case
FIXES=""
for r in no-registry-entry registry-error no-slack-channel ambiguous-slack-channel no-identity no-token \
         mcp-unregistered mcp-error:x not-found refused already-claimed invalid \
         cwd-project-mismatch project-unresolved; do
  claim_fn claim_reason_fix "${r}"
  if [[ -z "${OUT}" ]]; then bad "claim_reason_fix: ${r} has a Fix text" "empty"; continue; fi
  FIXES="${FIXES}${OUT}"$'\n'
done
if [[ "$(printf '%s' "${FIXES}" | sort | uniq -d | wc -l)" -eq 0 ]] \
   && [[ "$(printf '%s' "${FIXES}" | grep -c .)" -eq 14 ]]; then
  ok "claim_reason_fix: all 14 reasons have a non-empty, distinct Fix text"
else bad "claim_reason_fix: all 14 reasons have a non-empty, distinct Fix text" "$(printf '%s' "${FIXES}" | sort | uniq -c | sort -rn | head -3)"; fi

# u6-u11. claim_resolve_inbox: the project's ONE Slack log channel, from the
#         registry entry the cwd resolves -- never a platform channel, never a
#         guess among two, and the same from a worktree or a subdirectory.
resolve_case() { # resolve_case <label> <want> [channels-json]
  setup_case; claim_setup "${3:-}"
  claim_fn claim_resolve_inbox "$(cd "${RUN_CWD}" && pwd -P)"
  if [[ "${OUT}" == "$2" ]]; then ok "claim_resolve_inbox: $1 -> $2"
  else bad "claim_resolve_inbox: $1 -> $2" "got '${OUT}' rc=${RC} err='${ERR}'"; fi
}
resolve_case "one slack log channel" "cproj-slack.jsonl"
resolve_case "only a platform log channel" "no-slack-channel" \
  '{"session":{"kind":"log","path":"cproj-session.jsonl","producer":"platform","stale_after_s":0}}'
resolve_case "an explicit producer:slack channel" "cproj-slack.jsonl" \
  '{"s":{"kind":"log","path":"cproj-slack.jsonl","producer":"slack"}}'
resolve_case "two slack log channels" "ambiguous-slack-channel" \
  '{"a":{"kind":"log","path":"cproj-slack.jsonl"},"b":{"kind":"log","path":"cproj-other.jsonl"}}'
setup_case; claim_setup; rm -f "${CHOME}/inbox-root/projects/cproj.json"
claim_fn claim_resolve_inbox "${PROJ}"
if [[ "${OUT}" == "no-registry-entry" && "${RC}" != 0 ]]; then ok "claim_resolve_inbox: no entry for this repo -> no-registry-entry"
else bad "claim_resolve_inbox: no entry for this repo -> no-registry-entry" "got '${OUT}' rc=${RC}"; fi

# u11b. DND-491 fix round (critic finding): an UNPARSEABLE other tenant's
#       registry file, with no entry matching THIS repo, must be
#       `registry-error` -- never folded into `no-registry-entry`, because the
#       broken file may be this project's own (fs_registry_records' own
#       reasoning, restated here as the negative test claim_resolve_inbox never
#       had).
setup_case; claim_setup; rm -f "${CHOME}/inbox-root/projects/cproj.json"
printf 'not valid json' > "${CHOME}/inbox-root/projects/zzbroken.json"
chmod 600 "${CHOME}/inbox-root/projects/zzbroken.json"
claim_fn claim_resolve_inbox "${PROJ}"
if [[ "${OUT}" == "registry-error" && "${RC}" != 0 ]]; then
  ok "claim_resolve_inbox: an unparseable OTHER registry entry, no match for this repo -> registry-error"
else bad "claim_resolve_inbox: an unparseable OTHER registry entry, no match for this repo -> registry-error" \
  "got '${OUT}' rc=${RC}"; fi
setup_case; claim_setup; rm -f "${CHOME}/inbox-root/projects/cproj.json"
printf 'not valid json' > "${CHOME}/inbox-root/projects/zzbroken.json"
chmod 600 "${CHOME}/inbox-root/projects/zzbroken.json"
run_bin claim-thread D0DMCHAN 1.2
if [[ "${RC}" == 3 && "${ERR}" == *"reason=registry-error "* && "${ERR}" == *"Fix:"* ]]; then
  ok "claim-thread: an unparseable OTHER registry entry -> exit 3 reason=registry-error, Fix:"
else bad "claim-thread: an unparseable OTHER registry entry -> exit 3 reason=registry-error, Fix:" "rc=${RC} err='${ERR}'"; fi

# u11c. DND-491 fix round (critic finding): mcp_registered_url's internal-error
#       status (2, "a lookup key is not an absolute path") is its own status,
#       never folded into 1 (not registered) -- this is the status
#       claim-thread's own case maps to reason mcp-error:registration-key. Not
#       reachable end-to-end through claim-thread: both callers that compute
#       the key (inbox_mcp_main_checkout, mcp_toplevel) already realpath their
#       result, so a real repo can never hand it a relative key. The function
#       itself is the regression target for the defensive branch.
setup_case
claim_fn mcp_registered_url "relative/main" "/abs/top"
if [[ "${RC}" == 2 ]]; then
  ok "mcp_registered_url: a non-absolute main-checkout key -> status 2 (internal, never 'not registered')"
else bad "mcp_registered_url: a non-absolute main-checkout key -> status 2 (internal, never 'not registered')" \
  "rc=${RC} out='${OUT}' err='${ERR}'"; fi
setup_case
claim_fn mcp_registered_url "/abs/main" "relative/top"
if [[ "${RC}" == 2 ]]; then
  ok "mcp_registered_url: a non-absolute toplevel key -> status 2"
else bad "mcp_registered_url: a non-absolute toplevel key -> status 2" "rc=${RC} out='${OUT}' err='${ERR}'"; fi
setup_case; claim_setup
WT="${CHOME}/wt/cproj-feature"
( cd "${PROJ}" && git worktree add -q -b feature "${WT}" ) >/dev/null 2>&1
RUN_CWD="${WT}"; claim_fn claim_resolve_inbox "$(cd "${WT}" && pwd -P)"
if [[ "${OUT}" == "cproj-slack.jsonl" ]]; then ok "claim_resolve_inbox: a worktree resolves the main checkout's entry"
else bad "claim_resolve_inbox: a worktree resolves the main checkout's entry" "got '${OUT}' rc=${RC} err='${ERR}'"; fi
setup_case; claim_setup
RUN_CWD="${PROJ}/sub/dir"; claim_fn claim_resolve_inbox "$(cd "${PROJ}/sub/dir" && pwd -P)"
if [[ "${OUT}" == "cproj-slack.jsonl" ]]; then ok "claim_resolve_inbox: a subdirectory of the main checkout (relative git common dir) still resolves"
else bad "claim_resolve_inbox: a subdirectory of the main checkout (relative git common dir) still resolves" "got '${OUT}' rc=${RC} err='${ERR}'"; fi
setup_case; claim_setup
claim_fn claim_resolve_inbox "relative/path"
if [[ "${OUT}" == "no-registry-entry" && "${RC}" != 0 ]]; then ok "claim_resolve_inbox: a relative cwd key is refused, never looked up"
else bad "claim_resolve_inbox: a relative cwd key is refused, never looked up" "got '${OUT}' rc=${RC}"; fi

# c1. claim-thread: the whole call, and exactly the fields the server takes.
#     No machine_id / owner / agent_instance_id: the server derives those, and
#     a value for any of them is refused.
setup_case; claim_setup
run_bin claim-thread D0DMCHAN 1790360915.000100
ARGS="$(claim_args)"
if [[ "${RC}" == 0 && "${OUT}" == "claim=claimed inbox=cproj-slack.jsonl source=cwd" ]] \
   && [[ "$(jq -r '[.bot_id,.team_id,.channel,.thread_ts,.inbox_name]|join(" ")' <<<"${ARGS}")" == "${BOT_ID} ${TEAM_ID} D0DMCHAN 1790360915.000100 cproj-slack.jsonl" ]] \
   && [[ "$(jq -r 'keys|sort|join(",")' <<<"${ARGS}")" == "bot_id,channel,inbox_name,team_id,thread_ts" ]] \
   && [[ "$(mcp_calls | tr '\n' '|')" == "initialize|initialized|tools/call slack_thread_claim|" ]]; then
  ok "claim-thread: claimed -> claim=claimed, exit 0, exactly bot_id/team_id/channel/thread_ts/inbox_name"
else bad "claim-thread: claimed -> claim=claimed, exit 0, exactly bot_id/team_id/channel/thread_ts/inbox_name" \
  "rc=${RC} out='${OUT}' err='${ERR}' args=${ARGS} calls=$(mcp_calls | tr '\n' '|')"; fi

# c1b. already_yours is success too: re-claiming your own thread is a no-op.
setup_case; claim_setup; claim_ok_answer already_yours
run_bin claim-thread D0DMCHAN 1.2
if [[ "${RC}" == 0 && "${OUT}" == "claim=already_yours inbox=cproj-slack.jsonl source=cwd" ]]; then
  ok "claim-thread: already_yours -> exit 0"
else bad "claim-thread: already_yours -> exit 0" "rc=${RC} out='${OUT}' err='${ERR}'"; fi

# c2. No machine token: its own reason, and nothing is sent.
setup_case; claim_setup; rm -f "${CHOME}/client.json"
run_bin claim-thread D0DMCHAN 1.2
if [[ "${RC}" == 3 && "${ERR}" == *"reason=no-token "* && "${ERR}" == *"Fix:"* ]] && [[ -z "$(mcp_calls)" ]]; then
  ok "claim-thread: no machine token -> exit 3 reason=no-token, Fix:, no MCP call"
else bad "claim-thread: no machine token -> exit 3 reason=no-token, Fix:, no MCP call" "rc=${RC} err='${ERR}' calls=$(mcp_calls)"; fi

# c3. The machine token travels only in the stdin curl config: never argv,
#     never a file left behind, never the environment.
setup_case; claim_setup
run_bin claim-thread D0DMCHAN 1.2
LEFT="$(grep -rl "${MCP_BEARER}" "${TMP}" 2>/dev/null | grep -v "/client.json$" | grep -v "/shim${CASE_N}/" || true)"
if ! grep -q "${MCP_BEARER}" "${SHIM_DIR}/argv" 2>/dev/null \
   && [[ "$(cat "${SHIM_DIR}/mcp.bearer" 2>/dev/null | sort -u)" == "ok" ]] && [[ -z "${LEFT}" ]]; then
  ok "claim-thread: the machine token is sent as a Bearer header via stdin only (not argv, no file left)"
else bad "claim-thread: the machine token is sent as a Bearer header via stdin only (not argv, no file left)" \
  "argv=$(grep -c "${MCP_BEARER}" "${SHIM_DIR}/argv" 2>/dev/null) bearer=$(cat "${SHIM_DIR}/mcp.bearer" 2>/dev/null) left='${LEFT}'"; fi

# c4. The server's `not found`: its own reason, with the full key and inbox.
setup_case; claim_setup; claim_err_answer "not found"
run_bin claim-thread D0DMCHAN 1790.1
if [[ "${RC}" == 3 && "${ERR}" == *"claim=FAILED reason=not-found key=${TEAM_ID}/D0DMCHAN/1790.1 inbox=cproj-slack.jsonl"* && "${ERR}" == *"Fix:"* ]]; then
  ok "claim-thread: not found -> exit 3 reason=not-found key=<team>/<chan>/<ts> inbox=<inbox>"
else bad "claim-thread: not found -> exit 3 reason=not-found key=<team>/<chan>/<ts> inbox=<inbox>" "rc=${RC} err='${ERR}'"; fi

# c4b. A refusal carries the server's own words on a server: line.
setup_case; claim_setup; claim_err_answer "refused: inbox_name is not live. Fix: lookup_inbox"
run_bin claim-thread D0DMCHAN 1.2
if [[ "${RC}" == 3 && "${ERR}" == *"reason=refused "* && "${ERR}" == *"server: refused: inbox_name is not live. Fix: lookup_inbox"* ]]; then
  ok "claim-thread: refused -> exit 3 reason=refused, the server's words on a server: line"
else bad "claim-thread: refused -> exit 3 reason=refused, the server's words on a server: line" "rc=${RC} err='${ERR}'"; fi

# c5. A malformed ts or channel: exit 2, Fix:, no call of any kind.
for bad_args in "D0DMCHAN abc" "D0DMCHAN 1790" "UFAKE00001 1.2" "d0dm 1.2"; do
  setup_case; claim_setup
  # shellcheck disable=SC2086
  run_bin claim-thread ${bad_args}
  if [[ "${RC}" == 2 && "${ERR}" == *"reason=invalid"* && "${ERR}" == *"Fix:"* ]] && [[ -z "$(mcp_calls)" ]] && ! any_curl; then
    ok "claim-thread: '${bad_args}' -> exit 2 reason=invalid, Fix:, no call"
  else bad "claim-thread: '${bad_args}' -> exit 2 reason=invalid, Fix:, no call" "rc=${RC} err='${ERR}'"; fi
done

# c5b. DND-1521: --already-claimed-ok (either position) turns the server's
#      already_claimed into an outcome on stdout, exit 0; without it the same
#      answer is still claim=FAILED, exit 3. An unknown flag is invalid.
for args in "--already-claimed-ok D0DMCHAN 1.2" "D0DMCHAN 1.2 --already-claimed-ok"; do
  setup_case; claim_setup; claim_err_answer "already_claimed: another inbox holds this thread"
  # shellcheck disable=SC2086
  run_bin claim-thread ${args}
  if [[ "${RC}" == 0 && "${OUT}" == "claim=already_claimed holder=another-inbox inbox=cproj-slack.jsonl source=cwd" && -z "${ERR}" ]] \
     && [[ "$(jq -r '.channel + " " + .thread_ts' <<<"$(claim_args)")" == "D0DMCHAN 1.2" ]]; then
    ok "claim-thread '${args}': already_claimed -> stdout outcome, exit 0"
  else bad "claim-thread '${args}': already_claimed -> stdout outcome, exit 0" "rc=${RC} out='${OUT}' err='${ERR}'"; fi
done
setup_case; claim_setup; claim_err_answer "already_claimed: another inbox holds this thread"
run_bin claim-thread D0DMCHAN 1.2
if [[ "${RC}" == 3 && "${ERR}" == *"claim=FAILED reason=already-claimed "* && -z "${OUT}" ]]; then
  ok "claim-thread: already_claimed without the flag -> claim=FAILED, exit 3"
else bad "claim-thread: already_claimed without the flag -> claim=FAILED, exit 3" "rc=${RC} out='${OUT}' err='${ERR}'"; fi
setup_case; claim_setup; claim_err_answer "not found"
run_bin claim-thread D0DMCHAN 1.2 --already-claimed-ok
if [[ "${RC}" == 3 && "${ERR}" == *"claim=FAILED reason=not-found "* && -z "${OUT}" ]]; then
  ok "claim-thread --already-claimed-ok: any other refusal is still claim=FAILED, exit 3"
else bad "claim-thread --already-claimed-ok: any other refusal is still claim=FAILED, exit 3" "rc=${RC} out='${OUT}' err='${ERR}'"; fi
# c5c. DND-1645: the server's real refusal shape, a JSON-RPC error (Hermes
#      Error.execution). already_claimed is reason=already-claimed with the
#      transfer Fix (never mcp-error), and --already-claimed-ok makes it exit 0.
#      not found / refused / invalid keep their own reasons in that shape too.
claim_rpc_err_answer() { # claim_rpc_err_answer <message>
  mcp_answer slack_thread_claim "$(jq -n -c --arg t "$1" '{jsonrpc:"2.0", id:2, error:{code:-32000, message:$t, data:{}}}')"
}
HERMES_HELD='already_claimed: this thread is claimed by another inbox. Fix: replies will route to that inbox; claim only threads your session started.'
setup_case; claim_setup; claim_rpc_err_answer "${HERMES_HELD}"
run_bin claim-thread D0DMCHAN 1.2
if [[ "${RC}" == 3 && "${ERR}" == *"claim=FAILED reason=already-claimed "* && "${ERR}" != *"mcp-error"* \
      && "${ERR}" == *"reroute_of_event_id"* && "${ERR}" == *"server: already_claimed: this thread"* && -z "${OUT}" ]]; then
  ok "claim-thread: a JSON-RPC already_claimed -> reason=already-claimed, transfer Fix, exit 3"
else bad "claim-thread: a JSON-RPC already_claimed -> reason=already-claimed, transfer Fix, exit 3" "rc=${RC} out='${OUT}' err='${ERR}'"; fi
setup_case; claim_setup; claim_rpc_err_answer "${HERMES_HELD}"
run_bin claim-thread D0DMCHAN 1.2 --already-claimed-ok
if [[ "${RC}" == 0 && "${OUT}" == "claim=already_claimed holder=another-inbox inbox=cproj-slack.jsonl source=cwd" && -z "${ERR}" ]]; then
  ok "claim-thread --already-claimed-ok: a JSON-RPC already_claimed -> stdout outcome, exit 0"
else bad "claim-thread --already-claimed-ok: a JSON-RPC already_claimed -> stdout outcome, exit 0" "rc=${RC} out='${OUT}' err='${ERR}'"; fi
for pair in "not found|not-found|3" "refused: inbox_name is not live. Fix: lookup_inbox|refused|3" "invalid: thread_ts must be digits.digits|invalid|2"; do
  IFS='|' read -r words want code <<<"${pair}"
  setup_case; claim_setup; claim_rpc_err_answer "${words}"
  run_bin claim-thread D0DMCHAN 1.2 --already-claimed-ok
  if [[ "${RC}" == "${code}" && "${ERR}" == *"claim=FAILED reason=${want} "* && -z "${OUT}" ]]; then
    ok "claim-thread: a JSON-RPC '${words%%:*}' -> reason=${want}, exit ${code}"
  else bad "claim-thread: a JSON-RPC '${words%%:*}' -> reason=${want}, exit ${code}" "rc=${RC} out='${OUT}' err='${ERR}'"; fi
done
setup_case; claim_setup
run_bin claim-thread D0DMCHAN 1.2 --loud
if [[ "${RC}" == 2 && "${ERR}" == *"reason=invalid"* && "${ERR}" == *"Fix:"* && -z "$(mcp_calls)" ]]; then
  ok "claim-thread: an unknown flag -> exit 2 reason=invalid, no call"
else bad "claim-thread: an unknown flag -> exit 2 reason=invalid, no call" "rc=${RC} err='${ERR}'"; fi

# c6. A 500 or garbage from the server is an mcp-error, never claimed.
setup_case; claim_setup; mkdir -p "${SHIM_DIR}/mcp"; printf 500 > "${SHIM_DIR}/mcp/slack_thread_claim.code"
run_bin claim-thread D0DMCHAN 1.2
if [[ "${RC}" == 3 && "${ERR}" == *"reason=mcp-error:"*"HTTP 500"* ]]; then
  ok "claim-thread: HTTP 500 -> exit 3 reason=mcp-error:..."
else bad "claim-thread: HTTP 500 -> exit 3 reason=mcp-error:..." "rc=${RC} err='${ERR}'"; fi
setup_case; claim_setup; mkdir -p "${SHIM_DIR}/mcp"; printf 'garbage' > "${SHIM_DIR}/mcp/slack_thread_claim.answer"
run_bin claim-thread D0DMCHAN 1.2
if [[ "${RC}" == 3 && "${ERR}" == *"reason=mcp-error:"* && "${OUT}" != *"claim=claimed"* ]]; then
  ok "claim-thread: a garbage answer -> exit 3 reason=mcp-error, never claimed"
else bad "claim-thread: a garbage answer -> exit 3 reason=mcp-error, never claimed" "rc=${RC} out='${OUT}' err='${ERR}'"; fi

# c7. The MCP not registered for this project: its own reason, no call.
setup_case; claim_setup; rm -f "${CHOME}/.claude.json"
run_bin claim-thread D0DMCHAN 1.2
if [[ "${RC}" == 3 && "${ERR}" == *"reason=mcp-unregistered "* ]] && [[ -z "$(mcp_calls)" ]]; then
  ok "claim-thread: MCP unregistered -> exit 3 reason=mcp-unregistered, no call"
else bad "claim-thread: MCP unregistered -> exit 3 reason=mcp-unregistered, no call" "rc=${RC} err='${ERR}'"; fi

# c8. An identity cache written before bot_id was read is refreshed once; an
#     auth.test that still lacks it is no-identity, never an empty bot_id.
setup_case; claim_setup
printf '{"ok":true,"user":"athena","user_id":"%s","team_id":"%s"}' "${BOT_USER}" "${TEAM_ID}" > "${CACHE}/identity.json"
fixture auth.test "{\"ok\":true,\"user_id\":\"${BOT_USER}\",\"bot_id\":\"${BOT_ID}\",\"team_id\":\"${TEAM_ID}\"}"
run_bin claim-thread D0DMCHAN 1.2
if [[ "${RC}" == 0 && "$(calls_of auth.test)" == 1 && "$(jq -r .bot_id <<<"$(claim_args)")" == "${BOT_ID}" ]]; then
  ok "claim-thread: a cached identity without bot_id is refreshed once from auth.test"
else bad "claim-thread: a cached identity without bot_id is refreshed once from auth.test" "rc=${RC} auth=$(calls_of auth.test) err='${ERR}'"; fi
setup_case; claim_setup; rm -f "${CACHE}/identity.json"
fixture auth.test "{\"ok\":true,\"user_id\":\"${BOT_USER}\",\"team_id\":\"${TEAM_ID}\"}"
run_bin claim-thread D0DMCHAN 1.2
if [[ "${RC}" == 3 && "${ERR}" == *"reason=no-identity "* ]] && [[ -z "$(mcp_calls)" ]]; then
  ok "claim-thread: auth.test without a bot_id -> exit 3 reason=no-identity, no call"
else bad "claim-thread: auth.test without a bot_id -> exit 3 reason=no-identity, no call" "rc=${RC} err='${ERR}'"; fi

# c8b. DND-491 fix round (critic finding): the SAME refresh-once-then-fail
#      applies when TEAM_ID (not bot_id) is the field missing from the cached
#      identity -- only the bot_id half of `slack_load_bot_identity`'s check
#      was tested before this round.
setup_case; claim_setup
printf '{"ok":true,"user":"athena","user_id":"%s","bot_id":"%s"}' "${BOT_USER}" "${BOT_ID}" > "${CACHE}/identity.json"
fixture auth.test "{\"ok\":true,\"user_id\":\"${BOT_USER}\",\"bot_id\":\"${BOT_ID}\",\"team_id\":\"${TEAM_ID}\"}"
run_bin claim-thread D0DMCHAN 1.2
if [[ "${RC}" == 0 && "$(calls_of auth.test)" == 1 && "$(jq -r .team_id <<<"$(claim_args)")" == "${TEAM_ID}" ]]; then
  ok "claim-thread: a cached identity without team_id is refreshed once from auth.test"
else bad "claim-thread: a cached identity without team_id is refreshed once from auth.test" "rc=${RC} auth=$(calls_of auth.test) err='${ERR}'"; fi
setup_case; claim_setup; rm -f "${CACHE}/identity.json"
fixture auth.test "{\"ok\":true,\"user_id\":\"${BOT_USER}\",\"bot_id\":\"${BOT_ID}\"}"
run_bin claim-thread D0DMCHAN 1.2
if [[ "${RC}" == 3 && "${ERR}" == *"reason=no-identity "* ]] && [[ -z "$(mcp_calls)" ]]; then
  ok "claim-thread: auth.test without a team_id -> exit 3 reason=no-identity, no call"
else bad "claim-thread: auth.test without a team_id -> exit 3 reason=no-identity, no call" "rc=${RC} err='${ERR}'"; fi

echo
echo "-- DND-1163: the claim is keyed on the SESSION's project, not the shell cwd --"
# A walt_ui session whose Bash cwd had drifted into ~/dev/custom claimed its
# DM thread for custom-slack.jsonl: exit 0, claim=claimed, the wrong inbox.
# Here cproj plays custom (where the cwd drifted to) and wproj plays walt_ui
# (the session's own project).

# claim_other_project <name> <registered:yes|no> -- a second repo under
# ${CHOME}/dev/<name>; with "yes" it gets a registry entry whose one Slack log
# channel is <name>-slack.jsonl. The athena MCP is registered for it either
# way, so a claim can only fail on the project key. Sets OPROJ, OCOMMON.
claim_other_project() {
  OPROJ="${CHOME}/dev/$1"; mkdir -p "${OPROJ}/sub"
  ( cd "${OPROJ}" && git init -q . && git config user.email t@t && git config user.name t \
    && git commit -q --allow-empty -m init )
  OCOMMON="$(cd "${OPROJ}" && realpath "$(git rev-parse --git-common-dir)")"
  if [[ "$2" == yes ]]; then
    jq -n --arg r "${OCOMMON}" --arg p "$1-slack.jsonl" \
      '{v:1, repo:$r, channels:{slack:{kind:"log", path:$p, dedupe:["event_id","channel+ts"], schema_v:[1], stale_after_s:0}}}' \
      > "${CHOME}/inbox-root/projects/$1.json"
    chmod 600 "${CHOME}/inbox-root/projects/$1.json"
  fi
  local cfg; cfg="$(jq --arg p "$(dirname "${OCOMMON}")" --arg u "${MCP_URL}" \
    '.projects[$p] = {mcpServers: {athena: {type: "http", url: $u}}}' "${CHOME}/.claude.json")"
  printf '%s\n' "${cfg}" > "${CHOME}/.claude.json"
}
# claim_with_env <NAME=value...> -- run_bin claim-thread with extra session env.
claim_with_env() {
  local saved_cpd="${CLAUDE_PROJECT_DIR-__unset__}" saved_pid="${CLAUDE_PID-__unset__}"
  unset CLAUDE_PROJECT_DIR CLAUDE_PID
  local kv; for kv in "$@"; do export "${kv?}"; done
  run_bin claim-thread D0DMCHAN 1790632113.515229
  unset CLAUDE_PROJECT_DIR CLAUDE_PID
  [[ "${saved_cpd}" == __unset__ ]] || export CLAUDE_PROJECT_DIR="${saved_cpd}"
  [[ "${saved_pid}" == __unset__ ]] || export CLAUDE_PID="${saved_pid}"
}

# k1. THE REPORTED DEFECT. Session project = wproj, cwd = cproj: never
#     cproj's inbox; refused as a mismatch, with a Fix:, before any MCP call.
setup_case; claim_setup; claim_other_project wproj yes
RUN_CWD="${PROJ}/sub/dir"; claim_with_env "CLAUDE_PROJECT_DIR=${OPROJ}"
if [[ "${RC}" == 3 && "${OUT}" != *"cproj-slack.jsonl"* && "${ERR}" == *"reason=cwd-project-mismatch "* ]] \
   && [[ "${ERR}" == *"Fix:"* && "${ERR}" == *"${OPROJ}"* && "${ERR}" == *"CLAUDE_PROJECT_DIR=<"* ]] && [[ -z "$(mcp_calls)" ]]; then
  ok "claim-thread: CLAUDE_PROJECT_DIR=wproj, cwd in cproj -> claim=FAILED reason=cwd-project-mismatch, Fix:, no call, never cproj's inbox"
else bad "claim-thread: CLAUDE_PROJECT_DIR=wproj, cwd in cproj -> claim=FAILED reason=cwd-project-mismatch, Fix:, no call, never cproj's inbox" \
  "rc=${RC} out='${OUT}' err='${ERR}' calls=$(mcp_calls | tr '\n' '|')"; fi

# k2. The session's project wins over a cwd that is in no registered project,
#     and the output says where the project came from.
setup_case; claim_setup; claim_other_project wproj yes
RUN_CWD="${TMP}"; claim_with_env "CLAUDE_PROJECT_DIR=${OPROJ}"
if [[ "${RC}" == 0 && "${OUT}" == "claim=claimed inbox=wproj-slack.jsonl source=project-dir" ]] \
   && [[ "$(jq -r .inbox_name <<<"$(claim_args)")" == "wproj-slack.jsonl" ]]; then
  ok "claim-thread: CLAUDE_PROJECT_DIR=wproj, cwd outside any project -> wproj's inbox, source=project-dir"
else bad "claim-thread: CLAUDE_PROJECT_DIR=wproj, cwd outside any project -> wproj's inbox, source=project-dir" \
  "rc=${RC} out='${OUT}' err='${ERR}' args=$(claim_args)"; fi

# k3. No session signal at all: the cwd, and the output says so.
setup_case; claim_setup; claim_other_project wproj yes
RUN_CWD="${PROJ}"; claim_with_env
if [[ "${RC}" == 0 && "${OUT}" == "claim=claimed inbox=cproj-slack.jsonl source=cwd" ]]; then
  ok "claim-thread: no CLAUDE_PROJECT_DIR and no CLAUDE_PID -> falls back to the cwd and says source=cwd"
else bad "claim-thread: no CLAUDE_PROJECT_DIR and no CLAUDE_PID -> falls back to the cwd and says source=cwd" \
  "rc=${RC} out='${OUT}' err='${ERR}'"; fi

# k4. The Bash tool does not export CLAUDE_PROJECT_DIR (measured 2026-09-28);
#     it exports CLAUDE_PID, the Claude Code process, whose own cwd is the
#     session's project and never follows the tool shell's `cd`. A stand-in
#     process parked in wproj plays it.
setup_case; claim_setup; claim_other_project wproj yes
( cd "${OPROJ}" && exec tail -f /dev/null ) & STANDIN=$!
RUN_CWD="${PROJ}"; claim_with_env "CLAUDE_PID=${STANDIN}"
K4A_RC="${RC}" K4A_OUT="${OUT}" K4A_ERR="${ERR}" K4A_CALLS="$(mcp_calls)"
RUN_CWD="${OPROJ}/sub"; claim_with_env "CLAUDE_PID=${STANDIN}"
kill "${STANDIN}" 2>/dev/null; wait "${STANDIN}" 2>/dev/null || true  # 143: killed, as intended (run_bin leaves set -e on)
if [[ "${K4A_RC}" == 3 && "${K4A_ERR}" == *"reason=cwd-project-mismatch "* && "${K4A_OUT}" != *"cproj-slack"* && -z "${K4A_CALLS}" ]] \
   && [[ "${RC}" == 0 && "${OUT}" == "claim=claimed inbox=wproj-slack.jsonl source=session-process" ]]; then
  ok "claim-thread: CLAUDE_PID's cwd is the session project -> cwd in cproj refused; cwd in wproj claims wproj, source=session-process"
else bad "claim-thread: CLAUDE_PID's cwd is the session project -> cwd in cproj refused; cwd in wproj claims wproj, source=session-process" \
  "first: rc=${K4A_RC} out='${K4A_OUT}' err='${K4A_ERR}'; second: rc=${RC} out='${OUT}' err='${ERR}'"; fi

# k5. A worktree of the session's own project is the same project.
setup_case; claim_setup
WT="${CHOME}/wt/cproj-k5"; ( cd "${PROJ}" && git worktree add -q -b k5 "${WT}" ) >/dev/null 2>&1
RUN_CWD="${WT}"; claim_with_env "CLAUDE_PROJECT_DIR=${PROJ}"
if [[ "${RC}" == 0 && "${OUT}" == "claim=claimed inbox=cproj-slack.jsonl source=project-dir" ]]; then
  ok "claim-thread: cwd in a worktree of the session's project -> that project's inbox, no mismatch"
else bad "claim-thread: cwd in a worktree of the session's project -> that project's inbox, no mismatch" "rc=${RC} out='${OUT}' err='${ERR}'"; fi

# k6. The session's project has NO registry entry and the cwd's does: that is
#     the drift, not a licence to borrow the cwd's inbox.
setup_case; claim_setup; claim_other_project uproj no
RUN_CWD="${PROJ}"; claim_with_env "CLAUDE_PROJECT_DIR=${OPROJ}"
if [[ "${RC}" == 3 && "${ERR}" == *"reason=cwd-project-mismatch "* && "${OUT}" != *"cproj-slack"* && -z "$(mcp_calls)" ]]; then
  ok "claim-thread: an unregistered session project with the cwd in cproj -> cwd-project-mismatch, never cproj's inbox"
else bad "claim-thread: an unregistered session project with the cwd in cproj -> cwd-project-mismatch, never cproj's inbox" "rc=${RC} out='${OUT}' err='${ERR}'"; fi

# k7. A key that resolves to nothing is an error NAMING THE KEY.
setup_case; claim_setup; claim_other_project uproj no
RUN_CWD="${TMP}"; claim_with_env "CLAUDE_PROJECT_DIR=${OPROJ}"
if [[ "${RC}" == 3 && "${ERR}" == *"reason=no-registry-entry "* && "${ERR}" == *"${OCOMMON}"* && "${ERR}" == *"Fix:"* ]] \
   && [[ -z "${OUT}" && -z "$(mcp_calls)" ]]; then
  ok "claim-thread: the session project's repo key matches no entry -> no-registry-entry naming that key"
else bad "claim-thread: the session project's repo key matches no entry -> no-registry-entry naming that key" "rc=${RC} out='${OUT}' err='${ERR}'"; fi

# k8. A session signal that is SET but unusable is refused by name, never
#     skipped in favour of the next source.
for bogus in "relative/dir" "${CHOME}/dev/no-such-dir"; do
  setup_case; claim_setup
  RUN_CWD="${PROJ}"; claim_with_env "CLAUDE_PROJECT_DIR=${bogus}"
  if [[ "${RC}" == 3 && "${ERR}" == *"reason=project-unresolved "* && "${ERR}" == *"${bogus}"* && "${ERR}" == *"Fix:"* && -z "${OUT}" ]]; then
    ok "claim-thread: CLAUDE_PROJECT_DIR='${bogus##*/}' unusable -> reason=project-unresolved naming it, no fallback to the cwd"
  else bad "claim-thread: CLAUDE_PROJECT_DIR='${bogus##*/}' unusable -> reason=project-unresolved naming it, no fallback to the cwd" \
    "rc=${RC} out='${OUT}' err='${ERR}'"; fi
done
# k9. A subagent inherits its parent's CLAUDE_PID. With the parent parked in
#     wproj and the subagent dispatched into cproj, it is refused there (k4)
#     and claims for cproj only when it names cproj explicitly: the override
#     the refusal's Fix: prescribes.
setup_case; claim_setup; claim_other_project wproj yes
( cd "${OPROJ}" && exec tail -f /dev/null ) & STANDIN=$!
RUN_CWD="${PROJ}"; claim_with_env "CLAUDE_PID=${STANDIN}" "CLAUDE_PROJECT_DIR=${PROJ}"
kill "${STANDIN}" 2>/dev/null; wait "${STANDIN}" 2>/dev/null || true  # 143: killed, as intended (run_bin leaves set -e on)
if [[ "${RC}" == 0 && "${OUT}" == "claim=claimed inbox=cproj-slack.jsonl source=project-dir" ]]; then
  ok "claim-thread: an explicit CLAUDE_PROJECT_DIR outranks an inherited CLAUDE_PID (the subagent override)"
else bad "claim-thread: an explicit CLAUDE_PROJECT_DIR outranks an inherited CLAUDE_PID (the subagent override)" "rc=${RC} out='${OUT}' err='${ERR}'"; fi

# k10. The registry cannot say which entry is the session's (two entries claim
#      it): registry-error, never a guess and never the cwd's.
setup_case; claim_setup; claim_other_project wproj yes
cp "${CHOME}/inbox-root/projects/wproj.json" "${CHOME}/inbox-root/projects/wproj-dup.json"
RUN_CWD="${PROJ}"; claim_with_env "CLAUDE_PROJECT_DIR=${OPROJ}"
if [[ "${RC}" == 3 && "${ERR}" == *"reason=registry-error "* && -z "${OUT}" && -z "$(mcp_calls)" ]]; then
  ok "claim-thread: an ambiguous registry for the session's project -> reason=registry-error, no call"
else bad "claim-thread: an ambiguous registry for the session's project -> reason=registry-error, no call" "rc=${RC} out='${OUT}' err='${ERR}'"; fi

setup_case; claim_setup
RUN_CWD="${PROJ}"; claim_with_env "CLAUDE_PID=not-a-pid"
if [[ "${RC}" == 3 && "${ERR}" == *"reason=project-unresolved "* && "${ERR}" == *"not-a-pid"* && -z "${OUT}" ]]; then
  ok "claim-thread: CLAUDE_PID not a pid -> reason=project-unresolved, no fallback to the cwd"
else bad "claim-thread: CLAUDE_PID not a pid -> reason=project-unresolved, no fallback to the cwd" "rc=${RC} out='${OUT}' err='${ERR}'"; fi

# p1. post: the ts line, then the claim; exit 0.
setup_case; claim_setup
fixture chat.postMessage "{\"ok\":true,\"ts\":\"1790000000.000100\",\"channel\":\"${ENG_CHANNEL}\"}"
run_bin post "${ENG_CHANNEL}" "hi"
if [[ "${RC}" == 0 && "$(head -n1 <<<"${OUT}")" == "ts=1790000000.000100 channel=${ENG_CHANNEL}" && "$(tail -n1 <<<"${OUT}")" == "claim=claimed inbox=cproj-slack.jsonl source=cwd" ]] \
   && [[ "$(jq -r '.channel + " " + .thread_ts' <<<"$(claim_args)")" == "${ENG_CHANNEL} 1790000000.000100" ]]; then
  ok "post: prints the ts line, then claims that (channel, ts): claim=claimed, exit 0"
else bad "post: prints the ts line, then claims that (channel, ts): claim=claimed, exit 0" "rc=${RC} out='${OUT}' err='${ERR}' args=$(claim_args)"; fi

# p2. A failed claim never undoes or repeats the post: exit 3, one post.
setup_case; claim_setup; claim_err_answer "not found"
fixture chat.postMessage "{\"ok\":true,\"ts\":\"1.1\",\"channel\":\"${ENG_CHANNEL}\"}"
run_bin post "${ENG_CHANNEL}" "hi"
if [[ "${RC}" == 3 && "$(head -n1 <<<"${OUT}")" == "ts=1.1 channel=${ENG_CHANNEL}" && "${ERR}" == *"claim=FAILED reason=not-found"* ]] \
   && [[ "$(calls_of chat.postMessage)" == 1 && "${OUT}" != *"claim="* ]]; then
  ok "post: a failed claim -> ts line printed, claim=FAILED on stderr, exit 3, posted exactly once"
else bad "post: a failed claim -> ts line printed, claim=FAILED on stderr, exit 3, posted exactly once" \
  "rc=${RC} out='${OUT}' err='${ERR}' posts=$(calls_of chat.postMessage)"; fi

# p3. dm without --thread_ts starts a thread: claims (channel from
#     conversations.open, ts from chat.postMessage).
setup_case; claim_setup
fixture conversations.open '{"ok":true,"channel":{"id":"D0PENED"}}'
fixture chat.postMessage '{"ok":true,"ts":"1790.5","channel":"D0PENED"}'
run_bin dm "${CODY}" "hi"
if [[ "${RC}" == 0 && "$(tail -n1 <<<"${OUT}")" == "claim=claimed inbox=cproj-slack.jsonl source=cwd" ]] \
   && [[ "$(jq -r '.channel + " " + .thread_ts' <<<"$(claim_args)")" == "D0PENED 1790.5" ]]; then
  ok "dm: a new DM claims (D... from conversations.open, ts from the post)"
else bad "dm: a new DM claims (D... from conversations.open, ts from the post)" "rc=${RC} out='${OUT}' err='${ERR}' args=$(claim_args)"; fi

# p4. DND-1521: dm --thread_ts replies into an existing thread and claims it
#     only if unclaimed: the key is the PARENT ts, never the reply's own ts.
setup_case; claim_setup
fixture conversations.open '{"ok":true,"channel":{"id":"D0PENED"}}'
fixture chat.postMessage '{"ok":true,"ts":"1790.6","channel":"D0PENED"}'
run_bin dm "${CODY}" "hi" --thread_ts 1790.5
if [[ "${RC}" == 0 && "$(tail -n1 <<<"${OUT}")" == "claim=claimed inbox=cproj-slack.jsonl source=cwd" ]] \
   && [[ "$(jq -r '.channel + " " + .thread_ts' <<<"$(claim_args)")" == "D0PENED 1790.5" ]]; then
  ok "dm --thread_ts: claims the parent thread (D0PENED 1790.5), claim=claimed, exit 0"
else bad "dm --thread_ts: claims the parent thread (D0PENED 1790.5), claim=claimed, exit 0" "rc=${RC} out='${OUT}' err='${ERR}' args=$(claim_args)"; fi

# p5. DND-1521: reply claims an unclaimed thread for this session's inbox.
#     Measured 2026-10-01: a session answered an owner thread with reply,
#     nothing claimed it, and the owner's next reply went by channel_route to
#     another session. The claim key is (resolved channel, PARENT ts).
setup_case; claim_setup
fixture chat.postMessage "{\"ok\":true,\"ts\":\"1790.7\",\"channel\":\"${ENG_CHANNEL}\"}"
run_bin reply "${ENG_CHANNEL}" 1790.5 "threaded"
if [[ "${RC}" == 0 && "$(head -n1 <<<"${OUT}")" == "ts=1790.7 channel=${ENG_CHANNEL} thread_ts=1790.5" ]] \
   && [[ "$(tail -n1 <<<"${OUT}")" == "claim=claimed inbox=cproj-slack.jsonl source=cwd" ]] \
   && [[ "$(jq -r '.channel + " " + .thread_ts + " " + .inbox_name' <<<"$(claim_args)")" == "${ENG_CHANNEL} 1790.5 cproj-slack.jsonl" ]]; then
  ok "reply: claims the unclaimed parent thread (channel, thread_ts) for this inbox, exit 0"
else bad "reply: claims the unclaimed parent thread (channel, thread_ts) for this inbox, exit 0" "rc=${RC} out='${OUT}' err='${ERR}' args=$(claim_args)"; fi

# p5b. A thread another inbox holds stays theirs: an outcome on stdout, never a
#      failure, and the reply is posted exactly once.
setup_case; claim_setup; claim_err_answer "already_claimed: another inbox holds this thread"
fixture chat.postMessage "{\"ok\":true,\"ts\":\"1790.8\",\"channel\":\"${ENG_CHANNEL}\"}"
run_bin reply "${ENG_CHANNEL}" 1790.5 "threaded"
if [[ "${RC}" == 0 && "$(tail -n1 <<<"${OUT}")" == "claim=already_claimed holder=another-inbox inbox=cproj-slack.jsonl source=cwd" ]] \
   && [[ "${ERR}" != *"claim=FAILED"* && "$(calls_of chat.postMessage)" == 1 ]]; then
  ok "reply: a thread another inbox holds -> claim=already_claimed holder=another-inbox, exit 0, posted once"
else bad "reply: a thread another inbox holds -> claim=already_claimed holder=another-inbox, exit 0, posted once" \
  "rc=${RC} out='${OUT}' err='${ERR}' posts=$(calls_of chat.postMessage)"; fi

# p5c. A reply into the session's own thread: already_yours, exit 0.
setup_case; claim_setup; claim_ok_answer already_yours
fixture chat.postMessage "{\"ok\":true,\"ts\":\"1790.9\",\"channel\":\"${ENG_CHANNEL}\"}"
run_bin reply "${ENG_CHANNEL}" 1790.5 "threaded"
if [[ "${RC}" == 0 && "$(tail -n1 <<<"${OUT}")" == "claim=already_yours inbox=cproj-slack.jsonl source=cwd" ]]; then
  ok "reply: the session's own thread -> claim=already_yours, exit 0"
else bad "reply: the session's own thread -> claim=already_yours, exit 0" "rc=${RC} out='${OUT}' err='${ERR}'"; fi

# p5d. A failed claim never fails the reply (the post happened): claim=FAILED
#      and Fix: on stderr, exit 0, posted exactly once.
setup_case; claim_setup; claim_err_answer "not found"
fixture chat.postMessage "{\"ok\":true,\"ts\":\"1790.10\",\"channel\":\"${ENG_CHANNEL}\"}"
run_bin reply "${ENG_CHANNEL}" 1790.5 "threaded"
if [[ "${RC}" == 0 && "$(head -n1 <<<"${OUT}")" == "ts=1790.10 channel=${ENG_CHANNEL} thread_ts=1790.5" ]] \
   && [[ "${ERR}" == *"claim=FAILED reason=not-found"* && "${ERR}" == *"Fix:"* && "${OUT}" != *"claim="* ]] \
   && [[ "$(calls_of chat.postMessage)" == 1 ]]; then
  ok "reply: a failed claim -> claim=FAILED + Fix: on stderr, exit 0 (the reply is posted), posted once"
else bad "reply: a failed claim -> claim=FAILED + Fix: on stderr, exit 0 (the reply is posted), posted once" \
  "rc=${RC} out='${OUT}' err='${ERR}' posts=$(calls_of chat.postMessage)"; fi

# p5e. reply --no-claim (either position): claim=skipped, no MCP call.
for args in "--no-claim ${ENG_CHANNEL} 1790.5 threaded" "${ENG_CHANNEL} 1790.5 threaded --no-claim"; do
  setup_case; claim_setup
  fixture chat.postMessage "{\"ok\":true,\"ts\":\"1790.11\",\"channel\":\"${ENG_CHANNEL}\"}"
  # shellcheck disable=SC2086
  run_bin reply ${args}
  if [[ "${RC}" == 0 && "$(tail -n1 <<<"${OUT}")" == "claim=skipped" && -z "$(mcp_calls)" && "$(calls_of chat.postMessage)" == 1 ]]; then
    ok "reply '${args}': claim=skipped, no MCP call, exit 0"
  else bad "reply '${args}': claim=skipped, no MCP call, exit 0" "rc=${RC} out='${OUT}' err='${ERR}' calls=$(mcp_calls)"; fi
done

# p5l. DND-1605: the note a forwarder posts when it forwards a misrouted
#      conversation never claims the thread. `--reroute-of <event_id>` (the
#      event_id it passed to session_send as reroute_of_event_id) implies no
#      claim, in either position: claim=skipped, no MCP call, posted once.
#      Claiming it would route the owner's follow-ups to the forwarder.
for args in "--reroute-of EVFAKE00001 ${ENG_CHANNEL} 1790.5 forwarded" "${ENG_CHANNEL} 1790.5 forwarded --reroute-of EVFAKE00001" \
            "${ENG_CHANNEL} 1790.5 forwarded --no-claim --reroute-of EVFAKE00001"; do
  setup_case; claim_setup
  fixture chat.postMessage "{\"ok\":true,\"ts\":\"1790.17\",\"channel\":\"${ENG_CHANNEL}\"}"
  # shellcheck disable=SC2086
  run_bin reply ${args}
  if [[ "${RC}" == 0 && "$(tail -n1 <<<"${OUT}")" == "claim=skipped" && -z "$(mcp_calls)" && "$(calls_of chat.postMessage)" == 1 ]]; then
    ok "reply '${args}' (a forward note): claim=skipped, no MCP call, exit 0"
  else bad "reply '${args}' (a forward note): claim=skipped, no MCP call, exit 0" "rc=${RC} out='${OUT}' err='${ERR}' calls=$(mcp_calls)"; fi
done
# p5m. --reroute-of with no event_id (or an empty one) is a usage error, exit 2,
#      nothing posted or claimed: a forward note must name what it forwarded.
for form in "missing" "empty" "flag"; do
  setup_case; claim_setup
  case "${form}" in
    missing) run_bin reply "${ENG_CHANNEL}" 1790.5 forwarded --reroute-of ;;
    empty) run_bin reply "${ENG_CHANNEL}" 1790.5 forwarded --reroute-of "" ;;
    flag) run_bin reply "${ENG_CHANNEL}" 1790.5 forwarded --reroute-of --no-claim ;;
  esac
  if [[ "${RC}" == 2 && "${ERR}" == *"--reroute-of"* && "${ERR}" == *"Fix:"* && "$(calls_of chat.postMessage)" == 0 && -z "$(mcp_calls)" ]]; then
    ok "reply --reroute-of (${form} event_id): usage with Fix:, exit 2, nothing posted or claimed"
  else bad "reply --reroute-of (${form} event_id): usage with Fix:, exit 2, nothing posted or claimed" "rc=${RC} err='${ERR}' posts=$(calls_of chat.postMessage)"; fi
done

# p5i. Slack's own message.thread_ts wins over the argument: a reply's ts
#      passed by mistake never gets a different thread claimed for good.
setup_case; claim_setup
fixture chat.postMessage "{\"ok\":true,\"ts\":\"1790.14\",\"channel\":\"${ENG_CHANNEL}\",\"message\":{\"ts\":\"1790.14\",\"thread_ts\":\"1790.1\"}}"
run_bin reply "${ENG_CHANNEL}" 1790.5 "threaded"
if [[ "${RC}" == 0 && "$(jq -r '.channel + " " + .thread_ts' <<<"$(claim_args)")" == "${ENG_CHANNEL} 1790.1" ]]; then
  ok "reply: claims the response's message.thread_ts (1790.1), not the argument (1790.5)"
else bad "reply: claims the response's message.thread_ts (1790.1), not the argument (1790.5)" "rc=${RC} out='${OUT}' args=$(claim_args)"; fi
setup_case; claim_setup
fixture conversations.open '{"ok":true,"channel":{"id":"D0PENED"}}'
fixture chat.postMessage '{"ok":true,"ts":"1790.15","channel":"D0PENED","message":{"ts":"1790.15","thread_ts":"1790.1"}}'
run_bin dm "${CODY}" "hi" --thread_ts 1790.5
if [[ "${RC}" == 0 && "$(jq -r '.channel + " " + .thread_ts' <<<"$(claim_args)")" == "D0PENED 1790.1" ]]; then
  ok "dm --thread_ts: claims the response's message.thread_ts, not the argument"
else bad "dm --thread_ts: claims the response's message.thread_ts, not the argument" "rc=${RC} out='${OUT}' args=$(claim_args)"; fi

# p5j. The reply parser: `--` text (alone and after a flag), stdin text, and a
#      #name channel all post and claim the resolved (channel, thread_ts).
for form in "dashdash" "flag-dashdash" "stdin" "name"; do
  setup_case; claim_setup
  fixture chat.postMessage "{\"ok\":true,\"ts\":\"1790.16\",\"channel\":\"${ENG_CHANNEL}\"}"
  case "${form}" in
    dashdash) run_bin reply "${ENG_CHANNEL}" 1790.5 -- "--looks-like-a-flag" ;;
    flag-dashdash) run_bin reply --broadcast "${ENG_CHANNEL}" 1790.5 -- "--looks-like-a-flag" ;;
    stdin) run_bin_stdin "from stdin" reply "${ENG_CHANNEL}" 1790.5 ;;
    name) run_bin reply '#eng-fixture' 1790.5 "hi" ;;  # resolved from the seeded channel cache
  esac
  if [[ "${RC}" == 0 && "$(calls_of chat.postMessage)" == 1 && "$(tail -n1 <<<"${OUT}")" == "claim=claimed inbox=cproj-slack.jsonl source=cwd" ]] \
     && [[ "$(jq -r '.channel + " " + .thread_ts' <<<"$(claim_args)")" == "${ENG_CHANNEL} 1790.5" ]]; then
    ok "reply parser (${form}): posts once, claims (${ENG_CHANNEL}, 1790.5)"
  else bad "reply parser (${form}): posts once, claims (${ENG_CHANNEL}, 1790.5)" "rc=${RC} out='${OUT}' err='${ERR}' args=$(claim_args)"; fi
done
# p5k. A 4th positional, or `--` before the thread_ts: usage, exit 2, nothing sent.
for args in "${ENG_CHANNEL} 1790.5 one two" "${ENG_CHANNEL} -- text"; do
  setup_case; claim_setup
  # shellcheck disable=SC2086
  run_bin reply ${args}
  if [[ "${RC}" == 2 && "${ERR}" == *"usage: reply"* && "$(calls_of chat.postMessage)" == 0 && -z "$(mcp_calls)" ]]; then
    ok "reply '${args}': usage, exit 2, nothing posted or claimed"
  else bad "reply '${args}': usage, exit 2, nothing posted or claimed" "rc=${RC} err='${ERR}'"; fi
done

# p5f. A failed reply post is the post's failure: exit 1, no claim attempted.
setup_case; claim_setup
fixture chat.postMessage '{"ok":false,"error":"thread_not_found"}'
run_bin reply "${ENG_CHANNEL}" 1790.5 "threaded"
if [[ "${RC}" == 1 && "${ERR}" == *"thread_not_found"* && -z "$(mcp_calls)" && "${ERR}" != *"claim="* ]]; then
  ok "reply: a failed post exits 1, and no claim is attempted"
else bad "reply: a failed post exits 1, and no claim is attempted" "rc=${RC} err='${ERR}' calls=$(mcp_calls)"; fi

# p5g. dm --thread_ts into a thread another inbox holds: already_claimed, exit 0.
setup_case; claim_setup; claim_err_answer "already_claimed: another inbox holds this thread"
fixture conversations.open '{"ok":true,"channel":{"id":"D0PENED"}}'
fixture chat.postMessage '{"ok":true,"ts":"1790.12","channel":"D0PENED"}'
run_bin dm "${CODY}" "hi" --thread_ts 1790.5
if [[ "${RC}" == 0 && "$(tail -n1 <<<"${OUT}")" == "claim=already_claimed holder=another-inbox inbox=cproj-slack.jsonl source=cwd" ]]; then
  ok "dm --thread_ts: a thread another inbox holds -> claim=already_claimed, exit 0"
else bad "dm --thread_ts: a thread another inbox holds -> claim=already_claimed, exit 0" "rc=${RC} out='${OUT}' err='${ERR}'"; fi

# p5h. A new DM (no --thread_ts) is unchanged: another holder of a thread it
#      just started is still a failure, exit 3 (its claim is the return address).
setup_case; claim_setup; claim_err_answer "already_claimed: another inbox holds this thread"
fixture conversations.open '{"ok":true,"channel":{"id":"D0PENED"}}'
fixture chat.postMessage '{"ok":true,"ts":"1790.13","channel":"D0PENED"}'
run_bin dm "${CODY}" "hi"
if [[ "${RC}" == 3 && "${ERR}" == *"claim=FAILED reason=already-claimed"* ]]; then
  ok "dm (new thread): already_claimed is still claim=FAILED, exit 3"
else bad "dm (new thread): already_claimed is still claim=FAILED, exit 3" "rc=${RC} out='${OUT}' err='${ERR}'"; fi

# p6. --no-claim: claim=skipped, no MCP call, on post and dm.
setup_case; claim_setup
fixture chat.postMessage "{\"ok\":true,\"ts\":\"1.1\",\"channel\":\"${ENG_CHANNEL}\"}"
run_bin post "${ENG_CHANNEL}" "hi" --no-claim
if [[ "${RC}" == 0 && "$(tail -n1 <<<"${OUT}")" == "claim=skipped" && -z "$(mcp_calls)" ]]; then
  ok "post --no-claim: claim=skipped, no MCP call, exit 0"
else bad "post --no-claim: claim=skipped, no MCP call, exit 0" "rc=${RC} out='${OUT}' calls=$(mcp_calls)"; fi
setup_case; claim_setup
fixture conversations.open '{"ok":true,"channel":{"id":"D0PENED"}}'
fixture chat.postMessage '{"ok":true,"ts":"1790.6","channel":"D0PENED"}'
run_bin dm "${CODY}" "hi" --no-claim
if [[ "${RC}" == 0 && "$(tail -n1 <<<"${OUT}")" == "claim=skipped" && -z "$(mcp_calls)" ]]; then
  ok "dm --no-claim: claim=skipped, no MCP call, exit 0"
else bad "dm --no-claim: claim=skipped, no MCP call, exit 0" "rc=${RC} out='${OUT}' calls=$(mcp_calls)"; fi

# p7. A failed post is the post's failure, as before: no claim is attempted.
setup_case; claim_setup
fixture chat.postMessage '{"ok":false,"error":"channel_not_found"}'
run_bin post "${ENG_CHANNEL}" "hi"
if [[ "${RC}" == 1 && "${ERR}" == *"channel_not_found"* && -z "$(mcp_calls)" && "${ERR}" != *"claim="* ]]; then
  ok "post: a failed post exits 1 as before, and no claim is attempted"
else bad "post: a failed post exits 1 as before, and no claim is attempted" "rc=${RC} err='${ERR}' calls=$(mcp_calls)"; fi

# p8. No registry entry for the cwd: posted once, exit 3 reason=no-registry-entry.
setup_case; claim_setup; RUN_CWD="${TMP}"
fixture chat.postMessage "{\"ok\":true,\"ts\":\"1.1\",\"channel\":\"${ENG_CHANNEL}\"}"
run_bin post "${ENG_CHANNEL}" "hi"
if [[ "${RC}" == 3 && "${ERR}" == *"reason=no-registry-entry "*"inbox=none"* && "$(calls_of chat.postMessage)" == 1 && -z "$(mcp_calls)" ]]; then
  ok "post: cwd with no registry entry -> posted once, exit 3 reason=no-registry-entry inbox=none"
else bad "post: cwd with no registry entry -> posted once, exit 3 reason=no-registry-entry inbox=none" \
  "rc=${RC} err='${ERR}' posts=$(calls_of chat.postMessage)"; fi
RUN_CWD=""

# p9. DND-491 fix round (critic finding): the ONE untested branch in
#     slack_claim_started_thread -- claim-thread crashing or exiting a code it
#     never documents (not 0, 2, or 3). Without this branch, post/dm would
#     exit 3 with nothing printed at all, which is exactly the silent failure
#     the header says the branch prevents. A separate bin dir stands in for
#     the real one, with claim-thread replaced by a stub that exits 1, so
#     slack_claim_started_thread's `"$1/claim-thread"` call reaches the stub.
setup_case; claim_setup
ALTROOT="${TMP}/p9altroot${CASE_N}"; ALTBIN="${ALTROOT}/bin"; mkdir -p "${ALTBIN}"
ln -s "${ROOT}/lib" "${ALTROOT}/lib"
cp "${BIN}/post" "${ALTBIN}/post"
cat > "${ALTBIN}/claim-thread" <<'STUBEOF'
#!/usr/bin/env bash
exit 1
STUBEOF
chmod +x "${ALTBIN}/claim-thread"
fixture chat.postMessage "{\"ok\":true,\"ts\":\"1.1\",\"channel\":\"${ENG_CHANNEL}\"}"
set +e
OUT="$(cd "${RUN_CWD:-${TMP}}" && env HOME="${CHOME}" PATH="${SHIMBIN}:${PATH}" SHIM_DIR="${SHIM_DIR}" \
  ATHENA_INBOX_ROOT="${CHOME}/inbox-root" ATHENA_INBOX_CLIENT_CONFIG="${CHOME}/client.json" \
  SHIM_MCP_BEARER="${MCP_BEARER}" \
  SLACK_INBOX_STATE="${STATE}" SLACK_INBOX_LEGACY_STATE="${LEGACY}" \
  "${ALTBIN}/post" "${ENG_CHANNEL}" "hi" 2>"${TMP}/perr${CASE_N}")"
RC=$?
set -e
ERR="$(cat "${TMP}/perr${CASE_N}")"
if [[ "${RC}" == 3 ]] && [[ "$(head -n1 <<<"${OUT}")" == "ts=1.1 channel=${ENG_CHANNEL}" ]] \
   && [[ "${ERR}" == *"claim=FAILED reason=mcp-error:claim-thread-exit-1"* ]] && [[ "${ERR}" == *"Fix:"* ]] \
   && [[ "$(calls_of chat.postMessage)" == 1 ]]; then
  ok "post: claim-thread exiting an undocumented code (1) -> claim=FAILED reason=mcp-error:claim-thread-exit-1, Fix:, exit 3"
else bad "post: claim-thread exiting an undocumented code (1) -> claim=FAILED reason=mcp-error:claim-thread-exit-1, Fix:, exit 3" \
  "rc=${RC} out='${OUT}' err='${ERR}'"; fi

# p10. DND-1521: the same undocumented exit under reply is named, never silent,
#      and never fails the reply: claim=FAILED + Fix:, exit 0.
cp "${BIN}/reply" "${ALTBIN}/reply"
fixture chat.postMessage "{\"ok\":true,\"ts\":\"1.2\",\"channel\":\"${ENG_CHANNEL}\"}"
set +e
OUT="$(cd "${RUN_CWD:-${TMP}}" && env HOME="${CHOME}" PATH="${SHIMBIN}:${PATH}" SHIM_DIR="${SHIM_DIR}" \
  ATHENA_INBOX_ROOT="${CHOME}/inbox-root" ATHENA_INBOX_CLIENT_CONFIG="${CHOME}/client.json" \
  SHIM_MCP_BEARER="${MCP_BEARER}" \
  SLACK_INBOX_STATE="${STATE}" SLACK_INBOX_LEGACY_STATE="${LEGACY}" \
  "${ALTBIN}/reply" "${ENG_CHANNEL}" 1.1 "hi" 2>"${TMP}/rerr${CASE_N}")"
RC=$?
set -e
ERR="$(cat "${TMP}/rerr${CASE_N}")"
if [[ "${RC}" == 0 ]] && [[ "$(head -n1 <<<"${OUT}")" == "ts=1.2 channel=${ENG_CHANNEL} thread_ts=1.1" ]] \
   && [[ "${ERR}" == *"claim=FAILED reason=mcp-error:claim-thread-exit-1"* ]] && [[ "${ERR}" == *"Fix:"* ]]; then
  ok "reply: claim-thread exiting an undocumented code (1) -> claim=FAILED + Fix:, exit 0"
else bad "reply: claim-thread exiting an undocumented code (1) -> claim=FAILED + Fix:, exit 0" \
  "rc=${RC} out='${OUT}' err='${ERR}'"; fi

echo
echo "-- DND-1538: topic-route (slack_topic_route_list / slack_topic_route_put) ----"

# The fixture is claim_setup's: a project with the athena MCP registered, a
# machine token, cwd = the project. The bin needs no Slack inbox and no bot
# identity: the server derives the owner and the app from the machine token.
TR_LIB="${ROOT}/lib/topic_route.sh"
# tr_fn <fn> [args...] -- one topic_route.sh function in a fresh bash.
tr_fn() {
  set +e
  OUT="$(env TR_LIB="${TR_LIB}" bash -c '. "${TR_LIB}"; "$@"' tr_fn "$@" 2>"${TMP}/trerr${CASE_N}")"
  RC=$?
  set -e
  ERR="$(cat "${TMP}/trerr${CASE_N}")"
}
tr_text_answer() { # tr_text_answer <tool> <reply-json>  (a Response.json-style text content)
  mcp_answer "$1" "$(jq -n -c --argjson r "$2" '{jsonrpc:"2.0", id:2, result:{isError:false, content:[{type:"text", text:($r|tojson)}]}}')"
}
tr_rpc_error() { # tr_rpc_error <tool> <message>  (Hermes Error.execution: a JSON-RPC error)
  mcp_answer "$1" "$(jq -n -c --arg m "$2" '{jsonrpc:"2.0", id:2, error:{code:-32000, message:$m, data:{}}}')"
}
tr_tool_error() { # tr_tool_error <tool> <text>  (an isError tool result)
  mcp_answer "$1" "$(jq -n -c --arg t "$2" '{jsonrpc:"2.0", id:2, result:{isError:true, content:[{type:"text", text:$t}]}}')"
}
tr_args() { cat "${SHIM_DIR}/mcp.args.$1.json" 2>/dev/null || true; }
TR_APP="AFAKEAPP01"
TR_TWO_ROUTES="$(jq -n -c --arg a "${TR_APP}" '{app_id:$a, count:2, routes:[
  {label:"harness", agent_instance_id:"inst-1", inbox_name:"custom-slack.jsonl", machine_id:"m-1", machine_name:"desktop", enabled:true, live:true},
  {label:"walt_ui", agent_instance_id:"inst-2", inbox_name:"walt_ui-slack.jsonl", machine_id:"m-2", machine_name:"laptop", enabled:false, live:false}]}')"
TR_PUT_OK="$(jq -n -c --arg a "${TR_APP}" '{status:"put", app_id:$a, label:"harness", agent_instance_id:"inst-1", inbox_name:"custom-slack.jsonl", machine_id:"m-1", enabled:true}')"
TR_REFUSED='refused: inst-9 is not a <project>-slack.jsonl instance on your machines. Fix: pick an agent_instance_id from list_my_machines.'

# t-u1. Domain: the arguments are exactly the fields the server takes. No
#       owner, machine_id or slack_app_id ever (the server refuses them).
setup_case
tr_fn topic_route_put_args harness inst-1 true ""
if [[ "${OUT}" == '{"label":"harness","agent_instance_id":"inst-1","enabled":true}' ]]; then
  ok "topic_route_put_args: label/agent_instance_id/enabled, no bot_id when none given"
else bad "topic_route_put_args: label/agent_instance_id/enabled, no bot_id when none given" "got '${OUT}' rc=${RC}"; fi
tr_fn topic_route_put_args harness inst-1 false B0BOTFIX01
if [[ "${OUT}" == '{"label":"harness","agent_instance_id":"inst-1","enabled":false,"bot_id":"B0BOTFIX01"}' ]]; then
  ok "topic_route_put_args: enabled false is a JSON boolean, bot_id passed when given"
else bad "topic_route_put_args: enabled false is a JSON boolean, bot_id passed when given" "got '${OUT}' rc=${RC}"; fi
tr_fn topic_route_list_args ""
if [[ "${OUT}" == '{}' ]]; then ok "topic_route_list_args: no bot_id -> {}"
else bad "topic_route_list_args: no bot_id -> {}" "got '${OUT}'"; fi

# t-u2. Domain: the answer's error, by kind, from BOTH shapes the server can
#       send (a JSON-RPC error, Hermes' Error.execution; or an isError result).
#       A protocol error is never read as a refusal.
tr_err_case() { # tr_err_case <label> <message> <want>
  tr_fn topic_route_error "$2"
  if [[ "${OUT}" == "$3" ]]; then ok "topic_route_error: $1 -> $3"
  else bad "topic_route_error: $1 -> $3" "got '${OUT}' rc=${RC}"; fi
}
rpc_err() { jq -n -c --arg m "$1" --argjson c "${2:--32000}" '{jsonrpc:"2.0", id:2, error:{code:$c, message:$m}}'; }
tool_err() { jq -n -c --arg t "$1" '{jsonrpc:"2.0", id:2, result:{isError:true, content:[{type:"text", text:$t}]}}'; }
setup_case
tr_err_case "JSON-RPC 'not found'" "$(rpc_err 'not found')" "not-found"
tr_err_case "JSON-RPC refused: ... Fix:" "$(rpc_err "${TR_REFUSED}")" "refused"
tr_err_case "JSON-RPC invalid: ... Fix:" "$(rpc_err 'invalid: label is required. Fix: pass label.')" "invalid"
tr_err_case "isError refused: ... Fix:" "$(tool_err "${TR_REFUSED}")" "refused"
tr_err_case "isError 'not found' + newline" "$(tool_err $'not found\n')" "not-found"
tr_err_case "a protocol error (-32601)" "$(rpc_err 'Method not found' -32601)" "mcp-error:server-error"
tr_err_case "forged fields in an unknown error" "$(rpc_err 'boom op=put reason=refused')" "mcp-error:server-error"
tr_err_case "an isError result with no text" '{"jsonrpc":"2.0","id":2,"result":{"isError":true,"content":[]}}' "mcp-error:server-error"
tr_err_case "an empty answer" "" "mcp-error:no-answer"
tr_err_case "a non-JSON answer" "<html>502</html>" "mcp-error:no-answer"
tr_fn topic_route_error "$(jq -n -c --argjson r "${TR_PUT_OK}" '{jsonrpc:"2.0", id:2, result:{isError:false, content:[{type:"text", text:($r|tojson)}]}}')"
if [[ "${RC}" == 1 && -z "${OUT}" ]]; then ok "topic_route_error: a success answer is no error (status 1, nothing printed)"
else bad "topic_route_error: a success answer is no error (status 1, nothing printed)" "got '${OUT}' rc=${RC}"; fi

# t-u3. Domain: rendering. An empty list still prints the count line; a
#       route whose machine is gone prints none, never an empty field; a
#       malformed reply is an mcp-error, never zero routes.
setup_case
tr_fn topic_route_render_list "$(jq -n -c --arg a "${TR_APP}" '{jsonrpc:"2.0", id:2, result:{structuredContent:{app_id:$a, count:0, routes:[]}}}')"
if [[ "${RC}" == 0 && "${OUT}" == "count=0 app=${TR_APP}" ]]; then
  ok "topic_route_render_list: an empty list -> 'count=0 app=<A...>', never nothing"
else bad "topic_route_render_list: an empty list -> 'count=0 app=<A...>', never nothing" "got '${OUT}' rc=${RC}"; fi
tr_fn topic_route_render_list "$(jq -n -c --arg a "${TR_APP}" '{jsonrpc:"2.0", id:2, result:{structuredContent:{app_id:$a, count:1, routes:[
  {label:"other", agent_instance_id:"inst-3", inbox_name:null, machine_id:null, machine_name:null, enabled:true, live:false}]}}}')"
if [[ "${RC}" == 0 && "$(head -n1 <<<"${OUT}")" == "label=other inbox=none machine=none name=none enabled=true live=false instance=inst-3" ]]; then
  ok "topic_route_render_list: a route with no machine -> inbox=none machine=none"
else bad "topic_route_render_list: a route with no machine -> inbox=none machine=none" "got '${OUT}' rc=${RC}"; fi
for bad_reply in '{"count":0,"routes":[]}' "{\"app_id\":\"${TR_APP}\",\"count\":2,\"routes\":[]}" \
                 "{\"app_id\":\"${TR_APP}\",\"count\":1,\"routes\":[{\"label\":\"x\"}]}" '"just a string"'; do
  tr_fn topic_route_render_list "$(jq -n -c --argjson r "${bad_reply}" '{jsonrpc:"2.0", id:2, result:{isError:false, content:[{type:"text", text:($r|tojson)}]}}')"
  if [[ "${RC}" == 1 && "${OUT}" == mcp-error:* ]]; then
    ok "topic_route_render_list: malformed reply ${bad_reply:0:40} -> mcp-error, never a route count"
  else bad "topic_route_render_list: malformed reply ${bad_reply:0:40} -> mcp-error, never a route count" "got '${OUT}' rc=${RC}"; fi
done
tr_fn topic_route_render_list "$(jq -n -c --arg a "${TR_APP}" '{jsonrpc:"2.0", id:2, result:{structuredContent:{app_id:$a, count:1, routes:[
  {label:"harness\nlabel=forged", agent_instance_id:"inst 1", inbox_name:"x.jsonl", machine_id:"m", machine_name:"my desk\u202e\u009b", enabled:true, live:true}]}}}')"
if [[ "${RC}" == 0 && "$(wc -l <<<"${OUT}")" -eq 2 && "$(head -n1 <<<"${OUT}")" == "label=harness_label_forged inbox=x.jsonl machine=m name=\"my desk_____\" enabled=true live=true instance=inst_1" ]]; then
  ok "topic_route_render_list: server whitespace, '=', newlines, bidi and C1 controls cannot forge a field or a line"
else bad "topic_route_render_list: server whitespace, '=', newlines, bidi and C1 controls cannot forge a field or a line" "got '${OUT}' rc=${RC}"; fi

# t-u3b. DND-1568: the machine a list line prints is an ADDRESS another tool
#        accepts. machine= is the machine id and name= the real name, quoted
#        (names carry spaces). Both resolve through the lookup send-mail
#        --to-project <project>@<machine> uses (routed_pick_machine). The old
#        machine=Fake_Desktop matched no machine.
setup_case
TR_SPACE_REPLY="$(jq -n -c --arg a "${TR_APP}" '{jsonrpc:"2.0", id:2, result:{structuredContent:{app_id:$a, count:1, routes:[
  {label:"harness", agent_instance_id:"inst-1", inbox_name:"custom-slack.jsonl", machine_id:"m-fake-1", machine_name:"Fake Desktop", enabled:true, live:true}]}}}')"
tr_fn topic_route_render_list "${TR_SPACE_REPLY}"
TR_LINE="$(head -n1 <<<"${OUT}")"
TR_MACHINES='[{"id":"m-fake-1","name":"Fake Desktop","instances":[{"inbox_name":"custom-session.jsonl"}]},{"id":"m-fake-2","name":"Fake Laptop","instances":[{"inbox_name":"custom-session.jsonl"}]}]'
TR_ID="$(sed -n 's/.* machine=\([^ ]*\) .*/\1/p' <<<"${TR_LINE}")"
TR_NAME_Q="$(sed -n 's/.* name=\("[^"]*"\) .*/\1/p' <<<"${TR_LINE}")"
TR_NAME="$(jq -r '.' <<<"${TR_NAME_Q:-null}" 2>/dev/null)"
pick() { env INBOX_LIB_DIR="${ROOT}/../athena:inbox/lib" bash -c '. "${INBOX_LIB_DIR}/err.sh"; . "${INBOX_LIB_DIR}/routed.sh"; routed_pick_machine "$@"' pick "$@" 2>&1; }
if [[ "${TR_LINE}" == 'label=harness inbox=custom-slack.jsonl machine=m-fake-1 name="Fake Desktop" enabled=true live=true instance=inst-1' \
   && "$(pick "${TR_MACHINES}" custom-session.jsonl "${TR_ID}")" == "m-fake-1" \
   && "$(pick "${TR_MACHINES}" custom-session.jsonl "${TR_NAME}")" == "m-fake-1" ]]; then
  ok "topic_route_render_list: machine=<id> name=\"<real name>\" both resolve through send-mail's routed_pick_machine"
else bad "topic_route_render_list: machine=<id> name=\"<real name>\" both resolve through send-mail's routed_pick_machine" \
  "line='${TR_LINE}' id='${TR_ID}' name='${TR_NAME}' pick-id='$(pick "${TR_MACHINES}" custom-session.jsonl "${TR_ID}")'"; fi
# A name with a quote, a backslash and a forged field stays inside its quotes.
tr_fn topic_route_render_list "$(jq -n -c --arg a "${TR_APP}" '{jsonrpc:"2.0", id:2, result:{structuredContent:{app_id:$a, count:1, routes:[
  {label:"harness", agent_instance_id:"i", inbox_name:"x.jsonl", machine_id:"m-fake-1", machine_name:"a\" enabled=false \\ b\n", enabled:true, live:true}]}}}')"
if [[ "${RC}" == 0 && "$(wc -l <<<"${OUT}")" -eq 2 && "$(head -n1 <<<"${OUT}")" == 'label=harness inbox=x.jsonl machine=m-fake-1 name="a\" enabled=false \\ b" enabled=true live=true instance=i' ]]; then
  ok "topic_route_render_list: a name with a quote, backslash, newline cannot forge a field"
else bad "topic_route_render_list: a name with a quote, backslash, newline cannot forge a field" "got '${OUT}' rc=${RC}"; fi

# t-u4. Domain: every reason has its own Fix text.
setup_case
FIXES=""
for r in usage no-token mcp-unregistered mcp-error:x not-found refused invalid project-unresolved; do
  tr_fn topic_route_fix "${r}"
  if [[ -z "${OUT}" ]]; then bad "topic_route_fix: ${r} has a Fix text" "empty"; continue; fi
  FIXES="${FIXES}${OUT}"$'\n'
done
if [[ "$(printf '%s' "${FIXES}" | sort | uniq -d | wc -l)" -eq 0 && "$(printf '%s' "${FIXES}" | grep -c .)" -eq 8 ]]; then
  ok "topic_route_fix: all 8 reasons have a non-empty, distinct Fix text"
else bad "topic_route_fix: all 8 reasons have a non-empty, distinct Fix text" "$(printf '%s' "${FIXES}" | sort | uniq -c | sort -rn | head -3)"; fi

# Q1. list, two routes: one line each, then the count line; one tools/call.
setup_case; claim_setup; tr_text_answer slack_topic_route_list "${TR_TWO_ROUTES}"
run_bin topic-route list
WANT="label=harness inbox=custom-slack.jsonl machine=m-1 name=\"desktop\" enabled=true live=true instance=inst-1
label=walt_ui inbox=walt_ui-slack.jsonl machine=m-2 name=\"laptop\" enabled=false live=false instance=inst-2
count=2 app=${TR_APP}"
if [[ "${RC}" == 0 && "${OUT}" == "${WANT}" && "$(tr_args slack_topic_route_list)" == '{}' ]] \
   && [[ "$(mcp_calls | tr '\n' '|')" == "initialize|initialized|tools/call slack_topic_route_list|" ]]; then
  ok "topic-route list: two routes -> two label= lines and count=2 app=..., exit 0, arguments {}"
else bad "topic-route list: two routes -> two label= lines and count=2 app=..., exit 0, arguments {}" \
  "rc=${RC} out='${OUT}' err='${ERR}' args=$(tr_args slack_topic_route_list) calls=$(mcp_calls | tr '\n' '|')"; fi

# Q1b. list --bot-id passes the bot id and nothing else.
setup_case; claim_setup; tr_text_answer slack_topic_route_list "${TR_TWO_ROUTES}"
run_bin topic-route --bot-id B0BOTFIX01 list
if [[ "${RC}" == 0 && "$(tr_args slack_topic_route_list)" == '{"bot_id":"B0BOTFIX01"}' ]]; then
  ok "topic-route list --bot-id (flag first): arguments are exactly {bot_id}"
else bad "topic-route list --bot-id (flag first): arguments are exactly {bot_id}" "rc=${RC} err='${ERR}' args=$(tr_args slack_topic_route_list)"; fi

# Q1c. An empty list prints the count line, exit 0.
setup_case; claim_setup; tr_text_answer slack_topic_route_list "{\"app_id\":\"${TR_APP}\",\"count\":0,\"routes\":[]}"
run_bin topic-route list
if [[ "${RC}" == 0 && "${OUT}" == "count=0 app=${TR_APP}" ]]; then
  ok "topic-route list: no routes -> 'count=0 app=<A...>', exit 0"
else bad "topic-route list: no routes -> 'count=0 app=<A...>', exit 0" "rc=${RC} out='${OUT}' err='${ERR}'"; fi

# Q2. put ok.
setup_case; claim_setup; tr_text_answer slack_topic_route_put "${TR_PUT_OK}"
run_bin topic-route put harness inst-1
if [[ "${RC}" == 0 && "${OUT}" == "put label=harness inbox=custom-slack.jsonl enabled=true" ]] \
   && [[ "$(tr_args slack_topic_route_put)" == '{"label":"harness","agent_instance_id":"inst-1","enabled":true}' ]]; then
  ok "topic-route put: ok -> 'put label=harness inbox=custom-slack.jsonl enabled=true', exit 0, exact arguments"
else bad "topic-route put: ok -> 'put label=harness inbox=custom-slack.jsonl enabled=true', exit 0, exact arguments" \
  "rc=${RC} out='${OUT}' err='${ERR}' args=$(tr_args slack_topic_route_put)"; fi

# Q3. --disabled (in any position) sends enabled:false; --bot-id=B... form.
setup_case; claim_setup
tr_text_answer slack_topic_route_put "$(jq -c '.enabled = false' <<<"${TR_PUT_OK}")"
run_bin topic-route put --disabled harness --bot-id=B0BOTFIX01 inst-1
if [[ "${RC}" == 0 && "${OUT}" == "put label=harness inbox=custom-slack.jsonl enabled=false" ]] \
   && [[ "$(jq -c '.enabled, .bot_id' <<<"$(tr_args slack_topic_route_put)" | tr '\n' ' ')" == 'false "B0BOTFIX01" ' ]]; then
  ok "topic-route put --disabled: the request carries enabled:false (flags in any position)"
else bad "topic-route put --disabled: the request carries enabled:false (flags in any position)" \
  "rc=${RC} out='${OUT}' err='${ERR}' args=$(tr_args slack_topic_route_put)"; fi

# Q4. The server's refusal: its words (with their Fix:) on stderr, exit 3,
#     nothing on stdout. Both error shapes.
for shape in tr_rpc_error tr_tool_error; do
  setup_case; claim_setup; "${shape}" slack_topic_route_put "${TR_REFUSED}"
  run_bin topic-route put harness inst-9
  if [[ "${RC}" == 3 && -z "${OUT}" && "${ERR}" == *"topic-route=FAILED reason=refused op=put"* ]] \
     && [[ "${ERR}" == *"server: ${TR_REFUSED}"* && "$(grep -c '^Fix: ' <<<"${ERR}")" == 1 ]]; then
    ok "topic-route put: server refused (${shape}) -> the server's Fix on stderr, our Fix:, exit 3"
  else bad "topic-route put: server refused (${shape}) -> the server's Fix on stderr, our Fix:, exit 3" "rc=${RC} out='${OUT}' err='${ERR}'"; fi
done
setup_case; claim_setup; tr_rpc_error slack_topic_route_list "not found"
run_bin topic-route list --bot-id B0NOPE0001
if [[ "${RC}" == 3 && -z "${OUT}" && "${ERR}" == *"reason=not-found op=list"* && "${ERR}" == *"Fix:"* ]]; then
  ok "topic-route list: 'not found' -> reason=not-found, exit 3, no count line"
else bad "topic-route list: 'not found' -> reason=not-found, exit 3, no count line" "rc=${RC} out='${OUT}' err='${ERR}'"; fi

# Q5. Usage errors: exit 2, Fix:, and NO call at all.
tr_usage() { # tr_usage <label> <args...>
  local label="$1"; shift
  setup_case; claim_setup
  run_bin topic-route "$@"
  if [[ "${RC}" == 2 && -z "${OUT}" && "${ERR}" == *"reason=usage"* && "${ERR}" == *"Fix:"* && -z "$(mcp_calls)" ]]; then
    ok "topic-route: ${label} -> exit 2, Fix:, no call"
  else bad "topic-route: ${label} -> exit 2, Fix:, no call" "rc=${RC} out='${OUT}' err='${ERR}' calls=$(mcp_calls)"; fi
}
tr_usage "no subcommand"
tr_usage "an unknown subcommand" route harness inst-1
tr_usage "put with a missing label" put
tr_usage "put with a missing agent_instance_id" put harness
tr_usage "put with an empty label" put "" inst-1
tr_usage "put with a third positional" put harness inst-1 extra
tr_usage "list with a positional" list harness
tr_usage "list --disabled" list --disabled
tr_usage "--bot-id with no value" list --bot-id
tr_usage "a bot id that is not B..." list --bot-id U0NOTABOT
tr_usage "an unknown flag" put harness inst-1 --loud
tr_usage "an empty --bot-id" list --bot-id ""
tr_usage "an empty --bot-id=" list --bot-id=
tr_usage "--bot-id given twice" list --bot-id B0BOTFIX01 --bot-id B0BOTFIX02

# Q6. The machine token reaches curl only on stdin: never in any child's
#     argv, and no file left behind.
setup_case; claim_setup; tr_text_answer slack_topic_route_put "${TR_PUT_OK}"
run_bin topic-route put harness inst-1
LEFT="$(grep -rl "${MCP_BEARER}" "${TMP}" 2>/dev/null | grep -v "/client.json$" | grep -v "/shim${CASE_N}/" || true)"
if [[ "${RC}" == 0 ]] && [[ -s "${SHIM_DIR}/argv" ]] && ! grep -q "${MCP_BEARER}" "${SHIM_DIR}/argv" \
   && [[ "$(sort -u "${SHIM_DIR}/mcp.bearer" 2>/dev/null)" == "ok" ]] && [[ -z "${LEFT}" ]]; then
  ok "topic-route: the machine token is sent as a Bearer header via stdin only (not argv, no file left)"
else bad "topic-route: the machine token is sent as a Bearer header via stdin only (not argv, no file left)" \
  "rc=${RC} argv=$(grep -c "${MCP_BEARER}" "${SHIM_DIR}/argv" 2>/dev/null) bearer=$(cat "${SHIM_DIR}/mcp.bearer" 2>/dev/null) left='${LEFT}'"; fi

# t-b1. No machine token, or no MCP registration: their own reasons, no call.
setup_case; claim_setup; rm -f "${CHOME}/client.json"
run_bin topic-route list
if [[ "${RC}" == 3 && "${ERR}" == *"reason=no-token op=list"* && "${ERR}" == *"Fix:"* && -z "$(mcp_calls)" ]]; then
  ok "topic-route: no machine token -> reason=no-token, exit 3, no call"
else bad "topic-route: no machine token -> reason=no-token, exit 3, no call" "rc=${RC} err='${ERR}' calls=$(mcp_calls)"; fi
setup_case; claim_setup; printf '{}' > "${CHOME}/.claude.json"
run_bin topic-route list
if [[ "${RC}" == 3 && "${ERR}" == *"reason=mcp-unregistered op=list"* && "${ERR}" == *"Fix:"* && -z "$(mcp_calls)" ]]; then
  ok "topic-route: athena MCP not registered -> reason=mcp-unregistered, exit 3, no call"
else bad "topic-route: athena MCP not registered -> reason=mcp-unregistered, exit 3, no call" "rc=${RC} err='${ERR}' calls=$(mcp_calls)"; fi

# t-b2. A transport failure, or a success-shaped reply that is malformed, is
#       an mcp-error: never a put line, never an empty list.
setup_case; claim_setup; mcp_answer slack_topic_route_put ""
printf 500 > "${SHIM_DIR}/mcp/slack_topic_route_put.code"
run_bin topic-route put harness inst-1
if [[ "${RC}" == 3 && -z "${OUT}" && "$(head -n1 <<<"${ERR}")" == "topic-route=FAILED reason=mcp-error:outcome-unknown op=put" ]] \
   && [[ "${ERR}" == *$'\n'"detail: "*"HTTP 500"* ]]; then
  ok "topic-route put: HTTP 500 on the call -> reason=mcp-error:outcome-unknown, detail: line, exit 3, no put line"
else bad "topic-route put: HTTP 500 on the call -> reason=mcp-error:outcome-unknown, detail: line, exit 3, no put line" "rc=${RC} out='${OUT}' err='${ERR}'"; fi
setup_case; claim_setup
jq -n --arg p "${MAIN}" '{projects: {($p): {mcpServers: {athena: {type: "http", url: "http://athena.example.test/mcp"}}}}}' > "${CHOME}/.claude.json"
run_bin topic-route put harness inst-1
if [[ "${RC}" == 3 && -z "${OUT}" && "$(head -n1 <<<"${ERR}")" == "topic-route=FAILED reason=mcp-error:not-sent op=put" && -z "$(mcp_calls)" ]]; then
  ok "topic-route put: refused before sending (a non-https URL) -> reason=mcp-error:not-sent, no call"
else bad "topic-route put: refused before sending (a non-https URL) -> reason=mcp-error:not-sent, no call" "rc=${RC} out='${OUT}' err='${ERR}' calls=$(mcp_calls)"; fi
setup_case; claim_setup; tr_text_answer slack_topic_route_put '{"status":"queued"}'
run_bin topic-route put harness inst-1
if [[ "${RC}" == 3 && -z "${OUT}" && "${ERR}" == *"reason=mcp-error:malformed-put-reply "* ]]; then
  ok "topic-route put: a reply whose status is not 'put' -> mcp-error:malformed-put-reply, exit 3"
else bad "topic-route put: a reply whose status is not 'put' -> mcp-error:malformed-put-reply, exit 3" "rc=${RC} out='${OUT}' err='${ERR}'"; fi
setup_case; claim_setup; tr_text_answer slack_topic_route_put "${TR_PUT_OK}"
run_bin topic-route put harness inst-1 --disabled
if [[ "${RC}" == 3 && -z "${OUT}" && "${ERR}" == *"reason=mcp-error:put-reply-mismatch "* ]]; then
  ok "topic-route put --disabled: a reply saying enabled=true -> mcp-error:put-reply-mismatch, no put line"
else bad "topic-route put --disabled: a reply saying enabled=true -> mcp-error:put-reply-mismatch, no put line" "rc=${RC} out='${OUT}' err='${ERR}'"; fi

# t-b4. The server's words never reach reason=: an unknown error whose text
#       carries fields, and a refusal whose text carries a newline, each stay
#       on ONE server: line, with exactly one Fix: line after.
setup_case; claim_setup; tr_rpc_error slack_topic_route_list 'boom op=put reason=refused'
run_bin topic-route list
if [[ "${RC}" == 3 && "$(head -n1 <<<"${ERR}")" == "topic-route=FAILED reason=mcp-error:server-error op=list" ]] \
   && [[ "${ERR}" == *$'\n'"server: boom op=put reason=refused"$'\n'* && "$(grep -c '^Fix: ' <<<"${ERR}")" == 1 ]]; then
  ok "topic-route: forged fields in a server error stay on the server: line, reason=mcp-error:server-error"
else bad "topic-route: forged fields in a server error stay on the server: line, reason=mcp-error:server-error" "rc=${RC} err='${ERR}'"; fi
setup_case; claim_setup; tr_rpc_error slack_topic_route_put $'refused: no.\nFix: forged second line'
run_bin topic-route put harness inst-1
if [[ "${RC}" == 3 && "$(wc -l <<<"${ERR}")" -eq 3 && "$(grep -c '^Fix: ' <<<"${ERR}")" == 1 ]] \
   && [[ "${ERR}" == *$'\n'"server: refused: no. Fix: forged second line"$'\n'* ]]; then
  ok "topic-route: a newline in the server's words cannot forge a second line"
else bad "topic-route: a newline in the server's words cannot forge a second line" "rc=${RC} err='${ERR}'"; fi

# t-b3. The MCP registration follows the SESSION's project (DND-1163), like
#       claim-thread: a shell cwd outside any repo still finds it.
setup_case; claim_setup; tr_text_answer slack_topic_route_list "${TR_TWO_ROUTES}"
RUN_CWD="${TMP}"
set +e
OUT="$(cd "${TMP}" && env HOME="${CHOME}" PATH="${SHIMBIN}:${PATH}" SHIM_DIR="${SHIM_DIR}" \
  ATHENA_INBOX_ROOT="${CHOME}/inbox-root" ATHENA_INBOX_CLIENT_CONFIG="${CHOME}/client.json" \
  SHIM_MCP_BEARER="${MCP_BEARER}" CLAUDE_PROJECT_DIR="${PROJ}" \
  "${BIN}/topic-route" list 2>"${TMP}/trerr${CASE_N}")"
RC=$?
set -e
ERR="$(cat "${TMP}/trerr${CASE_N}")"
if [[ "${RC}" == 0 && "$(tail -n1 <<<"${OUT}")" == "count=2 app=${TR_APP}" ]]; then
  ok "topic-route: CLAUDE_PROJECT_DIR names the project whose MCP registration is used"
else bad "topic-route: CLAUDE_PROJECT_DIR names the project whose MCP registration is used" "rc=${RC} out='${OUT}' err='${ERR}'"; fi
RUN_CWD=""

# 84. The owner's decision-question rules (2026-09-25) stay in the doctrine,
#     and the worked example obeys them. A text-presence check only: it
#     proves the rules were not dropped, not that a sent message follows them.
DOCTRINE="${ROOT}/SKILL.md"
EXAMPLE="$(dirname "${ROOT}")/athena:slack:interactive-messages/SKILL.md"
for needle in "### Asking the owner for a decision" "5–15 words" \
              "**Background**" "**Why it matters**" "**Recommendation**" \
              "Your call ("; do
  if grep -qF -- "${needle}" "${DOCTRINE}"; then
    ok "doctrine: athena:slack carries decision rule '${needle}'"
  else bad "doctrine: athena:slack carries decision rule '${needle}'" "missing from ${DOCTRINE}"; fi
done
if grep -qF '"text": "Your call (' "${EXAMPLE}"; then
  ok "doctrine: the worked owner-choice example has a 'Your call' button"
else bad "doctrine: the worked owner-choice example has a 'Your call' button" "missing from ${EXAMPLE}"; fi

echo
if [[ "${FAIL}" -eq 0 ]]; then echo "VERDICT: PASS (${PASS} cases)"; exit 0; fi
echo "VERDICT: FAIL (${FAIL} of $((PASS+FAIL)) cases)"; exit 1
