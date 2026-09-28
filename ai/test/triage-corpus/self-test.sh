#!/usr/bin/env bash
# self-test.sh -- the triage-corpus suite (DND-714). Discovered by
# harness-gate (every committed `self-test.sh` runs).
#
# Three layers, in TDD order:
#   1. domain  -- ai/lib/triage_corpus.rb, pure functions, called from ruby -e;
#   2. build   -- ai/bin/triage-corpus --build over a FIXTURE snapshot, then
#                 ai/bin/judgment-eval --dry-run over the files it wrote;
#   3. fetch   -- ai/bin/triage-corpus --fetch against a FAKE Notion
#                 (fake-notion-server.py, loopback only, never Notion).
#
# The fail-first cases are marked [ticket]: duplicate / related / unrelated
# extraction, proposed labels excluded from the eval, the domain never
# guessed, label-leak redaction, and an unread body excluded (never passed).
# The n/a "insufficient evidence" display is judgment-eval's, tested in
# ai/test/judgment-eval/self-test.sh.

set -u

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
AI="$(cd -- "${HERE}/../.." && pwd -P)"
BIN="${AI}/bin/triage-corpus"
EVAL="${AI}/bin/judgment-eval"
LIBRB="${AI}/lib/triage_corpus.rb"
FAKE="${HERE}/fake-notion-server.py"

PASS=0
FAIL=0
ok()   { PASS=$((PASS + 1)); printf 'ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL + 1)); printf 'FAIL %s\n' "$1"; [ -n "${2:-}" ] && printf '     %s\n' "$2"; return 0; }
eq()   { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$3], got [$2]"; fi; }
has()  { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "no [$3] in: $2" ;; esac; }
lacks() { case "$2" in *"$3"*) bad "$1" "unexpected [$3] in: $2" ;; *) ok "$1" ;; esac; }

for dep in ruby python3 curl jq git; do
  command -v "${dep}" >/dev/null 2>&1 || { echo "triage-corpus self-test: FAIL -- ${dep} is not on PATH"; echo "  Fix: install ${dep}; this suite does not skip."; exit 1; }
done
for f in "${BIN}" "${EVAL}"; do
  [ -x "${f}" ] || { echo "triage-corpus self-test: FAIL -- ${f} missing or not executable"; echo "  Fix: chmod +x ${f#"${AI}/../"}"; exit 1; }
done
[ -f "${LIBRB}" ] || { echo "triage-corpus self-test: FAIL -- ${LIBRB} missing"; echo "  Fix: add the domain lib ai/lib/triage_corpus.rb"; exit 1; }

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
  got="$(ruby -rjson -r "${LIBRB}" -e "puts(begin; $3; rescue TriageCorpus::InputError => e; 'InputError: ' + e.message; end)" 2>&1)"
  eq "$1" "${got}" "$2"
}

echo "== domain"

ruby_eq "duplicate: 'Duplicate of DND-12.' names DND-12 [ticket]" \
  "DND-12" 'TriageCorpus.duplicate_refs("Cancelled. Duplicate of DND-12.").join(",")'
ruby_eq "duplicate: 'dup of DND-7' and 'duplicates DND-8' both count" \
  "DND-7,DND-8" 'TriageCorpus.duplicate_refs("a dup of DND-7\nthis duplicates DND-8").join(",")'
ruby_eq "duplicate: a negation voids it ('not a duplicate of DND-12') [ticket]" \
  "" 'TriageCorpus.duplicate_refs("This is not a duplicate of DND-12.").join(",")'
ruby_eq "duplicate: a ref in the next sentence is not the duplicate" \
  "" 'TriageCorpus.duplicate_refs("Checked for a duplicate. See DND-4.").join(",")'
ruby_eq "refs: distinct, first-mention order, leading zeros dropped" \
  "DND-3,DND-12" 'TriageCorpus.refs_in("DND-3 then DND-012 then DND-3").join(",")'
ruby_eq "redact: refs become [ref] and duplicate lines are dropped [ticket]" \
  "Widget breaks on save.|See [ref] for context." \
  'TriageCorpus.redact("Duplicate of DND-2.\nWidget breaks on save.\nSee DND-9 for context.").split("\n").join("|")'
ruby_eq "epic_projects: an epic claimed by two projects is ambiguous (nil)" \
  "harness nil" \
  'rows = TriageCorpus::REPO_APPS.values.flatten.map { |a| {"repo_app"=>a,"epic_ids"=>[]} }; rows << {"repo_app"=>"~/dev/custom","epic_ids"=>["E1","E2"]}; rows << {"repo_app"=>"walt_ui","epic_ids"=>["E2"]}; m = TriageCorpus.epic_projects(rows); [m["E1"], m["E2"].inspect].join(" ")'
