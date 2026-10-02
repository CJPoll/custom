#!/usr/bin/env bash
# self-test.sh -- the ticket-classify suite (DND-1054). Discovered by
# harness-gate (every committed `self-test.sh` runs).
#
# Two layers, in TDD order:
#   1. domain  -- the script's pure Classify module, loaded with ruby -e (the
#      script only runs main when it IS the program);
#   2. end to end -- the script against the loopback fake the finding-triage
#      suite already runs (../fake-triage-server.py), standing in for the
#      Athena server. Never prod: every URL is 127.0.0.1, and the token, the
#      MCP registry and the inbox client config are temp fixtures.
#
# Cases marked [qa] are DND-1054's QA Plan rows; [pin] reads the contract's
# pinned Fix: clause from ai/contracts/fixtures/athena-judgments-quoted-fix.txt
# (the other side of the pin is ai/contracts/test/self-test.sh).

set -u

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SKILL="$(cd -- "${HERE}/../.." && pwd -P)"
BIN="${SKILL}/scripts/ticket-classify"
FAKE="${SKILL}/test/fake-triage-server.py"
PIN_FILE="$(cd -- "${SKILL}/../../contracts/fixtures" && pwd -P)/athena-judgments-quoted-fix.txt"
PINNED="$(awk '/^@section Ticket classification: the harness script$/ { on = 1; next } /^@section / { on = 0 } on && /^Fix: / { print; exit }' "${PIN_FILE}" 2>/dev/null)"
[ -n "${PINNED}" ] || { echo "ticket-classify self-test: FAIL -- no pinned Fix: line under '@section Ticket classification: the harness script' in ${PIN_FILE}"; echo "  Fix: restore it in the contract fixture; the suite does not guess it."; exit 1; }

PASS=0
FAIL=0
ok()   { PASS=$((PASS + 1)); printf 'ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL + 1)); printf 'FAIL %s\n' "$1"; [ -n "${2:-}" ] && printf '     %s\n' "$2"; return 0; }
eq()   { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$3], got [$2]"; fi; }
has()  { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "no [$3] in: $2" ;; esac; }
lacks() { case "$2" in *"$3"*) bad "$1" "unexpected [$3] in: $2" ;; *) ok "$1" ;; esac; }

[ -x /usr/bin/ruby ] || { echo "ticket-classify self-test: FAIL -- /usr/bin/ruby is missing"; echo "  Fix: install the harness Ruby at /usr/bin/ruby (DND-931/958); this suite does not skip."; exit 1; }
for dep in python3 curl jq git; do
  command -v "${dep}" >/dev/null 2>&1 || { echo "ticket-classify self-test: FAIL -- ${dep} is not on PATH"; echo "  Fix: install ${dep}; this suite does not skip."; exit 1; }
done
[ -x "${BIN}" ] || { echo "ticket-classify self-test: FAIL -- ${BIN} missing or not executable"; echo "  Fix: chmod +x ai/skills/athena:ticket-management/scripts/ticket-classify"; exit 1; }

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
  got="$(/usr/bin/ruby -e "load ARGV.shift; puts(begin; $3; rescue ArgumentError => e; 'ArgumentError: ' + e.message; end)" "${BIN}" 2>&1)"
  eq "$1" "${got}" "$2"
}
# ruby_eq_args NAME EXPECTED RUBY-EXPR ARG... -- the same, with ARGV = ARG...
ruby_eq_args() {
  local name="$1" want="$2" expr="$3" got
  shift 3
  got="$(/usr/bin/ruby -e "load ARGV.shift; puts(begin; ${expr}; rescue ArgumentError => e; 'ArgumentError: ' + e.message; end)" "${BIN}" "$@" 2>&1)"
  eq "${name}" "${got}" "${want}"
}

# A 200 as DND-991 answers it with every mode off: each property the filer's,
# reason mode_off. The provenance line is the server's, byte for byte.
PROV_OFF='Jev classification: {"kind":{"value":"Bug","source":"filer","judged":null,"confidence":null,"accepted":false,"mode":"off","reason":"mode_off"},"severity":{"value":"MEDIUM","source":"filer","judged":null,"confidence":null,"accepted":false,"mode":"off","reason":"mode_off"},"security":{"value":"none","source":"filer","judged":null,"confidence":null,"accepted":false,"mode":"off","reason":"mode_off"},"model":"jev-1.13.0","versions":{"kind":"ticket-kind-v1","severity":"ticket-severity-v1","security":"ticket-security-v1"}}'
OFF_BODY="$(jq -cn --arg p "${PROV_OFF}" '{status: "judged", properties: {kind: {decided: "Bug", source: "filer", judged: null, accepted: false, reason: "mode_off", mode: "off"}, severity: {decided: "MEDIUM", source: "filer", judged: null, accepted: false, reason: "mode_off", mode: "off"}, security: {decided: "none", source: "filer", judged: null, accepted: false, reason: "mode_off", mode: "off"}}, would_decide: null, provenance_line: $p}')"
# A 200 with Jev on for Kind and the policy's Vulnerability floor on Security.
MIXED_BODY="$(jq -cn '{status: "judged", properties: {kind: {decided: "Vulnerability", source: "filer", judged: null, accepted: false, reason: "mode_off", mode: "off"}, severity: {decided: "HIGH", source: "jev", judged: {value: "HIGH", confidence: 0.934}, accepted: true, reason: null, mode: "on"}, security: {decided: "pre-existing", source: "policy", judged: null, accepted: false, reason: "vulnerability_floor", mode: "off"}}, would_decide: null, provenance_line: "Jev classification: {\"x\":1}"}')"

echo "== domain"

