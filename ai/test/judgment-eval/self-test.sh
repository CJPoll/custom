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

[ -x /usr/bin/ruby ] || { echo "judgment-eval self-test: FAIL -- /usr/bin/ruby is missing"; echo "  Fix: install the harness Ruby at /usr/bin/ruby (DND-931/958); this suite does not skip."; exit 1; }
for dep in python3 curl jq git; do
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
  got="$(/usr/bin/ruby -r "${LIBRB}" -e "puts(begin; $3; rescue JudgmentEval::InputError => e; 'InputError: ' + e.message; end)" 2>&1)"
  eq "$1" "${got}" "$2"
}

echo "== domain"

ruby_eq "summary: all not_configured is scored 0 / unscored N (not_configured) [ticket]" \
  "scored 0 / unscored 3 (not_configured)" \
  'JudgmentEval.summary_lines({"scored"=>0,"unscored"=>{"not_configured"=>3},"labels"=>[]}).join("|")'
ruby_eq "summary: scored 0 prints no label line even if the report had labels" \
  "scored 0 / unscored 2 (not_configured 1, timeout 1)" \
  'JudgmentEval.summary_lines({"scored"=>0,"unscored"=>{"timeout"=>1,"not_configured"=>1},"labels"=>[{"label"=>"x","chosen"=>nil,"n_a"=>{"reason"=>"too_few_routed","n"=>0,"needs"=>10}}]}).join("|")'
ruby_eq "summary: a label under 10 cases is n/a (n=<k>, needs 10), insufficient evidence [ticket] [DND-714]" \
  "  harness: n/a (n=7, needs 10) -- insufficient evidence" \
  'JudgmentEval.label_line({"label"=>"harness","chosen"=>nil,"n_a"=>{"reason"=>"too_few_routed","n"=>7,"needs"=>10}})'
ruby_eq "summary: a label whose bound misses the target names the best bound, insufficient evidence [DND-714]" \
  "  harness: n/a (best lb 0.898 < 0.90 at every threshold) -- insufficient evidence" \
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
ruby_eq "labels: tracker_record and rule_confirmed are provenances [DND-714]" \
  "tracker_record rule_confirmed" \
  'JudgmentEval.parse_labels(%({"id":"a","label":"x","provenance":"tracker_record"}\n{"id":"b","label":"y","provenance":"rule_confirmed"}\n), "L").map { |l| l[:provenance] }.join(" ")'
ruby_eq "labels: title_prefix is a provenance and enters the run [DND-1055]" \
  "title_prefix 1 0" \
  'l = JudgmentEval.parse_labels(%({"id":"DND-1","label":"HIGH","provenance":"title_prefix"}\n), "L"); c = JudgmentEval.parse_corpus(%({"id":"DND-1"}\n), "C", "ticket_severity"); j = JudgmentEval.join(l, c); [l.first[:provenance], j[:cases].size, j[:proposed]].join(" ")'
ruby_eq "use cases: ticket_blocking is evaluable, joined on id [DND-1057]" \
  "true id" \
  '[JudgmentEval::USE_CASES.include?("ticket_blocking"), JudgmentEval::ID_KEYS["ticket_blocking"]].join(" ")'
ruby_eq "use cases: ticket_kind, ticket_severity and ticket_security are evaluable, joined on id [DND-1055]" \
  "true id id id" \
  '[%w[ticket_kind ticket_severity ticket_security].all? { |u| JudgmentEval::USE_CASES.include?(u) }, *%w[ticket_kind ticket_severity ticket_security].map { |u| JudgmentEval::ID_KEYS[u] }].join(" ")'
ruby_eq "join: only proposed is excluded; tracker_record and rule_confirmed enter the run [DND-714]" \
  "2 1" \
  'l = JudgmentEval.parse_labels(%({"id":"a","label":"x","provenance":"tracker_record"}\n{"id":"b","label":"x","provenance":"rule_confirmed"}\n{"id":"c","label":"x","provenance":"proposed"}\n), "L"); c = JudgmentEval.parse_corpus(%({"id":"a"}\n{"id":"b"}\n{"id":"c"}\n), "C", "finding_triage"); j = JudgmentEval.join(l, c); [j[:cases].size, j[:proposed]].join(" ")'
ruby_eq "slack_routing: a session-addressed root leaves the run, whatever its provenance, and is counted [DND-717]" \
  "a 1" \
  'cs = [{"case_id" => "a", "input" => {"text" => "a plain question"}}, {"case_id" => "m", "input" => {"text" => "harness session: hi"}}]; k, n = JudgmentEval.without_rule_routed(cs, "slack_routing"); [k.map { |c| c["case_id"] }.join, n].join(" ")'
ruby_eq "other use cases never apply the Slack router's rule [DND-717]" \
  "2 0" \
  'cs = [{"case_id" => "a", "input" => {"text" => "x"}}, {"case_id" => "m", "input" => {"text" => "harness session: hi"}}]; k, n = JudgmentEval.without_rule_routed(cs, "finding_triage"); [k.size, n].join(" ")'
# DND-1483: a snapshot row whose window was not complete is n/a, not a case.
# "Could not tell" (no flag, a non-boolean flag, a snapshot that is not an
# object) is not complete either. A live-inbox row (no snapshot) is unchanged.
ruby_eq "slack_routing: a snapshot case whose window was incomplete leaves the run and is named [DND-1483]" \
  "c,live|i,nokey,str,notobj" \
  'snap = ->(id, s) { {"case_id" => id, "input" => {"text" => "q", "snapshot" => s}} }; cs = [snap.("c", {"window_complete" => true}), snap.("i", {"window_complete" => false}), snap.("nokey", {}), snap.("str", {"window_complete" => "true"}), snap.("notobj", "x"), {"case_id" => "live", "input" => {"text" => "q"}}]; k, ex = JudgmentEval.without_incomplete_window(cs, "slack_routing"); [k.map { |c| c["case_id"] }.join(","), ex.join(",")].join("|")'
ruby_eq "other use cases never apply the snapshot window rule [DND-1483]" \
  "1 0" \
  'cs = [{"case_id" => "i", "input" => {"snapshot" => {"window_complete" => false}}}]; k, ex = JudgmentEval.without_incomplete_window(cs, "finding_triage"); [k.size, ex.size].join(" ")'
ruby_eq "the window-incomplete line counts, names, and says n/a, never a score [DND-1483]" \
  "window-incomplete excluded: 2 (n/a, not scored: the root's context window had partly rotated out of the inbox when it was snapshotted): i1, i2" \
  'JudgmentEval.window_incomplete_line(["i1", "i2"])'
ruby_eq "no line when nothing was excluded [DND-1483]" \
  "nil" \
  'JudgmentEval.window_incomplete_line([]).inspect'
# DND-1637: one sample per case let a near-zero-confidence answer that flips
# between runs decide a keep/revert bar. A verdict needs >= 2 samples that
# all scored and all gave the same answer; answers that differ are unstable.
VS='s = ->(id, p, c) { {"case_id" => id, "outcome" => "scored", "predicted" => p, "confidence" => c} }; L = {"a" => "blocks", "b" => "does_not_block", "c" => "blocks", "d" => "blocks"}'
ruby_eq "verdicts: a flipped low-confidence sample is unstable, never a match or a miss [DND-1637]" \
  "unstable" \
  "${VS}; JudgmentEval.case_verdicts({\"b\" => \"does_not_block\"}, [[s.(\"b\", \"blocks\", 0.09)], [s.(\"b\", \"does_not_block\", 0.02)], [s.(\"b\", \"blocks\", 0.11)]]).first[:verdict]"
ruby_eq "verdicts: every sample agreeing decides match or miss [DND-1637]" \
  "a:match c:miss" \
  "${VS}; JudgmentEval.case_verdicts({\"a\" => \"blocks\", \"c\" => \"blocks\"}, [[s.(\"a\", \"blocks\", 0.98), s.(\"c\", \"does_not_block\", 0.6)], [s.(\"a\", \"blocks\", 0.97), s.(\"c\", \"does_not_block\", 0.64)]]).map { |v| \"#{v[:case_id]}:#{v[:verdict]}\" }.join(\" \")"
ruby_eq "verdicts: misses that disagree on the answer are unstable, not a stable miss [DND-1637]" \
  "unstable" \
  "${VS}; JudgmentEval.case_verdicts({\"x\" => \"LOW\"}, [[s.(\"x\", \"MEDIUM\", 0.5)], [s.(\"x\", \"HIGH\", 0.5)]]).first[:verdict]"
ruby_eq "verdicts: one sample alone decides nothing (n/a) [DND-1637]" \
  "n/a" \
  "${VS}; JudgmentEval.case_verdicts({\"a\" => \"blocks\"}, [[s.(\"a\", \"blocks\", 0.98)]]).first[:verdict]"
ruby_eq "verdicts: an unscored or absent sample is n/a, never wrong [DND-1637]" \
  "a:n/a:blocks 0.98|unscored timeout d:n/a:blocks 0.90|absent" \
  "${VS}; JudgmentEval.case_verdicts({\"a\" => \"blocks\", \"d\" => \"blocks\"}, [[s.(\"a\", \"blocks\", 0.98), s.(\"d\", \"blocks\", 0.9)], [{\"case_id\" => \"a\", \"outcome\" => \"unscored\", \"reason\" => \"timeout\"}]]).map { |v| [v[:case_id], v[:verdict], v[:answers].join(\"|\")].join(\":\") }.join(\" \")"
ruby_eq "verdict lines: a count line, then one line per case with every answer [DND-1637]" \
  "per-case verdicts over 2 samples: match 1, miss 0, unstable 1, n/a 0|  a (blocks): match [blocks 0.98, blocks 0.97]|  b (does_not_block): unstable [blocks 0.09, does_not_block 0.02]" \
  "${VS}; JudgmentEval.verdict_lines(JudgmentEval.case_verdicts({\"a\" => \"blocks\", \"b\" => \"does_not_block\"}, [[s.(\"a\", \"blocks\", 0.98), s.(\"b\", \"blocks\", 0.09)], [s.(\"a\", \"blocks\", 0.97), s.(\"b\", \"does_not_block\", 0.02)]]), 2).join(\"|\")"
