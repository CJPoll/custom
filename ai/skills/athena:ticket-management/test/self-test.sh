#!/usr/bin/env bash
# self-test.sh -- the finding-triage suite (DND-713). Discovered by harness-gate
# (every committed `self-test.sh` runs).
#
# Two layers, in TDD order:
#   1. domain  -- the script's pure Triage module, loaded with ruby -e (the
#      script only runs main when it IS the program);
#   2. end to end -- the script against ONE loopback fake (fake-triage-server.py)
#      standing in for both Notion and the Athena server. Never prod: every URL
#      is 127.0.0.1, and both tokens, the MCP registry and the token file are
#      temp fixtures.
#
# The QA Plan's script cases are marked [qa]: "0 candidates considered" printed
# explicitly; exit 3 with Fix: on not_configured; exit 3 on an unreachable
# server as a DISTINCT line from not_configured; exit 2 on bad args; --help
# exit 0 on stdout; the body file read only when given. The ticket's
# acceptance is marked [ticket]: no code path to a Notion write; the pinned
# unavailable line. Plus: neither token reaches argv or env.

set -u

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SKILL="$(cd -- "${HERE}/.." && pwd -P)"
BIN="${SKILL}/scripts/finding-triage"
FAKE="${HERE}/fake-triage-server.py"
# The inert line, read from the contract's pin (the other side of the pin is
# ai/contracts/test/self-test.sh, which checks the contract quotes it).
PIN_FILE="$(cd -- "${SKILL}/../../contracts/fixtures" && pwd -P)/athena-judgments-quoted-fix.txt"
PINNED="$(grep '^JUDGMENTS UNAVAILABLE: not_configured\.' "${PIN_FILE}" 2>/dev/null)"
[ -n "${PINNED}" ] || { echo "finding-triage self-test: FAIL -- no pinned not_configured line in ${PIN_FILE}"; echo "  Fix: restore the line in the contract fixture; the suite does not guess it."; exit 1; }
PROJECTS_DS="3e2349da-87fb-809a-a93e-000b167fd855"
TICKETS_DS="219349da-87fb-8063-8f36-000b362fbd60"

PASS=0
FAIL=0
ok()   { PASS=$((PASS + 1)); printf 'ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL + 1)); printf 'FAIL %s\n' "$1"; [ -n "${2:-}" ] && printf '     %s\n' "$2"; return 0; }
eq()   { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$3], got [$2]"; fi; }
has()  { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "no [$3] in: $2" ;; esac; }
lacks() { case "$2" in *"$3"*) bad "$1" "unexpected [$3] in: $2" ;; *) ok "$1" ;; esac; }

for dep in ruby python3 curl jq git; do
  command -v "${dep}" >/dev/null 2>&1 || { echo "finding-triage self-test: FAIL -- ${dep} is not on PATH"; echo "  Fix: install ${dep}; this suite does not skip."; exit 1; }
done
[ -x "${BIN}" ] || { echo "finding-triage self-test: FAIL -- ${BIN} missing or not executable"; echo "  Fix: chmod +x ai/skills/athena:ticket-management/scripts/finding-triage"; exit 1; }

TMP="$(mktemp -d)" || { echo "FAIL mktemp"; exit 1; }
SERVER_PID=""
cleanup() {
  [ -n "${SERVER_PID}" ] && kill "${SERVER_PID}" 2>/dev/null
  rm -rf "${TMP}"
}
trap cleanup EXIT INT TERM

# ruby_eq NAME EXPECTED RUBY-EXPR -- evaluate EXPR with the script loaded.
ruby_eq() {
  local got
  got="$(ruby -e "load ARGV.shift; puts(begin; $3; rescue ArgumentError => e; 'ArgumentError: ' + e.message; end)" "${BIN}" 2>&1)"
  eq "$1" "${got}" "$2"
}

echo "== domain"

ruby_eq "keywords: the severity prefix and stopwords dropped, longest first" \
  "cannot,passes,check,gate" \
  'Triage.keywords("HIGH: gate passes when the check cannot run").join(",")'
ruby_eq "keywords: a title of short words has none" \
  "" \
  'Triage.keywords("LOW: a b c fix it").join(",")'
