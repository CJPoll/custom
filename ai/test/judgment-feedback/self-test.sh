#!/usr/bin/env bash
# self-test.sh -- the ai/bin/judgment-feedback suite (DND-1466). Discovered by
# harness-gate (every committed `self-test.sh` runs).
#
# Two layers, in TDD order:
#   1. domain -- ai/lib/judgment_feedback.rb, loaded with ruby -e;
#   2. end to end -- the tool against a loopback fake of the Athena server's
#      feedback surfaces (fake-feedback-server.py). Never prod: the URL is
#      127.0.0.1, and the token, the MCP registry and the token file are temp
#      fixtures. Functional only (DND-1222): the suite blocks on the fake's
#      port line and on each command's exit, never on a sleep.
#
# The ticket's tests are marked [ticket N].

set -u

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT="$(cd -- "${HERE}/../../.." && pwd -P)"
BIN="${ROOT}/ai/bin/judgment-feedback"
LIB="${ROOT}/ai/lib/judgment_feedback.rb"
FAKE="${HERE}/fake-feedback-server.py"

PASS=0
FAIL=0
ok()    { PASS=$((PASS + 1)); printf 'ok   %s\n' "$1"; }
bad()   { FAIL=$((FAIL + 1)); printf 'FAIL %s\n' "$1"; [ -n "${2:-}" ] && printf '     %s\n' "$2"; return 0; }
eq()    { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$3], got [$2]"; fi; }
has()   { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "no [$3] in: $2" ;; esac; }
lacks() { case "$2" in *"$3"*) bad "$1" "unexpected [$3] in: $2" ;; *) ok "$1" ;; esac; }

[ -x /usr/bin/ruby ] || { echo "judgment-feedback self-test: FAIL -- /usr/bin/ruby is missing"; echo "  Fix: install the harness Ruby at /usr/bin/ruby (DND-931); this suite does not skip."; exit 1; }
for dep in python3 curl jq; do
  command -v "${dep}" >/dev/null 2>&1 || { echo "judgment-feedback self-test: FAIL -- ${dep} is not on PATH"; echo "  Fix: install ${dep}; this suite does not skip."; exit 1; }
done
[ -x "${BIN}" ] || { echo "judgment-feedback self-test: FAIL -- ${BIN} missing or not executable"; echo "  Fix: chmod +x ai/bin/judgment-feedback"; exit 1; }
[ -f "${LIB}" ] || { echo "judgment-feedback self-test: FAIL -- ${LIB} is missing"; echo "  Fix: restore ai/lib/judgment_feedback.rb"; exit 1; }

TMP="$(mktemp -d)" || { echo "FAIL mktemp"; echo "  Fix: free space in TMPDIR"; exit 1; }
SERVER_PID=""
cleanup() {
  [ -n "${SERVER_PID}" ] && kill "${SERVER_PID}" 2>/dev/null
  rm -rf "${TMP}"
}
trap cleanup EXIT INT TERM

# ruby_eq NAME EXPECTED RUBY-EXPR -- evaluate EXPR with the domain loaded.
ruby_eq() {
  local got
  got="$(/usr/bin/ruby -e "require ARGV.shift; JF = JudgmentFeedback; puts(begin; $3; rescue JudgmentFeedback::UsageError => e; 'UsageError: ' + e.message; end)" "${LIB}" 2>&1)"
  eq "$1" "${got}" "$2"
}

U1="11111111-1111-4111-8111-111111111111"
U2="22222222-2222-4222-8222-222222222222"
U3="33333333-3333-4333-8333-333333333333"
U4="44444444-4444-4444-8444-444444444444"
ZERO="00000000-0000-0000-0000-000000000000"

echo "== domain"

ruby_eq "corrections: q=label pairs into a map" \
  '{"relation":"duplicate","level":"2"}' \
  'JSON.generate(JF.corrections(["relation=duplicate", "level=2"]))'
ruby_eq "corrections: the label may hold '='; only the first splits" \
  '{"route":"a=b"}' \
  'JSON.generate(JF.corrections(["route=a=b"]))'
ruby_eq "corrections: a pair with no '=' is usage" \
  "UsageError: --correct needs <question>=<label>, got one with no '='" \
  'JF.corrections(["relation"])'
ruby_eq "corrections: an empty question or label is usage" \
  "UsageError: --correct needs a non-empty question and label" \
  'JF.corrections(["=x"])'
ruby_eq "corrections: a question named twice is usage" \
  "UsageError: --correct names the question relation more than once" \
  'JF.corrections(["relation=a", "relation=b"])'
ruby_eq "record body: --call form carries call_id and nothing about identity [ticket 1]" \
  "call_id,correction,note,session_label,signal" \
  'JF.record_body(call: "'"${U1}"'", corrections: {"q"=>"a"}, signal: "explicit", note: "n", session_label: "harness").keys.sort.join(",")'
