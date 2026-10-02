#!/usr/bin/env bash
# self-test.sh -- the athena:lead-time-improve suite (DND-1478). Discovered by
# harness-gate (every committed `self-test.sh` runs).
#
# Layers, in TDD order:
#   1. the domain and store suite (experiment_test.rb);
#   2. scripts/experiment end to end, against temp state dirs
#      (LEAD_TIME_STATE_DIR), a temp config (ATHENA_LEADTIME_CONFIG), fixture
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
REPO="${TMP}/custom"
G=(env GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid
   GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid git -C "${REPO}")
mkdir -p "${REPO}"
"${G[@]}" init -q -b main || { echo "FAIL git init"; echo "  Fix: install git"; exit 1; }
# commit AT SUBJECT [BODY] -> prints the new SHA
commit() {
  GIT_COMMITTER_DATE="$1" GIT_AUTHOR_DATE="$1" "${G[@]}" commit -q --allow-empty -m "$2" ${3:+-m "$3"} \
    && "${G[@]}" rev-parse HEAD
}
# Each experiment commit carries the Lead-time-experiment trailer for every
# repo/phase/metric this suite records it on (DND-1529).
tr() { printf 'Lead-time-experiment: %s\n' "$@"; }
LANDING="$(commit 2026-09-01T00:00:00Z "fixture: landing" "$(tr "custom verify phase" "custom implement na_share")")"
OTHER="$(commit 2026-09-01T00:01:00Z "fixture: other" "$(tr "custom verify phase")")"
NEWSHA="$(commit 2026-09-01T00:02:00Z "fixture: not ingested yet" "$(tr "custom merge phase" "custom verify phase")")"
NEVER="$(printf '1%.0s' $(seq 40))"
[ ${#LANDING} -eq 40 ] && [ ${#OTHER} -eq 40 ] && [ ${#NEWSHA} -eq 40 ] || { echo "FAIL fixture commits"; echo "  Fix: install git"; exit 1; }

CONFIG="${TMP}/repos.json"
# Each configured path that exists must be a checkout named for its repo
# (DND-1526), so the watch repo is a real (empty) checkout named gen_saas.
mkdir -p "${TMP}/gen_saas"
env GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "${TMP}/gen_saas" init -q -b main
printf '%s\n' "{\"repos\":[{\"name\":\"custom\",\"path\":\"${REPO}\",\"mode\":\"improve\"},{\"name\":\"gen_saas\",\"path\":\"${TMP}/gen_saas\",\"mode\":\"watch\"}],\"window\":20,\"improvement_epic\":\"epic-id\"}" >"${CONFIG}"

STATE="${TMP}/state"
mkdir -p "${STATE}"
HYP="${TMP}/hypothesis.txt"
printf 'Caching the gate fixture should cut verify by a fifth.\n' >"${HYP}"

export LEAD_TIME_STATE_DIR="${STATE}" ATHENA_LEADTIME_CONFIG="${CONFIG}" LEAD_TIME_EXPERIMENT_NOW="2026-09-21T12:00:00Z"

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
has "... and the trailer line its revert lands with (DND-1529)" "$(out)" 'land the revert with the trailer line `Lead-time-experiment: custom verify phase`'
eq "re-judge: exit 0" "$(s3 run judge --repo custom)" "0"
has "the revert is OWED while main lacks it" "$(out)" "REVERT OWED"
has "... still naming the trailer line" "$(out)" 'land the revert with the trailer line `Lead-time-experiment: custom verify phase`'
has "... and nothing new is recorded" "$(out)" "0 status row(s) appended"
eq "a new change on verify is refused while the revert is owed" "$(s3 rec verify phase "${NEWSHA}" change)" "2"
has "... saying it owes a revert" "$(err)" "owes a revert"
commit 2026-09-23T13:00:00Z "Revert \"fixture: other\"" "This reverts commit ${OTHER}." >/dev/null
eq "judge after the revert lands: exit 0" "$(s3 run judge --repo custom)" "0"
has "it is REVERTED" "$(out)" "custom:verify:${OTHER:0:12} REVERTED"
eq "the phase is free again" "$(s3 rec verify phase "${NEWSHA}" change)" "0"

# ── decline: a revert the hard constraint forbids (DND-1547) ────────────────
echo "== decline"
# A median-only revert: after-set verify 700 s, windows on the 24th, no revert
# of anything in either window, so every guard is ok.
DECL="$(commit 2026-09-24T11:00:00Z "fixture: a fixture fix a revert would delete" "$(tr "custom verify phase")")"
STATE4="${TMP}/state4"
mkdir -p "${STATE4}"
/usr/bin/ruby "${HERE}/make_ledger.rb" "${STATE4}/ledger.jsonl" "${DECL}" 700 2026-09-24T00:00:00Z
s4() { LEAD_TIME_STATE_DIR="${STATE4}" LEAD_TIME_EXPERIMENT_NOW=2026-09-25T12:00:00Z "$@"; }
DID="custom:verify:${DECL:0:12}"
REASON="${TMP}/reason.txt"
printf 'The revert would delete the assertion that killing the holder frees the lock.\n' >"${REASON}"
dec() { s4 run decline --repo custom --id "$1" --constraint "$2" --reason-file "$3"; }
rows4() { grep -c . "${STATE4}/experiments.jsonl"; }
eq "decline with no experiments file: exit 2" "$(dec "${DID}" safety-checks "${REASON}")" "2"
has "... saying there is nothing to decline" "$(err)" "nothing to decline"
eq "... and the file is not created" "$(test -e "${STATE4}/experiments.jsonl" && echo yes || echo no)" "no"
eq "record the change" "$(s4 rec verify phase "${DECL}" change)" "0"
eq "decline before it is judged: exit 2" "$(dec "${DID}" safety-checks "${REASON}")" "2"
has "... not judged yet" "$(err)" "not judged yet"
eq "judge: exit 0" "$(s4 run judge --repo custom)" "0"
has "a median-only REVERT" "$(out)" "${DID} REVERT"
has "... every guard ok" "$(out)" "reverts 0->0 ok"
eq "regression: record on the phase is refused while the revert is owed" "$(s4 rec verify phase "${OTHER}" change)" "2"
has "... naming the blocker" "$(err)" "${DID}"
N4="$(rows4)"
: >"${TMP}/empty.txt"
eq "an empty reason file: exit 2" "$(dec "${DID}" safety-checks "${TMP}/empty.txt")" "2"
has "... saying it is empty" "$(err)" "is empty"
eq "a missing reason file: exit 2" "$(dec "${DID}" safety-checks "${TMP}/no-such-reason.txt")" "2"
has "... saying it cannot be read" "$(err)" "cannot read the reason file"
eq "a reason file that is not UTF-8: exit 2" "$(dec "${DID}" safety-checks "${TMP}/latin.txt")" "2"
has "... saying so" "$(err)" "not valid UTF-8"
eq "an unknown --constraint: exit 2" "$(dec "${DID}" speed "${REASON}")" "2"
has "... naming the known constraints" "$(err)" "safety-checks, bug-fix"
eq "an unknown id: exit 2" "$(dec custom:verify:000000000000 safety-checks "${REASON}")" "2"
has "... listing the repo's ids" "$(err)" "${DID}"
eq "no refused decline wrote a row" "$(rows4)" "${N4}"
cp "${STATE4}/experiments.jsonl" "${TMP}/store4.before"
eq "decline --help: exit 0" "$(s4 run decline --repo custom --id "${DID}" --constraint safety-checks --reason-file "${REASON}" --help)" "0"
has "... documents the verb on stdout" "$(out)" "experiment decline --repo R --id ID --constraint"
eq "... and the store is byte-identical" "$(cmp -s "${TMP}/store4.before" "${STATE4}/experiments.jsonl" && echo same || echo changed)" "same"
eq "decline the median-only revert: exit 0" "$(dec "${DID}" safety-checks "${REASON}")" "0"
has "... saying it is declined" "$(out)" "declined ${DID}"
eq "decline wrote exactly one row" "$(rows4)" "$((N4 + 1))"
LAST="$(tail -1 "${STATE4}/experiments.jsonl")"
has "... a declined status row" "${LAST}" '"status":"declined"'
has "... with the constraint" "${LAST}" '"constraint":"safety-checks"'
has "... keeping the revert's reason" "${LAST}" '"prior_reason":"median rose 600s -> 700s"'
has "... and its numbers" "${LAST}" '"after":{"n":10,"median":700'
eq "judge after the decline: exit 0" "$(s4 run judge --repo custom)" "0"
lacks "no REVERT OWED line for it" "$(out)" "REVERT OWED"
has "the declined experiment is not judged again" "$(out)" "0 judged ("
has "... so the tally has no keep for it" "$(out)" "0 keep"
has "... and counts it as declined on its own" "$(out)" "1 declined"
eq "judge appended nothing" "$(rows4)" "$((N4 + 1))"
eq "list: exit 0" "$(s4 run list --repo custom)" "0"
has "list shows DECLINED with the constraint and reason" "$(out)" "${DID} DECLINED constraint=safety-checks"
has "... and the reason" "$(out)" "killing the holder frees the lock"
has "... and the revert verdict it declined" "$(out)" "(revert verdict was: median rose 600s -> 700s)"
eq "decline twice: exit 2" "$(dec "${DID}" safety-checks "${REASON}")" "2"
has "... already declined" "$(err)" "already declined"
eq "... still one declined row" "$(grep -c '"status":"declined"' "${STATE4}/experiments.jsonl")" "1"
eq "the phase now admits a new change" "$(s4 rec verify phase "${OTHER}" change)" "0"

echo "== decline refuses a guard-worse revert"
WORSE="$(commit 2026-09-26T11:00:00Z "fixture: a change whose window saw a revert" "$(tr "custom verify phase")")"
commit 2026-09-26T15:00:00Z "Revert \"something else\"" "This reverts commit $(printf '3%.0s' $(seq 40))." >/dev/null
STATE5="${TMP}/state5"
mkdir -p "${STATE5}"
/usr/bin/ruby "${HERE}/make_ledger.rb" "${STATE5}/ledger.jsonl" "${WORSE}" 500 2026-09-26T00:00:00Z
s5() { LEAD_TIME_STATE_DIR="${STATE5}" LEAD_TIME_EXPERIMENT_NOW=2026-09-27T12:00:00Z "$@"; }
WID="custom:verify:${WORSE:0:12}"
eq "record" "$(s5 rec verify phase "${WORSE}" change)" "0"
eq "judge" "$(s5 run judge --repo custom)" "0"
has "a guard-worse REVERT" "$(out)" "${WID} REVERT"
N5="$(grep -c . "${STATE5}/experiments.jsonl")"
eq "decline it: exit 2" "$(s5 run decline --repo custom --id "${WID}" --constraint bug-fix --reason-file "${REASON}")" "2"
has "... naming the guard" "$(err)" "a guard worsened (reverts)"
has "... with Fix:" "$(err)" "Fix:"
eq "... nothing written" "$(grep -c . "${STATE5}/experiments.jsonl")" "${N5}"

# ── check:<label>: a change judged on its own check's wall (DND-1548) ───────
echo "== check metric"
WAITL="self-test: fixture/control/wait"
CHK="$(commit 2026-09-28T11:00:00Z "fixture: a one-check fix" "$(tr "custom verify check:${WAITL}")")"
CID="custom:verify:${CHK:0:12}"
STATE6="${TMP}/state6"
mkdir -p "${STATE6}"
s6() { LEAD_TIME_STATE_DIR="${STATE6}" LEAD_TIME_EXPERIMENT_NOW=2026-09-29T12:00:00Z "$@"; }
has "--help lists the check metric" "$(run --help >/dev/null; out)" "check:<label>"
/usr/bin/ruby "${HERE}/make_ledger.rb" "${STATE6}/ledger.jsonl" "${CHK}" 700 2026-09-28T00:00:00Z
eq "record a check metric when no landing carries check_walls: exit 3" "$(s6 rec verify "check:${WAITL}" "${CHK}" change)" "3"
has "... could not look, never an unknown label" "$(err)" "could not look"
lacks "... and it does not call the label unknown" "$(err)" "appears on none"
eq "... nothing written" "$(test -e "${STATE6}/experiments.jsonl" && echo yes || echo no)" "no"
/usr/bin/ruby "${HERE}/make_ledger.rb" "${STATE6}/ledger.jsonl" "${CHK}" 700 2026-09-28T00:00:00Z checks
eq "check: with no label: exit 2" "$(s6 rec verify "check:" "${CHK}" change)" "2"
has "... saying it needs a label" "$(err)" "needs a check label"
eq "regression: record with a misspelled label: exit 2" "$(s6 rec verify "check:self-test: fixture/control/wiat" "${CHK}" change)" "2"
has "... saying it appears on none of the window's landings" "$(err)" "appears on none of 20 landings with check_walls"
has "... naming the closest label" "$(err)" "${WAITL}"
has "... with a Fix: naming timings.jsonl" "$(err)" "timings.jsonl"
eq "... nothing written" "$(test -e "${STATE6}/experiments.jsonl" && echo yes || echo no)" "no"
eq "record on the check: exit 0" "$(s6 rec verify "check:${WAITL}" "${CHK}" change)" "0"
has "... its baseline is the check's wall" "$(out)" "metric=check:${WAITL} phase=verify baseline n=10 median=120.0s"
eq "judge: exit 0" "$(s6 run judge --repo custom)" "0"
has "the check fell 120 -> 5 s while the phase rose: KEEP" "$(out)" "${CID} KEEP"
has "... judged on the check's numbers" "$(out)" "before n=10 median=120.0s p90=120.0s | after n=10 median=5.0s p90=5.0s"
has "... with the phase median beside it as context" "$(out)" "phase (context, not judged): before n=10 median=600s p90=600s | after n=10 median=700s p90=700s"

# ── reverts guard: could not look is unmeasured, never 0 ────────────────────
echo "== reverts could not look"
# A checkout that is present but has no main (DND-1526: a missing path is
# skipped by the resolver, so git's could-not-look is reached this way).
NOMAIN="${TMP}/nomain/custom"
mkdir -p "${NOMAIN}"
env GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "${NOMAIN}" init -q -b main
printf '%s\n' "{\"repos\":[{\"name\":\"custom\",\"path\":\"${NOMAIN}\",\"mode\":\"improve\"}],\"window\":20,\"improvement_epic\":\"epic-id\"}" >"${TMP}/nomain.json"
STATE2="${TMP}/state2"
mkdir -p "${STATE2}"
/usr/bin/ruby "${HERE}/make_ledger.rb" "${STATE2}/ledger.jsonl" "${LANDING}"
eq "record with no main to read: could not look (exit 3)" "$(LEAD_TIME_STATE_DIR="${STATE2}" ATHENA_LEADTIME_CONFIG="${TMP}/nomain.json" rec verify phase "${LANDING}" change)" "3"
has "... saying it could not look whether it is on main" "$(err)" "could not look whether"
eq "record with the repo present" "$(LEAD_TIME_STATE_DIR="${STATE2}" rec verify phase "${LANDING}" change)" "0"
# DND-1529: judge reads the harness repo's log for confounders before it
# would read the reverts; a log it cannot read is exit 3, never "no
# confounder" (and never a keep while the guards could not be read).
N2="$(statuses "${STATE2}/experiments.jsonl")"
eq "regression: judge with no main to read: could not look (exit 3)" "$(LEAD_TIME_STATE_DIR="${STATE2}" ATHENA_LEADTIME_CONFIG="${TMP}/nomain.json" run judge --repo custom)" "3"
has "... saying it could not look for confounders in custom's log" "$(err)" "could not look for confounders: custom's log cannot be read"
has "... never no confounder, with Fix:" "$(err)" "this is not \"no confounder\""
lacks "... no verdict printed" "$(out)" "KEEP"
eq "... nothing written" "$(statuses "${STATE2}/experiments.jsonl")" "${N2}"

# ── revert held: a plain revert would delete test additions (DND-1549) ─────
echo "== revert held"
# commit_files AT SUBJECT [BODY] -> stages the work tree, commits, prints the SHA
commit_files() {
  "${G[@]}" add -A && GIT_COMMITTER_DATE="$1" GIT_AUTHOR_DATE="$1" "${G[@]}" commit -q -m "$2" ${3:+-m "$3"} \
    && "${G[@]}" rev-parse HEAD
}
mkdir -p "${REPO}/ai/x/test" "${REPO}/ai/bin"
printf 'echo one\necho two\n' >"${REPO}/ai/x/test/foo.sh"
printf 'echo fixed\n' >"${REPO}/ai/x/fix.sh"
TADD="$(commit_files 2026-09-30T11:00:00Z "fixture: a fix with its regression test" "$(tr "custom verify phase" "gen_saas verify phase")")"
printf 'echo tool\n' >"${REPO}/ai/bin/x"
TBIN="$(commit_files 2026-09-30T11:01:00Z "fixture: a tool-only change" "$(tr "custom implement phase")")"
printf 'echo one\n' >"${REPO}/ai/x/test/foo.sh"
TDEL="$(commit_files 2026-09-30T11:02:00Z "fixture: a change that only deletes a test line" "$(tr "custom queue phase")")"
mkdir -p "${REPO}/ai/y/test"
"${G[@]}" mv ai/x/test/foo.sh ai/y/test/foo.sh
TREN="$(commit_files 2026-09-30T11:03:00Z "fixture: a test moved to a new path" "$(tr "custom integrate phase")")"
STATE7="${TMP}/state7"
mkdir -p "${STATE7}"
# after-set verify 700 s, windows on the 30th, no revert in either: median-only
/usr/bin/ruby "${HERE}/make_ledger.rb" "${STATE7}/ledger.jsonl" "${TADD}" 700 2026-09-30T00:00:00Z
s7() { LEAD_TIME_STATE_DIR="${STATE7}" LEAD_TIME_EXPERIMENT_NOW=2026-10-01T12:00:00Z "$@"; }
recrow() { grep '"type":"record"' "$1" | grep "\"id\":\"$2\""; }
HID="custom:verify:${TADD:0:12}"
eq "record a change whose commit adds a test: exit 0" "$(s7 rec verify phase "${TADD}" change)" "0"
has "... the record row lists the test path, not the fix" "$(recrow "${STATE7}/experiments.jsonl" "${HID}")" '"revert_deletes_tests":["ai/x/test/foo.sh"]'
eq "record a tool-only change: exit 0" "$(s7 rec implement phase "${TBIN}" change)" "0"
has "... lists no test" "$(recrow "${STATE7}/experiments.jsonl" "custom:implement:${TBIN:0:12}")" '"revert_deletes_tests":[]'
eq "record a change that only deletes test lines: exit 0" "$(s7 rec queue phase "${TDEL}" change)" "0"
has "... lists no test (reverting it adds them back)" "$(recrow "${STATE7}/experiments.jsonl" "custom:queue:${TDEL:0:12}")" '"revert_deletes_tests":[]'
eq "record a change that moves a test: exit 0" "$(s7 rec integrate phase "${TREN}" change)" "0"
has "... lists the test under its new path (a revert would delete it there)" "$(recrow "${STATE7}/experiments.jsonl" "custom:integrate:${TREN:0:12}")" '"revert_deletes_tests":["ai/y/test/foo.sh"]'
eq "judge: exit 0" "$(s7 run judge --repo custom)" "0"
has "regression: a revert of a test-adding commit reads REVERT HELD" "$(out)" "${HID} REVERT HELD kind=change"
has "... naming the test additions" "$(out)" "reverting ${TADD:0:12} deletes test additions in ai/x/test/foo.sh"
has "... ruling out a plain git revert" "$(out)" "the hard constraint rules out a plain git revert"
has "... with the Fix" "$(out)" "Fix: land a partial revert that keeps every test addition and its fixture fix"
has "... offering decline (a median-only revert)" "$(out)" "experiment decline --repo custom --id ${HID} --constraint safety-checks"
has "the verdict is still revert, and held is tallied on its own" "$(out)" "1 revert, 0 inconclusive, 0 reverted)"
has "... 1 held" "$(out)" "1 held"
ROW7="$(grep '"type":"status"' "${STATE7}/experiments.jsonl" | grep "\"id\":\"${HID}\"")"
has "the status row stays revert" "${ROW7}" '"status":"revert"'
has "... and carries held" "${ROW7}" '"held":{"tests":["ai/x/test/foo.sh"]}'
eq "re-judge: exit 0" "$(s7 run judge --repo custom)" "0"
has "the owed revert still reads REVERT HELD" "$(out)" "${HID} REVERT HELD kind=change"
lacks "... never a plain REVERT OWED" "$(out)" "REVERT OWED"
has "... and is still owed" "$(out)" "main has no revert of it yet"
has "... the Fix keeps git's full-SHA revert line" "$(out)" "\"This reverts commit ${TADD}.\""
# The Fix's partial revert: the fix undone, the test kept, git's line kept.
rm "${REPO}/ai/x/fix.sh"
PARTIAL="$(GIT_COMMITTER_DATE=2026-10-01T11:00:00Z GIT_AUTHOR_DATE=2026-10-01T11:00:00Z "${G[@]}" commit -q -a \
  -m "Revert \"fixture: a fix with its regression test\" (partial: keeps the test)" -m "This reverts commit ${TADD}." && "${G[@]}" rev-parse HEAD)"