ruby_eq "filter: epic AND keyword AND (open OR edited since), two levels deep" \
  "3|Epic:e1,Epic:e2|Name:gate|Status,Status,Status,Status,last_edited_time>=2026-06-29" \
  'f = Triage.tickets_filter(%w[e1 e2], %w[gate], "2026-06-29"); a = f["and"]; [a.size.to_s, a[0]["or"].map { |c| "Epic:" + c["relation"]["contains"] }.join(","), a[1]["or"].map { |c| "Name:" + c["title"]["contains"] }.join(","), a[2]["or"].map { |c| c["property"] || (c["timestamp"] + ">=" + c["last_edited_time"]["on_or_after"]) }.join(",")].join("|")'
ruby_eq "since: 90 days back, as a date" \
  "2026-06-29" \
  'Triage.since(Time.utc(2026, 9, 27, 12))'
ruby_eq "epic_ids: the project's epics; a mapped Repo / App no row has is MISSING, never empty" \
  "e1,e2|gen_saas/apps/athena|true" \
  'rows = [{"properties"=>{"Repo / App"=>{"select"=>{"name"=>"gen_saas / Athena"}},"Epics"=>{"relation"=>[{"id"=>"e1"},{"id"=>"e2"}],"has_more"=>true}}}]; r = Triage.epic_ids(rows, "athena"); [r[:ids].join(","), r[:missing].join(","), r[:truncated]].join("|")'
ruby_eq "ticket: ref from the unique id, title from the Name" \
  "DND-12|Gate passes|p1" \
  't = Triage.ticket({"id"=>"p1","properties"=>{"ID"=>{"unique_id"=>{"prefix"=>"DND","number"=>12}},"Name"=>{"title"=>[{"plain_text"=>"Gate passes"}]}}}); [t[:ref], t[:title], t[:page_id]].join("|")'
ruby_eq "summary: the first blocks' text, at most 500 characters" \
  "500|One two" \
  '[Triage.summary([{"type"=>"paragraph","paragraph"=>{"rich_text"=>[{"plain_text"=>"x" * 600}]}}]).length, Triage.summary([{"type"=>"paragraph","paragraph"=>{"rich_text"=>[{"plain_text"=>"One"}]}},{"type"=>"divider","divider"=>{}},{"type"=>"heading_2","heading_2"=>{"rich_text"=>[{"plain_text"=>" two "}]}}])].join("|")'
ruby_eq "request body: body cut to 2,000, candidates to 20, only the contract's keys" \
  "2000|20|body,project,title|ref,summary,title" \
  'b = Triage.request_body("T", "y" * 2500, "harness", (1..25).map { |i| {ref: "DND-#{i}", title: "t", summary: "s"} }); [b["finding"]["body"].length, b["candidates"].size, b["finding"].keys.sort.join(","), b["candidates"][0].keys.sort.join(",")].join("|")'
ruby_eq "considered: 0 candidates is said, never silence [qa]" \
  "0 candidates considered (x)" \
  'Triage.considered_line(0, "x")'
ruby_eq "candidates file: a repeated ref is refused by position" \
  "ArgumentError: entry 1 repeats an earlier ref" \
  'Triage.parse_candidates_file(%([{"ref":"DND-1","title":"a"},{"ref":"DND-1","title":"b"}]))'
ruby_eq "candidates file: a ref that is text is refused, never echoed" \
  "ArgumentError: entry 0 has a ref that is not an opaque id (e.g. DND-123)" \
  'Triage.parse_candidates_file(%([{"ref":"SECRET words here","title":"a"}]))'
ruby_eq "advisory: only duplicate/related AT OR ABOVE threshold, then the severity" \
  "3|  DND-5: duplicate (confidence 0.93) -- Five|  severity suggestion: HIGH (confidence 0.55; a suggestion, not calibrated)" \
  'l = Triage.advisory_lines({"mode"=>"on","thresholds"=>{"duplicate"=>"enabled","related"=>"enabled"},"question_set_version"=>"v1","model"=>"m","candidates"=>[{"ref"=>"DND-5","relation"=>"duplicate","confidence"=>0.93,"above_threshold"=>true},{"ref"=>"DND-6","relation"=>"related","confidence"=>0.4,"above_threshold"=>false},{"ref"=>"DND-7","relation"=>"unrelated","confidence"=>0.99,"above_threshold"=>true}],"severity"=>{"level"=>"HIGH","confidence"=>0.55}}, {"DND-5"=>"Five"}); [l.size, l[1], l[2]].join("|")'
