#!/usr/bin/env bash
# self-test.sh -- the ticket-corpus suite (DND-1055). Discovered by
# harness-gate (every committed `self-test.sh` runs).
#
# Layers, in TDD order:
#   1. domain  -- ai/lib/ticket_corpus.rb, pure functions, called from ruby -e
#                 (labels/2 and shadow_report/2, the QA plan's matrices);
#   2. bin     -- ai/bin/ticket-corpus --build / --shadow-report over a FIXTURE
#                 snapshot, then ai/bin/judgment-eval --dry-run over the files
#                 it wrote.
# The Notion reads are triage-corpus --fetch's, tested (read-only allowlist,
# UNREAD bodies) in ai/test/triage-corpus/self-test.sh; ticket-corpus makes no
# network call at all.
#
# The fail-first cases are marked [ticket].

set -u

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
AI="$(cd -- "${HERE}/../.." && pwd -P)"
BIN="${AI}/bin/ticket-corpus"
EVAL="${AI}/bin/judgment-eval"
LIBRB="${AI}/lib/ticket_corpus.rb"

PASS=0
FAIL=0
ok()   { PASS=$((PASS + 1)); printf 'ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL + 1)); printf 'FAIL %s\n' "$1"; [ -n "${2:-}" ] && printf '     %s\n' "$2"; return 0; }
eq()   { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$3], got [$2]"; fi; }
has()  { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "no [$3] in: $2" ;; esac; }
lacks() { case "$2" in *"$3"*) bad "$1" "unexpected [$3] in: $2" ;; *) ok "$1" ;; esac; }

[ -x /usr/bin/ruby ] || { echo "ticket-corpus self-test: FAIL -- /usr/bin/ruby is missing"; echo "  Fix: install the harness Ruby at /usr/bin/ruby (DND-931/958); this suite does not skip."; exit 1; }
for dep in jq; do
  command -v "${dep}" >/dev/null 2>&1 || { echo "ticket-corpus self-test: FAIL -- ${dep} is not on PATH"; echo "  Fix: install ${dep}; this suite does not skip."; exit 1; }
done
for f in "${BIN}" "${EVAL}"; do
  [ -x "${f}" ] || { echo "ticket-corpus self-test: FAIL -- ${f} missing or not executable"; echo "  Fix: chmod +x ${f#"${AI}/../"}"; exit 1; }
done
[ -f "${LIBRB}" ] || { echo "ticket-corpus self-test: FAIL -- ${LIBRB} missing"; echo "  Fix: add the domain lib ai/lib/ticket_corpus.rb"; exit 1; }

TMP="$(mktemp -d)" || { echo "FAIL mktemp"; exit 1; }
trap 'rm -rf "${TMP}"' EXIT INT TERM

# PRE builds tickets: t.(n, created, props = {}) -> a snapshot ticket in the
# harness epic EH, post-cutoff unless `created` says otherwise.
PRE='POST = "2026-09-28T01:00:00.000Z"; PRE_CUT = "2026-09-26T12:00:00.000Z";
t = ->(n, created = POST, extra = {}) { {"page_id"=>"p#{n}","ref"=>"DND-#{n}","title"=>"Ticket #{n} widget","area"=>"Harness","epic_ids"=>["EH"],"created_time"=>created,"kind"=>"Bug","severity"=>"MEDIUM","security"=>"none","schema_missing"=>[],"status"=>"Not Started","path"=>"Off","path_select"=>true,"blocks"=>[],"found_while"=>[],"blocks_text"=>["Body #{n}."],"body_read"=>true,"body_truncated"=>false}.merge(extra) };
snap = ->(ts, at = "2026-10-02T00:00:00Z") { {"fetched_at"=>at,"epic_projects"=>{"EH"=>"harness","EW"=>"walt_ui"},"tickets"=>ts} };
rows = ->(r, uc) { r[:labels][uc].map { |l| [l["id"], l["label"], l["provenance"]].join(" ") }.join("|") };
ex = ->(r, uc) { r[:exclusions][uc].map { |k, v| "#{k} #{v}" }.join(", ") };
exsum = ->(r, reason) { r[:exclusions].values.sum { |h| h[reason] || 0 } }'
rb() { /usr/bin/ruby -rjson -r "${LIBRB}" -e "${PRE}; $1" 2>&1; }

