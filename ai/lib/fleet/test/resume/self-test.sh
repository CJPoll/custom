#!/usr/bin/env bash
# self-test.sh -- the fleet-resume suite (DND-443, critic round 3). Discovered by
# harness-gate and run by `ai/bin/fleet-resume --self-test`. Temp dirs only.
#
# The invariant under test: at most one admiral owns a run. So the cases that
# matter are the MISSES and the RACES:
#   - two resume triggers at once (the control_changed inbox line AND a draining
#     admiral's hand-back) claim each drained run exactly once;
#   - a marker that is reformatted (a timestamp prefix, a list bullet) is LOUD,
#     never silently skipped (that would be a run never resumed);
#   - a marker copied from another run's log is refused.

set -u

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
LIB="$(cd -- "${HERE}/../.." && pwd -P)"
AI="$(cd -- "${LIB}/../.." && pwd -P)"
BIN="${AI}/bin/fleet-resume"

PASS=0
FAIL=0
ok()   { PASS=$((PASS + 1)); printf 'ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL + 1)); printf 'FAIL %s\n' "$1"; [ -n "${2:-}" ] && printf '     %s\n' "$2"; return 0; }
eq()   { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$3], got [$2]"; fi; }
has()  { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "[$3] not in [$2]" ;; esac; }

for dep in git flock find timeout; do
  command -v "${dep}" >/dev/null 2>&1 || { echo "fleet-resume self-test: FAIL -- ${dep} is not on PATH"; echo "  Fix: install ${dep}; this suite does not skip."; exit 1; }
done

# shellcheck source=../../domain.sh
. "${LIB}/domain.sh"
# shellcheck source=../../resume-domain.sh
. "${LIB}/resume-domain.sh"

TMP="$(mktemp -d)" || { echo "FAIL mktemp"; exit 1; }
trap 'rm -rf "${TMP}"' EXIT INT TERM
ROOT="${TMP}/coordination"
S="0cc59a5e-6c65-495e-a216-83c6a0bf2d56"
OTHER="11111111-2222-3333-4444-555555555555"
fr() { "${BIN}" "$@" --session-id "${S}" --root "${ROOT}"; }
newrun() { mkdir -p "${ROOT}/$1"; printf '# state\n\n## Mission state\n\n## Log\n- 10:00Z started\n' > "${ROOT}/$1/state.md"; }
resumed_count() { grep -c "^RESUMED session=${S} run=$1 " "${ROOT}/$1/state.md"; }

echo "== domain"
L="$(fleet_marker_line DRAINED "${S}" run-a 2026-09-24T10:00:00Z)"
eq "the pinned line format" "${L}" "DRAINED session=${S} run=run-a at=2026-09-24T10:00:00Z"
eq "last marker: none" "$(fleet_marker_last "${S}" run-a "")" none
eq "last marker: DRAINED" "$(fleet_marker_last "${S}" run-a "${L}")" DRAINED
eq "last marker: RESUMED after DRAINED" "$(fleet_marker_last "${S}" run-a "${L}
$(fleet_marker_line RESUMED "${S}" run-a 2026-09-24T11:00:00Z)")" RESUMED
eq "another session's marker is not ours" "$(fleet_marker_last "${S}" run-a "$(fleet_marker_line DRAINED "${OTHER}" run-a 2026-09-24T10:00:00Z)")" none
for m in "- ${L}" "- 12:00Z ${L}" "12:00Z ${L}" "${L} (by hand)" "DRAINED  session=${S} run=run-a at=2026-09-24T10:00:00Z" \
         "DRAINED session=${S} run=run-a at=2026-09-24 10:00" "**DRAINED** session=${S} run=run-a at=2026-09-24T10:00:00Z"; do
  if out="$(fleet_marker_last "${S}" run-a "${m}")"; then bad "a reformatted marker is refused: ${m}" "accepted as ${out}"
  else has "a reformatted marker is refused: ${m}" "${out}" "is not exactly"; fi
done
if out="$(fleet_marker_last "${S}" run-a "$(fleet_marker_line DRAINED "${S}" run-b 2026-09-24T10:00:00Z)")"; then
  bad "a marker naming another run is refused" "accepted"
else has "a marker naming another run is refused" "${out}" "names run run-b"; fi
check_candidate() { [[ "$1" =~ ${FLEET_MARKER_CANDIDATE_RE} ]]; }
if check_candidate "- 12:00Z DRAINED session=x"; then ok "the loose pattern sees a timestamp-prefixed marker"; else bad "the loose pattern sees a timestamp-prefixed marker"; fi
if check_candidate "the drain protocol DRAINED nothing"; then bad "narrative prose is not a candidate"; else ok "narrative prose is not a candidate"; fi

echo "== drained / status / claim"
newrun r1
out="$(fr status --run-id r1)"; eq "status on a fresh run: exit 0" "$?" 0
has "status on a fresh run: none" "${out}" ": none"
out="$(fr drained --run-id r1)"; eq "drained: exit 0" "$?" 0
eq "drained: exactly one pinned line appended" "$(grep -cE "${FLEET_MARKER_RE}" "${ROOT}/r1/state.md")" 1
has "drained: the line is last and exact" "$(tail -n 1 "${ROOT}/r1/state.md")" "DRAINED session=${S} run=r1 at="
fr drained --run-id r1 >/dev/null; eq "drained twice is idempotent (still one line)" "$(grep -c '^DRAINED ' "${ROOT}/r1/state.md")" 1
has "status: DRAINED" "$(fr status --run-id r1)" ": DRAINED"
out="$(fr claim)"; eq "claim: exit 0" "$?" 0
has "claim: CLAIMED r1" "${out}" "CLAIMED run=r1 state=${ROOT}/r1/state.md"
has "claim: the summary names what was considered" "${out}" "considered 1 state log(s) under ${ROOT}; claimed 1"
eq "claim appended RESUMED before any spawn" "$(resumed_count r1)" 1
has "status after the claim: RESUMED (what the spawned admiral confirms)" "$(fr status --run-id r1)" ": RESUMED"
out="$(fr claim)"
has "a second trigger claims nothing" "${out}" "claimed 0"
eq "... and appends nothing" "$(resumed_count r1)" 1
fr drained --run-id r1 >/dev/null
has "a release (drained after a failed spawn) makes it claimable again" "$(fr claim)" "CLAIMED run=r1"
out="$("${BIN}" claim --session-id "${OTHER}" --root "${ROOT}")"
has "another session claims nothing of ours" "${out}" "claimed 0"

echo "== the race: the inbox line and the hand-back arrive together"
for i in $(seq 1 20); do newrun "race-${i}"; fr drained --run-id "race-${i}" >/dev/null; done
fr claim > "${TMP}/c1" 2>&1 &
p1=$!
fr claim > "${TMP}/c2" 2>&1 &
p2=$!
timeout 60 tail --pid="${p1}" -f /dev/null
timeout 60 tail --pid="${p2}" -f /dev/null
wait "${p1}"; r1=$?
wait "${p2}"; r2=$?
eq "both claimers exit 0" "${r1}:${r2}" "0:0"
eq "20 drained runs, 20 claims in total across both triggers" "$(cat "${TMP}/c1" "${TMP}/c2" | grep -c '^CLAIMED run=race-')" 20
eq "no run claimed twice" "$(cat "${TMP}/c1" "${TMP}/c2" | grep -o '^CLAIMED run=race-[0-9]*' | sort | uniq -d | grep -c .)" 0
twice=0
for i in $(seq 1 20); do [ "$(resumed_count "race-${i}")" -eq 1 ] || twice=$((twice + 1)); done
eq "every race run has exactly one RESUMED line" "${twice}" 0

echo "== a malformed marker is loud, never a silent skip"
newrun bad1
printf -- '- 12:00Z DRAINED session=%s run=bad1 at=2026-09-24T12:00:00Z\n' "${S}" >> "${ROOT}/bad1/state.md"
newrun good1; fr drained --run-id good1 >/dev/null
out="$(fr claim 2>"${TMP}/err")"; rc=$?
eq "claim with a malformed log: exit 4" "${rc}" 4
has "... the good run is still claimed" "${out}" "CLAIMED run=good1"
has "... the summary counts the unjudged log" "${out}" "could not judge 1"
has "... stderr names the run and the line, with Fix:" "$(cat "${TMP}/err")" "claim skipped bad1"
has "... and carries Fix:" "$(cat "${TMP}/err")" "Fix:"
eq "... nothing appended to the malformed log" "$(grep -c '^RESUMED' "${ROOT}/bad1/state.md")" 0
fr drained --run-id bad1 >/dev/null 2>"${TMP}/err"; eq "drained on a malformed log: exit 4" "$?" 4
fr status --run-id bad1 >/dev/null 2>&1; eq "status on a malformed log: exit 4" "$?" 4
newrun copied
fleet_marker_line DRAINED "${S}" other-run 2026-09-24T12:00:00Z >> "${ROOT}/copied/state.md"
fr status --run-id copied >/dev/null 2>"${TMP}/err"; eq "a marker copied from another run: exit 4" "$?" 4
has "... named" "$(cat "${TMP}/err")" "names run other-run"

echo "== misses"
fr drained --run-id no-such-run >/dev/null 2>"${TMP}/err"; eq "drained for a run with no state log: exit 1" "$?" 1
has "... with Fix:" "$(cat "${TMP}/err")" "Fix:"
"${BIN}" claim --session-id "${S}" --root "${TMP}/nope" >/dev/null 2>"${TMP}/err"; eq "claim with a missing root: exit 1, never 'nothing drained'" "$?" 1
( unset CLAUDE_CODE_SESSION_ID; "${BIN}" claim --root "${ROOT}" >/dev/null 2>&1 ); eq "no session id: exit 2" "$?" 2
"${BIN}" claim --run-id r1 --session-id "${S}" --root "${ROOT}" >/dev/null 2>&1; eq "claim --run-id: exit 2" "$?" 2
"${BIN}" status --session-id "${S}" --root "${ROOT}" >/dev/null 2>&1; eq "status without --run-id: exit 2" "$?" 2
"${BIN}" status --run-id ../x --session-id "${S}" --root "${ROOT}" >/dev/null 2>&1; eq "an unsafe run id: exit 2" "$?" 2
"${BIN}" status --run-id r1 --session-id "${S}" --root rel >/dev/null 2>&1; eq "a relative root: exit 2" "$?" 2
newrun nl; printf 'last line without newline' >> "${ROOT}/nl/state.md"
fr drained --run-id nl >/dev/null
has "a marker never glues onto a line without a newline" "$(tail -n 1 "${ROOT}/nl/state.md")" "DRAINED session=${S} run=nl"
out="$("${BIN}" --help)"; eq "--help exits 0" "$?" 0
has "--help pins the line format" "${out}" "DRAINED session=<id> run=<run-id> at=<ISO 8601 UTC>"
eq "default root resolves to the MAIN checkout's coordination dir" \
  "$(bash -c '. "$0"; . "$1"; . "$2"; fleet_coordination_root "$3"' "${LIB}/domain.sh" "${LIB}/resume-domain.sh" "${LIB}/resume-effects.sh" "${AI}")" \
  "$(realpath "$(git -C "${AI}" rev-parse --path-format=absolute --git-common-dir)" | sed 's|/\.git$||')/ai-artifacts/coordination"

echo
echo "${PASS} passed, ${FAIL} failed"
if [ "${FAIL}" -ne 0 ]; then
  echo "fleet-resume self-test: FAIL"
  echo "  Fix: read the FAIL lines above; each names the ownership rule it checks (athena:fleet-drain -> Resume)."
  exit 1
fi
echo "fleet-resume self-test: OK"
