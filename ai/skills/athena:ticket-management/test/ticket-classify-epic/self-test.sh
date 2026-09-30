#!/usr/bin/env bash
# self-test.sh -- ticket-classify --epic, the Path part (DND-1057). Discovered
# by harness-gate (every committed `self-test.sh` runs).
#
# Two layers, in TDD order:
#   1. domain  -- ../lib/blocking.rb, loaded with ruby -e;
#   2. end to end -- the script against the loopback fake both ticket-classify
#      suites use (../fake-triage-server.py), standing in for Notion (reads
#      only) and the Athena server. Never prod: every URL is 127.0.0.1, and
#      both tokens, the MCP registry and the inbox client config are temp
#      fixtures.
#
# Cases marked [qa N] are DND-1057's QA Plan rows for ticket-classify.

set -u

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SKILL="$(cd -- "${HERE}/../.." && pwd -P)"
BIN="${SKILL}/scripts/ticket-classify"
LIB="${SKILL}/lib/blocking.rb"
FAKE="${SKILL}/test/fake-triage-server.py"
UNAVAILABLE_FIX="Fix: file the ticket as today; this is advisory."

PASS=0
FAIL=0
ok()   { PASS=$((PASS + 1)); printf 'ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL + 1)); printf 'FAIL %s\n' "$1"; [ -n "${2:-}" ] && printf '     %s\n' "$2"; return 0; }
eq()   { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$3], got [$2]"; fi; }
has()  { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "no [$3] in: $2" ;; esac; }
lacks() { case "$2" in *"$3"*) bad "$1" "unexpected [$3] in: $2" ;; *) ok "$1" ;; esac; }

[ -x /usr/bin/ruby ] || { echo "ticket-classify-epic self-test: FAIL -- /usr/bin/ruby is missing"; echo "  Fix: install the harness Ruby at /usr/bin/ruby (DND-931/958); this suite does not skip."; exit 1; }
for dep in python3 curl jq; do
  command -v "${dep}" >/dev/null 2>&1 || { echo "ticket-classify-epic self-test: FAIL -- ${dep} is not on PATH"; echo "  Fix: install ${dep}; this suite does not skip."; exit 1; }
done
[ -x "${BIN}" ] || { echo "ticket-classify-epic self-test: FAIL -- ${BIN} missing or not executable"; echo "  Fix: chmod +x ai/skills/athena:ticket-management/scripts/ticket-classify"; exit 1; }

TMP="$(mktemp -d)" || { echo "FAIL mktemp"; exit 1; }
SERVER_PID=""
cleanup() {
  [ -n "${SERVER_PID}" ] && kill "${SERVER_PID}" 2>/dev/null
  rm -rf "${TMP}"
}
trap cleanup EXIT INT TERM

# ruby_eq NAME EXPECTED RUBY-EXPR [ARG...] -- evaluate EXPR with blocking.rb loaded.
ruby_eq() {
  local name="$1" want="$2" expr="$3" got
  shift 3
  got="$(/usr/bin/ruby -rjson -e "require ARGV.shift; puts(begin; ${expr}; rescue ArgumentError => e; 'ArgumentError: ' + e.message; end)" "${LIB}" "$@" 2>&1)"
  eq "${name}" "${got}" "${want}"
}

# Fixture rows, as the Notion data source query returns them.
uuid() { printf '00000000-0000-4000-8000-%012d' "$1"; }
row() { # row NUMBER PATH STATUS
  jq -cn --arg id "$(uuid "$1")" --argjson n "$1" --arg p "$2" --arg s "$3" \
    '{id: $id, properties: {ID: {unique_id: {prefix: "DND", number: $n}}, Name: {title: [{plain_text: ("Critical \($n)")}]}, Path: {select: {name: $p}}, Status: {status: {name: $s}}}}'
}
rows() { jq -cs '{results: ., has_more: false}'; }

EPIC="3e6349da87fb817aacfbd72c30bf9986"
EPIC_DASHED="3e6349da-87fb-817a-acfb-d72c30bf9986"
TICKETS_DS="219349da-87fb-8063-8f36-000b362fbd60"
EPICS_DS="f4231817-18f3-4c2d-ac5b-b1151a5bb020"
# epic_page PARENT_DS -- a page as Notion's GET /v1/pages answers it.
epic_page() {
  jq -cn --arg ds "$1" --arg id "${EPIC_DASHED}" '{status: 200, body: {object: "page", id: $id, parent: {type: "data_source_id", data_source_id: $ds}, in_trash: false, properties: {Name: {type: "title", title: [{plain_text: "Jev judgments"}]}}}}'
}
EPIC_PAGE="$(epic_page "${EPICS_DS}")"

