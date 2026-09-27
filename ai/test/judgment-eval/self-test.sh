#!/usr/bin/env bash
# self-test.sh -- the judgment-eval suite (DND-710). Discovered by harness-gate
# (every committed `self-test.sh` runs).
#
# Two layers, in TDD order:
#   1. domain  -- ai/lib/judgment_eval.rb, pure functions, called from ruby -e;
#   2. end to end -- ai/bin/judgment-eval against a FAKE server
#      (fake-judgments-server.py) that answers the way gen_saas
#      Athena.Judgments.Evals does. Never prod: every URL is 127.0.0.1, and the
#      token, MCP registry, and run directory are temp fixtures.
#
# The ticket's fail-first cases are marked [ticket]: a missing corpus file is
# distinct from an empty corpus; an id-join miss is reported by count and
# names the missing ids; --dry-run makes no network call; an all-fallback run
# prints "scored 0 / unscored N (not_configured)", never a precision, and
# exits 3 with "no key; see DND-711"; a label under 10 cases prints
# "n/a (n=<k>, needs 10)". Plus the token never reaching argv or env.

set -u

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
AI="$(cd -- "${HERE}/../.." && pwd -P)"
BIN="${AI}/bin/judgment-eval"
LIBRB="${AI}/lib/judgment_eval.rb"
FAKE="${HERE}/fake-judgments-server.py"

PASS=0
FAIL=0
ok()   { PASS=$((PASS + 1)); printf 'ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL + 1)); printf 'FAIL %s\n' "$1"; [ -n "${2:-}" ] && printf '     %s\n' "$2"; return 0; }
eq()   { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$3], got [$2]"; fi; }
has()  { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "no [$3] in: $2" ;; esac; }
lacks() { case "$2" in *"$3"*) bad "$1" "unexpected [$3] in: $2" ;; *) ok "$1" ;; esac; }

for dep in ruby python3 curl jq git; do
  command -v "${dep}" >/dev/null 2>&1 || { echo "judgment-eval self-test: FAIL -- ${dep} is not on PATH"; echo "  Fix: install ${dep}; this suite does not skip."; exit 1; }
done
[ -x "${BIN}" ] || { echo "judgment-eval self-test: FAIL -- ${BIN} missing or not executable"; echo "  Fix: chmod +x ai/bin/judgment-eval"; exit 1; }

TMP="$(mktemp -d)" || { echo "FAIL mktemp"; exit 1; }
SERVER_PID=""
cleanup() {
  [ -n "${SERVER_PID}" ] && kill "${SERVER_PID}" 2>/dev/null
  rm -rf "${TMP}"
}
trap cleanup EXIT INT TERM

# ruby_eq NAME EXPECTED RUBY-EXPR -- evaluate EXPR against the domain lib.
ruby_eq() {
  local got
  got="$(ruby -r "${LIBRB}" -e "puts(begin; $3; rescue JudgmentEval::InputError => e; 'InputError: ' + e.message; end)" 2>&1)"
  eq "$1" "${got}" "$2"
}

echo "== domain"

ruby_eq "summary: all not_configured is scored 0 / unscored N (not_configured) [ticket]" \
  "scored 0 / unscored 3 (not_configured)" \
  'JudgmentEval.summary_lines({"scored"=>0,"unscored"=>{"not_configured"=>3},"labels"=>[]}).join("|")'
ruby_eq "summary: scored 0 prints no label line even if the report had labels" \
  "scored 0 / unscored 2 (not_configured 1, timeout 1)" \
  'JudgmentEval.summary_lines({"scored"=>0,"unscored"=>{"timeout"=>1,"not_configured"=>1},"labels"=>[{"label"=>"x","chosen"=>nil,"n_a"=>{"reason"=>"too_few_routed","n"=>0,"needs"=>10}}]}).join("|")'
ruby_eq "summary: a label under 10 cases is n/a (n=<k>, needs 10) [ticket]" \
  "  harness: n/a (n=7, needs 10)" \
  'JudgmentEval.label_line({"label"=>"harness","chosen"=>nil,"n_a"=>{"reason"=>"too_few_routed","n"=>7,"needs"=>10}})'