eq "... the partial revert landed" "${#PARTIAL}" "40"
eq "judge after the partial revert lands: exit 0" "$(s7 run judge --repo custom)" "0"
has "the held revert settles as REVERTED" "$(out)" "${HID} REVERTED"

echo "== revert held: a record with no field"
STATE8="${TMP}/state8"
mkdir -p "${STATE8}"
cp "${STATE7}/ledger.jsonl" "${STATE8}/ledger.jsonl"
s8() { LEAD_TIME_STATE_DIR="${STATE8}" LEAD_TIME_EXPERIMENT_NOW=2026-10-01T12:00:00Z "$@"; }
recrow "${STATE7}/experiments.jsonl" "${HID}" | sed 's/,"revert_deletes_tests":\[[^]]*\]//' >"${STATE8}/experiments.jsonl"
lacks "the fixture record predates the field" "$(cat "${STATE8}/experiments.jsonl")" "revert_deletes_tests"
eq "judge: exit 0" "$(s8 run judge --repo custom)" "0"
has "the field is computed on the fly: REVERT HELD" "$(out)" "${HID} REVERT HELD kind=change"
has "... naming the test additions" "$(out)" "deletes test additions in ai/x/test/foo.sh"
lacks "... and the record is not rewritten" "$(recrow "${STATE8}/experiments.jsonl" "${HID}")" "revert_deletes_tests"

