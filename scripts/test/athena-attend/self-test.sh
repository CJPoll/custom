#!/usr/bin/env bash
# Self-test for scripts/athena-attend-run.sh and scripts/setup-athena-attend.
#
# Nothing real is touched:
#   * `claude` is a stub (ATHENA_ATTEND_CLAUDE) whose exit code, receipt-touch,
#     transcript growth and argv log each case chooses. The real binary would
#     start a model session; this suite must never do that, and never does.
#   * `inbox-wait` / `inbox-status` are stubs (ATHENA_ATTEND_INBOX_BIN_DIR).
#   * the CRONTAB is a PATH shim over a file in the case tmpdir; the live crontab
#     (shipwright + inbox-client entries) is never opened. Each case seeds the
#     fake crontab with unrelated lines so "unrelated entries survive" is
#     asserted, not assumed.
#
# Every assertion is about a decision INVISIBLE from the outside in production —
# which is why it is worth a test:
#   * a runner that invokes the model on a quiet budget burns tokens for nothing;
#   * one that treats "could not count" as zero goes silently dark (the
#     silent-dark class ai/CLAUDE.md warns about);
#   * an epoch that never rotates grows the transcript — and the per-wake bill —
#     without bound;
#   * a runner that leaked CLAUDE_AGENT_* would make its own handler a subagent,
#     which inbox-wait would then refuse to let ack;
#   * an installer that appends instead of replacing ends with eleven copies of a
#     line, or loses the shipwright's.
#
# Run: bash scripts/test/athena-attend/self-test.sh
#      (or: scripts/setup-athena-attend --self-test)
# NOTE: never call `setup-athena-attend --self-test` from here — it runs THIS
# file, and the pair would recurse.

set -uo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SCRIPTS="$(cd -- "${HERE}/../.." && pwd -P)"
RUNNER="${SCRIPTS}/athena-attend-run.sh"
INSTALLER="${SCRIPTS}/setup-athena-attend"

PASS=0; FAIL=0
BG_PID=""
TMP="$(mktemp -d)"
cleanup() {
  [ -n "$BG_PID" ] && { kill "$BG_PID" 2>/dev/null; wait "$BG_PID" 2>/dev/null; }
  rm -rf -- "$TMP"
}
trap cleanup EXIT INT TERM
ok()  { printf '  ok    %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  FAIL  %s\n        %s\n' "$1" "$2"; FAIL=$((FAIL+1)); }

# ---- per-case fixtures -----------------------------------------------------
CASE_N=0
setup_case() {
  CASE_N=$((CASE_N+1))
  CD="${TMP}/$(printf '%02d' "$CASE_N")-$1"
  CTRL="${CD}/ctrl"; STATE="${CD}/state"; PROJ="${CD}/proj"
  TRANSCRIPT="${CD}/transcript"; INBOXBIN="${CD}/inbin"; SHIMBIN="${CD}/shimbin"
  mkdir -p "$CTRL" "$STATE" "$PROJ" "$TRANSCRIPT" "$INBOXBIN" "$SHIMBIN"
  ( cd "$PROJ" && git init -q && git config user.email t@t && git config user.name t \
      && git commit -q --allow-empty -m init ) 2>/dev/null
  CLAUDE_STUB="${CD}/claude"
  ARGV="${CTRL}/argv"; ENVLOG="${CTRL}/env"; BRIEFLOG="${CTRL}/brief"
  : >"$ARGV"; : >"$ENVLOG"; : >"$BRIEFLOG"

  cat >"$CLAUDE_STUB" <<STUB
#!/usr/bin/env bash
CTRL='${CTRL}'
printf '%s\n' "\$*" >> "\$CTRL/argv"
printf 'ATTENDED=[%s] AGENT_ID=[%s] AGENT_TYPE=[%s] RECEIPT=[%s] LEDGER=[%s] PROJECT=[%s]\n' \
  "\${CLAUDE_CODE_SESSION_ATTENDED:-UNSET}" "\${CLAUDE_AGENT_ID:-UNSET}" "\${CLAUDE_AGENT_TYPE:-UNSET}" \
  "\${ATHENA_ATTEND_RECEIPT:+SET}" "\${ATHENA_ATTEND_LEDGER:+SET}" "\${ATHENA_ATTEND_PROJECT_DIR:+SET}" >> "\$CTRL/env"
prev=""; for a in "\$@"; do [ "\$prev" = "-p" ] && { printf '%s\n' "\$a" >> "\$CTRL/brief"; break; }; prev="\$a"; done
uuid=""; want=""
for a in "\$@"; do
  if [ -n "\$want" ]; then uuid="\$a"; want=""; continue; fi
  case "\$a" in --session-id|--resume) want=1;; esac
