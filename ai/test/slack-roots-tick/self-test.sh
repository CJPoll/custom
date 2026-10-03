#!/usr/bin/env bash
# Self-test for ai/bin/slack-roots-tick (DND-1502).
#
# The gap this pins: nothing ran `judgment-label --propose` on a schedule, so
# the slack_routing root snapshot grew only when someone ran it by hand. A
# Slack inbox generation is deleted at its second rotation, so a root that
# arrived and rotated out between two manual runs was lost for good, and its
# label became permanently n/a with no signal. slack-roots-tick is the
# scheduled step (the hourly shipwright tick runs it): it runs --propose,
# leaves its outcome in a run record, and alerts ONCE per failure episode.
#
# Hermetic: judgment-label and send-mail are stubs reached through the tool's
# two documented seams, and every state dir is a temp dir.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AI_DIR="$(cd "${HERE}/../.." && pwd)"
TOOL="${SLACK_ROOTS_TICK_UNDER_TEST:-${AI_DIR}/bin/slack-roots-tick}"

T="$(mktemp -d)"; trap 'rm -rf "${T}"' EXIT
PASS=0; FAIL=0
ok()  { printf '  ok    %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  FAIL  %s\n        %s\n' "$1" "$2"; FAIL=$((FAIL+1)); }

# --- stubs ----------------------------------------------------------------------
# judgment-label: records argv in SR_T/jl.log, then plays SR_JL_MODE:
#   ok (default)  prints a propose summary with SR_JL_APPENDED appended, exit 0
#   fail          prints a Fix: line on stderr, exit 1
#   silent        exit 0 with no snapshot summary line (an output we cannot read)
#   hang          blocks until killed (the tool's timeout must cap it)
cat > "${T}/judgment-label" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${SR_T}/jl.log"
# The run lock is the tool's fd 9; a child must never hold it.
[ -e /proc/self/fd/9 ] && echo "fd9-open" >> "${SR_T}/fd9.log"
case "${SR_JL_MODE:-ok}" in
  ok)
    echo "slack: /inbox/walt_ui-slack.jsonl.1 + /inbox/walt_ui-slack.jsonl: 378 lines"
    echo "roots: 70 owner new-conversation roots"
    echo "${SR_JL_SUMMARY:-snapshot: /inbox/evals/slack-routing-roots.jsonl: 70 roots kept, ${SR_JL_APPENDED:-0} appended}"
    echo "snapshot context: 3 lines"
    echo "owner_confirmed kept: 10 (0 in neither this inbox nor the snapshot)"
    exit 0 ;;
  fail)
    echo "judgment-label: the root snapshot is absent. Fix: restore it" >&2
    exit 1 ;;
  silent) exit 0 ;;
  hang) exec tail -f /dev/null ;;