echo "== domain"

ruby_eq "epic_id: dashed or not, to dashed; anything else nil" \
  "${EPIC_DASHED}|${EPIC_DASHED}|nil|nil" \
  '[Blocking.epic_id(ARGV[0]), Blocking.epic_id(ARGV[1]), Blocking.epic_id("DND-5").inspect, Blocking.epic_id("zz").inspect].join("|")' "${EPIC}" "${EPIC_DASHED}"
ruby_eq "query_filter: the epic's relation AND Path Critical" \
  '{"and":[{"property":"Epic","relation":{"contains":"E"}},{"property":"Path","select":{"equals":"Critical"}}]}' \
  'JSON.generate(Blocking.query_filter("E")["filter"])'
ruby_eq "candidates: open Critical only, by ID ascending, at most 10 [qa 2]" \
  "DND-1,DND-2,DND-3,DND-4,DND-5,DND-6,DND-8,DND-9,DND-10,DND-11|11" \
  'r = JSON.parse(ARGV[0]); c = Blocking.candidates(r); [c[:chosen].map { |x| x[:ref] }.join(","), c[:open]].join("|")' \
  "$( { for n in 12 11 10 9 8 6 5 4 3 2 1; do row "$n" Critical "Not Started"; done; row 7 Critical Done; row 13 Off "Not Started"; row 14 Blocking "In Progress"; } | jq -cs .)"
ruby_eq "candidates: Cancelled and Won't Fix are closed too" \
  "|0" \
  'c = Blocking.candidates(JSON.parse(ARGV[0])); [c[:chosen].map { |x| x[:ref] }.join(","), c[:open]].join("|")' \
  "$( { row 1 Critical Cancelled; row 2 Critical "Won't Fix"; } | jq -cs .)"
ruby_eq "candidates: a row with no Path select is an error, never 'not a candidate'" \
  "ArgumentError: row 0 has no Path select (the tracker schema changed?)" \
  'Blocking.candidates([{"id" => "x", "properties" => {"ID" => {"unique_id" => {"prefix" => "DND", "number" => 1}}, "Status" => {"status" => {"name" => "Done"}}}}])'
ruby_eq "candidates: a row with no Status is an error, never read as open" \
  "ArgumentError: row 0 has no Status" \
  'Blocking.candidates([{"id" => "x", "properties" => {"ID" => {"unique_id" => {"prefix" => "DND", "number" => 1}}, "Path" => {"select" => {"name" => "Critical"}}}}])'
ruby_eq "summary: text blocks joined, cut to 800 characters" \
  "800|first" \
  'b = [{"type" => "paragraph", "paragraph" => {"rich_text" => [{"plain_text" => "first"}]}}, {"type" => "divider", "divider" => {}}, {"type" => "paragraph", "paragraph" => {"rich_text" => [{"plain_text" => "x" * 900}]}}]; s = Blocking.summary(b); [s.length, s.split("\n").first].join("|")'
ruby_eq "considered line: 0 is printed; a cut list says so" \
  "0 candidates considered (epic E, open Critical)|10 candidates considered (epic E, open Critical; the first 10 of 12 by ID)" \
  '[Blocking.considered_line([], 0, "E"), Blocking.considered_line([1] * 10, 12, "E")].join("|")'
ruby_eq "request body: only the finding, the candidates and the filer's three path fields" \
  'candidates,filer,finding|body,project,title|ref,summary,title|claimed_blocks,found_while,security' \
  'b = Blocking.request_body("T", "B", "harness", [{ref: "DND-1", title: "t", summary: "s", page_id: "p"}], {security: "none", found_while: "DND-9", claimed_blocks: "DND-1"}); [b.keys.sort, b["finding"].keys.sort, b["candidates"][0].keys.sort, b["filer"].keys.sort].map { |k| k.join(",") }.join("|")'
ruby_eq "request body: absent found_while and claim are not sent" \
  "security" \
  'Blocking.request_body("T", "B", "harness", [], {security: "none", found_while: nil, claimed_blocks: nil})["filer"].keys.join(",")'