done
if [ -s "\$CTRL/transcript_bytes" ] && [ -n "\$uuid" ] && [ -n "\${ATHENA_ATTEND_TRANSCRIPT_DIR:-}" ]; then
  n="\$(cat "\$CTRL/transcript_bytes")"
  head -c "\$n" /dev/zero | tr '\0' x >> "\${ATHENA_ATTEND_TRANSCRIPT_DIR}/\${uuid}.jsonl"
fi
[ -e "\$CTRL/touch_receipt" ] && [ -n "\${ATHENA_ATTEND_RECEIPT:-}" ] && touch "\$ATHENA_ATTEND_RECEIPT"
printf '{"total_cost_usd":0.0123,"num_turns":2,"result":"ok"}\n'
ec=0
if [ -s "\$CTRL/exits" ]; then ec="\$(head -n1 "\$CTRL/exits")"; sed -i '1d' "\$CTRL/exits"; fi
exit "\$ec"
STUB
  chmod +x "$CLAUDE_STUB"

  cat >"${INBOXBIN}/inbox-status" <<STUB
#!/usr/bin/env bash
CTRL='${CTRL}'
[ -e "\$CTRL/status_fail" ] && exit 1
n=0
if [ -e "\$CTRL/status_always" ]; then n="\$(cat "\$CTRL/status_always")"
elif [ -s "\$CTRL/status_counts" ]; then n="\$(head -n1 "\$CTRL/status_counts")"; sed -i '1d' "\$CTRL/status_counts"
fi
printf '{"channels":[{"new":%s}]}\n' "\$n"
STUB
  chmod +x "${INBOXBIN}/inbox-status"

  cat >"${INBOXBIN}/inbox-wait" <<STUB
#!/usr/bin/env bash
CTRL='${CTRL}'
case "\${1:-}" in --dry-run) echo "doorbells: (stub for tests)"; exit 0;; esac
[ -e "\$CTRL/wait_block" ] && exec sleep 3600
ec=0
if [ -s "\$CTRL/wait_exits" ]; then ec="\$(head -n1 "\$CTRL/wait_exits")"; sed -i '1d' "\$CTRL/wait_exits"; fi
exit "\$ec"
STUB
  chmod +x "${INBOXBIN}/inbox-wait"

  # crontab shim (installer cases)
  FAKE_CRONTAB="${CD}/crontab.txt"
  cat >"${SHIMBIN}/crontab" <<SHIM
#!/usr/bin/env bash
set -u
f='${FAKE_CRONTAB}'
case "\${1:-}" in
  -l) if [ -s "\$f" ]; then cat "\$f"; else echo "no crontab for user" >&2; exit 1; fi ;;
  -)  cat > "\$f" ;;
  -r) rm -f "\$f" ;;
  *)  echo "crontab shim: unsupported: \$*" >&2; exit 64 ;;
esac
SHIM
  chmod +x "${SHIMBIN}/crontab"

  # The fixed environment every runner invocation carries. CLAUDE_AGENT_* and
  # SESSION_ATTENDED are SCRUBBED (-u) so a leak would show as the handler seeing
  # them SET — which is the thing the env-clean case asserts against.
  ATTEND_ENV=( -u CLAUDE_AGENT_ID -u CLAUDE_AGENT_TYPE -u CLAUDE_CODE_SESSION_ATTENDED
    ATHENA_ATTEND_CLAUDE="$CLAUDE_STUB" ATHENA_ATTEND_INBOX_BIN_DIR="$INBOXBIN"
    ATHENA_ATTEND_PROJECT_DIR="$PROJ" ATHENA_ATTEND_STATE_DIR="$STATE"
    ATHENA_ATTEND_TRANSCRIPT_DIR="$TRANSCRIPT"
    ATHENA_ATTEND_MIN_BACKOFF=0 ATHENA_ATTEND_MAX_BACKOFF=0 )
}

# run the runner (foreground). Args of the form VAR=val are extra environment;
# everything else is a runner flag. (env would treat a leading --flag as its own
# command, so the split is mandatory.)
run_attend() {
  local envs=() flags=() a
  for a in "$@"; do case "$a" in *=*) envs+=("$a") ;; *) flags+=("$a") ;; esac; done
  env "${ATTEND_ENV[@]}" "${envs[@]}" bash "$RUNNER" "${flags[@]}"
}
handler_calls() { [ -f "$ARGV" ] && wc -l < "$ARGV" | tr -d ' ' || echo 0; }
uuid_of() { sed -n "${1}p" "$ARGV" | sed -n 's/.*--\(session-id\|resume\) \([^ ]*\).*/\2/p'; }