ruby_eq "verdict lines: one sample per case computes no verdict and says how to get one [DND-1637]" \
  "per-case verdicts: not computed (1 sample per case; an answer near confidence 0 can flip between runs). For a keep/revert bar, re-run with --repeat 3 (DND-1637)." \
  "JudgmentEval.verdict_lines([], 1).join(\"|\")"

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

# DND-1048: the slack_routing context candidates. Root D1 at 1790570000.000100.
CTX_ROOT='r = {"channel"=>"D1","ts"=>"1790570000.000100","kind"=>"im","text"=>"ROOT","user"=>"U0O"}; ln = ->(o) { {"channel"=>"D1","user"=>"U0O","ts"=>"#{1790570000 + o}.000100","text"=>"t#{o}"}.merge(o == -1 ? {"user"=>"UFAKE00009","text"=>"OTHER"} : {}) }'
ruby_eq "context: slack ts parses to microseconds; anything else is nil [DND-1048]" \
  "1790570000000100 nil nil nil" \
  '[JudgmentEval.slack_ts_us("1790570000.000100"), JudgmentEval.slack_ts_us("1790570000.1"), JudgmentEval.slack_ts_us("99999999999.000100"), JudgmentEval.slack_ts_us(nil)].map(&:inspect).join(" ")'
ruby_eq "context: candidates are the root channel's top-level lines in its hour, oldest first [DND-1048]" \
  "t-3600 t-60" \
  "${CTX_ROOT}"'; JudgmentEval.context_candidates(r, [ln[-60], ln[-3600], ln[-3601], ln[0], ln[5], ln[-30].merge("channel"=>"D2")], "U0O").map { |c| c["text"] }.join(" ")'
ruby_eq "context: another person's line is a candidate with its text emptied (D7) [DND-1048]" \
  'UFAKE00009:' \
  "${CTX_ROOT}"'; JudgmentEval.context_candidates(r, [ln[-1]], "U0O").map { |c| c["user"] + ":" + c["text"] }.join(" ")'
ruby_eq "context: a thread reply is never a candidate; a thread parent is [DND-1048]" \
  "t-60" \
  "${CTX_ROOT}"'; JudgmentEval.context_candidates(r, [ln[-60].merge("thread_ts"=>"1790569940.000100"), ln[-30].merge("thread_ts"=>"1790560000.000100")], "U0O").map { |c| c["text"] }.join(" ")'
ruby_eq "context: a line the inbox holds twice is one candidate [DND-1048]" \
  "1" \
  "${CTX_ROOT}"'; JudgmentEval.context_candidates(r, [ln[-60], ln[-60], ln[-60]], "U0O").size'
ruby_eq "context: a candidate carries only the endpoint's fields [DND-1048]" \
  '["channel","user","ts","text","thread_ts"]' \
  "${CTX_ROOT}"'; JSON.generate(JudgmentEval.context_candidates(r, [ln[-60].merge("event_id"=>"Ev1","route"=>"x")], "U0O").first.keys)'
ruby_eq "context: at most 200 candidates, the most recent [DND-1048]" \
  "200 t-1" \
  "${CTX_ROOT}"'; c = JudgmentEval.context_candidates(r, (2..250).map { |o| ln[-o] } + [ln[-60].merge("text"=>"t-1","ts"=>"1790569999.000100")], "U0O"); [c.size, c.last["text"]].join(" ")'
ruby_eq "context: a root with a malformed ts gets no candidates [DND-1048]" \
  "0" \
  "${CTX_ROOT}"'; JudgmentEval.context_candidates(r.merge("ts"=>"bad"), [ln[-60]], "U0O").size'
ruby_eq "context: the request names bot_id only when given [DND-1048]" \
  'false B0X' \
  "${CTX_ROOT}"'; [JudgmentEval.context_request(r, []).key?("bot_id"), JudgmentEval.context_request(r, [], "B0X")["bot_id"]].join(" ")'
ruby_eq "context: the harness's rules are the labeller's constants, and the router's (3600/6/500) [DND-1048 x DND-1047]" \
  '{"window_s":3600,"max_entries":6,"max_text":500} true' \
  '[JSON.generate(JudgmentEval::CONTEXT_RULES), JudgmentEval::CONTEXT_RULES == {"window_s"=>JudgmentContext::WINDOW_S,"max_entries"=>JudgmentContext::MAX_MESSAGES,"max_text"=>JudgmentContext::JUDGE_TEXT_CAP}].join(" ")'
ruby_eq "context: a reply that matches the harness passes the check [DND-1048]" \
  "nil" \
  'JudgmentEval.check_context({"question_set_version"=>"slack-routing-v2","rules"=>{"window_s"=>3600,"max_entries"=>6,"max_text"=>500},"owner_slack_user_id"=>"U0O"}, "U0O").inspect'
ruby_eq "context: another version, other rules, another owner or a missing field each fail the check [DND-1048]" \
  "4" \
  'ok = {"question_set_version"=>"slack-routing-v2","rules"=>{"window_s"=>3600,"max_entries"=>6,"max_text"=>500},"owner_slack_user_id"=>"U0O"}; [ok.merge("question_set_version"=>"slack-routing-v3"), ok.merge("rules"=>{"window_s"=>7200,"max_entries"=>6,"max_text"=>500}), ok.merge("owner_slack_user_id"=>"U0X"), ok.reject { |k, _| k == "rules" }].count { |d| JudgmentEval.check_context(d, "U0O") }'
ruby_eq "context: an owner mismatch names neither owner id (a work value) [DND-1048 x DND-704]" \
  "the server's owner Slack user id differs from the private overlay's (neither is printed)" \
  'JudgmentEval.check_context({"question_set_version"=>"slack-routing-v2","rules"=>{"window_s"=>3600,"max_entries"=>6,"max_text"=>500},"owner_slack_user_id"=>"UFAKE00002"}, "UFAKE00001")'
ruby_eq "context: the case input is the root's text and kind with the context, nothing else [DND-1048]" \
  '{"text":"ROOT","kind":"im","context":[]}' \
  "${CTX_ROOT}"'; JSON.generate(JudgmentEval.context_input(r, []))'
# DND-1567: a root written before HG-22 carries the legacy kind "dm", which
# covered both im and mpim (athena-inbox.md -> Line format). The server's
# context endpoint and the slack-routing-v2 state take only im, mpim or
# mention, so the harness maps it: a D channel is a 1:1 (im), any other
# channel a group DM (mpim).
ruby_eq "kind: a legacy dm root in a D channel is sent as im [DND-1567]" \
  "im" \
  "${CTX_ROOT}"'; JudgmentEval.contract_kind(r.merge("kind"=>"dm"))'
ruby_eq "kind: a legacy dm root in a non-D channel is sent as mpim [DND-1567]" \
  "mpim mpim" \
  "${CTX_ROOT}"'; [JudgmentEval.contract_kind(r.merge("kind"=>"dm","channel"=>"GFAKE0001")), JudgmentEval.contract_kind(r.merge("kind"=>"dm","channel"=>"CFAKE0001"))].join(" ")'
ruby_eq "kind: im, mpim and mention pass unchanged [DND-1567]" \
  "im mpim mention" \
  "${CTX_ROOT}"'; %w[im mpim mention].map { |k| JudgmentEval.contract_kind(r.merge("kind"=>k)) }.join(" ")'
ruby_eq "kind: any other kind passes unchanged, so the server's refusal names it [DND-1567]" \
  '["thread_reply","channel",null]' \
  "${CTX_ROOT}"'; JSON.generate(["thread_reply", "channel", nil].map { |k| JudgmentEval.contract_kind(r.merge("kind"=>k)) })'
ruby_eq "kind: a legacy dm with no channel is not guessed [DND-1567]" \
  '"dm"' \
  "${CTX_ROOT}"'; JudgmentEval.contract_kind(r.merge("kind"=>"dm").reject { |k, _| k == "channel" }).inspect'
ruby_eq "kind: the context request of a legacy dm root carries im [DND-1567]" \
  "im" \
  "${CTX_ROOT}"'; JudgmentEval.context_request(r.merge("kind"=>"dm"), [])["kind"]'
ruby_eq "kind: the case input of a legacy dm root carries im [DND-1567]" \
  '{"text":"ROOT","kind":"im","context":[]}' \
  "${CTX_ROOT}"'; JSON.generate(JudgmentEval.context_input(r.merge("kind"=>"dm"), []))'
ruby_eq "context: an unavailable case is counted and named [DND-1048]" \
  "context: built 1 of 2|unscored 1 (context_unavailable, not sent): Ev2" \
  'JudgmentEval.context_lines(1, [{case_id: "Ev2"}]).join("|")'

echo "== end to end"

TOKEN="judgment-eval-test-token-$$-${RANDOM}-c4e1"
printf '%s\n' "${TOKEN}" > "${TMP}/token"
mkdir -p "${TMP}/cfg" "${TMP}/data" "${TMP}/home"
jq -n --arg t "${TOKEN}" '{server_url: "wss://example.invalid/machine/websocket", token: $t}' > "${TMP}/cfg/config.json"
chmod 600 "${TMP}/cfg/config.json"
export ATHENA_INBOX_CLIENT_CONFIG="${TMP}/cfg/config.json"
export FLEET_CLAUDE_JSON="${TMP}/claude.json"
export XDG_DATA_HOME="${TMP}/data"
# The owner's Slack id is a work value: it lives only in the private overlay
# (ai/contracts/athena-private-overlay.md), never in this public repo. The
# suite feeds a SYNTHETIC id the way the real one is fed: to judgment-eval
# through a fixture overlay (ATHENA_PRIVATE_ROOT), and to the fake server as
# the owner id its app would hold.
OWNER_ID="UFAKE00001"
overlay_root() { # overlay_root DIR SLACK_JSON
  mkdir -p "$1/overlay"
  printf '{"kind":"athena-private-overlay","schema":1}\n' >"$1/athena-overlay.json"
  printf '%s\n' "$2" >"$1/overlay/slack.json"
  chmod 700 "$1" "$1/overlay"
}
OVERLAY="${TMP}/overlay"
overlay_root "${OVERLAY}" "{\"people\":{\"owner\":{\"user_id\":\"${OWNER_ID}\"}}}"
export ATHENA_PRIVATE_ROOT="${OVERLAY}"
export FAKE_OWNER_SLACK_USER_ID="${OWNER_ID}"
: > "${TMP}/server.log"
printf '{"auto":"not_configured"}\n' > "${TMP}/responses.json"

