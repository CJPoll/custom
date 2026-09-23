#!/usr/bin/env bash
# Self-test for scripts/inbox-client-capture (DND-333 / LV-2).
#
# NOTHING LIVE IS TOUCHED. The "client" is mock-athena-inbox-client.rb (real
# ruby, so the identity assertion is the production one), the supervisor is a
# throwaway bash parent, and every path — state dir, XDG_STATE_HOME, the client
# config — is under a mktemp -d. The live client and supervisor are never
# probed, signalled or read. Every process this suite starts is reaped BY PID.
#
# What is proven, because each was silent or destructive on 2026-09-22:
#   * the capture holds the dump, the socket table, the fds, /proc status, the
#     log tail and a signature — and the dump is the client's own, moved in;
#   * an ignored SIGQUIT is recorded as `dump: absent (...)`, never as success
#     and never as "nothing to capture";
#   * the machine token never survives into the capture;
#   * the signature ignores line numbers and changes with the step;
#   * retention keeps N and never prunes the capture being written; the size
#     cap truncates the largest file with a marker;
#   * (DND-367) retention never prunes a capture an UNREAD harness-alerts
#     message references: KEEP=1 with two unread alerts, both still verify; the
#     hard max prunes one only on the record, and its alert is then refused as
#     "pruned before processing", never as tampering; references it could not
#     read keep everything up to the hard max, loudly;
#   * the client is found as the supervisor's ONE child, and "could not
#     identify" (exit 3) is distinct and captures/signals nothing.
#
# Run: bash scripts/test/inbox-client-capture/self-test.sh
#      (or: scripts/inbox-client-capture --self-test)
set -uo pipefail

# Match captured output with a here-string (`grep -q PAT <<<"$out"`), never
# `printf '%s' "$out" | grep -q PAT`. Under pipefail that pipe is a race:
# bash's printf writes line by line, `grep -q` exits at its first match, and a
# later write then takes SIGPIPE -- so the pipeline reads 141 (a false FAIL, or
# a false PASS under `!`) whenever grep is scheduled mid-write. Measured: one
# red "--dry-run previews and changes nothing" in five runs under load (DND-365).

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SCRIPTS="$(cd -- "${HERE}/../.." && pwd -P)"
CAPTURE="${SCRIPTS}/inbox-client-capture"
MOCK="${HERE}/mock-athena-inbox-client.rb"

PASS=0; FAIL=0
ok()  { printf '  ok    %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  FAIL  %s\n        %s\n' "$1" "$2"; FAIL=$((FAIL+1)); }

# DND-404: a marker tagging every mock-athena-inbox-client.rb this run starts
# (passed as its trailing argv below — the mock ignores ARGV entirely, so this
# is inert to its behaviour). Inherited from harness-gate when run under the
# gate (ATHENA_HARNESS_GATE_RUN_MARKER, one per gate invocation, shared with
# ai/bin/check-inbox-mock-orphans -- the gate-level backstop for exactly the
# case a bash trap cannot cover: this suite's OWN process being SIGKILLed,
# which no EXIT/INT/TERM trap can observe); synthesized for a standalone run
# so this suite's own regression case (C-10 below) always has something to
# scope to.
RUN_MARKER="${ATHENA_HARNESS_GATE_RUN_MARKER:-standalone-$$-$(date +%s%N 2>/dev/null || date +%s)}"
export ATHENA_HARNESS_GATE_RUN_MARKER="${RUN_MARKER}"

TMP="$(mktemp -d)"
PIDS=()
cleanup() {
  local p
  # Children first (a fake supervisor's `sleep` would otherwise be orphaned to
  # PID 1 for its whole minute), then the recorded pids themselves.
  for p in "${PIDS[@]}"; do pkill -9 -P "${p}" 2>/dev/null; done
  for p in "${PIDS[@]}"; do kill -9 "${p}" 2>/dev/null; done
  for p in "${PIDS[@]}"; do wait "${p}" 2>/dev/null; done
  # DND-404 belt-and-suspenders: a final sweep by THIS run's marker, in case a
  # mock's pid was ever missed above. pkill/pgrep exclude their own process by
  # design, so this cannot self-match; scoping to the marker (never the bare
  # filename) means it can never touch a sibling worktree's own gate run.
  pkill -9 -f "mock-athena-inbox-client.rb.*${RUN_MARKER}" 2>/dev/null
  rm -rf -- "${TMP}"
}
# INT/TERM must END the suite, not just run cleanup and carry on: a handler
# that returns resumes the next case against a deleted TMP (measured DND-365).
# `exit` fires the EXIT trap, so cleanup still runs exactly once.
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

command -v ruby >/dev/null 2>&1 || {
  echo "VERDICT: FAIL — ruby is not on PATH; the mock client is ruby so the identity check is the real one."
  echo "  Fix: put a ruby on PATH (the harness gate itself needs one)."
  exit 1
}

export ATHENA_INBOX_CLIENT_STATE_DIR="${TMP}/state"
export XDG_STATE_HOME="${TMP}/xdg"
export ATHENA_INBOX_CLIENT_CONFIG="${TMP}/config.json"
export ATHENA_INBOX_CAPTURE_DUMP_WAIT=5
# DND-367: retention reads the harness-alerts channel through the registry, so
# the inbox root is pinned suite-wide and holds the COMMITTED custom entry,
# re-keyed to this checkout's common dir. The live root is never read.
export ATHENA_INBOX_ROOT="${TMP}/inbox-root"
REPO_ROOT="$(cd -- "${SCRIPTS}/.." && pwd -P)"
COMMON="$(cd -- "${REPO_ROOT}" && realpath -- "$(git rev-parse --git-common-dir)")"
mkdir -p "${ATHENA_INBOX_ROOT}/projects"; chmod 700 "${ATHENA_INBOX_ROOT}" "${ATHENA_INBOX_ROOT}/projects"
jq --arg r "${COMMON}" '.projects[] | select(.file == "custom.json") | .entry | .repo = $r' \
  "${REPO_ROOT}/ai/inbox/registry.json" >"${ATHENA_INBOX_ROOT}/projects/custom.json"