ruby_eq "parse: a Blocks target outside the candidates is refused [qa 5]" \
  "ArgumentError: path.blocks is not one of the candidates" \
  'Blocking.parse_result({"status" => "judged", "path" => {"decided" => "Blocking", "blocks" => "DND-99", "source" => "jev"}, "provenance_line" => "Jev path: {}"}, ["DND-1"], {})'
ruby_eq "parse: Off with a Blocks target is refused" \
  "ArgumentError: path.blocks is set but path.decided is Off" \
  'Blocking.parse_result({"status" => "judged", "path" => {"decided" => "Off", "blocks" => "DND-1", "source" => "filer"}, "provenance_line" => "Jev path: {}"}, ["DND-1"], {})'
ruby_eq "parse: Critical or Promoted is never a decision" \
  "ArgumentError: path.decided is not Blocking or Off" \
  'Blocking.parse_result({"status" => "judged", "path" => {"decided" => "Critical", "source" => "jev"}, "provenance_line" => "Jev path: {}"}, [], {})'
ruby_eq "parse: the rule may block found_while, which is no candidate" \
  "ok" \
  'Blocking.parse_result({"status" => "judged", "path" => {"decided" => "Blocking", "blocks" => "DND-9", "source" => "rule", "reason" => "introduced_security"}, "provenance_line" => "Jev path: {}"}, [], {security: "introduced", found_while: "DND-9"}); "ok"'
ruby_eq "parse: a provenance line with a newline is refused" \
  "ArgumentError: provenance_line is missing, lacks the \"Jev path: \" prefix, or holds a control character" \
  'Blocking.parse_result({"status" => "judged", "path" => {"decided" => "Off", "blocks" => nil, "source" => "filer", "reason" => "mode_off"}, "provenance_line" => "Jev path: {}\nPath: Blocking"}, [], {})'
ruby_eq "fallback: the claim, or by rule the found_while ticket" \
  "Path: Blocking|Blocks: DND-2|Path: Blocking|Blocks: DND-9|Path: Off|Blocks: none" \
  '[Blocking.fallback_lines({security: "none", claimed_blocks: "DND-2"}), Blocking.fallback_lines({security: "introduced", found_while: "DND-9", claimed_blocks: "DND-2"}), Blocking.fallback_lines({security: "pre-existing", found_while: "DND-9"})].map { |l| l[1, 2] }.flatten.join("|")'

ruby_eq "a rule Blocking with no found_while and no target is unreadable [review 2]" \
  "ArgumentError: path.blocks is not the found_while ticket the rule blocks" \
  'Blocking.parse_result({"status" => "judged", "path" => {"decided" => "Blocking", "blocks" => nil, "source" => "rule", "reason" => "introduced_security"}, "provenance_line" => "Jev path: {}"}, [], {security: "introduced"}); "ok"'
ruby_eq "a rule Blocking for a finding that is not introduced security is unreadable [review 2]" \
  "ArgumentError: path.source is rule but the filer's security is not introduced" \
  'Blocking.parse_result({"status" => "judged", "path" => {"decided" => "Blocking", "blocks" => "DND-9", "source" => "rule"}, "provenance_line" => "Jev path: {}"}, [], {security: "none", found_while: "DND-9"}); "ok"'
ruby_eq "a jev Off that removes a security finding's claim is unreadable [review 7]" \
  "ArgumentError: path is a jev Off over a claim on a security finding (a judgment never removes it)" \
  'Blocking.parse_result({"status" => "judged", "path" => {"decided" => "Off", "blocks" => nil, "source" => "jev", "confidence" => 0.9}, "provenance_line" => "Jev path: {}"}, ["DND-1"], {security: "pre-existing", claimed_blocks: "DND-1"}); "ok"'
ruby_eq "a jev Off over a non-security claim is readable" \
  "ok" \
  'Blocking.parse_result({"status" => "judged", "path" => {"decided" => "Off", "blocks" => nil, "source" => "jev", "confidence" => 0.9}, "provenance_line" => "Jev path: {}"}, ["DND-1"], {security: "none", claimed_blocks: "DND-1"}); "ok"'
