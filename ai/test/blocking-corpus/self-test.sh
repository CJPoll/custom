#!/usr/bin/env bash
# self-test.sh -- ticket-corpus's ticket_blocking pairs and shadow report
# (DND-1057). Discovered by harness-gate (every committed `self-test.sh` runs).
#
# Layers, in TDD order:
#   1. domain  -- ai/lib/blocking_corpus.rb, pure functions, from ruby -e
#                 (labels/2 and shadow_report/2);
#   2. bin     -- ai/bin/ticket-corpus --build / --shadow-report over a FIXTURE
#                 snapshot, then ai/bin/judgment-eval --dry-run --use-case
#                 ticket_blocking over the files it wrote.
# ticket-corpus makes no network call; the snapshot is a fixture.
#
# Cases marked [qa N] are DND-1057's QA Plan rows for ticket-corpus.

set -u

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
AI="$(cd -- "${HERE}/../.." && pwd -P)"
BIN="${AI}/bin/ticket-corpus"
EVAL="${AI}/bin/judgment-eval"
LIBRB="${AI}/lib/blocking_corpus.rb"

PASS=0
FAIL=0
ok()   { PASS=$((PASS + 1)); printf 'ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL + 1)); printf 'FAIL %s\n' "$1"; [ -n "${2:-}" ] && printf '     %s\n' "$2"; return 0; }
eq()   { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$3], got [$2]"; fi; }
has()  { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "no [$3] in: $2" ;; esac; }
lacks() { case "$2" in *"$3"*) bad "$1" "unexpected [$3] in: $2" ;; *) ok "$1" ;; esac; }

[ -x /usr/bin/ruby ] || { echo "blocking-corpus self-test: FAIL -- /usr/bin/ruby is missing"; echo "  Fix: install the harness Ruby at /usr/bin/ruby (DND-931/958); this suite does not skip."; exit 1; }
for dep in jq; do
  command -v "${dep}" >/dev/null 2>&1 || { echo "blocking-corpus self-test: FAIL -- ${dep} is not on PATH"; echo "  Fix: install ${dep}; this suite does not skip."; exit 1; }
done
for f in "${BIN}" "${EVAL}"; do
  [ -x "${f}" ] || { echo "blocking-corpus self-test: FAIL -- ${f} missing or not executable"; echo "  Fix: chmod +x ${f#"${AI}/../"}"; exit 1; }
done

TMP="$(mktemp -d)" || { echo "FAIL mktemp"; exit 1; }
trap 'rm -rf "${TMP}"' EXIT INT TERM

# t.(n, created, extra) -> a snapshot ticket in the harness epic EH. C.(n) is
# an open Critical planned Feature; F.(n, path, extra) a post-cutoff finding.
PRE='POST = "2026-09-28T01:00:00.000Z"; PRE_CUT = "2026-09-26T12:00:00.000Z";
t = ->(n, created = POST, extra = {}) { {"page_id"=>"p#{n}","ref"=>"DND-#{n}","title"=>"Ticket #{n} widget","area"=>"Harness","epic_ids"=>["EH"],"created_time"=>created,"kind"=>"Bug","severity"=>"MEDIUM","security"=>"none","schema_missing"=>[],"status"=>"Not Started","path"=>"Off","path_select"=>true,"blocks"=>[],"found_while"=>[],"blocks_text"=>["Body #{n}."],"body_read"=>true,"body_truncated"=>false}.merge(extra) };
C = ->(n, extra = {}) { t.(n, PRE_CUT, {"kind"=>"Feature","severity"=>nil,"path"=>"Critical","blocks_text"=>["Requirement #{n}: the widget saves."]}.merge(extra)) };
F = ->(n, path, extra = {}) { t.(n, POST, {"path"=>path}.merge(extra)) };
snap = ->(ts, at = "2026-10-02T00:00:00Z") { {"fetched_at"=>at,"epic_projects"=>{"EH"=>"harness","EW"=>"walt_ui"},"tickets"=>ts} };
rows = ->(r) { r[:labels].map { |l| [l["id"], l["label"], l["provenance"]].join(" ") }.join("|") };
ex = ->(r) { r[:exclusions].map { |k, v| "#{k} #{v}" }.join(", ") }'
rb() { /usr/bin/ruby -rjson -r "${LIBRB}" -e "${PRE}; $1" 2>&1; }

echo "== domain: labels/2"

eq "1 a Blocking finding with a Blocks edge onto a Critical ticket is a blocks pair [qa 1]" \
  "$(rb 'puts rows.(BlockingCorpus.labels(snap.([C.(10), F.(50, "Blocking", "blocks"=>["p10"])])))')" \
  "DND-50:DND-10 blocks tracker_record"
eq "1b a Blocks edge onto a non-Critical ticket is no pair" \
  "$(rb 'puts ex.(BlockingCorpus.labels(snap.([t.(10), F.(50, "Blocking", "blocks"=>["p10"])])))')" \
  "blocking_without_critical_edge 1, no_found_while 1"