chmod 600 "${ATHENA_INBOX_ROOT}/projects/custom.json"
TOKEN="SEKRETtok-9f8e7d6c5b4a-0123456789abcdef"
mkdir -p "${ATHENA_INBOX_CLIENT_STATE_DIR}"
printf '{"server_url":"wss://x/machine/websocket","token":"%s","instances":{}}' "${TOKEN}" > "${ATHENA_INBOX_CLIENT_CONFIG}"
chmod 600 "${ATHENA_INBOX_CLIENT_CONFIG}"
DUMPS="${XDG_STATE_HOME}/athena/inbox-client-dumps"
LOG="${ATHENA_INBOX_CLIENT_STATE_DIR}/athena-inbox-client.log"
printf '2026-09-23T09:00:00Z INFO step tcp_connect 30ms\n' > "${LOG}"
# The token also sits in the log, so the log tail's redaction is exercised.
printf '2026-09-23T09:00:01Z INFO a line that leaked %s\n' "${TOKEN}" >> "${LOG}"

# wait_file <file> [tenths] — a bounded poll with a real sleep; never a spin.
wait_file() {
  local f="$1" max="${2:-100}" i=0
  while [ "${i}" -lt "${max}" ]; do [ -s "${f}" ] && return 0; sleep 0.1; i=$((i+1)); done
  return 1
}

# start_mock <name> [VAR=value ...] — start a mock client and set MOCK_PID.
# NOT called as $(start_mock ...): a command substitution is a subshell, so the
# PIDS it recorded would never reach cleanup and every mock would outlive the
# suite (measured on this suite's first run: eight orphaned mocks).
MOCK_PID=""
start_mock() {
  local name="$1"; shift
  local ready="${TMP}/${name}.ready"
  rm -f "${ready}"
  env MOCK_DUMP_DIR="${DUMPS}" MOCK_LOG="${LOG}" MOCK_READY="${ready}" \
      MOCK_TERM_FILE="${TMP}/${name}.term" MOCK_TOKEN="${TOKEN}" "$@" \
      ruby "${MOCK}" "${RUN_MARKER}" >/dev/null 2>&1 &
  PIDS+=("$!")
  MOCK_PID=""
  wait_file "${ready}" 100 || { echo "mock ${name} never became ready" >&2; return 1; }
  MOCK_PID="$(cat "${ready}")"
  PIDS+=("${MOCK_PID}")
}

field() { printf '%s\n' "$1" | awk -F'\t' -v k="$2" '$1==k{print $2; exit}'; }

mkdir -p "${DUMPS}"; chmod 700 "${DUMPS}"

# ---------------------------------------------------------------------------
printf '\nC-1  a wedged client that answers SIGQUIT: the full capture\n'
start_mock m1 MOCK_MODE=dump; M1="${MOCK_PID}"
out="$("${CAPTURE}" "${M1}" --step tls --reason test 2>&1)"; rc=$?
CAP="$(field "${out}" dir)"
if [ "${rc}" -eq 0 ] && [ -d "${CAP}" ]; then ok "capture exits 0 and names its directory"; else bad "capture exits 0 and names its directory" "rc=${rc} out=${out}"; fi
for f in capture.txt dump.txt socket.txt fds.txt status.txt log-tail.txt signature.txt; do
  if [ -s "${CAP}/${f}" ]; then ok "capture holds ${f}"; else bad "capture holds ${f}" "missing or empty in ${CAP}"; fi
done
if grep -q '^dump: present' "${CAP}/capture.txt"; then ok "the manifest says the dump is present"; else bad "the manifest says the dump is present" "$(cat "${CAP}/capture.txt")"; fi
if grep -q '^trigger: manual$' "${CAP}/capture.txt"; then ok "a direct-pid capture with no --trigger defaults to trigger: manual (DND-362)"; else bad "a direct-pid capture defaults to trigger: manual" "$(cat "${CAP}/capture.txt")"; fi
if [ -z "$(find "${DUMPS}" -maxdepth 1 -type f -name "*-${M1}.txt")" ]; then ok "the loose LV-1 dump was MOVED into the capture (one owner)"; else bad "the loose LV-1 dump was MOVED into the capture (one owner)" "still loose"; fi
if [ "$(stat -c %a "${CAP}")" = "700" ] && [ -z "$(find "${CAP}" -type f ! -perm 600)" ]; then ok "the capture is 0700 with 0600 files"; else bad "the capture is 0700 with 0600 files" "$(stat -c '%a %n' "${CAP}" "${CAP}"/*)"; fi
if grep -rqF -- "${TOKEN:0:8}" "${CAP}"; then bad "the machine token (and its 8-char prefix) never appears in the capture" "$(grep -rlF -- "${TOKEN:0:8}" "${CAP}")"; else ok "the machine token (and its 8-char prefix) never appears in the capture"; fi
if grep -qF '[REDACTED]' "${CAP}/dump.txt" && grep -qF '[REDACTED]' "${CAP}/log-tail.txt"; then ok "the token was redacted in the dump and the log tail"; else bad "the token was redacted in the dump and the log tail" "no [REDACTED] marker"; fi
if grep -q '^step: tls$' "${CAP}/signature.txt" && grep -q '^source: dump$' "${CAP}/signature.txt"; then ok "signature.txt names the step and its source"; else bad "signature.txt names the step and its source" "$(cat "${CAP}/signature.txt")"; fi
EXPECT_FRAMES="$(printf '  %s\n' 'athena-inbox-client.rb:connect_nonblock' 'athena-inbox-client.rb:tls_handshake' 'athena-inbox-client.rb:block in open_transport' 'athena-inbox-client.rb:block in step' 'athena-inbox-client.rb:block in with_deadline')"
if [ "$(sed -n '/^frames:$/,$p' "${CAP}/signature.txt" | tail -n +2)" = "${EXPECT_FRAMES}" ]; then ok "the signature uses the step worker's top 5 frames, file:function only"; else bad "the signature uses the step worker's top 5 frames, file:function only" "$(cat "${CAP}/signature.txt")"; fi
SIG1="$(field "${out}" signature)"
if kill -0 "${M1}" 2>/dev/null && [ ! -e "${TMP}/m1.term" ]; then ok "capture never kills or signals TERM (restart is the caller's, after)"; else bad "capture never kills or signals TERM (restart is the caller's, after)" "mock gone or TERMed"; fi