echo "== domain: labels/2"

eq "1 a post-cutoff Bug yields a Kind label, tracker_record [ticket]" \
  "$(rb 'puts rows.(TicketCorpus.labels(snap.([t.(1)])), "ticket_kind")')" \
  "DND-1 Bug tracker_record"
eq "1b every label row is weak, labeller tracker, never owner_confirmed [ticket]" \
  "true tracker" \
  "$(rb 'l = TicketCorpus.labels(snap.([t.(1)]))[:labels].values.flatten; puts [l.all? { |x| x["weak"] == true && x["provenance"] != "owner_confirmed" }, l.map { |x| x["labeler"] }.uniq.join].join(" ")')"
eq "2 a pre-cutoff ticket is excluded as before_cutoff (the W4 backfill) [ticket]" \
  "| before_cutoff 1" \
  "$(rb 'r = TicketCorpus.labels(snap.([t.(2, PRE_CUT)])); puts [rows.(r, "ticket_kind"), ex.(r, "ticket_kind")].join("| ")')"
eq "2b the cutoff is inclusive at 2026-09-27T22:00Z" \
  "DND-2 Bug tracker_record" \
  "$(rb 'puts rows.(TicketCorpus.labels(snap.([t.(2, "2026-09-27T22:00:00.000Z")])), "ticket_kind")')"
eq "3 a Feature is excluded from Kind and Severity only; its Security is labelled [ticket]" \
  "kind [] severity [] security [DND-3 none tracker_record] feature 2" \
  "$(rb 'r = TicketCorpus.labels(snap.([t.(3, POST, "kind"=>"Feature","severity"=>nil)])); puts "kind [#{rows.(r, "ticket_kind")}] severity [#{rows.(r, "ticket_severity")}] security [#{rows.(r, "ticket_security")}] feature #{exsum.(r, "feature")}"')"
eq "4 security maps introduced/pre-existing to security and none to none [ticket]" \
  "DND-4 security tracker_record|DND-5 security tracker_record|DND-6 none tracker_record" \
  "$(rb 'r = TicketCorpus.labels(snap.([t.(4, POST, "security"=>"pre-existing"), t.(5, POST, "security"=>"introduced"), t.(6)])); puts rows.(r, "ticket_security")')"
eq "5 a title prefix yields a Severity label at any date, provenance title_prefix [ticket]" \
  "DND-7 MEDIUM title_prefix" \
  "$(rb 'puts rows.(TicketCorpus.labels(snap.([t.(7, PRE_CUT, "title"=>"MEDIUM [harness] widget drops saves", "severity"=>"HIGH")])), "ticket_severity")')"
eq "6 a post-cutoff property wins over its own prefix, counted once [ticket]" \
  "DND-8 HIGH tracker_record" \
  "$(rb 'puts rows.(TicketCorpus.labels(snap.([t.(8, POST, "title"=>"LOW: widget", "severity"=>"HIGH")])), "ticket_severity")')"
eq "7 an unset property is excluded by reason, not labelled [ticket]" \
  "property_unset 1" \
  "$(rb 'puts ex.(TicketCorpus.labels(snap.([t.(9, POST, "severity"=>nil)])), "ticket_severity")')"
eq "7b a value outside the tracker's options is excluded as unknown_value" \
  "unknown_value 1" \
  "$(rb 'puts ex.(TicketCorpus.labels(snap.([t.(9, POST, "kind"=>"Chore")])), "ticket_kind")')"
eq "8 an unreadable body is excluded, never an empty input [ticket]" \
  "body_unread 1 rows 0 corpus 0" \
  "$(rb 'r = TicketCorpus.labels(snap.([t.(10, POST, "body_read"=>false, "blocks_text"=>[])])); puts "#{ex.(r, "ticket_kind")} rows #{r[:labels]["ticket_kind"].size} corpus #{r[:corpus]["ticket_kind"].size}"')"
eq "9 an unknown project is excluded, never guessed [ticket]" \
  "unknown_project 1" \
  "$(rb 'puts ex.(TicketCorpus.labels(snap.([t.(11, POST, "epic_ids"=>["EX"], "area"=>"Product")])), "ticket_kind")')"
eq "10 corpus rows carry the domain and a capped body [ticket]" \
  "blend 2000 harness" \
  "$(rb 'c = TicketCorpus.labels(snap.([t.(12, POST, "blocks_text"=>["x" * 3000])]))[:corpus]["ticket_kind"].first; puts [c["content_domain"], c["input"]["body"].size, c["input"]["project"]].join(" ")')"
eq "10b a walt_ui ticket is work" \
  "work" \
  "$(rb 'puts TicketCorpus.labels(snap.([t.(13, POST, "epic_ids"=>["EW"], "area"=>"Product")]))[:corpus]["ticket_kind"].first["content_domain"]')"
eq "11 the severity prefix is stripped from the title sent (no label leak) [ticket]" \
  "widget drops saves" \
  "$(rb 'puts TicketCorpus.labels(snap.([t.(14, POST, "title"=>"HIGH: widget drops saves")]))[:corpus]["ticket_severity"].first["input"]["title"]')"
eq "12 a body's classification statements and provenance line are redacted (no label leak) [ticket]" \
  "Widget drops saves.|Filed as [classification] · [classification]." \
  "$(rb 'b = ["Widget drops saves.", "Filed as Kind Bug · Severity MEDIUM.", "Jev classification: {\"kind\":{}}"]; puts TicketCorpus.redact_body(b.join("\n")).split("\n").join("|")')"
eq "12a a garbled provenance line excludes the ticket (Jev may have set a value) as provenance_unparseable" \
  "provenance_unparseable 1" \
  "$(rb 'puts ex.(TicketCorpus.labels(snap.([t.(15, POST, "blocks_text"=>["x", "Jev classification: {\"kind\":{}}"])])), "ticket_kind")')"