echo "== athena-attend runner + installer self-test =="

# 1. wait 0 + new>0 -> exactly one handler call, carrying --session-id
setup_case new-triggers-handler
printf '0\n' >"$CTRL/wait_exits"; printf '1\n0\n' >"$CTRL/status_counts"; : >"$CTRL/touch_receipt"
rc=0; run_attend --once >/dev/null 2>&1 || rc=$?
[ "$(handler_calls)" = 1 ] && grep -q -- '--session-id' "$ARGV" && [ "$rc" = 0 ] \
  && ok "new>0 after wait 0: one handler call with --session-id, exit 0" \
  || bad "new>0 after wait 0" "calls=$(handler_calls) rc=$rc argv=[$(cat "$ARGV")]"

# 2. wait 0 + new=0 -> no handler call
setup_case quiet-no-handler
printf '0\n' >"$CTRL/wait_exits"; printf '0\n' >"$CTRL/status_counts"
rc=0; run_attend --once >/dev/null 2>&1 || rc=$?
[ "$(handler_calls)" = 0 ] && [ "$rc" = 0 ] \
  && ok "new=0: no handler call (quiet hours cost zero model turns)" \
  || bad "new=0 quiet" "calls=$(handler_calls) rc=$rc"

# 3. wait 75 + new>0 -> handler called (lost-wake closure)
setup_case budget-recheck
printf '75\n' >"$CTRL/wait_exits"; printf '1\n0\n' >"$CTRL/status_counts"; : >"$CTRL/touch_receipt"
run_attend --once >/dev/null 2>&1
[ "$(handler_calls)" = 1 ] \
  && ok "wait 75 still re-checks inbox and handles new mail (missed-bell closure)" \
  || bad "wait 75 recheck" "calls=$(handler_calls)"

# 4. wait 75 + new=0 -> no handler call
setup_case budget-quiet
printf '75\n' >"$CTRL/wait_exits"; printf '0\n' >"$CTRL/status_counts"
run_attend --once >/dev/null 2>&1
[ "$(handler_calls)" = 0 ] && ok "wait 75 with nothing waiting invokes no model" \
  || bad "wait 75 quiet" "calls=$(handler_calls)"

# 5. wait 2 -> stop marker; --once exits 75; next --once refuses without arming
setup_case refused-stops
printf '2\n' >"$CTRL/wait_exits"
rc=0; run_attend --once >/dev/null 2>&1 || rc=$?
if [ -e "${STATE}/attend.stopped" ] && [ "$rc" = 75 ]; then
  before="$(cat "$ARGV")"
  rc2=0; run_attend --once >/dev/null 2>&1 || rc2=$?
  [ "$rc2" = 75 ] && [ "$(cat "$ARGV")" = "$before" ] \
    && ok "inbox-wait exit 2 writes attend.stopped, exits 75, and next run refuses" \
    || bad "stop refuse" "rc2=$rc2"
else bad "stop marker" "rc=$rc stopped=$([ -e "${STATE}/attend.stopped" ] && echo y || echo n)"; fi

# 6. handler blocked (exit 0, no receipt) -> --once exit 69, wedge counter untouched
setup_case blocked
printf '0\n' >"$CTRL/wait_exits"; printf '1\n0\n' >"$CTRL/status_counts"  # NO touch_receipt
rc=0; run_attend --once >/dev/null 2>&1 || rc=$?
fails="$(cat "${STATE}/consecutive-failures" 2>/dev/null || echo 0)"
[ "$rc" = 69 ] && [ "${fails:-0}" = 0 ] \
  && ok "handler exit 0 without a receipt = BLOCKED (exit 69), wedge counter untouched" \
  || bad "blocked" "rc=$rc fails=$fails"

# 7. handler failed (exit 1) -> --once exit 1, one consecutive failure
setup_case failed
printf '0\n' >"$CTRL/wait_exits"; printf '1\n0\n' >"$CTRL/status_counts"; : >"$CTRL/touch_receipt"
printf '1\n' >"$CTRL/exits"
rc=0; run_attend --once >/dev/null 2>&1 || rc=$?
[ "$rc" = 1 ] && [ "$(cat "${STATE}/consecutive-failures" 2>/dev/null)" = 1 ] \
  && ok "handler exit≠0 = failed (exit 1), consecutive-failures=1" \
  || bad "failed" "rc=$rc fails=$(cat "${STATE}/consecutive-failures" 2>/dev/null)"