python3 "${FAKE}" "${TMP}/port" "${TMP}/server.log" "${TMP}/responses.json" "${TMP}/token" "${TMP}/context.json" &
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

NOHOME="${TMP}/no-overlay-home"
mkdir -p "${NOHOME}"
OUT="$(env -u ATHENA_PRIVATE_ROOT HOME="${NOHOME}" "${BIN}" --help 2>"${TMP}/err")"; RC=$?; ERR="$(cat "${TMP}/err")"
eq "--help exits 0 with no private overlay [DND-1048 x DND-704]" "${RC}" "0"
has "--help prints the usage on stdout" "${OUT}" "Usage: judgment-eval"
has "--help names the overlay key the owner id is read from [DND-1048 x DND-704]" "${OUT}" "slack .people.owner.user_id"
lacks "--help prints no owner id [DND-1048 x DND-704]" "${OUT}" "${OWNER_ID}"
eq "--help writes nothing to stderr [DND-1048 x DND-704]" "${ERR}" ""

run --use-case finding_triage --labels "${TMP}/labels.jsonl"
eq "a missing --corpus is usage (2)" "${RC}" "2"
has "the usage error carries Fix:" "${ERR}" "Fix: "
run --use-case finding_triage --labels "${TMP}/labels.jsonl" --corpus "${TMP}/corpus.jsonl" --bogus
eq "an unknown flag is usage (2)" "${RC}" "2"
run --use-case general --labels "${TMP}/labels.jsonl" --corpus "${TMP}/corpus.jsonl" --content-domain blend
eq "an unknown use case is usage (2)" "${RC}" "2"
has "the unknown-use-case Fix: names the ticket use cases [DND-1055]" "${ERR}" "ticket_kind, ticket_severity, ticket_security"

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

# The committed ticket_blocking measurement fixture (DND-1579): the four owner
# overrides of ticket-blocking-v1, paraphrased, plus six controls. It is the
# before/after set for a ticket_blocking question-set version, so it must
# keep joining: 10 cases, 4 blocks and 6 does_not_block, nothing excluded.
TBF="${HERE}/fixtures/ticket-blocking-dnd-1579"
run --use-case ticket_blocking --labels "${TBF}/labels.jsonl" --corpus "${TBF}/corpus.jsonl" --dry-run
eq "the DND-1579 ticket_blocking fixture dry-runs clean" "${RC}" "0"
has "the DND-1579 fixture joins all 10 cases, 4 blocks and 6 does_not_block" "${OUT}" "cases: 10 (blocks 4, does_not_block 6)"
has "the DND-1579 fixture excludes no proposed label" "${OUT}" "proposed excluded: 0"
eq "the DND-1579 fixture dry run reports no join miss" "${ERR}" ""
eq "the DND-1579 fixture dry run sends nothing" "$(requests)" "${n}"

# The second ticket_blocking fixture (DND-1607): three live filer overrides
# after the DND-1579 set was cut, plus two controls that truly block.
TBL="${HERE}/fixtures/ticket-blocking-dnd-1607"
run --use-case ticket_blocking --labels "${TBL}/labels.jsonl" --corpus "${TBL}/corpus.jsonl" --dry-run
eq "the DND-1607 ticket_blocking fixture dry-runs clean" "${RC}" "0"
has "the DND-1607 fixture joins all 5 cases, 2 blocks and 3 does_not_block" "${OUT}" "cases: 5 (blocks 2, does_not_block 3)"
has "the DND-1607 fixture excludes no proposed label" "${OUT}" "proposed excluded: 0"
eq "the DND-1607 fixture dry run reports no join miss" "${ERR}" ""
eq "the DND-1607 fixture dry run sends nothing" "$(requests)" "${n}"

# The committed ticket_severity measurement fixture (DND-1600): the eight
# owner overrides of ticket-severity-v1, paraphrased. It is the before/after
# set for ticket-severity-v2, judged on the bar its README registered before
# any run, so it must keep joining: 8 cases, nothing excluded.
TSF="${HERE}/fixtures/ticket-severity-dnd-1600"
run --use-case ticket_severity --labels "${TSF}/labels.jsonl" --corpus "${TSF}/corpus.jsonl" --dry-run
eq "the DND-1600 ticket_severity fixture dry-runs clean" "${RC}" "0"
has "the DND-1600 fixture joins all 8 cases, HIGH 2, LOW 5, MEDIUM 1" "${OUT}" "cases: 8 (HIGH 2, LOW 5, MEDIUM 1)"
has "the DND-1600 fixture excludes no proposed label" "${OUT}" "proposed excluded: 0"
eq "the DND-1600 fixture dry run reports no join miss" "${ERR}" ""
eq "the DND-1600 fixture dry run sends nothing" "$(requests)" "${n}"

# The committed ticket_security measurement fixture (DND-1697): the four
# filer overrides of ticket-security-v1 (quality gates read as security
# controls), paraphrased, plus nine kept security controls and five of them
# with their self-labels removed. It is the before/after set for
# ticket-security-v2, judged on the bar its README committed before any v2
# run, so it must keep joining: 18 cases.
TSS="${HERE}/fixtures/ticket-security-dnd-1697"
run --use-case ticket_security --labels "${TSS}/labels.jsonl" --corpus "${TSS}/corpus.jsonl" --dry-run
eq "the DND-1697 ticket_security fixture dry-runs clean" "${RC}" "0"
has "the DND-1697 fixture joins all 18 cases, none 4 and security 14" "${OUT}" "cases: 18 (none 4, security 14)"
has "the DND-1697 fixture excludes no proposed label" "${OUT}" "proposed excluded: 0"
eq "the DND-1697 fixture dry run reports no join miss" "${ERR}" ""
eq "the DND-1697 fixture dry run sends nothing" "$(requests)" "${n}"

# The ticket-security-v3 held-out scorer (DND-1697 v3): per-case verdicts
# from two --repeat 3 run files. Only `match` is right; unstable counts as a
# miss. An n/a case that could hide a lost case makes the result COULD NOT
# MEASURE (exit 3), never a pass; FAIL exits 1, PASS 0, a refused input 2.
SV3="${TSS}/score-v3.rb"
V3D="${TMP}/dnd1697v3"
mkdir -p "${V3D}"
# mkrun FILE VERSION REPEAT "case:label:verdict ..." [SHA] -- a synthetic run file.
mkrun() {
  /usr/bin/ruby -rjson -e '
    file, version, repeat, spec, sha = ARGV
    verdicts = spec.split.map { |s| id, label, v = s.split(":"); { "case_id" => id, "label" => label, "verdict" => v } }
    run = { "eval_run_id" => "00000000-0000-4000-8000-000000000000", "question_set_version" => version,
            "model" => "jev-test", "repeat" => repeat.to_i, "candidate" => version != "ticket-security-v1",
            "labels_sha256" => sha || "sha-a" }
    run["verdicts"] = verdicts if repeat.to_i >= 2
    File.write(file, JSON.generate(run))' "$@"
}
sv3() { OUT="$(/usr/bin/ruby "${SV3}" "$@" 2>&1)"; RC=$?; }
printf '%s\n' '{"id":"a","label":"security"}' '{"id":"b","label":"none"}' '{"id":"c","label":"none"}' '{"id":"d","label":"security"}' > "${V3D}/labels.jsonl"
mkrun "${V3D}/v1.json" ticket-security-v1 3 "a:security:match b:none:match c:none:miss d:security:unstable"
mkrun "${V3D}/v3.json" ticket-security-v3 3 "a:security:match b:none:match c:none:match d:security:miss"
sv3 "${V3D}/v1.json" "${V3D}/v3.json" "${V3D}/labels.jsonl"
eq "score-v3: a passing comparison exits 0" "${RC}" "0"
has "score-v3: no case v1 matches is lost" "${OUT}" "item 2: cases v1 matches that v3 does not: 0 -> PASS"
has "score-v3: false security counts unstable and miss, v1 1 of 2, v3 0 of 2" "${OUT}" "item 3 (held-out): none cases not matched: v1 1/2, v3 0/2 -> PASS"
has "score-v3: a miss v1 already had is no regression" "${OUT}" "result: PASS"

mkrun "${V3D}/v3-lost.json" ticket-security-v3 3 "a:security:unstable b:none:match c:none:match d:security:match"
sv3 "${V3D}/v1.json" "${V3D}/v3-lost.json" "${V3D}/labels.jsonl"
has "score-v3: an unstable case v1 matched is a lost case, named" "${OUT}" "item 2: cases v1 matches that v3 does not: 1 (a) -> FAIL"
has "score-v3: a lost case fails the result" "${OUT}" "result: FAIL"
eq "score-v3: FAIL exits 1" "${RC}" "1"

# b (v1 match) is n/a under v3: it could hide a lost case. d is absent from
# v3 but v1 measured it unstable, so v3 cannot be worse there.
mkrun "${V3D}/v3-na.json" ticket-security-v3 3 "a:security:match b:none:n/a c:none:match"
sv3 "${V3D}/v1.json" "${V3D}/v3-na.json" "${V3D}/labels.jsonl"
has "score-v3: n/a and absent cases are named" "${OUT}" "n/a (no measured verdict in at least one run, left out of both): 2 (b, d)"
has "score-v3: only an n/a that could hide a lost case is named as such" "${OUT}" "n/a that could hide a lost case: 1 (b)"
has "score-v3: such an n/a makes the result could-not-measure, never a pass" "${OUT}" "result: COULD NOT MEASURE"
eq "score-v3: COULD NOT MEASURE exits 3" "${RC}" "3"

mkrun "${V3D}/v3-na-benign.json" ticket-security-v3 3 "a:security:match b:none:match c:none:match"
sv3 "${V3D}/v1.json" "${V3D}/v3-na-benign.json" "${V3D}/labels.jsonl"
has "score-v3: an n/a v1 already missed is left out and still passes" "${OUT}" "result: PASS"

mkrun "${V3D}/v3-r1.json" ticket-security-v3 1 ""
sv3 "${V3D}/v1.json" "${V3D}/v3-r1.json" "${V3D}/labels.jsonl"
eq "score-v3: a run with no per-case verdicts is refused (exit 2)" "${RC}" "2"
has "score-v3: the refusal says to measure with --repeat 3" "${OUT}" "Fix: measure with judgment-eval --repeat 3"

