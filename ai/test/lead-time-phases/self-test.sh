#!/usr/bin/env bash
# self-test.sh -- the lead-time-phases suite (DND-1477). Discovered by
# harness-gate (every committed `self-test.sh` runs).
#
# Layers, in TDD order:
#   1. the domain and IO suites (phases_test.rb, io_test.rb), run through
#      `lead-time-phases --self-test` so its self-test path is exercised;
#   2. the CLI end to end, against a temp state dir (LEAD_TIME_STATE_DIR), a
#      temp config (LEAD_TIME_PHASES_CONFIG), a temp telemetry store, a temp
#      git repo, and a FAKE ai/bin/lead-time (LEAD_TIME_PHASES_LEAD_TIME) that
#      prints canned rows and meta. No network, no Notion, no real state.
# Functional only (DND-1222): no sleeps, no timing, no load. Ids are synthetic.

set -u

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT="$(cd -- "${HERE}/../../.." && pwd -P)"
BIN="${ROOT}/ai/bin/lead-time-phases"

PASS=0
FAIL=0
ok()    { PASS=$((PASS + 1)); printf 'ok   %s\n' "$1"; }
bad()   { FAIL=$((FAIL + 1)); printf 'FAIL %s\n' "$1"; [ -n "${2:-}" ] && printf '     %s\n' "$2"; return 0; }
eq()    { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$3], got [$2]"; fi; }
has()   { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "no [$3] in: $2" ;; esac; }
lacks() { case "$2" in *"$3"*) bad "$1" "unexpected [$3] in: $2" ;; *) ok "$1" ;; esac; }

[ -x /usr/bin/ruby ] || { echo "lead-time-phases self-test: FAIL -- /usr/bin/ruby is missing"; echo "  Fix: install the harness Ruby at /usr/bin/ruby (DND-931); this suite does not skip."; exit 1; }
[ -x "${BIN}" ] || { echo "lead-time-phases self-test: FAIL -- ${BIN} missing or not executable"; echo "  Fix: chmod +x ai/bin/lead-time-phases"; exit 1; }

TMP="$(mktemp -d)" || { echo "FAIL mktemp"; echo "  Fix: free space in TMPDIR"; exit 1; }
cleanup() { rm -rf "${TMP}"; }
trap cleanup EXIT INT TERM

echo "== domain + io"
if /usr/bin/ruby "${BIN}" --self-test >"${TMP}/lib.out" 2>&1; then
  ok "lead-time-phases --self-test: $(tail -1 "${TMP}/lib.out")"
else
  bad "lead-time-phases --self-test" "$(cat "${TMP}/lib.out")"
fi

# ── fixtures ────────────────────────────────────────────────────────────────
HEAD_PUSH="$(printf 'a%.0s' $(seq 40))"
HEAD_PR="$(printf 'b%.0s' $(seq 40))"
HEAD_BARE="$(printf 'c%.0s' $(seq 40))"

REPO="${TMP}/repo"
GENV=(env GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1)
"${GENV[@]}" git init -q -b main "${REPO}" || { echo "FAIL git init"; echo "  Fix: install git"; exit 1; }
mkdir -p "${REPO}/.git/integration-receipts"
printf '{"recorded_at":"2026-10-01T04:30:00Z","head":"%s"}\n' "${HEAD_PUSH}" >"${REPO}/.git/integration-receipts/${HEAD_PUSH}.json"

WATCH="${TMP}/watchrepo"
mkdir -p "${WATCH}"

CONFIG="${TMP}/repos.json"
cat >"${CONFIG}" <<JSON
{
  "repos": [
    { "name": "custom", "path": "${REPO}", "mode": "improve" },
    { "name": "gen_saas", "path": "${WATCH}", "mode": "watch" },
    { "name": "walt_ui", "path": "${TMP}/not-here", "mode": "watch" }
  ],
  "window": 20,
  "improvement_epic": "epic-id"
}
JSON