ruby_eq "advisory: none above threshold is said" \
  "  no candidate is a duplicate or related at or above its threshold." \
  'Triage.advisory_lines({"mode"=>"on","thresholds"=>{"duplicate"=>"enabled","related"=>"enabled"},"candidates"=>[],"severity"=>{"level"=>"LOW","confidence"=>1}}, {})[1]'
ruby_eq "advisory: an n/a relation says insufficient evidence, and only enabled ones are advised [DND-714]" \
  "4|  duplicate: insufficient evidence (n/a: the eval could not calibrate it); not advised.|  DND-6: related (confidence 0.97) -- Six" \
  'l = Triage.advisory_lines({"mode"=>"on","thresholds"=>{"duplicate"=>"n_a","related"=>"enabled"},"candidates"=>[{"ref"=>"DND-5","relation"=>"duplicate","confidence"=>0.99,"above_threshold"=>false},{"ref"=>"DND-6","relation"=>"related","confidence"=>0.97,"above_threshold"=>true}],"severity"=>{"level"=>"LOW","confidence"=>1}}, {"DND-6"=>"Six"}); [l.size, l[1], l[2]].join("|")'
ruby_eq "advisory: no hit names only the enabled relations [DND-714]" \
  "  no candidate is related at or above its threshold." \
  'Triage.advisory_lines({"mode"=>"on","thresholds"=>{"duplicate"=>"n_a","related"=>"enabled"},"candidates"=>[],"severity"=>{"level"=>"LOW","confidence"=>1}}, {})[2]'
ruby_eq "advisory: an unset relation says insufficient evidence (no threshold) [DND-714]" \
  "  related: insufficient evidence (no threshold); not advised." \
  'Triage.advisory_lines({"mode"=>"on","thresholds"=>{"duplicate"=>"enabled","related"=>"unset"},"candidates"=>[],"severity"=>{"level"=>"LOW","confidence"=>1}}, {})[1]'
ruby_eq "advisory: no threshold state from the server is said, never read as enabled [DND-714]" \
  "  duplicate: threshold state not reported by the server; treat as insufficient evidence.|  related: threshold state not reported by the server; treat as insufficient evidence.|4" \
  'l = Triage.advisory_lines({"mode"=>"on","candidates"=>[{"ref"=>"DND-5","relation"=>"duplicate","confidence"=>0.99,"above_threshold"=>true}],"severity"=>{"level"=>"LOW","confidence"=>1}}, {}); [l[1], l[2], l.size - 1].join("|")'
ruby_eq "advisory: shadow mode advises nothing" \
  "2|  mode shadow: judged and recorded; nothing is advised until the mode is on." \
  'l = Triage.advisory_lines({"mode"=>"shadow","candidates"=>[{"ref"=>"DND-5","relation"=>"duplicate","confidence"=>1,"above_threshold"=>true}],"severity"=>{"level"=>"LOW","confidence"=>1}}, {}); [l.size, l[1]].join("|")'
ruby_eq "security hint: a security word in the title or body" \
  "true|false" \
  '[Triage.security_hint?("HIGH: token printed in argv", ""), Triage.security_hint?("LOW: stale docs", "typo")].join("|")'

echo "== no code path to a Notion write [ticket]"

ruby_eq "the Notion effect admits only the two reads" \
  "true,true,false,false,false,false,false,false" \
  'id = "219349da-87fb-8063-8f36-000b362fbd60"; [["POST", "/v1/data_sources/#{id}/query"], ["GET", "/v1/blocks/#{id}/children?page_size=10"], ["PATCH", "/v1/pages/#{id}"], ["POST", "/v1/pages"], ["POST", "/v1/comments"], ["PATCH", "/v1/blocks/#{id}/children"], ["DELETE", "/v1/blocks/#{id}"], ["POST", "/v1/data_sources/#{id}"]].map { |m, p| Effects.notion_read?(m, p) }.join(",")'
ruby_eq "a refused Notion request raises before anything is sent" \
  "3|refused a Notion PATCH" \
  'begin; Effects.notion_read("http://127.0.0.1:9", "t", "PATCH", "/v1/pages/219349da-87fb-8063-8f36-000b362fbd60", {}); rescue Failure => e; [e.code, e.message[/refused a Notion PATCH/]].join("|"); end'