# 8. FAIL_ESCALATE consecutive failures -> attend.wedged, supervisor exits 75
setup_case wedge
printf '0\n0\n0\n0\n0\n' >"$CTRL/wait_exits"; printf '1\n' >"$CTRL/status_always"
printf '1\n1\n1\n1\n1\n' >"$CTRL/exits"; : >"$CTRL/touch_receipt"
rc=0; run_attend ATHENA_ATTEND_FAIL_ESCALATE=3 ATHENA_ATTEND_MAX_CYCLES=6 >/dev/null 2>&1 || rc=$?
[ -e "${STATE}/attend.wedged" ] && [ "$rc" = 75 ] \
  && ok "N consecutive handler failures write attend.wedged and exit 75 (loud, not silent)" \
  || bad "wedge" "rc=$rc wedged=$([ -e "${STATE}/attend.wedged" ] && echo y || echo n)"

# 9. resume on wake 2 (same epoch, same uuid)
setup_case resume
printf '0\n0\n' >"$CTRL/wait_exits"; printf '1\n0\n1\n0\n' >"$CTRL/status_counts"; : >"$CTRL/touch_receipt"
run_attend ATHENA_ATTEND_MAX_CYCLES=2 ATHENA_ATTEND_EPOCH_MAX_WAKES=30 >/dev/null 2>&1
u1="$(uuid_of 1)"; u2="$(uuid_of 2)"
grep -q -- '--session-id' <<<"$(sed -n 1p "$ARGV")" && grep -q -- '--resume' <<<"$(sed -n 2p "$ARGV")" \
  && [ -n "$u1" ] && [ "$u1" = "$u2" ] \
  && ok "wake 2 in an epoch resumes the same session (--resume, same uuid)" \
  || bad "resume" "line1=[$(sed -n 1p "$ARGV")] line2=[$(sed -n 2p "$ARGV")]"

# 10. rotation on max-wakes -> fresh session, different uuid
setup_case rotate-wakes
printf '0\n0\n' >"$CTRL/wait_exits"; printf '1\n0\n1\n0\n' >"$CTRL/status_counts"; : >"$CTRL/touch_receipt"
run_attend ATHENA_ATTEND_MAX_CYCLES=2 ATHENA_ATTEND_EPOCH_MAX_WAKES=1 >/dev/null 2>&1
u1="$(uuid_of 1)"; u2="$(uuid_of 2)"
grep -q -- '--session-id' <<<"$(sed -n 2p "$ARGV")" && [ -n "$u1" ] && [ -n "$u2" ] && [ "$u1" != "$u2" ] \
  && ok "epoch rotates after EPOCH_MAX_WAKES: fresh --session-id, new uuid" \
  || bad "rotate-wakes" "u1=$u1 u2=$u2 line2=[$(sed -n 2p "$ARGV")]"

# 11. rotation on transcript bytes
setup_case rotate-bytes
printf '0\n0\n' >"$CTRL/wait_exits"; printf '1\n0\n1\n0\n' >"$CTRL/status_counts"
: >"$CTRL/touch_receipt"; printf '50\n' >"$CTRL/transcript_bytes"
run_attend ATHENA_ATTEND_MAX_CYCLES=2 ATHENA_ATTEND_EPOCH_MAX_WAKES=30 ATHENA_ATTEND_EPOCH_MAX_BYTES=10 >/dev/null 2>&1
u1="$(uuid_of 1)"; u2="$(uuid_of 2)"
grep -q -- '--session-id' <<<"$(sed -n 2p "$ARGV")" && [ "$u1" != "$u2" ] \
  && ok "epoch rotates when the transcript exceeds EPOCH_MAX_BYTES" \
  || bad "rotate-bytes" "u1=$u1 u2=$u2 line2=[$(sed -n 2p "$ARGV")]"

# 12. unmeasurable transcript -> n/a in wakes.log, and NO spurious rotation
setup_case na-bytes
printf '0\n0\n' >"$CTRL/wait_exits"; printf '1\n0\n1\n0\n' >"$CTRL/status_counts"; : >"$CTRL/touch_receipt"
# no transcript_bytes control -> stub writes no .jsonl -> unmeasurable
run_attend ATHENA_ATTEND_MAX_CYCLES=2 ATHENA_ATTEND_EPOCH_MAX_WAKES=30 ATHENA_ATTEND_EPOCH_MAX_BYTES=10 >/dev/null 2>&1
grep -q 'transcript_bytes=n/a' "${STATE}/wakes.log" && grep -q -- '--resume' <<<"$(sed -n 2p "$ARGV")" \
  && ok "unmeasurable transcript logs n/a (never 0) and does NOT rotate on bytes" \
  || bad "na-bytes" "wakes.log=[$(cat "${STATE}/wakes.log" 2>/dev/null)] line2=[$(sed -n 2p "$ARGV")]"