ruby_eq "summary: a label whose bound misses the target names the best bound" \
  "  harness: n/a (best lb 0.898 < 0.90 at every threshold)" \
  'JudgmentEval.label_line({"label"=>"harness","chosen"=>nil,"n_a"=>{"reason"=>"precision_below_target","best_precision_lb"=>0.8984,"target"=>0.9}})'
ruby_eq "summary: a chosen label prints its threshold and provenance figures" \
  "  harness: threshold 0.35 (precision 1.000, lb 0.901, coverage 1.000, n 35)" \
  'JudgmentEval.label_line({"label"=>"harness","chosen"=>{"threshold"=>0.35,"precision"=>1.0,"precision_lb"=>0.90109,"coverage"=>1.0,"n"=>35}})'
ruby_eq "labels: an empty file is its own error" \
  "InputError: labels file L is empty (0 rows)" \
  'JudgmentEval.parse_labels("\n\n", "L")'
ruby_eq "labels: a bad row names its line, never its text" \
  "InputError: L:2 is not a JSON object" \
  'JudgmentEval.parse_labels(%({"id":"a","label":"x","provenance":"proposed"}\nSECRET TEXT\n), "L")'
ruby_eq "labels: an unknown provenance is refused" \
  "InputError: L:1 has provenance guess" \
  'JudgmentEval.parse_labels(%({"id":"a","label":"x","provenance":"guess"}\n), "L")'
ruby_eq "labels: a repeated id is refused" \
  "InputError: L:2 repeats id of line 1" \
  'JudgmentEval.parse_labels(%({"id":"a","label":"x","provenance":"proposed"}\n{"id":"a","label":"y","provenance":"proposed"}\n), "L")'
ruby_eq "corpus: slack_routing joins on event_id; a row with no id is counted" \
  "1 1 event_id" \
  'c = JudgmentEval.parse_corpus(%({"event_id":"Ev1","text":"t"}\n{"text":"no id"}\n), "C", "slack_routing"); [c[:rows].size, c[:without_id], c[:id_key]].join(" ")'
ruby_eq "corpus: an input member is sent, else the whole row" \
  '{"text":"t"} {"id":"b","text":"u"}' \
  'c = JudgmentEval.parse_corpus(%({"id":"a","input":{"text":"t"}}\n{"id":"b","text":"u"}\n), "C", "finding_triage"); [c[:rows]["a"][:input], c[:rows]["b"][:input]].map { |i| JSON.generate(i) }.join(" ")'
ruby_eq "join: proposed excluded and counted; a miss is named [ticket]" \
  "1 1 missing=c" \
  'l = JudgmentEval.parse_labels(%({"id":"a","label":"x","provenance":"owner_confirmed"}\n{"id":"b","label":"x","provenance":"proposed"}\n{"id":"c","label":"x","provenance":"forward_record"}\n), "L"); c = JudgmentEval.parse_corpus(%({"id":"a"}\n{"id":"b"}\n), "C", "finding_triage"); j = JudgmentEval.join(l, c); [j[:cases].size, j[:proposed], "missing=" + j[:missing].join(",")].join(" ")'
ruby_eq "domain: a case with neither its own nor a default domain is counted" \
  "1" \
  'JudgmentEval.with_domain([{"case_id"=>"a","content_domain"=>nil},{"case_id"=>"b","content_domain"=>"work"}], nil)[1]'

echo "== end to end"

TOKEN="judgment-eval-test-token-$$-${RANDOM}-c4e1"
printf '%s\n' "${TOKEN}" > "${TMP}/token"
mkdir -p "${TMP}/cfg" "${TMP}/data" "${TMP}/home"
jq -n --arg t "${TOKEN}" '{server_url: "wss://example.invalid/machine/websocket", token: $t}' > "${TMP}/cfg/config.json"
chmod 600 "${TMP}/cfg/config.json"
export ATHENA_INBOX_CLIENT_CONFIG="${TMP}/cfg/config.json"
export FLEET_CLAUDE_JSON="${TMP}/claude.json"
export XDG_DATA_HOME="${TMP}/data"
: > "${TMP}/server.log"
printf '{"auto":"not_configured"}\n' > "${TMP}/responses.json"

python3 "${FAKE}" "${TMP}/port" "${TMP}/server.log" "${TMP}/responses.json" "${TMP}/token" &
SERVER_PID=$!
for _i in $(seq 1 100); do
  [ -s "${TMP}/port" ] && break
  sleep 0.05