mkrun "${V3D}/v4.json" ticket-security-v4 3 "a:security:match b:none:match c:none:match d:security:miss"
sv3 "${V3D}/v1.json" "${V3D}/v4.json" "${V3D}/labels.jsonl"
eq "score-v3: a ticket-security-v4 run is scored against the same bar (exit 0)" "${RC}" "0"
has "score-v3: the v4 run is named in the header" "${OUT}" "ticket-security-v4 jev-test repeat=3 candidate=true"
mkrun "${V3D}/v2.json" ticket-security-v2 3 "a:security:match b:none:match c:none:match d:security:miss"
sv3 "${V3D}/v1.json" "${V3D}/v2.json" "${V3D}/labels.jsonl"
eq "score-v3: a v2 run is refused: the v3 bar covers v3 and later (exit 2)" "${RC}" "2"

sv3 "${V3D}/v3.json" "${V3D}/v1.json" "${V3D}/labels.jsonl"
eq "score-v3: swapped runs are refused (exit 2)" "${RC}" "2"
has "score-v3: the swap refusal names the order" "${OUT}" "Fix: pass the v1 run first and the v3 run second"

mkrun "${V3D}/v3-sha.json" ticket-security-v3 3 "a:security:match b:none:match c:none:match d:security:match" sha-b
sv3 "${V3D}/v1.json" "${V3D}/v3-sha.json" "${V3D}/labels.jsonl"
eq "score-v3: runs against different labels files are refused (exit 2)" "${RC}" "2"
has "score-v3: the labels refusal carries Fix:" "${OUT}" "Fix: measure both versions against the same labels file"

mkrun "${V3D}/v3-relabel.json" ticket-security-v3 3 "a:none:match b:none:match c:none:match d:security:match"
sv3 "${V3D}/v1.json" "${V3D}/v3-relabel.json" "${V3D}/labels.jsonl"
eq "score-v3: a verdict scored against another label is refused (exit 2)" "${RC}" "2"

sv3 "${V3D}/v1.json" "${V3D}/missing.json" "${V3D}/labels.jsonl"
eq "score-v3: a missing run file is refused (exit 2), not a backtrace" "${RC}" "2"
has "score-v3: the missing-file refusal carries Fix:" "${OUT}" "Fix: pass a run file judgment-eval wrote"

# Item 3 is a count and a rate: at most 31 false security calls, and at most
# 31/291 of the none cases measured in both runs.
/usr/bin/ruby -e 'puts (1..300).map { |i| %({"id":"n#{i}","label":"none"}) }' > "${V3D}/labels-300.jsonl"
mkrun "${V3D}/v1-300.json" ticket-security-v1 3 "$(/usr/bin/ruby -e 'puts (1..300).map { |i| "n#{i}:none:#{i <= 40 ? "miss" : "match"}" }.join(" ")')"
mkrun "${V3D}/v3-31.json" ticket-security-v3 3 "$(/usr/bin/ruby -e 'puts (1..300).map { |i| "n#{i}:none:#{i <= 31 ? "unstable" : "match"}" }.join(" ")')"
mkrun "${V3D}/v3-32.json" ticket-security-v3 3 "$(/usr/bin/ruby -e 'puts (1..300).map { |i| "n#{i}:none:#{i <= 32 ? "miss" : "match"}" }.join(" ")')"
sv3 "${V3D}/v1-300.json" "${V3D}/v3-31.json" "${V3D}/labels-300.jsonl"
has "score-v3: 31 false security calls of 300 is within item 3" "${OUT}" "item 3 (held-out): none cases not matched: v1 40/300, v3 31/300 -> PASS"
sv3 "${V3D}/v1-300.json" "${V3D}/v3-32.json" "${V3D}/labels-300.jsonl"
has "score-v3: 32 false security calls fails item 3 on the count" "${OUT}" "item 3 (held-out): none cases not matched: v1 40/300, v3 32/300 -> FAIL"
# n40 is a none case v1 missed, so it cannot hide a lost case, but v3 left it
# n/a: it may be one more false call. With 31 measured, that one decides item 3.
mkrun "${V3D}/v3-31-na.json" ticket-security-v3 3 "$(/usr/bin/ruby -e 'puts (1..300).map { |i| "n#{i}:none:#{i <= 31 ? "miss" : (i == 40 ? "n/a" : "match")}" }.join(" ")')"
sv3 "${V3D}/v1-300.json" "${V3D}/v3-31-na.json" "${V3D}/labels-300.jsonl"
has "score-v3: a none n/a that could be the 32nd false call is named" "${OUT}" "item 3 undecided: 1 none case(s) v3 left n/a could each be a false call (n40)"
eq "score-v3: it makes the result COULD NOT MEASURE (exit 3), never PASS" "${RC}" "3"
mkrun "${V3D}/v3-30-na.json" ticket-security-v3 3 "$(/usr/bin/ruby -e 'puts (1..300).map { |i| "n#{i}:none:#{i <= 30 ? "miss" : (i == 40 ? "n/a" : "match")}" }.join(" ")')"
sv3 "${V3D}/v1-300.json" "${V3D}/v3-30-na.json" "${V3D}/labels-300.jsonl"
eq "score-v3: a none n/a that cannot change item 3 still passes (exit 0)" "${RC}" "0"
printf '%s\n' '{"id":"a","label":"security"}' '{"id":"a","label":"none"}' > "${V3D}/labels-dup.jsonl"
sv3 "${V3D}/v1.json" "${V3D}/v3.json" "${V3D}/labels-dup.jsonl"
eq "score-v3: a labels file naming a case twice is refused (exit 2)" "${RC}" "2"
/usr/bin/ruby -e 'puts (1..200).map { |i| %({"id":"m#{i}","label":"none"}) }' > "${V3D}/labels-200.jsonl"
mkrun "${V3D}/v1-200.json" ticket-security-v1 3 "$(/usr/bin/ruby -e 'puts (1..200).map { |i| "m#{i}:none:#{i <= 30 ? "miss" : "match"}" }.join(" ")')"
mkrun "${V3D}/v3-200-21.json" ticket-security-v3 3 "$(/usr/bin/ruby -e 'puts (1..200).map { |i| "m#{i}:none:#{i <= 21 ? "miss" : "match"}" }.join(" ")')"
mkrun "${V3D}/v3-200-22.json" ticket-security-v3 3 "$(/usr/bin/ruby -e 'puts (1..200).map { |i| "m#{i}:none:#{i <= 22 ? "miss" : "match"}" }.join(" ")')"
sv3 "${V3D}/v1-200.json" "${V3D}/v3-200-21.json" "${V3D}/labels-200.jsonl"
has "score-v3: 21 of 200 is within the 31/291 rate" "${OUT}" "item 3 (held-out): none cases not matched: v1 30/200, v3 21/200 -> PASS"
sv3 "${V3D}/v1-200.json" "${V3D}/v3-200-22.json" "${V3D}/labels-200.jsonl"
has "score-v3: 22 of 200 fails on the rate alone (22 <= 31, 22/200 > 31/291)" "${OUT}" "item 3 (held-out): none cases not matched: v1 30/200, v3 22/200 -> FAIL"

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
has "a one-sample run computes no per-case verdict and names --repeat [DND-1637]" "${OUT}" "per-case verdicts: not computed (1 sample per case"

# DND-1637: --repeat N runs the same cases N times, each its own server run,
# and a case whose answers differ is unstable. The fake answers c2 (related)
# with related 0.02 in sample 1 and unrelated 0.09 in sample 2 (the
# DND-1607 live-2 shape), and c1 / c3 the same way both times.
sample() { # sample RUN_ID C2_PREDICTED C2_CONF
  printf '{"status":200,"body":{"data":{"eval_run_id":"%s","use_case":"finding_triage","question_set_version":"v1","model":"jev-1.13.0","results":[{"case_id":"c1","outcome":"scored","predicted":"duplicate","confidence":0.95},{"case_id":"c2","outcome":"scored","predicted":"%s","confidence":%s},{"case_id":"c3","outcome":"scored","predicted":"duplicate","confidence":0.7}],"report":%s}}}' "$1" "$2" "$3" "${report}"
}
R1=11111111-1111-4111-8111-111111111111
R2=22222222-2222-4222-8222-222222222222
respond "[$(sample "${R1}" related 0.02),$(sample "${R2}" unrelated 0.09)]"
rm -f "${XDG_DATA_HOME}/athena/evals/runs/"*-finding_triage.json
n="$(requests)"
run --use-case finding_triage --labels "${TMP}/labels.jsonl" --corpus "${TMP}/corpus.jsonl" --content-domain blend --pause 0 --repeat 2
eq "--repeat 2 exits 0 [DND-1637]" "${RC}" "0"
eq "--repeat 2 sends the cases twice [DND-1637]" "$(requests)" "$((n + 2))"
eq "each sample starts its own server run (no eval_run_id) [DND-1637]" "$(sed -n "$((n + 1)),$((n + 2))p" "${TMP}/server.log" | jq -r '.body.eval_run_id // "none"' | tr '\n' ' ')" "none none "
eq "each sample sends the same cases [DND-1637]" "$(sed -n "$((n + 1)),$((n + 2))p" "${TMP}/server.log" | jq -c '[.body.cases[].case_id]' | sort -u)" '["c1","c2","c3"]'
has "the flipped low-confidence case is unstable, not a match [DND-1637]" "${OUT}" "  c2 (related): unstable [related 0.02, unrelated 0.09]"
has "an agreeing correct case is a match [DND-1637]" "${OUT}" "  c1 (duplicate): match [duplicate 0.95, duplicate 0.95]"
has "an agreeing wrong case is a miss [DND-1637]" "${OUT}" "  c3 (unrelated): miss [duplicate 0.70, duplicate 0.70]"
has "the verdict count line counts the unstable case apart [DND-1637]" "${OUT}" "per-case verdicts over 2 samples: match 1, miss 1, unstable 1, n/a 0"
has "the run names each sample's run id [DND-1637]" "${OUT}" "sample 2 of 2: finding_triage run ${R2}"
has "the apply line names sample 1's run, pasteable [DND-1637]" "${OUT}" "apply with (sample 1's run): judgment-eval --apply ${R1}"
run_file="$(find "${XDG_DATA_HOME}/athena/evals/runs" -maxdepth 1 -type f -name '*-finding_triage.json' | head -n 1)"
eq "the run file keeps sample 1 at the top level (old readers unchanged) [DND-1637]" "$(jq -r '.eval_run_id + " " + (.results | length | tostring)' "${run_file}")" "${R1} 3"
eq "the run file records every sample's run id [DND-1637]" "$(jq -c '[.samples[].eval_run_id]' "${run_file}")" "[\"${R1}\",\"${R2}\"]"
eq "the run file records each case's verdict [DND-1637]" "$(jq -c '.verdicts | map({(.case_id): .verdict}) | add' "${run_file}")" '{"c1":"match","c2":"unstable","c3":"miss"}'
eq "the run file records the planned sample count [DND-1637]" "$(jq -r '.repeat' "${run_file}")" "2"