eq "12b a 'Bug MEDIUM' pair is redacted too" \
  "(Harness, [classification], Path Blocking)" \
  "$(rb 'puts TicketCorpus.redact_body("(Harness, Bug MEDIUM, Path Blocking)")')"
eq "12c prose that merely uses a Kind word stays" \
  "the bug is in the widget test" \
  "$(rb 'puts TicketCorpus.redact_body("the bug is in the widget test")')"
eq "13 a property Jev decided (source jev) is excluded as jev_decided (no circular label) [ticket]" \
  "kind [jev_decided 1] security [DND-16 none tracker_record]" \
  "$(rb 'line = "Jev classification: " + JSON.generate({"kind"=>{"value"=>"Bug","source"=>"jev","judged"=>"Bug","confidence"=>0.9,"accepted"=>true,"mode"=>"on","reason"=>nil},"severity"=>{"value"=>"MEDIUM","source"=>"filer","judged"=>"LOW","confidence"=>0.5,"accepted"=>false,"mode"=>"on","reason"=>"below_threshold"},"security"=>{"value"=>"none","source"=>"filer","judged"=>"none","confidence"=>0.9,"accepted"=>false,"mode"=>"on","reason"=>"below_threshold"},"model"=>"jev-1.13.0","versions"=>{}}); r = TicketCorpus.labels(snap.([t.(16, POST, "blocks_text"=>["x", line])])); puts "kind [#{ex.(r, "ticket_kind")}] security [#{rows.(r, "ticket_security")}]"')"
eq "14 a ticket whose title is blank once the prefix is stripped is excluded as blank_title" \
  "blank_title 1" \
  "$(rb 'puts ex.(TicketCorpus.labels(snap.([t.(17, POST, "title"=>"HIGH:")])), "ticket_kind")')"
eq "15 a snapshot from before DND-1055 (no created_time) is an error, not an empty corpus [ticket]" \
  "InputError" \
  "$(rb 'begin; TicketCorpus.labels(snap.([t.(18).reject { |k, _| k == "created_time" }])); puts "no error"; rescue TicketCorpus::InputError; puts "InputError"; end')"
eq "15b an empty snapshot is an error, not an empty corpus" \
  "InputError" \
  "$(rb 'begin; TicketCorpus.labels(snap.([])); puts "no error"; rescue TicketCorpus::InputError; puts "InputError"; end')"
eq "16 labels and corpus rows are ordered by ticket number (deterministic)" \
  "DND-2,DND-10" \
  "$(rb 'puts TicketCorpus.labels(snap.([t.(10), t.(2)]))[:labels]["ticket_kind"].map { |l| l["id"] }.join(",")')"
eq "17 a truncated body with no provenance line is provenance_unread: Jev's line may be past the page [review 2]" \
  "provenance_unread 1" \
  "$(rb 'puts ex.(TicketCorpus.labels(snap.([t.(19, POST, "body_truncated"=>true)])), "ticket_kind")')"
eq "17b a truncated body is provenance_unread even with an early line: a newer line may be past the page [critic]" \
  "provenance_unread 1" \
  "$(rb 'l = "Jev classification: " + JSON.generate(%w[kind severity security].to_h { |k| [k, {"value"=>nil,"source"=>"filer","judged"=>nil,"confidence"=>nil,"accepted"=>false,"mode"=>"off","reason"=>"mode_off"}] }); puts ex.(TicketCorpus.labels(snap.([t.(19, POST, "body_truncated"=>true, "blocks_text"=>["x", l])])), "ticket_kind")')"
eq "18 severity words in either order and with a dash are redacted [review 4]" \
  "This is a [classification] bug.|[classification]|Filed as a [classification], [classification]." \
  "$(rb 'puts ["This is a HIGH severity bug.", "Severity — HIGH", "Filed as a Bug, severity HIGH."].map { |s| TicketCorpus.redact_body(s) }.join("|")')"
eq "18b a bare upper-case level in prose is the ticket's own rating: redacted; lower-case prose stays [corpus probe]" \
  "Priority: [classification].|the coordinator filed it as [classification] today|the high road is low risk" \
  "$(rb 'puts ["Priority: LOW.", "the coordinator filed it as HIGH today", "the high road is low risk"].map { |s| TicketCorpus.redact_body(s) }.join("|")')"
eq "19 the title sent is redacted like the body [review 5]" \
  "[classification]: [classification] auth bypass" \
  "$(rb 'puts TicketCorpus.labels(snap.([t.(20, POST, "title"=>"Kind Bug: Severity HIGH auth bypass")]))[:corpus]["ticket_kind"].first["input"]["title"]')"
eq "20 a title that is only a classification is blank_title [review 5]" \
  "blank_title 1" \
  "$(rb 'puts ex.(TicketCorpus.labels(snap.([t.(21, POST, "title"=>"Severity: HIGH")])), "ticket_kind")')"
eq "21 a Kind/Severity/Security property missing from the tracker schema is an error, never property_unset [review 6]" \
  "InputError Kind" \
  "$(rb 'begin; TicketCorpus.labels(snap.([t.(22, POST, "schema_missing"=>["Kind"])])); puts "no error"; rescue TicketCorpus::InputError => e; puts "InputError #{e.message[/Kind/]}"; end')"
eq "22 a title word that merely starts with a level is not a prefix ('LOW-hanging') [review 8]" \
  "property_unset 1|LOW-hanging fruit in the widget" \
  "$(rb 'r = TicketCorpus.labels(snap.([t.(23, PRE_CUT), t.(24, POST, "severity"=>nil, "title"=>"LOW-hanging fruit in the widget")])); puts [ex.(r, "ticket_severity").sub("before_cutoff 1, ", ""), r[:corpus]["ticket_kind"].first["input"]["title"]].join("|")')"
eq "23 equal ticket numbers order by ref (stable) [review 7]" \
  "DND-a,DND-b" \
  "$(rb 'a = t.(5).merge("ref"=>"DND-a"); b = t.(5).merge("ref"=>"DND-b"); puts TicketCorpus.labels(snap.([b, a]))[:labels]["ticket_kind"].map { |l| l["id"] }.join(",")')"

echo "== domain: shadow_report/2"

# line.(kind_judged, kind_accepted, extra) -> a provenance line.
LINE='prop = ->(v, j, acc, src = "filer") { {"value"=>v,"source"=>src,"judged"=>j,"confidence"=>0.9,"accepted"=>acc,"mode"=>"shadow","reason"=>acc ? "shadow" : "below_threshold"} };
line = ->(kj, kacc, sj = "MEDIUM", sacc = false, secj = "none", secacc = false) { "Jev classification: " + JSON.generate({"kind"=>prop.("Bug", kj, kacc),"severity"=>prop.("MEDIUM", sj, sacc),"security"=>prop.("none", secj, secacc),"model"=>"jev-1.13.0","versions"=>{}}) };
SINCE = "2026-09-28T00:00:00Z"'
sh() { /usr/bin/ruby -rjson -r "${LIBRB}" -e "${PRE}; ${LINE}; $1" 2>&1; }

eq "s1 counts agreement over accepted judgments only [ticket]" \
  "accepted 2 agreed 1" \
  "$(sh 'r = TicketCorpus.shadow_report(snap.([t.(1, POST, "blocks_text"=>[line.("Bug", true)]), t.(2, POST, "blocks_text"=>[line.("Docs", true)]), t.(3, POST, "blocks_text"=>[line.("Bug", false)])]), SINCE); k = r[:use_cases]["ticket_kind"]; puts "accepted #{k[:accepted]} agreed #{k[:agreed]}"')"
eq "s2 uses the LAST provenance line [ticket]" \
  "accepted 1 agreed 0" \
  "$(sh 'r = TicketCorpus.shadow_report(snap.([t.(1, POST, "blocks_text"=>[line.("Bug", true), "later edit", line.("Docs", true)])]), SINCE); k = r[:use_cases]["ticket_kind"]; puts "accepted #{k[:accepted]} agreed #{k[:agreed]}"')"
eq "s3 an unparseable line is named, not skipped [ticket]" \
  "unparseable DND-4 accepted 0" \
  "$(sh 'r = TicketCorpus.shadow_report(snap.([t.(4, POST, "blocks_text"=>["Jev classification: {\"kind\":{\"val"])]), SINCE); puts "unparseable #{r[:unparseable].join(",")} accepted #{r[:use_cases]["ticket_kind"][:accepted]}"')"