calls="$(grep -o 'Effects.notion_read([^)]*' "${BIN}" | grep -v 'def ' | sed 's/.*token, //' | sort -u | tr '\n' ';')"
eq "every Notion call site in the script is a POST query or a GET children" \
  "${calls}" \
  '"GET", "/v1/blocks/#{t[:page_id]}/children?page_size=10";"POST", "/v1/data_sources/#{Triage::PROJECTS_DATA_SOURCE}/query", { "page_size" => 100 };"POST", "/v1/data_sources/#{Triage::TICKETS_DATA_SOURCE}/query", query;'
lacks "the script names no Notion write endpoint" "$(grep -v '^\s*#' "${BIN}" | grep -n '/v1/pages\|/v1/comments' || true)" "/v1/"

echo "== end to end"

ATHENA_TOKEN="triage-athena-token-$$-${RANDOM}-7a1f"
NOTION_TOKEN="triage-notion-token-$$-${RANDOM}-3c9d"
printf '%s\n' "${ATHENA_TOKEN}" > "${TMP}/athena-token"
printf '%s\n' "${NOTION_TOKEN}" > "${TMP}/notion-token"
chmod 600 "${TMP}/notion-token"
mkdir -p "${TMP}/cfg" "${TMP}/spec"
jq -n --arg t "${ATHENA_TOKEN}" '{server_url: "wss://example.invalid/machine/websocket", token: $t}' > "${TMP}/cfg/config.json"
chmod 600 "${TMP}/cfg/config.json"
export ATHENA_INBOX_CLIENT_CONFIG="${TMP}/cfg/config.json"
export FLEET_CLAUDE_JSON="${TMP}/claude.json"
: > "${TMP}/server.log"

python3 "${FAKE}" "${TMP}/port" "${TMP}/server.log" "${TMP}/spec" "${TMP}/athena-token" "${TMP}/notion-token" &
SERVER_PID=$!
for _i in $(seq 1 100); do
  [ -s "${TMP}/port" ] && break
  sleep 0.05
done
[ -s "${TMP}/port" ] || { echo "FAIL fake server did not start"; exit 1; }
PORT="$(cat "${TMP}/port")"
export FINDING_TRIAGE_NOTION_API="http://127.0.0.1:${PORT}"
registry() {
  jq -n --arg u "$1" --arg f "${TMP}/notion-token" \
    '{mcpServers: {athena: {type: "http", url: $u}, "notion-personal": {type: "stdio", command: "x", env: {NOTION_ATHENA_TOKEN_FILE: $f}}}}' > "${FLEET_CLAUDE_JSON}"
}
registry "http://127.0.0.1:${PORT}/mcp"

spec() { printf '%s\n' "$2" > "${TMP}/spec/$1"; }
requests() { local c; c="$(grep -c . "${TMP}/server.log" 2>/dev/null)"; printf '%s\n' "${c:-0}"; }
count_of() { jq -s --arg s "$1" '[.[] | select(.service == $s)] | length' "${TMP}/server.log"; }

spec "query-${PROJECTS_DS}.json" '{"status":200,"body":{"results":[{"properties":{"Repo / App":{"select":{"name":"~/dev/custom"}},"Epics":{"relation":[{"id":"e0000000-0000-0000-0000-000000000001"}],"has_more":false}}},{"properties":{"Repo / App":{"select":{"name":"gen_saas/apps/dnd"}},"Epics":{"relation":[],"has_more":false}}}]}}'
TICKETS_TWO='{"status":200,"body":{"results":[{"id":"a0000000-0000-0000-0000-000000000005","properties":{"ID":{"unique_id":{"prefix":"DND","number":5}},"Name":{"title":[{"plain_text":"Gate passes when its check cannot run"}]}}},{"id":"a0000000-0000-0000-0000-000000000006","properties":{"ID":{"unique_id":{"prefix":"DND","number":6}},"Name":{"title":[{"plain_text":"Check runner prints no Fix"}]}}}]}}'
spec "query-${TICKETS_DS}.json" "${TICKETS_TWO}"
spec blocks.json '{"status":200,"body":{"results":[{"type":"paragraph","paragraph":{"rich_text":[{"plain_text":"The gate exits 0 when the tool is missing."}]}}]}}'
spec triage.json '{"status":200,"body":{"status":"unavailable","reason":"not_configured"}}'
printf 'The check exits 0 when its tool is missing. SYNTHETIC-BODY\n' > "${TMP}/body.txt"