ruby_eq "epic_projects: a mapped Repo / App no row carries is an error, not an empty project" \
  "InputError: no DND Projects row has Repo / App walt_ui" \
  'rows = (TriageCorpus::REPO_APPS.values.flatten - ["walt_ui"]).map { |a| {"repo_app"=>a,"epic_ids"=>[]} }; TriageCorpus.epic_projects(rows)'
ruby_eq "ticket_from_row: a row with no DND id is skipped" \
  "nil" 'TriageCorpus.ticket_from_row({"id"=>"x","properties"=>{"ID"=>{"unique_id"=>{"prefix"=>"PT","number"=>3}}}}).inspect'

# ── the fixture snapshot ────────────────────────────────────────────────────
# harness epic EH, walt_ui epic EW. Tickets (ref, area, text / links):
#   10 Harness  base defect
#   11 Harness  "Duplicate of DND-10."             -> duplicate 11:10
#   12 Harness  Depends On 10                      -> related 12:10 depends_on
#   13 Harness  cites DND-11                       -> related 13:11 citation
#   14 Product  nothing                            -> unrelated rule_confirmed with Harness tickets
#   15 walt_ui  cites DND-10                       -> cross_project, excluded
#   16 (no epic) cites DND-10                      -> no_project, excluded
#   17 Harness  UNREAD, Depends On 10              -> body_unread, excluded
#   18 Harness  Found while 10                     -> linked, never related, never unrelated
#   19 Harness  "not a duplicate of DND-12"        -> related 19:12 citation, not duplicate
#   20 Harness  cites 9 tickets                    -> citation_list_skipped
#   21 Harness  cites DND-999 (unknown)            -> unknown_ref
mkdir -p "${TMP}/evals"
ruby -rjson -e '
  def t(n, epic, area, text, extra = {})
    { "page_id" => "p#{n}", "ref" => "DND-#{n}", "title" => "Ticket #{n} about the widget", "status" => "Todo",
      "area" => area, "severity" => nil, "epic_ids" => epic ? [epic] : [], "depends_on" => [], "blocks" => [],
      "found_while" => [], "relations_truncated" => false, "blocks_text" => text, "body_read" => true }.merge(extra)
  end
  tickets = [
    t(10, "EH", "Harness", ["Base defect in the widget save path."]),
    t(11, "EH", "Harness", ["Duplicate of DND-10.", "Widget save path breaks."]),
    t(12, "EH", "Harness", ["Needs the save fix first."], "depends_on" => ["p10"]),
    t(13, "EH", "Harness", ["Follow-up to DND-11."]),
    t(14, "EH", "Product", ["Unrelated billing page copy."]),
    t(15, "EW", "Product", ["Mirrors DND-10 in walt_ui."]),
    t(16, nil, "Harness", ["Also about DND-10."]),
    t(17, "EH", "Harness", [], "body_read" => false, "depends_on" => ["p10"]),
    t(18, "EH", "Harness", ["Found during other work."], "found_while" => ["p10"]),
    t(19, "EH", "Harness", ["This is not a duplicate of DND-12."]),
    t(20, "EH", "Harness", ["Sweep: " + (1..9).map { |i| "DND-#{i}" }.join(" ")]),
    t(21, "EH", "Harness", ["See DND-999."]),
    { "page_id" => "p30", "ref" => "DND-30", "title" => "HIGH: a finding", "status" => "Todo", "area" => "Harness",
      "severity" => nil, "epic_ids" => ["EH"], "depends_on" => [], "blocks" => [], "found_while" => [],
      "relations_truncated" => false, "blocks_text" => ["x"], "body_read" => true }
  ]
  snap = { "fetched_at" => "2026-09-28T00:00:00Z", "tickets_rows" => tickets.size,
           "epic_projects" => { "EH" => "harness", "EW" => "walt_ui" }, "unread" => [{ "ref" => "DND-17", "why" => "answered HTTP 429" }],
           "tickets" => tickets }
  File.write(ARGV[0], JSON.generate(snap))
' "${TMP}/evals/finding-triage-snapshot.json"

build() { ruby -rjson -r "${LIBRB}" -e "r = TriageCorpus.build(JSON.parse(File.read('${TMP}/evals/finding-triage-snapshot.json')), unrelated: 3, seed: 's'); $1"; }

eq "build: duplicate from the body text [ticket]" \
  "$(build 'puts r[:labels].select { |l| l["label"] == "duplicate" }.map { |l| [l["id"], l["provenance"], l["rule"]].join(" ") }')" \
  "DND-11:DND-10 tracker_record duplicate_text"