echo "== revert held: a record-time could-not-look is looked at again"
STATE10="${TMP}/state10"
mkdir -p "${STATE10}"
cp "${STATE8}/ledger.jsonl" "${STATE10}/"
recrow "${STATE8}/experiments.jsonl" "${HID}" | sed 's/"type":"record",/"type":"record","revert_deletes_tests_na":"git show failed once",/' >"${STATE10}/experiments.jsonl"
has "the fixture record carries _na" "$(cat "${STATE10}/experiments.jsonl")" '"revert_deletes_tests_na":"git show failed once"'
eq "judge: exit 0" "$(LEAD_TIME_STATE_DIR="${STATE10}" LEAD_TIME_EXPERIMENT_NOW=2026-10-01T12:00:00Z run judge --repo custom)" "0"
has "git answers now: held on the test, not on could not look" "$(out)" "deletes test additions in ai/x/test/foo.sh"
lacks "... the stale reason is not printed" "$(out)" "git show failed once"

echo "== revert held: git could not look"
STATE9="${TMP}/state9"
mkdir -p "${STATE9}"
cp "${STATE8}/ledger.jsonl" "${STATE8}/experiments.jsonl" "${STATE9}/"
eq "judge an owed revert where git cannot show the commit: exit 0" "$(LEAD_TIME_STATE_DIR="${STATE9}" ATHENA_LEADTIME_CONFIG="${TMP}/nomain.json" LEAD_TIME_EXPERIMENT_NOW=2026-10-01T12:00:00Z run judge --repo custom)" "0"
has "an unknown answer is held (fail closed)" "$(out)" "${HID} REVERT HELD kind=change"
has "... saying it could not look" "$(out)" "could not look whether reverting ${TADD:0:12} deletes test additions"
has "the git adapter reads a bad repo path as could not look, never as no tests" \
  "$(/usr/bin/ruby -e 'require ARGV[0]; s = LeadTimeExperimentGit.numstat(ARGV[1], ARGV[2]); puts s.could_not_look? ? "could_not_look: #{s.reason}" : "ok: #{s.items.inspect}"' \
     "${HERE}/../lib/experiment_git.rb" "${TMP}/no-such-repo" "${TADD}")" "could_not_look:"

