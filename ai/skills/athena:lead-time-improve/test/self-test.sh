#!/usr/bin/env bash
# self-test.sh -- the athena:lead-time-improve suite (DND-1478). Discovered by
# harness-gate (every committed `self-test.sh` runs).
#
# Layers, in TDD order:
#   1. the domain and store suite (experiment_test.rb);
#   2. scripts/experiment end to end, against a temp state dir
#      (LEAD_TIME_STATE_DIR), a temp config (LEAD_TIME_PHASES_CONFIG), a
#      fixture ledger (make_ledger.rb), a temp git repo for the reverts guard,
#      and an injected now (LEAD_TIME_EXPERIMENT_NOW). No network, no real state.
# Functional only (DND-1222): no sleeps, no timing, no load. Ids are synthetic.

set -u

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
BIN="${HERE}/../scripts/experiment"

PASS=0
FAIL=0
ok()    { PASS=$((PASS + 1)); printf 'ok   %s\n' "$1"; }
bad()   { FAIL=$((FAIL + 1)); printf 'FAIL %s\n' "$1"; [ -n "${2:-}" ] && printf '     %s\n' "$2"; return 0; }
eq()    { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$3], got [$2]"; fi; }
has()   { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "no [$3] in: $2" ;; esac; }
lacks() { case "$2" in *"$3"*) bad "$1" "unexpected [$3] in: $2" ;; *) ok "$1" ;; esac; }

[ -x /usr/bin/ruby ] || { echo "lead-time-improve self-test: FAIL -- /usr/bin/ruby is missing"; echo "  Fix: install the harness Ruby at /usr/bin/ruby (DND-931); this suite does not skip."; exit 1; }
[ -x "${BIN}" ] || { echo "lead-time-improve self-test: FAIL -- ${BIN} missing or not executable"; echo "  Fix: chmod +x ai/skills/athena:lead-time-improve/scripts/experiment"; exit 1; }

TMP="$(mktemp -d)" || { echo "FAIL mktemp"; echo "  Fix: free space in TMPDIR"; exit 1; }
cleanup() { rm -rf "${TMP}"; }
trap cleanup EXIT INT TERM

echo "== domain + store"
if /usr/bin/ruby "${HERE}/experiment_test.rb" >"${TMP}/lib.out" 2>&1; then
  ok "experiment_test.rb: $(tail -1 "${TMP}/lib.out")"
else
  bad "experiment_test.rb" "$(cat "${TMP}/lib.out")"
fi

# ── fixtures ────────────────────────────────────────────────────────────────
LANDING="$(printf 'e%.0s' $(seq 40))"
OTHER="$(printf 'f%.0s' $(seq 40))"

REPO="${TMP}/repo"
GENV=(env GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid
      GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid)
"${GENV[@]}" git init -q -b main "${REPO}" || { echo "FAIL git init"; echo "  Fix: install git"; exit 1; }
"${GENV[@]}" git -C "${REPO}" commit -q --allow-empty -m "fixture: initial" || { echo "FAIL git commit"; echo "  Fix: install git"; exit 1; }

CONFIG="${TMP}/repos.json"
printf '%s\n' "{\"repos\":[{\"name\":\"custom\",\"path\":\"${REPO}\",\"mode\":\"improve\"},{\"name\":\"gen_saas\",\"path\":\"${TMP}/w\",\"mode\":\"watch\"}],\"window\":20,\"improvement_epic\":\"epic-id\"}" >"${CONFIG}"

STATE="${TMP}/state"
mkdir -p "${STATE}"
HYP="${TMP}/hypothesis.txt"
printf 'Caching the gate fixture should cut verify by a fifth.\n' >"${HYP}"

export LEAD_TIME_STATE_DIR="${STATE}" LEAD_TIME_PHASES_CONFIG="${CONFIG}" LEAD_TIME_EXPERIMENT_NOW="2026-09-21T12:00:00Z"

run() { "${BIN}" "$@" >"${TMP}/out" 2>"${TMP}/err"; echo $?; }
out() { cat "${TMP}/out"; }
err() { cat "${TMP}/err"; }
rec() { run record --repo custom --phase "$1" --metric "$2" --commit "$3" --kind "$4" --hypothesis-file "${HYP}"; }