eq "build: related from Depends On and citations, later ticket as finding [ticket]" \
  "DND-12:DND-10 depends_on|DND-13:DND-11 citation|DND-19:DND-12 citation" \
  "$(build 'puts r[:labels].select { |l| l["label"] == "related" }.map { |l| [l["id"], l["rule"]].join(" ") }.join("|")')"
eq "build: unrelated rule_confirmed pairs are exactly the different-Area ones [ticket]" \
  "true 3" \
  "$(build 'u = r[:labels].select { |l| l["provenance"] == "rule_confirmed" }; puts [u.all? { |l| l["id"].include?("DND-14") && l["label"] == "unrelated" && l["rule"] == "different_area_unlinked" }, u.size].join(" ")')"
eq "build: proposed unrelated pairs are same-Area, unlinked, and carry no rule [ticket]" \
  "true 3" \
  "$(build 'p = r[:labels].select { |l| l["provenance"] == "proposed" }; puts [p.none? { |l| l["id"].include?("DND-14") || l["rule"] }, p.size].join(" ")')"
eq "build: a linked pair is never sampled as unrelated (found_while, duplicate, citation)" \
  "" \
  "$(build 'bad = %w[DND-18:DND-10 DND-11:DND-10 DND-13:DND-11 DND-12:DND-10 DND-19:DND-12]; puts r[:labels].select { |l| l["label"] == "unrelated" && bad.include?(l["id"]) }.map { |l| l["id"] }.join(",")')"
eq "build: exclusions are counted by reason, never dropped silently" \
  "body_unread 1, citation_list_skipped 1, cross_project 1, no_project 1, unknown_ref 1" \
  "$(build 'puts r[:excluded].map { |k, v| "#{k} #{v}" }.join(", ")')"
eq "build: the content domain comes from the project (harness -> blend) [ticket]" \
  "blend" \
  "$(build 'puts r[:corpus].map { |c| c["content_domain"] }.uniq.join(",")')"
eq "build: the sent finding text carries no duplicate line and no ref (label leak) [ticket]" \
  "Widget save path breaks." \
  "$(build 'puts r[:corpus].find { |c| c["id"] == "DND-11:DND-10" }["input"]["finding"]["body"]')"
eq "build: one case is one (finding, candidate) pair: exactly one candidate" \
  "1" \
  "$(build 'puts r[:corpus].map { |c| c["input"]["candidates"].size }.uniq.join(",")')"
eq "build: severity labels are weak, from the title prefix" \
  "DND-30 HIGH title_prefix true" \
  "$(build 'puts r[:severity].map { |s| [s["id"], s["label"], s["source"], s["weak"]].join(" ") }.join("|")')"
eq "build: counts by relation/provenance" \
  "duplicate/tracker_record 1, related/tracker_record 3, unrelated/proposed 3, unrelated/rule_confirmed 3" \
  "$(build 'puts r[:counts]["by_label_provenance"].map { |k, v| "#{k} #{v}" }.join(", ")')"
eq "build: a snapshot with no tickets is an error, not an empty corpus" \
  "InputError: the snapshot holds no tickets" \
  "$(ruby -r "${LIBRB}" -e 'begin; TriageCorpus.build({"tickets"=>[],"epic_projects"=>{},"fetched_at"=>"x"}, unrelated: 1, seed: "s"); rescue TriageCorpus::InputError => e; puts "InputError: #{e.message}"; end')"

echo "== build (bin) + judgment-eval --dry-run"