eq "s4 no provenance line is its own count, not a case [ticket]" \
  "no_provenance 1 lines 0 accepted 0" \
  "$(sh 'r = TicketCorpus.shadow_report(snap.([t.(5)]), SINCE); puts "no_provenance #{r[:no_provenance].size} lines #{r[:lines]} accepted #{r[:use_cases]["ticket_kind"][:accepted]}"')"
eq "s5 compares judged with the CURRENT property value [ticket]" \
  "accepted 1 agreed 0" \
  "$(sh 'r = TicketCorpus.shadow_report(snap.([t.(6, POST, "kind"=>"Refactor", "blocks_text"=>[line.("Bug", true)])]), SINCE); k = r[:use_cases]["ticket_kind"]; puts "accepted #{k[:accepted]} agreed #{k[:agreed]}"')"
eq "s5b security compares the judged label with the mapped current value" \
  "accepted 2 agreed 2" \
  "$(sh 'r = TicketCorpus.shadow_report(snap.([t.(7, POST, "security"=>"pre-existing", "blocks_text"=>[line.("Bug", false, "MEDIUM", false, "security", true)]), t.(8, POST, "blocks_text"=>[line.("Bug", false, "MEDIUM", false, "none", true)])]), SINCE); k = r[:use_cases]["ticket_security"]; puts "accepted #{k[:accepted]} agreed #{k[:agreed]}"')"