# ---------------------------------------------------------------------------
printf '\nC-1b  --trigger (DND-362): only the supervisor watchdog claims watchdog\n'
out="$("${CAPTURE}" "${M1}" --step tls --trigger watchdog 2>&1)"; rc=$?
CAPW="$(field "${out}" dir)"
if [ "${rc}" -eq 0 ] && grep -q '^trigger: watchdog$' "${CAPW}/capture.txt"; then ok "--trigger watchdog is recorded verbatim (the watchdog's own invocation)"; else bad "--trigger watchdog is recorded verbatim" "rc=${rc} $(cat "${CAPW}/capture.txt" 2>/dev/null)"; fi
out="$("${CAPTURE}" "${M1}" --trigger bogus 2>&1)"; rc=$?
if [ "${rc}" -eq 1 ] && grep -q 'Fix:' <<<"${out}"; then ok "--trigger bogus is a usage error with a Fix: (only watchdog|manual)"; else bad "--trigger bogus is a usage error with a Fix:" "rc=${rc} ${out}"; fi

# ---------------------------------------------------------------------------
printf '\nC-7  the summary facts the harness-alerts message reads (DND-334)\n'
# shellcheck source=ai/skills/athena:inbox/lib/wedge.sh
. "${SCRIPTS}/../ai/skills/athena:inbox/lib/wedge.sh"
if grep -qx 'reconnecting_since: 0 (log start)' "${CAP}/capture.txt" && grep -qx 'connected_since: 0 (log start)' "${CAP}/capture.txt" \
   && grep -q '^uptime_s: [0-9][0-9]*$' "${CAP}/capture.txt"; then
  ok "the manifest records uptime and the cycle counts (C-1's log has no restart line: since log start)"
else bad "the manifest records uptime and the cycle counts" "$(cat "${CAP}/capture.txt")"; fi
CL="${TMP}/counts.log"
{
  printf '2026-09-23T09:00:00Z WARN reconnecting in 1.0s\n2026-09-23T09:00:02Z INFO connected to wss://x\n'
  printf '2026-09-23T09:00:03Z SUPERVISOR client exited 143 after 9s; restart 1 in 1s\n'
  printf '2026-09-23T09:00:05Z INFO reconnecting in 2.0s\n2026-09-23T09:00:06Z WARN reconnecting in 4.0s\n2026-09-23T09:00:09Z INFO connected to wss://x\n'
} >"${CL}"
if [ "$(wedge_cycle_counts "${CL}")" = "$(printf '2\t1\tlast restart')" ]; then ok "counts reset at the last supervisor restart line (any log level)"; else bad "counts reset at the last supervisor restart line" "$(wedge_cycle_counts "${CL}")"; fi
if [ "$(wedge_cycle_counts "${TMP}/no-such.log")" = "$(printf 'n/a\tn/a\tno log')" ]; then ok "a missing log is n/a, never a measured 0"; else bad "a missing log is n/a, never 0" "$(wedge_cycle_counts "${TMP}/no-such.log")"; fi
if [ "$(wedge_signature tls "$(wedge_frames "${CAP}/dump.txt")")" = "${SIG1}" ]; then ok "lib/wedge.sh recomputes the capture's own signature from its dump (one algorithm)"; else bad "lib/wedge.sh recomputes the capture's signature" "want ${SIG1}"; fi

# ---------------------------------------------------------------------------
printf '\nC-8  the retention PLAN (pure, lib/wedge.sh): a referenced capture is never pruned to meet KEEP (DND-367)\n'
# plan <keep> <hard> <known> <name:ref ...> -> the prune lines, space-joined
plan() {
  local keep="$1" hard="$2" known="$3"; shift 3
  printf '%s\n' "$@" | tr ':' '\t' | wedge_retention_plan "${keep}" "${hard}" "${known}" | tr '\t' '=' | paste -sd' ' -
}
got="$(plan 5 25 1 a:0 b:0 c:0 d:0 e:0 f:0)"
if [ "${got}" = "a=retention b=retention" ]; then ok "six unreferenced, KEEP=5: the two OLDEST go (room for the new one)"; else bad "six unreferenced, KEEP=5: the two oldest go" "${got}"; fi
got="$(plan 1 25 1 a:0 b:1 c:1)"
if [ "${got}" = "a=retention" ]; then ok "KEEP=1 with two referenced: only the unreferenced one goes"; else bad "KEEP=1 with two referenced: only the unreferenced one goes" "${got}"; fi
got="$(plan 1 25 1 a:1 b:0 c:1)"
if [ "${got}" = "b=retention" ]; then ok "a referenced capture OLDER than an unreferenced one still survives"; else bad "a referenced older capture still survives" "${got}"; fi
got="$(plan 1 3 1 a:1 b:1 c:1 d:1)"
if [ "${got}" = "a=hard-max-while-unread b=hard-max-while-unread" ]; then ok "the hard max bounds even referenced captures, oldest first, and NAMES the loss"; else bad "the hard max bounds referenced captures and names the loss" "${got}"; fi
got="$(plan 1 25 0 a:0 b:0 c:0 d:0)"
if [ -z "${got}" ]; then ok "references UNKNOWN: nothing is pruned below the hard max (a failed lookup is not 'none referenced')"; else bad "references unknown: nothing pruned below the hard max" "${got}"; fi
got="$(plan 1 3 0 a:0 b:0 c:0 d:0)"
if [ "${got}" = "a=hard-max-references-unknown b=hard-max-references-unknown" ]; then ok "references unknown: the hard max still holds, with its own reason"; else bad "references unknown: the hard max still holds" "${got}"; fi
got="$(printf '' | wedge_retention_plan 5 25 1)"
if [ -z "${got}" ]; then ok "no captures: nothing to prune"; else bad "no captures: nothing to prune" "${got}"; fi

# ---------------------------------------------------------------------------
printf '\nC-2  the signature: stable across line numbers, sensitive to the step\n'
start_mock m2 MOCK_MODE=dump MOCK_LINE=9999; M2="${MOCK_PID}"
SIG2="$(field "$("${CAPTURE}" "${M2}" --step tls 2>/dev/null)" signature)"
if [ -n "${SIG1}" ] && [ "${SIG1}" = "${SIG2}" ]; then ok "a different line number keeps the same signature"; else bad "a different line number keeps the same signature" "${SIG1} vs ${SIG2}"; fi
SIG3="$(field "$("${CAPTURE}" "${M2}" --step dns 2>/dev/null)" signature)"
if [ -n "${SIG3}" ] && [ "${SIG3}" != "${SIG1}" ]; then ok "a different stalled step changes the signature"; else bad "a different stalled step changes the signature" "${SIG3}"; fi
start_mock m5 MOCK_MODE=dump MOCK_STEP=ws_upgrade; M5="${MOCK_PID}"
CAP5="$(field "$("${CAPTURE}" "${M5}" 2>/dev/null)" dir)"
if grep -q '^step: ws_upgrade$' "${CAP5}/signature.txt"; then ok "without --step, the dump's current_step is the signature step"; else bad "without --step, the dump's current_step is the signature step" "$(cat "${CAP5}/signature.txt")"; fi

