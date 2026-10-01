#!/usr/bin/env bash
# Self-test for ai/bin/main-health (DND-1482).
#
# The gap this pins: ~/dev/custom has no CI and lands by a clean rebase plus a
# fast-forward push with no re-gate (owner decision D5, DND-1463). Two clean
# landings can combine into a red origin/main, and nothing re-ran the gate on
# it, so the red went unseen until the next branch gate tripped over it.
# main-health gates origin/main after a landing, records a per-SHA verdict,
# keeps a red marker while the tip is RED (the push guard refuses on it; its
# cases are in ai/test/gh-athena/self-test.sh), and alerts once per red episode.
#
# Hermetic: fixture repos only, the global git config replaced, the gate is a
# stub committed INTO the fixture's origin/main (main-health runs the landed
# tree's own ai/bin/harness-gate), and test-slot and send-mail are stubs
# reached through main-health's two documented seams.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AI_DIR="$(cd "${HERE}/../.." && pwd)"
TOOL="${MAIN_HEALTH_UNDER_TEST:-${AI_DIR}/bin/main-health}"

T="$(mktemp -d)"; trap 'rm -rf "${T}"' EXIT
PASS=0; FAIL=0
ok()  { printf '  ok    %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  FAIL  %s\n        %s\n' "$1" "$2"; FAIL=$((FAIL+1)); }

export GIT_CONFIG_NOSYSTEM=1
export GIT_CONFIG_GLOBAL="${T}/gitconfig"
printf '[user]\n\tname = t\n\temail = t@t\n[init]\n\tdefaultBranch = main\n' > "${GIT_CONFIG_GLOBAL}"
export GIT_TERMINAL_PROMPT=0
unset GIT_CONFIG_COUNT