# A later sample that stops leaves every case n/a: one sample decides nothing.
respond "[$(sample "${R1}" related 0.02),{\"status\":500,\"body\":{\"error\":\"internal_error\"}}]"
run --use-case finding_triage --labels "${TMP}/labels.jsonl" --corpus "${TMP}/corpus.jsonl" --content-domain blend --pause 0 --repeat 2
eq "a stopped later sample exits with the stop code [DND-1637]" "${RC}" "5"
has "a stopped later sample leaves every case n/a [DND-1637]" "${OUT}" "per-case verdicts over 2 samples: match 0, miss 0, unstable 0, n/a 3"
has "a stopped later sample says which sample stopped [DND-1637]" "${ERR}" "stopped in sample 2 of 2"

# Stopped in sample 2 of 3: sample 3 is never taken, so EVERY case is n/a.
respond "[$(sample "${R1}" related 0.02),{\"status\":500,\"body\":{\"error\":\"internal_error\"}}]"
n="$(requests)"
run --use-case finding_triage --labels "${TMP}/labels.jsonl" --corpus "${TMP}/corpus.jsonl" --content-domain blend --pause 0 --repeat 3
eq "a stop in sample 2 of 3 takes no third sample [DND-1637]" "$(requests)" "$((n + 2))"
has "a stop in sample 2 of 3 says sample 3 was not taken and every case is n/a [DND-1637]" "${ERR}" "stopped in sample 2 of 3; samples 3..3 were not taken, so every case is n/a."
has "a stop in sample 2 of 3 counts every case n/a [DND-1637]" "${OUT}" "per-case verdicts over 3 samples: match 0, miss 0, unstable 0, n/a 3"

# Sample 1 stops at its first batch: no verdict, no run file, no n/a claim.
respond '{"status":500,"body":{"error":"internal_error"}}'
run --use-case finding_triage --labels "${TMP}/labels.jsonl" --corpus "${TMP}/corpus.jsonl" --content-domain blend --pause 0 --repeat 2
eq "sample 1 stopping at once exits 5 [DND-1637]" "${RC}" "5"
lacks "sample 1 stopping at once claims no n/a verdicts [DND-1637]" "${ERR}" "n/a"
lacks "sample 1 stopping at once prints no verdict line [DND-1637]" "${OUT}" "per-case verdicts"

# A later sample that scored nothing is called out with Fix:, never silent.
respond "[$(sample "${R1}" related 0.02),{\"auto\":\"not_configured\"}]"
run --use-case finding_triage --labels "${TMP}/labels.jsonl" --corpus "${TMP}/corpus.jsonl" --content-domain blend --pause 0 --repeat 2
eq "a later sample that scored nothing still exits 0 (sample 1 is a run) [DND-1637]" "${RC}" "0"
has "a later sample that scored nothing is named, with Fix: [DND-1637]" "${ERR}" "sample 2 of 2 scored nothing (reasons above), so every case is n/a. Fix: "
has "a later unscored sample reads every case n/a [DND-1637]" "${OUT}" "  c1 (duplicate): n/a [duplicate 0.95, unscored not_configured]"

run --use-case finding_triage --labels "${TMP}/labels.jsonl" --corpus "${TMP}/corpus.jsonl" --content-domain blend --repeat 6
eq "--repeat above 5 is usage (2) [DND-1637]" "${RC}" "2"
has "the --repeat refusal carries Fix: [DND-1637]" "${ERR}" "Fix: "
run --use-case finding_triage --labels "${TMP}/labels.jsonl" --corpus "${TMP}/corpus.jsonl" --content-domain blend --repeat 3 --dry-run
has "--dry-run prints the judged-call cost of the repeat [DND-1637]" "${OUT}" "samples: 3 per case (9 judged calls)"

# The use case's question set has not shipped yet.
respond '{"status":409,"body":{"error":"question_set_unavailable","fix":"use case finding_triage has no question set on this server yet. Fix: it ships with DND-713."}}'
run --use-case finding_triage --labels "${TMP}/labels.jsonl" --corpus "${TMP}/corpus.jsonl" --content-domain blend --pause 0
eq "question_set_unavailable exits 3" "${RC}" "3"
has "it prints JUDGMENTS UNAVAILABLE with the server's Fix:" "${ERR}" "JUDGMENTS UNAVAILABLE: question_set_unavailable: use case finding_triage has no question set on this server yet. Fix: it ships with DND-713."

respond '{"status":422,"body":{"error":"unprocessable_entity","fix":"cases[0].label is missing. Fix: send it."}}'
run --use-case finding_triage --labels "${TMP}/labels.jsonl" --corpus "${TMP}/corpus.jsonl" --content-domain blend --pause 0
eq "a refusal exits 5" "${RC}" "5"
has "a refusal prints the server's fix" "${ERR}" "cases[0].label is missing. Fix: send it."

# Every failure line carries Fix:, even when the server's own fix does not.
respond '{"status":409,"body":{"error":"question_set_unavailable"}}'
run --use-case finding_triage --labels "${TMP}/labels.jsonl" --corpus "${TMP}/corpus.jsonl" --content-domain blend --pause 0
eq "question_set_unavailable with no server fix still exits 3" "${RC}" "3"
has "question_set_unavailable with no server fix still carries Fix:" "${ERR}" "JUDGMENTS UNAVAILABLE: question_set_unavailable: Fix: "
respond '{"status":409,"body":{"error":"conflict","fix":"the run is already applied"}}'
run --use-case finding_triage --labels "${TMP}/labels.jsonl" --corpus "${TMP}/corpus.jsonl" --content-domain blend --pause 0
eq "a 409 whose server fix lacks the marker exits 5" "${RC}" "5"
has "a 409 whose server fix lacks the marker keeps the server's text" "${ERR}" "the run is already applied"
has "a 409 whose server fix lacks the marker still carries Fix:" "${ERR}" "Fix: "
respond '{"status":422,"body":{"error":"unprocessable_entity","fix":"cases[0].label is missing"}}'
run --use-case finding_triage --labels "${TMP}/labels.jsonl" --corpus "${TMP}/corpus.jsonl" --content-domain blend --pause 0
eq "a 4xx whose server fix lacks the marker exits 5" "${RC}" "5"
has "a 4xx whose server fix lacks the marker still carries Fix:" "${ERR}" "Fix: "

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
has "--apply prints a disabled label as n/a, insufficient evidence [DND-714]" "${OUT}" "related: disabled (n/a, n 7) -- insufficient evidence"
respond '{"status":404,"body":{"error":"not_found"}}'
run --apply "5f0c3a1e-8b2d-4c6f-9a7e-1d2b3c4d5e6f"
eq "--apply of a run that is absent or another owner's exits 5" "${RC}" "5"
has "the not_found line says it may not be this owner's" "${ERR}" "not this machine owner's"

echo "== slack_routing context (DND-1048)"

# Synthetic inbox: two *-slack.jsonl files. The corpus here is
# walt_ui-slack.jsonl itself (the labels join its event_id): a live inbox
# still joins. judgment-label's root snapshot (DND-1448) is the corpus it
# documents; ai/test/judgment-label covers that join.
INBOX="${TMP}/inbox"
mkdir -p "${INBOX}"
{
  printf '{"channel":"D1","user":"%s","ts":"1790570000.000100","thread_ts":null,"text":"ROOT-ONE","kind":"im","event_id":"Ev-r1"}\n' "${OWNER_ID}"
  printf '{"channel":"D2","user":"%s","ts":"1790571000.000100","thread_ts":null,"text":"ROOT-TWO","kind":"mpim","event_id":"Ev-r2"}\n' "${OWNER_ID}"
  printf '{"channel":"D1","user":"UFAKE00009","ts":"1790569700.000100","thread_ts":null,"text":"OTHER-SECRET","kind":"im","event_id":"Ev-m"}\n'
  printf '{"channel":"D3","user":"UFAKE00009","ts":"1790572000.000100","thread_ts":null,"text":"OTHER-ROOT","kind":"im","event_id":"Ev-mr"}\n'
} > "${INBOX}/walt_ui-slack.jsonl"
{
  printf '{"channel":"D1","user":"%s","ts":"1790569400.000100","thread_ts":null,"text":"OWNER-EARLIER","kind":"im","event_id":"Ev-e"}\n' "${OWNER_ID}"
  printf '{"channel":"D1","user":"%s","ts":"1790569400.000100","thread_ts":null,"text":"OWNER-EARLIER","kind":"im","event_id":"Ev-e"}\n' "${OWNER_ID}"
  printf '{"channel":"D1","user":"%s","ts":"1790569500.000100","thread_ts":"1790569000.000100","text":"OWNER-IN-THREAD","kind":"thread_reply","event_id":"Ev-t"}\n' "${OWNER_ID}"
  printf '{"channel":"D1","user":"%s","ts":"1790566000.000100","thread_ts":null,"text":"OWNER-OLD","kind":"im","event_id":"Ev-o"}\n' "${OWNER_ID}"
} > "${INBOX}/custom-slack.jsonl"
cat > "${TMP}/labels-slr.jsonl" <<'EOF'
{"id":"Ev-r1","label":"harness","provenance":"owner_confirmed","labeler":"owner","labeled_at":"2026-09-28T00:00:00Z"}
{"id":"Ev-r2","label":"walt_ui","provenance":"owner_confirmed","labeler":"owner","labeled_at":"2026-09-28T00:00:00Z"}
EOF
slr() { run --use-case slack_routing --labels "${TMP}/labels-slr.jsonl" --corpus "${INBOX}/walt_ui-slack.jsonl" --content-domain work --pause 0 --inbox-root "${INBOX}" "$@"; }
ctx_requests() { jq -c 'select(.path == "/api/v1/judgments/slack_routing/context")' "${TMP}/server.log"; }
eval_requests() { jq -c 'select(.path == "/api/v1/judgments/eval")' "${TMP}/server.log"; }
ctx_respond() { printf '%s\n' "$1" > "${TMP}/context.json"; }
GOOD_META='"question_set_version":"slack-routing-v2","rules":{"window_s":3600,"max_entries":6,"max_text":500},"owner_slack_user_id":"'"${OWNER_ID}"'"'