# ── unclassified additions: named, never read as no tests (DND-1634) ───────
echo "== unclassified additions"
# Dated mid-August, so no other fixture's window holds its trailer.
mkdir -p "${REPO}/features" "${REPO}/ai/z"
printf 'Feature: login\n  Scenario: ok\n' >"${REPO}/features/x.feature"
printf 'echo fixed\n' >"${REPO}/ai/z/fix.sh"
TFEAT="$(commit_files 2026-08-15T11:00:00Z "fixture: a fix with a Cucumber feature" "$(tr "custom verify phase")")"
printf 'echo plain\n' >"${REPO}/ai/z/plain.sh"
TSRC="$(commit_files 2026-08-15T11:01:00Z "fixture: a plain source change" "$(tr "custom implement phase")")"
STATE11="${TMP}/state11"
mkdir -p "${STATE11}"
/usr/bin/ruby "${HERE}/make_ledger.rb" "${STATE11}/ledger.jsonl" "${TFEAT}" 700 2026-08-15T00:00:00Z
s11() { LEAD_TIME_STATE_DIR="${STATE11}" LEAD_TIME_EXPERIMENT_NOW=2026-08-16T12:00:00Z "$@"; }
FID="custom:verify:${TFEAT:0:12}"
eq "record a change adding features/x.feature: exit 0" "$(s11 rec verify phase "${TFEAT}" change)" "0"
has "regression: the record output names features/x.feature as unclassified" "$(out)" "unclassified additions in features/x.feature"
has "... the record row lists it" "$(recrow "${STATE11}/experiments.jsonl" "${FID}")" '"revert_unclassified":["features/x.feature"]'
has "... and no test (no guard moves)" "$(recrow "${STATE11}/experiments.jsonl" "${FID}")" '"revert_deletes_tests":[]'
eq "record a plain source change: exit 0" "$(s11 rec implement phase "${TSRC}" change)" "0"
lacks "... its record output names nothing unclassified" "$(out)" "unclassified"
has "... its record row lists none" "$(recrow "${STATE11}/experiments.jsonl" "custom:implement:${TSRC:0:12}")" '"revert_unclassified":[]'
eq "judge: exit 0" "$(s11 run judge --repo custom)" "0"
has "the revert is not held on an unclassified path" "$(out)" "${FID} REVERT kind=change"
lacks "... never REVERT HELD" "$(out)" "REVERT HELD"
has "regression: the judge line names features/x.feature as unclassified" "$(out)" "unclassified additions in features/x.feature"
has "... 0 held" "$(out)" "0 held"
STATE12="${TMP}/state12"
mkdir -p "${STATE12}"
cp "${STATE11}/ledger.jsonl" "${STATE12}/"
recrow "${STATE11}/experiments.jsonl" "${FID}" | sed 's/,"revert_unclassified":\[[^]]*\]//' >"${STATE12}/experiments.jsonl"
lacks "a record from before DND-1634 has no field" "$(cat "${STATE12}/experiments.jsonl")" "revert_unclassified"
eq "judge it: exit 0" "$(LEAD_TIME_STATE_DIR="${STATE12}" LEAD_TIME_EXPERIMENT_NOW=2026-08-16T12:00:00Z run judge --repo custom)" "0"
has "... the field is computed on the fly" "$(out)" "unclassified additions in features/x.feature"

# ── cross-repo: a custom change measured on gen_saas (DND-1528) ─────────────
echo "== cross-repo"
XGS="${TMP}/xr/gen_saas"
mkdir -p "${XGS}"
GX=(env GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid
    GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid git -C "${XGS}")
"${GX[@]}" init -q -b main
GS_ONLY="$(GIT_COMMITTER_DATE=2026-09-01T00:00:00Z GIT_AUTHOR_DATE=2026-09-01T00:00:00Z "${GX[@]}" commit -q --allow-empty -m "fixture: gen_saas root" && "${GX[@]}" rev-parse HEAD)"
XCONF="${TMP}/xrepo.json"
printf '%s\n' "{\"repos\":[{\"name\":\"custom\",\"path\":\"${REPO}\",\"mode\":\"improve\"},{\"name\":\"gen_saas\",\"path\":\"${XGS}\",\"mode\":\"improve\"}],\"window\":20,\"improvement_epic\":\"epic-id\"}" >"${XCONF}"
# The custom change: written at 02:00 (author date), landed at 11:30 (committer).
XC="$(GIT_AUTHOR_DATE=2026-10-02T02:00:00Z GIT_COMMITTER_DATE=2026-10-02T11:30:00Z "${G[@]}" commit -q --allow-empty -m "fixture: a harness change for gen_saas" -m "$(tr "gen_saas verify phase")" && "${G[@]}" rev-parse HEAD)"
XID="gen_saas:verify:${XC:0:12}"
# The push that carried it to main was 12:15 (the forge's time, in custom's
# ledger), with one more commit on top: the ledger's landed commit is that tip.
XTIP="$(GIT_AUTHOR_DATE=2026-10-02T11:40:00Z GIT_COMMITTER_DATE=2026-10-02T11:40:00Z "${G[@]}" commit -q --allow-empty -m "fixture: the next commit in the same push" && "${G[@]}" rev-parse HEAD)"
# custom_rows OUT: custom's ledger rows near it. 11:50 is a landing that does
# not carry XC (OTHER is an older custom commit); 12:15 is the push that does.
custom_rows() {
  printf '%s\n' "{\"schema\":1,\"repo\":\"custom\",\"mode\":\"improve\",\"ticket\":\"DND-9901\",\"landed_commit\":\"${OTHER}\",\"landed_at\":\"2026-10-02T11:50:00Z\",\"landed_via\":\"push\",\"phases\":{}}" \
    "{\"schema\":1,\"repo\":\"custom\",\"mode\":\"improve\",\"ticket\":\"DND-9902\",\"landed_commit\":\"${XTIP}\",\"landed_at\":\"2026-10-02T12:15:00Z\",\"landed_via\":\"push\",\"phases\":{}}" >>"$1"
}
# gen_saas's own landings, hourly from 2026-10-02T00:00Z: 600 s before, 500 s after.
STATEX="${TMP}/statex"
mkdir -p "${STATEX}"
gs_ledger() { # OUT LANDING AFTER BASE: make_ledger.rb's rows, as gen_saas's
  /usr/bin/ruby "${HERE}/make_ledger.rb" "$1.custom" "$2" "$3" "$4" && sed 's/"repo":"custom"/"repo":"gen_saas"/' "$1.custom" >"$1" && rm -f "$1.custom"
}
gs_ledger "${STATEX}/ledger.jsonl" "$(printf 'd%.0s' $(seq 40))" 500 2026-10-02T00:00:00Z
sx() { LEAD_TIME_STATE_DIR="${STATEX}" ATHENA_LEADTIME_CONFIG="${XCONF}" LEAD_TIME_EXPERIMENT_NOW=2026-10-03T12:00:00Z "$@"; }
xrec() { sx run record --repo gen_saas --change-repo "$1" --phase verify --metric phase --commit "$2" --kind change --hypothesis-file "${HYP}"; }
eq "a commit NOT on custom's main: refused, exit 2" "$(xrec custom "${NEVER}")" "2"
has "... naming the commit and the change repo" "$(err)" "${NEVER:0:12} is not on custom's main"
eq "a gen_saas commit as a custom change: refused (the on-main check reads the CHANGE repo)" "$(xrec custom "${GS_ONLY}")" "2"
has "... naming it" "$(err)" "${GS_ONLY:0:12} is not on custom's main"
eq "a change repo that cannot be resolved: refused, exit 2" "$(xrec nope "${XC}")" "2"
has "... naming it, with Fix:" "$(err)" "no repo \"nope\""
has "... and a Fix:" "$(err)" "Fix:"
eq "... nothing written by any refusal" "$(test -e "${STATEX}/experiments.jsonl" && echo yes || echo no)" "no"
eq "a commit on custom's main: accepted, exit 0" "$(xrec custom "${XC}")" "0"
has "record prints the change repo and live_at" "$(out)" "change_repo=custom commit=${XC:0:12} live_at=2026-10-02T11:30:00Z"
XROW="$(recrow "${STATEX}/experiments.jsonl" "${XID}")"
has "the row records change_repo" "${XROW}" '"change_repo":"custom"'
has "... live_at: with no custom ledger row carrying it, the landing commit's committer time, never the author date" "${XROW}" '"live_at":"2026-10-02T11:30:00Z"'
has "... and says that is its source" "${XROW}" '"live_at_source":"committer"'
has "record warns that live_at is the committer time, and why" "$(err)" "live_at for ${XC:0:12} is its committer time on custom's main: none of custom's 0 ledger landing(s)"
has "... the commit" "${XROW}" "\"commit\":\"${XC}\""
has "the baseline splits at live_at: gen_saas's 11:00 landing is in it (no own landing excluded)" "${XROW}" '"to":"2026-10-02T11:00:00Z"'
has "... ten landings back from live_at, not from the 02:00 author date" "${XROW}" '"from":"2026-10-02T02:00:00Z"'
lacks "... and it is not provisional" "${XROW}" "provisional"
eq "list: exit 0" "$(sx run list --repo gen_saas)" "0"
has "list prints change_repo, commit and live_at" "$(out)" "${XID} PENDING kind=change metric=phase change_repo=custom commit=${XC:0:12} live_at=2026-10-02T11:30:00Z"
eq "judge: exit 0" "$(sx run judge --repo gen_saas)" "0"
has "judge: before/after from gen_saas's rows around live_at: KEEP 600 -> 500" "$(out)" "${XID} KEEP kind=change metric=phase change_repo=custom commit=${XC:0:12} live_at=2026-10-02T11:30:00Z"
has "... before = the ten up to 11:00, after = the ten from 12:00" "$(out)" "before n=10 median=600s p90=600s | after n=10 median=500s p90=500s"
has "... the guards read gen_saas's main" "$(out)" "reverts 0->0 ok"