# --- stubs --------------------------------------------------------------------
# test-slot: record argv, honour --outcome-file, run what follows `--`.
# MH_SLOT_MODE=timeout plays a slot that never came free (exit 75, CMD never ran).
cat > "${T}/test-slot" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${MH_T}/slot.log"
of=""
while [ $# -gt 0 ] && [ "$1" != "--" ]; do
  [ "$1" = "--outcome-file" ] && { of="$2"; shift; }
  shift
done
shift
if [ "${MH_SLOT_MODE:-}" = timeout ]; then
  [ -n "$of" ] && printf 'timeout\n' > "$of"
  echo "test-slot: TIMEOUT" >&2; exit 75
fi
"$@"; rc=$?
[ -n "$of" ] && printf 'ran exit=%s\n' "$rc" > "$of"
exit "$rc"
EOF
# send-mail: record argv and body; MH_MAIL_FAIL=1 plays a failed send.
cat > "${T}/send-mail" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${MH_T}/mail.log"
[ "${MH_MAIL_FAIL:-}" = 1 ] && { echo "send-mail: simulated failure" >&2; exit 1; }
# MH_MAIL_QUIET=1 plays a send that exits 0 but prints no delivered line (DND-1513).
[ "${MH_MAIL_QUIET:-}" = 1 ] && { echo "athena:inbox: path: local -- stub"; exit 0; }
while [ $# -gt 0 ]; do
  [ "$1" = "--body-file" ] && cp "$2" "${MH_T}/mail-body"
  shift
done
echo "athena:inbox: path: local -- stub"
echo "athena:inbox: delivered 20261001T000000Z-stub-main-red.md"
EOF
chmod +x "${T}/test-slot" "${T}/send-mail"
export MH_T="${T}"
export MAIN_HEALTH_TEST_SLOT="${T}/test-slot"
export MAIN_HEALTH_SEND_MAIL="${T}/send-mail"

# --- fixture --------------------------------------------------------------------
# A bare origin and a clone W. Every commit on origin/main carries a stub gate
# whose exit code is the committed file gate-rc.
O="${T}/origin.git"; W="${T}/w"
git init -q --bare -b main "${O}"
git init -q -b main "${W}"
mkdir -p "${W}/ai/bin"
printf '#!/bin/sh\necho "stub gate ran in $(pwd)"\nexit "$(cat gate-rc)"\n' > "${W}/ai/bin/harness-gate"
chmod +x "${W}/ai/bin/harness-gate"
COMMON="$(cd "${W}" && pwd -P)/.git"
STORE="${COMMON}/main-health"

# land <gate-rc> : commit a tree whose gate exits <gate-rc>, push it to origin
# main, and print the new SHA.
# Each landing writes a fresh landing-n, so two landings with one gate-rc are
# still two commits (land runs in a $(...) subshell, so no shell counter).
land() {
  printf '%s\n' "$1" > "${W}/gate-rc"
  printf '%s\n' "$(( $(git -C "${W}" rev-list --count HEAD 2>/dev/null || echo 0) + 1 ))" > "${W}/landing-n"
  git -C "${W}" add -A && git -C "${W}" commit -q -m "gate-rc $1" \
    && git -C "${W}" push -q origin HEAD:main 2>/dev/null
  git -C "${W}" rev-parse HEAD
}
git -C "${W}" remote add origin "${O}"

run() { # run <args...> -> OUT ERR RC
  OUT="$("${TOOL}" "$@" 2>"${T}/err")"; RC=$?; ERR="$(cat "${T}/err")"
}
slot_n() { [ -f "${T}/slot.log" ] && grep -c . "${T}/slot.log" || echo 0; }
mail_n() { [ -f "${T}/mail.log" ] && grep -c . "${T}/mail.log" || echo 0; }
kv() { sed -n "s/^$2=//p" "$1" 2>/dev/null | tail -n 1; }
lanes_left() { git -C "${W}" worktree list --porcelain | grep -c 'main-health-lanes' || true; }

echo "main-health self-test"
echo "tool: ${TOOL}"
echo

echo "--- help ---"
OUT="$("${TOOL}" --help)"; RC=$?
[ "${RC}" = 0 ] && [[ "${OUT}" == *"main-health check"* ]] && [ ! -e "${STORE}" ] \
  && ok "1. --help: stdout, exit 0, nothing written" || bad "1. --help" "rc=${RC} out='${OUT}'"

echo "--- a green tip ---"
G1="$(land 0)"
run check --repo "${W}"
[ "${RC}" = 0 ] && [ "$(kv "${STORE}/verdicts/${G1}" verdict)" = green ] \
  && [ "$(kv "${STORE}/verdicts/${G1}" source)" = gate ] && [ ! -e "${STORE}/red" ] \
  && ok "2. green tip: exit 0, a green verdict from the gate, no red marker" \
  || bad "2. green tip" "rc=${RC} out='${OUT}' err='${ERR}'"
grep -q -- '--label main-health' "${T}/slot.log" && grep -q -- '-- timeout 1500 ./ai/bin/harness-gate' "${T}/slot.log" \
  && ok "3. the gate runs the landed tree's own ai/bin/harness-gate, under test-slot, bounded by timeout" \
  || bad "3. slot argv" "$(cat "${T}/slot.log")"
[ "$(lanes_left)" = 0 ] && [ -z "$(command ls -A "${COMMON}/main-health-lanes" 2>/dev/null)" ] \
  && ok "4. the short-lived lane is removed after the run" || bad "4. lane removed" "$(git -C "${W}" worktree list)"

N="$(slot_n)"; run check --repo "${W}"
[ "${RC}" = 0 ] && [ "$(slot_n)" = "${N}" ] && [[ "${OUT}" == *"already checked"* ]] \
  && ok "5. a tip already checked is not re-gated (one gate per SHA)" \
  || bad "5. cached verdict" "rc=${RC} slots=$(slot_n) out='${OUT}'"

echo "--- a red tip: marker + one alert per episode ---"
R1="$(land 1)"
run check --repo "${W}"
[ "${RC}" = 1 ] && [ "$(kv "${STORE}/red" sha)" = "${R1}" ] && [ "$(kv "${STORE}/verdicts/${R1}" verdict)" = red ] \
  && [[ "${OUT}${ERR}" == *"RED"* ]] && [[ "${ERR}" == *"Fix:"* ]] \
  && ok "6. red tip: exit 1, red verdict, red marker naming the SHA, Fix:" \
  || bad "6. red tip" "rc=${RC} out='${OUT}' err='${ERR}'"
[ "$(mail_n)" = 1 ] && grep -q -- "--local harness-alerts-detector main-red --to custom --re ${STORE}/verdicts/${R1}" "${T}/mail.log" \
  && grep -q "^sha: ${R1}$" "${T}/mail-body" && [ "$(kv "${STORE}/red" alert)" = 20261001T000000Z-stub-main-red.md ] \
  && ok "7. one harness-alerts message, re: the verdict record, body names the SHA; the marker records it" \
  || bad "7. alert" "mail=$(cat "${T}/mail.log" 2>/dev/null) body=$(cat "${T}/mail-body" 2>/dev/null)"
[ -s "$(kv "${STORE}/verdicts/${R1}" log)" ] && grep -q 'stub gate ran' "$(kv "${STORE}/verdicts/${R1}" log)" \
  && ok "8. the verdict record names the gate log, which holds the gate's output" \
  || bad "8. log" "$(cat "${STORE}/verdicts/${R1}" 2>/dev/null)"

run check --repo "${W}"
[ "${RC}" = 1 ] && [ "$(mail_n)" = 1 ] && ok "9. re-checking the same red tip sends no second alert" \
  || bad "9. no repeat alert" "rc=${RC} mails=$(mail_n)"

run status --repo "${W}"
[ "${RC}" = 1 ] && [[ "${OUT}" == *"RED ${R1}"* ]] && [[ "${ERR}" == *"Fix:"* ]] && ok "10. status: exit 1, RED <sha>, Fix:" \
  || bad "10. status red" "rc=${RC} out='${OUT}'"

R2="$(land 1)"
run check --repo "${W}"
[ "${RC}" = 1 ] && [ "$(kv "${STORE}/red" sha)" = "${R2}" ] && [ "$(kv "${STORE}/red" first_red)" = "${R1}" ] \
  && [ "$(mail_n)" = 1 ] \
  && ok "11. a newer red tip in the same episode: marker moves to it, keeps first_red, no new alert" \
  || bad "11. red episode continues" "rc=${RC} red=$(cat "${STORE}/red") mails=$(mail_n)"

mv "${STORE}/red" "${T}/red.saved"
run status --repo "${W}"
[ "${RC}" = 1 ] && [[ "${OUT}" == *"MISSING"* ]] && [[ "${ERR}" == *"Fix:"* ]] \
  && ok "11b. status: a red verdict with no marker is exit 1 (marker MISSING), never 'no red known'" \
  || bad "11b. missing marker" "rc=${RC} out='${OUT}' err='${ERR}'"
mv "${T}/red.saved" "${STORE}/red"

N="$(slot_n)"; run check --repo "${W}" --recheck --slot-wait 77
[ "${RC}" = 1 ] && [ "$(slot_n)" = "$((N + 1))" ] && grep -q -- '--wait-timeout 77 ' <<<"$(tail -n 1 "${T}/slot.log")" \
  && ok "12. --recheck re-gates a tip that already has a verdict; --slot-wait reaches test-slot" \
  || bad "12. recheck" "rc=${RC} slots=$(slot_n) was ${N}"

echo "--- the fix clears the marker ---"
G2="$(land 0)"
run check --repo "${W}"
[ "${RC}" = 0 ] && [ ! -e "${STORE}/red" ] && [[ "${OUT}" == *"cleared"* ]] \
  && ok "13. a green tip clears the red marker" || bad "13. clear" "rc=${RC} out='${OUT}' err='${ERR}'"
run status --repo "${W}"
[ "${RC}" = 0 ] && [[ "${OUT}" == *"${G2}"* ]] && [[ "${OUT}" == *green* ]] \
  && ok "14. status: exit 0, names the tip and its green verdict" || bad "14. status green" "rc=${RC} out='${OUT}'"

echo "--- a tip integration-gate already passed is green without a gate run ---"
printf '1\n' > "${W}/gate-rc"; git -C "${W}" add -A; git -C "${W}" commit -q -m "receipt-covered"
P="$(git -C "${W}" rev-parse HEAD)"
mkdir -p "${COMMON}/integration-receipts"
printf '{"schema":"integration-receipt/1","verdict":"pass","head":"%s","base":"%s","target_ref":"origin/main","recorded_at":"2026-10-01T00:00:00Z"}\n' \
  "${P}" "${G2}" > "${COMMON}/integration-receipts/${P}.json"
git -C "${W}" push -q origin HEAD:main 2>/dev/null
N="$(slot_n)"; run check --repo "${W}"
[ "${RC}" = 0 ] && [ "$(slot_n)" = "${N}" ] && [ "$(kv "${STORE}/verdicts/${P}" source)" = receipt ] \
  && ok "15. a tip with integration-gate's pass receipt for exactly itself: green, source=receipt, no gate run" \
  || bad "15. receipt shortcut" "rc=${RC} slots=$(slot_n) was ${N} out='${OUT}' err='${ERR}'"

echo "--- no verdict is ever invented ---"
U1="$(land 6)"
run check --repo "${W}"
[ "${RC}" = 3 ] && [ ! -e "${STORE}/verdicts/${U1}" ] && [ ! -e "${STORE}/red" ] && [[ "${ERR}" == *"COULD NOT MEASURE"* ]] \
  && [[ "${ERR}" == *"Fix:"* ]] \
  && ok "16. a gate exit that is neither pass (0) nor fail (1): exit 3, COULD NOT MEASURE, no verdict, no marker" \
  || bad "16. unknown gate exit" "rc=${RC} err='${ERR}' $(command ls "${STORE}/verdicts")"
U2="$(land 1)"
MH_SLOT_MODE=timeout run check --repo "${W}"
[ "${RC}" = 3 ] && [ ! -e "${STORE}/verdicts/${U2}" ] && [ ! -e "${STORE}/red" ] && [[ "${ERR}" == *"never ran"* ]] \
  && ok "17. test-slot timed out: exit 3, the gate never ran, no verdict" \
  || bad "17. slot timeout" "rc=${RC} err='${ERR}'"

echo "--- a failed alert is retried, never recorded as sent ---"
MH_MAIL_FAIL=1 run check --repo "${W}"
M="$(mail_n)"
[ "${RC}" = 1 ] && [ "$(kv "${STORE}/red" alert)" = FAILED ] && [[ "${ERR}" == *"could NOT be sent"* ]] \
  && ok "18. alert send failed: still exit 1 (red), marker alert=FAILED, loud" \
  || bad "18. failed alert" "rc=${RC} red=$(cat "${STORE}/red" 2>/dev/null) err='${ERR}'"
run check --repo "${W}"
[ "${RC}" = 1 ] && [ "$(mail_n)" = "$((M + 1))" ] && [ "$(kv "${STORE}/red" alert)" = 20261001T000000Z-stub-main-red.md ] \
  && ok "19. the next check retries the alert and records it" \
  || bad "19. alert retry" "rc=${RC} mails=$(mail_n) red=$(cat "${STORE}/red")"

echo "--- exit 0 with no delivered line is not a send (DND-1513) ---"
rm -f "${STORE}/red"
M="$(mail_n)"
MH_MAIL_QUIET=1 run check --repo "${W}"
[ "${RC}" = 1 ] && [ "$(mail_n)" = "$((M + 1))" ] && [ "$(kv "${STORE}/red" alert)" = FAILED ] \
  && [[ "${ERR}" == *"no 'athena:inbox: delivered' line"* ]] && [[ "${ERR}" == *"could NOT be sent"* ]] \
  && ok "19a. send-mail exits 0 with no delivered line: alert=FAILED (never '?'), loud, still exit 1" \
  || bad "19a. quiet send" "rc=${RC} red=$(cat "${STORE}/red" 2>/dev/null) err='${ERR}'"
run check --repo "${W}"
[ "${RC}" = 1 ] && [ "$(mail_n)" = "$((M + 2))" ] && [ "$(kv "${STORE}/red" alert)" = 20261001T000000Z-stub-main-red.md ] \
  && ok "19b. the next check retries the unconfirmed alert and records the delivered name" \
  || bad "19b. quiet retry" "rc=${RC} mails=$(mail_n) red=$(cat "${STORE}/red" 2>/dev/null)"
sed -i 's/^alert=.*/alert=?/' "${STORE}/red"
run check --repo "${W}"
[ "${RC}" = 1 ] && [ "$(mail_n)" = "$((M + 3))" ] && [ "$(kv "${STORE}/red" alert)" = 20261001T000000Z-stub-main-red.md ] \
  && ok "19c. a marker an older main-health wrote as alert=? is unconfirmed: the next check retries it" \
  || bad "19c. legacy alert=?" "rc=${RC} mails=$(mail_n) red=$(cat "${STORE}/red" 2>/dev/null)"

echo "--- corpses, fetch failures, and repos it does not cover ---"
git -C "${W}" worktree add -q --detach "${COMMON}/main-health-lanes/deadbeef-1" HEAD
G3="$(land 0)"
run check --repo "${W}"
[ "${RC}" = 0 ] && [ "$(lanes_left)" = 0 ] && ok "20. a crashed run's lane is reaped under the lock" \
  || bad "20. corpse reaped" "rc=${RC} $(git -C "${W}" worktree list)"

git -C "${W}" remote set-url origin "${T}/no-such-origin.git"
run check --repo "${W}"
[ "${RC}" = 3 ] && [[ "${ERR}" == *"fetch"* ]] && [[ "${ERR}" == *"Fix:"* ]] \
  && ok "21. origin cannot be fetched: exit 3 with Fix:, never a verdict on a stale ref" \
  || bad "21. fetch failure" "rc=${RC} err='${ERR}'"
git -C "${W}" remote set-url origin "${O}"

N2="${T}/nogate"; git init -q -b main "${N2}"; git init -q --bare -b main "${T}/nogate.git"
git -C "${N2}" commit -q --allow-empty -m c0; git -C "${N2}" remote add origin "${T}/nogate.git"
git -C "${N2}" push -q origin main 2>/dev/null
run check --repo "${N2}"
[ "${RC}" = 2 ] && [[ "${ERR}" == *"ai/bin/harness-gate"* ]] && [[ "${ERR}" == *"Fix:"* ]] \
  && ok "22. a repo whose origin/main declares no ai/bin/harness-gate: exit 2 with Fix:" \
  || bad "22. no declared gate" "rc=${RC} err='${ERR}'"

echo "--- status reads ---"
run status --repo "${N2}"
[ "${RC}" = 0 ] && [[ "${OUT}" == *unchecked* ]] && ok "23. status with no store: exit 0, unchecked (no red known)" \
  || bad "23. status unchecked" "rc=${RC} out='${OUT}' err='${ERR}'"
printf 'garbage\n' > "${STORE}/red"
run status --repo "${W}"
[ "${RC}" = 3 ] && [[ "${OUT}${ERR}" == *"COULD NOT LOOK"* ]] && [[ "${ERR}" == *"Fix:"* ]] \
  && ok "24. a malformed marker: status exit 3, COULD NOT LOOK (never read as no red)" \
  || bad "24. malformed marker" "rc=${RC} out='${OUT}' err='${ERR}'"
rm -f "${STORE}/red"

run bogus --repo "${W}"
[ "${RC}" = 2 ] && [[ "${ERR}" == *"Fix:"* ]] && ok "25. an unknown subcommand: exit 2 with Fix:" \
  || bad "25. usage" "rc=${RC} err='${ERR}'"

echo
echo "==================================================="
printf 'RESULT: %d passed, %d failed\n' "${PASS}" "${FAIL}"
echo "==================================================="
[ "${FAIL}" -eq 0 ] || exit 1
echo "ALL CASES PASS"
exit 0