n="$(requests)"
slr --dry-run
eq "slack_routing --dry-run exits 0 [DND-1048]" "${RC}" "0"
has "--dry-run builds no context [DND-1048]" "${OUT}" "context: not built (dry run)"
has "--dry-run prints the candidate counts [DND-1048]" "${OUT}" "context candidates: 2 line(s), 1 the owner's, for 1 of 2 case(s)"
has "the run names the inbox files it read [DND-1048]" "${OUT}" "inbox files: 2 read (custom-slack.jsonl, walt_ui-slack.jsonl)"
eq "--dry-run makes no call at all [DND-1048]" "$(requests)" "${n}"
lacks "--dry-run never prints a context's text [DND-1048]" "${OUT}" "OWNER-EARLIER"
# The inbox's rotated generation holds the channel's earlier lines
# (athena-inbox.md -> Retention): it is read with its live file (DND-1497).
printf '{"channel":"D2","user":"%s","ts":"1790570500.000100","thread_ts":null,"text":"OWNER-IN-GENERATION","kind":"im","event_id":"Ev-g"}\n' "${OWNER_ID}" > "${INBOX}/walt_ui-slack.jsonl.1"
slr --dry-run
has "the run names the rotated generation it read [DND-1497]" "${OUT}" "inbox files: 3 read (custom-slack.jsonl, walt_ui-slack.jsonl.1, walt_ui-slack.jsonl)"
has "a line only in the generation is a context candidate [DND-1497]" "${OUT}" "context candidates: 3 line(s), 2 the owner's, for 2 of 2 case(s)"
rm -f "${INBOX}/walt_ui-slack.jsonl.1"

respond '{"auto":"not_configured"}'
rm -f "${TMP}/context.json"
: > "${TMP}/server.log"
slr
eq "a slack_routing run with no key still exits 3 [DND-1048]" "${RC}" "3"
eq "one context request per root, then one eval batch [DND-1048]" "$(requests)" "3"
first_ctx="$(ctx_requests | head -n 1)"
eq "the context request is for the root's channel, ts and kind [DND-1048]" \
  "$(jq -c '.body | [.channel, .ts, .kind]' <<<"${first_ctx}")" '["D1","1790570000.000100","im"]'
eq "candidates: top-level, one per ts, in the hour; only the owner's keeps its text (D7) [DND-1048]" \
  "$(jq -c '[.body.candidates[] | [.user, .text]]' <<<"${first_ctx}")" '[["'"${OWNER_ID}"'","OWNER-EARLIER"],["UFAKE00009",""]]'
eq "the request names no bot_id unless given [DND-1048]" "$(jq -c '.body | has("bot_id")' <<<"${first_ctx}")" "false"
eq "the context request authenticated with the machine token [DND-1048]" "$(jq -r .auth_ok <<<"${first_ctx}")" "true"
eq "the token was in no argv during the context request [DND-1048]" "$(jq -c .argv_leak <<<"${first_ctx}")" "[]"
if ctx_requests | grep -q OTHER-SECRET; then bad "no context request carries another person's text (D7) [DND-1048]"; else ok "no context request carries another person's text (D7) [DND-1048]"; fi
eval_req="$(eval_requests)"
eq "each case input is {text, kind, context} from the endpoint [DND-1048]" \
  "$(jq -c '.body.cases[0].input' <<<"${eval_req}")" '{"text":"ROOT-ONE","kind":"im","context":[{"from":"owner","text":"OWNER-EARLIER"}]}'
eq "an empty context is still a context [DND-1048]" \
  "$(jq -c '.body.cases[1].input' <<<"${eval_req}")" '{"text":"ROOT-TWO","kind":"mpim","context":[]}'
has "the run reports the contexts built [DND-1048]" "${OUT}" "context: built 2 of 2"

# --bot-id reaches the request.
: > "${TMP}/server.log"
slr --bot-id B0ATHENA
eq "--bot-id is sent as bot_id [DND-1048]" "$(ctx_requests | head -n 1 | jq -r .body.bot_id)" "B0ATHENA"
run --use-case slack_routing --labels "${TMP}/labels-slr.jsonl" --corpus "${INBOX}/walt_ui-slack.jsonl" --content-domain work --inbox-root "${INBOX}" --bot-id "not a bot" --dry-run
eq "a malformed --bot-id is usage (2) [DND-1048]" "${RC}" "2"

# A failed context call leaves that case unscored context_unavailable, with the server's own fix.
ctx_respond '[{"status":503,"body":{"error":"context_unavailable","fix":"Fix: check the database."}},{"auto":"context"}]'
: > "${TMP}/server.log"
rm -rf "${XDG_DATA_HOME}/athena/evals/runs"
slr
eq "a run with one unavailable context still exits 3 with no key [DND-1048]" "${RC}" "3"
eq "the unavailable case is not sent to the eval [DND-1048]" \
  "$(eval_requests | jq -c '[.body.cases[].case_id]')" '["Ev-r2"]'
has "the unavailable case is named as unscored context_unavailable [DND-1048]" "${OUT}" "unscored 1 (context_unavailable, not sent): Ev-r1"
has "the stderr line quotes the server's fix [DND-1048]" "${ERR}" "1 case(s) have no context (HTTP 503: Fix: check the database. x1): Ev-r1"
run_file="$(find "${XDG_DATA_HOME}/athena/evals/runs" -maxdepth 1 -type f | head -n 1)"
eq "exactly one file is written: the run file, no second corpus [DND-1048]" \
  "$(find "${XDG_DATA_HOME}" -type f | wc -l | tr -d ' ')" "1"
eq "the run file records the case as unscored context_unavailable [DND-1048]" \
  "$(jq -c '[.results[] | select(.reason == "context_unavailable") | .case_id]' "${run_file}")" '["Ev-r1"]'
eq "the run file names the inbox files [DND-1048]" "$(jq -c .context.inbox_files "${run_file}")" '["custom-slack.jsonl","walt_ui-slack.jsonl"]'
eq "the run file counts the root-snapshot contexts, 0 for a live-inbox corpus [DND-1448]" "$(jq -c .context.snapshot "${run_file}")" '{"cases":0}'
for text in ROOT-ONE ROOT-TWO OWNER-EARLIER OTHER-SECRET; do
  if grep -q "${text}" "${run_file}"; then bad "the run file holds no text (${text}) [DND-1048]"; else ok "the run file holds no text (${text}) [DND-1048]"; fi
done

# A 422 about one root is that case's; its fix is quoted.
ctx_respond '[{"status":422,"body":{"error":"unprocessable_entity","fix":"ts must be a Slack ts. Fix: send the root line'"'"'s ts unchanged."}},{"auto":"context"}]'
slr
has "a per-root 422 is unscored with the server's fix [DND-1048]" "${ERR}" "HTTP 422: ts must be a Slack ts. Fix: send the root line's ts unchanged."

# Several apps and no bot_id dooms every case: fatal, pointing at --bot-id.
ctx_respond '{"status":422,"body":{"error":"unprocessable_entity","fix":"the owner has more than one Slack app. Fix: pass bot_id."}}'
: > "${TMP}/server.log"
slr
eq "an ambiguous-app 422 exits 5 [DND-1048]" "${RC}" "5"
has "it names --bot-id as the fix [DND-1048]" "${ERR}" "Fix: re-run with --bot-id"
eq "it stops after the first context request [DND-1048]" "$(requests)" "1"

# A reply that does not match this harness stops the run: never a quiet empty context.
ctx_respond "{\"status\":200,\"body\":{\"context\":[],\"counts\":{},${GOOD_META/${OWNER_ID}/UFAKE00002}}}"
slr
eq "an owner id mismatch exits 5 [DND-1048]" "${RC}" "5"
has "it says the owner id differs, with a Fix [DND-1048]" "${ERR}" "the server's owner Slack user id differs from the private overlay's (neither is printed). Fix: "
lacks "the mismatch never prints the overlay's owner id [DND-1048 x DND-704]" "${ERR}" "${OWNER_ID}"
lacks "the mismatch never prints the server's owner id [DND-1048 x DND-704]" "${ERR}" "UFAKE00002"
ctx_respond "{\"status\":200,\"body\":{\"context\":[],\"counts\":{},${GOOD_META/slack-routing-v2/slack-routing-v3}}}"
slr
eq "a question-set version mismatch exits 5 [DND-1048]" "${RC}" "5"
has "it names both versions [DND-1048]" "${ERR}" "the server's question set is slack-routing-v3, this harness builds for slack-routing-v2"
ctx_respond '{"status":200,"body":{"context":[],"counts":{},"question_set_version":"slack-routing-v2","owner_slack_user_id":"'"${OWNER_ID}"'"}}'
slr
eq "a reply with no rules exits 5: could not check is never checked [DND-1048]" "${RC}" "5"

# Every context unavailable: nothing is judged.
ctx_respond '{"status":503,"body":{"error":"context_unavailable","fix":"Fix: check the database."}}'
: > "${TMP}/server.log"
slr
eq "every context unavailable exits 3 [DND-1048]" "${RC}" "3"
has "it says nothing was sent, with a Fix [DND-1048]" "${ERR}" "nothing was sent: every case's context was unavailable"
eq "no eval request is made [DND-1048]" "$(eval_requests | wc -l | tr -d ' ')" "0"

# A 404: no owner app, or no endpoint at all. Both doom every case, and they say which.
ctx_respond '{"status":404,"body":{"error":"not_found"}}'
slr
eq "a not_found 404 exits 5 [DND-1048]" "${RC}" "5"
has "the not_found 404 names the owner Slack user id, with a Fix [DND-1048]" "${ERR}" "owner Slack user id (and that bot id, if --bot-id was given) (HTTP 404). Fix: "
ctx_respond '{"status":404,"body":{}}'
slr
eq "a 404 from a server without the endpoint exits 5 [DND-1048]" "${RC}" "5"
has "it says the endpoint is missing [DND-1048]" "${ERR}" "the server has no slack_routing context endpoint (HTTP 404). Fix: deploy gen_saas with DND-1048"
rm -f "${TMP}/context.json"