ruby_eq "record body: the slack form carries use_case and subject_ref [ticket 2]" \
  '{"use_case":"slack_routing","subject_ref":"Ev0FAKE01"}' \
  'JSON.generate(JF.record_body(use_case: "slack_routing", subject: "Ev0FAKE01"))'
ruby_eq "record body: --call with --subject is usage" \
  "UsageError: name the call one way: --call, or --use-case with --subject" \
  'JF.record_body(call: "'"${U1}"'", use_case: "slack_routing", subject: "Ev1")'
ruby_eq "record body: neither key is usage" \
  "UsageError: name the call: --call <uuid>, or --use-case slack_routing --subject <event_id>" \
  'JF.record_body'
ruby_eq "record body: --use-case without --subject is usage" \
  "UsageError: --use-case and --subject go together" \
  'JF.record_body(use_case: "slack_routing")'
ruby_eq "record body: a call id that is not a uuid is usage" \
  "UsageError: --call needs a uuid" \
  'JF.record_body(call: "DND-1")'
ruby_eq "record body: a note over 500 characters is usage" \
  "UsageError: the note is 501 characters; the limit is 500" \
  'JF.record_body(call: "'"${U1}"'", note: "x" * 501)'

ruby_eq "cursor: a bare time reads as that time with the zero id" \
  "2026-10-01T07:00:00.000000Z,${ZERO}" \
  'JF.encode(JF.parse_after("2026-10-01T07:00:00Z"))'
ruby_eq "cursor: a server cursor round-trips, an offset normalised to UTC" \
  "2026-10-01T07:15:53.123456Z,${U1}" \
  'JF.encode(JF.parse_after("2026-10-01T09:15:53.123456+02:00,'"${U1}"'"))'
ruby_eq "cursor: a date alone is usage, never a guess" \
  "UsageError: --after needs a cursor (<ISO 8601 time>,<uuid>) or an ISO 8601 time with a zone" \
  'JF.parse_after("2026-10-01")'
ruby_eq "cursor: a time with no zone is usage" \
  "UsageError: --after needs a cursor (<ISO 8601 time>,<uuid>) or an ISO 8601 time with a zone" \
  'JF.parse_after("2026-10-01T07:00:00")'
ruby_eq "cursor: step back N seconds lands on the zero id" \
  "2026-10-01T07:14:53.123456Z,${ZERO}" \
  'JF.encode(JF.step_back(JF.parse_after("2026-10-01T07:15:53.123456Z,'"${U1}"'"), 60))'
ruby_eq "cursor: order is time, then id" \
  "true|true|false" \
  'a = JF.parse_after("2026-10-01T07:00:00Z,'"${U1}"'"); b = JF.parse_after("2026-10-01T07:00:00Z,'"${U2}"'"); c = JF.parse_after("2026-10-01T07:00:01Z,'"${U1}"'"); [JF.after?(b, a), JF.after?(c, b), JF.after?(a, a)].join("|")'

ruby_eq "http: 404 with a fix is a refusal (exit 4) naming the server's fix [ticket 3]" \
  "4|SERVER REFUSED: HTTP 404 not_found. Fix: name a call of yours" \
  'r = JF.http_failure({curl_rc: 0, status: 404, body: %({"error":"not_found","fix":"Fix: name a call of yours"})}); [r[0], r[1]].join("|")'
ruby_eq "http: 422 invalid names its field" \
  "4|SERVER REFUSED: HTTP 422 invalid (field correction). Fix: map each question to one of its labels" \
  'r = JF.http_failure({curl_rc: 0, status: 422, body: %({"error":"invalid","field":"correction","fix":"Fix: map each question to one of its labels"})}); [r[0], r[1]].join("|")'
ruby_eq "http: a server fix without the marker still reads Fix:" \
  "4|SERVER REFUSED: HTTP 409 not_judged. Fix: report only answered calls" \
  'r = JF.http_failure({curl_rc: 0, status: 409, body: %({"error":"not_judged","fix":"report only answered calls"})}); [r[0], r[1]].join("|")'
ruby_eq "http: curl failure is COULD NOT REACH SERVER (exit 3)" \
  "3|COULD NOT REACH SERVER: curl exit 7" \
  'r = JF.http_failure({curl_rc: 7, status: 0, body: ""}); [r[0], r[1][/\A[^.]*/]].join("|")'
ruby_eq "http: a 5xx is SERVER FAILED (exit 3)" \
  "3|SERVER FAILED: HTTP 500" \
  'r = JF.http_failure({curl_rc: 0, status: 500, body: "boom"}); [r[0], r[1][/\A[^.]*/]].join("|")'
ruby_eq "http: a 401 is SERVER FAILED, never a refusal to work around" \
  "3|true" \
  'r = JF.http_failure({curl_rc: 0, status: 401, body: %({"error":"unauthorized"})}); [r[0], r[1].start_with?("SERVER FAILED: HTTP 401")].join("|")'