ruby_eq_args "render: one line per property with its source [qa render 1]" \
  "Kind: Bug (filer: mode_off)|Severity: MEDIUM (filer: mode_off)|Security: none (filer: mode_off)" \
  'Classify.decision_lines(Classify.parse_result(JSON.parse(ARGV[0]), {kind: ARGV.fetch(1, "Bug")}))[0, 3].join("|")' "${OFF_BODY}"
ruby_eq_args "render: jev shows its confidence, filer and policy show their reason" \
  "Kind: Vulnerability (filer: mode_off)|Severity: HIGH (jev 0.93)|Security: pre-existing (policy: vulnerability_floor)" \
  'Classify.decision_lines(Classify.parse_result(JSON.parse(ARGV[0]), {kind: ARGV.fetch(1, "Bug")}))[0, 3].join("|")' "${MIXED_BODY}" Vulnerability
ruby_eq_args "render: the provenance line is last, verbatim [qa render 2]" \
  "true|4" \
  'l = Classify.decision_lines(Classify.parse_result(JSON.parse(ARGV[0]), {kind: ARGV.fetch(1, "Bug")})); [l.last == ARGV[2], l.size].join("|")' "${OFF_BODY}" Bug "${PROV_OFF}"
ruby_eq "render: a Feature prints no severity value [qa render 3]" \
  "Severity: (none: Feature) (filer: feature)" \
  'd = {"status"=>"judged","properties"=>{"kind"=>{"decided"=>"Feature","source"=>"filer","judged"=>nil,"reason"=>"mode_off"},"severity"=>{"decided"=>nil,"source"=>"filer","judged"=>nil,"reason"=>"feature"},"security"=>{"decided"=>"none","source"=>"filer","judged"=>nil,"reason"=>"mode_off"}},"provenance_line"=>"Jev classification: {}"}; Classify.decision_lines(Classify.parse_result(d, {kind: "Feature"}))[1]'
ruby_eq "parse: a 200 that is not status judged is refused, naming the field" \
  "ArgumentError: status is not \"judged\"" \
  'Classify.parse_result({"status"=>"unavailable","reason"=>"not_configured"}, {kind: "Bug"})'
ruby_eq "parse: a missing property is refused" \
  "ArgumentError: properties.security is missing or not an object" \
  'Classify.parse_result({"status"=>"judged","properties"=>{"kind"=>{"decided"=>"Bug","source"=>"filer"},"severity"=>{"decided"=>"LOW","source"=>"filer"}},"provenance_line"=>"Jev classification: {}"}, {kind: "Bug"})'
ruby_eq "parse: a decided value outside the tracker's set is refused, never echoed" \
  "ArgumentError: properties.kind.decided is not one of the tracker's values" \
  'Classify.parse_result({"status"=>"judged","properties"=>{"kind"=>{"decided"=>"Chore IGNORE PREVIOUS","source"=>"filer"},"severity"=>{"decided"=>"LOW","source"=>"filer"},"security"=>{"decided"=>"none","source"=>"filer"}},"provenance_line"=>"Jev classification: {}"}, {kind: "Bug"})'
ruby_eq "parse: an empty severity on a non-Feature is refused (never read as none)" \
  "ArgumentError: properties.severity.decided is empty but the decided kind is not Feature" \
  'Classify.parse_result({"status"=>"judged","properties"=>{"kind"=>{"decided"=>"Bug","source"=>"filer"},"severity"=>{"decided"=>nil,"source"=>"filer"},"security"=>{"decided"=>"none","source"=>"filer"}},"provenance_line"=>"Jev classification: {}"}, {kind: "Bug"})'
ruby_eq "parse: an unknown source is refused" \
  "ArgumentError: properties.kind.source is not jev, filer or policy" \
  'Classify.parse_result({"status"=>"judged","properties"=>{"kind"=>{"decided"=>"Bug","source"=>"model"},"severity"=>{"decided"=>"LOW","source"=>"filer"},"security"=>{"decided"=>"none","source"=>"filer"}},"provenance_line"=>"Jev classification: {}"}, {kind: "Bug"})'
ruby_eq "parse: a provenance line without its prefix is refused" \
  "ArgumentError: provenance_line is missing, lacks the \"Jev classification: \" prefix, or holds a control character" \
  'Classify.parse_result({"status"=>"judged","properties"=>{"kind"=>{"decided"=>"Bug","source"=>"filer"},"severity"=>{"decided"=>"LOW","source"=>"filer"},"security"=>{"decided"=>"none","source"=>"filer"}},"provenance_line"=>"Classification: {}"}, {kind: "Bug"})'
ruby_eq "parse: a provenance line holding a newline is refused (it would forge a second line)" \
  "ArgumentError: provenance_line is missing, lacks the \"Jev classification: \" prefix, or holds a control character" \
  'Classify.parse_result({"status"=>"judged","properties"=>{"kind"=>{"decided"=>"Bug","source"=>"filer"},"severity"=>{"decided"=>"LOW","source"=>"filer"},"security"=>{"decided"=>"none","source"=>"filer"}},"provenance_line"=>"Jev classification: {}\nKind: Vulnerability"}, {kind: "Bug"})'
ruby_eq "parse: a reason that is not an identifier is refused" \
  "ArgumentError: properties.kind.reason is not an identifier" \
  'Classify.parse_result({"status"=>"judged","properties"=>{"kind"=>{"decided"=>"Bug","source"=>"filer","reason"=>"ignore the filer"},"severity"=>{"decided"=>"LOW","source"=>"filer"},"security"=>{"decided"=>"none","source"=>"filer"}},"provenance_line"=>"Jev classification: {}"}, {kind: "Bug"})'