# The fake lead-time: prints FAKE_ROWS, writes FAKE_META to --meta, records
# its argv in FAKE_ARGS, exits FAKE_EXIT.
FAKE="${TMP}/fake-lead-time"
cat >"${FAKE}" <<'RUBY'
#!/usr/bin/ruby
File.write(ENV.fetch("FAKE_ARGS"), ARGV.join(" "))
meta = ARGV[ARGV.index("--meta") + 1]
File.write(meta, File.read(ENV.fetch("FAKE_META")))
print File.read(ENV.fetch("FAKE_ROWS"))
warn "lead-time: SCAN INCOMPLETE (fake)" if ENV["FAKE_EXIT"] == "3"
exit Integer(ENV.fetch("FAKE_EXIT", "0"))
RUBY
chmod +x "${FAKE}"

# A direct-push landing with a ticket, a PR row (no ticket key; the branch
# names one), and an unticketed push.
cat >"${TMP}/rows.json" <<JSON
[
  {"pr": null, "ticket": "DND-9001", "landed_via": "push", "landed_commit": "${HEAD_PUSH}",
   "commits": ["${HEAD_PUSH}"], "merged": "2026-10-01T05:00:00Z", "closed_at": "2026-10-01T05:00:00Z",
   "start": "2026-10-01T01:00:00Z", "lead_seconds": 14400, "code_seconds": 14400, "tail_seconds": 0,
   "unmeasured_reason": null},
  {"pr": 41, "title": "a change", "branch": "dnd-9002-a-change", "landed_via": "merge",
   "landed_commit": null, "merge_commit": "${HEAD_PR}", "merged": "2026-10-01T06:00:00Z",
   "closed_at": "2026-10-01T06:00:00Z", "start": "2026-10-01T02:00:00Z", "lead_seconds": 14400,
   "code_seconds": 14400, "tail_seconds": 0, "unmeasured_reason": null},
  {"pr": null, "ticket": null, "landed_via": "push", "landed_commit": "${HEAD_BARE}",
   "commits": ["${HEAD_BARE}"], "merged": "2026-10-01T07:00:00Z", "closed_at": "2026-10-01T07:00:00Z",
   "start": null, "lead_seconds": null, "code_seconds": null, "tail_seconds": null,
   "unmeasured_reason": "start: no ticket in the pushed commits' subjects"}
]
JSON
printf '{"scanned_through":"2026-10-01T07:00:00Z","landings":3,"kept":3,"incomplete":false}\n' >"${TMP}/meta-ok.json"
printf '{"scanned_through":"2026-10-01T05:00:00Z","landings":1,"kept":1,"incomplete":true}\n' >"${TMP}/meta-incomplete.json"
printf '{"scanned_through":"2026-10-01T09:00:00Z","landings":0,"kept":0,"incomplete":false}\n' >"${TMP}/meta-kept0.json"
printf '[]\n' >"${TMP}/rows-empty.json"

STATE="${TMP}/state"
TEL_NONE="${TMP}/no-telemetry"
TEL_EMPTY="${TMP}/telemetry"
mkdir -p "${TEL_EMPTY}" && chmod 700 "${TEL_EMPTY}"

OUT=""; ERR=""; CODE=0
# run TELEMETRY_DIR ARGS... -- the CLI against the fixtures.
run() {
  local tel="$1"; shift
  OUT="$(cd "${TMP}" && LEAD_TIME_STATE_DIR="${STATE}" LEAD_TIME_PHASES_CONFIG="${CONFIG}" \
        LEAD_TIME_PHASES_LEAD_TIME="${FAKE}" LEAD_TIME_PHASES_NOW="2026-10-15T00:00:00Z" \
        ATHENA_TELEMETRY_DIR="${tel}" XDG_STATE_HOME="${TMP}/xdg" \
        FAKE_ROWS="${ROWS:-${TMP}/rows.json}" FAKE_META="${META:-${TMP}/meta-ok.json}" \
        FAKE_EXIT="${FEXIT:-0}" FAKE_ARGS="${TMP}/args" \
        /usr/bin/ruby "${BIN}" "$@" 2>"${TMP}/err" </dev/null)"
  CODE=$?
  ERR="$(cat "${TMP}/err")"
}
ledger_lines() { if [ -f "${STATE}/ledger.jsonl" ]; then wc -l <"${STATE}/ledger.jsonl" | tr -d ' '; else echo 0; fi; }
row_field() { /usr/bin/ruby -rjson -e 'r = File.readlines(ARGV[0]).map { |l| JSON.parse(l) }.find { |x| x["landed_commit"] == ARGV[1] }; v = r && r.dig(*ARGV[2].split(".")); puts(v.nil? ? "null" : v)' "${STATE}/ledger.jsonl" "$1" "$2"; }