ruby_eq "http: a 4xx with no readable error is SERVER FAILED" \
  "3|SERVER FAILED: HTTP 404" \
  'r = JF.http_failure({curl_rc: 0, status: 404, body: "<html>"}); [r[0], r[1][/\A[^.]*/]].join("|")'
ruby_eq "http: a 200 is no failure" \
  "nil" \
  'JF.http_failure({curl_rc: 0, status: 200, body: "{}"}).inspect'
ruby_eq "http: every failure line carries Fix:" \
  "true" \
  '[[7, 0, ""], [0, 500, ""], [0, 401, ""], [0, 404, %({"error":"not_found","fix":"Fix: x"})]].all? { |c, s, b| JF.http_failure({curl_rc: c, status: s, body: b})[1].include?("Fix: ") }'

ruby_eq "recorded: the line names the feedback and the call" \
  "recorded ${U2} call ${U1}|replaced ${U2} call ${U1}" \
  '[false, true].map { |r| JF.recorded_line(JSON.generate("status"=>"recorded","feedback_id"=>"'"${U2}"'","call_id"=>"'"${U1}"'","replaced"=>r)) }.join("|")'
ruby_eq "recorded: an answer missing a field is unreadable" \
  "UnreadableAnswer: no feedback_id" \
  'begin; JF.recorded_line(%({"status":"recorded","call_id":"'"${U1}"'","replaced":false})); rescue JF::UnreadableAnswer => e; "UnreadableAnswer: " + e.message; end'

ROW1="{\"id\":\"${U1}\",\"cursor\":\"2026-10-01T07:00:00.000001Z,${U1}\",\"call_id\":\"${U3}\",\"note\":\"SYNTHETIC-NOTE\",\"request\":{\"state\":\"SYNTHETIC-PAYLOAD\"}}"
C1="2026-10-01T07:00:00.000001Z,${U1}"
ROW2="{\"id\":\"${U2}\",\"cursor\":\"2026-10-01T07:00:00.000002Z,${U2}\"}"
unreadable() { ruby_eq "$1" "UnreadableAnswer: $2" "begin; $3; rescue JF::UnreadableAnswer => e; \"UnreadableAnswer: \" + e.message; end"; }
ruby_eq "page: a well-formed page reads" \
  "1|false|${C1}" \
  'p = JF.page(%({"feedback":['"${ROW1}"'],"count":1,"has_more":false,"next_cursor":"'"${C1}"'"}), limit: 2, after: nil); [p[:rows].size, p[:has_more], JF.encode(p[:next_cursor])].join("|")'
unreadable "page: count disagreeing with the rows is unreadable" "count 2 but 1 rows" \
  'JF.page(%({"feedback":['"${ROW1}"'],"count":2,"has_more":false,"next_cursor":null}), limit: 5, after: nil)'
unreadable "page: a row with no id is unreadable" "row 0 has no uuid id" \
  'JF.page(%({"feedback":[{"cursor":"x"}],"count":1,"has_more":false,"next_cursor":null}), limit: 5, after: nil)'
unreadable "page: no has_more is unreadable, never read as the last page" "has_more is not true or false" \
  'JF.page(%({"feedback":[],"count":0,"next_cursor":null}), limit: 5, after: nil)'
unreadable "page: a full page that says it is the last is unreadable (it would truncate the read)" "has_more false for 1 rows at limit 1" \
  'JF.page(%({"feedback":['"${ROW1}"'],"count":1,"has_more":false,"next_cursor":"'"${C1}"'"}), limit: 1, after: nil)'
unreadable "page: a short page that says there is more is unreadable" "has_more true for 1 rows at limit 2" \
  'JF.page(%({"feedback":['"${ROW1}"'],"count":1,"has_more":true,"next_cursor":"'"${C1}"'"}), limit: 2, after: nil)'
unreadable "page: a next_cursor ahead of the last row would skip rows: unreadable" "next_cursor is not the last row's cursor" \
  'JF.page(%({"feedback":['"${ROW1}"'],"count":1,"has_more":true,"next_cursor":"2026-10-01T09:00:00.000000Z,'"${U1}"'"}), limit: 1, after: nil)'
unreadable "page: has_more with no next_cursor is unreadable" "next_cursor is not the last row's cursor" \
  'JF.page(%({"feedback":['"${ROW1}"'],"count":1,"has_more":true,"next_cursor":null}), limit: 1, after: nil)'
unreadable "page: rows out of order are unreadable" "row 1 is not after the row before it" \
  'JF.page(%({"feedback":['"${ROW2}"','"${ROW1}"'],"count":2,"has_more":false,"next_cursor":"'"${C1}"'"}), limit: 5, after: nil)'