# 13. resume failure -> next wake retries a FRESH epoch, once
setup_case resume-fail-fresh
# MAX_BURST=1 + always-1 so each cycle handles exactly once (a failed cycle
# consumes no re-count, which a queue would misalign).
printf '0\n0\n0\n' >"$CTRL/wait_exits"; printf '1\n' >"$CTRL/status_always"; : >"$CTRL/touch_receipt"
printf '0\n1\n0\n' >"$CTRL/exits"   # wake1 ok, wake2 (resume) fails, wake3 ok
run_attend ATHENA_ATTEND_MAX_CYCLES=3 ATHENA_ATTEND_MAX_BURST=1 ATHENA_ATTEND_EPOCH_MAX_WAKES=30 ATHENA_ATTEND_FAIL_ESCALATE=9 >/dev/null 2>&1
u1="$(uuid_of 1)"; u3="$(uuid_of 3)"
grep -q -- '--resume' <<<"$(sed -n 2p "$ARGV")" && grep -q -- '--session-id' <<<"$(sed -n 3p "$ARGV")" \
  && [ -n "$u1" ] && [ -n "$u3" ] && [ "$u1" != "$u3" ] \
  && ok "a failed --resume forces a fresh epoch on the next wake" \
  || bad "resume-fail-fresh" "u1=$u1 u3=$u3 line3=[$(sed -n 3p "$ARGV")]"

# 14. brief byte-identical across wakes (cache-hittable prefix)
setup_case brief-stable
printf '0\n0\n' >"$CTRL/wait_exits"; printf '1\n0\n1\n0\n' >"$CTRL/status_counts"; : >"$CTRL/touch_receipt"
run_attend ATHENA_ATTEND_MAX_CYCLES=2 >/dev/null 2>&1
b1="$(sed -n 1p "$BRIEFLOG")"; b2="$(sed -n 2p "$BRIEFLOG")"
[ -n "$b1" ] && [ "$b1" = "$b2" ] \
  && ok "the -p brief is byte-identical on every wake (shared prefix stays cacheable)" \
  || bad "brief-stable" "b1len=${#b1} b2len=${#b2}"

# 15. handler env: no CLAUDE_AGENT_*/ATTENDED leaked; receipt/ledger/project ARE set
setup_case env-clean
printf '0\n' >"$CTRL/wait_exits"; printf '1\n0\n' >"$CTRL/status_counts"; : >"$CTRL/touch_receipt"
run_attend --once >/dev/null 2>&1
line="$(sed -n 1p "$ENVLOG")"
grep -q 'ATTENDED=\[UNSET\]' <<<"$line" && grep -q 'AGENT_ID=\[UNSET\]' <<<"$line" \
  && grep -q 'AGENT_TYPE=\[UNSET\]' <<<"$line" && grep -q 'RECEIPT=\[SET\]' <<<"$line" \
  && grep -q 'LEDGER=\[SET\]' <<<"$line" && grep -q 'PROJECT=\[SET\]' <<<"$line" \
  && ok "handler env: CLAUDE_AGENT_*/SESSION_ATTENDED unset; receipt/ledger/project set" \
  || bad "env-clean" "env=[$line]"

# 16. inbox-status non-document -> "could not count", no handler, no marker
setup_case count-failed
printf '0\n' >"$CTRL/wait_exits"; : >"$CTRL/status_fail"
rc=0; run_attend --once >/dev/null 2>&1 || rc=$?
[ "$(handler_calls)" = 0 ] && [ ! -e "${STATE}/attend.stopped" ] && [ ! -e "${STATE}/attend.wedged" ] \
  && grep -q 'could not count' "${STATE}/attend.log" && [ "$rc" = 0 ] \
  && ok "inbox-status non-document = 'could not count' (never treated as 0): no handler, no marker" \
  || bad "count-failed" "calls=$(handler_calls) rc=$rc"

# 17. --help on stdout, exit 0, no side effect
setup_case help
out="$(run_attend --help 2>/dev/null)"; rc=$?
[ "$rc" = 0 ] && grep -q 'Usage:' <<<"$out" && [ ! -e "${STATE}/attend.log" ] \
  && ok "--help prints Usage on stdout, exit 0, no state written" \
  || bad "help" "rc=$rc log=$([ -e "${STATE}/attend.log" ] && echo y || echo n)"