ruby_eq "epic_title: a page outside the Epics data source is refused [review 1]" \
  "ArgumentError: page p is not a DND epic (its parent is data source 219349da-87fb-8063-8f36-000b362fbd60); pass the epic's page id" \
  'Blocking.epic_title({"id" => "p", "parent" => {"data_source_id" => "219349da-87fb-8063-8f36-000b362fbd60"}, "properties" => {"Name" => {"type" => "title", "title" => [{"plain_text" => "T"}]}}}, "f4231817-18f3-4c2d-ac5b-b1151a5bb020")'
ruby_eq "epic_title: a trashed epic is refused" \
  "ArgumentError: epic page p is in the trash" \
  'Blocking.epic_title({"id" => "p", "in_trash" => true, "parent" => {"data_source_id" => "E"}, "properties" => {"Name" => {"type" => "title", "title" => [{"plain_text" => "T"}]}}}, "E")'
ruby_eq "epic_title: an epic page gives its title" \
  "T" \
  'Blocking.epic_title({"id" => "p", "parent" => {"data_source_id" => "E"}, "properties" => {"Name" => {"type" => "title", "title" => [{"plain_text" => "T"}]}}}, "E")'

echo "== end to end"

ATHENA_TOKEN="epic-athena-token-$$-${RANDOM}-8c1d"
NOTION_TOKEN="epic-notion-token-$$-${RANDOM}-4f07"
printf '%s\n' "${ATHENA_TOKEN}" > "${TMP}/athena-token"
printf '%s\n' "${NOTION_TOKEN}" > "${TMP}/notion-token"
mkdir -p "${TMP}/cfg" "${TMP}/spec" "${TMP}/home"
jq -n --arg t "${ATHENA_TOKEN}" '{server_url: "wss://example.invalid/machine/websocket", token: $t}' > "${TMP}/cfg/config.json"
chmod 600 "${TMP}/cfg/config.json"
export ATHENA_INBOX_CLIENT_CONFIG="${TMP}/cfg/config.json"
export FLEET_CLAUDE_JSON="${TMP}/claude.json"
export TICKET_CLASSIFY_PACE_S=0
: > "${TMP}/server.log"

python3 "${FAKE}" "${TMP}/port" "${TMP}/server.log" "${TMP}/spec" "${TMP}/athena-token" "${TMP}/notion-token" &
SERVER_PID=$!
for _i in $(seq 1 100); do
  [ -s "${TMP}/port" ] && break
  sleep 0.05
done
[ -s "${TMP}/port" ] || { echo "FAIL fake server did not start"; exit 1; }
PORT="$(cat "${TMP}/port")"
export TICKET_CLASSIFY_NOTION_API="http://127.0.0.1:${PORT}"
jq -n --arg u "http://127.0.0.1:${PORT}/mcp" --arg f "${TMP}/notion-token" \
  '{mcpServers: {athena: {type: "http", url: $u}, "notion-personal": {env: {NOTION_ATHENA_TOKEN_FILE: $f}}}}' > "${FLEET_CLAUDE_JSON}"

spec() { printf '%s\n' "$2" > "${TMP}/spec/$1"; }
athena_paths() { jq -rs '[.[] | select(.service == "athena") | .path] | join(",")' "${TMP}/server.log"; }
blocking_sent() { jq -c 'select(.path == "/api/v1/judgments/ticket_blocking") | .body' "${TMP}/server.log" | tail -n 1; }
notion_count() { jq -s '[.[] | select(.service == "notion")] | length' "${TMP}/server.log"; }

printf 'The gate reads empty when its lookup key is wrong. SYNTHETIC-FINDING\n' > "${TMP}/body.txt"
run() {
  : > "${TMP}/server.log"
  OUT="$(HOME="${TMP}/home" "${BIN}" "$@" 2>"${TMP}/err")"
  RC=$?
  ERR="$(cat "${TMP}/err")"
}
TICKET=(--title "Gate reads empty on a wrong key" --body-file "${TMP}/body.txt" --project harness)
FILER=(--kind Bug --severity MEDIUM --security none)

