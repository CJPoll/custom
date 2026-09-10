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
HOOK="${ROOT}/hooks/athena-slack-poll.sh"

TMP="$(mktemp -d)"; trap 'rm -rf "${TMP}"' EXIT
PASS=0; FAIL=0

BOT_USER="U0BU75F8EUR"
CODY="U0AHNV4RJGP"
ENG_CHANNEL="C07A6E3CBFH"
FAKE_TOKEN="xoxb-fake-000-111-abcdefghijklmnop"

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
  CHOME="${TMP}/home${CASE_N}"
  CACHE="${CHOME}/.cache/athena-slack"
  mkdir -p "${CHOME}/.claude" "${CACHE}"
  SHIM_DIR="${TMP}/shim${CASE_N}"; mkdir -p "${SHIM_DIR}"
  printf '%s\n' "${FAKE_TOKEN}" > "${CHOME}/.claude/slack-bot-token"
  chmod 600 "${CHOME}/.claude/slack-bot-token"
  # A recent success by default, so soft-fail cases assert the silence they
  # were written for rather than tripping the staleness warning.
  : > "${CHOME}/.claude/athena-slack-last-success"
}

# Pre-seed the caches the inbox scan reads, so a case can script the API calls
# it actually cares about instead of re-scripting identity every time.
seed_caches() {
  printf '{"ok":true,"user":"athena","user_id":"%s","team_id":"T06UD7W5HGX"}' "${BOT_USER}" \
    > "${CACHE}/identity.json"
  printf '{"%s":"cody","%s":"athena","U0BETV05H40":"johnny"}' "${CODY}" "${BOT_USER}" \
    > "${CACHE}/users.json"
  printf '[{"id":"%s","name":"team-engineering","is_member":true},{"id":"C074G1DDUV8","name":"standup","is_member":false}]' \
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
  OUT="$(env HOME="${CHOME}" PATH="${SHIMBIN}:${PATH}" SHIM_DIR="${SHIM_DIR}" \
    SLACK_MAX_RETRIES="${SLACK_MAX_RETRIES_OVERRIDE:-3}" \
    "${BIN}/${script}" "$@" 2>"${TMP}/err${CASE_N}")"
  RC=$?
  set -e
  ERR="$(cat "${TMP}/err${CASE_N}")"
}

run_bin_stdin() { # run_bin_stdin <stdin> <script> [args...]
  local input="$1" script="$2"; shift 2
  set +e
  OUT="$(printf '%s' "${input}" | env HOME="${CHOME}" PATH="${SHIMBIN}:${PATH}" \
    SHIM_DIR="${SHIM_DIR}" "${BIN}/${script}" "$@" 2>"${TMP}/err${CASE_N}")"
  RC=$?
  set -e
  ERR="$(cat "${TMP}/err${CASE_N}")"
}