unreadable "page: a row at or behind the cursor asked for is unreadable" "row 0 is not after the cursor asked for" \
  'JF.page(%({"feedback":['"${ROW1}"'],"count":1,"has_more":false,"next_cursor":"'"${C1}"'"}), limit: 5, after: JF.parse_after("'"${C1}"'"))'
ruby_eq "redact: note and request are dropped, has_note said" \
  "call_id,cursor,has_note,id|true" \
  'r = JF.redact(JSON.parse(%('"${ROW1}"')), false); [r.keys.sort.join(","), r["has_note"]].join("|")'
ruby_eq "redact: only the listed fields print; a field the server adds later does not" \
  "call_id,cursor,has_note,id,use_case" \
  'JF.redact({"id"=>"x","cursor"=>"c","call_id"=>"y","use_case"=>"u","summary"=>"NEW TEXT FIELD"}, false).keys.sort.join(",")'
ruby_eq "row line: a control character in a server string is not printed" \
  "${U1} finding triage - - - call -" \
  'JF.row_line({"id"=>"'"${U1}"'","use_case"=>"finding\ntriage"})'
ruby_eq "redact: --with-payloads keeps them" \
  "SYNTHETIC-NOTE" \
  'JF.redact(JSON.parse(%('"${ROW1}"')), true)["note"]'
ruby_eq "final cursor: never behind the cursor the reader started from" \
  "2026-10-01T08:00:00.000000Z,${ZERO}" \
  'JF.encode(JF.final_cursor(JF.parse_after("2026-10-01T08:00:00Z"), [JSON.parse(%('"${ROW1}"'))]))'
ruby_eq "final cursor: the last row read when it is ahead" \
  "2026-10-01T07:00:00.000001Z,${U1}" \
  'JF.encode(JF.final_cursor(JF.parse_after("2026-10-01T06:00:00Z"), [JSON.parse(%('"${ROW1}"'))]))'
ruby_eq "final cursor: no cursor and no rows is none" \
  "nil" \
  'JF.final_cursor(nil, []).inspect'
ruby_eq "seen tail: the ids within the overlap behind the final cursor" \
  "${U2},${U3}" \
  'rows = [["06:58:59", "'"${U1}"'"], ["06:59:30", "'"${U2}"'"], ["07:00:00", "'"${U3}"'"]].map { |t, i| {"id"=>i, "cursor"=>"2026-10-01T#{t}.000000Z,#{i}"} }; JF.seen_tail(rows, JF.parse_after("2026-10-01T07:00:00Z,'"${U3}"'"), 60).join(",")'
ruby_eq "seen tail: overlap 0 keeps nothing" \
  "" \
  'JF.seen_tail([{"id"=>"'"${U1}"'","cursor"=>"2026-10-01T07:00:00Z,'"${U1}"'"}], JF.parse_after("2026-10-01T07:00:00Z,'"${U1}"'"), 0).join(",")'
ruby_eq "seen file: a line that is not a uuid is usage, never skipped" \
  "UsageError: --seen-file line 2 is not a uuid" \
  'JF.seen_ids("'"${U1}"'\nnot-a-uuid\n")'
ruby_eq "seen file: blank lines are fine" \
  "${U1}" \
  'JF.seen_ids("'"${U1}"'\n\n").to_a.join(",")'

echo "== end to end"

TOKEN="feedback-token-$$-${RANDOM}-9c2e"
printf '%s\n' "${TOKEN}" > "${TMP}/token"
mkdir -p "${TMP}/cfg" "${TMP}/spec"
jq -n --arg t "${TOKEN}" '{server_url: "wss://example.invalid/machine/websocket", token: $t}' > "${TMP}/cfg/config.json"
chmod 600 "${TMP}/cfg/config.json"
export ATHENA_INBOX_CLIENT_CONFIG="${TMP}/cfg/config.json"
export FLEET_CLAUDE_JSON="${TMP}/claude.json"
export JUDGMENT_FEEDBACK_MAX_TIME_S=10
: > "${TMP}/server.log"

coproc FAKE_SERVER { exec python3 "${FAKE}" "${TMP}/server.log" "${TMP}/spec" "${TMP}/token"; }
SERVER_PID="${FAKE_SERVER_PID}"
PORT=""
read -r -t 20 PORT <&"${FAKE_SERVER[0]}" || true
case "${PORT}" in
  ''|*[!0-9]*) echo "FAIL the fake server printed no port"; echo "  Fix: run ${FAKE} by hand and read its error"; exit 1 ;;
esac
registry() { jq -n --arg u "$1" '{mcpServers: {athena: {type: "http", url: $u}}}' > "${FLEET_CLAUDE_JSON}"; }
registry "http://127.0.0.1:${PORT}/mcp"