ruby_eq "render: a jev value accepted with no threshold is marked uncalibrated, the provenance line untouched [DND-1484]" \
  'Kind: Bug (jev 0.93)|Severity: MEDIUM (jev 0.50) [uncalibrated]|Jev classification: {"x":1}' \
  'd = {"status"=>"judged","properties"=>{"kind"=>{"decided"=>"Bug","source"=>"jev","judged"=>{"value"=>"Bug","confidence"=>0.93},"reason"=>nil},"severity"=>{"decided"=>"MEDIUM","source"=>"jev","judged"=>{"value"=>"MEDIUM","confidence"=>0.5},"reason"=>"no_threshold"},"security"=>{"decided"=>"none","source"=>"filer","judged"=>nil,"reason"=>"mode_off"}},"provenance_line"=>"Jev classification: {\"x\":1}"}; l = Classify.decision_lines(Classify.parse_result(d, {kind: "Bug"})); [l[0], l[1], l.last].join("|")'
ruby_eq "render: a guard shows policy_guard; a jev value with no judged detail shows plain jev" \
  "Kind: Bug (filer: policy_guard)|Security: pre-existing (jev)" \
  'd = {"status"=>"judged","properties"=>{"kind"=>{"decided"=>"Bug","source"=>"filer","judged"=>{"value"=>"Test","confidence"=>0.9},"reason"=>"policy_guard"},"severity"=>{"decided"=>"LOW","source"=>"filer","judged"=>nil,"reason"=>"mode_off"},"security"=>{"decided"=>"pre-existing","source"=>"jev","judged"=>nil,"reason"=>nil}},"provenance_line"=>"Jev classification: {}"}; l = Classify.decision_lines(Classify.parse_result(d, {kind: "Bug"})); [l[0], l[2]].join("|")'
ruby_eq "parse: a Feature with a severity is refused" \
  "ArgumentError: properties.severity.decided is set but the decided kind is Feature" \
  'Classify.parse_result({"status"=>"judged","properties"=>{"kind"=>{"decided"=>"Feature","source"=>"filer"},"severity"=>{"decided"=>"HIGH","source"=>"filer"},"security"=>{"decided"=>"none","source"=>"filer"}},"provenance_line"=>"Jev classification: {}"}, {kind: "Feature"})'
ruby_eq "parse: a decided Feature on a non-Feature filer is refused (the policy never assigns Feature)" \
  "ArgumentError: properties.kind.decided assigns or replaces Feature, which the policy never does" \
  'Classify.parse_result({"status"=>"judged","properties"=>{"kind"=>{"decided"=>"Feature","source"=>"jev"},"severity"=>{"decided"=>nil,"source"=>"filer"},"security"=>{"decided"=>"none","source"=>"filer"}},"provenance_line"=>"Jev classification: {}"}, {kind: "Bug"})'
ruby_eq "parse: a filer Feature decided as anything else is refused (the policy never replaces Feature)" \
  "ArgumentError: properties.kind.decided assigns or replaces Feature, which the policy never does" \
  'Classify.parse_result({"status"=>"judged","properties"=>{"kind"=>{"decided"=>"Bug","source"=>"jev"},"severity"=>{"decided"=>"LOW","source"=>"filer"},"security"=>{"decided"=>"none","source"=>"filer"}},"provenance_line"=>"Jev classification: {}"}, {kind: "Feature"})'
ruby_eq "truncate: by grapheme cluster, as the server counts" \
  "300|600" \
  't = Classify.truncate("é" * 301, 300); [Classify.length(t), t.length].join("|")'
ruby_eq "request body: severity none is null, ref only when given, only the contract's keys" \
  "filer,ticket|body,project,title|kind,security,severity|nil|DND-7" \
  'a = Classify.request_body("T", "B", "harness", nil, {kind: "Feature", severity: "none", security: "none"}); b = Classify.request_body("T", "B", "harness", "DND-7", {kind: "Bug", severity: "LOW", security: "none"}); [a.keys.sort.join(","), a["ticket"].keys.sort.join(","), a["filer"].keys.sort.join(","), a["filer"]["severity"].inspect, b["ticket"]["ref"]].join("|")'
# DND-1590: a trailing Source:/Context: provenance block is background, not
# the defect's impact. ticket-severity-v1 rated the incident a finding came
# from, so the block is dropped from the body sent; anything else is kept.
ruby_eq "sent body: a trailing Source:/Context: block on the last sentence is dropped [DND-1590]" \
  "The pool is 3. Fix: size it." \
  'Classify.sent_body("The pool is 3. Fix: size it. Source: DND-9 captain report, a/b/r.md. Context: the 16:00Z prod outage (DND-9).\n")'
ruby_eq "sent body: a block on its own lines, Context first, is dropped [DND-1590]" \
  "The pool is 3." \
  'Classify.sent_body("The pool is 3.\n\nContext: the prod outage.\nSource: a report.\n")'
ruby_eq "sent body: the request body carries the dropped form [DND-1590]" \
  "The pool is 3." \
  'Classify.request_body("T", "The pool is 3. Source: a report.", "athena", nil, {kind: "Bug", severity: "LOW", security: "none"})["ticket"]["body"]'
ruby_eq "sent body: a Source: followed by a sentence that is not provenance is kept whole [DND-1590]" \
  "true" \
  'b = "The pool is 3. Source: the logs. Prod is down now.\n"; Classify.sent_body(b) == b'
ruby_eq "sent body: a label inside a sentence is not a block [DND-1590]" \
  "true" \
  'b = "Read the Source: header of each event.\n"; Classify.sent_body(b) == b'
ruby_eq "sent body: a body that is only provenance is kept, never sent blank [DND-1590]" \
  "true" \
  'b = "Source: a report. Context: an outage.\n"; Classify.sent_body(b) == b'
