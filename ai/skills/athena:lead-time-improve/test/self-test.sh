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
LANDING="$(commit 2026-09-01T00:00:00Z "fixture: landing")"
OTHER="$(commit 2026-09-01T00:01:00Z "fixture: other")"
NEWSHA="$(commit 2026-09-01T00:02:00Z "fixture: not ingested yet")"
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
eq "re-judge: exit 0" "$(s3 run judge --repo custom)" "0"
has "the revert is OWED while main lacks it" "$(out)" "REVERT OWED"
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
DECL="$(commit 2026-09-24T11:00:00Z "fixture: a fixture fix a revert would delete")"
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
WORSE="$(commit 2026-09-26T11:00:00Z "fixture: a change whose window saw a revert")"
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
CHK="$(commit 2026-09-28T11:00:00Z "fixture: a one-check fix")"
CID="custom:verify:${CHK:0:12}"
WAITL="self-test: fixture/control/wait"
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
eq "judge with no main to read: exit 0" "$(LEAD_TIME_STATE_DIR="${STATE2}" ATHENA_LEADTIME_CONFIG="${TMP}/nomain.json" run judge --repo custom)" "0"
has "no keep while reverts could not be read" "$(out)" "custom:verify:${SHORT} PENDING"
has "... and it says the guard is unmeasured" "$(out)" "reverts unmeasured"

# ── revert held: a plain revert would delete test additions (DND-1549) ─────
echo "== revert held"
# commit_files AT SUBJECT -> stages the work tree, commits, prints the SHA
commit_files() {
  "${G[@]}" add -A && GIT_COMMITTER_DATE="$1" GIT_AUTHOR_DATE="$1" "${G[@]}" commit -q -m "$2" \
    && "${G[@]}" rev-parse HEAD
}
mkdir -p "${REPO}/ai/x/test" "${REPO}/ai/bin"
printf 'echo one\necho two\n' >"${REPO}/ai/x/test/foo.sh"
printf 'echo fixed\n' >"${REPO}/ai/x/fix.sh"
TADD="$(commit_files 2026-09-30T11:00:00Z "fixture: a fix with its regression test")"
printf 'echo tool\n' >"${REPO}/ai/bin/x"
TBIN="$(commit_files 2026-09-30T11:01:00Z "fixture: a tool-only change")"
printf 'echo one\n' >"${REPO}/ai/x/test/foo.sh"
TDEL="$(commit_files 2026-09-30T11:02:00Z "fixture: a change that only deletes a test line")"
mkdir -p "${REPO}/ai/y/test"
"${G[@]}" mv ai/x/test/foo.sh ai/y/test/foo.sh
TREN="$(commit_files 2026-09-30T11:03:00Z "fixture: a test moved to a new path")"
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