OUT="$("${BIN}" --build --unrelated 3 --seed s --dir "${TMP}/evals" 2>&1)"
RC=$?
eq "--build exits 0" "${RC}" "0"
has "--build prints counts by relation/provenance" "${OUT}" "labels by relation/provenance: duplicate/tracker_record 1, related/tracker_record 3"
has "--build prints eval-usable cases and proposed excluded" "${OUT}" "eval-usable cases: 7 (proposed excluded: 3)"
MODE="$(stat -c '%a' "${TMP}/evals/finding-triage-corpus.jsonl" 2>/dev/null)"
eq "--build writes the corpus 0600 (machine-local ticket text)" "${MODE}" "600"
LTEXT="$(cat "${TMP}/evals/finding-triage-labels.jsonl")"
lacks "the labels file holds ids and labels, never ticket text" "${LTEXT}" "widget"
cp "${TMP}/evals/finding-triage-labels.jsonl" "${TMP}/labels.first"
"${BIN}" --build --unrelated 3 --seed s --dir "${TMP}/evals" >/dev/null 2>&1
if cmp -s "${TMP}/labels.first" "${TMP}/evals/finding-triage-labels.jsonl"; then ok "--build is deterministic (byte-identical labels)"; else bad "--build is deterministic (byte-identical labels)"; fi
DRY="$("${EVAL}" --dry-run --use-case finding_triage --labels "${TMP}/evals/finding-triage-labels.jsonl" --corpus "${TMP}/evals/finding-triage-corpus.jsonl" 2>&1)"
RC=$?
eq "judgment-eval --dry-run joins the corpus (exit 0)" "${RC}" "0"
has "judgment-eval excludes the proposed labels [ticket]" "${DRY}" "proposed excluded: 3"
has "judgment-eval runs every usable label, each with its domain" "${DRY}" "cases: 7 (duplicate 1, related 3, unrelated 3)"
OUT="$("${BIN}" --build --dir "${TMP}/nowhere" 2>&1)"
RC=$?
eq "--build with no snapshot exits 1" "${RC}" "1"
has "--build with no snapshot says so, with Fix:" "${OUT}" "does not exist. Fix: run triage-corpus --fetch first"
OUT="$("${BIN}" --fetch --unrelated 3 2>&1)"
RC=$?
eq "--fetch refuses build flags (usage, exit 2)" "${RC}" "2"

echo "== fetch (fake Notion)"

TOKEN="triage-corpus-test-token-$$-${RANDOM}"
printf '%s\n' "${TOKEN}" > "${TMP}/token"
chmod 600 "${TMP}/token"
: > "${TMP}/notion.log"
python3 "${FAKE}" "${TMP}/port" "${TMP}/notion.log" "${TMP}/token" &
SERVER_PID=$!
for _i in $(seq 1 100); do
  [ -s "${TMP}/port" ] && break
  sleep 0.05
done
[ -s "${TMP}/port" ] || { echo "FAIL fake Notion did not start"; exit 1; }
PORT="$(cat "${TMP}/port")"
jq -n --arg f "${TMP}/token" '{mcpServers: {"notion-personal": {type: "stdio", command: "x", env: {NOTION_ATHENA_TOKEN_FILE: $f}}}}' > "${TMP}/claude.json"
OUT="$(cd "${TMP}" && FLEET_CLAUDE_JSON="${TMP}/claude.json" TRIAGE_CORPUS_NOTION_API="http://127.0.0.1:${PORT}" TRIAGE_CORPUS_PACE_S=0 \
  "${BIN}" --fetch --dir "${TMP}/fetched" 2>&1)"
RC=$?
eq "--fetch exits 0" "${RC}" "0"
has "--fetch follows the cursor and skips a non-DND row" "${OUT}" "4 tickets (5 rows)"
has "--fetch names an UNREAD body, never passes it [ticket]" "${OUT}" "1 bodies UNREAD (DND-429 answered HTTP 429)"
SNAP="${TMP}/fetched/finding-triage-snapshot.json"
eq "the snapshot records the unread body as body_read false" \
  "$(jq -r '.tickets[] | select(.ref=="DND-429") | .body_read' "${SNAP}" 2>/dev/null)" "false"
eq "the snapshot maps the epic to its project" "$(jq -r '.epic_projects["e0000000-0000-0000-0000-000000000001"]' "${SNAP}" 2>/dev/null)" "harness"
eq "the snapshot is 0600" "$(stat -c '%a' "${SNAP}" 2>/dev/null)" "600"
LOG="$(cat "${TMP}/notion.log")"
lacks "every Notion request carried the token" "${LOG}" "AUTH_BAD"
eq "only reads were made (POST query, GET children)" \
  "$(grep -v -E '^(POST /v1/data_sources/[0-9a-f-]{36}/query|GET /v1/blocks/[0-9a-f-]{36}/children\?page_size=100) AUTH_OK$' "${TMP}/notion.log" | wc -l | tr -d ' ')" "0"
eq "a 429 body read was tried 3 times" "$(grep -c '0429/children' "${TMP}/notion.log")" "3"
OUT="$("${BIN}" --build --unrelated 1 --dir "${TMP}/fetched" 2>&1)"
has "a fetched snapshot builds: the duplicate from the fake bodies" "${OUT}" "duplicate/tracker_record 1"

echo
echo "triage-corpus self-test: ${PASS} passed, ${FAIL} failed"
if [ "${FAIL}" -ne 0 ]; then
  echo "triage-corpus self-test: FAIL"
  echo "  Fix: make ai/bin/triage-corpus and ai/lib/triage_corpus.rb satisfy the failing cases above (contract: ai/contracts/athena-judgments.md -> Threshold provenance, n/a and the pinned model)."
  exit 1
fi
echo "triage-corpus self-test: OK"