run() {
  OUT="$("${BIN}" "$@" 2>"${TMP}/err")"
  RC=$?
  ERR="$(cat "${TMP}/err")"
}
FINDING=(--title "HIGH: gate passes when the check cannot run" --body-file "${TMP}/body.txt")

run --help
eq "--help exits 0 [qa]" "${RC}" "0"
has "--help prints the usage on stdout [qa]" "${OUT}" "Usage: finding-triage"

n="$(requests)"
run
eq "no arguments is usage (2) [qa]" "${RC}" "2"
has "the usage line carries Fix:" "${ERR}" "Fix: "
run "${FINDING[@]}" --project harness --bogus
eq "an unknown flag is usage (2) [qa]" "${RC}" "2"
run --title "HIGH: x" --project harness
eq "no --body-file is usage (2): no default body file is ever read [qa]" "${RC}" "2"
has "the refusal names --body-file" "${ERR}" "--body-file is required"
run --title "HIGH: x" --body-file "${TMP}/absent.txt" --project harness
eq "a missing body file is usage (2)" "${RC}" "2"
has "a missing body file names its path" "${ERR}" "${TMP}/absent.txt does not exist"
run "${FINDING[@]}" --project "Walt UI"
eq "a project that is not an identifier is usage (2)" "${RC}" "2"
run "${FINDING[@]}" --project harness --tracker jira
eq "an unsupported tracker is usage (2)" "${RC}" "2"
eq "no usage failure sent any request" "$(requests)" "${n}"

# Shipped inert: the server answers not_configured.
: > "${TMP}/server.log"
run "${FINDING[@]}" --project harness
eq "not_configured exits 3 [qa]" "${RC}" "3"
has "not_configured prints the pinned line with Fix: [qa] [ticket]" "${OUT}" "${PINNED}"
has "the candidate count comes first" "$(printf '%s\n' "${OUT}" | head -n 1)" "2 candidates considered (DND, project harness"
has "the scope names the title keywords" "${OUT}" "title keywords: cannot, passes, check, gate"
lacks "not_configured is not read as no duplicates" "${OUT}" "no candidate is"
eq "Notion was asked: projects, tickets, then one children read per ticket" "$(count_of notion)" "4"
eq "the server was asked once" "$(count_of athena)" "1"
eq "every request reached a known route (no write was attempted) [ticket]" "$(jq -s '[.[] | select(.unexpected)] | length' "${TMP}/server.log")" "0"
eq "every Notion request is a POST query or a GET children [ticket]" \
  "$(jq -rs '[.[] | select(.service == "notion") | .method] | unique | join(",")' "${TMP}/server.log")" "GET,POST"
eq "every request carried its own service's token" "$(jq -s '[.[] | select(.auth_ok | not)] | length' "${TMP}/server.log")" "0"
eq "Notion requests name the data-source API version" "$(jq -rs '[.[] | select(.service == "notion") | .notion_version] | unique | join(",")' "${TMP}/server.log")" "2025-09-03"
eq "neither token was in any process's argv" "$(jq -s '[.[] | .argv_leak[]] | length' "${TMP}/server.log")" "0"
eq "neither token was in any process's environment" "$(jq -s '[.[] | .environ_leak[]] | length' "${TMP}/server.log")" "0"
sent="$(jq -c 'select(.service == "athena") | .body' "${TMP}/server.log")"
eq "the server got the finding and both candidates, with summaries" \
  "$(printf '%s' "${sent}" | jq -c '[.finding.project, (.candidates | map(.ref)), .candidates[0].summary]')" \
  '["harness",["DND-5","DND-6"],"The gate exits 0 when the tool is missing."]'
filter="$(jq -c "select(.path == \"/v1/data_sources/${TICKETS_DS}/query\") | .body" "${TMP}/server.log")"
eq "the tickets query is scoped to the project's epic" "$(printf '%s' "${filter}" | jq -r '.filter.and[0].or[0].relation.contains')" "e0000000-0000-0000-0000-000000000001"
eq "the tickets query asks for at most 20, newest first" "$(printf '%s' "${filter}" | jq -c '[.page_size, .sorts[0].direction]')" '[20,"descending"]'