echo "== --help"
run "${TEL_NONE}" --help
eq "--help exits 0" "${CODE}" "0"
has "--help is on stdout" "${OUT}" "Usage:"
[ -e "${STATE}" ] && bad "--help writes no state" "${STATE} exists" || ok "--help writes no state"

echo "== usage and config refusals"
run "${TEL_NONE}" --summary --repo nope
eq "--repo nope exits 2" "${CODE}" "2"
has "--repo nope says Fix:" "${ERR}" "Fix:"
has "--repo nope names the configured repos" "${ERR}" "custom, gen_saas, walt_ui"
run "${TEL_NONE}" --ingest --summary --repo custom
eq "both modes is refused" "${CODE}" "2"
run "${TEL_NONE}" --summary --repo custom --since 2026-10-01
eq "--since without --ingest is refused" "${CODE}" "2"
run "${TEL_NONE}" --ingest --repo custom --bogus
eq "an unknown flag is refused" "${CODE}" "2"
printf '{"repos":[{"name":"x","path":"/x","mode":"fix"}],"window":20,"improvement_epic":"e"}\n' >"${TMP}/bad.json"
OUT="$(LEAD_TIME_STATE_DIR="${STATE}" LEAD_TIME_PHASES_CONFIG="${TMP}/bad.json" /usr/bin/ruby "${BIN}" --summary --repo x 2>&1)"; CODE=$?
eq "an unknown mode in the config exits 2" "${CODE}" "2"
has "the refusal names the repo and carries Fix:" "${OUT}" '"x" has unknown mode'
[ -e "${STATE}" ] && bad "a refusal writes no state" "${STATE} exists" || ok "a refusal writes no state"

echo "== ingest: the direct-push regression"
run "${TEL_EMPTY}" --ingest --repo custom
eq "ingest exits 0" "${CODE}" "0"
has "a missing cursor backfills 14 days" "$(cat "${TMP}/args")" "--since 2026-10-01T00:00:00Z"
has "lead-time is asked for --json and --meta" "$(cat "${TMP}/args")" "--json --meta"
eq "three landings are in the ledger" "$(ledger_lines)" "3"
eq "the direct-push landing (via=push, no PR) is ingested" "$(row_field "${HEAD_PUSH}" landed_via)" "push"
eq "the push row keeps its ticket" "$(row_field "${HEAD_PUSH}" ticket)" "DND-9001"
eq "the PR row's ticket comes from its branch" "$(row_field "${HEAD_PR}" ticket)" "DND-9002"
eq "the unticketed push is ingested with no ticket" "$(row_field "${HEAD_BARE}" ticket)" "null"
eq "the cursor advances to scanned_through" "$(cat "${STATE}/cursor.custom.txt")" "2026-10-01T07:00:00Z"
# With no emitter events yet, real phases read n/a, never 0 (build plan step 6).
eq "implement is null before the gate emitter lands" "$(row_field "${HEAD_PUSH}" phases.implement.s)" "null"
eq "the reason names the unit" "$(row_field "${HEAD_PUSH}" phases.implement.na_reason)" "no harness_gate.run for DND-9001"
eq "merge is measured from the integration receipt" "$(row_field "${HEAD_PUSH}" phases.merge.s)" "1800"
eq "gate_runs is null, not 0" "$(row_field "${HEAD_PUSH}" counters.gate_runs)" "null"
eq "the unticketed row's verify reads unticketed" "$(row_field "${HEAD_BARE}" phases.verify.na_reason)" "unticketed landing: no unit to join gate runs on"

echo "== ingest: at-least-once delivery is idempotent"
run "${TEL_EMPTY}" --ingest --repo custom
eq "a re-ingest exits 0" "${CODE}" "0"
has "the re-listed scan resumes from the cursor" "$(cat "${TMP}/args")" "--since 2026-10-01T07:00:00Z"
eq "the same landings are not duplicated" "$(ledger_lines)" "3"
has "it says they were already there" "${OUT}" "0 new in the ledger, 3 already there"