# ---------------------------------------------------------------------------
printf '\nC-3  a client that ignores SIGQUIT: an absent dump is EVIDENCE\n'
start_mock m3 MOCK_MODE=ignore; M3="${MOCK_PID}"
out="$(ATHENA_INBOX_CAPTURE_DUMP_WAIT=2 "${CAPTURE}" "${M3}" --step join 2>&1)"; rc=$?
CAP3="$(field "${out}" dir)"
if [ "${rc}" -eq 0 ] && grep -q '^dump: absent (handler did not respond within 2s)$' "${CAP3}/capture.txt"; then ok "the manifest records 'dump: absent (handler did not respond within 2s)'"; else bad "the manifest records 'dump: absent (handler did not respond within 2s)'" "rc=${rc} $(cat "${CAP3}/capture.txt" 2>/dev/null)"; fi
if [ ! -e "${CAP3}/dump.txt" ] && [ -s "${CAP3}/socket.txt" ] && [ -s "${CAP3}/log-tail.txt" ] && grep -q '^source: no-dump$' "${CAP3}/signature.txt"; then ok "the rest of the capture still happens, signature source no-dump"; else bad "the rest of the capture still happens, signature source no-dump" "$(command ls "${CAP3}")"; fi
if [ "$(field "${out}" dump)" = "absent (handler did not respond within 2s)" ]; then ok "stdout reports the absent dump to the caller"; else bad "stdout reports the absent dump to the caller" "${out}"; fi

# ---------------------------------------------------------------------------
printf '\nC-3b a client NOT known to handle SIGQUIT is never sent it (it would die of it)\n'
mkdir -p "${TMP}/old"
printf '%s\n' '# a pre-LV-1 client: no QUIT handler, so Ruby'"'"'s default would kill it' \
  'File.write(ENV["MOCK_READY"], Process.pid.to_s)' 'sleep' > "${TMP}/old/athena-inbox-client.rb"
touch -d '@1' "${TMP}/old/athena-inbox-client.rb"
rm -f "${TMP}/old.ready"
MOCK_READY="${TMP}/old.ready" ruby "${TMP}/old/athena-inbox-client.rb" >/dev/null 2>&1 &
PIDS+=("$!")
wait_file "${TMP}/old.ready" 100; OLD="$(cat "${TMP}/old.ready")"; PIDS+=("${OLD}")
out="$(ATHENA_INBOX_CAPTURE_DUMP_WAIT=1 "${CAPTURE}" "${OLD}" 2>&1)"; rc=$?
CAPO="$(field "${out}" dir)"
if [ "${rc}" -eq 0 ] && grep -q '^dump: not requested (cannot confirm the running client handles SIGQUIT' "${CAPO}/capture.txt" && kill -0 "${OLD}" 2>/dev/null; then
  ok "a pre-LV-1 client is not sent SIGQUIT (still alive), and the manifest says why"
else
  bad "a pre-LV-1 client is not sent SIGQUIT (still alive), and the manifest says why" "rc=${rc} alive=$(kill -0 "${OLD}" 2>/dev/null && echo y || echo n) $(cat "${CAPO}/capture.txt" 2>/dev/null)"
fi
# The trap is in the source, but the source CHANGED after the process started:
# the running code is unknown, so no SIGQUIT either.
cp "${MOCK}" "${TMP}/old/changed-athena-inbox-client.rb"
touch -d '@1' "${TMP}/old/changed-athena-inbox-client.rb"
rm -f "${TMP}/chg.ready"
env MOCK_DUMP_DIR="${DUMPS}" MOCK_LOG="${LOG}" MOCK_READY="${TMP}/chg.ready" MOCK_TERM_FILE="${TMP}/chg.term" \
  ruby "${TMP}/old/changed-athena-inbox-client.rb" >/dev/null 2>&1 &
PIDS+=("$!")
wait_file "${TMP}/chg.ready" 100; CHG="$(cat "${TMP}/chg.ready")"; PIDS+=("${CHG}")
touch "${TMP}/old/changed-athena-inbox-client.rb"
out="$(ATHENA_INBOX_CAPTURE_DUMP_WAIT=1 "${CAPTURE}" "${CHG}" 2>&1)"
if grep -q '^dump: not requested' "$(field "${out}" dir)/capture.txt"; then
  ok "a client whose source changed after it started is not sent SIGQUIT"
else
  bad "a client whose source changed after it started is not sent SIGQUIT" "$(cat "$(field "${out}" dir)/capture.txt" 2>/dev/null)"
fi

