#!/usr/bin/env bash
# Self-test for ai/bin/lane-lock (DND-261).
#
# The regression cases the ticket names come first:
#   - two concurrent claims -> exactly one wins;
#   - a crashed holder (killed process) frees the lock, and so does the
#     anchor (the session) exiting;
#   - a stale marker file alone no longer blocks, and a missing or garbled
#     record no longer admits a second holder.
# Then the misses: a malformed lane, no anchor, a dead anchor, a release from
# a caller under another anchor.
#
# Hermetic: a temp lock dir and temp HOME; anchors are `sleep` processes this
# suite starts and kills. Every wait blocks on a lock or a pid with a bound;
# nothing polls.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# LANE_LOCK_TOOL lets a sabotage run point the suite at a broken copy.
TOOL="${LANE_LOCK_TOOL:-$(cd "${HERE}/../.." && pwd)/bin/lane-lock}"
PASS=0; FAIL=0
TMP="$(mktemp -d)"
LD="${TMP}/locks"
export HOME="${TMP}/home"; mkdir -p "${HOME}/.claude"
unset XDG_STATE_HOME CLAUDE_CODE_SESSION_ID
ANCHORS=()

cleanup() {
  local p
  for p in "${ANCHORS[@]}"; do kill "${p}" 2>/dev/null; done
  for l in a b c d e f g h i j k; do "${TOOL}" release --lane "${l}" --force --lock-dir "${LD}" >/dev/null 2>&1; done
  chmod -R u+rwx "${TMP}" 2>/dev/null
  rm -rf "${TMP}"
}
trap cleanup EXIT

ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; [ -n "${2-}" ] && printf '%s\n' "$2" | sed 's/^/       /'; }

# new_anchor -- start a long sleep standing in for the Claude session; its pid
# is in ANCHOR. Called in THIS shell (never in $(...)), so cleanup sees it.
ANCHOR=""
new_anchor() {
  sleep 3600 </dev/null >/dev/null 2>&1 &
  ANCHOR="$!"
  ANCHORS+=("${ANCHOR}")
}

LL() { "${TOOL}" "$@" --lock-dir "${LD}"; }

# freed_within <lane> <secs> -- block (not spin) until the lane lock is free.
freed_within() { flock -w "$2" -s "${LD}/$1.lock" true; }

echo "lane-lock self-test"

# ---- --help ---------------------------------------------------------------
out="$("${TOOL}" --help 2>/dev/null)"; rc=$?
if [ "${rc}" = 0 ] && printf '%s' "${out}" | grep -q 'lane-lock acquire'; then ok "--help on stdout, exit 0"
else bad "--help on stdout, exit 0" "rc=${rc}"; fi

# ---- 1. two concurrent claims: exactly one wins ---------------------------
new_anchor; A="${ANCHOR}"
claimers=()
for i in 1 2 3 4 5; do
  ( LL acquire --lane a --anchor-pid "${A}" > "${TMP}/c${i}.out" 2>&1; echo $? > "${TMP}/c${i}.rc" ) &
  claimers+=("$!")
done
wait "${claimers[@]}"   # the claimers only: the anchors are children too
wins=0; held=0; other=""
for i in 1 2 3 4 5; do
  case "$(cat "${TMP}/c${i}.rc")" in 0) wins=$((wins+1)) ;; 3) held=$((held+1)) ;; *) other="${other} c${i}=$(cat "${TMP}/c${i}.rc")" ;; esac
done
if [ "${wins}" = 1 ] && [ "${held}" = 4 ] && [ -z "${other}" ]; then ok "5 concurrent acquires: exactly one ACQUIRED, four HELD"
else bad "5 concurrent acquires: exactly one ACQUIRED, four HELD" "wins=${wins} held=${held} other=${other}"; fi
out="$(LL status --lane a)"; rc=$?
if [ "${rc}" = 3 ] && [[ "${out}" == HELD*"anchor_pid=${A}"* ]]; then ok "status after the race: HELD under the anchor"
else bad "status after the race: HELD under the anchor" "rc=${rc} out=${out}"; fi