done
[ -s "${TMP}/port" ] || { echo "FAIL fake server did not start"; exit 1; }
PORT="$(cat "${TMP}/port")"
jq -n --arg u "http://127.0.0.1:${PORT}/mcp" '{mcpServers: {athena: {type: "http", url: $u}}}' > "${FLEET_CLAUDE_JSON}"

requests() { local c; c="$(grep -c . "${TMP}/server.log" 2>/dev/null)"; printf '%s\n' "${c:-0}"; }
respond() { printf '%s\n' "$1" > "${TMP}/responses.json"; }

# Synthetic fixtures only: label files are machine-local and never committed.
cat > "${TMP}/labels.jsonl" <<'EOF'
{"id":"c1","label":"duplicate","provenance":"owner_confirmed","labeler":"owner","labeled_at":"2026-09-27T00:00:00Z"}
{"id":"c2","label":"related","provenance":"forward_record","labeler":"owner","labeled_at":"2026-09-27T00:00:00Z"}
{"id":"c3","label":"unrelated","provenance":"owner_confirmed","labeler":"owner","labeled_at":"2026-09-27T00:00:00Z"}
{"id":"c4","label":"duplicate","provenance":"proposed","labeler":"athena","labeled_at":"2026-09-27T00:00:00Z"}
EOF
cat > "${TMP}/corpus.jsonl" <<'EOF'
{"id":"c1","input":{"title":"SYNTHETIC-INPUT-one"}}
{"id":"c2","input":{"title":"SYNTHETIC-INPUT-two"}}
{"id":"c3","input":{"title":"SYNTHETIC-INPUT-three"}}
{"id":"c4","input":{"title":"SYNTHETIC-INPUT-four"}}
EOF

run() {
  OUT="$("${BIN}" "$@" 2>"${TMP}/err")"
  RC=$?
  ERR="$(cat "${TMP}/err")"
}

run --help
eq "--help exits 0" "${RC}" "0"
has "--help prints the usage on stdout" "${OUT}" "Usage: judgment-eval"

run --use-case finding_triage --labels "${TMP}/labels.jsonl"
eq "a missing --corpus is usage (2)" "${RC}" "2"
has "the usage error carries Fix:" "${ERR}" "Fix: "
run --use-case finding_triage --labels "${TMP}/labels.jsonl" --corpus "${TMP}/corpus.jsonl" --bogus
eq "an unknown flag is usage (2)" "${RC}" "2"
run --use-case general --labels "${TMP}/labels.jsonl" --corpus "${TMP}/corpus.jsonl" --content-domain blend
eq "an unknown use case is usage (2)" "${RC}" "2"

n="$(requests)"
run --use-case finding_triage --labels "${TMP}/labels.jsonl" --corpus "${TMP}/absent.jsonl" --content-domain blend
eq "a missing corpus file is exit 1 [ticket]" "${RC}" "1"
has "a missing corpus file says it does not exist [ticket]" "${ERR}" "corpus file ${TMP}/absent.jsonl does not exist"
: > "${TMP}/empty.jsonl"
run --use-case finding_triage --labels "${TMP}/labels.jsonl" --corpus "${TMP}/empty.jsonl" --content-domain blend
eq "an empty corpus is exit 1 [ticket]" "${RC}" "1"
has "an empty corpus says it is empty, distinct from missing [ticket]" "${ERR}" "corpus file ${TMP}/empty.jsonl is empty (0 rows)"
lacks "the empty-corpus line is not the missing-file line [ticket]" "${ERR}" "does not exist"
run --use-case finding_triage --labels "${TMP}/absent-labels.jsonl" --corpus "${TMP}/corpus.jsonl" --content-domain blend
has "a missing labels file says so" "${ERR}" "labels file ${TMP}/absent-labels.jsonl does not exist"
run --use-case finding_triage --labels "${TMP}/labels.jsonl" --corpus "${TMP}/corpus.jsonl"
eq "cases with no content domain are usage (2): never guessed" "${RC}" "2"
has "the domain refusal names --content-domain" "${ERR}" "--content-domain"
eq "no input or usage failure sent anything" "$(requests)" "${n}"