ruby_eq "sent body: a body with no block is byte-identical [DND-1590]" \
  "true" \
  'b = "Gate exits 0 when its tool is missing.\n"; Classify.sent_body(b) == b'
ruby_eq "sent body: only the trailing block goes; an earlier labelled sentence followed by content stays [DND-1590]" \
  "Context: seen twice. The fix is X." \
  'Classify.sent_body("Context: seen twice. The fix is X. Source: r.md.")'
ruby_eq "sent body: a line after a Source: line, with no full stop between, is content: kept whole [DND-1590 review]" \
  "true" \
  'b = "Fix the gate.\nSource: logs\nImpact: prod is down for every tenant"; Classify.sent_body(b) == b'
ruby_eq "sent body: a bracket or quote alone does not end a sentence [DND-1590 review]" \
  "true|true" \
  'a = "Call f(x) Source: the logs."; b = "Run `X` Context: an outage."; [Classify.sent_body(a) == a, Classify.sent_body(b) == b].join("|")'
ruby_eq "sent body: an e.g. before a label does not end a sentence [DND-1590 review]" \
  "true" \
  'b = "Use a header, e.g. Source: the gateway."; Classify.sent_body(b) == b'
ruby_eq "sent body: a quoted sentence end and a CRLF block are dropped; trailing whitespace too [DND-1590 review]" \
  "It read \"stop.\"|Pool is 3.|Pool is 3." \
  '[Classify.sent_body("It read \"stop.\" Source: r.md."), Classify.sent_body("Pool is 3.\r\nSource: r.md.\r\n"), Classify.sent_body("Pool is 3. Context: x.  \n\n")].join("|")'
ruby_eq "sent body: many labelled clauses before a closing sentence are all kept [DND-1590 review]" \
  "true" \
  'b = "Lead. " + ("Source: a. x " * 50) + "End."; Classify.sent_body(b) == b'
ruby_eq_args "sent body: on the DND-1590 fixtures, exactly the 15 bodies with a block change, and none keeps a label [DND-1590]" \
  "15|0|6" \
  'rows = File.readlines(ARGV[0]).map { |l| JSON.parse(l)["input"]["body"] }; sent = rows.map { |b| Classify.sent_body(b) }; changed = rows.zip(sent).reject { |a, b| a == b }; [changed.size, changed.count { |_, b| b.match?(/(?:Source|Context):/) }, rows.zip(sent).count { |a, b| a == b }].join("|")' \
  "${SKILL}/../../eval/judgment-fixtures/ticket-severity-provenance/corpus.jsonl"
ruby_eq "fallback: the filer's values under a heading that is not a decision" \
  "Decided (filer; classification unavailable):|Kind: Feature|Severity: (none: Feature)|Security: none" \
  'Classify.fallback_lines({kind: "Feature", severity: "none", security: "none"}).join("|")'
ruby_eq "filer check: severity none only with Feature, Feature only with none" \
  "--severity none is only for --kind Feature|--kind Feature takes --severity none (a Feature has no Severity)|" \
  '[Classify.filer_error({kind: "Bug", severity: "none", security: "none"}).first, Classify.filer_error({kind: "Feature", severity: "LOW", security: "none"}).first, Classify.filer_error({kind: "Flake", severity: "LOW", security: "introduced"}).inspect.sub("nil", "")].join("|")'
ruby_eq "control check [DND-1747]: none, a matching direction and no --control pass" \
  "|||" \
  '[Classify.control_error(nil, "Bug"), Classify.control_error("none", "Docs"), Classify.control_error("fails-closed", "Bug"), Classify.control_error("fails-open", "Vulnerability")].map(&:inspect).map { |s| s.sub("nil", "") }.join("|")'
ruby_eq "control check [DND-1747]: an unknown value, and a direction whose Kind is wrong, are refused" \
  "--control sideways is not a Control value|--control fails-closed is a Bug (it blocks legitimate work), not Vulnerability|--control fails-open is a Vulnerability (it lets through what it should block), not Bug" \
  '[Classify.control_error("sideways", "Bug"), Classify.control_error("fails-closed", "Vulnerability"), Classify.control_error("fails-open", "Bug")].map(&:first).join("|")'
ruby_eq "control check [DND-1747]: every refusal carries a fix" \
  "true" \
  '[Classify.control_error("sideways", "Bug"), Classify.control_error("fails-closed", "Vulnerability"), Classify.control_error("fails-open", "Bug")].all? { |w, f| f.is_a?(String) && !f.empty? }'
ruby_eq "control line [DND-1747]: the filer's value, sourced" \
  "Control: fails-closed (filer)" \
  'Classify.control_line("fails-closed")'

echo "== no tracker writer [qa manager 8]"

# DND-1057: --epic reads the epic's candidates, and only through the
# read-only ai/lib/notion_read.rb (its allowlist refuses any other request
# before it is sent). The script itself names no Notion URL and no write.
CODE="$(grep -v '^\s*#' "${BIN}")"
lacks "the script names no Notion API URL (all Notion access is NotionRead)" "${CODE}" "api.notion.com"
lacks "the script makes no PATCH" "${CODE}" '"PATCH"'
lacks "the script makes no DELETE" "${CODE}" '"DELETE"'
has "its Notion access is the read-only client" "${CODE}" 'require_relative "../../../lib/notion_read"'
eq "every NotionRead call is a read" "$(printf '%s\n' "${CODE}" | grep -o 'NotionRead\.[a-z_]*' | sort -u | tr '\n' ' ')" "NotionRead.credentials NotionRead.page NotionRead.query_all NotionRead.read "

echo "== argv"