# Unreachable server: a DISTINCT line.
registry "http://127.0.0.1:9/mcp"
run "${FINDING[@]}" --project harness
eq "an unreachable server exits 3 [qa]" "${RC}" "3"
has "it says it could not reach the server, with Fix: [qa]" "${OUT}" "COULD NOT REACH SERVER: curl exit"
has "the unreachable line ends with the advisory Fix:" "${OUT}" "Fix: file the ticket as today; this is advisory."
lacks "unreachable is not not_configured [qa]" "${OUT}" "JUDGMENTS UNAVAILABLE"
lacks "unreachable is not no duplicates [qa]" "${OUT}" "no candidate is"
registry "http://127.0.0.1:${PORT}/mcp"

# 0 candidates considered, judged.
spec "query-${TICKETS_DS}.json" '{"status":200,"body":{"results":[]}}'
spec triage.json '{"status":200,"body":{"status":"judged","mode":"on","question_set_version":"finding-triage-v1","model":"jev-1.13.0","thresholds":{"duplicate":"enabled","related":"enabled"},"candidates":[],"severity":{"level":"MEDIUM","score":1.1,"confidence":0.6}}}'
: > "${TMP}/server.log"
run "${FINDING[@]}" --project harness
eq "0 candidates judged exits 0 [qa]" "${RC}" "0"
has "it prints 0 candidates considered explicitly [qa]" "$(printf '%s\n' "${OUT}" | head -n 1)" "0 candidates considered"
has "and says none is a duplicate" "${OUT}" "no candidate is a duplicate or related at or above its threshold."
has "and the severity suggestion" "${OUT}" "severity suggestion: MEDIUM (confidence 0.60"
eq "the server got an empty candidate list" "$(jq -c 'select(.service == "athena") | .body.candidates' "${TMP}/server.log")" "[]"

# Judged with a duplicate above threshold.
spec "query-${TICKETS_DS}.json" "${TICKETS_TWO}"
spec triage.json '{"status":200,"body":{"status":"judged","mode":"on","question_set_version":"finding-triage-v1","model":"jev-1.13.0","thresholds":{"duplicate":"enabled","related":"enabled"},"candidates":[{"ref":"DND-5","relation":"duplicate","confidence":0.91,"above_threshold":true},{"ref":"DND-6","relation":"related","confidence":0.4,"above_threshold":false}],"severity":{"level":"HIGH","score":2.0,"confidence":0.7}}}'
run "${FINDING[@]}" --project harness
eq "judged exits 0" "${RC}" "0"
has "the duplicate above threshold is printed with its title" "${OUT}" "DND-5: duplicate (confidence 0.91) -- Gate passes when its check cannot run"
lacks "the related one below threshold is not printed" "${OUT}" "DND-6:"
has "the advisory is labelled not a decision" "${OUT}" "Jev advisory (not a decision)"

# The personal project (D2 permits it; inert, so not_configured).
spec triage.json '{"status":200,"body":{"status":"unavailable","reason":"not_configured"}}'
spec "query-${PROJECTS_DS}.json" '{"status":200,"body":{"results":[{"properties":{"Repo / App":{"select":{"name":"gen_saas/apps/dnd"}},"Epics":{"relation":[],"has_more":false}}}]}}'
: > "${TMP}/server.log"
run "${FINDING[@]}" --project dnd
eq "a dnd finding (no epics) exits 3 not_configured" "${RC}" "3"
has "it says the project has no epics, so nothing was searched" "${OUT}" "0 candidates considered (DND, project dnd, open or edited in the last 90 days; project dnd has no epics, so nothing was searched)"
has "and the pinned line" "${OUT}" "${PINNED}"

# admiral: no DND project row; nothing is searched, and it says so.
: > "${TMP}/server.log"
run "${FINDING[@]}" --project admiral
has "admiral says no DND project maps to it" "${OUT}" "no DND project maps to admiral, so nothing was searched"
eq "admiral makes no Notion request" "$(count_of notion)" "0"

# Unknown project: the server refuses it (domain_not_permitted).
spec triage.json '{"status":200,"body":{"status":"unavailable","reason":"domain_not_permitted"}}'
: > "${TMP}/server.log"
run "${FINDING[@]}" --project anchor
eq "an unknown project exits 3" "${RC}" "3"
has "it prints the server's reason" "${OUT}" "JUDGMENTS UNAVAILABLE: domain_not_permitted. Fix: file the ticket as today; this is advisory."
eq "an unknown project makes no Notion request" "$(count_of notion)" "0"
eq "an unknown project is still sent, so the server records the refusal" "$(count_of athena)" "1"