# The join miss: c3's corpus row is absent.
grep -v '"c3"' "${TMP}/corpus.jsonl" > "${TMP}/corpus-miss.jsonl"
mv "${TMP}/cfg/config.json" "${TMP}/cfg/moved.json"
run --use-case finding_triage --labels "${TMP}/labels.jsonl" --corpus "${TMP}/corpus-miss.jsonl" --content-domain blend --dry-run
mv "${TMP}/cfg/moved.json" "${TMP}/cfg/config.json"
eq "--dry-run with a join miss exits 0" "${RC}" "0"
has "a join miss is reported by count [ticket]" "${ERR}" "join: 1 of 3 labels have no corpus row with that id"
has "a join miss names the missing id [ticket]" "${ERR}" ": c3. Fix: "
has "--dry-run prints the joined cases" "${OUT}" "cases: 2 (duplicate 1, related 1)"
has "--dry-run counts the excluded proposed label" "${OUT}" "proposed excluded: 1"
has "--dry-run says nothing was sent" "${OUT}" "nothing sent"
eq "--dry-run makes no network call, and reads no token [ticket]" "$(requests)" "${n}"
run --use-case finding_triage --labels "${TMP}/labels.jsonl" --corpus "${TMP}/corpus.jsonl" --content-domain blend --dry-run
eq "--dry-run with a token and a live server exits 0" "${RC}" "0"
eq "--dry-run with a token and a live server still sends nothing [ticket]" "$(requests)" "${n}"

printf '{"id":"zz","label":"x","provenance":"owner_confirmed"}\n' > "${TMP}/labels-none.jsonl"
run --use-case finding_triage --labels "${TMP}/labels-none.jsonl" --corpus "${TMP}/corpus.jsonl" --content-domain blend --dry-run
eq "no label joining the corpus is exit 1, never an empty run" "${RC}" "1"
has "the no-join line names the join key" "${ERR}" "the join key is id"

# All fallback: the server has no key.
respond '{"auto":"not_configured"}'
run --use-case finding_triage --labels "${TMP}/labels.jsonl" --corpus "${TMP}/corpus.jsonl" --content-domain blend --pause 0
eq "an all-not_configured run exits 3 [ticket]" "${RC}" "3"
has "it prints scored 0 / unscored 3 (not_configured) [ticket]" "${OUT}" "scored 0 / unscored 3 (not_configured)"
lacks "it never prints a precision [ticket]" "${OUT}" "precision"
has "it says no key; see DND-711, with Fix: [ticket]" "${ERR}" "no key; see DND-711. Fix: "
eq "one batch was sent" "$(requests)" "$((n + 1))"
last="$(tail -n 1 "${TMP}/server.log")"
eq "the request authenticated with the machine token" "$(jq -r .auth_ok <<<"${last}")" "true"
eq "the token was in no process's argv while in flight" "$(jq -c .argv_leak <<<"${last}")" "[]"
eq "the token was in no process's environment while in flight" "$(jq -c .environ_leak <<<"${last}")" "[]"
eq "the request is POST /api/v1/judgments/eval" "$(jq -r '.method + " " + .path' <<<"${last}")" "POST /api/v1/judgments/eval"
eq "proposed labels are not sent" "$(jq -c '[.body.cases[].case_id]' <<<"${last}")" '["c1","c2","c3"]'
eq "each case carries its label and domain" "$(jq -c '.body.cases[0] | [.label, .content_domain]' <<<"${last}")" '["duplicate","blend"]'
run_file="$(find "${XDG_DATA_HOME}/athena/evals/runs" -maxdepth 1 -type f -name '*-finding_triage.json' | head -n 1)"
if [ -n "${run_file}" ]; then ok "a run file was written under XDG_DATA_HOME/athena/evals/runs"; else bad "a run file was written under XDG_DATA_HOME/athena/evals/runs"; fi
eq "the run file is 0600" "$(stat -c %a "${run_file}" 2>/dev/null)" "600"
if grep -q SYNTHETIC-INPUT "${run_file}" 2>/dev/null; then bad "the run file holds no case input"; else ok "the run file holds no case input"; fi
eq "the run file records the labels file's sha256" "$(jq -r .labels_sha256 "${run_file}")" "$(sha256sum "${TMP}/labels.jsonl" | cut -d' ' -f1)"