ATHENA_TOKEN="classify-athena-token-$$-${RANDOM}-5e2b"
printf '%s\n' "${ATHENA_TOKEN}" > "${TMP}/athena-token"
printf 'unused-notion-%s\n' "$$" > "${TMP}/notion-token"
mkdir -p "${TMP}/cfg" "${TMP}/spec" "${TMP}/home"
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
registry() { jq -n --arg u "$1" '{mcpServers: {athena: {type: "http", url: $u}}}' > "${FLEET_CLAUDE_JSON}"; }
registry "http://127.0.0.1:${PORT}/mcp"

spec() { printf '%s\n' "$2" > "${TMP}/spec/$1"; }
requests() { local c; c="$(grep -c . "${TMP}/server.log" 2>/dev/null)"; printf '%s\n' "${c:-0}"; }
sent() { jq -c 'select(.service == "athena") | .body' "${TMP}/server.log" | tail -n 1; }

printf 'The gate exits 0 when its tool is missing. SYNTHETIC-BODY\n' > "${TMP}/body.txt"
run() {
  OUT="$(HOME="${TMP}/home" "${BIN}" "$@" 2>"${TMP}/err")"
  RC=$?
  ERR="$(cat "${TMP}/err")"
}
TICKET=(--title "Gate passes when its check cannot run" --body-file "${TMP}/body.txt" --project harness)
FILER=(--kind Bug --severity MEDIUM --security none)

: > "${TMP}/server.log"
run --help
eq "--help exits 0 [qa help 1]" "${RC}" "0"
has "--help prints the usage on stdout [qa help 1]" "${OUT}" "Usage: ticket-classify"
eq "--help makes no request [qa help 1]" "$(requests)" "0"
eq "--help writes nothing under HOME [qa help 1]" "$(find "${TMP}/home" -mindepth 1 | wc -l | tr -d ' ')" "0"
run "${TICKET[@]}" "${FILER[@]}" --help
eq "--help anywhere wins" "${RC}" "0"

run "${TICKET[@]}" --kind Bug --severity MEDIUM
eq "no --security is usage (2) [qa argv 1]" "${RC}" "2"
has "the refusal names --security with Fix: [qa argv 1]" "${ERR}" "--security is required. Fix: "
run "${TICKET[@]}" --severity MEDIUM --security none
has "no --kind is usage naming --kind" "${ERR}" "--kind is required"
run "${TICKET[@]}" --kind Bug --security none
has "no --severity is usage naming --severity, never a guessed default" "${ERR}" "--severity is required"
run "${TICKET[@]}" --kind Bug --severity none --security none
eq "severity none on a Bug is usage (2) [qa argv 2]" "${RC}" "2"
has "it says why, with Fix: [qa argv 2]" "${ERR}" "--severity none is only for --kind Feature. Fix: "
run "${TICKET[@]}" --kind Feature --severity LOW --security none
eq "a Feature with a severity is usage (2)" "${RC}" "2"
run "${TICKET[@]}" --kind Chore --severity LOW --security none
eq "an unknown Kind is usage (2) [qa argv 4]" "${RC}" "2"
has "it lists the nine Kinds" "${ERR}" "Feature, Bug, Vulnerability, Hardening, Refactor, Test, Flake, Docs, Ops"
run "${TICKET[@]}" --kind Bug --severity medium --security none
eq "a severity in the wrong case is usage (2): tracker spelling only" "${RC}" "2"
run "${TICKET[@]}" --kind Bug --severity LOW --security yes
eq "an unknown Security is usage (2)" "${RC}" "2"
run "${TICKET[@]}" "${FILER[@]}" --ref dnd-5
eq "a --ref that is not a ticket id is usage (2)" "${RC}" "2"
run "${TICKET[@]}" "${FILER[@]}" --bogus
eq "an unknown flag is usage (2)" "${RC}" "2"
run --title $'\xe3\x80\x80 ' --body-file "${TMP}/body.txt" --project harness "${FILER[@]}"
eq "a title of only Unicode whitespace is usage (2)" "${RC}" "2"
run --title "T" --body-file "${TMP}/absent.txt" --project harness "${FILER[@]}"
eq "a missing body file is usage (2)" "${RC}" "2"
has "it names the path" "${ERR}" "${TMP}/absent.txt does not exist"
run --title "T" --body-file "${TMP}/body.txt" --project "Walt UI" "${FILER[@]}"
eq "a project that is not an identifier is usage (2)" "${RC}" "2"
eq "no usage failure sent any request [qa argv 4]" "$(requests)" "0"

echo "== end to end"

spec classify.json "$(jq -cn --argjson b "${OFF_BODY}" '{status: 200, body: $b}')"
: > "${TMP}/server.log"
run "${TICKET[@]}" "${FILER[@]}"
eq "modes off: a 200 with every property from the filer exits 0 [qa manager 1]" "${RC}" "0"
eq "modes off: each property is the filer's, mode_off, then the provenance line [qa render 1-2]" \
  "${OUT}" "Kind: Bug (filer: mode_off)
Severity: MEDIUM (filer: mode_off)
Security: none (filer: mode_off)
${PROV_OFF}"
eq "one request, to ticket_classification" "$(jq -rs 'map(.path) | join(",")' "${TMP}/server.log")" "/api/v1/judgments/ticket_classification"
eq "nothing reached any other route: no tracker call [qa manager 8]" "$(jq -s '[.[] | select(.unexpected)] | length' "${TMP}/server.log")" "0"
eq "the request carried the machine token" "$(jq -s '[.[] | select(.auth_ok | not)] | length' "${TMP}/server.log")" "0"
eq "the token was in no process's argv [qa manager 6]" "$(jq -s '[.[] | .argv_leak[]] | length' "${TMP}/server.log")" "0"
eq "the token was in no process's environment [qa manager 6]" "$(jq -s '[.[] | .environ_leak[]] | length' "${TMP}/server.log")" "0"
eq "the body is the ticket and the filer's values, no ref, no identity" \
  "$(sent)" '{"ticket":{"title":"Gate passes when its check cannot run","body":"The gate exits 0 when its tool is missing. SYNTHETIC-BODY\n","project":"harness"},"filer":{"kind":"Bug","severity":"MEDIUM","security":"none"}}'