eq "s6 the Wilson bound matches the server (35/35 = 0.901) [ticket]" \
  "0.901 nil" \
  "$(sh 'puts [format("%.3f", TicketCorpus.wilson_lower_bound(35, 35)), TicketCorpus.wilson_lower_bound(0, 0).inspect].join(" ")')"
eq "s6b the Wilson bound for 20/20 is below 0.90 (the reason 35 is the floor)" \
  "0.839" \
  "$(sh 'puts format("%.3f", TicketCorpus.wilson_lower_bound(20, 20))')"
eq "s7 zero accepted prints n/a, never 0 [ticket]" \
  "n/a (0 accepted) -- insufficient evidence" \
  "$(sh 'r = TicketCorpus.shadow_report(snap.([t.(5)]), SINCE); puts TicketCorpus.shadow_lines(r).find { |l| l.start_with?("ticket_kind:") }.sub("ticket_kind: ", "")')"
eq "s8 tickets filed before --since are not filings" \
  "filings 1" \
  "$(sh 'r = TicketCorpus.shadow_report(snap.([t.(1, PRE_CUT), t.(2)]), SINCE); puts "filings #{r[:filings]}"')"
eq "s9 a Feature is not a Kind or Severity case (Feature is authored, never judged)" \
  "kind 0 feature 1" \
  "$(sh 'r = TicketCorpus.shadow_report(snap.([t.(9, POST, "kind"=>"Feature", "severity"=>nil, "blocks_text"=>[line.("Bug", true)])]), SINCE); puts "kind #{r[:use_cases]["ticket_kind"][:accepted]} feature #{r[:use_cases]["ticket_kind"][:excluded]["feature"]}"')"