PROV_CLASSIFY='Jev classification: {"kind":{"value":"Bug","source":"filer"}}'
OFF_CLASSIFY="$(jq -cn --arg p "${PROV_CLASSIFY}" '{status: "judged", properties: {kind: {decided: "Bug", source: "filer", judged: null, accepted: false, reason: "mode_off", mode: "off"}, severity: {decided: "MEDIUM", source: "filer", judged: null, accepted: false, reason: "mode_off", mode: "off"}, security: {decided: "none", source: "filer", judged: null, accepted: false, reason: "mode_off", mode: "off"}}, would_decide: null, provenance_line: $p}')"
spec classify.json "$(jq -cn --argjson b "${OFF_CLASSIFY}" '{status: 200, body: $b}')"

# The epic page, three open Critical tickets (one Done, one Off excluded).
spec "page-${EPIC_DASHED}.json" "${EPIC_PAGE}"
spec "query-${TICKETS_DS}.json" "$(jq -cn --argjson b "$( { row 717 Critical "Not Started"; row 700 Critical "In Progress"; row 710 Critical Done; row 720 Off "Not Started"; row 730 Critical Parked; } | rows)" '{status: 200, body: $b}')"
spec blocks.json '{"status":200,"body":{"results":[{"type":"paragraph","paragraph":{"rich_text":[{"plain_text":"Requirement: route by session."}]}}],"has_more":false}}'

PROV_PATH='Jev path: {"path":{"value":"Blocking","blocks":"DND-717","source":"filer","reason":"mode_off","mode":"off","confidence":null},"candidates":3,"model":"jev-1.13.0","version":"ticket-blocking-v1"}'
path_body() { # path_body DECIDED BLOCKS SOURCE REASON CONFIDENCE LINE
  jq -cn --arg d "$1" --argjson b "$2" --arg s "$3" --argjson r "$4" --argjson c "$5" --arg p "$6" \
    '{status: 200, body: {status: "judged", path: {decided: $d, blocks: $b, source: $s, reason: $r, mode: "off", confidence: $c}, candidates: [], would_decide: null, provenance_line: $p}}'
}
spec blocking.json "$(path_body Blocking '"DND-717"' filer '"mode_off"' null "${PROV_PATH}")"

run "${TICKET[@]}" "${FILER[@]}" --epic "${EPIC}" --found-while DND-600 --blocks DND-717
eq "modes off with a claim: exit 0 [acceptance]" "${RC}" "0"
eq "modes off: classification, count, the filer's claim, the path line verbatim [acceptance; qa 5]" \
  "${OUT}" "Kind: Bug (filer: mode_off)
Severity: MEDIUM (filer: mode_off)
Security: none (filer: mode_off)
${PROV_CLASSIFY}
3 candidates considered (epic Jev judgments, open Critical)
Path: Blocking (filer: mode_off)
Blocks: DND-717
${PROV_PATH}"
eq "both endpoints were called, classification first" "$(athena_paths)" "/api/v1/judgments/ticket_classification,/api/v1/judgments/ticket_blocking"
eq "the blocking body: the finding, 3 open Critical candidates by ID, the filer's claim [qa 2]" \
  "$(blocking_sent | jq -c '{f: .finding.project, c: [.candidates[].ref], s: [.candidates[].summary] | unique, filer: .filer}')" \
  '{"f":"harness","c":["DND-700","DND-717","DND-730"],"s":["Requirement: route by session."],"filer":{"security":"none","found_while":"DND-600","claimed_blocks":"DND-717"}}'
eq "only reads reached Notion: one page, one query, one block list per candidate [qa 6]" \
  "$(jq -rs '[.[] | select(.service == "notion") | .method + " " + (.path | sub("[0-9a-f-]{36}"; "ID") | sub("\\?.*"; ""))] | join(",")' "${TMP}/server.log")" \
  "GET /v1/pages/ID,POST /v1/data_sources/ID/query,GET /v1/blocks/ID/children,GET /v1/blocks/ID/children,GET /v1/blocks/ID/children"
eq "the query filtered by the epic and Path Critical" \
  "$(jq -c 'select(.method == "POST" and .service == "notion") | .body.filter' "${TMP}/server.log")" \
  "{\"and\":[{\"property\":\"Epic\",\"relation\":{\"contains\":\"${EPIC_DASHED}\"}},{\"property\":\"Path\",\"select\":{\"equals\":\"Critical\"}}]}"