# ---------------------------------------------------------------------------
printf '\nC-4  retention keeps N and never prunes the one being written; size cap\n'
RD="${TMP}/ret-xdg/athena/inbox-client-dumps"; mkdir -p "${RD}"
for i in 1 2 3 4 5 6; do mkdir -p "${RD}/2026010${i}T000000Z-1"; printf 'old\n' > "${RD}/2026010${i}T000000Z-1/capture.txt"; done
: > "${RD}/20260101T000000Z-77.txt"   # a loose hand-sent dump: never pruned
out="$(XDG_STATE_HOME="${TMP}/ret-xdg" MOCK_DUMP_DIR="${RD}" ATHENA_INBOX_CAPTURE_KEEP=5 ATHENA_INBOX_CAPTURE_DUMP_WAIT=1 "${CAPTURE}" "${M3}" 2>&1)"
NEWCAP="$(field "${out}" dir)"
n="$(find "${RD}" -mindepth 1 -maxdepth 1 -type d | wc -l)"
if [ "${n}" -eq 5 ] && [ -d "${NEWCAP}" ]; then ok "5 capture dirs remain, including the one just written"; else bad "5 capture dirs remain, including the one just written" "n=${n} new=${NEWCAP}"; fi
if [ ! -e "${RD}/20260101T000000Z-1" ] && [ ! -e "${RD}/20260102T000000Z-1" ] && [ -e "${RD}/20260103T000000Z-1" ]; then ok "the OLDEST were pruned first"; else bad "the OLDEST were pruned first" "$(command ls "${RD}")"; fi
if [ -e "${RD}/20260101T000000Z-77.txt" ]; then ok "a loose dump outside any capture is left alone"; else bad "a loose dump outside any capture is left alone" "pruned"; fi
yes 'a long client log line that pads the tail past the cap .................................' | head -n 5000 > "${TMP}/big.log"
cp "${TMP}/big.log" "${LOG}"
out="$(ATHENA_INBOX_CAPTURE_MAX_BYTES=8000 ATHENA_INBOX_CAPTURE_DUMP_WAIT=1 "${CAPTURE}" "${M3}" 2>&1)"
CAPB="$(field "${out}" dir)"
total="$(find "${CAPB}" -type f -printf '%s\n' | awk '{s+=$1} END {print s+0}')"
if [ "${total}" -le 8000 ] && grep -q 'truncated by inbox-client-capture' "${CAPB}/log-tail.txt"; then ok "the size cap holds (${total} <= 8000) and the largest file carries the marker"; else bad "the size cap holds and the largest file carries the marker" "total=${total}"; fi
if [ -s "${CAPB}/signature.txt" ] && [ -s "${CAPB}/capture.txt" ]; then ok "the signature and manifest survive the cap"; else bad "the signature and manifest survive the cap" "$(command ls -la "${CAPB}")"; fi
printf '2026-09-23T09:00:00Z INFO step tcp_connect 30ms\n' > "${LOG}"
# DND-334: a dump big enough to be capped loses its frames (the recorder comes
# first and the cap keeps the head). The signature was taken BEFORE the cap, so
# the attendant's verifier must still accept this REAL capture -- from the
# frames signature.txt recorded -- rather than call it tampered.
start_mock m6 MOCK_MODE=dump MOCK_FLIGHT_LINES=400; M6="${MOCK_PID}"
# This simulates the watchdog's own capture-before-restart, which always
# claims --trigger watchdog (DND-362); wedge-ticket-decide refuses a manual one.
out="$(ATHENA_INBOX_CAPTURE_MAX_BYTES=12000 "${CAPTURE}" "${M6}" --step tls --trigger watchdog 2>&1)"
CAPD="$(field "${out}" dir)"
if grep -qF 'truncated by inbox-client-capture' "${CAPD}/dump.txt" 2>/dev/null && ! grep -q 'with_deadline' "${CAPD}/dump.txt"; then
  ok "the size cap truncated dump.txt and cut its frames (the case the verifier must survive)"
else bad "the size cap truncated dump.txt and cut its frames" "$(command ls -la "${CAPD}" 2>&1 | tr '\n' '|')"; fi
WF_REPO="$(cd -- "${SCRIPTS}/.." && pwd -P)"
# shellcheck source=scripts/test/inbox-client-alert/wedge-fixture.bash
. "${SCRIPTS}/test/inbox-client-alert/wedge-fixture.bash"
V="$(ATHENA_INBOX_ROOT="${TMP}/inbox-root" "${SCRIPTS}/../ai/skills/athena:inbox-attend/bin/wedge-ticket-decide" \
      --message "$(wf_make_message "${TMP}/msgs" "${CAPD}" "$(field "${out}" signature)")" --verify-only 2>&1)"
if grep -qx 'decision	verified' <<<"${V}" && grep -q '^frames_from	signature.txt (dump.txt was truncated' <<<"${V}"; then
  ok "a REAL capped capture still verifies, from signature.txt's frames, and says so"
else bad "a real capped capture still verifies" "${V}"; fi

# ---------------------------------------------------------------------------
printf '\nC-9  retention never prunes a capture an UNREAD harness-alert references (DND-367)\n'
DECIDE="${REPO_ROOT}/ai/skills/athena:inbox-attend/bin/wedge-ticket-decide"
RX="${TMP}/rx-xdg"; RXD="${RX}/athena/inbox-client-dumps"; mkdir -p "${RXD}"; chmod 700 "${RXD}"
TO_CUSTOM="${ATHENA_INBOX_ROOT}/harness-alerts/to-custom"
mkdir -p "${TO_CUSTOM}"; chmod 700 "${ATHENA_INBOX_ROOT}/harness-alerts" "${TO_CUSTOM}"
OLD0="$(XDG_STATE_HOME="${RX}" wf_make_capture "${RXD}" 20260101T000000Z-10 tls)"   # no alert references it
CA="$(XDG_STATE_HOME="${RX}" wf_make_capture "${RXD}" 20260102T000000Z-11 tls)"
CB="$(XDG_STATE_HOME="${RX}" wf_make_capture "${RXD}" 20260103T000000Z-12 dns)"
MA="$(wf_make_message "${TO_CUSTOM}" "${CA}" "$(wf_signature_of "${CA}")" inbox-client-detector custom 001)"
MB="$(wf_make_message "${TO_CUSTOM}" "${CB}" "$(wf_signature_of "${CB}")" inbox-client-detector custom 002)"
out="$(XDG_STATE_HOME="${RX}" MOCK_DUMP_DIR="${RXD}" ATHENA_INBOX_CAPTURE_KEEP=1 ATHENA_INBOX_CAPTURE_DUMP_WAIT=1 "${CAPTURE}" "${M3}" 2>"${TMP}/c9.err")"; rc=$?
NEWX="$(field "${out}" dir)"
if [ "${rc}" -eq 0 ] && [ -d "${CA}" ] && [ -d "${CB}" ] && [ -d "${NEWX}" ]; then ok "KEEP=1 with two UNREAD alerts: both referenced captures survive, and the new one is written"; else bad "KEEP=1 with two unread alerts: both referenced captures survive" "rc=${rc} $(command ls "${RXD}" | tr '\n' ' ')"; fi
if [ ! -e "${OLD0}" ] && grep -qP "\t20260101T000000Z-10\tretention$" "${RXD}/pruned-captures.log"; then ok "the unreferenced capture was pruned, and the prune ledger records it (reason retention)"; else bad "the unreferenced capture was pruned and recorded" "$(cat "${RXD}/pruned-captures.log" 2>&1)"; fi
for m in "${MA}" "${MB}"; do
  V="$(XDG_STATE_HOME="${RX}" "${DECIDE}" --message "${m}" --verify-only 2>&1)"
  if grep -qx 'decision	verified' <<<"${V}"; then ok "the alert $(basename "${m}") still VERIFIES against its capture after the prune"; else bad "the alert $(basename "${m}") still verifies" "${V}"; fi