spec() { printf '%s\n' "$2" > "${TMP}/spec/$1"; }
requests() { local c; c="$(grep -c . "${TMP}/server.log" 2>/dev/null)"; printf '%s\n' "${c:-0}"; }
last() { tail -n 1 "${TMP}/server.log"; }
# The fake numbers GETs across the whole run; each case writes its pages
# after the GETs already made.
GBASE=0
reset_gets() { GBASE="$(jq -s 'map(select(.method == "GET")) | length' "${TMP}/server.log")"; }
page() { spec "get-$((GBASE + $1)).json" "$2"; }

run() {
  OUT="$("${BIN}" "$@" 2>"${TMP}/err")"
  RC=$?
  ERR="$(cat "${TMP}/err")"
}

n="$(requests)"
run --help
eq "--help exits 0 [ticket 5]" "${RC}" "0"
has "--help prints the usage on stdout [ticket 5]" "${OUT}" "Usage: judgment-feedback"
eq "--help makes no request [ticket 5]" "$(requests)" "${n}"
run record --help
eq "record --help exits 0 too, with no request" "${RC}|$(requests)" "0|${n}"

run
eq "no subcommand is usage (2)" "${RC}" "2"
has "the usage line carries Fix:" "${ERR}" "Fix: "
run record --call "${U1}" --owner me
eq "an identity flag does not exist: usage (2)" "${RC}" "2"
has "...and is named" "${ERR}" '--owner'
run record --call "${U1}" --machine m1
eq "--machine does not exist either" "${RC}" "2"
run list --after "2026-10-01T07:00:00Z" --bogus
eq "an unknown list flag is usage" "${RC}" "2"
run record --call "${U1}" --correct
eq "--correct with no value is usage" "${RC}" "2"
run record --call "${U1}" --note-file "${TMP}/absent"
eq "a missing --note-file is usage" "${RC}" "2"
has "...with Fix:" "${ERR}" "Fix: "
run list --overlap-s 3601
eq "--overlap-s over an hour is usage" "${RC}" "2"
run list --limit 201
eq "--limit over 200 is usage" "${RC}" "2"
eq "no usage error sent a request" "$(requests)" "${n}"

# [ticket 1] record --call: the body, the token, the output.
spec post.json "{\"status\":200,\"body\":{\"status\":\"recorded\",\"feedback_id\":\"${U2}\",\"call_id\":\"${U1}\",\"replaced\":false}}"
printf 'SYNTHETIC-NOTE-TEXT\n' > "${TMP}/note.txt"
run record --correct relation=duplicate --call "${U1}" --note-file "${TMP}/note.txt" --correct severity=2 --session-label harness
eq "record --call exits 0 [ticket 1]" "${RC}" "0"
eq "record prints the feedback and call ids [ticket 1]" "${OUT}" "recorded ${U2} call ${U1}"
lacks "the note is never printed" "${OUT}${ERR}" "SYNTHETIC-NOTE"
entry="$(last)"
eq "POST to the feedback route [ticket 1]" "$(jq -r '.method + " " + .path' <<<"${entry}")" "POST /api/v1/judgments/feedback"
eq "the body has call_id and the correction map [ticket 1]" "$(jq -c '.body | {call_id, correction}' <<<"${entry}")" "{\"call_id\":\"${U1}\",\"correction\":{\"relation\":\"duplicate\",\"severity\":\"2\"}}"
eq "the note is the file's text, trailing newline cut" "$(jq -r '.body.note' <<<"${entry}")" "SYNTHETIC-NOTE-TEXT"
eq "no owner, machine or reporter key [ticket 1]" "$(jq -c '.body | keys' <<<"${entry}")" '["call_id","correction","note","session_label"]'
eq "the bearer token was the machine token" "$(jq -r '.auth_ok' <<<"${entry}")" "true"
eq "the token was in no process's argv [ticket 1]" "$(jq -c '.argv_leak' <<<"${entry}")" "[]"
eq "the token was in no process's environment" "$(jq -c '.environ_leak' <<<"${entry}")" "[]"
lacks "the token is never printed" "${OUT}${ERR}" "${TOKEN}"

spec post.json "{\"status\":200,\"body\":{\"status\":\"recorded\",\"feedback_id\":\"${U2}\",\"call_id\":\"${U1}\",\"replaced\":true}}"
run record --call "${U1}" --signal explicit
eq "a second report says replaced" "${RC}|${OUT}" "0|replaced ${U2} call ${U1}"
eq "--signal is passed through" "$(last | jq -r '.body.signal')" "explicit"

# [ticket 2] the slack form.
run record --subject Ev0FAKE01 --use-case slack_routing --correct route=harness
eq "record slack form exits 0 [ticket 2]" "${RC}" "0"
eq "the body has use_case and subject_ref [ticket 2]" "$(last | jq -c '.body | {use_case, subject_ref, call_id}')" '{"use_case":"slack_routing","subject_ref":"Ev0FAKE01","call_id":null}'

