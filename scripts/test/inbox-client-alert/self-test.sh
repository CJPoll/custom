#!/usr/bin/env bash
# Self-test for scripts/inbox-client-alert (DND-334 / LV-3) and the committed
# harness-alerts registry declaration it sends through.
#
# NOTHING LIVE IS TOUCHED. XDG_STATE_HOME, ATHENA_INBOX_ROOT and the client
# config are pinned under a mktemp -d for the WHOLE suite (a previous suite
# leaked into live state through an unpinned variable). The registry entry is
# the COMMITTED custom entry from ai/inbox/registry.json, re-keyed to this
# checkout's git common dir and installed into the temp root only. Every
# process this suite backgrounds is reaped BY PID.
#
# What is proven:
#   * the committed custom entry (with both harness-alerts sides) validates, and
#     check-inbox-registry passes against a temp root installed from it;
#   * the alert body carries signature, step, frames, capture path, counts, pid
#     and uptime — and never the token (a capture carrying it is REFUSED);
#   * a send lands ONE contract message in harness-alerts/to-custom, from
#     inbox-client-detector to custom, re: the capture; the writer takes only
#     the .sender.lock;
#   * inbox-wait (armed from this repo, as the harness session arms it) WAKES
#     on that delivery and names `harness-alerts` (existing behaviour, asserted);
#   * read-inbox on `harness-alerts` reads and acks it, and wedge-ticket-decide
#     on the acked file verifies and resolves `create` (end to end);
#   * a failed send (no registry entry) is exit 4 with a Fix:, loud, never 0;
#   * a capture outside the dump dir, or not a capture, is refused (exit 2).
#
# Run: bash scripts/test/inbox-client-alert/self-test.sh
#      (or: scripts/inbox-client-alert --self-test)
set -uo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
WF_REPO="$(cd -- "${HERE}/../../.." && pwd -P)"
ALERT="${WF_REPO}/scripts/inbox-client-alert"
BIN="${WF_REPO}/ai/skills/athena:inbox/bin"
DECIDE="${WF_REPO}/ai/skills/athena:inbox-attend/bin/wedge-ticket-decide"

PASS=0; FAIL=0
ok()  { printf '  ok    %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  FAIL  %s\n        %s\n' "$1" "$2"; FAIL=$((FAIL+1)); }

TMP="$(mktemp -d)"
WAIT_CHILD=""
cleanup() {
  if [ -n "${WAIT_CHILD}" ]; then
    pkill -P "${WAIT_CHILD}" 2>/dev/null
    kill "${WAIT_CHILD}" 2>/dev/null
    wait "${WAIT_CHILD}" 2>/dev/null
  fi
  rm -rf -- "${TMP}"
}
trap cleanup EXIT INT TERM

export XDG_STATE_HOME="${TMP}/xdg"
export ATHENA_INBOX_ROOT="${TMP}/inbox-root"
export ATHENA_INBOX_CLIENT_CONFIG="${TMP}/config.json"
export ATHENA_INBOX_REGISTRY="${WF_REPO}/ai/inbox/registry.json"
# A subagent may not arm a waiter or take the consumer lock; this suite plays
# the harness SESSION, so it must not inherit a caller's subagent identity.
unset CLAUDE_AGENT_ID CLAUDE_AGENT_TYPE
TOKEN="SEKRETtok-alert-0123456789abcdef"
printf '{"server_url":"wss://x/machine/websocket","token":"%s","instances":{}}' "${TOKEN}" >"${ATHENA_INBOX_CLIENT_CONFIG}"
chmod 600 "${ATHENA_INBOX_CLIENT_CONFIG}"

# shellcheck source=scripts/test/inbox-client-alert/wedge-fixture.bash
. "${HERE}/wedge-fixture.bash"
DUMPS="${XDG_STATE_HOME}/athena/inbox-client-dumps"
field() { printf '%s\n' "$1" | awk -F'\t' -v k="$2" '$1==k{print $2; exit}'; }

# install_registry <root> — the COMMITTED custom entry, re-keyed to this
# checkout's common dir (so the suite does not depend on living at ~/dev/custom).
COMMON="$(cd -- "${WF_REPO}" && realpath -- "$(git rev-parse --git-common-dir)")"
install_registry() {
  mkdir -p "$1/projects"; chmod 700 "$1" "$1/projects"
  jq --arg r "${COMMON}" '.projects[] | select(.file == "custom.json") | .entry | .repo = $r' \
    "${ATHENA_INBOX_REGISTRY}" >"$1/projects/custom.json"
  chmod 600 "$1/projects/custom.json"
}
install_registry "${ATHENA_INBOX_ROOT}"
TO_CUSTOM="${ATHENA_INBOX_ROOT}/harness-alerts/to-custom"
msgs() { find "${TO_CUSTOM}" -maxdepth 1 -type f -name '*.md' 2>/dev/null | sort; }