echo "== cross-repo: live_at is the push that carried it, from custom's ledger"
STATEU="${TMP}/stateu"
mkdir -p "${STATEU}"
gs_ledger "${STATEU}/ledger.jsonl" "$(printf 'd%.0s' $(seq 40))" 500 2026-10-02T00:00:00Z
custom_rows "${STATEU}/ledger.jsonl"
su() { LEAD_TIME_STATE_DIR="${STATEU}" ATHENA_LEADTIME_CONFIG="${XCONF}" LEAD_TIME_EXPERIMENT_NOW=2026-10-03T12:00:00Z "$@"; }
eq "record with custom's ledger row ingested: exit 0" "$(su run record --repo gen_saas --change-repo custom --phase verify --metric phase --commit "${XC}" --kind change --hypothesis-file "${HYP}")" "0"
UROW="$(recrow "${STATEU}/experiments.jsonl" "${XID}")"
has "live_at is the 12:15 push, not the 11:50 landing that does not carry it, nor the 11:30 commit" "${UROW}" '"live_at":"2026-10-02T12:15:00Z"'
has "... from the ledger" "${UROW}" '"live_at_source":"ledger"'
has "... so gen_saas's 12:00 landing is in the before-set" "${UROW}" '"to":"2026-10-02T12:00:00Z"'
lacks "... and record warns of no fallback" "$(err)" "committer time"

echo "== cross-repo: a ledger landing git cannot check is could not look, never 'does not carry it'"
STATET="${TMP}/statet"
mkdir -p "${STATET}"
gs_ledger "${STATET}/ledger.jsonl" "$(printf 'd%.0s' $(seq 40))" 500 2026-10-02T00:00:00Z
UNSEEN="$(printf 'f%.0s' $(seq 40))"
printf '%s\n' "{\"schema\":1,\"repo\":\"custom\",\"mode\":\"improve\",\"ticket\":\"DND-9903\",\"landed_commit\":\"${UNSEEN}\",\"landed_at\":\"2026-10-02T12:00:00Z\",\"landed_via\":\"push\",\"phases\":{}}" >>"${STATET}/ledger.jsonl"
custom_rows "${STATET}/ledger.jsonl"
eq "record with an unknown landed commit before the carrier: exit 0" "$(LEAD_TIME_STATE_DIR="${STATET}" ATHENA_LEADTIME_CONFIG="${XCONF}" LEAD_TIME_EXPERIMENT_NOW=2026-10-03T12:00:00Z run record --repo gen_saas --change-repo custom --phase verify --metric phase --commit "${XC}" --kind change --hypothesis-file "${HYP}")" "0"
has "... the scan stops there: the committer fallback, never the later 12:15 row" "$(recrow "${STATET}/experiments.jsonl" "${XID}")" '"live_at":"2026-10-02T11:30:00Z","live_at_source":"committer"'
has "... and says it could not look" "$(err)" "could not look whether ${UNSEEN:0:12} carries it: ${UNSEEN:0:12} is not in"

echo "== cross-repo: judge moves a committer-time live_at to the ledger landing once ingested"
STATEV="${TMP}/statev"
mkdir -p "${STATEV}"
gs_ledger "${STATEV}/ledger.jsonl" "$(printf 'd%.0s' $(seq 40))" 500 2026-10-02T00:00:00Z
sv() { LEAD_TIME_STATE_DIR="${STATEV}" ATHENA_LEADTIME_CONFIG="${XCONF}" LEAD_TIME_EXPERIMENT_NOW=2026-10-03T12:00:00Z "$@"; }
eq "record before custom's landing is ingested: exit 0" "$(sv run record --repo gen_saas --change-repo custom --phase verify --metric phase --commit "${XC}" --kind change --hypothesis-file "${HYP}")" "0"
has "... on the committer fallback" "$(recrow "${STATEV}/experiments.jsonl" "${XID}")" '"live_at_source":"committer"'
custom_rows "${STATEV}/ledger.jsonl"
eq "judge after custom's landing is ingested: exit 0" "$(sv run judge --repo gen_saas)" "0"
has "judge splits at the 12:15 push" "$(out)" "change_repo=custom commit=${XC:0:12} live_at=2026-10-02T12:15:00Z |"
has "... so the after-set starts at 13:00: nine landings, pending" "$(out)" "after-set n=9 of K=10"
lacks "... and the record is not rewritten" "$(recrow "${STATEV}/experiments.jsonl" "${XID}")" "12:15"

echo "== cross-repo: same-repo is unchanged"
STATEY="${TMP}/statey"
STATEZ="${TMP}/statez"
mkdir -p "${STATEY}" "${STATEZ}"
cp "${STATE7}/ledger.jsonl" "${STATEY}/"
cp "${STATE7}/ledger.jsonl" "${STATEZ}/"
eq "custom on custom, no --change-repo: exit 0" "$(LEAD_TIME_STATE_DIR="${STATEY}" LEAD_TIME_EXPERIMENT_NOW=2026-10-01T12:00:00Z rec implement phase "${TBIN}" change)" "0"
eq "custom on custom, --change-repo custom: exit 0" "$(LEAD_TIME_STATE_DIR="${STATEZ}" LEAD_TIME_EXPERIMENT_NOW=2026-10-01T12:00:00Z run record --repo custom --change-repo custom --phase implement --metric phase --commit "${TBIN}" --kind change --hypothesis-file "${HYP}")" "0"
eq "... the two rows are byte-identical" "$(cmp -s "${STATEY}/experiments.jsonl" "${STATEZ}/experiments.jsonl" && echo same || echo differ)" "same"
lacks "... and carry no change_repo or live_at" "$(cat "${STATEY}/experiments.jsonl")" "live_at"

echo "== cross-repo: a revert lands in the change repo"
STATEW="${TMP}/statew"
mkdir -p "${STATEW}"
# TADD (a custom commit adding a test) landed 2026-09-30T11:00Z; gen_saas got slower after it.
gs_ledger "${STATEW}/ledger.jsonl" "$(printf 'e%.0s' $(seq 40))" 700 2026-09-30T00:00:00Z
sw() { LEAD_TIME_STATE_DIR="${STATEW}" ATHENA_LEADTIME_CONFIG="${XCONF}" LEAD_TIME_EXPERIMENT_NOW=2026-10-01T12:00:00Z "$@"; }
WID="gen_saas:verify:${TADD:0:12}"
eq "record TADD as a gen_saas experiment: exit 0" "$(sw run record --repo gen_saas --change-repo custom --phase verify --metric phase --commit "${TADD}" --kind change --hypothesis-file "${HYP}")" "0"
has "the test additions are read from the CHANGE repo's git" "$(recrow "${STATEW}/experiments.jsonl" "${WID}")" '"revert_deletes_tests":["ai/x/test/foo.sh"]'
eq "judge: exit 0" "$(sw run judge --repo gen_saas)" "0"
has "gen_saas rose 600 -> 700 after it went live: REVERT HELD" "$(out)" "${WID} REVERT HELD"
has "... the Fix reverts it in custom" "$(out)" "in custom: git revert --no-commit ${TADD}"
has "... decline is on the measured repo" "$(out)" "experiment decline --repo gen_saas --id ${WID}"
eq "re-judge: exit 0" "$(sw run judge --repo gen_saas)" "0"
has "custom's main carries the (partial) revert: REVERTED (read from the change repo, not gen_saas)" "$(out)" "${WID} REVERTED"

echo "== cross-repo: live_at is the first-parent landing"
"${G[@]}" checkout -q -b side
SIDE="$(GIT_AUTHOR_DATE=2026-10-04T01:00:00Z GIT_COMMITTER_DATE=2026-10-04T01:00:00Z "${G[@]}" commit -q --allow-empty -m "fixture: side work" && "${G[@]}" rev-parse HEAD)"
"${G[@]}" checkout -q main
GIT_AUTHOR_DATE=2026-10-04T09:00:00Z GIT_COMMITTER_DATE=2026-10-04T09:00:00Z "${G[@]}" merge -q --no-ff -m "fixture: merge side" side
MERGE="$("${G[@]}" rev-parse HEAD)"
LAND="$(/usr/bin/ruby -e 'require ARGV[0]; s = LeadTimeExperimentGit.landed_at(ARGV[1], ARGV[2]); puts(s.could_not_look? ? "could_not_look: #{s.reason}" : s.items.map { |c, t| "#{c} #{t.iso8601}" }.join(","))' \
  "${HERE}/../lib/experiment_git.rb" "${REPO}" "${SIDE}")"
eq "a merged side commit went live with its merge, at the merge's time" "${LAND}" "${MERGE} 2026-10-04T09:00:00Z"
LAND="$(/usr/bin/ruby -e 'require ARGV[0]; s = LeadTimeExperimentGit.landed_at(ARGV[1], ARGV[2]); puts(s.could_not_look? ? "could_not_look: #{s.reason}" : s.items.size.to_s)' \
  "${HERE}/../lib/experiment_git.rb" "${NOMAIN}" "${SIDE}")"
has "a repo with no main: could not look, never 'no landing'" "${LAND}" "could_not_look:"