# 18. --dry-run prints the command and calls no handler
setup_case dry-run
out="$(run_attend --dry-run 2>/dev/null)"; rc=$?
[ "$rc" = 0 ] && grep -q 'handler command line' <<<"$out" && grep -q 'changed nothing' <<<"$out" \
  && [ "$(handler_calls)" = 0 ] \
  && ok "--dry-run prints the command line and starts no session" \
  || bad "dry-run" "rc=$rc calls=$(handler_calls)"

# 19. a second invocation exits 0 under the lock (single instance)
setup_case single-instance
: >"$CTRL/wait_block"   # the bg supervisor blocks in inbox-wait, holding the lock
env "${ATTEND_ENV[@]}" ATHENA_ATTEND_MAX_CYCLES=1 bash "$RUNNER" >/dev/null 2>&1 &
BG_PID=$!
# wait (bounded, blocking) until the pidfile shows the bg run holds the lock
for _ in $(seq 1 50); do [ -s "${STATE}/attend.pid" ] && break; sleep 0.1; done
rc=0; run_attend --once >/dev/null 2>&1 || rc=$?
[ "$rc" = 0 ] && [ "$(handler_calls)" = 0 ] \
  && ok "a second invocation finds the flock held and exits 0 without arming (single instance)" \
  || bad "single-instance" "rc=$rc calls=$(handler_calls)"
kill "$BG_PID" 2>/dev/null; wait "$BG_PID" 2>/dev/null; BG_PID=""

# 20. SIGTERM reaps the waiter child and exits 143
setup_case sigterm
: >"$CTRL/wait_block"
env "${ATTEND_ENV[@]}" ATHENA_ATTEND_MAX_CYCLES=1 bash "$RUNNER" >/dev/null 2>&1 &
BG_PID=$!
for _ in $(seq 1 50); do [ -s "${STATE}/attend.child.pid" ] && break; sleep 0.1; done
childpid="$(cat "${STATE}/attend.child.pid" 2>/dev/null)"
kill -TERM "$BG_PID" 2>/dev/null
wait "$BG_PID" 2>/dev/null; trc=$?; BG_PID=""
# the waiter child must be dead (bounded wait for the reap); exit 143 (128+SIGTERM)
for _ in $(seq 1 50); do [ -n "$childpid" ] && kill -0 "$childpid" 2>/dev/null || break; sleep 0.1; done
if [ -n "$childpid" ] && ! kill -0 "$childpid" 2>/dev/null && [ "$trc" = 143 ]; then
  ok "SIGTERM reaps the waiter child (pid dead) and the supervisor exits 143"
else bad "sigterm" "childpid=$childpid alive=$(kill -0 "${childpid:-0}" 2>/dev/null && echo y || echo n) trc=$trc"; fi

# 21. kill -9 orphan adopted on next start
setup_case orphan
: >"$CTRL/wait_block"
env "${ATTEND_ENV[@]}" ATHENA_ATTEND_MAX_CYCLES=1 bash "$RUNNER" >/dev/null 2>&1 &
BG_PID=$!
for _ in $(seq 1 50); do [ -s "${STATE}/attend.child.pid" ] && break; sleep 0.1; done
orphanpid="$(cat "${STATE}/attend.child.pid" 2>/dev/null)"
kill -9 "$BG_PID" 2>/dev/null; wait "$BG_PID" 2>/dev/null; BG_PID=""
# child was orphaned (still alive). A fresh start must reap it before proceeding.
if [ -n "$orphanpid" ] && kill -0 "$orphanpid" 2>/dev/null; then
  rm -f "$CTRL/wait_block"; printf '0\n' >"$CTRL/wait_exits"; printf '0\n' >"$CTRL/status_counts"
  run_attend --once >/dev/null 2>&1
  # give the reap a bounded moment
  for _ in $(seq 1 50); do kill -0 "$orphanpid" 2>/dev/null || break; sleep 0.1; done
  ! kill -0 "$orphanpid" 2>/dev/null \
    && ok "a SIGKILLed supervisor's orphaned waiter is reaped on the next start" \
    || bad "orphan" "orphan $orphanpid still alive after restart"
else bad "orphan" "could not orphan a child (pid=$orphanpid)"; fi

# ---- reliability: the mechanism must never go silent on a non-success -------
# terminal state, must re-arm on both wake paths, must survive a transient, and
# must not spin or run an unbounded one-shot wait. (Owner: the continuous
# background wait "felt unreliable"; silence is not success.)