# [ticket 3] refusals and an unreachable server.
spec post.json '{"status":404,"body":{"error":"not_found","fix":"Fix: name a call of yours (the call id the result printed)."}}'
run record --call "${U1}"
eq "404 exits 4 [ticket 3]" "${RC}" "4"
eq "...with the server's fix as the first line [ticket 3]" "$(head -n 1 <<<"${ERR}")" "SERVER REFUSED: HTTP 404 not_found. Fix: name a call of yours (the call id the result printed)."
eq "...and nothing on stdout" "${OUT}" ""
spec post.json '{"status":409,"body":{"error":"not_judged","fix":"Fix: that call fell back; only an answered call can be reported."}}'
run record --call "${U1}"
eq "409 not_judged exits 4" "${RC}" "4"
has "...named" "${ERR}" "SERVER REFUSED: HTTP 409 not_judged."
spec post.json '{"status":422,"body":{"error":"invalid","field":"correction","fix":"Fix: map each question to one of its labels."}}'
run record --call "${U1}" --correct relation=nope
eq "422 invalid exits 4 and names the field" "${RC}|$(head -n 1 <<<"${ERR}")" "4|SERVER REFUSED: HTTP 422 invalid (field correction). Fix: map each question to one of its labels."
spec post.json '{"status":500,"raw":"oops"}'
run record --call "${U1}"
eq "500 exits 3 SERVER FAILED" "${RC}|$(head -n 1 <<<"${ERR}" | cut -d. -f1)" "3|SERVER FAILED: HTTP 500"
spec post.json '{"status":403,"body":{"error":"forbidden","fix":"Fix: x"}}'
run record --call "${U1}"
eq "403 exits 3 SERVER FAILED (the token), never a refusal to work around" "${RC}|$(head -n 1 <<<"${ERR}" | cut -d'(' -f1)" "3|SERVER FAILED: HTTP 403 "
has "...naming the owner-issued token" "${ERR}" "owner-issued"
spec post.json '{"status":200,"raw":"not json"}'
run record --call "${U1}"
eq "a 200 that is not JSON exits 3 UNREADABLE SERVER ANSWER" "${RC}|$(head -n 1 <<<"${ERR}" | cut -d: -f1)" "3|UNREADABLE SERVER ANSWER"
has "...with Fix:" "${ERR}" "Fix: "

# A port nothing listens on: bind one, read its number, release it.
DEAD_PORT="$(python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()')"
registry "http://127.0.0.1:${DEAD_PORT}/mcp"
run record --call "${U1}"
eq "unreachable exits 3 [ticket 3]" "${RC}" "3"
has "...COULD NOT REACH SERVER [ticket 3]" "$(head -n 1 <<<"${ERR}")" "COULD NOT REACH SERVER: "
has "...with Fix:" "${ERR}" "Fix: "
registry "http://127.0.0.1:${PORT}/mcp"
mv "${ATHENA_INBOX_CLIENT_CONFIG}" "${TMP}/cfg/away.json"
run record --call "${U1}"
eq "no token file exits 3 COULD NOT REACH SERVER, naming the path" "${RC}|$(head -n 1 <<<"${ERR}" | grep -c "COULD NOT REACH SERVER: no machine token in ${ATHENA_INBOX_CLIENT_CONFIG}")" "3|1"
mv "${TMP}/cfg/away.json" "${ATHENA_INBOX_CLIENT_CONFIG}"

# [ticket 4] list: two pages, then complete.
row() { # row ID TIME
  printf '{"id":"%s","cursor":"%s,%s","call_id":"%s","use_case":"finding_triage","question_set_version":"finding-triage-v1","signal":"explicit","strength":"strong","note":"SYNTHETIC-NOTE-TEXT","request":{"state":"SYNTHETIC-PAYLOAD-TEXT"},"payload_state":"kept","reported_at":"%s"}' "$1" "$2" "$1" "${U4}" "$2"
}
T1="2026-10-01T07:00:00.000001Z"; T2="2026-10-01T07:00:30.000000Z"; T3="2026-10-01T07:01:00.000000Z"
reset_gets
n="$(requests)"
page 1 "{\"status\":200,\"body\":{\"feedback\":[$(row "${U1}" "${T1}"),$(row "${U2}" "${T2}")],\"count\":2,\"has_more\":true,\"next_cursor\":\"${T2},${U2}\"}}"
page 2 "{\"status\":200,\"body\":{\"feedback\":[$(row "${U3}" "${T3}")],\"count\":1,\"has_more\":false,\"next_cursor\":\"${T3},${U3}\"}}"
run list --json --limit 2 --after "2026-10-01T06:00:00Z"
eq "list pages twice then completes: exit 0 [ticket 4]" "${RC}" "0"
eq "two requests were made [ticket 4]" "$(( $(requests) - n ))" "2"
eq "the first asks after the given time, limit 2" "$(sed -n "$((n + 1))p" "${TMP}/server.log" | jq -c '.query')" "{\"after\":\"2026-10-01T06:00:00.000000Z,${ZERO}\",\"limit\":\"2\"}"
eq "the second asks after the first page's next_cursor" "$(last | jq -r '.query.after')" "${T2},${U2}"
eq "three row lines, then the final line [ticket 4]" "$(printf '%s\n' "${OUT}" | jq -r '.id // "final"' | tr '\n' ' ')" "${U1} ${U2} ${U3} final "
eq "the final line is complete with the last cursor [ticket 4]" "$(printf '%s\n' "${OUT}" | tail -n 1 | jq -c '{next_cursor, complete, rows, deduped}')" "{\"next_cursor\":\"${T3},${U3}\",\"complete\":true,\"rows\":3,\"deduped\":0}"
lacks "no note in the output by default" "${OUT}" "SYNTHETIC-NOTE"
lacks "no payload in the output by default" "${OUT}" "SYNTHETIC-PAYLOAD"
eq "rows say whether they carry a note" "$(printf '%s\n' "${OUT}" | head -n 1 | jq -r '.has_note')" "true"