eq "nothing unexpected reached the fake (no write) [qa 6]" "$(jq -s '[.[] | select(.unexpected)] | length' "${TMP}/server.log")" "0"
eq "every request carried its own service's token" "$(jq -s '[.[] | select(.auth_ok | not)] | length' "${TMP}/server.log")" "0"
eq "no token was in any process's argv" "$(jq -s '[.[] | .argv_leak[]] | length' "${TMP}/server.log")" "0"
eq "no token was in any process's environment" "$(jq -s '[.[] | .environ_leak[]] | length' "${TMP}/server.log")" "0"
eq "no file was written under HOME" "$(find "${TMP}/home" -mindepth 1 | wc -l | tr -d ' ')" "0"

spec blocking.json "$(path_body Blocking '"DND-730"' jev null 0.96 'Jev path: {"path":{"value":"Blocking","blocks":"DND-730","source":"jev"}}')"
run "${TICKET[@]}" "${FILER[@]}" --epic "${EPIC_DASHED}"
eq "a jev decision exits 0" "${RC}" "0"
has "it prints the edge to wire with Jev's confidence [qa 5]" "${OUT}" "Path: Blocking (jev 0.96)
Blocks: DND-730
Jev path: "

spec blocking.json "$(path_body Off null filer '"no_blocks_judged"' null 'Jev path: {"path":{"value":"Off"}}')"
run "${TICKET[@]}" "${FILER[@]}" --epic "${EPIC}"
has "Off wires no edge" "${OUT}" "Path: Off (filer: no_blocks_judged)
Blocks: none"

spec blocking.json "$(path_body Blocking '"DND-600"' rule '"introduced_security"' null 'Jev path: {"path":{"value":"Blocking","blocks":"DND-600","source":"rule"}}')"
run "${TICKET[@]}" --kind Vulnerability --severity HIGH --security introduced --epic "${EPIC}" --found-while DND-600
eq "introduced security exits 0" "${RC}" "0"
has "the rule blocks found_while [R1057-2]" "${OUT}" "Path: Blocking (rule: introduced_security)
Blocks: DND-600"
eq "the rule's request still carries found_while" "$(blocking_sent | jq -c .filer)" '{"security":"introduced","found_while":"DND-600"}'

echo "== a Feature is never sent [qa 1]"

spec classify.json "$(jq -cn --argjson b "${OFF_CLASSIFY}" '{status: 200, body: ($b | .properties.kind.decided = "Feature" | .properties.severity = {decided: null, source: "filer", judged: null, accepted: false, reason: "feature", mode: "off"})}')"
run --title "New feature" --body-file "${TMP}/body.txt" --project harness --kind Feature --severity none --security none --epic "${EPIC}"
spec classify.json "$(jq -cn --argjson b "${OFF_CLASSIFY}" '{status: 200, body: $b}')"
eq "a Feature with --epic exits 0" "${RC}" "0"
eq "only the classification endpoint was called" "$(athena_paths)" "/api/v1/judgments/ticket_classification"
eq "and Notion was not read" "$(notion_count)" "0"
lacks "no Path line" "${OUT}" "Path:"
has "stderr says the Path is authored" "${ERR}" "its Path is authored, never judged"

echo "== zero candidates [qa 3]"

spec "query-${TICKETS_DS}.json" "$(jq -cn --argjson b "$( { row 720 Off "Not Started"; row 710 Critical Done; } | rows)" '{status: 200, body: $b}')"
spec blocking.json "$(path_body Off null filer '"no_candidates"' null 'Jev path: {"path":{"value":"Off","candidates":0}}')"
run "${TICKET[@]}" "${FILER[@]}" --epic "${EPIC}"
eq "an epic with no open Critical ticket exits 0" "${RC}" "0"
has "0 candidates considered is printed, not silent [qa 3]" "${OUT}" "0 candidates considered (epic Jev judgments, open Critical)"
eq "the server is still asked, with no candidates" "$(blocking_sent | jq -c .candidates)" "[]"
run "${TICKET[@]}" "${FILER[@]}" --epic "${EPIC}" --blocks DND-717
eq "--blocks with no candidate is usage (2)" "${RC}" "2"
has "it names the considered list" "${ERR}" "--blocks DND-717 is not one of the epic's open Critical tickets considered (none). Fix: "
eq "nothing was sent to the Athena server" "$(athena_paths)" ""

echo "== ten at most"