done
if grep -q '^retention: keep 1, hard max 25; 3 existed, 2 referenced by unread harness-alerts, 1 pruned$' "${NEWX}/capture.txt" && [ "$(field "${out}" retention)" = "keep 1, hard max 25; 3 existed, 2 referenced by unread harness-alerts, 1 pruned" ]; then
  ok "the manifest and stdout say what retention did (counts, not silence)"
else bad "the manifest and stdout say what retention did" "$(grep '^retention' "${NEWX}/capture.txt"; field "${out}" retention)"; fi
if [ ! -s "${TMP}/c9.err" ]; then ok "an ordinary prune prints no note"; else bad "an ordinary prune prints no note" "$(cat "${TMP}/c9.err")"; fi

# An ACKED alert no longer pins its capture (the attendant has read it).
mkdir -p "${TO_CUSTOM}/.acked"; mv "${MB}" "${TO_CUSTOM}/.acked/"
rm -rf "${NEWX}"
out="$(XDG_STATE_HOME="${RX}" MOCK_DUMP_DIR="${RXD}" ATHENA_INBOX_CAPTURE_KEEP=1 ATHENA_INBOX_CAPTURE_DUMP_WAIT=1 "${CAPTURE}" "${M3}" 2>/dev/null)"
NEWY="$(field "${out}" dir)"
if [ -d "${CA}" ] && [ ! -e "${CB}" ]; then ok "an acked alert's capture is prunable again; the unread one's is not"; else bad "an acked alert's capture is prunable; the unread one's is not" "$(command ls "${RXD}" | tr '\n' ' ')"; fi
rm -rf "${NEWY}"; mv "${TO_CUSTOM}/.acked/$(basename "${MB}")" "${TO_CUSTOM}/"
CB="$(XDG_STATE_HOME="${RX}" wf_make_capture "${RXD}" 20260103T000000Z-12 dns)"

# The HARD MAX prunes a referenced capture, oldest first, ON THE RECORD.
out="$(XDG_STATE_HOME="${RX}" MOCK_DUMP_DIR="${RXD}" ATHENA_INBOX_CAPTURE_KEEP=1 ATHENA_INBOX_CAPTURE_HARD_MAX=2 ATHENA_INBOX_CAPTURE_DUMP_WAIT=1 "${CAPTURE}" "${M3}" 2>"${TMP}/c9h.err")"; rc=$?
NEWZ="$(field "${out}" dir)"
if [ "${rc}" -eq 0 ] && [ ! -e "${CA}" ] && [ -d "${CB}" ] && [ -d "${NEWZ}" ]; then ok "HARD_MAX=2: the OLDEST referenced capture goes, the newer one stays"; else bad "HARD_MAX=2: the oldest referenced capture goes" "rc=${rc} $(command ls "${RXD}" | tr '\n' ' ')"; fi
if grep -qP "\t20260102T000000Z-11\thard-max-while-unread$" "${RXD}/pruned-captures.log" && grep -q '^note: .*hard max (2).*20260102T000000Z-11.*Fix:' "${TMP}/c9h.err" && grep -q '^retention: .*LOST before processing: 20260102T000000Z-11(hard-max-while-unread)' "${NEWZ}/capture.txt"; then
  ok "...recorded as hard-max-while-unread in the ledger, the manifest, and a note: with a Fix:"
else bad "...recorded in the ledger, the manifest and a note" "$(cat "${TMP}/c9h.err"; cat "${RXD}/pruned-captures.log")"; fi
V="$(XDG_STATE_HOME="${RX}" "${DECIDE}" --message "${MA}" --verify-only 2>"${TMP}/c9v.err")"; rc=$?
if [ "${rc}" -eq 3 ] && [ "$(field "${V}" refusal)" = "pruned" ] && grep -q 'pruned before processing' "${TMP}/c9v.err" && grep -q 'hard-max-while-unread' "${TMP}/c9v.err" && ! grep -q 'REFUSED (integrity)' "${TMP}/c9v.err"; then
  ok "its alert is refused as 'pruned before processing' (class pruned, the recorded reason), never as tampering"
else bad "its alert is refused as pruned before processing" "rc=${rc} ${V} $(cat "${TMP}/c9v.err")"; fi

# References that cannot be READ keep everything below the hard max, loudly.
out="$(ATHENA_INBOX_ROOT="${TMP}/no-such-root" XDG_STATE_HOME="${RX}" MOCK_DUMP_DIR="${RXD}" ATHENA_INBOX_CAPTURE_KEEP=1 ATHENA_INBOX_CAPTURE_DUMP_WAIT=1 "${CAPTURE}" "${M3}" 2>"${TMP}/c9u.err")"; rc=$?
NEWU="$(field "${out}" dir)"
if [ "${rc}" -eq 0 ] && [ -d "${CB}" ] && [ -d "${NEWZ}" ] && [ -d "${NEWU}" ]; then ok "unreadable references (no registry): KEEP=1 prunes NOTHING below the hard max"; else bad "unreadable references: nothing pruned below the hard max" "rc=${rc} $(command ls "${RXD}" | tr '\n' ' ')"; fi
if grep -q '^note: capture retention could not read the unread harness-alerts references (.*registry.*).*Fix:' "${TMP}/c9u.err" && grep -q '^retention: .*unread references UNKNOWN' "${NEWU}/capture.txt"; then
  ok "...and says so: a note: naming why with a Fix:, and 'UNKNOWN' in the manifest (never '0 referenced')"
else bad "...and says so" "$(cat "${TMP}/c9u.err"; grep '^retention' "${NEWU}/capture.txt")"; fi
out="$(ATHENA_INBOX_CAPTURE_KEEP=5 ATHENA_INBOX_CAPTURE_HARD_MAX=4 "${CAPTURE}" "${M3}" 2>&1)"; rc=$?
if [ "${rc}" -eq 1 ] && grep -q 'Fix:' <<<"${out}"; then ok "HARD_MAX below KEEP is a usage error with a Fix:"; else bad "HARD_MAX below KEEP is a usage error" "rc=${rc} ${out}"; fi

# ---------------------------------------------------------------------------
printf '\nC-5  identity: the supervisor'"'"'s ONE child, and exit 3 is distinct\n'
PF="${ATHENA_INBOX_CLIENT_STATE_DIR}/athena-inbox-client.pid"
# A fake supervisor whose single child is the mock client.
bash -c 'env MOCK_DUMP_DIR="$1" MOCK_LOG="$2" MOCK_READY="$3" MOCK_TERM_FILE="$4" MOCK_MODE=dump ruby "$5" "$6" & wait' _ \
  "${DUMPS}" "${LOG}" "${TMP}/sup.ready" "${TMP}/sup.term" "${MOCK}" "${RUN_MARKER}" >/dev/null 2>&1 &