# A labelled root the owner did not write is never sent (D7).
printf '{"id":"Ev-mr","label":"walt_ui","provenance":"owner_confirmed"}\n{"id":"Ev-r1","label":"harness","provenance":"owner_confirmed"}\n' > "${TMP}/labels-other.jsonl"
: > "${TMP}/server.log"
run --use-case slack_routing --labels "${TMP}/labels-other.jsonl" --corpus "${INBOX}/walt_ui-slack.jsonl" --content-domain work --pause 0 --inbox-root "${INBOX}"
has "a root someone else wrote is unscored, never sent (D7) [DND-1048]" "${ERR}" "the root is not the owner's x1): Ev-mr"
if grep -q OTHER-ROOT "${TMP}/server.log"; then bad "no request carries another person's root (D7) [DND-1048]"; else ok "no request carries another person's root (D7) [DND-1048]"; fi

# The inbox root: a missing one is an error, never an empty context.
run --use-case slack_routing --labels "${TMP}/labels-slr.jsonl" --corpus "${INBOX}/walt_ui-slack.jsonl" --content-domain work --inbox-root "${TMP}/no-inbox" --dry-run
eq "a missing inbox root is exit 1 [DND-1048]" "${RC}" "1"
has "a missing inbox root says so, with a Fix [DND-1048]" "${ERR}" "the inbox root ${TMP}/no-inbox does not exist. Fix: "
mkdir -p "${TMP}/empty-inbox"
run --use-case slack_routing --labels "${TMP}/labels-slr.jsonl" --corpus "${INBOX}/walt_ui-slack.jsonl" --content-domain work --inbox-root "${TMP}/empty-inbox" --dry-run
eq "an inbox root with no *-slack.jsonl is exit 1, never zero candidates [DND-1048]" "${RC}" "1"
has "it names the 0 files [DND-1048]" "${ERR}" "(0 files)"
ATHENA_INBOX_ROOT="${INBOX}" run --use-case slack_routing --labels "${TMP}/labels-slr.jsonl" --corpus "${INBOX}/walt_ui-slack.jsonl" --content-domain work --dry-run
eq "ATHENA_INBOX_ROOT is the default inbox root [DND-1048]" "${RC}" "0"
run --use-case finding_triage --labels "${TMP}/labels.jsonl" --corpus "${TMP}/corpus.jsonl" --content-domain blend --inbox-root "${INBOX}" --dry-run
eq "--inbox-root with another use case is usage (2) [DND-1048]" "${RC}" "2"
run --use-case finding_triage --labels "${TMP}/labels.jsonl" --corpus "${TMP}/corpus.jsonl" --content-domain blend --bot-id B0X --dry-run
eq "--bot-id with another use case is usage (2) [DND-1048]" "${RC}" "2"

echo "== slack_routing: an incomplete snapshot window is n/a, never scored (DND-1483)"

# A root snapshot corpus (judgment-label, DND-1448): Ev-r1's window was
# complete when snapshotted; Ev-r2's had partly rotated out of the inbox
# (window_complete false). Scoring Ev-r2 would read missing context as a
# router miss, so it is excluded, counted and named, and never sent.
SNAPCORPUS="${TMP}/snap-roots.jsonl"
{
  printf '{"channel":"D1","user":"%s","ts":"1790570000.000100","thread_ts":null,"text":"ROOT-ONE","kind":"im","event_id":"Ev-r1","snapshot":{"at":"2026-10-01T00:00:00Z","window_complete":true,"context_candidates":[]}}\n' "${OWNER_ID}"
  printf '{"channel":"D2","user":"%s","ts":"1790571000.000100","thread_ts":null,"text":"ROOT-TWO","kind":"mpim","event_id":"Ev-r2","snapshot":{"at":"2026-10-01T00:00:00Z","window_complete":false,"context_candidates":[]}}\n' "${OWNER_ID}"
  printf '{"channel":"D4","user":"%s","ts":"1790572000.000100","thread_ts":null,"text":"harness session: hi","kind":"im","event_id":"Ev-sm","snapshot":{"at":"2026-10-01T00:00:00Z","window_complete":true,"context_candidates":[]}}\n' "${OWNER_ID}"
} > "${SNAPCORPUS}"
snapr() { run --use-case slack_routing --labels "${TMP}/labels-slr.jsonl" --corpus "${SNAPCORPUS}" --content-domain work --pause 0 --inbox-root "${INBOX}" "$@"; }
rm -f "${TMP}/context.json"
respond '{"auto":"not_configured"}'
: > "${TMP}/server.log"
snapr --dry-run
eq "a dry run over an incomplete-window case exits 0 [DND-1483]" "${RC}" "0"
has "the dry run names the window-incomplete case as n/a [DND-1483]" "${OUT}" "window-incomplete excluded: 1 (n/a, not scored: the root's context window had partly rotated out of the inbox when it was snapshotted): Ev-r2"
has "the excluded case is not among the cases [DND-1483]" "${OUT}" "cases: 1 (harness 1)"
eq "the dry run makes no call [DND-1483]" "$(requests)" "0"

rm -rf "${XDG_DATA_HOME}/athena/evals/runs"
snapr
eq "the run still exits 3 with no key: the complete case was sent [DND-1483]" "${RC}" "3"
eq "no context is built for the excluded case [DND-1483]" "$(ctx_requests | jq -r .body.ts | tr '\n' ' ')" "1790570000.000100 "
eq "only the complete-window case is sent to the eval [DND-1483]" "$(eval_requests | jq -c '[.body.cases[].case_id]')" '["Ev-r1"]'
run_file="$(find "${XDG_DATA_HOME}/athena/evals/runs" -maxdepth 1 -type f | head -n 1)"
eq "the run file names the excluded case [DND-1483]" "$(jq -c .window_incomplete_excluded "${run_file}")" '["Ev-r2"]'
eq "the run file never records the excluded case as a result [DND-1483]" "$(jq -c '[.results[] | select(.case_id == "Ev-r2")] | length' "${run_file}")" "0"
eq "the run file counts only the snapshot cases kept; the excluded are named once [DND-1483]" "$(jq -c .context.snapshot "${run_file}")" '{"cases":1}'

# Every case incomplete: nothing is a measurement, nothing is sent.
printf '{"id":"Ev-r2","label":"walt_ui","provenance":"owner_confirmed"}\n' > "${TMP}/labels-incomplete.jsonl"
: > "${TMP}/server.log"
run --use-case slack_routing --labels "${TMP}/labels-incomplete.jsonl" --corpus "${SNAPCORPUS}" --content-domain work --pause 0 --inbox-root "${INBOX}"
eq "every case window-incomplete exits 3: nothing scored [DND-1483]" "${RC}" "3"
has "it says why nothing is a measurement, with a Fix [DND-1483]" "${ERR}" "every joined case the router would judge (1) had an incomplete context window, so none is a measurement and nothing was sent. Fix: "
eq "it makes no request [DND-1483]" "$(requests)" "0"
run --use-case slack_routing --labels "${TMP}/labels-incomplete.jsonl" --corpus "${SNAPCORPUS}" --content-domain work --inbox-root "${INBOX}" --dry-run
eq "every case window-incomplete exits 3 under --dry-run too [DND-1483]" "${RC}" "3"
eq "the dry run makes no request either [DND-1483]" "$(requests)" "0"

# A session-mention root beside a window-incomplete one: nothing is left to
# measure, which is exit 3 (nothing scored), not exit 1 (every joined label
# a session mention). Both exclusions are counted.
printf '{"id":"Ev-sm","label":"harness","provenance":"rule_confirmed"}\n{"id":"Ev-r2","label":"walt_ui","provenance":"owner_confirmed"}\n' > "${TMP}/labels-mixed.jsonl"
run --use-case slack_routing --labels "${TMP}/labels-mixed.jsonl" --corpus "${SNAPCORPUS}" --content-domain work --pause 0 --inbox-root "${INBOX}"
eq "session-mention plus window-incomplete, nothing left: exit 3, not 1 [DND-1483]" "${RC}" "3"
has "the session-mention root is counted [DND-1483]" "${OUT}" "session-mention excluded: 1"
has "the window-incomplete root is named [DND-1483]" "${OUT}" "window-incomplete excluded: 1 (n/a, not scored: the root's context window had partly rotated out of the inbox when it was snapshotted): Ev-r2"
eq "the mixed run makes no request [DND-1483]" "$(requests)" "0"

echo "== slack_routing: a legacy kind=dm root gets a context (DND-1567)"

# Roots received before HG-22 carry kind "dm". The fake server refuses any
# kind but im, mpim or mention with the real server's 422; the harness must
# map dm before it sends, or the case is unscored context_unavailable.
DMCORPUS="${TMP}/dm-roots.jsonl"
{
  printf '{"channel":"D1","user":"%s","ts":"1790570000.000100","thread_ts":null,"text":"ROOT-ONE","kind":"dm","event_id":"Ev-r1"}\n' "${OWNER_ID}"
  printf '{"channel":"GFAKE0002","user":"%s","ts":"1790571000.000100","thread_ts":null,"text":"ROOT-TWO","kind":"dm","event_id":"Ev-r2"}\n' "${OWNER_ID}"
} > "${DMCORPUS}"
rm -f "${TMP}/context.json"
respond '{"auto":"not_configured"}'
: > "${TMP}/server.log"
rm -rf "${XDG_DATA_HOME}/athena/evals/runs"
run --use-case slack_routing --labels "${TMP}/labels-slr.jsonl" --corpus "${DMCORPUS}" --content-domain work --pause 0 --inbox-root "${INBOX}"
eq "a run of legacy dm roots still exits 3 with no key: both were sent [DND-1567]" "${RC}" "3"
has "both legacy dm roots get a context [DND-1567]" "${OUT}" "context: built 2 of 2"
lacks "no legacy dm root is context_unavailable [DND-1567]" "${ERR}" "context_unavailable"
eq "the context requests carry im for the D channel and mpim for the other [DND-1567]" \
  "$(ctx_requests | jq -r .body.kind | tr '\n' ' ')" "im mpim "
eq "the eval cases carry the mapped kinds, never dm [DND-1567]" \
  "$(eval_requests | jq -c '[.body.cases[].input.kind]')" '["im","mpim"]'