FIRST="$(sent)"
run --security none --project harness --severity MEDIUM --body-file "${TMP}/body.txt" --kind Bug --title "Gate passes when its check cannot run"
eq "flags in any order send an identical body [qa argv 3]" "$(sent)" "${FIRST}"
eq "no file was written under HOME [qa manager 8]" "$(find "${TMP}/home" -mindepth 1 | wc -l | tr -d ' ')" "0"

run "${TICKET[@]}" "${FILER[@]}" --ref DND-42
eq "--ref is sent as ticket.ref" "$(sent | jq -r '.ticket.ref')" "DND-42"

# DND-1747: Control is the filer's, never sent (the server has no Control
# input) and printed after the classification.
run "${TICKET[@]}" "${FILER[@]}" --control fails-closed
eq "--control fails-closed on a Bug exits 0 [DND-1747]" "${RC}" "0"
eq "the Control line follows the provenance line [DND-1747]" "$(printf '%s\n' "${OUT}" | tail -n 1)" "Control: fails-closed (filer)"
eq "Control is not sent to the server [DND-1747]" "$(sent)" "${FIRST}"
lacks "a given --control prints no unset note [DND-1747]" "${ERR}" "--control not given"
run "${TICKET[@]}" "${FILER[@]}"
lacks "without --control stdout is unchanged: no Control line [DND-1747]" "${OUT}" "Control:"
has "without --control stderr names the gap [DND-1747]" "${ERR}" "--control not given"
has "the unset note carries a Fix: [DND-1747]" "${ERR}" "Fix: "
: > "${TMP}/server.log"
run "${TICKET[@]}" "${FILER[@]}" --control fails-open
eq "--control fails-open on a Bug is usage (2) [DND-1747]" "${RC}" "2"
has "it says fail-open is a Vulnerability, with Fix: [DND-1747]" "${ERR}" "--control fails-open is a Vulnerability (it lets through what it should block), not Bug. Fix: "
run "${TICKET[@]}" "${FILER[@]}" --control maybe
eq "an unknown --control is usage (2) [DND-1747]" "${RC}" "2"
eq "no --control refusal sent a request [DND-1747]" "$(requests)" "0"
spec classify.json "$(jq -cn '{status: 503, body: {error: "unavailable"}}')"
run "${TICKET[@]}" "${FILER[@]}" --control fails-closed
eq "an unavailable classification still exits 3 with --control [DND-1747]" "${RC}" "3"
eq "the Control line follows the filer's fallback values [DND-1747]" "$(printf '%s\n' "${OUT}" | tail -n 2 | tr '\n' '|')" "Security: none|Control: fails-closed (filer)|"
spec classify.json "$(jq -cn --argjson b "${OFF_BODY}" '{status: 200, body: $b}')"

printf 'The gate exits 0. Source: DND-9 captain report, r.md. Context: the 16:00Z prod outage (DND-9).\n' > "${TMP}/prov-body.txt"
run --title "T" --body-file "${TMP}/prov-body.txt" --project harness "${FILER[@]}"
eq "a trailing Source:/Context: block is not sent [DND-1590]" "$(sent | jq -r '.ticket.body')" "The gate exits 0."
/usr/bin/ruby -e 'print "z" * 1990, ". Source: ", "r" * 40, "."' > "${TMP}/prov-long.txt"
run --title "T" --body-file "${TMP}/prov-long.txt" --project harness "${FILER[@]}"
lacks "a body under the cap once its block is dropped is not reported truncated [DND-1590]" "${ERR}" "[truncated]"

run "${TICKET[@]}" "${FILER[@]}" --json
eq "--json exits 0" "${RC}" "0"
eq "--json prints the server's result" "$(printf '%s' "${OUT}" | jq -cS .)" "$(printf '%s' "${OFF_BODY}" | jq -cS .)"

run --title "New feature" --body-file "${TMP}/body.txt" --project harness --kind Feature --severity none --security none
eq "a Feature sends severity null" "$(sent | jq -c '.filer')" '{"kind":"Feature","severity":null,"security":"none"}'

/usr/bin/ruby -e 'print "z" * 3000' > "${TMP}/long.txt"
run --title "T" --body-file "${TMP}/long.txt" --project harness "${FILER[@]}"
eq "a 3,000-character body is sent as 2,000 [qa manager 7]" "$(sent | jq -r '.ticket.body | length')" "2000"
has "stderr says it was truncated [qa manager 7]" "${ERR}" "[truncated]"
eq "a long body still exits 0" "${RC}" "0"
LANG=C LC_ALL=C run --title "$(printf 'é%.0s' $(seq 1 310))" --body-file "${TMP}/body.txt" --project harness "${FILER[@]}"
eq "a C-locale title is cut to 300 characters, not bytes" "$(sent | jq -r '.ticket.title | length')" "300"
has "and stderr says so" "${ERR}" "--title"

# A non-ASCII byte in the answer under a C locale is still read as UTF-8, never
# an UNEXPECTED ERROR (review round, DND-1054).
# "raw", so the fake sends the UTF-8 bytes (its json.dumps would escape them).
spec classify.json "$(jq -cn --argjson b "${OFF_BODY}" '{status: 200, raw: ($b | .provenance_line = "Jev classification: {\"note\":\"café\"}" | tojson)}')"
LANG=C LC_ALL=C run "${TICKET[@]}" "${FILER[@]}"
eq "a UTF-8 answer under LANG=C exits 0" "${RC}" "0"
has "and its provenance line is printed intact" "${OUT}" 'Jev classification: {"note":"café"}'

