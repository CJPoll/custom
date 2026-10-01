#!/usr/bin/env bash
# self-test.sh -- the athena:lead-time-improve suite (DND-1478). Discovered by
# harness-gate (every committed `self-test.sh` runs).
#
# Layers, in TDD order:
#   1. the domain and store suite (experiment_test.rb);
#   2. scripts/experiment end to end, against temp state dirs
#      (LEAD_TIME_STATE_DIR), a temp config (LEAD_TIME_PHASES_CONFIG), fixture
#      ledgers (make_ledger.rb), a temp git repo whose commits are the landings
#      and reverts (committer dates pinned), and an injected now
#      (LEAD_TIME_EXPERIMENT_NOW). No network, no real state.
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

# ── fixtures: a git repo whose commits are the experiments' landings ───────
REPO="${TMP}/repo"
G=(env GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid
   GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid git -C "${REPO}")
mkdir -p "${REPO}"
"${G[@]}" init -q -b main || { echo "FAIL git init"; echo "  Fix: install git"; exit 1; }
# commit AT SUBJECT [BODY] -> prints the new SHA
commit() {
  GIT_COMMITTER_DATE="$1" GIT_AUTHOR_DATE="$1" "${G[@]}" commit -q --allow-empty -m "$2" ${3:+-m "$3"} \
    && "${G[@]}" rev-parse HEAD
}
LANDING="$(commit 2026-09-01T00:00:00Z "fixture: landing")"
OTHER="$(commit 2026-09-01T00:01:00Z "fixture: other")"
NEWSHA="$(commit 2026-09-01T00:02:00Z "fixture: not ingested yet")"
NEVER="$(printf '1%.0s' $(seq 40))"
[ ${#LANDING} -eq 40 ] && [ ${#OTHER} -eq 40 ] && [ ${#NEWSHA} -eq 40 ] || { echo "FAIL fixture commits"; echo "  Fix: install git"; exit 1; }

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
statuses() { grep -c '"type":"status"' "$1"; }

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
eq "list with an unknown repo is refused, not an empty list" "$(run list --repo custm)" "2"
has "... naming the configured repos" "$(err)" "configured: custom, gen_saas"
eq "a short SHA is refused: exit 2" "$(rec verify phase abc123 change)" "2"
has "... naming the 40-hex rule" "$(err)" "40-hex"
eq "instrumentation with a duration metric is refused" "$(rec implement phase "${LANDING}" instrumentation)" "2"
has "... naming na_share" "$(err)" "na_share"
eq "an unknown metric is refused" "$(rec verify speed "${LANDING}" change)" "2"
printf '\377\376 not utf-8\n' >"${TMP}/latin.txt"
eq "a hypothesis that is not UTF-8 is refused" "$(run record --repo custom --phase verify --metric phase --commit "${LANDING}" --kind change --hypothesis-file "${TMP}/latin.txt")" "2"
has "... saying so" "$(err)" "not valid UTF-8"

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
eq "a SHA that is not on main is refused: exit 2" "$(rec verify phase "${NEVER}" change)" "2"
has "... saying it is not on main, with Fix:" "$(err)" "is not on custom's main"
eq "record a change on verify: exit 0" "$(rec verify phase "${LANDING}" change)" "0"
SHORT="${LANDING:0:12}"
has "record prints the baseline from the fixture ledger" "$(out)" "baseline n=10 median=600s p90=600s"
eq "list: exit 0" "$(run list --repo custom)" "0"
has "list shows one PENDING experiment" "$(out)" "custom:verify:${SHORT} PENDING kind=change metric=phase"
has "list shows its baseline numbers" "$(out)" "baseline n=10 median=600s p90=600s"
has "list counts it" "$(out)" "1 experiment(s) for custom of 1 recorded"

# ── record refused: a second change on the same phase ───────────────────────
echo "== record refused"
eq "a second change on verify: exit 2" "$(rec verify phase "${OTHER}" change)" "2"
has "the refusal names the pending experiment" "$(err)" "custom:verify:${SHORT}"
has "the refusal carries Fix:" "$(err)" "Fix:"
eq "the refused record was not written" "$(grep -c '"type":"record"' "${STATE}/experiments.jsonl")" "1"
eq "the same id twice is refused: exit 2" "$(rec verify phase "${LANDING}" change)" "2"
has "... as already recorded" "$(err)" "already recorded"
eq "instrumentation on the same landing, implement: admitted" "$(rec implement na_share "${LANDING}" instrumentation)" "0"
has "its baseline is the n/a share" "$(out)" "n/a share=1.0"

# ── judge: keep, and a revert OF AN EXPERIMENT never counts as a guard ──────
echo "== judge"
# In the after-window (the 20th, 12:00-21:00): a revert of this experiment's
# own commit. Counting it would chain reverts across experiments.
commit 2026-09-20T15:00:00Z "Revert \"fixture: landing\"" "This reverts commit ${LANDING}." >/dev/null
eq "judge: exit 0" "$(run judge --repo custom)" "0"
J="$(out)"
has "judge keeps the verify change (600 -> 500)" "${J}" "custom:verify:${SHORT} KEEP"
has "judge prints before and after numbers" "${J}" "before n=10 median=600s p90=600s | after n=10 median=500s p90=500s"
has "judge prints the guards, measured" "${J}" "critic_block_rate 0.0->0.0 ok"
has "the experiment's own revert is not counted" "${J}" "reverts 0->0 ok"
has "judge keeps the instrumentation (share 1.0 -> 0.0)" "${J}" "custom:implement:${SHORT} KEEP"
has "judge sums up" "${J}" "2 judged (0 pending, 2 keep, 0 revert, 0 inconclusive, 0 reverted); 2 status row(s) appended"
eq "two status rows were appended" "$(statuses "${STATE}/experiments.jsonl")" "2"
eq "re-judge with the same now: exit 0" "$(run judge --repo custom)" "0"
has "a keep is terminal: nothing is judged again" "$(out)" "0 judged"
eq "no duplicate status rows" "$(statuses "${STATE}/experiments.jsonl")" "2"
eq "list after judge" "$(run list)" "0"
has "list shows the latest status" "$(out)" "custom:verify:${SHORT} KEEP"

# ── judge idempotent on a still-pending row ─────────────────────────────────
echo "== pending idempotence"
eq "record a change on merge whose landing is not ledgered yet" "$(rec merge phase "${NEWSHA}" change)" "0"
has "its baseline is marked provisional" "$(out)" "provisional"
eq "judge: exit 0" "$(run judge --repo custom)" "0"
has "the unlanded experiment is PENDING" "$(out)" "custom:merge:${NEWSHA:0:12} PENDING"
has "... on main, so the reason is ingest lag" "$(out)" "it is on main: run lead-time-phases --ingest"
N1="$(statuses "${STATE}/experiments.jsonl")"
eq "re-judge with the same now" "$(run judge --repo custom)" "0"
has "re-judge appends nothing" "$(out)" "0 status row(s) appended"
eq "the status row count is unchanged" "$(statuses "${STATE}/experiments.jsonl")" "${N1}"
eq "eight days later: judge exits 0" "$(LEAD_TIME_EXPERIMENT_NOW=2026-09-29T13:00:00Z run judge --repo custom)" "0"
has "an unlanded experiment past day 7 is INCONCLUSIVE" "$(out)" "custom:merge:${NEWSHA:0:12} INCONCLUSIVE"

# ── a malformed record is reported, not fatal ───────────────────────────────
echo "== malformed record"
printf '%s\n' '{"type":"record","id":"custom:queue:zz","repo":"custom","phase":"queue","metric":"phase","kind":"change","commit":"zz","recorded_at":"2026-09-21T12:00:00Z"}' >>"${STATE}/experiments.jsonl"
eq "judge with a malformed record still exits 0" "$(run judge --repo custom)" "0"
has "the malformed record is named, with Fix:" "$(err)" "record \"custom:queue:zz\" is malformed"
has "... and Fix:" "$(err)" "Fix:"

# ── revert: owed until main carries it, and it blocks its phase meanwhile ───
echo "== revert owed"
STATE3="${TMP}/state3"
mkdir -p "${STATE3}"
# after-set verify 700 s (median rose); windows on the 22nd. An unrelated
# revert lands in the after-window and IS counted.
/usr/bin/ruby "${HERE}/make_ledger.rb" "${STATE3}/ledger.jsonl" "${OTHER}" 700 2026-09-22T00:00:00Z
commit 2026-09-22T15:00:00Z "Revert \"something unrelated\"" "This reverts commit $(printf '2%.0s' $(seq 40))." >/dev/null
s3() { LEAD_TIME_STATE_DIR="${STATE3}" LEAD_TIME_EXPERIMENT_NOW=2026-09-23T12:00:00Z "$@"; }
eq "record the change" "$(s3 rec verify phase "${OTHER}" change)" "0"
eq "judge: exit 0" "$(s3 run judge --repo custom)" "0"
has "a guard worsened by an unrelated revert: REVERT" "$(out)" "custom:verify:${OTHER:0:12} REVERT"
has "... naming the guard" "$(out)" "reverts 0 -> 1"
eq "re-judge: exit 0" "$(s3 run judge --repo custom)" "0"
has "the revert is OWED while main lacks it" "$(out)" "REVERT OWED"
has "... and nothing new is recorded" "$(out)" "0 status row(s) appended"
eq "a new change on verify is refused while the revert is owed" "$(s3 rec verify phase "${NEWSHA}" change)" "2"
has "... saying it owes a revert" "$(err)" "owes a revert"
commit 2026-09-23T13:00:00Z "Revert \"fixture: other\"" "This reverts commit ${OTHER}." >/dev/null
eq "judge after the revert lands: exit 0" "$(s3 run judge --repo custom)" "0"
has "it is REVERTED" "$(out)" "custom:verify:${OTHER:0:12} REVERTED"
eq "the phase is free again" "$(s3 rec verify phase "${NEWSHA}" change)" "0"

# ── reverts guard: could not look is unmeasured, never 0 ────────────────────
echo "== reverts could not look"
printf '%s\n' "{\"repos\":[{\"name\":\"custom\",\"path\":\"${TMP}/gone\",\"mode\":\"improve\"}],\"window\":20,\"improvement_epic\":\"epic-id\"}" >"${TMP}/gone.json"
STATE2="${TMP}/state2"
mkdir -p "${STATE2}"
/usr/bin/ruby "${HERE}/make_ledger.rb" "${STATE2}/ledger.jsonl" "${LANDING}"
eq "record with the repo absent: could not look (exit 3)" "$(LEAD_TIME_STATE_DIR="${STATE2}" LEAD_TIME_PHASES_CONFIG="${TMP}/gone.json" rec verify phase "${LANDING}" change)" "3"
has "... saying it could not look whether it is on main" "$(err)" "could not look whether"
eq "record with the repo present" "$(LEAD_TIME_STATE_DIR="${STATE2}" rec verify phase "${LANDING}" change)" "0"
eq "judge with the repo gone: exit 0" "$(LEAD_TIME_STATE_DIR="${STATE2}" LEAD_TIME_PHASES_CONFIG="${TMP}/gone.json" run judge --repo custom)" "0"
has "no keep while reverts could not be read" "$(out)" "custom:verify:${SHORT} PENDING"
has "... and it says the guard is unmeasured" "$(out)" "reverts unmeasured"

echo
echo "lead-time-improve self-test: ${PASS} passed, ${FAIL} failed"
[ "${FAIL}" -eq 0 ] || { echo "Fix: read the FAIL lines above; each names the case and what it expected."; exit 1; }
exit 0