SUP=$!; PIDS+=("${SUP}")
wait_file "${TMP}/sup.ready" 100
CHILD="$(cat "${TMP}/sup.ready")"; PIDS+=("${CHILD}")
printf '%s\n' "${SUP}" > "${PF}"
got="$("${CAPTURE}" --resolve-client 2>&1)"; rc=$?
if [ "${rc}" -eq 0 ] && [ "${got}" = "${CHILD}" ]; then ok "--resolve-client finds the supervisor's child, not a pattern match"; else bad "--resolve-client finds the supervisor's child, not a pattern match" "rc=${rc} got=${got} want=${CHILD}"; fi
out="$("${CAPTURE}" --now 2>&1)"; rc=$?
if [ "${rc}" -eq 0 ] && grep -q "^pid: ${CHILD}$" "$(field "${out}" dir)/capture.txt" && grep -q '^reason: manual (--now)$' "$(field "${out}" dir)/capture.txt"; then ok "--now captures the supervised client"; else bad "--now captures the supervised client" "rc=${rc} ${out}"; fi
if grep -q '^trigger: manual$' "$(field "${out}" dir)/capture.txt"; then ok "--now defaults trigger: manual too (DND-362: only the watchdog claims watchdog)"; else bad "--now defaults trigger: manual too" "$(cat "$(field "${out}" dir)/capture.txt" 2>/dev/null)"; fi
if kill -0 "${CHILD}" 2>/dev/null && [ ! -e "${TMP}/sup.term" ]; then ok "--now never restarts or signals TERM"; else bad "--now never restarts or signals TERM" "child gone"; fi

# During a restart backoff the supervisor's child is a `sleep`.
bash -c 'sleep 60 & wait' >/dev/null 2>&1 & SB=$!; PIDS+=("${SB}")
i=0; while [ -z "$(pgrep -P "${SB}")" ] && [ "${i}" -lt 50 ]; do sleep 0.1; i=$((i+1)); done
printf '%s\n' "${SB}" > "${PF}"
before="$(find "${DUMPS}" -mindepth 1 -maxdepth 1 -type d | wc -l)"
out="$("${CAPTURE}" --resolve-client 2>&1)"; rc=$?
if [ "${rc}" -eq 3 ] && grep -q 'could not identify the client: .*not the ruby client (exe .*sleep)' <<<"${out}"; then ok "a backoff sleep child -> exit 3 'could not identify', naming the exe"; else bad "a backoff sleep child -> exit 3 'could not identify', naming the exe" "rc=${rc} ${out}"; fi
out="$("${CAPTURE}" --now 2>&1)"; rc=$?
after="$(find "${DUMPS}" -mindepth 1 -maxdepth 1 -type d | wc -l)"
if [ "${rc}" -eq 3 ] && [ "${before}" = "${after}" ] && grep -q 'Fix:' <<<"${out}"; then ok "--now on an unidentifiable client captures NOTHING, exit 3 with a Fix:"; else bad "--now on an unidentifiable client captures NOTHING, exit 3 with a Fix:" "rc=${rc} dirs ${before}->${after}"; fi

bash -c 'sleep 60 & sleep 60 & wait' >/dev/null 2>&1 & S2=$!; PIDS+=("${S2}")
i=0; while [ "$(pgrep -P "${S2}" | wc -l)" -lt 2 ] && [ "${i}" -lt 50 ]; do sleep 0.1; i=$((i+1)); done
printf '%s\n' "${S2}" > "${PF}"
out="$("${CAPTURE}" --resolve-client 2>&1)"; rc=$?
if [ "${rc}" -eq 3 ] && grep -q 'has 2 children, expected exactly 1' <<<"${out}"; then ok "two children -> exit 3, never a guess"; else bad "two children -> exit 3, never a guess" "rc=${rc} ${out}"; fi
rm -f "${PF}"
out="$("${CAPTURE}" --resolve-client 2>&1)"; rc=$?
if [ "${rc}" -eq 3 ] && grep -q 'no supervisor pidfile' <<<"${out}"; then ok "no pidfile -> exit 3 naming the missing pidfile"; else bad "no pidfile -> exit 3 naming the missing pidfile" "rc=${rc} ${out}"; fi

# A pid that is not the client at all (a plain sleep) is refused before any
# directory is made and before any signal is sent.
sleep 60 & SL=$!; PIDS+=("${SL}")
before="$(find "${DUMPS}" -mindepth 1 -maxdepth 1 -type d | wc -l)"
out="$("${CAPTURE}" "${SL}" 2>&1)"; rc=$?
after="$(find "${DUMPS}" -mindepth 1 -maxdepth 1 -type d | wc -l)"
if [ "${rc}" -eq 3 ] && [ "${before}" = "${after}" ] && kill -0 "${SL}" 2>/dev/null; then ok "a non-client pid -> exit 3, nothing captured, not signalled"; else bad "a non-client pid -> exit 3, nothing captured, not signalled" "rc=${rc} dirs ${before}->${after}"; fi
out="$("${CAPTURE}" 1 2>&1)"; rc=$?
if [ "${rc}" -eq 3 ] && grep -q 'uid' <<<"${out}"; then ok "another user's process (pid 1) -> exit 3 on the uid check"; else bad "another user's process (pid 1) -> exit 3 on the uid check" "rc=${rc} ${out}"; fi

# ---------------------------------------------------------------------------
printf '\nC-6  usage\n'
out="$("${CAPTURE}" --help 2>&1)"; rc=$?
if [ "${rc}" -eq 0 ] && grep -q 'Exit codes' <<<"${out}"; then ok "--help prints the header, exit 0"; else bad "--help prints the header, exit 0" "rc=${rc}"; fi
out="$("${CAPTURE}" --bogus 2>&1)"; rc=$?
if [ "${rc}" -eq 1 ] && grep -q 'Fix:' <<<"${out}"; then ok "an unknown option is exit 1 with a Fix:"; else bad "an unknown option is exit 1 with a Fix:" "rc=${rc}"; fi
out="$(XDG_STATE_HOME=relative "${CAPTURE}" "${M1}" 2>&1)"; rc=$?
if [ "${rc}" -eq 2 ] && grep -q 'Fix:' <<<"${out}"; then ok "a relative XDG_STATE_HOME is exit 2 with a Fix: (a wrongly computed key)"; else bad "a relative XDG_STATE_HOME is exit 2 with a Fix:" "rc=${rc} ${out}"; fi