# ── confounds: another experiment's trailer on the same phase (DND-1529) ───
echo "== confounded"
# custom's main gains, inside the experiment's window (the 6th, 01:00-21:00),
# the laptop's harness change on the same phase: its trailer names gen_saas,
# and this machine's store has never heard of it.
CF="$(commit 2026-10-06T11:00:00Z "fixture: a verify change measured here" "$(tr "custom verify phase")")"
CO="$(commit 2026-10-06T13:00:00Z "fixture: the laptop's harness change" "$(tr "gen_saas verify phase")")"
STATEC1="${TMP}/statec1"
mkdir -p "${STATEC1}"
/usr/bin/ruby "${HERE}/make_ledger.rb" "${STATEC1}/ledger.jsonl" "${CF}" 500 2026-10-06T00:00:00Z
sc1() { LEAD_TIME_STATE_DIR="${STATEC1}" LEAD_TIME_EXPERIMENT_NOW=2026-10-07T12:00:00Z "$@"; }
FID="custom:verify:${CF:0:12}"
eq "record the change: exit 0" "$(sc1 rec verify phase "${CF}" change)" "0"
has "... the ledger already holds its after-set, so record warns now that CO will confound it (DND-1622)" "$(err)" \
  "warning: ${FID} will read confounded: ${CO:0:12} (gen_saas verify phase"
eq "judge: exit 0" "$(sc1 run judge --repo custom)" "0"
has "regression: two trailers on one phase inside the window: CONFOUNDED" "$(out)" "${FID} CONFOUNDED kind=change"
has "... naming the other commit, its trailer and when it landed" "$(out)" "${CO:0:12} (gen_saas verify phase, 2026-10-06T13:00:00Z)"
has "... and what it would have read (never keep)" "$(out)" "treated as inconclusive (unconfounded it read keep"
has "... the tally is unchanged, with confounded counted on its own" "$(out)" "1 judged (0 pending, 0 keep, 0 revert, 0 inconclusive, 0 reverted); 1 status row(s) appended"
has "... 1 confounded" "$(out)" "1 confounded"
has "the status row records the confounder" "$(grep '"status":"confounded"' "${STATEC1}/experiments.jsonl")" "\"confounders\":[{\"commit\":\"${CO}\""
eq "re-judge: exit 0" "$(sc1 run judge --repo custom)" "0"
has "confounded is terminal: nothing is judged again" "$(out)" "0 judged"
eq "list: exit 0" "$(sc1 run list --repo custom)" "0"
has "list shows CONFOUNDED" "$(out)" "${FID} CONFOUNDED"
has "... and its confounders" "$(out)" "confounders: ${CO:0:12} (gen_saas verify phase"
eq "a commit whose trailer names another measured repo is refused for this one: exit 2" "$(sc1 rec verify phase "${CO}" change)" "2"
has "... naming what its trailer says" "$(err)" "trailer(s) name gen_saas verify phase, not custom verify phase"
CN="$(commit 2026-10-06T22:00:00Z "fixture: the next verify change" "$(tr "custom verify phase")")"
eq "confounded does not block its phase: a new change records, exit 0" "$(sc1 rec verify phase "${CN}" change)" "0"
has "... and record warns that it will read confounded, naming the trailer in its baseline (DND-1622)" "$(err)" \
  "warning: custom:verify:${CN:0:12} will read confounded: ${CO:0:12} (gen_saas verify phase"

echo "== not confounded"
# Inside the window (the 8th, 01:00-21:00): a trailer on another phase, a
# malformed trailer, and this experiment's own revert carrying its trailer.
CV="$(commit 2026-10-08T11:00:00Z "fixture: a verify change" "$(tr "custom verify phase")")"
CI="$(commit 2026-10-08T13:00:00Z "fixture: an implement change" "$(tr "custom implement phase")")"
CM="$(commit 2026-10-08T14:00:00Z "fixture: a hand-written trailer" "$(tr "custom")")"
commit 2026-10-08T15:00:00Z "Revert \"fixture: a verify change\"" "This reverts commit ${CV}.

$(tr "custom verify phase")" >/dev/null
STATEC2="${TMP}/statec2"
mkdir -p "${STATEC2}"
/usr/bin/ruby "${HERE}/make_ledger.rb" "${STATEC2}/ledger.jsonl" "${CV}" 500 2026-10-08T00:00:00Z
sc2() { LEAD_TIME_STATE_DIR="${STATEC2}" LEAD_TIME_EXPERIMENT_NOW=2026-10-09T12:00:00Z "$@"; }
eq "record: exit 0" "$(sc2 rec verify phase "${CV}" change)" "0"
lacks "... judge will read it unconfounded, so record prints no confound warning (DND-1622)" "$(err)" "will read confounded"
eq "judge: exit 0" "$(sc2 run judge --repo custom)" "0"
has "a trailer on another phase, and its own revert, have no effect: KEEP" "$(out)" "custom:verify:${CV:0:12} KEEP"
has "... 0 confounded" "$(out)" "0 confounded"
has "a malformed trailer in the window is named on stderr, not counted" "$(err)" "${CM:0:12} has a malformed Lead-time-experiment trailer \"custom\" (no phase after custom)"

echo "== record needs the trailer"
NOTR="$(commit 2026-10-08T16:00:00Z "fixture: a change landed with no trailer")"
RC2="$(grep -c '"type":"record"' "${STATEC2}/experiments.jsonl")"
eq "regression: a change commit with no trailer is refused: exit 2" "$(sc2 rec queue phase "${NOTR}" change)" "2"
has "... saying so" "$(err)" "${NOTR:0:12} carries no Lead-time-experiment trailer"
has "... the Fix names the line to carry and the format" "$(err)" 'Fix: every improver change and revert lands with the trailer line `Lead-time-experiment: custom queue phase` (format: Lead-time-experiment: <measured repo> <phase> <metric>)'
eq "an instrumentation commit with no trailer is refused too: exit 2" "$(sc2 rec implement na_share "${NOTR}" instrumentation)" "2"
eq "a trailer for another phase is refused: exit 2" "$(sc2 rec verify phase "${CI}" change)" "2"
has "... naming the trailer it carries" "$(err)" "name custom implement phase, not custom verify phase"
eq "... nothing written by any refusal" "$(grep -c '"type":"record"' "${STATEC2}/experiments.jsonl")" "${RC2}"
eq "the git adapter reads a bad repo path as could not look, never as no trailer" \
  "$(/usr/bin/ruby -e 'require ARGV[0]; s = LeadTimeExperimentGit.trailer_commits(ARGV[1], "2026-10-01T00:00:00Z"); puts s.could_not_look? ? "could_not_look" : "ok"' \
     "${HERE}/../lib/experiment_git.rb" "${TMP}/no-such-repo")" "could_not_look"