spec "query-${TICKETS_DS}.json" "$(jq -cn --argjson b "$(for n in 12 3 11 1 10 2 9 8 7 6 5 4; do row "$n" Critical "Not Started"; done | rows)" '{status: 200, body: $b}')"
spec blocking.json "$(path_body Off null filer '"mode_off"' null 'Jev path: {}')"
run "${TICKET[@]}" "${FILER[@]}" --epic "${EPIC}"
has "a cut list says how many were open [qa 2]" "${OUT}" "10 candidates considered (epic Jev judgments, open Critical; the first 10 of 12 by ID)"
eq "the first 10 by ID are sent [qa 2]" "$(blocking_sent | jq -c '[.candidates[].ref]')" '["DND-1","DND-2","DND-3","DND-4","DND-5","DND-6","DND-7","DND-8","DND-9","DND-10"]'

echo "== unavailable"

spec "query-${TICKETS_DS}.json" '{"status":500,"body":{"object":"error"}}'
run "${TICKET[@]}" "${FILER[@]}" --epic "${EPIC}" --blocks DND-717
eq "a failed Notion read exits 3 [qa 4]" "${RC}" "3"
has "Kind, Severity and Security still print [qa 4]" "${OUT}" "Kind: Bug (filer: mode_off)
Severity: MEDIUM (filer: mode_off)
Security: none (filer: mode_off)
${PROV_CLASSIFY}"
has "the read failure is CANDIDATES UNAVAILABLE with Fix:, never 0 [qa 4]" "${OUT}" "CANDIDATES UNAVAILABLE: Notion answered HTTP 500"
has "the line ends with the unavailable Fix:" "$(printf '%s\n' "${OUT}" | grep '^CANDIDATES UNAVAILABLE')" "${UNAVAILABLE_FIX}"
lacks "no candidate count is printed" "${OUT}" "candidates considered"
has "the filer's own Path follows" "${OUT}" "Decided (filer; path unavailable):
Path: Blocking
Blocks: DND-717"
lacks "no path provenance line (never reads as a decision)" "${OUT}" "Jev path:"
eq "the blocking endpoint was not called" "$(athena_paths)" "/api/v1/judgments/ticket_classification"

spec "query-${TICKETS_DS}.json" "$(jq -cn --argjson b "$(jq -cn '{id: "x", properties: {ID: {unique_id: {prefix: "DND", number: 5}}, Status: {status: {name: "Not Started"}}}}' | rows)" '{status: 200, body: $b}')"
run "${TICKET[@]}" "${FILER[@]}" --epic "${EPIC}"
eq "a row with no Path property exits 3" "${RC}" "3"
has "it is CANDIDATES UNAVAILABLE naming the row" "${OUT}" "CANDIDATES UNAVAILABLE: a tracker row could not be read: row 0 has no Path select"

spec "page-${EPIC_DASHED}.json" '{"status":404,"body":{"object":"error"}}'
run "${TICKET[@]}" --kind Vulnerability --severity HIGH --security introduced --epic "${EPIC}" --found-while DND-600
eq "an unreadable epic page exits 3" "${RC}" "3"
has "it is CANDIDATES UNAVAILABLE" "${OUT}" "CANDIDATES UNAVAILABLE: Notion answered HTTP 404"
has "the fallback applies the introduced rule" "${OUT}" "Path: Blocking
Blocks: DND-600"
spec "page-${EPIC_DASHED}.json" "${EPIC_PAGE}"
spec "query-${TICKETS_DS}.json" "$(jq -cn --argjson b "$( { row 717 Critical "Not Started"; row 700 Critical "In Progress"; } | rows)" '{status: 200, body: $b}')"

spec "page-${EPIC_DASHED}.json" "$(epic_page "${TICKETS_DS}")"
run "${TICKET[@]}" "${FILER[@]}" --epic "${EPIC}"
eq "a ticket's page id passed as --epic exits 3, never 0 candidates [review 1]" "${RC}" "3"
has "it is CANDIDATES UNAVAILABLE naming the wrong parent" "${OUT}" "CANDIDATES UNAVAILABLE: page ${EPIC_DASHED} is not a DND epic"
lacks "no candidate count is printed for a wrong key" "${OUT}" "candidates considered"
eq "and Notion's ticket rows were never queried" "$(jq -s '[.[] | select(.service == "notion" and .method == "POST")] | length' "${TMP}/server.log")" "0"
spec "page-${EPIC_DASHED}.json" "${EPIC_PAGE}"