# ── --help ──────────────────────────────────────────────────────────────────
echo "== --help"
eq "--help exits 0" "$(run --help)" "0"
has "--help prints usage on stdout" "$(out)" "experiment record --repo R"
eq "--help writes nothing to the state dir" "$(find "${STATE}" -mindepth 1 | wc -l)" "0"
eq "--help after a subcommand also exits 0 and runs nothing" "$(run judge --repo custom --help)" "0"
eq "... and still writes nothing" "$(find "${STATE}" -mindepth 1 | wc -l)" "0"

# ── usage refusals ──────────────────────────────────────────────────────────
echo "== usage"
eq "no subcommand: exit 2" "$(run)" "2"
has "no subcommand: Fix:" "$(err)" "Fix:"
eq "an unknown flag: exit 2" "$(run judge --repo custom --rpeo x)" "2"
has "an unknown flag is named" "$(err)" "--rpeo"
eq "a watch repo is refused: exit 2" "$(run judge --repo gen_saas)" "2"
has "the refusal says improve only, with Fix:" "$(err)" "improve repos only"
eq "a short SHA is refused: exit 2" "$(rec verify phase abc123 change)" "2"
has "... naming the 40-hex rule" "$(err)" "40-hex"
eq "instrumentation with a duration metric is refused" "$(rec implement phase "${LANDING}" instrumentation)" "2"
has "... naming na_share" "$(err)" "na_share"
eq "an unknown metric is refused" "$(rec verify speed "${LANDING}" change)" "2"

# ── missing ledger: could not look (exit 3), never "0 landings" ─────────────
echo "== missing ledger"
eq "judge with no ledger: exit 3" "$(run judge --repo custom)" "3"
has "judge says could not look" "$(err)" "could not look"
has "judge's Fix: names the ingest" "$(err)" "lead-time-phases --ingest"
lacks "judge never reads it as 0 landings" "$(out)$(err)" "0 landing"
eq "record with no ledger: exit 3" "$(rec verify phase "${LANDING}" change)" "3"
eq "record with no ledger wrote no experiment" "$(test -s "${STATE}/experiments.jsonl" && echo yes || echo no)" "no"

# ── empty ledger: looked, 0 landings ────────────────────────────────────────
echo "== empty ledger"
: >"${STATE}/ledger.jsonl"
eq "judge on an empty ledger and no experiments: exit 0" "$(run judge --repo custom)" "0"
has "it says none recorded yet" "$(out)" "none recorded yet"
has "and 0 landings" "$(out)" "0 landing(s) in the ledger"
eq "list with no experiments file: exit 0" "$(run list)" "0"
has "list says none recorded yet" "$(out)" "none recorded yet"

# ── record then list ────────────────────────────────────────────────────────
echo "== record + list"
/usr/bin/ruby "${HERE}/make_ledger.rb" "${STATE}/ledger.jsonl" "${LANDING}" || bad "make_ledger.rb"
eq "record a change on verify: exit 0" "$(rec verify phase "${LANDING}" change)" "0"
has "record prints the baseline from the fixture ledger" "$(out)" "baseline n=10 median=600s p90=600s"
eq "list: exit 0" "$(run list --repo custom)" "0"
has "list shows one PENDING experiment" "$(out)" "custom:verify:eeeeeeeeeeee PENDING kind=change metric=phase"
has "list shows its baseline numbers" "$(out)" "baseline n=10 median=600s p90=600s"
has "list counts it" "$(out)" "1 experiment(s) for custom of 1 recorded"

# ── record refused: a second change on the same phase ───────────────────────
echo "== record refused"
eq "a second change on verify: exit 2" "$(rec verify phase "${OTHER}" change)" "2"
has "the refusal names the pending experiment" "$(err)" "custom:verify:eeeeeeeeeeee"
has "the refusal carries Fix:" "$(err)" "Fix:"
eq "the refused record was not written" "$(grep -c '"type":"record"' "${STATE}/experiments.jsonl")" "1"
eq "the same id twice is refused: exit 2" "$(rec verify phase "${LANDING}" change)" "2"
has "... as already recorded" "$(err)" "already recorded"
eq "instrumentation on the same landing, implement: admitted" "$(rec implement na_share "${LANDING}" instrumentation)" "0"
has "its baseline is the n/a share" "$(out)" "n/a share=1.0"