spec classify.json "$(jq -cn --argjson b "${MIXED_BODY}" '{status: 200, body: $b}')"
run "${TICKET[@]}" "${FILER[@]}"
eq "a per-property decision inside a 200 is exit 0, not unavailable" "${RC}" "0"
has "the policy's floor is shown as policy, not filer" "${OUT}" "Security: pre-existing (policy: vulnerability_floor)"

fallback_ok() {
  has "$1: it prints the filer's values under the unavailable heading" "${OUT}" "Decided (filer; classification unavailable):
Kind: Bug
Severity: MEDIUM
Security: none"
  lacks "$1: it prints no provenance line (never reads as a decision)" "${OUT}" "Jev classification:"
  lacks "$1: it prints no per-property source" "${OUT}" "(filer:"
  case "$(printf '%s\n' "${OUT}" | head -n 1)" in *"${PINNED}") ok "$1: the first line ends with the pinned Fix: [pin]" ;; *) bad "$1: the first line ends with the pinned Fix: [pin]" "first line: $(printf '%s\n' "${OUT}" | head -n 1)" ;; esac
}

# Unreachable: a closed port.
registry "http://127.0.0.1:9/mcp"
run "${TICKET[@]}" "${FILER[@]}"
eq "an unreachable server exits 3 [qa manager 2]" "${RC}" "3"
has "it says it could not reach the server [qa manager 2]" "$(printf '%s\n' "${OUT}" | head -n 1)" "COULD NOT REACH SERVER: curl exit"
fallback_ok "unreachable"
registry "http://127.0.0.1:${PORT}/mcp"

# No machine token: unreachable, naming the path read, never an empty token.
ATHENA_INBOX_CLIENT_CONFIG="${TMP}/cfg/absent.json" run "${TICKET[@]}" "${FILER[@]}"
eq "a missing token file exits 3 [qa library 2]" "${RC}" "3"
has "it names the path it read [qa library 2]" "${OUT}" "COULD NOT REACH SERVER: no machine token in ${TMP}/cfg/absent.json"
fallback_ok "no machine token"

# No athena MCP entry.
printf '{}\n' > "${FLEET_CLAUDE_JSON}"
run "${TICKET[@]}" "${FILER[@]}"
has "no athena MCP entry is could-not-reach" "${OUT}" "COULD NOT REACH SERVER: no athena MCP entry"
fallback_ok "no athena MCP entry"
registry "http://127.0.0.1:${PORT}/mcp"

spec classify.json '{"status":422,"body":{"error":"unprocessable_entity","fix":"filer.kind is missing or not one of the tracker'"'"'s values. Fix: send one of Feature, Bug."}}'
run "${TICKET[@]}" "${FILER[@]}"
eq "a 422 exits 3 [qa manager 3]" "${RC}" "3"
has "a 422 is its own line with the server's Fix: [qa manager 3]" "${OUT}" "SERVER REFUSED THE REQUEST: HTTP 422 unprocessable_entity: filer.kind is missing or not one of the tracker's values. Fix: send one of Feature, Bug. ${PINNED}"
fallback_ok "422"

spec classify.json '{"status":401,"body":{"error":"unauthorized"}}'
run "${TICKET[@]}" "${FILER[@]}"
eq "a 401 exits 3 [qa manager 4]" "${RC}" "3"
has "a 401 names the machine token [qa manager 4]" "${OUT}" "SERVER REFUSED THE REQUEST: HTTP 401 unauthorized: the machine token was rejected; it is owner-issued, never mint one"
lacks "a 401 is never could-not-reach" "${OUT}" "COULD NOT REACH SERVER"
fallback_ok "401"

spec classify.json '{"status":404,"body":{"error":"not_found"}}'
run "${TICKET[@]}" "${FILER[@]}"
eq "a 404 exits 3 (the endpoint is not deployed yet)" "${RC}" "3"
has "a 404 says the server does not serve classification" "${OUT}" "SERVER REFUSED THE REQUEST: HTTP 404 not_found: this server does not serve ticket_classification (DND-991 not deployed?). ${PINNED}"
fallback_ok "404"

spec classify.json '{"status":500,"body":{"error":"internal_error"}}'
run "${TICKET[@]}" "${FILER[@]}"
eq "a 5xx exits 3" "${RC}" "3"
has "a 5xx is its own line: the server failed, it was reached" "${OUT}" "SERVER FAILED: HTTP 500 internal_error. ${PINNED}"
lacks "a 5xx is never could-not-reach" "${OUT}" "COULD NOT REACH SERVER"
fallback_ok "5xx"

spec classify.json '{"status":200,"raw":"<html>proxy</html>"}'
run "${TICKET[@]}" "${FILER[@]}"
eq "a non-JSON 200 exits 3 [qa manager 5]" "${RC}" "3"
has "a non-JSON 200 is its own line [qa manager 5]" "${OUT}" "UNREADABLE SERVER ANSWER: HTTP 200 with a body that is not JSON. ${PINNED}"
fallback_ok "non-JSON 200"

spec classify.json '{"status":200,"body":{"status":"unavailable","reason":"not_configured"}}'
run "${TICKET[@]}" "${FILER[@]}"
eq "a wrong-shape 200 exits 3 [qa manager 5]" "${RC}" "3"
has "a wrong-shape 200 names the field, never reads as a decision [qa manager 5]" "${OUT}" "UNREADABLE SERVER ANSWER: HTTP 200 but status is not \"judged\". ${PINNED}"
fallback_ok "wrong-shape 200"