# 28. inotify fault (exit 1) is survived, not fatal and not silent
setup_case fault-survives
printf '1\n1\n0\n' >"$CTRL/wait_exits"; printf '1\n' >"$CTRL/status_always"; : >"$CTRL/touch_receipt"
run_attend ATHENA_ATTEND_MAX_CYCLES=3 ATHENA_ATTEND_MAX_BURST=1 >/dev/null 2>&1
# two faults, then a rang wake that handles: proves the loop re-armed through the
# faults, logged them, and wrote no stop/wedge marker (a dead watch is not quiet)
[ "$(handler_calls)" -ge 1 ] && grep -qi 'fault' "${STATE}/attend.log" \
  && [ ! -e "${STATE}/attend.stopped" ] && [ ! -e "${STATE}/attend.wedged" ] \
  && ok "inotify fault (exit 1) survived: re-arms, logs the fault, no marker, not silent" \
  || bad "fault-survives" "calls=$(handler_calls) log=[$(tail -3 "${STATE}/attend.log" 2>/dev/null)]"

# 29. a single transient handler failure does not kill the loop
setup_case transient-survives
printf '0\n0\n' >"$CTRL/wait_exits"; printf '1\n' >"$CTRL/status_always"; : >"$CTRL/touch_receipt"
printf '1\n0\n' >"$CTRL/exits"   # cycle1 handler fails, cycle2 succeeds
run_attend ATHENA_ATTEND_MAX_CYCLES=2 ATHENA_ATTEND_MAX_BURST=1 ATHENA_ATTEND_FAIL_ESCALATE=6 >/dev/null 2>&1
[ "$(handler_calls)" = 2 ] && [ "$(cat "${STATE}/consecutive-failures" 2>/dev/null)" = 0 ] \
  && [ ! -e "${STATE}/attend.wedged" ] \
  && ok "a single transient handler failure is survived: backs off, next wake succeeds, streak reset" \
  || bad "transient-survives" "calls=$(handler_calls) fails=$(cat "${STATE}/consecutive-failures" 2>/dev/null)"

# 30. the loop re-arms across a 0 -> 75 -> 0 sequence (75 is NOT "all clear")
setup_case rearm-mixed
printf '0\n75\n0\n' >"$CTRL/wait_exits"; printf '1\n0\n0\n1\n0\n' >"$CTRL/status_counts"; : >"$CTRL/touch_receipt"
run_attend ATHENA_ATTEND_MAX_CYCLES=3 >/dev/null 2>&1
[ "$(handler_calls)" = 2 ] \
  && ok "re-arms on BOTH exit 0 (rang) and exit 75 (quiet budget): handles across 0->75->0" \
  || bad "rearm-mixed" "calls=$(handler_calls)"

# 31. no busy-spin, and the wait is bounded/blocking (safe-wait Hard Rule)
setup_case no-spin-static
if grep -Eq 'do[[:space:]]+:[[:space:]]*;[[:space:]]*done' "$RUNNER"; then
  bad "no-spin-static" "the runner contains a bare busy-spin loop body ('do :; done')"
elif ! grep -qF 'wait "$child"' "$RUNNER"; then
  bad "no-spin-static" "the waiter is not blocked on with a kernel wait (would poll/spin)"
elif ! grep -qF 'run_child "$INBOX_WAIT"' "$RUNNER"; then
  bad "no-spin-static" "the waiter is not invoked through the blocking run_child helper"
elif ! grep -qF 'run_child sleep' "$RUNNER"; then
  bad "no-spin-static" "backoff is not a real bounded sleep"
else
  ok "no busy-spin: the waiter blocks via a kernel wait, backoff is a real bounded sleep"
fi

# ---- installer -------------------------------------------------------------
UNRELATED_SHIPWRIGHT='0 * * * * /home/cjpoll/dev/custom/scripts/athena-shipwright-run.sh'
UNRELATED_OTHER='@reboot /home/cjpoll/dev/custom/scripts/athena-attend-run.sh --project /home/cjpoll/dev/gen_saas'

# a case-local main-checkout runner dir (a pre-merge tree has none; the real
# resolver is exercised only conceptually — here we assert against the copy).
inst_env() {
  local envs=() flags=() a
  for a in "$@"; do case "$a" in *=*) envs+=("$a") ;; *) flags+=("$a") ;; esac; done
  env PATH="${SHIMBIN}:${PATH}" \
    ATHENA_ATTEND_RUNNER_DIR="$RUNNER_DIR_FIX" \
    ATHENA_ATTEND_INBOX_BIN_DIR="$INBOXBIN" \
    "${envs[@]}" bash "$INSTALLER" "${flags[@]}"
}
make_runner_fix() { RUNNER_DIR_FIX="${CD}/bin"; mkdir -p "$RUNNER_DIR_FIX"; cp "$RUNNER" "${RUNNER_DIR_FIX}/athena-attend-run.sh"; }