# ── settling: a clean baseline before a change lands (DND-1622) ─────────────
echo "== settling"
# STATEC1's ledger lands hourly on the 6th; at noon on the 7th the would-be
# before-set is 12:00-21:00 on the 6th. Inside it on custom's main: CO (the
# laptop's gen_saas verify change, 13:00) and CN (custom verify, 22:00 is
# after the last landing, so it needs all K).
eq "test 10: settling --json over trailered commits: exit 0" "$(sc1 run settling --repo custom --phase verify --json)" "0"
has "... the domain verdict: SETTLING" "$(out)" '"verdict":"SETTLING"'
has "... naming each confounder" "$(out)" "\"commit\":\"${CO}\""
has "... the latest, and the landings still needed" "$(out)" "\"latest\":{\"commit\":\"${CN}\""
has "... all K, since none has landed after it" "$(out)" '"needed":10'
has "... the metric defaults to phase" "$(out)" '"metric":"phase"'
eq "settling as text: exit 0" "$(sc1 run settling --repo custom --phase verify)" "0"
has "... one verdict line" "$(out)" "experiment settling: custom verify phase SETTLING"
has "... clean after N more" "$(out)" "clean after 10 more comparable landings"
NREC="$(grep -c . "${STATEC1}/experiments.jsonl")"
sc1 run settling --repo custom --phase verify >/dev/null 2>&1
eq "settling writes nothing to the store" "$(grep -c . "${STATEC1}/experiments.jsonl")" "${NREC}"
eq "another phase on the same fixture: exit 0" "$(sc1 run settling --repo custom --phase implement)" "0"
has "... CLEAN (no implement trailer in its window)" "$(out)" "experiment settling: custom implement phase CLEAN"
STATES="${TMP}/states"
mkdir -p "${STATES}"
# July: no fixture commit lands near it.
/usr/bin/ruby "${HERE}/make_ledger.rb" "${STATES}/ledger.jsonl" "$(printf 'c%.0s' $(seq 40))" 500 2026-07-01T00:00:00Z
eq "no trailer in the window: exit 0" "$(LEAD_TIME_STATE_DIR="${STATES}" LEAD_TIME_EXPERIMENT_NOW=2026-07-02T00:00:00Z run settling --repo custom --phase verify --json)" "0"
has "... CLEAN" "$(out)" '"verdict":"CLEAN"'
eq "five landings before now: exit 0" "$(LEAD_TIME_STATE_DIR="${STATES}" LEAD_TIME_EXPERIMENT_NOW=2026-07-01T05:30:00Z run settling --repo custom --phase verify)" "0"
has "... SHORT, with how many more reach K" "$(out)" "SHORT: before-set n=5 of K=10"
# The malformed trailer CM (the 8th, 14:00) sits in this window.
eq "a malformed trailer in the window: exit 0" "$(sc2 run settling --repo custom --phase verify)" "0"
has "... named as malformed, not counted (the miss)" "$(out)" "${CM:0:12} has a malformed Lead-time-experiment trailer \"custom\" (no phase after custom); it names no phase, so it is not counted as a confounder"
eq "test 11: an unreadable repo (no main): exit 3" "$(LEAD_TIME_STATE_DIR="${STATE2}" ATHENA_LEADTIME_CONFIG="${TMP}/nomain.json" run settling --repo custom --phase verify)" "3"
has "... could not look, never CLEAN" "$(err)" "could not look for confounders"
has "... with Fix:" "$(err)" "Fix:"
lacks "... no verdict printed" "$(out)" "CLEAN"
eq "no ledger: exit 3" "$(LEAD_TIME_STATE_DIR="${TMP}/no-state" run settling --repo custom --phase verify)" "3"
has "... could not look, with the ingest Fix" "$(err)" "lead-time-phases --ingest"
eq "settling with no --phase: exit 2" "$(run settling --repo custom)" "2"
has "... with Fix:" "$(err)" "Fix:"
eq "settling --metric na_share: exit 2 (instrumentation never waits)" "$(sc1 run settling --repo custom --phase verify --metric na_share)" "2"
has "... saying why, with Fix:" "$(err)" "never confounded"
eq "settling on a watch repo: exit 2" "$(run settling --repo gen_saas --phase verify)" "2"
# record's warning reads the same logs; one it cannot read leaves the record
# standing (exit 0, the row written) and says the baseline is unknown. Here
# the measured repo is a gen_saas checkout with no main.
XNGS="${TMP}/xn/gen_saas"
mkdir -p "${XNGS}"
env GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "${XNGS}" init -q -b main
printf '%s\n' "{\"repos\":[{\"name\":\"custom\",\"path\":\"${REPO}\",\"mode\":\"improve\"},{\"name\":\"gen_saas\",\"path\":\"${XNGS}\",\"mode\":\"improve\"}],\"window\":20,\"improvement_epic\":\"epic-id\"}" >"${TMP}/xn.json"
STATEXN="${TMP}/statexn"
mkdir -p "${STATEXN}"
gs_ledger "${STATEXN}/ledger.jsonl" "$(printf 'd%.0s' $(seq 40))" 500 2026-10-02T00:00:00Z
eq "record with a confound log it cannot read: still exit 0" \
  "$(LEAD_TIME_STATE_DIR="${STATEXN}" ATHENA_LEADTIME_CONFIG="${TMP}/xn.json" LEAD_TIME_EXPERIMENT_NOW=2026-10-03T12:00:00Z run record --repo gen_saas --change-repo custom --phase verify --metric phase --commit "${XC}" --kind change --hypothesis-file "${HYP}")" "0"
has "... warning that whether its baseline is clean is unknown" "$(err)" "gen_saas:verify:${XC:0:12} is recorded, but whether its baseline is clean is unknown"
has "... the row is in the store" "$(cat "${STATEXN}/experiments.jsonl")" "\"id\":\"gen_saas:verify:${XC:0:12}\""
eq "settling against that repo: exit 3, never CLEAN" "$(LEAD_TIME_STATE_DIR="${STATEXN}" ATHENA_LEADTIME_CONFIG="${TMP}/xn.json" run settling --repo gen_saas --phase verify)" "3"
eq "test 12: settling --help: exit 0" "$(run settling --repo custom --phase verify --help)" "0"
has "... on stdout, naming the verdicts" "$(out)" "SETTLING"
eq "... nothing on stderr (no reads)" "$(err)" ""

# ── tail: a product change judged on landing -> post-merge run (DND-1613) ───
echo "== tail"
# A product repo with post-merge CI (gen_saas-shaped, synthetic), configured
# improve beside custom. Its changes land in itself (DND-1542).
PGS="${TMP}/tl/gen_saas"
mkdir -p "${PGS}"
GP=(env GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid
    GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid git -C "${PGS}")
"${GP[@]}" init -q -b main
pcommit() { # AT SUBJECT [BODY]: stages the work tree, commits, prints the SHA
  "${GP[@]}" add -A && GIT_COMMITTER_DATE="$1" GIT_AUTHOR_DATE="$1" "${GP[@]}" commit -q --allow-empty -m "$2" ${3:+-m "$3"} \
    && "${GP[@]}" rev-parse HEAD
}
mkdir -p "${PGS}/.github/workflows" "${PGS}/apps/x/test"
printf 'jobs: {}\n' >"${PGS}/.github/workflows/deploy.yml"
TK="$(pcommit 2026-10-12T14:00:00Z "fixture: cache the deploy build" "$(tr "gen_saas tail phase")")"
printf 'jobs: {build: {}}\n' >"${PGS}/.github/workflows/deploy.yml"
TV="$(pcommit 2026-10-14T14:00:00Z "fixture: a slower deploy step" "$(tr "gen_saas tail phase")")"
printf 'defmodule T do end\n' >"${PGS}/apps/x/test/deploy_test.exs"
printf 'jobs: {build: {}, smoke: {}}\n' >"${PGS}/.github/workflows/deploy.yml"
TH="$(pcommit 2026-10-16T14:00:00Z "fixture: a deploy step with its test" "$(tr "gen_saas tail phase")")"
TNR="$(pcommit 2026-10-18T14:00:00Z "fixture: a change where no run concluded" "$(tr "gen_saas tail phase")")"
TCONF="${TMP}/tail.json"
printf '%s\n' "{\"repos\":[{\"name\":\"custom\",\"path\":\"${REPO}\",\"mode\":\"improve\"},{\"name\":\"gen_saas\",\"path\":\"${PGS}\",\"mode\":\"improve\"}],\"window\":20,\"improvement_epic\":\"epic-id\"}" >"${TCONF}"
# tl STATE NOW CMD...: runs CMD against that state dir and the tail config.
tl() { local st="$1" now="$2"; shift 2; LEAD_TIME_STATE_DIR="${st}" ATHENA_LEADTIME_CONFIG="${TCONF}" LEAD_TIME_EXPERIMENT_NOW="${now}" "$@"; }
trec() { run record --repo gen_saas --phase tail --metric "$1" --commit "$2" --kind "${3:-change}" --hypothesis-file "${HYP}"; }

STATETK="${TMP}/statetk"
mkdir -p "${STATETK}"
/usr/bin/ruby "${HERE}/make_tail_ledger.rb" "${STATETK}/ledger.jsonl" gen_saas "${TK}" 2400 2026-10-12T00:00:00Z
KID="gen_saas:tail:${TK:0:12}"
eq "tail on any metric but phase is refused: exit 2" "$(tl "${STATETK}" 2026-10-13T12:00:00Z trec lead "${TK}")" "2"
has "... naming tail and --metric phase" "$(err)" "tail is judged on --metric phase only"
eq "... instrumentation on tail too (na_share is not a tail metric)" "$(tl "${STATETK}" 2026-10-13T12:00:00Z trec na_share "${TK}" instrumentation)" "2"
eq "a tail change attributed to a custom commit (--change-repo) is refused: exit 2" \
  "$(tl "${STATETK}" 2026-10-13T12:00:00Z run record --repo gen_saas --change-repo custom --phase tail --metric phase --commit "${LANDING}" --kind change --hypothesis-file "${HYP}")" "2"
has "... naming the product lever" "$(err)" "a change on tail lands in gen_saas itself"
eq "record a product change on tail: exit 0" "$(tl "${STATETK}" 2026-10-13T12:00:00Z trec phase "${TK}")" "0"
has "the baseline is the ten measured tails before it" "$(out)" "${KID} kind=change metric=phase phase=tail"
has "... n=10 median 3600s" "$(out)" "baseline n=10 median=3600s p90=3600s"
has "... the three landings with no post-merge run are excluded with their reason, never 0" "$(out)" \
  "excluded 3 landing(s) in the window, never read as 0: tail: no post-merge run concluded for the landing (lead-time end kind merge); its 0s is not a measured tail (3)"
eq "judge: exit 0" "$(tl "${STATETK}" 2026-10-13T12:00:00Z run judge --repo gen_saas)" "0"
has "regression: a change recorded on tail splits before/after on measured tails: KEEP 3600 -> 2400" "$(out)" \
  "${KID} KEEP kind=change metric=phase | before n=10 median=3600s p90=3600s | after n=10 median=2400s p90=2400s"