# A Feature decided end to end: exit 0, no severity value.
spec classify.json "$(jq -cn --argjson b "${OFF_BODY}" '{status: 200, body: ($b | .properties.kind.decided = "Feature" | .properties.severity = {decided: null, source: "filer", judged: null, accepted: false, reason: "feature", mode: "off"})}')"
run --title "New feature" --body-file "${TMP}/body.txt" --project harness --kind Feature --severity none --security none
eq "a Feature answer exits 0" "${RC}" "0"
has "and prints no severity value" "${OUT}" "Severity: (none: Feature) (filer: feature)"
spec classify.json "$(jq -cn --argjson b "${OFF_BODY}" '{status: 200, body: $b}')"

# A token a curl config line cannot carry: refused before any request.
jq -n '{token: "bad\"token"}' > "${TMP}/cfg/quote.json"
: > "${TMP}/server.log"
ATHENA_INBOX_CLIENT_CONFIG="${TMP}/cfg/quote.json" run "${TICKET[@]}" "${FILER[@]}"
eq "an unsafe token exits 3" "${RC}" "3"
has "it names the refusal, never the token" "${OUT}" "COULD NOT REACH SERVER: a request value contains a quote, backslash or control character."
lacks "the token is never printed" "${OUT}" 'bad"token'
eq "an unsafe token sends nothing" "$(requests)" "0"
fallback_ok "unsafe token"

# No curl on PATH (the script's shebang is absolute, so it still runs).
OUT="$(PATH=/nonexistent HOME="${TMP}/home" "${BIN}" "${TICKET[@]}" "${FILER[@]}" 2>"${TMP}/err")"
RC=$?
eq "no curl exits 3" "${RC}" "3"
has "it says curl is missing" "${OUT}" "COULD NOT REACH SERVER: curl is not on PATH."
fallback_ok "no curl"

# A title blank in what is sent is usage, never a 422 after the fact.
run --title "$(printf ' %.0s' $(seq 1 300))x" --body-file "${TMP}/body.txt" --project harness "${FILER[@]}"
eq "a title blank in its first 300 characters is usage (2)" "${RC}" "2"

# Truncation counts grapheme clusters, as the server does.
run --title "$(for _ in $(seq 1 301); do printf 'e\xcc\x81'; done)" --body-file "${TMP}/body.txt" --project harness "${FILER[@]}"
eq "a title of 301 combining clusters sends 300 clusters (600 codepoints)" "$(sent | jq -r '.ticket.title | length')" "600"

echo "== --lines-out (DND-1354)"

spec classify.json "$(jq -cn --argjson b "${OFF_BODY}" '{status: 200, body: $b}')"
rm -f "${TMP}/lines.txt"
run "${TICKET[@]}" "${FILER[@]}" --lines-out "${TMP}/lines.txt"
eq "--lines-out exits 0 [ticket 1354]" "${RC}" "0"
eq "--lines-out writes exactly the printed Jev classification: line [ticket 1354]" \
  "$(cat "${TMP}/lines.txt" 2>/dev/null)" "$(printf '%s\n' "${OUT}" | grep '^Jev classification: ')"
eq "--lines-out writes one line, the provenance line" "$(grep -c '^Jev classification: {' "${TMP}/lines.txt" 2>/dev/null)|$(grep -c . "${TMP}/lines.txt" 2>/dev/null)" "1|1"
eq "--lines-out writes the file 0600" "$(stat -c %a "${TMP}/lines.txt" 2>/dev/null)" "600"
has "stdout still prints the decision" "${OUT}" "Kind: Bug (filer: mode_off)"
cp "${TMP}/body.txt" "${TMP}/body.keep"
run "${TICKET[@]}" "${FILER[@]}" --lines-out "${TMP}/body.txt"
eq "--lines-out onto the body file is usage (2), never a clobbered draft" "${RC}" "2"
has "it says so with Fix:" "${ERR}" "Fix:"
eq "the body file is untouched" "$(cmp -s "${TMP}/body.txt" "${TMP}/body.keep" && echo same)" "same"
run "${TICKET[@]}" "${FILER[@]}" --json --lines-out "${TMP}/lines-json.txt"
eq "--lines-out with --json is usage (2)" "${RC}" "2"
spec classify.json '{"status": 503, "body": {"error": "overloaded"}}'
printf 'stale\n' > "${TMP}/lines.txt"
run "${TICKET[@]}" "${FILER[@]}" --lines-out "${TMP}/lines.txt"
eq "an unavailable classification still exits 3 with --lines-out" "${RC}" "3"
eq "--lines-out is emptied when no line was printed (never a stale line) [ticket 1354]" "$(wc -c < "${TMP}/lines.txt" | tr -d ' ')" "0"
has "stderr says no line was written" "${ERR}" "--lines-out: no Jev line was printed"
spec classify.json "$(jq -cn --argjson b "${OFF_BODY}" '{status: 200, body: $b}')"
printf 'Jev classification: {"an":"older filing"}\n' > "${TMP}/lines-ro.txt"
chmod 400 "${TMP}/lines-ro.txt"
: > "${TMP}/server.log"
run "${TICKET[@]}" "${FILER[@]}" --lines-out "${TMP}/lines-ro.txt"
eq "an existing --lines-out that cannot be written is usage (2) before anything is sent [review]" "${RC}|$(requests)" "2|0"
has "it says so with Fix:" "${ERR}" "--lines-out ${TMP}/lines-ro.txt is not writable. Fix:"
chmod 600 "${TMP}/lines-ro.txt"

echo
echo "ticket-classify self-test: ${PASS} passed, ${FAIL} failed"
[ "${FAIL}" -eq 0 ]