# Batching: 60 cases, batch size 50: two requests; the second names the run.
: > "${TMP}/labels60.jsonl"; : > "${TMP}/corpus60.jsonl"
for i in $(seq 1 60); do
  printf '{"id":"k%s","label":"duplicate","provenance":"owner_confirmed"}\n' "${i}" >> "${TMP}/labels60.jsonl"
  printf '{"id":"k%s","input":{"t":"x"}}\n' "${i}" >> "${TMP}/corpus60.jsonl"
done
n="$(requests)"
run --use-case finding_triage --labels "${TMP}/labels60.jsonl" --corpus "${TMP}/corpus60.jsonl" --content-domain work --pause 0
eq "60 cases went in two requests" "$(requests)" "$((n + 2))"
eq "the first batch held 50 cases" "$(sed -n "$((n + 1))p" "${TMP}/server.log" | jq '.body.cases | length')" "50"
eq "the first batch starts a run (no eval_run_id)" "$(sed -n "$((n + 1))p" "${TMP}/server.log" | jq -r '.body.eval_run_id // "none"')" "none"
eq "the second batch appends to the first's run" "$(sed -n "$((n + 2))p" "${TMP}/server.log" | jq -r .body.eval_run_id)" "5f0c3a1e-8b2d-4c6f-9a7e-1d2b3c4d5e6f"

# A scored run: exit 0, per-label lines.
report='{"cases":12,"scored":12,"unscored":{},"labels":[{"label":"duplicate","positives":12,"chosen":null,"n_a":{"reason":"too_few_routed","n":7,"needs":10}}]}'
respond "{\"status\":200,\"body\":{\"data\":{\"eval_run_id\":\"5f0c3a1e-8b2d-4c6f-9a7e-1d2b3c4d5e6f\",\"use_case\":\"finding_triage\",\"question_set_version\":\"v1\",\"model\":\"jev-1.13.0\",\"results\":[],\"report\":${report}}}}"
run --use-case finding_triage --labels "${TMP}/labels.jsonl" --corpus "${TMP}/corpus.jsonl" --content-domain blend --pause 0
eq "a run that scored cases exits 0" "${RC}" "0"
has "a label under 10 cases prints n/a (n=7, needs 10) [ticket]" "${OUT}" "duplicate: n/a (n=7, needs 10)"
has "it prints how to apply the run" "${OUT}" "--apply 5f0c3a1e-8b2d-4c6f-9a7e-1d2b3c4d5e6f"

# The use case's question set has not shipped yet.
respond '{"status":409,"body":{"error":"question_set_unavailable","fix":"use case finding_triage has no question set on this server yet. Fix: it ships with DND-713."}}'
run --use-case finding_triage --labels "${TMP}/labels.jsonl" --corpus "${TMP}/corpus.jsonl" --content-domain blend --pause 0
eq "question_set_unavailable exits 3" "${RC}" "3"
has "it prints JUDGMENTS UNAVAILABLE with the server's Fix:" "${ERR}" "JUDGMENTS UNAVAILABLE: question_set_unavailable: use case finding_triage has no question set on this server yet. Fix: it ships with DND-713."

respond '{"status":422,"body":{"error":"unprocessable_entity","fix":"cases[0].label is missing. Fix: send it."}}'
run --use-case finding_triage --labels "${TMP}/labels.jsonl" --corpus "${TMP}/corpus.jsonl" --content-domain blend --pause 0
eq "a refusal exits 5" "${RC}" "5"
has "a refusal prints the server's fix" "${ERR}" "cases[0].label is missing. Fix: send it."

respond '{"status":500,"body":{"error":"internal_error"}}'
run --use-case finding_triage --labels "${TMP}/labels.jsonl" --corpus "${TMP}/corpus.jsonl" --content-domain blend --pause 0
eq "a server fault exits 5" "${RC}" "5"
has "a fault says the server faulted" "${ERR}" "the server faulted (HTTP 500)"