run_hook() {
  set +e
  OUT="$(env HOME="${CHOME}" PATH="${SHIMBIN}:${PATH}" SHIM_DIR="${SHIM_DIR}" \
    "$@" sh "${HOOK}" 2>"${TMP}/herr${CASE_N}")"
  RC=$?
  set -e
  HOOKLOG="$(cat "${CHOME}/.claude/athena-slack-poll.log" 2>/dev/null || true)"
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
run_bin post '#team-engineering' "hi"
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
run_bin post "${ENG_CHANNEL}" "retry me"
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
fixture users.list '{"ok":true,"members":[{"id":"U0NEW","name":"erich","profile":{"display_name":"erich"}}],"response_metadata":{"next_cursor":""}}'
fixture conversations.history '{"ok":true,"messages":[{"ts":"1.1","user":"U0NEW","text":"hi"},{"ts":"1.2","user":"U0NEW","text":"again"}],"response_metadata":{"next_cursor":""}}'
run_bin read-channel "${ENG_CHANNEL}" --limit 5
if [[ "${OUT}" == *"erich"* ]] && [[ "$(calls_of users.list)" == "1" ]]; then
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
seed_state() { printf '{"version":1,"channels":{"D0CODY":"1000.0","%s":"1000.0"}}' "${ENG_CHANNEL}" > "${CACHE}/inbox-state.json"; }

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
if [[ "${OUT}" != *$'\n'* ]] \
   && [[ "${OUT}" == "2 new Slack DM(s) and 1 mention(s) for Athena — run /athena:slack read-inbox" ]]; then
  ok "hook: N>0 prints exactly one line with the right DM and mention counts"
else bad "hook: N>0 prints exactly one line with the right DM and mention counts" "out='${OUT}'"; fi

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
BEFORE="$(cat "${CACHE}/inbox-state.json")"
run_hook
if [[ "$(cat "${CACHE}/inbox-state.json")" == "${BEFORE}" ]]; then
  ok "hook: the inbox state file is left untouched (read-inbox owns it)"
else bad "hook: the inbox state file is left untouched" "after=$(cat "${CACHE}/inbox-state.json")"; fi

echo
echo "-- the hook: staleness -----------------------------------------------------"

# 37. Six hours with no successful poll, token present: say so, once.
setup_case
seed_caches
touch_ago 400 "${CHOME}/.claude/athena-slack-last-success"
fixture conversations.list '{"ok":false,"error":"invalid_auth"}'
run_hook
if [[ "${OUT}" == *"has not succeeded in 6h"* ]]; then ok "hook: warns after 6h with no successful poll"
else bad "hook: warns after 6h with no successful poll" "out='${OUT}' log='${HOOKLOG}'"; fi

# 38. ...and does not repeat it on the next prompt.
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
   && [[ "$(jq -r '.channels.D0CODY' "${CACHE}/inbox-state.json")" == "2000.5" ]]; then
  ok "read-inbox: shows the body, resolves the sender, advances the state file"
else bad "read-inbox: shows the body, resolves the sender, advances the state file" \
  "out='${OUT}' state=$(cat "${CACHE}/inbox-state.json")"; fi

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
BEFORE="$(cat "${CACHE}/inbox-state.json")"
run_bin read-inbox --peek
if [[ "${OUT}" == *"peek at me"* ]] && [[ "$(cat "${CACHE}/inbox-state.json")" == "${BEFORE}" ]]; then
  ok "read-inbox: --peek shows messages without advancing the state file"
else bad "read-inbox: --peek shows messages without advancing the state file" \
  "out='${OUT}' state=$(cat "${CACHE}/inbox-state.json")"; fi

# 45. A conversation seen for the first time records where it is and reports
#     nothing. Otherwise the first run after install announces the entire
#     history of every DM at once.
setup_case
seed_caches
rm -f "${CACHE}/inbox-state.json"
seed_inbox_fixtures "[{\"ts\":\"2000.5\",\"user\":\"${CODY}\",\"text\":\"ancient history\"}]" '[]'
run_bin read-inbox
if [[ "${OUT}" != *"ancient history"* ]] \
   && [[ "$(jq -r '.channels.D0CODY' "${CACHE}/inbox-state.json")" == "2000.5" ]]; then
  ok "read-inbox: first sight of a conversation records its ts and reports nothing"
else bad "read-inbox: first sight of a conversation records its ts and reports nothing" \
  "out='${OUT}' state=$(cat "${CACHE}/inbox-state.json" 2>/dev/null)"; fi

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
fixture conversations.list '{"ok":true,"channels":[{"id":"D0SLACKBOT","user":"USLACKBOT"},{"id":"D0CODY","user":"U0AHNV4RJGP"}],"response_metadata":{"next_cursor":""}}'
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
fixture conversations.list '{"ok":true,"channels":[{"id":"D0BAD","user":"U1"},{"id":"D0CODY","user":"U0AHNV4RJGP"}],"response_metadata":{"next_cursor":""}}'
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
rm -f "${CACHE}/inbox-state.json"
fixture conversations.list '{"ok":true,"channels":[{"id":"D0EMPTY","user":"U1"}],"response_metadata":{"next_cursor":""}}'
fixture conversations.history '{"ok":true,"messages":[],"response_metadata":{"next_cursor":""}}'
run_bin read-inbox
if [[ "$(jq -r '.channels.D0EMPTY' "${CACHE}/inbox-state.json" 2>/dev/null)" == "0" ]]; then
  ok "inbox scan: an empty conversation records a zero baseline, not nothing"
else bad "inbox scan: an empty conversation records a zero baseline, not nothing" \
  "state=$(cat "${CACHE}/inbox-state.json" 2>/dev/null)"; fi

# 52. ...and the NEXT message in it is then reported.
setup_case
seed_caches
printf '{"version":1,"channels":{"D0EMPTY":"0"}}' > "${CACHE}/inbox-state.json"
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
if [[ "${FAIL}" -eq 0 ]]; then echo "VERDICT: PASS (${PASS} cases)"; exit 0; fi
echo "VERDICT: FAIL (${FAIL} of $((PASS+FAIL)) cases)"; exit 1