# Notion fails: the candidate search is unavailable, never an empty result.
spec "query-${PROJECTS_DS}.json" '{"status":200,"body":{"results":[{"properties":{"Repo / App":{"select":{"name":"~/dev/custom"}},"Epics":{"relation":[{"id":"e0000000-0000-0000-0000-000000000001"}],"has_more":false}}}]}}'
spec "query-${TICKETS_DS}.json" '{"status":500,"body":{"object":"error"}}'
spec triage.json '{"status":200,"body":{"status":"unavailable","reason":"not_configured"}}'
: > "${TMP}/server.log"
run "${FINDING[@]}" --project harness
eq "a Notion failure exits 3" "${RC}" "3"
has "it says the candidate search is unavailable, with Fix:" "${OUT}" "CANDIDATES UNAVAILABLE: Notion answered HTTP 500"
lacks "a Notion failure is never 0 candidates considered" "${OUT}" "0 candidates considered"
eq "a Notion failure asks the server nothing" "$(count_of athena)" "0"

spec "query-${PROJECTS_DS}.json" '{"status":200,"body":{"results":[{"properties":{"Repo / App":{"select":{"name":"walt_ui"}},"Epics":{"relation":[],"has_more":false}}}]}}'
run "${FINDING[@]}" --project harness
has "a Repo / App no Projects row carries is a stale map, never an empty search" "${OUT}" "CANDIDATES UNAVAILABLE: no DND Projects row has Repo / App ~/dev/custom"
spec "query-${PROJECTS_DS}.json" '{"status":200,"body":{"results":[]}}'
run "${FINDING[@]}" --project harness
has "an empty Projects data source is a failed lookup" "${OUT}" "CANDIDATES UNAVAILABLE: the DND Projects data source returned no rows"

# No Notion token: candidates unavailable, never an empty search.
jq -n --arg u "http://127.0.0.1:${PORT}/mcp" '{mcpServers: {athena: {type: "http", url: $u}}}' > "${FLEET_CLAUDE_JSON}"
run "${FINDING[@]}" --project harness
has "no notion-personal entry is candidates unavailable" "${OUT}" "CANDIDATES UNAVAILABLE: the notion-personal MCP entry names no NOTION_ATHENA_TOKEN_FILE"
registry "http://127.0.0.1:${PORT}/mcp"

# The documented fallback: candidates from a file, no Notion at all.
printf '[{"ref":"DND-77","title":"From a file","summary":"S"}]\n' > "${TMP}/cands.json"
: > "${TMP}/server.log"
run "${FINDING[@]}" --project harness --candidates-file "${TMP}/cands.json"
eq "--candidates-file exits 3 when not_configured" "${RC}" "3"
has "--candidates-file counts its candidates" "${OUT}" "1 candidate considered (from --candidates-file"
eq "--candidates-file makes no Notion request" "$(count_of notion)" "0"
eq "--candidates-file sends its refs" "$(jq -c 'select(.service == "athena") | .body.candidates | map(.ref)' "${TMP}/server.log")" '["DND-77"]'
printf '{"ref":"x"}\n' > "${TMP}/bad-cands.json"
run "${FINDING[@]}" --project harness --candidates-file "${TMP}/bad-cands.json"
eq "a malformed candidates file is usage (2)" "${RC}" "2"

# A long body is cut to 2,000 characters before it is sent.
ruby -e 'print "z" * 2600' > "${TMP}/long.txt"
: > "${TMP}/server.log"
run --title "HIGH: gate passes" --body-file "${TMP}/long.txt" --project harness --candidates-file "${TMP}/cands.json"
eq "the body sent is at most 2,000 characters" "$(jq -r 'select(.service == "athena") | .body.finding.body | length' "${TMP}/server.log")" "2000"

# 401 from the server: unavailable, distinct from not_configured.
spec triage.json '{"status":401,"body":{"error":"unauthorized"}}'
run "${FINDING[@]}" --project harness --candidates-file "${TMP}/cands.json"
eq "a rejected machine token exits 3" "${RC}" "3"
has "a 401 is SERVER REFUSED, naming the owner-issued token" "${OUT}" "SERVER REFUSED THE REQUEST: HTTP 401 unauthorized: the machine token was rejected; it is owner-issued"
lacks "a 401 is never could-not-reach" "${OUT}" "COULD NOT REACH SERVER"
spec triage.json '{"status":200,"body":{"status":"maybe"}}'
run "${FINDING[@]}" --project harness --candidates-file "${TMP}/cands.json"
eq "a 200 outside the contract's shape exits 3" "${RC}" "3"
has "it is its own line, not unreachable" "${OUT}" "UNREADABLE SERVER ANSWER: HTTP 200"