# ---------------------------------------------------------------------------
printf '\nA-1  the committed registry declaration\n'
if jq -e '.projects[] | select(.file=="custom.json") | .entry.channels
          | (.["harness-alerts"] == {kind:"maildir",namespace:"harness-alerts",read:"to-custom",write:"to-inbox-client-detector",identity:"custom"})
            and (.["harness-alerts-detector"] == {kind:"maildir",namespace:"harness-alerts",read:"to-inbox-client-detector",write:"to-custom",identity:"inbox-client-detector"})' \
     "${ATHENA_INBOX_REGISTRY}" >/dev/null; then
  ok "custom declares harness-alerts (custom reads to-custom) and its mirror (inbox-client-detector writes to-custom)"
else bad "custom declares both harness-alerts sides" "$(jq -c '.projects[0].entry.channels' "${ATHENA_INBOX_REGISTRY}")"; fi
if [ "$(jq -r '.projects[] | select(.file=="custom.json") | .entry.channels | keys_unsorted | map(select(startswith("harness-alerts"))) | join(",")' "${ATHENA_INBOX_REGISTRY}")" = "harness-alerts,harness-alerts-detector" ]; then
  ok "harness-alerts is declared before its mirror (the shared doorbell is attributed to the reader)"
else bad "harness-alerts is declared before its mirror" "order wrong"; fi
REG_ROOT="${TMP}/reg-root"
if ATHENA_INBOX_ROOT="${REG_ROOT}" "${WF_REPO}/scripts/setup-inbox-registry" --install >"${TMP}/reg.out" 2>&1 \
   && ATHENA_INBOX_ROOT="${REG_ROOT}" "${WF_REPO}/ai/bin/check-inbox-registry" >"${TMP}/chk.out" 2>&1; then
  ok "check-inbox-registry passes against a temp root installed from the committed registry"
else bad "check-inbox-registry passes against a temp root" "$(cat "${TMP}/reg.out" "${TMP}/chk.out" | tail -n 5)"; fi
if (cd "${WF_REPO}" && "${BIN}/inbox-wait" --dry-run >"${TMP}/bells.out" 2>&1) \
   && grep -qx "${ATHENA_INBOX_ROOT}/harness-alerts/to-custom/.event" "${TMP}/bells.out" \
   && grep -qx "${ATHENA_INBOX_ROOT}/harness-alerts/to-inbox-client-detector/.event" "${TMP}/bells.out"; then
  ok "this repo resolves the harness-alerts channel: the waiter arms on its doorbells"
else bad "this repo resolves the harness-alerts channel" "$(cat "${TMP}/bells.out")"; fi

# ---------------------------------------------------------------------------
printf '\nA-2  the alert body: the capture summary, never the token\n'
CAP="$(wf_make_capture "${DUMPS}" 20260923T100000Z-4242 tls)"
SIG="$(wf_signature_of "${CAP}")"
out="$("${ALERT}" "${CAP}" --dry-run 2>&1)"; rc=$?
if [ "${rc}" -eq 0 ] && grep -qx "signature: ${SIG}" <<<"${out}" && grep -qx 'step: tls' <<<"${out}" \
   && grep -qx "capture: ${CAP}" <<<"${out}" && grep -qx 'pid: 4242' <<<"${out}" \
   && grep -qx 'uptime_s: 3600' <<<"${out}" && grep -qx 'reconnecting_since: 113 (last restart)' <<<"${out}" \
   && grep -qx 'connected_since: 42 (last restart)' <<<"${out}" && grep -qx '  athena-inbox-client.rb:connect_nonblock' <<<"${out}"; then
  ok "signature, step, capture, pid, uptime, counts and frames"