# ---- 2. a crashed holder frees the lock -----------------------------------
hp="$(sed -n 's/^holder_pid=//p' "${LD}/a.holder")"
kill -KILL "${hp}" 2>/dev/null
if freed_within a 5; then ok "SIGKILL of the holder frees the lock"
else bad "SIGKILL of the holder frees the lock" "holder ${hp} still holds"; fi
out="$(LL status --lane a)"; rc=$?
if [ "${rc}" = 0 ] && [[ "${out}" == FREE* ]]; then ok "status after the crash: FREE, although the stale record remains"
else bad "status after the crash: FREE, although the stale record remains" "rc=${rc} out=${out}"; fi
out="$(LL acquire --lane a --anchor-pid "${A}")"; rc=$?
if [ "${rc}" = 0 ]; then ok "acquire after the crash succeeds"; else bad "acquire after the crash succeeds" "rc=${rc} ${out}"; fi

# ---- 3. the anchor (session) exiting frees the lock -----------------------
new_anchor; B="${ANCHOR}"
LL acquire --lane b --anchor-pid "${B}" >/dev/null 2>&1
kill "${B}"
if freed_within b 10; then ok "the anchor exiting frees the lock"
else bad "the anchor exiting frees the lock" "$(LL status --lane b)"; fi

# ---- 4. a stale marker file alone no longer blocks ------------------------
new_anchor; C="${ANCHOR}"
mkdir -p "${LD}"
: > "${LD}/c.lock"                          # an unheld lock file (a corpse)
printf 'holder_pid=999999\nanchor_pid=999999\n' > "${LD}/c.holder"
touch -d '2 hours ago' "${LD}/c.lock"
: > "${HOME}/.claude/c-coordinator.lock"    # the retired touch-marker
out="$(LL status --lane c)"; rc=$?
if [ "${rc}" = 0 ] && [[ "${out}" == FREE* ]]; then ok "a corpse lock file, stale record and old marker read FREE"
else bad "a corpse lock file, stale record and old marker read FREE" "rc=${rc} out=${out}"; fi
out="$(LL acquire --lane c --anchor-pid "${C}")"; rc=$?
if [ "${rc}" = 0 ]; then ok "... and do not block acquire"; else bad "... and do not block acquire" "rc=${rc} ${out}"; fi

# ---- 5. a missing or garbled record no longer admits -----------------------
new_anchor; D="${ANCHOR}"
rm -f "${HOME}/.claude/c-coordinator.lock" "${LD}/c.holder"
out="$(LL acquire --lane c --anchor-pid "${D}" 2>&1)"; rc=$?
if [ "${rc}" = 3 ]; then ok "held lane with its record deleted: acquire still refused (3)"
else bad "held lane with its record deleted: acquire still refused (3)" "rc=${rc} ${out}"; fi
out="$(LL status --lane c)"; rc=$?
if [ "${rc}" = 3 ] && [[ "${out}" == *"holder=unknown"* ]]; then ok "status: HELD, holder=unknown"
else bad "status: HELD, holder=unknown" "rc=${rc} out=${out}"; fi
printf 'garbage\n' > "${LD}/c.holder"
out="$(LL acquire --lane c --anchor-pid "${D}" 2>&1)"; rc=$?
if [ "${rc}" = 3 ]; then ok "held lane with a garbled record: acquire still refused (3)"
else bad "held lane with a garbled record: acquire still refused (3)" "rc=${rc} ${out}"; fi