# [ticket 4] a page failure mid-way.
reset_gets
page 1 "{\"status\":200,\"body\":{\"feedback\":[$(row "${U1}" "${T1}"),$(row "${U2}" "${T2}")],\"count\":2,\"has_more\":true,\"next_cursor\":\"${T2},${U2}\"}}"
page 2 '{"status":503,"raw":"down"}'
run list --json --limit 2 --after "2026-10-01T06:00:00Z"
eq "a page failure mid-way exits 3 [ticket 4]" "${RC}" "3"
has "...SERVER FAILED on stderr, with Fix:" "$(head -n 1 <<<"${ERR}")" "SERVER FAILED: HTTP 503"
eq "...the rows already read are printed [ticket 4]" "$(printf '%s\n' "${OUT}" | jq -r '.id // "final"' | tr '\n' ' ')" "${U1} ${U2} final "
eq "...and the last line is complete:false with no cursor to advance to [ticket 4]" "$(printf '%s\n' "${OUT}" | tail -n 1 | jq -c '{next_cursor, complete, rows}')" '{"next_cursor":null,"complete":false,"rows":2}'

reset_gets
DEAD_PORT="$(python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()')"
registry "http://127.0.0.1:${DEAD_PORT}/mcp"
run list --json --after "2026-10-01T06:00:00Z"
eq "an unreachable list is exit 3 and complete:false, never an empty list" "${RC}|$(printf '%s\n' "${OUT}" | tail -n 1 | jq -c '{complete, rows}')" '3|{"complete":false,"rows":0}'
registry "http://127.0.0.1:${PORT}/mcp"

reset_gets
page 1 "{\"status\":200,\"body\":{\"feedback\":[$(row "${U1}" "${T1}")],\"count\":1,\"has_more\":true,\"next_cursor\":\"2026-10-01T06:00:00.000000Z,${ZERO}\"}}"
run list --json --limit 1 --after "2026-10-01T06:00:00Z"
eq "a next_cursor that does not advance is unreadable (exit 3), never a loop" "${RC}|$(head -n 1 <<<"${ERR}" | cut -d: -f1)" "3|UNREADABLE SERVER ANSWER"

reset_gets
page 1 '{"status":422,"body":{"error":"invalid","field":"after","fix":"Fix: pass next_cursor from the previous page."}}'
run list --json --after "2026-10-01T06:00:00Z"
eq "a refused list is exit 4 and complete:false" "${RC}|$(printf '%s\n' "${OUT}" | tail -n 1 | jq -c '.complete')" "4|false"

# Overlap, dedupe by id, and a cursor that never moves backwards.
reset_gets
printf '%s\n' "${U2}" > "${TMP}/seen.txt"
page 1 "{\"status\":200,\"body\":{\"feedback\":[$(row "${U1}" "${T1}"),$(row "${U2}" "${T2}"),$(row "${U3}" "${T3}")],\"count\":3,\"has_more\":false,\"next_cursor\":\"${T3},${U3}\"}}"
run list --json --after "${T2},${U2}" --overlap-s 60 --seen-file "${TMP}/seen.txt"
eq "overlap read exits 0" "${RC}" "0"
eq "it asks 60 s behind the cursor, at the zero id" "$(last | jq -r '.query.after')" "2026-10-01T06:59:30.000000Z,${ZERO}"
eq "a seen id is dropped; a late commit behind the cursor is kept" "$(printf '%s\n' "${OUT}" | jq -r '.id // "final"' | tr '\n' ' ')" "${U1} ${U3} final "
eq "the final line counts the dedupe and carries the seen tail" "$(printf '%s\n' "${OUT}" | tail -n 1 | jq -c '{next_cursor, complete, rows, deduped, seen_tail}')" "{\"next_cursor\":\"${T3},${U3}\",\"complete\":true,\"rows\":2,\"deduped\":1,\"seen_tail\":[\"${U1}\",\"${U2}\",\"${U3}\"]}"