eq "2 an Off finding pairs with its Found while epic's open Critical tickets, at most 3, by ID [qa 2]" \
  "$(rb 'ts = [C.(14), C.(12), C.(10), C.(13), C.(11), C.(9, "status"=>"Done"), t.(40), F.(50, "Off", "found_while"=>["p40"])]; puts BlockingCorpus.labels(snap.(ts))[:labels].map { |l| [l["id"], l["label"]].join(" ") }.join("|")')" \
  "DND-50:DND-10 does_not_block|DND-50:DND-11 does_not_block|DND-50:DND-12 does_not_block"
eq "2b an Off finding with no Found while is excluded by reason" \
  "$(rb 'puts ex.(BlockingCorpus.labels(snap.([C.(10), F.(50, "Off")])))')" \
  "feature 1, no_found_while 1"
eq "2c an Off finding whose epic has no open Critical ticket is excluded" \
  "$(rb 'puts ex.(BlockingCorpus.labels(snap.([C.(10, "status"=>"Done"), t.(40), F.(50, "Off", "found_while"=>["p40"])])))')" \
  "feature 1, no_found_while 1, no_open_critical 1"
eq "3 a pre-cutoff finding is excluded as before_cutoff [qa 3]" \
  "$(rb 'puts ex.(BlockingCorpus.labels(snap.([C.(10), t.(50, PRE_CUT, "path"=>"Blocking", "blocks"=>["p10"])])))')" \
  "before_cutoff 1, feature 1"
eq "4 a finding whose Path Jev decided (source jev) is excluded as jev_decided (no circular label)" \
  "$(rb 'line = "Jev path: " + JSON.generate({"path"=>{"value"=>"Blocking","blocks"=>"DND-10","source"=>"jev"}}); puts ex.(BlockingCorpus.labels(snap.([C.(10), F.(50, "Blocking", "blocks"=>["p10"], "blocks_text"=>["x", line])])))')" \
  "feature 1, jev_decided 1"
eq "5 authored and unset Paths are excluded, never labelled" \
  "$(rb 'puts ex.(BlockingCorpus.labels(snap.([C.(10), F.(50, "Promoted"), F.(51, nil)])))')" \
  "authored_path 1, feature 1, path_unset 1"
eq "5b a planned Feature is never a finding" \
  "$(rb 'puts ex.(BlockingCorpus.labels(snap.([C.(10)])))')" \
  "feature 1"
eq "6 the case input: the finding redacted of its Path and edge, the candidate as a live one" \
  "$(rb 'f = F.(50, "Blocking", "blocks"=>["p10"], "blocks_text"=>["Widget fails.", "Path Blocking; it blocks DND-10.", "Jev path: {\"path\":{\"source\":\"filer\"}}"]); puts JSON.generate(BlockingCorpus.labels(snap.([C.(10), f]))[:corpus].first["input"])')" \
  '{"finding":{"title":"Ticket 50 widget","body":"Widget fails.\n[classification]; it [edge].","project":"harness"},"candidates":[{"ref":"DND-10","title":"Ticket 10 widget","summary":"Requirement 10: the widget saves."}]}'
eq "6b every label is weak tracker_record; the corpus carries the domain" \
  "$(rb 'r = BlockingCorpus.labels(snap.([C.(10), F.(50, "Blocking", "blocks"=>["p10"])])); puts [r[:labels].all? { |l| l["weak"] && l["provenance"] == "tracker_record" }, r[:corpus].first["content_domain"]].join(" ")')" \
  "true blend"
eq "6c the summary is the first 800 characters, as ticket-classify --epic sends it" \
  "$(rb 'r = BlockingCorpus.labels(snap.([C.(10, "blocks_text"=>["x" * 900]), F.(50, "Blocking", "blocks"=>["p10"])])); puts r[:corpus].first["input"]["candidates"].first["summary"].length')" \
  "800"
eq "7 a snapshot from before DND-1057 (no path) is an error, not an empty corpus" \
  "$(rb 'begin; BlockingCorpus.labels(snap.([t.(1).reject { |k, _| k == "path_select" }])); puts "no error"; rescue TicketCorpus::InputError => e; puts "InputError #{e.message[/path/]}"; end')" \
  "InputError path"
eq "7b rows with no Path select (a renamed property) are an error" \
  "$(rb 'begin; BlockingCorpus.labels(snap.([t.(1, POST, "path_select"=>false)])); puts "no error"; rescue TicketCorpus::InputError; puts "InputError"; end')" \
  "InputError"

echo "== domain: shadow_report/2"