eq "s10 the bar names every failing clause (window, n, lb)" \
  "not met (window 1.0 days < 3; accepted 1 < 35; lb 0.207 < 0.90)" \
  "$(sh 'r = TicketCorpus.shadow_report(snap.([t.(1, POST, "blocks_text"=>[line.("Bug", true)])], "2026-09-29T00:00:00Z"), SINCE); puts TicketCorpus.bar(r, "ticket_kind")')"
eq "s11 the bar is met at 35/35 over 3 days" \
  "met (accepted 35, agreed 35, lb 0.901, window 3.0 days)" \
  "$(sh 'ts = (1..35).map { |n| t.(n, POST, "blocks_text"=>[line.("Bug", true)]) }; r = TicketCorpus.shadow_report(snap.(ts, "2026-10-01T00:00:00Z"), SINCE); puts TicketCorpus.bar(r, "ticket_kind")')"
eq "s12 per judged label, accepted and agreed are counted (the 35-per-label check)" \
  "Bug 1/1, Docs 1/0" \
  "$(sh 'r = TicketCorpus.shadow_report(snap.([t.(1, POST, "blocks_text"=>[line.("Bug", true)]), t.(2, POST, "blocks_text"=>[line.("Docs", true)])]), SINCE); puts r[:use_cases]["ticket_kind"][:by_label].map { |k, v| "#{k} #{v[:accepted]}/#{v[:agreed]}" }.join(", ")')"
eq "s13 an unread body is counted body_unread, never no_provenance" \
  "body_unread 1 no_provenance 0" \
  "$(sh 'r = TicketCorpus.shadow_report(snap.([t.(1, POST, "body_read"=>false, "blocks_text"=>[])]), SINCE); puts "body_unread #{r[:body_unread].size} no_provenance #{r[:no_provenance].size}"')"
eq "s14 a truncated body with no line is provenance_unread (the line may be past the page), never no_provenance" \
  "provenance_unread 1 no_provenance 0" \
  "$(sh 'r = TicketCorpus.shadow_report(snap.([t.(1, POST, "body_truncated"=>true)]), SINCE); puts "provenance_unread #{r[:provenance_unread].size} no_provenance #{r[:no_provenance].size}"')"

eq "s14b a truncated body with a line is provenance_unread, never tallied: the line read may not be the last [critic]" \
  "provenance_unread 1 lines 0 accepted 0" \
  "$(sh 'r = TicketCorpus.shadow_report(snap.([t.(1, POST, "body_truncated"=>true, "blocks_text"=>[line.("Bug", true)])]), SINCE); puts "provenance_unread #{r[:provenance_unread].size} lines #{r[:lines]} accepted #{r[:use_cases]["ticket_kind"][:accepted]}"')"
eq "s15 an accepted judgment in mode on is not a shadow case (Jev agreeing with itself) [review 1]" \
  "accepted 0 mode_on 1" \
  "$(sh 'l = line.("Bug", true).sub("\"mode\":\"shadow\"", "\"mode\":\"on\"").sub("\"source\":\"filer\"", "\"source\":\"jev\""); r = TicketCorpus.shadow_report(snap.([t.(1, POST, "blocks_text"=>[l])]), SINCE); k = r[:use_cases]["ticket_kind"]; puts "accepted #{k[:accepted]} mode_on #{k[:excluded]["mode_on"]}"')"