else bad "signature, step, capture, pid, uptime, counts and frames" "rc=${rc} ${out}"; fi
if [ -z "$(msgs)" ]; then ok "--dry-run delivers nothing"; else bad "--dry-run delivers nothing" "$(msgs)"; fi
out="$(ATHENA_INBOX_CLIENT_CONFIG="${TMP}/no-such-config.json" "${ALERT}" "${CAP}" --dry-run 2>&1 >/dev/null)"; rc=$?
if [ "${rc}" -eq 0 ] && grep -q '^note: token guard NOT checked' <<<"${out}"; then ok "an unrunnable token guard says so ('not checked' never reads as 'checked')"; else bad "an unrunnable token guard says so" "rc=${rc} ${out}"; fi
CAPT="$(wf_make_capture "${DUMPS}" 20260923T100500Z-4245 tls "leak_${TOKEN:0:8}_here")"
out="$("${ALERT}" "${CAPT}" 2>&1)"; rc=$?
if [ "${rc}" -eq 2 ] && grep -q 'would carry the machine token' <<<"${out}" && grep -q '^  Fix: ' <<<"${out}" && [ -z "$(msgs)" ] \
   && ! grep -qF -- "${TOKEN:0:8}" <<<"${out}"; then
  ok "a capture carrying the token prefix is REFUSED (exit 2, Fix:), nothing delivered, the token not echoed"
else bad "a capture carrying the token prefix is refused" "rc=${rc} ${out} msgs=$(msgs)"; fi

# ---------------------------------------------------------------------------
printf '\nA-3  refusals: only a capture in the dump dir\n'
OUTSIDE="$(wf_make_capture "${TMP}/elsewhere" 20260923T100000Z-4242 tls)"
out="$("${ALERT}" "${OUTSIDE}" 2>&1)"; rc=$?
if [ "${rc}" -eq 2 ] && grep -q '^  Fix: ' <<<"${out}"; then ok "a capture outside the dump dir is exit 2 with a Fix:"; else bad "a capture outside the dump dir is exit 2" "rc=${rc} ${out}"; fi
mkdir -p "${DUMPS}/not-a-capture"
out="$("${ALERT}" "${DUMPS}/not-a-capture" 2>&1)"; rc=$?
if [ "${rc}" -eq 2 ]; then ok "a directory that is not a capture name is refused"; else bad "a directory that is not a capture name is refused" "rc=${rc} ${out}"; fi
out="$("${ALERT}" 2>&1)"; rc=$?
if [ "${rc}" -eq 1 ] && grep -q '^  Fix: ' <<<"${out}"; then ok "no argument is exit 1 with a Fix:"; else bad "no argument is exit 1 with a Fix:" "rc=${rc} ${out}"; fi
# The exit status is asserted separately: a here-string drops the producer's
# status, which the old `--help | grep -q` pipe carried through pipefail.
if help_out="$("${ALERT}" --help)" && grep -q 'inbox-client-alert' <<<"${help_out}"; then ok "--help prints the header, exit 0"; else bad "--help prints the header" "no"; fi

