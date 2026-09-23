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
#   * the client is found as the supervisor's ONE child, and "could not
#     identify" (exit 3) is distinct and captures/signals nothing.
#
# Run: bash scripts/test/inbox-client-capture/self-test.sh
#      (or: scripts/inbox-client-capture --self-test)
set -uo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SCRIPTS="$(cd -- "${HERE}/../.." && pwd -P)"
CAPTURE="${SCRIPTS}/inbox-client-capture"
MOCK="${HERE}/mock-athena-inbox-client.rb"

PASS=0; FAIL=0
ok()  { printf '  ok    %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  FAIL  %s\n        %s\n' "$1" "$2"; FAIL=$((FAIL+1)); }

TMP="$(mktemp -d)"
PIDS=()
cleanup() {
  local p
  # Children first (a fake supervisor's `sleep` would otherwise be orphaned to
  # PID 1 for its whole minute), then the recorded pids themselves.
  for p in "${PIDS[@]}"; do pkill -9 -P "${p}" 2>/dev/null; done
  for p in "${PIDS[@]}"; do kill -9 "${p}" 2>/dev/null; done
  for p in "${PIDS[@]}"; do wait "${p}" 2>/dev/null; done
  rm -rf -- "${TMP}"
}
trap cleanup EXIT INT TERM

command -v ruby >/dev/null 2>&1 || {
  echo "VERDICT: FAIL — ruby is not on PATH; the mock client is ruby so the identity check is the real one."
  echo "  Fix: put a ruby on PATH (the harness gate itself needs one)."
  exit 1
}

export ATHENA_INBOX_CLIENT_STATE_DIR="${TMP}/state"
export XDG_STATE_HOME="${TMP}/xdg"
export ATHENA_INBOX_CLIENT_CONFIG="${TMP}/config.json"
export ATHENA_INBOX_CAPTURE_DUMP_WAIT=5
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
      ruby "${MOCK}" >/dev/null 2>&1 &
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

# ---------------------------------------------------------------------------
printf '\nC-5  identity: the supervisor'"'"'s ONE child, and exit 3 is distinct\n'
PF="${ATHENA_INBOX_CLIENT_STATE_DIR}/athena-inbox-client.pid"
# A fake supervisor whose single child is the mock client.
bash -c 'env MOCK_DUMP_DIR="$1" MOCK_LOG="$2" MOCK_READY="$3" MOCK_TERM_FILE="$4" MOCK_MODE=dump ruby "$5" & wait' _ \
  "${DUMPS}" "${LOG}" "${TMP}/sup.ready" "${TMP}/sup.term" "${MOCK}" >/dev/null 2>&1 &
SUP=$!; PIDS+=("${SUP}")
wait_file "${TMP}/sup.ready" 100
CHILD="$(cat "${TMP}/sup.ready")"; PIDS+=("${CHILD}")
printf '%s\n' "${SUP}" > "${PF}"
got="$("${CAPTURE}" --resolve-client 2>&1)"; rc=$?
if [ "${rc}" -eq 0 ] && [ "${got}" = "${CHILD}" ]; then ok "--resolve-client finds the supervisor's child, not a pattern match"; else bad "--resolve-client finds the supervisor's child, not a pattern match" "rc=${rc} got=${got} want=${CHILD}"; fi
out="$("${CAPTURE}" --now 2>&1)"; rc=$?
if [ "${rc}" -eq 0 ] && grep -q "^pid: ${CHILD}$" "$(field "${out}" dir)/capture.txt" && grep -q '^reason: manual (--now)$' "$(field "${out}" dir)/capture.txt"; then ok "--now captures the supervised client"; else bad "--now captures the supervised client" "rc=${rc} ${out}"; fi
if kill -0 "${CHILD}" 2>/dev/null && [ ! -e "${TMP}/sup.term" ]; then ok "--now never restarts or signals TERM"; else bad "--now never restarts or signals TERM" "child gone"; fi