# C-7. The retention "is this capture referenced?" test must not be a
#      `printf | grep -q` pipe. The tool runs under pipefail, where that pipe
#      reads 141 when grep exits at its first match mid-write, so a REFERENCED
#      capture would read as unreferenced and be pruned under its unread alert.
#      The SIGPIPE needs a scheduling coincidence, so no behavioural fixture
#      can force it; the shape itself is asserted instead (DND-365).
printf '\nC-7  pipefail-safe matching\n'
PIPES="$(grep -nE '\| *grep -[a-zA-Z]*q' "${CAPTURE}" | grep -v '^[0-9]*: *#')"
if grep -q '^set -[a-z]*o pipefail' "${CAPTURE}" && [ -z "${PIPES}" ]; then
  ok "inbox-client-capture (pipefail) matches with here-strings, never a 'printf | grep -q' pipe"
else
  bad "inbox-client-capture (pipefail) matches with here-strings, never a 'printf | grep -q' pipe" \
      "pipes: ${PIPES:-none} (or pipefail no longer set). Fix: rewrite as grep -q PAT <<<\"\$var\""
fi

# ---------------------------------------------------------------------------
# C-10 (DND-404). Reproduces the measured incident: a suite's own process is
# SIGKILLed (an operator or a timeout wrapper killing a hung gate run) while a
# mock it started is still alive. No EXIT/INT/TERM trap -- in this suite, in
# the fake one below, or anywhere else -- can observe a SIGKILL of its own
# process, so the mock is orphaned (reparented to PID 1) no matter how good
# the trap is. This is why the fix cannot be trap-only: it proves the trap
# CANNOT close this gap, then proves ai/bin/check-inbox-mock-orphans (scoped to
# a marker, never the bare filename) does.
printf '\nC-10  DND-404: a SIGKILLed launcher orphans its mock -- the gate backstop reaps what no trap can\n'
NESTED_MARKER="nested-$$-$(date +%s%N 2>/dev/null || date +%s)"
FAKE_SUITE="${TMP}/fake-suite.sh"
cat >"${FAKE_SUITE}" <<'FAKE'
#!/usr/bin/env bash
set -uo pipefail
env MOCK_DUMP_DIR="$1" MOCK_LOG="$2" MOCK_READY="$3" MOCK_TERM_FILE="$4" MOCK_TOKEN="$5" MOCK_MODE=dump \
    ruby "$6" "$7" >/dev/null 2>&1 &
wait
FAKE
chmod +x "${FAKE_SUITE}"
rm -f "${TMP}/nested.ready"
"${FAKE_SUITE}" "${DUMPS}" "${LOG}" "${TMP}/nested.ready" "${TMP}/nested.term" "${TOKEN}" "${MOCK}" "${NESTED_MARKER}" &
FAKE_SUITE_PID=$!
if wait_file "${TMP}/nested.ready" 100; then
  NESTED_CHILD="$(cat "${TMP}/nested.ready")"
  # The incident: SIGKILL the process running the suite, never the mock. No
  # trap sees this -- that is exactly the property under test.
  kill -9 "${FAKE_SUITE_PID}" 2>/dev/null
  wait "${FAKE_SUITE_PID}" 2>/dev/null
  ppid=""; i=0
  while [ "${i}" -lt 30 ]; do
    ppid="$(awk '{print $4}' "/proc/${NESTED_CHILD}/stat" 2>/dev/null)"
    [ "${ppid}" = "1" ] && break
    sleep 0.1; i=$((i+1))
  done
  if kill -0 "${NESTED_CHILD}" 2>/dev/null; then
    ok "reproduces the incident: mock (pid ${NESTED_CHILD}) outlives its SIGKILLed launcher, ppid now ${ppid:-?} (PT-919 class)"
  else
    bad "reproduces the incident (mock outlives its SIGKILLed launcher)" "mock ${NESTED_CHILD} is already gone -- cannot demonstrate the gap this run"
  fi
  GATE="${SCRIPTS}/../ai/bin/check-inbox-mock-orphans"
  GATE_OUT="$(ATHENA_HARNESS_GATE_RUN_MARKER="${NESTED_MARKER}" "${GATE}" 2>&1)"; GATE_RC=$?
  if [ "${GATE_RC}" -eq 1 ] && grep -q "pid=${NESTED_CHILD} " <<<"${GATE_OUT}" && grep -q 'Fix:' <<<"${GATE_OUT}"; then
    ok "check-inbox-mock-orphans, scoped to this run's marker, finds it: exit 1 with a Fix:"
  else
    bad "check-inbox-mock-orphans finds the orphan by this run's marker" "rc=${GATE_RC} ${GATE_OUT}"
  fi
  if ! kill -0 "${NESTED_CHILD}" 2>/dev/null; then
    ok "the orphan is gone once the backstop has run (what no trap could do)"
  else
    bad "the orphan is gone once the backstop has run" "pid ${NESTED_CHILD} still alive"
  fi
  GATE_OUT2="$(ATHENA_HARNESS_GATE_RUN_MARKER="${NESTED_MARKER}" "${GATE}" 2>&1)"; GATE_RC2=$?
  if [ "${GATE_RC2}" -eq 0 ]; then
    ok "re-running the backstop on the same, now-clean marker is exit 0 (PASS)"
  else
    bad "re-running the backstop on the same, now-clean marker is exit 0" "rc=${GATE_RC2} ${GATE_OUT2}"
  fi
  # Safety net for THIS regression test itself, independent of the assertions
  # above: never let this case be the thing that leaves an orphan behind.
  kill -9 "${NESTED_CHILD}" 2>/dev/null
else
  bad "the fake suite's mock became ready" "no ${TMP}/nested.ready"
  kill -9 "${FAKE_SUITE_PID}" 2>/dev/null
fi

printf '\n'
if [ "${FAIL}" -eq 0 ]; then echo "VERDICT: PASS (${PASS} cases)"; exit 0; fi
echo "VERDICT: FAIL (${FAIL} failed, ${PASS} passed)"
echo "  Fix: read each FAIL above; the claim names the behaviour. Repair scripts/inbox-client-capture and re-run it with --self-test."
exit 1