# ---------------------------------------------------------------------------
printf '\nA-4  a send wakes the harness session'"'"'s waiter (existing inbox-wait behaviour)\n'
BELLS="$(cd "${WF_REPO}" && "${BIN}/inbox-wait" --dry-run 2>/dev/null | sort -u | grep -c .)"
( cd "${WF_REPO}" && ATHENA_INBOX_WAIT_BUDGET=60 exec "${BIN}/inbox-wait" ) >"${TMP}/wait.out" 2>"${TMP}/wait.err" &
WAIT_CHILD=$!
# Block until the kernel reports the watches (bounded: 0.2 s cadence, 30 tries).
for _ in $(seq 1 30); do
  kill -0 "${WAIT_CHILD}" 2>/dev/null || break
  n=0
  for p in $(pgrep -P "${WAIT_CHILD}" 2>/dev/null); do
    for gc in "${p}" $(pgrep -P "${p}" 2>/dev/null); do
      n=$(( n + $(grep -h '^inotify wd:' /proc/"${gc}"/fdinfo/* 2>/dev/null | wc -l) ))
    done
  done
  [ "${n}" -ge "${BELLS}" ] && break
  sleep 0.2
done
SENT="$("${ALERT}" "${CAP}" 2>"${TMP}/send.err")"; SRC=$?
timeout 20 tail --pid="${WAIT_CHILD}" -f /dev/null 2>/dev/null
wait "${WAIT_CHILD}"; WRC=$?; WAIT_CHILD=""
if [ "${SRC}" -eq 0 ] && [ "$(field "${SENT}" sent)" != "" ]; then ok "the send exits 0 and names the delivered file"; else bad "the send exits 0 and names the delivered file" "rc=${SRC} ${SENT} $(cat "${TMP}/send.err")"; fi
if [ "${WRC}" -eq 0 ] && grep -q '^athena:inbox: rang-channels: .*harness-alerts' "${TMP}/wait.out"; then
  ok "inbox-wait woke (exit 0) and named harness-alerts"
else bad "inbox-wait woke and named harness-alerts" "rc=${WRC} out=$(cat "${TMP}/wait.out") err=$(tail -n 3 "${TMP}/wait.err")"; fi

# ---------------------------------------------------------------------------
printf '\nA-5  the delivered message\n'
M="$(msgs)"
if [ "$(printf '%s\n' "${M}" | grep -c .)" -eq 1 ] && [ "$(basename -- "${M}")" = "$(field "${SENT}" sent)" ]; then ok "exactly ONE message in harness-alerts/to-custom"; else bad "exactly ONE message in harness-alerts/to-custom" "${M}"; fi
if grep -qx 'from: inbox-client-detector' <<<"$(sed -n '2,5p' "${M}")" && grep -qx 'to: custom' <<<"$(sed -n '2,6p' "${M}")" \
   && grep -qx "re: ${CAP}" <<<"$(sed -n '2,7p' "${M}")" && grep -q '^sent_at: [0-9T:-]*Z$' <<<"$(sed -n '2,7p' "${M}")"; then
  ok "frontmatter: from inbox-client-detector, to custom, sent_at, re: the capture"
else bad "frontmatter: from/to/sent_at/re" "$(head -n 8 "${M}")"; fi
if ! grep -qF -- "${TOKEN:0:8}" "${M}"; then ok "the message carries no token"; else bad "the message carries no token" "leak"; fi
if [ -z "$(find "${ATHENA_INBOX_ROOT}/harness-alerts" -name '*.consumer.lock')" ] && [ -e "${TO_CUSTOM}/.sender.lock" ]; then
  ok "the writer took only to-custom/.sender.lock, never a consumer lock"
else bad "the writer took only .sender.lock" "$(find "${ATHENA_INBOX_ROOT}/harness-alerts" -name '*.lock')"; fi

# ---------------------------------------------------------------------------
printf '\nA-6  end to end: read-inbox acks it, wedge-ticket-decide verifies it -> create\n'
RD="$(cd "${WF_REPO}" && "${BIN}/read-inbox" harness-alerts 2>&1)"; RRC=$?
ACKED="${TO_CUSTOM}/.acked/$(basename -- "${M}")"
if [ "${RRC}" -eq 0 ] && [ -f "${ACKED}" ] && [ -z "$(msgs)" ]; then ok "read-inbox harness-alerts read and acked it into .acked/"; else bad "read-inbox harness-alerts read and acked it" "rc=${RRC} ${RD}"; fi
printf '[]' >"${TMP}/none.json"
D="$("${DECIDE}" --message "${ACKED}" --tickets "${TMP}/none.json" 2>&1)"; DRC=$?
if [ "${DRC}" -eq 0 ] && [ "$(field "${D}" decision)" = "create" ] && [ "$(field "${D}" title)" = "Inbox client wedge [wedge:${SIG:0:8}]: stalled at tls" ]; then
  ok "the real delivered message verifies against the capture and resolves create"
else bad "the real delivered message verifies and resolves create" "rc=${DRC} ${D}"; fi

# ---------------------------------------------------------------------------
printf '\nA-7  a failed send is loud and never reads as sent\n'
EMPTY_ROOT="${TMP}/empty-root"; mkdir -p "${EMPTY_ROOT}/projects"; chmod 700 "${EMPTY_ROOT}" "${EMPTY_ROOT}/projects"
out="$(ATHENA_INBOX_ROOT="${EMPTY_ROOT}" "${ALERT}" "${CAP}" 2>&1)"; rc=$?
if [ "${rc}" -eq 4 ] && grep -q 'harness-alerts send FAILED' <<<"${out}" && grep -q '^  Fix: .*setup-inbox-registry' <<<"${out}" \
   && ! grep -q '^sent' <<<"${out}"; then
  ok "no registry entry -> exit 4, 'send FAILED', a Fix: naming the registry install"
else bad "no registry entry -> exit 4 with a Fix:" "rc=${rc} ${out}"; fi
if [ -z "$(find "${EMPTY_ROOT}" -name '*.md')" ]; then ok "nothing was delivered anywhere on the failed send"; else bad "nothing was delivered on the failed send" "$(find "${EMPTY_ROOT}" -name '*.md')"; fi

printf '\n'
if [ "${FAIL}" -eq 0 ]; then echo "VERDICT: PASS (${PASS} cases)"; exit 0; fi
echo "VERDICT: FAIL (${FAIL} of $((PASS+FAIL)) cases failed)"
exit 1