# During a restart backoff the supervisor's child is a `sleep`.
bash -c 'sleep 60 & wait' >/dev/null 2>&1 & SB=$!; PIDS+=("${SB}")
i=0; while [ -z "$(pgrep -P "${SB}")" ] && [ "${i}" -lt 50 ]; do sleep 0.1; i=$((i+1)); done
printf '%s\n' "${SB}" > "${PF}"
before="$(find "${DUMPS}" -mindepth 1 -maxdepth 1 -type d | wc -l)"
out="$("${CAPTURE}" --resolve-client 2>&1)"; rc=$?
if [ "${rc}" -eq 3 ] && printf '%s' "${out}" | grep -q 'could not identify the client: .*not the ruby client (exe .*sleep)'; then ok "a backoff sleep child -> exit 3 'could not identify', naming the exe"; else bad "a backoff sleep child -> exit 3 'could not identify', naming the exe" "rc=${rc} ${out}"; fi
out="$("${CAPTURE}" --now 2>&1)"; rc=$?
after="$(find "${DUMPS}" -mindepth 1 -maxdepth 1 -type d | wc -l)"
if [ "${rc}" -eq 3 ] && [ "${before}" = "${after}" ] && printf '%s' "${out}" | grep -q 'Fix:'; then ok "--now on an unidentifiable client captures NOTHING, exit 3 with a Fix:"; else bad "--now on an unidentifiable client captures NOTHING, exit 3 with a Fix:" "rc=${rc} dirs ${before}->${after}"; fi

bash -c 'sleep 60 & sleep 60 & wait' >/dev/null 2>&1 & S2=$!; PIDS+=("${S2}")
i=0; while [ "$(pgrep -P "${S2}" | wc -l)" -lt 2 ] && [ "${i}" -lt 50 ]; do sleep 0.1; i=$((i+1)); done
printf '%s\n' "${S2}" > "${PF}"
out="$("${CAPTURE}" --resolve-client 2>&1)"; rc=$?
if [ "${rc}" -eq 3 ] && printf '%s' "${out}" | grep -q 'has 2 children, expected exactly 1'; then ok "two children -> exit 3, never a guess"; else bad "two children -> exit 3, never a guess" "rc=${rc} ${out}"; fi
rm -f "${PF}"
out="$("${CAPTURE}" --resolve-client 2>&1)"; rc=$?
if [ "${rc}" -eq 3 ] && printf '%s' "${out}" | grep -q 'no supervisor pidfile'; then ok "no pidfile -> exit 3 naming the missing pidfile"; else bad "no pidfile -> exit 3 naming the missing pidfile" "rc=${rc} ${out}"; fi

# A pid that is not the client at all (a plain sleep) is refused before any
# directory is made and before any signal is sent.
sleep 60 & SL=$!; PIDS+=("${SL}")
before="$(find "${DUMPS}" -mindepth 1 -maxdepth 1 -type d | wc -l)"
out="$("${CAPTURE}" "${SL}" 2>&1)"; rc=$?
after="$(find "${DUMPS}" -mindepth 1 -maxdepth 1 -type d | wc -l)"
if [ "${rc}" -eq 3 ] && [ "${before}" = "${after}" ] && kill -0 "${SL}" 2>/dev/null; then ok "a non-client pid -> exit 3, nothing captured, not signalled"; else bad "a non-client pid -> exit 3, nothing captured, not signalled" "rc=${rc} dirs ${before}->${after}"; fi
out="$("${CAPTURE}" 1 2>&1)"; rc=$?
if [ "${rc}" -eq 3 ] && printf '%s' "${out}" | grep -q 'uid'; then ok "another user's process (pid 1) -> exit 3 on the uid check"; else bad "another user's process (pid 1) -> exit 3 on the uid check" "rc=${rc} ${out}"; fi

# ---------------------------------------------------------------------------
printf '\nC-6  usage\n'
out="$("${CAPTURE}" --help 2>&1)"; rc=$?
if [ "${rc}" -eq 0 ] && printf '%s' "${out}" | grep -q 'Exit codes'; then ok "--help prints the header, exit 0"; else bad "--help prints the header, exit 0" "rc=${rc}"; fi
out="$("${CAPTURE}" --bogus 2>&1)"; rc=$?
if [ "${rc}" -eq 1 ] && printf '%s' "${out}" | grep -q 'Fix:'; then ok "an unknown option is exit 1 with a Fix:"; else bad "an unknown option is exit 1 with a Fix:" "rc=${rc}"; fi
out="$(XDG_STATE_HOME=relative "${CAPTURE}" "${M1}" 2>&1)"; rc=$?
if [ "${rc}" -eq 2 ] && printf '%s' "${out}" | grep -q 'Fix:'; then ok "a relative XDG_STATE_HOME is exit 2 with a Fix: (a wrongly computed key)"; else bad "a relative XDG_STATE_HOME is exit 2 with a Fix:" "rc=${rc} ${out}"; fi

printf '\n'
if [ "${FAIL}" -eq 0 ]; then echo "VERDICT: PASS (${PASS} cases)"; exit 0; fi
echo "VERDICT: FAIL (${FAIL} failed, ${PASS} passed)"
echo "  Fix: read each FAIL above; the claim names the behaviour. Repair scripts/inbox-client-capture and re-run it with --self-test."
exit 1