# 22. install writes both entries; idempotent; preserves unrelated lines
setup_case install
make_runner_fix
printf '%s\n%s\n' "$UNRELATED_SHIPWRIGHT" "$UNRELATED_OTHER" >"$FAKE_CRONTAB"
inst_env --install --project "$PROJ" >/dev/null 2>&1
n1="$(grep -c "athena-attend-run.sh --project ${PROJ}\$" "$FAKE_CRONTAB")"
inst_env --install --project "$PROJ" >/dev/null 2>&1   # re-install
n2="$(grep -c "athena-attend-run.sh --project ${PROJ}\$" "$FAKE_CRONTAB")"
[ "$n1" = 2 ] && [ "$n2" = 2 ] \
  && grep -qF "$UNRELATED_SHIPWRIGHT" "$FAKE_CRONTAB" && grep -qF "$UNRELATED_OTHER" "$FAKE_CRONTAB" \
  && ok "install writes exactly 2 entries, is idempotent, and preserves unrelated + other-project lines" \
  || bad "install" "n1=$n1 n2=$n2"

# 23. remove deletes this project's entries, preserves the others
setup_case remove
make_runner_fix
printf '%s\n%s\n' "$UNRELATED_SHIPWRIGHT" "$UNRELATED_OTHER" >"$FAKE_CRONTAB"
inst_env --install --project "$PROJ" >/dev/null 2>&1
inst_env --remove --project "$PROJ" >/dev/null 2>&1
[ "$(grep -c "athena-attend-run.sh --project ${PROJ}\$" "$FAKE_CRONTAB")" = 0 ] \
  && grep -qF "$UNRELATED_SHIPWRIGHT" "$FAKE_CRONTAB" && grep -qF "$UNRELATED_OTHER" "$FAKE_CRONTAB" \
  && ok "remove deletes only this project's entries; shipwright + other-project survive" \
  || bad "remove" "left=$(grep -c "project ${PROJ}\$" "$FAKE_CRONTAB")"

# 24. --check OK after install, MISSING+exit1 before
setup_case check
make_runner_fix
: >"$FAKE_CRONTAB"
rc=0; inst_env --check --project "$PROJ" >/dev/null 2>&1 || rc=$?
[ "$rc" = 1 ] || bad "check-missing" "expected exit 1, got $rc"
inst_env --install --project "$PROJ" >/dev/null 2>&1
rc=0; inst_env --check --project "$PROJ" >/dev/null 2>&1 || rc=$?
[ "$rc" = 0 ] && ok "--check: exit 1 (MISSING) before install, exit 0 (OK) after" \
  || bad "check-ok" "expected exit 0 after install, got $rc"

# 25. refuses when the runner is not in the resolved main checkout
setup_case no-runner
RUNNER_DIR_FIX="${CD}/empty"; mkdir -p "$RUNNER_DIR_FIX"   # no runner copied in
: >"$FAKE_CRONTAB"
rc=0; inst_env --install --project "$PROJ" >/dev/null 2>&1 || rc=$?
[ "$rc" = 2 ] && ok "install refuses (exit 2) when the main-checkout runner is absent" \
  || bad "no-runner" "expected exit 2, got $rc"

# 26. refuses a non-git project dir
setup_case non-git
make_runner_fix
: >"$FAKE_CRONTAB"
rc=0; inst_env --install --project "${CD}/not-a-repo" >/dev/null 2>&1 || rc=$?
[ "$rc" = 2 ] && ok "install refuses (exit 2) a project dir that is not a git repository" \
  || bad "non-git" "expected exit 2, got $rc"

# 27. refuses when inbox-wait --dry-run refuses for the project (no channels)
setup_case no-channels
make_runner_fix
: >"$FAKE_CRONTAB"
cat >"${INBOXBIN}/inbox-wait" <<'STUB'
#!/usr/bin/env bash
case "${1:-}" in --dry-run) echo "no channels" >&2; exit 2;; esac
exit 0
STUB
chmod +x "${INBOXBIN}/inbox-wait"
rc=0; inst_env --install --project "$PROJ" >/dev/null 2>&1 || rc=$?
[ "$rc" = 2 ] && ok "install refuses (exit 2) when the project has no inbox channels (silent-dark class)" \
  || bad "no-channels" "expected exit 2, got $rc"

echo
echo "== $PASS passed, $FAIL failed =="
[ "$FAIL" -eq 0 ]