echo "== slack_routing: the owner id comes from the private overlay (DND-1048 x DND-704)"

# Each failure is exit 1 (local configuration), carries the resolver's own
# Fix: line, makes no request at all, and never reads as "not the owner's"
# (which would leave every case context_unavailable, exit 3).
overlay_refused() { # overlay_refused NAME STATE -- after a run
  eq "${1} refuses slack_routing (exit 1)" "${RC}" "1"
  has "${1}: the refusal names the state ${2}" "${ERR}" "private-overlay: ${2}: key=slack.people.owner.user_id"
  has "${1}: the refusal carries Fix:" "${ERR}" "Fix: "
  eq "${1}: the refusal is one stderr line" "$(printf '%s\n' "${ERR}" | wc -l | tr -d ' ')" "1"
  lacks "${1}: it never reads as not the owner's" "${ERR}" "not the owner's"
  eq "${1}: no request is made" "$(requests)" "0"
}
respond '{"auto":"not_configured"}'
: > "${TMP}/server.log"
OUT="$(env -u ATHENA_PRIVATE_ROOT HOME="${NOHOME}" "${BIN}" --use-case slack_routing --labels "${TMP}/labels-slr.jsonl" --corpus "${INBOX}/walt_ui-slack.jsonl" --content-domain work --pause 0 --inbox-root "${INBOX}" 2>"${TMP}/err")"; RC=$?; ERR="$(cat "${TMP}/err")"
overlay_refused "an ABSENT overlay" "ABSENT"
has "an ABSENT overlay: the refusal names the probed path" "${ERR}" "${NOHOME}/.config/athena/work"
OUT="$(env -u ATHENA_PRIVATE_ROOT HOME="${NOHOME}" "${BIN}" --use-case slack_routing --labels "${TMP}/labels-slr.jsonl" --corpus "${INBOX}/walt_ui-slack.jsonl" --content-domain work --inbox-root "${INBOX}" --dry-run 2>"${TMP}/err")"; RC=$?; ERR="$(cat "${TMP}/err")"
overlay_refused "an ABSENT overlay under --dry-run" "ABSENT"
ATHENA_PRIVATE_ROOT="" slr
overlay_refused "a MALFORMED overlay root" "MALFORMED"
BADJSON="${TMP}/overlay-badjson"
overlay_root "${BADJSON}" '{"people": not json'
ATHENA_PRIVATE_ROOT="${BADJSON}" slr
overlay_refused "an overlay whose slack.json is not JSON" "MALFORMED"
NOKEY="${TMP}/overlay-nokey"
overlay_root "${NOKEY}" '{"people":{}}'
ATHENA_PRIVATE_ROOT="${NOKEY}" slr
overlay_refused "an overlay without the owner key" "KEY_NOT_FOUND"
NOTID="${TMP}/overlay-notid"
overlay_root "${NOTID}" '{"people":{"owner":{"user_id":"cody"}}}'
ATHENA_PRIVATE_ROOT="${NOTID}" slr
eq "an owner value that is not a Slack user id refuses (exit 1)" "${RC}" "1"
has "the malformed-value refusal says what is wrong" "${ERR}" "is not a Slack user id"
lacks "the malformed-value refusal never prints the value" "${ERR}" "cody"
has "the malformed-value refusal carries Fix:" "${ERR}" "Fix: "
eq "the malformed-value refusal makes no request" "$(requests)" "0"
# A well-formed owner id that is not the one the labels were made under (a
# stale overlay) matches no root. That is a wrong key, not "no root is the
# owner's": exit 1 naming the overlay key, before any request, not exit 3
# with every case context_unavailable (and the server's owner check, which
# would name it, is never reached).
STALE="${TMP}/overlay-stale"
overlay_root "${STALE}" '{"people":{"owner":{"user_id":"UFAKE00003"}}}'
: > "${TMP}/server.log"
ATHENA_PRIVATE_ROOT="${STALE}" slr
eq "an overlay owner id that matches no labelled root refuses (exit 1)" "${RC}" "1"
has "the no-owner-root refusal names the overlay key" "${ERR}" "slack .people.owner.user_id"
has "the no-owner-root refusal counts the roots considered" "${ERR}" "0 of 2 labelled root(s)"
has "the no-owner-root refusal carries Fix:" "${ERR}" "Fix: "
lacks "the no-owner-root refusal never prints the id" "${ERR}" "UFAKE00003"
eq "the no-owner-root refusal makes no request" "$(requests)" "0"
ATHENA_PRIVATE_ROOT="${STALE}" slr --dry-run
eq "the no-owner-root refusal holds under --dry-run (exit 1)" "${RC}" "1"
OUT="$(env -u ATHENA_PRIVATE_ROOT HOME="${NOHOME}" "${BIN}" --use-case finding_triage --labels "${TMP}/labels.jsonl" --corpus "${TMP}/corpus.jsonl" --content-domain blend --dry-run 2>"${TMP}/err")"; RC=$?; ERR="$(cat "${TMP}/err")"
eq "another use case needs no overlay (--dry-run exits 0)" "${RC}" "0"
lacks "another use case never reads the overlay" "${ERR}" "private-overlay"

# ---------------------------------------------------------------------------
echo "== candidate question-set version [DND-1608]"

LAST_BODY() { tail -n 1 "${TMP}/server.log" | jq -c '.body'; }

respond '{"auto":"not_configured"}'
: > "${TMP}/server.log"
run --use-case finding_triage --labels "${TMP}/labels.jsonl" --corpus "${TMP}/corpus.jsonl" --content-domain blend --pause 0
eq "no --question-set-version: the body carries no question_set_version (old server shape unchanged)" \
  "$(tail -n 1 "${TMP}/server.log" | jq -c '.body | has("question_set_version")')" "false"

: > "${TMP}/server.log"
run --use-case finding_triage --labels "${TMP}/labels.jsonl" --corpus "${TMP}/corpus.jsonl" --content-domain blend --pause 0 --question-set-version test-v2
eq "a candidate eval sends question_set_version in every batch body" \
  "$(tail -n 1 "${TMP}/server.log" | jq -r '.body.question_set_version')" "test-v2"
has "a candidate eval names the candidate it scored" "${OUT}" "question set test-v2"
respond '{"status":200,"body":{"data":{"eval_run_id":"11111111-1111-4111-8111-111111111111","use_case":"finding_triage","question_set_version":"test-v2","model":"jev-1.13.0","results":[{"case_id":"c1","outcome":"scored","predicted":"duplicate","confidence":0.9}],"report":{"cases":1,"scored":1,"unscored":{},"labels":[]}}}}'
run --use-case finding_triage --labels "${TMP}/labels.jsonl" --corpus "${TMP}/corpus.jsonl" --content-domain blend --pause 0 --question-set-version test-v2
eq "a scored candidate eval exits 0" "${RC}" "0"
has "a candidate eval says it is a candidate and will not apply" "${OUT}" "candidate run"
lacks "a candidate eval prints no apply line" "${OUT}" "apply with"
RUNFILE="$(printf '%s\n' "${OUT}" | sed -n 's/^run file: //p')"
eq "the run file records the candidate" "$(jq -r '.candidate' "${RUNFILE}")" "true"

# A server that ignores the key answers its deployed version: the eval must
# stop, never present that as the candidate's number.
respond '{"status":200,"body":{"data":{"eval_run_id":"11111111-1111-4111-8111-111111111111","use_case":"finding_triage","question_set_version":"v1","model":"jev-1.13.0","results":[{"case_id":"c1","outcome":"scored","predicted":"duplicate","confidence":0.9}],"report":{"cases":1,"scored":1,"unscored":{},"labels":[]}}}}'
run --use-case finding_triage --labels "${TMP}/labels.jsonl" --corpus "${TMP}/corpus.jsonl" --content-domain blend --pause 0 --question-set-version test-v2
eq "a server answering another version than the candidate stops (exit 5)" "${RC}" "5"
has "the version mismatch names both versions" "${ERR}" "test-v2"
has "the version mismatch names the answered version" "${ERR}" "v1"
has "the version mismatch carries Fix:" "${ERR}" "Fix: "

# An old server's closed schema refuses the unknown key: surfaced, never dropped.
respond '{"status":422,"body":{"error":"unprocessable_entity","fix":"the body has unlisted keys question_set_version. Fix: send only use_case, eval_run_id, content_domain, cases."}}'
run --use-case finding_triage --labels "${TMP}/labels.jsonl" --corpus "${TMP}/corpus.jsonl" --content-domain blend --pause 0 --question-set-version test-v2
eq "an old server refusing the key is exit 5, no fallback to the deployed set" "${RC}" "5"
has "the refusal prints the server's Fix:" "${ERR}" "unlisted keys question_set_version"

# A server refusing a candidate it cannot load (the new shape).
respond '{"status":422,"body":{"error":"unprocessable_entity","fix":"finding_triage has no question set version test-v9 on this server. Fix: ship the candidate."}}'
run --use-case finding_triage --labels "${TMP}/labels.jsonl" --corpus "${TMP}/corpus.jsonl" --content-domain blend --pause 0 --question-set-version test-v9
eq "a candidate the server cannot load is exit 5" "${RC}" "5"
has "the unloadable-candidate refusal names it" "${ERR}" "test-v9"
respond '{"auto":"not_configured"}'

run --use-case finding_triage --labels "${TMP}/labels.jsonl" --corpus "${TMP}/corpus.jsonl" --content-domain blend --question-set-version 'bad version'
eq "a malformed --question-set-version is usage (2)" "${RC}" "2"
has "the malformed-version usage error carries Fix:" "${ERR}" "Fix: "
run --apply 11111111-1111-4111-8111-111111111111 --question-set-version test-v2 --dry-run
eq "--apply refuses --question-set-version (usage 2)" "${RC}" "2"

# ---------------------------------------------------------------------------
printf '\n%d passed, %d failed\n' "${PASS}" "${FAIL}"
if [ "${FAIL}" -ne 0 ]; then
  echo "judgment-eval self-test: FAILED"
  echo "  Fix: make ai/bin/judgment-eval and ai/lib/judgment_eval.rb satisfy the failing cases above (contract: ai/contracts/athena-judgments.md -> Threshold provenance, n/a and the pinned model)."
  exit 1
fi
echo "judgment-eval self-test: OK"
exit 0