spec blocks.json '{"status":200,"body":{"object":"list","has_more":false}}'
run "${TICKET[@]}" "${FILER[@]}" --epic "${EPIC}"
eq "a block list with no results exits 3, never a blank summary [review 4]" "${RC}" "3"
has "it is CANDIDATES UNAVAILABLE" "${OUT}" "CANDIDATES UNAVAILABLE: "
eq "the blocking endpoint was not called" "$(athena_paths)" "/api/v1/judgments/ticket_classification"
spec blocks.json '{"status":200,"body":{"results":[{"type":"paragraph","paragraph":{"rich_text":[{"plain_text":"Requirement: route by session."}]}}],"has_more":false}}'

spec blocking.json '{"status":422,"body":{"error":"unprocessable_entity","fix":"filer.claimed_blocks is not one of the candidates. Fix: --blocks must name an open Critical ticket of the epic."}}'
run "${TICKET[@]}" "${FILER[@]}" --epic "${EPIC}" --blocks DND-700
eq "a 422 from the blocking endpoint exits 3" "${RC}" "3"
has "it is PATH UNAVAILABLE with the server's Fix:" "${OUT}" "PATH UNAVAILABLE: SERVER REFUSED THE REQUEST: HTTP 422 unprocessable_entity: filer.claimed_blocks is not one of the candidates. Fix: --blocks must name an open Critical ticket of the epic. ${UNAVAILABLE_FIX}"
has "the classification is still decided" "${OUT}" "${PROV_CLASSIFY}"

spec blocking.json '{"status":404,"body":{"error":"not_found"}}'
run "${TICKET[@]}" "${FILER[@]}" --epic "${EPIC}"
has "a 404 names the undeployed endpoint" "${OUT}" "PATH UNAVAILABLE: SERVER REFUSED THE REQUEST: HTTP 404 not_found: this server does not serve ticket_blocking (DND-1057 not deployed?). ${UNAVAILABLE_FIX}"
has "and falls back to Off with no claim" "${OUT}" "Decided (filer; path unavailable):
Path: Off
Blocks: none"

spec blocking.json "$(path_body Blocking '"DND-999"' jev null 0.9 'Jev path: {}')"
run "${TICKET[@]}" "${FILER[@]}" --epic "${EPIC}"
eq "a Blocks target outside the candidates exits 3" "${RC}" "3"
has "it is an unreadable answer, never wired" "${OUT}" "PATH UNAVAILABLE: UNREADABLE SERVER ANSWER: HTTP 200 but path.blocks is not one of the candidates. ${UNAVAILABLE_FIX}"
lacks "the bad target is never printed as a decision" "${OUT}" "Blocks: DND-999"

echo "== argv"

run "${TICKET[@]}" "${FILER[@]}" --blocks DND-1
eq "--blocks without --epic is usage (2)" "${RC}" "2"
has "it says so with Fix:" "${ERR}" "--blocks needs --epic. Fix: "
run "${TICKET[@]}" "${FILER[@]}" --found-while DND-1
eq "--found-while without --epic is usage (2)" "${RC}" "2"
run "${TICKET[@]}" "${FILER[@]}" --epic "${EPIC}" --ref DND-4
eq "--epic with --ref is usage (2): a reclassification never judges Path" "${RC}" "2"
run "${TICKET[@]}" "${FILER[@]}" --epic "${EPIC}" --json
eq "--epic with --json is usage (2)" "${RC}" "2"
run "${TICKET[@]}" "${FILER[@]}" --epic DND-5
eq "an epic that is not a page id is usage (2)" "${RC}" "2"
run "${TICKET[@]}" "${FILER[@]}" --epic "${EPIC}" --blocks dnd-717
eq "a --blocks that is not a ticket id is usage (2)" "${RC}" "2"
run "${TICKET[@]}" "${FILER[@]}" --epic "${EPIC}" --blocks DND-999
eq "--blocks outside the candidates is usage (2)" "${RC}" "2"
has "it lists the candidates considered" "${ERR}" "(DND-700, DND-717)"
eq "no usage failure sent anything to the Athena server" "$(athena_paths)" ""

echo
echo "ticket-classify-epic self-test: ${PASS} passed, ${FAIL} failed"
[ "${FAIL}" -eq 0 ]