# Unreachable: a distinct line and exit, never "no key" or "no duplicates".
closed="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')"
jq -n --arg u "http://127.0.0.1:${closed}/mcp" '{mcpServers: {athena: {type: "http", url: $u}}}' > "${FLEET_CLAUDE_JSON}"
run --use-case finding_triage --labels "${TMP}/labels.jsonl" --corpus "${TMP}/corpus.jsonl" --content-domain blend --pause 0
eq "an unreachable server exits 4" "${RC}" "4"
has "it says it could not reach the server" "${ERR}" "could not reach the Athena server"
lacks "unreachable is not reported as no key" "${ERR}" "DND-711"
jq -n --arg u "http://athena.example.invalid/mcp" '{mcpServers: {athena: {type: "http", url: $u}}}' > "${FLEET_CLAUDE_JSON}"
run --use-case finding_triage --labels "${TMP}/labels.jsonl" --corpus "${TMP}/corpus.jsonl" --content-domain blend --pause 0
eq "a non-loopback http URL is refused locally (1)" "${RC}" "1"
has "the refusal says the token would be sent in clear text" "${ERR}" "clear text"
jq -n --arg u "http://127.0.0.1:${PORT}/mcp" '{mcpServers: {athena: {type: "http", url: $u}}}' > "${FLEET_CLAUDE_JSON}"
ATHENA_INBOX_CLIENT_CONFIG="${TMP}/nope.json" run --use-case finding_triage --labels "${TMP}/labels.jsonl" --corpus "${TMP}/corpus.jsonl" --content-domain blend --pause 0
eq "no token config is exit 1" "${RC}" "1"
has "no token config says the token is owner-issued" "${ERR}" "owner-issued"

# --apply
n="$(requests)"
run --apply "5f0c3a1e-8b2d-4c6f-9a7e-1d2b3c4d5e6f" --dry-run
eq "--apply --dry-run exits 0" "${RC}" "0"
eq "--apply --dry-run prints only the run id body" "${OUT}" '{"eval_run_id":"5f0c3a1e-8b2d-4c6f-9a7e-1d2b3c4d5e6f"}'
eq "--apply --dry-run sends nothing" "$(requests)" "${n}"
run --apply "not-a-uuid"
eq "--apply with a non-uuid is usage (2)" "${RC}" "2"
run --apply "5f0c3a1e-8b2d-4c6f-9a7e-1d2b3c4d5e6f" --use-case finding_triage
eq "--apply with eval flags is usage (2)" "${RC}" "2"
respond '{"status":200,"body":{"data":{"eval_run_id":"5f0c3a1e-8b2d-4c6f-9a7e-1d2b3c4d5e6f","use_case":"finding_triage","question_set_version":"v1","model":"jev-1.13.0","thresholds":[{"label":"duplicate","enabled":true,"threshold":0.35,"precision_lb":0.901,"coverage":1.0,"n":35},{"label":"related","enabled":false,"threshold":0.0,"precision_lb":0.5,"coverage":0.4,"n":7}]}}}'
run --apply "5f0c3a1e-8b2d-4c6f-9a7e-1d2b3c4d5e6f"
eq "--apply exits 0" "${RC}" "0"
last="$(tail -n 1 "${TMP}/server.log")"
eq "--apply is PUT /api/v1/judgments/thresholds" "$(jq -r '.method + " " + .path' <<<"${last}")" "PUT /api/v1/judgments/thresholds"
eq "--apply sends only the run id, never thresholds" "$(jq -c .body <<<"${last}")" '{"eval_run_id":"5f0c3a1e-8b2d-4c6f-9a7e-1d2b3c4d5e6f"}'
eq "--apply keeps the token out of argv" "$(jq -c .argv_leak <<<"${last}")" "[]"
has "--apply prints an enabled label" "${OUT}" "duplicate: enabled at 0.35 (lb 0.901, coverage 1.000, n 35)"
has "--apply prints a disabled label as n/a" "${OUT}" "related: disabled (n/a, n 7)"
respond '{"status":404,"body":{"error":"not_found"}}'
run --apply "5f0c3a1e-8b2d-4c6f-9a7e-1d2b3c4d5e6f"
eq "--apply of a run that is absent or another owner's exits 5" "${RC}" "5"
has "the not_found line says it may not be this owner's" "${ERR}" "not this machine owner's"

# ---------------------------------------------------------------------------
printf '\n%d passed, %d failed\n' "${PASS}" "${FAIL}"
if [ "${FAIL}" -ne 0 ]; then
  echo "judgment-eval self-test: FAILED"
  echo "  Fix: make ai/bin/judgment-eval and ai/lib/judgment_eval.rb satisfy the failing cases above (contract: ai/contracts/athena-judgments.md -> Threshold provenance, n/a and the pinned model)."
  exit 1
fi
echo "judgment-eval self-test: OK"
exit 0