esac
EOF
# send-mail: records argv and body; SR_MAIL_FAIL=1 plays a failed send.
cat > "${T}/send-mail" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${SR_T}/mail.log"
[ "${SR_MAIL_FAIL:-}" = 1 ] && { echo "send-mail: simulated failure" >&2; exit 1; }
[ "${SR_MAIL_SILENT:-}" = 1 ] && { echo "athena:inbox: path: local -- stub"; exit 0; }
while [ $# -gt 0 ]; do
  [ "$1" = "--body-file" ] && cp "$2" "${SR_T}/mail-body"
  shift
done
echo "athena:inbox: path: local -- stub"
echo "athena:inbox: delivered 20261001T000000Z-stub-slack-roots-failing.md"
EOF
chmod +x "${T}/judgment-label" "${T}/send-mail"
export SR_T="${T}"
export SLACK_ROOTS_JUDGMENT_LABEL="${T}/judgment-label"
export SLACK_ROOTS_SEND_MAIL="${T}/send-mail"

S="${T}/state"
run() { # <tick> [extra args...] -> sets RC; stdout/stderr in T/out, T/err
  local tick="$1"; shift
  "${TOOL}" --state-dir "${S}" --tick "${tick}" "$@" >"${T}/out" 2>"${T}/err"; RC=$?
}
rec()    { printf '%s' "${S}/runs/$1.propose"; }
jl_n()   { [ -f "${T}/jl.log" ] && wc -l < "${T}/jl.log" | tr -d ' ' || echo 0; }
mail_n() { [ -f "${T}/mail.log" ] && wc -l < "${T}/mail.log" | tr -d ' ' || echo 0; }
kv()     { sed -n "s/^$2=//p" "$1" 2>/dev/null | tail -n 1; }

# --- --help: stdout, exit 0, does nothing ------------------------------------------
out="$("${TOOL}" --help 2>/dev/null)"; rc=$?
if [ "${rc}" = 0 ] && grep -q 'judgment-label --propose' <<<"${out}" && [ "$(jl_n)" = 0 ] && [ ! -e "${S}" ]; then
  ok "--help prints usage on stdout, exits 0, runs nothing and writes nothing"
else
  bad "--help" "rc=${rc} jl=$(jl_n) state=$( [ -e "${S}" ] && echo exists)"
fi

# --- usage errors carry Fix: --------------------------------------------------------
"${TOOL}" --no-such-flag >"${T}/out" 2>"${T}/err"; rc=$?
if [ "${rc}" = 2 ] && grep -q 'Fix:' "${T}/err" && [ "$(jl_n)" = 0 ]; then
  ok "an unknown argument is exit 2 with a Fix: line, and runs nothing"
else
  bad "unknown argument" "rc=${rc} err=$(cat "${T}/err")"
fi
for flag in --alert-after --timeout; do
  all=1
  for bad_n in 0 x ''; do
    "${TOOL}" --state-dir "${S}" "${flag}" "${bad_n}" >"${T}/out" 2>"${T}/err"; rc=$?
    if [ "${rc}" != 2 ] || ! grep -q 'Fix:' "${T}/err"; then
      all=0; bad "${flag} '${bad_n}'" "rc=${rc} err=$(cat "${T}/err")"
    fi
  done
  [ "${all}" = 1 ] && ok "${flag} must be a positive integer (exit 2, Fix:), and nothing ran"
done
[ "$(jl_n)" = 0 ] || bad "usage errors ran judgment-label" "jl=$(jl_n)"

# --- a healthy tick: propose runs, the record carries its summary -----------------------
SR_JL_APPENDED=3 run t1
r="$(rec t1)"
if [ "${RC}" = 0 ] && [ "$(cat "${T}/jl.log")" = "--propose" ] \
   && grep -q '^snapshot: .*70 roots kept, 3 appended$' "${r}" \
   && grep -q '^ok: appended=3 exit=0$' "${r}" \
   && [ ! -e "${S}/consecutive-failures" ] && [ "$(mail_n)" = 0 ]; then
  ok "a healthy tick runs exactly 'judgment-label --propose' (no --rule-default, no --new-snapshot) and records ok: appended=3 with the summary"
else
  bad "healthy tick" "rc=${RC} jl=$(cat "${T}/jl.log") rec=$(cat "${r}" 2>&1)"
fi
if [ "$(stat -c %a "${r}")" = 600 ]; then
  ok "the run record is 0600 (it sits beside machine-local eval state)"
else
  bad "record mode" "$(stat -c %a "${r}")"
fi
if grep -q 'appended=3' "${T}/err" && grep -q "${r}" "${T}/err"; then
  ok "the one-line outcome on stderr names the appended count and the record"
else
  bad "stderr outcome" "$(cat "${T}/err")"
fi

if [ ! -e "${T}/fd9.log" ]; then
  ok "judgment-label does not inherit the run lock (fd 9 closed in the child)"
else
  bad "lock inheritance" "the child saw fd 9 open"
fi

# The real summary shapes judgment-label prints (ai/bin/judgment-label, the
# snapshot: line): with a trailing notes parenthesis, and on a new snapshot.
SR_JL_SUMMARY='snapshot: /inbox/evals/r.jsonl: 70 roots kept, 2 appended (3 no longer in this inbox; 1 not this owner'"'"'s roots, ignored)' run p1
SR_JL_SUMMARY='snapshot: /inbox/evals/r.jsonl: absent, starting it, 5 appended' run p2
if grep -q '^ok: appended=2 exit=0$' "$(rec p1)" && grep -q '^ok: appended=5 exit=0$' "$(rec p2)"; then
  ok "the summary parse reads the notes-suffixed and new-snapshot shapes (appended=2, appended=5)"
else
  bad "summary shapes" "p1=$(tail -n 1 "$(rec p1)") p2=$(tail -n 1 "$(rec p2)")"
fi

# Idempotent: a second tick with nothing new appends nothing and is still ok.
SR_JL_APPENDED=0 run t2
if [ "${RC}" = 0 ] && grep -q '^ok: appended=0 exit=0$' "$(rec t2)" && [ -s "$(rec t1)" ]; then
  ok "a second tick with no new roots is ok: appended=0, and the first record is kept"
else
  bad "second tick" "rc=${RC} rec=$(cat "$(rec t2)" 2>&1)"
fi

# --- failures: counted, recorded, alerted once per episode ------------------------------
SR_JL_MODE=fail run f1
r="$(rec f1)"
if [ "${RC}" = 1 ] && grep -q 'Fix: restore it' "${r}" \
   && grep -q '^failed: exit=1 consecutive_failures=1 threshold=3 ' "${r}" \
   && grep -q '^alert: not yet (1 of 3)$' "${r}" && [ "$(mail_n)" = 0 ] && grep -q 'Fix:' "${T}/err"; then
  ok "a failed propose is exit 1, recorded with its own output and the counter, and not alerted below the threshold"
else
  bad "first failure" "rc=${RC} mail=$(mail_n) rec=$(cat "${r}" 2>&1)"
fi
SR_JL_MODE=fail run f2
SR_JL_MODE=fail run f3
r="$(rec f3)"
ep="$(kv "${S}/failing" episode)"
if [ "${RC}" = 1 ] && [ "$(mail_n)" = 1 ] \
   && grep -q -- "--local harness-alerts-detector slack-roots-failing --to custom --re ${r} --body-file" "${T}/mail.log" \
   && grep -q "^failed: exit=1 consecutive_failures=3 threshold=3 episode=${ep} " "${r}" \
   && grep -q '^alert: harness-alerts 20261001T000000Z-stub-slack-roots-failing.md$' "${r}" \
   && grep -q "^episode: ${ep}$" "${T}/mail-body" && grep -q '^Fix:' "${T}/mail-body" \
   && [ "$(kv "${S}/failing" alerted)" = 20261001T000000Z-stub-slack-roots-failing.md ]; then
  ok "the threshold-th failure opens an episode, sends ONE slack-roots-failing alert re: its record, and records it"
else
  bad "threshold alert" "rc=${RC} mail=$(mail_n) ep=${ep} rec=$(cat "${r}" 2>&1) body=$(cat "${T}/mail-body" 2>&1)"
fi
SR_JL_MODE=fail run f4
if [ "${RC}" = 1 ] && [ "$(mail_n)" = 1 ] && grep -q '^alert: already sent for this episode (20261001T000000Z-stub-slack-roots-failing.md)$' "$(rec f4)" \
   && grep -q "episode=${ep} " "$(rec f4)"; then
  ok "a later failure in the same episode sends nothing and says it was already alerted"
else
  bad "no repeat alert" "mail=$(mail_n) rec=$(cat "$(rec f4)" 2>&1)"
fi

# A success ends the episode; the next run of failures is a new episode and alerts again.
run s1
if [ "${RC}" = 0 ] && [ ! -e "${S}/consecutive-failures" ] && [ ! -e "${S}/failing" ] \
   && grep -q 'ended the failure episode' "$(rec s1)"; then
  ok "a healthy tick clears the counter and ends the episode, and says so in its record"
else
  bad "episode end" "rc=${RC} rec=$(cat "$(rec s1)" 2>&1)"
fi
for t in g1 g2 g3; do SR_JL_MODE=fail run "${t}"; done
if [ "$(mail_n)" = 2 ] && [ "$(kv "${S}/failing" episode)" != "${ep}" ]; then
  ok "failures after a success are a new episode, alerted again"
else
  bad "new episode" "mail=$(mail_n) episode=$(kv "${S}/failing" episode) old=${ep}"
fi
run s2

# --- an exit 0 with no summary line is a failure, never an ok with nothing appended ------
SR_JL_MODE=silent run q1
if [ "${RC}" = 1 ] && grep -q '^failed: exit=0 .*no snapshot summary line' "$(rec q1)" \
   && ! grep -q '^ok:' "$(rec q1)"; then
  ok "exit 0 with no 'snapshot:' summary is recorded as failed (could not read the outcome), not as appended=0"
else
  bad "silent exit 0" "rc=${RC} rec=$(cat "$(rec q1)" 2>&1)"
fi
run s3

# --- a hang is capped by --timeout and recorded as a failure ------------------------------
SR_JL_MODE=hang run h1 --timeout 1
if [ "${RC}" = 1 ] && grep -q '^failed: exit=124 .*timed out after 1s' "$(rec h1)"; then
  ok "a propose that hangs is killed at --timeout and recorded as failed (exit 124)"
else
  bad "hang" "rc=${RC} rec=$(cat "$(rec h1)" 2>&1)"
fi
run s4

# --- a failed send is recorded as FAILED, never as sent, and the next failure retries ------
for t in m1 m2; do SR_JL_MODE=fail run "${t}"; done
M="$(mail_n)"
SR_MAIL_FAIL=1 SR_JL_MODE=fail run m3
if [ "${RC}" = 1 ] && grep -q '^alert: FAILED to send$' "$(rec m3)" && [ -z "$(kv "${S}/failing" alerted)" ] \
   && grep -q 'Fix:' "${T}/err"; then
  ok "a failed alert send is recorded as FAILED, is loud with a Fix:, and is not remembered as sent"
else
  bad "failed send" "rc=${RC} alerted=$(kv "${S}/failing" alerted) rec=$(cat "$(rec m3)" 2>&1)"
fi
SR_JL_MODE=fail run m4
if [ "$(mail_n)" = "$((M + 2))" ] && grep -q '^alert: harness-alerts ' "$(rec m4)"; then
  ok "the next failing tick retries the alert and records it as sent"
else
  bad "send retry" "mail=$(mail_n) M=${M} rec=$(cat "$(rec m4)" 2>&1)"
fi
run s5

# A send that exits 0 but names no delivered message is not a delivery.
for t in d1 d2; do SR_JL_MODE=fail run "${t}"; done
SR_MAIL_SILENT=1 SR_JL_MODE=fail run d3
if grep -q '^alert: FAILED to send$' "$(rec d3)" && [ -z "$(kv "${S}/failing" alerted)" ]; then
  ok "a send with no 'delivered' line is recorded as FAILED and retried, never stored as sent"
else
  bad "silent send" "alerted=$(kv "${S}/failing" alerted) rec=$(cat "$(rec d3)" 2>&1)"
fi
run s6

# --- a tick already in flight: skip, run nothing, count nothing ---------------------------
N="$(jl_n)"
exec 7>>"${S}/run.lock"
flock -n 7
SR_JL_MODE=fail run k1
exec 7>&-
if [ "${RC}" = 0 ] && [ "$(jl_n)" = "${N}" ] && grep -q '^skipped: another slack-roots-tick holds' "${S}/runs/k1.skipped" \
   && [ ! -e "${S}/consecutive-failures" ]; then
  ok "a held run lock skips the tick (exit 0, a .skipped record), runs nothing and counts nothing"
else
  bad "lock held" "rc=${RC} jl=$(jl_n)/${N} skip=$(cat "${S}/runs/k1.skipped" 2>&1)"
fi

# --- a state dir that cannot be made is exit 3, and propose does not run blind ------------
N="$(jl_n)"
printf 'not a dir\n' > "${T}/file"
"${TOOL}" --state-dir "${T}/file/state" --tick x1 >"${T}/out" 2>"${T}/err"; rc=$?
if [ "${rc}" = 3 ] && grep -q 'Fix:' "${T}/err" && [ "$(jl_n)" = "${N}" ]; then
  ok "an unusable state dir is exit 3 with a Fix:, and propose is not run without a record"
else
  bad "unusable state dir" "rc=${rc} err=$(cat "${T}/err")"
fi

# --- the default state dir comes from scripts/lib/main-checkout.sh (DND-1722) -------------
# fx_tool <dir> — a copy of the tool beside its libs in <dir>, a fixture checkout.
fx_tool() {
  mkdir -p "$1/ai/bin" "$1/ai/lib" "$1/scripts/lib"
  cp -- "${AI_DIR}/bin/slack-roots-tick" "$1/ai/bin/"
  cp -- "${AI_DIR}/lib/harness-alert-send.sh" "$1/ai/lib/"
  cp -- "${AI_DIR}/../scripts/lib/main-checkout.sh" "$1/scripts/lib/"
}
fx_run() { # <dir> -> sets rc; the default state dir (no --state-dir)
  "$1/ai/bin/slack-roots-tick" --tick d1 >"${T}/out" 2>"${T}/err"; rc=$?
}
git init -q -b main "${T}/fx-main" >&2
fx_tool "${T}/fx-main"
fx_run "${T}/fx-main"
if [ "${rc}" = 0 ] && [ -f "${T}/fx-main/ai-artifacts/slack-roots/runs/d1.propose" ]; then
  ok "a main checkout's default state dir is <checkout>/ai-artifacts/slack-roots"
else
  bad "default state dir" "rc=${rc} err=$(cat "${T}/err")"
fi
git -C "${T}/fx-main" -c user.email=t@example.invalid -c user.name=t -c commit.gpgsign=false commit -q --allow-empty -m seed >&2
git -C "${T}/fx-main" worktree add -q "${T}/fx-wt" >&2
fx_tool "${T}/fx-wt"
fx_run "${T}/fx-wt"
if [ "${rc}" = 0 ] && [ -f "${T}/fx-main/ai-artifacts/slack-roots/runs/d1.propose" ] && [ ! -e "${T}/fx-wt/ai-artifacts" ]; then
  ok "from a linked worktree the default state dir is still the MAIN checkout's"
else
  bad "worktree default state dir" "rc=${rc} err=$(cat "${T}/err")"
fi
git init -q -b main --separate-git-dir "${T}/fx-sep-gitdir" "${T}/fx-sep" >&2
fx_tool "${T}/fx-sep"
fx_run "${T}/fx-sep"
if [ "${rc}" = 3 ] && grep -q 'not <checkout>/.git' "${T}/err" && grep -q 'Fix:' "${T}/err" \
   && [ ! -e "${T}/fx-sep/ai-artifacts" ] && [ ! -e "${T}/ai-artifacts" ]; then
  ok "a --separate-git-dir repo is exit 3 naming the cause with a Fix:, and writes no state"
else
  bad "separate git dir" "rc=${rc} err=$(cat "${T}/err")"
fi
mkdir -p "${T}/fx-nogit"
fx_tool "${T}/fx-nogit"
GIT_CEILING_DIRECTORIES="${T}" fx_run "${T}/fx-nogit"
if [ "${rc}" = 3 ] && grep -q 'not inside a git checkout' "${T}/err" && grep -q 'Fix:' "${T}/err" && [ ! -e "${T}/fx-nogit/ai-artifacts" ]; then
  ok "a tool outside any git checkout is exit 3 naming the cause with a Fix:, and writes no state"
else
  bad "non-git tool dir" "rc=${rc} err=$(cat "${T}/err")"
fi
rm -f "${T}/fx-main/scripts/lib/main-checkout.sh"
fx_run "${T}/fx-main"
if [ "${rc}" = 2 ] && grep -q 'main-checkout.sh' "${T}/err" && grep -q 'Fix:' "${T}/err"; then
  ok "a missing main-checkout.sh is exit 2 naming the file, with a Fix:"
else
  bad "missing lib" "rc=${rc} err=$(cat "${T}/err")"
fi

# --- a missing judgment-label is a recorded failure, never a quiet skip --------------------
SLACK_ROOTS_JUDGMENT_LABEL="${T}/no-such-judgment-label" run n1
if [ "${RC}" = 1 ] && grep -q '^failed: exit=127 .*not executable' "$(rec n1)"; then
  ok "a missing judgment-label is recorded as failed (exit 127) and counts toward the episode"
else
  bad "missing judgment-label" "rc=${RC} rec=$(cat "$(rec n1)" 2>&1)"
fi

printf '\n%d passed, %d failed\n' "${PASS}" "${FAIL}"
[ "${FAIL}" -eq 0 ] || {
  printf 'Fix: read each FAIL line above; it names the guarantee that broke. Re-run with: bash ai/test/slack-roots-tick/self-test.sh\n' >&2
  exit 1
}
exit 0