# The server was reached and refused: its own line, with the server's Fix:.
spec triage.json '{"status":422,"body":{"error":"unprocessable_entity","fix":"candidates[0].title is missing, blank or over 300 characters. Fix: send a short title."}}'
run "${FINDING[@]}" --project harness --candidates-file "${TMP}/cands.json"
eq "a 422 exits 3" "${RC}" "3"
has "a 422 is SERVER REFUSED, carrying the server's fix" "${OUT}" "SERVER REFUSED THE REQUEST: HTTP 422 unprocessable_entity: candidates[0].title is missing, blank or over 300 characters. Fix: send a short title. Fix: file the ticket as today; this is advisory."
lacks "a 422 is never could-not-reach" "${OUT}" "COULD NOT REACH SERVER"
spec triage.json '{"status":404,"body":{"error":"not_found"}}'
run "${FINDING[@]}" --project harness --candidates-file "${TMP}/cands.json"
has "a 404 is SERVER REFUSED too (e.g. the endpoint is not deployed yet)" "${OUT}" "SERVER REFUSED THE REQUEST: HTTP 404 not_found. Fix: file the ticket as today"
spec triage.json '{"status":500,"body":{"error":"internal_error"}}'
run "${FINDING[@]}" --project harness --candidates-file "${TMP}/cands.json"
has "a 5xx is the server failing, not refusing" "${OUT}" "COULD NOT REACH SERVER: the Athena server answered HTTP 500 internal_error"

printf '[{"ref":"DND-1","title":"\xe3\x80\x80 "}]\n' > "${TMP}/blank-title.json"
run "${FINDING[@]}" --project harness --candidates-file "${TMP}/blank-title.json"
eq "a candidates-file title of only Unicode whitespace is usage (2)" "${RC}" "2"
has "it names the entry, not its text" "${ERR}" "entry 0 has a blank title"
mkdir -p "${TMP}/a-dir"
run "${FINDING[@]}" --project harness --candidates-file "${TMP}/a-dir"
eq "a candidates-file that is a directory is usage (2), never a stack trace" "${RC}" "2"

# A ticket search Notion truncated says so.
spec "query-${PROJECTS_DS}.json" '{"status":200,"body":{"results":[{"properties":{"Repo / App":{"select":{"name":"~/dev/custom"}},"Epics":{"relation":[{"id":"e0000000-0000-0000-0000-000000000001"}],"has_more":false}}}]}}'
spec "query-${TICKETS_DS}.json" "$(printf '%s' "${TICKETS_TWO}" | jq -c '.body.has_more = true')"
spec triage.json '{"status":200,"body":{"status":"unavailable","reason":"not_configured"}}'
run "${FINDING[@]}" --project harness
has "a truncated ticket search is reported" "${OUT}" "more tickets matched, the 20 most recently edited were sent"

# A title in a non-UTF-8 locale is still sent as UTF-8.
printf '[]\n' > "${TMP}/none.json"
: > "${TMP}/server.log"
LANG=C LC_ALL=C run --title "HIGH: $(printf 'é%.0s' $(seq 1 310))" --body-file "${TMP}/body.txt" --project harness --candidates-file "${TMP}/none.json"
eq "a C-locale title is cut to 300 characters, not bytes" "$(jq -r 'select(.service == "athena") | .body.finding.title | length' "${TMP}/server.log")" "300"

# A security word prints the hint.
spec triage.json '{"status":200,"body":{"status":"judged","mode":"on","question_set_version":"finding-triage-v1","model":"jev-1.13.0","thresholds":{"duplicate":"enabled","related":"enabled"},"candidates":[],"severity":{"level":"CRITICAL","score":3,"confidence":0.9}}}'
printf '[]\n' > "${TMP}/none.json"
run --title "CRITICAL: token printed in argv" --body-file "${TMP}/body.txt" --project harness --candidates-file "${TMP}/none.json"
has "a security finding prints the hint" "${OUT}" "Owner approval policy -> Security fixes"

echo
echo "finding-triage self-test: ${PASS} passed, ${FAIL} failed"
[ "${FAIL}" -eq 0 ]