has "... foreign landings count on tail (their tail is the forge's)" "$(out)" "after n=10"
has "... the six unmeasured landings in the window are named, never 0" "$(out)" "excluded 6 landing(s) in the window, never read as 0"
has "... with the pre-DND-1532 row named apart" "$(out)" "tail: the row was ingested before DND-1532 kept its end kind, so its 0s cannot be told apart from a landing whose run was never found (1)"
has "... the guards read gen_saas" "$(out)" "reverts 0->0 ok"
has "the status row records the exclusions" "$(grep '"status":"keep"' "${STATETK}/experiments.jsonl")" '"excluded":[{"reason":"tail: no post-merge run concluded'

STATETV="${TMP}/statetv"
mkdir -p "${STATETV}"
/usr/bin/ruby "${HERE}/make_tail_ledger.rb" "${STATETV}/ledger.jsonl" gen_saas "${TV}" 4000 2026-10-14T00:00:00Z
VID="gen_saas:tail:${TV:0:12}"
eq "record a tail change that slows the deploy: exit 0" "$(tl "${STATETV}" 2026-10-15T12:00:00Z trec phase "${TV}")" "0"
eq "judge: exit 0" "$(tl "${STATETV}" 2026-10-15T12:00:00Z run judge --repo gen_saas)" "0"
has "a rising tail is REVERT, as for any phase" "$(out)" "${VID} REVERT kind=change"
has "... its revert is a PR in gen_saas through its own bar (the product lane)" "$(out)" \
  "land the revert as a revert PR in gen_saas through its own bar (the product lane, DND-1540) with the trailer line \`Lead-time-experiment: gen_saas tail phase\`"
has "... the one-pending-per-phase rule holds: an owed tail revert blocks tail" \
  "$(tl "${STATETV}" 2026-10-15T12:00:00Z trec phase "${TNR}" >/dev/null; err)" "a change on tail owes a revert that has not landed: ${VID}"

STATETH="${TMP}/stateth"
mkdir -p "${STATETH}"
/usr/bin/ruby "${HERE}/make_tail_ledger.rb" "${STATETH}/ledger.jsonl" gen_saas "${TH}" 4000 2026-10-16T00:00:00Z
HTID="gen_saas:tail:${TH:0:12}"
eq "record a tail change that added a test in gen_saas: exit 0" "$(tl "${STATETH}" 2026-10-17T12:00:00Z trec phase "${TH}")" "0"
has "... record reads gen_saas's test paths (FirstParty.test_file_any_layout?)" "$(out)" "a plain revert would delete test additions in apps/x/test/deploy_test.exs"
eq "judge: exit 0" "$(tl "${STATETH}" 2026-10-17T12:00:00Z run judge --repo gen_saas)" "0"
has "REVERT HELD applies to the product repo's tests" "$(out)" "${HTID} REVERT HELD kind=change"
has "... the partial revert lands as a revert PR in gen_saas through its bar" "$(out)" \
  "and the trailer line \`Lead-time-experiment: gen_saas tail phase\` (DND-1529), landed as a revert PR in gen_saas through its own bar (the product lane, DND-1540))"

# Foreign landings on a phase experiment (DND-1628): the same ledger shape,
# judged on verify. Every other landing is foreign with its verify null; the
# judge leaves them out of the sides and names the count.
TF="$(pcommit 2026-10-20T14:00:00Z "fixture: a verify change" "$(tr "gen_saas verify phase")")"
STATETF="${TMP}/statetf"
mkdir -p "${STATETF}"
/usr/bin/ruby "${HERE}/make_tail_ledger.rb" "${STATETF}/ledger.jsonl" gen_saas "${TF}" 2400 2026-10-20T00:00:00Z
eq "record a phase change on a ledger with foreign landings: exit 0" \
  "$(tl "${STATETF}" 2026-10-21T12:00:00Z run record --repo gen_saas --phase verify --metric phase --commit "${TF}" --kind change --hypothesis-file "${HYP}")" "0"
has "record: the baseline names the foreign landings it left out" "$(out)" "left out 6 landing(s) worked on another machine (origin foreign)"
eq "judge: exit 0" "$(tl "${STATETF}" 2026-10-21T12:00:00Z run judge --repo gen_saas)" "0"
has "judge: the foreign landings are left out of both sides, counted, never an n/a reason" "$(out)" \
  "left out 11 landing(s) worked on another machine (origin foreign), as lead-time-phases --summary does"
lacks "... not tallied as an excluded n/a reason" "$(out)" "worked on another machine (no local events"

# A product repo's own test layouts (DND-1630): spec/, __tests__/ and a *.test.ts
# are test additions a plain revert would delete; the source change is not.
mkdir -p "${PGS}/spec" "${PGS}/web/__tests__"
printf 'x\n' >"${PGS}/spec/deploy_spec.rb"
printf 'x\n' >"${PGS}/web/__tests__/page.js"
printf 'x\n' >"${PGS}/web/button.test.ts"
printf 'jobs: {build: {}, smoke: {}, lint: {}}\n' >"${PGS}/.github/workflows/deploy.yml"
TL="$(pcommit 2026-10-22T14:00:00Z "fixture: a change with spec, __tests__ and .test.ts files" "$(tr "gen_saas tail phase")")"
STATETL="${TMP}/statetl"
mkdir -p "${STATETL}"
/usr/bin/ruby "${HERE}/make_tail_ledger.rb" "${STATETL}/ledger.jsonl" gen_saas "${TL}" 4000 2026-10-22T00:00:00Z
eq "record a change that added spec/, __tests__/ and *.test.ts files: exit 0" "$(tl "${STATETL}" 2026-10-23T12:00:00Z trec phase "${TL}")" "0"
has "... the record names all three test paths, not the workflow" "$(out)" \
  "a plain revert would delete test additions in spec/deploy_spec.rb, web/__tests__/page.js, web/button.test.ts"
lacks "... a source file is not a test" "$(out)" "deploy.yml"

STATETN="${TMP}/statetn"
mkdir -p "${STATETN}"
/usr/bin/ruby "${HERE}/make_tail_ledger.rb" "${STATETN}/ledger.jsonl" gen_saas "${TNR}" 2400 2026-10-18T00:00:00Z no-runs
eq "a repo where no landing in the window had a post-merge run: tail refused, exit 2" "$(tl "${STATETN}" 2026-10-19T12:00:00Z trec phase "${TNR}")" "2"
has "... naming the reasons it counted, never a 0 baseline" "$(err)" "none of gen_saas's last 20 landing(s) has a measured tail"
has "... with the reasons" "$(err)" "lead-time end kind merge"
has "... and a Fix:" "$(err)" "Fix:"
eq "... nothing written" "$(test -e "${STATETN}/experiments.jsonl" && echo yes || echo no)" "no"
eq "custom's ledger rows carry no tail end kind (ingested before DND-1532): could not look, exit 3" "$(rec tail phase "${NEWSHA}" change)" "3"
has "... saying could not look, not unmeasured" "$(err)" "could not look: none of custom's"

# ── a configured repo not on this machine (DND-1526) ────────────────────────
echo "== skipped on this machine"
printf '%s\n' "{\"repos\":[{\"name\":\"custom\",\"path\":\"${REPO}\",\"mode\":\"improve\"},{\"name\":\"gen_saas\",\"path\":\"${TMP}/gone/gen_saas\",\"mode\":\"improve\"}],\"window\":20,\"improvement_epic\":\"epic-id\"}" >"${TMP}/gone.json"
eq "judge on a skipped repo: exit 4" "$(LEAD_TIME_STATE_DIR="${STATE2}" ATHENA_LEADTIME_CONFIG="${TMP}/gone.json" run judge --repo gen_saas)" "4"
has "... saying skipped on this machine, with the reason" "$(err)" "gen_saas: skipped on this machine: no such path"
has "... with Fix:" "$(err)" "Fix:"
eq "record on a skipped repo: exit 4, nothing written" "$(LEAD_TIME_STATE_DIR="${STATE2}" ATHENA_LEADTIME_CONFIG="${TMP}/gone.json" run record --repo gen_saas --phase verify --metric phase --commit "${NEWSHA}" --kind change --hypothesis-file "${HYP}")" "4"
lacks "... no experiment recorded for it" "$(cat "${STATE2}/experiments.jsonl")" '"repo":"gen_saas"'
eq "an unconfigured repo is a refusal (exit 2), not a skip" "$(LEAD_TIME_STATE_DIR="${STATE2}" ATHENA_LEADTIME_CONFIG="${TMP}/gone.json" run judge --repo nope)" "2"
lacks "... and is not called skipped" "$(err)" "skipped on this machine"
eq "the retired LEAD_TIME_PHASES_CONFIG seam is refused, never ignored" "$(LEAD_TIME_PHASES_CONFIG="${TMP}/gone.json" run judge --repo custom)" "2"
has "... naming it" "$(err)" "LEAD_TIME_PHASES_CONFIG is retired"

echo
echo "lead-time-improve self-test: ${PASS} passed, ${FAIL} failed"
[ "${FAIL}" -eq 0 ] || { echo "Fix: read the FAIL lines above; each names the case and what it expected."; exit 1; }
exit 0