# ---- 6. release: only the holder's anchor, or --force ----------------------
new_anchor; E="${ANCHOR}"; new_anchor; E2="${ANCHOR}"
LL acquire --lane e --anchor-pid "${E}" >/dev/null 2>&1
out="$(LL release --lane e --anchor-pid "${E2}" 2>&1)"; rc=$?
if [ "${rc}" = 4 ] && [[ "${out}" == *"Fix:"* ]] && ! freed_within e 0; then ok "release from another anchor: refused (4), still held"
else bad "release from another anchor: refused (4), still held" "rc=${rc} ${out}"; fi
out="$(LL release --lane e --anchor-pid "${E}")"; rc=$?
if [ "${rc}" = 0 ] && [[ "${out}" == RELEASED* ]] && freed_within e 0; then ok "release by the holder's anchor: RELEASED, free"
else bad "release by the holder's anchor: RELEASED, free" "rc=${rc} ${out}"; fi
out="$(LL release --lane e --anchor-pid "${E}")"; rc=$?
if [ "${rc}" = 0 ] && [[ "${out}" == NOT_HELD* ]]; then ok "release again: NOT_HELD, exit 0"
else bad "release again: NOT_HELD, exit 0" "rc=${rc} ${out}"; fi
LL acquire --lane e --anchor-pid "${E}" >/dev/null 2>&1
sleep 3600 9<"${LD}/e.lock" </dev/null >/dev/null 2>&1 &   # a bystander with the file open
BYST="$!"; ANCHORS+=("${BYST}")
out="$(LL release --lane e --force)"; rc=$?
if [ "${rc}" = 0 ] && freed_within e 0; then ok "release --force by a caller with no anchor frees it"
else bad "release --force by a caller with no anchor frees it" "rc=${rc} ${out}"; fi
if kill -0 "${BYST}" 2>/dev/null && [[ "${out}" != *"${BYST}"* ]]; then ok "release kills only the lock holder, not a process that merely has the file open"
else bad "release kills only the lock holder, not a process that merely has the file open" "${out}"; fi
out="$(LL release --lane c --anchor-pid "${D}" 2>&1)"; rc=$?
if [ "${rc}" = 4 ]; then ok "release of a lane with a garbled record, no --force: refused (4)"
else bad "release of a lane with a garbled record, no --force: refused (4)" "rc=${rc} ${out}"; fi

# ---- 7. the anchor is found by comm ---------------------------------------
FB="${TMP}/bin"; mkdir -p "${FB}"; cp "$(command -v bash)" "${FB}/fakeclaude"
# `; true` keeps bash from exec'ing the last command, so fakeclaude stays the parent.
out="$("${FB}/fakeclaude" -c "\"${TOOL}\" acquire --lane f --anchor-comm fakeclaude --lock-dir \"${LD}\"; true" 2>&1)"; rc=$?
if [ "${rc}" = 0 ] && [[ "${out}" == ACQUIRED*anchor_pid=* ]]; then ok "anchor resolved from the nearest ancestor by comm"
else bad "anchor resolved from the nearest ancestor by comm" "rc=${rc} ${out}"; fi
if freed_within f 10; then ok "... and the lock ended with that ancestor"
else bad "... and the lock ended with that ancestor" "$(LL status --lane f)"; fi

# ---- 8. the misses --------------------------------------------------------
out="$(LL acquire --lane g --anchor-comm no-such-comm-dnd261 2>&1)"; rc=$?
if [ "${rc}" = 1 ] && [[ "${out}" == *"no-such-comm-dnd261"*"Fix:"* ]] && [ ! -e "${LD}/g.lock" ]; then ok "no anchor ancestor: exit 1 naming the comm searched, no lock"
else bad "no anchor ancestor: exit 1 naming the comm searched, no lock" "rc=${rc} ${out}"; fi
new_anchor; dead="${ANCHOR}"; kill "${dead}"; wait "${dead}" 2>/dev/null
out="$(LL acquire --lane g --anchor-pid "${dead}" 2>&1)"; rc=$?
if [ "${rc}" = 1 ] && [[ "${out}" == *"Fix:"* ]]; then ok "dead anchor: exit 1, never ACQUIRED"
else bad "dead anchor: exit 1, never ACQUIRED" "rc=${rc} ${out}"; fi
out="$(LL status --lane 'Bad/Lane' 2>&1)"; rc=$?
if [ "${rc}" = 2 ] && [[ "${out}" == *"Fix:"* ]]; then ok "malformed lane id: exit 2"
else bad "malformed lane id: exit 2" "rc=${rc} ${out}"; fi
out="$(LL status 2>&1)"; rc=$?
if [ "${rc}" = 2 ]; then ok "no --lane: exit 2"; else bad "no --lane: exit 2" "rc=${rc} ${out}"; fi
out="$("${TOOL}" status --lane h --lock-dir relative/dir 2>&1)"; rc=$?
if [ "${rc}" = 2 ]; then ok "relative --lock-dir: exit 2"; else bad "relative --lock-dir: exit 2" "rc=${rc} ${out}"; fi
out="$(LL status --lane h)"; rc=$?
if [ "${rc}" = 0 ] && [[ "${out}" == FREE* ]] && [ ! -e "${LD}/h.lock" ]; then ok "status of a never-used lane: FREE, creates nothing"
else bad "status of a never-used lane: FREE, creates nothing" "rc=${rc} ${out}"; fi
mkdir -p "${LD}"; : > "${LD}/i.lock"; chmod 000 "${LD}/i.lock"
if [ -r "${LD}/i.lock" ]; then ok "unreadable lock file: skipped (running as root)"
else
  out="$(LL status --lane i 2>&1)"; rc=$?
  if [ "${rc}" = 1 ] && [[ "${out}" != FREE* ]]; then ok "unreadable lock file: exit 1, never FREE"
  else bad "unreadable lock file: exit 1, never FREE" "rc=${rc} ${out}"; fi