eq "s16 an accepted judgment with no judged label is unparseable, never a crash [review 3]" \
  "unparseable DND-2" \
  "$(sh 'r = TicketCorpus.shadow_report(snap.([t.(2, POST, "blocks_text"=>[line.(nil, true)])]), SINCE); puts "unparseable #{r[:unparseable].join(",")}"')"
eq "s17 an accepted judgment outside the label set is unparseable [review 3]" \
  "unparseable DND-3" \
  "$(sh 'r = TicketCorpus.shadow_report(snap.([t.(3, POST, "blocks_text"=>[line.("Feature", true)])]), SINCE); puts "unparseable #{r[:unparseable].join(",")}"')"

echo "== bin"

mkdir -p "${TMP}/evals"
/usr/bin/ruby -rjson -r "${LIBRB}" -e "${PRE}; ${LINE};
  ts = [t.(1), t.(2, POST, \"kind\"=>\"Docs\", \"severity\"=>\"LOW\"), t.(3, PRE_CUT, \"title\"=>\"HIGH: old widget\"),
        t.(4, POST, \"kind\"=>\"Feature\", \"severity\"=>nil), t.(5, POST, \"security\"=>\"introduced\", \"kind\"=>\"Vulnerability\", \"severity\"=>\"HIGH\"),
        t.(6, POST, \"body_read\"=>false, \"blocks_text\"=>[]), t.(7, POST, \"blocks_text\"=>[line.(\"Bug\", true)])]
  File.write(ARGV[0], JSON.generate(snap.(ts)))" "${TMP}/evals/finding-triage-snapshot.json"

OUT="$("${BIN}" --help 2>&1)"; RC=$?
eq "--help exits 0" "${RC}" "0"
has "--help prints the usage" "${OUT}" "Usage: ticket-corpus"

OUT="$("${BIN}" --build --dry-run --dir "${TMP}/evals" 2>&1)"; RC=$?
eq "--build --dry-run exits 0" "${RC}" "0"
has "--dry-run prints the per-label counts" "${OUT}" "ticket_kind: 4 labels (Bug/tracker_record 2, Docs/tracker_record 1, Vulnerability/tracker_record 1)"
has "--dry-run prints the exclusions by reason" "${OUT}" "excluded: before_cutoff 1, body_unread 1, feature 1"
has "--dry-run prints the severity title_prefix row" "${OUT}" "HIGH/title_prefix 1"
eq "--dry-run writes nothing" "$(find "${TMP}/evals" -maxdepth 1 -name 'ticket-*' | wc -l | tr -d ' ')" "0"

OUT="$("${BIN}" --build --dir "${TMP}/evals" 2>&1)"; RC=$?
eq "--build exits 0" "${RC}" "0"
eq "--build writes eight files (three classification use cases and ticket_blocking)" "$(find "${TMP}/evals" -maxdepth 1 -name 'ticket-*.jsonl' | wc -l | tr -d ' ')" "8"
eq "every file is 0600 (machine-local ticket text)" \
  "$(find "${TMP}/evals" -maxdepth 1 -name 'ticket-*.jsonl' -printf '%m\n' | sort -u | tr '\n' ' ')" "600 "
lacks "the labels file holds ids and labels, never ticket text" "$(cat "${TMP}/evals/ticket-kind-labels.jsonl")" "widget"
cp "${TMP}/evals/ticket-kind-labels.jsonl" "${TMP}/labels.first"
"${BIN}" --build --dir "${TMP}/evals" >/dev/null 2>&1
if cmp -s "${TMP}/labels.first" "${TMP}/evals/ticket-kind-labels.jsonl"; then ok "--build is deterministic (byte-identical labels)"; else bad "--build is deterministic (byte-identical labels)"; fi

for uc in kind severity security; do
  DRY="$("${EVAL}" --dry-run --use-case "ticket_${uc}" --labels "${TMP}/evals/ticket-${uc}-labels.jsonl" --corpus "${TMP}/evals/ticket-${uc}-corpus.jsonl" 2>&1)"; RC=$?
  eq "judgment-eval --dry-run --use-case ticket_${uc} joins the corpus (exit 0) [ticket]" "${RC}" "0"
  has "judgment-eval ticket_${uc}: every row carries its domain, no --content-domain" "${DRY}" "cases: "
done
DRY="$("${EVAL}" --dry-run --use-case ticket_severity --labels "${TMP}/evals/ticket-severity-labels.jsonl" --corpus "${TMP}/evals/ticket-severity-corpus.jsonl" 2>&1)"
has "judgment-eval accepts title_prefix labels and counts them [ticket]" "${DRY}" "title_prefix 1"

OUT="$("${BIN}" --shadow-report --since 2026-09-28T00:00:00Z --dir "${TMP}/evals" 2>&1)"; RC=$?
eq "--shadow-report exits 0" "${RC}" "0"
has "--shadow-report prints filings and lines" "${OUT}" "filings 6, provenance lines 1"
has "--shadow-report names the unread body" "${OUT}" "body_unread 1 (DND-6)"
has "--shadow-report prints the kind agreement" "${OUT}" "ticket_kind: accepted 1, agreed 1, lb 0.207"
has "--shadow-report prints n/a for a use case with nothing accepted" "${OUT}" "ticket_security: n/a (0 accepted) -- insufficient evidence"
has "--shadow-report prints the bar per use case" "${OUT}" "bar ticket_kind: not met"
OUT="$("${BIN}" --shadow-report --dir "${TMP}/evals" 2>&1)"; RC=$?
eq "--shadow-report without --since is usage (exit 2)" "${RC}" "2"
has "--shadow-report without --since says Fix:" "${OUT}" "Fix:"
OUT="$("${BIN}" --shadow-report --since yesterday --dir "${TMP}/evals" 2>&1)"; RC=$?
eq "--since that is not a UTC timestamp is usage (exit 2)" "${RC}" "2"

OUT="$("${BIN}" --build --dir "${TMP}/nowhere" 2>&1)"; RC=$?
eq "--build with no snapshot exits 1" "${RC}" "1"
has "--build with no snapshot says so, with Fix:" "${OUT}" "Fix: run triage-corpus --fetch"
printf '%s\n' '{"fetched_at":"x","epic_projects":{},"tickets":[{"ref":"DND-1","page_id":"p","title":"t","epic_ids":[],"area":"Harness","blocks_text":[],"body_read":true}]}' > "${TMP}/old.json"
mkdir -p "${TMP}/old" && cp "${TMP}/old.json" "${TMP}/old/finding-triage-snapshot.json"
OUT="$("${BIN}" --build --dir "${TMP}/old" 2>&1)"; RC=$?
eq "--build over a pre-DND-1055 snapshot exits 1 [ticket]" "${RC}" "1"
has "--build over a pre-DND-1055 snapshot names the missing field, with Fix:" "${OUT}" "created_time"
lacks "--build prints no backtrace" "${OUT}" "ticket_corpus.rb:"
mkdir -p "${TMP}/allold"
/usr/bin/ruby -rjson -r "${LIBRB}" -e "${PRE}; File.write(ARGV[0], JSON.generate(snap.([t.(1, PRE_CUT), t.(2, PRE_CUT)])))" "${TMP}/allold/finding-triage-snapshot.json"
OUT="$("${BIN}" --build --dry-run --dir "${TMP}/allold" 2>&1)"
has "--build says so when every ticket is excluded (0 labels is never silent) [review 9]" "${OUT}" "0 labels: every ticket was excluded"
OUT="$("${BIN}" --bogus 2>&1)"; RC=$?
eq "an unknown flag is usage (exit 2)" "${RC}" "2"

echo
echo "ticket-corpus self-test: ${PASS} passed, ${FAIL} failed"
if [ "${FAIL}" -ne 0 ]; then
  echo "ticket-corpus self-test: FAIL"
  echo "  Fix: make ai/bin/ticket-corpus and ai/lib/ticket_corpus.rb satisfy the failing cases above (design: DND-1055 A&E; contract ai/contracts/athena-judgments.md -> Ticket classification labels)."
  exit 1
fi
echo "ticket-corpus self-test: OK"