WOULD='w = ->(value, blocks, source, mode = "shadow") { "Jev path: " + JSON.generate({"path"=>{"value"=>"Off","blocks"=>nil,"source"=>"filer","reason"=>"shadow","mode"=>mode,"confidence"=>nil},"would"=>(source ? {"value"=>value,"blocks"=>blocks,"source"=>source} : nil),"candidates"=>2,"model"=>"jev-1.13.0","version"=>"ticket-blocking-v1"}) }'
eq "8 a shadow would-block that the ticket carries agrees; one it does not, disagrees" \
  "$(rb "${WOULD}; ts = [C.(10), F.(50, \"Blocking\", \"blocks\"=>[\"p10\"], \"blocks_text\"=>[w.(\"Blocking\", \"DND-10\", \"jev\")]), F.(51, \"Off\", \"blocks_text\"=>[w.(\"Blocking\", \"DND-10\", \"jev\")])]; r = BlockingCorpus.shadow_report(snap.(ts), \"2026-09-28T00:00:00Z\"); puts [r[:accepted], r[:agreed], r[:by_label].map { |k, v| \"#{k} #{v[:accepted]}/#{v[:agreed]}\" }.join].join(\" \")")" \
  "2 1 blocks 2/1"
eq "8b a would-decision that is the filer's (no accepted judgment) and a mode-off line are excluded, not scored" \
  "$(rb "${WOULD}; ts = [F.(50, \"Off\", \"blocks_text\"=>[w.(\"Off\", nil, \"filer\")]), F.(51, \"Off\", \"blocks_text\"=>[w.(\"Off\", nil, nil, \"off\")])]; r = BlockingCorpus.shadow_report(snap.(ts), \"2026-09-28T00:00:00Z\"); puts [r[:accepted], r[:excluded].map { |k, v| \"#{k} #{v}\" }.join(\", \")].join(\" \")")" \
  "0 mode_off 1, no_accepted_judgment 1"
eq "8c nothing accepted prints n/a, never 0" \
  "$(rb "r = BlockingCorpus.shadow_report(snap.([F.(50, \"Off\")]), \"2026-09-28T00:00:00Z\"); puts BlockingCorpus.shadow_lines(r).grep(/n\\/a/).first.to_s[/\\A[^-]*\\)/]")" \
  "ticket_blocking: n/a (0 accepted)"

echo "== bin"

mkdir -p "${TMP}/evals"
/usr/bin/ruby -rjson -r "${LIBRB}" -e "${PRE};
  ts = [C.(10), C.(11), t.(40), F.(50, \"Blocking\", \"blocks\"=>[\"p10\"]), F.(51, \"Off\", \"found_while\"=>[\"p40\"]), F.(52, \"Off\")]
  File.write(ARGV[0], JSON.generate(snap.(ts)))" "${TMP}/evals/finding-triage-snapshot.json"

OUT="$("${BIN}" --build --dir "${TMP}/evals" 2>&1)"; RC=$?
eq "--build exits 0" "${RC}" "0"
has "--build prints the blocking counts" "${OUT}" "ticket_blocking: 3 labels (blocks/tracker_record 1, does_not_block/tracker_record 2)"
has "--build prints the blocking exclusions" "${OUT}" "excluded: feature 2, no_found_while 2"
eq "--build writes the ticket_blocking files, 0600" \
  "$(find "${TMP}/evals" -maxdepth 1 -name 'ticket-blocking-*.jsonl' -printf '%f %m\n' | sort | tr '\n' ' ')" \
  "ticket-blocking-corpus.jsonl 600 ticket-blocking-labels.jsonl 600 "
lacks "the labels file holds ids and labels, never ticket text" "$(cat "${TMP}/evals/ticket-blocking-labels.jsonl")" "widget"

DRY="$("${EVAL}" --dry-run --use-case ticket_blocking --labels "${TMP}/evals/ticket-blocking-labels.jsonl" --corpus "${TMP}/evals/ticket-blocking-corpus.jsonl" 2>&1)"; RC=$?
eq "judgment-eval --dry-run --use-case ticket_blocking joins the corpus (exit 0)" "${RC}" "0"
has "judgment-eval ticket_blocking: three cases, domains from the rows" "${DRY}" "cases: 3"

OUT="$("${BIN}" --shadow-report --since 2026-09-28T00:00:00Z --dir "${TMP}/evals" 2>&1)"; RC=$?
eq "--shadow-report exits 0" "${RC}" "0"
has "--shadow-report prints the blocking section" "${OUT}" "ticket_blocking: since 2026-09-28T00:00:00Z"
has "--shadow-report prints n/a for blocking with nothing accepted" "${OUT}" "ticket_blocking: n/a (0 accepted)"
has "--shadow-report prints the blocking bar" "${OUT}" "bar ticket_blocking: not met"

echo
echo "blocking-corpus self-test: ${PASS} passed, ${FAIL} failed"
if [ "${FAIL}" -ne 0 ]; then
  echo "blocking-corpus self-test: FAIL"
  echo "  Fix: make ai/lib/blocking_corpus.rb and ai/bin/ticket-corpus satisfy the failing cases above (design: DND-1057 A&E section 2)."
  exit 1
fi
echo "blocking-corpus self-test: OK"