reset_gets
page 1 "{\"status\":200,\"body\":{\"feedback\":[],\"count\":0,\"has_more\":false,\"next_cursor\":\"2026-10-01T06:59:30.000000Z,${ZERO}\"}}"
run list --json --after "${T2},${U2}" --overlap-s 60
eq "an empty overlap read keeps the reader's own cursor, never the stepped-back one" "${RC}|$(printf '%s\n' "${OUT}" | tail -n 1 | jq -c '{next_cursor, complete, rows}')" "0|{\"next_cursor\":\"${T2},${U2}\",\"complete\":true,\"rows\":0}"

# A first run (no cursor) then a second: the second re-reads the first's
# last minute and must drop every row of it by id (review round, must-fix 1).
reset_gets
page 1 "{\"status\":200,\"body\":{\"feedback\":[$(row "${U1}" "${T1}"),$(row "${U2}" "${T2}")],\"count\":2,\"has_more\":true,\"next_cursor\":\"${T2},${U2}\"}}"
page 2 "{\"status\":200,\"body\":{\"feedback\":[],\"count\":0,\"has_more\":false,\"next_cursor\":\"${T2},${U2}\"}}"
run list --overlap-s 60 --limit 2 --json
eq "a first run with --overlap-s and no --after reads from the oldest row" "${RC}|$(sed -n "$(( $(requests) - 1 ))p" "${TMP}/server.log" | jq -c '.query')" "0|{\"limit\":\"2\"}"
FIRST_FINAL="$(printf '%s\n' "${OUT}" | tail -n 1)"
eq "...and its seen tail holds the rows of its last minute" "$(jq -c '{next_cursor, seen_tail}' <<<"${FIRST_FINAL}")" "{\"next_cursor\":\"${T2},${U2}\",\"seen_tail\":[\"${U1}\",\"${U2}\"]}"
jq -r '.seen_tail[]' <<<"${FIRST_FINAL}" > "${TMP}/seen2.txt"
reset_gets
page 1 "{\"status\":200,\"body\":{\"feedback\":[$(row "${U1}" "${T1}"),$(row "${U2}" "${T2}"),$(row "${U3}" "${T3}")],\"count\":3,\"has_more\":false,\"next_cursor\":\"${T3},${U3}\"}}"
run list --seen-file "${TMP}/seen2.txt" --overlap-s 60 --json --after "$(jq -r '.next_cursor' <<<"${FIRST_FINAL}")"
eq "the second run (flags in another order) drops both re-read rows and keeps the new one" "${RC}|$(printf '%s\n' "${OUT}" | jq -r '.id // "final"' | tr '\n' ' ')" "0|${U3} final "
eq "...counting them as deduped" "$(printf '%s\n' "${OUT}" | tail -n 1 | jq -c '{rows, deduped}')" '{"rows":1,"deduped":2}'

reset_gets
page 1 "{\"status\":200,\"body\":{\"feedback\":[$(row "${U1}" "${T1}")],\"count\":1,\"has_more\":false,\"next_cursor\":\"${T1},${U1}\"}}"
run list --with-payloads --json
eq "no --after reads from the oldest kept row (no after param)" "${RC}|$(last | jq -c '.query')" "0|{\"limit\":\"100\"}"
has "--with-payloads prints the note" "${OUT}" "SYNTHETIC-NOTE-TEXT"
has "--with-payloads prints the request" "${OUT}" "SYNTHETIC-PAYLOAD-TEXT"

reset_gets
page 1 "{\"status\":200,\"body\":{\"feedback\":[$(row "${U1}" "${T1}")],\"count\":1,\"has_more\":false,\"next_cursor\":\"${T1},${U1}\"}}"
run list --after "2026-10-01T06:00:00Z"
eq "list without --json prints a line per row and a complete line" "${RC}|$(printf '%s\n' "${OUT}" | wc -l | tr -d ' ')" "0|2"
has "...the row line carries ids only" "$(head -n 1 <<<"${OUT}")" "${U1} finding_triage finding-triage-v1 explicit strong call ${U4}"
has "...the last line says complete" "$(tail -n 1 <<<"${OUT}")" "complete: 1 rows, 0 deduped, next_cursor ${T1},${U1}"
lacks "...and no note" "${OUT}" "SYNTHETIC"

eq "no request ever went to an unexpected route" "$(jq -s '[.[] | select(.unexpected)] | length' "${TMP}/server.log")" "0"
eq "no request leaked the token to argv or env" "$(jq -s '[.[] | select((.argv_leak | length) > 0 or (.environ_leak | length) > 0)] | length' "${TMP}/server.log")" "0"

echo
echo "judgment-feedback self-test: ${PASS} passed, ${FAIL} failed"
if [ "${FAIL}" -ne 0 ]; then
  echo "  Fix: read the FAIL lines above; each names the case and what it got."
  exit 1
fi
exit 0