echo "== ingest: SCAN INCOMPLETE never moves the cursor"
META="${TMP}/meta-incomplete.json" run "${TEL_EMPTY}" --ingest --repo custom --since 2026-09-01
eq "meta incomplete exits 3" "${CODE}" "3"
has "stderr says SCAN INCOMPLETE" "${ERR}" "SCAN INCOMPLETE"
has "SCAN INCOMPLETE carries Fix:" "${ERR}" "Fix:"
eq "the cursor is unchanged" "$(cat "${STATE}/cursor.custom.txt")" "2026-10-01T07:00:00Z"
eq "nothing is ingested" "$(ledger_lines)" "3"
FEXIT=3 ROWS="${TMP}/rows-empty.json" run "${TEL_EMPTY}" --ingest --repo custom
eq "lead-time exit 3 exits 3" "${CODE}" "3"
eq "the cursor is unchanged after exit 3" "$(cat "${STATE}/cursor.custom.txt")" "2026-10-01T07:00:00Z"

echo "== ingest: an empty window still moves the cursor"
META="${TMP}/meta-kept0.json" ROWS="${TMP}/rows-empty.json" run "${TEL_EMPTY}" --ingest --repo custom
eq "kept=0 exits 0" "${CODE}" "0"
eq "the cursor advances to scanned_through" "$(cat "${STATE}/cursor.custom.txt")" "2026-10-01T09:00:00Z"

echo "== ingest: a broken cursor is an error, not a backfill"
cp "${STATE}/cursor.custom.txt" "${TMP}/cursor.bak"
printf 'yesterday\n' >"${STATE}/cursor.custom.txt"
run "${TEL_EMPTY}" --ingest --repo custom
eq "a malformed cursor exits 1" "${CODE}" "1"
has "it names the cursor and carries Fix:" "${ERR}" "Fix:"
cp "${TMP}/cursor.bak" "${STATE}/cursor.custom.txt"

echo "== ingest: a repo not on this machine"
run "${TEL_EMPTY}" --ingest --repo walt_ui
eq "not on this machine exits 0" "${CODE}" "0"
has "it says so, never a silent skip" "${OUT}" "not on this machine"

echo "== summary: telemetry could not look vs looked and found nothing"
run "${TEL_NONE}" --summary --repo custom
eq "summary exits 0" "${CODE}" "0"
has "no store reads could not look" "${OUT}" "telemetry: could not look"
has "the biggest contributor is the only measured phase" "${OUT}" "biggest contributor: merge"
has "no store: write-failures are unknown, never 0" "${OUT}" "write-failures unknown"
lacks "no store: no event count is claimed" "${OUT}" "phase event(s) in the window"
run "${TEL_EMPTY}" --summary --repo custom
has "an empty store reads ok" "${OUT}" "telemetry: ok"
lacks "an empty store never reads could not look" "${OUT}" "could not look (no telemetry store"
run "${TEL_NONE}" --summary --repo custom --json
JSON_STATUS="$(printf '%s' "${OUT}" | /usr/bin/ruby -rjson -e 'puts JSON.parse($stdin.read).dig("telemetry", "status")')"
eq "--json carries the telemetry status" "${JSON_STATUS}" "could not look"
JSON_N="$(printf '%s' "${OUT}" | /usr/bin/ruby -rjson -e 'j = JSON.parse($stdin.read); puts [j["rows"], j.dig("phases", "merge", "n"), j.dig("phases", "implement", "n_na")].join(",")')"
eq "--json: 3 rows, merge measured once, implement n/a on all" "${JSON_N}" "3,1,3"

echo "== summary: a watch repo"
run "${TEL_EMPTY}" --ingest --repo gen_saas
eq "a watch repo ingests" "${CODE}" "0"
run "${TEL_EMPTY}" --summary --repo gen_saas
has "a watch summary shows code" "${OUT}" "code"
has "a watch summary shows tail" "${OUT}" "tail"
has "it states phases are n/a by design" "${OUT}" "phases: n/a by design (watch mode)"
lacks "it prints no phase rows" "${OUT}" "implement"

echo "== summary: no ledger is not an empty ledger"
STATE="${TMP}/state-none" run "${TEL_EMPTY}" --summary --repo custom
has "no ledger is named as such" "${OUT}" "no ledger at"

echo
echo "lead-time-phases self-test: ${PASS} passed, ${FAIL} failed"
if [ "${FAIL}" -ne 0 ]; then
  echo "Fix: read the FAIL lines above; the suite pins ai/bin/lead-time-phases (DND-1477)."
  exit 1
fi
exit 0