# ── judge ───────────────────────────────────────────────────────────────────
echo "== judge"
eq "judge: exit 0" "$(run judge --repo custom)" "0"
J="$(out)"
has "judge keeps the verify change (600 -> 500)" "${J}" "custom:verify:eeeeeeeeeeee KEEP"
has "judge prints before and after numbers" "${J}" "before n=10 median=600s p90=600s | after n=10 median=500s p90=500s"
has "judge prints the guards, measured" "${J}" "critic_block_rate 0.0->0.0 ok"
has "the reverts guard read git" "${J}" "reverts 0->0 ok"
has "judge keeps the instrumentation (share 1.0 -> 0.0)" "${J}" "custom:implement:eeeeeeeeeeee KEEP"
has "judge sums up" "${J}" "2 pending judged (0 pending, 2 keep, 0 revert, 0 inconclusive); 2 status row(s) appended"
eq "two status rows were appended" "$(grep -c '"type":"status"' "${STATE}/experiments.jsonl")" "2"
eq "re-judge with the same now: exit 0" "$(run judge --repo custom)" "0"
has "a keep is terminal: nothing pending is judged again" "$(out)" "0 pending judged"
eq "no duplicate status rows" "$(grep -c '"type":"status"' "${STATE}/experiments.jsonl")" "2"
eq "list after judge" "$(run list)" "0"
has "list shows the latest status" "$(out)" "custom:verify:eeeeeeeeeeee KEEP"

# ── judge idempotent on a still-pending row ─────────────────────────────────
echo "== pending idempotence"
NEWSHA="$(printf '1%.0s' $(seq 40))"
eq "record a change on merge whose landing is not ledgered yet" "$(rec merge phase "${NEWSHA}" change)" "0"
eq "judge: exit 0" "$(run judge --repo custom)" "0"
has "the unlanded experiment is PENDING with its reason" "$(out)" "custom:merge:111111111111 PENDING"
has "... not in the ledger yet" "$(out)" "not in the ledger yet"
N1="$(grep -c '"type":"status"' "${STATE}/experiments.jsonl")"
eq "re-judge with the same now" "$(run judge --repo custom)" "0"
has "re-judge appends nothing" "$(out)" "0 status row(s) appended"
eq "the status row count is unchanged" "$(grep -c '"type":"status"' "${STATE}/experiments.jsonl")" "${N1}"
eq "eight days later: judge exits 0" "$(LEAD_TIME_EXPERIMENT_NOW=2026-09-29T13:00:00Z run judge --repo custom)" "0"
has "an unlanded experiment past day 7 is INCONCLUSIVE" "$(out)" "custom:merge:111111111111 INCONCLUSIVE"

# ── reverts guard: could not look is unmeasured, never 0 ────────────────────
echo "== reverts could not look"
printf '%s\n' "{\"repos\":[{\"name\":\"custom\",\"path\":\"${TMP}/gone\",\"mode\":\"improve\"}],\"window\":20,\"improvement_epic\":\"epic-id\"}" >"${TMP}/gone.json"
STATE2="${TMP}/state2"
mkdir -p "${STATE2}"
/usr/bin/ruby "${HERE}/make_ledger.rb" "${STATE2}/ledger.jsonl" "${LANDING}"
eq "record with the repo absent" "$(LEAD_TIME_STATE_DIR="${STATE2}" LEAD_TIME_PHASES_CONFIG="${TMP}/gone.json" run record --repo custom --phase verify --metric phase --commit "${LANDING}" --kind change --hypothesis-file "${HYP}")" "0"
eq "judge with the repo absent: exit 0" "$(LEAD_TIME_STATE_DIR="${STATE2}" LEAD_TIME_PHASES_CONFIG="${TMP}/gone.json" run judge --repo custom)" "0"
has "no keep while reverts could not be read" "$(out)" "custom:verify:eeeeeeeeeeee PENDING"
has "... and it says the guard is unmeasured" "$(out)" "reverts unmeasured"

echo
echo "lead-time-improve self-test: ${PASS} passed, ${FAIL} failed"
[ "${FAIL}" -eq 0 ] || { echo "Fix: read the FAIL lines above; each names the case and what it expected."; exit 1; }
exit 0