fi
chmod 600 "${LD}/i.lock"
if [ "$(LL status --lane g)" = "FREE lane=g lock=${LD}/g.lock" ] && [ -z "$(pgrep -f '^lane-lock-holder:g ')" ]; then
  ok "after the failed acquires, lane g is FREE and no holder lingers"
else bad "after the failed acquires, lane g is FREE and no holder lingers" "$(LL status --lane g) $(pgrep -af '^lane-lock-holder:g ')"; fi

# A directory that cannot be searched, or a file where the dir should be,
# hides the lock file from [ -e ]; that is "cannot look", never FREE.
new_anchor; K="${ANCHOR}"
KD="${TMP}/kdir"
"${TOOL}" acquire --lane k --anchor-pid "${K}" --lock-dir "${KD}" >/dev/null 2>&1
chmod 000 "${KD}"
if [ -x "${KD}" ]; then ok "unsearchable lock dir: skipped (running as root)"
else
  out="$("${TOOL}" status --lane k --lock-dir "${KD}" 2>&1)"; rc=$?
  if [ "${rc}" = 1 ] && [[ "${out}" != FREE* ]] && [[ "${out}" == *"Fix:"* ]]; then ok "held lane in an unsearchable lock dir: exit 1, never FREE"
  else bad "held lane in an unsearchable lock dir: exit 1, never FREE" "rc=${rc} ${out}"; fi
fi
chmod 700 "${KD}"
"${TOOL}" release --lane k --force --lock-dir "${KD}" >/dev/null 2>&1
: > "${TMP}/afile"
out="$("${TOOL}" status --lane k --lock-dir "${TMP}/afile/locks" 2>&1)"; rc=$?
if [ "${rc}" = 1 ] && [[ "${out}" != FREE* ]]; then ok "a file where the lock dir should be: exit 1, never FREE"
else bad "a file where the lock dir should be: exit 1, never FREE" "rc=${rc} ${out}"; fi

# --wait: decimal only in meaning (08 is eight, not an octal error), acquire only.
new_anchor; W="${ANCHOR}"
out="$(LL acquire --lane h --anchor-pid "${W}" --wait 08 2>&1)"; rc=$?
if [ "${rc}" = 0 ] && [[ "${out}" == ACQUIRED* ]]; then ok "--wait 08 is eight seconds"
else bad "--wait 08 is eight seconds" "rc=${rc} ${out}"; fi
out="$(LL status --lane h --wait 3 2>&1)"; rc=$?
if [ "${rc}" = 2 ]; then ok "--wait on status: exit 2, even at the default value"
else bad "--wait on status: exit 2, even at the default value" "rc=${rc} ${out}"; fi
if [ -z "$(find "${LD}" -maxdepth 1 -name '.acquire.*')" ]; then ok "no hand-off fifo or stray file left in the lock dir"
else bad "no hand-off fifo or stray file left in the lock dir" "$(find "${LD}" -maxdepth 1 -name '.acquire.*')"; fi
m="$(stat -c %a "${LD}/h.holder" 2>/dev/null)"
if [ "${m}" = 600 ]; then ok "holder record is mode 600 (it names the session)"
else bad "holder record is mode 600 (it names the session)" "mode=${m}"; fi

# ---- 9. the holder does not tie up the caller's stdout ---------------------
new_anchor; J="${ANCHOR}"
out="$(timeout 20 "${TOOL}" acquire --lane j --anchor-pid "${J}" --lock-dir "${LD}")"; rc=$?
if [ "${rc}" = 0 ]; then ok "acquire returns while the holder keeps running (no inherited stdout)"
else bad "acquire returns while the holder keeps running (no inherited stdout)" "rc=${rc} ${out}"; fi

echo "lane-lock self-test: ${PASS} passed, ${FAIL} failed"
[ "${FAIL}" = 0 ]
